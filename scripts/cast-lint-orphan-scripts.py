#!/usr/bin/env python3
"""
CAST Orphan Script Detector

Parses settings.json, extracts every script path referenced in hooks,
and fails if any referenced script is missing from scripts/.

Exit codes:
  0 — all referenced scripts exist
  1 — one or more referenced scripts are missing
"""

import json
import os
import re
import sys
from pathlib import Path

def get_repo_root():
    """Get the repository root directory."""
    try:
        result = os.popen("git rev-parse --show-toplevel 2>/dev/null").read().strip()
        if result:
            return result
    except Exception:
        pass
    return os.getcwd()

def extract_script_paths(settings_dict):
    """Extract all script paths referenced in settings.json hooks."""
    scripts = set()

    def traverse_hooks(obj):
        """Recursively traverse hooks structure to find script references."""
        if isinstance(obj, dict):
            for key, val in obj.items():
                if key == "command" and isinstance(val, str):
                    # Look for bash script invocations: bash scripts/... or bash ~/.claude/scripts/...
                    # Also capture bash /absolute/... so the absolute-path guard in the
                    # resolver can reject it as a contract violation.
                    if "bash scripts/" in val or "bash ~/.claude/scripts/" in val:
                        # Extract the script path
                        if "bash scripts/" in val:
                            parts = val.split("bash scripts/")
                            if len(parts) > 1:
                                script_name = parts[1].split()[0]
                                scripts.add(f"scripts/{script_name}")
                        elif "bash ~/.claude/scripts/" in val:
                            parts = val.split("bash ~/.claude/scripts/")
                            if len(parts) > 1:
                                script_name = parts[1].split()[0]
                                scripts.add(f"~/.claude/scripts/{script_name}")
                    else:
                        # Detect bare absolute-path invocations: `bash /some/path.sh`
                        m = re.search(r"bash\s+(/[^\s]+\.sh)", val)
                        if m:
                            scripts.add(m.group(1))
                traverse_hooks(val)
        elif isinstance(obj, list):
            for item in obj:
                traverse_hooks(item)

    traverse_hooks(settings_dict)
    return scripts

def main():
    repo_root = get_repo_root()
    settings_path = os.path.join(repo_root, "settings.json")

    if not os.path.exists(settings_path):
        print(f"WARNING: {settings_path} not found. Skipping orphan script check.", file=sys.stderr)
        return 0

    try:
        with open(settings_path, "r") as f:
            settings = json.load(f)
    except json.JSONDecodeError as e:
        print(f"ERROR [lint-orphan-scripts]: Failed to parse settings.json: {e}", file=sys.stderr)
        return 1

    referenced_scripts = extract_script_paths(settings)

    if not referenced_scripts:
        return 0

    invalid = []
    missing = []
    for script in sorted(referenced_scripts):
        if script.startswith("~/.claude/scripts/"):
            # ~/.claude/scripts/ paths are sourced from the repo's scripts/ directory.
            # Resolve against the repo (not the live installed location) so this check
            # is hermetic — independent of whether install.sh has been run.
            script_name = os.path.basename(script)
            full_path = os.path.join(repo_root, "scripts", script_name)
        elif os.path.isabs(script):
            # Absolute paths are a contract violation for a hermetic repo lint —
            # they would silently consult the live filesystem (the bug class fixed above).
            invalid.append(script)
            continue
        else:
            full_path = os.path.join(repo_root, script)

        if not os.path.exists(full_path):
            missing.append(script)

    if invalid:
        print(f"ERROR [lint-orphan-scripts]: {len(invalid)} absolute path reference(s) in settings.json hooks (must be repo-relative or ~/.claude/scripts/):", file=sys.stderr)
        for script in invalid:
            print(f"  - {script}", file=sys.stderr)

    if missing:
        print(f"ERROR [lint-orphan-scripts]: {len(missing)} referenced script(s) missing from repo:", file=sys.stderr)
        for script in missing:
            print(f"  - {script}", file=sys.stderr)

    if invalid or missing:
        return 1

    return 0

if __name__ == "__main__":
    sys.exit(main())
