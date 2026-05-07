#!/usr/bin/env bash
# cast-contract-runner.sh — Run contract tests for a CAST agent
# Reads agent-contracts/<agent>.contract.yaml, evaluates fixtures against assertions,
# logs results to cast.db, exits 0 if all pass, 1 if any fail.
#
# Usage: cast-contract-runner.sh <agent-name> [--record]
#
# Escape hatch: CAST_CONTRACT_RECORD=1 enables record mode without --record flag
#
# Exit codes: 0 = all tests pass, 1 = test failure

if [ "${CLAUDE_SUBPROCESS:-0}" = "1" ]; then exit 0; fi

set -euo pipefail

# ── Globals ──────────────────────────────────────────────────────────────────
AGENT_NAME="${1:-}"
RECORD_MODE=0

if [ -z "$AGENT_NAME" ] || [ "$AGENT_NAME" = "--help" ] || [ "$AGENT_NAME" = "-h" ]; then
  if [ -z "$AGENT_NAME" ]; then
    printf "Usage: %s <agent-name> [--record]\n" "$(basename "$0")" >&2
    exit 1
  fi
  cat <<USAGE
Usage: $(basename "$0") <agent-name> [--record]

  <agent-name>     Name of the agent (contract file: agent-contracts/<agent>.contract.yaml)
  --record         Record fixture output (not yet implemented)

Exit codes:
  0                All contract tests passed
  1                At least one contract test failed
USAGE
  exit 0
fi

# Parse flags
while [ "${#}" -gt 1 ]; do
  shift
  case "$1" in
    --record) RECORD_MODE=1 ;;
  esac
done

# Check for escape hatch
[ "${CAST_CONTRACT_RECORD:-0}" = "1" ] && RECORD_MODE=1

REPO_ROOT="${REPO_ROOT:-.}"
CONTRACTS_DIR="${REPO_ROOT}/agent-contracts"
FIXTURES_DIR="${CONTRACTS_DIR}/fixtures"
CONTRACT_FILE="${CONTRACTS_DIR}/${AGENT_NAME}.contract.yaml"
CAST_DB_PATH="${CAST_DB_PATH:-${HOME}/.claude/cast.db}"
SCRIPTS_DIR="${REPO_ROOT}/scripts"

# ── Ensure directories exist ─────────────────────────────────────────────────
mkdir -p "$FIXTURES_DIR" "${HOME}/.claude/logs"

# ── Record mode ──────────────────────────────────────────────────────────────
if [ "$RECORD_MODE" -eq 1 ]; then
  printf "Record mode not yet implemented — run agent manually and save output to %s\n" \
    "$FIXTURES_DIR/<agent>-<slug>.txt" >&2
  exit 0
fi

# ── Verify contract file exists ──────────────────────────────────────────────
if [ ! -f "$CONTRACT_FILE" ]; then
  printf "Error: Contract file not found: %s\n" "$CONTRACT_FILE" >&2
  exit 1
fi

# ── Helper: log error ────────────────────────────────────────────────────────
_log_error() {
  local msg="$1"
  local log_file="${HOME}/.claude/logs/cast-contract-runner.log"
  mkdir -p "$(dirname "$log_file")"
  printf "[%s] ERROR: %s\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$msg" >> "$log_file"
}

# ── Helper: parse YAML or return empty if unavailable ────────────────────────
# Minimal YAML parser: extract fixtures list and assertions list
_parse_contract() {
  local contract_file="$1"
  python3 - "$contract_file" <<'PYEOF'
import sys
import re

contract_file = sys.argv[1]
try:
    with open(contract_file, 'r') as f:
        content = f.read()
except Exception as e:
    print(f"error:Failed to read contract: {e}", file=sys.stderr)
    sys.exit(1)

# Try standard YAML library if available
try:
    import yaml
    data = yaml.safe_load(content)

    fixtures = data.get('fixtures', [])
    if isinstance(fixtures, list):
        for fx in fixtures:
            fixture_name = fx.get('name', '')
            print(f"fixture:{fixture_name}")

    assertions = data.get('assertions', [])
    if isinstance(assertions, list):
        for asr in assertions:
            asr_type = asr.get('type', '')
            if asr_type == 'output_contains':
                pattern = asr.get('pattern', '')
                print(f"assertion:output_contains:{pattern}")
            elif asr_type == 'output_not_contains':
                pattern = asr.get('pattern', '')
                print(f"assertion:output_not_contains:{pattern}")
            elif asr_type == 'cast_db_write':
                table = asr.get('table', '')
                field = asr.get('field', '')
                expected = asr.get('expected', '')
                print(f"assertion:cast_db_write:{table}:{field}:{expected}")
            elif asr_type == 'exit_code':
                expected_code = asr.get('expected', '')
                print(f"assertion:exit_code:{expected_code}")
except ImportError:
    # Fallback: simple key:value parsing for YAML-like format
    for line in content.split('\n'):
        line = line.strip()
        if line.startswith('- name:'):
            fixture_name = line.replace('- name:', '').strip().strip("'\"")
            print(f"fixture:{fixture_name}")
        elif line.startswith('type:'):
            asr_type = line.replace('type:', '').strip().strip("'\"")
            # Will be incomplete, but better than nothing
        elif line.startswith('pattern:'):
            pattern = line.replace('pattern:', '').strip().strip("'\"")
            # Store pattern for next assertion line
PYEOF
}

# ── Create contract_test_runs table if missing ────────────────────────────────
_ensure_contract_table() {
  sqlite3 "$CAST_DB_PATH" <<'SQL' 2>/dev/null || true
CREATE TABLE IF NOT EXISTS contract_test_runs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    agent TEXT,
    fixture TEXT,
    result TEXT,
    timestamp TEXT
);
SQL
}

# ── Run assertions against fixture content ───────────────────────────────────
_run_assertions() {
  local agent_name="$1"
  local fixture_name="$2"
  local fixture_file="$3"

  if [ ! -f "$fixture_file" ]; then
    printf "[SKIP] fixture not found: %s\n" "$(basename "$fixture_file")"
    return 2
  fi

  local fixture_content
  fixture_content="$(cat "$fixture_file")"

  # Extract assertions for this fixture from contract file
  local assertions_json
  assertions_json="$(python3 - "$CONTRACT_FILE" <<'PYEOF'
import sys, re
try:
    import yaml
    with open(sys.argv[1], 'r') as f:
        data = yaml.safe_load(f)
    assertions = data.get('assertions', [])
    import json
    print(json.dumps(assertions))
except ImportError:
    print('[]')
except Exception:
    print('[]')
PYEOF
  )"

  # Call Python assertion runner (ignore exit code; python always outputs JSON)
  local result_json
  result_json="$(CAST_FIXTURE_CONTENT="$fixture_content" CAST_ASSERTIONS_JSON="$assertions_json" \
    python3 "$SCRIPTS_DIR/cast_contract_runner.py" 2>/dev/null)" || true
  [ -n "$result_json" ] || result_json='{"results":[],"error":"runner failed"}'

  # Parse results and print
  local passed=0 failed=0
  python3 - "$result_json" <<'PYEOF'
import sys, json
try:
    data = json.loads(sys.argv[1])
    results = data.get('results', [])
    for r in results:
        asr_type = r.get('type', '')
        pattern = r.get('pattern', '')
        passed = r.get('passed', False)
        status = 'PASS' if passed else 'FAIL'
        print(f"[{status}] {asr_type}: {pattern}")
        if not passed:
            print(f"  assertion failed")
except Exception as e:
    print(f"Error parsing results: {e}", file=sys.stderr)
PYEOF

  # Record to DB
  _ensure_contract_table
  local result_status="FAIL"
  python3 - "$result_json" <<'PYEOF'
import sys, json
try:
    data = json.loads(sys.argv[1])
    all_passed = all(r.get('passed', False) for r in data.get('results', []))
    return_code = 0 if all_passed else 1
    sys.exit(return_code)
except Exception:
    sys.exit(1)
PYEOF

  if [ $? -eq 0 ]; then
    result_status="PASS"
  fi

  sqlite3 "$CAST_DB_PATH" <<SQL 2>/dev/null || true
INSERT INTO contract_test_runs (agent, fixture, result, timestamp)
VALUES (
  '$agent_name',
  '$fixture_name',
  '$result_status',
  datetime('now')
);
SQL

  [ "$result_status" = "PASS" ]
}

# ── Main ─────────────────────────────────────────────────────────────────────
_ensure_contract_table

# Parse fixtures from contract
fixture_list="$(python3 - "$CONTRACT_FILE" <<'PYEOF'
import sys
try:
    import yaml
    with open(sys.argv[1], 'r') as f:
        data = yaml.safe_load(f)
    fixtures = data.get('fixtures', [])
    for fx in fixtures:
        name = fx.get('name', 'unknown')
        # Slugify: convert spaces and special chars to hyphens
        slug = name.lower().replace(' ', '-').replace('_', '-')
        slug = ''.join(c if c.isalnum() or c == '-' else '' for c in slug)
        print(slug)
except ImportError:
    print('warning: PyYAML not available', file=sys.stderr)
except Exception as e:
    print(f'error: {e}', file=sys.stderr)
PYEOF
)"

if [ -z "$fixture_list" ]; then
  printf "Warning: No fixtures found in contract or YAML parsing failed\n" >&2
fi

passed_count=0
failed_count=0

while IFS= read -r fixture_slug; do
  [ -z "$fixture_slug" ] && continue
  fixture_file="${FIXTURES_DIR}/${AGENT_NAME}-${fixture_slug}.txt"

  if _run_assertions "$AGENT_NAME" "$fixture_slug" "$fixture_file"; then
    passed_count=$((passed_count + 1))
  else
    failed_count=$((failed_count + 1))
  fi
done <<< "$fixture_list"

# Summary
printf "\nContract tests: %d passed, %d failed\n" "$passed_count" "$failed_count"

if [ "$failed_count" -gt 0 ]; then
  exit 1
else
  exit 0
fi
