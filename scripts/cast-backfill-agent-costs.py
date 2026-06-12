#!/usr/bin/env python3
"""CAST backfill script: recover cost/model/token data for historical agent_runs rows.

Mirrors the exact cost computation logic from cast-subagent-stop-hook.sh lines ~255-432.
Resolves transcript files using the same recursive glob pattern the hook uses.
"""
import argparse
import glob
import json
import os
import sqlite3
import sys
from typing import Optional


PRICING_PATH = os.path.expanduser("~/.claude/config/model-pricing.json")
DEFAULT_RATE_IN = 3.0
DEFAULT_RATE_OUT = 15.0


def load_pricing() -> dict:
    """Load model pricing table. Returns dict of model -> {cost_per_million_input, cost_per_million_output}."""
    try:
        with open(PRICING_PATH, "r") as f:
            data = json.load(f)
        return data.get("models", {})
    except Exception as e:
        # fake-success-ok: intentional fallback — returns empty dict so _default rates apply;
        # caller gets DEFAULT_RATE_IN/DEFAULT_RATE_OUT via get_rates(). Print warning so it
        # is never silent.
        print(f"[WARN] Could not load pricing from {PRICING_PATH}: {e} — using defaults", file=sys.stderr)
        return {}


def get_rates(pricing: dict, model: Optional[str]) -> tuple[float, float]:
    """Return (rate_in, rate_out) per million tokens for the given model."""
    entry = {}
    if model:
        entry = pricing.get(model) or pricing.get("_default") or {}
    else:
        entry = pricing.get("_default") or {}
    rate_in = entry.get("cost_per_million_input", DEFAULT_RATE_IN)
    rate_out = entry.get("cost_per_million_output", DEFAULT_RATE_OUT)
    return float(rate_in), float(rate_out)


def compute_cost(
    total_input: int,
    total_output: int,
    cache_read: int,
    cache_create: int,
    rate_in: float,
    rate_out: float,
) -> float:
    """Anthropic full cost formula — mirrors hook line ~369-373.

    cost = (input * rate_in + output * rate_out + cache_create * rate_in * 1.25 + cache_read * rate_in * 0.1)
           / 1_000_000
    """
    return round(
        (
            total_input * rate_in
            + total_output * rate_out
            + cache_create * rate_in * 1.25
            + cache_read * rate_in * 0.1
        )
        / 1_000_000,
        6,
    )


def resolve_transcript(session_id: str, agent_id: str) -> Optional[str]:
    """Resolve transcript path using the same recursive glob as the stop-hook.

    Covers:
      Flat:   ~/.claude/projects/*/<session_id>/subagents/agent-<agent_id>.jsonl
      Nested: ~/.claude/projects/*/<session_id>/subagents/workflows/wf_*/agent-<agent_id>.jsonl
    Returns the most recently modified match, or None if no match.
    """
    pattern = os.path.expanduser(
        f"~/.claude/projects/*/{session_id}/subagents/**/agent-{agent_id}.jsonl"
    )
    matches = glob.glob(pattern, recursive=True)
    if matches:
        return max(matches, key=os.path.getmtime)
    return None


def parse_transcript(
    transcript_path: str,
) -> Optional[tuple[int, int, int, int, Optional[str]]]:
    """Parse a .jsonl transcript file.

    Returns (input_tokens, output_tokens, cache_read, cache_create, model) or None
    if no usage blocks were found. Mirrors hook lines ~317-336.
    """
    total_input = 0
    total_output = 0
    total_cache_read = 0
    total_cache_create = 0
    transcript_model: Optional[str] = None
    found_usage = False

    with open(transcript_path, "r", errors="replace") as f:
        for raw_line in f:
            raw_line = raw_line.strip()
            if not raw_line:
                continue
            try:
                obj = json.loads(raw_line)
            except Exception:
                continue  # fake-success-ok: skip malformed JSONL lines; mirrors hook behavior
            msg = obj.get("message", {}) if isinstance(obj.get("message"), dict) else {}
            usage = (
                msg.get("usage")
                if isinstance(msg.get("usage"), dict)
                else obj.get("usage")
            )
            if not isinstance(usage, dict):
                continue
            total_input += usage.get("input_tokens", 0) or 0
            total_output += usage.get("output_tokens", 0) or 0
            total_cache_read += usage.get("cache_read_input_tokens", 0) or 0
            total_cache_create += usage.get("cache_creation_input_tokens", 0) or 0
            found_usage = True
            if not transcript_model and isinstance(msg.get("model"), str):
                transcript_model = msg["model"]

    if not found_usage:
        return None
    return (total_input, total_output, total_cache_read, total_cache_create, transcript_model)


def get_db_path(db_arg: Optional[str]) -> str:
    """Resolve the DB path from --db arg, CAST_DB_PATH env, or default."""
    if db_arg:
        return db_arg
    return os.path.expanduser(
        os.environ.get("CAST_DB_PATH", "~/.claude/cast.db")
    )


def fetch_null_cost_rows(conn: sqlite3.Connection) -> list[tuple]:
    """Fetch all agent_runs rows that need backfill."""
    cur = conn.execute(
        "SELECT id, session_id, agent_id, agent FROM agent_runs "
        "WHERE cost_usd IS NULL AND agent_id IS NOT NULL"
    )
    return cur.fetchall()


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Backfill cost/model/token data for historical agent_runs rows."
    )
    parser.add_argument(
        "--db",
        default=None,
        help="Path to cast.db (default: $CAST_DB_PATH or ~/.claude/cast.db)",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Report what would change without writing to the DB.",
    )
    args = parser.parse_args()

    db_path = get_db_path(args.db)
    pricing = load_pricing()

    print(f"DB: {db_path}")
    print(f"Pricing models loaded: {len(pricing)}")
    print(f"Dry-run: {args.dry_run}")
    print()

    conn = sqlite3.connect(db_path, timeout=10)
    rows = fetch_null_cost_rows(conn)
    total_null = len(rows)
    print(f"NULL-cost rows found: {total_null}")

    filled = []
    skipped_no_transcript = 0
    skipped_no_usage = 0
    errors = 0

    for row_id, session_id, agent_id, agent_name in rows:
        try:
            if not session_id or not agent_id:
                skipped_no_transcript += 1
                continue

            transcript_path = resolve_transcript(session_id, agent_id)
            if not transcript_path:
                skipped_no_transcript += 1
                continue

            result = parse_transcript(transcript_path)
            if result is None:
                skipped_no_usage += 1
                continue

            inp, out, cr, cc, model = result
            if inp + out == 0:
                skipped_no_usage += 1
                continue

            rate_in, rate_out = get_rates(pricing, model)
            cost = compute_cost(inp, out, cr, cc, rate_in, rate_out)

            filled.append({
                "id": row_id,
                "agent": agent_name,
                "model": model,
                "input_tokens": inp,
                "output_tokens": out,
                "cache_read_input_tokens": cr,
                "cache_creation_input_tokens": cc,
                "cost_usd": cost,
            })
        except Exception as e:
            # fake-success-ok: per-row defensive catch — task spec requires "Never crash on a
            # malformed transcript". Error is counted, printed to stderr, and surfaced in the
            # final report. No data is silently invented or skipped without accounting.
            errors += 1
            print(f"  [WARN] row {row_id} agent_id={agent_id}: {e}", file=sys.stderr)
            continue

    total_cost = sum(r["cost_usd"] for r in filled)
    print(f"Resolvable (have transcript + usage): {len(filled)}")
    print(f"Skipped — no transcript found:        {skipped_no_transcript}")
    print(f"Skipped — no usage in transcript:     {skipped_no_usage}")
    print(f"Errors (per-row exceptions):           {errors}")
    print(f"Sum of recovered cost_usd:             ${total_cost:.6f}")
    print()

    # Sample: show up to 5 rows
    sample = filled[:5]
    if sample:
        print("Sample rows (up to 5):")
        for r in sample:
            print(
                f"  id={r['id']} agent={r['agent']} model={r['model'] or 'unknown'} "
                f"in={r['input_tokens']} out={r['output_tokens']} "
                f"cr={r['cache_read_input_tokens']} cc={r['cache_creation_input_tokens']} "
                f"cost=${r['cost_usd']:.6f}"
            )
        print()

    if args.dry_run:
        print("DRY-RUN mode — no writes performed.")
        conn.close()
        return 0

    # Write in a single transaction
    updated = 0
    with conn:
        for r in filled:
            conn.execute(
                "UPDATE agent_runs "
                "SET model=?, input_tokens=?, output_tokens=?, "
                "cache_read_input_tokens=?, cache_creation_input_tokens=?, cost_usd=? "
                "WHERE id=? AND cost_usd IS NULL",
                (
                    r["model"],
                    r["input_tokens"],
                    r["output_tokens"],
                    r["cache_read_input_tokens"],
                    r["cache_creation_input_tokens"],
                    r["cost_usd"],
                    r["id"],
                ),
            )
            updated += 1

    conn.close()
    print(f"Rows updated: {updated}")
    print(f"Total cost recovered: ${total_cost:.6f}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
