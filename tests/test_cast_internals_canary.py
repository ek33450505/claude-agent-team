#!/usr/bin/env python3
"""Tests for scripts/cast-internals-canary.py (G3-A).

Every test builds an isolated temp HOME (and a temp CAST_DB_PATH) - the real
~/.claude is never read. The hyphenated script is loaded via importlib.
"""
import importlib.util
import io
import json
import os
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from datetime import datetime, timedelta, timezone
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent.parent / "scripts" / "cast-internals-canary.py"
_spec = importlib.util.spec_from_file_location("cast_internals_canary", SCRIPT)
canary = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(canary)

GOOD = {"agentType": "backend-writer", "description": "d", "spawnDepth": 1}
NOW_ISO = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


class CanaryBase(unittest.TestCase):
    def setUp(self):
        self._td = tempfile.TemporaryDirectory()
        self.addCleanup(self._td.cleanup)
        self.home = Path(self._td.name)
        (self.home / ".claude" / "logs").mkdir(parents=True)
        self.proj = self.home / ".claude" / "projects" / "p" / "sess" / "subagents"
        self.proj.mkdir(parents=True)
        self.n = 0
        self._old = os.environ.pop("CAST_DB_PATH", None)
        self.addCleanup(self._restore_env)

    def _restore_env(self):
        if self._old is None:
            os.environ.pop("CAST_DB_PATH", None)
        else:
            os.environ["CAST_DB_PATH"] = self._old

    def sidecar(self, obj=None, raw=None, where=None):
        self.n += 1
        d = where or self.proj
        d.mkdir(parents=True, exist_ok=True)
        p = d / f"agent-{self.n}.meta.json"
        p.write_text(raw if raw is not None else json.dumps(GOOD if obj is None else obj))
        return p

    def hatch(self, **over):
        rec = {"event": "COMMIT_HATCH_USED", "in_claude_session": True,
               "session_id": "s", "agent_type": "commit", "agent_id": "a1",
               "tool_use_id": "t"}
        rec.update(over)
        rec = {k: v for k, v in rec.items() if v is not None}
        with open(self.home / ".claude" / "logs" / "audit.jsonl", "a") as fh:
            fh.write(json.dumps(rec) + "\n")

    def db(self, total, with_id):
        con = sqlite3.connect(self.home / ".claude" / "cast.db")
        con.execute("CREATE TABLE IF NOT EXISTS agent_runs "
                    "(started_at TEXT, agent_id TEXT)")
        for i in range(total):
            con.execute("INSERT INTO agent_runs VALUES (?, ?)",
                        (NOW_ISO, f"id{i}" if i < with_id else None))
        con.commit()
        con.close()

    def run_main(self, *extra):
        buf = io.StringIO()
        with redirect_stdout(buf):
            rc = canary.main(["--json", "--home", str(self.home), *extra])
        return rc, json.loads(buf.getvalue())

    def codes(self, out, sev=None):
        return {f["code"] for f in out["findings"] if sev is None or f["severity"] == sev}


class TestChecks(CanaryBase):
    def healthy(self, n=12):
        for _ in range(n):
            self.sidecar()
        self.hatch()
        self.db(10, 10)

    def test_happy_path_ok(self):
        self.healthy()
        rc, out = self.run_main()
        self.assertEqual((rc, out["state"], out["findings"]), (0, "ok", []))
        self.assertEqual((out["sidecars"], out["hatch_lines"], out["db_rows"]), (12, 1, 10))

    def test_workflows_layout_found(self):
        self.sidecar(where=self.proj / "workflows" / "w1")
        rc, out = self.run_main()
        self.assertEqual(out["sidecars"], 1)

    def test_layout_fires_and_silent(self):
        self.db(6, 6)
        rc, out = self.run_main()
        self.assertEqual((rc, out["state"]), (1, "drift"))
        self.assertIn("SIDECAR_LAYOUT", self.codes(out, "drift"))
        self.sidecar()
        _, out = self.run_main()
        self.assertNotIn("SIDECAR_LAYOUT", self.codes(out))

    def test_layout_silent_below_threshold(self):
        self.db(4, 4)
        _, out = self.run_main()
        self.assertNotIn("SIDECAR_LAYOUT", self.codes(out))

    def test_agenttype_fires(self):
        for bad in ({"spawnDepth": 1}, {"agentType": "", "spawnDepth": 1},
                    {"agentType": 5, "spawnDepth": 1}):
            self.sidecar(bad)
        rc, out = self.run_main()
        self.assertEqual(rc, 1)
        f = [x for x in out["findings"] if x["code"] == "SIDECAR_AGENTTYPE"][0]
        self.assertIn("3 of 3", f["detail"])

    def test_agenttype_silent(self):
        self.sidecar()
        _, out = self.run_main()
        self.assertNotIn("SIDECAR_AGENTTYPE", self.codes(out))

    def test_spawndepth_fires_and_bool_not_int(self):
        for _ in range(10):
            self.sidecar({"agentType": "x", "spawnDepth": True})
        rc, out = self.run_main()
        self.assertEqual(rc, 1)
        self.assertIn("SIDECAR_SPAWNDEPTH", self.codes(out, "drift"))

    def test_spawndepth_silent_when_few_or_good(self):
        for _ in range(9):  # below the 10-sample floor
            self.sidecar({"agentType": "x"})
        _, out = self.run_main()
        self.assertNotIn("SIDECAR_SPAWNDEPTH", self.codes(out))
        for _ in range(11):
            self.sidecar()
        _, out = self.run_main()
        self.assertIn("SIDECAR_SPAWNDEPTH", self.codes(out))  # 11/20 = 0.55 < .95
        for _ in range(300):
            self.sidecar()
        _, out = self.run_main()
        self.assertNotIn("SIDECAR_SPAWNDEPTH", self.codes(out))

    def test_unparsable_drift_vs_info(self):
        for _ in range(9):
            self.sidecar()
        for _ in range(3):  # 3/12 = 0.25 > 0.05 and >= 3 files -> drift
            self.sidecar(raw="{not json")
        _, out = self.run_main()
        self.assertIn("SIDECAR_UNPARSABLE", self.codes(out, "drift"))

    def test_unparsable_single_file_is_info_only(self):
        for _ in range(9):
            self.sidecar()
        self.sidecar(raw="{not json")  # one mid-write file must not alarm
        rc, out = self.run_main()
        self.assertEqual(rc, 0)
        self.assertIn("SIDECAR_UNPARSABLE", self.codes(out, "info"))

    def test_unparsable_info_when_small_sample(self):
        self.sidecar()
        self.sidecar(raw="[1,2]")  # valid JSON but not an object
        rc, out = self.run_main()
        self.assertEqual(rc, 0)
        self.assertIn("SIDECAR_UNPARSABLE", self.codes(out, "info"))

    def test_unparsable_silent_when_clean(self):
        self.sidecar()
        _, out = self.run_main()
        self.assertNotIn("SIDECAR_UNPARSABLE", self.codes(out))

    MATE = {**GOOD, "teamName": "t", "taskKind": "k", "customAgentType": "c",
            "color": "x"}

    def test_teammate_markers_fires_and_silent(self):
        self.sidecar({**GOOD, "teamName": "t"})
        rc, out = self.run_main()
        self.assertEqual(rc, 1)
        self.assertIn("TEAMMATE_MARKERS", self.codes(out, "drift"))
        self.sidecar({**GOOD, "taskKind": "k"})
        _, out = self.run_main()
        self.assertIn("TEAMMATE_MARKERS", self.codes(out))  # each lacks the other

    def test_teammate_markers_silent_when_paired(self):
        for _ in range(6):
            self.sidecar(self.MATE)
        _, out = self.run_main()
        self.assertNotIn("TEAMMATE_MARKERS", self.codes(out))
        self.assertNotIn("TEAMMATE_CUSTOM_TYPE", self.codes(out))

    def test_teammate_joint_rename_fires(self):
        # taskKind+teamName both renamed; other teammate markers still present
        renamed = {**GOOD, "customAgentType": "c", "color": "x",
                   "planModeRequired": False, "permissionMode": "m"}
        for _ in range(3):
            self.sidecar(renamed)
        rc, out = self.run_main()
        self.assertEqual(rc, 1)
        self.assertIn("TEAMMATE_MARKERS", self.codes(out, "drift"))

    def test_custom_agent_type_rename_fires(self):
        renamed = {k: v for k, v in self.MATE.items() if k != "customAgentType"}
        for _ in range(6):
            self.sidecar(renamed)
        rc, out = self.run_main()
        self.assertEqual(rc, 1)
        self.assertEqual(self.codes(out, "drift"), {"TEAMMATE_CUSTOM_TYPE"})

    def test_custom_agent_type_silent_below_floor(self):
        renamed = {k: v for k, v in self.MATE.items() if k != "customAgentType"}
        for _ in range(4):
            self.sidecar(renamed)
        _, out = self.run_main()
        self.assertNotIn("TEAMMATE_CUSTOM_TYPE", self.codes(out))

    def test_custom_agent_type_ignores_builtin_teammates(self):
        # built-in types never carry customAgentType; they must not dilute the ratio
        base = {k: v for k, v in self.MATE.items() if k != "customAgentType"}
        for _ in range(10):
            self.sidecar({**base, "spawnedAgentType": "general-purpose"})
        for _ in range(2):
            self.sidecar({**self.MATE, "spawnedAgentType": "code-reviewer"})
        _, out = self.run_main()
        self.assertNotIn("TEAMMATE_CUSTOM_TYPE", self.codes(out))

    def test_custom_agent_type_fires_for_roster_teammates(self):
        base = {k: v for k, v in self.MATE.items() if k != "customAgentType"}
        for _ in range(6):
            self.sidecar({**base, "spawnedAgentType": "code-reviewer"})
        _, out = self.run_main()
        f = [x for x in out["findings"] if x["code"] == "TEAMMATE_CUSTOM_TYPE"]
        self.assertEqual([x["severity"] for x in f], ["drift"])
        self.assertIn("0 of 6 roster teammate", f[0]["detail"])

    def test_custom_agent_type_fires_without_spawned_agent_type(self):
        # a renamed spawnedAgentType must stay in the denominator, not go silent
        base = {k: v for k, v in self.MATE.items() if k != "customAgentType"}
        for _ in range(6):
            self.sidecar(base)
        _, out = self.run_main()
        self.assertIn("TEAMMATE_CUSTOM_TYPE", self.codes(out, "drift"))

    def test_new_claude_code_keys_are_known(self):
        self.sidecar({**GOOD, "finished": True, "launchedWithDefaults": True})
        _, out = self.run_main()
        self.assertNotIn("SIDECAR_NEW_KEYS", self.codes(out))

    def test_custom_agent_type_unhashable_spawned_type_counts_as_roster(self):
        base = {k: v for k, v in self.MATE.items() if k != "customAgentType"}
        for _ in range(6):
            self.sidecar({**base, "spawnedAgentType": ["x"]})
        rc, out = self.run_main()
        self.assertEqual((rc, out["state"]), (1, "drift"))
        self.assertIn("TEAMMATE_CUSTOM_TYPE", self.codes(out, "drift"))

    def test_hatch_agent_id_fires_and_silent(self):
        self.hatch(agent_id="")
        rc, out = self.run_main()
        self.assertEqual(rc, 1)
        self.assertIn("HATCH_AGENT_ID", self.codes(out, "drift"))
        self.assertNotIn("HATCH_KEYS", self.codes(out))  # key present but empty

    def test_hatch_agent_id_silent_for_main_session(self):
        self.hatch(agent_type="", agent_id="")
        _, out = self.run_main()
        self.assertNotIn("HATCH_AGENT_ID", self.codes(out))

    def test_hatch_keys_fires(self):
        self.hatch(agent_id=None)
        rc, out = self.run_main()
        self.assertEqual(rc, 1)
        self.assertIn("HATCH_KEYS", self.codes(out, "drift"))

    def test_hatch_ignores_other_events_and_non_claude(self):
        self.hatch(in_claude_session=False, agent_id=None)
        self.hatch(event="OTHER", agent_id=None)
        _, out = self.run_main()
        self.assertEqual(out["hatch_lines"], 0)

    def test_hatch_keeps_newest_20(self):
        for _ in range(25):
            self.hatch()
        _, out = self.run_main()
        self.assertEqual(out["hatch_lines"], 20)

    def test_payload_agent_id_fires_and_silent(self):
        for _ in range(3):
            self.sidecar()
        self.db(10, 4)
        rc, out = self.run_main()
        self.assertEqual(rc, 1)
        self.assertIn("PAYLOAD_AGENT_ID", self.codes(out, "drift"))

    def test_payload_agent_id_uses_newest_rows_not_window_ratio(self):
        self.sidecar()
        con = sqlite3.connect(self.home / ".claude" / "cast.db")
        con.execute("CREATE TABLE agent_runs (started_at TEXT, agent_id TEXT)")
        for i in range(60):  # old healthy rows
            con.execute("INSERT INTO agent_runs VALUES (?, ?)", (NOW_ISO, f"i{i}"))
        for _ in range(20):  # newest 20 lost their agent_id (window ratio 0.75)
            con.execute("INSERT INTO agent_runs VALUES (?, NULL)", (NOW_ISO,))
        con.commit()
        con.close()
        rc, out = self.run_main()
        self.assertEqual(rc, 1)
        self.assertIn("PAYLOAD_AGENT_ID", self.codes(out, "drift"))

    def test_payload_agent_id_silent_below_floor_and_healthy(self):
        self.sidecar()
        self.db(9, 0)
        _, out = self.run_main()
        self.assertNotIn("PAYLOAD_AGENT_ID", self.codes(out))

    def test_new_keys_info(self):
        self.sidecar({**GOOD, "zNew": 1, "aNew": 2})
        rc, out = self.run_main()
        self.assertEqual(rc, 0)
        f = [x for x in out["findings"] if x["code"] == "SIDECAR_NEW_KEYS"][0]
        self.assertEqual(f["severity"], "info")
        self.assertIn("aNew,zNew", f["detail"])

    def test_known_keys_silent(self):
        self.sidecar({**GOOD, "teamName": "t", "taskKind": "k", "color": "c"})
        _, out = self.run_main()
        self.assertNotIn("SIDECAR_NEW_KEYS", self.codes(out))

    def test_isfork_key_known_silent(self):
        # Claude Code writes isFork:true in fork-dispatch sidecars (live sample 2026-10-15).
        self.sidecar({**GOOD, "agentType": "fork", "isFork": True})
        _, out = self.run_main()
        self.assertNotIn("SIDECAR_NEW_KEYS", self.codes(out))


class TestInputHandling(CanaryBase):
    def test_symlinked_sidecar_unparsable(self):
        target = self.home / "real.json"
        target.write_text(json.dumps(GOOD))
        (self.proj / "agent-link.meta.json").symlink_to(target)
        _, out = self.run_main()
        self.assertEqual(out["sidecars"], 1)
        self.assertIn("SIDECAR_UNPARSABLE", self.codes(out))

    def test_oversized_sidecar_unparsable(self):
        self.sidecar(raw=json.dumps({**GOOD, "pad": "x" * (70 * 1024)}))
        _, out = self.run_main()
        self.assertIn("SIDECAR_UNPARSABLE", self.codes(out))

    def test_old_mtime_excluded(self):
        p = self.sidecar()
        old = (datetime.now() - timedelta(days=20)).timestamp()
        os.utime(p, (old, old))
        _, out = self.run_main()
        self.assertEqual(out["sidecars"], 0)
        _, out = self.run_main("--days", "30")
        self.assertEqual(out["sidecars"], 1)

    def test_sample_capped_at_300(self):
        for _ in range(305):
            self.sidecar()
        _, out = self.run_main()
        self.assertEqual(out["sidecars"], 300)

    def test_no_data_state(self):
        rc, out = self.run_main()
        self.assertEqual((rc, out["state"], out["db_rows"]), (0, "no_data", None))

    def test_no_data_with_empty_db_table(self):
        self.db(0, 0)
        rc, out = self.run_main()
        self.assertEqual((rc, out["state"], out["db_rows"]), (0, "no_data", 0))

    def test_db_missing_not_drift(self):
        self.sidecar()
        rc, out = self.run_main()
        self.assertEqual((rc, out["state"], out["db_rows"]), (0, "ok", None))

    def test_db_without_table_unavailable(self):
        sqlite3.connect(self.home / ".claude" / "cast.db").close()
        self.sidecar()
        _, out = self.run_main()
        self.assertIsNone(out["db_rows"])

    def test_cast_db_path_env_used(self):
        other = self.home / "other.db"
        con = sqlite3.connect(other)
        con.execute("CREATE TABLE agent_runs (started_at TEXT, agent_id TEXT)")
        con.execute("INSERT INTO agent_runs VALUES (?, 'x')", (NOW_ISO,))
        con.commit()
        con.close()
        os.environ["CAST_DB_PATH"] = str(other)
        _, out = self.run_main()
        self.assertEqual(out["db_rows"], 1)

    def test_hatch_tail_truncation_skips_partial_line(self):
        path = self.home / ".claude" / "logs" / "audit.jsonl"
        # First line = junk prefix + a complete hatch-shaped object, so its
        # SUFFIX is a valid hatch record (agent_type set, agent_id empty). The
        # 2 MiB cut lands at the end of the prefix; the partial line must be dropped.
        rec = json.dumps({"event": "COMMIT_HATCH_USED", "in_claude_session": True,
                          "session_id": "s", "agent_type": "commit",
                          "agent_id": "", "tool_use_id": "t"})
        first = "J" * 100 + rec + "\n"
        tail = canary.HATCH_TAIL_BYTES - (len(first) - 100)  # cut at byte 100
        path.write_text(first + "y" * (tail - 1) + "\n")
        _, out = self.run_main()
        self.assertEqual(out["hatch_lines"], 0)
        self.assertNotIn("HATCH_AGENT_ID", self.codes(out))
        # a real record after the partial line is still read
        self.hatch()
        _, out = self.run_main()
        self.assertEqual(out["hatch_lines"], 1)


class TestOutput(CanaryBase):
    MARKER = "ZZ-DISTINCT-MARKER-VALUE"

    def _plant(self):
        self.sidecar({**GOOD, "description": self.MARKER,
                      "bad key\nMARKERKEY": self.MARKER, "okNewKey": 1})
        self.hatch(session_id=self.MARKER)

    def test_value_leak_json(self):
        self._plant()
        _, out = self.run_main()
        text = json.dumps(out)
        self.assertNotIn(self.MARKER, text)
        self.assertNotIn("MARKERKEY", text)
        self.assertIn("okNewKey", text)
        self.assertIn("1 unprintable", text)

    def test_value_leak_text(self):
        self._plant()
        buf = io.StringIO()
        with redirect_stdout(buf):
            canary.main(["--home", str(self.home)])
        self.assertNotIn(self.MARKER, buf.getvalue())
        self.assertNotIn("MARKERKEY", buf.getvalue())
        self.assertIn("[--] SIDECAR_NEW_KEYS", buf.getvalue())

    def test_text_formats(self):
        buf = io.StringIO()
        with redirect_stdout(buf):
            canary.main(["--home", str(self.home)])
        self.assertEqual(buf.getvalue().strip(), "[--] no data")
        self.sidecar()
        buf = io.StringIO()
        with redirect_stdout(buf):
            canary.main(["--home", str(self.home)])
        self.assertTrue(buf.getvalue().startswith("[ok]"))
        self.sidecar({"spawnDepth": 1})
        buf = io.StringIO()
        with redirect_stdout(buf):
            canary.main(["--home", str(self.home)])
        self.assertIn("[!!] SIDECAR_AGENTTYPE:", buf.getvalue())


class TestSubprocess(CanaryBase):
    def run_cli(self, *args):
        env = {k: v for k, v in os.environ.items() if k != "CAST_DB_PATH"}
        return subprocess.run([sys.executable, "-I", str(SCRIPT), *args],
                              capture_output=True, text=True, env=env,
                              timeout=5)  # a hang regression FAILS, not hangs

    @unittest.skipUnless(hasattr(os, "mkfifo"), "needs os.mkfifo")
    def test_fifo_sidecar_does_not_hang(self):
        os.mkfifo(self.proj / "agent-fifo.meta.json")
        self.sidecar()
        r = self.run_cli("--json", "--home", str(self.home))
        self.assertEqual(r.returncode, 0)
        out = json.loads(r.stdout)
        self.assertEqual(out["sidecars"], 2)
        self.assertIn("SIDECAR_UNPARSABLE", self.codes(out, "info"))

    @unittest.skipUnless(hasattr(os, "mkfifo"), "needs os.mkfifo")
    def test_fifo_audit_log_does_not_hang(self):
        os.mkfifo(self.home / ".claude" / "logs" / "audit.jsonl")
        r = self.run_cli("--json", "--home", str(self.home))
        self.assertEqual(r.returncode, 0)
        self.assertEqual(json.loads(r.stdout)["hatch_lines"], 0)

    @unittest.skipUnless(hasattr(os, "mkfifo"), "needs os.mkfifo")
    def test_fifo_db_does_not_hang(self):
        os.mkfifo(self.home / ".claude" / "cast.db")
        self.sidecar()
        r = self.run_cli("--json", "--home", str(self.home))
        self.assertEqual(r.returncode, 0)
        self.assertIsNone(json.loads(r.stdout)["db_rows"])

    def test_exit_ok(self):
        self.sidecar()
        r = self.run_cli("--json", "--home", str(self.home))
        self.assertEqual(r.returncode, 0)
        self.assertEqual(json.loads(r.stdout)["state"], "ok")

    def test_exit_drift(self):
        self.sidecar({"spawnDepth": 1})
        r = self.run_cli("--json", "--home", str(self.home))
        self.assertEqual(r.returncode, 1)

    def test_json_error_contract(self):
        r = self.run_cli("--json", "--days", "31")
        self.assertEqual(r.returncode, 2)
        self.assertEqual(json.loads(r.stdout), {"state": "error", "findings": []})
        self.assertIn("usage:", r.stderr)

    def test_exit_usage(self):
        for args in (["--bogus"], ["--days"], ["--days", "0"], ["--days", "x"],
                     ["--days", "31"], ["--home"]):
            r = self.run_cli(*args)
            self.assertEqual(r.returncode, 2, args)
            self.assertEqual(r.stdout, "")
            self.assertIn("usage:", r.stderr)

    def test_exit_internal_error_fixed_message(self):
        orig = canary.collect_hatch
        canary.collect_hatch = lambda home: 1 / 0
        self.addCleanup(setattr, canary, "collect_hatch", orig)
        err, out = io.StringIO(), io.StringIO()
        old, sys.stderr = sys.stderr, err
        try:
            with redirect_stdout(out):
                rc = canary.main(["--json", "--home", str(self.home)])
        finally:
            sys.stderr = old
        self.assertEqual(rc, 2)
        self.assertEqual(json.loads(out.getvalue()), {"state": "error", "findings": []})
        self.assertEqual(err.getvalue().strip(), "cast-internals-canary: internal error")

    def test_script_is_executable_with_shebang(self):
        self.assertTrue(os.access(SCRIPT, os.X_OK))
        self.assertEqual(SCRIPT.read_text().splitlines()[0], "#!/usr/bin/env python3")


if __name__ == "__main__":
    unittest.main()
