---
name: reminders-fetch
description: Fetch due and overdue reminders from Apple Reminders on macOS. Use when gathering task data for briefings or checking pending reminders.
user-invocable: false
allowed-tools: Bash
---

# Reminders Fetch

Fetch due and overdue reminders from Apple Reminders via AppleScript.

## Instructions

1. Run the AppleScript below via temp file:

```bash
SCRIPT=$(mktemp /tmp/reminders_XXXXXX.scpt)
cat > "$SCRIPT" << 'HEREDOC'
tell application "Reminders"
  set today to current date
  set time of today to 0
  set tomorrow to today + (24 * 60 * 60)
  set dueItems to {}
  repeat with lst in lists
    repeat with r in reminders of lst
      if completed of r is false then
        if due date of r exists then
          if due date of r < tomorrow then
            set end of dueItems to (name of r) & " | due: " & (date string of due date of r)
          end if
        end if
      end if
    end repeat
  end repeat
  return dueItems
end tell
HEREDOC
result=$(osascript "$SCRIPT" 2>&1)
exit_code=$?
rm -f "$SCRIPT"
echo "$result"
```

2. Handle errors based on exit code and stderr:
   - **Contains "-600"** → "*Reminders app not running — reminders unavailable*"
   - **Contains "-1743"** → "*Reminders automation blocked*"
   - **Contains "-2741" or "-10810"** → "*Reminders unavailable due to sandbox restrictions*"
   - **Any other error** → include the raw error text

   In ALL error cases: return the error message as the section content and **continue**. Never stop.

3. Return output as a checklist:

```markdown
- [ ] Task name (due: today)
- [ ] Overdue task (was due: YYYY-MM-DD)
```

Mark items overdue if their due date is before today.
If no items: `*No reminders due today*`
