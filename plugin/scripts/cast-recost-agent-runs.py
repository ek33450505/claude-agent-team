#!/usr/bin/env python3
"""cast-recost-agent-runs.py — recompute agent_runs.cost_usd from corrected model rates.

WHY THIS EXISTS
---------------
config/model-pricing.json drifted from Anthropic's published rates (corrected 2026-09-01,
commit fc7f6fa). Every cost recorded before that correction used a wrong rate:

    claude-opus-5              absent from the table -> priced at _default $3/$15; real $5/$25
    claude-opus-4-8            $15/$75  -> real $5/$25          (3.0x OVERSTATED)
    claude-haiku-4-5-20251001  $0.80/$4 (Haiku 3.5's price) -> real $1/$5
    claude-fable-5             absent -> _default; real $10/$50

agent_runs.cost_usd is read by the statusline, the budget gates, `bin/cast cost`,
`just -g cost` and the dashboard, so the error propagates everywhere. The token columns on
each row are correct — only the rates applied to them were wrong — so cost can be recomputed
in place from data already in the row.

DESTRUCTIVE. Mirrors cast-db-prune.py's fail-closed gate: --apply refuses to run without a
successful cast-db-backup.py first. Default is a dry run that writes nothing.

WHAT IT WILL NOT DO
-------------------
  * rows with NULL model            -> skipped (cannot price what we cannot identify)
  * rows with NULL input AND output -> skipped (nothing to recompute from; cost stays NULL)
  * agent_runs_daily               -> NOT touched. Re-run cast-db-rollup.py afterwards; it
                                      rewrites authoritative days and monotonically merges
                                      older ones, so the rollup converges on its own.

Cache rates are derived the same way cast_subagent_stop.py derives them (1.25x write,
0.1x read of base input) so a recomputed row is identical to a freshly recorded one.

ONE DELIBERATE DIVERGENCE. This script applies the real 0.025x cache-read rate for
claude-fable-5-1 / claude-mythos-5-1; the hook still flat-rates every model at 0.1x (a known
gap recorded in config/model-pricing.json's _note). Both models have ZERO rows today, so the
divergence is inert. If either starts accruing rows before the hook is fixed, this script
would price history correctly while the hook keeps overstating new rows 4x — fix the hook
first in that case, rather than removing the override here.

Usage:
  scripts/cast-recost-agent-runs.py               # dry run: report only, writes nothing
  scripts/cast-recost-agent-runs.py --apply       # backup, then rewrite cost_usd
  scripts/cast-recost-agent-runs.py --json        # machine-readable report

Exit: 0 on success or dry-run; 1 on backup failure, bad config, or DB error.
"""
import argparse
import json
import os
import sqlite3
import subprocess
import sys
from pathlib import Path

DB_PATH = Path(os.environ.get('CAST_DB_PATH', Path.home() / '.claude' / 'cast.db'))
PRICING_PATH = Path.home() / '.claude' / 'config' / 'model-pricing.json'
CACHE_WRITE_MULT = 1.25
CACHE_READ_MULT = 0.1
# Fable 5.1 / Mythos 5.1 read cache at 0.025x, not 0.1x.
CACHE_READ_OVERRIDES = {'claude-fable-5-1': 0.025, 'claude-mythos-5-1': 0.025}


def _log(msg: str) -> None:
    print(f'cast-recost: {msg}', file=sys.stderr)


def _load_rates() -> dict:
    if not PRICING_PATH.is_file():
        _log(f'ERROR: pricing config not found: {PRICING_PATH}')
        sys.exit(1)
    try:
        models = json.loads(PRICING_PATH.read_text())['models']
    except (json.JSONDecodeError, KeyError) as e:
        _log(f'ERROR: pricing config unreadable ({e})')
        sys.exit(1)
    if '_default' not in models:
        _log('ERROR: pricing config has no _default entry')
        sys.exit(1)
    return models


def _cost(rates: dict, model: str, tin: int, tout: int, cc: int, cr: int) -> float:
    entry = rates.get(model) or rates['_default']
    rin = entry['cost_per_million_input']
    rout = entry['cost_per_million_output']
    read_mult = CACHE_READ_OVERRIDES.get(model, CACHE_READ_MULT)
    return round(
        (tin * rin + tout * rout + cc * rin * CACHE_WRITE_MULT + cr * rin * read_mult) / 1_000_000, 6
    )


def _backup_gate() -> int:
    """Fail-closed: never rewrite a row without a successful backup first."""
    script = Path(__file__).resolve().parent / 'cast-db-backup.py'
    if not script.exists():
        _log(f'ERROR: backup script not found: {script} — refusing to write')
        return 1
    try:
        result = subprocess.run([sys.executable, str(script)], capture_output=True, text=True, timeout=120)
    except subprocess.TimeoutExpired:
        _log('ERROR: backup timed out after 120s — refusing to write')
        return 1
    except Exception as e:
        _log(f'ERROR: backup invocation failed: {e} — refusing to write')
        return 1
    if result.returncode != 0:
        _log(f'ERROR: backup exited {result.returncode} — refusing to write: {result.stdout.strip()[:300]}')
        return 1
    _log('backup OK')
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--apply', action='store_true', help='write the recomputed costs (requires a successful backup)')
    ap.add_argument('--json', action='store_true', help='emit a machine-readable report on stdout')
    args = ap.parse_args()

    if not DB_PATH.is_file():
        _log(f'ERROR: cast.db not found at {DB_PATH}')
        return 1

    rates = _load_rates()

    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    try:
        rows = conn.execute(
            'SELECT id, model, input_tokens, output_tokens, '
            '       cache_creation_input_tokens, cache_read_input_tokens, cost_usd '
            '  FROM agent_runs'
        ).fetchall()

        updates, skipped_no_model, skipped_no_tokens, unchanged = [], 0, 0, 0
        by_model: dict = {}
        for r in rows:
            model = r['model']
            if not model:
                skipped_no_model += 1
                continue
            tin = r['input_tokens'] or 0
            tout = r['output_tokens'] or 0
            cc = r['cache_creation_input_tokens'] or 0
            cr = r['cache_read_input_tokens'] or 0
            if tin == 0 and tout == 0 and cc == 0 and cr == 0:
                skipped_no_tokens += 1
                continue
            new = _cost(rates, model, tin, tout, cc, cr)
            old = r['cost_usd']
            if old is not None and abs(new - old) < 1e-9:
                unchanged += 1
                continue
            updates.append((new, r['id']))
            m = by_model.setdefault(model, {'rows': 0, 'old': 0.0, 'new': 0.0})
            m['rows'] += 1
            m['old'] += old or 0.0
            m['new'] += new

        report = {
            'db': str(DB_PATH),
            'applied': False,
            'rows_total': len(rows),
            'rows_to_update': len(updates),
            'rows_unchanged': unchanged,
            'skipped_no_model': skipped_no_model,
            'skipped_no_tokens': skipped_no_tokens,
            'by_model': {
                k: {'rows': v['rows'], 'old_usd': round(v['old'], 2), 'new_usd': round(v['new'], 2),
                    'delta_usd': round(v['new'] - v['old'], 2)}
                for k, v in sorted(by_model.items(), key=lambda kv: -abs(kv[1]['new'] - kv[1]['old']))
            },
            'total_old_usd': round(sum(v['old'] for v in by_model.values()), 2),
            'total_new_usd': round(sum(v['new'] for v in by_model.values()), 2),
        }

        if args.apply:
            if updates and _backup_gate() != 0:
                # Emit the report even on refusal: a caller piping --json should never get an
                # empty stdout, or it cannot distinguish "refused" from "crashed".
                report['error'] = 'backup gate failed — nothing was written'
                if args.json:
                    print(json.dumps(report, indent=2))
                return 1
            with conn:
                conn.executemany('UPDATE agent_runs SET cost_usd = ? WHERE id = ?', updates)
            report['applied'] = True
            _log(f'rewrote {len(updates)} rows; re-run cast-db-rollup.py to converge agent_runs_daily')
        else:
            _log(f'DRY RUN — {len(updates)} rows would change; pass --apply to write')
    finally:
        conn.close()

    if args.json:
        print(json.dumps(report, indent=2))
    else:
        print(f"{'model':<30}{'rows':>7}{'old $':>12}{'new $':>12}{'delta':>12}")
        print('-' * 73)
        for m, v in report['by_model'].items():
            print(f"{m:<30}{v['rows']:>7}{v['old_usd']:>12.2f}{v['new_usd']:>12.2f}{v['delta_usd']:>+12.2f}")
        print('-' * 73)
        print(f"{'TOTAL':<30}{report['rows_to_update']:>7}{report['total_old_usd']:>12.2f}"
              f"{report['total_new_usd']:>12.2f}{report['total_new_usd'] - report['total_old_usd']:>+12.2f}")
        print(f"\nskipped: {report['skipped_no_model']} rows with no model, "
              f"{report['skipped_no_tokens']} with no tokens; {report['rows_unchanged']} already correct")
    return 0


if __name__ == '__main__':
    sys.exit(main())
