#!/usr/bin/env python3
"""Unit tests for scripts/cast-db-backup.py's permission hardening (fix/394).

cast.db itself is deliberately chmod 600 (cast-db-init.sh), but
sqlite3.connect(dest) creates the backup destination as a brand-new file
subject to the process umask — pre-fix that left every backup (and its
-wal/-shm sidecars) world-readable (644) despite holding the full CAST
record (agent prompts, dispatch decisions, memories).

Loads cast-db-backup.py via importlib (hyphenated module name) so tests can
call _do_backup()/_harden_existing_backups() directly rather than parsing
subprocess JSON — the dispatch's required assertions name these functions
directly. Every source/backup DB is a throwaway built with tempfile; this
suite never touches the real ~/.claude/cast.db or the real backup dir.

Covers:
  1. _do_backup() leaves the destination file at exactly mode 0o600.
  2. Any -wal/-shm sidecar left behind is not group/world readable (and,
     per this fix's WAL-checkpoint design choice, should not exist at all).
  3. A chmod failure during hardening is logged, not fatal — the backup
     still returns a valid, existing path.
  4. _harden_existing_backups() self-heals a pre-existing 644 backup file
     (and its sidecars) found on a later run.
  5. backup_dir itself ends up chmod 0o700.
"""
import importlib.util
import logging
import os
import sqlite3
import stat
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

_SCRIPT_PATH = Path(__file__).parent.parent / 'scripts' / 'cast-db-backup.py'

_spec = importlib.util.spec_from_file_location('cast_db_backup', str(_SCRIPT_PATH))
cast_db_backup = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(cast_db_backup)


def _make_wal_source_db(path: str) -> None:
    """Build a small throwaway WAL-mode sqlite DB — mirrors cast.db's own
    journal_mode so the destination inherits WAL via the copied file header,
    which is precisely the mechanism that produces -wal/-shm sidecars."""
    conn = sqlite3.connect(path)
    try:
        conn.execute("PRAGMA journal_mode=WAL")
        conn.execute("CREATE TABLE agent_runs (id INTEGER PRIMARY KEY, agent TEXT)")
        conn.execute("INSERT INTO agent_runs (agent) VALUES ('backend-writer')")
        conn.commit()
    finally:
        conn.close()


class CastDbBackupPermissionsTest(unittest.TestCase):
    def setUp(self):
        self._tmpdir = tempfile.mkdtemp(prefix='cast-db-backup-test-')
        self.db_src = Path(self._tmpdir) / 'src.db'
        self.backup_dir = Path(self._tmpdir) / 'backups'
        _make_wal_source_db(str(self.db_src))
        # Force a permissive umask so a bug regresses to the real-world
        # default (022) rather than an accidentally-restrictive test shell.
        self._old_umask = os.umask(0o022)

    def tearDown(self):
        os.umask(self._old_umask)
        import shutil
        shutil.rmtree(self._tmpdir, ignore_errors=True)

    # 1. destination file mode is exactly 0o600 -------------------------------
    def test_do_backup_sets_dest_mode_0600(self):
        dest = cast_db_backup._do_backup(self.db_src, self.backup_dir)
        mode = stat.S_IMODE(dest.stat().st_mode)
        self.assertEqual(
            mode, 0o600,
            f"expected backup file mode 0o600, observed {oct(mode)}",
        )

    # 2a. real end-to-end run over a WAL source leaves no sidecar at all -----
    def test_do_backup_over_wal_source_leaves_no_sidecar(self):
        # Confirms the design choice (checkpoint + journal_mode=DELETE): a
        # real WAL-mode source backup collapses to one self-contained file.
        # NOTE: this assertion alone is NOT mutation-safe in an isolated
        # single-call unit test — CPython's refcounting GC closes `src`/`dst`
        # (and SQLite auto-checkpoints on close) the instant _do_backup()
        # returns and its locals go out of scope, regardless of whether the
        # explicit close()/PRAGMA calls are present. Verified by reverting
        # _do_backup to the pre-fix `with ... as conn:` (no explicit close,
        # no PRAGMA) body: this assertion still passed. The discriminating
        # assertion for requirement 2 is test 2b below, which drives
        # _secure_backup_file() directly against sidecars that already
        # exist on disk, independent of GC timing.
        dest = cast_db_backup._do_backup(self.db_src, self.backup_dir)
        for suffix in ("-wal", "-shm"):
            sidecar = Path(str(dest) + suffix)
            self.assertFalse(
                sidecar.exists(),
                f"expected no {suffix} sidecar after checkpoint, found {sidecar}",
            )

    # 2b. any sidecar that DOES exist on disk is never left world-readable --
    def test_secure_backup_file_chmods_existing_sidecars(self):
        self.backup_dir.mkdir(parents=True, exist_ok=True)
        dest = self.backup_dir / 'cast-db-2026-01-02.db'
        dest.write_bytes(b'placeholder db bytes')
        os.chmod(dest, 0o644)
        wal = Path(str(dest) + '-wal')
        wal.write_bytes(b'placeholder wal bytes')
        os.chmod(wal, 0o644)
        shm = Path(str(dest) + '-shm')
        shm.write_bytes(b'placeholder shm bytes')
        os.chmod(shm, 0o644)

        cast_db_backup._secure_backup_file(dest)

        for f in (dest, wal, shm):
            mode = stat.S_IMODE(f.stat().st_mode)
            self.assertEqual(
                mode, 0o600,
                f"expected {f.name} mode 0o600 after _secure_backup_file, observed {oct(mode)}",
            )

    # 3. a chmod failure during hardening must not lose the backup -----------
    def test_chmod_failure_is_non_fatal(self):
        real_chmod = os.chmod

        def _raising_chmod(path, mode):
            raise OSError("simulated permission denial")

        with mock.patch.object(cast_db_backup.os, 'chmod', side_effect=_raising_chmod):
            dest = cast_db_backup._do_backup(self.db_src, self.backup_dir)

        # backup must still have landed even though every chmod call failed
        self.assertTrue(dest.exists())
        # restore isn't strictly needed (mock.patch context already reverted
        # it) but assert real_chmod is usable for the next test's cleanup
        self.assertTrue(callable(real_chmod))

    # 4. self-heal corrects a pre-existing 644 backup on a later run ---------
    def test_harden_existing_backups_fixes_pre_existing_644_file(self):
        self.backup_dir.mkdir(parents=True, exist_ok=True)
        stale = self.backup_dir / 'cast-db-2026-01-01.db'
        stale.write_bytes(b'not a real sqlite file, just needs to exist')
        os.chmod(stale, 0o644)
        stale_wal = Path(str(stale) + '-wal')
        stale_wal.write_bytes(b'wal')
        os.chmod(stale_wal, 0o644)

        cast_db_backup._harden_existing_backups(self.backup_dir)

        self.assertEqual(stat.S_IMODE(stale.stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(stale_wal.stat().st_mode), 0o600)

    # 5. backup_dir itself ends up 0o700 --------------------------------------
    def test_backup_dir_mode_is_0700(self):
        cast_db_backup._do_backup(self.db_src, self.backup_dir)
        mode = stat.S_IMODE(self.backup_dir.stat().st_mode)
        self.assertEqual(
            mode, 0o700,
            f"expected backup_dir mode 0o700, observed {oct(mode)}",
        )


if __name__ == '__main__':
    unittest.main()

class TestLoggerEmitsWarnings(unittest.TestCase):
    """The non-fatal-failure contract depends on warnings being VISIBLE.

    Regression guard for a defect found in review 2026-09-05: the logger was
    set to ERROR while 8 of the 9 log calls in this module are `warning`, so
    every non-fatal failure it reports (chmod, checkpoint, self-heal,
    retention skips) was silently discarded. A "logged, never raised"
    contract that logs to nowhere is indistinguishable from no logging.
    """

    def test_warning_level_messages_reach_the_log_file(self):
        with tempfile.TemporaryDirectory() as td:
            log_path = Path(td) / "logs" / "cast-db-backup.log"
            # Drop any cached logger so setLevel/handlers are re-applied.
            logging.Logger.manager.loggerDict.pop("cast-db-backup", None)
            logger = cast_db_backup._setup_logging(log_path)
            logger.warning("CANARY-WARNING-MUST-APPEAR")
            for h in logger.handlers:
                h.flush()
            self.assertIn(
                "CANARY-WARNING-MUST-APPEAR",
                log_path.read_text(),
                "warning-level messages must reach the log file; if this fails "
                "the logger level has regressed above WARNING",
            )
