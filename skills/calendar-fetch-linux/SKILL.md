---
name: calendar-fetch-linux
description: Linux stub for calendar-fetch. Returns a platform note and documents gcalcli as an alternative.
user-invocable: false
allowed-tools: Bash
---

# Calendar Fetch (Linux)

This skill runs on Linux/WSL where AppleScript is unavailable.

## Output

Return the following markdown fragment verbatim:

```
## Today's Calendar
*Calendar unavailable — macOS/Outlook required for automatic fetch.*

**Linux alternatives (not yet configured):**
- `gcalcli` — Google Calendar CLI (`pip install gcalcli`)
- `calcurse` — TUI calendar with iCal support
```

If `gcalcli` is installed (`which gcalcli`), attempt: `gcalcli agenda today tomorrow --nocolor 2>/dev/null`
and include the output if the command succeeds.
