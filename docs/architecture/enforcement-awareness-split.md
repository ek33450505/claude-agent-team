# Enforcement vs. Awareness — the guard classification (CAST v9 P0)

> **Principle (`master_v9.md` §0.3):** *Enforcement* = native `permissions.deny` + the OS
> sandbox (the real, non-bypassable boundary **where Claude Code engages its sandbox — see the
> Platform engagement caveat below**). *Awareness* = hooks (advisory, fail-open,
> feed the record). **No guard claims to be both. Advisory hooks never masquerade as
> enforcement.**

This document classifies every CAST PreToolUse / sandbox guard as **enforcement** (move to
or keep in a native primitive) or **awareness** (a fail-open hook that records + advises),
and records, per guard, whether a native primitive *can* express its guarantee.

## Headline finding

**The split is already correct — no guard should move.** Every boundary that a native
primitive *can* faithfully express is **already native** (sandbox + `permissions.deny`).
Every guard that remains a hook does so because the official docs confirm native cannot
express its guarantee — and in several cases the docs **explicitly recommend a PreToolUse
hook** for exactly that job. This unit therefore ships the *documented* classification plus
honesty relabeling, not a migration.

## ⚠️ Platform engagement caveat (the honest qualifier)

**Verified on this maintainer's machine (macOS 26.5.1, 2026-06-29):** the `sandbox.*` flags
classified as "enforcement / ALREADY NATIVE" below are **configured** and would enforce on a
platform where Claude Code engages its OS sandbox — but on macOS 26.5.1 the CC sandbox
**engagement gate declines** (the `f1n()` / SRT `isSupportedPlatform`-or-`checkDependencies`
short-circuit returns false; the OS Seatbelt layer itself works, but CC never hands the command
to it). A direct probe (W1a, CAST v9) confirmed `curl` to a non-allowlisted domain returned
`200` from a sandboxed Bash call. **So on this machine the sandbox boundary is INERT and the
egress hook (advisory, log-only) is the only live recording layer.**

The classification below is therefore the **design** — what a native primitive *can* express
and is *configured* to express — not a claim that the boundary is currently active here. Where
this document says a guard is "enforced" by the sandbox, read it as *"enforced where CC engages
the sandbox; otherwise the hook is the live layer."* CAST does **not** relabel the
egress/credential hooks as redundant on the strength of configured-but-inert flags — the record
is the product, and on this platform it is also the only enforcement signal.

## What native CAN and CANNOT express (verified against official docs)

Sources: `permissions.md`, `sandboxing.md`, `hooks.md` (code.claude.com), via `claude-code-guide`.

| Capability | Native? | Note |
|---|---|---|
| Deny a tool / coarse command prefix (`Bash(git *)`, `Bash(rm *)`) | ✅ | Prefix-glob matching |
| **Path-aware** Bash matching (block `rm -rf ~/.claude`, allow `rm -rf ./node_modules`) | ❌ | Docs: prefix parsing, *not* path-semantic. Docs **recommend a hook**. |
| **Env-var-conditional** allow (`CAST_COMMIT_AGENT=1 git commit`) | ❌ | Deny rules cannot read env or carry allowlist exceptions. Docs: use a hook. |
| Indirection-robust subcommand block (`cd /x && git push`, `g=push; git $g`, subshells) | ⚠️ | `Bash(git push *)` catches simple/compound forms; **fragile** to vars/subshells. Docs recommend a hook for reliable blocking. |
| Credential-read block (`~/.ssh/id_*`, `~/.aws/credentials`) | ✅ | `sandbox.filesystem.denyRead` — OS-level (Seatbelt/bubblewrap), all subprocesses |
| Network egress restriction | ✅ | `sandbox.network.allowedDomains` — built-in proxy, hostname allowlist |
| Subagent model cap | ✅ | native `Agent(model:)` deny rule |
| Content sensitivity / credential→egress correlation / a local audit record | ❌ | Net-new value of the egress hook; native has no concept |

**Precedence (docs):** `deny → ask → allow → prompt`, with the **sandbox enforced on top**
once a permission allows the command. A broad deny cannot carry a narrower allow exception.

## Guard classification

| Guard (hook) | Class | Native primitive can express it? | Verdict |
|---|---|---|---|
| `cast-git-guard` — git commit/push/stash blocks | enforcement-intent | ❌ env-var escape hatch + indirection-robustness | **KEEP as hook** (docs recommend a hook here) |
| `cast-git-guard` — Write/Edit `requires_agent` policy | enforcement-intent | ❌ stateful (per-session agent-status) | **KEEP as hook** |
| `cast-command-guard` — pkill/killall/mass-kill/catastrophic-rm | enforcement-intent | ❌ path-aware + escape hatch | **KEEP as hook** (already self-labeled "defense-in-depth, not a complete sandbox") |
| `cast-command-guard` — RULE 5 Bash writes into the installed exec surface | enforcement-intent | ❌ path-aware Bash analysis + escape hatch (native deny covers only the file tools) | **KEEP as hook** (defence-in-depth for sandbox-OFF; the sandbox is the hard boundary) |
| `cast-git-guard` — exec-capable git config / gc / worktree prune / symlinked worktree entries | enforcement-intent | ❌ argument + filesystem-state aware | **KEEP as hook** |
| `cast-install-integrity` — install manifest alarm (SessionStart + doctor) | **awareness** (detection) | ❌ | **KEEP** (detects what slips past string guards) |
| `write-guards` — literal-tilde write block | enforcement-intent | ❌ path-pattern correction | **KEEP as hook** |
| `write-guards` — stat-claim badge gate | awareness/quality | ❌ | **KEEP as hook** (advisory) |
| `write-guards` — no-fake-success | awareness | ❌ | **KEEP as hook** (already advisory) |
| `cast-egress-sentinel` — off-machine-bound recording | **awareness** | partial (coarse access is native; the *record* + content-sensitivity is net-new) | **KEEP as hook** — the record is the product (§1) |
| `cast-audit-hook` — web/PII audit record | **awareness** | partial | **KEEP as hook** (audit record) |
| Credential reads | **enforcement** (engagement-gated) | ✅ `sandbox.filesystem.denyRead` *(configured; inert where CC's sandbox doesn't engage — see caveat)* | **NATIVE WHERE ENGAGED** — egress hook is the live record, and the only layer where the sandbox is inert |
| Network egress | **enforcement** (engagement-gated) | ✅ `sandbox.network.allowedDomains` *(configured; inert where CC's sandbox doesn't engage — see caveat)* | **NATIVE WHERE ENGAGED** — egress hook is the live record, and the only layer where the sandbox is inert |
| Subagent model cap | **enforcement** | ✅ `Agent(model:)` deny | **ALREADY NATIVE** (shipped via `11-deny.json`; supersedes the direct `settings.json` edit from `73d0db1` — see §11-deny layer below) |

## The honesty correction (§0.3)

Because the bespoke hooks block via `exit 2`, their comments historically read as hard,
non-bypassable boundaries (e.g. *"Exit 2 = hard block (Claude cannot bypass)"*). That
over-claims: a PreToolUse hook is **advisory-grade** — it is the model-facing block in an
interactive session, but the **non-bypassable** boundary for the catastrophic classes
(credential reads, network egress, filesystem) is the **OS sandbox**, which the docs confirm
is enforced for all subprocesses **on a platform where CC engages it** (on this maintainer's
macOS 26.5.1 the engagement gate declines, so in practice the egress hook remains the live
layer — see the Platform engagement caveat above). The guards' comments are relabeled to say so. The hooks
remain valuable as the *path-aware / escape-hatch / indirection-robust* layer the sandbox
cannot express, and as the **record** — but they no longer masquerade as the wall.

## Headless-context skip: the Write/Edit policy layer (GOV-1 residual — by design)

`write-guards.sh` (the PreToolUse `Write|Edit` wrapper) exits 0 immediately when
`CLAUDE_SUBPROCESS=1` (line 5), and `cast-git-guard.py` applies the same skip to its
Write/Edit `requires_agent` policy engine and agent-status TTL sweep. The entire
Write/Edit policy layer — including the G1 docs-destroy guard (PR #320) — therefore does
not run in managed/headless sub-claude contexts.

**This is intended, not a hole** (v9 live-fire audit, probe B6, 2026-07-01):

- `CLAUDE_SUBPROCESS=1` marks managed/headless sub-claude processes ONLY. Agent-tool
  subagents do NOT carry it — probe B6 behaviorally proved that a subagent docs-delete
  without ack is BLOCKED (exit 2, fixture unmodified). The static-audit claim that
  `write-guards.sh:5` lets subagents bypass G1 was REFUTED live.
- The skip exists for recursion prevention: hook-spawned sub-claude processes must not
  re-enter the hook pipeline.
- The irreversible git/destructive command guards are NOT part of this skip — post-U6 they
  run in EVERY context (see the note in `cast-git-guard.py main()` and probes B1/B5/B6).

**Residual (accepted + mitigated):** a genuinely headless run (`CLAUDE_SUBPROCESS=1`
automation, cron/launchd) performs Write/Edit without the policy layer, so the G1
docs-destroy guard does not bite there. The backstop is CI: the `docs-destroy-guard`
workflow re-runs the same net-deletion check on every PR to `main` and is a protect-main
REQUIRED status check (added 2026-07-01), so a headless docs destruction cannot reach
`main` unacknowledged. This matches the irreversibility-interrupt rule: hooks are never
the unattended-safety layer — fail-closed script gates and CI carry that job.

## Net change from this unit

- **Code:** none moves to native (the analysis above shows nothing *can* move that isn't
  already native). Only the over-claiming comments are corrected.
- **Defense-in-depth:** the catastrophic boundaries are *already* native (sandbox), so the
  hooks are correctly the second layer, not the only one.
- **Follow-up (not done here):** confirm `sandbox.filesystem.allowWrite` live semantics and
  document the effective Bash-write boundary; consider a coarse `permissions.deny` backstop
  only if a real, native-expressible gap is found (none identified).

## The `11-deny.json` categorical deny layer (C1 + B2, v9)

Added in CAST v9 (branch `feature/v9-b2c1-permissions-deny`). Shipped as a CAST-owned
managed-settings fragment so deny rules reach existing installs on reinstall (unlike the
one-time `settings.json` edit from commit `73d0db1`).

### What it blocks

| Rule | Goal |
|---|---|
| `Agent(model:claude-fable*)` | **C1 model cap** — block all Fable versions (claude-fable, claude-fable-5, future) |
| `Agent(model:claude-mythos*)` | **C1 model cap** — block Mythos dispatch |
| `Agent(model:fable*)` | **C1 model cap** — bare alias the Agent tool's model enum sends |
| `Agent(model:mythos*)` | **C1 model cap** — bare alias |
| `Bash(pkill *)` | **B2 destructive belt** — mass process kill |
| `Bash(killall *)` | **B2 destructive belt** — mass process kill |
| `Bash(rm -rf ~)` | **B2 destructive belt** — exact home-root wipe (belt against catastrophic single-arg form) |
| `Bash(rm -rf ~/)` | **B2 destructive belt** — exact home-root wipe with trailing slash |
| `Bash(rm -rf ~/.claude*)` | **B2 destructive belt** — CAST runtime wipe (full .claude subtree) |
| `Edit(~/.claude/agent-status/**)` | **S3d gate integrity** — no forged `requires_agent` completion records via Write/Edit/NotebookEdit |
| `Edit(~/.claude/config/**)` | **S3d gate integrity** — installed `policies.json` / `egress-policy.json` cannot be emptied or rewritten |
| `Edit(~/.claude/projects/**/subagents/**)` | **S3d gate integrity** — subagent sidecars/transcripts (the gate's roster-type and handback-verdict sources) |
| `Edit(~/.claude/settings.json)` / `Edit(~/.claude/settings.local.json)` | **S3d self-protection** — the denies themselves cannot be removed by an agent tool (Claude Code's own `/config`, `/model` writes are in-process and unaffected) |
| `Edit(~/.claude/managed-settings.d/**)` | **S3d self-protection** — live settings fragments; change them in the repo and reinstall |
| `Edit(~/.claude/scripts/**)` | **S3d self-protection** — every CAST hook executes from here; edit the repo copy and reinstall |
| `Edit(~/.claude/logs/**)` | **S3d F2** — `audit.jsonl` and hook logs cannot be rewritten by an agent tool |
| `Edit(**/.claude/settings*.json)` / `Edit(//**/.claude/settings*.json)` | **S3d F1** — a project's `env` and `disableAllHooks` hot-reload mid-session and reach (or switch off) every user-level CAST hook; the `//` form also covers a subdirectory or worktree cwd |

> **Why NOT `rm -rf ~*`:** the `~*` prefix glob matched `rm -rf ~/Projects/foo/node_modules`
> and other legitimate deep-path deletes (the command-guard intentionally allows those).
> The home-root narrowing (FIX A, v9 security review) replaces the over-broad glob with two
> exact-match entries covering only the catastrophic bare home cases.

### Known bypass gaps (covered by command-guard, not native deny)

Native `permissions.deny` is a **coarse belt** for exact catastrophic strings. The following
variants bypass native deny entirely — they are caught by `cast-command-guard` (path-aware
script gate) and `cast_safe_rm` (guarded delete helper), NOT by this deny layer:

- `rm -rf "$HOME"` / `rm -rf $HOME` — env-var expansion, not the literal `~`
- `/bin/rm -rf ~` / `/usr/bin/rm -rf ~` — full path bypasses prefix matching
- `rm -fr ~` / `rm -rf --no-preserve-root ~` — flag-order variants
- `rm --recursive --force ~` — long-form flags
- `cd ~ && rm -rf .` — two-command form; only the `rm` part would be matched
- `/usr/bin/pkill foo` — full-path pkill bypass
- Python `shutil.rmtree(os.path.expanduser('~'))` — language-level delete, no Bash rule fires

Also: **native deny matches the literal model value Claude sends**. Agents whose frontmatter
sets a named model (`model: claude-fable`) are matched. Agents that omit the `model`
parameter and rely on a default or ambient routing are NOT matched by `Agent(model:)` rules —
a known limitation documented in the permissions spec.

**The right mental model:** native deny fires before the model generates the command (zero
runtime cost, session-scoped, impossible to bypass in an interactive session). The script
gates are the nuanced, non-session, path-aware layer. Both are needed.

### Belt-and-suspenders relationship

This is a **belt over the existing suspenders** — it does NOT replace:

- `cast-command-guard` (script-gate, path-aware, handles env-var escape hatches)
- `cast-blast-radius-lint` (static analysis, pre-commit)
- `cast_safe_rm` (guarded delete helper)

Native `permissions.deny` is **session-scoped**: fires inside interactive `claude` sessions
and headless `claude -p` calls. The script gates run in cron/CI only where a job explicitly
invokes them, and cover any non-session context where `permissions.deny` does not apply.

**Why belt + suspenders and not just one?**
- Native deny is coarse (prefix-glob, no env-var exceptions, no path semantics) but fires
  at the permission check when the tool call is made, before the tool runs — zero runtime cost,
  impossible to bypass in a session.
- Script gates are nuanced (path-aware, escape-hatch-aware) but are hook-advisory-grade in
  interactive sessions and run in cron/CI only where a job explicitly invokes them.

### Source-of-truth

`managed-settings.d/11-deny.json` is the fragment source. `settings.json` in the repo root
carries the merged result (kept in sync manually — `cast-merge-settings.sh` reads the live
`~/.claude/managed-settings.d`, not the repo fragments). No drift gate covers the full set;
`tests/cast-sandbox-u6-config.bats` checks a subset of the Edit denies only. Both sets had
26 entries on 2026-10-09.
The `11-deny.json` fragment is CAST-owned in `install.sh` (pattern `11-deny.json` in the overwrite case), so reinstall
propagates security updates to existing deployments.

## The `requires_agent` unblock gate: session-bound, roster-typed records (S3d, 2026-10-05)

`config/policies.json` block policies (`.githooks/`, `.git/`, `.env`, `src/auth/`, global gitconfig → `security`;
`.github/workflows/` → `devops`) clear only after the required agent has run. Until PR #416 the gate accepted ANY
`~/.claude/agent-status/<agent>-*` file with a DONE status from ANY session. Live-probed: a read-only `Explore`
dispatched with `name: "security"` minted a security pass, and another terminal's record unblocked this one.

**Now:**
- The SubagentStop hook writes `session_id` + `agent_type`. The type comes from Claude Code's `agent-<id>.meta.json`
  sidecar. A non-empty `customAgentType` is trusted. A teammate (`taskKind: in_process_teammate`, or `teamName`
  set) without one is untrusted, because its `agentType` is the dispatch name; this covers e.g. an Explore named
  `security`. Otherwise `agentType` is used, unless it equals `name`.
- `cast-git-guard.py` clears a policy only on a record whose content matches the PreToolUse `session_id` and the
  required agent exactly. The newest matching record wins, and a same-session BLOCKED supersedes an earlier DONE.
- The verdict is parsed asymmetrically: blocking verdicts are read anywhere, passing ones only from an anchored,
  unfenced `Status:` line or a `json status` fence. Async agents that end with `SubagentHandback` produce no
  `last_assistant_message`, so their verdict is read from that call in the agent's own transcript.
- The native `Edit` denies above keep agent tools out of every gate input.

**Live-verified 2026-10-05** (post-install, this repo):

| Probe | Result |
|---|---|
| Gated `.githooks/` Write with no review | BLOCKED |
| After an Explore named `security-2` | BLOCKED |
| After a real `security` review ending `Status: SAFE` (not a contract verdict) | BLOCKED |
| After a real unnamed `security` review | ALLOWED |
| Write/Edit/Bash-redirect into `agent-status`, `config`, `scripts`, sidecars, incl. `~/.Claude/`, `/./`, `/../` | DENIED |

**What it attests:** a `<required_agent>`-typed subagent finished with a passing verdict in THIS session. It does
not attest that the review covered this particular edit. DONE_WITH_CONCERNS still unblocks; the concerns go to
the orchestrator.

**Residuals:**
- With the sandbox OFF, Bash or subprocess writes can still forge a record or a sidecar.
- A project-level `.claude/agents/security.md` shadows the roster agent; identity is a name.
- Project `.claude/settings*.json` writes (S3d follow-up F1): see the next section.
- ~~A slow SubagentStop telemetry stage can hit the 15 s hook timeout before the record is written (S3d-5).~~
  Fixed: a `--gate-only` pass writes the record before any telemetry stage, and the claimed-work verifier is linear
  on agent output (was 50–100 s on 600 KB).

## Commit identity at pre-push (D5a/D5b, 2026-10-08)

Reuses the S3d resolver from the `requires_agent` gate above to answer "who made this hatch commit".
Commits `aacaf1d` (D5a, record) and `85c5d21` (D5b, judge).

**Mechanism.**
- D5a: the dispatcher hands the PreToolUse payload to the git guard (`set_hook_context`);
  `COMMIT_HATCH_USED` lines gain `agent_type`, `agent_id`, `tool_use_id`, `session_id`, `head_before`,
  `main_repo` (`PUSH_HATCH_USED` gets the identity fields). Git facts are memoized per call; hatch lines
  cap at 8 per call (`_MAX_HATCH_RECORDS_PER_COMMAND`) to stay inside the 2 s watchdog (60 segments:
  8.4 s to ~1 s).
- PostToolUse (`part5_commit_provenance`) finds `head_before` by `tool_use_id` in the last 256 KiB of
  `audit.jsonl`, records `head_before..HEAD` (committer time >= hatch event - 5 s, <= 50; else HEAD-only
  with age checks), labels with payload `agent_type` or `'main-session'`, UPSERTs over `'unattributed'`
  rows only (`recorded_at`, `repo` kept).
- D5b (`cast-commit-reconcile.py`): identity events are authorized iff `agent_id` is non-empty and
  `_resolve_roster_type` (sidecar `~/.claude/projects/*/<session_id>/subagents/[workflows/<id>/]agent-<agent_id>.meta.json`)
  returns `commit`. Rows are not consulted for identity events. Legacy events (no `agent_type`) keep the
  [ts-60s, ts+15min] provenance-row window.

**Trust source and fail directions.**

| Condition | Result |
|---|---|
| sidecar type == `commit` | authorized |
| `agent_id` empty | violation: `main-session hatch` |
| resolved type != `commit` | violation: `agent X is not the commit agent` |
| no / ambiguous / spoofed / teammate-shaped sidecar | violation: `commit-agent identity unverifiable (no trusted sidecar)` |
| corrupt line containing `COMMIT_HATCH_USED` (non-UTF-8 / non-JSON / non-object) | violation (Ed, 2026-10-04) |
| last line without trailing newline | `unverifiable`, exit 0 |

`CAST_RECONCILE_ACK=1` acks all kinds; acked corrupt lines' sha256 go into `RECONCILE_ACK_USED.corrupt_line_sha256`.

**Live verification.** A commit-agent subagent payload carries `agent_type:"commit"` + `agent_id`; the main
session's carries neither. On copies of the live audit log and cast.db the old reconcile blocked (rc=1) on a
commit-agent probe event, the new one was clean; the live push of `85c5d21` printed `"status": "clean", "checked": 3`.
Gates: D5a code-reviewer x3 APPROVED, security R1 FIX REQUIRED (memoization, label overwrite) then R2 CLEAN;
D5b code-reviewer APPROVED, security CLEAN.

**Operational naming.** Dispatch the commit agent unnamed or as `commit__<label>`. A dispatch named exactly
`commit` is unattributable (sidecar name equals the type, the ambiguous shape) and blocks the push.

## Project settings files: `env` and `disableAllHooks` (S3d F1, 2026-10-05)

Claude Code reloads a project's `.claude/settings.json` and `.claude/settings.local.json` mid-session. Their `env`
block "reaches every subprocess Claude Code starts", hooks included. Their `disableAllHooks: true` disables user
hooks, and every CAST guard is a user hook. Project `env` is not filtered for `PATH`, `BASH_ENV`, `BASH_FUNC_*`,
`LD_*`, `DYLD_*`, `PYTHON*` or `GIT_*`. A write to that file could therefore switch off every guard or run code inside
every hook. Before this, only the auto-mode classifier stood in the way, and `bypassPermissions` allows the write.

| Layer | Covers | Doesn't cover |
|---|---|---|
| Native deny `Edit(**/.claude/settings*.json)` + `Edit(//**/…)` | Write/Edit/NotebookEdit and Bash's recognized writers, in every mode | `ln -s`, `cp`, `mv`, `dd`, interpreters while the sandbox is off |
| `ConfigChange` guard (`cast-config-change-guard.sh`, matcher `project_settings\|local_settings`) | Any writer, mid-session: blocks a change that sets `disableAllHooks` or an exec/guard/egress-relevant `env` name (denylist + `CAST_`/`CLAUDE_`/`ANTHROPIC_`/`NODE_`/`AWS_`/`GOOGLE_`/`LD_`/`DYLD_`/`PYTHON`/`GIT_`/`BASH_FUNC_` prefixes, any non-identifier key; a benign `NODE_ENV` also blocks mid-session, by design). Fails closed on anything it can't evaluate, with a 2.5 s self-deadline inside the 5 s hook timeout. | A blocked file stays on disk and applies at the next startup (no startup event). The content is judged at hook-read time (TOCTOU), and only an OS deny-write closes that. Other keys (`hooks`, `statusLine`, helpers, `permissions`, `sandbox`) aren't judged. |

The denylist is defence in depth, not an inventory. A block shows no message to the user or to Claude. Claude
Code writes only a debug-log line, and the guard appends a names-only line to `~/.claude/logs/config-change-guard.jsonl`.

## Sandbox write-denies for git-executed paths (2026-10-04, U6b/U6c)

`61-sandbox.json` adds `sandbox.filesystem.denyWrite: ["~/Projects/**/.git/worktrees", "~/Projects/**/.githooks"]`; `12-ask.json` adds the `ask` rule `Edit(**/.githooks/**)`. There is no `Write(...)` twin, because Claude Code consults only `Edit(path)` rules for the file tools and a `Write(path)` rule is inert. That ask rule prompted in manual mode but not in auto mode (probe 9). The mode-independent layer is the `githooks-require-security` block policy in `config/policies.json`, enforced by git-guard on Write/Edit. It needs a `security` completion in the session, or `CAST_POLICY_OVERRIDE=1`, and goes live only from the installed copy, after `install.sh`. It is a guardrail for compliant agents, not a boundary: agent-status completion records can be forged through the Write tool and aren't tied to a session (plan S3d). A sibling `git-internals-require-security` policy covers `.git/` (config, hooks, info). Never use `./` here: fragments merge into the USER `~/.claude/settings.json`, where `./` means `~/.claude`. A denyWrite glob compiles to a case-sensitive Seatbelt regex, e.g. `^/(.*/)?\.git/worktrees(/.*)?$` (dir + descendants).
- **Why:** an agent could plant `.git/worktrees/zz -> <victim>`; the next UNSANDBOXED git (your terminal, auto-gc) runs `worktree prune` and empties the victim. `.githooks/` (this repo's `core.hooksPath`) was sandbox-writable, so your unsandboxed `git commit`/`push` ran agent-written hooks. Since #421 (2026-10-07) `core.hooksPath` is the absolute installed `~/.claude/githooks` (Edit-denied, RULE 5, integrity alarm); the repo `.githooks/` is only the deploy source.
- **Scope:** repos under `~/Projects` only; repos elsewhere are unprotected. Temp dirs are deliberately exempt (a leading `/**/` also matched `/tmp`/`$TMPDIR` and broke sandboxed bats fixtures that `git worktree add` or write `.githooks`).
- **Residual:** hooks now call only the installed `~/.claude/scripts/*` (with `CAST_REPO_ROOT`), so the residual moved to the installed scripts, which RULE 5 and the install manifest cover; repo `scripts/` changes reach hooks only through `bash install.sh`. Best-effort only: no ancestor pinning, so renaming a NESTED repo's `.git` aside, populating it, and renaming back may evade the regex (the cwd repo's `.git` is pinned by built-in rules). Case variants (`.GitHooks`, APFS) are untested. Only `.githooks` is protected; `.husky`, `tools/hooks`, `.pre-commit-config.yaml` are not. A linked worktree's `.git` gitfile could be redirected (`gitdir: /tmp/x`); out of scope.
- **Side effects:** sandboxed `git worktree add`, and sandboxed checkout/merge/pull that rewrite `.githooks` files, fail ("unable to unlink"/permission). `scripts/cast-parallel.sh` (`git worktree add/remove`) and the branch groomer's registry-entry removal must run from your terminal, not sandboxed Bash. `git` was removed from `excludedCommands` on 2026-10-06: `excludedCommands: ["git"]` matches only a bare `git` (docs: `git *`), so it was either dead (agent git is sandboxed anyway) or, if it ever matched, a sandbox escape (git has many exec vectors: hooks, fsmonitor, filters, aliases, pagers); pushes go through `scripts/cast-push.sh` via `!` in your terminal. `docker`, `bq` and `osascript` were removed too in #421; with the sandbox ON, run them with `!` in your terminal.
- **Live-probe results (2026-10-05, sandboxed Bash; control: `touch ~/x` EPERM, `TMPDIR=/tmp/claude-501`):** (1) `ln -s` into an existing `.git/worktrees` EPERM ✅; (2) `mkdir -p .git/worktrees/x` with no `.git/worktrees` EPERM ✅, so a deny on a not-yet-existing path DOES block creating it; (3) `mv`/`rmdir`/`touch` on a live `.git/worktrees/<id>` EPERM ✅; (4) `touch .githooks/x` and `mv .githooks …` EPERM ✅; (5) `.GitHooks/x`, `.Git/Worktrees/x` and `.git/WORKTREES/x` EPERM ✅ (APFS case variants are covered); (6) `mv .git .gitx` EPERM ✅; (7) `tests/cast-branch-groomer.bats` 53/53 sandboxed ✅ (fixtures live in `$TMPDIR`); (8) native `isolation: worktree` creation OK, but `git add` inside it FAILS (`.git/worktrees/<id>/index.lock` EPERM; the denyWrite beats the harness's temporary `.git` allowOnly), so worktree-isolated agents cannot stage or commit; (9) ❌ Write AND Edit on `.githooks/zz-cast-probe` landed in auto mode with NO prompt. The docs say explicit ask rules always prompt, and that `Write(path)` rules are inert (only `Edit(path)` is consulted). The cause of the `Edit(**/.githooks/**)` miss is unresolved; one suspect is the bare `Edit`/`Write` allow in `10-permissions.json`. (10) live `~/.claude/settings.json` carries both denyWrite entries and both ask rules ✅.
- **Precondition:** a project `.claude/settings.local.json` with `"sandbox": {"enabled": false}` silently turns all of this off for that repo (found 2026-10-05; the first probe run was invalid). Probe a positive control (`touch ~/x` must fail) before trusting any sandbox probe.

## Closed as documented residuals (v10.3.0 close-out, 2026-10-08)

These were judged and accepted, not fixed; each is a known limit, not an open item.

- S3c-1 pre-commit secret scan: there is no local pre-commit secret scan; CI gitleaks and the PII gate cover it.
- S3c-11 policy engine: NotebookEdit and the audit path hash are not judged by the policy engine.
- S3d-7 fenced verdicts: a verdict inside a code fence is not parsed; this fails closed (no unblock).
- Path aliases: symlinked `..` and hardlink aliases of a protected path are not resolved by the string guards.
- Health-alarm Lows: minor health-alarm wording/coverage gaps, accepted.
- Degraded-scan residuals: when a scan degrades it reports degraded, not clean.
- install.sh CLT-absent branch: the Command Line Tools-absent path is untested.
- S3c-10 egress header comment: cosmetic.
- U4d branch-delete TOCTOU: a window exists between the check and the delete; accepted.
- Validator backgrounded-child litter: a backgrounded child of the validator may leave temp litter.
- Dispatcher locked-DB path: under a locked cast.db the dispatcher can take ~16 s, and a planted `hook_failures` row is not distinguished.
- Egress R1/R4/R8, the `%40` tail and raw ledger fields: accepted egress-sentinel limits.
- `git grep -O`: an open-in-pager exec vector, pinned by a test as a known allow (#421).
- RULE 5 residuals: runtime-built paths, script files, stdin data, earlier-call `cd`/aliases, `pip install --user` (see `scripts/cast-command-guard.py` docstring and the `CAST_PROTECTED_WRITE_OK` row in docs/escape-hatches.md).
- U6d residuals: the integrity checker attests itself (in-process; tampering with it already defeats the check); Homebrew's group-writable `/opt/homebrew/bin` is trusted; install's cache purge falls back to PATH `python3` only when no system python exists.
- D5: a hatch commit after `cd <other repo>` is attributed to the hook cwd's repo.
- D5: a concurrent actor's commit landing during our tool call can get our label (label only; window = tool-call duration).
- D5: a future-dated commit fast-forward-merged later gets the caller's own label.
- D5: a corrupt hatch line is not repo-scoped (ackable).
- D5: the reconcile reads `audit.jsonl` whole (~2.5x RAM; fine at the live 1.1 MB).
- D5: the sidecar and `audit.jsonl` are agent-writable with the sandbox off (same cooperative boundary as the other records).
- D5: the reconcile still returns `skip` for identity events when cast.db / `commit_provenance` is absent (tracked in S4).
