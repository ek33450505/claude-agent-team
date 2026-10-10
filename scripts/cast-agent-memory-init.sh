#!/bin/bash
# cast-agent-memory-init.sh — CAST Agent Memory Seeder
# Seeds or updates each active agent's MEMORY.md with project context
# and recent dispatch history from the event log.
#
# Triggered by cast-session-end.sh after session end (runs in background, no args).
# Memory entries are project-scoped (keyed by repo root path).
#
# Safety: Custom Notes are user data and are never dropped (an unreadable file is
# skipped, not overwritten); writes are atomic (temp file + os.replace); the script
# never follows symlinks (a symlinked agent dir or MEMORY.md is skipped).
#
# Usage:
#   cast-agent-memory-init.sh [--project-root /path/to/project]

set -euo pipefail

PROJECT_ROOT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --project-root)
      shift
      # A value starting with '-' is another flag, not a path: warn, ignore, and
      # leave it for the next loop iteration. Never fail the session end.
      if [ $# -gt 0 ] && [[ "${1:-}" != -* ]]; then
        PROJECT_ROOT="$1"
        shift
      elif [ $# -gt 0 ]; then
        echo "cast-agent-memory-init: --project-root value '${1}' looks like a flag; ignoring" >&2
      fi
      ;;
    --project-root=*)
      if [[ "${1#--project-root=}" == -* ]]; then
        echo "cast-agent-memory-init: --project-root value '${1#--project-root=}' looks like a flag; ignoring" >&2
      else
        PROJECT_ROOT="${1#--project-root=}"
      fi
      shift
      ;;
    *) shift ;;
  esac
done
# No (or empty) --project-root: fall back to the git toplevel of the cwd (the session-end caller passes no args).
if [ -z "$PROJECT_ROOT" ]; then
  PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo "")"
fi
AGENT_MEMORY_DIR="${HOME}/.claude/agent-memory-local"
EVENTS_DIR="${HOME}/.claude/cast/events"
AGENT_REGISTRY_DIR="${HOME}/.claude/agents"

# H3: Dynamic agent discovery — no hardcoded ghost agents.
# Discover from ~/.claude/agents/ first; fall back to repo agents/core/ if needed.
if [ -d "${AGENT_REGISTRY_DIR}" ]; then
  KNOWN_AGENTS_LIST="$(find "${AGENT_REGISTRY_DIR}" -name '*.md' -exec basename {} .md \; 2>/dev/null | sort)"
fi
if [ -z "${KNOWN_AGENTS_LIST:-}" ]; then
  SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
  FALLBACK_DIR="${SCRIPT_DIR}/../agents/core"
  if [ -d "$FALLBACK_DIR" ]; then
    KNOWN_AGENTS_LIST="$(find "$FALLBACK_DIR" -name '*.md' -exec basename {} .md \; 2>/dev/null | sort)"
  fi
fi
# Final fallback: empty list — don't seed phantom agents
KNOWN_AGENTS_LIST="${KNOWN_AGENTS_LIST:-}"

CAST_PROJECT_ROOT="$PROJECT_ROOT" CAST_KNOWN_AGENTS="$KNOWN_AGENTS_LIST" python3 -I - <<'PYEOF' || true
import json, os, re, shutil, sys, glob, datetime
from collections import defaultdict

project_root = os.environ.get('CAST_PROJECT_ROOT', '')
known_agents_raw = os.environ.get('CAST_KNOWN_AGENTS', '')
agent_memory_dir = os.path.expanduser('~/.claude/agent-memory-local')
events_dir = os.path.expanduser('~/.claude/cast/events')
today = datetime.date.today().isoformat()

# Project name is the basename of the project root
project_name = os.path.basename(project_root) if project_root else 'unknown'

# H3: Use dynamically discovered agents — no ghost agents
known_agents = [a.strip() for a in known_agents_raw.splitlines() if a.strip()]
if not known_agents:
    print("No agents discovered — skipping memory seed.")
    sys.exit(0)

# Read recent events
events = []
if os.path.isdir(events_dir):
    event_files = sorted(glob.glob(os.path.join(events_dir, '*.json')))[-200:]  # last 200 events max
    for fpath in event_files:
        try:
            with open(fpath) as f:
                event = json.load(f)
            events.append(event)
        except Exception:
            continue

# Group events by agent
agent_events = defaultdict(list)
for event in events:
    agent = event.get('agent', '')
    if agent:
        agent_events[agent].append(event)

# Write or update each agent's MEMORY.md
for agent in known_agents:
    agent_dir = os.path.join(agent_memory_dir, agent)
    memory_path = os.path.join(agent_dir, 'MEMORY.md')

    # Never follow symlinks: an agent-planted link must not turn this script into
    # an arbitrary-file overwrite, and replacing the link would diverge from its target.
    if os.path.islink(agent_dir) or os.path.islink(memory_path):
        print(f'cast-agent-memory-init: {agent_dir} or {memory_path} is a symlink; skipping', file=sys.stderr)
        continue
    try:
        os.makedirs(agent_dir, exist_ok=True)
    except OSError as exc:
        print(f'cast-agent-memory-init: cannot create {agent_dir} ({exc}); skipping', file=sys.stderr)
        continue

    # Gather last 3 tasks for this agent
    agent_task_events = [
        e for e in agent_events.get(agent, [])
        if e.get('type') in ('task_completed', 'task_blocked', 'task_claimed')
    ]
    last3_tasks = agent_task_events[-3:] if len(agent_task_events) >= 3 else agent_task_events

    # Gather BLOCKED history
    blocked_events = [
        e for e in agent_events.get(agent, [])
        if e.get('type') == 'task_blocked'
    ]

    # Build memory content
    task_lines = []
    for e in reversed(last3_tasks):
        ts = e.get('timestamp', '?')[:10]
        etype = e.get('type', '?').replace('task_', '')
        msg = e.get('message', '')[:60]
        batch = e.get('batch', '?')
        task_lines.append(f'- [{ts}] {etype} | {batch} | {msg}')

    blocked_lines = []
    for e in blocked_events[-3:]:
        ts = e.get('timestamp', '?')[:10]
        msg = e.get('message', '')[:60]
        blocked_lines.append(f'- [{ts}] BLOCKED | {msg}')

    # Read existing memory to preserve custom notes if present
    existing_custom = ''
    if os.path.exists(memory_path):
        try:
            with open(memory_path, encoding='utf-8') as f:
                content = f.read()
        except (OSError, UnicodeDecodeError) as exc:
            # Custom Notes are user data: if we cannot read the file we cannot
            # preserve them, so we must NOT overwrite it. Skip this agent.
            print(f'cast-agent-memory-init: cannot read {memory_path} ({exc}); skipping to preserve Custom Notes', file=sys.stderr)
            continue
        # Preserve from the first level-2 "## Custom Notes" heading, including suffixed
        # forms ("## Custom Notes (private)", "## Custom Notes:"); not "### Custom Notes"
        # or "## Custom Notesfoo".
        m = re.search(r'^## Custom Notes\b', content, re.M)
        if m:
            existing_custom = '\n' + content[m.start():].strip()

    memory_content = f'''---
project: {project_name}
type: agent-memory
agent: {agent}
updated: {today}
---

# {project_name} — {agent} Memory

## Project Context
- Project: {project_name}
- Root: {project_root if project_root else 'unknown'}
- Agent memory auto-seeded by cast-agent-memory-init.sh

## Recent Tasks (last 3)
{chr(10).join(task_lines) if task_lines else '- No recent tasks recorded'}

## BLOCKED History
{chr(10).join(blocked_lines) if blocked_lines else '- No blocked history'}
{existing_custom}
'''

    # Atomic write: temp file in the same dir, then os.replace (overlapping
    # background runs never see or leave a truncated MEMORY.md).
    tmp_path = f'{memory_path}.tmp.{os.getpid()}'
    try:
        with open(tmp_path, 'w', encoding='utf-8') as f:
            f.write(memory_content)
            f.flush()
            os.fsync(f.fileno())
        if os.path.exists(memory_path):
            shutil.copymode(memory_path, tmp_path)  # keep a 0600/0444 MEMORY.md's mode
        os.replace(tmp_path, memory_path)
    except (OSError, ValueError) as exc:  # ValueError covers UnicodeEncodeError (lone surrogates)
        print(f'cast-agent-memory-init: cannot write {memory_path} ({exc}); skipping', file=sys.stderr)
        continue
    finally:
        try:
            os.unlink(tmp_path)  # no-op (ENOENT) after a successful replace
        except OSError:
            pass

print(f'Agent memory seeded for {len(known_agents)} agents in project: {project_name}')
print(f'Memory directory: {agent_memory_dir}')
PYEOF

exit 0
