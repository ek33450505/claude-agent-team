#!/usr/bin/env bats

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

# ---------------------------------------------------------------------------
# Task 6A: agent-groups.json schema validation
# ---------------------------------------------------------------------------

@test "agent-groups.json: file exists at config/agent-groups.json" {
  [ -f "$REPO_DIR/config/agent-groups.json" ]
}

@test "agent-groups.json: valid JSON (parses without error)" {
  run python3 -c "import json; json.load(open('$REPO_DIR/config/agent-groups.json')); print('ok')"
  assert_success
  assert_output "ok"
}

@test "agent-groups.json: has 'version' key at root" {
  run python3 -c "
import json
data = json.load(open('$REPO_DIR/config/agent-groups.json'))
assert 'version' in data, 'missing version key'
print(data['version'])
"
  assert_success
}

@test "agent-groups.json: has 'groups' array at root" {
  run python3 -c "
import json
data = json.load(open('$REPO_DIR/config/agent-groups.json'))
assert 'groups' in data, 'missing groups key'
assert isinstance(data['groups'], list), 'groups is not an array'
print('ok')
"
  assert_success
  assert_output "ok"
}

@test "agent-groups.json: group count is 31" {
  run python3 -c "
import json
data = json.load(open('$REPO_DIR/config/agent-groups.json'))
print(len(data['groups']))
"
  assert_success
  assert_output "31"
}

@test "agent-groups.json: every group has required fields (id, description, patterns, confidence, waves)" {
  run python3 -c "
import json, sys
data = json.load(open('$REPO_DIR/config/agent-groups.json'))
required = {'id', 'description', 'patterns', 'confidence', 'waves'}
for g in data['groups']:
    missing = required - set(g.keys())
    if missing:
        print(f'Group {g.get(\"id\", \"?\")} missing: {missing}', file=sys.stderr)
        sys.exit(1)
print('ok')
"
  assert_success
  assert_output "ok"
}

@test "agent-groups.json: no group has more than 4 agents in any wave" {
  run python3 -c "
import json, sys
data = json.load(open('$REPO_DIR/config/agent-groups.json'))
for g in data['groups']:
    for w in g.get('waves', []):
        agents = w.get('agents', [])
        if len(agents) > 4:
            print(f'Group {g[\"id\"]} wave {w[\"id\"]} has {len(agents)} agents (>4)', file=sys.stderr)
            sys.exit(1)
print('ok')
"
  assert_success
  assert_output "ok"
}

@test "agent-groups.json: all confidence values are 'hard' or 'soft'" {
  run python3 -c "
import json, sys
data = json.load(open('$REPO_DIR/config/agent-groups.json'))
valid = {'hard', 'soft'}
for g in data['groups']:
    conf = g.get('confidence', '')
    if conf not in valid:
        print(f'Group {g[\"id\"]} has invalid confidence: {conf!r}', file=sys.stderr)
        sys.exit(1)
print('ok')
"
  assert_success
  assert_output "ok"
}

@test "agent-groups.json: all wave parallel fields are boolean" {
  run python3 -c "
import json, sys
data = json.load(open('$REPO_DIR/config/agent-groups.json'))
for g in data['groups']:
    for w in g.get('waves', []):
        parallel = w.get('parallel')
        if not isinstance(parallel, bool):
            print(f'Group {g[\"id\"]} wave {w[\"id\"]} parallel is {type(parallel).__name__!r}, not bool', file=sys.stderr)
            sys.exit(1)
print('ok')
"
  assert_success
  assert_output "ok"
}

@test "agent-groups.json: no pattern string exceeds 200 characters (ReDoS guard)" {
  run python3 -c "
import json, sys
data = json.load(open('$REPO_DIR/config/agent-groups.json'))
for g in data['groups']:
    for p in g.get('patterns', []):
        if len(p) > 200:
            print(f'Group {g[\"id\"]} pattern too long ({len(p)} chars): {p[:50]}...', file=sys.stderr)
            sys.exit(1)
print('ok')
"
  assert_success
  assert_output "ok"
}
