#!/usr/bin/env bash
# cast-files-api.sh — Anthropic Files API adapter shim
# Usage:
#   cast-files-api.sh upload <local-file-path> [--purpose "assistants"] [--ttl 3600]
#   cast-files-api.sh download <file-id> <dest-path>
#   cast-files-api.sh delete <file-id>
# Env:
#   ANTHROPIC_API_KEY   required (or stored in macOS keychain under 'anthropic-api-key')
# Beta header: files-api-2025-04-14

# Disable xtrace first — this script handles ANTHROPIC_API_KEY and must never echo it
set +x
set -euo pipefail

# --- Subprocess bypass ---
if [[ "${CLAUDE_SUBPROCESS:-}" == "1" ]]; then
  exit 0
fi

# --- Constants ---
BETA_HEADER="files-api-2025-04-14"
API_BASE="${ANTHROPIC_API_BASE:-https://api.anthropic.com}"
# Authority parse (not prefix matching): https only, no userinfo, host exactly
# api.anthropic.com or localhost, optional :1-5 digit port.
_cast_url_allowed() {
  local url="$1" rest authority host port
  case "$url" in *[[:space:]]*) return 1 ;; esac
  case "$url" in https://*) ;; *) return 1 ;; esac
  rest="${url#https://}"
  authority="${rest%%[/?#]*}"
  case "$authority" in "" | *@*) return 1 ;; esac
  host="${authority%%:*}"
  case "$host" in api.anthropic.com | localhost) ;; *) return 1 ;; esac
  if [[ "$authority" != "$host" ]]; then
    port="${authority#"$host":}"
    case "$port" in "" | *[!0-9]*) return 1 ;; esac
    [[ ${#port} -le 5 ]] || return 1
  fi
  return 0
}

# A key containing a quote, backslash, CR or LF would break out of the curl
# config line (-K) that carries it, so refuse it.
_cast_key_ok() {
  case "$1" in *\"*) return 1 ;; *\\*) return 1 ;; *$'\r'*) return 1 ;; *$'\n'*) return 1 ;; esac
  return 0
}
if ! _cast_url_allowed "$API_BASE"; then
  echo "ERROR: ANTHROPIC_API_BASE '$API_BASE' is not allowed (must be https://api.anthropic.com or https://localhost[:port]); refusing to send the API key." >&2
  exit 1
fi
LOG_DIR="${HOME}/.claude/logs"
LOG_FILE="${LOG_DIR}/files-api.log"

# --- Verify API key (env var, then macOS Keychain fallback) ---
if [[ -z "${ANTHROPIC_API_KEY:-}" ]]; then
  if command -v security >/dev/null 2>&1; then
    KEYCHAIN_KEY="$(security find-generic-password -s anthropic-api-key -w 2>/dev/null || true)"
    if [[ -n "$KEYCHAIN_KEY" ]]; then
      ANTHROPIC_API_KEY="$KEYCHAIN_KEY"
      export ANTHROPIC_API_KEY
    fi
  fi
fi

if [[ -z "${ANTHROPIC_API_KEY:-}" ]]; then
  echo "ERROR: ANTHROPIC_API_KEY not set (env var or keychain)" >&2
  exit 1
fi
if ! _cast_key_ok "$ANTHROPIC_API_KEY"; then
  echo "ERROR: ANTHROPIC_API_KEY contains a disallowed character (quote, backslash, CR or LF)" >&2
  exit 1
fi

# --- Logging setup ---
umask 077
mkdir -p "$LOG_DIR"
chmod 700 "$LOG_DIR" 2>/dev/null || true

_log() {
  local action="$1"
  local file_id="${2:-}"
  local local_path="${3:-}"
  local agent="${4:-}"
  local status="${5:-}"
  echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ') action=${action} file_id=${file_id} local_path=${local_path} agent=${agent} status=${status}" >> "$LOG_FILE"
}

_log_error() {
  local msg="$1"
  local error_log="${HOME}/.claude/logs/hook-errors.log"
  echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] [CAST FILES API] ${msg}" >> "$error_log"
}

# --- Parse subcommand ---
if [[ $# -lt 1 ]]; then
  echo "Usage: cast-files-api.sh upload|download|delete [args]" >&2
  exit 1
fi

SUBCOMMAND="$1"
shift

case "$SUBCOMMAND" in
  upload)
    if [[ $# -lt 1 ]]; then
      echo "Usage: cast-files-api.sh upload <local-file-path> [--purpose \"assistants\"] [--ttl 3600]" >&2
      exit 1
    fi

    LOCAL_FILE_PATH="$1"
    shift

    PURPOSE="assistants"
    TTL=""

    while [[ $# -gt 0 ]]; do
      case "$1" in
        --purpose)
          PURPOSE="$2"
          shift 2
          ;;
        --ttl)
          TTL="$2"
          shift 2
          ;;
        *)
          echo "Unknown option: $1" >&2
          exit 1
          ;;
      esac
    done

    # Validate --ttl is a positive integer if provided
    if [[ -n "${TTL:-}" && ! "$TTL" =~ ^[0-9]+$ ]]; then
      echo "ERROR: --ttl must be a positive integer, got: $TTL" >&2
      exit 1
    fi

    # Validate file exists
    if [[ ! -f "$LOCAL_FILE_PATH" ]]; then
      echo "ERROR: file not found: $LOCAL_FILE_PATH" >&2
      _log_error "upload failed: file not found: $LOCAL_FILE_PATH"
      exit 1
    fi

    # Path traversal guard: resolve path and whitelist allowed directories
    RESOLVED_PATH="$(realpath "$LOCAL_FILE_PATH" 2>/dev/null || echo '')"
    if [[ -z "$RESOLVED_PATH" ]]; then
      echo "ERROR: cannot resolve path: $LOCAL_FILE_PATH" >&2
      exit 1
    fi
    case "$RESOLVED_PATH" in
      /Users/*|/tmp/*|/var/folders/*|/private/tmp/*|/private/var/folders/*) ;;
      *) echo "ERROR: file path outside allowed directories: $RESOLVED_PATH" >&2; exit 1 ;;
    esac
    LOCAL_FILE_PATH="$RESOLVED_PATH"

    # Upload via multipart
    RESPONSE="$(curl \
      --silent \
      --show-error \
      --fail-with-body \
      --connect-timeout 10 --speed-limit 1024 --speed-time 60 \
      -X POST "${API_BASE}/v1/files" \
      -K <(printf 'header = "x-api-key: %s"\n' "$ANTHROPIC_API_KEY") \
      -H "anthropic-beta: ${BETA_HEADER}" \
      -F "file=@${LOCAL_FILE_PATH}" \
      -F "mime_type=application/octet-stream" \
      -F "purpose=${PURPOSE}" \
      ${TTL:+-F "expires_in=${TTL}"} \
      2>&1)" || {
      CURL_EXIT=$?
      _log "upload" "" "$LOCAL_FILE_PATH" "" "error"
      _log_error "upload failed for $LOCAL_FILE_PATH: curl exit $CURL_EXIT"
      echo "ERROR: upload failed (curl exit $CURL_EXIT)" >&2
      exit 1
    }

    # Extract file_id from response
    FILE_ID="$(echo "$RESPONSE" | python3 -I -c 'import json,sys; print(json.load(sys.stdin).get("id",""))' 2>/dev/null || echo "")"

    if [[ -z "$FILE_ID" ]]; then
      _log "upload" "" "$LOCAL_FILE_PATH" "" "error"
      _log_error "upload failed: no file_id in response for $LOCAL_FILE_PATH"
      echo "ERROR: upload response missing file_id" >&2
      exit 1
    fi

    _log "upload" "$FILE_ID" "$LOCAL_FILE_PATH" "${CAST_AGENT_NAME:-}" "success"

    # Return JSON with file_id
    echo "$RESPONSE"
    ;;

  download)
    if [[ $# -lt 2 ]]; then
      echo "Usage: cast-files-api.sh download <file-id> <dest-path>" >&2
      exit 1
    fi

    FILE_ID="$1"
    DEST_PATH="$2"

    # Check destination directory
    DEST_DIR="$(dirname "$DEST_PATH")"
    if [[ ! -d "$DEST_DIR" ]]; then
      echo "ERROR: destination directory does not exist: $DEST_DIR" >&2
      _log_error "download failed: dest directory does not exist: $DEST_DIR"
      exit 1
    fi

    # Download file
    curl \
      --silent \
      --show-error \
      --fail-with-body \
      --connect-timeout 10 --speed-limit 1024 --speed-time 60 \
      -X GET "${API_BASE}/v1/files/${FILE_ID}/content" \
      -K <(printf 'header = "x-api-key: %s"\n' "$ANTHROPIC_API_KEY") \
      -H "anthropic-beta: ${BETA_HEADER}" \
      -o "$DEST_PATH" \
      2>&1 || {
      CURL_EXIT=$?
      _log "download" "$FILE_ID" "$DEST_PATH" "" "error"
      _log_error "download failed for file_id=$FILE_ID to $DEST_PATH: curl exit $CURL_EXIT"
      echo "ERROR: download failed (curl exit $CURL_EXIT)" >&2
      exit 1
    }

    _log "download" "$FILE_ID" "$DEST_PATH" "${CAST_AGENT_NAME:-}" "success"

    echo "Downloaded file_id=$FILE_ID to $DEST_PATH"
    ;;

  delete)
    if [[ $# -lt 1 ]]; then
      echo "Usage: cast-files-api.sh delete <file-id>" >&2
      exit 1
    fi

    FILE_ID="$1"

    # Delete file
    curl \
      --silent \
      --show-error \
      --fail-with-body \
      --connect-timeout 10 --max-time 120 \
      -X DELETE "${API_BASE}/v1/files/${FILE_ID}" \
      -K <(printf 'header = "x-api-key: %s"\n' "$ANTHROPIC_API_KEY") \
      -H "anthropic-beta: ${BETA_HEADER}" \
      > /dev/null 2>&1 || {
      CURL_EXIT=$?
      _log "delete" "$FILE_ID" "" "" "error"
      _log_error "delete failed for file_id=$FILE_ID: curl exit $CURL_EXIT"
      echo "ERROR: delete failed (curl exit $CURL_EXIT)" >&2
      exit 1
    }

    _log "delete" "$FILE_ID" "" "${CAST_AGENT_NAME:-}" "success"

    echo "Deleted file_id=$FILE_ID"
    ;;

  *)
    echo "Unknown subcommand: $SUBCOMMAND" >&2
    exit 1
    ;;
esac
