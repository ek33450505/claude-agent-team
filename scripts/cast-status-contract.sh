#!/usr/bin/env bash
# cast-status-contract.sh — shared CAST Status-block contract helper.
# Single source of truth for which subagents are bound by the CAST protocol
# (must end with `Status: DONE|...`). Sourced by cast-subagent-stop-hook.sh and
# cast-response-completeness-hook.sh so the exempt set cannot drift between them.
#
# Principle: a missing-Status event is only REAL for an IDENTIFIABLE CAST agent
# that produced substantive prose. Built-ins, workflow subagents, and
# unidentifiable ('unknown'/empty) agents are NOT under the contract.

# cast_status_exempt_agent <agent_type>
#   returns 0 (EXEMPT — skip the check) for non-CAST / unidentifiable agents,
#   returns 1 (UNDER CONTRACT) for identifiable CAST agents.
cast_status_exempt_agent() {
  case "${1:-}" in
    general-purpose|Explore|Plan|claude|statusline-setup|output-style-setup|unknown|"")
      return 0 ;;
    *workflow-subagent*)
      return 0 ;;
    *)
      return 1 ;;
  esac
}

# cast_output_lacks_prose <output_text>
#   returns 0 if output is empty/whitespace-only (StructuredOutput-only — no prose
#   to carry a Status block), 1 if there is substantive prose.
cast_output_lacks_prose() {
  [ -z "$(printf '%s' "${1:-}" | tr -d '[:space:]')" ]
}
