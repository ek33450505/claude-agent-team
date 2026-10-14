# Getting Started with CAST

**CAST** turns Claude Code into a team: define a workflow once, let specialist agents plan,
implement, review, test, and commit — automatically — while a local audit log tells you
exactly what happened and why.

This is Part 1 of the CAST tutorial. It covers installation and verifying your setup.

---

## Prerequisites

- macOS (Apple Silicon or Intel) or Linux
- git, python3 and the sqlite3 CLI (see the README's [Prerequisites](../../README.md#installation) for install commands and optional extras)
- [Claude Code](https://claude.ai/code) 2.1.295 or later, installed and authenticated
- Homebrew (optional, macOS)

---

## Step 1: Install CAST

With Homebrew:

```bash
brew tap ek33450505/cast && brew install cast
bash "$(brew --prefix)/opt/cast/libexec/install.sh"   # sets up ~/.claude, cast.db, hooks
```

`brew install cast` only places the files; the second command runs the installer.

Expected output (abbreviated):

```
CAST Installer (v10.4.0)
...
Installation complete! (CAST v10.4.0)

  Installed: <!-- CAST_AGENT_COUNT -->27<!-- /CAST_AGENT_COUNT --> agents, <!-- CAST_COMMAND_COUNT -->21<!-- /CAST_COMMAND_COUNT --> commands, <!-- CAST_SKILL_COUNT -->19<!-- /CAST_SKILL_COUNT --> skills
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
/plugin install cast@cast
/plugin enable cast@cast
```

```bash
# OR local dev path (CLI flag, from a clone):
claude --plugin-dir ./plugin
```

Both paths install the same curated agents, skills, and hooks. See the README "[Installation](../../README.md#installation)" section for details.

---

## Step 2: Run `cast status`

Open a terminal inside any project directory and run:

```bash
cast status
```

Expected output (abbreviated):

```
CAST v10.4.0
======================================================================
Agents      <!-- CAST_AGENT_COUNT -->27<!-- /CAST_AGENT_COUNT --> in ~/.claude/agents/
Hooks       NN active
Spend       $X.XX today  $X.XX this week
Budget      not configured (run cast init-repo)
Memory      not configured
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
backend-writer.md    debugger.md       docs.md
...
```

A full `install.sh` gives you <!-- CAST_AGENT_COUNT -->27<!-- /CAST_AGENT_COUNT --> `.md` files (the plugin install ships a curated 22). Each file is a fully-configured agent definition with
YAML frontmatter specifying the model and memory for that specialist.

---

## What just happened

`install.sh` (run via the Homebrew libexec path or from a clone):
1. Copied <!-- CAST_AGENT_COUNT -->27<!-- /CAST_AGENT_COUNT --> agent definition files into `~/.claude/agents/` — Claude Code loads these automatically
2. Installed slash commands (e.g., `/commit`, `/review`, `/plan`) into `~/.claude/commands/`
3. Wired hook scripts into `~/.claude/settings.json` so hook events (SessionStart, PreToolUse, SubagentStop, etc.) fire on every session
4. Created the `cast` CLI at `~/.local/bin/cast`

All of this runs locally — nothing is sent to a remote server during installation.

---

## Next step

Part 2: [Dispatch your first agent](./first-agent-dispatch.md) — send `code-reviewer` at a
real file and read the Work Log output.
