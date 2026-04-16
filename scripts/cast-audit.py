#!/usr/bin/env python3
"""
cast-audit.py — CAST audit hook consolidation script.

Reads the PreToolUse hook JSON from stdin in one pass and performs:
  1. Parses tool-specific fields (file_path, command_preview, hashes, etc.)
  2. Builds the JSONL audit record
  3. Appends the record to ~/.claude/logs/audit.jsonl
  4. Runs PII redaction analysis for cloud-bound calls (if enabled)
  5. Annotates the record with redaction metadata
  6. Stores redaction map files
  7. Emits hookSpecificOutput JSON (warning) or block JSON to stdout
  8. Exits 2 to block the tool call in strict+redact_pii mode

Interface:
  stdin  — raw hook JSON (tool_name, tool_input, session_id, etc.)
  stdout — hook output JSON (hookSpecificOutput warning, block decision, or empty)
  stderr — silent (errors are logged to hook-errors.log, never raised)
  env    — CLAUDE_SESSION_ID, CLAUDE_PROJECT_PATH, CAST_PII_ENFORCEMENT
  exit 0 — continue (pass-through)
  exit 2 — block (strict mode + PII detected in cloud-bound call)

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
    project = os.environ.get("CLAUDE_PROJECT_PATH", "")
    if project:
        return os.path.basename(project)
    # Try git remote
    try:
        result = subprocess.run(
            ["git", "remote", "get-url", "origin"],
            capture_output=True, text=True, timeout=3
        )
        if result.returncode == 0:
            url = result.stdout.strip()
            name = url.rstrip("/").split("/")[-1]
            if name.endswith(".git"):
                name = name[:-4]
            if name:
                return name
    except Exception:
        pass
    # Try git toplevel
    try:
        result = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            capture_output=True, text=True, timeout=3
        )
        if result.returncode == 0:
            return os.path.basename(result.stdout.strip())
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
    """Store redaction entity map to ~/.claude/logs/redact-maps/."""
    try:
        os.makedirs(REDACT_MAPS_DIR, exist_ok=True)
        safe_ts = timestamp.replace(":", "-")
        path = os.path.join(REDACT_MAPS_DIR, f"{session_id}-{safe_ts}.json")
        map_data = {
            "timestamp": timestamp,
            "session_id": session_id,
            "entities": redact_result.get("entities", []),
        }
        with open(path, "w") as f:
            json.dump(map_data, f)
    except Exception as e:
        _log_error(f"write_redact_map failed: {e}")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> int:
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
    session_id = os.environ.get("CLAUDE_SESSION_ID", "unknown")
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
                    elif ENFORCEMENT_MODE == "strict" and cfg.get("redact_pii"):
                        # Strict mode: append record before blocking
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
