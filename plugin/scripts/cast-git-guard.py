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
  - Quoted-token evasion CLOSED (2026-08-17 shlex tokenization pass): every
    BLOCK regex above matches a BARE shell token, so `git reset "--hard"`,
    `git "reset" --hard`, `git "commit" -m x`, `git "push"`, `git checkout
    "--" .`, `git switch "--discard-changes" main`, `git gc "--prune=now"`,
    `git reflog "expire" --all`, `git -c "gc.pruneExpire=now" gc`, and `git
    "config" gc.pruneExpire now` were all measured ALLOWED before this pass.
    `_normalize_git_segment()` re-tokenizes each shell segment with
    `shlex.split()` and re-joins it unquoted; `_git_evaluate`'s `hit()`
    wrapper then checks every existing pattern against BOTH the raw segment
    and (when it parses as a git invocation) its normalized form — no
    individual BLOCK/ALLOW regex was rewritten to get this. Absolute-path
    invocation (`/usr/bin/git reset --hard`, previously allowed because
    every pattern anchors on `(^|\s)git`, and the char before `git` here is
    `/`) is closed the same way: the first non-assignment token is
    normalized to the literal `git` whenever `os.path.basename()` of it
    equals `git` (so `./mygit` does NOT normalize — no basename collision).
    Normalization runs ONLY when the segment IS a git invocation (leading
    `VAR=value` assignments, then `git`/`/path/to/git`); a segment that
    isn't a git command to begin with (`rg "git push" docs/`, `gh pr create
    --body "adds git push guard"`) returns None and is evaluated exactly as
    before — this was a deliberate choice (Ed, this session): normalizing
    EVERY segment was measured to newly BLOCK ordinary non-git commands
    with NO working escape hatch, because every `*_ALLOW` hatch pattern
    requires `git` immediately after the env assignments and a non-git
    segment can never satisfy that. NOT covered by this pass (see KNOWN
    LIMITATIONS below for the durable list): subshell/`$()` wrapping,
    `--config-env=`/`GIT_CONFIG_*` env indirection, unbalanced-quote parse
    failures (raw-only fallback), and quoting a *safety*-flag token for
    `clean` specifically — that one is a structural asymmetry, not an
    oversight, documented in `_git_evaluate`'s docstring.
  - `git config edit`/`--edit`/`-e` blocked under the SAME hatch as the
    `git config` write block below (CAST_GC_OK=1) — an interactive editor
    session on `.git/config` can set `gc.pruneExpire`/`gc.reflogExpire`/
    `gc.reflogExpireUnreachable` to `now` with no key/value token ever
    appearing on the command line for the write-detection block to key on
    (2026-08-17 shlex tokenization pass, same-day follow-up).
  - Two more same-day (2026-08-17) fixes, both from a security-gate review of
    this pass, honestly recorded here on the ALLOW side too (not just what
    got newly blocked):
    (1) `_GC_CONFIG_EDIT_BLOCK` originally matched the bare token `edit`
    ANYWHERE on the line, so it false-blocked reads/values that merely
    contained "edit": `git config user.email "edit@example.com"`, `git
    config --get-regexp edit` (a READ), `git config alias.e "edit"`. `edit`
    IS a real subcommand (git ≥ 2.46: `get|set|unset|list|edit`), so the
    bare token now anchors to SUBCOMMAND POSITION only (via
    `_GC_CONFIG_SCOPE_FLAGS`, an enumerated valueless-flag allowlist —
    deliberately not a generic `--\S+` skip, which would swallow
    value-taking options like `--get-regexp` and reintroduce the same false
    block); `--edit`/`-e` remain matched anywhere as unambiguous flags. All
    three commands above now correctly ALLOW; `git config edit`, `git config
    --edit`, `git config -e`, `git config --global -e`, `git config
    --global edit`, `git config --local edit` still correctly BLOCK.
    (2) `_normalize_git_segment`'s rejoin (`' '.join(tokens)`) broke on a
    leading env-assignment VALUE containing whitespace: `CAST_RESET_OK=1
    FOO="bar baz" git reset --hard` is a genuine, valid hatch use, but
    `shlex.split` parses `FOO=bar baz` as one token while every `*_ALLOW`
    pattern's assignment-tolerance (`\S+`) cannot span the re-rendered
    space — a real hatch use false-blocked. Whitespace-containing values in
    the assignment PREFIX (indices before the `git` token) are now collapsed
    to a placeholder (`FOO=_`) before rejoining; this now correctly ALLOWS,
    and `CAST_RESET_OK="10" git reset --hard` (wrong hatch VALUE) still
    correctly BLOCKS — the fix only fixes the whitespace-join bug, it does
    not loosen the value check. Two more cases worth naming plainly rather
    than silently absorbing: `CAST_RESET_OK="1" git reset --hard` /
    `CAST_PUSH_OK="1" git push` (a quoted hatch VALUE — a real bash
    assignment) previously false-blocked and now correctly ALLOWS, a
    straightforward FIX. But `"CAST_RESET_OK=1" git reset --hard` (a
    FULLY-QUOTED assignment WORD) is NOT a bash assignment at all — measured
    live, bash resolves the quoted word as a command name and errors
    (`bash: CAST_RESET_OK=1: command not found`), so git never executes;
    this guard now allows a line that cannot run in the first place. That is
    an inert over-allow (no destructive git command actually runs), not a
    guarantee regression, but it is a real behavior change on the ALLOW side
    and is named here rather than left undocumented.
  - Write/Edit path policy engine (config/policies.json → requires_agent gate,
    CAST_POLICY_OVERRIDE=1 escape with audit-log).
  - agent-status TTL sweep (files older than 120 min) on Write/Edit.

SECURITY (updated 2026-08-24, SEC-1 fix — every line is now scanned; see the
updated KNOWN LIMITATIONS below for what this replaces):
  - The escape hatch MUST appear as a leading env-var assignment BEFORE the git
    command, in the SAME shell segment (tolerating leading `cd &&` chains and
    git global options). It can NEVER take effect from inside a commit message
    / comment / echo. Multiline commands are now fully scanned (every line,
    not just the first — see `_scannable_segments()`), but a hatch on one
    line/segment still can't unblock a destructive op on a DIFFERENT
    line/segment: that guarantee comes from the PER-SEGMENT evaluation below,
    not from limiting how much of the command gets scanned. A multiline
    escape-hatch on line 2 still can't bypass a git command on line 1.
  - `_git_evaluate` splits every line of the command into SHELL SEGMENTS on
    `;`, `&&`, `||`, and `|` (2026-08-24: widened from first-line-only via
    `_scannable_segments()` — see KNOWN LIMITATIONS below), and evaluates
    each segment on its own (2026-08-17 fix —
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
  - Multiline scanning (2026-08-24 SEC-1 fix): every line of the command is
    scanned, via `_scannable_segments()`, not just line 1 — `echo hi` /
    `git reset --hard` on line 2 correctly blocks. The function performs
    exactly two operations: backslash line-continuations are joined across
    ALL lines, counting TRAILING backslashes so only an ODD count joins
    (SEC-1 C2 fix) — an EVEN count is a paired-off literal escape, not a
    continuation, and is left unjoined; a single trailing backslash still
    joins `git \` / `reset --hard` into one logical line, and an odd count
    of N backslashes collapses to (N-1)/2 literal backslashes once the
    continuation itself is consumed (2026-08-24 correctness fix — the
    prior version left N-1 residual backslashes for N >= 3). Each
    resulting line is then split into shell segments on `;`, `&&`, `||`,
    `|`, same as line 1 always was. That is the entire transformation.
      COMMENTS ARE NOT SKIPPED (2026-08-24 SEC-1 D2 removal, superseding
    the D1 fix this bullet used to describe). This module previously tried
    to classify and drop leading-`#` comment lines from the scan, and
    tried it in BOTH possible orderings relative to continuation-joining —
    join-then-drop, and drop-then-join — and BOTH were empirically
    demonstrated, this session, to produce a fail-open bypass, in opposite
    directions, verified against real bash with a `git` PATH-shim:
      join-then-drop (the original SEC-1 multiline fix): `# note \`
    followed by `git stash` on the next line joined into one string,
    `# note git stash`, before the comment check ever ran — and since the
    JOINED string starts with `#`, the whole thing was dropped as one
    comment. But real bash treats a trailing backslash INSIDE a comment as
    inert: a comment runs to the newline unconditionally, so `# note \` is
    a complete, self-terminating comment and `git stash` on the next line
    is a separate, real command that runs. The guard returned rc=0 (allow)
    while the stash genuinely ran.
      drop-then-join (the D1 fix, this module's immediately prior state):
    `echo foo\` followed by `#bar; git reset --hard` classified the SECOND
    line as a comment and dropped it, in isolation, before any joining
    ran. But real bash joins the first line's trailing backslash with the
    second line BEFORE that line's `#` is ever evaluated, fusing `foo` and
    `#bar` into one word (`foo#bar`) where `#` is no longer at a word
    start and is therefore not a comment marker at all — bash prints
    `foo#bar` and then genuinely runs `git reset --hard` after the `;`.
    Dropping the second line in isolation discarded that real, executable
    `git reset --hard` from the scan entirely.
      Root cause: bash decides comment-hood WORD-WISE, during lexing,
    interleaved with continuation removal — a `#` starts a comment only at
    a word start, and whether a given line's leading `#` IS a word start
    depends on whether a preceding line's trailing backslash fused
    something onto it. Neither a per-original-line check (drop-first) nor
    a post-join whole-string check (join-first) can decide that correctly;
    only a real, character-by-character shell lexer can, interleaving
    continuation-removal and comment detection the way bash itself does —
    which is exactly the kind of hand-rolled parser already tried once for
    heredocs (below) and shown to produce two CRITICAL bypasses of its
    own. So comment suppression is deleted here too, rather than
    re-ordered a third time.
      This is a statement of what the function costs, not a claim that the
    multiline surface is now closed: a comment mentioning a guarded git
    command — a whole comment line (`# git push`) or comment text fused by
    a continuation into an adjacent line — is scanned exactly like any
    other text and BLOCKS, and needs that op's own `CAST_*_OK=1` hatch on
    that line/segment to proceed.
      2026-08-24 SEC-1 heredoc-suppression REMOVAL (design decision, not a
    third patch): this module used to also drop heredoc BODIES before the
    per-line scan, on the theory that a heredoc body is inert data the
    shell never executes as a command — first via a bare `<<` regex, then
    (C1, CRITICAL, closed same day) via a quote/comment-aware detector
    wrapper plus a fail-closed unterminated-heredoc fallback, after the
    bare regex was found to swallow every remaining
    line to EOF on three ordinary, non-adversarial constructs (a herestring
    `<<<WORD`, a `<<` inside a quoted string, a `<<` after an unquoted
    trailing `#`) — none of which ever produces a real terminator line, so
    the bypass had UNBOUNDED blast radius, hiding an arbitrary number of
    real, unguarded destructive git commands.
    That fix held for less than a day: the detector's
    quote-parity scan tracks `'`/`"` state character-by-character but does
    not understand backslash-escaped quotes, so
    `echo "text \" <<EOF"` — a single, self-contained echo in real bash,
    with NO heredoc at all — desyncs its tracked quote state into believing
    a real `<<EOF` heredoc opened; a real destructive git command on the
    next line is then swallowed as "heredoc body" and a later `EOF` line
    closes the fake heredoc, so the whole line is silently dropped from
    the scan while bash executes it for real. Verified against real bash
    with a `git` PATH-shim, both for a double-quoted (`\"`) and an ANSI-C
    single-quoted (`$'...\'...'`) escaped-quote form. Two CRITICAL bypasses
    from the SAME parser across three review rounds is the parser proving
    itself untractable, not a pair of unlucky one-off bugs — a hand-rolled
    shell quote scanner cannot safely draw the "is this really inside a
    string" line by chasing each new escaping construct as it is found. So
    THE PARSER IS DELETED rather than patched a third time: the heredoc-start
    regex and its quote/comment-aware detector wrapper no longer exist, and
    `_scannable_segments()` no longer special-cases heredocs at all — a heredoc body is scanned
    exactly like any other line, with the SAME per-line/per-segment
    evaluation as everything else. Removing the parser removes the whole
    misdetection class: there is nothing left for an escaping trick to fool.
    Accepted cost, deliberate and approved (not an oversight): a heredoc
    body that happens to mention a guarded git command as PROSE — e.g.
    documentation authored via `cat > notes.md <<EOF` — now false-BLOCKs,
    and needs a per-segment `CAST_*_OK=1` hatch on that line to write. A
    rare, hatchable false positive is preferable to a parser that has
    already produced two silent, unbounded bypasses.
    Widening the scan to every line (including former heredoc bodies) is
    safe specifically BECAUSE of the per-segment evaluation above: a hatch
    on one line/segment cannot reach a destructive op on a different
    line/segment, so there is no line-2-hatch-unblocks-line-1-op risk from
    scanning further.
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
  - Quoted-token evasion is CLOSED — see the GUARANTEES PRESERVED section
    above (2026-08-17 shlex tokenization pass) for the mechanism
    (`_normalize_git_segment()` + the `hit()` dual-variant check) and its
    deliberately narrow scope. One asymmetry survives BY DESIGN, not by
    oversight: `restore`'s safety check is a separate positive predicate
    (`hit(_RESTORE_HAS_STAGED) and not hit(_RESTORE_HAS_WORKTREE)`), so
    normalizing either operand independently fixes it — `git restore
    "--staged" f.txt` (blocked at HEAD, a fail-CLOSED false positive) now
    correctly ALLOWS. `clean`'s dry-run safety instead lives INSIDE
    `_CLEAN_BLOCK`'s own negative lookahead, evaluated once per variant and
    OR'd by `hit()` — so if the RAW variant alone still trips the block (as
    it does for a quoted safety flag, since the lookahead never sees past
    the quote), the normalized variant's safe verdict can't override it:
    `git clean "-nd"` still blocks. Restructuring `_CLEAN_BLOCK` to match
    `restore`'s shape would fix it too, but was deliberately deferred this
    pass to keep the diff on this safety-critical file small.
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


# --- shell-quoting normalization (2026-08-17 shlex tokenization pass) -------
# Every BLOCK regex in this module matches a BARE shell token; quoting the
# git subcommand or a destructive flag (`git reset "--hard"`, `git "commit"
# -m x`) evades every regex above since the shell strips quotes the regex
# never sees past. `_normalize_git_segment` re-tokenizes a segment with
# shlex and re-joins it unquoted, giving every existing regex a SECOND,
# quote-stripped view to match against (see `_git_evaluate`'s `hit()`
# wrapper below) without rewriting a single existing pattern.
_ENV_ASSIGN = re.compile(r'^[A-Za-z_][A-Za-z0-9_]*=')

# --- git global-option bypass fix (2026-08-18, security review) ------------
# `_GIT_OPTS` (top of file) is a 5-form ENUMERATED allowlist inserted between
# `git` and every guarded subcommand in every BLOCK/ALLOW pattern. Any OTHER
# legal git global option — or one of those 5 forms spelled differently —
# breaks the `git`-to-subcommand anchor, so no pattern matches and the op is
# ALLOWED. Measured at HEAD `ba039b5` against the live regexes: `git -p
# reset --hard`, `git --namespace=foo push`, `git --git-dir /tmp/x/.git
# clean -fdx` (space form; only `--git-dir=<d>` was allowlisted), and
# `git -C/tmp/x reset --hard` all bypassed every one of the 16 guarded ops.
#
# Fix is a token DROP in `_normalize_git_segment`, not another `_GIT_OPTS`
# alternative — extending the regex allowlist is what produced the defect.
# Which tokens consume a following (space-separated) value was measured
# directly against `git 2.55.0`'s global-option parsing (`git.c`'s
# `handle_options()`), not assumed from the `git --help` usage synopsis:
# the synopsis is misleading here. `--exec-path` and `--list-cmds` LOOK
# like they take a value but only accept the ATTACHED `=` form — a bare
# `--exec-path` prints the configured exec-path and exits without touching
# further argv, and a bare `--list-cmds` errors "unknown option: --list-cmds"
# — so neither needs (or may have) a space-form value-consumption entry.
# `--super-prefix`, despite existing in git's source, is NOT in this git's
# global-option usage line at all and errors "unknown option" in every
# form tried (bare, `=value`, and space `value`). `-C` and `-c` themselves
# have NO attached form: `-C/tmp/x` and `-cfoo=bar` both error "unknown
# option" (only the space-separated `-C <path>` / `-c <cfg>` form is real);
# those malformed-looking single tokens are simply dropped as opaque flags
# by the generic branch in the walk below, which is safe because git would
# reject them too, so there is nothing valid after them left to consume.
_GIT_GLOBAL_VALUE_OPTS = frozenset((
    '-C', '-c', '--git-dir', '--work-tree', '--namespace',
    '--config-env', '--attr-source',
))


def _normalize_git_segment(seg):
    r"""Return a quote-stripped, absolute-path-normalized rendering of `seg`
    if (and only if) `seg` is a git invocation, else None.

    DELIBERATELY NARROW: normalization runs ONLY when the segment's first
    non-assignment token is a git invocation (`os.path.basename(token) ==
    'git'`, so `/usr/bin/git` also normalizes but `./mygit` does not — no
    basename collision). Every `*_ALLOW` hatch pattern requires `git`
    immediately after the leading `VAR=value` assignments, so a segment
    that isn't a git command to begin with (`rg "git push" docs/`, `gh pr
    create --body "adds git push guard"`) returns None and is evaluated
    EXACTLY as before this pass — measured: normalizing every segment
    unconditionally newly blocked ordinary non-git commands with NO working
    escape hatch, since a false BLOCK on a non-git segment has no *_ALLOW
    pattern that could ever match it.

    Unbalanced quotes (`shlex.split` raising ValueError) also return None,
    falling back to raw-only evaluation rather than raising — this module's
    fail-open-on-internal-error contract applies here too.

    A leading env-assignment VALUE containing whitespace (`FOO="bar baz"
    git ...`) is collapsed to a placeholder (`FOO=_`) before the rejoin
    (2026-08-17 shlex tokenization pass, security-gate fix): `shlex.split`
    correctly parses the quoted value as ONE token, but `' '.join(tokens)`
    then re-renders it as TWO words, which every `*_ALLOW` hatch pattern's
    assignment-tolerance (`([A-Za-z_][A-Za-z0-9_]*=\S+\s+)*`, `\S+` cannot
    span a space) fails to re-match — a genuine, valid hatch use like
    `CAST_RESET_OK=1 FOO="bar baz" git reset --hard` was false-blocking.
    Scoped to indices `< i` (the assignment prefix) ONLY — never `tokens[i:]`,
    where e.g. a `-c gc.pruneExpire=<value>` argument lives and the value IS
    load-bearing for `_GC_CINJECT_BLOCK`/`_GC_CONFIG_WRITE_BLOCK`.

    Global-option tokens between `git` and the subcommand are then DROPPED
    entirely (2026-08-18 global-option bypass fix, security review) — see
    `_GIT_GLOBAL_VALUE_OPTS` below for what was measured and why this is a
    token-drop, not a `_GIT_OPTS` regex extension.
    """
    try:
        tokens = shlex.split(seg)
    except ValueError:
        return None
    if not tokens:
        return None
    i = 0
    while i < len(tokens) and _ENV_ASSIGN.match(tokens[i]):
        i += 1
    if i >= len(tokens) or os.path.basename(tokens[i]) != 'git':
        return None
    tokens[i] = 'git'  # absolute-path normalization: /usr/bin/git -> git
    for k in range(i):
        if re.search(r'\s', tokens[k]):
            name, _sep, _val = tokens[k].partition('=')
            tokens[k] = name + '=_'  # value is never load-bearing for any pattern

    # Walk forward from the subcommand position dropping global-option
    # tokens, so the normalized rendering is always `git <subcommand>
    # <args...>` with zero `_GIT_OPTS` repetitions needed. j never raises:
    # every branch either advances j or the loop condition itself bounds it.
    #
    # `-c` is the one option KEPT rather than dropped (value collapsed the
    # same way the assignment-prefix loop above collapses whitespace):
    # `_GIT_OPTS` already allowlists `-c\s+\S+`, and `-c`'s value is
    # separately load-bearing for `_GC_CINJECT_BLOCK`'s `gc.*Expire=` key
    # lookahead, which only the quote-stripped NORMALIZED view can still
    # see once the value is shell-quoted — measured (mutation-tested by
    # this fix's own test run): `git -c "gc.pruneExpire=now" gc` left
    # literal quote characters in the RAW segment that broke
    # `_GC_CONFIG_KEY`'s match, so dropping `-c` like every other global
    # option silently un-blocked it (caught test 233, pre-existing at HEAD).
    j = i + 1
    kept_tail = []
    while j < len(tokens) and tokens[j].startswith('-'):
        opt, eq, _val = tokens[j].partition('=')
        if opt == '-c' and not eq and j + 1 < len(tokens):
            val = tokens[j + 1]
            if re.search(r'\s', val):
                name, _sep, _v = val.partition('=')
                val = name + '=_'  # value is never load-bearing; only the KEY prefix is
            kept_tail.extend(('-c', val))
            j += 2
        elif eq or opt not in _GIT_GLOBAL_VALUE_OPTS or j + 1 >= len(tokens):
            j += 1  # attached `opt=value`, or a no-value/unrecognized flag: drop it alone
        else:
            j += 2  # separate-token value form (`--git-dir <path>`): drop opt AND its value
    norm = ' '.join(tokens[:i + 1] + kept_tail + tokens[j:])
    return norm if norm != seg else None


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

# `git config edit` / `git config --edit` / `git config -e` opens $EDITOR
# directly on .git/config — a hole in the SAME mechanism as the write block
# above, since an interactive edit can set gc.pruneExpire=now with NO
# key/value token ever appearing on the command line for that block to key
# on (2026-08-17 shlex tokenization pass, same-day follow-up). Gated by the
# SAME hatch (CAST_GC_OK=1) — no new hatch name.
#
# The `edit` bare-token form is a real subcommand only in SUBCOMMAND
# POSITION (`git config edit`, `git config --global edit`) — git ≥ 2.46
# accepts `get|set|unset|list|edit`. It is deliberately anchored there via
# `_GC_CONFIG_SCOPE_FLAGS` (an enumerated, valueless allowlist of scope
# flags git accepts before the subcommand) rather than a generic `--\S+`
# skip, which would swallow value-taking options and re-block reads like
# `git config --get-regexp edit` (2026-08-17 security-gate fix: that read,
# plus `git config user.email "edit@example.com"` and `git config alias.e
# "edit"`, previously false-blocked because `edit` was matched anywhere on
# the line). The `--edit`/`-e` FLAGS remain matched anywhere on the line
# (unambiguous in any position) via the second alternative below. A value
# token literally equal to `-e`/`--edit`/`edit` elsewhere on the line still
# fails closed — this pass narrows false blocks, it does not narrow true
# ones.
# MEASURED against git 2.55.0 with an editor sentinel (2026-08-17 shlex pass),
# because the reasoning and the behaviour disagreed: the scope-flag run below is
# DEFENCE-IN-DEPTH, not a live route. Only `edit` as the FIRST argument is the
# edit subcommand — `git config edit` opens the editor, while `git config
# --global edit`, `--local edit`, `--show-origin edit` and `-z edit` all parse
# `edit` as a KEY NAME and die with "key does not contain a section: edit",
# opening nothing. So no omission from this list can fail OPEN; the list can
# only over-block forms git itself rejects. It is kept anyway because git's
# subcommand syntax is new (2.46) and a later version accepting the legacy
# flags-then-subcommand order would otherwise reopen the hole silently.
# The `--edit`/`-e` FLAGS are the real scoped route and DO open the editor
# (`git config --global -e` measured), which is why they match anywhere.
_GC_CONFIG_SCOPE_FLAGS = (
    r'(?:\s+(?:--global|--local|--system|--worktree|--show-origin|--show-scope'
    r'|--includes|--no-includes|-z|--null))*'
)
_GC_CONFIG_EDIT_BLOCK = re.compile(
    r'(^|\s)git' + _GIT_OPTS + r'\s+config\b'
    r'(?:' + _GC_CONFIG_SCOPE_FLAGS + r'\s+edit\b'
    r'|(?=.*(?:^|\s)(?:--edit|-e)\b))'
)

# --- git rm force block -------------------------------------------------------
# 2026-08-17 remaining-destructive-ops pass: measured that `git rm` with a
# force flag (-f, --force, or any single-dash cluster containing f: -rf, -fr,
# -rfq) DESTROYS an uncommitted working-tree edit — git's normal refusal
# ("error: the following file has local modifications") is bypassed by force.
# Reuses `_FORCE_FLAG_LOOKAHEAD` (defined with the checkout block above) for
# flag detection, same cluster-aware/single-dash-anchored reasoning.
# Measured SAFE, stays allowed even WITH a force flag: `git rm --cached
# f.txt` and `git rm -r --cached sub` — `--cached` only touches the index;
# the worktree file (and any uncommitted edit on it) is left untouched
# (verified empirically). The pattern excludes any segment containing
# `--cached` via a negative lookahead.
# 2026-08-17 security-review fix: the `--cached` exemption previously used a
# bare `\b` lookahead (`--cached\b`). `\b` fires on ANY word→non-word
# transition, so a pathspec that merely STARTS WITH `--cached` (e.g. a file
# named `--cached-evil.txt`) satisfies `\b` right after the `d` and disables
# the entire force-block, even though `--cached` is not a real flag token
# there — same defect class already fixed for `_PRUNE_BLOCK`
# (`prune(?![\w-])`) and `_FILTER_BRANCH_BLOCK` (`filter-branch(?![\w-])`):
# a plain `\b` still matches inside a longer hyphenated token. Fixed by
# anchoring the exemption to a real shell token — `--cached` must be
# followed by whitespace or end-of-string, not merely a non-word char — via
# `(?:^|\s)--cached(?:\s|$)` instead of a bare `\b` lookahead.
# Residual limitation (cannot be closed by a command-line regex scanner): a
# file literally named `--cached`, passed after a `--` separator
# (`git rm -f -- --cached`), is indistinguishable from the real flag token
# and is still exempted. This is a known, accepted gap, not an oversight.
# Measured: `-n`/`--dry-run` DOES save the file — `git rm -nf <modified>`
# printed what it would remove but left the file on disk untouched (unlike
# `_GC_PRUNE_VALUE`'s "no exemption" cases, this one genuinely is a no-op).
# Exempted the same way `_PRUNE_BLOCK` exempts dry runs, via `_CLEAN_DRY_RUN`.
# Tolerates extra VAR=value assignments between CAST_GIT_RM_OK=1 and git.
_GIT_RM_ALLOW = re.compile(
    r'(^|&&\s*)CAST_GIT_RM_OK=1\s+([A-Za-z_][A-Za-z0-9_]*=\S+\s+)*git' + _GIT_OPTS + r'\s+rm\b'
)
_GIT_RM_BLOCK = re.compile(
    r'(^|\s)git' + _GIT_OPTS + r'\s+rm\b'
    r'(?!.*(?:^|\s)--cached(?:\s|$))'
    r'(?=.*' + _FORCE_FLAG_LOOKAHEAD + r')'
    r'(?!.*' + _CLEAN_DRY_RUN + r')'
)

# --- git branch force-delete block --------------------------------------------
# 2026-08-17 remaining-destructive-ops pass: measured that `git branch -D
# <branch>`, `git branch --delete --force <branch>`, and clustered `git
# branch -qD <branch>` all deleted an UNMERGED branch ref AND its branch
# reflog. The commit object itself survived in the HEAD reflog and survived
# `gc --prune=now`, so it remains recoverable for the reflog retention
# window — NOT unrecoverable; the message below says exactly that, no more.
# Measured SAFE, stays allowed: `git branch -d <branch>` on an unmerged
# branch (git refuses, rc=1), `git branch -m <new>` (rename), and the
# read-only forms `git branch` (bare), `-a`, `-v`, `-vv`, `-r`, `--list`.
# Measured: `git branch -d x --force` DOES force-delete (force overrides the
# safe `-d` refusal the same way it overrides `-D`'s absent one).
# `_BRANCH_D_LOOKAHEAD` is cluster-aware and single-dash-anchored the same
# way as `_FORCE_FLAG_LOOKAHEAD`, built for uppercase `D` instead of `f` —
# it cannot match inside `--delete` (double-dash token, no uppercase D).
#
# 2026-08-18 follow-up (global-option bypass pass, same day): `git branch -M
# old new` and `git branch -f main HEAD~3` were both still ALLOWED — a gap
# the force-delete block above never covered. Measured in a throwaway repo:
#   - `git branch -M old new`, when `new` already exists, OVERWRITES `new`'s
#     ref with `old`'s tip. `new`'s OWN reflog does NOT carry the
#     destination's prior history forward (only the renamed SOURCE branch's
#     reflog survives the rename) — the victim's old tip becomes a
#     dangling, unreachable commit object (confirmed via `git fsck
#     --unreachable --no-reflogs`), recoverable only by a dangling-blob
#     hunt, same class as `git reset --hard`. Lowercase `git branch -m old
#     new` (no force) correctly REFUSES ("fatal: a branch named 'new'
#     already exists", rc=128) — `-M` really is a distinct destructive
#     flag, not just `-m` typed differently; per `git branch --help`, `-M`
#     is literally `-m -f` combined.
#   - `git branch -f <branch> <start-point>`, when `<branch>` already
#     exists, force-moves it. Unlike `-M`'s victim, THIS old tip IS
#     reflog-recoverable (`git rev-parse <branch>@{1}` returned the exact
#     pre-force commit on an isolated unique-tip branch) — same
#     recoverability class as `-D`, blocked anyway for the same
#     deny-by-default reason `-D` is.
#   - Per `git branch --help`, `-f`/`--force` means the same thing
#     ("allow overwriting an existing target") whether paired with no verb
#     (create/move), `-d`/`--delete` (force-delete, already covered above),
#     `-m`/`--move`, or `-c`/`--copy` — there is no git-documented SAFE
#     meaning of `--force` on `branch`. So instead of adding another paired
#     lookahead (mirroring the OLD `-d ... --force` shape), the block
#     condition below is simplified to: an uppercase-D cluster, OR an
#     uppercase-M cluster, OR a bare force flag ANYWHERE on the line. This
#     is a strict superset of the two old paired alternatives (both already
#     REQUIRED `_FORCE_FLAG_LOOKAHEAD` to match too, so nothing previously
#     blocked stops being blocked) — and it additionally closes `-M`,
#     `-c -f` (force-copy onto an existing branch, same clobber class as
#     `-M`, not in the reported gap but closed for free by the same fix),
#     and bare `-f`/`--force` with no `-d`/`-m`/`-c` verb at all.
_BRANCH_D_LOOKAHEAD = r'(?:^|\s)-[a-zA-Z]*D[a-zA-Z]*\b'
_BRANCH_M_LOOKAHEAD = r'(?:^|\s)-[a-zA-Z]*M[a-zA-Z]*\b'
_BRANCH_ALLOW = re.compile(
    r'(^|&&\s*)CAST_BRANCH_OK=1\s+([A-Za-z_][A-Za-z0-9_]*=\S+\s+)*git' + _GIT_OPTS + r'\s+branch\b'
)
_BRANCH_BLOCK = re.compile(
    r'(^|\s)git' + _GIT_OPTS + r'\s+branch\b'
    r'(?=.*(?:'
    + _BRANCH_D_LOOKAHEAD
    + r'|' + _BRANCH_M_LOOKAHEAD
    + r'|' + _FORCE_FLAG_LOOKAHEAD
    + r'))'
)

# --- git worktree remove force block -------------------------------------------
# 2026-08-17 remaining-destructive-ops pass: measured that `git worktree
# remove -f <path>` / `--force` deleted a worktree containing uncommitted
# edits. Measured SAFE, stays allowed: bare `git worktree remove <path>`
# (git refuses on a dirty tree AND on untracked-only content, rc=128),
# `git worktree add -f` (force there is not destructive — the pattern
# anchors on the literal `worktree\s+remove` sequence, so `add -f` can never
# match), `git worktree list`, `git worktree prune`.
_WORKTREE_ALLOW = re.compile(
    r'(^|&&\s*)CAST_WORKTREE_OK=1\s+([A-Za-z_][A-Za-z0-9_]*=\S+\s+)*git' + _GIT_OPTS + r'\s+worktree\s+remove\b'
)
_WORKTREE_BLOCK = re.compile(
    r'(^|\s)git' + _GIT_OPTS + r'\s+worktree\s+remove\b(?=.*' + _FORCE_FLAG_LOOKAHEAD + r')'
)

# --- git update-ref delete block ------------------------------------------------
# 2026-08-17 remaining-destructive-ops pass: measured that `git update-ref -d
# refs/heads/feature` deleted the ref AND its reflog. Measured that
# `git update-ref --delete` is NOT a valid flag (rc=129 usage error) — only
# `-d` works; do not "fix" its absence, there is nothing to fix. Measured
# that `printf 'delete refs/heads/feature\n' | git update-ref --stdin`
# deleted the ref via a payload that arrives on STDIN, invisible to a
# command-line scanner — so `--stdin` is ALSO blocked under the same hatch,
# deny-by-default. This deliberately also blocks non-destructive `create`/
# `update` stdin payloads, because the scanner has no way to see which verb
# the stdin stream carries. Measured SAFE, stays allowed: `git update-ref
# refs/heads/tmp HEAD` (create/update via command-line args, no `-d`/
# `--stdin`).
_UPDATE_REF_ALLOW = re.compile(
    r'(^|&&\s*)CAST_UPDATE_REF_OK=1\s+([A-Za-z_][A-Za-z0-9_]*=\S+\s+)*git' + _GIT_OPTS + r'\s+update-ref\b'
)
_UPDATE_REF_BLOCK = re.compile(
    r'(^|\s)git' + _GIT_OPTS + r'\s+update-ref\b'
    r'(?=.*(?:(?:^|\s)-d\b|(?:^|\s)--stdin\b))'
)

# 2026-08-18 follow-up (global-option bypass pass, same day): `git
# update-ref refs/heads/main HEAD~3`, when `refs/heads/main` already
# exists, was still ALLOWED — the block above only catches `-d`/`--stdin`.
# Re-measured the "Measured SAFE" claim above against an EXISTING target:
# creating `refs/heads/tmp` (didn't exist) really is harmless, that part of
# the comment still holds. But overwriting an EXISTING ref moves it exactly
# like `git branch -f` above (measured: reflog-recoverable via `<ref>@{1}`,
# dangling per `git fsck --unreachable --no-reflogs` beforehand — same
# class blocked above for `branch -f`). Unlike every other block in this
# module, "create" vs "overwrite" is NOT decidable from the command line
# alone — the `<ref>` argument is spelled identically either way — so this
# needs a small stateful check, the same shape as
# `_checkout_bare_path_blocks`'s pathspec-existence check, adapted from a
# filesystem check to `git rev-parse --verify --quiet <ref>` (a read-only
# query; mirrors `_repo_toplevel`'s subprocess style/timeout). Chose the
# clean separation over blocking unconditionally, since blocking
# unconditionally would regress the still-true, still-tested "creating a
# new ref is harmless" case above.
#
# KNOWN LIMITATION (measured, same spirit as `_checkout_bare_path_blocks`'s
# own KNOWN LIMITATION note): `update-ref` resolves a BARE, non-fully-
# qualified ref argument (`git update-ref main HEAD~3`, no `refs/heads/`
# prefix) as a LITERAL path relative to `$GIT_DIR` (creates `.git/main`, a
# pseudo-ref entirely separate from the real `refs/heads/main` branch —
# confirmed: `git branch --list` never sees it). `git rev-parse --verify`
# instead applies git's normal DWIM revision resolution, which tries
# `refs/heads/<name>` (among other namespaces) for a bare name. So for a
# BARE argument only, this check can say "exists" (via DWIM matching the
# real branch) when the literal `update-ref` target does not yet exist,
# over-blocking a call that would have been safe. This is the SAFE
# direction of error (a false BLOCK, never a false ALLOW) and only affects
# non-fully-qualified ref arguments — a fully-qualified `refs/heads/<name>`
# argument (the form in every example above, and the only form git itself
# recommends for `update-ref`) resolves identically both ways.
_UPDATE_REF_CMD = re.compile(r'(^|\s)git' + _GIT_OPTS + r'\s+update-ref\b(?P<rest>.*)$')


def _update_ref_overwrites_existing(seg: str) -> bool:
    """True if `seg` is a `git update-ref <ref> <value> [<oldvalue>]` (no
    `-d`/`--stdin` — those are already caught by `_UPDATE_REF_BLOCK`
    directly) whose target `<ref>` ALREADY EXISTS, i.e. this call
    overwrites it rather than creating a new one. See the 2026-08-18
    comment above `_UPDATE_REF_CMD` for what was measured, why this needs
    a stateful check instead of a static regex, and its known limitation.

    Bails out (returns False) immediately if the first token after
    `update-ref` starts with `-` — that's `-d`/`--stdin`/an unrecognized
    flag, not a ref name; `_UPDATE_REF_BLOCK` (or nothing, if unrecognized)
    is the correct handler for those, not this function.

    FAILS OPEN: any subprocess error, timeout, or non-git-repo cwd (a
    nonzero `rev-parse --verify` return also covers "not a git repo" and
    "not a valid ref", both correctly treated as "doesn't exist" → allow)
    returns False — matches this module's global fail-open-on-internal-
    error contract and mirrors `_checkout_bare_path_blocks`'s try/except
    shape. Reuses `_CHECKOUT_CDIR` (a generic `-C\\s+(\\S+)` pattern despite
    the name) for the same cwd-relative `-C <dir>` extraction and the same
    documented quoted-path limitation as `_checkout_bare_path_blocks`.
    """
    try:
        m = _UPDATE_REF_CMD.search(seg)
        if not m:
            return False
        rest = m.group('rest').strip()
        if not rest:
            return False
        try:
            tokens = shlex.split(rest)
        except ValueError:
            return False
        if not tokens or tokens[0].startswith('-'):
            return False
        ref = tokens[0]
        cdir_m = _CHECKOUT_CDIR.search(seg)
        cmd = ['git']
        if cdir_m:
            cmd += ['-C', cdir_m.group(1)]
        cmd += ['rev-parse', '--verify', '--quiet', ref]
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=5)
        return r.returncode == 0
    except Exception:
        return False

# --- git filter-branch block -----------------------------------------------------
# 2026-08-17 remaining-destructive-ops pass: measured that `git filter-branch
# -f --msg-filter ... HEAD` rewrote history (HEAD sha changed). All forms
# block — filter-branch has no non-destructive read-only mode. Uses a
# `(?![\w-])` token-boundary guard after `filter-branch` for the same reason
# `_PRUNE_BLOCK` does: a plain `\b` still matches inside a longer hyphenated
# token (the `e`->`-` transition IS a word/non-word boundary), so the
# negative lookahead rejects anything where `filter-branch` is immediately
# followed by a word char or hyphen.
_FILTER_BRANCH_ALLOW = re.compile(
    r'(^|&&\s*)CAST_FILTER_BRANCH_OK=1\s+([A-Za-z_][A-Za-z0-9_]*=\S+\s+)*git' + _GIT_OPTS + r'\s+filter-branch(?![\w-])'
)
_FILTER_BRANCH_BLOCK = re.compile(
    r'(^|\s)git' + _GIT_OPTS + r'\s+filter-branch(?![\w-])'
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
_GC_CONFIG_EDIT_MSG = (
    "**[CAST]** `git config edit`/`--edit`/`-e` blocked — an interactive "
    "editor session on `.git/config` can set `gc.pruneExpire` / "
    "`gc.reflogExpire` / `gc.reflogExpireUnreachable` to `now` with NO "
    "key/value token ever appearing on the command line for the "
    "`git config` write block to key on — same config-layer bypass family, "
    "closing the last route into it. If you genuinely need to edit git "
    "config interactively, use `CAST_GC_OK=1 git config --edit` (document "
    "why)."
)

_GIT_RM_MSG = (
    "**[CAST]** Raw `git rm` with a force flag (`-f`/`--force`/clustered "
    "`-rf`/`-fr`/`-rfq`) blocked — it deletes an uncommitted working-tree "
    "edit that git would otherwise refuse to remove. `git rm --cached "
    "<path>` (index-only, worktree untouched) and `-n`/`--dry-run` are "
    "unaffected. If you genuinely need to force-remove a modified file, "
    "use `CAST_GIT_RM_OK=1 git rm -f ...` (document why)."
)
_BRANCH_MSG = (
    "**[CAST]** Raw `git branch` with `-D` / `-M` / `-f`/`--force` (in any "
    "combination, including `-c -f`) blocked. `-D` (or `-d`/`--delete` "
    "combined with force) force-deletes an unmerged branch ref and its own "
    "reflog — recoverable only within the HEAD reflog's retention window. "
    "`-M` (or `-c`/`--copy` combined with force) force-overwrites an "
    "existing branch's tip — a dangling-blob hunt to recover, NOT "
    "reflog-recoverable. Bare `-f`/`--force` force-moves an existing "
    "branch pointer — reflog-recoverable via `<branch>@{1}`. Plain `git "
    "branch -d <branch>` (safe refusal on unmerged), `git branch -m <new>` "
    "(safe refusal if `<new>` already exists), and read-only forms "
    "(`branch`, `-a`, `-v`, `-vv`, `-r`, `--list`) are unaffected. If you "
    "genuinely need to force this, use `CAST_BRANCH_OK=1 git branch -D "
    "...` (document why)."
)
_WORKTREE_MSG = (
    "**[CAST]** Raw `git worktree remove -f`/`--force` blocked — it deletes "
    "a worktree even when it contains uncommitted edits. Bare `git worktree "
    "remove <path>` (git refuses on a dirty tree), `git worktree add -f`, "
    "`list`, and `prune` are unaffected. If you genuinely need to "
    "force-remove a worktree, use `CAST_WORKTREE_OK=1 git worktree remove "
    "-f ...` (document why)."
)
_UPDATE_REF_MSG = (
    "**[CAST]** Raw `git update-ref -d`/`--stdin`, or a `git update-ref "
    "<ref> <value>` whose `<ref>` already exists, blocked — `-d` deletes a "
    "ref and its reflog; `--stdin` accepts a delete payload on stdin that "
    "is invisible to this scanner, so it is blocked deny-by-default even "
    "though it can also carry non-destructive `create`/`update` payloads; "
    "overwriting an existing ref moves it, same reflog-recoverable class "
    "as `git branch -f`. `git update-ref <ref> <value>` where `<ref>` does "
    "NOT already exist (create) is unaffected. If you genuinely need this, "
    "use `CAST_UPDATE_REF_OK=1 git update-ref -d ...` (document why)."
)
_FILTER_BRANCH_MSG = (
    "**[CAST]** Raw `git filter-branch` blocked — it rewrites history "
    "(changes commit SHAs), including the current HEAD. There is no "
    "non-destructive form. If you genuinely need to rewrite history, use "
    "`CAST_FILTER_BRANCH_OK=1 git filter-branch ...` (document why)."
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
    avoids spurious hits from agent names that merely contain required_agent.

    2026-08-18 fix (same defect class as the commit approval gate, fixed this
    session in cast-events.sh — that file untouched here): the dispatch-naming
    rule (`working-conventions.md` → Dispatch-Prompt Contract) requires roster
    dispatches be named ``<agent-type>__<label>`` for attribution, so a
    ``code-reviewer__fix-x`` run writes ``code-reviewer__fix-x-<ts>.json`` —
    which does NOT start with ``code-reviewer-``. A required-agent policy gate
    then sees a review that genuinely ran as never-having-run and blocks.
    Fixed by accepting EITHER ``<agent>-`` OR ``<agent>__`` as the prefix,
    still anchored to a real separator (not a bare ``required_agent`` prefix)
    so ``code-reviewer2-...`` cannot satisfy a ``code-reviewer`` requirement —
    that anchoring is the whole reason the dispatch convention uses `__` in
    the first place, and this fix must not loosen it.

    Reads the structured ``status`` field (not a substring scan) and fails CLOSED
    (keeps the block) on any read/parse error. Mirrors orchestrate-dispatch.py
    cmd_recent_status.
    """
    if not os.path.isdir(agent_status_dir):
        return False
    prefix_dash = required_agent + '-'
    prefix_dunder = required_agent + '__'
    newest_path = None
    newest_mtime = -1.0
    for fname in os.listdir(agent_status_dir):
        if not (fname.startswith(prefix_dash) or fname.startswith(prefix_dunder)):
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


# 2026-08-26 latency-bound fix: `_record_hatch` is synchronous on the
# PreToolUse hot path, spawned once per hatched segment with (before this
# fix) no cap on segment count and a 5s subprocess timeout — a security
# review measured 5.011s for one hung `cast_ack.py` spawn and 15.065s for
# three chained, against a HEALTHY-path baseline of 0.033s median / 0.040s
# max over 5 runs. Two-part fix: the timeout drops to 2s (still ~60x the
# measured healthy call), and this caps how many `_record_hatch` calls
# `_git_evaluate_impl` will make per invocation, bounding worst case to
# `_MAX_HATCH_RECORDS_PER_COMMAND` x 2s for the per-hatch calls, PLUS one
# more `_record_hatch` spawn (2026-08-27 I-3b Unit 1b-i) for the
# `CAST_HATCH_RECORD_CAP` sentinel that `_git_evaluate`'s `finally` clause
# emits whenever this cap suppressed at least one record — so the true
# worst case is `(_MAX_HATCH_RECORDS_PER_COMMAND + 1) x 2s` instead of
# unbounded x 5s. The counter lives in `_git_evaluate_impl`, not here — see
# its per-segment loop — so this cap never touches the ALLOW/BLOCK verdict,
# only whether the audit-record subprocess gets spawned.
_MAX_HATCH_RECORDS_PER_COMMAND = 8


def _record_hatch(variable: str, value: str, git_op: str) -> None:
    """Record an escape-hatch use into cast.db's ack_events table (CAST v10
    I-3b). Best-effort, run as an EXTERNAL subprocess rather than an
    in-process `from cast_ack import record_ack` — mirrors
    cast-events.sh:576-596's `_record_hatch_ack()`: an in-process import
    puts cast_ack.py on a CWD-derived sys.path where a planted same-named
    module could call sys.exit() at import time and kill this entire guard
    process (`except Exception` does not catch SystemExit).

    `git_op` identifies which guarded operation triggered the hatch (e.g.
    'commit', 'push') for callers/logging context only — ack_events has no
    git_op column (scripts/migrations/034_ack_events.sql), so it is not
    part of the recorded payload.

    `capture_output=True` is required, not cosmetic: cast_ack.py's CLI
    prints a stderr nudge for bare/reasonless values (e.g. "=1"), and this
    function must never print to stdout/stderr regardless of value content.

    LATENCY (2026-08-26 fix, security review; updated 2026-08-27 I-3b Unit
    1b-i): this call is synchronous on the PreToolUse hot path. Measured: a
    healthy `cast_ack.py` spawn is 0.033s median / 0.040s max over 5 runs; a
    hung spawn cost 5.011s at the prior 5s timeout (15.065s for three
    chained). `timeout` here is now 2s (still ~60x the healthy median,
    ample headroom without the old worst-case cost) and `_git_evaluate_impl`
    additionally caps total per-hatch calls to this function at
    `_MAX_HATCH_RECORDS_PER_COMMAND` (8) per command. `_git_evaluate`'s
    `finally` clause makes ONE additional call to this function for the
    `CAST_HATCH_RECORD_CAP` sentinel whenever the cap suppressed at least
    one record, so the worst case for one guard invocation is bounded at
    `(_MAX_HATCH_RECORDS_PER_COMMAND + 1) x 2s = 18s` rather than unbounded
    x 5s.

    Must never raise and must never change the guard's exit code.
    """
    try:
        scripts_dir = os.environ.get('CAST_SCRIPTS_DIR', os.path.expanduser('~/.claude/scripts'))
        subprocess.run(
            ['python3', os.path.join(scripts_dir, 'cast_ack.py'),
             variable, '--value', value, '--script', 'cast-git-guard.py'],
            timeout=2,
            capture_output=True,
        )
    except Exception:
        pass


def _hatch_value(segment: str, variable: str) -> str:
    """Return the literal value assigned to `variable=` in the leading
    VAR=value assignment prefix of `segment` (i.e. before the `git`
    invocation), or '' if `variable` is not assigned there.

    Uses shlex.split so a quoted, spaced value (`VAR="a b c"`) survives as
    ONE token (`VAR=a b c`) instead of being split on internal whitespace —
    see the module's 2026-08-17 shlex tokenization note above. shlex.split
    raises ValueError on unbalanced quotes; this is NOT treated as "no value
    found" (2026-08-26 fix) — a quoting error LATER in the command (e.g. an
    unbalanced quote inside a commit message) has nothing to do with the
    LEADING hatch assignment, and the relevant `*_ALLOW` regex has already
    matched the raw segment and honoured the hatch by the time this is
    called. Silently returning '' here would drop the audit row for a
    bypass that DID happen — a plain whitespace split is used as a fallback
    instead, recovering the ordinary unquoted form (`VAR=1 git ...`); a
    hatch value that itself contains unbalanced-quote-and-whitespace stays
    unrecoverable, which is a strict improvement on always returning ''.
    Never raises.
    """
    try:
        tokens = shlex.split(segment)
    except ValueError:
        tokens = segment.split()
    prefix = f'{variable}='
    for token in tokens:
        if not _ENV_ASSIGN.match(token):
            break
        if token.startswith(prefix):
            return token[len(prefix):]
    return ''


def _scannable_segments(command: str):
    """Yield shell-evaluable segments from EVERY line of `command`, not just
    line 1 (2026-08-24 SEC-1 fix — see the module SECURITY note above for
    why widening this to a multi-line scan is safe: the 2026-08-17
    per-segment fix already scopes a hatch to its own segment, so a hatch on
    one line structurally cannot reach a destructive op on a different
    line).

    This function performs EXACTLY two operations and nothing else:
      1. Join backslash line-continuations across ALL lines, counting
         TRAILING backslashes on each line so only an ODD count joins
         (SEC-1 C2 fix) — an EVEN count is a paired-off literal escape, not
         a continuation, and is left unjoined. A single trailing backslash
         still joins `git \\` / `reset --hard` into one logical line, and
         an odd count of N backslashes collapses to (N-1)/2 literal
         backslashes once the continuation itself is consumed (2026-08-24
         correctness fix — the prior version left N-1 residual backslashes
         for N >= 3).
      2. Split each resulting joined line into shell segments on `;`,
         `&&`, `||`, `|` — the same regex `_git_evaluate` always used for
         line 1 — and yield each segment.

    COMMENTS ARE NOT SKIPPED (2026-08-24 SEC-1 D2 removal, superseding the
    D1 fix this docstring previously described — see the module KNOWN
    LIMITATIONS docstring for the full incident history with worked
    examples). This function used to classify and drop leading-`#` comment
    lines before the scan. Both possible orderings relative to
    continuation-joining were tried this session — join-then-drop, and
    drop-then-join (D1, this function's immediately prior state) — and
    BOTH produced a confirmed, fail-open bypass, in opposite directions,
    verified against real bash with a `git` PATH-shim: join-then-drop let a
    real, self-terminating comment's trailing backslash wrongly absorb a
    following REAL command into the text that got dropped as "a comment"
    (`# note \\` / `git stash`); drop-then-join let a following line's
    leading `#` be classified as a real comment-start in isolation, when a
    preceding line's continuation would have fused it mid-word in real
    bash, where it is NOT a comment-start at all (`echo foo\\` /
    `#bar; git reset --hard`). Root cause: bash decides comment-hood
    WORD-WISE, during lexing, interleaved with continuation removal — no
    line-based ordering of "join" and "drop" can reproduce that; only a
    real shell lexer can, which is exactly the kind of hand-rolled parser
    that already failed twice for heredocs (below). So comment suppression
    is deleted here too, rather than re-ordered a third time. Cost, stated
    plainly rather than as a claim that the multiline surface is now
    closed: a comment mentioning a guarded git command — a whole comment
    line (`# git push`) or comment text fused by a continuation into an
    adjacent line — is scanned like any other text and BLOCKS, needing
    that op's own `CAST_*_OK=1` hatch on that line/segment to proceed.

    2026-08-24 SEC-1 heredoc-suppression REMOVAL (design decision, not a
    bug fix — see the module KNOWN LIMITATIONS docstring for the full
    incident history): this function used to also drop heredoc BODIES via
    a hand-rolled quote/comment-aware detector (a heredoc-start regex plus a
    quote/comment-tracking wrapper), on the theory that a heredoc body is
    inert data the shell never executes as a command. That parser produced TWO CRITICAL
    bypasses across three review rounds — closing the first (a herestring
    `<<<`, a `<<` inside quotes, a `<<` after a trailing comment) only
    exposed the second and fatal one: the parser's quote-parity scan does
    not understand backslash-escaped quotes, so a line like
    `echo "text \" <<EOF"` desyncs its tracked quote state and it
    misdetects a real destructive command on a following line as heredoc
    body, silently dropping it from the scan while bash executes it for
    real. A hand-rolled shell quote parser is not a tractable way to draw
    this line safely, so it is DELETED rather than patched a third time —
    removing the parser removes the whole misdetection class, since there
    is no longer any special-casing left to fool. A heredoc body is now
    scanned exactly like any other line: prose (e.g. documentation written
    via `cat > file <<EOF`) that happens to mention a guarded git command
    will correctly false-BLOCK, and needs its own per-segment
    `CAST_*_OK=1` hatch to write. That trade is deliberate: a rare,
    hatchable false positive beats a parser that has already produced two
    silent, unbounded bypasses.
    """
    # Step 1: join backslash line-continuations across ALL lines (no
    # comment classification — see the docstring above). Only an ODD
    # trailing-backslash count is a real continuation (SEC-1 C2); an odd
    # count of N backslashes leaves (N-1)/2 literal backslashes behind once
    # the continuation itself is consumed, matching bash's own escaped-pair
    # semantics (2026-08-24 correctness fix).
    joined_lines = []
    buf = ''
    for line in command.split('\n'):
        buf += line
        trailing = 0
        idx = len(buf) - 1
        while idx >= 0 and buf[idx] == '\\':
            trailing += 1
            idx -= 1
        if trailing % 2 == 1:
            buf = buf[:len(buf) - trailing] + ('\\' * ((trailing - 1) // 2))
            continue
        joined_lines.append(buf)
        buf = ''
    if buf:
        joined_lines.append(buf)

    # Step 2: split each joined line into shell segments.
    for line in joined_lines:
        for seg in re.split(r';|&&|\|\||\|', line):
            yield seg


def _git_evaluate(command: str):
    """Thin wrapper around `_git_evaluate_impl()` (2026-08-27 I-3b Unit
    1b-i). Kept as the stable public entry point — same name, same
    `(command: str)` signature, same `(exit_code, message_or_None)` return
    contract — because it is imported and called directly as a module by
    tests and by probes; renaming it or changing its return shape breaks
    them.

    The ONLY thing this wrapper adds over calling the impl directly is a
    `finally` clause that emits exactly one `CAST_HATCH_RECORD_CAP`
    sentinel `ack_events` row (via `_record_hatch`) if `_git_evaluate_impl`
    suppressed one or more per-hatch records against
    `_MAX_HATCH_RECORDS_PER_COMMAND`. `finally` fires on every exit path —
    an ALLOW return, a BLOCK return, or an unexpected exception — which
    matters because `_git_evaluate_impl` returns EARLY on the first BLOCK
    verdict in its per-segment loop: a suppression counter tallied only
    after the loop completes would be lost whenever a block follows a
    suppression later in the same command. The sentinel call itself is
    wrapped in its own try/except so it can never raise and never change
    the verdict computed by `_git_evaluate_impl` — same contract as
    `_record_hatch` itself.
    """
    suppressed_counter = [0]
    try:
        return _git_evaluate_impl(command, suppressed_counter)
    finally:
        if suppressed_counter[0] > 0:
            try:
                _record_hatch(
                    'CAST_HATCH_RECORD_CAP',
                    f'{suppressed_counter[0]} hatch record(s) suppressed '
                    f'(cap={_MAX_HATCH_RECORDS_PER_COMMAND})',
                    'cap',
                )
            except Exception:
                pass


def _git_evaluate_impl(command: str, suppressed_counter):
    """Evaluate a Bash command for git commit/push/stash/reset/clean/
    checkout/restore/switch. Every line is scanned (2026-08-24 SEC-1 fix),
    not just the first — see `_scannable_segments()` for how lines are
    joined/filtered before the per-line segment split below.

    `suppressed_counter` is a 1-element list used as an out-parameter
    (2026-08-27 I-3b Unit 1b-i): `_git_evaluate`, the caller, needs the
    suppressed-hatch-record count even when this function returns EARLY on
    a BLOCK verdict, so the count can't simply be a local returned at the
    end of the function. `suppressed_counter[0]` is incremented once per
    hatch use that exceeded `_MAX_HATCH_RECORDS_PER_COMMAND`; see the
    `hatch_record_count` paragraph below.

    A hatch on one line/segment still cannot unblock a destructive op on a
    DIFFERENT line/segment — that guarantee comes from PER-SEGMENT
    evaluation (below), not from limiting how much of the command gets
    scanned. Returns (exit_code, message_or_None).

    Evaluated PER SHELL SEGMENT (2026-08-17 same-op fix, security review),
    using `_scannable_segments()` to split every surviving line on `;`,
    `&&`, `||`, and `|`. This mirrors real shell semantics: `VAR=1 cmd`
    scopes VAR to that one command, not to everything chained after it.
    Per-line (not per-segment) evaluation let a hatch attached to a
    HARMLESS invocation of an op unlock a DESTRUCTIVE invocation of the
    *same* op later on the line — e.g. `CAST_RESET_OK=1 git reset --soft &&
    git reset --hard` was allowed, because the line-wide *_ALLOW.search()
    doesn't care which `git reset` it matched against. Verified
    pre-existing (not introduced by the reset/clean/checkout/restore
    additions) even for commit/push: at HEAD, `CAST_COMMIT_AGENT=1 git
    commit --dry-run && git commit -m x` was allowed. `seg.strip()` is
    load-bearing: the *_ALLOW patterns anchor a hatch to the START of a
    segment (`^`); an un-stripped leading space after splitting on
    `&&`/`;` would make a legitimate per-segment hatch like
    `CAST_RESET_OK=1 git reset --hard && CAST_CLEAN_OK=1 git clean -fdx`
    wrongly block on its second segment.

    Each op is ALSO evaluated independently within a segment (2026-08-17
    short-circuit fix): a matched *_ALLOW suppresses ONLY its own op's block
    and does not skip the other ops' BLOCK checks in the same segment.

    Net effect: a combined-prefix hatch (`CAST_RESET_OK=1 CAST_CLEAN_OK=1
    git reset --hard && git clean -fdx`) still BLOCKS — segment 2 carries no
    hatch of its own — so "each destructive git command needs its OWN hatch
    immediately before it" holds for same-op chains too, not just cross-op
    chains, and now holds ACROSS LINES too: `git reset --hard` on line 1
    followed by `CAST_CLEAN_OK=1 git clean -fdx` on line 2 still blocks
    line 1.

    `hatch_record_count` (2026-08-26 latency-bound fix) caps how many
    `_record_hatch()` audit-record subprocesses this invocation will spawn
    at `_MAX_HATCH_RECORDS_PER_COMMAND` — see `_record_hatch`'s docstring
    for the measured latency this bounds. Once the cap is reached, further
    hatch uses in the SAME command are NOT individually recorded — but they
    are NOT silent (2026-08-27 I-3b Unit 1b-i fix): `_git_evaluate`'s
    `finally` clause emits ONE `CAST_HATCH_RECORD_CAP` sentinel `ack_events`
    row naming the suppressed count, so an absent per-hatch row is never
    ambiguous with "no hatch was used." This ONLY affects whether the
    per-hatch audit-record subprocess gets spawned, never the ALLOW/BLOCK
    verdict itself, which is computed identically either way.
    """
    hatch_record_count = 0
    for seg in _scannable_segments(command):
        seg = seg.strip()
        if not seg:
            continue
        # 2026-08-17 shlex tokenization pass: `norm` is a quote-stripped,
        # absolute-path-normalized rendering of `seg` (None if `seg` isn't a
        # git invocation — see `_normalize_git_segment`'s docstring for why
        # that's deliberate, not an oversight). `hit()` checks every pattern
        # against BOTH the raw segment and its normalized form, closing the
        # quoted-token evasion class without rewriting any BLOCK/ALLOW regex.
        norm = _normalize_git_segment(seg)
        variants = (seg, norm) if norm else (seg,)

        def hit(pattern, _v=variants):
            return any(pattern.search(v) for v in _v)

        if hit(_COMMIT_ALLOW):
            _audit_commit_hatch()
            if hatch_record_count < _MAX_HATCH_RECORDS_PER_COMMAND:
                _record_hatch('CAST_COMMIT_AGENT', _hatch_value(seg, 'CAST_COMMIT_AGENT'), 'commit')
                hatch_record_count += 1
            else:
                suppressed_counter[0] += 1
        elif hit(_COMMIT_BLOCK):
            return 2, _COMMIT_MSG
        if hit(_PUSH_ALLOW):
            _audit_push_hatch()
            if hatch_record_count < _MAX_HATCH_RECORDS_PER_COMMAND:
                _record_hatch('CAST_PUSH_OK', _hatch_value(seg, 'CAST_PUSH_OK'), 'push')
                hatch_record_count += 1
            else:
                suppressed_counter[0] += 1
        elif hit(_PUSH_BLOCK):
            return 2, _PUSH_MSG
        if not hit(_STASH_ALLOW) and hit(_STASH_BLOCK):
            return 2, _STASH_MSG
        if not hit(_RESET_ALLOW) and hit(_RESET_BLOCK):
            return 2, _RESET_MSG
        if not hit(_CLEAN_ALLOW) and hit(_CLEAN_BLOCK):
            return 2, _CLEAN_MSG
        if not hit(_CHECKOUT_ALLOW) and (
            hit(_CHECKOUT_BLOCK)
            or any(_checkout_bare_path_blocks(v) for v in variants)
            or hit(_CHECKOUT_FORCE_BLOCK)
        ):
            return 2, _CHECKOUT_MSG
        if not hit(_RESTORE_ALLOW) and hit(_RESTORE_CMD):
            safe = hit(_RESTORE_HAS_STAGED) and not hit(_RESTORE_HAS_WORKTREE)
            if not safe:
                return 2, _RESTORE_MSG
        if not hit(_SWITCH_ALLOW) and hit(_SWITCH_BLOCK):
            return 2, _SWITCH_MSG
        if not hit(_REFLOG_ALLOW) and hit(_REFLOG_BLOCK):
            return 2, _REFLOG_MSG
        if not hit(_GC_ALLOW) and hit(_GC_BLOCK):
            return 2, _GC_MSG
        if not hit(_PRUNE_ALLOW) and hit(_PRUNE_BLOCK):
            return 2, _PRUNE_MSG
        if not hit(_GC_HATCH_ALLOW) and hit(_GC_CINJECT_BLOCK):
            return 2, _GC_CINJECT_MSG
        if not hit(_GC_HATCH_ALLOW) and hit(_GC_CONFIG_WRITE_BLOCK):
            return 2, _GC_CONFIG_WRITE_MSG
        if not hit(_GC_HATCH_ALLOW) and hit(_GC_CONFIG_EDIT_BLOCK):
            return 2, _GC_CONFIG_EDIT_MSG
        if not hit(_GIT_RM_ALLOW) and hit(_GIT_RM_BLOCK):
            return 2, _GIT_RM_MSG
        if not hit(_BRANCH_ALLOW) and hit(_BRANCH_BLOCK):
            return 2, _BRANCH_MSG
        if not hit(_WORKTREE_ALLOW) and hit(_WORKTREE_BLOCK):
            return 2, _WORKTREE_MSG
        if not hit(_UPDATE_REF_ALLOW) and (
            hit(_UPDATE_REF_BLOCK)
            or any(_update_ref_overwrites_existing(v) for v in variants)
        ):
            return 2, _UPDATE_REF_MSG
        if not hit(_FILTER_BRANCH_ALLOW) and hit(_FILTER_BRANCH_BLOCK):
            return 2, _FILTER_BRANCH_MSG
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
