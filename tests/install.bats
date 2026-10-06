#!/usr/bin/env bats

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'
load 'helpers/setup'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

setup() {
  setup_temp_home
}

teardown() {
  teardown_temp_home
}

# Helper: run install.sh non-interactively (v3 has no menu).
# CAST_INSTALL_FORCE=1 bypasses the dirty-tree guard so tests can run in any working-tree state.
run_install() {
  CAST_INSTALL_FORCE=1 bash "$REPO_DIR/install.sh" 2>&1
  return $?
}

run_install_personal() {
  CAST_INSTALL_FORCE=1 bash "$REPO_DIR/install.sh" --personal 2>&1
  return $?
}

# =============================================================================
# Install (v3 — flat, non-interactive)
# =============================================================================

@test "Install: creates ~/.claude directory structure" {
  run_install

  [ -d "$HOME/.claude/agents" ]
  [ -d "$HOME/.claude/commands" ]
  [ -d "$HOME/.claude/skills" ]
  [ -d "$HOME/.claude/rules" ]
  [ -d "$HOME/.claude/plans" ]
  [ -d "$HOME/.claude/briefings" ]
  [ -d "$HOME/.claude/agent-memory-local" ]
}

@test "Install: installs all core agents (no personal overlay)" {
  run_install

  local count
  count=$(ls -1 "$HOME/.claude/agents/"*.md 2>/dev/null | wc -l | tr -d ' ')
  # merge converted to skill + 7 agents retired + email-drafter merged into docs in v7 Phase 4.5;
  # +2 agents added Phase 4.5.4 (eval-writer, pr-reviewer); portfolio-sync was personal/ (archived);
  # merge.md moved from archive back to core (v7.3 PR lifecycle chain); code-writer split into
  # frontend-writer/backend-writer + db-reader/infra-writer/report-writer/email-drafter added
  # (agent-roster-split 2026-07-11); core install has 27 agents
  [ "$count" -eq 27 ]
}

@test "Install: installs core skills (spot-check)" {
  run_install

  [ -d "$HOME/.claude/skills/briefing-writer" ]
  [ -d "$HOME/.claude/skills/careful-mode" ]
  [ -d "$HOME/.claude/skills/freeze-mode" ]
  [ -d "$HOME/.claude/skills/git-activity" ]
  [ -d "$HOME/.claude/skills/merge" ]
  [ -d "$HOME/.claude/skills/plan" ]
  [ -d "$HOME/.claude/skills/wizard" ]
}

@test "Install: default install (no --personal) does NOT install project-catalog" {
  # project-catalog is now personal-gated; core install must not write it
  run_install
  [ ! -e "$HOME/.claude/skills/project-catalog/SKILL.md" ]
}

@test "Install: --personal install writes project-catalog stub on fresh HOME" {
  # No pre-existing skill; --personal install must copy the stub
  run_install_personal
  [ -f "$HOME/.claude/skills/project-catalog/SKILL.md" ]
  # The installed file must not be empty
  [ -s "$HOME/.claude/skills/project-catalog/SKILL.md" ]
}

@test "Install: --personal install preserves user-populated project-catalog on reinstall" {
  # First personal install — stub is written
  run_install_personal
  [ -f "$HOME/.claude/skills/project-catalog/SKILL.md" ]

  # Simulate user populating the catalog with real project data
  echo "MY_REAL_PROJECT_CATALOG_SENTINEL" > "$HOME/.claude/skills/project-catalog/SKILL.md"

  # Second personal install — user content must NOT be overwritten (skip-if-exists)
  run_install_personal
  grep -q "MY_REAL_PROJECT_CATALOG_SENTINEL" "$HOME/.claude/skills/project-catalog/SKILL.md"
}

@test "Install: dead skills (compact-discipline, thinking-budget) are absent after install" {
  # Pre-create them in the temp HOME to verify the rm cleanup removes them
  mkdir -p "$HOME/.claude/skills/compact-discipline"
  echo "stale" > "$HOME/.claude/skills/compact-discipline/SKILL.md"
  mkdir -p "$HOME/.claude/skills/thinking-budget"
  echo "stale" > "$HOME/.claude/skills/thinking-budget/SKILL.md"

  run_install

  [ ! -e "$HOME/.claude/skills/compact-discipline" ]
  [ ! -e "$HOME/.claude/skills/thinking-budget" ]
}

@test "Install: .template extension stripped from rules" {
  run_install

  [ -f "$HOME/.claude/rules/stack-context.md" ]
  [ ! -f "$HOME/.claude/rules/stack-context.md.template" ]
}

@test "Install: scripts are executable" {
  run_install

  [ -x "$HOME/.claude/scripts/tidy.sh" ]
}

@test "Backup: existing agents dir is backed up before overwrite" {
  # First install
  run_install

  # Second install — should trigger backup
  run_install

  # A backup directory should exist containing an agents/ subdirectory
  local backup_base="$HOME/.claude/backups"
  [ -d "$backup_base" ]

  # Find the backup dir (there may be two if both runs created one, we need at least one with agents/)
  local found=false
  for dir in "$backup_base"/*/; do
    if [ -d "${dir}agents" ]; then
      found=true
      break
    fi
  done
  [ "$found" = true ]
}

@test "Install: migrations/ directory and SQL files are copied to ~/.claude/scripts/migrations/" {
  run_install

  [ -d "$HOME/.claude/scripts/migrations" ]
  # At least one .sql file must exist after install
  local sql_count
  sql_count=$(ls -1 "$HOME/.claude/scripts/migrations/"*.sql 2>/dev/null | wc -l | tr -d ' ')
  [ "$sql_count" -gt 0 ]
  # Verify the known migration file is present
  [ -f "$HOME/.claude/scripts/migrations/009_cast_framework_fixes.sql" ]
}

@test "Rules: existing rule file is not overwritten" {
  # First install
  run_install

  # Modify a rule file
  echo "CUSTOM_MARKER" >> "$HOME/.claude/rules/working-conventions.md"

  # Second install
  run_install

  # The custom marker should still be there (file was not overwritten)
  grep -q "CUSTOM_MARKER" "$HOME/.claude/rules/working-conventions.md"
}

@test "Dirty-tree guard: exits 1 with dirty scripts/ directory" {
  # Use a temp git repo so the guard fires based on a controlled dirty state,
  # without polluting the real working tree.
  # core.hooksPath=/dev/null prevents CAST pre-commit hooks from firing in the fixture.
  local tmp_repo
  tmp_repo="$(make_clean_tmp_repo)"

  # Now dirty the tree by modifying a tracked file
  echo "# test change" >> "$tmp_repo/scripts/gen-stats.sh"
  git -C "$tmp_repo" add scripts/gen-stats.sh

  # Run install.sh from the temp repo — should exit 1 due to dirty tree
  run bash "$tmp_repo/install.sh"
  [ "$status" -eq 1 ]

  # Verify error message mentions "uncommitted changes"
  [[ "$output" =~ "uncommitted changes" ]]
}

@test "Dirty-tree guard: allows install.sh to proceed with clean tree" {
  # Use a temp git repo with a clean tree — guard should not fire.
  # core.hooksPath=/dev/null prevents CAST pre-commit hooks from firing in the fixture.
  local tmp_repo
  tmp_repo="$(make_clean_tmp_repo)"

  # Tree is clean — install.sh should exit 0 (guard passes through)
  run bash "$tmp_repo/install.sh"
  [ "$status" -eq 0 ]
}

@test "Dirty-tree guard: CAST_INSTALL_FORCE=1 bypasses guard with dirty tree" {
  # Use a temp git repo and make it dirty.
  # core.hooksPath=/dev/null prevents CAST pre-commit hooks from firing in the fixture.
  local tmp_repo
  tmp_repo="$(make_clean_tmp_repo)"
  echo "# force test" >> "$tmp_repo/scripts/gen-stats.sh"
  git -C "$tmp_repo" add scripts/gen-stats.sh

  # With CAST_INSTALL_FORCE=1, install.sh should succeed despite dirty tree
  run env CAST_INSTALL_FORCE=1 bash "$tmp_repo/install.sh"
  [ "$status" -eq 0 ]
}

# Helper: build a clean throwaway git repo copy of the source tree; echoes its path.
# core.hooksPath=/dev/null prevents CAST pre-commit hooks from firing in the fixture.
make_clean_tmp_repo() {
  local tmp_repo
  # Under bats' per-test dir (bats owns cleanup). Detached git auto-maintenance after the big
  # commit can write into .git during teardown ("rm: .git: Directory not empty", main 2026-10-05).
  tmp_repo="$(mktemp -d "$BATS_TEST_TMPDIR/repo.XXXXXX")"
  cp -R "$REPO_DIR/." "$tmp_repo/"
  # Discard any inherited .git (CI's detached pull/N/merge state).
  rm -rf "$tmp_repo/.git"
  git -C "$tmp_repo" -c core.hooksPath=/dev/null init -q
  git -C "$tmp_repo" config gc.auto 0
  git -C "$tmp_repo" config maintenance.auto false
  git -C "$tmp_repo" config maintenance.autoDetach false
  git -C "$tmp_repo" add -A
  git -C "$tmp_repo" -c user.email="test@example.com" -c user.name="Test" \
    -c core.hooksPath=/dev/null commit -q -m "init"
  echo "$tmp_repo"
}

@test "Dirty-tree guard: aborts on an uncommitted tracked change in managed-settings.d/" {
  # An unstaged edit to an owned enforcement fragment must not deploy on reinstall.
  local tmp_repo
  tmp_repo="$(make_clean_tmp_repo)"
  echo "# loosened" >> "$tmp_repo/managed-settings.d/12-ask.json"

  run bash "$tmp_repo/install.sh"
  [ "$status" -eq 1 ]
  [[ "$output" =~ "uncommitted changes" ]]
  # Guard runs before any deploy step: nothing may have been written to the temp HOME.
  [ ! -e "$HOME/.claude/managed-settings.d" ]
  [ ! -e "$HOME/.claude/agents" ]
}

@test "Dirty-tree guard: aborts on an untracked new file in managed-settings.d/ (guard covers untracked)" {
  # Guard semantics: the untracked branch (`status --porcelain | grep '^??'`) applies to every
  # guarded pathspec, so a brand-new fragment is refused just like a modified tracked one.
  local tmp_repo
  tmp_repo="$(make_clean_tmp_repo)"
  echo '{}' > "$tmp_repo/managed-settings.d/99-untracked.json"

  run bash "$tmp_repo/install.sh"
  [ "$status" -eq 1 ]
  [[ "$output" =~ "uncommitted changes" ]]
  [ ! -e "$HOME/.claude/managed-settings.d" ]
}

@test "Dirty-tree guard: CAST_INSTALL_FORCE=1 bypasses guard with dirty managed-settings.d/" {
  local tmp_repo
  tmp_repo="$(make_clean_tmp_repo)"
  echo '{}' > "$tmp_repo/managed-settings.d/99-untracked.json"

  # Without the bypass this state aborts (previous test); with it, install proceeds and deploys.
  run env CAST_INSTALL_FORCE=1 bash "$tmp_repo/install.sh"
  [ "$status" -eq 0 ]
  [ -f "$HOME/.claude/managed-settings.d/99-untracked.json" ]
}

@test "Dirty-tree guard: every deploy-source path is guarded (untracked file and tracked edit, listing names the file)" {
  # Independent oracle (deliberately NOT read from install.sh): the repo paths install.sh deploys
  # from, per its deploy map. Dropping any entry from install.sh's GUARD_PATHS fails that row.
  # The guard exits before any deploy step, so each probe is fast.
  local -a guarded
  guarded=(agents/ commands/ skills/ rules-core/ scripts/ bin/ config/ managed-settings.d/
    macos/ tools/justfile cast/ VERSION skills-personal/ managed-settings-personal/ rules-personal/)
  local tmp_repo failures="" entry probe tracked
  tmp_repo="$(make_clean_tmp_repo)"

  for entry in "${guarded[@]}"; do
    # Each row must start from a clean guarded tree (else a prior row's leftover could pass it).
    [ -z "$(git -C "$tmp_repo" status --porcelain --untracked-files=all)" ] \
      || failures="$failures [dirty-before:$entry]"

    # (1) untracked file under a directory entry
    if [[ "$entry" == */ ]]; then
      probe="${entry}zz-guard-probe.txt"
      mkdir -p "$tmp_repo/$entry" # a guarded dir may be absent from the repo (rules-personal/)
      echo probe > "$tmp_repo/$probe"
      run bash "$tmp_repo/install.sh"
      { [ "$status" -eq 1 ] && [[ "$output" == *"$probe"* ]]; } || failures="$failures [untracked:$entry]"
      rm -f "$tmp_repo/$probe"
    fi

    # (2) edit to a tracked file under (or equal to) the entry
    tracked="$entry"
    if [[ "$entry" == */ ]]; then
      tracked="$(git -C "$tmp_repo" ls-files -- "$entry" | head -1)"
    fi
    if [ -n "$tracked" ]; then
      cp -p "$tmp_repo/$tracked" "$HOME/.probe-saved"
      echo "# guard probe" >> "$tmp_repo/$tracked"
      run bash "$tmp_repo/install.sh"
      { [ "$status" -eq 1 ] && [[ "$output" == *"$tracked"* ]]; } || failures="$failures [tracked:$entry]"
      cp -p "$HOME/.probe-saved" "$tmp_repo/$tracked"
    fi
  done

  [ -z "$failures" ] || { echo "unguarded rows:$failures" >&2; return 1; }
}

@test "Dirty-tree guard: untracked-only dirt is listed by file (even with showUntrackedFiles=no) and says commit or remove" {
  local tmp_repo
  tmp_repo="$(make_clean_tmp_repo)"
  # An untracked file inside a NEW subdirectory: default porcelain would collapse it to the dir.
  mkdir -p "$tmp_repo/config/zz-newdir"
  echo '{}' > "$tmp_repo/config/zz-newdir/untracked-only.json"
  # A user/repo setting that hides untracked files must not defeat the guard.
  git -C "$tmp_repo" config status.showUntrackedFiles no

  run bash "$tmp_repo/install.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"config/zz-newdir/untracked-only.json"* ]]
  [[ "$output" == *"Commit or remove"* ]]
  # CAST forbids stash: the footer must not recommend it.
  [[ "$output" != *"stash"* ]]
}

@test "Dirty-tree guard: outside a git work tree fails closed with a message (not silently)" {
  local not_git
  not_git="$(mktemp -d)"
  cp "$REPO_DIR/install.sh" "$not_git/install.sh"

  # Ceiling keeps git from discovering an enclosing repo above the temp dir.
  run env GIT_CEILING_DIRECTORIES="$(dirname "$not_git")" bash "$not_git/install.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not a usable git work tree"* ]]
  [ ! -e "$HOME/.claude" ]

  rm -rf "$not_git"
}

@test "Dirty-tree guard: an uncommitted file under rules-personal/ aborts install (--personal deploy source is guarded)" {
  # install.sh --personal deploys rules-personal/* into ~/.claude/rules; an uncommitted edit there
  # must not ship on the next reinstall. Fixture dir is created fresh (it is absent from the repo).
  local tmp_repo
  tmp_repo="$(make_clean_tmp_repo)"
  mkdir -p "$tmp_repo/rules-personal"
  echo "# guard probe" > "$tmp_repo/rules-personal/zz-guard-probe.md"

  run bash "$tmp_repo/install.sh" --personal
  [ "$status" -eq 1 ]
  [[ "$output" == *"uncommitted changes"* ]]
  [[ "$output" == *"rules-personal/zz-guard-probe.md"* ]]
  # Guard runs before any deploy step: nothing may have been written to the temp HOME.
  [ ! -e "$HOME/.claude" ]
}

# Helper: add + commit a broken-python fixture so the clean-tree guard passes and ONLY the
# compile gate can reject the install. $1 = tmp repo, $2 = file name under scripts/, $3 = source.
commit_py_fixture() {
  printf '%s\n' "$3" > "$1/scripts/$2"
  git -C "$1" add "scripts/$2"
  git -C "$1" -c user.email="test@example.com" -c user.name="Test" \
    -c core.hooksPath=/dev/null commit -q -m "fixture $2"
}

@test "Compile gate: a script that does not compile aborts install and writes nothing to ~/.claude" {
  local tmp_repo
  tmp_repo="$(make_clean_tmp_repo)"
  commit_py_fixture "$tmp_repo" zz-broken.py 'def x(:'

  # No CAST_INSTALL_FORCE: tree is clean (fixture committed), so the dirty-tree guard passes and
  # the abort below can only come from the compile gate.
  run bash "$tmp_repo/install.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"zz-broken.py"* ]]
  [[ "$output" == *"does not compile"* ]]
  [[ "$output" == *"SyntaxError"* ]]
  [[ "$output" != *"uncommitted changes"* ]]
  # Gate runs before the first write (backups/mkdirs/copies): ~/.claude must not even exist.
  [ ! -e "$HOME/.claude" ]
}

@test "Compile gate: CAST_INSTALL_FORCE=1 does NOT bypass the compile gate" {
  local tmp_repo
  tmp_repo="$(make_clean_tmp_repo)"
  # Untracked + FORCE: the dirty-tree guard is bypassed, so only the compile gate can stop this.
  printf '%s\n' 'def x(:' > "$tmp_repo/scripts/zz-broken.py"

  run env CAST_INSTALL_FORCE=1 bash "$tmp_repo/install.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"zz-broken.py"* ]]
  [[ "$output" == *"does not compile"* ]]
  [ ! -e "$HOME/.claude/scripts" ]
  [ ! -e "$HOME/.claude/agents" ]
}

@test "Compile gate: a successful install leaves no __pycache__ or .pyc under the repo's scripts/" {
  local tmp_repo
  tmp_repo="$(make_clean_tmp_repo)"
  # make_clean_tmp_repo cp -R's the live checkout, whose scripts/ may already hold gitignored
  # __pycache__ from earlier runs. Clear them from the COPY (bound to the bats tmpdir) so a
  # passing assertion proves this run wrote none.
  [[ "$tmp_repo" == "$BATS_TEST_TMPDIR"/* ]] || { echo "refusing to rm outside tmpdir: $tmp_repo" >&2; return 1; }
  find "$tmp_repo/scripts" -name '__pycache__' -type d -prune -exec rm -rf {} +
  find "$tmp_repo/scripts" -name '*.pyc' -type f -delete
  [ -z "$(find "$tmp_repo/scripts" \( -name '__pycache__' -o -name '*.pyc' \) | head -1)" ]

  run bash "$tmp_repo/install.sh"
  [ "$status" -eq 0 ]
  # The compile gate compiles in memory; a pyc written into the repo would be stray state.
  local stray
  stray="$(find "$tmp_repo/scripts" \( -name '__pycache__' -o -name '*.pyc' \) | head -3)"
  [ -z "$stray" ] || { echo "stray bytecode in repo: $stray" >&2; return 1; }
}

@test "Compile gate: syntax newer than the macOS system python3 is rejected via /usr/bin/python3" {
  # Hooks run bare `python3`, which can resolve to the system 3.9; a module using 3.10+ syntax
  # would fail to load there and silently disable its guard. Only meaningful when /usr/bin/python3
  # is a DIFFERENT, older interpreter than PATH's (macOS); skip elsewhere.
  # Mirrors install.sh: on Darwin without the Command Line Tools /usr/bin/python3 is a failing
  # shim that can pop a GUI installer dialog, so it is neither probed here nor used by the gate.
  { [ -x /usr/bin/python3 ] && { [ "$(uname -s)" != "Darwin" ] || xcode-select -p >/dev/null 2>&1; }; } \
    || skip "no usable /usr/bin/python3 (absent, or Darwin without Command Line Tools)"
  [ "$(realpath /usr/bin/python3)" != "$(realpath "$(command -v python3)")" ] \
    || skip "PATH python3 is /usr/bin/python3"
  /usr/bin/python3 -I -c 'import sys; sys.exit(0 if sys.version_info < (3, 10) else 1)' \
    || skip "/usr/bin/python3 is 3.10+"
  command -v python3 >/dev/null
  python3 -I -c 'import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)' \
    || skip "PATH python3 is older than 3.10"

  local tmp_repo
  tmp_repo="$(make_clean_tmp_repo)"
  commit_py_fixture "$tmp_repo" zz-py310.py $'match 1:\n    case 1:\n        pass'

  run bash "$tmp_repo/install.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"zz-py310.py"* ]]
  [[ "$output" == *"/usr/bin/python3"* ]]
  [ ! -e "$HOME/.claude" ]
}

# Helper: commit everything in the tmp repo so the clean-tree guard passes and only the compile
# gate can reject the install.
commit_all_fixture() {
  git -C "$1" add -A
  git -C "$1" -c user.email="test@example.com" -c user.name="Test" \
    -c core.hooksPath=/dev/null commit -q -m "fixture"
}

@test "Compile gate: a symlinked .py under scripts/ is refused (deploy cp would follow it past the gate)" {
  local tmp_repo
  tmp_repo="$(make_clean_tmp_repo)"
  # Broken target lives OUTSIDE scripts/, so find -type f never sees it: only the symlink check can stop this.
  mkdir -p "$tmp_repo/zz-fixture"
  printf '%s\n' 'def x(:' > "$tmp_repo/zz-fixture/broken-target.txt"
  ln -s ../zz-fixture/broken-target.txt "$tmp_repo/scripts/zz-link.py"
  commit_all_fixture "$tmp_repo"

  run bash "$tmp_repo/install.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"non-regular entry"* ]]
  [[ "$output" == *"scripts/zz-link.py"* ]]
  [[ "$output" != *"uncommitted changes"* ]]
  [ ! -e "$HOME/.claude" ]
}

@test "Compile gate: a FIFO named zz.py under scripts/ is refused without hanging" {
  local tmp_repo
  tmp_repo="$(make_clean_tmp_repo)"
  mkfifo "$tmp_repo/scripts/zz.py"

  # Without the gate the deploy `cp` blocks forever on the FIFO, so bound the run by hand
  # (no GNU `timeout` on stock macOS). fd 3/4 are closed so a leaked child can't hold bats' pipes.
  local out="$BATS_TEST_TMPDIR/fifo-install.out" pid i=0 rc=0
  CAST_INSTALL_FORCE=1 bash "$tmp_repo/install.sh" >"$out" 2>&1 </dev/null 3>&- 4>&- &
  pid=$!
  while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 200 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    # Release a `cp` blocked opening the FIFO (open O_RDWR never blocks) so nothing leaks.
    { exec 7<>"$tmp_repo/scripts/zz.py"; } 2>/dev/null && exec 7>&-
    echo "install.sh HUNG on the FIFO (gate did not refuse it)" >&2
    return 1
  fi
  wait "$pid" || rc=$?
  [ "$rc" -ne 0 ]
  grep -q "non-regular entry" "$out"
  grep -q "scripts/zz.py" "$out"
  [ ! -e "$HOME/.claude" ]
}

@test "Compile gate: scripts/ replaced by a symlink is refused (find would not descend, gate would fail open)" {
  local tmp_repo
  tmp_repo="$(make_clean_tmp_repo)"
  mv "$tmp_repo/scripts" "$tmp_repo/zz-scripts-real"
  ln -s zz-scripts-real "$tmp_repo/scripts"

  # FORCE: with a symlinked scripts/ git's own pathspec check fails first (a different abort).
  # The compile gate has no FORCE bypass, so it must still stop this.
  run env CAST_INSTALL_FORCE=1 bash "$tmp_repo/install.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"scripts/ is missing or is a symlink"* ]]
  [ ! -e "$HOME/.claude" ]
}

@test "Compile gate: a missing scripts/ is refused (empty file list must not skip the gate)" {
  local tmp_repo
  tmp_repo="$(make_clean_tmp_repo)"
  [[ "$tmp_repo" == "$BATS_TEST_TMPDIR"/* ]] || { echo "refusing to rm outside tmpdir: $tmp_repo" >&2; return 1; }
  rm -rf "$tmp_repo/scripts"

  run env CAST_INSTALL_FORCE=1 bash "$tmp_repo/install.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"scripts/ is missing or is a symlink"* ]]
  [ ! -e "$HOME/.claude" ]
}

@test "Compile gate: a scripts/ tree with zero .py files is refused (count 0 must not skip the gate)" {
  local tmp_repo
  tmp_repo="$(make_clean_tmp_repo)"
  [[ "$tmp_repo" == "$BATS_TEST_TMPDIR"/* ]] || { echo "refusing to rm outside tmpdir: $tmp_repo" >&2; return 1; }
  find "$tmp_repo/scripts" -type f \( -name '*.py' -o -name '*.py.template' \) -delete

  run env CAST_INSTALL_FORCE=1 bash "$tmp_repo/install.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"found no .py files"* ]]
  [ ! -e "$HOME/.claude" ]
}

@test "Compile gate: a failing find while listing scripts is refused (find status must not be hidden)" {
  local tmp_repo shim="$BATS_TEST_TMPDIR/shim"
  tmp_repo="$(make_clean_tmp_repo)"
  mkdir -p "$shim"
  # Pass the non-regular scan (-print) through; fail only the .py listing (-print0).
  cat > "$shim/find" <<'SHIM'
#!/bin/bash
case "$*" in *-print0*) exit 3 ;; esac
exec /usr/bin/find "$@"
SHIM
  chmod +x "$shim/find"

  run env PATH="$shim:$PATH" CAST_INSTALL_FORCE=1 bash "$tmp_repo/install.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"could not list scripts/*.py"* ]]
  [ ! -e "$HOME/.claude" ]
}

@test "Compile gate: a broken scripts/*.py.template is refused (deploy strips .template, so it ships as .py)" {
  local tmp_repo
  tmp_repo="$(make_clean_tmp_repo)"
  commit_py_fixture "$tmp_repo" zz-tmpl.py.template 'def x(:'

  run bash "$tmp_repo/install.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"zz-tmpl.py.template"* ]]
  [[ "$output" == *"does not compile"* ]]
  [ ! -e "$HOME/.claude" ]
}

@test "Compile gate: control characters in a failing file name are stripped from the terminal output" {
  local tmp_repo
  tmp_repo="$(make_clean_tmp_repo)"
  commit_py_fixture "$tmp_repo" $'zz-ctl\001x.py' 'def x(:'

  run bash "$tmp_repo/install.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"zz-ctl?x.py"* ]]
  [[ "$output" != *$'\001'* ]]
}

@test "Compile gate: UTF-8 C1 and bidi-override bytes in a failing file name never reach the terminal" {
  local tmp_repo
  tmp_repo="$(make_clean_tmp_repo)"
  # U+0085 (C1 NEL: c2 85) and U+202E (RIGHT-TO-LEFT OVERRIDE: e2 80 ae) are valid UTF-8 that a
  # control-char strip leaves intact; every non-printable-ASCII byte must become '?'.
  commit_py_fixture "$tmp_repo" $'zz-u\xc2\x85\xe2\x80\xaex.py' 'def x(:'

  run bash "$tmp_repo/install.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not compile"* ]]
  [[ "$output" == *"zz-u?????x.py"* ]]
  local c1 bidi
  c1="$(printf '%s' "$output" | LC_ALL=C grep -c $'\xc2\x85' || true)"
  bidi="$(printf '%s' "$output" | LC_ALL=C grep -c $'\xe2\x80\xae' || true)"
  [ "$c1" = "0" ] || { echo "C1 bytes leaked to output" >&2; return 1; }
  [ "$bidi" = "0" ] || { echo "bidi-override bytes leaked to output" >&2; return 1; }
}

@test "Compile gate: an upper-case .PY under scripts/ is refused (case-insensitive FS would overwrite a deployed script ungated)" {
  local tmp_repo
  tmp_repo="$(make_clean_tmp_repo)"
  commit_py_fixture "$tmp_repo" zz-case.PY 'def x(:'

  run bash "$tmp_repo/install.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"non-canonical Python file name"* ]]
  [[ "$output" == *"scripts/zz-case.PY"* ]]
  [[ "$output" != *"uncommitted changes"* ]]
  [ ! -e "$HOME/.claude" ]
}

@test "Compile gate: an upper-case .PY.template under scripts/ is refused" {
  local tmp_repo
  tmp_repo="$(make_clean_tmp_repo)"
  commit_py_fixture "$tmp_repo" zz-up.PY.template 'def x(:'

  run bash "$tmp_repo/install.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"non-canonical Python file name"* ]]
  [[ "$output" == *"scripts/zz-up.PY.template"* ]]
  [ ! -e "$HOME/.claude" ]
}

@test "Compile gate: a broken upper-case .PY in a scripts/ subdirectory is still compiled (-iname)" {
  local tmp_repo
  tmp_repo="$(make_clean_tmp_repo)"
  # Only top-level names are deployed (and canonical-name checked); a subdirectory case-variant
  # must still be compiled, so only the case-insensitive match can catch it.
  commit_py_fixture "$tmp_repo" eval-graders/zz-sub.PY 'def x(:'

  run bash "$tmp_repo/install.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"eval-graders/zz-sub.PY"* ]]
  [[ "$output" == *"does not compile"* ]]
  [ ! -e "$HOME/.claude" ]
}

@test "Compile gate: the temp file list is removed when install.sh is terminated mid-gate" {
  local tmp_repo shim="$BATS_TEST_TMPDIR/shim" tmpd="$BATS_TEST_TMPDIR/tmpd"
  local mark="$BATS_TEST_TMPDIR/shim.pid" out="$BATS_TEST_TMPDIR/term-install.out" pid i=0 rc=0
  tmp_repo="$(make_clean_tmp_repo)"
  mkdir -p "$shim" "$tmpd"
  # find shim: passes every scan through except the -print0 listing, which records its pid and
  # parks. The list file already exists (mktemp ran, trap armed) while find is parked, which is
  # the only window in which a signal could leak it.
  cat > "$shim/find" <<SHIM
#!/bin/bash
case "\$*" in
  *-print0*) echo \$\$ > "$mark"; exec sleep 30 ;;
esac
exec /usr/bin/find "\$@"
SHIM
  chmod +x "$shim/find"

  TMPDIR="$tmpd" PATH="$shim:$PATH" CAST_INSTALL_FORCE=1 bash "$tmp_repo/install.sh" >"$out" 2>&1 </dev/null 3>&- 4>&- &
  pid=$!
  while [ ! -s "$mark" ] && kill -0 "$pid" 2>/dev/null && [ "$i" -lt 200 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ -s "$mark" ] || { echo "install.sh never reached the listing step" >&2; kill "$pid" 2>/dev/null || true; return 1; }
  # The list file must exist now (otherwise this test would prove nothing about its removal).
  [ -n "$(ls "$tmpd"/cast-install-pylist.* 2>/dev/null)" ]

  kill -TERM "$pid"
  kill -TERM "$(cat "$mark")" 2>/dev/null || true
  i=0
  while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 100 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -KILL "$pid" 2>/dev/null || true
    echo "install.sh did not exit on SIGTERM" >&2
    return 1
  fi
  wait "$pid" || rc=$?
  [ "$rc" -eq 143 ]
  [ -z "$(ls "$tmpd"/cast-install-pylist.* 2>/dev/null)" ] || { echo "leaked list file in $tmpd" >&2; return 1; }
  [ ! -e "$HOME/.claude" ]
}

@test "Owned fragment backup: prior copy is backed up with mode 600 even when the live file was 644" {
  mkdir -p "$HOME/.claude/managed-settings.d"
  # A differing live copy of a CAST-owned fragment, world-readable.
  echo '{"_planted":"differs-from-repo"}' > "$HOME/.claude/managed-settings.d/05-behavior.json"
  chmod 644 "$HOME/.claude/managed-settings.d/05-behavior.json"

  run_install

  local backup
  backup="$(ls -d "$HOME"/.claude/backups/*/managed-settings.d/05-behavior.json 2>/dev/null | head -1)"
  [ -n "$backup" ]
  grep -q "differs-from-repo" "$backup"
  # Portable mode check (no `stat -f`/`stat -c`): first 10 chars of `ls -l`.
  local mode
  mode="$(ls -l "$backup" | cut -c1-10)"
  [ "$mode" = "-rw-------" ]
}

@test "Backup retention: keeps only the 5 most recent install snapshots" {
  # Pre-populate 7 fake timestamp dirs in the isolated temp HOME backups dir
  local backup_base="$HOME/.claude/backups"
  mkdir -p "$backup_base"

  # Create 7 dirs with valid YYYYMMDD-HHMMSS names (8+6 digits)
  local -a dirs
  dirs=()
  for ts in 20260601-120001 20260602-120002 20260603-120003 20260604-120004 \
            20260605-120005 20260606-120006 20260607-120007; do
    local d="$backup_base/$ts"
    mkdir -p "$d"
    dirs+=("$d")
  done

  # Also create a cast-db file and an ad-hoc snapshot — these must survive
  touch "$backup_base/cast-db-2026-06-01.db"
  mkdir -p "$backup_base/_phase1-backup-manual"

  # Run install (creates one more timestamped dir, total snapshot dirs becomes 8)
  run_install

  # Count surviving timestamp-pattern dirs (macOS-safe: no -regextype)
  local count=0
  while IFS= read -r -d '' d; do
    local dname
    dname="$(basename "$d")"
    if [[ "$dname" =~ ^[0-9]{8}-[0-9]{6}$ ]]; then
      count=$(( count + 1 ))
    fi
  done < <(find "$backup_base" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)

  # Must keep exactly 5 (keep-last-N=5)
  [ "$count" -eq 5 ]

  # cast-db file must survive
  [ -f "$backup_base/cast-db-2026-06-01.db" ]

  # Ad-hoc snapshot must survive
  [ -d "$backup_base/_phase1-backup-manual" ]
}

# =============================================================================
# Hook-ownership sentinel
# =============================================================================

# =============================================================================
# OTEL collector plist — opt-in install (v9 B3)
# =============================================================================

@test "Install: otel-collector plist is installed as dormant (NO launchctl load) on fresh install" {
  if [[ "$(uname)" != "Darwin" ]]; then skip "macOS-only: launchd plist installation"; fi
  # Stub launchctl: record every invocation so we can assert it was NOT called for otel-collector
  local stub_bin
  stub_bin="$(mktemp -d)"
  local call_log="$stub_bin/launchctl-calls.log"
  cat > "$stub_bin/launchctl" <<STUBEOF
#!/bin/bash
# Stub launchctl — records calls, always succeeds
echo "\$@" >> "$call_log"
exit 0
STUBEOF
  chmod +x "$stub_bin/launchctl"

  PATH="$stub_bin:$PATH" CAST_INSTALL_FORCE=1 bash "$REPO_DIR/install.sh" 2>&1

  # Assertion 1: plist file must exist in LaunchAgents
  local plist_dest="$HOME/Library/LaunchAgents/com.cast.otel-collector.plist"
  [ -f "$plist_dest" ] || {
    echo "FAIL: plist not found at $plist_dest" >&2
    return 1
  }

  # Assertion 2: __HOME__ token must be replaced with the real HOME path
  grep -q "__HOME__" "$plist_dest" && {
    echo "FAIL: __HOME__ token not substituted in $plist_dest" >&2
    return 1
  }

  # Assertion 3: install.sh MUST NOT call launchctl load for otel-collector
  # (telemetry is opt-in; activation must go through cast-otel.sh enable only)
  if grep -q "^load .*otel-collector" "$call_log" 2>/dev/null; then
    echo "FAIL: install.sh called launchctl load for otel-collector — consent violation (daemon must be dormant until cast-otel.sh enable)" >&2
    echo "Call log contents:" >&2
    cat "$call_log" >&2
    return 1
  fi

  # Assertion 4: plist must have RunAtLoad=false (dormant by default)
  grep -q "<false/>" "$plist_dest" || {
    echo "FAIL: plist does not contain RunAtLoad=false (dormant default)" >&2
    return 1
  }

  rm -rf "$stub_bin"
}

@test "Install: 50-mcp.json is overwritten on reinstall (CAST-owned fragment — propagates removals)" {
  # First install — seeds 50-mcp.json from repo source
  run_install

  # Simulate a stale fragment containing a dummy MCP server (e.g. pre-github-MCP-drop)
  local mcp_dest="$HOME/.claude/managed-settings.d/50-mcp.json"
  printf '{"mcpServers":{"stale-server":{"command":"never-existed"}}}\n' > "$mcp_dest"

  # Second install — 50-mcp.json must be overwritten with the repo source ({"mcpServers": {}})
  run_install

  # The dummy server must NOT be present — repo's empty mcpServers wins
  if grep -q "stale-server" "$mcp_dest"; then
    echo "FAIL: stale 50-mcp.json was NOT overwritten on reinstall" >&2
    cat "$mcp_dest" >&2
    return 1
  fi
}

@test "Install: 11-deny.json is overwritten on reinstall (CAST-owned fragment — propagates security deny updates)" {
  # First install — seeds 11-deny.json from repo source
  run_install

  local deny_dest="$HOME/.claude/managed-settings.d/11-deny.json"
  [ -f "$deny_dest" ] || { echo "FAIL: 11-deny.json not installed" >&2; return 1; }

  # Simulate a stale fragment missing the model-cap deny entries
  printf '{"permissions":{"deny":["Bash(pkill *)"]}}\n' > "$deny_dest"

  # Verify our stale copy is missing the fable deny
  if grep -q "claude-fable" "$deny_dest"; then
    echo "setup error: stale copy unexpectedly contains claude-fable" >&2
    return 1
  fi

  # Second install — 11-deny.json must be overwritten with full repo source
  run_install

  # The model-cap deny entries must now be present
  if ! grep -q "claude-fable" "$deny_dest"; then
    echo "FAIL: stale 11-deny.json was NOT overwritten on reinstall" >&2
    cat "$deny_dest" >&2
    return 1
  fi
}

@test "Install: 61-sandbox.json is overwritten on reinstall (CAST-owned fragment — propagates sandbox/security config)" {
  # First install — seeds 61-sandbox.json from repo source
  run_install

  local sandbox_dest="$HOME/.claude/managed-settings.d/61-sandbox.json"
  [ -f "$sandbox_dest" ] || { echo "FAIL: 61-sandbox.json not installed" >&2; return 1; }

  # Simulate a stale fragment missing the allowRead allowlist (e.g. pre-2026-07-02 config)
  printf '{"sandbox":{"enabled":true,"filesystem":{"denyRead":["~/.aws/credentials"]}}}\n' > "$sandbox_dest"

  # Verify our stale copy is missing api.anthropic.com (present in repo source)
  if grep -q "api.anthropic.com" "$sandbox_dest"; then
    echo "setup error: stale copy unexpectedly contains api.anthropic.com" >&2
    return 1
  fi

  # Second install — 61-sandbox.json must be overwritten with full repo source
  run_install

  # The repo-source network allowlist entry must now be present
  if ! grep -q "api.anthropic.com" "$sandbox_dest"; then
    echo "FAIL: stale 61-sandbox.json was NOT overwritten on reinstall" >&2
    cat "$sandbox_dest" >&2
    return 1
  fi
}

@test "Install: 12-ask.json is overwritten on reinstall (CAST-owned fragment — propagates ask-gate updates)" {
  # First install — seeds 12-ask.json from repo source
  run_install

  local ask_dest="$HOME/.claude/managed-settings.d/12-ask.json"
  [ -f "$ask_dest" ] || { echo "FAIL: 12-ask.json not installed" >&2; return 1; }

  # Simulate a stale ask-gate missing the Neon rules (the 2026-10-03 failed-to-deploy shape)
  printf '{"permissions":{"ask":["Bash(rm *)"]}}\n' > "$ask_dest"

  # Verify our stale copy is missing the mcp__neon__ ask rules (present in repo source)
  if grep -q "mcp__neon__" "$ask_dest"; then
    echo "setup error: stale copy unexpectedly contains mcp__neon__" >&2
    return 1
  fi

  # Second install — 12-ask.json must be overwritten with full repo source
  run run_install
  assert_success

  # A replaced copy is never silent: the notice names the file ...
  assert_output --partial "Replaced (differed from repo): managed-settings.d/12-ask.json"

  # ... and the stale copy is backed up with its content intact
  local bak
  bak="$(ls "$HOME"/.claude/backups/*/managed-settings.d/12-ask.json 2>/dev/null | head -1)"
  [ -n "$bak" ] || { echo "FAIL: no backup of stale 12-ask.json under ~/.claude/backups" >&2; return 1; }
  grep -q 'Bash(rm \*)' "$bak" || { echo "FAIL: backup lacks the stale marker" >&2; cat "$bak" >&2; return 1; }

  if ! grep -q "mcp__neon__" "$ask_dest"; then
    echo "FAIL: stale 12-ask.json was NOT overwritten on reinstall" >&2
    cat "$ask_dest" >&2
    return 1
  fi
  if ! cmp -s "$REPO_DIR/managed-settings.d/12-ask.json" "$ask_dest"; then
    echo "FAIL: reinstalled 12-ask.json differs from repo source" >&2
    return 1
  fi
}

# Shared body for the "CAST-owned enforcement fragment is replaced on reinstall" tests.
# Args: <fragment filename> <stale JSON> <stale marker grep pattern (fixed string)>
# Asserts: replaced notice, content-intact backup, dest byte-identical to repo source.
assert_owned_fragment_replaced() {
  local name="$1" stale_json="$2" stale_marker="$3"
  local dest="$HOME/.claude/managed-settings.d/$name"

  # First install — seeds the fragment from repo source
  run_install
  [ -f "$dest" ] || { echo "FAIL: $name not installed" >&2; return 1; }

  # Simulate a stale/diverged deployed copy
  printf '%s\n' "$stale_json" > "$dest"
  if cmp -s "$REPO_DIR/managed-settings.d/$name" "$dest"; then
    echo "setup error: stale copy of $name is identical to repo source" >&2
    return 1
  fi

  # Second install — must overwrite with repo source
  run run_install
  assert_success

  # A replaced copy is never silent: the notice names the file ...
  assert_output --partial "Replaced (differed from repo): managed-settings.d/$name"

  # ... and the stale copy is backed up with its content intact
  local bak
  bak="$(ls "$HOME"/.claude/backups/*/managed-settings.d/"$name" 2>/dev/null | head -1)"
  [ -n "$bak" ] || { echo "FAIL: no backup of stale $name under ~/.claude/backups" >&2; return 1; }
  grep -qF -- "$stale_marker" "$bak" || { echo "FAIL: backup of $name lacks the stale marker" >&2; cat "$bak" >&2; return 1; }

  if grep -qF -- "$stale_marker" "$dest"; then
    echo "FAIL: stale $name was NOT overwritten on reinstall" >&2
    cat "$dest" >&2
    return 1
  fi
  if ! cmp -s "$REPO_DIR/managed-settings.d/$name" "$dest"; then
    echo "FAIL: reinstalled $name differs from repo source" >&2
    return 1
  fi
}

@test "Install: 05-behavior.json is overwritten on reinstall (CAST-owned fragment — propagates sandbox.failIfUnavailable)" {
  # Stale copy disables the fail-closed sandbox switch (the shape a repo fix must be able to repair)
  assert_owned_fragment_replaced "05-behavior.json" \
    '{"sandbox":{"failIfUnavailable":false,"staleMarker05":true}}' \
    'staleMarker05'

  # The enforcement value from repo source is what landed
  grep -q '"failIfUnavailable": true' "$HOME/.claude/managed-settings.d/05-behavior.json" || {
    echo "FAIL: reinstalled 05-behavior.json lacks failIfUnavailable: true" >&2
    return 1
  }
}

@test "Install: 10-permissions.json is overwritten on reinstall (CAST-owned fragment — propagates permission allow-list)" {
  assert_owned_fragment_replaced "10-permissions.json" \
    '{"permissions":{"allow":["Bash(echo stale-marker-10)"]}}' \
    'stale-marker-10'
}

@test "Install: identical 05-behavior.json and 10-permissions.json are synced with no Replaced notice or backup" {
  run_install

  run run_install
  assert_success

  local name
  for name in 05-behavior.json 10-permissions.json; do
    # Owned fragments report "Synced", never "Skipped (exists)"
    assert_output --partial "Synced: managed-settings.d/$name"
    refute_output --partial "Replaced (differed from repo): managed-settings.d/$name"
    # No backup is taken when the copies are already identical
    if compgen -G "$HOME/.claude/backups/*/managed-settings.d/$name" >/dev/null; then
      echo "FAIL: unexpected backup of identical $name" >&2
      return 1
    fi
  done
}

@test "Install: a customized user fragment is preserved and reported as drift" {
  run_install

  # 00-env.json remains a user-customizable (skip-if-exists) fragment
  local env_dest="$HOME/.claude/managed-settings.d/00-env.json"
  [ -f "$env_dest" ] || { echo "FAIL: 00-env.json not installed" >&2; return 1; }

  # Local customization of a user-customizable fragment
  printf '{"env":{"CUSTOM_MARKER":"custom-marker"}}\n' > "$env_dest"

  run run_install
  assert_success

  # Preserved — install.sh must never overwrite a skip-if-exists fragment
  if ! grep -q "custom-marker" "$env_dest"; then
    echo "FAIL: customized 00-env.json was overwritten on reinstall" >&2
    cat "$env_dest" >&2
    return 1
  fi

  # Skipped, not synced
  assert_output --partial "Skipped (exists): managed-settings.d/00-env.json"
  refute_output --partial "Replaced (differed from repo): managed-settings.d/00-env.json"

  # Reported — report-only drift WARN names the file (and only the drifted one)
  assert_output --partial "differ from the repo source"
  assert_output --partial "    - 00-env.json"
  refute_output --partial "    - 10-permissions.json"
  refute_output --partial "    - 05-behavior.json"
}

@test "Install: clean reinstall reports no fragment drift" {
  run_install

  run run_install
  assert_success
  refute_output --partial "differ from the repo source"
  refute_output --partial "Replaced (differed from repo)"
}

@test "Install: creates ~/.claude/config/cast-hook-owner with content 'install.sh'" {
  run_install

  # File must exist
  [ -f "$HOME/.claude/config/cast-hook-owner" ] || {
    echo "File not found: $HOME/.claude/config/cast-hook-owner" >&2
    return 1
  }

  # Content must be exactly 'install.sh\n'
  local content
  content="$(cat "$HOME/.claude/config/cast-hook-owner")"
  [ "$content" = "install.sh" ] || {
    echo "Expected content 'install.sh', got '$content'" >&2
    return 1
  }
}

# =============================================================================
# Telemetry personal overlay: --personal installs 12-otel.json; plain install does NOT
# =============================================================================

@test "Install --personal: copies managed-settings-personal/12-otel.json into managed-settings.d/" {
  if [[ ! -f "$REPO_DIR/managed-settings-personal/12-otel.json" ]]; then
    skip "managed-settings-personal/12-otel.json not present in repo"
  fi

  run_install_personal

  local dest="$HOME/.claude/managed-settings.d/12-otel.json"
  [ -f "$dest" ] || {
    echo "FAIL: 12-otel.json not found in managed-settings.d/ after --personal install" >&2
    return 1
  }

  # Must be valid JSON
  python3 -m json.tool "$dest" >/dev/null 2>&1 || {
    echo "FAIL: $dest is not valid JSON" >&2
    return 1
  }

  # Must contain CLAUDE_CODE_ENABLE_TELEMETRY
  python3 -c "
import json, sys
with open('$dest') as f:
    data = json.load(f)
env = data.get('env', {})
if 'CLAUDE_CODE_ENABLE_TELEMETRY' not in env:
    print('FAIL: CLAUDE_CODE_ENABLE_TELEMETRY missing from 12-otel.json', file=sys.stderr)
    sys.exit(1)
" || return 1
}

@test "Install (no --personal): does NOT copy 12-otel.json into managed-settings.d/" {
  run_install

  local dest="$HOME/.claude/managed-settings.d/12-otel.json"
  [ ! -f "$dest" ] || {
    echo "FAIL: 12-otel.json was copied into managed-settings.d/ by a plain install (no --personal) — consent violation" >&2
    return 1
  }
}

@test "Install (no --personal): 00-env.json contains none of the 6 telemetry keys" {
  run_install

  local fragment="$HOME/.claude/managed-settings.d/00-env.json"
  [ -f "$fragment" ] || {
    echo "FAIL: 00-env.json not found after install" >&2
    return 1
  }

  python3 << PYEOF
import json, sys
TELEMETRY_KEYS = [
    "CLAUDE_CODE_ENABLE_TELEMETRY",
    "OTEL_METRICS_EXPORTER",
    "OTEL_LOGS_EXPORTER",
    "OTEL_EXPORTER_OTLP_PROTOCOL",
    "OTEL_EXPORTER_OTLP_ENDPOINT",
    "DISABLE_TELEMETRY",
]
with open("$fragment") as f:
    data = json.load(f)
env = data.get("env", {})
found = [k for k in TELEMETRY_KEYS if k in env]
if found:
    print(f"FAIL: 00-env.json must not ship telemetry keys, found: {found}", file=sys.stderr)
    sys.exit(1)
PYEOF
}

# =============================================================================
# Config backup safety (commit fe343ab)
# =============================================================================

@test "Install: backs up existing config before overwriting (safety)" {
  # Pre-create a config file with old content
  mkdir -p "$HOME/.claude/config"
  local old_content="old_config_content_v1"
  printf '%s' "$old_content" > "$HOME/.claude/config/egress-policy.json"

  # Run install (which should overwrite the config)
  run_install

  # Verify new config was installed
  [ -f "$HOME/.claude/config/egress-policy.json" ]

  # Verify old config was backed up to .bak
  [ -f "$HOME/.claude/config/egress-policy.json.bak" ]

  # Verify backup contains the old content
  local backup_content
  backup_content="$(cat "$HOME/.claude/config/egress-policy.json.bak")"
  [ "$backup_content" = "$old_content" ]

  # Verify new config is different from old
  local new_content
  new_content="$(cat "$HOME/.claude/config/egress-policy.json")"
  [ "$new_content" != "$old_content" ]
}
