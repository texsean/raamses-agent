-- RaamsesAgent SQL State Layer — v1
-- 0001: extensions required by the schema.

CREATE EXTENSION IF NOT EXISTS pgcrypto;   -- gen_random_uuid()
CREATE EXTENSION IF NOT EXISTS vector;     -- pgvector: embedding column + ANN index
CREATE EXTENSION IF NOT EXISTS pg_trgm;    -- trigram fallback for text search/dedup
