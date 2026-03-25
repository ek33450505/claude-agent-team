#!/bin/bash
# cast-agent-memory-init.sh — CAST Agent Memory Seeder
# Seeds or updates each active agent's MEMORY.md with project context
# and recent dispatch history from the event log.
#
# Triggered by stop-hook.sh after session end (runs in background).
# Memory entries are project-scoped (keyed by repo root path).
#
# Usage:
#   cast-agent-memory-init.sh [--project-root /path/to/project]

set -euo pipefail

PROJECT_ROOT="${2:-$(git rev-parse --show-toplevel 2>/dev/null || echo "")}"
AGENT_MEMORY_DIR="${HOME}/.claude/agent-memory-local"
EVENTS_DIR="${HOME}/.claude/cast/events"
AGENT_REGISTRY_DIR="${HOME}/.claude/agents"

# Known agents to seed memory for
KNOWN_AGENTS=(
  "commit"
  "code-reviewer"
  "build-error-resolver"
  "refactor-cleaner"
  "doc-updater"
  "auto-stager"
  "debugger"
  "test-writer"
  "planner"
  "security"
  "architect"
  "researcher"
  "bash-specialist"
  "test-runner"
  "report-writer"
  "chain-reporter"
  "verifier"
)

python3 -c "
import json, os, sys, glob, datetime
from collections import defaultdict

project_root = os.environ.get('CAST_PROJECT_ROOT', '')
agent_memory_dir = os.path.expanduser('~/.claude/agent-memory-local')
events_dir = os.path.expanduser('~/.claude/cast/events')
today = datetime.date.today().isoformat()

# Detect project name and stack from project-catalog.md if available
project_name = os.path.basename(project_root) if project_root else 'unknown'

known_agents = [
    'commit', 'code-reviewer', 'build-error-resolver', 'refactor-cleaner',
    'doc-updater', 'auto-stager', 'debugger', 'test-writer', 'planner',
    'security', 'architect', 'researcher', 'bash-specialist', 'test-runner',
    'report-writer', 'chain-reporter', 'verifier'
]

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
    os.makedirs(agent_dir, exist_ok=True)
    memory_path = os.path.join(agent_dir, 'MEMORY.md')

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
            with open(memory_path) as f:
                content = f.read()
            # Extract any ## Custom Notes section
            if '## Custom Notes' in content:
                custom_start = content.index('## Custom Notes')
                existing_custom = '\n' + content[custom_start:].strip()
        except Exception:
            pass

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
- Stack: React 19 + Vite + Express + Node.js (see ~/.claude/rules/stack-context.md)
- Agent memory auto-seeded by cast-agent-memory-init.sh

## Recent Tasks (last 3)
{chr(10).join(task_lines) if task_lines else '- No recent tasks recorded'}

## BLOCKED History
{chr(10).join(blocked_lines) if blocked_lines else '- No blocked history'}
{existing_custom}
'''

    with open(memory_path, 'w') as f:
        f.write(memory_content)

print(f'Agent memory seeded for {len(known_agents)} agents in project: {project_name}')
print(f'Memory directory: {agent_memory_dir}')
" CAST_PROJECT_ROOT="$PROJECT_ROOT" 2>/dev/null || true

exit 0
