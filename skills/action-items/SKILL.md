---
name: action-items
description: Scan meeting notes for open action items (unchecked checkboxes). Use when gathering outstanding tasks for briefings, follow-up reviews, or when user asks "what tasks are open" or "pending action items".
user-invocable: false
allowed-tools: Bash
---

# Action Items

Scan meeting notes for open (unchecked) action items.

## Instructions

1. Search for unchecked items in the meetings directory:

```bash
grep -r "- \[ \]" ~/.claude/meetings/ 2>/dev/null | head -20
```

2. Format each result as:
   `- [ ] [filename-without-path] item text`

   Extract just the filename (not full path) and the task text after `- [ ]`.

3. Return output as a checklist (limit 20 items):

```markdown
- [ ] [2026-03-18-standup] Follow up with vendor re: renewal
- [ ] [2026-03-15-planning] Draft Q2 roadmap section
```

If no items found: `*No open action items in meetings/*`
