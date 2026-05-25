# Archived Agents

These agent definition files were promoted to first-class CAST agents and later deprecated
as their functionality was absorbed into other agents or the framework itself.

They are preserved here for historical reference — not deleted — because they capture
design decisions, prompt patterns, and capability boundaries that informed the current
agent registry. Deleting them would lose that context permanently.

**Do not load these files as active agents.** The canonical agent list is in `agents/core/`.

| File | Purpose | Reason archived |
|------|---------|----------------|
| `ADD-CANDIDATES-NOT-JUSTIFIED.md` | Documents agents evaluated and rejected during Phase 4.5.4 research sprint (marketing-copy and others) | Meta-document, not an agent definition; retained as decision record |
| `adr-writer.md` | Architecture Decision Record author — drafts ADRs in standard Title/Status/Context/Decision/Consequences format | Functionality absorbed into `docs` agent; ADR authoring is infrequent enough to handle inline |
| `email-drafter.md` | Professional email composer — drafts emails from bullet points, never sends | Superseded by direct user authoring + docs agent for low-frequency task |
| `knowledge-curator.md` | Obsidian vault organizer — links notes, surfaces stale content, suggests tag cleanup | Routine converted to scheduled `cast-routines` job; no longer needs a standing agent |
| `learning-scout.md` | Tech topic monitor and resource curator — searches for learning resources, writes structured Obsidian summaries | Routine converted to scheduled `cast-routines` job (`learning-scout.yaml`) |
| `meeting-prep.md` | Meeting preparation agent — pulls calendar via Google Calendar MCP, writes per-meeting briefs | Routine converted to scheduled `cast-routines` job (`meeting-prep.yaml`) |
| `portfolio-sync.md` | Portfolio updater — syncs showcase repo READMEs with actual project state (test counts, versions, badges) | Moved to `agents/personal/` layer (`--personal` flag) as maintainer-only tooling |
| `pr-narrator.md` | PR storyteller — translates diffs into stakeholder-facing summaries in non-technical language | Routine converted to scheduled `cast-routines` job (`pr-narrator.yaml`) |
| `standup-writer.md` | Daily standup update generator — creates outward-facing status updates from git activity and Todoist | Routine converted to scheduled `cast-routines` job (`standup-writer.yaml`) |
| `task-triage.md` | Todoist inbox triage — reviews inbox, assigns priorities and due dates, surfaces overdue tasks | Routine converted to scheduled `cast-routines` job (`task-triage.yaml`) |
