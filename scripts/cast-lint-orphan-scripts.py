#!/usr/bin/env python3
"""
CAST Orphan Script Detector

Two passes:

FORWARD PASS — Fails (exit 1) if any script *referenced* in hook config is
missing from scripts/:
  1. settings.json       — repo-relative commands (``bash scripts/...``) and
                           tilde-prefixed installs (``bash ~/.claude/scripts/...``)
  2. managed-settings.d/*.json fragments — installed config; fragment commands
                           legitimately reference ``$HOME/.claude/scripts/...`` or
                           ``~/.claude/scripts/...`` because the merged settings are
                           installed into ~/.claude. For existence checks the lint maps
                           referenced script *basenames* back to repo scripts/ — same
                           hermetic invariant as settings.json tilde paths.

REVERSE PASS — Warns (exit 0) if any script in scripts/ is not referenced
anywhere in the reachability set.  A WARNING does not block commits; it helps
developers notice scripts that were added but never wired.

Reachability set (surfaces searched for each script basename):
  - settings.json, managed-settings.d/*.json
  - bin/cast, install.sh
  - .githooks/*, .github/workflows/*
  - agents/**, macos/*.plist, completions/*, skills/**
  - scripts/* (scripts calling scripts)
  - tests/**, plugin/**, config/**, docs/**

Self-references (a script's own content) are excluded from the check so that
a script that only mentions its own name in comments/shebang is still flagged.

A FULL-LINE comment (first non-whitespace char is '#') in a .sh/.py/.bash
surface does not count as a real caller — see _strip_full_line_comments.
A TRAILING comment (``foo  # see cast-x.sh``) still counts as a caller;
telling it apart from a real invocation needs lexing, which this lint
deliberately does not attempt (see J-10 / v10 SEC-1 lesson). A script whose
only reference(s) are full-line comments is reported separately (see
comment_only_refs in check_orphan_scripts) rather than silently passing.

Hermeticity rule: this script MUST read only repo files, never the live
~/.claude install. Every path resolution bottoms out at repo_root/scripts/<name>.
Absolute paths (``/usr/...``) are treated as contract violations in settings.json.
In fragments they are simply not matched (fragment paths are always tilde or
HOME-env forms).

Exit codes:
  0 — all referenced scripts exist in repo; orphan warnings are printed but
      do NOT change the exit code
  1 — one or more referenced scripts are missing (forward-pass violation)
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


# ---------------------------------------------------------------------------
# Reverse pass — orphan scripts (no caller found)
# ---------------------------------------------------------------------------

# Extensions where a leading '#' is unambiguously a comment marker.  Kept
# narrow on purpose: JSON surfaces (settings.json, managed-settings.d/*.json)
# have no comment syntax at all, so stripping '#'-leading lines there would
# corrupt matching against real JSON content. YAML/.plist/Makefile also use
# '#' for comments but are deliberately NOT included here -- extending this
# set is a separate, explicitly-scoped follow-up, not part of this fix.
_COMMENT_STRIP_EXTENSIONS: set[str] = {".sh", ".py", ".bash"}


def _strip_full_line_comments(content: str) -> str:
    """Remove lines whose first non-whitespace character is '#'.

    Deliberately narrow: only a FULL-LINE comment (nothing but whitespace
    before the '#') is stripped. A TRAILING comment (``foo  # see x.sh``)
    is NOT stripped, because distinguishing a real trailing '#' from one
    inside a string literal requires actual shell/Python lexing -- v10
    SEC-1 removed exactly that kind of machinery (a heredoc detector, a
    quote-parity replacer, and a comment-dropper each proved unsafe) on the
    recorded lesson that comment-hood is decided word-wise during lexing,
    not by scanning characters. This function only ever handles the
    unambiguous case and does not claim to cover trailing comments.
    """
    kept_lines = [
        line for line in content.splitlines() if not line.lstrip().startswith("#")
    ]
    return "\n".join(kept_lines)

# Glob patterns (relative to repo_root) whose text content is searched
# for each script's basename.  Self-references are excluded per-script.
#
# Why include tests/, plugin/, config/, docs/:
#   cast-count-planned-tests.sh is only called from tests/run.sh;
#   cast-cron-setup.sh is only in config/upgrade-sources.json + docs/;
#   tidy.sh is only referenced in tests/install.bats + docs/.
#   Without these surfaces those three emit false positives.
_REVERSE_SURFACE_PATTERNS: list[str] = [
    "settings.json",
    "managed-settings.d/*.json",
    "bin/cast",
    "install.sh",
    ".githooks/*",
    ".github/workflows/*",
    "agents/**/*",
    "macos/*.plist",
    "completions/*",
    "skills/**/*",
    "scripts/*.sh",
    "scripts/*.py",
    "tests/**/*",
    "plugin/**/*",
    "config/**/*",
    "docs/**/*",
    "Makefile",
]


def _collect_surface_files(repo_root: str) -> list[str]:
    """Return the list of files in the reachability set (text files only)."""
    files: list[str] = []
    for pattern in _REVERSE_SURFACE_PATTERNS:
        full_pattern = os.path.join(repo_root, pattern)
        for path in glob.glob(full_pattern, recursive=True):
            if os.path.isfile(path):
                files.append(os.path.abspath(path))
    return files


def check_orphan_scripts(repo_root: str) -> tuple[list[str], list[str]]:
    """Return (orphans, comment_only_refs) for scripts/ with no real caller.

    Does NOT raise or exit — both lists are warnings only (see main()); the
    reverse pass has never affected the exit code and that is unchanged here.
    Self-references are excluded: if the only mention of 'foo.sh' is inside
    'foo.sh' itself, it is still flagged.

    A "real" caller excludes a FULL-LINE comment mention (first non-whitespace
    char is '#') in a .sh/.py/.bash surface — see _strip_full_line_comments
    for exactly what that does and does not cover. A script whose ONLY
    reference(s) are such comment lines is reported separately in
    comment_only_refs rather than silently passing as "has a caller".
    """
    script_pattern_sh = os.path.join(repo_root, "scripts", "*.sh")
    script_pattern_py = os.path.join(repo_root, "scripts", "*.py")
    all_script_paths: list[str] = sorted(
        glob.glob(script_pattern_sh) + glob.glob(script_pattern_py)
    )

    surface_files = _collect_surface_files(repo_root)
    # Pre-read surface file contents keyed by absolute path for speed
    surface_raw: dict[str, str] = {}
    for f in surface_files:
        try:
            with open(f, "r", errors="replace") as fh:
                surface_raw[f] = fh.read()
        except OSError:
            surface_raw[f] = ""

    # Content used to decide "real caller" — full-line comments stripped for
    # the narrow set of extensions where '#' is unambiguously a comment.
    surface_for_matching: dict[str, str] = {}
    for f, content in surface_raw.items():
        ext = os.path.splitext(f)[1]
        if ext in _COMMENT_STRIP_EXTENSIONS:
            surface_for_matching[f] = _strip_full_line_comments(content)
        else:
            surface_for_matching[f] = content

    orphans: list[str] = []
    comment_only_refs: list[str] = []
    for script_path in all_script_paths:
        basename = os.path.basename(script_path)
        abs_script = os.path.abspath(script_path)
        found_real = False
        for abs_surface, matching_content in surface_for_matching.items():
            if abs_surface == abs_script:
                continue  # skip self
            if basename in matching_content:
                found_real = True
                break

        if found_real:
            continue

        # No real caller found. Check whether the ONLY reference(s) are
        # inside full-line comments, so that case is visible rather than
        # silently indistinguishable from a genuine orphan.
        comment_hit: str | None = None
        for abs_surface, raw_content in surface_raw.items():
            if abs_surface == abs_script:
                continue
            ext = os.path.splitext(abs_surface)[1]
            if ext not in _COMMENT_STRIP_EXTENSIONS:
                continue
            for line_no, line in enumerate(raw_content.splitlines(), start=1):
                if line.lstrip().startswith("#") and basename in line:
                    rel = os.path.relpath(abs_surface, repo_root)
                    comment_hit = f"{basename}  ({rel}:{line_no})"
                    break
            if comment_hit:
                break

        if comment_hit:
            comment_only_refs.append(comment_hit)
        else:
            orphans.append(basename)

    return orphans, comment_only_refs


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

    # --- reverse pass: orphan scripts ---
    orphan_scripts, comment_only_refs = check_orphan_scripts(repo_root)

    if orphan_scripts:
        print(
            f"WARN [lint-orphan-scripts]: {len(orphan_scripts)} script(s) in scripts/ "
            f"not referenced anywhere in the reachability set (warning only — does not "
            f"block commit):",
            file=sys.stderr,
        )
        for name in orphan_scripts:
            print(f"  - scripts/{name}", file=sys.stderr)
        print(
            "  To suppress: wire the script into a caller, or add it to the "
            "documented allowlist in check_orphan_scripts() if it is a standalone tool.",
            file=sys.stderr,
        )

    if comment_only_refs:
        print(
            f"WARN [lint-orphan-scripts]: {len(comment_only_refs)} script(s) in scripts/ "
            f"referenced ONLY in comments (not a caller — warning only, does not block "
            f"commit):",
            file=sys.stderr,
        )
        for entry in comment_only_refs:
            print(f"  - {entry}", file=sys.stderr)
        print(
            "  A comment mention is not a real caller; wire the script into an actual "
            "invocation or treat it as orphaned.",
            file=sys.stderr,
        )

    if invalid or missing_settings or missing_fragments:
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
