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
// We ask for a JSON object as TEXT and parse it here rather than forcing a
// StructuredOutput schema: the nested decomposition shape proved too brittle for
// forced StructuredOutput (it retried to the cap with payloads missing `units`).
// Fence-strip + one stricter retry + normalization is far more robust here.
phase('Decompose')

function _extractJson(text) {
  if (!text || typeof text !== 'string') return null
  let s = text.trim()
  const fence = s.match(/```(?:json)?\s*([\s\S]*?)```/i)
  if (fence) s = fence[1].trim()
  if (s[0] !== '{') {
    const i = s.indexOf('{')
    const j = s.lastIndexOf('}')
    if (i >= 0 && j > i) s = s.slice(i, j + 1)
  }
  try { return JSON.parse(s) } catch (e) { return null }
}

function _normalizeUnits(p) {
  if (!p || !Array.isArray(p.units)) return null
  const out = p.units
    .filter(u => u && typeof u === 'object' && (u.title || u.instructions))
    .map((u, i) => ({
      id: Number.isInteger(u.id) ? u.id : i + 1,
      title: String(u.title || `unit ${i + 1}`),
      layer: String(u.layer || 'code'),
      files: Array.isArray(u.files) ? u.files : [],
      instructions: String(u.instructions || u.title || ''),
      needs_security: u.needs_security === true,
      depends_on: Array.isArray(u.depends_on) ? u.depends_on : [],
    }))
  return out.length ? out : null
}

const DECOMP_PROMPT =
  `You are a CAST planner performing a stack-ADAPTIVE app-build decomposition.\n` +
  `Feature request: "${desc}"\n` +
  `Target project root: ${projectRoot}\n\n` +
  `Read CLAUDE.md and the most relevant existing files (HARD cap: 8 reads) to detect the project's ACTUAL stack. ` +
  `It may be a CLI / bash / python project, a React + Express app, or something else — ADAPT to what you find; ` +
  `do NOT assume a frontend/API/migration shape.\n` +
  `Decompose the feature into the SMALLEST set of gated build units (typically 1-4), each ~15-30 min, in dependency order. ` +
  `YAGNI — only what the request literally needs; do not invent scope.\n\n` +
  `Output ONLY a single JSON object — no prose before or after (a \`\`\`json fence is allowed) — with EXACTLY this shape:\n` +
  `{"summary":"one line","stack":"detected stack","units":[{"id":1,"title":"short title",` +
  `"layer":"data|cli|api|frontend|test|docs","files":["path/to/file"],` +
  `"instructions":"concrete artifact-first steps a code-writer can start from immediately",` +
  `"needs_security":false,"depends_on":[]}]}\n` +
  `needs_security is true ONLY if the unit touches auth / user input / secrets / shell interpolation / enforcement / destructive ops.`

let raw = await agent(DECOMP_PROMPT, { label: 'decompose', phase: 'Decompose' })
let plan = _extractJson(raw)
let units = _normalizeUnits(plan)
if (!units) {
  log('decompose: first reply was not parseable JSON with units — retrying once (stricter)')
  raw = await agent(
    DECOMP_PROMPT + `\n\nYour previous reply could not be parsed as JSON. Reply with ONLY the JSON object, nothing else — no explanation.`,
    { label: 'decompose-retry', phase: 'Decompose' }
  )
  plan = _extractJson(raw)
  units = _normalizeUnits(plan)
}
if (!units) {
  log('cast-feature: decomposition did not yield parseable units — aborting (nothing built)')
  return { error: 'no-units', raw: (raw || '').slice(0, 500), units: [] }
}
const stack = (plan && plan.stack) ? String(plan.stack) : 'unknown'
log(`stack: ${stack} · ${units.length} unit(s): ${units.map(u => u.title).join(' | ')}`)

// ── Phase 2: Build each unit through the gated pipeline ───────────────────────
phase('Build')
const BLOCKER_RE = /^\s*BLOCKER\b/m
const results = []

for (const unit of units) {
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
log(`cast feature: ${done}/${units.length} unit(s) committed`)
return { desc, stack, summary: (plan && plan.summary) || '', units: results }
