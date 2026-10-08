#!/usr/bin/env python3
"""
cast-command-guard.py — PreToolUse Bash command-guard backend (CAST).

The command-layer analogue of write-guards.py: where write-guards protects the
filesystem WRITE surface (Write/Edit tool), this protects the Bash COMMAND surface
(Bash tool). It blocks two classes of catastrophic command BEFORE the shell runs:

  RULE 1 — PROCESS-KILL (pkill / killall):
    Any command-position `pkill` or `killall` is blocked. These take patterns/names
    and routinely nuke far more than intended (e.g. `pkill -9 bash` kills the whole
    session). Escape hatch: prefix the SEGMENT with `CAST_KILL_OK=1`.

  RULE 2 — MASS KILL (`kill` of a process group / all processes):
    A command-position `kill` whose TARGET is `0`, `-1`, or any negative integer
    (`-<n>` process-group form, including `kill -- -<n>`) is blocked — these signal
    an entire process group / every process. Plain `kill <pid>`, `kill -9 <pid>`,
    `kill -0 "$VAR"` etc. are ALLOWED (test-runner's timeout guard depends on them).
    Escape hatch: `CAST_KILL_OK=1`.

  RULE 4 — WORKFLOW-WRITE VIA BASH REDIRECTION:
    A Bash command that WRITES under `.github/workflows/` via output redirection
    (`>`, `>>`, fd-numbered forms like `2>`, `1>>`) or a `tee` sink is blocked — it
    evades the `workflows-require-devops` Write/Edit policy (a workflow agent used
    `tee` to bypass the gate on 2026-07-04). Detection is write-only: input
    redirects (`<`) and plain reads (`cat`/`grep` of a workflow file) are NEVER
    blocked. Target paths are matched by the `.github/workflows/` marker, so
    absolute, repo-relative, and `$PWD`-composed targets are all caught. There is
    NO escape hatch here — route the change through the devops agent (edit via the
    Write/Edit tool so the policy gate applies).

  RULE 3 — CATASTROPHIC rm (recursive rm of a protected root):
    A command-position `rm` with a recursive flag (-r/-R/--recursive or a combined
    short flag containing r, e.g. -rf) whose TARGET is a protected path is blocked.
    Two protected-path tiers (see PROTECTED PATHS below):
      EXACT-only — block only on an exact match: `/`, `.`, `..`, `~`, `$HOME`,
        `${HOME}`, the resolved absolute home, and the root-glob wipe forms `/*`,
        `/.*` (which expand to every top-level entry, as catastrophic as `/`).
      SUBTREE — block on exact match OR as a parent: `~/.claude`, `$HOME/.claude`,
        `${HOME}/.claude`, and the resolved-home `.claude`.
    Other home subpaths are ALLOWED (`rm -rf ~/Projects/x/node_modules`,
    `rm -rf ~/.cache/pip`, `rm -rf ~/.cast-worktrees/wt-1`) — only the home ROOT and
    the `.claude` subtree are protected, so the guard does not train agents to
    reflexively reach for the escape hatch. Escape hatch: `CAST_RM_OK=1`.

  RULE 5 — WRITE / MOVE / LINK / CHMOD / DELETE OF THE INSTALLED EXEC SURFACE (U6e):
    Git hooks now run from `~/.claude/githooks` and call `~/.claude/scripts`; the Edit/Write
    TOOLS are denied there, but Bash was not (only a RECURSIVE `rm -r[f]` of the .claude
    subtree was blocked). RULE 5 blocks a Bash command that WRITES, MOVES, LINKS, CHMODs /
    CHOWNs or DELETES (recursive or not) a path under the PW roots below -- or the roots
    themselves (renaming / replacing the directory):
        ~/.claude/githooks/   ~/.claude/scripts/   ~/.claude/config/
        ~/.claude/install-manifest.sha256
        ~/.claude/cast-state                (pyc-verification snapshot + state files that only
                                             HOOKS write; hooks do not pass through this guard)
        ~/Library/Caches/com.apple.python   (macOS python bytecode cache: a forged .pyc there is
                                             loaded for installed scripts)
        ~/Library/Python                    (user site-packages / sitecustomize)
        ~/Library/LaunchAgents              (launchd plists = persistence)
    (`ls`/`cat`/`plutil -p`/`cp FROM` of those stay allowed; `launchctl load` names the path and
    blocks.)
    FAIL-CLOSED (inverted) DEFAULT: a command that is not on the READ/EXEC allowlist
    (_PW_READERS, a per-command SPEC TABLE audited against man pages: cat/ls/grep/diff/cmp/
    shasum/jq/echo/printf/test/sed/awk without -i ...) and
    has no dedicated handler below is assumed to WRITE whatever protected path appears in ANY
    of its arguments -- including `--opt=PATH`, `of=PATH`, `-C/path` and each word of a quoted
    command string -- so an unlisted wrapper (`arch`, `caffeinate`, `setsid`, `su -c`,
    `sandbox-exec`, `script`, `exec -a`), editors (`vim -es`), `mkfifo`, `zip`, `split`, `cpio`,
    `pax`, `sqlite3`, `defaults write`, `plutil -replace`, `git clone|init|checkout-index|
    worktree` into a root are all caught without being listed. Interpreters (python/node/perl/
    ruby/php...) may RUN a protected script (argv[1] is read) but a protected path as any
    other operand blocks; `bash -n`, `source`/`.`/`bash <installed script>`, `plutil -p|-lint`,
    git read subcommands (`diff|log|show|status|config|add|commit ...`) and `cp|rsync|ditto|tar
    -c` FROM a protected path stay allowed. A redirect INTO a root blocks for every command.
    STRICT READERS: an allowlisted command is a reader only while every option it is given is
    one it is KNOWN to accept. `nowrite` entries (cat, ls, grep, diff, cmp, shasum, jq, echo,
    printf, test, builtins ... audited against man/--help) have no option that writes, so every
    operand is a read. Entries that CAN write or run a string (sort, uniq, xxd, sdiff, tree, rg,
    file, sed, awk) declare their COMPLETE option set with exact arity (re-derived from --help on
    this machine; long options resolve by GNU unique prefix: `sort --outp P` is `--output`); an
    option that is unknown, ambiguous or of the wrong arity makes the segment LOSE reader status
    and it falls to the generic fail-closed path. Declared write slots (`sort -o|-T|--output|
    --temporary-directory`, `sdiff -o`, `tree -o`), output operands (`uniq in OUT`, `xxd in OUT`:
    every operand after the first), writer flags (`file -C`) and command-string options (`rg
    --pre|--hostname-bin`, `sort --compress-program`, `sdiff --diff-program`) are checked. less/more
    (`-o -O --log-file --LOG-FILE`; `+cmd` start-up commands are program text), bat (`--pager`;
    `bat cache` is a writer), yq (`-i -s`) and ag (`--pager`) are tabled; yq and ag are not
    installed here, so their tables come from documentation and are PARTIAL -- a missing option
    only drops the segment to the generic path, it can never make a write look like a read. Not
    allowlisted (cannot be characterised confidently): ack, mdls, lsof, most, colordiff, xargs.
    STRING-CARRYING BUILTINS are not pure readers: alias, set, declare, typeset, local, readonly,
    export, read, hash, for/select/case headers (and echo/printf when the command also holds a
    sink that can run text: a shell, eval, source, xargs, an interpreter, `"$@"`) block when an
    operand holding whitespace or shell metacharacters mentions a root (`alias w='cp a P'`,
    `case 'cp a P' in`, `echo 'cp a P' | bash`); a plain path operand is data. Tracked values --
    `X='cp a P'`, `declare|local|readonly X=..`, `read X <<< ..`, `printf -v X ..`, `for c in ..`,
    and the positional parameters of `set -- cp a P` -- are expanded when they reappear as a
    command word, an `eval` operand, a `-c` payload or `"$@"`. A `$(..)`/backtick body inside an
    assignment value that mentions / names / resolves to a root marks the value protected. Quoted
    globs (`'cp a ~/.claude/s*/x'`) and quote splices (`s'"'"'cripts`) are resolved by the
    mention scan. PYTHONPATH is exempt like PATH (selection, not a destination), and
    environment-insensitive strict readers (uniq, xxd, tree, rg, file, sed, awk, bat, ag) ignore a
    protected env VALUE, but not a command-string variable.
    MENTION SCAN: for anything that is not a strict reader's pure read operand, a protected root
    named ANYWHERE inside a word blocks -- after the same normalisation words get ($HOME, `~`,
    the passwd / real home, the APFS firmlink prefix, case, `//` `/./` `..`). That covers option
    values, quoted command strings, environment values, `sed 'w$HOME/..'`, `awk '{print > ".."}'`
    and interpreter code (`python3 -c "open('/Users/testuser/.claude/scripts/y','w')"`).
    ENVIRONMENT: command-string variables (PS4, PROMPT_COMMAND, BASH_ENV, ENV, LESSOPEN,
    LESSCLOSE, PAGER, MANPAGER, GIT_PAGER, EDITOR, VISUAL, GIT_EDITOR, GIT_SEQUENCE_EDITOR,
    GIT_EXTERNAL_DIFF, GIT_SSH[_COMMAND], GIT_ASKPASS, SSH_ASKPASS, FCEDIT, *_COMMAND, *_CMD,
    *_PAGER, *_EDITOR, *_ASKPASS) have their VALUE scanned as a SCRIPT. For EVERY other variable
    (no name list), a value that mentions / is inside / is an ANCESTOR of a root (`~/.claude`, `~`,
    `/`, the home's parents) blocks -- in `VAR=val cmd`, `env`/`sudo VAR=val cmd`,
    `export|declare -x|typeset -x VAR=val`, and `set -a` -- unless the command is a nowrite reader.
    Assignments are tracked in any order and form (`declare|readonly|local X=P; export X`,
    `export X; X=P`, `printf -v X %s P; export X`, `X+=P`, `env -S'X=P cmd'`). PATH is exempt (it
    selects what to RUN; a planted binary would first need a write into a root, which is blocked).
    `python -X pycache_prefix=DIR` is a write slot.
    GIT: `-C X`, `--git-dir X`, `--work-tree X` (and the `=` forms, GIT_DIR=, GIT_WORK_TREE=) that
    name a root OR an ancestor block for every subcommand except status/diff/log/show/ls-files/
    rev-parse/cat-file/grep/blame.
    ANCESTORS of the roots (`~/.claude`; also `~`, its parents and `/` for the tools below) are
    protected against merge / extract / delete: `cp -R|-a`, `rsync -a`, `ditto`, `tar -x -C`,
    `unzip -d`, `cpio`/`pax`, `find ... -delete|-exec`, `rm -r`, `chmod|chown|chflags -R`, a
    `mv` whose source is (or may be) a root's name, and an unknown command given `-r|-R|-a`.
    Detected: output redirection (`>` `>>` `>|` `&>` `>&file` `<>` `n>`); `tee`/`sponge`;
    `cp`/`mv`/`install`/`rsync`/`ditto` with a protected DEST (or `-t DIR`), and `mv` of a
    protected SOURCE away; `ln` with a protected link NAME; `rm`/`unlink`/`rmdir`/`shred`;
    `chmod`/`chown`/`chgrp`/`chflags`/`xattr -w|-d|-c`/`touch`/`truncate`; in-place `sed -i`
    (`gsed`), `perl -i`, `ruby -i`, `awk -i inplace`, `ed`/`ex`, `patch`; `dd of=`;
    `curl -o`/`wget -O|-P`; `find <protected> ... -delete|-exec <non-reader>|-fprint*`;
    `tar -x` / `unzip -d` into a protected dir; `tar -c -f <protected>`. Parent: `~/.claude`
    ITSELF is protected against move / link-over / non-recursive rm / recursive chmod.
    READS stay allowed: `cat`/`ls`/`cmp`/`diff`/`grep`/`head`/`shasum`, `cp`/`rsync`/`tar -c`
    FROM a protected path, `source`/`bash <installed script>`, and `bash install.sh` (the
    deploy path; its internal writes are not command-line visible).
    Resolution mirrors the shell: quotes, backslash / backslash-newline, `~`, `$HOME`,
    `${HOME}`, `$'..'`, brace expansion (`~/.claude/{scripts,config}`), globs (`~/.claude/scr*`),
    bracket classes (`~/.claude/[s]cripts`, `[a-z]`, `[!x]`, `[[:lower:]]`) -- also against the
    tracked cwd (`cd ~/.claude/scripts && rm *`, `rm [a-z]*`, `rm ?`) -- and a dynamic tail
    (`~/.claude/scripts/$X`); `.`/`..`/`//` are collapsed; the APFS firmlink prefix
    `/System/Volumes/Data` is stripped (realpath() does not resolve it); matching is
    CASE-INSENSITIVE (APFS); `$HOME`, `~`, the passwd home and the realpath of each are all
    protected, so an absolute `/Users/<user>/.claude/...` is caught even when $HOME was
    redirected; a write THROUGH a symlink that already exists (`/tmp/s -> ~/.claude/scripts`)
    is followed by realpath. Wrappers (`sudo`/`env`/`nice`/`timeout`/`xargs`/`command`/
    `exec`/`nohup`/`time`/`busybox`, `env -S 'cmd'`), `bash -c '..'`/`eval '..'`/`trap '..'`
    payloads (3 levels deep; deeper is refused; bash options that take an operand --
    `-o X` `+o X` `-O X` `--rcfile X` `--init-file X` `-eo pipefail` `--` -- are skipped to
    find the payload; fish/csh/tcsh/ash/busybox sh too), a here-string (`bash <<< '..'`),
    `source <(echo '..')`, a heredoc FED TO A SHELL (`bash <<EOF`, `cat <<EOF | sh` -- unlike
    `cat > f <<EOF`, whose body stays inert data), `$(..)`/backtick/`<(..)`/`>(..)` bodies,
    leading `do`/`then`/`!` keywords, `~user` (passwd lookup), parameters assigned earlier in
    the SAME command (`D=~/.claude; echo x > "$D/scripts/x"`, `export`/`declare`, and `for f in
    ~/.claude/scripts/*; do rm "$f"`), and literal `cd`/`pushd` (a relative target resolves
    against the tracked cwd; the hook process cwd is the starting point) are followed. A dynamic word (`$VAR`, `$(..)`, glob) is blocked when its STATIC prefix
    already points at a protected root (`~/.claude/scripts/$X`, `~/.cl*/scripts/x`) or it
    spells a protected name after an unknown prefix (`"$D/.claude/scripts/x"`).
    Escape hatch: prefix the SEGMENT with `CAST_PROTECTED_WRITE_OK=1` (segment-scoped, like
    the others; NOT recorded -- this module records no hatch use). `CAST_RM_OK=1` ALSO
    exempts a RECURSIVE `rm` (RULE 3's hatch already authorises that act); every other
    shape needs the new hatch.
    TEXT-RUNNER RULE (the last structural rule): if ANY segment of the command executes TEXT -- its
    command word, after unwrapping `command`/`env`/`nohup`/`timeout`/`exec`/`time`/`nice`/`sudo`, is
    dynamic (`$X`, `${X:-}`, `"$@"`, `$*`, `$(..)`, backtick), or it is `eval` / `source` / `.` /
    a shell with `-c` -- AND any assignment value, `+=` value, `m[k]=` / `arr=(..)` element, or
    `declare|typeset|local|readonly|export|read|set|for|alias|printf -v` operand ANYWHERE in the
    command mentions a protected root, the command BLOCKS, whatever the variable name, modifier,
    IFS trick or array form. Accepted false positive: `X=~/.claude/scripts; $X`.
    FINAL RESIDUALS -- accepted, NOT detected (each is a property of analysing a command STRING):
      1. code that never spells a root in one piece or builds it at runtime (`python3 -c
         "open(h+'/.claude/scripts/x','w')"`), any script FILE that writes (its body is invisible),
         `python3 <<EOF` (a heredoc into a non-shell is inert text), `ssh host '..'`;
      2. a path taken from a source the lexer cannot read: `read X < file`, command output, an
         inherited / exported environment, a function argument, a variable assigned in an EARLIER
         Bash call (`read` leaves the value unknown);
      3. a link that does not exist yet: `ln -s ~/.claude/scripts /tmp/s; echo x > /tmp/s/x` in ONE
         command, or a HARD link made elsewhere (a link that already exists IS followed, bounded to
         PW_MAX_REALPATH lookups per command);
      4. data arriving on a pipe or stdin from anything but `echo`/`printf` (`cat file | bash`,
         `ls ~/.claude/scripts | xargs rm`, `find .. | while read f; do rm "$f"; done`);
      5. `cd` done in an EARLIER Bash call whose cwd differs from the hook process cwd;
      6. `git -c <exec-key>=..` (core.pager etc. belong to the git guard) and `cd <root> && git
         add|commit` (a root is not a git repository here);
      7. package managers that write into ~/Library/Python without naming it: `pip install --user`,
         `python3 -m pip install ..`, `pipx`, `uv pip`, Apple-python plain `pip install` (blocking
         them would break normal development; pinned ALLOW);
      8. aliases / functions / PATH shadowing defined in an earlier call or a shell rc file, tools'
         own config files, and anything else that changes what a command DOES without appearing in
         the string (PATH and PYTHONPATH values are exempt by design);
      9. expansion limits: more than 16 brace groups / 256 alternatives in one word degrade to a
         wildcard, more than 3 nested shells are refused (blocked), 1000 realpath lookups per command;
     10. the yq / ag option tables are partial (tools not installed here): an unlisted option only
         drops the segment to the generic fail-closed path.
    BOUNDARY: this rule is DEFENCE-IN-DEPTH FOR SANDBOX-OFF. The hard boundary is the sandbox
    (allowWrite limited to /tmp-class paths); DETECTION of what slips past a string guard is the
    U6d integrity alarm. Escape hatch for a deliberate operation: CAST_PROTECTED_WRITE_OK=1.

PROTECTED PATHS
  - EXACT-only roots: '/', '.', '..', '~', '$HOME', '${HOME}', resolved-home, '/*', '/.*'
  - SUBTREE bases:    '~/.claude', '$HOME/.claude', '${HOME}/.claude', resolved-home/.claude

DESIGN NOTES
  - Command-position aware: a token only counts as a command if it begins the string
    or follows a shell separator (newline ; & | ( ) { ` ). A mention inside a quoted
    string (e.g. `echo "use pkill"`) is NOT a command and is never matched.
  - Command-substitution is caught (fail-closed): both `$(...)` (via the `(`
    separator) and backticks `` `...` `` are split so a kill/rm in command position
    inside them is detected.
  - Heredoc bodies are SKIPPED: a `<<WORD` / `<<-WORD` / `<<'WORD'` body is inert
    data, so its lines are stripped before scanning (agents legitimately write hook /
    teardown scripts whose bodies contain `rm -rf "$HOME/..."` or `pkill`). A command
    OUTSIDE the heredoc still scans normally. Heredoc detection is QUOTE/COMMENT-AWARE:
    only an UNQUOTED `<<WORD` that occurs before any unquoted word-boundary `#` comment
    opens a heredoc — a `<<WORD` inside quotes (`echo '<<EOF'`), after a comment
    (`# <<EOF`), or as a here-string `<<<WORD` (three `<`) is inert and does NOT open
    one, so a real `rm`/`pkill` on a later line is still scanned and blocked.
  - Attached redirects are SPLIT OFF target tokens: `rm -rf ~/.claude>x` is one token
    (`~/.claude>x`); the unquoted trailing `>x` is stripped so the protected-path check
    sees `~/.claude`. A quoted `>`/`<` inside a token (a literal filename char) is kept.
  - Leading shell RESERVED WORDS are skipped for EVERY rule (SHELL_KEYWORDS: `do` `then` `else`
    `elif` `if` `while` `until` `!` `{` `}` `coproc`), so `for x in 1; do rm -rf ~/.claude; done`,
    `if ..; then pkill ..; fi`, `! rm -rf ..`, `while rm ..; do` and `coproc rm ..` expose the real
    command (the keyword used to BE the command word and hid it). Function / group / subshell /
    `case` bodies are scanned as ordinary segments (`{`, `(`, `)` already split), so
    `f() { rm -rf ~/.claude; }; f` is caught at the definition.
  - Command wrappers `command`/`exec`/`nohup`/`time` are unwrapped (the next token is
    the real command); a leading backslash (`\\pkill`) is stripped. `sudo`, `env`,
    `xargs`, and non-HOME-variable indirection remain OUT OF SCOPE (fail-open) — this
    is LITERAL-PATH defense-in-depth, not a complete sandbox. The guard matches literal
    protected paths and the resolved $HOME; other variables (e.g. $TEST_HOME) are not
    resolved and therefore not protected, by design.
  - KNOWN OUT-OF-SCOPE EVASION (documented, NOT fixed): nested ESCAPED-backtick command
    substitution -- an inner backtick layer escaped with backslashes inside an outer
    backtick subst, e.g. an assignment whose value is a backtick subst that itself wraps
    an escaped-backtick pkill -- is not split into its inner command, so a kill/rm hidden
    in that escaped layer is not detected. Same deliberate-evasion class as
    sudo/env/xargs/non-HOME-variable indirection -- acceptable for literal-path
    defense-in-depth, not a complete sandbox.
  - KNOWN OUT-OF-SCOPE EVASION (documented, NOT fixed): heredoc detection tracks quote
    state per LINE, not across lines. A multi-line command that opens a quote on one
    line and never closes it, with a fake `<<WORD` on a continuation line, can make a
    real `rm`/`pkill` on a still-later line look like heredoc body and be skipped. Same
    deliberate-evasion class as above (no agent emits this by accident); the accidental
    and improvised catastrophes the guard targets (e.g. `pkill -9 bash`, `rm -rf
    ~/.claude`) are still caught.
  - The escape hatch is PER-SEGMENT: `CAST_KILL_OK=1`/`CAST_RM_OK=1` exempts only the
    segment carrying it as a leading VAR= assignment, never the whole command line.
  - CLAUDE_SUBPROCESS=1 (managed / headless sub-claude) is skipped in the .sh wrapper,
    consistent with the other CAST guards. In-process Agent-tool subagents do NOT set
    that flag and ARE guarded.
  - FAIL-OPEN: any internal error → exit 0 (allow). A guard crash must never block all
    Bash. Exit 2 = block, 0 = allow.
"""
import fnmatch
import json
import os
import re
import sys
from datetime import datetime, timezone

try:
    import pwd
except ImportError:  # non-POSIX: the passwd-home spelling is simply not added
    pwd = None

# --- token classifiers ---
ENV_ASSIGN = re.compile(r'^[A-Za-z_][A-Za-z0-9_]*=')
NEG_INT = re.compile(r'^-\d+$')
# combined short flag containing r or R: -r, -R, -rf, -fr, -rfv, -fRv ...
RM_RECURSIVE_SHORT = re.compile(r'^-[A-Za-z]*[rR][A-Za-z]*$')
# root-glob wipe forms: /* and /.* (expand to every top-level entry)
ROOT_GLOB = re.compile(r'^/\.?\*$')
# a redirection operator token: >, >>, <, 2>, 1>, 2>> ...  (digits then < or >)
REDIR_RE = re.compile(r'^\d*[<>]')
# a BARE redirect operator token (no filename glued on): >, >>, <, 2>, 1>> ... —
# these consume the FOLLOWING token as their redirect target. `>file`, `2>&1`, `>&2`
# are self-contained and consume no following token.
BARE_REDIR_RE = re.compile(r'^\d*[<>]{1,2}$')
# bare (unquoted) heredoc delimiter word
HEREDOC_WORD_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_-]*")

# per-segment escape hatches (leading VAR= assignment), value 1 (optionally quoted)
KILL_OK_ASSIGN = re.compile(r'^CAST_KILL_OK=["\']?1["\']?$')
RM_OK_ASSIGN = re.compile(r'^CAST_RM_OK=["\']?1["\']?$')

# simple no-option command wrappers: unwrap to the real command word
WRAPPERS = {'command', 'exec', 'nohup', 'time'}

# rm targets protected as EXACT match only (everything lives under these, so
# prefix-matching them would block every absolute / relative path).
EXACT_ONLY_ROOTS = {'/', '.', '..', '~', '$HOME', '${HOME}'}

KILL_MSG = (
    "**[CAST]** Dangerous process-kill blocked "
    "(pkill/killall, or kill of a process group / all processes). "
    "Escape hatch: prefix the command with CAST_KILL_OK=1."
)
RM_MSG = (
    "**[CAST]** Catastrophic `rm -rf` of a protected path blocked. "
    "Escape hatch: prefix the command with CAST_RM_OK=1."
)
WORKFLOW_MSG = (
    "**[CAST]** Writing to .github/workflows/ via Bash redirection (>, >>, | tee) is "
    "blocked — it evades the workflows-require-devops Write/Edit policy. Route the change "
    "through the devops agent and edit via the Write/Edit tool so the policy gate applies."
)

# RULE 4 — workflow-write markers.
# A target path anywhere under `.github/workflows/` — the substring covers absolute,
# repo-relative, and $PWD-composed forms (e.g. `$PWD/.github/workflows/ci.yml`).
WORKFLOW_PATH_MARK = ".github/workflows/"


def load_input():
    """Load and parse the PreToolUse JSON from CAST_CMD_GUARD_INPUT env or stdin.

    Always returns a dict — a non-object JSON value (e.g. `123`, `[1,2,3]`) or a
    parse error yields {} so the caller never crashes on a non-dict payload.
    """
    raw = os.environ.get('CAST_CMD_GUARD_INPUT', '').strip()
    if not raw:
        try:
            raw = sys.stdin.read().strip()
        except Exception:
            raw = '{}'
    try:
        data = json.loads(raw)
    except Exception:
        return {}
    return data if isinstance(data, dict) else {}


def write_log(log_path, message):
    """Append a timestamped line to a log file. Never raises (logging must not break the hook)."""
    try:
        os.makedirs(os.path.dirname(log_path), exist_ok=True)
        with open(log_path, 'a') as f:
            f.write(f"[{datetime.now(timezone.utc).isoformat().replace('+00:00', 'Z')}] {message}\n")
    except Exception:
        pass


def strip_quotes(tok):
    """Remove a single pair of matching surrounding quotes from a token."""
    if len(tok) >= 2 and tok[0] == tok[-1] and tok[0] in ('"', "'"):
        return tok[1:-1]
    return tok


def strip_all_quotes(tok):
    """Strip ALL quote characters from a token.

    Handles mid-token quote-concat (e.g. `$HOME"/.claude"` which the shell expands to
    ~/.claude) that strip_quotes — which only unwraps a whole-token pair — would miss.
    Defense-in-depth, not a full shell parser.
    """
    return tok.replace('"', '').replace("'", '')


def _find_heredoc_words(line):
    """Find heredoc delimiter words introduced on a single line, quote/comment-aware.

    Mirrors tokenize()'s quote-state walk: a `<<WORD` opens a heredoc ONLY when its
    `<<` occurs OUTSIDE single/double quotes AND before any unquoted word-boundary `#`
    comment. A here-string `<<<WORD` (three `<`) is NOT a heredoc and never opens one.
    Returns a FIFO-ordered list of (word, strip_tabs) for `<<WORD` / `<<-WORD` /
    `<<'WORD'` / `<<"WORD"` operators found on the line.
    """
    words = []
    i = 0
    n = len(line)
    in_single = in_double = False
    prev_ws = True  # start-of-line is a word boundary (so a leading `#` is a comment)
    while i < n:
        c = line[i]
        if in_single:
            if c == "'":
                in_single = False
            prev_ws = False
            i += 1
            continue
        if in_double:
            if c == '\\' and i + 1 < n:
                prev_ws = False
                i += 2
                continue
            if c == '"':
                in_double = False
            prev_ws = False
            i += 1
            continue
        if c == "'":
            in_single = True
            prev_ws = False
            i += 1
            continue
        if c == '"':
            in_double = True
            prev_ws = False
            i += 1
            continue
        if c == '\\' and i + 1 < n:
            prev_ws = False
            i += 2
            continue
        if c == '#' and prev_ws:
            break  # unquoted word-boundary comment — rest of the line is inert
        if c == '<' and i + 1 < n and line[i + 1] == '<':
            # exclude here-string `<<<` (a `<<` flanked by another unquoted `<`)
            prev_lt = i > 0 and line[i - 1] == '<'
            next_lt = i + 2 < n and line[i + 2] == '<'
            if prev_lt or next_lt:
                prev_ws = False
                i += 1
                continue
            j = i + 2
            strip_tabs = False
            if j < n and line[j] == '-':
                strip_tabs = True
                j += 1
            while j < n and line[j] in (' ', '\t'):
                j += 1
            word = None
            if j < n and line[j] in ('"', "'"):
                q = line[j]
                j += 1
                start = j
                while j < n and line[j] != q:
                    j += 1
                word = line[start:j]
                if j < n:
                    j += 1  # consume closing quote
            else:
                m = HEREDOC_WORD_RE.match(line, j)
                if m:
                    word = m.group(0)
                    j = m.end()
            if word:
                words.append((word, strip_tabs))
            prev_ws = False
            i = j
            continue
        prev_ws = c in (' ', '\t')
        i += 1
    return words


def strip_heredocs(command):
    """Remove heredoc BODIES so inert data lines are not scanned as commands.

    Detects `<<WORD` / `<<-WORD` / `<<'WORD'` / `<<"WORD"` (quote/comment-aware, via
    _find_heredoc_words) and drops every line from the line AFTER the operator up to
    and including the terminator line (a line equal to WORD; leading tabs allowed for
    `<<-`). Multiple heredocs are handled in order. The introducing line itself is kept
    (it holds the real command + any redirects). A `<<WORD` that bash treats as inert —
    inside quotes, after an unquoted `#` comment, or as a `<<<` here-string — does NOT
    open a heredoc, so commands on later lines are still scanned.
    """
    lines = command.split('\n')
    out = []
    pending = []  # FIFO queue of (word, strip_tabs)
    for line in lines:
        if pending:
            word, strip_tabs = pending[0]
            check = line.lstrip('\t') if strip_tabs else line
            if check.strip() == word:
                pending.pop(0)  # terminator line — pop, then drop it too
            continue  # body (or terminator) line — drop either way
        for word, strip_tabs in _find_heredoc_words(line):
            pending.append((word, strip_tabs))
        out.append(line)
    return '\n'.join(out)


def split_segments(command, wr=False):
    """Split a command line into segments at UNQUOTED shell separators.

    Separators: newline ; & | ( ) { ` (which also covers && and ||, $(...) command
    substitution via `(`, and backtick `` `...` `` command substitution). Characters
    inside single/double quotes are never treated as separators, so a mention like
    echo "use pkill; rm -rf /" stays a single segment whose command is echo.

    wr=True (RULE 5 only; every other rule keeps the historical splitting) additionally keeps
    redirection glue inside one segment -- `&>`, `>&`, `<&`, `>|` -- and does NOT split at a
    `{` that is not followed by whitespace (`~/.claude/{a,b}/x` is brace EXPANSION, not a
    `{ cmd; }` group), so the target of a redirect / argument is never cut off its operator.
    """
    seps = set(';&|(){\n`')
    segments = []
    buf = []
    i = 0
    n = len(command)
    in_single = in_double = False
    while i < n:
        c = command[i]
        if in_single:
            buf.append(c)
            if c == "'":
                in_single = False
            i += 1
            continue
        if in_double:
            if c == '\\' and i + 1 < n:
                buf.append(c)
                buf.append(command[i + 1])
                i += 2
                continue
            buf.append(c)
            if c == '"':
                in_double = False
            i += 1
            continue
        if c == "'":
            in_single = True
            buf.append(c)
            i += 1
            continue
        if c == '"':
            in_double = True
            buf.append(c)
            i += 1
            continue
        if c == '\\' and i + 1 < n:
            buf.append(c)
            buf.append(command[i + 1])
            i += 2
            continue
        # `{` is a separator ONLY as the command-grouping keyword, NOT inside a
        # `${VAR}` expansion — otherwise `rm -rf ${HOME}` would be split apart.
        if c == '{' and i > 0 and command[i - 1] == '$':
            buf.append(c)
            i += 1
            continue
        if wr and (
            (c == '{' and i + 1 < n and command[i + 1] not in ' \t\n')
            or (c == '&' and ((i > 0 and command[i - 1] in '<>')
                              or (i + 1 < n and command[i + 1] == '>')))
            or (c == '|' and i > 0 and command[i - 1] == '>')
        ):
            buf.append(c)
            i += 1
            continue
        if c in seps:
            segments.append(''.join(buf))
            buf = []
            i += 1
            continue
        buf.append(c)
        i += 1
    segments.append(''.join(buf))
    return segments


def tokenize(segment):
    """Split a segment into tokens on UNQUOTED whitespace, preserving quotes in each token."""
    tokens = []
    cur = None  # None = no token in progress; str = building one
    i = 0
    n = len(segment)
    in_single = in_double = False
    while i < n:
        c = segment[i]
        if in_single:
            cur += c
            if c == "'":
                in_single = False
            i += 1
            continue
        if in_double:
            if c == '\\' and i + 1 < n:
                cur += c + segment[i + 1]
                i += 2
                continue
            cur += c
            if c == '"':
                in_double = False
            i += 1
            continue
        if c == "'":
            cur = (cur or '') + c
            in_single = True
            i += 1
            continue
        if c == '"':
            cur = (cur or '') + c
            in_double = True
            i += 1
            continue
        if c == '\\' and i + 1 < n:
            cur = (cur or '') + c + segment[i + 1]
            i += 2
            continue
        if c.isspace():
            if cur is not None:
                tokens.append(cur)
                cur = None
            i += 1
            continue
        cur = (cur or '') + c
        i += 1
    if cur is not None:
        tokens.append(cur)
    return tokens


# Shell reserved words that can LEAD a segment ahead of the real command (`do rm x`,
# `then pkill y`, `while rm z; do`, `! rm w`, `coproc rm v`). Without stripping them the
# keyword becomes the command word and EVERY rule misses the command behind it.
SHELL_KEYWORDS = frozenset(('do', 'then', 'else', 'elif', 'if', 'while', 'until', '!', '}', '{',
                            'coproc'))


def strip_keywords(tokens):
    """Drop leading shell reserved words (SHELL_KEYWORDS) so the real command is first."""
    i = 0
    while i < len(tokens) and tokens[i] in SHELL_KEYWORDS:
        i += 1
    return tokens[i:] if i else tokens


def tokenize_cmd(segment):
    """tokenize() + strip_keywords(): the tokens of the command a segment actually runs."""
    return strip_keywords(tokenize(segment))


def command_and_args(tokens):
    """Drop leading env-var assignments; return (assignments, command_word, arg_tokens)."""
    idx = 0
    while idx < len(tokens) and ENV_ASSIGN.match(tokens[idx]):
        idx += 1
    assignments = tokens[:idx]
    if idx >= len(tokens):
        return assignments, None, []
    return assignments, tokens[idx], tokens[idx + 1:]


def basename(word):
    """Unquoted basename of a command word.

    Strips a leading backslash (`\\pkill` → `pkill`) so quote/backslash-escaping the
    command word can't bypass the rule. /bin/rm and rm resolve to the same base.
    """
    w = strip_quotes(word)
    if w.startswith('\\'):
        w = w[1:]
    return os.path.basename(w)


# --- RULE 2 helpers ---------------------------------------------------------

def kill_target_dangerous(val):
    """A kill TARGET is dangerous if it is 0, -1, or any negative-integer pgid."""
    if val == '0':
        return True
    if NEG_INT.match(val):
        return True
    return False


def kill_has_dangerous_target(args):
    """Classify kill args and report whether any TARGET is a process-group / all-process target.

    The first leading -flag is the SIGNAL (e.g. -9, -KILL, -TERM, -0); -s/--signal
    consume the following token as the signal name. Everything after the signal that
    starts with '-' is a negative-pgid TARGET; '--' ends option parsing.
    """
    signal_consumed = False
    expect_signal_arg = False
    after_dd = False
    for tok in args:
        if expect_signal_arg:
            expect_signal_arg = False
            signal_consumed = True
            continue
        if after_dd:
            if kill_target_dangerous(strip_quotes(tok)):
                return True
            continue
        if tok == '--':
            after_dd = True
            continue
        if tok in ('-s', '--signal'):
            expect_signal_arg = True
            continue
        if tok.startswith('-') and not signal_consumed:
            # leading signal flag (-9 / -KILL / -TERM / -0 / -1-as-signal ...)
            signal_consumed = True
            continue
        # TARGET: positive pid, shell variable, or negative pgid
        if kill_target_dangerous(strip_quotes(tok)):
            return True
    return False


# --- RULE 3 helpers ---------------------------------------------------------

def _norm(path):
    """Strip a single trailing slash for matching, but keep the root '/' intact."""
    if len(path) > 1 and path.endswith('/'):
        return path.rstrip('/')
    return path


def exact_protected_roots():
    """Roots blocked ONLY on an exact (normalized) match.

    Everything lives under these, so prefix-matching them would block every path.
    Includes the resolved absolute home (expanduser + $HOME).
    """
    roots = set(EXACT_ONLY_ROOTS)
    for h in (os.path.expanduser('~'), os.environ.get('HOME', '')):
        if h:
            roots.add(_norm(h))
    return roots


def subtree_protected_bases():
    """Bases blocked on exact match OR as a parent of the target.

    Only the `.claude` subtree is fully protected; other home subpaths are allowed.
    """
    bases = ['~/.claude', '$HOME/.claude', '${HOME}/.claude']
    seen = set(bases)
    for h in (os.path.expanduser('~'), os.environ.get('HOME', '')):
        if not h:
            continue
        candidate = _norm(os.path.join(h, '.claude'))
        if candidate not in seen:
            seen.add(candidate)
            bases.append(candidate)
    return bases


def rm_target_protected(tok):
    """True if an rm TARGET (after quote-strip) is a protected root, root-glob, or .claude subtree."""
    val = strip_all_quotes(tok)
    nval = _norm(val)
    # root-glob wipe forms (/* , /.*) expand to every top-level entry — as bad as `/`
    if ROOT_GLOB.match(nval) or ROOT_GLOB.match(val):
        return True
    if nval in exact_protected_roots():
        return True
    for base in subtree_protected_bases():
        nbase = _norm(base)
        if not nbase:
            continue
        if nval == nbase or nval.startswith(nbase + '/'):
            return True
    return False


def _strip_attached_redirect(tok):
    """Strip an UNQUOTED trailing redirection glued onto a target token.

    `~/.claude>x` → `~/.claude` (the `>x` is a stdout redirect, not part of the path),
    so the protected-path check sees the real target. A `>`/`<` INSIDE quotes is a
    literal filename character and is preserved. Returns the portion before the first
    unquoted redirect operator (the whole token when there is none).
    """
    i = 0
    n = len(tok)
    in_single = in_double = False
    while i < n:
        c = tok[i]
        if in_single:
            if c == "'":
                in_single = False
            i += 1
            continue
        if in_double:
            if c == '\\' and i + 1 < n:
                i += 2
                continue
            if c == '"':
                in_double = False
            i += 1
            continue
        if c == "'":
            in_single = True
            i += 1
            continue
        if c == '"':
            in_double = True
            i += 1
            continue
        if c == '\\' and i + 1 < n:
            i += 2
            continue
        if c in '<>':
            return tok[:i]  # unquoted redirect begins here — everything before is target
        i += 1
    return tok


def rm_is_catastrophic(args):
    """True if rm args carry a recursive flag AND target a protected path.

    Target collection stops at a shell comment ('#' at a word boundary). Redirections
    are not rm targets: a BARE redirect operator token (`>`, `2>`, `>>`) consumes the
    FOLLOWING token as its redirect target; a self-contained redirect (`>file`, `2>&1`)
    consumes only itself; and an UNQUOTED redirect glued to a target token
    (`~/.claude>x`) is split off so the real target is checked.
    """
    recursive = False
    targets = []
    after_dd = False
    i = 0
    n = len(args)
    while i < n:
        tok = args[i]
        # Lexical (shell-parsed before option handling, ignores `--`):
        if tok.startswith('#'):
            break  # comment — drop it and everything after on this segment
        if REDIR_RE.match(tok):
            # A redirect operator token — never an rm target. A bare op (`>`, `2>`)
            # also consumes the following token as its redirect target.
            i += 2 if BARE_REDIR_RE.match(tok) else 1
            continue
        if not after_dd and tok == '--':
            after_dd = True
            i += 1
            continue
        if not after_dd and tok.startswith('-') and tok != '-':
            if tok == '--recursive' or RM_RECURSIVE_SHORT.match(tok):
                recursive = True
            i += 1
            continue  # other flags (-f, --force, -v, ...) ignored
        target = _strip_attached_redirect(tok)
        if target:
            targets.append(target)
        i += 1
    if not recursive:
        return False
    return any(rm_target_protected(t) for t in targets)


# --- RULE 4 helpers ---------------------------------------------------------

def _out_redirect_suffix(tok, wide=False):
    """If a token carries an unquoted OUTPUT redirect (`>` / `>>`, incl. fd-numbered
    `2>` `1>>`), return the target substring that follows the `>` run; else None.

    - Returns '' for a BARE operator (`>`, `>>`, `2>`) whose target is the FOLLOWING
      token.
    - Returns the glued path for `>path` / `2>>path` / `word>path`.
    - Returns None for an input redirect (`<`, scanned past) and for an fd-dup
      (`>&2`, `2>&1`) whose suffix starts with `&` — neither is a file target.
    Quote-aware: a `>`/`<` inside quotes is a literal filename char, not a redirect.

    wide=True (RULE 5) also understands the clobber form `>|file` and `>&file` (stdout+stderr
    to a FILE -- only `>&<digits>` / `>&-` are fd-dups), and reports `<>file` (read-write open)
    as a write. A bare `>&` returns '' (the target is the following token; the caller skips a
    digit / `-` token).
    """
    i = 0
    n = len(tok)
    in_single = in_double = False
    while i < n:
        c = tok[i]
        if in_single:
            if c == "'":
                in_single = False
            i += 1
            continue
        if in_double:
            if c == '\\' and i + 1 < n:
                i += 2
                continue
            if c == '"':
                in_double = False
            i += 1
            continue
        if c == "'":
            in_single = True
            i += 1
            continue
        if c == '"':
            in_double = True
            i += 1
            continue
        if c == '\\' and i + 1 < n:
            i += 2
            continue
        if c == '<':
            i += 1  # input redirect — skip, keep scanning for a later `>`
            continue
        if c == '>':
            j = i + 1
            while j < n and tok[j] == '>':
                j += 1
            suffix = tok[j:]
            if wide:
                if suffix.startswith('|'):
                    suffix = suffix[1:]
                if suffix.startswith('&'):
                    rest = suffix[1:]
                    if rest == '':
                        return ''
                    if rest.isdigit() or rest == '-':
                        return None
                    return rest
            if suffix.startswith('&'):
                return None  # fd-dup (>&2, 2>&1), not a file target
            return suffix
        i += 1
    return None


def _is_cd_to_workflows(segment):
    """True if this segment is a literal 'cd' whose target contains .github/workflows.

    Matches 'cd .github/workflows' (exact), 'cd .github/workflows/' (trailing slash),
    and any path containing '.github/workflows/' as a substring (absolute, $PWD-composed).
    Quote-strips the first non-flag argument. Does NOT track cwd state — pure literal detection.
    """
    tokens = tokenize_cmd(segment)
    _, cmd, args = command_and_args(tokens)
    if cmd is None or basename(cmd) != 'cd' or not args:
        return False
    target = strip_all_quotes(args[0])
    return target == '.github/workflows' or WORKFLOW_PATH_MARK in target


def _segment_has_output_redirect(segment):
    """True if this segment contains any output redirect (>, >>, or tee in command position).

    Reuses _out_redirect_suffix for `>`/`>>` detection and the tee-sink pattern from
    workflow_write_via_bash. Input redirects (<) are never flagged.
    """
    tokens = tokenize_cmd(segment)
    _assignments, cmd, args = command_and_args(tokens)
    while cmd is not None and basename(cmd) in WRAPPERS and args:
        cmd = args[0]
        args = args[1:]
    if cmd is not None and basename(cmd) == 'tee':
        return True
    for tok in tokens:
        if _out_redirect_suffix(tok) is not None:
            return True
    return False


def workflow_write_via_bash(command):
    """True if the command WRITES under `.github/workflows/` via output redirection
    (`>`/`>>`, fd-numbered forms) or a `tee` sink. Reads (`cat`/`grep`, `<` input
    redirects) are never flagged. Quote/segment-aware; heredoc bodies are inert.

    Literal-cd evasion is also detected: a compound command where a segment is a
    literal `cd .github/workflows` (with or without trailing slash) followed by any
    segment containing an output redirect is blocked even when the redirect target
    (e.g. `ci.yml`) lacks the workflow marker. Detection is literal-cd only — no
    stateful cwd tracking. Handles `;`, `&&`, `||`, and any other separator that
    split_segments already yields as separate segments.

    KNOWN OUT-OF-SCOPE EVASION (documented, NOT fixed — same deliberate class as
    sudo/env/xargs variable-indirection out-of-scope in RULE 3):
      - cp/mv destinations: `cp src .github/workflows/ci.yml` is not an output
        redirect operator and is not caught here.
      - dd of= targets: `dd if=src of=.github/workflows/ci.yml` uses a non-redirect
        write mechanism not scanned by this guard.
      - bash -c quoted subshell: a redirect inside a single-quoted bash -c argument
        (`bash -c 'echo x > .github/workflows/ci.yml'`) is literal data inside a
        quoted segment and is not split or scanned.
      - sed -i in-place: `sed -i '' 's/a/b/' .github/workflows/ci.yml` modifies the
        file in-place via the -i flag, not via an output redirect.
      - Variable indirection: `echo x > "$WFPATH"` where WFPATH resolves to a
        workflow path at runtime — only literal path markers are checked, no env
        expansion.
      - git apply / git checkout: git commands that write workflow files from an
        object store or patch are not Bash redirects and are not caught here.
      - rsync / install: `rsync src .github/workflows/ci.yml` or
        `install -m 644 src .github/workflows/ci.yml` are file-copy commands, not
        redirect operators.
    This is defense-in-depth for the redirect-evasion class, not a complete sandbox.
    The devops Write/Edit policy gate is the primary enforcement surface.
    """
    segments = split_segments(strip_heredocs(command))

    # Literal-cd evasion: 'cd .github/workflows && echo x > ci.yml' evades the
    # per-segment redirect check because the redirect target 'ci.yml' lacks the
    # marker. Detect a literal cd to .github/workflows followed by any output
    # redirect in any later segment; block the full compound command.
    cd_wf_seen = False
    for segment in segments:
        if not cd_wf_seen and _is_cd_to_workflows(segment):
            cd_wf_seen = True
        elif cd_wf_seen and _segment_has_output_redirect(segment):
            return True

    for segment in segments:
        tokens = tokenize_cmd(segment)

        # `tee` sink: every non-flag argument is a write target.
        _assignments, cmd, args = command_and_args(tokens)
        while cmd is not None and basename(cmd) in WRAPPERS and args:
            cmd = args[0]
            args = args[1:]
        if cmd is not None and basename(cmd) == 'tee':
            for a in args:
                if a.startswith('-') and a != '-':
                    continue  # flag (-a, -i, --)
                if WORKFLOW_PATH_MARK in strip_all_quotes(a):
                    return True

        # Output redirect operators anywhere in the token stream.
        i = 0
        n = len(tokens)
        while i < n:
            suffix = _out_redirect_suffix(tokens[i])
            if suffix is not None:
                if suffix == '':
                    if i + 1 < n and WORKFLOW_PATH_MARK in strip_all_quotes(tokens[i + 1]):
                        return True
                elif WORKFLOW_PATH_MARK in strip_all_quotes(suffix):
                    return True
            i += 1
    return False


# --- RULE 5 helpers ---------------------------------------------------------
#
# Bash WRITE guard for the installed CAST exec surface. See the module docstring (RULE 5) for
# the contract and the accepted residuals; everything below is literal-path analysis of the
# command STRING -- nothing is executed and nothing on disk is touched (the only syscalls are
# realpath() lookups of write targets, to follow symlinks that already exist).

PW_OK_ASSIGN = re.compile(r'^CAST_PROTECTED_WRITE_OK=["\']?1["\']?$')
# Protected ROOTS, relative to the home (the roots themselves are protected too):
#   ~/.claude/{githooks,scripts,config,install-manifest.sha256}  the installed exec surface
#   ~/.claude/cast-state                pyc-verification snapshot + state files only HOOKS write
#                                       (hooks do not go through this guard; Bash must not either)
#   ~/Library/Caches/com.apple.python   macOS /usr/bin/python3 bytecode cache (a forged .pyc
#                                       there is loaded for installed scripts)
#   ~/Library/Python                    user site-packages / sitecustomize
#   ~/Library/LaunchAgents              launchd plists = persistence
PW_ROOT_RELS = ('.claude/githooks', '.claude/scripts', '.claude/config',
                '.claude/install-manifest.sha256', '.claude/cast-state',
                'Library/Caches/com.apple.python',
                'Library/Python', 'Library/LaunchAgents')
# leaf names of the roots and of their parents (a `mv /tmp/evil/<leaf> <parent>` replaces one)
PW_ROOT_NAMES = ('githooks', 'scripts', 'config', 'install-manifest.sha256', 'cast-state',
                 'launchagents',
                 'python', 'com.apple.python', 'caches', 'library')
PW_MAX_TOKEN = 16384      # a path word longer than PATH_MAX-ish can't name a real target
PW_MAX_BRACE = 256        # brace-expansion alternatives per word (beyond: wildcarded)
PW_MAX_GROUPS = 16
PW_MAX_DEPTH = 3          # bash -c / eval payload nesting
PW_MAX_PAYLOAD = 262144
PW_MAX_REALPATH = 1000    # realpath() lookups of write targets per command (perf bound)
_WILD_STAR = '\ue000'     # an unquoted `*`
_WILD_ONE = '\ue001'      # an unquoted `?` (or a POSIX class `[[:alpha:]]`)
_CLS_OPEN = '\ue002'      # `[` of a real bracket class; `\ue003` closes it (content between)
_CLS_CLOSE = '\ue003'
_WILD_EXP = '\ue004'      # an unresolvable expansion ($VAR, $(...), `...`): base UNKNOWN
_WILDS = (_WILD_STAR, _WILD_ONE, _CLS_OPEN, _WILD_EXP)
_FIRMLINK = '/system/volumes/data'
# a dynamic word that spells one of the protected names after an unknown prefix
PW_MARKER_RE = re.compile(
    r'(?:^|[/\ue000\ue001\ue004])(?:\.claude/(?:githooks|scripts|config|install-manifest\.sha256|'
    r'cast-state)'
    r'|library/(?:caches/com\.apple\.python|python|launchagents))(?:$|[/\ue000\ue001\ue004])')

PW_MSG = (
    "**[CAST]** Writing / moving / linking / chmod-ing / deleting under the installed CAST exec "
    "surface (~/.claude/githooks, ~/.claude/scripts, ~/.claude/config, "
    "~/.claude/install-manifest.sha256, ~/.claude/cast-state, ~/Library/Caches/com.apple.python, "
    "~/Library/Python, ~/Library/LaunchAgents) via Bash is blocked — git hooks and python run from there. Deploy "
    "with `bash install.sh`. Deliberate? Prefix the segment with CAST_PROTECTED_WRITE_OK=1."
)

# wrapper -> (short flags that take an argument, positionals to skip, skips VAR=val words)
# (xargs: only a path given on ITS command line is seen -- paths arriving on stdin are not)
_PW_WRAPPERS = {
    'command': ('', 0, False), 'exec': ('', 0, False), 'nohup': ('', 0, False),
    'time': ('', 0, False), 'builtin': ('', 0, False), 'nice': ('n', 0, False),
    'timeout': ('sk', 1, False), 'sudo': ('ugphpCDRTUrtc', 0, True),
    'doas': ('uC', 0, True), 'env': ('uC', 0, True), 'xargs': ('InPLdEsJ', 0, False),
    'busybox': ('', 0, False),
}
# GNU coreutils installed with a `g` prefix (Homebrew): gsed -i, grm, gtee ...
_PW_GNU = frozenset(('tee', 'cp', 'mv', 'ln', 'rm', 'unlink', 'rmdir', 'shred', 'chmod', 'chown',
                     'chgrp', 'touch', 'truncate', 'sed', 'dd', 'install', 'find', 'tar',
                     'patch', 'awk'))
# commands a `find ... -exec` may run without it counting as a write
_PW_READ_EXEC = frozenset(('grep', 'egrep', 'fgrep', 'rg', 'cat', 'head', 'tail', 'less', 'more',
                           'ls', 'stat', 'file', 'wc', 'shasum', 'sha1sum', 'sha256sum', 'md5',
                           'md5sum', 'cksum', 'cmp', 'diff', 'echo', 'printf', 'test', '[',
                           'basename', 'dirname', 'readlink', 'realpath', 'du', 'strings',
                           'xxd', 'od', 'hexdump', 'true', 'false'))


class _PWCtx(object):
    """Resolved protected-path facts for one guard run (home spellings + realpaths)."""
    pass


def _pw_canon(path):
    """Lexical canonical form of an absolute path (collapse //, /./, /../)."""
    p = os.path.normpath(path)
    if p.startswith('//'):
        p = '/' + p.lstrip('/')
    low = p.lower()
    if low == _FIRMLINK or low.startswith(_FIRMLINK + '/'):
        # APFS firmlink: /System/Volumes/Data/Users/testuser IS /Users/testuser (realpath() does not see it)
        p = p[len(_FIRMLINK):] or '/'
    return p


def _pw_realpath(path):
    try:
        return os.path.realpath(path)
    except Exception:
        return path


def _pw_context():
    """Protected roots for this process. The home is every spelling of it that can be live:
    $HOME, expanduser('~') and the account's passwd home (so an absolute
    `/Users/<user>/.claude/...` is protected even when $HOME was redirected). Roots and
    their realpaths are both kept, lower-cased (APFS is case-insensitive)."""
    ctx = _PWCtx()
    primary = os.environ.get('HOME') or os.path.expanduser('~')
    ctx.home = _pw_canon(primary) if primary.startswith('/') else os.path.expanduser('~')
    cands = [primary, os.path.expanduser('~')]
    if pwd is not None:
        try:
            cands.append(pwd.getpwuid(os.getuid()).pw_dir)
        except Exception:
            pass
    homes = []
    roots = []
    ancestors = []
    far = ['/']
    for h in cands:
        if not h or not h.startswith('/'):
            continue
        hc = _pw_canon(h)
        if hc == '/':
            continue
        for hv in (hc, _pw_realpath(hc)):
            hl = hv.lower()
            if hl not in homes:
                homes.append(hl)
            anc = (hv + '/.claude').lower()
            if anc not in ancestors:
                ancestors.append(anc)
            up = hv  # the home and every parent of it: a merge into one of them reaches the roots
            while up != '/' and up:
                if up.lower() not in far:
                    far.append(up.lower())
                up = os.path.dirname(up)
            for rel in PW_ROOT_RELS:
                for rv in (hv + '/' + rel, _pw_realpath(hv + '/' + rel)):
                    rl = rv.lower()
                    if rl not in roots:
                        roots.append(rl)
            for rel in ('Library', 'Library/Caches'):  # parents of the Library roots (merge tools)
                rl = (hv + '/' + rel).lower()
                if rl not in far:
                    far.append(rl)
        # `.claude` itself may be a symlink: its target is the real ancestor
        ra = _pw_realpath(hc + '/.claude').lower()
        if ra not in ancestors:
            ancestors.append(ra)
    ctx.rp_left = PW_MAX_REALPATH
    ctx.vars = {}
    ctx.prot_vars = set()  # names assigned a protected value (blocked if later exported)
    ctx.allexport = False   # `set -a` / `set -o allexport` seen
    ctx.exported = set()    # names exported so far (either order vs. the assignment)
    ctx.git_env_dirs = []   # GIT_DIR= / GIT_WORK_TREE= values for the segment's git
    ctx.sink = True         # set by protected_write_via_bash: the command can run text
    ctx.homes = homes
    ctx.roots = roots
    ctx.ancestors = ancestors
    ctx.far = far
    return ctx


# ---- word resolution (quotes / $HOME / ~ / ${HOME} / backslash-newline / braces / globs) ----

def _pw_brace_group(s, i):
    """If s[i] == '{' opens a brace-expansion group with a top-level comma, return
    (alternatives, index_of_closing_brace); else None. Quote-aware."""
    n = len(s)
    depth = 1
    j = i + 1
    start = j
    alts = []
    in_s = in_d = False
    commas = False
    while j < n:
        c = s[j]
        if in_s:
            if c == "'":
                in_s = False
        elif in_d:
            if c == '\\':
                j += 1
            elif c == '"':
                in_d = False
        elif c == "'":
            in_s = True
        elif c == '"':
            in_d = True
        elif c == '\\':
            j += 1
        elif c == '$' and j + 1 < n and s[j + 1] == '{':
            k = s.find('}', j + 2)
            if k < 0:
                return None
            j = k
        elif c == '{':
            depth += 1
        elif c == '}':
            depth -= 1
            if depth == 0:
                if not commas:
                    return None
                alts.append(s[start:j])
                return alts, j
        elif c == ',' and depth == 1:
            commas = True
            alts.append(s[start:j])
            start = j + 1
        j += 1
    return None


def _pw_brace_expand(s, depth=0):
    """Expand unquoted `{a,b}` groups (bash brace expansion) into a list of raw words. Bounded:
    more than PW_MAX_GROUPS groups, PW_MAX_BRACE results or deep nesting degrade to a
    WILDCARD in place of the group, so the word is still checked as a dynamic pattern."""
    parts = []
    n = len(s)
    i = 0
    lit = 0
    in_s = in_d = False
    while i < n:
        c = s[i]
        if in_s:
            if c == "'":
                in_s = False
        elif in_d:
            if c == '\\':
                i += 1
            elif c == '"':
                in_d = False
        elif c == "'":
            in_s = True
        elif c == '"':
            in_d = True
        elif c == '\\':
            i += 1
        elif c == '{' and not (i > 0 and s[i - 1] == '$'):
            g = _pw_brace_group(s, i)
            if g is not None:
                parts.append(s[lit:i])
                parts.append(g[0])
                lit = g[1] + 1
                i = lit
                continue
        i += 1
    parts.append(s[lit:])
    if len(parts) == 1:
        return [s]

    def wildcarded():
        return [''.join(_WILD_STAR if isinstance(p, list) else p for p in parts)]

    if depth > 8 or sum(1 for p in parts if isinstance(p, list)) > PW_MAX_GROUPS:
        return wildcarded()
    results = ['']
    for p in parts:
        if isinstance(p, str):
            results = [r + p for r in results]
            continue
        alts = []
        for a in p:
            alts.extend(_pw_brace_expand(a, depth + 1))
            if len(alts) > PW_MAX_BRACE:
                return wildcarded()
        results = [r + a for r in results for a in alts]
        if len(results) > PW_MAX_BRACE:
            return wildcarded()
    return results


def _pw_expand(raw, i, home, variables=None):
    """Expand the `$...` / backtick construct at raw[i]. -> (text, end_index, is_dynamic).
    $HOME / ${HOME} resolve to `home`, a parameter assigned earlier in the SAME command
    (`variables`, name -> text) to its value; every other parameter / command substitution
    is dynamic (unknowable here)."""
    def known(name):
        if name == 'HOME':
            return home
        return variables.get(name) if variables else None

    n = len(raw)
    if raw[i] == '`':
        j = i + 1
        while j < n and raw[j] != '`':
            j += 2 if raw[j] == '\\' else 1
        return '', min(j + 1, n), True
    if i + 1 >= n:
        return '$', i + 1, False
    nx = raw[i + 1]
    if nx == '(':
        depth = 0
        j = i + 1
        while j < n:
            ch = raw[j]
            if ch == '\\':
                j += 2
                continue
            if ch == "'":
                k = raw.find("'", j + 1)
                j = k + 1 if k >= 0 else n
                continue
            if ch == '(':
                depth += 1
            elif ch == ')':
                depth -= 1
                if depth == 0:
                    j += 1
                    break
            j += 1
        return '', min(j, n), True
    if nx == '{':
        j = raw.find('}', i + 2)
        if j < 0:
            return '', n, True
        val = known(raw[i + 2:j])
        if val is not None:
            return val, j + 1, False
        return '', j + 1, True
    if nx.isalpha() or nx == '_':
        j = i + 2
        while j < n and (raw[j].isalnum() or raw[j] == '_'):
            j += 1
        val = known(raw[i + 1:j])
        if val is not None:
            return val, j, False
        return '', j, True
    if nx.isdigit() or nx in '@*#?$!-':
        if variables and nx in variables:
            return variables[nx], i + 2, False  # positional parameters set by `set --`
        return '', i + 2, True
    return '$', i + 1, False


def _pw_unquote(raw, home, payload=False, variables=None):
    """Shell-unquote one word. -> (text, dynamic).

    Path mode (default): `~` / `$HOME` / `${HOME}` resolve to `home`; an unquoted glob char or
    any other expansion becomes a wildcard sentinel (dynamic=True); quotes, backslashes and
    backslash-newline are removed as the shell would. payload=True keeps wildcards and
    non-HOME expansions as their SOURCE text (the word is re-parsed as a shell command)."""
    out = []
    dyn = False
    i = 0
    n = len(raw)
    while i < n:
        c = raw[i]
        if c == "'":
            j = raw.find("'", i + 1)
            if j < 0:
                j = n
            out.append(raw[i + 1:j])
            i = j + 1
            continue
        if c == '"':
            i += 1
            while i < n and raw[i] != '"':
                d = raw[i]
                if d == '\\' and i + 1 < n:
                    nx = raw[i + 1]
                    if nx == '\n':
                        i += 2
                        continue
                    if nx in '$`"\\':
                        out.append(nx)
                        i += 2
                        continue
                    out.append('\\')
                    i += 1
                    continue
                if d == '$' or d == '`':
                    txt, i2, isdyn = _pw_expand(raw, i, home, variables)
                    if isdyn:
                        dyn = True
                        txt = raw[i:i2] if payload else _WILD_EXP
                    out.append(txt)
                    i = i2
                    continue
                out.append(d)
                i += 1
            i += 1
            continue
        if c == '\\':
            if i + 1 < n:
                if raw[i + 1] != '\n':
                    out.append(raw[i + 1])
                i += 2
            else:
                out.append('\\')
                i += 1
            continue
        if c == '$' and i + 1 < n and raw[i + 1] == "'":
            j = i + 2
            buf = []
            while j < n and raw[j] != "'":
                if raw[j] == '\\' and j + 1 < n:
                    buf.append(raw[j:j + 2])
                    j += 2
                else:
                    buf.append(raw[j])
                    j += 1
            text = ''.join(buf)
            try:
                text = text.encode('latin-1', 'backslashreplace').decode('unicode_escape')
            except Exception:
                pass
            out.append(text)
            i = j + 1
            continue
        if c == '$' and i + 1 < n and raw[i + 1] == '"':
            i += 1  # $"..." locale string: same as "..."
            continue
        if c == '$' or c == '`':
            txt, i2, isdyn = _pw_expand(raw, i, home, variables)
            if isdyn:
                dyn = True
                txt = raw[i:i2] if payload else _WILD_EXP
            out.append(txt)
            i = i2
            continue
        if c == '~' and i == 0:
            j = raw.find('/')
            name = raw[1:] if j < 0 else raw[1:j]
            if name == '':
                out.append(home)
                i += 1
                continue
            if not payload and re.match(r'^[A-Za-z0-9_.+-]+$', name):
                # `~user` expands to that account's home; `~+` / `~-` are cwd-ish: unknown
                udir = None
                if pwd is not None and name not in ('+', '-'):
                    try:
                        udir = pwd.getpwnam(name).pw_dir
                    except (KeyError, ValueError, OverflowError):
                        udir = None
                out.append(udir if udir else (_WILD_STAR if name in ('+', '-') else '~' + name))
                dyn = dyn or name in ('+', '-')
                i += 1 + len(name)
                continue
        if c == '[':
            j = i + 1
            if j < n and raw[j] in '!^':
                j += 1
            if j < n and raw[j] == ']':
                j += 1
            while j < n and raw[j] != ']':
                if raw[j:j + 2] == '[:':
                    k = raw.find(':]', j + 2)
                    j = k + 2 if k >= 0 else j + 1
                else:
                    j += 1
            if j < n:  # a real bracket class: `~/.claude/[s]cripts` names scripts
                content = raw[i + 1:j]
                dyn = True
                if payload:
                    out.append(raw[i:j + 1])
                elif '[:' in content or any(q in content for q in '\'"\\$`'):
                    out.append(_WILD_ONE)  # POSIX class / odd content: any one character
                else:
                    out.append(_CLS_OPEN + content + _CLS_CLOSE)
                i = j + 1
                continue
            out.append('[')  # unmatched: a literal bracket
            i += 1
            continue
        if c in '*?':
            dyn = True
            out.append(c if payload else (_WILD_STAR if c == '*' else _WILD_ONE))
            i += 1
            continue
        out.append(c)
        i += 1
    text = ''.join(out)
    if not payload and not dyn and any(w in text for w in _WILDS):
        dyn = True  # a known variable whose value was itself a pattern
    return text, dyn


def _pw_alts(ctx, tok):
    """The (text, dynamic) readings of one shell word. Brace expansion has already turned a
    `{a,b}` word into SEVERAL words (see _pw_scan), so there is exactly one reading."""
    if len(tok) > PW_MAX_TOKEN:
        return []
    return [_pw_unquote(tok, ctx.home, variables=ctx.vars)]


# ---- matching ----

def _pw_comp_match(name, pat):
    conv = []
    in_cls = False
    first = False
    for ch in pat:
        if ch == _CLS_OPEN:
            conv.append('[')
            in_cls = True
            first = True
            continue
        if ch == _CLS_CLOSE:
            conv.append(']')
            in_cls = False
            continue
        if in_cls:
            if first and ch == '^':
                ch = '!'
            first = False
            conv.append(ch)
        elif ch in (_WILD_STAR, _WILD_EXP):
            conv.append('*')
        elif ch == _WILD_ONE:
            conv.append('?')
        elif ch in '*?[':
            conv.append('[' + ch + ']')
        else:
            conv.append(ch)
    return fnmatch.fnmatchcase(name, ''.join(conv))


def _pw_pat_hits(pl, root, under=True):
    """Can the lower-cased wildcard pattern `pl` name `root` (or, with under=True, something
    below it)? Component-wise; a wildcard in the LAST component may span several root
    components (an unknown expansion can contain `/`)."""
    pc = pl.split('/')
    rc = root.split('/')
    k, m = len(pc), len(rc)
    if k > m and not under:
        return False
    if k >= m:
        return all(_pw_comp_match(rc[i], pc[i]) for i in range(m))
    last = pc[-1]
    if not any(w in last for w in _WILDS):
        return False
    return (all(_pw_comp_match(rc[i], pc[i]) for i in range(k - 1))
            and _pw_comp_match('/'.join(rc[k - 1:]), last))


def _pw_static_hit(ctx, text, structural):
    p = _pw_canon(text)
    cands = [p]
    if ctx.rp_left > 0:  # symlink-following is a syscall per target: bounded per command
        ctx.rp_left -= 1
        cands.append(_pw_realpath(p))
    for cand in cands:
        c = cand.lower()
        for r in ctx.roots:
            if c == r or c.startswith(r + '/'):
                return True
        if structural and c in ctx.ancestors:
            return True
        if structural >= 2 and c in ctx.far:
            return True
    return False


def _pw_dyn_hit(ctx, text, structural):
    pl = _pw_canon(text).lower()
    k = len(pl)
    for w in _WILDS:
        j = pl.find(w)
        if 0 <= j < k:
            k = j
    static = pl[:k]
    under_home = False
    for h in ctx.homes:
        if static.startswith(h + '/'):
            under_home = True
            # `~/$X` (nothing of `.claude` named yet) is NOT enough to suspect a target
            if len(static) > len(h) + 1:
                for r in ctx.roots:
                    if _pw_pat_hits(pl, r):
                        return True
                if structural:
                    for a in ctx.ancestors:
                        if _pw_pat_hits(pl, a, under=False):
                            return True
    if (static == '' or under_home) and PW_MARKER_RE.search(pl):
        return True
    return False


def _pw_hit(ctx, tok, cwd, structural=False):
    """True if shell word `tok` names (or may name) a protected path. Relative words resolve
    against the tracked cwd; with an unknown cwd only a dynamic word spelling a protected
    name is suspected. structural=True also protects `~/.claude` itself (move / link /
    delete / recursive chmod of the PARENT takes the roots with it)."""
    for text, dyn in _pw_alts(ctx, tok):
        if not text:
            continue
        if text[0] != '/':
            if cwd is None or text[0] == _WILD_EXP:
                # base unknown (no cwd, or the word LEADS with an unknown expansion that may
                # itself be absolute): only a dynamic word spelling a protected name is suspect
                if dyn and PW_MARKER_RE.search(text.lower()):
                    return True
                continue
            text = cwd + '/' + text
        if dyn:
            if _pw_dyn_hit(ctx, text, structural):
                return True
        elif _pw_static_hit(ctx, text, structural):
            return True
    return False


def _pw_any(ctx, toks, cwd, structural=False):
    return any(_pw_hit(ctx, t, cwd, structural) for t in toks)


# ---- argument parsing ----

def _pw_parse_args(args, short_arg='', long_arg=(), stop_at=''):
    """Split a command's args into (positionals, [(flag, value)]). Flags: `-x` clusters (a
    char in `short_arg` takes the rest of the cluster or the next token as its value; a char
    in `stop_at` ends the cluster -- `sed -i.bak`), `--name[=value]` (`long_arg` names take the
    next token). Redirect tokens are not arguments; `--` ends options; a `#` word starts a
    comment."""
    pos = []
    opts = []
    after_dd = False
    i = 0
    n = len(args)
    while i < n:
        tok = args[i]
        if tok.startswith('#'):
            break
        if REDIR_RE.match(tok):
            i += 2 if BARE_REDIR_RE.match(tok) else 1
            continue
        if not after_dd and tok == '--':
            after_dd = True
            i += 1
            continue
        if not after_dd and tok.startswith('--'):
            name, eq, val = tok[2:].partition('=')
            if eq:
                opts.append(('--' + name, val))
            elif name in long_arg:
                opts.append(('--' + name, args[i + 1] if i + 1 < n else None))
                i += 1
            else:
                opts.append(('--' + name, None))
            i += 1
            continue
        if not after_dd and tok.startswith('-') and tok != '-':
            j = 1
            while j < len(tok):
                ch = tok[j]
                if ch in short_arg:
                    rest = tok[j + 1:]
                    if rest:
                        opts.append((ch, rest))
                    else:
                        opts.append((ch, args[i + 1] if i + 1 < n else None))
                        i += 1
                    break
                opts.append((ch, None))
                if ch in stop_at:
                    break
                j += 1
            i += 1
            continue
        t = _strip_attached_redirect(tok)
        if t:
            pos.append(t)
        i += 1
    return pos, opts


def _pw_cmdword(ctx, word):
    """A command word with its quoting removed (`t''ee`, `r"m"`, `/bin/r\\m` -> the real name)."""
    if word is None or len(word) > 512 or not any(c in word for c in '\'"\\$'):
        return word
    return _pw_unquote(word, ctx.home)[0] or word


def _pw_unwrap(cmd, args, ctx, collected=None, raw_out=None):
    """Peel command wrappers (command/exec/nohup/time/nice/timeout/sudo/doas/env) -> the real
    (command_word, args). sudo/env VAR=val words are skipped (a hatch must LEAD the segment)."""
    raw = cmd
    for _ in range(8):
        raw = cmd  # the real command word as WRITTEN (`${X:-}`), before quote removal
        cmd = _pw_cmdword(ctx, cmd)
        if cmd is None:
            break
        spec = _PW_WRAPPERS.get(basename(cmd))
        if spec is None:
            break
        arg_flags, skip_pos, skip_assign = spec
        i = 0
        n = len(args)
        while i < n:
            t = args[i]
            if t == '--':
                i += 1
                break
            if basename(cmd) == 'env':
                # env -S 'cmd args' / -S'cmd args' / --split-string='cmd args': a command STRING
                if t in ('-S', '--split-string') and i + 1 < n:
                    return 'sh', ['-c', args[i + 1]]
                if t.startswith('--split-string='):
                    return 'sh', ['-c', t.split('=', 1)[1]]
                if t.startswith('-S') and len(t) > 2 and not t.startswith('--'):
                    return 'sh', ['-c', t[2:]]
            if t.startswith('-') and t != '-':
                if not t.startswith('--') and t[-1] in arg_flags and len(t) == 2:
                    i += 1  # the flag's value
                i += 1
            elif skip_assign and ENV_ASSIGN.match(t):
                if collected is not None:
                    collected.append(t)  # `env VAR=val cmd`: still an environment assignment
                i += 1
            else:
                break
        i += skip_pos
        if i >= n:
            return None, []
        cmd, args = args[i], args[i + 1:]
        raw = cmd
    if raw_out is not None:
        raw_out[:] = [raw]
    return cmd, args


def _pw_cd(ctx, args, cwd):
    """cwd after a `cd` / `pushd` (None = unknown)."""
    pos, _opts = _pw_parse_args(args)
    if not pos:
        return ctx.home
    alts = _pw_alts(ctx, pos[0])
    if len(alts) != 1:
        return None
    text, dyn = alts[0]
    if dyn or not text or text == '-':
        return None
    if text.startswith('/'):
        return _pw_canon(text)
    if cwd is None:
        return None
    return _pw_canon(cwd + '/' + text)


def _pw_redirect_targets(tokens):
    """Raw target words of every output redirect in a segment's tokens."""
    n = len(tokens)
    for i in range(n):
        rest = tokens[i]
        while True:
            suffix = _out_redirect_suffix(rest, wide=True)
            if suffix is None:
                break
            if suffix == '':
                if i + 1 < n:
                    tgt = tokens[i + 1]
                    if not (rest.endswith('&') and (tgt.isdigit() or tgt == '-')):
                        t = _strip_attached_redirect(tgt)
                        if t:
                            yield t
                break
            tgt = _strip_attached_redirect(suffix)
            if tgt:
                yield tgt
            rest = suffix[len(tgt):]
            if not rest:
                break


# ---- STRICT READERS --------------------------------------------------------------------------
# An allowlisted command is a "reader" only while every option it is given is one it is KNOWN to
# accept. Two kinds of entry:
#   nowrite  audited against man/--help: NO option of the command creates or modifies a file or
#            runs a command string, so option parsing cannot matter -- every operand (and every
#            mention of a protected path in it) is a pure READ. No option table is kept for these
#            (it would be dead weight); an unknown option cannot make them write.
#   strict   a command that CAN write (sort -o, tree -o, uniq in OUT, ...) or run a string (rg
#            --pre, sdiff --diff-program) declares its COMPLETE option set with exact arity,
#            re-derived from `<cmd> --help` / man on this machine. Long options resolve by GNU
#            unique prefix (`--outp` is `--output`); an option that is unknown, ambiguous or has
#            the wrong arity makes the segment LOSE reader status -> the generic fail-closed path
#            (any mention of a protected path blocks).
# Arity: 'N' none, 'A' argument (a read / plain value), 'W' argument the command WRITES,
# 'C' argument that is a COMMAND STRING (scanned as a script), 'O' optional ATTACHED argument.
def _tbl(n='', a='', w='', c='', o=''):
    d = {}
    for arity, chars in (('N', n), ('A', a), ('W', w), ('C', c), ('O', o)):
        for ch in chars:
            d['-' + ch] = arity
    return d


def _ltbl(n=(), a=(), w=(), c=(), o=()):
    d = {}
    for arity, names in (('N', n), ('A', a), ('W', w), ('C', c), ('O', o)):
        for nm in names:
            d['--' + nm] = arity
    return d


def _nw():
    """A nowrite entry (see above): pure-read operands, environment-insensitive."""
    return {'nowrite': True, 'envsafe': True, 'short': {}, 'long': {}, 'exact': {}, 'last': False,
            'text': False, 'danger': frozenset(), 'dpos': frozenset()}


def _strict(short, long_=None, exact=None, last=False, text=False, danger=(), dpos=(),
            envsafe=False):
    """danger: flags that make the command a writer; dpos: first operands that do (`bat cache`).
    envsafe: no environment variable can make the command write (so a protected env VALUE is
    ignored for it, command-string variables are still scanned)."""
    return {'nowrite': False, 'envsafe': envsafe, 'short': short, 'long': long_ or {},
            'exact': exact or {}, 'last': last, 'text': text, 'danger': frozenset(danger),
            'dpos': frozenset(dpos)}


_PW_READERS = {}
for _name in (
        # no option of these writes (audited: man / --help)
        'cat', 'head', 'tail', 'wc', 'ls', 'stat', 'cmp', 'diff', 'diff3', 'sha1sum', 'sha256sum',
        'sha512sum', 'shasum', 'md5', 'md5sum', 'cksum', 'b2sum', 'grep', 'egrep', 'fgrep',
        'zgrep', 'jq', 'od', 'hexdump', 'strings', 'basename', 'dirname', 'readlink', 'realpath',
        'pwd', 'du', 'df', 'test', '[', '[[', 'true', 'false', ':', 'type',
        'which', 'whereis', 'sleep', 'date', 'cut', 'tr', 'nl', 'column', 'fold', 'expand',
        'unexpand', 'paste', 'comm', 'join', 'rev', 'tac', 'fmt', 'shellcheck', 'seq', 'yes',
        'nproc', 'sw_vers',
        # status / info builtins whose operands are numbers or names, never executed
        'return', 'exit', 'break', 'continue', 'wait', 'getconf', 'id', 'whoami', 'uname',
        'hostname', 'printenv', 'umask', 'ulimit', 'tput', 'clear'):
    _PW_READERS[_name] = _nw()
# STRING-CARRYING builtins are NOT pure readers: their operands become variables, aliases,
# positional parameters or loop words that a later `eval` / `bash -c` / command word EXECUTES.
# (`alias w='cp a P'; eval w`, `set -- cp a P; "$@"`, `declare X='cp a P'; eval "$X"`,
# `read X <<< 'cp a P'; eval "$X"`, `for c in 'cp a P'; do eval "$c"; done`, `case 'cp a P' in`.)
# A protected root mentioned in an operand that contains whitespace or shell metacharacters
# blocks; a plain path operand (`D=~/.claude/scripts`) is only data. echo / printf only write
# to stdout, so they are blocked only when the command also contains a SINK that can run text
# (a shell, eval, source, xargs, an interpreter, `"$@"`): `echo 'cp a P' | bash`.
_PW_STRBUILTINS = frozenset((
    'echo', 'printf', 'export', 'declare', 'typeset', 'local', 'readonly', 'unset', 'set',
    'shift', 'read', 'alias', 'unalias', 'hash', 'for', 'select', 'case', 'esac', 'function',
    'done', 'fi', 'in'))
_PW_META = re.compile(r'[\s;&|<>()`$]')
_PW_SINK_RE = re.compile(
    r'(?<![\w.-])(?:bash|sh|zsh|dash|ksh|ksh93|ash|fish|csh|tcsh|eval|source|xargs|exec|'
    r'python[0-9.]*|node|nodejs|perl|ruby|php|lua|osascript|deno|bun|sqlite3|awk|gawk|mawk|ssh|at|'
    r'batch|parallel|tclsh|expect|script|crontab|make)(?![\w.-])|\$@|\$\*|'
    r'\$\{?SHELL|(?:^|[\s;&|(])\.\s')
# NOT allowlisted (cannot be characterised confidently, so they fail closed): ack (not
# installed), mdls (-plist FILE writes), lsof, most, colordiff, xargs, ll, la.
# yq and ag are not installed here either: their tables come from the tools' documentation and
# are deliberately PARTIAL -- an option missing from a table only drops the segment to the
# generic fail-closed path, it can never make a write look like a read (usability, not safety).
_PW_READERS.update({
    # Apple sort 2.3: -o FILE / -T DIR write; --compress-program PROG runs a command
    'sort': _strict(
        _tbl(n='bcCdfghiMmnRrsuVz', a='ktS', w='oT'),
        _ltbl(n=('merge', 'unique', 'version', 'help', 'ignore-leading-blanks', 'dictionary-order',
                 'ignore-case', 'general-numeric-sort', 'human-numeric-sort', 'ignore-nonprinting',
                 'month-sort', 'numeric-sort', 'random-sort', 'reverse', 'version-sort',
                 'zero-terminated', 'debug', 'radixsort', 'mergesort', 'qsort', 'heapsort', 'mmap',
                 'stable'),
              a=('key', 'field-separator', 'buffer-size', 'batch-size', 'random-source',
                 'files0-from', 'sort', 'parallel'),
              w=('output', 'temporary-directory'), c=('compress-program',), o=('check',))),
    # BSD uniq: `uniq [-cdiu] [-D[septype]] [-f fields] [-s chars] [input [output]]`
    'uniq': _strict(
        _tbl(n='cdiu', a='fs', o='D'),
        _ltbl(n=('count', 'repeated', 'ignore-case', 'unique'), a=('skip-fields', 'skip-chars'),
              o=('all-repeated',)), last=True),
    # xxd [options] [infile [outfile]]; single-dash long names are exact tokens (-ps is NOT -p -s)
    'xxd': _strict(
        _tbl(n='abCEehitrdupv', a='cglnosR'), None,
        exact={'-ps': 'N', '-postscript': 'N', '-plain': 'N', '-bits': 'N', '-capitalize': 'N',
               '-autoskip': 'N', '-EBCDIC': 'N', '-help': 'N', '-include': 'N', '-revert': 'N',
               '-uppercase': 'N', '-version': 'N', '-cols': 'A', '-groupsize': 'A', '-len': 'A',
               '-name': 'A', '-seek': 'A', '-offset': 'A'}, last=True),
    # BSD/GNU-compatible sdiff: -o FILE writes; --diff-program PROG runs a command
    'sdiff': _strict(
        _tbl(n='lsabditWBEH', a='wI', w='o'),
        _ltbl(n=('left-column', 'suppress-common-lines', 'text', 'ignore-space-change', 'minimal',
                 'ignore-case', 'expand-tabs', 'ignore-all-space', 'ignore-blank-lines',
                 'ignore-tab-expansion', 'speed-large-files', 'ignore-file-name-case',
                 'no-ignore-file-name-case', 'strip-trailing-cr'),
              a=('width', 'ignore-matching-lines', 'tabsize'), w=('output',),
              c=('diff-program',))),
    # tree (usage text): -o FILE writes
    'tree': _strict(
        _tbl(n='acdfghilnpqrstuvxACDFJQNSURX', a='LHTPI', w='o'),
        _ltbl(n=('gitignore', 'matchdirs', 'metafirst', 'ignore-case', 'nolinks', 'inodes', 'device',
                 'dirsfirst', 'filesfirst', 'si', 'du', 'prune', 'fromfile', 'fromtabfile',
                 'fflinks', 'info', 'noreport', 'hyperlink', 'opt-toggle', 'condense', 'version',
                 'help'),
              a=('gitfile', 'hintro', 'houtro', 'sort', 'filelimit', 'charset', 'timefmt',
                 'infofile', 'scheme', 'authority', 'compress'))),
    # ripgrep 15.2 (`rg --help`): --pre / --hostname-bin run a command; nothing writes
    'rg': _strict(
        _tbl(n='0FHILNPSUVabchilnopqsuvwxz', a='ABCEMTdefgjmrt'),
        _ltbl(n=('auto-hybrid-regex', 'binary', 'block-buffered', 'byte-offset', 'case-sensitive',
                 'column', 'count', 'count-matches', 'crlf', 'debug', 'files',
                 'files-with-matches', 'files-without-match', 'fixed-strings', 'follow',
                 'glob-case-insensitive', 'heading', 'help', 'ignore-case',
                 'ignore-file-case-insensitive', 'include-zero', 'invert-match', 'json',
                 'line-buffered', 'line-number', 'line-regexp', 'max-columns-preview', 'mmap',
                 'multiline', 'multiline-dotall', 'no-config', 'no-filename', 'no-ignore',
                 'no-ignore-dot', 'no-ignore-exclude', 'no-ignore-files', 'no-ignore-global',
                 'no-ignore-messages', 'no-ignore-parent', 'no-ignore-vcs', 'no-line-number',
                 'no-messages', 'no-pcre2-unicode', 'no-require-git', 'no-unicode', 'null',
                 'null-data', 'one-file-system', 'only-matching', 'passthru', 'pcre2',
                 'pcre2-version', 'pretty', 'quiet', 'search-zip', 'smart-case', 'sort-files',
                 'stats', 'stop-on-nonmatch', 'text', 'trace', 'trim', 'type-list', 'unrestricted',
                 'version', 'vimgrep', 'with-filename', 'word-regexp', 'no-pre', 'no-heading',
                 'no-column', 'no-follow', 'no-binary', 'no-mmap', 'no-multiline', 'no-crlf',
                 'no-fixed-strings', 'no-invert-match', 'no-search-zip', 'no-encoding',
                 'no-unicode', 'no-context-separator', 'no-max-columns-preview', 'no-ignore-parent',
                 'no-one-file-system', 'no-sort-files', 'no-trim', 'no-text', 'no-unrestricted',
                 'no-pcre2', 'no-line-buffered', 'no-block-buffered', 'no-auto-hybrid-regex',
                 'no-glob-case-insensitive', 'no-ignore-file-case-insensitive', 'no-stop-on-nonmatch',
                 'no-include-zero', 'no-byte-offset', 'no-count', 'no-json', 'no-passthru',
                 'no-null', 'no-null-data', 'no-only-matching', 'no-pretty', 'no-quiet',
                 'no-smart-case', 'no-stats', 'no-vimgrep', 'no-with-filename',
                 'no-word-regexp', 'no-line-regexp', 'no-ignore-case', 'no-case-sensitive',
                 'no-column', 'no-debug', 'no-trace'),
              a=('after-context', 'before-context', 'color', 'colors', 'context',
                 'context-separator', 'dfa-size-limit', 'encoding', 'engine',
                 'field-context-separator', 'field-match-separator', 'file', 'generate', 'glob',
                 'hyperlink-format', 'iglob', 'ignore-file', 'max-columns', 'max-count',
                 'max-depth', 'max-filesize', 'path-separator', 'pre-glob', 'regex-size-limit',
                 'regexp', 'replace', 'sort', 'sortr', 'threads', 'type', 'type-add', 'type-clear',
                 'type-not'),
              c=('pre', 'hostname-bin'))),
    # libmagic file: -C / --compile WRITES a .mgc file next to -m
    'file': _strict(
        _tbl(n='0CDILNSZbcdhiklnprsvz', a='FMefmP'),
        _ltbl(n=('brief', 'checking-printout', 'compile', 'debug', 'dereference', 'extension',
                 'help', 'keep-going', 'list', 'mime', 'mime-encoding', 'mime-type', 'no-buffer',
                 'no-dereference', 'no-pad', 'no-sandbox', 'parameter', 'preserve-date', 'print0',
                 'raw', 'special-files', 'uncompress', 'uncompress-noreport', 'version'),
              a=('exclude', 'exclude-quiet', 'files-from', 'magic-file', 'separator')),
        danger=('-C', '--compile')),
    # less(1) (`less --help`; macOS more IS less): -o/-O/--log-file/--LOG-FILE write a log. A
    # write option consumes the next word (conservative: it is the file we must not miss).
    # `+cmd` start-up commands (`+s FILE`, `+|cmd`) are program text -> text scan.
    'less': _strict(
        _tbl(n='?aABcdeEfFgGiIJKLmMnNqQrRsSuUVwWX~', a='bDhjkpPtTxyz"#', w='oO'),
        _ltbl(n=('search-skip-screen', 'SEARCH-SKIP-SCREEN', 'auto-buffers', 'clear-screen', 'dumb',
                 'quit-at-eof', 'QUIT-AT-EOF', 'force', 'quit-if-one-screen', 'hilite-search',
                 'HILITE-SEARCH', 'ignore-case', 'IGNORE-CASE', 'status-column', 'quit-on-intr',
                 'no-lessopen', 'long-prompt', 'LONG-PROMPT', 'line-numbers', 'LINE-NUMBERS',
                 'quiet', 'QUIET', 'silent', 'SILENT', 'raw-control-chars', 'RAW-CONTROL-CHARS',
                 'squeeze-blank-lines', 'chop-long-lines', 'underline-special',
                 'UNDERLINE-SPECIAL', 'version', 'hilite-unread', 'HILITE-UNREAD', 'no-init',
                 'tilde', 'exit-follow-on-close', 'file-size', 'follow-name', 'incsearch', 'mouse',
                 'no-keypad', 'no-histdups', 'no-number-headers', 'no-search-header-lines',
                 'no-search-header-columns', 'no-search-headers', 'no-vbell', 'redraw-on-quit',
                 'save-marks', 'show-preproc-errors', 'proc-backspace', 'PROC-BACKSPACE',
                 'proc-return', 'PROC-RETURN', 'proc-tab', 'PROC-TAB', 'status-line',
                 'use-backslash', 'use-color', 'wordwrap', 'help'),
              a=('buffers', 'max-back-scroll', 'jump-target', 'color', 'pattern', 'prompt', 'tag',
                 'tag-file', 'tabs', 'max-forw-scroll', 'window', 'quotes', 'shift', 'header',
                 'intr', 'line-num-width', 'match-shift', 'modelines', 'rscroll', 'search-options',
                 'status-col-width', 'wheel-lines', 'lesskey-context', 'lesskey-src',
                 'lesskey-file'),
              w=('log-file', 'LOG-FILE')), text=True),
    # bat 0.26 (`bat --help`): --pager runs a command; `bat cache --build` writes the cache
    'bat': _strict(
        _tbl(n='ApPdSnfsuLhV', a='lHmr'),
        _ltbl(n=('show-all', 'plain', 'diff', 'chop-long-lines', 'number', 'force-colorization',
                 'list-themes', 'squeeze-blank', 'list-languages', 'unbuffered', 'diagnostic',
                 'acknowledgements', 'set-terminal-title', 'help', 'version'),
              a=('nonprintable-notation', 'binary', 'language', 'highlight-line', 'file-name',
                 'diff-context', 'tabs', 'wrap', 'terminal-width', 'color', 'italic-text',
                 'decorations', 'paging', 'map-syntax', 'ignored-suffix', 'theme', 'theme-light',
                 'theme-dark', 'squeeze-limit', 'strip-ansi', 'style', 'line-range', 'completion'),
              c=('pager',)), dpos=('cache',), envsafe=True),
    # mikefarah yq v4 (documented; PARTIAL): -i / -s write
    'yq': _strict(
        _tbl(n='cCeMnNPrvh', a='fIop'),
        _ltbl(n=('colors', 'no-colors', 'exit-status', 'null-input', 'no-doc', 'prettyPrint',
                 'unwrapScalar', 'verbose', 'help'),
              a=('front-matter', 'indent', 'output-format', 'input-format', 'from-file')),
        danger=('-i', '--inplace', '-s', '--split-exp')),
    # the silver searcher (documented; PARTIAL): --pager runs a command
    'ag': _strict(
        _tbl(n='acfFilLnQsSuUvwz0', a='ABCGgmp'),
        _ltbl(n=('all-types', 'count', 'follow', 'fixed-strings', 'ignore-case', 'files-with-matches',
                 'files-without-matches', 'nonumbers', 'literal', 'case-sensitive', 'smart-case',
                 'unrestricted', 'skip-vcs-ignores', 'invert-match', 'word-regexp', 'search-zip',
                 'hidden', 'noheading', 'nocolor', 'nogroup', 'column', 'stats', 'null', 'silent',
                 'vimgrep', 'numbers', 'heading', 'color', 'group', 'version', 'help'),
              a=('after-context', 'before-context', 'context', 'file-search-regex', 'ignore',
                 'ignore-dir', 'depth', 'path-to-ignore', 'max-count'),
              c=('pager',)), envsafe=True),
    # BSD sed (`sed script [-EHalnru] [-i ext] [file ...]`): program text may `w FILE` -> text scan
    'sed': _strict(_tbl(n='EHalnru', a='ef'), text=True),
    # onetrue awk 20200816: program text may `print > "FILE"` / system() -> text scan
    'awk': _strict(_tbl(n='dV', a='Fvf'), None,
                   exact={'-safe': 'N', '-version': 'N', '--version': 'N'}, text=True),
})
# `more` on macOS IS less(1)
_PW_READERS['more'] = _PW_READERS['less']
# strict readers that no environment variable can turn into a writer: a protected env VALUE is
# ignored for them (command-string variables are still scanned). NOT sort (TMPDIR), sdiff,
# less/more (LESSHISTFILE), yq.
for _n in ('uniq', 'xxd', 'tree', 'rg', 'file', 'sed', 'awk'):
    _PW_READERS[_n]['envsafe'] = True
# interpreters: argv[1] is the script (read); every OTHER operand is data the script may write
_PW_INTERP_RE = re.compile(
    r'^(?:python[0-9.]*|pypy[0-9]*|node|nodejs|deno|bun|tsx|ts-node|php|lua|perl|ruby|osascript|'
    r'Rscript|julia|swift)$')
_PW_SHELL_EXEC = frozenset(('bash', 'sh', 'zsh', 'dash', 'ksh', 'ksh93', 'ash', 'fish', 'csh', 'tcsh'))
# tools that merge / extract into a directory operand: an ANCESTOR of the roots is as bad as a root
_PW_ANC_TOOLS = frozenset(('cpio', 'pax', '7z', '7za', '7zr', 'unrar', 'unar', 'ar', 'bsdcpio'))
# git subcommands whose path operands are never written
_PW_GIT_READ = frozenset((
    'diff', 'log', 'show', 'status', 'ls-files', 'ls-tree', 'cat-file', 'rev-parse', 'rev-list',
    'grep', 'blame', 'describe', 'shortlog', 'show-ref', 'check-ignore', 'merge-base', 'name-rev',
    'for-each-ref', 'count-objects', 'config', 'add', 'commit', 'branch', 'tag', 'fetch',
    'remote', 'var', 'version', 'help', 'whatchanged', 'diff-tree', 'diff-index', 'diff-files',
))


def _pw_arg_cands(ctx, tok):
    """The words inside one argument that may name a path: the argument itself (not a bare
    flag), a `--opt=VALUE` / `of=VALUE` / `VAR=VALUE` value, the path glued to a short flag
    (`-C/path`, `-o~/x`), and each whitespace-separated piece of a quoted command string
    (`su -c 'cp a ~/.claude/scripts/x'`, `env -S '...'`)."""
    out = []
    if not tok.startswith('-'):
        out.append(tok)
    if '=' in tok:
        out.append(tok.split('=', 1)[1])
    if tok.startswith('-') and not tok.startswith('--'):
        for i, ch in enumerate(tok):
            if ch in '/~$':
                out.append(tok[i:])
                break
    if len(tok) <= PW_MAX_TOKEN and (' ' in tok or '\t' in tok or '\n' in tok):
        out.extend(_pw_unquote(tok, ctx.home, payload=True, variables=ctx.vars)[0].split()[:64])
    return out


def _pw_generic(ctx, b, args, cwd):
    """True if ANY argument of an unrecognised / non-reader command names a protected path
    (inside a root or a root itself); an ancestor counts too for a recursive-capable or
    merge / extract tool. Redirects are checked separately for every command."""
    toks = []
    i = 0
    n = len(args)
    while i < n:
        t = args[i]
        if t.startswith('#'):
            break
        if REDIR_RE.match(t):
            i += 2 if BARE_REDIR_RE.match(t) else 1
            continue
        t = _strip_attached_redirect(t)
        if t:
            toks.append(t)
        i += 1
    recursive = b in _PW_ANC_TOOLS or any(
        re.match(r'^-[A-Za-z]*[rRa][A-Za-z]*$', t) or t in ('--recursive', '--archive')
        for t in toks)
    for t in toks:
        for c in _pw_arg_cands(ctx, t):
            if _pw_hit(ctx, c, cwd, 2 if recursive else 0):
                return True
        # a protected root named ANYWHERE inside the word (`w$HOME/.claude/scripts/y`, a quoted
        # command string, an option value) is a mention too
        if len(t) <= PW_MAX_PAYLOAD and _pw_mention(ctx, _pw_unquote(t, ctx.home, payload=True, variables=ctx.vars)[0]):
            return True
    return False


def _pw_interp(ctx, args, cwd):
    """An interpreter (python / node / perl ...): argv[1] -- the script -- is read, so a
    protected SCRIPT is fine to run; every other operand is data the script may write."""
    valued = ('-W', '-X', '-Q', '-I', '-r', '--require', '--loader', '--import', '-C', '-F')
    code = any((t.startswith('-') and not t.startswith('--') and t[-1] in 'ceEmp')
               or t in ('--eval', '--print', '--exec') for t in args)
    out = []
    script_seen = code
    i = 0
    while i < len(args):
        t = args[i]
        # python writes .pyc files below -X pycache_prefix=DIR: a write slot
        pyc = t[2:] if t.startswith('-X') and len(t) > 2 else (
            args[i + 1] if t == '-X' and i + 1 < len(args) else None)
        if pyc is not None and pyc.startswith('pycache_prefix=') \
                and _pw_hit(ctx, pyc.split('=', 1)[1], cwd):
            return True
        if t in valued:
            i += 2
            continue
        if not script_seen and not t.startswith('-'):
            script_seen = True  # the script itself
            i += 1
            continue
        out.append(t)
        i += 1
    return _pw_generic(ctx, 'interp', out, cwd)


def _pw_shell_parse(ctx, b, args):
    """-> (payload_or_None, remaining_operands, noexec) for a shell invocation. Understands the
    options that take a separate operand (`-o X`, `+o X`, `-O X`, `+O X`, `--rcfile X`,
    `--init-file X`, a cluster ending in o/O such as `-eo pipefail`), `--`, and `-c`."""
    if b in ('source', '.'):
        return None, args[1:], False
    n = len(args)
    i = 0
    has_c = False
    noexec = False
    valued = ('-o', '+o', '-O', '+O', '--rcfile', '--init-file')
    while i < n:
        t = args[i]
        if t == '--':
            i += 1
            break
        if t in valued:
            i += 2
            continue
        if t.startswith('--'):
            i += 1
            continue
        if len(t) > 1 and t[0] in '-+':
            if t[0] == '-' and 'c' in t[1:]:
                has_c = True
            if t[0] == '-' and 'n' in t[1:]:
                noexec = True
            i += 2 if t[-1] in 'oO' else 1
            continue
        break
    if has_c:
        payload = ''
        if i < n and len(args[i]) <= PW_MAX_PAYLOAD:
            payload = _pw_unquote(args[i], ctx.home, payload=True, variables=ctx.vars)[0]
        return payload, args[i + 1:], noexec
    return None, args[i + 1:], noexec  # script mode: args[i] is the script (read)


def _pw_git(ctx, args, cwd):
    """git: a repository / work-tree selector (`-C X`, `--git-dir X`, `--work-tree X`, the `=` forms,
    GIT_DIR= / GIT_WORK_TREE=) that names a protected root OR an ancestor of one lets a
    subcommand write there (`git --work-tree ~/.claude checkout-index -f -- scripts/x`): blocked for
    every subcommand except a short pure-read set."""
    sub = None
    i = 0
    n = len(args)
    repo_dirs = list(getattr(ctx, 'git_env_dirs', ()))
    while i < n:
        t = args[i]
        if t in ('-C', '-c', '--git-dir', '--work-tree', '--namespace', '--exec-path',
                 '--super-prefix'):
            if t in ('-C', '--git-dir', '--work-tree') and i + 1 < n:
                repo_dirs.append(args[i + 1])
            i += 2
            continue
        if t.startswith('--git-dir=') or t.startswith('--work-tree='):
            repo_dirs.append(t.split('=', 1)[1])
            i += 1
            continue
        if t.startswith('-'):
            i += 1
            continue
        sub = t
        break
    if sub not in _PW_GIT_PURE and _pw_any(ctx, repo_dirs, cwd, structural=2):
        return True
    if sub in _PW_GIT_READ:
        flags = [t for t in args if t.startswith('-')]
        if any(t.startswith('--output') or t in ('-f', '--file') or t.startswith('--file=')
               for t in flags):
            return _pw_generic(ctx, 'git', args, cwd)
        return False
    return _pw_generic(ctx, 'git', args, cwd)


_PW_NAMES = (r'(?:\.claude/(?:githooks|scripts|config|install-manifest\.sha256|cast-state)'
             r'|library/(?:caches/com\.apple\.python|python|launchagents))')
_PW_MENTION_RE = re.compile(r'(?:~|\$home|\$\{home\})/' + _PW_NAMES + r'(?![a-z0-9._-])')
_PW_TEXT_SEP = re.compile(r"""[\s"';{}()<>|&,]""")
# environment variables whose VALUE is a command string some program will RUN
_PW_ENV_CMDSTR = re.compile(
    r'^(?:ps[0-9]|prompt_command|bash_env|env|lessopen|lessclose|pager|manpager|git_pager|editor|'
    r'visual|git_editor|git_sequence_editor|git_external_diff|git_ssh|git_ssh_command|'
    r'git_askpass|ssh_askpass|fcedit|.*_command|.*_cmd|.*_pager|.*_editor|.*_askpass)$', re.I)
# variables that only SELECT what to run / import (PATH, PYTHONPATH): not a write destination
_PW_ENV_SELECT = frozenset(('PATH', 'PYTHONPATH'))
_PW_GIT_PURE = frozenset(('status', 'diff', 'log', 'show', 'ls-files', 'rev-parse', 'cat-file',
                          'grep', 'blame'))


def _pw_mention_norm(ctx, tl):
    t = re.sub(r'/+', '/', tl).replace('/./', '/')
    for _ in range(4):
        t2 = re.sub(r'/[^/\s]+/\.\./', '/', t)
        if t2 == t:
            break
        t = t2
    t = t.replace(_FIRMLINK, '')
    for h in ctx.homes:
        t = re.sub(re.escape(h) + r'(?=/|$)', '~', t)
    if _PW_MENTION_RE.search(t):
        return True
    for r in ctx.roots:
        if re.search(re.escape(r) + r'(?![a-z0-9._-])', t):
            return True
    return False


def _pw_mention(ctx, text):
    """True if `text` contains a protected root path ANYWHERE as a substring, after the same
    normalisation words get: $HOME / ${HOME} / ~ / the passwd home / realpath home, the APFS
    firmlink prefix, case, `//` `/./` `..`, with quote characters removed (`'..'"'"'..'` splices
    re-join), and glob / bracket spellings inside the text (`cp a ~/.claude/s*/x`) resolved
    piece by piece. (`w$HOME/.claude/scripts/y`, `|cp a ~/.claude/..`.)"""
    tl = text.lower()
    glob = ('*' in tl or '?' in tl or '[' in tl) and '/' in tl
    if '.claude' not in tl and '/library/' not in tl and not glob \
            and not any(r in tl for r in ctx.roots):
        return False
    if _pw_mention_norm(ctx, tl):
        return True
    unq = re.sub(r"['\"\\]", '', tl)
    if unq != tl and _pw_mention_norm(ctx, unq):
        return True
    if glob:
        for piece in _PW_TEXT_SEP.split(text)[:256]:
            if piece and len(piece) <= PW_MAX_TOKEN and _pw_hit(ctx, piece, None, 0):
                return True
    return False


def _pw_body_touches(ctx, body):
    """Does a command-substitution BODY mention / name / resolve to a protected path?"""
    if len(body) > PW_MAX_PAYLOAD:
        return False
    if _pw_mention(ctx, body):
        return True
    for tok in tokenize(body)[:64]:
        if len(tok) <= PW_MAX_TOKEN and _pw_hit(ctx, tok, None, 2):
            return True
    return False


def _pw_env_script_blocked(ctx, name, val, cwd, depth):
    """A command-string variable (PS4, PROMPT_COMMAND, LESSOPEN, PAGER, EDITOR,
    GIT_EXTERNAL_DIFF, GIT_SSH_COMMAND, *_COMMAND, *_CMD ...) holds a SCRIPT: scan it as one."""
    if not val or not _PW_ENV_CMDSTR.match(name) or len(val) > PW_MAX_PAYLOAD:
        return False
    if depth >= PW_MAX_DEPTH:
        return True
    return _pw_scan(_pw_unquote(val, ctx.home, payload=True, variables=ctx.vars)[0], ctx, cwd, depth + 1)[0]


def _pw_env_value_protected(ctx, name, val, cwd):
    """True if an assignment's VALUE mentions a protected root anywhere, is inside one, or is an
    ANCESTOR of one (`~/.claude`, `~`, `/`, the home's parents) -- for ANY variable name.
    PATH is exempt: it selects what to RUN (a planted binary would first need a write into the
    root, which this rule blocks), not where to write."""
    if not val or name.upper() in _PW_ENV_SELECT or len(val) > PW_MAX_PAYLOAD:
        return False
    if '$_SM' in val:  # `$(dirname ~/.claude/scripts/x)`: the substitution resolves to a root
        return True
    if _pw_mention(ctx, _pw_unquote(val, ctx.home, payload=True, variables=ctx.vars)[0]):
        return True
    if len(val) > PW_MAX_TOKEN:
        return False
    for piece in val.split(':'):
        if piece and (piece[0] in '/~$' or '/' in piece) and _pw_hit(ctx, piece, cwd, 2):
            return True
    return False


def _pw_env_assign(ctx, name, val, cwd, depth, exported):
    """Record / judge one assignment seen by the SHELL ITSELF (bare, export, declare, readonly,
    local, printf -v ...). Blocks a command-string variable holding a harmful script at once, and a
    protected value as soon as the name is exported (either order: `export X; X=P`,
    `X=P; export X`, `declare X=P; export X`, `set -a`)."""
    if _pw_env_script_blocked(ctx, name, val, cwd, depth):
        return True
    if _pw_env_value_protected(ctx, name, val, cwd):
        if exported or ctx.allexport or name in ctx.exported:
            return True
        ctx.prot_vars.add(name)
    return False


def _pw_reader(ctx, b, args, cwd, depth):
    """An allowlisted command. nowrite entries: every operand is a read. strict entries: parse the
    argv against the COMPLETE option table; anything unknown/ambiguous -> generic fail-closed."""
    spec = _PW_READERS[b]
    if spec['nowrite']:
        return False
    parsed = _pw_strict_parse(spec, args)
    if parsed is None or (parsed[2] & spec['danger']) or (parsed[0] and parsed[0][0] in spec['dpos']):
        return _pw_generic(ctx, b, args, cwd)
    pos, vals, _keys = parsed
    for role, v in vals:
        if role == 'W' and _pw_hit(ctx, v, cwd):
            return True
        if role == 'C':
            if len(v) > PW_MAX_PAYLOAD:
                continue
            if depth >= PW_MAX_DEPTH:
                return True
            if _pw_scan(_pw_unquote(v, ctx.home, payload=True, variables=ctx.vars)[0], ctx, cwd, depth + 1)[0]:
                return True
    if spec['last'] and _pw_any(ctx, pos[1:], cwd):
        return True  # `uniq in OUT`, `xxd in OUT`: every operand after the first is an output
    if spec['text']:  # program text: a mention that is not itself an input-file word
        for tok in args:
            if len(tok) <= PW_MAX_PAYLOAD and not _pw_hit(ctx, tok, cwd) \
                    and _pw_mention(ctx, _pw_unquote(tok, ctx.home, payload=True, variables=ctx.vars)[0]):
                return True
    return False


def _pw_strict_parse(spec, args):
    """-> (operands, [(role, value)], keys) or None when an option is unknown, ambiguous (GNU
    unique-prefix resolution against the COMPLETE table), or has the wrong arity."""
    short, long_, exact = spec['short'], spec['long'], spec['exact']
    pos = []
    vals = []
    keys = set()
    after_dd = False
    n = len(args)
    i = 0
    while i < n:
        t = args[i]
        if t.startswith('#'):
            break
        if REDIR_RE.match(t):
            i += 2 if BARE_REDIR_RE.match(t) else 1
            continue
        if after_dd or t == '-' or not t.startswith('-'):
            tt = _strip_attached_redirect(t)
            if tt:
                pos.append(tt)
            i += 1
            continue
        if t == '--':
            after_dd = True
            i += 1
            continue
        if t in exact:
            keys.add(t)
            if exact[t] != 'N':
                if i + 1 >= n:
                    return None
                vals.append(('A', args[i + 1]))
                i += 1
            i += 1
            continue
        if t.startswith('--'):
            name, eq, val = t.partition('=')
            if name in long_:
                key = name
            else:
                cands = [k for k in long_ if k.startswith(name)]
                if len(cands) != 1:
                    return None
                key = cands[0]
            arity = long_[key]
            keys.add(key)
            if arity == 'N':
                if eq:
                    return None
            elif arity == 'O':
                if eq:
                    vals.append(('A', val))
            else:
                if eq:
                    v = val
                elif i + 1 < n:
                    v = args[i + 1]
                    i += 1
                else:
                    return None
                vals.append((arity, v))
            i += 1
            continue
        j = 1
        while j < len(t):
            key = '-' + t[j]
            if key not in short:
                return None
            arity = short[key]
            keys.add(key)
            if arity == 'N':
                j += 1
                continue
            rest = t[j + 1:]
            if arity == 'O':
                if rest:
                    vals.append(('A', rest))
                break
            if rest:
                v = rest
            elif i + 1 < n:
                v = args[i + 1]
                i += 1
            else:
                return None
            vals.append((arity, v))
            break
        i += 1
    return pos, vals, keys


def _pw_strbuiltin(ctx, b, args):
    """A string-carrying builtin (see _PW_STRBUILTINS): block a protected root mentioned inside
    an operand that holds whitespace / shell metacharacters (text that could be executed later)."""
    if b in ('echo', 'printf'):
        if not ctx.sink:
            return False
        # `echo cp a P | sh`: the words only form the command once JOINED
        words = []
        for t in args:
            if t.startswith('#'):
                break
            if len(t) <= PW_MAX_PAYLOAD and not REDIR_RE.match(t):
                words.append(_pw_unquote(t, ctx.home, payload=True, variables=ctx.vars)[0])
        joined = ' '.join(words)
        return bool(_PW_META.search(joined)) and _pw_mention(ctx, joined)
    for t in args:
        if t.startswith('#'):
            break
        if len(t) > PW_MAX_PAYLOAD:
            continue
        text = _pw_unquote(t, ctx.home, payload=True, variables=ctx.vars)[0]
        if _PW_META.search(text) and _pw_mention(ctx, text):
            return True
    return False


def _pw_command_writes(ctx, b, args, cwd, depth):
    """True if command `b` (basename, wrappers already peeled) with `args` writes / moves /
    links / chmods / deletes a protected path. Reads are never flagged."""
    if len(b) > 1 and b[0] == 'g' and b[1:] in _PW_GNU:
        b = b[1:]

    if b in ('tee', 'sponge'):
        pos, _o = _pw_parse_args(args)
        return _pw_any(ctx, pos, cwd)

    if b in ('cp', 'install', 'ditto', 'rsync', 'mv', 'link'):
        if b == 'rsync':
            short = 'ef'
            long_arg = ('exclude', 'include', 'exclude-from', 'include-from', 'files-from',
                        'filter', 'rsh', 'rsync-path', 'backup-dir', 'partial-dir', 'log-file',
                        'temp-dir', 'chmod', 'chown', 'compare-dest', 'copy-dest', 'link-dest',
                        'max-size', 'min-size', 'port', 'timeout', 'bwlimit', 'suffix')
        elif b in ('ditto', 'link'):
            short, long_arg = '', ()
        else:
            short = 'tSmog'
            long_arg = ('target-directory', 'suffix', 'mode', 'owner', 'group')
        pos, opts = _pw_parse_args(args, short, long_arg)
        flags = set(f for f, _v in opts)
        tdir = [v for f, v in opts if f in ('t', '--target-directory') and v]
        if tdir:
            dests, sources = tdir, pos
        elif b == 'install' and 'd' in flags:
            dests, sources = pos, []
        elif len(pos) >= 2:
            dests, sources = pos[-1:], pos[:-1]
        else:
            dests, sources = [], pos
        if _pw_any(ctx, dests, cwd):
            return True
        # merging a tree into an ANCESTOR of the roots (`cp -R src/. ~/.claude/`) overwrites them
        merge = (b == 'ditto' or bool(flags & set(('r', 'R', 'a', '--recursive', '--archive')))
                 ) and b != 'mv'
        if merge and _pw_any(ctx, dests, cwd, structural=2):
            return True
        if b == 'mv':
            if _pw_any(ctx, sources, cwd, structural=True):
                return True  # moving a protected source AWAY is a delete
            if _pw_any(ctx, dests, cwd, structural=2):
                # `mv /tmp/evil/scripts ~/.claude/`: a source that IS (or may be) a root's name
                for src in sources:
                    leaf = strip_all_quotes(src).rstrip('/').rsplit('/', 1)[-1].lower()
                    if (leaf in PW_ROOT_NAMES or leaf in ('', '.', '..', '.claude')
                            or any(ch in leaf for ch in '*?[$')):
                        return True
        if b == 'rsync' and '--remove-source-files' in flags and _pw_any(ctx, sources, cwd):
            return True
        return False

    if b == 'ln':
        pos, opts = _pw_parse_args(args, 'tS', ('target-directory', 'suffix'))
        tdir = [v for f, v in opts if f in ('t', '--target-directory') and v]
        if tdir:
            return _pw_any(ctx, tdir, cwd, structural=True)
        if len(pos) >= 2:
            return _pw_any(ctx, pos[-1:], cwd, structural=True)
        if len(pos) == 1:  # `ln -s /x/y` creates ./y
            name = strip_all_quotes(pos[0]).rstrip('/').rsplit('/', 1)[-1]
            return bool(name) and _pw_hit(ctx, name, cwd, structural=True)
        return False

    if b in ('rm', 'unlink', 'rmdir', 'shred', 'srm'):
        pos, opts = _pw_parse_args(args)
        rec = bool(set(f for f, _v in opts) & set(('r', 'R', '--recursive')))
        return _pw_any(ctx, pos, cwd, structural=2 if rec else 1)

    if b in ('chmod', 'chown', 'chgrp', 'chflags', 'xattr', 'touch', 'truncate'):
        short = {'touch': 'rtd', 'truncate': 'sr'}.get(b, '')
        pos, opts = _pw_parse_args(args, short, ('reference', 'date', 'size', 'time'))
        flags = set(f for f, _v in opts)
        if b == 'xattr' and not (flags & set(('w', 'd', 'c'))):
            return False  # -l / -p / plain listing: a read
        recursive = b in ('chmod', 'chown', 'chgrp', 'chflags', 'xattr') and bool(
            flags & set(('R', 'r', '--recursive')))
        return _pw_any(ctx, pos, cwd, structural=2 if recursive else 0)

    if b in ('sed', 'ssed'):
        pos, opts = _pw_parse_args(args, 'efl', ('expression', 'file', 'line-length'),
                                   stop_at='i')
        flags = set(f for f, _v in opts)
        if not (flags & set(('i', '--in-place'))):
            return _pw_reader(ctx, 'sed', args, cwd, depth)
        if not (flags & set(('e', 'f', '--expression', '--file'))):
            pos = pos[1:]  # the first positional is the script
        return _pw_any(ctx, pos, cwd)

    if b in ('perl', 'ruby'):
        pos, opts = _pw_parse_args(args, 'eEIM', stop_at='i')
        if 'i' not in set(f for f, _v in opts):
            return _pw_interp(ctx, args, cwd)
        return _pw_any(ctx, pos, cwd)

    if b in ('awk', 'gawk'):
        pos, opts = _pw_parse_args(args, 'ifvFE')
        if not any(f == 'i' and v == 'inplace' for f, v in opts):
            return _pw_reader(ctx, 'awk', args, cwd, depth)
        if 'f' not in set(f for f, _v in opts):
            pos = pos[1:]
        return _pw_any(ctx, pos, cwd)

    if b in ('ed', 'ex'):
        pos, _o = _pw_parse_args(args, 'cS')
        return _pw_any(ctx, pos, cwd)

    if b in ('patch', 'gpatch'):
        pos, opts = _pw_parse_args(args, 'odipFBVYzrD',
                                   ('directory', 'output', 'input', 'strip', 'reject-file'))
        outs = [v for f, v in opts if f in ('o', 'd', 'r', '--output', '--directory',
                                            '--reject-file') and v]
        return _pw_any(ctx, pos + outs, cwd)

    if b == 'dd':
        for a in args:
            if a.startswith('of=') and _pw_hit(ctx, a[3:], cwd):
                return True
        return False

    if b in ('curl', 'wget'):
        pos, opts = _pw_parse_args(args, 'o' if b == 'curl' else 'OP',
                                   ('output', 'output-dir') if b == 'curl' else
                                   ('output-document', 'directory-prefix'))
        outs = [v for f, v in opts if v and f in ('o', 'O', 'P', '--output', '--output-dir',
                                                   '--output-document', '--directory-prefix')]
        return _pw_any(ctx, outs, cwd)

    if b == 'find':
        return _pw_find_writes(ctx, args, cwd, depth)

    if b in ('tar', 'bsdtar'):
        letters = set()
        if args and re.match(r'^[A-Za-z]+$', args[0]):  # old style: tar xzf a.tgz
            letters = set(args[0])
            args = args[1:]
        pos, opts = _pw_parse_args(args, 'CfTXIK', ('directory', 'file', 'files-from'))
        flags = set(f for f, _v in opts)
        letters |= set(f for f in flags if len(f) == 1)
        extract = 'x' in letters or bool(flags & set(('--extract', '--get')))
        create = bool(letters & set(('c', 'r', 'u'))) or bool(
            flags & set(('--create', '--append', '--update')))
        dirs = [v for f, v in opts if f in ('C', '--directory') and v]
        files = [v for f, v in opts if f in ('f', '--file') and v]
        if extract:
            if dirs:
                if _pw_any(ctx, dirs, cwd, structural=2):
                    return True
            elif _pw_hit(ctx, '.', cwd, structural=2):
                return True  # extracts into the (protected / ancestor) cwd
        if create and _pw_any(ctx, files, cwd):
            return True
        return False

    if b == 'unzip':
        pos, opts = _pw_parse_args(args, 'dxP')
        dirs = [v for f, v in opts if f == 'd' and v]
        if dirs:
            return _pw_any(ctx, dirs, cwd, structural=2)
        flags = set(f for f, _v in opts)
        if not (flags & set(('l', 't', 'p', 'v', 'z'))):
            return _pw_hit(ctx, '.', cwd, structural=2)
        return False

    if b == 'eval' or b == 'trap':
        if b == 'eval':
            words = [a for a in args if len(a) <= PW_MAX_PAYLOAD]
            payload = ' '.join(_pw_unquote(a, ctx.home, payload=True, variables=ctx.vars)[0] for a in words)
        else:  # trap 'cmd' SIG ...: the first operand is a command STRING run later
            first = [a for a in args if a != '--']
            payload = None
            if first and not first[0].startswith('-') and len(first[0]) <= PW_MAX_PAYLOAD:
                payload = _pw_unquote(first[0], ctx.home, payload=True, variables=ctx.vars)[0]
        if payload:
            if depth >= PW_MAX_DEPTH:
                return True  # nobody legitimately nests shells this deep: fail closed
            return _pw_scan(payload, ctx, cwd, depth + 1)[0]
        return False

    if b in _PW_SHELL_EXEC or b in ('source', '.'):
        payload, rest, noexec = _pw_shell_parse(ctx, b, args)
        if payload is not None:
            if payload and depth >= PW_MAX_DEPTH:
                return True
            if payload and _pw_scan(payload, ctx, cwd, depth + 1)[0]:
                return True
            return _pw_generic(ctx, b, rest, cwd)
        return False if noexec else _pw_generic(ctx, b, rest, cwd)

    if b == 'git':
        return _pw_git(ctx, args, cwd)

    if b == 'defaults':  # `defaults read PATH` reads; `defaults write` still names + writes
        return False if (args and args[0] in ('read', 'read-type')) else _pw_generic(
            ctx, b, args, cwd)

    if b == 'launchctl':  # lifecycle verbs act on a LOADED job; none of them writes the plist
        sub = next((a for a in args if not a.startswith('-')), None)
        if sub in ('print', 'list', 'bootstrap', 'bootout', 'load', 'unload', 'enable',
                   'disable', 'print-cache', 'blame', 'kickstart'):
            return False
        return _pw_generic(ctx, b, args, cwd)

    if b == 'plutil':  # only the read-only modes are a read
        return False if (args and args[0] in ('-p', '-lint', '-type', '-help')) else \
            _pw_generic(ctx, b, args, cwd)

    if _PW_INTERP_RE.match(b):
        return _pw_interp(ctx, args, cwd)

    if b in _PW_STRBUILTINS:
        return _pw_strbuiltin(ctx, b, args)

    if b in _PW_READERS:
        return _pw_reader(ctx, b, args, cwd, depth)

    # INVERTED default: a command we do not recognise as a reader is assumed to WRITE whatever
    # protected path it is handed (hidden behind an unlisted wrapper, `mkfifo`, `zip`, `split`,
    # `sqlite3`, `defaults write`, ...).
    return _pw_generic(ctx, b, args, cwd)


def _pw_find_writes(ctx, args, cwd, depth):
    i = 0
    n = len(args)
    while i < n and (args[i] in ('-H', '-L', '-P', '-E', '-X', '-x', '-s')
                     or re.match(r'^-O\d$', args[i])):
        i += 1
    starts = []
    while i < n and not (args[i].startswith('-') or args[i] in ('(', '\\(', '!', '\\!')):
        starts.append(args[i])
        i += 1
    if not starts:
        starts = ['.']
    rest = args[i:]
    destructive = False
    for j, t in enumerate(rest):
        if t == '-delete':
            destructive = True
        elif t in ('-exec', '-execdir', '-ok', '-okdir'):
            run = []
            for w in rest[j + 1:]:
                if w in (';', '\\;', '+'):
                    break
                run.append(w)
            if run:
                if basename(run[0]) not in _PW_READ_EXEC:
                    destructive = True
                if _pw_command_writes(ctx, basename(run[0]), run[1:], cwd, depth):
                    return True
        elif t in ('-fprint', '-fprint0', '-fprintf', '-fls') and j + 1 < len(rest):
            if _pw_hit(ctx, rest[j + 1], cwd):
                return True
    return destructive and _pw_any(ctx, starts, cwd, structural=2)


def _pw_match_paren(text, i):
    """Index of the `)` closing the `(` at text[i] (quote / backslash / nesting aware), or
    len(text) when unterminated."""
    n = len(text)
    depth = 0
    j = i
    while j < n:
        c = text[j]
        if c == '\\':
            j += 2
            continue
        if c == "'":
            k = text.find("'", j + 1)
            j = k + 1 if k >= 0 else n
            continue
        if c == '"':
            j += 1
            while j < n and text[j] != '"':
                j += 2 if text[j] == '\\' else 1
            j += 1
            continue
        if c == '(':
            depth += 1
        elif c == ')':
            depth -= 1
            if depth == 0:
                return j
        j += 1
    return n


def _pw_split_subst(command, ctx=None):
    """Lift command substitutions out of a command line: `$(...)`, backticks and process
    substitution `<(...)` / `>(...)` (single quotes keep them inert). Returns
    (outer_text, [bodies]); each construct is replaced in the outer text by `$_S`, an unknown
    parameter, so a word like `~/.claude/$(echo scripts)/y` stays ONE word (dynamic) instead
    of being cut at the `(`. The bodies are scanned as commands of their own."""
    out = []
    bodies = []
    i = 0
    n = len(command)
    in_s = in_d = False
    while i < n:
        c = command[i]
        if in_s:
            out.append(c)
            if c == "'":
                in_s = False
            i += 1
            continue
        if c == '\\' and i + 1 < n:
            out.append(command[i:i + 2])
            i += 2
            continue
        if c == "'" and not in_d:
            in_s = True
            out.append(c)
            i += 1
            continue
        if c == '"':
            in_d = not in_d
            out.append(c)
            i += 1
            continue
        if c == '`':
            j = i + 1
            while j < n and command[j] != '`':
                j += 2 if command[j] == '\\' else 1
            body = command[i + 1:j].replace('\\`', '`')
            bodies.append(('cmd', body))
            out.append('$_SM' if ctx is not None and _pw_body_touches(ctx, body) else '$_S')
            i = j + 1
            continue
        if i + 1 < n and command[i + 1] == '(' and (c == '$' or (c in '<>' and not in_d)):
            j = _pw_match_paren(command, i + 1)
            kind = 'ps' if c == '<' else 'cmd'
            body = command[i + 2:j]
            bodies.append((kind, body))
            out.append('$_PS' if c == '<' else (
                '$_SM' if ctx is not None and c == '$' and _pw_body_touches(ctx, body) else '$_S'))
            i = j + 1
            continue
        out.append(c)
        i += 1
    return ''.join(out), bodies


_PW_SHELLS = frozenset(('bash', 'sh', 'zsh', 'dash', 'ksh', 'ksh93', 'ash', 'fish', 'csh', 'tcsh',
                        'source', '.'))


def _pw_shell_heredoc_bodies(command, ctx):
    """Bodies of heredocs whose introducing line runs a shell (`bash <<EOF`, `cat <<EOF | sh`,
    `source /dev/stdin <<EOF`). strip_heredocs drops every heredoc body as inert data, which is
    right for `cat > file <<EOF` but hides a script handed to an interpreter. Other
    interpreters (`python3 <<EOF`) stay an accepted residual."""
    if '<<' not in command:
        return []
    bodies = []
    pending = []  # [word, strip_tabs, runs_shell, lines]
    for line in command.split('\n'):
        if pending:
            word, strip_tabs, _sh, buf = pending[0]
            check = line.lstrip('\t') if strip_tabs else line
            if check.strip() == word:
                done = pending.pop(0)
                if done[2]:
                    bodies.append('\n'.join(done[3]))
            else:
                buf.append(line)
            continue
        if '<<' not in line:
            continue
        words = _find_heredoc_words(line)
        if not words:
            continue
        runs_shell = False
        for seg in split_segments(line, wr=True):
            toks = tokenize_cmd(seg)
            _a, cmd, args = command_and_args(toks)
            cmd, args = _pw_unwrap(cmd, args, ctx)
            if cmd is not None and basename(cmd) in _PW_SHELLS:
                runs_shell = True
                break
        for word, strip_tabs in words:
            pending.append([word, strip_tabs, runs_shell, []])
    for _w, _t, sh, buf in pending:  # unterminated at EOF: bash still runs what it read
        if sh:
            bodies.append('\n'.join(buf))
    return bodies


def _pw_set_var(ctx, name, raw):
    """Remember `name=raw` (flow-insensitive, this command only). Only the path-relevant
    reading is kept: the value as the shell would expand it."""
    if len(ctx.vars) >= 256 or len(raw) > PW_MAX_TOKEN:
        return
    text, _dyn = _pw_unquote(raw, ctx.home, variables=ctx.vars)
    ctx.vars[name] = text


def _pw_track_vars(ctx, tokens, assignments, cmd, args, cwd):
    """Learn parameters so a LATER use resolves: bare `NAME=value`, `export|declare|typeset|local|
    readonly NAME=value`, `for NAME in words` (the first word naming / mentioning a protected
    path, else the first word), `read NAME <<< text`, `printf -v NAME ...`, and the positional
    parameters of `set -- words` (`"$@"`, `$1`, `$*`). A tracked value that is later used as a
    command word, an `eval` operand or a `-c` payload is scanned as a script."""
    if cmd is None:
        for a in assignments:
            name, _eq, val = a.partition('=')
            _pw_set_var(ctx, name, val)
        return
    base = basename(cmd)
    if base in ('export', 'declare', 'typeset', 'local', 'readonly'):
        for a in args:
            if ENV_ASSIGN.match(a):
                name, _eq, val = a.partition('=')
                _pw_set_var(ctx, name, val)
    elif base == 'for' and len(args) >= 2 and args[1] == 'in' and ENV_ASSIGN.match(args[0] + '='):
        words = args[2:34]
        chosen = None
        for w in words:
            texts = [t for t, _d in _pw_alts(ctx, w)]
            if not texts:
                continue
            if chosen is None:
                chosen = texts[0]
            if _pw_hit(ctx, w, cwd) or _pw_mention(ctx, texts[0]):
                chosen = texts[0]
                break
        if chosen is not None:
            ctx.vars[args[0]] = chosen
    elif base == 'set':
        if '--' in args:
            vals = args[args.index('--') + 1:]
        elif args and not args[0].startswith(('-', '+')):
            vals = args
        else:
            return
        texts = [_pw_unquote(v, ctx.home, payload=True, variables=ctx.vars)[0] for v in vals[:64]]
        ctx.vars['@'] = ctx.vars['*'] = ' '.join(texts)
        for k, t in enumerate(texts):
            ctx.vars[str(k + 1)] = t
    elif base == 'read':
        word = None
        for k, t in enumerate(tokens):
            if t.startswith('<<<'):
                word = t[3:] or (tokens[k + 1] if k + 1 < len(tokens) else '')
        if word:
            text = _pw_unquote(word, ctx.home, payload=True, variables=ctx.vars)[0]
            prev = ''
            for a in args:
                if re.match(r'^[A-Za-z_][A-Za-z0-9_]*$', a) and prev not in (
                        '-p', '-u', '-n', '-N', '-t', '-d', '-a', '-i'):
                    ctx.vars[a] = text
                prev = a
    elif base == 'printf' and '-v' in args:
        k = args.index('-v')
        if k + 1 < len(args):
            ctx.vars[args[k + 1]] = ' '.join(
                _pw_unquote(v, ctx.home, payload=True, variables=ctx.vars)[0]
                for v in args[k + 2:][:64])


def _pw_producer_text(ctx, body):
    """The text a `<(echo ...)` / `<(printf ...)` process substitution hands to a shell."""
    toks = tokenize_cmd(body)
    _a, cmd, args = command_and_args(toks)
    if cmd is None or basename(cmd) not in ('echo', 'printf'):
        return ''
    words = [a for a in args if len(a) <= PW_MAX_PAYLOAD]
    return ' '.join(_pw_unquote(a, ctx.home, payload=True, variables=ctx.vars)[0] for a in words)


def _pw_scan(command, ctx, cwd, depth, sd=0):
    """-> (blocked, cwd_after). True if any segment of `command` writes a protected path.
    Segment-scoped hatch: a segment LEADING with CAST_PROTECTED_WRITE_OK=1 is exempt (never the
    rest of the line). cwd follows literal `cd` / `pushd` across segments (a subshell's `cd`
    is over-applied: fail-closed). Command-substitution bodies are scanned too, under both
    the starting and the final cwd."""
    shell_docs = _pw_shell_heredoc_bodies(command, ctx)
    command = strip_heredocs(command)
    bodies = []
    if sd < 24:
        command, bodies = _pw_split_subst(command, ctx)
    start_cwd = cwd
    ps_queue = [bd for kd, bd in bodies if kd == 'ps']
    for doc in shell_docs:  # a heredoc FED TO A SHELL is a script, not inert data
        if depth >= PW_MAX_DEPTH or _pw_scan(doc, ctx, cwd, depth + 1)[0]:
            return True, cwd
    for segment in split_segments(command, wr=True):
        tokens = tokenize(segment)
        for k, t in enumerate(tokens):
            if t.startswith('#'):  # unquoted word-boundary comment: the rest is inert
                tokens = tokens[:k]
                break
        tokens = strip_keywords(tokens)  # `do rm x`, `then tee y`, `! cmd`
        # Brace expansion happens BEFORE tilde/parameter expansion and yields several WORDS:
        # `{rm,~/.claude/scripts/x}` runs `rm ~/.claude/scripts/x`. Flatten it as the shell does.
        flat = []
        for t in tokens:
            flat.extend(_pw_brace_expand(t) if len(t) <= PW_MAX_TOKEN and '{' in t else (t,))
        tokens = flat
        for k in range(len(tokens)):  # `X+=v` is an assignment too (leading run only)
            if re.match(r'^[A-Za-z_][A-Za-z0-9_]*\+=', tokens[k]):
                tokens[k] = tokens[k].replace('+=', '=', 1)
            elif not ENV_ASSIGN.match(tokens[k]):
                break
        assignments, cmd, args = command_and_args(tokens)
        if cmd is not None and '$' in cmd and ctx.vars and len(cmd) <= PW_MAX_TOKEN:
            # a tracked variable used as the COMMAND WORD (`$X`, `"$@"` after `set --`)
            ctext = _pw_unquote(cmd, ctx.home, payload=True, variables=ctx.vars)[0]
            if '$' not in ctext:
                cwords = tokenize(ctext)
                if cwords:
                    cmd, args = cwords[0], cwords[1:] + list(args)
        n_ps = sum(t.count('$_PS') for t in tokens)
        seg_ps = ps_queue[:n_ps]
        del ps_queue[:n_ps]
        if any(PW_OK_ASSIGN.match(a) for a in assignments):
            continue
        for tgt in _pw_redirect_targets(tokens):
            if _pw_hit(ctx, tgt, cwd):
                return True, cwd
        _pw_track_vars(ctx, tokens, assignments, cmd, args, cwd)
        wrapped = []
        cmd, args = _pw_unwrap(cmd, args, ctx, wrapped)
        if cmd is None:
            for a in assignments:  # bare `VAR=val`: private to the shell unless exported
                name, _eq, val = a.partition('=')
                if _pw_env_assign(ctx, name, val, cwd, depth, False):
                    return True, cwd
            continue
        base = basename(cmd)
        # Environment handed to the command (`VAR=val cmd`, `env VAR=val cmd`, `sudo VAR=val cmd`):
        # a command-string variable is scanned as a SCRIPT; ANY variable whose value mentions /
        # sits inside / is an ancestor of a protected root blocks unless the command is a pure
        # reader (nowrite entry). GIT_DIR / GIT_WORK_TREE are judged with the git subcommand.
        envsafe = base in _PW_READERS and _PW_READERS[base]['envsafe']
        ctx.git_env_dirs = []
        for a in list(assignments) + wrapped:
            name, _eq, val = a.partition('=')
            if PW_OK_ASSIGN.match(a):
                continue
            if base == 'git' and name in ('GIT_DIR', 'GIT_WORK_TREE'):
                ctx.git_env_dirs.append(val)
                continue
            if _pw_env_script_blocked(ctx, name, val, cwd, depth):
                return True, cwd
            if not envsafe and _pw_env_value_protected(ctx, name, val, cwd):
                return True, cwd
        if base == 'set' and (('-a' in args) or any(
                args[k] == '-o' and k + 1 < len(args) and args[k + 1] == 'allexport'
                for k in range(len(args)))):
            ctx.allexport = True
        if base in ('export', 'declare', 'typeset', 'local', 'readonly'):
            exports = base == 'export' or any(
                a.startswith('-') and not a.startswith('--') and 'x' in a for a in args)
            for a in args:
                if a.startswith('-'):
                    continue
                if ENV_ASSIGN.match(a):
                    name, _eq, val = a.partition('=')
                    if _pw_env_assign(ctx, name, val, cwd, depth, exports):
                        return True, cwd
                    if exports:
                        ctx.exported.add(name)
                elif re.match(r'^[A-Za-z_][A-Za-z0-9_]*$', a):
                    if exports:
                        ctx.exported.add(a)
                        if a in ctx.prot_vars:
                            return True, cwd  # `D=~/.claude/scripts; export D`
        if base == 'printf' and '-v' in args:  # printf -v NAME FORMAT ARGS: NAME gets the text
            k = args.index('-v')
            if k + 1 < len(args):
                pname = args[k + 1]
                for v in args[k + 2:]:
                    if _pw_env_assign(ctx, pname, v, cwd, depth, False):
                        return True, cwd
        if base == 'rm' and any(RM_OK_ASSIGN.match(a) for a in assignments):
            # RULE 3's hatch already authorises a RECURSIVE rm of the .claude subtree; do not
            # demand a second hatch for the same act. A non-recursive rm still needs ours.
            _pos, _opts = _pw_parse_args(args)
            if set(f for f, _v in _opts) & set(('R', 'r', '--recursive')):
                continue
        if base in ('cd', 'pushd'):
            cwd = _pw_cd(ctx, args, cwd)
            continue
        if base in _PW_SHELL_EXEC or base in ('source', '.'):
            # a script handed to a shell through a here-string `<<<` or a `<(echo ...)`
            fed = []
            for k, t in enumerate(tokens):
                if t.startswith('<<<'):
                    word = t[3:] or (tokens[k + 1] if k + 1 < len(tokens) else '')
                    if word and len(word) <= PW_MAX_PAYLOAD:
                        fed.append(_pw_unquote(word, ctx.home, payload=True, variables=ctx.vars)[0])
            for body in seg_ps:
                fed.append(_pw_producer_text(ctx, body))
            for text in fed:
                if text and (depth >= PW_MAX_DEPTH or _pw_scan(text, ctx, cwd, depth + 1)[0]):
                    return True, cwd
        if _pw_command_writes(ctx, base, args, cwd, depth):
            return True, cwd
    for _kind, body in bodies:
        for c in ((start_cwd,) if cwd == start_cwd else (start_cwd, cwd)):
            if _pw_scan(body, ctx, c, depth, sd + 1)[0]:
                return True, cwd
    return False, cwd


_PW_ARRAY_RE = re.compile(r'(?<![\w.-])[A-Za-z_][A-Za-z0-9_]*\+?=\(')
_PW_SUBSCRIPT_ASSIGN = re.compile(r'^[A-Za-z_][A-Za-z0-9_]*\[[^\]]*\]\+?=')
# builtins whose operands become variables / aliases / loop words / positional parameters
_PW_MENTION_BUILTINS = frozenset(('declare', 'typeset', 'local', 'readonly', 'export', 'read',
                                  'printf', 'set', 'for', 'select', 'alias'))


def _pw_dynamic_word(w):
    """A command word that is not a literal name: `$X`, `${X:-}`, `"$@"`, backtick, `$(..)` (lifted
    to `$_S`). `$HOME/...` is a PATH, not text to run."""
    t = w.lstrip('"\'')
    if not (t.startswith('$') or t.startswith('`')):
        return False
    return not re.match(r'^\$(?:HOME|\{HOME\})(?:/|$)', t)


def _pw_tr_analyze(command, ctx, depth):
    """-> (runner, mention) for the TEXT-RUNNER rule. runner: some segment executes TEXT -- its
    command word (after unwrapping `command`/`env`/`nohup`/`timeout`/`exec`/`time`/`nice`/`sudo`)
    is dynamic (`$X`, `${X:-}`, `"$@"`, `$*`, `$(..)`, backtick), or it is `eval` / `source` / `.` /
    a shell with `-c`. mention: a protected root appears in an assignment value (`X=`, `X+=`,
    `m[k]=`, `arr=(..)`, `declare|typeset|local|readonly|export|read|set|for|alias` operands,
    `printf -v`) -- i.e. in TEXT that was stored for later. Both anywhere in the command => the
    stored text may be what runs, however it is spelled (IFS tricks, ${X:-}, arrays, +=)."""
    if depth > 5:
        return True, True  # nobody legitimately nests this deep: fail closed
    runner = mention = False
    command = strip_heredocs(command)
    outer, bodies = _pw_split_subst(command, ctx)
    for m in _PW_ARRAY_RE.finditer(outer):
        j = _pw_match_paren(outer, m.end() - 1)
        if _pw_mention(ctx, outer[m.end():j]):
            mention = True
    for seg in split_segments(outer, wr=True):
        tokens = tokenize(seg)
        for k, t in enumerate(tokens):
            if t.startswith('#'):
                tokens = tokens[:k]
                break
        tokens = strip_keywords(tokens)
        for k in range(len(tokens)):
            if re.match(r'^[A-Za-z_][A-Za-z0-9_]*\+=', tokens[k]):
                tokens[k] = tokens[k].replace('+=', '=', 1)
            elif not ENV_ASSIGN.match(tokens[k]):
                break
        assignments, cmd, args = command_and_args(tokens)
        if any(PW_OK_ASSIGN.match(a) for a in assignments):
            continue  # a hatched segment is the operator's decision
        wrapped = []
        for a in assignments:
            if '$_SM' in a or _pw_mention(ctx, a):
                mention = True
        for t in tokens:
            if _PW_SUBSCRIPT_ASSIGN.match(t) and ('$_SM' in t or _pw_mention(ctx, t)):
                mention = True
        raw_cmd = []
        cmd, args = _pw_unwrap(cmd, args, ctx, wrapped, raw_cmd)
        for a in wrapped:
            if '$_SM' in a or _pw_mention(ctx, a):
                mention = True
        if cmd is None:
            continue
        dyn_word = bool(raw_cmd) and _pw_dynamic_word(raw_cmd[0])  # judged on the WRITTEN word
        cmd = _pw_cmdword(ctx, cmd)
        base = basename(cmd)
        payload = None
        if base in ('eval', 'source', '.'):
            runner = True
            if base == 'eval':
                payload = ' '.join(_pw_unquote(a, ctx.home, payload=True, variables=ctx.vars)[0]
                                   for a in args if len(a) <= PW_MAX_PAYLOAD)
        elif base in _PW_SHELL_EXEC:
            pl, _rest, _ne = _pw_shell_parse(ctx, base, args)
            if pl is not None:
                runner = True
                payload = pl
        elif dyn_word:
            runner = True
        if payload:
            r2, m2 = _pw_tr_analyze(payload, ctx, depth + 1)
            runner = runner or r2
            mention = mention or m2
        if base in _PW_MENTION_BUILTINS and not (base == 'printf' and '-v' not in args):
            for t in args:
                if '$_SM' in t or _pw_mention(ctx, t):
                    mention = True
    for _kind, body in bodies:
        r2, m2 = _pw_tr_analyze(body, ctx, depth + 1)
        runner = runner or r2
        mention = mention or m2
    return runner, mention


def protected_write_via_bash(command):
    """RULE 5: True if the command WRITES / MOVES / LINKS / CHMODs / DELETES a path under the
    installed CAST exec surface (see the module docstring)."""
    ctx = _pw_context()
    ctx.sink = bool(_PW_SINK_RE.search(command))
    try:
        cwd = _pw_canon(os.getcwd())
    except Exception:
        cwd = None
    if _pw_scan(command, ctx, cwd, 0)[0]:
        return True
    # TEXT-RUNNER rule: stored text that mentions a root + something that executes text
    if len(command) <= PW_MAX_PAYLOAD and _pw_mention(ctx, command):
        runner, mention = _pw_tr_analyze(command, ctx, 0)
        if runner and mention:
            return True
    return False


# --- top-level detection ----------------------------------------------------

def is_blocked(command):
    """Return (blocked, message) for a raw Bash command string."""
    # RULE 4 — workflow-write via Bash redirection (scans the raw command; it does
    # its own heredoc-strip + segment split). Checked first: a workflow write is a
    # policy-evasion class independent of the kill/rm rules.
    if workflow_write_via_bash(command):
        return True, WORKFLOW_MSG

    raw_command = command  # RULE 5 does its own heredoc handling (a heredoc fed to a shell)
    command = strip_heredocs(command)

    for segment in split_segments(command):
        tokens = tokenize_cmd(segment)
        assignments, cmd, args = command_and_args(tokens)

        # PER-SEGMENT escape hatch: only this segment's own leading VAR= exempts it.
        seg_kill_exempt = any(KILL_OK_ASSIGN.match(a) for a in assignments)
        seg_rm_exempt = any(RM_OK_ASSIGN.match(a) for a in assignments)

        # Unwrap simple no-option command wrappers (command/exec/nohup/time).
        while cmd is not None and basename(cmd) in WRAPPERS and args:
            cmd = args[0]
            args = args[1:]
        if not cmd:
            continue
        base = basename(cmd)

        # RULE 1 — process-kill
        if base in ('pkill', 'killall'):
            if not seg_kill_exempt:
                return True, KILL_MSG
            continue

        # RULE 2 — mass kill
        if base == 'kill':
            if not seg_kill_exempt and kill_has_dangerous_target(args):
                return True, KILL_MSG
            continue

        # RULE 3 — catastrophic rm
        if base == 'rm':
            if not seg_rm_exempt and rm_is_catastrophic(args):
                return True, RM_MSG
            continue

    # RULE 5 — write / move / link / chmod / delete of the installed exec surface. Runs after
    # the kill / rm rules so their (more specific) messages and hatches win.
    if protected_write_via_bash(raw_command):
        return True, PW_MSG

    return False, ""


def safe_is_blocked(command):
    """is_blocked with a fail-open guard — any internal error allows the command."""
    try:
        return is_blocked(command)
    except Exception:
        return False, ""


def main():
    try:
        data = load_input()
        tool = data.get('tool_name', '')
        ti = data.get('tool_input', {})
        if not isinstance(ti, dict):
            ti = {}
        command = ti.get('command', '') or ''
        if tool != 'Bash' or not command:
            sys.exit(0)

        blocked, message = safe_is_blocked(command)
        if blocked:
            # Block reason goes to STDERR: Claude Code feeds a PreToolUse hook's stderr
            # back to the model as the block reason on exit 2 (verified via live bite-test
            # — a stdout-only message surfaced only as "hook error: No stderr output").
            print(message, file=sys.stderr)
            log_path = os.path.join(os.path.expanduser('~'), '.claude', 'logs', 'command-guard.log')
            write_log(log_path, f"BLOCK: {command}")
            sys.exit(2)
        sys.exit(0)
    except SystemExit:
        raise
    except Exception:
        sys.exit(0)


if __name__ == '__main__':
    main()
