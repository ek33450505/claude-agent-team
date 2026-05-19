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
==> Downloading https://github.com/ek33450505/cast/...
==> Installing cast
  CAST Installer (v7.0)

  ✓ Installed <!-- CAST_AGENT_COUNT -->23<!-- /CAST_AGENT_COUNT --> agents -> ~/.claude/agents/
  ✓ Installed <!-- CAST_COMMAND_COUNT -->19<!-- /CAST_COMMAND_COUNT --> slash commands -> ~/.claude/commands/
  ✓ Installed <!-- CAST_SKILL_COUNT -->16<!-- /CAST_SKILL_COUNT --> skills -> ~/.claude/skills/
  ✓ Installed hook scripts -> ~/.claude/scripts/
  ✓ Installed 12 rules -> ~/.claude/rules/
  ✓ Wired settings.json (hooks, permissions)
  CAST v6.0 installed.
```

### Alternative: clone + install

```bash
git clone https://github.com/ek33450505/claude-agent-team.git
cd claude-agent-team
bash install.sh
```

---

## Step 2: Run `cast status`

Open a terminal inside any project directory and run:

```bash
cast status
```

Expected output (abbreviated):

```
CAST v6.0
======================================================================
Agents      30 installed
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

You should see 31 `.md` files. Each file is a fully-configured agent definition with
YAML frontmatter specifying the model, memory, and thinking budget for that specialist.

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
