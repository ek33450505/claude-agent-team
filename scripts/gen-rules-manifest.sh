#!/bin/bash
set -euo pipefail

# Guard: skip in subprocess
if [[ "${CLAUDE_SUBPROCESS:-}" == "1" ]]; then
  exit 0
fi

# Shared hardened primitives (cast_git_safe, cast_safe_write). FAIL CLOSED: if the lib is not
# loadable beside this script nothing is written (never fall back to a bare `>` redirect or bare
# git). The -r guard matters: on bash 3.2 a bare `source <missing-file>` aborts under set -e.
_CAST_LIB="$(dirname "${BASH_SOURCE[0]}")/cast-hook-lib.sh"
# shellcheck source=cast-hook-lib.sh
if [[ -r "$_CAST_LIB" ]] && source "$_CAST_LIB"; then
  :
else
  echo "gen-rules-manifest: FATAL — cast-hook-lib.sh not loadable beside $0; nothing written" >&2
  exit 1
fi

# Ensure we're at repo root. CAST_REPO_ROOT wins (installed-copy mode: the hook
# passes the repo as data); else resolve from this script's own location, not the
# CWD, through the hardened git (repo-local exec config neutralised). This script only
# reads working-tree files, never the index.
if [[ -n "${CAST_REPO_ROOT+x}" ]]; then
  if [[ "$CAST_REPO_ROOT" != /* || ! -d "$CAST_REPO_ROOT" ]]; then
    echo "gen-rules-manifest: FATAL — CAST_REPO_ROOT must be an absolute path to an existing directory: '${CAST_REPO_ROOT}'" >&2
    exit 1
  fi
  cd "$CAST_REPO_ROOT"
else
  _top="$(cast_git_safe "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)" || {
    echo "gen-rules-manifest: FATAL — could not resolve the repo root" >&2
    exit 1
  }
  cd "$_top"
fi
_ROOT="$PWD"

# Enumerate all rules-core files (both .md and .template) NUL-delimited and REFUSE any name with
# a control character (newline, CR, ...): a name like "a\nDEADBEEF  rules-core/x" would forge
# manifest lines. The check runs under LC_ALL=C so it is byte-exact; `sort` keeps the ambient
# locale so the order is unchanged for normal names.
_files=()
while IFS= read -r -d '' _f; do
  _plain="$(printf '%s' "$_f" | LC_ALL=C tr -d '[:cntrl:]')"
  if [[ "$_plain" != "$_f" ]]; then
    echo "gen-rules-manifest: FATAL — a rules-core file name contains a control character (newline/CR/...); refusing to write the manifest" >&2
    exit 1
  fi
  _files+=("$_f")
done < <(find rules-core -type f \( -name "*.md" -o -name "*.template" \) -print0 | sort -z)
if [[ "${#_files[@]}" -eq 0 ]]; then
  echo "gen-rules-manifest: FATAL — no rules-core files found; nothing written" >&2
  exit 1
fi

# Hash first (a failed sha256sum must not leave a partial manifest), then one atomic safe write
# that refuses a symlinked target / parent (see cast_safe_write).
_out="$(sha256sum "${_files[@]}")"
printf '%s\n' "$_out" | cast_safe_write "$_ROOT" .github/rules-core.manifest

echo "[manifest] regenerated .github/rules-core.manifest with $(wc -l < .github/rules-core.manifest) entries"
