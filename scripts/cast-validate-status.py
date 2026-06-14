#!/usr/bin/env python3
"""
cast-validate-status.py — Validate a CAST agent Status block JSON against the
agent-status schema without any third-party dependencies.

Interface:
  stdin  — JSON to validate (if no file arg given)
  arg[1] — optional path to JSON file to validate
  --schema <path> — override default schema path (default: schemas/agent-status.json
                    relative to this script's directory)
  stdout — "VALID" on success
  stderr — "INVALID: <reason>" on failure
  exit 0 — valid
  exit 1 — invalid or error

Examples:
  echo '{"status":"DONE","summary":"ok","agent":"code-writer"}' | python3 cast-validate-status.py
  python3 cast-validate-status.py /path/to/status.json
  python3 cast-validate-status.py --schema /custom/schema.json /path/to/status.json
"""

import sys
import json
import os
from typing import Any

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

SCRIPT_DIR = os.path.dirname(os.path.realpath(__file__))
DEFAULT_SCHEMA_PATH = os.path.join(SCRIPT_DIR, "..", "schemas", "agent-status.json")

VALID_STATUSES = {"DONE", "DONE_WITH_CONCERNS", "BLOCKED", "NEEDS_CONTEXT", "APPROVE", "REQUEST_CHANGES"}

# Fields that must be arrays when present
ARRAY_FIELDS = {"concerns", "files_changed", "next_actions", "blockers", "context_needed"}

# Allowed top-level fields (mirrors additionalProperties: false in schema)
ALLOWED_FIELDS = {
    "status", "summary", "agent", "concerns", "files_changed",
    "next_actions", "blockers", "context_needed", "schema_version"
}

# ---------------------------------------------------------------------------
# Error helpers
# ---------------------------------------------------------------------------

def fail(reason: str) -> None:
    """Print structured error to stderr and exit 1."""
    print(f"INVALID: {reason}", file=sys.stderr)
    sys.exit(1)


def invalid_if(condition: bool, reason: str) -> None:
    if condition:
        fail(reason)

# ---------------------------------------------------------------------------
# Validation logic (manual — stdlib only)
# ---------------------------------------------------------------------------

def validate(data: Any) -> None:
    """Validate a parsed JSON value against the agent-status schema rules.

    Raises SystemExit(1) via fail() on the first violation found.
    Returns silently if valid.
    """
    # Must be an object
    if not isinstance(data, dict):
        fail(f"root value must be a JSON object, got {type(data).__name__}")

    # Check for unexpected fields
    extra = set(data.keys()) - ALLOWED_FIELDS
    if extra:
        fail(f"unexpected field(s): {', '.join(sorted(extra))}")

    # --- Required fields ---

    # status
    if "status" not in data:
        fail("missing required field: 'status'")
    status = data["status"]
    if not isinstance(status, str):
        fail(f"'status' must be a string, got {type(status).__name__}")
    if status not in VALID_STATUSES:
        fail(f"'status' must be one of {sorted(VALID_STATUSES)}, got '{status}'")

    # summary
    if "summary" not in data:
        fail("missing required field: 'summary'")
    summary = data["summary"]
    if not isinstance(summary, str):
        fail(f"'summary' must be a string, got {type(summary).__name__}")
    if len(summary) < 1:
        fail("'summary' must not be empty (minLength: 1)")
    if len(summary) > 300:
        fail(f"'summary' exceeds maxLength of 300 characters (got {len(summary)})")

    # agent
    if "agent" not in data:
        fail("missing required field: 'agent'")
    agent = data["agent"]
    if not isinstance(agent, str):
        fail(f"'agent' must be a string, got {type(agent).__name__}")
    if len(agent) < 1:
        fail("'agent' must not be empty (minLength: 1)")

    # --- Optional array fields: type check ---
    for field in ARRAY_FIELDS:
        if field in data:
            val = data[field]
            if not isinstance(val, list):
                fail(f"'{field}' must be an array, got {type(val).__name__}")
            for i, item in enumerate(val):
                if not isinstance(item, str):
                    fail(f"'{field}[{i}]' must be a string, got {type(item).__name__}")
                if len(item) < 1:
                    fail(f"'{field}[{i}]' must not be empty (minLength: 1)")

    # --- schema_version ---
    if "schema_version" in data:
        sv = data["schema_version"]
        if not isinstance(sv, str):
            fail(f"'schema_version' must be a string, got {type(sv).__name__}")
        if sv != "1.0":
            fail(f"'schema_version' must be '1.0', got '{sv}'")

    # --- Conditional requirements ---

    if status == "DONE_WITH_CONCERNS":
        if "concerns" not in data:
            fail("'concerns' is required when status is 'DONE_WITH_CONCERNS'")
        if len(data["concerns"]) < 1:
            fail("'concerns' must have at least one item when status is 'DONE_WITH_CONCERNS'")

    if status == "BLOCKED":
        if "blockers" not in data:
            fail("'blockers' is required when status is 'BLOCKED'")
        if len(data["blockers"]) < 1:
            fail("'blockers' must have at least one item when status is 'BLOCKED'")

    if status == "NEEDS_CONTEXT":
        if "context_needed" not in data:
            fail("'context_needed' is required when status is 'NEEDS_CONTEXT'")
        if len(data["context_needed"]) < 1:
            fail("'context_needed' must have at least one item when status is 'NEEDS_CONTEXT'")

# ---------------------------------------------------------------------------
# Input parsing
# ---------------------------------------------------------------------------

def load_input(args: list[str]) -> Any:
    """Parse CLI args to determine input source, return parsed JSON."""
    schema_path: str | None = None
    positional: list[str] = []

    i = 0
    while i < len(args):
        if args[i] == "--schema" and i + 1 < len(args):
            schema_path = args[i + 1]
            i += 2
        else:
            positional.append(args[i])
            i += 1

    # schema_path is accepted but not used in stdlib validation (schema is
    # hard-coded logic). Kept for interface compatibility / future extension.
    _ = schema_path

    if positional:
        file_path = positional[0]
        try:
            with open(file_path, "r", encoding="utf-8") as fh:
                raw = fh.read()
        except OSError as exc:
            fail(f"cannot read file '{file_path}': {exc}")
    else:
        try:
            raw = sys.stdin.read()
        except Exception as exc:
            fail(f"cannot read stdin: {exc}")

    if not raw or not raw.strip():
        fail("input is empty")

    try:
        return json.loads(raw)
    except json.JSONDecodeError as exc:
        fail(f"input is not valid JSON: {exc}")


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main() -> None:
    args = sys.argv[1:]
    data = load_input(args)
    validate(data)
    print("VALID")


if __name__ == "__main__":
    main()
