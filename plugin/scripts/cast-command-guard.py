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
import json
import os
import re
import sys
from datetime import datetime, timezone

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


def split_segments(command):
    """Split a command line into segments at UNQUOTED shell separators.

    Separators: newline ; & | ( ) { ` (which also covers && and ||, $(...) command
    substitution via `(`, and backtick `` `...` `` command substitution). Characters
    inside single/double quotes are never treated as separators, so a mention like
    echo "use pkill; rm -rf /" stays a single segment whose command is echo.
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


# --- top-level detection ----------------------------------------------------

def is_blocked(command):
    """Return (blocked, message) for a raw Bash command string."""
    command = strip_heredocs(command)

    for segment in split_segments(command):
        tokens = tokenize(segment)
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
