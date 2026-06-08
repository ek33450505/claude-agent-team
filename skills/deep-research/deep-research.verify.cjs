// Standalone logic verifier for deep-research.workflow.js.
// The workflow is Workflow-DSL JS (can't run under BATS/node directly), so this stubs the DSL
// (agent/parallel/pipeline/phase/log) and exercises the correctness-critical paths.
//   Run:  node deep-research.verify.cjs [path-to-workflow.js]
// Guards the behaviors that matter for HONESTY:
//   - a vote that fails (rate-limit / no verdict) → ABSTAIN → claim `unverified`, NEVER `refuted`
//   - genuine 2/3 refutations still kill
//   - partial-abstention thresholds (2 valid → adjudicate; 1 valid → unverified)
//   - fetch's free-text→structure fallback still recovers sources (low-fan-out phase)
const fs = require('fs')
const path = require('path')
const PATH = process.argv[2] || path.join(__dirname, 'deep-research.workflow.js')
const body = fs.readFileSync(PATH, 'utf8').replace('export const meta', 'const meta')
// read the configured depth so assertions track the consts (dialed back over time)
const MVC = parseInt((body.match(/MAX_VERIFY_CLAIMS\s*=\s*(\d+)/) || [])[1] || '25', 10)

const parallel = (thunks) => Promise.all(thunks.map(async t => { try { return await t() } catch { return null } }))
const pipeline = (items, ...stages) => Promise.all(items.map(async (it, i) => {
  let cur = it
  for (const st of stages) { try { cur = await st(cur, it, i) } catch { return null } }
  return cur
}))
const phase = () => {}

function kindFromLabel(label) {
  if (label.startsWith('scope')) return 'scope'
  if (label.startsWith('search')) return 'search'
  if (label.startsWith('fetch')) return 'extract'
  if (/^v\d/.test(label)) return 'verdict'
  if (label.startsWith('synthesize')) return 'report'
  return 'unknown'
}
let uid = 0
function makeObj(kind, mode) {
  if (kind === 'scope') return { question: 'q', summary: 's', angles: [
    { label: 'a1', query: 'q1', rationale: 'r' }, { label: 'a2', query: 'q2' },
    { label: 'a3', query: 'q3' }, { label: 'a4', query: 'q4' }, { label: 'a5', query: 'q5' }] }
  if (kind === 'search') { const b = ++uid; return { results: [0,1,2].map(i => ({ url: 'https://ex' + b + '-' + i + '.com/p', title: 'T' + b + i, relevance: 'high' })) } }
  if (kind === 'extract') return { sourceQuality: 'primary', claims: [
    { claim: 'C' + (++uid), quote: 'Q', importance: 'central' }, { claim: 'C' + (++uid), quote: 'Q', importance: 'supporting' }] }
  if (kind === 'verdict') return { refuted: mode.refute === true, evidence: 'ev', confidence: 'high' }
  if (kind === 'report') return { summary: 'final', findings: [{ claim: 'F', confidence: 'high', sources: ['u'], evidence: 'e' }], caveats: 'c' }
  return {}
}
const makeRunner = (body) => new Function('agent', 'parallel', 'pipeline', 'log', 'phase', 'args',
  'return (async () => {\n' + body + '\n})()')

async function run(scenario) {
  uid = 0
  const logs = []
  const log = (m) => logs.push(m)
  const mode = scenario.mode
  const agent = async (prompt, opts = {}) => {
    const label = opts.label || ''
    const hasSchema = !!opts.schema
    const isStructure = label.endsWith('·structure')
    const isProse = label.endsWith('·prose')
    const kind = kindFromLabel(label)
    if (mode.shouldThrow && mode.shouldThrow({ label, hasSchema, isStructure, isProse, kind })) {
      throw new Error('agent({schema}): subagent completed without calling StructuredOutput (after 2 in-conversation nudges)')
    }
    if (!hasSchema) return 'PROSE result for ' + kind
    return makeObj(kind, mode)
  }
  const result = await makeRunner(body)(agent, parallel, pipeline, log, phase, scenario.args)
  return { result, logs }
}

let failures = 0
const check = (name, cond, detail) => {
  if (cond) console.log('  ✓ ' + name)
  else { console.log('  ✗ ' + name + (detail ? '  ── ' + detail : '')); failures++ }
}

;(async () => {
  console.log('MAX_VERIFY_CLAIMS = ' + MVC + ' (assertions track this)')

  { const { result } = await run({ args: undefined, mode: {} })
    console.log('[1] no-args guard')
    check('returns an error string', !!result.error) }

  { const { result } = await run({ args: 'q', mode: { refute: false, shouldThrow: () => false } })
    console.log('[2] happy path')
    check('confirmed === ' + MVC, result.stats.confirmed === MVC, 'got ' + result.stats.confirmed)
    check('killed === 0', result.stats.killed === 0)
    check('unverified === 0', result.stats.unverified === 0)
    check('fallbacksFired === 0 (nothing failed)', result.stats.fallbacksFired === 0, 'got ' + result.stats.fallbacksFired)
    check('findings present', Array.isArray(result.findings) && result.findings.length > 0) }

  { const { result } = await run({ args: 'q', mode: { refute: true, shouldThrow: () => false } })
    console.log('[3] genuine refutation')
    check('killed === ' + MVC, result.stats.killed === MVC, 'got ' + result.stats.killed)
    check('confirmed === 0', result.stats.confirmed === 0)
    check('summary says refuted/inconclusive', /refuted by adversarial verification/.test(result.summary))
    check('refuted list has ' + MVC, (result.refuted || []).length === MVC) }

  { const { result } = await run({ args: 'q', mode: { shouldThrow: ({ kind, hasSchema }) => kind === 'verdict' && hasSchema } })
    console.log('[4] verifier 100% failure (rate-limit / the original bug)')
    check('confirmed === 0', result.stats.confirmed === 0)
    check('killed === 0 (NOT mislabeled refuted)', result.stats.killed === 0, 'got ' + result.stats.killed)
    check('unverified === ' + MVC, result.stats.unverified === MVC, 'got ' + result.stats.unverified)
    check('refuted list empty', (result.refuted || []).length === 0)
    check('unverified claims surfaced w/ sources', (result.unverified || []).length === MVC && !!result.unverified[0].source)
    check('summary = "Verification did not complete" (not "refuted")',
      /Verification did not complete/.test(result.summary) && !/refuted by adversarial/.test(result.summary), result.summary.slice(0, 90))
    check('verify did NOT use the amplifying fallback (fallbacksFired 0)', result.stats.fallbacksFired === 0, 'got ' + result.stats.fallbacksFired) }

  { const { result } = await run({ args: 'q', mode: { refute: false, shouldThrow: ({ kind, label }) => kind === 'verdict' && label.startsWith('v2') } })
    console.log('[5] partial abstention (1 abstain, 2 valid non-refute → confirmed)')
    check('confirmed === ' + MVC, result.stats.confirmed === MVC, 'got ' + result.stats.confirmed)
    check('unverified === 0', result.stats.unverified === 0, 'got ' + result.stats.unverified) }

  { const { result } = await run({ args: 'q', mode: { refute: false, shouldThrow: ({ kind, label }) => kind === 'verdict' && (label.startsWith('v1') || label.startsWith('v2')) } })
    console.log('[6] insufficient votes (only 1 valid → unverified, cannot adjudicate)')
    check('unverified === ' + MVC, result.stats.unverified === MVC, 'got ' + result.stats.unverified)
    check('confirmed === 0', result.stats.confirmed === 0)
    check('killed === 0', result.stats.killed === 0) }

  { const { result } = await run({ args: 'q', mode: { refute: false, shouldThrow: ({ kind, hasSchema, isStructure }) => kind === 'extract' && hasSchema && !isStructure } })
    console.log('[7] fetch fallback recovers sources (low-fan-out phase keeps the fallback)')
    const srcs = result.sources || []
    check('fetch fallback fired', result.stats.fallbacksFired > 0, 'got ' + result.stats.fallbacksFired)
    check('all fired fetches recovered', result.stats.fallbackRecovered === result.stats.fallbacksFired, result.stats.fallbackRecovered + '/' + result.stats.fallbacksFired)
    check('all sources have claims (none dropped)', srcs.length > 0 && srcs.every(s => s.claimCount > 0))
    check('verify still confirmed (extract-only failure)', result.stats.confirmed === MVC, 'got ' + result.stats.confirmed) }

  console.log('\n' + (failures === 0 ? 'ALL CHECKS PASSED' : failures + ' CHECK(S) FAILED'))
  process.exit(failures === 0 ? 0 : 1)
})().catch(e => { console.error('HARNESS ERROR:', e.stack || e.message); process.exit(2) })
