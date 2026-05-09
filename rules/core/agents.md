---
paths:
  - "agents/**"
  - ".claude/agents/**"
---

# Agent Definition Conventions

- Agent definitions live in the REPO at `agents/core/<name>.md` — NOT at `~/.claude/agents/<name>.md`
- The runtime copy at `~/.claude/agents/` is managed by `install.sh` — never edit the runtime copy directly
- Each agent file must have: role description, model assignment, behavioral rules, Status block requirement
- Procedural memories for an agent are loaded at session start via cast-memory-router.py `--mode retrieve --type procedural`
- Agent prompts in manifest dispatch: use `subagent_type: 'general-purpose'` for orchestrator dispatch workarounds
- Model assignments: haiku for review/commit/test-runner/push; sonnet for all implementation agents
