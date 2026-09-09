#!/usr/bin/env python3
"""
CAST Workflow Stage-Model Lint

Fails (exit 1) when an ``agent(...)`` call in a repo workflow script omits an
explicit ``model:``.

WHY THIS GATE EXISTS
--------------------
Workflow stages inherit the **main-loop model** when ``model:`` is omitted --
the Workflow tool documents this explicitly ("the agent inherits the main-loop
model (the resolved session model)"). Passing ``agentType`` does NOT supply the
roster agent's frontmatter model: a stage declared ``agentType: 'code-reviewer'``
gets code-reviewer's *prompt* but the *session's* model. So the roster's careful
haiku assignments are silently discarded inside workflows.

Measured 2026-09-09 over a 27d window (3,606 rows, $5,358.62):
``workflow-subagent`` ran 150 opus stages costing $471.68 ($3.14/run) against
360 sonnet ($0.69/run) and 16 haiku ($0.18/run) -- 29% of runs, 63% of that
agent's cost. ``working-conventions.md`` already carries the per-stage rule as
prose; prose is not enforcement, and the only workflow in this repo had 8
``agent()`` calls and zero ``model:`` when this lint was written.

Re-measure before citing those numbers (``just -g window`` then ``just -g cost``);
the DB prunes on CAST_DB_PRUNE_DAYS and any literal here goes stale.

SCOPE
-----
Hermetic: reads only ``workflows/*.workflow.js`` under the repo root. Never
touches the live ~/.claude install.

ESCAPE HATCH
------------
A stage that genuinely must inherit the session model opts out with a comment
on the ``agent(`` line or the line directly above it:

    // cast-lint: inherit-model -- final adversarial judge, needs session opus
    const verdict = await agent(PROMPT, { label: 'judge' })

The reason text after ``--`` is required; a bare marker does not count. This
keeps the gate honest: an opt-out is a decision on the record, not a silencer.

DOCUMENTED LIMITS
-----------------
- Comments, string/template *contents*, and regex literals are blanked before
  parsing, so a ``model:`` mentioned in prompt text, a comment, or a pattern
  does not count as a real specification. Offsets and newlines are preserved so
  reported line numbers are accurate.
- Regex-vs-division is resolved by the previous-significant-character
  heuristic (see ``_regex_can_start``). The rare ``return /re/`` keyword form is
  read as division, which leaves a regex body unblanked -- that can only add a
  spurious finding, never hide a real one.
- If the scrub ends with an unclosed quote the file is NOT certified: the lint
  reports a PARSE ANOMALY and exits 1 rather than reporting zero violations.
- An ``agent(`` appearing inside a ``${...}`` interpolation within a template
  literal is not detected (the template body is blanked). No workflow in this
  repo does that; if one ever does, this lint under-reports rather than
  false-passing on the outer call.
- ``model:`` is matched anywhere in the call's own argument span after nested
  ``agent(...)`` spans are blanked out, so an inner stage's model cannot
  satisfy an outer one.
"""

import os
import re
import sys

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WORKFLOW_DIR = os.path.join(REPO_ROOT, "workflows")
OPT_OUT_RE = re.compile(r"cast-lint:\s*inherit-model\s*--\s*\S")
AGENT_CALL_RE = re.compile(r"\bagent\s*\(")
MODEL_KEY_RE = re.compile(r"\bmodel\s*:")


def _regex_can_start(last):
    """True if a ``/`` at this point begins a regex literal rather than division.

    Standard heuristic: a regex may start unless the previous significant
    character ends a value (identifier, number, closing paren/bracket). This
    misreads the rare ``return /re/`` / ``typeof /re/`` keyword form as
    division, which leaves the regex body unblanked -- a *noisy* failure, never
    a silent pass.
    """
    if last == "":
        return True
    if last.isalnum() or last in "_$":
        return False
    return last not in ")]"


def blank_comments_and_strings(src):
    """Blank comment bodies, string/template contents, and regex literals.

    Returns ``(scrubbed, unterminated)``. Every replaced character becomes a
    space and newlines are always kept, so ``src.count('\\n', 0, offset)`` still
    yields the correct line number.

    ``unterminated`` is the still-open state at EOF (or None). A non-None value
    means the scrub cannot be trusted -- the caller MUST refuse to certify the
    file rather than report zero violations, because everything after the
    unclosed quote was blanked and any agent() call in it became invisible.
    """
    out = []
    i = 0
    n = len(src)
    state = None  # None | 'line' | 'block' | "'" | '"' | '`'
    last = ""     # last significant char emitted at top level
    while i < n:
        c = src[i]
        nxt = src[i + 1] if i + 1 < n else ""
        if state is None:
            if c == "/" and nxt == "/":
                state, i = "line", i + 2
                out.append("  ")
                continue
            if c == "/" and nxt == "*":
                state, i = "block", i + 2
                out.append("  ")
                continue
            if c == "/" and _regex_can_start(last):
                # Regex literal: blank its body up to the unescaped closing '/',
                # honouring [...] classes (a '/' inside a class does not close).
                out.append("/")
                i += 1
                in_class = False
                while i < n:
                    ch = src[i]
                    if ch == "\\":
                        out.append("  " if src[i + 1:i + 2] != "\n" else " \n")
                        i += 2
                        continue
                    if ch == "\n":  # unterminated regex -- stop, keep the newline
                        break
                    if ch == "[":
                        in_class = True
                    elif ch == "]":
                        in_class = False
                    elif ch == "/" and not in_class:
                        out.append("/")
                        i += 1
                        break
                    out.append(" ")
                    i += 1
                last = "/"
                continue
            if c in ("'", '"', "`"):
                state = c
            out.append(c)
            if not c.isspace():
                last = c
            i += 1
            continue
        if state == "line":
            if c == "\n":
                state = None
                out.append("\n")
            else:
                out.append(" ")
            i += 1
            continue
        if state == "block":
            if c == "*" and nxt == "/":
                state, i = None, i + 2
                out.append("  ")
                continue
            out.append("\n" if c == "\n" else " ")
            i += 1
            continue
        # inside a string or template literal
        if c == "\\":
            out.append("  " if nxt != "\n" else " \n")
            i += 2
            continue
        if c == state:
            state = None
            out.append(c)
            last = c
        else:
            out.append("\n" if c == "\n" else " ")
        i += 1
    return "".join(out), (state if state in ("'", '"', "`") else None)


def call_span(src, open_paren):
    """Return the index just past the ``)`` matching ``src[open_paren]``."""
    depth = 0
    i = open_paren
    while i < len(src):
        if src[i] == "(":
            depth += 1
        elif src[i] == ")":
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    return len(src)


def find_violations(path):
    with open(path, "r", encoding="utf-8") as fh:
        original = fh.read()
    scrubbed, unterminated = blank_comments_and_strings(original)
    original_lines = original.splitlines()

    # FAIL CLOSED. An unclosed quote at EOF means everything after it was
    # blanked, so any agent() call in that region is invisible. Reporting zero
    # violations here would be a silent pass -- the one outcome this gate must
    # never produce. Report the anomaly instead.
    if unterminated is not None:
        return [(0, "PARSE ANOMALY: unterminated %s at EOF -- file not certified"
                 % unterminated)]

    calls = []
    for m in AGENT_CALL_RE.finditer(scrubbed):
        open_paren = m.end() - 1
        calls.append((m.start(), open_paren, call_span(scrubbed, open_paren)))

    violations = []
    for start, open_paren, end in calls:
        span = list(scrubbed[open_paren:end])
        # Blank nested agent(...) spans so an inner model: cannot satisfy this call.
        for nstart, nopen, nend in calls:
            if nopen > open_paren and nend <= end:
                for k in range(nopen - open_paren, nend - open_paren):
                    if span[k] != "\n":
                        span[k] = " "
        if MODEL_KEY_RE.search("".join(span)):
            continue

        lineno = scrubbed.count("\n", 0, start) + 1
        here = original_lines[lineno - 1] if lineno - 1 < len(original_lines) else ""
        above = original_lines[lineno - 2] if lineno - 2 >= 0 else ""
        if OPT_OUT_RE.search(here) or OPT_OUT_RE.search(above):
            continue
        violations.append((lineno, here.strip()[:88]))
    return violations


def main():
    if not os.path.isdir(WORKFLOW_DIR):
        print(f"workflow-stage-models: no {WORKFLOW_DIR}/ -- nothing to check")
        return 0

    names = sorted(f for f in os.listdir(WORKFLOW_DIR) if f.endswith(".workflow.js"))
    if not names:
        print("workflow-stage-models: no *.workflow.js files -- nothing to check")
        return 0

    total = 0
    checked = 0
    for name in names:
        path = os.path.join(WORKFLOW_DIR, name)
        violations = find_violations(path)
        checked += 1
        if not violations:
            continue
        total += len(violations)
        print(
            f"workflows/{name}: {len(violations)} agent() call(s) with no explicit model:",
            file=sys.stderr,
        )
        for lineno, text in violations:
            where = f"line {lineno}: " if lineno else ""
            print(f"  - {where}{text}", file=sys.stderr)

    if total:
        print("", file=sys.stderr)
        print(
            "An agent() stage without model: inherits the session model (opus).\n"
            "Set model per stage -- 'haiku' for mechanical/scout/gather, 'sonnet' for\n"
            "the analytical middle, 'opus' only for synthesis/adversarial-judge tops.\n"
            "Genuinely opus-hard stage? Opt out on the line above with:\n"
            "  // cast-lint: inherit-model -- <reason>",
            file=sys.stderr,
        )
        return 1

    print(f"workflow-stage-models: OK ({checked} file(s), every agent() stage pins a model)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
