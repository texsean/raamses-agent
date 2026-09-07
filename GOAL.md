# RaamsesAgent — Charter: SQL State Layer (v1, finalized 2026-09-07)

Fork of `NousResearch/hermes-agent` (upstream remote: `hermes`).
Repo: `texsean/raamses-agent` · Brand: Raamses.io · User: texsean (seantexan@gmail.com)

## Goal

Replace Hermes' file-scattered state layer — `state.db` (SQLite), `sessions/*.jsonl`
transcripts, markdown memory files, markdown skills, on-disk summaries — with a single
PostgreSQL 16 + pgvector store accessed **exclusively through stored functions**.
Every agent turn assembles its context in one database round-trip
(`sp_build_context`), and we measure whether it actually helps.

Colloquially: **SQL, not markdowns/files.** Success criterion 1 is the definition of
done: after the port, Hermes' `state.db`, `sessions/*.jsonl`, and markdown
memory/summary files are no longer read or written during an interactive session.

## Non-goals (v1)

- No changes to the model client, tool loop, TUI, or gateway. Fork, not rewrite.
- No new agent features. Storage layer only, until benchmarks exist.
- `config.yaml`, `.env`, logs, and user content files (uploaded docs) stay as files.
  This charter covers **agent state**: sessions, messages, tool calls, memories,
  summaries, skills index/content, turn metrics.

## Success criteria

1. RaamsesAgent runs an interactive session end-to-end with Postgres as the only
   session/memory store. `state.db`, `sessions/*.jsonl`, and markdown memory files
   are no longer read or written.
2. Per-turn context assembly = exactly one call: `sp_build_context(session_id,
   token_budget)`. Returns system-prompt fragments + relevant memories + skill
   headers + rolling summary + recent turns, already trimmed to budget, in order.
3. All writes go through stored functions: `sp_append_message`, `sp_log_tool_call`,
   `sp_compact_session`, `sp_upsert_memory`. Application code contains no raw SQL.
4. Compaction is transactional — a crash mid-compaction leaves history intact.
5. Every turn logs `db_ms` / `model_ms` / `tool_ms` to `turn_metrics`. A benchmark
   script replays a fixed 50-turn transcript on stock Hermes and on RaamsesAgent
   and prints the comparison. Ship the numbers even if unflattering.
6. Existing Hermes tests still pass, plus new tests for each stored function.

## Schema v1 (Phase 1, migrations as plain SQL files)

`sessions` · `messages` (parent_id → free session branching) · `tool_calls` ·
`summaries` · `memories` (embedding vector) · `skills` · `turn_metrics`
Every table: `session_id` + `created_at`. Postgres 16 + pgvector in Docker
(`docker-compose.yml`, Windows variant exists).

## Stored functions v1

- `sp_build_context(session_id, token_budget)` — the money function; one ordered
  result set, pre-trimmed to budget. One round-trip per turn instead of five.
- `sp_append_message`, `sp_log_tool_call`, `sp_upsert_memory`,
  `sp_compact_session` (transactional), `sp_recall(query_embedding, k)` —
  pgvector; tsvector full-text fallback when no embedding provider configured.

## Architecture rules

- **Repository layer**: one Python module, one function per stored proc, psycopg3
  with a connection pool. Application code never touches SQL.
- **Feature flag**: `storage.backend = hermes | raamses` so stock and Postgres
  paths run side by side during the port.
- **Port order**: session store → memory → compaction, each swap its own commit
  (per-swap PR) with a passing test suite via `scripts/run_tests.sh`.
- Embeddings come from whatever provider Hermes already has configured; no new
  provider work in v1.

## Phases

| # | Phase | Status |
|---|-------|--------|
| 0 | **Map** — inventory every place Hermes reads/writes state (state.db, sessions/, memory files, skills, compression) with file:line. No code changes. | **DONE** — 2026-09-07, 4-agent recon; write-up: docs/phase0-inventory.md |
| 1 | Schema — tables, stored functions, migrations, Docker Postgres 16 + pgvector | |
| 2 | Repository layer behind `storage.backend` flag | |
| 3 | Port session store → memory → compaction (one swap per commit, tests green each time) | |
| 4 | Benchmark — replay 50-turn transcript, stock vs RaamsesAgent, publish db_ms/model_ms/tool_ms split | |

## Benchmark honesty

The agent loop spends 90%+ of wall-clock waiting on the model. The genuine wins to
measure are round-trip count for context assembly, recall quality/latency, and
crash safety of compaction — not total turn time. `turn_metrics` exists so the
table decides, not the narrative.

## Decisions (2026-09-07; recommended defaults adopted pending user confirmation)

1. **Memory port shape**: Postgres REPLACES the builtin file MemoryStore internals —
   single store, no dual-write (the goal is zero `MEMORY.md` reads). `memories`
   table + `sp_upsert_memory`; the external-provider ABC stays untouched for
   third-party providers. Snapshot semantics preserved: entries frozen at load,
   reload only at compaction.
2. **Skills scope**: index + usage/curator ledger + search in Postgres; SKILL.md
   *content* stays on disk as authored files, loaded once per session (charter
   lean, confirmed by Phase 0 recon: content is loaded once/session; the mutable
   agent state is the ledger). `skills` table = registry/index; sidecar files
   (`.usage.json`, `.curator_state`, `.curator_suppressed`, `.archive/`) migrate
   into it.
3. **v1 cut scope**: brain state only — sessions/messages/compaction/memories +
   `turn_metrics` + `sp_build_context`. Cron/kanban/plugin-data are Phase 3+
   extensions (inventory rows already filed in docs/phase0-inventory.md §5).
4. **Branch strategy**: charter/planning commits land on `main`; each port swap
   gets its own branch + PR to keep `main` mergeable with upstream.

## Open questions (remaining)

1. Does Raamses.io / Texsean/Raamses (existing CYD/Ramses codebase) integrate with
   RaamsesAgent, or is this brand reuse only? (Asked 2026-09-07, unanswered.)
