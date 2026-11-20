#!/usr/bin/env python3
"""Tests for scripts/cast-ci-watch.py pure functions.

The `gh` CLI is never invoked: the JSON strings below stand in for its output.
Stdlib unittest only; state files live in a temp dir.
"""

import importlib.util
import io
import json
import os
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
MODULE_PATH = REPO_ROOT / "scripts" / "cast-ci-watch.py"

_spec = importlib.util.spec_from_file_location("cast_ci_watch", MODULE_PATH)
ciw = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(ciw)


def _run(fn, *args) -> str:
    buf = io.StringIO()
    with redirect_stdout(buf):
        fn(*args)
    return buf.getvalue().strip()


def _run_main(*argv: str) -> str:
    saved = sys.argv
    sys.argv = ["cast-ci-watch.py", *argv]
    buf = io.StringIO()
    try:
        with redirect_stdout(buf):
            ciw.main()
    finally:
        sys.argv = saved
    return buf.getvalue().strip()


class StateTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.state = os.path.join(self._tmp.name, "watch-state.json")

    def tearDown(self):
        self._tmp.cleanup()

    def test_state_write_then_read_round_trips_deadline(self):
        ciw.cmd_state_write(self.state, "450", "1700000000", "1700003600")
        with open(self.state) as f:
            self.assertEqual(
                json.load(f),
                {"pr": 450, "start_epoch": 1700000000, "deadline_epoch": 1700003600},
            )
        self.assertEqual(_run(ciw.cmd_state_read, self.state), "1700003600")

    def test_state_read_returns_zero_when_file_absent(self):
        self.assertEqual(_run(ciw.cmd_state_read, self.state), "0")

    def test_state_read_returns_zero_on_malformed_json(self):
        Path(self.state).write_text("{not json")
        self.assertEqual(_run(ciw.cmd_state_read, self.state), "0")

    def test_state_read_returns_zero_when_deadline_key_missing(self):
        Path(self.state).write_text(json.dumps({"pr": 1}))
        self.assertEqual(_run(ciw.cmd_state_read, self.state), "0")

    def test_state_write_rejects_non_integer_pr(self):
        # Error path: a non-numeric PR number must raise, not write a bad file.
        with self.assertRaises(ValueError):
            ciw.cmd_state_write(self.state, "abc", "1", "2")
        self.assertFalse(os.path.exists(self.state))


class ParseStatusTests(unittest.TestCase):
    def test_all_checks_success_is_green(self):
        pr = {
            "mergeable": "MERGEABLE",
            "mergeStateStatus": "CLEAN",
            "statusCheckRollup": [
                {"conclusion": "SUCCESS", "status": "COMPLETED"},
                {"conclusion": "SKIPPED", "status": "COMPLETED"},
            ],
        }
        self.assertEqual(
            _run(ciw.cmd_parse_status, json.dumps(pr)),
            "green|MERGEABLE|0|CLEAN",
        )

    def test_in_progress_check_is_pending(self):
        pr = {
            "mergeable": "MERGEABLE",
            "mergeStateStatus": "BLOCKED",
            "statusCheckRollup": [
                {"conclusion": "", "status": "IN_PROGRESS"},
                {"conclusion": "SUCCESS", "status": "COMPLETED"},
            ],
        }
        self.assertEqual(
            _run(ciw.cmd_parse_status, json.dumps(pr)),
            "pending|MERGEABLE|0|BLOCKED",
        )

    def test_failed_conclusion_wins_over_pending(self):
        pr = {
            "mergeable": "CONFLICTING",
            "mergeStateStatus": "DIRTY",
            "statusCheckRollup": [
                {"conclusion": "FAILURE", "status": "COMPLETED"},
                {"conclusion": "", "status": "QUEUED"},
            ],
        }
        self.assertEqual(
            _run(ciw.cmd_parse_status, json.dumps(pr)),
            "failed|CONFLICTING|0|DIRTY",
        )

    def test_legacy_status_context_failure_is_failed(self):
        pr = {
            "mergeable": "MERGEABLE",
            "mergeStateStatus": "UNSTABLE",
            "statusCheckRollup": [{"state": "ERROR"}],
        }
        self.assertTrue(
            _run(ciw.cmd_parse_status, json.dumps(pr)).startswith("failed|")
        )

    def test_legacy_status_context_expected_is_pending(self):
        pr = {
            "mergeable": "MERGEABLE",
            "mergeStateStatus": "BLOCKED",
            "statusCheckRollup": [{"state": "EXPECTED"}],
        }
        self.assertTrue(
            _run(ciw.cmd_parse_status, json.dumps(pr)).startswith("pending|")
        )

    def test_empty_rollup_is_pending(self):
        pr = {"mergeable": "UNKNOWN", "mergeStateStatus": "UNKNOWN", "statusCheckRollup": []}
        self.assertEqual(
            _run(ciw.cmd_parse_status, json.dumps(pr)),
            "pending|UNKNOWN|0|UNKNOWN",
        )

    def test_unresolved_review_threads_are_counted(self):
        pr = {
            "mergeable": "MERGEABLE",
            "mergeStateStatus": "CLEAN",
            "reviewThreads": [
                {"isResolved": False},
                {"isResolved": True},
                {"isResolved": False},
            ],
            "statusCheckRollup": [{"conclusion": "SUCCESS", "status": "COMPLETED"}],
        }
        self.assertEqual(
            _run(ciw.cmd_parse_status, json.dumps(pr)),
            "green|MERGEABLE|2|CLEAN",
        )

    def test_invalid_json_returns_parse_error_sentinel(self):
        # Error path: gh output that is not JSON must never read as green.
        self.assertEqual(
            _run(ciw.cmd_parse_status, "<html>rate limited</html>"),
            "PARSE_ERROR|UNKNOWN|0|UNKNOWN",
        )

    def test_json_null_returns_no_pr_sentinel(self):
        self.assertEqual(
            _run(ciw.cmd_parse_status, "null"),
            "NO_PR|UNKNOWN|0|UNKNOWN",
        )

    def test_json_without_mergeable_key_returns_no_pr_sentinel(self):
        self.assertEqual(
            _run(ciw.cmd_parse_status, json.dumps({"number": 5})),
            "NO_PR|UNKNOWN|0|UNKNOWN",
        )


class ParseRepoTests(unittest.TestCase):
    def test_returns_owner_and_name(self):
        out = _run(ciw.cmd_parse_repo, json.dumps({"owner": {"login": "metasol"}, "name": "cast"}))
        self.assertEqual(out, "metasol|cast")

    def test_invalid_json_is_parse_error(self):
        self.assertEqual(_run(ciw.cmd_parse_repo, "not-json"), "PARSE_ERROR")

    def test_missing_owner_is_parse_error(self):
        self.assertEqual(_run(ciw.cmd_parse_repo, json.dumps({"name": "cast"})), "PARSE_ERROR")

    def test_empty_name_is_parse_error(self):
        out = json.dumps({"owner": {"login": "metasol"}, "name": ""})
        self.assertEqual(_run(ciw.cmd_parse_repo, out), "PARSE_ERROR")


class ParseThreadsTests(unittest.TestCase):
    @staticmethod
    def _gql(nodes):
        return json.dumps(
            {"data": {"repository": {"pullRequest": {"reviewThreads": {"nodes": nodes}}}}}
        )

    def test_counts_unresolved_nodes(self):
        payload = self._gql([{"isResolved": False}, {"isResolved": True}, {"isResolved": False}])
        self.assertEqual(_run(ciw.cmd_parse_threads, payload), "2")

    def test_no_threads_is_zero(self):
        self.assertEqual(_run(ciw.cmd_parse_threads, self._gql([])), "0")

    def test_malformed_response_is_parse_error_not_zero(self):
        # Error path: a missing key must never be reported as "0 unresolved".
        self.assertEqual(_run(ciw.cmd_parse_threads, json.dumps({"errors": []})), "PARSE_ERROR")

    def test_invalid_json_is_parse_error(self):
        self.assertEqual(_run(ciw.cmd_parse_threads, "{"), "PARSE_ERROR")


class MainDispatchTests(unittest.TestCase):
    def test_unknown_mode_exits_one(self):
        with self.assertRaises(SystemExit) as cm:
            _run_main("bogus-mode")
        self.assertEqual(cm.exception.code, 1)

    def test_missing_mode_exits_one(self):
        with self.assertRaises(SystemExit) as cm:
            _run_main()
        self.assertEqual(cm.exception.code, 1)

    def test_parse_repo_mode_dispatches_with_argument(self):
        out = _run_main("parse-repo", json.dumps({"owner": {"login": "a"}, "name": "b"}))
        self.assertEqual(out, "a|b")


if __name__ == "__main__":
    unittest.main()
