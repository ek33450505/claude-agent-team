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

# crs first: importing cast_subagent_stop prepends the installed scripts dir to sys.path,
# which would otherwise shadow the repo's cast_review_snapshot when this file runs alone.
import cast_review_snapshot as crs  # noqa: E402
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
        _migrate(conn)
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

    def test_extra_discovery_incomplete_dir_cap_degrades_default_repo(self):
        self.start()
        late1, late2 = self.add_wt("wtl1"), self.add_wt("wtl2")
        self.dirty(late1)
        self.dirty(late2)
        self.transcript([("Read", {"file_path": os.path.join(late1, "a.txt")}),
                         ("Read", {"file_path": os.path.join(late2, "a.txt")})])
        mod = css._get_review_snapshot_module()
        with mock.patch.object(mod, "list_worktrees", return_value=[self.repo]), \
                mock.patch.object(css, "_EXTRA_ROOTS_MAX", 1):
            css.stage8b_review_snapshot(self.ctx(BLOCK_TEXT, "BLOCKED"))
        self.assertEqual(self.rows("SELECT repo_root FROM review_snapshots WHERE scope='repo'"),
                         [(self.repo,)])
        self.assertIn("EXTRA-root discovery incomplete", self.log())
        self.assertIn("degrading", self.log())
        self.assertTrue(self.rows("SELECT 1 FROM review_snapshots WHERE scope='files'"))  # file rows kept

    def test_extra_discovery_complete_writes_no_degraded_row(self):
        self.start()
        late = self.add_wt("wtl")
        self.dirty(late)
        self.transcript([("Read", {"file_path": os.path.join(late, "a.txt")})])
        mod = css._get_review_snapshot_module()
        with mock.patch.object(mod, "list_worktrees", return_value=[self.repo]):
            css.stage8b_review_snapshot(self.ctx(BLOCK_TEXT, "BLOCKED"))
        self.assertEqual(self.rows("SELECT * FROM review_snapshots WHERE scope='repo'"), [])
        self.assertNotIn("EXTRA-root discovery incomplete", self.log())

    def test_extra_roots_reasons_budget_and_identity(self):
        late = self.add_wt("wtl")
        mod = css._get_review_snapshot_module()
        paths = {os.path.join(late, "a.txt")}
        seq = iter([5.0, 0.0])
        roots, why = css._extra_touched_roots(mod, self.repo, paths, [self.repo], lambda: next(seq, 0.0))
        self.assertEqual((roots, why), ([], "budget spent"))
        with mock.patch.object(mod, "repo_identity", return_value=None):
            roots, why = css._extra_touched_roots(mod, self.repo, paths, [self.repo], lambda: 5.0)
        self.assertEqual((roots, why), ([], "repo identity unavailable"))
        self.assertEqual(css._extra_touched_roots(mod, self.repo, set(), [self.repo], lambda: 5.0), ([], None))

    def test_extra_incomplete_for_budget_or_identity_degrades_with_log(self):
        self.start()
        self.transcript([("Read", {"file_path": os.path.join(self.tmp, "nowhere", "f.txt")})])
        for reason in ("budget spent", "repo identity unavailable"):
            with mock.patch.object(css, "_extra_touched_roots", return_value=([], reason)):
                css.stage8b_review_snapshot(self.ctx(BLOCK_TEXT, "BLOCKED"))
            self.assertIn("(%s); degrading" % reason, self.log())
        self.assertEqual(len(self.rows("SELECT * FROM review_snapshots WHERE scope='repo'")), 2)

    def test_approve_root_starved_by_budget_is_logged(self):
        self.start()
        with mock.patch.object(css, "_REVIEW_SNAPSHOT_BUDGET_S", 0.0):
            css.stage8b_review_snapshot(self.ctx(APPROVE_TEXT, "DONE"))
        self.assertIn("APPROVE root starved by budget", self.log())

    def test_unmigrated_db_without_mode_column_blocked_still_degrades(self):
        old_db = os.path.join(self.tmp, "old.db")
        conn = sqlite3.connect(old_db)
        conn.executescript(_MIGRATION.read_text())  # 037 only: no mode column
        conn.close()
        self.start()
        css.stage8b_review_snapshot(self.ctx(APPROVE_TEXT, "DONE", db=old_db))
        self.start()
        css.stage8b_review_snapshot(self.ctx(BLOCK_TEXT, "BLOCKED", db=old_db))
        conn = sqlite3.connect(old_db)
        try:
            rows = conn.execute("SELECT decision, scope FROM review_snapshots").fetchall()
        finally:
            conn.close()
        self.assertEqual(rows, [("BLOCKED", "repo")])
        self.assertIn("APPROVE not recorded", self.log())

    def test_rows_carry_git_modes(self):
        os.chmod(os.path.join(self.repo, "b.txt"), 0o755)
        self.start()
        css.stage8b_review_snapshot(self.ctx(APPROVE_TEXT, "DONE"))
        css.stage8b_review_snapshot(self.ctx(BLOCK_TEXT, "BLOCKED"))
        got = self.rows("SELECT s.decision, f.path, f.mode FROM review_snapshots s "
                        "JOIN review_snapshot_files f ON f.snapshot_id = s.id")
        self.assertEqual(sorted(got), sorted(
            [(d, "a.txt", "100644") for d in ("APPROVE", "BLOCKED")]
            + [(d, "b.txt", "100755") for d in ("APPROVE", "BLOCKED")]))

    def test_old_format_start_file_without_modes_approves_nothing(self):
        snap = crs.take_snapshot(self.repo)
        snap.pop("modes")
        sd = crs.default_state_dir()
        os.makedirs(sd, mode=0o700, exist_ok=True)
        with open(os.path.join(sd, "ag1.json"), "w") as fh:
            json.dump({"v": 2, "session_id": "s1", "reviewer": "code-reviewer",
                       "snaps": {snap["repo_root"]: snap}, "started_at": "2026-10-30T00:00:00Z"}, fh)
        css.stage8b_review_snapshot(self.ctx(APPROVE_TEXT, "DONE"))
        self.assertEqual(self.rows("SELECT * FROM review_snapshots"), [])
        self.assertIn("nothing stable", self.log())

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

    def test_blocked_empty_union_clean_tree_records_nothing(self):
        self.write("a.txt", b"a0\n")
        self.write("b.txt", b"b0\n")  # clean tree: both snapshots present, zero dirty files
        self.start()
        css.stage8b_review_snapshot(self.ctx(BLOCK_TEXT, "BLOCKED"))
        self.assertEqual(self.rows("SELECT * FROM review_snapshots"), [])
        self.assertIn("BLOCK on clean tree, nothing to bind", self.log())

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


    # --- worktree coverage -------------------------------------------------------------
    def add_wt(self, name, rel=None):
        path = os.path.join(self.tmp, name) if rel is None else os.path.join(self.repo, rel)
        self.git("worktree", "add", "-q", "-b", name, path)
        return os.path.realpath(path)

    def dirty(self, root, rel="a.txt", body=b"dirty\n"):
        with open(os.path.join(root, rel), "wb") as fh:
            fh.write(body)

    def transcript(self, tools, aid="ag1", sid="s1", raw=None):
        """Write the reviewer's trusted transcript; tools = [(name, input_dict), ...]."""
        d = os.path.join(self.home, ".claude", "projects", "slug", sid, "subagents")
        os.makedirs(d, exist_ok=True)
        lines = [json.dumps({"type": "assistant", "message": {"content": [
            {"type": "tool_use", "name": n, "input": i} for n, i in tools]}})]
        with open(os.path.join(d, "agent-%s.jsonl" % aid), "w") as fh:
            fh.write(raw if raw is not None else "\n".join(lines) + "\n")

    def snap_roots(self, decision):
        return sorted(r[0] for r in self.rows(
            "SELECT repo_root FROM review_snapshots WHERE decision='%s'" % decision))

    def test_approve_binds_only_touched_worktree(self):
        x, y = self.add_wt("wtx"), self.add_wt("wty")
        self.dirty(x)
        self.dirty(y)
        self.start()
        self.transcript([("Read", {"file_path": os.path.join(x, "a.txt")})])
        css.stage8b_review_snapshot(self.ctx(APPROVE_TEXT, "DONE"))
        self.assertEqual(self.snap_roots("APPROVE"), [x])
        self.assertEqual(self.rows("SELECT path FROM review_snapshot_files"), [("a.txt",)])

    def test_approve_grep_glob_relative_path_resolves_against_cwd(self):
        x = self.add_wt("wtx", rel="sub/wtx")
        self.dirty(x)
        self.start()
        self.transcript([("Grep", {"path": "sub/wtx", "pattern": "p"}),
                         ("Glob", {"path": os.path.join(x, "src"), "pattern": "*"})])
        css.stage8b_review_snapshot(self.ctx(APPROVE_TEXT, "DONE"))
        self.assertEqual(self.snap_roots("APPROVE"), [x])

    def test_approve_without_reads_binds_default_root_only(self):
        x = self.add_wt("wtx")
        self.dirty(x)
        self.start()
        self.transcript([("Bash", {"command": "ls"})])
        css.stage8b_review_snapshot(self.ctx(APPROVE_TEXT, "DONE"))
        self.assertEqual(self.snap_roots("APPROVE"), [self.repo])

    def test_approve_with_unreadable_transcript_binds_default_root_only(self):
        x = self.add_wt("wtx")
        self.dirty(x)
        self.start()
        css.stage8b_review_snapshot(self.ctx(APPROVE_TEXT, "DONE"))  # no transcript at all
        self.assertEqual(self.snap_roots("APPROVE"), [self.repo])

    def test_blocked_touched_worktree_only(self):
        x, y = self.add_wt("wtx"), self.add_wt("wty")
        self.dirty(x)
        self.dirty(y)
        self.start()
        self.transcript([("Read", {"file_path": os.path.join(y, "a.txt")})])
        css.stage8b_review_snapshot(self.ctx(BLOCK_TEXT, "BLOCKED"))
        self.assertEqual(self.snap_roots("BLOCKED"), sorted([self.repo, y]))  # default root + touched

    def test_blocked_bash_only_clean_tree_everywhere_records_nothing(self):
        self.write("a.txt", b"a0\n")
        self.write("b.txt", b"b0\n")
        self.add_wt("wtx")
        self.start()
        self.transcript([("Bash", {"command": "ls"})])
        css.stage8b_review_snapshot(self.ctx(BLOCK_TEXT, "BLOCKED"))
        self.assertEqual(self.rows("SELECT * FROM review_snapshots"), [])

    def test_blocked_unreadable_transcript_binds_every_dirty_candidate(self):
        x, y, z = self.add_wt("wtx"), self.add_wt("wty"), self.add_wt("wtz")
        self.dirty(x)
        self.dirty(y)
        self.start()
        self.transcript([], raw="not json at all\n")
        css.stage8b_review_snapshot(self.ctx(BLOCK_TEXT, "BLOCKED"))
        roots = set(self.snap_roots("BLOCKED"))
        self.assertEqual(roots, {self.repo, x, y})
        self.assertNotIn(z, roots)
        self.assertEqual(self.rows("SELECT * FROM review_snapshots WHERE scope='repo'"), [])

    def test_blocked_neither_snapshot_degraded_even_with_worktrees(self):
        self.add_wt("wtx")
        self.transcript([("Read", {"file_path": os.path.join(self.repo, "a.txt")})])
        mod = css._get_review_snapshot_module()
        with mock.patch.object(mod, "take_snapshot", return_value=None):
            css.stage8b_review_snapshot(self.ctx(BLOCK_TEXT, "BLOCKED"))
        self.assertEqual(self.rows("SELECT decision, scope, repo_root FROM review_snapshots"),
                         [("BLOCKED", "repo", self.repo)])

    def test_v1_start_file_still_lets_approve_record(self):
        snap = crs.take_snapshot(self.repo)
        sd = crs.default_state_dir()
        os.makedirs(sd, mode=0o700, exist_ok=True)
        with open(os.path.join(sd, "ag1.json"), "w") as fh:
            json.dump({"session_id": "s1", "reviewer": "code-reviewer",
                       "repo_root": snap["repo_root"], "snap": snap,
                       "started_at": "2026-10-30T00:00:00Z"}, fh)
        css.stage8b_review_snapshot(self.ctx(APPROVE_TEXT, "DONE"))
        self.assertEqual(self.snap_roots("APPROVE"), [self.repo])

    def test_blocked_bash_only_binds_every_dirty_candidate(self):
        x, y = self.add_wt("wtx"), self.add_wt("wty")
        self.dirty(x)
        self.start()
        self.transcript([("Bash", {"command": "cat x/a.txt"})])
        css.stage8b_review_snapshot(self.ctx(BLOCK_TEXT, "BLOCKED"))
        roots = set(self.snap_roots("BLOCKED"))
        self.assertEqual(roots, {self.repo, x})
        self.assertNotIn(y, roots)

    def test_blocked_read_outside_every_repo_binds_default_root_only(self):
        x = self.add_wt("wtx")
        self.dirty(x)
        self.start()
        outside = os.path.join(self.tmp, "not-a-repo")
        os.makedirs(outside)
        with open(os.path.join(outside, "f.txt"), "w") as fh:
            fh.write("f")
        self.transcript([("Read", {"file_path": os.path.join(outside, "f.txt")})])
        css.stage8b_review_snapshot(self.ctx(BLOCK_TEXT, "BLOCKED"))
        self.assertEqual(self.snap_roots("BLOCKED"), [self.repo])

    def test_blocked_read_in_worktree_created_after_start_gets_stop_only_row(self):
        self.start()
        late = self.add_wt("wtlate")  # not in the start snapshot
        self.dirty(late)
        self.transcript([("Read", {"file_path": os.path.join(late, "a.txt")})])
        mod = css._get_review_snapshot_module()
        # stop-time worktree listing capped / failed: the late worktree is not a candidate
        with mock.patch.object(mod, "list_worktrees", return_value=[self.repo]):
            css.stage8b_review_snapshot(self.ctx(BLOCK_TEXT, "BLOCKED"))
        self.assertEqual(set(self.snap_roots("BLOCKED")), {self.repo, late})
        rows = self.rows("SELECT f.path FROM review_snapshots s JOIN review_snapshot_files f "
                         "ON f.snapshot_id = s.id WHERE s.repo_root = '%s'" % late)
        self.assertEqual(rows, [("a.txt",)])

    def test_blocked_read_in_other_repository_is_ignored(self):
        self.start()
        other = os.path.join(self.tmp, "other")
        os.makedirs(other)
        subprocess.run(["git", "-C", other, "init", "-q"], check=True, capture_output=True)
        with open(os.path.join(other, "z.txt"), "w") as fh:
            fh.write("z")
        self.transcript([("Read", {"file_path": os.path.join(other, "z.txt")})])
        css.stage8b_review_snapshot(self.ctx(BLOCK_TEXT, "BLOCKED"))
        self.assertEqual(self.snap_roots("BLOCKED"), [self.repo])

    def test_blocked_one_snapshot_empty_union_is_degraded(self):
        self.write("a.txt", b"a0\n")
        self.write("b.txt", b"b0\n")  # clean
        # no start snapshot saved: exactly one (stop) snapshot, empty
        self.transcript([("Read", {"file_path": os.path.join(self.repo, "a.txt")})])
        css.stage8b_review_snapshot(self.ctx(BLOCK_TEXT, "BLOCKED"))
        self.assertEqual(self.rows("SELECT decision, scope, repo_root FROM review_snapshots"),
                         [("BLOCKED", "repo", self.repo)])

    def test_blocked_with_no_roots_logs_fail_and_writes_marker(self):
        mod = css._get_review_snapshot_module()
        with mock.patch.object(mod, "resolve_repo_root", return_value=None), \
                mock.patch.object(mod, "list_worktrees", return_value=None), \
                mock.patch.object(css, "_log_fail") as lf, \
                mock.patch.object(css, "_write_review_unrecorded_marker") as mk:
            css.stage8b_review_snapshot(self.ctx(BLOCK_TEXT, "BLOCKED"))
        self.assertTrue(any(c.args[0] == "review_snapshot" for c in lf.call_args_list))
        mk.assert_called_once()

    def test_each_root_gets_a_budget_share_not_the_whole_remainder(self):
        x, y = self.add_wt("wtx"), self.add_wt("wty")
        self.dirty(x)
        self.dirty(y)
        self.start()
        mod = css._get_review_snapshot_module()
        seen = []
        real = mod.take_snapshot

        def spy(root, deadline_s=None):
            seen.append(deadline_s)
            return real(root, deadline_s)

        with mock.patch.object(mod, "take_snapshot", spy):
            css.stage8b_review_snapshot(self.ctx(BLOCK_TEXT, "BLOCKED"))
        self.assertEqual(len(seen), 3)
        self.assertLess(seen[0], css._REVIEW_SNAPSHOT_BUDGET_S * 0.5)

    def test_touched_paths_over_cap_is_none(self):
        self.transcript([("Read", {"file_path": "/p/%d" % i}) for i in range(5)])
        with mock.patch.object(css, "_TOUCHED_MAX_PATHS", 3):
            self.assertIsNone(css._reviewer_touched_paths(self.ctx(APPROVE_TEXT, "DONE"), self.repo))

    def test_touched_paths_spent_deadline_is_none(self):
        self.transcript([("Read", {"file_path": "/p/1"})])
        self.assertIsNone(css._reviewer_touched_paths(self.ctx(APPROVE_TEXT, "DONE"), self.repo,
                                                      deadline=css.time.monotonic() - 1))

    def test_main_snapshot_excludes_nested_worktree_files(self):
        nested = self.add_wt("nest", rel=".claude/worktrees/nest")
        self.dirty(nested, "a.txt", b"dirty in nested\n")
        snap = crs.take_snapshot(self.repo)
        self.assertFalse([p for p in snap["files"] if p.startswith(".claude/worktrees")], snap["files"])
        snaps = crs.take_snapshots(self.repo, 30)
        self.assertEqual(list(snaps[nested]["files"]), ["a.txt"])

    def test_map_touched_roots_longest_match_on_component_boundary(self):
        roots = ["/m", "/m/.claude/worktrees/x", "/m/wt", "/m/wt2"]
        got = css._map_touched_roots(
            {"/m/.claude/worktrees/x/src/a.py", "/m/wt2/f", "/m/other", "/elsewhere/f", "/m/wt"}, roots)
        self.assertEqual(got, {"/m/.claude/worktrees/x", "/m/wt2", "/m", "/m/wt"})
        self.assertNotIn("/m/wt", css._map_touched_roots({"/m/wt2/f"}, roots))

    def test_touched_paths_none_when_over_cap_or_unparsable(self):
        self.transcript([("Read", {"file_path": "/x/y"})])
        c = self.ctx(APPROVE_TEXT, "DONE")
        self.assertEqual(css._reviewer_touched_paths(c, self.repo), {"/x/y"})
        with mock.patch.object(css, "_TOUCHED_TRANSCRIPT_MAX", 10):
            self.assertIsNone(css._reviewer_touched_paths(c, self.repo))
        self.transcript([], raw="{bad\n")
        self.assertIsNone(css._reviewer_touched_paths(c, self.repo))

    def test_touched_paths_ignores_non_assistant_and_non_str(self):
        raw = "\n".join(json.dumps(e) for e in [
            {"type": "user", "message": {"content": [{"type": "tool_use", "name": "Read", "input": {"file_path": "/u"}}]}},
            {"type": "assistant", "message": {"content": [
                {"type": "tool_use", "name": "Read", "input": {"file_path": 5}},
                {"type": "tool_use", "name": "Edit", "input": {"file_path": "/e"}},
                {"type": "tool_use", "name": "Read", "input": {"file_path": "/ok"}}]}}]) + "\n"
        self.transcript([], raw=raw)
        self.assertEqual(css._reviewer_touched_paths(self.ctx(APPROVE_TEXT, "DONE"), self.repo), {"/ok"})

    def test_never_raises(self):
        c = self.ctx(APPROVE_TEXT, "DONE")
        c.data = None
        with mock.patch.object(css, "_get_review_snapshot_module", side_effect=RuntimeError("x")):
            css.stage8b_review_snapshot(c)


if __name__ == "__main__":
    unittest.main()
