#!/usr/bin/env python3
"""
engram-prompt-sentinel.py
Fires on: UserPromptSubmit
Purpose: Write user prompt text to sentinel file for style_capture to read.
Always exits 0 — never blocks prompt submission.
"""
# Copyright 2026 Edward Kubiak
# Apache-2.0 License

import json
import os
import sys
from pathlib import Path

_SENTINEL_PATH = Path.home() / ".claude" / "engram-last-prompt.txt"
_MAX_BYTES = 32 * 1024  # 32KB


def main() -> None:
    try:
        payload = json.loads(sys.stdin.read())
    except (json.JSONDecodeError, ValueError):
        sys.exit(0)

    prompt = payload.get("prompt", "")
    if not prompt or not isinstance(prompt, str):
        sys.exit(0)

    # Truncate to 32KB
    if len(prompt.encode("utf-8")) > _MAX_BYTES:
        prompt = prompt[:_MAX_BYTES]

    try:
        _SENTINEL_PATH.parent.mkdir(parents=True, exist_ok=True)
        _SENTINEL_PATH.write_text(prompt, encoding="utf-8")
        _SENTINEL_PATH.chmod(0o600)
    except OSError:
        pass

    sys.exit(0)


if __name__ == "__main__":
    main()
