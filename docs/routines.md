# Routines: Scheduled Agent Workflows

Routines are **time-triggered or event-triggered autonomous agent jobs** that run on a schedule without user interaction. Unlike slash commands and interactive agent dispatch, routines execute asynchronously via cron and RemoteTrigger, making them ideal for housekeeping, monitoring, and periodic AI tasks.

## What Routines Solve

Interactive agents (e.g., `/plan`, `/debug`, `/test`) are best for in-session problem-solving where you provide context and feedback in real-time. Routines fill the gap: **tasks that should run daily or weekly without asking**, like:

- Morning briefings summarizing overnight activity
- Email and task inbox triage
- Infrastructure health checks
- Release notes generation
- Weekly cost reports

Routines generalize the JARVIS PA (Personal Assistant) pattern: define the task once in YAML, schedule it, and forget it.

---

## YAML Schema

Routines live in `~/.claude/routines/` as individual YAML files, named `<routine-name>.yaml`.

### Required fields

```yaml
name: daily-briefing
description: "Run morning-briefing agent at 8am daily"
trigger:
  type: cron
  value: "0 7 * * *"          # Standard crontab format (UTC)
agent: morning-briefing        # Agent to dispatch
prompt_template: |
  Your prompt here. Can reference {{routine_output_path}}.
output_dir: "~/.claude/routines-output/daily-briefing"
enabled: true
```

### Optional fields

```yaml
mcp_required:                  # List of MCP servers required; pre-flight check fails if absent
  - claude_ai_Gmail
  - todoist

notes: |                       # Documentation, escape hatches, setup instructions
  This routine requires...
```

### Trigger types

| Type | Value format | Example | Notes |
|---|---|---|---|
| `cron` | Standard crontab format (UTC) | `"0 7 * * *"` (7am UTC daily) | Most common; UTC timezone |
| `manual` | N/A — triggered by hand | See task-triage routine | Use when event-driven scheduling isn't ready |

### Special variables in `prompt_template`

| Variable | Value | Notes |
|---|---|---|
| `{{routine_output_path}}` | `~/.claude/routines-output/<name>/<timestamp>.md` | Write results here |

### prompt_args — Dynamic Prompt Interpolation

Routines can accept runtime arguments via `--arg key=value` flags. Arguments are interpolated into `prompt_template` using `{{key}}` syntax:

```yaml
# routine YAML
prompt_template: |
  Fetch tickets with priority={{priority}} from {{project_name}}.

# trigger with args
cast routines trigger my-routine --arg priority=high --arg project_name=INGEST
```

Arguments are shell-escaped automatically.

### mcp_required — Pre-flight MCP Check

If `mcp_required` lists MCP servers, the routine runner verifies they are reachable before dispatch:

```yaml
mcp_required:
  - claude_ai_Gmail
  - todoist
```

If a required MCP is unavailable, dispatch fails with a clear error. Skip the check with:

```bash
CAST_ROUTINE_SKIP_MCP_CHECK=1 cast routines trigger email-triage
```

---

## The 11 Built-in Routines

| Name | Schedule | What it does |
|---|---|---|
| `daily-briefing` | 7am daily | Morning briefing: agent activity summary, blockers, urgent flags |
| `daily-cast-health` | 8pm daily | CAST infra health check: hook status, db size, agent availability |
| `email-triage` | Manual | Gmail inbox triage, priority buckets, draft replies for starred items |
| `knowledge-curator` | 10am daily | Organize Obsidian vault, surface orphaned notes, suggest links |
| `learning-scout` | 3pm daily | Tech topic monitor, curate learning resources by topic |
| `meeting-prep` | 6am daily | Calendar-driven briefs for today's meetings, include attendees + context |
| `pr-narrator` | 30min after GitHub webhook | PR storyteller: summarize changes, flag risks, suggest reviewers |
| `release-celebration` | Manual | Release notes + celebration brief for stakeholders |
| `standup-writer` | 4pm daily | Daily standup summary (blockers, wins, next 24h) |
| `task-triage` | 8am daily | Todoist overdue surfacing, BLOCKED agents from cast.db, priority summary |
| `weekly-cost-report` | Mon 9am | Claude API cost breakdown by agent, week-over-week trends |

---

## Authoring a New Routine

### Step 1: Create the YAML file

```bash
cat > ~/.claude/routines/my-routine.yaml << 'EOF'
name: my-routine
description: "What this routine does"
trigger:
  type: cron
  value: "0 9 * * *"          # 9am UTC daily
agent: researcher
prompt_template: |
  Your task description here.
  Write output to {{routine_output_path}}.
output_dir: "~/.claude/routines-output/my-routine"
enabled: true
notes: |
  Setup notes, MCP requirements, etc.
EOF
```

### Step 2: Validate the YAML

```bash
cast routines validate my-routine
```

The validator checks schema, required fields, and cron syntax. Fix any errors before proceeding.

### Step 3: Dry-run before scheduling

```bash
cast routines trigger my-routine --dry-run
```

This simulates the dispatch without actually running the agent. Verify the prompt and output path are correct.

### Step 4: Test with a live run

```bash
cast routines trigger my-routine
```

Check the output at `~/.claude/routines-output/my-routine/<timestamp>.md`. If the agent succeeded, proceed. If it failed, debug with:

```bash
cast routines get my-routine        # Show last run status and logs
```

### Step 5: Schedule with cron

```bash
cast routines schedule my-routine
```

This installs the routine into the system crontab (via `crontab -e` integration). You'll see the cron entry in the crontab output. Verify it's there:

```bash
crontab -l | grep my-routine
```

---

## Output

Routine output is written to `~/.claude/routines-output/<name>/<timestamp>.md` by default. Use `{{routine_output_path}}` in your prompt to reference this path:

```yaml
prompt_template: |
  Fetch unread mail and summarize to {{routine_output_path}}.
```

The runner creates the directory if it doesn't exist. Each run gets its own timestamped file; historical output is preserved.

---

## Escape Hatches

### Disable without unscheduling

```yaml
# In the YAML file:
enabled: false
```

This soft-disables the routine — the cron entry remains in the crontab, but the runner exits early without dispatching.

### Disable via CLI

```bash
cast routines disable my-routine
```

This sets `enabled: false` in the YAML. Re-enable with:

```bash
cast routines enable my-routine
```

### Skip MCP pre-flight check

If a required MCP is temporarily unavailable but you want the routine to proceed:

```bash
CAST_ROUTINE_SKIP_MCP_CHECK=1 cast routines trigger my-routine
```

---

## Environment & Authentication

### ANTHROPIC_API_KEY

Routines dispatch agents remotely via `cast-managed-agent.sh` (Anthropic-hosted Managed Agents). This requires `ANTHROPIC_API_KEY` to be set.

**Option 1: Environment variable**

```bash
export ANTHROPIC_API_KEY="sk-..."
```

**Option 2: macOS Keychain (recommended)**

```bash
security add-generic-password -s anthropic-api-key -a "$USER" -w "sk-..."
```

The routine runner reads from Keychain automatically if the env var is not set. Only do this once.

---

## CLI Reference

```bash
# List all routines with status
cast routines list

# Show status of one routine
cast routines get my-routine

# Trigger a routine manually (ignores schedule)
cast routines trigger my-routine

# Trigger with arguments
cast routines trigger my-routine --arg priority=high --arg project=INGEST

# Dry-run (simulate without dispatching)
cast routines trigger my-routine --dry-run

# Validate YAML
cast routines validate my-routine

# Schedule into crontab
cast routines schedule my-routine

# Soft-disable
cast routines disable my-routine

# Re-enable
cast routines enable my-routine

# Install all routines at once (run after fresh clone)
cast routines install

# Uninstall from crontab
cast routines uninstall my-routine
```

---

## Troubleshooting

### Routine failed with "MCP not found"

The routine requires an MCP server (e.g., `claude_ai_Gmail`) that isn't wired in `~/.claude/settings.json`. Either:

1. Wire the MCP in settings.json and re-trigger, or
2. Skip the pre-flight check: `CAST_ROUTINE_SKIP_MCP_CHECK=1 cast routines trigger <name>`

### Cron job runs but agent doesn't dispatch

Common causes:

- `ANTHROPIC_API_KEY` not set and Keychain entry missing. Set one of the two.
- `~/.claude/scripts/cast-routine-runner.sh` not found. Run `bash install.sh` to reinstall.
- `enabled: false` in the YAML. Check the routine YAML.

Check logs:

```bash
tail -50 ~/.claude/logs/routine-errors.log
```

### Routine output directory not created

The runner creates the directory automatically. If it's missing, verify the `output_dir` path in the YAML is valid (e.g., `~` expands correctly).

---

## Next Steps

- **Manage routines:** `cast routines list`, `cast routines get <name>`
- **Author routines:** Copy one of the built-in routines as a template, edit, validate, schedule.
- **View output:** `ls -la ~/.claude/routines-output/`
- **View cast.db:** Routine runs are logged to cast.db with agent_id, status, and output path.
