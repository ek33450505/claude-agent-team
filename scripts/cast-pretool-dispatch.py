#!/usr/bin/env python3
"""cast-pretool-dispatch.py — CAST v9 P0 unified PreToolUse dispatcher.

Collapses the three serial Bash-path PreToolUse hooks — the egress sentinel,
the git/policy guard (pre-tool-guard), and the command-guard — into ONE process.
Bash hot path: 6 spawns (3 bash shims + 3 python cold-starts, ~78 ms measured)
→ 1 python process (~15 ms floor). Realizes master_v9.md §0.5 / P0
("one dispatcher process per tool call, not N").

SUBTRACTION SAFETY GATE (master_v9.md §0.2): this dispatcher REUSES the exact
logic modules the standalone wrappers wrap —
  cast-egress-sentinel.py   (classify / assess_sensitivity / record / emit_advisory)
  cast-git-guard.py         (evaluate: git commit/push/stash + Write/Edit policy)
  cast-command-guard.py     (safe_is_blocked: pkill/killall/mass-kill/catastrophic-rm)
so cast-egress-sentinel.bats / pre-tool-guard.bats / test_push_agent_stash_guard.bats
/ cast-command-guard.bats keep proving the underlying guarantees, and
cast-pretool-dispatch.bats proves the routing + integration. Replace-then-remove:
the wrappers stay on disk as those test entrypoints; only the live hook WIRING is
repointed here.

ROUTING (by tool_name):
  0. Workflow: stage-model guard (_workflow_stage_model_guard) owns the call --
     DENY an inline/scriptPath script whose agent() stage lacks model:; every
     failure mode allows silently, incl. a lint that outruns its 2 s SIGALRM
     watchdog (the scriptPath read has its own 1 s SIGALRM window; a stalled
     read = an unreadable scriptPath). No other path below applies to Workflow.
  1. HARD BLOCKS first — CPU-bound (regex only, no I/O), so the wipe-protection
     guard is guaranteed to run before any egress I/O could stall the hook's
     timeout budget:
       Bash:        git-guard (commit/push/stash) THEN command-guard (kill/rm).
       Write/Edit:  git-guard policy engine (TTL sweep + config/policies.json).
     First hard block wins → block reason to stderr + exit 2.
  2. EGRESS scope (mcp__*, WebFetch, WebSearch, Bash, Read), reached only when
     nothing hard-blocked: classify + RECORD to the local egress ledger (the KEEP
     value — master_v9.md §1) + emit advisory (record-only). The hard-block set
     (git/kill/rm) and the egress-record set (network/credential) are DISJOINT for
     Bash (verified: the egress sentinel records none of the blocked commands), so
     evaluating blocks first loses no audit record while making command-guard
     robust against a slow egress write.

FAIL-OPEN per guard: a crash/missing module in one guard never suppresses another
(each load + call is independently guarded), and any load failure is logged to
hook-errors.log so `cast doctor` can surface a silently-disabled guard. The ONE exception
is the git/policy guard module (cast-git-guard.py) failing to LOAD, which fails CLOSED: a
Write/Edit is blocked (unless CAST_POLICY_OVERRIDE=1) and Bash gets a coarse degraded-mode
block of the irreversible git verbs (_degraded_git_block), each with its normal hatch. command-
guard is always evaluated for Bash unless git-guard already hard-blocked — which
prevents the whole command from executing anyway. CLAUDE_SUBPROCESS=1 skips ONLY the Write/Edit policy + egress record + dispatch capture; the git commit/push/stash and destructive-command guards run in EVERY context (a subagent must not bypass the irreversibility/destructive guards), and so does the Neon MCP unsafe-tool notify guard (_notify_neon_risk) — a dispatched subagent's risky Neon call must be notified and recorded too. Any
unhandled error → exit 0 (allow); a guard crash must never block all tool use.

CONTRACT (identical to the wrappers): exit 2 + stderr = block; stdout
hookSpecificOutput JSON = egress advisory (and, for a risky Neon MCP call, a
native permissionDecision "ask" folded into the same single object; also printed
alone when stdin cannot be parsed but names an mcp__neon__ tool); exit 0 =
allow. An ask is a prompt, never a hard block (this hook exits 2 only for the
git/kill/rm/policy blocks); under headless or CLAUDE_SUBPROCESS=1 nobody can
answer it, so there it is effectively a deny -- intended fail-closed.

ENFORCEMENT vs AWARENESS (master_v9.md §0.3): these guards are ADVISORY-grade — the
model-facing block in an interactive session, NOT the non-bypassable wall. The real
boundary for the catastrophic classes (credential reads, network egress, filesystem)
is the OS sandbox (sandbox.filesystem.denyRead / network.allowedDomains) + permissions.
deny, which native rules enforce for all subprocesses. These hooks remain the path-aware
/ escape-hatch / indirection-robust layer native rules cannot express, and the record.
See docs/architecture/enforcement-awareness-split.md for the full classification.
"""
import importlib.util
import json
import os
import re
import stat
import sys
import time
from datetime import datetime, timezone

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))

# Egress scope = the original cast-egress-sentinel matcher set (plus any mcp__*).
_EGRESS_TOOLS = ("WebFetch", "WebSearch", "Bash", "Read")

_MODULE_CACHE = {}

# I-2c hardening: dispatch_name's bound-parameter shape gate. Claude Code's own
# Agent-tool `name=` pattern (^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$) is a SUPERSET of
# common secret-token alphabets (AWS key IDs, GitHub PATs, base64url/JWT segments
# all fit it) — the pattern below re-enforces that exact bound rather than trusting
# the caller to have honored it, which in one stroke also rejects control
# characters, newlines/CR, NUL, DEL, and Unicode bidi-override characters (none of
# those are in the allowed charset). Use fullmatch(), not match()+trailing `$` —
# `$` matches just before a trailing newline even under match(), so match() alone
# would let "name\n" through; fullmatch() requires the match to consume the entire
# string and correctly rejects it (verified).
_DISPATCH_NAME_RE = re.compile(r'^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$')


def _log_error(msg):
    """Append to hook-errors.log so a silently-disabled guard is observable. Never raises."""
    try:
        log_dir = os.path.join(os.path.expanduser("~"), ".claude", "logs")
        os.makedirs(log_dir, exist_ok=True)
        ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        with open(os.path.join(log_dir, "hook-errors.log"), "a") as f:
            f.write(f"[{ts}] ERROR cast-pretool-dispatch.py: {msg}\n")
    except Exception:
        pass


# A session id usable as a dedupe key: a UUID-ish token. Anything else (empty,
# non-str, whitespace/control chars, > 64 chars, "unknown") is NOT a key -- the
# failure is still recorded, just never deduplicated.
_SESSION_ID_RE = re.compile(r'[A-Za-z0-9_\-]{1,64}')
_UNKNOWN_SESSION = "unknown"

# The PreToolUse payload's session_id, set once by main() so _load() -- reached
# from a dozen call sites -- can hand it to _record_guard_failure without threading
# a parameter through all of them. Single-shot process; reset at the top of main().
_PAYLOAD_SESSION_ID = None


def _payload_session_id(data):
    """The payload's session_id for the RECORD-ONLY writers (egress record, dispatch_decisions).

    A non-str value (int/list/dict) or an empty one is MISSING: fall back to
    CLAUDE_SESSION_ID, then "unknown". Before this, a truthy non-str flowed on as-is: a
    list/dict made the dispatch_decisions INSERT raise (row silently dropped) and was
    handed to the egress sentinel as a non-str. Both writers stay fail-open (record-only,
    never blocking); the value just has to be a str so the record still lands.
    """
    sid = data.get("session_id")
    if isinstance(sid, str) and sid:
        return sid
    return os.environ.get("CLAUDE_SESSION_ID", "unknown")


def _dedupe_session_id(*candidates):
    """First candidate that is a usable dedupe key, else None. The payload
    session_id is passed before the CLAUDE_SESSION_ID env fallback."""
    for c in candidates:
        if isinstance(c, str) and c != _UNKNOWN_SESSION and _SESSION_ID_RE.fullmatch(c):
            return c
    return None


def _guard_failure_recorded(cast_db, hook_name, session_id):
    """True only if a hook_failures row for (hook_name, session_id) provably
    exists. ANY doubt -- the read raises, the DB is unreadable, the table is
    missing -- is False, so the caller writes the row: fail toward recording."""
    try:
        cast_db.ensure_hook_failures_table()
        rows = cast_db.db_query(
            "SELECT 1 FROM hook_failures WHERE hook_name = ? AND session_id = ? LIMIT 1",
            (hook_name, session_id),
        )
        return bool(rows)
    except Exception:
        return False


def _record_guard_failure(mod_name: str, err_msg: str, session_id=None) -> None:
    """Write one hook_failures row for a guard module load failure.

    Deduplication: at most one row per (session_id, module), enforced by the
    hook_failures table ITSELF -- an existence check on (hook_name, session_id)
    before the write. There is deliberately NO marker file: a file in a
    guessable location is steerable (a symlinked parent, an object planted at the
    marker path) and, written before the DB row, silently dropped later records
    whenever the DB write failed. The DB is the record, so it is also the dedupe.
    `session_id` is the PreToolUse payload's (preferred), then CLAUDE_SESSION_ID;
    with neither usable the failure is recorded every time (stored as "unknown",
    no dedupe -- an id shared across sessions must not suppress anyone's record).
    Not atomic across concurrent hook processes: two racing calls may both write
    (a duplicate row is benign; a lost one is not).  Never raises — must not crash
    the hook.
    """
    try:
        sid = _dedupe_session_id(session_id, os.environ.get("CLAUDE_SESSION_ID"))
        hook_name = f"cast-pretool-dispatch/{mod_name}"
        # Import cast_db lazily — only on failure path; keeps the hot path free of
        # an extra module load on every call.
        if SCRIPT_DIR not in sys.path:
            sys.path.insert(0, SCRIPT_DIR)
        import cast_db
        if sid is not None and _guard_failure_recorded(cast_db, hook_name, sid):
            return  # already recorded for this (session, module) pair
        cast_db.log_hook_failure(
            hook_name,
            -1,
            (f"guard module failed to load — guard DISABLED: {err_msg}")[:2000],
            sid if sid is not None else _UNKNOWN_SESSION,
        )
    except Exception as exc:
        _log_error(f"_record_guard_failure: {exc}")


def _load(mod_name, filename):
    """Load a hyphen-named sibling script as a module, cached. Fail-soft → None.

    A None return means a guard is silently disabled for this process — log it
    (M2) so `cast doctor` / hook-errors.log surfaces the lost protection.
    Also writes one durable hook_failures row per (session, module) so the
    failure is visible to cast.db queries and `cast doctor`, not only to
    hook-errors.log."""
    if mod_name in _MODULE_CACHE:
        return _MODULE_CACHE[mod_name]
    mod = None
    try:
        path = os.path.join(SCRIPT_DIR, filename)
        spec = importlib.util.spec_from_file_location(mod_name, path)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
    except Exception as e:
        mod = None
        err_str = str(e)
        _log_error(f"guard module failed to load ({filename}) — guard DISABLED this call: {err_str}")
        _record_guard_failure(mod_name, err_str, _PAYLOAD_SESSION_ID)
    _MODULE_CACHE[mod_name] = mod
    return mod


def _sanitize_dispatch_name(raw_name):
    """Bound + screen a dispatch's custom Agent-tool `name=` before storage (I-2c).

    Three-step pipeline, fail-CLOSED at every step — a rejection anywhere returns
    None (never the raw value):
      1. Type + shape gate: non-str, empty, or not a full match of
         _DISPATCH_NAME_RE -> None. This alone closes the control-character/
         newline/bidi gap (see _DISPATCH_NAME_RE's comment).
      2. Redaction screen: run the (now shape-bound) name through cast-redact.py's
         regex engine — analyze_regex/redact_regex — so a token-shaped name that
         still happens to satisfy the shape gate (an AWS key ID, GitHub PAT, etc.)
         gets redacted rather than stored raw. Costs zero extra subprocess spawns:
         cast-redact.py is loaded in-process via the file's existing cached _load()
         (measured ~8ms import), not spawned — there is no performance case for
         skipping this the way there was for a second `subprocess.run` per dispatch.
      3. Fail closed: a missing/unloadable redactor module, or any exception raised
         while screening, stores None rather than the raw name — this only costs a
         lost attribution join (today's exact behavior, pre-I-2c) and can never leak.
         Logs one content-free breadcrumb (byte length + exception class + site,
         never the name itself) via _log_error, matching the prompt-redaction
         breadcrumb pattern elsewhere in this function.

    Honest limit: this screen is only as strong as cast-redact.py's own pattern
    set. Verified 2026-08-21: an Anthropic key shaped like "sk-ant-api03-..." is
    NOT matched by cast-redact.py's ANTHROPIC_KEY pattern and passes through
    unredacted. Do not represent this as a complete secret-detection guarantee —
    fixing cast-redact.py's pattern set is out of scope for this change.
    """
    if not isinstance(raw_name, str) or not raw_name:
        return None
    if not _DISPATCH_NAME_RE.fullmatch(raw_name):
        return None
    try:
        cast_redact = _load("cast_redact", "cast-redact.py")
        if cast_redact is None:
            raise RuntimeError("cast_redact module unavailable")
        entities = cast_redact.analyze_regex(raw_name, [])
        if entities:
            return cast_redact.redact_regex(raw_name, entities, "redact")
        return raw_name
    except Exception as exc:
        try:
            _byte_len = len(raw_name.encode("utf-8", errors="replace"))
            _log_error(
                "dispatch_name redaction failed — storing NULL "
                f"(site=dispatch_decisions.dispatch_name input_bytes={_byte_len} "
                f"exception={type(exc).__name__})"
            )
        except Exception:
            pass
        return None


def _is_egress_tool(tool):
    return tool in _EGRESS_TOOLS or tool.startswith("mcp__")


def _run_egress(sentinel, data):
    """Run cast-egress-sentinel.evaluate() -- the SAME per-call body the sentinel's
    own main() runs (load policy, classify, assess, record, plus the
    policy-missing/invalid advisory) -- with pre-parsed data.

    RECORDS (the KEEP value); returns an action tuple or None.
    ("advisory", verdict) or None. Never raises. Fail-open, but NOT silent: a
    swallowed exception is logged (exception TYPE only, matching this file's
    convention of never echoing tool payload text) so a disabled egress record
    shows up in hook-errors.log."""
    try:
        tool_name = data.get("tool_name", "") or ""
        tool_input = data.get("tool_input", {}) or {}
        if not isinstance(tool_input, dict):
            tool_input = {}
        session_id = _payload_session_id(data)
        verdict = sentinel.evaluate(tool_name, tool_input, session_id)
        if verdict is not None:
            return ("advisory", verdict)
        return None
    except Exception as e:
        _log_error(f"egress evaluation failed (fail-open, no record/advisory this call): {type(e).__name__}")
        return None


def _emit_egress(sentinel, action):
    try:
        kind, payload = action
        if kind == "advisory":
            sentinel.emit_advisory(payload)
    except Exception:
        pass


# --------------------------------------------------------------------------
# Neon MCP unsafe-tool notify guard (owner decision, 2026-08-24; hardened
# 2026-08-24 after security found this guard fail-open on two classes of
# calls -- see managed-settings.d/12-ask.json's _neon_ask_note for the full
# incident). The Neon MCP server reports "Write mode active. Destructive
# tools are exposed." and exposes delete_branch/delete_project/run_sql/
# reset_from_parent with full schemas even though the client wires
# ?readonly=true and deniedMcpServers blocks the full-access URL (see
# managed-settings.d/50-mcp.json's _neon_note) -- the OAuth SCOPE granted at
# session start beat the URL param. Decision: keep the write tools usable
# (do not deny, do not try to re-scope OAuth); instead make sure nothing
# risky ever lands silently. The real GATE is managed-settings.d/12-ask.json's
# permissions.ask (a client-side prompt the user must answer). This half
# notifies + records and (since 2026-10-03, see NATIVE ASK below) also emits its
# own fail-closed ask; it NEVER hard-blocks (never exits 2) -- see the call site
# in main(), placed BEFORE the CLAUDE_SUBPROCESS recursion-prevention early-return so a
# dispatched subagent's Neon call is also caught (mirrors the Bash git/kill/rm
# guards' "every context" rule documented at the top of main()).
#
# CRITICAL fix (2026-08-24): get_connection_string returns a LIVE Postgres
# connection string with an embedded password. It starts with "get_", so the
# old verb-enumeration regex (which only matched delete/create/run_sql/reset/
# prepare/complete/provision/configure) let it through as a "read" with zero
# signal -- identical to list_projects. Credential exposure is its OWN risk
# class, distinct from "mutates data": _NEON_CREDENTIAL_RE below is a
# separate pattern from the safe-read allowlist, checked BEFORE it so a
# credential tool can never be shadowed into "safe" just because it happens
# to match a get_.* shape. Covers the named tool plus any plausible
# *credential*/*password*/*connection*-shaped name.
#
# HIGH fix (2026-08-24): the old regex was a positive enumeration of
# "dangerous" verbs, and it was missing update/grant/revoke/set_/add_/
# remove_/rename/transfer -- security reproduced mcp__neon__grant_access and
# mcp__neon__update_project producing zero signal. Enumerating today's
# dangerous verbs is unbounded (Neon can add any verb tomorrow); enumerating
# today's SAFE reads is bounded. _NEON_SAFE_READ_RE below is now the ONLY
# allowlist, and classification is FAIL-CLOSED: any mcp__neon__* tool that
# does not affirmatively match it (and isn't a credential tool) is treated
# as unsafe. A tool Neon adds tomorrow gets signal by default instead of
# silence. Mirrors managed-settings.d/12-ask.json's verb-glob set (kept in
# sync by convention, not by shared code -- the JSON fragment is consumed by
# Claude Code's native permission engine, not by this Python process).
#
# permissions.ask precedence investigated (2026-08-24) before choosing how to
# widen 12-ask.json: docs/architecture/enforcement-awareness-split.md:55
# records the documented native precedence as `deny -> ask -> allow ->
# prompt` -- ask is checked BEFORE allow, so a broad "ask on mcp__neon__*"
# rule would catch every read before a narrower "allow" exception for
# known-safe reads ever got a chance to match. That rules out an
# allow-carve-out for 12-ask.json; see that file's _neon_ask_note for the
# chosen alternative (widen the ask globs directly).
#
# STRUCTURAL fix (2026-08-24, 3rd pass -- security BLOCKED this guard twice;
# both prior passes (CRITICAL, HIGH above) were point-patches that added a
# name to a list; this pass removes the pattern class that keeps producing
# those gaps. _NEON_SAFE_READ_RE previously mixed a handful of exact names
# with UNBOUNDED wildcards (list_.*, describe_.*, explain_.*, get_.*), and
# _NEON_CREDENTIAL_RE sat in front of it matching only the three literal
# words credential/password/connection. Any secret-returning tool using
# different wording -- get_client_secret, get_api_key, get_database_uri,
# get_bearer_token, get_jwt, get_oauth_token, describe_api_token,
# describe_secret_key, list_role_secrets, explain_token_scope (10 names
# reproduced live by security) -- matched a get_.*/describe_.*/explain_.*
# wildcard, fell through the narrow credential check, and classified None
# (safe): zero notify, zero record. A wider credential word list is not a
# fix for this -- it is the identical blocklist-in-front-of-a-wildcard shape
# with a bigger dictionary, and fails again on the next word.
#
# _NEON_SAFE_READ_RE below is now an EXACT enumeration of literal tool
# names -- no verb-prefix wildcard anywhere in it. This IS the fail-closed
# boundary the HIGH-fix docstring already claimed but the wildcards
# silently undermined: anything that is not a literal member -- including
# every unrecognised get_*/list_*/describe_* tool -- classifies "unsafe" by
# default in _classify_neon_risk. get_neon_auth_config is deliberately
# DROPPED from the enumeration (security MEDIUM): "auth config" plausibly
# returns client secrets or JWKS material and nobody has verified its
# response shape, so it now fails closed too (in practice it resolves to
# "credential" below, since "auth" is one of the broadened label words --
# either way it is no longer silently "safe"). _NEON_CREDENTIAL_RE is
# DEMOTED to a labelling refinement only: it does zero safety work now
# (nothing reaches "safe" that this enumeration would not itself call
# safe) -- it only decides whether a non-safe tool is notified as
# "CREDENTIAL" (a more useful signal) instead of the generic "write/unsafe"
# default, so it is broadened liberally (credential/password/connection/
# secret/token/key/uri/auth/jwt/oauth) without reintroducing any safety
# risk from over-matching.
#
# Both regexes now match via .fullmatch(), not .match()+trailing $ -- see
# _DISPATCH_NAME_RE's comment above: $ matches just before a trailing
# newline even under match(), so 'mcp__neon__list_projects\n' previously
# classified None/safe via that laxity (reproduced). fullmatch() requires
# consuming the whole string and correctly rejects it.
#
# managed-settings.d/12-ask.json's three *credential*/*password*/
# *connection* MID-STRING globs were found to be almost certainly INERT in
# the same pass (this engine's permission matching is prefix-glob only --
# see docs/architecture/enforcement-awareness-split.md and that file's
# _neon_ask_note) and were removed there rather than kept as false
# reassurance; that file's belt-and-braces literal get_connection_string
# entry remains. The two files still encode one policy in two languages
# (kept in sync by convention, not shared code) -- see
# tests/cast-neon-notify-guard.bats's drift tests for the cross-check.
#
# NATIVE ASK (2026-10-03): this hook now ALSO emits `permissionDecision:
# "ask"` for every risky classification, fail-closed -- an unknown future tool
# prompts by default, with no glob to keep in step. That closes two gaps in the
# 12-ask.json globs alone: verb-glob drift (it recurred twice) and
# argument-dependence (explain_sql_statement {analyze: true} EXECUTES its SQL;
# a native rule cannot read arguments, so _classify_neon_risk does). The
# 12-ask.json globs REMAIN as the belt for when this fail-open hook cannot run
# (module load failure, crash); the two layers are redundant by design. It is
# a prompt, not a hard block -- exit stays 0, never 2. Under headless /
# CLAUDE_SUBPROCESS=1 nobody can answer the prompt, so there an ask is
# effectively a deny: intended fail-closed. Stdout carries ONE JSON object only
# (see _emit_pretool_output): an ask and an egress advisory are folded together.
# If the stdin payload cannot be parsed at all, main() still asks when the raw
# text names an mcp__neon__ tool (see _emit_unparseable_neon_ask).
# --------------------------------------------------------------------------
_NEON_CREDENTIAL_RE = re.compile(
    r'^mcp__neon__.*(credential|password|connection|secret|token|key|uri|'
    r'auth|jwt|oauth).*$',
    re.IGNORECASE,
)

# EXACT enumeration -- no verb-prefix wildcards. This IS the safety
# boundary: anything not a literal member classifies "unsafe" by default in
# _classify_neon_risk. get_neon_auth_config intentionally excluded (see
# comment block above).
_NEON_SAFE_READ_RE = re.compile(
    r'^mcp__neon__('
    r'list_projects|list_shared_projects|list_organizations|'
    r'list_branch_computes|list_slow_queries|list_docs_resources|'
    r'list_log_fields|list_log_field_values|'
    r'describe_project|describe_branch|describe_table_schema|'
    r'explain_sql_statement|'
    r'query_logs|search|fetch|'
    r'compare_database_schema|inspect_database|get_database_tables|'
    r'get_doc_resource|'
    # Schema-verified read-only tools (2026-10-03). Deliberately NOT here:
    # get_neon_auth_config, list_auth_oauth_providers, get_function,
    # list_functions, get_storage, get_data_api, list_credentials,
    # list_triggers, get_trigger -- response shapes unverified / may carry
    # secrets (trigger/webhook config can hold headers), so they keep failing
    # closed.
    r'list_branches|list_operations|list_regions|get_branch|'
    r'get_default_branch|get_operation|get_snapshot_schedule|list_snapshots|'
    r'list_postgres_databases|list_postgres_endpoints|list_postgres_roles|'
    r'get_postgres_database|get_postgres_endpoint|get_postgres_role|'
    r'list_project_members|list_project_permissions|'
    r'list_functions_custom_domains|'
    r'list_storage_buckets|list_storage_objects|get_ai_gateway'
    r')$'
)


_NEON_EXPLAIN_TOOL = "mcp__neon__explain_sql_statement"


# explain_sql_statement's live input schema is flat with
# additionalProperties:false and exactly these properties (verified 2026-10-03
# by loading the tool schema); `analyze` is {"type": "boolean", "default": false}.
_NEON_EXPLAIN_KNOWN_KEYS = frozenset(
    {"analyze", "branch_id", "database_name", "project_id", "sql"}
)


def _explain_may_execute(tool_input):
    """True unless explain_sql_statement provably does NOT execute the SQL.

    `analyze: true` makes Postgres EXECUTE the statement (EXPLAIN ANALYZE), so
    explain_sql_statement {analyze: true, sql: "DELETE ..."} runs the SQL and
    its side effects. The tool's schema default is false (verified
    2026-10-03), but a native permissions.ask rule cannot read arguments, so
    this check lives here.
    FAIL-CLOSED: skip the prompt ONLY when `analyze` is the real JSON boolean
    False AND every key in tool_input is one the live schema declares. The
    schema types `analyze` as boolean, so a legitimate client sends a bool; a
    string such as "false"/"0" is NOT accepted (a server that coerces strings
    could read "false" as true). Missing/None/any other analyze value, an
    unknown extra key (the schema forbids additionalProperties, so one means
    the schema drifted or the call is malformed), or a non-dict tool_input is
    treated as may-execute."""
    if not isinstance(tool_input, dict):
        return True
    if tool_input.get("analyze") is not False:
        return True
    if not set(tool_input).issubset(_NEON_EXPLAIN_KNOWN_KEYS):
        return True
    return False


def _classify_neon_risk(tool_name, tool_input=None):
    """Fail-closed Neon MCP risk classifier (structural fix, 3rd pass; prefix
    hardening, 4th pass 2026-08-24 -- see PREFIX HARDENING note below).
    Returns:
      None          -- not a neon tool, or an EXACT literal member of the
                       known-safe-read enumeration (_NEON_SAFE_READ_RE). The
                       two cases deliberately share this sentinel: the sole
                       consumer (_notify_neon_risk) branches only on
                       `risk is None` to mean "no action, no signal" --
                       splitting the sentinel would require also changing
                       that check (and its risk-label mapping) for zero
                       behavior difference, so the value stays shared and
                       the two `return None` sites below stay textually
                       separate for legibility instead.
      "credential"  -- a LABELLING refinement only, not a security boundary
                       (see the comment block above _NEON_CREDENTIAL_RE):
                       flags a non-safe tool whose name contains a
                       credential-shaped word so the notification says
                       something more useful than a bare "unsafe". Checked
                       first only so a credential-shaped name can never
                       accidentally match the (now-exact, non-overlapping)
                       safe-read enumeration; safety does not depend on this
                       branch running at all.
      "unsafe"      -- the fail-closed default: everything else, including
                       every unrecognised get_*/list_*/describe_* tool and
                       any tool this classifier has never seen before.
    Both regexes use .fullmatch() -- see _DISPATCH_NAME_RE's comment for why
    match()+trailing $ lets a trailing-newline tool name through.

    PREFIX HARDENING (4th pass, 2026-08-24 -- security reproduced this
    directly against the classifier): the prefix gate previously did a bare
    `tool_name.startswith("mcp__neon__")`, so an uppercase
    "MCP__NEON__delete_branch", a leading space, or a leading newline all
    fell through the first `if` below to `return None` -- i.e. "not a Neon
    tool at all", identical to a genuinely unrelated tool, instead of being
    recognised and classified. `normalized` below is `.lstrip().lower()`
    ONLY (leading whitespace stripped, case folded) -- deliberately NOT a
    full `.strip()`: stripping the TRAILING side too would silently re-open
    the exact bypass the .fullmatch() switch above already closed (a
    regression-tested case -- see tests/cast-neon-notify-guard.bats's
    trailing-newline test), so trailing whitespace is left in place and
    still fails every fullmatch below, still falling through to "unsafe".
    Deliberately narrow scope: a leading NON-whitespace character is not
    stripped, so this must not and does not widen into typosquat matching --
    "mcp__neonfake__delete_all" still does not start with "mcp__neon__"
    after normalisation (it starts with "mcp__neonfake__") and still
    correctly returns None. Both regex fullmatch calls below now run
    against `normalized` too, not just the prefix test, so a case/whitespace
    variant of a genuinely safe read (e.g. "MCP__NEON__LIST_PROJECTS")
    classifies the SAME as its canonical-case form instead of merely
    happening to fail closed by accident of case.

    Prefix-scoped to the neon server only -- a non-Neon mcp__<other>__* tool
    is deliberately NOT matched (a different server needs its own guard).

    ARGUMENT-AWARE (2026-10-03): `tool_input` is optional (backward
    compatible). The one tool whose safety depends on its arguments is
    explain_sql_statement -- `analyze: true` EXECUTES the SQL and its side
    effects -- so it classifies "unsafe" unless `analyze` is explicitly false
    (see _explain_may_execute; missing/unparseable input fails closed)."""
    tool_name = tool_name or ""
    normalized = tool_name.lstrip().lower()
    if not normalized.startswith("mcp__neon__"):
        return None
    if _NEON_CREDENTIAL_RE.fullmatch(normalized):
        return "credential"
    if _NEON_SAFE_READ_RE.fullmatch(normalized):
        # explain_sql_statement is a known-safe read ONLY when it does not
        # execute the statement (see _explain_may_execute).
        if normalized == _NEON_EXPLAIN_TOOL and _explain_may_execute(tool_input):
            return "unsafe"
        return None
    return "unsafe"


def _notify_neon_risk(tool, tool_input, data):
    """Notify + record a risky (credential or unsafe/write) Neon MCP tool
    call. Never hard-blocks (never exits 2) and never raises -- fail-open,
    matching this file's module-level contract ("any unhandled error -> exit
    0; a guard crash must never block all tool use"). Returns the egress advisory action for the
    subagent case (see RECORD below) so main() can fold it into its single
    stdout object, else None; the native ask is built separately by
    _neon_ask_reason.

    RECORD: a top-level (non-subprocess) call is already recorded moments
    later by the normal EGRESS step further down in main() (_run_egress ->
    sentinel.record()), which captures the FULL tool_name (e.g.
    "mcp__neon__delete_branch", not just surface/server) to
    logs/egress.jsonl -- "neon" is classified cloud_bound in
    config/egress-policy.json, so every neon call already reaches record().
    Calling record() again here for that case would double-write the
    ledger, so this function fills only the one real gap: a DISPATCHED
    SUBAGENT (CLAUDE_SUBPROCESS=1) never reaches that later step at all --
    main()'s recursion-prevention early-return returns 0 first, before step
    2 (EGRESS) ever runs. Only that case gets an explicit record() call
    here.

    tool_input payloads are deliberately never added to the ledger line or
    the notify message -- record() already omits generic tool_input fields
    for every MCP surface (a documented no-payload invariant, not a
    Neon-specific gap; see cast-egress-sentinel.py's record() docstring/
    comments), and the notify message below is built from the tool NAME
    only, never tool_input, so this guard does not widen what gets
    persisted or displayed.

    EVENT TYPE: uses "neon_write", not "blocked" -- this code never
    hard-blocks the call (it exits 0, never 2); at most the call is PROMPTED,
    by the native permissions.ask globs and by this hook's own ask object
    (_neon_ask_reason), and the user may approve it. Under headless or
    CLAUDE_SUBPROCESS=1 nobody can answer a prompt, so there it is
    effectively a deny (intended fail-closed) -- but that is the prompt's
    doing, not this notification's. Sending "blocked" for an action that may
    proceed trains the user to ignore real blocks (security finding).
    Deliberately does NOT bypass quiet hours: unlike budget_alert, which
    needs immediate attention to stop a cost overrun, this is a record-only
    FYI about a call that is being prompted or has already been approved --
    see scripts/cast-notify.sh's in_quiet_hours call site for the matching
    inline comment.
    """
    try:
        risk = _classify_neon_risk(tool, tool_input)
        if risk is None:
            return None
        # --- notify: best-effort desktop notification; never hard-blocks. ---
        try:
            import subprocess as _sp
            notify_script = os.path.join(SCRIPT_DIR, "cast-notify.sh")
            if os.path.isfile(notify_script):
                label = "CREDENTIAL" if risk == "credential" else "write/unsafe"
                _sp.run(
                    ["bash", notify_script, "neon_write",
                     f"Neon {label} tool called: {tool}",
                     "CAST Neon Guard"],
                    # 1 s, not 3: the hook's settings timeout is 5 s and the
                    # native ask prints LAST (after this, the sentinel load
                    # and the ledger write), so the worst case must stay well
                    # under it. A timeout here is swallowed (fail-open).
                    timeout=1, capture_output=True,
                )
        except Exception:
            pass
        # --- record: only the subagent gap (see docstring above) ---
        if os.environ.get("CLAUDE_SUBPROCESS", "0") == "1":
            sentinel = _load("cast_egress_sentinel", "cast-egress-sentinel.py")
            if sentinel is not None:
                # Recorded here; the advisory (if any) is RETURNED, not printed,
                # so main() can fold it into the single JSON object it emits
                # alongside the native ask (stdout must hold exactly one).
                return _run_egress(sentinel, data)
    except Exception:
        pass
    return None


def _neon_ask_reason(tool, tool_input):
    """Reason text for a native `permissionDecision: "ask"` on a risky Neon
    call, or None when no prompt is warranted (not a Neon tool, a known-safe
    read, or any internal error -- fail-open by this hook's contract; the
    managed-settings.d/12-ask.json globs are the belt for that case).

    The text names the tool only. tool_input content (SQL text etc.) is
    NEVER included: the reason is shown to the user and written to
    transcripts, and the ledger/notify paths keep the same no-payload
    invariant. A tool name that is not a plain identifier is replaced by the
    word "tool" so odd bytes never reach the prompt."""
    try:
        risk = _classify_neon_risk(tool, tool_input)
        if risk is None:
            return None
        normalized = (tool or "").lstrip().lower()
        bare = normalized[len("mcp__neon__"):]
        if not re.fullmatch(r"[a-z0-9_]{1,80}", bare):
            bare = "tool"
        if risk == "credential":
            return f"[CAST] Neon {bare} can return a credential — confirm before it runs."
        if normalized == _NEON_EXPLAIN_TOOL:
            return (
                "[CAST] explain_sql_statement with analyze not explicitly false "
                "executes the SQL and its side effects — confirm before it runs."
            )
        return (
            f"[CAST] Neon {bare} is not on CAST's known-safe read list "
            "(write or unrecognised tool) — confirm before it runs."
        )
    except Exception:
        return None


_NEON_UNPARSEABLE_REASON = (
    "[CAST] Neon tool call could not be parsed by the guard — "
    "confirm before it runs."
)
_NEON_TOOL_NAME_SCAN_RE = re.compile(r'"tool_name"\s*:\s*"\s*mcp__neon__', re.IGNORECASE)


def _emit_unparseable_neon_ask(raw):
    """Parse-failure branch ONLY. If the raw stdin still LOOKS like a Neon
    tool call (a `"tool_name": "mcp__neon__` token), print ONE ask object --
    fail-closed where the structured path cannot run. Any error or no match
    -> print nothing (fail-open, exit 0 by the caller).

    The WHOLE of `raw` is scanned, not a prefix: if the harness serialises
    tool_input before tool_name, a >64 KiB tool_input would push the name past
    any fixed prefix window and hide it (reproduced on 3.9). The regex is
    linear (a literal prefix, no nested quantifiers), so the full scan is
    cheap: ~130 KB of adversarial input measured at 0.02 s."""
    try:
        if _NEON_TOOL_NAME_SCAN_RE.search(raw):
            print(json.dumps({"hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "permissionDecision": "ask",
                "permissionDecisionReason": _NEON_UNPARSEABLE_REASON,
            }}))
    except Exception:
        pass


# Parse-failure scan for a Write/Edit call (see _unparseable_write_edit_verdict). Linear: a
# literal prefix plus bounded alternation, no nested quantifiers.
_WRITE_EDIT_TOOL_NAME_SCAN_RE = re.compile(r'"tool_name"\s*:\s*"(Write|Edit)"')


def _unparseable_write_edit_verdict(raw, exc):
    """Parse-failure branch ONLY. (code, msg) when the unparseable stdin still LOOKS like a
    Write/Edit call, else None.

    An attacker-shaped payload (e.g. 1,000,000-deep nesting in an extra tool_input key ->
    RecursionError) makes json.loads fail, and the policy gate never ran: that must not allow
    the write. Same verdict as a raising evaluate() -- BLOCK, or allow under
    CAST_POLICY_OVERRIDE=1 (audited best-effort). The whole of `raw` is scanned (the harness may
    serialise tool_input before tool_name); the reason names the exception CLASS only, never raw
    text. A block is stderr + exit 2, so the caller must NOT also print the Neon ask object:
    exactly one outcome per call. Like the parsed path, managed/headless sub-claude
    (CLAUDE_SUBPROCESS=1) skips the Write/Edit policy engine."""
    if os.environ.get("CLAUDE_SUBPROCESS", "0") == "1":
        return None
    m = _WRITE_EDIT_TOOL_NAME_SCAN_RE.search(raw)
    if m is None:
        return None
    git_guard = _load("cast_git_guard", "cast-git-guard.py")
    if git_guard is None:
        # Guard module failed to LOAD: same verdict (and content-free override log line) as
        # the parsed Write/Edit path, rather than _write_edit_gate_error(None, ...).
        code, msg = _write_edit_guard_unavailable(m.group(1))
    else:
        code, msg = _write_edit_gate_error(git_guard, m.group(1), {}, "", exc)
    return (code, msg) if code == 2 else None


# Parse-failure scan for a Bash call (see _unparseable_bash_verdict). Linear, like the one above.
_BASH_TOOL_NAME_SCAN_RE = re.compile(r'"tool_name"\s*:\s*"Bash"')
# JSON string escapes (linear: one backslash + a fixed-width alternative). A command's newline
# or quote reaches the raw text as `\n` / `\"`, which must not glue onto the neighbouring word.
_JSON_ESCAPE_RE = re.compile(r'\\(?:u([0-9a-fA-F]{4})|(["\\/bfnrt]))')
_JSON_ESCAPE_CHARS = {'"': '"', "\\": "\\", "/": "/", "b": " ", "f": " ",
                      "n": "\n", "r": "\r", "t": "\t"}


def _json_unescape_repl(m):
    hex4 = m.group(1)
    return chr(int(hex4, 16)) if hex4 is not None else _JSON_ESCAPE_CHARS[m.group(2)]


def _unparseable_bash_verdict(raw, exc):
    """Parse-failure branch ONLY. The degraded git block message (str) when the unparseable
    stdin still LOOKS like a Bash call and its raw text runs a coarse irreversible git verb,
    else None. Neither git guard ran on this payload (a Bash call whose JSON fails to parse --
    e.g. absurd nesting in an extra tool_input key -- would otherwise be a blanket allow, in
    healthy mode too), so the same coarse scan runs over the JSON-unescaped raw text; the
    verbs' normal hatches are still honoured. Logs the exception CLASS only. A block is
    stderr + exit 2, so the caller must NOT also print the Neon ask: one outcome per call.
    Applies in EVERY context, like the parsed Bash path."""
    if _BASH_TOOL_NAME_SCAN_RE.search(raw) is None:
        return None
    _log_error(f"unparseable Bash payload ({type(exc).__name__}); degraded git scan of raw text")
    try:
        text = _JSON_ESCAPE_RE.sub(_json_unescape_repl, raw)
    except Exception:
        text = raw
    return _degraded_git_block(text, "was given an unparseable payload")


def _emit_pretool_output(sentinel, action, neon_reason, extra_context=None):
    """Print AT MOST ONE hookSpecificOutput JSON object on stdout (Claude Code
    2.1.288 BLOCKS the call when a PreToolUse hook's output fails to parse, so
    two concatenated objects must never happen).

      neon_reason set  -> {"permissionDecision": "ask", "permissionDecisionReason":
                          neon_reason}, plus "additionalContext" when an egress
                          advisory and/or `extra_context` also exist (their text is
                          folded in, joined with "\\n", not printed separately);
      neon_reason None -> the egress advisory and/or `extra_context` (a Write/Edit
                          warn-policy advisory) as ONE additionalContext object, or
                          nothing. With `extra_context` None this is the unchanged
                          egress-advisory-alone behaviour.
    Never raises."""
    try:
        advisory = action is not None and action[0] == "advisory"
        extra = extra_context if isinstance(extra_context, str) and extra_context else None
        parts = []
        if advisory and sentinel is not None:
            try:
                parts.append(sentinel.advisory_context(action[1]))
            except Exception:
                pass
        if extra:
            parts.append(extra)
        if neon_reason:
            out = {
                "hookEventName": "PreToolUse",
                "permissionDecision": "ask",
                "permissionDecisionReason": neon_reason,
            }
            if parts:
                out["additionalContext"] = "\n".join(parts)
            print(json.dumps({"hookSpecificOutput": out}))
        elif extra:
            print(json.dumps({"hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "additionalContext": "\n".join(parts),
            }}))
        elif advisory and sentinel is not None:
            _emit_egress(sentinel, action)
    except Exception:
        pass


def _block(message):
    if message:
        print(message, file=sys.stderr)
    return 2


def _write_edit_gate_error(git_guard, tool, tool_input, session_id, exc):
    """(code, msg) when git_guard.evaluate() RAISED for a Write/Edit: fail CLOSED.

    evaluate() fails closed on its own and should never raise; if it does, the policy gate
    did not run, so the write is blocked unless CAST_POLICY_OVERRIDE=1 (audited via the
    guard's own writer, best-effort). The reason names the exception CLASS only -- never
    str(exc) or the path, which can carry attacker-controlled text. Never raises."""
    exc_class = type(exc).__name__
    _log_error(f"Write/Edit policy gate could not run for {tool} ({exc_class}); failing closed")
    if os.environ.get("CAST_POLICY_OVERRIDE", "0") == "1":
        try:
            path = tool_input.get("file_path", tool_input.get("path"))
            git_guard._audit_policy_override(
                "policy-internal-error",
                path if isinstance(path, str) else "<unresolved file_path>",
                session_id if session_id else os.environ.get("CLAUDE_SESSION_ID", "default"),
            )
        except Exception:
            pass
        return 0, ""
    return 2, (
        f"**[CAST-POLICY-BLOCK]** Internal error ({exc_class}) while checking this {tool} "
        f"against the policies; failing closed.\n"
        f"Escape hatch: Set CAST_POLICY_OVERRIDE=1 to bypass (document your reason)."
    )


def _write_edit_guard_unavailable(tool):
    """(code, msg) for a Write/Edit when cast-git-guard.py failed to LOAD: fail CLOSED.

    No policy ran, so the write is blocked unless CAST_POLICY_OVERRIDE=1. The guard's own
    audit writer is unavailable, so an override is logged to hook-errors.log instead,
    content-free (tool name only -- never a path or exception text). Never raises."""
    if os.environ.get("CAST_POLICY_OVERRIDE", "0") == "1":
        _log_error(f"{tool}: CAST_POLICY_OVERRIDE=1 override used while guard unavailable")
        return 0, ""
    _log_error(f"Write/Edit policy guard unavailable for {tool}; failing closed")
    return 2, (
        f"**[CAST-POLICY-BLOCK]** The policy guard module (cast-git-guard.py) failed to load, "
        f"so this {tool} could not be checked; failing closed. "
        f"Repair: bash install.sh from the claude-agent-team checkout "
        f"(details: ~/.claude/logs/hook-errors.log).\n"
        f"Escape hatch: Set CAST_POLICY_OVERRIDE=1 to bypass (document your reason)."
    )


# Degraded-mode git guard: cast-git-guard.py failed to LOAD, so ONLY this coarse list of
# irreversible git verbs stays blocked (everything else is allowed so a repair is possible),
# each with its EXISTING escape hatch. rebase/merge are deliberately absent: the normal guard
# allows them and they have no hatch, so degraded mode must not be stricter than normal mode
# with nothing to escape through.
_DEGRADED_GIT_HATCHES = {
    "commit": "CAST_COMMIT_AGENT=1",
    "push": "CAST_PUSH_OK=1",
    "reset": "CAST_RESET_OK=1",
    "clean": "CAST_CLEAN_OK=1",
    "stash": "CAST_STASH_OK=1",
    "checkout": "CAST_CHECKOUT_OK=1",
    "restore": "CAST_RESTORE_OK=1",
    "branch": "CAST_BRANCH_OK=1",
}
# Normalization for the whole-command scan: command separators and the shell-syntax glue
# that can sit flush against a git word are turned into spaces (`$(`, backticks, `<`/`>`
# redirects, `${IFS}`, NUL, and the JSON punctuation `: , [ ]` that glues a word to its key
# when the raw text of an unparseable payload is scanned); quotes and backslashes are
# deleted (`"git" push`, `g\it push`).
# NO segmentation: a separator INSIDE a git argument (`git -C "$(pwd)" push`,
# `git -c user.name="Ed (K)" commit`) must not hide the verb from the scan.
_DEGRADED_NORM_TABLE = {ord(c): " " for c in ";&|\n\r()`<>${}\x00:,[]"}
_DEGRADED_NORM_TABLE.update({ord(c): None for c in "\"'\\"})


def _degraded_normalize(text):
    # `$'git'` / `$"git"` (ANSI-C / locale quoting) -> plain quotes first; then the table.
    return text.replace("$'", "'").replace('$"', '"').translate(_DEGRADED_NORM_TABLE)


def _degraded_git_scan(command, why):
    """The degraded-mode scan proper (see _degraded_git_block). May raise; the caller fails
    closed. Linear: one translate, one split, two passes over the tokens, <= 8 hatch lookups."""
    # NUL: bash either drops it (glues the neighbours) or ends the word -- scan both readings.
    variants = [command]
    if "\x00" in command:
        variants = [command.replace("\x00", " "), command.replace("\x00", "")]
    present = None  # hatch tokens found in the WHOLE command; computed ONCE, never per match
    for text in variants:
        norm = _degraded_normalize(text)
        if "git" not in norm.lower():
            continue
        tokens = norm.split()
        start = None
        for i, tok in enumerate(tokens):
            low = tok.lower()  # `GIT push` runs on a case-insensitive macOS filesystem
            if low == "git" or low.endswith("/git"):
                start = i + 1
                break
        if start is None:
            continue
        seen = {}  # verb -> None, in first-seen order
        has_D = has_d = has_f = False
        for tok in tokens[start:]:
            low = tok.lower()
            if low in _DEGRADED_GIT_HATCHES:
                seen[low] = None
            elif tok.startswith("--"):
                name = tok.split("=", 1)[0]
                if len(name) >= 3:
                    has_d = has_d or "--delete".startswith(name)
                    has_f = has_f or "--force".startswith(name)
            elif tok.startswith("-") and len(tok) > 1:
                has_D = has_D or "D" in tok
                has_d = has_d or "d" in tok
                has_f = has_f or "f" in tok
        if not seen:
            continue
        if present is None:
            present = {h for h in _DEGRADED_GIT_HATCHES.values() if h in command}
        for verb in seen:
            if verb == "branch" and not (has_D or (has_d and has_f)):
                continue
            hatch = _DEGRADED_GIT_HATCHES[verb]
            if hatch in present:
                continue
            return (
                f"**[CAST]** The git guard module {why}, so git {verb} is blocked in "
                f"degraded mode. Use the normal hatch ({hatch} …) if intended, and repair with "
                f"bash install.sh (details: ~/.claude/logs/hook-errors.log)."
            )
    return None


def _degraded_git_block(command, why="failed to load"):
    """Block message (str) when `command` runs a coarse irreversible git verb and its hatch
    token is absent from the WHOLE command, else None. Used ONLY when the git guard did not
    run: its module failed to load (`why`, the default), its evaluate() raised, or the payload
    was unparseable. COARSE: over-blocking is acceptable, under-blocking is not.

    The whole command is normalized (_degraded_normalize) and tokenized -- NOT split into
    segments, so a separator inside a git argument cannot hide the verb. The first token that
    is `git` or ends in `/git` (case-insensitive) marks the start; EVERY later token is checked
    against the verb table (so global options taking an argument, like `-C dir`, cannot hide
    the verb, and `git status && make clean` over-blocks by design). `branch` blocks only with
    a force-delete shape over the later tokens: -D, or d+f (-d -f / -df / -fd / --delete
    --force), long flags matched by prefix since git accepts unambiguous abbreviations.
    O(len(command)); the hatch lookup is done once (a per-match scan was O(matches x len)).

    Fails CLOSED: an exception in the scan blocks any command that mentions `git` at all
    (never allows it); a command without the substring `git` cannot name the binary."""
    if not isinstance(command, str):
        return None
    try:
        return _degraded_git_scan(command, why)
    except Exception as exc:
        _log_error(f"degraded git check raised {type(exc).__name__}; failing closed")
        try:
            names_git = "git" in command.lower()
        except Exception:
            names_git = True
        if not names_git:
            return None
        return (
            f"**[CAST]** The git guard module {why}, and the degraded-mode git check itself "
            f"failed ({type(exc).__name__}), so this command is blocked. Repair with bash "
            f"install.sh (details: ~/.claude/logs/hook-errors.log)."
        )


def _record_dispatch(data):
    """Record a dispatch_decisions row (outcome='pending') for a Task dispatch.
    Record-only, fail-soft — must never raise or block the dispatch."""
    try:
        ti = data.get("tool_input", {}) or {}
        if not isinstance(ti, dict):
            return
        chosen_agent = ti.get("subagent_type") or "unknown"
        # dispatch_name (I-2c): the dispatch's custom Agent-tool `name=`, when given (None
        # otherwise). Captured so a later join can use whichever of (chosen_agent,
        # dispatch_name) SubagentStop actually saw as ctx.agent_name — a custom `name` makes
        # Claude Code report THAT as agent_type instead of the roster type, which silently
        # breaks the exact match dispatch_decisions.outcome is closed on. Shape-gated AND
        # redaction-screened before storage — see _sanitize_dispatch_name's docstring for
        # the fail-closed, three-step pipeline and its honest limit.
        dispatch_name = _sanitize_dispatch_name(ti.get("name"))
        prompt = (ti.get("prompt") or ti.get("description") or "")[:500]
        # Redact PII/secrets before storage (consistency with cast_subagent_stop.py incident stage;
        # cast.db can sync off-machine). FAIL-CLOSED: if redaction does not succeed on a
        # non-empty prompt, store a [REDACTION_FAILED] marker rather than raw text — never
        # leak unredacted content into cast.db. Still never blocks the dispatch.
        if prompt:
            _redacted = None
            _exc_name = None
            try:
                import subprocess as _sp
                _r = _sp.run(
                    ["python3", "-I", os.path.join(SCRIPT_DIR, "cast-redact.py"),
                     "--engine", "regex", "--field", "redacted_text"],
                    input=prompt, capture_output=True, text=True, timeout=3,
                )
                _out = _r.stdout.strip()
                if _r.returncode == 0 and _out:
                    _redacted = _out
            except Exception as _exc:
                _redacted = None
                _exc_name = type(_exc).__name__
            if _redacted is None:
                # CONTENT-FREE breadcrumb (byte length + exception class + site
                # only, never the prompt itself) — two 2026-07-02 incidents were
                # never root-caused because [REDACTION_FAILED] carried no other
                # detail. Wrapped so breadcrumb construction can never itself
                # raise on this already-error path.
                try:
                    _byte_len = len(prompt.encode("utf-8", errors="replace"))
                    _log_error(
                        "dispatch redaction failed — storing [REDACTION_FAILED] marker "
                        f"(site=dispatch_decisions.prompt input_bytes={_byte_len} "
                        f"exception={_exc_name or 'none'})"
                    )
                except Exception:
                    pass
                prompt = "[REDACTION_FAILED]"
            else:
                prompt = _redacted
        model = ti.get("model")  # usually absent in tool_input → NULL
        session_id = _payload_session_id(data)
        db = os.path.expanduser(os.environ.get("CAST_DB_PATH", "~/.claude/cast.db"))
        if not os.path.isfile(db):
            return
        import sqlite3

        conn = sqlite3.connect(db, timeout=1)
        try:
            try:
                # Column list kept on ONE string literal (not split across adjacent
                # literals) so cast-db-contract.py's writer-attribution regex can see
                # it — \s* in that regex cannot cross the closing-quote/opening-quote
                # seam between two adjacent Python string literals, only whitespace
                # within a single literal (see cast-db-contract.py's insert_re).
                conn.execute(
                    "INSERT INTO dispatch_decisions (session_id, prompt_snippet, chosen_agent, model, outcome, dispatch_name) "
                    "VALUES (?, ?, ?, ?, 'pending', ?)",
                    (session_id, prompt, chosen_agent, model, dispatch_name),
                )
            except sqlite3.OperationalError as e:
                # Fallback for a DB that predates migration 033 (dispatch_decisions has no
                # dispatch_name column yet). This function is contractually record-only,
                # fail-soft — without this fallback the outer `except Exception` would swallow
                # the OperationalError and silently stop recording EVERY dispatch row on an
                # unmigrated DB, not just drop the new column. Retry the original 5-column
                # INSERT so the row is still recorded.
                if "has no column named" not in str(e).lower():
                    raise
                conn.execute(
                    "INSERT INTO dispatch_decisions (session_id, prompt_snippet, chosen_agent, model, outcome) "
                    "VALUES (?, ?, ?, ?, 'pending')",
                    (session_id, prompt, chosen_agent, model),
                )
            conn.commit()
        finally:
            conn.close()
    except Exception as e:
        _log_error(f"dispatch_decisions record failed: {type(e).__name__}")


_WORKFLOW_LINT_MOD = "cast_lint_workflow_stage_models"
_WORKFLOW_LINT_FILE = "cast-lint-workflow-stage-models.py"
_WORKFLOW_SCRIPT_MAX_BYTES = 1024 * 1024
_WORKFLOW_REASON_MAX_ENTRIES = 10
_WORKFLOW_SNIPPET_MAX = 80
# Fail-open bounds (hook only -- the lint CLI has none). The hook's budget is 5 s
# and the lint is superlinear on pathological input, so a source over either
# bound is ALLOWED unlinted. Raw `agent(` matches over-count (comments/strings
# included), which only makes the bound more conservative. These bound size and
# count, NOT shape: malformed nesting inside them can still be slow (measured:
# 150 unclosed `agent(` + 64 KiB of padding ~10 s), so the lint itself also runs
# under a wall-clock watchdog (_lint_with_watchdog).
_WORKFLOW_MAX_SOURCE_CHARS = 256 * 1024
_WORKFLOW_MAX_AGENT_CALLS = 2000
_WORKFLOW_LINT_BUDGET_SECS = 2.0  # < the hook's 5 s timeout, with margin for startup
# The scriptPath read gets its OWN window (not the lint's): the lint module load sits
# between the two and must never run under an alarm. Worst case read + lint stays
# 1 s + 2 s = 3 s, inside the 5 s hook timeout with margin for startup + the load.
_WORKFLOW_READ_BUDGET_SECS = 1.0


def _read_workflow_script_path(data, path):
    """Read a Workflow `scriptPath` -> decoded text, or None (= nothing lintable):
    non-str / empty path, missing / unreadable / non-regular / oversize (> 1 MiB)
    file, or a path the OS refuses (NUL byte, lone surrogate). Relative paths
    resolve against the payload `cwd`.

    Opened FIRST with O_NONBLOCK and judged with fstat on the SAME fd, so a path
    swapped for a FIFO between a stat and an open cannot block the hook (an
    open() of a FIFO with no writer waits forever) and a FIFO / device is never
    read. O_NONBLOCK does NOT bound a slow open()/read() of a REGULAR file (a
    stalled network filesystem): that is _read_workflow_script_path_bounded's
    SIGALRM window, and the one reason this function may raise
    _WorkflowLintTimeout -- never call it unbounded from the guard."""
    if not isinstance(path, str) or not path:
        return None
    fd = -1
    try:
        path = os.path.expanduser(path)
        if not os.path.isabs(path):
            cwd = data.get("cwd")
            if isinstance(cwd, str) and cwd:
                path = os.path.join(cwd, path)
        fd = os.open(path, os.O_RDONLY | getattr(os, "O_NONBLOCK", 0) | getattr(os, "O_CLOEXEC", 0))
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            return None
        with os.fdopen(fd, "rb") as fh:
            fd = -1  # fh owns (and closes) the descriptor from here on
            raw = fh.read(_WORKFLOW_SCRIPT_MAX_BYTES + 1)
    except (OSError, ValueError):
        return None
    finally:
        if fd != -1:
            try:
                os.close(fd)
            except OSError:
                # An alarm landing between fdopen() and `fd = -1` leaves fh to close
                # the descriptor as well; an EBADF here must not replace the
                # in-flight exception.
                pass
    if len(raw) > _WORKFLOW_SCRIPT_MAX_BYTES:
        return None
    return raw.decode("utf-8", errors="replace")


def _read_workflow_script_path_bounded(data, path):
    """_read_workflow_script_path under its own SIGALRM wall-clock budget
    (_WORKFLOW_READ_BUDGET_SECS), so a `scriptPath` on a stalled filesystem cannot
    hold the hook past its timeout (every other failure mode here allows silently,
    so a hang would otherwise end in Claude Code's hook-timeout kill instead).

    A read that outruns the budget is logged (content-free: no path, no text) and
    treated exactly like any other unreadable scriptPath -> None, "nothing
    lintable" -- so a scriptPath-only call is ALLOWED silently, same as a lint that
    outruns its watchdog, while an inline `script` in the same call is still
    linted. A path that is not even a non-empty str never opens a window."""
    if not isinstance(path, str) or not path:
        return None
    t0 = time.monotonic()
    try:
        return _run_under_watchdog(
            lambda: _read_workflow_script_path(data, path), _WORKFLOW_READ_BUDGET_SECS
        )
    except _WorkflowLintTimeout:
        _log_error(
            f"workflow scriptPath read timed out after {time.monotonic() - t0:.1f}s "
            f"(budget {_WORKFLOW_READ_BUDGET_SECS:g}s) — scriptPath treated as unreadable"
        )
        return None


def _workflow_sources(data, tool_input):
    """Workflow source texts to lint, as [(label, text), ...] (possibly empty).

    A non-empty `script` str is one source; a readable `scriptPath` (see
    _read_workflow_script_path_bounded) is another. BOTH are linted when both exist -- an
    empty or non-str `script` is "absent" and must never shadow a real file, and
    a clean `script` must not mask a violating file. Anything else (`name` of a
    saved workflow, resume, ...) yields no source -> allow."""
    sources = []
    script = tool_input.get("script")
    if isinstance(script, str) and script:
        sources.append(("script", script))
    text = _read_workflow_script_path_bounded(data, tool_input.get("scriptPath"))
    if text is not None:
        sources.append(("scriptPath", text))
    return sources


def _workflow_deny_reason(entries):
    """Deny reason: count, up to 10 `line N: <snippet <= 80 chars>` entries, then
    the fix. `entries` is [(label, lineno, text), ...]; the label ("script" /
    "scriptPath") is shown only when two sources were linted, so line numbers stay
    unambiguous. Stays under ~1500 chars (10 x ~92 + header + fix)."""
    total = len(entries)
    shown = entries[:_WORKFLOW_REASON_MAX_ENTRIES]
    lines = [
        f"{total} agent() stage(s) in this Workflow script have no model:, so they "
        "inherit the opus main-loop model (cost lever)."
    ]
    for label, lineno, text in shown:
        prefix = f"{label} " if label else ""
        lines.append(f"{prefix}line {lineno}: {str(text).strip()[:_WORKFLOW_SNIPPET_MAX]}")
    if total > len(shown):
        lines.append(f"(+{total - len(shown)} more)")
    lines.append(
        "Fix: add model: to each stage ('haiku' for mechanical/scout/gather, "
        "'sonnet' for analytical, 'opus' for synthesis/judge), or opt out on the "
        "agent( line or the line above with: "
        "// cast-lint: inherit-model -- <reason>  (reason required)."
    )
    return "\n".join(lines)


class _WorkflowLintTimeout(Exception):
    """Private: raised by the SIGALRM handler when the lint -- or the scriptPath
    read, in its own window -- outruns its budget. Deliberately an Exception (not
    BaseException): if the alarm ever lands outside the helper's own try, the
    guard's `except Exception` still turns it into an ALLOW instead of letting a
    traceback escape -- an uncaught hook crash is a BLOCK to Claude Code >= 2.1.288."""


# Wall-clock budget for the Bash git guard (2026-10-06). The hook timeout is 5 s and a hook
# TIMEOUT is a non-blocking error, i.e. an ALLOW: a command that sends the git guard
# super-linear (measured: ~15 s for 100 KB of repeated `git ` tokens before the regex fix)
# silently bypassed every git block in it. Past this budget any command that NAMES git is
# blocked, hatches ignored (`_git_guard_timeout_block`; fail CLOSED). 2.0 s = the Workflow
# lint's budget: well past the guard's measured worst case on a 1 MB command (~1.5 s, linear).
_GIT_GUARD_BUDGET_SECS = 2.0


class _GitGuardTimeout(BaseException):
    """Private: raised by the SIGALRM handler when the Bash git guard outruns
    _GIT_GUARD_BUDGET_SECS.

    A BaseException, UNLIKE _WorkflowLintTimeout, ON PURPOSE: git_guard.evaluate("Bash") ends in
    `except Exception: return 0, ''` (fail-open on a guard bug), and several helpers inside
    it swallow `Exception` too. The alarm is one-shot, so an Exception swallowed anywhere on
    the way up would let the slow scan run on unbounded -- and `evaluate` would then return
    ALLOW. Reusing _WorkflowLintTimeout was tried first and is exactly that bug (measured: the
    pre-fix guard under a 1 s alarm returned (0, '') at 1.0 s). BaseException passes through
    every `except Exception` to the one `except _GitGuardTimeout` in main(); the guard module
    has no bare `except:` / `except BaseException`."""


# Total wall-clock budget for the two Bash guards (git guard, then command guard), measured
# from the start of main(): the git guard gets _GIT_GUARD_BUDGET_SECS of it, the command guard
# whatever is left but never less than _COMMAND_GUARD_MIN_BUDGET_SECS. 3.5 s leaves ~1.5 s of
# the hook's 5 s for interpreter start-up and the egress / dispatch work after the guards.
# A hook TIMEOUT is an ALLOW, and cast-command-guard.py (rm -rf / pkill / kill) is also
# linear-but-slow on a huge command: 7.6-9.9 s observed on ~1 MB, run unwatched, which let the
# hook time out and ALLOW a catastrophic rm behind a megabyte of padding.
_BASH_GUARD_TOTAL_BUDGET_SECS = 3.5
_COMMAND_GUARD_MIN_BUDGET_SECS = 0.5


class _CommandGuardTimeout(BaseException):
    """Private: raised by the SIGALRM handler when cast-command-guard.py outruns its budget.
    BaseException for the same reason as _GitGuardTimeout: `safe_is_blocked` is
    `try: ... except Exception: return False, ''` (fail-open on a guard bug), which would
    swallow an Exception-based alarm and turn the timeout into an ALLOW."""


_CONTINUATION = re.compile(r"\\\r?\n")   # backslash-newline / backslash-CRLF: bash deletes both
_NON_LETTERS = re.compile(r"[^A-Za-z]+")


def _git_guard_timeout_block(command, budget):
    """Block message (str) for a command the git guard could not finish checking in `budget`
    s, or None when the command does not name git at all.

    Used ONLY on the timeout path (a load failure or an evaluate() raise still gets the coarse
    `_degraded_git_block`). A timed-out scan decided NOTHING about this command, so the 8-verb
    degraded table is not enough (it let rm, filter-branch, update-ref -d, reflog expire,
    gc --prune, worktree remove --force, switch -f and `-c gc.*=` through) and it must not
    honour a hatch (the degraded scan accepts a hatch token ANYWHERE in the command, which
    reopens the per-segment scoping the guard fixed on 2026-08-17: `echo CAST_PUSH_OK=1; ...;
    <raw push>`). So: ANY command that names git is refused, hatches ignored. "Names git" is
    three steps, in this order: (1) delete line continuations exactly as bash does (backslash +
    newline, and backslash + CR LF) -- `_degraded_normalize` deletes the backslash but turns the
    newline into a SPACE, so `g\\<newline>it` (which bash runs as `git`) read as `g it` and a
    command that timed out on it was ALLOWED (security round 2, HIGH-1); (2) the degraded
    normalisation (quotes/backslashes deleted, `$'x'` unwrapped, separators and shell glue turned
    into spaces); (3) collapse everything that is not an ASCII letter and test the letters for
    `git`, case-insensitively. Step 3 makes the test independent of WHATEVER sits between the
    letters (`g$''it`, `g''it`, `g\\it`, a continuation, a line of glue), so `GIT`, `$'git'`,
    `g'i't`, `/usr/bin/git`, `$(git ...)` all count. This over-blocks on purpose and ONLY on this
    path (`digit`, `github`, even `bag it` or `big;it`): a timed-out scan decided nothing, and a
    false block here is one split command, a false allow is a bypass. A command that never
    names git stays allowed. Linear; fails CLOSED (an internal error counts as naming git)."""
    try:
        text = command if isinstance(command, str) else ""
        variants = [text]
        if "\x00" in text:  # bash drops NUL or ends the word there: scan both readings
            variants = [text.replace("\x00", " "), text.replace("\x00", "")]
        names_git = any(
            "git" in _NON_LETTERS.sub("", _degraded_normalize(_CONTINUATION.sub("", v))).lower()
            for v in variants)
    except Exception:
        names_git = True
    if not names_git:
        return None
    return (
        f"**[CAST]** The git guard could not finish checking this command within "
        f"{budget:g}s, so it is blocked. Split it into smaller commands (one git operation "
        f"per command)."
    )


def _run_under_watchdog(fn, budget, exc_type=None):
    """fn() under ONE SIGALRM wall-clock budget of `budget` seconds.

    Returns fn()'s result; raises `exc_type` (default _WorkflowLintTimeout) when the budget
    expires first. Runs fn() WITHOUT a watchdog -- same result, no protection -- where
    SIGALRM/setitimer do not exist (non-POSIX) or signal.signal refuses (not the
    main thread of the main interpreter). Armed only around fn itself, never around
    the lint module load (an alarm mid-import would poison the module cache).

    The handler raises only while an `armed` flag is set; the inner finally disarms it
    BEFORE cancelling the timer, so an alarm already in flight at cancel time is a no-op
    instead of raising out of the outer finally and leaking `_on_alarm` as the handler.

    Disposition afterwards: the timer is cancelled FIRST; then a previously
    installed Python handler (or SIG_IGN) is restored, but SIG_DFL / None is
    replaced by a no-op -- never restored. This process is single-shot, and a
    SIGALRM arriving after the restore (one already in flight when the timer was
    cancelled) would, under SIG_DFL, terminate it with exit 142: a crashed hook,
    which Claude Code treats as a BLOCK. Windows are sequential (scriptPath read,
    then lint), never nested."""
    import signal

    if not (hasattr(signal, "SIGALRM") and hasattr(signal, "setitimer")):
        return fn()

    armed = [False]
    timeout_exc = exc_type if exc_type is not None else _WorkflowLintTimeout

    def _on_alarm(signum, frame):
        if armed[0]:
            raise timeout_exc()

    def _noop(signum, frame):
        return None

    # `previous` starts as a sentinel: if a stale in-flight alarm raises right AFTER
    # signal.signal() installed _on_alarm but BEFORE the assignment, the finally
    # still runs and replaces the leaked handler with a no-op (the original is
    # unknowable there, and a no-op is always safe -- see Disposition above).
    unset = object()
    previous = unset
    refused = False
    try:
        try:
            previous = signal.signal(signal.SIGALRM, _on_alarm)
        except (ValueError, OSError):
            refused = True  # nothing installed -> nothing to restore
            return fn()
        try:
            armed[0] = True
            signal.setitimer(signal.ITIMER_REAL, budget)
            return fn()
        finally:
            armed[0] = False  # disarm FIRST: a stale in-flight alarm is now a no-op
            signal.setitimer(signal.ITIMER_REAL, 0)  # then cancel
    finally:
        if not refused:
            if previous is unset or previous is None or previous == signal.SIG_DFL:
                signal.signal(signal.SIGALRM, _noop)
            else:
                signal.signal(signal.SIGALRM, previous)


def _lint_with_watchdog(lint, srcs):
    """lint.find_violations_in_source over each text in `srcs`, all under ONE
    wall-clock budget (_WORKFLOW_LINT_BUDGET_SECS, via _run_under_watchdog).

    Returns a list of the lint's (violations, unterminated), one per source;
    raises _WorkflowLintTimeout when the budget expires first."""
    return _run_under_watchdog(
        lambda: [lint.find_violations_in_source(src) for src in srcs],
        _WORKFLOW_LINT_BUDGET_SECS,
    )


def _workflow_stage_model_guard(data, tool_input):
    """PreToolUse DENY for a Workflow script with an agent() stage lacking model:
    (such stages silently inherit the opus main-loop model; Ed-approved
    2026-10-03). Reuses cast-lint-workflow-stage-models.py's
    find_violations_in_source, lazy-loaded here only (Bash/Read/Write/Edit never
    pay for it). An inline `script` and a `scriptPath` file are both linted when
    both are present; a violation in either denies.

    ALWAYS returns 0 and prints at most ONE hookSpecificOutput object, built in
    full before printing: Claude Code >= 2.1.288 BLOCKS a tool call whose
    PreToolUse hook crashes or emits malformed output, so every failure mode
    (lint module missing, any exception, a parse anomaly, a source over the
    size / agent( count bounds, or a lint that outruns its 2 s wall-clock
    watchdog) ALLOWS silently and is logged. Content-free logging: exception
    class and counts only, never script text."""
    src_len = n_calls = 0
    t_lint = None
    try:
        sources = _workflow_sources(data, tool_input)
        sized = []
        for label, text in sources:
            if len(text) > _WORKFLOW_MAX_SOURCE_CHARS:
                _log_error(
                    f"workflow stage-model lint skipped: {label} is {len(text)} chars, "
                    f"over the {_WORKFLOW_MAX_SOURCE_CHARS}-char bound — allowed unlinted"
                )
            else:
                sized.append((label, text))
        if not sized:
            return 0
        lint = _load(_WORKFLOW_LINT_MOD, _WORKFLOW_LINT_FILE)
        if lint is None:  # _load already logged + recorded the lost guard
            return 0
        to_lint = []
        for label, text in sized:
            count = 0
            for _m in lint.AGENT_CALL_RE.finditer(text):
                count += 1
                if count > _WORKFLOW_MAX_AGENT_CALLS:
                    break
            if count > _WORKFLOW_MAX_AGENT_CALLS:
                _log_error(
                    f"workflow stage-model lint skipped: {label} has more than "
                    f"{_WORKFLOW_MAX_AGENT_CALLS} agent( matches, over the call-count "
                    "bound — allowed unlinted"
                )
            else:
                to_lint.append((label, text))
                src_len += len(text)
                n_calls += count
        if not to_lint:
            return 0
        t_lint = time.monotonic()
        results = _lint_with_watchdog(lint, [text for _label, text in to_lint])
        entries = []
        multi = len(to_lint) > 1
        for (label, _text), (violations, unterminated) in zip(to_lint, results):
            if unterminated is not None:
                # Scrub cannot be trusted -> the empty violation list is NOT a
                # clean bill. A parser limitation must not block work: allow this
                # source, but say so.
                _log_error(
                    f"workflow stage-model lint skipped: unterminated {unterminated} "
                    f"quote in {label} (parse anomaly) — allowed"
                )
                continue
            for lineno, text in violations:
                entries.append((label if multi else "", lineno, text))
        if not entries:
            return 0
        out = json.dumps({"hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": _workflow_deny_reason(entries),
        }})
    except _WorkflowLintTimeout:
        elapsed = (time.monotonic() - t_lint) if t_lint is not None else 0.0
        _log_error(
            f"workflow stage-model lint timed out after {elapsed:.1f}s "
            f"(budget {_WORKFLOW_LINT_BUDGET_SECS:g}s) on {src_len} chars of source "
            f"with {n_calls} agent( matches — allowed unlinted"
        )
        return 0
    except Exception as e:
        name = type(e).__name__
        _log_error(f"workflow stage-model lint failed — allowed: {name}")
        _record_guard_failure("cast_lint_workflow_runtime",
                              f"runtime error in Workflow stage-model guard: {name}",
                              data.get("session_id"))
        return 0
    try:
        print(out)
    except Exception:
        pass
    return 0


def main():
    global _PAYLOAD_SESSION_ID
    _PAYLOAD_SESSION_ID = None  # per-call: a payload that never parses has none
    t_main = time.monotonic()   # origin of _BASH_GUARD_TOTAL_BUDGET_SECS
    try:
        # Read BYTES and decode ourselves: sys.stdin.read() raises
        # UnicodeDecodeError on invalid UTF-8 (strict locale), which would
        # return 0 here before `raw` exists -- so a Neon call inside such a
        # payload got no ask. errors="replace" keeps `raw` defined (a U+FFFD
        # inside a JSON string still parses; one outside it falls to the
        # parse-failure scan below). Fall back to text read if stdin has no
        # .buffer (e.g. a patched stream).
        _stdin_buf = getattr(sys.stdin, "buffer", None)
        if _stdin_buf is not None:
            raw = _stdin_buf.read().decode("utf-8", errors="replace")
        else:
            raw = sys.stdin.read()
    except Exception:
        return 0
    if not raw.strip():
        return 0
    try:
        data = json.loads(raw)
    except Exception as parse_exc:
        # Parse failure (malformed JSON, or RecursionError on deep nesting --
        # /usr/bin/python3 3.9 trips it near 1000 levels). Everything below is
        # unreachable, so this is the ONLY place a Neon call can still be
        # caught: fail closed with a prompt rather than let it through
        # silently. Nothing but that one ask is ever printed on this path.
        # A Write/Edit call that went unparseable ran NO policy: it is blocked (stderr,
        # exit 2) instead -- unless CAST_POLICY_OVERRIDE=1 -- and then no Neon ask is
        # printed (one outcome per call).
        verdict = _unparseable_write_edit_verdict(raw, parse_exc)
        if verdict is not None:
            return _block(verdict[1])
        bash_msg = _unparseable_bash_verdict(raw, parse_exc)
        if bash_msg:
            return _block(bash_msg)
        _emit_unparseable_neon_ask(raw)
        return 0
    if not isinstance(data, dict):
        _emit_unparseable_neon_ask(raw)
        return 0

    _PAYLOAD_SESSION_ID = data.get("session_id")

    tool = data.get("tool_name", "") or ""
    tool_input = data.get("tool_input", {}) or {}
    if not isinstance(tool_input, dict):
        tool_input = {}

    # Workflow stage-model guard: runs in EVERY context (pure CPU, spawns nothing,
    # so no recursion risk) and owns this tool call outright -- none of the Bash /
    # Neon / Write / egress / dispatch paths below apply to `Workflow`.
    if tool == "Workflow":
        return _workflow_stage_model_guard(data, tool_input)

    # 0. IRREVERSIBLE + DESTRUCTIVE Bash ops are guarded in EVERY context —
    #    including dispatched subagents (CLAUDE_SUBPROCESS=1) and headless runs.
    #    The recursion-prevention skip below must NOT exempt a subagent from these
    #    guards, or a dispatched agent could bypass the git commit/push/stash blocks
    #    (the 2026-06 self-commit recurrence) OR the destructive-command guard
    #    (rm -rf etc.). Escape hatches still apply — the guards check allow patterns first.
    if tool == "Bash":
        command = tool_input.get("command", "") or ""
        git_guard = _load("cast_git_guard", "cast-git-guard.py")
        if git_guard is not None:
            try:
                # D5a-1: hand the hook payload's identity to the guard (hatch audit events).
                # Best-effort: a failure here must never change the guard verdict.
                if hasattr(git_guard, "set_hook_context"):
                    git_guard.set_hook_context(data)
            except Exception:
                pass
            try:
                gcode, gmsg = _run_under_watchdog(
                    lambda: git_guard.evaluate("Bash", tool_input),
                    _GIT_GUARD_BUDGET_SECS,
                    _GitGuardTimeout,
                )
            except _GitGuardTimeout:
                # The guard ran past its budget (a super-linear scan; a hook TIMEOUT would be
                # an ALLOW) and decided NOTHING: block every command that names git, hatches
                # ignored -- NOT the 8-verb degraded table (see _git_guard_timeout_block).
                # Budget only is logged -- never the command text.
                _log_error(f"Bash git guard timed out after {_GIT_GUARD_BUDGET_SECS:g}s; "
                           f"blocking any command that names git")
                gmsg = _git_guard_timeout_block(command, _GIT_GUARD_BUDGET_SECS)
                gcode = 2 if gmsg else 0
            except Exception as exc:
                # evaluate() RAISED: the guard did not run. Same degraded-mode verdict as a
                # load failure (a coarse irreversible-git block; else allow). The exception
                # CLASS only is logged -- never str(exc), which can carry attacker text.
                _log_error(f"Bash git guard evaluate() raised {type(exc).__name__}; "
                           f"degraded git block")
                gmsg = _degraded_git_block(command, "failed while checking this command")
                gcode = 2 if gmsg else 0
            finally:
                try:
                    if hasattr(git_guard, "clear_hook_context"):
                        git_guard.clear_hook_context()
                except Exception:
                    pass
            if gcode == 2:
                return _block(gmsg)
        else:
            # The guard module failed to LOAD: a coarse irreversible-git list stays
            # blocked (own hatches apply); everything else is allowed so repair works.
            dmsg = _degraded_git_block(command)
            if dmsg:
                return _block(dmsg)
        if command:
            cg = _load("cast_command_guard", "cast-command-guard.py")
            if cg is not None:
                # Under the REMAINING share of the total Bash-guard budget: it is linear but
                # slow on a huge command, and a hook timeout is an ALLOW of rm -rf / pkill.
                cg_budget = max(_COMMAND_GUARD_MIN_BUDGET_SECS,
                                _BASH_GUARD_TOTAL_BUDGET_SECS - (time.monotonic() - t_main))
                try:
                    blocked, message = _run_under_watchdog(
                        lambda: cg.safe_is_blocked(command), cg_budget, _CommandGuardTimeout)
                except _CommandGuardTimeout:
                    _log_error(f"Bash command guard timed out after {cg_budget:.1f}s; blocking")
                    return _block(
                        "**[CAST]** The command guard could not finish checking this command in "
                        "time, so it is blocked. Split it into smaller commands.")
                except Exception:
                    blocked, message = False, ""
                if blocked:
                    # Preserve the standalone guard's BLOCK log side effect.
                    try:
                        cg.write_log(
                            os.path.join(os.path.expanduser("~"), ".claude", "logs",
                                         "command-guard.log"),
                            f"BLOCK: {command}",
                        )
                    except Exception:
                        pass
                    return _block(message)

    # 0.5. Neon MCP unsafe-tool guard -- fires in EVERY context (see
    #      _notify_neon_risk's docstring), same "every context" rule as the
    #      Bash git/kill/rm guards above. Notify + record never hard-block. The
    #      same classification also yields a native `permissionDecision: "ask"`
    #      (neon_reason): a prompt, not a hard block -- exit stays 0 (never 2);
    #      headless / CLAUDE_SUBPROCESS=1 cannot answer it, so there it is
    #      effectively a deny (intended fail-closed). The one JSON
    #      object carrying it is printed by _emit_pretool_output (here for a
    #      subagent, at step 2 for a top-level session).
    neon_action = _notify_neon_risk(tool, tool_input, data)
    neon_reason = _neon_ask_reason(tool, tool_input)

    # Recursion-prevention skip: the REST of the dispatcher (Write/Edit path policy
    # engine + TTL sweep, egress I/O, dispatch_decisions capture) is suppressed for
    # managed/headless sub-claude to avoid hook recursion.
    if os.environ.get("CLAUDE_SUBPROCESS", "0") == "1":
        if neon_reason or neon_action is not None:
            _emit_pretool_output(
                _load("cast_egress_sentinel", "cast-egress-sentinel.py"),
                neon_action, neon_reason,
            )
        return 0

    # 1. Write/Edit path policy (top-level sessions only). A code-0 result may carry a
    #    warn-policy advisory (policy_context): never a block, folded into the single
    #    hookSpecificOutput object printed at step 2.
    policy_context = None
    if tool in ("Write", "Edit"):
        git_guard = _load("cast_git_guard", "cast-git-guard.py")
        if git_guard is not None:
            # The requires_agent gate trusts only completion records bound to THIS
            # payload's session_id; a missing/non-str value is "" (fails closed).
            sid = data.get("session_id")
            try:
                code, msg = git_guard.evaluate(tool, tool_input, sid if isinstance(sid, str) else "")
            except Exception as exc:
                # Write/Edit fails CLOSED (unlike Bash above): the policy gate did not run.
                code, msg = _write_edit_gate_error(
                    git_guard, tool, tool_input, sid if isinstance(sid, str) else "", exc)
            if code == 2:
                return _block(msg)
            if code == 0 and isinstance(msg, str) and msg:
                policy_context = msg
        else:
            # The guard module failed to LOAD: no policy ran -> fail CLOSED.
            code, msg = _write_edit_guard_unavailable(tool)
            if code == 2:
                return _block(msg)

    # 2. EGRESS — record + emit (only reached when nothing hard-blocked; blocked
    #    commands are never off-machine-bound, so no egress record is lost).
    #    Output goes through _emit_pretool_output so a Neon ask and an egress
    #    advisory share ONE JSON object. It is called even for a non-egress tool
    #    name (e.g. an upper-cased "MCP__NEON__...", which _classify_neon_risk
    #    normalises but _is_egress_tool does not) so the ask is never lost.
    sentinel = None
    action = None
    if _is_egress_tool(tool):
        sentinel = _load("cast_egress_sentinel", "cast-egress-sentinel.py")
        if sentinel is not None:
            action = _run_egress(sentinel, data)
    _emit_pretool_output(sentinel, action, neon_reason, policy_context)

    # F2: record the dispatch decision (record-only; NEVER blocks a dispatch).
    # The subagent-dispatch tool is "Agent" in current Claude Code and "Task" in
    # older builds — accept both so capture works across harness versions.
    if tool in ("Task", "Agent"):
        _record_dispatch(data)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except SystemExit:
        raise
    except Exception:
        sys.exit(0)
