# CI/Contributor Experience Audit — 2026-05-07

## Q1: README Badge Conflict

**Current behavior:**

The `.githooks/pre-commit` hook runs `make docs` (which calls `scripts/gen-stats.sh`) on every commit, re-counts agents/commands/skills/tests from tracked files, and auto-stages any changes to `README.md`. When a contributor's PR adds a new `.bats` file, this hook updates the test-count badge in `README.md` and stages it as part of the commit.

The `docs-check.yml` CI workflow (`readme-in-sync` job) independently runs `bash scripts/gen-stats.sh` in a clean checkout and then fails if `README.md` shows any diff. Because the PR branch contains the contributor's local test count (set at the time they committed), and the CI checkout sees the PR's _new_ `.bats` file as a tracked file (it is part of the PR checkout), the counts should technically match — but a conflict arises in practice when:

1. The contributor's pre-commit ran before `git add tests/new.bats` (the file wasn't tracked yet when the hook fired), so the staged README still has the old count.
2. The `readme-in-sync` job runs against a full checkout including the new `.bats` file and gets a higher count.

This produces a `readme-in-sync` failure on every PR that adds tests, because the badge was stamped with the pre-add count.

**Decision: Option (c) — update badge only on main via a post-merge job; gate the PR on test correctness, not badge correctness.**

Rationale: The badge is cosmetic metadata. Blocking a merge because badge numbers are stale (due to hook-timing edge cases) is noise that damages contributor trust. Moving the badge update to a push-to-main job eliminates the conflict entirely. The `readme-in-sync` job should verify _structural_ README correctness (required sections present, no broken links) rather than dynamic counts. The pre-commit hook already auto-stages the update, so the first commit after merge will have fresh numbers if the post-merge job doesn't fire fast enough — but that is acceptable for a badge.

**Implementation steps:**

1. In `docs-check.yml`, remove the `Regenerate README stats` step and the `Verify README is up to date` diff-check step entirely. Replace the job body with a lightweight structural check:
   ```yaml
   - name: Verify required README sections
     run: |
       for section in "## Installation" "## Agents" "## Hooks" "## Testing"; do
         grep -q "$section" README.md || { echo "Missing: $section"; exit 1; }
       done
   ```
2. Add a new workflow `readme-badge-sync.yml` triggered on `push` to `main` only:
   ```yaml
   name: Sync README Badges
   on:
     push:
       branches: [main]
   jobs:
     sync-badges:
       runs-on: ubuntu-latest
       permissions:
         contents: write
       steps:
         - uses: actions/checkout@v5
           with:
             token: ${{ secrets.GITHUB_TOKEN }}
         - name: Update badges
           run: bash scripts/gen-stats.sh
         - name: Commit if changed
           run: |
             git config user.name "github-actions[bot]"
             git config user.email "github-actions[bot]@users.noreply.github.com"
             git diff --quiet README.md || {
               git add README.md
               git commit -m "chore: sync README badges [skip ci]"
               git push
             }
   ```
3. Remove the README stats block from `.githooks/pre-commit` (the last `make docs` + `git add README.md` block), since badge updates will now happen post-merge. Keep all other lints intact.
4. Update `CONTRIBUTING.md` (or add a note to README) explaining that badge numbers self-update on merge to main.

---

## Q2: Fork PR CI Problem

**Current behavior:**

The `cast-pr-review.yml` workflow uses `${{ secrets.ANTHROPIC_API_KEY }}` via `anthropics/claude-code-action@v1`. On fork PRs, GitHub does not expose repository secrets to workflow runs triggered by the fork's `pull_request` event — this is a GitHub security boundary. The result: `cast-pr-review` always fails on fork PRs with an auth error (the action receives an empty API key). The `continue-on-error: true` flag suppresses the job-level failure, but the check still shows as a red X in the PR status checks list.

The BATS tests (`bats-ci.yml`) do not use secrets, so they run fine on fork PRs.

**Decision: Use the `workflow_run` trigger to safely run secret-consuming jobs after the fork's tests pass.**

The `workflow_run` trigger fires in the context of the base repo (not the fork), so secrets are accessible. This is the GitHub-recommended pattern for fork PR safety.

**Implementation steps:**

1. Split `cast-pr-review.yml` into two workflows:

   **`cast-pr-review-trigger.yml`** (runs on the fork's PR event, no secrets, just records the run):
   ```yaml
   name: CAST PR Review Trigger
   on:
     pull_request:
       types: [opened, synchronize]
   jobs:
     trigger:
       runs-on: ubuntu-latest
       steps:
         - run: echo "PR review trigger — waiting for BATS to pass"
   ```
   This workflow's only purpose is to create a named workflow run that `workflow_run` can listen to.

   **`cast-pr-review.yml`** (updated — triggered by workflow_run, runs with secrets):
   ```yaml
   name: CAST PR Review
   on:
     workflow_run:
       workflows: ["BATS Tests"]
       types: [completed]
   jobs:
     cast-review:
       if: ${{ github.event.workflow_run.conclusion == 'success' }}
       runs-on: ubuntu-latest
       continue-on-error: true
       permissions:
         contents: read
         pull-requests: write
         id-token: write
       steps:
         - uses: actions/checkout@v5
           with:
             ref: ${{ github.event.workflow_run.head_sha }}
         - uses: anthropics/claude-code-action@v1
           with:
             anthropic_api_key: ${{ secrets.ANTHROPIC_API_KEY }}
             prompt: |
               Review the changed files in this PR. Focus on:
               1. BATS test coverage for any new shell scripts
               2. Hook script defensive coding (empty input handling, exit codes)
               3. Agent frontmatter completeness (name, model, effort, memory fields)
               Post findings as a PR comment. Be specific — cite file:line.
   ```

2. Note: with `workflow_run`, the review job only fires after BATS passes. This is the correct ordering semantically (no point reviewing if tests fail).

3. The `workflow_run` approach means the review check appears as a separate workflow run linked to the PR, not a required status check inline in the PR. Update branch protection rules accordingly: keep `BATS Tests` as a required check; mark `CAST PR Review` as optional/informational.

---

## Q3: cast-review Red X on Every PR

**Current behavior:**

`cast-pr-review.yml` runs `anthropics/claude-code-action@v1` with `continue-on-error: true`. The job fails because:
- On fork PRs: `ANTHROPIC_API_KEY` is empty (secret not passed to fork workflows)
- On internal PRs: the action may fail for transient API errors, rate limits, or if the action version has bugs

The `continue-on-error: true` flag prevents the _job_ from blocking merge, but GitHub still shows the check as a red X in the PR status list. This creates noise for every contributor who sees "1 check failed" on an otherwise-green PR.

**Decision: Option (c) — convert to advisory-only by moving to `workflow_run` (as in Q2) AND removing it from required status checks.**

The Q2 fix addresses the fork-PR failure root cause. For the red-X appearance issue, the remaining fix is:

**Implementation steps:**

1. Apply the `workflow_run` change from Q2 — this eliminates the fork-PR auth failure.
2. In GitHub repo Settings > Branches > Branch protection rules for `main`, ensure `CAST PR Review` is NOT in the "Required status checks" list. Only `BATS Tests` and `readme-in-sync` (or its replacement from Q1) should be required.
3. Change `continue-on-error: true` to remain — this is correct behavior for an advisory check. The distinction is that after the Q2 change it won't fail due to missing secrets.
4. If the `anthropics/claude-code-action@v1` itself produces transient errors: pin to a specific SHA rather than `@v1` to prevent action version drift from introducing new failure modes:
   ```yaml
   - uses: anthropics/claude-code-action@<pinned-sha>
   ```
5. Add a `timeout-minutes: 5` to the cast-review job so a hung API call doesn't block the workflow indefinitely.

---

## Q4: macOS/Ubuntu Platform Divergence

**Current behavior:**

Three confirmed divergence incidents:
- `local` declarations outside function scope: valid syntax in bash 5.x (macOS Homebrew bash), fatal in bash 4.x (Ubuntu CI's system bash via `apt-get install bats`).
- `wc -l` whitespace: macOS `wc` pads output with leading spaces; Ubuntu does not. Scripts that compared `$(wc -l ...)` without `tr -d ' '` failed string comparisons on macOS but not Ubuntu (or vice versa).
- `*.py` not copied in CI: the CI setup step `cp scripts/*.sh ~/.claude/scripts/` missed Python files — hooks that called Python scripts silently no-oped on Ubuntu while passing locally on macOS.

The existing `bats-ci.yml` and `test-installer.yml` both run on `ubuntu-latest`, and `test-installer.yml` runs on `macos-latest` too. The gap is that local development happens on macOS (Homebrew bash 5.2+), while CI runs Ubuntu (bash 5.1 from apt, or older). Contributors can't easily reproduce the Ubuntu environment locally.

**Decision: Add a `make test-ubuntu` target that runs BATS inside a Docker Ubuntu container, mirroring the exact CI environment.**

**Implementation steps:**

1. Add a `Dockerfile.ci` to the repo root (for local use only — not for shipping):
   ```dockerfile
   FROM ubuntu:22.04
   RUN apt-get update && apt-get install -y \
       bash bats python3 jq sqlite3 git \
       && rm -rf /var/lib/apt/lists/*
   WORKDIR /repo
   ```

2. Add a `test-ubuntu` target to `Makefile`:
   ```makefile
   test-ubuntu:
   	@echo "Running BATS in Docker Ubuntu (mirrors CI)..."
   	docker build -f Dockerfile.ci -t cast-ci-ubuntu . --quiet
   	docker run --rm \
   	  -v "$(PWD):/repo" \
   	  -v "$(HOME)/.claude:/root/.claude" \
   	  cast-ci-ubuntu bash -c " \
   	    mkdir -p ~/.claude/scripts ~/.claude/logs ~/.claude/cast/events ~/.claude/agent-status && \
   	    cp /repo/scripts/*.sh ~/.claude/scripts/ && \
   	    cp /repo/scripts/*.py ~/.claude/scripts/ && \
   	    chmod +x ~/.claude/scripts/*.sh && \
   	    bats /repo/tests/*.bats /repo/tests/hooks/*.bats /repo/tests/agents/*.bats /repo/tests/scripts/*.bats --tap \
   	  "
   ```

3. Add a `scripts/pre-push-ubuntu-check.sh` that wraps the Docker invocation with a guard:
   ```bash
   #!/usr/bin/env bash
   # Pre-push check: run BATS in Ubuntu Docker before pushing
   # Wire with: git config core.hooksPath .githooks && add to .githooks/pre-push
   set -euo pipefail
   if ! command -v docker &>/dev/null; then
     echo "[CAST] Docker not found — skipping Ubuntu CI parity check. Install Docker to enable." >&2
     exit 0
   fi
   echo "[CAST] Running Ubuntu CI parity check via Docker..."
   make test-ubuntu
   ```

4. Add `.githooks/pre-push` wiring in the `Makefile hooks` target:
   ```makefile
   hooks:
   	git config core.hooksPath .githooks
   	chmod +x .githooks/pre-commit .githooks/pre-push
   	@echo "Pre-commit and pre-push hooks installed."
   ```
   And create `.githooks/pre-push`:
   ```bash
   #!/usr/bin/env bash
   bash "$(git rev-parse --show-toplevel)/scripts/pre-push-ubuntu-check.sh"
   ```

5. Document in `CONTRIBUTING.md`:
   > Run `make test-ubuntu` before opening a PR if you're on macOS. This catches bash 4/5 divergence, `wc` whitespace differences, and missing file copy issues that only surface on Ubuntu CI.

6. Add `Dockerfile.ci` to `.gitignore` if you don't want it shipped, or commit it. Committing is preferred — it documents the exact CI environment for contributors.

---

## Summary

| Question | Decision | Key Change |
|---|---|---|
| Q1: Badge conflict | Move badge update to post-merge push job | Remove `readme-in-sync` diff-check; add `readme-badge-sync.yml` |
| Q2: Fork PR secrets | `workflow_run` trigger for secret-consuming jobs | Rewrite `cast-pr-review.yml` to fire after BATS pass |
| Q3: Red X advisory | Remove from required checks + apply Q2 fix | Branch protection + pin action SHA + add timeout |
| Q4: macOS/Ubuntu parity | Docker-based `make test-ubuntu` pre-push | `Dockerfile.ci` + Makefile target + `.githooks/pre-push` |

## Sources

- `.github/workflows/bats-ci.yml` — verified, no secrets used
- `.github/workflows/cast-pr-review.yml` — verified, uses `ANTHROPIC_API_KEY` secret
- `.github/workflows/docs-check.yml` — verified, `readme-in-sync` job runs `gen-stats.sh` + diff check
- `.github/workflows/clean-install.yml` — verified, push/schedule only (no fork PR trigger)
- `.github/workflows/test-installer.yml` — verified, runs on ubuntu-latest + macos-latest
- `scripts/gen-stats.sh` — verified, uses `git ls-files` for counts
- `.githooks/pre-commit` — verified, auto-runs `make docs` and stages README.md changes
- `Makefile` — verified, `docs` target calls `gen-stats.sh`; `hooks` target wires `.githooks/`
- GitHub docs on workflow_run for fork safety: https://docs.github.com/en/actions/writing-workflows/choosing-when-your-workflow-runs/events-that-trigger-workflows#workflow_run [unverified — referenced from knowledge, not fetched this session]
