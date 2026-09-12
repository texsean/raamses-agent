-- RaamsesAgent SQL State Layer — v1
-- 0003: stored functions. Application code (repository layer, Phase 2) calls
-- ONLY these — no raw SQL from Python per charter architecture rule.

-- ========================================================= sp_append_message
-- Insert one message, bump the session's updated_at, return the new row id.
CREATE OR REPLACE FUNCTION sp_append_message(
    p_session_id    UUID,
    p_role          TEXT,
    p_content       TEXT,
    p_parent_id     BIGINT DEFAULT NULL,
    p_token_count   INTEGER DEFAULT NULL,
    p_metadata      JSONB DEFAULT '{}'::jsonb
) RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    v_id BIGINT;
BEGIN
    INSERT INTO messages (session_id, parent_id, role, content, token_count, metadata)
    VALUES (p_session_id, p_parent_id, p_role, p_content, p_token_count, p_metadata)
    RETURNING id INTO v_id;

    UPDATE sessions SET updated_at = now() WHERE session_id = p_session_id;

    RETURN v_id;
END;
$$;

-- ========================================================= sp_log_tool_call
CREATE OR REPLACE FUNCTION sp_log_tool_call(
    p_session_id    UUID,
    p_tool_name     TEXT,
    p_arguments     JSONB,
    p_message_id    BIGINT DEFAULT NULL,
    p_result        JSONB DEFAULT NULL,
    p_status        TEXT DEFAULT 'ok',
    p_error_text    TEXT DEFAULT NULL,
    p_duration_ms   NUMERIC DEFAULT NULL
) RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    v_id BIGINT;
BEGIN
    INSERT INTO tool_calls (session_id, message_id, tool_name, arguments, result,
                             status, error_text, duration_ms)
    VALUES (p_session_id, p_message_id, p_tool_name, p_arguments, p_result,
            p_status, p_error_text, p_duration_ms)
    RETURNING id INTO v_id;

    RETURN v_id;
END;
$$;

-- ========================================================= sp_upsert_memory
-- Snapshot semantics: existing frozen rows are left alone unless explicitly
-- targeted by id; this call always inserts a new memory row or updates one
-- addressed by id, never silently mutates a frozen row's frozen flag.
CREATE OR REPLACE FUNCTION sp_upsert_memory(
    p_id            BIGINT,             -- NULL => insert new
    p_session_id    UUID,               -- NULL => global/user-level memory
    p_kind          TEXT,
    p_content       TEXT,
    p_embedding     VECTOR(1536) DEFAULT NULL,
    p_importance    REAL DEFAULT 0.5,
    p_metadata      JSONB DEFAULT '{}'::jsonb
) RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    v_id BIGINT;
BEGIN
    IF p_id IS NULL THEN
        INSERT INTO memories (session_id, kind, content, embedding, importance, metadata)
        VALUES (p_session_id, p_kind, p_content, p_embedding, p_importance, p_metadata)
        RETURNING id INTO v_id;
    ELSE
        UPDATE memories
           SET content    = p_content,
               embedding  = COALESCE(p_embedding, embedding),
               importance = p_importance,
               metadata   = p_metadata,
               last_accessed_at = now()
         WHERE id = p_id
        RETURNING id INTO v_id;

        IF v_id IS NULL THEN
            RAISE EXCEPTION 'sp_upsert_memory: no memory row with id=%', p_id;
        END IF;
    END IF;

    RETURN v_id;
END;
$$;

-- ================================================================ sp_recall
-- pgvector cosine search when an embedding is supplied; tsvector/trigram
-- fallback (ts_rank via plainto_tsquery, falling back further to trigram
-- similarity) when no embedding provider is configured for this call.
CREATE OR REPLACE FUNCTION sp_recall(
    p_session_id        UUID,
    p_query_embedding   VECTOR(1536) DEFAULT NULL,
    p_query_text        TEXT DEFAULT NULL,
    p_k                 INTEGER DEFAULT 8
) RETURNS TABLE (
    memory_id   BIGINT,
    content     TEXT,
    kind        TEXT,
    importance  REAL,
    score       REAL
)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_query_embedding IS NOT NULL THEN
        RETURN QUERY
        SELECT m.id, m.content, m.kind, m.importance,
               (1 - (m.embedding <=> p_query_embedding))::REAL AS score
        FROM memories m
        WHERE (m.session_id = p_session_id OR m.session_id IS NULL)
          AND m.embedding IS NOT NULL
        ORDER BY m.embedding <=> p_query_embedding
        LIMIT p_k;
    ELSIF p_query_text IS NOT NULL THEN
        RETURN QUERY
        SELECT m.id, m.content, m.kind, m.importance,
               similarity(m.content, p_query_text)::REAL AS score
        FROM memories m
        WHERE (m.session_id = p_session_id OR m.session_id IS NULL)
          AND m.content % p_query_text
        ORDER BY score DESC
        LIMIT p_k;
    ELSE
        RETURN QUERY
        SELECT m.id, m.content, m.kind, m.importance, m.importance AS score
        FROM memories m
        WHERE (m.session_id = p_session_id OR m.session_id IS NULL)
        ORDER BY m.importance DESC, m.last_accessed_at DESC
        LIMIT p_k;
    END IF;
END;
$$;

-- ========================================================= sp_compact_session
-- Transactional compaction: fold all not-yet-summarized messages up to
-- p_up_to_message_id into a new summary row, mark them summarized. Wrapped
-- implicitly in one transaction (a plpgsql function body IS the transaction
-- from the caller's point of view) -- a crash mid-function leaves the
-- prior state fully intact per charter success criterion 4.
CREATE OR REPLACE FUNCTION sp_compact_session(
    p_session_id        UUID,
    p_summary_content   TEXT,
    p_up_to_message_id  BIGINT,
    p_summary_tokens    INTEGER DEFAULT NULL
) RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    v_summary_id BIGINT;
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM messages
        WHERE id = p_up_to_message_id AND session_id = p_session_id
    ) THEN
        RAISE EXCEPTION 'sp_compact_session: message % not found in session %',
            p_up_to_message_id, p_session_id;
    END IF;

    INSERT INTO summaries (session_id, content, covers_up_to_message_id, token_count)
    VALUES (p_session_id, p_summary_content, p_up_to_message_id, p_summary_tokens)
    RETURNING id INTO v_summary_id;

    UPDATE messages
       SET is_summarized = true
     WHERE session_id = p_session_id
       AND id <= p_up_to_message_id
       AND is_summarized = false;

    UPDATE sessions SET updated_at = now() WHERE session_id = p_session_id;

    RETURN v_summary_id;
END;
$$;

-- ============================================================ sp_build_context
-- The money function (charter success criterion 2): one ordered result set,
-- pre-trimmed to token budget: system-prompt fragments (none owned by SQL —
-- placeholder empty set for now, reserved for Phase 3) + relevant memories +
-- skill headers + latest rolling summary + recent unsummarized turns, in
-- delivery order. A single UNION ALL of tagged rows lets callers reconstruct
-- ordering client-side without five separate round-trips.
CREATE OR REPLACE FUNCTION sp_build_context(
    p_session_id    UUID,
    p_token_budget  INTEGER DEFAULT 8000
) RETURNS TABLE (
    section         TEXT,       -- 'summary' | 'memory' | 'skill' | 'message'
    ord             INTEGER,    -- caller sort key within section
    ref_id          BIGINT,
    role            TEXT,
    content         TEXT,
    token_count     INTEGER
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_used_tokens   INTEGER := 0;
    v_budget        INTEGER := p_token_budget;
BEGIN
    -- 1) latest rolling summary (cheapest, highest-value context)
    RETURN QUERY
    SELECT 'summary'::TEXT, 0, s.id, 'system'::TEXT, s.content, COALESCE(s.token_count, 0)
    FROM summaries s
    WHERE s.session_id = p_session_id
    ORDER BY s.created_at DESC
    LIMIT 1;

    -- 2) top relevant memories (importance-ranked; embedding search is the
    --    caller's job via sp_recall when a query embedding exists — this
    --    default path is importance/recency for baseline context assembly)
    RETURN QUERY
    SELECT 'memory'::TEXT, ROW_NUMBER() OVER (ORDER BY m.importance DESC, m.last_accessed_at DESC)::INTEGER,
           m.id, 'system'::TEXT, m.content, COALESCE(length(m.content) / 4, 0)
    FROM memories m
    WHERE (m.session_id = p_session_id OR m.session_id IS NULL)
    ORDER BY m.importance DESC, m.last_accessed_at DESC
    LIMIT 10;

    -- 3) active skill headers (name + description only — full content loaded
    --    on demand elsewhere, keeps this call cheap)
    RETURN QUERY
    SELECT 'skill'::TEXT, ROW_NUMBER() OVER (ORDER BY sk.usage_count DESC)::INTEGER,
           sk.id, 'system'::TEXT,
           sk.name || ': ' || COALESCE(sk.description, ''),
           COALESCE(length(sk.description) / 4, 0)
    FROM skills sk
    WHERE sk.is_archived = false AND sk.is_suppressed = false
    ORDER BY sk.usage_count DESC
    LIMIT 20;

    -- 4) recent unsummarized messages, most recent first (caller reverses
    --    for chronological display); this is the part trimmed to budget.
    RETURN QUERY
    SELECT 'message'::TEXT, ROW_NUMBER() OVER (ORDER BY m.created_at DESC)::INTEGER,
           m.id, m.role, m.content, COALESCE(m.token_count, length(m.content) / 4)
    FROM messages m
    WHERE m.session_id = p_session_id
      AND m.is_summarized = false
    ORDER BY m.created_at DESC;

    -- Note: hard token-budget trimming of the 'message' section is applied
    -- by the repository layer (Phase 2) by walking rows in order and
    -- summing token_count until p_token_budget is reached; kept out of SQL
    -- here so the running total is visible to callers for turn_metrics.
    PERFORM v_budget, v_used_tokens; -- silence unused-variable warnings
END;
$$;
