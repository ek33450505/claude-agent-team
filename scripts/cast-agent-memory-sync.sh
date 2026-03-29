#!/bin/bash
# cast-agent-memory-sync.sh — CAST Agent Memory DB Sync
# Walks ~/.claude/agent-memory-local/**/*.md, parses YAML frontmatter,
# and UPSERTs each memory file into cast.db agent_memories table.
#
# Each subdirectory under agent-memory-local/ is treated as the agent name.
# Frontmatter fields extracted: name, description, type
# Content = everything after the closing --- delimiter.
#
# UPSERT logic:
#   - If a row with the same (agent, name) exists: UPDATE content/description/type/updated_at
#   - Otherwise: INSERT with created_at = now
#
# Usage:
#   cast-agent-memory-sync.sh [--db /path/to/cast.db]
#
# Environment:
#   CAST_DB_PATH — override DB path (default: ~/.claude/cast.db)

# --- CAST subprocess guard (must be first) ---
if [ "${CLAUDE_SUBPROCESS:-0}" = "1" ]; then exit 0; fi

set -euo pipefail

DB_PATH="${CAST_DB_PATH:-${HOME}/.claude/cast.db}"
MEMORY_DIR="${HOME}/.claude/agent-memory-local"

# Allow override via flag
if [ "${1:-}" = "--db" ] && [ -n "${2:-}" ]; then
  DB_PATH="$2"
fi

# Validate DB exists
if [ ! -f "$DB_PATH" ]; then
  echo "[CAST-WARN] cast-agent-memory-sync: cast.db not found at $DB_PATH. Run cast-db-init.sh first." >&2
  exit 1
fi

# Validate memory directory exists
if [ ! -d "$MEMORY_DIR" ]; then
  echo "Warning: agent-memory-local directory not found at $MEMORY_DIR. Nothing to sync." >&2
  exit 0
fi

python3 - "$DB_PATH" "$MEMORY_DIR" <<'PYEOF'
import sys
import os
import sqlite3
import datetime
import glob

db_path = sys.argv[1]
memory_dir = sys.argv[2]

inserted = 0
updated = 0
errors = 0

def parse_frontmatter(content):
    """
    Parse YAML frontmatter between --- delimiters.
    Returns (fields_dict, body_content) where body is everything after closing ---.
    Returns ({}, full_content) if no valid frontmatter found.
    """
    lines = content.split('\n')
    if not lines or lines[0].strip() != '---':
        return {}, content

    end_idx = None
    for i in range(1, len(lines)):
        if lines[i].strip() == '---':
            end_idx = i
            break

    if end_idx is None:
        return {}, content

    frontmatter_lines = lines[1:end_idx]
    body_lines = lines[end_idx + 1:]

    fields = {}
    for line in frontmatter_lines:
        if ':' in line:
            key, _, val = line.partition(':')
            key = key.strip()
            val = val.strip()
            # Strip YAML quotes if present
            if len(val) >= 2 and ((val[0] == '"' and val[-1] == '"') or (val[0] == "'" and val[-1] == "'")):
                val = val[1:-1]
            if key:
                fields[key] = val

    body = '\n'.join(body_lines).strip()
    return fields, body


try:
    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
    cur = conn.cursor()
except Exception as e:
    print(f"[CAST-WARN] cast-agent-memory-sync: cannot connect to {db_path}: {e}", file=sys.stderr)
    sys.exit(1)

now = datetime.datetime.utcnow().isoformat() + 'Z'

# Walk agent-memory-local/<agent>/*.md
agent_dirs = [
    d for d in os.listdir(memory_dir)
    if os.path.isdir(os.path.join(memory_dir, d))
]

for agent in sorted(agent_dirs):
    agent_dir = os.path.join(memory_dir, agent)
    md_files = glob.glob(os.path.join(agent_dir, '*.md'))

    for fpath in sorted(md_files):
        try:
            with open(fpath, 'r', encoding='utf-8') as f:
                raw = f.read()
        except Exception as e:
            print(f"[ERROR] Could not read {fpath}: {e}", file=sys.stderr)
            errors += 1
            continue

        try:
            fields, body = parse_frontmatter(raw)
        except Exception as e:
            print(f"[ERROR] Could not parse frontmatter in {fpath}: {e}", file=sys.stderr)
            errors += 1
            continue

        name = fields.get('name', '') or os.path.splitext(os.path.basename(fpath))[0]
        description = fields.get('description', '') or ''
        mem_type = fields.get('type', '') or ''
        content = body

        if not name:
            print(f"[WARN] Skipping {fpath}: no name resolved", file=sys.stderr)
            continue

        try:
            # Check for existing row with same (agent, name)
            cur.execute(
                "SELECT id FROM agent_memories WHERE agent = ? AND name = ?",
                (agent, name)
            )
            row = cur.fetchone()

            if row:
                cur.execute(
                    """UPDATE agent_memories
                       SET content = ?, description = ?, type = ?, updated_at = ?
                       WHERE agent = ? AND name = ?""",
                    (content, description, mem_type, now, agent, name)
                )
                updated += 1
            else:
                cur.execute(
                    """INSERT INTO agent_memories
                       (agent, project, type, name, description, content, created_at, updated_at)
                       VALUES (?, ?, ?, ?, ?, ?, ?, ?)""",
                    (agent, None, mem_type, name, description, content, now, now)
                )
                inserted += 1

        except Exception as e:
            print(f"[ERROR] DB operation failed for {fpath}: {e}", file=sys.stderr)
            errors += 1
            continue

conn.commit()
conn.close()

print(f"cast-agent-memory-sync: {inserted} inserted, {updated} updated, {errors} errors", file=sys.stderr)
PYEOF

exit 0
