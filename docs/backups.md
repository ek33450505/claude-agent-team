# CAST Backups

## What is backed up

| Category | Files | Destination |
|---|---|---|
| Agent memories | `~/.claude/agent-memory-local/**/*.md` | On-disk snapshot + overlay |
| Auto-memories | `~/.claude/projects/*/memory/*.md` | On-disk snapshot + overlay |
| Rules | `~/.claude/rules/*.md` | On-disk snapshot + overlay |
| CLAUDE.md | `~/.claude/CLAUDE.md` | On-disk snapshot + overlay |
| settings.local.json | `~/.claude/settings.local.json` | On-disk snapshot + overlay |
| PII denylist | `~/.claude/config/pii-denylist-local.txt` | On-disk snapshot + overlay |
| Personal agents | `~/.claude/agents/personal/*.md` | On-disk snapshot + overlay |
| Sync metadata | `~/.claude/config/sync.json` | On-disk snapshot + overlay |
| cast.db | `~/.claude/cast.db` | Via `cast-db-backup.py` (WAL-safe) |

Secrets (API keys, `.env`, `.pem`, `.key` files) are explicitly excluded from both backups via basename pattern matching. The overlay script additionally runs a content-level secret scan using gitleaks before pushing.

## On-disk snapshots

**Location:** `~/Library/Application Support/cast/backups/cast-snapshot-YYYY-MM-DD/`

**Retention:** 7 daily snapshots + 4 weekly snapshots (ISO-week anchors)

**Schedule:** Daily at 02:30 via launchd (`com.cast.backup`)

**Override:** Set `CAST_BACKUP_ROOT` environment variable to use a different backup root directory.

## Off-machine overlay

**Repository:** `ek33450505/cast-private` (private GitHub repo)

**Script:** `scripts/cast-overlay-sync.sh`

Version-controlled working tree with full git history — not GitHub release assets. Copies the same files as the on-disk snapshot.

**Note:** The overlay is not auto-scheduled by launchd (it requires working `gh` and SSH authentication, which a background job may lack). Run manually via `cast backup --overlay` or set `CAST_OVERLAY_SYNC=1`.

## Running a backup manually

```bash
# On-disk snapshot only
cast backup

# On-disk snapshot + push to GitHub overlay repo
cast backup --overlay
```

## Restore procedure

**List available snapshots:**
```bash
ls ~/Library/Application\ Support/cast/backups/
```

**Restore a snapshot:**
```bash
python3 scripts/cast-snapshot.py restore 2026-06-02 --target ~/.claude
```

**Restore to a temporary directory first to inspect:**
```bash
python3 scripts/cast-snapshot.py restore 2026-06-02 --target /tmp/cast-restore
ls /tmp/cast-restore
```

By default, `restore` refuses to overwrite existing files. Use `--force` to overwrite:
```bash
python3 scripts/cast-snapshot.py restore 2026-06-02 --target ~/.claude --force
```

## Monitoring

`cast doctor` includes a Backups freshness check that reports the age of the newest snapshot.

**Warning:** Fires if the newest snapshot is older than 48 hours (default).

**Override the threshold:**
```bash
CAST_BACKUP_MAX_AGE_HOURS=72 cast doctor
```

## What was retired

`scripts/cast-memory-backup.sh` — tarred daily output to `/tmp` and pushed release assets to GitHub (not version-controlled). Replaced by this system in §3.9 (2026-06-02).
