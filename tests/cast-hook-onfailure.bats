#!/usr/bin/env bats
# tests/cast-hook-onfailure.bats
# U1: native hook field "onFailure": "block" (Claude Code >= 2.1.295) on the
# three fail-closed CAST guards ONLY, plus the install-time version-floor WARN.
#
# Brick guard: UserPromptSubmit/SessionStart/telemetry/async hooks must stay
# fail-open — a broken memory router must never block prompts.

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO="${BATS_TEST_DIRNAME}/.."
FRAGMENT="${REPO}/managed-settings.d/25-hooks-security.json"
FRAGMENTS_DIR="${REPO}/managed-settings.d"
SETTINGS="${REPO}/settings.json"
PLUGIN_HOOKS="${REPO}/plugin/hooks/hooks.json"
FLOOR_SCRIPT="${REPO}/scripts/cast-cc-version-floor.sh"

# Prints "<event>|<id>|<command>|<onFailure>|<async>" for every inner hook in $1.
_hooks() {
  python3 - "$1" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
for ev, groups in (d.get("hooks") or {}).items():
    for g in groups:
        for h in g.get("hooks", []):
            print("|".join([ev, str(g.get("id", "")), h.get("command", ""),
                            str(h.get("onFailure", "")), str(h.get("async", ""))]))
PY
}

# Asserts exactly the three guard hooks carry onFailure == block in file $1.
_assert_three_guards() {
  local out
  out="$(_hooks "$1")"
  echo "$out" | grep -F 'ConfigChange|' | grep -F 'cast-config-change-guard.sh' | grep -q '|block|' || return 1
  echo "$out" | grep -F 'PreToolUse|cast-pretool-dispatch|' | grep -q '|block|' || return 1
  echo "$out" | grep -F 'PreToolUse|cast-write-guards|' | grep -q '|block|' || return 1
}

# --- (a) fragment ---------------------------------------------------------

@test "fragment: the three guard hooks carry onFailure block" {
  run _assert_three_guards "$FRAGMENT"
  assert_success
}

@test "fragment: cast-audit-hook.sh hooks do NOT carry onFailure" {
  run bash -c "$(declare -f _hooks); _hooks '$FRAGMENT' | grep -F 'cast-audit-hook.sh'"
  assert_success
  assert_output --partial 'cast-audit-hook.sh --mode pre'
  assert_output --partial 'cast-audit-hook.sh --mode post'
  refute_output --partial '|block|'
}

# --- (b) brick guard ------------------------------------------------------

@test "brick guard: onFailure block appears only under PreToolUse or ConfigChange (allowlist)" {
  run python3 - "$FRAGMENTS_DIR" <<'PY'
import glob, json, os, sys
ALLOWED = {"PreToolUse", "ConfigChange"}
bad = []
for f in sorted(glob.glob(os.path.join(sys.argv[1], "*.json"))):
    d = json.load(open(f))
    for ev, groups in (d.get("hooks") or {}).items():
        for g in groups:
            for h in g.get("hooks", []):
                if h.get("onFailure") == "block" and ev not in ALLOWED:
                    bad.append(f"{os.path.basename(f)}:{ev}")
print("\n".join(bad))
sys.exit(1 if bad else 0)
PY
  assert_success
  assert_output ""
}

@test "brick guard: no async hook carries onFailure in any fragment" {
  run python3 - "$FRAGMENTS_DIR" <<'PY'
import glob, json, os, sys
bad = []
for f in sorted(glob.glob(os.path.join(sys.argv[1], "*.json"))):
    d = json.load(open(f))
    for ev, groups in (d.get("hooks") or {}).items():
        for g in groups:
            for h in g.get("hooks", []):
                if h.get("async") is True and "onFailure" in h:
                    bad.append(f"{os.path.basename(f)}:{ev}")
print("\n".join(bad))
sys.exit(1 if bad else 0)
PY
  assert_success
  assert_output ""
}

@test "brick guard: exactly three onFailure block hooks exist across all fragments" {
  run python3 - "$FRAGMENTS_DIR" <<'PY'
import glob, json, os, sys
n = 0
for f in sorted(glob.glob(os.path.join(sys.argv[1], "*.json"))):
    d = json.load(open(f))
    for ev, groups in (d.get("hooks") or {}).items():
        for g in groups:
            for h in g.get("hooks", []):
                if "onFailure" in h:
                    n += 1
print(n)
PY
  assert_success
  assert_output "3"
}

# --- (c) committed build artifacts ---------------------------------------

@test "committed settings.json carries onFailure block on the three guards" {
  run _assert_three_guards "$SETTINGS"
  assert_success
}

@test "committed plugin/hooks/hooks.json carries onFailure block on the three guards" {
  run _assert_three_guards "$PLUGIN_HOOKS"
  assert_success
}

# --- (d) version floor script --------------------------------------------

setup() {
  STUB_DIR="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "$STUB_DIR"
  # PATH with only coreutils-ish dirs and NO claude, for the absent case.
  NOCLAUDE_PATH="/usr/bin:/bin"
}

# $1 = text the stub `claude --version` prints
_stub_claude() {
  printf '#!/bin/sh\necho "%s"\n' "$1" > "${STUB_DIR}/claude"
  chmod +x "${STUB_DIR}/claude"
}

_run_floor() {
  run env PATH="${STUB_DIR}:${NOCLAUDE_PATH}" CLAUDE_SUBPROCESS=0 /bin/bash "$FLOOR_SCRIPT"
}

@test "floor: 2.1.294 warns and names the version" {
  _stub_claude "2.1.294 (Claude Code)"
  _run_floor
  assert_success
  assert_output --partial "WARNING"
  assert_output --partial "2.1.294"
}

@test "floor: 2.1.295 is silent" {
  _stub_claude "2.1.295 (Claude Code)"
  _run_floor
  assert_success
  assert_output ""
}

@test "floor: 2.1.300 is silent" {
  _stub_claude "2.1.300"
  _run_floor
  assert_success
  assert_output ""
}

@test "floor: 2.2.0 is silent" {
  _stub_claude "2.2.0"
  _run_floor
  assert_success
  assert_output ""
}

@test "floor: 3.0.0 is silent" {
  _stub_claude "3.0.0"
  _run_floor
  assert_success
  assert_output ""
}

@test "floor: 2.1.29 warns (numeric compare, not string)" {
  _stub_claude "2.1.29 (Claude Code)"
  _run_floor
  assert_success
  assert_output --partial "WARNING"
  assert_output --partial "2.1.29"
}

@test "floor: 2.1.80 warns (a string compare would stay silent)" {
  _stub_claude "2.1.80 (Claude Code)"
  _run_floor
  assert_success
  assert_output --partial "WARNING"
  assert_output --partial "2.1.80"
}

@test "floor: 2.1.1000 is silent (a string compare would warn)" {
  _stub_claude "2.1.1000 (Claude Code)"
  _run_floor
  assert_success
  assert_output ""
}

@test "floor: claude --version exiting 1 says could not determine and exits 0" {
  printf '#!/bin/sh\nexit 1\n' > "${STUB_DIR}/claude"
  chmod +x "${STUB_DIR}/claude"
  _run_floor
  assert_success
  assert_output --partial "could not determine"
}

@test "floor: garbage version says could not determine" {
  _stub_claude "not a version"
  _run_floor
  assert_success
  assert_output --partial "could not determine"
}

@test "floor: claude absent from PATH says could not determine" {
  run env PATH="$NOCLAUDE_PATH" CLAUDE_SUBPROCESS=0 /bin/bash "$FLOOR_SCRIPT"
  assert_success
  assert_output --partial "could not determine"
}

@test "floor: install.sh runs the floor check after the settings merge and warns" {
  merge=$(grep -n 'cast-merge-settings.sh" "\$CLAUDE_DIR/settings.json"' "${REPO}/install.sh" | head -1 | cut -d: -f1)
  floor=$(grep -n 'CC_FLOOR_MSG="\$(bash .*cast-cc-version-floor.sh.*|| true)"' "${REPO}/install.sh" | cut -d: -f1)
  warnl=$(grep -n 'warn "  \$CC_FLOOR_MSG"' "${REPO}/install.sh" | cut -d: -f1)
  [ -n "$merge" ]
  [ -n "$floor" ]
  [ -n "$warnl" ]
  [ "$floor" -gt "$merge" ]
  [ "$warnl" -gt "$floor" ]
}
