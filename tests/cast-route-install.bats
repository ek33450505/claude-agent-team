#!/usr/bin/env bats

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
INSTALL_SH="$REPO_DIR/scripts/cast-route-install.sh"

# ---------------------------------------------------------------------------
# Setup / Teardown
# ---------------------------------------------------------------------------

setup() {
  export ORIG_HOME="$HOME"
  export HOME="$(mktemp -d)"
  mkdir -p "$HOME/.claude/config"
  mkdir -p "$HOME/.claude/scripts"

  # Minimal routing table with a catch-all (pattern-less router at end)
  cat > "$HOME/.claude/config/routing-table.json" <<'EOF'
{
  "routes": [
    {
      "patterns": ["^/plan\\b", "plan.*implement"],
      "agent": "planner",
      "model": "sonnet",
      "post_chain": []
    },
    {
      "agent": "router",
      "model": "haiku",
      "post_chain": []
    }
  ]
}
EOF

  # Minimal proposals file with two pending proposals
  cat > "$HOME/.claude/routing-proposals.json" <<'EOF'
{
  "generated": "2026-03-25T00:00:00Z",
  "proposals": [
    {
      "id": "auto-analyze",
      "patterns": ["\\banalyze\\b"],
      "agent": "data-scientist",
      "model": "sonnet",
      "confidence": "soft",
      "frequency": 12,
      "example_prompts": ["analyze this dataset", "analyze the logs"],
      "status": "pending"
    },
    {
      "id": "auto-convert",
      "patterns": ["\\bconvert\\b"],
      "agent": "code-writer",
      "model": "sonnet",
      "confidence": "soft",
      "frequency": 5,
      "example_prompts": ["convert this file"],
      "status": "pending"
    },
    {
      "id": "auto-already-installed",
      "patterns": ["\\binstalled\\b"],
      "agent": "router",
      "model": "haiku",
      "confidence": "soft",
      "frequency": 3,
      "example_prompts": ["installed thing"],
      "status": "installed"
    }
  ]
}
EOF
}

teardown() {
  export HOME="$ORIG_HOME"
}

# ---------------------------------------------------------------------------
# --pending-count
# ---------------------------------------------------------------------------

@test "--pending-count returns 0 when proposals file is missing" {
  rm -f "$HOME/.claude/routing-proposals.json"
  run bash "$INSTALL_SH" --pending-count
  assert_success
  assert_output "0"
}

@test "--pending-count returns correct count from proposals file" {
  run bash "$INSTALL_SH" --pending-count
  assert_success
  assert_output "2"
}

# ---------------------------------------------------------------------------
# --list
# ---------------------------------------------------------------------------

@test "--list returns valid JSON with pending proposals" {
  run bash "$INSTALL_SH" --list
  assert_success
  # Output should be valid JSON with a proposals array
  echo "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); assert isinstance(d['proposals'], list)" 2>/dev/null
  assert [ $? -eq 0 ]
}

@test "--list returns only pending proposals" {
  run bash "$INSTALL_SH" --list
  assert_success
  # Should not include installed proposal
  run bash -c "echo '$output' | python3 -c \"import json,sys; d=json.load(sys.stdin); ids=[p['id'] for p in d['proposals']]; assert 'auto-already-installed' not in ids, f'installed id found: {ids}'\""
  assert_success
}

@test "--list returns empty proposals array when file is missing" {
  rm -f "$HOME/.claude/routing-proposals.json"
  run bash "$INSTALL_SH" --list
  assert_success
  assert_output '{"proposals":[]}'
}

# ---------------------------------------------------------------------------
# --approve validation
# ---------------------------------------------------------------------------

@test "--approve rejects invalid regex pattern (exits 1)" {
  # Inject a proposal with a broken regex
  python3 -c "
import json
with open('$HOME/.claude/routing-proposals.json') as f:
    d = json.load(f)
d['proposals'].append({
    'id': 'auto-badregex',
    'patterns': ['[unclosed'],
    'agent': 'router',
    'model': 'haiku',
    'confidence': 'soft',
    'frequency': 1,
    'example_prompts': ['bad'],
    'status': 'pending',
})
with open('$HOME/.claude/routing-proposals.json', 'w') as f:
    json.dump(d, f)
"
  run bash "$INSTALL_SH" --approve auto-badregex
  assert_failure
}

@test "--approve rejects pattern longer than 200 chars (exits 1)" {
  LONG_PATTERN="$(python3 -c "print('x' * 201)")"
  python3 -c "
import json
with open('$HOME/.claude/routing-proposals.json') as f:
    d = json.load(f)
d['proposals'].append({
    'id': 'auto-longpat',
    'patterns': ['$LONG_PATTERN'],
    'agent': 'router',
    'model': 'haiku',
    'confidence': 'soft',
    'frequency': 1,
    'example_prompts': ['long'],
    'status': 'pending',
})
with open('$HOME/.claude/routing-proposals.json', 'w') as f:
    json.dump(d, f)
"
  run bash "$INSTALL_SH" --approve auto-longpat
  assert_failure
}

# ---------------------------------------------------------------------------
# --approve success path
# ---------------------------------------------------------------------------

@test "--approve creates a .bak of routing-table.json" {
  run bash "$INSTALL_SH" --approve auto-analyze
  assert_success
  assert [ -f "$HOME/.claude/config/routing-table.json.bak" ]
}

@test "--approve inserts route before the catch-all router entry" {
  run bash "$INSTALL_SH" --approve auto-analyze
  assert_success
  python3 -c "
import json, sys
with open('$HOME/.claude/config/routing-table.json') as f:
    d = json.load(f)
routes = d['routes']
# Find the new route and the router catch-all
analyze_idx = next((i for i,r in enumerate(routes) if r.get('agent') == 'data-scientist'), None)
router_idx  = next((i for i,r in enumerate(routes) if r.get('agent') == 'router' and not r.get('patterns')), None)
assert analyze_idx is not None, 'data-scientist route not found'
assert router_idx is not None,  'router catch-all not found'
assert analyze_idx < router_idx, f'new route ({analyze_idx}) not before catch-all ({router_idx})'
"
  assert [ $? -eq 0 ]
}

@test "--approve updates proposal status to 'installed'" {
  run bash "$INSTALL_SH" --approve auto-analyze
  assert_success
  python3 -c "
import json
with open('$HOME/.claude/routing-proposals.json') as f:
    d = json.load(f)
p = next(x for x in d['proposals'] if x['id'] == 'auto-analyze')
assert p['status'] == 'installed', f\"expected installed, got {p['status']}\"
"
  assert [ $? -eq 0 ]
}

@test "--approve updates routing-table.json with new route" {
  run bash "$INSTALL_SH" --approve auto-convert
  assert_success
  python3 -c "
import json
with open('$HOME/.claude/config/routing-table.json') as f:
    d = json.load(f)
agents = [r.get('agent') for r in d['routes']]
assert 'code-writer' in agents, f'code-writer not found in routes: {agents}'
"
  assert [ $? -eq 0 ]
}

# ---------------------------------------------------------------------------
# --approve idempotency
# ---------------------------------------------------------------------------

@test "--approve of already-installed ID is a no-op (exit 0)" {
  run bash "$INSTALL_SH" --approve auto-already-installed
  assert_success
  # routing table should not have a duplicate
  python3 -c "
import json
with open('$HOME/.claude/config/routing-table.json') as f:
    d = json.load(f)
# Count routes whose patterns contain \\binstalled\\b
count = sum(1 for r in d['routes'] if r.get('patterns') and any('installed' in p for p in r.get('patterns',[])))
assert count == 0, f'unexpected installed route found: {count}'
"
  assert [ $? -eq 0 ]
}

# ---------------------------------------------------------------------------
# --reject
# ---------------------------------------------------------------------------

@test "--reject updates status to 'rejected' without modifying routing-table.json" {
  # Record routing table checksum before
  BEFORE="$(python3 -c "import json; d=json.load(open('$HOME/.claude/config/routing-table.json')); print(json.dumps(d, sort_keys=True))")"

  run bash "$INSTALL_SH" --reject auto-convert
  assert_success

  # Status should be rejected
  python3 -c "
import json
with open('$HOME/.claude/routing-proposals.json') as f:
    d = json.load(f)
p = next(x for x in d['proposals'] if x['id'] == 'auto-convert')
assert p['status'] == 'rejected', f\"expected rejected, got {p['status']}\"
"
  assert [ $? -eq 0 ]

  # Routing table should be unchanged
  AFTER="$(python3 -c "import json; d=json.load(open('$HOME/.claude/config/routing-table.json')); print(json.dumps(d, sort_keys=True))")"
  assert [ "$BEFORE" = "$AFTER" ]
}

@test "--reject of already-rejected ID is a no-op (exit 0)" {
  # First reject
  run bash "$INSTALL_SH" --reject auto-convert
  assert_success
  # Second reject should also succeed
  run bash "$INSTALL_SH" --reject auto-convert
  assert_success
}

# ---------------------------------------------------------------------------
# Exit code for file not found
# ---------------------------------------------------------------------------

@test "--approve exits 2 when proposals file is missing" {
  rm -f "$HOME/.claude/routing-proposals.json"
  run bash "$INSTALL_SH" --approve auto-analyze
  assert [ "$status" -eq 2 ]
}

@test "--reject exits 2 when proposals file is missing" {
  rm -f "$HOME/.claude/routing-proposals.json"
  run bash "$INSTALL_SH" --reject auto-analyze
  assert [ "$status" -eq 2 ]
}
