#!/usr/bin/env python3
"""Tests for cast_subagent_stop.stage8b_review_snapshot (content-bound review gate, U1b).

Isolated temp HOME + temp CAST_DB_PATH; the repo under review is a temp git repo.
"""
import json
import os
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

_REPO = Path(__file__).resolve().parent.parent
_SCRIPTS_DIR = str(_REPO / "scripts")
if _SCRIPTS_DIR not in sys.path:
    sys.path.insert(0, _SCRIPTS_DIR)

import cast_subagent_stop as css  # noqa: E402
import cast_review_snapshot as crs  # noqa: E402

_MIGRATION = _REPO / "scripts" / "migrations" / "037_review_snapshots.sql"
APPROVE_TEXT = "Looks fine.\nVerdict: APPROVE\nStatus: DONE\n"
BLOCK_TEXT = "Bad.\nVerdict: BLOCKED\nStatus: BLOCKED\n"


class Stage8bTests(unittest.TestCase):
    def setUp(self):
        self.tmp = os.path.realpath(tempfile.mkdtemp(prefix="cast-8b-"))
        self.home = os.path.join(self.tmp, "home")
        os.makedirs(os.path.join(self.home, ".claude", "logs"))
        self.db = os.path.join(self.tmp, "cast.db")
        # patch.dict snapshots os.environ and restores it wholesale on stop.
        _env = mock.patch.dict(os.environ, {"HOME": self.home, "CAST_DB_PATH": self.db})
        _env.start()
        self.addCleanup(_env.stop)
        conn = sqlite3.connect(self.db)
        conn.executescript(_MIGRATION.read_text())
        conn.close()
        self.repo = os.path.join(self.tmp, "repo")
        os.makedirs(self.repo)
        self.git("init", "-q")
        self.git("config", "commit.gpgsign", "false")
        self.write("a.txt", b"a0\n")
        self.write("b.txt", b"b0\n")
        self.git("add", "-A")
        self.git("commit", "-q", "-m", "init")
        self.write("a.txt", b"a1\n")
        self.write("b.txt", b"b1\n")
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

    def write(self, rel, content):
        with open(os.path.join(self.repo, rel), "wb") as fh:
            fh.write(content)

    def blob(self, rel):
        return self.git("hash-object", "--", rel)

    def start(self, agent="code-reviewer", aid="ag1", sid="s1"):
        crs.main(["start", "--agent-id", aid, "--session-id", sid,
                  "--reviewer", crs.is_reviewer(agent) or agent, "--cwd", self.repo])

    def sidecar(self, agent_type, name, aid="ag1", sid="s1"):
        """Claude Code's meta.json for a named regular subagent (shape 4)."""
        d = os.path.join(self.home, ".claude", "projects", "slug", sid, "subagents")
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, "agent-%s.meta.json" % aid), "w") as fh:
            json.dump({"agentType": agent_type, "name": name}, fh)

    def ctx(self, text, gate, agent="code-reviewer", aid="ag1", sid="s1", db=None, roster="auto"):
        c = css.Ctx()
        c.agent_name, c.agent_id, c.session_id = agent, aid, sid
        c.output_full, c.gate_match, c.final_text = text, gate, text
        if roster == "auto":
            roster = crs.is_reviewer(agent)
        if roster:
            self.sidecar(roster, agent if agent != roster else roster + "__t", aid, sid)
        c.is_exempt = css.is_exempt_agent(agent)
        c.db_path = db or self.db
        c.data = {"cwd": self.repo}
        return c

    def rows(self, sql):
        conn = sqlite3.connect(self.db)
        try:
            return conn.execute(sql).fetchall()
        finally:
            conn.close()

    def log(self):
        p = os.path.join(self.home, ".claude", "logs", "hook-errors.log")
        if not os.path.isfile(p):
            return ""
        with open(p) as fh:
            return fh.read()

    def test_approve_unchanged_files_recorded_with_blob(self):
        self.start()
        css.stage8b_review_snapshot(self.ctx(APPROVE_TEXT, "DONE"))
        self.assertEqual(self.rows("SELECT decision, scope, reviewer, repo_root FROM review_snapshots"),
                         [("APPROVE", "files", "code-reviewer", self.repo)])
        self.assertEqual(dict(self.rows("SELECT path, blob FROM review_snapshot_files")),
                         {"a.txt": self.blob("a.txt"), "b.txt": self.blob("b.txt")})

    def test_file_edited_during_review_not_approved(self):
        self.start()
        self.write("a.txt", b"edited during review\n")
        css.stage8b_review_snapshot(self.ctx(APPROVE_TEXT, "DONE"))
        paths = [r[0] for r in self.rows("SELECT path FROM review_snapshot_files")]
        self.assertEqual(paths, ["b.txt"])

    def test_approve_without_start_records_nothing_and_logs(self):
        css.stage8b_review_snapshot(self.ctx(APPROVE_TEXT, "DONE"))
        self.assertEqual(self.rows("SELECT * FROM review_snapshots"), [])
        self.assertIn("no start snapshot", self.log())

    def test_blocked_covers_start_union_stop_including_superseded_values(self):
        self.start()
        old_a = self.blob("a.txt")
        self.write("a.txt", b"changed mid review\n")
        self.write("c.txt", b"new\n")
        css.stage8b_review_snapshot(self.ctx(BLOCK_TEXT, "BLOCKED"))
        got = self.rows("SELECT s.decision, f.path, f.blob FROM review_snapshots s "
                        "JOIN review_snapshot_files f ON f.snapshot_id = s.id")
        self.assertTrue(all(r[0] == "BLOCKED" for r in got))
        pairs = {(r[1], r[2]) for r in got}
        self.assertIn(("a.txt", old_a), pairs)
        self.assertIn(("a.txt", self.blob("a.txt")), pairs)
        self.assertIn(("b.txt", self.blob("b.txt")), pairs)
        self.assertIn(("c.txt", self.blob("c.txt")), pairs)

    def test_blocked_gate_with_approve_text_still_blocked(self):
        self.start()
        css.stage8b_review_snapshot(self.ctx(APPROVE_TEXT, "BLOCKED"))
        self.assertEqual([r[0] for r in self.rows("SELECT decision FROM review_snapshots")], ["BLOCKED"])

    def test_blocked_start_missing_stop_present_is_file_scoped(self):
        css.stage8b_review_snapshot(self.ctx(BLOCK_TEXT, "BLOCKED"))  # no start saved
        self.assertEqual(self.rows("SELECT decision, scope FROM review_snapshots"),
                         [("BLOCKED", "files")])
        self.assertEqual(dict(self.rows("SELECT path, blob FROM review_snapshot_files")),
                         {"a.txt": self.blob("a.txt"), "b.txt": self.blob("b.txt")})

    def test_blocked_stop_missing_start_present_is_file_scoped(self):
        self.start()
        mod = css._get_review_snapshot_module()
        with mock.patch.object(mod, "take_snapshot", return_value=None):
            css.stage8b_review_snapshot(self.ctx(BLOCK_TEXT, "BLOCKED"))
        self.assertEqual(self.rows("SELECT scope FROM review_snapshots"), [("files",)])
        self.assertEqual(sorted(r[0] for r in self.rows("SELECT path FROM review_snapshot_files")),
                         ["a.txt", "b.txt"])

    def test_started_at_recorded_from_start_file(self):
        self.start()
        css.stage8b_review_snapshot(self.ctx(APPROVE_TEXT, "DONE"))
        st, en = self.rows("SELECT started_at, ended_at FROM review_snapshots")[0]
        self.assertRegex(st, r"^\d{4}-\d\d-\d\dT")
        self.assertTrue(en)

    def test_blocked_with_both_snapshots_missing_writes_degraded_repo_row(self):
        mod = css._get_review_snapshot_module()
        with mock.patch.object(mod, "take_snapshot", return_value=None):
            css.stage8b_review_snapshot(self.ctx(BLOCK_TEXT, "BLOCKED"))
        self.assertEqual(self.rows("SELECT decision, scope, repo_root FROM review_snapshots"),
                         [("BLOCKED", "repo", self.repo)])
        self.assertEqual(self.rows("SELECT * FROM review_snapshot_files"), [])

    def test_blocked_with_unwritable_db_writes_side_marker(self):
        self.start()
        bad_db = os.path.join(self.tmp, "missing", "cast.db")
        css.stage8b_review_snapshot(self.ctx(BLOCK_TEXT, "BLOCKED", db=bad_db))
        d = os.path.join(self.home, ".claude", "cast-state", "review-unrecorded")
        names = os.listdir(d)
        self.assertEqual(len(names), 1)
        self.assertEqual(len(names[0]), 16)
        with open(os.path.join(d, names[0])) as fh:
            body = json.load(fh)
        self.assertEqual(body["repo_root"], self.repo)
        self.assertEqual(body["agent_id"], "ag1")
        self.assertEqual(oct(os.stat(os.path.join(d, names[0])).st_mode & 0o777), "0o600")
        self.assertEqual(oct(os.stat(d).st_mode & 0o777), "0o700")

    def test_non_reviewer_and_missing_agent_id_record_nothing(self):
        self.start()
        css.stage8b_review_snapshot(self.ctx(APPROVE_TEXT, "DONE", agent="backend-writer"))
        css.stage8b_review_snapshot(self.ctx(APPROVE_TEXT, "DONE", aid=""))
        self.assertEqual(self.rows("SELECT * FROM review_snapshots"), [])

    def test_labelled_reviewer_name_recorded(self):
        self.start(agent="security__pass1")
        css.stage8b_review_snapshot(self.ctx(APPROVE_TEXT, "DONE", agent="security__pass1"))
        self.assertEqual(self.rows("SELECT reviewer FROM review_snapshots"), [("security",)])

    def test_final_text_used_and_transcript_not_reread(self):
        self.start()
        c = self.ctx("", "DONE")
        c.final_text = APPROVE_TEXT  # as parse_input caches it (handback message)
        with mock.patch.object(css, "_handback_message", side_effect=AssertionError("re-read")) as hb:
            css.stage8b_review_snapshot(c)
        hb.assert_not_called()
        self.assertEqual([r[0] for r in self.rows("SELECT decision FROM review_snapshots")], ["APPROVE"])

    def test_spoofed_name_with_general_purpose_roster_records_nothing(self):
        self.start(agent="code-reviewer__x")
        c = self.ctx(APPROVE_TEXT, "DONE", agent="code-reviewer__x", roster=None)
        self.sidecar("general-purpose", "code-reviewer__x")
        css.stage8b_review_snapshot(c)
        css.stage8b_review_snapshot(self.ctx(BLOCK_TEXT, "BLOCKED", agent="code-reviewer__x", roster=None))
        self.assertEqual(self.rows("SELECT * FROM review_snapshots"), [])
        self.assertIn("roster type unverified", self.log())

    def test_no_sidecar_records_nothing(self):
        self.start()
        css.stage8b_review_snapshot(self.ctx(APPROVE_TEXT, "DONE", roster=None))
        self.assertEqual(self.rows("SELECT * FROM review_snapshots"), [])

    def test_real_reviewer_sidecar_records_roster_type_as_reviewer(self):
        self.start(agent="security__s")
        css.stage8b_review_snapshot(self.ctx(APPROVE_TEXT, "DONE", agent="security__s"))
        self.assertEqual(self.rows("SELECT reviewer FROM review_snapshots"), [("security",)])

    def test_blocked_roots_differ_is_degraded(self):
        self.start()
        mod = css._get_review_snapshot_module()
        other = {"repo_root": os.path.join(self.tmp, "elsewhere"), "files": {"z": "a" * 40}}
        with mock.patch.object(mod, "take_snapshot", return_value=other):
            css.stage8b_review_snapshot(self.ctx(BLOCK_TEXT, "BLOCKED"))
        self.assertEqual(self.rows("SELECT scope FROM review_snapshots"), [("repo",)])

    def test_blocked_empty_union_is_degraded(self):
        self.write("a.txt", b"a0\n")
        self.write("b.txt", b"b0\n")  # clean tree: zero dirty files
        css.stage8b_review_snapshot(self.ctx(BLOCK_TEXT, "BLOCKED"))
        self.assertEqual(self.rows("SELECT scope FROM review_snapshots"), [("repo",)])
        self.assertEqual(self.rows("SELECT * FROM review_snapshot_files"), [])

    def test_approve_with_zero_stable_files_records_nothing(self):
        self.write("a.txt", b"a0\n")
        self.write("b.txt", b"b0\n")  # clean: nothing dirty at start or stop
        self.start()
        css.stage8b_review_snapshot(self.ctx(APPROVE_TEXT, "DONE"))
        self.assertEqual(self.rows("SELECT * FROM review_snapshots"), [])
        self.assertIn("nothing stable", self.log())

    def test_block_verdict_with_done_gate_is_blocked(self):
        self.start()
        css.stage8b_review_snapshot(self.ctx(BLOCK_TEXT, "DONE"))
        self.assertEqual({r[0] for r in self.rows("SELECT decision FROM review_snapshots")}, {"BLOCKED"})
        self.assertEqual(len(self.rows("SELECT * FROM review_snapshot_files")), 2)

    def test_teammate_shaped_sidecar_with_custom_agent_type_records(self):
        # customAgentType wins in _roster_type_from_meta (shape 2): named teammate, real type.
        self.start(agent="code-reviewer__tm")
        c = self.ctx(APPROVE_TEXT, "DONE", agent="code-reviewer__tm", roster=None)
        d = os.path.join(self.home, ".claude", "projects", "slug", "s1", "subagents")
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, "agent-ag1.meta.json"), "w") as fh:
            json.dump({"agentType": "code-reviewer__tm", "name": "code-reviewer__tm",
                       "taskKind": "in_process_teammate", "teamName": "t",
                       "customAgentType": "code-reviewer"}, fh)
        css.stage8b_review_snapshot(c)
        self.assertEqual(self.rows("SELECT reviewer, decision FROM review_snapshots"),
                         [("code-reviewer", "APPROVE")])

    def test_teammate_without_custom_type_records_nothing(self):
        self.start(agent="code-reviewer__tm")
        c = self.ctx(APPROVE_TEXT, "DONE", agent="code-reviewer__tm", roster=None)
        d = os.path.join(self.home, ".claude", "projects", "slug", "s1", "subagents")
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, "agent-ag1.meta.json"), "w") as fh:
            json.dump({"agentType": "code-reviewer__tm", "name": "code-reviewer__tm",
                       "taskKind": "in_process_teammate"}, fh)
        css.stage8b_review_snapshot(c)
        self.assertEqual(self.rows("SELECT * FROM review_snapshots"), [])

    def test_expired_budget_approve_records_nothing(self):
        self.start()
        with mock.patch.object(css, "_REVIEW_SNAPSHOT_BUDGET_S", 0.0):
            css.stage8b_review_snapshot(self.ctx(APPROVE_TEXT, "DONE"))
        self.assertEqual(self.rows("SELECT * FROM review_snapshots"), [])
        self.assertIn("no stop snapshot", self.log())

    def test_expired_budget_blocked_uses_start_files_and_never_calls_git_with_timeout(self):
        self.start()
        mod = css._get_review_snapshot_module()
        seen = []
        real = mod._git

        def spy(repo_dir, args, timeout=30.0):
            seen.append(timeout)
            return real(repo_dir, args, timeout)

        with mock.patch.object(css, "_REVIEW_SNAPSHOT_BUDGET_S", 0.0), \
                mock.patch.object(mod, "_git", spy):
            css.stage8b_review_snapshot(self.ctx(BLOCK_TEXT, "BLOCKED"))
        self.assertEqual(seen, [])  # budget already spent: no git call at all
        self.assertEqual(self.rows("SELECT scope FROM review_snapshots"), [("files",)])
        self.assertEqual(sorted(r[0] for r in self.rows("SELECT path FROM review_snapshot_files")),
                         ["a.txt", "b.txt"])

    def test_marker_refused_when_base_dir_unsafe(self):
        self.start()
        base = os.path.join(self.home, ".claude", "cast-state", "review-unrecorded")
        os.makedirs(base, mode=0o777, exist_ok=True)
        os.chmod(base, 0o777)  # group/world writable -> _state_dir_ok refuses
        css.stage8b_review_snapshot(self.ctx(BLOCK_TEXT, "BLOCKED", db=os.path.join(self.tmp, "no", "db")))
        self.assertEqual(os.listdir(base), [])

    def test_never_raises(self):
        c = self.ctx(APPROVE_TEXT, "DONE")
        c.data = None
        with mock.patch.object(css, "_get_review_snapshot_module", side_effect=RuntimeError("x")):
            css.stage8b_review_snapshot(c)


if __name__ == "__main__":
    unittest.main()
