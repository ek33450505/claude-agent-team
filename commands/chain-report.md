Use the `chain-reporter` agent to summarize a completed multi-agent chain.

$ARGUMENTS

The chain-reporter will:
1. Collect results from the agents that just ran
2. Produce a structured markdown summary of what each agent did
3. Save the report to `~/.claude/reports/chain-YYYY-MM-DD-HH-MM.md`
4. Return a concise summary to the main session
