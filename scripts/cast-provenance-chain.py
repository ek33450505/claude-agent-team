#!/usr/bin/env python3
"""cast-provenance-chain.py — Tamper-evident hash-chain of per-session A5 ledger digests.

CLI: cast-provenance-chain.py <subcommand> [--db PATH]

Subcommands:
  append  <session_id>  — Append a session to the chain (idempotent, fail-open).
  verify               — Walk the chain and verify integrity + session attestations.
  backfill             — Append all sessions not yet in the chain (deterministic order).
  status               — Print chain health summary.

Hash format:
  session_digest = ledger._compute_digest(ledger._build_receipt_data(ro_conn, session_row))
  prev_hash      = stored chain_hash of previous row; '' for genesis row.
  chain_hash     = "sha256:" + sha256((prev_hash + session_digest).encode("utf-8")).hexdigest()

TRUST MODEL:
  Local-only, no external anchor. Detects insertion, deletion, reordering, or
  modification of individual chain rows or session data when the attacker does NOT
  perform a full consistent re-chain.

  LIMITATION 1: An attacker with full read-write access to cast.db can edit a
  session_digest and recompute every subsequent chain_hash consistently — level-1
  then passes. Closing this requires an external anchor (publish the head chain_hash
  to an append-only/remote/WORM store).

  LIMITATION 2: Deleting a session row from `sessions` makes verify classify that
  link as "pruned" and skip level-2 attestation. The chain_hash still locks the
  stored digest, but it can no longer be independently re-derived. Pruning is
  by-design (the chain stores the digest at append-time to survive TTL pruning).

  LIMITATION 3: Truncating the chain tail (removing the most recent links) leaves a
  valid prefix; only the empty-chain case is cross-checked against the sessions count.

Local-only. Nothing leaves the machine. Never writes through the read-only ledger conn.
"""

import argparse
import hashlib
import importlib.util
import json
import os
import sqlite3
import sys
import urllib.parse
from pathlib import Path
from typing import Any, Dict, List, Optional


# ── Ledger module loader ──────────────────────────────────────────────────────

def _load_ledger():
    """Lazy-load cast-ledger.py (hyphenated -> importlib). Returns module or None (fail-open)."""
    try:
        path = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'cast-ledger.py')
        spec = importlib.util.spec_from_file_location('cast_ledger', path)
        if spec is None or spec.loader is None:
            return None
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod
    except Exception:
        return None


# ── DB path resolution ────────────────────────────────────────────────────────

def _resolve_db_path(ledger, override: str = "") -> str:
    """Resolve DB path via ledger._get_db_path if available, else replicate the logic."""
    if ledger is not None:
        return ledger._get_db_path(override)
    if override:
        return override
    url = os.environ.get("CAST_DB_URL", "")
    if url.startswith("sqlite:///"):
        return url[len("sqlite:///"):]
    return os.environ.get("CAST_DB_PATH", str(Path.home() / ".claude" / "cast.db"))


# ── Hash computation ──────────────────────────────────────────────────────────

def _has_receipt_json(conn: sqlite3.Connection) -> bool:
    """True when provenance_chain carries the receipt_json column.

    A DB that predates migration 035 has not been upgraded yet, and selecting a
    column that does not exist would turn a missing feature into a hard read
    error. PRAGMA output is pipe-delimited via the CLI but a row sequence here.
    """
    try:
        return any(r[1] == "receipt_json"
                   for r in conn.execute("PRAGMA table_info(provenance_chain)").fetchall())
    except Exception:
        return False


# Session-header fields written once at session start and never updated by CAST.
# Everything else in a receipt legitimately moves after the digest is taken:
# agent_runs are pruned by retention and backfilled with cost/tool_uses/model at
# completion, integrity rows keep arriving, and status/ended_at are set at session
# end. Divergence in THESE fields is therefore not explainable by CAST's own
# writers, and is reported as tamper — which is what the pre-PROV-1 check caught
# and what a blanket "drift" verdict would have quietly stopped catching.
_IMMUTABLE_SESSION_FIELDS = ("id", "project", "project_root", "started_at")


def _immutable_fields_changed(payload: str, live: Dict[str, Any]) -> List[str]:
    """Return the immutable session-header fields that differ from the frozen receipt.

    Empty list on any parse failure: an unreadable payload is already reported by
    the digest check above, and guessing here would turn one finding into two.
    """
    try:
        stored = json.loads(payload).get("session", {})
    except Exception:
        return []
    live_session = live.get("session", {})
    return [f for f in _IMMUTABLE_SESSION_FIELDS
            if stored.get(f) != live_session.get(f)]


def _compute_chain_hash(prev_hash: str, session_digest: str) -> str:
    """Compute chain_hash = 'sha256:' + sha256((prev_hash + session_digest).encode()).hexdigest().

    Defensively coerces None to '' so legacy NULL rows never raise TypeError.
    """
    raw = ((prev_hash or "") + session_digest).encode("utf-8")
    return "sha256:" + hashlib.sha256(raw).hexdigest()


# ── Connections ──────────────────────────────────────────────────────────────

def _open_rw(db_path: str) -> sqlite3.Connection:
    """Open a read-write sqlite3 connection for INSERT operations."""
    rw = sqlite3.connect(db_path, timeout=5)
    rw.row_factory = sqlite3.Row
    rw.execute("PRAGMA busy_timeout=5000;")
    return rw


def _open_ro(db_path: str) -> sqlite3.Connection:
    """Open a read-only sqlite3 connection (mirrors ledger._connect's mode=ro approach)."""
    ro_uri = "file://" + urllib.parse.quote(os.path.abspath(db_path)) + "?mode=ro"
    conn = sqlite3.connect(ro_uri, uri=True, timeout=5)
    conn.row_factory = sqlite3.Row
    try:
        conn.execute("PRAGMA busy_timeout=5000;")
    except Exception:
        pass
    return conn


# ── Core append logic ────────────────────────────────────────────────────────

def _append_session(
    ledger,
    ro_conn: sqlite3.Connection,
    rw: sqlite3.Connection,
    session_id: str,
) -> bool:
    """Append one session to the chain. Returns True if inserted, False if skipped/error.

    Uses BEGIN IMMEDIATE to serialize the head-read + insert against concurrent appends,
    preventing a race where two processes read the same head and both store the same
    prev_hash (which verify would later flag as a false linkage break).
    INSERT OR IGNORE keeps this idempotent: a 2nd append for the same session is a no-op.
    On any exception, rolls back and returns False (append stays fail-open at call-site).
    """
    session_row = ledger._fetch_session(ro_conn, session_id)
    if session_row is None:
        return False
    # Serialize ONCE and keep the bytes. The digest must be taken over exactly what
    # is stored, or the two disagree by construction.
    receipt_json = ledger.canonical_json(ledger._build_receipt_data(ro_conn, session_row))
    session_digest = ledger.digest_of_canonical_json(receipt_json)

    try:
        rw.execute("BEGIN IMMEDIATE")
        head_row = rw.execute(
            "SELECT chain_hash FROM provenance_chain ORDER BY seq DESC LIMIT 1"
        ).fetchone()
        prev_hash = (head_row["chain_hash"] or "") if head_row else ""
        chain_hash = _compute_chain_hash(prev_hash, session_digest)
        if _has_receipt_json(rw):
            cursor = rw.execute(
                "INSERT OR IGNORE INTO provenance_chain "
                "(session_id, prev_hash, session_digest, chain_hash, receipt_json) VALUES (?,?,?,?,?)",
                (session_id, prev_hash, session_digest, chain_hash, receipt_json),
            )
        else:
            # DB predates migration 035. Append without the payload rather than
            # raising into the caller's except and silently recording nothing —
            # _append_session is fail-open, so an unconditional 5-column INSERT
            # here would turn "not upgraded yet" into "the chain stopped growing".
            cursor = rw.execute(
                "INSERT OR IGNORE INTO provenance_chain "
                "(session_id, prev_hash, session_digest, chain_hash) VALUES (?,?,?,?)",
                (session_id, prev_hash, session_digest, chain_hash),
            )
        rw.commit()
        return cursor.rowcount > 0
    except Exception:
        try:
            rw.rollback()
        except Exception:
            pass
        return False


# ── Subcommand: append ───────────────────────────────────────────────────────

def cmd_append(args: argparse.Namespace, ledger) -> int:
    """Append a single session to the chain. FAIL-OPEN — always exits 0."""
    ro_conn: Optional[sqlite3.Connection] = None
    rw: Optional[sqlite3.Connection] = None
    try:
        db_path = _resolve_db_path(ledger, getattr(args, 'db', None) or "")
        if ledger is None:
            print("cast-provenance-chain: ledger module unavailable; skipping append", file=sys.stderr)
            return 0
        ro_conn = ledger._connect(db_path)
        rw = _open_rw(db_path)
        _append_session(ledger, ro_conn, rw, args.session_id)
    except Exception as e:
        print(f"cast-provenance-chain append: non-fatal error: {e}", file=sys.stderr)
    finally:
        if ro_conn is not None:
            try:
                ro_conn.close()
            except Exception:
                pass
        if rw is not None:
            try:
                rw.close()
            except Exception:
                pass
    return 0


# ── Subcommand: verify ───────────────────────────────────────────────────────

def cmd_verify(args: argparse.Namespace, ledger) -> int:
    """Walk the chain and verify integrity. Returns 0 for PASS, 1 for BROKEN.

    Level 1: chain linkage + chain_hash recompute (no live session required).
    Level 2: session attestation (re-derive session_digest from live data; skip if pruned).
    Empty-chain guard: if chain is empty but sessions exist, report BROKEN.
    """
    db_path = _resolve_db_path(ledger, getattr(args, 'db', None) or "")
    ro_conn: Optional[sqlite3.Connection] = None
    ledger_ro_conn: Optional[sqlite3.Connection] = None

    try:
        try:
            ro_conn = _open_ro(db_path)
            rows = ro_conn.execute(
                "SELECT seq, session_id, prev_hash, session_digest, chain_hash, "
                + ("receipt_json " if _has_receipt_json(ro_conn) else "NULL AS receipt_json ")
                + "FROM provenance_chain ORDER BY seq ASC"
            ).fetchall()
        except Exception as e:
            print(f"VERIFY-CHAIN: BROKEN (cannot read chain: {e})")
            return 1

        if not rows:
            # FIX 1: cross-check sessions to prevent empty-chain false-pass
            session_count = 0
            try:
                sc_row = ro_conn.execute("SELECT COUNT(*) FROM sessions").fetchone()
                session_count = sc_row[0] if sc_row else 0
            except Exception:
                session_count = 0
            if session_count > 0:
                print(
                    f"VERIFY-CHAIN: BROKEN (chain is empty but {session_count} sessions exist"
                    f" — run 'cast provenance backfill' or investigate tampering)"
                )
                return 1
            print("VERIFY-CHAIN: PASS (0 links)")
            return 0

        # Open ledger ro conn for level-2 session attestation
        if ledger is not None:
            try:
                ledger_ro_conn = ledger._connect(db_path)
            except Exception as e:
                print(
                    f"WARNING: level-2 attestation skipped — provenance ledger unavailable (connect failed: {e})",
                    file=sys.stderr,
                )
                ledger_ro_conn = None
        else:
            print(
                "WARNING: level-2 attestation skipped — provenance ledger unavailable (module load failed)",
                file=sys.stderr,
            )

        broken = False
        pruned_skipped = 0
        unverifiable = 0
        drifted = 0
        prev_stored_chain_hash = ""

        for row in rows:
            seq = row["seq"]
            stored_prev = row["prev_hash"] or ""  # defensive coercion: NULL → ''

            # LEVEL 1: chain linkage integrity
            if stored_prev != prev_stored_chain_hash:
                print(f"VERIFY-CHAIN: BROKEN (seq {seq}: prev_hash linkage mismatch)")
                broken = True

            expected_chain_hash = _compute_chain_hash(stored_prev, row["session_digest"])
            if row["chain_hash"] != expected_chain_hash:
                print(f"VERIFY-CHAIN: BROKEN (seq {seq}: chain_hash mismatch)")
                broken = True

            # LEVEL 2: attestation of the stored receipt payload.
            #
            # This asks "does the row still hash to its stored digest", which is a
            # question about the LEDGER and has one right answer. It deliberately no
            # longer asks "does live data still hash to the stored digest" — that is
            # a question about the rest of the database, whose answer changes for
            # reasons that are not tamper: retention prunes agent_runs while this
            # table is never pruned, and cost/tool_uses/model are backfilled after a
            # session ends. Conflating the two reported 244 of 929 rows as tamper,
            # none of which were, and a permanently part-red chain says nothing.
            payload = row["receipt_json"]
            if payload is None:
                # Appended before receipt_json existed. Its digest cannot be
                # re-derived from anything that survives, so no verdict is
                # available — which is NOT the same as a failed one. Level 1 above
                # still covers this row completely.
                unverifiable += 1
            elif ledger is not None:
                if ledger.digest_of_canonical_json(payload) != row["session_digest"]:
                    print(
                        f"VERIFY-CHAIN: BROKEN (seq {seq}: stored receipt does not match "
                        f"its digest for {row['session_id']})"
                    )
                    broken = True
                elif ledger_ro_conn is not None:
                    session_row = ledger._fetch_session(ledger_ro_conn, row["session_id"])
                    if session_row is None:
                        pruned_skipped += 1
                    else:
                        live = ledger._build_receipt_data(ledger_ro_conn, session_row)
                        if ledger.canonical_json(live) != payload:
                            changed = _immutable_fields_changed(payload, live)
                            if changed:
                                # These fields are written once, at session start, and
                                # nothing in CAST updates them afterwards. Divergence
                                # here is not retention and not a backfill.
                                print(
                                    f"VERIFY-CHAIN: BROKEN (seq {seq}: session-data tamper detected"
                                    f" for {row['session_id']} — {', '.join(changed)})"
                                )
                                broken = True
                            else:
                                drifted += 1

            prev_stored_chain_hash = row["chain_hash"]

        if broken:
            return 1

        n = len(rows)
        notes = []
        if unverifiable:
            notes.append(f"{unverifiable} unverifiable (appended before receipts were stored)")
        if pruned_skipped:
            notes.append(f"{pruned_skipped} pruned-skipped")
        if drifted:
            notes.append(f"{drifted} drifted from live data")
        suffix = (", " + ", ".join(notes)) if notes else ""
        print(f"VERIFY-CHAIN: PASS ({n} links{suffix})")

        if unverifiable and getattr(args, "require_attestation", False):
            print(
                f"VERIFY-CHAIN: BROKEN ({unverifiable} of {n} links carry no stored receipt "
                f"and --require-attestation was given)"
            )
            return 1
        return 0

    finally:
        if ro_conn is not None:
            try:
                ro_conn.close()
            except Exception:
                pass
        if ledger_ro_conn is not None:
            try:
                ledger_ro_conn.close()
            except Exception:
                pass


# ── Subcommand: backfill ─────────────────────────────────────────────────────

def cmd_backfill(args: argparse.Namespace, ledger) -> int:
    """Append all sessions not yet in the chain, in deterministic order. Exit 0."""
    if ledger is None:
        print("cast-provenance-chain backfill: ledger module unavailable", file=sys.stderr)
        return 1

    db_path = _resolve_db_path(ledger, getattr(args, 'db', None) or "")
    ro_conn: Optional[sqlite3.Connection] = None
    rw: Optional[sqlite3.Connection] = None

    try:
        try:
            ro_conn = ledger._connect(db_path)
            rw = _open_rw(db_path)
            session_rows = ro_conn.execute(
                "SELECT id FROM sessions ORDER BY started_at ASC, rowid ASC"
            ).fetchall()
        except Exception as e:
            print(f"cast-provenance-chain backfill: error: {e}", file=sys.stderr)
            return 1

        appended = 0
        skipped = 0
        for s_row in session_rows:
            sid = s_row["id"]
            inserted = _append_session(ledger, ro_conn, rw, sid)
            if inserted:
                appended += 1
            else:
                skipped += 1

        try:
            chain_len = rw.execute("SELECT COUNT(*) FROM provenance_chain").fetchone()[0]
        except Exception:
            chain_len = "?"

        print(f"BACKFILL: {appended} appended, {skipped} already-present (chain length {chain_len})")
        return 0

    finally:
        if ro_conn is not None:
            try:
                ro_conn.close()
            except Exception:
                pass
        if rw is not None:
            try:
                rw.close()
            except Exception:
                pass


# ── Subcommand: status ───────────────────────────────────────────────────────

def cmd_status(args: argparse.Namespace, ledger) -> int:
    """Print chain health summary. Exit 0."""
    db_path = _resolve_db_path(ledger, getattr(args, 'db', None) or "")
    conn: Optional[sqlite3.Connection] = None

    try:
        try:
            conn = _open_ro(db_path)
            count_row = conn.execute("SELECT COUNT(*) AS c FROM provenance_chain").fetchone()
            chain_len = count_row["c"] if count_row else 0

            head_row = conn.execute(
                "SELECT session_id, chain_hash FROM provenance_chain ORDER BY seq DESC LIMIT 1"
            ).fetchone()
            head_chain_hash = head_row["chain_hash"] if head_row else "(empty)"
            last_session_id = head_row["session_id"] if head_row else "(none)"

            # Count rows whose session_id is no longer in sessions
            pruned_count = conn.execute(
                "SELECT COUNT(*) AS c FROM provenance_chain "
                "WHERE session_id NOT IN (SELECT id FROM sessions)"
            ).fetchone()
            pruned = pruned_count["c"] if pruned_count else 0
        except Exception as e:
            print(f"cast-provenance-chain status: error: {e}", file=sys.stderr)
            return 1

        print(f"Chain length:        {chain_len}")
        print(f"Head chain_hash:     {head_chain_hash}")
        print(f"Last session_id:     {last_session_id}")
        print(f"Pruned attestations: {pruned}")
        return 0

    finally:
        if conn is not None:
            try:
                conn.close()
            except Exception:
                pass


# ── Argument parsing ──────────────────────────────────────────────────────────

def _build_parser() -> argparse.ArgumentParser:
    # Shared --db flag as a parent parser so it's accepted before OR after subcommand.
    db_parent = argparse.ArgumentParser(add_help=False)
    db_parent.add_argument("--db", metavar="PATH", default=None, help="Override DB path")

    p = argparse.ArgumentParser(
        prog="cast-provenance-chain",
        description="Tamper-evident hash-chain of per-session A5 ledger digests (CAST v9 A7).",
        parents=[db_parent],
    )
    sub = p.add_subparsers(dest="subcommand", required=True)

    sp_append = sub.add_parser("append", help="Append a session to the chain", parents=[db_parent])
    sp_append.add_argument("session_id", help="Session ID to append")

    sp_verify = sub.add_parser(
        "verify", help="Verify chain integrity and session attestations", parents=[db_parent])
    sp_verify.add_argument(
        "--require-attestation", action="store_true",
        help="Exit 1 if any link carries no stored receipt (default: report the count and pass)",
    )
    sub.add_parser("backfill", help="Backfill all sessions into the chain", parents=[db_parent])
    sub.add_parser("status", help="Print chain health summary", parents=[db_parent])
    return p


# ── Main ──────────────────────────────────────────────────────────────────────

def main() -> int:
    parser = _build_parser()
    args = parser.parse_args()

    ledger = _load_ledger()

    if args.subcommand == "append":
        return cmd_append(args, ledger)
    elif args.subcommand == "verify":
        return cmd_verify(args, ledger)
    elif args.subcommand == "backfill":
        return cmd_backfill(args, ledger)
    elif args.subcommand == "status":
        return cmd_status(args, ledger)
    else:
        parser.print_help()
        return 1


if __name__ == "__main__":
    sys.exit(main())
