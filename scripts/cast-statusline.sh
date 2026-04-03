#!/bin/bash
# cast-statusline.sh — StatusLine formatter for Claude Code
# Reads native JSON from stdin, outputs a single formatted line.
# Must be fast (<100ms) — runs after every assistant message.

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
else
  eval "$(echo "$INPUT" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    def g(path, default='n/a'):
        obj = d
        for k in path.split('.'):
            if isinstance(obj, dict):
                obj = obj.get(k, None)
            else:
                return default
        return obj if obj is not None else default
    print(f\"agent='{g('agent.name','main')}'\")
    print(f\"cost='{g('cost.total_cost_usd','0')}'\")
    print(f\"ctx_pct='{g('context_window.used_percentage','0')}'\")
    print(f\"rate_pct='{g('rate_limits.five_hour.used_percentage','')}'\")
    print(f\"model='{g('model.display_name','n/a')}'\")
    print(f\"session='{g('session_name','')}'\")
except Exception:
    print(\"agent='main'\")
    print(\"cost='0'\")
    print(\"ctx_pct='0'\")
    print(\"rate_pct=''\")
    print(\"model='n/a'\")
    print(\"session=''\")
" 2>/dev/null)"
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

# Build output
out="⚡ ${agent} | ${cost_fmt} | ctx: ${ctx_color}${ctx_pct}%${reset}"

# Add rate limit if present
if [ -n "$rate_pct" ] && [ "$rate_pct" != "null" ]; then
  out="${out} | rate: ${rate_pct}%"
fi

# Add session name if present
if [ -n "$session" ] && [ "$session" != "null" ]; then
  out="${out} | ${session}"
fi

# Add model
out="${out} | ${model}"

printf '%b\n' "$out"
exit 0
