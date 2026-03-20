Review code changes with size-appropriate strategy.

$ARGUMENTS

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
| `qa-reviewer` | Functional correctness, edge cases, regression risk |

After all three complete, synthesize findings:
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
