#!/usr/bin/env python3
"""
cast-snapshot.py — snapshot irreplaceable ~/.claude files to a dated directory.

Copies local-only CAST files that would be lost in a ~/.claude wipe to
~/Library/Application Support/cast/backups/cast-snapshot-YYYY-MM-DD/.
Retention: 7 daily + 4 weekly (ISO-week anchor).
Invokes cast-db-backup.py as a subprocess for WAL-safe DB backup.

Environment variables:
  CAST_BACKUP_ROOT — backup root dir (default: ~/Library/Application Support/cast/backups/)
  CAST_CLAUDE_DIR  — source dir (default: ~/.claude)

Subcommands:
  (none)              — run snapshot
  restore <date-or-dir> [--target DIR] [--force]
                      — restore snapshot into --target (default: ~/.claude)

JSON output (single line to stdout):
  Success: {"snapshot_path": "...", "files_copied": N, "retained": N, "pruned": N, "db_backup": {...}}
  Failure: {"snapshot_path": null, "error": "reason"}

Exit codes: 0=success, 1=error
"""
import os
import sys
import json
import glob
import shutil
import logging
import re
import subprocess
from datetime import date
from pathlib import Path
from cast_guard import safe_rmtree


# ---------------------------------------------------------------------------
# Path / logging helpers (mirrors cast-db-backup.py conventions)
# ---------------------------------------------------------------------------

def _resolve_paths() -> tuple[Path, Path, Path]:
    """Resolve backup root, claude dir, and log path from env or defaults."""
    backup_root = Path(
        os.environ.get(
            "CAST_BACKUP_ROOT",
            os.path.expanduser("~/Library/Application Support/cast/backups/"),
        )
    ).expanduser()
    claude_dir = Path(
        os.environ.get("CAST_CLAUDE_DIR", "~/.claude")
    ).expanduser()
    log_path = Path("~/.claude/logs/cast-snapshot.log").expanduser()
    return backup_root, claude_dir, log_path


def _setup_logging(log_path: Path) -> logging.Logger:
    """Configure file-based logger. Creates log dir if needed."""
    log_path.parent.mkdir(parents=True, exist_ok=True)
    logger = logging.getLogger("cast-snapshot")
    logger.setLevel(logging.ERROR)
    if not logger.handlers:
        handler = logging.FileHandler(str(log_path))
        handler.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(message)s"))
        logger.addHandler(handler)
    return logger


# ---------------------------------------------------------------------------
# Secrets exclusion
# ---------------------------------------------------------------------------

_SECRET_PATTERNS = re.compile(
    r"(\.env$|\.env\.|api_key|secret|credentials|\.pem$|\.key$|\.p12$|\.pfx$"
    r"|^(id_rsa|id_dsa|id_ecdsa|id_ed25519)$)",
    re.IGNORECASE,
)


def _is_secret(basename: str) -> bool:
    """Return True if the file basename looks like a secret and should be excluded."""
    return bool(_SECRET_PATTERNS.search(basename))


# ---------------------------------------------------------------------------
# File collection
# ---------------------------------------------------------------------------

def _collect_files(claude_dir: Path) -> list[Path]:
    """
    Return absolute paths to all files that should be snapshotted.
    Skips files that don't exist or match the secrets pattern.
    """
    candidates: list[Path] = []

    # Explicit single files
    for rel in ["config/pii-denylist-local.txt", "config/sync.json", "CLAUDE.md", "settings.local.json"]:
        p = claude_dir / rel
        if p.exists() and not _is_secret(p.name):
            candidates.append(p)

    # Glob patterns
    glob_patterns = [
        "projects/*/memory/*.md",
        "agent-memory-local/**/*.md",
        "rules/*.md",
        "agents/personal/*.md",
    ]
    for pattern in glob_patterns:
        for match in claude_dir.glob(pattern):
            if match.is_file() and not _is_secret(match.name):
                candidates.append(match)

    return candidates


# ---------------------------------------------------------------------------
# Snapshot
# ---------------------------------------------------------------------------

def _do_snapshot(backup_root: Path, claude_dir: Path) -> tuple[Path, int]:
    """
    Copy files from claude_dir into a dated snapshot directory.
    Returns (snapshot_dir, files_copied).
    Re-run on same day: the day dir is cleared first (guarded rmtree).
    """
    today_str = date.today().strftime("%Y-%m-%d")
    snapshot_dir = backup_root / f"cast-snapshot-{today_str}"

    # If the day dir already exists, wipe it to get a fresh snapshot.
    if snapshot_dir.exists():
        try:
            safe_rmtree(snapshot_dir, backup_root, label="snapshot-rotate")
        except RuntimeError as e:
            logging.getLogger("cast-snapshot").warning(f"snapshot-rotate blocked (safety guard): {e}")
        # If the guard blocked deletion, we fall through and merge into the
        # existing dir (safe — copy2 overwrites individual files).

    snapshot_dir.mkdir(parents=True, exist_ok=True)

    files = _collect_files(claude_dir)
    copied = 0
    logger = logging.getLogger("cast-snapshot")

    for src in files:
        try:
            rel = src.relative_to(claude_dir)
        except ValueError:
            logger.warning(f"skipping file outside claude_dir: {src}")
            continue

        dest = snapshot_dir / rel
        dest.parent.mkdir(parents=True, exist_ok=True)

        try:
            shutil.copy2(str(src), str(dest))
            copied += 1
        except OSError as e:
            logger.error(f"failed to copy {src}: {e}")

    return snapshot_dir, copied


# ---------------------------------------------------------------------------
# Retention (mirrors cast-db-backup.py _enforce_retention, adapted for dirs)
# ---------------------------------------------------------------------------

def _parse_date_from_snapshot_dir(dirpath: Path):
    """Extract date from cast-snapshot-YYYY-MM-DD dir name. Returns date or None."""
    name = dirpath.name  # cast-snapshot-YYYY-MM-DD
    try:
        date_part = name[len("cast-snapshot-"):]  # YYYY-MM-DD
        return date.fromisoformat(date_part)
    except (ValueError, IndexError):
        return None


def _enforce_retention(
    backup_root: Path, keep_daily: int = 7, keep_weekly: int = 4
) -> tuple[int, int]:
    """
    Retention: keep 7 most-recent dailies + up to 4 weekly anchors.

    Weekly anchor = the newest directory from each ISO week number that is NOT
    already represented in the 7 dailies, across the 4 most-recent distinct
    ISO weeks outside the daily window.

    Directories are sorted by name (ISO date = alphabetical = chronological).
    Each rmtree is guarded via _assert_safe_to_delete.

    Returns (retained_count, pruned_count).
    """
    pattern = str(backup_root / "cast-snapshot-????-??-??")
    all_dirs = sorted(
        d for d in glob.glob(pattern) if os.path.isdir(d)
    )  # ascending by ISO date

    if len(all_dirs) <= keep_daily:
        return len(all_dirs), 0

    # Directories to always keep: last `keep_daily` by sort order
    daily_window = set(all_dirs[-keep_daily:])

    # Older dirs — candidates for weekly anchor promotion
    older_dirs = all_dirs[:-keep_daily]

    # Collect ISO week numbers already represented in the daily window
    daily_weeks: set[int] = set()
    for d in daily_window:
        parsed = _parse_date_from_snapshot_dir(Path(d))
        if parsed:
            daily_weeks.add(parsed.isocalendar()[1])

    # Build weekly anchor set: newest dir from each distinct ISO week
    # not already in daily_weeks, up to keep_weekly distinct weeks
    week_to_newest: dict[int, str] = {}
    for d in older_dirs:
        parsed = _parse_date_from_snapshot_dir(Path(d))
        if parsed is None:
            continue
        iso_week = parsed.isocalendar()[1]
        if iso_week in daily_weeks:
            continue
        week_to_newest[iso_week] = d  # newer entries overwrite — sort is ascending

    sorted_weeks = sorted(week_to_newest.keys(), reverse=True)[:keep_weekly]
    weekly_anchor_set = {week_to_newest[w] for w in sorted_weeks}

    keep_set = daily_window | weekly_anchor_set

    logger = logging.getLogger("cast-snapshot")
    pruned = 0
    for d in all_dirs:
        if d not in keep_set:
            target = Path(d)
            try:
                safe_rmtree(target, backup_root, label="snapshot-retention")
                pruned += 1
            except RuntimeError as e:
                logger.warning(f"retention skip (safety guard): {e}")
            except OSError as e:
                logger.warning(f"failed to prune {d}: {e}")

    retained = len(keep_set)
    return retained, pruned


# ---------------------------------------------------------------------------
# DB backup via subprocess
# ---------------------------------------------------------------------------

def _invoke_db_backup() -> dict:
    """
    Call scripts/cast-db-backup.py via subprocess.
    Returns its parsed JSON output, or an error dict if it fails.
    """
    script_dir = Path(__file__).parent
    db_backup_script = script_dir / "cast-db-backup.py"

    if not db_backup_script.exists():
        return {"error": f"cast-db-backup.py not found at {db_backup_script}"}

    try:
        result = subprocess.run(
            [sys.executable, str(db_backup_script)],
            capture_output=True,
            text=True,
            timeout=60,
        )
        raw = result.stdout.strip()
        if raw:
            return json.loads(raw)
        return {"error": f"cast-db-backup.py produced no output (exit {result.returncode})"}
    except subprocess.TimeoutExpired:
        return {"error": "cast-db-backup.py timed out"}
    except json.JSONDecodeError as e:
        return {"error": f"cast-db-backup.py output was not valid JSON: {e}"}
    except Exception as e:
        return {"error": f"cast-db-backup.py invocation failed: {e}"}


# ---------------------------------------------------------------------------
# Restore subcommand
# ---------------------------------------------------------------------------

def _cmd_restore(
    snapshot_ref: str,
    target_dir: Path,
    backup_root: Path,
    force: bool,
) -> None:
    """
    Copy files from snapshot_ref into target_dir.

    snapshot_ref can be:
      - A date string YYYY-MM-DD → resolved to backup_root/cast-snapshot-YYYY-MM-DD
      - An absolute path or relative path to a snapshot dir

    Refuses to overwrite existing files unless --force.
    Each restored file is printed to stdout.
    Exits 1 on error.
    """
    logger = logging.getLogger("cast-snapshot")

    # Resolve snapshot directory
    candidate = Path(snapshot_ref)
    if not candidate.is_absolute():
        # Try as date
        try:
            date.fromisoformat(snapshot_ref)
            candidate = backup_root / f"cast-snapshot-{snapshot_ref}"
        except ValueError:
            candidate = Path(snapshot_ref).expanduser()

    if not candidate.exists() or not candidate.is_dir():
        print(json.dumps({"snapshot_path": None, "error": f"snapshot not found: {candidate}"}))
        sys.exit(1)

    target_dir.mkdir(parents=True, exist_ok=True)
    restored = 0

    for src in candidate.rglob("*"):
        if not src.is_file():
            continue
        if _is_secret(src.name):
            continue

        try:
            rel = src.relative_to(candidate)
        except ValueError:
            continue

        dest = target_dir / rel

        if dest.exists() and not force:
            print(f"  SKIP (exists, use --force to overwrite): {rel}", file=sys.stderr)
            continue

        # Guard: if --force overwrites, validate the destination is inside target_dir
        real_dest = os.path.realpath(str(dest))
        real_target = os.path.realpath(str(target_dir))
        if not real_dest.startswith(real_target + os.sep) and real_dest != real_target:
            logger.warning(f"SKIPPING restore — dest outside target: {real_dest}")
            continue

        dest.parent.mkdir(parents=True, exist_ok=True)
        try:
            shutil.copy2(str(src), str(dest))
            print(f"  restored: {rel}")
            restored += 1
        except OSError as e:
            logger.error(f"failed to restore {src}: {e}")

    print(json.dumps({"snapshot_path": str(candidate), "files_restored": restored}))
    sys.exit(0)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> None:
    backup_root, claude_dir, log_path = _resolve_paths()
    logger = _setup_logging(log_path)

    def _fail(msg: str) -> None:
        payload = json.dumps({"snapshot_path": None, "error": msg})
        print(payload)
        logger.error(msg)
        sys.exit(1)

    # ---- Subcommand dispatch ----
    args = sys.argv[1:]

    if args and args[0] == "restore":
        if len(args) < 2:
            _fail("restore requires a <date-or-dir> argument")

        snapshot_ref = args[1]
        rest = args[2:]

        target_dir = backup_root.parent / "restore-out"  # default fallback
        target_dir = Path("~/.claude").expanduser()       # real default
        force = False

        i = 0
        while i < len(rest):
            if rest[i] == "--target" and i + 1 < len(rest):
                target_dir = Path(rest[i + 1]).expanduser()
                i += 2
            elif rest[i] == "--force":
                force = True
                i += 1
            else:
                i += 1

        _cmd_restore(snapshot_ref, target_dir, backup_root, force)
        return  # _cmd_restore calls sys.exit

    # ---- Default: run snapshot ----
    try:
        snapshot_dir, files_copied = _do_snapshot(backup_root, claude_dir)
    except Exception as e:
        _fail(f"snapshot failed: {e}")
        return

    try:
        retained, pruned = _enforce_retention(backup_root)
    except Exception as e:
        _fail(f"retention error: {e}")
        return

    db_backup = _invoke_db_backup()

    print(json.dumps({
        "snapshot_path": str(snapshot_dir),
        "files_copied": files_copied,
        "retained": retained,
        "pruned": pruned,
        "db_backup": db_backup,
    }))
    sys.exit(0)


if __name__ == "__main__":
    main()
