#!/usr/bin/env python3
"""_get_git_sha() in scripts/cast-db-contract.py runs cast_git_safe through bash.

The bash it spawns must get a minimal ALLOWLIST environment: a hostile SHELLOPTS/PS4 (xtrace
expands $(...) in PS4), BASHOPTS, BASH_ENV or an exported BASH_FUNC_* function in the caller's
environment must not execute anything, and the short sha must still come back.

Fixtures live in a temp dir (HOME included). The canary only touches a marker file.
"""
import importlib.util
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

_SCRIPTS = Path(__file__).resolve().parent.parent / "scripts"


def _git(repo, *args, env):
    subprocess.run(["git", "-C", str(repo), *args], check=True, capture_output=True, env=env)


class GetGitShaEnvTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="cast-sha-")).resolve()
        self.addCleanup(shutil.rmtree, str(self.tmp), True)
        self.home = self.tmp / "home"
        self.home.mkdir()
        self.marker = self.tmp / "MARKER"
        # An "installed" dir: the lib must be the sibling of the module file.
        inst = self.tmp / "installed"
        inst.mkdir()
        shutil.copy(str(_SCRIPTS / "cast-db-contract.py"), str(inst / "cast-db-contract.py"))
        shutil.copy(str(_SCRIPTS / "cast-hook-lib.sh"), str(inst / "cast-hook-lib.sh"))
        self.inst = inst
        self.repo = self.tmp / "repo"
        self.repo.mkdir()
        genv = {"PATH": "/usr/bin:/bin:/opt/homebrew/bin", "HOME": str(self.home)}
        _git(self.repo, "init", "-q", env=genv)
        (self.repo / "f.txt").write_text("x\n")
        _git(self.repo, "add", "f.txt", env=genv)
        _git(self.repo, "-c", "user.email=t@example.com", "-c", "user.name=t",
             "-c", "commit.gpgsign=false", "commit", "-q", "-m", "init", env=genv)
        self.expected = subprocess.run(
            ["git", "-C", str(self.repo), "rev-parse", "--short", "HEAD"],
            check=True, capture_output=True, text=True, env=genv,
        ).stdout.strip()

    def _load(self):
        spec = importlib.util.spec_from_file_location("cast_db_contract_inst", str(self.inst / "cast-db-contract.py"))
        mod = importlib.util.module_from_spec(spec)
        sys.modules["cast_db_contract_inst"] = mod  # dataclasses resolves the module by name
        self.addCleanup(sys.modules.pop, "cast_db_contract_inst", None)
        spec.loader.exec_module(mod)
        mod.REPO_ROOT = self.repo
        return mod

    def _hostile_env(self):
        return {
            "SHELLOPTS": "xtrace",
            "BASHOPTS": "extdebug",
            "PS4": "$(touch %s)+ " % self.marker,
            "BASH_FUNC_git%%": "() { touch %s; }" % self.marker,
            "HOME": str(self.home),
        }

    def test_control_hostile_env_does_execute_in_plain_bash(self):
        """CONTROL: the same environment given to a plain bash DOES create the marker."""
        env = dict(os.environ)
        env.update(self._hostile_env())
        subprocess.run(["/bin/bash", "-c", "true"], env=env, capture_output=True)
        self.assertTrue(self.marker.exists(), "control: probe cannot detect execution")
        self.marker.unlink()

    def test_hostile_shell_env_does_not_execute_and_sha_still_returned(self):
        mod = self._load()
        saved = dict(os.environ)
        try:
            os.environ.update(self._hostile_env())
            sha = mod._get_git_sha()
        finally:
            os.environ.clear()
            os.environ.update(saved)
        self.assertFalse(self.marker.exists(), "hostile SHELLOPTS/PS4/BASH_FUNC executed")
        self.assertEqual(sha, self.expected)

    def test_missing_lib_returns_unknown(self):
        mod = self._load()
        (self.inst / "cast-hook-lib.sh").unlink()
        self.assertEqual(mod._get_git_sha(), "unknown")


if __name__ == "__main__":
    unittest.main()
