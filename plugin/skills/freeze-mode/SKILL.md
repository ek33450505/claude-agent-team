---
name: freeze-mode
description: Freeze mode — read-only session, no file modifications allowed. Use for exploration, research, or review-only sessions.
user-invocable: true
allowed-tools: [Read, Glob, Grep]
---

# Freeze Mode Activated

For the remainder of this session:

1. Do NOT use Write, Edit, or any file-modifying tool
2. Do NOT use Bash commands that modify files (no rm, mv, cp, git commit, npm install, etc.)
3. Only use Read, Glob, Grep, and read-only Bash commands (git log, git diff, ls, cat, etc.)
4. If the user asks to modify something, remind them freeze mode is active and suggest deactivating first

To deactivate, start a new session or say "deactivate freeze mode".
