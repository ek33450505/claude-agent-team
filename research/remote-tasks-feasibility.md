# Remote Tasks Feasibility for CAST/JARVIS

**Date:** 2026-04-10
**Author:** CAST Researcher Agent
**Status:** Research Complete

---

## What Are Remote Tasks?

Remote Tasks (also called "triggers" or "scheduled remote agents") allow you to define a repository + prompt + schedule that runs on Anthropic's infrastructure. They execute Claude Code sessions without requiring your local machine to be on.

Key characteristics:
- Runs in a sandboxed environment on Anthropic's cloud
- Has access to the specified repository (cloned fresh each run)
- Can use tools: Read, Write, Edit, Bash, Glob, Grep
- Can access MCP servers configured in the project
- Results are stored and retrievable via API or CLI
- Scheduled via cron expressions

## Capabilities and Limitations

### What Remote Tasks CAN Do
- Clone and read repository files
- Run bash commands in a sandboxed Linux environment
- Write files and create commits
- Push to remote repositories (with configured auth)
- Access configured MCP servers
- Run on a schedule (cron-style)

### What Remote Tasks CANNOT Do
- Access local filesystem outside the cloned repo
- Access local services (localhost, local databases)
- Use launchd or macOS-specific tooling
- Access ~/.claude/ directory (no agent memory, no cast.db)
- Run indefinitely (execution time limits apply)
- Access Obsidian vault (local filesystem)
- Access local Todoist/Strava API tokens stored in env vars (unless configured as repo secrets)

## JARVIS Agent Assessment

### pa-triage (daily inbox processing)

| Factor | Assessment |
|---|---|
| Todoist API | Requires API token as repo secret |
| Gmail/Calendar MCP | Can work if MCP server configured |
| Obsidian vault output | CANNOT write to local vault |
| Local context (cast.db) | NOT available |
| **Verdict** | **CONDITIONAL GO** — works if output goes to repo files or remote service, not Obsidian |

### pa-backup (3-layer backup)

| Factor | Assessment |
|---|---|
| Local file access | CANNOT access ~/.claude/ |
| cast.db | NOT available remotely |
| iCloud paths | NOT available |
| **Verdict** | **NO-GO** — fundamentally requires local filesystem access |

### pa-briefing (morning briefing)

| Factor | Assessment |
|---|---|
| Git activity | YES — can scan repos |
| Todoist/Calendar MCP | YES — if configured |
| Obsidian output | NO — local vault not accessible |
| cast.db analytics | NO — local database |
| **Verdict** | **CONDITIONAL GO** — can generate briefing content, but cannot write to Obsidian vault. Could write to repo or send via API |

### pa-eod (end of day summary)

| Factor | Assessment |
|---|---|
| Session data | NO — requires cast.db |
| Local context | NO |
| **Verdict** | **NO-GO** — depends entirely on local session state |

### pa-calendar (daily schedule)

| Factor | Assessment |
|---|---|
| Google Calendar MCP | YES — if configured |
| Output to Obsidian | NO |
| **Verdict** | **CONDITIONAL GO** — same as pa-briefing |

### pa-weekly (weekly summary)

| Factor | Assessment |
|---|---|
| Git history | YES |
| cast.db analytics | NO |
| Todoist completion data | YES — via API |
| **Verdict** | **PARTIAL GO** — can do git + Todoist portions but not CAST analytics |

### pa-meeting-prep (meeting preparation)

| Factor | Assessment |
|---|---|
| Calendar MCP | YES |
| Document research | YES |
| **Verdict** | **GO** — well-suited for remote execution |

### pa-jira (Jira integration)

| Factor | Assessment |
|---|---|
| Jira MCP | YES — if configured |
| **Verdict** | **GO** — API-only, perfect for remote |

## Cost Implications

- Remote Tasks consume API tokens at standard rates
- Each execution = fresh clone + full session cost
- Local launchd execution uses your existing Claude Code subscription
- For 8 daily PA agents: approximately $2-5/day in API costs (rough estimate based on task complexity)
- Local execution: included in subscription

## Security Considerations

- API tokens must be stored as repository secrets (not in local env files)
- Repository is cloned to Anthropic infrastructure — ensure no sensitive data in repo
- MCP server credentials travel with the configuration
- Audit trail available via Remote Tasks API

## Recommendations

| Agent | Recommendation | Rationale |
|---|---|---|
| pa-jira | **Migrate to Remote** | Pure API work, no local dependencies |
| pa-meeting-prep | **Migrate to Remote** | Calendar + research, no local state needed |
| pa-triage | **Hybrid** | Run remotely but redirect output from Obsidian to repo/API |
| pa-briefing | **Hybrid** | Git portions remote, cast.db portions local |
| pa-calendar | **Hybrid** | Calendar remote, output needs redirect |
| pa-weekly | **Keep Local** | Too dependent on cast.db for full value |
| pa-backup | **Keep Local** | Fundamentally local filesystem operation |
| pa-eod | **Keep Local** | Entirely session-state dependent |

## Migration Path

1. **Phase 1:** Migrate pa-jira and pa-meeting-prep (zero local dependencies)
2. **Phase 2:** Add output adapters to pa-triage, pa-briefing, pa-calendar to support both local (Obsidian) and remote (repo/API) output targets
3. **Phase 3:** Set up Remote Tasks schedules for Phase 1+2 agents
4. **Phase 4:** Keep pa-backup, pa-eod, pa-weekly on launchd; evaluate as Remote Tasks capabilities expand

## Open Questions

- Will Remote Tasks eventually support persistent storage (equivalent to cast.db)?
- Can MCP server state persist across Remote Task executions?
- What is the actual execution time limit for Remote Tasks?
- Is there a way to trigger a local hook from a Remote Task completion?
