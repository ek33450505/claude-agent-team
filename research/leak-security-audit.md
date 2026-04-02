# CAST Hook Security Audit — Post-Leak Analysis
**Date:** 2026-04-02
**Agent:** security
**Scope:** All hook scripts in scripts/ audited against the Claude Code internal architecture revealed by the 2026-03-31 npm source map incident.

---

## Summary

CAST's hook architecture is well-aligned with the confirmed Claude Code internals. No critical vulnerabilities found. Five areas require attention: one medium risk (unconfirmed env vars), two low risks (permission model gaps, anti-distillation decoy handling), and two informational findings (fragile output parsing, sandbox boundary awareness).

| Finding | Severity | Script | Status |
|---|---|---|---|
| Unconfirmed env vars: CLAUDE_INPUT_TOKENS, CLAUDE_OUTPUT_TOKENS, CLAUDE_MODEL | Medium | cast-cost-tracker.sh | Safe (graceful fallback to 0) |
| Permission model: no Tier 1 passthrough | Low | cast-permission-hook.sh | Advisory |
| Anti-distillation decoy tool risk | Low | cast-permission-hook.sh | Advisory |
| Output format parsing in post-tool-hook.sh | Info | post-tool-hook.sh | No change needed |
| Sandbox denyRead includes cast.db | Info | cast-db-log.py, cast_db.py | Confirmed by leak |

---

## 1. Fragile Internal Assumptions

### Finding 1.1 — JSON envelope is schema-stable (PASS)
**Scripts audited:** cast-audit-hook.sh, cast-security-guard.sh, cast-permission-hook.sh, pre-tool-guard.sh, cast-headless-guard.sh, post-tool-hook.sh

All hook scripts parse the hook payload via `json.load(sys.stdin)` or Python's `json.loads()` and access fields via `.get()` with safe defaults. None use string parsing, regex on raw stdin, or assume positional field order.

The leak confirms the hook payload envelope is:
```json
{
  "tool_name": "...",
  "tool_input": { ... },
  "session_id": "..."
}
```

CAST hooks already use exactly this structure. **No fragile assumptions found.**

### Finding 1.2 — Output format parsing in post-tool-hook.sh (INFO)
`post-tool-hook.sh` Part 3 scans agent output for `[CAST-CHAIN]` and `[CAST-REVIEW]` directives using bash string matching. The leak confirms agent output is returned as raw text in the SubagentStop payload — no schema wrap. This parsing pattern is stable, but if Claude Code ever wraps agent output in a JSON envelope at the SubagentStop level, CAST's chain detection would break silently (the directive would simply not be detected, not cause a crash). Risk is low — set+e ensures no hard failure. **Monitor but no change required.**

---

## 2. Permission Model Alignment

### Finding 2.1 — Missing Tier 1 passthrough (LOW)
The leaked permission system has four tiers. Claude Code's implementation shows:

- **Tier 1 (always-allowed):** Read-only tools (Glob, Grep, Read, LS) — the PermissionRequest hook is **never called** for these tools; they execute without any hook firing.
- **Allow:** Tools like Bash/Write/Edit that are in the explicit allow list — PermissionRequest fires but is auto-approved.
- **Ask:** Falls through to the hook for human or programmatic decision.
- **Deny:** Hard-blocked, hook returns deny immediately.

CAST's `permission-rules.json`:
```json
{
  "auto_approve": ["git status", "git log", "git diff", "git branch", "git show", "ls", "cat ", ...],
  "auto_deny": ["curl", "wget", "nc ", "ncat", "rm -rf", ...],
  "default": "allow"
}
```

**Gap:** CAST's auto_approve list contains commands (like `ls`, `cat`, `git status`) that the leak confirms will never reach the PermissionRequest hook at all — they're Tier 1. This means CAST's auto_approve list for these items is dead code. It wastes hook evaluation time on items that are already pre-approved by Claude Code internally.

**Recommendation:** Add a comment to `permission-rules.json` noting that Tier 1 tools (Read, Glob, Grep, Bash read-only) never reach this hook. The auto_approve list is defensive but harmless.

### Finding 2.2 — default: allow is correct (PASS)
The leaked source confirms Claude Code's default permission behavior for tools in the `Allow` tier is to proceed without asking. CAST's `"default": "allow"` matches this. **Correct.**

---

## 3. Anti-Distillation Risk

### Finding 3.1 — ANTI_DISTILLATION_CC decoy tool risk (LOW)
The leak reveals `ANTI_DISTILLATION_CC` injects synthetic tool definitions into model context to prevent model extraction/distillation. These decoy tools have names that may resemble real tools but route to no-op implementations.

**Risk scenario:** If a decoy tool name matches an `auto_deny` pattern in CAST's `permission-rules.json`, the hook would emit `{"decision": "deny"}` for a tool call that Claude Code intended to allow (or that is itself a no-op decoy). This could block the anti-distillation mechanism.

**Current auto_deny patterns that could conflict:**
- `"curl"` — could match a decoy tool named `curl_helper` or similar
- `"rm -rf"` — unlikely to be a decoy tool name
- `"nc "` — unlikely

**Assessment:** The risk is theoretical. The auto_deny list applies only to Bash command content, not to tool names — `cast-permission-hook.sh` inspects `tool_input.command` for Bash calls, not the tool_name itself. Decoy tools would appear as new tool_name values, not as Bash commands. The permission hook would fall through to `default: allow` for unknown tool names.

**Recommendation:** Add a comment in `cast-permission-hook.sh` documenting that unknown tool names (including potential ANTI_DISTILLATION_CC decoys) fall through to `default: allow` and are logged, not blocked. This is the correct behavior.

---

## 4. Environment Variable Surface

### Finding 4.1 — Confirmed env vars (PASS)
The leak confirms the following env vars are intentional and stable in Claude Code's hook runner:

| Env Var | Confirmed by Leak | CAST Usage |
|---|---|---|
| `CLAUDE_SESSION_ID` | Yes | cast-audit-hook.sh, cast-session-end.sh, cast-cost-tracker.sh, post-tool-hook.sh, agent-status-reader.sh |
| `CLAUDE_SUBPROCESS` | Yes | 14+ scripts use this guard |
| `CLAUDE_ENV_FILE` | Yes | cast-session-start-hook.sh |
| `CLAUDE_PROJECT_PATH` | Yes | cast-audit-hook.sh |

All of these are used defensively with `${VAR:-default}` fallbacks. **No fragile usage found.**

### Finding 4.2 — Unconfirmed env vars: CLAUDE_INPUT_TOKENS, CLAUDE_OUTPUT_TOKENS, CLAUDE_MODEL (MEDIUM)
`cast-cost-tracker.sh` uses three env vars not explicitly confirmed in the leak:

```bash
CLAUDE_INPUT_TOKENS_VAL="${CLAUDE_INPUT_TOKENS:-}" \
CLAUDE_OUTPUT_TOKENS_VAL="${CLAUDE_OUTPUT_TOKENS:-}" \
CLAUDE_MODEL_VAL="${CLAUDE_MODEL:-}" \
```

**Risk:** These vars may be internal to Claude Code's PostToolUse hook context but not formally part of the public hook API. If Anthropic renames or removes them, cost tracking silently falls back to 0 tokens.

**Mitigation in place:** The code uses `int(os.environ.get('CLAUDE_INPUT_TOKENS_VAL', '0') or '0')` — graceful fallback to 0. No crash occurs. Cost tracking simply shows 0 when vars are absent.

**Recommendation:** Add a comment to `cast-cost-tracker.sh` noting these vars are undocumented but available in practice. Monitor if cost tracking starts showing all-zeros — that would indicate the vars changed. No code change required; the fallback is correct.

---

## 5. Sandbox Boundaries

### Finding 5.1 — cast.db is in sandbox denyRead (CONFIRMED)
`managed-settings.d/60-meta.json` has:
```json
"denyRead": ["~/.claude/cast.db", ...]
```

The leak confirms Claude Code's sandbox `denyRead` paths prevent the model from reading those files directly — but **hook scripts bypass the sandbox** because they run as separate processes, not as Claude Code tool calls.

**Implication:** `cast-db-log.py`, `cast_db.py`, `cast-cost-tracker.sh`, `cast-session-end.sh`, and all other scripts that write to `cast.db` work correctly because they execute outside the sandbox boundary. The denyRead setting only applies to Claude Code's own tool calls (e.g., a Read tool call targeting `~/.claude/cast.db` would be blocked). Hook scripts are shell processes — they are not sandboxed by Claude Code's tool sandbox.

**Status:** This is working as designed. The sandwich of "Claude Code can't read cast.db, but hooks can write to it" is intentional for security. **No change needed.**

### Finding 5.2 — sandbox.excludedCommands includes git (CONFIRMED)
`60-meta.json` excludes `git` from the sandbox. The leak confirms `excludedCommands` runs those commands outside sandbox restrictions. This is why `pre-tool-guard.sh` needs to intercept git calls before they execute — by the time they reach the Bash tool, git is unsandboxed. **Working correctly.**

---

## Conclusion

CAST's hook surface is robust against the architecture the leak confirms. The highest-risk finding is the unconfirmed env vars in `cast-cost-tracker.sh` — but graceful fallbacks make this a monitoring concern, not a breakage risk. Permission model has minor dead-code in auto_approve for Tier 1 tools, and anti-distillation decoy tools are handled correctly by the default-allow fallthrough.

**No code changes required.** Recommendations are documentation/comment additions only.

---

*Generated by security agent (Batch 2, parallel — Wave 2)*
*Audit scope: 71 scripts in scripts/, managed-settings.d/*.json, research context from leak-architecture-comparison.md*
