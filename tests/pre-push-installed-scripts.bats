#!/usr/bin/env bats
# pre-push-installed-scripts.bats — U6b-2b-2.
#
# .githooks/pre-push runs in the user's unsandboxed terminal over a repo an agent can write to.
# It must therefore execute ONLY installed scripts (~/.claude/scripts/*, passing the repo as DATA
# via CAST_REPO_ROOT) and must never run a program a repo's own config names (smudge/clean
# filters, core.fsmonitor, config-based hooks, .git/hooks/post-checkout).
#
# Fixture: a repo under a temp HOME whose scripts/ dir holds PLANTED copies of every script the
# hook calls (each touches $MARKERS/repo-<name>), plus INSTALLED stubs under $HOME/.claude/scripts
# (each touches $MARKERS/installed-<name>). A repo marker means the hook executed a repo file.
#
# Isolation: everything lives under a temp HOME (setup_temp_home); every git call strips the
# hook-exported GIT_* variables; programs a planted config names only touch files in $MARKERS.
# No skip sites in this file (the test-skip ledger counts them).

bats_require_minimum_version 1.5.0
load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'
load 'helpers/setup'
load 'helpers/prepush-installed'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
HOOK="$REPO_DIR/.githooks/pre-push"

# Every script the hook runs, with the kind that decides how a stub/plant is written.
SCRIPTS_BASH="pre-push-ci-check.sh gen-cast-stats.sh gen-stats.sh gen-rules-manifest.sh cast-check-skip-ledger.sh cast-lint-bash32-parse.sh pre-push-ubuntu-check.sh"
SCRIPTS_PY="cast-commit-reconcile.py cast-db-contract.py"

_git() { env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE git -c user.email=t@example.com -c user.name=t "$@"; }

# Installed stub for <name>: leaves $MARKERS/installed-<name>, then behaves.
_install_stub() {
  local name="$1" body="${2:-}"
  case "$name" in
    *.py)
      printf '%s\n' '#!/usr/bin/env python3' 'import os, sys' \
        "open(os.path.join(os.environ['MARKERS'], 'installed-$name'), 'w').close()" \
        "print('{\"status\": \"clean\"}')" > "$INSTALLED/$name"
      ;;
    *)
      printf '%s\n' '#!/usr/bin/env bash' "touch \"\$MARKERS/installed-$name\"" "$body" 'exit 0' > "$INSTALLED/$name"
      ;;
  esac
  chmod +x "$INSTALLED/$name"
}

# Planted repo copy of <name>: leaves $MARKERS/repo-<name> if it is ever executed.
_plant_repo_script() {
  local name="$1"
  case "$name" in
    *.py)
      printf '%s\n' '#!/usr/bin/env python3' 'import os' \
        "open(os.path.join(os.environ['MARKERS'], 'repo-$name'), 'w').close()" > "$REPO/scripts/$name"
      ;;
    *)
      printf '%s\n' '#!/usr/bin/env bash' "touch \"\$MARKERS/repo-$name\"" 'exit 0' > "$REPO/scripts/$name"
      ;;
  esac
  chmod +x "$REPO/scripts/$name"
}

# Fixture repo with two commits: C1 (cast-stats.json = old) and C2 = HEAD (cast-stats.json = new).
_mk_repo() {
  local n
  REPO="$HOME/repo"
  mkdir -p "$REPO/scripts" "$REPO/.github"
  _git init -q "$REPO"
  for n in $SCRIPTS_BASH $SCRIPTS_PY; do _plant_repo_script "$n"; done
  printf '# Fixture\n## Installation\n## Agents\n## Hooks\n## Testing\n' > "$REPO/README.md"
  printf 'same\n' > "$REPO/.github/rules-core.manifest"
  printf '* filter=x\n' > "$REPO/.gitattributes"
  printf 'old\n' > "$REPO/cast-stats.json"
  _git -C "$REPO" add -A
  _git -C "$REPO" "com""mit" -q -m c1
  C1="$(_git -C "$REPO" rev-parse HEAD)"
  printf 'new\n' > "$REPO/cast-stats.json"
  _git -C "$REPO" add -A
  _git -C "$REPO" "com""mit" -q -m c2
  C2="$(_git -C "$REPO" rev-parse HEAD)"
}

# Installed stubs for the whole hook, all marker-leaving and exit 0 / clean.
_install_all_stubs() {
  local n
  for n in $SCRIPTS_BASH $SCRIPTS_PY; do _install_stub "$n"; done
  # The manifest generator must reproduce the committed manifest (in sync).
  _install_stub gen-rules-manifest.sh 'printf "same\n" > "$CAST_REPO_ROOT/.github/rules-core.manifest"'
}

# Run the hook in $REPO with every gate ON (ubuntu opt-in included), pushing <sha>.
_run_hook() {
  local sha="$1"
  shift
  run --separate-stderr bash -c '
    cd "$REPO" || exit 1
    printf "refs/heads/main %s refs/heads/main 0000000000000000000000000000000000000000\n" "$1" | \
      CAST_RUN_UBUNTU_PUSH=1 bash "$HOOK"
  ' _ "$sha" "$@"
}

setup() {
  setup_temp_home
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE CAST_REPO_ROOT CLAUDE_SUBPROCESS \
    CAST_SKIP_RECONCILE CAST_SKIP_PII_CHECK CAST_SKIP_STATS_PUSH CAST_SKIP_DB_CONTRACT \
    CAST_SKIP_LEDGER_CHECK CAST_SKIP_RULES_DRIFT CAST_SKIP_README_STRUCTURE CAST_RUN_BATS_PUSH
  seed_prepush_install
  MARKERS="$HOME/markers"
  mkdir -p "$MARKERS"
  export MARKERS
  _mk_repo
  export REPO HOOK
  _install_all_stubs
}

teardown() {
  teardown_temp_home
}

# ── (a) a planted repo script is NOT executed; the installed copy runs ─────────────────────────

@test "(a) planted repo scripts/* are never executed — only the installed copies run" {
  _run_hook "$C2"
  [ "$status" -eq 0 ]
  local n
  for n in $SCRIPTS_BASH $SCRIPTS_PY; do
    # The bash32 lint is Darwin-only by design (INFO-skipped elsewhere); every other step runs.
    if [ "$n" = "cast-lint-bash32-parse.sh" ] && [ "$(uname -s)" != "Darwin" ]; then
      [ ! -e "$MARKERS/repo-$n" ]
      continue
    fi
    [ ! -e "$MARKERS/repo-$n" ] || { echo "repo copy of $n was EXECUTED"; false; }
    [ -e "$MARKERS/installed-$n" ] || { echo "installed copy of $n did not run"; false; }
  done
}

@test "(a) static: the hook names no path under \$REPO_ROOT/scripts" {
  run grep -nE 'REPO_ROOT[}"]*/scripts' "$HOOK"
  [ "$status" -eq 1 ]
}

# ── (b) the stats check runs against the PUSHED sha's tree, via the installed script ───────────

@test "(b) stats check: installed gen-cast-stats.sh sees the pushed SHA's tree in a temp export, not the repo" {
  _install_stub gen-cast-stats.sh '
. "$HOME/.claude/scripts/cast-hook-lib.sh"
cat "$CAST_REPO_ROOT/cast-stats.json" > "$MARKERS/stats-saw"
printf "%s\n" "$CAST_REPO_ROOT" > "$MARKERS/stats-root"
cast_git_safe "$CAST_REPO_ROOT" ls-files > "$MARKERS/stats-ls"
cast_git_safe "$CAST_REPO_ROOT" rev-parse HEAD > "$MARKERS/stats-head"
[ -d "$CAST_REPO_ROOT/.git" ] && touch "$MARKERS/stats-has-own-git"'
  # Push C1 while HEAD / the working tree are at C2 ("new"): the check must see C1's "old".
  _run_hook "$C1"
  [ "$status" -eq 0 ]
  [ "$(cat "$MARKERS/stats-saw")" = "old" ]
  [ "$(cat "$MARKERS/stats-head")" = "$C1" ]
  grep -qx 'cast-stats.json' "$MARKERS/stats-ls"
  [ -e "$MARKERS/stats-has-own-git" ]
  local root
  root="$(cat "$MARKERS/stats-root")"
  [ "$root" != "$REPO" ]
  [[ "$root" != "$REPO"/* ]]
  # The throwaway export is removed afterwards.
  [ ! -d "$root" ]
  # Nothing was registered in the pushed repo (no linked worktree).
  [ "$(_git -C "$REPO" worktree list | wc -l | tr -d ' ')" = "1" ]
}

# ── (c) repo-config exec paths do not fire during the hook ─────────────────────────────────────

# Plant: core.fsmonitor, filter.x smudge/clean (+ .gitattributes '* filter=x', committed), a
# config-based hook, and a .git/hooks/post-checkout — each only touches $MARKERS/<name>.
_plant_exec_config() {
  local prog="$HOME/prog.sh"
  printf '%s\n' '#!/bin/sh' 'touch "$MARKERS/$1"' 'case "$1" in smudge|clean) cat ;; esac' 'exit 0' > "$prog"
  chmod +x "$prog"
  # Written straight into .git/config (what an agent with file-write access would do).
  {
    printf '[core]\n\tfsmonitor = %s fsmonitor\n' "$prog"
    printf '[filter "x"]\n\tsmudge = %s smudge\n\tclean = %s clean\n' "$prog" "$prog"
    printf '[hook "m"]\n\tevent = post-checkout\n\tcommand = %s confighook\n' "$prog"
  } >> "$REPO/.git/config"
  printf '#!/bin/sh\ntouch "$MARKERS/post-checkout"\n' > "$REPO/.git/hooks/post-checkout"
  chmod +x "$REPO/.git/hooks/post-checkout"
}

@test "(c) control: the planted config DOES fire under a plain linked-worktree checkout and a plain status" {
  _plant_exec_config
  _git -C "$REPO" worktree add --detach "$HOME/ctl" "$C1" >/dev/null 2>&1
  _git -C "$REPO" status >/dev/null 2>&1 || true
  [ -e "$MARKERS/smudge" ]
  [ -e "$MARKERS/post-checkout" ]
  [ -e "$MARKERS/fsmonitor" ]
}

@test "(c) planted core.fsmonitor / filter.x.* / config hook / post-checkout: NO marker during the pre-push run" {
  _plant_exec_config
  _run_hook "$C1"
  [ "$status" -eq 0 ]
  local m
  for m in smudge clean fsmonitor confighook post-checkout; do
    [ ! -e "$MARKERS/$m" ] || { echo "repo-config program '$m' ran during the hook"; false; }
  done
  # …and the rules-drift diff (cast_git_safe) and the stats export both actually ran.
  [[ "$output$stderr" == *"rules-core manifest in sync"* ]]
  [[ "$output$stderr" == *"cast-stats.json in sync"* ]]
}

# ── rules-drift through the hardened git + safe restore ────────────────────────────────────────

@test "rules drift: generated manifest differs from HEAD's -> push blocked; working-tree manifest restored" {
  _install_stub gen-rules-manifest.sh 'printf "different\n" > "$CAST_REPO_ROOT/.github/rules-core.manifest"'
  _run_hook "$C2"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"rules-core manifest is out of sync"* ]]
  [ "$(cat "$REPO/.github/rules-core.manifest")" = "same" ]
}

@test "rules drift: manifest not yet committed -> first-time skip, generated file removed afterwards" {
  _git -C "$REPO" rm -q --cached .github/rules-core.manifest
  _git -C "$REPO" "com""mit" -q -m drop-manifest
  rm -f "$REPO/.github/rules-core.manifest"
  C3="$(_git -C "$REPO" rev-parse HEAD)"
  _run_hook "$C3"
  [ "$status" -eq 0 ]
  [[ "$output" == *"first-time run"* ]]
  [ ! -e "$REPO/.github/rules-core.manifest" ]
}

# ── (d) a missing INSTALLED script: gates fail closed, informational steps warn, no repo fallback ──

@test "(d) missing installed reconcile script -> push blocked with the install message; the planted repo copy does NOT run" {
  rm -f "$INSTALLED/cast-commit-reconcile.py"
  _run_hook "$C2"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"installed cast-commit-reconcile.py missing"* ]]
  [[ "$stderr" == *"bash install.sh"* ]]
  [[ "$stderr" == *"CAST_SKIP_RECONCILE=1"* ]]
  [ ! -e "$MARKERS/repo-cast-commit-reconcile.py" ]
}

@test "(d) CAST_SKIP_RECONCILE=1 is still the documented bypass when the reconcile script is missing" {
  rm -f "$INSTALLED/cast-commit-reconcile.py"
  run --separate-stderr bash -c '
    cd "$REPO" || exit 1
    printf "refs/heads/main %s refs/heads/main 0\n" "$1" | CAST_SKIP_RECONCILE=1 bash "$HOOK"
  ' _ "$C2"
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"Skipping commit-provenance reconcile"* ]]
}

@test "(d) every other gate script missing from the install -> fail closed naming it (never a repo fallback)" {
  local n saved
  for n in pre-push-ci-check.sh gen-cast-stats.sh gen-stats.sh cast-db-contract.py cast-check-skip-ledger.sh gen-rules-manifest.sh cast-hook-lib.sh; do
    saved="$HOME/saved-$n"
    mv "$INSTALLED/$n" "$saved"
    rm -f "$MARKERS"/*
    _run_hook "$C2"
    mv "$saved" "$INSTALLED/$n"
    [ "$status" -ne 0 ] || { echo "hook passed with $n missing"; false; }
    [[ "$stderr" == *"installed $n missing"* ]] || { echo "no install message for $n: $stderr"; false; }
    [ -z "$(ls "$MARKERS" | grep '^repo-' || true)" ] || { echo "a repo script ran with $n missing"; false; }
  done
}

@test "(d) a SYMLINKED installed script counts as missing (it could point anywhere)" {
  mv "$INSTALLED/cast-db-contract.py" "$HOME/real-dbc.py"
  ln -s "$HOME/real-dbc.py" "$INSTALLED/cast-db-contract.py"
  _run_hook "$C2"
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"installed cast-db-contract.py missing"* ]]
}

@test "(d) missing installed ubuntu check (informational) warns and the push continues" {
  rm -f "$INSTALLED/pre-push-ubuntu-check.sh"
  _run_hook "$C2"
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"installed pre-push-ubuntu-check.sh missing"* ]]
  [ ! -e "$MARKERS/repo-pre-push-ubuntu-check.sh" ]
}
