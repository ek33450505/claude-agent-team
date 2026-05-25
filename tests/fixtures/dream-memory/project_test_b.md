---
name: project-test-b
description: Test project memory with stale path reference
type: project
verified_at: 2026-05-20
---
Project configuration lives at /Users/edkubiak/nonexistent_file.txt for historical reasons.

**Why:** Stale path references should be detected and flagged during consolidation.

**How to apply:** When running dream consolidation, lines containing paths that no longer exist are candidates for removal.
