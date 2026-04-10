#!/usr/bin/env python3
"""
cast-output-adapter.py — CAST multi-target output adapter for PA agents.
Writes markdown content to one of several output targets for hybrid local/remote execution.

Targets:
    obsidian  — Write to Obsidian vault (local only)
    repo      — Write to a file in the current repository (local + remote)
    stdout    — Print to stdout (for piping)

Usage:
    python3 cast-output-adapter.py --target obsidian --path 'Daily/2026-04-10.md' --content 'markdown'
    python3 cast-output-adapter.py --target repo --path 'reports/standup.md' --content 'markdown'
    python3 cast-output-adapter.py --target stdout --content 'markdown'

    # Content from stdin:
    echo "markdown" | python3 cast-output-adapter.py --target obsidian --path 'Daily/2026-04-10.md'

Environment:
    CAST_OUTPUT_TARGET      Override target (obsidian|repo|stdout)
    OBSIDIAN_VAULT_PATH     Path to Obsidian vault (default: ~/Library/Mobile Documents/iCloud~md~obsidian/Documents)
    CLAUDE_REMOTE           Set to 'true' when running on Anthropic infra — defaults to repo target
"""

import sys
import os
import argparse
import datetime
from pathlib import Path


# ---------------------------------------------------------------------------
# Target detection
# ---------------------------------------------------------------------------

def _auto_target() -> str:
    """Auto-detect output target based on environment."""
    env_target = os.environ.get('CAST_OUTPUT_TARGET', '')
    if env_target:
        return env_target
    # Running on Anthropic remote infrastructure
    if os.environ.get('CLAUDE_REMOTE', '').lower() in ('true', '1', 'yes'):
        return 'repo'
    return 'obsidian'


def _obsidian_vault() -> Path:
    """Resolve Obsidian vault path."""
    env = os.environ.get('OBSIDIAN_VAULT_PATH', '')
    if env:
        return Path(env)
    # macOS default iCloud location
    mac_icloud = Path.home() / 'Library' / 'Mobile Documents' / 'iCloud~md~obsidian' / 'Documents'
    if mac_icloud.exists():
        return mac_icloud
    # Fallback: ~/obsidian-vault
    return Path.home() / 'obsidian-vault'


# ---------------------------------------------------------------------------
# Writers
# ---------------------------------------------------------------------------

def write_obsidian(path: str, content: str) -> Path:
    """Write to Obsidian vault at the given relative path."""
    vault = _obsidian_vault()
    target = vault / path
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(content, encoding='utf-8')
    return target


def write_repo(path: str, content: str) -> Path:
    """Write to a path relative to the current working directory (repo root)."""
    target = Path(os.getcwd()) / path
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(content, encoding='utf-8')
    return target


def write_stdout(content: str) -> None:
    """Print content to stdout."""
    print(content)


# ---------------------------------------------------------------------------
# Public API (importable)
# ---------------------------------------------------------------------------

def write_output(
    content: str,
    path: str = '',
    target: str = '',
) -> str:
    """
    Write content to the specified (or auto-detected) target.

    Args:
        content: Markdown string to write
        path:    Relative file path (for obsidian/repo targets)
        target:  'obsidian' | 'repo' | 'stdout' (auto-detected if empty)

    Returns:
        Human-readable result string (path written to, or 'stdout')
    """
    if not target:
        target = _auto_target()

    if target == 'stdout':
        write_stdout(content)
        return 'stdout'
    elif target == 'obsidian':
        if not path:
            path = f"CAST/{datetime.date.today().isoformat()}.md"
        dest = write_obsidian(path, content)
        return str(dest)
    elif target == 'repo':
        if not path:
            path = f"reports/{datetime.date.today().isoformat()}.md"
        dest = write_repo(path, content)
        return str(dest)
    else:
        raise ValueError(f"Unknown target: {target!r}. Must be obsidian, repo, or stdout.")


# ---------------------------------------------------------------------------
# CLI entry point
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description='CAST output adapter — write markdown to obsidian, repo, or stdout'
    )
    parser.add_argument('--target', default='', help='obsidian | repo | stdout (auto-detected if omitted)')
    parser.add_argument('--path', default='', help='Relative file path for obsidian/repo targets')
    parser.add_argument('--content', default='', help='Markdown content to write (or read from stdin)')
    args = parser.parse_args()

    # Read content from arg or stdin
    content = args.content
    if not content and not sys.stdin.isatty():
        content = sys.stdin.read()

    if not content:
        print('Error: no content provided. Use --content or pipe via stdin.', file=sys.stderr)
        sys.exit(1)

    result = write_output(content=content, path=args.path, target=args.target)
    print(f"[cast-output-adapter] Written to: {result}", file=sys.stderr)


if __name__ == '__main__':
    main()
