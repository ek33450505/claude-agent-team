#!/usr/bin/env python3
"""cast-rate-check.py — Fetch Anthropic rate limit data and write to cast.db.

Usage:
    python3 cast-rate-check.py          # fetch + store snapshot
    python3 cast-rate-check.py --json   # print latest snapshot as JSON (for morning-briefing)

Env:
    ANTHROPIC_API_KEY       — API key (required; or macOS Keychain 'anthropic-api-key')
    CAST_ANTHROPIC_ORG_ID   — Organization ID (required; logs warning and exits 0 if missing)
    CAST_SCRIPTS_DIR        — override path to scripts dir for cast_db import
    CAST_DB_PATH            — override path to cast.db
"""

import argparse
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path


LOG_FILE = Path.home() / ".claude" / "logs" / "cast-rate-check.log"
API_BASE = os.environ.get("ANTHROPIC_API_BASE", "https://api.anthropic.com")


def _log(level: str, msg: str) -> None:
    """Append a line to the rate-check log. Never raises."""
    try:
        LOG_FILE.parent.mkdir(parents=True, exist_ok=True)
        ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        with open(LOG_FILE, "a") as fh:
            fh.write(f"[{ts}] {level}: {msg}\n")
    except Exception:
        pass


def _resolve_api_key() -> str | None:
    """Return ANTHROPIC_API_KEY from env or macOS Keychain, or None."""
    key = os.environ.get("ANTHROPIC_API_KEY", "")
    if key:
        return key
    # macOS Keychain fallback — mirror cast-managed-agent.sh pattern
    try:
        result = subprocess.run(
            ["security", "find-generic-password", "-s", "anthropic-api-key", "-w"],
            capture_output=True,
            text=True,
            timeout=5,
        )
        if result.returncode == 0:
            keychain_key = result.stdout.strip()
            if keychain_key:
                return keychain_key
    except (FileNotFoundError, subprocess.TimeoutExpired, OSError):
        pass
    return None


def _ensure_table() -> None:
    """CREATE TABLE IF NOT EXISTS rate_limit_snapshots."""
    import cast_db  # noqa: F401 — imported for side-effect path resolution
    from cast_db import db_execute
    db_execute("""
        CREATE TABLE IF NOT EXISTS rate_limit_snapshots (
            ts          INTEGER,
            tpm_limit   INTEGER,
            tpm_used    INTEGER,
            rpm_limit   INTEGER,
            rpm_used    INTEGER,
            raw_json    TEXT
        )
    """)


def _fetch_rate_limits(api_key: str, org_id: str) -> dict:
    """Call GET /v1/organizations/{org_id}/rate_limits and return parsed JSON."""
    url = f"{API_BASE}/v1/organizations/{org_id}/rate_limits"
    req = urllib.request.Request(
        url,
        headers={
            "x-api-key": api_key,
            "anthropic-version": "2023-06-01",
            "content-type": "application/json",
        },
        method="GET",
    )
    with urllib.request.urlopen(req, timeout=10) as resp:
        return json.loads(resp.read().decode("utf-8"))


def _extract_metrics(data: dict) -> tuple[int, int, int, int]:
    """Extract (tpm_limit, tpm_used, rpm_limit, rpm_used) from the API response.

    The Anthropic rate_limits object shape varies; attempt known field names
    and fall back to 0 for missing values.
    """
    tpm_limit = data.get("tokens_per_minute_limit") or data.get("tpm_limit") or 0
    tpm_used  = data.get("tokens_per_minute_used")  or data.get("tpm_used")  or 0
    rpm_limit = data.get("requests_per_minute_limit") or data.get("rpm_limit") or 0
    rpm_used  = data.get("requests_per_minute_used")  or data.get("rpm_used")  or 0
    return int(tpm_limit), int(tpm_used), int(rpm_limit), int(rpm_used)


def cmd_fetch(api_key: str, org_id: str) -> None:
    """Fetch rate limits and persist to cast.db."""
    try:
        data = _fetch_rate_limits(api_key, org_id)
    except urllib.error.HTTPError as exc:
        body = ""
        try:
            body = exc.read().decode("utf-8", errors="replace")
        except Exception:
            pass
        _log("ERROR", f"HTTP {exc.code} from rate_limits endpoint: {body[:200]}")
        sys.exit(0)
    except urllib.error.URLError as exc:
        _log("ERROR", f"URL error fetching rate limits: {exc.reason}")
        sys.exit(0)
    except Exception as exc:
        _log("ERROR", f"Unexpected error fetching rate limits: {exc}")
        sys.exit(0)

    tpm_limit, tpm_used, rpm_limit, rpm_used = _extract_metrics(data)
    ts = int(time.time())
    raw = json.dumps(data)

    try:
        _setup_cast_db_path()
        _ensure_table()
        from cast_db import db_write
        db_write("rate_limit_snapshots", {
            "ts":        ts,
            "tpm_limit": tpm_limit,
            "tpm_used":  tpm_used,
            "rpm_limit": rpm_limit,
            "rpm_used":  rpm_used,
            "raw_json":  raw,
        })
        _log("INFO", f"Snapshot written: tpm={tpm_used}/{tpm_limit} rpm={rpm_used}/{rpm_limit}")
    except Exception as exc:
        _log("ERROR", f"Failed to write snapshot to cast.db: {exc}")
        sys.exit(0)


def cmd_json() -> None:
    """Print the latest snapshot from cast.db as JSON, or error JSON if unavailable."""
    try:
        _setup_cast_db_path()
        _ensure_table()
        from cast_db import db_query
        rows = db_query(
            "SELECT ts, tpm_limit, tpm_used, rpm_limit, rpm_used, raw_json "
            "FROM rate_limit_snapshots ORDER BY ts DESC LIMIT 1"
        )
        if not rows:
            print(json.dumps({"error": "no snapshots found"}))
            return
        row = rows[0]
        print(json.dumps({
            "ts":        row["ts"],
            "tpm_limit": row["tpm_limit"],
            "tpm_used":  row["tpm_used"],
            "rpm_limit": row["rpm_limit"],
            "rpm_used":  row["rpm_used"],
        }))
    except Exception as exc:
        print(json.dumps({"error": str(exc)}))


def _setup_cast_db_path() -> None:
    """Insert the scripts dir into sys.path so cast_db is importable."""
    scripts_dir = os.environ.get(
        "CAST_SCRIPTS_DIR",
        os.path.expanduser("~/.claude/scripts"),
    )
    if scripts_dir not in sys.path:
        sys.path.insert(0, scripts_dir)


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Fetch Anthropic rate limits and store in cast.db."
    )
    parser.add_argument(
        "--json",
        action="store_true",
        dest="json_output",
        help="Print latest snapshot as JSON (for morning-briefing consumption).",
    )
    args = parser.parse_args()

    if args.json_output:
        cmd_json()
        return

    # --- fetch path ---
    org_id = os.environ.get("CAST_ANTHROPIC_ORG_ID", "")
    if not org_id:
        _log("WARNING", "CAST_ANTHROPIC_ORG_ID not set — skipping rate limit fetch")
        sys.exit(0)

    api_key = _resolve_api_key()
    if not api_key:
        _log("ERROR", "ANTHROPIC_API_KEY not set (env var or keychain) — skipping")
        sys.exit(0)

    cmd_fetch(api_key, org_id)


if __name__ == "__main__":
    main()
