Use the `orchestrator` agent to read a plan's Agent Dispatch Manifest and execute the agent queue.

$ARGUMENTS

The orchestrator will:
1. Find and read the specified plan file (or most recent plan if none specified)
2. Parse the Agent Dispatch Manifest
3. Show the full dispatch queue for approval
4. Execute batches in order — parallel agents simultaneously, sequential agents one at a time
5. Summarize what each agent did when complete
