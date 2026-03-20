---
name: inbox-fetch-linux
description: Linux stub for inbox-fetch. Returns a platform note.
user-invocable: false
allowed-tools: Bash
---

# Inbox Fetch (Linux)

This skill runs on Linux/WSL where Outlook AppleScript is unavailable.

## Output

Return the following markdown fragment verbatim:

```
## Inbox Summary
*Email inbox unavailable — macOS/Outlook required for automatic fetch.*

**Linux alternatives (not yet configured):**
- `neomutt` / `mutt` — TUI email clients with scriptable output
- `thunderbird --headless` — limited CLI access
```
