# Bug Report: CLI hard-crashes on non-spec `hookSpecificOutput`

**Filed:** 2026-05-08
**Repo to file in:** `anthropics/claude-code`
**Affected versions:** 2.1.119 (and likely earlier — bug class is the `in`-on-non-object pattern)
**Severity:** High — crashes the user's session mid-flow, no graceful degradation
**Status:** Draft — review before filing

---

## Title

CLI throws `q.hookSpecificOutput is not an Object` and crashes the session when a hook emits malformed `hookSpecificOutput`

## Summary

When a user hook script emits valid JSON whose `hookSpecificOutput` value is anything other than an object (string, number, array, null, etc.), the Claude Code CLI evaluates `"additionalContext" in q.hookSpecificOutput` in the `async_hook_response` handler. The `in` operator throws `TypeError: q.hookSpecificOutput is not an Object` and the session crashes immediately with no recovery — the user loses in-flight work and conversation context.

This is a robustness issue. A malformed hook script (which is user-authored and outside the CLI's control) should not be able to hard-crash the session.

## Reproduction

Create a hook script that emits a stringified blob in the `hookSpecificOutput` field:

```bash
#!/bin/bash
# fixture-bad-hook.sh
cat <<'EOF'
{"hookSpecificOutput": "{\"status\": \"DONE\"}"}
EOF
```

Wire it as a `SubagentStop` hook in `~/.claude/settings.json`:

```json
{
  "hooks": {
    "SubagentStop": [
      { "hooks": [ { "type": "command", "command": "bash ~/fixture-bad-hook.sh" } ] }
    ]
  }
}
```

Dispatch any subagent (e.g. via `/agents` or any agent invocation). The session crashes:

```
Claude Code returned an error result: q.hookSpecificOutput is not an Object.
(evaluating '"additionalContext" in q.hookSpecificOutput')
```

## Expected behavior

Either:
1. **Soft-fail:** log a warning ("hook output malformed: hookSpecificOutput must be an object, got string") and discard that hook's output, continuing the session uninterrupted.
2. **Hard-fail with context:** throw a structured error that names the offending hook script path and the actual vs expected shape — but do not crash the entire session, only the hook integration.

## Actual behavior

Session terminates with an unhandled `TypeError`. No information about which hook misbehaved. No way to recover the conversation. No retry.

## Why this matters

Real-world impact (the case that triggered this report):

- A multi-agent CAST framework user introduced a hook in commit `be8d924` that emitted `'hookSpecificOutput': json.dumps({...})` — a one-character mistake (`json.dumps` should not have wrapped the whole object).
- The hook ran on every subagent completion. The CLI crashed on every single one. The user lost approximately a full work day to recovery sessions, opening multiple sessions trying to diagnose what was breaking.
- Static analysis (TypeScript types, Python type hints) cannot catch this — the value is `Any`/`unknown` at the JSON boundary.
- Local testing didn't catch it because the hook fired on subagent completion, which doesn't happen in unit tests.
- The CLI gave no hint about which hook was malformed; isolation took hours.

## Suggested fix

In the `async_hook_response` handler (and any other site that uses `in`-checks against `hookSpecificOutput`):

```js
// Before (throws on string, number, null, array)
if ("additionalContext" in q.hookSpecificOutput) { ... }

// After (handles any value)
if (q.hookSpecificOutput && typeof q.hookSpecificOutput === "object" && !Array.isArray(q.hookSpecificOutput)) {
  if ("additionalContext" in q.hookSpecificOutput) { ... }
} else {
  console.warn(`Hook output malformed: hookSpecificOutput must be an object, got ${typeof q.hookSpecificOutput}. Hook: <path>. Discarding.`);
}
```

Or use a runtime schema validator (zod, ajv) at the JSON boundary that catches the shape mismatch with a useful error message and degrades gracefully.

## Workaround (for users hitting this today)

1. Open a fresh session that doesn't dispatch subagents (so the broken `SubagentStop` hook never fires).
2. Audit your hooks: `grep -rn "hookSpecificOutput" ~/.claude/scripts/` — look for any code that emits `hookSpecificOutput` as a stringified blob (e.g. `'hookSpecificOutput': json.dumps(...)` in Python, or any hook that wraps the field as a string).
3. Replace with the spec shape:
   ```json
   {"hookSpecificOutput": {"hookEventName": "<EventName>", "additionalContext": "<string>"}}
   ```
4. Restart Claude Code.

## Related observations

- Even with the fix, **the CLI does not surface which hook produced bad output**. Adding the hook script path to any future warning/error would dramatically reduce diagnosis time. Consider logging hook output validation failures to `~/.claude/logs/` with the hook path + raw output (redacted for PII).
- The hooks JSON schema is implicit — there's no published JSON Schema that hook authors can validate against. Publishing a schema (or providing a `claude-code validate-hook` CLI subcommand) would let hook authors catch this class of bug at write-time.

---

## Filing checklist

- [ ] Verify reproduction on latest Claude Code (currently 2.1.119)
- [ ] Capture the actual error stack trace from a real session
- [ ] Reference this report in the GitHub issue
- [ ] Cross-link to CAST PR #29 as a real-world case study
