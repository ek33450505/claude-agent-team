#!/usr/bin/env python3
"""
write-guards.py — Unified Python backend for write-guards.sh (Phase 4, Unit 1).
Parses PreToolUse input ONCE, extracts tool metadata, validates against three guards.
"""
import json
import os
import sys
import sqlite3
import uuid
from datetime import datetime, timezone

def load_input():
    """Load and parse the PreToolUse JSON from stdin or CAST_WG_INPUT env."""
    raw = os.environ.get('CAST_WG_INPUT', '').strip()
    if not raw:
        try:
            raw = sys.stdin.read().strip()
        except Exception:
            raw = '{}'
    try:
        return json.loads(raw)
    except Exception:
        return {}

def extract_metadata(data):
    """Extract tool, file_path, content, and old_string from PreToolUse JSON."""
    ti = data.get('tool_input', {}) or {}
    tool = data.get('tool_name', '')
    file_path = ti.get('file_path', ti.get('path', ''))
    content = ti.get('content', ti.get('new_string', ''))
    old_string = ti.get('old_string', '')
    return tool, file_path, content, old_string

def write_log(log_path, message):
    """Write a timestamped message to a log file."""
    try:
        os.makedirs(os.path.dirname(log_path), exist_ok=True)
        with open(log_path, 'a') as f:
            f.write(f"[{datetime.now(timezone.utc).isoformat().replace('+00:00', 'Z')}] {message}\n")
    except Exception:
        pass

def _line_count(s):
    """Count lines in s using splitlines() — correct for content with or without trailing newline."""
    if not s:
        return 0
    return len(s.splitlines())

def check_tilde_write(file_path, home):
    if not file_path:
        return False, ""
    if '/~/' in file_path:
        suffix = file_path.split('/~/', 1)[-1]
        corrected = os.path.join(home, suffix)
    elif file_path.endswith('/~'):
        corrected = home
    else:
        return False, ""
    log_path = os.path.join(home, '.claude/logs/tilde-guard.log')
    write_log(log_path, f"BLOCK literal-tilde write: {file_path}")
    msg = f"""BLOCKED: Write attempt to literal-tilde path.

Path:      {file_path}
Likely intended: {corrected}

The literal '~' as a directory segment is a plan-mode harness path bug —
it creates a phantom subdirectory under cwd instead of expanding to $HOME.

Action: rewrite the path using the corrected form above ({corrected}-prefixed),
then retry the Write.

Logged to: ~/.claude/logs/tilde-guard.log"""
    return True, msg

def check_stat_claim(file_path, content, home):
    """Check for mismatched test count in README badge. Returns (should_block, message)."""
    if not file_path.endswith('README.md'):
        return False, ""
    if not any(x in content for x in ['tests-', 'badge', 'test']):
        return False, ""
    
    log_path = os.path.join(home, '.claude/logs/stat-guard.log')
    
    # Count actual @test lines
    try:
        import subprocess
        result = subprocess.run(
            ["git", "ls-files", "tests/*.bats", "tests/*/*.bats"],
            capture_output=True, text=True, timeout=5
        )
        test_files = result.stdout.strip().split('\n') if result.stdout.strip() else []
        
        if test_files:
            grep_result = subprocess.run(
                ["grep", "-h", "^@test"] + test_files,
                capture_output=True, text=True, timeout=5
            )
            real_count = len([l for l in grep_result.stdout.split('\n') if l.strip()])
        else:
            real_count = 0
    except Exception:
        real_count = 0
    
    # Extract claimed count
    import re
    match = re.search(r'tests-(\d+)', content)
    claimed_count = int(match.group(1)) if match else 0
    
    if claimed_count and claimed_count != real_count:
        write_log(log_path, f"Stat claim check: claimed={claimed_count}, actual={real_count}")
        msg = f"[CAST STAT GUARD] Badge claims {claimed_count} tests but actual @test count is {real_count}. Difference: {claimed_count - real_count}. Update the badge before proceeding. (See: feedback_bats_count_method.md)"
        return True, msg
    
    return False, ""

def record_no_fake_success(file_path, pattern, home, session_id):
    """Record a no-fake-success advisory to DB and log. Returns hookSpecificOutput if matched."""
    log_path = os.path.join(home, '.claude/logs/no-fake-success-guard.log')
    write_log(log_path, f"WARN: {pattern} in {file_path}")
    
    db_path = os.environ.get('CAST_DB_PATH', os.path.join(home, '.claude/cast.db'))
    if os.path.isfile(db_path):
        try:
            gate_id = str(uuid.uuid4())
            timestamp = datetime.now(timezone.utc).isoformat().replace('+00:00', 'Z')

            conn = sqlite3.connect(db_path, timeout=5)
            conn.execute(
                "INSERT OR IGNORE INTO quality_gates (id, session_id, agent_name, timestamp, status_line, gate_type, contract_passed) VALUES (?, ?, ?, ?, ?, ?, ?)",
                (gate_id, session_id, 'cast-no-fake-success-guard', timestamp, 'WARN', 'no-fake-success', 0)
            )
            conn.commit()
            conn.close()
        except Exception:
            pass

    return json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "additionalContext": f"[CAST FAKE-SUCCESS WARN] {file_path}: try/except|catch returns sample/mock data — verify this is intentional, not silent failure masking. Skip with /* fake-success-ok */ comment if intentional."
        }
    })

def check_destructive_docs_edit(tool: str, file_path: str, content: str, old_string: str, home: str):
    """Block Write/Edit that destroys large swaths of append-only docs. Returns (should_block, message)."""
    if not file_path:
        return False, ""

    # Determine if path is a guarded doc
    basename = os.path.basename(file_path)
    is_changelog = (basename == 'CHANGELOG.md')
    is_docs_md = ('/docs/' in file_path and file_path.endswith('.md'))
    if not (is_changelog or is_docs_md):
        return False, ""

    # Parse threshold (fail-open on bad value)
    try:
        threshold = int(os.environ.get('CAST_DOCS_DELETE_THRESHOLD', '30'))
    except (ValueError, TypeError):
        threshold = 30

    # Compute net_deleted
    try:
        if tool == 'Write':
            try:
                with open(file_path, 'r', encoding='utf-8', errors='replace') as fh:
                    disk_content = fh.read()
                net_deleted = _line_count(disk_content) - _line_count(content)
            except FileNotFoundError:
                return False, ""  # new file — nothing to destroy
        else:
            # Edit: compare old_string vs new_string (content)
            net_deleted = _line_count(old_string) - _line_count(content)
    except Exception as _e:
        # fail-open — never crash the hook pipeline (python.md convention) — but LOG, don't swallow silently.
        try:
            write_log(os.path.join(home, '.claude/logs/destroy-guard.log'),
                      f"guard-error (fail-open): {tool} {file_path}: {_e}")
        except Exception:
            pass
        return False, ""

    if net_deleted < threshold:
        return False, ""

    # Author acknowledged with the ack token — allow but log
    if '[docs-destroy-ok]' in content:
        log_path = os.path.join(home, '.claude/logs/destroy-guard.log')
        write_log(log_path, f"ACK docs-destroy allowed: {tool} {file_path} net_deleted={net_deleted}")
        return False, ""

    # Block
    log_path = os.path.join(home, '.claude/logs/destroy-guard.log')
    write_log(log_path, f"BLOCK docs-destroy: {tool} {file_path} net_deleted={net_deleted}")
    msg = (
        f"[CAST DESTROY GUARD] This {tool} removes {net_deleted} lines of append-only "
        f"content from {file_path}.\n"
        f"If intentional, add [docs-destroy-ok] to the new content or preserve the history.\n"
        f"Logged to: ~/.claude/logs/destroy-guard.log"
    )
    return True, msg


def check_no_fake_success(file_path, content, home, session_id):
    """Check for fake-success patterns. Returns hookSpecificOutput JSON if matched, else empty string."""
    # Skip tests, specs, fixtures
    if any(x in file_path for x in ['tests/', '.test.', '.spec.', 'fixtures/']):
        return ""
    
    # Only check specific extensions
    if not any(file_path.endswith(x) for x in ['.py', '.js', '.jsx', '.ts', '.tsx', '.mjs', '.cjs']):
        return ""
    
    # Escape hatch
    if 'fake-success-ok' in content:
        return ""
    
    # Normalize and match
    normalized = ' '.join(content.split('\n'))
    pattern = ""
    
    if file_path.endswith('.py'):
        import re
        if re.search(r'try.*(except|finally).*return.*(sample|fake|mock|placeholder|dummy)', normalized, re.IGNORECASE):
            pattern = "Python try/except → return sample/fake/mock data"
    elif any(file_path.endswith(x) for x in ['.js', '.jsx', '.ts', '.tsx', '.mjs', '.cjs']):
        import re
        if re.search(r'try.*catch.*return.*[\[\{].*(sample|fake|mock)', normalized, re.IGNORECASE):
            pattern = "JS/TS try/catch → return sample/fake/mock data"
    
    if pattern:
        return record_no_fake_success(file_path, pattern, home, session_id)
    return ""

if __name__ == '__main__':
    data = load_input()
    tool, file_path, content, old_string = extract_metadata(data)
    # Early filter: only Write/Edit (defense-in-depth; harness matcher also gates)
    if tool not in ('Write', 'Edit'):
        sys.exit(0)
    home = os.path.expanduser('~')
    session_id = os.environ.get('CAST_SESSION_ID', 'unknown')

    # BLOCK 1 — tilde-write (blocking)
    block1, msg1 = check_tilde_write(file_path, home)
    if block1:
        sys.stderr.write(msg1 + "\n")
        sys.exit(2)

    # BLOCK 2 — stat-claim (blocking)
    block2, msg2 = check_stat_claim(file_path, content, home)
    if block2:
        sys.stderr.write(msg2 + "\n")
        sys.exit(2)

    # BLOCK 2.5 — destructive-docs guard (blocking)
    block25, msg25 = check_destructive_docs_edit(tool, file_path, content, old_string, home)
    if block25:
        sys.stderr.write(msg25 + "\n")
        sys.exit(2)

    # BLOCK 3 — no-fake-success (advisory; never blocks)
    guard3 = check_no_fake_success(file_path, content, home, session_id)
    if guard3:
        sys.stdout.write(guard3 + "\n")
    sys.exit(0)
