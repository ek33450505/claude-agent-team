Use the `verifier` agent to check implementation completeness before the quality gate runs.

$ARGUMENTS

The verifier will:
1. Run build checks (npm build, tsc --noEmit)
2. Scan for TODO/FIXME/placeholder strings in modified files
3. Verify referenced files and functions exist
4. Return PASS (ready for code-reviewer) or FAIL (specific issues to fix first)
