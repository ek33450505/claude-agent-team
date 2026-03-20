---
name: inbox-fetch
description: Fetch unread emails from Microsoft Outlook on macOS and classify by priority. Use when summarizing inbox, triaging email, gathering email data for briefings, or when user asks "check my email" or "any new messages".
user-invocable: false
allowed-tools: Bash
---

# Inbox Fetch

Fetch and classify unread emails from Microsoft Outlook via AppleScript.

## Instructions

1. Run the AppleScript below via temp file:

```bash
SCRIPT=$(mktemp /tmp/outlook_inbox_XXXXXX.scpt)
cat > "$SCRIPT" << 'HEREDOC'
tell application "Microsoft Outlook"
  set unread to messages of inbox whose is read is false
  set result to {}
  repeat with m in unread
    set end of result to (address of sender of m) & " | " & (subject of m)
  end repeat
  return result
end tell
HEREDOC
result=$(osascript "$SCRIPT" 2>&1)
exit_code=$?
rm -f "$SCRIPT"
echo "$result"
```

2. Handle errors based on exit code and stderr:
   - **Contains "-600"** → "*Outlook not running — inbox unavailable*"
   - **Contains "-1743"** → "*Outlook automation blocked*"
   - **Contains "-2741" or "-10810"** → "*Inbox unavailable due to sandbox restrictions*"
   - **Any other error** → include the raw error text

   In ALL error cases: return the error message as the section content and **continue**. Never stop.

3. Classify each message:
   - **Action Required**: subject contains "?", "please", "deadline", "urgent", "FW:", or "RE:" with a question
   - **FYI**: CC'd messages, announcements, status updates
   - **Archive** (omit from output): noreply@, newsletter keywords, automated notifications

4. Return output as a markdown table (limit 10 messages):

```markdown
| Priority | From | Subject |
|----------|------|---------|
| Action Required | sender | subject |
| FYI | sender | subject |
```

If more than 10: add `*+N more unread messages*`
If no unread: `*Inbox zero*`
