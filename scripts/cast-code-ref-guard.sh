#!/usr/bin/env bash
# cast-code-ref-guard.sh — verify code references in agent output exist in repo
#
# Usage: echo "$agent_output" | bash scripts/cast-code-ref-guard.sh [--repo-root PATH]
#
# Extracts function/import references from stdin (agent output text) and greps the repo
# to verify they exist. Writes results to cast.db code_ref_checks table.
#
# Exit: always 0 (v1 = observability only, never block)
#
# Environment vars:
#   CAST_DB_PATH        — path to cast.db (default: ~/.claude/cast.db)
#   CAST_SESSION_ID     — session ID for logging (optional)
#   CAST_AGENT_NAME     — agent name for logging (optional)

set -euo pipefail

# Subprocess guard: do not run inside subagents
if [[ "${CLAUDE_SUBPROCESS:-0}" == "1" ]]; then
  exit 0
fi

# ============================================================================
# Config
# ============================================================================

REPO_ROOT="${1:-.}"
DB_PATH="${CAST_DB_PATH:-${HOME}/.claude/cast.db}"
SESSION_ID="${CAST_SESSION_ID:-unknown}"
AGENT_NAME="${CAST_AGENT_NAME:-unknown}"

# Nothing to do if db doesn't exist — will be created on first write
if [ ! -f "$DB_PATH" ]; then
  exit 0
fi

# Read stdin once
INPUT="$(cat 2>/dev/null || true)"
if [ -z "$INPUT" ]; then
  exit 0
fi

# ============================================================================
# Extract and verify code references via Python heredoc
# ============================================================================

DB_PATH_VAL="$DB_PATH" \
REPO_ROOT_VAL="$REPO_ROOT" \
SESSION_ID_VAL="$SESSION_ID" \
AGENT_NAME_VAL="$AGENT_NAME" \
INPUT_VAL="$INPUT" \
python3 - <<'PYEOF'

import os, sys, sqlite3, re, datetime
from pathlib import Path

db_path = os.environ.get('DB_PATH_VAL', '')
repo_root = os.environ.get('REPO_ROOT_VAL', '.')
session_id = os.environ.get('SESSION_ID_VAL', 'unknown')
agent_name = os.environ.get('AGENT_NAME_VAL', 'unknown')
input_text = os.environ.get('INPUT_VAL', '')

if not input_text:
    sys.exit(0)

# -----------------------------------------------------------------------
# 1. Extract code references from input text
# -----------------------------------------------------------------------

def extract_references(text):
    """Extract function names, imports, and file paths from agent output."""
    refs = {
        'functions': set(),
        'imports': set(),
        'files': set(),
    }

    # Function patterns: "function foo", "def foo", "foo()", "const foo ="
    func_patterns = [
        r'\bfunction\s+([a-zA-Z_]\w*)\b',
        r'\bdef\s+([a-zA-Z_]\w*)\b',
        r'\b([a-zA-Z_]\w*)\s*\(\)',
        r'\bconst\s+([a-zA-Z_]\w*)\s*=',
        r'\bfunction\s+([a-zA-Z_]\w*)',
    ]
    for pattern in func_patterns:
        matches = re.findall(pattern, text)
        for m in matches:
            if len(m) >= 3:  # skip 1-2 char names (common false positives)
                refs['functions'].add(m)

    # Import patterns: "import foo", "from 'foo'", "require('foo')"
    import_patterns = [
        r"from\s+['\"]([^'\"]+)['\"]",
        r"import\s+['\"]([^'\"]+)['\"]",
        r"require\s*\(\s*['\"]([^'\"]+)['\"]",
        r"import\s+{\s*([^}]+)\s*}",
    ]
    for pattern in import_patterns:
        matches = re.findall(pattern, text)
        for m in matches:
            if m.strip():
                # For imports like "import { foo, bar }", split and add each
                for part in m.split(','):
                    part = part.strip()
                    if part and len(part) >= 3:
                        refs['imports'].add(part)

    # File paths: paths with extensions that look real (scripts, modules, etc.)
    file_pattern = r'\b([\w./]+\.(sh|py|js|ts|tsx|bats|md|json))\b'
    matches = re.findall(file_pattern, text)
    for m in matches:
        path = m[0] if isinstance(m, tuple) else m
        if path and not path.startswith('.'):  # skip relative dot-paths
            refs['files'].add(path)

    return refs

refs = extract_references(input_text)

# -----------------------------------------------------------------------
# 2. Verify references exist in repo
# -----------------------------------------------------------------------

def verify_function(func_name, repo_root):
    """Check if function exists in scripts/ or bin/ directories."""
    search_dirs = [
        os.path.join(repo_root, 'scripts'),
        os.path.join(repo_root, 'bin'),
    ]
    for d in search_dirs:
        if not os.path.isdir(d):
            continue
        try:
            for root, dirs, files in os.walk(d):
                for f in files:
                    if f.endswith(('.sh', '.py', '.js', '.ts')):
                        fpath = os.path.join(root, f)
                        try:
                            with open(fpath, 'r', errors='ignore') as fp:
                                content = fp.read()
                                # Match: function X, def X, const X =, export const X
                                if re.search(
                                    rf'(function\s+{re.escape(func_name)}\b|'
                                    rf'def\s+{re.escape(func_name)}\b|'
                                    rf'const\s+{re.escape(func_name)}\s*=|'
                                    rf'export\s+(const|function)\s+{re.escape(func_name)}\b)',
                                    content
                                ):
                                    return True, fpath
                        except Exception:
                            pass
        except Exception:
            pass
    return False, None

def verify_file(file_path, repo_root):
    """Check if file exists in repo."""
    candidate = os.path.join(repo_root, file_path)
    if os.path.isfile(candidate):
        return True, candidate
    # Also try absolute
    if os.path.isfile(file_path):
        return True, file_path
    return False, None

# -----------------------------------------------------------------------
# 3. Collect results
# -----------------------------------------------------------------------

results = {
    'verified': [],
    'not_found': [],
    'skipped': [],
}

# Verify functions
for func_name in sorted(refs['functions']):
    found, location = verify_function(func_name, repo_root)
    if found:
        results['verified'].append({
            'type': 'function',
            'name': func_name,
            'location': location,
        })
    else:
        results['not_found'].append({
            'type': 'function',
            'name': func_name,
        })

# Verify files
for file_path in sorted(refs['files']):
    found, location = verify_file(file_path, repo_root)
    if found:
        results['verified'].append({
            'type': 'file',
            'name': file_path,
            'location': location,
        })
    else:
        results['not_found'].append({
            'type': 'file',
            'name': file_path,
        })

# -----------------------------------------------------------------------
# 4. Write results to DB
# -----------------------------------------------------------------------

try:
    conn = sqlite3.connect(db_path, timeout=5)
    conn.row_factory = sqlite3.Row
    cur = conn.cursor()

    # Create table if not exists
    cur.execute('''
        CREATE TABLE IF NOT EXISTS code_ref_checks (
            id              INTEGER PRIMARY KEY AUTOINCREMENT,
            session_id      TEXT,
            agent_name      TEXT,
            ref_type        TEXT,
            ref_name        TEXT,
            verified        INTEGER,
            location        TEXT,
            timestamp       TEXT
        )
    ''')

    ts = datetime.datetime.now(datetime.timezone.utc).isoformat().replace('+00:00', 'Z')

    # Write verified refs
    for item in results['verified']:
        cur.execute('''
            INSERT INTO code_ref_checks
            (session_id, agent_name, ref_type, ref_name, verified, location, timestamp)
            VALUES (?, ?, ?, ?, ?, ?, ?)
        ''', (
            session_id,
            agent_name,
            item['type'],
            item['name'],
            1,
            item.get('location', ''),
            ts,
        ))

    # Write not-found refs
    for item in results['not_found']:
        cur.execute('''
            INSERT INTO code_ref_checks
            (session_id, agent_name, ref_type, ref_name, verified, timestamp)
            VALUES (?, ?, ?, ?, ?, ?)
        ''', (
            session_id,
            agent_name,
            item['type'],
            item['name'],
            0,
            ts,
        ))

    conn.commit()
    conn.close()
except Exception as e:
    # Non-fatal: log but exit 0
    log_dir = os.path.expanduser('~/.claude/logs')
    try:
        os.makedirs(log_dir, exist_ok=True)
        with open(os.path.join(log_dir, 'code-ref-guard.log'), 'a') as f:
            f.write(f'[ERROR] {ts}: {e}\n')
    except Exception:
        pass

# -----------------------------------------------------------------------
# 5. Print results to stdout (for Work Log inclusion)
# -----------------------------------------------------------------------

verified_count = len(results['verified'])
not_found_count = len(results['not_found'])

if verified_count == 0 and not_found_count == 0:
    sys.exit(0)

print(f'[CAST-REF-CHECK] {verified_count + not_found_count} references checked, '
      f'{verified_count} verified, {not_found_count} not found')

for item in sorted(results['verified'], key=lambda x: x['name']):
    print(f'[VERIFIED]  {item["name"]}')

for item in sorted(results['not_found'], key=lambda x: x['name']):
    print(f'[NOT FOUND] {item["name"]}')

PYEOF

exit 0
