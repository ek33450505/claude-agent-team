---
description: CAST roadmap command
---

Show CAST's open work from `plans/next-session.md` (maintenance mode — the backlog lives there).

## Usage

- `/roadmap` — Summarize open work: next action, Session Ledger, open items, and Backlog
- `/roadmap next` — Show the NEXT ACTION and the protocol for running it
- `/roadmap <S#>` — Show one Session Ledger row and its open-work items

## Arguments

$ARGUMENTS

## Instructions

Read `~/Projects/personal/claude-agent-team/plans/next-session.md`. It is the only top-level `.md` in `plans/`. Completed history lives in `plans/archive/`; don't read the archive unless asked.

### No arguments — show the plan

Display concisely:
1. The `▶ NEXT ACTION` line.
2. The **Session Ledger** table (S#, Goal, Units, Status).
3. One line per item under **Open work — in order** (heading + item name only).
4. The item names under **Backlog — needs Ed's case**, labelled as needing Ed's case before any work starts.

End with: "Run `/roadmap next` for the next action, or `/roadmap <S#>` for one session's detail."

### `/roadmap next`

Print the `▶ NEXT ACTION` line verbatim, then the **Autonomous-run protocol** section. Do not start work, invoke `/plan`, or dispatch agents. The user decides when to start.

### `/roadmap <S#>`

Find row S# in the Session Ledger. Print that row, then every **Open work** item that belongs to the row's units. If there is no such row, list the valid S# values.

## Rules

- Read-only: never edit `plans/next-session.md` from this command. Its structure feeds `scripts/cast-resume-scaffold.py` (see the file's Resume-tooling contract).
- Never present a **Backlog — needs Ed's case** item as ready to build.
- If the file does not exist, output "No plan at plans/next-session.md." and stop.
