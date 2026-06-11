#!/bin/bash
# cast-statusline.sh — StatusLine formatter for Claude Code
# Reads native JSON from stdin, outputs a single formatted line.
# Must be fast (<100ms) — runs after every assistant message.

# Source agent color helper
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=cast-agent-color.sh
source "${SCRIPT_DIR}/cast-agent-color.sh"

INPUT="$(cat 2>/dev/null || true)"
[ -z "$INPUT" ] && echo "CAST | n/a" && exit 0

# Try jq first, fall back to python3
if command -v jq >/dev/null 2>&1; then
  agent=$(echo "$INPUT" | jq -r '.agent.name // "main"' 2>/dev/null)
  cost=$(echo "$INPUT" | jq -r '.cost.total_cost_usd // 0' 2>/dev/null)
  ctx_pct=$(echo "$INPUT" | jq -r '.context_window.used_percentage // 0' 2>/dev/null)
  rate_pct=$(echo "$INPUT" | jq -r '.rate_limits.five_hour.used_percentage // empty' 2>/dev/null)
  model=$(echo "$INPUT" | jq -r '.model.display_name // "n/a"' 2>/dev/null)
  session=$(echo "$INPUT" | jq -r '.session_name // empty' 2>/dev/null)
  session_id=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
else
  # jq not available — use safe static defaults
  agent="main"; cost="0"; ctx_pct="0"; rate_pct=""; model="n/a"; session=""; session_id=""
fi

# ── Git branch ────────────────────────────────────────────────────────────────
git_branch=""
git_branch="$(git branch --show-current 2>/dev/null || true)"

# ── Session uptime ─────────────────────────────────────────────────────────────
uptime_str=""
if [ -n "$session_id" ]; then
  epoch_file="${TMPDIR:-/tmp}/cast-session-start-${session_id}.epoch"
  now_epoch="$(date +%s 2>/dev/null || true)"
  if [ -f "$epoch_file" ]; then
    start_epoch="$(cat "$epoch_file" 2>/dev/null || echo "")"
    if [ -n "$start_epoch" ] && [ -n "$now_epoch" ]; then
      elapsed=$(( now_epoch - start_epoch ))
      hours=$(( elapsed / 3600 ))
      mins=$(( (elapsed % 3600) / 60 ))
      if [ "$hours" -gt 0 ]; then
        uptime_str="$(printf '%dh%02dm' "$hours" "$mins")"
      else
        uptime_str="${mins}m"
      fi
    fi
  elif [ -n "$now_epoch" ]; then
    echo "$now_epoch" > "$epoch_file" 2>/dev/null || true
    uptime_str="0m"
  fi
fi

# ── Active CAST agents (from cast.db agent_runs where status='running') ──────
active_agents=""
dispatch_count=""
DB_PATH="${CAST_DB_PATH:-${HOME}/.claude/cast.db}"
if [ -n "$session_id" ] && [ -f "$DB_PATH" ] && command -v python3 >/dev/null 2>&1; then
  export CAST_SL_DB="$DB_PATH"
  export CAST_SL_SESSION="$session_id"
  IFS='|' read -r active_agents dispatch_count <<< "$(python3 - <<'PYEOF' 2>/dev/null
import sqlite3, os
db   = os.environ.get('CAST_SL_DB', '')
sess = os.environ.get('CAST_SL_SESSION', '')
if not db or not sess:
    raise SystemExit(0)
try:
    conn = sqlite3.connect(db, timeout=2)
    rows = conn.execute(
        "SELECT DISTINCT agent FROM agent_runs WHERE status='running' AND session_id=? ORDER BY id",
        (sess,)
    ).fetchall()
    count_row = conn.execute(
        "SELECT COUNT(*) FROM agent_runs WHERE session_id=?",
        (sess,)
    ).fetchone()
    conn.close()
    names = [r[0] for r in rows if r[0]]
    total = count_row[0] if count_row else 0
    print('%s|%s' % (','.join(names), total))
except Exception:
    print('|0')
PYEOF
  )" || true
fi

# Handle null/empty defaults
[ "$agent" = "null" ] || [ -z "$agent" ] && agent="main"
[ "$cost" = "null" ] || [ -z "$cost" ] && cost="0"
[ "$ctx_pct" = "null" ] || [ -z "$ctx_pct" ] && ctx_pct="0"
[ "$model" = "null" ] || [ -z "$model" ] && model="n/a"

# Format cost
cost_fmt=$(printf '$%.2f' "$cost" 2>/dev/null || echo "\$0.00")

# Context color (ANSI)
ctx_int=${ctx_pct%%.*}
ctx_int=${ctx_int:-0}
if [ "$ctx_int" -lt 50 ] 2>/dev/null; then
  ctx_color="\033[32m"  # green
elif [ "$ctx_int" -lt 75 ] 2>/dev/null; then
  ctx_color="\033[33m"  # yellow
else
  ctx_color="\033[31m"  # red
fi
reset="\033[0m"

# ── Line 1 (primary): branch + agent + cost + ctx + uptime ───────────────────
agent_color=$(get_agent_color "$agent")
# Prefix with git branch if available and different from agent name
if [ -n "$git_branch" ] && [ "$git_branch" != "$agent" ]; then
  line1="⚡ ${git_branch} ${agent_color}${agent}${reset} | ${cost_fmt} | ctx: ${ctx_color}${ctx_pct}%${reset}"
else
  line1="⚡ ${agent_color}${agent}${reset} | ${cost_fmt} | ctx: ${ctx_color}${ctx_pct}%${reset}"
fi

# Add uptime if available
if [ -n "$uptime_str" ]; then
  line1="${line1} | 🕐 ${uptime_str}"
fi

# ── Line 2 (secondary): agents + rate + session + model ──────────────────────
# Build active CAST agents section
agents_section=""
if [ -n "$active_agents" ]; then
  agents_colored=""
  IFS=',' read -ra agent_list <<< "$active_agents"
  for a in "${agent_list[@]}"; do
    ac=$(get_agent_color "$a")
    if [ -n "$agents_colored" ]; then
      agents_colored="${agents_colored} ${ac}${a}${reset}"
    else
      agents_colored="${ac}${a}${reset}"
    fi
  done
  agents_section="${agents_colored}"
fi
# Add dispatch count if available
if [ -n "$dispatch_count" ] && [ "$dispatch_count" != "0" ] && [ "$dispatch_count" != "" ]; then
  if [ -n "$agents_section" ]; then
    agents_section="${agents_section} (${dispatch_count} dispatched)"
  else
    agents_section="(${dispatch_count} dispatched)"
  fi
fi

# Assemble line2 segments, join with " | ", skipping empty ones
line2=""
if [ -n "$agents_section" ]; then
  line2="agents: ${agents_section}"
fi
if [ -n "$rate_pct" ] && [ "$rate_pct" != "null" ]; then
  [ -n "$line2" ] && line2="${line2} | rate: ${rate_pct}%" || line2="rate: ${rate_pct}%"
fi
if [ -n "$session" ] && [ "$session" != "null" ]; then
  [ -n "$line2" ] && line2="${line2} | ${session}" || line2="${session}"
fi
# Model always appears on line2
[ -n "$line2" ] && line2="${line2} | ${model}" || line2="${model}"

printf '%b\n%b\n' "$line1" "$line2"
exit 0
