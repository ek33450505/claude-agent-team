#!/bin/bash
# cast-validate.sh — CAST system integrity checker v1.8.0
# Checks: hook wiring, agent frontmatter, routing table schema,
#         CLAUDE.md directives, CAST directory structure, cast-events.sh installed,
#         cast-route-install.sh present, cast-session-end.sh wiring, routing-proposals.json schema.
# Exit codes: 0=all green, 1=warnings only, 2=one or more errors

set -euo pipefail

VERSION="1.9.0"
ERRORS=0
WARNINGS=0

# --- Output helpers ---
pass()  { echo "✓ $*"; }
fail()  { echo "✗ $*"; ERRORS=$((ERRORS + 1)); }
warn()  { echo "⚠ $*"; WARNINGS=$((WARNINGS + 1)); }

echo "CAST Validate v${VERSION} (11 checks)"
echo "══════════════════════════════"

# --- Check 1: Hook wiring ---
SETTINGS="$HOME/.claude/settings.local.json"
if [[ ! -f "$SETTINGS" ]]; then
  fail "Hook wiring: $SETTINGS not found"
else
  WIRING=$(python3 - "$SETTINGS" <<'PYEOF'
import sys, json

path = sys.argv[1]
try:
    with open(path) as f:
        d = json.load(f)
except Exception as e:
    print(f"ERROR:{e}")
    sys.exit(0)

hooks = d.get("hooks", {})
commands = []
for event_hooks in hooks.values():
    for entry in event_hooks:
        for h in entry.get("hooks", []):
            cmd = h.get("command", "") + h.get("prompt", "")
            commands.append(cmd)

all_commands = " ".join(commands)
missing = []
for script in ["pre-tool-guard.sh", "post-tool-hook.sh"]:
    if script not in all_commands:
        missing.append(script)

if missing:
    print("MISSING:" + ",".join(missing))
else:
    print("OK")
PYEOF
)
  if [[ "$WIRING" == OK ]]; then
    pass "Hook wiring: pre-tool-guard.sh, post-tool-hook.sh wired"
  elif [[ "$WIRING" == MISSING:* ]]; then
    MISSING_SCRIPTS="${WIRING#MISSING:}"
    fail "Hook wiring: missing scripts not wired — ${MISSING_SCRIPTS}"
  else
    fail "Hook wiring: could not parse settings — ${WIRING#ERROR:}"
  fi
fi

# --- Check 2: Agent frontmatter ---
AGENTS_DIR="$HOME/.claude/agents"
if [[ ! -d "$AGENTS_DIR" ]]; then
  fail "Agent frontmatter: agents directory not found ($AGENTS_DIR)"
else
  FRONTMATTER_RESULT=$(python3 - "$AGENTS_DIR" <<'PYEOF'
import sys, os

agents_dir = sys.argv[1]
required_fields = ["name:", "description:", "tools:", "model:"]
bad = []
total = 0

for fname in sorted(os.listdir(agents_dir)):
    if not fname.endswith(".md"):
        continue
    total += 1
    fpath = os.path.join(agents_dir, fname)
    try:
        with open(fpath) as f:
            lines = [f.readline() for _ in range(20)]
        head = "".join(lines)
        missing = [field for field in required_fields if field not in head]
        if missing:
            bad.append(f"{fname}(missing: {', '.join(missing)})")
    except Exception as e:
        bad.append(f"{fname}(read error: {e})")

if bad:
    print(f"BAD:{total}:" + "|".join(bad))
else:
    print(f"OK:{total}")
PYEOF
)
  if [[ "$FRONTMATTER_RESULT" == OK:* ]]; then
    COUNT="${FRONTMATTER_RESULT#OK:}"
    pass "Agent frontmatter: ${COUNT} agents — all valid"
  elif [[ "$FRONTMATTER_RESULT" == BAD:* ]]; then
    REST="${FRONTMATTER_RESULT#BAD:}"
    COUNT="${REST%%:*}"
    DETAILS="${REST#*:}"
    fail "Agent frontmatter: ${COUNT} agents — invalid frontmatter detected"
    # Print each bad agent on its own line for clarity
    IFS='|' read -ra BAD_AGENTS <<< "$DETAILS"
    for agent in "${BAD_AGENTS[@]}"; do
      echo "  ✗ ${agent}"
    done
  else
    fail "Agent frontmatter: unexpected result — ${FRONTMATTER_RESULT}"
  fi
fi

# --- Check 3: Routing table schema ---
ROUTING_TABLE="$HOME/.claude/config/routing-table.json"
if [[ ! -f "$ROUTING_TABLE" ]]; then
  fail "Routing table: $ROUTING_TABLE not found"
else
  ROUTING_RESULT=$(python3 - "$ROUTING_TABLE" <<'PYEOF'
import sys, json

path = sys.argv[1]
try:
    with open(path) as f:
        data = json.load(f)
except Exception as e:
    print(f"ERROR:{e}")
    sys.exit(0)

routes = data if isinstance(data, list) else data.get("routes", [])
schema_errors = []
long_patterns = []

for i, route in enumerate(routes):
    label = route.get("agent", f"route[{i}]")
    if not isinstance(route.get("patterns"), list):
        schema_errors.append(f"{label}: 'patterns' missing or not array")
    else:
        for p in route["patterns"]:
            if isinstance(p, str) and len(p) > 200:
                long_patterns.append(f"{label}: pattern length {len(p)}")
    if not isinstance(route.get("agent"), str):
        schema_errors.append(f"{label}: 'agent' missing or not string")
    if not isinstance(route.get("model"), str):
        schema_errors.append(f"{label}: 'model' missing or not string")
    conf = route.get("confidence")
    if conf not in ("hard", "soft"):
        schema_errors.append(f"{label}: 'confidence' must be 'hard' or 'soft', got {conf!r}")

parts = []
if schema_errors:
    parts.append("ERRORS:" + "|".join(schema_errors))
if long_patterns:
    parts.append("WARN:" + "|".join(long_patterns))
if not parts:
    parts.append(f"OK:{len(routes)}")

print(";".join(parts))
PYEOF
)
  # Parse routing result — may contain ERRORS, WARN, or OK segments separated by ;
  ROUTING_ERRORS=""
  ROUTING_WARNS=""
  ROUTING_OK=""
  IFS=';' read -ra RT_PARTS <<< "$ROUTING_RESULT"
  for part in "${RT_PARTS[@]}"; do
    if [[ "$part" == ERROR:* ]]; then
      fail "Routing table: could not parse — ${part#ERROR:}"
    elif [[ "$part" == ERRORS:* ]]; then
      ROUTING_ERRORS="${part#ERRORS:}"
    elif [[ "$part" == WARN:* ]]; then
      ROUTING_WARNS="${part#WARN:}"
    elif [[ "$part" == OK:* ]]; then
      ROUTING_OK="${part#OK:}"
    fi
  done

  if [[ -n "$ROUTING_ERRORS" ]]; then
    fail "Routing table: schema violations detected"
    IFS='|' read -ra ERR_LIST <<< "$ROUTING_ERRORS"
    for e in "${ERR_LIST[@]}"; do
      echo "  ✗ ${e}"
    done
  fi
  if [[ -n "$ROUTING_WARNS" ]]; then
    IFS='|' read -ra WARN_LIST <<< "$ROUTING_WARNS"
    warn "Routing table: ${#WARN_LIST[@]} pattern(s) >200 chars (warning)"
    for w in "${WARN_LIST[@]}"; do
      echo "  ⚠ ${w}"
    done
  fi
  if [[ -z "$ROUTING_ERRORS" && -z "$ROUTING_WARNS" && -n "$ROUTING_OK" ]]; then
    pass "Routing table: ${ROUTING_OK} routes — schema valid"
  elif [[ -z "$ROUTING_ERRORS" && -n "$ROUTING_OK" ]]; then
    pass "Routing table: ${ROUTING_OK} routes — schema valid"
  fi
fi

# --- Check 4: CLAUDE.md directives ---
CLAUDE_MD="$HOME/.claude/CLAUDE.md"
if [[ ! -f "$CLAUDE_MD" ]]; then
  fail "CLAUDE.md directives: $CLAUDE_MD not found"
else
  DIRECTIVES_RESULT=$(python3 - "$CLAUDE_MD" <<'PYEOF'
import sys

path = sys.argv[1]
required = ["[CAST-DISPATCH]", "[CAST-REVIEW]", "[CAST-CHAIN]", "[CAST-DISPATCH-GROUP"]
try:
    with open(path) as f:
        content = f.read()
except Exception as e:
    print(f"ERROR:{e}")
    sys.exit(0)

missing = [d for d in required if d not in content]
if missing:
    print("MISSING:" + ",".join(missing))
else:
    print("OK")
PYEOF
)
  if [[ "$DIRECTIVES_RESULT" == OK ]]; then
    pass "CLAUDE.md directives: [CAST-DISPATCH] [CAST-REVIEW] [CAST-CHAIN] [CAST-DISPATCH-GROUP] present"
  elif [[ "$DIRECTIVES_RESULT" == MISSING:* ]]; then
    MISSING_DIRS="${DIRECTIVES_RESULT#MISSING:}"
    fail "CLAUDE.md directives: missing — ${MISSING_DIRS}"
  else
    fail "CLAUDE.md directives: could not parse — ${DIRECTIVES_RESULT#ERROR:}"
  fi
fi

# --- Check 5: CAST directory structure ---
CAST_DIRS=(
  "$HOME/.claude/cast/events"
  "$HOME/.claude/cast/state"
  "$HOME/.claude/cast/reviews"
  "$HOME/.claude/cast/artifacts"
  "$HOME/.claude/agent-status"
)
CAST_DIR_NAMES=("events/" "state/" "reviews/" "artifacts/" "agent-status/")
CAST_MISSING=()
for i in "${!CAST_DIRS[@]}"; do
  if [[ ! -d "${CAST_DIRS[$i]}" ]]; then
    CAST_MISSING+=("${CAST_DIRS[$i]}")
  fi
done
if [[ ${#CAST_MISSING[@]} -eq 0 ]]; then
  pass "CAST dirs: events/ state/ reviews/ artifacts/ agent-status/ all present"
else
  for missing_dir in "${CAST_MISSING[@]}"; do
    # agent-status is required for Status Block Protocol — error, not warning
    if [[ "$missing_dir" == *"agent-status" ]]; then
      fail "CAST dirs: ${missing_dir} missing (required for Status Block Protocol — run install.sh)"
    else
      warn "CAST dirs: ${missing_dir} missing (run install.sh to create)"
    fi
  done
fi

# --- Check 6: cast-events.sh installed ---
CAST_EVENTS_SCRIPT="$HOME/.claude/scripts/cast-events.sh"
if [[ -f "$CAST_EVENTS_SCRIPT" ]]; then
  pass "cast-events.sh: installed at ${CAST_EVENTS_SCRIPT}"
else
  fail "cast-events.sh: ${CAST_EVENTS_SCRIPT} not found (required for event-sourcing protocol)"
fi

# --- Check 7: agent-groups.json present ---
AGENT_GROUPS="$HOME/.claude/config/agent-groups.json"
if [[ -f "$AGENT_GROUPS" ]]; then
  GROUP_COUNT=$(python3 -c "
import json, sys
try:
    data = json.load(open('$AGENT_GROUPS'))
    print(len(data.get('groups', [])))
except Exception:
    print(0)
" 2>/dev/null || echo 0)
  if [[ "$GROUP_COUNT" -gt 0 ]]; then
    pass "agent-groups.json: ${GROUP_COUNT} groups — present and valid"
  else
    warn "agent-groups.json: present but 0 groups parsed (may be malformed)"
  fi
else
  warn "agent-groups.json: ${AGENT_GROUPS} not found (parallel agent groups disabled)"
fi

# --- Check 8: cast-route-install.sh present and executable ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROUTE_INSTALL_REPO="${SCRIPT_DIR}/cast-route-install.sh"
ROUTE_INSTALL_HOME="$HOME/.claude/scripts/cast-route-install.sh"
if [[ -f "$ROUTE_INSTALL_REPO" && -x "$ROUTE_INSTALL_REPO" ]]; then
  pass "cast-route-install.sh: present and executable (repo copy)"
elif [[ -f "$ROUTE_INSTALL_HOME" && -x "$ROUTE_INSTALL_HOME" ]]; then
  pass "cast-route-install.sh: present and executable (home copy)"
elif [[ -f "$ROUTE_INSTALL_REPO" || -f "$ROUTE_INSTALL_HOME" ]]; then
  warn "cast-route-install.sh: found but not executable (run chmod +x)"
else
  fail "cast-route-install.sh: not found (routing proposal install pipeline unavailable)"
fi

# --- Check 9: cast-session-end.sh wired in settings.local.json ---
if [[ -f "$SETTINGS" ]]; then
  STOP_WIRED=$(python3 - "$SETTINGS" <<'PYEOF'
import sys, json
path = sys.argv[1]
try:
    with open(path) as f:
        d = json.load(f)
except Exception:
    print("UNKNOWN")
    sys.exit(0)
hooks = d.get("hooks", {})
all_cmds = " ".join(
    h.get("command", "") + h.get("prompt", "")
    for event_hooks in hooks.values()
    for entry in event_hooks
    for h in entry.get("hooks", [])
)
print("OK" if "cast-session-end.sh" in all_cmds else "MISSING")
PYEOF
)
  if [[ "$STOP_WIRED" == "OK" ]]; then
    pass "cast-session-end.sh: wired in settings.local.json"
  elif [[ "$STOP_WIRED" == "MISSING" ]]; then
    warn "cast-session-end.sh: not wired (chain-reporter auto-dispatch on session end unavailable)"
  else
    warn "cast-session-end.sh: could not verify wiring"
  fi
fi

# --- Check 10: routing-proposals.json schema (if present) ---
PROPOSALS_FILE="$HOME/.claude/routing-proposals.json"
if [[ -f "$PROPOSALS_FILE" ]]; then
  PROPOSALS_RESULT=$(python3 - "$PROPOSALS_FILE" <<'PYEOF'
import sys, json
path = sys.argv[1]
try:
    with open(path) as f:
        data = json.load(f)
except Exception as e:
    print(f"ERROR:{e}")
    sys.exit(0)
if not isinstance(data.get("generated"), str):
    print("ERROR:missing 'generated' field")
    sys.exit(0)
proposals = data.get("proposals", [])
if not isinstance(proposals, list):
    print("ERROR:'proposals' must be an array")
    sys.exit(0)
valid_statuses = {"pending", "installed", "rejected"}
bad = []
for p in proposals:
    pid = p.get("id", "(unknown)")
    if not isinstance(p.get("id"), str):
        bad.append(f"{pid}: missing 'id'")
    if not isinstance(p.get("patterns"), list):
        bad.append(f"{pid}: 'patterns' must be array")
    if not isinstance(p.get("agent"), str):
        bad.append(f"{pid}: missing 'agent'")
    if p.get("status") not in valid_statuses:
        bad.append(f"{pid}: invalid status '{p.get('status')}'")
if bad:
    print("BAD:" + "|".join(bad))
else:
    pending = sum(1 for p in proposals if p.get("status") == "pending")
    print(f"OK:{len(proposals)}:{pending}")
PYEOF
)
  if [[ "$PROPOSALS_RESULT" == OK:* ]]; then
    REST="${PROPOSALS_RESULT#OK:}"
    TOTAL="${REST%%:*}"
    PENDING="${REST#*:}"
    pass "routing-proposals.json: ${TOTAL} proposals, ${PENDING} pending — schema valid"
  elif [[ "$PROPOSALS_RESULT" == BAD:* ]]; then
    DETAILS="${PROPOSALS_RESULT#BAD:}"
    fail "routing-proposals.json: schema violations"
    IFS='|' read -ra BAD_LIST <<< "$DETAILS"
    for b in "${BAD_LIST[@]}"; do
      echo "  ✗ ${b}"
    done
  elif [[ "$PROPOSALS_RESULT" == ERROR:* ]]; then
    fail "routing-proposals.json: parse error — ${PROPOSALS_RESULT#ERROR:}"
  fi
else
  pass "routing-proposals.json: not present (proposals pipeline not yet run — OK)"
fi

# --- Check 11: security agent wired in at least one post_chain ---
if [[ -f "$ROUTING_TABLE" ]]; then
  SECURITY_WIRED=$(python3 - "$ROUTING_TABLE" <<'PYEOF'
import sys, json
path = sys.argv[1]
try:
    with open(path) as f:
        data = json.load(f)
except Exception as e:
    print(f"ERROR:{e}")
    sys.exit(0)
routes = data if isinstance(data, list) else data.get('routes', [])
def has_security(chain):
    if not chain:
        return False
    for item in chain:
        if isinstance(item, list):
            if 'security' in item:
                return True
        elif item == 'security':
            return True
    return False
wired = any(has_security(r.get('post_chain')) for r in routes)
print('OK' if wired else 'MISSING')
PYEOF
)
  if [[ "$SECURITY_WIRED" == 'OK' ]]; then
    pass "Security post_chain: security agent wired in ≥1 route (parallel or sequential)"
  elif [[ "$SECURITY_WIRED" == 'MISSING' ]]; then
    warn "Security post_chain: security agent not in any post_chain (consider wiring for auth/API routes)"
  else
    warn "Security post_chain: could not verify — ${SECURITY_WIRED#ERROR:}"
  fi
fi

# --- Summary ---
echo "══════════════════════════════"
if [[ $ERRORS -eq 0 && $WARNINGS -eq 0 ]]; then
  echo "0 errors, 0 warnings"
  exit 0
elif [[ $ERRORS -eq 0 ]]; then
  echo "0 errors, ${WARNINGS} warning$([ $WARNINGS -ne 1 ] && echo 's' || true)"
  exit 1
else
  echo "${ERRORS} error$([ $ERRORS -ne 1 ] && echo 's' || true), ${WARNINGS} warning$([ $WARNINGS -ne 1 ] && echo 's' || true)"
  exit 2
fi
