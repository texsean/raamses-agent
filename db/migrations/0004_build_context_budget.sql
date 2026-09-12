-- RaamsesAgent SQL State Layer — v1
-- 0004: make sp_build_context honour p_token_budget inside SQL.
--
-- Why: charter success criterion 2 requires sp_build_context to return context
-- "already trimmed to budget, in order" in ONE round-trip. The 0003 version
-- returned every unsummarized message and left trimming to the repository
-- layer, which makes the budget a client-side concern and can ship a whole
-- session's history over the wire on every turn. This version accumulates a
-- running token total across sections and stops emitting rows once the budget
-- is exhausted.
--
-- Ordering / priority (highest value first, so truncation drops the least
-- important context):
--   1. summary  — latest rolling summary
--   2. memory   — importance-ranked, up to 10
--   3. skill    — active skill headers, up to 20
--   4. message  — recent unsummarized turns, newest first, fills the remainder
--
-- The 'message' rows are emitted newest-first and the caller reverses them for
-- chronological display; trimming newest-first means an over-budget session
-- drops its OLDEST unsummarized turns, which is the correct eviction order.
--
-- Row-level budget accounting is also returned to the caller: the final
-- running total is available by summing token_count client-side for
-- turn_metrics, with no second query.

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
    v_used      INTEGER := 0;
    v_budget    INTEGER := GREATEST(COALESCE(p_token_budget, 0), 0);
    r           RECORD;
BEGIN
    FOR r IN
        WITH summary_rows AS (
            SELECT 'summary'::TEXT       AS section,
                   0                     AS ord,
                   s.id                  AS ref_id,
                   'system'::TEXT        AS role,
                   s.content             AS content,
                   COALESCE(s.token_count, GREATEST(length(s.content) / 4, 1)) AS token_count,
                   1                     AS section_rank
            FROM summaries s
            WHERE s.session_id = p_session_id
            ORDER BY s.created_at DESC
            LIMIT 1
        ),
        memory_rows AS (
            SELECT 'memory'::TEXT,
                   ROW_NUMBER() OVER (ORDER BY m.importance DESC, m.last_accessed_at DESC)::INTEGER,
                   m.id,
                   'system'::TEXT,
                   m.content,
                   GREATEST(length(m.content) / 4, 1),
                   2
            FROM memories m
            WHERE (m.session_id = p_session_id OR m.session_id IS NULL)
            ORDER BY m.importance DESC, m.last_accessed_at DESC
            LIMIT 10
        ),
        skill_rows AS (
            SELECT 'skill'::TEXT,
                   ROW_NUMBER() OVER (ORDER BY sk.usage_count DESC, sk.name)::INTEGER,
                   sk.id,
                   'system'::TEXT,
                   sk.name || ': ' || COALESCE(sk.description, ''),
                   GREATEST(length(sk.name || ': ' || COALESCE(sk.description, '')) / 4, 1),
                   3
            FROM skills sk
            WHERE sk.is_archived = false AND sk.is_suppressed = false
            ORDER BY sk.usage_count DESC, sk.name
            LIMIT 20
        ),
        message_rows AS (
            SELECT 'message'::TEXT,
                   ROW_NUMBER() OVER (ORDER BY m.created_at DESC, m.id DESC)::INTEGER,
                   m.id,
                   m.role,
                   m.content,
                   COALESCE(m.token_count, GREATEST(length(m.content) / 4, 1)),
                   4
            FROM messages m
            WHERE m.session_id = p_session_id
              AND m.is_summarized = false
            ORDER BY m.created_at DESC, m.id DESC
        )
        SELECT * FROM summary_rows
        UNION ALL SELECT * FROM memory_rows
        UNION ALL SELECT * FROM skill_rows
        UNION ALL SELECT * FROM message_rows
        ORDER BY section_rank, ord
    LOOP
        -- Stop as soon as the next row would exceed the budget. Sections are
        -- walked in priority order, so what gets dropped is always the
        -- lowest-priority context (oldest unsummarized turns first).
        EXIT WHEN v_used + r.token_count > v_budget;

        v_used := v_used + r.token_count;

        section     := r.section;
        ord         := r.ord;
        ref_id      := r.ref_id;
        role        := r.role;
        content     := r.content;
        token_count := r.token_count;
        RETURN NEXT;
    END LOOP;
END;
$$;
