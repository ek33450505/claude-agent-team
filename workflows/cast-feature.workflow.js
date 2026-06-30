/**
 * cast-feature.workflow.js — CAST app-build engine (F3)
 *
 * This is a Claude Code **Workflow tool** script, NOT a Node module. It runs in the
 * Workflow interpreter (top-level `await`/`return` and the injected globals
 * `agent()`/`parallel()`/`pipeline()`/`phase()`/`log()`/`args`/`budget` are provided
 * by the harness — there is no filesystem or Node API access here). Do not `node`-run it.
 *
 * Invoked by `cast feature "<desc>"` / `/feature` via:
 *     Workflow({ scriptPath: "<repo>/workflows/cast-feature.workflow.js",
 *                args: { desc, project?, estimate? } })
 * The cost bookends (`cast predict` pre-flight, `cast cost` after) live OUTSIDE the
 * Workflow because scripts cannot shell out — the command surface runs them.
 *
 * Pipeline: Decompose (stack-adaptive) → Build loop, per unit:
 *   code-writer → code-reviewer (+ security when the unit warrants) → test-runner → commit.
 * Units build SEQUENTIALLY (they commonly share files → no parallel conflict). The two
 * reviewers may run in parallel; test-runner gets its OWN isolated stage and is NEVER
 * co-scheduled with a reviewer (its suite-timeout/kill path can reap siblings). Commits
 * go through the `commit` agent (ceremony preserved); the engine NEVER pushes.
 */

export const meta = {
  name: 'cast-feature',
  description: 'CAST app-build: decompose a feature into stack-adaptive gated units, build each through code-writer -> code-reviewer(+security) -> test-runner -> commit',
  phases: [
    { title: 'Decompose', detail: 'stack-adaptive decomposition into the smallest set of gated build units' },
    { title: 'Build', detail: 'per-unit code-writer -> code-reviewer(+security) -> isolated test-runner -> commit (no push)' },
  ],
}

// ── Inputs (args) ────────────────────────────────────────────────────────────
// { desc: string (required), project?: string, estimate?: string (from `cast predict`) }
const desc = (args && args.desc != null ? String(args.desc) : '').trim()
if (!desc) {
  log('cast-feature: args.desc is empty — nothing to build')
  return { error: 'no-desc', units: [] }
}
const projectRoot = (args && args.project) ? String(args.project) : 'the current working directory'
log(`cast feature: "${desc}"` + (args && args.estimate ? ` · pre-flight estimate: ${args.estimate}` : ''))

// ── Phase 1: Decompose (stack-ADAPTIVE) ──────────────────────────────────────
phase('Decompose')
const DECOMP_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['summary', 'stack', 'units'],
  properties: {
    summary: { type: 'string' },
    stack: { type: 'string' },
    units: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['id', 'title', 'layer', 'instructions', 'needs_security'],
        properties: {
          id: { type: 'integer' },
          title: { type: 'string' },
          layer: { type: 'string' },
          files: { type: 'array', items: { type: 'string' } },
          instructions: { type: 'string' },
          needs_security: { type: 'boolean' },
          depends_on: { type: 'array', items: { type: 'integer' } },
        },
      },
    },
  },
}

const plan = await agent(
  `You are a CAST planner performing a stack-ADAPTIVE app-build decomposition.\n` +
  `Feature request: "${desc}"\n` +
  `Target project root: ${projectRoot}\n\n` +
  `Read CLAUDE.md and the most relevant existing files (HARD cap: 8 reads) to detect the project's ACTUAL stack. ` +
  `It may be a CLI / bash / python project, a React + Express app, or something else — ADAPT to what you find; ` +
  `do NOT assume a frontend/API/migration shape.\n` +
  `Decompose the feature into the SMALLEST set of gated build units (typically 1-4), each ~15-30 min, in dependency order. ` +
  `For each unit provide: concrete file paths, artifact-first instructions a code-writer can begin from immediately, ` +
  `the layer (e.g. data, cli, api, frontend, test, docs), needs_security (true only if it touches auth / user input / ` +
  `secrets / shell interpolation / enforcement / destructive ops), and depends_on (ids of prerequisite units).\n` +
  `YAGNI — only what the request literally needs; do not invent scope. Return ONLY the structured object.`,
  { label: 'decompose', phase: 'Decompose', schema: DECOMP_SCHEMA }
)

if (!plan || !Array.isArray(plan.units) || plan.units.length === 0) {
  log('cast-feature: decomposition produced no units — aborting (nothing built)')
  return { error: 'no-units', plan: plan || null, units: [] }
}
log(`stack: ${plan.stack} · ${plan.units.length} unit(s): ${plan.units.map(u => u.title).join(' | ')}`)

// ── Phase 2: Build each unit through the gated pipeline ───────────────────────
phase('Build')
const BLOCKER_RE = /^\s*BLOCKER\b/m
const results = []

for (const unit of plan.units) {
  const tag = `u${unit.id} [${unit.layer}] ${unit.title}`
  log(`build ${tag}`)

  // Stage A — implement. Leaves changes in the working tree; does NOT commit/push.
  const writerOut = await agent(
    `Implement ONE CAST build unit. Parent feature: "${desc}".\n` +
    `Unit ${unit.id} — ${unit.title} (layer: ${unit.layer}).\n` +
    `Target files: ${JSON.stringify(unit.files || [])}\n` +
    `Instructions:\n${unit.instructions}\n\n` +
    `Follow project conventions (read CLAUDE.md / rules-core first). Add inline tests if you introduce logic. ` +
    `Artifact-first: write a skeleton of the deliverable in your first 1-2 tool calls, then refine. ` +
    `Do NOT git commit and do NOT push — a later stage commits. Leave your changes in the working tree.`,
    { label: `write:${unit.id}`, phase: 'Build', agentType: 'code-writer' }
  )
  if (writerOut === null) {
    log(`  ${tag}: code-writer died/skipped — stopping the build`)
    results.push({ unit, status: 'BLOCKED', reason: 'writer-null' })
    break
  }

  // Stage B — review. code-reviewer (+ security when needed) run in PARALLEL.
  // Free-text output; a blocking defect is signalled by a line starting with "BLOCKER".
  // (No schema here on purpose — agentType + StructuredOutput is fragile for code-reviewer.)
  const reviewThunks = [
    () => agent(
      `Code-quality review of the working-tree changes just made for CAST unit ${unit.id} (${unit.title}), ` +
      `feature "${desc}". Check correctness, edge cases, error handling, naming, and project conventions. ` +
      `If there is a BLOCKING defect, output a line beginning with the literal token "BLOCKER" followed by the issue. ` +
      `Otherwise state plainly that it is acceptable.`,
      { label: `review:${unit.id}`, phase: 'Build', agentType: 'code-reviewer' }
    ),
  ]
  if (unit.needs_security) {
    reviewThunks.push(() => agent(
      `Security review of the working-tree changes for CAST unit ${unit.id} (${unit.title}), feature "${desc}". ` +
      `Check injection, auth bypass, secret exposure, unsafe shell interpolation, path traversal, and any weakening ` +
      `of enforcement / §1 record-feeding hooks. If there is a BLOCKING issue, output a line beginning with the ` +
      `literal token "BLOCKER" followed by the issue. Otherwise state plainly that it is clean.`,
      { label: `security:${unit.id}`, phase: 'Build', agentType: 'security' }
    ))
  }
  const reviews = (await parallel(reviewThunks)).filter(Boolean)
  const blocked = reviews.some(r => BLOCKER_RE.test(String(r)))
  if (blocked) {
    log(`  ${tag}: BLOCKER raised in review — leaving changes UNCOMMITTED for a human, stopping the build`)
    results.push({ unit, status: 'BLOCKED', reason: 'review-blocker', reviews })
    break
  }

  // Stage C — test-runner in its OWN isolated stage (never parallel with a reviewer).
  const testOut = await agent(
    `Run the tests covering CAST unit ${unit.id} (${unit.title}). Scope to the changed files where possible ` +
    `(e.g. tests/run.sh --files <changed>); run the full suite only if scope cannot be determined — and NEVER run ` +
    `any destructive / real-HOME-touching test against the real HOME. Report pass/fail and the exit code plainly.`,
    { label: `test:${unit.id}`, phase: 'Build', agentType: 'test-runner' }
  )

  // Stage D — commit via the commit agent (ceremony preserved). NEVER pushes.
  const commitOut = await agent(
    `Stage and commit ONLY the working-tree changes for CAST unit ${unit.id} (${unit.title}) — part of feature ` +
    `"${desc}". Compose a semantic commit message. Do NOT push.`,
    { label: `commit:${unit.id}`, phase: 'Build', agentType: 'commit' }
  )
  results.push({ unit, status: 'DONE', test: testOut, commit: commitOut })
  log(`  ${tag}: committed`)
}

const done = results.filter(r => r.status === 'DONE').length
log(`cast feature: ${done}/${plan.units.length} unit(s) committed`)
return { desc, stack: plan.stack, summary: plan.summary, units: results }
