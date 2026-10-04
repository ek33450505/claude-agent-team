#!/usr/bin/env bats
# cast-neon-notify-guard.bats — Neon MCP unsafe-tool notify guard.
#
# Covers _notify_neon_risk() / _classify_neon_risk() in cast-pretool-dispatch.py
# (the notify + record half of the two-part Neon guard) and
# managed-settings.d/12-ask.json (the permissions.ask prompt half, the real
# gate). Context: the Neon MCP server ignores the client's ?readonly=true URL
# param under a full-scope OAuth grant, so the owner decision was "keep the
# write tools usable, never block, but make sure nothing risky lands
# silently" -- see 12-ask.json's _neon_ask_note and cast-pretool-dispatch.py's
# _notify_neon_risk docstring. Hardened 2026-08-24 (CAST v10 sec1): the
# classifier is now FAIL-CLOSED (default-unsafe unless proven safe) and
# credential-returning tools (e.g. get_connection_string) are their own risk
# class, checked ahead of the safe-read allowlist.
#
# HARD RULES honored: temp-HOME isolation (setup_temp_home); osascript/
# notify-send/terminal-notifier PATH-shimmed to no-op stubs (zero real GUI
# side effects); never calls a real Neon MCP tool or makes a Neon network
# request (the dispatcher + egress sentinel are pure classifiers over the
# hook JSON -- no tool_input schema is ever executed).

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
DISPATCH="$REPO_DIR/scripts/cast-pretool-dispatch.py"
ASK_FRAGMENT="$REPO_DIR/managed-settings.d/12-ask.json"
MERGE_SH="$REPO_DIR/scripts/cast-merge-settings.sh"

payload() {
  # payload <tool_name> [key=val ...]
  python3 -c "
import json, sys
tool = sys.argv[1]
ti = {}
for kv in sys.argv[2:]:
    k, _, v = kv.partition('=')
    ti[k] = v
print(json.dumps({'tool_name': tool, 'tool_input': ti, 'session_id': 'test'}))
" "$@"
}

run_dispatch() { run python3 "$DISPATCH" <<< "$1"; }

# The 20 read-only tools added to _NEON_SAFE_READ_RE on 2026-10-03 (schema-
# verified). list_triggers/get_trigger were considered and REMOVED: trigger/
# webhook config may carry headers or secrets and the response shape is
# unverified (they are in the kept-off-list test below). Shared by the fence
# loop and the native-ask "no prompt" loop.
NEW_SAFE_READS=(
  list_branches list_operations list_regions get_branch get_default_branch
  get_operation get_snapshot_schedule list_snapshots list_postgres_databases
  list_postgres_endpoints list_postgres_roles get_postgres_database
  get_postgres_endpoint get_postgres_role list_project_members
  list_project_permissions list_functions_custom_domains
  list_storage_buckets list_storage_objects get_ai_gateway
)

# payload_json <tool_name> <tool_input_json> -- like payload, but tool_input is a
# raw JSON object so booleans/null/numbers survive (payload makes strings only).
payload_json() {
  python3 -c "
import json, sys
print(json.dumps({'tool_name': sys.argv[1], 'tool_input': json.loads(sys.argv[2]), 'session_id': 'test'}))
" "$@"
}

# run_dispatch_stdout <payload> [cwd] -- like run_dispatch, but $output is STDOUT
# only (stderr dropped), i.e. exactly what Claude Code parses as the hook result.
run_dispatch_stdout() { run bash -c 'cd "${2:-.}" && python3 "$1" 2>/dev/null' _ "$DISPATCH" "${2:-}" <<< "$1"; }

# assert_one_json_doc <stdout> -- stdout must parse as EXACTLY ONE JSON document
# (json.loads rejects two concatenated objects with "Extra data"; Claude Code
# 2.1.288 blocks the tool call when a PreToolUse hook's output fails to parse).
assert_one_json_doc() {
  python3 -c 'import json,sys; json.loads(sys.stdin.read())' <<< "$1" || {
    echo "stdout is not exactly one JSON document: $1" >&2
    return 1
  }
}

# refute_in <haystack> <needle> -- fail if needle occurs. `if` form on purpose: a
# bare `[[ != ]]` mid-test does not trip errexit on bash 3.2 (false green).
refute_in() {
  if [[ "$1" == *"$2"* ]]; then
    echo "unexpected '$2' in: $1" >&2
    return 1
  fi
}

# hook_json_get <stdout> <key> -- prints hookSpecificOutput[key] ("" if absent);
# exits non-zero if stdout is not exactly one JSON document.
hook_json_get() {
  python3 -c '
import json, sys
h = json.loads(sys.argv[1])["hookSpecificOutput"]
v = h.get(sys.argv[2])
sys.stdout.write("" if v is None else str(v))
' "$1" "$2"
}

# unclassify_neon_in_policy -- rewrite the TEMP-HOME copy of the egress policy so
# "neon" is an UNKNOWN server: its egress verdict becomes 'warn', which is how a
# Neon call gets an egress advisory (the repo policy is never touched).
unclassify_neon_in_policy() {
  [[ -f "$HOME/.cast-test-home" ]] || { echo "refusing: HOME is not a test fixture" >&2; return 1; }
  python3 - "$HOME/.claude/config/egress-policy.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["mcp_servers"]["cloud_bound"].remove("neon")
json.dump(d, open(p, "w"))
PY
}

setup() {
  load 'helpers/setup'
  setup_temp_home
  mkdir -p "$HOME/.claude/logs" "$HOME/.claude/config" "$HOME/.claude/cast"
  cp "$REPO_DIR/config/egress-policy.json" "$HOME/.claude/config/egress-policy.json"
  export EGRESS_LOG="$HOME/.claude/logs/egress.jsonl"
  export NOTIFY_QUEUE="$HOME/.claude/cast/notify-queue.json"
  unset CLAUDE_SUBPROCESS CLAUDE_SESSION_ID

  # PATH-shim notification binaries so this test never fires a real desktop
  # alert (HARD RULE) -- no-op stubs, same pattern as tests/cast-notify.bats.
  local stub_bin="$HOME/bin/stubs"
  mkdir -p "$stub_bin"
  for _cmd in osascript notify-send terminal-notifier; do
    printf '#!/bin/sh\nexit 0\n' > "$stub_bin/$_cmd"
    chmod +x "$stub_bin/$_cmd"
  done
  export PATH="$stub_bin:$PATH"
}

teardown() { teardown_temp_home; }

# --- notify: Neon write tools ------------------------------------------------

@test "Neon write tool (delete_branch) → notify queued, exit 0" {
  run_dispatch "$(payload mcp__neon__delete_branch branchId=br-123)"
  assert_success
  [[ -f "$NOTIFY_QUEUE" ]]
  run cat "$NOTIFY_QUEUE"
  assert_output --partial "mcp__neon__delete_branch"
}

@test "Neon write tool (run_sql) → notify queued, exit 0" {
  run_dispatch "$(payload mcp__neon__run_sql query='drop table x')"
  assert_success
  [[ -f "$NOTIFY_QUEUE" ]]
  run cat "$NOTIFY_QUEUE"
  assert_output --partial "mcp__neon__run_sql"
}

@test "Neon write tool never blocks — exit code is always 0" {
  run_dispatch "$(payload mcp__neon__delete_project projectId=p-1)"
  assert_success
  [ "$status" -eq 0 ]
}

# --- notify: scoping (must NOT fire) -----------------------------------------

@test "Neon READ tool (list_projects) → no notify" {
  run_dispatch "$(payload mcp__neon__list_projects)"
  assert_success
  [[ ! -f "$NOTIFY_QUEUE" ]]
}

@test "Neon READ tool (describe_project) → no notify" {
  run_dispatch "$(payload mcp__neon__describe_project projectId=p-1)"
  assert_success
  [[ ! -f "$NOTIFY_QUEUE" ]]
}

@test "non-Neon MCP tool with a write-shaped verb (github delete) → no notify" {
  run_dispatch "$(payload mcp__github__delete_repo repo=x)"
  assert_success
  [[ ! -f "$NOTIFY_QUEUE" ]]
}

@test "non-MCP tool (Bash) → no Neon notify" {
  run_dispatch "$(payload Bash command='ls -la /tmp')"
  assert_success
  [[ ! -f "$NOTIFY_QUEUE" ]]
}

# --- CRITICAL fix: credential-returning tools (2026-08-24) ------------------
# get_connection_string returns a live Postgres connection string with an
# embedded password. It starts with "get_" so it must NOT be swallowed by
# the safe-read allowlist despite sharing that prefix -- see
# cast-pretool-dispatch.py's _NEON_CREDENTIAL_RE / _classify_neon_risk.

@test "Neon CREDENTIAL tool (get_connection_string) → notify queued despite get_ prefix" {
  run_dispatch "$(payload mcp__neon__get_connection_string branchId=br-1)"
  assert_success
  [[ -f "$NOTIFY_QUEUE" ]]
  run cat "$NOTIFY_QUEUE"
  assert_output --partial "mcp__neon__get_connection_string"
}

@test "Neon CREDENTIAL tool (get_connection_string) under CLAUDE_SUBPROCESS=1 → recorded to egress ledger" {
  export CLAUDE_SUBPROCESS=1
  run_dispatch "$(payload mcp__neon__get_connection_string branchId=br-1)"
  assert_success
  [[ -f "$EGRESS_LOG" ]]
  run tail -1 "$EGRESS_LOG"
  assert_output --partial '"tool_name":"mcp__neon__get_connection_string"'
}

# --- HIGH fix: previously-uncovered write verbs (2026-08-24) ----------------
# update*/grant*/revoke*/set_*/add_*/remove_*/rename*/transfer* were missing
# from both the ask list and the old write-verb enumeration regex.

@test "Neon write tool (update_project) → notify queued, exit 0" {
  run_dispatch "$(payload mcp__neon__update_project projectId=p-1)"
  assert_success
  [[ -f "$NOTIFY_QUEUE" ]]
  run cat "$NOTIFY_QUEUE"
  assert_output --partial "mcp__neon__update_project"
}

@test "Neon write tool (update_project) under CLAUDE_SUBPROCESS=1 → recorded to egress ledger" {
  export CLAUDE_SUBPROCESS=1
  run_dispatch "$(payload mcp__neon__update_project projectId=p-1)"
  assert_success
  [[ -f "$EGRESS_LOG" ]]
  run tail -1 "$EGRESS_LOG"
  assert_output --partial '"tool_name":"mcp__neon__update_project"'
}

@test "Neon write tool (grant_access) → notify queued, exit 0" {
  run_dispatch "$(payload mcp__neon__grant_access granteeId=u-1)"
  assert_success
  [[ -f "$NOTIFY_QUEUE" ]]
  run cat "$NOTIFY_QUEUE"
  assert_output --partial "mcp__neon__grant_access"
}

@test "Neon write tool (grant_access) under CLAUDE_SUBPROCESS=1 → recorded to egress ledger" {
  export CLAUDE_SUBPROCESS=1
  run_dispatch "$(payload mcp__neon__grant_access granteeId=u-1)"
  assert_success
  [[ -f "$EGRESS_LOG" ]]
  run tail -1 "$EGRESS_LOG"
  assert_output --partial '"tool_name":"mcp__neon__grant_access"'
}

# --- fail-closed default (HIGH fix, the structural gap-closer) -------------
# The classifier must default to unsafe for any mcp__neon__* tool it has
# never seen before, not just the verbs enumerated today.

@test "fail-closed: unknown future Neon tool (frobnicate_branch) → still notified" {
  run_dispatch "$(payload mcp__neon__frobnicate_branch branchId=br-9)"
  assert_success
  [[ -f "$NOTIFY_QUEUE" ]]
  run cat "$NOTIFY_QUEUE"
  assert_output --partial "mcp__neon__frobnicate_branch"
}

@test "fail-closed under CLAUDE_SUBPROCESS=1: unknown future Neon tool → still recorded to egress ledger" {
  export CLAUDE_SUBPROCESS=1
  run_dispatch "$(payload mcp__neon__frobnicate_branch branchId=br-9)"
  assert_success
  [[ -f "$EGRESS_LOG" ]]
  run tail -1 "$EGRESS_LOG"
  assert_output --partial '"tool_name":"mcp__neon__frobnicate_branch"'
}

# --- STRUCTURAL fix (2026-08-24, 3rd pass): 10 reproduced bypass names ------
# _NEON_SAFE_READ_RE previously mixed exact names with list_.*/describe_.*/
# explain_.*/get_.* wildcards, and _NEON_CREDENTIAL_RE matched only the
# literal words credential/password/connection -- so every name below
# classified None (safe) via a wildcard match, producing zero notify/record.
# The safe-read side is now an exact enumeration with a default-unsafe
# fallthrough, so each of these must produce a notify regardless of wording.

@test "bypass name 1/10 (get_client_secret) → notify queued, not safe" {
  run_dispatch "$(payload mcp__neon__get_client_secret)"
  assert_success
  [[ -f "$NOTIFY_QUEUE" ]]
  run cat "$NOTIFY_QUEUE"
  assert_output --partial "mcp__neon__get_client_secret"
}

@test "bypass name 2/10 (get_api_key) → notify queued, not safe" {
  run_dispatch "$(payload mcp__neon__get_api_key)"
  assert_success
  [[ -f "$NOTIFY_QUEUE" ]]
  run cat "$NOTIFY_QUEUE"
  assert_output --partial "mcp__neon__get_api_key"
}

@test "bypass name 3/10 (get_database_uri) → notify queued, not safe" {
  run_dispatch "$(payload mcp__neon__get_database_uri)"
  assert_success
  [[ -f "$NOTIFY_QUEUE" ]]
  run cat "$NOTIFY_QUEUE"
  assert_output --partial "mcp__neon__get_database_uri"
}

@test "bypass name 4/10 (get_bearer_token) → notify queued, not safe" {
  run_dispatch "$(payload mcp__neon__get_bearer_token)"
  assert_success
  [[ -f "$NOTIFY_QUEUE" ]]
  run cat "$NOTIFY_QUEUE"
  assert_output --partial "mcp__neon__get_bearer_token"
}

@test "bypass name 5/10 (get_jwt) → notify queued, not safe" {
  run_dispatch "$(payload mcp__neon__get_jwt)"
  assert_success
  [[ -f "$NOTIFY_QUEUE" ]]
  run cat "$NOTIFY_QUEUE"
  assert_output --partial "mcp__neon__get_jwt"
}

@test "bypass name 6/10 (get_oauth_token) → notify queued, not safe" {
  run_dispatch "$(payload mcp__neon__get_oauth_token)"
  assert_success
  [[ -f "$NOTIFY_QUEUE" ]]
  run cat "$NOTIFY_QUEUE"
  assert_output --partial "mcp__neon__get_oauth_token"
}

@test "bypass name 7/10 (describe_api_token) → notify queued, not safe" {
  run_dispatch "$(payload mcp__neon__describe_api_token)"
  assert_success
  [[ -f "$NOTIFY_QUEUE" ]]
  run cat "$NOTIFY_QUEUE"
  assert_output --partial "mcp__neon__describe_api_token"
}

@test "bypass name 8/10 (describe_secret_key) → notify queued, not safe" {
  run_dispatch "$(payload mcp__neon__describe_secret_key)"
  assert_success
  [[ -f "$NOTIFY_QUEUE" ]]
  run cat "$NOTIFY_QUEUE"
  assert_output --partial "mcp__neon__describe_secret_key"
}

@test "bypass name 9/10 (list_role_secrets) → notify queued, not safe" {
  run_dispatch "$(payload mcp__neon__list_role_secrets)"
  assert_success
  [[ -f "$NOTIFY_QUEUE" ]]
  run cat "$NOTIFY_QUEUE"
  assert_output --partial "mcp__neon__list_role_secrets"
}

@test "bypass name 10/10 (explain_token_scope) → notify queued, not safe" {
  run_dispatch "$(payload mcp__neon__explain_token_scope)"
  assert_success
  [[ -f "$NOTIFY_QUEUE" ]]
  run cat "$NOTIFY_QUEUE"
  assert_output --partial "mcp__neon__explain_token_scope"
}

@test "bypass name under CLAUDE_SUBPROCESS=1 (get_client_secret) → still recorded to egress ledger" {
  export CLAUDE_SUBPROCESS=1
  run_dispatch "$(payload mcp__neon__get_client_secret)"
  assert_success
  [[ -f "$EGRESS_LOG" ]]
  run tail -1 "$EGRESS_LOG"
  assert_output --partial '"tool_name":"mcp__neon__get_client_secret"'
}

# --- get_neon_auth_config dropped from the safe list (security MEDIUM) -----

@test "get_neon_auth_config is no longer classified safe (dropped from enumeration)" {
  run_dispatch "$(payload mcp__neon__get_neon_auth_config)"
  assert_success
  [[ -f "$NOTIFY_QUEUE" ]]
  run cat "$NOTIFY_QUEUE"
  assert_output --partial "mcp__neon__get_neon_auth_config"
}

# --- over-correction fence: every real safe-read tool must stay safe -------

@test "every exact safe-read tool still classifies safe -- no notify (over-correction fence)" {
  # explain_sql_statement is deliberately NOT here: it is safe only when
  # `analyze` is explicitly false (it needs tool_input), covered by the
  # dedicated explain_sql_statement tests below.
  local -a tools
  tools=(
    list_projects list_shared_projects list_organizations list_branch_computes
    list_slow_queries list_docs_resources list_log_fields list_log_field_values
    describe_project describe_branch describe_table_schema
    query_logs search fetch compare_database_schema inspect_database
    get_database_tables get_doc_resource
    "${NEW_SAFE_READS[@]}"
  )
  for t in "${tools[@]}"; do
    rm -f "$NOTIFY_QUEUE"
    run_dispatch "$(payload "mcp__neon__${t}")"
    if [ "$status" -ne 0 ]; then
      echo "REGRESSION: mcp__neon__${t} dispatch exited non-zero ($status)" >&2
      return 1
    fi
    if [[ -f "$NOTIFY_QUEUE" ]]; then
      echo "REGRESSION: mcp__neon__${t} incorrectly classified non-safe (notify fired)" >&2
      return 1
    fi
  done
}

# --- pins the EXACT-enumeration property independent of credential labelling
# All 10 reproduced bypass names above contain a credential-flavored word
# (secret/token/key/uri/auth/jwt/oauth), so _NEON_CREDENTIAL_RE catches them
# before _NEON_SAFE_READ_RE is even consulted -- none of those tests would
# go red if a bare `get_.*`/`list_.*`/`describe_.*` wildcard were mistakenly
# reintroduced into the safe-read enumeration. This test uses a clean name
# with no credential-flavored word so it exercises ONLY the exact-enumeration
# fail-closed path.

@test "fail-closed (non-credential-flavored): unlisted get_ tool without a credential word must NOT classify safe" {
  run_dispatch "$(payload mcp__neon__get_org_settings)"
  assert_success
  [[ -f "$NOTIFY_QUEUE" ]]
  run cat "$NOTIFY_QUEUE"
  assert_output --partial "mcp__neon__get_org_settings"
}

# --- fullmatch fix: trailing newline must not classify safe -----------------

@test "trailing-newline tool name (list_projects + \\n) must NOT classify safe" {
  run_dispatch "$(payload $'mcp__neon__list_projects\n')"
  assert_success
  [[ -f "$NOTIFY_QUEUE" ]]
  run cat "$NOTIFY_QUEUE"
  assert_output --partial "mcp__neon__list_projects"
}

# --- prefix hardening (LOW fix, 2026-08-24): case/whitespace-malformed -----
# --- Neon-shaped names must still classify, not silently fall through as ---
# --- "not a Neon tool" -- _classify_neon_risk's prefix gate now normalises -
# --- via .lstrip().lower() before the startswith("mcp__neon__") check. -----
# Mutation-tested: reverting the normalisation (back to a bare startswith())
# turns the three "prefix hardening N/3" tests below RED while leaving every
# other test in this file GREEN, confirming they discriminate this fix and
# not some other behavior.

@test "prefix hardening 1/3: uppercase tool name (MCP__NEON__delete_branch) -> notify queued" {
  run_dispatch "$(payload MCP__NEON__delete_branch branchId=br-1)"
  assert_success
  [[ -f "$NOTIFY_QUEUE" ]]
  run cat "$NOTIFY_QUEUE"
  assert_output --partial "MCP__NEON__delete_branch"
}

@test "prefix hardening 2/3: leading-space tool name ( mcp__neon__delete_branch) -> notify queued" {
  run_dispatch "$(payload $' mcp__neon__delete_branch' branchId=br-1)"
  assert_success
  [[ -f "$NOTIFY_QUEUE" ]]
  run cat "$NOTIFY_QUEUE"
  assert_output --partial "mcp__neon__delete_branch"
}

@test "prefix hardening 3/3: leading-newline tool name (\\nmcp__neon__delete_branch) -> notify queued" {
  run_dispatch "$(payload $'\nmcp__neon__delete_branch' branchId=br-1)"
  assert_success
  [[ -f "$NOTIFY_QUEUE" ]]
  run cat "$NOTIFY_QUEUE"
  assert_output --partial "mcp__neon__delete_branch"
}

@test "prefix hardening: non-Neon tool (mcp__cloudflare__docs) -> still no notify" {
  run_dispatch "$(payload mcp__cloudflare__docs)"
  assert_success
  [[ ! -f "$NOTIFY_QUEUE" ]]
}

@test "prefix hardening: typosquat-shaped non-Neon tool (mcp__neonfake__delete_all) -> still no notify" {
  run_dispatch "$(payload mcp__neonfake__delete_all)"
  assert_success
  [[ ! -f "$NOTIFY_QUEUE" ]]
}

# --- event type honesty (security finding: "blocked" was a lie) ------------

@test "notify uses the truthful neon_write event type, never the dishonest blocked type" {
  run_dispatch "$(payload mcp__neon__delete_branch branchId=br-1)"
  assert_success
  [[ -f "$NOTIFY_QUEUE" ]]
  run cat "$NOTIFY_QUEUE"
  assert_output --partial '"event": "neon_write"'
  refute_output --partial '"event": "blocked"'
}

# --- tool_input payloads must never leak into notify or the ledger ---------

@test "tool_input payload (SQL text) never reaches the notify queue" {
  run_dispatch "$(payload mcp__neon__run_sql query='DROP TABLE secrets -- SENTINEL_SQL_TEXT')"
  assert_success
  [[ -f "$NOTIFY_QUEUE" ]]
  run cat "$NOTIFY_QUEUE"
  refute_output --partial "SENTINEL_SQL_TEXT"
  refute_output --partial "DROP TABLE"
}

@test "tool_input payload (SQL text) never reaches the egress ledger" {
  run_dispatch "$(payload mcp__neon__run_sql query='DROP TABLE secrets -- SENTINEL_SQL_TEXT')"
  assert_success
  [[ -f "$EGRESS_LOG" ]]
  run cat "$EGRESS_LOG"
  refute_output --partial "SENTINEL_SQL_TEXT"
  refute_output --partial "DROP TABLE"
}

# --- record: subagent gap ----------------------------------------------------
# CLAUDE_SUBPROCESS=1 never reaches the dispatcher's normal EGRESS step (it's
# after the recursion-prevention early-return), so the Neon guard's placement
# BEFORE that early-return is what records a dispatched subagent's write.

@test "Neon write under CLAUDE_SUBPROCESS=1 (dispatched subagent) → still recorded to egress ledger" {
  export CLAUDE_SUBPROCESS=1
  run_dispatch "$(payload mcp__neon__delete_branch branchId=br-9)"
  assert_success
  [[ -f "$EGRESS_LOG" ]]
  run tail -1 "$EGRESS_LOG"
  assert_output --partial '"tool_name":"mcp__neon__delete_branch"'
}

@test "Neon write under CLAUDE_SUBPROCESS=1 → still notified (every-context rule)" {
  export CLAUDE_SUBPROCESS=1
  run_dispatch "$(payload mcp__neon__reset_from_parent branchId=br-9)"
  assert_success
  [[ -f "$NOTIFY_QUEUE" ]]
}

@test "Neon top-level write is not double-recorded (one ledger line, not two)" {
  run_dispatch "$(payload mcp__neon__create_branch projectId=p-1)"
  assert_success
  [[ -f "$EGRESS_LOG" ]]
  n="$(wc -l < "$EGRESS_LOG" | tr -d ' ')"
  [ "$n" -eq 1 ]
}

# --- native ask (2026-10-03) -------------------------------------------------
# The hook now ALSO emits `permissionDecision: "ask"` for every risky Neon
# classification, fail-closed (no glob to keep in step with Neon's tool list),
# and reads arguments (explain_sql_statement analyze). It is a PROMPT, not a
# block: exit stays 0. Stdout must hold exactly ONE JSON object.

@test "native ask: unsafe write (restore_snapshot) → exit 0, ONE JSON doc, ask naming the tool" {
  run_dispatch_stdout "$(payload mcp__neon__restore_snapshot snapshotId=s-1)"
  assert_success
  local out="$output"
  assert_one_json_doc "$out"
  run hook_json_get "$out" hookEventName
  assert_output "PreToolUse"
  run hook_json_get "$out" permissionDecision
  assert_success
  assert_output "ask"
  run hook_json_get "$out" permissionDecisionReason
  assert_success
  assert_output --partial "restore_snapshot"
  assert_output --partial "known-safe read list"
}

@test "native ask: credential tool (get_connection_string) → ask, reason says credential" {
  run_dispatch_stdout "$(payload mcp__neon__get_connection_string branchId=br-1)"
  assert_success
  local out="$output"
  assert_one_json_doc "$out"
  run hook_json_get "$out" permissionDecision
  assert_output "ask"
  run hook_json_get "$out" permissionDecisionReason
  assert_output --partial "get_connection_string"
  assert_output --partial "can return a credential"
}

@test "native ask: unknown future tool (frobnicate_branch) → ask (fail-closed)" {
  run_dispatch_stdout "$(payload mcp__neon__frobnicate_branch branchId=br-9)"
  assert_success
  local out="$output"
  assert_one_json_doc "$out"
  run hook_json_get "$out" permissionDecision
  assert_output "ask"
  run hook_json_get "$out" permissionDecisionReason
  assert_output --partial "frobnicate_branch"
}

@test "native ask: case/whitespace variants of a Neon write (not egress-shaped names) still ask" {
  # _is_egress_tool() is case-sensitive, so an upper-cased name never reaches
  # the egress step; the ask must not be lost on that path.
  local -a names
  names=("MCP__NEON__delete_branch" $' mcp__neon__delete_branch' $'\nmcp__neon__delete_branch')
  local n
  for n in "${names[@]}"; do
    run_dispatch_stdout "$(payload "$n" branchId=br-1)"
    [ "$status" -eq 0 ] || { echo "non-zero exit for variant" >&2; return 1; }
    local out="$output"
    assert_one_json_doc "$out"
    run hook_json_get "$out" permissionDecision
    [ "$output" = "ask" ] || { echo "no ask for variant: $n" >&2; return 1; }
  done
}

@test "native ask: trailing-newline list_projects asks, odd tool-name bytes never reach the reason" {
  run_dispatch_stdout "$(payload $'mcp__neon__list_projects\n')"
  assert_success
  local out="$output"
  run hook_json_get "$out" permissionDecision
  assert_output "ask"
  run hook_json_get "$out" permissionDecisionReason
  assert_output --partial "Neon tool is not on CAST's known-safe read list"

  run_dispatch_stdout "$(payload 'mcp__neon__zzq9 b"c')"
  assert_success
  out="$output"
  run hook_json_get "$out" permissionDecisionReason
  assert_success
  assert_output --partial "Neon tool is not on CAST's known-safe read list"
  refute_output --partial 'zzq9'
}

@test "native ask: safe read (list_projects) → no permissionDecision on stdout, no notify" {
  run_dispatch_stdout "$(payload mcp__neon__list_projects)"
  assert_success
  refute_output --partial "permissionDecision"
  [[ ! -f "$NOTIFY_QUEUE" ]]
}

@test "native ask: each of the 20 newly-safe reads → no permissionDecision, no notify" {
  [ "${#NEW_SAFE_READS[@]}" -eq 20 ]
  local t
  for t in "${NEW_SAFE_READS[@]}"; do
    rm -f "$NOTIFY_QUEUE"
    run_dispatch_stdout "$(payload "mcp__neon__${t}")"
    [ "$status" -eq 0 ] || { echo "non-zero exit for $t" >&2; return 1; }
    if [[ "$output" == *permissionDecision* ]]; then
      echo "REGRESSION: mcp__neon__${t} (newly-safe read) was ask-gated" >&2
      return 1
    fi
    if [[ -f "$NOTIFY_QUEUE" ]]; then
      echo "REGRESSION: mcp__neon__${t} (newly-safe read) fired notify" >&2
      return 1
    fi
  done
}

@test "native ask: tools deliberately kept OFF the safe list (unverified shapes / credential-flavoured) still ask" {
  local -a kept
  kept=(
    get_neon_auth_config list_auth_oauth_providers get_function list_functions
    get_storage get_data_api list_credentials get_auth list_auth_trusted_domains
    list_triggers get_trigger
  )
  local t
  for t in "${kept[@]}"; do
    run_dispatch_stdout "$(payload "mcp__neon__${t}")"
    [ "$status" -eq 0 ] || { echo "non-zero exit for $t" >&2; return 1; }
    local out="$output"
    run hook_json_get "$out" permissionDecision
    [ "$output" = "ask" ] || { echo "REGRESSION: mcp__neon__${t} no longer asks" >&2; return 1; }
  done
}

# --- explain_sql_statement: analyze:true EXECUTES the SQL -------------------

@test "explain_sql_statement analyze:true (JSON true) → ask + notify, SQL text never leaves tool_input" {
  run_dispatch_stdout "$(payload_json mcp__neon__explain_sql_statement '{"sql":"DELETE FROM t -- SENTINEL_SQL_TEXT","analyze":true}')"
  assert_success
  local out="$output"
  assert_one_json_doc "$out"
  run hook_json_get "$out" permissionDecision
  assert_output "ask"
  run hook_json_get "$out" permissionDecisionReason
  assert_output --partial "analyze not explicitly false"
  [[ -f "$NOTIFY_QUEUE" ]] || { echo "notify not queued" >&2; return 1; }
  run cat "$NOTIFY_QUEUE"
  assert_output --partial "mcp__neon__explain_sql_statement"
  # SQL text must reach neither stdout (the reason), the notify queue, nor the ledger.
  refute_in "$out" SENTINEL_SQL_TEXT
  refute_in "$out" "DELETE FROM"
  run cat "$NOTIFY_QUEUE" "$EGRESS_LOG"
  refute_output --partial "SENTINEL_SQL_TEXT"
  refute_output --partial "DELETE FROM"
}

@test "explain_sql_statement with analyze absent → ask (fail-closed)" {
  run_dispatch_stdout "$(payload_json mcp__neon__explain_sql_statement '{"sql":"SELECT 1"}')"
  assert_success
  local out="$output"
  assert_one_json_doc "$out"
  run hook_json_get "$out" permissionDecision
  assert_output "ask"
  [[ -f "$NOTIFY_QUEUE" ]] || { echo "notify not queued" >&2; return 1; }
}

@test "explain_sql_statement with analyze given as the string true → ask" {
  run_dispatch_stdout "$(payload_json mcp__neon__explain_sql_statement '{"sql":"SELECT 1","analyze":"true"}')"
  assert_success
  local out="$output"
  run hook_json_get "$out" permissionDecision
  assert_output "ask"
  [[ -f "$NOTIFY_QUEUE" ]] || { echo "notify not queued" >&2; return 1; }
}

@test "explain_sql_statement with analyze:false → no ask, no notify" {
  run_dispatch_stdout "$(payload_json mcp__neon__explain_sql_statement '{"sql":"SELECT 1","analyze":false}')"
  assert_success
  refute_output --partial "permissionDecision"
  [[ ! -f "$NOTIFY_QUEUE" ]]
}

@test "explain_sql_statement: analyze:false with every schema-declared key → no ask, no notify" {
  run_dispatch_stdout "$(payload_json mcp__neon__explain_sql_statement '{"sql":"SELECT 1","analyze":false,"project_id":"p-1","branch_id":"br-1","database_name":"neondb"}')"
  assert_success
  assert_output ""
  [[ ! -f "$NOTIFY_QUEUE" ]]
}

@test "explain_sql_statement: string analyze spellings (false, padded FALSE, 0) now ASK -- only a JSON boolean false skips the prompt" {
  # The schema types analyze as boolean; a server that coerces strings could
  # read "false" as true, so no string is trusted as "does not execute".
  local -a forms
  forms=('"false"' '" FALSE "' '"0"')
  local f
  for f in "${forms[@]}"; do
    rm -f "$NOTIFY_QUEUE"
    # Hoisted: bash 3.2 mangles \" inside a nested "$(...)".
    local ti="{\"sql\":\"SELECT 1\",\"analyze\":${f}}"
    run_dispatch_stdout "$(payload_json mcp__neon__explain_sql_statement "$ti")"
    [ "$status" -eq 0 ] || { echo "non-zero exit for analyze=$f" >&2; return 1; }
    local out="$output"
    run hook_json_get "$out" permissionDecision
    [ "$output" = "ask" ] || { echo "REGRESSION: string analyze=$f skipped the prompt" >&2; return 1; }
    [[ -f "$NOTIFY_QUEUE" ]] || { echo "REGRESSION: string analyze=$f not notified" >&2; return 1; }
  done
}

@test "explain_sql_statement: analyze:false plus a key outside the live schema (params) → ask (fail-closed)" {
  # The live schema is flat with additionalProperties:false (verified
  # 2026-10-03): an extra key means schema drift or a malformed call.
  run_dispatch_stdout "$(payload_json mcp__neon__explain_sql_statement '{"sql":"SELECT 1","analyze":false,"params":{"analyze":true}}')"
  assert_success
  local out="$output"
  assert_one_json_doc "$out"
  run hook_json_get "$out" permissionDecision
  assert_output "ask"
  [[ -f "$NOTIFY_QUEUE" ]] || { echo "notify not queued" >&2; return 1; }
}

@test "explain_sql_statement: anything that is not explicitly false (null, 1, string yes, empty list) → ask" {
  local -a forms
  forms=('null' '1' '"yes"' '[]')
  local f
  for f in "${forms[@]}"; do
    # Hoisted: bash 3.2 mangles \" inside a nested "$(...)".
    local ti="{\"sql\":\"SELECT 1\",\"analyze\":${f}}"
    run_dispatch_stdout "$(payload_json mcp__neon__explain_sql_statement "$ti")"
    [ "$status" -eq 0 ] || { echo "non-zero exit for analyze=$f" >&2; return 1; }
    local out="$output"
    run hook_json_get "$out" permissionDecision
    [ "$output" = "ask" ] || { echo "REGRESSION: analyze=$f did not ask" >&2; return 1; }
  done
}

# --- native ask: payload hygiene, subagent context, one-document rule -------

@test "native ask: SQL text from tool_input never appears on stdout (run_sql)" {
  run_dispatch_stdout "$(payload mcp__neon__run_sql query='DROP TABLE secrets -- SENTINEL_SQL_TEXT')"
  assert_success
  local out="$output"
  assert_one_json_doc "$out"
  run hook_json_get "$out" permissionDecision
  assert_output "ask"
  refute_in "$out" SENTINEL_SQL_TEXT
  refute_in "$out" "DROP TABLE"
}

@test "native ask: CLAUDE_SUBPROCESS=1 + unsafe tool → ask object still emitted (ONE doc)" {
  export CLAUDE_SUBPROCESS=1
  run_dispatch_stdout "$(payload mcp__neon__delete_branch branchId=br-9)"
  assert_success
  local out="$output"
  assert_one_json_doc "$out"
  run hook_json_get "$out" permissionDecision
  assert_output "ask"
  run hook_json_get "$out" permissionDecisionReason
  assert_output --partial "delete_branch"
}

@test "native ask: CLAUDE_SUBPROCESS=1 + safe read → nothing on stdout" {
  export CLAUDE_SUBPROCESS=1
  run_dispatch_stdout "$(payload mcp__neon__list_projects)"
  assert_success
  assert_output ""
}

@test "native ask: non-Neon tools never get a permissionDecision (mcp__github__delete_repo, Bash)" {
  run_dispatch_stdout "$(payload mcp__github__delete_repo repo=x)"
  assert_success
  refute_output --partial "permissionDecision"
  run_dispatch_stdout "$(payload Bash command='ls -la /tmp')"
  assert_success
  refute_output --partial "permissionDecision"
}

# --- parse-failure branch: stdin the guard cannot parse, but names a Neon tool ---
# main() used to return 0 silently when json.loads raised (malformed JSON, or
# RecursionError on deep nesting) -- fail-OPEN, no ask. The parse-failure branch
# now scans the raw text for a "tool_name": "mcp__neon__ token and, if found,
# prints ONE ask object. Anything else on that path stays silent exit 0.

@test "parse failure: truncated stdin naming mcp__neon__delete_project → exit 0, ONE JSON doc, ask (could not be parsed)" {
  run_dispatch_stdout '{"tool_name": "mcp__neon__delete_project", "tool_input": {"project_id": "p-1'
  assert_success
  local out="$output"
  assert_one_json_doc "$out"
  run hook_json_get "$out" permissionDecision
  assert_output "ask"
  run hook_json_get "$out" permissionDecisionReason
  assert_output --partial "could not be parsed by the guard"
  run hook_json_get "$out" hookEventName
  assert_output "PreToolUse"
}

@test "parse failure: case/whitespace variant of the token (MCP__NEON__, spaces) → still ask" {
  run_dispatch_stdout '{"tool_name"   :   "  MCP__NEON__delete_project", "tool_input": {'
  assert_success
  local out="$output"
  assert_one_json_doc "$out"
  run hook_json_get "$out" permissionDecision
  assert_output "ask"
}

@test "parse failure: deep nesting (RecursionError in json.loads) naming a Neon tool → ask" {
  local deep
  deep="$(python3 -c 'import sys; n=300000; sys.stdout.write("{\"tool_name\":\"mcp__neon__delete_project\",\"x\":" + "["*n + "]"*n + "}")')"
  # n is deliberately huge: /usr/bin/python3 3.9 raises RecursionError near 1000
  # levels, but python 3.14 still parses 20000 levels fine (measured), so a
  # modest depth would NOT defeat json.loads there. Non-vacuity guard: the
  # fixture must really defeat json.loads on the interpreter under test, or
  # this test proves nothing. Fed via stdin (a ~600 KB argv entry would exceed
  # Linux's 128 KiB per-argument limit).
  run python3 -c 'import json,sys
try:
    json.loads(sys.stdin.read())
except Exception as e:
    print(type(e).__name__)
    sys.exit(0)
sys.exit(1)' <<< "$deep"
  assert_success
  run_dispatch_stdout "$deep"
  assert_success
  local out="$output"
  assert_one_json_doc "$out"
  run hook_json_get "$out" permissionDecision
  assert_output "ask"
}

@test "parse failure: valid JSON that is not an object but names a Neon tool → ask" {
  run_dispatch_stdout '[{"tool_name": "mcp__neon__delete_project"}]'
  assert_success
  local out="$output"
  assert_one_json_doc "$out"
  run hook_json_get "$out" permissionDecision
  assert_output "ask"
}

@test "parse failure under CLAUDE_SUBPROCESS=1: still ask (the parse branch precedes the subprocess early-return)" {
  export CLAUDE_SUBPROCESS=1
  run_dispatch_stdout '{"tool_name": "mcp__neon__delete_project", "tool_input": {'
  assert_success
  local out="$output"
  assert_one_json_doc "$out"
  run hook_json_get "$out" permissionDecision
  assert_output "ask"
}

@test "parse failure: unparseable stdin NOT naming a Neon tool → silent exit 0 (fail-open unchanged)" {
  run_dispatch_stdout '{"tool_name": "mcp__github__delete_repo", "tool_input": {'
  assert_success
  assert_output ""
  run_dispatch_stdout 'this is not json at all'
  assert_success
  assert_output ""
  run_dispatch_stdout '{"tool_name": "Bash", "tool_input": {"command": "echo mcp__neon__delete_project"'
  assert_success
  assert_output ""
}

@test "parse failure: Neon name AFTER >64 KiB of tool_input padding (tool_input serialised first) → still ask" {
  # A fixed scan window would hide the name behind a large tool_input.
  local fixture
  fixture="$(python3 -c 'import sys; sys.stdout.write("{\"tool_input\": {\"pad\": \"" + "A"*70000 + "\"}, \"tool_name\": \"mcp__neon__delete_project\"")')"
  # Non-vacuity: the Neon token must sit beyond the old 64 KiB window, and the
  # fixture must really be unparseable (truncated: no closing brace).
  local head="${fixture%%mcp__neon__*}"
  [ "${#head}" -gt 65536 ] || { echo "fixture token not past 64 KiB: ${#head}" >&2; return 1; }
  run python3 -c 'import json,sys
try:
    json.loads(sys.stdin.read())
except Exception:
    sys.exit(0)
sys.exit(1)' <<< "$fixture"
  assert_success
  run_dispatch_stdout "$fixture"
  assert_success
  local out="$output"
  assert_one_json_doc "$out"
  run hook_json_get "$out" permissionDecision
  assert_output "ask"
  run hook_json_get "$out" permissionDecisionReason
  assert_output --partial "could not be parsed by the guard"
}

# --- invalid UTF-8 on stdin ----------------------------------------------------
# sys.stdin.read() raises UnicodeDecodeError on invalid UTF-8 under a strict
# locale; main() used to return 0 before `raw` existed, so a Neon call in such a
# payload got no ask. PYTHONIOENCODING=utf-8:strict pins that strict behaviour
# for the test regardless of the runner's locale / UTF-8-mode defaults (without
# it a C-locale python decodes stdin with surrogateescape and never raises).

@test "invalid UTF-8 byte inside otherwise-valid JSON naming a Neon tool → decodes with replace, parses, asks (structured path)" {
  export PYTHONIOENCODING=utf-8:strict
  run_dispatch_stdout $'{"tool_name": "mcp__neon__delete_project", "tool_input": {"project_id": "p-\xff1"}}'
  assert_success
  local out="$output"
  assert_one_json_doc "$out"
  run hook_json_get "$out" permissionDecision
  assert_output "ask"
  run hook_json_get "$out" permissionDecisionReason
  assert_output --partial "delete_project"
  assert_output --partial "known-safe read list"
}

@test "invalid UTF-8 byte in UNPARSEABLE stdin naming a Neon tool → parse-failure ask" {
  export PYTHONIOENCODING=utf-8:strict
  run_dispatch_stdout $'{"tool_name": "mcp__neon__delete_project", "tool_input": {"sql": "\xff'
  assert_success
  local out="$output"
  assert_one_json_doc "$out"
  run hook_json_get "$out" permissionDecision
  assert_output "ask"
  run hook_json_get "$out" permissionDecisionReason
  assert_output --partial "could not be parsed by the guard"
}

@test "invalid UTF-8 byte in a NON-Neon payload → silent exit 0, no ask" {
  export PYTHONIOENCODING=utf-8:strict
  run_dispatch_stdout $'{"tool_name": "Bash", "tool_input": {"command": "echo \xff"}}'
  assert_success
  assert_output ""
}

@test "valid multi-byte UTF-8 payloads classify exactly as before (safe read silent, write asks)" {
  export PYTHONIOENCODING=utf-8:strict
  # Literal UTF-8 bytes on the wire (payload()/json.dumps would ASCII-escape them).
  run_dispatch_stdout $'{"tool_name": "mcp__neon__list_projects", "tool_input": {"search": "caf\xc3\xa9 \xe2\x98\x83"}}'
  assert_success
  assert_output ""
  run_dispatch_stdout $'{"tool_name": "mcp__neon__delete_branch", "tool_input": {"branchId": "br-\xc3\xa9\xe2\x98\x83"}}'
  assert_success
  local out="$output"
  assert_one_json_doc "$out"
  run hook_json_get "$out" permissionDecision
  assert_output "ask"
  run hook_json_get "$out" permissionDecisionReason
  assert_output --partial "Neon delete_branch is not on CAST's known-safe read list"
}

@test "combined: egress advisory + ask are folded into ONE JSON object (top-level)" {
  # Policy copy in the temp HOME with neon unclassified -> egress verdict 'warn'.
  # cwd = temp HOME so the repo's config/egress-policy.json is not the first candidate.
  unclassify_neon_in_policy
  run_dispatch_stdout "$(payload mcp__neon__restore_snapshot snapshotId=s-1)" "$HOME"
  assert_success
  local out="$output"
  assert_one_json_doc "$out"
  run hook_json_get "$out" permissionDecision
  assert_output "ask"
  run hook_json_get "$out" additionalContext
  assert_success
  assert_output --partial "[CAST-EGRESS:warn]"
  assert_output --partial "UNKNOWN MCP server 'neon'"
}

@test "combined: egress advisory + ask are folded into ONE JSON object (CLAUDE_SUBPROCESS=1)" {
  unclassify_neon_in_policy
  export CLAUDE_SUBPROCESS=1
  run_dispatch_stdout "$(payload mcp__neon__restore_snapshot snapshotId=s-1)" "$HOME"
  assert_success
  local out="$output"
  assert_one_json_doc "$out"
  run hook_json_get "$out" permissionDecision
  assert_output "ask"
  run hook_json_get "$out" additionalContext
  assert_output --partial "[CAST-EGRESS:warn]"
}

@test "advisory-only path unchanged: warn verdict on a SAFE Neon read → additionalContext, no permissionDecision" {
  unclassify_neon_in_policy
  run_dispatch_stdout "$(payload mcp__neon__list_projects)" "$HOME"
  assert_success
  local out="$output"
  assert_one_json_doc "$out"
  run hook_json_get "$out" additionalContext
  assert_output --partial "[CAST-EGRESS:warn]"
  refute_in "$out" permissionDecision
}

# --- 12-ask.json fragment -----------------------------------------------------

@test "12-ask.json is valid JSON" {
  run python3 -c "import json; json.load(open('$ASK_FRAGMENT'))"
  assert_success
}

@test "12-ask.json defines only permissions.ask (no allow/deny keys)" {
  run python3 -c "
import json
d = json.load(open('$ASK_FRAGMENT'))
perms = d.get('permissions', {})
assert list(perms.keys()) == ['ask'], f'unexpected permissions keys: {list(perms.keys())}'
assert isinstance(perms['ask'], list) and len(perms['ask']) > 0
"
  assert_success
}

@test "12-ask.json ask list covers the known Neon write tool names" {
  run python3 -c "
import json
d = json.load(open('$ASK_FRAGMENT'))
ask = set(d['permissions']['ask'])
required = {
    'mcp__neon__delete_branch', 'mcp__neon__delete_project',
    'mcp__neon__create_branch', 'mcp__neon__create_project',
    'mcp__neon__reset_from_parent', 'mcp__neon__run_sql',
    'mcp__neon__run_sql_transaction',
    'mcp__neon__prepare_database_migration',
    'mcp__neon__complete_database_migration',
    'mcp__neon__prepare_query_tuning', 'mcp__neon__complete_query_tuning',
    'mcp__neon__configure_neon_auth', 'mcp__neon__provision_neon_auth',
    'mcp__neon__provision_neon_data_api',
    # HIGH fix (2026-08-24): previously-missing verbs' belt-and-braces names.
    'mcp__neon__grant_access', 'mcp__neon__update_project',
    # CRITICAL fix (2026-08-24): credential-returning tool.
    'mcp__neon__get_connection_string',
}
missing = required - ask
assert not missing, f'missing from ask list: {missing}'
"
  assert_success
}

@test "12-ask.json ask list covers the previously-missing write verbs (HIGH fix)" {
  run python3 -c "
import json
d = json.load(open('$ASK_FRAGMENT'))
ask = d['permissions']['ask']
required_globs = {
    'mcp__neon__update*', 'mcp__neon__grant*', 'mcp__neon__revoke*',
    'mcp__neon__set_*', 'mcp__neon__add_*', 'mcp__neon__remove_*',
    'mcp__neon__rename*', 'mcp__neon__transfer*',
}
missing = required_globs - set(ask)
assert not missing, f'missing verb globs from ask list: {missing}'
"
  assert_success
}

@test "12-ask.json ask list covers the 2026-10-03 drift verbs" {
  run python3 -c "
import json
d = json.load(open('$ASK_FRAGMENT'))
ask = set(d['permissions']['ask'])
required_globs = {
    'mcp__neon__restore*', 'mcp__neon__finalize*', 'mcp__neon__recover*',
    'mcp__neon__rotate*', 'mcp__neon__deploy*', 'mcp__neon__register*',
    'mcp__neon__restart*', 'mcp__neon__start*', 'mcp__neon__suspend*',
    'mcp__neon__disable*', 'mcp__neon__presign*',
}
required_literals = {
    'mcp__neon__restore_snapshot', 'mcp__neon__finalize_branch_restore',
    'mcp__neon__recover_project', 'mcp__neon__rotate_credential',
    'mcp__neon__deploy_function',
    'mcp__neon__register_functions_custom_domain',
    'mcp__neon__restart_postgres_endpoint',
    'mcp__neon__start_postgres_endpoint',
    'mcp__neon__suspend_postgres_endpoint', 'mcp__neon__disable_auth',
    'mcp__neon__presign_storage_object',
}
missing_globs = required_globs - ask
assert not missing_globs, f'missing drift verb globs: {missing_globs}'
missing_literals = required_literals - ask
assert not missing_literals, f'missing drift literals: {missing_literals}'
"
  assert_success
}

@test "no 12-ask.json ask glob shadows a known safe-read tool" {
  run python3 -c "
import ast, fnmatch, json, re
ask = json.load(open('$ASK_FRAGMENT'))['permissions']['ask']
# Parse the real _NEON_SAFE_READ_RE out of the dispatch source (no import, no
# side effects) so this check cannot drift from a hard-coded third copy.
tree = ast.parse(open('$DISPATCH').read())
pattern = None
for node in ast.walk(tree):
    if isinstance(node, ast.Assign) and any(
            isinstance(t, ast.Name) and t.id == '_NEON_SAFE_READ_RE'
            for t in node.targets):
        pattern = node.value.args[0].value
assert pattern, '_NEON_SAFE_READ_RE assignment not found in dispatch script'
head, tail = '^mcp__neon__(', ')' + chr(36)
assert pattern.startswith(head) and pattern.endswith(tail), f'unexpected regex shape: {pattern!r}'
names = pattern[len(head):-len(tail)].split('|')
# Non-vacuity: the parse must have produced the real enumeration.
assert len(names) >= 10 and 'list_projects' in names and 'search' in names, f'parsed too few safe names: {names}'
# Exact-enumeration property: every entry is a literal tool name, never a
# wildcard/alternation fragment (keeps the fnmatch shadow check below honest).
assert all(re.fullmatch(r'[a-z_]+', n) for n in names), f'non-literal safe-read entry: {names}'
globs =[a for a in ask if '*' in a]
assert globs, 'no glob entries found in ask list'
hits = [(g, n) for g in globs for n in names
        if fnmatch.fnmatchcase('mcp__neon__' + n, g)]
assert not hits, f'ask glob(s) shadow known safe-read tool(s): {hits}'
"
  assert_success
}

@test "12-ask.json does not list any Neon safe-read tool (list_/describe_/explain_)" {
  run python3 -c "
import json
d = json.load(open('$ASK_FRAGMENT'))
ask = d['permissions']['ask']
read_prefixes = ('mcp__neon__list_', 'mcp__neon__describe_', 'mcp__neon__explain_')
hits = [a for a in ask if a.startswith(read_prefixes)]
assert not hits, f'read tool(s) leaked into ask list: {hits}'
"
  assert_success
}

@test "12-ask.json does not list any NON-credential get_ tool" {
  # get_* reads are safe EXCEPT credential-shaped tools -- CRITICAL fix:
  # get_connection_string must be ask-gated despite the get_ prefix (checked
  # separately below). Any OTHER get_* tool appearing here would regress the
  # original 'read tools are not ask-gated' design.
  run python3 -c "
import json
d = json.load(open('$ASK_FRAGMENT'))
ask = d['permissions']['ask']
non_credential_get_hits = [
    a for a in ask
    if a.startswith('mcp__neon__get_')
    and 'connection' not in a and 'credential' not in a and 'password' not in a
]
assert not non_credential_get_hits, f'non-credential get_ tool leaked into ask list: {non_credential_get_hits}'
"
  assert_success
}

@test "12-ask.json ask-gates the connection-string credential tool (CRITICAL fix)" {
  run python3 -c "
import json
d = json.load(open('$ASK_FRAGMENT'))
ask = d['permissions']['ask']
assert 'mcp__neon__get_connection_string' in ask, 'get_connection_string not ask-gated'
"
  assert_success
}

# --- disclosure (MEDIUM fix, 2026-08-24): prompt/record asymmetry ----------
# The ask list only prompts for the verb globs + literal names above -- it
# does NOT prompt for unenumerated credential-shaped get_*/describe_*/
# list_*/explain_* names (the ten names security reproduced live in
# _classify_neon_risk's 3rd-pass docstring). This test pins that the
# _neon_ask_note discloses that asymmetry in plain language, so a future
# edit that silently drops the disclosure fails instead of quietly
# reintroducing an undisclosed gap.

@test "12-ask.json's _neon_ask_note discloses the prompt/record asymmetry for unenumerated credential-shaped tools" {
  run python3 -c "
import json
d = json.load(open('$ASK_FRAGMENT'))
note = d['_neon_ask_note']
assert 'DISCLOSURE' in note, 'disclosure paragraph missing entirely'
assert 'recorded, not interrupted' in note, 'missing the recorded-not-interrupted guarantee phrase'
assert 'get_connection_string' in note
# spot-check two of the ten reproduced bypass names are actually named
assert 'get_client_secret' in note
assert 'explain_token_scope' in note
"
  assert_success
}

# --- drift: 12-ask.json and _NEON_SAFE_READ_RE encode ONE policy in two ----
# --- languages (code-reviewer HIGH finding) ---------------------------------

@test "drift: no literal safe-read tool name from cast-pretool-dispatch.py appears in 12-ask.json's ask list" {
  run python3 -c "
import json
d = json.load(open('$ASK_FRAGMENT'))
ask = set(d['permissions']['ask'])
safe_reads = {
    'list_projects', 'list_shared_projects', 'list_organizations',
    'list_branch_computes', 'list_slow_queries', 'list_docs_resources',
    'list_log_fields', 'list_log_field_values',
    'describe_project', 'describe_branch', 'describe_table_schema',
    'explain_sql_statement', 'query_logs', 'search', 'fetch',
    'compare_database_schema', 'inspect_database', 'get_database_tables',
    'get_doc_resource',
    # 2026-10-03 additions (kept in step with NEW_SAFE_READS at the file top).
    'list_branches', 'list_operations', 'list_regions', 'get_branch',
    'get_default_branch', 'get_operation', 'get_snapshot_schedule',
    'list_snapshots', 'list_postgres_databases', 'list_postgres_endpoints',
    'list_postgres_roles', 'get_postgres_database', 'get_postgres_endpoint',
    'get_postgres_role', 'list_project_members', 'list_project_permissions',
    'list_functions_custom_domains',
    'list_storage_buckets', 'list_storage_objects', 'get_ai_gateway',
}
safe_full = {f'mcp__neon__{t}' for t in safe_reads}
overlap = ask & safe_full
assert not overlap, f'safe-read tool(s) present in ask list (policy contradiction): {overlap}'
"
  assert_success
}

@test "drift: every literal (non-glob) 12-ask.json ask entry classifies non-safe in the Python guard" {
  run python3 -c "
import json
d = json.load(open('$ASK_FRAGMENT'))
ask = d['permissions']['ask']
literals = [a for a in ask if '*' not in a]
print('\n'.join(literals))
"
  assert_success
  local literals="$output"
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    rm -f "$NOTIFY_QUEUE"
    run_dispatch "$(payload "$name")"
    if [[ ! -f "$NOTIFY_QUEUE" ]]; then
      echo "REGRESSION: ask-listed literal $name classified SAFE by the Python guard (policy contradiction)" >&2
      return 1
    fi
  done <<< "$literals"
}

@test "no mid-string *credential*/*password*/*connection* globs remain in 12-ask.json (found inert)" {
  run python3 -c "
import json
d = json.load(open('$ASK_FRAGMENT'))
ask = d['permissions']['ask']
inert = [a for a in ask if a in ('mcp__neon__*credential*', 'mcp__neon__*password*', 'mcp__neon__*connection*')]
assert not inert, f'inert mid-string glob(s) still present: {inert}'
"
  assert_success
}

# --- merge preserves allow + deny + ask --------------------------------------

@test "cast-merge-settings.sh preserves allow, deny AND ask after adding 12-ask.json" {
  mkdir -p "$HOME/.claude/managed-settings.d"
  cp "$REPO_DIR"/managed-settings.d/*.json "$HOME/.claude/managed-settings.d/"
  out="$HOME/.claude/settings.json"
  run bash "$MERGE_SH" "$out"
  assert_success
  run python3 -c "
import json
d = json.load(open('$out'))
p = d.get('permissions', {})
assert p.get('allow'), 'permissions.allow missing/empty after merge'
assert p.get('deny'), 'permissions.deny missing/empty after merge'
assert p.get('ask'), 'permissions.ask missing/empty after merge'
assert 'mcp__neon__delete_branch' in p['ask']
"
  assert_success
}
