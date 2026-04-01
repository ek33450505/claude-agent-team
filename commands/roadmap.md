Resume the CAST backlog from `research/cast-future-roadmap.md`.

## Usage

- `/roadmap` — Display all backlog items with priority and effort
- `/roadmap <number>` — Kick off the `/plan` skill for item N from the roadmap
- `/roadmap next` — Pick the highest-priority unstarted item and start planning it

## Arguments

$ARGUMENTS

## Instructions

### No arguments — show the roadmap

Read `~/Projects/personal/claude-agent-team/research/cast-future-roadmap.md` and display a concise summary table:

| # | Item | Effort | Why It Matters |
|---|---|---|---|
| 1 | CAST Plugin Package | 2-3 days | Dual-channel distribution |
| ... | | | |

End with: "Run `/roadmap <number>` to start planning any item, or `/roadmap next` to start the highest-priority one."

### `/roadmap next`

Read the roadmap. Pick item #1 (highest priority). Invoke the `/plan` skill with that item as the task, providing full context from the roadmap entry (what it is, why it matters, effort estimate, dependencies).

### `/roadmap <number>`

Read the roadmap. Find item N. Invoke the `/plan` skill with that item as the task. Pass the full roadmap entry as context so the planner has all the detail it needs.

When invoking `/plan`, include:
- The item name and description from the roadmap
- The "why it matters" rationale
- Any noted dependencies or existing drafts (e.g. "draft exists at research/hn-show-hn-draft.md")
- Effort estimate as a sizing hint

## Roadmap location

`~/Projects/personal/claude-agent-team/research/cast-future-roadmap.md`

If the file does not exist, output: "Roadmap not found at research/cast-future-roadmap.md. Run `/research` to regenerate it."
