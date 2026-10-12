"""Tests for scripts/cast-managed-settings-verify.py (G5)."""
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPT = os.path.join(REPO, "scripts", "cast-managed-settings-verify.py")


def run(*args):
    return subprocess.run(
        [sys.executable, "-I", SCRIPT, *args],
        capture_output=True, text=True, timeout=30,
    )


class VerifyTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="cast-ms-verify-", dir=os.environ.get("TMPDIR"))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        os.makedirs(os.path.join(self.tmp, "macos"))
        os.makedirs(os.path.join(self.tmp, "managed-settings.d"))
        shutil.copy(os.path.join(REPO, "macos", "managed-settings.json"),
                    os.path.join(self.tmp, "macos"))
        for name in ("11-deny.json", "25-hooks-security.json"):
            shutil.copy(os.path.join(REPO, "managed-settings.d", name),
                        os.path.join(self.tmp, "managed-settings.d"))
        self.src = os.path.join(self.tmp, "macos", "managed-settings.json")

    def mutate(self, fn):
        with open(self.src) as fh:
            doc = json.load(fh)
        fn(doc)
        with open(self.src, "w") as fh:
            json.dump(doc, fh)

    def test_real_repo_source_passes(self):
        r = run("--source")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertNotIn("FAIL", r.stdout)

    def test_temp_copy_source_passes(self):
        r = run("--source", "--repo", self.tmp)
        self.assertEqual(r.returncode, 0, r.stdout)

    def test_extra_top_level_key_fails(self):
        self.mutate(lambda d: d.update({"env": {}}))
        r = run("--source", "--repo", self.tmp)
        self.assertEqual(r.returncode, 1)
        self.assertIn("FAIL", r.stdout)

    def test_deny_not_in_fragment_fails(self):
        self.mutate(lambda d: d["permissions"]["deny"].append("Bash(curl *)"))
        r = run("--source", "--repo", self.tmp)
        self.assertEqual(r.returncode, 1)
        self.assertIn("differs from fragment-derived", r.stdout)

    def test_missing_required_hook_fails(self):
        def drop(d):
            d["hooks"]["PreToolUse"] = [
                e for e in d["hooks"]["PreToolUse"] if e.get("id") != "cast-write-guards"
            ]
        self.mutate(drop)
        r = run("--source", "--repo", self.tmp)
        self.assertEqual(r.returncode, 1)
        self.assertIn("PreToolUse[1] missing", r.stdout)

    def test_missing_required_deny_fails(self):
        self.mutate(lambda d: d["permissions"]["deny"].remove("Edit(~/.claude/scripts/**)"))
        r = run("--source", "--repo", self.tmp)
        self.assertEqual(r.returncode, 1)

    def test_malformed_json_fails_with_1(self):
        with open(self.src, "w") as fh:
            fh.write("{not json")
        r = run("--source", "--repo", self.tmp)
        self.assertEqual(r.returncode, 1)
        self.assertNotIn("Traceback", r.stderr)

    def test_missing_repo_files_fail_closed(self):
        r = run("--source", "--repo", os.path.join(self.tmp, "nope"))
        self.assertEqual(r.returncode, 1)

    def assert_source_fails(self, fn):
        self.mutate(fn)
        r = run("--source", "--repo", self.tmp)
        self.assertEqual(r.returncode, 1, r.stdout)
        self.assertIn("FAIL", r.stdout)

    def pre(self, d, hook_id):
        return next(e for e in d["hooks"]["PreToolUse"] if e.get("id") == hook_id)

    def test_http_hook_added_fails(self):
        self.assert_source_fails(lambda d: d["hooks"]["ConfigChange"][0]["hooks"].append(
            {"type": "http", "url": "http://example.invalid"}))

    def test_prompt_stop_hook_added_fails(self):
        self.assert_source_fails(lambda d: d["hooks"].update(
            {"Stop": [{"hooks": [{"type": "prompt", "prompt": "x"}]}]}))

    def test_list_form_command_fails(self):
        def f(d):
            self.pre(d, "cast-write-guards")["hooks"][0]["command"] = ["bash", "write-guards.sh"]
        self.assert_source_fails(f)

    def test_narrowed_matcher_fails(self):
        self.assert_source_fails(lambda d: self.pre(d, "cast-pretool-dispatch").update({"matcher": "Bash"}))

    def test_event_moved_to_posttooluse_fails(self):
        def f(d):
            e = self.pre(d, "cast-write-guards")
            d["hooks"]["PreToolUse"].remove(e)
            d["hooks"]["PostToolUse"] = [e]
        self.assert_source_fails(f)

    def test_timeout_changed_fails(self):
        def f(d):
            self.pre(d, "cast-write-guards")["hooks"][0]["timeout"] = 1
        self.assert_source_fails(f)

    def test_killall_added_fails(self):
        self.assert_source_fails(lambda d: d["permissions"]["deny"].append("Bash(killall *)"))

    def test_audit_hook_added_fails(self):
        self.assert_source_fails(lambda d: d["hooks"]["PreToolUse"].insert(0, {
            "matcher": "WebFetch|WebSearch",
            "hooks": [{"type": "command", "command": "bash cast-audit-hook.sh --mode pre", "timeout": 5}]}))

    def test_deny_as_dict_fails(self):
        self.assert_source_fails(lambda d: d["permissions"]["deny"].__setitem__(0, {"rule": "Bash(rm -rf ~)"}))

    def test_fragment_drift_fails_source(self):
        p = os.path.join(self.tmp, "managed-settings.d", "11-deny.json")
        with open(p) as fh:
            doc = json.load(fh)
        doc["permissions"]["deny"].append("Edit(~/.claude/new-protected/**)")
        with open(p, "w") as fh:
            json.dump(doc, fh)
        r = run("--source", "--repo", self.tmp)
        self.assertEqual(r.returncode, 1)
        self.assertIn("by hand", r.stdout)

    def test_missing_fragment_hook_id_fails(self):
        p = os.path.join(self.tmp, "managed-settings.d", "25-hooks-security.json")
        with open(p) as fh:
            doc = json.load(fh)
        for e in doc["hooks"]["PreToolUse"]:
            if e.get("id") == "cast-write-guards":
                e.pop("id")
        with open(p, "w") as fh:
            json.dump(doc, fh)
        r = run("--source", "--repo", self.tmp)
        self.assertEqual(r.returncode, 1)
        self.assertIn("cannot derive", r.stdout)

    def test_floor_fails_when_fragment_and_source_both_narrowed(self):
        for path in (self.src, os.path.join(self.tmp, "managed-settings.d", "25-hooks-security.json")):
            with open(path) as fh:
                doc = json.load(fh)
            self.pre(doc, "cast-write-guards")["matcher"] = "Write"
            with open(path, "w") as fh:
                json.dump(doc, fh)
        r = run("--source", "--repo", self.tmp)
        self.assertEqual(r.returncode, 1, r.stdout)
        self.assertIn("FAIL: floor", r.stdout)

    def test_floor_fails_when_configchange_emptied_in_both(self):
        for path in (self.src, os.path.join(self.tmp, "managed-settings.d", "25-hooks-security.json")):
            with open(path) as fh:
                doc = json.load(fh)
            doc["hooks"]["ConfigChange"] = []
            with open(path, "w") as fh:
                json.dump(doc, fh)
        r = run("--source", "--repo", self.tmp)
        self.assertEqual(r.returncode, 1, r.stdout)
        self.assertIn("FAIL: floor", r.stdout)

    def both(self, fn):
        """Apply fn to the source and the fragment, so only the floor can catch it."""
        for path in (self.src, os.path.join(self.tmp, "managed-settings.d", "25-hooks-security.json")):
            with open(path) as fh:
                doc = json.load(fh)
            fn(doc)
            with open(path, "w") as fh:
                json.dump(doc, fh)

    def assert_floor_fails(self, fn):
        self.both(fn)
        r = run("--source", "--repo", self.tmp)
        self.assertEqual(r.returncode, 1, r.stdout)
        self.assertIn("FAIL: floor", r.stdout)

    def test_floor_if_key_on_dispatch(self):
        self.assert_floor_fails(lambda d: self.pre(d, "cast-pretool-dispatch")["hooks"][0].update({"if": "Bash(x)"}))

    def test_floor_timeout_one(self):
        self.assert_floor_fails(lambda d: self.pre(d, "cast-write-guards")["hooks"][0].update({"timeout": 1}))

    def test_floor_async_true(self):
        self.assert_floor_fails(lambda d: self.pre(d, "cast-write-guards")["hooks"][0].update({"async": True}))

    def test_floor_entry_level_extra_key(self):
        self.assert_floor_fails(lambda d: self.pre(d, "cast-pretool-dispatch").update({"if": "x"}))

    def test_floor_regex_wrapped_matcher(self):
        self.assert_floor_fails(lambda d: self.pre(d, "cast-pretool-dispatch").update({
            "matcher": "(?!X|Bash|Read|Write|Edit|Agent|Task|WebFetch|WebSearch|Workflow|Q)"}))

    def test_floor_command_swap(self):
        self.assert_floor_fails(lambda d: self.pre(d, "cast-write-guards")["hooks"][0].update({"command": "true"}))

    def test_floor_second_hook_in_entry(self):
        self.assert_floor_fails(lambda d: self.pre(d, "cast-write-guards")["hooks"].append(
            {"type": "command", "command": "true", "timeout": 5}))

    def test_floor_extra_event(self):
        self.assert_floor_fails(lambda d: d["hooks"].update(
            {"Stop": [{"hooks": [{"type": "command", "command": "true"}]}]}))

    def test_floor_extra_pretool_entry(self):
        self.assert_floor_fails(lambda d: d["hooks"]["PreToolUse"].append(
            {"id": "extra", "matcher": "Bash", "hooks": [{"type": "command", "command": "true", "timeout": 5}]}))

    def test_floor_drop_deny_from_both(self):
        for path in (self.src, os.path.join(self.tmp, "managed-settings.d", "11-deny.json")):
            with open(path) as fh:
                doc = json.load(fh)
            doc["permissions"]["deny"].remove("Edit(**/.claude/settings*.json)")
            with open(path, "w") as fh:
                json.dump(doc, fh)
        r = run("--source", "--repo", self.tmp)
        self.assertEqual(r.returncode, 1, r.stdout)
        self.assertIn("FAIL: floor", r.stdout)

    def test_floor_timeout_float(self):
        self.assert_floor_fails(lambda d: self.pre(d, "cast-write-guards")["hooks"][0].update({"timeout": 5.0}))

    def test_floor_hash_matches_real_repo(self):
        mod = self.load_module()
        with open(os.path.join(REPO, "macos", "managed-settings.json")) as fh:
            real = json.load(fh)
        want = mod.FLOOR_SHA256
        self.assertEqual(mod._canonical_sha256(real), want)
        self.assertEqual(mod._canonical_sha256(mod.build_expected(REPO)), want)

    def test_canonical_hash_is_type_strict(self):
        mod = self.load_module()
        self.assertNotEqual(mod._canonical_sha256({"a": 5}), mod._canonical_sha256({"a": 5.0}))
        self.assertNotEqual(mod._canonical_sha256({"a": True}), mod._canonical_sha256({"a": 1}))

    def test_print_floor_hash(self):
        mod = self.load_module()
        r = run("--print-floor-hash")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout.strip(), mod.FLOOR_SHA256)

    def test_nan_in_source_fails(self):
        with open(self.src) as fh:
            text = fh.read()
        with open(self.src, "w") as fh:
            fh.write(text.rstrip()[:-1] + ', "x": NaN}')
        r = run("--source", "--repo", self.tmp)
        self.assertEqual(r.returncode, 1, r.stdout)
        self.assertIn("non-standard JSON constant", r.stdout)

    def test_nan_in_source_fails_print_floor_hash(self):
        with open(self.src, "w") as fh:
            fh.write('{"x": Infinity}')
        r = run("--print-floor-hash", "--repo", self.tmp)
        self.assertEqual(r.returncode, 1, r.stdout)

    def test_print_floor_hash_malformed_source_fails(self):
        with open(self.src, "w") as fh:
            fh.write("{bad")
        r = run("--print-floor-hash", "--repo", self.tmp)
        self.assertEqual(r.returncode, 1)

    @staticmethod
    def load_module():
        spec = importlib.util.spec_from_file_location("verify", SCRIPT)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod

    def test_duplicate_json_key_fails(self):
        with open(self.src) as fh:
            text = fh.read()
        with open(self.src, "w") as fh:
            fh.write(text.rstrip()[:-1] + ', "permissions": {"deny": []}}')
        r = run("--source", "--repo", self.tmp)
        self.assertEqual(r.returncode, 1, r.stdout)
        self.assertIn("duplicate JSON key", r.stdout)

    def test_fifo_installed_fails_without_hanging(self):
        fifo = os.path.join(self.tmp, "fifo.json")
        os.mkfifo(fifo)
        r = subprocess.run([sys.executable, "-I", SCRIPT, "--repo", self.tmp, "--installed", fifo],
                           capture_output=True, text=True, timeout=15)
        self.assertEqual(r.returncode, 1, r.stdout)
        self.assertIn("not a regular file", r.stdout)

    def test_installed_symlink_refused(self):
        link = os.path.join(self.tmp, "link.json")
        os.symlink(self.src, link)
        r = run("--repo", self.tmp, "--installed", link)
        self.assertEqual(r.returncode, 1)
        self.assertIn("cannot open", r.stdout)

    @unittest.skipIf(os.geteuid() == 0, "needs non-root user")
    def test_installed_owned_by_non_root_fails(self):
        inst = os.path.join(self.tmp, "installed.json")
        shutil.copy(self.src, inst)
        r = run("--repo", self.tmp, "--installed", inst)
        self.assertEqual(r.returncode, 1)
        self.assertIn("not root", r.stdout)

    def test_installed_byte_mismatch_reported(self):
        inst = os.path.join(self.tmp, "installed.json")
        with open(inst, "w") as fh:
            fh.write("{}")
        r = run("--repo", self.tmp, "--installed", inst)
        self.assertEqual(r.returncode, 1)
        self.assertIn("bytes differ", r.stdout)

    def test_installed_missing_fails(self):
        r = run("--repo", self.tmp, "--installed", os.path.join(self.tmp, "absent.json"))
        self.assertEqual(r.returncode, 1)

    def test_print_install_after_source_ok(self):
        r = run("--print-install", "--repo", self.tmp)
        self.assertEqual(r.returncode, 0, r.stdout)
        lines = r.stdout.splitlines()
        self.assertTrue(any(l.startswith("SRC=") for l in lines), r.stdout)
        self.assertIn("DEST='/Library/Application Support/ClaudeCode/managed-settings.json'", lines)
        self.assertIn('sudo mkdir -p "$(dirname -- "$DEST")"', lines)
        self.assertIn('sudo install -o root -g wheel -m 0644 -- "$SRC" "$DEST"', lines)
        self.assertIn("sudo -k", lines)
        # No line may be long enough to wrap on paste, except the path assignments.
        for l in lines:
            if not l.startswith(("SRC=", "DEST=")):
                self.assertLessEqual(len(l), 100, l)

    def _eval_printed_install(self, *extra):
        """Run the printed SRC/DEST/mkdir/install lines under bash and zsh with a
        sudo stub that echoes its argv; yield (shell, mkdir_argv, install_argv)."""
        r = run("--print-install", "--repo", self.tmp, *extra)
        self.assertEqual(r.returncode, 0, r.stdout)
        cmds = [l for l in r.stdout.splitlines()
                if l.startswith(("SRC=", "DEST=", "sudo ")) and l != "sudo -k"]
        self.assertEqual(len(cmds), 4, cmds)
        script = "sudo() { printf 'ARG<%s>\\n' \"$@\"; printf 'END\\n'; }\n" + "\n".join(cmds) + "\n"
        shells = [s for s in ("/bin/bash", shutil.which("zsh")) if s]
        self.assertTrue(shells)
        for sh in shells:
            p = subprocess.run([sh, "-c", script], capture_output=True, text=True)
            self.assertEqual(p.returncode, 0, p.stderr)
            self.assertEqual(p.stderr, "", sh)
            calls = p.stdout.split("END\n")[:-1]
            self.assertEqual(len(calls), 2, p.stdout)
            yield sh, calls[0].splitlines(), calls[1].splitlines()

    def test_print_install_commands_run_in_bash_and_zsh(self):
        expect_src = os.path.join(os.path.abspath(self.tmp), "macos", "managed-settings.json")
        expect_dest = "/Library/Application Support/ClaudeCode/managed-settings.json"
        for sh, mk, inst in self._eval_printed_install():
            with self.subTest(shell=sh):
                self.assertEqual(mk, ["ARG<mkdir>", "ARG<-p>",
                                      "ARG</Library/Application Support/ClaudeCode>"])
                self.assertEqual(inst[-3:], ["ARG<-->", f"ARG<{expect_src}>", f"ARG<{expect_dest}>"])

    def test_print_install_special_char_dest(self):
        dest = os.path.join(self.tmp, "we$ird 'q\"d dir", "managed settings.json")
        expect_src = os.path.join(os.path.abspath(self.tmp), "macos", "managed-settings.json")
        for sh, mk, inst in self._eval_printed_install("--installed", dest):
            with self.subTest(shell=sh):
                self.assertEqual(mk, ["ARG<mkdir>", "ARG<-p>", f"ARG<{os.path.dirname(dest)}>"])
                self.assertEqual(inst[-3:], ["ARG<-->", f"ARG<{expect_src}>", f"ARG<{dest}>"])

    def test_print_install_leading_dash_dest(self):
        expect_src = os.path.join(os.path.abspath(self.tmp), "macos", "managed-settings.json")
        for sh, mk, inst in self._eval_printed_install("--installed=-dash.json"):
            with self.subTest(shell=sh):
                self.assertEqual(mk, ["ARG<mkdir>", "ARG<-p>", "ARG<.>"])
                self.assertEqual(inst[-3:], ["ARG<-->", f"ARG<{expect_src}>", "ARG<-dash.json>"])

    def test_print_install_refused_when_source_fails(self):
        self.mutate(lambda d: d.update({"env": {}}))
        r = run("--print-install", "--repo", self.tmp)
        self.assertEqual(r.returncode, 1)
        self.assertNotIn("sudo install", r.stdout)


class RealFileTests(unittest.TestCase):
    def test_build_expected_matches_real_file(self):
        spec = importlib.util.spec_from_file_location("verify", SCRIPT)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        with open(os.path.join(REPO, "macos", "managed-settings.json")) as fh:
            self.assertEqual(mod.build_expected(REPO), json.load(fh))

    def test_no_policy_or_telemetry_entries(self):
        with open(os.path.join(REPO, "macos", "managed-settings.json")) as fh:
            text = fh.read()
        self.assertNotIn("Agent(model:", text)
        self.assertNotIn("cast-audit-hook", text)
        self.assertNotIn("pkill", text)


if __name__ == "__main__":
    unittest.main()
