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
    """Get token usage for a session. Returns dict with token counts."""
    if not DB_PATH.exists():
        return {"error": "cast.db not found", "total_tokens": 0}

    conn = sqlite3.connect(str(DB_PATH))
    conn.row_factory = sqlite3.Row
    try:
        if session_id:
            row = conn.execute(
                "SELECT session_id, total_tokens, input_tokens, output_tokens FROM sessions WHERE session_id = ? LIMIT 1",
                (session_id,),
            ).fetchone()
        else:
            row = conn.execute(
                "SELECT session_id, total_tokens, input_tokens, output_tokens FROM sessions ORDER BY created_at DESC LIMIT 1"
            ).fetchone()

        if not row:
            return {"error": "No sessions found", "total_tokens": 0}

        total = row["total_tokens"] or 0
        sid = row["session_id"]

        # Fallback: sum from agent_runs if total_tokens is 0
        if total == 0:
            result = conn.execute(
                "SELECT SUM(total_tokens) as total FROM agent_runs WHERE session_id = ?",
                (sid,),
            ).fetchone()
            total = (result["total"] or 0) if result else 0

        return {
            "session_id": sid,
            "total_tokens": total,
            "input_tokens": row["input_tokens"] or 0,
            "output_tokens": row["output_tokens"] or 0,
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
