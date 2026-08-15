# Working Conventions

> Operational/recovery procedures (worktree recovery, multi-terminal coordination, post-push CI checks, branch grooming, workflow closures) live in `docs/operational-playbook.md`.

## Planning
- Match planning ceremony to task size — three tiers:
  - **Trivial → inline-eligible** (typo, doc/comment fix, single-value non-protected-config tweak, ≤3-line doc trim): no formal plan, and when ALL **Inline tier** criteria below hold the main session may apply it **inline** — no specialist dispatch, no `code-reviewer`. Anything failing a criterion keeps the dispatch + review ceremony ("no plan" still never means "no dispatch" for it).
  - **Single-session-sized** (one or a few files, finishable in one session): use native plan mode (Claude Code's built-in, in-session plan-then-act via shift-tab — no plan file, no manifest) with a single agent. This is the DEFAULT for ordinary code work.
  - **Genuinely multi-file / multi-hour / multi-agent** (large refactors, migrations, features spanning many files): dispatch the `planner` agent to write a plan file + Agent Dispatch Manifest, then run `/orchestrate` to execute it in waves.
- Don't reflexively spin up the `planner`→`/orchestrate` chain: most coding work has limited parallelizable components (single-agent is better), and multi-agent orchestration costs ~15x the tokens — reserve the chain for work that genuinely fans out.
- Softening *planning* does NOT soften *review* or *dispatch*: the `code-reviewer` gate after every logical unit stays MANDATORY (see `## Code Quality`) — this is the Writer/Reviewer pattern, untouched here. Code changes still route to `frontend-writer`/`backend-writer`/specialists per global CLAUDE.md, even single-line ones.
- `/orchestrate` consumes a manifest from the `planner` agent OR native plan mode — `planner` need not run first.
- Tasks: 15-30 min max; break larger work into chunks
- Each logical unit gets its own commit

## Inline tier (ceremony right-sizing by blast radius)
The main session MAY apply a change **inline** — no specialist dispatch, no `code-reviewer` gate — ONLY when **every** condition holds:
1. **Change class:** documentation/prose (`*.md`, `docs/`), code-comments-only, a typo/wording fix, or a single-value tweak to a non-protected config.
2. **Not a protected surface:** the file is NOT under `scripts/`, `bin/`, any hook, `.githooks/`, `config/policies.json`, `config/egress-policy.json`, `managed-settings.d/`, `install.sh`, a cast.db schema/migration, a §1 hard-won-core file, or a test that guards a hard-won lesson.
3. **No behavior change:** mechanical only — no logic or control-flow change.
4. **Small & self-evident:** ≤ ~10 lines as a rule of thumb — but **blast radius is the real gate**: a one-line edit to a guard, hook, or enforcement file is NOT inline-eligible.

Fail ANY condition → the standard ceremony applies (dispatch the specialist + mandatory `code-reviewer`). Applying trivial work inline also avoids the dispatch-spawned failure modes (maxTurns silent-truncation; the nested-agent review hop) for that work.

**Never relaxed, regardless of size** (the §1 hard-won core + the record): executable-code changes → specialist + `code-reviewer`; enforcement / security / destructive config → also `security`; the `commit` agent (record-feeding + irreversibility); the irreversibility interrupts; record-feeding cast.db hooks; destructive-test containment HARD RULES; the Status / Handoff / Facts protocol; `test-runner` isolation.

## Code Quality
- YAGNI: build only what was asked
- DRY: find existing patterns before inventing new ones
- TDD: write failing tests before implementation for logic-heavy tasks
- Scope discipline: every change traces to the request. Fix a trivial bug only in a file you are ALREADY editing for the task — never open another file to "tidy" it; no "while I'm here" edits.
- Out-of-scope or non-trivial findings: SURFACE, do not fix without an OK. Agents flag via `DONE_WITH_CONCERNS` (the Status `Concerns` field); the main session raises it to the user. (Surgical HARD RULES in `bash-specialist`/`commit` stay stricter — this does not loosen them.)
- MANDATORY: `code-reviewer` after every logical unit of changes **above the Inline tier** (trivial doc/comment/non-protected-config edits the main session applies inline are exempt — see **Inline tier**; anything touching code, enforcement/security/destructive config, or a §1 hard-won-core file is never exempt)
- MANDATORY: Never `git commit` directly (see `## Commits` for the agent + escape hatch)
- MANDATORY: Route errors to `debugger` agent, not inline triage
- MANDATORY: Code-modifying agents attempt to self-dispatch `code-reviewer` via the Agent tool; when nesting depth prevents it, they emit DONE_WITH_CONCERNS and the orchestrator dispatches code-reviewer instead
- MANDATORY: All agents end with Status: `DONE` | `DONE_WITH_CONCERNS` | `BLOCKED` | `NEEDS_CONTEXT`

## Agent Selection
- Native plan mode vs the `planner` agent: native plan mode is Claude Code's built-in, in-session plan-then-act (shift-tab — no plan file, no manifest), the single-agent default for single-session work. The `planner` agent is a dispatched sonnet agent that writes a plan file + Agent Dispatch Manifest for `/orchestrate` to execute in waves — reserve it for genuinely multi-file / multi-agent work. (Note: the `/plan` skill IS that heavy `planner`→`/orchestrate` chain, not built-in plan mode.)
- Single-agent inline is the default — prefer one agent (yourself in native plan mode, or a single specialist dispatch) unless the work genuinely fans out across many files/agents; only then take on the `/orchestrate` overhead.
- `researcher` (sonnet): deep investigation, external sources, recommendations
- `Explore` subagent: fast codebase navigation, file/grep searches

## Agent Turn Limits (maxTurns)
- Every CAST agent has a `maxTurns` frontmatter cap (natively enforced by Claude Code). Hitting it stops the agent SILENTLY mid-task: no Status/Handoff block, no SubagentStop hook fire, and the `agent_runs` row stays stuck in `running` (discovered 2026-06-10, crosscheck_2.0 help-docs migration).
- A SendMessage resume grants a fresh turn budget — but scope dispatch prompts to fit the cap instead of relying on resumes. Caps are data-fit to each agent's truncation rate (B4 retune 2026-07-06; B5 retune 2026-07-09): reviewers/researchers that truncate mid-output run higher (code-reviewer 50, researcher 45, docs 30); implementers stay scoped (frontend-writer/backend-writer 80, test-writer 50, debugger 50); most others 15–25.
- Symptom of a hit cap: agent's final message ends mid-sentence (e.g. "Now let me run the tests:") with no Status line. Treat as truncation, not completion — never relay it as done.
- For tasks that legitimately need more turns (large migrations, multi-file sweeps), split into smaller dispatches rather than raising caps further — the cap is a runaway-loop guard.

## When an Agent Goes Quiet (two causes, opposite remedies)
An agent that delivers nothing has TWO possible causes, and guessing wrong is expensive in both directions. **Before re-dispatching or redoing the work, read the record:** `bash bin/cast review <agent-name-or-prefix> [--last N]` prints `agent_runs.status` and `response` together — that pair is the discriminator.
- **`status='DONE'` with a populated `response` → transport loss.** The work is finished; only delivery dropped it. Read it, do NOT re-run. Observed 3× in one session (2026-08-15): 2938, 3135 and 4151 chars of complete work the orchestrator never saw.
- **`status='running'` with an empty `response` → real maxTurns truncation** (the mode described above). Re-dispatch with smaller scope.
- ⚠️ Invoke it as `bash bin/cast review`, never bare `cast review` — the tap binary is dormant and rejects it with `Unknown subcommand` (verified 2026-08-15).
- Honest limit: only ~79% of `DONE` runs carry a response, and **no** non-DONE run carries one at all (measured 2026-08-15 over the rolling 30d window — re-measure, don't cite this literal). `(no response recorded)` is the correct output for the rest — it is NOT evidence the agent failed.
- Still `running`? Check `bash bin/cast agents --live` before concluding anything — it lists in-flight runs with elapsed time. **Do NOT re-dispatch on `running` alone:** only ~1.5% of runs never end and `code-reviewer` averages 1.6 min, so `running` usually means slow, not dead. Misreading it as stalled once caused two agents to edit the same file. Note elapsed is the ONLY live signal — `tool_uses`, `branch` and `model` are written at completion, so they are empty mid-run by design, not a fault.

## Dispatch-Prompt Contract (context-at-dispatch)
The 95K-token zero-yield burn (a bash-specialist read 8 files, wrote nothing, hit maxTurns) was an *authoring* failure, not a cap failure. Every dispatch MUST give the agent enough inlined context to start producing output immediately:
- **Inline the context, don't defer it.** Paste the exact `file:line` anchors / snippets / old→new strings the agent needs — never "study/read these N files first." If the agent would need to read 4+ files just to begin, compress that context into the prompt before dispatch.
- **Demand artifact-first.** "Write a skeleton of the deliverable in your first 1–2 tool calls, then refine" — so a truncated run leaves a salvageable artifact, never zero output.
- **Scope to the turn cap.** One logical unit per dispatch, sized to the agent's maxTurns (bash-specialist 30, frontend-writer/backend-writer 80). Split big bites; never rely on a resume.
Agents enforce the reciprocal half (`cast-conventions` → Truncation Prevention: artifact-first + read-before-write refusal).
- **Scope the commit agent explicitly.** Every `commit` dispatch lists the exact files to stage AND states "exclude everything else" — the agent stages nothing outside the list. An unscoped dispatch swept `docs/decision-log.md` into an unrelated commit (LF-5, 2026-07-01).
- **Per-unit review gates need per-unit diffs.** When multiple units' uncommitted work coexists, scope each `code-reviewer` dispatch to the unit's files (or commit prior units first) — a reviewer shown the whole tree false-BLOCKs on other units' legitimate work (LF-9, 2026-07-01).
- **Commit dispatches without a `task_id` log an expected "no approval record" WARN.** When dispatching `commit` outside an orchestrated task, state the review provenance in the prompt (which reviewers passed); the WARN is informational, not a failure.
- **Name roster dispatches `<agent-type>__<label>`, or don't name them at all.** A custom `name` on the Agent call **overwrites the registered type in the hook payload** — Claude Code documents an agent's `name` as *"the value hooks receive as `agent_type`"*, and there is **no separate key carrying `subagent_type`** (verified against the official hooks/subagents docs, 2026-08-14). So `Agent({subagent_type: "backend-writer", name: "fix-advisory"})` lands in `agent_runs` and `agent_protocol_violations` as `fix-advisory`, permanently unattributable to `backend-writer`; `agent_id` doesn't help (it's a slug of the same name, and NULL in ~27% of rows). Prefix with the roster type and a **double underscore** — `backend-writer__fix-advisory` — so the record stays classifiable. `__` is unambiguous because every roster name uses single hyphens; a single `-` would be. Note the `name` pattern is `^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$`, so `type:label` is **invalid** — no colons. Unnamed dispatches are already fine (they report the roster type verbatim). Cost of ignoring this: a 2026-08-14 audit found 59 protocol violations in 7d that could not be attributed to any agent, burying the ~10 that were real.

## Parallel Dispatch
- `test-runner` (and any process-killing / test-executing agent) MUST run in its OWN sequential batch. It MUST NEVER share a `"parallel": true` batch or a dispatch-group wave with any other agent — most critically the review agents (`code-reviewer`, `security`, `frontend-qa`).
- Reason: `test-runner`'s suite-timeout/kill path can reap co-scheduled sibling processes — a co-scheduled `code-reviewer` was killed this way on 2026-06-14. Isolating `test-runner` in its own batch keeps the kill blast radius to itself.

## Workflow Authoring (stage model selection)
`Workflow` stages inherit the **session model (opus) by default** — the tool's own guidance is to omit `model` and let stages inherit. For CAST that default is the dominant cost driver: `workflow-subagent` is consistently the single largest line item in the record. Choose the model per stage instead:
- **Mechanical / scout / gather** (file collection, grep/scan, formatting, mechanical transforms) → `model: 'haiku'`.
- **Analytical middle** (per-item review, single-source synthesis) → `model: 'sonnet'`.
- **Synthesis / verify / adversarial-judge tops** (final report, refute-a-finding, cross-item ranking) → `model: 'opus'` (or `fable` where breadth helps).
- Omit `model` (inherit opus) ONLY when the whole workflow is genuinely opus-hard — never let a mechanical fan-out inherit opus. Mirror this for `effort` (`low` for mechanical stages, higher tiers only for the hardest tops).
- Pin a `label`/stage name when you set a model, so the record can measure the before/after (feeds B5).

**Measure, don't remember — never cite a frozen cost literal here.** `cast.db` keeps a **rolling 30-day window** (`com.cast.db-prune`), so (a) a cited share is meaningless without the window it was computed over, and (b) any figure written into this file goes stale within the month. Recompute before citing — `just -g window` FIRST (prints the real span), then `just -g cost`, `just -g model-mix`, `just -g cost-weekly`, `just -g model-drift`. Recipes live in `~/.config/just/justfile`.
- The former "64.6% of all recorded agent cost / ~$5.3K / ~$6.56 per run (2026-07-06 audit)" figure is **unreproducible** — the rows it was computed over have been pruned. Do not re-cite it.
- Last measured 2026-08-03 (window 2026-07-04 → 2026-08-03, 30d): `workflow-subagent` = 611 runs, ~$1.4K, **~31% of recorded spend at ~$2.33/run**. That window shifted inside 12 hours (4602 → 4375 rows overnight as prune ran) — which is precisely why the *recipe*, not the number, is the durable artifact.
- ⚠️ **The per-stage rule above is NOT currently being applied.** Over that window `workflow-subagent` opus share rose **21% → 68%** while haiku usage fell to **zero for three consecutive weeks**. The falling per-run cost is a pricing effect (`opus-4-8` ~$4.75/run → `opus-5` ~$1.98/run), not evidence of stage discipline. Verify with `just -g model-drift` before assuming this is resolved.

## Irreversibility Interrupts
- Irreversible/destructive ops that always gate (never run ad hoc): `git push` & force-push, PR/force-merge, schema migration, DB row deletion (prune), destructive `rm -rf`/rmtree, process mass-kill (`pkill`/`killall`), raw `git commit`/`git stash`.
- Auto-chain rule: hook guards and confirm-pauses protect interactive sessions but are BYPASSED in headless/managed runs and ABSENT in cron/launchd. An irreversible op is auto-chain-safe ONLY via a fail-closed script gate (back-up-or-abort, e.g. `cast-migrate.py`, `cast-db-prune.py`) or an agent text-refusal — never rely on a hook for unattended safety.
- New destructive automation MUST carry its own fail-closed gate (declare blast radius; back up or abort before deleting).
- Canonical per-op ledger (enforcement + auto-chain-safety column): `docs/architecture/cast-protocol-spec.md` §2.5.

## Testing

> **POLICY CHANGE (Ed, 2026-06-02):** Passing tests are NO LONGER a per-merge/per-push requirement.
> Tests are fixed in batches before version releases. Rationale: gate failures unrelated to changes
> cost half a day on PR #104. The old "all tests green before push" rule is retired.
> EXCEPTIONS that still block immediately: (1) destructive tests (anything that can damage the live
> runtime — see project_cast_recovery_state memory), (2) failures clearly caused by the change being made.
> **NEVER run the full BATS suite against a real $HOME — the isolated-temp-HOME requirement is permanent**
> **(see cast-blast-radius-guard.bats §3.8.A regression coverage), not conditional on a pending fix.**

- Tests alongside source: `Foo.jsx` -> `Foo.test.jsx`
- Test behavior (`getByRole`/`getByText`), not implementation
- Cover: happy path, edge cases, error states
- A new gate (lint, hook, CI check) isn't done until probed on its REAL default path: plant a violation, run with no env overrides, watch it bite. Passing only via the test/override path is false green (blast-radius lint scanned 0 files and exited 0, 2026-06-12).
- New BATS files using `date`/`stat`/`sed` get a Docker Ubuntu pass before push, not just macOS — BSD/GNU flag divergence (e.g. BSD-only `date -v`) breaks CI (2026-06-12).

## Accessibility (UI projects)
- Every icon-only button/link gets `aria-label`; decorative icons get `aria-hidden="true"`
- Visible `:focus-visible` state on every interactive element — never rely on browser default rings on dark themes
- Color contrast ≥ 4.5:1 for text and meaningful icons
- Hit target ≥ 44×44 px on touch surfaces
- Form inputs have `<label>`, `autoComplete`, and `aria-describedby` for errors
- Animation respects `prefers-reduced-motion` via `useReducedMotion()` or CSS media query
- Semantic HTML first (`<button>`, `<a>`, `<nav>`, `<main>`); ARIA only when semantic HTML is insufficient
- Keyboard navigation works end-to-end — logical tab order, modal focus trap, Escape closes overlays
- Applies on first pass, not as a later sweep. Dispatch `frontend-qa` for a dedicated a11y review before commit on UI-heavy changes.

## SQL / Data
- `db-reader` for read-only exploration
- Optimized queries with filters; BigQuery via `bq query` CLI

## Commits
- MANDATORY: Use `commit` agent — never raw `git commit` (escape hatch when agent unavailable: `CAST_COMMIT_AGENT=1 git commit`)
- Imperative mood, concise (`Add feature X`, `Fix bug in Y`)

## Context Management
- Compact at ~60% context (before "dumb zone" at ~70%)
- `/compact` to summarize; `/clear` + `/resume` for fresh start
- Commit before compacting — compact discards tool output history
- Commit at least hourly during implementation sessions
- Run `/usage` periodically to monitor token spend; run `/cost` after long sessions for per-model + cache-hit breakdown — both feed the monthly cost re-evaluation cadence.
- `CLAUDE_CODE_SCRIPT_CAPS=100` is set in settings.json — caps per-session script invocations to prevent runaway agent loops.
- No github MCP wired (dropped 2026-07-02, `gh` CLI covers it — see memory).

## Branch Naming
- Before starting any phase/feature work, verify the current branch matches the phase name (e.g., Phase C3 work must land on feature/c3-*, not feature/c2-*).
- When orchestrating a new phase, explicitly create and checkout the correctly-named branch FIRST before any edits or agent dispatches.

## Stat/Fact Verification
- Before writing any public-facing content (LinkedIn, README, dev.to articles, announcements) that cites project stats (agent counts, test counts, line counts), verify numbers against the actual repo state — do not rely on memory or prior session context.

## Memory Verification

- Auto-memory entries that name a wired hook, registered route, or flag-gated feature must be verified on disk before being relied on for new work. Memory records intent and snapshots; reality is the file system and live config.
- When recommending action based on a memory entry that names a specific function/path/script, grep or stat the target first. "The memory says X exists" is not the same as "X exists now."
- Bug class context: 2026-05-05 — a 3-week-old auto-memory said `SessionStart read hook added 2026-04-26` but the hook had never been wired. The intent was recorded; the wiring step never happened. The memory was honest about what it observed.
