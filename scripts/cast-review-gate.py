#!/usr/bin/env python3
"""cast-review-gate.py -- content-bound review gate, WARN mode (v10.6.0 U2).

Invoked at commit time as `python3 -I -E -s ~/.claude/scripts/cast-review-gate.py` from the repo
being committed. For every STAGED path it asks: is the exact content about to be committed (the
git blob) covered by a code-reviewer APPROVE recorded in review_snapshots / review_snapshot_files
(U1a recorder, scripts/cast_review_snapshot.py), and is it free of any recorded BLOCK?

WARN mode: this script NEVER blocks. It always exits 0, prints exactly ONE stdout line, and
writes one review_gate_decisions row (would_block = what enforcement WOULD have done) so the
false-positive rate can be measured before enforcement is switched on.

Per staged path (first match wins):
  derived     CAST repo only: under plugin/ or == cast-stats.json (generated, not reviewable).
              "CAST repo" = the two marker files AND the repo's root commit is CAST_ROOT_COMMIT
              (F3; evaluated lazily, any git failure -> not CAST -> exemption off)
  blocked     an UNCLEARED file-scoped BLOCKED row binds this exact (path, blob); or a
              repo-wide block (scope='repo' row / review-unrecorded marker under this repo)
              not cleared by a LATER file-scoped review. A file-scoped BLOCK by reviewer type T is
              cleared iff a file-scoped APPROVE by the SAME type T on the same (path, blob) has
              started_at strictly later than the BLOCK's ended_at (latest same-type wins; epochs
              compared; unparseable/NULL timestamps -> not cleared). A security BLOCK is never
              cleared by a code-reviewer APPROVE and vice versa.
  approved    a code-reviewer APPROVE binds this exact (path, blob) AND its recorded git file mode
              equals the staged index mode (F2; a NULL mode never approves; deletions skip the mode
              check). Security APPROVE never counts.
  hatched     would be unreviewed, but CAST_UNREVIEWED_OK is set (never turns blocked -> hatched)
  unreviewed  everything else, including: unstaged changes on the path, unreadable file, DB
              unavailable (fail closed in the CATEGORY; the exit code is still 0)

Trust/robustness: git is reached only through cast_git_safe (via cast_review_snapshot._git); the
DB is read with mode=ro and written with mode=rw (a missing DB is never created); markers are
read-only (never deleted); the whole run is bounded (~20 s) and wrapped so it cannot crash.

Library entry: evaluate(root, *, db_path, home, hatch, budget_s) -> dict is the in-process entry
used by the PreToolUse git guard. It never raises and returns results/counts/would_block/db_ok/error;
`hatch` (a reason string) replaces the CAST_UNREVIEWED_OK env read. run() is the CLI wrapper.

Python 3.9 compatible, stdlib only.
"""
import datetime
import hashlib
import importlib.util
import json
import os
import re
import sqlite3
import stat
import subprocess
import sys
import time
import urllib.parse
from typing import Dict, List, Optional, Set, Tuple

BUDGET_S = 20.0
GIT_TIMEOUT_S = 10.0
HASH_BATCH = 200
MAX_MARKER_BYTES = 64 * 1024
MAX_REASONS = 50
MAX_REASONS_BYTES = 16 * 1024
MAX_DISPLAY = 120
MAX_GITLINKS = 200  # more index gitlinks than this -> gitlink-unknown (per-link rev-parse is a spawn each)
MAX_BYTES = 50 * 1024 * 1024  # same total-size cap as take_snapshot
DB_TIMEOUT_S = 3.0
MAX_FUTURE_S = 300.0  # an APPROVE starting further ahead than this cannot clear a BLOCK
SCRIPT_NAME = "cast-review-gate.py"
CAST_ROOT_COMMIT = "6e91a7b35815811aee513bc038697c8dd85a4663"  # CAST's root commit (F3 repo identity)

_SCRIPTS_DIR = os.path.dirname(os.path.realpath(__file__))
_CRS = None  # cast_review_snapshot module, loaded lazily
# control chars, line/para separators, bidi controls, zero-width chars (escapes, not raw chars)
_CTRL_RE = re.compile(
    "[\x00-\x1f\x7f-\x9f\u2028\u2029\u202a-\u202e\u2066-\u2069"
    "\u200e\u200f\u061c\u200b-\u200d\ufeff]")


# ---------------------------------------------------------------------------------- helpers

def _load_crs():
    """Load cast_review_snapshot.py by explicit realpath (no sys.path / cwd imports)."""
    global _CRS
    if _CRS is None:
        spec = importlib.util.spec_from_file_location(
            "cast_review_snapshot", os.path.join(_SCRIPTS_DIR, "cast_review_snapshot.py"))
        if spec is None or spec.loader is None:
            raise ImportError("cast_review_snapshot unavailable")
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        _CRS = mod
    return _CRS


def _log_error(msg: str) -> None:
    """Append one line to ~/.claude/logs/hook-errors.log. Never raises."""
    try:
        log_dir = os.path.join(os.path.expanduser("~"), ".claude", "logs")
        os.makedirs(log_dir, exist_ok=True)
        ts = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        line = f"{ts} [{SCRIPT_NAME}] {_CTRL_RE.sub('?', msg)[:500]}\n"
        fd = os.open(os.path.join(log_dir, "hook-errors.log"),
                     os.O_WRONLY | os.O_CREAT | os.O_APPEND | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, "wb") as fh:
            fh.write(line.encode("utf-8", "replace"))
    except Exception:
        pass


def _display(path: str, limit: int = MAX_DISPLAY) -> str:
    """Terminal-safe, bounded rendering of a path (control chars -> '?', lone surrogates -> '?')."""
    s = path.encode("utf-8", "replace").decode("utf-8", "replace")
    s = _CTRL_RE.sub("?", s)
    return s if len(s) <= limit else s[:limit - 3] + "..."


def _emit(line: str) -> None:
    """Exactly one stdout line, UTF-8 regardless of locale (-E clears PYTHONIOENCODING)."""
    data = (line.replace("\n", " ").replace("\r", " ") + "\n").encode("utf-8", "replace")
    try:
        sys.stdout.buffer.write(data)
        sys.stdout.buffer.flush()
    except Exception:
        pass


def _to_epoch(ts) -> Optional[float]:
    """ISO-T/Z (or space-format / offset) timestamp -> UTC epoch seconds; None if unparseable."""
    if not isinstance(ts, str) or not ts.strip():
        return None
    s = ts.strip()
    if s.endswith(("Z", "z")):
        s = s[:-1] + "+00:00"
    try:
        dt = datetime.datetime.fromisoformat(s)
    except ValueError:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=datetime.timezone.utc)
    return dt.timestamp()


def _t(end: float) -> float:
    """Per-call timeout: min(GIT_TIMEOUT_S, remaining budget), floored so a spent budget still fails fast."""
    return min(GIT_TIMEOUT_S, max(0.1, end - time.monotonic()))


def _under(root: str, other: str) -> bool:
    """other == root or other is a path-component descendant of root."""
    return other == root or other.startswith(root.rstrip("/") + "/")


# ---------------------------------------------------------------------------------- DB reads

class Store:
    """Read-only view of review_snapshots*. Any DB error flips .ok False (fail closed)."""

    def __init__(self, db_path: str, timeout: float = DB_TIMEOUT_S) -> None:
        self.ok = False
        self.err = ""
        self._conn = None  # type: Optional[sqlite3.Connection]
        try:
            uri = "file:" + urllib.parse.quote(os.path.abspath(db_path)) + "?mode=ro"
            conn = sqlite3.connect(uri, uri=True, timeout=timeout)
            conn.execute(f"PRAGMA busy_timeout={int(timeout * 1000)}")
            conn.execute("SELECT 1 FROM review_snapshots LIMIT 1").fetchall()
            conn.execute("SELECT 1 FROM review_snapshot_files LIMIT 1").fetchall()
            self._conn = conn
            self.ok = True
        except sqlite3.Error as exc:
            self.err = f"{type(exc).__name__}: {exc}"
            _log_error(f"db unavailable: {self.err}")

    def close(self) -> None:
        if self._conn is not None:
            try:
                self._conn.close()
            except sqlite3.Error:
                pass

    def _fail(self, exc: Exception) -> None:
        self.ok = False
        self.err = f"{type(exc).__name__}: {exc}"
        _log_error(f"db query failed: {self.err}")

    def has_file_row(self, repo_root: str, key: str, blob: str, decision: str,
                     reviewer: Optional[str] = None, mode: Optional[str] = None) -> bool:
        """Any file-scoped row of `decision` (optionally by `reviewer`, optionally recorded with
        git file `mode`; a NULL recorded mode never matches) binding (key, blob)?"""
        if not self.ok or self._conn is None:
            return False
        sql = ("SELECT 1 FROM review_snapshots s JOIN review_snapshot_files f ON f.snapshot_id = s.id "
               "WHERE s.decision = ? AND s.scope = 'files' AND s.repo_root = ? AND f.path = ? AND f.blob = ?")
        params = [decision, repo_root, key, blob]  # type: list
        if reviewer is not None:
            sql += " AND s.reviewer = ?"
            params.append(reviewer)
        if mode is not None:
            sql += " AND f.mode = ?"
            params.append(mode)
        try:
            return self._conn.execute(sql + " LIMIT 1", params).fetchone() is not None
        except sqlite3.Error as exc:
            self._fail(exc)
            return False

    def uncleared_block(self, repo_root: str, key: str, blob: str) -> bool:
        """True iff a file-scoped BLOCKED row on (key, blob) is not cleared. A BLOCK by reviewer
        type T is cleared iff a file-scoped APPROVE by the same T on the same (key, blob) has
        started_at strictly later than the BLOCK's ended_at (epochs; unparseable/NULL -> not
        cleared). On DB error: .ok goes False and this returns False (path -> db-unavailable)."""
        if not self.ok or self._conn is None:
            return False
        base = ("SELECT s.reviewer, s.{col}{extra} FROM review_snapshots s JOIN review_snapshot_files f "
                "ON f.snapshot_id = s.id WHERE s.decision = ? AND s.scope = 'files' "
                "AND s.repo_root = ? AND f.path = ? AND f.blob = ?")
        try:
            blocks = self._conn.execute(base.format(col="ended_at", extra=""), ("BLOCKED", repo_root, key, blob)).fetchall()
            if not blocks:
                return False
            approves = self._conn.execute(base.format(col="started_at", extra=", s.ended_at"), ("APPROVE", repo_root, key, blob)).fetchall()
        except sqlite3.Error as exc:
            self._fail(exc)
            return False
        starts = {}  # type: Dict[str, List[float]]
        now = time.time()
        for reviewer, started, stopped in approves:
            ep, stop_ep = _to_epoch(started), _to_epoch(stopped)
            # an APPROVE whose clock is implausible cannot clear a BLOCK: unparseable own ended_at,
            # started after it ended, or starting more than MAX_FUTURE_S in the future
            if ep is None or stop_ep is None or ep > stop_ep or ep > now + MAX_FUTURE_S:
                continue
            starts.setdefault(reviewer, []).append(ep)
        for reviewer, ended in blocks:
            b = _to_epoch(ended)
            if b is None or not any(a > b for a in starts.get(reviewer, [])):
                return True
        return False

    def degraded_block_ended_ats(self, repo_root: str) -> Optional[List[Optional[str]]]:
        """ended_at of every scope='repo' BLOCKED row at/under repo_root. None on DB error."""
        if not self.ok or self._conn is None:
            return None
        try:
            rows = self._conn.execute(
                "SELECT repo_root, ended_at FROM review_snapshots WHERE decision = 'BLOCKED' AND scope = 'repo'"
            ).fetchall()
        except sqlite3.Error as exc:
            self._fail(exc)
            return None
        return [r[1] for r in rows if isinstance(r[0], str) and _under(repo_root, r[0])]

    def latest_file_review_epoch(self, repo_root: str) -> Optional[float]:
        """Max parseable ended_at over file-scoped rows (any decision) for repo_root."""
        if not self.ok or self._conn is None:
            return None
        try:
            rows = self._conn.execute(
                "SELECT ended_at FROM review_snapshots WHERE scope = 'files' AND repo_root = ?", (repo_root,)
            ).fetchall()
        except sqlite3.Error as exc:
            self._fail(exc)
            return None
        eps = [e for e in (_to_epoch(r[0]) for r in rows) if e is not None]
        return max(eps) if eps else None


def read_markers(repo_root: str, home: str) -> List[Optional[str]]:
    """ts of every valid review-unrecorded marker at/under repo_root (None = unparseable ts)."""
    base = os.path.join(home, ".claude", "cast-state", "review-unrecorded")
    out = []  # type: List[Optional[str]]
    try:
        names = sorted(os.listdir(base))
    except OSError:
        return out
    for name in names:
        full = os.path.join(base, name)
        try:
            st = os.lstat(full)
            if not stat.S_ISREG(st.st_mode) or st.st_size > MAX_MARKER_BYTES:
                _log_error(f"marker skipped (not regular or oversized): {_display(name)}")
                continue
            fd = os.open(full, os.O_RDONLY | os.O_NOFOLLOW)
            with os.fdopen(fd, "rb") as fh:
                obj = json.loads(fh.read(MAX_MARKER_BYTES + 1).decode("utf-8"))
        except (OSError, ValueError) as exc:
            _log_error(f"marker skipped (unreadable/malformed): {_display(name)} {type(exc).__name__}")
            continue
        if not isinstance(obj, dict) or not isinstance(obj.get("repo_root"), str):
            _log_error(f"marker skipped (bad shape): {_display(name)}")
            continue
        if _under(repo_root, obj["repo_root"]):
            ts = obj.get("ts")
            out.append(ts if isinstance(ts, str) else None)
    return out


def repo_wide_blocked(store: Store, repo_root: str, home: str) -> bool:
    """True iff a scope='repo' BLOCK row or unrecorded marker is not cleared by a LATER review."""
    degraded = store.degraded_block_ended_ats(repo_root)
    if degraded is None:
        degraded = []
    items = list(degraded) + read_markers(repo_root, home)
    if not items:
        return False
    latest = store.latest_file_review_epoch(repo_root)
    for ts in items:
        ep = _to_epoch(ts)
        if ep is None or latest is None or not latest > ep:
            return True  # unparseable / no later review -> still blocking (fail closed)
    return False


# ---------------------------------------------------------------------------------- git

def _git_diff_z(crs, root: str, args: List[str], t: float) -> Optional[List[str]]:
    res = crs._git(root, args, t)
    if res is None or res.returncode != 0:
        return None
    parts = res.stdout.split("\0")
    if parts and parts[-1] == "":
        parts.pop()
    return parts


def staged_entries(crs, root: str, t: float) -> Optional[List[Tuple[str, str, str, str]]]:
    """[(status_letter, path, new_mode, new_blob)] from `diff --cached --raw -z --no-renames`."""
    parts = _git_diff_z(crs, root, ["diff", "--cached", "--raw", "-z", "--no-renames", "--no-abbrev"], t)
    if parts is None or len(parts) % 2 != 0:
        return None
    out = []  # type: List[Tuple[str, str, str, str]]
    for i in range(0, len(parts), 2):
        hdr = parts[i]
        fields = hdr[1:].split(" ") if hdr.startswith(":") else []
        if len(fields) != 5:
            return None
        out.append((fields[4][:1], parts[i + 1], fields[1], fields[3]))
    return out


def gitlink_entries(crs, root: str, diff_paths: Set[str], end: float) -> List[Tuple[str, str, str, str]]:
    """Staged gitlink (submodule) changes as ('G', path, '160000', reason) entries.

    cast_git_safe injects --ignore-submodules=all into diff/diff-index (and refuses
    --ignore-submodules*), so staged_entries() can never see a 160000 entry. ls-tree is not on
    its allowlist either, so: added/changed = index gitlinks (`ls-files --stage`) whose
    `rev-parse HEAD:<path>` differs; removed = paths that `ls-files --with-tree=HEAD` lists but
    the index and the visible diff do not (a removed gitlink is the only entry type hidden from
    both). Any failure -> one synthetic 'gitlink-unknown' entry (fail closed).
    """
    unknown = [("G", "(gitlink check failed)", "160000", "gitlink-unknown")]
    res = crs._git(root, ["ls-files", "--stage", "-z"], _t(end))
    if res is None or res.returncode != 0:
        return unknown
    index_paths = set()  # type: Set[str]
    index_links = {}  # type: Dict[str, str]
    for rec in res.stdout.split("\0"):
        if not rec:
            continue
        meta, sep, path = rec.partition("\t")
        fields = meta.split(" ")
        if not sep or len(fields) != 3:
            return unknown
        index_paths.add(path)
        if fields[0] == "160000":
            index_links[path] = fields[1]
            if len(index_links) > MAX_GITLINKS:
                return unknown
    head = crs._git(root, ["rev-parse", "--verify", "--quiet", "HEAD"], _t(end))
    # rc 0 = HEAD exists, rc 1 = unborn HEAD; anything else (timeout 124, lib error 3, None) is
    # unknown and must NOT be read as "unborn" (that would skip the removed-gitlink scan).
    if head is None or head.returncode not in (0, 1):
        return unknown
    head_ok = head.returncode == 0
    out = []  # type: List[Tuple[str, str, str, str]]
    for path in sorted(index_links):
        changed = True
        if head_ok:
            if time.monotonic() >= end:
                return unknown
            r = crs._git(root, ["rev-parse", f"HEAD:{path}"], _t(end))
            changed = r is None or r.returncode != 0 or r.stdout.strip() != index_links[path]
        if changed:
            out.append(("G", path, "160000", "gitlink"))
    if head_ok:
        wt = crs._git(root, ["ls-files", "-t", "--with-tree=HEAD", "-z"], _t(end))
        if wt is None or wt.returncode != 0:
            return unknown
        tree_only = set()  # type: Set[str]
        for rec in wt.stdout.split("\0"):
            if rec:
                tree_only.add(rec[2:])
        for path in sorted(tree_only - index_paths - diff_paths):
            out.append(("G", path, "160000", "gitlink"))
    return out


def unstaged_set(crs, root: str, t: float) -> Optional[Set[str]]:
    parts = _git_diff_z(crs, root, ["diff", "--name-only", "-z", "--no-renames"], t)
    return None if parts is None else set(parts)


def hash_worktree(crs, root: str, rels: List[str], end: float):
    """rel -> (kind, blob, reason). kind is 'link'|'file'; blob is None (with a reason) when the
    path is unreadable, out of budget, or over the total-size cap. Same hashing as take_snapshot."""
    result = {}  # type: Dict[str, Tuple[Optional[str], Optional[str], Optional[str]]]
    to_hash = []  # type: List[str]
    fmt = None
    total = 0
    for rel in rels:
        result[rel] = (None, None, "unreadable-or-timeout")
        if not rel or "\n" in rel:
            continue  # cast_git_safe's hash-object refuses newline paths -> stays unreviewed
        full = os.path.join(root, rel)
        try:
            lst = os.lstat(full)
        except OSError:
            continue
        if stat.S_ISLNK(lst.st_mode):
            try:
                if fmt is None:
                    if end - time.monotonic() <= 0:
                        result[rel] = (None, None, "budget")
                        continue
                    fmt = crs._object_format(root, _t(end))
                result[rel] = ("link", crs._symlink_blob(full, fmt), None)
            except OSError:
                pass
        elif stat.S_ISREG(lst.st_mode):
            total += lst.st_size
            if total > MAX_BYTES:
                result[rel] = (None, None, "size-cap")
                continue
            to_hash.append(rel)
    for i in range(0, len(to_hash), HASH_BATCH):
        batch = to_hash[i:i + HASH_BATCH]
        if end - time.monotonic() <= 0:
            for rel in to_hash[i:]:
                result[rel] = (None, None, "budget")
            break
        res = crs._git(root, ["hash-object", "--"] + batch, _t(end))
        if res is None or res.returncode != 0:
            continue
        shas = res.stdout.split("\n")
        if shas and shas[-1] == "":
            shas.pop()
        if len(shas) != len(batch) or not all(re.fullmatch(r"[0-9a-f]{40,64}", x) for x in shas):
            continue
        for rel, sha in zip(batch, shas):
            result[rel] = ("file", sha, None)
    return result


def is_cast_repo(root: str, end: float) -> bool:
    """CAST identity: the two marker files AND CAST_ROOT_COMMIT among the repo's root commits.

    F3 proves "this repo's history descends from CAST's root commit", NOT "this is CAST": a repo
    that fetches CAST history passes. That is accepted -- the exemption is applied AFTER block
    checks, so it can never override a recorded BLOCK, and pre-commit's drift check still runs.
    A shallow clone has no visible root commit, so it fails closed (exemption off), as does any
    git failure. Grafts/replace refs cannot forge the root: cast_git_safe passes
    --no-replace-objects on every call (verified in scripts/cast-hook-lib.sh), so no extra flag
    is needed here."""
    try:
        for rel in ("agents/core/commit.md", "scripts/cast_review_snapshot.py"):
            p = os.path.join(root, rel)
            if os.path.islink(p) or not os.path.isfile(p):
                return False
        res = _load_crs()._git(root, ["rev-list", "--max-parents=0", "HEAD"], _t(end))
        if res is None or res.returncode != 0:
            return False
        return CAST_ROOT_COMMIT in res.stdout.split()
    except Exception:
        return False


# ---------------------------------------------------------------------------------- core

def _bad_path(path: str) -> bool:
    return (not path or os.path.isabs(path) or ".." in path.split("/") or "\x00" in path)


def classify(crs, root: str, staged: List[Tuple[str, str, str, str]],
             unstaged: Optional[Set[str]], store: Store, end: float, home: str):
    """-> list of (path, category, reason) in staged order.

    PRECEDENCE (one unconditional rule): (a) bad-path/budget -> (b) BLOCK sources (file row,
    repo-wide row, unrecorded marker; markers are filesystem-only so they hold with the DB down;
    a gitlink has no blob, so for it only the repo-wide sources apply, else unreviewed 'gitlink')
    -> (c) derived -> (d) DB unavailable => unreviewed -> (e) index/worktree/type checks + approval.
    Derived never returns before (b).
    """
    cast_cache = []  # type: List[bool]

    def cast_repo() -> bool:  # lazy: the git spawn is only paid when a derived-shaped path is staged
        if not cast_cache:
            cast_cache.append(is_cast_repo(root, end))
        return cast_cache[0]

    verdicts = {}  # type: Dict[int, Tuple[str, str]]
    pending = []  # type: List[int]
    repo_block = None  # type: Optional[bool]
    for idx, (status, path, mode, sblob) in enumerate(staged):
        if _bad_path(path) and status != "G":
            verdicts[idx] = ("unreviewed", "bad-path")
            continue
        if time.monotonic() >= end:
            verdicts[idx] = ("unreviewed", "budget")
            continue
        if status == "G":
            # a gitlink has no blob to bind: only the repo-wide BLOCK sources apply to it
            if repo_block is None:
                repo_block = repo_wide_blocked(store, root, home)
            verdicts[idx] = ("blocked", "repo-wide-block") if repo_block else ("unreviewed", sblob)
            continue
        key = crs.path_key(path)
        bound = crs.DELETED if status == "D" else sblob  # the content that would be committed
        if store.uncleared_block(root, key, bound):
            verdicts[idx] = ("blocked", "recorded-block")
            continue
        if repo_block is None:
            repo_block = repo_wide_blocked(store, root, home)
        if repo_block:
            verdicts[idx] = ("blocked", "repo-wide-block")
        elif (path.startswith("plugin/") or path == "cast-stats.json") and cast_repo():
            verdicts[idx] = ("derived", "generated-file")
        elif not store.ok:
            verdicts[idx] = ("unreviewed", "db-unavailable")
        elif unstaged is None:
            verdicts[idx] = ("unreviewed", "unstaged-unknown")
        elif status == "D":
            verdicts[idx] = _approval(store, root, key, crs.DELETED, None)
        elif path in unstaged:
            verdicts[idx] = ("unreviewed", "unstaged-changes")
        elif mode not in ("120000", "100644", "100755"):
            verdicts[idx] = ("unreviewed", "unsupported-mode")
        else:
            pending.append(idx)
    blobs = hash_worktree(crs, root, [staged[i][1] for i in pending], end) if pending else {}
    for idx in pending:
        _status, path, mode, sblob = staged[idx]
        kind, blob, why = blobs.get(path, (None, None, "unreadable-or-timeout"))
        if blob is None:
            verdicts[idx] = ("unreviewed", why or "unreadable-or-timeout")
        elif kind != ("link" if mode == "120000" else "file"):
            verdicts[idx] = ("unreviewed", "type-mismatch")
        elif blob != sblob:
            verdicts[idx] = ("unreviewed", "index-worktree-mismatch")
        else:
            verdicts[idx] = _approval(store, root, crs.path_key(path), blob, mode)
    return [(staged[i][1], verdicts[i][0], verdicts[i][1]) for i in range(len(staged))]


def _approval(store: Store, root: str, key: str, blob: str, mode: Optional[str]) -> Tuple[str, str]:
    """mode=None (staged deletion) skips the mode check; otherwise the APPROVE row's recorded mode
    must equal the staged index mode (NULL never matches)."""
    if store.has_file_row(root, key, blob, "APPROVE", "code-reviewer", mode):
        return ("approved", "code-reviewer-approve")
    return ("unreviewed", "db-error" if not store.ok else "no-approval")


def record_hatch(value: str) -> None:
    """Audit the CAST_UNREVIEWED_OK use via cast_ack.py. Best-effort, never raises.

    cast_ack.py's CLI parser takes `--value` and its argument as TWO argv tokens (taken verbatim,
    even if it starts with '-'); `--value=x` is silently dropped. The child env must not carry
    CAST_UNREVIEWED_OK so the recorded value is the one passed on argv.
    """
    try:
        env = {k: v for k, v in os.environ.items() if k != "CAST_UNREVIEWED_OK"}
        subprocess.run(
            # sys._base_executable, not sys.executable: PYTHONEXECUTABLE overrides the latter even under -I
            [sys._base_executable, "-I", os.path.join(_SCRIPTS_DIR, "cast_ack.py"),
             "CAST_UNREVIEWED_OK", "--script", SCRIPT_NAME, "--value", value[:500]],
            timeout=3, capture_output=True, env=env,
        )
    except Exception:
        pass


def build_reasons(results: List[Tuple[str, str, str]]) -> str:
    order = {"blocked": 0, "unreviewed": 1, "hatched": 2, "derived": 3}
    items = [r for r in results if r[1] != "approved"]
    items.sort(key=lambda r: order.get(r[1], 9))
    out = []  # type: list
    for path, cat, reason in items[:MAX_REASONS]:
        out.append({"path": _display(path, 200), "category": cat, "reason": reason})
    while out and len(json.dumps(out)) > MAX_REASONS_BYTES:
        out.pop()
    return json.dumps(out)


def write_row(db_path: str, row: dict, timeout: float = DB_TIMEOUT_S,
              mode: str = "warn", source: str = "cli") -> bool:
    """INSERT one review_gate_decisions row. mode=rw never creates a missing DB."""
    conn = None
    try:
        uri = "file:" + urllib.parse.quote(os.path.abspath(db_path)) + "?mode=rw"
        conn = sqlite3.connect(uri, uri=True, timeout=timeout)
        conn.execute(f"PRAGMA busy_timeout={int(timeout * 1000)}")
        with conn:
            conn.execute(
                "INSERT INTO review_gate_decisions (session_id, repo_root, mode, would_block, n_staged, n_approved, n_unreviewed, n_blocked, n_derived, n_hatched, reasons, source) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                (row["session_id"], row["repo_root"], mode, row["would_block"], row["n_staged"],
                 row["n_approved"], row["n_unreviewed"], row["n_blocked"], row["n_derived"],
                 row["n_hatched"], row["reasons"], source),
            )
        return True
    except sqlite3.Error as exc:
        _log_error(f"decision row not written: {type(exc).__name__}: {exc}")
        return False
    finally:
        if conn is not None:
            try:
                conn.close()
            except sqlite3.Error:
                pass


_CATS = ("approved", "unreviewed", "blocked", "derived", "hatched")


def evaluate(root: str, *, db_path: str, home: str, hatch: str, budget_s: float,
             audit_hatch: bool = True) -> dict:
    """In-process library entry. Never raises.

    -> {results: [(path, category, reason)], counts, would_block (0/1), db_ok, error, root, staged}
    error is None or one of "not-a-repo", "diff-failed", "budget", "db-unavailable",
    "exception:<Name>". `hatch` (non-empty) turns "unreviewed" into "hatched" (never "blocked")
    and is audited via record_hatch(). Staged paths are categorised even when the DB fails.

    audit_hatch=False skips the record_hatch() ack spawn (up to 3 s) for callers under a tight hook
    timeout; the unreviewed -> hatched conversion still happens and the caller records the hatch.

    CONTRACT: error is not None and error != "not-a-repo"  =>  would_block == 1 (fail closed; a
    caller that cannot trust the evaluation must treat it as would-block). On an exception after
    classification the partial (pre-hatch) results are kept and would_block is forced to 1.
    """
    out = {"results": [], "counts": {c: 0 for c in _CATS}, "would_block": 0, "db_ok": False,
           "error": None, "root": root, "staged": False}  # type: dict
    store = None
    try:
        end = time.monotonic() + budget_s
        crs = _load_crs()
        top = crs._git(root, ["rev-parse", "--show-toplevel"], _t(end))
        if top is None or top.returncode != 0 or not top.stdout.strip("\n"):
            out["error"] = "not-a-repo"
            return out
        root = os.path.realpath(top.stdout.strip("\n"))
        out["root"] = root
        staged = staged_entries(crs, root, _t(end))
        if staged is None:
            _log_error("git diff --cached failed")
            out["error"] = "diff-failed"
            return out
        staged = staged + gitlink_entries(crs, root, {e[1] for e in staged}, end)
        if not staged:
            return out
        out["staged"] = True
        unstaged = unstaged_set(crs, root, _t(end))
        store = Store(db_path, min(DB_TIMEOUT_S, max(0.1, end - time.monotonic())))
        results = classify(crs, root, staged, unstaged, store, end, home)
        out["db_ok"] = store.ok
        counts = {c: 0 for c in _CATS}
        for _, cat, _ in results:
            counts[cat] += 1
        out.update(results=results, counts=counts,
                   would_block=1 if (counts["unreviewed"] or counts["blocked"]) else 0)
        if any(r == "budget" for _, _, r in results):
            out["error"] = "budget"
        elif not store.ok:
            out["error"] = "db-unavailable"
        if hatch:
            hatched = [(p, "hatched", r) if c == "unreviewed" else (p, c, r) for p, c, r in results]
            if audit_hatch and any(c == "hatched" for _, c, _ in hatched):
                record_hatch(hatch)  # may raise: partial pre-hatch results + would_block=1 stand
            hcounts = {c: 0 for c in _CATS}
            for _, cat, _ in hatched:
                hcounts[cat] += 1
            out.update(results=hatched, counts=hcounts,
                       would_block=1 if (hcounts["unreviewed"] or hcounts["blocked"]) else 0)
    except Exception as exc:
        _log_error(f"evaluate {type(exc).__name__}: {exc}")
        out["error"] = f"exception:{type(exc).__name__}"
    finally:
        if store is not None:
            store.close()
        if out["error"] is not None and out["error"] != "not-a-repo":
            out["would_block"] = 1
    return out


def run() -> None:
    end = time.monotonic() + BUDGET_S
    crs = _load_crs()
    db_path = crs.default_db_path()
    ev = evaluate(os.getcwd(), db_path=db_path, home=os.path.expanduser("~"),
                  hatch=os.environ.get("CAST_UNREVIEWED_OK", ""), budget_s=BUDGET_S)
    err = ev["error"]
    if err == "not-a-repo":
        _emit("review-gate: skipped (not a git repo)")
        return
    if err == "diff-failed":
        _emit("review-gate: error (git diff --cached failed)")
        return
    if err is not None and err.startswith("exception:"):
        _emit(f"review-gate: error ({err[len('exception:'):]})")
        return
    if not ev["staged"]:
        _emit("review-gate: nothing staged")
        return
    results, counts, db_ok, root = ev["results"], ev["counts"], ev["db_ok"], ev["root"]
    would_block = ev["would_block"]  # fail-closed: forced to 1 on any evaluate() error

    sid = os.environ.get("CLAUDE_SESSION_ID") or os.environ.get("CAST_SESSION_ID") or None
    row_ok = write_row(db_path, {
        "session_id": sid, "repo_root": root, "would_block": would_block,
        "n_staged": len(results), "n_approved": counts["approved"],
        "n_unreviewed": counts["unreviewed"], "n_blocked": counts["blocked"],
        "n_derived": counts["derived"], "n_hatched": counts["hatched"],
        "reasons": build_reasons(results),
    }, min(DB_TIMEOUT_S, max(0.1, end - time.monotonic())), source="cli") if db_ok else False

    summary = " ".join(f"{k}={counts[k]}" for k in _CATS)
    if would_block:
        line = f"review-gate WARN (not enforced): would block — {summary}"
        # no blocked/unreviewed path exists when a hatch masked everything under an error
        first = next((r for r in results if r[1] == "blocked"), None) or \
            next((r for r in results if r[1] == "unreviewed"), None)
        if first is not None:
            line += f"; first: {_display(first[0])} ({first[2]})"
    else:
        line = f"review-gate OK: {summary}"
    if err is not None:
        line += f"; error={err}"
    if not db_ok:
        line += "; db unavailable, decision row not recorded"
    elif not row_ok:
        line += "; decision row not recorded"
    _emit(line)


def main() -> int:
    try:
        run()
    except Exception as exc:  # never crash the commit path
        name = type(exc).__name__
        _log_error(f"unhandled {name}: {exc}")
        _emit(f"review-gate: error ({name})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
