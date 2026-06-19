#!/bin/bash
# cast-validate.sh — CAST system integrity checker v2.1.0
# Checks: hook wiring, agent frontmatter, routing table schema,
#         CLAUDE.md directives, CAST directory structure, cast-events.sh installed,
#         agent-groups.json, cast-session-end.sh wiring, routing-proposals.json schema,
#         security post_chain wiring, local-first readiness.
# Exit codes: 0=all green, 1=warnings only, 2=one or more errors

set -euo pipefail

# --- Help handler ---
for arg in "$@"; do
  case "$arg" in
    --help|-h)
      cat <<'USAGE'
Usage: cast-validate.sh [--help|-h]

CAST system integrity checker v2.1.0.
Validates hook wiring, agent frontmatter, routing table schema,
CLAUDE.md directives, CAST directory structure, and local-first readiness.

Exit codes:
  0 = all checks passed
  1 = warnings only
  2 = one or more errors

Options:
  --help, -h    Show this help message and exit
USAGE
      exit 0
      ;;
  esac
done

VERSION="2.1.0"
ERRORS=0
WARNINGS=0

# --- Output helpers ---
pass()  { echo "✓ $*"; }
fail()  { echo "✗ $*"; ERRORS=$((ERRORS + 1)); }
warn()  { echo "⚠ $*"; WARNINGS=$((WARNINGS + 1)); }
info()  { echo "ℹ $*"; }  # Optional/advisory — does not increment WARNINGS

echo "CAST Validate v${VERSION} (12 checks)"
echo "══════════════════════════════"

# --- Check 1: Hook wiring ---
SETTINGS="$HOME/.claude/settings.json"
[[ ! -f "$SETTINGS" ]] && SETTINGS="$HOME/.claude/settings.local.json"
if [[ ! -f "$SETTINGS" ]]; then
  fail "Hook wiring: neither settings.json nor settings.local.json found"
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

import os
hooks = d.get("hooks", {})
commands = []
for event_hooks in hooks.values():
    for entry in event_hooks:
        for h in entry.get("hooks", []):
            cmd = h.get("command", "") + h.get("prompt", "")
            commands.append(cmd)

missing = []
for script in ["pre-tool-guard.sh", "post-tool-hook.sh"]:
    found = any(
        script in cmd or
        any(os.path.basename(tok) == script for tok in cmd.split())
        for cmd in commands if cmd.strip()
    )
    if not found:
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
    fpath = os.path.join(agents_dir, fname)
    try:
        with open(fpath) as f:
            lines = [f.readline() for _ in range(20)]
        head = "".join(lines)
        # Skip files that don't have YAML frontmatter (first non-empty line != "---")
        first_nonempty = next((line.strip() for line in lines if line.strip()), "")
        if first_nonempty != "---":
            continue
        total += 1
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

# --- Check 8: cast-session-end.sh wired in settings file ---
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
import os
hooks = d.get("hooks", {})
cmds = [
    h.get("command", "") + h.get("prompt", "")
    for event_hooks in hooks.values()
    for entry in event_hooks
    for h in entry.get("hooks", [])
]
script = "cast-session-end.sh"
found = any(
    script in cmd or
    any(os.path.basename(tok) == script for tok in cmd.split())
    for cmd in cmds if cmd.strip()
)
print("OK" if found else "MISSING")
PYEOF
)
  if [[ "$STOP_WIRED" == "OK" ]]; then
    pass "cast-session-end.sh: wired in $(basename "$SETTINGS")"
  elif [[ "$STOP_WIRED" == "MISSING" ]]; then
    warn "cast-session-end.sh: not wired in settings.json (session end telemetry unavailable)"
  else
    warn "cast-session-end.sh: could not verify wiring"
  fi
fi

# --- Check 9: routing-proposals.json schema (if present) ---
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

# --- Check 11: Local-First Readiness ---
echo ""
echo "Local-First Readiness"
echo "─────────────────────"

# Keychain: is ANTHROPIC_API_KEY stored?
if [[ "$(uname -s)" == "Darwin" ]] && security find-generic-password -s cast-anthropic-api-key -a cast -w >/dev/null 2>&1; then
  pass "Keychain: ANTHROPIC_API_KEY stored in macOS Keychain"
else
  info "Keychain: ANTHROPIC_API_KEY not in Keychain (opt-in: cast-keychain.sh set anthropic-api-key)"
fi

# Encryption: is age installed? Memory file state?
if command -v age >/dev/null 2>&1; then
  MEMORY_DIR="$HOME/.claude/agent-memory-local"
  AGE_COUNT=$(find "$MEMORY_DIR" -name "*.age" -type f 2>/dev/null | wc -l | tr -d '[:space:]' || echo 0)
  if [[ "$AGE_COUNT" -gt 0 ]]; then
    pass "Encryption: age installed, $AGE_COUNT encrypted memory file(s)"
  else
    pass "Encryption: age installed (memory not encrypted — opt-in: cast-encrypt.sh encrypt)"
  fi
else
  info "Encryption: age not installed (opt-in: brew install age)"
fi

# Backup: freshness check
BACKUP_DIR="${CAST_BACKUP_DIR:-${HOME}/Library/Application Support/cast/db-backups}"
LEGACY_BACKUP_DIR="${HOME}/.claude/backups"
if [[ -d "$BACKUP_DIR" ]]; then
  LATEST_BACKUP=$(find "$BACKUP_DIR" -name "cast-db-*.db" -type f 2>/dev/null | sort -r | head -1)
  if [[ -n "$LATEST_BACKUP" ]]; then
    BACKUP_AGE_DAYS=$(python3 -c "
import os, datetime
mtime = os.path.getmtime('$LATEST_BACKUP')
age = (datetime.datetime.now().timestamp() - mtime) / 86400
print(f'{age:.0f}')
" 2>/dev/null || echo "?")
    pass "Backup: latest $(basename "$LATEST_BACKUP") (${BACKUP_AGE_DAYS}d ago)"
  else
    info "Backup: $BACKUP_DIR exists but no cast-db-*.db snapshots found"
  fi
else
  info "Backup: dir not found at $BACKUP_DIR (run: cast-db-backup.py)"
fi
# Legacy advisory: old colocated backups from before wipe-#2 retarget
if [[ -d "$LEGACY_BACKUP_DIR" ]] && [[ -n "$(ls -A "$LEGACY_BACKUP_DIR" 2>/dev/null)" ]]; then
  info "Backup: legacy colocated backups present in ~/.claude/backups — migrate to $BACKUP_DIR"
fi

# Ollama: is it running?
if command -v ollama >/dev/null 2>&1; then
  if curl -s --connect-timeout 2 "http://localhost:11434/api/tags" >/dev/null 2>&1; then
    OLLAMA_MODEL_COUNT=$(curl -s --connect-timeout 2 "http://localhost:11434/api/tags" 2>/dev/null | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('models',[])))" 2>/dev/null || echo "?")
    pass "Ollama: running ($OLLAMA_MODEL_COUNT model(s) available)"
  else
    info "Ollama: installed but not running (start: ollama serve)"
  fi
else
  info "Ollama: not installed (opt-in: brew install ollama)"
fi

# Offline queue depth
OFFLINE_QUEUE_DIR="$HOME/.claude/cast/offline-queue"
if [[ -d "$OFFLINE_QUEUE_DIR" ]]; then
  QUEUE_DEPTH=$(find "$OFFLINE_QUEUE_DIR" -name "*.json" -type f 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$QUEUE_DEPTH" -eq 0 ]]; then
    pass "Offline queue: empty (0 pending)"
  else
    warn "Offline queue: $QUEUE_DEPTH item(s) pending replay"
  fi
else
  pass "Offline queue: not initialized (no pending items)"
fi

# FTS5: agent_memories_fts table present?
CAST_DB="$HOME/.claude/cast.db"
if [[ -f "$CAST_DB" ]]; then
  FTS5_CHECK=$(sqlite3 "$CAST_DB" "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='agent_memories_fts';" 2>/dev/null || echo "0")
  if [[ "$FTS5_CHECK" -gt 0 ]]; then
    pass "FTS5: agent_memories_fts table present in cast.db"
  else
    info "FTS5: agent_memories_fts table not found (run: cast-memory-fts5-migrate.py)"
  fi
else
  info "FTS5: cast.db not found"
fi

echo ""

# --- Check 12: managed-settings.d fragment commands resolve to real scripts ---
FRAGS_DIR="$HOME/.claude/managed-settings.d"
SCRIPTS_DIR="$HOME/.claude/scripts"
if [[ ! -d "$FRAGS_DIR" ]]; then
  info "Fragment command check: $FRAGS_DIR not found (install not yet run)"
else
  FRAG_CHECK=$(python3 - "$FRAGS_DIR" "$SCRIPTS_DIR" <<'PYEOF'
import sys, os, json, glob

frags_dir = sys.argv[1]
scripts_dir = sys.argv[2]
missing = []

for frag_path in sorted(glob.glob(os.path.join(frags_dir, "*.json"))):
    frag_name = os.path.basename(frag_path)
    try:
        with open(frag_path) as f:
            data = json.load(f)
    except Exception as e:
        print(f"ERROR:{frag_name}:{e}")
        sys.exit(0)
    hooks = data.get("hooks", {})
    for event_hooks in hooks.values():
        for entry in (event_hooks if isinstance(event_hooks, list) else []):
            for h in entry.get("hooks", []):
                cmd = h.get("command", "")
                if not cmd:
                    continue
                # Extract tokens that look like script paths under ~/.claude/scripts/
                for tok in cmd.split():
                    basename = os.path.basename(tok)
                    if (basename.endswith(".sh") or basename.endswith(".py")) and "scripts/" in tok:
                        if not os.path.isfile(os.path.join(scripts_dir, basename)):
                            missing.append(f"{frag_name}: {basename}")

if missing:
    print("MISSING:" + "|".join(missing))
else:
    print("OK")
PYEOF
)
  if [[ "$FRAG_CHECK" == OK ]]; then
    pass "Fragment commands: all managed-settings.d hook commands resolve to existing scripts"
  elif [[ "$FRAG_CHECK" == MISSING:* ]]; then
    DETAILS="${FRAG_CHECK#MISSING:}"
    fail "Fragment commands: hook command(s) reference missing scripts"
    IFS='|' read -ra MISSING_LIST <<< "$DETAILS"
    for m in "${MISSING_LIST[@]}"; do
      echo "  ✗ ${m}"
    done
  elif [[ "$FRAG_CHECK" == ERROR:* ]]; then
    warn "Fragment commands: parse error — ${FRAG_CHECK#ERROR:}"
  fi
fi

echo ""

# --- Check 13: config agent-name cross-check (no ghost agents) ---
AGENTS_DIR="$HOME/.claude/agents"
CHAIN_MAP="$HOME/.claude/config/chain-map.json"
POLICIES_JSON="$HOME/.claude/config/policies.json"
WATCHERS_TEMPLATE="$HOME/.claude/config/fs-watchers.json.template"
WATCHERS_JSON="$HOME/.claude/config/fs-watchers.json"

if [[ ! -d "$AGENTS_DIR" ]]; then
  warn "Agent cross-check: $AGENTS_DIR not found — cannot verify config agent names"
else
  GHOST_RESULT=$(python3 - "$AGENTS_DIR" "$CHAIN_MAP" "$POLICIES_JSON" "$WATCHERS_TEMPLATE" "$WATCHERS_JSON" <<'PYEOF'
import sys, os, json, glob

agents_dir    = sys.argv[1]
cm_path       = sys.argv[2]
pol_path      = sys.argv[3]
wt_path       = sys.argv[4]
wj_path       = sys.argv[5]

# Build canonical agent set from installed core agents
canonical = {
    os.path.splitext(os.path.basename(f))[0]
    for f in glob.glob(os.path.join(agents_dir, "*.md"))
}

ghosts = []

# --- chain-map.json: top-level keys (skip _comment) and successor values ---
if os.path.isfile(cm_path):
    try:
        with open(cm_path) as f:
            cm = json.load(f)
        for key, val in cm.items():
            if key == "_comment":
                continue
            if key not in canonical:
                ghosts.append(f"chain-map.json: key {key!r}")
            # Successor values may be strings or lists
            successors = val if isinstance(val, list) else ([val] if isinstance(val, str) else [])
            for s in successors:
                if isinstance(s, str) and s not in canonical:
                    ghosts.append(f"chain-map.json: successor {s!r} (from key {key!r})")
    except Exception as e:
        ghosts.append(f"chain-map.json: could not verify ({e})")
else:
    pass  # Optional file — absence is OK, nothing to cross-check

# --- policies.json: requires_agent values ---
if os.path.isfile(pol_path):
    try:
        with open(pol_path) as f:
            pol = json.load(f)
        policies = pol.get("policies", pol) if isinstance(pol, dict) else pol
        if isinstance(policies, list):
            for p in policies:
                ra = p.get("requires_agent")
                if ra and ra not in canonical:
                    ghosts.append(f"policies.json: requires_agent {ra!r} (id={p.get('id','?')!r})")
    except Exception as e:
        ghosts.append(f"policies.json: could not verify ({e})")
else:
    pass  # Optional file — absence is OK, nothing to cross-check

# --- fs-watchers.json.template + fs-watchers.json: rules[*].agent values ---
for wpath, wlabel in [(wt_path, "fs-watchers.json.template"), (wj_path, "fs-watchers.json")]:
    if os.path.isfile(wpath):
        try:
            with open(wpath) as f:
                wd = json.load(f)
            for rule in wd.get("rules", []):
                agent_name = rule.get("agent")
                if agent_name and agent_name not in canonical:
                    ghosts.append(f"{wlabel}: agent {agent_name!r}")
        except Exception as e:
            ghosts.append(f"{wlabel}: could not verify ({e})")

if ghosts:
    print("GHOSTS:" + "|".join(ghosts))
else:
    print("OK")
PYEOF
)
  if [[ "$GHOST_RESULT" == OK ]]; then
    pass "Agent cross-check: no ghost agent names in chain-map.json, policies.json, fs-watchers.json.template"
  elif [[ "$GHOST_RESULT" == GHOSTS:* ]]; then
    DETAILS="${GHOST_RESULT#GHOSTS:}"
    IFS='|' read -ra GHOST_LIST <<< "$DETAILS"
    for g in "${GHOST_LIST[@]}"; do
      warn "Agent cross-check: ghost/unverifiable — ${g}"
    done
  else
    warn "Agent cross-check: unexpected result — ${GHOST_RESULT}"
  fi
fi

echo ""

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
