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
| `/laconic` | Toggle laconic terse-output mode. Usage: /laconic [lite|full|ultra|off] |
| `/merge` | Dispatch merge agent for git merges, rebases, conflict resolution |
| `/morning` | Dispatch morning-briefing agent to generate today's briefing |
| `/orchestrate` | Execute a CAST plan via the /orchestrate skill (main session dispatches sub-agents inline) |
| `/plan` | Dispatch planner agent to create an implementation plan |
| `/push` | Dispatch push agent to push committed work to remote |
| `/research` | Dispatch researcher agent for technical research |
| `/review` | Review code changes with size-appropriate strategy |
| `/roadmap` | Resume the CAST backlog — see `~/.claude/research/2026-06-03-anthropic-devs-claude-code-convergence.md` for the current convergence roadmap (research/cast-future-roadmap.md no longer exists) |
| `/secure` | Dispatch security agent for a security review |
| `/ship` | Run ship workflow: tests → CI check → commit → push → journal _(skill-backed, not one of the 19 core commands)_ |
| `/test` | Dispatch test-writer agent to write tests |

---

## Agents

| Agent | Model | Effort | Key Tools | Description |
|---|---|---|---|---|
| api-contract | sonnet | high | Read, Bash, Grep | API contract guardian, detects breaking changes |
| merge | haiku 4.5 | low | Bash, Read | PR lifecycle / git merge, rebase, conflict resolution, worktree cleanup |
| bash-specialist | haiku 4.5 | low | Bash, Edit, Grep | Shell scripting and BATS test specialist |
| code-reviewer | haiku 4.5 | low | Bash, Grep, Read | Post-change code review |
| backend-writer | sonnet | high | Edit, Write, Agent | Backend implementation specialist (Express/Node/SQLite/Anthropic SDK) |
| frontend-writer | sonnet | high | Edit, Write, Agent | Frontend implementation specialist (React/TypeScript/Vite) |
| commit | haiku 4.5 | low | Bash, Read | Semantic git commit creation |
| debugger | sonnet | high | Edit, Bash, Agent | Error investigation and fix |
| dep-auditor | haiku 4.5 | low | Read, Bash, Grep | Dependency auditor for CVEs and licenses |
| devops | haiku 4.5 | low | Bash, Edit, Grep | CI/CD, Docker, infrastructure |
| docs | haiku 4.5 | low | Write, Edit, WebSearch | Documentation updates, email drafting, portfolio sync (since 4.5.3) |
| eval-writer | sonnet | — | Read, Write, Edit, Bash | Eval + benchmark fixture author for agent prompts and routing rules |
| frontend-qa | haiku 4.5 | low | Bash, Grep, Read | Frontend quality assurance |
| migration-reviewer | opus | high | Read, Bash, Grep | Database schema change reviewer |
| morning-briefing | haiku 4.5 | low | Bash, Write, Grep | Daily morning briefing orchestrator |
| planner | sonnet | high | Read, Write, Grep | Implementation plan creation |
| pr-reviewer | sonnet | — | Read, Bash, Grep | Holistic PR-level reviewer at PR-open time; distinct from per-unit code-reviewer |
| push | haiku 4.5 | low | Bash, Read | Push commits to remote repository |
| release-notes | haiku 4.5 | low | Read, Write, Bash | Release notes generator from git commits |
| researcher | sonnet | high | WebFetch, WebSearch | Deep technical research and analysis |
| security | sonnet | high | Read, Grep, Bash | Security audit and review |
| test-runner | haiku 4.5 | low | Bash, Read, Glob | Run test suites and report results |
| test-writer | haiku 4.5 | low | Edit, Write, Bash | Write tests for code changes |

---

## Skills

| Skill | Description | User-invocable |
|---|---|---|
| briefing-writer | Assemble morning briefing sections into structured markdown | No |
| careful-mode | Require explicit confirmation before Write/Edit/Bash operations | Yes |
| freeze-mode | Read-only session, no file modifications allowed | Yes |
| git-activity | Scan project repos for yesterday's git activity | No |
| merge | Git merge, rebase, conflict resolution, worktree cleanup | Yes |
| orchestrate | Execute a CAST plan via the /orchestrate skill (main session dispatches sub-agents inline) | Yes |
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
| `cast cost` | Per-task/feature cost attribution (token totals + cache-read share) | `--by-task`, `--by-branch`, `--by-agent`, `--project`, `--limit`, `--json` |
| `cast predict "<task>"` | Predict cost + suggest agents from the record (reads past runs/incidents) | `--limit`, `--json` |
| `cast feature "<desc>"` | App-build: decompose a feature into gated units, build each via backend-writer/frontend-writer→code-reviewer→test→commit | |
| `cast mcp serve\|config\|status` | Expose the cast.db record read-only over MCP (stdio, local-only) so any CC session can query decisions/incidents/cost/sessions | |
| `cast agents` | List installed agents; with `--usage`, per-agent runtime stats (dispatches, avg cost, success rate) | `--usage`, `--json` |
| `cast hooks` | Show active hooks with health status | `--json` |
| `cast doctor` | Run system health check | |
| `cast tidy` | Clean up old plans, events, logs, briefings | `--dry-run` |
| `cast install-completions` | Install shell tab completions | |

Global flags: `--json`, `--quiet`, `--verbose`, `--help`, `--version`

---

## Routines

Scheduled autonomous agent jobs for daily tasks, triage, and reports.

| Routine | Schedule | What it does |
|---|---|---|
| `daily-briefing` | 7am UTC daily | Morning briefing: agent activity, blockers |
| `daily-cast-health` | 8pm UTC daily | CAST infrastructure health check |
| `email-triage` | Manual | Gmail triage, priority buckets, drafts |
| `knowledge-curator` | 10am UTC daily | Obsidian vault organization |
| `learning-scout` | 3pm UTC daily | Tech topic monitor, resource curator |
| `meeting-prep` | 6am UTC daily | Calendar-driven meeting briefs |
| `pr-narrator` | 30min after webhook | PR storyteller, change summary |
| `release-celebration` | Manual | Release notes + stakeholder brief |
| `standup-writer` | 4pm UTC daily | Daily standup summary |
| `task-triage` | 8am UTC daily | BLOCKED/overdue `agent_runs` from cast.db |
| `weekly-cost-report` | Mon 9am UTC | API cost breakdown by agent |

### Routine Commands

| Command | Description |
|---|---|
| `cast routines list` | List all routines with status |
| `cast routines get <name>` | Show routine status and last run |
| `cast routines trigger <name>` | Run routine manually (ignores schedule) |
| `cast routines trigger <name> --arg key=value` | Trigger with runtime arguments |
| `cast routines trigger <name> --dry-run` | Simulate without dispatching |
| `cast routines validate <name>` | Validate YAML syntax |
| `cast routines schedule <name>` | Install into crontab |
| `cast routines uninstall <name>` | Remove from crontab |
| `cast routines enable <name>` | Re-enable soft-disabled routine |
| `cast routines disable <name>` | Soft-disable routine |
| `cast routines install` | Install all routines at once |

Full guide: [docs/routines.md](docs/routines.md)

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
- **`[CAST-DISPATCH-GROUP: <group-id>]`** -- Auto-generate an Agent Dispatch Manifest from the payload JSON. Invoke the /orchestrate skill immediately with the plan file path. Do not delegate to an orchestrator agent.

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

### Run BATS tests locally
- Local BATS run: `bash tests/run.sh` (uses CI globs; never `bats tests/` -- non-recursive in BATS 1.13.0)

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
