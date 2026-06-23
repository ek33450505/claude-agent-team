# Enforcement vs. Awareness — the guard classification (CAST v9 P0)

> **Principle (`master_v9.md` §0.3):** *Enforcement* = native `permissions.deny` + the OS
> sandbox (the real, non-bypassable boundary). *Awareness* = hooks (advisory, fail-open,
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
| Credential reads | **enforcement** | ✅ `sandbox.filesystem.denyRead` | **ALREADY NATIVE** (egress hook adds the record) |
| Network egress | **enforcement** | ✅ `sandbox.network.allowedDomains` | **ALREADY NATIVE** (egress hook adds the record) |
| Subagent model cap | **enforcement** | ✅ `Agent(model:)` deny | **ALREADY NATIVE** (shipped `73d0db1`) |

## The honesty correction (§0.3)

Because the bespoke hooks block via `exit 2`, their comments historically read as hard,
non-bypassable boundaries (e.g. *"Exit 2 = hard block (Claude cannot bypass)"*). That
over-claims: a PreToolUse hook is **advisory-grade** — it is the model-facing block in an
interactive session, but the **non-bypassable** boundary for the catastrophic classes
(credential reads, network egress, filesystem) is the **OS sandbox**, which the docs confirm
is enforced for all subprocesses. The guards' comments are relabeled to say so. The hooks
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
