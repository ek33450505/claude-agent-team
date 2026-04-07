# Research: JARVIS-Style Personal Assistant with Claude Code + CAST
**Date:** 2026-04-06
**Question:** How can CAST be extended from a coding automation framework into a full personal assistant that automates Ed's professional and personal life?

---

## Executive Summary

This is feasible today — not 80% with major gaps, but genuinely workable with MCP servers that already exist. Ed already has GitHub, Jira, and Confluence MCP connected. Gmail is available (check settings). The biggest gap is **real-time event-driven triggers** (new email arrives, Jira ticket assigned) — Claude Code has no native push/webhook listener, so all non-coding automations are polling-based or manually-triggered. The recommended architecture is a hybrid: CAST agents handle reasoning/composition, Desktop Scheduled Tasks handle durable cron automation, and optionally n8n handles webhook fan-out if real-time push matters.

**Cost estimate for 15 automated workflows/day (Haiku-heavy):** ~$8-18/month.

---

## 1. What CAST Can Do RIGHT NOW

### Already Connected (confirmed in settings.json / system context)
| MCP Server | Connected | Key Tools Available |
|---|---|---|
| GitHub | YES (`@modelcontextprotocol/server-github`) | PRs, issues, commits, code search, repo ops |
| Atlassian (Jira + Confluence) | YES (confirmed in system prompt) | JQL search, create/update/transition issues, Confluence pages |
| Gmail | YES (confirmed in system prompt) | Read/search/compose/send emails |

### Ready-to-Build This Week (no new MCP needed)
1. **Expanded morning briefing** — add Gmail unread digest + Jira sprint status to `/morning`
2. **Email triage** — read inbox, categorize, draft replies for important senders
3. **Jira sprint dashboard** — summarize open tickets, blocked items, velocity
4. **Meeting prep** — given a calendar event title, search Jira + Confluence + Gmail for context
5. **Code review notifications** — scan GitHub notifications and surface PRs needing attention
6. **Weekly sprint summary** — aggregate Jira closed tickets + GitHub merged PRs into a report

---

## 2. Available MCP Servers (Not Yet Connected)

### Microsoft / Office 365
| Server | Source | Key Capabilities | Install |
|---|---|---|---|
| Microsoft 365 (Work IQ) | Official (Microsoft) | Outlook mail+calendar, Teams, SharePoint, Word | `@microsoft/work-iq-mcp` |
| ms-365-mcp-server | Community (softeria) | Mail, files, calendar via Graph API | npm |
| floriscornel-teams | Community | Teams messages, channels, meetings | npm |

**Note:** Microsoft's Agent 365 platform (Ignite 2025) is now the official path. Work IQ MCP servers cover Outlook, Teams, Calendar, and SharePoint as separate server components. SSE endpoint retires June 30, 2026 — use STDIO transport.

### Google Workspace
| Server | Source | Key Capabilities |
|---|---|---|
| google-workspace-mcp | Community (j3k0) | Gmail, Drive, Calendar, Docs, Sheets — OAuth 2.1 multi-user |
| @cocal/google-calendar-mcp | Community | Multi-account calendar, conflict detection |

### Collaboration Tools
| Tool | Server | Status |
|---|---|---|
| Slack | Official (remote-only) | Messages, channels, search — OAuth-based |
| Notion | Official (remote-only) | Pages, databases, blocks — token-efficient markdown |
| Linear | Community | Issues, projects, cycles — API key auth |
| Todoist | Community via HA or direct | Tasks, projects, due dates |

### Home Automation
| Tool | Server | Notes |
|---|---|---|
| Home Assistant | Official integration (`homeassistant.io/integrations/mcp_server`) | Lights, devices, automations — HA 2025.2+ built-in |
| HomeKit via HA | Via HA bridge | HA exposes HomeKit devices through its own MCP |
| ha-mcp (community) | `homeassistant-ai/ha-mcp` on GitHub | Docker deployable |

**Home Assistant is the key**: it bridges HomeKit, Z-Wave, Zigbee, and almost every smart home device into a single MCP server. If Ed uses HA, one server handles the whole home.

### Finance & Health
| Area | Options | Maturity |
|---|---|---|
| Plaid / banking | Community MCP servers exist; Plaid OAuth required | Early/fragile |
| Health/fitness | Apple Health has no MCP; Garmin/Fitbit community options | Immature |
| Expense tracking | Expensify MCP (community), or CSV-based manual approach | Workable |

---

## 3. Recommended Architecture

### Architecture Diagram

```
                         ┌──────────────────────────────────────────────────┐
                         │              CAST Personal Assistant              │
                         │                  ~/.claude/agents/                │
                         └──────────────────────────────────────────────────┘
                                              │
                           ┌──────────────────┼──────────────────┐
                           ▼                  ▼                  ▼
                  ┌─────────────────┐  ┌────────────┐  ┌────────────────┐
                  │  pa-briefing    │  │ pa-triage  │  │  pa-jira       │
                  │  (haiku)        │  │ (haiku)    │  │  (haiku)       │
                  │  Daily digest:  │  │ Email/PR   │  │  Sprint mgmt,  │
                  │  mail+cal+jira  │  │ triage,    │  │  ticket ops,   │
                  │  +github        │  │ routing    │  │  stand-up gen  │
                  └────────┬────────┘  └─────┬──────┘  └──────┬─────────┘
                           │                 │                 │
                           └─────────────────┼─────────────────┘
                                             │
                                  ┌──────────▼──────────┐
                                  │   orchestrator       │
                                  │   (sonnet)           │
                                  │   Routes, composes,  │
                                  │   handles ambiguity  │
                                  └──────────┬───────────┘
                                             │
                 ┌───────────────────────────┼───────────────────────────┐
                 ▼                           ▼                           ▼
       ┌──────────────────┐      ┌──────────────────────┐    ┌────────────────────┐
       │   MCP Servers    │      │  Desktop Scheduled   │    │   CAST Existing    │
       │                  │      │  Tasks (durable cron)│    │   Agents           │
       │  • GitHub        │      │                      │    │                    │
       │  • Jira/Conf     │      │  • 07:45 briefing    │    │  • code-writer     │
       │  • Gmail         │      │  • 09:00 triage      │    │  • morning-brief   │
       │  • MS 365 (add)  │      │  • 16:30 standup gen │    │  • commit          │
       │  • Slack (add)   │      │  • Friday report     │    │  • code-reviewer   │
       │  • Home Asst(add)│      │                      │    │  • ... (17 total)  │
       └──────────────────┘      └──────────────────────┘    └────────────────────┘
```

### Agent Design Decision: Specialized Per Domain

**Recommendation: specialized agents dispatched by orchestrator**, not one monolithic PA agent. This matches CAST's existing pattern and keeps agents small, focused, and replaceable.

| Agent | Model | Role |
|---|---|---|
| `pa-briefing` | haiku | Morning + evening digest (mail, cal, Jira, GitHub) |
| `pa-triage` | haiku | Email and PR triage, routing, follow-up drafts |
| `pa-jira` | haiku | Jira sprint ops, ticket creation, stand-up generation |
| `pa-meeting-prep` | sonnet | Pre-meeting context gathering (needs reasoning) |
| `pa-weekly-report` | sonnet | Weekly summary synthesis (needs reasoning) |
| `pa-home` (future) | haiku | Home Assistant commands, routines |

**Why haiku for most:** Triage, briefing, and Jira ops are structured and routine — haiku handles them well at 1/3 the cost of sonnet. Reserve sonnet for tasks requiring synthesis across many sources.

---

## 4. Scheduling and Triggers

### What Exists Today (Claude Code Desktop Scheduled Tasks)
- Persistent across restarts (unlike `/loop`)
- Minimum 1-minute interval
- Full local file and MCP access
- No "machine must be on" caveat beyond being asleep
- **This is the right tool** for most of Ed's automations

### Trigger Strategy by Use Case
| Use Case | Trigger Method | Tool |
|---|---|---|
| Morning briefing | Desktop Scheduled Task, 07:45 daily | Claude Code |
| Email triage | Desktop Scheduled Task, every 30m during work hours | Claude Code |
| Jira stand-up generation | Desktop Scheduled Task, 09:00 Mon-Fri | Claude Code |
| End-of-day summary | Desktop Scheduled Task, 16:30 Mon-Fri | Claude Code |
| Weekly report | Desktop Scheduled Task, Fridays at 15:00 | Claude Code |
| New email arrives (push) | NOT supported natively — requires n8n + webhook relay | n8n optional |
| CI failure notification | GitHub Actions + Channels (Claude Code Channels) | Claude Code |
| Jira ticket assigned to Ed | Polling every 15m (JQL: assignee=currentUser() AND updated >= -15m) | Claude Code |

### Claude Code "Channels" Feature (Event Push)
Claude Code Channels allows external systems to push events into a running session. CI can push failure data directly. This is the event-driven path, but it requires a running session — less useful for always-on personal assistant use. Monitor this feature as it matures.

### Chyros Daemon (Coming)
A background daemon codename "Chyros" is in Claude Code's source — intended to run at login as a system service independent of any terminal session. This would solve the "machine must be open" limitation. Not available yet, but worth watching.

---

## 5. Concrete Workflows to Build This Week

### Priority 1: Expand /morning (1-2 hours)
Modify `morning-briefing.md` to:
- Pull Gmail unread count + top 5 subjects (via Gmail MCP)
- Add Jira sprint items: open tickets assigned to Ed, any blocked items
- Add today's calendar events (once Google Calendar MCP added)
- Keep existing GitHub activity and CAST system checks

### Priority 2: pa-triage agent (2-3 hours)
New agent: reads Gmail inbox, categorizes by: urgent/respond-today/FYI/newsletter, drafts replies for "respond-today" items, outputs a triage report to `~/.claude/briefings/email-triage-YYYY-MM-DD.md`.

### Priority 3: pa-jira agent (2 hours)
New agent: given a sprint or project key, queries Jira via MCP, produces:
- Stand-up text (what I did, what I'm doing, blockers)
- Sprint burndown narrative
- Blocked tickets summary with suggested next steps

### Priority 4: Desktop Scheduled Tasks (30 min)
Register the above agents as Desktop Scheduled Tasks at their optimal fire times.

### Priority 5: Google Calendar MCP (30 min)
Add `@cocal/google-calendar-mcp` to settings.json. This unlocks meeting prep workflows.

---

## 6. Limitations and Gaps (Honest Assessment)

| Limitation | Severity | Workaround |
|---|---|---|
| No real-time push (email arrives → agent fires) | High | Poll every 15-30 min. Add n8n for true push if needed. |
| No voice interface | High | None within Claude Code. Apple Shortcuts + Siri Shortcuts could call cast CLI commands. |
| No mobile access | Medium | None native. Claude.ai mobile app works for ad-hoc but not automation. |
| Machine must be on for Desktop Tasks | Medium | Cloud Scheduled Tasks bypass this, but lose local file access. |
| Claude Code sessions aren't always-on | Medium | Chyros daemon (future). Cron + `claude -p` is the current workaround. |
| Finance/banking MCP is immature | Medium | Manual CSV export + analysis is more reliable now. |
| Apple Health has no MCP | Low | Export via Health app + parse CSV as a periodic task. |
| Rate limits on Claude API | Low | Personal assistant workload is well within limits at hobby scale. |
| Context window limits for large email archives | Medium | Summarize incrementally; never feed raw full inboxes. |

---

## 7. Comparison with Alternatives

| Criteria | Claude Code + CAST | n8n (self-hosted) | Zapier | Apple Shortcuts + Siri | Microsoft Copilot |
|---|---|---|---|---|---|
| Reasoning quality | Excellent | None (routes to LLMs) | None (routes to LLMs) | Poor | Good (GPT-4 based) |
| Coding integration | Native | Separate tool | Separate tool | None | Limited |
| Local-first | Yes | Yes | No (cloud-only) | Yes | No (cloud) |
| Cost | ~$10-20/mo (API) | Free (self-host) | $20-50/mo | Free | $30/mo (M365) |
| Real-time triggers | No (polling/manual) | Yes (webhooks) | Yes (webhooks) | Limited | Yes |
| Voice interface | No | No | Limited | Yes (Siri) | Teams integration |
| Setup complexity | Medium (agents are code) | Medium (visual) | Low (no-code) | Low | Low |
| Customizability | Extremely high | High | Medium | Low | Low |
| Privacy | High (local) | High (self-host) | Low | High | Low |
| Best for Ed | YES — coding + PA unified | Webhook relay only | Overkill | Shortcuts for quick triggers | Work-specific only |

**Verdict:** Claude Code + CAST is the right foundation because it unifies coding automation and personal assistant in one system. **n8n is a worthwhile complement** (not replacement) if Ed wants real-time push triggers without building a webhook listener from scratch. Apple Shortcuts can serve as a thin mobile/voice layer that calls `cast` CLI commands.

---

## 8. Cost Estimate

**Scenario: 15 automated tasks/day, mostly haiku**

| Workflow | Model | Estimated tokens/run | Runs/day | Monthly cost |
|---|---|---|---|---|
| Morning briefing | haiku | ~4K in, 1K out | 1 | ~$0.15 |
| Email triage (every 30m, 8h window) | haiku | ~3K in, 500 out | 16 | ~$0.50 |
| Jira stand-up | haiku | ~2K in, 500 out | 1 | ~$0.04 |
| End-of-day summary | haiku | ~3K in, 800 out | 1 | ~$0.07 |
| Weekly report (sonnet) | sonnet | ~8K in, 2K out | 0.2 | ~$0.55/week |
| Meeting prep (sonnet) | sonnet | ~6K in, 1.5K out | 1 | ~$0.25 |
| Ad-hoc PA queries | sonnet | ~3K in, 1K out | 3 | ~$1.10 |

**Estimated total: ~$8-18/month** at current API rates. This is well within the Claude Max plan's included token allocation — if Ed is already on Max, the marginal cost may be near zero.

**Optimization:** Route all non-reasoning tasks (triage, briefing, Jira ops) to Haiku. Only meeting prep, weekly report, and ambiguous tasks need Sonnet. This cuts cost by 60%.

---

## 9. Phased Rollout Plan

### Phase 1 — This Week (hours 1-8)
- [ ] Add Google Calendar MCP to settings.json
- [ ] Expand morning-briefing agent to include Gmail + Jira sprint
- [ ] Create `pa-triage` agent for email triage
- [ ] Register morning briefing as a Desktop Scheduled Task at 07:45

### Phase 2 — Week 2 (hours 9-16)
- [ ] Create `pa-jira` agent for stand-up generation + sprint ops
- [ ] Create `pa-meeting-prep` agent (uses Gmail + Jira + Confluence)
- [ ] Register stand-up generation as Desktop Scheduled Task at 09:00
- [ ] Add Microsoft 365 Work IQ MCP (Teams + Outlook, since META Solutions uses M365)

### Phase 3 — Week 3-4 (hours 17-24)
- [ ] Create `pa-weekly-report` agent for Friday sprint summaries
- [ ] Evaluate n8n for webhook relay if polling latency is annoying
- [ ] Consider Home Assistant MCP if Ed uses smart home devices
- [ ] Add Slack MCP once official server works in Claude Code context

### Phase 4 — Future
- [ ] Mobile: Apple Shortcut → `cast` CLI → pa-triage on demand
- [ ] Monitor Chyros daemon for always-on capability
- [ ] Explore Claude Code Channels for CI/CD event push

---

## Sources

- [Connect Claude Code to tools via MCP - Claude Code Docs](https://code.claude.com/docs/en/mcp)
- [Run prompts on a schedule - Claude Code Docs](https://code.claude.com/docs/en/scheduled-tasks)
- [Microsoft Work IQ MCP overview](https://learn.microsoft.com/en-us/microsoft-agent-365/tooling-servers-overview)
- [Microsoft Teams MCP Server by Floris Cornel](https://www.pulsemcp.com/servers/floriscornel-teams)
- [ms-365-mcp-server](https://mcpservers.org/servers/softeria/ms-365-mcp-server)
- [Google Workspace MCP Server](https://mcpservers.org/servers/j3k0/mcp-google-workspace)
- [Home Assistant MCP Server Integration](https://www.home-assistant.io/integrations/mcp_server/)
- [atlassian-mcp-server (official)](https://github.com/atlassian/atlassian-mcp-server)
- [sooperset/mcp-atlassian](https://github.com/sooperset/mcp-atlassian)
- [n8n vs Claude Code vs Agentic Workflows](https://www.mindstudio.ai/blog/n8n-vs-claude-code-vs-agentic-workflows-comparison)
- [How I Built Jarvis - Sid Bharath](https://sidbharath.com/blog/how-i-built-jarvis/)
- [Claude API Pricing 2026](https://platform.claude.com/docs/en/about-claude/pricing)
- [Claude Code Chyros background daemon](https://www.mindstudio.ai/blog/what-is-claude-code-chyros-background-daemon)
- [Composio MCP (universal connector)](https://mcp.composio.dev/)
- [PulseMCP Server Directory](https://www.pulsemcp.com/)
