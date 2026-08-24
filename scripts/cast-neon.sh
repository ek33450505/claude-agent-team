#!/bin/bash
# cast-neon.sh — fail-closed wrapper for Neon WRITE operations (CAST v10 I-5 Unit B)
#
# The Neon MCP server is wired READ-ONLY (?readonly=true, enforced server-side by
# Neon), so destructive Neon tools are unreachable from the model. Writes route
# through this bash wrapper instead so they land in cast.db and are covered by
# CAST's irreversibility machinery — an MCP tool call has no shell in its path and
# cannot be gated locally; a bash wrapper can.
#
# NOT a hook — no CLAUDE_SUBPROCESS guard needed (same rationale as cast-cheap.sh).
#
# Usage:
#   cast-neon.sh list-projects
#   cast-neon.sh list-branches  <project_id>
#   cast-neon.sh branch-create  <project_id> <branch_name>
#   cast-neon.sh branch-delete  <project_id> <branch_id>     <-- DESTRUCTIVE, gated
#   cast-neon.sh --help
#
# Global flag (may appear anywhere in the argument list):
#   --dry-run   Print the exact request (method, URL, redacted auth) and exit 0
#               WITHOUT calling the network. Exempt from the branch-delete gate
#               below (see the branch-delete case) — a preview never writes an
#               ack_events row either.
#
# Auth: resolves the API key from $NEON_API_KEY, else from macOS Keychain via
# `cast-keychain.sh get neon-api-key`. Fails closed (exit 1, no network call) if
# neither yields a non-empty key. What IS guaranteed: the key is never printed to
# stdout/stderr/logs on any path (--dry-run shows ***REDACTED***), and it is never
# passed to curl as an argv argument — curl receives it via `-K -` (config read
# from stdin) specifically so it cannot be read out of another process's `ps`/
# /proc/<pid>/cmdline snapshot or land in a core dump of curl. What is NOT
# guaranteed: it still exists in this script's own process memory and briefly on
# the pipe between the two bash builtins handing it to curl.
#
# project_id / branch_id validation: both are ids Neon itself issues (its
# documented format is alphanumeric plus hyphen/underscore, e.g.
# "square-mode-12345678", "br-cool-lab-98765432") and both are concatenated
# directly into the request URL path, so they are checked against
# ^[A-Za-z0-9_-]+$ before use — an embedded "/" could otherwise widen or
# redirect which path segment the request actually hits. branch_name is
# deliberately NOT charset-restricted: it is user-chosen (not Neon-issued),
# Neon branch names may legitimately contain characters like "/" (git-style
# names), and it never enters a URL path — it goes into the JSON request body
# via `python3 -c ... json.dumps(...)` with the value passed as argv (never
# interpolated into the program text), so it can't break out of the JSON string
# regardless of its contents.
#
# Read-endpoint response handling: list-projects/list-branches responses are
# printed verbatim. Checked against Neon's documented project/branch object
# schemas (no live fetch performed — no WebFetch/WebSearch tool in this role):
# those objects carry metadata only (name, id, state, timestamps, size/usage
# counters, ...) — no password or connection-URI field. Passwords and
# connection strings live behind separate `connection_uri` and
# `reveal_password` endpoints, which this wrapper does not call. If a future
# subcommand adds either endpoint, this needs redaction before printing.
# Recommend an independent live spot-check if you want this fully confirmed.
#
# Escape hatch (branch-delete only, real runs — NOT --dry-run, see below):
# CAST_NEON_BRANCH_DELETE_OK must equal the LITERAL string "1" — "true"/"yes"/
# "10"/etc. do NOT satisfy it (this literal-1 convention is deliberate and
# shared across CAST's escape hatches). Each real use is passed to
# cast_ack.py, best-effort (`|| true`), before the delete proceeds — but that
# call can itself fail silently (e.g. a db_write error), in which case the
# delete still happens with no CAST-side record of the bypass. Recording is
# not a guarantee, only an attempt.
#
# There is no `reset` subcommand: Neon's v2 REST API has no documented
# reset-to-parent endpoint (POST .../restore is snapshot restore, a different
# operation, and out of scope). There is no project-delete subcommand either —
# blast radius is an entire project; not requested, not built (YAGNI).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NEON_API_BASE="https://console.neon.tech/api/v2"

usage() {
  cat <<'USAGE'
Usage: cast-neon.sh [--dry-run] <command> [args]

Commands:
  list-projects                              List Neon projects
  list-branches  <project_id>                List branches for a project
  branch-create  <project_id> <branch_name>  Create a branch
  branch-delete  <project_id> <branch_id>    Delete a branch (DESTRUCTIVE, gated)
  --help                                     Show this help

Global flags:
  --dry-run   Print the exact request and exit 0 without calling the network.
              (May appear anywhere in the argument list. Exempt from the
              branch-delete escape hatch below — a preview needs no hatch.)

Auth: $NEON_API_KEY, else `cast-keychain.sh get neon-api-key`.

branch-delete requires CAST_NEON_BRANCH_DELETE_OK=1 (the literal string "1")
for a real run; --dry-run branch-delete does not require it.
USAGE
}

_err() {
  echo "cast-neon.sh: $*" >&2
}

# project_id/branch_id are Neon-issued and URL-path-bound — validate before
# use (see header comment for why branch_name is excluded from this check).
_validate_id() {
  local value="$1"
  local label="$2"
  if [[ ! "$value" =~ ^[A-Za-z0-9_-]+$ ]]; then
    _err "invalid ${label}: \"${value}\" — must match ^[A-Za-z0-9_-]+\$ (an embedded \"/\" could otherwise widen the request's URL path)"
    exit 1
  fi
}

# --- arg parsing (--dry-run may appear anywhere) -------------------------
DRY_RUN=0
ARGS=()
for arg in "$@"; do
  if [[ "$arg" == "--dry-run" ]]; then
    DRY_RUN=1
  else
    ARGS+=("$arg")
  fi
done
set -- "${ARGS[@]+"${ARGS[@]}"}"

CMD="${1:-}"

if [[ -z "$CMD" ]]; then
  usage
  exit 1
fi

if [[ "$CMD" == "--help" || "$CMD" == "-h" ]]; then
  usage
  exit 0
fi

# --- auth resolution (fail-closed; see header comment for what is/isn't protected) --
resolve_api_key() {
  if [[ -n "${NEON_API_KEY:-}" ]]; then
    printf '%s' "$NEON_API_KEY"
    return 0
  fi

  local from_keychain=""
  # gitleaks:allow — "neon-api-key" is the Keychain SERVICE NAME, not a secret value.
  from_keychain="$(bash "$SCRIPT_DIR/cast-keychain.sh" get neon-api-key 2>/dev/null || true)" # gitleaks:allow
  if [[ -n "$from_keychain" ]]; then
    printf '%s' "$from_keychain"
    return 0
  fi

  return 1
}

NEON_API_KEY_RESOLVED=""
if ! NEON_API_KEY_RESOLVED="$(resolve_api_key)"; then
  _err "no Neon API key found. Set \$NEON_API_KEY, or store one via: cast-keychain.sh set neon-api-key <key>"
  exit 1
fi
if [[ -z "$NEON_API_KEY_RESOLVED" ]]; then
  _err "no Neon API key found. Set \$NEON_API_KEY, or store one via: cast-keychain.sh set neon-api-key <key>"
  exit 1
fi

# --- request execution ------------------------------------------------
# $1=method $2=path $3=optional JSON body. Handles --dry-run internally so
# every command gets identical dry-run behavior for free.
_do_request() {
  local method="$1"
  local path="$2"
  local body="${3:-}"
  local url="${NEON_API_BASE}${path}"

  if [[ "$DRY_RUN" == "1" ]]; then
    echo "[dry-run] $method $url"
    echo "[dry-run] Authorization: Bearer ***REDACTED***"
    if [[ -n "$body" ]]; then
      echo "[dry-run] body: $body"
    fi
    exit 0
  fi

  local curl_args=(-sS -X "$method" "$url" -H "Content-Type: application/json")
  if [[ -n "$body" ]]; then
    curl_args+=(-d "$body")
  fi

  # Authorization header is supplied via curl's -K (config-from-stdin), not
  # -H, so the key is never a curl argv argument (see header comment). Both
  # `printf` here and the resolve step above rely on the bash BUILTIN printf
  # (not /usr/bin/printf) — the builtin runs in-process/in-subshell without
  # an exec(), so the key never appears as a separate process's argv either.
  local response=""
  local rc=0
  set +e
  response="$(printf 'header = "Authorization: Bearer %s"\n' "$NEON_API_KEY_RESOLVED" | curl -K - "${curl_args[@]}" 2>&1)"
  rc=$?
  set -e
  if [[ "$rc" -ne 0 ]]; then
    _err "request failed (curl exit $rc)"
    exit 1
  fi
  # Response is printed verbatim — see header comment: checked against
  # Neon's documented schema (not live-fetched), no secret fields on these
  # two read endpoints.
  echo "$response"
}

case "$CMD" in
  list-projects)
    _do_request GET "/projects"
    ;;

  list-branches)
    PROJECT_ID="${2:-}"
    if [[ -z "$PROJECT_ID" ]]; then
      _err "list-branches requires <project_id>"
      exit 1
    fi
    _validate_id "$PROJECT_ID" "project_id"
    _do_request GET "/projects/${PROJECT_ID}/branches"
    ;;

  branch-create)
    PROJECT_ID="${2:-}"
    BRANCH_NAME="${3:-}"
    if [[ -z "$PROJECT_ID" || -z "$BRANCH_NAME" ]]; then
      _err "branch-create requires <project_id> <branch_name>"
      exit 1
    fi
    _validate_id "$PROJECT_ID" "project_id"
    # BRANCH_NAME is passed as argv (sys.argv[1]), never interpolated into
    # the python program text, and json.dumps handles all escaping — a
    # branch name containing a double-quote (or anything else) cannot break
    # out of the JSON string or inject sibling keys into the request body.
    BODY="$(python3 -c 'import json, sys; print(json.dumps({"branch": {"name": sys.argv[1]}}))' "$BRANCH_NAME")"
    _do_request POST "/projects/${PROJECT_ID}/branches" "$BODY"
    ;;

  branch-delete)
    PROJECT_ID="${2:-}"
    BRANCH_ID="${3:-}"
    if [[ -z "$PROJECT_ID" || -z "$BRANCH_ID" ]]; then
      _err "branch-delete requires <project_id> <branch_id>"
      exit 1
    fi
    _validate_id "$PROJECT_ID" "project_id"
    _validate_id "$BRANCH_ID" "branch_id"

    if [[ "$DRY_RUN" != "1" ]]; then
      # Fail-closed: literal "1" only. --dry-run is exempt (see header
      # comment) — requiring the hatch just to PREVIEW the request would
      # force arming a destructive op in order to look at it, and an
      # exported hatch var then persists into the next command. Same
      # precedent CAST already applies elsewhere: git-prune's -n/--dry-run
      # is unaffected by its gate (docs/architecture/cast-protocol-spec.md
      # §2.5), and scripts/cast-git-guard.py:383-384 records a 2026-08-17
      # review finding that an over-eager block "would have blocked it,
      # training people to reach for the hatch reflexively."
      if [[ "${CAST_NEON_BRANCH_DELETE_OK:-}" != "1" ]]; then
        _err "branch-delete blocked. Set CAST_NEON_BRANCH_DELETE_OK=1 (the literal string \"1\") to proceed. (--dry-run does not require this.)"
        exit 1
      fi

      # Record the bypass BEFORE performing the delete. Best-effort per
      # cast_ack.py's contract (always exits 0) — see header comment: this
      # can silently fail to record while still allowing the delete.
      python3 "$SCRIPT_DIR/cast_ack.py" CAST_NEON_BRANCH_DELETE_OK --script cast-neon.sh || true
    fi

    _do_request DELETE "/projects/${PROJECT_ID}/branches/${BRANCH_ID}"
    ;;

  *)
    _err "unknown command: $CMD"
    usage
    exit 1
    ;;
esac
