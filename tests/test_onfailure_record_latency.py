#!/usr/bin/env python3
"""Latency + crash-safety tests for the PreToolUse hooks now wired with onFailure:block.

With `"onFailure": "block"` and `"timeout": 5`, a hook that times out or exits non-0/2
BLOCKS the tool call. So every RECORD-ONLY / ADVISORY wait must stay well under 5 s even
when cast.db is locked, and an unexpected crash in a guard script must exit 0 (fail-open)
rather than 1:

  - write-guards.py  : no-fake-success advisory record (sqlite wait), crash -> exit 0
  - cast-pretool-dispatch.py : _record_dispatch (sqlite + redaction wait) and the
    guard-load-failure record (_record_guard_failure -> cast_db, bounded by cast_db.deadline)

Each test holds `BEGIN EXCLUSIVE` on a temp cast.db in THIS process and runs the hook as a
subprocess, asserting exit 0 and wall time < LIMIT_S. Isolation: temp HOME + temp
CAST_DB_PATH under it; the real ~/.claude is never touched.
"""
import json
import os
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import time
import unittest

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPTS = os.path.join(REPO, "scripts")
WRITE_GUARDS = os.path.join(SCRIPTS, "write-guards.py")
DISPATCH = os.path.join(SCRIPTS, "cast-pretool-dispatch.py")

LIMIT_S = 3.0  # hook timeout is 5 s; leave real headroom for interpreter start-up

# Minimal copies of the cast-db-init.sh tables these paths write.
SCHEMA = """
CREATE TABLE IF NOT EXISTS quality_gates (
  id TEXT PRIMARY KEY, session_id TEXT, agent_name TEXT, timestamp TEXT,
  status_line TEXT, contract_passed INTEGER, retry_count INTEGER, gate_type TEXT,
  created_at TEXT DEFAULT (datetime('now')));
CREATE TABLE IF NOT EXISTS hook_failures (
  id TEXT PRIMARY KEY, hook_name TEXT NOT NULL, exit_code INTEGER, stderr TEXT,
  session_id TEXT, timestamp TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS dispatch_decisions (
  id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT, prompt_snippet TEXT,
  chosen_agent TEXT, model TEXT, created_at TEXT DEFAULT (datetime('now')),
  outcome TEXT DEFAULT 'pending', dispatch_name TEXT);
"""

FAKE_SUCCESS_PY = (
    "def load():\n"
    "    try:\n"
    "        return fetch()\n"
    "    except Exception:\n"
    "        return sample_data\n"
)


class _HookCase(unittest.TestCase):
    def setUp(self):
        self.home = tempfile.mkdtemp(prefix="onfailure-latency-")
        self.addCleanup(shutil.rmtree, self.home, True)
        os.makedirs(os.path.join(self.home, ".claude", "config"))
        os.makedirs(os.path.join(self.home, ".claude", "logs"))
        shutil.copy(os.path.join(REPO, "config", "egress-policy.json"),
                    os.path.join(self.home, ".claude", "config", "egress-policy.json"))
        self.db = os.path.join(self.home, ".claude", "cast.db")
        setup = sqlite3.connect(self.db)
        setup.executescript(SCHEMA)
        setup.commit()
        setup.close()
        self.env = {
            "HOME": self.home,
            "CAST_DB_PATH": self.db,
            "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
            "PYTHONDONTWRITEBYTECODE": "1",
        }

    def lock_db(self):
        holder = sqlite3.connect(self.db, isolation_level=None, timeout=1)
        holder.execute("BEGIN EXCLUSIVE")
        self.addCleanup(holder.close)
        return holder

    def run_hook(self, script, payload, cwd=None):
        t0 = time.monotonic()
        try:
            proc = subprocess.run(
                [sys.executable, "-B", "-E", "-s", script],
                input=payload if isinstance(payload, str) else json.dumps(payload),
                capture_output=True, text=True, env=self.env,
                cwd=cwd or self.home, timeout=12,
            )
        except subprocess.TimeoutExpired:
            self.fail(f"{os.path.basename(script)} did not finish in 12 s (hook timeout is 5 s)")
        return proc, time.monotonic() - t0


class WriteGuardsOnFailure(_HookCase):
    def test_advisory_record_under_locked_db_is_fast_and_allows(self):
        self.lock_db()
        proc, dt = self.run_hook(WRITE_GUARDS, {
            "tool_name": "Write",
            "tool_input": {"file_path": os.path.join(self.home, "mod.py"),
                           "content": FAKE_SUCCESS_PY},
        })
        self.assertEqual(proc.returncode, 0, proc.stderr)
        # the advisory fired (so the sqlite path really ran), it did not block
        self.assertIn("FAKE-SUCCESS WARN", proc.stdout)
        self.assertLess(dt, LIMIT_S, f"advisory record took {dt:.2f}s under a locked cast.db")

    def test_empty_list_payload_exits_zero_and_logs_class_only(self):
        proc, _ = self.run_hook(WRITE_GUARDS, "[]")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        log = os.path.join(self.home, ".claude", "logs", "hook-errors.log")
        self.assertTrue(os.path.isfile(log), "catch-all wrote no hook-errors.log line")
        with open(log) as fh:
            text = fh.read()
        self.assertIn("write-guards.py: unexpected AttributeError", text)
        self.assertNotIn("has no attribute", text)  # class name only, never str(exc)

    def test_null_file_path_exits_zero(self):
        proc, _ = self.run_hook(WRITE_GUARDS, {
            "tool_name": "Write", "tool_input": {"file_path": None, "content": "x"}})
        self.assertEqual(proc.returncode, 0, proc.stderr)

    def _hung_git_env(self):
        stub_dir = os.path.join(self.home, "stubbin")
        os.makedirs(stub_dir, exist_ok=True)
        stub = os.path.join(stub_dir, "git")
        with open(stub, "w") as fh:
            fh.write("#!/bin/sh\nsleep 3\n")
        os.chmod(stub, 0o755)
        self.env["PATH"] = stub_dir + os.pathsep + self.env["PATH"]

    def test_stat_guard_count_timeout_blocks_honestly(self):
        # `git` stub sleeps past the 1.5 s count timeout: the badge claim cannot be
        # verified, so the write is blocked (exit 2) with an honest message -- NOT the
        # misleading "actual @test count is 0".
        self._hung_git_env()
        proc, dt = self.run_hook(WRITE_GUARDS, {
            "tool_name": "Write",
            "tool_input": {"file_path": os.path.join(self.home, "README.md"),
                           "content": "![badge](https://img.shields.io/badge/tests-123-green)\n"},
        })
        self.assertEqual(proc.returncode, 2, proc.stderr)
        out = proc.stdout + proc.stderr
        self.assertIn("Could not count", out)
        self.assertNotIn("actual @test count is 0", out)
        self.assertLess(dt, LIMIT_S, f"stat-guard took {dt:.2f}s with a hung git")

    def test_stat_guard_nonzero_git_exit_blocks_honestly(self):
        # Real git, cwd is a temp dir that is NOT a git repo: `git ls-files` exits non-zero.
        # That is "could not count", not "zero tests".
        self.env["GIT_CEILING_DIRECTORIES"] = os.path.dirname(self.home)
        proc, _ = self.run_hook(WRITE_GUARDS, {
            "tool_name": "Write",
            "tool_input": {"file_path": os.path.join(self.home, "README.md"),
                           "content": "![badge](https://img.shields.io/badge/tests-123-green)\n"},
        }, cwd=self.home)
        self.assertEqual(proc.returncode, 2, proc.stderr)
        out = proc.stdout + proc.stderr
        self.assertIn("Could not count", out)
        self.assertNotIn("actual @test count is 0", out)

    def test_stat_guard_hung_git_without_a_claim_is_allowed(self):
        self._hung_git_env()
        proc, _ = self.run_hook(WRITE_GUARDS, {
            "tool_name": "Write",
            "tool_input": {"file_path": os.path.join(self.home, "README.md"),
                           "content": "# Project\n\nSee the test suite for details.\n"},
        })
        self.assertEqual(proc.returncode, 0, proc.stderr)

    def test_intentional_block_still_exits_two(self):
        proc, _ = self.run_hook(WRITE_GUARDS, {
            "tool_name": "Write",
            "tool_input": {"file_path": "/work/~/x.txt", "content": "x"}})
        self.assertEqual(proc.returncode, 2, proc.stderr)
        self.assertIn("literal-tilde", proc.stderr)


class CastDbDeadlineNesting(unittest.TestCase):
    def test_inner_deadline_never_extends_outer_and_restores(self):
        sys.path.insert(0, SCRIPTS)
        try:
            import cast_db
        finally:
            sys.path.remove(SCRIPTS)
        self.assertIsNone(cast_db._DEADLINE)
        with cast_db.deadline(0.3):
            outer = cast_db._DEADLINE
            with cast_db.deadline(60):
                self.assertEqual(cast_db._DEADLINE, outer)   # larger inner budget ignored
                self.assertLessEqual(cast_db._deadline_left(), 0.3)
            self.assertEqual(cast_db._DEADLINE, outer)       # restored after inner exit
            with cast_db.deadline(0.01):
                self.assertLess(cast_db._DEADLINE, outer)    # tighter inner budget honoured
        self.assertIsNone(cast_db._DEADLINE)                 # restored after outer exit


class CastDbDeadlineBound(_HookCase):
    """In-process, tight-bound check that cast_db.deadline() is ONE wait, not two.

    The subprocess tests above keep a loose 3.0 s tripwire (slow CI). This one pins the
    mechanism: under a DELETE-journal DB held BEGIN EXCLUSIVE, `PRAGMA journal_mode` and
    `PRAGMA synchronous` each took their own busy wait, so deadline(0.5) cost ~1.0 s+.
    Fixed it is ~0.5 s."""

    def test_deadline_is_one_wait_not_two(self):
        import importlib.util
        from unittest import mock
        with mock.patch.dict(os.environ, {"HOME": self.home, "CAST_DB_PATH": self.db}):
            spec = importlib.util.spec_from_file_location(
                "cast_db_deadline_probe", os.path.join(SCRIPTS, "cast_db.py"))
            cast_db = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(cast_db)
            self.lock_db()
            t0 = time.monotonic()
            with cast_db.deadline(0.5):
                # the calls _record_guard_failure makes; each swallows its own locked error
                cast_db.ensure_hook_failures_table()
                cast_db.db_query("SELECT 1 FROM hook_failures LIMIT 1")
                cast_db.log_hook_failure("probe", -1, "e", "s")
            elapsed = time.monotonic() - t0
        self.assertGreaterEqual(elapsed, 0.4, "deadline did not wait at all")
        self.assertLess(elapsed, 0.8, f"deadline(0.5) took {elapsed:.2f}s (double busy wait?)")


class DispatcherOnFailure(_HookCase):
    def test_agent_dispatch_record_under_locked_db_is_fast_and_allows(self):
        self.lock_db()
        proc, dt = self.run_hook(DISPATCH, {
            "tool_name": "Agent",
            "tool_input": {"prompt": "hi", "subagent_type": "x", "description": "d"},
            "session_id": "latency-sess",
        })
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertLess(dt, LIMIT_S, f"dispatch record took {dt:.2f}s under a locked cast.db")

    def test_guard_load_failure_record_under_locked_db_is_fast_and_allows(self):
        # Run a COPY of the scripts the dispatcher needs, with command-guard replaced by a
        # module that raises on import -> _load() fails -> _record_guard_failure() runs.
        scripts = os.path.join(self.home, "scripts-copy")
        os.makedirs(scripts)
        for name in ("cast-pretool-dispatch.py", "cast_db.py", "cast-git-guard.py",
                     "cast-egress-sentinel.py"):
            shutil.copy(os.path.join(SCRIPTS, name), os.path.join(scripts, name))
        with open(os.path.join(scripts, "cast-command-guard.py"), "w") as fh:
            fh.write("raise RuntimeError('simulated guard load failure')\n")
        self.lock_db()
        proc, dt = self.run_hook(os.path.join(scripts, "cast-pretool-dispatch.py"), {
            "tool_name": "Bash", "tool_input": {"command": "echo hi"},
            "session_id": "guardfail-latency-sess",
        })
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertLess(dt, LIMIT_S,
                        f"guard-failure record took {dt:.2f}s under a locked cast.db")

    def test_guard_load_failure_is_recorded_when_db_is_free(self):
        # Discriminator for the test above: with no lock the failure path really writes
        # its row, so the fast result under a lock is the deadline, not a skipped path.
        scripts = os.path.join(self.home, "scripts-copy")
        os.makedirs(scripts)
        for name in ("cast-pretool-dispatch.py", "cast_db.py", "cast-git-guard.py",
                     "cast-egress-sentinel.py"):
            shutil.copy(os.path.join(SCRIPTS, name), os.path.join(scripts, name))
        with open(os.path.join(scripts, "cast-command-guard.py"), "w") as fh:
            fh.write("raise RuntimeError('simulated guard load failure')\n")
        proc, _ = self.run_hook(os.path.join(scripts, "cast-pretool-dispatch.py"), {
            "tool_name": "Bash", "tool_input": {"command": "echo hi"},
            "session_id": "guardfail-free-sess",
        })
        self.assertEqual(proc.returncode, 0, proc.stderr)
        conn = sqlite3.connect(self.db)
        try:
            n = conn.execute("SELECT COUNT(*) FROM hook_failures "
                             "WHERE hook_name LIKE 'cast-pretool-dispatch/%'").fetchone()[0]
        finally:
            conn.close()
        self.assertGreaterEqual(n, 1)


if __name__ == "__main__":
    unittest.main()
