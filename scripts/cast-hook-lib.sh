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
#   cast_safe_write()      — writes stdin to <root>/<relative-target> atomically, refusing symlinks
#                            and escapes (generators run from hooks over an agent-writable repo)
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
# exec paths neutralised. stdout/stderr/exit status are git's own EXCEPT: 2 = refused (empty or
# '-'-leading <repo-dir>; a MISSING, EMPTY, '-'-leading or newline-bearing first git arg — callers
# pass the SUBCOMMAND first, since global options like `-c k=v status` would bypass the injection
# below; a subcommand NOT on the ALLOWLIST; or a DENIED FLAG anywhere in the args: --ext-diff
# --textconv --output[=*] --no-index --alternate-refs --ignore-submodules*); 3 = hardening could
# not be established and git was NOT run (fail closed: the config read failed, or no trusted git
# binary: its directory must be owned by root or the current user (uid from /usr/bin/id, NOT $EUID:
# bash 3.2 imports EUID from the environment) and not world-writable, or a `branch` symlink check
# failed/fired, see WHY); 126 from env if the config exceeds ARG_MAX (thousands of filter/hook
# sections, or ONE huge config key name; also fail closed).
# ALLOWLIST (exactly what callers use): status rev-parse rev-list for-each-ref ls-files cherry
# branch diff diff-files diff-index merge-base, plus `worktree` ONLY when its first non-option arg
# is `list`, plus the two STAGING verbs hash-object and update-index under argument constraints
# (STAGING VERBS below). (merge-base: a pure commit-graph read — no index, worktree, diff machinery or
# config-driven program; added so pre-push-ci-check.sh needs no bare git. Lazy fetch is stopped by
# the env below.)
# STAGING VERBS (added U6b-2b for pre-commit's stage-a-regenerated-file step; `git add` is NOT
# allowed: it runs clean filters). hash-object: only `-w`, `--no-filters`, `--` and bare path args
# are accepted (anything else, e.g. --path, --stdin, --stdin-paths, --literally, -t, is refused rc
# 2) and `--no-filters` is ALWAYS injected, so no filter driver or eol conversion runs.
# update-index: only the exact forms `--cacheinfo <mode>,<sha>,<path>` and `--add --cacheinfo
# <mode>,<sha>,<path>` (mode 100644|100755, sha 40 or 64 hex, a non-empty path with no newline);
# everything else (--refresh, --assume-unchanged, --index-info, --stdin, ...) is refused rc 2.
# Both honour CAST_GIT_SAFE_INDEX_FILE below. Unlike plain `git -c core.hooksPath=/dev/null ...`
# they also blank config-based hooks (hook.<name>.enabled=false: an `event = post-index-change`
# config hook fires on update-index otherwise, probed).
# Everything else is refused, because "is a git builtin" is the wrong safety axis: repo config can
# make many builtins exec programs or delete (alias.<x>='!cmd'; help -> man.<tool>.cmd; credential,
# difftool/mergetool, merge drivers, bisect run; gc/prune/repack/maintenance and `worktree
# prune|repair|move|remove` follow an agent-planted symlinked .git/worktrees/<id> and EMPTY its
# target). This also closes `show` / `log -p` / `format-patch`, where diff.<drv>.textconv would
# fire (they are not on the list, so the diff-family flag injection need not cover them).
# git is NEVER resolved from the caller's PATH (a planted ./git, or a git in any agent-writable
# dir on PATH, would win): the first executable of /opt/homebrew/bin/git, /usr/local/bin/git,
# /usr/bin/git whose directory is owned by root or by the invoking user and is NOT world-writable
# is used (an untrusted candidate dir is SKIPPED; group-writable is accepted, so a stock Mac's
# user:admin 775 /opt/homebrew/bin is trusted; Linux/CI: /usr/bin/git); rc 3 if none qualifies.
# git's own children get a SANITISED PATH (empty and non-absolute entries dropped; fallback
# /usr/bin:/bin:/opt/homebrew/bin). --no-pager is always passed (core.pager/pager.<cmd> exec).
# Editors: GIT_EDITOR=: and GIT_SEQUENCE_EDITOR=: are SET (they outrank core.editor /
# sequence.editor, so `branch --edit-description` cannot launch a repo-set editor; merely UNSETTING
# them would fall back to that repo config). Unset: GIT_EXEC_PATH, GIT_PAGER, PAGER,
# GIT_EXTERNAL_DIFF, GIT_SSH, GIT_SSH_COMMAND, GIT_ASKPASS, SSH_ASKPASS, GIT_TEMPLATE_DIR,
# GIT_PROXY_COMMAND, DEVELOPER_DIR (the /usr/bin/git Xcode shim honours it) (plus the
# repo-redirecting GIT_DIR & co.).
# Injected right after the subcommand: status -> --ignore-submodules=all;
# diff|diff-files|diff-index -> --ignore-submodules=all --no-ext-diff --no-textconv.
# Caller-supplied args that would override or bypass those are REFUSED (rc 2, before the
# injection): --ext-diff, --textconv, --output[=*], --no-index, --alternate-refs,
# --ignore-submodules*. Exact match suffices (git diff options take no abbreviations, probed
# 2.56). --no-ext-diff and --no-textconv stay allowed.
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
# GIT_DIR & co. that would override -C (env -u); PATH-resolved `env` (called as /usr/bin/env);
# `branch` (run for every invocation, flags not parsed) deleting or rewriting a file OUTSIDE the
# repo through an agent-planted symlink (git unlinks/appends/rewrites through it): refused (rc 3)
# when /usr/bin/find -P finds any symlink at or under logs, refs, packed-refs, config, reftable or
# worktrees of the git-dir or the common-dir. Only THOSE paths are scanned; a symlink elsewhere
# in .git is not covered.
# INDEX OPT-IN: GIT_INDEX_FILE is stripped (a hook exports the committing worktree's temporary
# index, e.g. <gitdir>/next-index-<pid>.lock for `git commit -a`/`<paths>`, and an ambient value
# could point git anywhere). A caller that must read THAT index sets the shell variable
# CAST_GIT_SAFE_INDEX_FILE (conventionally "${GIT_INDEX_FILE:-}"; empty/unset = no opt-in). It is
# honoured ONLY if, after resolution (a relative value is taken relative to <repo-dir>), it is a
# regular NON-symlink file named index | index.lock | next-index-*.lock whose directory (cd -P /
# pwd -P) is exactly the repo's git-dir or common-dir (both from the same hardened git). Otherwise
# rc 2, git NOT run (fixed message, never echoes the path). Residual: TOCTOU between the check and
# git's open of the file (an agent able to swap the file inside .git).
# The "git dir" is whatever the repo NAMES: a gitfile or a symlinked .git can point at another
# repo, whose own index is then honoured — it only feeds counts / the bundle list / the advisory
# (nothing is written from it).
# Config goes through GIT_CONFIG_COUNT/KEY_i/VALUE_i, NOT -c k=v (a name containing '=' would
# mis-split -c). Fixed entries occupy indices 0-8; enumeration starts at n=9. Locals only, no nested helpers (sourced file). Bash 3.2-safe.
# RESIDUALS (NOT covered): (M1) enumerate-then-blank is a TOCTOU window if an agent can rewrite
# .git/config between the read and the call (the sandbox denies that today); the same window
# applies to the `branch` symlink scan (a symlink swapped in between the find and the git call).
# (M3) a .git file or
# core.worktree can redirect to another repo: MUTATING callers must verify `rev-parse
# --git-common-dir` first and put `--` before refs/paths. `log -p`, `show` and `format-patch`
# are NOT injected: callers must pass --no-ext-diff --no-textconv themselves or
# diff.<drv>.command/textconv will run. `describe --dirty` and `commit -a` still recurse into
# submodules (no flag exists).
cast_git_safe() {
  local dir="${1-}"
  case "$dir" in
    "" | -*) return 2 ;;
  esac
  shift
  # A leading option (-c k=v, --no-pager, ...) would hide the subcommand from the checks below.
  local wt_arg wt_sub=""
  case "${1-}" in
    "" | -* | *$'\n'*) return 2 ;;
    status | rev-parse | rev-list | for-each-ref | ls-files | cherry | branch | diff | diff-files | diff-index | merge-base) ;;
    hash-object | update-index) ;; # argument-constrained below (STAGING VERBS)
    worktree)
      # Only `worktree list`: the first non-option arg after `worktree` is the sub-subcommand.
      for wt_arg in "${@:2}"; do
        case "$wt_arg" in
          -*) continue ;;
        esac
        wt_sub="$wt_arg"
        break
      done
      if [[ "$wt_sub" != "list" ]]; then
        echo "cast_git_safe: 'worktree ${wt_sub}' is not allowed (only 'worktree list'); git NOT run" >&2
        return 2
      fi
      ;;
    *)
      echo "cast_git_safe: '$1' is not allowed; allowed: status rev-parse rev-list for-each-ref ls-files cherry branch diff diff-files diff-index merge-base hash-object update-index, worktree list; git NOT run" >&2
      return 2
      ;;
  esac
  # git: first executable of a FIXED trusted list whose directory is owned by root or by the
  # invoking user and is not world-writable; the caller's PATH is never consulted. Group-writable
  # is fine (Homebrew's /opt/homebrew/bin is user:admin 775 on a single-user Mac; the admin group
  # is trusted there). A candidate in an untrusted dir is SKIPPED, not fatal. ONE stat spawn covers
  # every existing candidate dir (hooks call this often); -L follows a symlinked dir. BSD vs GNU
  # stat is chosen from the builtin $OSTYPE (no spawn). Anything stat cannot report is untrusted.
  local git_candidates=(/opt/homebrew/bin/git /usr/local/bin/git /usr/bin/git)
  local git_bin="" cand seen=0 dirs=() info="" trusted="" d_name d_uid d_mode
  for cand in "${git_candidates[@]}"; do
    [[ -f "$cand" && -x "$cand" ]] || continue
    seen=$((seen + 1))
    dirs+=("${cand%/*}")
  done
  if [[ "$seen" -gt 0 ]]; then
    # Own uid from /usr/bin/id, NOT $EUID (bash 3.2 imports EUID from the environment, so a caller
    # could set EUID=<dir owner>). Failure / non-numeric => no match: only root-owned dirs trusted.
    local self_uid=""
    self_uid="$(/usr/bin/id -u 2>/dev/null)" || self_uid=""
    case "$self_uid" in "" | *[!0-9]*) self_uid="" ;; esac
    if [[ "$OSTYPE" == darwin* ]]; then
      info="$(/usr/bin/stat -L -f '%N %u %Lp' "${dirs[@]}" 2>/dev/null)" || :
    else
      info="$(/usr/bin/stat -L -c '%n %u %a' "${dirs[@]}" 2>/dev/null)" || :
    fi
    while read -r d_name d_uid d_mode; do
      # No =~ here: it would leak BASH_REMATCH into the caller's shell.
      case "$d_uid" in "" | *[!0-9]*) continue ;; esac
      case "$d_mode" in "" | *[!0-7]*) continue ;; esac
      [[ "$d_uid" == 0 || ( -n "$self_uid" && "$d_uid" == "$self_uid" ) ]] || continue
      [[ $((8#$d_mode & 2)) -eq 0 ]] || continue
      trusted="${trusted}"$'\n'"${d_name}"
    done <<<"$info"
    trusted="${trusted}"$'\n'
  fi
  for cand in "${git_candidates[@]}"; do
    [[ -f "$cand" && -x "$cand" ]] || continue
    case "$trusted" in
      *$'\n'"${cand%/*}"$'\n'*)
        git_bin="$cand"
        break
        ;;
    esac
  done
  if [[ -z "$git_bin" ]]; then
    echo "cast_git_safe: no trusted git binary (seen=${seen}; dir must be owned by root or the current user and not world-writable); git NOT run" >&2
    return 3
  fi
  # Caller-supplied flags that re-enable what is disabled below (external diff / textconv programs),
  # write a file (--output), leave the repo (--no-index), or flip the submodule injection are
  # refused. Exact match is enough: git diff options do not accept abbreviations (probed, 2.56).
  # --no-ext-diff / --no-textconv stay allowed. Must run BEFORE the injection below.
  local a_arg
  for a_arg in "${@:2}"; do
    case "$a_arg" in
      --ext-diff | --textconv | --output | --no-index | --alternate-refs | --output=* | --ignore-submodules*)
        echo "cast_git_safe: argument '${a_arg%%=*}' is not allowed; git NOT run" >&2
        return 2
        ;;
    esac
  done
  # STAGING VERBS: constrain the arguments (exact forms only) BEFORE anything is injected.
  local st_arg st_seen_dd=0 st_n=0 st_ci=""
  case "$1" in
    hash-object)
      for st_arg in "${@:2}"; do
        if [[ "$st_seen_dd" -eq 1 ]]; then
          case "$st_arg" in "" | *$'\n'*) st_n=1 ;; esac
          continue
        fi
        case "$st_arg" in
          -w | --no-filters) ;;
          --) st_seen_dd=1 ;;
          "" | -* | *$'\n'*) st_n=1 ;;
        esac
      done
      if [[ "$st_n" -ne 0 ]]; then
        echo "cast_git_safe: hash-object accepts only -w, --no-filters, -- and plain path args; git NOT run" >&2
        return 2
      fi
      ;;
    update-index)
      if [[ "$#" -eq 3 && "$2" == "--cacheinfo" ]]; then
        st_ci="$3"
      elif [[ "$#" -eq 4 && "$2" == "--add" && "$3" == "--cacheinfo" ]]; then
        st_ci="$4"
      fi
      # <mode>,<sha>,<path>: the sha is hex only, the path has no newline (it may contain commas).
      case "$st_ci" in
        100644,* | 100755,*) st_arg="${st_ci#*,}" ;;
        *) st_arg="" ;;
      esac
      case "${st_arg%%,*}" in
        "" | *[!0-9a-f]*) st_arg="" ;;
      esac
      if [[ -n "$st_arg" ]]; then
        st_n="${st_arg%%,*}"
        case "${#st_n}" in 40 | 64) ;; *) st_arg="" ;; esac
        case "${st_arg#*,}" in "" | "$st_arg" | *$'\n'*) st_arg="" ;; esac
      fi
      if [[ -z "$st_arg" ]]; then
        echo "cast_git_safe: update-index accepts only [--add] --cacheinfo <100644|100755>,<hex sha>,<path>; git NOT run" >&2
        return 2
      fi
      ;;
  esac
  # PATH for git's own children: absolute entries only. Locals only; read -a leaves IFS untouched.
  local safe_path="" p parts=()
  IFS=: read -r -a parts <<<"${PATH-}"
  for p in ${parts[@]+"${parts[@]}"}; do
    case "$p" in
      /*) safe_path="${safe_path:+$safe_path:}$p" ;;
    esac
  done
  [[ -n "$safe_path" ]] || safe_path="/usr/bin:/bin:/opt/homebrew/bin"
  local n=9 key name knob cfg rc=0
  # Inherited git env that would override -C, the config below, or exec a program. Never empty, so
  # "${unset_env[@]}" is safe under `set -u` in bash 3.2 (as is env_assignments).
  local unset_env=(
    -u GIT_CONFIG_PARAMETERS -u GIT_CONFIG_COUNT -u GIT_CONFIG_GLOBAL -u GIT_CONFIG_SYSTEM
    -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE -u GIT_COMMON_DIR
    -u GIT_OBJECT_DIRECTORY -u GIT_ALTERNATE_OBJECT_DIRECTORIES -u GIT_NAMESPACE -u GIT_PREFIX
    -u GIT_EXEC_PATH -u GIT_PAGER -u PAGER -u GIT_EXTERNAL_DIFF -u GIT_SSH -u GIT_SSH_COMMAND
    -u GIT_ASKPASS -u SSH_ASKPASS -u GIT_TEMPLATE_DIR -u GIT_PROXY_COMMAND
    -u DEVELOPER_DIR
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
    "GIT_EDITOR=:" "GIT_SEQUENCE_EDITOR=:"
  )
  # --ignore-submodules=all: a submodule's own config can define filter drivers we never
  # enumerate (the env diff.ignoreSubmodules does NOT close this). Harmless if passed twice.
  # --no-ext-diff/--no-textconv: diff.<drv>.command / .textconv are repo-defined programs.
  case "$1" in
    status) set -- "$1" --ignore-submodules=all "${@:2}" ;;
    diff | diff-files | diff-index)
      set -- "$1" --ignore-submodules=all --no-ext-diff --no-textconv "${@:2}"
      ;;
    hash-object) set -- "$1" --no-filters "${@:2}" ;;
  esac
  # Enumerate filter drivers and config hooks from config (a read; executes nothing). name = key
  # minus the "filter."/"hook." prefix minus the last ".<knob>" (it may itself contain '.' or
  # '='); keys with no dot after the prefix (e.g. hook.jobs) are skipped.
  # Fail CLOSED: rc 0 = matches, 1 = none (fine), anything else (e.g. a malformed ambient config,
  # 128) means we cannot know what to blank, so refuse. Plain read, not -z: a config key cannot
  # contain a newline and $(...) cannot carry NUL bytes. `|| rc=$?` keeps the caller's set -e
  # from firing on rc 1.
  cfg="$(/usr/bin/env "${unset_env[@]}" PATH="$safe_path" "$git_bin" -C "$dir" config --name-only --get-regexp '^(filter|hook)\.' 2>/dev/null)" || rc=$?
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
  # `branch` (flags are not parsed; the scan runs for every invocation) unlinks refs and reflogs,
  # appends reflogs and rewrites config, following a symlink an agent planted, so it could delete
  # or modify a file outside the repo. Refuse when any symlink is at or under
  # <git-dir>|<common-dir>/{logs,refs,packed-refs,config,reftable,worktrees}. The dirs
  # come from the same hardened git; anything but exactly two absolute lines fails closed. Fixed
  # messages only (never echo attacker-controlled path bytes). Residual: TOCTOU, see header.
  local idx_in="${CAST_GIT_SAFE_INDEX_FILE-}"
  if [[ "$1" == "branch" || -n "$idx_in" ]]; then
    local gd_out="" gd_line gd_n=0 gd_a="" gd_b="" gd_rc=0 gd_d gd_s gd_p gd_found="" gd_paths=() gd_dirs=()
    local idx_path="" idx_base="" idx_dir="" idx_real="" idx_ok=0
    gd_out="$(GIT_OPTIONAL_LOCKS=0 GIT_TERMINAL_PROMPT=0 GIT_NO_LAZY_FETCH=1 GIT_ALLOW_PROTOCOL=none \
      /usr/bin/env "${unset_env[@]}" PATH="$safe_path" "${env_assignments[@]}" \
      "$git_bin" --no-pager -c core.fsmonitor=false -c core.hooksPath=/dev/null -c log.showSignature=false -c core.untrackedCache=false \
      --no-replace-objects --no-optional-locks -C "$dir" rev-parse --path-format=absolute --git-dir --git-common-dir 2>/dev/null)" || gd_rc=$?
    if [[ "$gd_rc" -ne 0 ]]; then
      echo "cast_git_safe: could not resolve the git dir (branch symlink check / CAST_GIT_SAFE_INDEX_FILE); git NOT run" >&2
      return 3
    fi
    while IFS= read -r gd_line; do
      gd_n=$((gd_n + 1))
      case "$gd_line" in
        /*) ;;
        *) gd_n=99 ;;
      esac
      if [[ "$gd_n" -eq 1 ]]; then
        gd_a="$gd_line"
      elif [[ "$gd_n" -eq 2 ]]; then
        gd_b="$gd_line"
      fi
    done <<<"$gd_out"
    if [[ "$gd_n" -ne 2 ]]; then
      echo "cast_git_safe: unexpected git-dir output (branch symlink check / CAST_GIT_SAFE_INDEX_FILE); git NOT run" >&2
      return 3
    fi
    gd_dirs=("$gd_a")
    [[ "$gd_b" == "$gd_a" ]] || gd_dirs+=("$gd_b")
    if [[ "$1" == "branch" ]]; then
      for gd_d in "${gd_dirs[@]}"; do
        for gd_s in logs refs packed-refs config reftable worktrees; do
          gd_p="${gd_d}/${gd_s}"
          if [[ -e "$gd_p" || -L "$gd_p" ]]; then
            gd_paths+=("$gd_p")
          fi
        done
      done
      # Never run find with no paths (it would scan the cwd).
      if [[ "${#gd_paths[@]}" -gt 0 ]]; then
        gd_rc=0
        gd_found="$(/usr/bin/find -P "${gd_paths[@]}" -type l -print 2>/dev/null)" || gd_rc=$?
        if [[ "$gd_rc" -ne 0 ]]; then
          echo "cast_git_safe: symlink scan under logs/refs/packed-refs/config/reftable/worktrees failed; git NOT run" >&2
          return 3
        fi
        if [[ -n "$gd_found" ]]; then
          echo "cast_git_safe: a symlink exists at or under the repo's logs, refs, packed-refs, config, reftable or worktrees (branch would follow it); git NOT run" >&2
          return 3
        fi
      fi
    fi
    # CAST_GIT_SAFE_INDEX_FILE opt-in: honour a caller-named index ONLY if it is a regular,
    # non-symlink file named index | index.lock | next-index-*.lock sitting DIRECTLY in the
    # git-dir or common-dir (what `git commit -a` / `git commit <paths>` export as
    # GIT_INDEX_FILE). A relative value resolves against <repo-dir>. Anything else: rc 2.
    if [[ -n "$idx_in" ]]; then
      case "$idx_in" in
        /*) idx_path="$idx_in" ;;
        *) idx_path="${dir%/}/${idx_in}" ;;
      esac
      idx_base="${idx_path##*/}"
      case "$idx_base" in
        index | index.lock | next-index-*.lock) ;;
        *)
          echo "cast_git_safe: CAST_GIT_SAFE_INDEX_FILE name is not index, index.lock or next-index-*.lock; git NOT run" >&2
          return 2
          ;;
      esac
      if [[ -L "$idx_path" || ! -f "$idx_path" ]]; then
        echo "cast_git_safe: CAST_GIT_SAFE_INDEX_FILE is not a regular non-symlink file; git NOT run" >&2
        return 2
      fi
      idx_dir="$(cd -P -- "${idx_path%/*}" 2>/dev/null && pwd -P)" || idx_dir=""
      if [[ -n "$idx_dir" ]]; then
        for gd_d in "${gd_dirs[@]}"; do
          idx_real="$(cd -P -- "$gd_d" 2>/dev/null && pwd -P)" || idx_real=""
          if [[ -n "$idx_real" && "$idx_real" == "$idx_dir" ]]; then
            idx_ok=1
          fi
        done
      fi
      if [[ "$idx_ok" -ne 1 ]]; then
        echo "cast_git_safe: CAST_GIT_SAFE_INDEX_FILE is not directly inside the repo's git dir or common dir; git NOT run" >&2
        return 2
      fi
      env_assignments+=("GIT_INDEX_FILE=${idx_dir}/${idx_base}")
    fi
  fi
  GIT_OPTIONAL_LOCKS=0 GIT_TERMINAL_PROMPT=0 GIT_NO_LAZY_FETCH=1 GIT_ALLOW_PROTOCOL=none \
    /usr/bin/env "${unset_env[@]}" PATH="$safe_path" "${env_assignments[@]}" \
    "$git_bin" --no-pager -c core.fsmonitor=false -c core.hooksPath=/dev/null -c log.showSignature=false -c core.untrackedCache=false \
    --no-replace-objects --no-optional-locks -C "$dir" "$@"
}

# cast_safe_write <root> <relative-target> — write STDIN to <root>/<relative-target> without ever
# following an agent-planted symlink. Generators (gen-rules-manifest, gen-cast-stats,
# gen-ecosystem-versions, ...) run from git hooks in the user's unsandboxed terminal over a repo an
# agent can write to: a plain `> file` would write THROUGH a symlink the agent put at the target
# (or at a parent directory) and overwrite an arbitrary user file (e.g. an installed githook).
# Returns 0 on success; 2 = refused, nothing written (stderr names the reason, never the path
# bytes of an attacker-controlled name): empty/non-absolute <root> or non-directory <root>;
# <relative-target> empty, absolute, containing a newline, or having an empty/`.`/`..` component;
# ANY component between <root> and the target (parent dirs included) is a symlink or is not a
# directory; the resolved parent (cd -P / pwd -P) differs from <root>-resolved + the components;
# the target is a symlink; the target exists and is not a regular file. 1 = I/O failure (temp
# file creation, stdin read, chmod or rename failed; the temp file is removed).
# <root> itself MAY be reached through a symlink (it is resolved once with cd -P): CAST_REPO_ROOT
# legitimately names e.g. /tmp/x on macOS, which is /private/tmp/x. The content is staged in a
# mktemp file in the SAME directory (O_EXCL, never follows a planted name), chmod 0644, then
# `mv -f` renames it over the target: rename REPLACES a dir entry (a hardlink or file at the
# target is unlinked, never written through). Missing parent directories are NOT created.
# Locals only, no traps (sourced file), bash 3.2-safe.
# RESIDUAL: TOCTOU between the checks and the rename if an agent swaps a parent directory for a
# symlink in that window; an attacker with that timing can redirect the rename (not a write
# through an existing file) into a directory the user can write, and the mktemp temp file itself
# can land in a swapped-in directory (probed: ~0.27% of race iterations). There is NO overwrite
# of, and no write through, an existing file in either case.
cast_safe_write() {
  local root="${1-}" rel="${2-}"
  local root_real cur comp rest tmp parent_real="" dest rc=0
  case "$root" in
    /*) ;;
    *)
      echo "cast_safe_write: <root> must be an absolute path; nothing written" >&2
      return 2
      ;;
  esac
  root_real="$(cd -P -- "$root" 2>/dev/null && pwd -P)" || root_real=""
  if [[ -z "$root_real" ]]; then
    echo "cast_safe_write: <root> is not a directory; nothing written" >&2
    return 2
  fi
  case "$rel" in
    "" | /* | *$'\n'* | *$'\r'*)
      echo "cast_safe_write: invalid <relative-target>; nothing written" >&2
      return 2
      ;;
  esac
  # Walk the components: reject ''/./.. and any symlink / non-directory above the final name.
  cur="$root_real"
  rest="$rel"
  while [[ "$rest" == */* ]]; do
    comp="${rest%%/*}"
    rest="${rest#*/}"
    case "$comp" in
      "" | . | ..)
        echo "cast_safe_write: <relative-target> has an empty, '.' or '..' component; nothing written" >&2
        return 2
        ;;
    esac
    cur="${cur}/${comp}"
    if [[ -L "$cur" || ! -d "$cur" ]]; then
      echo "cast_safe_write: a parent component of the target is a symlink or not a directory; nothing written" >&2
      return 2
    fi
  done
  case "$rest" in
    "" | . | ..)
      echo "cast_safe_write: <relative-target> has no file name; nothing written" >&2
      return 2
      ;;
  esac
  parent_real="$(cd -P -- "$cur" 2>/dev/null && pwd -P)" || parent_real=""
  if [[ -z "$parent_real" || "$parent_real" != "$cur" ]]; then
    echo "cast_safe_write: the target's parent resolves outside the expected path; nothing written" >&2
    return 2
  fi
  dest="${cur}/${rest}"
  if [[ -L "$dest" ]]; then
    echo "cast_safe_write: the target is a symlink; nothing written" >&2
    return 2
  fi
  if [[ -e "$dest" && ! -f "$dest" ]]; then
    echo "cast_safe_write: the target exists and is not a regular file; nothing written" >&2
    return 2
  fi
  tmp="$(mktemp "${cur}/.cast-safe-write.XXXXXX" 2>/dev/null)" || tmp=""
  if [[ -z "$tmp" ]]; then
    echo "cast_safe_write: could not create a temp file beside the target; nothing written" >&2
    return 1
  fi
  cat >"$tmp" 2>/dev/null || rc=1
  if [[ "$rc" -eq 0 ]]; then
    chmod 0644 "$tmp" 2>/dev/null || rc=1
  fi
  if [[ "$rc" -eq 0 ]]; then
    mv -f "$tmp" "$dest" 2>/dev/null || rc=1
  fi
  if [[ "$rc" -ne 0 ]]; then
    rm -f "$tmp" 2>/dev/null || true
    echo "cast_safe_write: I/O failure writing the target; nothing written" >&2
    return 1
  fi
  return 0
}
