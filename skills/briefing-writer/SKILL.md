---
name: briefing-writer
description: Assemble morning briefing sections into a structured markdown file. Use when writing the final briefing output after all data sources have been gathered.
user-invocable: false
allowed-tools: Bash, Write
---

# Briefing Writer

Assemble gathered data sections into a structured morning briefing file.

## Instructions

You will receive data sections (git activity, action items, CAST intelligence) as markdown fragments. Assemble them into this template:

```markdown
# Morning Briefing — [Weekday], [Month Day Year]
*Generated [HH:MM] · [N] items across [N] sources*

## Git Activity (Yesterday)
[git data or "No commits yesterday"]

## Open Action Items
*From recent meeting notes and TODOs*
[action items data or "No open action items"]

## CAST Intelligence
- **Dirty repos:** [list or "All clean"]
- **Open PRs:** [list or "None"]
- **Yesterday's spend:** [sessions/tokens/cost or "No data"]
- **Blocked agents:** [list or "None"]
```

## Output Rules

1. Get today's date: `date "+%A, %B %d %Y"` and `date +%Y-%m-%d`
2. Write to: `~/.claude/briefings/YYYY-MM-DD-morning.md`
3. **Never overwrite** — if file exists, append `_2` suffix
4. Count total items across all sections (git commits + action items + CAST alerts) for the header line
5. Count sources that returned data (not errors) for the header line
6. Each section must appear even if empty — show the "no data" message rather than omitting

## After Writing

Confirm: `Morning briefing written to ~/.claude/briefings/YYYY-MM-DD-morning.md`
