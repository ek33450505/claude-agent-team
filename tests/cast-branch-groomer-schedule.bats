#!/usr/bin/env bats
# Tests for scripts/cast-branch-groomer-schedule.sh (S4-1 D-E).
# The real job runs from launchd with CAST_GROOM_AUTO_APPLY=1, which makes the groomer DELETE branches
# and worktrees. The schedule script locates its groomer as <its own dir>/cast-branch-groomer.sh, so the
# tests copy the script into a temp tree next to a stub groomer that only records its argv. The real
# groomer is never executed.

bats_require_minimum_version 1.5.0

load 'helpers/setup'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
REAL_SCRIPT="$REPO_DIR/scripts/cast-branch-groomer-schedule.sh"

setup() {
  setup_temp_home
  unset CAST_GROOM_AUTO_APPLY CAST_GROOM_REPOS CLAUDE_SUBPROCESS
  ISO="$HOME/iso/scripts"
  mkdir -p "$ISO"
  cp "$REAL_SCRIPT" "$ISO/cast-branch-groomer-schedule.sh"
  SCRIPT="$ISO/cast-branch-groomer-schedule.sh"
  export STUB_LOG="$HOME/groomer-argv.log"
  cat > "$ISO/cast-branch-groomer.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_LOG"
echo "stub-groomer-output"
exit 0
STUB
  # fake repos: the script only checks for a .git directory before handing off to the groomer
  REPO_A="$HOME/repos/alpha"
  REPO_B="$HOME/repos/beta"
  mkdir -p "$REPO_A/.git" "$REPO_B/.git"
  cd "$HOME"
}

teardown() {
  cd /
  teardown_temp_home
}

_report() { ls "$HOME"/.claude/reports/branch-grooming-*.md 2>/dev/null | head -1; }

@test "default run is dry-run: passes --dry-run and NO --apply" {
  run bash "$SCRIPT" --repo "$REPO_A"
  [ "$status" -eq 0 ]
  [ -f "$STUB_LOG" ]
  run cat "$STUB_LOG"
  [ "$output" = "--dry-run --worktrees --repo $REPO_A" ]
  [[ "$output" != *--apply* ]]
}

@test "default run writes the report under the temp HOME" {
  run bash "$SCRIPT" --repo "$REPO_A"
  [ "$status" -eq 0 ]
  local r
  r="$(_report)"
  [ -n "$r" ]
  [[ "$r" == "$HOME/.claude/reports/branch-grooming-"*.md ]]
  grep -q 'mode: \*\*dry-run\*\*' "$r"
  grep -q 'stub-groomer-output' "$r"
  grep -q '^## alpha$' "$r"
  [[ "$output" == *"mode=dry-run"* ]]
}

@test "CAST_GROOM_AUTO_APPLY=1 passes --apply (and not --dry-run)" {
  run env CAST_GROOM_AUTO_APPLY=1 bash "$SCRIPT" --repo "$REPO_A"
  [ "$status" -eq 0 ]
  run cat "$STUB_LOG"
  [ "$output" = "--apply --worktrees --repo $REPO_A" ]
  grep -q 'mode: \*\*apply\*\*' "$(_report)"
}

@test "any CAST_GROOM_AUTO_APPLY value other than exactly 1 does NOT apply" {
  local v
  for v in true yes TRUE on 0 2 01 " 1" "1 " "" "1;" "apply"; do
    rm -f "$STUB_LOG"
    run env "CAST_GROOM_AUTO_APPLY=$v" bash "$SCRIPT" --repo "$REPO_A"
    [ "$status" -eq 0 ]
    [ -f "$STUB_LOG" ] || { echo "groomer not called for value '$v'"; false; }
    if grep -q -- '--apply' "$STUB_LOG"; then
      echo "CAST_GROOM_AUTO_APPLY='$v' triggered --apply"
      false
    fi
    grep -q -- '--dry-run' "$STUB_LOG" || { echo "no --dry-run for '$v'"; false; }
  done
}

@test "the report is written under the temp HOME" {
  run bash "$SCRIPT" --repo "$REPO_A"
  [ "$status" -eq 0 ]
  [ -n "$(_report)" ]
  [[ "$(_report)" == "$HOME"/* ]]
}

@test "only reports/logs/stub files are created under HOME" {
  (cd "$HOME" && find . -type f | LC_ALL=C sort) > "$BATS_TEST_TMPDIR/before"
  run bash "$SCRIPT" --repo "$REPO_A"
  [ "$status" -eq 0 ]
  (cd "$HOME" && find . -type f | LC_ALL=C sort) > "$BATS_TEST_TMPDIR/after"
  run bash -c "LC_ALL=C comm -13 '$BATS_TEST_TMPDIR/before' '$BATS_TEST_TMPDIR/after' | grep -v -e '^./.claude/reports/branch-grooming-' -e '^./groomer-argv.log$' -e '^./.claude/logs/'"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "repos with no .git directory are skipped and the groomer is not called for them" {
  mkdir -p "$HOME/repos/plain"
  run bash "$SCRIPT" --repo "$HOME/repos/plain"
  [ "$status" -eq 0 ]
  [ ! -f "$STUB_LOG" ]
  grep -q 'skipped' "$(_report)"
  [[ "$output" == *"0 repo(s)"* ]]
}

@test "default repo list under a temp HOME grooms nothing (no live repos exist)" {
  run env CAST_GROOM_AUTO_APPLY=1 bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ ! -f "$STUB_LOG" ]
  [[ "$output" == *"0 repo(s), mode=apply"* ]]
}

@test "CAST_GROOM_REPOS accepts colon- and space-separated lists" {
  run env "CAST_GROOM_REPOS=$REPO_A:$REPO_B" bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$STUB_LOG" | tr -d ' ')" -eq 2 ]
  grep -q -- "--repo $REPO_A\$" "$STUB_LOG"
  grep -q -- "--repo $REPO_B\$" "$STUB_LOG"
  rm -f "$STUB_LOG"
  run env "CAST_GROOM_REPOS=$REPO_A $REPO_B" bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$STUB_LOG" | tr -d ' ')" -eq 2 ]
}

@test "--repo takes precedence over CAST_GROOM_REPOS" {
  run env "CAST_GROOM_REPOS=$REPO_B" bash "$SCRIPT" --repo "$REPO_A"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$STUB_LOG" | tr -d ' ')" -eq 1 ]
  grep -q -- "--repo $REPO_A\$" "$STUB_LOG"
}

@test "CLAUDE_SUBPROCESS=1 exits 0 without calling the groomer or writing a report" {
  run env CLAUDE_SUBPROCESS=1 CAST_GROOM_AUTO_APPLY=1 bash "$SCRIPT" --repo "$REPO_A"
  [ "$status" -eq 0 ]
  [ ! -f "$STUB_LOG" ]
  [ -z "$(_report)" ]
}

@test "missing groomer is advisory: exit 0, no report" {
  rm -f "$ISO/cast-branch-groomer.sh"
  run bash "$SCRIPT" --repo "$REPO_A"
  [ "$status" -eq 0 ]
  [[ "$output" == *"groomer not found"* ]]
  [ -z "$(_report)" ]
}

@test "unknown flag warns on stderr and the run continues in dry-run" {
  run --separate-stderr bash "$SCRIPT" --bogus --repo "$REPO_A"
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"Unknown flag: --bogus"* ]]
  run cat "$STUB_LOG"
  [[ "$output" == "--dry-run"* ]]
}

@test "--help prints usage and does not call the groomer" {
  run bash "$SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"CAST_GROOM_AUTO_APPLY"* ]]
  [ ! -f "$STUB_LOG" ]
}

@test "a failing groomer is advisory: exit 0 and the run still reports" {
  cat > "$ISO/cast-branch-groomer.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_LOG"
echo "boom"
exit 3
STUB
  run bash "$SCRIPT" --repo "$REPO_A"
  [ "$status" -eq 0 ]
  grep -q 'boom' "$(_report)"
  grep -q 'groomer non-zero' "$HOME/.claude/logs/hook-errors.log"
}
