# Phase 0 — State-Layer Inventory (COMPLETE, 2026-09-07)

Method: 4 parallel read-only recon agents over the fork at upstream v0.21.1. No code
changed. Every row cites `file:line` in the repo. This page is the map; the four
per-area reports (sessions, memory, skills+compression, assembly+other state) are the
appendix sources.

## The shape of the thing

Hermes state is NOT mostly markdown today — it is one SQLite database plus scattered
files:

- **SQLite**: `<hermes_home>/state.db` — sessions, messages, tool calls, FTS5 index,
  system prompts, usage, state_meta kv, gateway leases. Only path control is
  `HERMES_HOME` (hermes_state.py:156 `DEFAULT_DB_PATH`); no db-path config key.
  All ~28 `hermes_state*.py` mixin modules' SQL funnels through **5 executor
  functions**: `_execute_write/_write_sql/_write_rowcount` (hermes_state.py:773-886)
  and `_read_one/_read_all` (hermes_state.py:896-901). Connections open only in
  `_connect_and_init/_open_writer/_connect_read_only` (hermes_state.py:488-615).
- **The "markdowns"**: `memories/MEMORY.md` + `memories/USER.md` (agent + user
  profile), and the `SKILL.md` trees + sidecars. These are the literal markdown
  stores the port kills.
- **Other file state**: `sessions/*.jsonl` (fallback transcript, DB-down only —
  hermes_state.py:297-305), cron `jobs.json` + jsonl ledgers, kanban `.db`/`.md`,
  plugin-data, gateway `sessions.json` mirror.
- DDL single source: `SCHEMA_SQL` in hermes_state_common.py (tables: schema_version
  :270, system_prompts :274, sessions :279, messages :342, session_model_usage :369,
  state_meta :391, gateway tables + leases/locks :396-488, indexes :490-529; FTS5
  `messages_fts` :554 + trigram/CJK variants :676/:759/:788). Version tracked in
  hermes_state_schema.py:846-961; migrations :874-942.

**Consequence for the port**: `SessionDB` (hermes_state.py:327) is one facade whose
public methods ARE the session-store API. Reimplementing those methods over stored
functions — via the 5 executors as the single swap seam — converts the whole session
domain at once. App code above the facade barely changes. Phase 2's job is that
facade swap, not a call-site-by-call-site port.

## 1. Sessions + transcripts (state.db)

| What | Where (file:line) | Notes |
|---|---|---|
| create session / ensure | hermes_state_sessions.py:271 (`_insert_session_row`), :362-367 | number + next-session-number maintenance |
| end / reopen | hermes_state_sessions.py:429-445 | end_reason first-wins (run_agent.py:979) |
| activity stamp / get | hermes_state_sessions.py:549-734 | `effective_activity` expr |
| archive / read flags | hermes_state_sessions.py:831-886 | |
| rich list / search | hermes_state_sessions.py:1168, :1343-1379 | `/sessions`, `/resume`, session search |
| delete / archive batch | hermes_state_sessions.py:1445, :1571 | also unlinks `sessions/<sid>.jsonl` :1417-1433 |
| append batch (turn flush) | agent/session_persistence.py:204-208 → `SessionDB.append_messages_batch` | the one per-turn write choke |
| context read | hermes_state_messages.py:732-756 (`get_messages_as_conversation`), :842 | `sp_build_context` analogue |
| destructive rewrite | hermes_state_messages.py:439-508, :998 | replace/rewind — compaction, `/rewind`, resume-forks |
| FTS5 read path | hermes_state_search.py:859-879, :1053-1116 | trigram/CJK fallback routing |
| jsonl fallback writer | hermes_state.py:297-305 | gateway divert + persistence flush, DB-down only |

Callers (row lifecycle): create run_agent.py:319-349; close run_agent.py:979-991;
per-turn persist agent/session_persistence.py.

## 2. Memory subsystem (the first full markdown kill)

| What | Where (file:line) | Notes |
|---|---|---|
| files | `memories/MEMORY.md`, `memories/USER.md` | GLOBAL per profile, NOT per-session (target map tools/memory_tool_store.py:161-164; dir tools/memory_tool.py:38-40) |
| format | tools/memory_tool_store.py:22 | flat `\n§\n`-delimited entries; NO headers in file (headers only in rendered block :19-20, :357-363) |
| parser + snapshot | tools/memory_tool_store.py:111-133 (read :366-381, split :383-386), :340-343 | frozen snapshot at load; reload only at compaction (system_prompt.py:677-695) |
| mutation path | tools/memory_tool_store.py:190-212 (`_mutate`), :394-401 (`_write_file`) | file lock sidecar `.lock` :137-159; `.bak.<ts>` drift guard :403-417 |
| tool wiring | tools/memory_tool.py:317-326 (register); agent/inline_tool_executors.py:113-133 | runtime store = `agent._memory_store` :120; write gate :99-108 |
| out-of-band writers (bypass the store!) | hermes_cli/web_routers/ops.py:467-486, agent/learning_mutations.py:59-63, hermes_cli/agent_import.py:361 | DB store must intercept these or they diverge |
| prompt injection | agent/system_prompt.py:459 (`_memory_parts`), format_for_system_prompt store:340-343 | first-prompt build only; mid-session writes never reach live prompt |
| provider ABC | agent/memory_provider.py:58-166 (`MemoryProvider`) | required: name/is_available/initialize/get_tool_schemas; everything else optional; ONE external provider max (memory_manager.py:332-340) |
| discovery | plugins/memory/__init__.py | bundled → `$HERMES_HOME/plugins` → `./.hermes/plugins` → pip entry point `hermes_agent.memory_providers`; loaded only at agent_init.py:1282 |

Key facts: no `BuiltinMemoryProvider` class exists — builtin is a plain `MemoryStore`
object, so "provider" ≠ builtin files. **No keyword/FTS/vector recall exists over
builtin memories today** — `sp_recall` is greenfield, not a replacement. Budgets:
memory 2200 / user 1375 chars (config-mutable). `session_search` is transcript
recall — different subsystem, already SQLite.

Files that stop being read/written under the swap: `MEMORY.md`, `USER.md`,
`*.lock`, `*.bak.<ts>` (+ the 3 out-of-band writers above).

## 3. Skills + compression

| What | Where (file:line) |
|---|---|
| skill dirs | get_skills_dir hermes_constants.py:1084 (profile, write target); optional-skills :255; union get_all_skills_dirs agent/skill_utils.py:393 |
| parse | agent/skill_utils.py:100 (frontmatter), :725 (desc); validation tools/skill_manager_tool.py:130 |
| read tools | tools/skills_tool.py:176/187 (discovery), :237 skills_list, :368/:519 skill_view + linked files |
| write tools | tools/skill_manager_tool.py:881 skill_manage (create :392, edit :418, delete→`.archive/` :485, write_file :527, remove_file :553, write gate :581) |
| ledger sidecars | `.usage.json` tools/skill_usage.py:49-54 (flock r-m-w :57-66, active→stale→archived :33), `.curator_suppressed` :178-184, `.curator_state` agent/curator.py:37-38 |
| plugin skills | hermes_cli/plugins.py:1138 registry, :1441/:1446/:1467 handles, :1559 discovery |
| system-prompt injection | agent/system_prompt.py:298 → :310 → agent/prompt_builder.py:1195/:1332; snapshot cache prompt_builder.py:1065-1079 (avoids rescans) |
| summarizer | agent/context_compressor.py:3315 (summary prompt), :4587 (compress); rolling summary carried as a message row |
| compaction orchestration | agent/conversation_compression.py:992; commit fence begin :466 / in-flight :490 / watermark :515; micro-compaction agent/micro_compaction.py:36 (defrag :158-162, DB sync :343-352) |
| **the transactional primitive** | hermes_state_messages.py:508-568 `archive_and_compact` — lease pre-check :531-535, single txn: watermark rewind, `UPDATE active=0/compacted=1`, INSERT summary carrier row, recount; runs under `_execute_write` BEGIN IMMEDIATE (hermes_state.py:773-800) |

`sp_compact_session` replaces `archive_and_compact`; its callers are
micro_compaction.py:352 and the full-compaction commit path. Read paths depend on
`messages.active/compacted` flags (hermes_state_common.py:61-74 preview SQL;
hermes_state_sessions.py:739 resume JOIN) and `session_turn_leases` — the stored
proc must preserve both semantics.

## 4. One-turn context assembly (where sp_build_context slots in)

Steady interactive turn (system prompt already cached in RAM):
- ~1 sqlite read (session row: conversation_loop.py:641/657 → `get_session`) +
  ~2 writes (upsert + persist: turn_context.py:598, :757). **Zero filesystem
  reads.**
- Everything else is RAM: history in cli.py:2816, tool schemas from registry
  (turn_request_assembly.py:191), messages built at turn_context.py:949
  (`build_api_messages`).
- First turn of a session: 6-10 one-time disk reads building the system prompt
  (system_prompt.py:604-727: skills headers :298, memory block :459, SOUL.md,
  AGENTS.md/context files, env/tz probes, tool-description block :727), then the
  prompt persists into the sessions row and is cached.
- Trim decision: turn-start gate turn_context_compaction.py:128/229 → pre-API gate
  turn_preflight_gate.py:20 → decider context_engine.py:84/97 (protect-first/last
  windows, summary_target_ratio; thresholds wired at agent_init.py:1842-43). Only
  the message list shrinks; system prompt never trimmed; window growth first
  (conversation_loop.py:403).

Assembly intercept list: turn_context.py:774 (per-turn orchestrator), :949
(request builder), turn_context_compaction.py:128/229, turn_preflight_gate.py:20,
context_engine.py:97, conversation_loop.py:403, turn_api_call.py:61 (model call).

## 5. Other file-backed state (cron/kanban/plugin — Phase 3+ candidates)

| Store | Format | Where | Verdict |
|---|---|---|---|
| cron jobs + runs | json / jsonl | cron/jobs.py:70-71 (save :1378-79, load :979); delivery_queue.py:163; scheduler.py:715/:1007/:3180-81; executions/incidents/occurrences/ledger/notepad modules | IN-SCOPE (agent state) — later phase |
| kanban | sqlite + json + legacy .md | hermes_cli/kanban_db.py:3/:395/:453-470; legacy kanban_boards.py | IN-SCOPE — later phase |
| plugin persistence | json/sqlite | plugins/plugin_storage.py:27-41 (`plugin-data/<name>/`) | IN-SCOPE — later phase |
| approvals | in-memory only + config.yaml | tools/approval.py:172-262, :806-982 | nothing file-backed; no migration needed |
| gateway mirror | json | gateway/mirror.py:18, hermes_state_gateway.py:204/:384 | rides sessions domain |
| cron heartbeat markers, run-output files | text | cron/jobs.py:76-77, monitor.py:83 | OUT (ephemeral/logs) |
| config.yaml, .env, logs, uploaded content | files | — | OUT per charter |

## 6. Intercept-point summary (the seams a repository layer stands in front of)

1. SessionDB executors — hermes_state.py:773-886 (writes) + :896-901 (reads):
   swap here = swap all ~28 mixin modules at once.
2. Per-turn flush choke — agent/session_persistence.py:204-208.
3. Session create/close — run_agent.py:319-349, :979-991.
4. Context read — hermes_state_messages.py:732-756/:842 (becomes sp_build_context).
5. Compaction primitive — hermes_state_messages.py:508-568 + callers
   (micro_compaction.py:352, conversation_compression.py:992) (becomes
   sp_compact_session).
6. FTS search — hermes_state_search.py:859-1116 (becomes sp_recall / tsvector).
7. Memory file layer — memory_tool_store.py:111-133/:190-212/:394-401 + the 3
   out-of-band writers (becomes memories table + sp_upsert_memory).
8. Skills read/write + ledger + injection snapshot — skills_tool.py,
   skill_manager_tool.py, prompt_builder.py:1065-1079 (index+ledger table).
9. First-prompt build — system_prompt.py:604-727 (one-time 6-10 reads/session).
10. Assembly gates — turn_context.py:774/:949 et al. (sp_build_context consumer).

## Phase 0 exit decisions (see GOAL.md open questions)

- Skills content-in-DB vs index-in-DB → decision asked of user (lean: index in DB,
  content stays on disk as authored files).
- Memory port shape: DB replaces builtin MemoryStore files vs ships as external
  provider → decision asked of user (lean: single store, replace the files).
- Scope of the v1 cut: brain state only (sessions/messages/compaction/memories)
  vs + cron/kanban → decision asked of user (lean: brain state first — it is what
  the benchmark exercises).

## Appendix: recon source reports (machine-local)

Sessions: subagent-summary-0-20260907_181616_405611.txt
Memory:  subagent-summary-1-20260907_181616_417781.txt
Skills/compression: subagent-summary-2-20260907_181616_422687.txt
Assembly/other: inline in dispatch result + live log task-3.log (deleg_28b4b409)
under `C:\Users\SCR\AppData\Local\hermes\cache\delegation\`.
