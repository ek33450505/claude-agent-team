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

# ── Parse stdin JSON + git branch + active agents: ONE python3 process ───────
# (Replaces jq + `git branch --show-current` + a sqlite heredoc: 3 spawns -> 1.)
# Fields are joined with US (0x1f, ASCII Unit Separator): non-whitespace so IFS
# does not collapse consecutive delimiters (empty field positions survive).
# NOT \x01 — bash <=4 (macOS /bin/bash 3.2) uses 0x01 internally as CTLESC, so
# it fails as an IFS delimiter and every field lands in the first variable.
DB_PATH="${CAST_DB_PATH:-${HOME}/.claude/cast.db}"
agent="main"; cost="0"; ctx_pct="0"; rate_pct=""; model="n/a"; session=""; session_id=""
git_branch=""; active_agents=""; dispatch_count=""
IFS=$'\x1f' read -r agent cost ctx_pct rate_pct model session session_id git_branch active_agents dispatch_count <<< \
  "$(CAST_SL_INPUT="$INPUT" CAST_SL_DB="$DB_PATH" python3 -c '
import json, os, sqlite3

SEP = "\x1f"
DEFAULTS = ["main", "0", "0", "", "n/a", "", ""]


def parse(raw):
    # Keep numeric literals verbatim (jq prints them unchanged).
    d = json.loads(raw, parse_float=str, parse_int=str)
    if d is not None and not isinstance(d, dict):
        raise ValueError("not an object")

    def get(*path):
        cur = d
        for k in path:
            if cur is None:
                return None
            if not isinstance(cur, dict):
                raise ValueError("bad traversal")
            cur = cur.get(k)
        return cur

    out = []
    for path, dflt in (
        (("agent", "name"), "main"),
        (("cost", "total_cost_usd"), "0"),
        (("context_window", "used_percentage"), "0"),
        (("rate_limits", "five_hour", "used_percentage"), ""),
        (("model", "display_name"), "n/a"),
        (("session_name",), ""),
        (("session_id",), ""),
    ):
        v = get(*path)
        if v is None or v is False:
            v = dflt
        elif v is True:
            v = "true"
        elif isinstance(v, (dict, list)):
            raise ValueError("join of non-scalar")
        out.append(str(v))
    return out


def branch():
    try:
        cur = os.path.realpath(os.getcwd())
    except OSError:
        return ""
    while True:
        g = os.path.join(cur, ".git")
        try:
            if os.path.isdir(g):
                head = os.path.join(g, "HEAD")
                break
            if os.path.isfile(g):
                with open(g) as f:
                    first = f.readline().strip()
                if first.startswith("gitdir:"):
                    gd = first[7:].strip()
                    if not os.path.isabs(gd):
                        gd = os.path.join(cur, gd)
                    head = os.path.join(gd, "HEAD")
                    break
        except OSError:
            return ""
        parent = os.path.dirname(cur)
        if parent == cur:
            return ""
        cur = parent
    try:
        with open(head) as f:
            line = f.readline().strip()
    except OSError:
        return ""
    pre = "ref: refs/heads/"
    return line[len(pre):] if line.startswith(pre) else ""


try:
    fields = parse(os.environ.get("CAST_SL_INPUT", ""))
except Exception:
    fields = list(DEFAULTS)

active, count = "", ""
db = os.environ.get("CAST_SL_DB", "")
sess = fields[6]
if sess and db and os.path.isfile(db):
    try:
        conn = sqlite3.connect(db, timeout=2)
        rows = conn.execute(
            "SELECT DISTINCT agent FROM agent_runs WHERE status=\x27running\x27 AND session_id=? ORDER BY id",
            (sess,),
        ).fetchall()
        crow = conn.execute(
            "SELECT COUNT(*) FROM agent_runs WHERE session_id=?", (sess,)
        ).fetchone()
        conn.close()
        active = ",".join(r[0] for r in rows if r[0])
        count = str(crow[0] if crow else 0)
    except Exception:
        active, count = "", "0"

print(SEP.join(v.replace(SEP, "") for v in fields + [branch(), active, count]))
' 2>/dev/null || true)"

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
