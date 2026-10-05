#!/usr/bin/env bats
# Regression test for scripts/status-writer.sh: `local status="$1"` collided with
# zsh's read-only special parameter `status` (same class as `$?`), breaking
# cast_write_status whenever the file was sourced under zsh. A bash-only BATS
# test would not catch this — must be exercised under a real zsh subshell.

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
STATUS_WRITER_SH="$REPO_DIR/scripts/status-writer.sh"

setup() {
  load 'helpers/setup'
  setup_temp_home  # sets HOME to a temp dir; CAST_STATUS_DIR derives from $HOME
}

teardown() {
  teardown_temp_home
}

@test "cast_write_status succeeds under zsh (regression: 'status' is read-only in zsh)" {
  command -v zsh >/dev/null 2>&1 || skip "zsh not installed"

  run zsh -c "source '$STATUS_WRITER_SH' && cast_write_status DONE 'test summary' 'test-agent-zsh'"
  assert_success

  local written
  written=$(find "$HOME/.claude/agent-status" -name 'test-agent-zsh-*.json' 2>/dev/null | head -1)
  [ -n "$written" ]
  [ -f "$written" ]
}

@test "cast_write_status succeeds under bash (primary path still works)" {
  run bash -c "source '$STATUS_WRITER_SH' && cast_write_status DONE 'test summary' 'test-agent-bash'"
  assert_success

  local written
  written=$(find "$HOME/.claude/agent-status" -name 'test-agent-bash-*.json' 2>/dev/null | head -1)
  [ -n "$written" ]
  [ -f "$written" ]
}

@test "written JSON file has correct status/summary/agent fields" {
  run bash -c "source '$STATUS_WRITER_SH' && cast_write_status DONE_WITH_CONCERNS 'a summary here' 'field-check-agent'"
  assert_success

  local written
  written=$(find "$HOME/.claude/agent-status" -name 'field-check-agent-*.json' 2>/dev/null | head -1)
  [ -n "$written" ]

  run python3 -c "
import json
d = json.load(open('$written'))
assert d['status'] == 'DONE_WITH_CONCERNS', d
assert d['summary'] == 'a summary here', d
assert d['agent'] == 'field-check-agent', d
print('ok')
"
  assert_success
  assert_output "ok"
}

@test "args 6/7 (session_id, agent_type) are written as content fields when supplied" {
  run bash -c "source '$STATUS_WRITER_SH' && cast_write_status DONE 'gate record' 'ident-agent' '' '' 'sess-abc-123' 'security'"
  assert_success

  local written
  written=$(find "$HOME/.claude/agent-status" -name 'ident-agent-*.json' 2>/dev/null | head -1)
  [ -n "$written" ]

  run python3 -c "
import json
d = json.load(open('$written'))
assert d['session_id'] == 'sess-abc-123', d
assert d['agent_type'] == 'security', d
assert d['agent'] == 'ident-agent', d
assert d['status'] == 'DONE', d
print('ok')
"
  assert_success
  assert_output "ok"
}

@test "args 6/7 absent -> session_id and agent_type keys are absent (not empty strings)" {
  run bash -c "source '$STATUS_WRITER_SH' && cast_write_status DONE 'gate record' 'noident-agent'"
  assert_success

  local written
  written=$(find "$HOME/.claude/agent-status" -name 'noident-agent-*.json' 2>/dev/null | head -1)
  [ -n "$written" ]

  run python3 -c "
import json
d = json.load(open('$written'))
assert 'session_id' not in d, d
assert 'agent_type' not in d, d
print('ok')
"
  assert_success
  assert_output "ok"
}

@test "args 6/7 empty strings -> keys omitted; only the non-empty one is written" {
  run bash -c "source '$STATUS_WRITER_SH' && cast_write_status DONE 'gate record' 'partial-agent' '' '' 'sess-only' ''"
  assert_success

  local written
  written=$(find "$HOME/.claude/agent-status" -name 'partial-agent-*.json' 2>/dev/null | head -1)
  [ -n "$written" ]

  run python3 -c "
import json
d = json.load(open('$written'))
assert d['session_id'] == 'sess-only', d
assert 'agent_type' not in d, d
print('ok')
"
  assert_success
  assert_output "ok"
}

# ---------------------------------------------------------------------------
# Confused-deputy hardening: the writer runs unsandboxed from the SubagentStop
# hook, so it must never follow a planted symlink or overwrite a prior record.
# ---------------------------------------------------------------------------

# Run the python writer block, extracted verbatim from status-writer.sh, with
# os.urandom / os.getpid pinned so the record and temp names are predictable
# and a symlink can be pre-planted at them. Arg: the status dir to write to.
run_pinned_writer() {
  local status_dir="$1"
  local blk="$HOME/writer-block.py"
  sed -n "/<<'PYEOF'/,/^PYEOF\$/p" "$STATUS_WRITER_SH" | sed '1d;$d' > "$blk"
  [ -s "$blk" ]
  run python3 -I -c "
import os, sys
os.urandom = lambda n: b'\\x01' * n
os.getpid = lambda: 4242
sys.argv = ['writer', 'sym-agent', 'DONE', 'summary', '', '', '20990101T000000Z', '$status_dir', '', '']
exec(compile(open('$blk').read(), '$blk', 'exec'))
"
}

# File mode of <path> as octal digits, e.g. 600 (BSD/GNU stat flags differ).
mode_of() {
  python3 -c "import os, sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777)[2:])" "$1"
}

@test "status dir that is a symlink -> no record written, victim dir untouched" {
  local victim="$HOME/home-victim-dir"
  mkdir -p "$victim" "$HOME/.claude"
  chmod 755 "$victim"
  ln -s "$victim" "$HOME/.claude/agent-status"

  run bash -c "source '$STATUS_WRITER_SH' && cast_write_status DONE 'gate record' 'sym-dir-agent' '' '' 'sess-1' 'security'"
  assert_success
  assert_output ""

  [ -z "$(find "$victim" -mindepth 1 2>/dev/null)" ]
  run mode_of "$victim"
  assert_output "755"
}

@test "python writer refuses a symlinked status dir on its own (no record, victim untouched)" {
  local victim="$HOME/home-victim-dir"
  mkdir -p "$victim"
  chmod 755 "$victim"
  ln -s "$victim" "$HOME/linked-status"

  run_pinned_writer "$HOME/linked-status"
  assert_success
  assert_output ""

  [ -z "$(find "$victim" -mindepth 1 2>/dev/null)" ]
  run mode_of "$victim"
  assert_output "755"
}

@test "symlink pre-planted at the record path is replaced, not followed (victim unchanged)" {
  local dir="$HOME/.claude/agent-status"
  local victim="$HOME/home-victim-file.txt"
  mkdir -p "$dir"
  printf 'precious\n' > "$victim"
  chmod 644 "$victim"
  ln -s "$victim" "$dir/sym-agent-20990101T000000Z-4242-010101.json"

  run_pinned_writer "$dir"
  assert_success
  assert_output "$dir/sym-agent-20990101T000000Z-4242-010101.json"

  # Victim content and mode are untouched.
  [ "$(cat "$victim")" = "precious" ]
  run mode_of "$victim"
  assert_output "644"
  # The record is now a regular file (rename replaced the link) holding the JSON, mode 600.
  [ ! -L "$dir/sym-agent-20990101T000000Z-4242-010101.json" ]
  [ -f "$dir/sym-agent-20990101T000000Z-4242-010101.json" ]
  run mode_of "$dir/sym-agent-20990101T000000Z-4242-010101.json"
  assert_output "600"
  run python3 -c "
import json
d = json.load(open('$dir/sym-agent-20990101T000000Z-4242-010101.json'))
assert d['status'] == 'DONE', d
print('ok')
"
  assert_output "ok"
}

@test "symlink pre-planted at the temp path -> write refused, victim unchanged, no record" {
  local dir="$HOME/.claude/agent-status"
  local victim="$HOME/home-victim-file.txt"
  mkdir -p "$dir"
  printf 'precious\n' > "$victim"
  chmod 644 "$victim"
  ln -s "$victim" "$dir/.sym-agent-20990101T000000Z-4242-010101.json.tmp-010101"

  run_pinned_writer "$dir"
  assert_failure

  [ "$(cat "$victim")" = "precious" ]
  run mode_of "$victim"
  assert_output "644"
  [ ! -e "$dir/sym-agent-20990101T000000Z-4242-010101.json" ]
}

@test "records written in a tight loop are all distinct files (no same-second overwrite)" {
  run bash -c "source '$STATUS_WRITER_SH' && for i in 1 2 3 4 5; do cast_write_status DONE \"rec \$i\" 'loop-agent' >/dev/null; done"
  assert_success

  local count
  count="$(find "$HOME/.claude/agent-status" -name 'loop-agent-*.json' | wc -l | tr -d ' ')"
  [ "$count" -eq 5 ]
}

@test "a written record is mode 600, names <agent>-<ts>-... and leaves no temp file behind" {
  run bash -c "source '$STATUS_WRITER_SH' && cast_write_status DONE 'gate record' 'mode-agent'"
  assert_success

  local written
  written="$(find "$HOME/.claude/agent-status" -name 'mode-agent-*.json' | head -1)"
  [ -n "$written" ]
  run mode_of "$written"
  assert_output "600"
  [[ "$(basename "$written")" =~ ^mode-agent-[0-9]{8}T[0-9]{6}Z-[0-9]+-[0-9a-f]{6}\.json$ ]]
  [ -z "$(find "$HOME/.claude/agent-status" -name '.*' -not -name '.' -not -name '..' 2>/dev/null)" ]
}

@test "cast_write_status prints the written path on stdout" {
  run bash -c "source '$STATUS_WRITER_SH' && cast_write_status DONE 'gate record' 'stdout-agent'"
  assert_success
  [ -f "$output" ]
  [[ "$output" == "$HOME/.claude/agent-status/stdout-agent-"*.json ]]
}

@test "status dir is created mode 700 when absent (even under a permissive umask)" {
  [ ! -e "$HOME/.claude/agent-status" ]

  run bash -c "umask 000; source '$STATUS_WRITER_SH' && cast_write_status DONE 'gate record' 'newdir-agent'"
  assert_success

  [ -d "$HOME/.claude/agent-status" ]
  [ ! -L "$HOME/.claude/agent-status" ]
  run mode_of "$HOME/.claude/agent-status"
  assert_output "700"
  [ -n "$(find "$HOME/.claude/agent-status" -name 'newdir-agent-*.json')" ]
}

@test "an existing real status dir with mode 777 is re-pinned to 700" {
  mkdir -p "$HOME/.claude/agent-status"
  chmod 777 "$HOME/.claude/agent-status"

  run bash -c "source '$STATUS_WRITER_SH' && cast_write_status DONE 'gate record' 'repin-agent'"
  assert_success

  run mode_of "$HOME/.claude/agent-status"
  assert_output "700"
  [ -n "$(find "$HOME/.claude/agent-status" -name 'repin-agent-*.json')" ]
}

@test "the shell side makes no path-based mkdir/chmod call (chmod follows symlinks)" {
  # PATH-shim mkdir and chmod to log every invocation, then delegate to the real tool.
  local shim="$HOME/shim-bin" log="$HOME/shim-calls.log"
  mkdir -p "$shim"
  : > "$log"
  local real_mkdir real_chmod
  real_mkdir="$(command -v mkdir)"
  real_chmod="$(command -v chmod)"
  printf '#!/bin/bash\necho "mkdir $*" >> "%s"\nexec "%s" "$@"\n' "$log" "$real_mkdir" > "$shim/mkdir"
  printf '#!/bin/bash\necho "chmod $*" >> "%s"\nexec "%s" "$@"\n' "$log" "$real_chmod" > "$shim/chmod"
  "$real_chmod" 755 "$shim/mkdir" "$shim/chmod"

  run env PATH="$shim:$PATH" bash -c "source '$STATUS_WRITER_SH' && cast_write_status DONE 'gate record' 'shim-agent'"
  assert_success

  # The record was still written (python does the mkdir/chmod through an fd) ...
  [ -n "$(find "$HOME/.claude/agent-status" -name 'shim-agent-*.json')" ]
  # ... and the shell never invoked mkdir or chmod.
  [ ! -s "$log" ]
}
