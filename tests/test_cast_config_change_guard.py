"""Tests for the ConfigChange guard (S3d follow-up F1b).

Covers scripts/cast_config_change_guard.py (pure `evaluate`, helpers) and the
real wrapper scripts/cast-config-change-guard.sh end to end against real temp
settings files. Every subprocess runs with HOME pointed at a temp dir; the real
HOME is never touched.

The expected EXACT / PREFIX lists are hardcoded here (not read from the module)
on purpose: iterating the module's own sets would silently skip a name deleted
from them, so the test could never fail for that regression.
"""

import contextlib
import io
import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

REPO = Path(__file__).resolve().parent.parent
SCRIPTS = REPO / "scripts"
WRAPPER = SCRIPTS / "cast-config-change-guard.sh"
EVALUATOR = SCRIPTS / "cast_config_change_guard.py"

sys.path.insert(0, str(SCRIPTS))
import cast_config_change_guard as guard  # noqa: E402

# Hardcoded expectations, grouped like the module comments.
EXEC_ENV = [
    "PATH", "BASH_ENV", "ENV", "SHELLOPTS", "BASHOPTS", "CDPATH", "GLOBIGNORE",
    "IFS", "PS4", "PROMPT_COMMAND", "SHELL", "ZDOTDIR",
]
GUARD_CONTROL_ENV = [
    "CLAUDE_SUBPROCESS", "CLAUDE_ENV_FILE", "CLAUDE_PROJECT_DIR",
    "CLAUDE_CODE_SHELL_PREFIX", "CLAUDE_CODE_SHELL",
    "CLAUDE_CODE_SUBPROCESS_ENV_SCRUB", "CLAUDE_CODE_SCRIPT_CAPS",
    "CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH", "CLAUDE_CODE_MAX_SUBAGENTS_PER_SESSION",
    "ATTEST_ENFORCE_AGENTS",
]
RUNTIME_ENV = ["NODE_OPTIONS", "RUBYOPT", "PERL5OPT", "PERL5LIB", "PERLLIB"]
BASH_SWITCH_ENV = ["FUNCNEST", "POSIXLY_CORRECT", "BASH_XTRACEFD", "BASH_LOADABLES_PATH"]
NETWORK_TRUST_ENV = [
    "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY", "SSL_CERT_FILE",
    "SSL_CERT_DIR", "CURL_CA_BUNDLE", "REQUESTS_CA_BUNDLE", "NODE_EXTRA_CA_CERTS",
]
LAUNCHED_PROGRAM_ENV = [
    "EDITOR", "VISUAL", "PAGER", "LESSOPEN", "SSH_ASKPASS", "SSH_AUTH_SOCK",
]
TLS_SECRET_ENV = ["SSLKEYLOGFILE"]
# macOS xcrun shim redirection (F3): DEVELOPER_DIR runs a fake xcrun, TOOLCHAINS
# reselects the toolchain, xcrun_db poisons the tool-path cache.
XCRUN_SHIM_ENV = ["DEVELOPER_DIR", "TOOLCHAINS"]
XCRUN_PREFIX_ENV = ["xcrun_db", "XCRUN_DB", "xcrun_nocache", "xcrun_log", "Xcrun_Verbose"]
PREFIX_SAMPLES = [
    "CAST_POLICY_OVERRIDE", "CAST_DB_PATH", "LD_PRELOAD", "LD_LIBRARY_PATH",
    "DYLD_INSERT_LIBRARIES", "PYTHONPATH", "PYTHONSTARTUP", "GIT_SSH_COMMAND",
    "GIT_EXEC_PATH", "BASH_FUNC_ls%%", "ANTHROPIC_BASE_URL", "ANTHROPIC_API_KEY",
    "ANTHROPIC_MODEL", "ANTHROPIC_CUSTOM_HEADERS", "CLAUDE_CODE_USE_BEDROCK",
    "CLAUDE_CODE_SOME_FUTURE_KNOB", "NODE_ENV", "NODE_TLS_REJECT_UNAUTHORIZED",
    "NODE_EXTRA_CA_CERTS", "NODE_PATH", "AWS_ENDPOINT_URL", "AWS_PROFILE",
    "GOOGLE_APPLICATION_CREDENTIALS", "CLAUDE_BASH_MAINTAIN_PROJECT_WORKING_DIR",
    "CLAUDE_CONFIG_DIR",
]


class EvaluateTests(unittest.TestCase):
    def blocked(self, settings):
        return guard.evaluate(settings)

    def test_empty_and_unrelated_allowed(self):
        self.assertEqual(guard.evaluate({}), [])
        self.assertEqual(guard.evaluate({"permissions": {"allow": ["Bash(ls)"]}}), [])
        self.assertEqual(guard.evaluate({"env": {}}), [])

    def test_exec_env_names_blocked(self):
        for name in EXEC_ENV:
            with self.subTest(name=name):
                self.assertEqual(guard.evaluate({"env": {name: "x"}}), [name])

    def test_guard_control_env_names_blocked(self):
        for name in GUARD_CONTROL_ENV:
            with self.subTest(name=name):
                self.assertEqual(guard.evaluate({"env": {name: "x"}}), [name])

    def test_runtime_injection_env_names_blocked(self):
        for name in RUNTIME_ENV:
            with self.subTest(name=name):
                self.assertEqual(guard.evaluate({"env": {name: "x"}}), [name])

    def test_bash_switch_network_trust_and_launched_program_names_blocked(self):
        for name in BASH_SWITCH_ENV + NETWORK_TRUST_ENV + LAUNCHED_PROGRAM_ENV + TLS_SECRET_ENV:
            with self.subTest(name=name):
                self.assertEqual(guard.evaluate({"env": {name: "x"}}), [name])
                lower = name.lower()
                self.assertEqual(guard.evaluate({"env": {lower: "x"}}), [lower])

    def test_xcrun_shim_env_blocked_in_every_case(self):
        for name in XCRUN_SHIM_ENV:
            for spelling in (name, name.lower(), name.title()):
                with self.subTest(name=spelling):
                    self.assertEqual(guard.evaluate({"env": {spelling: "x"}}), [spelling])

    def test_xcrun_prefix_env_blocked_in_every_case(self):
        for name in XCRUN_PREFIX_ENV:
            with self.subTest(name=name):
                self.assertEqual(guard.evaluate({"env": {name: "x"}}), [name])

    def test_xcrun_lookalikes_allowed(self):
        env = {
            "DEVELOPER_MODE": "1",   # DEVELOPER_DIR is whole-name, not a prefix
            "MY_DEVELOPER_DIR": "x",
            "TOOLCHAIN": "x",        # TOOLCHAINS needs the trailing S
            "XCRUNNER": "x",         # XCRUN_ needs the trailing underscore
            "MY_XCRUN_DB": "x",      # prefix, not substring
        }
        self.assertEqual(guard.evaluate({"env": env}), [])

    def test_prefix_families_blocked(self):
        for name in PREFIX_SAMPLES:
            with self.subTest(name=name):
                self.assertEqual(guard.evaluate({"env": {name: "x"}}), [name])

    def test_lowercase_and_mixed_case_blocked_via_upper(self):
        for name in ("path", "bash_env", "Pythonpath", "cast_x", "ld_preload", "Git_Dir"):
            with self.subTest(name=name):
                self.assertEqual(guard.evaluate({"env": {name: "x"}}), [name])

    def test_benign_env_allowed(self):
        env = {
            "APP_MODE": "production",
            "LANG": "en_US.UTF-8",
            "MY_APP_MODEL": "x",   # ANTHROPIC_ is a prefix, not a substring
            "MY_NODE_X": "x",      # NODE_/AWS_/GOOGLE_ are prefixes, not substrings
            "AWSX": "x",
            "GOOGLEBOT": "x",
            "NODE": "x",           # NODE_ needs the trailing underscore
            "CLAUDE": "x",         # CLAUDE_ needs the trailing underscore
            "_private1": "x",
            "GITHUB_TOKEN": "x",   # GITHUB_ is not the GIT_ prefix
            "LDAP_URL": "x",       # LDAP_ is not the LD_ prefix
            "PATHOLOGY": "x",      # EXACT is whole-name, not a prefix match
            "ENVIRON": "x",
            "MY_CAST": "x",        # CAST_ is a prefix, not a substring
        }
        self.assertEqual(guard.evaluate({"env": env}), [])

    def test_env_key_syntax_bypass_vectors_name_the_real_variable(self):
        # Node's process.env setter truncates a key at NUL, and consumers split at
        # "=" / trim whitespace, so these all reach a child as the denylisted name.
        vectors = {
            "BASH_ENV\x00x": "BASH_ENV",
            "PATH\x00": "PATH",
            "BASH_ENV=/p/evil.sh": "BASH_ENV",
            "PATH=/p/evil:": "PATH",
            "CLAUDE_SUBPROCESS=1": "CLAUDE_SUBPROCESS",
            " PATH": "PATH",
            "PATH ": "PATH",
            "\tBASH_ENV\n": "BASH_ENV",
            "CAST_X\x00y": "CAST_X",
            "ld_preload=/x.so": "ld_preload",
            "ANTHROPIC_BASE_URL\x00": "ANTHROPIC_BASE_URL",
        }
        for key, expected in vectors.items():
            with self.subTest(key=key):
                self.assertEqual(guard.evaluate({"env": {key: "x"}}), [expected])

    def test_env_key_bad_syntax_blocked_even_when_not_denylisted(self):
        zero_width_space = chr(0x200B)
        fullwidth_path = chr(0xFF30) + chr(0xFF21) + chr(0xFF34) + chr(0xFF28)
        for key in ("", "=x", "FOO\x00PATH", "MY-VAR", "a.b", "1ABC", "APP_MODE\n",
                    "BASH_ENV" + zero_width_space, fullwidth_path, "A B", "a\x00"):
            with self.subTest(key=key):
                self.assertEqual(guard.evaluate({"env": {key: "x"}}), ["env:<bad-name>"])

    def test_plain_names_not_flagged_by_syntax_check(self):
        env = {"_x": "1", "a1": "2", "APP_MODE": "3", "Mixed_Case_9": "4"}
        self.assertEqual(guard.evaluate({"env": env}), [])

    def test_evaluate_dedupes_by_head_and_stops_at_max_names(self):
        self.assertEqual(
            guard.evaluate({"env": {"PATH=a": "1", "PATH=b": "2", "PATH\x00z": "3"}}),
            ["PATH"])
        many = {f"CAST_{i}": "x" for i in range(1000)}
        self.assertEqual(len(guard.evaluate({"env": many})), guard.MAX_NAMES)
        self.assertEqual(guard.MAX_NAMES, 20)

    def test_evaluate_is_linear_on_huge_envs(self):
        # The old list-membership dedupe was quadratic: 40k offenders took 5 s,
        # past the hook timeout, so the change applied unjudged (fail-open).
        for label, make in (("offending", lambda i: f"CAST_{i}"),
                            ("benign", lambda i: f"BENIGN_KEY_{i}")):
            with self.subTest(label=label):
                env = {make(i): "" for i in range(60000)}
                started = time.monotonic()
                result = guard.evaluate({"env": env})
                # No process startup in this timing. The old quadratic dedupe took
                # 5-11 s here, so 2 s still discriminates while tolerating a slow runner.
                self.assertLess(time.monotonic() - started, 2.0)
                self.assertEqual(len(result), guard.MAX_NAMES if label == "offending" else 0)

    def test_disable_all_hooks_matrix(self):
        for value in (True, "true", "false", 1, 0, None, [], {}):
            with self.subTest(value=value):
                self.assertEqual(guard.evaluate({"disableAllHooks": value}), ["disableAllHooks"])
        self.assertEqual(guard.evaluate({"disableAllHooks": False}), [])
        self.assertEqual(guard.evaluate({}), [])

    def test_env_non_object_blocked(self):
        for value in ([], ["PATH"], "PATH=/x", None, 5, True):
            with self.subTest(value=value):
                self.assertEqual(guard.evaluate({"env": value}), ["env:<non-object>"])

    def test_non_string_key_blocked(self):
        self.assertEqual(guard.evaluate({"env": {1: "x"}}), ["env:<non-string-key>"])

    def test_non_dict_settings_blocked(self):
        for value in ([], "x", None, 3):
            with self.subTest(value=value):
                self.assertTrue(guard.evaluate(value))

    def test_multiple_offenders_ordered_and_values_never_returned(self):
        result = guard.evaluate({
            "disableAllHooks": True,
            "env": {"APP_MODE": "ok", "CAST_X": "s3cr3t", "PATH": "/evil"},
        })
        self.assertEqual(result, ["disableAllHooks", "CAST_X", "PATH"])
        self.assertNotIn("s3cr3t", json.dumps(result))
        self.assertNotIn("/evil", json.dumps(result))


class OutputShapingTests(unittest.TestCase):
    def test_block_json_caps_names_and_length_and_strips_control(self):
        names = [f"CAST_{i}" for i in range(25)]
        reason = json.loads(guard._block_json("project_settings", names, False))["reason"]
        self.assertIn("CAST_19", reason)
        self.assertNotIn("CAST_20", reason)
        self.assertIn("(+5 more)", reason)

        long_name = "CAST_" + "A" * 200
        reason = json.loads(guard._block_json("local_settings", [long_name], False))["reason"]
        self.assertIn("A" * 59, reason)
        self.assertNotIn("A" * 60, reason)

        reason = json.loads(guard._block_json("local_settings", ["CAST_\n\x1b[31mX"], False))["reason"]
        self.assertNotIn("\n", reason)
        self.assertNotIn("\x1b", reason)

    def test_clean_strips_unicode_line_separators(self):
        dirty = "a" + chr(0x2028) + "b" + chr(0x2029) + "c\x00\x85d"
        self.assertEqual(guard._clean(dirty, 50), "abcd")

    def test_block_json_shape(self):
        data = json.loads(guard._block_json("project_settings", ["PATH"], False))
        self.assertEqual(data["decision"], "block")
        self.assertEqual(
            data["reason"], "cast-config-change-guard: project_settings sets PATH"
        )

    def test_audit_direct_writes_names_only_with_modes(self):
        with tempfile.TemporaryDirectory() as home:
            with mock.patch.dict(os.environ, {"HOME": home}):
                guard._audit("sess\n-1" + "x" * 300, "project_settings",
                             "/p/\x07.claude/settings.json", "block", ["CAST_X"])
            logs = Path(home) / ".claude" / "logs"
            log = logs / "config-change-guard.jsonl"
            self.assertEqual(stat.S_IMODE(os.stat(log).st_mode), 0o600)
            self.assertEqual(stat.S_IMODE(os.stat(logs).st_mode), 0o700)
            lines = log.read_text().splitlines()
            self.assertEqual(len(lines), 1)
            rec = json.loads(lines[0])
            self.assertEqual(rec["verdict"], "block")
            self.assertEqual(rec["names"], ["CAST_X"])
            self.assertEqual(rec["source"], "project_settings")
            self.assertTrue(rec["session_id"].startswith("sess-1x"))
            self.assertLessEqual(len(rec["session_id"]), 128)
            self.assertNotIn("\x07", rec["file_path"])
            self.assertRegex(rec["ts"], r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$")

    def test_audit_failure_is_swallowed_but_reported_on_stderr(self):
        with tempfile.TemporaryDirectory() as home:
            Path(home, ".claude").write_text("i am a file, not a dir")
            err = io.StringIO()
            with mock.patch.dict(os.environ, {"HOME": home}), contextlib.redirect_stderr(err):
                guard._audit("s", "project_settings", "/p", "allow", [])  # must not raise
            self.assertIn("audit log write failed", err.getvalue())


class EndToEndTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.tmp = Path(self._tmp.name)
        self.home = self.tmp / "home"
        self.home.mkdir()
        self.proj = self.tmp / "proj"
        (self.proj / ".claude").mkdir(parents=True)
        self.settings = self.proj / ".claude" / "settings.json"
        self.local = self.proj / ".claude" / "settings.local.json"

    # -- helpers ---------------------------------------------------------
    def run_hook(self, payload, wrapper=WRAPPER, home=None, extra_env=None, raw=None):
        env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"),
               "HOME": str(home if home is not None else self.home)}
        env.update(extra_env or {})
        data = raw if raw is not None else json.dumps(payload)
        return subprocess.run(
            ["bash", str(wrapper)], input=data, env=env,
            capture_output=True, text=True, timeout=10,
        )

    def hook_payload(self, source="project_settings", path=None, **extra):
        payload = {"session_id": "sess-test", "cwd": str(self.proj),
                   "hook_event_name": "ConfigChange", "source": source}
        if path is not None:
            payload["file_path"] = str(path)
        payload.update(extra)
        return payload

    def put(self, path, obj):
        Path(path).write_text(obj if isinstance(obj, str) else json.dumps(obj))
        return path

    def assert_allow(self, proc):
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(proc.stdout, "")

    def assert_block(self, proc, *needles):
        self.assertEqual(proc.returncode, 0, proc.stderr)
        data = json.loads(proc.stdout)
        self.assertEqual(data["decision"], "block")
        for needle in needles:
            self.assertIn(needle, data["reason"])
        return data

    def audit_lines(self, home=None):
        log = Path(home or self.home) / ".claude" / "logs" / "config-change-guard.jsonl"
        if not log.exists():
            return []
        return [json.loads(line) for line in log.read_text().splitlines()]

    # -- verdicts --------------------------------------------------------
    def test_clean_settings_allowed_with_empty_stdout(self):
        self.put(self.settings, {"env": {"APP_MODE": "x"}, "disableAllHooks": False})
        self.assert_allow(self.run_hook(self.hook_payload(path=self.settings)))

    def test_disable_all_hooks_blocked(self):
        self.put(self.settings, {"disableAllHooks": True})
        self.assert_block(self.run_hook(self.hook_payload(path=self.settings)),
                          "disableAllHooks", "project_settings")

    def test_guard_override_env_blocked(self):
        self.put(self.settings, {"env": {"CAST_POLICY_OVERRIDE": "1"}})
        self.assert_block(self.run_hook(self.hook_payload(path=self.settings)),
                          "CAST_POLICY_OVERRIDE")

    def test_bash_env_blocked(self):
        self.put(self.settings, {"env": {"BASH_ENV": "/tmp/evil.sh"}})
        data = self.assert_block(self.run_hook(self.hook_payload(path=self.settings)),
                                 "BASH_ENV")
        self.assertNotIn("/tmp/evil.sh", data["reason"])

    def test_bash_func_blocked(self):
        self.put(self.settings, {"env": {"BASH_FUNC_ls%%": "() { :; }"}})
        self.assert_block(self.run_hook(self.hook_payload(path=self.settings)),
                          "BASH_FUNC_ls%%")

    def test_local_settings_source_blocked(self):
        self.put(self.local, {"env": {"PATH": "/evil"}})
        self.assert_block(self.run_hook(self.hook_payload("local_settings", self.local)),
                          "local_settings", "PATH")

    def test_wrapper_ignores_claude_subprocess_and_policy_override_env(self):
        # The guard protects that very channel: no early-exit, no override env.
        self.put(self.settings, {"disableAllHooks": True})
        proc = self.run_hook(
            self.hook_payload(path=self.settings),
            extra_env={"CLAUDE_SUBPROCESS": "1", "CAST_POLICY_OVERRIDE": "1"},
        )
        self.assert_block(proc, "disableAllHooks")

    # -- unverifiable targets fail closed --------------------------------
    def test_invalid_json_blocked(self):
        self.put(self.settings, "{not json")
        self.assert_block(self.run_hook(self.hook_payload(path=self.settings)),
                          "unverifiable", "<invalid-json>")

    def test_invalid_utf8_blocked(self):
        self.settings.write_bytes(b'{"env": {"A": "\xff\xfe"}}')
        self.assert_block(self.run_hook(self.hook_payload(path=self.settings)),
                          "<invalid-utf8>")

    def test_non_object_json_blocked(self):
        self.put(self.settings, "[1, 2, 3]")
        self.assert_block(self.run_hook(self.hook_payload(path=self.settings)),
                          "<non-object>")

    def test_oversize_settings_blocked(self):
        cap = guard.MAX_SETTINGS_BYTES
        self.assertEqual(cap, 256 * 1024)
        self.settings.write_bytes(b'{"x":"' + b"a" * cap + b'"}')
        self.assert_block(self.run_hook(self.hook_payload(path=self.settings)),
                          "<oversize>")
        # Just over the cap, by one byte, is still oversize ...
        self.settings.write_bytes(b'{"x":"' + b"a" * (cap - 7) + b'"}')  # exactly cap + 1
        self.assertEqual(self.settings.stat().st_size, cap + 1)
        self.assert_block(self.run_hook(self.hook_payload(path=self.settings)),
                          "<oversize>")
        # ... and exactly at the cap is judged normally.
        self.settings.write_bytes(b'{"x":"' + b"a" * (cap - 8) + b'"}')
        self.assertEqual(self.settings.stat().st_size, cap)
        self.assert_allow(self.run_hook(self.hook_payload(path=self.settings)))

    def test_worst_case_file_at_the_cap_finishes_well_inside_the_deadline(self):
        cap = guard.MAX_SETTINGS_BYTES
        for label, prefix, expect in (("offending", "CAST_", "CAST_0"),
                                      ("benign", "BENIGN_KEY_", None)):
            with self.subTest(label=label):
                body = ",".join(f'"{prefix}{i}":""' for i in range(40000))
                text = '{"env":{' + body + "}}"
                text = text[: text.rfind(",", 0, cap - 4)] + "}}"  # trim to <= cap, stay valid
                self.settings.write_text(text)
                self.assertLessEqual(self.settings.stat().st_size, cap)
                started = time.monotonic()
                proc = self.run_hook(self.hook_payload(path=self.settings))
                elapsed = time.monotonic() - started
                # Property: the verdict is the EVALUATED one (offenders named / empty
                # allow), never the deadline's block, so evaluation beat the 2.5 s
                # self-deadline. The wall-clock bound is only a loose sanity ceiling
                # under the hook's own 5 s timeout, startup included.
                self.assertLess(elapsed, 4.5)
                if expect:
                    data = self.assert_block(proc, expect)
                    self.assertIn("sets", data["reason"])
                    self.assertNotIn("deadline", data["reason"])
                    self.assertNotIn("unverifiable", data["reason"])
                else:
                    self.assert_allow(proc)  # empty stdout: the deadline would have blocked

    def test_env_key_syntax_bypass_vectors_blocked_end_to_end(self):
        vectors = {
            "BASH_ENV\x00x": "BASH_ENV",
            "PATH\x00": "PATH",
            "BASH_ENV=/p/evil.sh": "BASH_ENV",
            "PATH=/p/evil:": "PATH",
            "CLAUDE_SUBPROCESS=1": "CLAUDE_SUBPROCESS",
            " PATH": "PATH",
            "FOO\x00PATH": "env:<bad-name>",
        }
        for key, expected in vectors.items():
            with self.subTest(key=key):
                self.put(self.settings, {"env": {key: "/p/evil.sh"}})  # json.dumps escapes NUL
                data = self.assert_block(self.run_hook(self.hook_payload(path=self.settings)),
                                         expected)
                self.assertNotIn("/p/evil.sh", data["reason"])
                self.assertNotIn("\x00", data["reason"])

    def test_anthropic_and_proxy_env_blocked_end_to_end(self):
        for key in ("ANTHROPIC_BASE_URL", "CLAUDE_CODE_SHELL_PREFIX", "HTTPS_PROXY",
                    "NODE_EXTRA_CA_CERTS", "CLAUDE_PROJECT_DIR",
                    "NODE_TLS_REJECT_UNAUTHORIZED", "SSLKEYLOGFILE", "AWS_ENDPOINT_URL",
                    "GOOGLE_APPLICATION_CREDENTIALS",
                    "CLAUDE_BASH_MAINTAIN_PROJECT_WORKING_DIR"):
            with self.subTest(key=key):
                self.put(self.settings, {"env": {key: "x"}})
                self.assert_block(self.run_hook(self.hook_payload(path=self.settings)), key)

    # -- self-deadline -----------------------------------------------------
    def test_deadline_blocks_when_evaluation_stalls(self):
        # Slow evaluate injected through a driver (no test hooks in prod code).
        self.put(self.settings, {"env": {"APP_MODE": "x"}})
        driver = self.tmp / "slow_driver.py"
        driver.write_text(
            "import sys, time\n"
            f"sys.path.insert(0, {str(SCRIPTS)!r})\n"
            "import cast_config_change_guard as g\n"
            "g.evaluate = lambda obj: time.sleep(30)\n"
            "sys.exit(g.main())\n"
        )
        # evaluate sleeps 30 s, so a deadline block in the output proves the 2.5 s
        # self-deadline pre-empted it; timeout=15 (< 30) is the hang guard.
        proc = subprocess.run(
            [sys.executable, "-I", str(driver)], input=json.dumps(self.hook_payload(path=self.settings)),
            env={"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": str(self.home)},
            capture_output=True, text=True, timeout=15,
        )
        self.assertEqual(proc.returncode, 0)
        data = json.loads(proc.stdout)
        self.assertEqual(data["decision"], "block")
        self.assertIn("deadline", data["reason"])
        self.assertIn("deadline exceeded", proc.stderr)

    def test_deadline_is_well_inside_the_registered_hook_timeout(self):
        # Deterministic stand-in for any wall-clock check of that relationship: the
        # self-deadline must leave real headroom under the ConfigChange hook timeout
        # registered in the managed-settings fragment (else the host's own timeout
        # fires first and renders no decision).
        fragment = json.loads(
            (REPO / "managed-settings.d" / "25-hooks-security.json").read_text())
        timeouts = [h["timeout"] for entry in fragment["hooks"]["ConfigChange"]
                    for h in entry["hooks"]]
        self.assertTrue(timeouts)
        for timeout in timeouts:
            self.assertLessEqual(guard.DEADLINE_SECONDS * 2, timeout)

    def test_deadline_blocks_when_stdin_never_closes(self):
        # A stalled read (network/iCloud-style stall) must also be answered, through
        # the real wrapper, before the hook's own 5 s timeout.
        proc = subprocess.Popen(
            ["bash", str(WRAPPER)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, text=True,
            env={"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": str(self.home)},
        )
        self.addCleanup(proc.kill)
        # stdin is left open on purpose; the process can only exit via the deadline,
        # so wait() returning (TimeoutExpired = failure) plus a deadline block is the proof.
        proc.wait(timeout=10)
        out = proc.stdout.read()
        data = json.loads(out)
        self.assertEqual(data["decision"], "block")
        self.assertIn("deadline", data["reason"])
        proc.stdin.close()
        proc.stdout.close()
        proc.stderr.close()

    # -- L1: both candidates are judged when file_path is absent ---------
    def _split_layout(self):
        """proj (CLAUDE_PROJECT_DIR) and proj/pkg/sub (cwd), each with its own .claude/."""
        sub = self.proj / "pkg" / "sub"
        (sub / ".claude").mkdir(parents=True)
        return sub, sub / ".claude" / "settings.json"

    def test_cpd_benign_but_cwd_malicious_blocks(self):
        sub, sub_settings = self._split_layout()
        self.put(self.settings, {"env": {"APP_MODE": "x"}})
        self.put(sub_settings, {"disableAllHooks": True})
        proc = self.run_hook(self.hook_payload("project_settings", cwd=str(sub)),
                             extra_env={"CLAUDE_PROJECT_DIR": str(self.proj)})
        self.assert_block(proc, "disableAllHooks")
        self.assertEqual(self.audit_lines()[-1]["file_path"], str(sub_settings))

    def test_cwd_benign_but_cpd_malicious_blocks(self):
        sub, sub_settings = self._split_layout()
        self.put(self.settings, {"env": {"BASH_ENV": "/p/evil.sh"}})
        self.put(sub_settings, {"env": {"APP_MODE": "x"}})
        proc = self.run_hook(self.hook_payload("project_settings", cwd=str(sub)),
                             extra_env={"CLAUDE_PROJECT_DIR": str(self.proj)})
        self.assert_block(proc, "BASH_ENV")
        self.assertEqual(self.audit_lines()[-1]["file_path"], str(self.settings))

    def test_both_candidates_benign_allows_and_audits_both_paths(self):
        sub, sub_settings = self._split_layout()
        self.put(self.settings, {"env": {"APP_MODE": "x"}})
        self.put(sub_settings, {"env": {"APP_MODE": "y"}})
        proc = self.run_hook(self.hook_payload("project_settings", cwd=str(sub)),
                             extra_env={"CLAUDE_PROJECT_DIR": str(self.proj)})
        self.assert_allow(proc)
        logged = self.audit_lines()[-1]["file_path"]
        self.assertIn(str(self.settings), logged)
        self.assertIn(str(sub_settings), logged)

    def test_one_candidate_unverifiable_blocks_even_if_other_is_benign(self):
        sub, sub_settings = self._split_layout()
        self.put(self.settings, {"env": {"APP_MODE": "x"}})
        self.put(sub_settings, "{not json")
        proc = self.run_hook(self.hook_payload("project_settings", cwd=str(sub)),
                             extra_env={"CLAUDE_PROJECT_DIR": str(self.proj)})
        self.assert_block(proc, "unverifiable", "<invalid-json>")

    def test_both_candidates_missing_blocks_no_target_file(self):
        sub = self.proj / "pkg" / "sub"
        sub.mkdir(parents=True)
        proc = self.run_hook(self.hook_payload("project_settings", cwd=str(sub)),
                             extra_env={"CLAUDE_PROJECT_DIR": str(self.proj)})
        self.assert_block(proc, "unverifiable", "<no-target-file>")

    def test_only_one_candidate_missing_is_not_no_target_file(self):
        sub = self.proj / "pkg" / "sub"
        sub.mkdir(parents=True)  # cwd candidate missing, CPD candidate present + benign
        self.put(self.settings, {"env": {"APP_MODE": "x"}})
        proc = self.run_hook(self.hook_payload("project_settings", cwd=str(sub)),
                             extra_env={"CLAUDE_PROJECT_DIR": str(self.proj)})
        self.assert_allow(proc)

    def test_target_paths_order_and_dedupe(self):
        with mock.patch.dict(os.environ, {"CLAUDE_PROJECT_DIR": "/proj"}):
            paths, derived = guard._target_paths({"cwd": "/proj/pkg"}, "project_settings")
            self.assertEqual(paths, ["/proj/.claude/settings.json",
                                     "/proj/pkg/.claude/settings.json"])
            self.assertTrue(derived)
            paths, _ = guard._target_paths({"cwd": "/proj/"}, "local_settings")
            self.assertEqual(paths, ["/proj/.claude/settings.local.json"])  # deduped
            self.assertEqual(
                guard._target_paths({"file_path": "/x/y.json", "cwd": "/z"}, "project_settings"),
                (["/x/y.json"], False))

    # -- F5: derivation when file_path is absent -------------------------
    def test_subdir_cwd_without_file_path_blocks_instead_of_allowing(self):
        sub = self.proj / "pkg" / "sub"
        sub.mkdir(parents=True)
        self.put(self.settings, {"disableAllHooks": True})
        payload = self.hook_payload("project_settings", cwd=str(sub))
        self.assert_block(self.run_hook(payload), "unverifiable", "<no-target-file>")

    def test_derived_file_missing_blocks_but_explicit_missing_file_allows(self):
        self.assert_block(self.run_hook(self.hook_payload("project_settings")),
                          "<no-target-file>")
        self.assert_allow(self.run_hook(
            self.hook_payload("project_settings", path=self.proj / ".claude" / "gone.json")))

    def test_claude_project_dir_is_used_before_cwd(self):
        sub = self.proj / "pkg" / "sub"
        sub.mkdir(parents=True)
        payload = self.hook_payload("project_settings", cwd=str(sub))
        env = {"CLAUDE_PROJECT_DIR": str(self.proj)}
        self.put(self.settings, {"disableAllHooks": True})
        self.assert_block(self.run_hook(payload, extra_env=env), "disableAllHooks")
        self.put(self.settings, {"env": {"APP_MODE": "x"}})
        self.assert_allow(self.run_hook(payload, extra_env=env))

    def test_fifo_blocked_without_hanging(self):
        os.mkfifo(self.settings)
        proc = self.run_hook(self.hook_payload(path=self.settings))  # timeout=10: TimeoutExpired = hang
        self.assert_block(proc, "<not-regular-file>")

    def test_directory_target_blocked(self):
        self.settings.mkdir()
        self.assert_block(self.run_hook(self.hook_payload(path=self.settings)),
                          "<not-regular-file>")

    def test_symlink_judged_by_target(self):
        evil = self.put(self.tmp / "evil.json", {"env": {"BASH_ENV": "/x"}})
        clean = self.put(self.tmp / "clean.json", {"env": {"APP_MODE": "x"}})
        self.settings.symlink_to(evil)
        self.assert_block(self.run_hook(self.hook_payload(path=self.settings)), "BASH_ENV")
        self.settings.unlink()
        self.settings.symlink_to(clean)
        self.assert_allow(self.run_hook(self.hook_payload(path=self.settings)))

    def test_symlink_to_fifo_blocked_without_hanging(self):
        fifo = self.tmp / "pipe"
        os.mkfifo(fifo)
        self.settings.symlink_to(fifo)
        self.assert_block(self.run_hook(self.hook_payload(path=self.settings)),
                          "<not-regular-file>")

    def test_missing_file_allowed(self):
        self.assert_allow(self.run_hook(self.hook_payload(path=self.proj / ".claude" / "nope.json")))

    # -- path derivation -------------------------------------------------
    def test_cwd_derivation_project(self):
        self.put(self.settings, {"env": {"PATH": "/evil"}})
        self.assert_block(self.run_hook(self.hook_payload("project_settings")), "PATH")

    def test_cwd_derivation_local(self):
        self.put(self.local, {"disableAllHooks": True})
        self.assert_block(self.run_hook(self.hook_payload("local_settings")), "disableAllHooks")

    def test_cwd_derivation_picks_file_for_the_source(self):
        # project source must read settings.json, not the (evil) local file.
        self.put(self.settings, {"env": {"APP_MODE": "x"}})
        self.put(self.local, {"disableAllHooks": True})
        self.assert_allow(self.run_hook(self.hook_payload("project_settings")))
        self.assert_block(self.run_hook(self.hook_payload("local_settings")), "disableAllHooks")

    def test_no_file_path_and_no_cwd_blocked(self):
        payload = {"session_id": "s", "source": "project_settings"}
        self.assert_block(self.run_hook(payload), "<no-target-path>")

    # -- out-of-scope payloads: silent allow -----------------------------
    def test_other_sources_ignored(self):
        self.put(self.settings, {"disableAllHooks": True})
        for source in ("user_settings", "policy_settings", "skills", "", None, 5):
            with self.subTest(source=source):
                payload = self.hook_payload(path=self.settings)
                payload["source"] = source
                self.assert_allow(self.run_hook(payload))
        self.assertEqual(self.audit_lines(), [])  # not evaluated -> not audited

    def test_contract_validator_payload_and_non_dict_payloads_empty(self):
        self.assert_allow(self.run_hook({"key": "test"}))
        for raw in ("[]", '"str"', "5", "null"):
            with self.subTest(raw=raw):
                self.assert_allow(self.run_hook(None, raw=raw))

    def test_unparseable_stdin_fails_closed(self):
        # NB: cast-validate-hook-contracts.sh currently sends `{"key":"test"}}`
        # (its `${!var:-{}}` expansion appends a stray brace), so it observes this
        # block; once the validator is fixed it sends valid `{"key":"test"}` (silent).
        for raw in ('{"key":"test"}}', "{nope", "", "\n"):
            with self.subTest(raw=raw):
                self.assert_block(self.run_hook(None, raw=raw),
                                  "unverifiable", "<stdin-invalid-json>")
        self.assertEqual(
            [r["names"] for r in self.audit_lines()], [["<stdin-invalid-json>"]] * 4)

    def test_unparseable_stdin_is_noted_in_hook_errors_log(self):
        self.assert_block(self.run_hook(None, raw="{nope"), "<stdin-invalid-json>")
        errlog = (self.home / ".claude" / "logs" / "hook-errors.log").read_text()
        self.assertIn("stdin is not valid JSON", errlog)

    def test_invalid_utf8_stdin_fails_closed(self):
        proc = subprocess.run(
            ["bash", str(WRAPPER)], input=b'{"source": "\xff"}',
            env={"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": str(self.home)},
            capture_output=True, timeout=10,
        )
        self.assertEqual(proc.returncode, 0)
        data = json.loads(proc.stdout)
        self.assertEqual(data["decision"], "block")
        self.assertIn("<stdin-invalid-json>", data["reason"])

    def test_oversize_stdin_blocked(self):
        big = json.dumps({"source": "project_settings", "pad": "a" * (1 << 20)})
        self.assert_block(self.run_hook(None, raw=big), "<stdin-oversize>")

    # -- fail-closed wrapper ---------------------------------------------
    def test_evaluator_missing_fails_closed(self):
        lone = self.tmp / "lone"
        lone.mkdir()
        shutil.copy(WRAPPER, lone / WRAPPER.name)
        self.assert_block(self.run_hook(self.hook_payload(path=self.settings),
                                        wrapper=lone / WRAPPER.name),
                          "evaluator failed")

    def test_evaluator_nonzero_exit_fails_closed(self):
        for body in ("import sys\nsys.exit(3)\n", "raise RuntimeError('boom')\n"):
            with self.subTest(body=body):
                stub = self.tmp / "stub"
                shutil.rmtree(stub, ignore_errors=True)
                stub.mkdir()
                shutil.copy(WRAPPER, stub / WRAPPER.name)
                (stub / EVALUATOR.name).write_text(body)
                self.assert_block(self.run_hook(self.hook_payload(path=self.settings),
                                                wrapper=stub / WRAPPER.name),
                                  "evaluator failed")

    def test_wrapper_passes_evaluator_stdout_through_verbatim(self):
        stub = self.tmp / "stub2"
        stub.mkdir()
        shutil.copy(WRAPPER, stub / WRAPPER.name)
        (stub / EVALUATOR.name).write_text('print(\'{"decision":"block","reason":"stub"}\')\n')
        data = self.assert_block(self.run_hook({"source": "project_settings"},
                                               wrapper=stub / WRAPPER.name), "stub")
        self.assertEqual(data["reason"], "stub")

    # -- audit log -------------------------------------------------------
    def test_audit_logs_names_never_values(self):
        self.put(self.settings, {"env": {"CAST_X": "s3cr3t-canary"}})
        proc = self.run_hook(self.hook_payload(path=self.settings))
        self.assert_block(proc, "CAST_X")
        self.assertNotIn("s3cr3t-canary", proc.stdout)
        self.assertNotIn("s3cr3t-canary", proc.stderr)
        log = self.home / ".claude" / "logs" / "config-change-guard.jsonl"
        text = log.read_text()
        self.assertIn("CAST_X", text)
        self.assertNotIn("s3cr3t-canary", text)
        self.assertEqual(stat.S_IMODE(os.stat(log).st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(os.stat(log.parent).st_mode), 0o700)
        rec = self.audit_lines()[0]
        self.assertEqual(rec["verdict"], "block")
        self.assertEqual(rec["names"], ["CAST_X"])
        self.assertEqual(rec["source"], "project_settings")
        self.assertEqual(rec["session_id"], "sess-test")
        self.assertEqual(rec["file_path"], str(self.settings))

    def test_audit_logs_allow_verdict_and_appends(self):
        self.put(self.settings, {"env": {"APP_MODE": "x"}})
        self.run_hook(self.hook_payload(path=self.settings))
        self.put(self.settings, {"disableAllHooks": True})
        self.run_hook(self.hook_payload(path=self.settings))
        self.assertEqual([r["verdict"] for r in self.audit_lines()], ["allow", "block"])

    def test_audit_failure_never_changes_verdict(self):
        broken_home = self.tmp / "broken-home"
        broken_home.mkdir()
        (broken_home / ".claude").write_text("a file where the dir should be")
        self.put(self.settings, {"disableAllHooks": True})
        self.assert_block(self.run_hook(self.hook_payload(path=self.settings), home=broken_home),
                          "disableAllHooks")
        self.put(self.settings, {"env": {"APP_MODE": "x"}})
        self.assert_allow(self.run_hook(self.hook_payload(path=self.settings), home=broken_home))

    def test_audit_does_not_follow_symlinked_log(self):
        logs = self.home / ".claude" / "logs"
        logs.mkdir(parents=True)
        victim = self.tmp / "victim.txt"
        victim.write_text("untouched")
        (logs / "config-change-guard.jsonl").symlink_to(victim)
        self.put(self.settings, {"disableAllHooks": True})
        self.assert_block(self.run_hook(self.hook_payload(path=self.settings)), "disableAllHooks")
        self.assertEqual(victim.read_text(), "untouched")
        # The failed audit write is not silent: the wrapper appends stderr here.
        self.assertIn("audit log write failed", (logs / "hook-errors.log").read_text())


if __name__ == "__main__":
    unittest.main()
