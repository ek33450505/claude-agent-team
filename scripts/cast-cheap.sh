#!/usr/bin/env bash
# cast-cheap.sh — local cheap-mode session via ccr + Ollama
# Usage: cast cheap [status|config|check|--help]
# NOT a hook — no CLAUDE_SUBPROCESS guard needed.

set -euo pipefail

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
_log_error() {
    local msg="$1"
    local log_dir="${HOME}/.claude/logs"
    mkdir -p "$log_dir"
    printf "[cast-cheap] ERROR: %s\n" "$msg" >> "${log_dir}/hook-errors.log"
    printf "ERROR: %s\n" "$msg" >&2
}

# ---------------------------------------------------------------------------
# Env / defaults
# ---------------------------------------------------------------------------
CAST_CCR_CONFIG="${CAST_CCR_CONFIG:-${HOME}/.claude-code-router/config.json}"
CAST_OLLAMA_URL="${CAST_OLLAMA_URL:-http://localhost:11434}"

_resolve_template() {
    if [[ -n "${CAST_CHEAP_TEMPLATE:-}" && -f "$CAST_CHEAP_TEMPLATE" ]]; then
        echo "$CAST_CHEAP_TEMPLATE"
        return 0
    fi
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local repo_dir
    repo_dir="$(dirname "$script_dir")"
    local candidates=(
        "${CAST_REPO_DIR:-$repo_dir}/config/cast-ccr-config.json"
        "${HOME}/.claude/config/cast-ccr-config.json"
    )
    for c in "${candidates[@]}"; do
        if [[ -f "$c" ]]; then
            echo "$c"
            return 0
        fi
    done
    return 1
}

# ---------------------------------------------------------------------------
# Model parsing helpers
# ---------------------------------------------------------------------------
_parse_router_model() {
    # Returns the model part of "provider,model" from Router.default
    if [[ ! -f "$CAST_CCR_CONFIG" ]]; then
        echo ""
        return
    fi
    local model=""
    # Prefer python3 JSON parse
    if command -v python3 >/dev/null 2>&1; then
        # Pass the path via env (NOT string interpolation) to avoid code injection.
        model="$(CAST_CCR_CONFIG_PATH="$CAST_CCR_CONFIG" python3 -c "
import json, os, sys
try:
    cfg = json.load(open(os.environ['CAST_CCR_CONFIG_PATH']))
    val = cfg.get('Router', {}).get('default', '')
    parts = val.split(',', 1)
    print(parts[1] if len(parts) > 1 else val)
except Exception:
    sys.exit(1)
" 2>/dev/null || true)"
    fi
    # Grep fallback
    if [[ -z "$model" ]]; then
        model="$(grep -o '"default"[[:space:]]*:[[:space:]]*"[^"]*"' -- "$CAST_CCR_CONFIG" 2>/dev/null \
            | grep -o '"[^"]*"$' | tr -d '"' | cut -d',' -f2 || true)"
    fi
    echo "$model"
}

_ollama_has_model() {
    local model="$1"
    local tags
    tags="$(curl -sf --max-time 3 "${CAST_OLLAMA_URL}/api/tags" 2>/dev/null || true)"
    if [[ -z "$tags" ]]; then
        return 1
    fi
    echo "$tags" | grep -qF "\"$model\"" 2>/dev/null
}

_ollama_reachable() {
    curl -sf --max-time 2 "${CAST_OLLAMA_URL}/api/version" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
_preflight() {
    local ok=0

    # (a) ccr installed?
    if ! command -v ccr >/dev/null 2>&1; then
        printf "FAIL: ccr not found.\n  Install: npm i -g @musistudio/claude-code-router\n" >&2
        ok=1
    fi

    # (b) Ollama reachable — try cast-ollama-ensure.sh first, then re-check
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local ensure_script="${script_dir}/cast-ollama-ensure.sh"
    if [[ -x "$ensure_script" ]]; then
        bash "$ensure_script" 2>/dev/null || true
    fi
    if ! _ollama_reachable; then
        printf "FAIL: Ollama not reachable at %s\n  Start: ollama serve\n" "$CAST_OLLAMA_URL" >&2
        ok=1
    fi

    # (c) ccr config exists?
    if [[ ! -f "$CAST_CCR_CONFIG" ]]; then
        printf "FAIL: ccr config not found: %s\n  Repair: cast cheap config\n" "$CAST_CCR_CONFIG" >&2
        ok=1
    fi

    # (d) model not :cloud?
    if [[ -f "$CAST_CCR_CONFIG" ]]; then
        local model
        model="$(_parse_router_model)"
        if [[ "$model" == *":cloud" ]]; then
            printf "FAIL: configured model '%s' is a :cloud model (leaves the machine).\n  Edit: %s\n" \
                "$model" "$CAST_CCR_CONFIG" >&2
            ok=1
        fi
    fi

    return "$ok"
}

# ---------------------------------------------------------------------------
# Subcommands
# ---------------------------------------------------------------------------
_status() {
    printf "=== cast cheap status ===\n"

    # ccr presence
    if command -v ccr >/dev/null 2>&1; then
        local ver
        ver="$(ccr version 2>/dev/null | head -1 || ccr -v 2>/dev/null | head -1 || echo "unknown")"
        printf "  ccr:     found (%s)\n" "$ver"
    else
        printf "  ccr:     NOT FOUND (install: npm i -g @musistudio/claude-code-router)\n"
    fi

    # Ollama reachability
    if _ollama_reachable; then
        printf "  Ollama:  reachable at %s\n" "$CAST_OLLAMA_URL"
    else
        printf "  Ollama:  NOT REACHABLE at %s (start: ollama serve)\n" "$CAST_OLLAMA_URL"
    fi

    # Config + model
    if [[ -f "$CAST_CCR_CONFIG" ]]; then
        local model
        model="$(_parse_router_model)"
        printf "  config:  %s\n" "$CAST_CCR_CONFIG"
        printf "  model:   %s\n" "${model:-unknown}"

        # Model present in Ollama?
        if [[ -n "$model" ]]; then
            if _ollama_has_model "$model"; then
                printf "  model present in Ollama: YES\n"
            else
                printf "  model present in Ollama: NO (pull: ollama pull %s)\n" "$model"
            fi
        fi

        # Warn on retired / cloud targets
        if grep -Eq 'mlx-local|:8080' "$CAST_CCR_CONFIG" 2>/dev/null; then
            printf "  WARN: config still references the retired mlx-server — run: cast cheap config\n"
        fi
        if [[ "$model" == *":cloud" ]]; then
            printf "  WARN: model '%s' leaves the machine — edit %s\n" "$model" "$CAST_CCR_CONFIG"
        fi
    else
        printf "  config:  NOT FOUND (%s) — run: cast cheap config\n" "$CAST_CCR_CONFIG"
    fi

    return 0
}

_config() {
    local tmpl
    if ! tmpl="$(_resolve_template)"; then
        printf "ERROR: cast-ccr-config.json template not found.\n" >&2
        printf "  Expected locations:\n" >&2
        printf "    \$CAST_REPO_DIR/config/cast-ccr-config.json\n" >&2
        printf "    ~/.claude/config/cast-ccr-config.json\n" >&2
        exit 1
    fi

    local dest_dir
    dest_dir="$(dirname "$CAST_CCR_CONFIG")"
    mkdir -p "$dest_dir"

    if [[ -f "$CAST_CCR_CONFIG" ]]; then
        local bak="${CAST_CCR_CONFIG}.cast.bak"
        cp "$CAST_CCR_CONFIG" "$bak"
        printf "Backed up existing config to: %s\n" "$bak"
    fi

    cp "$tmpl" "$CAST_CCR_CONFIG"
    printf "Installed ccr config: %s\n" "$CAST_CCR_CONFIG"
    printf "  Source template: %s\n" "$tmpl"
    return 0
}

_check() {
    # Quiet one-line verdict for cast doctor
    local issues=()

    if ! command -v ccr >/dev/null 2>&1; then
        issues+=("ccr not installed")
    fi
    if ! _ollama_reachable; then
        issues+=("Ollama not reachable")
    fi
    if [[ ! -f "$CAST_CCR_CONFIG" ]]; then
        issues+=("no ccr config")
    else
        local model
        model="$(_parse_router_model)"
        if [[ "$model" == *":cloud" ]]; then
            issues+=("model is :cloud")
        fi
        if grep -Eq 'mlx-local|:8080' "$CAST_CCR_CONFIG" 2>/dev/null; then
            issues+=("stale mlx-server config")
        fi
    fi

    if [[ ${#issues[@]} -eq 0 ]]; then
        printf "cast cheap: OK (ccr + Ollama ready)\n"
    else
        printf "cast cheap: WARN — %s\n" "$(IFS=', '; echo "${issues[*]}")"
    fi
    return 0
}

_launch() {
    if ! _preflight; then
        exit 1
    fi

    # Ensure ccr server is up
    if ! ccr status >/dev/null 2>&1; then
        printf "Starting ccr server...\n"
        ccr start
    fi

    # Forward any prompt/flags to ccr (e.g. `cast cheap "fix the bug"`)
    exec ccr code "$@"
}

_usage() {
    cat <<'EOF'
cast cheap — local cheap-mode session via ccr + Ollama

USAGE:
  cast cheap                 Launch a local ccr coding session (runs preflight)
  cast cheap status          Show ccr + Ollama health status
  cast cheap config          (Re)generate ccr config from CAST template
  cast cheap check           Quiet one-line health check (used by cast doctor)
  cast cheap --help | -h     Show this help

ENVIRONMENT:
  CAST_CCR_CONFIG      Path to ccr config.json (default: ~/.claude-code-router/config.json)
  CAST_OLLAMA_URL      Ollama API base URL (default: http://localhost:11434)
  CAST_CHEAP_TEMPLATE  Path to CAST ccr config template (default: auto-detect)

NOTE: This is an opt-in whole-session local mode for review/docs/exploration.
      7B models break tool-heavy agentic loops — do not use for complex CAST work.
EOF
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------
case "${1:-}" in
    status)
        shift
        _status
        ;;
    config)
        shift
        _config
        ;;
    check)
        shift
        _check
        ;;
    --help|-h)
        _usage
        ;;
    "")
        _launch
        ;;
    *)
        # Any other args = a prompt/flags for the session → forward to ccr code
        _launch "$@"
        ;;
esac
