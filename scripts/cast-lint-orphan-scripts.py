#!/usr/bin/env python3
"""
CAST Orphan Script Detector

Scans two sources for hook→script references and fails if any referenced
script is missing from the repo's scripts/ directory:

  1. settings.json       — repo-relative commands (``bash scripts/...``) and
                           tilde-prefixed installs (``bash ~/.claude/scripts/...``)
  2. managed-settings.d/*.json fragments — installed config; fragment commands
                           legitimately reference ``$HOME/.claude/scripts/...`` or
                           ``~/.claude/scripts/...`` because the merged settings are
                           installed into ~/.claude. For existence checks the lint maps
                           referenced script *basenames* back to repo scripts/ — same
                           hermetic invariant as settings.json tilde paths.

Hermeticity rule: this script MUST read only repo files, never the live
~/.claude install. Every path resolution bottoms out at repo_root/scripts/<name>.
Absolute paths (``/usr/...``) are treated as contract violations in settings.json.
In fragments they are simply not matched (fragment paths are always tilde or
HOME-env forms).

Exit codes:
  0 — all referenced scripts exist in repo
  1 — one or more referenced scripts are missing (or contract violation found)
"""

import glob
import json
import os
import re
import sys


def get_repo_root() -> str:
    """Return the repository root directory."""
    try:
        result = os.popen("git rev-parse --show-toplevel 2>/dev/null").read().strip()
        if result:
            return result
    except Exception:
        pass
    return os.getcwd()


def extract_script_paths(settings_dict: dict) -> set[str]:
    """Extract all script paths referenced in settings.json hooks."""
    scripts: set[str] = set()

    def traverse_hooks(obj: object) -> None:
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


def extract_fragment_script_basenames(fragment_dict: dict) -> set[str]:
    """Extract script basenames from a managed-settings.d fragment.

    Fragment commands use installed paths like:
        bash ~/.claude/scripts/cast-foo.sh
        bash $HOME/.claude/scripts/cast-foo.sh

    We extract only the *basename* so the existence check can map it back to
    repo scripts/ — keeping the check hermetic (no live-path reads).

    Only ``type: command`` entries are scanned. ``type: http`` and
    ``type: prompt`` entries never reference scripts and are skipped.
    """
    basenames: set[str] = set()

    def traverse(obj: object) -> None:
        if isinstance(obj, dict):
            hook_type = obj.get("type", "")
            # Skip http and prompt entries — they never reference scripts
            if hook_type in ("http", "prompt"):
                return
            cmd = obj.get("command", "")
            if isinstance(cmd, str):
                # Match: bash ~/.claude/scripts/name.sh [args...]
                m = re.search(r"bash\s+(?:~|\$HOME)/\.claude/scripts/([^\s]+\.sh)", cmd)
                if m:
                    basenames.add(m.group(1))
            for val in obj.values():
                traverse(val)
        elif isinstance(obj, list):
            for item in obj:
                traverse(item)

    traverse(fragment_dict)
    return basenames


def check_settings_json(repo_root: str) -> tuple[list[str], list[str]]:
    """Check settings.json hook references. Returns (invalid, missing)."""
    settings_path = os.path.join(repo_root, "settings.json")

    if not os.path.exists(settings_path):
        print(
            f"WARNING: {settings_path} not found. Skipping settings.json orphan check.",
            file=sys.stderr,
        )
        return [], []

    try:
        with open(settings_path, "r") as f:
            settings = json.load(f)
    except json.JSONDecodeError as e:
        print(
            f"ERROR [lint-orphan-scripts]: Failed to parse settings.json: {e}",
            file=sys.stderr,
        )
        return [], ["<parse error>"]

    referenced_scripts = extract_script_paths(settings)

    invalid: list[str] = []
    missing: list[str] = []
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

    return invalid, missing


def check_fragments(repo_root: str) -> list[str]:
    """Check managed-settings.d fragment hook references. Returns missing basenames."""
    fragment_glob = os.path.join(repo_root, "managed-settings.d", "*.json")
    fragments = sorted(glob.glob(fragment_glob))

    if not fragments:
        return []

    # Collect (basename, source_fragment_path) pairs for clear error messages
    missing_with_source: list[str] = []

    for frag_path in fragments:
        try:
            with open(frag_path, "r") as f:
                frag = json.load(f)
        except json.JSONDecodeError as e:
            print(
                f"ERROR [lint-orphan-scripts]: Failed to parse {frag_path}: {e}",
                file=sys.stderr,
            )
            missing_with_source.append(f"<parse error in {os.path.basename(frag_path)}>")
            continue

        basenames = extract_fragment_script_basenames(frag)
        for name in sorted(basenames):
            full_path = os.path.join(repo_root, "scripts", name)
            if not os.path.exists(full_path):
                rel_frag = os.path.relpath(frag_path, repo_root)
                missing_with_source.append(f"{name}  (referenced in {rel_frag})")

    return missing_with_source


def main() -> int:
    repo_root = get_repo_root()

    # --- settings.json check ---
    invalid, missing_settings = check_settings_json(repo_root)

    if invalid:
        print(
            f"ERROR [lint-orphan-scripts]: {len(invalid)} absolute path reference(s) in "
            f"settings.json hooks (must be repo-relative or ~/.claude/scripts/):",
            file=sys.stderr,
        )
        for script in invalid:
            print(f"  - {script}", file=sys.stderr)

    if missing_settings:
        print(
            f"ERROR [lint-orphan-scripts]: {len(missing_settings)} referenced script(s) "
            f"missing from repo (settings.json):",
            file=sys.stderr,
        )
        for script in missing_settings:
            print(f"  - {script}", file=sys.stderr)

    # --- managed-settings.d fragments check ---
    missing_fragments = check_fragments(repo_root)

    if missing_fragments:
        print(
            f"ERROR [lint-orphan-scripts]: {len(missing_fragments)} referenced script(s) "
            f"missing from repo (managed-settings.d fragments):",
            file=sys.stderr,
        )
        for entry in missing_fragments:
            print(f"  - {entry}", file=sys.stderr)

    if invalid or missing_settings or missing_fragments:
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
