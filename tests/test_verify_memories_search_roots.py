"""build_search_roots in scripts/cast-verify-memories.py must not use the
filesystem root as a resolution root.

The nightly run happens under launchd with cwd "/", where a relative ref such
as "etc/hosts" would otherwise resolve against "/" and bump verified_at.
"""

import importlib.util
import os
import sys
import tempfile
import unittest
from unittest import mock

SCRIPTS_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "scripts")
MEMFILE = "/nonexistent-home/.claude/projects/-nonexistent-proj/memory/m.md"


def _load_module():
    path = os.path.join(SCRIPTS_DIR, "cast-verify-memories.py")
    spec = importlib.util.spec_from_file_location("cast_verify_memories_roots_under_test", path)
    mod = importlib.util.module_from_spec(spec)
    sys.path.insert(0, SCRIPTS_DIR)
    spec.loader.exec_module(mod)
    return mod


class SearchRootsCwd(unittest.TestCase):
    def setUp(self):
        self.mod = _load_module()

    def _labels(self, cwd):
        with mock.patch.object(os, "getcwd", return_value=cwd):
            roots, _ = self.mod.build_search_roots(MEMFILE)
        return [label for label, _root in roots]

    def test_filesystem_root_cwd_adds_no_cwd_roots(self):
        labels = self._labels(os.sep)
        self.assertNotIn("cwd", labels)
        self.assertNotIn("cwd/scripts", labels)
        self.assertIn("home/.claude", labels)

    def test_non_root_cwd_keeps_cwd_roots(self):
        with tempfile.TemporaryDirectory() as tmp:
            labels = self._labels(tmp)
        self.assertIn("cwd", labels)
        self.assertIn("cwd/scripts", labels)


class RelativeRefAtFilesystemRoot(unittest.TestCase):
    def setUp(self):
        self.mod = _load_module()
        prev = os.getcwd()
        self.addCleanup(os.chdir, prev)

    def test_relative_ref_does_not_resolve_against_filesystem_root(self):
        os.chdir(os.sep)
        self.assertTrue(os.path.isfile("bin/sh"))  # precondition: exists under "/"
        roots, _ = self.mod.build_search_roots(MEMFILE)
        self.assertIsNone(self.mod.resolve_ref("bin/sh", roots))

    def test_relative_ref_still_resolves_via_cwd_root_elsewhere(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = os.path.realpath(tmp)
            os.makedirs(os.path.join(tmp, "x"))
            open(os.path.join(tmp, "x", "y.txt"), "w").close()
            os.chdir(tmp)
            roots, _ = self.mod.build_search_roots(MEMFILE)
            self.assertEqual(
                self.mod.resolve_ref("x/y.txt", roots),
                (os.path.join(tmp, "x", "y.txt"), "cwd"),
            )
            os.chdir(os.sep)

    def test_absolute_ref_still_resolves_as_given(self):
        roots, _ = self.mod.build_search_roots(MEMFILE)
        path = os.path.realpath(__file__)
        self.assertEqual(self.mod.resolve_ref(path, roots), (path, "as-given"))


class RelativeMemoryPath(unittest.TestCase):
    def test_relative_memory_file_dir_root_is_absolute(self):
        mod = _load_module()
        prev = os.getcwd()
        self.addCleanup(os.chdir, prev)
        os.chdir(os.sep)
        roots, _ = mod.build_search_roots("memdir/proj/memory/m.md")
        mem_root = dict(roots)["memory-file-dir"]
        self.assertTrue(os.path.isabs(mem_root))
        self.assertEqual(mem_root, os.path.join(os.sep, "memdir", "proj", "memory"))
        # and a ref that exists only relative to "/" cannot resolve through it
        self.assertIsNone(mod.resolve_ref("bin/sh", roots))


if __name__ == "__main__":
    unittest.main()
