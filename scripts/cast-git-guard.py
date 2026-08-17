#!/usr/bin/env python3
r"""cast-git-guard.py — CAST PreToolUse git + policy guard (logic module).

CAST v9 P0 hot-path consolidation: the git commit/push/stash blocks and the
Write/Edit policy engine — formerly inline bash + python in pre-tool-guard.sh —
now live here as ONE importable module. `pre-tool-guard.sh` is a thin wrapper
that execs this file (so tests/pre-tool-guard.bats + tests/test_push_agent_stash_guard.bats
continue to prove this logic), and cast-pretool-dispatch.py imports `evaluate()`
to run the same checks in-process — single source of truth, no duplication.

GUARANTEES PRESERVED (Subtraction Safety Gate, master_v9.md §0.2):
  - Raw `git commit` blocked → use the commit agent (escape: CAST_COMMIT_AGENT=1).
  - Raw `git push` blocked → code-reviewer first (escape: CAST_PUSH_OK=1).
  - Raw `git stash` blocked (2026-05-19 push-agent stash-resurrection incident;
    escape: CAST_STASH_OK=1).
  - `git reset --hard`/`--merge`/`--keep` blocked (2026-08-17 dispatched-commit-agent
    incident: a raw `git reset --hard` + `git clean` destroyed a fully reviewed, gated
    working-tree diff, recovered only via a dangling-blob hunt; escape: CAST_RESET_OK=1).
    Bare `git reset` / `--soft` / `--mixed` are index-only and stay UNBLOCKED (routine).
  - `git clean` blocked unless a dry run (`-n`/`--dry-run`); same 2026-08-17 incident
    (escape: CAST_CLEAN_OK=1).
  - `git checkout -- <pathspec>` / `git checkout .` / bare `git checkout
    <existing-path>` (no `--` at all, e.g. `git checkout completions/cast.bash`
    — the EXACT 2026-08-15 incident command) / `git checkout -f`/`--force`
    blocked (discards worktree changes); plain branch ops (`checkout <branch>`,
    `-b`, `-`, `--track`, `--detach`, `-B <b> <start>`, refs like
    `HEAD~1`/`@{-1}`) stay UNBLOCKED. `git restore` blocked unless `--staged`
    without `--worktree` (index-only). `git switch -f`/`--force`/
    `--discard-changes` blocked the same way; plain `git switch <branch>`
    stays UNBLOCKED (git itself refuses it on conflicting local changes, so
    it isn't destructive by default the way checkout is). Closes the exact
    gap a READ-ONLY code-reviewer used to silently revert the file it was
    reviewing (see CLAUDE.md incident note); escapes: CAST_CHECKOUT_OK=1,
    CAST_RESTORE_OK=1, CAST_SWITCH_OK=1.
  - Write/Edit path policy engine (config/policies.json → requires_agent gate,
    CAST_POLICY_OVERRIDE=1 escape with audit-log).
  - agent-status TTL sweep (files older than 120 min) on Write/Edit.

SECURITY (unchanged from the bash original):
  - The escape hatch MUST appear as a leading env-var assignment BEFORE the git
    command (tolerating leading `cd &&` chains and git global options). It can
    NEVER take effect from inside a commit message / comment / echo — only the
    command's FIRST LINE is scanned, so a multiline escape-hatch on line 2 can't
    bypass the first-line git command.
  - `_git_evaluate` splits the first line into SHELL SEGMENTS on `;`, `&&`,
    `||`, and `|`, and evaluates each segment on its own (2026-08-17 fix —
    a security review found that per-LINE evaluation let a hatch attached to
    a HARMLESS invocation of an op unlock a DESTRUCTIVE invocation of the
    *same* op later on the line, e.g. `CAST_RESET_OK=1 git reset --soft &&
    git reset --hard` was allowed; this was pre-existing and reproducible
    even for commit at HEAD, e.g. `CAST_COMMIT_AGENT=1 git commit --dry-run
    && git commit -m x`). Per-segment matching mirrors real shell semantics:
    `VAR=1 cmd` scopes VAR to that one command, not to everything chained
    after it. Within each segment, every op is ALSO checked INDEPENDENTLY: a
    matched *_ALLOW suppresses only its own op's block and does NOT
    short-circuit the other ops' BLOCK checks in that segment (closes the
    cross-op sibling of this same defect class, e.g.
    `CAST_STASH_OK=1 git stash pop; git reset --hard`).
    Consequence: a combined-prefix hatch (`CAST_RESET_OK=1 CAST_CLEAN_OK=1
    git reset --hard && git clean -fdx`) BLOCKS — segment 2 carries no hatch
    of its own — so each destructive git command on a chained line needs its
    OWN hatch immediately before it, for both same-op and cross-op chains
    (`CAST_RESET_OK=1 git reset --hard && CAST_CLEAN_OK=1 git clean -fdx`
    is allowed). This is intentional strictness, not a bug.

KNOWN LIMITATIONS (advisory-grade guard — threat model is a careless agent,
not an adversary; the OS/tool sandbox is the real security boundary, not this
regex layer):
  - Multiline: anything past line 1 evades the scan (`echo hi\ngit reset
    --hard`). This is the SAME mechanism that stops a hatch on line 2 from
    unblocking a destructive op on line 1 — the tradeoff is deliberate and is
    NOT going to be widened to a multi-line scan in this module.
  - Subshell / command-substitution indirection evades every BLOCK regex,
    which all anchor on `(^|\s)git`: `(git reset --hard)`, `$(git reset
    --hard)`, backticks, `{ git reset --hard; }`, `bash -c 'git reset
    --hard'`. Chasing these would require a real shell parser, not regex —
    out of scope for this module.
    NOTE (2026-08-17 follow-up): this is distinct from — and NOT fixed by —
    the token-boundary fix below. Boundary anchoring (`\b`) closes ADJACENT
    empty-output command substitution appended to a flag/token
    (`--hard$(true)`, `` stash`true` ``, `.$(true)`), where the destructive
    git invocation itself is still plainly on the line. It does nothing for
    the case above, where the ENTIRE git invocation is wrapped inside the
    subshell/substitution and never appears as a bare `git ...` token.
  - Quoted-token evasion (2026-08-17 recovery-path pass, measured — SAME
    family as the subshell/`$( )` limitation above, and for the same reason:
    fixing it properly needs real shell tokenization (`shlex`), not more
    regex, so it is surfaced here rather than papered over). Every BLOCK
    regex in this module matches a BARE shell token — `--hard`, `expire`,
    `commit`, etc. — literally, so wrapping the subcommand name OR a
    destructive flag in quotes evades the match, since the shell strips the
    quotes but the regex never sees past them: `git reset "--hard"`, `git
    "reset" --hard`, `git "commit" -m x`, `git "push"`, `git checkout "--" .`,
    `git switch "--discard-changes" main`, `git gc "--prune=now"`, `git
    reflog "expire" --all` are all measured ALLOWED. This is PRE-EXISTING —
    reproducible against `commit`/`push`/`reset`/`checkout`/`switch` at HEAD
    — and NOT introduced by the reflog/gc/prune additions in this pass;
    those three ops inherit the same gap by using the same pattern idiom.
    Quoting only the flag's VALUE, as opposed to the flag/token itself, does
    NOT evade it: `git gc --prune="now"` still blocks, because the literal
    `--prune=` text the regex keys on is unquoted. The failure direction is
    NOT uniform across ops: for most ops (reset/checkout/switch/commit/push/
    reflog/gc/prune) quoting fails OPEN as shown above, but for `clean` and
    `restore` the *safe-form* detection (the dry-run/`--staged` lookahead,
    not the block itself) is what gets quoted-token-evaded, which flips the
    outcome to fail CLOSED instead: `git clean "-fd"` and `git restore
    "--worktree" f.txt` still BLOCK, because the quoted safety flag is what
    the regex fails to recognize, not the destructive command. Advisory-grade
    like every other gap in this module — surfaced, not fixed, this pass.
  - The stash/reset/checkout BLOCK regexes anchor destructive-flag detection
    on a token boundary (`\b`, or an equivalent negative lookahead for `.`,
    which is itself a non-word character) rather than requiring literal
    trailing whitespace. This closes the adjacent-command-substitution
    evasion above while still rejecting look-alike tokens (`--hardcore`,
    `stashsomething`, `.github`, `./foo`) that merely start with or extend
    past the blocked token.
  - `git checkout <bare-token>` with NO `--` and no literal `.` (e.g. `git
    checkout completions/cast.bash`) is caught by `_checkout_bare_path_blocks()`,
    a filesystem-existence heuristic, NOT a regex: the first non-flag token is
    treated as a pathspec (and blocked) only if `os.path.exists()` finds it —
    mirroring git's own path-vs-branch disambiguation, since shape alone
    can't tell `release/1.0.0` (a branch) from `src/app.py` (a path). This is
    CWD-DEPENDENT: it resolves relative to this guard process's own cwd (or
    the `-C <dir>` argument in the same segment, if present), so it has no
    visibility into a `cd` earlier in a shell chain this guard doesn't
    execute, or a cwd that differs from git's actual working tree. A branch
    name that happens to match a real path elsewhere on disk, but not
    relative to this cwd, is MISSED (allowed), not blocked — advisory-grade,
    same as the rest of this module, not a guarantee. Also worth naming
    plainly: `_checkout_bare_path_blocks()` swallows exceptions and returns
    False on any internal error, i.e. it FAILS OPEN — a bug in the heuristic
    silently disables the check rather than blocking. Defensible under the
    "never crash the hook pipeline" contract (a guard crash must never block
    all work), but it is a fail-open path, not a fail-closed one.
  - `git checkout -f`/`--force` and `git switch -f`/`--force`/
    `--discard-changes` (2026-08-17 third follow-up) both force past
    conflicting local changes, discarding them; both block, each with its
    own hatch (CAST_CHECKOUT_OK=1 / CAST_SWITCH_OK=1 respectively). `switch`
    does not take a pathspec, so it gets no filesystem heuristic — only the
    force/discard flags are checked. Plain `git switch <branch>` stays
    UNBLOCKED because git itself refuses it on conflicting local changes
    (unlike `checkout`, which silently discards them for a bare pathspec).
    `_FORCE_FLAG_LOOKAHEAD` (shared by both the checkout and switch force
    checks) matches `-f`/`--force` in CLUSTERED short-flag form too, not
    just standalone (2026-08-17 fourth follow-up, completing the same-day
    third follow-up above): `git checkout -fb newbranch` is valid git,
    parsed as `-f -b newbranch` (force + branch-create — confirmed via
    `git checkout -fb` alone erroring with "switch `b' requires a value",
    proving git reads it flag-by-flag), and was still ALLOWED by the
    initial standalone-only regex. Same defect class already fixed once in
    this file for `_CLEAN_DRY_RUN` clustering (`-nd`/`-fn`); same fix shape
    (`-[a-zA-Z]*f[a-zA-Z]*`, single-dash-anchored so `--force`/`--detach`/
    `--track` are unaffected). Non-`f` clusters (`-b`, `-B`, `-q`, `-t`,
    `-p`, `-m`, `-d`, `-c`, `-C`, and combinations without an `f`) correctly
    stay unmatched.
  - `git reflog expire`/`git reflog delete` blocked (2026-08-17 recovery-path
    pass: these destroy reflog entries — the SAME recovery mechanism that
    recovered a fully reviewed diff via a dangling-blob hunt earlier that
    day; escape: CAST_REFLOG_OK=1). Read-only `git reflog`/`git reflog show`/
    `git reflog exists` stay UNBLOCKED.
  - `git gc --prune=<value>` (any explicit value, including `now`/`all`/an
    age) blocked — same recovery-path rationale (escape: CAST_GC_OK=1). Bare
    `git gc`, `--aggressive`, `--prune` with no value, `--no-prune`, and
    `--auto` stay UNBLOCKED.
  - `git prune` blocked in every non-dry-run form — measured MORE
    destructive than `git gc --prune=now` (no grace period at all; escape:
    CAST_PRUNE_OK=1). Dry runs (`-n`/`--dry-run`) stay UNBLOCKED, as do the
    unrelated `git prune-packed`, `git remote prune`, and `git worktree
    prune`.
  - `git -c gc.pruneExpire=<value>` / `-c gc.reflogExpire=<value>` / `-c
    gc.reflogExpireUnreachable=<value>` blocked on ANY git invocation
    regardless of subcommand — measured as a complete config-layer bypass of
    all three blocks above (2026-08-17 recovery-path pass, same-day
    follow-up): `git -c gc.reflogExpire=now -c gc.pruneExpire=now gc`
    reproduces the FULL `reflog expire --all && gc --prune=now` destruction
    chain in ONE command with no `--prune=`/`expire`/`prune` token for those
    checks to key on (escape: CAST_GC_OK=1, no new hatch). Key match is
    case-insensitive (git config keys are); value match is not — ANY value
    blocks, including a protective `=never`, same precedent as `--prune=
    <value>` above. NOT narrowed to the `gc` subcommand — see the `--auto`
    note below for why.
  - `git config` WRITES (bare, `--local`, `--global`, `--replace-all`, ...)
    of `gc.pruneExpire`/`gc.reflogExpire`/`gc.reflogExpireUnreachable` are
    blocked under the same hatch (CAST_GC_OK=1) — closes `git config
    gc.pruneExpire now && git gc`, where the destructive act is the config
    WRITE in segment 1, leaving a bare, innocent-looking `git gc` in segment
    2. READS (`git config --get gc.pruneExpire`, or a bare `git config
    gc.pruneExpire` with no value — git itself treats that as a
    print-current-value read) stay UNBLOCKED.
  - Entirely unguarded ops, deliberately out of scope, measured and
    confirmed still open as of this pass (a separate enumerated unit, not
    this one): `git rm -f`, `git rm -r --cached`, `git branch -D`, `git
    worktree remove -f`, `git update-ref -d`, `git filter-branch`, `git
    sparse-checkout set`. Do not assume this list is exhaustive — it is the
    set explicitly measured and deferred, not a claim that everything else
    is covered. (`git reflog expire`/`git gc --prune=<value>`/`git prune`
    were on this list through the prior pass; they are now covered by the
    reflog/gc/prune blocks above — see the 2026-08-17 recovery-path pass
    note in each block's comment.)
  - The `git gc`/`git prune` coverage above is deliberately narrow, keyed
    only on the explicit `--prune=<value>` flag or the bare `git prune`
    invocation. It does NOT cover bare `git gc` or `git gc --prune` (no
    value) — both stay allowed and CAN still delete objects older than
    `gc.pruneExpire` (default 2 weeks). The `-c`/`git config` blocks added in
    the same-day follow-up (above) close the two routes that SET that config
    via a `git` command in the scanned line; they do NOT close a bare `git
    gc` run against a `gc.pruneExpire=now` that got into `.git/config` some
    OTHER way — e.g. a direct file edit (`Write`/`Edit` tool, a text editor,
    a prior session, a repo committed with that setting) — since that write
    never appears as a `git ...` token on any line this module scans. That
    remains a real, named hole: bare `git gc` is not, and cannot be made,
    unconditionally safe by a command-line regex layer.
  - Config-injection indirection (2026-08-17 recovery-path pass, follow-up,
    measured — deliberately NOT chased, same family as the subshell/`$( )`
    and quoted-token limitations: regex cannot win this arms race, and the
    threat model here is a careless agent, not an adversary evading a
    security boundary; the OS/tool sandbox is the real boundary):
    `PRX=now git --config-env=gc.pruneExpire=PRX gc` and `GIT_CONFIG_COUNT=1
    GIT_CONFIG_KEY_0=gc.pruneExpire GIT_CONFIG_VALUE_0=now git gc` both
    measured GONE (dangling blob deleted) and both ALLOWED by every check in
    this module — `--config-env=` names the ENV VAR holding the value, not
    the value itself, so the literal `gc.pruneExpire=now` text the `-c`
    block keys on never appears on the line; the `GIT_CONFIG_KEY_0`/
    `GIT_CONFIG_VALUE_0` form sets config purely via env-var assignments
    git reads internally, with no `-c` or `config` token at all.
  - Honest unresolved question, NOT smoothed over (2026-08-17 recovery-path
    pass, follow-up): whether inline expiry config plus git's own
    auto-gc (`git -c gc.auto=1 -c gc.pruneExpire=now commit`, or any
    subcommand that can trigger auto-gc) is ITSELF destructive at scale
    could NOT be determined this pass. A first probe checking only whether
    the blob survived showed "harmless," but `gc.autoDetach` defaults to
    TRUE, so that probe may simply have raced a backgrounded gc process
    rather than proving auto-gc never ran. Re-probing with
    `-c gc.autoDetach=false` and counting loose objects directly (not just
    checking blob survival) showed the object count UNCHANGED — i.e. gc
    genuinely never fired, because a repo this small (7 loose objects) never
    trips `gc.auto`'s default threshold. The correct, narrow statement is:
    **auto-gc could not be MADE to fire in a repo small enough to probe
    cheaply, so whether inline expiry config plus auto-gc is destructive at
    scale is UNRESOLVED, not "verified harmless."** This is also why block
    (A) above (the `-c` config-injection block) is NOT narrowed to the `gc`
    subcommand: doing so would require answering this exact open question
    first, and this pass could not.

CONTRACT: exit 2 + stderr message = block; exit 0 = allow. FAIL-OPEN — any
internal error allows the tool (a guard crash must never block all work).
CLAUDE_SUBPROCESS=1 (managed/headless sub-claude) skips ONLY the Write/Edit policy engine + TTL sweep; the git commit/push/stash guards run in EVERY context (a subagent must not bypass the irreversibility guards).
"""
import datetime
import json
import os
import re
import shlex
import subprocess
import sys

# --- git global-option tolerance (shared by every git pattern) --------------
# Matches: -C <path>, --no-pager, -c <cfg>, --git-dir=<d>, --work-tree=<w>
_GIT_OPTS = r'(\s+(-C\s+\S+|--no-pager|-c\s+\S+|--git-dir=\S+|--work-tree=\S+))*'

# --- git commit block -------------------------------------------------------
# Tolerates extra VAR=value assignments between CAST_COMMIT_AGENT=1 and git
# (e.g. CAST_COMMIT_AGENT=1 CAST_SKIP_PLUGIN_DRIFT=1 git commit ...).
_COMMIT_ALLOW = re.compile(
    r'(^|&&\s*)CAST_COMMIT_AGENT=1\s+([A-Za-z_][A-Za-z0-9_]*=\S+\s+)*git' + _GIT_OPTS + r'\s+commit'
)
_COMMIT_BLOCK = re.compile(r'(^|\s)git' + _GIT_OPTS + r'\s+commit')

# --- git push block ---------------------------------------------------------
# Tolerates extra VAR=value assignments between CAST_PUSH_OK=1 and git
# (e.g. CAST_PUSH_OK=1 CAST_SKIP_BATS_PUSH=1 git push ...).
_PUSH_ALLOW = re.compile(
    r'(^|&&\s*)CAST_PUSH_OK=1\s+([A-Za-z_][A-Za-z0-9_]*=\S+\s+)*git' + _GIT_OPTS + r'\s+push'
)
_PUSH_BLOCK = re.compile(r'(^|\s)git' + _GIT_OPTS + r'\s+push')

# --- git stash block --------------------------------------------------------
# Tolerates extra VAR=value assignments between CAST_STASH_OK=1 and git
# (e.g. CAST_STASH_OK=1 CAST_SKIP_PLUGIN_DRIFT=1 git stash ...).
_STASH_ALLOW = re.compile(
    r'(^|&&\s*)CAST_STASH_OK=1\s+([A-Za-z_][A-Za-z0-9_]*=\S+\s+)*git' + _GIT_OPTS + r'\s+stash'
)
# 2026-08-17 follow-up: trailing `(\s|$)` required LITERAL whitespace/end
# after the token, which adjacent empty-output command substitution defeats
# (`git stash`true`` -> shell runs `git stash` but the regex never saw a
# trailing space). `\b` anchors on the token boundary itself instead: it
# matches before a non-word char (backtick, `$`, `;`, etc.) or end-of-string,
# but NOT between two word chars, so `stashsomething` still does not match.
_STASH_BLOCK = re.compile(r'(^|\s)git' + _GIT_OPTS + r'\s+stash\b')

# --- git reset --hard/--merge/--keep block ----------------------------------
# 2026-08-17: a raw `git reset --hard` destroyed a fully reviewed working-tree
# diff. Only the worktree-destructive forms are blocked — bare `git reset`,
# `--soft`, and `--mixed` touch only the index (routine unstaging) and must
# stay allowed. The destructive flag can appear before OR after the ref
# (`git reset --hard HEAD` or `git reset HEAD --hard`), so BLOCK uses a
# lookahead over the rest of the line rather than anchoring flag position.
# Tolerates extra VAR=value assignments between CAST_RESET_OK=1 and git.
_RESET_ALLOW = re.compile(
    r'(^|&&\s*)CAST_RESET_OK=1\s+([A-Za-z_][A-Za-z0-9_]*=\S+\s+)*git' + _GIT_OPTS + r'\s+reset\b'
)
# 2026-08-17 follow-up: the flag's trailing `(\s|$)` had the same
# literal-whitespace gap as the stash block above (`git reset
# --hard$(true)` evaded it). Swapped for `\b`, which anchors on the token
# boundary — matches `--hard$(true)`/`--hard` (end-of-string) but not
# `--hardcore`, since 'd'->'c' is word-to-word with no boundary between them.
_RESET_BLOCK = re.compile(
    r'(^|\s)git' + _GIT_OPTS + r'\s+reset\b(?=.*\s--(hard|merge|keep)\b)'
)

# --- git clean block ---------------------------------------------------------
# 2026-08-17: paired with the `git reset --hard` incident above. Dry runs
# (-n/--dry-run, INCLUDING short-flag clusters like -nd/-dn/-fn) are the only
# safe form and stay allowed; everything else (including bare `git clean`,
# which is only harmless while clean.requireForce defaults true — a config
# change can flip that) blocks. `-nd`/`git clean -nd` is the standard "preview
# what would be deleted" idiom (security review, 2026-08-17 follow-up) — the
# original -n/--dry-run-only regex missed clustered short flags and would have
# blocked it, training people to reach for the hatch reflexively. The dry-run
# lookahead below matches ANY short-flag cluster containing `n` (bounded by
# whitespace, single-dash-anchored so it can't misfire on long flags like
# `--interactive`), plus the literal `--dry-run` long flag.
# Tolerates extra VAR=value assignments between CAST_CLEAN_OK=1 and git.
_CLEAN_ALLOW = re.compile(
    r'(^|&&\s*)CAST_CLEAN_OK=1\s+([A-Za-z_][A-Za-z0-9_]*=\S+\s+)*git' + _GIT_OPTS + r'\s+clean\b'
)
_CLEAN_DRY_RUN = r'(\s|^)(--dry-run|-[a-zA-Z]*n[a-zA-Z]*)(\s|$)'
_CLEAN_BLOCK = re.compile(
    r'(^|\s)git' + _GIT_OPTS + r'\s+clean\b(?!.*' + _CLEAN_DRY_RUN + r')'
)

# --- git checkout (pathspec) block -------------------------------------------
# 2026-08-17: same defect class as reset/clean — a READ-ONLY code-reviewer
# used `git checkout` to silently revert the file it was reviewing. Distinguishing
# an arbitrary pathspec argument from a branch name is NOT generally decidable
# (both are bare strings) — this deliberately does NOT try. It keys ONLY on the
# `--` pathspec separator (the definitive "this is a path, not a branch" signal
# in git's own syntax) and a literal `.` argument (whole-worktree discard).
# Plain branch ops (`checkout <branch>`, `-b new`, `-`, `--track ...`) are NOT
# pathspec forms and stay allowed — `--track` starts with `--` but is never
# followed by bare whitespace/end-of-line the way a `--` separator is, so it
# does not match the lookahead below.
# Tolerates extra VAR=value assignments between CAST_CHECKOUT_OK=1 and git.
_CHECKOUT_ALLOW = re.compile(
    r'(^|&&\s*)CAST_CHECKOUT_OK=1\s+([A-Za-z_][A-Za-z0-9_]*=\S+\s+)*git' + _GIT_OPTS + r'\s+checkout\b'
)
# 2026-08-17 follow-up: the bare-`.` alternative's trailing `(\s|$)` had the
# same literal-whitespace gap (`git checkout .$(true)` evaded it). `\b`
# CANNOT fix this branch the way it fixed stash/reset above: `.` is itself a
# NON-word character, and `\b` only fires at a word/non-word transition — `.`
# followed by `$`, a backtick, or another non-word char is a non-word/non-word
# pair, i.e. NOT a boundary, so `\.\b` would silently fail to match
# `.$(true)` too. Instead we assert directly on what a real pathspec/filename
# continuation looks like: a negative lookahead that rejects `.` only when
# immediately followed by a word char, `.`, `/`, or `-` (so `.github`,
# `./foo`, `.env`, `.-x` stay UNMATCHED — they're not the bare-dot
# whole-worktree form) and accepts everything else, including whitespace,
# end-of-string, and shell metacharacters (`$`, backtick, `;`, `&`, `|`, `)`).
# The `--` pathspec alternative below is untouched — it already anchors on
# the `--` separator token, not a trailing-whitespace requirement, so it was
# never vulnerable to this evasion.
_CHECKOUT_BLOCK = re.compile(
    r'(^|\s)git' + _GIT_OPTS + r'\s+checkout\b'
    r'(?:(?=.*\s--(\s|$))|\s+\.(?![\w./-]))'
)

# 2026-08-17 second follow-up (security review): `_CHECKOUT_BLOCK` above only
# catches the `--`-separator and bare-`.` forms. `git checkout <bare-token>`
# with NO `--` (e.g. `git checkout completions/cast.bash`, `git checkout
# f.txt`) was still ALLOWED — and that bare form, not the `--`/`.` forms, is
# the EXACT command the 2026-08-15 incident used (a read-only code-reviewer
# silently reverted `completions/cast.bash` this way). Path vs. branch is not
# decidable by regex/shape alone (`release/1.0.0` is a valid branch name that
# looks just like a path). `_checkout_bare_path_blocks()` mirrors git's own
# disambiguation instead: a bare, non-flag first token is treated as a
# pathspec only if it resolves to an EXISTING file/dir (branch names
# typically don't collide with a real path in the worktree). See its
# docstring for the cwd-dependent limitation this implies.
_CHECKOUT_CMD = re.compile(r'(^|\s)git' + _GIT_OPTS + r'\s+checkout\b(?P<rest>.*)$')
_CHECKOUT_CDIR = re.compile(r'-C\s+(\S+)')


def _checkout_bare_path_blocks(seg: str) -> bool:
    """True if `seg` is a `git checkout <token> ...` with no `--` separator
    (already handled by `_CHECKOUT_BLOCK`) whose first non-flag argument
    resolves to an existing file or directory — i.e. git would silently
    treat it as a pathspec and discard uncommitted changes to it, rather
    than as a branch/ref name.

    Deliberately conservative to avoid blocking real branch ops: any token
    starting with `-` (`-b`, `-B`, `-`, `--track`, `--detach`, ...) bails out
    immediately without inspecting further tokens — multi-token forms like
    `-B <branch> <start-point>` are left entirely to git's normal handling.
    A bare `.` is skipped here too (already caught by `_CHECKOUT_BLOCK`,
    kept out of this path to avoid a duplicate block reason).

    KNOWN LIMITATION (advisory-grade, not a proof): `os.path.exists()` is
    resolved relative to THIS PROCESS's cwd (or the `-C <dir>` argument, if
    present in the same segment) — it has no visibility into a `cd` that
    happened earlier in a shell chain this guard doesn't execute, or a cwd
    that differs from git's actual working tree. A branch name that
    coincidentally matches a real path elsewhere on disk, but not relative
    to this cwd, will be missed (allowed) rather than blocked. FAILS OPEN
    on any internal error by returning False, i.e. a bug in this heuristic
    silently disables the check rather than blocking (never raises —
    `evaluate()`'s outer try/except is a second layer, this one avoids
    relying on it). Defensible under the "never crash the hook pipeline"
    contract, but worth knowing: this is fail-open, not fail-closed.
    """
    try:
        m = _CHECKOUT_CMD.search(seg)
        if not m:
            return False
        rest = m.group('rest').strip()
        if not rest:
            return False
        try:
            tokens = shlex.split(rest)
        except ValueError:
            return False
        if not tokens:
            return False
        first = tokens[0]
        if first.startswith('-') or first == '.':
            return False
        cdir_m = _CHECKOUT_CDIR.search(seg)
        base_dir = cdir_m.group(1) if cdir_m else None
        check_path = os.path.join(base_dir, first) if base_dir else first
        return os.path.exists(check_path)
    except Exception:
        return False


# 2026-08-17 third follow-up (security review, final round before ship):
# `-f`/`--force` on checkout is a FLAG, not a pathspec — it proceeds even
# when the working tree differs from HEAD, discarding local changes, e.g.
# `git checkout -f main`. This is ordinary syntax a careless agent types to
# force a branch switch, not an evasion, so (unlike the bare-pathspec case
# above) it IS decidable by regex: any `-f` or `--force` token anywhere on
# the checkout invocation blocks, regardless of branch/pathspec args
# alongside it (`git checkout -f -b new` still blocks on the `-f`).
#
# 2026-08-17 fourth follow-up (completion, same pass): the initial `-f`
# alternative only matched a STANDALONE `-f` token, missing git's own
# CLUSTERED short-flag syntax — `git checkout -fb newbranch` is valid git
# (parsed as `-f -b newbranch`, confirmed: `git checkout -fb` alone errors
# with "switch `b' requires a value", proving git reads it as `-f` then
# `-b`) and is fully destructive (force + branch-create), but was still
# ALLOWED. Same defect class already fixed once in this file for
# `_CLEAN_DRY_RUN` (`-nd`/`-fn` clustering) — same fix shape applies:
# `-[a-zA-Z]*f[a-zA-Z]*` matches any single-dash short-flag cluster
# CONTAINING an `f` in any position (`-fb`, `-bf`, `-f` itself), while
# staying single-dash-anchored so `--force`/`--detach`/`--track` (which
# start with a SECOND `-`, never matched by this alternative) are
# unaffected and still need their own explicit long-flag alternative.
# Clusters with no `f` (`-b`, `-B`, `-q`, `-t`, `-p`, `-m`, `-d`, and any
# combination of them) correctly do NOT match, since the class requires a
# literal lowercase `f` present in the token.
_FORCE_FLAG_LOOKAHEAD = r'(?:^|\s)(?:--force|-[a-zA-Z]*f[a-zA-Z]*)\b'
_CHECKOUT_FORCE_BLOCK = re.compile(
    r'(^|\s)git' + _GIT_OPTS + r'\s+checkout\b(?=.*' + _FORCE_FLAG_LOOKAHEAD + r')'
)


# --- git restore block --------------------------------------------------------
# 2026-08-17: same defect class as checkout above — `git restore` overwrites
# the WORKTREE by default (destructive). Only `--staged` WITHOUT `--worktree`
# is safe (index-only unstage); every other form (bare `restore <path>`,
# `restore .`, `--staged --worktree ...`) blocks. This AND/NOT safety condition
# doesn't compress into one lookahead-only regex without hurting readability of
# safety-critical code, so it's evaluated as two small flag checks in
# _git_evaluate rather than a single mega-regex.
# Tolerates extra VAR=value assignments between CAST_RESTORE_OK=1 and git.
_RESTORE_ALLOW = re.compile(
    r'(^|&&\s*)CAST_RESTORE_OK=1\s+([A-Za-z_][A-Za-z0-9_]*=\S+\s+)*git' + _GIT_OPTS + r'\s+restore\b'
)
_RESTORE_CMD = re.compile(r'(^|\s)git' + _GIT_OPTS + r'\s+restore\b')
_RESTORE_HAS_STAGED = re.compile(r'\s--staged(\s|$)')
_RESTORE_HAS_WORKTREE = re.compile(r'\s--worktree(\s|$)')

# --- git switch block ---------------------------------------------------------
# 2026-08-17 third follow-up: `git switch` is the modern branch-changing
# replacement for the branch half of `checkout`, and was completely
# unguarded — `git switch --discard-changes main` / `git switch -f main`
# both discard uncommitted worktree changes and were previously ALLOWED.
# UNLIKE checkout, plain `git switch <branch>` is NOT destructive by
# default — git refuses it outright when there are conflicting local
# changes — so only the explicit force/discard forms (`-f`, `--force`,
# `--discard-changes`) block; `switch` never takes a pathspec, so no
# filesystem heuristic is needed here (unlike checkout's bare-path case).
# Own hatch (CAST_SWITCH_OK=1), matching the one-hatch-per-command-name
# convention (CAST_RESET_OK/CAST_CLEAN_OK/CAST_CHECKOUT_OK/CAST_RESTORE_OK).
# Reuses `_FORCE_FLAG_LOOKAHEAD` (defined with the checkout block above) for
# the `-f`/`--force`/clustered-`f` detection (2026-08-17 fourth follow-up),
# since `switch` has its own short-flag set (`-c -C -f -t -q -d`) that can
# equally cluster a destructive `-f` with a harmless one, e.g. `git switch
# -fc new` (force + create) — same defect class, same fix.
_SWITCH_ALLOW = re.compile(
    r'(^|&&\s*)CAST_SWITCH_OK=1\s+([A-Za-z_][A-Za-z0-9_]*=\S+\s+)*git' + _GIT_OPTS + r'\s+switch\b'
)
_SWITCH_BLOCK = re.compile(
    r'(^|\s)git' + _GIT_OPTS + r'\s+switch\b'
    r'(?=.*(?:' + _FORCE_FLAG_LOOKAHEAD + r'|(?:^|\s)--discard-changes\b))'
)

# --- git reflog expire/delete block ------------------------------------------
# 2026-08-17 recovery-path pass: `git reflog expire`/`git reflog delete` destroy
# reflog entries — the SAME dangling-object/reflog recovery path that recovered
# a fully reviewed, gated working-tree diff after a dispatched commit agent ran
# a raw `git reset --hard` earlier the same day. Only the two destructive
# subcommands block; `git reflog` (bare), `git reflog show [ref]`, and `git
# reflog exists <ref>` are read-only and stay allowed. Reuses the shell-token
# boundary (`\b`) rather than a trailing `(\s|$)`, same as stash/reset above,
# so adjacent empty-output command substitution (`` git reflog expire`true` ``)
# can't evade it.
# Tolerates extra VAR=value assignments between CAST_REFLOG_OK=1 and git.
_REFLOG_ALLOW = re.compile(
    r'(^|&&\s*)CAST_REFLOG_OK=1\s+([A-Za-z_][A-Za-z0-9_]*=\S+\s+)*git' + _GIT_OPTS + r'\s+reflog\b'
)
_REFLOG_BLOCK = re.compile(
    r'(^|\s)git' + _GIT_OPTS + r'\s+reflog\s+(expire|delete)\b'
)

# --- git gc --prune=<value> block --------------------------------------------
# 2026-08-17 recovery-path pass: measured that `git gc --prune=<value>` (ANY
# explicit value, including `now`/`all`, and even a value as generous as
# `1.hour.ago` against a 3-hour-old dangling blob) deletes unreachable objects
# — the same recovery path noted above. Bare `git gc`, `--aggressive`,
# `--prune` with no `=value`, `--no-prune`, and `--auto` all stay allowed —
# none of them force an immediate/explicit prune. The `--no-prune` case is the
# trap: the flag lookahead below requires the literal substring `--prune=`
# preceded by a token boundary, which `--no-prune` (no `=` at all) never
# contains, so it cannot misfire on it.
# Tolerates extra VAR=value assignments between CAST_GC_OK=1 and git.
_GC_ALLOW = re.compile(
    r'(^|&&\s*)CAST_GC_OK=1\s+([A-Za-z_][A-Za-z0-9_]*=\S+\s+)*git' + _GIT_OPTS + r'\s+gc\b'
)
_GC_PRUNE_VALUE = r'(?:^|\s)--prune=\S+'
_GC_BLOCK = re.compile(
    r'(^|\s)git' + _GIT_OPTS + r'\s+gc\b(?=.*' + _GC_PRUNE_VALUE + r')'
)

# --- git prune block ----------------------------------------------------------
# 2026-08-17 recovery-path pass: bare `git prune` destroys unreachable objects
# with NO grace period at all — measured MORE destructive than `git gc
# --prune=now` (which still respects `gc.pruneExpire`, default 2 weeks, unless
# overridden). Dry runs (`-n`/`--dry-run`, including clustered short-flag forms
# like `-fn`) are the only safe form and stay allowed, mirroring `_CLEAN_DRY_RUN`
# above. Must NOT match `git prune-packed` (a distinct, non-destructive
# command), `git remote prune origin`, or `git worktree prune` (both `prune`
# arguments to a DIFFERENT subcommand, not the top-level destructive `git
# prune`). `\b` alone is wrong here — `prune\b` still matches inside
# `prune-packed` (the `e`->`-` transition IS a word/non-word boundary) — so a
# negative lookahead `(?![\w-])` is used instead, rejecting anything where
# `prune` is immediately followed by a word char or hyphen. `remote prune
# origin`/`worktree prune` are excluded structurally: `_GIT_OPTS` only
# recognizes git's global options (`-C`, `--no-pager`, `-c`, `--git-dir=`,
# `--work-tree=`), not subcommand names like `remote`/`worktree`, so the
# pattern's `\s+prune` can only match when `prune` is the FIRST subcommand
# token right after `git` (+ global opts) — not a later argument to another
# subcommand.
# Tolerates extra VAR=value assignments between CAST_PRUNE_OK=1 and git.
_PRUNE_ALLOW = re.compile(
    r'(^|&&\s*)CAST_PRUNE_OK=1\s+([A-Za-z_][A-Za-z0-9_]*=\S+\s+)*git' + _GIT_OPTS + r'\s+prune(?![\w-])'
)
_PRUNE_BLOCK = re.compile(
    r'(^|\s)git' + _GIT_OPTS + r'\s+prune(?![\w-])(?!.*' + _CLEAN_DRY_RUN + r')'
)

# --- git gc/reflog config-injection block (config-route bypass follow-up) ----
# 2026-08-17 recovery-path pass, follow-up (same day): the three blocks above
# key on the DESTRUCTIVE FLAG (`--prune=<value>`, `reflog expire`/`delete`,
# bare `prune`). Measured that the exact same destruction is reachable with
# NONE of those flags present at all, via git's config layer instead —
# `git -c gc.pruneExpire=now gc` deletes the dangling blob with no `--prune=`
# on the line, and `git -c gc.reflogExpire=now -c gc.pruneExpire=now gc` in
# ONE command reproduces the full `reflog expire --all && gc --prune=now`
# destruction chain with no token any BLOCK regex above would catch. `git
# config` keys are case-insensitive (`gc.pruneexpire` behaves identically to
# `gc.pruneExpire`), so the key match below is case-insensitive; value safety
# is deliberately NOT decidable here either (same precedent as `--prune=
# <value>` above) — ANY value blocks, including a protective `=never`, an
# accepted hatchable false positive.
#
# Two distinct routes, both gated by the SAME hatch (CAST_GC_OK=1 — no new
# hatch for this follow-up):
#
# (A) Inline injection via `-c key=value` on ANY git invocation, regardless
#     of subcommand. NOT narrowed to `gc` — see the KNOWN LIMITATIONS note on
#     `--auto`/`gc.autoDetach` for why: whether inline expiry config plus
#     git's own auto-gc (which can fire on ANY subcommand, e.g. `git -c
#     gc.auto=1 -c gc.pruneExpire=now commit`) is itself destructive at scale
#     is an open, unresolved question this pass could not settle, so the
#     block does not assume "only `gc` matters."
# (B) `git config` WRITES of an expiry key (any form: bare, `--local`,
#     `--global`, `--replace-all`, ...) — closes `git config gc.pruneExpire
#     now && git gc`, where the destructive second segment is a bare `git gc`
#     that looks innocent in isolation to the per-segment evaluator; the
#     config WRITE in segment 1 is the actual destructive act. A READ (`git
#     config --get gc.pruneExpire`, or a bare `git config gc.pruneExpire`
#     with no value token — git itself treats that as a print-current-value
#     read) must NOT be caught: the pattern requires BOTH the absence of
#     `--get`/`--get-all`/etc. AND a value token following the key, so a
#     bare-key read is allowed on either condition alone.
_GC_CONFIG_KEY = r'(?i:gc\.(?:reflogExpireUnreachable|reflogExpire|pruneExpire))'
_GC_HATCH_ALLOW = re.compile(
    r'(^|&&\s*)CAST_GC_OK=1\s+([A-Za-z_][A-Za-z0-9_]*=\S+\s+)*git\b'
)
_GC_CINJECT_BLOCK = re.compile(
    r'(^|\s)git\b(?=.*(?:^|\s)-c\s+' + _GC_CONFIG_KEY + r'=)'
)
_GC_CONFIG_WRITE_BLOCK = re.compile(
    r'(^|\s)git' + _GIT_OPTS + r'\s+config\b'
    r'(?!.*--get)'
    r'(?=.*\s' + _GC_CONFIG_KEY + r'\s+\S)'
)

_COMMIT_MSG = (
    "**[CAST]** Raw `git commit` blocked. Dispatch the `commit` agent instead "
    "(Agent tool, subagent_type: 'commit')."
)
_PUSH_MSG = (
    "**[CAST]** Raw `git push` blocked. Ensure code-reviewer has run, then use "
    "`CAST_PUSH_OK=1 git push` or dispatch via the commit agent workflow."
)
_STASH_MSG = (
    "**[CAST]** Raw `git stash` blocked. Stash operations are prohibited for agents "
    "— they risk resurrecting abandoned stashes from other sessions. If you genuinely "
    "need stash, use `CAST_STASH_OK=1 git stash` (document your reason). "
    "See: 2026-05-19 push-agent stash incident."
)
_RESET_MSG = (
    "**[CAST]** Raw `git reset --hard`/`--merge`/`--keep` blocked — it destroys "
    "uncommitted work. Recovering a fully reviewed, gated working-tree diff on "
    "2026-08-17 (after a dispatched commit agent ran a raw `git reset --hard`) "
    "required hunting a dangling blob in the object DB. If you genuinely need to "
    "discard the working tree, use `CAST_RESET_OK=1 git reset --hard` (document why)."
)
_CLEAN_MSG = (
    "**[CAST]** Raw `git clean` blocked (dry runs via `-n`/`--dry-run` are exempt) "
    "— it permanently deletes untracked files. Paired with the 2026-08-17 "
    "`git reset --hard` incident that destroyed a reviewed, gated working-tree diff. "
    "If you genuinely need to clean, use `CAST_CLEAN_OK=1 git clean ...` (document why)."
)
_CHECKOUT_MSG = (
    "**[CAST]** Raw `git checkout -- <pathspec>` / `git checkout .` / "
    "`git checkout <existing path>` / `git checkout -f`/`--force` blocked — it "
    "discards uncommitted worktree changes. The bare-pathspec form is the exact "
    "mechanism a READ-ONLY code-reviewer used to silently revert the file it was "
    "reviewing (2026-08-15/2026-08-17 class of incident, e.g. `git checkout "
    "completions/cast.bash` with no `--`); `-f`/`--force` forces a branch switch "
    "through local changes the same way. Plain branch checkouts (`checkout "
    "<branch>`, `-b`, `-`, `--track`) are unaffected. If you genuinely need to "
    "discard a path or force a switch, use `CAST_CHECKOUT_OK=1 git checkout ...` "
    "(document why)."
)
_RESTORE_MSG = (
    "**[CAST]** Raw `git restore` blocked — by default it overwrites the WORKTREE "
    "(destructive). Only `git restore --staged <path>` (without `--worktree`) is "
    "allowed, since that only unstages. If you genuinely need to restore worktree "
    "content, use `CAST_RESTORE_OK=1 git restore ...` (document why)."
)
_SWITCH_MSG = (
    "**[CAST]** Raw `git switch -f`/`--force`/`--discard-changes` blocked — it "
    "discards uncommitted worktree changes the same way `checkout -f` does. Plain "
    "`git switch <branch>` is unaffected (git itself refuses it when local changes "
    "conflict). If you genuinely need to force a switch, use `CAST_SWITCH_OK=1 "
    "git switch ...` (document why)."
)
_REFLOG_MSG = (
    "**[CAST]** Raw `git reflog expire`/`git reflog delete` blocked — it "
    "permanently destroys reflog entries, closing off the dangling-object "
    "recovery path that saved a fully reviewed, gated working-tree diff after "
    "a dispatched commit agent ran a raw `git reset --hard` on 2026-08-17. "
    "Read-only forms (`git reflog`, `git reflog show`, `git reflog exists`) are "
    "unaffected. If you genuinely need to expire/delete reflog entries, use "
    "`CAST_REFLOG_OK=1 git reflog ...` (document why)."
)
_GC_MSG = (
    "**[CAST]** Raw `git gc --prune=<value>` blocked — an explicit prune value "
    "(including `now`/`all`, or any age) permanently deletes unreachable "
    "objects, closing off the same 2026-08-17 dangling-blob recovery path. "
    "Bare `git gc`, `--aggressive`, `--prune` (no value), `--no-prune`, and "
    "`--auto` are unaffected. If you genuinely need an explicit prune, use "
    "`CAST_GC_OK=1 git gc --prune=<value>` (document why)."
)
_PRUNE_MSG = (
    "**[CAST]** Raw `git prune` blocked (dry runs via `-n`/`--dry-run` are "
    "exempt) — it deletes unreachable objects with no grace period at all, "
    "closing off the same 2026-08-17 dangling-blob recovery path (more "
    "destructive than `git gc --prune=now`, which still respects "
    "`gc.pruneExpire`). `git prune-packed`, `git remote prune`, and `git "
    "worktree prune` are unaffected. If you genuinely need to prune, use "
    "`CAST_PRUNE_OK=1 git prune ...` (document why)."
)
_GC_CINJECT_MSG = (
    "**[CAST]** Raw `git -c gc.pruneExpire=<value>` / `-c gc.reflogExpire=<value>` "
    "/ `-c gc.reflogExpireUnreachable=<value>` blocked (key match is "
    "case-insensitive; ANY value blocks, including `never`) — this is a "
    "config-layer bypass of the reflog/gc/prune blocks above: it reaches the "
    "exact same dangling-object/reflog recovery-path destruction with no "
    "`--prune=`/`expire`/`prune` token on the line for those checks to key "
    "on. If you genuinely need to set one of these inline, use "
    "`CAST_GC_OK=1 git -c gc.pruneExpire=<value> ...` (document why)."
)
_GC_CONFIG_WRITE_MSG = (
    "**[CAST]** `git config` write of `gc.pruneExpire` / `gc.reflogExpire` / "
    "`gc.reflogExpireUnreachable` blocked (key match is case-insensitive; "
    "reads via `--get`/a bare key with no value are unaffected) — this is "
    "the same config-layer bypass as the inline `-c` block, staged instead "
    "via a persistent config write that makes a LATER, innocent-looking bare "
    "`git gc` destructive. If you genuinely need to set one of these, use "
    "`CAST_GC_OK=1 git config gc.pruneExpire ...` (document why)."
)

SESSION_TIMEOUT = 7200  # 2 hours, matches the agent-status TTL


def _claude_dir() -> str:
    return os.environ.get('CLAUDE_DIR', os.path.join(os.path.expanduser('~'), '.claude'))


# --------------------------------------------------------------------------
# Write/Edit: agent-status TTL sweep + policy engine
# --------------------------------------------------------------------------
def _ttl_sweep_agent_status() -> None:
    """Delete agent-status/*.json older than 120 min (mirrors `find -mmin +120 -delete`)."""
    try:
        status_dir = os.path.join(_claude_dir(), 'agent-status')
        if not os.path.isdir(status_dir):
            return
        now = datetime.datetime.now(datetime.timezone.utc).timestamp()
        for fname in os.listdir(status_dir):
            if not fname.endswith('.json'):
                continue
            fpath = os.path.join(status_dir, fname)
            try:
                age_min = int((now - os.path.getmtime(fpath)) / 60)
                if age_min > 120:
                    os.remove(fpath)
            except Exception:
                pass
    except Exception:
        pass


def _agent_completed_this_session(required_agent: str, agent_status_dir: str, now: float) -> bool:
    """The MOST RECENT fresh (< SESSION_TIMEOUT) agent-status file for required_agent
    reports DONE / DONE_WITH_CONCERNS.

    Picks the newest matching file by mtime so a later BLOCKED/NEEDS_CONTEXT review
    supersedes an earlier DONE (re-run safety). The filename written by
    status-writer.sh is ``<agent>-<ts>.json``, so an exact ``<agent>-`` prefix match
    avoids spurious hits from agent names that merely contain required_agent. Reads
    the structured ``status`` field (not a substring scan) and fails CLOSED (keeps
    the block) on any read/parse error. Mirrors orchestrate-dispatch.py
    cmd_recent_status.
    """
    if not os.path.isdir(agent_status_dir):
        return False
    prefix = required_agent + '-'
    newest_path = None
    newest_mtime = -1.0
    for fname in os.listdir(agent_status_dir):
        if not fname.startswith(prefix):
            continue
        fpath = os.path.join(agent_status_dir, fname)
        try:
            mtime = os.path.getmtime(fpath)
        except OSError:
            continue
        if now - mtime >= SESSION_TIMEOUT:
            continue
        if mtime > newest_mtime:
            newest_mtime = mtime
            newest_path = fpath
    if newest_path is None:
        return False
    try:
        with open(newest_path) as f:
            data = json.load(f)
    except (OSError, ValueError):
        return False
    return data.get('status') in ('DONE', 'DONE_WITH_CONCERNS')


def _policy_evaluate(file_path: str):
    """Evaluate config/policies.json against file_path. Returns (exit_code, message_or_None).

    Mirrors the inline policy engine: a `block`-severity policy whose path_pattern
    matches AND whose required_agent has NOT completed this session → (2, msg).
    CAST_POLICY_OVERRIDE=1 bypasses block policies (audit-logged). `warn` policies
    allow silently (the original routed warns to a suppressed stream).
    """
    override = os.environ.get('CAST_POLICY_OVERRIDE', '0') == '1'
    session_id = os.environ.get('CLAUDE_SESSION_ID', 'default')

    policies_path = os.path.join(os.getcwd(), 'config', 'policies.json')
    if not os.path.exists(policies_path):
        policies_path = os.path.expanduser('~/.claude/config/policies.json')
    if not os.path.exists(policies_path):
        return 0, None
    try:
        with open(policies_path) as f:
            config = json.load(f)
    except Exception:
        return 0, None

    agent_status_dir = os.path.expanduser('~/.claude/agent-status')
    now = datetime.datetime.now(datetime.timezone.utc).timestamp()

    for policy in config.get('policies', []):
        pattern = policy.get('path_pattern', '')
        if not pattern:
            continue
        try:
            if not re.search(pattern, file_path, re.IGNORECASE):
                continue
        except re.error:
            continue

        policy_id = policy.get('id', 'unknown')
        required_agent = policy.get('requires_agent', '')
        severity = policy.get('severity', 'warn')
        description = policy.get('description', '')

        if not required_agent:
            continue
        if _agent_completed_this_session(required_agent, agent_status_dir, now):
            continue

        if severity == 'block':
            if override:
                _audit_policy_override(policy_id, file_path, session_id)
                return 0, None
            msg = (
                f'**[CAST-POLICY-BLOCK]** Policy "{policy_id}" blocks this edit.\n'
                f'Reason: {description}\n'
                f'Required flow: dispatch `{required_agent}` REVIEW-ONLY — it must NOT apply this edit itself '
                f'(its own edits stay blocked until its completion marker exists, which deadlocks). '
                f'When it ends DONE its agent-status marker unblocks the session; then the ORCHESTRATOR applies the edit to `{file_path}`.\n'
                f'Escape hatch: Set CAST_POLICY_OVERRIDE=1 to bypass (document your reason).'
            )
            return 2, msg
        # severity == warn → allow silently (faithful to the original's suppressed warn stream)
    return 0, None


def _audit_policy_override(policy_id: str, file_path: str, session_id: str) -> None:
    try:
        audit_path = os.path.expanduser('~/.claude/logs/audit.jsonl')
        os.makedirs(os.path.dirname(audit_path), exist_ok=True)
        event = {
            'timestamp': datetime.datetime.now(datetime.timezone.utc)
            .isoformat().replace('+00:00', 'Z'),
            'event': 'POLICY_OVERRIDE',
            'policy_id': policy_id,
            'file_path': file_path,
            'session_id': session_id,
            'override_env': 'CAST_POLICY_OVERRIDE',
        }
        with open(audit_path, 'a') as af:
            af.write(json.dumps(event) + '\n')
    except Exception:
        pass


# --------------------------------------------------------------------------
# Bash: git commit / push / stash guards
# --------------------------------------------------------------------------
def _repo_toplevel() -> str:
    """Return the cwd repo's git toplevel, or '' on any failure (best-effort).

    A '' result degrades the hatch event to legacy-global handling in the
    reconcile gate (fail-closed, per the D5 hardening compat table)."""
    try:
        r = subprocess.run(['git', 'rev-parse', '--show-toplevel'],
                           capture_output=True, text=True, timeout=5)
        return r.stdout.strip() if r.returncode == 0 else ''
    except Exception:
        return ''


def _hatch_session_id(repo: str) -> str:
    """Resolve the session id for a hatch event, mirroring cast-commit-provenance.

    Order: CAST_SESSION_ID → CLAUDE_SESSION_ID → DB unique-active-or-refuse
    fallback (exactly one active session for this repo → use it, else honest '').
    The DB tier is required for parity: neither env var reliably reaches the
    commit-agent Bash subprocess. Ambiguity yields '' rather than a confabulated
    attribution (wave-1 dead-teammate incident)."""
    sid = os.environ.get('CAST_SESSION_ID') or os.environ.get('CLAUDE_SESSION_ID', '')
    if sid:
        return sid
    try:
        import sqlite3
        db = os.environ.get('CAST_DB_PATH', os.path.expanduser('~/.claude/cast.db'))
        conn = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
        conn.execute("PRAGMA busy_timeout = 2000")
        rows = conn.execute(
            "SELECT id FROM sessions WHERE status='active' AND project_root=? "
            "ORDER BY started_at DESC LIMIT 2", (repo,)).fetchall()
        conn.close()
        return rows[0][0] if len(rows) == 1 else ''   # unique-active or honest ''
    except Exception:
        return ''


def _audit_commit_hatch() -> None:
    """Append a COMMIT_HATCH_USED line to audit.jsonl — best-effort, never blocks."""
    try:
        repo = _repo_toplevel()
        audit_path = os.path.expanduser('~/.claude/logs/audit.jsonl')
        os.makedirs(os.path.dirname(audit_path), exist_ok=True)
        event = {
            'timestamp': datetime.datetime.now(datetime.timezone.utc)
            .isoformat().replace('+00:00', 'Z'),
            'event': 'COMMIT_HATCH_USED',
            'override_env': 'CAST_COMMIT_AGENT',
            'git_op': 'commit',
            'repo': repo,
            'session_id': _hatch_session_id(repo),
            'in_claude_session': os.environ.get('CLAUDECODE') == '1',
        }
        with open(audit_path, 'a') as af:
            af.write(json.dumps(event) + '\n')
    except Exception:
        pass


def _audit_push_hatch() -> None:
    """Append a PUSH_HATCH_USED line to audit.jsonl — best-effort, never blocks."""
    try:
        repo = _repo_toplevel()
        audit_path = os.path.expanduser('~/.claude/logs/audit.jsonl')
        os.makedirs(os.path.dirname(audit_path), exist_ok=True)
        event = {
            'timestamp': datetime.datetime.now(datetime.timezone.utc)
            .isoformat().replace('+00:00', 'Z'),
            'event': 'PUSH_HATCH_USED',
            'override_env': 'CAST_PUSH_OK',
            'git_op': 'push',
            'repo': repo,
            'session_id': _hatch_session_id(repo),
            'in_claude_session': os.environ.get('CLAUDECODE') == '1',
        }
        with open(audit_path, 'a') as af:
            af.write(json.dumps(event) + '\n')
    except Exception:
        pass


def _git_evaluate(command: str):
    """Evaluate the FIRST LINE of a Bash command for git commit/push/stash/
    reset/clean/checkout/restore/switch.

    First-line-only scan prevents a multiline escape-hatch on line 2 from
    unblocking a git command on line 1. Returns (exit_code, message_or_None).

    Evaluated PER SHELL SEGMENT (2026-08-17 same-op fix, security review),
    splitting the first line on `;`, `&&`, `||`, and `|`. This mirrors real
    shell semantics: `VAR=1 cmd` scopes VAR to that one command, not to
    everything chained after it on the line. Per-line (not per-segment)
    evaluation let a hatch attached to a HARMLESS invocation of an op unlock
    a DESTRUCTIVE invocation of the *same* op later on the line — e.g.
    `CAST_RESET_OK=1 git reset --soft && git reset --hard` was allowed,
    because the line-wide *_ALLOW.search() doesn't care which `git reset`
    it matched against. Verified pre-existing (not introduced by the
    reset/clean/checkout/restore additions) even for commit/push: at HEAD,
    `CAST_COMMIT_AGENT=1 git commit --dry-run && git commit -m x` was
    allowed. `seg.strip()` is load-bearing: the *_ALLOW patterns anchor a
    hatch to the START of a segment (`^`); an un-stripped leading space
    after splitting on `&&`/`;` would make a legitimate per-segment hatch
    like `CAST_RESET_OK=1 git reset --hard && CAST_CLEAN_OK=1 git clean -fdx`
    wrongly block on its second segment.

    Each op is ALSO evaluated independently within a segment (2026-08-17
    short-circuit fix): a matched *_ALLOW suppresses ONLY its own op's block
    and does not skip the other ops' BLOCK checks in the same segment.

    Net effect: a combined-prefix hatch (`CAST_RESET_OK=1 CAST_CLEAN_OK=1
    git reset --hard && git clean -fdx`) still BLOCKS — segment 2 carries no
    hatch of its own — so "each destructive git command needs its OWN hatch
    immediately before it" holds for same-op chains too, not just cross-op
    chains.
    """
    first_line = command.split('\n', 1)[0]

    for seg in re.split(r';|&&|\|\||\|', first_line):
        seg = seg.strip()
        if not seg:
            continue
        if _COMMIT_ALLOW.search(seg):
            _audit_commit_hatch()
        elif _COMMIT_BLOCK.search(seg):
            return 2, _COMMIT_MSG
        if _PUSH_ALLOW.search(seg):
            _audit_push_hatch()
        elif _PUSH_BLOCK.search(seg):
            return 2, _PUSH_MSG
        if not _STASH_ALLOW.search(seg) and _STASH_BLOCK.search(seg):
            return 2, _STASH_MSG
        if not _RESET_ALLOW.search(seg) and _RESET_BLOCK.search(seg):
            return 2, _RESET_MSG
        if not _CLEAN_ALLOW.search(seg) and _CLEAN_BLOCK.search(seg):
            return 2, _CLEAN_MSG
        if not _CHECKOUT_ALLOW.search(seg) and (
            _CHECKOUT_BLOCK.search(seg)
            or _checkout_bare_path_blocks(seg)
            or _CHECKOUT_FORCE_BLOCK.search(seg)
        ):
            return 2, _CHECKOUT_MSG
        if not _RESTORE_ALLOW.search(seg) and _RESTORE_CMD.search(seg):
            safe = bool(_RESTORE_HAS_STAGED.search(seg)) and not _RESTORE_HAS_WORKTREE.search(seg)
            if not safe:
                return 2, _RESTORE_MSG
        if not _SWITCH_ALLOW.search(seg) and _SWITCH_BLOCK.search(seg):
            return 2, _SWITCH_MSG
        if not _REFLOG_ALLOW.search(seg) and _REFLOG_BLOCK.search(seg):
            return 2, _REFLOG_MSG
        if not _GC_ALLOW.search(seg) and _GC_BLOCK.search(seg):
            return 2, _GC_MSG
        if not _PRUNE_ALLOW.search(seg) and _PRUNE_BLOCK.search(seg):
            return 2, _PRUNE_MSG
        if not _GC_HATCH_ALLOW.search(seg) and _GC_CINJECT_BLOCK.search(seg):
            return 2, _GC_CINJECT_MSG
        if not _GC_HATCH_ALLOW.search(seg) and _GC_CONFIG_WRITE_BLOCK.search(seg):
            return 2, _GC_CONFIG_WRITE_MSG
    return 0, None


# --------------------------------------------------------------------------
# Top-level evaluation (importable by the dispatcher)
# --------------------------------------------------------------------------
def evaluate(tool_name: str, tool_input: dict):
    """Return (exit_code, message). 0 = allow, 2 = block (message is the block reason).

    Never raises — internal errors fail-open to (0, '')."""
    try:
        if not isinstance(tool_input, dict):
            tool_input = {}
        if tool_name in ('Write', 'Edit'):
            file_path = tool_input.get('file_path', tool_input.get('path', '')) or ''
            if file_path:
                _ttl_sweep_agent_status()
                code, msg = _policy_evaluate(file_path)
                if code == 2:
                    return 2, msg
            return 0, ''
        if tool_name != 'Bash':
            return 0, ''
        command = tool_input.get('command', '') or ''
        code, msg = _git_evaluate(command)
        return (code, msg or '') if code == 2 else (0, '')
    except Exception:
        return 0, ''


def main() -> int:
    try:
        raw = sys.stdin.read()
    except Exception:
        return 0
    if not raw.strip():
        return 0
    try:
        data = json.loads(raw)
    except Exception:
        return 0
    if not isinstance(data, dict):
        return 0

    tool_name = data.get('tool_name', '') or ''
    tool_input = data.get('tool_input', {}) or {}
    if not isinstance(tool_input, dict):
        tool_input = {}

    # Irreversible git ops (commit/push/stash/reset --hard/merge/keep/clean/
    # checkout --/restore) are guarded in EVERY context, including dispatched
    # subagents and headless runs —
    # see the matching note in cast-pretool-dispatch.py. Escape hatches still apply
    # (_git_evaluate checks the *_ALLOW patterns first). The CLAUDE_SUBPROCESS skip
    # below covers ONLY the Write/Edit policy engine + agent-status TTL sweep
    # (recursion prevention).
    if tool_name == 'Bash':
        command = tool_input.get('command', '') or ''
        gcode, gmsg = _git_evaluate(command)
        if gcode == 2:
            if gmsg:
                print(gmsg, file=sys.stderr)
            return 2

    if os.environ.get('CLAUDE_SUBPROCESS', '0') == '1':
        return 0

    code, msg = evaluate(tool_name, tool_input)
    if code == 2:
        if msg:
            print(msg, file=sys.stderr)
        return 2
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except SystemExit:
        raise
    except Exception:
        sys.exit(0)
