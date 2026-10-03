#!/usr/bin/env bash
# cast-upgrade-check.sh — Fetch recent GitHub releases and score for CAST relevance
#
# Usage: bash scripts/cast-upgrade-check.sh
#
# Reads:   config/upgrade-sources.json  (list of repos to monitor)
# Reads:   ~/.claude/cast/last-checked-upgrades.json  (last check timestamp; init to epoch if missing)
# Writes:  ~/.claude/cast/upgrade-candidates.json     (idempotent findings keyed by {repo}-{tag}-{item_hash})
# Updates: ~/.claude/cast/last-checked-upgrades.json  (timestamp after successful run)
#
# On gh CLI failure: print warning and exit 0 (graceful skip)
# Idempotent: re-running for the same release produces no duplicate entries.

if [ "${CLAUDE_SUBPROCESS:-0}" = "1" ]; then exit 0; fi

set -euo pipefail

# ── Resolve paths ──────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SOURCES_FILE="${CAST_UPGRADE_SOURCES_FILE:-${REPO_ROOT}/config/upgrade-sources.json}"
SCORE_SCRIPT="${CAST_UPGRADE_SCORE_SCRIPT:-${SCRIPT_DIR}/cast-upgrade-score.sh}"
CAST_STATE_DIR="${CAST_STATE_DIR:-${HOME}/.claude/cast}"
LAST_CHECKED_FILE="${CAST_STATE_DIR}/last-checked-upgrades.json"
CANDIDATES_FILE="${CAST_STATE_DIR}/upgrade-candidates.json"

# ── Validate dependencies ──────────────────────────────────────────────────────
if ! command -v gh >/dev/null 2>&1; then
  printf "[cast-upgrade-check] Warning: gh CLI not found — skipping upgrade check.\n" >&2
  exit 0
fi

if ! command -v python3 >/dev/null 2>&1; then
  printf "[cast-upgrade-check] Warning: python3 not found — skipping upgrade check.\n" >&2
  exit 0
fi

if [ ! -f "$SOURCES_FILE" ]; then
  printf "[cast-upgrade-check] Warning: upgrade-sources.json not found at %s — skipping.\n" "$SOURCES_FILE" >&2
  exit 0
fi

if [ ! -f "$SCORE_SCRIPT" ]; then
  printf "[cast-upgrade-check] Warning: cast-upgrade-score.sh not found at %s — skipping.\n" "$SCORE_SCRIPT" >&2
  exit 0
fi

# ── Ensure state dir ───────────────────────────────────────────────────────────
mkdir -p "$CAST_STATE_DIR"

# ── Read last-checked timestamp (epoch 0 if file missing or malformed) ─────────
LAST_CHECKED_ISO="$(python3 -c "
import json, os, sys
f = sys.argv[1]
try:
    with open(f) as fh:
        d = json.load(fh)
    print(d.get('last_checked', '1970-01-01T00:00:00Z') or '1970-01-01T00:00:00Z')
except Exception:
    print('1970-01-01T00:00:00Z')
" "$LAST_CHECKED_FILE" 2>/dev/null || echo "1970-01-01T00:00:00Z")"

printf "[cast-upgrade-check] Last checked: %s\n" "$LAST_CHECKED_ISO"

# ── Read sources list ──────────────────────────────────────────────────────────
REPOS="$(python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
sources = d.get('sources', [])
for s in sources:
    repo = s.get('repo', '')
    if repo:
        print(repo)
" "$SOURCES_FILE" 2>/dev/null || echo "")"

if [ -z "$REPOS" ]; then
  printf "[cast-upgrade-check] No sources configured in upgrade-sources.json — nothing to check.\n"
  exit 0
fi

# ── Load existing candidates (for idempotent merge) ────────────────────────────
EXISTING_CANDIDATES="$(python3 -c "
import json, os, sys
f = sys.argv[1]
try:
    with open(f) as fh:
        d = json.load(fh)
    if isinstance(d, dict):
        print(json.dumps(d))
    else:
        print('{}')
except Exception:
    print('{}')
" "$CANDIDATES_FILE" 2>/dev/null || echo "{}")"

# ── Process each source repo ───────────────────────────────────────────────────
NEW_ENTRIES_JSON="{}"

while IFS= read -r REPO; do
  [ -z "$REPO" ] && continue
  printf "[cast-upgrade-check] Checking: %s\n" "$REPO"

  # Fetch recent releases — graceful skip on gh failure
  RELEASES_JSON="$(gh release list \
    --repo "$REPO" \
    --limit 10 \
    --json tagName,publishedAt 2>/dev/null || echo "[]")"

  if [ "$RELEASES_JSON" = "[]" ] || [ -z "$RELEASES_JSON" ]; then
    printf "[cast-upgrade-check] Warning: gh could not fetch releases for %s — skipping.\n" "$REPO" >&2
    continue
  fi

  # Find releases newer than last check; fetch notes and score each
  while IFS= read -r RELEASE_LINE; do
    # Single python3 call emits tab-separated fields to avoid two separate
    # cold-start invocations that each re-parse the same RELEASE_LINE.
    IFS=$'\t' read -r TAG PUBLISHED <<<"$(echo "$RELEASE_LINE" | python3 -c "
import sys, json
d = json.loads(sys.stdin.read())
def clean(v):
    return str(v).replace('\t', ' ').replace('\n', ' ') if v else ''
print(f\"{clean(d.get('tagName'))}\t{clean(d.get('publishedAt'))}\")
" 2>/dev/null || printf '\t')"

    [ -z "$TAG" ] && continue

    # TAG comes from untrusted GitHub release data and is passed to `gh release view`
    # as a positional arg: a leading "-" would be parsed as a gh flag (option injection).
    # Allow-list, not deny-list: bash ranges (A-Z) and classes ([:alnum:], [:cntrl:])
    # are locale-dependent, so under LC_ALL=C bidi overrides, CSI, NBSP etc. would slip
    # through a deny-list. The charset below is enumerated literally and covers
    # monorepo tags like @scope/pkg@1.2.3. Skip, don't sanitize.
    case "$TAG" in
      -* | *[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._+@/-]*)
        printf "[cast-upgrade-check] Warning: skipping release with unsafe tag name from %s.\n" "$REPO" >&2
        continue
        ;;
    esac

    # Compare timestamps: skip if published <= last_checked
    IS_NEW="$(python3 -c "
from datetime import datetime, timezone
import sys
def parse(s):
    s = s.strip()
    if not s:
        return datetime.min.replace(tzinfo=timezone.utc)
    for fmt in ['%Y-%m-%dT%H:%M:%SZ', '%Y-%m-%dT%H:%M:%S%z', '%Y-%m-%dT%H:%M:%S.%fZ']:
        try:
            dt = datetime.strptime(s, fmt)
            if dt.tzinfo is None:
                dt = dt.replace(tzinfo=timezone.utc)
            return dt
        except ValueError:
            continue
    return datetime.min.replace(tzinfo=timezone.utc)
pub = parse(sys.argv[1])
lkg = parse(sys.argv[2])
print('1' if pub > lkg else '0')
" "$PUBLISHED" "$LAST_CHECKED_ISO" 2>/dev/null || echo "0")"

    if [ "$IS_NEW" != "1" ]; then
      continue
    fi

    printf "[cast-upgrade-check] New release: %s@%s (%s)\n" "$REPO" "$TAG" "$PUBLISHED"

    # Fetch release notes
    # Note: BSD mktemp (macOS) does not support a suffix after XXXXXX — drop .txt
    # to avoid creating a literal "cast-upgrade-notes-XXXXXX.txt" file on macOS.
    NOTES_FILE="$(mktemp "${TMPDIR:-/tmp}/cast-upgrade-notes-XXXXXX")"
    # shellcheck disable=SC2064
    trap "rm -f '$NOTES_FILE'" EXIT

    FETCH_OK=0
    if gh release view "$TAG" --repo "$REPO" --json body -q '.body' > "$NOTES_FILE" 2>/dev/null; then
      FETCH_OK=1
    fi

    if [ "$FETCH_OK" -ne 1 ] || [ ! -s "$NOTES_FILE" ]; then
      printf "[cast-upgrade-check] Warning: could not fetch notes for %s@%s — skipping.\n" "$REPO" "$TAG" >&2
      rm -f "$NOTES_FILE"
      continue
    fi

    # Score the release notes
    # The scorer's stderr is NOT discarded: on a claude failure it prints exactly one
    # "[cast-upgrade-score] claude exited ..." line, which must stay visible.
    SCORED_ITEMS="$(bash "$SCORE_SCRIPT" "$REPO" "$TAG" "$NOTES_FILE" || echo "[]")"
    rm -f "$NOTES_FILE"

    if [ -z "$SCORED_ITEMS" ] || [ "$SCORED_ITEMS" = "[]" ]; then
      continue
    fi

    # Merge scored items into new_entries using idempotent key: {repo}-{tag}-{item_hash}
    # item_hash = first 8 chars of md5 of item description
    NEW_ENTRIES_JSON="$(python3 -c "
import json, hashlib, sys

repo = sys.argv[1]
tag = sys.argv[2]
published = sys.argv[3]
scored_raw = sys.argv[4]
existing_raw = sys.argv[5]

try:
    scored = json.loads(scored_raw)
except Exception:
    scored = []

try:
    entries = json.loads(existing_raw)
except Exception:
    entries = {}

for item in scored:
    desc = item.get('item', '')
    item_hash = hashlib.md5(desc.encode()).hexdigest()[:8]
    # Sanitize repo name for key (replace / with -)
    repo_key = repo.replace('/', '-')
    key = f'{repo_key}-{tag}-{item_hash}'
    if key not in entries:
        entries[key] = {
            'repo': repo,
            'tag': tag,
            'published_at': published,
            'item': desc,
            'category': item.get('category', 'SKIP'),
            'reason': item.get('reason', ''),
            'cast_component': item.get('cast_component', ''),
            'key': key
        }

print(json.dumps(entries))
" "$REPO" "$TAG" "$PUBLISHED" "$SCORED_ITEMS" "$NEW_ENTRIES_JSON" 2>/dev/null || echo "$NEW_ENTRIES_JSON")"

  done < <(python3 -c "
import json, sys
releases = json.loads(sys.argv[1])
for r in releases:
    print(json.dumps(r))
" "$RELEASES_JSON" 2>/dev/null)

done <<< "$REPOS"

# ── Merge new entries into existing candidates ─────────────────────────────────
MERGED_CANDIDATES="$(python3 -c "
import json, sys

existing_raw = sys.argv[1]
new_raw = sys.argv[2]

try:
    existing = json.loads(existing_raw)
except Exception:
    existing = {}

try:
    new_entries = json.loads(new_raw)
except Exception:
    new_entries = {}

# Merge: existing takes no precedence over new (idempotent keys prevent overwrites)
merged = {**existing, **new_entries}
print(json.dumps(merged, indent=2))
" "$EXISTING_CANDIDATES" "$NEW_ENTRIES_JSON" 2>/dev/null || echo "{}")"

printf "%s\n" "$MERGED_CANDIDATES" > "$CANDIDATES_FILE"

# ── Update last-checked timestamp ──────────────────────────────────────────────
NOW_ISO="$(python3 -c "
from datetime import datetime, timezone
print(datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'))
" 2>/dev/null || echo "")"

if [ -n "$NOW_ISO" ]; then
  python3 -c "
import json, os, sys
f = sys.argv[1]
try:
    with open(f) as fh:
        d = json.load(fh)
except Exception:
    d = {}
d['last_checked'] = sys.argv[2]
with open(f, 'w') as fh:
    json.dump(d, fh, indent=2)
" "$LAST_CHECKED_FILE" "$NOW_ISO" 2>/dev/null || true
fi

# ── Summary ────────────────────────────────────────────────────────────────────
# Single python3 call emits tab-separated TOTAL/CRITICAL to avoid two separate
# cold-start invocations that each re-read and re-parse CANDIDATES_FILE.
IFS=$'\t' read -r TOTAL CRITICAL <<<"$(python3 -c "
import json, sys
d = json.loads(open(sys.argv[1]).read())
total = len(d)
critical = sum(1 for v in d.values() if v.get('category') == 'CRITICAL')
print(f'{total}\t{critical}')
" "$CANDIDATES_FILE" 2>/dev/null || printf '0\t0')"

printf "[cast-upgrade-check] Done. Candidates: %s total, %s CRITICAL\n" "$TOTAL" "$CRITICAL"
if [ "$CRITICAL" -gt 0 ]; then
  printf "[cast-upgrade-check] Run: cast doctor  (to review critical items)\n"
fi
