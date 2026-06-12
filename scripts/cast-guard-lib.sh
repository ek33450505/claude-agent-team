#!/usr/bin/env bash
# cast-guard-lib.sh — Shared blast-radius write guard for CAST destructive operations.
#
# SOURCED library — must not alter caller shell options (no set -euo pipefail here).
# Source once at the top of any script that deletes files:
#
#   source "${CAST_SCRIPTS_DIR}/cast-guard-lib.sh" 2>/dev/null || \
#     source "$(dirname "$0")/cast-guard-lib.sh" 2>/dev/null || true
#
# Usage:
#   cast_declare_blast_radius "/private/tmp/cast-swarm-" "/tmp/cast-swarm-"
#   cast_safe_rm "$target_dir"

# Internal: array of declared blast-radius prefixes.
# Named with _CAST_GUARD_ prefix to avoid collisions with caller variables.
# Reset on each source so each script gets a clean state.
_CAST_GUARD_BLAST_RADIUS=()

# cast_declare_blast_radius PATH...
#
# Register one or more allowed root prefixes. Prefix-match semantics:
# a path is in-radius if its canonicalized form STARTS WITH a registered prefix
# and is NOT EQUAL to that prefix (i.e., strictly inside).
#
# Prefixes are canonicalized at registration time (realpath of parent + basename)
# so that /tmp symlink aliases (macOS: /tmp → /private/tmp) are resolved once.
# Trailing slash is preserved if supplied, so "/path/to/dir/" means "any path
# strictly inside /path/to/dir/".
#
# Multiple calls append to the list.
cast_declare_blast_radius() {
  local prefix canonical_prefix
  for prefix in "$@"; do
    # Determine whether the prefix ends with '/'
    local _has_trailing_slash=0
    [[ "$prefix" == */ ]] && _has_trailing_slash=1

    local _prefix_stripped="${prefix%/}"

    if [[ -d "$_prefix_stripped" ]]; then
      # Existing directory: realpath resolves symlinks (e.g. /tmp → /private/tmp)
      canonical_prefix="$(realpath "$_prefix_stripped" 2>/dev/null)" || canonical_prefix="$_prefix_stripped"
    else
      # Non-directory (e.g. /private/tmp/cast-swarm- string prefix):
      # canonicalize parent dir and re-append basename
      local _pdir _pbase _pdir_canon
      _pdir="$(dirname "$_prefix_stripped")"
      _pbase="$(basename "$_prefix_stripped")"
      _pdir_canon="$(realpath "$_pdir" 2>/dev/null)" || _pdir_canon="$_pdir"
      canonical_prefix="${_pdir_canon}/${_pbase}"
    fi

    # Re-apply trailing slash if original had one
    [[ "$_has_trailing_slash" -eq 1 ]] && canonical_prefix="${canonical_prefix}/"

    _CAST_GUARD_BLAST_RADIUS+=("$canonical_prefix")
  done
}

# cast_safe_rm PATH
#
# Remove PATH recursively only if ALL safety checks pass:
#   1. No blast radius declared → FATAL (fail-closed)
#   2. Canonicalize PATH via realpath; handle non-existent targets by
#      canonicalizing the parent directory + appending basename
#   3. Hard deny-list (checked regardless of declaration):
#        a. canonical == "/"
#        b. canonical == real user HOME
#        c. canonical == $HOME/.claude
#        d. canonical == parent directory of any declared blast-radius prefix
#   4. Canonical path must START WITH a declared prefix AND NOT EQUAL it
#      (symlink escapes are caught here because realpath resolves symlinks)
#
# On refusal:
#   Prints "FATAL [cast_safe_rm]: refusing '<path>' — <reason>" to stderr,
#   returns 1. The target is never touched.
#
# On pass:
#   Executes rm -rf on the canonicalized path.
cast_safe_rm() {
  local path="$1"
  local canonical

  # Check 1: fail-closed — no blast radius declared
  if [[ "${#_CAST_GUARD_BLAST_RADIUS[@]}" -eq 0 ]]; then
    echo "FATAL [cast_safe_rm]: refusing '${path}' — no blast radius declared (fail-closed)" >&2
    return 1
  fi

  # Canonicalize the path.
  # If the target exists (or is a symlink), realpath resolves it fully.
  # If the target does not exist, canonicalize the parent + append basename.
  if [[ -e "$path" || -L "$path" ]]; then
    canonical="$(realpath "$path" 2>/dev/null)" || {
      echo "FATAL [cast_safe_rm]: refusing '${path}' — realpath failed" >&2
      return 1
    }
  else
    local _parent _basename _parent_canonical
    _parent="$(dirname "$path")"
    _basename="$(basename "$path")"
    _parent_canonical="$(realpath "$_parent" 2>/dev/null)" || {
      echo "FATAL [cast_safe_rm]: refusing '${path}' — could not canonicalize parent '${_parent}'" >&2
      return 1
    }
    canonical="${_parent_canonical}/${_basename}"
  fi

  # Hard deny #1: filesystem root
  if [[ "$canonical" == "/" ]]; then
    echo "FATAL [cast_safe_rm]: refusing '${path}' — canonical path is filesystem root" >&2
    return 1
  fi

  # Hard deny #2: real user home
  local _real_home
  _real_home="$(realpath "$HOME" 2>/dev/null)" || _real_home="$HOME"
  if [[ "$canonical" == "$_real_home" ]]; then
    echo "FATAL [cast_safe_rm]: refusing '${path}' — canonical path is user home directory" >&2
    return 1
  fi

  # Hard deny #3: $HOME/.claude
  local _claude_dir="${_real_home}/.claude"
  if [[ "$canonical" == "$_claude_dir" ]]; then
    echo "FATAL [cast_safe_rm]: refusing '${path}' — canonical path is \$HOME/.claude" >&2
    return 1
  fi

  # Hard deny #4: parent directory of any declared blast-radius prefix
  local _prefix _prefix_parent
  for _prefix in "${_CAST_GUARD_BLAST_RADIUS[@]}"; do
    _prefix_parent="$(dirname "$_prefix")"
    if [[ "$canonical" == "$_prefix_parent" ]]; then
      echo "FATAL [cast_safe_rm]: refusing '${path}' — canonical path '${canonical}' equals parent of declared blast radius '${_prefix}'" >&2
      return 1
    fi
  done

  # Prefix check: canonical must START WITH a declared prefix AND NOT EQUAL it.
  # Realpath resolves symlinks, so a symlink inside the radius that points outside
  # will have its resolved path fail this check — symlink escapes are caught here.
  local _matched=0
  for _prefix in "${_CAST_GUARD_BLAST_RADIUS[@]}"; do
    if [[ "$canonical" == "${_prefix}"* && "$canonical" != "$_prefix" ]]; then
      _matched=1
      break
    fi
  done

  if [[ "$_matched" -eq 0 ]]; then
    echo "FATAL [cast_safe_rm]: refusing '${path}' — '${canonical}' is outside declared blast radius" >&2
    return 1
  fi

  # All checks passed — remove the canonicalized path
  rm -rf "$canonical"
}
