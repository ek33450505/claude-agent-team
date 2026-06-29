#!/usr/bin/env bats
# cast-egress-matcher-contract.bats — Contract test for the PreToolUse egress-dispatcher matcher.
#
# RATIONALE: Claude Code 2.1.195 made hook matchers EXACT-match unless they contain a regex
# metacharacter. The cast-pretool-dispatch entry's matcher:
#
#   mcp__.*|WebFetch|WebSearch|Bash|Read|Write|Edit
#
# stays a regex ONLY because of the `.*` in `mcp__.*`. If anyone simplifies the mcp branch to a
# pure-alnum form (e.g. `mcp__github`), MCP PreToolUse hooks silently match nothing and MCP egress
# recording dies with no error. This test guards a §1 record-feeder (the egress ledger).
#
# BOTH source files are asserted because they are independently deployed:
#   - managed-settings.d/25-hooks-security.json (merged by install.sh → settings.local.json)
#   - plugin/hooks/hooks.json (deployed via gen-plugin.sh to the plugin directory)
#
# This test reads repo files only — no HOME isolation needed.

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
MANAGED_SETTINGS="$REPO_DIR/managed-settings.d/25-hooks-security.json"
PLUGIN_HOOKS="$REPO_DIR/plugin/hooks/hooks.json"

# ---------------------------------------------------------------------------
# Helper: extract the matcher string for the cast-pretool-dispatch entry.
# Usage: _get_pretool_dispatch_matcher <json-file>
# Prints the matcher string; exits non-zero if the entry is not found.
# ---------------------------------------------------------------------------
_get_pretool_dispatch_matcher() {
	local file="$1"
	jq -r '
    .hooks.PreToolUse[]
    | select(
        .hooks[]?.command // "" | test("cast-pretool-dispatch"; "")
      )
    | .matcher
  ' "$file"
}

# ---------------------------------------------------------------------------
# managed-settings.d/25-hooks-security.json
# ---------------------------------------------------------------------------

@test "managed-settings.d/25-hooks-security.json: file exists" {
	[ -f "$MANAGED_SETTINGS" ]
}

@test "managed-settings.d/25-hooks-security.json: PreToolUse cast-pretool-dispatch entry has a matcher" {
	local matcher
	matcher=$(_get_pretool_dispatch_matcher "$MANAGED_SETTINGS")
	[ -n "$matcher" ]
}

@test "managed-settings.d/25-hooks-security.json: cast-pretool-dispatch matcher contains mcp__.* (regex branch preserved)" {
	local matcher
	matcher=$(_get_pretool_dispatch_matcher "$MANAGED_SETTINGS")
	# The substring mcp__.* must be present verbatim — the .* is what keeps CC treating
	# the whole matcher string as a regex rather than an exact match.
	[[ "$matcher" == *"mcp__.*"* ]]
}

# ---------------------------------------------------------------------------
# plugin/hooks/hooks.json
# ---------------------------------------------------------------------------

@test "plugin/hooks/hooks.json: file exists" {
	[ -f "$PLUGIN_HOOKS" ]
}

@test "plugin/hooks/hooks.json: PreToolUse cast-pretool-dispatch entry has a matcher" {
	local matcher
	matcher=$(_get_pretool_dispatch_matcher "$PLUGIN_HOOKS")
	[ -n "$matcher" ]
}

@test "plugin/hooks/hooks.json: cast-pretool-dispatch matcher contains mcp__.* (regex branch preserved)" {
	local matcher
	matcher=$(_get_pretool_dispatch_matcher "$PLUGIN_HOOKS")
	[[ "$matcher" == *"mcp__.*"* ]]
}
