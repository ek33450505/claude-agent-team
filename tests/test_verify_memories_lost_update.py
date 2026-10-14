"""Lost-update guard for scripts/cast-verify-memories.py --apply.

If a memory file is modified between the run's snapshot and the atomic replace,
the bump must be skipped (the concurrent edit wins), not overwrite it.
Temp dirs only; never touches a real ~/.claude.
"""

import importlib.util
import io
import os
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from unittest import mock

SCRIPTS_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "scripts")
REAL_REF = "scripts/cast-events.sh"

MEMORY = """---
name: lost-update
metadata:
  verified_at: 2026-06-08
---

Discusses {ref} and the --verbose flag.
"""


def _load_module():
    path = os.path.join(SCRIPTS_DIR, "cast-verify-memories.py")
    spec = importlib.util.spec_from_file_location("cast_verify_memories_under_test", path)
    mod = importlib.util.module_from_spec(spec)
    sys.path.insert(0, SCRIPTS_DIR)
    spec.loader.exec_module(mod)
    return mod


class LostUpdateGuard(unittest.TestCase):
    def setUp(self):
        self.mod = _load_module()
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.mem_dir = os.path.join(self.tmp.name, "proj-lu", "memory")
        os.makedirs(self.mem_dir)
        self.path = os.path.join(self.mem_dir, "lu.md")
        with open(self.path, "w", encoding="utf-8", newline="") as fh:
            fh.write(MEMORY.format(ref=REAL_REF))
        # run from the repo root so REAL_REF resolves via the cwd root
        self.addCleanup(os.chdir, os.getcwd())
        os.chdir(os.path.join(SCRIPTS_DIR, ".."))

    def _run_apply(self, mutate_during_classify=None):
        real_classify = self.mod.classify

        def classify_then_mutate(*args, **kwargs):
            result = real_classify(*args, **kwargs)
            if mutate_during_classify is not None:
                mutate_during_classify()
            return result

        argv = ["cast-verify-memories.py", "--apply", "--base-dir", self.tmp.name, "--days", "30"]
        out, err = io.StringIO(), io.StringIO()
        with mock.patch.object(sys, "argv", argv), \
                mock.patch.object(self.mod, "classify", classify_then_mutate), \
                redirect_stdout(out), redirect_stderr(err):
            rc = self.mod.main()
        return rc, out.getvalue(), err.getvalue()

    def test_unmodified_file_is_bumped(self):
        rc, _out, _err = self._run_apply()
        self.assertEqual(rc, 0)
        with open(self.path, encoding="utf-8") as fh:
            self.assertIn("verified_by: cast-verify-memories.py (refs-resolved)", fh.read())

    def test_concurrent_edit_wins_and_bump_is_skipped(self):
        edited = MEMORY.format(ref=REAL_REF) + "\nHUMAN EDIT made mid-run.\n"

        def concurrent_edit():
            with open(self.path, "w", encoding="utf-8", newline="") as fh:
                fh.write(edited)

        rc, _out, err = self._run_apply(mutate_during_classify=concurrent_edit)
        self.assertEqual(rc, 0)
        with open(self.path, encoding="utf-8", newline="") as fh:
            self.assertEqual(fh.read(), edited)
        self.assertIn("modified during run", err)
        leftovers = [n for n in os.listdir(self.mem_dir) if n.startswith(".cast-verify-tmp-")]
        self.assertEqual(leftovers, [])


if __name__ == "__main__":
    unittest.main()
