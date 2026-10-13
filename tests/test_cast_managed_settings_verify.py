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


CAST_CMDS = (
    "bash ~/.claude/scripts/cast-config-change-guard.sh",
    "python3 -E -s ~/.claude/scripts/cast-pretool-dispatch.py",
    "bash ~/.claude/scripts/write-guards.sh",
)


def _inner_hooks(doc):
    for groups in doc["hooks"].values():
        for grp in groups:
            for h in grp["hooks"]:
                yield h


class CheckOnFailureTests(unittest.TestCase):
    """--check-onfailure: the install.sh gate against a stale managed file."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="cast-ms-onfail-", dir=os.environ.get("TMPDIR"))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.path = os.path.join(self.tmp, "managed-settings.json")
        with open(os.path.join(REPO, "macos", "managed-settings.json")) as fh:
            self.doc = json.load(fh)

    def write(self, doc=None, raw=None):
        with open(self.path, "w") as fh:
            fh.write(raw if raw is not None else json.dumps(doc if doc is not None else self.doc))

    def gate(self, path=None):
        return run("--check-onfailure", "--installed", path or self.path)

    def test_absent_file_passes(self):
        r = self.gate(os.path.join(self.tmp, "absent.json"))
        self.assertEqual(r.returncode, 0, r.stdout)
        self.assertTrue(r.stdout.startswith("OK:"), r.stdout)

    def test_all_cast_hooks_block_passes(self):
        self.write()
        r = self.gate()
        self.assertEqual(r.returncode, 0, r.stdout)
        self.assertEqual(r.stdout.count("OK:"), 3, r.stdout)

    def test_each_cast_hook_missing_onfailure_fails_and_is_named(self):
        for cmd in CAST_CMDS:
            doc = json.loads(json.dumps(self.doc))
            for h in _inner_hooks(doc):
                if h["command"] == cmd:
                    del h["onFailure"]
            self.write(doc)
            r = self.gate()
            self.assertEqual(r.returncode, 1, (cmd, r.stdout))
            self.assertIn("FAIL:", r.stdout)
            self.assertIn(cmd, r.stdout)

    def test_onfailure_continue_fails(self):
        for h in _inner_hooks(self.doc):
            if h["command"] == CAST_CMDS[1]:
                h["onFailure"] = "continue"
        self.write()
        r = self.gate()
        self.assertEqual(r.returncode, 1, r.stdout)
        self.assertIn("cast-pretool-dispatch.py", r.stdout)

    def test_malformed_json_fails_closed(self):
        self.write(raw="{not json")
        r = self.gate()
        self.assertEqual(r.returncode, 1, r.stdout)
        self.assertIn("malformed", r.stdout)

    def test_duplicate_key_fails_closed(self):
        self.write(raw='{"hooks": {}, "hooks": {}}')
        self.assertEqual(self.gate().returncode, 1)

    def test_symlinked_installed_path_fails(self):
        self.write()
        link = os.path.join(self.tmp, "link.json")
        os.symlink(self.path, link)
        r = self.gate(link)
        self.assertEqual(r.returncode, 1, r.stdout)
        self.assertIn("cannot open", r.stdout)

    def test_non_cast_hook_without_onfailure_ignored(self):
        self.doc["hooks"]["PostToolUse"] = [
            {"matcher": "Write", "hooks": [{"type": "command", "command": "bash ~/other-hook.sh"}]}]
        self.write()
        r = self.gate()
        self.assertEqual(r.returncode, 0, r.stdout)

    def test_repo_source_satisfies_gate(self):
        r = self.gate(os.path.join(REPO, "macos", "managed-settings.json"))
        self.assertEqual(r.returncode, 0, r.stdout)
        # exactly the 3 CAST registrations were matched and each reported OK
        self.assertEqual(r.stdout.count("OK: managed hook"), 3, r.stdout)
        self.assertNotIn("FAIL", r.stdout)

    def test_nonstandard_shapes_without_onfailure_fail(self):
        cmd = CAST_CMDS[1]
        shapes = {
            "bare matcher+command at top level": {"matcher": "Bash", "command": cmd},
            "hooks as a list": {"hooks": [{"type": "command", "command": cmd}]},
            "group dict carrying command": {"hooks": {"PreToolUse": [{"matcher": "Bash", "command": cmd}]}},
            "deeply nested": {"a": [{"b": {"c": [{"command": cmd}]}}]},
            "event value is a dict not a list": {"hooks": {"PreToolUse": {"hooks": [{"command": cmd}]}}},
        }
        for name, doc in shapes.items():
            self.write(doc)
            r = self.gate()
            self.assertEqual(r.returncode, 1, (name, r.stdout))
            self.assertIn("cast-pretool-dispatch.py", r.stdout, name)

    def test_nonstandard_shape_with_block_passes(self):
        self.write({"hooks": [{"command": CAST_CMDS[2], "onFailure": "block"}]})
        r = self.gate()
        self.assertEqual(r.returncode, 0, r.stdout)

    def test_respelled_commands_without_onfailure_fail(self):
        for cmd in ("bash  ~/.claude/scripts/write-guards.sh",
                    "bash /opt/cast-fixture/.claude/scripts/write-guards.sh",
                    "bash ~/.claude/scripts/write-guards.sh ",
                    "python3 -E -s  ~/.claude/scripts/cast-pretool-dispatch.py",
                    "/bin/bash $HOME/.claude/scripts/cast-config-change-guard.sh"):
            self.write({"hooks": {"PreToolUse": [{"hooks": [{"type": "command", "command": cmd}]}]}})
            r = self.gate()
            self.assertEqual(r.returncode, 1, (cmd, r.stdout))

    def test_onfailure_must_be_exact_string_block(self):
        for val in ("Block", "block ", True, ["block"], None, 1):
            doc = json.loads(json.dumps(self.doc))
            for h in _inner_hooks(doc):
                if h["command"] == CAST_CMDS[0]:
                    h["onFailure"] = val
            self.write(doc)
            self.assertEqual(self.gate().returncode, 1, repr(val))

    def test_two_registrations_one_without_block_fails(self):
        cmd = CAST_CMDS[2]
        self.write({"hooks": {"PreToolUse": [
            {"hooks": [{"command": cmd, "onFailure": "block"}]},
            {"hooks": [{"command": cmd}]}]}})
        r = self.gate()
        self.assertEqual(r.returncode, 1, r.stdout)
        self.assertEqual(r.stdout.count("OK:"), 1, r.stdout)
        self.assertEqual(r.stdout.count("FAIL:"), 1, r.stdout)

    def test_very_deep_nesting_fails_closed(self):
        # A CAST registration buried 50k levels deep must not slip past the walk: it is
        # either found (iterative walk, rc 1) or the parse refuses it (RecursionError, rc 1).
        n = 50000
        self.write(raw="[" * n + '{"command": "bash ~/.claude/scripts/write-guards.sh"}' + "]" * n)
        r = self.gate()
        self.assertEqual(r.returncode, 1, r.stdout[-300:])
        self.assertIn("FAIL:", r.stdout)
        self.assertNotIn("Traceback", r.stdout + r.stderr)

    def test_deep_nesting_with_block_passes_without_recursion(self):
        # ~1100 levels exceeds Python's default recursion limit (1000): a recursive walk
        # would crash; the explicit-stack walk must reach the registration and pass it.
        n = 1100
        self.write(raw="[" * n + '{"command": "bash ~/.claude/scripts/write-guards.sh", "onFailure": "block"}' + "]" * n)
        r = self.gate()
        self.assertEqual(r.returncode, 0, r.stdout[-300:] + r.stderr[-300:])
        self.assertEqual(r.stdout.count("OK: managed hook"), 1, r.stdout)

    def test_non_str_command_naming_a_basename_is_a_registration(self):
        self.write({"hooks": [{"command": ["bash", "~/.claude/scripts/write-guards.sh"]}]})
        r = self.gate()
        self.assertEqual(r.returncode, 1, r.stdout)
        self.assertIn("write-guards.sh", r.stdout)
        self.write({"hooks": [{"command": ["bash", "~/.claude/scripts/write-guards.sh"], "onFailure": "block"}]})
        self.assertEqual(self.gate().returncode, 0)

    def test_fragment_block_commands_match_gate_basenames(self):
        """Drift guard: the gate's basenames cannot silently go stale vs the fragment."""
        spec = importlib.util.spec_from_file_location("msv", SCRIPT)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        with open(os.path.join(REPO, "managed-settings.d", "25-hooks-security.json")) as fh:
            frag = json.load(fh)
        block_cmds = [h["command"] for h in _inner_hooks(frag) if h.get("onFailure") == "block"]
        self.assertTrue(block_cmds, "fragment has no onFailure:block hooks")
        for cmd in block_cmds:
            self.assertTrue(any(b in cmd for b in mod.ONFAILURE_BASENAMES),
                            f"{cmd!r} carries onFailure:block but matches no gate basename")
        for b in mod.ONFAILURE_BASENAMES:
            self.assertTrue(any(b in cmd for cmd in block_cmds),
                            f"basename {b!r} matches no onFailure:block fragment command")

    def test_stale_pre_onfailure_file_fails(self):
        # Today's stale live file shape: the three hooks with no onFailure key.
        for h in _inner_hooks(self.doc):
            h.pop("onFailure", None)
        self.write()
        r = self.gate()
        self.assertEqual(r.returncode, 1, r.stdout)
        self.assertEqual(r.stdout.count("FAIL:"), 3, r.stdout)

    def test_historical_9e93a1a_content_fails(self):
        g = subprocess.run(["git", "-C", REPO, "--no-pager", "show", "9e93a1a:macos/managed-settings.json"],
                           capture_output=True, text=True, timeout=30)
        if g.returncode != 0:
            self.skipTest("commit 9e93a1a not available (shallow clone)")
        self.write(raw=g.stdout)
        r = self.gate()
        self.assertEqual(r.returncode, 1, r.stdout)


if __name__ == "__main__":
    unittest.main()
