# Claude Code Native Tools Reference

Confirmed native tools from Claude Code internal source analysis. CAST agents can list
these in their `tools:` frontmatter to access them. Names are as confirmed.

| Tool | What it does | CAST agents that should add it |
|---|---|---|
| `VerifyPlanExecutionTool` | Returns PASS/FAIL/PARTIAL verdict after plan execution | orchestrator |
| `BriefTool` | Produces a brief/summarize output block | orchestrator, planner |
| `WorkflowTool` | **Platform-native successor to the `/orchestrate` + ADM pattern (Phase 10 convergence target).** Claude authors a JS orchestration script; native Dynamic Workflows replace the Agent Dispatch Manifest for new dispatches. **Available & verified 2026-06-03 — used for a 7-agent fan-out in-session.** | orchestrator |
| `SleepTool` | Deliberate pause — useful in orchestrated pipelines for rate-limiting | orchestrator, bash-specialist |
| `REPLTool` | REPL-style code execution | debugger, code-writer |
| `ScheduleCronTool` | Schedule a cron job from within an agent | devops, bash-specialist |
| `EnterPlanMode` / `ExitPlanMode` | Native plan mode gates | planner, orchestrator |
| `EnterWorktree` / `ExitWorktree` | Native worktree management | code-writer, merge |

## Notes

- **WorkflowTool (Dynamic Workflows)**: the platform-native successor to `/orchestrate` + ADM. Confirmed available and working 2026-06-03 (7-agent fan-out executed in-session). New non-critical multi-agent dispatches should prefer this over the ADM path. The ADM path is retained as the stable legacy fallback until a piloted migration validates native Workflows for CAST's critical dispatch paths. See Phase 10 in `~/.claude/research/2026-06-03-anthropic-devs-claude-code-convergence.md`.
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

As of 2026-06-03 — `WorkflowTool` (Dynamic Workflows) confirmed available and working in production (7-agent fan-out). Other tools confirmed via source analysis 2026-04-02. Verify against Claude Code release notes before adding to production agent definitions.
