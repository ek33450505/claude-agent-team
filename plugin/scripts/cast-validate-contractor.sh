#!/bin/bash
# cast-validate-contractor.sh — Validate Ollama contractor output before passing to next CAST stage.
#
# Reads output from stdin. Validates:
#   1. Non-empty output
#   2. No hallucination markers ("I cannot", "As an AI", "I'm not sure")
#   3. Reasonable length: 10-500 chars (configurable via CAST_CONTRACTOR_MIN/MAX_LEN)
#   4. Commit message mode (--type commit): imperative mood start (capital letter, no "This commit")
#
# Exit codes:
#   0 — validation passed; output is safe to pass to next stage
#   1 — validation failed; trigger escalation to Claude
#
# Usage:
#   echo "feat: add login" | cast-validate-contractor.sh --type commit
#   echo "some output"    | cast-validate-contractor.sh
#
# Environment:
#   CAST_CONTRACTOR_MIN_LEN   Minimum output length (default: 10)
#   CAST_CONTRACTOR_MAX_LEN   Maximum output length (default: 500)
#   CAST_DB_PATH              Path to cast.db (default: ~/.claude/cast.db)
#   CAST_SESSION_ID           Session ID for logging (optional)

set -euo pipefail

SCRIPTS_DIR="${CAST_SCRIPTS_DIR:-${HOME}/.claude/scripts}"
MIN_LEN="${CAST_CONTRACTOR_MIN_LEN:-10}"
MAX_LEN="${CAST_CONTRACTOR_MAX_LEN:-500}"
OUTPUT_TYPE="generic"
MODEL="${CAST_CONTRACTOR_MODEL:-unknown}"
SESSION_ID="${CAST_SESSION_ID:-unknown}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --type) OUTPUT_TYPE="$2"; shift ;;
    --model) MODEL="$2"; shift ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
  shift
done

# Read contractor output from stdin
CONTRACTOR_OUTPUT="$(cat)"
VALIDATION_RESULT="pass"
FAIL_REASON=""

# --- Check 1: Non-empty ---
if [ -z "$CONTRACTOR_OUTPUT" ]; then
  VALIDATION_RESULT="fail"
  FAIL_REASON="empty output"
fi

# --- Check 2: No hallucination markers ---
if [ "$VALIDATION_RESULT" = "pass" ]; then
  HALLUCINATION_PATTERNS=(
    "I cannot"
    "As an AI"
    "I'm not sure"
    "I am not able"
    "I don't have the ability"
    "I'm unable to"
    "As a language model"
  )
  for PATTERN in "${HALLUCINATION_PATTERNS[@]}"; do
    if echo "$CONTRACTOR_OUTPUT" | grep -qi "$PATTERN"; then
      VALIDATION_RESULT="fail"
      FAIL_REASON="hallucination marker: $PATTERN"
      break
    fi
  done
fi

# --- Check 3: Reasonable length ---
if [ "$VALIDATION_RESULT" = "pass" ]; then
  OUTPUT_LEN="${#CONTRACTOR_OUTPUT}"
  if [ "$OUTPUT_LEN" -lt "$MIN_LEN" ]; then
    VALIDATION_RESULT="fail"
    FAIL_REASON="output too short: ${OUTPUT_LEN} chars (min: ${MIN_LEN})"
  elif [ "$OUTPUT_LEN" -gt "$MAX_LEN" ]; then
    VALIDATION_RESULT="fail"
    FAIL_REASON="output too long: ${OUTPUT_LEN} chars (max: ${MAX_LEN})"
  fi
fi

# --- Check 4: Commit message validation ---
if [ "$VALIDATION_RESULT" = "pass" ] && [ "$OUTPUT_TYPE" = "commit" ]; then
  FIRST_LINE="$(echo "$CONTRACTOR_OUTPUT" | head -1)"

  # Must start with a capital letter
  FIRST_CHAR="${FIRST_LINE:0:1}"
  if ! echo "$FIRST_CHAR" | grep -q '[A-Z]'; then
    VALIDATION_RESULT="fail"
    FAIL_REASON="commit: does not start with capital letter"
  fi

  # Must not start with "This commit"
  if echo "$FIRST_LINE" | grep -qi "^This commit"; then
    VALIDATION_RESULT="fail"
    FAIL_REASON="commit: starts with 'This commit' (not imperative mood)"
  fi

  # Must not be all lowercase (indicative of non-imperative form)
  if echo "$FIRST_LINE" | grep -q "^[a-z]"; then
    VALIDATION_RESULT="fail"
    FAIL_REASON="commit: first word is lowercase (not imperative mood)"
  fi
fi

# --- Log result to cast.db ---
LOG_PAYLOAD="{
  \"session_id\": \"${SESSION_ID}\",
  \"timestamp\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",
  \"event_type\": \"contractor_validation\",
  \"action\": \"validate_contractor\",
  \"matched_route\": \"${OUTPUT_TYPE}\",
  \"match_type\": \"contractor\",
  \"confidence\": \"${VALIDATION_RESULT}\",
  \"pattern\": \"${MODEL}\",
  \"prompt_preview\": \"${FAIL_REASON}\"
}"

if [ -f "${SCRIPTS_DIR}/cast-db-log.py" ] && command -v python3 >/dev/null 2>&1; then
  echo "$LOG_PAYLOAD" | python3 "${SCRIPTS_DIR}/cast-db-log.py" 2>/dev/null || true
fi

# --- Exit and emit output ---
if [ "$VALIDATION_RESULT" = "pass" ]; then
  echo "$CONTRACTOR_OUTPUT"
  exit 0
else
  echo "cast-validate-contractor: FAIL — ${FAIL_REASON}" >&2
  exit 1
fi
