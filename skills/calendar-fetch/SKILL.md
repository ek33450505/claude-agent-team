---
name: calendar-fetch
description: Fetch today's calendar events from Microsoft Outlook on macOS via AppleScript. Use when gathering calendar data for briefings, schedule checks, meeting prep, or when user asks "what's on my calendar" or "any meetings today".
user-invocable: false
allowed-tools: Bash
---

# Calendar Fetch

Fetch today's calendar events from Microsoft Outlook via AppleScript.

## Instructions

1. Run the AppleScript below via a temp-file approach (avoids inline escaping issues):

```bash
SCRIPT=$(mktemp /tmp/outlook_cal_XXXXXX.scpt)
cat > "$SCRIPT" << 'HEREDOC'
tell application "Microsoft Outlook"
  set todayStart to current date
  set time of todayStart to 0
  set todayEnd to todayStart + (24 * 60 * 60) - 1
  set evts to calendar events whose start time >= todayStart and start time <= todayEnd
  set result to {}
  repeat with e in evts
    set end of result to (time string of start time of e) & " | " & (subject of e)
  end repeat
  return result
end tell
HEREDOC
result=$(osascript "$SCRIPT" 2>&1)
exit_code=$?
rm -f "$SCRIPT"
echo "$result"
```

2. Handle errors based on exit code and stderr content:
   - **Exit 0, empty output** → "No calendar events today"
   - **Contains "-600"** → "*Outlook not running — calendar unavailable*"
   - **Contains "-1743"** → "*Outlook automation blocked — grant access in System Settings > Privacy & Security > Automation*"
   - **Contains "-2741" or "-10810"** → "*Calendar unavailable due to sandbox restrictions*"
   - **Any other error** → include the raw error text as-is

   In ALL error cases: return the error message as the section content and **continue to the next step**. Never stop execution.

3. Return output as a markdown table:

```markdown
| Time | Event |
|------|-------|
| 9:00 AM | Team standup |
```

If no events: `*No calendar events today*`
