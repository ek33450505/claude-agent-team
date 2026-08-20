# Research: Claude Code Hook Event Surface (Re-sourcing)
**Date:** 2026-08-20
**Question:** Re-source the hook event surface from code.claude.com/docs — verify against live doc pages, no reliance on memory/training data or prior CAST notes.

**Status:** COMPLETE

## 1. Complete Hook Event List

Source: https://code.claude.com/docs/en/hooks (fetched directly; no redirect observed — host and path match the requested authoritative source)

**31 events found, not "~29."** Cross-checked via a WebSearch pass ([claudefa.st "All 30 Lifecycle Events"](https://claudefa.st/blog/tools/hooks/hooks-guide) and [cc.bruniaux.com "All 30 Events"] both third-party and unverified, but a search snippet attributed to the same underlying page states "the reference documents 31 hook events, though other sources mention around 30 events" — consistent with a recently-added event pushing the count from 30 to 31). **Discrepancy confirmed: prior CAST note said ~29; live doc page shows 31.**

| Event | When it fires | Can block? | Mechanism | Key payload fields (beyond common fields) |
|---|---|---|---|---|
| SessionStart | Session begins/resumes | No | — | `model` (not guaranteed) |
| Setup | `--init-only`/`--init`/`--maintenance` startup | No | — | — |
| UserPromptSubmit | Prompt submitted, before Claude processes it | Yes | exit code 2 (erases the prompt) | — |
| UserPromptExpansion | A typed command expands into a prompt | Yes | exit code 2 | — |
| PreToolUse | Before a tool call executes | Yes | exit code 2, or `hookSpecificOutput.permissionDecision: "deny"` | `tool_name`, `tool_input`, `tool_use_id` |
| PermissionRequest | Tool call needs a permission decision | Yes | `hookSpecificOutput.decision` object | `tool_name`, `tool_input`, `tool_use_id` |
| PermissionDenied | Auto mode denies a tool call | No (denial already happened) | `hookSpecificOutput.retry: true` lets model retry | `tool_name`, `tool_input`, `tool_use_id` |
| PostToolUse | After a tool call succeeds | No | exit code 2 shows stderr to Claude | `tool_name`, `tool_input`, `tool_use_id` |
| PostToolUseFailure | After a tool call fails | No | exit code 2 shows stderr to Claude | `tool_name`, `tool_input`, `tool_use_id` |
| PostToolBatch | After a parallel tool-call batch resolves | Yes | exit code 2 stops the loop before next model call | — |
| Stop | Claude finishes responding | Yes | exit code 2 (continues conversation) | `last_assistant_message` |
| StopFailure | Turn ends due to API error | No | output/exit ignored except `terminalSequence` | error details |
| SubagentStart | Subagent spawned | No | exit code 2 shows stderr to user only | `agent_id`, `agent_type` |
| SubagentStop | Subagent finishes | Yes | exit code 2 | `agent_id`, `agent_type`, `last_assistant_message` |
| TaskCreated | Task created via TaskCreate | Yes | exit code 2 rolls back creation | — |
| TaskCompleted | Task marked completed | Yes | exit code 2 | — |
| TeammateIdle | Team teammate about to go idle | Yes | exit code 2 | — |
| InstructionsLoaded | CLAUDE.md / `.claude/rules/*.md` loaded | No | exit code ignored | — |
| ConfigChange | Config file changes mid-session | Yes | exit code 2 (except `policy_settings`) | — |
| CwdChanged | Working directory changes | No | — | — |
| DirectoryAdded | Dir added via `/add-dir` or SDK | No | stderr to debug log only | — |
| FileChanged | Watched file changes on disk | No | stderr to user only | file path info |
| WorktreeCreate | Worktree being created | Yes | ANY non-zero exit code fails creation | — |
| WorktreeRemove | Worktree removed | No | failures logged in debug mode only | — |
| PreCompact | Before context compaction | Yes | exit code 2 | — |
| PostCompact | After compaction | No | stderr to user only | — |
| Elicitation | MCP server requests user input | Yes | exit code 2 denies elicitation | — |
| ElicitationResult | After user responds to elicitation | Yes | exit code 2 (response becomes decline) | — |
| SessionEnd | Session terminates | No | stderr to user only | — |
| Notification | Claude Code sends a notification | No | exit code/stderr ignored | — |
| MessageDisplay | Assistant message text displayed | No | exit code ignored | — |

All events also carry a **common field set** per the doc (session_id, transcript_path, cwd, permission_mode, hook_event_name, etc. — see example payload in §4).

## 2. Blocking / Decision Semantics

Source: https://code.claude.com/docs/en/hooks

**Exit-code table (verbatim structure from doc):**
| Exit code | Meaning | Behavior |
|---|---|---|
| 0 | Success | JSON output fields read from stdout for events that support them; for most events stdout goes to debug log only. Exceptions: `UserPromptSubmit`, `UserPromptExpansion`, `SessionStart` add plain-text stdout as visible context. |
| 2 | Blocking error | Blocks the action for events that support blocking (e.g. `PreToolUse` blocks the tool call). Applies whether or not JSON is printed — **exit 2 overrides even a JSON `permissionDecision: "allow"`.** |
| Other (1, 3+) | Non-blocking error (most events) | If JSON passes schema validation it's honored; otherwise (invalid JSON or plain text) it's non-blocking and the action proceeds. Exception: `WorktreeCreate` — any non-zero code fails creation. |

**PreToolUse `hookSpecificOutput` schema (verbatim per doc):**
```json
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "allow" | "deny" | "ask",
    "permissionDecisionReason": "string",
    "updatedInput": { "...tool input object..." },
    "additionalContext": "string"
  }
}
```

**PermissionRequest `hookSpecificOutput.decision` schema:**
```json
{
  "hookSpecificOutput": {
    "hookEventName": "PermissionRequest",
    "decision": "allow" | "deny" | "ask",
    "decisionReason": "string"
  }
}
```

**Universal JSON fields (all hooks):** `continue: boolean`, `stopReason: string`, `systemMessage: string`, `additionalContext: string`, `terminalSequence: string`.

**Precedence rules across multiple hooks** (https://code.claude.com/docs/en/hooks and https://code.claude.com/docs/en/permissions):
- "All matching hooks run in parallel. If you define the same handler in more than one settings file, it runs once. A plugin's or skill's copy of the same handler stays separate."
- "Hook entries merge across settings levels rather than replacing each other: user, project, and local settings add their own hooks without removing managed ones."
- Hook decisions vs. permission rules (https://code.claude.com/docs/en/permissions, "Hooks" section): **"Hook decisions don't bypass permission rules. Claude Code evaluates deny and ask rules regardless of what a PreToolUse hook returns: a matching deny rule blocks the call, and a matching ask rule still prompts even when the hook returned `"allow"` or `"ask"`."** A blocking hook (exit 2) takes precedence over allow rules and stops the call before permission rules are even evaluated.

## 3. Native Capabilities vs. Bespoke CAST Guards

Sources: https://code.claude.com/docs/en/permissions, https://code.claude.com/docs/en/permission-modes

### Irreversibility interrupts (git push/force-push, force-merge, schema migration, DB row deletion, rm -rf, pkill/killall, raw git commit)

**What exists natively:**
- **`permissions.deny` rules with Bash tool-matcher syntax** can block specific command prefixes, e.g. `"Bash(git push *)"`. Verified example from docs search + fetch: `{ "permissions": { "deny": ["Bash(git push *)"] } }`. Wildcard `*` matches any sequence including spaces; a trailing `" *"` enforces a word boundary (`Bash(ls *)` matches `ls -la` but not `lsof`).
- Claude Code is **shell-operator-aware**: a rule like `Bash(safe-cmd *)` does not implicitly permit `safe-cmd && other-cmd`; recognized separators are `&&`, `||`, `;`, `|`, `|&`, `&`, newlines, and **a deny/allow rule must match each subcommand independently** — so a deny on `git push` is not trivially bypassable via a compound command. (https://code.claude.com/docs/en/permissions)
- **Critical-path circuit breaker (`rm`/`rmdir` only):** Claude Code has a *built-in, non-configurable* block on `rm`/`rmdir` targeting a "critical path" — filesystem root, top-level dirs (`/usr`, `/etc`), home dir, working directory and its parents, Windows drive roots, and glob/trailing-slash removals under a shell variable (`rm -rf "$DIR"/*`). This **cannot be approved by any allow rule or a `PreToolUse` hook returning `"allow"`** — "This circuit breaker guards against model error." It survives command substitution/backtick hiding (`echo "$(rm -rf ~)"` is still caught). A matching **deny** rule still blocks it outright. (https://code.claude.com/docs/en/permission-modes)
- **What this native `rm`/`rmdir` circuit breaker does NOT cover:** it is scoped to `rm`/`rmdir` targeting those specific critical-path shapes. It is NOT a general "destructive op" detector — it does not natively recognize `git push --force`, `git commit`, schema migrations, DB row deletions, or `pkill`/`killall` as a class. Those require the operator to hand-write `permissions.deny` rules per command pattern (as CAST already does via its own guard scripts); there is no built-in taxonomy of "irreversible operations" in the docs.
- **Sandboxing** (https://code.claude.com/docs/en/sandboxing, referenced but not independently fetched this session — flagged `[unverified — not fetched]`) is described in the permissions page as OS-level enforcement restricting the Bash tool's filesystem/network access, applying "only to Bash commands and their child processes." Permission deny rules + sandbox restrictions are explicitly framed as complementary layers, not substitutes.

**Bottom line for irreversibility interrupts:** the only native mechanism that maps onto CAST's guard set is `permissions.deny` (a config-authored allowlist/denylist), plus the one hard-coded `rm`/`rmdir` critical-path circuit breaker. There is no native, generalized "irreversible-operation" gate covering push/force-merge/migration/DB-delete/pkill/raw-commit as a category — CAST's bespoke guard for those remains necessary; a `permissions.deny` ruleset could partially replace the *bash-pattern-matchable* subset (git push, pkill, killall, rm -rf) but not the mechanism-level operations (schema migration via app code, DB row deletion via app code) which aren't expressible as a Bash-command pattern at all unless invoked from the shell.

### Config-write guards (protected config paths)

**Native "protected paths" mechanism exists and is closely analogous to CAST's config-write guard** (https://code.claude.com/docs/en/permission-modes, "Protected paths" section):
- Writes to a fixed, **built-in, non-configurable** list of directories/files are never auto-approved except in `bypassPermissions` mode: directories `.git`, `.config/git`, `.vscode`, `.idea`, `.husky`, `.cargo`, `.devcontainer`, `.yarn`, `.mvn`, `.claude` (except `.claude/worktrees`); files `.gitconfig`, `.gitmodules`, shell rc files (`.bashrc`, `.zshrc`, etc.), `.envrc`, `.ripgreprc`, `pyrightconfig.json`, `.mcp.json`, `.claude.json`.
- Verbatim: **"`permissions.allow` rules in settings files do not pre-approve protected-path writes. The safety check runs before Claude Code evaluates allow rules from settings, so an entry such as `Edit(.claude/**)` ... does not change the per-mode outcome."**
- Per-mode behavior: `default`/`acceptEdits` → prompted; `plan` → allowed only with bypass permissions, else classifier/prompt; `auto` → routed to classifier; `dontAsk` → denied; `bypassPermissions` → **allowed** (this mode explicitly disables the protection).

**What it does NOT cover:**
- It is a **fixed list**, not extensible via config to arbitrary "protected config paths" CAST cares about (e.g. `config/policies.json`, `config/egress-policy.json`, `managed-settings.d/`, `install.sh`, `.githooks/`, cast.db schema/migration files) — none of those appear in the built-in list, so CAST's own guard is still required for its own protected-surface set.
- `bypassPermissions` mode explicitly skips this protection entirely — it is not fail-closed under that mode.
- The protected-paths check applies to Claude's built-in file tools and to file operations Claude Code recognizes inside Bash (`cat`, `head`, `tail`, `sed`, output redirection to a file) — **it does NOT apply to arbitrary subprocesses that read/write files indirectly**, e.g. a Python or Node script that opens the file itself. Verbatim: **"Read and Edit deny rules apply to Claude's built-in file tools and to file commands Claude Code recognizes in Bash... They don't apply to arbitrary subprocesses that read or write files indirectly, like a Python or Node script that opens files itself. For OS-level enforcement that blocks all processes from accessing a path, enable the sandbox."** (https://code.claude.com/docs/en/permissions) This is a real gap for a CAST guard script invoked as `python3 foo.py` that then opens a protected path directly.

## 4. Argument and Payload Handling

Source: https://code.claude.com/docs/en/hooks

**Stdin:** "For command hooks, input arrives on stdin." Example `PreToolUse` payload for a Bash tool call:
```json
{
  "session_id": "abc123",
  "prompt_id": "550e8400-e29b-41d4-a716-446655440000",
  "transcript_path": "/home/user/.claude/projects/.../transcript.jsonl",
  "cwd": "/home/user/my-project",
  "permission_mode": "default",
  "hook_event_name": "PreToolUse",
  "tool_name": "Bash",
  "tool_input": { "command": "npm test", "description": "Run test suite", "timeout": 120000, "run_in_background": false },
  "tool_use_id": "toolu_01ABC123..."
}
```

**Two distinct invocation forms — this is the load-bearing finding for the CAST validator question:**
- **Shell form (no `args` key in the hook's settings entry):** "runs when `args` is absent. The `command` string is passed to a shell: `sh -c` on macOS and Linux, Git Bash on Windows, or PowerShell when Git Bash isn't installed." The **entire command string, including everything after the first space, is the command** — it is not split or truncated by Claude Code; the shell interprets it as one line.
- **Exec form (with `args` present):** "runs when `args` is present. Claude Code resolves `command` as an executable on `PATH` and spawns it directly with `args` as the argument vector. There is no shell, so each `args` element is one argument exactly as written."

**Implication for the CAST validator bug being investigated:** a hook registered as `bash ~/.claude/scripts/foo.sh --mode post` is shell form (assuming no separate `args` array in the config) — the documented contract treats the full string `bash ~/.claude/scripts/foo.sh --mode post` as one shell command. **A local validator that strips everything after the first space would discard the script path and all arguments**, leaving only `bash` — that does not match the documented invocation contract in either form (shell form needs the whole string; exec form needs `command` to itself be the executable, with `args` supplying the rest). This strongly suggests the "strip after first space" behavior is a bug relative to the documented contract, though I did not read the CAST validator source itself this session (out of scope per the "no code changes" instruction — flagging for the requester to confirm against `scripts/cast-validate-all-hooks.sh` or wherever the validator lives).

## Sources

- https://code.claude.com/docs/en/hooks — Hooks reference: complete event list, exit-code table, JSON output schemas, stdin payload example, exec/shell form (fetched directly, no redirect)
- https://code.claude.com/docs/en/permissions — Permission rule syntax, Bash wildcard/word-boundary matching, compound-command awareness, hook-vs-permission-rule precedence, sandbox/permission interaction, "Read and Edit deny rules... don't apply to arbitrary subprocesses" gap (fetched directly)
- https://code.claude.com/docs/en/permission-modes — Protected paths list, Critical paths definition and circuit breaker, "Actions no mode auto-approves" (fetched directly)
- https://code.claude.com/docs/en/sandboxing — referenced by the permissions page for OS-level Bash filesystem/network isolation; **not independently fetched this session** — flagged `[unverified]` for any sandboxing detail not directly quoted from the permissions page above.
- WebSearch snippet (aggregated, not a single fetched page) noting "the reference documents 31 hook events, though other sources mention around 30 events" and third-party mirrors (claudefa.st, cc.bruniaux.com) reporting "30 events" — these are `[unverified]` third-party summaries, cited only to corroborate that the count is in flux/recently changed, not as an authoritative source. The live `code.claude.com/docs/en/hooks` fetch is the authoritative count (31).

## Contradictions vs. Prior Claims

- **Event count:** Prior CAST notes claimed "~29 events." Live doc (https://code.claude.com/docs/en/hooks, fetched 2026-08-20) lists **31** events. This is a real discrepancy, not close enough to round to "~29" — flag for correction in CAST docs/rules referencing hook counts.
- No other prior CAST claim about hook mechanics was checked against a claim explicit enough to confirm/deny in this session (the task said "a prior research run" had 2/5 items already found wrong, but the specifics of which 5 items were not supplied to this dispatch — only the event-count claim was named explicitly in the prompt).
