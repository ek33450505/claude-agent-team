#!/usr/bin/env python3
"""
cast-db-backup.py — WAL-safe SQLite backup for cast.db

Uses Python's stdlib sqlite3.Connection.backup() API for a consistent,
WAL-safe snapshot. Filename: cast-db-YYYY-MM-DD.db (one per day, overwrites).
Retention: 7 daily + 4 weekly (ISO-week anchor = newest file from each week).

Environment variables:
  CAST_DB_PATH   — path to source DB (default: ~/.claude/cast.db)
  CAST_BACKUP_DIR — directory for backups (default: ~/.claude/backups)

JSON output (single line to stdout):
  Success: {"backup_path": "/abs/path/cast-db-YYYY-MM-DD.db",
            "size_bytes": N, "retained": N, "pruned": N}
  Failure: {"backup_path": null, "error": "reason"}

Exit codes: 0=success, 1=error
"""
import sqlite3
import os
import sys
import json
import glob
import logging
from datetime import date
from pathlib import Path


def _resolve_paths():
    """Resolve DB source, backup dir, and log paths from env or defaults."""
    db_src = Path(os.environ.get("CAST_DB_PATH", "~/.claude/cast.db")).expanduser()
    backup_dir = Path(os.environ.get("CAST_BACKUP_DIR", "~/.claude/backups")).expanduser()
    log_path = Path("~/.claude/logs/cast-db-backup.log").expanduser()
    return db_src, backup_dir, log_path


def _setup_logging(log_path: Path) -> logging.Logger:
    """Configure file-based logger. Creates log dir if needed."""
    log_path.parent.mkdir(parents=True, exist_ok=True)
    logger = logging.getLogger("cast-db-backup")
    logger.setLevel(logging.ERROR)
    if not logger.handlers:
        handler = logging.FileHandler(str(log_path))
        handler.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(message)s"))
        logger.addHandler(handler)
    return logger


def _do_backup(db_src: Path, backup_dir: Path) -> Path:
    """Perform WAL-safe backup via sqlite3.Connection.backup(). Returns dest path."""
    backup_dir.mkdir(parents=True, exist_ok=True)
    today_str = date.today().strftime("%Y-%m-%d")
    dest_path = backup_dir / f"cast-db-{today_str}.db"

    with sqlite3.connect(str(db_src), timeout=5) as src:
        with sqlite3.connect(str(dest_path), timeout=5) as dst:
            src.backup(dst)

    return dest_path


def _parse_date_from_filename(filepath: Path):
    """Extract date from cast-db-YYYY-MM-DD.db filename. Returns date or None."""
    stem = filepath.stem  # cast-db-YYYY-MM-DD
    try:
        date_part = stem[len("cast-db-"):]  # YYYY-MM-DD
        return date.fromisoformat(date_part)
    except (ValueError, IndexError):
        return None


def _enforce_retention(backup_dir: Path, keep_daily: int = 7, keep_weekly: int = 4):
    """
    Retention: keep 7 most-recent dailies + up to 4 weekly anchors.

    Weekly anchor = the newest file from each ISO week number that is NOT
    already represented in the 7 dailies, across the 4 most-recent distinct
    ISO weeks outside the daily window.

    Returns (retained_count, pruned_count).
    """
    pattern = str(backup_dir / "cast-db-*.db")
    all_files = sorted(glob.glob(pattern))  # ascending by ISO date (alphabetical = chronological)

    if len(all_files) <= keep_daily:
        return len(all_files), 0

    # Files to always keep: last `keep_daily` by sort order
    daily_window = set(all_files[-keep_daily:])

    # Older files — candidate for weekly anchor promotion
    older_files = all_files[:-keep_daily]

    # Collect ISO week numbers already represented in daily window
    daily_weeks = set()
    for f in daily_window:
        d = _parse_date_from_filename(Path(f))
        if d:
            daily_weeks.add(d.isocalendar()[1])  # ISO week number

    # Build weekly anchor set: newest file from each distinct ISO week
    # not already in daily_weeks, up to keep_weekly distinct weeks
    week_to_newest: dict[int, str] = {}
    for f in older_files:
        d = _parse_date_from_filename(Path(f))
        if d is None:
            continue
        iso_week = d.isocalendar()[1]
        if iso_week in daily_weeks:
            continue
        # newer files come later in sorted order — keep overwriting to get newest
        week_to_newest[iso_week] = f

    # Take the 4 most-recent distinct weeks (by ISO week number descending)
    sorted_weeks = sorted(week_to_newest.keys(), reverse=True)[:keep_weekly]
    weekly_anchor_set = {week_to_newest[w] for w in sorted_weeks}

    keep_set = daily_window | weekly_anchor_set

    _logger = logging.getLogger("cast-db-backup")
    pruned = 0
    for f in all_files:
        if f not in keep_set:
            try:
                os.remove(f)
                pruned += 1
            except OSError as e:
                _logger.warning(f"failed to prune {f}: {e}")

    retained = len(keep_set)
    return retained, pruned


def main():
    db_src, backup_dir, log_path = _resolve_paths()
    logger = _setup_logging(log_path)

    def _fail(msg: str) -> None:
        payload = json.dumps({"backup_path": None, "error": msg})
        print(payload)
        logger.error(msg)
        sys.exit(1)

    # Guard: source must exist
    if not db_src.exists():
        _fail(f"source not found: {db_src}")

    try:
        dest_path = _do_backup(db_src, backup_dir)
    except Exception as e:
        _fail(f"backup failed: {e}")
        return  # unreachable — keeps type checker happy

    try:
        size_bytes = dest_path.stat().st_size
        retained, pruned = _enforce_retention(backup_dir)
    except Exception as e:
        _fail(f"post-backup error: {e}")
        return

    print(json.dumps({
        "backup_path": str(dest_path),
        "size_bytes": size_bytes,
        "retained": retained,
        "pruned": pruned,
    }))
    sys.exit(0)


if __name__ == "__main__":
    main()
