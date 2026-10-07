#!/usr/bin/env bats
# install-integrity.bats — U6d: install.sh writes ~/.claude/install-manifest.sha256 and the
# SessionStart health hook + `cast doctor` DETECT post-install tampering (changed/missing scripts or
# githooks, a vanished githooks dir, a rewired core.hooksPath). All under temp HOMEs: one real install
# into a throwaway repo copy (setup_file), copied into a fresh temp HOME per test. Never touches the
# real ~/.claude or this repo's .git/config.

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'
load 'helpers/setup'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
HEALTH="$REPO_DIR/scripts/cast-session-start-health.sh"
CHECKER="$REPO_DIR/scripts/cast-install-integrity.py"

setup_file() {
  export MASTER_HOME="$BATS_FILE_TMPDIR/master-home"
  export MASTER_REPO="$BATS_FILE_TMPDIR/repo"
  mkdir -p "$MASTER_HOME" "$MASTER_REPO"
  touch "$MASTER_HOME/.cast-test-home"   # install.sh's test-HOME sentinel
  cp -R "$REPO_DIR/." "$MASTER_REPO/"
  rm -rf "$MASTER_REPO/.git"
  git -C "$MASTER_REPO" -c core.hooksPath=/dev/null init -q
  git -C "$MASTER_REPO" config gc.auto 0
  git -C "$MASTER_REPO" config maintenance.auto false
  git -C "$MASTER_REPO" config maintenance.autoDetach false
  git -C "$MASTER_REPO" add -A
  git -C "$MASTER_REPO" -c user.email="test@example.com" -c user.name="Test" \
    -c core.hooksPath=/dev/null commit -q -m "init"
  HOME="$MASTER_HOME" bash "$MASTER_REPO/install.sh" > "$BATS_FILE_TMPDIR/install.out" 2>&1 \
    || { echo "master install failed" >&2; tail -20 "$BATS_FILE_TMPDIR/install.out" >&2; return 1; }
}

setup() {
  setup_temp_home
  cp -Rp "$MASTER_HOME/.claude" "$HOME/.claude"
  STUB="$BATS_TEST_TMPDIR/launchctl-ok.sh"
  printf '#!/bin/bash\necho "-\t0\tcom.cast.backup"\n' > "$STUB"
  chmod +x "$STUB"
  export CAST_HEALTH_LAUNCHCTL_CMD="$STUB"
  unset CAST_DB_PATH CAST_REPO_DIR
  MANIFEST="$HOME/.claude/install-manifest.sha256"
}

teardown() {
  cd /
  teardown_temp_home
}

run_health() { run bash "$HEALTH" < /dev/null; }
checker() { python3 -I "$CHECKER" --home "$HOME"; }   # use as: run checker

# Append raw text to a repo's .git/config (written as a file, exactly as an attacker would).
cfg_append() { printf '%b' "$2" >> "$1/.git/config"; }

# A throwaway repo wired like a real install (core.hooksPath = installed githooks), and the manifest
# rewritten to name it with the matching expected value (the temp-HOME install records "-").
wire_repo() {  # $1 = hooksPath value to put in the repo config ("" = leave unset)
  local repo="$BATS_TEST_TMPDIR/wired-repo"
  mkdir -p "$repo"
  git -C "$repo" -c core.hooksPath=/dev/null init -q
  [ -z "$1" ] || git -C "$repo" config core.hooksPath "$1"
  sed -i.bak -e "s|^# repo: .*|# repo: $repo|" -e "s|^# hooks-path: .*|# hooks-path: $HOME/.claude/githooks|" "$MANIFEST"
  rm -f "$MANIFEST.bak"
  echo "$repo"
}

# --- manifest content ---------------------------------------------------------------------------

@test "install writes a manifest: header, repo, skipped hooks-path under a temp HOME, mode 644" {
  [ -f "$MANIFEST" ]
  [ ! -L "$MANIFEST" ]
  [ "$(sed -n 1p "$MANIFEST")" = "# cast-install-manifest v2" ]
  [ "$(sed -n 2p "$MANIFEST")" = "# repo: $MASTER_REPO" ]
  [ "$(sed -n 3p "$MANIFEST")" = "# hooks-path: -" ]
  [ "$(stat -f '%Lp' "$MANIFEST" 2>/dev/null || stat -c '%a' "$MANIFEST")" = "644" ]
  [ -z "$(find "$HOME/.claude" -maxdepth 1 -name '.install-manifest-*' | head -1)" ]
}

@test "manifest lists exactly the deployed scripts + migrations + 5 hook files + policies.json" {
  local expected actual
  expected=$(( $(find "$MASTER_REPO/scripts" -maxdepth 1 -type f | wc -l) \
             + $(find "$MASTER_REPO/scripts/migrations" -maxdepth 1 -type f -name '*.sql' | wc -l) + 6 ))
  actual="$(grep -vc '^#' "$MANIFEST")"
  [ "$actual" -eq "$expected" ]
  grep -q '  scripts/cast-install-integrity.py$' "$MANIFEST"
  grep -q '  scripts/cast-git-guard.py$' "$MANIFEST"
  grep -q '  githooks/pre-push$' "$MANIFEST"
  grep -q '  githooks/cold-start-baseline.txt$' "$MANIFEST"
  grep -q '  config/policies.json$' "$MANIFEST"
  # sorted, no duplicates
  [ "$(grep -v '^#' "$MANIFEST" | awk '{print $2}' | LC_ALL=C sort -c 2>&1 | wc -l)" -eq 0 ]
  [ "$(grep -v '^#' "$MANIFEST" | awk '{print $2}' | sort | uniq -d | wc -l)" -eq 0 ]
}

@test "every manifest hash verifies against the deployed files (independent shasum -c)" {
  grep -v '^#' "$MANIFEST" > "$BATS_TEST_TMPDIR/entries.sha"
  run bash -c 'cd "$HOME/.claude" && shasum -a 256 -c "$1" | grep -vc ": OK$"' _ "$BATS_TEST_TMPDIR/entries.sha"
  assert_output "0"
}

@test "install aborts (nothing written through it) when the manifest path is a symlink" {
  local repo="$BATS_TEST_TMPDIR/repo2" fresh victim
  mkdir -p "$repo"
  cp -R "$MASTER_REPO/." "$repo/"   # carries the master's .git: clean tree, throwaway repo
  fresh="$BATS_TEST_TMPDIR/fresh-home"; mkdir -p "$fresh/.claude"; touch "$fresh/.cast-test-home"
  victim="$BATS_TEST_TMPDIR/victim"; echo keep > "$victim"
  ln -s "$victim" "$fresh/.claude/install-manifest.sha256"
  run env HOME="$fresh" bash "$repo/install.sh"
  assert_failure
  assert_output --partial "install-manifest.sha256 is a symlink or not a regular file"
  [ "$(cat "$victim")" = "keep" ]
}

# --- health hook: clean / advisory -------------------------------------------------------------

@test "clean install: health hook emits NO notice" {
  run_health
  assert_success
  assert_output ""
}

@test "missing manifest (pre-manifest install): advisory notice, not an alarm, exit 0" {
  rm -f "$MANIFEST"
  run_health
  assert_success
  assert_output --partial "install integrity manifest missing"
  assert_output --partial "run bash install.sh to create the integrity manifest"
  refute_output --partial "problem"
}

# --- health hook: tampering --------------------------------------------------------------------

@test "tampered script: alarm names it" {
  echo '# planted' >> "$HOME/.claude/scripts/cast-git-guard.py"
  run_health
  assert_success
  assert_output --partial "install integrity"
  assert_output --partial "scripts/cast-git-guard.py changed since install"
  assert_output --partial "re-run bash install.sh"
  echo "$output" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["systemMessage"]; assert d["hookSpecificOutput"]["hookEventName"]=="SessionStart"'
}

@test "same-size edit of a script is still caught (hash, not size/mtime)" {
  local f="$HOME/.claude/scripts/cast-git-guard.py" sz mt
  sz="$(wc -c < "$f")"; mt="$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f")"
  # flip the first byte to a different one of the same width, then restore the mtime
  printf 'X' | dd of="$f" bs=1 count=1 conv=notrunc 2>/dev/null
  touch -t "$(date -r "$mt" +%Y%m%d%H%M.%S 2>/dev/null || date -d "@$mt" +%Y%m%d%H%M.%S)" "$f"
  [ "$(wc -c < "$f")" -eq "$sz" ]
  run_health
  assert_output --partial "scripts/cast-git-guard.py changed since install"
}

@test "deleted script: alarm names it as missing" {
  rm -f "$HOME/.claude/scripts/cast-git-guard.py"
  run_health
  assert_output --partial "scripts/cast-git-guard.py is missing"
}

@test "tampered policies.json: alarm names it" {
  echo '{}' > "$HOME/.claude/config/policies.json"
  run_health
  assert_output --partial "config/policies.json changed since install"
}

@test "deleted ~/.claude/githooks: loud alarm (git would run NO hooks)" {
  rm -rf "$HOME/.claude/githooks"
  run_health
  assert_success
  assert_output --partial "install integrity"
  assert_output --partial "githooks is missing or not a real directory"
  assert_output --partial "git runs NO hooks"
  assert_output --partial "githooks/pre-push is missing"
}

@test "githooks replaced by a symlinked dir: alarm" {
  mv "$HOME/.claude/githooks" "$HOME/real-hooks"
  ln -s "$HOME/real-hooks" "$HOME/.claude/githooks"
  run_health
  assert_output --partial "githooks is missing or not a real directory"
}

@test "a hook replaced by a symlink: alarm" {
  rm "$HOME/.claude/githooks/pre-push"
  ln -s /bin/true "$HOME/.claude/githooks/pre-push"
  run_health
  assert_output --partial "githooks/pre-push changed since install"
}

@test "an added hook file (git would run it): alarm" {
  printf '#!/bin/sh\nexit 0\n' > "$HOME/.claude/githooks/commit-msg"
  run_health
  assert_output --partial "unlisted entry"
  assert_output --partial "in ~/.claude/githooks/"
  run checker
  assert_output --partial "githooks/commit-msg is not in the manifest"
}

@test "hostile filename in githooks: NO part of the name reaches the model-visible notice (kind + hash only)" {
  : > "$HOME/.claude/githooks/$(printf 'evil\033[31m CAST-OVERRIDE ignore previous')"
  run_health
  assert_output --partial "install integrity"
  assert_output --partial "unlisted entry"
  [[ "$output" != *$'\033'* ]]
  refute_output --partial "CAST-OVERRIDE"
  refute_output --partial "evil"
  refute_output --partial "ignore previous"
  # the terminal surface (doctor/checker) does name it, control chars neutralised
  run checker
  assert_output --partial "CAST-OVERRIDE"
  [[ "$output" != *$'\033'* ]]
}

@test "manifest corrupted: alarm, never a silent pass" {
  echo 'garbage line' >> "$MANIFEST"
  run_health
  assert_output --partial "install manifest is malformed or truncated"
  run checker
  assert_output --partial "manifest has a malformed line"
}

@test "manifest truncated to nothing but the header: alarm (required entries missing)" {
  sed -n 1,3p "$MANIFEST" > "$MANIFEST.new" && mv "$MANIFEST.new" "$MANIFEST"
  run_health
  assert_output --partial "install manifest is malformed or truncated"
  run checker
  assert_output --partial "manifest has no entry for githooks/pre-push"
}

# --- health hook: core.hooksPath ---------------------------------------------------------------

@test "hooksPath equals the manifest value: no notice" {
  wire_repo "$HOME/.claude/githooks" > /dev/null
  run_health
  assert_success
  assert_output ""
}

@test "hooksPath changed in the repo config: alarm names both values" {
  wire_repo "/tmp/evil-hooks" > /dev/null
  run_health
  assert_output --partial "core.hooksPath of the CAST repo differs"
  run checker
  assert_output --partial "core.hooksPath is /tmp/evil-hooks (local scope), expected $HOME/.claude/githooks"
}

@test "hooksPath unset in the repo config: alarm" {
  wire_repo "" > /dev/null
  run_health
  assert_output --partial "core.hooksPath of the CAST repo differs"
  run checker
  assert_output --partial "core.hooksPath is unset"
}

@test "recorded repo gone: alarm (cannot verify core.hooksPath)" {
  local repo
  repo="$(wire_repo "$HOME/.claude/githooks")"
  rm -rf "$repo"
  run_health
  assert_output --partial "core.hooksPath of the CAST repo differs"
  run checker
  assert_output --partial "has no readable git dir"
}

# --- H1: effective git config (include / includeIf / config.worktree / hook.*) ----------------

@test "H1 include overriding hooksPath: alarm" {
  local repo; repo="$(wire_repo "$HOME/.claude/githooks")"
  printf '[core]\n\thooksPath = /tmp/evil\n' > "$repo/.git/extra.cfg"
  cfg_append "$repo" '[include]\n\tpath = extra.cfg\n'
  run_health
  assert_output --partial "core.hooksPath of the CAST repo differs"
  run checker
  assert_output --partial "core.hooksPath is /tmp/evil"
}

@test "H1 includeIf gitdir overriding hooksPath: alarm (needs repo context)" {
  local repo real; repo="$(wire_repo "$HOME/.claude/githooks")"
  real="$(cd "$repo" && pwd -P)"
  printf '[core]\n\thooksPath = /tmp/evil\n' > "$repo/.git/extra.cfg"
  cfg_append "$repo" "[includeIf \"gitdir:$real/.git\"]\n\tpath = extra.cfg\n"
  run_health
  assert_output --partial "core.hooksPath of the CAST repo differs"
}

@test "H1 extensions.worktreeConfig + config.worktree hooksPath: alarm" {
  local repo; repo="$(wire_repo "$HOME/.claude/githooks")"
  cfg_append "$repo" '[core]\n\trepositoryformatversion = 1\n[extensions]\n\tworktreeConfig = true\n'
  printf '[core]\n\thooksPath = /tmp/evil\n' > "$repo/.git/config.worktree"
  run_health
  assert_output --partial "core.hooksPath of the CAST repo differs"
}

# A repo with one commit and one REAL linked worktree "wt" (so git can resolve its config).
wire_repo_with_worktree() {
  local repo; repo="$(wire_repo "$HOME/.claude/githooks")"
  git -C "$repo" -c core.hooksPath=/dev/null -c user.email=t@example.com -c user.name=T commit -q --allow-empty -m init
  git -C "$repo" -c core.hooksPath=/dev/null worktree add -q "$BATS_TEST_TMPDIR/wt"
  cfg_append "$repo" '[core]\n\trepositoryformatversion = 1\n[extensions]\n\tworktreeConfig = true\n'
  echo "$repo"
}

@test "N2 linked worktree with a clean config.worktree: no alarm (control)" {
  wire_repo_with_worktree > /dev/null
  run_health
  assert_output ""
}

@test "N2 linked worktree's config.worktree overrides hooksPath: alarm (resolved by git, per worktree)" {
  local repo; repo="$(wire_repo_with_worktree)"
  printf '[core]\n\thooksPath = /tmp/evil\n' > "$repo/.git/worktrees/wt/config.worktree"
  run_health
  assert_output --partial "core.hooksPath of the CAST repo differs"
  run checker
  assert_output --partial "core.hooksPath is /tmp/evil (worktree scope)"
}

@test "N2 linked worktree defining hook.<n>.command via an include: alarm" {
  local repo; repo="$(wire_repo_with_worktree)"
  printf '[hook "x"]\n\tcommand = true\n' > "$repo/.git/wt-extra.cfg"
  printf '[include]\n\tpath = %s\n' "$repo/.git/wt-extra.cfg" > "$repo/.git/worktrees/wt/config.worktree"
  run_health
  assert_output --partial "git config defines hook.*"
}

@test "N2 an unreadable linked-worktree entry fails closed; more than 64 worktrees is an alarm" {
  local repo; repo="$(wire_repo "$HOME/.claude/githooks")"
  mkdir -p "$repo/.git/worktrees/broken"
  run checker
  assert_output --partial "could not read the effective git config of linked worktree"
  local i; for i in $(seq 1 65); do mkdir -p "$repo/.git/worktrees/w$i"; done
  run checker
  assert_output --partial "more than 64 linked worktrees"
}

@test "H1 config-based hook (hook.<n>.command) in the local config: alarm even with correct hooksPath" {
  local repo; repo="$(wire_repo "$HOME/.claude/githooks")"
  cfg_append "$repo" '[hook "pii-off"]\n\tcommand = true\n\tevent = pre-commit\n'
  run_health
  assert_output --partial "git config defines hook.*"
  run checker
  assert_output --partial "hook.pii-off.command is set in local git config"
}

@test "H1 config-based hook in the GLOBAL config: alarm" {
  wire_repo "$HOME/.claude/githooks" > /dev/null
  printf '[hook "g"]\n\tevent = pre-push\n' > "$HOME/.gitconfig"
  run_health
  assert_output --partial "git config defines hook.*"
  run checker
  assert_output --partial "hook.g.event is set in global git config"
}

@test "H1 effective value from the global config is honoured (local unset, global correct): no alarm" {
  wire_repo "" > /dev/null
  printf '[core]\n\thooksPath = %s\n' "$HOME/.claude/githooks" > "$HOME/.gitconfig"
  run_health
  assert_output ""
}

@test "H1 global hooksPath cannot stand in for a missing local value: global evil + local unset: alarm" {
  wire_repo "" > /dev/null
  printf '[core]\n\thooksPath = /tmp/evil\n' > "$HOME/.gitconfig"
  run_health
  assert_output --partial "core.hooksPath of the CAST repo differs"
}

# --- H2: modes ---------------------------------------------------------------------------------

@test "H2 manifest records a mode for every entry" {
  [ "$(grep -c '^# mode: ' "$MANIFEST")" -eq "$(grep -vc '^#' "$MANIFEST")" ]
  grep -q '^# mode: 755 githooks/pre-commit$' "$MANIFEST"
  grep -q '^# mode: 644 githooks/cold-start-baseline.txt$' "$MANIFEST"
}

@test "H2 chmod -x on a hook: alarm (git silently skips a non-executable hook)" {
  chmod -x "$HOME/.claude/githooks/pre-commit"
  run_health
  assert_output --partial "githooks/pre-commit has different permissions than installed"
  run checker
  assert_output --partial "githooks/pre-commit mode is 644, expected 755"
}

@test "H2 a script made group/world writable: alarm" {
  chmod 777 "$HOME/.claude/scripts/cast-git-guard.py"
  run_health
  assert_output --partial "scripts/cast-git-guard.py has different permissions than installed"
}

# --- M1: unlisted entries in code-loading dirs -------------------------------------------------

@test "M1 planted scripts/json.py (stdlib shadow): alarm" {
  echo 'import os' > "$HOME/.claude/scripts/json.py"
  run_health
  assert_output --partial "unlisted entry"
  assert_output --partial "in ~/.claude/scripts/"
  run checker
  assert_output --partial "scripts/json.py is not in the manifest"
}

@test "M1 planted package dir scripts/json/: alarm" {
  mkdir -p "$HOME/.claude/scripts/json"; echo 'x=1' > "$HOME/.claude/scripts/json/__init__.py"
  run checker
  assert_output --partial "scripts/json is not in the manifest"
}

@test "M1 planted file in scripts/migrations/: alarm" {
  echo 'x' > "$HOME/.claude/scripts/migrations/zz.py"
  run checker
  assert_output --partial "scripts/migrations/zz.py is not in the manifest"
}

@test "M1 __pycache__: bytecode of a manifest script and .DS_Store are tolerated" {
  make_pyc python3 cast-git-guard > /dev/null   # a genuine cache (verified byte-for-byte by N3)
  : > "$HOME/.claude/scripts/.DS_Store"
  run_health
  assert_output ""
}

@test "M1 __pycache__: bytecode for a NON-manifest module, or a subdir inside it: alarm" {
  mkdir -p "$HOME/.claude/scripts/__pycache__/sub"
  : > "$HOME/.claude/scripts/__pycache__/json.cpython-314.pyc"
  run checker
  assert_output --partial "scripts/__pycache__/json.cpython-314.pyc is not a bytecode file of a manifest script"
  assert_output --partial "scripts/__pycache__/sub is not a bytecode file of a manifest script"
}

@test "M1 install WARNs about an unmanaged leftover in scripts/ and does not bless it" {
  local repo="$BATS_TEST_TMPDIR/repo3" fresh
  mkdir -p "$repo"; cp -R "$MASTER_REPO/." "$repo/"
  fresh="$BATS_TEST_TMPDIR/fresh-home2"; mkdir -p "$fresh/.claude/scripts"; touch "$fresh/.cast-test-home"
  echo '#!/bin/sh' > "$fresh/.claude/scripts/stale-leftover.sh"
  run env HOME="$fresh" bash "$repo/install.sh"
  assert_success
  assert_output --partial "UNMANAGED file in ~/.claude/scripts: stale-leftover.sh"
  ! grep -q 'stale-leftover' "$fresh/.claude/install-manifest.sha256"
}

# --- M2: non-regular files / hangs -------------------------------------------------------------

@test "M2 a FIFO swapped in for a script does not hang the checker" {
  rm -f "$HOME/.claude/scripts/cast-git-guard.py"
  mkfifo "$HOME/.claude/scripts/cast-git-guard.py"
  run perl -e 'alarm 20; exec @ARGV' python3 -I "$CHECKER" --home "$HOME"
  [ "$status" -eq 1 ]   # 142 would be the alarm firing
  assert_output --partial "scripts/cast-git-guard.py is no longer a readable regular file"
}

@test "M2 doctor bounds a hung checker (timeout, not a hang)" {
  local stub="$BATS_TEST_TMPDIR/hang-scripts"
  mkdir -p "$stub"; printf 'import time\ntime.sleep(60)\n' > "$stub/cast-install-integrity.py"
  run env CAST_SCRIPTS_DIR="$stub" CAST_DOCTOR_INTEGRITY_TIMEOUT=2 bash "$REPO_DIR/bin/cast" doctor
  assert_output --partial "integrity checker timed out after 2s"
}

# --- L2: env overrides -------------------------------------------------------------------------

@test "L2/N4 git env overrides that redirect config, hooks or programs: alarm (each variable)" {
  wire_repo "$HOME/.claude/githooks" > /dev/null
  local v
  for v in GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0 \
           GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_EXEC_PATH GIT_CONFIG_NOSYSTEM GIT_TEMPLATE_DIR \
           GIT_SSH GIT_SSH_COMMAND GIT_ASKPASS GIT_PROXY_COMMAND GIT_EXTERNAL_DIFF \
           PYTHONPATH PYTHONSTARTUP PYTHONPYCACHEPREFIX PYTHONHOME PYTHONUSERBASE PYTHONEXECUTABLE PYTHONINSPECT; do
    run env "$v=x" bash "$HEALTH" < /dev/null
    assert_output --partial "session environment sets GIT_*/PYTHON* overrides"
  done
}

@test "N4 harmless git env (GIT_EDITOR, GIT_PAGER) does not alarm" {
  wire_repo "$HOME/.claude/githooks" > /dev/null
  run env GIT_EDITOR=true GIT_PAGER=cat bash "$HEALTH" < /dev/null
  assert_output ""
}

# --- N1: managed directories must be real directories ------------------------------------------

@test "N1 ~/.claude/scripts replaced by a symlink to a copy with an extra json.py: alarm" {
  mv "$HOME/.claude/scripts" "$HOME/.claude/scripts.real"
  echo 'x=1' > "$HOME/.claude/scripts.real/json.py"
  ln -s "$HOME/.claude/scripts.real" "$HOME/.claude/scripts"
  run_health
  assert_output --partial "~/.claude/scripts is a symlink or not a directory"
  run checker
  assert_output --partial "scripts is a symlink or not a directory"
}

@test "N1 scripts/migrations and config as symlinks: alarm" {
  mv "$HOME/.claude/scripts/migrations" "$HOME/mig.real"; ln -s "$HOME/mig.real" "$HOME/.claude/scripts/migrations"
  run checker
  assert_output --partial "scripts/migrations is a symlink or not a directory"
  rm "$HOME/.claude/scripts/migrations"; mv "$HOME/mig.real" "$HOME/.claude/scripts/migrations"
  mv "$HOME/.claude/config" "$HOME/cfg.real"; ln -s "$HOME/cfg.real" "$HOME/.claude/config"
  run checker
  assert_output --partial "config is a symlink or not a directory"
}

@test "N1 .DS_Store is ignored only as a regular file (dir or symlink = unlisted alarm)" {
  mkdir "$HOME/.claude/scripts/.DS_Store"
  run checker
  assert_output --partial "scripts/.DS_Store is not in the manifest"
  rmdir "$HOME/.claude/scripts/.DS_Store"; ln -s /etc/hosts "$HOME/.claude/scripts/.DS_Store"
  run checker
  assert_output --partial "scripts/.DS_Store is not in the manifest"
}

# --- N3: bytecode caches are verified against their source -------------------------------------

# Compile scripts/<stem>.py with interpreter $1 into scripts/__pycache__ (what python itself would write).
make_pyc() {  # $1 interpreter, $2 stem; echoes the pyc path
  "$1" -c '
import importlib.util, os, py_compile, sys
home, stem = sys.argv[1], sys.argv[2]
src = os.path.join(home, ".claude", "scripts", stem + ".py")
print(py_compile.compile(src, cfile=importlib.util.cache_from_source(src), doraise=True))
' "$HOME" "$2"
}

# A bytecode cache for EVERY installed script from every installed interpreter (as real use leaves).
compile_all_pycs() {
  local interp
  for interp in python3 /usr/bin/python3; do
    [ -x "$(command -v "$interp")" ] || continue
    "$interp" -c '
import importlib.util, os, py_compile, sys
base = os.path.join(sys.argv[1], ".claude", "scripts")
for root in (base, os.path.join(base, "migrations")):
    for f in sorted(os.listdir(root)):
        if f.endswith(".py"):
            s = os.path.join(root, f)
            try:
                py_compile.compile(s, cfile=importlib.util.cache_from_source(s), doraise=True)
            except Exception:
                pass
' "$HOME" 2>/dev/null || true
  done
}

# Replace a pyc's code body with the compilation of arbitrary source, keeping its 16-byte header.
forge_pyc() {  # $1 pyc path
  python3 -c '
import marshal, sys
p = sys.argv[1]
head = open(p, "rb").read()[:16]
open(p, "wb").write(head + marshal.dumps(compile("import os\nos.system(\"id\")\n", "<f>", "exec")))
' "$1"
}

@test "N3 a genuine bytecode cache of a manifest script: no alarm" {
  make_pyc python3 cast-git-guard > /dev/null
  run_health
  assert_output ""
}

@test "N3 forged bytecode (header copied, body replaced): alarm" {
  local pyc; pyc="$(make_pyc python3 cast-git-guard)"
  forge_pyc "$pyc"
  run_health
  assert_output --partial "scripts/cast-git-guard.py compiled cache does not match its source"
}

@test "N3 bytecode with an unknown magic number (no interpreter can verify it): alarm" {
  local pyc; pyc="$(make_pyc python3 cast-git-guard)"
  python3 -c '
import sys
p = sys.argv[1]; b = bytearray(open(p, "rb").read()); b[0:4] = b"\x01\x02\x0d\x0a"; open(p, "wb").write(bytes(b))
' "$pyc"
  run_health
  assert_output --partial "bytecode cache cannot be verified"
}

@test "N3 bytecode of a DIFFERENT installed interpreter is verified by that interpreter (genuine ok, forged alarm)" {
  local other=/usr/bin/python3 tag_a tag_b
  [ -x "$other" ] || skip "no /usr/bin/python3"
  tag_a="$(python3 -c 'import sys; print(sys.implementation.cache_tag)')"
  tag_b="$("$other" -c 'import sys; print(sys.implementation.cache_tag)' 2>/dev/null)" || skip "/usr/bin/python3 unusable"
  [ "$tag_a" != "$tag_b" ] || skip "only one interpreter version on this host"
  local pyc; pyc="$(make_pyc "$other" cast-git-guard)"
  run_health
  assert_output ""
  # forge with the OTHER interpreter's marshal
  "$other" -c '
import marshal, sys
p = sys.argv[1]
head = open(p, "rb").read()[:16]
open(p, "wb").write(head + marshal.dumps(compile("import os\nos.system(\"id\")\n", "<f>", "exec")))
' "$pyc"
  run_health
  assert_output --partial "scripts/cast-git-guard.py compiled cache does not match its source"
}

@test "N3 install purges scripts/__pycache__ and scripts/migrations/__pycache__ (clean install starts with none)" {
  local repo="$BATS_TEST_TMPDIR/repo4" fresh
  mkdir -p "$repo"; cp -R "$MASTER_REPO/." "$repo/"
  fresh="$BATS_TEST_TMPDIR/fresh-home3"; mkdir -p "$fresh/.claude/scripts/__pycache__" "$fresh/.claude/scripts/migrations/__pycache__"
  touch "$fresh/.cast-test-home"
  : > "$fresh/.claude/scripts/__pycache__/planted.cpython-314.pyc"
  : > "$fresh/.claude/scripts/migrations/__pycache__/planted.cpython-314.pyc"
  run env HOME="$fresh" bash "$repo/install.sh"
  assert_success
  [ ! -e "$fresh/.claude/scripts/__pycache__/planted.cpython-314.pyc" ]
  [ ! -e "$fresh/.claude/scripts/migrations/__pycache__/planted.cpython-314.pyc" ]
}

@test "N3 install refuses a symlinked __pycache__ (never deletes through it)" {
  local repo="$BATS_TEST_TMPDIR/repo5" fresh victim="$BATS_TEST_TMPDIR/victim-dir"
  mkdir -p "$repo" "$victim"; echo keep > "$victim/f"; cp -R "$MASTER_REPO/." "$repo/"
  fresh="$BATS_TEST_TMPDIR/fresh-home4"; mkdir -p "$fresh/.claude/scripts"; touch "$fresh/.cast-test-home"
  ln -s "$victim" "$fresh/.claude/scripts/__pycache__"
  run env HOME="$fresh" bash "$repo/install.sh"
  assert_failure
  assert_output --partial "__pycache__ is a symlink"
  [ "$(cat "$victim/f")" = "keep" ]
}

# --- timing ------------------------------------------------------------------------------------

@test "timing: full ~190-file verification inside the hook budget" {
  local n t0 t1 ms
  n="$(grep -vc '^#' "$MANIFEST")"
  [ "$n" -gt 150 ]
  # Worst case: a bytecode cache for EVERY script from every installed interpreter (all must verify).
  compile_all_pycs
  echo "caches: $(find "$HOME" -name '*.pyc' | wc -l | tr -d ' ') pyc files" >&3
  t0="$(python3 -c 'import time; print(time.monotonic())')"
  run python3 -I "$CHECKER" --home "$HOME"
  t1="$(python3 -c 'import time; print(time.monotonic())')"
  assert_success
  ms="$(python3 -c "print(int(($t1 - $t0) * 1000))")"
  echo "checker: $n files in ${ms}ms" >&3
  [ "$ms" -lt 1500 ]
  t0="$(python3 -c 'import time; print(time.monotonic())')"
  run_health
  t1="$(python3 -c 'import time; print(time.monotonic())')"
  ms="$(python3 -c "print(int(($t1 - $t0) * 1000))")"
  echo "health hook end-to-end: ${ms}ms" >&3
  [ "$ms" -lt 2500 ]
}

# --- P1: the prefix probe must not run user-site code -----------------------------------------

@test "P1 a user-site usercustomize printing junk cannot hide a forged Apple-prefix cache" {
  local other=/usr/bin/python3 tag_a tag_b site
  [ -x "$other" ] || skip "no /usr/bin/python3"
  tag_a="$(python3 -c 'import sys; print(sys.implementation.cache_tag)')"
  tag_b="$("$other" -c 'import sys; print(sys.implementation.cache_tag)' 2>/dev/null)" || skip "/usr/bin/python3 unusable"
  [ "$tag_a" != "$tag_b" ] || skip "only one interpreter version on this host"
  local pyc; pyc="$(make_pyc "$other" cast-git-guard)"
  site="$("$other" -c 'import site; print(site.getusersitepackages())')"
  mkdir -p "$site"
  printf 'print("junk /tmp/fake-prefix")\n' > "$site/usercustomize.py"
  "$other" -c '
import marshal, sys
p = sys.argv[1]
head = open(p, "rb").read()[:16]
open(p, "wb").write(head + marshal.dumps(compile("import os\nos.system(\"id\")\n", "<f>", "exec")))
' "$pyc" > /dev/null
  run_health
  assert_output --partial "scripts/cast-git-guard.py compiled cache does not match its source"
}

# --- P3: incremental SessionStart verification via a snapshot ------------------------------------

SNAP_REL=".claude/cast-state/pyc-verified.json"

@test "P3 a clean full check writes a 0600 snapshot of verified caches; planting is detected next incremental run" {
  compile_all_pycs
  run python3 -I "$CHECKER" --home "$HOME"
  assert_success
  [ -f "$HOME/$SNAP_REL" ]
  [ ! -L "$HOME/$SNAP_REL" ]
  [ "$(stat -f '%Lp' "$HOME/$SNAP_REL" 2>/dev/null || stat -c '%a' "$HOME/$SNAP_REL")" = "600" ]
  [ "$(stat -f '%Lp' "$HOME/.claude/cast-state" 2>/dev/null || stat -c '%a' "$HOME/.claude/cast-state")" = "700" ]
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["v"]==1 and len(d["entries"])>20, len(d["entries"])' "$HOME/$SNAP_REL"
}

@test "P3 cold incremental runs under a small budget make progress, converge, and never alarm falsely" {
  compile_all_pycs
  local i out pend=1
  # A budget too small to start any verifier: everything is PENDING, loudly but not an alarm.
  out="$(python3 -I "$CHECKER" --home "$HOME" --json --incremental --budget 0.2)"
  python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["state"]=="ok" and d["pending"]>20 and not d["problems"], d' "$out"
  for i in $(seq 1 40); do
    out="$(python3 -I "$CHECKER" --home "$HOME" --json --incremental --budget 0.7)"
    python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["state"]=="ok", d' "$out"
    pend="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("pending",0))' "$out")"
    [ "$pend" -eq 0 ] && break
  done
  echo "converged after $i incremental run(s)" >&3
  [ "$pend" -eq 0 ]
}

@test "P3 warm incremental run verifies NOTHING and skips every cache via the snapshot (structural, not wall-clock)" {
  local t0 t1 ms out
  compile_all_pycs
  python3 -I "$CHECKER" --home "$HOME" > /dev/null          # full verify fills the snapshot
  out="$(python3 -I "$CHECKER" --home "$HOME" --json --incremental)"
  python3 -c '
import json, sys
d = json.loads(sys.argv[1])
c = d["caches"]
assert d["state"] == "ok" and d["pending"] == 0, d
assert c["verified"] == 0 and c["skipped"] > 20, c
' "$out"
  # cold: the same run with no snapshot verifies them all (so a disabled snapshot cannot pass above)
  rm -rf "$HOME/.claude/cast-state"
  out="$(python3 -I "$CHECKER" --home "$HOME" --json --incremental)"
  python3 -c '
import json, sys
c = json.loads(sys.argv[1])["caches"]
assert c["verified"] > 20 and c["skipped"] == 0, c
' "$out"
  t0="$(python3 -c 'import time; print(time.monotonic())')"
  run_health
  t1="$(python3 -c 'import time; print(time.monotonic())')"
  assert_output ""
  ms="$(python3 -c "print(int(($t1 - $t0) * 1000))")"
  echo "warm health hook (info only): ${ms}ms" >&3
}

@test "P3 health hook renders a pending verification as a loud non-alarm notice (stub checker)" {
  printf '_PY_CANDIDATES = ()\ndef _trusted_exes(c): return []\nimport json\nprint(json.dumps({"state": "ok", "checked": 3, "dropped": 0, "problems": [], "pending": 7}))\n' \
    > "$HOME/.claude/scripts/cast-install-integrity.py"
  run_health
  assert_success
  assert_output --partial "bytecode verification incomplete (7 pending)"
  refute_output --partial "problem"
}

@test "P3 in-place forge with size and mtime restored is still caught (ctime/inode are part of the key)" {
  compile_all_pycs
  python3 -I "$CHECKER" --home "$HOME" > /dev/null
  local pyc; pyc="$(find "$HOME/.claude/scripts/__pycache__" -name 'cast-install-integrity.*.pyc' | head -1)"
  python3 - "$pyc" <<'PYEOF'
import marshal, os, sys
p = sys.argv[1]
st = os.stat(p)
head = open(p, "rb").read()[:16]
body = head + marshal.dumps(compile("import os\nos.system('id')\n", "<f>", "exec"))
assert len(body) <= st.st_size
with open(p, "r+b") as fh:
    fh.write(body.ljust(st.st_size, b"\0"))
os.utime(p, ns=(st.st_atime_ns, st.st_mtime_ns))
assert os.stat(p).st_size == st.st_size and os.stat(p).st_mtime_ns == st.st_mtime_ns
PYEOF
  run_health
  assert_output --partial "scripts/cast-install-integrity.py compiled cache does not match its source"
}

@test "P3 full check (doctor mode) ignores a forged snapshot; the incremental path trusts it (documented residual)" {
  compile_all_pycs
  python3 -I "$CHECKER" --home "$HOME" > /dev/null
  local pyc; pyc="$(find "$HOME/.claude/scripts/__pycache__" -name 'cast-install-integrity.*.pyc' | head -1)"
  python3 - "$pyc" "$HOME/$SNAP_REL" <<'PYEOF'
import json, marshal, os, sys
p, snap = sys.argv[1], sys.argv[2]
head = open(p, "rb").read()[:16]
open(p, "wb").write(head + marshal.dumps(compile("import os\nos.system('id')\n", "<f>", "exec")))
d = json.load(open(snap))
st = os.lstat(p)
sha = d["entries"][p][4]
d["entries"][p] = [st.st_size, st.st_mtime_ns, st.st_ctime_ns, st.st_ino, sha]
json.dump(d, open(snap, "w"))
PYEOF
  run python3 -I "$CHECKER" --home "$HOME"
  assert_failure
  assert_output --partial "scripts/cast-install-integrity.py compiled cache does not match its source"
}

@test "P3 symlinked cast-state dir or snapshot file: never written through" {
  compile_all_pycs
  local victim="$BATS_TEST_TMPDIR/victim"; mkdir -p "$victim"
  ln -s "$victim" "$HOME/.claude/cast-state"
  run python3 -I "$CHECKER" --home "$HOME"
  assert_success
  [ -z "$(ls -A "$victim")" ]
  rm "$HOME/.claude/cast-state"; mkdir -m 700 "$HOME/.claude/cast-state"
  echo keep > "$victim/target"
  ln -s "$victim/target" "$HOME/$SNAP_REL"
  run python3 -I "$CHECKER" --home "$HOME"
  assert_success
  [ "$(cat "$victim/target")" = "keep" ]
  [ -L "$HOME/$SNAP_REL" ]
}

# --- E1: a non-regular cache at a path python would load is an alarm ----------------------------

apple_interp() {  # sets $other (an interpreter that reports a sys.pycache_prefix) or skips
  other=/usr/bin/python3
  [ -x "$other" ] || skip "no /usr/bin/python3"
  [ -n "$("$other" -S -c 'import sys; print(sys.pycache_prefix or "")' 2>/dev/null)" ] || skip "no interpreter with a pycache prefix on this host"
}

@test "E1 prefix cache replaced by a SYMLINK to a forged pyc (valid header): alarm" {
  local other pyc; apple_interp
  pyc="$(make_pyc "$other" cast-git-guard)"
  cp "$pyc" "$HOME/forged.pyc"; forge_pyc "$HOME/forged.pyc"
  rm "$pyc"; ln -s "$HOME/forged.pyc" "$pyc"
  run_health
  assert_output --partial "scripts/cast-git-guard.py compiled cache does not match its source"
  run python3 -I "$CHECKER" --home "$HOME"
  assert_failure
}

@test "E1 prefix cache replaced by a DANGLING symlink: alarm" {
  local other pyc; apple_interp
  pyc="$(make_pyc "$other" cast-git-guard)"
  rm "$pyc"; ln -s "$HOME/does-not-exist.pyc" "$pyc"
  run_health
  assert_output --partial "scripts/cast-git-guard.py compiled cache does not match its source"
}

@test "E1 prefix cache replaced by a DIRECTORY or a FIFO: alarm" {
  local other pyc; apple_interp
  pyc="$(make_pyc "$other" cast-git-guard)"
  rm "$pyc"; mkdir "$pyc"
  run_health
  assert_output --partial "scripts/cast-git-guard.py compiled cache does not match its source"
  rmdir "$pyc"; mkfifo "$pyc"
  run perl -e 'alarm 25; exec @ARGV' python3 -I "$CHECKER" --home "$HOME"
  [ "$status" -eq 1 ]
  assert_output --partial "scripts/cast-git-guard.py compiled cache does not match its source"
}

@test "E1 parity: a symlink in the default __pycache__ also alarms" {
  local pyc; pyc="$(make_pyc python3 cast-git-guard)"
  cp "$pyc" "$HOME/forged.pyc"; forge_pyc "$HOME/forged.pyc"
  rm "$pyc"; ln -s "$HOME/forged.pyc" "$pyc"
  run checker
  assert_output --partial "is not a bytecode file of a manifest script"
}

# --- starvation: a tight budget must not keep missing the same last-sorted cache -----------------

@test "N5 snapshot persistence disabled + room for only 3 caches per run: a forged last-sorted cache is reached" {
  compile_all_pycs
  # persistence disabled: cast-state is a symlink, so nothing is ever saved or loaded
  local victim="$BATS_TEST_TMPDIR/nostate"; mkdir -p "$victim"; ln -s "$victim" "$HOME/.claude/cast-state"
  local last pyc
  last="$(ls "$HOME/.claude/scripts/"*.py | sort | tail -1 | xargs basename | sed 's/\.py$//')"
  pyc="$(find "$HOME/.claude/scripts/__pycache__" -name "$last.cpython-*.pyc" | head -1)"
  [ -n "$pyc" ]
  forge_pyc "$pyc"
  local i hit=0
  # stepping the offset by the quota walks the rotating window across every cache (~25 runs worst case)
  for i in $(seq 0 3 300); do
    run python3 -I "$CHECKER" --home "$HOME" --incremental --max-verify 3 --offset "$i"
    if [ "$status" -eq 1 ] && [[ "$output" == *"scripts/$last.py compiled cache does not match its source"* ]]; then hit=$i; break; fi
  done
  echo "forged last-sorted cache reached at offset $hit" >&3
  [ "$status" -eq 1 ]
  [ -z "$(ls -A "$victim")" ]
}

@test "N5 never-verified caches are checked BEFORE ones the snapshot already vouches for" {
  compile_all_pycs
  python3 -I "$CHECKER" --home "$HOME" > /dev/null          # snapshot now vouches for every cache
  local pyc; pyc="$(find "$HOME/.claude/scripts/__pycache__" -name 'cast-install-integrity.*.pyc' | head -1)"
  rm "$pyc"; python3 -c '
import py_compile, importlib.util, sys
s = sys.argv[1]; py_compile.compile(s, cfile=importlib.util.cache_from_source(s), doraise=True)
' "$HOME/.claude/scripts/cast-install-integrity.py"        # a NEW inode: changed vs the snapshot
  forge_pyc "$pyc"
  run python3 -I "$CHECKER" --home "$HOME" --incremental --max-verify 1 --offset 0
  assert_failure
  assert_output --partial "scripts/cast-install-integrity.py compiled cache does not match its source"
}

# --- own interpreter must come from the trusted list --------------------------------------------

@test "N6 PYTHONEXECUTABLE pointing at an existing fake file is never executed by the hook" {
  wire_repo "$HOME/.claude/githooks" > /dev/null
  local fake="$BATS_TEST_TMPDIR/fake-python" mark="$BATS_TEST_TMPDIR/fake-ran"
  printf '#!/bin/sh\ntouch "%s"\nexit 0\n' "$mark" > "$fake"; chmod +x "$fake"
  run env PYTHONEXECUTABLE="$fake" bash "$HEALTH" < /dev/null
  [ ! -e "$mark" ]
  assert_output --partial "session environment sets GIT_*/PYTHON* overrides"
  # the checker itself (run directly, as doctor does) must not exec it either
  compile_all_pycs
  run env PYTHONEXECUTABLE="$fake" python3 -I "$CHECKER" --home "$HOME"
  [ ! -e "$mark" ]
}

# --- A1: integrity runs first; a run that verified nothing says so loudly --------------------------

@test "A1 health hook: a run that verified NOTHING while caches are pending renders a distinct SKIPPED warning" {
  printf '_PY_CANDIDATES = ()\ndef _trusted_exes(c): return []\nimport json\nprint(json.dumps({"state": "ok", "checked": 3, "dropped": 0, "problems": [], "pending": 71, "caches": {"verified": 0, "skipped": 0}}))\n' \
    > "$HOME/.claude/scripts/cast-install-integrity.py"
  run_health
  assert_success
  assert_output --partial "bytecode verification SKIPPED this session"
  assert_output --partial "NONE of the 71 bytecode cache file(s) were checked"
  assert_output --partial "cast doctor"
  refute_output --partial "incomplete"
}

@test "A1 health hook: progress with some left pending stays the ordinary 'incomplete' line (not SKIPPED)" {
  printf '_PY_CANDIDATES = ()\ndef _trusted_exes(c): return []\nimport json\nprint(json.dumps({"state": "ok", "checked": 3, "dropped": 0, "problems": [], "pending": 5, "caches": {"verified": 9, "skipped": 0}}))\n' \
    > "$HOME/.claude/scripts/cast-install-integrity.py"
  run_health
  assert_output --partial "bytecode verification incomplete (5 pending)"
  refute_output --partial "SKIPPED"
}

@test "A1 the integrity check runs BEFORE the stale-memory scanner and the guard check (full budget)" {
  local i s g
  i="$(grep -n '^# ── Install integrity' "$HEALTH" | head -1 | cut -d: -f1)"
  s="$(grep -n '^# ── Stale memory detection' "$HEALTH" | head -1 | cut -d: -f1)"
  g="$(grep -n '^# ── Guard modules that failed to load' "$HEALTH" | head -1 | cut -d: -f1)"
  [ -n "$i" ] && [ -n "$s" ] && [ -n "$g" ]
  [ "$i" -lt "$s" ]
  [ "$i" -lt "$g" ]
}

@test "A1 a hung stale-memory scanner (2s) does not starve the integrity check: forged cache still alarms" {
  compile_all_pycs
  local pyc; pyc="$(find "$HOME/.claude/scripts/__pycache__" -name 'cast-install-integrity.*.pyc' | head -1)"
  forge_pyc "$pyc"
  printf 'import time\ntime.sleep(60)\n' > "$HOME/.claude/scripts/cast-stale-memories.py"
  run perl -e 'alarm 30; exec @ARGV' bash "$HEALTH" < /dev/null
  [ "$status" -eq 0 ]
  assert_output --partial "scripts/cast-install-integrity.py compiled cache does not match its source"
}

# --- A2: state dir opened once; all access through the fd -------------------------------------------

@test "A2 a cast-state dir with group/other access (0755) is not trusted: nothing is written" {
  mkdir -m 755 "$HOME/.claude/cast-state"
  compile_all_pycs
  run python3 -I "$CHECKER" --home "$HOME"
  assert_success
  [ ! -e "$HOME/.claude/cast-state/pyc-verified.json" ]
}

@test "A2 swapping the cast-state path for a symlink AFTER it is opened cannot redirect the write" {
  local victim="$BATS_TEST_TMPDIR/swapvictim"; mkdir -p "$victim"
  run python3 - "$CHECKER" "$HOME/.claude" "$victim" <<'PYEOF'
import os, sys
checker, claude, victim = sys.argv[1:4]
ns = {"__name__": "cii", "__file__": checker}
exec(compile(open(checker).read(), checker, "exec"), ns)
real_open = os.open
state = {"done": False}
def swapping_open(path, flags, *a, **kw):
    fd = real_open(path, flags, *a, **kw)
    if not state["done"] and flags & getattr(os, "O_DIRECTORY", 0) and str(path).endswith("cast-state"):
        state["done"] = True           # the check passed on this fd; now swap the path component
        os.rename(os.path.join(claude, "cast-state"), os.path.join(claude, "cast-state.real"))
        os.symlink(victim, os.path.join(claude, "cast-state"))
    return fd
os.supports_dir_fd.add(swapping_open)   # the checker gates on `os.open in os.supports_dir_fd`
os.open = swapping_open
ns["_snapshot_save"](claude, {"/x": [1, 2, 3, 4, "abc"]})
os.open = real_open
assert state["done"]
assert os.listdir(victim) == [], os.listdir(victim)
assert os.path.isfile(os.path.join(claude, "cast-state.real", "pyc-verified.json"))
PYEOF
  assert_success
}

# --- A3: one forged cache = one problem --------------------------------------------------------------

@test "A3 a single forged cache produces exactly ONE problem (no extra 'cannot be verified')" {
  compile_all_pycs
  local pyc; pyc="$(find "$HOME/.claude/scripts/__pycache__" -name 'cast-install-integrity.*.pyc' | head -1)"
  forge_pyc "$pyc"
  run python3 -I "$CHECKER" --home "$HOME" --json
  assert_failure
  python3 -c '
import json, sys
d = json.loads(sys.argv[1])
assert [p["kind"] for p in d["problems"]] == ["pyc"], d["problems"]
' "$output"
}

# --- A4: the hook's interpreter comes from the checker's trust rule -------------------------------------

@test "A4 _trusted_exes skips a candidate in a world-writable directory and a missing one" {
  run python3 - "$CHECKER" "$BATS_TEST_TMPDIR" <<'PYEOF'
import os, sys
checker, tmp = sys.argv[1:3]
ns = {"__name__": "cii", "__file__": checker}
exec(compile(open(checker).read(), checker, "exec"), ns)
trusted = ns["_trusted_exes"]
def mk(name, mode):
    d = os.path.join(tmp, name); os.makedirs(d); os.chmod(d, mode)
    f = os.path.join(d, "python3"); open(f, "w").write("#!/bin/sh\n"); os.chmod(f, 0o755)
    return f
good, ww = mk("good", 0o755), mk("ww", 0o777)
assert trusted([ww]) == [], trusted([ww])
assert trusted([ww, good]) == [good]
assert trusted([os.path.join(tmp, "missing")]) == []
PYEOF
  assert_success
}

# --- F1: the checker is read like an untrusted file before anything executes it --------------------

# A checker stand-in that proves execution by touching a marker, and prints valid-looking JSON.
marker_checker() {  # $1 marker path -> script text on stdout
  printf '_PY_CANDIDATES = ()\ndef _trusted_exes(c): return []\nopen("%s", "w").close()\nimport json\nprint(json.dumps({"state": "ok", "checked": 0, "dropped": 0, "problems": [], "pending": 0}))\n' "$1"
}

@test "F1 a SYMLINKED checker is refused (degraded notice) and never executed" {
  local real="$BATS_TEST_TMPDIR/real-checker.py" mark="$BATS_TEST_TMPDIR/ran-symlink"
  marker_checker "$mark" > "$real"
  rm -f "$HOME/.claude/scripts/cast-install-integrity.py"
  ln -s "$real" "$HOME/.claude/scripts/cast-install-integrity.py"
  run_health
  assert_success
  assert_output --partial "install integrity check could not complete (checker failed)"
  [ ! -e "$mark" ]
}

@test "F1 an OVERSIZED checker (1 MiB + 1) is refused quickly and never executed" {
  local mark="$BATS_TEST_TMPDIR/ran-big" f="$HOME/.claude/scripts/cast-install-integrity.py"
  marker_checker "$mark" > "$f"
  python3 -c 'import os,sys; p=sys.argv[1]; open(p,"a").write("#"*(1048577-os.path.getsize(p)))' "$f"
  [ "$(wc -c < "$f")" -gt 1048576 ]
  run perl -e 'alarm 15; exec @ARGV' bash "$HEALTH" < /dev/null
  [ "$status" -eq 0 ]
  assert_output --partial "install integrity check could not complete (checker failed)"
  [ ! -e "$mark" ]
}

@test "F1 a checker exactly at the cap is still accepted (boundary)" {
  local f="$HOME/.claude/scripts/cast-install-integrity.py" mark="$BATS_TEST_TMPDIR/ran-cap"
  { marker_checker "$mark"; } > "$f"
  python3 -c 'import sys; p=sys.argv[1]; open(p,"a").write("#"*(1048576-__import__("os").path.getsize(p)))' "$f"
  [ "$(wc -c < "$f")" -eq 1048576 ]
  run_health
  refute_output --partial "checker failed"
  [ -e "$mark" ]
}

@test "F1 a FIFO checker does not hang the hook; it is reported as changed (the repo sibling checker takes over)" {
  rm -f "$HOME/.claude/scripts/cast-install-integrity.py"
  mkfifo "$HOME/.claude/scripts/cast-install-integrity.py"
  run perl -e 'alarm 20; exec @ARGV' bash "$HEALTH" < /dev/null
  [ "$status" -eq 0 ]   # 142 would mean the alarm fired: the hook hung
  assert_output --partial "scripts/cast-install-integrity.py changed since install"
}

@test "F1 a FIFO checker with no sibling to fall back to: loud 'checker not found', no hang" {
  local alone="$BATS_TEST_TMPDIR/alone"; mkdir -p "$alone"; cp "$HEALTH" "$alone/health.sh"
  rm -f "$HOME/.claude/scripts/cast-install-integrity.py"
  mkfifo "$HOME/.claude/scripts/cast-install-integrity.py"
  run perl -e 'alarm 20; exec @ARGV' bash "$alone/health.sh" < /dev/null
  [ "$status" -eq 0 ]
  assert_output --partial "install integrity check could not complete (checker not found)"
}

# --- cast doctor -------------------------------------------------------------------------------

@test "doctor: clean install reports the integrity check as ok" {
  run bash "$REPO_DIR/bin/cast" doctor
  assert_output --regexp 'install integrity: install manifest verified \([0-9]+ files'
  refute_output --partial "changed since install"
}

@test "doctor: tampered script and deleted githooks fail with the same findings as the hook" {
  echo '# planted' >> "$HOME/.claude/scripts/cast-git-guard.py"
  rm -rf "$HOME/.claude/githooks"
  run bash "$REPO_DIR/bin/cast" doctor
  assert_failure
  assert_output --partial "install integrity: scripts/cast-git-guard.py changed since install"
  assert_output --partial "install integrity: ~/.claude/githooks is missing or not a real directory"
}

@test "doctor: missing manifest is an advisory, not a failure of its own" {
  rm -f "$MANIFEST"
  run bash "$REPO_DIR/bin/cast" doctor
  assert_output --partial "install integrity: no integrity manifest"
  refute_output --regexp 'ERR.*install integrity'
}
