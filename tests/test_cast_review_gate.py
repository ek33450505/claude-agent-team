"""Tests for scripts/cast-review-gate.py (content-bound review gate, WARN mode, v10.6.0 U2).

Every test runs the gate as a real subprocess exactly as the commit path would
(`python3 -I -E -s scripts/cast-review-gate.py`, cwd = a throwaway git repo) against a throwaway
cast.db and a throwaway HOME. Nothing touches the real ~/.claude.
"""
import json
import os
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import unittest

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPTS = os.path.join(REPO, "scripts")
GATE = os.path.join(SCRIPTS, "cast-review-gate.py")
sys.path.insert(0, SCRIPTS)
import cast_review_snapshot as crs  # noqa: E402

T_OLD = "2026-10-15T10:00:00Z"
T_MID = "2026-10-15T11:00:00Z"
T_NEW = "2026-10-15T12:00:00Z"


class GateCase(unittest.TestCase):
    _template_db = None
    _template_dir = None

    @classmethod
    def setUpClass(cls):
        cls._template_dir = tempfile.mkdtemp(prefix="gate-tpl-")
        cls._template_db = os.path.join(cls._template_dir, "cast.db")
        home = os.path.join(cls._template_dir, "home")
        os.makedirs(home)
        env = dict(os.environ, HOME=home, CAST_DB_PATH=cls._template_db)
        subprocess.run(["bash", os.path.join(SCRIPTS, "cast-db-init.sh")], env=env,
                       capture_output=True, check=True, timeout=120)

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls._template_dir, ignore_errors=True)

    def setUp(self):
        self.tmp = os.path.realpath(tempfile.mkdtemp(prefix="gate-test-"))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.home = os.path.join(self.tmp, "home")
        os.makedirs(self.home)
        self.db = os.path.join(self.tmp, "cast.db")
        shutil.copy(self._template_db, self.db)
        self.repo = os.path.join(self.tmp, "repo")
        os.makedirs(self.repo)
        self.git("init", "-q")
        self.git("config", "user.name", "t")
        self.git("config", "user.email", "t@example.invalid")
        self.git("config", "commit.gpgsign", "false")
        self.write("base.txt", "base\n")
        self.git("add", "base.txt")
        self.git("commit", "-q", "-m", "base")

    # ---- fixtures ----
    def git(self, *args, cwd=None):
        env = dict(os.environ, HOME=self.home, GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_SYSTEM=os.devnull)
        r = subprocess.run(["git"] + list(args), cwd=cwd or self.repo, env=env,
                           capture_output=True, text=True, timeout=30)
        self.assertEqual(r.returncode, 0, r.stderr)
        return r.stdout

    def write(self, rel, content):
        full = os.path.join(self.repo, rel)
        os.makedirs(os.path.dirname(full), exist_ok=True)
        with open(full, "w") as fh:
            fh.write(content)

    def stage(self, *rels):
        self.git("add", "--", *rels)

    def blob(self, rel):
        return self.git("hash-object", "--no-filters", "--", rel).strip()

    def seed(self, decision, files, reviewer="code-reviewer", scope="files", ended_at=T_MID,
             repo_root=None):
        conn = sqlite3.connect(self.db)
        try:
            cur = conn.execute(
                "INSERT INTO review_snapshots (session_id, agent_id, reviewer, repo_root, decision, scope, started_at, ended_at) VALUES ('s','a',?,?,?,?,?,?)",
                (reviewer, repo_root or self.repo, decision, scope, T_OLD, ended_at))
            for path, blob in files.items():
                conn.execute("INSERT INTO review_snapshot_files (snapshot_id, path, blob) VALUES (?,?,?)",
                             (cur.lastrowid, crs.path_key(path), blob))
            conn.commit()
        finally:
            conn.close()

    def marker(self, repo_root, ts=T_MID, name="m1"):
        d = os.path.join(self.home, ".claude", "cast-state", "review-unrecorded")
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, name), "w") as fh:
            json.dump({"repo_root": repo_root, "session_id": "s", "agent_id": "a",
                       "reviewer": "code-reviewer", "ts": ts}, fh)

    def gate(self, cwd=None, db=None, **extra_env):
        env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": self.home,
               "CAST_DB_PATH": db or self.db}
        env.update(extra_env)
        r = subprocess.run([sys.executable, "-I", "-E", "-s", GATE], cwd=cwd or self.repo, env=env,
                           capture_output=True, text=True, timeout=60)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(len(r.stdout.splitlines()), 1, f"stdout was not one line: {r.stdout!r}")
        return r.stdout.strip()

    def rows(self, sql="SELECT * FROM review_gate_decisions"):
        conn = sqlite3.connect(self.db)
        conn.row_factory = sqlite3.Row
        try:
            return conn.execute(sql).fetchall()
        finally:
            conn.close()

    def assertCounts(self, line, **kw):
        for k, v in kw.items():
            self.assertIn(f"{k}={v}", line, line)


class TestClassification(GateCase):
    def test_approved(self):
        self.write("a.txt", "one\n")
        self.stage("a.txt")
        self.seed("APPROVE", {"a.txt": self.blob("a.txt")})
        line = self.gate()
        self.assertTrue(line.startswith("review-gate OK:"), line)
        self.assertCounts(line, approved=1, unreviewed=0, blocked=0)
        row = self.rows()[0]
        self.assertEqual((row["would_block"], row["n_staged"], row["n_approved"], row["mode"]), (0, 1, 1, "warn"))
        self.assertEqual(row["repo_root"], self.repo)
        self.assertIsNone(row["commit_sha"])

    def test_security_only_approve_is_unreviewed(self):
        self.write("a.txt", "one\n")
        self.stage("a.txt")
        self.seed("APPROVE", {"a.txt": self.blob("a.txt")}, reviewer="security")
        line = self.gate()
        self.assertIn("would block", line)
        self.assertCounts(line, approved=0, unreviewed=1)
        self.assertIn("a.txt (no-approval)", line)

    def test_content_changed_after_approval(self):
        self.write("a.txt", "one\n")
        self.stage("a.txt")
        self.seed("APPROVE", {"a.txt": self.blob("a.txt")})
        self.write("a.txt", "two\n")
        self.stage("a.txt")
        self.assertCounts(self.gate(), approved=0, unreviewed=1)

    def test_unstaged_change_on_approved_path(self):
        self.write("a.txt", "one\n")
        self.stage("a.txt")
        self.seed("APPROVE", {"a.txt": self.blob("a.txt")})
        self.write("a.txt", "one\nmore\n")  # not staged
        line = self.gate()
        self.assertCounts(line, approved=0, unreviewed=1)
        self.assertIn("unstaged-changes", line)

    def test_block_same_blob_beats_approve(self):
        self.write("a.txt", "one\n")
        self.stage("a.txt")
        b = self.blob("a.txt")
        self.seed("APPROVE", {"a.txt": b})
        self.seed("BLOCKED", {"a.txt": b})
        line = self.gate()
        self.assertCounts(line, approved=0, blocked=1)
        self.assertEqual(self.rows()[0]["would_block"], 1)

    def test_security_block_wins(self):
        self.write("a.txt", "one\n")
        self.stage("a.txt")
        b = self.blob("a.txt")
        self.seed("APPROVE", {"a.txt": b})
        self.seed("BLOCKED", {"a.txt": b}, reviewer="security")
        self.assertCounts(self.gate(), approved=0, blocked=1)

    def test_deletion_with_deleted_binding(self):
        self.git("rm", "-q", "base.txt")
        self.seed("APPROVE", {"base.txt": "DELETED"})
        self.assertCounts(self.gate(), approved=1, unreviewed=0)

    def test_deletion_without_binding(self):
        self.git("rm", "-q", "base.txt")
        self.assertCounts(self.gate(), approved=0, unreviewed=1)

    def test_symlink_blob(self):
        os.symlink("base.txt", os.path.join(self.repo, "lnk"))
        self.stage("lnk")
        fmt = crs._object_format(self.repo)
        self.seed("APPROVE", {"lnk": crs._symlink_blob(os.path.join(self.repo, "lnk"), fmt)})
        self.assertCounts(self.gate(), approved=1, unreviewed=0)

    def test_non_utf8_filename(self):
        raw = os.path.join(os.fsencode(self.repo), b"bad-\xff.txt")
        try:
            with open(raw, "wb") as fh:
                fh.write(b"x\n")
        except OSError:
            self.skipTest("filesystem rejects non-UTF-8 filenames (e.g. APFS)")
        self.git("add", "-A")
        name = os.fsdecode(b"bad-\xff.txt")
        blob = self.git("hash-object", "--no-filters", "--", name).strip()
        self.assertTrue(crs.path_key(name).startswith("\x00b:"))
        self.seed("APPROVE", {name: blob})
        self.assertCounts(self.gate(), approved=1, unreviewed=0)

    def test_unicode_filename(self):
        name = "caf\u00e9-\u65e5\u672c.txt"
        self.write(name, "x\n")
        self.stage(name)
        self.seed("APPROVE", {name: self.blob(name)})
        self.assertCounts(self.gate(), approved=1, unreviewed=0)

    def test_approval_for_other_repo_root_does_not_count(self):
        self.write("a.txt", "one\n")
        self.stage("a.txt")
        self.seed("APPROVE", {"a.txt": self.blob("a.txt")}, repo_root=self.repo + "2")
        self.assertCounts(self.gate(), approved=0, unreviewed=1)


class TestRepoWideBlocks(GateCase):
    def setUp(self):
        super().setUp()
        self.write("a.txt", "one\n")
        self.stage("a.txt")
        self.approve = lambda ended: self.seed("APPROVE", {"a.txt": self.blob("a.txt")}, ended_at=ended)

    def test_repo_scope_block_blocks_all(self):
        self.seed("BLOCKED", {}, scope="repo", ended_at=T_MID)
        self.approve(T_OLD)  # earlier review does not clear it
        line = self.gate()
        self.assertCounts(line, approved=0, blocked=1)
        self.assertIn("repo-wide-block", line)

    def test_cleared_by_later_file_review(self):
        self.seed("BLOCKED", {}, scope="repo", ended_at=T_MID)
        self.approve(T_NEW)
        self.assertCounts(self.gate(), approved=1, blocked=0)

    def test_repo_block_with_null_ended_at_fails_closed(self):
        self.seed("BLOCKED", {}, scope="repo", ended_at=None)
        self.approve(T_NEW)
        self.assertCounts(self.gate(), blocked=1)

    def test_marker_for_subdir_blocks(self):
        self.marker(self.repo + "/sub", ts=T_MID)
        self.approve(T_OLD)
        self.assertCounts(self.gate(), blocked=1, approved=0)

    def test_marker_cleared_by_later_review(self):
        self.marker(self.repo, ts=T_MID)
        self.approve(T_NEW)
        self.assertCounts(self.gate(), blocked=0, approved=1)

    def test_marker_for_sibling_prefix_does_not_block(self):
        self.marker(self.repo + "2", ts=T_MID)
        self.approve(T_OLD)
        self.assertCounts(self.gate(), blocked=0, approved=1)

    def test_bad_markers_are_ignored(self):
        d = os.path.join(self.home, ".claude", "cast-state", "review-unrecorded")
        os.makedirs(d)
        with open(os.path.join(d, "junk"), "w") as fh:
            fh.write("{not json")
        with open(os.path.join(d, "big"), "w") as fh:
            fh.write(json.dumps({"repo_root": self.repo, "ts": T_MID, "pad": "x" * 70000}))
        os.symlink(os.path.join(d, "junk"), os.path.join(d, "lnk"))
        self.approve(T_OLD)
        self.assertCounts(self.gate(), blocked=0, approved=1)


class TestHatchAndDerived(GateCase):
    def test_hatch_turns_unreviewed_into_hatched_and_records_ack(self):
        self.write("a.txt", "one\n")
        self.stage("a.txt")
        line = self.gate(CAST_UNREVIEWED_OK="because testing")
        self.assertTrue(line.startswith("review-gate OK:"), line)
        self.assertCounts(line, unreviewed=0, hatched=1)
        row = self.rows()[0]
        self.assertEqual((row["would_block"], row["n_hatched"]), (0, 1))
        acks = self.rows("SELECT * FROM ack_events WHERE variable='CAST_UNREVIEWED_OK'")
        self.assertEqual(len(acks), 1)
        # the child env must not carry the hatch var, so this value proves argv delivery
        self.assertEqual(acks[0]["value"], "because testing")

    def test_hatch_value_starting_with_dash_is_recorded_verbatim(self):
        self.write("a.txt", "one\n")
        self.stage("a.txt")
        self.gate(CAST_UNREVIEWED_OK="--script evil -x")
        acks = self.rows("SELECT * FROM ack_events WHERE variable='CAST_UNREVIEWED_OK'")
        self.assertEqual(len(acks), 1)
        self.assertEqual(acks[0]["value"], "--script evil -x")
        self.assertEqual(acks[0]["script"], "cast-review-gate.py")

    def test_hatch_leaves_blocked_and_no_ack_when_nothing_hatched(self):
        self.write("a.txt", "one\n")
        self.stage("a.txt")
        self.seed("BLOCKED", {"a.txt": self.blob("a.txt")})
        line = self.gate(CAST_UNREVIEWED_OK="1")
        self.assertCounts(line, blocked=1, hatched=0)
        self.assertIn("would block", line)
        self.assertEqual(self.rows("SELECT * FROM ack_events WHERE variable='CAST_UNREVIEWED_OK'"), [])

    def test_no_hatch_no_ack(self):
        self.write("a.txt", "one\n")
        self.stage("a.txt")
        self.gate()
        self.assertEqual(self.rows("SELECT * FROM ack_events WHERE variable='CAST_UNREVIEWED_OK'"), [])

    def _cast_shape(self):
        self.write("agents/core/commit.md", "x\n")
        self.write("scripts/cast_review_snapshot.py", "x = 1\n")
        for rel in ("agents/core/commit.md", "scripts/cast_review_snapshot.py"):
            self.stage(rel)
            self.seed("APPROVE", {rel: self.blob(rel)})

    def test_derived_only_in_cast_shaped_repo(self):
        self._cast_shape()
        self.write("plugin/gen.txt", "g\n")
        self.write("cast-stats.json", "{}\n")
        self.stage("plugin/gen.txt", "cast-stats.json")
        line = self.gate()
        self.assertTrue(line.startswith("review-gate OK:"), line)
        self.assertCounts(line, derived=2, approved=2, unreviewed=0)

    def test_derived_not_exempt_outside_cast_repo(self):
        self.write("plugin/gen.txt", "g\n")
        self.write("cast-stats.json", "{}\n")
        self.stage("plugin/gen.txt", "cast-stats.json")
        line = self.gate()
        self.assertCounts(line, derived=0, unreviewed=2)


class TestGitlinks(GateCase):
    def _commit_sha(self):
        return self.git("rev-parse", "HEAD").strip()

    def _stage_gitlink(self, path, sha):
        self.git("update-index", "--add", "--cacheinfo", f"160000,{sha},{path}")

    def test_gitlink_only_commit_is_counted(self):
        self._stage_gitlink("sm", self._commit_sha())
        line = self.gate()
        self.assertIn("would block", line)
        self.assertCounts(line, approved=0, unreviewed=1)
        self.assertIn("sm (gitlink)", line)
        row = self.rows()[0]
        self.assertEqual((row["would_block"], row["n_staged"], row["n_unreviewed"]), (1, 1, 1))

    def test_mixed_file_and_gitlink(self):
        self.write("a.txt", "one\n")
        self.stage("a.txt")
        self._stage_gitlink("sm", self._commit_sha())
        self.seed("APPROVE", {"a.txt": self.blob("a.txt")})
        line = self.gate()
        self.assertCounts(line, approved=1, unreviewed=1)
        self.assertEqual(self.rows()[0]["n_staged"], 2)

    def test_unchanged_existing_gitlink_not_counted(self):
        self._stage_gitlink("sm", self._commit_sha())
        self.git("commit", "-q", "-m", "add gitlink")
        self.write("a.txt", "one\n")
        self.stage("a.txt")
        self.seed("APPROVE", {"a.txt": self.blob("a.txt")})
        line = self.gate()
        self.assertTrue(line.startswith("review-gate OK:"), line)
        self.assertEqual(self.rows()[0]["n_staged"], 1)

    def test_changed_gitlink_counted(self):
        self._stage_gitlink("sm", self._commit_sha())
        self.git("commit", "-q", "-m", "add gitlink")
        self.write("x.txt", "x\n")
        self.stage("x.txt")
        self.git("commit", "-q", "-m", "second")
        self._stage_gitlink("sm", self._commit_sha())
        line = self.gate()
        self.assertCounts(line, unreviewed=1)
        self.assertIn("(gitlink)", line)

    def test_removed_gitlink_counted(self):
        self._stage_gitlink("sm", self._commit_sha())
        self.git("commit", "-q", "-m", "add gitlink")
        self.git("update-index", "--force-remove", "sm")
        line = self.gate()
        self.assertCounts(line, unreviewed=1)
        self.assertIn("(gitlink)", line)
        self.assertEqual(self.rows()[0]["n_staged"], 1)

    def test_gitlink_hatchable(self):
        self._stage_gitlink("sm", self._commit_sha())
        line = self.gate(CAST_UNREVIEWED_OK="why")
        self.assertCounts(line, unreviewed=0, hatched=1)


class TestGitlinkBounds(GateCase):
    """gitlink_entries() driven with a fake crs: budget, cap and HEAD-resolve failures fail closed."""

    class FakeProc:
        def __init__(self, rc=0, out=""):
            self.returncode, self.stdout = rc, out

    def _fake(self, handler):
        class Crs:
            _git = staticmethod(lambda root, args, t=10: handler(args))
        return Crs()

    def _mod(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location("gate_mod2", GATE)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod

    def _ls(self, n):
        sha = "a" * 40
        return "".join(f"160000 {sha} 0\tsm{i}\0" for i in range(n))

    def test_cap_exceeded_is_unknown(self):
        mod = self._mod()
        P = self.FakeProc
        out = mod.gitlink_entries(self._fake(lambda a: P(0, self._ls(mod.MAX_GITLINKS + 1))), "/r", set(), 1e18)
        self.assertEqual([e[3] for e in out], ["gitlink-unknown"])

    def test_under_cap_is_not_unknown(self):
        mod = self._mod()
        P = self.FakeProc

        def h(a):
            if a[0] == "ls-files" and a[1] == "--stage":
                return P(0, self._ls(3))
            if a[0] == "rev-parse" and "--verify" in a:
                return P(1)  # unborn HEAD: every index gitlink counts
            return P(0, "")
        out = mod.gitlink_entries(self._fake(h), "/r", set(), 1e18)
        self.assertEqual([e[3] for e in out], ["gitlink"] * 3)

    def test_budget_spent_mid_loop_is_unknown(self):
        mod = self._mod()
        P = self.FakeProc
        clock = {"now": 0.0}

        class FakeTime:
            @staticmethod
            def monotonic():
                return clock["now"]
        mod.time = FakeTime  # gate module's own reference only

        def h(a):
            if a[0] == "ls-files":
                return P(0, self._ls(5))
            if a[0] == "rev-parse" and "--verify" in a:
                return P(0, "h\n")
            if a[0] == "rev-parse":
                clock["now"] = 100.0  # budget (end=50) is now spent
                return P(0, "a" * 40 + "\n")
            return P(0, "")
        out = mod.gitlink_entries(self._fake(h), "/r", set(), 50.0)
        self.assertEqual([e[3] for e in out], ["gitlink-unknown"])

    def test_head_resolve_failure_is_unknown_not_unborn(self):
        mod = self._mod()
        P = self.FakeProc
        for rc in (124, 3, 128):
            def h(a, rc=rc):
                if a[0] == "ls-files":
                    return P(0, self._ls(1))
                return P(rc)
            out = mod.gitlink_entries(self._fake(h), "/r", set(), 1e18)
            self.assertEqual([e[3] for e in out], ["gitlink-unknown"], rc)
        out = mod.gitlink_entries(self._fake(lambda a: P(0, self._ls(1)) if a[0] == "ls-files" else None), "/r", set(), 1e18)
        self.assertEqual([e[3] for e in out], ["gitlink-unknown"])

    def test_gate_unknown_counts_as_would_block(self):
        # end to end: unborn-HEAD-free repo, repo-wide block applies to a gitlink entry too
        self.git("update-index", "--add", "--cacheinfo", f"160000,{self.git('rev-parse', 'HEAD').strip()},sm")
        self.seed("BLOCKED", {}, scope="repo", ended_at=T_NEW)
        line = self.gate()
        self.assertCounts(line, blocked=1, unreviewed=0)
        self.assertIn("repo-wide-block", line)


class TestPrecedence(GateCase):
    def _cast_repo_with_plugin(self):
        self.write("agents/core/commit.md", "x\n")
        self.write("scripts/cast_review_snapshot.py", "x = 1\n")
        self.write("plugin/p.json", "{}\n")
        self.stage("plugin/p.json")

    def test_marker_beats_derived_with_db_missing(self):
        self._cast_repo_with_plugin()
        self.marker(self.repo, ts=T_MID)
        line = self.gate(db=os.path.join(self.tmp, "nope.db"))
        self.assertCounts(line, blocked=1, derived=0)
        self.assertIn("repo-wide-block", line)

    def test_marker_beats_derived_with_db_present(self):
        self._cast_repo_with_plugin()
        self.marker(self.repo, ts=T_MID)
        line = self.gate()
        self.assertCounts(line, blocked=1, derived=0)
        self.assertIn("repo-wide-block", line)

    def test_derived_with_db_missing_and_no_block(self):
        self._cast_repo_with_plugin()
        line = self.gate(db=os.path.join(self.tmp, "nope.db"))
        self.assertCounts(line, derived=1, blocked=0)


class TestIndexVsWorktree(GateCase):
    def _hidden_edit(self, flag):
        self.write("a.txt", "one\n")
        self.stage("a.txt")
        self.git("update-index", flag, "a.txt")
        self.write("a.txt", "two\n")  # worktree differs from the index, yet git diff is silent
        self.assertEqual(self.git("diff", "--name-only").strip(), "")
        self.seed("APPROVE", {"a.txt": self.blob("a.txt")})  # approval is for the WORKTREE content
        line = self.gate()
        self.assertCounts(line, approved=0, unreviewed=1)
        self.assertIn("index-worktree-mismatch", line)

    def test_assume_unchanged_hides_edit(self):
        self._hidden_edit("--assume-unchanged")

    def test_skip_worktree_hides_edit(self):
        self._hidden_edit("--skip-worktree")

    def test_type_mismatch_file_vs_symlink(self):
        self.write("a.txt", "one\n")
        self.stage("a.txt")
        self.git("update-index", "--assume-unchanged", "a.txt")
        os.remove(os.path.join(self.repo, "a.txt"))
        os.symlink("base.txt", os.path.join(self.repo, "a.txt"))
        fmt = crs._object_format(self.repo)
        self.seed("APPROVE", {"a.txt": crs._symlink_blob(os.path.join(self.repo, "a.txt"), fmt)})
        line = self.gate()
        self.assertCounts(line, approved=0, unreviewed=1)
        self.assertIn("type-mismatch", line)

    def test_crlf_filter_mismatch_fails_closed(self):
        self.write(".gitattributes", "*.txt text\n")
        self.stage(".gitattributes")
        self.git("commit", "-q", "-m", "attrs")
        with open(os.path.join(self.repo, "c.txt"), "wb") as fh:
            fh.write(b"one\r\ntwo\r\n")  # git add normalises CRLF->LF, so index != raw worktree
        self.stage("c.txt")
        self.seed("APPROVE", {"c.txt": self.blob("c.txt")})
        line = self.gate()
        self.assertCounts(line, approved=0, unreviewed=1)


class TestDerivedBlocks(GateCase):
    def test_recorded_block_on_derived_path_wins(self):
        self.write("agents/core/commit.md", "x\n")
        self.write("scripts/cast_review_snapshot.py", "x = 1\n")
        self.write("plugin/gen.txt", "g\n")
        self.write("cast-stats.json", "{}\n")
        self.stage("agents/core/commit.md", "scripts/cast_review_snapshot.py", "plugin/gen.txt", "cast-stats.json")
        self.seed("BLOCKED", {"plugin/gen.txt": self.blob("plugin/gen.txt"),
                              "cast-stats.json": self.blob("cast-stats.json")})
        line = self.gate()
        self.assertCounts(line, blocked=2, derived=0)

    def test_repo_wide_block_beats_derived(self):
        self.write("agents/core/commit.md", "x\n")
        self.write("scripts/cast_review_snapshot.py", "x = 1\n")
        self.write("plugin/gen.txt", "g\n")
        self.stage("agents/core/commit.md", "scripts/cast_review_snapshot.py", "plugin/gen.txt")
        self.seed("BLOCKED", {}, scope="repo", ended_at=T_NEW)
        self.assertCounts(self.gate(), blocked=3, derived=0)


class TestSchemaAndPure(GateCase):
    def test_mode_check_constraint(self):
        conn = sqlite3.connect(self.db)
        try:
            with self.assertRaises(sqlite3.IntegrityError):
                conn.execute("INSERT INTO review_gate_decisions (repo_root, mode, would_block) VALUES ('r','bogus',0)")
            conn.execute("INSERT INTO review_gate_decisions (repo_root, mode, would_block) VALUES ('r','enforce',0)")
        finally:
            conn.close()

    def test_migrate_only_db(self):
        db = os.path.join(self.tmp, "migrated.db")
        conn = sqlite3.connect(db)
        for name in ("037_review_snapshots.sql", "038_review_gate_decisions.sql"):
            with open(os.path.join(SCRIPTS, "migrations", name)) as fh:
                conn.executescript(fh.read())
        conn.close()
        self.write("a.txt", "one\n")
        self.stage("a.txt")
        self.db, orig = db, self.db
        try:
            self.seed("APPROVE", {"a.txt": self.blob("a.txt")})
            line = self.gate(db=db)
            self.assertTrue(line.startswith("review-gate OK:"), line)
            self.assertEqual(len(self.rows()), 1)
        finally:
            self.db = orig

    def _mod(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location("gate_mod", GATE)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod

    def test_display_strips_bidi_and_zero_width(self):
        mod = self._mod()
        out = mod._display("a\u202eb\u2066c\u200bd\ufeffe\u200ff\u061cg\x1bh")
        self.assertEqual(out, "a?b?c?d?e?f?g?h")

    def test_bad_path(self):
        mod = self._mod()
        for p in ("/etc/passwd", "../x", "a/../b", "", "a/.."):
            self.assertTrue(mod._bad_path(p), p)
        for p in ("a/b.txt", "..x/y", "a/..b"):
            self.assertFalse(mod._bad_path(p), p)


class TestEdges(GateCase):
    def test_missing_db(self):
        self.write("a.txt", "one\n")
        self.stage("a.txt")
        missing = os.path.join(self.tmp, "nope.db")
        line = self.gate(db=missing)
        self.assertIn("would block", line)
        self.assertCounts(line, unreviewed=1)
        self.assertIn("db unavailable", line)
        self.assertFalse(os.path.exists(missing), "gate must never create a DB")

    def test_table_missing(self):
        bare = os.path.join(self.tmp, "bare.db")
        sqlite3.connect(bare).close()
        self.write("a.txt", "one\n")
        self.stage("a.txt")
        line = self.gate(db=bare)
        self.assertCounts(line, unreviewed=1)
        self.assertIn("db unavailable", line)

    def test_nothing_staged(self):
        line = self.gate()
        self.assertEqual(line, "review-gate: nothing staged")
        self.assertEqual(self.rows(), [])

    def test_not_a_git_repo(self):
        plain = os.path.join(self.tmp, "plain")
        os.makedirs(plain)
        self.assertEqual(self.gate(cwd=plain), "review-gate: skipped (not a git repo)")

    def test_control_chars_in_path_sanitized(self):
        name = "evil\x1b[31m.txt"
        self.write(name, "x\n")
        self.stage(name)
        line = self.gate()
        self.assertNotIn("\x1b", line)
        self.assertIn("would block", line)

    def test_reasons_json_lists_non_approved_only(self):
        self.write("ok.txt", "1\n")
        self.write("no.txt", "2\n")
        self.stage("ok.txt", "no.txt")
        self.seed("APPROVE", {"ok.txt": self.blob("ok.txt")})
        self.gate()
        row = self.rows()[0]
        self.assertEqual((row["n_staged"], row["n_approved"], row["n_unreviewed"], row["would_block"]), (2, 1, 1, 1))
        reasons = json.loads(row["reasons"])
        self.assertEqual([r["path"] for r in reasons], ["no.txt"])
        self.assertEqual(reasons[0]["category"], "unreviewed")

    def test_session_id_from_env(self):
        self.write("a.txt", "x\n")
        self.stage("a.txt")
        self.gate(CLAUDE_SESSION_ID="sess-42")
        self.assertEqual(self.rows()[0]["session_id"], "sess-42")


if __name__ == "__main__":
    unittest.main()
