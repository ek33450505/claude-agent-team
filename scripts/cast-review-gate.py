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
  derived     CAST repo only: under plugin/ or == cast-stats.json (generated, not reviewable)
  blocked     a file-scoped BLOCKED row (any reviewer) binds this exact (path, blob); or a
              repo-wide block (scope='repo' row / review-unrecorded marker under this repo)
              not cleared by a LATER file-scoped review
  approved    a code-reviewer APPROVE binds this exact (path, blob). Security APPROVE never counts.
  hatched     would be unreviewed, but CAST_UNREVIEWED_OK is set (never turns blocked -> hatched)
  unreviewed  everything else, including: unstaged changes on the path, unreadable file, DB
              unavailable (fail closed in the CATEGORY; the exit code is still 0)

Trust/robustness: git is reached only through cast_git_safe (via cast_review_snapshot._git); the
DB is read with mode=ro and written with mode=rw (a missing DB is never created); markers are
read-only (never deleted); the whole run is bounded (~20 s) and wrapped so it cannot crash.

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
SCRIPT_NAME = "cast-review-gate.py"

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
                     reviewer: Optional[str] = None) -> bool:
        """Any file-scoped row of `decision` (optionally by `reviewer`) binding (key, blob)?"""
        if not self.ok or self._conn is None:
            return False
        sql = ("SELECT 1 FROM review_snapshots s JOIN review_snapshot_files f ON f.snapshot_id = s.id "
               "WHERE s.decision = ? AND s.scope = 'files' AND s.repo_root = ? AND f.path = ? AND f.blob = ?")
        params = [decision, repo_root, key, blob]  # type: list
        if reviewer is not None:
            sql += " AND s.reviewer = ?"
            params.append(reviewer)
        try:
            return self._conn.execute(sql + " LIMIT 1", params).fetchone() is not None
        except sqlite3.Error as exc:
            self._fail(exc)
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


def read_markers(repo_root: str) -> List[Optional[str]]:
    """ts of every valid review-unrecorded marker at/under repo_root (None = unparseable ts)."""
    base = os.path.join(os.path.expanduser("~"), ".claude", "cast-state", "review-unrecorded")
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


def repo_wide_blocked(store: Store, repo_root: str) -> bool:
    """True iff a scope='repo' BLOCK row or unrecorded marker is not cleared by a LATER review."""
    degraded = store.degraded_block_ended_ats(repo_root)
    if degraded is None:
        degraded = []
    items = list(degraded) + read_markers(repo_root)
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


def is_cast_repo(root: str) -> bool:
    # NOTE: identity here is file presence only -- a repo that plants these two files is treated
    # as the CAST repo. A stronger identity (U4) is deliberately out of scope for this unit; the
    # exemption is also applied AFTER block checks, so it can never override a recorded BLOCK.
    for rel in ("agents/core/commit.md", "scripts/cast_review_snapshot.py"):
        p = os.path.join(root, rel)
        if os.path.islink(p) or not os.path.isfile(p):
            return False
    return True


# ---------------------------------------------------------------------------------- core

def _bad_path(path: str) -> bool:
    return (not path or os.path.isabs(path) or ".." in path.split("/") or "\x00" in path)


def classify(crs, root: str, staged: List[Tuple[str, str, str, str]],
             unstaged: Optional[Set[str]], store: Store, end: float):
    """-> list of (path, category, reason) in staged order.

    PRECEDENCE (one unconditional rule): (a) bad-path/budget -> (b) BLOCK sources (file row,
    repo-wide row, unrecorded marker; markers are filesystem-only so they hold with the DB down;
    a gitlink has no blob, so for it only the repo-wide sources apply, else unreviewed 'gitlink')
    -> (c) derived -> (d) DB unavailable => unreviewed -> (e) index/worktree/type checks + approval.
    Derived never returns before (b).
    """
    cast_repo = is_cast_repo(root)
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
                repo_block = repo_wide_blocked(store, root)
            verdicts[idx] = ("blocked", "repo-wide-block") if repo_block else ("unreviewed", sblob)
            continue
        key = crs.path_key(path)
        bound = crs.DELETED if status == "D" else sblob  # the content that would be committed
        if store.has_file_row(root, key, bound, "BLOCKED"):
            verdicts[idx] = ("blocked", "recorded-block")
            continue
        if repo_block is None:
            repo_block = repo_wide_blocked(store, root)
        if repo_block:
            verdicts[idx] = ("blocked", "repo-wide-block")
        elif cast_repo and (path.startswith("plugin/") or path == "cast-stats.json"):
            verdicts[idx] = ("derived", "generated-file")
        elif not store.ok:
            verdicts[idx] = ("unreviewed", "db-unavailable")
        elif unstaged is None:
            verdicts[idx] = ("unreviewed", "unstaged-unknown")
        elif status == "D":
            verdicts[idx] = _approval(store, root, key, crs.DELETED)
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
            verdicts[idx] = _approval(store, root, crs.path_key(path), blob)
    return [(staged[i][1], verdicts[i][0], verdicts[i][1]) for i in range(len(staged))]


def _approval(store: Store, root: str, key: str, blob: str) -> Tuple[str, str]:
    if store.has_file_row(root, key, blob, "APPROVE", "code-reviewer"):
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


def write_row(db_path: str, row: dict, timeout: float = DB_TIMEOUT_S) -> bool:
    """INSERT one review_gate_decisions row. mode=rw never creates a missing DB."""
    conn = None
    try:
        uri = "file:" + urllib.parse.quote(os.path.abspath(db_path)) + "?mode=rw"
        conn = sqlite3.connect(uri, uri=True, timeout=timeout)
        conn.execute(f"PRAGMA busy_timeout={int(timeout * 1000)}")
        with conn:
            conn.execute(
                "INSERT INTO review_gate_decisions (session_id, repo_root, mode, would_block, n_staged, n_approved, n_unreviewed, n_blocked, n_derived, n_hatched, reasons) VALUES (?, ?, 'warn', ?, ?, ?, ?, ?, ?, ?, ?)",
                (row["session_id"], row["repo_root"], row["would_block"], row["n_staged"],
                 row["n_approved"], row["n_unreviewed"], row["n_blocked"], row["n_derived"],
                 row["n_hatched"], row["reasons"]),
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


def run() -> None:
    end = time.monotonic() + BUDGET_S
    crs = _load_crs()
    cwd = os.getcwd()
    top = crs._git(cwd, ["rev-parse", "--show-toplevel"], _t(end))
    if top is None or top.returncode != 0 or not top.stdout.strip("\n"):
        _emit("review-gate: skipped (not a git repo)")
        return
    root = os.path.realpath(top.stdout.strip("\n"))

    staged = staged_entries(crs, root, _t(end))
    if staged is None:
        _log_error("git diff --cached failed")
        _emit("review-gate: error (git diff --cached failed)")
        return
    staged = staged + gitlink_entries(crs, root, {e[1] for e in staged}, end)
    if not staged:
        _emit("review-gate: nothing staged")
        return
    unstaged = unstaged_set(crs, root, _t(end))

    db_path = crs.default_db_path()
    store = Store(db_path, min(DB_TIMEOUT_S, max(0.1, end - time.monotonic())))
    try:
        results = classify(crs, root, staged, unstaged, store, end)
        db_ok = store.ok
    finally:
        store.close()

    hatch = os.environ.get("CAST_UNREVIEWED_OK", "")
    if hatch:
        results = [(p, "hatched", r) if c == "unreviewed" else (p, c, r) for p, c, r in results]
        if any(c == "hatched" for _, c, _ in results):
            record_hatch(hatch)

    counts = {c: 0 for c in ("approved", "unreviewed", "blocked", "derived", "hatched")}
    for _, cat, _ in results:
        counts[cat] += 1
    would_block = 1 if (counts["unreviewed"] or counts["blocked"]) else 0

    sid = os.environ.get("CLAUDE_SESSION_ID") or os.environ.get("CAST_SESSION_ID") or None
    row_ok = write_row(db_path, {
        "session_id": sid, "repo_root": root, "would_block": would_block,
        "n_staged": len(results), "n_approved": counts["approved"],
        "n_unreviewed": counts["unreviewed"], "n_blocked": counts["blocked"],
        "n_derived": counts["derived"], "n_hatched": counts["hatched"],
        "reasons": build_reasons(results),
    }, min(DB_TIMEOUT_S, max(0.1, end - time.monotonic()))) if db_ok else False

    summary = " ".join(f"{k}={counts[k]}" for k in ("approved", "unreviewed", "blocked", "derived", "hatched"))
    if would_block:
        first = next(r for r in results if r[1] == "blocked") if counts["blocked"] else \
            next(r for r in results if r[1] == "unreviewed")
        line = (f"review-gate WARN (not enforced): would block — {summary}; "
                f"first: {_display(first[0])} ({first[2]})")
    else:
        line = f"review-gate OK: {summary}"
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
