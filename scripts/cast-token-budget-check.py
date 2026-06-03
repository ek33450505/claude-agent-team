#!/usr/bin/env python3
"""CAST Token Budget Check — alert when session token usage exceeds threshold."""

import argparse
import json
import os
import sqlite3
import sys
from pathlib import Path

DB_PATH = Path(os.path.expanduser("~/.claude/cast.db"))


def get_token_usage(session_id: str = None) -> dict:
    """Get token usage for a session. Returns dict with token counts.

    sessions table has: id, project, project_root, started_at, ended_at, model
    agent_runs table has: session_id, input_tokens, output_tokens (no total_tokens column)
    """
    if not DB_PATH.exists():
        return {"error": "cast.db not found", "total_tokens": 0}

    conn = sqlite3.connect(str(DB_PATH))
    conn.row_factory = sqlite3.Row
    try:
        if session_id:
            row = conn.execute(
                "SELECT id AS session_id FROM sessions WHERE id = ? LIMIT 1",
                (session_id,),
            ).fetchone()
        else:
            row = conn.execute(
                "SELECT id AS session_id FROM sessions ORDER BY started_at DESC LIMIT 1"
            ).fetchone()

        if not row:
            return {"error": "No sessions found", "total_tokens": 0}

        sid = row["session_id"]

        # Sum tokens from agent_runs (the authoritative source)
        result = conn.execute(
            "SELECT COALESCE(SUM(input_tokens), 0) AS input_tokens, "
            "COALESCE(SUM(output_tokens), 0) AS output_tokens "
            "FROM agent_runs WHERE session_id = ?",
            (sid,),
        ).fetchone()

        input_tokens = (result["input_tokens"] or 0) if result else 0
        output_tokens = (result["output_tokens"] or 0) if result else 0
        total = input_tokens + output_tokens

        return {
            "session_id": sid,
            "total_tokens": total,
            "input_tokens": input_tokens,
            "output_tokens": output_tokens,
        }
    except sqlite3.OperationalError as e:
        return {"error": str(e), "total_tokens": 0}
    finally:
        conn.close()


def main():
    parser = argparse.ArgumentParser(description="CAST Token Budget Check — session token usage alerting")
    parser.add_argument("--threshold", type=int, default=50000, help="Warning threshold in tokens (default: 50000)")
    parser.add_argument("--session-id", help="Specific session ID to check (default: most recent)")
    parser.add_argument("--json", action="store_true", dest="json_output", help="Output as JSON")
    args = parser.parse_args()

    usage = get_token_usage(args.session_id)

    if "error" in usage and usage["total_tokens"] == 0:
        if args.json_output:
            print(json.dumps({"status": "OK", "message": usage["error"], "total_tokens": 0}))
        else:
            print(f"OK: {usage.get('error', 'unknown')} — defaulting to 0 tokens")
        sys.exit(0)

    total = usage["total_tokens"]
    pct_of_threshold = (total / args.threshold * 100) if args.threshold > 0 else 0

    if total > args.threshold:
        exceed_pct = ((total - args.threshold) / args.threshold * 100) if args.threshold > 0 else 0
        result = {
            "status": "WARNING",
            "total_tokens": total,
            "threshold": args.threshold,
            "exceed_pct": round(exceed_pct, 1),
        }
        if args.json_output:
            print(json.dumps(result))
        else:
            print(f"WARNING: {total:,} tokens used (exceeds {args.threshold:,} threshold by {exceed_pct:.1f}%)")
        sys.exit(1)
    else:
        result = {
            "status": "OK",
            "total_tokens": total,
            "threshold": args.threshold,
            "pct_of_threshold": round(pct_of_threshold, 1),
        }
        if args.json_output:
            print(json.dumps(result))
        else:
            print(f"OK: {total:,} tokens used ({pct_of_threshold:.1f}% of {args.threshold:,} threshold)")
        sys.exit(0)


if __name__ == "__main__":
    main()
