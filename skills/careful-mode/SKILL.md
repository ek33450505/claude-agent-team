---
name: careful-mode
description: Activate careful mode — require explicit confirmation before any Write, Edit, or Bash operations. Use when working on production code or sensitive systems.
user-invocable: true
allowed-tools: []
---

# Careful Mode Activated

For the remainder of this session:

1. Before EVERY Write or Edit operation, summarize the change and ask for confirmation
2. Before EVERY Bash command, show the command and ask for confirmation
3. Never use `git push`, `rm`, or `DROP` without triple-confirmation
4. Review each file change for security implications before applying
5. Explain your reasoning before each action — no silent changes

To deactivate, start a new session or say "deactivate careful mode".
