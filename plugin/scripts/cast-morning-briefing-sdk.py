#!/usr/bin/env python3
"""
CAST Agent SDK Reference Implementation
----------------------------------------
Demonstrates how to drive a CAST agent (morning-briefing) programmatically
using the Claude Code CLI as a subprocess. This is the recommended approach
for triggering CAST agents from external scripts, cron jobs, or CI pipelines.

Usage:
    python3 cast-morning-briefing-sdk.py
    python3 cast-morning-briefing-sdk.py --date 2026-04-01
"""

import argparse
import subprocess
import sys
from datetime import date


def parse_args() -> argparse.Namespace:
    """Parse command-line arguments."""
    parser = argparse.ArgumentParser(
        description="Run the CAST morning-briefing agent via the Claude Code CLI.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument(
        "--date",
        default=str(date.today()),
        metavar="YYYY-MM-DD",
        help="Date to generate the briefing for (default: today).",
    )
    return parser.parse_args()


def build_prompt(briefing_date: str) -> str:
    """Build the agent prompt for the given date."""
    return (
        f"Generate morning briefing for {briefing_date}. "
        f"Focus on git activity and any pending tasks."
    )


def run_morning_briefing(briefing_date: str) -> int:
    """
    Invoke the morning-briefing agent via the Claude Code CLI.

    Returns the subprocess exit code (0 = success).
    """
    prompt = build_prompt(briefing_date)

    cmd = [
        "claude",
        "--agent", "morning-briefing",
        "--output-format", "stream-json",
        "--print",
        prompt,
    ]

    try:
        result = subprocess.run(
            cmd,
            check=True,
            text=True,
        )
        return result.returncode
    except subprocess.CalledProcessError as exc:
        print(
            f"Error: morning-briefing agent exited with code {exc.returncode}",
            file=sys.stderr,
        )
        if exc.stderr:
            print(exc.stderr, file=sys.stderr)
        return exc.returncode
    except FileNotFoundError:
        print(
            "Error: 'claude' CLI not found. Install Claude Code and ensure it is in PATH.",
            file=sys.stderr,
        )
        return 1


if __name__ == "__main__":
    args = parse_args()
    sys.exit(run_morning_briefing(args.date))
