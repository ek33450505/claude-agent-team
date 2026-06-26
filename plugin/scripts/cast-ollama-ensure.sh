#!/usr/bin/env bash
# cast-ollama-ensure.sh — ensure Ollama is reachable; auto-start if possible.
# Fail-open: always exits 0. Consumers handle down state gracefully.
# Usage: bash cast-ollama-ensure.sh

# Subprocess guard MUST come before set -euo pipefail
if [ "${CLAUDE_SUBPROCESS:-0}" = "1" ]; then exit 0; fi

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

_log_error() {
	local msg="$1"
	local log_dir
	log_dir="${HOME}/.claude/logs"
	mkdir -p "$log_dir"
	echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] [cast-ollama-ensure] ERROR: ${msg}" \
		>>"${log_dir}/hook-errors.log"
}

# Config via env
OLLAMA_URL="${CAST_OLLAMA_URL:-http://localhost:11434}"

_ollama_reachable() {
	curl -fsS --max-time 2 -- "${OLLAMA_URL}/api/version" >/dev/null 2>&1
}

# --- Check if already up ---
if _ollama_reachable; then
	exit 0
fi

# --- Ollama is down — attempt to start ---
if [[ "$(uname)" == "Darwin" ]]; then
	open -ga Ollama 2>/dev/null || true
else
	if command -v ollama >/dev/null 2>&1; then
		nohup ollama serve >/dev/null 2>&1 &
	fi
fi

# --- Poll up to ~15s (10 tries × 1.5s) ---
_POLL_TRIES=10
_POLL_INTERVAL=1.5
for ((i = 1; i <= _POLL_TRIES; i++)); do
	sleep "${_POLL_INTERVAL}"
	if _ollama_reachable; then
		exit 0
	fi
done

# --- Still down: fire one reminder then exit 0 (fail-open) ---
_log_error "Ollama at ${OLLAMA_URL} did not come up after ~15s; firing reminder." || true
bash "${SCRIPT_DIR}/cast-notify.sh" \
	ollama_down \
	"Ollama isn't running — CAST needs it for local embeddings (and future routing). Please open Ollama." \
	"CAST" 2>/dev/null || true

exit 0
