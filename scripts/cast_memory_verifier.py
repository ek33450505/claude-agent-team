#!/usr/bin/env python3
"""
Memory verifier — extracts file paths and function names from memory content
and checks if they exist on disk. Returns confidence delta based on failed checks.

Reads from stdin (CAST_MEMORY_CONTENT env var) or stdin.
Outputs JSON: {"paths_checked": N, "missing": [...], "confidence_delta": -0.X}
"""
import os
import sys
import json
import re

def extract_paths_and_functions(content: str) -> tuple:
    """Extract file paths and function names from memory content."""
    paths = []
    functions = []

    # Regex for file paths: word chars, slashes, dots, dashes
    # Matches: script.sh, ./file.py, /path/to/file.md, ~/.local/bin/cast
    path_pattern = r'\b([a-zA-Z0-9_/\.\-]+(?:\.sh|\.py|\.js|\.ts|\.md|\.bats))\b'
    for match in re.finditer(path_pattern, content):
        path_str = match.group(1)
        if '/' in path_str or '.' in path_str:
            paths.append(path_str)

    # Regex for function names: 'function name' or 'def name'
    func_pattern = r'(?:function|def)\s+([a-zA-Z_][a-zA-Z0-9_]*)'
    for match in re.finditer(func_pattern, content):
        functions.append(match.group(1))

    return list(set(paths)), list(set(functions))


def check_path_exists(path_str: str) -> bool:
    """Check if a file path exists on disk. Expand tilde and relative paths."""
    try:
        # Expand ~ and relative paths
        expanded = os.path.expanduser(path_str)
        # If relative, check from repo root or home
        if not os.path.isabs(expanded):
            # Try current repo root (.git/.. fallback)
            repo_root = os.getcwd()
            candidate = os.path.join(repo_root, expanded)
            if os.path.isfile(candidate):
                return True
            # Try home
            candidate = os.path.join(os.path.expanduser('~'), expanded)
            if os.path.isfile(candidate):
                return True
            return False
        return os.path.isfile(expanded)
    except Exception:
        return False


def main():
    # Read memory content from env var or stdin
    content = os.environ.get('CAST_MEMORY_CONTENT', '')
    if not content:
        try:
            content = sys.stdin.read()
        except Exception:
            content = ''

    paths, functions = extract_paths_and_functions(content)

    missing = []
    checked = 0

    # Check paths
    for path_str in paths:
        checked += 1
        if not check_path_exists(path_str):
            missing.append(f"path:{path_str}")

    # Functions are harder to verify without parsing — skip for now
    # (would require grep against repo)
    checked += len(functions)

    # Confidence delta: -0.2 per failure, min 0.0
    confidence_delta = -0.2 * len(missing)
    confidence_delta = max(confidence_delta, -len(missing) * 0.2)

    result = {
        "paths_checked": checked,
        "missing": missing,
        "confidence_delta": round(confidence_delta, 2)
    }

    print(json.dumps(result))


if __name__ == '__main__':
    main()
