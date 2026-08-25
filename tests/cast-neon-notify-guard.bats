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
  local tools=(
    list_projects list_shared_projects list_organizations list_branch_computes
    list_slow_queries list_docs_resources list_log_fields list_log_field_values
    describe_project describe_branch describe_table_schema explain_sql_statement
    query_logs search fetch compare_database_schema inspect_database
    get_database_tables get_doc_resource
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
