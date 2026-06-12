#!/usr/bin/env bats
# Regression tests for cast-memory-backfill-verified.sh and doctor staleness check
# Phase 4.8.3: auto-memory TTL warnings

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
BACKFILL_SCRIPT="$REPO_DIR/scripts/cast-memory-backfill-verified.sh"

# Setup a temporary projects directory with test memories
setup() {
  load 'helpers/setup'
  setup_temp_home  # sets HOME to a temp dir; exports ORIG_HOME
  # TEST_HOME is an alias for the isolated HOME used in @test body references
  TEST_HOME="$HOME"
  export TEST_HOME
  mkdir -p "$TEST_HOME/.claude/projects/proj-a/memory"

  # Memory 1: stale, with /scripts/ reference (should flag)
  cat > "$TEST_HOME/.claude/projects/proj-a/memory/foo.md" << 'EOF'
---
name: Test foo memory
description: Test memory with scripts path
type: feedback
verified_at: 2026-04-01
---

This memory talks about /scripts/foo.sh and how it works.
EOF

  # Memory 2: fresh (1 day old), with /scripts/ reference (should NOT flag)
  FRESH_DATE=$(date -u -d "1 day ago" +%Y-%m-%d 2>/dev/null || date -u -v-1d +%Y-%m-%d 2>/dev/null)
  cat > "$TEST_HOME/.claude/projects/proj-a/memory/bar.md" << EOF
---
name: Test bar memory
description: Fresh memory with scripts
type: reference
verified_at: ${FRESH_DATE}
---

This memory talks about /scripts/bar.sh.
EOF

  # Memory 3: no verified_at (should NOT flag, will be backfilled)
  cat > "$TEST_HOME/.claude/projects/proj-a/memory/baz.md" << 'EOF'
---
name: Test baz memory
description: Memory without verified_at
type: user
---

This is a trivial memory with no date.
EOF

  # Memory 4: stale but no specific paths/flags (should NOT flag)
  cat > "$TEST_HOME/.claude/projects/proj-a/memory/quux.md" << 'EOF'
---
name: Test quux memory
description: Stale but no specific references
type: project
verified_at: 2026-04-01
---

This is a generic memory that doesn't mention paths or functions.
EOF

  # Memory 5: MEMORY.md index (should be skipped by backfill)
  cat > "$TEST_HOME/.claude/projects/proj-a/memory/MEMORY.md" << 'EOF'
# Memory Index

- [foo.md](foo.md) — test memory
EOF

  export CLAUDE_SUBPROCESS=0
}

teardown() {
  teardown_temp_home
}

# ---------------------------------------------------------------------------
# Backfill tests
# ---------------------------------------------------------------------------

@test "backfill adds verified_at to files missing it" {
  run bash "$BACKFILL_SCRIPT"
  assert_success
  assert_output --partial "stamped"

  # Check that baz.md now has verified_at
  run grep "^verified_at:" "$TEST_HOME/.claude/projects/proj-a/memory/baz.md"
  assert_success
  assert_output --regexp "verified_at: [0-9]{4}-[0-9]{2}-[0-9]{2}"
}

@test "backfill is idempotent" {
  # Run once
  bash "$BACKFILL_SCRIPT" > /dev/null
  local first_baz=$(cat "$TEST_HOME/.claude/projects/proj-a/memory/baz.md")

  # Run again
  run bash "$BACKFILL_SCRIPT"
  assert_success
  assert_output --partial "stamped 0"

  # Content should be identical
  local second_baz=$(cat "$TEST_HOME/.claude/projects/proj-a/memory/baz.md")
  [[ "$first_baz" == "$second_baz" ]]
}

@test "backfill skips MEMORY.md index files" {
  local before=$(cat "$TEST_HOME/.claude/projects/proj-a/memory/MEMORY.md")
  bash "$BACKFILL_SCRIPT" > /dev/null
  local after=$(cat "$TEST_HOME/.claude/projects/proj-a/memory/MEMORY.md")

  [[ "$before" == "$after" ]]
}

@test "backfill --dry-run does not modify files" {
  local before=$(cat "$TEST_HOME/.claude/projects/proj-a/memory/baz.md")

  run bash "$BACKFILL_SCRIPT" --dry-run
  assert_success
  assert_output --partial "stamped"

  local after=$(cat "$TEST_HOME/.claude/projects/proj-a/memory/baz.md")
  [[ "$before" == "$after" ]]
}

@test "backfill --target-date sets custom date" {
  run bash "$BACKFILL_SCRIPT" --target-date 2026-05-15
  assert_success

  run grep "verified_at: 2026-05-15" "$TEST_HOME/.claude/projects/proj-a/memory/baz.md"
  assert_success
}

# ---------------------------------------------------------------------------
# Doctor staleness check tests
# ---------------------------------------------------------------------------

@test "staleness logic flags stale memories with specific paths" {
  # Run backfill first to set verified_at on all
  bash "$BACKFILL_SCRIPT" > /dev/null

  run python3 -c "
import os, re, sys
from datetime import datetime
os.environ['HOME'] = '$TEST_HOME'
projects_dir = os.path.join(os.path.expanduser('~'), '.claude', 'projects')
stale_count = 0
for proj_dir in os.listdir(projects_dir):
  memory_dir = os.path.join(projects_dir, proj_dir, 'memory')
  if not os.path.isdir(memory_dir): continue
  for fname in os.listdir(memory_dir):
    if fname == 'MEMORY.md' or not fname.endswith('.md'): continue
    fpath = os.path.join(memory_dir, fname)
    try:
      with open(fpath) as f: content = f.read()
    except: continue
    if not content.startswith('---'): continue
    parts = content.split('---')
    if len(parts) < 3: continue
    frontmatter, body = parts[1], '---'.join(parts[2:])
    verified_at = None
    for line in frontmatter.split('\n'):
      if line.startswith('verified_at:'):
        m = re.search(r'(\d{4}-\d{2}-\d{2})', line)
        if m: verified_at = m.group(1)
        break
    if not verified_at: continue
    try:
      vdate = datetime.strptime(verified_at, '%Y-%m-%d')
      age_days = (datetime.utcnow() - vdate).days
    except: continue
    if age_days <= 30: continue
    has_specific = bool(re.search(r'/scripts/', body) or re.search(r'~/.claude/', body) or re.search(r'\w+\(\)', body) or re.search(r'--\w+', body))
    if has_specific: stale_count += 1
sys.exit(0 if stale_count == 1 else 1)
"
  assert_success
}

@test "staleness logic does NOT flag fresh memories" {
  bash "$BACKFILL_SCRIPT" > /dev/null

  run python3 -c "
import os, re, sys
from datetime import datetime
os.environ['HOME'] = '$TEST_HOME'
projects_dir = os.path.join(os.path.expanduser('~'), '.claude', 'projects')
for proj_dir in os.listdir(projects_dir):
  memory_dir = os.path.join(projects_dir, proj_dir, 'memory')
  if not os.path.isdir(memory_dir): continue
  for fname in os.listdir(memory_dir):
    if fname == 'MEMORY.md' or not fname.endswith('.md'): continue
    if fname != 'bar.md': continue
    fpath = os.path.join(memory_dir, fname)
    try:
      with open(fpath) as f: content = f.read()
    except: continue
    if not content.startswith('---'): continue
    parts = content.split('---')
    if len(parts) < 3: continue
    frontmatter, body = parts[1], '---'.join(parts[2:])
    verified_at = None
    for line in frontmatter.split('\n'):
      if line.startswith('verified_at:'):
        m = re.search(r'(\d{4}-\d{2}-\d{2})', line)
        if m: verified_at = m.group(1)
        break
    if not verified_at: continue
    try:
      vdate = datetime.strptime(verified_at, '%Y-%m-%d')
      age_days = (datetime.utcnow() - vdate).days
    except: continue
    if age_days <= 30: sys.exit(0)
sys.exit(1)
"
  assert_success
}

@test "staleness logic does NOT flag stale without specific references" {
  bash "$BACKFILL_SCRIPT" > /dev/null

  run python3 -c "
import os, re, sys
from datetime import datetime
os.environ['HOME'] = '$TEST_HOME'
projects_dir = os.path.join(os.path.expanduser('~'), '.claude', 'projects')
for proj_dir in os.listdir(projects_dir):
  memory_dir = os.path.join(projects_dir, proj_dir, 'memory')
  if not os.path.isdir(memory_dir): continue
  for fname in os.listdir(memory_dir):
    if fname == 'MEMORY.md' or not fname.endswith('.md'): continue
    if fname != 'quux.md': continue
    fpath = os.path.join(memory_dir, fname)
    try:
      with open(fpath) as f: content = f.read()
    except: continue
    if not content.startswith('---'): continue
    parts = content.split('---')
    if len(parts) < 3: continue
    frontmatter, body = parts[1], '---'.join(parts[2:])
    verified_at = None
    for line in frontmatter.split('\n'):
      if line.startswith('verified_at:'):
        m = re.search(r'(\d{4}-\d{2}-\d{2})', line)
        if m: verified_at = m.group(1)
        break
    if not verified_at: continue
    try:
      vdate = datetime.strptime(verified_at, '%Y-%m-%d')
      age_days = (datetime.utcnow() - vdate).days
    except: continue
    if age_days <= 30: continue
    has_specific = bool(re.search(r'/scripts/', body) or re.search(r'~/.claude/', body) or re.search(r'\w+\(\)', body) or re.search(r'--\w+', body))
    if has_specific: sys.exit(1)
sys.exit(0)
"
  assert_success
}
