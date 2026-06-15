#!/usr/bin/env bash
# try-plugin-isolated.sh — Dev helper: launch Claude Code with the CAST plugin in a
# throwaway sandbox HOME so the real ~/.claude is never touched.
#
# Usage:
#   bash scripts/try-plugin-isolated.sh [extra claude args...]
#
# The sandbox HOME is a fixed, reused path (not a fresh mktemp every run) so repeated
# invocations accumulate state naturally — useful for iterating on plugin behaviour.
# Override with: CAST_PLUGIN_SANDBOX_HOME=/your/path bash scripts/try-plugin-isolated.sh
#
# To clean up the sandbox (the caller decides when — this script never deletes anything):
#   rm -rf "${CAST_PLUGIN_SANDBOX_HOME:-${TMPDIR:-/tmp}/cast-plugin-sandbox}"
#
# macOS keychain auth: nothing to copy — the keychain is process-scoped, not file-based.
# File-based auth (~/.claude/.credentials.json): copied best-effort into the sandbox.

set -euo pipefail

# ---------------------------------------------------------------------------
# 1. Resolve repo root from the script's own location, not from CWD.
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PLUGIN_DIR="${REPO_ROOT}/plugin"

# ---------------------------------------------------------------------------
# 2. Validate the plugin directory exists before doing anything else.
# ---------------------------------------------------------------------------
if [[ ! -d "${PLUGIN_DIR}" ]]; then
  printf 'ERROR: plugin dir not found: %s\n' "${PLUGIN_DIR}" >&2
  printf '       Run: bash scripts/gen-plugin.sh\n' >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# 3. Resolve sandbox HOME (fixed, reused across runs).
# ---------------------------------------------------------------------------
SANDBOX="${CAST_PLUGIN_SANDBOX_HOME:-${TMPDIR:-/tmp}/cast-plugin-sandbox}"
mkdir -p "${SANDBOX}/.claude"

# ---------------------------------------------------------------------------
# 4. Copy file-based credentials into the sandbox (best-effort; macOS keychain
#    auth needs nothing here).
# ---------------------------------------------------------------------------
REAL_CREDS="${HOME}/.claude/.credentials.json"
SANDBOX_CREDS="${SANDBOX}/.claude/.credentials.json"
if [[ -f "${REAL_CREDS}" && ! -f "${SANDBOX_CREDS}" ]]; then
  cp "${REAL_CREDS}" "${SANDBOX_CREDS}" || true
fi

# ---------------------------------------------------------------------------
# 5. Print orientation banner before handing off to claude.
# ---------------------------------------------------------------------------
printf '\n'
printf '╔══════════════════════════════════════════════════════════════╗\n'
printf '║          CAST Plugin — Isolated Sandbox Session              ║\n'
printf '╚══════════════════════════════════════════════════════════════╝\n'
printf '\n'
printf '  Sandbox HOME : %s\n' "${SANDBOX}"
printf '  Plugin dir   : %s\n' "${PLUGIN_DIR}"
printf '\n'
printf '  Your real ~/.claude is UNTOUCHED.\n'
printf '\n'
printf '  Note: --plugin-dir auto-loads the plugin; no /plugin enable\n'
printf '        command is needed. (A marketplace install would need:\n'
printf '        /plugin enable cast@cast)\n'
printf '\n'
printf '  To clean up this sandbox when you are done, delete:\n'
printf '    %s\n' "${SANDBOX}"
printf '\n'

# ---------------------------------------------------------------------------
# 6. Hand off to claude with the sandbox HOME and the plugin dir.
#    Extra args (e.g. --resume, a file path) are passed through.
# ---------------------------------------------------------------------------
exec env HOME="${SANDBOX}" claude --plugin-dir "${PLUGIN_DIR}" "$@"
