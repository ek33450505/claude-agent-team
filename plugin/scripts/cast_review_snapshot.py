#!/usr/bin/env python3
"""cast_review_snapshot.py -- content-bound review gate: snapshot + verdict library.

Design: plans/design/2026-10-15-content-bound-review-gate.md (U1a: library + schema only;
nothing calls this module yet -- hook wiring is U1b, the commit gate is U2).

A reviewer run is bracketed by two snapshots of the repo's dirty set (path -> git blob sha,
or "DELETED"). Only paths whose value is identical at start and stop (stable_files) were
present unchanged for the whole review. record() persists one review_snapshots row
(scope='files') plus one review_snapshot_files row per stable path.

Every function here is fail-closed and never raises: take_snapshot/load_start return None,
save_start/record/record_degraded_block return False, parse_verdict returns None, decide
returns "BLOCKED".

Blob semantics (U2 MUST honour this): cast_git_safe forces `hash-object --no-filters`, so no
clean-filter / textconv code ever runs and every blob here is the RAW working-tree hash. It is
NOT necessarily the blob `git add` would stage (autocrlf / clean filters would differ). U2
therefore compares the raw worktree hash of each staged path AND requires the path to have no
unstaged changes (index blob == worktree blob) before it counts as covered.

Verdict parsing is deliberately NOT Markdown-aware (see the "verdict" section below).

Sticky BLOCK: a BLOCKED review must survive a snapshot or record failure. Callers that fail to
take a snapshot, or whose record(decision="BLOCKED", ...) returns False, MUST fall back to
record_degraded_block(), which writes a BLOCKED row with scope='repo' and no files. U2 treats a
scope='repo' BLOCKED row as blocking every path in that repo_root. resolve_repo_root() gives
the repo_root even when the full snapshot failed.

Bounds: a dirty set over MAX_PATHS paths / MAX_BYTES bytes makes take_snapshot return None.
`status --untracked-files=all` output itself is uncapped (cast_git_safe is deliberately not
changed): a huge dirty set only fails THIS snapshot closed -- the blobs stay unreviewed -- and
the degraded-BLOCK path above keeps a BLOCK verdict alive through it. A path containing a
newline cannot be passed to cast_git_safe's hash-object; that one path is omitted (it stays
unreviewed) and the rest of the snapshot is kept. A symlink blob is computed in Python with the
repo's object format (`rev-parse --show-object-format`); if that is unavailable, sha1 is
assumed, so a sha256 repo on a git without the flag simply never matches (fail closed).

Trust boundary: the start-snapshot file and cast.db are same-user writable. Protection rests on
the `Edit(~/.claude/cast-state/**)` deny plus the 0700 state dir, exactly as for cast.db -- this
module does not defend against a process running as the same user that bypasses those.

Git is reached ONLY through scripts/cast_git_safe.py (loaded by explicit realpath, same as
cast_subagent_stop._git_safe_run): repo-local config can otherwise make git execute programs.

Python 3.9 compatible, stdlib only.
"""
import hashlib
import importlib.util
import json
import os
import re
import sqlite3
import stat
import time
import unicodedata
import urllib.parse
from typing import Dict, List, Optional

MAX_PATHS = 2000
MAX_BYTES = 50 * 1024 * 1024
MAX_STATE_BYTES = 10 * 1024 * 1024
MAX_VERDICT_TEXT = 1024 * 1024
STALE_TMP_SECONDS = 3600
_HASH_BATCH = 200
_GIT_TIMEOUT = 30.0
DELETED = "DELETED"

_GIT_SAFE_MOD = None  # None=unattempted, False=load failed, module=loaded


def _git(repo_dir: str, args: List[str], timeout: float = _GIT_TIMEOUT):
    """cast_git_safe.run(...) or None when the primitive cannot load / errors."""
    global _GIT_SAFE_MOD
    if _GIT_SAFE_MOD is None:
        try:
            spec = importlib.util.spec_from_file_location(
                "cast_git_safe",
                os.path.join(os.path.dirname(os.path.realpath(__file__)), "cast_git_safe.py"),
            )
            if spec and spec.loader:
                mod = importlib.util.module_from_spec(spec)
                spec.loader.exec_module(mod)
                _GIT_SAFE_MOD = mod
            else:
                _GIT_SAFE_MOD = False
        except Exception:
            _GIT_SAFE_MOD = False
    if _GIT_SAFE_MOD is False:
        return None
    try:
        return _GIT_SAFE_MOD.run(repo_dir, args, timeout=timeout)
    except Exception:
        return None


def _object_format(root: str) -> str:
    res = _git(root, ["rev-parse", "--show-object-format"])
    if res is not None and res.returncode == 0 and res.stdout.strip() == "sha256":
        return "sha256"
    return "sha1"


def _symlink_blob(full: str, fmt: str = "sha1") -> str:
    """Blob id git would store for a symlink: hash of 'blob <len>\\0' + link text."""
    target = os.fsencode(os.readlink(full))
    return getattr(hashlib, fmt)(b"blob %d\0" % len(target) + target).hexdigest()


def _parse_status(out: str) -> Optional[Dict[str, bool]]:
    """Parse `status --porcelain=v1 -z` -> {path: is_rename_source}. None on malformed."""
    parts = out.split("\0")
    if parts and parts[-1] == "":
        parts.pop()
    paths = {}  # type: Dict[str, bool]
    i = 0
    while i < len(parts):
        rec = parts[i]
        if len(rec) < 4 or rec[2] != " ":
            return None
        xy, path = rec[:2], rec[3:]
        i += 1
        paths.setdefault(path, False)
        if "R" in xy or "C" in xy:
            if i >= len(parts):
                return None
            if "R" in xy:
                # old path of a rename no longer exists -> recorded as DELETED
                paths.setdefault(parts[i], False)
            i += 1
    return paths


def resolve_repo_root(repo_dir: str) -> Optional[str]:
    """realpath of the git toplevel for repo_dir, for the degraded-BLOCK path.

    If even a bare `rev-parse --show-toplevel` fails, fall back to the realpath of repo_dir
    itself (the hook payload's cwd). That is a weaker identity -- it may be a subdirectory of
    the real root -- but a BLOCK recorded under a too-narrow root is still recorded, which
    beats losing it; U2 matches roots by prefix for scope='repo' rows.
    """
    try:
        if not isinstance(repo_dir, str) or not repo_dir:
            return None
        top = _git(repo_dir, ["rev-parse", "--show-toplevel"])
        if top is not None and top.returncode == 0 and top.stdout.strip("\n"):
            return os.path.realpath(top.stdout.strip("\n"))
        return os.path.realpath(repo_dir)
    except Exception:
        return None


def take_snapshot(repo_dir: str) -> Optional[dict]:
    """Snapshot the dirty set of the git repo containing repo_dir, or None (fail closed)."""
    try:
        if not isinstance(repo_dir, str) or not repo_dir:
            return None
        top = _git(repo_dir, ["rev-parse", "--show-toplevel"])
        if top is None or top.returncode != 0:
            return None
        root_raw = top.stdout.strip("\n")
        if not root_raw:
            return None
        root = os.path.realpath(root_raw)
        st = _git(root, ["status", "--porcelain=v1", "-z", "--untracked-files=all"])
        if st is None or st.returncode != 0:
            return None
        paths = _parse_status(st.stdout)
        if paths is None or len(paths) > MAX_PATHS:
            return None

        files = {}  # type: Dict[str, str]
        to_hash = []  # type: List[str]
        total = 0
        fmt = None
        for rel in sorted(paths):
            if not rel or "\n" in rel:
                # cast_git_safe's hash-object refuses newline paths; omit THIS path only
                # (it stays unreviewed) rather than failing the whole snapshot.
                continue
            full = os.path.join(root, rel)
            try:
                lst = os.lstat(full)
            except FileNotFoundError:
                files[rel] = DELETED
                continue
            if stat.S_ISLNK(lst.st_mode):
                # Never follow: hash the link text exactly as git stores it.
                if fmt is None:
                    fmt = _object_format(root)
                files[rel] = _symlink_blob(full, fmt)
            elif stat.S_ISREG(lst.st_mode):
                total += lst.st_size
                if total > MAX_BYTES:
                    return None
                to_hash.append(rel)
            # directories (submodules / nested repos) and special files are left out:
            # an absent path is simply "not covered", which is the safe direction.

        for i in range(0, len(to_hash), _HASH_BATCH):
            batch = to_hash[i:i + _HASH_BATCH]
            res = _git(root, ["hash-object", "--"] + batch)
            if res is None or res.returncode != 0:
                return None
            shas = res.stdout.split("\n")
            if shas and shas[-1] == "":
                shas.pop()
            if len(shas) != len(batch) or not all(re.fullmatch(r"[0-9a-f]{40,64}", s) for s in shas):
                return None
            files.update(zip(batch, shas))
        return {"repo_root": root, "files": files}
    except Exception:
        return None


def stable_files(start: dict, stop: dict) -> dict:
    """Paths present in both snapshots with an identical value; {} unless repo_root matches."""
    try:
        if not isinstance(start, dict) or not isinstance(stop, dict):
            return {}
        root = start.get("repo_root")
        if not isinstance(root, str) or not root or root != stop.get("repo_root"):
            return {}
        a, b = start.get("files"), stop.get("files")
        if not isinstance(a, dict) or not isinstance(b, dict):
            return {}
        return {p: v for p, v in a.items() if p in b and b[p] == v}
    except Exception:
        return {}


# --- verdict ---------------------------------------------------------------------------
# NO Markdown parsing. Fence state is inherently ambiguous (a closer our parser accepts that
# CommonMark does not, or the reverse, turns a quoted example `Verdict: APPROVE` into a real
# approval), so fences are not tracked at all: quoted content is untrusted and simply counts.
# Rule (default-deny, fail closed):
#   * Lines split on \r\n | \r | \n only. Each line is normalised for DETECTION: Cf and Cc
#     characters removed, every Unicode whitespace -> one space, NFKC (so NBSP, ZWSP, NUL,
#     fullwidth colon and friends cannot hide a verdict token). ASCII lines are normalised too.
#   * A verdict line is any normalised line matching `verdict[ *_`]*:` OR
#     `verdict\W{0,40}(approve|block|reject)` (case-insensitive), anywhere -- fenced, quoted,
#     prefixed, mid-sentence. The second form catches `Verdict - BLOCKED`, `**Verdict** -- BLOCKED`
#     and `Verdict BLOCKED`; prose with words between ("the verdict should block") does not match.
#   * zero verdict lines -> None;  more than one -> BLOCKED;
#     exactly one that is not the strict form -> BLOCKED. Strict = `Verdict: APPROVE`,
#     case-SENSITIVE, >=1 space after the colon, optional ** / __ wrapping, no prefix, and the
#     RAW line equals its normalised form apart from trailing whitespace.
#   * a strict line yields APPROVE only if it is among the last 15 non-blank lines AND the
#     nearest non-blank line directly above or below it is a line-anchored
#     `Status: DONE|DONE_WITH_CONCERNS` (plain spaces / tabs only: NBSP is not accepted).
#     Lines holding only invisible characters count as blank for adjacency and for the
#     15-line window. Otherwise BLOCKED (an unanchored lone APPROVE is
#     suspect). Text over MAX_VERDICT_TEXT is BLOCKED.
# Residual (accepted): an honest reviewer that omits OR mis-formats its OWN verdict (in a form
# neither detector pattern matches) AND whose last lines quote a planted strict Verdict + Status
# pair would be read as approving.
# Out of scope: a reviewer whose OWN Status/Verdict is obfuscated (zero-width, fullwidth,
# homoglyph -- e.g. `Sta<ZWSP>tus: BLOCKED`). In the broad status gate in
# cast_subagent_stop.py the literal words `Status` and `BLOCKED` must be ASCII; the separator
# between them may be any whitespace or non-alphanumeric character. So such a line is invisible
# to it too; an honest reviewer writes its status in ASCII, and a compromised reviewer can emit
# a clean APPROVE anyway. decide() additionally requires the caller's Status gate to pass.
# Accepted fail-closed false blocks include `Verdict \u2014 APPROVE` (non-strict), an
# indented/bulleted Status line next to a strict APPROVE, and prose such as
# "verdict: block-level findings none".
# decide() callers (U1b): derive status_gate from the SAME final message as this text -- never
# infer it from parse_verdict.
# Linear: one pass, bounded-class regexes, no nested unbounded quantifiers.
_VERDICT_LINE_RE = re.compile(
    r"verdict[ *_`]*:|verdict\W{0,40}(?:approve|block|reject)", re.IGNORECASE
)
_STRICT_APPROVE_RE = re.compile(
    r"(?:\*\*|__)?Verdict:(?:\*\*|__)? +(?:\*\*|__)?APPROVE(?:\*\*|__)?"
)
_STATUS_PASS_RE = re.compile(
    r"(?:\*\*|__)?Status:(?:\*\*|__)?[ \t]+(?:\*\*|__)?(?:DONE|DONE_WITH_CONCERNS)(?:\*\*|__)?[ \t]*"
)
_LINE_SPLIT_RE = re.compile(r"\r\n|\r|\n")  # NOT str.splitlines: U+2028 etc must not split
_WS_RE = re.compile(r"\s")
_ASCII_CC_RE = re.compile(r"[\x00-\x08\x0e-\x1b\x7f]")  # Cc that is not whitespace
_TAIL_WINDOW = 15


def _drop_invisible(s: str) -> str:
    return "".join(c for c in s if unicodedata.category(c) not in ("Cf", "Cc") or c.isspace())


def _normalise(line: str) -> str:
    if line.isascii():
        line = _ASCII_CC_RE.sub("", line)
    else:
        line = _drop_invisible(unicodedata.normalize("NFKC", _drop_invisible(line)))
    return _WS_RE.sub(" ", line)


def parse_verdict(text: str) -> Optional[str]:
    """'APPROVE' (single strict anchored verdict), 'BLOCKED' (anything suspect) or None."""
    try:
        if not isinstance(text, str) or not text:
            return None
        if len(text) > MAX_VERDICT_TEXT:
            return "BLOCKED"
        raws = _LINE_SPLIT_RE.split(text)
        norms = [_normalise(r) for r in raws]
        verdict_idx = [i for i, n in enumerate(norms) if _VERDICT_LINE_RE.search(n)]
        if not verdict_idx:
            return None
        if len(verdict_idx) > 1:
            return "BLOCKED"
        v = verdict_idx[0]
        raw_v = raws[v].rstrip()
        if raw_v != norms[v].rstrip() or _STRICT_APPROVE_RE.fullmatch(raw_v) is None:
            return "BLOCKED"
        nonblank = [i for i, n in enumerate(norms) if n.strip()]
        k = nonblank.index(v)  # v is non-blank: it matched the verdict regex
        if k < len(nonblank) - _TAIL_WINDOW:
            return "BLOCKED"
        for nb in (k - 1, k + 1):
            if 0 <= nb < len(nonblank) and _STATUS_PASS_RE.fullmatch(raws[nonblank[nb]]):
                return "APPROVE"
        return "BLOCKED"
    except Exception:
        return None


def decide(verdict: Optional[str], status_gate: Optional[str]) -> str:
    """APPROVE only with an APPROVE verdict AND a passing Status; everything else BLOCKED.

    status_gate MUST be derived by the caller (U1b) from the same final message that was
    given to parse_verdict -- never inferred from the parse_verdict result.
    """
    if verdict == "APPROVE" and status_gate in ("DONE", "DONE_WITH_CONCERNS"):
        return "APPROVE"
    return "BLOCKED"


# --- storage ---------------------------------------------------------------------------
_BLOB_RE = re.compile(r"(?:[0-9a-f]{40}|[0-9a-f]{64}|DELETED)")


def default_db_path() -> str:
    return os.environ.get("CAST_DB_PATH", os.path.expanduser("~/.claude/cast.db"))


def _opt_str(v) -> bool:
    return v is None or isinstance(v, str)


def path_key(path: str) -> str:
    """Lossless, SQLite-safe key for a repo-relative path. U2 MUST use this same function.

    A path that is valid UTF-8 (after os.fsencode, so surrogateescape'd bytes round-trip) is
    stored as-is; anything else becomes '\\x00b:' + hex of its raw bytes. A real path can never
    start with NUL, so the two spaces cannot collide.
    """
    try:
        raw = os.fsencode(path)
    except UnicodeEncodeError:
        raw = path.encode("utf-8", "surrogatepass")
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError:
        return "\x00b:" + raw.hex()
    if "\x00" in text:
        return "\x00b:" + raw.hex()
    return text


def _insert(
    db_path: str,
    session_id: Optional[str],
    agent_id: Optional[str],
    reviewer: str,
    repo_root: str,
    decision: str,
    scope: str,
    started_at: Optional[str],
    ended_at: Optional[str],
    rows: List[tuple],
) -> bool:
    """One transaction: parent row + child rows. mode=rw never creates a missing DB file.

    Raw sqlite3 (not cast_db.db_write): db_write is single-row/single-table and cannot give
    one transaction across the two tables.
    """
    conn = None
    try:
        uri = "file:" + urllib.parse.quote(os.path.abspath(db_path)) + "?mode=rw"
        conn = sqlite3.connect(uri, uri=True, timeout=5, isolation_level=None)
        conn.execute("PRAGMA busy_timeout=5000")
        conn.execute("PRAGMA foreign_keys=ON")
        conn.execute("BEGIN IMMEDIATE")
        try:
            cur = conn.execute(
                "INSERT INTO review_snapshots (session_id, agent_id, reviewer, repo_root, decision, scope, started_at, ended_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                (session_id, agent_id, reviewer, repo_root, decision, scope, started_at, ended_at),
            )
            if rows:
                conn.executemany(
                    "INSERT INTO review_snapshot_files (snapshot_id, path, blob) VALUES (?, ?, ?)",
                    [(cur.lastrowid, p, b) for p, b in rows],
                )
            conn.execute("COMMIT")
        except Exception:
            conn.execute("ROLLBACK")
            raise
        return True
    except Exception:
        return False
    finally:
        if conn is not None:
            try:
                conn.close()
            except Exception:
                pass


def record(
    db_path: str,
    *,
    session_id: Optional[str],
    agent_id: Optional[str],
    reviewer: str,
    repo_root: str,
    decision: str,
    started_at: Optional[str],
    ended_at: Optional[str],
    files: dict,
) -> bool:
    """Insert one review_snapshots row (scope='files') + one row per path, atomically.

    Paths are stored via path_key(); blobs must be 40/64 lowercase hex or "DELETED", else
    False. Never raises. CONTRACT: if this returns False for decision == "BLOCKED" (or the
    snapshot could not be taken at all), the caller MUST fall back to record_degraded_block()
    so a BLOCK is never lost to a snapshot/record failure.
    """
    try:
        if decision not in ("APPROVE", "BLOCKED") or not reviewer or not repo_root:
            return False
        if not isinstance(files, dict) or not _opt_str(session_id) or not _opt_str(agent_id):
            return False
        rows = []
        for p, b in files.items():
            if not isinstance(p, str) or not isinstance(b, str) or not _BLOB_RE.fullmatch(b):
                return False
            key = path_key(p)
            if not key:
                return False
            rows.append((key, b))
        return _insert(db_path, session_id, agent_id, reviewer, repo_root, decision,
                       "files", started_at, ended_at, rows)
    except Exception:
        return False


def record_degraded_block(
    db_path: str,
    *,
    session_id: Optional[str],
    agent_id: Optional[str],
    reviewer: str,
    repo_root: str,
    started_at: Optional[str],
    ended_at: Optional[str],
) -> bool:
    """Write a BLOCKED row with scope='repo' and no files (BLOCK survives a failed snapshot).

    repo_root: use resolve_repo_root() -- it falls back to the payload cwd realpath if even a
    bare rev-parse fails. Never raises.
    """
    try:
        if not reviewer or not isinstance(repo_root, str) or not repo_root:
            return False
        if not _opt_str(session_id) or not _opt_str(agent_id):
            return False
        return _insert(db_path, session_id, agent_id, reviewer, repo_root, "BLOCKED",
                       "repo", started_at, ended_at, [])
    except Exception:
        return False


# --- start-snapshot persistence (SubagentStart and SubagentStop are different processes) ---
_AGENT_ID_RE = re.compile(r"[A-Za-z0-9_-]{1,128}")


def default_state_dir() -> str:
    return os.path.expanduser("~/.claude/cast-state/review-snapshots")


def _state_dir_ok(state_dir: str, create: bool) -> bool:
    try:
        if create:
            os.makedirs(state_dir, mode=0o700, exist_ok=True)
        st = os.lstat(state_dir)
        return (
            stat.S_ISDIR(st.st_mode)
            and st.st_uid == os.getuid()
            and not (st.st_mode & 0o022)
        )
    except OSError:
        return False


def _sweep_stale_tmp(state_dir: str) -> None:
    """Best-effort: remove regular '.*.tmp' leftovers older than STALE_TMP_SECONDS."""
    try:
        cutoff = time.time() - STALE_TMP_SECONDS
        with os.scandir(state_dir) as it:
            for ent in it:
                if not (ent.name.startswith(".") and ent.name.endswith(".tmp")):
                    continue
                try:
                    st = ent.stat(follow_symlinks=False)
                    if stat.S_ISREG(st.st_mode) and st.st_mtime < cutoff:
                        os.unlink(ent.path)
                except OSError:
                    pass
    except OSError:
        pass


def save_start(state_dir: str, agent_id: str, snap: dict, *,
               session_id: Optional[str], reviewer: str) -> bool:
    """Atomically write <state_dir>/<agent_id>.json (0600), bound to session_id + reviewer."""
    tmp = None
    try:
        if not isinstance(agent_id, str) or not _AGENT_ID_RE.fullmatch(agent_id):
            return False
        if not _opt_str(session_id) or not isinstance(reviewer, str) or not reviewer:
            return False
        if not isinstance(snap, dict) or not isinstance(snap.get("repo_root"), str):
            return False
        data = json.dumps({
            "session_id": session_id,
            "reviewer": reviewer,
            "repo_root": snap["repo_root"],
            "snap": snap,
        }).encode("utf-8")
        if len(data) > MAX_STATE_BYTES or not _state_dir_ok(state_dir, create=True):
            return False
        _sweep_stale_tmp(state_dir)
        tmp = os.path.join(state_dir, ".%s.%d.tmp" % (agent_id, os.getpid()))
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, "wb") as fh:
            fh.write(data)
        os.replace(tmp, os.path.join(state_dir, agent_id + ".json"))
        tmp = None
        return True
    except Exception:
        return False
    finally:
        if tmp is not None:
            try:
                os.unlink(tmp)
            except OSError:
                pass


def load_start(state_dir: str, agent_id: str, *,
               session_id: Optional[str], reviewer: str) -> Optional[dict]:
    """Read and DELETE <state_dir>/<agent_id>.json; the snapshot, or None.

    None when absent / invalid / oversized / not a regular file, or when the stored
    session_id + reviewer do not both match the caller's (the file is consumed either way).
    """
    try:
        if not isinstance(agent_id, str) or not _AGENT_ID_RE.fullmatch(agent_id):
            return None
        if not _state_dir_ok(state_dir, create=False):
            return None
        path = os.path.join(state_dir, agent_id + ".json")
        # NOFOLLOW: ELOOP on a symlink (file left alone). NONBLOCK: opening a FIFO must not hang.
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        data = None
        try:
            st = os.fstat(fd)
            if stat.S_ISREG(st.st_mode) and st.st_size <= MAX_STATE_BYTES:
                with os.fdopen(fd, "rb", closefd=False) as fh:
                    data = fh.read(MAX_STATE_BYTES + 1)
        finally:
            os.close(fd)
            try:
                os.unlink(path)
            except OSError:
                pass
        if data is None or len(data) > MAX_STATE_BYTES:
            return None
        env = json.loads(data.decode("utf-8"))
        if not isinstance(env, dict):
            return None
        if env.get("session_id") != session_id or env.get("reviewer") != reviewer:
            return None
        snap = env.get("snap")
        if (
            isinstance(snap, dict)
            and isinstance(snap.get("repo_root"), str)
            and snap.get("repo_root") == env.get("repo_root")
            and isinstance(snap.get("files"), dict)
            and all(isinstance(k, str) and isinstance(v, str) for k, v in snap["files"].items())
        ):
            return snap
        return None
    except Exception:
        return None
