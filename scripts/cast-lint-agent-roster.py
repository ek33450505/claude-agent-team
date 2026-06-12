#!/usr/bin/env python3
"""
CAST Agent Roster Lint

Compares docs/agents/AGENT-ROSTER.md against agents/core/*.md to detect:
  (a) roster rows that have no corresponding def file
  (b) def files that do not appear in the roster
  (c) roster model != def frontmatter model

Model normalisation:
  Both surfaces already use the same short aliases ("haiku", "sonnet", "opus").
  No alias mapping is required. The roster table lists a bare word (e.g. "haiku");
  the def frontmatter uses "model: haiku". They are compared as-is (case-insensitive).

  If a future entry uses a full model ID (e.g. "claude-haiku-4.5"), this lint
  will surface it as a mismatch, which is the correct outcome — the two surfaces
  should stay in sync using the same convention.

Exit codes:
  0 — no discrepancies found
  1 — at least one discrepancy found

Env overrides (for testing):
  CAST_ROSTER_FILE  — path to AGENT-ROSTER.md (default: <repo-root>/docs/agents/AGENT-ROSTER.md)
  CAST_AGENTS_DIR   — path to agents/core/ directory (default: <repo-root>/agents/core)
"""

import os
import re
import sys
from pathlib import Path
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


def parse_roster(roster_path: str) -> Optional[dict[str, str]]:
    """
    Parse AGENT-ROSTER.md table rows.

    Expected format: | `agent-name` | model-word | ... |
    Returns {agent_name: model} or None if the file is missing.
    """
    if not os.path.exists(roster_path):
        print(f"ERROR [lint-agent-roster]: roster file not found: {roster_path}", file=sys.stderr)
        return None

    with open(roster_path, "r") as f:
        text = f.read()

    # Match rows: | `name` | model | rest... |
    rows = re.findall(r"\|\s*`([^`]+)`\s*\|\s*([a-z]+)\s*\|", text)
    if not rows:
        print(
            f"ERROR [lint-agent-roster]: no parseable table rows found in {roster_path}. "
            "Expected format: | `agent-name` | model | ... |",
            file=sys.stderr,
        )
        return None

    return {name.strip(): model.strip().lower() for name, model in rows}


def parse_def_model(def_path: str) -> Optional[str]:
    """
    Extract the `model:` value from a YAML frontmatter block in an agent def.
    Returns the model string (lowercase) or None if not found.
    """
    with open(def_path, "r") as f:
        content = f.read()

    # Frontmatter is between leading --- delimiters
    fm_match = re.match(r"^---\n(.*?)\n---", content, re.DOTALL)
    if not fm_match:
        return None

    fm_text = fm_match.group(1)
    model_match = re.search(r"^model:\s*(.+)$", fm_text, re.MULTILINE)
    if not model_match:
        return None

    return model_match.group(1).strip().lower()


def main() -> int:
    repo_root = get_repo_root()

    roster_file = os.environ.get(
        "CAST_ROSTER_FILE",
        os.path.join(repo_root, "docs", "agents", "AGENT-ROSTER.md"),
    )
    agents_dir = os.environ.get(
        "CAST_AGENTS_DIR",
        os.path.join(repo_root, "agents", "core"),
    )

    # --- Parse roster ---
    roster = parse_roster(roster_file)
    if roster is None:
        return 1

    # --- Parse def files ---
    if not os.path.isdir(agents_dir):
        print(f"ERROR [lint-agent-roster]: agents dir not found: {agents_dir}", file=sys.stderr)
        return 1

    def_files = {
        p.stem: p
        for p in sorted(Path(agents_dir).glob("*.md"))
        if p.is_file()
    }
    # {agent_name: Path}

    defs_models: dict[str, Optional[str]] = {}
    for name, path in def_files.items():
        defs_models[name] = parse_def_model(str(path))

    # --- Compare ---
    roster_names = set(roster.keys())
    def_names = set(def_files.keys())

    discrepancies: list[str] = []

    # (a) roster rows missing def files
    for name in sorted(roster_names - def_names):
        discrepancies.append(
            f"  roster-only (no def file):     {name}  (roster model: {roster[name]})"
        )

    # (b) def files not in roster
    for name in sorted(def_names - roster_names):
        discrepancies.append(
            f"  def-only (not in roster):      {name}"
        )

    # (c) model mismatch for agents present in both
    for name in sorted(roster_names & def_names):
        roster_model = roster[name]
        def_model = defs_models.get(name)
        if def_model is None:
            discrepancies.append(
                f"  model unreadable in def:       {name}  "
                f"(roster: {roster_model}, def: <no model: frontmatter>)"
            )
        elif roster_model != def_model:
            discrepancies.append(
                f"  model mismatch:                {name}  "
                f"(roster: {roster_model}, def: {def_model})"
            )

    if discrepancies:
        print(f"ERROR [lint-agent-roster]: {len(discrepancies)} discrepancy(ies) found:")
        for line in discrepancies:
            print(line)
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
