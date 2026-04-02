# Claude Code Native Tools Reference

Confirmed native tools from Claude Code internal source analysis. CAST agents can list
these in their `tools:` frontmatter to access them. Names are as confirmed.

| Tool | What it does | CAST agents that should add it |
|---|---|---|
| `VerifyPlanExecutionTool` | Returns PASS/FAIL/PARTIAL verdict after plan execution | orchestrator |
| `BriefTool` | Produces a brief/summarize output block | orchestrator, planner |
| `WorkflowTool` | Executes a structured workflow definition | orchestrator |
| `SleepTool` | Deliberate pause — useful in orchestrated pipelines for rate-limiting | orchestrator, bash-specialist |
| `REPLTool` | REPL-style code execution | debugger, code-writer |
| `ScheduleCronTool` | Schedule a cron job from within an agent | devops, bash-specialist |
| `EnterPlanMode` / `ExitPlanMode` | Native plan mode gates | planner, orchestrator |
| `EnterWorktree` / `ExitWorktree` | Native worktree management | code-writer, merge |

## Notes

- **VerifyPlanExecutionTool**: the orchestrator should call this after all batches complete
  to log a PASS/FAIL/PARTIAL verdict to cast.db `quality_gates`. Until added to the
  orchestrator `tools:` frontmatter, it is unavailable.
- **AgentHook / PromptHook**: hook types beyond `BashCommandHook` are available. CAST
  currently only uses `BashCommandHook` (type: "command"). `PromptHook` (type: "prompt")
  is already used in the PostCompact fragment. `AgentHook` dispatches a sub-agent — useful
  for reactive escalation patterns.
- **allowedHttpHookUrls**: any `type: "http"` hook requires the target URL to be listed
  in `allowedHttpHookUrls` in settings.json. Without it, HTTP hooks are silently blocked.
  Dev-only endpoints (localhost) should not ship in managed-settings.d fragments.

## Status

As of 2026-04-02 — names confirmed via source analysis. Verify against Claude Code
release notes before adding to production agent definitions.
