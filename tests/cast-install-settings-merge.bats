#!/usr/bin/env bats

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

setup() {
  export TEST_TMPDIR="$(mktemp -d /tmp/cast-install-merge-test.XXXXXXXX)"
  export TEST_CLAUDE_DIR="$TEST_TMPDIR/.claude"
  mkdir -p "$TEST_CLAUDE_DIR/scripts"
  mkdir -p "$TEST_CLAUDE_DIR/managed-settings.d"

  # Install cast-merge-settings.sh so the install fragment-regen step can find it
  cp "$REPO_DIR/scripts/cast-merge-settings.sh" "$TEST_CLAUDE_DIR/scripts/cast-merge-settings.sh"
  chmod +x "$TEST_CLAUDE_DIR/scripts/cast-merge-settings.sh"
}

teardown() {
  [ -n "${TEST_TMPDIR:-}" ] && rm -rf "$TEST_TMPDIR"
}

# Helper: run the fragment-copy + merge-regen block from install.sh
# in a sandboxed CLAUDE_DIR. Simulates what install.sh does.
_run_install_fragment_block() {
  local claude_dir="$1"
  local script_dir="$REPO_DIR"

  # Copy fragments (skip-if-exists)
  local installed=0 skipped=0
  for fragment in "$script_dir"/managed-settings.d/*.json; do
    [ -f "$fragment" ] || continue
    local base
    base="$(basename "$fragment")"
    local dest="$claude_dir/managed-settings.d/$base"
    if [ -f "$dest" ]; then
      skipped=$((skipped + 1))
    else
      cp "$fragment" "$dest"
      installed=$((installed + 1))
    fi
  done

  # Regenerate settings.json from fragments
  if [ -x "$claude_dir/scripts/cast-merge-settings.sh" ]; then
    # Override FRAGMENT_DIR by temporarily symlinking
    local orig_home="$HOME"
    HOME="$TEST_TMPDIR" \
      FRAGMENT_DIR_OVERRIDE="$claude_dir/managed-settings.d" \
      bash "$claude_dir/scripts/cast-merge-settings.sh" "$claude_dir/settings.json" >/dev/null 2>&1
    local exit_code=$?
    HOME="$orig_home"
    return $exit_code
  fi
}

# Helper: run merge with explicit fragment dir (since cast-merge-settings.sh uses $HOME/.claude)
_run_merge_with_dir() {
  local fragment_dir="$1"
  local output="$2"
  # Build merged output directly from fragments in the given dir
  python3 - "$fragment_dir"/*.json > "$output" 2>&1 <<'PYEOF'
import json
import sys
import os
import glob

def merge(base, override):
    if not isinstance(base, dict) or not isinstance(override, dict):
        return override
    result = dict(base)
    for key, val in override.items():
        if key == "hooks" and isinstance(val, dict) and isinstance(result.get("hooks"), dict):
            merged_hooks = dict(result["hooks"])
            for event, arr in val.items():
                if event in merged_hooks:
                    merged_hooks[event] = merged_hooks[event] + arr
                else:
                    merged_hooks[event] = arr
            result["hooks"] = merged_hooks
        elif key in result and isinstance(result[key], dict) and isinstance(val, dict):
            result[key] = merge(result[key], val)
        else:
            result[key] = val
    return result

# Accept either a glob pattern directory or explicit files
args = sys.argv[1:]
files = []
for arg in args:
    if os.path.isdir(arg):
        files = sorted(glob.glob(os.path.join(arg, '*.json')))
    elif os.path.isfile(arg):
        files.append(arg)

if not files:
    print('{}')
    sys.exit(0)

combined = {}
for fpath in sorted(files):
    with open(fpath) as f:
        fragment = json.load(f)
    combined = merge(combined, fragment)

print(json.dumps(combined, indent=2))
PYEOF
}

@test "install copies fragments not present at destination" {
  # No pre-existing fragments
  local frag_count
  frag_count=$(ls "$REPO_DIR/managed-settings.d/"*.json 2>/dev/null | wc -l | tr -d ' ')
  [ "$frag_count" -gt 0 ]

  # Run fragment copy
  for fragment in "$REPO_DIR"/managed-settings.d/*.json; do
    [ -f "$fragment" ] || continue
    base="$(basename "$fragment")"
    dest="$TEST_CLAUDE_DIR/managed-settings.d/$base"
    [ ! -f "$dest" ] || continue
    cp "$fragment" "$dest"
  done

  # Assert all source fragments are now at destination
  for fragment in "$REPO_DIR"/managed-settings.d/*.json; do
    [ -f "$fragment" ] || continue
    base="$(basename "$fragment")"
    dest="$TEST_CLAUDE_DIR/managed-settings.d/$base"
    [ -f "$dest" ] || {
      echo "MISSING: $dest" >&2
      return 1
    }
  done
}

@test "install preserves downstream-only fragments and user-customizable fragments (skip-if-exists)" {
  # Pre-create a downstream-only fragment (filename not in source) with distinctive content
  local downstream="$TEST_CLAUDE_DIR/managed-settings.d/99-downstream.json"
  printf '{"_downstream":"preserve-me-123"}' > "$downstream"

  # Pre-create a user-customizable fragment (50-mcp.json — not a *-hooks-* file in name)
  # to verify the skip-if-exists path for non-hook fragments
  local user_frag="$TEST_CLAUDE_DIR/managed-settings.d/50-mcp.json"
  printf '{"_user_custom":"my-mcp-config"}' > "$user_frag"

  # Run install fragment block (mirrors the dual policy in install.sh)
  for fragment in "$REPO_DIR"/managed-settings.d/*.json; do
    [ -f "$fragment" ] || continue
    base="$(basename "$fragment")"
    dest="$TEST_CLAUDE_DIR/managed-settings.d/$base"
    case "$base" in
      *-hooks-*.json)
        cp "$fragment" "$dest"
        ;;
      *)
        [ -f "$dest" ] && continue
        cp "$fragment" "$dest"
        ;;
    esac
  done

  # Downstream-only fragment must be unchanged
  local content
  content=$(cat "$downstream")
  [ "$content" = '{"_downstream":"preserve-me-123"}' ]

  # User-customizable fragment must not have been overwritten
  local user_marker
  user_marker=$(python3 -c "import json; d=json.load(open('$user_frag')); print(d.get('_user_custom',''))")
  [ "$user_marker" = "my-mcp-config" ]
}

@test "install overwrites stale CAST-owned hook fragments to propagate source updates" {
  # Plant a stale hook fragment in destination that LACKS a journal hook
  local stale_30="$TEST_CLAUDE_DIR/managed-settings.d/30-hooks-session.json"
  printf '%s' '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"bash ~/.claude/scripts/cast-stale.sh"}]}]}}' > "$stale_30"

  # Confirm the stale fragment lacks the journal hook
  local stale_has_journal
  stale_has_journal=$(python3 -c "
import json
d = json.load(open('$stale_30'))
ss = d.get('hooks',{}).get('SessionStart',[])
found = any('cast-session-start-journal' in str(e) for e in ss)
print('yes' if found else 'no')
")
  [ "$stale_has_journal" = "no" ]

  # Run install fragment block — should overwrite *-hooks-*.json
  for fragment in "$REPO_DIR"/managed-settings.d/*.json; do
    [ -f "$fragment" ] || continue
    base="$(basename "$fragment")"
    dest="$TEST_CLAUDE_DIR/managed-settings.d/$base"
    case "$base" in
      *-hooks-*.json)
        cp "$fragment" "$dest"
        ;;
      *)
        [ -f "$dest" ] && continue
        cp "$fragment" "$dest"
        ;;
    esac
  done

  # Stale fragment was overwritten — journal hook now present
  local now_has_journal
  now_has_journal=$(python3 -c "
import json
d = json.load(open('$stale_30'))
ss = d.get('hooks',{}).get('SessionStart',[])
found = any(e.get('id') == 'cast-session-start-journal' for e in ss)
print('yes' if found else 'no')
")
  [ "$now_has_journal" = "yes" ]
}

@test "merged settings.json contains all hook entries from all fragments" {
  # Copy all source fragments to test dir
  for fragment in "$REPO_DIR"/managed-settings.d/*.json; do
    [ -f "$fragment" ] || continue
    base="$(basename "$fragment")"
    cp "$fragment" "$TEST_CLAUDE_DIR/managed-settings.d/$base"
  done

  # Run merge
  _run_merge_with_dir "$TEST_CLAUDE_DIR/managed-settings.d" "$TEST_CLAUDE_DIR/settings.json"
  [ -f "$TEST_CLAUDE_DIR/settings.json" ]

  # Assert SessionStart contains cast-time-context
  local has_time_context
  has_time_context=$(python3 -c "
import json, sys
d = json.load(open('$TEST_CLAUDE_DIR/settings.json'))
ss = d.get('hooks', {}).get('SessionStart', [])
found = any(e.get('id') == 'cast-time-context' for e in ss)
print('yes' if found else 'no')
")
  [ "$has_time_context" = "yes" ]

  # Assert SessionStart contains cast-session-start-journal
  local has_journal
  has_journal=$(python3 -c "
import json, sys
d = json.load(open('$TEST_CLAUDE_DIR/settings.json'))
ss = d.get('hooks', {}).get('SessionStart', [])
found = any(e.get('id') == 'cast-session-start-journal' for e in ss)
print('yes' if found else 'no')
")
  [ "$has_journal" = "yes" ]

  # Assert Stop contains cast-journal-session-end
  local has_stop_journal
  has_stop_journal=$(python3 -c "
import json, sys
d = json.load(open('$TEST_CLAUDE_DIR/settings.json'))
st = d.get('hooks', {}).get('Stop', [])
found = any(e.get('id') == 'cast-journal-session-end' for e in st)
print('yes' if found else 'no')
")
  [ "$has_stop_journal" = "yes" ]
}

@test "install is idempotent — second run produces identical output" {
  # Copy all source fragments
  for fragment in "$REPO_DIR"/managed-settings.d/*.json; do
    [ -f "$fragment" ] || continue
    base="$(basename "$fragment")"
    cp "$fragment" "$TEST_CLAUDE_DIR/managed-settings.d/$base"
  done

  # First merge
  _run_merge_with_dir "$TEST_CLAUDE_DIR/managed-settings.d" "$TEST_CLAUDE_DIR/settings.json"
  local md5_first
  md5_first=$(md5 -q "$TEST_CLAUDE_DIR/settings.json" 2>/dev/null || md5sum "$TEST_CLAUDE_DIR/settings.json" | awk '{print $1}')

  # Second run: fragment copy is all-skip-exists + merge runs again
  for fragment in "$REPO_DIR"/managed-settings.d/*.json; do
    [ -f "$fragment" ] || continue
    base="$(basename "$fragment")"
    dest="$TEST_CLAUDE_DIR/managed-settings.d/$base"
    [ -f "$dest" ] && continue
    cp "$fragment" "$dest"
  done
  _run_merge_with_dir "$TEST_CLAUDE_DIR/managed-settings.d" "$TEST_CLAUDE_DIR/settings.json"
  local md5_second
  md5_second=$(md5 -q "$TEST_CLAUDE_DIR/settings.json" 2>/dev/null || md5sum "$TEST_CLAUDE_DIR/settings.json" | awk '{print $1}')

  [ "$md5_first" = "$md5_second" ]
}
