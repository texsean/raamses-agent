-- RaamsesAgent SQL State Layer — v1
-- 0002: core tables per GOAL.md charter.
-- Convention: every table carries session_id + created_at (session_id is NULL
-- on tables that are intentionally global/cross-session — skills, file_sync).

-- ============================================================= sessions ====
CREATE TABLE sessions (
    session_id      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    title           TEXT,
    status          TEXT NOT NULL DEFAULT 'active'
                        CHECK (status IN ('active', 'archived', 'closed')),
    storage_backend TEXT NOT NULL DEFAULT 'raamses'
                        CHECK (storage_backend IN ('hermes', 'raamses')),
    metadata        JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_sessions_status ON sessions (status);
CREATE INDEX idx_sessions_created_at ON sessions (created_at);

-- ============================================================= messages ====
-- parent_id enables free session branching (a message tree, not just a list).
CREATE TABLE messages (
    id              BIGSERIAL PRIMARY KEY,
    session_id      UUID NOT NULL REFERENCES sessions (session_id) ON DELETE CASCADE,
    parent_id       BIGINT REFERENCES messages (id) ON DELETE SET NULL,
    role            TEXT NOT NULL CHECK (role IN ('system', 'user', 'assistant', 'tool')),
    content         TEXT NOT NULL,
    token_count     INTEGER,
    branch_label    TEXT,
    is_summarized   BOOLEAN NOT NULL DEFAULT false,   -- true once folded into a summary row
    metadata        JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_messages_session_id ON messages (session_id, created_at);
CREATE INDEX idx_messages_parent_id ON messages (parent_id);
CREATE INDEX idx_messages_session_not_summarized
    ON messages (session_id, created_at)
    WHERE is_summarized = false;

-- ============================================================ tool_calls ===
CREATE TABLE tool_calls (
    id              BIGSERIAL PRIMARY KEY,
    session_id      UUID NOT NULL REFERENCES sessions (session_id) ON DELETE CASCADE,
    message_id      BIGINT REFERENCES messages (id) ON DELETE SET NULL,
    tool_name       TEXT NOT NULL,
    arguments       JSONB NOT NULL DEFAULT '{}'::jsonb,
    result          JSONB,
    status          TEXT NOT NULL DEFAULT 'ok' CHECK (status IN ('ok', 'error', 'timeout')),
    error_text      TEXT,
    duration_ms     NUMERIC,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_tool_calls_session_id ON tool_calls (session_id, created_at);
CREATE INDEX idx_tool_calls_tool_name ON tool_calls (tool_name);

-- ============================================================= summaries ===
-- Rolling compaction summaries. covers_up_to_message_id lets sp_build_context
-- know which messages are already folded and can be skipped from raw history.
CREATE TABLE summaries (
    id                      BIGSERIAL PRIMARY KEY,
    session_id              UUID NOT NULL REFERENCES sessions (session_id) ON DELETE CASCADE,
    content                 TEXT NOT NULL,
    covers_up_to_message_id BIGINT REFERENCES messages (id) ON DELETE SET NULL,
    token_count             INTEGER,
    created_at              TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_summaries_session_id ON summaries (session_id, created_at DESC);

-- ============================================================== memories ===
-- Embedding dimension left at 1536 (OpenAI text-embedding-3-small default);
-- adjust via migration if the configured provider differs.
CREATE TABLE memories (
    id              BIGSERIAL PRIMARY KEY,
    session_id      UUID REFERENCES sessions (session_id) ON DELETE CASCADE,  -- NULL = global/user-level memory
    kind            TEXT NOT NULL DEFAULT 'fact' CHECK (kind IN ('fact', 'preference', 'episodic', 'summary')),
    content         TEXT NOT NULL,
    embedding       VECTOR(1536),
    importance      REAL NOT NULL DEFAULT 0.5,
    frozen          BOOLEAN NOT NULL DEFAULT false,   -- snapshot semantics: frozen at load, reloaded only at compaction
    metadata        JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_accessed_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_memories_session_id ON memories (session_id);
CREATE INDEX idx_memories_embedding ON memories USING ivfflat (embedding vector_cosine_ops) WITH (lists = 100);
CREATE INDEX idx_memories_content_trgm ON memories USING gin (content gin_trgm_ops);  -- tsvector-free fallback recall

-- ================================================================ skills ===
-- Full content port per charter Decision 2: SKILL.md content, sidecar usage
-- ledger, and curator state all live here. Disk files remain the
-- 3rd-party/legacy/authoring import surface only.
CREATE TABLE skills (
    id                  BIGSERIAL PRIMARY KEY,
    session_id          UUID REFERENCES sessions (session_id) ON DELETE SET NULL, -- NULL = global skill
    name                TEXT NOT NULL,
    description         TEXT,
    category            TEXT,
    content             TEXT NOT NULL,             -- full SKILL.md body
    source              TEXT NOT NULL DEFAULT 'user'
                            CHECK (source IN ('bundled', 'plugin', 'hub', 'user')),
    file_path           TEXT,                       -- legacy/authoring provenance, not read at runtime
    version             TEXT,
    usage_count         INTEGER NOT NULL DEFAULT 0,
    last_used_at        TIMESTAMPTZ,
    curator_state       JSONB NOT NULL DEFAULT '{}'::jsonb,
    is_suppressed       BOOLEAN NOT NULL DEFAULT false,
    is_archived         BOOLEAN NOT NULL DEFAULT false,
    metadata            JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (name, source)
);

CREATE INDEX idx_skills_name ON skills (name);
CREATE INDEX idx_skills_active ON skills (is_archived, is_suppressed);

-- ============================================================ turn_metrics =
CREATE TABLE turn_metrics (
    id              BIGSERIAL PRIMARY KEY,
    session_id      UUID NOT NULL REFERENCES sessions (session_id) ON DELETE CASCADE,
    turn_number     INTEGER NOT NULL,
    db_ms           NUMERIC NOT NULL DEFAULT 0,
    model_ms        NUMERIC NOT NULL DEFAULT 0,
    tool_ms         NUMERIC NOT NULL DEFAULT 0,
    total_ms        NUMERIC GENERATED ALWAYS AS (db_ms + model_ms + tool_ms) STORED,
    metadata        JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (session_id, turn_number)
);

CREATE INDEX idx_turn_metrics_session_id ON turn_metrics (session_id, turn_number);

-- ============================================================== file_sync ==
-- Per-file fingerprint ledger for the external-edit sync sweep (Decision 5).
-- Global table: file_path is the natural key, not scoped to a session.
CREATE TABLE file_sync (
    id                  BIGSERIAL PRIMARY KEY,
    session_id          UUID REFERENCES sessions (session_id) ON DELETE SET NULL,  -- usually NULL (skills/memories are global)
    file_path           TEXT NOT NULL UNIQUE,
    content_hash        TEXT NOT NULL,
    watched_kind        TEXT NOT NULL CHECK (watched_kind IN ('skill', 'memory_md')),
    last_direction      TEXT CHECK (last_direction IN ('import', 'export', 'conflict')),
    last_synced_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_file_sync_kind ON file_sync (watched_kind);
