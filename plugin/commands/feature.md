---
description: CAST feature command
---

Run `cast predict "$ARGUMENTS"` for a pre-flight cost estimate, then invoke the Workflow tool to build the feature via the CAST app-build engine:

  Workflow({ scriptPath: "<repo>/workflows/cast-feature.workflow.js", args: { desc: "$ARGUMENTS", project: "<cwd>" } })

The engine decomposes the feature into gated units, running code-writer → code-reviewer (+security) → test-runner → commit per unit. It never pushes.

After it returns, run `cast cost --by-task --limit 1` to report actual spend for this run, then summarize the units built.
