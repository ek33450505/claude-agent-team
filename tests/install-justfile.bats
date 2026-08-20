#!/usr/bin/env bats
# Coverage for install.sh's tools/justfile -> ~/.config/just/justfile install step.
# This step is intentionally OVERWRITE (not skip-if-exists) with a backup-or-abort
# fail-closed gate — see install.sh's "Install tools/justfile" section for why.

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

run_install() {
  CAST_INSTALL_FORCE=1 bash "$REPO_DIR/install.sh" 2>&1
  return $?
}

@test "Install justfile: fresh install writes ~/.config/just/justfile with vendored content" {
  run_install
  [ -f "$HOME/.config/just/justfile" ]
  diff "$REPO_DIR/tools/justfile" "$HOME/.config/just/justfile"
}

@test "Install justfile: re-running install is idempotent (no error, content unchanged)" {
  run_install
  [ -f "$HOME/.config/just/justfile" ]

  run run_install
  assert_success

  diff "$REPO_DIR/tools/justfile" "$HOME/.config/just/justfile"

  # No stray backup should have been created on an idempotent re-run against
  # identical content.
  local bak_count
  bak_count=$(ls -1 "$HOME/.config/just/"justfile.bak.* 2>/dev/null | wc -l | tr -d ' ')
  [ "$bak_count" -eq 0 ]
}

@test "Install justfile: an existing DIFFERENT justfile is backed up (with its old content) then overwritten" {
  mkdir -p "$HOME/.config/just"
  echo "OLD_LOCAL_JUSTFILE_SENTINEL" > "$HOME/.config/just/justfile"

  run_install

  # Overwritten with the vendored content.
  diff "$REPO_DIR/tools/justfile" "$HOME/.config/just/justfile"

  # Exactly one timestamped backup exists, and it holds the OLD content —
  # the backup's content is the safety property under test, not just its existence.
  local bak_count
  bak_count=$(ls -1 "$HOME/.config/just/"justfile.bak.* 2>/dev/null | wc -l | tr -d ' ')
  [ "$bak_count" -eq 1 ]

  local bak_file
  bak_file=$(ls -1 "$HOME/.config/just/"justfile.bak.* 2>/dev/null | head -1)
  grep -q "OLD_LOCAL_JUSTFILE_SENTINEL" "$bak_file"
}

@test "Install justfile: a symlinked destination is left untouched (not written through)" {
  mkdir -p "$HOME/.config/just"
  mkdir -p "$HOME/dotfiles-fixture"
  echo "SYMLINK_TARGET_SENTINEL" > "$HOME/dotfiles-fixture/justfile"
  ln -s "$HOME/dotfiles-fixture/justfile" "$HOME/.config/just/justfile"

  run_install

  # The symlink itself must still be a symlink, still pointing at the same target.
  [ -L "$HOME/.config/just/justfile" ]
  [ "$(readlink "$HOME/.config/just/justfile")" = "$HOME/dotfiles-fixture/justfile" ]

  # The link target must be untouched — CAST must not have written through it.
  grep -q "SYMLINK_TARGET_SENTINEL" "$HOME/dotfiles-fixture/justfile"
  ! diff -q "$HOME/dotfiles-fixture/justfile" "$REPO_DIR/tools/justfile" >/dev/null 2>&1

  # No backup should have been created for a skipped symlink destination.
  local bak_count
  bak_count=$(ls -1 "$HOME/.config/just/"justfile.bak.* 2>/dev/null | wc -l | tr -d ' ')
  [ "$bak_count" -eq 0 ]
}

@test "Install justfile: no stray tmp file remains after fresh install or update" {
  run_install
  local tmp_count
  tmp_count=$(ls -1 "$HOME/.config/just/"*.tmp.* 2>/dev/null | wc -l | tr -d ' ')
  [ "$tmp_count" -eq 0 ]

  echo "DIFFERENT_CONTENT_SENTINEL" >> "$HOME/.config/just/justfile"
  run_install
  tmp_count=$(ls -1 "$HOME/.config/just/"*.tmp.* 2>/dev/null | wc -l | tr -d ' ')
  [ "$tmp_count" -eq 0 ]
}

@test "Install justfile: two different-content updates in rapid succession produce two distinct backups" {
  # Two real install.sh runs rarely land in the same wall-clock second (each
  # does DB init/migrations/etc.), so a same-second collision can't be relied
  # on to happen naturally. Stub `date` to return a FIXED timestamp for both
  # runs, forcing the collision deterministically so this test actually
  # exercises the disambiguation loop rather than getting lucky on timing.
  local fake_bin="$BATS_TEST_TMPDIR/fakebin"
  mkdir -p "$fake_bin"
  cat > "$fake_bin/date" <<'EOS'
#!/usr/bin/env bash
if [ "$1" = "+%Y%m%d%H%M%S" ]; then
  echo "20260101000000"
else
  exec /bin/date "$@"
fi
EOS
  chmod +x "$fake_bin/date"

  mkdir -p "$HOME/.config/just"
  echo "FIRST_OLD_SENTINEL" > "$HOME/.config/just/justfile"
  PATH="$fake_bin:$PATH" run_install

  echo "SECOND_OLD_SENTINEL" > "$HOME/.config/just/justfile"
  PATH="$fake_bin:$PATH" run_install

  local bak_count
  bak_count=$(ls -1 "$HOME/.config/just/"justfile.bak.* 2>/dev/null | wc -l | tr -d ' ')
  [ "$bak_count" -eq 2 ]

  local bak1 bak2
  bak1=$(ls -1 "$HOME/.config/just/"justfile.bak.* | sed -n '1p')
  bak2=$(ls -1 "$HOME/.config/just/"justfile.bak.* | sed -n '2p')

  # Content is the safety property under test, not just the filename/count.
  ! diff -q "$bak1" "$bak2" >/dev/null 2>&1
  grep -q "FIRST_OLD_SENTINEL\|SECOND_OLD_SENTINEL" "$bak1"
  grep -q "FIRST_OLD_SENTINEL\|SECOND_OLD_SENTINEL" "$bak2"
}
