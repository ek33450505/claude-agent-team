#!/bin/bash
# cast-agent-color.sh — Agent name → ANSI 256-color escape code lookup
# Sourceable helper for statusline and other CAST display scripts.
# No file I/O — pure case statement for speed.

# get_agent_color <agent-name>
# Prints the ANSI escape sequence to set the agent's color.
get_agent_color() {
  local agent="${1:-main}"
  local code
  case "$agent" in
    code-writer)       code="38;5;208" ;;  # orange
    code-reviewer)     code="36"       ;;  # cyan
    commit)            code="38;5;220" ;;  # yellow
    push)              code="38;5;33"  ;;  # blue
    debugger)          code="38;5;196" ;;  # red
    test-runner)       code="32"       ;;  # green (standard ANSI)
    test-writer)       code="38;5;201" ;;  # fuchsia
    planner)           code="38;5;69"  ;;  # cornflower blue
    orchestrator)      code="38;5;135" ;;  # purple
    researcher)        code="38;5;105" ;;  # indigo
    security)          code="38;5;199" ;;  # hot pink
    bash-specialist)   code="38;5;214" ;;  # amber
    devops)            code="38;5;30"  ;;  # teal
    docs)              code="38;5;48"  ;;  # emerald
    merge)             code="38;5;142" ;;  # olive
    frontend-qa)       code="38;5;45"  ;;  # sky blue
    morning-briefing)  code="38;5;172" ;;  # bronze
    main)              code="38;5;255" ;;  # white (default session)
    *)                 code="0"        ;;  # reset / no color
  esac
  printf '\033[%sm' "$code"
}

# get_agent_color_reset
# Prints the ANSI reset sequence.
get_agent_color_reset() {
  printf '\033[0m'
}
