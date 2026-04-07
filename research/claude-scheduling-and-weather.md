# Research: Claude Code Scheduling, Weather APIs, and COROS Integration
**Date:** 2026-04-06
**Sources:** code.claude.com official docs, GitHub repos, npm registry

---

## 1. Scheduling Overview — Three Options

| | Cloud Tasks | Desktop Tasks | `/loop` |
|---|---|---|---|
| Runs on | Anthropic cloud | Your machine | Your machine |
| Requires machine on | No | Yes | Yes |
| Requires open session | No | No | Yes |
| Persistent | Yes | Yes | No (session-scoped) |
| Local file access | No (fresh clone) | Yes | Yes |
| MCP servers | Connectors per task | Config files + connectors | Inherits from session |
| Permission prompts | No (autonomous) | Configurable | Inherits from session |
| Minimum interval | 1 hour | 1 minute | 1 minute |

---

## 2. Desktop Scheduled Tasks

### How they work
Desktop tasks fire a fresh Claude Code session on a schedule. Desktop checks every minute while open; each task gets up to 10 minutes of stagger to avoid API traffic spikes. You get a desktop notification and a new session appears under "Scheduled" in the sidebar.

### Setup process
1. Click **Schedule** in the Desktop sidebar
2. Click **New task** → **New local task**
3. Fill in: Name, Description, Prompt, Frequency
4. Optionally enable **Worktree** toggle (gives each run an isolated Git worktree)
5. Click **Run now** immediately after creation to flush permission prompts

Or conversationally: *"set up a daily morning briefing that runs every day at 7am"*

### SKILL.md config format
Tasks are stored on disk at:
```
~/.claude/scheduled-tasks/<task-name>/SKILL.md
```

Format:
```markdown
---
name: morning-briefing
description: Daily summary of commits, weather, and task queue
---

Pull the last 24h of git commits from ~/Projects/personal/claude-agent-team,
check the cast.db for agent run stats, and print a morning briefing summary.
```

**Note:** Schedule, folder, model, and enabled state are NOT in SKILL.md — change those via the Edit form or by asking Claude.

### Limitations
- **macOS and Windows only** — not available on Linux
- Requires the Desktop app to be **open and awake**. Sleeping laptop = skipped run.
- **Catch-up:** On wake, Desktop runs exactly one catch-up run for the most recently missed time (discards older misses). A 7-day daily task that missed 6 days runs once.
- **Setting:** Enable "Keep computer awake" in Settings → Desktop app → General to prevent idle sleep (closing the lid still sleeps).
- Write catch-up guards into your prompt: *"Only act on data from today. If it's after 6pm, skip and log a note."*

### Permission handling
Each task has its own permission mode. `dontAsk` for unattended runs. Allow rules in `~/.claude/settings.json` apply to all task sessions.

---

## 3. Cloud (Remote) Scheduled Tasks

### How they work
Runs on Anthropic-managed infrastructure. Works when your machine is off. Clones a fresh copy of your GitHub repo on each run; Claude creates `claude/`-prefixed branches.

### Setup
Three entry points:
- **Web:** `claude.ai/code/scheduled` → New scheduled task
- **Desktop:** Schedule page → New task → New remote task
- **CLI:** `/schedule` (guided conversation), or `/schedule daily PR review at 9am`

### CLI management commands
```bash
/schedule                        # guided setup
/schedule list                   # see all tasks
/schedule update                 # change a task (incl. custom cron)
/schedule run                    # trigger immediately
```

### Custom cron via CLI
The web/desktop pickers only offer Hourly/Daily/Weekdays/Weekly. For custom intervals, use:
```
/schedule update
```
Then enter a cron expression. Minimum interval: **1 hour**. Expressions like `*/30 * * * *` are rejected.

### MCP connectors
Tasks include all your connected MCP connectors by default. Remove any not needed. Connectors are managed at Settings → Connectors on claude.ai.

### Environments
Each task runs in a cloud environment with:
- Network access level
- Environment variables (API keys, secrets)
- Setup script (install deps, configure tools)

**No local file access** — cloud tasks work against a GitHub repo clone only.

### Limitations
- No local file access (use Desktop tasks for that)
- Minimum 1-hour interval
- Cannot use locally-installed MCP servers (only connectors)
- GitHub repo required for file operations

---

## 4. `/loop` Command (Session-Scoped)

### How it works
`/loop` is a bundled skill that schedules a recurring prompt within the current CLI session. Uses cron under the hood.

### Syntax
```bash
/loop 5m check if the deployment finished
/loop check the build every 2 hours
/loop 20m /review-pr 1234        # loop can invoke other skills
/loop check the build             # no interval = defaults to every 10 minutes
```

### Interval units
`s` (seconds, rounded to minute), `m`, `h`, `d`

### One-shot reminders (no `/loop` needed)
```
remind me at 3pm to push the release branch
in 45 minutes, check whether the integration tests passed
```

### Managing tasks
```
what scheduled tasks do I have?
cancel the deploy check job
```

### Under-the-hood tools
- `CronCreate` — schedule with 5-field cron expression
- `CronList` — list all tasks
- `CronDelete` — cancel by ID

Max 50 tasks per session. Each task has an 8-char ID.

### Cron expression reference
```
*/5 * * * *     Every 5 minutes
0 * * * *       Every hour on the hour
0 9 * * *       Every day at 9am local
0 9 * * 1-5     Weekdays at 9am local
```

### Limitations
- **Session-scoped** — closes when you exit Claude Code
- No catch-up for missed fires while Claude is busy
- 7-day max expiry on recurring tasks (fires once final time, then self-deletes)
- Tasks fire only while Claude is idle (not mid-response)
- Disable entirely with env var: `CLAUDE_CODE_DISABLE_CRON=1`

---

## 5. `claude -p` Headless Mode for Cron

### Basic usage
```bash
claude -p "Find and fix the bug in auth.py" --allowedTools "Read,Edit,Bash"
```

The `-p` / `--print` flag: non-interactive, process one prompt, print result, exit. Clean target for cron.

### Recommended: bare mode for cron
```bash
claude --bare -p "Summarize this file" --allowedTools "Read"
```

`--bare` skips auto-discovery of hooks, skills, plugins, MCP servers, auto-memory, CLAUDE.md. Faster startup, reproducible on any machine.

**Note:** `--bare` is becoming the default for `-p` in a future release.

### Authentication in bare mode
Bare mode skips OAuth and keychain reads. Use one of:
```bash
export ANTHROPIC_API_KEY="sk-ant-..."
claude --bare -p "..." --allowedTools "Read"
```

Or pass via `--settings`:
```bash
claude --bare -p "..." --settings '{"apiKey":"sk-ant-..."}'
```

### MCP servers in headless
Without `--bare`, `claude -p` loads `.mcp.json` from the working directory and `~/.claude`. This means your morning-briefing script CAN use your configured MCP servers.

With `--bare`, you must pass MCP config explicitly:
```bash
claude --bare -p "Get today's weather" \
  --mcp-config ~/.claude/mcp-weather.json \
  --allowedTools "Read,Bash"
```

### Cron example
```cron
# Morning briefing at 7am weekdays
0 7 * * 1-5 ANTHROPIC_API_KEY=sk-ant-... /usr/local/bin/claude -p "Run the morning briefing" --allowedTools "Read,Bash" >> ~/.claude/logs/morning-briefing.log 2>&1
```

Or better, use a wrapper script that loads the key from keychain:
```bash
#!/bin/bash
# ~/.claude/scripts/morning-briefing.sh
export ANTHROPIC_API_KEY=$(security find-generic-password -a claude -s anthropic-api-key -w)
claude -p "Run the morning briefing skill" --allowedTools "Read,Bash"
```

### Output formats
```bash
# Plain text (default)
claude -p "What does auth.ts do?"

# JSON with session ID + metadata
claude -p "Summarize project" --output-format json

# Streaming JSON
claude -p "Write a report" --output-format stream-json --verbose --include-partial-messages

# Extract just the text result
claude -p "Summarize" --output-format json | jq -r '.result'
```

### Continue conversations
```bash
session_id=$(claude -p "Start review" --output-format json | jq -r '.session_id')
claude -p "Now focus on auth" --resume "$session_id"
```

---

## 6. Weather APIs for Morning Briefing

### Option A: NWS MCP Server (US only, no API key)

**Repo:** github.com/nitvob/nws-mcp-server  
**Stack:** Python + uv

Install:
```bash
git clone https://github.com/nitvob/nws-mcp-server
cd nws-mcp-server && uv sync
```

`~/.claude/claude_desktop_config.json` (or `~/.claude/mcp.json`):
```json
{
  "mcpServers": {
    "weather": {
      "command": "uv",
      "args": [
        "--directory", "/absolute/path/to/nws-mcp-server",
        "run", "weather.py"
      ]
    }
  }
}
```

Tools:
- `get-forecast` — lat/lon → detailed forecast (US only)
- `get-alerts` — two-letter state code → active weather alerts

**Pros:** Free, no API key, zero config  
**Cons:** US only

### Option B: OpenWeatherMap MCP (global, API key required)

**Repo:** github.com/SaintDoresh/Weather-MCP-ClaudeDesktop  
**Stack:** Python + pip

Install:
```bash
git clone https://github.com/SaintDoresh/Weather-MCP-ClaudeDesktop
cd Weather-MCP-ClaudeDesktop
pip install -r requirements.txt
echo "OPENWEATHER_API_KEY=your_key" > .env
```

Config:
```json
{
  "mcpServers": {
    "weather": {
      "command": "python3",
      "args": ["/absolute/path/to/Weather-MCP-ClaudeDesktop/main.py"]
    }
  }
}
```

Tools: `get_current_weather`, `get_weather_forecast` (5-day), `get_air_quality`, `get_historical_weather`, `search_location`, `get_weather_alerts`

**Pros:** Global coverage, richer data (AQI, historical, 5-day)  
**Cons:** Requires free API key (24h activation); free tier: 60 calls/min

### Option C: Direct NWS API call in bash (no MCP needed)

For a simple morning briefing, you can just curl it in a bash script:
```bash
# Get forecast for a lat/lon (US)
LAT=41.4993  # Columbus, OH
LON=-81.6944
GRID=$(curl -s "https://api.weather.gov/points/${LAT},${LON}" | jq -r '.properties | "\(.gridId)/\(.gridX),\(.gridY)"')
curl -s "https://api.weather.gov/gridpoints/${GRID}/forecast" | jq '.properties.periods[0]'
```

Pass the output directly to `claude -p` as context.

### Recommendation for morning-briefing agent
Use **NWS MCP server** if you're in the US — zero config, no keys. Add as an MCP server in `~/.claude/mcp.json` so it's available to all sessions and `claude -p` calls. For the CAST morning-briefing agent specifically, call the NWS API directly in the briefing script (curl + jq) and embed the result in the prompt — avoids MCP server complexity for a simple daily task.

---

## 7. COROS Fitness Watch Integration

### Official COROS API
COROS has an official API but requires submitting a developer application:
- Apply at: `support.coros.com/hc/en-us/articles/17085887816340-Submitting-an-API-Application`
- Approval process, not self-serve
- Intended for app developers / enterprise partners

### COROS MCP Server (unofficial)
**Repo:** github.com/Dhivakarkd/corus-mcp  
**Note:** Repo name has a typo — "corus" not "coros"

Data available:
- Recent workouts with lap-by-lap splits
- EvoLab scores, training status, recovery %
- Training calendar (scheduled + completed)
- Heart rate/pace training zones
- User profile + personal bests
- FIT/TCX/GPX file export
- Time-series GPS + biometric data (1Hz)

Config for Claude Desktop (`~/Library/Application Support/Claude/claude_desktop_config.json`):
```json
{
  "mcpServers": {
    "coros": {
      "command": "coros-mcp-server"
    }
  }
}
```

Auth: Browser-based OAuth at `localhost:8111`. Credentials stored at `~/.config/coros-mcp/credentials.json`.

**Critical caveat:** This uses **reverse-engineered, unofficial API endpoints**. COROS can break it at any time without notice. There is no guarantee of data accuracy or account safety.

### Terra API (production-grade, paid)
`tryterra.co/integrations/coros` — Normalized COROS data with webhooks. Designed for production apps. Requires paid plan.

### Recommendation
For personal use (morning briefing, training summary), the COROS MCP is viable but fragile. For anything mission-critical, go through Terra API or submit an official COROS API application.

---

## 8. Best Approach for CAST Morning Briefing

For a reliable `morning-briefing` agent that includes weather + COROS:

```
Scheduling:  Desktop scheduled task, daily 7am, permission mode: dontAsk
Weather:     NWS MCP or direct curl to api.weather.gov (US)
COROS:       COROS MCP server (unofficial, caveat emptor) or manual FIT export
Fallback:    If Desktop is asleep, catch-up fires when you open app
Local access: Desktop task can read cast.db, git log, local files — all available
```

Cron alternative (if Desktop unreliable):
```bash
# crontab -e
0 7 * * 1-5 ~/.claude/scripts/morning-briefing.sh >> ~/.claude/logs/morning.log 2>&1
```

Where `morning-briefing.sh` uses `claude -p` with `--allowedTools "Read,Bash"` and ANTHROPIC_API_KEY from keychain.

---

## Sources
- [Run Claude Code programmatically (headless docs)](https://code.claude.com/docs/en/headless)
- [Run prompts on a schedule (/loop docs)](https://code.claude.com/docs/en/scheduled-tasks)
- [Schedule recurring tasks in Claude Code Desktop](https://code.claude.com/docs/en/desktop-scheduled-tasks)
- [Schedule tasks on the web (cloud tasks)](https://code.claude.com/docs/en/web-scheduled-tasks)
- [NWS MCP server — nitvob](https://github.com/nitvob/nws-mcp-server)
- [OpenWeatherMap MCP — SaintDoresh](https://github.com/SaintDoresh/Weather-MCP-ClaudeDesktop)
- [COROS MCP server — Dhivakarkd](https://github.com/Dhivakarkd/corus-mcp)
- [COROS official API application](https://support.coros.com/hc/en-us/articles/17085887816340-Submitting-an-API-Application)
- [Terra API — COROS integration](https://tryterra.co/integrations/coros)
