#!/usr/bin/env python3
"""cast-ci-watch.py — Python backend for cast-ci-watch.sh

Modes (sys.argv[1]):
  state-read  <state_file>
      Print deadline_epoch (int) from the JSON state file.
      Prints 0 if the file is absent, unreadable, or malformed.

  state-write <state_file> <pr> <start_epoch> <deadline_epoch>
      Write {"pr": N, "start_epoch": N, "deadline_epoch": N} to state_file.
      Prints nothing on success; error text to stderr on failure.

  parse-status <pr_json_string>
      Parse the JSON returned by `gh pr view --json mergeable,...`.
      Prints a single pipe-delimited line:
          checks|mergeable|unresolved|merge_state
      Special sentinel prefixes on error:
          PARSE_ERROR|UNKNOWN|0|UNKNOWN   — JSON decode failed
          NO_PR|UNKNOWN|0|UNKNOWN         — JSON has no 'mergeable' key
      checks values: green | pending | failed
      Falls back to pending|UNKNOWN|0|UNKNOWN on unexpected exceptions.
"""

import json
import sys


def cmd_state_read(state_file: str) -> None:
    try:
        with open(state_file) as f:
            d = json.load(f)
        print(d.get("deadline_epoch", 0))
    except Exception:
        print(0)


def cmd_state_write(state_file: str, pr: str, start_epoch: str, deadline_epoch: str) -> None:
    d = {
        "pr": int(pr),
        "start_epoch": int(start_epoch),
        "deadline_epoch": int(deadline_epoch),
    }
    with open(state_file, "w") as f:
        json.dump(d, f)


def cmd_parse_status(pr_json_string: str) -> None:
    FAIL_CONCLUSIONS = {"FAILURE", "ACTION_REQUIRED", "CANCELLED", "TIMED_OUT", "ERROR"}
    FAIL_STATES = {"FAILURE", "ERROR"}

    try:
        data = json.loads(pr_json_string)
    except Exception:
        print("PARSE_ERROR|UNKNOWN|0|UNKNOWN")
        return

    if data is None or "mergeable" not in data:
        print("NO_PR|UNKNOWN|0|UNKNOWN")
        return

    # Unresolved review threads
    threads = data.get("reviewThreads") or []
    unresolved = sum(1 for t in threads if not t.get("isResolved", True))

    # Mergeable fields
    mergeable = data.get("mergeable") or "UNKNOWN"
    merge_state = data.get("mergeStateStatus") or "UNKNOWN"

    # CI check rollup
    rollup = data.get("statusCheckRollup") or []
    if not rollup:
        print(f"pending|{mergeable}|{unresolved}|{merge_state}")
        return

    has_pending = False
    has_failed = False

    for check in rollup:
        if "conclusion" in check:
            conclusion = (check.get("conclusion") or "").upper()
            status = (check.get("status") or "").upper()
            if conclusion in FAIL_CONCLUSIONS:
                has_failed = True
            elif status in ("QUEUED", "IN_PROGRESS", "WAITING", "PENDING", "REQUESTED"):
                has_pending = True
            elif conclusion == "":
                has_pending = True
        elif "state" in check:
            state = (check.get("state") or "").upper()
            if state in FAIL_STATES:
                has_failed = True
            elif state in ("PENDING", "EXPECTED"):
                has_pending = True

    if has_failed:
        checks = "failed"
    elif has_pending:
        checks = "pending"
    else:
        checks = "green"

    print(f"{checks}|{mergeable}|{unresolved}|{merge_state}")


def main() -> None:
    if len(sys.argv) < 2:
        print("usage: cast-ci-watch.py <mode> [args...]", file=sys.stderr)
        sys.exit(1)

    mode = sys.argv[1]

    if mode == "state-read":
        if len(sys.argv) < 3:
            print("usage: cast-ci-watch.py state-read <state_file>", file=sys.stderr)
            sys.exit(1)
        cmd_state_read(sys.argv[2])

    elif mode == "state-write":
        if len(sys.argv) < 6:
            print(
                "usage: cast-ci-watch.py state-write <state_file> <pr> <start_epoch> <deadline_epoch>",
                file=sys.stderr,
            )
            sys.exit(1)
        cmd_state_write(sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5])

    elif mode == "parse-status":
        if len(sys.argv) < 3:
            print("usage: cast-ci-watch.py parse-status <pr_json_string>", file=sys.stderr)
            sys.exit(1)
        cmd_parse_status(sys.argv[2])

    else:
        print(f"unknown mode: {mode}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
