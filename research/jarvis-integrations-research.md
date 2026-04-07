# JARVIS Integrations Research
**Date:** 2026-04-06
**Scope:** 5 integration topics for macOS Apple Silicon personal assistant

---

## 1. Strava MCP Server

### Recommendation: `r-huijts/strava-mcp`
The best-maintained option with 25 tools covering all major Strava data surfaces.

### What data is available
- **Activities:** Recent activities, filtered queries, detailed analysis, lap breakdowns
- **Streams (time-series):** Heart rate, pace, altitude, cadence, power, GPS
- **Stats:** YTD and all-time totals, personal records, activity type summaries
- **Segments:** Starred segments, leaderboard data, effort tracking
- **Routes:** Saved routes, GPX/TCX exports
- **Profile:** Athlete profile, shoe tracking, training zones, clubs

### Auth setup (3 steps)
1. Create a free Strava API app at `strava.com/settings/api` — set callback URL to `http://localhost`
2. Add to Claude Code config:
   ```json
   {
     "mcpServers": {
       "strava": {
         "command": "npx",
         "args": ["-y", "@r-huijts/strava-mcp-server"]
       }
     }
   }
   ```
3. Restart Claude, then say "Connect my Strava account" — a browser window opens for OAuth flow. Tokens are cached locally after first auth.

### Rate limits
Strava API v3 defaults: **200 requests per 15 minutes**, **2,000 requests per day**. For a personal assistant polling occasionally, this is a non-issue. HTTP 429 is returned if exceeded; resets at 0/15/30/45 minutes past the hour and midnight UTC.

### COROS compatibility
COROS syncs to Strava automatically. Any activity completed on the COROS watch will be available via Strava API once synced — no direct COROS API integration needed.

### Gotchas
- Strava OAuth tokens expire; the MCP server handles refresh automatically
- Activity streams (raw time-series data) can be large; `r-huijts` compresses payload by 70-80%
- Private activities are accessible (it's your own account via OAuth)
- Strava API is **read-only for personal apps** — you cannot create activities via API without "upload" scope and a file

---

## 2. Todoist MCP Server

### Recommendation: `greirson/mcp-todoist`
19 tools, full CRUD, bulk operations, subtasks, labels, reminders, dry-run mode. The most complete community server. The official `Doist/todoist-ai` is HTTP-only and requires OAuth browser flow — overkill for personal use.

### What tools it exposes

| Category | Count | Operations |
|----------|-------|------------|
| Tasks | 9 | create, get, update, complete, delete, quick-add, bulk complete, bulk delete |
| Subtasks | 5 | create, list, complete, convert to task, batch operations |
| Projects | 4 | create, list, update, delete |
| Labels | 5 | create, list, apply, remove, analytics |
| Reminders | 4 | create, list, delete (Pro/Business plan required) |
| Comments | 2 | add to task, add to project |
| Testing | 3 | connection validation, performance check |

**Full CRUD on tasks: yes.** Supports due dates (natural language like "next Friday"), priorities (p1-p4), labels, projects, sections.

### Setup steps (Claude Code)

1. Get API token: Todoist → Settings → Integrations → Developer → Copy API token

2. Add server:
   ```bash
   claude mcp add todoist -e TODOIST_API_TOKEN=your_token -- npx @greirson/mcp-todoist
   ```

3. Or add to `~/.claude/claude_code_config.json` (for persistent config):
   ```json
   {
     "mcpServers": {
       "todoist": {
         "command": "npx",
         "args": ["-y", "@greirson/mcp-todoist"],
         "env": {
           "TODOIST_API_TOKEN": "your_token_here"
         }
       }
     }
   }
   ```

4. Enable dry-run mode while testing by adding `"DRYRUN": "true"` to env — validates against real data without mutating.

### Natural language examples that work
- "Add task: write weekly review, due Sunday, priority 1, label @deep-work"
- "Complete all tasks due today"
- "What tasks do I have in the Work project?"
- "Create subtasks for 'Launch JARVIS': OAuth setup, test briefing, schedule cron"

### Gotchas
- Reminders require Todoist Pro ($4/mo) — free plan has no reminders
- `quick-add` parses natural language dates but is less reliable than explicit ISO dates
- No recurring task creation via MCP (Todoist's recurrence syntax is complex; manage via Todoist app)
- API token is long-lived (does not expire) — store securely, not in plaintext config

---

## 3. macOS Text-to-Speech for Briefings

### Recommendation: macOS `say` with a downloaded Premium voice
Zero dependencies, works offline, already installed. Siri-quality voices are available for free download.

### Best voices available
Run `say -v ?` to list installed voices. Download premium voices at:
**System Settings → Accessibility → Spoken Content → System Voice → Customize**

Top recommendations for briefings:
| Voice | Language | Quality | Notes |
|-------|----------|---------|-------|
| **Siri (voice 2)** | en-US | Best | Neural, requires system voice setting |
| **Zoe (Premium)** | en-US | Excellent | Download ~300MB, available via `say -v Zoe` |
| **Samantha (Enhanced)** | en-US | Good | Smaller download, natural cadence |
| **Daniel (Enhanced)** | en-GB | Good | British accent, calm tone |

The Siri voice requires setting it as system voice in Accessibility first — then `say` uses it automatically. All other downloaded premium voices work directly with `say -v VoiceName`.

### Key commands for briefings

```bash
# Speak text directly
say -v Zoe "Good morning. Here is your briefing."

# Read a text file
say -v Zoe -f /path/to/briefing.txt

# Save to audio file (M4A recommended over AIFF for size)
say -v Zoe -f /path/to/briefing.txt -o ~/Desktop/briefing.m4a

# Control rate (default ~180 wpm; 150 is comfortable for briefings)
say -v Zoe -r 150 "Your briefing content here"
```

### Markdown preprocessing (required)
`say` reads markdown literally — it will say "hashtag hashtag Good morning" for `## Good morning`. Strip markdown before passing to `say`:

```bash
# Simple sed-based strip (good enough for briefings)
strip_md() {
  sed 's/^#\+ //g' "$1" |        # Remove heading markers
  sed 's/\*\*\(.*\)\*\*/\1/g' |  # Remove bold
  sed 's/\*\(.*\)\*/\1/g' |      # Remove italic
  sed 's/^[-*] //g' |            # Remove list markers
  sed 's/`[^`]*`//g'             # Remove inline code
}

strip_md briefing.md | say -v Zoe -r 150
```

Or use Python's `markdown` → `html2text` pipeline for cleaner output on complex notes.

### Saving audio files
```bash
# Save as M4A (compressed, good for sharing/archiving)
say -v Zoe -f briefing.txt -o ~/briefings/morning-$(date +%Y%m%d).m4a

# AIFF is lossless but large (~10MB/min); M4A is ~1MB/min
```

### Better alternatives considered
- **Piper TTS** (open source, runs locally): Higher quality neural voices, runs on Apple Silicon. More setup. Worth evaluating for v2.
- **OpenAI TTS API**: Excellent quality (tts-1-hd), costs ~$0.03/1K characters. Good for occasional use. Not offline.
- **ElevenLabs**: Best quality, but $5+/mo and requires internet.

**Decision:** Start with `say -v Zoe`. It is free, offline, no API key, and good enough for morning briefings. Upgrade to Piper or OpenAI TTS if quality is unsatisfactory.

### Gotchas
- macOS 15 Sequoia moved voice downloads to VoiceOver Utility (VO + Fn + F8 → Speech → Voices → Add)
- Premium voices are 100-300MB downloads per voice
- MP3 output not supported natively; use ffmpeg to convert: `ffmpeg -i briefing.m4a briefing.mp3`
- `say` blocks the terminal while speaking; use `say ... &` to run in background

---

## 4. Obsidian MCP Server

### Recommendation: Direct filesystem write (no MCP needed for briefings)
For the specific use case of writing briefings to the Obsidian vault, the simplest approach is **writing markdown files directly to the vault directory**. Claude Code already has the Write tool — no MCP server required.

### When to use MCP vs. direct write

| Use Case | Approach |
|----------|----------|
| Write daily briefing note | Direct Write tool to vault path |
| Append to existing note | MCP (`append_content`) or direct file append |
| Search across vault | MCP server required |
| Read/query existing notes | MCP server required |
| Create Daily Note with correct filename | Direct Write to `vault/Daily Notes/YYYY-MM-DD.md` |

### Obsidian MCP option: `MarkusPfundstein/mcp-obsidian`
If search/read capabilities are needed, this is the most established option.

**Requires:** [Obsidian Local REST API plugin](https://github.com/coddingtonbear/obsidian-local-rest-api) (free, community plugin)

**Tools exposed:**
1. `list_files_in_vault` — browse vault structure
2. `list_files_in_dir` — list specific directory
3. `get_file_contents` — read any note
4. `search` — full-text search across all notes
5. `patch_content` — insert at heading/block reference
6. `append_content` — append to new or existing file
7. `delete_file` — remove file or directory

**Setup:**
1. In Obsidian: Settings → Community plugins → Browse → "Local REST API" → Install + Enable
2. Copy the API key from plugin settings
3. Add to Claude config:
   ```json
   {
     "mcpServers": {
       "obsidian": {
         "command": "npx",
         "args": ["-y", "mcp-obsidian"],
         "env": {
           "OBSIDIAN_API_KEY": "your_api_key",
           "OBSIDIAN_HOST": "127.0.0.1",
           "OBSIDIAN_PORT": "27124"
         }
       }
     }
   }
   ```

### Daily Notes integration (direct write approach)
Obsidian's Daily Notes plugin uses the pattern `YYYY-MM-DD.md` in a configurable folder (default: `Daily Notes/`). Claude can write directly:

```bash
# Example path for a briefing as Daily Note
VAULT_PATH="$HOME/Documents/Obsidian/MyVault"
DATE=$(date +%Y-%m-%d)
BRIEFING_PATH="$VAULT_PATH/Daily Notes/$DATE.md"
```

The Write tool or a CAST agent can write the full markdown briefing to this path. Obsidian will pick it up automatically — no restart needed, Obsidian watches the filesystem.

### Gotchas
- Obsidian REST API plugin requires Obsidian to be **running** — MCP calls fail if Obsidian is closed
- Direct filesystem write works even when Obsidian is closed (and syncs when opened)
- YAML frontmatter (`---` blocks) must be valid or Obsidian shows parse errors
- `cyanheads/obsidian-mcp-server` is more feature-rich (tags, frontmatter management) but heavier setup

---

## 5. Backup Solutions

### Recommended Strategy: 3-2-1 layered approach

| Layer | Tool | Target | Cost |
|-------|------|--------|------|
| Local continuous | Time Machine | External SSD | Free (drive cost) |
| Cloud encrypted | Arq 7 + Backblaze B2 | All critical dirs | ~$3.50/mo |
| Config versioned | Git | `~/.claude/` | Free |
| Obsidian sync | Obsidian Git plugin | Private GitHub repo | Free |

### What to back up

```
~/.claude/                  # Agents, memory, plans, briefings, cast.db
~/Documents/Obsidian/       # Vault
~/Projects/                 # All code
~/.ssh/                     # SSH keys (encrypted separately)
~/.zshrc, ~/.gitconfig      # Dotfiles
```

### Layer 1: Time Machine (already built in)
Time Machine backs up everything hourly to an external drive. No setup beyond attaching drive and selecting it in System Settings → General → Time Machine.

**Limitation:** Requires the drive to be physically connected. Not useful for laptop away from home.

### Layer 2: Arq + Backblaze B2 (best cloud option)
**Arq 7** ($49.99 one-time) is the best macOS backup client. Features:
- Zero-knowledge AES-256 encryption (password never leaves your machine)
- Backs up to Backblaze B2, S3, Wasabi, local drives, network shares
- Incremental deduplication — only changed blocks uploaded
- File versioning with configurable retention
- Scheduled hourly/daily runs, runs silently in background

**Backblaze B2 cost:** $0.006/GB/mo. For 50GB of `~/.claude/` + Obsidian + dotfiles: ~$0.30/mo. For full Projects (~200GB): ~$1.20/mo.

**Setup:**
1. Buy Arq 7 from arqbackup.com
2. Create Backblaze account at backblaze.com → B2 Cloud Storage → Create Bucket
3. Generate Application Key in Backblaze
4. In Arq: Add Storage Location → Backblaze B2 → paste key ID + app key
5. Add backup plan: select paths, set encryption password, schedule hourly

### Layer 3: Git for `~/.claude/` config
`~/.claude/` contains agents, rules, skills, plans, scripts — all plain text and suitable for git.

**Setup:**
```bash
cd ~/.claude
git init
# Create .gitignore to exclude sensitive files:
cat > .gitignore << 'EOF'
cast.db          # SQLite DB (large, binary, use Arq instead)
cast/events/     # High-volume event logs
logs/            # Verbose logs
*.key            # Any key files
.env             # Environment files
EOF
git add agents/ rules/ skills/ scripts/ plans/
git commit -m "Initial CAST config backup"
# Add private GitHub remote:
gh repo create cast-config --private
git remote add origin git@github.com:ek33450505/cast-config.git
git push -u origin main
```

**What to include in git:** agents/, rules/, skills/, scripts/, plans/, briefings/ (markdown only)
**What to exclude from git:** cast.db, event logs, any file with API keys

### Layer 4: Obsidian Git plugin
Install the "Obsidian Git" community plugin. It commits and pushes vault changes to a private GitHub repo on a schedule (default: every 5 minutes or on file save).

**Setup:**
1. Create private GitHub repo: `gh repo create obsidian-vault --private`
2. Init git in vault: `cd ~/Documents/Obsidian/MyVault && git init && git remote add origin ...`
3. In Obsidian: Settings → Community plugins → Obsidian Git → Enable
4. Configure: auto-commit interval 10 minutes, push on commit: yes

### Encryption considerations

| Data | Sensitivity | Recommendation |
|------|-------------|----------------|
| cast.db | Medium — contains agent runs, session data | Arq encrypts in transit/at rest; exclude from git |
| agent-memory-local/ | Medium — personal context | Arq encrypted backup; ok in private git |
| ~/.claude/scripts/ | Low — bash scripts | Fine in private git |
| API keys / .env | High | Never commit; use macOS Keychain; Arq-only backup |
| SSH keys | High | Arq only, never git |

**Keychain for API keys:** All CAST API keys should be in macOS Keychain (CAST v4.5 already enforces this). `cast.db` contains no raw keys — safe to back up encrypted.

### Automating backups via CAST
Arq runs autonomously on a schedule — no CAST involvement needed. For git-based backups, a CAST `devops` agent can be scheduled via cron:

```bash
# Add to crontab (crontab -e):
0 */6 * * * cd ~/.claude && git add -A && git commit -m "Auto-backup $(date)" && git push origin main 2>/dev/null
```

Or create a CAST scheduled task that calls a `bash-specialist` agent to commit and push `~/.claude/` every 6 hours.

### Gotchas
- `cast.db` is a binary SQLite file — git will store the full file on every change, ballooning repo size. Exclude from git, use Arq for this.
- Obsidian Git can conflict with Obsidian Sync if both are enabled — use one or the other for cloud sync.
- Backblaze B2 has no egress fees for Arq (Arq negotiated free egress with B2).
- Time Machine excludes paths listed in `~/.tmignore` — add `node_modules/` and build dirs.
- iCloud Drive is not recommended for `~/.claude/` — it does not handle SQLite WAL files well and can corrupt cast.db.

---

## Summary: Quick Decision Matrix

| Topic | Chosen Option | Effort | Cost |
|-------|--------------|--------|------|
| Strava | `r-huijts/strava-mcp` (25 tools, OAuth) | 15 min | Free |
| Todoist | `greirson/mcp-todoist` (19 tools, full CRUD) | 10 min | Free |
| TTS | `say -v Zoe` with markdown strip | 5 min | Free |
| Obsidian | Direct Write tool + MCP for search | 20 min | Free |
| Backup | Time Machine + Arq/B2 + Git | 1 hr | ~$50 one-time + $0.30/mo |

---

## Sources

- [r-huijts/strava-mcp — 25 tools](https://github.com/r-huijts/strava-mcp)
- [MariyaFilippova/mcp-strava](https://github.com/MariyaFilippova/mcp-strava)
- [Strava API Rate Limits](https://developers.strava.com/docs/rate-limits/)
- [greirson/mcp-todoist — 19 tools](https://github.com/greirson/mcp-todoist)
- [Doist/todoist-ai — official](https://github.com/Doist/todoist-ai)
- [abhiz123/todoist-mcp-server](https://github.com/abhiz123/todoist-mcp-server)
- [macOS TTS voices in Sequoia](https://speechcentral.net/2025/02/12/how-to-install-tts-voices-in-macos-15-sequoia/)
- [say command audio file export](https://medium.com/@fonto.design/how-to-generate-a-text-to-speech-audio-file-in-macos-with-ai-siri-voice-13230c810969)
- [Piper TTS on macOS](https://www.thoughtasylum.com/2025/08/25/text-to-speech-on-macos-with-piper/)
- [MarkusPfundstein/mcp-obsidian](https://github.com/MarkusPfundstein/mcp-obsidian)
- [cyanheads/obsidian-mcp-server](https://github.com/cyanheads/obsidian-mcp-server)
- [Arq backup pricing and features](https://www.arqbackup.com/pricing/)
- [Obsidian backup recommendations](https://help.obsidian.md/backup)
