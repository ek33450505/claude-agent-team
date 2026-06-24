# Getting Started with CAST

**CAST** turns Claude Code into a team: define a workflow once, let specialist agents plan,
implement, review, test, and commit — automatically — while a local audit log tells you
exactly what happened and why.

This is Part 1 of the CAST tutorial. It covers installation and verifying your setup.

---

## Prerequisites

- macOS (Apple Silicon or Intel) or Linux
- [Claude Code](https://claude.ai/code) installed and authenticated
- Homebrew (macOS) or curl (Linux)

---

## Step 1: Install CAST via Homebrew

```bash
brew tap ek33450505/cast
brew install cast
```

Expected output:

```
==> Tapping ek33450505/cast
==> Downloading https://github.com/ek33450505/claude-agent-team/...
==> Installing cast
  CAST Installer (v7.3.1)

  ✓ Installed <!-- CAST_AGENT_COUNT -->23<!-- /CAST_AGENT_COUNT --> agents -> ~/.claude/agents/
  ✓ Installed <!-- CAST_COMMAND_COUNT -->20<!-- /CAST_COMMAND_COUNT --> slash commands -> ~/.claude/commands/
  ✓ Installed <!-- CAST_SKILL_COUNT -->17<!-- /CAST_SKILL_COUNT --> skills -> ~/.claude/skills/
  ✓ Installed hook scripts -> ~/.claude/scripts/
  ✓ Installed 9 rules -> ~/.claude/rules/
  ✓ Wired settings.json (hooks, permissions)
  Installation complete! (CAST v7.3.1)
```

### Alternative: clone + install

```bash
git clone https://github.com/ek33450505/claude-agent-team.git
cd claude-agent-team
bash install.sh
```

### Alternative: install as a Claude Code plugin

```text
# Marketplace install — run these slash commands inside a Claude Code session:
/plugin marketplace add ek33450505/claude-agent-team
/plugin install cast
/plugin enable cast@cast
```

```bash
# OR local dev path (CLI flag, from a clone):
claude --plugin-dir ./plugin
```

Both paths install the same curated agents, skills, and hooks. See the README "[Install as a plugin (beta)](../../README.md#install-as-a-plugin-beta)" section for details.

---

## Step 2: Run `cast status`

Open a terminal inside any project directory and run:

```bash
cast status
```

Expected output (abbreviated):

```
CAST v7.3.1
======================================================================
Agents      23 installed
Hooks       29 active
Spend       $0.00 today  $X.XX this week
Budget      not configured (run cast init-repo)
Memory      N entries | ...
======================================================================
```

If you see `command not found: cast`, ensure `~/.local/bin` is on your `$PATH`:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

Add that line to your `~/.zshrc` or `~/.bashrc` to make it permanent.

---

## Step 3: Confirm the agent list loads

```bash
ls ~/.claude/agents/
```

Expected output (partial):

```
api-contract.md      commit.md         dep-auditor.md
bash-specialist.md   code-reviewer.md  devops.md
code-writer.md       debugger.md       docs.md
...
```

You should see 23 `.md` files. Each file is a fully-configured agent definition with
YAML frontmatter specifying the model and memory for that specialist.

---

## What just happened

`brew install cast` ran `install.sh`, which:
1. Copied <!-- CAST_AGENT_COUNT -->23<!-- /CAST_AGENT_COUNT --> agent definition files into `~/.claude/agents/` — Claude Code loads these automatically
2. Installed slash commands (e.g., `/commit`, `/review`, `/plan`) into `~/.claude/commands/`
3. Wired hook scripts into `~/.claude/settings.json` so hook events (SessionStart, PreToolUse, SubagentStop, etc.) fire on every session
4. Created the `cast` CLI at `~/.local/bin/cast`

All of this runs locally — nothing is sent to a remote server during installation.

---

## Next step

Part 2: [Dispatch your first agent](./first-agent-dispatch.md) — send `code-reviewer` at a
real file and read the Work Log output.
