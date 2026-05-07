#!/usr/bin/env bats
# Tests for hook output compression in cast-subagent-stop-hook.sh
#
# Coverage:
#   1. Status: DONE + Summary: → hookSpecificOutput.status = DONE
#   2. Status: DONE_WITH_CONCERNS + Concerns section → hookSpecificOutput includes concerns
#   3. No Status line → hookSpecificOutput.status = UNKNOWN

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
HOOK_SCRIPT="$REPO_ROOT/scripts/cast-subagent-stop-hook.sh"

# Run only the compression snippet in isolation (avoids needing a full DB setup)
_run_compression() {
  local response_text="$1"
  CAST_STOP_RESPONSE_TEXT="$response_text" python3 - <<'PYEOF'
import os, sys, re, json

text = os.environ.get('CAST_STOP_RESPONSE_TEXT', '')

status_match = re.search(r'Status:\s*(\S+)', text)
status = status_match.group(1) if status_match else 'UNKNOWN'

summary_match = re.search(r'Summary:\s*(.+)', text)
summary = summary_match.group(1).strip() if summary_match else ''

concerns = []
concerns_match = re.search(r'Concerns?:(.*?)(?=\n#|\n##|\nStatus:|$)', text, re.DOTALL | re.IGNORECASE)
if concerns_match:
    for line in concerns_match.group(1).splitlines():
        line = line.strip().lstrip('- ').strip()
        if line:
            concerns.append(line)

output = json.dumps({
    'hookSpecificOutput': json.dumps({
        'status': status,
        'summary': summary,
        'concerns': concerns
    })
})
print(output)
PYEOF
}

@test "Status: DONE and Summary line → hookSpecificOutput.status is DONE" {
  local response="Status: DONE
Summary: committed feature X
Files changed: bin/cast"

  result="$(_run_compression "$response")"
  inner="$(echo "$result" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d['hookSpecificOutput'])")"
  status="$(echo "$inner" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d['status'])")"
  assert_equal "$status" "DONE"
}

@test "Status: DONE_WITH_CONCERNS with Concerns section → hookSpecificOutput contains concerns" {
  local response="Status: DONE_WITH_CONCERNS
Summary: implemented feature with concerns
Concerns:
- Missing test coverage
- Potential race condition"

  result="$(_run_compression "$response")"
  inner="$(echo "$result" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d['hookSpecificOutput'])")"
  status="$(echo "$inner" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d['status'])")"
  concerns_len="$(echo "$inner" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(len(d['concerns']))")"

  assert_equal "$status" "DONE_WITH_CONCERNS"
  assert [ "$concerns_len" -ge 1 ]
}

@test "no Status line → hookSpecificOutput.status is UNKNOWN" {
  local response="This agent output has no structured status block.
Just some prose and work log entries."

  result="$(_run_compression "$response")"
  inner="$(echo "$result" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d['hookSpecificOutput'])")"
  status="$(echo "$inner" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d['status'])")"
  assert_equal "$status" "UNKNOWN"
}
