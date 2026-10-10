#!/usr/bin/env bats
# Tests for scripts/cast-agent-memory-init.sh (S4-1 D-E).
# The script WRITES LIVE MEMORY (~/.claude/agent-memory-local/<agent>/MEMORY.md) from a
# background job on every session end, so every test runs against an isolated temp HOME.

load 'helpers/setup'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REPO_DIR/scripts/cast-agent-memory-init.sh"

setup() {
  setup_temp_home
  # cwd outside any git repo so the git-toplevel fallback cannot see the real repo
  cd "$HOME"
  mkdir -p "$HOME/.claude/agents" "$HOME/.claude/cast/events"
  printf -- '---\nname: alpha\n---\nbody\n' > "$HOME/.claude/agents/alpha.md"
  printf -- '---\nname: beta\n---\nbody\n' > "$HOME/.claude/agents/beta.md"
  PROJ="$HOME/work/myproj"
  mkdir -p "$PROJ"
}

teardown() {
  cd /
  # restore permissions the chmod-based tests removed so teardown can delete the tree
  chmod -R u+rwX "$HOME/.claude/agent-memory-local" "$HOME/hl" 2>/dev/null || true
  teardown_temp_home
}

_snapshot() { (cd "$HOME" && find . -type f | LC_ALL=C sort); }

@test "creates MEMORY.md per agent and writes nothing outside agent-memory-local" {
  _snapshot > "$BATS_TEST_TMPDIR/before"
  run bash "$SCRIPT" --project-root "$PROJ"
  [ "$status" -eq 0 ]
  [ -f "$HOME/.claude/agent-memory-local/alpha/MEMORY.md" ]
  [ -f "$HOME/.claude/agent-memory-local/beta/MEMORY.md" ]
  _snapshot > "$BATS_TEST_TMPDIR/after"
  # every new file lives under agent-memory-local
  run bash -c "LC_ALL=C comm -13 '$BATS_TEST_TMPDIR/before' '$BATS_TEST_TMPDIR/after' | grep -v '^./.claude/agent-memory-local/'"
  [ "$status" -eq 1 ]
  # and no pre-existing file disappeared
  run bash -c "LC_ALL=C comm -23 '$BATS_TEST_TMPDIR/before' '$BATS_TEST_TMPDIR/after'"
  [ -z "$output" ]
  # exactly the two agents were seeded
  [ "$(find "$HOME/.claude/agent-memory-local" -name MEMORY.md | wc -l | tr -d ' ')" -eq 2 ]
}

@test "writes a YAML header with project, agent and type" {
  run bash "$SCRIPT" --project-root "$PROJ"
  [ "$status" -eq 0 ]
  local f="$HOME/.claude/agent-memory-local/alpha/MEMORY.md"
  [ "$(sed -n 1p "$f")" = "---" ]
  grep -qx 'project: myproj' "$f"
  grep -qx 'type: agent-memory' "$f"
  grep -qx 'agent: alpha' "$f"
  grep -qE '^updated: [0-9]{4}-[0-9]{2}-[0-9]{2}$' "$f"
  [ "$(sed -n 6p "$f")" = "---" ]
}

@test "preserves a planted Custom Notes section verbatim and drops other stale content" {
  local f="$HOME/.claude/agent-memory-local/alpha/MEMORY.md"
  mkdir -p "$(dirname "$f")"
  cat > "$f" <<'EOF'
---
project: old
type: agent-memory
agent: alpha
updated: 2020-01-01
---

# STALE_TITLE_MARKER

## Stale Section
STALE_BODY_MARKER

## Custom Notes
first custom line
  indented custom line
- bullet with `code` and $dollar

### Sub heading kept
last custom line
EOF
  run bash "$SCRIPT" --project-root "$PROJ"
  [ "$status" -eq 0 ]
  run cat "$f"
  [[ "$output" == *$'## Custom Notes\nfirst custom line\n  indented custom line\n- bullet with `code` and $dollar\n\n### Sub heading kept\nlast custom line'* ]]
  [[ "$output" != *STALE_BODY_MARKER* ]]
  [[ "$output" != *STALE_TITLE_MARKER* ]]
  # header regenerated, not carried over from the stale file
  [[ "$output" != *"project: old"* ]]
  [[ "$output" == *"project: myproj"* ]]
}

@test "re-running is stable: Custom Notes not duplicated" {
  local f="$HOME/.claude/agent-memory-local/beta/MEMORY.md"
  mkdir -p "$(dirname "$f")"
  printf '## Custom Notes\nkeep me\n' > "$f"
  bash "$SCRIPT" --project-root "$PROJ"
  bash "$SCRIPT" --project-root "$PROJ"
  [ "$(grep -c '^## Custom Notes$' "$f")" -eq 1 ]
  [ "$(grep -c '^keep me$' "$f")" -eq 1 ]
}

@test "a file without Custom Notes gets none" {
  run bash "$SCRIPT" --project-root "$PROJ"
  [ "$status" -eq 0 ]
  run grep -c 'Custom Notes' "$HOME/.claude/agent-memory-local/alpha/MEMORY.md"
  [ "$output" = "0" ]
}

@test "Recent Tasks and BLOCKED History come from the events dir" {
  cat > "$HOME/.claude/cast/events/001.json" <<'EOF'
{"agent":"alpha","type":"task_completed","timestamp":"2026-10-01T10:00:00Z","message":"finished the widget","batch":"B7"}
EOF
  cat > "$HOME/.claude/cast/events/002.json" <<'EOF'
{"agent":"alpha","type":"task_blocked","timestamp":"2026-10-02T11:00:00Z","message":"needs the schema","batch":"B8"}
EOF
  run bash "$SCRIPT" --project-root "$PROJ"
  [ "$status" -eq 0 ]
  local f="$HOME/.claude/agent-memory-local/alpha/MEMORY.md"
  run sed -n '/^## Recent Tasks/,/^## BLOCKED History/p' "$f"
  [[ "$output" == *"- [2026-10-01] completed | B7 | finished the widget"* ]]
  [[ "$output" == *"- [2026-10-02] blocked | B8 | needs the schema"* ]]
  run sed -n '/^## BLOCKED History/,$p' "$f"
  [[ "$output" == *"- [2026-10-02] BLOCKED | needs the schema"* ]]
  [[ "$output" != *"finished the widget"* ]]
  # beta has no events of its own
  run cat "$HOME/.claude/agent-memory-local/beta/MEMORY.md"
  [[ "$output" == *"- No recent tasks recorded"* ]]
  [[ "$output" == *"- No blocked history"* ]]
}

@test "malformed event JSON is skipped and the valid event still lands" {
  printf 'not json{' > "$HOME/.claude/cast/events/000.json"
  cat > "$HOME/.claude/cast/events/001.json" <<'EOF'
{"agent":"alpha","type":"task_completed","timestamp":"2026-10-01T10:00:00Z","message":"ok event","batch":"B1"}
EOF
  run bash "$SCRIPT" --project-root "$PROJ"
  [ "$status" -eq 0 ]
  grep -q 'ok event' "$HOME/.claude/agent-memory-local/alpha/MEMORY.md"
}

@test "--project-root <path> sets project name and Root" {
  run bash "$SCRIPT" --project-root "$PROJ"
  [ "$status" -eq 0 ]
  local f="$HOME/.claude/agent-memory-local/alpha/MEMORY.md"
  grep -qx -- "- Project: myproj" "$f"
  grep -qx -- "- Root: $PROJ" "$f"
}

@test "--project-root=<path> form is accepted" {
  run bash "$SCRIPT" "--project-root=$PROJ"
  [ "$status" -eq 0 ]
  grep -qx -- "- Root: $PROJ" "$HOME/.claude/agent-memory-local/alpha/MEMORY.md"
}

@test "--project-root works regardless of position (old code read \$2)" {
  mkdir -p "$HOME/work/other"
  run bash "$SCRIPT" --unknown-flag --project-root "$HOME/work/other"
  [ "$status" -eq 0 ]
  grep -qx -- "- Project: other" "$HOME/.claude/agent-memory-local/alpha/MEMORY.md"
}

@test "no arguments (session-end invocation) falls back to git toplevel of cwd" {
  local repo="$HOME/work/gitproj"
  mkdir -p "$repo"
  git -C "$repo" init -q
  cd "$repo"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  local f="$HOME/.claude/agent-memory-local/alpha/MEMORY.md"
  grep -qx -- "- Project: gitproj" "$f"
  # realpath may differ from $HOME on macOS (/var -> /private/var), so match on the suffix
  grep -q "^- Root: .*work/gitproj$" "$f"
}

@test "no arguments outside a git repo yields project unknown" {
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  local f="$HOME/.claude/agent-memory-local/alpha/MEMORY.md"
  grep -qx -- "- Project: unknown" "$f"
  grep -qx -- "- Root: unknown" "$f"
}

@test "--project-root with a missing value leaves Root unknown" {
  run bash "$SCRIPT" --project-root
  [ "$status" -eq 0 ]
  grep -qx -- "- Root: unknown" "$HOME/.claude/agent-memory-local/alpha/MEMORY.md"
}

@test "Stack line is gone (no hardcoded React/Vite/Express claim)" {
  run bash "$SCRIPT" --project-root "$PROJ"
  [ "$status" -eq 0 ]
  local f="$HOME/.claude/agent-memory-local/alpha/MEMORY.md"
  run grep -ci -e '^- Stack:' -e 'React 19' "$f"
  [ "$output" = "0" ]
  # control: the same grep does bite when the text is present
  run grep -ci -e '^- Project:' "$f"
  [ "$output" = "1" ]
}

@test "header comment names cast-session-end.sh, not stop-hook.sh" {
  run grep -c 'cast-session-end.sh' "$SCRIPT"
  [ "$output" -ge 1 ]
  run grep -c 'stop-hook.sh' "$SCRIPT"
  [ "$output" = "0" ]
}

@test "empty agents dir falls back to the repo agents/core" {
  rm -f "$HOME/.claude/agents"/*.md
  run bash "$SCRIPT" --project-root "$PROJ"
  [ "$status" -eq 0 ]
  local expected
  expected="$(find "$REPO_DIR/agents/core" -name '*.md' | wc -l | tr -d ' ')"
  [ "$expected" -gt 0 ]
  [ "$(find "$HOME/.claude/agent-memory-local" -name MEMORY.md | wc -l | tr -d ' ')" -eq "$expected" ]
}

@test "missing agents dir falls back to the repo agents/core" {
  rm -rf "$HOME/.claude/agents"
  run bash "$SCRIPT" --project-root "$PROJ"
  [ "$status" -eq 0 ]
  [ "$(find "$HOME/.claude/agent-memory-local" -name MEMORY.md | wc -l | tr -d ' ')" -gt 0 ]
}

@test "no agents anywhere seeds nothing and exits 0" {
  # copy the script to a tree with no ../agents/core so the fallback is empty too
  mkdir -p "$HOME/iso/scripts"
  cp "$SCRIPT" "$HOME/iso/scripts/"
  rm -rf "$HOME/.claude/agents"
  run bash "$HOME/iso/scripts/cast-agent-memory-init.sh" --project-root "$PROJ"
  [ "$status" -eq 0 ]
  [ ! -d "$HOME/.claude/agent-memory-local" ] || [ -z "$(find "$HOME/.claude/agent-memory-local" -name MEMORY.md)" ]
}

@test "missing events dir yields the no-recent-tasks placeholder" {
  rm -rf "$HOME/.claude/cast"
  run bash "$SCRIPT" --project-root "$PROJ"
  [ "$status" -eq 0 ]
  grep -q 'No recent tasks recorded' "$HOME/.claude/agent-memory-local/alpha/MEMORY.md"
}

_sha() { shasum -a 256 "$1" | cut -d' ' -f1; }

_plant_notes() { # $1 = agent; plants a MEMORY.md with Custom Notes, echoes its path
  local f="$HOME/.claude/agent-memory-local/$1/MEMORY.md"
  mkdir -p "$(dirname "$f")"
  printf -- '---\nproject: old\n---\n\n# stale\n\n## Custom Notes\nPRECIOUS_NOTE_%s\n' "$1" > "$f"
  echo "$f"
}

@test "W1: unreadable MEMORY.md is left byte-identical and logged, other agents still seeded" {
  [ "$(id -u)" -ne 0 ] || skip "root ignores file permissions"
  local f; f="$(_plant_notes alpha)"
  local before; before="$(_sha "$f")"
  chmod 000 "$f"
  run bash "$SCRIPT" --project-root "$PROJ"
  chmod 600 "$f"
  [ "$status" -eq 0 ]
  [ "$(_sha "$f")" = "$before" ]
  grep -q 'PRECIOUS_NOTE_alpha' "$f"
  [[ "$output" == *"cannot read"* ]]
  # the skip is per-agent: beta was still seeded
  grep -qx 'agent: beta' "$HOME/.claude/agent-memory-local/beta/MEMORY.md"
  [ -z "$(find "$HOME/.claude/agent-memory-local" -name '*.tmp*')" ]
}

@test "W1: undecodable MEMORY.md is left byte-identical" {
  local f="$HOME/.claude/agent-memory-local/alpha/MEMORY.md"
  mkdir -p "$(dirname "$f")"
  printf '## Custom Notes\nbad byte \377\376 here\n' > "$f"
  local before; before="$(_sha "$f")"
  run bash "$SCRIPT" --project-root "$PROJ"
  [ "$status" -eq 0 ]
  [ "$(_sha "$f")" = "$before" ]
  [[ "$output" == *"cannot read"* ]]
}

@test "W2: write is atomic (replace, not truncate-in-place) and leaves no temp files" {
  local f; f="$(_plant_notes alpha)"
  # a hard link shares the inode: an in-place truncate+write would rewrite it too
  ln "$f" "$HOME/hl"
  run bash "$SCRIPT" --project-root "$PROJ"
  [ "$status" -eq 0 ]
  # new content landed in MEMORY.md, complete, with notes
  grep -qx 'project: myproj' "$f"
  grep -q 'PRECIOUS_NOTE_alpha' "$f"
  grep -q '^## BLOCKED History$' "$f"
  # the old inode is untouched => the file was replaced, not rewritten in place
  grep -qx 'project: old' "$HOME/hl"
  [ -z "$(find "$HOME/.claude/agent-memory-local" -name '*.tmp*')" ]
}

@test "W2: concurrent runs never lose Custom Notes" {
  local a
  for a in $(seq 1 30); do
    printf -- '---\nname: gen%s\n---\n' "$a" > "$HOME/.claude/agents/gen$a.md"
    _plant_notes "gen$a" > /dev/null
  done
  _plant_notes alpha > /dev/null
  _plant_notes beta > /dev/null
  bash "$SCRIPT" --project-root "$PROJ" &
  bash "$SCRIPT" --project-root "$PROJ" &
  bash "$SCRIPT" --project-root "$PROJ" &
  wait
  local d
  for d in alpha beta $(seq -f 'gen%g' 1 30); do
    grep -q "PRECIOUS_NOTE_$d" "$HOME/.claude/agent-memory-local/$d/MEMORY.md"
    [ "$(grep -c '^## Custom Notes$' "$HOME/.claude/agent-memory-local/$d/MEMORY.md")" -eq 1 ]
  done
  [ -z "$(find "$HOME/.claude/agent-memory-local" -name '*.tmp*')" ]
}

@test "S1: --project-root followed by a flag does not take the flag as the path" {
  run bash "$SCRIPT" --project-root --foo
  [ "$status" -eq 0 ]
  local f="$HOME/.claude/agent-memory-local/alpha/MEMORY.md"
  grep -qx -- "- Root: unknown" "$f"
  run grep -c -e '--foo' "$f"
  [ "$output" = "0" ]
}

@test "S1: a rejected flag-like value warns and a later real --project-root still wins" {
  run bash "$SCRIPT" --project-root --foo --project-root "$PROJ"
  [ "$status" -eq 0 ]
  [[ "$output" == *"looks like a flag"* ]]
  grep -qx -- "- Root: $PROJ" "$HOME/.claude/agent-memory-local/alpha/MEMORY.md"
}

@test "S1: --project-root=--foo is rejected too" {
  run bash "$SCRIPT" "--project-root=--foo"
  [ "$status" -eq 0 ]
  grep -qx -- "- Root: unknown" "$HOME/.claude/agent-memory-local/alpha/MEMORY.md"
}

@test "S2: a level-3 '### Custom Notes' heading is not the preservation anchor" {
  local f="$HOME/.claude/agent-memory-local/alpha/MEMORY.md"
  mkdir -p "$(dirname "$f")"
  cat > "$f" <<'EOF'
# stale

### Custom Notes
FAKE_L3_MARKER

## Custom Notes
real level-2 note
EOF
  run bash "$SCRIPT" --project-root "$PROJ"
  [ "$status" -eq 0 ]
  run cat "$f"
  [[ "$output" == *$'## Custom Notes\nreal level-2 note'* ]]
  [[ "$output" != *FAKE_L3_MARKER* ]]
  [ "$(grep -c 'Custom Notes' "$f")" -eq 1 ]
}

@test "S2: a file with only a level-3 '### Custom Notes' heading gets no Custom Notes" {
  local f="$HOME/.claude/agent-memory-local/alpha/MEMORY.md"
  mkdir -p "$(dirname "$f")"
  printf '### Custom Notes\nFAKE_L3_MARKER\n' > "$f"
  run bash "$SCRIPT" --project-root "$PROJ"
  [ "$status" -eq 0 ]
  run grep -c -e 'Custom Notes' -e FAKE_L3_MARKER "$f"
  [ "$output" = "0" ]
}

@test "R1: suffixed level-2 Custom Notes headings are preserved verbatim, '## Custom Notesfoo' is not" {
  local f="$HOME/.claude/agent-memory-local/alpha/MEMORY.md"
  mkdir -p "$(dirname "$f")"
  printf '# stale\n\n## Custom Notesfoo\nNOT_AN_ANCHOR\n\n## Custom Notes (private)\nprivate note\n\n## Custom Notes:\ncolon note\n' > "$f"
  run bash "$SCRIPT" --project-root "$PROJ"
  [ "$status" -eq 0 ]
  run cat "$f"
  [[ "$output" == *$'## Custom Notes (private)\nprivate note\n\n## Custom Notes:\ncolon note'* ]]
  [[ "$output" != *NOT_AN_ANCHOR* ]]
  # the colon form alone is also an anchor
  printf '# stale\n\n## Custom Notes:\nonly colon\n' > "$f"
  run bash "$SCRIPT" --project-root "$PROJ"
  run cat "$f"
  [[ "$output" == *$'## Custom Notes:\nonly colon'* ]]
}

@test "R2: a failing write (lone surrogate) leaves MEMORY.md intact, no temp file, other agents still seeded" {
  local f; f="$(_plant_notes alpha)"
  local before; before="$(_sha "$f")"
  printf '%s' '{"agent":"alpha","type":"task_completed","timestamp":"2026-10-01T10:00:00Z","message":"bad \udc80 char","batch":"B1"}' > "$HOME/.claude/cast/events/001.json"
  _plant_notes beta > /dev/null
  run bash "$SCRIPT" --project-root "$PROJ"
  [ "$status" -eq 0 ]
  [ "$(_sha "$f")" = "$before" ]
  [[ "$output" == *"cannot write"* ]]
  [ -z "$(find "$HOME/.claude/agent-memory-local" -name '*.tmp*')" ]
  # beta, processed after alpha's failure, was rewritten and kept its notes
  grep -qx 'project: myproj' "$HOME/.claude/agent-memory-local/beta/MEMORY.md"
  grep -q 'PRECIOUS_NOTE_beta' "$HOME/.claude/agent-memory-local/beta/MEMORY.md"
}

@test "R3: an existing MEMORY.md keeps its mode (0600 and 0444) across a run" {
  local f; f="$(_plant_notes alpha)"
  chmod 600 "$f"
  run bash "$SCRIPT" --project-root "$PROJ"
  [ "$status" -eq 0 ]
  [ -n "$(find "$f" -perm 600)" ]
  grep -qx 'project: myproj' "$f"
  chmod 444 "$f"
  run bash "$SCRIPT" --project-root "$PROJ"
  [ "$status" -eq 0 ]
  [ -n "$(find "$f" -perm 444)" ]
  grep -q 'PRECIOUS_NOTE_alpha' "$f"
}

@test "R4: a symlinked MEMORY.md is skipped: link and target untouched, other agents still seeded" {
  local f="$HOME/.claude/agent-memory-local/alpha/MEMORY.md"
  mkdir -p "$(dirname "$f")"
  printf 'TARGET_ORIGINAL\n## Custom Notes\nlinked note\n' > "$HOME/target.txt"
  ln -s "$HOME/target.txt" "$f"
  local before; before="$(_sha "$HOME/target.txt")"
  run bash "$SCRIPT" --project-root "$PROJ"
  [ "$status" -eq 0 ]
  [ -L "$f" ]
  [ "$(readlink "$f")" = "$HOME/target.txt" ]
  [ "$(_sha "$HOME/target.txt")" = "$before" ]
  [[ "$output" == *"symlink"* ]]
  [ -z "$(find "$HOME/.claude/agent-memory-local" -name '*.tmp*')" ]
  grep -qx 'agent: beta' "$HOME/.claude/agent-memory-local/beta/MEMORY.md"
}

@test "R4: a dangling symlinked MEMORY.md is skipped and its target is not created" {
  local f="$HOME/.claude/agent-memory-local/alpha/MEMORY.md"
  mkdir -p "$(dirname "$f")"
  ln -s "$HOME/not-created.txt" "$f"
  run bash "$SCRIPT" --project-root "$PROJ"
  [ "$status" -eq 0 ]
  [ -L "$f" ]
  [ ! -e "$HOME/not-created.txt" ]
}

@test "R4: a symlinked agent directory is skipped: its target dir is untouched, other agents still seeded" {
  mkdir -p "$HOME/realdir" "$HOME/.claude/agent-memory-local"
  printf '## Custom Notes\ndir-linked note\n' > "$HOME/realdir/MEMORY.md"
  ln -s "$HOME/realdir" "$HOME/.claude/agent-memory-local/alpha"
  local before; before="$(_sha "$HOME/realdir/MEMORY.md")"
  run bash "$SCRIPT" --project-root "$PROJ"
  [ "$status" -eq 0 ]
  [ -L "$HOME/.claude/agent-memory-local/alpha" ]
  [ "$(_sha "$HOME/realdir/MEMORY.md")" = "$before" ]
  [ "$(find "$HOME/realdir" -type f | wc -l | tr -d ' ')" -eq 1 ]
  grep -qx 'agent: beta' "$HOME/.claude/agent-memory-local/beta/MEMORY.md"
}
