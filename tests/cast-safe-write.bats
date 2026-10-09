#!/usr/bin/env bats
# cast-safe-write.bats — U6b-2a (CAST v10.3.0).
#
# Generators and checks that git hooks run from the INSTALLED ~/.claude/scripts over a repo an
# agent can write to must (1) never write THROUGH a symlink the agent planted (cast_safe_write)
# and (2) never let repo-local git config exec programs (cast_git_safe, incl. the narrow
# CAST_GIT_SAFE_INDEX_FILE opt-in for the index a hook is committing).
#
# Every fixture lives under a temp HOME; every git call strips GIT_*; canaries only `touch` a
# marker. Each exec probe has a CONTROL (the same git command run bare MUST create the marker),
# so a green "marker absent" cannot be a probe that cannot fire. No skip sites in this file: the
# test-skip ledger counts them. The test token is assembled at runtime so fixtures never contain
# it literally (a fixture holding it at line start is parsed as a declaration by bats).

load 'helpers/setup'

_git() { env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE git "$@"; }

_commit() {
  _git -C "$1" -c user.email=test@example.com -c user.name=t -c commit.gpgsign=false commit -q -m "$2"
}

# Copy repo scripts into the simulated installed location (the lib always comes along).
_install() {
  local f
  cp "$REPO/scripts/cast-hook-lib.sh" "$INSTALLED/cast-hook-lib.sh"
  for f in "$@"; do
    cp "$REPO/scripts/$f" "$INSTALLED/$f"
  done
}

# _canary <script> <marker> — executable script that touches <marker>.
_canary() {
  printf '#!/bin/sh\ntouch "%s"\nexit 0\n' "$2" >"$1"
  chmod +x "$1"
}

# _config_append <repo> <text> — write repo config directly (never via a git command).
_config_append() {
  printf '%s\n' "$2" >>"$1/.git/config"
}

# The victim stands in for an installed githook / settings file an attacker wants overwritten.
_mk_victim() {
  mkdir -p "$HOME/.claude/githooks"
  VICTIM="$HOME/.claude/githooks/pre-push"
  printf '#!/bin/sh\n# ORIGINAL HOOK\n' >"$VICTIM"
  cp "$VICTIM" "$HOME/victim.orig"
}

_victim_unchanged() {
  cmp -s "$VICTIM" "$HOME/victim.orig"
}

# A repo whose tracked-file counts clear gen-cast-stats's plausibility floors. Nothing is
# committed: ls-files reads the index, which is all the counters need.
_mk_stats_fixture() {
  local root="$1" i tok
  tok='@te''st'
  mkdir -p "$root"
  _git init -q "$root"
  printf '1.2.3\n' >"$root/VERSION"
  mkdir -p "$root/agents/core" "$root/commands" "$root/skills" "$root/tests" "$root/scripts"
  for i in $(seq 1 22); do printf 'a\n' >"$root/agents/core/a${i}.md"; done
  for i in $(seq 1 12); do printf 'c\n' >"$root/commands/c${i}.md"; done
  for i in $(seq 1 6); do
    mkdir -p "$root/skills/s${i}"
    printf 's\n' >"$root/skills/s${i}/SKILL.md"
  done
  for i in $(seq 1 175); do
    : >"$root/tests/t${i}.bats"
    for _ in 1 2 3 4 5 6; do printf '%s "x" {\n:\n}\n' "$tok" >>"$root/tests/t${i}.bats"; done
  done
  mkdir -p "$root/scripts/migrations"
  for i in $(seq 1 31); do
    printf 'CREATE TABLE IF NOT EXISTS tbl%s (id INTEGER);\n' "$i" >>"$root/scripts/cast-db-init.sh"
  done
  # The table counter greps scripts/migrations/*.sql too; with no match grep exits 2 and, under
  # the generator's pipefail, the whole count collapses to 0.
  printf 'CREATE TABLE IF NOT EXISTS mig1 (id INTEGER);\n' >"$root/scripts/migrations/001.sql"
  _git -C "$root" add -A
}

# gen-cast-stats skips itself under BATS; the real hook run has no BATS_* in its environment.
_run_gen_stats() {
  run env -u BATS_TEST_NAME -u BATS_TEST_FILENAME -u BATS_TMPDIR \
    CAST_REPO_ROOT="$FIX" bash "$INSTALLED/gen-cast-stats.sh"
}

setup() {
  setup_temp_home
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE CAST_REPO_ROOT CLAUDE_SUBPROCESS CAST_GIT_SAFE_INDEX_FILE
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  LIB="$REPO/scripts/cast-hook-lib.sh"
  INSTALLED="$HOME/.claude/scripts"
  FIX="$HOME/fixture-repo"
  mkdir -p "$INSTALLED"
}

teardown() {
  teardown_temp_home
}

# ── cast_safe_write itself ────────────────────────────────────────────────────

# _sw <root> <rel> <content> — cast_safe_write fed <content> on stdin.
_sw() {
  run bash -c 'set -euo pipefail; . "$1"; printf "%s\n" "$4" | cast_safe_write "$2" "$3"' _ "$LIB" "$1" "$2" "$3"
}

@test "cast_safe_write: regular target is written with exact content and mode 0644, no temp left" {
  mkdir -p "$FIX/sub"
  printf 'old\n' >"$FIX/sub/out.json"
  chmod 600 "$FIX/sub/out.json"
  _sw "$FIX" sub/out.json 'new content'
  [ "$status" -eq 0 ]
  [ "$(cat "$FIX/sub/out.json")" = "new content" ]
  [ "$(file_mode "$FIX/sub/out.json")" = "644" ]
  [ -z "$(find "$FIX/sub" -name '.cast-safe-write.*')" ]
}

@test "cast_safe_write: a new (absent) target in an existing dir is created" {
  mkdir -p "$FIX"
  _sw "$FIX" fresh.txt 'hello'
  [ "$status" -eq 0 ]
  [ "$(cat "$FIX/fresh.txt")" = "hello" ]
}

@test "cast_safe_write: symlinked target is refused and the victim is byte-unchanged" {
  _mk_victim
  mkdir -p "$FIX/.github"
  ln -s "$VICTIM" "$FIX/.github/rules-core.manifest"
  _sw "$FIX" .github/rules-core.manifest 'PWNED'
  [ "$status" -eq 2 ]
  [[ "$output" == *"symlink"* ]]
  _victim_unchanged
  [ -L "$FIX/.github/rules-core.manifest" ]
}

@test "cast_safe_write: symlinked parent directory component is refused, nothing lands in the link target" {
  mkdir -p "$FIX" "$HOME/elsewhere"
  ln -s "$HOME/elsewhere" "$FIX/plugin"
  _sw "$FIX" plugin/out.txt 'PWNED'
  [ "$status" -eq 2 ]
  [ ! -e "$HOME/elsewhere/out.txt" ]
  [ -z "$(find "$HOME/elsewhere" -type f)" ]
}

@test "cast_safe_write: target escaping the root via .. is refused" {
  mkdir -p "$FIX/sub"
  _sw "$FIX" sub/../../escape.txt 'PWNED'
  [ "$status" -eq 2 ]
  [ ! -e "$HOME/escape.txt" ]
  _sw "$FIX" ../escape.txt 'PWNED'
  [ "$status" -eq 2 ]
  [ ! -e "$HOME/escape.txt" ]
}

@test "cast_safe_write: absolute, empty and newline-bearing relative targets are refused" {
  mkdir -p "$FIX"
  _sw "$FIX" "$HOME/abs.txt" 'x'
  [ "$status" -eq 2 ]
  [ ! -e "$HOME/abs.txt" ]
  _sw "$FIX" "" 'x'
  [ "$status" -eq 2 ]
  _sw "$FIX" $'a\nb.txt' 'x'
  [ "$status" -eq 2 ]
  _sw relative-root out.txt 'x'
  [ "$status" -eq 2 ]
}

@test "cast_safe_write: a target that is an existing directory is refused" {
  mkdir -p "$FIX/adir"
  _sw "$FIX" adir 'x'
  [ "$status" -eq 2 ]
  [ -d "$FIX/adir" ]
}

@test "cast_safe_write: a hardlink at the target is replaced, never written through" {
  _mk_victim
  mkdir -p "$FIX"
  ln "$VICTIM" "$FIX/linked.txt"
  _sw "$FIX" linked.txt 'new'
  [ "$status" -eq 0 ]
  [ "$(cat "$FIX/linked.txt")" = "new" ]
  _victim_unchanged
}

@test "cast_safe_write: a root reached through a symlink is accepted (CAST_REPO_ROOT may be a symlinked path)" {
  mkdir -p "$FIX"
  ln -s "$FIX" "$HOME/root-link"
  _sw "$HOME/root-link" out.txt 'via link'
  [ "$status" -eq 0 ]
  [ "$(cat "$FIX/out.txt")" = "via link" ]
}

# ── generators run as INSTALLED copies ────────────────────────────────────────

_mk_rules_fixture() {
  mkdir -p "$FIX/rules-core" "$FIX/.github"
  printf 'one\n' >"$FIX/rules-core/a.md"
  printf 'two\n' >"$FIX/rules-core/b.template"
}

@test "gen-rules-manifest: output is exactly sorted sha256sum lines (format unchanged)" {
  _install gen-rules-manifest.sh
  _mk_rules_fixture
  run env CAST_REPO_ROOT="$FIX" bash "$INSTALLED/gen-rules-manifest.sh"
  [ "$status" -eq 0 ]
  (cd "$FIX" && sha256sum rules-core/a.md rules-core/b.template) >"$HOME/expected.manifest"
  cmp "$FIX/.github/rules-core.manifest" "$HOME/expected.manifest"
}

@test "gen-rules-manifest: symlinked manifest target is refused, victim unchanged" {
  _install gen-rules-manifest.sh
  _mk_rules_fixture
  _mk_victim
  ln -s "$VICTIM" "$FIX/.github/rules-core.manifest"
  run env CAST_REPO_ROOT="$FIX" bash "$INSTALLED/gen-rules-manifest.sh"
  [ "$status" -ne 0 ]
  _victim_unchanged
}

@test "gen-rules-manifest: symlinked .github directory is refused, nothing written through it" {
  _install gen-rules-manifest.sh
  mkdir -p "$FIX/rules-core" "$HOME/elsewhere"
  printf 'one\n' >"$FIX/rules-core/a.md"
  ln -s "$HOME/elsewhere" "$FIX/.github"
  run env CAST_REPO_ROOT="$FIX" bash "$INSTALLED/gen-rules-manifest.sh"
  [ "$status" -ne 0 ]
  [ -z "$(find "$HOME/elsewhere" -type f)" ]
}

@test "gen-rules-manifest: a newline-named rules-core file is refused and the existing manifest is untouched" {
  _install gen-rules-manifest.sh
  _mk_rules_fixture
  printf 'OLD MANIFEST\n' >"$FIX/.github/rules-core.manifest"
  printf 'x\n' >"$FIX/rules-core/evil"$'\n'"0000  forged.md"
  run env CAST_REPO_ROOT="$FIX" bash "$INSTALLED/gen-rules-manifest.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"control character"* ]]
  [ "$(cat "$FIX/.github/rules-core.manifest")" = "OLD MANIFEST" ]
}

@test "gen-rules-manifest: a carriage-return-named file is refused" {
  _install gen-rules-manifest.sh
  _mk_rules_fixture
  printf 'x\n' >"$FIX/rules-core/cr"$'\r'".md"
  run env CAST_REPO_ROOT="$FIX" bash "$INSTALLED/gen-rules-manifest.sh"
  [ "$status" -ne 0 ]
  [ ! -s "$FIX/.github/rules-core.manifest" ]
}

@test "gen-rules-manifest: a shell-metacharacter file name is data, never executed" {
  _install gen-rules-manifest.sh
  _mk_rules_fixture
  printf 'x\n' >"$FIX/rules-core"/'zz;touch${IFS}PWNED-EXEC;#.md'
  run env CAST_REPO_ROOT="$FIX" bash "$INSTALLED/gen-rules-manifest.sh"
  [ "$status" -eq 0 ]
  [ ! -e "$FIX/PWNED-EXEC" ]
  [ ! -e "$PWD/PWNED-EXEC" ]
  grep -qF 'rules-core/zz;touch' "$FIX/.github/rules-core.manifest"
}

@test "gen-rules-manifest: without cast-hook-lib.sh beside it, fails closed and writes nothing" {
  cp "$REPO/scripts/gen-rules-manifest.sh" "$INSTALLED/gen-rules-manifest.sh"
  _mk_rules_fixture
  printf 'OLD MANIFEST\n' >"$FIX/.github/rules-core.manifest"
  run env CAST_REPO_ROOT="$FIX" bash "$INSTALLED/gen-rules-manifest.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not loadable"* ]]
  [ "$(cat "$FIX/.github/rules-core.manifest")" = "OLD MANIFEST" ]
}

@test "gen-cast-stats: regular target is written (positive control for the symlink test)" {
  command -v jq >/dev/null
  _install gen-cast-stats.sh cast-stats-lib.sh
  _mk_stats_fixture "$FIX"
  _run_gen_stats
  [ "$status" -eq 0 ]
  [ "$(jq -r .agents "$FIX/cast-stats.json")" = "22" ]
  [ "$(jq -r .test_files "$FIX/cast-stats.json")" = "175" ]
}

@test "gen-cast-stats: symlinked cast-stats.json is refused, victim unchanged" {
  command -v jq >/dev/null
  _install gen-cast-stats.sh cast-stats-lib.sh
  _mk_stats_fixture "$FIX"
  _mk_victim
  ln -s "$VICTIM" "$FIX/cast-stats.json"
  _run_gen_stats
  [ "$status" -ne 0 ]
  _victim_unchanged
}

@test "gen-cast-stats: without cast-hook-lib.sh beside it, fails closed and writes nothing" {
  command -v jq >/dev/null
  cp "$REPO/scripts/gen-cast-stats.sh" "$REPO/scripts/cast-stats-lib.sh" "$INSTALLED/"
  _mk_stats_fixture "$FIX"
  _run_gen_stats
  [ "$status" -ne 0 ]
  [ ! -e "$FIX/cast-stats.json" ]
}

_mk_eco_fixture() {
  mkdir -p "$HOME/eco/cast" "$HOME/eco/cast-thing"
  FIX="$HOME/eco/cast"
  printf '2.5.1\n' >"$HOME/eco/cast-thing/VERSION"
  mkdir -p "$FIX/docs"
  printf '<!-- ECOSYSTEM_START -->\n- https://github.com/ek33450505/cast-thing\n<!-- ECOSYSTEM_END -->\n' >"$FIX/docs/ecosystem.md"
}

@test "gen-ecosystem-versions: regular target is written (positive control)" {
  command -v jq >/dev/null
  _install gen-ecosystem-versions.sh
  _mk_eco_fixture
  run env CAST_REPO_ROOT="$FIX" bash "$INSTALLED/gen-ecosystem-versions.sh"
  [ "$status" -eq 0 ]
  [ "$(jq -r '."cast-thing"' "$FIX/ecosystem-versions.json")" = "2.5.1" ]
}

@test "gen-ecosystem-versions: symlinked ecosystem-versions.json is refused, victim unchanged" {
  command -v jq >/dev/null
  _install gen-ecosystem-versions.sh
  _mk_eco_fixture
  _mk_victim
  ln -s "$VICTIM" "$FIX/ecosystem-versions.json"
  run env CAST_REPO_ROOT="$FIX" bash "$INSTALLED/gen-ecosystem-versions.sh"
  [ "$status" -ne 0 ]
  _victim_unchanged
}

@test "gen-ecosystem-versions: without cast-hook-lib.sh beside it, fails closed and writes nothing" {
  command -v jq >/dev/null
  cp "$REPO/scripts/gen-ecosystem-versions.sh" "$INSTALLED/gen-ecosystem-versions.sh"
  _mk_eco_fixture
  run env CAST_REPO_ROOT="$FIX" bash "$INSTALLED/gen-ecosystem-versions.sh"
  [ "$status" -ne 0 ]
  [ ! -e "$FIX/ecosystem-versions.json" ]
}

@test "gen-plugin: a symlinked output dir is refused, nothing is written through it" {
  _install gen-plugin.sh cast-guard-lib.sh
  mkdir -p "$FIX" "$HOME/elsewhere"
  _git init -q "$FIX"
  printf '1.2.3\n' >"$FIX/VERSION"
  printf 'keep\n' >"$HOME/elsewhere/keep.txt"
  ln -s "$HOME/elsewhere" "$FIX/plugin"
  run env CAST_REPO_ROOT="$FIX" bash "$INSTALLED/gen-plugin.sh" "$FIX/plugin"
  [ "$status" -ne 0 ]
  [[ "$output" == *"symlink"* ]]
  [ "$(cat "$HOME/elsewhere/keep.txt")" = "keep" ]
  [ "$(find "$HOME/elsewhere" -type f | wc -l | tr -d ' ')" = "1" ]
}

@test "gen-plugin: without cast-hook-lib.sh beside it, fails closed" {
  cp "$REPO/scripts/gen-plugin.sh" "$REPO/scripts/cast-guard-lib.sh" "$INSTALLED/"
  mkdir -p "$FIX"
  run env CAST_REPO_ROOT="$FIX" bash "$INSTALLED/gen-plugin.sh" "$HOME/out-plugin"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not loadable"* ]]
  [ ! -e "$HOME/out-plugin" ]
}

# ── fsmonitor / diff.external regression: hook-run git must not exec repo config ──

@test "cast-stats-lib: core.fsmonitor in the repo config is not executed by the stat counters" {
  _install cast-stats-lib.sh
  _mk_stats_fixture "$FIX"
  _canary "$HOME/fsm.sh" "$HOME/FSMARK"
  _config_append "$FIX" "[core]"
  _config_append "$FIX" "	fsmonitor = $HOME/fsm.sh"
  # CONTROL: the same read, run bare, fires the canary.
  _git -C "$FIX" ls-files >/dev/null 2>&1
  [ -e "$HOME/FSMARK" ]
  rm -f "$HOME/FSMARK"
  run bash -c 'CAST_REPO_ROOT="$1"; . "$2/cast-stats-lib.sh"; cast_stat_agents' _ "$FIX" "$INSTALLED"
  [ "$status" -eq 0 ]
  [ "$output" = "22" ]
  [ ! -e "$HOME/FSMARK" ]
}

@test "cast-test-coverage-advisory: core.fsmonitor is not executed by the staged-file diff" {
  _install cast-test-coverage-advisory.sh
  mkdir -p "$FIX/scripts"
  _git init -q "$FIX"
  printf 'x\n' >"$FIX/scripts/x.sh"
  _git -C "$FIX" add scripts/x.sh
  _canary "$HOME/fsm.sh" "$HOME/FSMARK"
  _config_append "$FIX" "[core]"
  _config_append "$FIX" "	fsmonitor = $HOME/fsm.sh"
  # CONTROL
  _git -C "$FIX" diff --cached --name-only >/dev/null 2>&1
  [ -e "$HOME/FSMARK" ]
  rm -f "$HOME/FSMARK"
  run env CAST_REPO_ROOT="$FIX" bash "$INSTALLED/cast-test-coverage-advisory.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"scanned 1 staged file(s)"* ]]
  [ ! -e "$HOME/FSMARK" ]
}

@test "gen-plugin: core.fsmonitor is not executed by its git ls-files calls" {
  _install gen-plugin.sh cast-guard-lib.sh
  mkdir -p "$FIX/scripts"
  _git init -q "$FIX"
  printf '1.2.3\n' >"$FIX/VERSION"
  printf 'x\n' >"$FIX/scripts/x.sh"
  _git -C "$FIX" add -A
  _canary "$HOME/fsm.sh" "$HOME/FSMARK"
  _config_append "$FIX" "[core]"
  _config_append "$FIX" "	fsmonitor = $HOME/fsm.sh"
  # CONTROL
  _git -C "$FIX" ls-files >/dev/null 2>&1
  [ -e "$HOME/FSMARK" ]
  rm -f "$HOME/FSMARK"
  run env CAST_REPO_ROOT="$FIX" bash "$INSTALLED/gen-plugin.sh" "$HOME/out-plugin"
  # Reached the scripts step (the last ls-files call), so the probe covered every call site.
  [[ "$output" == *"Scripts: 1 copied"* ]]
  [ ! -e "$HOME/FSMARK" ]
}

@test "pre-push-ci-check: diff.external in the repo config is not executed by the push diff" {
  _install pre-push-ci-check.sh
  mkdir -p "$FIX"
  _git init -q "$FIX"
  printf 'one\n' >"$FIX/f.txt"
  _git -C "$FIX" add f.txt
  _commit "$FIX" one
  printf 'two\n' >"$FIX/f.txt"
  _git -C "$FIX" add f.txt
  _commit "$FIX" two
  _canary "$HOME/ext.sh" "$HOME/EXTMARK"
  _config_append "$FIX" "[diff]"
  _config_append "$FIX" "	external = $HOME/ext.sh"
  # CONTROL
  _git -C "$FIX" diff HEAD~1 HEAD >/dev/null 2>&1
  [ -e "$HOME/EXTMARK" ]
  rm -f "$HOME/EXTMARK"
  run env CAST_REPO_ROOT="$FIX" bash "$INSTALLED/pre-push-ci-check.sh" </dev/null
  [[ "$output" == *"Scanning"* ]]
  [ ! -e "$HOME/EXTMARK" ]
}

@test "pre-push-ci-check: without cast-hook-lib.sh beside it, fails closed" {
  cp "$REPO/scripts/pre-push-ci-check.sh" "$INSTALLED/pre-push-ci-check.sh"
  mkdir -p "$FIX"
  run env CAST_REPO_ROOT="$FIX" bash "$INSTALLED/pre-push-ci-check.sh" </dev/null
  [ "$status" -ne 0 ]
  [[ "$output" == *"not loadable"* ]]
}

# ── CAST_GIT_SAFE_INDEX_FILE through the stat counters ────────────────────────

@test "cast-stats-lib: a hook's temporary index (GIT_INDEX_FILE inside the git dir) is the one counted" {
  _install cast-stats-lib.sh
  _mk_stats_fixture "$FIX"
  cp "$FIX/.git/index" "$FIX/.git/next-index-77.lock"
  printf 'extra\n' >"$FIX/agents/core/extra.md"
  env GIT_INDEX_FILE="$FIX/.git/next-index-77.lock" git -C "$FIX" add agents/core/extra.md
  run env GIT_INDEX_FILE="$FIX/.git/next-index-77.lock" bash -c 'CAST_REPO_ROOT="$1"; . "$2/cast-stats-lib.sh"; cast_stat_agents' _ "$FIX" "$INSTALLED"
  [ "$status" -eq 0 ]
  [ "$output" = "23" ]
  # Without the temp index the real index still says 22.
  run bash -c 'CAST_REPO_ROOT="$1"; . "$2/cast-stats-lib.sh"; cast_stat_agents' _ "$FIX" "$INSTALLED"
  [ "$output" = "22" ]
}

@test "cast-stats-lib: a GIT_INDEX_FILE outside the git dir is NOT honoured" {
  _install cast-stats-lib.sh
  _mk_stats_fixture "$FIX"
  mkdir -p "$HOME/outside"
  cp "$FIX/.git/index" "$HOME/outside/index"
  printf 'extra\n' >"$FIX/agents/core/extra.md"
  env GIT_INDEX_FILE="$HOME/outside/index" git -C "$FIX" add agents/core/extra.md
  run env GIT_INDEX_FILE="$HOME/outside/index" bash -c 'CAST_REPO_ROOT="$1"; . "$2/cast-stats-lib.sh"; cast_stat_agents' _ "$FIX" "$INSTALLED"
  # Refused (rc 2, git not run): the counter reads 0 — NOT 23 (the outside index) and NOT 22.
  [[ "$output" == *"CAST_GIT_SAFE_INDEX_FILE is not directly inside"* ]]
  [ "${lines[${#lines[@]}-1]}" = "0" ]
}
