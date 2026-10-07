#!/usr/bin/env bats
# cast-repo-root-resolution.bats — U6b-1 (CAST v10.3.0).
#
# Scripts run from an INSTALLED copy (~/.claude/scripts/<name>) must operate on the repo named
# by CAST_REPO_ROOT (passed as data by the hooks), not on the repo their own location implies
# (which would be ~/.claude). Without CAST_REPO_ROOT they keep their own-location behaviour,
# but never inherit GIT_DIR/GIT_WORK_TREE from a git-hook environment (S3c-15).
#
# All fixtures live under a temp HOME; every git call strips GIT_* so a run from inside a hook
# (where git exports GIT_DIR) can never touch the real repo. No skip sites in this file: the
# test-skip ledger counts them.

load 'helpers/setup'

# Run git with the hook-exported repo variables removed.
_git() { env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE git "$@"; }

_mk_repo() {
  mkdir -p "$1"
  _git init -q "$1"
}

# Copy repo scripts into the simulated installed location.
_install() {
  local f
  # The installed scripts source cast-hook-lib.sh from their own directory and FAIL CLOSED
  # without it, so the lib is part of every simulated install.
  cp "$REPO/scripts/cast-hook-lib.sh" "$INSTALLED/cast-hook-lib.sh"
  for f in "$@"; do
    cp "$REPO/scripts/$f" "$INSTALLED/$f"
  done
}

# A fixture whose skip ledger is in sync: one skip call site in one file.
# The skip token is assembled at runtime so THIS file adds no skip site to the real ledger.
_mk_ledger_fixture() {
  local root="$1" tok="sk"
  mkdir -p "$root/tests" "$root/docs"
  printf '  %sip "why"\n' "$tok" >"$root/tests/fx.bats"
  printf '**Total call sites: 1** across 1 files\n' >"$root/docs/test-skip-ledger.md"
}

setup() {
  setup_temp_home
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE CAST_REPO_ROOT CLAUDE_SUBPROCESS
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  INSTALLED="$HOME/.claude/scripts"
  FIX="$HOME/fixture-repo"
  OTHER="$HOME/other-repo"
  UNRELATED="$HOME/unrelated-cwd"
  mkdir -p "$INSTALLED" "$UNRELATED"
  _mk_repo "$FIX"
  _mk_repo "$OTHER"
}

teardown() {
  teardown_temp_home
}

# ── (a) installed copy + CAST_REPO_ROOT operates on that root ──────────────────

@test "skip-ledger: installed copy with CAST_REPO_ROOT checks the named repo from an unrelated cwd" {
  _install cast-check-skip-ledger.sh
  _mk_ledger_fixture "$FIX"
  cd "$UNRELATED"
  CAST_REPO_ROOT="$FIX" run bash "$INSTALLED/cast-check-skip-ledger.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK: skip ledger in sync — 1 call sites across 1 files"* ]]
}

@test "skip-ledger: installed copy WITHOUT CAST_REPO_ROOT keeps own-location resolution (not a repo -> FATAL)" {
  _install cast-check-skip-ledger.sh
  _mk_ledger_fixture "$FIX"
  cd "$FIX"
  run bash -c 'bash "$1" 2>&1' _ "$INSTALLED/cast-check-skip-ledger.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"is not inside a git repository"* ]]
}

@test "gen-rules-manifest: installed copy with CAST_REPO_ROOT writes the manifest into the named repo only" {
  _install gen-rules-manifest.sh
  mkdir -p "$FIX/rules-core" "$FIX/.github"
  echo "rule body" >"$FIX/rules-core/a.md"
  cd "$UNRELATED"
  CAST_REPO_ROOT="$FIX" run bash "$INSTALLED/gen-rules-manifest.sh"
  [ "$status" -eq 0 ]
  grep -q 'rules-core/a.md' "$FIX/.github/rules-core.manifest"
  [ ! -e "$UNRELATED/.github" ]
  [ ! -e "$HOME/.claude/.github" ]
}

@test "hook-wiring lint: installed copy with CAST_REPO_ROOT reads the named repo's managed-settings.d" {
  _install cast-lint-hook-wiring.py
  mkdir -p "$FIX/managed-settings.d"
  cat >"$FIX/managed-settings.d/dup.json" <<'JSON'
{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"bash ~/.claude/scripts/foo-guard.sh"},{"type":"command","command":"bash ~/.claude/scripts/foo-guard.sh"}]}]}}
JSON
  cd "$UNRELATED"
  CAST_REPO_ROOT="$FIX" run /usr/bin/python3 "$INSTALLED/cast-lint-hook-wiring.py"
  [ "$status" -eq 1 ]
  [[ "$output" == *"foo-guard.sh"* ]]
  [[ "$output" == *"$FIX/managed-settings.d/dup.json"* ]]
}

@test "byte-budget lint: installed copy with CAST_REPO_ROOT measures the named repo's rules-core" {
  _install cast-lint-byte-budget.sh
  mkdir -p "$FIX/rules-core"
  echo "hello" >"$FIX/rules-core/a.md"
  cd "$UNRELATED"
  CAST_REPO_ROOT="$FIX" run bash "$INSTALLED/cast-lint-byte-budget.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK [lint-byte-budget]: 6 bytes"* ]]
}

@test "cast-stats-lib: installed copy with CAST_REPO_ROOT counts the named repo's tracked agents" {
  _install cast-stats-lib.sh
  mkdir -p "$FIX/agents/core"
  echo a >"$FIX/agents/core/one.md"
  echo b >"$FIX/agents/core/two.md"
  mkdir -p "$FIX/tests"
  # Two test cases in one file; the marker token is assembled at runtime (fixtures never
  # contain it literally).
  printf '@%s "a" {\n}\n@%s "b" {\n}\n' test test >"$FIX/tests/fx.bats"
  _git -C "$FIX" add agents tests
  cd "$UNRELATED"
  CAST_REPO_ROOT="$FIX" run bash -c 'source "$1"; echo "root=$CAST_STATS_REPO_ROOT"; echo "agents=$(cast_stat_agents)"; echo "tests=$(cast_stat_tests)"; echo "files=$(cast_stat_test_files)"' _ "$INSTALLED/cast-stats-lib.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"root=$FIX"* ]]
  [[ "$output" == *"agents=2"* ]]
  [[ "$output" == *"tests=2"* ]]
  [[ "$output" == *"files=1"* ]]
}

@test "cast-db-contract: CAST_REPO_ROOT moves REPO_ROOT and the scanned scripts dir to the named repo" {
  _install cast-db-contract.py
  mkdir -p "$FIX/scripts"
  cd "$UNRELATED"
  CAST_REPO_ROOT="$FIX" run /usr/bin/python3 -c '
import importlib.util, sys
spec = importlib.util.spec_from_file_location("cdc", sys.argv[1])
m = importlib.util.module_from_spec(spec)
sys.modules["cdc"] = m  # dataclasses resolve annotations through sys.modules
spec.loader.exec_module(m)
print("REPO_ROOT=%s" % m.REPO_ROOT)
print("SCRIPT_DIR=%s" % m.SCRIPT_DIR)
print("INIT_SCRIPT=%s" % m.INIT_SCRIPT)
' "$INSTALLED/cast-db-contract.py"
  [ "$status" -eq 0 ]
  [[ "$output" == *"REPO_ROOT=$FIX"* ]]
  [[ "$output" == *"SCRIPT_DIR=$FIX/scripts"* ]]
  [[ "$output" == *"INIT_SCRIPT=$FIX/scripts/cast-db-init.sh"* ]]
}

@test "check-plugin-drift: runs the SIBLING generator and hands it CAST_REPO_ROOT" {
  _install check-plugin-drift.sh cast-guard-lib.sh
  # A stub generator beside it (the installed sibling) records what it was given.
  cat >"$INSTALLED/gen-plugin.sh" <<'STUB'
#!/usr/bin/env bash
printf 'ran root=%s out=%s\n' "${CAST_REPO_ROOT:-}" "${1:-}" >"$MARKER"
STUB
  # No repo-local generator exists in the fixture: executing it would be the bug.
  mkdir -p "$HOME/shim"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$HOME/shim/claude"
  chmod +x "$HOME/shim/claude"
  cd "$UNRELATED"
  MARKER="$HOME/marker" PATH="$HOME/shim:$PATH" CAST_REPO_ROOT="$FIX" run bash "$INSTALLED/check-plugin-drift.sh"
  [ -f "$HOME/marker" ]
  grep -q "ran root=$FIX " "$HOME/marker"
}

# ── (b) relative / nonexistent CAST_REPO_ROOT fails closed ─────────────────────

@test "every changed script rejects a relative or nonexistent CAST_REPO_ROOT with a stderr message" {
  local sh_scripts="cast-check-skip-ledger.sh gen-rules-manifest.sh gen-cast-stats.sh gen-stats.sh gen-plugin.sh check-plugin-drift.sh gen-ecosystem-versions.sh blast-radius-lint.sh cast-lint-bash32-parse.sh cast-lint-source-guard.sh cast-lint-byte-budget.sh cast-test-coverage-advisory.sh pre-push-ci-check.sh cast-lint-agent-boilerplate.sh"
  local py_scripts="cast-db-contract.py cast-lint-agent-roster.py cast-lint-hook-wiring.py cast-lint-orphan-scripts.py cast-lint-write-only-tables.py"
  local s bad
  # Run the INSTALLED copies: were a check missing, the script would resolve to the temp HOME.
  for s in $sh_scripts cast-stats-lib.sh $py_scripts cast-guard-lib.sh; do
    _install "$s"
  done
  cd "$UNRELATED"
  for bad in "relative/path" "$HOME/does-not-exist" ""; do
    for s in $sh_scripts; do
      run env -u BATS_TEST_NAME -u BATS_TEST_FILENAME -u BATS_TMPDIR -u CLAUDE_SUBPROCESS \
        CAST_REPO_ROOT="$bad" bash -c 'bash "$1" 2>&1 </dev/null' _ "$INSTALLED/$s"
      if [ "$status" -eq 0 ] || [[ "$output" != *"CAST_REPO_ROOT"* ]]; then
        echo "FAIL $s with CAST_REPO_ROOT='$bad': status=$status output=$output" >&2
        return 1
      fi
    done
    for s in $py_scripts; do
      run env CAST_REPO_ROOT="$bad" bash -c '/usr/bin/python3 "$1" 2>&1 </dev/null' _ "$INSTALLED/$s"
      if [ "$status" -eq 0 ] || [[ "$output" != *"CAST_REPO_ROOT"* ]]; then
        echo "FAIL $s with CAST_REPO_ROOT='$bad': status=$status output=$output" >&2
        return 1
      fi
    done
    # The lib is sourced: a bad root must terminate the sourcing shell non-zero.
    run env CAST_REPO_ROOT="$bad" bash -c 'source "$1"; echo survived' _ "$INSTALLED/cast-stats-lib.sh"
    [ "$status" -ne 0 ]
    [[ "$output" != *"survived"* ]]
    [[ "$output" == *"CAST_REPO_ROOT"* ]]
  done
}

# ── (c) S3c-15: a hook-exported GIT_DIR must not redirect root resolution ──────

@test "S3c-15 skip-ledger: GIT_DIR pointing at another repo does not mis-resolve the script's own repo" {
  mkdir -p "$FIX/scripts"
  cp "$REPO/scripts/cast-check-skip-ledger.sh" "$FIX/scripts/"
  cp "$REPO/scripts/cast-hook-lib.sh" "$FIX/scripts/"  # sourced from its own dir (fail closed without it)
  _mk_ledger_fixture "$FIX"
  cd "$OTHER"
  GIT_DIR="$OTHER/.git" run bash "$FIX/scripts/cast-check-skip-ledger.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK: skip ledger in sync"* ]]
}

@test "S3c-15 gen-rules-manifest: GIT_DIR pointing at another repo does not mis-resolve the script's own repo" {
  mkdir -p "$FIX/scripts" "$FIX/rules-core" "$FIX/.github"
  cp "$REPO/scripts/gen-rules-manifest.sh" "$FIX/scripts/"
  cp "$REPO/scripts/cast-hook-lib.sh" "$FIX/scripts/"  # sourced from its own dir (fail closed without it)
  echo "rule body" >"$FIX/rules-core/a.md"
  cd "$OTHER"
  GIT_DIR="$OTHER/.git" run bash "$FIX/scripts/gen-rules-manifest.sh"
  [ "$status" -eq 0 ]
  grep -q 'rules-core/a.md' "$FIX/.github/rules-core.manifest"
}

@test "S3c-15 byte-budget (cwd-based): GIT_DIR from a hook does not turn a subdirectory into the root" {
  mkdir -p "$FIX/rules-core" "$FIX/sub/dir"
  echo "hello" >"$FIX/rules-core/a.md"
  cd "$FIX/sub/dir"
  # With GIT_DIR set and no GIT_WORK_TREE, git calls the cwd the top of the work tree.
  GIT_DIR="$FIX/.git" run bash "$REPO/scripts/cast-lint-byte-budget.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK [lint-byte-budget]: 6 bytes"* ]]
}

@test "S3c-15 hook-wiring lint (cwd-based): GIT_DIR from a hook does not turn a subdirectory into the root" {
  mkdir -p "$FIX/managed-settings.d" "$FIX/sub"
  cat >"$FIX/managed-settings.d/dup.json" <<'JSON'
{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"bash ~/.claude/scripts/foo-guard.sh"},{"type":"command","command":"bash ~/.claude/scripts/foo-guard.sh"}]}]}}
JSON
  cd "$FIX/sub"
  GIT_DIR="$FIX/.git" run /usr/bin/python3 "$REPO/scripts/cast-lint-hook-wiring.py"
  [ "$status" -eq 1 ]
  [[ "$output" == *"$FIX/managed-settings.d/dup.json"* ]]
}
