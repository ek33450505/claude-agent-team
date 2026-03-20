Evaluate and improve the quality of work using a generate-evaluate feedback loop.

$ARGUMENTS

## How This Works

This is the **Evaluator-Optimizer** pattern: generate output, evaluate it against criteria, feed back improvements.

### Step 1: Determine What to Evaluate

If the user specifies a target, use that. Otherwise, evaluate the most recent work:
- Check `git diff` for recent code changes
- Check the most recently modified files in the current project

### Step 2: Generate or Identify the Output

Identify or produce the artifact to evaluate:
- **Code:** The recently written/modified code
- **Query:** A BigQuery or SQLite query — dispatch to `data-scientist` if needed
- **Report:** A document or summary — dispatch to `report-writer` if needed
- **Plan:** An implementation plan — dispatch to `planner` if needed
- **Research:** A comparison or evaluation — dispatch to `researcher` if needed

### Step 3: Evaluate Against Criteria

Dispatch the appropriate reviewer agent based on artifact type:

| Artifact | Evaluator Agent | Criteria |
|----------|----------------|----------|
| Code | `code-reviewer` | Readability, security, duplication, error handling |
| Code (security-sensitive) | `security` | OWASP top 10, secrets, injection, XSS |
| Architecture/design | `architect` | Module boundaries, trade-offs, scalability |
| Tests | `qa-reviewer` | Coverage, edge cases, functional correctness |
| Documentation | `code-reviewer` | Accuracy, completeness, up-to-date |

### Step 4: Feedback Loop

1. Collect the evaluator's findings (Critical / Warning / Suggestion)
2. If **Critical issues** exist:
   - Apply the fixes directly (for code)
   - Or present revision suggestions (for docs/plans)
   - Re-evaluate after fixes — max 2 iterations to avoid loops
3. If only **Warnings/Suggestions**:
   - Present them to the user for decision
   - Do not auto-apply — these are judgment calls

### Step 5: Report

Summarize the evaluation:
```
## Eval Summary
- **Artifact:** [what was evaluated]
- **Evaluator:** [which agent reviewed]
- **Iterations:** [1-3]
- **Critical issues found:** [N] (all resolved / N remaining)
- **Warnings:** [N]
- **Suggestions:** [N]
```

## Examples

- `/eval` — evaluate the most recent code changes
- `/eval my BigQuery query` — evaluate a query for correctness and performance
- `/eval the research summary I just wrote` — evaluate a document for quality
- `/eval security` — run a security-focused evaluation on recent changes
