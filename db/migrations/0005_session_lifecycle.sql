-- RaamsesAgent SQL State Layer — v1
-- 0005: session lifecycle stored functions.
--
-- Why: 0003 shipped message/memory/compaction functions but no way to CREATE
-- a session, so the only path to a session row was a raw INSERT — which the
-- charter architecture rule forbids in application code ("Application code
-- contains no raw SQL"). The Phase 2 repository layer needs these to be a
-- complete API surface.

-- ========================================================= sp_create_session
CREATE OR REPLACE FUNCTION sp_create_session(
    p_title     TEXT DEFAULT NULL,
    p_metadata  JSONB DEFAULT '{}'::jsonb
) RETURNS UUID
LANGUAGE plpgsql
AS $$
DECLARE
    v_id UUID;
BEGIN
    INSERT INTO sessions (title, metadata)
    VALUES (p_title, p_metadata)
    RETURNING session_id INTO v_id;

    RETURN v_id;
END;
$$;

-- =========================================================== sp_end_session
-- Idempotent close. end_reason is recorded in metadata under 'end_reason' and
-- is first-wins, matching stock Hermes semantics (run_agent.py:979).
CREATE OR REPLACE FUNCTION sp_end_session(
    p_session_id    UUID,
    p_status        TEXT DEFAULT 'closed',
    p_end_reason    TEXT DEFAULT NULL
) RETURNS BOOLEAN
LANGUAGE plpgsql
AS $$
DECLARE
    v_found BOOLEAN;
BEGIN
    UPDATE sessions
       SET status     = p_status,
           metadata   = CASE
                            WHEN p_end_reason IS NULL THEN metadata
                            WHEN metadata ? 'end_reason' THEN metadata  -- first-wins
                            ELSE metadata || jsonb_build_object('end_reason', p_end_reason)
                        END,
           updated_at = now()
     WHERE session_id = p_session_id
    RETURNING true INTO v_found;

    RETURN COALESCE(v_found, false);
END;
$$;

-- ========================================================== sp_get_session
CREATE OR REPLACE FUNCTION sp_get_session(
    p_session_id UUID
) RETURNS TABLE (
    session_id      UUID,
    title           TEXT,
    status          TEXT,
    storage_backend TEXT,
    metadata        JSONB,
    created_at      TIMESTAMPTZ,
    updated_at      TIMESTAMPTZ
)
LANGUAGE sql
STABLE
AS $$
    SELECT s.session_id, s.title, s.status, s.storage_backend,
           s.metadata, s.created_at, s.updated_at
    FROM sessions s
    WHERE s.session_id = p_session_id;
$$;

-- ======================================================== sp_list_sessions
CREATE OR REPLACE FUNCTION sp_list_sessions(
    p_status    TEXT DEFAULT NULL,   -- NULL = any status
    p_limit     INTEGER DEFAULT 50
) RETURNS TABLE (
    session_id      UUID,
    title           TEXT,
    status          TEXT,
    message_count   BIGINT,
    created_at      TIMESTAMPTZ,
    updated_at      TIMESTAMPTZ
)
LANGUAGE sql
STABLE
AS $$
    SELECT s.session_id, s.title, s.status,
           (SELECT count(*) FROM messages m WHERE m.session_id = s.session_id),
           s.created_at, s.updated_at
    FROM sessions s
    WHERE p_status IS NULL OR s.status = p_status
    ORDER BY s.updated_at DESC
    LIMIT p_limit;
$$;

-- ======================================================= sp_record_turn_metrics
-- Criterion 5: every turn logs db_ms / model_ms / tool_ms. Upsert so a retried
-- turn overwrites rather than violating the (session_id, turn_number) unique.
CREATE OR REPLACE FUNCTION sp_record_turn_metrics(
    p_session_id    UUID,
    p_turn_number   INTEGER,
    p_db_ms         NUMERIC DEFAULT 0,
    p_model_ms      NUMERIC DEFAULT 0,
    p_tool_ms       NUMERIC DEFAULT 0,
    p_metadata      JSONB DEFAULT '{}'::jsonb
) RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    v_id BIGINT;
BEGIN
    INSERT INTO turn_metrics (session_id, turn_number, db_ms, model_ms, tool_ms, metadata)
    VALUES (p_session_id, p_turn_number, p_db_ms, p_model_ms, p_tool_ms, p_metadata)
    ON CONFLICT (session_id, turn_number) DO UPDATE
        SET db_ms    = EXCLUDED.db_ms,
            model_ms = EXCLUDED.model_ms,
            tool_ms  = EXCLUDED.tool_ms,
            metadata = EXCLUDED.metadata
    RETURNING id INTO v_id;

    RETURN v_id;
END;
$$;
