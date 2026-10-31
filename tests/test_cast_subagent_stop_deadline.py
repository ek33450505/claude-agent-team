#!/usr/bin/env python3
"""Tests for the shared monotonic SubagentStop deadline in cast_subagent_stop.

The hook is killed at 15 s; the full pass gets _HOOK_BUDGET_S (12 s). Every git call must
clamp to what is left, stages that would start after the deadline are skipped (stage17_tail
excepted), and the review record (stage8b) must still land a BLOCKED verdict when git is
unusable.

Isolated temp HOME + temp CAST_DB_PATH throughout; the repo under review is a temp git repo.
git is resolved by cast_git_safe from a fixed trusted-dir list (never PATH), so a PATH shim
cannot make it hang: the end-to-end test instead runs the real full pass in a child
interpreter whose cast_git_safe.run is replaced by a fake that blocks for its whole timeout
and then reports rc 124 (what the real primitive does on a hung git).
"""
import contextlib
import io
import json
import os
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import textwrap
import time
import unittest
from pathlib import Path
from unittest import mock

_REPO = Path(__file__).resolve().parent.parent
_SCRIPTS_DIR = str(_REPO / "scripts")
if _SCRIPTS_DIR not in sys.path:
    sys.path.insert(0, _SCRIPTS_DIR)

import cast_subagent_stop as css  # noqa: E402

_MIGRATION = _REPO / "scripts" / "migrations" / "037_review_snapshots.sql"
_MIGRATION_039 = _REPO / "scripts" / "migrations" / "039_review_mode_and_source.sql"


def _migrate(conn):
    """Apply 037 then 039 (mode column), tolerating re-runs as cast-migrate.py does."""
    conn.executescript(_MIGRATION.read_text())
    sql = "\n".join(l for l in _MIGRATION_039.read_text().splitlines() if not l.strip().startswith("--"))
    for body in (b.strip() for b in sql.split(";")):
        if not body:
            continue
        try:
            conn.execute(body)
        except sqlite3.OperationalError as exc:
            if "duplicate column" not in str(exc) and "no such table" not in str(exc):
                raise
BLOCK_TEXT = "Bad.\nVerdict: BLOCKED\nStatus: BLOCKED\n"
APPROVE_TEXT = "Looks fine.\nVerdict: APPROVE\nStatus: DONE\n"

# Child-interpreter driver: install a hanging cast_git_safe.run on BOTH git entry points
# (the hook's own loader and the review-snapshot module's), then run the real full pass.
_DRIVER = textwrap.dedent('''
    import subprocess, sys, time, types
    sys.path.insert(0, sys.argv[1])
    import cast_subagent_stop as css

    def hang(repo_dir, args, timeout=10.0):
        time.sleep(min(timeout, 30.0))  # a hung git waits out its whole cap
        return subprocess.CompletedProcess(["git"] + list(args), 124, "", "timed out")

    fake = types.SimpleNamespace(run=hang)
    css._GIT_SAFE_MOD = fake
    css._get_review_snapshot_module()._GIT_SAFE_MOD = fake
    sys.exit(css.main(["--stdin"]))
''')


class _Base(unittest.TestCase):
    def setUp(self):
        self.tmp = os.path.realpath(tempfile.mkdtemp(prefix="cast-dl-"))
        self.home = os.path.join(self.tmp, "home")
        os.makedirs(os.path.join(self.home, ".claude", "logs"))
        self.db = os.path.join(self.tmp, "cast.db")
        _env = mock.patch.dict(os.environ, {"HOME": self.home, "CAST_DB_PATH": self.db})
        _env.start()
        self.addCleanup(_env.stop)
        conn = sqlite3.connect(self.db)
        _migrate(conn)
        conn.close()
        self.repo = os.path.join(self.tmp, "repo")
        os.makedirs(self.repo)
        self.git("init", "-q")
        self.git("config", "commit.gpgsign", "false")
        with open(os.path.join(self.repo, "a.txt"), "wb") as fh:
            fh.write(b"a0\n")
        self.git("add", "-A")
        self.git("commit", "-q", "-m", "init")
        with open(os.path.join(self.repo, "a.txt"), "wb") as fh:
            fh.write(b"a1\n")
        self.addCleanup(self._cleanup)

    def _cleanup(self):
        assert self.tmp.startswith(os.path.realpath(tempfile.gettempdir()))
        shutil.rmtree(self.tmp, ignore_errors=True)

    def git(self, *args):
        env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
        env.update(GIT_CONFIG_NOSYSTEM="1", GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@t",
                   GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@t")
        r = subprocess.run(["git", "-C", self.repo] + list(args), env=env,
                           stdin=subprocess.DEVNULL, capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        return r.stdout.strip()

    def sidecar(self, agent_type, aid="ag1", sid="s1"):
        d = os.path.join(self.home, ".claude", "projects", "slug", sid, "subagents")
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, "agent-%s.meta.json" % aid), "w") as fh:
            json.dump({"agentType": agent_type, "name": agent_type + "__t"}, fh)

    def rows(self, sql):
        conn = sqlite3.connect(self.db)
        try:
            return conn.execute(sql).fetchall()
        finally:
            conn.close()

    def ctx(self, text, gate, aid="ag1", sid="s1"):
        c = css.Ctx()
        c.agent_name, c.agent_id, c.session_id = "code-reviewer", aid, sid
        c.output_full, c.gate_match, c.final_text = text, gate, text
        self.sidecar("code-reviewer", aid, sid)
        c.is_exempt = css.is_exempt_agent("code-reviewer")
        c.db_path = self.db
        c.data = {"cwd": self.repo}
        return c


class RunStageDeadlineTests(_Base):
    def test_stage_after_deadline_is_skipped_and_logged(self):
        calls = []
        with mock.patch.object(css, "_HOOK_DEADLINE", time.monotonic() - 1), \
                mock.patch.object(css, "_log_fail") as lf:
            css.run_stage("stageX_demo", lambda c: calls.append("x"), self.ctx(BLOCK_TEXT, "BLOCKED"))
        self.assertEqual(calls, [])
        lf.assert_called_once()
        self.assertEqual(lf.call_args[0][:3], ("stageX_demo", -1, "skipped: hook deadline"))

    def test_stage17_tail_runs_after_deadline(self):
        calls = []
        with mock.patch.object(css, "_HOOK_DEADLINE", time.monotonic() - 1), \
                mock.patch.object(css, "_log_fail") as lf:
            css.run_stage("stage17_tail", lambda c: calls.append("tail"), self.ctx(BLOCK_TEXT, "BLOCKED"))
        self.assertEqual(calls, ["tail"])
        lf.assert_not_called()

    def test_stage8b_runs_after_deadline_and_still_records_blocked(self):
        # Stages 0-1 overran: the review stage is exempt from the skip, self-clamps to a
        # zero git budget, and the BLOCKED verdict lands as a git-free degraded row.
        c = self.ctx(BLOCK_TEXT, "BLOCKED")
        mod = css._get_review_snapshot_module()
        with mock.patch.object(css, "_HOOK_DEADLINE", time.monotonic() - 1), \
                mock.patch.object(css, "_log_fail") as lf, \
                mock.patch.object(mod, "_git", side_effect=AssertionError("git must not run")):
            css.run_stage("stage8b_review_snapshot", css.stage8b_review_snapshot, c)
        self.assertNotIn("skipped: hook deadline", [a[0][2] for a in lf.call_args_list])
        self.assertEqual(self.rows("SELECT decision, scope FROM review_snapshots"),
                         [("BLOCKED", "repo")])

    def test_stage_runs_when_deadline_unset_or_live(self):
        calls = []
        c = self.ctx(BLOCK_TEXT, "BLOCKED")
        with mock.patch.object(css, "_HOOK_DEADLINE", None):
            css.run_stage("stageX_demo", lambda _c: calls.append("unset"), c)
        with mock.patch.object(css, "_HOOK_DEADLINE", time.monotonic() + 60):
            css.run_stage("stageX_demo", lambda _c: calls.append("live"), c)
        self.assertEqual(calls, ["unset", "live"])

    def test_git_safe_run_spent_deadline_does_not_spawn(self):
        fake = mock.Mock()
        with mock.patch.object(css, "_HOOK_DEADLINE", time.monotonic() - 1), \
                mock.patch.object(css, "_GIT_SAFE_MOD", fake):
            r = css._git_safe_run(self.repo, ["rev-parse", "HEAD"], timeout=5)
        self.assertNotEqual(r.returncode, 0)
        fake.run.assert_not_called()

    def test_git_safe_run_clamps_timeout_to_remaining(self):
        fake = mock.Mock()
        fake.run.return_value = subprocess.CompletedProcess(["git"], 0, "x\n", "")
        with mock.patch.object(css, "_HOOK_DEADLINE", time.monotonic() + 2.0), \
                mock.patch.object(css, "_GIT_SAFE_MOD", fake):
            css._git_safe_run(self.repo, ["rev-parse", "HEAD"], timeout=5)
        self.assertLessEqual(fake.run.call_args.kwargs["timeout"], 2.0)


class RedactSubprocessClampTests(_Base):
    """_redact_excerpt_verbose subprocess fallback (in-process redact module unavailable)."""

    def _call(self, deadline, run):
        with mock.patch.object(css, "_HOOK_DEADLINE", deadline), \
                mock.patch.object(css, "_get_redact_module", return_value=None), \
                mock.patch.object(css.subprocess, "run", run):
            return css._redact_excerpt_verbose("some text")

    @staticmethod
    def _ok_run():
        return mock.Mock(return_value=subprocess.CompletedProcess(
            ["python3"], 0, b'{"redacted_text": "redacted"}', b""))

    def test_spent_deadline_fails_closed_without_spawning(self):
        run = self._ok_run()
        self.assertEqual(self._call(time.monotonic() - 1, run), (None, "HookDeadline"))
        run.assert_not_called()

    def test_partial_deadline_clamps_subprocess_timeout(self):
        run = self._ok_run()
        self.assertEqual(self._call(time.monotonic() + 1.5, run), ("redacted", None))
        self.assertLessEqual(run.call_args.kwargs["timeout"], 1.5)

    def test_no_deadline_keeps_the_5s_cap(self):
        run = self._ok_run()
        self.assertEqual(self._call(None, run), ("redacted", None))
        self.assertEqual(run.call_args.kwargs["timeout"], 5.0)


class Stage8bSpentBudgetTests(_Base):
    def _count_git(self):
        # The hook loads its OWN cast_review_snapshot instance (by realpath), so patch that one.
        return mock.patch.object(css._get_review_snapshot_module(), "_git",
                                 side_effect=AssertionError("git must not run"))

    def test_blocked_with_spent_budget_writes_degraded_row_without_git(self):
        c = self.ctx(BLOCK_TEXT, "BLOCKED")
        with mock.patch.object(css, "_HOOK_DEADLINE", time.monotonic() - 1), self._count_git() as g:
            css.stage8b_review_snapshot(c)
        g.assert_not_called()
        self.assertEqual(
            self.rows("SELECT decision, scope, reviewer, repo_root FROM review_snapshots"),
            [("BLOCKED", "repo", "code-reviewer", os.path.realpath(self.repo))])

    def test_approve_with_spent_budget_is_not_recorded(self):
        c = self.ctx(APPROVE_TEXT, "DONE")
        with mock.patch.object(css, "_HOOK_DEADLINE", time.monotonic() - 1), self._count_git():
            css.stage8b_review_snapshot(c)
        self.assertEqual(self.rows("SELECT count(*) FROM review_snapshots"), [(0,)])

    def test_partial_budget_caps_git_to_remaining(self):
        seen = []

        def fake_git(repo_dir, args, timeout=30.0):
            seen.append(timeout)
            return subprocess.CompletedProcess(["git"], 124, "", "timed out")

        c = self.ctx(BLOCK_TEXT, "BLOCKED")
        with mock.patch.object(css, "_HOOK_DEADLINE", time.monotonic() + 1.5), \
                mock.patch.object(css._get_review_snapshot_module(), "_git", side_effect=fake_git):
            css.stage8b_review_snapshot(c)
        self.assertTrue(seen)
        self.assertTrue(all(t <= 1.5 for t in seen), seen)
        # git failed within the budget, BLOCK still recorded (degraded, cwd realpath root)
        self.assertEqual(self.rows("SELECT decision, scope FROM review_snapshots"),
                         [("BLOCKED", "repo")])


class MainOrderingTests(_Base):
    def _payload(self):
        return json.dumps({"agent_type": "code-reviewer", "agent_id": "ag1", "session_id": "s1",
                           "cwd": self.repo, "last_assistant_message": BLOCK_TEXT})

    def _run_main(self, args):
        names, seen = [], []

        def record(n, f, c):
            names.append(n)
            seen.append(css._HOOK_DEADLINE)

        self.sidecar("code-reviewer")
        with mock.patch.object(css, "_HOOK_DEADLINE", None), \
                mock.patch.object(css, "_read_stdin_payload", return_value=self._payload()), \
                mock.patch.object(css, "run_stage", side_effect=record), \
                contextlib.redirect_stdout(io.StringIO()):
            css.main(args)
        return names, (seen[0] if seen else None)

    def test_review_record_runs_before_slow_stages_and_tail_last(self):
        names, _ = self._run_main(["--stdin"])
        self.assertIn("stage8b_review_snapshot", names)
        i8b = names.index("stage8b_review_snapshot")
        for slow in ("stage2_transcript_cost", "stage9_claimed_work", "stage10_facts_write"):
            self.assertLess(i8b, names.index(slow), slow)
        self.assertEqual(names[0], "stage0_fast_write")
        self.assertEqual(names[-1], "stage17_tail")

    def test_full_pass_arms_deadline_during_stages_and_gate_only_does_not(self):
        _, full = self._run_main(["--stdin"])
        self.assertIsNotNone(full)
        self.assertLess(abs((full - time.monotonic()) - css._HOOK_BUDGET_S), 2.0)
        names, gate = self._run_main(["--stdin", "--gate-only"])
        self.assertIsNone(gate)
        self.assertEqual(names, [])  # --gate-only runs no stages

    def _unpatched_main(self, args):
        """Real stages, real global: only stdin is faked. Returns the global afterwards."""
        self.sidecar("code-reviewer")
        self.assertIsNone(css._HOOK_DEADLINE)
        with mock.patch.object(css, "_read_stdin_payload", return_value=self._payload()), \
                contextlib.redirect_stdout(io.StringIO()) as out:
            css.main(args)
        return css._HOOK_DEADLINE, out.getvalue()

    def test_full_pass_leaves_deadline_disarmed_for_later_callers(self):
        after, out = self._unpatched_main(["--stdin"])
        self.assertIn("__CAST_TAIL_END__", out)  # the real full pass ran
        self.assertIsNone(after)

    def test_gate_only_after_full_pass_stays_disarmed(self):
        self._unpatched_main(["--stdin"])
        after, out = self._unpatched_main(["--stdin", "--gate-only"])
        self.assertIsNone(after)
        self.assertNotIn("CAST_SUCCESSORS", out)

    def test_deadline_disarmed_even_when_pass_raises(self):
        with mock.patch.object(css, "_read_stdin_payload", side_effect=RuntimeError("boom")):
            with self.assertRaises(RuntimeError):
                css.main(["--stdin"])
        self.assertIsNone(css._HOOK_DEADLINE)


class FullPassEndToEndTests(_Base):
    def test_hung_git_full_pass_finishes_inside_hook_timeout(self):
        # No start snapshot -> BLOCKED can only land as a degraded row.
        self.sidecar("code-reviewer")
        payload = {"hook_event_name": "SubagentStop", "agent_type": "code-reviewer",
                   "agent_id": "ag1", "session_id": "s1", "cwd": self.repo,
                   "last_assistant_message": BLOCK_TEXT}
        driver = os.path.join(self.tmp, "driver.py")
        with open(driver, "w") as fh:
            fh.write(_DRIVER)
        env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
        env.update(HOME=self.home, CAST_DB_PATH=self.db)
        t0 = time.monotonic()
        r = subprocess.run([sys._base_executable, "-I", driver, _SCRIPTS_DIR, "--stdin"],
                           input=json.dumps(payload), capture_output=True, text=True,
                           env=env, timeout=60, cwd=self.tmp)
        elapsed = time.monotonic() - t0
        self.assertEqual(r.returncode, 0, r.stderr)
        # 15 s is the hook kill; the gate-only pass + startup use the rest. Unbounded ~20 s+.
        self.assertLess(elapsed, 14.0, "full pass took %.1fs" % elapsed)
        # stage17_tail still emitted the block the wrapper evals, with the successors var.
        self.assertIn("__CAST_TAIL_BEGIN__", r.stdout)
        self.assertIn("CAST_SUCCESSORS=", r.stdout)
        self.assertIn("__CAST_TAIL_END__", r.stdout)
        # stage8b ran first and recorded the BLOCK (no git usable -> degraded repo-scope row).
        self.assertEqual(
            self.rows("SELECT decision, scope, repo_root FROM review_snapshots"),
            [("BLOCKED", "repo", os.path.realpath(self.repo))])
        # later stages that would have started past the deadline were skipped + logged.
        skipped = self.rows("SELECT hook_name FROM hook_failures WHERE stderr = 'skipped: hook deadline'")
        self.assertTrue(skipped, "expected at least one stage skipped by the hook deadline")
        for exempt in ("stage17_tail", "stage8b_review_snapshot"):
            self.assertFalse([h for (h,) in skipped if h.endswith(":" + exempt)], skipped)


if __name__ == "__main__":
    unittest.main()
