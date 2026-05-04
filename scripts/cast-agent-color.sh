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
    adr-writer)        code="38;5;37"  ;;  # teal (distinct from devops 30)
    api-contract)      code="38;5;27"  ;;  # blue (distinct from push 33)
    dep-auditor)       code="38;5;226" ;;  # yellow (distinct from commit 220)
    email-drafter)     code="38;5;153" ;;  # light blue
    knowledge-curator) code="38;5;141" ;;  # purple (distinct from orchestrator 135)
    learning-scout)    code="38;5;178" ;;  # gold
    meeting-prep)      code="38;5;39"  ;;  # blue (distinct from push 33 and api-contract 27)
    migration-reviewer) code="38;5;99" ;;  # purple (distinct from orchestrator 135, knowledge-curator 141)
    perf-sentinel)     code="38;5;164" ;;  # magenta
    pr-narrator)       code="38;5;218" ;;  # pink
    release-notes)     code="38;5;51"  ;;  # cyan (distinct from code-reviewer 36)
    standup-writer)    code="38;5;112" ;;  # green (distinct from test-runner 32)
    task-triage)       code="38;5;202" ;;  # orange (distinct from code-writer 208)
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
