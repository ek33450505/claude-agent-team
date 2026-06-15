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
| cast.db | `~/.claude/cast.db` | Via continuous replication (Litestream) + daily snapshots |

Secrets (API keys, `.env`, `.pem`, `.key` files) are explicitly excluded from both backups via basename pattern matching. The overlay script additionally runs a content-level secret scan (a grep-based denylist, plus gitleaks as an additive layer when installed) before pushing.

## Continuous replication (Litestream)

**What:** The `cast.db` SQLite database is continuously replicated to a replica directory outside the `~/.claude` blast radius, ensuring near-zero RPO (recovery point objective) even if `~/.claude` is wiped.

**Requirement:** Install Litestream via Homebrew:
```bash
brew tap benbjohnson/litestream && brew install litestream
```

Litestream is optional — `install.sh` registers the continuous replication daemon only when Litestream is detected as installed.

**Architecture:**
- **Daemon:** `com.cast.litestream` LaunchAgent runs continuously and replicates writes to `cast.db` to a file-replica (not a remote service).
- **Replica location:** `~/Library/Application Support/cast/litestream/cast-db/` (outside `~/.claude`, survives a wipe of that directory).
- **Config:** `~/Library/Application Support/cast/litestream.yml` (written once by setup, automatically loaded by the daemon).
- **Daemon logs:** `~/Library/Application Support/cast/logs/litestream.log` (survives a wipe).

**Setup:**

Idempotent setup that creates the replica directory and writes the config (the daemon itself is registered by `install.sh` when Litestream is present):
```bash
bash scripts/cast-litestream-setup.sh
```

The setup script respects two environment variable overrides (primarily for testing):
- `CAST_DB_PATH` — path to the source database (default: `~/.claude/cast.db`)
- `CAST_LITESTREAM_ROOT` — base directory for config and replica (default: `~/Library/Application Support/cast`)

If Litestream is not installed, the script exits gracefully with an advisory message (exit 0).

**Verify and restore:**

Before restoring from any backup, verify that the replica is restorable and intact:
```bash
bash scripts/cast-litestream-verify.sh
```

This script:
1. Checks that Litestream is installed and the config/replica exist
2. Restores to a temporary directory
3. Runs `PRAGMA integrity_check` on the restored database
4. Compares replica freshness vs. the live database (warns if older than 1 hour)
5. Prints a PASS/FAIL summary and exits 0 only if all checks pass

To manually restore from the Litestream replica to a new database file:
```bash
litestream restore -config ~/Library/Application\ Support/cast/litestream.yml -o <out.db> ~/.claude/cast.db
```

You can also restore to a specific point in time using the `-timestamp` flag:
```bash
litestream restore -config ~/Library/Application\ Support/cast/litestream.yml -timestamp 2026-06-12T14:30:00Z -o <out.db> ~/.claude/cast.db
```

**Health monitoring:**

`cast doctor` includes a Litestream replication freshness check that reports the status of the replica:
- **INFO** — Litestream not installed (opt-in tool, no alert needed)
- **WARN** — Litestream installed but daemon not loaded, replica missing, or replica is stale (>1 hour older than the live database)
- **OK** — Daemon is running and replica is current

**Relationship to other pillars:**

- **cast-snapshot.py (daily file snapshots):** Unchanged. Continues to take daily snapshots of `~/.claude/` contents (agent memories, rules, settings, etc.) as a file-based safety net.
- **cast-db-backup.py (daily database snapshots):** Now defaults to `~/Library/Application Support/cast/db-backups/` instead of the colocated `~/.claude/backups/` (which was destroyed by the 2026-06-11 wipe). Manual snapshots can still be triggered via `cast backup` (equivalent to `python3 scripts/cast-db-backup.py`).

## On-disk snapshots

**Location:** `~/Library/Application Support/cast/backups/cast-snapshot-YYYY-MM-DD/`

**Retention:** 7 daily snapshots + 4 weekly snapshots (ISO-week anchors)

**Schedule:** Daily at 02:30 via launchd (`com.cast.backup`)

**Override:** Set `CAST_BACKUP_ROOT` environment variable to use a different backup root directory.

## Off-machine overlay

**Repository:** your own private overlay repo, configured via `CAST_OVERLAY_REPO` or `~/.claude/config/cast-overlay-repo` (the URL is never hardcoded in this public repo)

**Script:** `scripts/cast-overlay-sync.sh`

Version-controlled working tree with full git history — not GitHub release assets. Copies the same files as the on-disk snapshot.

**Scheduling:** The daily `com.cast.backup` launchd job now runs both the on-disk snapshot AND a best-effort overlay push via `scripts/cast-backup-scheduled.sh`. This runs as the user (not as a Claude Code agent), so it has legitimate access to working `gh` and SSH authentication in the launchd environment.

**Caveat — authentication in launchd:** The overlay push requires working `gh` and `ssh` credentials in the launchd environment. If the scheduled push fails (e.g., due to auth timeouts or SSH key passphrases), it is logged as non-fatal — the on-disk snapshot still succeeds. To manually trigger the overlay push or verify that it succeeded, run `cast backup --overlay` from your terminal (where `gh` and `ssh` auth are fully configured). If the scheduled job hasn't pushed recently, run this command to catch up.

**Security note:** Claude Code agents are intentionally hard-blocked from pushing to the private overlay repo by the platform's data-exfiltration guard. The overlay push is always a user-initiated or user-scheduled action (via launchd as your user, not as an agent).

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

`~/.claude/backups/` (colocated database snapshots) — This directory was destroyed along with `~/.claude` during the 2026-06-11 wipe because it shared the same parent directory. The new backup architecture decouples database replication (Litestream → `~/Library/Application Support/cast/litestream/cast-db/`) and snapshots (cast-db-backup.py → `~/Library/Application Support/cast/db-backups/`) from the `~/.claude` directory, preventing single-point-of-failure wipes.
