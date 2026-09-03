# CHANGELOG

All notable changes to CAST are documented here. This project adheres to [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## [Unreleased]

_Nothing yet._

## [10.0.1] — 2026-09-03

Small patch release — 3 merged PRs since v10.0.0, no schema or behavior changes to the
gate/guard surfaces.

### Fixed

- **`config/model-pricing.json` corrected against live Anthropic rates** (#397). Every model
  except `claude-sonnet-5` was mispriced — `claude-opus-5` and `claude-fable-5` were absent
  and fell through to the `_default` rate, `claude-opus-4-8` was overstated 3x, and
  `claude-haiku-4-5` carried Haiku 3.5's price. `config/producer-contract.json` gained entries
  for the three v10 tables (`ack_events`, `agent_runs_daily`, `mcp_calls_daily`) and a
  `retired` status for four tables that no longer exist, closing the gap that let
  `claude-code-dashboard` ship routes silently querying dropped tables. A fail-closed recost
  migration for historical `cost_usd` was added but **not yet applied** — dry-run only,
  pending a separate explicit decision.
- **`ecosystem-versions.json` drift now gated in CI** (#395) — the file had silently drifted
  (dashboard entry stuck at 2.5.0 while the dashboard had reached 2.7.0), publishing stale
  data to castframework.dev. `cast-stats-guard.yml` now runs `gen-ecosystem-versions.sh
  --remote --check` and fails loudly on drift instead of publishing it.
- **`cast-session-start-hook.sh`'s pane-bindings notify call aligned with the dashboard's
  endpoint contract** (#398) — adds the `X-Dashboard-Token` header the dashboard's new
  `POST /api/pane-bindings/notify` route requires, and renames the JSON field `paneId` →
  `pane_id` to match. The dashboard-side endpoint shipped in a parallel
  `claude-code-dashboard` v3.0.0 release.

## [10.0.0] — 2026-08-27 — Make the Gates Tell the Truth

49 merged PRs since v9.5.3 (2026-07-11 → 2026-08-27): 423 files, +48,879/−3,259. The release has one theme, arrived at the hard way: **a gate that has never failed is indistinguishable from a gate that cannot fail.** Nearly every item below was found by asking of an existing check "what does its output look like when the thing it guards did not happen?" — and discovering the answer was "identical to success." The destructive-op guard was registered but never validated; the session-end prune had been failing on every run for months behind `|| true`; a `cast doctor` honesty check compared timestamp formats that can never match; the review gate could be satisfied by a review of a different artifact entirely. Tests 2,353 → 3,320 across 204 → 239 files, and the new ones are mutation-tested — reverted against the bug they guard and confirmed RED — because an assertion that never fails is the same defect one level up. Two of this release's own tests were caught that way and would otherwise have shipped green and empty: one asserted NULLs on a payload the hook had rejected as malformed, so it could not have failed; another never reached the code under test because an optional module was absent on the machine running it.

### Security

- **Escape-hatch uses are now recorded, and the primitive that was supposed to record them would have written nothing.** `record_ack()` falls back to reading its variable from the process environment, but a CAST hatch is an inline command prefix and the git guard is a PreToolUse hook — the variable is never in the guard's own environment, so every call would have returned False and written zero rows while appearing to work. `cast_ack.py`'s CLI gained `--value` so the caller passes it explicitly. `cast-git-guard.py` gained `_record_hatch()` — an external subprocess, never an in-process import, because a planted same-named module on the CWD-derived `sys.path` could `sys.exit()` at import time and kill the guard, which `except Exception` cannot catch — and `_hatch_value()`, which recovers the value from the segment's leading assignment prefix. Wired at the commit and push sites; the remaining fourteen hatches follow separately. The existing `audit.jsonl` writes are retained rather than folded in: `COMMIT_HATCH_USED` has two live consumers (the pre-push provenance gate and the scheduled record review), so converging them would have silently broken a push gate. Three gate findings shipped in the same change: flag parsing now consumes `--flag value` pairs in order, so a value equal to a flag name cannot be re-read as a flag; an unbalanced quote later in a command no longer drops the audit row for a hatch that *was* honoured (the quoting error was in the commit message, destroying extraction of an unrelated leading prefix); and the subprocess timeout drops 5s to 2s with a cap of 8 records per command, bounding a measured 15s worst case against a 0.033s healthy median. Known and stated rather than buried: padding a command with eight or more hatched segments suppresses the later `ack_events` rows, the verdict unaffected and `audit.jsonl` uncapped.

- **The remaining fourteen escape hatches record their uses, and an absent row now means one thing.** Wiring them restructured `if not hit(_X_ALLOW) and hit(_X_BLOCK)` into `if hit(_X_ALLOW): record; elif hit(_X_BLOCK): return 2` at fourteen sites — control-flow equivalent, verified by truth table. The cap fix shipped in the same unit rather than after it, because it becomes load-bearing exactly when the wiring lands: `_MAX_HATCH_RECORDS_PER_COMMAND` is 8, so past that an absent `ack_events` row meant EITHER "no hatch" OR "hatch used, record dropped" — this release's own defect class. A `CAST_HATCH_RECORD_CAP` sentinel row is now emitted from `_git_evaluate`'s `finally` whenever the cap suppressed at least one record, so the true worst case is `(8 + 1) x 2s` and silence is unambiguous. The commit and push sites have `audit.jsonl` as a backstop; the other fourteen have none, which is why the gap had to close alongside them.
- **A hatch can say why it was used.** `CAST_HATCH_REASON="rebasing onto main" git reset --hard` overwrites the recorded value with the reason text, closing the last third of migration 034's question — who bypassed which gate, when, and *why*. A bare `=1` still records with `has_reason=0` rather than being rejected, so no existing invocation broke. The value is looked up per shell segment, and a quoted multi-word reason survives the guard's own segment re-joining, which collapses it to `CAST_HATCH_REASON=_` before re-splitting so the reason text can never be re-read as a command token.
- **Subagent lineage is recorded, after the assumption that it could not be was tested.** The SEC-2 residual carried an explicit instruction not to add `parent`/`depth` columns on faith, because the standing evidence said hook payloads carry no agent identity, and an always-NULL column is the write-only-table defect this release deleted `cast-board.sh` for. The payload indeed carries none — but Claude Code writes an `agent-<id>.meta.json` sidecar beside every subagent transcript, in the directory the SubagentStop hook already globs, and it does. Measured over 3,063 live sidecars: `spawnDepth` on 3,063 (100%), `parentAgentId` on 188 — every agent at depth >= 2 — and all 188 resolve to a real sibling agent. `agent_runs.spawn_depth` and `.parent_agent_id` (migration 036) are therefore populated for every row, and exactly where a parent agent exists. The same sidecar corroborates this release's depth-cap claim from **outside** the mechanism being claimed: the newest depth >= 2 agent on disk predates `CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH=1` by a day, and there are none after it.
- **`cast doctor` asserts the depth cap at runtime, not only at build time.** The cap fails OPEN by absence — a missing or malformed variable silently restores depth 3 — and its only backstops were `install.sh` regeneration and the `settings-drift` gate. The new check fails the doctor exit on any run in the last 7d at depth > 1, and reports "no depth recorded" as INFO rather than as a pass, because a green tick for an assertion that could not run is the exact false green this release is about.
- **SEC-2 — the review gate could be satisfied, overwritten, and inherited (six defects, one of them Critical).** `cast_check_approvals` Tier 2 resolved each reviewer with `ORDER BY ended_at DESC LIMIT 1`, so a later `DONE` silently superseded an earlier `BLOCKED`; since dispatched subagents share the enclosing `session_id`, a self-dispatched `code-reviewer__<label>` was indistinguishable from an orchestrator-run gate and could overturn a real rejection. Tier 1 (`cast_derive_state`, the `/orchestrate` path, checked **first**) had the same defect in a worse form — net rejections computed as an order-independent set difference, with no freshness window, no branch guard and no session scoping. Both are now sticky, with `CAST_REVIEW_BLOCK_OK=1` reverting to newest-decision-wins and recording the bypass. **Critical:** `cast_derive_state`'s reviews glob matched `{artifact}-*.json` and checked only reviewer and decision, never `artifact_id`, while the events loop 35 lines above correctly checked `task_id` — and `CAST_REVIEWS_DIR` is one flat directory shared by every task and session, so artifact `art` inherited every review belonging to `art-1`, `art-2` and so on. Measured: a foreign task's approval satisfied the gate for an artifact with **zero** reviews, with no attacker and no unusual naming required. Two further evidence-destruction paths: second-granularity filenames in `cast_write_review` (a rejection followed immediately by an approval overwrote the rejection — stickiness cannot help when the evidence is deleted) and in `cast_emit_event` (two `artifact_written` events collapsed into one, so the lost artifact never entered `artifact_ids`). Both writes now use `O_CREAT|O_EXCL` with a bounded 100-attempt retry that fails loudly rather than dropping a record. The events glob used the raw `task_id` while filenames use the sanitized form, so any `task_id` containing `/` derived empty state — which had made the state-file fix inert for the case it exists to protect. The `cast_ack` call moved from an in-process import to a subprocess, because `except Exception` does not catch `SystemExit` and a planted module could have terminated the gate with status 0.
- **Subagent self-review is now structurally impossible.** Prompt wording does not prevent it — measured 0 for 3, with three agents spawning subagents against explicit escalating prohibitions. `CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH=1` is set at the fragment layer, so at the depth limit Claude Code withholds the `Agent` tool from every subagent: the tool is absent, not merely forbidden. Scope stated so the control is not later assumed universal — local headless and cron **are** covered (every CAST dispatch path invokes the local CLI without `--settings`/`CLAUDE_CONFIG_DIR` overrides, and `permissions.*` and `env` are independent subsystems); **Managed Agents are not**, having no local `settings.json`; and it **fails open by absence**, with build-time backstops only (`install.sh` regen plus the `settings-drift` gate) and no runtime self-check. All seven agents holding the `Agent` tool now carry the graceful-degradation sentence.
- **Closed the SubagentStop approval-spoof channel (v10 Wave I) — the identified producer of a ~10-incident class that previously had no known cause.** Claude Code fires `SubagentStop` on a ~31.5 s beat while a subagent is still running. Raw-stdin capture (added behind a directory switch for exactly this question) proved these ticks carry `agent_type=""` plus a fresh ephemeral `agent_id` matching no `agent_runs` row — and that a tick's `last_assistant_message` is the **enclosing session's** last message, not any subagent's output. The identity guard admitted them on a bare `agent_id`, so stage 16 relayed that text into the parent context as a `<subagent-report>` `response_excerpt`. All six captured tick messages matched, verbatim and 1:1, the subagent-report blocks that arrived in the session — including `"push it and open the PR"`, which the user never sent. This was not a model misreading a fence; a real component was feeding non-subagent text into a subagent-attributed channel. Identity now requires a non-empty `agent_type`/name **or** an `agent_id` that resolves to a real row; rejected events drop ahead of all 18 stages, closing the model-context fence and the chain-automation side-effect path at one chokepoint. Tests are built from the 7 real captured payloads, not synthesized ones.
- **The git guard scanned only the first line of a Bash command.** `_git_evaluate` read line 1, so any guarded op on line 2+ was invisible; same-line `&&` and `;` chaining had always worked, and the newline was the whole bug. Widening the scan required suppressing prose, and **every suppression mechanism proved unsafe**: a heredoc detector missed `<<<` herestrings, `<<` inside quotes and `<<` after a trailing comment; its quote-parity replacement missed backslash-escaped quotes; and comment dropping fails open in whichever order it runs relative to continuation joining, because bash decides comment-hood word-wise during lexing. All of it was deleted — `_scannable_segments` now joins odd-count backslash continuations and splits on `;`, `&&`, `||`, `|`, and nothing else. Comments and heredoc bodies are scanned, so prose naming a guarded command blocks and needs that op's hatch: a hatchable false block was chosen deliberately over a silent bypass.
- **Quoting and global options each defeated the entire guard module.** Every BLOCK pattern matched a bare shell token, so quoting a subcommand or a destructive flag evaded it — 12 forms measured ALLOWED at HEAD across all 11 guarded ops, including the commit and push blocks. `_normalize_git_segment()` now `shlex`-tokenizes each shell segment and re-evaluates every pattern against the normalized form as well as the raw one, applying only when the segment's first non-assignment token is `git` (normalizing every segment was measured to newly block ordinary `rg`/`grep` searches with no working hatch). Separately, `_GIT_OPTS` was a regex allowlist of five global-option forms, so any legal option outside it broke the anchor between `git` and the subcommand and allowed **all 16** guarded ops — five distinct forms were measured at HEAD, and 14 more besides. A two-character option defeated the whole module. Fixed as a class rather than instance-by-instance: the normalizer walks the token list after `git`, dropping global-option tokens and their separate-token values, repairing all 16 ops without touching a single BLOCK regex. Extending the allowlist was rejected — an enumerated allowlist that fails open is what produced the bug. Absolute-path invocation (`/usr/bin/git`) is closed too.
- **Guarded thirteen destructive git ops that were entirely unguarded, each measured before a pattern was written.** The guard hard-blocked the commit, push and even the recoverable stash paths, while the commands that actually destroy uncommitted work were not covered — the gap that let a dispatched commit agent destroy a fully reviewed working-tree diff on 2026-08-17. New blocks, each with its own hatch and per-segment scoping: hard/merge/keep resets (`CAST_RESET_OK`), non-dry-run cleans (`CAST_CLEAN_OK`), pathspec and forced checkouts (`CAST_CHECKOUT_OK`), worktree restores (`CAST_RESTORE_OK`), discarding switches (`CAST_SWITCH_OK`), forced removals (`CAST_GIT_RM_OK`), branch delete/move/force (`CAST_BRANCH_OK`), forced worktree removal (`CAST_WORKTREE_OK`), ref deletion, stdin payloads and ref overwrites (`CAST_UPDATE_REF_OK`), history rewrites (`CAST_FILTER_BRANCH_OK`), and the recovery path itself — reflog expire/delete (`CAST_REFLOG_OK`), collection with an explicit prune date (`CAST_GC_OK`), and non-dry-run prunes (`CAST_PRUNE_OK`). Checkout path-vs-branch is not decidable by shape, so the bare-pathspec case mirrors git's own disambiguation and checks the token against disk — which blocks the exact command from the 2026-08-15 incident where a read-only reviewer silently reverted the file it was reviewing. Two ops on the deferred list were **measured not destructive** and deliberately left allowed with regression fences asserting they stay that way (a cached-only removal leaves the modified worktree file intact; a sparse-checkout set removes only committed content). Stdin ref payloads are denied by default because they arrive invisible to a command-line scanner — denying by default beat documenting a hole.
- **A brand-new hard-block shipped with a complete single-command bypass, found inside its own unit.** The forced-removal block's `--cached` exemption used a bare `\b`, which fires on any word/non-word transition, so a pathspec merely *starting* with `--cached` disabled the entire block. The same defect class had already been fixed twice in the same file (`prune(?![\w-])` against `prune-packed`, `filter-branch(?![\w-])`), each with a comment explaining it — and the new block was written alongside them and did not inherit the lesson. Now anchored to a real shell token, with four regression tests and a mutation test confirming they fail against the old pattern.
- **Three pre-existing guard defects fixed alongside, all confirmed live at HEAD:** escape hatches were never scoped to the command they attached to (`_git_evaluate` returned on the first matching ALLOW, so one hatch voided every later op on the same line — evaluation is now per shell segment, matching how a real shell scopes a `VAR=1` prefix); trailing-boundary patterns `(\s|$)` were bypassed by adjacent empty-output command substitution; and clustered short flags hid the destructive flag, so a dry-run clean was blocked while a forced checkout was allowed.
- **`cast exec` dispatched every agent with CAST's entire PreToolUse pipeline disabled — and had never worked.** Both dispatch sites passed `--bare`, which per the Claude Code docs skips "auto-discovery of hooks, skills, custom commands, subagents, plugins, MCP servers, auto memory, and CLAUDE.md" — so the git guard, destructive-op guard, egress sentinel and every record-feeding hook were absent, not merely a permission gate. Bare mode also "never reads OAuth credentials or the system keychain": measured, `claude --bare -p` returns rc=1 `Not logged in` against the real `$HOME` while the identical non-bare call authenticates, and `ANTHROPIC_API_KEY` is set nowhere — so every `cast exec` dispatch had been failing at auth for an unknown period, unnoticed. `--bare` removed from both sites, with a structural guard (`tests/cast-exec-no-bare.bats`) scanning every tracked `scripts/` and `plugin/scripts/` file via `git ls-files`, because prompt wording has a measured 0% success rate at preventing regressions in this repo.
- **Six credential patterns added to redaction, and three plaintext-leak paths closed.** New: `STRIPE_KEY`, `SLACK_TOKEN`, `NPM_TOKEN`, `SENDGRID_KEY`, `GOOGLE_API_KEY`, `GENERIC_SECRET` (which detects quoted-key and fat-arrow forms like `{"password": "x"}` that previously evaded entirely). Backtick-fenced values were missed; a case-insensitive `<...>` placeholder lookahead bypassed any `<word>`-prefixed value; and trim-below-floor discarded entities instead of keeping the untrimmed span.
- **Two redaction patterns were dead code behind the `_PII_CANDIDATES` fast path, and the guard for that could not catch either.** `AWS_ACCESS_KEY` (`AKIA[0-9A-Z]{16}`) requires no digit, but `AKIA` was not a trigger — so an all-letter key in text with no other trigger character was never scanned and passed through in full plaintext, for months. `PRIVATE_KEY` repeated the shape: the pattern accepts a `BEGIN`-prefixed header with no whitespace while the trigger required `BEGIN\s`. Neither was an oversight in the assertion — both were **sampling failures**, because the superset ratchet's sample per pattern was hand-chosen, and `AWS_ACCESS_KEY`'s sample was AWS's own example key whose stray `7` satisfied the `\d` trigger. Each sample is now derived from the pattern's own parse tree, preferring letters over digits at every choice point so it is adversarial by construction; all 23 patterns are machine-derivable and the exemption list is empty, with two drift guards keeping it that way. Also fixed: `redact_regex` spliced right-to-left using indices stale w.r.t. the already-mutated string, so an inner replacement that *grew* the text made the outer replacement slice too early and leak a plaintext tail — a database URL redacted to `<DATABASE_URL>ppdb`.
- **Redaction was persisting the plaintext it had just redacted, to a directory named `redact-maps`.** `cast-redact.py` attached the raw matched text to each entity as `original`, and `write_redact_map()` wrote that array verbatim to `~/.claude/logs/redact-maps/`. Nothing reads the field; nothing reads the directory at all — it is write-only, and `original_hash` is what correlation would use, so there was no retention-vs-exposure tradeoff being made. Found on disk: 210 map files, 150 holding plaintext (all `PHONE_NUMBER` false positives, 146 of them 10-digit epoch timestamps — so no credentials were exposed, but a real AWS key match would have been persisted identically). Stripped at the write site; the 150 files purged separately under a verified backup gate. Stage 6's handoff-block excerpt also failed **open**, storing unredacted text when redaction failed; it now omits the excerpt. Stage 16's `summary`/`concerns` remain fail-open, documented in place and rated Medium rather than quietly left.
- **Nine live bypasses closed across all three trust fences.** CAST has three hooks that inject external content behind a trust fence and neutralize the fence's own tag in the body — and each had a different subset right, which is what happens when one idea is reimplemented three times instead of shared. The `SessionStart` journal hook used the weak exact-string `.replace()` form: of five probes only the exact-case close tag was neutralized. Its directive neutralizer covered `DISPATCH|CHAIN|REVIEW` — 3 of the 27 `[CAST-*]` tokens in this repo, case-sensitively — missing `[CAST-HALT]` (hard-blocks a session) and `[CAST-ORCHESTRATE]`; the live journal already contained 6 such tokens. The resume-inject hook's neutralizer was likewise case-sensitive while live plan files contain `[CAST-CHAIN]` and `[CAST-BUDGET-HARD-LIMIT]`, and its `<resume-distillate>` fence neutralized **nothing** of its own tag, so a close tag in a plan file broke out and everything after it read as unfenced session context — a security review had cited that fence as independent protection, having verified it was present rather than that it held. Finally, all three used `</?TAG`, which requires the tag name immediately after `<` or `</`, so three whitespace-separated forms all escaped. Widened to `<[^\S\n]*/?[^\S\n]*TAG` after two wrong turns worth recording (`\s*` closes every bypass but matches newline, joining a bare `<` at end of line to a tag name on the next; `[ \t]*` fixes that and reopens four, because Python's `\s` also covers NBSP, em-space and form-feed). The tests are bidirectionally mutation-tested — every earlier version of this pattern passed its own tests, because each suite only checked the direction its author was worried about.
- **`db-reader` lost its `Write` grant.** It held `Write`+`Bash` behind a prose-only read-only contract with no technical backstop. The agent-type-keyed PreToolUse guard (the alternative remediation) was found **infeasible** and documented as such: PreToolUse payloads carry no agent identity (`agent_type` is SubagentStop-only, `subagent_type` is readable only at the orchestrator's dispatch, `CAST_AGENT_RUN_ID` has zero writers), so building it would be fake enforcement that silently no-ops under concurrency. The prose is now honest that Bash SQL discipline remains a prompt-level contract, not technically enforced.
- **Egress sentinel exfil-pipe detection is now shell-aware.** `_bash_network_hits()` used a naive whitespace split plus basename match, which under-detected (no segment awareness) and over-detected (a network binary named inside a quoted string false-positived). It now reuses `cast-command-guard.py`'s tokenizer, identifying a network binary as a segment's command word **or** one of its argument tokens — keeping recall for re-exec wrappers (`nohup`/`env`/`xargs`/`find -exec`) and command substitution while suppressing the quoted-string false positive. Falls back to the pre-fix split if the tokenizer cannot load; the sentinel stays fail-open and advisory. The residual — a network binary named inside a re-executed quoted string — is documented in the docstring rather than implied covered.
- **Neon MCP wired read-only, with writes gated behind a recorded hatch.** `?readonly=true` is enforced server-side by Neon, so the restriction holds in headless and cron contexts where local hooks are bypassed or absent, and `deniedMcpServers` blocks the full read-write endpoint (live-probe verified to block the read-write URL while sparing the read-only one, so the restriction survives a service rename). Branch deletes route through `scripts/cast-neon.sh`, which requires `CAST_NEON_BRANCH_DELETE_OK=1` and records the bypass via `cast_ack.py` — the first real caller of the recorded-hatch primitive. **Honest correction shipped in the same release:** the Neon MCP server reports write mode and exposes `delete_branch`, `delete_project`, `run_sql` and `reset_from_parent` *despite* `?readonly=true`, because the OAuth scope granted at connect time beats the URL parameter. Write tools stay usable but nothing lands silently: `permissions.ask` prompts on the write verbs and the PreToolUse dispatcher notifies and records, firing **before** the `CLAUDE_SUBPROCESS` early-return so a dispatched subagent is covered. Classification is fail-closed — the safe-read list is an exact enumeration, so any unrecognised tool is unsafe by default, and `get_connection_string` is classified as a credential rather than a read.
- **Four low-severity hardening fixes:** `cast-memory-consolidate.py`'s `SAFE_COL` regex `$` → `\Z` (`$` matches before a trailing newline); `cast-memory-embed.py` gained the `_is_safe_url()` SSRF gate its sibling already had; `api.anthropic.com` and `raw.githubusercontent.com` added to the egress safelist; and `.githooks/post-merge`'s `CAST_POST_MERGE_INSTALL_CMD` eval documented as accepted risk. Exception breadcrumbs in `cast-pretool-dispatch.py` and the handoff redaction path use `type(e).__name__` rather than `str(e)`, to avoid embedding user content from `subprocess.TimeoutExpired` or `json.JSONDecodeError`; two sibling sites deliberately keep `str(e)` because reducing them would make a silently-disabled security guard undiagnosable.

### Added

- **`ack_events` gained a reader in the same release that gave it a writer.** It is indexed into `record_fts` under `kind='hatch'`, so `cast ask` answers "which repo used `CAST_RESET_OK`" from the record. The reader belonged in the unit rather than in a backlog: a written-but-never-read table is precisely what `cast-board.sh` was, and a backlog is how that one survived three months.
- **`scripts/cast-check-derived-counts.sh`** — one sweep that RECOMPUTES every derived count in the repo and names the stale ones with the command that regenerates them: `cast-stats.json`, the README badges and sentinels, the skip ledger's call-site **and** file counts, the agent roster count in `CLAUDE.md`, and the completions dispatch-table literal, which appears both in an assertion and in a test *name* where drift is silent. It recomputes rather than proxying — a "has this file changed recently" heuristic is exactly true and says nothing about whether the number in it is right. Mutation-tested by planting a stale count in each of the five surfaces and confirming the sweep names it. Wired into `self-lints` as enforcing, because a release moves more derived counts at once than any other change.
- **`cast review <agent-name-or-prefix> [--last N] [--json]`** — reads agent output back from the record. Subagent final output is lost in transport between agent and orchestrator while `agent_runs.response` held the full text the whole time, and nothing in `bin/cast` read that column. Prints response plus status, tool_uses, duration, branch and model, newest first, with honest zero-handling: no rows → `No agent runs match` (exit 0); NULL or empty response → metadata header plus `(no response recorded)` rather than silent empty output.
- **`cast agents --live`** — distinguishes a slow agent from a dead one by listing in-flight runs with elapsed time. Elapsed is the only live signal; `tool_uses`, `branch` and `model` are written at completion and are empty mid-run by design, and the fixtures were corrected to model that real in-flight row shape (measured NULL in 84/84 running rows) after the shared seed had given them completion-time values.
- **`cast rules sync` / `cast rules status`** and `scripts/cast-rules-sync.sh` — a human-in-the-loop `rules-core/` → live delivery path, closing the gap left by `install.sh`'s skip-if-exists copy. Dry-run by default (IN-SYNC / WOULD-UPDATE / WOULD-CREATE with per-file diffs); `--apply` backs up fail-closed and confirms interactively, or requires `CAST_RULES_SYNC_ACK` non-interactively. Never syncs `*.md.template`. A defect found during independent verification — `sync` and `status` blocks were byte-identical, so `cast rules status --apply` could write to live rules despite its help text calling it a dry run — was fixed by routing both through one implementation with `status` guarding the flag. `resolve_repo_root()` requires a repo-only marker (both `rules-core/working-conventions.md` **and** `install.sh`), so the installed copy cannot sync a stale snapshot over hand-tuned live config.
- **`scripts/cast_ack.py` + the `ack_events` table (migration 034)** — makes escape-hatch bypasses a recorded primitive. CAST had nineteen hand-rolled hatches (`CAST_PUSH_OK`, the whole `CAST_SKIP_*` family, `CAST_RULES_*_ACK`) with inconsistent semantics and no recording, and every new guard added a twentieth; the record is the product, so a bypass that leaves no trace is a hole in it. Bare `=1` is accepted rather than rejected, recording `has_reason=0` with a one-line stderr nudge — requiring a reason would have broken every existing invocation for no gain over recording what was actually given. The property that mattered most is that **recording can never change whether a gate passes**: `record_ack()` cannot raise, the CLI always exits 0, the git subprocess has a 5 s timeout, and a missing or unwritable DB degrades to a no-op. Landed with no caller wired, deliberately, so the migration could soak.
- **`scripts/cast-db-rollup.py` + `agent_runs_daily` and `mcp_calls_daily` (migration 032)** — rolls up agent and MCP trends before the prune destroys them. `cast-db-prune.py` deleted raw rows on a rolling window with nothing aggregating first, which is exactly why the 2026-07-06 cost-audit figures are unreproducible. The rollup uses an authoritative-window rule rather than a blanket monotone guard: days strictly newer than the prune cutoff are deleted and rebuilt from raw, while the cutoff day and older are insert-only. A blanket guard was tried first and proved wrong — `agent_runs.status` is part of the aggregate key but is mutated in place by the stale-run sweeps, so a run inserted as `running` and later flipped to `abandoned` was recorded twice, permanently (measured `SUM(runs)=2` for one real run), and the regression test is mutation-tested against that exact scenario.
- **`tools/justfile` vendored into the repo**, installed by `install.sh`. It previously lived only at `~/.config/just/justfile` outside the repo, which is why adding the rollup tables could not update its readers in the same commit — leaving them silently reading raw `agent_runs` and truncating at the retention window. `cost`, `model-mix`, `cost-weekly` and `model-drift` now read the rollup using `SUM(cost_usd)/NULLIF(SUM(runs),0)` (never `AVG`, which would average pre-aggregated group sums) and never union raw with rollup (which would double-count recent days). `window` reports **both** the raw and rollup spans. Every rollup-backed recipe prints a freshness timestamp and a human-readable `rollup_age`, because the rollup refreshes once nightly so the current day is always partial; the age uses a `TIMESTAMPTZ` cast, since a naive `TIMESTAMP` cast silently drops the UTC `Z` and under-reports staleness by the local offset (measured 1097 s vs the true 15497 s — it would report a stale rollup as fresh). Uniquely among install steps this one **overwrites** rather than skip-if-exists, because skip-if-exists is precisely what previously meant a merged reader fix never reached the live file — but it backs up first and aborts the step if the backup cannot be written, writes atomically, skips a symlinked destination, and disambiguates same-second backup names. A new `cost-outliers` recipe flags agents whose per-run cost exceeds N× the median, with a minimum-runs floor and no cost literal baked in.
- **`scripts/cast-verify-memories.py` + `scripts/cast_memory_meta.py`** — re-verifies file-level `verified_at` instead of letting it rot. CAST had two staleness surfaces and only the DB one was maintained; the file surface was only ever flagged, never re-verified, so stale flags re-accumulated every ~30 days forever. Resolves the concrete refs each stale memory names and classifies REF-BROKEN / REFS-OK / NO-REFS / EPHEMERAL-ONLY; `--apply` bumps `verified_at` on REFS-OK only and writes `verified_by: cast-verify-memories.py (refs-resolved)` alongside it, because a refs-resolved check is a weaker claim than a human confirming the memory is still true and the record should say which one happened. Report-only by default and deliberately not wired into any scheduler — an unattended bump is a verification claim made with nobody watching.
- **`scripts/gen-completions.sh`** — generates the shell-completion subcommand lists from `bin/cast`'s dispatch table. `completions/cast.bash` was stranded on a pre-v7 vocabulary, offering 8 subcommands of which 4 do not exist (`run`, `queue`, `audit`, `daemon`) while omitting 35 real ones; the `cast memory` sub-subcommands offered 4 of 9. Both bash and zsh regions are now sentinel-bounded and generated, the dead subcommands and their completion functions are removed, and the generator fails closed on missing sentinels or unmapped zsh descriptions rather than omitting silently.
- **Two new lint ratchets.** `scripts/cast-lint-source-guard.sh` detects unguarded `source` calls (see Fixed); `scripts/cast-lint-bash32-parse.sh` runs `/bin/bash -n` — the real 3.2.57 on macOS — over every `#!`-bash script before the `act` loop, catching 3.2 parse errors locally instead of after a 47-minute CI round-trip. It states plainly that the check is weaker on Linux, where `/bin/bash` is 5.x and cannot see 3.2-only failures. Recorded honestly: the incident narrative blaming heredoc-inside-`$()` is empirically false — that construct parses cleanly under 3.2.57 — and the verified 3.2-only construct is `;;&` case fall-through, with the original failure's root cause left as *unknown* rather than replaced with a fresh guess.
- **`scripts/cast-rules-drift.sh`** — a read-only detector comparing all 11 repo `rules-core/*` files against live, classifying CORE / TEMPLATE / LIVE-ONLY / MISSING-LIVE, wired advisory-only into `cast-maintenance.sh`. Concrete motivating case: `tests.md` and `shell.md` gained a HARD RULE in PR #313 and live still lacked it seven weeks later with no detection.
- **`scripts/cast-producer-contract-check.py` + a `db-contract` CI step.** `producer-contract.json` declared 7 "live" tables whose writer scripts no longer existed after the `.sh`→`.py` stage consolidation — the audit found 3, the new validator surfaced 4 more.
- **`scripts/cast-test-coverage-advisory.sh`** — a non-blocking pre-commit advisory naming which existing `tests/*.bats` reference each staged file under `scripts/`, `bin/`, `.githooks/` or `completions/`, after a session shipped a defect to CI by running only the suites its change *added*. Matches on repo-relative path rather than basename for signal-to-noise (187 tests would match `bin/cast` by basename vs 35 by path), and always prints a scanned-file count so a silent scan looks distinct from a clean pass.
- **`scripts/cast-hook-lib.sh`** — shared `cast_hook_read_stdin()` / `cast_hook_db_path()`, with two hooks migrated as proof of concept.
- **MCP tool-call observability.** MCP calls were captured by name only; they now record `mcp_server`/`mcp_tool`, an `args_summary` (key names and value shapes only, never values), `outcome`/`error_preview`/`result_size`, and `is_cloud_bound` — derived from the canonical `config/egress-policy.json` rather than transport type, because transport is an unreliable signal (the policy documents that `github` runs over local stdio yet calls `api.github.com`). `error_preview` is sanitized through `cast-redact.py` before truncation and fails closed, dropped entirely rather than stored raw, because truncation is not redaction — GitHub PATs and AWS keys fit inside a 120-character cap. Gated strictly to `mcp__*` so the ~1,300/day non-MCP hot path is untouched. Also fixes `session_id` to read the hook payload before the env var: 98.8% of audit rows previously recorded `unknown` and were unjoinable to `sessions`/`agent_runs`.
- **Raw `SubagentStop` stdin capture behind a directory switch.** Enabled by creating `~/.claude/cast/debug/stdin-capture/` and disabled by removing it — no env plumbing and no settings change, so it cannot switch itself on. Off by default, capped, and verified local-only (both `cast-overlay-sync.sh` and `cast-snapshot.py` use explicit allowlists that exclude `cast/debug`). Cap handling degrades in two deliberately **opposite** directions because the failure costs differ: a malformed `CAST_STDIN_CAPTURE_MAX` degrades to the default and never to "off" (an empty capture dir would otherwise read as "no events observed" — a conclusion drawn from an instrument that was never running), while a malformed count degrades to the cap and never to 0. This is what made the Wave I spoof-channel finding provable rather than INFERRED.
- **`response_excerpt` on SubagentStop reports.** The hook shipped only regex-extracted `Summary:`/`Status:` markers and discarded the full response, so a report lacking those markers reached the orchestrator as an indistinguishable empty husk. Measured over 30 days on 2,437 runs with recorded responses: 21.1% shipped `status:"UNKNOWN"`, 41.4% shipped an empty summary, 19.0% shipped the total husk. The excerpt is capped (`CAST_STOP_RESPONSE_MAX`, default 2000, floor 20, ceiling 20000), redacted **before** truncation, fail-closed, and gated on empty-summary-or-UNKNOWN so a successful extraction does not suppress it. The `Summary:` regex is now anchored to line start — the old unanchored form let mid-sentence mentions hijack the field and left `**` cruft on the common bolded form (364 of 1,414 matches over 30 days). The emitted block carries a trust fence, stated honestly as advisory prompt text and not an enforced boundary.
- **Byte-budget hard ceiling for `rules-core`.** The lint became a two-tier gate: the soft target (`CAST_RULES_BYTE_BUDGET`, 36864) still prints ADVISORY and exits 0; a new hard ceiling (`CAST_RULES_BYTE_CEILING`, 45056) blocks and exits 1 unless `CAST_RULES_BUDGET_ACK` carries a non-empty reason, which is echoed verbatim — sanitized for display only, so embedded newlines and ANSI escapes cannot forge adjacent log lines while the decision logic still reads the raw value.
- **Two launchd observer jobs** — `com.cast.misfire-audit` (weekly, `misfire rank`) and `com.cast.looptrip-scan` (nightly 04:45, `looptrip scan`), both fail-open. `CLAUDE_CODE_MAX_SUBAGENTS_PER_SESSION` is pinned at the CLI's live default (200) as a runaway-fan-out backstop; an earlier draft also added `CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS`, which security review binary-verified does not exist and removed rather than ship an inert key on a protected surface.
- **`skills/seo-checklist`** — SEO/GEO reference skill (metadata, structured data, technical SEO, Core Web Vitals, `llms.txt`, LLM-quotable content structure), cross-referenced from a proportionate `frontend-qa` spot-check bullet. No new agent; `frontend-qa` remains a read-only per-file reviewer.

### Fixed

- **63% of every recorded protocol violation was a well-formed handoff.** `cast_handoff_parser` tolerated markdown in enum VALUES — `**DONE**` normalises to `DONE`, with a comment explaining that agents mean the plain token — and never applied the same tolerance to KEYS. So `**files_changed:** a.py` partitioned on the first `:` into the key `**files_changed` and the required field read as absent, and `files_changed:` with a bullet list beneath read as present-but-empty because the bullets carry no `:` of their own. Measured on the live table: 1,629 of 2,555 `agent_protocol_violations` rows, burying the real ones (`missing_field:blockers`, `invalid_value:status=APPROVED`) roughly 40:1. `_normalize_key()` now strips the decoration agents actually write — emphasis, list markers, JSON quotes — and folds whitespace to `_`; a list beneath a valueless key becomes that key's value. The tolerance cannot manufacture a pass: `files changed` maps onto the required field because that is plainly what was meant, while `files staged` becomes `files_staged` and stays the genuine violation it is, and a guard stops a bulleted `- **status:** DONE` being swallowed as another list entry, which would have destroyed a required field the fix exists to recover. Fixed in both copies — the inline fallback in `cast_subagent_stop.py` runs precisely when importing the canonical module has failed, so it cannot import it — with a parity test alongside the existing status-enum one. Replaying the 1,629 historical rows, 1,221 parse clean; the residual is dominated by `raw_excerpt` truncation in the replay itself. Historical rows are left alone by decision.
- **`cast verify-chain` reported tamper for 244 of 929 links, and not one was tamper.** Level-2 attestation re-derived `session_digest` from LIVE data, joining `sessions`, `agent_runs`, `file_writes`, `routing_events`, `quality_gates` and four integrity tables — none of which are immutable. `cast-db-prune` deletes `agent_runs` while `provenance_chain` is never pruned (the oldest surviving `agent_runs` row is 2026-07-28, and July links verified 40% broken against August's 9% — a cliff, not a coincidence), and `cost_usd`, `tool_uses`, `model` and `status` are backfilled at completion, which is why recent links broke too. A permanently 26%-red chain carries no information: an operator cannot separate a real edit from CAST's own writers, the same defect class as a gate that has never failed, in the mirror-image form of one that can never be green. `provenance_chain.receipt_json` (migration 035) now freezes the exact serialization the digest was taken over, so verification digests the stored payload — a question about the ledger, with one right answer. Live-data divergence is still checked but classified: fields written once at session start (`id`, `project`, `project_root`, `started_at`) cannot drift benignly and are still reported as tamper; everything else is reported as drift and passes. Dropping the live check entirely would have been a false-negative trade, and the pre-existing test that edits `sessions.project` to 'HACKED' is what caught that. Links predating the column report `unverifiable`, never BROKEN, and are not unguarded — level 1 covers every row — with `--require-attestation` for callers that need every link attestable.
- **`cast-ask-index.py --rebuild --kind K` deleted every kind and reindexed one.** The `--kind` filter was applied to the source list, but the `DELETE FROM record_fts` above it was unscoped and ran first: 18,162 rows across eight kinds stood to be destroyed to rebuild any one of them. A known sharp edge that became a likely one when the `hatch` source landed beside it and gave a routine reason to type the flag. The clear is now scoped when `--kind` is given and left unscoped when it is not — correct there, since every kind is being reindexed and an unscoped clear additionally sweeps kinds this version no longer produces. The identical unscoped `DELETE FROM record_embed` in `_embed_pending` is fixed the same way and is worse in kind, since those are Ollama embeddings the run does not recompute for the other kinds.
- **A lost subagent response is recovered from its own transcript.** Every path feeding `response_text` read the payload, so a transport loss left it empty, stage 16 emitted nothing, and the orchestrator saw a silence it could only resolve with a manual `cast review`. Measured over 14 days: 264 DONE runs stored no response, and all 264 had the transcript on disk. The reaper has always had a transcript recovery, but it targets `status IN ('failed','abandoned')`, so a DONE run was never a candidate. Stage 2 already reads the transcript line by line for token counts, so the last assistant turn is captured in that same pass and used only when the payload supplied nothing — tagged `[recovered-from-transcript]`, because its provenance differs from a message the agent actually handed back. `ctx.output_full` is deliberately untouched, so the truncation, completeness and protocol stages keep classifying the payload they were given.
- **Three documents told orchestrators not to run the review gate, on a premise this release made false.** The `cast-conventions` skill asserted that `test-writer`, `debugger`, `backend-writer` and `frontend-writer` "self-dispatch `code-reviewer` internally — do not double-dispatch from the main session", `code-reviewer.md` said "Do NOT dispatch from orchestrating session" for the same reason, and `planner.md`'s manifest template instructed `backend-writer` to dispatch the reviewer itself. At the spawn-depth limit the `Agent` tool is withheld from subagents entirely, and `code-reviewer` is declared `background: true`, which an in-process teammate cannot spawn at all — so an orchestrator following that instruction would have run the review gate **nowhere**. `test-writer.md` said nothing about dispatch at all, leaving the skill's incorrect claim as the only written statement about its gate; it now carries the contract.
- **`record_ack` returned False for three different outcomes and only one was benign** — the hatch was not used, `cast_db` was unavailable, or the write failed. The latter two now log to `~/.claude/logs/`; a legitimate bypass going unrecorded is exactly the hole the primitive exists to close, and it produced no signal anywhere. Exit status is unchanged at 0: recording must never alter whether a gate passes.
- **`commit.md`'s exit-code contract enumerated only 0/1/2**, so 127 (no `python3`), 126 or 137 fell through the prose, and the natural reading of "not 1 and not 2" is the dangerous one. Any other code is now explicitly BLOCKED — a gate that could not run has not passed.
- **The memory verifier called a generated mirror an ambiguity.** `plugin/` is regenerated from the repo, so every bundled file has a twin and a ref naming one matched twice by construction — `planner.md` resolved to two candidates that are the same file. Mirrors are now collapsed only when they are the sole cause of the tie; a ref with two genuine sources stays ambiguous and stays reported, because picking one is a guess. Of 38 stale memories the tool now classifies 8 RETIRED (each with the commit and date that deleted the file), 5 EPHEMERAL-ONLY, 9 REFS-OK, 2 NO-REFS, and leaves 13 for a human.
- **The bash-3.2 parse lint was correct, scanned the right file, and nothing ran it.** Its only caller was `make ci-local`, which needs Docker and act, so in practice it never ran — and it is deliberately excluded from CI for a sound reason: on Linux runners `/bin/bash` is 5.x and cannot see 3.2-only failures. It now runs in `.githooks/pre-push`, which is its real home, since macOS ships `/bin/bash` 3.2 while a bare `bash -n` here resolves to Homebrew 5.3. Verified by reintroducing the defect class it exists for — an apostrophe in a comment, inside a quoted heredoc, nested in `$( )` — where `bash -n` returned 0, `/bin/bash -n` found the error, and the lint blocked. On Linux it INFO-skips rather than passing, because a green result there would assert something that platform cannot test.

- **The hook-contract gate never executed the destructive-op guard it was supposed to validate.** `cast-validate-all-hooks.sh` resolved a hook command by stripping a leading `bash ` and taking everything before the first space. The guard is registered as `python3 ~/.claude/scripts/cast-pretool-dispatch.py`, so the strip yielded the bare word `python3`, failed an `-f` test, and was skipped with a WARN **while the gate exited 0** — and that hook enforces every irreversibility interrupt in the ledger. Arguments were discarded too, so `cast-audit-hook.sh` — registered twice, once `--mode pre` and once `--mode post` — was validated twice as `pre` and the PostToolUse contract was never exercised, while the summary counted never-executed hooks inside "validated N". All 29 CAST hooks are shell form per the docs, so the gate now invokes them the same way. Executability is decided by a pre-execution existence check, **not** by exit code: exit 2 is a legitimate PreToolUse block, and `python3 <missing.py>` exits 2 rather than 127, so an exit-code-only rule reports a missing script as ok. An unrunnable hook is now a FAIL, and executed vs skipped are reported separately.
- **The session-end prune had been failing on every run.** Three of the block's eight `DELETE`s targeted tables that do not exist (`stream_hook_events` was dropped by migration 015; `worktree_events` and `cast_events` have no `CREATE TABLE` anywhere in the repo), so `sqlite3` reported "no such table", continued, and exited 1 — with the status swallowed by `2>/dev/null || true`. A real prune failure from a locked or corrupt DB was indistinguishable from normal operation. The BATS fixture created all three tables in `setup()`, which is why this stayed green over a block that had been failing in production. Failures now capture the real exit code and log via `_log_error` while the block stays fail-open.
- **Nine timestamp comparisons were aimed a day off, and one `cast doctor` check could never fire.** Columns stored ISO-8601 `YYYY-MM-DDTHH:MM:SSZ` were compared raw against `sqlite3`'s space-separated `datetime('now',…)`; because `T` (0x54) sorts after ` ` (0x20), `<` under-matched and `>=` over-matched by up to a day. The "silent truncations (maxTurns)" doctor check compared raw `started_at`, so its stuck-running arm matched nothing and had **never once** reported a pre-reaper truncation — probed against a genuinely 3 h-stale row in production format, the raw compare matched 0 and the wrapped compare matched 1. Storage format was re-derived per column from the live DB rather than assumed: `dispatch_decisions.created_at`, `quality_gates.created_at` and `completeness_events.created_at` are genuinely space-format and are deliberately left raw. Wrapping also closed a pre-existing data-loss path — a row with an empty `started_at` previously satisfied the raw compare and was pruned regardless of age. **The pre-existing tests passed only because their fixtures stored space-separated timestamps rather than production ISO-T/Z**, so they never exercised the bug they appeared to cover.
- **Three uncoordinated stale-run reapers collapsed into one owner.** All three matched only `status='running'` plus staleness with no agent or session correlation, so whichever fired first won and the identical event — `SubagentStop` never firing — landed as `abandoned` or `failed` depending purely on timer phase. `cast-abandon-stale-runs.py` is now the sole reaper (the only one with transcript recovery, incident emission and a correct threshold), verified loaded and actively reaping in the real launchd domain before the other two were removed. The reaping `UPDATE` in `cast-session-end.sh` could never have done its job anyway — the ISO-vs-space compare above meant it reaped only rows from a strictly earlier UTC calendar date; re-adding that exact line as a mutation leaves the new regression test green, which is how the line was proven inert. Historical rows are deliberately left as-is because `status` is part of `agent_runs_daily`'s primary key and rewriting the 52 legacy `failed` rows would desync the rollup; readers accept both values. Its documented cadence had also been wrong since v9.5.2 (`StartInterval` moved to 7200 on 2026-07-09 and the prose was never updated) — and the replacement figure was wrong too: measured against the live record, 17 of 41 reaped rows (41%) exceeded the ~4 h worst case, max lag 18.8 h, with three rows sitting `running` for 59 h across a weekend. Cause: `RunAtLoad=false`, so a powered-off host neither sweeps nor catches up on boot. `RunAtLoad=true` gives one catch-up sweep, and the docstring now states ~4 h is a **floor**, not a bound.
- **`agent_runs` rows that can never be closed.** The SubagentStart hook inserted a row even when the payload carried no agent name, no `session_id` and no `agent_id`; such a row is unmatchable by the stop hook and sat `running` until a reaper aged it — 19 rows in the retained window, none ever DONE. The INSERT is now gated on agent identity, keeping the event file as the forensic trace. A second defect found while testing the first: **`IFS=$'\t' read` collapses an empty middle field**, because a lone tab is still IFS-whitespace, so a payload with an `agent_id` but no session parsed as `SESSION_ID=<agent_id>, AGENT_ID=''` — which both defeated the new gate (dropping a row that *was* closable) and wrote the `agent_id` into a column with an FK to `sessions(id)`. Emitter and reader moved to ASCII unit separator `0x1f`, which is non-whitespace and preserves empty fields. Session matching is now null-safe at all four `agent_runs` sites: the start hook wrote SQL NULL while the stop hook bound `''`, and `NULL = ''` is never true in SQLite — binding NULL is equally wrong, so the `IS` operator is used.
- **782 of 2,158 `dispatch_decisions` rows were stuck `pending`, and the naming convention was the cause.** Rows are written at `PreToolUse(Agent)` with `chosen_agent = tool_input["subagent_type"]` and closed at `SubagentStop` by matching that against the payload's `agent_type` — but when a dispatch carries a custom `name=`, Claude Code puts the **name** in `agent_type`, so the exact match never fired. The daily rate tracked `__`-naming adoption exactly (08-15 100%, 08-16 93.9%, 08-20 18.8%), and it was reproduced on live traffic rather than a fixture. Migration 033 adds a nullable `dispatch_name` column captured from `tool_input["name"]`, mirrored in `cast-db-init.sh` so fresh-install and migrated DBs cannot fork, with the INSERT falling back to the original 5-column form on an unmigrated DB — without which the swallowed `OperationalError` would have silently stopped recording **every** dispatch row. `dispatch_name` is charset-gated and screened through `cast-redact.py`, fail-closed to NULL, because the name charset is a superset of AWS-key and GitHub-PAT alphabets and cast.db can sync off-machine. The consumer half matches exactly on `dispatch_name` using `=` rather than `IS` (so a NULL can never be captured by the exact step), falling back to the FIFO `chosen_agent` match widened with `? LIKE chosen_agent || '\_\_%' ESCAPE '\'`. The `ESCAPE` is load-bearing, not decoration: `_` is a LIKE wildcard, so unescaped, `code-reviewerXY-unit-a` would match `chosen_agent` `code-reviewer` and close a different agent's row.
- **`__`-named reviewer dispatches could not satisfy the approval gate.** The dispatch-naming rule requires roster dispatches be named `<agent-type>__<label>`, but `cast_check_approvals`'s Tier-2 fallback matched the agent name by exact equality — so a reviewer dispatched as `code-reviewer__fix-x` could never satisfy a `code-reviewer` requirement, and the commit agent BLOCKed twice reporting a review as missing when it had run and passed. The gate did not fail open, but it named the wrong cause: an operator reading it concludes the reviewer never ran. Widened with an anchored `LIKE … ESCAPE`, escaping `\` then `%` then `_` — without which `code-reviewer2b` would satisfy a `code-reviewer` requirement.
- **Zero of 75 `failed`/`abandoned` runs preserved any output — 67 of them still had their full transcript on disk.** `SubagentStop` never fires on the abort path, and none of the stale-run sweeps ever touched `response`. Recovery is now an idempotent backfill keyed on **row state** rather than a step inside one sweep's flip, since three sweeps reach these rows and scoping to one would strand every row the others got first. It prefers the agent's last prose over its last tool call (taking the terminal message recovered a stray `git ls-remote` invocation while the agent's actual report sat in earlier text blocks — measured, not theorised), tags genuine `StructuredOutput` deliverables distinctly from an incidental terminal tool call, never overwrites a real response (guarded in both the SQL predicate and the Python), and degrades per-row so one bad file cannot stop the sweep. The explicit marker is kept for the 8 rows with no transcript, because an honest statement of absence beats silence. Measured against a copy of the live DB: 0 → 67 of 89 rows recover genuine prose, idempotent on a second run.
- **`agent_runs.response` was empty for 462 of 2,909 DONE runs (15.9%) — 99.6% of them Workflow stages whose terminal turn is a tool call.** `parse_input()` extracted only `type=="text"` blocks plus three flat fallback fields, none of which exist on a tool-call turn; the content sat intact in the transcript and was never looked at. Not a write failure — the same `UPDATE` wrote correct `tool_uses`, `cost_usd` and `model` for those rows. The terminal `tool_use` block's `input` is now recovered, tagged `[structured-output:<name>]` or `[last-tool-call:<name>]`. **Recovered content is fenced out of the verdict classifiers**: `output_full` feeds `compute_gate_match`, whose verdict flows to `CAST_GATE_MATCH` → a status file → `_agent_completed_this_session`, which clears `requires_agent` BLOCK policies for DONE — so recovering content without the fence meant an ordinary `{"status": "DONE"}` payload, or a shell command containing the word, would write a policy-clearing verdict the agent never gave. A `response_is_structured` flag excludes it, leaving classification bit-for-bit identical for every run.
- **Same-second event filenames silently overwrote each other.** All four event-filename builders used a second-resolution UTC stamp, reproduced directly: two back-to-back payloads left one file. The events directory is the forensic trace CAST falls back on when a DB row is absent, and it under-counted precisely during bursts — which is when anomalies arrive — so any figure derived by counting event files was a floor. A disambiguator is inserted between the leading timestamp and the existing suffix so the `%Y%m%dT%H%M%SZ` prefix stays byte-identical and leading, and every existing glob still matches.
- **`cast tidy` deleted `agent_runs` rows from the live record with no backup and no gate**, unattended nightly at 03:00 via launchd, with `--dry-run` opt-in so destructive was the default. A confirmation prompt would be the wrong shape — it would hang or be bypassed under launchd — so it mirrors `cast-db-prune.py`: run `cast-db-backup.py` first, delete only on exit 0, otherwise skip, log, and continue to exit 0 to preserve the launchd contract. The subprocess is bounded at 120 s in Python (no cast plist carries a timeout key and `KeepAlive` is false, so launchd would not reap a hung job, and `timeout(1)` is absent on stock macOS). Every malformed timeout value fails closed.
- **The prune now depends on the rollup, fail-closed.** `_pre_prune_rollup()` runs after the backup gate and before any delete; rollup failure skips all four delete steps and VACUUM, exits 0 to preserve the launchd contract, and names the DB-growth consequence in the ERROR log. It validates the payload (parseable JSON, dict, `dry_run is False`, four count keys present/int/non-bool/non-negative) and **scrubs `CAST_DB_ROLLUP_DRY_RUN` from the child environment** — an inherited dry-run made the real rollup write nothing, exit 0, and report would-be counts while the prune deleted the rows those counts described. Child output is escaped in both gates' ERROR logs so multi-line child errors cannot inject unprefixed lines into the prune log.
- **The memory verifier was calling refs broken that were sitting on disk — 63 of the 178 it flagged, a 35% false-positive rate.** A first version searched only cwd- and `$HOME`-relative paths (most of the misses were in `scripts/`); refs now resolve against an explicit, ordered, named root list so a REF-BROKEN claim is auditable. Two further gaps: `claude/`-prefix refs were never checked against the pseudo-namespace fallback, and repo-suffix matches resolved candidate paths that do not exist — multi-hit suffix matches are now reported ambiguous and stay REF-BROKEN rather than resolving to an unchecked guess. Separately, the project-dir encoding flattens `_` and `.` to `-` as well as `/`, so a directory named `report_v2.0` encodes as `report-v2-0` and never decoded; `decode_project_dir()` gained a bounded second pass (36 extra `isdir()` probes maximum, constant regardless of path depth — never an unbounded walk). And 33 refs pointed at ephemeral session artifacts destroyed by the 2026-06-02 and 2026-06-11 `~/.claude` wipes: those memories correctly recorded a pointer to something that later ceased to exist, which is not the memory rotting, so a new EPHEMERAL-ONLY class reports them separately and is never `--apply`-bump-eligible. Real corpus: 29/8/2 → 22 REF-BROKEN / 10 REFS-OK / 2 NO-REFS / 5 EPHEMERAL-ONLY.
- **`source X 2>/dev/null || true` aborted under Apple's bash 3.2.57.** With `set -e`, 3.2.57 treats `source <missing-file>` as fatal even as the left operand of `||` (bash 4+ does not), so every graceful-degradation source aborted on macOS whenever the lib was absent. 11 call sites across 10 scripts converted to the existence-guarded idiom; `cast-guard-lib.sh`'s header had been documenting the broken convention and was rewritten.
- **The Python unit suite was writing synthetic rows into the live `~/.claude/cast.db`** — measured `routing_events` +2 per full `unittest discover`, with 16 fixture rows accumulated over multiple runs. Root cause: six `tearDown` methods called `os.environ.pop('CAST_DB_PATH', None)` unconditionally, while two modules set `CAST_DB_PATH` at **module-import** time — so once popped by an early teardown, modules later in alphabetical discovery order silently fell back to the real DB. All six now save in `setUp` and restore in a `finally:`. A ratchet test sorted alphabetically last observes pollution from every other module and lints siblings for unguarded pop/del, reporting `file:line` — catching invisible leaks that row-delta symptoms would never surface.
- **`make ci-local` ran the BATS suite three times (~2.5 h) and could silently skip its only hook-contract coverage.** The `contract-test` and `hook-contract-validation` act jobs both declared `needs: bats`. `contract-test` is advisory-only by construction (`|| true` plus `continue-on-error: true`) and was dropped outright; `hook-contract-validation` is a real gate and was preserved as a direct command — but *after* the loop, so when `python-unit` (the loop's last job) failed, the loop's `exit 1` aborted make and the hook gate never ran, silently. Both now run directly **before** the loop as unsuppressed recipe lines. `python-unit` leaves act entirely: PyYAML is absent from `catthehacker/ubuntu:act-latest` but present on GitHub's `ubuntu-latest`, so under act it was permanently red for a reason unrelated to any regression — a gate you learn to ignore. Guarded by a hermetic ratchet that copies the real Makefile into a temp dir, stubs `act`/`docker`/the validator, and asserts the gate still runs when act fails.
- **Two generators could rewrite the wrong repository's tracked files.** `gen-completions.sh` and `gen-rules-manifest.sh` both resolved their root with a bare `cd "$(git rev-parse --show-toplevel)"`, which without `-C` resolves from the **caller's** cwd — so a copy run from inside a different repository would silently rewrite that repository's files. Both now anchor to their own location and fail closed when that directory is not inside a git repo. Two two-repo regression tests place a generator copy in repo A, run it with cwd set to unrelated repo B, and assert B's tracked sentinel is byte-for-byte untouched.
- **`gen-plugin.sh` bundled the working tree, not the index.** Anything untracked or gitignored under `skills/` or `commands/` was bundled into the committed `plugin/` mirror — live case: the third-party `skills/neon` and `skills/neon-postgres` installed via `npx skills` are gitignored, and a regeneration would have committed them into a public repo and moved the bundled skill count 18 → 20. Ignoring a path closed one route, not the class: both sites now source from `git ls-files`, which is also how `cast-stats-lib.sh` already counts skills — bundler and stats gate had been encoding one policy in two mechanisms that disagreed, and the disagreement was the bug. Fails closed on a git error or non-work-tree rather than falling back to a working-tree copy.
- **The resume distillate shipped `{{placeholder}}` slots into real resumes** — a continuity leak dressed as a continuity tool. §1, §4 and §5 are now populated at generation time from the record; where nothing is derivable it says so explicitly rather than emitting a placeholder or a confident guess. `agent_runs.status` never holds the literal `DONE_WITH_CONCERNS`, so concerns are detected from the `Status:` line in the recorded response. The test asserting placeholders were present is inverted to assert they are absent.
- **`cast_write_status()` failed under zsh**, where `status` is a reserved variable like `$?`. Renamed, with a regression test that runs under a real zsh subshell.
- **`cast doctor`'s redaction-failure check could never be cleared.** It counted `[REDACTION_FAILED]` marker rows with no `resolution_status` filter, so no operator action could clear it short of deleting incident rows — making the record lie to silence the monitor. It now counts only unresolved rows; triaged rows emit a visible `[ok]` line rather than silence; NULL/empty/unknown counts as unresolved; and SQL errors surface as INFO, never a false green. `CAST_SCRIPTS_DIR` and `CAST_AGENTS_DIR` were also silently ignoring every override — a documented `CAST_AGENTS_DIR` export in the doctor's own test file had been dead code for months.
- **The status enum rejected a valid contract value.** `NEEDS_CONTEXT` was added across the agent roster on 2026-07-10 but the validators in 5 locations were not updated, producing **41 rows of false-positive protocol violations** spanning 2026-07-02 to 2026-08-04 that marked compliant agents as violators. All copies updated, with a parity test to prevent divergence, and the parser now tolerates markdown emphasis and trailing prose. Separately, fail-closed redaction discarded its only diagnostic evidence along with the raw text, leaving two live incidents permanently unroot-causable; a content-free breadcrumb (exception class name, input byte length, hardcoded site label) now survives.
- **The `~/.claude/backups` advisory told operators to do something harmful** — migrate config snapshots into a DB-backup directory that contains zero `.db` files. Removed. The prune path in the same script now uses an explicit `20*-*` allowlist rather than a catch-all inside the twice-wiped `~/.claude`, and logs each path before deletion instead of swallowing `cast_safe_rm`'s refusal diagnostics.
- **`install.sh` printed "Skipped (exists)" for rules whether live was byte-identical or arbitrarily stale.** A report-only drift WARN now names the drifted files and points at `cast rules sync`. Skip-if-exists is deliberately unchanged — unattended overwrite of hand-tuned live rules is the wipe-class risk. `cast doctor`'s rules-drift check had a related defect: it iterates `~/.claude/rules-core/`, which `install.sh` populates with a hardcoded three-file subset, while the repo holds nine CORE files — so it was structurally blind to six of nine while printing an unqualified "in sync", a verdict that for those six **could not fail**. It now prints how many baseline files were actually compared.
- **`tests/run.sh` fell through to PASSTHRU on a bare positional argument**, silently running the full suite — the mechanism behind two `~/.claude` wipe incidents. Now fails closed. `run.sh` also gained a fresh-clone preflight that checks for `load.bash` in both bats submodules (an uninitialised submodule leaves an empty directory, which a bare `[[ -d ]]` would wrongly pass) and exits with the exact remedy — gated on `.gitmodules` presence so synthetic fixture repos are correctly exempt.
- **A BATS fixture must never contain the `@test` token at any indentation.** `cast-count-planned-tests.sh` counts only `^@test` while CI's bats parses `^[[:space:]]*@test`, so indenting a fixture's marker to satisfy the counter is exactly what makes bats read it as a declaration in the outer file — two fixtures sharing a name aborted the whole `make ci-local` run, green locally on Bats 1.14.0 which does not do this. Fixtures need only the path literals the code greps for.
- **Ref-overwrite guard tests leaned on ambient repo state.** Overwriting a ref is destructive only when the ref already exists, so the tests shelled out to `git rev-parse` in the process cwd and used this repo's `refs/heads/main` — which exists on a developer checkout but not in a detached CI checkout, so the guard correctly saw a ref *creation* and allowed it. The guard was right; the tests were not hermetic. Two sibling tests were worse than the red one: they asserted ALLOW, and in CI everything of that shape was allowed, so they passed for a reason unrelated to what they claimed to check.

### Changed

- **`code-writer` retirement completed across every surface.** The 22 → 27 roster split shipped in v9.5.3 left a ghost reference in enforcement config (`chain-map.json`, `agent-groups.json`, `ATTEST_ENFORCE_AGENTS`), validation, 8 agent definitions, 6 scripts, 2 skills, 2 commands, agent contracts, schemas, 11 docs files and the eval fixtures. `cast-validate.sh` Check 13 now cross-checks `agent-groups.json` against `ATTEST_ENFORCE_AGENTS` so this drift class cannot recur silently.
- **`rules-core/` reconciled with live in both directions.** The repo copy — which is the restore source after a wipe — had drifted stale in 7 of 10 hunks and would have reverted the BATS temp-`$HOME` rule from "permanent" back to "conditional on a pending fix", restored unreproducible cost figures that must not be re-cited, and re-added the github MCP that was explicitly removed. Three cases where live was the more accurate copy were absorbed the other way. New rules recorded from real failures this cycle: the `<agent-type>__<label>` dispatch-naming convention; the two causes of agent silence and how to tell them apart; checking `agents --live` before re-dispatching; the orchestrator-run review gate as the single documented path; the premise-vs-mechanism ("proxy") rule and the mutation-test rule; the `@test`-in-fixtures trap; and exit-code masking widened from `tee` specifically to **any pipeline as the last command**, after it was re-hit in a displaced form where a correctly-redirected run still reported 0 because the final command was `echo "$?" | tee -a "$LOG"`. The retention paragraph headed "Measure, don't remember" was itself remembering: it claimed a rolling 30-day window when `CAST_DB_PRUNE_DAYS` has defaulted to 90 since 2026-07-04, conflating the prune **window** with the **retained** span — a distinction that matters, because a v10 release criterion had been written as something nothing in a 30-day-deep DB could satisfy against a 90-day window.
- **OTEL retention default lowered 30 → 20 → 10 days**, and `CAST_PRUNE_OTEL_DAYS=10` pinned in `macos/cast-db-prune.plist` so the scheduled prune's window is deterministic rather than drifting with ambient env.
- **README rewritten for accuracy.** The project's thesis is honesty, which made its own unsupported claims the sharpest liability. Two independent fact-audits found three **false** claims (a "good first issues" invitation to a label with zero open issues, via a *closed* pinned issue; an `apt-get` package for bats that does not exist; a `rules-personal/` directory not in the repo), two **stale** ones (it told every visitor CAST had been in maintenance mode since v9.5 while 39 commits and ~42k insertions of v10 landed, the most recent the same day; and the 64.6% agent-spend figure that `rules-core/working-conventions.md` explicitly retracts with "Do not re-cite it" — the README was the last place citing it), and two unverifiable headline cost stats whose cited source contained none of the figures. The economics section now states its measurement window, says plainly that the figure is not reproducible today because retention pruned the rows, and publishes the `just -g window` / `cost` / `model-mix` recipes so a reader measures their own data instead of trusting a frozen literal. **The second audit found five further defects introduced by the rewrite itself** — an unsupported `cast doctor` claim, a false "the runner CI uses", a dangling concept-link, an illustrative figure that failed the tool's own integer arithmetic, and a demo block whose shape had drifted from real output. Prose down ~33% with every substantive claim retained.
- **`infra-writer` restructured** from a flat responsibilities list to a numbered workflow branching by artifact type, with a Status routing section naming four failure modes and their fallbacks — raising it 18 → 22 on the agent-quality rubric, so all 26 scored agents now clear 19. The rubric itself gained scores for the 13 previously-unscored agents and replaced its "all agents score 19+" hedge with the actual distribution.

### Removed

- **`scripts/cast-command-guard.sh`** — a 327-byte PreToolUse wrapper superseded by `cast-pretool-dispatch.py`, never wired (settings assert its absence), whose only added behavior was a `CLAUDE_SUBPROCESS=1` bypass the Python deliberately lacks. Removal was verified to **strengthen** enforcement. Three architecture docs that still described it as live were repointed, and the 97-call-site test suite retargeted. The canonical `CLAUDE_SUBPROCESS` ledger in `cast-protocol-spec.md` §2.5 and `docs/escape-hatches.md` were corrected in the same pass: both claimed the git guard and command guard **skip** under `CLAUDE_SUBPROCESS=1`, which is false and dangerous — someone could have "restored" a headless bypass as if it were spec. Those guards fire unconditionally; only Write/Edit-policy, egress and dispatch-capture skip.
- **`scripts/cast-stats.sh`** — zero callers repo-wide and in live `~/.claude`, and the measurement it carried was wrong: `--brief` counted event **files** as completed agent runs, reading 371 "agents today" against 153 real `agent_runs` rows, because most of those files are SubagentStop heartbeat ticks. Its own comment asserting otherwise was false. Deleted rather than fixed, since nothing consumed it. Noted honestly: the repo's orphan lint did not catch this because it matches a bare basename substring, so a comment mention counted as a caller (tracked as J-10).
- **`config/routing-table.json` retirement completed.** PR #152 deleted the file and its two readers in June but left three surfaces describing the dead mechanism plus a live artifact on every machine installed before then — including a false claim in `code-reviewer.md` that "routing-table post_chain fires code-reviewer and security in parallel", and an orphaned test fixture whose comment cited a "Check 11" that does not exist. `install.sh` gained the missing retirement line.

### Performance

- **Python cold-start consolidation.** The SessionStart hook went 3 synchronous `python3` heredoc blocks → 2 (the banner block stays separate for its distinct stdout contract); redundant `python3 -c` invocations were merged in `cast-exec.sh` (5 sites → fewer, via tab-separated single-spawn extraction), `cast-upgrade-check.sh` and `cast-managed-agent.sh`. Sites parsing distinct inputs at distinct control-flow points were deliberately left alone rather than restructured for a mechanical dedup. **The regression guard for this was itself false-green**: it counted only `python3 -c` and was blind to `python3 <<` / `python3 - <<` heredoc spawns; extending it surfaced three files with previously invisible heredoc debt, grandfathered at true counts.
- **`cast-mcp-server.py`** `_resource_schema` N+1 COUNT loop → 2 batched queries with per-table fallback, output shape preserved. **`cast-db-prune.py`** reclaims freed pages via VACUUM, guarded to run only when rows were actually deleted. **`cast-memory-validate.py`** and **`cast-db-routines.py`** cap unbounded `SELECT *` reads with defensive LIMITs and stderr cap-hit warnings, so truncation is never silent.

### Audit / process notes

- Three `/cast-audit` remediation batches landed (2026-07-22, and 2026-08-04 in three parts), plus a dedicated pass on `/doctor`'s own honesty surface and a Session E hook-surface audit that found the hook-contract gate defect above.
- **Test suite 2,353 → 3,244 across 204 → 236 files**; cast.db tables 39 → 42; skills 17 → 18. The counting mechanisms themselves drifted twice during the release: `docs/test-skip-ledger.md`'s file-count column is not enforced by `skip-ledger-drift.bats` (which checks only the call-site number) and drifted silently, and the pre-push stats gate does not cover the skip ledger at all — both recorded as an open derived-count sweep rather than papered over.
- **The pre-push PII gate and `ci-pii-scan.sh` do not agree, in both directions**, and both were tripped by legitimate test fixtures during this release: `ci-pii-scan.sh` flagged a low-entropy fake AWS key that `gitleaks` skipped, and `gitleaks` flagged a line the other passed. Every case was resolved by splitting the literal so no tracked line matches, never by an allowlist entry — an allowlist would blind both scanners to a real secret committed there later. One case is worth recording for why it surfaced late: a security gate ran `ci-pii-scan` over an earlier unit and passed **honestly**, because the offending fixture did not exist yet. A gate verdict covers the tree as it stood when it ran, so repo-wide gates need re-running after the **last** unit lands, not the first.
- `ruff` is pinned to `0.15.14` in `security-scan.yml`; the unpinned install floated to 0.16.0, whose new default rules failed `python-lint` repo-wide independent of any change here. Un-pinning is a tracked follow-up.

## [9.5.3] — 2026-07-11 — agent roster split + workflow-cost audit + CI hardening

Closes out the v9.5 line. Started as a review of whether any agent should escalate to Opus now that Sonnet 5 is the main-loop driver (answer: no — the escalation bar is irreversibility + infrequency, not raw capability, and only `migration-reviewer` clears it); grew into a full roster split plus two systemic bug fixes surfaced along the way.

### Changed
- **Agent roster split, 22 → 27 agents.** `code-writer` retired, split into `frontend-writer` + `backend-writer` (React/Vite/TS vs. Express/Node/SQLite). `docs` trimmed to README/doc-update only, spinning off `report-writer` (status/chain-summary reports) and `email-drafter` (email drafting + portfolio-sync). `researcher` trimmed to codebase/tech-research, spinning off `db-reader` (read-only SQL analysis — also fixes a stale reference in the personal rules config that named `db-reader` as an agent no longer wired). `devops` trimmed to CI/CD, spinning off `infra-writer` (Docker/Terraform/deployment/env-hygiene). Model tiering recomputed: Haiku 16 / Sonnet 10 / Opus 1 = 27. All cross-cutting surfaces (README, `docs/agents/AGENT-ROSTER.md`, agent-registry skill, plugin curation, eval fixtures) updated in step.

### Added
- **`scripts/cast-workflow-model-audit.py`** — fleet-level opus-share trend detector for the `Workflow`-tool cost lever (a 2026-07-06 fix added per-stage model guidance to `working-conventions.md`, but it was advisory-only with no enforcement). Wired into the existing weekly record-review report rather than a new schedule. Documented limitation: the SubagentStop hook doesn't expose per-stage labels, so this verifies fleet-level trend only, not true per-stage compliance.

### Fixed
- **`tests/rules-drift.bats` destructive test-isolation bug.** Its drift test mutated and `git checkout`'d the real tracked `rules-core/working-conventions.md` as its own cleanup — reverting any legitimate uncommitted edits present when the suite ran, not just its own scratch edit. Now isolated to a disposable `git worktree`.
- **`.githooks/pre-push` stats-drift gate gap.** CI's `stats-guard` workflow runs two checks (`gen-cast-stats.sh --check` for `cast-stats.json`, `gen-stats.sh --check` for README/`docs/*.md` sentinels); the pre-push hook only ever ran the first, so a clean local push could still fail CI — the root cause of a stats-guard failure recurring across several PRs. Hook now runs both checks inside the same per-pushed-SHA worktree.
- **3 CI regressions from the roster split, caught by the full BATS suite:** an eval-case ID collision (`frontend-writer` and `backend-writer` both shipped an eval case named `hallucination-claimed-file-write.yaml`, which `cast-eval-runner.py` resolves by filename stem across the whole tree — non-deterministic, resolved by renaming both to agent-scoped IDs); two stale hardcoded agent-count assertions (`tests/scripts/gen-plugin.bats`, `tests/cast-plugin-smoke.bats`, `tests/cast-stats.bats`); one stale reference to the retired `code-writer.md` in `tests/install-personal.bats`.

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
- **`cast doctor` MCP check enumerates all local scopes** — settings.json + settings.local.json + `$PWD/.mcp.json` (Option-B). ⚠️ **Correction (v10, DOC-1):** this was false as shipped — Claude Code does not read `mcpServers` from `settings.json`/`settings.local.json` at all; the authoritative sources are `~/.claude.json` (both its top-level `mcpServers` and per-project `projects.<cwd>.mcpServers`) plus `.mcp.json`/`managed-mcp.json`. `~/.claude.json` was missing from the scan, so doctor could report "none configured" while servers were live. Fixed in v10 — see DOC-1 in the v10 entry.
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
