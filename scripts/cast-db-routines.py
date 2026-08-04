#!/usr/bin/env python3
"""
cast-db-routines.py — CLI for reading and writing the CAST routines table.

Subcommands:
  list                List all routines (name, trigger_type, enabled, last_run_status).
  status [name]       Show detailed status for all routines, or a single named routine.
  get <name>          Return a single routine record as JSON.
  upsert              Upsert a routine record from a JSON blob on stdin.
  update-status       Update last_run_at, last_run_status, last_run_output_path for a routine.

All subcommands write JSON to stdout. Errors go to stderr. Exit 0 on success, 1 on error.
"""
from __future__ import annotations

import sys
import os
import json
import sqlite3
import logging
from datetime import datetime, timezone

# cast_db is co-located in scripts/ — import guardedly for hook failure logging.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
try:
    from cast_db import log_hook_failure as _log_hook_failure
except Exception:
    _log_hook_failure = None


def _maybe_log_failure(hook: str, code: int, msg: str) -> None:
    if _log_hook_failure:
        try:
            _log_hook_failure(hook, code, msg)
        except Exception:
            pass


# ---------------------------------------------------------------------------
# Path validation
# ---------------------------------------------------------------------------
ALLOWED_OUTPUT_PREFIX = os.path.realpath(os.path.expanduser("~/.claude/routines-output"))


def _validate_output_path(path: str, command: str) -> str | None:
    """Return an error message string if path is outside ALLOWED_OUTPUT_PREFIX, else None."""
    resolved = os.path.realpath(os.path.expanduser(path))
    if not (resolved == ALLOWED_OUTPUT_PREFIX or resolved.startswith(ALLOWED_OUTPUT_PREFIX + os.sep)):
        msg = f"path rejected: {path}"
        _maybe_log_failure(f"cast-db-routines:{command}", -3, msg)
        return f"output_path must be under {ALLOWED_OUTPUT_PREFIX}"
    return None


# ---------------------------------------------------------------------------
# Logging setup
# ---------------------------------------------------------------------------
LOG_PATH = os.path.expanduser("~/.claude/logs/cast-db-routines.log")

def _setup_logging() -> None:
    os.makedirs(os.path.dirname(LOG_PATH), exist_ok=True)
    logging.basicConfig(
        filename=LOG_PATH,
        level=logging.ERROR,
        format="%(asctime)s %(levelname)s %(message)s",
    )

# ---------------------------------------------------------------------------
# DB path
# ---------------------------------------------------------------------------
DB_PATH = os.environ.get("CAST_DB_PATH", os.path.expanduser("~/.claude/cast.db"))

# Defensive cap for the unfiltered "list all routines" read in cmd_status.
# routines is a small, admin-registered table (one row per named scheduled
# routine — currently 0 live), so this is generous headroom, not a page size.
_MAX_ROUTINES = 1000


def _connect() -> sqlite3.Connection:
    """Return a sqlite3 connection with row_factory set."""
    conn = sqlite3.connect(DB_PATH, timeout=5)
    conn.row_factory = sqlite3.Row
    return conn


def _table_exists(conn: sqlite3.Connection) -> bool:
    row = conn.execute(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='routines'"
    ).fetchone()
    return row is not None


def _row_to_dict(row) -> dict:
    return dict(row)


# ---------------------------------------------------------------------------
# Subcommand: list
# ---------------------------------------------------------------------------
def cmd_list(args: list) -> int:
    try:
        conn = _connect()
    except sqlite3.Error as e:
        logging.error(f"DB connect error in list: {e}")
        print(json.dumps({"error": str(e)}))
        return 1

    try:
        if not _table_exists(conn):
            print(json.dumps([]))
            print("(routines table not yet initialized — run: cast migrate)", file=sys.stderr)
            return 0

        rows = conn.execute(
            "SELECT name, trigger_type, trigger_value, agent_to_dispatch, enabled, last_run_at, last_run_status "
            "FROM routines ORDER BY name ASC"
        ).fetchall()

        result = [_row_to_dict(r) for r in rows]
        print(json.dumps(result, indent=2))
        return 0
    except sqlite3.OperationalError as e:
        logging.error(f"OperationalError in list: {e}")
        print(json.dumps({"error": str(e)}))
        return 1
    except Exception as e:
        logging.error(f"Unexpected error in list: {e}")
        print(json.dumps({"error": str(e)}))
        return 1
    finally:
        conn.close()


# ---------------------------------------------------------------------------
# Subcommand: status
# ---------------------------------------------------------------------------
def cmd_status(args: list) -> int:
    name_filter = args[0] if args else None

    try:
        conn = _connect()
    except sqlite3.Error as e:
        logging.error(f"DB connect error in status: {e}")
        print(json.dumps({"error": str(e)}))
        return 1

    try:
        if not _table_exists(conn):
            print(json.dumps([]))
            print("(routines table not yet initialized — run: cast migrate)", file=sys.stderr)
            return 0

        if name_filter:
            rows = conn.execute(
                "SELECT * FROM routines WHERE name = ?", (name_filter,)
            ).fetchall()
        else:
            rows = conn.execute(
                "SELECT * FROM routines ORDER BY name ASC LIMIT ?", (_MAX_ROUTINES,)
            ).fetchall()
            if len(rows) >= _MAX_ROUTINES:
                print(
                    f"WARNING: routines hit the {_MAX_ROUTINES}-row read cap — "
                    "some routines may not be shown.",
                    file=sys.stderr,
                )

        result = [_row_to_dict(r) for r in rows]
        print(json.dumps(result, indent=2))
        return 0
    except sqlite3.OperationalError as e:
        logging.error(f"OperationalError in status: {e}")
        print(json.dumps({"error": str(e)}))
        return 1
    except Exception as e:
        logging.error(f"Unexpected error in status: {e}")
        print(json.dumps({"error": str(e)}))
        return 1
    finally:
        conn.close()


# ---------------------------------------------------------------------------
# Subcommand: get
# ---------------------------------------------------------------------------
def cmd_get(args: list) -> int:
    if not args:
        print(json.dumps({"error": "get requires a routine name argument"}))
        return 1

    name = args[0]

    try:
        conn = _connect()
    except sqlite3.Error as e:
        logging.error(f"DB connect error in get: {e}")
        print(json.dumps({"error": str(e)}))
        return 1

    try:
        if not _table_exists(conn):
            print(json.dumps({"error": "routines table not yet initialized — run: cast migrate"}))
            return 1

        row = conn.execute(
            "SELECT * FROM routines WHERE name = ?", (name,)
        ).fetchone()

        if row is None:
            print(json.dumps({"error": f"routine not found: {name}"}))
            return 1

        print(json.dumps(_row_to_dict(row), indent=2))
        return 0
    except sqlite3.OperationalError as e:
        logging.error(f"OperationalError in get: {e}")
        print(json.dumps({"error": str(e)}))
        return 1
    except Exception as e:
        logging.error(f"Unexpected error in get: {e}")
        print(json.dumps({"error": str(e)}))
        return 1
    finally:
        conn.close()


# ---------------------------------------------------------------------------
# Subcommand: upsert
# ---------------------------------------------------------------------------
def cmd_upsert(args: list) -> int:
    """
    Read a JSON object from stdin (or --json flag) and upsert into routines table.
    Required fields: name, trigger_type, agent_to_dispatch, prompt_template.
    """
    try:
        raw = sys.stdin.read().strip()
        if not raw:
            print(json.dumps({"error": "upsert requires JSON on stdin"}))
            return 1
        data = json.loads(raw)
    except json.JSONDecodeError as e:
        print(json.dumps({"error": f"invalid JSON on stdin: {e}"}))
        return 1

    required = ["name", "trigger_type", "agent_to_dispatch", "prompt_template"]
    missing = [f for f in required if not data.get(f)]
    if missing:
        print(json.dumps({"error": f"missing required fields: {', '.join(missing)}"}))
        return 1

    # Validate user-supplied path fields before writing to DB
    for path_field in ("output_dir", "last_run_output_path"):
        val = data.get(path_field)
        if val:
            err = _validate_output_path(val, f"upsert:{path_field}")
            if err is not None:
                print(json.dumps({"error": err, "field": path_field}))
                return 1

    # Prompt-size diagnostic: warn when prompt_template is large enough to risk
    # context overflow when combined with agent system prompts and injected memories.
    PROMPT_SIZE_WARN_BYTES = 50_000
    prompt = data.get("prompt_template", "")
    if len(prompt.encode()) > PROMPT_SIZE_WARN_BYTES:
        logging.warning(
            f"upsert: prompt_template for '{data.get('name')}' is {len(prompt.encode())} bytes "
            f"(>{PROMPT_SIZE_WARN_BYTES}), may exceed context window when combined with system prompt and memories"
        )
        _maybe_log_failure(
            "cast-db-routines:upsert",
            -4,
            f"prompt_size_warning: {len(prompt.encode())} bytes for routine '{data.get('name')}'",
        )

    # Generate id if not provided
    if not data.get("id"):
        import uuid
        data["id"] = str(uuid.uuid4())

    # Set created_at if not provided
    if not data.get("created_at"):
        data["created_at"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    try:
        conn = _connect()
    except sqlite3.Error as e:
        logging.error(f"DB connect error in upsert: {e}")
        print(json.dumps({"error": str(e)}))
        return 1

    try:
        if not _table_exists(conn):
            print(json.dumps({"error": "routines table not yet initialized — run: cast migrate"}))
            return 1

        conn.execute(
            """
            INSERT INTO routines
              (id, name, trigger_type, trigger_value, agent_to_dispatch, prompt_template,
               output_dir, enabled, last_run_at, last_run_status, last_run_output_path, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(name) DO UPDATE SET
              trigger_type        = excluded.trigger_type,
              trigger_value       = excluded.trigger_value,
              agent_to_dispatch   = excluded.agent_to_dispatch,
              prompt_template     = excluded.prompt_template,
              output_dir          = excluded.output_dir,
              enabled             = excluded.enabled
            """,
            (
                data["id"],
                data["name"],
                data["trigger_type"],
                data.get("trigger_value"),
                data["agent_to_dispatch"],
                data["prompt_template"],
                data.get("output_dir"),
                int(data.get("enabled", 1)),
                data.get("last_run_at"),
                data.get("last_run_status"),
                data.get("last_run_output_path"),
                data["created_at"],
            ),
        )
        conn.commit()
        print(json.dumps({"status": "ok", "name": data["name"]}))
        return 0
    except sqlite3.OperationalError as e:
        logging.error(f"OperationalError in upsert: {e}")
        print(json.dumps({"error": str(e)}))
        return 1
    except Exception as e:
        logging.error(f"Unexpected error in upsert: {e}")
        print(json.dumps({"error": str(e)}))
        return 1
    finally:
        conn.close()


# ---------------------------------------------------------------------------
# Subcommand: update-status
# ---------------------------------------------------------------------------
def cmd_update_status(args: list) -> int:
    """
    update-status <name> <success|failure|skipped> [output_path]
    Updates last_run_at, last_run_status, and optionally last_run_output_path.
    """
    if len(args) < 2:
        print(json.dumps({"error": "update-status requires: <name> <status> [output_path]"}))
        return 1

    name = args[0]
    status = args[1]
    output_path = args[2] if len(args) > 2 else None

    if output_path is not None:
        err = _validate_output_path(output_path, "update-status")
        if err is not None:
            print(json.dumps({"error": err}))
            return 1

    valid_statuses = {"success", "failure", "skipped"}
    if status not in valid_statuses:
        print(json.dumps({"error": f"status must be one of: {', '.join(sorted(valid_statuses))}"}))
        return 1

    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    try:
        conn = _connect()
    except sqlite3.Error as e:
        logging.error(f"DB connect error in update-status: {e}")
        print(json.dumps({"error": str(e)}))
        return 1

    try:
        if not _table_exists(conn):
            print(json.dumps({"error": "routines table not yet initialized — run: cast migrate"}))
            return 1

        conn.execute(
            """
            UPDATE routines
            SET last_run_at = ?, last_run_status = ?, last_run_output_path = ?
            WHERE name = ?
            """,
            (now, status, output_path, name),
        )
        conn.commit()

        if conn.execute("SELECT changes()").fetchone()[0] == 0:
            print(json.dumps({"error": f"routine not found: {name}"}))
            return 1

        print(json.dumps({"status": "ok", "name": name, "last_run_status": status, "last_run_at": now}))
        return 0
    except sqlite3.OperationalError as e:
        logging.error(f"OperationalError in update-status: {e}")
        print(json.dumps({"error": str(e)}))
        return 1
    except Exception as e:
        logging.error(f"Unexpected error in update-status: {e}")
        print(json.dumps({"error": str(e)}))
        return 1
    finally:
        conn.close()


# ---------------------------------------------------------------------------
# Subcommand: enable-disable
# ---------------------------------------------------------------------------
def cmd_enable_disable(args: list) -> int:
    """
    enable-disable <name> <0|1>
    Sets the enabled flag for a routine.
    """
    if len(args) < 2:
        print(json.dumps({"error": "enable-disable requires: <name> <0|1>"}))
        return 1

    name = args[0]
    try:
        enabled = int(args[1])
        if enabled not in (0, 1):
            raise ValueError("must be 0 or 1")
    except ValueError:
        print(json.dumps({"error": "second argument must be 0 or 1"}))
        return 1

    try:
        conn = _connect()
    except sqlite3.Error as e:
        logging.error(f"DB connect error in enable-disable: {e}")
        print(json.dumps({"error": str(e)}))
        return 1

    try:
        if not _table_exists(conn):
            print(json.dumps({"error": "routines table not yet initialized — run: cast migrate"}))
            return 1

        conn.execute(
            "UPDATE routines SET enabled = ? WHERE name = ?",
            (enabled, name),
        )
        conn.commit()

        if conn.execute("SELECT changes()").fetchone()[0] == 0:
            print(json.dumps({"error": f"routine not found: {name}"}))
            return 1

        state = "enabled" if enabled else "disabled"
        print(json.dumps({"status": "ok", "name": name, "enabled": enabled, "state": state}))
        return 0
    except sqlite3.OperationalError as e:
        logging.error(f"OperationalError in enable-disable: {e}")
        print(json.dumps({"error": str(e)}))
        return 1
    except Exception as e:
        logging.error(f"Unexpected error in enable-disable: {e}")
        print(json.dumps({"error": str(e)}))
        return 1
    finally:
        conn.close()


# ---------------------------------------------------------------------------
# Main dispatch
# ---------------------------------------------------------------------------
SUBCOMMANDS = {
    "list": cmd_list,
    "status": cmd_status,
    "get": cmd_get,
    "upsert": cmd_upsert,
    "update-status": cmd_update_status,
    "enable-disable": cmd_enable_disable,
}


def main() -> int:
    _setup_logging()

    if len(sys.argv) < 2:
        print(
            "Usage: cast-db-routines.py <subcommand> [args]\n"
            "Subcommands: list, status [name], get <name>, upsert, update-status <name> <status> [output_path],"
            " enable-disable <name> <0|1>",
            file=sys.stderr,
        )
        return 1

    subcommand = sys.argv[1]
    remaining_args = sys.argv[2:]

    handler = SUBCOMMANDS.get(subcommand)
    if handler is None:
        print(json.dumps({"error": f"unknown subcommand: {subcommand}"}))
        return 1

    return handler(remaining_args)


if __name__ == "__main__":
    sys.exit(main())
