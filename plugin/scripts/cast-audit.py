#!/usr/bin/env python3
"""
cast-audit.py — CAST audit hook consolidation script.

Reads the hook JSON from stdin in one pass and performs:
  1. Parses tool-specific fields (file_path, command_preview, hashes, etc.)
  2. Builds the JSONL audit record
  3. Appends the record to ~/.claude/logs/audit.jsonl
  4. Runs PII redaction analysis for cloud-bound calls (if enabled)
  5. Annotates the record with redaction metadata
  6. Stores redaction map files
  7. Emits hookSpecificOutput JSON (warning) or block JSON to stdout
  8. Exits 2 to block the tool call in strict+redact_pii mode (pre mode only)

Usage:
  cast-audit.py [--mode pre|post]

  --mode pre  (default) PreToolUse: can exit 2 to block cloud-bound calls
              with PII when CAST_PII_ENFORCEMENT=strict. Intended for
              WebFetch|WebSearch matcher only.
  --mode post PostToolUse: audit-log-only path. Never exits 2. Intended as
              async catch-all logger for all tool events.

Interface:
  stdin  — raw hook JSON (tool_name, tool_input, session_id, etc.)
  stdout — hook output JSON (hookSpecificOutput warning, block decision, or empty)
  stderr — silent (errors are logged to hook-errors.log, never raised)
  env    — CLAUDE_SESSION_ID, CLAUDE_PROJECT_PATH, CLAUDE_PROJECT_DIR,
           CAST_PII_ENFORCEMENT
  exit 0 — continue (pass-through)
  exit 2 — block (strict mode + PII detected in cloud-bound call; pre mode only)

Never crashes — all errors are caught and logged silently.
"""
import sys
import json
import os
import hashlib
import subprocess
from datetime import datetime, timezone

# ---------------------------------------------------------------------------
# Constants / paths
# ---------------------------------------------------------------------------
HOME = os.path.expanduser("~")
CAST_DB_PATH = os.environ.get("CAST_DB_PATH", os.path.join(HOME, ".claude", "cast.db"))
AUDIT_LOG = os.path.join(HOME, ".claude", "logs", "audit.jsonl")
ERROR_LOG = os.path.join(HOME, ".claude", "logs", "hook-errors.log")
REDACT_MAPS_DIR = os.path.join(HOME, ".claude", "logs", "redact-maps")
CAST_CLI_CFG = os.path.join(HOME, ".claude", "config", "cast-cli.json")
REDACT_SCRIPT = os.path.join(HOME, ".claude", "scripts", "cast-redact.py")
CLAUDE_DIR = os.environ.get("CLAUDE_DIR", os.path.join(HOME, ".claude"))
# Policy data: prefer repo cwd (dev), fall back to installed ~/.claude — same
# candidate order as scripts/cast-egress-sentinel.py:53-56, the canonical
# reader of this file.
EGRESS_POLICY_CANDIDATES = [
    os.path.join(os.getcwd(), "config", "egress-policy.json"),
    os.path.join(CLAUDE_DIR, "config", "egress-policy.json"),
]

ENFORCEMENT_MODE = os.environ.get("CAST_PII_ENFORCEMENT", "advisory")

SAFELIST_PATTERNS = [
    "anthropic.com",
    "github.com",
    "example.com",
    "example.org",
    "noreply@",
    "user@example",
    "@anthropic",
    "claude.ai",
    "docs.anthropic",
]

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _log_error(msg: str) -> None:
    try:
        os.makedirs(os.path.dirname(ERROR_LOG), exist_ok=True)
        ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        with open(ERROR_LOG, "a") as f:
            f.write(f"[{ts}] ERROR cast-audit.py: {msg}\n")
    except Exception:
        pass


def _now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _sha256(text: str) -> str:
    return hashlib.sha256(text.encode()).hexdigest()


def _read_cast_cli_cfg() -> dict:
    """Read ~/.claude/config/cast-cli.json, return {} on any failure."""
    try:
        with open(CAST_CLI_CFG) as f:
            return json.load(f)
    except Exception:
        return {}


def _safelist_match(text: str) -> bool:
    lowered = text.lower()
    return any(p in lowered for p in SAFELIST_PATTERNS)


# ---------------------------------------------------------------------------
# MCP observability helpers
# ---------------------------------------------------------------------------

def _mcp_type_desc(value) -> str:
    """Describe a value's shape only — never its content."""
    if isinstance(value, bool):
        return "bool"
    if isinstance(value, str):
        return f"str({len(value)})"
    if isinstance(value, int):
        return "int"
    if isinstance(value, float):
        return "float"
    if isinstance(value, dict):
        return f"dict({len(value)})"
    if isinstance(value, list):
        return f"list({len(value)})"
    if value is None:
        return "null"
    return type(value).__name__


def _mcp_args_summary(tool_input: dict) -> str:
    """Redaction-by-construction: comma-joined, key-sorted `key:type(len)` pairs.

    MCP args can carry credentials, tokens, and account IDs — this must build a
    string that is structurally incapable of containing a value, not merely one
    that has been filtered. Never raises; unusable input yields "".
    """
    try:
        if not isinstance(tool_input, dict):
            return ""
        parts = [f"{k}:{_mcp_type_desc(tool_input[k])}" for k in sorted(tool_input.keys())]
        return ",".join(parts)[:200]
    except Exception:
        return ""


def _load_egress_policy() -> dict:
    """Load config/egress-policy.json via EGRESS_POLICY_CANDIDATES (same order
    as scripts/cast-egress-sentinel.py's _load_policy(), lines 76-84). Returns
    {} on any failure — never raises.

    Logs to hook-errors.log on failure (matching the sentinel's own
    _log_error() call) so a missing/malformed policy is VISIBLE. Without
    this, every MCP call silently falls through to the fail-safe
    is_cloud_bound=True — the correct safe VALUE, but indistinguishable from
    a working classifier that correctly found the server cloud-bound. The
    safe value does not change here; only its visibility does.
    """
    found_any = False
    for path in EGRESS_POLICY_CANDIDATES:
        try:
            if os.path.isfile(path):
                found_any = True
                with open(path) as f:
                    return json.load(f)
        except Exception as e:
            _log_error(f"egress policy load failed ({path}): {e}")
    if not found_any:
        _log_error(f"egress policy not found in any candidate path: {EGRESS_POLICY_CANDIDATES}")
    return {}


def _mcp_is_cloud_bound(server: str) -> bool:
    """Classify from CAST's CANONICAL egress policy
    (config/egress-policy.json -> mcp_servers), matching the semantics of
    scripts/cast-egress-sentinel.py:153-158 EXACTLY.

    Transport (stdio vs http) is NOT a reliable signal and must NOT be
    consulted here — the policy file's own _doc says why: github uses local
    stdio (npx) yet calls api.github.com. The transport-based version of this
    function got exactly that case wrong (confidently returned False for a
    server that does leave the machine); the policy file is the single
    source of truth CAST already maintains for this classification.

    server in local_only  -> False
    server in cloud_bound -> True
    otherwise (unknown)   -> True (honors the policy's _default_unknown,
                              currently "cloud_bound" — the sentinel's own
                              reader hardcodes this same unknown-is-cloud-
                              bound behavior rather than re-deriving it, so
                              this matches it exactly rather than reading
                              _default_unknown dynamically)

    Fail-safe: ANY failure (missing file, malformed JSON, missing key)
    -> True. This is a RECORD/OBSERVABILITY field only — see the note where
    it's set in parse_tool_fields().
    """
    if not server:
        return True
    try:
        mcp = _load_egress_policy().get("mcp_servers", {})
        if server in mcp.get("local_only", []):
            return False
        return True
    except Exception:
        return True


def _sanitize_error_text(text: str):
    """Redact PII/secrets from provider-controlled MCP error text before it is
    ever persisted. Both the routing_events (cast.db) and audit.jsonl writes
    are UNCONDITIONAL for MCP calls, so sanitization must be too — never gate
    this on cfg.get("redact_pii") or on is_cloud_bound. An upstream auth
    failure can echo a token straight back via `error`/`isError` content, and
    truncation alone is not redaction: a GitHub PAT (~40 chars) or an AWS key
    (20 chars) both fit inside the 120-char preview cap.

    Loads cast-redact.py's own regex engine directly via importlib (the
    hyphenated filename can't be `import`ed as a normal module) — same engine
    choice cast-redact.py makes for its own hook path (see cast-redact.py:319,
    "no Presidio startup cost in hook path").

    FAILS CLOSED: returns None on ANY failure (missing file, import error,
    regex error) so the caller drops the text entirely rather than storing
    raw, unredacted content. Never raises.
    """
    try:
        if not os.path.isfile(REDACT_SCRIPT):
            return None
        import importlib.util
        spec = importlib.util.spec_from_file_location("cast_redact_lazy", REDACT_SCRIPT)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        entities = module.analyze_regex(text, [])
        return module.redact_regex(text, entities, "redact")
    except Exception:
        return None


def _mcp_outcome(tool_response) -> tuple:
    """Derive (outcome, error_preview, result_size) from tool_response.

    tool_response may be a dict, a string, a list of content blocks, or missing
    entirely — handle all shapes without raising. error_preview is sanitized
    via _sanitize_error_text() BEFORE truncation — see that function's
    docstring for why (fail-closed: sanitization failure drops the preview
    entirely rather than ever persisting raw text).
    """
    if tool_response is None:
        return "ok", "", 0

    is_error = False
    error_text = ""
    try:
        if isinstance(tool_response, dict):
            if tool_response.get("error"):
                is_error = True
                error_text = str(tool_response.get("error"))
            if tool_response.get("isError"):
                is_error = True
                if not error_text:
                    error_text = json.dumps(tool_response, default=str)
        elif isinstance(tool_response, list):
            for block in tool_response:
                if isinstance(block, dict) and (block.get("isError") or block.get("type") == "error"):
                    is_error = True
                    error_text = str(block.get("text") or block.get("error") or "")
                    break
    except Exception:
        pass

    try:
        result_size = len(json.dumps(tool_response, default=str))
    except Exception:
        try:
            result_size = len(str(tool_response))
        except Exception:
            result_size = 0

    outcome = "error" if is_error else "ok"
    error_preview = ""
    if is_error and error_text:
        sanitized = _sanitize_error_text(error_text)
        if sanitized is not None:
            error_preview = sanitized[:120]
    return outcome, error_preview, result_size


# ---------------------------------------------------------------------------
# Step 1: Parse tool-specific fields
# ---------------------------------------------------------------------------

def parse_tool_fields(data: dict) -> dict:
    tool_name = data.get("tool_name", "")
    tool_input = data.get("tool_input", {}) or {}

    result = {
        "tool_name": tool_name,
        "file_path": "",
        "command_preview": "",
        "command_hash": "",
        "content_hash": "",
        "url": "",
        "query": "",
        "is_cloud_bound": False,
    }

    if tool_name in ("Write", "Edit", "Read", "NotebookEdit", "NotebookRead"):
        result["file_path"] = (
            tool_input.get("file_path")
            or tool_input.get("notebook_path")
            or tool_input.get("path")
            or ""
        )
        content = tool_input.get("content") or tool_input.get("new_string") or ""
        if content:
            result["content_hash"] = _sha256(content)

    elif tool_name == "Bash":
        cmd = tool_input.get("command", "") or ""
        result["command_preview"] = cmd[:80].replace("\n", " ").strip()
        if cmd:
            result["command_hash"] = _sha256(cmd)

    elif tool_name == "WebFetch":
        result["url"] = tool_input.get("url", "") or ""
        result["is_cloud_bound"] = True

    elif tool_name == "WebSearch":
        result["query"] = (tool_input.get("query") or tool_input.get("q") or "")[:120]
        result["is_cloud_bound"] = True

    elif tool_name == "Glob":
        result["query"] = tool_input.get("pattern", "") or ""

    elif tool_name == "Grep":
        result["query"] = (tool_input.get("pattern", "") or "")[:80]
        result["file_path"] = tool_input.get("path", "") or ""

    elif tool_name.startswith("mcp__"):
        # Format is mcp__<server>__<tool> — split on the DOUBLE underscore
        # delimiter only; server/tool names may legitimately contain hyphens
        # (e.g. mcp__cloudflare-graphql__graphql_query).
        parts = tool_name.split("__")
        result["mcp_server"] = parts[1] if len(parts) >= 2 else ""
        result["mcp_tool"] = "__".join(parts[2:]) if len(parts) >= 3 else ""
        result["args_summary"] = _mcp_args_summary(tool_input)
        # NOTE: for MCP, is_cloud_bound is a RECORD/OBSERVABILITY field only —
        # it answers "which MCP calls left the machine" when querying
        # routing_events. It does NOT gate the PII redaction/blocking path in
        # main() below: that path keys off `redact_text`, built from
        # url/query/command_preview — none of which this branch sets — so it
        # is unreachable for MCP calls regardless of is_cloud_bound. There is
        # nothing left for it to redact anyway: args_summary is value-free by
        # construction and error_preview is sanitized at the source (see
        # _sanitize_error_text). Do not assume this flag enforces anything.
        # Derived from CAST's canonical egress policy (config/egress-
        # policy.json), NOT from MCP transport type — see _mcp_is_cloud_bound's
        # docstring for why transport is not a reliable signal here.
        result["is_cloud_bound"] = _mcp_is_cloud_bound(result["mcp_server"])
        outcome, error_preview, result_size = _mcp_outcome(data.get("tool_response"))
        result["outcome"] = outcome
        if error_preview:
            result["error_preview"] = error_preview
        result["result_size"] = result_size

    # Catch-all fingerprint of the full tool_input
    input_str = json.dumps(tool_input, sort_keys=True)
    result["input_hash"] = _sha256(input_str)[:16]

    return result


# ---------------------------------------------------------------------------
# Step 2: Build JSONL audit record
# ---------------------------------------------------------------------------

def build_record(parsed: dict, timestamp: str, session_id: str, project: str) -> dict:
    record = {
        "timestamp": timestamp,
        "session_id": session_id,
        "project": project,
    }
    record.update(parsed)
    # Omit empty-string values to keep each log line compact
    return {k: v for k, v in record.items() if v != ""}


# ---------------------------------------------------------------------------
# Step 3: Resolve project name
# ---------------------------------------------------------------------------

def resolve_project() -> str:
    # Prefer CLAUDE_PROJECT_DIR (provided by Claude Code to hooks) — no subprocess
    for env_key in ("CLAUDE_PROJECT_DIR", "CLAUDE_PROJECT_PATH"):
        val = os.environ.get(env_key, "")
        if val:
            return os.path.basename(val.rstrip("/"))
    # Cheap memoization: cache result in a temp file keyed by cwd so we pay
    # the git subprocess cost at most once per working directory per session.
    try:
        cwd = os.getcwd()
        import tempfile
        cache_key = hashlib.sha256(cwd.encode()).hexdigest()[:16]
        cache_path = os.path.join(tempfile.gettempdir(), f"cast-audit-project-{cache_key}.txt")
        if os.path.isfile(cache_path):
            cached = open(cache_path).read().strip()
            if cached:
                return cached
    except Exception:
        cache_path = ""
        cwd = ""
    # Try git toplevel (single cheap subprocess — no network)
    try:
        result = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            capture_output=True, text=True, timeout=3
        )
        if result.returncode == 0:
            name = os.path.basename(result.stdout.strip())
            if name and cache_path:
                try:
                    with open(cache_path, "w") as f:
                        f.write(name)
                except Exception:
                    pass
            return name
    except Exception:
        pass
    return ""


# ---------------------------------------------------------------------------
# Step 4: PII redaction analysis
# ---------------------------------------------------------------------------

def run_redact_analysis(text: str) -> dict:
    """Run cast-redact.py in analyze mode. Returns parsed JSON or {} on failure."""
    if not os.path.isfile(REDACT_SCRIPT):
        return {}
    try:
        result = subprocess.run(
            ["python3", REDACT_SCRIPT, "--text", text, "--mode", "analyze"],
            capture_output=True, text=True, timeout=10
        )
        if result.returncode == 0 and result.stdout.strip():
            return json.loads(result.stdout.strip())
    except Exception as e:
        _log_error(f"redact analysis failed: {e}")
    return {}


def write_redact_map(session_id: str, timestamp: str, redact_result: dict) -> None:
    """Store redaction entity map to ~/.claude/logs/redact-maps/.

    Strips the plaintext `original` field from each entity before writing —
    only entity_type/start/end/score/original_hash are persisted. original_hash
    is what correlation needs; the raw matched text must never touch disk.
    Entities that aren't dicts (malformed input) are skipped rather than
    raising, and entities missing expected keys are written with whatever
    keys they do have.
    """
    try:
        os.makedirs(REDACT_MAPS_DIR, exist_ok=True)
        safe_ts = timestamp.replace(":", "-")
        path = os.path.join(REDACT_MAPS_DIR, f"{session_id}-{safe_ts}.json")
        raw_entities = redact_result.get("entities", []) or []
        entities = [
            {k: v for k, v in e.items() if k != "original"}
            for e in raw_entities
            if isinstance(e, dict)
        ]
        map_data = {
            "timestamp": timestamp,
            "session_id": session_id,
            "entities": entities,
        }
        with open(path, "w") as f:
            json.dump(map_data, f)
    except Exception as e:
        _log_error(f"write_redact_map failed: {e}")


def write_mcp_routing_event(record: dict, session_id: str, timestamp: str, project: str) -> None:
    """Persist an MCP tool call to routing_events (cast.db).

    audit.jsonl rotates through 5 files (~12 days) and is then gone — this is
    the durable record for MCP observability. MCP-only; caller must gate this.
    Fail-soft: never raises, never crashes the hook pipeline. db_write swallows
    its own errors silently, so callers that need certainty must SELECT the row
    back — this function does not (fire-and-forget, matching cast-post-tool.py).
    """
    try:
        from cast_db import db_write
        db_write("routing_events", {
            "session_id": session_id,
            "timestamp": timestamp,
            "event_type": "mcp_tool_call",
            "project": project,
            "data": json.dumps(record, separators=(",", ":")),
        })
    except Exception as e:
        _log_error(f"write_mcp_routing_event failed: {e}")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> int:
    # Parse --mode pre|post argument
    # pre  (default): PreToolUse — may exit 2 to block cloud-bound PII calls
    # post          : PostToolUse — audit-log only, never exits 2
    mode = "pre"
    args = sys.argv[1:]
    if "--mode" in args:
        idx = args.index("--mode")
        if idx + 1 < len(args):
            mode = args[idx + 1]
    if mode not in ("pre", "post"):
        mode = "pre"

    # Read stdin once
    try:
        raw = sys.stdin.read()
    except Exception:
        raw = ""

    if not raw.strip():
        return 0

    try:
        data = json.loads(raw)
    except Exception:
        _log_error("invalid JSON on stdin")
        return 0

    timestamp = _now_iso()
    session_id = data.get("session_id") or os.environ.get("CLAUDE_SESSION_ID") or "unknown"
    project = resolve_project()

    # Parse tool fields
    try:
        parsed = parse_tool_fields(data)
    except Exception as e:
        _log_error(f"parse_tool_fields failed: {e}")
        parsed = {
            "tool_name": data.get("tool_name", "unknown"),
            "is_cloud_bound": False,
            "input_hash": "",
        }

    # Build JSONL record
    try:
        record = build_record(parsed, timestamp, session_id, project)
    except Exception as e:
        _log_error(f"build_record failed: {e}")
        record = {
            "timestamp": timestamp,
            "session_id": session_id,
            "project": project,
            "tool_name": parsed.get("tool_name", "unknown"),
        }

    # PII redaction (cloud-bound calls only)
    hook_output = None
    exit_code = 0

    if parsed.get("is_cloud_bound"):
        cfg = _read_cast_cli_cfg()
        redact_enabled = bool(cfg.get("redact_pii"))

        if redact_enabled:
            # Extract relevant text
            redact_text = (
                parsed.get("url")
                or parsed.get("query")
                or parsed.get("command_preview")
                or ""
            )[:500]

            if redact_text:
                redact_result = run_redact_analysis(redact_text)
                entity_count = int(redact_result.get("entity_count", 0))

                if entity_count > 0:
                    # Annotate record
                    record["redacted"] = True
                    record["redacted_count"] = entity_count

                    # Write redaction map
                    write_redact_map(session_id, timestamp, redact_result)

                    # Check safelist
                    safelist_matched = _safelist_match(redact_text)

                    if safelist_matched:
                        # Log advisory only — never block
                        try:
                            pii_log = os.path.join(HOME, ".claude", "logs", "pii-advisory.log")
                            with open(pii_log, "a") as f:
                                f.write(
                                    f"[{timestamp}] PII-ADVISORY cast-audit.py: "
                                    f"safelist match, skipping enforcement. "
                                    f"Text preview: {redact_text[:100]}\n"
                                )
                        except Exception:
                            pass
                    elif mode == "pre" and ENFORCEMENT_MODE == "strict" and cfg.get("redact_pii"):
                        # Strict pre-tool mode: append record before blocking
                        try:
                            os.makedirs(os.path.dirname(AUDIT_LOG), exist_ok=True)
                            with open(AUDIT_LOG, "a") as f:
                                f.write(json.dumps(record, separators=(",", ":")) + "\n")
                        except Exception as e:
                            _log_error(f"audit log write failed (pre-block): {e}")

                        hook_output = json.dumps({
                            "decision": "block",
                            "reason": (
                                f"[CAST-PII-BLOCK] {entity_count} PII entities detected "
                                f"in cloud-bound tool call. Tool execution blocked. "
                                f"Set CAST_PII_ENFORCEMENT=advisory to disable blocking."
                            ),
                        })
                        print(hook_output)
                        return 2
                    else:
                        # Advisory mode: warn but allow
                        try:
                            pii_log = os.path.join(HOME, ".claude", "logs", "pii-advisory.log")
                            with open(pii_log, "a") as f:
                                f.write(
                                    f"[{timestamp}] PII-ADVISORY cast-audit.py: "
                                    f"{entity_count} entities detected (advisory mode). "
                                    f"Text preview: {redact_text[:100]}\n"
                                )
                        except Exception:
                            pass

                        hook_output = json.dumps({
                            "hookSpecificOutput": {
                                "hookEventName": "PreToolUse",
                                "additionalContext": (
                                    f"[CAST-REDACT-WARN: {entity_count} PII entities detected "
                                    f"in cloud-bound tool call. Audit record annotated. "
                                    f"Set CAST_PII_ENFORCEMENT=strict to enable blocking.]"
                                ),
                            }
                        })
                        print(hook_output)

    # Persist MCP tool calls to routing_events. Gated to mcp__* only — this
    # hook fires on every Bash/Edit/Write/etc. call with timeout: 3, and a DB
    # write on that hot path is unacceptable. MCP calls are rare by comparison.
    # Runs AFTER the redaction block (not before it) so the durable cast.db
    # copy is built from the exact same final `record` as the audit.jsonl
    # copy below — never a snapshot taken before redaction annotated it.
    if parsed.get("tool_name", "").startswith("mcp__"):
        write_mcp_routing_event(record, session_id, timestamp, project)

    # Append to audit log
    try:
        os.makedirs(os.path.dirname(AUDIT_LOG), exist_ok=True)
        with open(AUDIT_LOG, "a") as f:
            f.write(json.dumps(record, separators=(",", ":")) + "\n")
    except Exception as e:
        _log_error(f"audit log write failed: {e}")

    return exit_code


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as e:
        try:
            _log_error(f"unhandled exception: {e}")
        except Exception:
            pass
        sys.exit(0)
