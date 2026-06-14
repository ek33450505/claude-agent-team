#!/usr/bin/env python3
"""
CAST Hook Wiring Lint

Detects duplicate hook wiring WITHIN a single file: the same script basename
appearing more than once under the same hook event inside settings.json, OR
inside any individual managed-settings.d/*.json fragment.

Architecture note: managed-settings.d/*.json fragments are the CANONICAL hook
sources; settings.json is a GENERATED merged snapshot (produced by
cast-merge-settings.sh). A script that appears in settings.json AND in a
fragment is intentional by design — that overlap is NOT flagged. This lint
only catches the within-file double-wiring class (e.g. cast-session-end wired
twice inside one file's event array).

Exit codes:
  0 — no within-file duplicate wiring found, or input files gracefully absent
  1 — at least one within-file duplicate found, or malformed JSON input

Env overrides (for testing):
  CAST_SETTINGS_FILE  — path to settings.json (default: <repo-root>/settings.json)
  CAST_SETTINGS_DIR   — path to managed-settings.d/ dir (default: <repo-root>/managed-settings.d)
"""

import json
import os
import sys
from collections import defaultdict
from typing import Optional


def get_repo_root() -> str:
    """Get the repository root directory."""
    try:
        result = os.popen("git rev-parse --show-toplevel 2>/dev/null").read().strip()
        if result:
            return result
    except Exception:
        pass
    return os.getcwd()


def extract_basename(command: str) -> Optional[str]:
    """
    Extract a script basename from a hook command string.
    Returns None if no recognisable script invocation is found.

    Recognises:
      bash scripts/foo.sh ...
      bash ~/.claude/scripts/foo.sh ...
      python3 scripts/foo.py ...
    """
    import re
    m = re.search(r"(?:bash|python3|sh)\s+(?:[^\s]*/)([^\s/]+\.(?:sh|py))", command)
    if m:
        return m.group(1)
    return None


def load_json_file(path: str) -> Optional[dict]:
    """
    Load a JSON file. Returns None if the file does not exist.
    Prints an error and raises SystemExit(1) on malformed JSON.
    """
    if not os.path.exists(path):
        return None
    try:
        with open(path, "r") as f:
            return json.load(f)
    except json.JSONDecodeError as e:
        print(f"ERROR [lint-hook-wiring]: malformed JSON in {path}: {e}", file=sys.stderr)
        raise SystemExit(1)


def collect_hook_basenames_per_file(data: dict) -> dict[str, list[str]]:
    """
    Walk `data["hooks"]` and return a per-event list of script basenames found
    within this single file:
      result[event] = [basename, basename, ...]   (may contain duplicates)
    """
    result: dict[str, list[str]] = defaultdict(list)
    hooks_section = data.get("hooks", {})
    if not isinstance(hooks_section, dict):
        return result
    for event, entries in hooks_section.items():
        if not isinstance(entries, list):
            continue
        for entry in entries:
            if not isinstance(entry, dict):
                continue
            # Each entry may have a top-level "command" (flat style)
            # or a nested "hooks" list (group style used by settings.json)
            commands_to_check = []
            if "command" in entry and isinstance(entry["command"], str):
                commands_to_check.append(entry["command"])
            if "hooks" in entry and isinstance(entry["hooks"], list):
                for hook in entry["hooks"]:
                    if isinstance(hook, dict) and isinstance(hook.get("command"), str):
                        commands_to_check.append(hook["command"])
            for cmd in commands_to_check:
                bn = extract_basename(cmd)
                if bn:
                    result[event].append(bn)
    return result


def find_within_file_duplicates(
    data: dict, source_file: str
) -> list[tuple[str, str, str]]:
    """
    Return a list of (event, basename, source_file) for every basename that
    appears more than once under the same event key within `data`.
    """
    per_event = collect_hook_basenames_per_file(data)
    duplicates = []
    for event, basenames in sorted(per_event.items()):
        seen: set[str] = set()
        reported: set[str] = set()
        for bn in basenames:
            if bn in seen and bn not in reported:
                duplicates.append((event, bn, source_file))
                reported.add(bn)
            seen.add(bn)
    return duplicates


def main() -> int:
    repo_root = get_repo_root()

    settings_file = os.environ.get(
        "CAST_SETTINGS_FILE", os.path.join(repo_root, "settings.json")
    )
    settings_dir = os.environ.get(
        "CAST_SETTINGS_DIR", os.path.join(repo_root, "managed-settings.d")
    )

    all_duplicates: list[tuple[str, str, str]] = []

    # Check primary settings file (the generated merge — within-file dups here
    # indicate the merge itself produced a double-wiring)
    primary = load_json_file(settings_file)  # may raise SystemExit(1)
    if primary is not None:
        all_duplicates.extend(find_within_file_duplicates(primary, settings_file))

    # Check each managed-settings.d fragment independently
    if os.path.isdir(settings_dir):
        for fname in sorted(os.listdir(settings_dir)):
            if not fname.endswith(".json"):
                continue
            fpath = os.path.join(settings_dir, fname)
            fragment = load_json_file(fpath)  # may raise SystemExit(1)
            if fragment is not None:
                all_duplicates.extend(find_within_file_duplicates(fragment, fpath))

    if all_duplicates:
        print(f"ERROR [lint-hook-wiring]: {len(all_duplicates)} within-file duplicate hook wiring(s) found:")
        for event, basename, source in all_duplicates:
            print(f"  event={event}  script={basename}")
            print(f"    file: {source}")
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
