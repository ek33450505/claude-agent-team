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
| `write-guards` — literal-tilde write block | enforcement-intent | ❌ path-pattern correction | **KEEP as hook** |
| `write-guards` — stat-claim badge gate | awareness/quality | ❌ | **KEEP as hook** (advisory) |
| `write-guards` — no-fake-success | awareness | ❌ | **KEEP as hook** (already advisory) |
| `cast-egress-sentinel` — off-machine-bound recording | **awareness** | partial (coarse access is native; the *record* + content-sensitivity is net-new) | **KEEP as hook** — the record is the product (§1) |
| `cast-audit-hook` — web/PII audit record | **awareness** | partial | **KEEP as hook** (audit record) |
| `cast-headless-guard` — AskUserQuestion auto-answer | awareness | ❌ | **KEEP as hook** |
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
and headless `claude -p` calls. The script gates cover cron jobs, CI, and any non-session
context where `permissions.deny` does not apply.

**Why belt + suspenders and not just one?**
- Native deny is coarse (prefix-glob, no env-var exceptions, no path semantics) but fires
  before the model even generates the command — zero runtime cost, impossible to bypass in a
  session.
- Script gates are nuanced (path-aware, escape-hatch-aware) but are hook-advisory-grade in
  interactive sessions and absent in cron/CI without explicit wiring.

### Source-of-truth

`managed-settings.d/11-deny.json` is the fragment source. `settings.json` in the repo root
carries the merged result (kept in sync manually — `cast-merge-settings.sh` reads the live
`~/.claude/managed-settings.d`, not the repo fragments). The `11-deny.json` fragment is
CAST-owned in `install.sh` (pattern `11-deny.json` in the overwrite case), so reinstall
propagates security updates to existing deployments.
