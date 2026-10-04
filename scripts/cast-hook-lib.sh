#!/usr/bin/env bash
# cast-hook-lib.sh — Shared boilerplate for CAST hook scripts
#
# Provides small functions extracted from the ~19-24 hook scripts that
# duplicate the same lines verbatim:
#   cast_hook_read_stdin() — sets INPUT from stdin (never fails on empty/closed stdin)
#   cast_hook_db_path()    — sets DB_PATH from CAST_DB_PATH, falling back to ~/.claude/cast.db
#   cast_git_safe()        — runs git in a repo with the known repo-config exec paths
#                            neutralised (fsmonitor, filter drivers, hooks incl. config hooks,
#                            gpg, lazy fetch, submodule filters); see its comment for residuals
#
# Usage:
#   source "$(dirname "$0")/cast-hook-lib.sh"   # or full path
#   cast_hook_read_stdin   # sets $INPUT
#   cast_hook_db_path      # sets $DB_PATH
#   cast_git_safe "$repo" status --porcelain   # git's own stdout/stderr/exit status
#
# The first two assign into the caller's shell (no subshell escape) since
# this file is sourced, not executed — matching the inlined pattern exactly.
# cast_git_safe uses locals only and leaves the caller's variables untouched.

# Guard: source-safe, no side effects on re-source.
if [[ -n "${_CAST_HOOK_LIB_LOADED:-}" ]]; then
  return 0 2>/dev/null || true
fi
_CAST_HOOK_LIB_LOADED=1

cast_hook_read_stdin() {
  INPUT="$(cat 2>/dev/null || true)"
}

cast_hook_db_path() {
  DB_PATH="${CAST_DB_PATH:-${HOME}/.claude/cast.db}"
}

# cast_git_safe <repo-dir> <git-args...> — run git against <repo-dir> with the KNOWN repo-config
# exec paths neutralised. stdout/stderr/exit status are git's own EXCEPT: 2 = bad args (empty or
# '-'-leading <repo-dir>; a MISSING or EMPTY first git arg; or a first git arg starting with '-':
# callers pass the SUBCOMMAND first, since global options like `-c k=v status` would bypass the
# injection below); 3 = the hardening config read failed, so hardening could not be established
# and git was NOT run (fail closed); 126 from env if the config exceeds ARG_MAX (thousands of
# filter/hook sections, or ONE huge config key name; also fail closed). The first git arg must be
# a git BUILTIN subcommand: a repo-defined alias would be expanded by git under repo control.
# Injected right after the subcommand: status -> --ignore-submodules=all;
# diff|diff-files|diff-index -> --ignore-submodules=all --no-ext-diff --no-textconv.
# WHY: hooks and launchd jobs run OUTSIDE the Bash sandbox over repos an agent can write to, and
# repo-local config can make git exec programs. Neutralised: core.fsmonitor; filter.<drv>.* (each
# driver found in config); core.hooksPath AND config-based hooks (hook.<name>.enabled=false, git
# 2.54+; hooksPath does not gate them); gpg.program via log.showSignature AND commit/tag/push
# gpgSign=false; lazy fetch through a promisor remote (GIT_NO_LAZY_FETCH=1 +
# GIT_ALLOW_PROTOCOL=none are the load-bearing defence, probe 2026-10-04; the -c flags are
# belt-and-braces); filters defined in a submodule's OWN config (--ignore-submodules=all);
# diff.<drv>.command and textconv (--no-ext-diff --no-textconv, diff family only); implicit
# `git gc --auto` / `maintenance run --auto` (gc.auto=0, maintenance.auto=false: gc runs
# `git worktree prune`, which follows an agent-planted symlinked .git/worktrees/<id> and EMPTIES
# its target; gc.worktreePruneExpire=never does NOT stop it, probed 2026-10-04); inherited
# GIT_DIR & co. that would override -C (env -u); PATH-resolved `env` (called as /usr/bin/env).
# Config goes through GIT_CONFIG_COUNT/KEY_i/VALUE_i, NOT -c k=v (a name containing '=' would
# mis-split -c). Fixed entries occupy indices 0-8; enumeration starts at n=9. Locals only, no nested helpers (sourced file). Bash 3.2-safe.
# RESIDUALS (NOT covered): (M1) enumerate-then-blank is a TOCTOU window if an agent can rewrite
# .git/config between the read and the call (the sandbox denies that today). (M3) a .git file or
# core.worktree can redirect to another repo: MUTATING callers must verify `rev-parse
# --git-common-dir` first and put `--` before refs/paths. `log -p`, `show` and `format-patch`
# are NOT injected: callers must pass --no-ext-diff --no-textconv themselves or
# diff.<drv>.command/textconv will run. `describe --dirty` and `commit -a` still recurse into
# submodules (no flag exists), and a caller-supplied --ignore-submodules=none overrides the
# injection.
cast_git_safe() {
  local dir="${1-}"
  case "$dir" in
    "" | -*) return 2 ;;
  esac
  shift
  # A leading option (-c k=v, --no-pager, ...) would hide the subcommand from the injection below.
  # --ignore-submodules=all: a submodule's own config can define filter drivers we never
  # enumerate (the env diff.ignoreSubmodules does NOT close this). Harmless if passed twice.
  # --no-ext-diff/--no-textconv: diff.<drv>.command / .textconv are repo-defined programs.
  case "${1-}" in
    "" | -*) return 2 ;;
    status) set -- "$1" --ignore-submodules=all "${@:2}" ;;
    diff | diff-files | diff-index)
      set -- "$1" --ignore-submodules=all --no-ext-diff --no-textconv "${@:2}"
      ;;
  esac
  local n=9 key name knob cfg rc=0
  # Inherited git env that would override -C or the config below. Never empty, so
  # "${unset_env[@]}" is safe under `set -u` in bash 3.2 (as is env_assignments).
  local unset_env=(
    -u GIT_CONFIG_PARAMETERS -u GIT_CONFIG_COUNT -u GIT_CONFIG_GLOBAL -u GIT_CONFIG_SYSTEM
    -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE -u GIT_COMMON_DIR
    -u GIT_OBJECT_DIRECTORY -u GIT_ALTERNATE_OBJECT_DIRECTORIES -u GIT_NAMESPACE -u GIT_PREFIX
  )
  local env_assignments=(
    "GIT_CONFIG_KEY_0=core.fsmonitor" "GIT_CONFIG_VALUE_0=false"
    "GIT_CONFIG_KEY_1=core.untrackedCache" "GIT_CONFIG_VALUE_1=false"
    "GIT_CONFIG_KEY_2=core.hooksPath" "GIT_CONFIG_VALUE_2=/dev/null"
    "GIT_CONFIG_KEY_3=log.showSignature" "GIT_CONFIG_VALUE_3=false"
    "GIT_CONFIG_KEY_4=commit.gpgSign" "GIT_CONFIG_VALUE_4=false"
    "GIT_CONFIG_KEY_5=tag.gpgSign" "GIT_CONFIG_VALUE_5=false"
    "GIT_CONFIG_KEY_6=push.gpgSign" "GIT_CONFIG_VALUE_6=false"
    "GIT_CONFIG_KEY_7=gc.auto" "GIT_CONFIG_VALUE_7=0"
    "GIT_CONFIG_KEY_8=maintenance.auto" "GIT_CONFIG_VALUE_8=false"
  )
  # Enumerate filter drivers and config hooks from config (a read; executes nothing). name = key
  # minus the "filter."/"hook." prefix minus the last ".<knob>" (it may itself contain '.' or
  # '='); keys with no dot after the prefix (e.g. hook.jobs) are skipped.
  # Fail CLOSED: rc 0 = matches, 1 = none (fine), anything else (e.g. a malformed ambient config,
  # 128) means we cannot know what to blank, so refuse. Plain read, not -z: a config key cannot
  # contain a newline and $(...) cannot carry NUL bytes. `|| rc=$?` keeps the caller's set -e
  # from firing on rc 1.
  cfg="$(/usr/bin/env "${unset_env[@]}" git -C "$dir" config --name-only --get-regexp '^(filter|hook)\.' 2>/dev/null)" || rc=$?
  if [[ "$rc" -gt 1 ]]; then
    echo "cast_git_safe: hardening config read failed (rc=$rc); git NOT run" >&2
    return 3
  fi
  while IFS= read -r key; do
    case "$key" in
      filter.*) name="${key#filter.}" ;;
      hook.*) name="${key#hook.}" ;;
      *) continue ;;
    esac
    [[ "$name" == *.* ]] || continue
    name="${name%.*}"
    case "$key" in
      filter.*)
        for knob in clean smudge process; do
          env_assignments+=("GIT_CONFIG_KEY_${n}=filter.${name}.${knob}" "GIT_CONFIG_VALUE_${n}=")
          n=$((n + 1))
        done
        env_assignments+=("GIT_CONFIG_KEY_${n}=filter.${name}.required" "GIT_CONFIG_VALUE_${n}=false")
        ;;
      *)
        env_assignments+=("GIT_CONFIG_KEY_${n}=hook.${name}.enabled" "GIT_CONFIG_VALUE_${n}=false")
        ;;
    esac
    n=$((n + 1))
  done < <(printf '%s\n' "$cfg")
  # Explicit count with keys from index 0: an inherited GIT_CONFIG_COUNT cannot add entries.
  env_assignments+=("GIT_CONFIG_COUNT=${n}")
  GIT_OPTIONAL_LOCKS=0 GIT_TERMINAL_PROMPT=0 GIT_NO_LAZY_FETCH=1 GIT_ALLOW_PROTOCOL=none \
    /usr/bin/env "${unset_env[@]}" "${env_assignments[@]}" \
    git -c core.fsmonitor=false -c core.hooksPath=/dev/null -c log.showSignature=false -c core.untrackedCache=false \
    --no-replace-objects --no-optional-locks -C "$dir" "$@"
}
