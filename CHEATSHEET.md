# CAST Cheat Sheet

Quick reference for the Claude Agent Specialist Team (CAST) framework.

---

## Slash Commands

| Command | What it does |
|---|---|
| `/agents` | List all installed CAST agents with model and description |
| `/bash` | Dispatch bash-specialist agent for shell scripting and BATS work |
| `/cast` | CAST diagnostic and manual dispatch command |
| `/commit` | Dispatch commit agent to create a semantic git commit |
| `/debug` | Dispatch debugger agent to investigate and fix an issue |
| `/devops` | Dispatch devops agent for CI/CD, Docker, and infrastructure |
| `/docs` | Dispatch docs agent to update documentation |
| `/doctor` | Run comprehensive CAST system health check |
| `/merge` | Dispatch merge agent for git merges, rebases, conflict resolution |
| `/morning` | Dispatch morning-briefing agent to generate today's briefing |
| `/orchestrate` | Execute a CAST plan via the orchestrator agent |
| `/plan` | Dispatch planner agent to create an implementation plan |
| `/push` | Dispatch push agent to push committed work to remote |
| `/research` | Dispatch researcher agent for technical research |
| `/review` | Review code changes with size-appropriate strategy |
| `/roadmap` | Resume the CAST backlog from research/cast-future-roadmap.md |
| `/secure` | Dispatch security agent for a security review |
| `/test` | Dispatch test-writer agent to write tests |

---

## Agents

| Agent | Model | Effort | Key Tools | Description |
|---|---|---|---|---|
| bash-specialist | sonnet | medium | Bash, Edit, Grep | Shell scripting and BATS test specialist |
| code-reviewer | haiku | low | Bash, Grep, Read | Post-change code review |
| code-writer | sonnet | high | Edit, Write, Agent | Primary code implementation agent |
| commit | haiku | low | Bash, Read | Semantic git commit creation |
| debugger | sonnet | high | Edit, Bash, Agent | Error investigation and fix |
| devops | sonnet | medium | Bash, Edit, Grep | CI/CD, Docker, infrastructure |
| docs | sonnet | medium | Write, Edit, WebSearch | Documentation updates |
| frontend-qa | haiku | low | Bash, Grep, Read | Frontend quality assurance |
| merge | sonnet | medium | Bash, Edit, Grep | Git merge, rebase, conflict resolution |
| morning-briefing | sonnet | medium | Bash, Write, Grep | Daily morning briefing orchestrator |
| orchestrator | sonnet | high | Agent, TaskCreate | Plan executor, batch dispatcher |
| planner | sonnet | high | Read, Write, Grep | Implementation plan creation |
| push | haiku | low | Bash, Read | Push commits to remote repository |
| researcher | sonnet | high | WebFetch, WebSearch | Deep technical research and analysis |
| security | sonnet | high | Read, Grep, Bash | Security audit and review |
| test-runner | haiku | low | Bash, Read, Glob | Run test suites and report results |
| test-writer | sonnet | high | Edit, Write, Bash | Write tests for code changes |

---

## Skills

| Skill | Description | User-invocable |
|---|---|---|
| briefing-writer | Assemble morning briefing sections into structured markdown | No |
| careful-mode | Require explicit confirmation before Write/Edit/Bash operations | Yes |
| freeze-mode | Read-only session, no file modifications allowed | Yes |
| git-activity | Scan project repos for yesterday's git activity | No |
| merge | Git merge, rebase, and conflict resolution | Yes |
| orchestrate | Execute a CAST plan by dispatching the orchestrator | Yes |
| plan | Write a structured plan with Agent Dispatch Manifest | Yes |
| wizard | Multi-step workflow with human-approval gates | Yes |

---

## cast CLI

| Subcommand | Description | Key Flags |
|---|---|---|
| `cast status` | Terminal health dashboard | `--json` |
| `cast exec <plan>` | Execute a plan manifest | `--resume`, `--status` |
| `cast memory search` | Search agent memories | `--agent`, `--project`, `--limit` |
| `cast memory list` | List all agent memories | `--agent`, `--type` |
| `cast memory forget <id>` | Delete a memory entry | |
| `cast memory export` | Export all memories as JSON | |
| `cast budget` | View cost summary | `--week`, `--project` |
| `cast agents` | List installed CAST agents | `--json` |
| `cast hooks` | Show active hooks with health status | `--json` |
| `cast doctor` | Run system health check | |
| `cast tidy` | Clean up old plans, events, logs, briefings | `--dry-run` |
| `cast install-completions` | Install shell tab completions | |

Global flags: `--json`, `--quiet`, `--verbose`, `--help`, `--version`

---

## Hook Events

| Event | Script(s) | What it does |
|---|---|---|
| SessionStart | cast-session-start-hook.sh | Initialize session, seed agent memory |
| UserPromptSubmit | cast-policy-gate.sh | Policy gate for prompt validation |
| PreToolUse | cast-pretool-gate.sh | Guard tool usage (commit, push blocks) |
| PostToolUse | cast-posttool-hook.sh | Post-tool logging and reactions |
| Stop | cast-stop-hook.sh | Session end cleanup and DB logging |

---

## Dispatch Directives

These directives appear in hook-injected context and must be followed immediately:

- **`[CAST-DISPATCH]`** -- Dispatch the named agent via the Agent tool. Pass the user's full prompt. Do NOT handle inline.
- **`[CAST-CHAIN]`** -- After the primary agent completes, dispatch the listed agents in sequence. No confirmation needed.
- **`[CAST-REVIEW]`** -- Dispatch code-reviewer (haiku) after completing the current logical unit of changes.
- **`[CAST-DISPATCH-GROUP: <group-id>]`** -- Auto-generate an Agent Dispatch Manifest from the payload JSON. Pass to orchestrator immediately with no approval gate.

---

## Escape Hatches

| Variable | Effect |
|---|---|
| `CAST_COMMIT_AGENT=1` | Bypass the PreToolUse commit block (let commit agent run git commit) |
| `CAST_PUSH_OK=1` | Bypass the PreToolUse push block (let push agent run git push) |
| `CAST_POLICY_OVERRIDE=1` | Skip the UserPromptSubmit policy gate |
| `CLAUDE_SUBPROCESS=1` | Signal that this is a subprocess (hooks exit early) |

---

## Common Workflows

### Plan, orchestrate, commit, push
1. `/plan` -- describe the feature or change
2. Review the generated plan file in `~/.claude/plans/`
3. `/orchestrate` -- execute the plan (dispatches agents in batches)
4. `/commit` -- stage and commit all changes
5. `/push` -- push to remote

### Debug a failure
1. `/debug` -- describe the error or paste the stack trace
2. Debugger investigates, proposes a fix, and self-dispatches code-reviewer
3. `/test` -- verify the fix passes tests

### Morning briefing
1. `/morning` -- generates today's briefing
2. Output: `~/.claude/briefings/YYYY-MM-DD-morning.md`

### Code review
1. `/review` -- reviews staged or recent changes
2. Uses size-appropriate strategy (haiku for small, sonnet for large)

---

## Key Paths

| Purpose | Path |
|---|---|
| CAST runtime root | `~/.claude/` |
| Agent definitions | `~/.claude/agents/` |
| Hook scripts | `~/.claude/scripts/` |
| Agent memory (local) | `~/.claude/agent-memory-local/` |
| Plans | `~/.claude/plans/` |
| CAST SQLite DB | `~/.claude/cast.db` |
| Event log | `~/.claude/cast/events/` |
| Agent status | `~/.claude/agent-status/` |
| Briefings | `~/.claude/briefings/` |
| Reports | `~/.claude/reports/` |
| CAST CLI config | `~/.claude/config/cast-cli.json` |
| CAST CLI binary | `~/.local/bin/cast` |
| Skills | `~/.claude/skills/` |
| Commands | project `commands/` directory |

---

## Keyboard Shortcuts

| Shortcut | Action |
|---|---|
| `Shift+Tab` | Cycle through permission modes (ask/auto/bypass) |
| `Ctrl+C` | Cancel current generation |
| `Esc` | Stop current agent and return control |
| `Esc Esc` | Rewind last change |
| `/compact` | Compact conversation context |
| `/clear` | Clear conversation and start fresh |
