Use the `morning-briefing` agent to generate today's morning briefing.

The agent orchestrates 6 skills in sequence:
1. `calendar-fetch` — Calendar events
2. `inbox-fetch` — Unread email summary
3. `reminders-fetch` — Due reminders
4. `git-activity` — Yesterday's commits across all projects
5. `action-items` — Open items from meeting notes
6. `briefing-writer` — Assembles all data into the final briefing file

Output: `briefings/YYYY-MM-DD-morning.md`

**Run from Terminal** (not Claude Code) — AppleScript needs direct macOS access.
