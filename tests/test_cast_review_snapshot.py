#!/usr/bin/env python3
"""Tests for scripts/cast_review_snapshot.py -- content-bound review gate library (U1a).

Every test runs under an isolated temp HOME and a temp CAST_DB_PATH; git repos are built in
temp dirs with a GIT_*-scrubbed environment. Never touches the real ~/.claude or cast.db.
"""
import hashlib
import json
import os
import shutil
import sqlite3
import stat
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

import cast_review_snapshot as crs  # noqa: E402

_MIGRATION = _REPO / "scripts" / "migrations" / "037_review_snapshots.sql"
_DB_INIT = _REPO / "scripts" / "cast-db-init.sh"


def _clean_env(home):
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    env.update(
        HOME=home,
        GIT_CONFIG_NOSYSTEM="1",
        GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@t",
        GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@t",
    )
    return env


class _TmpCase(unittest.TestCase):
    def setUp(self):
        self.tmp = os.path.realpath(tempfile.mkdtemp(prefix="cast-review-snap-"))
        self.home = os.path.join(self.tmp, "home")
        os.makedirs(self.home)
        self._old_home = os.environ.get("HOME")
        os.environ["HOME"] = self.home
        self.addCleanup(self._cleanup)

    def _cleanup(self):
        if self._old_home is None:
            os.environ.pop("HOME", None)
        else:
            os.environ["HOME"] = self._old_home
        assert self.tmp.startswith(os.path.realpath(tempfile.gettempdir()))
        shutil.rmtree(self.tmp, ignore_errors=True)

    def git(self, repo, *args):
        r = subprocess.run(
            ["git", "-C", repo] + list(args), env=_clean_env(self.home),
            stdin=subprocess.DEVNULL, capture_output=True, text=True,
        )
        self.assertEqual(r.returncode, 0, r.stderr)
        return r.stdout.strip()

    def make_repo(self, name="repo"):
        repo = os.path.join(self.tmp, name)
        os.makedirs(repo)
        self.git(repo, "init", "-q")
        self.git(repo, "config", "commit.gpgsign", "false")
        return repo

    @staticmethod
    def write(repo, rel, content=b"x\n"):
        full = os.path.join(repo, rel)
        os.makedirs(os.path.dirname(full), exist_ok=True)
        with open(full, "wb") as fh:
            fh.write(content)
        return full

    def blob(self, repo, rel):
        return self.git(repo, "hash-object", "--", rel)


class TakeSnapshotTests(_TmpCase):
    def committed_repo(self):
        repo = self.make_repo()
        self.write(repo, "keep.txt", b"keep\n")
        self.write(repo, "mod.txt", b"one\n")
        self.write(repo, "gone.txt", b"gone\n")
        self.write(repo, "old_name.txt", b"rename me, long enough content\n" * 5)
        self.write(repo, ".gitignore", b"ignored.log\n")
        self.git(repo, "add", "-A")
        self.git(repo, "commit", "-q", "-m", "init")
        return repo

    def test_clean_repo_has_empty_file_set(self):
        repo = self.committed_repo()
        snap = crs.take_snapshot(repo)
        self.assertEqual(snap, {"repo_root": repo, "files": {}})

    def test_modified_added_deleted_untracked_ignored(self):
        repo = self.committed_repo()
        self.write(repo, "mod.txt", b"two\n")                    # modified (unstaged)
        self.write(repo, "added.txt", b"added\n")                # added (staged)
        self.git(repo, "add", "added.txt")
        os.unlink(os.path.join(repo, "gone.txt"))                # deleted
        self.write(repo, "sub/dir/new.txt", b"untracked\n")      # untracked, nested
        self.write(repo, "ignored.log", b"nope\n")               # ignored -> excluded
        snap = crs.take_snapshot(repo)
        self.assertIsNotNone(snap)
        files = snap["files"]
        self.assertEqual(
            sorted(files), ["added.txt", "gone.txt", "mod.txt", "sub/dir/new.txt"])
        self.assertEqual(files["gone.txt"], "DELETED")
        for rel in ("mod.txt", "added.txt", "sub/dir/new.txt"):
            self.assertEqual(files[rel], self.blob(repo, rel), rel)
        self.assertNotIn("ignored.log", files)

    def test_staged_then_edited_records_worktree_content(self):
        repo = self.committed_repo()
        self.write(repo, "mod.txt", b"staged\n")
        self.git(repo, "add", "mod.txt")
        self.write(repo, "mod.txt", b"edited after staging\n")
        files = crs.take_snapshot(repo)["files"]
        self.assertEqual(files["mod.txt"], self.blob(repo, "mod.txt"))

    def test_rename_old_path_deleted_new_path_hashed(self):
        repo = self.committed_repo()
        self.git(repo, "mv", "old_name.txt", "new_name.txt")
        files = crs.take_snapshot(repo)["files"]
        self.assertEqual(files["old_name.txt"], "DELETED")
        self.assertEqual(files["new_name.txt"], self.blob(repo, "new_name.txt"))
        self.assertEqual(len(files), 2)

    def test_symlink_hashed_as_link_text_and_never_followed(self):
        repo = self.committed_repo()
        secret = os.path.join(self.tmp, "outside-secret.txt")
        with open(secret, "wb") as fh:
            fh.write(b"outside the repo\n")
        os.symlink(secret, os.path.join(repo, "link"))
        files = crs.take_snapshot(repo)["files"]
        target = os.fsencode(secret)
        want = hashlib.sha1(b"blob %d\0" % len(target) + target).hexdigest()
        self.assertEqual(files["link"], want)
        self.git(repo, "add", "link")  # what git itself stores for the symlink
        self.assertEqual(files["link"], self.git(repo, "ls-files", "-s", "link").split()[1])
        self.assertNotEqual(files["link"], hashlib.sha1(
            b"blob 17\0outside the repo\n").hexdigest())

    def test_dangling_symlink_is_recorded_not_dropped(self):
        repo = self.committed_repo()
        os.symlink("/nonexistent/target", os.path.join(repo, "dangling"))
        self.assertIn("dangling", crs.take_snapshot(repo)["files"])

    def test_path_count_bound_returns_none(self):
        repo = self.committed_repo()
        with mock.patch.object(crs, "MAX_PATHS", 3):
            for i in range(4):
                self.write(repo, "n%d.txt" % i)
            self.assertIsNone(crs.take_snapshot(repo))

    def test_path_count_at_bound_is_ok(self):
        repo = self.committed_repo()
        with mock.patch.object(crs, "MAX_PATHS", 3):
            for i in range(3):
                self.write(repo, "n%d.txt" % i)
            self.assertEqual(len(crs.take_snapshot(repo)["files"]), 3)

    def test_byte_bound_returns_none(self):
        repo = self.committed_repo()
        with mock.patch.object(crs, "MAX_BYTES", 100):
            self.write(repo, "big.bin", b"a" * 101)
            self.assertIsNone(crs.take_snapshot(repo))

    def test_hash_batching_covers_all_files(self):
        repo = self.committed_repo()
        with mock.patch.object(crs, "_HASH_BATCH", 2):
            for i in range(5):
                self.write(repo, "b%d.txt" % i, b"content %d\n" % i)
            files = crs.take_snapshot(repo)["files"]
        self.assertEqual(len(files), 5)
        for i in range(5):
            self.assertEqual(files["b%d.txt" % i], self.blob(repo, "b%d.txt" % i))

    def test_non_repo_returns_none(self):
        plain = os.path.join(self.tmp, "plain")
        os.makedirs(plain)
        self.assertIsNone(crs.take_snapshot(plain))

    def test_missing_dir_and_bad_input_return_none(self):
        self.assertIsNone(crs.take_snapshot(os.path.join(self.tmp, "nope")))
        self.assertIsNone(crs.take_snapshot(""))
        self.assertIsNone(crs.take_snapshot(None))  # type: ignore[arg-type]

    def test_git_unavailable_returns_none(self):
        repo = self.committed_repo()
        with mock.patch.object(crs, "_git", return_value=None):
            self.assertIsNone(crs.take_snapshot(repo))

    def test_subdirectory_start_reports_toplevel_relative_paths(self):
        repo = self.committed_repo()
        self.write(repo, "sub/f.txt")
        snap = crs.take_snapshot(os.path.join(repo, "sub"))
        self.assertEqual(snap["repo_root"], repo)
        self.assertIn("sub/f.txt", snap["files"])

    def test_newline_path_omitted_rest_kept(self):
        repo = self.committed_repo()
        try:
            self.write(repo, "nl\nname.txt")
        except OSError:
            self.skipTest("filesystem rejects newline names")
        self.write(repo, "fine.txt")
        snap = crs.take_snapshot(repo)
        self.assertIsNotNone(snap)
        self.assertEqual(sorted(snap["files"]), ["fine.txt"])

    def test_sha256_object_format_used_for_symlinks(self):
        repo = self.committed_repo()
        os.symlink("tgt", os.path.join(repo, "l"))
        real_git = crs._git

        def fake(repo_dir, args, timeout=30.0):
            if args[:2] == ["rev-parse", "--show-object-format"]:
                import subprocess as sp
                return sp.CompletedProcess(args, 0, "sha256\n", "")
            return real_git(repo_dir, args, timeout)
        with mock.patch.object(crs, "_git", side_effect=fake):
            val = crs.take_snapshot(repo)["files"]["l"]
        self.assertEqual(val, hashlib.sha256(b"blob 3\0tgt").hexdigest())

    def test_resolve_repo_root(self):
        repo = self.committed_repo()
        self.assertEqual(crs.resolve_repo_root(os.path.join(repo)), repo)
        plain = os.path.join(self.tmp, "plain2")
        os.makedirs(plain)
        self.assertEqual(crs.resolve_repo_root(plain), plain)  # documented cwd fallback
        self.assertIsNone(crs.resolve_repo_root(""))

    def test_non_utf8_path_does_not_raise(self):
        repo = self.committed_repo()
        raw = os.path.join(os.fsencode(repo), b"bad\xff.txt")
        try:
            with open(raw, "wb") as fh:
                fh.write(b"x\n")
        except OSError:
            self.skipTest("filesystem rejects non-UTF-8 names")
        snap = crs.take_snapshot(repo)  # must not raise; value or None both acceptable
        if snap is not None:
            self.assertEqual(len(snap["files"]), 1)


class StableFilesTests(unittest.TestCase):
    def test_keeps_only_identical_entries(self):
        a = {"repo_root": "/r", "files": {"a": "1", "b": "2", "c": "3", "d": "DELETED"}}
        b = {"repo_root": "/r", "files": {"a": "1", "b": "CHANGED", "d": "DELETED", "e": "9"}}
        self.assertEqual(crs.stable_files(a, b), {"a": "1", "d": "DELETED"})

    def test_requires_same_repo_root(self):
        a = {"repo_root": "/r1", "files": {"a": "1"}}
        b = {"repo_root": "/r2", "files": {"a": "1"}}
        self.assertEqual(crs.stable_files(a, b), {})

    def test_bad_input_is_empty(self):
        good = {"repo_root": "/r", "files": {"a": "1"}}
        for bad in (None, {}, {"repo_root": "/r"}, {"repo_root": "", "files": {}}, "x"):
            self.assertEqual(crs.stable_files(bad, good), {})
            self.assertEqual(crs.stable_files(good, bad), {})


class ParseVerdictTests(unittest.TestCase):
    OK = "Verdict: APPROVE"
    ST = "Status: DONE"

    def pv(self, *lines):
        return crs.parse_verdict("\n".join(lines))

    def test_strict_approve_adjacent_status_both_orders(self):
        for text in (
            "Review text.\nVerdict: APPROVE\nStatus: DONE\n",
            "Review text.\nStatus: DONE\nVerdict: APPROVE\n",
            "Verdict: APPROVE\n\n\nStatus: DONE_WITH_CONCERNS\n",      # blank lines allowed
            "Status: DONE\n\nVerdict: APPROVE",
            "**Verdict: APPROVE**\n**Status:** DONE",
            "**Verdict:** APPROVE\nStatus: **DONE**",
            "__Verdict: APPROVE__\n__Status: DONE__",
            "**Verdict:** **APPROVE**\nStatus: DONE",
            "Verdict: APPROVE   \nStatus: DONE   ",                       # trailing blanks
            "Verdict: APPROVE\r\nStatus: DONE\r\n",
            "Summary\n\nVerdict: APPROVE\nStatus: DONE\n\nWork log\n- a\n- b\n",
        ):
            self.assertEqual(crs.parse_verdict(text), "APPROVE", repr(text))

    def test_strict_approve_not_adjacent_to_status_is_blocked(self):
        for text in (
            "Verdict: APPROVE",
            "Verdict: APPROVE\nsomething\nStatus: DONE",
            "Status: DONE\nsomething\nVerdict: APPROVE",
            "Verdict: APPROVE\nStatus: BLOCKED",
            "Verdict: APPROVE\nStatus: NEEDS_CONTEXT",
            "Verdict: APPROVE\nStatus: DONE_WITH_CONCERNS_X",
            "Verdict: APPROVE\n- Status: DONE",                           # prefixed status
            "Verdict: APPROVE\n  Status: DONE",
            "Verdict: APPROVE\nstatus: done",
            "Verdict: APPROVE\nStatus: DONE | BLOCKED",
        ):
            self.assertEqual(crs.parse_verdict(text), "BLOCKED", repr(text))

    def test_status_blocked_adjacent_is_blocked(self):
        self.assertEqual(self.pv(self.OK, "Status: BLOCKED"), "BLOCKED")
        self.assertEqual(self.pv("Status: BLOCKED", self.OK), "BLOCKED")

    def test_tail_window_of_15_nonblank_lines(self):
        filler = ["line %d" % i for i in range(20)]
        far = filler + [self.OK, self.ST] + ["tail %d" % i for i in range(14)]
        self.assertEqual(self.pv(*far), "BLOCKED")                 # 14 lines after: 16th from end
        near = filler + [self.OK, self.ST] + ["tail %d" % i for i in range(13)]
        self.assertEqual(self.pv(*near), "APPROVE")               # 15th from the end
        way_off = [self.OK, self.ST] + filler
        self.assertEqual(self.pv(*way_off), "BLOCKED")
        # blank lines do not count against the window
        padded = [self.OK, self.ST] + ["t%d\n" % i for i in range(13)]
        self.assertEqual(self.pv(*padded), "APPROVE")

    def test_widened_verdict_detection_counts_as_second_verdict_line(self):
        for bad in ("Verdict - BLOCKED", "**Verdict** \u2014 BLOCKED", "Verdict BLOCKED",
                    "verdict: reject", "Verdict -- REJECTED", "VERDICT (approve)",
                    "verdict - approve", "Verdict APPROVE"):
            for text in (bad + "\n" + self.OK + "\n" + self.ST,
                         self.OK + "\n" + self.ST + "\n" + bad):
                self.assertEqual(crs.parse_verdict(text), "BLOCKED", (bad, text))
            self.assertEqual(crs.parse_verdict(bad), "BLOCKED", bad)

    def test_prose_with_words_between_is_not_a_verdict_line(self):
        for prose in ("the verdict should block the merge", "A verdict of sorts, then approve it",
                      "verdict " + "x" * 50 + " block"):
            self.assertEqual(self.pv(prose, self.OK, self.ST), "APPROVE", prose)

    def test_nbsp_status_is_not_adjacent(self):
        self.assertEqual(self.pv(self.OK, "Status:\u00a0DONE"), "BLOCKED")
        self.assertEqual(self.pv(self.OK, "Status: DONE\u00a0"), "BLOCKED")
        self.assertEqual(self.pv(self.OK, "Status:\tDONE\t "), "APPROVE")  # tabs/spaces fine

    def test_invisible_only_lines_count_as_blank(self):
        self.assertEqual(self.pv(self.OK, "\u200b", "  \u2060 ", self.ST), "APPROVE")
        pad = ["\u200b"] * 40
        self.assertEqual(self.pv(self.OK, self.ST, *pad), "APPROVE")  # not counted in the window

    def test_out_of_scope_obfuscated_own_status_is_not_detected(self):
        # BOUNDARY (see the verdict section of the module docstring): a reviewer whose OWN
        # Status is obfuscated is out of scope. The adjacent genuine `Status: DONE` still
        # anchors the strict APPROVE; the ZWSP-split line is neither a verdict line nor a Status.
        self.assertEqual(
            self.pv("Status: DONE", self.OK, "Sta\u200btus: BLOCKED"), "APPROVE")

    def test_two_verdict_lines_are_blocked(self):
        self.assertEqual(self.pv(self.OK, self.OK, self.ST), "BLOCKED")
        self.assertEqual(self.pv(self.OK, self.ST, self.OK, self.ST), "BLOCKED")
        self.assertEqual(self.pv("```", self.OK, "```", self.OK, self.ST), "BLOCKED")
        self.assertEqual(self.pv("> " + self.OK, self.OK, self.ST), "BLOCKED")

    def test_fence_closer_disagreement_probes_never_approve(self):
        # r3 High: a closer our parser/CommonMark disagree on, with a quoted example inside.
        for closer in ("```\x0b", "```\u00a0", "```\u200b", "```\u2028", "``` ", "```\x0c",
                       "~~~\u200b", "````"):
            for body in (
                ["```", self.OK, closer, "real prose", self.ST],           # no real verdict
                ["```", self.OK, closer, self.OK, self.ST],                # plus a real one
                ["```", self.OK, self.ST, closer, "Verdict: BLOCKED"],
            ):
                got = self.pv(*body)
                self.assertNotEqual(got, "APPROVE", (closer, body))

    def test_documented_residual_lone_quoted_pair_reads_as_approve(self):
        # ACCEPTED residual (module docstring): no Markdown parsing, so a lone strict
        # Verdict + Status pair as the only verdict line is APPROVE even if it is quoted.
        self.assertEqual(self.pv("```", self.OK, self.ST, "```"), "APPROVE")
        # ...but two of them, or any other verdict line, never does.
        self.assertEqual(self.pv("```", self.OK, self.ST, "```", self.OK, self.ST), "BLOCKED")

    def test_prefixed_and_decorated_verdict_lines_are_blocked(self):
        for text in ("- Verdict: APPROVE", "* Verdict: APPROVE", "* **Verdict:** **APPROVE**",
                     "> Verdict: APPROVE", "> - Verdict: APPROVE", " Verdict: APPROVE",
                     "    Verdict: APPROVE", "\tVerdict: APPROVE", "1. Verdict: APPROVE",
                     "Findings:\n- Verdict: APPROVE (quoted from the diff)\n"):
            self.assertEqual(crs.parse_verdict(text + "\nStatus: DONE"), "BLOCKED", repr(text))

    def test_non_strict_verdict_lines_are_blocked(self):
        for text in ("Verdict:", "Verdict: MAYBE", "Verdict: APPROVED", "x Verdict: APPROVE",
                     "Verdict: APPROVE | BLOCKED", "> Verdict: APPROVE | BLOCKED",
                     "Use `Verdict: APPROVE` or `other`", "verdict: approve",
                     "Verdict: Approve", "Verdict:APPROVE", "**Verdict:**APPROVE",
                     "the Verdict: line is required", "Verdict: BLOCK", "Verdict: BLOCKED",
                     "Verdict: REJECTED", "Verdict: BLOCKING", "Verdict *: BLOCK"):
            self.assertEqual(crs.parse_verdict(text), "BLOCKED", repr(text))
            self.assertEqual(crs.parse_verdict(text + "\nStatus: DONE"), "BLOCKED", repr(text))

    def test_invisible_character_probes_are_blocked_alone_and_paired(self):
        probes = {
            "nbsp": "Verdict:\u00a0BLOCKED",
            "zwsp": "Verdict:\u200bBLOCKED",
            "zwsp_in_word": "Ver\u200bdict: BLOCKED",
            "nul_in_word": "Ver\x00dict: BLOCKED",
            "ctl_in_word": "Ver\x01dict: BLOCKED",
            "bom": "\ufeffVerdict: BLOCKED",
            "word_joiner": "Verdict\u2060: BLOCKED",
            "fullwidth_colon": "Verdict\uff1aBLOCKED",
            "fullwidth_word": "\uff36erdict: BLOCKED",
            "line_separator": "Verdict: BLOCKED\u2028",
            "emphasis_space": "Verdict *: BLOCK",
        }
        for name, bad in probes.items():
            self.assertEqual(crs.parse_verdict(bad), "BLOCKED", name)
            for text in (bad + "\n" + self.OK + "\n" + self.ST,
                         self.OK + "\n" + self.ST + "\n" + bad):
                self.assertEqual(crs.parse_verdict(text), "BLOCKED", (name, text))

    def test_strict_line_must_equal_its_normalised_form(self):
        # NBSP / ZWSP / tab inside the line are normalised away for detection, but the RAW line
        # is then not the strict form -> BLOCKED (r4: raw must equal normalised).
        for text in ("Verdict:\u00a0APPROVE", "Verdict: AP\u200bPROVE", "Verdict:\tAPPROVE",
                     "Verdict: APPROVE\u200b", "\u200bVerdict: APPROVE"):
            self.assertEqual(crs.parse_verdict(text + "\nStatus: DONE"), "BLOCKED", repr(text))

    def test_missing_or_garbage_is_none(self):
        for text in ("", "Status: DONE", "no verdict here", "the verdict was reached by the team",
                     "The verdict is still out.\nStatus: DONE\n",
                     None, 5):
            self.assertIsNone(crs.parse_verdict(text), repr(text))  # type: ignore[arg-type]

    def test_oversized_is_blocked_at_any_position(self):
        pad = "x" * (crs.MAX_VERDICT_TEXT + 10)
        for text in ("Verdict: BLOCKED\n" + pad, pad + "\nVerdict: APPROVE\nStatus: DONE",
                     "Verdict: APPROVE\nStatus: DONE\n" + pad):
            self.assertEqual(crs.parse_verdict(text), "BLOCKED")

    def test_pathological_input_is_fast(self):
        import time
        t0 = time.time()
        crs.parse_verdict("Verdict:" + " " * 200000 + "x")
        crs.parse_verdict("**" * 200000)
        crs.parse_verdict("> " * 200000 + "Verdict: APPROVE")
        crs.parse_verdict("Verdict *" * 100000)
        crs.parse_verdict("\u00e9 x\n" * 50000 + "Verdict: APPROVE\nStatus: DONE")
        crs.parse_verdict("Status:" + " " * 200000 + "x\nVerdict: APPROVE")
        self.assertLess(time.time() - t0, 5.0)


class DecideTests(unittest.TestCase):
    def test_matrix(self):
        for v in ("APPROVE", "BLOCKED", None, "junk"):
            for s in ("DONE", "DONE_WITH_CONCERNS", "BLOCKED", "NEEDS_CONTEXT", None, ""):
                want = "APPROVE" if v == "APPROVE" and s in ("DONE", "DONE_WITH_CONCERNS") \
                    else "BLOCKED"
                self.assertEqual(crs.decide(v, s), want, (v, s))


class RecordTests(_TmpCase):
    def setUp(self):
        super().setUp()
        self.db = os.path.join(self.tmp, "cast.db")
        conn = sqlite3.connect(self.db)
        conn.executescript(_MIGRATION.read_text())
        conn.close()

    def rec(self, **over):
        kw = dict(session_id="s1", agent_id="a1", reviewer="code-reviewer",
                  repo_root="/r", decision="APPROVE",
                  started_at="2026-10-15T00:00:00Z", ended_at="2026-10-15T00:01:00Z",
                  files={"a.py": "a" * 40, "b.py": "DELETED"})
        kw.update(over)
        return crs.record(self.db, **kw)

    def rows(self, sql):
        conn = sqlite3.connect(self.db)
        try:
            return conn.execute(sql).fetchall()
        finally:
            conn.close()

    def test_writes_parent_and_children(self):
        self.assertTrue(self.rec())
        parent = self.rows("SELECT session_id, agent_id, reviewer, repo_root, decision, "
                           "started_at, ended_at, created_at FROM review_snapshots")
        self.assertEqual(len(parent), 1)
        self.assertEqual(parent[0][:7], ("s1", "a1", "code-reviewer", "/r", "APPROVE",
                                         "2026-10-15T00:00:00Z", "2026-10-15T00:01:00Z"))
        self.assertTrue(parent[0][7])
        kids = self.rows("SELECT path, blob FROM review_snapshot_files ORDER BY path")
        self.assertEqual(kids, [("a.py", "a" * 40), ("b.py", "DELETED")])

    def test_empty_files_still_records_parent(self):
        self.assertTrue(self.rec(files={}))
        self.assertEqual(self.rows("SELECT count(*) FROM review_snapshots"), [(1,)])
        self.assertEqual(self.rows("SELECT count(*) FROM review_snapshot_files"), [(0,)])

    def test_two_records_link_to_their_own_parent(self):
        self.assertTrue(self.rec(agent_id="a1", files={"x": "1" * 40}))
        self.assertTrue(self.rec(agent_id="a2", decision="BLOCKED", files={"x": "2" * 40}))
        got = self.rows("SELECT s.agent_id, s.decision, f.blob FROM review_snapshots s "
                        "JOIN review_snapshot_files f ON f.snapshot_id = s.id ORDER BY s.id")
        self.assertEqual(got, [("a1", "APPROVE", "1" * 40), ("a2", "BLOCKED", "2" * 40)])

    def test_bad_db_path_returns_false_and_creates_nothing(self):
        missing = os.path.join(self.tmp, "nodir", "x.db")
        self.assertFalse(crs.record(missing, session_id=None, agent_id=None,
                                    reviewer="r", repo_root="/r", decision="APPROVE",
                                    started_at=None, ended_at=None, files={}))
        self.assertFalse(os.path.exists(missing))
        absent = os.path.join(self.tmp, "absent.db")
        self.assertFalse(crs.record(absent, session_id=None, agent_id=None,
                                    reviewer="r", repo_root="/r", decision="APPROVE",
                                    started_at=None, ended_at=None, files={}))
        self.assertFalse(os.path.exists(absent))  # mode=rw never creates the file

    def test_db_without_tables_returns_false(self):
        empty = os.path.join(self.tmp, "empty.db")
        sqlite3.connect(empty).close()
        self.assertFalse(crs.record(empty, session_id=None, agent_id=None, reviewer="r",
                                    repo_root="/r", decision="APPROVE", started_at=None,
                                    ended_at=None, files={}))

    def test_bad_decision_or_args_return_false(self):
        self.assertFalse(self.rec(decision="MAYBE"))
        self.assertFalse(self.rec(reviewer=""))
        self.assertFalse(self.rec(repo_root=""))
        self.assertFalse(self.rec(files=None))
        self.assertEqual(self.rows("SELECT count(*) FROM review_snapshots"), [(0,)])

    def test_failure_midway_rolls_back_parent(self):
        # a child with a NULL blob violates NOT NULL after the parent insert succeeded
        self.assertFalse(self.rec(files={"ok": "1" * 40, "bad": None}))
        self.assertEqual(self.rows("SELECT count(*) FROM review_snapshots"), [(0,)])
        self.assertEqual(self.rows("SELECT count(*) FROM review_snapshot_files"), [(0,)])

    def test_session_and_agent_ids_must_be_str_or_none(self):
        self.assertFalse(self.rec(session_id=5))
        self.assertFalse(self.rec(agent_id=["a"]))
        self.assertTrue(self.rec(session_id=None, agent_id=None))
        kw = dict(session_id=None, agent_id=None, reviewer="r", repo_root="/r",
                  started_at=None, ended_at=None)
        self.assertFalse(crs.record_degraded_block(self.db, **dict(kw, session_id=1)))
        self.assertFalse(crs.record_degraded_block(self.db, **dict(kw, agent_id=2)))

    def test_empty_path_rejected(self):
        self.assertFalse(self.rec(files={"": "1" * 40}))
        self.assertEqual(self.rows("SELECT count(*) FROM review_snapshots"), [(0,)])

    def test_scope_defaults_to_files(self):
        self.assertTrue(self.rec())
        self.assertEqual(self.rows("SELECT scope FROM review_snapshots"), [("files",)])

    def test_degraded_block_writes_repo_scope_blocked_no_files(self):
        self.assertTrue(crs.record_degraded_block(
            self.db, session_id="s1", agent_id="a1", reviewer="code-reviewer",
            repo_root="/r", started_at="t0", ended_at="t1"))
        self.assertEqual(self.rows(
            "SELECT decision, scope, repo_root, reviewer FROM review_snapshots"),
            [("BLOCKED", "repo", "/r", "code-reviewer")])
        self.assertEqual(self.rows("SELECT count(*) FROM review_snapshot_files"), [(0,)])

    def test_degraded_block_bad_args_or_db_return_false(self):
        kw = dict(session_id=None, agent_id=None, reviewer="r", repo_root="/r",
                  started_at=None, ended_at=None)
        self.assertFalse(crs.record_degraded_block(os.path.join(self.tmp, "no.db"), **kw))
        self.assertFalse(crs.record_degraded_block(self.db, **dict(kw, repo_root="")))
        self.assertFalse(crs.record_degraded_block(self.db, **dict(kw, reviewer="")))

    def test_record_validates_path_and_blob_shapes(self):
        for bad in ({"a": "XYZ"}, {"a": "A" * 40}, {"a": "1" * 39}, {"a": "1" * 41},
                    {"a": 5}, {5: "1" * 40}, {"a": None}):
            self.assertFalse(self.rec(files=bad), repr(bad))
        self.assertTrue(self.rec(files={"a": "1" * 64, "b": "2" * 40, "c": "DELETED"}))
        self.assertEqual(self.rows("SELECT count(*) FROM review_snapshots"), [(1,)])

    def test_record_stores_non_utf8_paths_via_path_key(self):
        weird = os.fsdecode(b"bad\xff.txt")  # surrogate-escaped, as os/git give us
        self.assertTrue(self.rec(files={weird: "1" * 40, "plain.txt": "2" * 40}))
        got = dict(self.rows("SELECT path, blob FROM review_snapshot_files"))
        self.assertEqual(got[crs.path_key(weird)], "1" * 40)
        self.assertEqual(got["plain.txt"], "2" * 40)
        self.assertEqual(crs.path_key(weird), "\x00b:" + b"bad\xff.txt".hex())

    def test_path_key_is_identity_for_utf8_and_injective(self):
        self.assertEqual(crs.path_key("dir/f\u00e9.txt"), "dir/f\u00e9.txt")
        keys = {crs.path_key(os.fsdecode(b"a\xff")), crs.path_key(os.fsdecode(b"a\xfe")),
                crs.path_key("a")}
        self.assertEqual(len(keys), 3)
        self.assertIsInstance(crs.path_key("\ud800"), str)  # lone surrogate: no raise

    def test_default_db_path_honours_env(self):
        with mock.patch.dict(os.environ, {"CAST_DB_PATH": "/x/y.db"}):
            self.assertEqual(crs.default_db_path(), "/x/y.db")


class SchemaTests(_TmpCase):
    def test_db_init_creates_both_tables_idempotently(self):
        db = os.path.join(self.tmp, "init.db")
        for _ in range(2):
            r = subprocess.run(["bash", str(_DB_INIT), "--db", db], env=dict(
                os.environ, HOME=self.home), capture_output=True, text=True, timeout=120)
            self.assertEqual(r.returncode, 0, r.stderr[-500:])
        conn = sqlite3.connect(db)
        try:
            names = {r[0] for r in conn.execute(
                "SELECT name FROM sqlite_master WHERE type='table'")}
            self.assertIn("review_snapshots", names)
            self.assertIn("review_snapshot_files", names)
            with self.assertRaises(sqlite3.IntegrityError):
                conn.execute("INSERT INTO review_snapshots (reviewer, repo_root, decision) "
                             "VALUES ('r', '/r', 'MAYBE')")
            fk = conn.execute("PRAGMA foreign_key_list(review_snapshot_files)").fetchall()
            self.assertEqual(fk[0][2], "review_snapshots")
        finally:
            conn.close()
        # the production writer works against a db-init-built schema too
        self.assertTrue(crs.record(db, session_id="s", agent_id="a", reviewer="code-reviewer",
                                   repo_root="/r", decision="BLOCKED", started_at=None,
                                   ended_at=None, files={"p": "b" * 40}))

    def test_migration_matches_init_columns(self):
        db_init = os.path.join(self.tmp, "init.db")
        subprocess.run(["bash", str(_DB_INIT), "--db", db_init], env=dict(
            os.environ, HOME=self.home), capture_output=True, text=True, timeout=120,
            check=True)
        db_mig = os.path.join(self.tmp, "mig.db")
        conn = sqlite3.connect(db_mig)
        conn.executescript(_MIGRATION.read_text())
        conn.executescript(_MIGRATION.read_text())  # idempotent
        conn.close()

        def cols(path, table):
            c = sqlite3.connect(path)
            try:
                return [r[1:4] for r in c.execute("PRAGMA table_info(%s)" % table)]
            finally:
                c.close()
        for t in ("review_snapshots", "review_snapshot_files"):
            self.assertEqual(cols(db_init, t), cols(db_mig, t), t)

    def test_cascade_delete(self):
        db = os.path.join(self.tmp, "m.db")
        conn = sqlite3.connect(db)
        conn.executescript(_MIGRATION.read_text())
        conn.close()
        self.assertTrue(crs.record(db, session_id=None, agent_id=None, reviewer="r",
                                   repo_root="/r", decision="APPROVE", started_at=None,
                                   ended_at=None, files={"p": "c" * 40}))
        conn = sqlite3.connect(db)
        conn.execute("PRAGMA foreign_keys=ON")
        conn.execute("DELETE FROM review_snapshots")
        self.assertEqual(conn.execute("SELECT count(*) FROM review_snapshot_files")
                         .fetchone()[0], 0)
        conn.close()


class StartPersistenceTests(_TmpCase):
    def setUp(self):
        super().setUp()
        self.sd = os.path.join(self.tmp, "state", "review-snapshots")
        self.snap = {"repo_root": "/r", "files": {"a": "1" * 40, "b": "DELETED"}}
        self.K = dict(session_id="sess-1", reviewer="code-reviewer")

    def test_round_trip_mode_and_removal(self):
        self.assertTrue(crs.save_start(self.sd, "agent-1_A", self.snap, **self.K))
        path = os.path.join(self.sd, "agent-1_A.json")
        self.assertEqual(stat.S_IMODE(os.stat(path).st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(os.stat(self.sd).st_mode), 0o700)
        got = crs.load_start(self.sd, "agent-1_A", **self.K)
        self.assertRegex(got.pop("started_at"), r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$")
        self.assertEqual(got, self.snap)
        self.assertFalse(os.path.exists(path))
        self.assertIsNone(crs.load_start(self.sd, "agent-1_A", **self.K))  # consumed
        self.assertEqual([n for n in os.listdir(self.sd)], [])    # no tmp litter

    def test_bad_agent_ids_rejected(self):
        for bad in ("", "../x", "a/b", "a b", "a.b", "x" * 129, None, 5, "a\n"):
            self.assertFalse(crs.save_start(self.sd, bad, self.snap, **self.K), repr(bad))
            self.assertIsNone(crs.load_start(self.sd, bad, **self.K), repr(bad))
        self.assertTrue(crs.save_start(self.sd, "x" * 128, self.snap, **self.K))

    def test_overwrite_replaces_atomically(self):
        self.assertTrue(crs.save_start(self.sd, "a1", self.snap, **self.K))
        newer = {"repo_root": "/r2", "files": {}}
        self.assertTrue(crs.save_start(self.sd, "a1", newer, **self.K))
        got = crs.load_start(self.sd, "a1", **self.K)
        got.pop("started_at")
        self.assertEqual(got, newer)

    def test_symlinked_state_file_refused(self):
        os.makedirs(self.sd, mode=0o700)
        target = os.path.join(self.tmp, "elsewhere.json")
        with open(target, "w") as fh:
            json.dump(self.snap, fh)
        os.symlink(target, os.path.join(self.sd, "evil.json"))
        self.assertIsNone(crs.load_start(self.sd, "evil", **self.K))
        self.assertTrue(os.path.exists(target))  # the symlink target is never touched

    def test_symlinked_state_dir_refused(self):
        real = os.path.join(self.tmp, "real")
        os.makedirs(real, mode=0o700)
        link = os.path.join(self.tmp, "linkdir")
        os.symlink(real, link)
        self.assertFalse(crs.save_start(link, "a1", self.snap, **self.K))
        self.assertEqual(os.listdir(real), [])

    def test_writable_state_dir_refused(self):
        os.makedirs(self.sd, mode=0o700)
        os.chmod(self.sd, 0o777)
        self.assertFalse(crs.save_start(self.sd, "a1", self.snap, **self.K))

    def test_oversized_file_refused(self):
        os.makedirs(self.sd, mode=0o700)
        with mock.patch.object(crs, "MAX_STATE_BYTES", 50):
            with open(os.path.join(self.sd, "big.json"), "w") as fh:
                fh.write(json.dumps(self.snap) + " " * 100)
            self.assertIsNone(crs.load_start(self.sd, "big", **self.K))
            self.assertFalse(crs.save_start(self.sd, "big2", {
                "repo_root": "/r", "files": {"k%d" % i: "v" for i in range(20)}}, **self.K))

    def test_malformed_content_is_none(self):
        os.makedirs(self.sd, mode=0o700)
        for name, body in (("junk", "not json"), ("lst", "[]"),
                           ("noroot", '{"files": {}}'),
                           ("badfiles", '{"repo_root": "/r", "files": {"a": 1}}')):
            with open(os.path.join(self.sd, name + ".json"), "w") as fh:
                fh.write(body)
            self.assertIsNone(crs.load_start(self.sd, name, **self.K), name)

    def test_binding_requires_matching_session_and_reviewer(self):
        for kw in (dict(session_id="other", reviewer="code-reviewer"),
                   dict(session_id="sess-1", reviewer="security"),
                   dict(session_id=None, reviewer="code-reviewer")):
            self.assertTrue(crs.save_start(self.sd, "a1", self.snap, **self.K))
            self.assertIsNone(crs.load_start(self.sd, "a1", **kw), kw)
            self.assertFalse(os.path.exists(os.path.join(self.sd, "a1.json")))  # consumed
        self.assertTrue(crs.save_start(self.sd, "a1", self.snap, session_id=None,
                                       reviewer="code-reviewer"))
        got = crs.load_start(self.sd, "a1", session_id=None, reviewer="code-reviewer")
        got.pop("started_at")
        self.assertEqual(got, self.snap)

    def test_bare_snapshot_file_without_binding_envelope_is_refused(self):
        os.makedirs(self.sd, mode=0o700)
        with open(os.path.join(self.sd, "old.json"), "w") as fh:
            json.dump(self.snap, fh)
        self.assertIsNone(crs.load_start(self.sd, "old", **self.K))

    def test_fifo_state_file_does_not_hang(self):
        os.makedirs(self.sd, mode=0o700)
        os.mkfifo(os.path.join(self.sd, "pipe.json"))
        import signal
        signal.alarm(10)
        try:
            self.assertIsNone(crs.load_start(self.sd, "pipe", **self.K))
        finally:
            signal.alarm(0)

    def test_stale_tmp_swept_fresh_kept(self):
        os.makedirs(self.sd, mode=0o700)
        old = os.path.join(self.sd, ".dead.1.tmp")
        new = os.path.join(self.sd, ".live.2.tmp")
        keep = os.path.join(self.sd, "notes.txt")
        for pth in (old, new, keep):
            with open(pth, "w") as fh:
                fh.write("x")
        t = __import__("time").time() - 7200
        os.utime(old, (t, t))
        os.utime(keep, (t, t))
        self.assertTrue(crs.save_start(self.sd, "a1", self.snap, **self.K))
        self.assertFalse(os.path.exists(old))
        self.assertTrue(os.path.exists(new))
        self.assertTrue(os.path.exists(keep))

    def test_default_state_dir(self):
        self.assertTrue(crs.default_state_dir().endswith(
            os.path.join(".claude", "cast-state", "review-snapshots")))
        self.assertTrue(crs.default_state_dir().startswith(self.home))


if __name__ == "__main__":
    unittest.main()


class IsReviewerTests(unittest.TestCase):
    def test_matrix(self):
        for name, want in [
            ("code-reviewer", "code-reviewer"), ("security", "security"),
            ("code-reviewer__fix-a", "code-reviewer"), ("security__x", "security"),
            ("code-reviewer__", None), ("security__", None), ("code-reviewer2", None),
            ("my-code-reviewer", None), ("security-auditor", None), ("backend-writer", None),
            ("", None), (None, None), (5, None), ("Code-Reviewer", None),
        ]:
            self.assertEqual(crs.is_reviewer(name), want, repr(name))


class DeadlineTests(_TmpCase):
    def test_zero_deadline_returns_none_and_none_deadline_works(self):
        repo = self.make_repo()
        self.write(repo, "a.txt", b"a\n")
        self.assertIsNone(crs.take_snapshot(repo, deadline_s=0))
        self.assertIsNone(crs.take_snapshot(repo, deadline_s=-1))
        self.assertEqual(list(crs.take_snapshot(repo, deadline_s=30)["files"]), ["a.txt"])
        self.assertEqual(list(crs.take_snapshot(repo)["files"]), ["a.txt"])

    def test_deadline_spent_between_git_calls_returns_none(self):
        repo = self.make_repo()
        self.write(repo, "a.txt", b"a\n")
        seq = iter([0.0, 0.0, 0.0, 100.0, 100.0, 100.0, 100.0])
        with mock.patch.object(crs.time, "monotonic", lambda: next(seq, 100.0)):
            self.assertIsNone(crs.take_snapshot(repo, deadline_s=1.0))


class GitTimeoutThreadingTests(_TmpCase):
    def spy(self):
        seen = []
        real = crs._git

        def f(repo_dir, args, timeout=30.0):
            seen.append((args[0], timeout))
            return real(repo_dir, args, timeout)
        return seen, f

    def test_resolve_repo_root_timeout_threaded_and_expired_skips_git(self):
        repo = self.make_repo()
        seen, f = self.spy()
        with mock.patch.object(crs, "_git", f):
            self.assertEqual(crs.resolve_repo_root(repo, timeout=1.5), os.path.realpath(repo))
            self.assertEqual(seen, [("rev-parse", 1.5)])
            seen.clear()
            self.assertEqual(crs.resolve_repo_root(repo, timeout=100), os.path.realpath(repo))
            self.assertEqual(seen, [("rev-parse", crs._GIT_TIMEOUT)])  # capped at 30
            seen.clear()
            self.assertEqual(crs.resolve_repo_root(repo, timeout=0), os.path.realpath(repo))
            self.assertEqual(seen, [])  # expired: fallback without running git

    def test_object_format_gets_remaining_budget_inside_take_snapshot(self):
        repo = self.make_repo()
        os.symlink("target", os.path.join(repo, "lnk"))
        seen, f = self.spy()
        with mock.patch.object(crs, "_git", f):
            self.assertIsNotNone(crs.take_snapshot(repo, deadline_s=20.0))
        fmt = [t for a, t in seen if a == "rev-parse"][1:]  # first rev-parse is --show-toplevel
        self.assertTrue(fmt and all(0 < t <= 20.0 for _, t in seen), seen)


class CliStartTests(_TmpCase):
    def setUp(self):
        super().setUp()
        self.repo = self.make_repo()
        self.write(self.repo, "a.txt", b"a\n")
        self.git(self.repo, "add", "-A")
        self.git(self.repo, "commit", "-q", "-m", "init")
        self.write(self.repo, "a.txt", b"changed\n")
        self.sd = crs.default_state_dir()  # under the temp HOME

    def test_start_round_trip(self):
        rc = crs.main(["start", "--agent-id", "ag1", "--session-id", "s1",
                       "--reviewer", "code-reviewer", "--cwd", self.repo])
        self.assertEqual(rc, 0)
        self.assertTrue(self.sd.startswith(self.home))
        snap = crs.load_start(self.sd, "ag1", session_id="s1", reviewer="code-reviewer")
        self.assertEqual(snap["files"], {"a.txt": self.blob(self.repo, "a.txt")})

    def test_never_raises_and_exits_zero(self):
        self.assertEqual(crs.main(["start"]), 0)  # missing required args
        self.assertEqual(crs.main(["bogus"]), 0)
        self.assertEqual(crs.main(["start", "--agent-id", "../x", "--reviewer", "security",
                                   "--cwd", self.repo]), 0)
        self.assertEqual(crs.main(["start", "--agent-id", "a", "--reviewer", "security",
                                   "--cwd", os.path.join(self.tmp, "nope")]), 0)
        self.assertFalse(os.path.exists(self.sd) and os.listdir(self.sd))

    def test_non_reviewer_writes_nothing(self):
        self.assertEqual(crs.main(["start", "--agent-id", "ag2", "--session-id", "s",
                                   "--reviewer", "backend-writer", "--cwd", self.repo]), 0)
        self.assertFalse(os.path.exists(os.path.join(self.sd, "ag2.json")))
