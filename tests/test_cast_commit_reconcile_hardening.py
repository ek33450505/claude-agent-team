#!/usr/bin/env python3
"""S4-b: D5b hardening of scripts/cast-commit-reconcile.py.

  a. identity / corrupt-line events are judged even when cast.db or the commit_provenance
     table is absent (only legacy window-rule events need the DB);
  b. the audit log is STREAMED (chunked), with identical line semantics and a corrupt hatch
     line still blocking, ackable by sha256;
  c. a sidecar LOADER failure gets its own reason string ("sidecar resolver unavailable: <Class>");
  d. ONLY KeyboardInterrupt propagates out of the loader; every other BaseException (SystemExit
     included: a SystemExit(0) would make main() exit 0 with no JSON = a pre-push skip) is a
     load failure and fails closed.

Every run uses a throw-away HOME with a COPY-style audit file / DB / checkpoint passed through
CAST_AUDIT_PATH / CAST_DB_PATH / CAST_RECONCILE_CHECKPOINT / CAST_RECONCILE_REPO. The real
~/.claude, its audit log and its live checkpoint are never touched.
CAST_RECONCILE_PATH selects the module under test (used by the mutation checks).
"""
import contextlib
import hashlib
import importlib.util
import inspect
import io
import json
import os
import shutil
import sqlite3
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

_REPO = Path(__file__).parent.parent
_SCRIPT = Path(os.environ.get("CAST_RECONCILE_PATH") or (_REPO / "scripts" / "cast-commit-reconcile.py"))

T0 = "2026-01-01T11:00:00"
T1 = "2026-01-01T12:00:00"


class _Base(unittest.TestCase):
    def setUp(self):
        self.tmp = os.path.realpath(tempfile.mkdtemp(prefix="reconcile-hard-"))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.home = os.path.join(self.tmp, "home")
        os.makedirs(self.home)
        self.audit = os.path.join(self.tmp, "audit.jsonl")
        self.db = os.path.join(self.tmp, "cast.db")  # NOT created unless a test asks
        self.checkpoint = os.path.join(self.tmp, "checkpoint")
        self.repo = os.path.join(self.tmp, "repo")
        os.makedirs(self.repo)
        Path(self.checkpoint).write_text(T0)

    def load(self, ack=False):
        env = {
            "HOME": self.home,
            "CAST_AUDIT_PATH": self.audit,
            "CAST_DB_PATH": self.db,
            "CAST_RECONCILE_CHECKPOINT": self.checkpoint,
            "CAST_RECONCILE_REPO": self.repo,
            "CAST_RECONCILE_ACK": "1" if ack else "0",
        }
        patcher = mock.patch.dict(os.environ, env)
        patcher.start()
        self.addCleanup(patcher.stop)
        spec = importlib.util.spec_from_file_location("cast_commit_reconcile_hard", str(_SCRIPT))
        mod = importlib.util.module_from_spec(spec)
        saved_path = list(sys.path)
        try:
            spec.loader.exec_module(mod)
        finally:
            sys.path[:] = saved_path
        return mod

    def run_main(self, mod):
        out = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
            rc = mod.main()
        return rc, json.loads(out.getvalue().strip().splitlines()[-1])

    def write_audit(self, *lines, raw=None):
        data = b"".join(l.encode() + b"\n" for l in lines) if raw is None else raw
        Path(self.audit).write_bytes(data)

    @staticmethod
    def identity(sid="sess-1", aid="", atype="commit", ts=T1):
        return json.dumps({"event": "COMMIT_HATCH_USED", "timestamp": ts, "session_id": sid,
                           "in_claude_session": True, "agent_type": atype, "agent_id": aid,
                           "repo": ""})

    @staticmethod
    def legacy(ts=T1):
        return json.dumps({"event": "COMMIT_HATCH_USED", "timestamp": ts, "session_id": "sess-legacy",
                           "in_claude_session": True})

    def write_sidecar(self, sid, aid, meta):
        d = os.path.join(self.home, ".claude", "projects", "-x", sid, "subagents")
        os.makedirs(d, exist_ok=True)
        Path(d, f"agent-{aid}.meta.json").write_text(json.dumps(meta))

    def make_db(self, with_table):
        conn = sqlite3.connect(self.db)
        if with_table:
            conn.execute("CREATE TABLE commit_provenance (sha TEXT, recorded_at TEXT, repo TEXT)")
        else:
            conn.execute("CREATE TABLE unrelated (x TEXT)")
        conn.commit()
        conn.close()

    def checkpoint_text(self):
        return Path(self.checkpoint).read_text().strip()


class TestIdentityJudgedWithoutDb(_Base):
    """a. a missing cast.db / commit_provenance table must not skip identity events."""

    def test_main_session_identity_event_is_violation_without_db(self):
        mod = self.load()
        self.write_audit(self.identity(aid=""))
        self.assertFalse(os.path.exists(self.db))
        rc, res = self.run_main(mod)
        self.assertEqual((rc, res["status"]), (1, "violations"), res)
        self.assertEqual(res["violations"][0]["reason"], "main-session hatch")
        self.assertEqual(self.checkpoint_text(), T0)  # a violation never advances it

    def test_authorized_identity_event_is_clean_without_db_and_advances_checkpoint(self):
        mod = self.load()
        self.write_sidecar("sess-1", "agentaaa1", {"agentType": "commit", "spawnDepth": 1})
        self.write_audit(self.identity(aid="agentaaa1"))
        rc, res = self.run_main(mod)
        self.assertEqual((rc, res["status"], res["checked"]), (0, "clean", 1), res)
        self.assertNotEqual(self.checkpoint_text(), T0)

    def test_unauthorized_agent_is_violation_without_table(self):
        mod = self.load()
        self.make_db(with_table=False)
        self.write_sidecar("sess-1", "agentddd1", {"agentType": "backend-writer"})
        self.write_audit(self.identity(aid="agentddd1"))
        rc, res = self.run_main(mod)
        self.assertEqual((rc, res["status"]), (1, "violations"), res)
        self.assertEqual(res["violations"][0]["reason"], "agent backend-writer is not the commit agent")

    def test_corrupt_hatch_line_is_violation_without_db(self):
        mod = self.load()
        self.write_audit(raw=b'{"event":"COMMIT_HATCH_USED", "timestamp": \n')
        rc, res = self.run_main(mod)
        self.assertEqual((rc, res["status"]), (1, "violations"), res)
        self.assertEqual(res["violations"][0]["reason"], "corrupt hatch line (line 1)")

    def test_legacy_only_without_db_is_still_a_skip_and_keeps_checkpoint(self):
        mod = self.load()
        self.write_audit(self.legacy())
        rc, res = self.run_main(mod)
        self.assertEqual((rc, res["status"], res["reason"]), (0, "skip", "cast.db not found"), res)
        self.assertEqual(self.checkpoint_text(), T0)

    def test_legacy_only_without_table_is_still_a_skip(self):
        mod = self.load()
        self.make_db(with_table=False)
        self.write_audit(self.legacy())
        rc, res = self.run_main(mod)
        self.assertEqual((rc, res["status"], res["reason"]),
                         (0, "skip", "commit_provenance table not found"), res)

    def test_no_events_without_db_is_still_a_skip(self):
        mod = self.load()
        self.write_audit()
        rc, res = self.run_main(mod)
        self.assertEqual((rc, res["status"], res["reason"]), (0, "skip", "cast.db not found"), res)

    def test_mixed_clean_identity_plus_unjudged_legacy_keeps_checkpoint(self):
        mod = self.load()
        self.write_sidecar("sess-1", "agentaaa1", {"agentType": "commit", "spawnDepth": 1})
        self.write_audit(self.identity(aid="agentaaa1"), self.legacy())
        rc, res = self.run_main(mod)
        self.assertEqual((rc, res["status"], res["checked"]), (0, "clean", 1), res)
        self.assertEqual(res["unjudged_legacy_events"], 1)
        self.assertEqual(res["db_unavailable"], "cast.db not found")
        # the legacy event still awaits a DB: it must stay inside the next run's window
        self.assertEqual(self.checkpoint_text(), T0)

    def test_ack_without_db_acks_and_advances(self):
        mod = self.load(ack=True)
        self.write_audit(self.identity(aid=""))
        rc, res = self.run_main(mod)
        self.assertEqual((rc, res["status"]), (0, "acked"), res)
        self.assertNotEqual(self.checkpoint_text(), T0)

    def test_ack_with_unjudged_legacy_event_does_not_advance_checkpoint(self):
        mod = self.load(ack=True)
        self.write_audit(self.identity(aid=""), self.legacy())
        rc, res = self.run_main(mod)
        self.assertEqual((rc, res["status"]), (0, "acked"), res)
        self.assertEqual(res["unjudged_legacy_events"], 1)
        # the ack is recorded, but the unjudged legacy event must stay inside the next window
        self.assertEqual(self.checkpoint_text(), T0)
        self.assertIn("RECONCILE_ACK_USED", Path(self.audit).read_text())

    def test_db_present_behaviour_unchanged_legacy_violation(self):
        mod = self.load()
        self.make_db(with_table=True)
        self.write_audit(self.legacy())
        rc, res = self.run_main(mod)
        self.assertEqual((rc, res["status"]), (1, "violations"), res)
        self.assertEqual(res["violations"][0]["reason"], "no commit provenance in window")


class TestStreamingReader(_Base):
    """b. chunked reads, same line semantics, corrupt hatch lines still block + ack by sha256."""

    DATA = [
        b"",
        b"a",
        b"a\n",
        b"a\nb",
        b"a\r\nb\r\n",
        b"a\rb\rc",
        b"a\r\n\r\nb\n\n",
        b"\n\n\n",
        b"\r",
        b"\r\n",
        b"x" * 50 + b"\r\n" + b"y" * 50 + b"\r" + b"z" * 20,
        "café\n‮\r\nend".encode(),
        b"\xff\xfe\n\x00bad\n",
    ]

    def test_generator_not_whole_file_read(self):
        mod = self.load()
        self.assertTrue(inspect.isgeneratorfunction(mod._iter_audit_lines))
        reads = []
        real_open = open

        def spy_open(*a, **k):
            f = real_open(*a, **k)
            real_read = f.read

            class W:
                def __enter__(s):
                    return s

                def __exit__(s, *e):
                    f.close()

                def read(s, n=-1):
                    reads.append(n)
                    return real_read(n)
            return W()

        Path(self.audit).write_bytes(b"x\n" * 1000)
        with mock.patch("builtins.open", spy_open):
            list(mod._iter_audit_lines(self.audit, chunk_size=64))
        self.assertTrue(reads and all(isinstance(n, int) and 0 < n <= 64 for n in reads), reads)

    def test_matches_splitlines_for_every_chunk_size(self):
        mod = self.load()
        for data in self.DATA:
            for size in (1, 2, 3, 5, 7, 64, 1 << 16):
                with self.subTest(data=data[:20], size=size):
                    Path(self.audit).write_bytes(data)
                    got = list(mod._iter_audit_lines(self.audit, chunk_size=size))
                    want = data.splitlines()
                    self.assertEqual([r for r, _t in got], want)
                    open_tail = bool(data) and not data.endswith((b"\n", b"\r"))
                    self.assertEqual([t for _r, t in got],
                                     [True] * (len(want) - 1) + [not open_tail] if want else [])

    def test_missing_file_raises_file_not_found_at_first_next(self):
        mod = self.load()
        with self.assertRaises(FileNotFoundError):
            list(mod._iter_audit_lines(os.path.join(self.tmp, "nope.jsonl")))

    def test_corrupt_hatch_line_spanning_chunks_still_blocks_and_acks_by_sha(self):
        corrupt = b'{"event":"COMMIT_HATCH_USED","timestamp":"' + b"z" * 300 + b'" TRUNC'
        good = self.legacy(ts="2026-01-01T09:00:00").encode()  # older than the checkpoint
        self.write_audit(raw=good + b"\n" + corrupt + b"\n" + good + b"\n")
        mod = self.load()
        mod._AUDIT_READ_CHUNK = 17  # force the corrupt line across many chunks
        events = mod.load_hatch_events(mod._parse_ts(T0))
        self.assertEqual(len(events), 1, events)
        self.assertEqual(events[0]["corrupt_line"], 2)
        self.assertEqual(events[0]["sha256"], hashlib.sha256(corrupt).hexdigest())
        # ... and an ACK run records the hash so the next run is clean
        mod2 = self.load(ack=True)
        mod2._AUDIT_READ_CHUNK = 17
        self.make_db(with_table=True)
        rc, res = self.run_main(mod2)
        self.assertEqual((rc, res["status"]), (0, "acked"), res)
        mod3 = self.load()
        mod3._AUDIT_READ_CHUNK = 17
        Path(self.checkpoint).write_text(T0)
        rc, res = self.run_main(mod3)
        self.assertEqual((rc, res["status"], res.get("acked_corrupt_lines")), (0, "clean", 1), res)

    def test_open_tail_corrupt_hatch_line_is_unverifiable_across_chunks(self):
        mod = self.load()
        mod._AUDIT_READ_CHUNK = 5
        self.write_audit(raw=self.legacy(ts="2026-01-01T09:00:00").encode() + b"\n"
                         + b'{"event":"COMMIT_HATCH_USED", "timestamp": ')  # no newline
        with self.assertRaises(ValueError):
            mod.load_hatch_events(mod._parse_ts(T0))
        rc, res = self.run_main(mod)
        self.assertEqual((rc, res["status"]), (0, "unverifiable"), res)

    def test_lone_cr_separated_events_both_evaluated(self):
        mod = self.load()
        mod._AUDIT_READ_CHUNK = 9
        a = self.legacy(ts="2026-01-01T12:00:00").encode()
        b = self.legacy(ts="2026-01-01T12:30:00").encode()
        self.write_audit(raw=a + b"\r" + b + b"\r")
        self.assertEqual(len(mod.load_hatch_events(mod._parse_ts(T0))), 2)


class TestSidecarLoaderErrors(_Base):
    """c. + d. loader failure reason and BaseException handling."""

    OLD = "commit-agent identity unverifiable (no trusted sidecar)"

    def evt(self):
        return {"identity": True, "session_id": "sess-1", "agent_id": "agentaaa1",
                "agent_type": "commit", "_ts": None, "repo": ""}

    def test_no_sidecar_keeps_the_old_reason(self):
        mod = self.load()
        self.assertEqual(mod.violation_reason(self.evt()), self.OLD)

    def test_loader_failure_has_a_distinct_reason_and_is_still_a_violation(self):
        mod = self.load()
        with mock.patch.object(mod.importlib.util, "spec_from_file_location",
                               side_effect=RuntimeError("boom <script>")):
            reason = mod.violation_reason(self.evt())
        self.assertEqual(
            reason, "commit-agent identity unverifiable (sidecar resolver unavailable: RuntimeError)")
        self.assertNotIn("boom", reason)

    def test_loader_failure_is_cached_and_fails_closed_on_every_call(self):
        mod = self.load()
        with mock.patch.object(mod.importlib.util, "spec_from_file_location",
                               side_effect=ImportError("x")):
            mod.violation_reason(self.evt())
        self.assertIs(mod._SUBAGENT_STOP_MOD, False)
        self.assertEqual(mod.violation_reason(self.evt()),
                         "commit-agent identity unverifiable (sidecar resolver unavailable: ImportError)")

    def test_resolver_exception_is_reported_not_swallowed_as_no_sidecar(self):
        mod = self.load()
        self.write_sidecar("sess-1", "agentaaa1", {"agentType": "commit"})
        self.assertIsNotNone(mod._load_subagent_stop())
        with mock.patch.object(mod._SUBAGENT_STOP_MOD, "_resolve_roster_type",
                               side_effect=ValueError("bad")):
            self.assertEqual(
                mod.violation_reason(self.evt()),
                "commit-agent identity unverifiable (sidecar resolver unavailable: ValueError)")

    def test_keyboard_interrupt_propagates_and_is_not_cached(self):
        mod = self.load()
        before = list(sys.path)
        with mock.patch.object(mod.importlib.util, "spec_from_file_location",
                               side_effect=KeyboardInterrupt):
            with self.assertRaises(KeyboardInterrupt):
                mod._load_subagent_stop()
        self.assertIsNone(mod._SUBAGENT_STOP_MOD)  # a retry may still succeed
        self.assertEqual(sys.path, before)

    def test_system_exit_is_a_load_failure_not_an_escape(self):
        for code in (0, 1, None):
            with self.subTest(code=code):
                mod = self.load()
                with mock.patch.object(mod.importlib.util, "spec_from_file_location",
                                       side_effect=SystemExit(code)):
                    reason = mod.violation_reason(self.evt())  # must NOT raise
                self.assertEqual(
                    reason,
                    "commit-agent identity unverifiable (sidecar resolver unavailable: SystemExit)")
                self.assertIs(mod._SUBAGENT_STOP_MOD, False)

    def test_system_exit_from_the_loader_still_yields_a_json_verdict_from_main(self):
        mod = self.load()
        self.write_audit(self.identity(aid="agentaaa1"))
        with mock.patch.object(mod.importlib.util, "spec_from_file_location",
                               side_effect=SystemExit(0)):
            rc, res = self.run_main(mod)
        self.assertEqual((rc, res["status"]), (1, "violations"), res)
        self.assertIn("sidecar resolver unavailable: SystemExit", res["violations"][0]["reason"])

    def test_other_base_exceptions_still_fail_closed(self):
        class Watchdog(BaseException):  # shape of a timeout/alarm exception
            pass
        for exc in (Watchdog("t"), GeneratorExit(), MemoryError()):
            with self.subTest(exc=type(exc).__name__):
                mod = self.load()
                with mock.patch.object(mod.importlib.util, "spec_from_file_location", side_effect=exc):
                    reason = mod.violation_reason(self.evt())
                self.assertEqual(
                    reason,
                    f"commit-agent identity unverifiable (sidecar resolver unavailable: {type(exc).__name__})")
                self.assertIs(mod._SUBAGENT_STOP_MOD, False)


if __name__ == "__main__":
    unittest.main()
