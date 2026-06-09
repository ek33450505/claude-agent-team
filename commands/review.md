Review code changes with size-appropriate strategy.

$ARGUMENTS

## PR Routing (check before scope sizing)

If `$ARGUMENTS` references a pull request (a PR number like #123, a PR URL, or an explicit request to review a whole PR end-to-end), dispatch the `pr-reviewer` agent (holistic: full multi-commit diff, commit-message coherence, scope creep, breaking-change surface) and SKIP the size-based buckets below.

## Step 1: Determine Scope

If no specific files are mentioned, run:
```bash
git diff --stat HEAD~1
```
Count the number of changed files.

## Step 2: Route by Size

### Small (1-3 files changed)
Dispatch to `code-reviewer` agent directly. Standard review — readability, error handling, security, duplication, conventions. Check for hardcoded secrets.

### Medium (4-10 files changed)
Dispatch to `code-reviewer` agent with explicit instruction to:
1. Read all changed files in parallel first
2. Cross-reference changes for consistency (naming, patterns, imports)
3. Check for breaking changes across file boundaries
4. Standard review checklist on each file

### Large (10+ files changed)
Dispatch **parallel specialized reviews** using agent teams:

| Agent | Focus Area |
|-------|-----------|
| `code-reviewer` | Readability, duplication, conventions |
| `security` | OWASP top 10, secrets, injection, XSS |
| `frontend-qa` | React/TS correctness, prop typing, a11y — ONLY if the diff contains .tsx/.ts files; skip otherwise |

Note: there is no general-purpose functional-QA agent for non-frontend code; for backend/shell, code-reviewer + security cover the large bucket.

After all complete, synthesize findings:
- Deduplicate overlapping issues
- Prioritize: Critical → Warning → Suggestion
- Present a unified review summary

## Step 3: Output Format

```markdown
## Review Summary
- **Scope:** [N files, M insertions, K deletions]
- **Strategy:** [Small/Medium/Large]
- **Reviewers:** [which agents ran]

### Critical (must fix)
- [issue + file:line + how to fix]

### Warnings (should fix)
- [issue + file:line + recommendation]

### Suggestions (consider)
- [improvement idea]
```
