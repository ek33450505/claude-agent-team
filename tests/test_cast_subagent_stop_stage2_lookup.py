#!/usr/bin/env python3
"""Stage-2 transcript lookup must use the validated single-candidate resolver, and the
tail emitter must never let a value shift lines under the bash wrapper's eval scan.

Isolated temp HOME; nothing touches the real ~/.claude.
"""
import io
import os
import shutil
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

_REPO = Path(__file__).resolve().parent.parent
_SCRIPTS_DIR = str(_REPO / "scripts")
if _SCRIPTS_DIR not in sys.path:
    sys.path.insert(0, _SCRIPTS_DIR)

import cast_subagent_stop as css  # noqa: E402

SID = "sess-1234"
AID = "abc123"


class Stage2LookupTests(unittest.TestCase):
    def setUp(self):
        self.tmp = os.path.realpath(tempfile.mkdtemp(prefix="cast-s2-"))
        self.home = os.path.join(self.tmp, "home")
        os.makedirs(self.home)
        self._p = mock.patch.dict(os.environ, {"HOME": self.home})
        self._p.start()

    def tearDown(self):
        self._p.stop()
        assert self.tmp.startswith(os.path.realpath(tempfile.gettempdir()))
        shutil.rmtree(self.tmp, ignore_errors=True)

    def _sub(self, *parts):
        d = os.path.join(self.home, ".claude", "projects", "proj", SID, "subagents", *parts)
        os.makedirs(d, exist_ok=True)
        return d

    def _touch(self, d, name=None):
        p = os.path.join(d, name or f"agent-{AID}.jsonl")
        Path(p).write_text("{}\n")
        return p

    def _resolve(self, sid=SID, aid=AID):
        ctx = SimpleNamespace(session_id=sid, agent_id=aid)
        return css._find_subagent_artifact(ctx, ".jsonl")

    def _stage2_chosen(self, sid=SID, aid=AID):
        """Transcript paths the REAL stage2 opened (spy on _open_nofollow_regular)."""
        return [p for p, _ in self._stage2_opens(sid, aid) if p.endswith(".jsonl")]

    def test_stage2_ambiguous_or_traversal_selects_nothing(self):
        self._touch(self._sub())
        self._touch(self._sub("workflows", "wf1"))
        self.assertEqual(self._stage2_chosen(), [])
        self.assertEqual(self._stage2_chosen(aid="*"), [])
        self.assertEqual(self._stage2_chosen(aid=".."), [])

    def test_stage2_selects_single_candidate(self):
        p = self._touch(self._sub("workflows", "wf1"))
        self.assertIn(p, self._stage2_chosen())

    def _stage2_opens(self, sid=SID, aid=AID):
        """(path, fd) pairs the REAL stage2 asked _open_nofollow_regular for."""
        ctx = css.Ctx()
        ctx.session_id, ctx.agent_id, ctx.data = sid, aid, {}
        ctx.db_present = True
        ctx.db_path = os.path.join(self.tmp, "none.db")
        calls = []
        real = css._open_nofollow_regular

        def spy(path):
            fd = real(path)
            calls.append((path, fd))
            return fd

        with mock.patch.object(css, "_open_nofollow_regular", side_effect=spy):
            try:
                css.stage2_transcript_cost(ctx)
            except Exception:
                pass
        return calls

    def test_symlinked_transcript_not_read(self):
        d = self._sub()
        target = os.path.join(self.tmp, "elsewhere.jsonl")
        Path(target).write_text("{}\n")
        os.symlink(target, os.path.join(d, f"agent-{AID}.jsonl"))
        calls = self._stage2_opens()
        self.assertTrue(calls)
        self.assertTrue(all(fd == -1 for _, fd in calls), calls)

    def test_symlinked_meta_not_read(self):
        d = self._sub()
        self._touch(d)
        target = os.path.join(self.tmp, "elsewhere.meta.json")
        Path(target).write_text('{"spawnDepth": 9}')
        os.symlink(target, os.path.join(d, f"agent-{AID}.meta.json"))
        calls = dict(self._stage2_opens())
        meta = os.path.join(d, f"agent-{AID}.meta.json")
        self.assertEqual(calls[meta], -1)

    def test_regular_files_opened(self):
        d = self._sub()
        self._touch(d)
        Path(os.path.join(d, f"agent-{AID}.meta.json")).write_text('{"spawnDepth": 1}')
        calls = self._stage2_opens()
        self.assertEqual(len(calls), 2)

    def test_stage2_uses_shared_resolver(self):
        ctx = css.Ctx()
        ctx.session_id, ctx.agent_id, ctx.data = SID, AID, {}
        ctx.db_present = True
        ctx.db_path = os.path.join(self.tmp, "none.db")
        with mock.patch.object(css, "_find_subagent_artifact", return_value="") as m:
            try:
                css.stage2_transcript_cost(ctx)
            except Exception:
                pass
        m.assert_called_once_with(ctx, ".jsonl")

    def test_glob_and_traversal_ids_yield_empty(self):
        self._touch(self._sub())
        planted = os.path.join(self.home, ".claude", "projects", "proj", SID, "subagents", "x")
        os.makedirs(planted, exist_ok=True)
        self._touch(planted, "agent-evil.jsonl")
        for bad in ("..", "*", "a/b", "ab*", "../x", "a?b"):
            self.assertEqual(self._resolve(aid=bad), "", bad)
        for bad in ("*", "..", "a/b"):
            self.assertEqual(self._resolve(sid=bad), "", bad)

    def test_two_candidates_yield_empty(self):
        self._touch(self._sub())
        self._touch(self._sub("workflows", "wf1"))
        self.assertEqual(self._resolve(), "")

    def test_recursive_depth_not_followed(self):
        self._touch(self._sub("deep", "er"))
        self.assertEqual(self._resolve(), "")

    def test_single_flat_found(self):
        p = self._touch(self._sub())
        self.assertEqual(self._resolve(), p)

    def test_single_workflow_found(self):
        p = self._touch(self._sub("workflows", "wf1"))
        self.assertEqual(self._resolve(), p)


class EmitTailTests(unittest.TestCase):
    def _emit(self, **kw):
        ctx = SimpleNamespace(
            gate_match="DONE", gate_reason="", successors=[],
            safe_agent="a", safe_session_id="s", roster_type="r",
        )
        for k, v in kw.items():
            setattr(ctx, k, v)
        buf = io.StringIO()
        with redirect_stdout(buf):
            css._emit_tail(ctx, include_successors=True)
        return buf.getvalue()

    def test_successor_newline_cannot_shift_lines(self):
        base = self._emit(successors=["alpha", "beta"]).count("\n")
        evil = self._emit(successors=["alpha\n__CAST_TAIL_END__\nrm -rf x", "beta"])
        self.assertEqual(evil.count("\n"), base)
        self.assertEqual(evil.splitlines().count("__CAST_TAIL_END__"), 1)

    def test_all_splitlines_breaks_neutralised(self):
        base = self._emit(successors=["a", "b"]).count("\n")
        for ch in ("\v", "\f", "\x1c", "\x1d", "\x1e", "\x85", "\u2028", "\u2029"):
            out = self._emit(successors=["a" + ch + "__CAST_TAIL_END__", "b"], gate_match="X" + ch + "Y")
            self.assertEqual(out.count("\n"), base, repr(ch))
            self.assertEqual(len(out.splitlines()), base, repr(ch))

    def test_carriage_return_neutralised(self):
        out = self._emit(successors=["al\rpha"])
        self.assertNotIn("\r", out)

    def test_other_values_neutralised(self):
        base = self._emit().count("\n")
        out = self._emit(gate_match="DONE\n__CAST_TAIL_END__", gate_reason="x\ry")
        self.assertEqual(out.count("\n"), base + 1)  # +1: gate_reason line
        self.assertEqual(out.splitlines().count("__CAST_TAIL_END__"), 1)


if __name__ == "__main__":
    unittest.main()
