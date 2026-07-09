# CHANGELOG

All notable changes to CAST are documented here. This project adheres to [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## [Unreleased]

_Nothing yet._

## [9.5.2] — 2026-07-09 — maintenance fixes (evening audit remediation)

Same-day follow-up to v9.5.1: an evening `/cast-audit` re-run (**0 HIGH after adversarial verification — third consecutive zero-HIGH audit**) plus remediation of every actionable finding it and the `/doctor` pass surfaced. Every unit individually code-reviewed; landed as one batched commit (per-unit commits were blocked by the plugin-drift × commit-hatch guard collision this release also fixes).

### Fixed
- **`cast-validate.sh` stale FTS5 check.** The doctor check validated the dead pre-B2 `agent_memories_fts` table and suggested an obsolete migration; it now checks `record_fts` (the table the B2 memory router actually uses) with a correct remediation hint.
- **Stale-run reaper cadence.** `com.cast.abandon-stale-runs` ran once daily at 04:00 while its staleness threshold is 2h, so stuck-`running` `agent_runs` rows sat visible up to 24h (the recurring "stuck rows WORSENED" audit alarm was this cadence mismatch, not a leak). Now `StartInterval 7200`.
- **`cast-git-guard.py` composed-hatch regexes.** `_COMMIT_ALLOW`/`_STASH_ALLOW` didn't tolerate additional `VAR=value` assignments between the hatch var and `git` (unlike `_PUSH_ALLOW`), making sanctioned hatches impossible to compose (e.g. `CAST_COMMIT_AGENT=1 CAST_SKIP_PLUGIN_DRIFT=1 git commit`). Discovered live when it blocked this release's own commit pipeline. 3 regression tests.

### Hardened
- **`cast-db-backup.py` retention.** Existing 7-daily/4-weekly retention gained `CAST_SNAPSHOT_KEEP` override, refuse-if-keep<1, strict filename-pattern + parent-dir containment before any delete, `-wal`/`-shm` sibling cleanup, and verify-new-snapshot-before-prune (fail-closed: on any doubt, skip pruning).

### Performance
- **SubagentStart hook: 3 python3 cold-starts → 1** (tab-separated single-spawn extraction); **SessionStart hook: 4 → 3** (the two unconditional hot-path spawns merged; conditional/differently-sourced spawns left intact). Zero behavioral drift, verified by review + 24 existing BATS tests.
- **Migration 031: `idx_agent_runs_started_at`** — `cast-record-review.py`'s 21-day cost-trend query no longer full-scans `agent_runs`. Mirrored in `cast-db-init.sh` (single source of truth). `cast-migrate.py` gained a narrowly-scoped `CREATE INDEX`+`no such column` idempotency-fallback branch (the same class any future index migration would hit).

### Added
- **3 new test suites (26 cases)** for previously-untested v9.5.1 surfaces: `cast-stale-memories.py` (9 — including the indented-`verified_at` parser-regression fixture), `.githooks/post-commit` (7 — fail-open contract proven: commit exits 0 across missing/crashing recorder and escape hatch), `cast-memory-dream-review.py` (10). Suite: 2300 → **2338** @tests / 203 files.
- **otel-collector chunked-framing regression test.** The evening audit's one HIGH candidate ("parse errors persist post-fix") was **refuted** by restart-boundary analysis — errors stop at exactly the first restart on `d86578e`'s fixed code, zero since; the failure signature is now pinned by a parser-level test.

### Audit / process notes
- Evening audit corrected two morning-report claims via live probes: the OTEL feed is **live** (+3.7k rows/day; "stopped 2026-07-02" was wrong — cast.db retention decision reopened) and the B3 dream pipeline was only half-untested (promote had 11 tests).
- Deferred with rationale (backlog): egress-sentinel TODO tracking (classifier denied issue-creation this session), cold-start hotspots in non-hot-path scripts (`cast-exec.sh`/`cast-upgrade-check.sh`/`cast-managed-agent.sh`), the ~40% script-coverage ratio, `12-otel.json` contradictory telemetry env pair, `eval-runner shell=True` (documented accepted risk).

## [9.5.1] — 2026-07-09 — v9.5 close-out (maintenance)

A same-day maintenance pass closing out v9.5: a fresh `cast-audit` (second consecutive zero-HIGH audit), memory-state reconciliation, and the fixes that audit and the first B5 record-review surfaced. No new capability — hardening, correctness, and the two long-pending D5 provenance fixes.

### Added
- **`.githooks/post-commit` — the D5 provenance recorder (finally shipped).** Records `commit_provenance` automatically on every in-session (`CLAUDECODE=1`) commit — the symmetric counterpart to the pre-push provenance gate, so commit-agent truncation or a classifier outage can no longer skip the record and cause a false pre-push block. Idempotent (`INSERT OR IGNORE`), always `exit 0` (never blocks the commit), no `CLAUDE_SUBPROCESS` guard-out (the commit agent is a subagent — exactly where the miss occurred). Human-terminal commits are silent no-ops. Approved by code-reviewer + security and live-verified recording its own commits.
- **Manifest-based agent-prune in `install.sh`.** Installs now track the set of CAST-installed agent basenames and remove agents retired from the roster on the next install, while never touching hand-made agents absent from the manifest. Closes the drift that left the P6-retired `perf-sentinel.md` lingering live (23 installed vs 22 canonical). Path-traversal-hardened on the manifest read.

### Changed
- **`commit` agent: classifier outage is now a HARD BLOCK.** A transiently-unavailable safety classifier makes the commit agent stop and report `BLOCKED`, never self-authorize the `CAST_COMMIT_AGENT=1` escape hatch. `CAST_COMMIT_AGENT=1` presupposes an already-passed gate; classifier-unavailable ≠ classifier-approved.

### Fixed
- **Stale-memory count unified.** `cast doctor` reported "none" while the SessionStart health surface reported ~12 — same stated definition, divergent results, because `bin/cast` matched `verified_at:` without stripping leading whitespace (the field is indented under `metadata:`). A shared `scripts/cast-stale-memories.py` scanner now backs both surfaces; they always agree (14). The distinct `confidence < 0.4` metric in `cast status` is intentionally left separate.
- **Record-review hallucination over-count (~30×).** The B5 record-review counted every `agent_hallucinations` row — including `verified=1` confirmed writes — as a hallucination, inflating `code-writer`'s file-write "hallucination" rate to ~86%. Added `AND verified = 0` (the true rate is ~3%, matching `cast doctor`), making the report's Mine→Propose section trustworthy.

### Performance / Hardening
- **Session distiller bounded read.** `cast-session-distiller.py` capped transcript reads at 20 MB (`CAST_DISTILLER_MAX_BYTES`) with JSONL-safe tail-truncation, removing an unbounded `f.read()` on SessionEnd transcripts that can reach 50–80 MB.
- **eval-runner `shell=True` documented as accepted-risk.** Investigated switching to `shell=False`; the grader corpus legitimately uses shell features (`|`, `&&`, `;`) across 10+ templates, so the existing `$`-expansion-rejection guard + `shlex.quote` on all substituted values (committed-template, non-runtime-user input) remain the mitigation, now documented inline.

### Investigated (no code change — documented finding)
- **`agent_runs.model` unreliability root-caused.** Pre-2026-07-02 rows with a NULL `agent_id` reflect the *main-loop* model bleeding in (no transcript was resolved), not the subagent's model — e.g. the haiku `commit` agent logged as `"sonnet"`. A blanket alias→resolved-ID backfill would corrupt these rows; the forward capture path is already correct now that `agent_id` is consistently supplied. The B5 model-tier proposals that compared a model against itself stay rejected.

## [9.5.0] — 2026-07-09 — The Record Runs the System

v9.5 is the last release under the optimization-sprint framing that began at v9.0 — after this, CAST enters maintenance mode. The theme: v9 built the record; v9.5 makes the system run on it. Three routines close the loop: a weekly memory-consolidation pass that was scheduled nowhere before, a main-loop model change that cuts the cost of everything Workflow-shaped inherits, and — the release's thesis — a weekly report that mines the record for its own maintenance and asks a human to approve or reject each line.

### Added
- **`cast-record-review.py` — the record-review loop (B5):** a read-only weekly report (`~/.claude/reports/cast-record-review-<date>.md`, launchd `com.cast.record-review`, Sundays 07:00, folding in a monthly deep pass on the first Sunday) across four sections — measure→tune (cost-per-success by agent×model, truncation rates, ceremony-mix drift), mine→propose (drafts eval cases from recurring `agent_hallucinations` / `agent_protocol_violations` patterns), friction mining (correlates hatch/override events against immediately-preceding guard blocks to surface false friction), and trend→alert (silent-producer detection, stale-run trend, cost-per-session trend). Every DB connection opens SQLite `mode=ro` — the script cannot write to `cast.db`. Nothing acts automatically; a human accepts or rejects each proposal and accepted ones land as normal reviewed units. The first report ran the day it shipped: 32 proposals from real 7-day data, two accepted and merged within hours — a `maxTurns` retune for `code-writer`/`code-reviewer` (both truncating at ~14% of runs) and a mandatory File Write Verification guard addressing CAST's single most common recorded hallucination (276/week — `code-writer` claiming a write a stale read never confirmed). The report also caught its own blind spot: it flagged that `agent_runs.model` mixes alias labels (`"sonnet"`) and resolved model IDs (`"claude-sonnet-4-6"`) for the same underlying model, and told the reader not to act on 8 of its own model-tier proposals until that's fixed first.
- **Confidence-gated memory lifecycle, scheduled (B3):** `cast-memory-consolidate.py` (decay/dedup/archive/promote) existed but ran on no schedule. It's now a weekly launchd job (`com.cast.memory-consolidate`, Sundays 05:30, ahead of the record-review pass) with its own fail-closed pre-run backup gate. Decay is now injection-usage-aware instead of age-only. Closed a 36-of-216-memory indexing gap where daily maintenance embedded memories but never wrote them into `record_fts` — the B2 injection path was silently unable to serve them.
- **Push-hatch audit logging:** the `CAST_PUSH_OK=1` escape hatch had no audit trail, unlike the equivalent commit hatch. `PUSH_HATCH_USED` events now write to `~/.claude/logs/audit.jsonl` — the first proposal B5's friction-mining section surfaced, shipped same day.

### Changed
- **Main-loop default → Claude Sonnet 5 (B6):** `managed-settings.d/16-model-defaults.json` now pins `claude-sonnet-5` (the explicit model ID, not the `sonnet` alias, so it can't silently drift) as the main-loop model — $2/$10 per million tokens against Opus 4.8's $15/$75, at documented near-Opus capability. Because Workflow/Explore/Plan/general-purpose subagents inherit the main-loop model, this directly targets the cost driver the B4 agent audit found: `workflow-subagent` was 64.6% of all recorded agent cost, roughly 69% of it Opus-by-inheritance. Effort default also stepped down from `xhigh` to `high` — Sonnet 5's documented default; `xhigh`/`max` stay reachable per session.
- **`maxTurns` +25% for `code-writer`** (80→100) **and `code-reviewer`** (40→50), plus the File Write Verification section in `code-writer`'s definition — both direct outputs of the first record-review report, not a guess.
- **Version → 9.5.0** (VERSION, `cast-stats.json`, plugin manifest). Maintenance mode begins: from here, changes need a case — bug fixes, the monthly audit and its remediation, security fixes, dependency/CI keep-green, and whatever the record-review loop proposes and a human accepts.

## [9.0.0] — 2026-07-01 — The Record That Acts

v9 is the release where CAST stops being write-only and starts *acting* — the record that built itself now informs the next decision. Five command tiers (`cost`, `predict`, `ask`, `feature`, `mcp`) read back from `cast.db` to shape agent routing, workflow composition, and cost analysis; a tamper-evident provenance chain guards the decision ledger; and an egress-audit log records the full surface of what left the machine. Ceremony right-sizing by blast radius matured the safety gates without loosening the ones that matter, and dead subsystems (`/swarm`) plus dead code were purged to sharpen the portable core. This is a major release: the canonical `cast.db` table count moved from 41 to 38, and the version bump reflects the new command surface.

### Added
- **`cast cost --by-task` / `--by-branch` / `--by-agent` (+ `--json`):** cost attribution reading the existing cost pipeline; reports tokens and dollars per unit of work; branch captured into `agent_runs` (F1).
- **`cast predict`:** record→decision loop — reads past `dispatch_decisions` outcomes plus per-agent success/cost to suggest routing and recall prior incidents. `cast.db` stops being write-only (F2).
- **`cast ask`:** FTS5 full-text search over the whole `cast.db` record (`--json`), scoped to a session or the entire ledger (A3).
- **`cast feature "<description>"`:** app-build Workflow engine — stack-adaptive decompose → per-unit gated build under the writer/reviewer discipline; predict/cost bookends; **never pushes** (F3).
- **`cast mcp serve`:** `cast.db` as a read-only MCP server — local stdio server (Python **stdlib only, no SDK dependency**), `mode=ro`, no arbitrary-SQL; 5 tools (decisions/incidents/cost/sessions/ask) + 5 resources; register with `claude mcp add cast-record -- cast mcp serve` (F4).
- **`cast ledger`:** signed per-session audit receipt (SHA-256, `--verify`, `mode=ro`) (A5).
- **`cast verify-chain` / `cast provenance`:** session-digest hash-chain over ledger digests — tamper-evident, never pruned, hardened against an empty-chain bypass (A7).
- **Egress Audit Record (log-only):** a PreToolUse egress sentinel logs WebFetch/WebSearch/MCP/Bash egress to `logs/egress.jsonl` (honest advisory log-only; MCP classified by server name). A managed-sandbox lockdown config was added but is documented as **INERT on macOS 26.5.1 / CC 2.1.195** (the sandbox engagement gate short-circuits) — the egress hook is the live audit layer (A1).
- **`cast doctor` model-retirement check (C9):** warns if a dispatched Claude tier (opus/sonnet/haiku) is absent from `/v1/models` (advisory, fail-open; no network call when `ANTHROPIC_API_KEY` is missing).

### Changed
- **The "record that acts" thesis — convergence audited against CAST itself** (the convergence-floor analysis): the durable value of the record is its cross-surface joins and governance-semantic content, established through a Phase-V audit (0 P0, 9 P1) (F5).
- **Ceremony right-sizing by blast radius (P-trust):** introduced an **Inline tier** — the main session may apply trivial doc/comment/non-protected-config edits inline (no specialist dispatch, no `code-reviewer`) when strict blast-radius criteria hold; everything touching code, enforcement/security/destructive config, the §1 hard-won core, or a guarding test keeps the full dispatch + `code-reviewer` (+ `security`) ceremony. Record-feeding cast.db hooks, irreversibility gates, the `commit` agent, destructive-test containment, and `test-runner` isolation are never relaxed (Subtraction Safety Gate).
- **`rules-core` byte-budget gate → advisory (P-trust):** `cast-lint-byte-budget.sh` reports the always-loaded rules size with an `ADVISORY` nudge but no longer blocks a commit (the hard limit was forcing lossy compaction of hard-won rules text).
- **`cast doctor` MCP check enumerates all local scopes** — settings.json + settings.local.json + `$PWD/.mcp.json` (Option-B).
- **Version → 9.0.0** (VERSION, `cast-stats.json`, plugin manifest). A self-maintaining `CAST_TEST_FILE_COUNT` stat replaces the previously hand-typed README test-file count.

### Removed
- **Retired the dormant `/swarm` subsystem** (B1): removed the `/swarm` skill, the `cast-swarm-{bootstrap,merge,teardown}` scripts, `swarm-configs/`, `docs/swarm.md`, and the swarm BATS tests. The `swarm_sessions` / `teammate_runs` / `teammate_messages` tables are retained as dormant historical record (the record is the product) — only the writers were removed, no `DROP TABLE`. All §1 containment guarantees were re-anchored to general guard tests before any deletion (Subtraction Safety Gate). Forward path: native `isolation: worktree` subagents + (experimental) Agent Teams.
- **Retired 3 writerless cast.db tables from canonical** — `stream_events`, `teammate_messages`, `code_ref_checks`; the canonical table count is now **38** (was 41). Tables kept dormant on the live DB; no `DROP TABLE`.
- **Removed dead code:** `cast-research-cache.py` (Claude Code's native WebFetch in-session cache covers it) and `cast-token-budget-check.py` (no wiring; native context indicators cover it).

### Fixed
- **★ Security — `CLAUDE_SUBPROCESS` guard-bypass (U6):** the PreToolUse guard skipped the git commit/push/stash and `rm -rf` destructive-command checks when `CLAUDE_SUBPROCESS=1` (set for every dispatched subagent) — so any subagent could bypass the irreversibility guards. Those guards are now hoisted **above** the subprocess skip in all paths; escape hatches preserved.
- **Fail-closed redaction** in dispatch and incident recording (a `[REDACTION_FAILED]` marker is stored, never the raw payload).
- **MCP server correctness:** connection-leak fix, unknown-tool → JSON-RPC `-32602`, and `initialize` protocolVersion negotiation.
- **F2 `dispatch_decisions` capture:** the hook matched tool name `Task` while the runtime names it `Agent`, so capture was silently dead — fixed and verified live.
- **Policy-gate completion-recording (P-trust):** review agents (`devops`/`security`) now write a per-agent completion record, so `block`-severity policies clear on a genuine reviewed `DONE` and stay blocked on `BLOCKED`/truncated reviews. The hard block is preserved.
- **Test-safety sweep:** temp-HOME isolation for tests that wrote the real `$HOME`; SQL-identifier hardening; GUI-side-effect shims; redaction-fixture PII hygiene.

## [8.0.0] — 2026-06-15 — Native CAST

v8 is a convergence release — *less bespoke, more platform.* CAST retires custom code where Claude Code now ships a native primitive, and ships as a native **plugin** (the breaking change behind the major bump). It is organized around two differentiating pillars: **local-first by construction** and **data integrity by construction**, both earned from repeated full `~/.claude` wipe incidents.

### Added
- **Native plugin packaging (dual-ship):** CAST ships both (a) a committed `plugin/` artifact installable via `claude --plugin-dir plugin` and (b) a marketplace-distributed plugin (`/plugin marketplace add ek33450505/claude-agent-team` → `/plugin install cast` → `/plugin enable cast@cast`). Both paths serve the same curated surface; `install.sh` stays authoritative for the runtime layer, and the `cast-hook-owner` sentinel prevents double-firing when both coexist. All native surfaces (agents, skills, slash commands, `command`-type PreToolUse hooks, stdio MCP with `${user_config.*}`, SessionStart bootstrap) are plugin-loadable. `claude plugin validate --strict` is wired into CI via the plugin drift gate. The curated build ships **17 lean agents** (+4 opt-in extras via `--with-extras`; `push`/`morning-briefing` excluded) of the 23 in the full install.
- **Data-integrity stack (Pillar 2):** Litestream continuous replication of `cast.db` to `~/Library/Application Support/cast/` (outside the `~/.claude` blast radius) + dated snapshots; the wipe canary relocated off the blast radius; a fail-closed migration backup-gate (`cast-migrate.py --confirm`); the `blast-radius-lint` ratchet; and a `cast integrity` read surface with a daily regression-aware monitor.
- **PreToolUse command-guard:** blocks `pkill`/`killall`/`kill -9` and `rm -rf` of protected roots from agents (the command-layer analogue of write-guards), exit 2, with `CAST_KILL_OK`/`CAST_RM_OK` escapes. Fires for native Agent-tool subagents.
- **Eval harness (`cast eval`):** an agent-behavior corpus mined from real CAST failures, three-outcome programmatic + LLM-judge graders, `pass@k`, and an `eval_runs` table — closing the largest documented gap versus Anthropic guidance. `cast eval run|list|report|record`; the `eval-writer` agent produces graders.
- **Typed Handoff contract:** `schemas/agent-handoff.json` (required `files_changed`/`status`/`blockers`) validated WARN-only in the SubagentStop hook (`cast_handoff_parser.py`), killing the silent-cascade-failure class.
- **Rules → on-demand skills:** language conventions (TypeScript, Python) demand-loaded as skills for plugin portability; behavioral and HARD-RULE files stay always-on (DUAL-KEEP).
- **Regenerable architecture diagram:** Mermaid source (`docs/architecture/cast-architecture.mmd`) + `scripts/gen-arch-diagram.sh`, replacing the hand-drawn SVG.
- **Plugin bootstrap smoke test:** `tests/cast-plugin-smoke.bats` proves the clean-machine bootstrap path (dirs, symlinks, `cast.db` init, 17 lean agents, idempotency, `plugin validate`) under an isolated temp HOME.

### Changed
- **Strategic pivot to "Native CAST":** v8 represents convergence toward Claude Code native capabilities (plugins, native agents, native skills, native hooks) over bespoke infrastructure. Remaining bespoke components (`cast.db`, SessionStart bootstrap, observability dashboards) stay in place where native equivalents don't yet exist.
- **Softened planner doctrine:** planning ceremony now matches task size — trivial → no plan; single-session → native plan mode (shift-tab); multi-file/multi-agent → the `planner`→`/orchestrate` chain. The fresh-context `code-reviewer` gate stays **mandatory**.
- **Portfolio README + architecture refresh:** the README leads with the two pillars and the full v8 surface; `docs/architecture/ARCHITECTURE.md` is rewritten to the v8 control plane.

### Fixed
- **protocol-spec:** reconciled stale `CLAUDE_SUBPROCESS` assumptions (the `agent-status-reader.sh` / §5.5 references) with the verified finding that native Agent-tool subagents run with `CLAUDE_SUBPROCESS` **unset**, so the enforcement guards fire for them.

---

## [7.4.1] — 2026-06-05

### Fixed
- `cast-parallel` `_db_log` silently dropped every parallel lifecycle event (passed nonexistent `--event`/`--message` flags to `cast-db-log.py`, which reads JSON from stdin); now pipes a valid `routing_events` JSON entry built via `json.dumps` with values passed through `os.environ`.

### Security/Safety
- **pre-push hook**: BATS test gate is now opt-in (set `CAST_RUN_BATS_PUSH=1`) and routes through the isolated `tests/run.sh` runner. Direct `bats tests/` invocation is the 2026-06-02 wipe vector (can delete `~/.claude/` if a test lacks proper isolation). Per the 2026-06-02 test policy, the full BATS suite is batched before releases, not gated per-push.

---

## [7.4.0] — 2026-06-05 — Audit, Convergence & Database Correctness

**Strategic focus:** Close out the security/recovery audit, settle `cast.db` as a single source of truth, and begin convergence toward native Claude Code — shipped as an accurate, release-ready cut.

### Security & Safety
- Emergency security hardening + PII scrub across hooks (#104)
- Removed the destructive test that wiped the live runtime; eliminated the worktree wipe vector and hardened the swarm-teardown `rmtree` guard (#106)
- Drove the 35 Docker-only BATS failures green (#108)
- git-agent reliability — `-C` guard tolerance + push-first ordering (#111)

### Database Correctness (cast.db)
- Endpoint hardening — silent-write fixes + phantom-table provisioning (#113)
- Settled `cast.db` to a single source of truth: `cast-db-init.sh` declares all 38 tables, idempotent init, `user_version=8` (#114)
- Systems-test pass — hook fixes, `cast-db-verify`, CI pins (#116)
- `cast-db-init.sh` made authoritative for `agent_runs.duration_ms` / `agent_runs.tool_uses` and `dispatch_decisions.outcome` (previously created only by runtime `ALTER`s); added a `cast-db-verify` C10 check so the drift cannot silently return

### Disaster Recovery
- Backup subsystem refresh (§3.9): on-disk dated snapshots (`cast-snapshot.py`, 7-day + 4-week retention) plus a version-controlled private GitHub overlay (`cast-overlay-sync.sh`), unified under `cast backup [--overlay]`, with a `cast doctor` backup-freshness check (#107). Deprecated the flawed release-asset backup (`cast-memory-backup.sh` → no-op stub)

### Native Convergence (Phases 9–15)
- Phase 9 + Phase 14 + phase3-tail fixes (#117)
- Convergence batch — Phases 9.5 / 10 / 11 / 12 / 15 (convergence markers + safe config; bespoke engines retained where native isn't ready yet) (#119)

### Documentation & Accuracy
- Phase 16a documentation audit + Anthropic job-search-readiness pass — 91 findings (#122)
- Regenerated the rules-core manifest after the convergence merge (#121)
- Removed the fictional "Agent Constellation Dashboard" from all docs; replaced with the real observability dashboards (claude-code-dashboard — React 19 + Vite + Express, ~21 cast.db-backed views; Cast Desktop — Tauri 2 native app, 11 views)

### Fixed
- SubagentStop truncation detector no longer false-flags workflow / built-in agents (`general-purpose`, `Explore`, `Plan`, …) that return StructuredOutput instead of a prose `Status:` block; real CAST roster agents are still checked

---

## [7.3.1] — 2026-05-26 — Literal-tilde Write Guard

**Strategic focus:** Mitigate an upstream Claude Code plan-mode harness bug that creates phantom literal-`~` directories under cwd when the harness joins a `~/.claude/plans/<name>.md` Plan File Info path with cwd before model dispatch (instead of expanding `~` to `$HOME` first).

### Added

- **`cast-tilde-write-guard.sh` PreToolUse hook** — blocks `Write`/`Edit` calls whose `tool_input.file_path` contains a literal `~` directory segment (e.g. `<cwd>/~/.claude/plans/foo.md`) and emits a corrective `$HOME`-prefixed path in stderr. Wired in `managed-settings.d/25-hooks-security.json` via the proven `matcher: "Write|Edit"` pattern (the bare `if: "Write|Edit"` form did NOT fire on plan-mode Write during validation — same pattern that works for `cast-stat-claim-guard`). Logs incidents to `~/.claude/logs/tilde-guard.log`. 7 BATS cases (`tests/cast-tilde-write-guard.bats`).

### Internal

- Local incident sweep (2026-05-26) found 26 phantom literal-`~` directories filesystem-wide and 7 trapped plan files (recovered to `~/.claude/plans/_recovered-tilde-bug-2026-05-26/`). Bug correlates with random-three-word plan filenames — older date-prefixed plans landed correctly, suggesting a concurrent upstream change in plan naming and path resolution. Upstream report pending at `github.com/anthropics/claude-code`.

---

## [7.3] — 2026-05-19 — Hook Safety & Observability Hardening

**Strategic focus:** Agent protocol reliability — enforce Handoff block contracts in multi-agent chains, prevent stale stash corruption in push workflow, and route API failures to dedicated observability table.

### Fixed

- **tool_call_failures table routing** — Agent API call failures are now routed to the dedicated `tool_call_failures` table in cast.db. Previously these errors were inconsistently logged or swallowed. Failure events are now queryable alongside other cast.db events for observability. (#82)
- **push-agent stash safety** — Blocked `git stash` operations at the hook layer to prevent the push agent from surfacing stale stashes from prior sessions. Also added PR lifecycle chain enforcement so the push agent cannot proceed past a dirty stash state. (#84)
- **agent Handoff block enforcement** — Safer baseline pattern for agent dispatch in multi-agent chains. Chains now enforce that every agent includes a `## Handoff` block (key-value pairs: `files_changed`, `status`, `blockers`) before passing context to the next agent. Prevents context loss in long orchestration chains. (#86)

### Internal

- Hook layer: stash guard script added to pre-push hooks.
- Agent definitions: Handoff block enforcement section added to multi-agent chain agents.
- cast.db schema: `tool_call_failures` table populated on agent API errors.

---

## [7.2] — 2026-05-17 — Post-v7.1 Cleanup

**Strategic focus:** Retire dead stub infrastructure, eliminate observability noise introduced by the v7.1 arc, and add regression coverage for the cast-doctor frontmatter scope fix.

### Fixed

- **Stop-hook spurious `hook_failures`** — removed `log_hook_failure` call for `agent_id` lookup miss in the truncation section of `cast-subagent-stop-hook.sh`. Root cause confirmed: `CLAUDE_SUBPROCESS=1` guard in the start-hook intentionally skips `agent_runs` writes for subprocess-mode agents; the stop-hook lookup miss was expected behavior, not a bug. 7 false-positive `hook_failures` rows from the 2026-05-16 session are now the last of their kind. (#80)

### Removed

- **`stream_hook_events` table retired** — 0 rows ever written, no writer, no reader. Removed from `cast-db-init.sh` (3 locations) and `cast_db.py` stub list. Migration 015 applied to live DB. (#80)

### Added

- **BATS regression test: cast-doctor frontmatter scope** — test 16 in `cast-doctor-expansion.bats` locks the v7.1 fix that skips uppercase files (e.g. `CAST_AGENT_CONVENTIONS.md`) during the agent frontmatter check. Prevents silent regression if the `if not fname[0].islower(): continue` guard is removed. (#80)

### Investigated / Documented (→ v7.3 backlog)

- **`compaction_events` confirmed healthy** — 452 rows since 2026-04-26; hook fires on every `/compact`. Minor data quality gap: `trigger` and `session_id` often `'unknown'` (PreCompact event JSON not fully surfaced via `CAST_INPUT`) → v7.3.
- **`agent_runs.prompt` NULL pattern** — 57% NULL in May 2026. Root cause: pre-`agent_id` INSERT path wrote `prompt`; new `agent_id`-aware paths don't. No current hook script writes `prompt` at SubagentStart time → v7.3.
- **`schema_migrations` dual-runner drift** — bash and python runners use incompatible schemas; migrations still apply correctly. Recommend porting python runner to bash schema format → v7.3.

---

## [7.1] — 2026-05-17 — cast.db Observability Remediation

**Strategic focus:** Observability hardening — wired silent-exception fallback logging, repaired schema drift in quality_gates, closed agent-truncation routing bugs, restored daily-briefing routine. Addresses 15+ findings from the 2026-05-16 audit (see [corrections file](~/.claude/plans/cast-agent-team-corrections-2026-05-16.md) for detailed evidence).

### Fixed

- **`log_hook_failure()` wired end-to-end** — all silent `except Exception: pass` blocks now route through `log_hook_failure()` in `cast_db.py:204`. Invisible hook failures surface in `hook_failures` table in real time. (#14)
- **`quality_gates` INSERT broken since migration 009** — column names mismatched with current schema (`gate_type` → `status_line`, old 5-column shape → new 8-column). Writes now land correctly with proper Status enum + contract_passed logic. (#7)
- **Stop hook mis-firing on main-session content** — precondition guard added; hook now exits early on `Stop` events (user responses), fires only on `SubagentStop` (agent terminations). Eliminates 81% of `agent_type='unknown'` false positives. (#8, #10)
- **`agent_truncations` now accurate** — agent_type lookup fallback extended to truncation-detection block; stalled agents are attributed correctly instead of as 'unknown'. (#10)
- **`agent_memories` schema drift** — `last_validated_at` and `retrieval_count` columns added via idempotent migration 013. Memory validation/consolidation sweeps no longer silently swallow `column not found` errors. (#2)
- **Daily-briefing routine restored** — underlying dispatcher failure from earlier schema change fixed; cron re-enabled and verified running successfully. (#19)
- **`compaction_events` writer re-enabled** — hook wiring verified and firing again after 8-day silence; compact operations now logged. (#15)
- **`injection_log` writer implemented** — memory-injection observability now functional; each fact injected to a prompt writes a scored row to `injection_log`. (#9)
- **Path-prefix validation in routines** — `cast-db-routines.py update-status` now validates `output_path` prefix before writing to DB; blocks writes outside `~/.claude/routines-output/`. (#22)

### Added

- **`docs/cast-db-schema-rationale.md`** — documents the three "dispatch" tables (hook_events vs orchestrate_invocations vs scheduled_dispatches), failure-tracking table pairs (truncations vs completeness_events; hallucinations vs code_ref_checks), and intentionally-dormant swarm tables. Cross-references audit findings. (#5, #6, #12, #21)
- **Migration 013** — `agent_memories` column additions, idempotent. (#2)
- **`cast-backfill-schema-migrations.py`** — one-time backfill of pre-009 migration history from filesystem + git log. Closes schema_migrations history gap. (#18)
- **Hook failure telemetry** — `hook_failures` table now populated; cast.db audit logs visible. Enables detection of future silent-exception bugs at observation time, not in post-mortem.

### Changed

- **`cast-subagent-stop-hook.sh`** — corrected column bindings in quality_gates INSERT; added SubagentStop precondition guard; extended agent_type fallback scope; wired log_hook_failure to 3 exception handlers. (#7, #8, #10, #14)
- **`cast-subagent-start-hook.sh`** — exception handler now routes through log_hook_failure. (#14)
- **`cast-memory-validate.py` + `cast-memory-consolidate.py`** — removed 10 silent-swallow blocks; all exception paths now log to hook_failures. (#14)
- **`cast_db.py`** — `ensure_schema_columns()` extended with agent_memories migration 013. (#2)
- **`cast-session-end.sh` + `cast-abandon-stale-runs.py`** — WHERE clauses audited and hardened to catch null-`session_id` stuck `running` rows; one-time cleanup sweep applied. (#4)
- **`agent_protocol_violations` and `unstaged_warnings` hooks** — verified firing; hooks re-tested after Phase D commit flurry. (#13)
- **`worktree_anomalies` hooks** — verified clean (code-modifying agents no longer spawn worktrees by design; zero rows is correct). (#16)

### Schema

- **`agent_memories`** — added `last_validated_at` TEXT, `retrieval_count` INTEGER DEFAULT 0 (migration 013, idempotent).
- **`schema_migrations`** — backfilled pre-009 history (one-time).
- **`hook_failures`** — now actively populated; serves as universal silent-exception telemetry sink.

### Tests

- 987 → 990 BATS tests passing (+3 new hook verification tests)

### Notes

- v7.1 closes all P0/P1 findings from the 2026-05-16 cast.db audit. P2 cleanup items (#3 token tracking, #11 agent reliability UI, #20 /db stub-badging) deferred to next phases (claude-agent-team P2 wave + cast-desktop next arc).
- The audit surfaced a meta-bug pattern: silent exception swallow + no fallback logging = systemic visibility loss. `log_hook_failure()` wiring prevents future silent-failure accumulation.
- Deferred to cast-desktop: `agent_hallucinations` reliability dashboard (#11); /db browser stub-badging for deferred tables (#20); Routines panel with failed-run visibility (#19 cast-desktop side).
- See `~/.claude/plans/cast-agent-team-corrections-2026-05-16.md` (full audit report) and `~/.claude/plans/2026-05-17-cast-db-remediation-v7.1.md` (remediation plan) for detailed evidence + fix rationale.

---

## [7.0] — 2026-05-11 — Backend Lockdown

**Strategic goal:** set CAST logic in stone so it "just works" — update occasionally with Anthropic updates, otherwise turn attention to v8 (desktop app) and other projects.

### Added
- **Routines framework (Phase 4.6)** — 11 scheduled/event-triggered autonomous agent jobs (`routines/*.yaml`). Cron + cast-managed-agent dispatch with `prompt_args` interpolation, `mcp_required` pre-flight checks, and a CLI surface (`cast routines list/trigger/enable/disable/validate/schedule`). Generalizes the JARVIS PA pattern. Authoring guide at `docs/routines.md`.
- **Truncation-resilient status emission (Phase 4.9)** — all code-modifying agents write `~/.claude/agent-status/<agent>-<ts>.json` BEFORE prose. Orchestrate skill falls back to file truth (mtime ≤ 300s) when prose Status is missing/truncated.
- **Test-gate authoritative file truth (Phase 4.11)** — test-runner writes raw ok/notok grep counts to status JSON; orchestrate skill trusts file over prose for test-runner specifically (closes the hallucination class observed 2026-05-11 where test-runner reported BLOCKED on a green suite).
- **Cast doctor expansion (Phase 6.5b)** — three new checks: agent frontmatter parses, MCP servers reachable, routines validate.
- **Incident corpus (Phase 6.5c)** — 17 historical problem-fix pairs backfilled into `cast.db incidents` table from journal + feedback memories + fix commits. Idempotent backfill script.
- **DB schema drift fix (Phase 4.10)** — `agent_truncations` CREATE TABLE added to `cast-db-init.sh` self-healing block. Stops the 1917-line flood of "no such table" errors in fresh BATS test environments.

### Changed
- **gen-stats.sh BATS guard (Phase 4.11)** — refuses to mutate `README.md` when `BATS_TEST_NAME`/`BATS_TEST_FILENAME`/`BATS_TMPDIR` is set. Eliminates the sentinel-leak class that has forced manual `git checkout -- README.md` reverts on every full-suite run.
- **bin/cast** — `CAST_REPO_DIR` now respects pre-set env var (was unconditionally overwritten, broke test isolation).
- **test-runner agent definition** — removed false "dispatches debugger automatically" claim (the agent's `tools:` field does not include Agent). Workflow now reports BLOCKED with failing test names; orchestrator dispatches debugger when needed.
- **7 code-modifying agent definitions** (api-contract, bash-specialist, dep-auditor, devops, frontend-qa, migration-reviewer, test-writer) — gained a "Status file write (MANDATORY — truncation resilience)" section.

### Tests
- 918 → 987 (+69 new BATS tests across Phases 4.6, 4.9, 4.10, 4.11, 6.5b, 6.5c)

### Notes
- v7 is the "set in stone" release: backend hardened, observability solidified, agent contracts file-resilient. v8 (Forge + dashboard + voice as a desktop app) gets the marketing push.

---

## [6.0] — 2026-04-16 — Strategic Evolution Sweep

**Strategic goals:** trust for 2000+ clones, maintenance cadence, subtract complexity, leverage current model capabilities.

### Added
- Clean-install CI matrix (ubuntu + macos) verifying every script referenced in settings.json exists post-install (.github/workflows/clean-install.yml)
- Pre-commit regression lints: python cold-start counter, SQL-injection pattern detector, orphan-script detector (.githooks/pre-commit + scripts/cast-lint-orphan-scripts.py)
- Agent Status JSON schema + stdlib validator (schemas/agent-status.json, scripts/cast-validate-status.py)
- All 29 core agent definitions now emit structured JSON status alongside human-readable Status block
- `/cast-audit` skill — monthly 4-parallel-researcher audit (bugs, security, performance, coverage) into dated reports
- `rules-personal/` + `agents/personal/` layered overlay pattern; `install.sh --personal` opts in

### Changed
- `rules/` renamed to `rules-core/` — core content ships to all clones; personal overlay is opt-in
- `portfolio-sync` agent moved from `agents/core/` to `agents/personal/` (maintainer-only)
- `config.sh.template` scrubbed to placeholders only (no real maintainer paths)
- Agent count: 31 → 29 (retired `orchestrator`, archived `claudes-journal-session-end` hookscript moved to personal)
- Documentation (docs/cast-protocol-spec.md, CHEATSHEET.md) updated to reflect skill-based `/orchestrate` dispatch

### Removed
- `agents/core/orchestrator.md` — subagent form cannot dispatch further agents (structural limitation); `/orchestrate` skill replaces it
- Orphan hook references in `settings.json`, `managed-settings.d/40-hooks-tasks.json`, `README.md` (cleanup from commit 83f01bc which deleted scripts but missed the configs)

### Security
- SESSION_ID SQL-injection fix shipped in commit 89a1dc4 (2026-04-16 tactical audit)

### Notes
- D5 decision: VERSION bumped to 6.0 due to structural changes (agent count, layered install, orchestrator retirement, orphan cleanup)
- Agent audit report: candidates (dep-auditor, task-triage, standup-writer, pr-narrator, email-drafter) assessed but all retained. Report at `~/.claude/reports/agent-dispatch-audit-2026-04-16.md`

---

## [6.0-patch] — 2026-04-16 — Tactical Audit Follow-up

### Security
- Fixed SESSION_ID SQL injection in cast-session-end.sh (HIGH)
- Removed eval fallback in cast-statusline.sh (HIGH)
- Routed prompt_preview through cast-redact.py (MEDIUM)
- Allowlisted column names from PRAGMA in cast-memory-consolidate.py (MEDIUM)

### Bug Fixes
- Committed missing claudes_journal-session-end.sh (fixes broken clean install)
- Committed engram-identity-start.sh and engram-session-end.sh to repo
- Added _log_error to cast-subagent-stop-hook.sh and cast-task-created-hook.sh
- Consolidated hook error logs to single hook-errors.log

### Performance
- Consolidated 13 python3 invocations in cast-audit-hook.sh (~40-140ms/Write)
- Consolidated 10 python3 invocations in post-tool-hook.sh (~140-280ms/PostToolUse)
- Added TTL cleanup for agent-status directory (120-min)
- Added indexes on sessions(project), sessions(started_at), agent_runs(project), routing_events(event_type)
- Added 30-day retention for 6 cast.db tables

### Tests
- Added BATS coverage for 4 previously-untested hooks: cast-session-end, pre-tool-guard, cast-subagent-start-hook, cast-headless-guard (+63 tests)
- Deleted dead tests/cast-litellm.bats
- Fixed bracket convention violations in 2 test files
- Updated post-tool-hook.bats test 12 after stdin-heredoc bug fix (consolidation)

### Cleanup
- Removed 3 dead installable scripts (cast-rtk-hook.sh, audit-context-size.sh, cast-compact-reminder-hook.sh)

---

## v5.0 — Swarm Control Plane (2026-04-10)

CAST becomes the control plane for Anthropic's native Agent Teams. Swarm orchestration, live agent visualization, and local model routing.

### Added
- **Agent Teams Integration** — CAST wraps Anthropic's teammate mode with composition, quality gates, and observability
- **`/swarm` skill** — Bootstrap parallel agent teams from YAML config files (`/swarm fullstack-team "task"`)
- **Swarm configs** — `fullstack-team.yml`, `review-team.yml`, `research-team.yml` with model routing options
- **`cast-swarm-bootstrap.sh`** — Creates git worktrees per teammate, seeds spawn preambles, logs to cast.db
- **`cast-swarm-merge.sh`** — Post-swarm merge with safety checks (refuses incomplete teammates)
- **`cast-swarm-teardown.sh`** — Emergency swarm cleanup with `--force` flag
- **cast.db v8 schema** — `swarm_sessions`, `teammate_runs`, `teammate_messages` tables with indexes
- **Ollama/LiteLLM model routing** — Route teammate agents to local models (`ollama:codellama`, `ollama:deepseek-coder`) for cost savings
- **Agent Constellation** — Live force-directed graph dashboard page showing all 17 agents with task satellite nodes (dashboard repo)

### Changed
- Hardened `cast-task-completed-hook.sh` — writes to `teammate_runs` and `teammate_messages` tables
- Hardened `cast-teammate-idle-hook.sh` — routes through `teammate_messages` instead of ad-hoc tables
- Expanded `cast-worktree-create-hook.sh` — handles `CAST_SWARM_ID` and `CAST_SPAWN_PREAMBLE` env vars
- `install.sh` syncs `swarm-configs/` and `skills/swarm/` to `~/.claude/`
- Version bump: `VERSION` → 5.0, `claude-plugin.json` → 5.0.0

## v4.4 — Token Efficiency (2026-04-06)

Systematic token cost optimization across all 17 agents.

### Changed
- Downgraded 6 agents from Sonnet to Haiku: test-writer, bash-specialist, merge, morning-briefing, docs, devops
- Lowered effort from medium to low for all 11 Haiku agents
- Compressed 4 boilerplate sections (Event Registration, Context Limit Recovery, Agent Memory, Status Block) into single compact Agent Protocol across all 17 agents (~210 tokens saved per agent)
- Added tiered orchestrator preamble: full context for implementation agents, minimal for lightweight agents
- Strengthened orchestrator output compression rules (100-word summaries, 30k token compaction trigger)

### Added
- Response Budget sections on all 17 agents (300/800/2000 token tiers)
- WebFetch Efficiency guidance in researcher agent
- `scripts/cast-research-cache.py` — URL result cache for researcher (1-hour TTL)
- Token Efficiency section in README documenting all optimizations

### Impact
- Estimated 25-40% reduction in monthly token spend
- Agent prompt inventory reduced by ~3,570 tokens total (-726 lines, +104 lines across 17 files)
- 6 fewer Sonnet invocations per typical workflow (3x cost reduction each)

---

## v4.3 — Memory Persistence (2026-04-05)

Four-tier implementation of persistent, searchable, scored agent memory.

### Added (Tier 1 — Foundation)
- FTS5 full-text search on `agent_memories` via `agent_memories_fts` virtual table with sync triggers
- `importance` and `decay_rate` columns on `agent_memories` with type-specific backfill
- Relevance scoring: weighted `0.4*recency + 0.3*importance + 0.3*fts_rank` formula
- Shared memory pool: `agent='shared'` convention for cross-agent visibility
- Procedural memory type (`type='procedural'`) for operational patterns
- 5 seeded procedural memories (BATS whitespace, push sandbox, orchestrator dispatch, hook repo sync, dashboard QA)
- Path-scoped rule files: `rules/tests.md`, `rules/scripts.md`, `rules/agents.md`
- `cast-memory-router.py` updated: `--mode retrieve`, `--agent`, `--type`, `--top-n` flags

### Added (Tier 2 — Semantic Search & Distillation)
- Hybrid semantic search via Ollama nomic-embed-text embeddings (768 dims)
- `cast-memory-embed.py` — embedding generator with BLOB storage
- `cast-session-distiller.py` — end-of-session extractor for decisions/patterns/failures
- Memory staleness validation: `cast-memory-validate.py` flags >30-day memories, verifies file/function references
- `cast-memory-schema-v3.py` — adds `embedding BLOB` column

### Added (Tier 3 — Architecture)
- `cast-mcp-memory-server.py` — MCP server wrapping agent_memories table
- `cast-memory-consolidate.py` — weekly dedup, decay, archive below threshold
- Agent preamble wiring: procedural memories auto-loaded at session start
- `cast-memory-schema-v4.py` — MCP server schema additions

### Added (Tier 4 — Distribution)
- README: Memory Persistence section with full schema/algorithm documentation
- Standalone `cast-memory` repo (`ek33450505/cast-memory`) with install.sh and Homebrew tap
- `homebrew-cast-memory` tap formula

---

## v4.2 — TUI Dashboard & Tidy (2026-04-03)

Two new user-facing subcommands and several fixes.

### Added
- `cast dash` — Textual-based terminal UI for live CAST observability. Shows active agents, today's stats with sparkline, recent runs table, and system health. Reads `cast.db` and `~/.claude/` directly. Requires `textual` (installed automatically by `install.sh`).
- `cast tidy` — cleanup subcommand with `--dry-run` flag. Prunes plans, events, logs, DB rows, and briefings older than `cleanupPeriodDays` (default: 14). Configured via `config/cast-cli.json`.
- `CHEATSHEET.md` — comprehensive quick-reference for all CAST commands, agents, hooks, and config paths.

### Fixed
- `settings.json`: corrected `spinnerVerbs` to object format (was array, caused parse error)
- Morning briefing agent: removed broken AppleScript, fixed `cast.db` path
- `cast-cron-setup.sh`: updated cron jobs to use `--agent` flag for proper agent dispatch
- `config.sh`: populated real project paths (was placeholder template values)

---

## v4.1 — Native Adoption (2026-04-02)

Adopt native Claude Code features, remove CAST overlap.

### Replaced
- `cast-cost-tracker.sh` removed — native `cost.total_cost_usd` field in statusline replaces it
- `cast-security-guard.sh` removed — security guard behavior migrated to sandbox `denyRead`/`denyWrite` rules in settings.json
- Prettier `PostToolUse` hook removed — Claude Code formats natively

### Deleted (dead routing scripts)
- `cast-route-install.sh` — model-based routing via agent frontmatter makes this obsolete
- `cast-route-review.sh` — same rationale
- `cast-routing-feedback.sh` — mismatch feedback loop no longer needed
- `cast-mismatch-analyzer.sh` — depended on deleted mismatch_signals table

### Added
- `cast-pre-compact-hook.sh` — `PreCompact` hook for dumb-zone detection
- `cast-statusline.sh` — surfaces native cost and token data in session statusline
- `settings.json` committed to repo for reproducible installs

### Agent Frontmatter
- `code-reviewer`: `background: true` added — runs without blocking the main session
- `morning-briefing`: `initialPrompt: "/morning"` added
- All agents: `effort` frontmatter verified across all 17 definitions

### Tests
- `cast-security-guard.bats` removed (9 tests for deleted script)
- **262 BATS tests passing (0 failures)**

---

## v4.0 — CAST Rebuild (2026-04-02)

Major cleanup removing accumulated rot from v1–v3.4. No new features — reduction only.

### Removals
- Deleted `observe-*` shadow system (7 scripts)
- Removed 21 hooks from settings.json; consolidated guard hooks with matchers
- Gutted `bin/cast`: removed daemon, airgap, profile, route-test, learn, compat, upgrade, queue, run, audit subcommands
- Removed 17 stale files: research/, scripts/archive/, templates, plist, requirements.txt
- Deleted 5 test files for removed features
- Removed `CLAUDE.md.template` (replaced by committed settings.json)

### Schema
- cast.db rebuilt at v7: dropped 5 empty tables (`task_queue`, `budgets`, `mismatch_signals`, `quality_gates`, `dispatch_decisions`)
- Added `batch_id` column to `agent_runs`
- Canonical tables: `sessions`, `agent_runs`, `routing_events`, `agent_memories`

### Reduced
- `bin/cast`: 2331 → 976 lines
- `install.sh`: 351 → 193 lines (removed templates, daemon, managed-settings merge)
- Hooks wired in settings.json: 33 → 15 (then 13 after v4.1)

### Added
- `cast agents` subcommand — reads agent frontmatter, lists roster
- `cast hooks` subcommand — reads settings.json, lists wired hooks
- `sessions.ended_at` UPDATE in `cast-session-end.sh`
- `batch_id` support in `cast-subagent-start-hook.sh`

### Tests
- Rewrote `cast-cli.bats` for v4 subcommands
- **271 BATS tests passing (0 failures)**

---

## v3.4 — Security & Portability Hardening (2026-04-02)

33-issue audit pass. No feature additions — hardening and correctness only.

### Security
- **S1** — `cast-permission-hook.sh` Python injection fix: user-controlled input now passed via argument vector, not string interpolation
- **S2** — `cast-merge-settings.sh` path injection fix: file paths are validated and quoted before use in shell expansions
- **S3** — `cast` CLI: `--model` flag added to allow explicit model override at invocation time

### Portability
- **P1** — All personal absolute-path (`/Users/<user>`) hardcodes replaced with `__HOME__` tokens throughout hook scripts and config files
- **P2** — `install.sh` now runs `sed` substitution on `__HOME__` tokens during plist install, enabling cross-user installation

### Settings Cleanup
- **SC1** — Removed invalid matchers and hooks from `settings.json` that referenced non-existent scripts or used unsupported hook syntax
- **SC2** — Pruned unconfirmed environment variables from settings to reduce noise and prevent unexpected behavior

### Metadata & Agents
- **M1** — `frontend-qa` agent added to `install.sh` sync list and `agents/core/`
- **M2** — `test-writer` model corrected from haiku to sonnet in frontmatter
- **M3** — Agent count updated to 17/17 across install.sh, README, and settings

### Daemon Cleanup
- **D1** — `cast-sync.sh` replaced `castd pause/resume` calls with `flock` lockfile pattern; no daemon dependency
- **D2** — `cast-notify.sh` stale daemon event references removed

### New Docs
- **DOC1** — `docs/native-tools-reference.md` added: 8 confirmed Claude Code native tools with parameter signatures and usage notes

### Test Suite
- 324 BATS tests passing (0 failures)

---

## v3.3 — Phase 11: Audit Hardening (2026-04-01)

### Code Fixes (C1–C8)

- **C1** — `cast-task-completed-hook.sh` added to repo and wired into `install.sh`
- **C2** — `cast-db-log.py` silent exceptions replaced with structured error logging to `~/.claude/logs/db-write-errors.log`
- **C3** — Orchestrator classifies TRUNCATED responses separately from BLOCKED; no cascade on truncation
- **C4** — All critical hook scripts gain `_log_error()` helper — no more silent failures
- **C5** — `cast-audit-hook.sh` PII enforcement is advisory by default; opt into strict mode via `CAST_PII_ENFORCEMENT=strict`; 9-pattern safelist added to suppress false positives
- **C6** — `cast-memory-write.sh` SQL injection fixed — `sed` string escaping replaced with Python parameterized queries
- **C7** — Orchestrator `TodoWrite` references replaced with `TaskCreate`/`TaskUpdate`
- **C8** — `docs.md` command fixed — `doc-updater` → `docs` agent name

### Hardening Fixes (H1–H9)

- **H1** — `install.sh` now syncs `agents/core/*.md` to runtime on every install
- **H2** — `cast-memory-backup.sh` now includes `cast.db`, `plans/`, and `auto-memory/` in backup tarball
- **H3** — `cast-agent-memory-init.sh` ghost agent list removed — dynamic discovery via `find ~/.claude/agents/`
- **H4** — `code-writer` and `devops` agents no longer self-dispatch review chains — use Recommended Next Agents pattern instead
- **H5** — Orchestrator checkpoint system added — plans survive session disconnects mid-execution
- **H6** — Orchestrator policy enforcement gate added — reads `config/policies.json` before each batch dispatch
- **H7** — `post-tool-hook.sh` exits non-zero on prettier crash or status file write failure
- **H8** — SQLite WAL mode enabled; subagent hooks retry up to 3× with backoff on `SQLITE_BUSY`
- **H9** — 4 runtime-only scripts committed to repo: `cast-ci-monitor.sh`, `cast-route-install.sh`, `cast-routing-feedback.sh`, `tidy.sh`

### Behavior Change

- **Approval gate removed** — Orchestrator no longer pauses for user confirmation before batch dispatch; queue display is informational only, execution is immediate

---

## 2026-03-31

### Schema v6 + SessionStart write (`e4019cb`)
- **Migrated:** cast.db v5 → v6: added `event_type` and `data` columns to `routing_events` table
- **Fixed:** Spurious `exit 0` in v4→v5 migration path that caused the migration to silently succeed without running
- **Updated:** Fresh-install `CREATE TABLE routing_events` now includes `event_type` and `data` columns
- **Added:** `cast-session-start-hook.sh` writes `INSERT OR IGNORE` into sessions table on SessionStart (GAP-005)
- **Schema version:** bumped to 6

---

- 2026-03-28: Add cast-archive.sh — automated Stop hook for ~/.claude/ file archiving and cast.db pruning

## Phase 5 (2026-03-22 to 2026-03-26)

### Merge Skill (`b2edc4c`)
- **New:** `skills/merge/` — reusable skill fragment for git merge, rebase, and conflict resolution scenarios
- **New:** Scenario detection logic routes to appropriate merge strategy based on conflict type
- **Added:** `merge` agent promoted to core tier; dispatch routing wired in routing-table.json

### Specialist Agents — 6 New Agents (`1c87077`)
- **New:** `frontend-designer` — production-grade UI and design systems (React, Vue, Tailwind, MUI, shadcn)
- **New:** `framework-expert` — framework-native implementation for Laravel, Django, Rails, React, Vue
- **New:** `pentest` — automated security scanning, dependency audits, OWASP scanning (reports only, no file writes)
- **New:** `infra` — Terraform/IaC and cloud resource provisioning (AWS, GCP, Azure)
- **New:** `db-architect` — schema design, migration authoring, query optimization (write-capable counterpart to `db-reader`)
- **Updated:** Agent registry in CLAUDE.md.template updated to 42 total agents

### Documentation Updates (`1c1eeae`)
- **Updated:** README to document v1.9.0 validation output and new check table
- **Added:** Stage 2.5 architecture diagram entry for semantic routing
- **Added:** Parallel post-chain protocol section
- **Added:** ACI reference sections

### Infrastructure Hardening (`232f212`)
- **New:** Dry-run mode — `CAST_DRY_RUN=1` bypasses all hook side effects for safe testing
- **New:** `stop-hook.sh` — runs at session end: routing feedback, project board derivation, agent memory seeding, temp file cleanup
- **New:** `cast-rollback.sh` — restores working tree to pre-batch state after orchestrator failures
- **New:** `cast-board.sh` — derives project board state from event log
- **Fixed:** Four identified gaps from code audit (see commit body for details)

### Agent Profiling (`13ce26e`, `341c947`)
- **Removed:** Stage 2.5 semantic routing — reserved for future Claude Embeddings API integration
- **New:** `cast-agent-stats.sh` — agent performance profiling: hit rate, BLOCKED rate, avg turn count per agent
- **New:** `cast-validate.sh` v1.9.0 — adds 4 new checks (8–11): route install script, stop-hook wiring, proposals schema, security post_chain
- **Note:** semantic routing infrastructure remains in codebase for future development

---

## v1.5.0 — Fix (2026-03-26)

### Stale Count Corrections
- **Fixed:** `install.sh` menu string updated from "36 agents, 26 commands, 9 skills" to "42 agents, 32 commands, 13 skills"
- **Fixed:** `README.md` installer example updated from "36 agents, 32 commands, 12 skills" to "42 agents, 32 commands, 13 skills"
- **Fixed:** `README.md` validation output example updated from "36 agents" to "42 agents"
- **Fixed:** `~/.claude/CLAUDE.md` — added missing `[CAST-DISPATCH-GROUP]` directive to Hook Directives section (version drift from CLAUDE.md.template)

---

## Phase 4 (2026-03-22)

### Universal Dispatcher
- **New:** `/cast <request>` command — analyzes user intent and dispatches specialist agents
- **Changed:** `route.sh` stripped to logging-only for observability (no more text injection or dispatch messages)
- **Changed:** `CLAUDE.md.template` compressed from 175 to ~75 lines (delegation protocol now implicit in /cast behavior)
- **Added:** BATS test suite for `route.sh` (16 tests covering all routing scenarios and edge cases)

### Pattern Matching Simplification
- **Removed:** Overly broad planner patterns (`implement`, `we need to`, `i want to`, etc.) — replaced by Claude NLU in /cast
- **Removed:** `spawn-mode` from `route.sh` (superseded by explicit `/cast` invocation)
- **Removed:** `post-write-review.sh` and `code-review-gate.sh` PostToolUse hooks (enforcement moved to user command)
- **Simplified:** Stop hook to one-line prompt (reduced unnecessary output)

### Architecture Shift
- **From:** regex pattern matching (90 patterns, 15 routes) + text injection enforcement
- **To:** Claude's native NLU via /cast + explicit user commands
- **Result:** `route.sh` now observation-only (logs to dashboard), dispatch is user-initiated and transparent

---

## Phase 2 (2026-03-21)

### Routing System
- **Fixed:** `route.sh` false-positive on internal Claude Code `<task-notification>` XML messages — they now exit cleanly with no output
- **Changed:** Routing hints now instruct Claude to **dispatch agents directly** (not ask-first). The routing loop goes from 4 steps → 1 step.
- **Added:** `no_match` action logged to `routing-log.jsonl` for tracking routing miss rate (future: triggers Haiku router agent when miss rate > 20%)
- **Added:** 4 new routing patterns: `e2e-runner` (playwright/e2e test), `build-error-resolver` (typescript/build errors), `presenter` (slide deck/presentation), `morning-briefing` (daily briefing/schedule)
- **Fixed:** `commit` pattern tightened — no longer fires on "commit to this approach" or similar phrases

### Agents
- **Hardened:** `doc-updater` — added output format section, diff preview workflow, error handling table (was 16/25, now 23/25)
- **Synced:** `e2e-runner` installed version updated to match repo source (generic stack discovery replaces hardcoded project names)
- **Updated:** Agent quality rubric — re-scored `presenter` (14→20), `browser` (16→20), `e2e-runner` (16→23), `doc-updater` (16→23)

### Discoverability
- **Added:** `/help` command — lists all installed agents with model, command, and trigger conditions; explains routing system; shows examples with cost hints

### Installer
- **Updated:** Post-install "Next steps" now includes `/help` and a routing test example

### Branding
- **Renamed:** Project is now officially **CAST — Claude Agent System & Team** (README title updated)
- **Added:** Honest comparison table vs. NanoClaw v2 and Ruflo v3
- **Updated:** Architecture diagram agent/command counts from 23 → 24
- **Updated:** Router section describes Phase 2 auto-dispatch behavior

---

## Phase 1 (2026-03-20)

- Initial release: 24 agents, 24 commands, 9 skills, 3 lifecycle hooks
- Hook-based routing with regex pattern matching + Opus escalation via `opus:` prefix
- Agent quality rubric (`docs/agent-quality-rubric.md`) — 5-dimension scoring
- Cross-platform support — macOS + Linux/WSL with graceful degradation for macOS-only skills
- Companion dashboard: [claude-code-dashboard](https://github.com/ek33450505/claude-code-dashboard)
