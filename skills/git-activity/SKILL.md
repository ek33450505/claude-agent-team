---
name: git-activity
description: Scan project repositories for yesterday's git activity. Use when summarizing development progress for briefings, reports, standups, or when user asks "what did I work on yesterday" or "recent commits".
user-invocable: false
allowed-tools: Bash
---

# Git Activity

Scan known project directories for git commits since yesterday.

## Project Directories

Sourced from `~/.claude/config.sh`. Edit that file to add or remove projects.

## Instructions

1. Run the following script:

```bash
source ~/.claude/config.sh
for dir in "${PROJECTS[@]}"; do
  if [ -d "$dir/.git" ]; then
    count=$(git -C "$dir" log --since="yesterday" --oneline 2>/dev/null | wc -l | tr -d ' ')
    if [ "$count" -gt 0 ]; then
      remote=$(git -C "$dir" remote get-url origin 2>/dev/null || echo "local")
      if echo "$remote" | grep -q "bitbucket"; then
        host="Bitbucket"
      elif echo "$remote" | grep -q "github"; then
        host="GitHub"
      else
        host="local"
      fi
      echo "=== $(basename $dir) ($count commits) [$host] ==="
      git -C "$dir" log --since="yesterday" --oneline 2>/dev/null
    fi
  fi
done
```

2. Return output as a markdown table (omit repos with 0 commits):

```markdown
| Project | Host | Commits | Summary |
|---------|------|---------|---------|
| my-project | GitHub | 3 | feat: add chart, fix: tooltip, chore: deps |
```

If no activity at all: `*No commits yesterday*`
