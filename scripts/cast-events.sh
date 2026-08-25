#!/bin/bash
# cast-events.sh — CAST Event-Sourcing Protocol
# Source this file to get: cast_emit_event, cast_write_review, cast_derive_state, cast_read_board
#
# Architecture: agents never share mutable state.
# Each agent writes its own immutable event file.
# State is derived from events by the orchestrator.
# Reviews are attached to specific artifact IDs, not global task state.
#
# Usage:
#   source ~/.claude/scripts/cast-events.sh
#   cast_emit_event "task_claimed"  "orchestrator" "batch-1" "" "Starting architecture review"
#   cast_write_review "batch-1-plan" "code-reviewer" "approved" "Looks good" ""
#   cast_derive_state "batch-1"
#   cast_read_board
#
# Directory layout (all under ~/.claude/cast/):
#   events/    — append-only, one JSON file per agent action: {timestamp}-{agent}-{task_id}.json
#   state/     — derived task state written by orchestrator: {task_id}.json
#   reviews/   — review decisions attached to artifacts: {artifact_id}-{reviewer}-{timestamp}.json
#   artifacts/ — plans, patches, test files: {task_id}-{type}-{timestamp}.{ext}

CAST_DIR="${HOME}/.claude/cast"
CAST_EVENTS_DIR="${CAST_DIR}/events"
CAST_STATE_DIR="${CAST_DIR}/state"
CAST_REVIEWS_DIR="${CAST_DIR}/reviews"
CAST_ARTIFACTS_DIR="${CAST_DIR}/artifacts"

# --- API key resolution (priority: env var override > Keychain > unset) ---
# Keychain is the PRIMARY source on macOS. The env var acts as an override:
# if ANTHROPIC_API_KEY is already set in the environment, it wins and we skip
# the Keychain lookup entirely. If neither is available, we continue without it.
if [[ -z "${ANTHROPIC_API_KEY:-}" ]] && [[ "$(uname -s)" == "Darwin" ]]; then
  _keychain_key=$(security find-generic-password -s cast-anthropic-api-key -a cast -w 2>/dev/null || true)
  if [[ -n "$_keychain_key" ]]; then
    export ANTHROPIC_API_KEY="$_keychain_key"
  fi
  unset _keychain_key
fi

# --- Connectivity check utility ---
# Calls cast-connectivity.sh check if available. Returns 0=online, 1=offline.
cast_check_connectivity() {
  local script="${CAST_SCRIPTS_DIR:-${HOME}/.claude/scripts}/cast-connectivity.sh"
  if [[ -x "$script" ]]; then
    "$script" check >/dev/null 2>&1
    return $?
  else
    # Fallback: direct ping check
    ping -c 1 -W 2 api.anthropic.com >/dev/null 2>&1
    return $?
  fi
}

_cast_init_dirs() {
  mkdir -p "$CAST_EVENTS_DIR" "$CAST_STATE_DIR" "$CAST_REVIEWS_DIR" "$CAST_ARTIFACTS_DIR"
}

# Append an immutable event file.
# Usage: cast_emit_event <event_type> <agent> <task_id> [artifact_id] [summary] [status] [concerns]
# event_type: task_created | task_claimed | task_completed | task_blocked | task_rejected | artifact_written | review_submitted
# status: DONE | DONE_WITH_CONCERNS | BLOCKED | NEEDS_CONTEXT | IN_PROGRESS | (empty)
cast_emit_event() {
  local event_type="$1"
  local agent="$2"
  local task_id="$3"
  local artifact_id="${4:-}"
  local summary="${5:-}"
  local run_status="${6:-}"
  local concerns="${7:-}"

  _cast_init_dirs

  local ts
  ts="${CAST_EVENT_TS:-$(date -u +%Y%m%dT%H%M%SZ)}"  # test seam: inject for deterministic filename ordering
  local ts_iso
  ts_iso="${CAST_EVENT_TS_ISO:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"  # test seam: inject ISO timestamp
  local safe_task_id="${task_id//\//-}"
  # Slash-safe filename component, mirroring safe_task_id above. Unlike
  # task_id/artifact_id, `agent` was never sanitized before this fix — an
  # agent name containing `/` (e.g. "team/planner") landed a literal slash
  # mid-filename, which os.open()'s O_CREAT|O_EXCL below tries to resolve
  # as a subdirectory and fails (FileNotFoundError, uncaught by the
  # `except FileExistsError` retry handler) — the event silently failed to
  # write rather than escaping anywhere. Defense-in-depth, not a traversal
  # fix: the timestamp prefix anchors the first path component so a bare
  # ".." here still can't stand alone. The JSON body keeps the RAW `agent`
  # (see `event_id`/`"agent"` in the heredoc below) — only the path
  # component is sanitized, exactly like artifact_id/safe_artifact.
  local safe_agent="${agent//\//-}"

  # Collision-safe write — same defect class as cast_write_review (see
  # comment there), and worse here: this filename carries NEITHER
  # event_type NOR artifact_id, only ts-agent-task_id. Two events for the
  # SAME agent+task_id inside one wall-clock second (e.g. two
  # `artifact_written` events for two DIFFERENT artifacts — a completely
  # normal call pattern, no adversarial timing needed) would otherwise
  # collide on the same path, and the second write would silently overwrite
  # the first: an artifact can vanish from cast_derive_state's
  # `artifact_ids` entirely, taking every review attached to it down with
  # it. `ts` may be real or injected via the CAST_EVENT_TS test seam — the
  # guard below applies identically either way and does not change seam
  # behavior when there is no collision.
  #
  # CAST dispatches agents in PARALLEL (concurrent /orchestrate wave
  # members), so two same-agent events on the same task in the same second
  # is a reachable real-PROCESS race, not just a same-process sequential
  # one — a bash-level `[[ -e ]]` check-then-write has a genuine TOCTOU gap
  # between two processes. The retry loop below is therefore entirely
  # in-process in the python3 heredoc, using O_CREAT|O_EXCL (atomic
  # create-or-fail — one syscall, no separate check) as the SOLE authority;
  # there is no bash-level pre-check to keep in sync with it. On collision
  # it retries with a numeric suffix appended to `ts`, bounded at
  # MAX_ATTEMPTS: exhausting it fails LOUDLY (nonzero return, message on
  # stderr) rather than silently dropping the event — losing an event is
  # exactly the failure this fix exists to eliminate, so a loud failure
  # beats a silent one.
  #
  # The suffix lands on the FIRST filename segment (`ts`), so the glob
  # `*-*-{task_id}.json` in cast_derive_state still matches (the filename
  # still ends in `-{agent}-{task_id}.json`), and `event_id` (built from the
  # final `ts` actually used) stays unique. No sub-second `date` is used
  # (BSD `date` has no `%N`, a recorded macOS/CI hazard here). A
  # disambiguated `ts` is no longer guaranteed to sort lexically after the
  # original filename, so cast_derive_state replays events in order of
  # their own recorded `timestamp` field rather than filename order — see
  # the comment there.
  if ! python3 - "$event_type" "$agent" "$task_id" "$artifact_id" "$summary" "$run_status" "$concerns" "$ts" "$CAST_EVENTS_DIR" "$safe_task_id" "$ts_iso" "$safe_agent" <<'PYEOF'
import json, os, sys

event_type, agent, task_id, artifact_id, summary, status, concerns, ts, events_dir, safe_task_id, ts_iso, safe_agent = sys.argv[1:]

MAX_ATTEMPTS = 100  # bounded — see cast_emit_event's comment on why exhaustion fails loudly
filepath = None
for attempt in range(MAX_ATTEMPTS):
    candidate_ts = ts if attempt == 0 else f"{ts}-{attempt + 1}"
    candidate = os.path.join(events_dir, f"{candidate_ts}-{safe_agent}-{safe_task_id}.json")
    try:
        fd = os.open(candidate, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o644)
    except FileExistsError:
        continue
    ts = candidate_ts
    filepath = candidate
    event = {
        "event_id": f"{ts}-{agent}-{task_id}",
        "timestamp": ts_iso,
        "agent": agent,
        "task_id": task_id,
        "parent_task_id": None,
        "event_type": event_type,
        "status": status if status else None,
        "summary": summary if summary else None,
        "artifact_id": artifact_id if artifact_id else None,
        "concerns": concerns if concerns else None
    }
    with os.fdopen(fd, 'w') as f:
        json.dump(event, f, indent=2)
    print(filepath, file=sys.stderr)
    break

if filepath is None:
    print(f"FATAL cast_emit_event: exhausted {MAX_ATTEMPTS} filename attempts for "
          f"{ts}*-{safe_agent}-{safe_task_id} — event NOT written", file=sys.stderr)
    sys.exit(1)
PYEOF
  then
    return 1
  fi

  # Mirror to routing-log.jsonl for dashboard visibility
  # Only for actionable event types; skip artifact/review noise
  if [[ "$event_type" == "task_claimed" || "$event_type" == "task_completed" || "$event_type" == "task_blocked" ]]; then
    CAST_ETYPE="$event_type" CAST_AGENT="$agent" CAST_TASK="$task_id" \
    CAST_SUMMARY="$summary" CAST_STATUS="$run_status" CAST_TS="$ts_iso" \
    python3 -c "
import json, os
etype   = os.environ.get('CAST_ETYPE', '')
agent   = os.environ.get('CAST_AGENT', '')
task_id = os.environ.get('CAST_TASK', '')
summary = os.environ.get('CAST_SUMMARY', '')
status  = os.environ.get('CAST_STATUS', '')
ts      = os.environ.get('CAST_TS', '')
action  = 'agent_dispatch' if etype == 'task_claimed' else ('agent_complete' if etype == 'task_completed' else 'agent_blocked')
entry = {
    'timestamp':      ts,
    'event_type':     etype,
    'action':         action,
    'matched_route':  agent,
    'agent_name':     agent,
    'prompt_preview': summary[:80] if summary else task_id,
    'command':        None,
    'status':         status if status else None,
    'task_id':        task_id,
}
import subprocess
subprocess.run(
    ['python3', os.path.join(os.environ.get('CAST_SCRIPTS_DIR', os.path.expanduser('~/.claude/scripts')), 'cast-db-log.py')],
    input=json.dumps(entry), text=True, timeout=5
)
" 2>/dev/null || true
  fi
}

# Write a review decision attached to a specific artifact.
# Usage: cast_write_review <artifact_id> <reviewer> <decision> <feedback> [recommended_agents]
# decision: approved | rejected
cast_write_review() {
  local artifact_id="$1"
  local reviewer="$2"
  local decision="$3"
  local feedback="${4:-}"
  local recommended="${5:-}"

  _cast_init_dirs

  local ts
  ts="${CAST_REVIEW_TS:-$(date -u +%Y%m%dT%H%M%SZ)}"  # test seam: inject for deterministic filename ordering (mirrors CAST_EVENT_TS)
  local ts_iso
  ts_iso="${CAST_REVIEW_TS_ISO:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"  # test seam: inject ISO timestamp
  # Safe filename: replace slashes in artifact_id
  local safe_artifact
  safe_artifact="${artifact_id//\//-}"
  # Same sanitization for `reviewer` — was previously used raw in the
  # filename (see safe_agent's comment in cast_emit_event for the exact
  # failure mode: a "/" mid-filename hits os.open()'s O_CREAT|O_EXCL as an
  # unresolvable subdirectory, so the review silently fails to write rather
  # than escaping anywhere). The JSON body keeps the RAW `reviewer` —
  # sanitization is path-only.
  local safe_reviewer
  safe_reviewer="${reviewer//\//-}"

  # Collision-safe write: `ts` is second-granularity (no sub-second `date`
  # format is used — BSD `date` has no `%N`, a recorded macOS/CI divergence
  # hazard here), so two reviews of the SAME artifact by the SAME reviewer
  # inside one wall-clock second (e.g. a rejection immediately followed by a
  # self-approval, realistic at programmatic speed) would otherwise compute
  # the SAME path, and a naive write would silently OVERWRITE the first —
  # destroying evidence rather than adding to it. A sticky/tie-break
  # resolution downstream (cast_derive_state) can't help once the file
  # itself is gone.
  #
  # CAST dispatches agents in PARALLEL (concurrent /orchestrate wave
  # members can include two same-named reviewers on one artifact), so this
  # is a reachable real-PROCESS race, not just a same-process sequential
  # one — a bash-level `[[ -e ]]` check-then-write has a genuine TOCTOU gap
  # between two processes. The retry loop below is therefore entirely
  # in-process in the python3 heredoc, using O_CREAT|O_EXCL (atomic
  # create-or-fail — one syscall, no separate check) as the SOLE authority;
  # there is no bash-level pre-check to keep in sync with it. On collision
  # it retries with a numeric suffix appended to `ts`, bounded at
  # MAX_ATTEMPTS: exhausting it fails LOUDLY (nonzero return, message on
  # stderr, and the review_submitted event below is skipped) rather than
  # silently dropping the review — losing a review write is exactly the
  # failure this fix exists to eliminate, so a loud failure beats a silent
  # one.
  #
  # `ts` (used below for review_id too) reflects whichever attempt actually
  # won, so review_id stays unique and traceable. When there is no collision
  # the filename is byte-identical to before this fix, so existing
  # single-write callers/tests are unaffected. The glob `{safe_aid}-*.json`
  # in cast_derive_state matches either shape.
  if ! python3 - "$artifact_id" "$reviewer" "$decision" "$feedback" "$recommended" "$ts" "$CAST_REVIEWS_DIR" "$safe_artifact" "$ts_iso" "$safe_reviewer" <<'PYEOF'
import json, os, sys

artifact_id, reviewer, decision, feedback, recommended, ts, reviews_dir, safe_artifact, ts_iso, safe_reviewer = sys.argv[1:]

MAX_ATTEMPTS = 100  # bounded — see cast_write_review's comment on why exhaustion fails loudly
filepath = None
for attempt in range(MAX_ATTEMPTS):
    candidate_ts = ts if attempt == 0 else f"{ts}-{attempt + 1}"
    candidate = os.path.join(reviews_dir, f"{safe_artifact}-{safe_reviewer}-{candidate_ts}.json")
    try:
        fd = os.open(candidate, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o644)
    except FileExistsError:
        continue
    ts = candidate_ts
    filepath = candidate
    review = {
        "review_id": f"{artifact_id}-{reviewer}-{ts}",
        "artifact_id": artifact_id,
        "reviewer": reviewer,
        "decision": decision,
        "timestamp": ts_iso,
        "feedback": feedback if feedback else None,
        "recommended_agents": [a.strip() for a in recommended.split(",") if a.strip()] if recommended else []
    }
    with os.fdopen(fd, 'w') as f:
        json.dump(review, f, indent=2)
    break

if filepath is None:
    print(f"FATAL cast_write_review: exhausted {MAX_ATTEMPTS} filename attempts for "
          f"{safe_artifact}-{safe_reviewer}-{ts}* — review NOT written", file=sys.stderr)
    sys.exit(1)
PYEOF
  then
    return 1
  fi

  # Also emit a review_submitted event to the event log
  cast_emit_event "review_submitted" "$reviewer" "$artifact_id" "$artifact_id" "$decision: $feedback" "$decision" ""
}

# Derive the state-file path for a task_id. Collision-resistant against
# task ids that differ only in `/` vs `-` — e.g. "a/b" and "a-b" both
# naively sanitize to "a-b" via `${task_id//\//-}`, so two DIFFERENT tasks
# would derive and read the SAME state file. Branch-derived task ids
# plausibly contain `/` (a branch name itself — this branch is
# "feature/v10-sec2-sticky-blocked"), and CAST dispatches agents in
# parallel, so a sibling process's derive can land its rejection/approval
# into the wrong task's state file in the window between one call's write
# and another's read. Appending a short hash of the RAW (pre-sanitize)
# task_id disambiguates any two ids that collide after slash-replacement.
# `shasum -a 256` is used for portability across the macOS/Linux split this
# codebase already tracks (mirrors check-plugin-drift.sh's identical
# `shasum -a 256 | awk '{print $1}'` pattern).
#
# MUST be the ONLY place this path is computed — called by BOTH the writer
# (cast_derive_state) and the reader (cast_check_approvals). Two
# independent inline computations that must stay byte-for-byte in lockstep
# is the exact redundant-private-path-model failure this change class
# exists to remove (see cast_write_review's O_CREAT|O_EXCL comment for the
# same principle applied to collision-safe writes).
#
# Pre-existing state/*.json files from before this fix use the OLD,
# unhashed name and are simply orphaned — never read again. Every caller of
# cast_check_approvals calls cast_derive_state first (see below), which
# writes a FRESH file at the new hashed path before anything reads it, in
# the same invocation. If that write is somehow skipped (e.g. a python3
# failure), the read finds no file at the new path and falls through to
# "missing approvals" (exit 1) exactly like an unreadable/missing state
# file already did before this fix — this fails CLOSED, never open.
# Usage: _cast_state_file <task_id>  (echoes the absolute path to stdout)
_cast_state_file() {
  local task_id="$1"
  local safe_task="${task_id//\//-}"
  local hash
  hash="$(printf '%s' "$task_id" | shasum -a 256 | awk '{print $1}' | cut -c1-8)"
  echo "${CAST_STATE_DIR}/${safe_task}-${hash}.json"
}

# Derive and write current state for a task_id by replaying its events.
# Writes ~/.claude/cast/state/{task_id}-{hash}.json (see _cast_state_file)
# Usage: cast_derive_state <task_id>
cast_derive_state() {
  local task_id="$1"
  _cast_init_dirs

  local state_file
  state_file="$(_cast_state_file "$task_id")"

  python3 - "$CAST_EVENTS_DIR" "$CAST_REVIEWS_DIR" "$task_id" "$state_file" <<'PYEOF'
import json, sys, os, glob

events_dir, reviews_dir, task_id, state_file = sys.argv[1:]

# Events are written with a slash-sanitized task_id in the FILENAME (see
# cast_emit_event's `safe_task_id`), but this glob previously used the RAW
# task_id — so a task_id containing "/" (plausible: branch-derived ids,
# e.g. this branch's own "feature/v10-sec2-sticky-blocked") matched NO
# file, ever, silently deriving an empty/pending state instead of failing
# loudly. The exact-match check below (`ev.get("task_id") != task_id`)
# already guards the RAW value from the JSON body — mirroring `safe_aid` in
# the reviews loop, only the glob's filename pattern needs the sanitized
# form; a same-second-sanitized different task_id (e.g. "a-b" colliding
# with "a/b") still gets filtered out correctly by that exact-match check,
# so widening the glob here does not reopen the C1 defect class.
safe_task_id = task_id.replace("/", "-")

# Replay events for this task in true chronological order (each event's own
# `timestamp` field), NOT filename order. Filenames are `{ts}-{agent}-
# {task_id}.json`, and cast_emit_event now disambiguates same-second
# same-agent/task_id collisions with a numeric suffix on `ts` (see
# cast_emit_event) — that suffix keeps this glob pattern matching (the
# filename still ends in `-{task_id}.json`) but is NOT guaranteed to sort
# lexically after the original, undecorated filename, so filename order can
# no longer stand in for replay order once a collision has happened.
# Sorting by the event's own recorded `timestamp` avoids that entirely and
# mirrors the same fix already applied to review resolution below.
pattern = os.path.join(events_dir, f"*-*-{safe_task_id}.json")
loaded_events = []
for ef in glob.glob(pattern):
    try:
        with open(ef) as f:
            ev = json.load(f)
    except Exception:
        continue
    if ev.get("task_id") != task_id:
        continue
    loaded_events.append(ev)
loaded_events.sort(key=lambda ev: ev.get("timestamp") or "")

state = {
    "task_id": task_id,
    "status": "pending",
    "owner": None,
    "artifact_ids": [],
    "last_event": None,
    "last_updated": None,
    "summary": None
}

for ev in loaded_events:
    et = ev.get("event_type", "")
    if et == "task_claimed":
        state["owner"] = ev.get("agent")
        state["status"] = "in_progress"
    elif et in ("task_completed",):
        state["status"] = ev.get("status") or "DONE"
    elif et == "task_blocked":
        state["status"] = "BLOCKED"
    elif et == "artifact_written" and ev.get("artifact_id"):
        if ev["artifact_id"] not in state["artifact_ids"]:
            state["artifact_ids"].append(ev["artifact_id"])
    state["last_event"] = et
    state["last_updated"] = ev.get("timestamp")
    state["summary"] = ev.get("summary") or state["summary"]

# Collect reviews across ALL of the task's artifacts, then resolve each
# reviewer's decision in true chronological order (each review's own
# `timestamp` field) rather than per-artifact glob order — glob order sorts
# primarily by artifact_id (the filename's first component), so interleaving
# two artifacts' review files by filename does NOT reproduce real time order
# across artifacts, only within one artifact for one reviewer.
all_reviews = []
for aid in state["artifact_ids"]:
    safe_aid = aid.replace("/", "-")
    # `safe_aid` glob is a PREFIX match, not an identity match: artifact
    # "art" and "art-1" both glob-match "art-*.json" (the latter's own
    # reviews are named "art-1-<reviewer>-<ts>.json", which also satisfies
    # "art-*.json"). Without an exact artifact_id check below, a review
    # written for a completely unrelated artifact ("art-1", from a
    # different task) is silently attributed to THIS artifact ("art"),
    # letting a foreign approval satisfy a gate that never received any
    # review of its own — or a foreign rejection spuriously block one.
    # Mirrors the task_id exact-match guard in the events loop above
    # (`if ev.get("task_id") != task_id: continue`) — same defect class,
    # same fix shape.
    rfiles = glob.glob(os.path.join(reviews_dir, f"{safe_aid}-*.json"))
    for rf in rfiles:
        try:
            with open(rf) as f:
                rv = json.load(f)
        except Exception:
            continue
        # Exact match against the RAW artifact_id (cast_write_review stores
        # the raw, unsanitized artifact_id in the JSON body — only the
        # FILENAME uses the slash-safe form, see `safe_artifact` there). A
        # review whose artifact_id is missing or does not match `aid`
        # exactly is unattributable to THIS artifact, so it is dropped
        # entirely — counted as neither an approval nor a rejection —
        # rather than guessed onto either side.
        if rv.get("artifact_id") != aid:
            continue
        if rv.get("reviewer") and rv.get("decision") in ("approved", "rejected"):
            all_reviews.append(rv)

# `timestamp` is second-granularity (see cast_write_review), so two reviews
# for the same reviewer can share the exact same value — chronological order
# between them is genuinely unavailable, not just unsorted. Sort by
# (timestamp, decision == "rejected") rather than timestamp alone: at EQUAL
# timestamps this orders "approved" before "rejected", so a tied rejection
# is always processed LAST and wins the `newest_decision` slot below — an
# ambiguous tie resolves to the safe side (rejected), never to an approval.
# Distinct timestamps are unaffected: the primary key alone still fully
# determines order whenever the reviews weren't actually simultaneous, so a
# genuinely later approval still overrides an earlier rejection as before.
all_reviews.sort(key=lambda rv: (rv.get("timestamp") or "", rv.get("decision") == "rejected"))

# Sticky-by-default: once a reviewer has EVER rejected, that reviewer stays
# rejected regardless of a later approval — a same-reviewer approval must not
# silently clear its own earlier rejection (the defect this replaces:
# `rejections = set(rejections) - set(approvals)` cleared order-independently,
# regardless of which event came first). This does not depend on the sort
# order above at all — ANY rejected review for a reviewer, tied timestamp or
# not, adds them to `ever_rejected` below — so the default path fails safe on
# ties by construction. `newest_decision` records each reviewer's
# chronologically-last decision separately (ties broken toward "rejected" per
# the sort above), so cast_check_approvals' CAST_REVIEW_BLOCK_OK=1 hatch can
# revert to newest-decision-wins without re-deriving state, and without ever
# handing out an approval on an ambiguous tie.
newest_decision = {}
ever_rejected = set()
for rv in all_reviews:
    reviewer = rv["reviewer"]
    newest_decision[reviewer] = rv["decision"]
    if rv["decision"] == "rejected":
        ever_rejected.add(reviewer)

approved_reviewers = {r for r, d in newest_decision.items() if d == "approved"}
state["approvals"] = sorted(approved_reviewers - ever_rejected)
state["rejections"] = sorted(ever_rejected)
# Additive key — approvals/rejections keep their existing list-of-strings
# shape for backward compatibility with any other reader of state/*.json.
state["newest_decision"] = newest_decision

with open(state_file, 'w') as f:
    json.dump(state, f, indent=2)
PYEOF
}

# Check if a task_id has all required approvals (for commit gating).
# Usage: cast_check_approvals <task_id> <required_reviewer1> [required_reviewer2 ...]
# Returns 0 if all required approvals present, 1 if missing, 2 if any unanswered rejections
#
# Two-tier resolution per required reviewer, BOTH sticky by default (v10-sec2 Tier1 fix):
#   1. File-based state (cast_derive_state): a recorded approved/rejected decision keyed to
#      the task's artifact_ids. This is the DB-tracked /orchestrate path; tried first.
#      cast_derive_state resolves each reviewer's decisions in true chronological order (each
#      review's own `timestamp` field) and is STICKY: any 'rejected' decision, ever, wins — a
#      later same-reviewer approval no longer clears it. (Was previously an ORDER-INDEPENDENT
#      set difference, `rejections = set(rejections) - set(approvals)`, that cleared a
#      rejection via a same-reviewer approval regardless of which event came first — fixed
#      here, mirroring Tier 2's sticky-BLOCKED semantics below.)
#   2. Session-scoped agent_runs fallback (when the file path yields no approval): all
#      same-session agent_runs rows for that reviewer that are fresh (within
#      CAST_APPROVAL_WINDOW_MIN minutes, default 120) and branch-matched. ANY eligible
#      BLOCKED row is STICKY — it rejects regardless of a later DONE. The reason: subagents
#      share the enclosing session_id, so a self-dispatched `code-reviewer__<label>` re-review
#      could otherwise silently overturn an orchestrator's earlier rejection just by running
#      again and reporting DONE.
#      Covers ad-hoc Agent-tool dispatches that never thread a TASK_ID or emit
#      artifact_written events. Fails CLOSED (missing) when no session id is resolvable.
#      See docs/phase14-review-plumbing.md (Root Cause 4).
#
# Escape hatch (both tiers): CAST_REVIEW_BLOCK_OK=1 (the literal string "1") reverts a
# reviewer to pre-fix newest-decision-wins resolution — order-DEPENDENT, using
# cast_derive_state's `newest_decision` map for Tier 1 and each row's `ended_at` for Tier 2 —
# and records the bypass via cast_ack.py on a best-effort basis, as an EXTERNAL subprocess
# (see _record_hatch_ack in the heredoc below, not an in-process `from cast_ack import
# record_ack` — that pattern is a security finding: `except Exception` does not catch
# SystemExit, so a same-named module planted on a CWD-derived sys.path could kill this whole
# gate process). This is the recorded way out, not a silent one.
cast_check_approvals() {
  local task_id="$1"
  shift
  local required=("$@")
  [ "${#required[@]}" -eq 0 ] && { echo "All required approvals present (none required)"; return 0; }

  cast_derive_state "$task_id" >/dev/null 2>&1

  local state_file
  state_file="$(_cast_state_file "$task_id")"

  # Session + branch context for the agent_runs fallback (best-effort; empty when unknown)
  local sid="${CAST_SESSION_ID:-${CLAUDE_SESSION_ID:-}}"
  local cur_branch
  cur_branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")"
  local window_min="${CAST_APPROVAL_WINDOW_MIN:-120}"
  local db_path="${CAST_DB_PATH:-$HOME/.claude/cast.db}"
  # Sticky-BLOCK escape hatch (literal "1" only, checked in Python below).
  local review_block_ok="${CAST_REVIEW_BLOCK_OK:-}"
  # No BASH_SOURCE-derived script_dir here: the bypass-ack call below shells
  # out to cast_ack.py as an external subprocess (see _record_hatch_ack),
  # resolved via CAST_SCRIPTS_DIR (falling back to ~/.claude/scripts) exactly
  # like _db_log's subprocess call earlier in this file. A second,
  # BASH_SOURCE-based resolution mechanism threaded in alongside that would
  # be the redundant-private-path-model this whole change exists to remove.

  python3 - "$state_file" "$sid" "$cur_branch" "$window_min" "$db_path" "$review_block_ok" "${required[@]}" <<'PYEOF'
import json, os, sqlite3, subprocess, sys
from datetime import datetime, timedelta, timezone

state_file = sys.argv[1]
session_id = sys.argv[2]
cur_branch = sys.argv[3]
try:
    window_min = int(sys.argv[4])
except (ValueError, IndexError):
    window_min = 120
window_min = min(max(window_min, 1), 1440)   # clamp: 1-min floor, 24h ceiling — an unbounded window lets a stale approval satisfy the gate
db_path = sys.argv[5]
review_block_ok = sys.argv[6] == "1"   # literal "1" only — "true"/"yes"/"10" do NOT qualify
required = sys.argv[7:]

def _record_hatch_ack():
    """Best-effort audit record of a CAST_REVIEW_BLOCK_OK bypass, run as an
    EXTERNAL subprocess rather than `sys.path.insert(...); from cast_ack
    import record_ack` — an in-process import puts cast_ack.py on a
    CWD-derived sys.path where a same-named module planted there could call
    sys.exit() at import time and kill this ENTIRE gate process (including a
    rejection already computed for a DIFFERENT reviewer earlier in this same
    run) — `except Exception` does not catch SystemExit/BaseException.
    Mirrors _db_log's subprocess pattern earlier in cast-events.sh: same
    CAST_SCRIPTS_DIR-env-with-~/.claude/scripts-fallback resolution: a
    subprocess exiting nonzero or timing out cannot touch our exit code.
    Must never raise or change the gate's exit code/output.
    """
    try:
        scripts_dir = os.environ.get('CAST_SCRIPTS_DIR', os.path.expanduser('~/.claude/scripts'))
        subprocess.run(
            ['python3', os.path.join(scripts_dir, 'cast_ack.py'),
             'CAST_REVIEW_BLOCK_OK', '--script', 'cast-events.sh'],
            timeout=5,
        )
    except Exception:
        pass

# ── Tier 1: file-based decisions (DB-tracked /orchestrate path) ───────────────
approvals, rejections = set(), set()
newest_decision = {}
try:
    with open(state_file) as f:
        state = json.load(f)
    approvals = set(state.get("approvals", []))
    rejections = set(state.get("rejections", []))
    newest_decision = state.get("newest_decision", {}) or {}
except Exception:
    pass  # no/unreadable state file → empty, fall through to the fallback

if review_block_ok and rejections:
    # Escape hatch (CAST_REVIEW_BLOCK_OK=1): revert Tier 1 to pre-fix
    # newest-decision-wins, per reviewer, using `newest_decision` (written by
    # cast_derive_state in true chronological order — each review's own
    # `timestamp` field, not per-artifact glob order). Only a reviewer whose
    # chronologically-newest decision is 'approved' is suppressed; a reviewer
    # whose newest decision is still 'rejected' stays rejected even with the
    # hatch on.
    tier1_hatch_suppressed = {r for r in rejections if newest_decision.get(r) == "approved"}
    if tier1_hatch_suppressed:
        rejections = rejections - tier1_hatch_suppressed
        approvals = approvals | tier1_hatch_suppressed
        _record_hatch_ack()

# A recorded rejection is authoritative — never overridden by the fallback.
if rejections:
    print(f"REJECTED by: {', '.join(sorted(rejections))}", file=sys.stderr)
    sys.exit(2)

missing = [r for r in required if r not in approvals]
if not missing:
    print("All required approvals present")
    sys.exit(0)

# ── Tier 2: session-scoped agent_runs fallback for still-missing reviewers ────
# Requires a session id to scope safely; without one we cannot tell this session's
# reviews from any other, so we fail CLOSED (missing), never open.
if not session_id:
    print(f"Missing approvals from: {', '.join(sorted(missing))}", file=sys.stderr)
    sys.exit(1)

def parse_ts(s):
    # Tolerant: accept 'T' or space separators, drop fractional/'Z' beyond 19 chars.
    s = (s or "").strip().replace("T", " ")[:19]
    try:
        return datetime.strptime(s, "%Y-%m-%d %H:%M:%S").replace(tzinfo=timezone.utc)
    except ValueError:
        return None

cutoff = datetime.now(timezone.utc) - timedelta(minutes=window_min)
REJECT = {"BLOCKED"}  # decisive statuses selected in SQL; everything non-REJECT here = approve

still_missing, fallback_rejections = [], []
hatch_suppressed_block = False
try:
    conn = sqlite3.connect(db_path, timeout=5)
    try:
        for r in missing:
            # Match the bare agent name OR its `<agent>__<label>` dispatch-naming
            # variant (working-conventions.md dispatch-naming rule) — LIKE '_' is a
            # single-char wildcard, so escape the literal pattern and anchor on a
            # literal "__" separator (never a bare "<agent>%" prefix, which would
            # also match an unrelated agent like "code-reviewer2").
            like_pattern = (
                r.replace('\\', '\\\\').replace('%', '\\%').replace('_', '\\_')
                + '\\_\\_%'
            )
            # Fetch ALL matching rows, newest first (not just the newest one) —
            # a recorded BLOCKED must be STICKY: a later same-session DONE (e.g.
            # a self-dispatched re-review) can never silently supersede it. Each
            # row still passes through the same freshness/branch filters as
            # before, evaluated per row rather than on a single fetched row.
            rows = conn.execute(
                "SELECT status, branch, ended_at FROM agent_runs "
                "WHERE session_id=? AND (agent=? OR agent LIKE ? ESCAPE '\\') "
                "AND ended_at IS NOT NULL AND ended_at != '' "
                "AND status IN ('DONE','DONE_WITH_CONCERNS','completed','BLOCKED') "
                "ORDER BY replace(ended_at, 'T', ' ') DESC",
                (session_id, r, like_pattern),
            ).fetchall()
            if not rows:
                still_missing.append(r); continue
            eligible = []  # statuses of rows surviving the filters below, newest-first
            for row_status, row_branch, row_ended_at in rows:
                row_status = (row_status or "").strip()
                row_branch = (row_branch or "").strip()
                ts = parse_ts(row_ended_at)
                # Freshness window (UTC-to-UTC; robust to timestamp-format variants).
                if ts is None or ts < cutoff:
                    continue
                # Branch guard: only when both branches are known and differ.
                if cur_branch and row_branch and row_branch != cur_branch:
                    continue
                eligible.append(row_status)
            if not eligible:
                still_missing.append(r); continue
            sticky_reject = any(s in REJECT for s in eligible)
            if review_block_ok:
                # Escape hatch (CAST_REVIEW_BLOCK_OK=1): revert this reviewer to
                # pre-fix most-recent-wins resolution. `eligible` preserves the
                # SQL's DESC-by-ended_at order, so eligible[0] is the newest
                # eligible row — deciding from it alone reproduces the old
                # single-row LIMIT 1 behavior.
                if eligible[0] in REJECT:
                    fallback_rejections.append(r)
                elif sticky_reject:
                    # The hatch is the only reason this reviewer wasn't rejected:
                    # an older eligible row IS blocked, so sticky logic (below)
                    # would have rejected it. Record that the hatch fired.
                    hatch_suppressed_block = True
            elif sticky_reject:
                fallback_rejections.append(r)
            # else: no eligible BLOCKED row → DONE / DONE_WITH_CONCERNS / completed → satisfied
    finally:
        conn.close()
except Exception as e:
    # DB unavailable/locked → fail CLOSED (do not spuriously approve).
    print(f"Missing approvals from: {', '.join(sorted(missing))} "
          f"(agent_runs fallback unavailable: {e})", file=sys.stderr)
    sys.exit(1)

if hatch_suppressed_block:
    # Best-effort audit record of the bypass (only reached when the hatch
    # actually overturned a would-be sticky BLOCK). See _record_hatch_ack's
    # docstring above for why this shells out instead of importing cast_ack
    # in-process.
    _record_hatch_ack()

if fallback_rejections:
    print(f"REJECTED by: {', '.join(sorted(set(fallback_rejections)))} (session agent_runs)",
          file=sys.stderr)
    sys.exit(2)
if still_missing:
    print(f"Missing approvals from: {', '.join(sorted(set(still_missing)))}", file=sys.stderr)
    sys.exit(1)
print(f"All required approvals present (session-scoped agent_runs fallback, window={window_min}m)")
sys.exit(0)
PYEOF
}

# Print a human-readable board of current state across all tasks.
cast_read_board() {
  _cast_init_dirs
  python3 - "$CAST_STATE_DIR" "$CAST_EVENTS_DIR" <<'PYEOF'
import json, sys, os, glob
from datetime import datetime

state_dir, events_dir = sys.argv[1:]

state_files = sorted(glob.glob(os.path.join(state_dir, "*.json")))
if not state_files:
    # Fallback: derive from events
    task_ids = set()
    for ef in glob.glob(os.path.join(events_dir, "*.json")):
        try:
            with open(ef) as f:
                ev = json.load(f)
            task_ids.add(ev.get("task_id", ""))
        except Exception:
            pass
    print(f"  No derived state yet. {len(task_ids)} task IDs seen in events/")
    sys.exit(0)

print(f"CAST Task Board — {len(state_files)} tasks")
print("═" * 60)
STATUS_ICON = {
    "DONE": "✓", "pending": "·", "in_progress": "⋯",
    "BLOCKED": "✗", "DONE_WITH_CONCERNS": "⚠", "NEEDS_CONTEXT": "?"
}
for sf in state_files:
    try:
        with open(sf) as f:
            s = json.load(f)
        icon = STATUS_ICON.get(s.get("status", ""), "·")
        approvals = ", ".join(s.get("approvals", [])) or "none"
        rejections = ", ".join(s.get("rejections", [])) or "none"
        print(f"  {icon} [{s['status']:22s}] {s['task_id']}")
        print(f"      owner={s.get('owner','?')}  approvals={approvals}  rejections={rejections}")
        if s.get("summary"):
            print(f"      {s['summary'][:72]}")
    except Exception as e:
        print(f"  ? [error reading {sf}]: {e}")
PYEOF
}
