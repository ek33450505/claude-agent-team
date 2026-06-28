# Provenance Chain — `cast verify-chain`

**Status:** Shipped in CAST v9 A7

## What It Is

A tamper-evident hash-chain over the per-session A5 ledger digests. Each session's A5 digest is captured at session-end and linked into an append-only chain (session N references the digest of N-1), so the entire work history is verifiable. Local-only — nothing leaves the machine. Builds directly on the A5 Session Ledger ([docs/v9-a5-session-ledger.md](v9-a5-session-ledger.md)). Tagline: "Trust your own receipts."

---

## Quick Start

### Basic Usage

```bash
# Verify the whole chain; prints VERIFY-CHAIN: PASS (N links) or VERIFY-CHAIN: BROKEN (...)
cast verify-chain

# Chain length, head hash, last session, pruned-attestation count
cast provenance status

# Chain all existing sessions not yet in the chain (idempotent; safe to re-run)
cast provenance backfill

# Same as cast verify-chain
cast provenance verify

# Append one session (normally automatic; see How It Works)
cast provenance append <session-id>

# All commands accept --db to target a specific cast.db
cast verify-chain --db ~/custom.db
cast provenance status --db ~/custom.db
```

### Exit Codes

| Command | Exit 0 (Pass) | Exit 1 (Fail) |
|---------|---------------|---------------|
| `cast verify-chain` | Chain valid | Chain broken or empty |
| `cast provenance verify` | Chain valid | Chain broken or empty |
| `cast provenance backfill` | Backfill succeeded | Backfill encountered error |
| `cast provenance append <id>` | Always 0 — **fail-open** (no-op if session missing) | Never (it runs inside session-end and must never break it) |

---

## How It Works

- A `SessionEnd` hook (`cast-session-end.sh`) calls `cast provenance append` for each session as it ends — **BEFORE any DB pruning** — so the digest is chained while the session row still exists. The call is fail-open: it can never break session recording.
- The chain is stored in the `provenance_chain` table in `~/.claude/cast.db` and is **NEVER pruned** (it stores each session's digest at append-time, so it survives the TTL-based pruning of the live `sessions` table).
- Chain computation: `chain_hash = sha256(prev_hash + session_digest)`, where `session_digest` is the A5 ledger digest and `prev_hash` is the previous row's `chain_hash` (empty string for the genesis row).

---

## Schema

The `provenance_chain` table holds the tamper-evident hash chain:

- **`seq`** — Autoincrement chain order, primary key
- **`session_id`** — Session being chained
- **`prev_hash`** — Prior row's `chain_hash`; empty string for genesis row
- **`session_digest`** — The A5 digest captured at append-time
- **`chain_hash`** — `sha256(prev_hash + session_digest)`
- **`created_at`** — Timestamp of append

A UNIQUE index on `session_id` makes append idempotent (a session is chained at most once).

The table is declared in `scripts/cast-db-init.sh` (the schema source of truth).

---

## Verification — Two Levels

### Level 1 — Chain Integrity (Always)

Recompute each row's `chain_hash` from the stored `prev_hash` + `session_digest` and check linkage (each row's `prev_hash` equals the prior row's `chain_hash`). Needs no live session data, so it works even for sessions that have since been pruned.

### Level 2 — Session Attestation (Where Data Exists)

For each session still present in `sessions`, re-derive its A5 digest from cast.db and compare to the stored `session_digest`. Sessions already pruned are skipped-with-note (reported as "pruned-skipped"), not failed.

### Empty-Chain Cross-Check

If the chain is empty but sessions exist, verify reports BROKEN (an emptied chain cannot silently pass).

---

## Trust Model

### Guarantees (Detected as BROKEN)

- Modification, insertion, deletion, or reordering of individual chain rows
- Modification of session data that's still present (Level 2)
- Emptying the chain while sessions exist

### Limitations (Local-Only, No External Anchor)

1. **Offline edit vulnerability:** An attacker with full read-write access to cast.db can edit a `session_digest` and recompute every subsequent `chain_hash` consistently — Level 1 then passes. Closing this requires an external anchor (publishing the head `chain_hash` to an append-only/remote/WORM store).

2. **Pruned session attestation gap:** Deleting a session row from `sessions` makes verify classify that link as "pruned" and skip Level 2 for it (the `chain_hash` still locks the stored digest, but it can no longer be independently re-derived). Pruning is by-design.

3. **Tail truncation undetected (mostly):** Removing the most recent links from `provenance_chain` leaves a valid prefix and is not detected beyond the empty-chain cross-check. The head hash changes, so downstream chain links (if any existed) would break — but a freshly-truncated chain has no downstream links to catch it.

---

## Related Docs

- [Session Ledger](v9-a5-session-ledger.md) — The per-session digest this builds on
- [Observability Guide](observability/OBSERVABILITY.md) — cast.db schema reference
- [Backups](backups.md) — Off-machine sync and secret scanning
