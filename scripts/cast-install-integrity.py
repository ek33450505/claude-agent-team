#!/usr/bin/env python3
"""cast-install-integrity.py - verify the install manifest written by install.sh.

install.sh writes ~/.claude/install-manifest.sha256 after deploying: a sha256 + path (relative to
~/.claude) for every deployed file under scripts/ and githooks/ plus config/policies.json, the file
mode of each, and the CAST repo + expected core.hooksPath of the install. Git hooks run UNSANDBOXED
and call only installed scripts, so a deleted/rewritten/replaced/un-chmod'ed file, a silently-missing
githooks dir (git then runs NO hooks), or a rewired git config is a silent loss of the PII gate.
This checker is the DETECTION half. Shared by the SessionStart health hook (--json) and
`cast doctor` (default line output).

Manifest v2 (shasum -c compatible entry lines; modes live in comment lines):
  # cast-install-manifest v2
  # repo: <abs path of the CAST checkout that ran install.sh>
  # hooks-path: <abs installed githooks dir>   ("-" = wiring skipped under a test/CI/temp HOME)
  # mode: <octal> <relpath>                     (one per entry)
  <sha256>  <relpath>

Checks (every failure is a problem; nothing is skipped silently):
  * githooks dir exists, is a real directory, holds the 4 hooks
  * every entry exists as a regular file (never a symlink/FIFO/device), sha256 AND mode match
    (git silently skips a hook that lost its exec bit)
  * scripts/, scripts/migrations/ and githooks/ hold NOTHING the manifest does not list: a planted
    scripts/json.py (or json/ package dir) shadows the stdlib for the un-isolated dispatcher, an
    added githooks/commit-msg runs. __pycache__ is tolerated only for .pyc named after a manifest .py
    (python itself writes them); .DS_Store is ignored (inert). A forged .pyc for a listed source is
    NOT detectable here (its header is attacker-computable) - documented residual.
  * the EFFECTIVE git config of the recorded repo (every scope, includes/includeIf/config.worktree
    resolved BY GIT, env scrubbed of GIT_*): core.hooksPath == manifest value; no hook.*.command/event
    (config-based hooks run regardless of hooksPath); worktree configs of other worktrees clean
  * every linked worktree's effective config (git --git-dir=<common>/worktrees/<n>, <= 64 of them)
    passes the same hooksPath / hook.* checks; an unreadable or over-cap worktree set is an alarm
  * scripts/, scripts/migrations/, config/ and githooks/ are real directories (a symlinked dir would
    redirect every path under it past the O_NOFOLLOW file checks); .DS_Store counts only as a regular file
  * every __pycache__ .pyc of a manifest script equals compile(its source): the marshalled code
    object is compared to a fresh compile (co_filename is not part of code equality). Only a cache
    python would LOAD is compared: one whose header (source mtime+size, or source hash) does not match
    the CURRENT source is STALE - python ignores and rewrites it, so it is not an alarm (an install
    leaves such caches behind, esp. under the Apple ~/Library/Caches prefix). A .pyc made by
    another installed interpreter (hooks run both /usr/bin/python3 and Homebrew python) is verified by
    spawning that interpreter on this very file (--pyc-verify); a .pyc NO interpreter can verify
    (unknown magic, interpreter gone) is an alarm - re-running install.sh purges __pycache__.
  * the process env carries no git override that redirects config, hooks or programs: GIT_CONFIG_*
    (COUNT/KEY_n/VALUE_n/PARAMETERS/GLOBAL/SYSTEM/NOSYSTEM), GIT_DIR, GIT_WORK_TREE, GIT_COMMON_DIR,
    GIT_EXEC_PATH, GIT_TEMPLATE_DIR, GIT_SSH, GIT_SSH_COMMAND, GIT_ASKPASS, GIT_PROXY_COMMAND,
    GIT_EXTERNAL_DIFF. Deliberately NOT listed: GIT_EDITOR/GIT_PAGER (tooling sets them legitimately and
    they run no hook), GIT_ALTERNATE_OBJECT_DIRECTORIES/GIT_OBJECT_DIRECTORY (object lookup, no exec).
A MISSING manifest (pre-manifest install) is an advisory, not an alarm.

Incremental mode (--incremental [--budget SECONDS], used by the SessionStart hook): full cache
verification of ~70 scripts x 2 interpreters costs ~1-1.7 s, too much for the hook budget. A snapshot
~/.claude/cast-state/pyc-verified.json (0600, written atomically via O_EXCL temp + rename, never through
a symlinked dir/file; same cast-state rules as the statusline reader) records every cache verified OK as
[size, mtime_ns, ctime_ns, inode, source sha256]. An incremental run skips (counts as verified) only a
cache whose whole tuple still matches (ctime/inode cannot be reset by an in-place rewrite + utime), and
verifies the rest until the budget is spent. WHERE IT STOPS: the run keeps its progress in the snapshot
and reports "pending" (a loud but non-alarm notice); the next run RESUMES from there, so a cold start
converges over a few sessions, never chronically. Every run verifies at least one new cache (progress).
Order: caches the snapshot does not vouch for are verified FIRST, rotated by --offset (default: the
current time in seconds), so neither a tight budget nor a disabled snapshot (symlinked cast-state)
can starve the same last-sorted cache run after run; --max-verify K caps new verifications per
interpreter per run (a deterministic stand-in for the time budget, used by tests). The JSON reports
caches.verified (compiled this run) vs caches.skipped (vouched by the snapshot).
Stale and hash-based caches: python IGNORES a timestamp-based cache whose header (source mtime/size)
does not match the current source and rewrites it - that is "stale" (kind pyc-stale, its own alarm:
install.sh purges every cache after deploying -- `--purge-caches --home H`, which removes exactly the
caches _collect_pycs computes, default __pycache__ and each interpreter's pycache_prefix, by unlink only,
never through a symlink -- so none is expected afterwards, and a planted stale-looking cache could be made
loadable by a later source-mtime flip). Only TIMESTAMP caches can be stale: a hash-based cache that fails
its hash (python loads it under check_hash_based_pycs=never, settable from a user-site hook) or has
reserved flag bits is never written by python and alarms as a mismatch.
A cache path that exists but is not a regular file (symlink - even dangling -, dir, FIFO) at a spot
python would load from alarms: python follows a symlink there.
Mismatches and unverifiable caches alarm every run until fixed (never snapshotted). `cast doctor` runs
the FULL mode (ignores the snapshot, then refreshes it). The snapshot is agent-writable unless the Bash
write guard protects ~/.claude/cast-state: a forged snapshot can mark any cache whose stat tuple it
records as verified (an agent can read the tuple), so the incremental path is only as strong as that
protection; doctor's full verify is not affected.

Residuals (documented, not detectable here):
  * check-to-use TOCTOU: a file can change between this check and the hook/import that uses it
  * the trusted-git rule accepts a USER-owned /opt/homebrew/bin by design (single-user Mac, admin
    group trusted): an agent running as the user can swap git itself
  * the manifest, this checker and the health hook are themselves rewritable by an agent with Bash;
    the Bash write guards must cover them
  * the env check sees only this process's env (hook/doctor), not an agent's Bash env

Output (default): one line per result, "<level>|<message>", level in ok / err / adv.
Output (--json):  {"state", "checked", "dropped", "problems": [{"kind", "path"?, "detail"}]}
Exit: 0 = ok or advisory, 1 = at least one problem. Writes nothing except the cast-state snapshot above.
"""
import hashlib
import json
import os
import re
import stat
import subprocess
import sys
import time

MANIFEST_NAME = "install-manifest.sha256"
SNAPSHOT_NAME = "pyc-verified.json"
HEADER = "# cast-install-manifest v2"
HOOKS = ("pre-commit", "post-commit", "post-merge", "pre-push")
REQUIRED_ENTRIES = tuple("githooks/" + h for h in HOOKS) + ("config/policies.json",)
_ENTRY_RE = re.compile(r"^([0-9a-f]{64})  (\S.*)$")
_MODE_RE = re.compile(r"^# mode: ([0-7]{3,4}) (\S.*)$")
_PYC_RE = re.compile(r"^(.+)\.cpython-[0-9]+(\.opt-[12])?\.pyc$")
_MAX_PROBLEMS = 20
# Fixed trusted git selection (same candidates + dir-trust rule as cast_git_safe in
# scripts/cast-hook-lib.sh). `config` is not in cast_git_safe's subcommand allowlist and sourcing a
# bash library from here would add a shell hop, so the selection logic is mirrored, not called.
_GIT_CANDIDATES = ("/opt/homebrew/bin/git", "/usr/local/bin/git", "/usr/bin/git")
_ENV_OVERRIDES = frozenset((
    "GIT_CONFIG_COUNT", "GIT_CONFIG_PARAMETERS", "GIT_CONFIG_GLOBAL", "GIT_CONFIG_SYSTEM",
    "GIT_CONFIG_NOSYSTEM", "GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR", "GIT_EXEC_PATH",
    "GIT_TEMPLATE_DIR", "GIT_SSH", "GIT_SSH_COMMAND", "GIT_ASKPASS", "GIT_PROXY_COMMAND",
    "GIT_EXTERNAL_DIFF",
    # The hook interpreters run `python3 script.py` NON-isolated, so they honour these (this checker and
    # its children run under -I and ignore them). PYTHONINSPECT is listed because with it set the
    # interpreter runs PYTHONSTARTUP after the script; PYTHONBREAKPOINT is not (needs a breakpoint() call).
    "PYTHONPATH", "PYTHONSTARTUP", "PYTHONPYCACHEPREFIX", "PYTHONHOME", "PYTHONUSERBASE",
    "PYTHONEXECUTABLE", "PYTHONINSPECT"))
# Interpreters that may have written __pycache__ (hooks run python3 from PATH: system + Homebrew).
_PY_CANDIDATES = ("/usr/bin/python3", "/opt/homebrew/bin/python3", "/usr/local/bin/python3")
_MAX_WORKTREES = 64


class _NotRegular(OSError):
    pass


def _hash_file(path):
    """-> (sha256 hex, permission bits) of a regular file. O_NOFOLLOW refuses a symlink; O_NONBLOCK
    keeps open() of a swapped-in FIFO from hanging; fstat refuses anything but a regular file."""
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0))
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode):
            raise _NotRegular("not a regular file")
        h = hashlib.sha256()
        with os.fdopen(fd, "rb", closefd=False) as fh:
            for chunk in iter(lambda: fh.read(1 << 20), b""):
                h.update(chunk)
        return h.hexdigest(), stat.S_IMODE(st.st_mode)
    finally:
        os.close(fd)


def _parse_manifest(text):
    """-> (entries {rel: sha}, modes {rel: int}, repo, hooks_path, errors)."""
    entries, modes, repo, hooks_path, errors = {}, {}, None, None, []
    lines = text.split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    if not lines or lines[0] != HEADER:
        errors.append("manifest header missing or unrecognised (re-run bash install.sh)")
    for ln in lines[1:]:
        m = _MODE_RE.match(ln)
        if m:
            modes[m.group(2)] = int(m.group(1), 8)
        elif ln.startswith("# repo: "):
            repo = ln[len("# repo: "):]
        elif ln.startswith("# hooks-path: "):
            hooks_path = ln[len("# hooks-path: "):]
        elif ln.startswith("#") or ln == "":
            continue
        else:
            m = _ENTRY_RE.match(ln)
            if not m:
                errors.append("manifest has a malformed line")
                continue
            rel = m.group(2)
            parts = rel.split("/")
            if rel.startswith("/") or ".." in parts or "" in parts:
                errors.append("manifest has an unsafe path")
                continue
            entries[rel] = m.group(1)
    if repo is None or hooks_path is None:
        errors.append("manifest lacks its repo/hooks-path lines")
    for req in REQUIRED_ENTRIES:
        if req not in entries:
            errors.append("manifest has no entry for " + req)
    for rel in entries:
        if rel not in modes:
            errors.append("manifest has no mode for " + rel)
            break
    return entries, modes, repo, hooks_path, errors


def _gitdir_of(repo):
    """The git dir governing <repo>, without running git in the repo. None if not a repo."""
    dot_git = os.path.join(repo, ".git")
    if os.path.isdir(dot_git):
        return dot_git
    if os.path.isfile(dot_git):  # worktree/submodule: "gitdir: <path>"
        with open(dot_git, "r", errors="replace") as fh:
            first = fh.readline().strip()
        if first.startswith("gitdir:"):
            gitdir = first.split(":", 1)[1].strip()
            return gitdir if os.path.isabs(gitdir) else os.path.join(repo, gitdir)
    return None


def _trusted_git():
    exes = _trusted_exes(_GIT_CANDIDATES)
    return exes[0] if exes else None


def _trusted_exes(cands):
    """Existing executables from a fixed candidate list whose directory is owned by root or the
    current user and not world-writable (the cast_git_safe rule).
    ACCEPTED LIMIT: this admits GROUP-writable dirs such as Homebrew's /opt/homebrew/bin (775, admin
    group) - excluding them would drop Homebrew python and git on every Homebrew machine - and an agent
    running as the same user can replace the binary regardless of the directory mode."""
    found = []
    for cand in cands:
        try:
            st = os.stat(cand)
            dst = os.stat(os.path.dirname(cand))
        except OSError:
            continue
        if not (stat.S_ISREG(st.st_mode) and os.access(cand, os.X_OK)):
            continue
        if dst.st_uid not in (0, os.getuid()) or dst.st_mode & 0o002:
            continue
        found.append(cand)
    return found


def _effective_config(gitdir, home):
    """Every effective config record [(scope, key, value)] of the repo at <gitdir>: system, global,
    local and per-worktree scopes with include/includeIf resolved BY GIT (explicit --git-dir gives it
    the repo context a bare `--file` read lacks). cwd=/, env scrubbed of every GIT_* variable."""
    git = _trusted_git()
    if git is None:
        raise OSError("no trusted git binary")
    env = {"PATH": "/usr/bin:/bin", "LC_ALL": "C", "HOME": home}
    if os.environ.get("XDG_CONFIG_HOME"):
        env["XDG_CONFIG_HOME"] = os.environ["XDG_CONFIG_HOME"]
    r = subprocess.run([git, "--git-dir", gitdir, "config", "--list", "-z", "--show-scope", "--includes"],
                       cwd="/", env=env, capture_output=True, timeout=2.0, stdin=subprocess.DEVNULL)
    if r.returncode != 0 or len(r.stdout) > (8 << 20):
        raise OSError("git config exit %d" % r.returncode)
    toks = r.stdout.decode("utf-8", "replace").split("\0")
    if toks and toks[-1] == "":
        toks.pop()
    if len(toks) % 2:
        raise OSError("unexpected git config output")
    recs = []
    for i in range(0, len(toks), 2):
        key, _, val = toks[i + 1].partition("\n")
        recs.append((toks[i], key.lower(), val))
    return recs


def _linked_worktrees(gitdir):
    """[(name, git dir)] of the linked worktrees of the repo (<common>/worktrees/*). Raises
    OverflowError past _MAX_WORKTREES. Each is later asked to git itself: includeIf gitdir: patterns
    and config.worktree can differ per worktree."""
    common = gitdir
    cfile = os.path.join(gitdir, "commondir")
    if os.path.isfile(cfile):
        with open(cfile, "r", errors="replace") as fh:
            common = os.path.normpath(os.path.join(gitdir, fh.readline().strip()))
    root = os.path.join(common, "worktrees")
    if os.path.islink(root) or not os.path.isdir(root):
        return []
    names = sorted(os.listdir(root))
    if len(names) > _MAX_WORKTREES:
        raise OverflowError("too many linked worktrees")
    return [(n, os.path.join(root, n)) for n in names]


def _scan_dir(claude, rel_dir, entries, bad):
    full = os.path.join(claude, rel_dir)
    if os.path.islink(full) or not os.path.isdir(full):
        return
    listed = {r.split("/")[-1] for r in entries if os.path.dirname(r) == rel_dir}
    try:
        names = sorted(os.listdir(full))
    except OSError:
        bad("hooks-dir", "~/.claude/%s is unreadable" % rel_dir)
        return
    for name in names:
        rel = rel_dir + "/" + name
        p = os.path.join(full, name)
        if name in listed:
            continue
        if name == ".DS_Store":
            try:
                if stat.S_ISREG(os.lstat(p).st_mode):
                    continue  # inert Finder metadata; a dir/symlink of that name is NOT
            except OSError:
                pass
        if rel_dir == "githooks" and name.startswith(".install-"):
            continue  # install.sh's transient staging file (not a git hook name)
        if rel == "scripts/migrations" and os.path.isdir(p) and not os.path.islink(p):
            continue  # scanned in its own right
        if name == "__pycache__" and rel_dir in ("scripts", "scripts/migrations") \
                and os.path.isdir(p) and not os.path.islink(p):
            _scan_pycache(p, rel, rel_dir, entries, bad)
            continue
        bad("unexpected", rel + " is not in the manifest", rel)


def _scan_pycache(path, rel, rel_dir, entries, bad):
    try:
        names = sorted(os.listdir(path))
    except OSError:
        bad("unexpected", rel + " is unreadable", rel)
        return
    for name in names:
        m = _PYC_RE.match(name)
        st = None
        try:
            st = os.lstat(os.path.join(path, name))
        except OSError:
            pass
        ok = bool(m) and st is not None and stat.S_ISREG(st.st_mode) \
            and (rel_dir + "/" + m.group(1) + ".py") in entries
        if not ok:
            bad("unexpected", rel + "/" + name + " is not a bytecode file of a manifest script", rel + "/" + name)


def _read_regular(path, limit):
    """Bytes of a regular file (O_NOFOLLOW|O_NONBLOCK + fstat). Raises OSError."""
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0))
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            raise _NotRegular("not a regular file")
        with os.fdopen(fd, "rb", closefd=False) as fh:
            return fh.read(limit)
    finally:
        os.close(fd)


def _open_state_dir(claude, create):
    """fd of ~/.claude/cast-state, opened ONCE with O_DIRECTORY|O_NOFOLLOW and then fstat'ed: a real
    directory, owned by us, mode 0700 (no group/other access). Every later access goes through this fd
    (dir_fd=), so swapping the path component after the check cannot redirect a read or write. None
    (caller treats the snapshot as unavailable) on any irregularity or where dir_fd is unsupported."""
    if not (os.open in os.supports_dir_fd and os.rename in os.supports_dir_fd
            and os.stat in os.supports_dir_fd):
        return None
    d = os.path.join(claude, "cast-state")
    try:
        if create and not os.path.lexists(d):
            os.mkdir(d, 0o700)
        fd = os.open(d, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0))
    except OSError:
        return None
    try:
        st = os.fstat(fd)
        if (stat.S_ISDIR(st.st_mode) and st.st_uid == os.getuid()
                and stat.S_IMODE(st.st_mode) & 0o077 == 0 and stat.S_IMODE(st.st_mode) & 0o700 == 0o700):
            return fd
    except OSError:
        pass
    os.close(fd)
    return None


def _snapshot_load(claude):
    """{pyc path: [size, mtime_ns, ctime_ns, ino, source sha256]} of caches verified OK earlier.
    Any irregularity (symlink, not a file, bad JSON/shape) -> {} : verify everything again."""
    dfd = _open_state_dir(claude, False)
    if dfd is None:
        return {}
    try:
        fd = os.open(SNAPSHOT_NAME, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0),
                     dir_fd=dfd)
        try:
            if not stat.S_ISREG(os.fstat(fd).st_mode):
                return {}
            with os.fdopen(fd, "rb", closefd=False) as fh:
                data = fh.read(8 << 20)
        finally:
            os.close(fd)
        raw = json.loads(data.decode("utf-8"))
        ents = raw["entries"]
        if raw["v"] != 1 or not isinstance(ents, dict):
            return {}
        return {k: v for k, v in ents.items() if isinstance(k, str) and isinstance(v, list) and len(v) == 5
                and all(isinstance(x, int) for x in v[:4]) and isinstance(v[4], str)}
    except (OSError, ValueError, KeyError, TypeError, UnicodeDecodeError):
        return {}
    finally:
        os.close(dfd)


def _snapshot_save(claude, entries):
    """Atomically replace the snapshot: temp file created O_EXCL|O_NOFOLLOW 0600 and renamed, both
    relative to the ONE verified directory fd. Never writes through a symlinked dir or file; failure is
    silent (the snapshot is an optimisation, never a verdict)."""
    dfd = _open_state_dir(claude, True)
    if dfd is None:
        return
    tmp = ".pyc-verified-%d-%s" % (os.getpid(), os.urandom(4).hex())
    try:
        try:
            if not stat.S_ISREG(os.stat(SNAPSHOT_NAME, dir_fd=dfd, follow_symlinks=False).st_mode):
                return
        except FileNotFoundError:
            pass
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o600, dir_fd=dfd)
        try:
            with os.fdopen(fd, "w") as fh:
                json.dump({"v": 1, "entries": entries}, fh)
            os.rename(tmp, SNAPSHOT_NAME, src_dir_fd=dfd, dst_dir_fd=dfd)
        except OSError:
            try:
                os.unlink(tmp, dir_fd=dfd)
            except OSError:
                pass
    except OSError:
        pass
    finally:
        os.close(dfd)


def _collect_pycs(claude, entries, prefix="", purge=False):
    """[(pyc path, source rel, optimize level)] a python could LOAD for a manifest script: every
    well-named .pyc in the default __pycache__ dirs, plus - when the interpreter runs with a
    sys.pycache_prefix (macOS system python keeps its caches under ~/Library/Caches) - the cache
    path that interpreter computes for each source."""
    import importlib.util
    out = []
    for rel_dir in ("scripts", "scripts/migrations"):
        pc = os.path.join(claude, rel_dir, "__pycache__")
        if os.path.islink(pc) or not os.path.isdir(pc):
            continue
        try:
            names = sorted(os.listdir(pc))
        except OSError:
            continue
        for name in names:
            m = _PYC_RE.match(name)
            if not m or (rel_dir + "/" + m.group(1) + ".py") not in entries:
                continue
            path = os.path.join(pc, name)
            try:
                # verification only judges regular files (_scan_pycache alarms on the rest); a purge
                # must also remove a symlink/FIFO planted under a cache name
                if not purge and not stat.S_ISREG(os.lstat(path).st_mode):
                    continue
                os.lstat(path)
            except OSError:
                continue
            out.append((path, rel_dir + "/" + m.group(1) + ".py", int(m.group(2)[-1]) if m.group(2) else -1))
    if prefix:
        old = sys.pycache_prefix
        sys.pycache_prefix = prefix
        try:
            for rel in sorted(entries):
                if rel.endswith(".py") and os.path.dirname(rel) in ("scripts", "scripts/migrations"):
                    path = importlib.util.cache_from_source(os.path.join(claude, rel))
                    # lexists, NOT isreg: python FOLLOWS a symlink (and would trip on a dir/FIFO) at
                    # this path, so anything that exists but is not a regular file must reach
                    # _verify_one, which refuses it (-> alarm). A dangling symlink counts too.
                    if os.path.lexists(path):
                        out.append((path, rel, -1))
        finally:
            sys.pycache_prefix = old
    return out


def _pyc_header_current(data, src, src_mtime):
    """True when CPython's SourceLoader would ACCEPT this cache for <src> (so it would execute it); False
    when python would reject it and silently recompile (importlib._bootstrap_external._classify_pyc +
    _validate_*_pyc). Same rules: reserved flag bits -> rejected; hash-based + check_source -> the
    8-byte source_hash must match; hash-based unchecked -> accepted unseen (so still verified); else
    the source mtime (low 32 bits) and size (low 32 bits) must match."""
    import importlib.util
    flags = int.from_bytes(data[4:8], "little")
    if flags & ~0b11:
        return False
    if flags & 1:
        return (not flags & 2) or data[8:16] == importlib.util.source_hash(src)
    return (int.from_bytes(data[8:12], "little") == (src_mtime & 0xFFFFFFFF)
            and int.from_bytes(data[12:16], "little") == (len(src) & 0xFFFFFFFF))


def _pyc_is_timestamp_based(data):
    """True for a normal timestamp-based cache (the only kind python itself writes); False for a
    hash-based cache or one with reserved flag bits - nothing legitimate produces those."""
    return int.from_bytes(data[4:8], "little") == 0


def _verify_one(claude, pyc_path, src_rel, optimize, snap=None, hold=False):
    """-> (verdict, snapshot entry or None, served-from-snapshot). verdict: True = cache equals compile(source); False = does
    not (or unreadable); None = other-magic cache this interpreter cannot judge; "stale" = a
    TIMESTAMP cache whose header does not match the CURRENT source, so python ignores it and rewrites it
    (reported by the caller as its own alarm: install purges every cache, so none is expected after it); "pending" = out of
    time or compile quota (<hold>: the caller already did new work this run, so every run makes
    progress). With <snap>, a cache whose stat tuple (size, mtime_ns, ctime_ns, inode) and source
    sha256 equal a recorded OK verdict is True without compiling (ctime/inode cannot be reset by an
    in-place rewrite + utime)."""
    import hashlib
    import importlib.util
    import marshal
    try:
        st = os.lstat(pyc_path)
        data = _read_regular(pyc_path, 16 << 20)
        if len(data) < 16:
            return False, None, False
        if data[:4] != importlib.util.MAGIC_NUMBER:
            if snap is None or pyc_path not in snap:
                return None, None, False
        src = _read_regular(os.path.join(claude, src_rel), 16 << 20)
        sha = hashlib.sha256(src).hexdigest()
        key = [st.st_size, st.st_mtime_ns, st.st_ctime_ns, st.st_ino, sha]
        if snap is not None and snap.get(pyc_path) == key and len(data) == st.st_size:
            return True, key, True
        if data[:4] != importlib.util.MAGIC_NUMBER:
            return None, None, False
        if not _pyc_header_current(data, src, int(os.lstat(os.path.join(claude, src_rel)).st_mtime)):
            # Only a TIMESTAMP cache can be stale (an old source's leftover). A hash-based cache that
            # fails its hash, or one with reserved flag bits, is never written by python: python may still
            # load it (check_hash_based_pycs can be set to "never" from a user-site hook) -> ALARM.
            if _pyc_is_timestamp_based(data):
                return "stale", None, False
            return False, None, False
        if hold:
            return "pending", None, False
        want = compile(src, os.path.join(claude, src_rel), "exec", dont_inherit=True, optimize=optimize)
        if marshal.loads(data[16:]) == want:  # code equality ignores co_filename
            return True, key, False
        return False, None, False
    except Exception:
        return False, None, False


def _probe_prefix(exe, claude, seconds):
    """sys.pycache_prefix of interpreter <exe> as hooks see it ('' when none). `-S`: skips `site`, so a
    user-site usercustomize cannot print into or steer the probe; cwd=/ and no PYTHON* env keep it inert;
    HOME is the checked home (the system python's prefix follows $HOME)."""
    env = {"PATH": "/usr/bin:/bin", "LC_ALL": "C", "HOME": os.path.dirname(claude)}
    pr = subprocess.run([exe, "-S", "-c", "import sys; print(sys.pycache_prefix or '')"], cwd="/", env=env,
                        capture_output=True, timeout=min(3.0, max(0.5, seconds)), stdin=subprocess.DEVNULL)
    prefix = pr.stdout.decode("utf-8", "replace").strip() if pr.returncode == 0 else ""
    if not prefix.startswith("/") or "\n" in prefix or len(prefix) > 1000:
        return ""
    return prefix


def _run_verifier(exe, claude, incremental, seconds, max_verify, offset):
    """Ask interpreter <exe> to verify every cache it can read. -> {"bad", "verified", "pending"}.
    Two spawns. (1) probe sys.pycache_prefix with `-S`: the system python sets it only outside -I/-E,
    and hooks run `python3 script.py` non-isolated, but `-S` skips `site` so a user-site
    usercustomize/sitecustomize can neither print into nor steer the probe (an Apple-interpreter
    prefix we then derive ourselves would be the alternative; -S needs no per-interpreter knowledge).
    cwd=/ and no PYTHON* env keep it inert. (2) the isolated verifier (-I) on THIS file."""
    env = {"PATH": "/usr/bin:/bin", "LC_ALL": "C", "HOME": os.path.dirname(claude)}  # prefix follows $HOME
    t0 = time.monotonic()
    prefix = _probe_prefix(exe, claude, seconds)
    left = max(0.3, seconds - (time.monotonic() - t0))
    r = subprocess.run([exe, "-I", os.path.abspath(__file__), "--pyc-verify", claude, prefix,
                        "incr" if incremental else "full", "%.3f" % max(0.0, left - 0.2),
                        str(max_verify if max_verify is not None else -1), str(offset)],
                       cwd="/", env=env, capture_output=True, timeout=left, stdin=subprocess.DEVNULL)
    if r.returncode != 0:
        raise OSError("verifier exit %d" % r.returncode)
    return json.loads(r.stdout[:4 << 20].decode("utf-8", "replace"))


def _own_exe():
    """The interpreter to run verifiers with. NEVER sys.executable when a trusted candidate exists:
    PYTHONEXECUTABLE overrides sys.executable (even under -I, macOS) and the verifier EXECUTES it."""
    exes = _trusted_exes(_PY_CANDIDATES)
    return exes[0] if exes else sys.executable


def _verify_pycs(claude, entries, bad, incremental, deadline, max_verify=None, offset=0, counts=None):
    """Verify bytecode caches of manifest scripts against their source, with EVERY installed
    interpreter that may run them (own + fixed trusted candidates): a cache is only ever read by the
    interpreter whose magic it carries. Returns the number of caches still PENDING (incremental run
    out of budget; they continue next run, the snapshot keeps the progress). A default-dir cache that
    no interpreter verified, with every interpreter complete, is an alarm."""
    pool = {path: src for path, src, _o in _collect_pycs(claude, entries)}
    snap = _snapshot_load(claude) if incremental else {}
    verified, mismatched, stale, stale_srcs, seen = {}, set(), set(), set(), set()
    pending, incomplete = 0, False
    for exe in [_own_exe()] + _trusted_exes(_PY_CANDIDATES):
        real = os.path.realpath(exe)
        if real in seen:
            continue
        seen.add(real)
        left = (deadline - time.monotonic()) if deadline is not None else 30.0
        if left < 0.35:
            incomplete = True
            continue
        try:
            res = _run_verifier(exe, claude, incremental, left, max_verify, offset)
            if counts is not None:
                counts["verified"] += int(res.get("compiled", 0))
                counts["skipped"] += int(res.get("skipped", 0))
            mismatched.update(x for x in res["bad"] if isinstance(x, str))
            stale.update(x for x in res.get("stale", []) if isinstance(x, str))
            stale_srcs.update(x for x in res.get("stale_src", []) if isinstance(x, str))
            for ent in res["verified"]:
                if isinstance(ent, list) and len(ent) == 6 and isinstance(ent[0], str):
                    verified[ent[0]] = ent[1:]
            pending += int(res["pending"])
        except subprocess.TimeoutExpired:
            incomplete = True
        except (OSError, subprocess.SubprocessError, ValueError, KeyError, TypeError):
            continue  # this interpreter could not judge; its caches stay unverified (fail closed)
    for src_rel in sorted(mismatched):
        bad("pyc", src_rel + " compiled cache does not match its source", src_rel)
    # STALE timestamp caches: python ignores them, but install.sh purges every cache after deploying, so
    # none is expected afterwards - a planted stale-looking cache can be made loadable by a later source
    # mtime flip. Its own message (distinct from a forged cache); reported once per source, never on top
    # of a mismatch for the same source.
    for src_rel in sorted(stale_srcs - mismatched):
        bad("pyc-stale", "bytecode cache for " + src_rel + " is stale (python would not load it) - not expected "
            "after install; re-run bash install.sh", src_rel)
    # a cache already reported as a MISMATCH is not also "unverifiable" (one forged cache = one problem)
    # nor is a STALE one (header != current source: python ignores and rewrites it, so it runs nothing)
    remaining = {p for p, src in pool.items() if p not in verified and p not in stale and src not in mismatched}
    if incomplete or pending:
        pending = max(pending, len(remaining))
    elif remaining:
        bad("pyc-unverified", "%d bytecode cache file(s) cannot be verified by any installed interpreter "
            "(unknown magic or interpreter gone) - re-run bash install.sh to purge __pycache__" % len(remaining))
    final = verified
    if incomplete or pending:  # keep earlier progress of interpreters we ran out of time for
        final = {k: v for k, v in dict(snap, **verified).items() if os.path.lexists(k)}
    if final != snap:
        _snapshot_save(claude, final)
    return pending


def _pyc_verify_child(claude, prefix, mode, seconds, max_verify, offset):
    """--pyc-verify <claude dir> <pycache prefix or ''> <incr|full> <seconds> <max compiles or -1>
    <offset>: verify the caches THIS interpreter can read; print JSON. Snapshot entries are
    [pyc, size, mtime_ns, ctime_ns, inode, sha]. Order (incremental): caches the snapshot does not
    vouch for come FIRST, rotated by <offset>, then the already-vouched ones - so a tight budget or a
    disabled snapshot can neither starve a changed/new cache nor keep missing the same last-sorted one."""
    with open(os.path.join(claude, MANIFEST_NAME), "r", encoding="utf-8") as fh:
        entries = _parse_manifest(fh.read(4 << 20))[0]
    incr = mode == "incr"
    snap = _snapshot_load(claude) if incr else None
    deadline = time.monotonic() + float(seconds) if incr else None
    quota = int(max_verify) if incr and int(max_verify) >= 0 else None
    items = _collect_pycs(claude, entries, prefix)
    if incr and items:
        rot = int(offset) % len(items)
        items = items[rot:] + items[:rot]

        def vouched(it):
            try:
                st = os.lstat(it[0])
            except OSError:
                return False
            ent = snap.get(it[0])
            return bool(ent) and ent[:4] == [st.st_size, st.st_mtime_ns, st.st_ctime_ns, st.st_ino]
        items = [i for i in items if not vouched(i)] + [i for i in items if vouched(i)]  # stable
    out = {"bad": [], "verified": [], "stale": [], "stale_src": [], "pending": 0, "compiled": 0, "skipped": 0}
    new_work = 0
    for path, src_rel, opt in items:
        hold = incr and new_work > 0 and (time.monotonic() > deadline or (quota is not None and new_work >= quota))
        verdict, key, cached = _verify_one(claude, path, src_rel, opt, snap, hold)
        if verdict is True:
            out["verified"].append([path] + key)
            if cached:
                out["skipped"] += 1
            else:
                out["compiled"] += 1
                new_work += 1
        elif verdict is False:
            out["bad"].append(src_rel)
            new_work += 1
        elif verdict == "pending":
            out["pending"] += 1
        elif verdict == "stale":
            out["stale"].append(path)
            out["stale_src"].append(src_rel)
    sys.stdout.write(json.dumps(out))


def _unlink_under(root, parts, follow_root):
    """Unlink <root>/<parts...> without ever following a symlink BELOW <root>: every component is opened
    with O_NOFOLLOW|O_DIRECTORY relative to its parent fd and the final entry is os.unlink'ed (so a
    symlink is removed itself, its target untouched; a directory is refused, never rmtree'd)."""
    fd = os.open(root, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | (0 if follow_root else getattr(os, "O_NOFOLLOW", 0)))
    try:
        for part in parts[:-1]:
            nfd = os.open(part, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0), dir_fd=fd)
            os.close(fd)
            fd = nfd
        os.unlink(parts[-1], dir_fd=fd)
    finally:
        os.close(fd)


def _purge_caches(home):
    """Remove every bytecode cache python could load for the DEPLOYED scripts (scripts/*.py and
    scripts/migrations/*.py): the default __pycache__ AND each trusted interpreter's pycache_prefix
    location. A cache's file name carries the interpreter's tag (a.cpython-39.pyc), so each interpreter
    computes its own paths in a child (--pyc-purge) via the same _collect_pycs that verification uses -
    the two cannot drift. Run by install.sh right after deploying, so no cache of the previous source
    survives (a leftover stale cache is otherwise harmless to python but can be made loadable by a later
    source-mtime flip). -> (removed, failed)."""
    claude = os.path.join(home, ".claude")
    removed = failed = 0
    seen = set()
    for exe in [_own_exe()] + _trusted_exes(_PY_CANDIDATES):
        real = os.path.realpath(exe)
        if real in seen:
            continue
        seen.add(real)
        try:
            prefix = _probe_prefix(exe, claude, 3.0)
            r = subprocess.run([exe, "-I", os.path.abspath(__file__), "--pyc-purge", claude, prefix], cwd="/",
                               env={"PATH": "/usr/bin:/bin", "LC_ALL": "C"}, capture_output=True, timeout=10.0,
                               stdin=subprocess.DEVNULL)
            res = json.loads(r.stdout[:4096].decode("utf-8", "replace"))
            removed += int(res["removed"])
            failed += int(res["failed"])
        except (OSError, subprocess.SubprocessError, ValueError, KeyError, TypeError):
            failed += 1
    return removed, failed


def _purge_child(claude, prefix):
    """--pyc-purge <claude dir> <pycache prefix or ''>: unlink, for THIS interpreter, every cache of the
    deployed scripts. Entries are removed with unlink only, below a fixed root, never through a symlink;
    a path outside the computed cache locations is never touched; a directory is refused (no rmtree)."""
    if not (os.open in os.supports_dir_fd and os.unlink in os.supports_dir_fd):
        raise OSError("dir_fd unsupported")
    entries = {}
    for rel_dir in ("scripts", "scripts/migrations"):
        d = os.path.join(claude, rel_dir)
        if os.path.islink(d) or not os.path.isdir(d):
            continue
        for name in sorted(os.listdir(d)):
            if name.endswith(".py") and os.path.isfile(os.path.join(d, name)):
                entries[rel_dir + "/" + name] = ""
    roots = (os.path.join(claude, "scripts", "__pycache__"), os.path.join(claude, "scripts", "migrations", "__pycache__"))
    removed = failed = 0
    for path, _src, _opt in _collect_pycs(claude, entries, prefix, purge=True):
        root, follow = None, False
        for r in roots:
            if path.startswith(r + os.sep):
                root = r
        if root is None and prefix and path.startswith(prefix.rstrip("/") + os.sep):
            root, follow = prefix.rstrip("/"), True
        if root is None:
            continue  # never delete outside the computed cache locations
        parts = [x for x in path[len(root) + 1:].split(os.sep) if x]
        if not parts or ".." in parts:
            continue
        try:
            _unlink_under(root, parts, follow)
            removed += 1
        except FileNotFoundError:
            pass
        except OSError:
            failed += 1
    sys.stdout.write(json.dumps({"removed": removed, "failed": failed}))


def check(home, incremental=False, budget=None, max_verify=None, offset=0):
    """-> dict(state, problems[list of (kind, detail, path)], checked)."""
    t_start = time.monotonic()
    claude = os.path.join(home, ".claude")
    mpath = os.path.join(claude, MANIFEST_NAME)
    problems = []

    def bad(kind, detail, path=None):
        problems.append((kind, detail, path))

    if not os.path.lexists(mpath):
        return {"state": "advisory", "checked": 0, "problems": [
            ("manifest-missing", "no integrity manifest (" + MANIFEST_NAME + ") - "
             "run bash install.sh to create it", None)]}
    try:
        if os.path.islink(mpath) or not os.path.isfile(mpath):
            raise OSError("not a regular file")
        with open(mpath, "r", encoding="utf-8", errors="strict") as fh:
            text = fh.read(4 << 20)
    except (OSError, UnicodeDecodeError) as exc:
        return {"state": "alarm", "checked": 0, "problems": [
            ("manifest-unreadable", MANIFEST_NAME + " is unreadable (" + type(exc).__name__ + ")", None)]}

    entries, modes, repo, hooks_path, errors = _parse_manifest(text)
    for e in errors:
        bad("manifest-invalid", e)

    # (a) githooks dir
    hooks_dir = os.path.join(claude, "githooks")
    if os.path.islink(hooks_dir) or not os.path.isdir(hooks_dir):
        bad("hooks-dir", "~/.claude/githooks is missing or not a real directory - git runs NO hooks")
    else:
        for h in HOOKS:
            if not os.path.lexists(os.path.join(hooks_dir, h)) and ("githooks/" + h) not in entries:
                bad("missing", "githooks/" + h + " is missing", "githooks/" + h)

    # (b) every manifest entry: regular file, sha256 + mode match
    checked = 0
    for rel in sorted(entries):
        path = os.path.join(claude, rel)
        checked += 1
        try:
            actual, mode = _hash_file(path)
        except FileNotFoundError:
            bad("missing", rel + " is missing", rel)
            continue
        except OSError:
            bad("changed", rel + " is no longer a readable regular file", rel)
            continue
        if actual != entries[rel]:
            bad("changed", rel + " changed since install", rel)
        elif rel in modes and mode != modes[rel]:
            bad("mode", "%s mode is %o, expected %o (git skips a hook without its exec bit)"
                % (rel, mode, modes[rel]), rel)

    # (b2) managed dirs are real directories; nothing unlisted where code or hooks load from
    for d in ("scripts", "scripts/migrations", "config"):
        full = os.path.join(claude, d)
        if os.path.lexists(full) and (os.path.islink(full) or not os.path.isdir(full)):
            bad("dir-type", "~/.claude/%s is a symlink or not a directory" % d, d)
    for d in ("githooks", "scripts", "scripts/migrations"):
        _scan_dir(claude, d, entries, bad)

    # (b3) bytecode caches of manifest scripts equal their source
    pending, counts = 0, {"verified": 0, "skipped": 0}
    if not os.path.islink(os.path.join(claude, "scripts")):
        pending = _verify_pycs(claude, entries, bad, incremental,
                               (t_start + budget) if budget is not None else None, max_verify, offset, counts)

    # (c) effective git config of the recorded repo (main + every linked worktree)
    if hooks_path is not None and hooks_path != "-" and repo:
        def analyze(recs, label):
            hp = [(sc, v) for sc, k, v in recs if k == "core.hookspath"]
            actual_hp = hp[-1][1] if hp else None
            if actual_hp is not None and actual_hp.startswith("~/"):
                actual_hp = os.path.join(home, actual_hp[2:])
            where = " (repo " + repo + label + ")"
            if actual_hp is None:
                bad("hooks-path", "core.hooksPath is unset, expected " + hooks_path + where)
            elif os.path.normpath(actual_hp) != os.path.normpath(hooks_path):
                bad("hooks-path", "core.hooksPath is " + actual_hp + " (" + hp[-1][0] + " scope), expected "
                    + hooks_path + where)
            for scope, key, _v in recs:
                if key.startswith("hook.") and (key.endswith(".command") or key.endswith(".event")):
                    bad("hook-config", key + " is set in " + scope + " git config - config-based hooks "
                        "run regardless of core.hooksPath" + where)

        try:
            gitdir = _gitdir_of(repo)
            if gitdir is None or not os.path.isdir(gitdir):
                bad("hooks-path", "recorded CAST repo " + repo + " has no readable git dir - "
                    "core.hooksPath cannot be verified")
            else:
                analyze(_effective_config(gitdir, home), "")
                for name, wt_dir in _linked_worktrees(gitdir):
                    try:
                        if not os.path.isfile(os.path.join(wt_dir, "HEAD")):
                            raise OSError("not a git dir")
                        analyze(_effective_config(wt_dir, home), ", linked worktree " + name)
                    except (OSError, subprocess.SubprocessError):
                        bad("hooks-path", "could not read the effective git config of linked worktree "
                            + name + " (repo " + repo + ")")
        except OverflowError:
            bad("hooks-path", "more than %d linked worktrees in %s - cannot verify each worktree's git config"
                % (_MAX_WORKTREES, repo))
        except (OSError, subprocess.SubprocessError) as exc:
            bad("hooks-path", "could not read the effective git config of " + repo + " (" + type(exc).__name__ + ")")
        # (d) env overrides redirect config, hooks or programs for every git this process runs
        set_vars = sorted(k for k in os.environ if k in _ENV_OVERRIDES or re.match(r"^GIT_CONFIG_(KEY|VALUE)_[0-9]+$", k))
        if set_vars:
            bad("env", "environment sets " + ", ".join(set_vars) + " (redirects git config/hooks/programs for every git run)")

    return {"state": "alarm" if problems else "ok", "checked": checked, "problems": problems, "pending": pending, "caches": counts}


def _clean(text):
    """Printable ASCII only: a filename or .git/config value is attacker-influenced and this text
    reaches a terminal (doctor)."""
    return re.sub(r"[^ -~]", "?", str(text))[:400]


def main(argv):
    if len(argv) == 7 and argv[0] == "--pyc-verify":
        try:
            _pyc_verify_child(argv[1], argv[2], argv[3], argv[4], argv[5], argv[6])
            return 0
        except Exception:
            return 3
    if len(argv) == 3 and argv[0] == "--pyc-purge":
        try:
            _purge_child(argv[1], argv[2])
            return 0
        except Exception:
            return 3
    if len(argv) == 3 and argv[0] == "--purge-caches" and argv[1] == "--home":
        try:
            removed, failed = _purge_caches(argv[2])
        except Exception as exc:
            sys.stderr.write("purge failed (%s)\n" % type(exc).__name__)
            return 1
        sys.stdout.write("purged %d bytecode cache file(s)%s\n" % (removed, ", %d could not be removed" % failed if failed else ""))
        return 1 if failed else 0
    as_json, home, incremental, budget = False, os.path.expanduser("~"), False, None
    max_verify, offset = None, int(time.time())  # rotating start offset when nothing persists
    i = 0
    while i < len(argv):
        if argv[i] == "--json":
            as_json = True
        elif argv[i] == "--incremental":
            incremental = True
        elif argv[i] in ("--max-verify", "--offset") and i + 1 < len(argv):
            flag = argv[i]
            i += 1
            try:
                val = int(argv[i])
            except ValueError:
                sys.stderr.write("bad %s\n" % flag)
                return 2
            if flag == "--offset":
                offset = val
            else:
                max_verify = max(1, val)  # >= 1 so every run makes progress
        elif argv[i] == "--budget" and i + 1 < len(argv):
            i += 1
            try:
                budget = max(0.0, float(argv[i]))
            except ValueError:
                sys.stderr.write("bad --budget\n")
                return 2
        elif argv[i] == "--home" and i + 1 < len(argv):
            i += 1
            home = argv[i]
        else:
            sys.stderr.write("usage: cast-install-integrity.py [--json] [--home DIR]\n")
            return 2
        i += 1
    try:
        res = check(home, incremental, budget, max_verify, offset)
    except Exception as exc:  # never a traceback: an unexpected failure is itself an alarm
        res = {"state": "alarm", "checked": 0,
               "problems": [("checker-error", "integrity check failed (" + type(exc).__name__ + ")", None)]}
    dropped = max(0, len(res["problems"]) - _MAX_PROBLEMS)
    probs = [(k, _clean(d), p) for k, d, p in res["problems"][:_MAX_PROBLEMS]]
    if as_json:
        out = {"state": res["state"], "checked": res["checked"], "dropped": dropped, "problems": [],
               "pending": int(res.get("pending", 0)),
               "caches": res.get("caches", {"verified": 0, "skipped": 0})}
        for k, d, p in probs:
            item = {"kind": k, "detail": d}
            if p is not None:
                item["path"] = _clean(p)
            out["problems"].append(item)
        sys.stdout.write(json.dumps(out) + "\n")
    else:
        if res["state"] == "ok":
            sys.stdout.write("ok|install manifest verified (%d files, modes, githooks, git config)\n" % res["checked"])
        if res.get("pending"):
            sys.stdout.write("adv|bytecode cache verification incomplete (%d pending) - continues next session\n"
                             % res["pending"])
        for k, d, p in probs:
            sys.stdout.write(("adv|" if res["state"] == "advisory" else "err|") + d + "\n")
        if dropped:
            sys.stdout.write("err|... and %d more problem(s)\n" % dropped)
    return 1 if res["state"] == "alarm" else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
