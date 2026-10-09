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
    `GIT_CONFIG_*` env set in an earlier segment (the same-segment and
    `--config-env` forms were closed 2026-10-07 — see the "Config-injection
    indirection" note below), unbalanced-quote parse
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
  - Indirection and spelling (2026-10-06, security review; every one of these was ALLOWED). Every
    BLOCK regex anchors on `(^|\s)git`, so a `git` that another shell runs, or that is written another
    way, evaded them: `(git reset --hard)`, `$(git reset --hard)`, backticks, `{ git reset --hard; }`,
    `bash -c 'git reset --hard'`, `GIT push` (APFS is case-insensitive), `$'git' push`,
    `git${IFS}push`, `echo 'git push' | sh`. What is closed is exactly what the HOW list below
    says; anything else is in RESIDUALS (one list, at the end of this item).
    ADDITIVE, BY CONSTRUCTION: the real segments are evaluated first and unchanged
    (`_executable_segments()` yields `_scannable_segments()` before anything else), and new
    detection is only ever (a) an extra VIRTUAL segment - a code string fed through the same
    per-segment engine - or (b) a `_Refusal`, a fail-closed BLOCK. The per-segment loop never
    returns early on the strength of a virtual segment. Compared with main (9e19323),
    BYTE-IDENTICAL: `_normalize_git_segment`, `_scannable_segments`, `_git_evaluate`,
    `_join_continuations` and every BLOCK / ALLOW pattern. CHANGED: `_GIT_MENTION` (widened: it also
    reads `$` between the letters, and is case-insensitive) and `_git_evaluate_impl` (its loop
    iterates `_executable_segments` instead of `_scannable_segments`; the per-segment engine inside
    it is untouched). `hit()` ORs every variant of a segment, hatch (ALLOW) patterns included, so a
    rewrite of a REAL segment can remove a block (a `$` in a hatch VALUE was forged into a
    well-formed hatch that way): nothing here adds a variant to a real segment.
    HOW IT IS CLOSED (all in `_executable_segments()` / `_executed_code()` / `_Lexer` /
    `_shell_payloads()`):
      * ONE lexer reads every context - top level, `$(...)`, `(...)`, `<(...)`, `${...}`,
        `((...))`, unquoted-heredoc bodies - with bash's rules (blanks are only space/tab/
        newline, so `echo a\xa0#; P` is no comment; `${x//(/y}` has a literal paren; `$$'a\'` is
        `$$` then a quote; `<<` in arithmetic is a shift; an unquoted heredoc body is scanned
        like a double-quoted string, so `don't` in it is data; all pending heredocs of a line
        are tracked). It FAILS CLOSED: input it cannot model with certainty - an unterminated
        quote / substitution / expansion, `$[`, a quote inside arithmetic, a quote inside a
        `${...}` that is itself double-quoted (`$'..'` aside: bash's `extquote`), a heredoc
        delimiter it cannot quote-remove (`<<$'EOF'`, `<<"E'F"`), a heredoc whose delimiter line
        is missing, nesting past 48 levels, a scanner crash - becomes a REFUSAL, but only when
        `git` can be spelled in the text from the start of the earliest unresolved construct
        (or of the command that hands words to a shell, or - when ANY `|` follows the construct -
        of the pipeline's first stage) to the end: nothing there can run git otherwise, and what
        was extracted before it is complete. Cost, accepted: a command with such a construct AND
        a later git mention is refused, and so is one whose unresolved construct is followed by
        any pipe (`echo 'git push' $[1] | grep x`): split it, simplify the quoting, or write long
        text with the Write tool; the 31,322-command real corpus: 10 newly blocked, 0 newly allowed.
      * PAYLOADS at ANY word of a simple command (`_shell_payloads`), so a wrapper (`find -exec`,
        `arch`, `xargs`, `sudo`, `env`, `nohup`, a zsh `noglob` / `coproc`), a redirection (a
        `{fd}>f` too) or an assignment in front does not hide one: the operand of `<shell> -c` (any
        word that names a shell, options skipped - zsh's `=bash` / `=sh` / `=zsh`, ONE leading `=`, is
        the shell's path (`_unequals`); fish's `--command` / `--command=` too), `eval`'s
        arguments, `trap`'s action, `env -S STR`, a `<<<` herestring to a shell, and every
        outermost `$(...)`, backticks, `(...)`, `<(...)`, `>(...)`, `$((...))` body and
        unquoted-heredoc substitution. Followed 3 levels deep; deeper, or past a step / code-count
        cap, REFUSES. An operand written with `$'...'` escapes (`bash -c $'git\x20push'`, `eval`
        too) is also read as the shell reads it, in both readings of `\c\\` (bash 5; bash 3.2/zsh).
        A hatch INSIDE such a payload is evaluated exactly like the same direct command (the
        payload is a segment of its own, so `bash -c $'CAST_PUSH_OK=1 \x67it push'` is allowed
        where `CAST_PUSH_OK=1 git push` is), unless main's raw pattern already blocks the OUTER
        segment, which stays true (`bash -c 'CAST_PUSH_OK=1 git push'`); a hatch OUTSIDE
        (`CAST_PUSH_OK=1 bash -c 'git push'`) never reaches the payload.
      * POSITIONAL parameters: a `-c` payload that reads `$0`..`$9`, `${NN}`, `$@`, `$*`, `${@}`,
        `${*}`, `${@:N}`, `${*:N:M}` is also evaluated with the operands after it substituted, as
        the shell reads them (decoded: `$'\x70ush'`), three times: quoted (one word per operand),
        raw (the operand's own words: what `eval "$1"`, `exec $1`, `$@` and `"$1"` run) and raw SPLIT
        (a tab or newline in an operand is a blank: an unquoted `$1` / `$@` / `$*` is split at every
        default-IFS character, newline included, where raw would leave a command separator between
        the words) - `bash -c 'git $1' x push`, `bash -c '$1' x 'git push'`, `bash -c 'git $1' x
        $'\npush'`, `bash -c '$1 $2' x $'git\n' push`. A `"$@"` / `"$*"` is read the unquoted way too
        (the shell would not split it): accepted, it only blocks more.
      * SPELLED GIT: a word whose shell reading (`_word_view`: quotes and backslashes removed,
        `$'..'` escapes decoded, `$".."` as "..", split at an unquoted `$IFS` / `${IFS}`) has the
        basename `git`, case-insensitively, becomes the virtual segment `git <rest of the
        command>`: `GIT`, `/usr/bin/GIT`, `$'git'`, `$"git"`, `g''it`, `\git`, `git${IFS}push`,
        `$'\x67it'`, `$'\147it'`, zsh's `=git`, at the command word or any later one (`command GIT
        push`, `{ $'git' push; }`, `xargs GIT push`, `exec /usr/bin/git push`). A plain lower-case
        `git` is skipped where main sees it as it runs (the first word of a main segment); a
        PATH-qualified one (`/usr/bin/git`) only when, in addition, the command's raw span has no
        `;` `|` `&` newline `$(` backtick `${` (main's raw pattern needs a space before a plain
        `git`, so a quoted `;` or a `$(..)` in an assignment moves its segment boundary:
        `A=$(echo 1) /usr/bin/git push`). The extractor's gate (`_git_mentioned`) also reads
        numeric ANSI-C escapes, so `$'\x67it'` is "a git mention". Cost, accepted: a data word that
        spells git and is followed by a guarded verb (`echo 'git' push`, `echo =git push`) blocks.
      * PIPE TO A SHELL: a shell that reads its stdin (no `-c`; no script operand, or `-`,
        `/dev/stdin`, `/dev/fd/0`, `/proc/self/fd/0` - the path as the OS reads it: `//dev/stdin`,
        `/dev//stdin`, `/dev/./stdin`, `/dev/fd/00`, `/dev/stdin/` (`_is_stdin_path`); `-s`,
        `$SHELL`, zsh's `=bash` count; `source` / `.` of those too) and stands at
        the stage's COMMAND word (after assignments, redirections, `_STDIN_WRAPPERS` and their
        options - a CLOSED list: `env command exec builtin eval nohup nice time sudo doas noglob
        nocorrect stdbuf caffeinate arch timeout setsid ionice unbuffer sandbox-exec chroot taskset
        chrt watch` - `| eval bash`, `eval source /dev/stdin <<< ..` - with the operand arity
        `_WRAPPER_OPERANDS`) is handed the arguments of EVERY earlier stage
        of its pipeline, each and all joined (`echo 'git push' | bash`, `| cat | sh`, `<<< 'git push'
        | bash`, `echo git push | bash -s`), and the arguments of the commands inside a `<(...)` it
        reads as script or stdin (`bash < <(echo 'git push')`, `source <(...)`, `bash <(...)`; one
        level). A heredoc whose command or pipeline holds such a shell is code, also when the shell
        is on a LATER line of a pipeline that continues over the newline (`cat <<EOF |` newline
        body `EOF` newline `bash`).
    HATCHES: a hatch is scoped to its own (virtual) segment and NEVER passes through a spelling.
    `CAST_PUSH_OK=1 bash -c 'git push'` is blocked (the hatch is not inside the executed string),
    `CAST_PUSH_OK=1 GIT push` is blocked (the virtual segment carries no assignment prefix), and a
    hatch INSIDE a `-c` / `eval` payload is evaluated like the same direct command (see PAYLOADS):
    NOT "no hatch is ever honoured".
    The plain `CAST_PUSH_OK=1 git push` and `CAST_PUSH_OK=1 /usr/bin/git push` are honoured exactly
    as on main; `CAST_COMMIT_AGENT=1 git commit -m "$(cat f)"` is unaffected (the substitution body
    is `cat f`).
    RESIDUALS - ONE LIST, ACCEPTED, NOT CHASED (each needs an expansion / data-flow engine, not a
    lexer; `tests/test_cast_git_guard_spellings.py::TestReviewM5Residuals.RESIDUALS` pins a SAMPLE of
    them - each of those is still allowed - not every form listed, so closing one is a deliberate
    edit of this list, and of the sample where it is in it):
      * a group or subshell piped INTO a shell (`{ echo 'git push'; } | bash`, `(echo ..) | bash`)
        and a stdin shell INSIDE a group or subshell at the end of a pipe (`x | (bash)`, `x | { :;
        bash; }`, `x | if true; then bash; fi`, `x | while read c; do eval "$c"; done`), `sh -c
        'sh'`; a pipe producer that TRANSFORMS its data (`xxd -r -p | bash`, `base64 -d | sh`);
        a stdin shell behind a wrapper that is not in `_STDIN_WRAPPERS`; `tee >(bash)`,
        `> >(bash)`, `exec 3<<< ..; bash <&3`; `echo .. | env -S 'bash -s'`;
      * a stdin shell whose input does not come straight from a pipe / herestring on it: `source --
        /dev/stdin <<< ..`, a group or subshell around it (`{ source /dev/stdin; } <<< ..`, `{ bash; }
        <<< ..`, `( bash ) <<< ..`, and `( bash ) <<EOF` with a SPELLED git in the body: a plain
        lower-case line is main's to block), stdin through another fd (`source /dev/fd/3 3<<< ..`,
        `/dev/fd/63`, `bash /dev/fd/3 3<&0`) and a COMPUTED or globbed path (`bash $(echo
        /dev/stdin)`, `/dev/std?n`, `/dev/fd/$((0))`, `p=/dev/stdin; bash $p`);
      * process substitution beyond one level of plain commands: a nested subshell body (`bash <
        <((echo ..))`), a producer fed through a redirect (`cat < <(echo ..) | bash`, `bash < <(cat <
        <(echo ..))`) and a heredoc inside it (`bash <(cat <<EOF` + a spelled git + `EOF` + `)`).
        A `<(..)` that is an ARGUMENT of the producer IS read: `bash <(cat <(echo 'git push'))`;
      * `xargs ... bash -c '{}'` fed from a pipe, `find -exec` fed by data;
      * (`git -c alias.x=push x` was main's own gap — CLOSED 2026-10-07: every inline `-c alias.<n>`
        now blocks as an exec-capable config key, see `_EXEC_CONFIG_KEY`); a
        redirection inside git's own arguments (`git >/dev/null push`, `git {fd}>f push`) and a
        quoted `;` in them (`git -c 'a;b' push`): main's segment-split gaps, inherited unchanged;
      * command words built by a parameter, a substitution or an expansion: `x=push; git $x`,
        `set -- push; git $1`, `eval "$(echo 'git push')"`, `$(echo git) push`, `g$(true)it`,
        `$G push`, `g$xit`, `bash -c 'git ${1:-push}'` and `${1#}` / `${1/x/y}` / `${1:0}` /
        `${1:0:4}` positional forms (`${N}` of any width and `$N` ARE read; zsh's `$10` is its tenth
        parameter, bash's `${1}0`: read as bash's), `shift; git $1`, the implicit `$@` of `for a; do
        $a; done` (`for a in "$@"` IS read), a `printf` format that builds the text (`printf
        'g%s' it`), `\c\\` outside the `-c` / `eval` operands (read both ways only there; zsh reads
        `\c` in `$'..'` as a literal `c`, so `zsh -c $'\c\nGIT push'` keeps its newline), brace,
        glob and parameter-default spellings (`{git,} push`, `g{i..i}t`, `/usr/bin/g?t`,
        `g${X:-i}t`, `bash -c "${x:-git push}"`), any word `_word_view` cannot finish without
        running an expansion;
      * other interpreters: `python -c`, `perl -e`, `awk`, `node -e`, `osascript -e`, `ruby -e`, a
        script file written and run (`echo 'git push' > x.sh; bash x.sh`);
      * aliases and functions defined in an EARLIER command (`alias g=git; g push`);
      * zsh glob-qualifier eval (`*(e:'...':)`) and zsh's `$commands[git]`; zsh's `{fd}` with a
        space before the redirection (`bash {fd} >/dev/null -c 'git push'`: the guard reads `{fd}` as
        an ordinary word there, zsh as the descriptor variable);
      * bash 3.2 and bash 5 disagree on a heredoc inside `$(...)`; bash 5.x is modelled;
      * cap-driven false positives (a BLOCK of a command that does not run git, never an allow):
        the size cap (a git-mentioning command of more than ~250k words / metacharacters, or more
        than 5000 nested code strings, is REFUSED), any pipe after an unresolved construct, an
        upper-case `Git` / `=git` ARGUMENT followed by a verb, `ssh host <<< 'git push'`, a hatched
        plain git whose argument has a `$'..'` / `${IFS}` (judged without the hatch), a stdin shell
        that is given BOTH a pipe and a heredoc / herestring (`echo 'git push' | bash <<EOF`: zsh
        feeds both, bash only the body - both are read), a quoted `"$@"` over an operand with a
        newline, a stdin path with a trailing slash (`bash /dev/stdin/`: Linux refuses it).
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
    correctly ALLOWS. `clean`'s dry-run safety instead lives in
    `_dry_run_block` (formerly `_CLEAN_BLOCK`'s own negative lookahead),
    evaluated once per variant and OR'd — so if the RAW variant alone still trips the block (as
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
    age) blocked — same recovery-path rationale (escape: CAST_GC_OK=1).
  - EVERY `git gc` form (bare, `--aggressive`, `--auto`, `--prune`,
    `--no-prune`, ...), every `git maintenance run` (any task) and every
    `git worktree prune` except `-n`/`--dry-run` is blocked (2026-10-07 U6a-2,
    probed hazard E1): `gc` and `maintenance run`'s gc task run `git worktree
    prune`, which FOLLOWS an agent-planted SYMLINKED `.git/worktrees/<id>` entry
    and EMPTIES its target (`gc.worktreePruneExpire=never` does not stop it).
    Escapes: CAST_GC_OK=1 (gc / maintenance run), CAST_WORKTREE_OK=1 (worktree
    prune). Plus a STATEFUL check (`_worktree_symlink_hazard`): ANY git
    invocation is blocked while the target repo's common dir has a symlinked
    `worktrees/*` entry (or `gitdir` file, or a symlinked `worktrees` dir) —
    git's own implicit auto-gc (commit/merge/fetch/...) would otherwise run the
    same prune; it is a pure filesystem check (no subprocess), the repo is
    resolved from the cwd, literal `cd`/`pushd` targets earlier in the command, git's `-C`
    / `--git-dir` (either spelling) / `GIT_DIR=` / `env -C`, through any path-spelled git
    and git's full global-option grammar; unreadable dirs
    fail OPEN (git, same uid, cannot traverse them either) and a dir over
    `_MAX_WORKTREE_ENTRIES` fails CLOSED (hatch: CAST_WORKTREE_OK=1).
    The plant itself (`ln -s ... <x>.git/worktrees/<id>`) is blocked too
    (hatch CAST_WORKTREE_OK=1). RESIDUAL: a symlink planted AND used inside ONE
    command line by a means other than `ln -s` (`mv`, `cp -P`, an interpreter) is not
    visible at check time — the gc / maintenance / worktree-prune forms are blocked
    statically for exactly that reason; an implicit auto-gc after such a plant is not.
    A dynamic `cd $D` / `-C "$D"` target, `cd -`, `popd`, and a `GIT_DIR` exported in an
    earlier segment are not resolved. A command with more than `_MAX_TRACKED_CDS` literal
    cds, or a git prefix past the 8 KB / 128-word cap, is "too complex" and a git segment in
    it fails CLOSED (hatch CAST_WORKTREE_OK=1). `cd` text inside a heredoc body or a quoted
    string is read as a real `cd` (accepted false positive, only ever visible in a repo that is
    already poisoned). `-n ... --no-dry-run` is NOT a dry run (the last
    toggle wins; `_dry_run_block`) for clean / prune / worktree prune / rm.
  - `git prune` blocked in every non-dry-run form — measured MORE
    destructive than `git gc --prune=now` (no grace period at all; escape:
    CAST_PRUNE_OK=1). Dry runs (`-n`/`--dry-run`) stay UNBLOCKED, as do the
    unrelated `git prune-packed` and `git remote prune` (`git worktree prune`
    has its own block, above).
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
  - Former "entirely unguarded" list, resolved by the 2026-08-17
    remaining-ops pass (docs/architecture/cast-protocol-spec.md). NOW
    BLOCKED, each with its own hatch: `git rm -f` (CAST_GIT_RM_OK=1), `git
    branch -D` (CAST_BRANCH_OK=1), `git worktree remove -f`
    (CAST_WORKTREE_OK=1), `git update-ref -d` (CAST_UPDATE_REF_OK=1), `git
    filter-branch` (CAST_FILTER_BRANCH_OK=1). DELIBERATELY ALLOWED after
    measurement (non-destructive), pinned by regression fences in
    `tests/pre-tool-guard.bats`: `git rm -r --cached` (index-only; the
    worktree file and its uncommitted edit survive) and `git
    sparse-checkout set` / `init --cone` (remove only clean committed
    files; git refuses to drop a locally-modified file and leaves untracked
    files alone; `disable` restores — re-confirmed 2026-10-02 on git
    2.56.0; the 2026-09-05 audit item S-5 calling it destructive was a
    false finding).
  - Gaps the spec's 2026-08-17 note listed as unguarded, now CLOSED:
    a `-C` path containing a space (`git -C '/tmp/my dir' reset --hard`
    etc., in every quoting form) no longer defeats the guard (see #363/#364/
    #365, parsed-token matching); `git branch -M`/`-f` and `git update-ref
    <ref> <sha>` overwriting an EXISTING ref now block (creating a brand-new
    ref stays allowed, as designed). Each was verified 2026-10-02 by
    calling `_git_evaluate` directly as a module (return 2 = block). The
    residual limitations are the ones named elsewhere in this docstring
    (subshell/`$( )` wrapping, `GIT_CONFIG_*` env set in an earlier segment,
    unbalanced-quote parsing); do not assume that list is
    exhaustive. (`git reflog expire`/`git gc --prune=<value>`/`git prune`
    were once on the unguarded list; they are now covered by the
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
  - Config-injection indirection — CLOSED 2026-10-07 (U6a-1, CAST v10.3.0).
    It was a measured, deliberately unchased residual (2026-08-17):
    `PRX=now git --config-env=gc.pruneExpire=PRX gc` and `GIT_CONFIG_COUNT=1
    GIT_CONFIG_KEY_0=gc.pruneExpire GIT_CONFIG_VALUE_0=now git gc` both
    deleted the dangling blob and both were ALLOWED. Now BLOCKED (same
    message and CAST_GC_OK hatch as the `-c` block): `_normalize_git_segment`
    renders `--config-env=<k>=<E>` / `--config-env <k>=<E>` as the `-c` it is
    equivalent to, and `_GC_ENV_KEY_BLOCK` / `_GC_ENV_PARAMETERS_BLOCK` match
    `GIT_CONFIG_KEY_<n>=<gc key>` / a `GIT_CONFIG_PARAMETERS` value naming one
    on the segment that runs git (also through `env ...` and `bash -c '...'`).
    The exec-key analogue (`core.pager`, `alias.*`, `core.hooksPath`, ... —
    see `_EXEC_CONFIG_KEY`) shares the same machinery under CAST_GIT_CONFIG_OK.
    STILL UNCOVERED, measured 2026-10-07: the assignment in an EARLIER segment
    than the git that consumes it (`export GIT_CONFIG_KEY_0=gc.pruneExpire;
    git gc`, `export GIT_CONFIG_PARAMETERS=...; git status`) — the engine
    evaluates one segment at a time and the exporting segment mentions no
    git, so both are ALLOWED; and env vars that name a program rather than a
    config key (`GIT_PAGER`, `GIT_SSH_COMMAND`, `GIT_EXTERNAL_DIFF`, ...) or
    a config file via an unlisted variable; and a DYNAMIC git command word
    (`git $C core.pager v`, `G=git; $G config core.pager v`, shell aliases or
    functions), the same limit as every other block here. Exec-key `git
    config` writes fail CLOSED when the option parser cannot be modelled
    exactly (abbreviated `--fil`, bundled `-zf`, dynamic `--$E`, quoted
    redirection look-alikes, unquoted globs/`$K` in the key position); the
    accepted over-blocks (a VALUE that is literally an exec key, e.g.
    `config user.name "core.pager"`) are hatchable with CAST_GIT_CONFIG_OK=1
    — see the block comment above `_exec_config_cmd_blocks`. A word-splitting
    sole operand (`$KV`, `"$@"`) is key + value and is never a safe read. Also
    blocked: `clone -c|--config <exec key>=<v>` (persists into the new repo) and
    `clone|init --template` (copies hooks), abbreviations included (matched as
    UNIQUE PREFIXES of the subcommand's real long options, `_EXEC_LONG_OPTS`,
    from `git <sub> -h` on git 2.56 — an option git hides from `-h` is not in the
    table). git's own shell-exec carriers — `submodule foreach <cmd>`, `rebase
    -x|--exec <cmd>`, `difftool -x|--extcmd <cmd>`, `bisect run <cmd>` — hand a
    STRING to a shell, so `_git_carrier_payloads` re-evaluates it through the
    whole engine like a `bash -c` operand (a hatch on the OUTER command is not
    honoured for it); an unreadable carrier is a refusal. `git grep -O<cmd>` and
    other program-taking flags are not carriers (accepted, below).
    ACCEPTED RESIDUALS, same class as the dynamic command word: a user's OWN
    `~/.gitconfig` `help.autocorrect` or a pre-existing alias that turns a typo
    into `config` (the guard sees the typed word; setting `help.autocorrect`
    itself IS blocked), and CLI flags that run a program one-shot at the agent's
    own privilege (`fetch|clone --upload-pack`, `clone -u`, `ext::` URLs — `ext`
    is off by default via protocol.allow, and persisting `protocol.ext.allow` is
    blocked), and `git grep -O<cmd>` / `--open-files-in-pager=<cmd>` (a
    program-naming flag, one-shot, the agent's own privilege — real git 2.56
    executes it; pinned ALLOW). The threat model is a careless
    agent, not an adversary evading a security boundary; the OS/tool sandbox
    is the real boundary.
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

CONTRACT: exit 2 + stderr message = block; exit 0 = allow. Bash FAILS OPEN — an
internal error in the git guards allows the tool (a guard crash must never block all
Bash work). The Write/Edit policy gate (`evaluate`) FAILS CLOSED on an internal error
(escape hatch: CAST_POLICY_OVERRIDE=1).
CLAUDE_SUBPROCESS=1 (managed/headless sub-claude) skips ONLY the Write/Edit policy engine + TTL sweep; the git commit/push/stash guards run in EVERY context (a subagent must not bypass the irreversibility guards).
"""
import datetime
import json
import os
import re
import shlex
import stat
import subprocess
import sys

# --- git global-option tolerance (shared by every git pattern) --------------
# Matches: -C <path>, --no-pager, -c <cfg>, --git-dir=<d>, --work-tree=<w>
_GIT_OPTS = r'(\s+(-C\s+\S+|--no-pager|-c\s+\S+|--git-dir=\S+|--work-tree=\S+))*'


def _flag_cluster(letter: str) -> str:
    """Regex source for a single-dash short-flag cluster CONTAINING `letter`
    (`-f`, `-rf`, `-fb`, ...). Verdict-identical to the old
    `-[a-zA-Z]*<letter>[a-zA-Z]*` but linear in the token length.

    The old form is O(n^2) on one long token that ends in a word character
    after the letter run (`-fff...f_`): for every position the first star
    could stop at, the second star retried every length and `\\b` / `(\\s|$)`
    failed each time. 2026-10-06 security finding: a ~60 KB token made one
    `git branch`/`checkout`/`rm` segment cost >10 s, past the 5 s PreToolUse
    hook timeout, and a hook timeout is a non-blocking ALLOW. The terminator
    that follows every use of this fragment (`\\b` or `(\\s|$)`) can only
    hold at the END of the maximal letter run — between two letters neither
    holds — so "the run contains `letter`" is checked once in a lookahead
    and the run is then consumed by a single greedy `+`, which on failure
    backs off one position at a time (O(n)) instead of re-trying a nested
    star at each. No capture group is introduced, so numbered groups in the
    patterns that embed this fragment keep their numbering."""
    return r'-(?=[a-zA-Z]*' + letter + r')[a-zA-Z]+'

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
_CLEAN_DRY_RUN = r'(\s|^)(--dry-run|' + _flag_cluster('n') + r')(\s|$)'
# 2026-10-07 (U6a-2 security F1): the dry-run exemption used to be `(?!.*_CLEAN_DRY_RUN)` -- ANY `-n`
# / `--dry-run` after the command exempted it. Measured with real git (clean, prune, worktree
# prune, rm all use OPT__DRY_RUN): the LAST toggle wins, `--no-dry-run` (or an abbreviation of it,
# `--no-d`...) turns a prior `-n` OFF, so `git clean -f -n --no-dry-run` REALLY deletes. The BLOCK
# patterns below therefore only recognise the command; `_dry_run_block` applies the exemption: a
# match is exempt only when the last dry-run toggle after it is ON. One linear scan per variant (a
# regex `(?!.*ON(?!.*OFF))` would be O(n * toggles): a 40k-`-n` run was a latency lever).
# An abbreviation of `--dry-run` itself (`--dry`) is NOT exempted (fail closed, as before).
_DRY_TOGGLE = re.compile(
    r'(?:\s|^)(?:(?P<on>--dry-run|' + _flag_cluster('n') + r')'
    r'|(?P<off>--no-d(?:r(?:y(?:-(?:r(?:un?)?)?)?)?)?))(?=\s|$)'
)


def _dry_run_block(pattern, variants) -> bool:
    """True if `pattern` (a command-only BLOCK regex) matches any variant WITHOUT a dry-run in
    effect after the match (see the note above `_DRY_TOGGLE`)."""
    for v in variants:
        if pattern.search(v) is None:
            continue                       # the common case: skip the toggle scan entirely
        last = None
        for t in _DRY_TOGGLE.finditer(v):
            last = t
        for m in pattern.finditer(v):
            if last is None or last.start() < m.end() or last.group('off') is not None:
                return True
    return False


_CLEAN_BLOCK = re.compile(
    r'(^|\s)git' + _GIT_OPTS + r'\s+clean\b'
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
        elif opt == '--config-env' and (eq or j + 1 < len(tokens)):
            # 2026-10-07 U6a-1: `--config-env=<key>=<ENVVAR>` / `--config-env <key>=<ENVVAR>`
            # set config exactly like `-c <key>=<value>` (the value comes from the
            # environment), so render it as the `-c` it is equivalent to — the gc-expiry
            # and exec-key `-c` blocks then see it, quote-stripped, with no new pattern.
            val = _val if eq else tokens[j + 1]
            kept_tail.extend(('-c', val.replace(' ', '_') if re.search(r'\s', val) else val))
            j += 1 if eq else 2
        elif opt.startswith('-c') and not opt.startswith('--') and len(opt) > 2:
            # `-c<key>=<v>` (no space) is NOT a form git accepts (measured: "unknown
            # option"), but the guard must not depend on that — same rendering as `-c <key>=<v>`.
            val = tokens[j][2:]
            if re.search(r'\s', val):
                name, _sep, _v = val.partition('=')
                val = name + '=_'
            kept_tail.extend(('-c', val))
            j += 1
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
_FORCE_FLAG_LOOKAHEAD = r'(?:^|\s)(?:--force|' + _flag_cluster('f') + r')\b'
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
# `--prune` with no `=value`, `--no-prune`, and `--auto` were allowed then —
# none of them force an immediate/explicit prune. 2026-10-07 (U6a-2): that
# stopped being true for a DIFFERENT reason — every `git gc` form runs `git
# worktree prune`, which follows an agent-planted symlinked `.git/worktrees/<id>`
# entry and empties its target (`gc.worktreePruneExpire=never` does not stop
# it). `_GC_ANY_BLOCK` therefore blocks every `git gc` form (hatch: CAST_GC_OK=1,
# no new hatch); `_GC_BLOCK` keeps only the `--prune=<value>` shape so that
# message (and its recovery-path rationale) is unchanged. The `--no-prune` trap
# below still matters for `_GC_BLOCK`: the lookahead requires the literal
# substring `--prune=` preceded by a token boundary, which `--no-prune` (no `=`
# at all) never contains.
# Tolerates extra VAR=value assignments between CAST_GC_OK=1 and git.
_GC_ALLOW = re.compile(
    r'(^|&&\s*)CAST_GC_OK=1\s+([A-Za-z_][A-Za-z0-9_]*=\S+\s+)*git' + _GIT_OPTS + r'\s+gc\b'
)
_GC_PRUNE_VALUE = r'(?:^|\s)--prune=\S+'
_GC_BLOCK = re.compile(
    r'(^|\s)git' + _GIT_OPTS + r'\s+gc\b(?=.*' + _GC_PRUNE_VALUE + r')'
)
# Every `git gc` form (U6a-2). `(?![\w-])`, not `\b`, so `git gcfoo`/`git gc-x` stay out.
_GC_ANY_BLOCK = re.compile(
    r'(^|\s)git' + _GIT_OPTS + r'\s+gc(?![\w-])'
)
# `git maintenance run` (any task / flag): its default and `--task=gc` run the same `worktree
# prune`; `--task=worktree-prune` is the prune itself. `start`/`register`/`stop`/`unregister`
# only edit config / the scheduler and stay allowed (the scheduled tasks exclude gc and
# worktree-prune by default). Hatch: CAST_GC_OK=1.
_MAINTENANCE_BLOCK = re.compile(
    r'(^|\s)git' + _GIT_OPTS + r'\s+maintenance\s+run(?![\w-])'
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
# prune`; `git worktree prune` has its own block, `_WORKTREE_PRUNE_BLOCK`). `\b` alone is wrong here — `prune\b` still matches inside
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
    r'(^|\s)git' + _GIT_OPTS + r'\s+prune(?![\w-])'      # dry-run exemption: `_dry_run_block`
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

# --- exec-config injection block (2026-10-07 U6a-1, CAST v10.3.0) ------------
# Threat: git config keys that make git EXECUTE a program (or load more config /
# rewrite URLs into `ext::` transports) run in Ed's UNSANDBOXED terminal and in
# CAST hooks the moment a later, innocent-looking `git status`/`git log`/`git
# diff` is run in that repo. File-tool writes to `.git/config` / `~/.gitconfig`
# are already denied by config/policies.json; the remaining route is a Bash
# `git config` WRITE (persistent, the dangerous one) or a one-shot `-c` /
# `--config-env` / `GIT_CONFIG_*` env injection (same privilege as the agent
# itself — blocked as defence-in-depth). Same deny-by-default precedent as the
# gc-expiry keys above: ANY value blocks (`=true`, empty, `=never`), READS stay
# allowed, one hatch (CAST_GIT_CONFIG_OK=1).
#
# The key list is git-config(1)'s "runs a command / loads a file / rewrites a
# URL" set: core.{fsmonitor,hooksPath,pager,editor,sshCommand,askPass,gitProxy,
# alternateRefsCommand}, sequence.editor, ssh.variant, pager.<cmd>, alias.<n>,
# filter.<n>.{clean,smudge,process}, diff.external, diff.<n>.{command,textconv},
# merge.<n>.driver, {merge,diff}tool.<n>.{cmd,path}, gpg.program, gpg.<fmt>.
# program, gpg.ssh.defaultKeyCommand, credential[.<url>].helper, remote.<n>.
# {uploadpack,receivepack,vcs}, uploadpack.packObjectsHook, include.path,
# includeIf.<cond>.path, protocol.<n>.allow, url.<base>.{insteadOf,
# pushInsteadOf}, web.browser, browser.<t>.{cmd,path}, man.<t>.cmd, sendemail.
# {smtpServer,toCmd,ccCmd,headerCmd}, plus four further exec keys from the same
# man page: trailer.<t>.cmd, interactive.diffFilter, init.templateDir (copies
# hooks into every new repo), submodule.<n>.update (`!command`).
# Section/variable names are case-insensitive in git, subsection names are not
# but are matched case-insensitively too (fail-closed). A subsection can hold
# dots/anything (`includeIf.gitdir:~/x/.path`), so each pattern anchors on the
# section start and the LAST component. `[^\s=]+` is the subsection class: a
# `-c`/env key ends at the first `=`; a `git config` key may contain `=`, so
# the write block uses the `\S+` flavour. Both end the way the match does only
# at a token boundary, supplied by the caller's lookahead.
def _exec_config_key(sub):
    return (
        r'(?i:'
        r'core\.(?:fsmonitor|hooksPath|pager|editor|sshCommand|askPass|gitProxy|alternateRefsCommand)'
        r'|sequence\.editor|ssh\.variant|interactive\.diffFilter|init\.templateDir'
        r'|imap\.tunnel|instaweb\.(?:httpd|browser)|help\.(?:browser|autocorrect)|gc\.recentObjectsHook'
        r'|uploadpack\.packObjectsHook|diff\.external|web\.browser'
        r'|gpg\.program|gpg\.ssh\.defaultKeyCommand|gpg\.[^\s=.]+\.program'
        r'|credential\.helper|include\.path'
        r'|sendemail\.(?:smtpServer|toCmd|ccCmd|headerCmd)'
        r'|sendemail\.' + sub + r'\.(?:smtpServer|toCmd|ccCmd|headerCmd)'
        r'|(?:pager|alias)\.' + sub +
        r'|filter\.' + sub + r'\.(?:clean|smudge|process)'
        r'|diff\.' + sub + r'\.(?:command|textconv)'
        r'|merge\.' + sub + r'\.driver'
        r'|(?:mergetool|difftool|browser)\.' + sub + r'\.(?:cmd|path)'
        r'|trailer\.' + sub + r'\.(?:cmd|command)'
        r'|man\.' + sub + r'\.(?:cmd|path)'
        r'|(?:guitool)\.' + sub + r'\.cmd'
        r'|hook\.' + sub + r'\.command'
        r'|credential\.' + sub + r'\.helper'
        r'|remote\.' + sub + r'\.(?:uploadpack|receivepack|vcs)'
        r'|(?:includeIf)\.' + sub + r'\.path'
        r'|protocol\.' + sub + r'\.allow'
        r'|url\.' + sub + r'\.(?:insteadOf|pushInsteadOf)'
        r'|submodule\.' + sub + r'\.update'
        r')'
    )


_EXEC_CONFIG_KEY = _exec_config_key(r'[^\s=]+')
_EXEC_CONFIG_KEY_ANYSUB = _exec_config_key(r'\S+')
_GIT_CONFIG_HATCH_ALLOW = re.compile(
    r'(^|&&\s*)CAST_GIT_CONFIG_OK=1\s+([A-Za-z_][A-Za-z0-9_]*=\S+\s+)*git\b'
)

# Global options before the subcommand: `_GIT_OPTS`' set plus `--config-env=`.
# Every alternative consumes a distinct token shape, so the repeated group is
# deterministic (no `-C -C -C ...` ambiguity -> no exponential backtracking).
_EXEC_GLOBAL_OPTS = (
    r'(?:\s+(?:-C\s+\S+|--no-pager|-c\s+\S+|--git-dir=\S+|--work-tree=\S+'
    r'|--config-env=\S+))*'
)
_Q = r'''["']?'''

# (b) inline `-c <key>[=<v>]` / `-c<key>=<v>` and `--config-env=<key>=<ENV>`.
# `_normalize_git_segment` rewrites `--config-env <k>=<E>` / `--config-env=<k>=<E>` and the
# attached `-c<k>=<v>` into the `-c <k>=<v>` form (quotes stripped), so the
# quoted / space forms reach this pattern through the normalized view; the raw
# alternatives cover the unquoted forms when shlex cannot tokenize.
_EXEC_CINJECT_BLOCK = re.compile(
    r'(^|\s)git' + _EXEC_GLOBAL_OPTS +
    r'(?:\s+-c\s*' + _Q + _EXEC_CONFIG_KEY + _Q + r'(?:=|(?=\s|$))'
    r'|\s+--config-env(?:=|\s+)' + _Q + _EXEC_CONFIG_KEY + _Q + r'=)'
)

# `git config` writes are decided on TOKENS, and fail CLOSED whenever the guard cannot model
# git's own option parser exactly (security rounds 1+2, 2026-10-07). History: a line-wide
# "read-looking token anywhere" lookahead let `config core.editor "a --get b"` /
# `core.askpass x --get` through; then a tokenizer that dropped QUOTED redirection-looking
# words (`core.pager '>/dev/null v'`) and trusted an option region that is not git's
# (abbreviated `--fil`, bundled `-zf`, `--$E`) shifted the key operand. Structural rule now:
#   1. `_exec_split_words` records per word whether ANY char was quoted/escaped and which
#      chars come from an unresolvable expansion (`$`, backtick, unquoted glob/brace); only an
#      entirely UNQUOTED word can be a redirection.
#   2. A `git config` segment is a SAFE READ only if its option region is parsed EXACTLY (every
#      option token an exact member of `_EXEC_CFG_ZERO_OPTS` / `_EXEC_CFG_VALUE_OPTS`, value
#      options consuming exactly the next word or `=value`, no dynamic option token) AND it is
#      a read form: an exact read/unset/list/remove-section flag, a get/list/unset/
#      remove-section/edit subcommand, or at most one operand.
#   3. Anything else is "not a recognized read": BLOCK if ANY word after `config` (decoded,
#      quoted or not) is an exec key, a rename-section form's new section is exec-capable (any
#      word, when the option region was not exactly parsed), or a word that could be the KEY
#      (any non-final operand; any word at all when the option region was not exactly parsed)
#      is dynamic. The final operand (the value) may contain `$`.
# ACCEPTED OVER-BLOCKS (hatchable with CAST_GIT_CONFIG_OK=1): `git config user.name "core.pager"`
# (a value that is literally an exec key) and any not-exactly-parsed option spelling that sits
# next to an exec key. ACCEPTED RESIDUAL (pinned in tests, same limit as the rest of this
# module): a dynamic git SUBCOMMAND or command word (`git $C core.pager v`, `G=git; $G config
# core.pager v`, shell aliases/functions) is not seen.
_EXEC_SECTIONS = (
    r'(?i:core|pager|alias|sequence|ssh|filter|diff|merge|mergetool|difftool|gpg'
    r'|credential|remote|uploadpack|include|includeIf|protocol|url|web|browser'
    r'|man|sendemail|trailer|interactive|init|submodule|imap|instaweb|help|guitool|hook)'
)
_EXEC_KEY_FULL = re.compile(_EXEC_CONFIG_KEY_ANYSUB + r'\Z')
_EXEC_SECTION_FULL = re.compile(_EXEC_SECTIONS + r'(?:\..*)?\Z', re.S)
_EXEC_BRACE = re.compile(r'\{[^{}]*(?:,|\.\.)[^{}]*\}')
_EXEC_REDIRECT = re.compile(r'[0-9]*(?:>>?|<<?<?|>&|<&|&>>?)')
_EXEC_CFG_SUBCMDS = frozenset(('get', 'set', 'list', 'unset', 'edit', 'rename-section', 'remove-section'))
_EXEC_CFG_READ_SUBCMDS = frozenset(('get', 'list', 'unset', 'remove-section', 'edit'))
_EXEC_CFG_VALUE_OPTS = frozenset(('-f', '--file', '--blob', '--type', '--default', '--comment', '--value'))
_EXEC_CFG_READ_FLAGS = frozenset((
    '--get', '--get-all', '--get-regexp', '--get-urlmatch', '--get-color', '--get-colorbool',
    '--unset', '--unset-all', '--list', '-l', '--remove-section', '--edit', '-e',
))
_EXEC_CFG_ZERO_OPTS = _EXEC_CFG_READ_FLAGS | frozenset((
    '--local', '--global', '--system', '--worktree', '--add', '--replace-all', '--all',
    '--fixed-value', '--bool', '--int', '--bool-or-int', '--path', '--expiry-date', '--no-type',
    '--includes', '--no-includes', '--show-origin', '--show-scope', '--null', '-z', '--name-only',
    '--rename-section',
))
# shlex (or this splitter) could not read the segment: fail CLOSED for a `git config` that
# names an exec key at all, since a quote we cannot close may hide the real operand order.
_EXEC_UNPARSEABLE = re.compile(
    r'(^|\s)git\b(?=.*\sconfig\b)(?=.*(?:^|[\s"\'])' + _EXEC_CONFIG_KEY_ANYSUB + r'(?=[\s"\']|$))'
)
_ANSI_C_WORD = re.compile(r"\$'((?:[^'\\]|\\.)*)'", re.S)


def _decode_ansi_c_text(seg):
    """`seg` with every `$'...'` replaced by the text the shell makes of it (quoted again only
    if the decoded text would split into several words), for the regex views."""
    def one(m):
        v = _ansi_c(m.group(1))
        if not re.search(r'\s', v):
            return v
        return "'" + v + "'" if "'" not in v else '"' + v.replace('"', '\\"') + '"'
    return _ANSI_C_WORD.sub(one, seg)


def _exec_split_words(seg):
    """Shell-split `seg` into `(text, dyn, quoted)` words. `dyn[i]`: char i is produced by an
    expansion the guard cannot resolve (unquoted/double-quoted `$` or backtick, an unquoted glob
    char or `{a,b}` / `{1..3}` brace expansion). `quoted` is a bitmask: 1 = ANY char of the word was quoted or
    escaped, 2 = the word can word-split into several words. Single-quoted text is literal; `$'..'` is decoded; an unquoted `#` at a word start
    ends the command. None if a quote is unterminated."""
    words = []
    i, n = 0, len(seg)
    while i < n:
        while i < n and seg[i] in ' \t\r\n':
            i += 1
        if i >= n or seg[i] == '#':
            break
        text, dyn, unq = [], [], []
        quoted = False
        splits = False   # the word can become SEVERAL words (unquoted expansion, `"$@"`, `"$*"`)
        while i < n and seg[i] not in ' \t\r\n':
            c = seg[i]
            if c == '\\':
                quoted = True
                if i + 1 < n:
                    text.append(seg[i + 1])
                    dyn.append(False)
                    unq.append('\0')
                i += 2
            elif c == "'":
                quoted = True
                j = seg.find("'", i + 1)
                if j < 0:
                    return None
                for ch in seg[i + 1:j]:
                    text.append(ch)
                    dyn.append(False)
                    unq.append('\0')
                i = j + 1
            elif c == '"':
                quoted = True
                i += 1
                while True:
                    if i >= n:
                        return None
                    ch = seg[i]
                    if ch == '"':
                        i += 1
                        break
                    if ch == '\\' and i + 1 < n and seg[i + 1] in '$`"\\\n':
                        text.append(seg[i + 1])
                        dyn.append(False)
                        unq.append('\0')
                        i += 2
                        continue
                    text.append(ch)
                    dyn.append(ch in '$`')
                    unq.append('\0')
                    if ch == '$' and (seg[i + 1:i + 2] in ('@', '*') or seg[i + 1:i + 3] in ('{@', '{*')):
                        splits = True
                    i += 1
            elif c == '$' and seg.startswith("$'", i):
                quoted = True
                j = i + 2
                while j < n and seg[j] != "'":
                    j += 2 if seg[j] == '\\' else 1
                if j >= n:
                    return None
                for ch in _ansi_c(seg[i + 2:j]):
                    text.append(ch)
                    dyn.append(False)
                    unq.append('\0')
                i = j + 1
            else:
                text.append(c)
                dyn.append(c in '$`*?[')
                unq.append(c)
                if c in '$`*?[':
                    splits = True
                i += 1
        for m in _EXEC_BRACE.finditer(''.join(unq)):
            splits = True
            for p in range(m.start(), m.end()):
                dyn[p] = True
        words.append((''.join(text), dyn, (1 if quoted else 0) | (2 if splits else 0)))
    return words


def _exec_key_dynamic(text, dyn):
    """Is the KEY part (before the first `=`) of a `-c` / `--config-env` argument unresolvable?"""
    k = text.find('=')
    return any(dyn if k < 0 else dyn[:k])


def _exec_cfg_operands(args):
    """(sub, flags, ops, exact): `args` = the words after `config`. `exact` is False when any
    option token is not an exact table member or is dynamic (git's parser is not modelled)."""
    exact = True
    sub = None
    a = 0
    if args and args[0][0] in _EXEC_CFG_SUBCMDS:
        sub, a = args[0][0], 1
        exact = exact and not any(args[0][1])
    flags = set()
    while a < len(args):                   # option region: stops at the first operand
        t, d, _q = args[a]
        if t == '--' and not (_q & 1):
            a += 1
            break
        if not (t.startswith('-') and len(t) > 1):
            break
        name, eq, _v = t.partition('=')
        if any(d):
            exact = False
        if name in _EXEC_CFG_VALUE_OPTS:
            flags.add(name)
            a += 1 if eq else 2
        elif name in _EXEC_CFG_ZERO_OPTS and not eq:
            flags.add(name)
            a += 1
        else:
            exact = False
            a += 1
    return sub, flags, args[a:], exact


# Long options of each subcommand (positive spellings; `--[no-]x` listed as `--x`), from `git <sub>
# -h` on git 2.56. git's parse-options accepts any UNIQUE prefix of a long option, so `--t` or
# `--tem` is `--template`; a name that could mean a guarded option (exactly, or as a prefix of
# several options one of which is guarded) is treated as that option - fail closed - not by a
# length threshold.
_EXEC_LONG_OPTS = {
    'clone': frozenset((
        '--also-filter-submodules', '--bare', '--branch', '--bundle-uri', '--checkout', '--config',
        '--depth', '--dissociate', '--filter', '--hardlinks', '--ipv4', '--ipv6', '--jobs',
        '--local', '--mirror', '--no-checkout', '--no-hardlinks', '--origin', '--progress',
        '--quiet', '--recurse-submodules', '--recursive', '--ref-format', '--reference',
        '--reference-if-able', '--reject-shallow', '--remote-submodules', '--revision',
        '--separate-git-dir', '--server-option', '--shallow-exclude', '--shallow-since',
        '--shallow-submodules', '--shared', '--single-branch', '--sparse', '--tags', '--template',
        '--upload-pack', '--verbose')),
    'init': frozenset((
        '--bare', '--initial-branch', '--object-format', '--quiet', '--ref-format',
        '--separate-git-dir', '--shared', '--template')),
    'rebase': frozenset((
        '--abort', '--apply', '--autosquash', '--autostash', '--committer-date-is-author-date',
        '--continue', '--edit-todo', '--empty', '--exec', '--ff', '--force-rebase', '--fork-point',
        '--gpg-sign', '--ignore-whitespace', '--interactive', '--keep-base', '--merge', '--no-ff',
        '--no-stat', '--no-verify', '--onto', '--quiet', '--quit', '--reapply-cherry-picks',
        '--rebase-merges', '--rerere-autoupdate', '--reschedule-failed-exec', '--reset-author-date',
        '--root', '--show-current-patch', '--signoff', '--skip', '--stat', '--strategy',
        '--strategy-option', '--trailer', '--update-refs', '--verbose', '--verify', '--whitespace')),
    'difftool': frozenset((
        '--dir-diff', '--extcmd', '--gui', '--index', '--no-index', '--no-prompt', '--symlinks',
        '--tool', '--tool-help', '--trust-exit-code')),
}


def _exec_long_means(name, sub, want):
    """Can the long option spelling `name` (no `=value`) of subcommand `sub` mean `want`? An exact
    option name means only itself; otherwise every option it is a prefix of is a candidate."""
    table = _EXEC_LONG_OPTS[sub]
    if name in table:
        return name == want
    return want in table and want.startswith(name)


def _exec_config_arg_blocks(text, dyn):
    """A `key=value` config argument: blocked if the key is an exec key or cannot be resolved."""
    return _exec_key_dynamic(text, dyn) or _EXEC_KEY_FULL.match(text.partition('=')[0]) is not None


def _exec_clone_blocks(sub, words):
    """`clone -c|--config <key>=<v>` persists the key into the NEW repository's config (same
    effect as a config write there), and `clone|init --template <dir>` copies that directory's
    hooks into it (same class as init.templateDir). Short flags may be bundled / attached
    (`-qc k=v`, `-ck=v`); value-taking letters end a cluster."""
    i, n = 0, len(words)
    while i < n:
        t, d, _q = words[i]
        i += 1
        if t == '--':
            break
        if t.startswith('--'):
            name, eq, val = t.partition('=')
            if _exec_long_means(name, sub, '--template'):
                return True
            if sub == 'clone' and _exec_long_means(name, sub, '--config'):
                if eq:
                    arg = (val, d[len(name) + 1:])
                elif i < n:
                    arg = (words[i][0], words[i][1])
                    i += 1
                else:
                    continue
                if _exec_config_arg_blocks(*arg):
                    return True
        elif sub == 'clone' and t.startswith('-') and len(t) > 1:
            for idx in range(1, len(t)):
                ch = t[idx]
                if ch == 'c':
                    if idx + 1 < len(t):
                        arg = (t[idx + 1:], d[idx + 1:])
                    elif i < n:
                        arg = (words[i][0], words[i][1])
                        i += 1
                    else:
                        break
                    if _exec_config_arg_blocks(*arg):
                        return True
                    break
                if ch in 'bouj':
                    if idx + 1 >= len(t):
                        i += 1
                    break
    return False


_GIT_CARRIER_HINT = re.compile(r'submodule|rebase|difftool|bisect')
_GIT_CARRIER_FAIL = re.compile(
    r'(^|\s)git\b.*?\s(?:submodule\s+(?:\S+\s+)*?foreach|rebase|difftool|bisect\s+run)\b')


def _git_carrier_payloads(seg):
    """`(payloads, refuse)` for one segment: the shell command strings git itself runs through a
    shell for `git submodule foreach <cmd...>`, `git rebase -x|--exec <cmd>` (any position, also
    `-i -x`, `-xCMD`, `--exec=CMD`, unique abbreviations), `git difftool -x|--extcmd <cmd>` and
    `git bisect run <cmd...>`. Like a `bash -c` operand they are re-evaluated by the WHOLE engine
    (`_executable_segments`), so `git submodule foreach 'git config core.pager x'` and `git
    rebase -x 'git reset --hard'` are judged by every block, not just one. `refuse`: the segment
    names a carrier but cannot be read (unterminated quote) - the caller blocks."""
    if _GIT_CARRIER_HINT.search(seg) is None:
        return [], False
    words = _exec_split_words(seg)
    if words is None:
        return [], _GIT_CARRIER_FAIL.search(seg) is not None
    k = 0
    while k < len(words) and _ENV_ASSIGN.match(words[k][0]):
        k += 1
    if k >= len(words) or os.path.basename(words[k][0]).lower() != 'git':
        return [], False
    rest = [w for w in words[k + 1:]]
    j = 0
    while j < len(rest) and rest[j][0].startswith('-'):      # git's global options
        t = rest[j][0]
        if t in _GIT_GLOBAL_VALUE_OPTS and j + 1 < len(rest):
            j += 2
        else:
            j += 1
    if j >= len(rest):
        return [], False
    sub, args = rest[j][0], rest[j + 1:]
    out = []
    if sub in ('submodule', 'bisect'):
        a = 0
        while a < len(args) and args[a][0].startswith('-'):
            a += 1
        if a < len(args) and args[a][0] == ('foreach' if sub == 'submodule' else 'run'):
            a += 1
            if sub == 'submodule':
                while a < len(args) and args[a][0].startswith('-'):
                    a += 1
            cmd = ' '.join(w[0] for w in args[a:])
            if cmd.strip():
                out.append(cmd)
    elif sub in ('rebase', 'difftool'):
        long_want, short_val = ('--exec', 'sXC') if sub == 'rebase' else ('--extcmd', 't')
        short_cmd = 'x'
        a = 0
        while a < len(args):
            t = args[a][0]
            a += 1
            if t == '--':
                break
            if t.startswith('--'):
                name, eq, val = t.partition('=')
                if _exec_long_means(name, sub, long_want):
                    if eq:
                        out.append(val)
                    elif a < len(args):
                        out.append(args[a][0])
                        a += 1
            elif t.startswith('-') and len(t) > 1:
                for idx in range(1, len(t)):
                    ch = t[idx]
                    if ch == short_cmd:
                        if idx + 1 < len(t):
                            out.append(t[idx + 1:])
                        elif a < len(args):
                            out.append(args[a][0])
                            a += 1
                        break
                    if ch in short_val:
                        if idx + 1 >= len(t):
                            a += 1
                        break
        out = [c for c in out if c.strip()]
    return out, False


def _exec_config_cmd_blocks(seg):
    """True if `seg` runs `git config` in a way that is not a recognized read AND names an
    exec-capable key (or a rename into an exec-capable section, or a key the guard cannot
    determine statically), or passes a `-c` / `--config-env` key it cannot determine
    statically. See the block comment above for the structural rule."""
    words = _exec_split_words(seg)
    if words is None:
        return _EXEC_UNPARSEABLE.search(seg) is not None
    k = 0
    while k < len(words) and _ENV_ASSIGN.match(words[k][0]):
        k += 1
    if k >= len(words) or os.path.basename(words[k][0]).lower() != 'git':
        return False
    rest, skip = [], False
    for w in words[k + 1:]:                # drop UNQUOTED redirections: `2>/dev/null`, `> f`
        if skip:
            skip = False
        elif not (w[2] & 1) and _EXEC_REDIRECT.fullmatch(w[0]):
            skip = True
        elif not (w[2] & 1) and _EXEC_REDIRECT.match(w[0]):
            pass
        else:
            rest.append(w)
    j = 0
    while j < len(rest) and rest[j][0].startswith('-'):      # git's global options
        t, d, _q = rest[j]
        if t in ('-c', '--config-env') and j + 1 < len(rest):
            if _exec_key_dynamic(rest[j + 1][0], rest[j + 1][1]):
                return True
            j += 2
        elif t.startswith('--config-env='):
            if _exec_key_dynamic(t[13:], d[13:]):
                return True
            j += 1
        elif t.startswith('-c') and not t.startswith('--') and len(t) > 2:
            if _exec_key_dynamic(t[2:], d[2:]):
                return True
            j += 1
        elif t in _GIT_GLOBAL_VALUE_OPTS and j + 1 < len(rest):
            j += 2
        else:
            j += 1
    if j < len(rest) and rest[j][0] in ('clone', 'init'):
        return _exec_clone_blocks(rest[j][0], rest[j + 1:])
    if j >= len(rest) or rest[j][0] != 'config':
        return False
    args = rest[j + 1:]
    sub, flags, ops, exact = _exec_cfg_operands(args)
    rename = sub == 'rename-section' or '--rename-section' in flags
    if exact and not rename:
        if sub in _EXEC_CFG_READ_SUBCMDS or flags & _EXEC_CFG_READ_FLAGS:
            return False                   # exact read / unset / list / remove-section
        if sub is None and len(ops) <= 1 and not any(o[2] & 2 for o in ops):
            return False                   # a bare, non-splitting key is a read
    if exact and rename:                   # operands only: flags may sit between old and new
        pos, a = [], 0
        while a < len(args):
            t, _d, _q = args[a]
            if t.startswith('-') and len(t) > 1:
                name = t.partition('=')[0]
                if name in _EXEC_CFG_VALUE_OPTS:
                    a += 1 if '=' in t else 2
                    continue
                if name not in _EXEC_CFG_ZERO_OPTS or '=' in t:
                    exact = False
            else:
                pos.append(args[a])
            a += 1
        if pos and pos[0][0] == 'rename-section':
            pos = pos[1:]
        if exact:
            return len(pos) >= 2 and (any(pos[1][1]) or _EXEC_SECTION_FULL.match(pos[1][0]) is not None)
    # Not a recognized read: any exec key among the words, a section among them when a rename
    # is possible, or a key position that is dynamic.
    for t, _d, _q in args:
        if _EXEC_KEY_FULL.match(t) is not None:
            return True
        if (rename or not exact) and _EXEC_SECTION_FULL.match(t) is not None:
            return True
    if not exact:
        return any(any(d) for _t, d, _q in args)
    if len(ops) == 1 and ops[0][2] & 2:    # `$KV` / `"$@"` word-splits into key + value
        return True
    return any(any(d) for _t, d, _q in ops[:-1])


# (c) env-var injection on a git command. `GIT_CONFIG_KEY_<n>=<key>` (the
# GIT_CONFIG_COUNT/KEY/VALUE trio), `GIT_CONFIG_PARAMETERS` naming a key
# anywhere in its (possibly quoted) value, and `GIT_CONFIG_GLOBAL` /
# `GIT_CONFIG_SYSTEM` pointed anywhere but /dev/null (loads an arbitrary config
# file). Anchored on a preceding blank so `rg 'GIT_CONFIG_KEY_0=core.pager'`
# (quote before the name) is data, tied to the segment mentioning `git` by a
# trailing lookahead (the assignment sits in the segment that runs git).
_GIT_WORD_AFTER = r'(?=.*(?:^|[\s/])git\b)'
_GC_ENV_KEY_BLOCK = re.compile(
    r'(?:^|\s)GIT_CONFIG_KEY_\d+=' + _Q + _GC_CONFIG_KEY + _Q + r'(?=\s|$)' + _GIT_WORD_AFTER
)
_EXEC_ENV_KEY_BLOCK = re.compile(
    r'(?:^|\s)GIT_CONFIG_KEY_\d+=' + _Q + _EXEC_CONFIG_KEY + _Q + r'(?=\s|$)' + _GIT_WORD_AFTER
)
# The value is searched WITHOUT leaving its own shell word: a run of non-blank
# characters, or the inside of one double- / single-quoted string (git's own
# format is `'k'='v' 'k2'='v2'`, i.e. blanks inside the quotes).
def _params_block(key):
    return re.compile(
        r'(?:^|\s)GIT_CONFIG_PARAMETERS=(?:"[^"]*?|\'[^\']*?|[^\s"\']*?)'
        r'''(?<![\w.-])["']*''' + key + r'''(?=["'=\s]|$)''' + _GIT_WORD_AFTER
    )


_GC_ENV_PARAMETERS_BLOCK = _params_block(_GC_CONFIG_KEY)
_EXEC_ENV_PARAMETERS_BLOCK = _params_block(_EXEC_CONFIG_KEY)
_EXEC_ENV_FILE_BLOCK = re.compile(
    r'(?:^|\s)GIT_CONFIG_(?:GLOBAL|SYSTEM)='
    r'(?!\$?' + _Q + r'/dev/null' + _Q + r'(?:\s|$))(?!\$?' + _Q + r'(?:\s|$))\S' + _GIT_WORD_AFTER
)
_GIT_CONFIG_EXEC_BLOCKS = (
    _EXEC_CINJECT_BLOCK, _EXEC_ENV_KEY_BLOCK, _EXEC_ENV_PARAMETERS_BLOCK, _EXEC_ENV_FILE_BLOCK,
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
    r'(?=.*' + _FORCE_FLAG_LOOKAHEAD + r')'      # dry-run exemption: `_dry_run_block`
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
_BRANCH_D_LOOKAHEAD = r'(?:^|\s)' + _flag_cluster('D') + r'\b'
_BRANCH_M_LOOKAHEAD = r'(?:^|\s)' + _flag_cluster('M') + r'\b'
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
# match), `git worktree list`. (`git worktree prune` WAS in this list; it is no longer —
# 2026-10-07 U6a-2: it follows an agent-planted symlinked `.git/worktrees/<id>` entry and
# empties the target, see `_WORKTREE_PRUNE_BLOCK` below. `-n`/`--dry-run` stays allowed.)
_WORKTREE_ALLOW = re.compile(
    r'(^|&&\s*)CAST_WORKTREE_OK=1\s+([A-Za-z_][A-Za-z0-9_]*=\S+\s+)*git' + _GIT_OPTS + r'\s+worktree\s+remove\b'
)
_WORKTREE_BLOCK = re.compile(
    r'(^|\s)git' + _GIT_OPTS + r'\s+worktree\s+remove\b(?=.*' + _FORCE_FLAG_LOOKAHEAD + r')'
)

# --- git worktree prune block + symlinked-worktree-entry stateful check (U6a-2) -------------
# Probed 2026-10-04 (hazard E1; see the `cast_git_safe` header in scripts/cast-hook-lib.sh):
# `git worktree prune` — and therefore `git gc`, `git gc --auto` and `git maintenance run` —
# FOLLOWS a symlinked `.git/worktrees/<id>` entry and EMPTIES its target; `gc.worktreePruneExpire=
# never` does not stop it. Dry runs (`-n`/`--dry-run`, clustered `-nv` too) are the only safe
# form. Hatch: CAST_WORKTREE_OK=1 (existing, worktree family).
_WORKTREE_PRUNE_ALLOW = re.compile(
    r'(^|&&\s*)CAST_WORKTREE_OK=1\s+([A-Za-z_][A-Za-z0-9_]*=\S+\s+)*git' + _GIT_OPTS
    + r'\s+worktree\s+prune(?![\w-])'
)
_WORKTREE_PRUNE_BLOCK = re.compile(
    r'(^|\s)git' + _GIT_OPTS + r'\s+worktree\s+prune(?![\w-])'   # exemption: `_dry_run_block`
)
# Any git op, any hatched segment: `CAST_WORKTREE_OK=1 git ...` (generic, like `_GC_HATCH_ALLOW`).
_WORKTREE_HATCH_ALLOW = re.compile(
    r'(^|&&\s*)CAST_WORKTREE_OK=1\s+([A-Za-z_][A-Za-z0-9_]*=\S+\s+)*git\b'
)
_MAINTENANCE_ALLOW = re.compile(
    r'(^|&&\s*)CAST_GC_OK=1\s+([A-Za-z_][A-Za-z0-9_]*=\S+\s+)*git' + _GIT_OPTS
    + r'\s+maintenance\s+run(?![\w-])'
)

# The stateful half. The static blocks above cannot protect a repo that ALREADY holds a planted
# symlink: git runs `gc --auto` implicitly after commit/merge/fetch/rebase/..., so ANY git op
# there is the hazard. A pure-filesystem check (no subprocess: the guard already spawns git for
# update-ref, and a git run inside an agent-written repo is itself a sandbox-escape surface):
#   * start dir = cwd with each global `-C <dir>` applied in order (relative to the previous);
#     `--git-dir=<d>` / `GIT_DIR=<d>` / `GIT_COMMON_DIR=<d>` in the segment name a git dir directly;
#   * walk up for `<d>/.git` (a dir, or a `gitdir: <path>` file = linked worktree) or a bare repo
#     (`HEAD` + `objects/` + `refs/`); the common dir is the git dir's `commondir` file if present;
#   * hazard = `<common>/worktrees` is a symlink, an entry in it is a symlink, or an entry's
#     `gitdir` file is a symlink.
# FAIL-OPEN on errors listing the dir (EACCES/ENOTDIR/...): git runs as the same uid and cannot
# traverse what we cannot, so there is nothing it could prune through, and blocking every git op
# on an unreadable dir would be a lockout with no safety gain. FAIL-CLOSED when the dir holds more
# than `_MAX_WORKTREE_ENTRIES` entries: an unbounded listing is a latency lever, and a repo with
# 1000+ linked worktrees is not a real workflow (hatch: CAST_WORKTREE_OK=1). Cost: one lstat +
# one scandir (+ one lstat per entry), memoised per `_git_evaluate` call.
# KNOWN LIMITATIONS: a dynamic `-C "$DIR"` / `cd $D`, `cd -`, `popd`, a `GIT_DIR` exported in an
# EARLIER segment, and a symlink planted in the same command line by anything but `ln -s` are not
# resolved (same class as the dynamic command word); `GIT_CEILING_DIRECTORIES` / filesystem-
# boundary discovery rules are not modelled. A git segment is checked against every literal
# directory the command has `cd`-ed into so far (see `_DirTracker`).
_MAX_WORKTREE_ENTRIES = 1024
# Resolution reads the RAW tokenized prefix of the segment (shlex, posix, lazily, at most
# `_MAX_PREFIX_CHARS` chars / `_MAX_PREFIX_TOKENS` tokens) -- never the normalised variant, which
# drops `-C` -- so quoting, `g\\it`, `/usr/bin/git` (the git WORD is any token whose basename is
# `git`), `env -C <dir>` and every git global option resolve the way the shell+git would.
_MAX_PREFIX_CHARS = 8192
_MAX_PREFIX_TOKENS = 128
_MAX_TRACKED_DIRS = 64
# N1: `cd d0; cd d1; ...` NESTS, so every realpath/normpath walked an ever-longer path (1.7 s at
# 20 KB, 12 s at 50 KB). At most this many literal cd/pushd targets are tracked per command and a
# tracked path may not exceed `_MAX_TRACKED_PATH`; past either the directory is UNKNOWN
# (`_DirTracker.overflow`) and a git segment fails CLOSED (`too complex`), O(1) per segment.
_MAX_TRACKED_CDS = 64
_MAX_TRACKED_PATH = 4096
_CUT = 'cut'    # `_git_invocation_dirs`: the prefix cap was hit inside what looks like a git invocation
# git's real global-option grammar (git.c handle_options): these take a VALUE as the next word
# (`--exec-path` takes one only as `--exec-path=<v>`); every other dash word is zero-arg.
_GIT_VALUE_OPTS = frozenset((
    '-C', '-c', '--git-dir', '--work-tree', '--namespace', '--config-env', '--super-prefix',
    '--list-cmds', '--attr-source'))
_CTRL_WORDS = frozenset(('do', 'then', 'else', 'elif', 'if', 'while', 'until', 'time', '{', '(', '!'))
_CTRL_STRIP = ' \t({!'
# Words that may legitimately precede the git word; used only to decide whether a prefix that hit
# the cap before any git word still LOOKS like the start of a git invocation (N2).
_PREFIX_WRAPPERS = frozenset(('env', 'command', 'exec', 'sudo', 'doas', 'nohup', 'time', 'nice',
                              'builtin', 'xargs', 'stdbuf', 'timeout', 'ionice', 'setsid'))


def _prefix_tokens(text: str, state=None):
    """Lazily yield the leading shell words of `text`. Stops silently at a quote error. When `state`
    (a dict) is given, `state['cut']` is set if the words ran out for a reason other than the
    text really ending: the token cap or the char cap -- i.e. the caller has NOT
    seen the whole command prefix (a consumer that stops early never triggers it)."""
    stripped = text.lstrip(_CTRL_STRIP)
    truncated = len(stripped) > _MAX_PREFIX_CHARS
    lex = shlex.shlex(stripped[:_MAX_PREFIX_CHARS], posix=True)
    lex.whitespace_split = True
    lex.commenters = ''
    try:
        for i, tok in enumerate(lex):
            if i >= _MAX_PREFIX_TOKENS:
                if state is not None:
                    state['cut'] = True
                return
            yield tok
    except ValueError:
        # An unbalanced quote is NOT a cut by itself: segments are split on `&&`/`;` even inside
        # quotes (`bash -c "cd P && git status"` -> `git status"`), so it is routine and the shell
        # parser elsewhere refuses genuinely unparseable commands. Under the char cap it is a cut.
        if truncated and state is not None:
            state['cut'] = True
        return
    if truncated and state is not None:
        state['cut'] = True


def _git_invocation_dirs(text: str):
    """(chdirs, git_dirs, common_dirs) for the first git word in the prefix of `text`, else None.
    `chdirs` = `env -C|--chdir <d>` then git's own `-C <d>`, in order; `git_dirs` = `--git-dir`
    (either spelling) and `GIT_DIR=`; `common_dirs` = `GIT_COMMON_DIR=`."""
    chdirs, git_dirs, commons = [], [], []
    state = {}
    toks = _prefix_tokens(text, state)
    in_env = False
    prefix_like = True
    for tok in toks:
        if _ENV_ASSIGN.match(tok):
            key, _, val = tok.partition('=')
            if key == 'GIT_DIR':
                git_dirs.append(val)
            elif key == 'GIT_COMMON_DIR':
                commons.append(val)
            continue
        if os.path.basename(tok) == 'git':
            break
        if os.path.basename(tok) == 'env':
            in_env = True
        elif in_env:
            if tok in ('-C', '--chdir'):
                val = next(toks, None)
                if val is None:
                    return None
                chdirs.append(val)
            elif tok.startswith('--chdir='):
                chdirs.append(tok[len('--chdir='):])
            elif tok in ('-u', '--unset', '-S', '--split-string'):
                next(toks, None)
        if not (tok in _CTRL_WORDS or tok.startswith('-') or os.path.basename(tok) in _PREFIX_WRAPPERS):
            prefix_like = False
    else:
        # N2: the words ran out at a cap before any git word. Only a prefix made of assignments /
        # wrappers / options (`FOO=1 x300`) is treated as a git invocation we could not finish
        # reading; a long `echo ...` mentioning the word is not.
        return _CUT if (state.get('cut') and prefix_like) else None
    for tok in toks:
        if tok == '--git-dir':
            val = next(toks, None)
            if val is not None:
                git_dirs.append(val)
        elif tok.startswith('--git-dir='):
            git_dirs.append(tok[len('--git-dir='):])
        elif tok == '-C':
            val = next(toks, None)
            if val is not None:
                chdirs.append(val)
        elif tok in _GIT_VALUE_OPTS:
            next(toks, None)
        elif tok.startswith('-') and tok != '-':
            continue
        else:
            break
    else:
        if state.get('cut'):
            return _CUT      # N2: the options never ended inside the cap
    return chdirs, git_dirs, commons


class _DirTracker:
    """The directories a command line has `cd`/`pushd`-ed into so far (literal targets only),
    in segment order. A git segment is checked against EVERY directory visited so far (a
    deliberate over-approximation: a subshell `(cd P; ...)` or a later `cd ../Q` do not forget
    P -- the cost is a possible extra block in an already-poisoned repo, never a miss). NOT
    resolved: a dynamic target (`cd $D`, `cd "$(...)"`, a glob), `cd -`, `popd`, `CDPATH`."""
    __slots__ = ('cur', 'visited', 'cds', 'overflow')

    def __init__(self):
        try:
            cwd = os.getcwd()
        except OSError:
            cwd = ''
        self.cur = cwd
        self.visited = [cwd] if cwd else []
        self.cds = 0
        self.overflow = False

    def _add(self, d: str):
        if d and d not in self.visited and len(self.visited) < _MAX_TRACKED_DIRS:
            self.visited.append(d)

    def observe(self, seg: str):
        if self.overflow or ('cd' not in seg and 'pushd' not in seg):
            return
        toks = _prefix_tokens(seg)
        word = None
        for tok in toks:
            if _ENV_ASSIGN.match(tok) or tok in _CTRL_WORDS:
                continue
            word = tok
            break
        if word in ('builtin', 'command'):
            word = next(toks, None)
        if word not in ('cd', 'pushd'):
            return
        target = None
        for tok in toks:
            if tok.startswith('-') and tok != '-':
                continue            # `-P`, `-L`, `--`
            target = tok
            break
        if word == 'cd' and target is None:
            target = '~'
        if (target is None or target == '-' or target[:1] == '+'
                or any(ch in target for ch in '$`*?[')):
            return
        self.cds += 1
        t = os.path.expanduser(target)
        new = os.path.normpath(os.path.join(self.cur, t)) if self.cur else t
        if self.cds > _MAX_TRACKED_CDS or len(new) > _MAX_TRACKED_PATH:
            self.overflow = True     # N1: directory unknown from here on; see `_MAX_TRACKED_CDS`
            return
        self.cur = new
        self._add(new)
        real = os.path.realpath(new)
        if real != new:
            self._add(real)


def _read_small(path: str, limit: int = 4096) -> str:
    try:
        with open(path, 'r', encoding='utf-8', errors='replace') as fh:
            return fh.read(limit).strip()
    except OSError:
        return ''


def _find_git_dir(start: str) -> str:
    """The git dir git would discover from `start` ('' if none): `<d>/.git` as a dir, or as a
    `gitdir: <path>` file (linked worktree / submodule), or `<d>` itself when it is a bare repo."""
    d = start
    for _ in range(128):
        dotgit = os.path.join(d, '.git')
        try:
            st = os.stat(dotgit)
        except OSError:
            st = None
        if st is not None:
            if stat.S_ISDIR(st.st_mode):
                return dotgit
            if stat.S_ISREG(st.st_mode):
                text = _read_small(dotgit)
                if text.startswith('gitdir:'):
                    return os.path.normpath(os.path.join(d, text[len('gitdir:'):].strip()))
                return ''
        if (os.path.isfile(os.path.join(d, 'HEAD')) and os.path.isdir(os.path.join(d, 'objects'))
                and os.path.isdir(os.path.join(d, 'refs'))):
            return d
        parent = os.path.dirname(d)
        if parent == d:
            return ''
        d = parent
    return ''


def _common_dir_of(git_dir: str) -> str:
    rel = _read_small(os.path.join(git_dir, 'commondir'))
    return os.path.normpath(os.path.join(git_dir, rel)) if rel else git_dir


def _resolve_invocation(chdirs, git_dirs, commons, tracker) -> list:
    out, seen = [], set()

    def add(path: str):
        if path not in seen:
            seen.add(path)
            out.append(path)

    bases = [tracker.cur] if chdirs else (list(tracker.visited) or [''])
    for base in bases:
        start = base
        for c in chdirs:
            start = os.path.join(start, os.path.expanduser(c)) if start else os.path.expanduser(c)
        start = os.path.normpath(start) if start else ''
        for g in commons:
            add(os.path.normpath(os.path.join(start, os.path.expanduser(g))))
        if git_dirs:
            for g in git_dirs:
                add(_common_dir_of(os.path.normpath(os.path.join(start, os.path.expanduser(g)))))
        elif start:
            gd = _memoized(('gitdir', start), lambda s=start: _find_git_dir(s))
            if gd:
                add(_common_dir_of(gd))
    return out


def _worktree_common_dirs(texts, tracker):
    """(common dirs, unresolvable) for the git invocation(s) in `texts`. `unresolvable` is True when
    the repo cannot be located with certainty: the prefix cap was hit (N2) or the tracker overflowed
    (N1). Memoised per `_git_evaluate` call on everything the answer depends on."""
    out, seen, unresolvable = [], set(), False
    for text in texts:
        # Pure in `text`, and padding repeats the same segment thousands of times: lex it once.
        inv = _memoized(('wtinv', text), lambda t=text: _git_invocation_dirs(t))
        if inv is None:
            continue
        if inv is _CUT or tracker.overflow:
            unresolvable = True
            continue
        chdirs, git_dirs, commons = inv
        key = ('wtdirs', tuple(chdirs), tuple(git_dirs), tuple(commons), tracker.cur,
               tuple(tracker.visited))
        for path in _memoized(key, lambda: _resolve_invocation(chdirs, git_dirs, commons, tracker)):
            if path not in seen:
                seen.add(path)
                out.append(path)
    return out, unresolvable


def _worktree_symlink_hazard_uncached(common: str):
    """(kind, path) for the first hazard under `<common>/worktrees`, else None. See above."""
    wt = os.path.join(common, 'worktrees')
    try:
        st = os.lstat(wt)
        if stat.S_ISLNK(st.st_mode):
            return ('dir', wt)
        if not stat.S_ISDIR(st.st_mode):
            return None
        n = 0
        with os.scandir(wt) as it:
            for entry in it:
                n += 1
                if n > _MAX_WORKTREE_ENTRIES:
                    return ('over', wt)
                if entry.is_symlink():
                    return ('entry', entry.path)
                gd = os.path.join(entry.path, 'gitdir')
                try:
                    if stat.S_ISLNK(os.lstat(gd).st_mode):
                        return ('gitdir', gd)
                except OSError:
                    pass
    except OSError:
        return None
    return None


def _worktree_symlink_hazard(texts, tracker):
    """(kind, path) if the repo a git segment operates on holds a symlinked worktree entry.
    Memoised per `_git_evaluate` call (see `_EVAL_MEMO`). Never raises (fails open)."""
    try:
        dirs, unresolvable = _worktree_common_dirs(texts, tracker)
        for common in dirs:
            hz = _memoized(('wtsym', common), lambda c=common: _worktree_symlink_hazard_uncached(c))
            if hz:
                return hz
        if unresolvable:
            return ('complex', '')
    except Exception:
        return None
    return None


# F5 (U6a-2 security): the PLANT itself. Blocks `ln -s ... <path under a worktrees dir>` (any
# token -- the link name or, with `-t`/`--target-directory=`, its directory -- resolved against the
# TRACKED cwd, so `cd .git/worktrees && ln -s /v x` is caught), with or without a git word in the
# command: agents never create symlinks there. A `worktrees` component counts when it sits under
# `.git` / `*.git` / `.git/modules/<name>` (case-insensitive, `//` `/./` `..` collapsed) or under a
# directory that is a git dir on disk (a bare repo of any name). Deliberately NOT "any `ln -s`
# under `.git/`" (legitimate hook / info symlinks live there). Hatch: CAST_WORKTREE_OK=1. NOT
# covered (documented): the same plant by `mv` / `cp -P` / `python -c os.symlink`, a spelled
# `.g\\it` path, `$VAR` paths, and a cwd that is itself unknown (tracker overflow); the stateful
# check still blocks every later git command in that repo.
_LN_WORD = re.compile(r'(?<![\w.-])ln(?![\w.-])')
_LN_WRAPPERS = frozenset(('sudo', 'doas', 'env', 'command', 'exec', 'nohup', 'time', 'nice', 'builtin'))
_WORKTREE_LN_ALLOW = re.compile(
    r'(^|&&\s*)CAST_WORKTREE_OK=1\s+([A-Za-z_][A-Za-z0-9_]*=\S+\s+)*(?:\S*/)?ln\b'
)


def _looks_like_git_dir(path: str) -> bool:
    return (os.path.isfile(os.path.join(path, 'HEAD')) and os.path.isdir(os.path.join(path, 'objects'))
            and os.path.isdir(os.path.join(path, 'refs')))


def _names_a_worktrees_dir(token: str, cwd: str) -> bool:
    """True if `token` (a path, resolved against `cwd`; lowercased, `//` `/./` `..` collapsed --
    macOS is case-insensitive, so `.GIT` is a real git dir there) has a `worktrees` component
    directly under a `.git` / `*.git` component or a `.git/modules/<name>`, or directly under a
    directory that IS a git dir on disk (a bare repo named anything)."""
    path = os.path.normpath(os.path.join(cwd, os.path.expanduser(token))) if cwd else os.path.normpath(token)
    comps = [c for c in path.split('/') if c]
    low = [c.lower() for c in comps]
    for i, c in enumerate(low):
        if c != 'worktrees' or i == 0:
            continue
        if low[i - 1].endswith('.git'):
            return True
        if i >= 3 and low[i - 2] == 'modules' and low[i - 3].endswith('.git'):
            return True
        if _looks_like_git_dir('/' + '/'.join(comps[:i])):
            return True
    return False


def _plants_worktrees_symlink(seg: str, tracker) -> bool:
    if _LN_WORD.search(seg) is None:
        return False
    try:
        toks = list(_prefix_tokens(seg))
    except Exception:
        return False
    for i, tok in enumerate(toks):
        if _ENV_ASSIGN.match(tok) or tok in _CTRL_WORDS or tok.startswith('-') \
                or os.path.basename(tok) in _LN_WRAPPERS:
            continue
        if os.path.basename(tok) != 'ln':
            return False
        rest = toks[i + 1:]
        if not any(t == '--symbolic' or (t.startswith('-') and not t.startswith('--') and 's' in t)
                   for t in rest):
            return False
        for t in rest:
            if t.startswith('-'):
                if '=' not in t:
                    continue
                t = t.split('=', 1)[1]          # `--target-directory=<dir>`
            if t and _names_a_worktrees_dir(t, tracker.cur):
                return True
        return False
    return False


def _worktree_hazard_msg(hazard) -> str:
    kind, path = hazard
    if kind == 'complex':
        return (
            f'**[CAST]** This git command is blocked: it is too complex to tell which repository it '
            f'runs in (more than {_MAX_TRACKED_CDS} literal `cd` targets in one command, or a prefix '
            f'longer than {_MAX_PREFIX_TOKENS} words / {_MAX_PREFIX_CHARS} chars before the subcommand), '
            f'so it cannot be checked for a symlinked `.git/worktrees/<id>` entry (`git worktree prune` '
            f'-- run by gc, git\'s implicit `gc --auto` and `git maintenance run` -- follows one and '
            f'EMPTIES its target). Simplify it (`git -C <dir> ...`, fewer `cd`s), or use '
            f'`CAST_WORKTREE_OK=1 git ...` (document why).'
        )
    shown = ''.join(ch if ch.isprintable() else '?' for ch in path)[:200]
    if kind == 'over':
        what = (f'`{shown}` holds more than {_MAX_WORKTREE_ENTRIES} entries, too many to verify '
                f'that none is a symlink')
        fix = 'Remove the stale entries (`git worktree prune -n` lists them).'
    else:
        what = {'dir': f'`{shown}` is itself a SYMLINK',
                'entry': f'`{shown}` is a SYMLINK',
                'gitdir': f'`{shown}` (an entry\'s gitdir file) is a SYMLINK'}[kind]
        fix = (f'Remove it WITHOUT following it: `unlink {shlex.quote(shown)}` (never `rm -r` on '
               f'the entry), after checking where it points (`readlink`).')
    return (
        f'**[CAST]** Every git command is blocked in this repo: {what}. `git worktree prune` — which '
        f'`git gc`, git\'s implicit `gc --auto` (after commit/merge/fetch/rebase/...) and `git '
        f'maintenance run` all execute — FOLLOWS such an entry and EMPTIES its target (probed '
        f'2026-10-04; `gc.worktreePruneExpire=never` does not stop it). Nothing legitimate creates '
        f'one. {fix} If you must run git meanwhile, use `CAST_WORKTREE_OK=1 git ...` (document why).'
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
        # Memoised per `_git_evaluate` call (see `_EVAL_MEMO`): N `update-ref` segments naming
        # the same ref are one spawn, not N (each up to 5 s).
        return _memoized(
            ('verify', tuple(cmd)),
            lambda: subprocess.run(cmd, capture_output=True, text=True, timeout=5).returncode == 0)
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
    "If you genuinely need an explicit prune, use "
    "`CAST_GC_OK=1 git gc --prune=<value>` (document why)."
)
_GC_ANY_MSG = (
    "**[CAST]** Raw `git gc` blocked (every form, `--auto` included) — gc runs "
    "`git worktree prune`, which FOLLOWS a symlinked `.git/worktrees/<id>` entry "
    "and EMPTIES its target (probed 2026-10-04; `gc.worktreePruneExpire=never` "
    "does not stop it). Nothing here can see a symlink planted in the same "
    "command line, so the command is blocked outright. If you genuinely need a "
    "gc, check `.git/worktrees/` for symlinks first, then use "
    "`CAST_GC_OK=1 git gc ...` (document why)."
)
_MAINTENANCE_MSG = (
    "**[CAST]** `git maintenance run` blocked (any task) — its default and "
    "`--task=gc` tasks run `git worktree prune`, which FOLLOWS a symlinked "
    "`.git/worktrees/<id>` entry and EMPTIES its target (probed 2026-10-04). "
    "`git maintenance start|register|stop|unregister` are unaffected. If you "
    "genuinely need it, check `.git/worktrees/` for symlinks first, then use "
    "`CAST_GC_OK=1 git maintenance run ...` (document why)."
)
_WORKTREE_PLANT_MSG = (
    "**[CAST]** `ln -s` into a `.git/worktrees/` directory blocked — `git worktree prune` (run by "
    "`git gc`, git's implicit `gc --auto` and `git maintenance run`) FOLLOWS a symlinked worktree "
    "entry and EMPTIES its target (probed 2026-10-04). Nothing legitimate creates one. If you "
    "genuinely need it, use `CAST_WORKTREE_OK=1 ln -s ...` (document why)."
)
_WORKTREE_PRUNE_MSG = (
    "**[CAST]** `git worktree prune` blocked (`-n`/`--dry-run` is exempt) — it "
    "FOLLOWS a symlinked `.git/worktrees/<id>` entry and EMPTIES its target "
    "(probed 2026-10-04; `gc.worktreePruneExpire=never` does not stop it). If "
    "you genuinely need to prune, check `.git/worktrees/` for symlinks first, "
    "then use `CAST_WORKTREE_OK=1 git worktree prune` (document why)."
)
_PRUNE_MSG = (
    "**[CAST]** Raw `git prune` blocked (dry runs via `-n`/`--dry-run` are "
    "exempt) — it deletes unreachable objects with no grace period at all, "
    "closing off the same 2026-08-17 dangling-blob recovery path (more "
    "destructive than `git gc --prune=now`, which still respects "
    "`gc.pruneExpire`). `git prune-packed` and `git remote prune` are "
    "unaffected (`git worktree prune` has its own block). If you genuinely "
    "need to prune, use "
    "`CAST_PRUNE_OK=1 git prune ...` (document why)."
)
_GC_CINJECT_MSG = (
    "**[CAST]** Raw `git -c gc.pruneExpire=<value>` / `-c gc.reflogExpire=<value>` "
    "/ `-c gc.reflogExpireUnreachable=<value>` blocked (key match is "
    "case-insensitive; ANY value blocks, including `never`) — this is a "
    "config-layer bypass of the reflog/gc/prune blocks above: it reaches the "
    "exact same dangling-object/reflog recovery-path destruction with no "
    "`--prune=`/`expire`/`prune` token on the line for those checks to key "
    "on. The same key via `--config-env=<key>=ENV` or `GIT_CONFIG_KEY_<n>=<key>` "
    "(env-var injection) is blocked here too. If you genuinely need to set "
    "one of these inline, use `CAST_GC_OK=1 git -c gc.pruneExpire=<value> ...` "
    "(document why)."
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
    "closing the last route into it. The same editor session can equally set "
    "an exec key (`core.fsmonitor`, `core.hooksPath`, `alias.*`, ...), so it can "
    "set EITHER kind of key and EITHER hatch allows it. If you genuinely need to "
    "edit git config interactively, use `CAST_GC_OK=1 git config --edit` or "
    "`CAST_GIT_CONFIG_OK=1 git config --edit` (document why)."
)
_GIT_CONFIG_EXEC_MSG = (
    "**[CAST]** Setting a git config key that makes git EXECUTE a program or "
    "load other config is blocked (key match is case-insensitive; ANY value "
    "blocks, including `true`/empty; reads via `--get`/`list`/a bare key are "
    "unaffected). Covers `git config` writes (any scope, `--file`, `--add`, "
    "`set`, `rename-section` into such a section), inline `-c <key>[=v]` / "
    "`--config-env=<key>=ENV`, `clone -c|--config <key>=<v>` / `clone|init "
    "--template`, and `GIT_CONFIG_KEY_<n>=<key>` / "
    "`GIT_CONFIG_PARAMETERS` / `GIT_CONFIG_GLOBAL|SYSTEM=<file>` env "
    "injection. Key class: `core.fsmonitor|hooksPath|pager|editor|sshCommand|"
    "askPass|gitProxy`, `pager.*`, `alias.*`, `filter.*.clean|smudge|process`, "
    "`diff.*.command|textconv`, `merge.*.driver`, `gpg*.program`, "
    "`credential*.helper`, `remote.*.uploadpack|receivepack|vcs`, "
    "`include[If].path`, `url.*.insteadOf` (`ext::`), `protocol.*.allow`, "
    "`submodule.*.update`, ... A repo's `.git/config` runs in Ed's UNSANDBOXED "
    "terminal and in CAST hooks on the next `git status`/`log`/`diff`, so an "
    "agent must not plant one. If you genuinely need it, use "
    "`CAST_GIT_CONFIG_OK=1 git config <key> <value>` (document why)."
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


# --------------------------------------------------------------------------
# Write/Edit: agent-status TTL sweep + policy engine
# --------------------------------------------------------------------------
def _ttl_sweep_agent_status() -> None:
    """Delete agent-status/*.json older than 120 min (mirrors `find -mmin +120 -delete`).

    Same trust boundary as the gate reader: the directory is the fixed
    ``~/.claude/agent-status`` (NOT the env-steerable CLAUDE_DIR), and it must be a REAL
    directory per ``os.lstat`` — a symlinked agent-status dir is refused, so the sweep can
    never delete files in the symlink's target. Each entry is lstat'ed and only REGULAR
    files are unlinked (a symlink entry is never followed or removed through its target).
    At most `_STATUS_MAX_FILES` directory entries are examined per call (it runs on every
    Write/Edit). Never raises.
    """
    try:
        status_dir = os.path.expanduser('~/.claude/agent-status')
        if not stat.S_ISDIR(os.lstat(status_dir).st_mode):
            return
        now = datetime.datetime.now(datetime.timezone.utc).timestamp()
        for scanned, fname in enumerate(os.listdir(status_dir)):
            if scanned >= _STATUS_MAX_FILES:
                break  # bounded work: this runs on every Write/Edit; the rest waits for a later sweep
            if not fname.endswith('.json'):
                continue
            fpath = os.path.join(status_dir, fname)
            try:
                st = os.lstat(fpath)
                if not stat.S_ISREG(st.st_mode):
                    continue
                age_min = int((now - st.st_mtime) / 60)
                if age_min > 120:
                    os.remove(fpath)
            except Exception:
                pass
    except Exception:
        pass


_STATUS_MAX_FILES = 2000          # more candidate records than this -> fail closed (bounded work)
_STATUS_MAX_BYTES = 65536         # a record larger than this is skipped
_STATUS_FUTURE_SKEW = 60          # mtime more than this far in the future is ignored
_SESSION_ID_RE = re.compile(r'[A-Za-z0-9-]{1,64}')  # the shape the writer stores (fullmatch only)


def _read_status_record(fpath: str):
    """Return (mtime, data) for a regular, fresh-enough JSON status record, or None.

    lstat first (symlinks and non-regular files are skipped), then open with
    O_NOFOLLOW|O_NONBLOCK and fstat the descriptor so a swap between the lstat and
    the open cannot hand the gate a FIFO/device/symlink. Never raises: ANY failure to
    obtain a record — including RecursionError / MemoryError from `json.loads` on a
    deeply nested junk file (CPython 3.9 trips near ~1000 levels, well under the size
    cap) — is "no record" (None). A reader error that escaped would reach `evaluate()`'s
    blanket fail-open and silently disable EVERY policy block.
    """
    try:
        st = os.lstat(fpath)
        if not stat.S_ISREG(st.st_mode) or st.st_size > _STATUS_MAX_BYTES:
            return None
        fd = os.open(fpath, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except Exception:
        return None
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            return None
        raw = os.read(fd, _STATUS_MAX_BYTES + 1)
    except Exception:
        return None
    finally:
        try:
            os.close(fd)
        except OSError:
            pass
    if len(raw) > _STATUS_MAX_BYTES:
        return None
    try:
        data = json.loads(raw.decode('utf-8'))
    except Exception:
        return None
    if not isinstance(data, dict):
        return None
    return st.st_mtime, data


def _agent_completed_this_session(required_agent: str, agent_status_dir: str, now: float,
                                  session_id: str) -> bool:
    """A `required_agent`-typed subagent dispatched in THIS session finished with a
    passing verdict: the newest fresh matching record reports DONE / DONE_WITH_CONCERNS.

    TRUST MODEL. Only the CONTENT fields the SubagentStop hook writes are trusted:
    ``session_id`` (the hook payload's session) and ``agent_type`` (the TRUSTED roster
    type read from Claude Code's own sidecar — absent from the record when the sidecar
    could not vouch for it). A record counts only when BOTH equal the values asked for
    (exact string equality — no prefix, case or suffix matching). The filename and the
    record's ``agent`` field are display-only and are never consulted, so neither a
    ``<agent>-…`` / ``<agent>__…`` filename nor a hand-written ``agent`` value can unblock
    anything. Legacy records with no ``session_id``/``agent_type`` never match, and a
    gate call without a session_id (``session_id == ''``) fails closed. This replaces the
    2026-08-18 filename-prefix rule (``<agent>-`` / ``<agent>__``), which any terminal could
    satisfy for any session.

    SESSION ID SHAPE. The writer stores the session id sanitized to ``[A-Za-z0-9-]{1,64}``.
    The reader compares the RAW payload id and refuses (False) any id that does not fully
    match that shape — it never sanitizes-then-compares, because ``a_b`` and ``ab`` would
    collide after sanitizing.

    SELECTION. Records are filtered by content BEFORE the newest is chosen (a newer
    non-matching record cannot shadow a matching one), then the newest mtime decides, so
    a later BLOCKED/NEEDS_CONTEXT from the same session and type supersedes an earlier
    DONE (re-run safety). Equal-mtime ties are CONSERVATIVE: if any record at the newest
    mtime is not DONE/DONE_WITH_CONCERNS, the gate stays blocked (the random filename
    suffix must never decide a verdict).

    DECISION (do not "fix"): DONE_WITH_CONCERNS still unblocks. The gate attests that a
    ``required_agent``-typed subagent dispatched in THIS session finished with a passing
    verdict — NOT that the review approved the change. Concerns are surfaced to the
    orchestrator through the Status line, not through this gate.

    BOUNDS / FAIL-CLOSED. The directory must be a real directory (a symlinked dir is
    refused); records must be regular, non-symlink, <= 64 KiB, fresher than
    SESSION_TIMEOUT and not future-dated; more than 2000 candidate ``*.json`` names
    returns False; any per-file error (including RecursionError / MemoryError from a
    deeply nested junk record) skips that file; this function never raises.

    RESIDUALS. A Bash/subprocess write can still forge a matching record while the sandbox
    is off. Write/Edit/NotebookEdit forgery is covered by the native Edit denies on
    agent-status/** and the sidecars (commit 66dfff1).
    """
    if not (isinstance(required_agent, str) and required_agent
            and isinstance(session_id, str) and _SESSION_ID_RE.fullmatch(session_id)):
        return False
    try:
        if not stat.S_ISDIR(os.lstat(agent_status_dir).st_mode):
            return False
        names = [n for n in os.listdir(agent_status_dir)
                 if n.endswith('.json') and not n.startswith('.')]
    except Exception:
        return False
    if len(names) > _STATUS_MAX_FILES:
        return False
    newest_mtime = None
    newest_pass = False
    for name in names:
        try:
            rec = _read_status_record(os.path.join(agent_status_dir, name))
            if rec is None:
                continue
            mtime, data = rec
            if now - mtime >= SESSION_TIMEOUT or mtime > now + _STATUS_FUTURE_SKEW:
                continue
            agent_type = data.get('agent_type')
            rec_session = data.get('session_id')
            if not (isinstance(agent_type, str) and agent_type == required_agent
                    and isinstance(rec_session, str) and rec_session == session_id):
                continue
            status = data.get('status')
            passing = isinstance(status, str) and status in ('DONE', 'DONE_WITH_CONCERNS')
        except Exception:
            continue  # no per-file error may reach evaluate()'s blanket fail-open
        if newest_mtime is None or mtime > newest_mtime:
            newest_mtime = mtime
            newest_pass = passing
        elif mtime == newest_mtime:
            newest_pass = newest_pass and passing  # tie -> any non-passing record wins
    return newest_pass


_POLICY_MAX_BYTES = 1024 * 1024  # policies.json larger than this is rejected (fail closed)
_POLICY_WARN_MAX_LINES = 4       # max warn-policy lines surfaced per edit; the rest become "(+N more)"
_POLICY_MAX_PATH_LEN = 4096     # longer file_paths are not regex-matched (quadratic-backtrack DoS)
# A path with an embedded newline (or any control char) is never a real edit target, and a
# newline makes the default `.*\.env(\..*)?$` pattern backtrack cubically (4096 chars ~ 24 s
# against a 5 s hook timeout). Control-char paths fail closed BEFORE any regex or realpath.
_POLICY_CONTROL_CHAR_RE = re.compile(r'[\x00-\x1f\x7f]')


def _path_is_strict_utf8(path: str) -> bool:
    """True when `path` encodes as STRICT UTF-8, i.e. holds no lone surrogate (U+D800..U+DFFF).
    Any failure -> False (the caller blocks).

    Deliberately NOT `os.fsencode`: its surrogateescape handler maps a lone U+DC80..U+DCFF to a
    raw byte (0x80..0xFF), so Python's `realpath` would look up `lnk\\x80` -- while Claude Code's
    Node-based Write/Edit encodes ANY lone surrogate as U+FFFD (EF BF BD) and opens
    `lnk\\ufffd`. A symlink named with U+FFFD then escapes every resolved-path policy. The two
    encoders disagree for every surrogate, so every surrogate is refused. (A real astral
    code point, e.g. U+1F600, and a literal U+FFFD are valid UTF-8 and pass.)"""
    try:
        path.encode('utf-8')
        return True
    except Exception:
        return False


def _read_policy_config(path: str):
    """Load the installed policy config without trusting what sits at `path`.

    Returns ('missing', None) | ('invalid', reason) | ('ok', config). Only
    FileNotFoundError from lstat means "not installed"; every other failure
    (dangling symlink, symlink loop, unreadable parent, FIFO, device, directory,
    oversize, bad JSON, deep nesting) is 'invalid' so the caller fails closed.
    O_NONBLOCK keeps open() from hanging on a FIFO; S_ISREG + a bounded read keep
    a symlink to /dev/zero (or any device) from being read without limit. `reason`
    is a structural label, never file contents.
    """
    try:
        os.lstat(path)
    except FileNotFoundError:
        return 'missing', None
    except OSError as exc:
        return 'invalid', f'stat error: {type(exc).__name__}'
    fd = None
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            return 'invalid', 'not a regular file'
        chunks = []
        total = 0
        while total <= _POLICY_MAX_BYTES:
            chunk = os.read(fd, _POLICY_MAX_BYTES + 1 - total)
            if not chunk:
                break
            chunks.append(chunk)
            total += len(chunk)
        if total > _POLICY_MAX_BYTES:
            return 'invalid', 'too large'
        return 'ok', json.loads(b''.join(chunks).decode('utf-8'))
    except (OSError, ValueError, RecursionError, MemoryError) as exc:
        # ValueError covers JSONDecodeError + UnicodeDecodeError
        return 'invalid', f'load error: {type(exc).__name__}'
    finally:
        if fd is not None:
            try:
                os.close(fd)
            except OSError:
                pass


def _running_from_installed_scripts() -> bool:
    """True when this module was loaded from the INSTALLED ~/.claude/scripts dir.

    Evaluated at call time (HOME may differ per call). The plugin runs this module
    from ${CLAUDE_PLUGIN_ROOT}/scripts and repo checkouts from <repo>/scripts; neither
    is the installed dir, so a missing installed policies.json is expected there.
    Any failure computing the answer fails toward True (closed).
    """
    try:
        here = os.path.realpath(os.path.dirname(os.path.abspath(__file__)))
        installed = os.path.realpath(os.path.expanduser('~/.claude/scripts'))
        return here == installed
    except Exception:
        return True


_POLICY_WARN_DESC_MAX = 300      # max chars of a policy description echoed in a warn line


def _escape_for_context(text: str) -> str:
    """Render untrusted text (a file path) for model-visible additionalContext: every
    non-printable char (C0/C1 controls, U+2028/2029, bidi overrides, Unicode tag chars,
    ...) and the backtick (which would close the surrounding code span) becomes a
    \\uXXXX / \\UXXXXXXXX escape. A literal backslash is doubled so the encoding is
    injective (a path containing the text `\\u202e` cannot masquerade as an escape)."""
    out = []
    for c in text:
        if c == '\\':
            out.append('\\\\')  # injective: a literal backslash is doubled, so '\\u202e' text != an escape
        elif c.isprintable() and c != '`':
            out.append(c)
        elif ord(c) > 0xFFFF:
            out.append(f'\\U{ord(c):08x}')
        else:
            out.append(f'\\u{ord(c):04x}')
    return ''.join(out)


def _cap_warn_description(desc: str) -> str:
    if len(desc) > _POLICY_WARN_DESC_MAX:
        return desc[:_POLICY_WARN_DESC_MAX] + '\u2026'
    return desc


def _policy_evaluate(file_path: str, session_id: str = ''):
    """Evaluate the INSTALLED ~/.claude/config/policies.json against file_path.
    Returns (exit_code, message_or_None).

    Mirrors the inline policy engine: a `block`-severity policy whose path_pattern
    matches AND whose required_agent has NOT completed this session → (2, msg).
    CAST_POLICY_OVERRIDE=1 bypasses block policies (audit-logged). `warn` policies
    NEVER block: every matching warn policy whose required_agent has not completed
    this session is collected (a later block policy still wins), and when no block
    fires the result is (0, warn_text) with one `[CAST-POLICY-WARN]` line per policy
    (capped at _POLICY_WARN_MAX_LINES + "(+N more)") for the caller to surface as
    PreToolUse additionalContext. No warn match → (0, None).

    Only the installed copy is read (never a cwd-relative config/policies.json: the
    project dir is agent-writable). A missing installed file (lstat ENOENT) is judged
    by where this guard runs from: loaded from ~/.claude/scripts (CAST installed) →
    deletion/corruption → FAILS CLOSED (2, msg; CAST_POLICY_OVERRIDE=1 bypasses,
    audit-logged as policies-config-missing); loaded from anywhere else (the Claude
    Code plugin's ${CLAUDE_PLUGIN_ROOT}/scripts, a repo checkout) → no installed
    config is expected → (0, None). A PRESENT but unusable config (not a regular
    file, oversize, bad JSON, wrong shape, malformed policy entry, invalid
    path_pattern regex, severity not exactly "block"/"warn") FAILS CLOSED → (2, msg);
    CAST_POLICY_OVERRIDE=1 bypasses it (audit-logged). A file_path longer than
    _POLICY_MAX_PATH_LEN, containing any control character, or not strict UTF-8
    (any lone surrogate), is blocked rather than regex-matched (the raw path is checked before any regex or realpath, and the
    symlink-resolved candidate is checked again before any regex runs). Each pattern is tested
    against BOTH the raw path and its realpath (symlinked-directory bypass).

    `session_id` is the hook PAYLOAD's session_id (not an env var — env is agent-steerable):
    the requires_agent gate only trusts completion records bound to that exact session
    (see `_agent_completed_this_session`); an empty/non-str value fails closed.
    """
    override = os.environ.get('CAST_POLICY_OVERRIDE', '0') == '1'
    gate_session = session_id if isinstance(session_id, str) else ''
    session_id = gate_session or os.environ.get('CLAUDE_SESSION_ID', 'default')  # audit label only

    # Installed copy only: cwd is the project dir, which an agent can write, so a
    # cwd-relative config/policies.json would let it disable every block policy.
    policies_path = os.path.expanduser('~/.claude/config/policies.json')
    status, loaded = _read_policy_config(policies_path)
    if status == 'missing':
        if not _running_from_installed_scripts():
            return 0, None
        # Installed guard + absent config = deletion/corruption, not "never installed".
        if override:
            _audit_policy_override('policies-config-missing', file_path[:256], session_id)
            return 0, None
        return 2, (
            f'**[CAST-POLICY-BLOCK]** Policy config `~/.claude/config/policies.json` is missing although '
            f'CAST is installed (this guard runs from ~/.claude/scripts); failing closed — this edit to '
            f'`{file_path[:256]}` is blocked until it is restored. Run `bash install.sh` from the '
            f'claude-agent-team checkout.\n'
            f'Escape hatch: Set CAST_POLICY_OVERRIDE=1 to bypass (document your reason).'
        )

    def _config_invalid(reason: str):
        if override:
            _audit_policy_override('policies-config-invalid', file_path[:256], session_id)
            return 0, None
        return 2, (
            f'**[CAST-POLICY-BLOCK]** Policy config `{policies_path}` is unreadable or malformed '
            f'({reason}); failing closed — this edit to `{file_path[:256]}` is blocked until it is repaired.\n'
            f'Escape hatch: Set CAST_POLICY_OVERRIDE=1 to bypass (document your reason).'
        )

    if status == 'invalid':
        return _config_invalid(loaded)
    config = loaded
    if not isinstance(config, dict):
        return _config_invalid('top level is not an object')
    policies = config.get('policies', [])
    if not isinstance(policies, list):
        return _config_invalid('"policies" is not a list')
    for policy in policies:
        if not isinstance(policy, dict):
            return _config_invalid('policy entry is not an object')
        for key in ('id', 'description', 'requires_agent'):
            if key in policy and not isinstance(policy[key], str):
                return _config_invalid(f'policy "{key}" is not a string')
        if policy.get('severity') not in ('block', 'warn'):
            return _config_invalid('policy "severity" is missing or not exactly "block"/"warn"')
        pattern = policy.get('path_pattern', '')
        if not isinstance(pattern, str):
            return _config_invalid('path_pattern is not a string')
        if pattern:
            try:
                re.compile(pattern, re.IGNORECASE)
            except (re.error, RecursionError, OverflowError, MemoryError):
                return _config_invalid('invalid path_pattern regex')

    # 2026-10-07 U6c: a valid-but-EMPTY config ({} / {"policies": []} / every entry "warn") would
    # allow every edit — exactly what an agent that truncates the installed file gets for free. The
    # shipped config always carries block policies, so none = tampered / half-installed.
    if not any(isinstance(p, dict) and p.get('severity') == 'block' for p in policies):
        return _config_invalid('it defines no "block" policies, so it would allow every edit; '
                               'run `bash install.sh` from the claude-agent-team checkout to restore it')

    def _path_block(path: str, resolved: bool):
        """(code, msg) when `path` must not reach the regexes, else None.

        Applied to the raw file_path BEFORE realpath and again to the symlink-resolved
        candidate BEFORE any pattern runs: a short, control-free symlink can resolve to a
        target that is long and/or carries a newline (cubic backtracking on the default
        `.*\\.env(\\..*)?$` pattern — measured 8.4 s at 3400 chars, vs a 5 s hook timeout).
        """
        if len(path) > _POLICY_MAX_PATH_LEN:
            pid = 'path-too-long'
            why = f'is too long to evaluate safely ({len(path)} chars > {_POLICY_MAX_PATH_LEN})'
        elif _POLICY_CONTROL_CHAR_RE.search(path):
            pid = 'path-control-chars'
            why = ('contains control characters (a newline, tab, NUL or other 0x00-0x1f / 0x7f '
                   'byte) and cannot be evaluated safely')
        elif not _path_is_strict_utf8(path):
            # ANY lone surrogate (JSON "\ud800".."\udfff") is refused. Most can't be encoded for
            # the filesystem at all (realpath would raise); U+DC80..U+DCFF *can* (surrogateescape
            # -> a raw byte), but then Python resolves `lnk\x80` while the Node-based Write/Edit
            # opens `lnk�`, so a U+FFFD-named symlink would skip every resolved-path
            # policy. See `_path_is_strict_utf8`.
            pid = 'path-not-encodable'
            why = ('contains a code point that cannot be encoded as strict UTF-8 (a lone '
                   'surrogate) and cannot be resolved safely')
        else:
            return None
        if resolved:
            pid = 'resolved-' + pid
            subject = ('The symlink-resolved edit path (the path resolves elsewhere through a '
                       'symlink or the cwd)')
        else:
            subject = 'The edit path'
        if override:
            _audit_policy_override(f'policy-{pid}', file_path[:256], session_id)
            return 0, None
        return 2, (
            f'**[CAST-POLICY-BLOCK]** {subject} {why}; failing closed.\n'
            f'Escape hatch: Set CAST_POLICY_OVERRIDE=1 to bypass (document your reason).'
        )

    if policies:
        blocked = _path_block(file_path, False)
        if blocked is not None:
            return blocked

    # Test the raw path AND its symlink-resolved form: a symlinked directory
    # (hooks-link -> .githooks) would otherwise sidestep every path_pattern.
    # A realpath failure is NOT swallowed (that would degrade to raw-path-only matching and
    # let a symlinked dir bypass every resolved-path policy): it propagates to
    # `_evaluate_write_edit`, which fails the Write/Edit closed.
    candidates = [file_path]
    if policies:
        resolved = os.path.realpath(os.path.abspath(file_path))
        if resolved != file_path:
            candidates.append(resolved)
            blocked = _path_block(resolved, True)
            if blocked is not None:
                return blocked

    agent_status_dir = os.path.expanduser('~/.claude/agent-status')
    now = datetime.datetime.now(datetime.timezone.utc).timestamp()
    warn_hits = []

    for policy in policies:
        pattern = policy.get('path_pattern', '')
        if not pattern:
            continue
        if not any(re.search(pattern, cand, re.IGNORECASE) for cand in candidates):
            continue

        policy_id = policy.get('id', 'unknown')
        required_agent = policy.get('requires_agent', '')
        severity = policy.get('severity', 'warn')
        description = policy.get('description', '')

        if not required_agent:
            continue
        if _agent_completed_this_session(required_agent, agent_status_dir, now, gate_session):
            continue

        if severity == 'block':
            if override:
                _audit_policy_override(policy_id, file_path[:256], session_id)
                return 0, None
            msg = (
                f'**[CAST-POLICY-BLOCK]** Policy "{policy_id}" blocks this edit.\n'
                f'Reason: {description}\n'
                f'Required flow: dispatch `{required_agent}` REVIEW-ONLY — it must NOT apply this edit itself '
                f'(its own edits stay blocked until its completion marker exists, which deadlocks). '
                f'The marker must come from a `{required_agent}` subagent dispatched in THIS session, '
                f'unnamed or named `{required_agent}__<label>` (a dispatch named exactly `{required_agent}`, '
                f'or a built-in agent given that name, is not trusted); hand-written records are ignored. '
                f'When it ends DONE its hook-written marker unblocks the session; then the ORCHESTRATOR applies the edit to `{_escape_for_context(file_path[:256])}`.\n'
                f'Escape hatch: Set CAST_POLICY_OVERRIDE=1 to bypass (document your reason).'
            )
            return 2, msg
        # severity == warn → never blocks: collect it (a later block policy must still win)
        warn_hits.append((policy_id, required_agent, description))

    if not warn_hits:
        return 0, None
    lines = [
        f'**[CAST-POLICY-WARN]** Policy "{pid}" flags this edit to `{_escape_for_context(file_path[:256])}`: '
        f'{_cap_warn_description(desc)}. '
        f'Not blocked — consider dispatching `{agent}` to review it (warn-only).'
        for pid, agent, desc in warn_hits[:_POLICY_WARN_MAX_LINES]
    ]
    if len(warn_hits) > _POLICY_WARN_MAX_LINES:
        lines.append(f'(+{len(warn_hits) - _POLICY_WARN_MAX_LINES} more)')
    return 0, '\n'.join(lines)


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
# Per-`_git_evaluate`-call memo (None whenever no call is in flight, so direct callers and
# tests always recompute). 2026-10-06 security fix: `_audit_push_hatch` /
# `_audit_commit_hatch` spawned one `git rev-parse` PER HATCHED SEGMENT (and
# `_update_ref_overwrites_existing` one per `update-ref` segment) with no cap, so ~500
# hatched segments (13 KB) cost seconds of subprocess time and pushed the guard past its
# watchdog budget. Within one command the cwd and the repo do not change, so one spawn per
# distinct (cwd / ref) answers every segment. Never memoises across calls: a stale
# toplevel or ref answer in a later command would be wrong.
_EVAL_MEMO = None


def _memoized(key, compute):
    """`compute()` once per `_git_evaluate` call for `key`; recomputed every time outside one."""
    memo = _EVAL_MEMO
    if memo is None:
        return compute()
    if key not in memo:
        memo[key] = compute()
    return memo[key]


def _repo_toplevel() -> str:
    """Return the cwd repo's git toplevel, or '' on any failure (best-effort).

    A '' result degrades the hatch event to legacy-global handling in the
    reconcile gate (fail-closed, per the D5 hardening compat table).
    Memoised per `_git_evaluate` call (see `_EVAL_MEMO`)."""
    try:
        cwd = os.getcwd()
    except OSError:
        cwd = None
    return _memoized(('toplevel', cwd), _repo_toplevel_uncached)


def _repo_toplevel_uncached() -> str:
    try:
        r = subprocess.run(['git', 'rev-parse', '--show-toplevel'],
                           capture_output=True, text=True, timeout=5)
        return r.stdout.strip() if r.returncode == 0 else ''
    except Exception:
        return ''


def _hatch_session_id(repo: str) -> str:
    """Memoised per `_git_evaluate` call (see `_EVAL_MEMO`): the DB tier would otherwise
    open sqlite once per hatched segment."""
    return _memoized(('sid', repo), lambda: _hatch_session_id_uncached(repo))


def _hatch_session_id_uncached(repo: str) -> str:
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


# D5a-1: hook-payload identity for the hatch audit events. The dispatcher (or `main()`)
# hands the parsed PreToolUse payload to `set_hook_context` right before evaluating a Bash
# command; `_audit_*_hatch` read it so the D5 reconcile gate can attribute a hatch to a
# session / subagent. Replaced (never merged) on every call and cleared after, so one
# command's identity can never leak into the next.
_HOOK_CTX: dict = {}
_HOOK_CTX_FIELDS = ('session_id', 'agent_type', 'agent_id', 'tool_use_id')
_HOOK_CTX_RE = re.compile(r'^[A-Za-z0-9._:@/-]{1,128}$')


def set_hook_context(data) -> None:
    """Replace `_HOOK_CTX` with sanitized identity fields from a hook payload. Never raises.

    A field is kept only if it is a `str` fully matching `^[A-Za-z0-9._:@/-]{1,128}$`
    (`fullmatch`, so a trailing newline is rejected), else ''. A non-dict yields {}."""
    global _HOOK_CTX
    try:
        if not isinstance(data, dict):
            _HOOK_CTX = {}
            return
        ctx = {}
        for key in _HOOK_CTX_FIELDS:
            val = data.get(key)
            ctx[key] = val if isinstance(val, str) and _HOOK_CTX_RE.fullmatch(val) else ''
        _HOOK_CTX = ctx
    except Exception:
        _HOOK_CTX = {}


def clear_hook_context() -> None:
    global _HOOK_CTX
    _HOOK_CTX = {}


_SHA_RE = re.compile(r'^[0-9a-f]{40}([0-9a-f]{24})?$')


def _load_git_safe():
    """Load scripts/cast_git_safe.py from this file's own directory (importlib, no sys.path edit)."""
    import importlib.util
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'cast_git_safe.py')
    spec = importlib.util.spec_from_file_location('cast_git_safe', path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def _hatch_commit_git_facts(repo: str) -> tuple:
    """(head_before, main_repo) for a hatch commit; '' for each unknown. Two git calls at
    most (each <= 1.0s); the second is skipped if the first timed out (rc 124)."""
    if not repo:
        return '', ''
    gs = _load_git_safe()
    head_before = ''
    r = gs.run(repo, ['rev-parse', '--verify', '-q', 'HEAD'], timeout=1.0)
    if r.returncode == 124:
        return '', ''
    out = (r.stdout or '').strip()
    if r.returncode == 0 and _SHA_RE.match(out):
        head_before = out
    main_repo = ''
    r2 = gs.run(repo, ['rev-parse', '--path-format=absolute', '--git-common-dir'], timeout=1.0)
    if r2.returncode == 0:
        common = (r2.stdout or '').strip()
        if common and os.path.basename(common) == '.git':
            main_repo = os.path.realpath(os.path.dirname(common))
    return head_before, main_repo


def _hatch_identity(repo: str) -> dict:
    ctx = _HOOK_CTX if isinstance(_HOOK_CTX, dict) else {}
    return {
        'session_id': ctx.get('session_id') or _hatch_session_id(repo),
        'agent_type': ctx.get('agent_type') or '',
        'agent_id': ctx.get('agent_id') or '',
        'tool_use_id': ctx.get('tool_use_id') or '',
    }


def _audit_budget_ok(kind: str) -> bool:
    """Bound audit lines per `_git_evaluate` call to `_MAX_HATCH_RECORDS_PER_COMMAND` per kind
    (counter lives in `_EVAL_MEMO`, so it resets per call; unbounded outside a call). The
    verdict is never affected -- only the audit write is skipped. Mirrors the `_record_hatch`
    cap so a many-segment command cannot spend the watchdog budget on audit I/O."""
    memo = _EVAL_MEMO
    if memo is None:
        return True
    key = ('audit_n', kind)
    memo[key] = memo.get(key, 0) + 1
    return memo[key] <= _MAX_HATCH_RECORDS_PER_COMMAND


def _audit_commit_hatch() -> None:
    """Append a COMMIT_HATCH_USED line to audit.jsonl — best-effort, never blocks."""
    try:
        if not _audit_budget_ok('commit'):
            return
        repo = _repo_toplevel()
        audit_path = os.path.expanduser('~/.claude/logs/audit.jsonl')
        os.makedirs(os.path.dirname(audit_path), exist_ok=True)
        head_before, main_repo = _memoized(
            ('hatch_facts', repo), lambda: _hatch_commit_git_facts(repo))
        event = {
            'timestamp': datetime.datetime.now(datetime.timezone.utc)
            .isoformat().replace('+00:00', 'Z'),
            'event': 'COMMIT_HATCH_USED',
            'override_env': 'CAST_COMMIT_AGENT',
            'git_op': 'commit',
            'repo': repo,
            **_hatch_identity(repo),
            'head_before': head_before,
            'main_repo': main_repo,
            'in_claude_session': os.environ.get('CLAUDECODE') == '1',
        }
        with open(audit_path, 'a') as af:
            af.write(json.dumps(event) + '\n')
    except Exception:
        pass


def _audit_push_hatch() -> None:
    """Append a PUSH_HATCH_USED line to audit.jsonl — best-effort, never blocks."""
    try:
        if not _audit_budget_ok('push'):
            return
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
            **_hatch_identity(repo),
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

# 2026-10-06 security fix (High): CPU-time bound on the regex scan. A hook
# TIMEOUT is a non-blocking error, i.e. an ALLOW, so a command that makes this
# guard run past the PreToolUse timeout (5 s) silently bypasses every git block
# in it. Measured before this fix, in-process: `("git " * N) + "; git push ..."`
# cost 0.66 s at N=5k, 2.5 s at 10k, 11.5 s at 20k, 41 s at 40k — about 60 KB of
# padding in front of a raw push beat the hook timeout.
#
# Root cause: every BLOCK pattern is anchored at `(^|\s)git`, and `re.search`
# retries that anchor at EVERY `git` token in the segment. Each retry then does
# O(rest-of-segment) work — either a `(?=.*Y)` / `(?!.*Z)` lookahead
# (`_GC_CINJECT_BLOCK` is just `git\b(?=.*-c gc.xxx=)`, so it pays even for a
# bare `git git git ...`) or an option-run walk (`_GIT_OPTS` eats `-c git -c git
# ...` to the end of the line and then backs off one iteration at a time). N
# tokens x O(N) rest = O(N^2); 22 of the module's patterns were measured
# super-linear this way. The cost is per token, so it is paid by padding BEFORE
# the verb, and it is paid on a segment that itself matches nothing.
#
# Why a bound and not a rewrite of those 22 patterns: the retry-from-every-`git`
# shape is inherent to `re.search` over a leftmost-anchored pattern with a
# trailing lookahead, the rewrites are not verdict-obvious (a negative lookahead
# such as `(?!.*--cached)` fails at every retry and cannot be cut off), and a
# per-pattern fix leaves the NEXT pattern someone adds quadratic again. The bound
# is pattern-independent: it caps the one quantity every one of them scales with.
#
# What is bounded: the super-linear part, `(git tokens - 1) x segment length`,
# summed over every segment/variant of the command. One `git` token is linear
# no matter how long the segment is, so it costs nothing against the bound;
# real commands are far under it (a 40 KB segment may carry ~10 `git` tokens,
# an 8 KB one ~50; a segment under ~1.3 KB can never trip it at all, since
# it cannot hold enough tokens). Over the bound the command is BLOCKED
# (fail closed): refusing a command nobody can write by hand is the safe
# direction, whereas running it to the hook timeout is an allow. At the bound
# the measured worst case across all patterns is ~0.2 s.
#
# The single-token quadratic (`-fff...f_`, one star group after another over the
# same class) is NOT bounded here — it is a different shape (one start, O(n^2)
# inside the token) and is removed exactly by `_flag_cluster`.
_MAX_GIT_SCAN_WORK = 400_000
_GIT_START_TOKEN = re.compile(r'(?:^|\s)git\b')

# `shlex.split` (run by `_normalize_git_segment`) is O(n^2) in the length of its
# LONGEST TOKEN — it grows `self.token` one character at a time, an attribute
# `+=` CPython cannot do in place. Measured: 1.2 s at 400 KB, 4.5 s at 800 KB, for
# one `x...x` token. Two exact-or-fail-closed cuts, neither changing a verdict a
# real command can reach:
#   1. `_normalize_git_segment` returns None unless the segment's first command
#      word, quote- and escape-stripped, is `git`. A segment with no
#      `g<quotes/backslashes>i<quotes/backslashes>t` anywhere cannot satisfy
#      that (shlex only DELETES quote/backslash characters, it never adds or
#      reorders letters), so it is not tokenised at all — same None as before.
#   2. A segment that DOES mention `git` and is longer than
#      `_MAX_GIT_SEGMENT_LEN` is blocked rather than tokenised: tokenising it
#      costs up to the hook timeout, and 200 KB on one line (a newline,
#      `;`, `&&` or `|` ends a segment) is not a hand-written command.
_MAX_GIT_SEGMENT_LEN = 200_000
# Round-2 security finding (HIGH-1): the per-segment cap alone is not enough. shlex costs ~0.3 s
# per 195 KB token and the dispatcher's watchdog budget is 2 s, so FIVE 195 KB git-mentioning
# segments (each under the cap) pushed the guard past the budget — and a command that is only
# decided by the watchdog is decided by a blunt over-approximation, not by the guard. The bytes
# handed to `_normalize_git_segment` are therefore also capped CUMULATIVELY across the whole
# command: 2 x 195 KB (~0.6 s) still passes, a 3rd is refused up front, fail closed.
_MAX_GIT_TOKENIZE_BYTES = 400_000
# A GATE, never a verdict: necessary for `_executed_code` (and for the evaluator's normalisation
# of a segment) to be worth running. Wider than what `_normalize_git_segment` accepts: `$` is in
# the class because `$'g'it` / `g$'i't` spell git once the `$` of an ANSI-C / locale quote is
# dropped; `re.I` because APFS is case-insensitive (`GIT push` runs git).
_GIT_MENTION = re.compile(r'g[\\\'"$]*i[\\\'"$]*t', re.I)


def _scan_work(v: str, limit: int) -> int:
    """Super-linear regex work `v` costs: `(git start tokens - 1) x len(v)`
    (0 for a segment with at most one `git` token). Stops counting once the
    result exceeds `limit` and returns `limit + 1`, so a huge padded segment
    is rejected after `limit / len(v)` iterations rather than after scanning
    it all."""
    n = len(v)
    starts = 0
    for _ in _GIT_START_TOKEN.finditer(v):
        starts += 1
        if starts > 1 and (starts - 1) * n > limit:
            return limit + 1
    return (starts - 1) * n if starts > 1 else 0


_TOKENIZE_BUDGET_MSG = (
    "**[CAST]** Bash command blocked: its git-mentioning lines/segments add up to far more "
    "text than any hand-written command (over 400,000 characters), and tokenising it to "
    "check the git blocks would take unbounded time. A guard that runs past the hook "
    "timeout is silently skipped, so the git guard refuses (fails closed) instead of "
    "attempting it. Split it into separate commands, or pass the data via a file rather "
    "than inline."
)
_EXEC_BUDGET_MSG = (
    "**[CAST]** Bash command blocked: it nests far more `bash -c` / `eval` / `$(...)` code (or "
    "has far more words) than any hand-written command, and checking all of it against the git "
    "blocks would take unbounded time. A guard that runs past the hook timeout is silently "
    "skipped, so the git guard refuses (fails closed) instead of attempting it. Split it into "
    "separate commands."
)
_NESTING_MSG = (
    "**[CAST]** Bash command blocked: it runs `git` from inside more than 3 levels of nested "
    "`bash -c` / `eval` / `$(...)`, deeper than the git guard follows. A guard that cannot see "
    "the command it is checking refuses (fails closed) instead of allowing it. Flatten the "
    "nesting, or run the git command directly."
)
_LEX_UNCERTAIN_MSG = (
    "**[CAST]** Bash command blocked: the git guard could not parse it with certainty (an "
    "unterminated or unusually quoted string, an unclosed `$(` / `${` / `((`, a heredoc "
    "delimiter it cannot read, or a scanner fault) and `git` is mentioned from that point on, "
    "so it cannot tell whether a guarded git command is executed. A guard that cannot see the "
    "command it is checking refuses (fails closed) instead of allowing it. Split it into "
    "separate commands, simplify the quoting, or write long text with the Write tool instead "
    "of an inline heredoc."
)
_SCAN_BUDGET_MSG = (
    "**[CAST]** Bash command blocked: it contains far more `git` tokens per "
    "line/segment than any hand-written command, and checking it against the "
    "git blocks would take unbounded time. A guard that runs past the hook "
    "timeout is silently skipped, so the git guard refuses (fails closed) "
    "instead of attempting the scan. Split it into separate commands (a "
    "newline, `;`, `&&` or `|` starts a new segment), or pass the data via a "
    "file rather than inline."
)


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
            ['python3', '-E', '-s', os.path.join(scripts_dir, 'cast_ack.py'),
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

    2026-10-07 U6c: tokenized LAZILY, stopping at the first non-assignment token. It used
    to `shlex.split` the whole segment on every call (twice per hatched segment — the
    CAST_HATCH_REASON lookup and the hatch's own value — while the cumulative
    `_MAX_GIT_TOKENIZE_BYTES` budget counted the segment once), so two 195 KB hatched
    segments tripped the 2 s watchdog (~2.04 s). Only the leading `VAR=value` prefix
    is ever read, so the cost is now O(prefix). Same tokens as `shlex.split` (posix,
    whitespace_split, no comment handling); an unbalanced quote LATER in the segment is
    never reached, and one inside the prefix still falls back to a whitespace split.
    """
    prefix = f'{variable}='
    try:
        lex = shlex.shlex(segment, posix=True)
        lex.whitespace_split = True
        lex.commenters = ''
        for token in lex:
            if not _ENV_ASSIGN.match(token):
                break
            if token.startswith(prefix):
                return token[len(prefix):]
        return ''
    except ValueError:
        pass
    for token in segment.split():
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
    joined_lines = _join_continuations(command)

    # Step 2: split each joined line into shell segments.
    for line in joined_lines:
        for seg in re.split(r';|&&|\|\||\|', line):
            yield seg


def _join_continuations(command: str):
    """Step 1 of `_scannable_segments`: the list of logical lines after joining
    backslash line-continuations (only an ODD trailing-backslash count joins; an odd
    count of N leaves (N-1)/2 literal backslashes — see that docstring).

    LINEAR (2026-10-06 security fix). The original kept one growing string and rebuilt
    it with `buf = buf[:len(buf) - trailing] + ...` on every continuation line:
    O(lines x length), 0.85 s at 900 KB and >9 s at 4.8 MB of `a\\\\\\n` lines. This keeps
    the pieces in a list, tracks the length of the trailing backslash run instead of
    re-scanning the string, and joins once per logical line. Output is identical to the
    original for every input — the old loop is pinned as a reference implementation in
    tests/test_cast_git_guard_perf.py and compared exhaustively on small alphabets and on
    random inputs (including `\\r`, empty lines and runs of backslashes that span lines)."""
    joined_lines = []
    parts = []      # pieces of the logical line being built; ''.join(parts) is the old `buf`
    tail_bs = 0     # backslashes at the very end of ''.join(parts)
    for line in command.split('\n'):
        parts.append(line)
        stripped = line.rstrip('\\')
        run = len(line) - len(stripped)          # backslashes ending `line` itself
        # A line made ONLY of backslashes (or empty) extends the run already at the end of
        # the buffer; otherwise the run ends inside `line` and the buffer's old tail is cut off.
        trailing = tail_bs + run if not stripped else run
        if trailing % 2 == 1:
            # Drop the `trailing` backslashes from the end of the buffer ...
            remaining = trailing
            while remaining > 0:
                piece = parts.pop()
                if len(piece) <= remaining:
                    remaining -= len(piece)
                else:
                    parts.append(piece[:len(piece) - remaining])
                    remaining = 0
            # ... and leave (trailing-1)//2 literal ones behind.
            tail_bs = (trailing - 1) // 2
            if tail_bs:
                parts.append('\\' * tail_bs)
            continue
        joined_lines.append(''.join(parts))
        parts = []
        tail_bs = 0
    buf = ''.join(parts)
    if buf:
        joined_lines.append(buf)
    return joined_lines


# --- executed-code extraction (2026-10-06 security fix) ----------------------------------
# Every BLOCK regex anchors on `(^|\s)git`, so a git invocation that the SHELL executes but
# that is not a bare word of the segment - `bash -c 'git push'`, `eval "git push"`,
# `echo $(git push)`, `` `git push` `` - matched nothing and was ALLOWED. `_executed_code`
# pulls those nested command strings out of a command; `_executable_segments` then feeds
# them back through the SAME per-segment engine as extra VIRTUAL segments, so every verdict
# rule (incl. a hatch being honoured only inside its own segment) applies to them unchanged.
#
# ADDITIVE ONLY: an extra segment (or a `_Refusal`) can only add a block, never remove one - the
# real segments are always yielded first and evaluated exactly as before.
#
# FAILS CLOSED. The scan is only as good as its model of the shell's quoting, and a lexer that
# disagrees with the shell about where a quote ends hides every command after that point (the
# desync class: a `'` in an unquoted heredoc body, `#` after a non-blank, `${x//(/y}`, `$$'a\'`,
# `$((1<<'2'))`, `<<$'EOF'`). So on any input it cannot model with certainty it raises
# `_LexUncertain` (unterminated quote / substitution / expansion, a heredoc delimiter it cannot
# quote-remove, a quote inside arithmetic, `$[`, nesting past `_MAX_LEX_NEST`), and
# `_executable_segments` turns that into a `_Refusal` - EXCEPT when nothing from the start of the
# earliest unresolved construct to the end of the text could spell a guarded git command
# (`_GIT_MENTION`): then what was extracted before it is complete and is returned as is.
#
# ONE lexer (`_Lexer`) reads every context - top level, `$(...)`, `(...)`, `<(...)`, `>(...)`
# are the same `cmd` routine, recursively - so a quoting rule cannot hold in one and not another.
#
# Extraction runs on the WHOLE RAW command text, not per segment: a quoted payload or a
# substitution body can itself contain `;`, `|`, `&&` and newlines (`bash -c 'git push && echo
# done'`), so splitting on those first would cut it open and leave `bash -c 'git push ` with an
# unbalanced quote. RAW, not `_join_continuations`'d: a `\<newline>` is a continuation outside
# quotes but NOT in a comment or single quotes, and joining first would merge a comment line with
# the next one (`echo x # it's \` + newline + `b; <cmd>` hides `<cmd>` in the "comment") - the
# lexer applies the real rule itself.
# A word that names a shell by its de-quoted basename (lower-cased, like `git`): bash sh zsh dash
# ksh ash csh tcsh fish mksh ksh93 bash5 ..., or by a variable that holds one (`$SHELL`,
# "${BASH}"; matched on the RAW word). Wrappers are NOT listed: a payload is looked for at EVERY
# word of a simple command, so `find . -exec bash -c P \;`, `arch -arm64 bash -c P` and zsh's
# `noglob` / `repeat 1` / `coproc` precommand modifiers need no entry.
_SHELL_BASENAME = re.compile(r'[a-z0-9_+-]*sh[0-9.]*\Z')
_SHELL_VAR_WORD = re.compile(r'"?\$(?:[A-Za-z_][A-Za-z0-9_]*|\{[A-Za-z_][A-Za-z0-9_]*\})"?\Z')
_SHELL_NAME_MAX = 32
# `x=1`, `x+=1`, `x[0]=1`: an assignment word (`_ENV_ASSIGN`, which main uses, lacks the last two).
_ANY_ASSIGN = re.compile(r'[A-Za-z_][A-Za-z0-9_]*(?:\[[^\]]*\])?\+?=')
_ENV_SPLIT_SHORT = re.compile(r'-[iv0]*S(.*)\Z', re.S)      # `env -S STR`, `-SSTR`, `-iS STR`
# `$0`..`$9`, `${0}`..`${NN}`, `$@`, `$*`, `${@}`, `${*}`, `${@:N}`, `${*:N}`, `${@:N:M}` and the quoted
# `"$@"` / `"${@}"` ... : what a `-c` payload reads from the operands after it (`${1:-x}`, `${1#x}`
# ... are a residual: see `_shell_payloads`).
_ALL_OPERANDS = r'(?:[@*]|\{[@*](?::[0-9]{1,9}(?::[0-9]{1,9})?)?\})'
_POSITIONAL = re.compile(r'"\$' + _ALL_OPERANDS + r'"|\$' + _ALL_OPERANDS + r'|\$\{[0-9]{1,9}\}|\$[0-9]')
_SHELL_OPT_WITH_ARG = frozenset(('-o', '+o', '-O', '+O', '--rcfile', '--init-file'))
_IFS_BLANKS = re.compile(r'[\t\n]')      # IFS whitespace besides the space: what an unquoted `$1` splits at
_MAX_EXEC_DEPTH = 3          # nested levels of `bash -c` / `eval` / `$(...)` that are followed
# Nested constructs the lexer follows before refusing (it recurses; a hand-written command
# nests a handful of levels, and Python's own stack is the other limit).
_MAX_LEX_NEST = 48
# The scanner is linear but a Python-level loop, and every nested code string is re-evaluated
# by the whole per-segment engine: cap both, across every nesting level, so a padded command
# cannot spend the hook budget in them. A STEP is one scanner iteration (a run of plain text
# up to the next metacharacter, a blank-separated word, a quote/expansion/heredoc) and costs
# ~2-3 us; a real command has a few hundred at most - the largest of 31,322 real
# git-mentioning commands (up to 70 KB) takes 952 steps INCLUDING its nested re-scans, and none
# comes near either cap. RESIDUAL, accepted and fail closed: a command that mentions git AND has
# more than the cap's worth of words/metacharacters (roughly a 1 MB script of short words, far
# past any hand-written command) is refused rather than scanned to the end - in bounded time
# (the worst of 12 padding shapes at 5 MB is ~0.3 s; each word of a run is charged BEFORE the
# run is split, so a huge run is refused at once). Over a cap the command is refused, like the
# other caps above. STEPS, not bytes: a megabyte of `x` is one step, an unquoted-heredoc body
# costs one step per `\`, `$` or backtick, a quoted one a single regex search, and a text with
# no git mention is never scanned (tests/test_cast_git_guard_perf.py pins those).
_MAX_EXEC_SCAN_STEPS = 250_000
_MAX_EXEC_CODES = 5_000

_LEX_CMD_RUN = re.compile(r"""[^\\'"`$();&|<>#\n]*""")     # plain text and blanks up to a metacharacter
_BLANKS = re.compile(r'[ \t]+')       # bash blanks are ONLY space and tab (`\r`, `\xa0`, `\x0b` ... are word chars)
_BLANK_RUN = re.compile(r'[ \t\n]*')    # blanks and newlines: what may sit between a case pattern's `)` and the next token
_DIGITS = re.compile(r'[0-9]+\Z')
_LEX_DQ = re.compile(r'[\\"`$]')
_LEX_BQ = re.compile(r'[\\`]')
_LEX_PARAM = re.compile(r"""[\\'"`$}]""")
_LEX_ARITH = re.compile(r"""[()\\'"`$]""")
_LEX_HDBODY = re.compile(r'[\\`$]')
_NAME = re.compile(r'[A-Za-z_][A-Za-z0-9_]*')
_ANSI_C = re.compile(r"'(?:\\.|[^'\\])*'", re.S)         # a `$'...'` body: `\'` does not end it
_BQ_UNESCAPE = re.compile(r'\\([$`\\])')
_BQ_UNESCAPE_DQ = re.compile(r'\\([$`\\"])')              # a `...` inside "..." also unescapes `\"`
_HEREDOC_BARE = re.compile(r"""[^ \t\n;&|()<>'"\\`$]+""")
_CASE_WORDS = frozenset(('case', 'in', 'esac'))
# Words after which a command word may follow (so `case` / `esac` are reserved words there).
_CMD_KEYWORDS = frozenset(('if', 'then', 'else', 'elif', 'while', 'until', 'do', '!', '{', 'time'))


# bash's `$'...'` ANSI-C escapes: `\a \b \e \E \f \n \r \t \v \\ \' \" \?`, `\nnn` (1-3 octal digits),
# `\xHH`, `\uHHHH`, `\UHHHHHHHH` (1-2 / 1-4 / 1-8 hex digits), `\cx` (control-x). Anything else
# keeps its backslash; a NUL ends the string.
_ANSI_ESCAPE = re.compile(r"\\(?:([abeEfnrtv\\'\"?])|([0-7]{1,3})|x([0-9A-Fa-f]{1,2})"
                          r"|u([0-9A-Fa-f]{1,4})|U([0-9A-Fa-f]{1,8})|c(\\\\|.)|(.))", re.S)
# bash 3.2 (macOS /bin/bash) and zsh take `\c` and ONE character; bash 5 takes `\c\\` (two backslashes)
# as one. The two read the rest of `\c\\n` differently (`\n` is a newline for the first, a literal `n`
# for the second), so a payload is read BOTH ways (`_ansi_value`).
_ANSI_ESCAPE_LEGACY = re.compile(_ANSI_ESCAPE.pattern.replace(r'c(\\\\|.)', r'c(.)'), re.S)
_ANSI_SIMPLE = {'a': '\a', 'b': '\b', 'e': '\x1b', 'E': '\x1b', 'f': '\f', 'n': '\n', 'r': '\r',
                't': '\t', 'v': '\v', '\\': '\\', "'": "'", '"': '"', '?': '?'}
# A numeric escape (`\x67`, `\147`, `\u0067`): the only kind that can spell a letter the text does
# not contain. Looked for anywhere in a text that has a `$'`, not only inside a recognisable
# `$'...'`: quoted around a payload (`bash -c '$'"'"'\x67it'"'"' push'`) the `$'...'` is cut up.
_ANSI_NUMERIC = re.compile(r"\\(?:x[0-9A-Fa-f]{1,2}|u[0-9A-Fa-f]{1,4}|U[0-9A-Fa-f]{1,8}|0?[0-7]{1,3})")
_ANSI_MENTION_MAX = 2000        # numeric escapes examined; past it a text that has `$'` counts as a mention
_GIT_LETTER = re.compile(r'[gitGIT]')


def _ansi_char(code):
    return '�' if code > 0x10FFFF or 0xD800 <= code <= 0xDFFF else chr(code)


def _ansi_escape(m):
    simple, octal, hexa, u4, u8, ctl, other = m.groups()
    if simple is not None:
        return _ANSI_SIMPLE[simple]
    if octal is not None:
        return chr(int(octal, 8) & 0xFF)
    if hexa is not None:
        return chr(int(hexa, 16))
    if u4 is not None:
        return _ansi_char(int(u4, 16))
    if u8 is not None:
        return _ansi_char(int(u8, 16))
    if ctl is not None:             # `\c\\` (two backslashes) is ONE control-backslash, 0x1c
        ch = '\\' if ctl == '\\\\' else ctl
        return '\x7f' if ch == '?' else chr(ord(ch) & 0x1F)
    return '\\' + other


def _ansi_c(body, legacy=False):
    """The value of the `$'...'` string whose raw body is `body` (`legacy`: as bash 3.2 / zsh read
    `\\c\\\\`, see `_ANSI_ESCAPE_LEGACY`)."""
    s = (_ANSI_ESCAPE_LEGACY if legacy else _ANSI_ESCAPE).sub(_ansi_escape, body)
    z = s.find('\0')
    return s if z < 0 else s[:z]


def _echo_octal(m):
    return chr(int(m.group(1), 8) & 0xFF)


def _git_mentioned(text, start=0):
    """Can `text[start:]` spell a git invocation? `_GIT_MENTION`, also across a `\\<newline>`
    continuation (`gi\\` + newline + `t`) - the lexer scans the raw text, the shell joins those -
    and through an ANSI-C escape (`$'\\x67it'`, `$'\\147'it`): a text with a `$'` and a numeric
    escape that decodes to any letter of `git`."""
    if _GIT_MENTION.search(text, start):
        return True
    if text.find("$'", start) >= 0 or text.find('|', start) >= 0 or text.find('<(', start) >= 0:
        # in a `$'...'`, in a pipeline (`printf 'g\\151t push' | sh`, `echo -e 'g\\0151t' | sh`: the
        # producer reads the escapes) and in a process substitution (`bash <(printf 'g\\151t push')`)
        seen = 0
        for m in _ANSI_NUMERIC.finditer(text, start):
            seen += 1
            e = m.group()
            if (seen > _ANSI_MENTION_MAX or _GIT_LETTER.search(_ansi_c(e)) is not None
                    or _GIT_LETTER.search(_ansi_c(_ECHO_OCTAL.sub(_echo_octal, e))) is not None):
                return True
    tail = text[start:] if start else text
    return '\\\n' in tail and _GIT_MENTION.search(tail.replace('\\\n', '')) is not None


class _ExecOverBudget(Exception):
    """`_executed_code` ran past its step budget."""


class _LexUncertain(Exception):
    """The scanner met input whose shell parse it cannot model with certainty. `pos` is the
    offset of the construct that is unresolved (the enclosing ones are tracked by the lexer)."""

    def __init__(self, pos):
        Exception.__init__(self, pos)
        self.pos = pos


class _Refusal:
    """Yielded by `_executable_segments` in place of a segment when the command cannot be
    checked within bounds or with certainty; the evaluator turns it into a fail-closed BLOCK
    carrying `msg`."""
    __slots__ = ('msg',)

    def __init__(self, msg):
        self.msg = msg


class _Virtual(str):
    """A code string that is the virtual segment `git <the rest of the command>` of a spelled git
    (or of a plain `git` that is not main's). It is ONE simple command with every argument quoted
    (`shlex.join`), so there is nothing in it to scan for nested code: `_executable_segments`
    judges its real segments and goes no deeper (a scan would find the later `git` words of the
    command again - all of which the parent already has its own segment for)."""
    __slots__ = ()


class _W(str):
    """One word of a simple command as `_Lexer` builds it: its de-quoted text (it IS a `str`),
    plus `start`/`end`, its raw span in the scanned text, and `redir`, True for a redirection
    OPERATOR token (`>`, `2>&`, `&>>`, `<<`, `<<<` ...). The word that follows a redirection
    operator is that redirection's target (for `<<` it is the heredoc delimiter), not a command
    word. `spelled` is True for a FIELD `_spell_words` cut out of a word at an unquoted `$IFS`:
    its span is that whole word, its text one field of it."""
    __slots__ = ('start', 'end', 'redir', 'spelled')

    def __new__(cls, text, start, end, redir=False, spelled=False):
        self = str.__new__(cls, text)
        self.start = start
        self.end = end
        self.redir = redir
        self.spelled = spelled
        return self


def _unequals(w):
    """`w` without the ONE leading `=` of zsh's `=cmd` (the path of `cmd`: `=bash`, `=git`); `==cmd` is
    no expansion, and a word that is only `=` stays one."""
    return w[1:] if w[:1] == '=' and w[1:2] != '=' else w


def _is_shell_word(w, text):
    """Does the word `w` (a `_W`) name a shell? By its de-quoted basename (`_SHELL_BASENAME`,
    case-insensitive; zsh's `=bash` too, `_unequals`) or, for a variable that holds one, by its RAW text
    (`$SHELL`, "${BASH}")."""
    base = _unequals(w).rsplit('/', 1)[-1]
    if len(base) <= _SHELL_NAME_MAX and _SHELL_BASENAME.match(base.lower()) is not None:
        return True
    return (0 <= w.start < len(text) and text[w.start] in '$"' and w.end - w.start <= _SHELL_NAME_MAX
            and _SHELL_VAR_WORD.match(text, w.start, w.end) is not None)


# A script operand that IS stdin: `bash /dev/stdin`, `bash -`, `source /dev/stdin` (`_is_stdin_path`).
_STDIN_FD_PATH = re.compile(r'/(?:dev|proc/self)/fd/0+\Z')


def _is_stdin_path(w):
    """Does the script operand `w` name the shell's stdin: `-`, `/dev/stdin`, `/dev/fd/0`,
    `/proc/self/fd/0`? As the OS resolves the path: repeated slashes, `/./`, `/../`, a trailing slash
    and leading zeros of the fd number name the same file (`//dev/stdin`, `/dev/./stdin`,
    `/dev/fd/00`, `/dev/stdin/` - the last one no shell runs, blocked all the same). A relative path
    is never one (`dev/stdin`, `./dev/stdin`). Linear in `len(w)`."""
    if w == '-':
        return True
    if w[:1] != '/':
        return False
    parts = []
    for c in w.split('/'):
        if c == '..':
            if parts:
                parts.pop()
        elif c and c != '.':
            parts.append(c)
    p = '/' + '/'.join(parts)
    return p == '/dev/stdin' or _STDIN_FD_PATH.match(p) is not None


def _substitute_positional(payload, ops, lo, hi, budget, raw=False, split=False):
    """`payload` (the operand of `<shell> -c`) with the positional parameters it reads replaced by
    the operand words `ops[lo:hi]` that follow it (`$0` is `ops[lo]`, `$1` the next one ...; `$@`,
    `$*`, `${@}`, `${*}`, quoted or not, are `$1` .. `$n`, and `${@:N}` / `${*:N:M}` the slice from
    `$N`). `ops` are the operands as the SHELL reads them (decoded: `$'\\x70ush'` is `push`). Each
    is shlex-quoted - one word, what an unquoted `$1` is to a command - or, with `raw`, inserted as
    written: the operand's own words, which is what `eval "$1"` / `exec $1` / `$@` run (`bash -c
    '$1' x 'git push'`) and what a `"..."` around it must not be quoted twice. With `split` (and
    `raw`) a tab or newline in an operand is a blank: an UNQUOTED `$1` is split on every default IFS
    character, so `git` + newline + `push` in an operand is the two words `git push` to the command
    that reads it, where `raw` would leave a newline - a command separator - between them. A parameter
    with no operand behind it is empty. The work is charged to `budget[0]` BEFORE it is done - by operand
    count, by operand size and by size of what is produced - and running out raises
    `_ExecOverBudget`: n shell words each walking the operands behind it, or one `$@` repeated over
    big operands, would otherwise cost n x n."""
    budget[0] -= 1 + ((hi - lo) >> 4)
    if budget[0] < 0:
        raise _ExecOverBudget()
    quoted = {}
    spans = {}

    def operand(idx):
        if lo + idx >= hi:
            return ''
        if idx not in quoted:
            word = ops[lo + idx]
            budget[0] -= 1 + (len(word) >> 7)
            if budget[0] < 0:
                raise _ExecOverBudget()
            quoted[idx] = (_IFS_BLANKS.sub(' ', word) if split else str(word)) if raw else shlex.quote(word)
        return quoted[idx]

    def repl(m):
        t = m.group(0)
        if t[0] == '"':
            t = t[1:-1]
        body = t[2:-1] if t[1] == '{' else t[1:]
        if body[:1] in ('@', '*'):                  # `$@` `${@}` `${*:N}` `${@:N:M}`: a run of operands
            key = body[1:]
            if key not in spans:
                first, _, count = key[1:].partition(':') if key else ('1', '', '')
                start = int(first) if first else 1
                stop = hi - lo if not count else min(hi - lo, start + int(count))
                spans[key] = ' '.join([operand(i) for i in range(start, stop)])
            out = spans[key]
        else:
            out = operand(int(body))
        budget[0] -= 1 + (len(out) >> 7)
        if budget[0] < 0:
            raise _ExecOverBudget()
        return out

    return _POSITIONAL.sub(repl, payload)


# What `_word_view` reads. `_VIEW_SPECIAL`: a character that makes a word more than plain text.
_VIEW_SPECIAL = re.compile(r"[\\'\"$`]")
_VIEW_PLAIN = re.compile(r"[^\\'\"$`]+")
_VIEW_DQ_PLAIN = re.compile(r'[^\\"$`]+')
_ANSI_BODY = re.compile(r"((?:[^'\\]|\\.)*)'", re.S)
_NAME_CHAR = re.compile(r'[A-Za-z0-9_]')
_VIEW_EXPANSION = frozenset('{(@*#?!$-[_')      # after a `$`: an expansion (with a letter or digit)
# Any `|` / `|&`: where an unresolved construct earlier in the pipeline leaves `_executed_code`
# unable to say whether what the pipeline writes reaches a shell. It used to look for a shell NAME
# after the pipe, which a quote-split one (`ba's'h`, `s''h`, `b"a"s"h"`, `/bin/s\\h`) dodges and which
# was quadratic on `echo $[1] ` + `| # ` x N; a plain `|` is linear and cannot be dodged.
_PIPE_SINK = re.compile(r'\|')
# The shells that, with no `-c` and no script, read their commands from stdin (`_SHELL_BASENAME`
# is wider: it also takes `push`, `publish` ... for the `-c` payload, where a false positive costs
# nothing without an operand).
_STDIN_SHELL = re.compile(r'(?:r?ba|da|z|k|a|c|tc|fi|mk|pdk|ya)?sh[0-9.]*\Z')
# What may stand between the start of a pipeline stage and the shell that reads its stdin: these
# wrappers (and their options, `sudo -u root`, `nice -n 5`, `env -i A=1`) and `_CMD_KEYWORDS`
# (`{`, `then`, `time` ...). A shell word anywhere else is an ARGUMENT (`grep -v sh`).
# The list is CLOSED: a wrapper that is not here (`frobnicate bash`) hides the stdin shell - a documented
# residual. `_WRAPPER_OPERANDS`: the positional operands a wrapper takes AFTER its options and before the
# command (`timeout DUR`, `chroot DIR`, `taskset MASK`, `chrt PRIO`); an option's value (`ionice -c 2`,
# `sandbox-exec -p PROFILE`, `timeout -s KILL`) is skipped by the option rule.
_STDIN_WRAPPERS = frozenset(('env', 'command', 'exec', 'builtin', 'eval', 'nohup', 'nice', 'time', 'sudo', 'doas',
                             'noglob', 'nocorrect', 'stdbuf', 'caffeinate', 'arch', 'timeout', 'setsid',
                             'ionice', 'unbuffer', 'sandbox-exec', 'chroot', 'taskset', 'chrt', 'watch'))
_WRAPPER_OPERANDS = {'timeout': 1, 'chroot': 1, 'taskset': 1, 'chrt': 1}
# What in a simple command's raw span makes main split it differently from the shell (or hides a
# substitution from it): a path-qualified git there is judged here too.
_SPAN_UNSAFE = re.compile(r'[;|&\n`]|\$[({]')
# `\0NNN` (echo -e's octal: a 0 and up to three digits; printf's `\NNN` is `_ANSI_ESCAPE`'s)
_ECHO_OCTAL = re.compile(r'\\0([0-7]{1,3})')
# What an UNQUOTED heredoc body does to a backslash: `\<newline>` is removed, `\$ \` \\` lose it.
_HD_UNESCAPE = re.compile(r'\\(\n|[$`\\])')


def _dq_view(raw, i, n, cur):
    """`_word_view` inside "...": append what the text from `raw[i]` (just past the opening quote)
    reads as to `cur` and return the offset after the closing quote - None when the string runs an
    expansion (`$x`, `${..}`, `$(..)`, a backtick) or is unterminated."""
    while i < n:
        m = _VIEW_DQ_PLAIN.match(raw, i)
        if m is not None:
            cur.append(m.group())
            i = m.end()
            continue
        c = raw[i]
        if c == '"':
            return i + 1
        if c == '`':
            return None
        if c == '\\':
            nx = raw[i + 1:i + 2]
            if nx == '':
                return None
            if nx != '\n':
                cur.append(nx if nx in '$`"\\' else '\\' + nx)
            i += 2
        else:
            nx = raw[i + 1:i + 2]
            if nx.isalnum() or nx in _VIEW_EXPANSION:
                return None
            cur.append('$')
            i += 1
    return None


def _word_view(raw, split=None, legacy=False):
    """The fields the shell makes of the word whose RAW text is `raw`, with the quoting resolved:
    quotes and backslashes removed, `$'...'` ANSI-C escapes decoded (`_ansi_c`), `$"..."` as
    "...", and the word split at an UNQUOTED `$IFS` / `${IFS}` (whitespace IFS: empty fields
    drop). None when the word cannot be read without running an expansion - `$(`, a backtick,
    `${..}`, `$name`, `$1`, `$@` ... (`${IFS}` and `$IFS` aside): it is a residual, not a guess.
    `split`, a list, gets a True appended for each `$IFS` the word was split at. Linear in
    `len(raw)`: plain runs are consumed by regex."""
    fields = []
    cur = []
    i = 0
    n = len(raw)
    while i < n:
        m = _VIEW_PLAIN.match(raw, i)
        if m is not None:
            cur.append(m.group())
            i = m.end()
            continue
        c = raw[i]
        if c == '\\':
            nx = raw[i + 1:i + 2]
            if nx == '':
                cur.append('\\')
            elif nx != '\n':                    # `\<newline>` is a continuation
                cur.append(nx)
            i += 2
        elif c == "'":
            k = raw.find("'", i + 1)
            if k < 0:
                return None
            cur.append(raw[i + 1:k])
            i = k + 1
        elif c == '"':
            i = _dq_view(raw, i + 1, n, cur)
            if i is None:
                return None
        elif c == '`':
            return None
        else:                                   # `$`
            nx = raw[i + 1:i + 2]
            if nx == "'":
                m = _ANSI_BODY.match(raw, i + 2)
                if m is None:
                    return None
                cur.append(_ansi_c(m.group(1), legacy))
                i = m.end()
            elif nx == '"':
                i = _dq_view(raw, i + 2, n, cur)
                if i is None:
                    return None
            elif raw.startswith('{IFS}', i + 1) or (
                    raw.startswith('IFS', i + 1) and _NAME_CHAR.match(raw, i + 4) is None):
                fields.append(''.join(cur))
                cur = []
                if split is not None:
                    split.append(True)
                i += 6 if nx == '{' else 4
            elif nx.isalnum() or nx in _VIEW_EXPANSION:
                return None
            else:
                cur.append('$')
                i += 1
    fields.append(''.join(cur))
    return [f for f in fields if f]


def _ansi_value(w, text, legacy=False):
    """The value of the operand `w` when it is written with `$'...'` ANSI-C escapes and differs
    from the de-quoted text the lexer holds (`$'git\\x20push'` is `git push` to the shell, and
    `git\\x20push` to the lexer); else None. Only operands that ARE code use it - never
    an argument, so `echo $'git push'` stays data."""
    if not isinstance(w, _W) or w.spelled or not 0 <= w.start < w.end <= len(text):
        return None
    raw = text[w.start:w.end]
    if "$'" not in raw or '\\' not in raw:
        return None
    view = _word_view(raw, None, legacy)
    if not view:
        return None
    value = ' '.join(view)
    return value if value != w else None


_FD_NAME = re.compile(r'\{[A-Za-z_][A-Za-z0-9_]*\}\Z')


def _command_words(words):
    """`(ops, here)` of one simple command: `words` without its redirection operators and their
    targets (`ops`, the command words proper) and the targets of its `<<<` herestrings (`here`).
    A `{name}` word that sits right against the operator after it (`{fd}>f`, `{fd}<&0`) is that
    redirection's fd variable, one more part of the redirection: dropped with it."""
    n = len(words)
    ops = []
    here = []
    k = 0
    while k < n:
        w = words[k]
        if w.redir:
            if k + 1 < n and not words[k + 1].redir:
                if w.endswith('<<<'):
                    here.append(words[k + 1])
                k += 2
            else:
                k += 1
            continue
        if (k + 1 < n and words[k + 1].redir and words[k + 1].start == w.end
                and _FD_NAME.match(w) is not None):
            k += 1                      # `{fd}` of `{fd}>f`: the operator (and its target) go next turn
            continue
        ops.append(w)
        k += 1
    return ops, here


def _piped_data(args, budget):
    """What the stages before a shell that reads its stdin can write to it (`args`: the arguments
    of EVERY earlier stage of the pipeline, which the lexer's `flush_cmd` collects from `info[3]`): each argument, and all of them joined
    with spaces (`echo <git words> | sh`). Every stage counts, not only the last one: a filter in
    between (`| cat |`, `| tee f |`, `| sed s/x/y/ |`) passes the data on. A `\\n` / `\\t` inside an
    argument is also read the way `printf` / `echo -e` do (`_ansi_c`). The work is charged to `budget[0]` BEFORE it is
    done, by argument count and then by size."""
    budget[0] -= 1 + len(args)
    if budget[0] < 0:
        raise _ExecOverBudget()
    budget[0] -= sum(map(len, args)) >> 6
    if budget[0] < 0:
        raise _ExecOverBudget()
    out = [a for a in args if a.strip()]
    if len(args) > 1:
        out.append(' '.join(args))
    seen = set(out)
    for a in list(out):
        if '\\' in a:
            # `printf` / `echo -e` read the escapes (`\n`, `\151`, `\x69`; echo's `\0151`): the
            # decoded text is there too, next to the raw one
            for v in (_ansi_c(a), _ansi_c(_ECHO_OCTAL.sub(_echo_octal, a))):
                if v not in seen and v.strip():
                    seen.add(v)
                    out.append(v)
    return out


def _psub_args(body, budget):
    """The arguments of every command in `body`, the inside of a `<( ... )` process substitution: what
    the commands in it can write, as `_piped_data` reads a pipe producer's arguments. One level only
    (a producer that is itself fed by another `<(..)` is a residual); what is unresolved is skipped."""
    lx = _Lexer(body, budget)
    lx.arg_sink = []
    try:
        lx.cmd(0, len(body), False, True)
    except _LexUncertain:
        pass
    return lx.arg_sink


def _spell_words(ops, text, budget):
    """`(flat, vals, spec, diff)` for the command words `ops` (`_command_words`): how the SHELL
    reads each of them, which is not how the lexer holds them. All four are parallel lists.

      flat  the words the scan looks at: `ops`, but a word with an UNQUOTED `$IFS` / `${IFS}` is cut
            into the fields the shell makes of it (`command${IFS}git` is the two words `command`
            and `git`, each a `_W` that spans the whole word) and a word that is ONLY `$IFS`
            vanishes - so a shell, `eval`, `env -S` or git is found at every field.
      vals  the value of each: `_word_view`'s reading (quotes, `$'..'` / `$".."`, `\\x` resolved),
            else the lexer's text (a word the reading cannot finish: `$x`, `$(..)`, a backtick).
      spec  the raw word has a quote, backslash or `$`: the reading was made.
      diff  the shell reads the word differently from what main's patterns see: split or dropped at
            `$IFS`, or written with `$'..'` / `$".."` (main's normaliser takes plain quotes and
            backslashes out, never those). A word that vanishes marks the one after it.

    Every special word costs `1 + len >> 6` steps, charged BEFORE it is read; a plain word costs
    nothing."""
    flat = []
    vals = []
    spec = []
    diff = []
    n = len(text)
    gone = False                        # a word before this one vanished (`$IFS` alone)
    for w in ops:
        raw = text[w.start:w.end] if 0 <= w.start < w.end <= n else ''
        if not raw or _VIEW_SPECIAL.search(raw) is None:
            flat.append(w)
            vals.append(w)
            spec.append(False)
            diff.append(gone)
            gone = False
            continue
        budget[0] -= 1 + (len(raw) >> 6)
        if budget[0] < 0:
            raise _ExecOverBudget()
        cut = []
        view = _word_view(raw, cut)
        if view is None or (len(view) == 1 and not cut):
            flat.append(w)
            vals.append(w if view is None else view[0])
            spec.append(True)
            diff.append(gone or (view is not None and (view[0] != w or "$'" in raw or '$"' in raw)))
            gone = False
        elif not view and cut:
            gone = True
        elif not view:                  # `''`: an empty word that stays
            flat.append(w)
            vals.append('')
            spec.append(True)
            diff.append(gone)
            gone = False
        else:
            for f in view:
                flat.append(_W(f, w.start, w.end, False, True))
                vals.append(f)
                spec.append(True)
                diff.append(True)
            gone = False
    return flat, vals, spec, diff


def _starts_main_segment(text, pos):
    """Does a simple command that starts at `text[pos]` start a segment of main's own split (`;`,
    `&&`, `||`, `|`, a newline, or the start of the text)? Blanks before it do not count. A single
    `&`, a `|&`, a `)` or `(` or `{` or a keyword (`then`, `if` ...) before it does NOT: main's
    patterns and its normaliser see a segment from the previous such separator on."""
    q = pos - 1
    while q >= 0:
        c = text[q]
        if c in ' \t':
            q -= 1
        elif c == '\n' and q > 0 and text[q - 1] == '\\':
            q -= 2                              # a `\<newline>` continuation is a blank
        else:
            break
    if q < 0:
        return True
    c = text[q]
    return c in ';|\n' or (c == '&' and q > 0 and text[q - 1] == '&')


def _first_plain_word(ops, spec, diff):
    """The index of the first word of `ops` that is not a plain `NAME=value` assignment (the form
    `_normalize_git_segment` skips: `_ENV_ASSIGN`, read the same way by the shell) - `len(ops)` when
    every word is one."""
    for i, w in enumerate(ops):
        if diff[i] or _ENV_ASSIGN.match(w) is None:
            return i
    return len(ops)


def _shell_payloads(words, text, budget, prev=None, info=None):
    """`(payloads, producing)` for one simple command (`words`, `_W`s: de-quoted, with their raw
    span in `text`). `payloads` are the strings it hands to a nested shell, found at ANY word - a
    wrapper (`find -exec`, `arch`, `xargs`), a zsh precommand modifier (`noglob`, `repeat 1`,
    `coproc`), a redirection or an assignment in front of it do not hide one:

      * the operand of `<shell> -c`, `<shell>` being any word that names a shell (`_is_shell_word`),
        with its options skipped (`-o X`, `+o X`, `-O X`, `--rcfile F`, `--init-file F`, `--`, the
        combined `-lc` / `-ec` / `-eo X`) - and, when that operand reads positional parameters
        and operands follow it, two more payloads with them substituted, quoted and raw (`bash -c
        'git $1' x push`, `bash -c '$1' x 'git push'`, `_substitute_positional`); fish's `--command STR` / `--command=STR` (and its unique
        abbreviations) too;
      * the space-joined words after `eval` - which, at the command position, is also a wrapper like
        `exec` (`_STDIN_WRAPPERS`): the words after it are read here too (`| eval bash`), the first
        `eval` alone carries the payload;
      * the first operand of `trap` (the action string);
      * the string of `env -S STR` / `-SSTR` / `--split-string STR` / `--split-string=STR`, once a
        word `env` has been seen;
      * the target of a `<<<` herestring when any word of the command names a shell (or `source`
        / `.` reads `/dev/stdin`);
      * what a `<( .. )` that a shell reads as its script (`bash <(..)`), that `source` / `.` reads
        (`source <(..)`) or that feeds a stdin shell (`bash < <(..)`) writes (`_psub_args`: the
        arguments of the commands inside it, one level);
      * what the stages BEFORE it in a pipeline write (`prev`: the arguments of every command
        before a `|` / `|&`, across a newline, blank lines and comments after the pipe), when this
        command holds a shell that reads its stdin - no `-c` and no script operand (`bash`, `sh -s`,
        `bash -`, `$SHELL`) - AND that shell is the stage's COMMAND word: the first word after
        assignments and redirections, or after only `_STDIN_WRAPPERS` / `_CMD_KEYWORDS` and their
        options (`sudo -u root bash`, `env A=1 bash`, `{ bash; }`); a shell word that is an
        ARGUMENT (`grep -v sh`, `tee sh`) reads nothing. `echo 'git push' | bash` (`_piped_data`:
        each argument, all of them joined, and `printf` / `echo -e` escapes decoded: `\\151`,
        `\\x69`, `\\0151`); a filter in between (`| cat |`, `| tee f |`) does not hide it;
      * the body of a heredoc whose command or pipeline holds such a stdin shell (`bash <<EOF`,
        `cat <<'EOF' | bash`): the lexer (`read_heredocs`) hands the body over as code, via `info`;
      * SPELLED GIT - the virtual segment `git <the rest of the command>` (`_Virtual`, ONE per git
        word, identical strings once), the rest being every later word as the SHELL reads it
        (`_spell_words`: `$'push'`, `$"push"`, `p$'u'sh`, `$IFS`, `${IFS}` resolved). It is made for
        a git word that is spelled (`GIT`, `/usr/bin/GIT`, `$'git'`, `$"git"`, `g''it`, `\\git`,
        `command${IFS}git`, `$'\\x67it'`: found at every field of every word), and for a plain
        `git` too when main cannot be trusted to see it as the shell runs it. A plain lower-case
        `git` (or `/usr/bin/git`) is skipped ONLY when ALL of these hold: every word before it is
        a plain `NAME=value` (`_ENV_ASSIGN`, main's pattern) and no redirection precedes it; the
        command starts a segment of main's own split (`_starts_main_segment`: the start, a
        newline, `;`, `|`, `&&`, `||` - not a single `&`, a `)`, a `(`, a `{`, `then` ...); and no
        later word is read differently from how main sees it (`diff`). Everything else - `echo
        git`, `xargs git`, `time git`, `{ git --git-dir . push; }`, `sleep 0 &git push`, `case x
        in x)git push`, `x+=1 /usr/bin/git push`, `>f /usr/bin/git push` - gets its segment, which
        the per-segment engine judges as a plain `git` (and main's normaliser sees). The segment
        never carries the assignments in front of the command: a hatch is NOT honoured through a
        spelling. A word the reading cannot finish (`$(..)`, a backtick, `$x`, `${..}`) is a
        residual, not a guess. Each rest word is charged a quarter step (`(m - k) >> 2`).

    Redirection operators and the word after each (its target) are dropped first: they are not
    command words (`>/dev/null bash -c P`, `bash 2>&1 -c P`, `{fd}>f bash -c P`), nor are leading
    assignments (`x+=1`, `x[0]=1`). `producing` is True when the command hands (or, cut off at
    an unresolved construct, can still hand) words to a shell: `eval`, a shell with `-c`, `trap`,
    `env -S`, or a herestring to a shell - the refusal in `_executed_code` starts at such a
    command. `info`, a list `[stdin_shell, seen, want_args, args]`, is the lexer's channel: it gets
    `stdin_shell` (this command reads its stdin as code), shares `seen` (the virtual segments
    already made) and, when `want_args`, gets `args` (what this stage writes to the next).

    RESIDUALS: ONE list, in the module docstring ("RESIDUALS - ONE LIST"); the tests pin a SAMPLE of
    it (`TestReviewM5Residuals.RESIDUALS`: each of those is still allowed), not every listed form, so
    closing one is a deliberate edit of the list (and of the sample where it is in it).
    Linear in the words, apart from the budget-charged positional substitution and the
    budget-charged virtual segments (each carries the rest of the command)."""
    ops, here = _command_words(words)
    ops, vals, spec, diff = _spell_words(ops, text, budget)
    m = len(ops)
    j = 0
    while j < m and _ANY_ASSIGN.match(ops[j]) is not None:
        j += 1
    first = j                   # the first command word
    payloads = []

    def add(w):
        # a payload; and its value when it is written with ANSI-C escapes (`_ansi_value`)
        payloads.append(w)
        v = _ansi_value(w, text)
        if v is not None:
            payloads.append(v)
        if isinstance(w, _W) and '\\c\\' in text[w.start:w.end]:
            v2 = _ansi_value(w, text, True)         # bash 3.2 / zsh read `\c\\` differently
            if v2 is not None and v2 != v:
                payloads.append(v2)

    producing = False
    shell_seen = False
    stdin_shell = False
    env_seen = False
    eval_seen = False           # an `eval` was met: its payload (everything after it) is made
    chain = True                # `ops[j]` is the stage's command word, or follows only wrappers / options
    opt_val = False             # the previous word was an option: this one may be its value
    pend = 0                    # positional operands the last wrapper still takes (`timeout DUR`)
    psubs = []                  # `<( .. )` words a shell or `source` reads as its script or its stdin
    while j < m:
        w = ops[j]
        base = _unequals(w).rsplit('/', 1)[-1]          # zsh's `=bash`, `=env`: the command's path
        low = base.lower() if len(base) <= _SHELL_NAME_MAX else ''
        if env_seen and w[:1] == '-':
            s = None
            if w[:2] == '--':
                key, eq, val = w.partition('=')
                if len(key) > 3 and '--split-string'.startswith(key):
                    s = val if eq else (ops[j + 1] if j + 1 < m else None)
            else:
                sm = _ENV_SPLIT_SHORT.match(w)
                if sm is not None:
                    s = sm.group(1) or (ops[j + 1] if j + 1 < m else None)
            if s is not None:
                producing = True
                if s.strip():
                    add(s)
        if low == 'env':
            env_seen = True
        elif w == 'eval':
            producing = True
            if not eval_seen:                 # the first `eval` carries the payload: a later one is inside it
                eval_seen = True
                rest = ' '.join(ops[j + 1:])      # the rest is the payload: its own `eval` is found there
                if rest.strip():
                    payloads.append(rest)
                    decoded = ' '.join([_ansi_value(x, text) or x for x in ops[j + 1:]])
                    if decoded != rest:
                        payloads.append(decoded)
                    if any(isinstance(x, _W) and '\\c\\' in text[x.start:x.end] for x in ops[j + 1:]):
                        # bash 3.2 / zsh read `\c\\` differently (`_ANSI_ESCAPE_LEGACY`): the same both-ways
                        # reading `add` gives a `-c` operand
                        legacy = ' '.join([_ansi_value(x, text, True) or x for x in ops[j + 1:]])
                        if legacy != rest and legacy != decoded:
                            payloads.append(legacy)
            if not chain:
                break                         # an `eval` that is an argument: the payload is all there is
            # at the command position `eval` is a wrapper like `exec`: a stdin shell behind it (`| eval
            # bash`, `eval source /dev/stdin <<< ..`) reads the pipe, so the words after it are read here too
        elif w == 'trap':
            producing = True
            a = j + 1
            while a < m and a < j + 4 and ops[a] in ('-p', '-l', '--'):
                a += 1
            if a < m and ops[a].strip():
                add(ops[a])
        elif w in ('source', '.') and chain and j + 1 < m and _is_stdin_path(ops[j + 1]):
            shell_seen = stdin_shell = True         # `source /dev/stdin <<< 'git push'`: stdin is code
        elif w in ('source', '.') and chain and j + 1 < m and ops[j + 1][:2] == '<(':
            psubs.append(ops[j + 1])                # `source <(echo 'git push')`
        elif _is_shell_word(w, text):
            shell_seen = True
            has_c = False
            has_s = False
            a = j + 1
            while a < m:
                x = ops[a]
                if x in _SHELL_OPT_WITH_ARG:
                    a += 2                  # `-o pipefail`, `--rcfile FILE`: the next word is its value
                elif x == '--':
                    a += 1                  # end of options: the next word is the operand
                    break
                elif len(x) > 1 and x[0] in '-+' and x[1] != '-':
                    if x[0] == '-':
                        if 'c' in x:
                            has_c = True
                        if 's' in x:
                            has_s = True    # `-s`: read commands from stdin, operands are `$1` ...
                    a += 2 if x[-1] in 'oO' else 1      # `-eo pipefail`
                elif x[:2] == '--':
                    key, eq, val = x.partition('=')
                    if len(key) >= 3 and '--command'.startswith(key):
                        # fish: `--command STR` / `--command=STR` (getopt abbreviations too)
                        cmd_str = val if eq else (ops[a + 1] if a + 1 < m else None)
                        producing = True
                        if cmd_str is not None and cmd_str.strip():
                            add(cmd_str)
                            if eq:
                                dv = _ansi_value(x, text)       # `--command=$'git\\x20push'`
                                if dv is not None:
                                    payloads.append(dv.partition('=')[2])
                        a += 1 if eq else 2
                    else:
                        a += 1              # `--norc`, `--login`
                else:
                    break                   # first operand
            if chain and not has_c and not has_s and a < m and ops[a][:2] == '<(':
                psubs.append(ops[a])                # `bash <(echo 'git push')`: the script is a process substitution
            if (chain and not has_c and (has_s or a >= m or _is_stdin_path(ops[a]))
                    and (_STDIN_SHELL.match(low) is not None or _SHELL_BASENAME.match(low) is None)):
                stdin_shell = True          # no command string, no script file: it reads its stdin
            if has_c:
                producing = True
                if a < m:
                    add(ops[a])                     # the command string
                    if a + 1 < m and _POSITIONAL.search(ops[a]) is not None:
                        done = {str(ops[a])}
                        # quoted: one word per operand; raw: the operand's own words; split: raw, with a
                        # tab / newline a blank (the unquoted `$1` is split at them)
                        for raw, split in ((False, False), (True, False), (True, True)):
                            subst = _substitute_positional(ops[a], vals, a + 1, m, budget, raw, split)
                            if subst not in done:
                                done.add(subst)
                                payloads.append(subst)
                    j = a
        if chain:
            if low in _STDIN_WRAPPERS or w in _CMD_KEYWORDS or _ANY_ASSIGN.match(w) is not None:
                opt_val = False
                pend = _WRAPPER_OPERANDS.get(low, 0) if low in _STDIN_WRAPPERS else 0
            elif w[:1] == '-':
                opt_val = True
            elif opt_val:
                opt_val = False
            elif pend:
                pend -= 1
            else:
                chain = False
        j += 1
    if shell_seen and here:
        producing = True
        for t in here:
            if t.strip():
                add(t)
    seen = set()
    if info is not None:
        info[0] = stdin_shell
        seen = info[1]
        if info[2]:             # what this stage can write to the next one: its arguments, as the shell reads them
            args = []
            for x in range(first + 1, m):
                args.append(str(ops[x]))
                if vals[x] != ops[x]:
                    args.append(str(vals[x]))       # as the shell reads it (`$'git\\x20push'`)
            for t in here:
                args.append(str(t))
                v = _ansi_value(t, text)
                if v is not None:
                    args.append(v)
            info[3] = args
    if stdin_shell and prev:
        payloads.extend(_piped_data(prev, budget))
    if stdin_shell:
        for x in range(len(words) - 1):             # `bash < <(echo 'git push')`
            if words[x].redir and words[x] in ('<', '0<') and words[x + 1][:2] == '<(' and not words[x + 1].redir:
                psubs.append(words[x + 1])
    for pw in psubs:
        if pw[-1:] == ')':
            payloads.extend(_piped_data(_psub_args(pw[2:-1], budget), budget))
    # Spelled git, at every word from the first command word on (see the docstring).
    last_diff = m - 1 - diff[::-1].index(True) if True in diff else -1
    plain_first = None
    clean_span = None
    for k in range(first, m):
        v = vals[k]
        zsh_equals = v[:1] == '=' and v[1:2] != '='     # zsh: `=git` is the path of git (one `=` only)
        if zsh_equals:
            v = v[1:]
        if len(v) < 3 or v[-3:].lower() != 'git':
            continue
        base = v.rsplit('/', 1)[-1]
        if len(base) != 3:
            continue
        if base == 'git' and not spec[k] and last_diff <= k and not zsh_equals:
            # A plain lower-case `git` is main's: skipped ONLY where main's normaliser and anchored
            # patterns see it as it runs - the first word of a main segment (after plain `NAME=value`
            # assignments, no redirection before it) with no spelled word after it. A PATH-qualified
            # one (`/usr/bin/git`) is main's only when main also splits the whole command the way
            # the shell does: main's raw pattern needs a space before a plain `git`, so it cannot
            # stand in for the normaliser when a `;` inside a quote or a `$(..)` in an assignment
            # moves the segment boundary (`A=$(echo 1) /usr/bin/git push`).
            if plain_first is None:
                plain_first = _first_plain_word(ops, spec, diff)
            if (k == plain_first and k < len(words) and words[k] is ops[k]
                    and _starts_main_segment(text, words[0].start)):
                if '/' in v and clean_span is None:
                    clean_span = _SPAN_UNSAFE.search(text, words[0].start, words[-1].end) is None
                if '/' not in v or clean_span:
                    continue
        budget[0] -= (m - k) >> 2                   # the rest rides along: four words cost a step
        if budget[0] < 0:
            raise _ExecOverBudget()
        code = _Virtual('git ' + shlex.join(vals[k + 1:]))
        if code not in seen:
            seen.add(code)
            payloads.append(code)
    return payloads, producing


class _Lexer:
    """The single shell lexer behind `_executed_code`. Method per context, all reading the same
    `text`; each takes the offset to resume at and `lim`, the exclusive end of the region it may
    read (the heredoc body, or the whole text), and returns the offset after the construct.

      cmd       command text: top level, and the body of `$(...)` / `(...)` / `<(...)` / `>(...)`
      dq        a "..." string          param     a `${...}` expansion       backtick  a `...`
      arith     `((...))` / `$((...))`  hd_body   an UNQUOTED heredoc body (double-quote-like)
      dollar    one `$` form

    `emit` is True where a substitution found is the OUTERMOST one - its body is recorded in
    `codes` (nested ones are found when that body is scanned again, one level down). Anything
    it cannot model with certainty raises `_LexUncertain(offset of the unresolved construct)`;
    `open` holds the start offsets of the constructs still open, outermost first."""

    def __init__(self, text, budget):
        self.text = text
        self.budget = budget
        self.codes = []
        self.open = []
        self.refuse_from = None     # set when the outermost `cmd` is cut short: see its handler
        self.virtual_seen = set()   # the `git ...` code strings spelled git already produced
        self.arg_sink = None        # a list: the arguments of EVERY stage lexed (`_psub_args`)

    def _enter(self, start):
        if len(self.open) >= _MAX_LEX_NEST:
            raise _LexUncertain(start)
        self.open.append(start)

    # -- $ forms -------------------------------------------------------------------------
    def dollar(self, j, lim, in_dq, emit, cur, ext=False):
        """text[j] == '$'. Appends the word text of the form to `cur`; returns the offset after
        it. `$$ $? $# $! $@ $* $- $0..$9` and `$name` are one unit each, so the `'` in `$$'a\\'`
        starts an ordinary quote; `$'..'` is ANSI-C only for a `$` met HERE (a `$` that is the
        second char of `$$`, or escaped, never reaches this point), and only outside double
        quotes - except directly inside a `${...}` (`ext`: bash's default `extquote` option
        performs `$'..'` there even when the expansion is double-quoted: `"${x%$'\n'}"`)."""
        text = self.text
        i = j + 1
        if i >= lim:
            cur.append('$')
            return i
        c = text[i]
        if c == '(':
            if text.startswith('((', i, lim):
                e = self.arith(j, i + 2, lim, emit)
                if e is not None:
                    cur.append(text[j:e])
                    return e
            e = self.sub(j, i + 1, lim, emit)
            cur.append(text[j:e])
            return e
        if c == '{':
            e = self.param(j, i + 1, lim, in_dq, emit)
            cur.append(text[j:e])
            return e
        if c == '[':                        # old `$[ ... ]` arithmetic: not modelled
            raise _LexUncertain(j)
        if c == "'" and (ext or not in_dq):     # `$'...'` ANSI-C quote: escapes NOT interpreted
            am = _ANSI_C.match(text, i, lim)
            if am is None:
                raise _LexUncertain(j)
            cur.append(am.group(0)[1:-1])
            return am.end()
        if c == '"' and not in_dq:          # `$"..."` locale quote: drop the `$`
            return i
        if c in '$?#!@*-' or '0' <= c <= '9':
            cur.append(text[j:i + 1])
            return i + 1
        m = _NAME.match(text, i, lim)
        if m is not None:
            cur.append(text[j:m.end()])
            return m.end()
        cur.append('$')
        return i

    def sub(self, start, body, lim, emit):
        """`$(`, `(`, `<(`, `>(` opened at `start`, body from `body`: lexed with `cmd`, the same
        routine as the top level. Returns the offset after the closing `)`."""
        self._enter(start)
        end = self.cmd(body, lim, True, False)
        self.open.pop()
        if emit:
            self.codes.append(self.text[body:end - 1])
        return end

    def param(self, start, i, lim, in_dq, emit):
        """`${...}` (opened at `start`, body from `i`): `(` and `)` are literal, `}` closes,
        `$(` / `${` / `$((` / backticks nest. Quotes parse as quotes at top level; inside a
        double-quoted string their rules depend on the operator, so they are uncertain there
        (`$'..'` aside: see `dollar`)."""
        text = self.text
        budget = self.budget
        self._enter(start)
        while True:
            budget[0] -= 1
            if budget[0] < 0:
                raise _ExecOverBudget()
            m = _LEX_PARAM.search(text, i, lim)
            if m is None:
                raise _LexUncertain(start)
            j = m.start()
            c = text[j]
            i = j + 1
            if c == '}':
                break
            if c == '\\':
                i += 1
            elif c == '$':
                i = self.dollar(j, lim, in_dq, emit, [], True)
            elif c == '`':
                i = self.backtick(i, lim, emit, j, in_dq)
            elif in_dq:
                raise _LexUncertain(j)
            elif c == "'":
                k = text.find("'", i, lim)
                if k < 0:
                    raise _LexUncertain(j)
                i = k + 1
            else:
                i = self.dq(i, lim, [], emit, j)
        self.open.pop()
        return i

    def dq(self, i, lim, cur, emit, start):
        """A "..." string opened at `start`, body from `i`; the de-quoted text goes to `cur`.
        Only `\\` (before `$`, backtick, `"`, `\\`, newline), `$` and backtick are active."""
        text = self.text
        budget = self.budget
        self._enter(start)
        while True:
            budget[0] -= 1
            if budget[0] < 0:
                raise _ExecOverBudget()
            m = _LEX_DQ.search(text, i, lim)
            if m is None:
                raise _LexUncertain(start)
            j = m.start()
            if j > i:
                cur.append(text[i:j])
            c = text[j]
            i = j + 1
            if c == '"':
                break
            if c == '\\':
                if i >= lim:
                    raise _LexUncertain(start)
                nx = text[i]
                cur.append('' if nx == '\n' else nx if nx in '$`"\\' else '\\' + nx)
                i += 1
            elif c == '`':
                i = self.backtick(i, lim, emit, j, True)
                cur.append(text[j:i])
            else:
                i = self.dollar(j, lim, True, emit, cur)
        self.open.pop()
        return i

    def backtick(self, i, lim, emit, start, in_dq):
        """A `...` opened at `start`, body from `i`: it ends at the first UNESCAPED backtick
        (quotes inside do not matter); the body the shell runs has `\\$`, `\\``, `\\\\` (and
        `\\"` inside double quotes) unescaped. Its inner text is lexed when it is scanned as
        code one level down, not here."""
        text = self.text
        budget = self.budget
        k = i
        while True:
            budget[0] -= 1
            if budget[0] < 0:
                raise _ExecOverBudget()
            m = _LEX_BQ.search(text, k, lim)
            if m is None:
                raise _LexUncertain(start)
            j = m.start()
            if text[j] == '\\':
                k = j + 2
                continue
            break
        if emit:
            raw = text[i:j]
            body = _BQ_UNESCAPE.sub(r'\1', raw)
            self.codes.append(body)
            if in_dq:
                alt = _BQ_UNESCAPE_DQ.sub(r'\1', raw)
                if alt != body:
                    self.codes.append(alt)
        return j + 1

    def arith(self, start, i, lim, emit):
        """`$((` / `((` opened at `start`, body from `i`. Counts parens; `<<` / `>>` are shifts
        here; `$(...)` / backticks nest; ANY quote is uncertain. Returns the offset after the
        closing `))`, or None when the closer is a lone `)` (bash then reads `( (` nested
        subshells - the caller re-lexes it as a subshell). The body itself is also recorded as
        a code string (it covers that ambiguity); nested substitutions are found through it."""
        text = self.text
        budget = self.budget
        body = i
        self._enter(start)
        depth = 0
        while True:
            budget[0] -= 1
            if budget[0] < 0:
                raise _ExecOverBudget()
            m = _LEX_ARITH.search(text, i, lim)
            if m is None:
                self.open.pop()
                return None
            j = m.start()
            c = text[j]
            i = j + 1
            if c == '(':
                depth += 1
            elif c == ')':
                if depth:
                    depth -= 1
                elif text.startswith(')', i, lim):
                    self.open.pop()
                    if emit:
                        self.codes.append(text[body:j])
                    return i + 1
                else:
                    self.open.pop()
                    return None
            elif c == '\\':
                i += 1
            elif c == '`':
                i = self.backtick(i, lim, False, j, True)
            elif c == '$':
                i = self.dollar(j, lim, True, False, [])
            else:                           # ' or "
                raise _LexUncertain(start)

    def hd_word(self, k, lim, op):
        """The word after `<<` / `<<-` at `k` -> (end offset, delimiter after quote removal,
        quoted?). Only forms that can be quote-removed with certainty: bare word characters,
        `'...'`, `"..."` holding no `\\` `$` backtick or `'`, `\\X`, and concatenations. Anything
        else (`$'EOF'`, `"a\\"b"`, `$x`, nothing at all) raises."""
        text = self.text
        parts = []
        quoted = False
        start = k
        while k < lim:
            c = text[k]
            if c in ' \t\n;&|()<>':
                break
            if c == "'":
                e = text.find("'", k + 1, lim)
                if e < 0:
                    raise _LexUncertain(op)
                parts.append(text[k + 1:e])
                quoted = True
                k = e + 1
            elif c == '"':
                e = text.find('"', k + 1, lim)
                if e < 0:
                    raise _LexUncertain(op)
                inner = text[k + 1:e]
                if '\\' in inner or '$' in inner or '`' in inner or "'" in inner:
                    raise _LexUncertain(op)
                parts.append(inner)
                quoted = True
                k = e + 1
            elif c == '\\':
                if k + 1 >= lim or text[k + 1] == '\n':
                    raise _LexUncertain(op)
                parts.append(text[k + 1])
                quoted = True
                k += 2
            elif c == '$' or c == '`':
                raise _LexUncertain(op)
            else:
                m = _HEREDOC_BARE.match(text, k, lim)
                parts.append(m.group(0))
                k = m.end()
        if k == start:
            raise _LexUncertain(op)
        delim = ''.join(parts)
        if '\n' in delim or '\t' in delim:      # a tab: shells disagree on which `<<-` line ends it
            raise _LexUncertain(op)
        return k, delim, quoted

    def hd_body(self, i, end, emit, op):
        """An UNQUOTED heredoc body, text[i:end]: scanned like a double-quoted string. Only `\\`
        (before `$`, backtick, `\\`, newline), `$(`, `${`, `$((` and backticks are active;
        `'`, `"`, `(`, `#` are literal data."""
        text = self.text
        budget = self.budget
        self._enter(op)
        while True:
            budget[0] -= 1
            if budget[0] < 0:
                raise _ExecOverBudget()
            m = _LEX_HDBODY.search(text, i, end)
            if m is None:
                break
            j = m.start()
            c = text[j]
            i = j + 1
            if c == '\\':
                i += 1
            elif c == '`':
                i = self.backtick(i, end, emit, j, False)
            else:
                i = self.dollar(j, end, True, emit, [])
        self.open.pop()

    # -- command text --------------------------------------------------------------------
    def cmd(self, i, lim, closer, emit):
        """Lex command text from `i` to `lim`; with `closer` (a `$(` / `(` body) stop after the
        unmatched `)` and return the offset after it, else return `lim`. Builds the words of
        each simple command (redirection operators are `_W(..., redir=True)` tokens, not
        separators: `>&`, `&>` are not `&`, `|&` is a pipe) and, when `emit`, records the
        payloads handed to a nested shell (`_shell_payloads`) and the outermost substitutions.
        Tracks `case ... esac` (its `pat)` does not close a substitution) and pending heredocs."""
        text = self.text
        budget = self.budget
        codes = self.codes
        words = []              # words of the current simple command
        cur = []                # pieces of the word being built
        in_word = False
        plain = True            # the word so far is plain unquoted text
        wstart = 0
        pend = []               # pending heredocs: (offset of `<<`, delimiter, `<<-`?, body is literal)
        cases = []              # open `case`s: 'in?' (before `in`), 'pat' (patterns), 'body' (commands)
        pat_end = 0             # offset just after the `)` that last closed a case pattern
        prev = None             # the arguments of the earlier stages, while a pipeline runs
        pipe_from = 0           # where that pipeline starts
        pipe_open = False       # the last command ended at a `|` / `|&`: the pipeline goes on, newlines or not
        line_shell = False      # a command of this line reads its stdin as shell code (a heredoc body is code)
        held = []               # heredoc bodies of a line that ENDS with a pipe: code if a LATER stage reads stdin as code

        def cmd_position():
            return not words or all(w in _CMD_KEYWORDS for w in words)

        def flush_word(end):
            nonlocal in_word, plain
            if not in_word:
                return
            s = ''.join(cur)
            del cur[:]
            was_plain = plain
            in_word = False
            plain = True
            if was_plain and s in _CASE_WORDS:
                if s == 'case':
                    if cmd_position() and not (cases and cases[-1] == 'pat'):
                        cases.append('in?')
                elif s == 'in':
                    if cases and cases[-1] == 'in?':
                        cases[-1] = 'pat'
                        del words[:]
                        return
                elif cases and cases[-1] != 'in?' and cmd_position():     # esac
                    cases.pop()
            words.append(_W(s, wstart, end))

        def flush_cmd(pipe=False):
            # `pipe`: the command ends at a `|` / `|&`, so its words are what the next one reads.
            nonlocal prev, pipe_from, pipe_open, line_shell
            pipe_open = pipe
            if words:
                info = [False, self.virtual_seen, pipe or self.arg_sink is not None, []]
                if emit:
                    codes.extend(_shell_payloads(words, text, budget, prev, info)[0])
                    line_shell = line_shell or info[0]
                    if self.arg_sink is not None:
                        self.arg_sink.extend(info[3])
                    if info[0] and held:
                        # `cat <<EOF |` newline body `EOF` newline `bash`: the shell is a later stage of
                        # the pipeline the heredoc feeds, and it reads what that stage wrote
                        codes.extend(held)
                        del held[:]
                if pipe:
                    if prev is None:
                        prev = []
                        pipe_from = words[0].start      # the first stage of this pipeline
                    prev.extend(info[3])
                else:
                    prev = None
                    del held[:]
                del words[:]
            elif not pipe:
                prev = None
                del held[:]

        def redir_op(j, op, fd=True):
            # A redirection operator token. A word of ONLY digits right before it is the fd.
            nonlocal in_word, plain
            s = j
            e = j + len(op)
            if in_word:
                w = ''.join(cur)
                if fd and plain and _DIGITS.match(w):
                    s = wstart
                    op = w + op
                    del cur[:]
                    in_word = False
                else:
                    flush_word(j)
            words.append(_W(op, s, e, True))

        def read_heredocs(pos, feeds):
            # `pos` is just past a newline: consume each pending body up to its delimiter line - the
            # first line that IS the delimiter (after its leading tabs, for `<<-`). Found by string
            # search and line comparison, never by a regex built per delimiter: a regex compile per
            # distinct delimiter made a command of thousands of heredocs several times slower. Each
            # line that merely CONTAINS the delimiter costs a step; every other line costs nothing.
            for op, delim, strip, quoted in pend:
                p = pos                 # always the start of a line
                while True:
                    budget[0] -= 1
                    if budget[0] < 0:
                        raise _ExecOverBudget()
                    k = text.find(delim, p, lim)
                    if k < 0:
                        raise _LexUncertain(op)
                    nl = text.rfind('\n', p, k)
                    ls = p if nl < 0 else nl + 1                # start of the line holding the candidate
                    le = text.find('\n', k, lim)
                    if le < 0:
                        le = lim
                    line = text[ls:le]
                    if (line.lstrip('\t') if strip else line) == delim:
                        break
                    if le >= lim:
                        raise _LexUncertain(op)
                    p = le + 1
                if not quoted:
                    self.hd_body(pos, ls, emit, op)
                if emit and (feeds or pipe_open):
                    # A shell reads this body as its commands (`bash <<EOF`, `cat <<EOF | bash`):
                    # the body is code. Its text as written (a quoted delimiter: the shell reads it
                    # as is) and, for an unquoted one, as the shell expands the backslashes. When the
                    # line ends with a pipe (`pipe_open`) the shell may stand on a LATER line, after the
                    # body: it is held until a later stage of the pipeline turns out to be one.
                    body = text[pos:ls]
                    if body.strip():
                        budget[0] -= 1 + (len(body) >> 6)
                        if budget[0] < 0:
                            raise _ExecOverBudget()
                        bodies = [body]
                        if not quoted:
                            plain = _HD_UNESCAPE.sub(lambda e: '' if e.group(1) == '\n' else e.group(1), body)
                            if plain != body:
                                bodies.append(plain)
                        (codes if feeds else held).extend(bodies)
                pos = min(le + 1, lim)
            del pend[:]
            return pos

        try:
            while i < lim:
                budget[0] -= 1
                if budget[0] < 0:
                    raise _ExecOverBudget()
                j = _LEX_CMD_RUN.match(text, i, lim).end()
                if j > i:
                    # Each word of the run costs a step, charged BEFORE the (Python-level) loop
                    # that splits it: the blanks are counted at C speed, so a megabyte of words
                    # is refused up front instead of after it has been scanned.
                    nb = text.count(' ', i, j) + text.count('\t', i, j)
                    if nb:
                        budget[0] -= nb
                        if budget[0] < 0:
                            raise _ExecOverBudget()
                    pos = i
                    for bm in _BLANKS.finditer(text, i, j):
                        s = bm.start()
                        if s > pos:
                            if not in_word:
                                in_word = True
                                wstart = pos
                            cur.append(text[pos:s])
                        if in_word:
                            flush_word(s)
                        pos = bm.end()
                    if pos < j:
                        if not in_word:
                            in_word = True
                            wstart = pos
                        cur.append(text[pos:j])
                    if j >= lim:
                        i = lim
                        break
                c = text[j]
                i = j + 1
                if c == '\n':
                    goes_on = pipe_open and not words and not in_word      # `a |` newline `b`
                    flush_word(j)
                    if not goes_on:
                        flush_cmd()
                    if pend:
                        i = read_heredocs(i, line_shell)
                    line_shell = False
                elif c == '\\':
                    if i < lim:
                        nx = text[i]
                        if nx != '\n':      # `\<newline>` is a continuation: no word material
                            if not in_word:
                                in_word = True
                                wstart = j
                            plain = False
                            cur.append(nx)
                        i += 1
                    else:
                        if not in_word:
                            in_word = True
                            wstart = j
                        cur.append('\\')
                elif c == "'":
                    k = text.find("'", i, lim)
                    if k < 0:
                        raise _LexUncertain(j)
                    if not in_word:
                        in_word = True
                        wstart = j
                    plain = False
                    cur.append(text[i:k])
                    i = k + 1
                elif c == '"':
                    if not in_word:
                        in_word = True
                        wstart = j
                    plain = False
                    i = self.dq(i, lim, cur, emit, j)
                elif c == '`':
                    if not in_word:
                        in_word = True
                        wstart = j
                    plain = False
                    i = self.backtick(i, lim, emit, j, False)
                    cur.append(text[j:i])
                elif c == '$':
                    if not in_word:
                        in_word = True
                        wstart = j
                    plain = False
                    i = self.dollar(j, lim, False, emit, cur)
                elif c == '#':
                    if in_word:
                        cur.append('#')         # mid-word `a#b`: not a comment
                    else:
                        k = text.find('\n', i, lim)         # a comment runs to the end of the line
                        i = lim if k < 0 else k
                elif c == ';':
                    flush_word(j)
                    flush_cmd()
                    if cases and cases[-1] == 'body' and i < lim and text[i] in ';&':
                        i += 1                  # `;;` `;&` `;;&`: the next clause's patterns
                        if text[i - 1] == ';' and i < lim and text[i] == '&':
                            i += 1
                        cases[-1] = 'pat'
                elif c == '&':
                    if text.startswith('&&', j, lim):
                        flush_word(j)
                        flush_cmd()
                        i = j + 2
                    elif text.startswith('&>', j, lim):
                        n2 = 3 if text.startswith('&>>', j, lim) else 2
                        redir_op(j, text[j:j + n2], False)
                        i = j + n2
                    else:
                        flush_word(j)
                        flush_cmd()
                elif c == '|':
                    flush_word(j)
                    nxt = text[i] if i < lim else ''
                    flush_cmd(nxt != '|')       # `||` is an or-list, `|` and `|&` pipe
                    if nxt in ('|', '&'):
                        i += 1
                elif c == ')':
                    flush_word(j)
                    if cases and cases[-1] == 'pat':
                        del words[:]            # the `)` ends a case pattern, not a substitution
                        cases[-1] = 'body'
                        pat_end = i
                    else:
                        if cases and cases[-1] == 'body' and _BLANK_RUN.match(text, pat_end, j).end() == j:
                            # `(x))`: zsh reads `(x)` as a group pattern and this `)` as the one
                            # that ends it, bash (and this lexer) a pattern `x` and a stray `)`
                            # that closes the substitution early - after which the rest of the
                            # case body would be read as arguments of the command around it.
                            raise _LexUncertain(j)
                        flush_cmd()
                        if closer:
                            if pend:
                                raise _LexUncertain(pend[0][0])
                            return i
                elif c == '(':
                    if cases and cases[-1] == 'pat' and not in_word:
                        continue                # `(pat)`: the optional leading paren
                    if not in_word and text.startswith('(', i, lim):
                        e = self.arith(j, i + 1, lim, emit)
                        if e is not None:       # `(( ... ))` command
                            flush_cmd()
                            i = e
                            continue
                    flush_word(j)
                    flush_cmd()
                    i = self.sub(j, i, lim, emit)
                else:                           # `<` or `>`
                    if c == '<' and text.startswith('<<', j, lim) and not text.startswith('<<<', j, lim):
                        k = j + 2
                        strip = k < lim and text[k] == '-'
                        if strip:
                            k += 1
                        while k < lim and text[k] in ' \t':
                            k += 1
                        e, delim, quoted = self.hd_word(k, lim, j)
                        redir_op(j, '<<-' if strip else '<<')
                        words.append(_W(text[k:e], k, e))
                        pend.append((j, delim, strip, quoted))
                        i = e
                    elif text.startswith('(', i, lim):     # `<(` / `>(` process substitution
                        flush_word(j)
                        e = self.sub(j, i + 1, lim, emit)
                        in_word = True
                        wstart = j
                        plain = False
                        cur.append(text[j:e])
                        i = e
                    else:
                        two = text[j:j + 3]
                        if two == '<<<':
                            op = '<<<'
                        elif two[:2] in ('>>', '>&', '>|', '<>', '<&'):
                            op = two[:2]
                        else:
                            op = c
                        redir_op(j, op)
                        i = j + len(op)
            if closer:
                raise _LexUncertain(self.open[-1])
            flush_word(lim)
            if pend:
                raise _LexUncertain(pend[0][0])
        except _LexUncertain as exc:
            if emit and not closer:
                # What was read BEFORE the unresolved construct is complete code too, and the
                # refusal (`_executed_code`) only looks from the construct on: so the word being
                # built counts as a word (`bash -c 'git push '$[1]` hands `git push ` to a shell)
                # and the commands completed so far are extracted. Only this outermost frame has
                # anything to add: every nested frame lies inside `open[0]`, which the refusal
                # already counts from.
                #
                # Extraction is not enough: the unresolved part can SUPPLY what follows - inside
                # double quotes `${x:-'push'}` keeps its quotes, so `bash -c 'git '"${x:-'push'}"`
                # runs `git push` while all that was extracted is `git `. So the refusal starts
                # no later than the word being built, nor than the START of the current command
                # when that command hands its words to a shell (`_shell_payloads`: eval, a shell
                # with `-c`, trap, `env -S`, a herestring - or the word being built IS `eval` or
                # a shell): the git mention that decides it may sit anywhere in that command.
                starts = []
                building = in_word
                if building:
                    starts.append(wstart)
                flush_word(lim)
                cur_start = words[0].start if words else None
                if words:
                    found, producing = _shell_payloads(words, text, budget, prev)
                    codes.extend(found)
                    if producing or (building and (words[-1] == 'eval' or _is_shell_word(words[-1], text))):
                        starts.append(words[0].start)
                    del words[:]
                if (prev is not None or cur_start is not None) and _PIPE_SINK.search(text, exc.pos, lim):
                    # The unresolved construct sits in a pipeline that goes on (ANY `|` after it:
                    # the next stage can be a shell however it is spelled - `ba's'h`, `s''h`,
                    # `$SHELL` - and this scan never gets that far): what the stages up to here
                    # write can reach it. So the refusal starts at the first stage.
                    starts.append(pipe_from if prev is not None else cur_start)
                if starts:
                    self.refuse_from = min(starts)
            raise
        flush_cmd()
        return lim


def _executed_code(text, budget):
    """Return the code strings that `text` hands to a nested shell, one level down:
      - the operand of `<shell> -c` (and fish's `--command`), the arguments of `eval`, `trap`'s
        action, `env -S STR`, a herestring, the data piped into a shell that reads its stdin, the
        body of a heredoc fed to one, and - for every word that SPELLS `git` however it is written
        (`GIT`, `$'git'`, `g''it`, `command${IFS}git`, `$'\\x67it'`) and every plain `git` that is
        not main's - the virtual segment `git <the rest of the command>`; all of it found at ANY
        word of a simple command (see `_shell_payloads`, which holds the rules);
      - every OUTERMOST command substitution `$( ... )` / `` `...` ``, subshell `( ... )` and
        process substitution `<( ... )`, `>( ... )` (nested ones are found when that body is
        itself scanned, one level deeper), the bodies of `$(( ... ))` / `(( ... ))`, and the
        substitutions inside an unquoted-delimiter heredoc body.

    One lexer (`_Lexer`) reads all of it. Inside single quotes nothing is extracted (literal
    data); inside double quotes and unquoted heredoc bodies only `$(` and backticks are (the
    shell executes them). A heredoc whose delimiter is QUOTED (`<<'EOF'`) has a literal body,
    which is skipped - a commit message full of `` `git push` `` must not read as code. `#`
    starts a comment only at the start of a word (blanks are only space and tab).

    FAILS CLOSED: input the lexer cannot model with certainty (see `_Lexer`) raises
    `_LexUncertain` - unless nothing from the start of the earliest unresolved construct to the
    end of `text` can spell git (`_GIT_MENTION`), in which case the codes found before it are
    returned: the commands completed so far AND the one being built, whose last word is cut at
    the construct (`bash -c 'git push '$[1]` yields `git push `). `budget[0]` is the steps left;
    running out raises `_ExecOverBudget`. Any other exception is a scanner fault and propagates
    to the caller."""
    lx = _Lexer(text, budget)
    try:
        lx.cmd(0, len(text), False, True)
    except _LexUncertain as exc:
        start = min(exc.pos, lx.open[0]) if lx.open else exc.pos
        if lx.refuse_from is not None:
            start = min(start, lx.refuse_from)
        if _git_mentioned(text, start):
            raise
    return lx.codes


def _note_carriers(seg, carried):
    """Collect the shell strings git runs for a segment (`_git_carrier_payloads`) into `carried`."""
    if isinstance(seg, str) and 'git' in seg.lower():
        payloads, refuse = _git_carrier_payloads(seg)
        carried.extend(payloads)
        if refuse:
            carried.append(_Refusal(_LEX_UNCERTAIN_MSG))


def _executable_segments(command, budget=None, depth=0):
    """`_executable_segments_main`, then the segments of every shell string git itself runs for
    the segments it yielded (`_git_carrier_payloads`): `git submodule foreach '<cmd>'`, `git
    rebase -x '<cmd>'`, ... The payload is a nested command line like a `bash -c` operand and is
    judged by the same whole engine; a payload that cannot be read is a `_Refusal`."""
    if budget is None:
        budget = [_MAX_EXEC_SCAN_STEPS, _MAX_EXEC_CODES]
    carried = []
    yield from _executable_segments_main(command, budget, depth, carried)
    for item in carried:
        if isinstance(item, _Refusal):
            yield item
            return
        budget[1] -= 1
        if budget[1] < 0:
            yield _Refusal(_EXEC_BUDGET_MSG)
            return
        if depth >= _MAX_EXEC_DEPTH:
            yield _Refusal(_NESTING_MSG)
            return
        yield from _executable_segments(item, budget, depth + 1)


def _executable_segments_main(command, budget, depth, carried):
    """Every shell segment of `command` (exactly what `_scannable_segments` yields, FIRST and
    unchanged), followed by the segments of the code it hands to a nested shell and of the
    virtual `git ...` segment of every spelled git (`_executed_code`; payloads, positional
    parameters, spelled git, heredoc bodies and pipe-to-shell are all extra segments, none a
    rewrite of a real one - so no hatch is ever honoured through them), recursively to
    `_MAX_EXEC_DEPTH`. A virtual segment (`_Virtual`) is a leaf: its own segments are judged,
    nothing is scanned inside it.
    Detection is ADDITIVE: it only ever yields more segments or a refusal. A `_Refusal` is
    yielded instead when the scan is over its step / code-count cap, nested too deep to follow,
    cannot parse the text with certainty (`_LexUncertain`) or crashes - the caller blocks, so no
    failure of the scan can turn into an allow. `budget` is `[scanner steps left, nested code
    strings left]`, shared by every level.

    Only text that spells `git` is ever scanned for nested code: nested code is a de-quoted
    rewrite of its parent, so it can only contain a git invocation if the parent contains a
    `g<quotes>i<quotes>t` spelling. That keeps a big git-free command (a heredoc writing a
    file) entirely off this path. The scan reads the RAW command (see the note above); only
    the real segments come from the continuation-joined lines."""
    for seg in _scannable_segments(command):
        yield seg
        _note_carriers(seg, carried)
    text = command
    if not _git_mentioned(text):
        return
    try:
        codes = _executed_code(text, budget)
    except _ExecOverBudget:
        yield _Refusal(_EXEC_BUDGET_MSG)
        return
    except Exception:       # `_LexUncertain`, or a scanner fault: either way, cannot see = refuse
        yield _Refusal(_LEX_UNCERTAIN_MSG)
        return
    for code in codes:
        if not _git_mentioned(code):
            continue
        budget[1] -= 1
        if budget[1] < 0:
            yield _Refusal(_EXEC_BUDGET_MSG)
            return
        if isinstance(code, _Virtual):
            for seg in _scannable_segments(code):       # a leaf: see `_Virtual`
                yield seg
                _note_carriers(seg, carried)
            continue
        if depth >= _MAX_EXEC_DEPTH:
            yield _Refusal(_NESTING_MSG)
            return
        yield from _executable_segments(code, budget, depth + 1)


def _git_evaluate(command: str):
    """Thin wrapper around `_git_evaluate_impl()` (2026-08-27 I-3b Unit
    1b-i). Kept as the stable public entry point — same name, same
    `(command: str)` signature, same `(exit_code, message_or_None)` return
    contract — because it is imported and called directly as a module by
    tests and by probes; renaming it or changing its return shape breaks
    them.

    The ONLY things this wrapper adds over calling the impl directly are (a) the
    per-call `_EVAL_MEMO` scope (2026-10-06: one subprocess per distinct cwd/ref
    answers every hatched/`update-ref` segment) and (b) emitting exactly one
    `CAST_HATCH_RECORD_CAP` sentinel `ack_events` row (via `_record_hatch`) if
    `_git_evaluate_impl` suppressed one or more per-hatch records against
    `_MAX_HATCH_RECORDS_PER_COMMAND`. The sentinel is emitted on every exit
    path — an ALLOW return, a BLOCK return, or an ordinary exception — EXCEPT
    while a BaseException that is not an Exception is unwinding (the
    dispatcher's watchdog alarm: the sentinel is a 2 s subprocess and the
    budget has already expired). That matters because `_git_evaluate_impl` returns EARLY on the first BLOCK
    verdict in its per-segment loop: a suppression counter tallied only
    after the loop completes would be lost whenever a block follows a
    suppression later in the same command. The sentinel call itself is
    wrapped in its own try/except so it can never raise and never change
    the verdict computed by `_git_evaluate_impl` — same contract as
    `_record_hatch` itself.

    KNOWN LIMITATION (named plainly, not buried): the `CAST_HATCH_RECORD_CAP`
    sentinel records only HOW MANY per-hatch records this invocation
    suppressed — it does not, and cannot, say which hatch variable(s), which
    git op(s), or which value(s) were involved. A responder investigating a
    cap-sentinel row has the count and the command's rough timing only; the
    per-hatch detail for anything past the cap is gone, not just deferred.
    """
    global _EVAL_MEMO
    suppressed_counter = [0]

    def _emit_cap_sentinel():
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

    _EVAL_MEMO = {}   # see `_EVAL_MEMO`: scoped to exactly this call
    try:
        try:
            result = _git_evaluate_impl(command, suppressed_counter)
        except Exception:
            _emit_cap_sentinel()   # an ordinary error still records the suppressed count
            raise
        # NOT emitted when a BaseException that is not an Exception is unwinding (the
        # dispatcher's SIGALRM watchdog `_GitGuardTimeout`, KeyboardInterrupt, SystemExit):
        # `_record_hatch` is a subprocess with a 2 s timeout, and spawning it AFTER the
        # budget expired added 2 s to a 2 s budget (~4.2 s of the hook's 5 s).
        _emit_cap_sentinel()
        return result
    finally:
        _EVAL_MEMO = None


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

    A per-hatch row is written ONLY when the hatch actually AVERTED a block
    (2026-08-27 I-3b Unit 1b-ii, `record_hatch_use()` below), never on every
    hatched invocation: recording is gated on the relevant BLOCK regex
    itself having matched, since several BLOCK regexes are deliberately
    narrower than their matching ALLOW regex (e.g. `CAST_RESET_OK=1 git
    reset --soft` never trips `_RESET_BLOCK`, so it records nothing, while
    `CAST_RESET_OK=1 git reset --hard` does). `record_hatch_use()` also
    de-duplicates by variable WITHIN a segment, since one variable
    (`CAST_GC_OK`) gates four distinct BLOCK sites — a de-duplicated call is
    not a suppression and does not touch `suppressed_counter`.
    """
    hatch_record_count = 0
    tracker = _DirTracker()   # literal cd/pushd targets so far -- see `_DirTracker`
    scan_work = 0  # running `_scan_work` total — see `_MAX_GIT_SCAN_WORK`
    tokenized_bytes = 0  # running total handed to shlex — see `_MAX_GIT_TOKENIZE_BYTES`
    for seg in _executable_segments(command):
        if isinstance(seg, _Refusal):
            return 2, seg.msg   # nested code over its step / count cap or `_MAX_EXEC_DEPTH`, or unparseable
        seg = seg.strip()
        if not seg:
            continue
        tracker.observe(seg)
        # 2026-08-17 shlex tokenization pass: `norm` is a quote-stripped,
        # absolute-path-normalized rendering of `seg` (None if `seg` isn't a
        # git invocation — see `_normalize_git_segment`'s docstring for why
        # that's deliberate, not an oversight). `hit()` checks every pattern
        # against BOTH the raw segment and its normalized form, closing the
        # quoted-token evasion class without rewriting any BLOCK/ALLOW regex.
        mentions_git = _GIT_MENTION.search(seg) is not None
        if mentions_git and len(seg) > _MAX_GIT_SEGMENT_LEN:
            return 2, _SCAN_BUDGET_MSG  # see `_MAX_GIT_SEGMENT_LEN`
        if mentions_git:
            tokenized_bytes += len(seg)
            if tokenized_bytes > _MAX_GIT_TOKENIZE_BYTES:
                return 2, _TOKENIZE_BUDGET_MSG  # see `_MAX_GIT_TOKENIZE_BYTES`
        norm = _normalize_git_segment(seg) if mentions_git else None
        variants = (seg, norm) if norm else (seg,)
        # 2026-10-07 U6a-1 security F5: `GIT_CONFIG_KEY_0=$'core.pager' git ...` — the ANSI-C
        # string is decoded by the shell, so the regex views also get the decoded text.
        # Deliberately NOT added to `variants`: a decoded `$'git'` would turn heredoc DATA
        # into a spelled git for every other block. Only the GIT_CONFIG_* / exec-key
        # checks below read `env_variants`.
        dec_seg = (_decode_ansi_c_text(seg)
                   if mentions_git and "$'" in seg and 'GIT_CONFIG_' in seg else seg)
        env_variants = variants
        if dec_seg != seg:
            dec_norm = _normalize_git_segment(dec_seg)
            env_variants = variants + ((dec_seg, dec_norm) if dec_norm else (dec_seg,))

        def hit_env(pattern, _v=env_variants):
            return any(pattern.search(v) for v in _v)

        # 2026-10-06 security fix: refuse (fail closed) before any pattern
        # runs if this command's accumulated regex work would pass the bound
        # — see `_MAX_GIT_SCAN_WORK`. Checked on BOTH variants: `norm` can
        # turn `'git' 'git' ...` (no `git` token in `seg`) into a padded
        # string of real ones. A timeout is an ALLOW; this is a BLOCK.
        for variant in variants:
            scan_work += _scan_work(variant, _MAX_GIT_SCAN_WORK - scan_work)
        if scan_work > _MAX_GIT_SCAN_WORK:
            return 2, _SCAN_BUDGET_MSG

        def hit(pattern, _v=variants):
            return any(pattern.search(v) for v in _v)

        # 2026-08-27 I-3b Unit 1b-ii: a row is recorded ONLY when the hatch
        # actually AVERTED a block, never on every hatched invocation — the
        # BLOCK regexes below are deliberately narrower than their matching
        # ALLOW regexes (e.g. `_RESET_BLOCK` requires --hard/--merge/--keep
        # while `_RESET_ALLOW` matches any hatched `git reset`), so recording
        # is gated on the BLOCK regex having actually matched, not merely on
        # the ALLOW regex matching. `recorded_vars` de-duplicates within THIS
        # segment: `CAST_GC_OK` alone gates four distinct BLOCK sites below
        # (`_GC_BLOCK` plus the three `_GC_HATCH_ALLOW`-gated config blocks)
        # and must write at most one row per segment, not up to four. A
        # de-duplicated call is NOT a suppression — only cap-driven skips
        # increment `suppressed_counter`. `_seg=seg`/`_seen=recorded_vars`
        # mirror `hit()`'s `_v=variants` default-argument binding above, for
        # the same late-binding-capture reason.
        recorded_vars = set()

        def record_hatch_use(variable, git_op, _seg=seg, _seen=recorded_vars):
            # 2026-08-27 I-3b Unit 1b-ii, security review Low #2: `_record_hatch`
            # and `_hatch_value` are each independently documented "never
            # raises" and wrap their own internals — this try/except is
            # DELIBERATELY redundant with both, not a gap being patched. This
            # module's fail-open guarantee is load-bearing: a raise here would
            # propagate up through `_git_evaluate_impl` and turn an ALLOW/BLOCK
            # verdict into an unhandled exception instead. Making the
            # guarantee LOCAL (one wrap, here) rather than inherited from two
            # callees means it survives a future refactor of either one — do
            # NOT delete this as "redundant with the callees' own contracts."
            #
            # 2026-08-27 I-3b Unit 2b: migration 034's stated purpose was
            # "who bypassed which gate, when, and why" — the first three were
            # wired (Unit 1a/1b-ii); this adds the why. `CAST_HATCH_REASON`,
            # if present as a leading assignment ANYWHERE after the hatch
            # variable itself in the same segment (e.g. `CAST_RESET_OK=1
            # CAST_HATCH_REASON="rebasing onto main" git reset --hard`),
            # overwrites the recorded value with the reason text instead of
            # the hatch's own value ('1'). Overwriting loses nothing: every
            # `*_ALLOW` regex above requires the hatch literally `=1` to
            # grant the allow at all, so by the time this function runs the
            # hatch's own value has already done all the work it will ever
            # do — it carries no further information. `reason` is looked up
            # via `_hatch_value` on `_seg`, the RAW (non-normalized) segment
            # — `_hatch_value` calls `shlex.split` directly and already
            # returns a quoted multi-word value as one token on its own,
            # independent of `_normalize_git_segment`. This is a DIFFERENT
            # code path from whether the ALLOW regex matches at all: a
            # quoted multi-word `CAST_HATCH_REASON` value only keeps the
            # *_ALLOW hit() check passing because `_normalize_git_segment`
            # collapses it to `CAST_HATCH_REASON=_` before re-joining, giving
            # the ALLOW regex's `\S+`-per-assignment token a single word to
            # match — see `_normalize_git_segment`'s docstring. If that
            # normalization behavior ever changes, a quoted multi-word reason
            # will start BLOCKING outright (never reaching this function at
            # all) rather than silently losing its text — fails loudly, not
            # silently. No reason present -> falls back to the hatch's own
            # value, exactly as before this change (regression-safe).
            nonlocal hatch_record_count
            try:
                if variable in _seen:
                    return
                _seen.add(variable)
                if hatch_record_count < _MAX_HATCH_RECORDS_PER_COMMAND:
                    reason = _hatch_value(_seg, 'CAST_HATCH_REASON')
                    value = reason if reason else _hatch_value(_seg, variable)
                    _record_hatch(variable, value, git_op)
                    hatch_record_count += 1
                else:
                    suppressed_counter[0] += 1
            except Exception:
                pass

        if hit(_COMMIT_ALLOW):
            _audit_commit_hatch()
        if hit(_COMMIT_BLOCK):
            if hit(_COMMIT_ALLOW):
                record_hatch_use('CAST_COMMIT_AGENT', 'commit')
            else:
                return 2, _COMMIT_MSG
        if hit(_PUSH_ALLOW):
            _audit_push_hatch()
        if hit(_PUSH_BLOCK):
            if hit(_PUSH_ALLOW):
                record_hatch_use('CAST_PUSH_OK', 'push')
            else:
                return 2, _PUSH_MSG
        if hit(_STASH_BLOCK):
            if hit(_STASH_ALLOW):
                record_hatch_use('CAST_STASH_OK', 'stash')
            else:
                return 2, _STASH_MSG
        if hit(_RESET_BLOCK):
            if hit(_RESET_ALLOW):
                record_hatch_use('CAST_RESET_OK', 'reset')
            else:
                return 2, _RESET_MSG
        if _dry_run_block(_CLEAN_BLOCK, variants):
            if hit(_CLEAN_ALLOW):
                record_hatch_use('CAST_CLEAN_OK', 'clean')
            else:
                return 2, _CLEAN_MSG
        if (
            hit(_CHECKOUT_BLOCK)
            or any(_checkout_bare_path_blocks(v) for v in variants)
            or hit(_CHECKOUT_FORCE_BLOCK)
        ):
            if hit(_CHECKOUT_ALLOW):
                record_hatch_use('CAST_CHECKOUT_OK', 'checkout')
            else:
                return 2, _CHECKOUT_MSG
        if hit(_RESTORE_CMD):
            safe = hit(_RESTORE_HAS_STAGED) and not hit(_RESTORE_HAS_WORKTREE)
            if not safe:
                if hit(_RESTORE_ALLOW):
                    record_hatch_use('CAST_RESTORE_OK', 'restore')
                else:
                    return 2, _RESTORE_MSG
        if hit(_SWITCH_BLOCK):
            if hit(_SWITCH_ALLOW):
                record_hatch_use('CAST_SWITCH_OK', 'switch')
            else:
                return 2, _SWITCH_MSG
        if hit(_REFLOG_BLOCK):
            if hit(_REFLOG_ALLOW):
                record_hatch_use('CAST_REFLOG_OK', 'reflog')
            else:
                return 2, _REFLOG_MSG
        # 2026-10-07 U6a-2 (hazard E1): any git op in a repo already holding a symlinked
        # `worktrees/*` entry (implicit auto-gc runs the prune), then the static gc / maintenance
        # / worktree-prune blocks (a symlink planted in the SAME command is invisible here).
        if _plants_worktrees_symlink(seg, tracker):
            if hit(_WORKTREE_LN_ALLOW):
                record_hatch_use('CAST_WORKTREE_OK', 'worktree-symlink-plant')
            else:
                return 2, _WORKTREE_PLANT_MSG
        if mentions_git and (hazard := _worktree_symlink_hazard(
                (seg,) + ((dec_seg,) if dec_seg != seg else ()), tracker)):
            if hit(_WORKTREE_HATCH_ALLOW):
                record_hatch_use('CAST_WORKTREE_OK', 'worktree-symlink')
            else:
                return 2, _worktree_hazard_msg(hazard)
        if hit(_GC_ANY_BLOCK):
            if hit(_GC_ALLOW):
                record_hatch_use('CAST_GC_OK', 'gc')
            else:
                return 2, _GC_MSG if hit(_GC_BLOCK) else _GC_ANY_MSG
        if hit(_MAINTENANCE_BLOCK):
            if hit(_MAINTENANCE_ALLOW):
                record_hatch_use('CAST_GC_OK', 'maintenance')
            else:
                return 2, _MAINTENANCE_MSG
        if _dry_run_block(_WORKTREE_PRUNE_BLOCK, variants):
            if hit(_WORKTREE_PRUNE_ALLOW):
                record_hatch_use('CAST_WORKTREE_OK', 'worktree-prune')
            else:
                return 2, _WORKTREE_PRUNE_MSG
        if _dry_run_block(_PRUNE_BLOCK, variants):
            if hit(_PRUNE_ALLOW):
                record_hatch_use('CAST_PRUNE_OK', 'prune')
            else:
                return 2, _PRUNE_MSG
        if hit(_GC_CINJECT_BLOCK) or hit_env(_GC_ENV_KEY_BLOCK) or hit_env(_GC_ENV_PARAMETERS_BLOCK):
            if hit(_GC_HATCH_ALLOW):
                record_hatch_use('CAST_GC_OK', 'gc-config')
            else:
                return 2, _GC_CINJECT_MSG
        if hit(_GC_CONFIG_WRITE_BLOCK):
            if hit(_GC_HATCH_ALLOW):
                record_hatch_use('CAST_GC_OK', 'gc-config')
            else:
                return 2, _GC_CONFIG_WRITE_MSG
        # `config edit` can set an exec key as well as a gc key, so EITHER hatch
        # (CAST_GC_OK / CAST_GIT_CONFIG_OK) lets it through; one block, one record.
        if hit(_GC_CONFIG_EDIT_BLOCK):
            if hit(_GC_HATCH_ALLOW):
                record_hatch_use('CAST_GC_OK', 'gc-config')
            elif hit(_GIT_CONFIG_HATCH_ALLOW):
                record_hatch_use('CAST_GIT_CONFIG_OK', 'git-config-exec')
            else:
                return 2, _GC_CONFIG_EDIT_MSG
        # 2026-10-07 U6a-1: exec-capable config keys (after the gc checks, so a
        # gc-expiry hit keeps its own message and hatch).
        if (any(hit_env(p) for p in _GIT_CONFIG_EXEC_BLOCKS)
                or (mentions_git and _memoized(('execcfg', seg), lambda: _exec_config_cmd_blocks(seg)))):
            if hit(_GIT_CONFIG_HATCH_ALLOW):
                record_hatch_use('CAST_GIT_CONFIG_OK', 'git-config-exec')
            else:
                return 2, _GIT_CONFIG_EXEC_MSG
        if _dry_run_block(_GIT_RM_BLOCK, variants):
            if hit(_GIT_RM_ALLOW):
                record_hatch_use('CAST_GIT_RM_OK', 'git-rm')
            else:
                return 2, _GIT_RM_MSG
        if hit(_BRANCH_BLOCK):
            if hit(_BRANCH_ALLOW):
                record_hatch_use('CAST_BRANCH_OK', 'branch')
            else:
                return 2, _BRANCH_MSG
        if hit(_WORKTREE_BLOCK):
            if hit(_WORKTREE_ALLOW):
                record_hatch_use('CAST_WORKTREE_OK', 'worktree')
            else:
                return 2, _WORKTREE_MSG
        if (
            hit(_UPDATE_REF_BLOCK)
            or any(_update_ref_overwrites_existing(v) for v in variants)
        ):
            if hit(_UPDATE_REF_ALLOW):
                record_hatch_use('CAST_UPDATE_REF_OK', 'update-ref')
            else:
                return 2, _UPDATE_REF_MSG
        if hit(_FILTER_BRANCH_BLOCK):
            if hit(_FILTER_BRANCH_ALLOW):
                record_hatch_use('CAST_FILTER_BRANCH_OK', 'filter-branch')
            else:
                return 2, _FILTER_BRANCH_MSG
    return 0, None


# --------------------------------------------------------------------------
# Top-level evaluation (importable by the dispatcher)
# --------------------------------------------------------------------------
def _override_session_id(session_id) -> str:
    """Session id recorded on a CAST_POLICY_OVERRIDE audit event."""
    return (session_id if isinstance(session_id, str) and session_id
            else os.environ.get('CLAUDE_SESSION_ID', 'default'))


def _write_edit_internal_error(tool_name: str, file_path, session_id, exc: Exception):
    """Verdict for an UNEXPECTED exception in the Write/Edit policy gate: fail CLOSED.

    The block reason names the exception CLASS only — never `str(exc)` or the path, both of
    which can carry attacker-controlled text. `CAST_POLICY_OVERRIDE=1` allows (audited as
    `policy-internal-error`); the audit call is best-effort and cannot raise out of here, so
    the hatch always resolves. Nothing in this function can raise."""
    if os.environ.get('CAST_POLICY_OVERRIDE', '0') == '1':
        try:
            _audit_policy_override(
                'policy-internal-error',
                file_path if isinstance(file_path, str) else '<unresolved file_path>',
                _override_session_id(session_id))
        except Exception:
            pass
        return 0, ''
    return 2, (
        f'**[CAST-POLICY-BLOCK]** Internal error ({type(exc).__name__}) while checking this '
        f'{tool_name} against the policies; failing closed.\n'
        f'Escape hatch: Set CAST_POLICY_OVERRIDE=1 to bypass (document your reason).'
    )


def _evaluate_write_edit(tool_name: str, tool_input: dict, session_id):
    """Write/Edit policy gate. FAILS CLOSED: an unexpected exception blocks (see
    `_write_edit_internal_error`); the Bash branch of `evaluate` is the fail-OPEN one."""
    file_path = None
    try:
        # `file_path` wins when the key is present (as before); `path` is the fallback.
        file_path = tool_input.get('file_path', tool_input.get('path'))
        if not isinstance(file_path, str):
            # Absent / null / int / list / dict / bool: regex matching would raise
            # TypeError. A malformed Write/Edit target fails CLOSED (an empty STRING is
            # still "no path").
            kind = 'missing or null' if file_path is None else f'of type {type(file_path).__name__}'
            if os.environ.get('CAST_POLICY_OVERRIDE', '0') == '1':
                _audit_policy_override(
                    'policy-path-not-a-string', f'<{kind} file_path>',
                    _override_session_id(session_id))
                return 0, ''
            return 2, (
                f'**[CAST-POLICY-BLOCK]** The {tool_name} target path (`file_path`/`path`) is {kind}, '
                f'not a string, so it cannot be checked against the policies; failing closed.\n'
                f'Escape hatch: Set CAST_POLICY_OVERRIDE=1 to bypass (document your reason).'
            )
        if file_path:
            try:
                _ttl_sweep_agent_status()  # best-effort housekeeping; never decides the verdict
            except Exception:
                pass
            code, msg = _policy_evaluate(file_path, session_id)
            if code == 2:
                return 2, msg
            # code 0 may carry a warn-policy advisory: propagate it (never a block).
            return 0, msg or ''
        return 0, ''
    except Exception as exc:
        return _write_edit_internal_error(tool_name, file_path, session_id, exc)


def _evaluate_bash(tool_input: dict):
    """Bash git guard. FAILS OPEN on an internal error: a guard bug must not block every Bash
    call (the irreversible git ops are also guarded directly in `main()`)."""
    try:
        command = tool_input.get('command', '') or ''
        code, msg = _git_evaluate(command)
        return (code, msg or '') if code == 2 else (0, '')
    except Exception:
        return 0, ''


def evaluate(tool_name: str, tool_input: dict, session_id: str = ''):
    """Return (exit_code, message). 0 = allow, 2 = block (message is the block reason).

    For Write/Edit a code-0 result may carry a NON-EMPTY message: an advisory from a
    matching `warn`-severity policy. Callers must surface it as PreToolUse
    `additionalContext` and must never treat it as a block (only code 2 blocks).
    The Bash path always returns an empty message on code 0.

    `session_id` is the hook payload's session_id; only the Write/Edit policy gate uses it
    (requires_agent records must be bound to it — see `_agent_completed_this_session`).

    Failure policy differs by tool, deliberately:
      - Write/Edit fails CLOSED on an internal error -> (2, '**[CAST-POLICY-BLOCK]** ...');
        escape hatch CAST_POLICY_OVERRIDE=1 (audited as `policy-internal-error`).
      - Bash fails OPEN on an internal error -> (0, '').
      - Any other tool -> (0, '').
    Never raises."""
    if not isinstance(tool_input, dict):
        tool_input = {}
    if tool_name in ('Write', 'Edit'):
        return _evaluate_write_edit(tool_name, tool_input, session_id)
    if tool_name == 'Bash':
        return _evaluate_bash(tool_input)
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
        set_hook_context(data)
        try:
            gcode, gmsg = _git_evaluate(command)
        finally:
            clear_hook_context()
        if gcode == 2:
            if gmsg:
                print(gmsg, file=sys.stderr)
            return 2

    if os.environ.get('CLAUDE_SUBPROCESS', '0') == '1':
        return 0

    sid = data.get('session_id')
    code, msg = evaluate(tool_name, tool_input, sid if isinstance(sid, str) else '')
    if code == 2:
        if msg:
            print(msg, file=sys.stderr)
        return 2
    if code == 0 and isinstance(msg, str) and msg:
        # warn-policy advisory: ONE hookSpecificOutput object, never a block.
        print(json.dumps({'hookSpecificOutput': {
            'hookEventName': 'PreToolUse', 'additionalContext': msg}}))
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except SystemExit:
        raise
    except Exception:
        sys.exit(0)
