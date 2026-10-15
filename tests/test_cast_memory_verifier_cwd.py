"""check_path_exists in scripts/cast_memory_verifier.py must not resolve a relative
ref against the filesystem root (the nightly launchd run has cwd "/")."""

import importlib.util
import os
import tempfile
import unittest
from unittest import mock

SCRIPTS_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "scripts")


def _load_module():
    spec = importlib.util.spec_from_file_location(
        "cast_memory_verifier_under_test", os.path.join(SCRIPTS_DIR, "cast_memory_verifier.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class CheckPathExistsCwd(unittest.TestCase):
    def setUp(self):
        self.mod = _load_module()
        self.addCleanup(os.chdir, os.getcwd())
        home = tempfile.TemporaryDirectory()
        self.addCleanup(home.cleanup)
        env = mock.patch.dict(os.environ, {"HOME": os.path.realpath(home.name)})
        env.start()
        self.addCleanup(env.stop)

    def test_relative_ref_does_not_resolve_against_filesystem_root(self):
        os.chdir(os.sep)
        self.assertTrue(os.path.isfile("bin/sh"))  # precondition
        self.assertFalse(self.mod.check_path_exists("bin/sh"))

    def test_relative_ref_resolves_against_non_root_cwd(self):
        with tempfile.TemporaryDirectory() as tmp:
            os.makedirs(os.path.join(tmp, "x"))
            open(os.path.join(tmp, "x", "y.txt"), "w").close()
            os.chdir(tmp)
            try:
                self.assertTrue(self.mod.check_path_exists("x/y.txt"))
            finally:
                os.chdir(os.sep)

    def test_absolute_ref_unchanged(self):
        self.assertTrue(self.mod.check_path_exists(os.path.realpath(__file__)))


if __name__ == "__main__":
    unittest.main()
