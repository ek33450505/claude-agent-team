#!/usr/bin/env python3
"""
cast-egress-sentinel.py — CAST v9 A1 Egress Audit Record (log-only).

A PreToolUse classifier that RECORDS every off-machine-bound tool call to a
local egress ledger (logs/egress.jsonl) — the record-deepening / data-sovereignty
thesis. It is ADVISORY and LOG-ONLY: it never blocks and never asks. For hard
access control use native permissions.deny (WebFetch(domain:...), mcp__<server>)
and the OS sandbox (Bash network/filesystem) — those enforce for all subprocesses.
This sentinel's net-new value is the local, inspectable audit record of WHAT
leaves the machine across surfaces native rules don't record together:

  Surfaces recorded (egress scope "mcp__.*|WebFetch|WebSearch|Bash|Read" — the
  dispatcher's _EGRESS_TOOLS; classification data is the INSTALLED
  ~/.claude/config/egress-policy.json):
    1. Cloud-bound MCP calls   (mcp__<server>__<tool>, classified per-server; a
                                server in neither list follows
                                mcp_servers._default_unknown)
    2. WebFetch / WebSearch    (WebFetch: scheme/host/port/path only — userinfo,
                                query and fragment dropped, the query kept only
                                as a 12-hex fingerprint; WebSearch: surface only,
                                the search terms are never carried)
    3. Bash network egress     (curl/wget/scp/rsync/ssh/nc/... matched as bare
                                command words by cast-command-guard.py's
                                shell-aware tokenizer; loopback-only targets are
                                not recorded)
    4. Credential reads        (Read of a path matching the policy's
                                credential_path_globs — .env, ~/.ssh/id_*, *.pem,
                                ... — for local correlation)

DESIGN BOUNDARY (local-first thesis):
  Native Claude Code permissions.deny handles COARSE access control; the OS
  sandbox is the real Bash-egress / filesystem boundary. This sentinel does NOT
  enforce — it is the local record those layers don't keep. PreToolUse hooks are
  also bypassed in headless/cron runs, so it could never be a hard guarantee.
  See docs/v9-a1-egress-sentinel.md.

CONTRACT (main(), the standalone entry point):
  stdin  — raw PreToolUse hook JSON (tool_name, tool_input, session_id, cwd...)
  stdout — PreToolUse hookSpecificOutput JSON (additionalContext advisory), only
           for a severity "warn" verdict (credential read, bash network command,
           unknown MCP server) or when the policy is missing/invalid (that notice
           once per session); "info" calls are recorded silently. Every value
           interpolated from the tool input is sanitized (_clean) first.
  exit 0 — always. *** FAIL-OPEN: any internal error -> exit 0, log to
           hook-errors.log, never interrupt the user's work. ***

In production the registered PreToolUse hook is scripts/cast-pretool-dispatch.py,
which imports this module and runs the same evaluate() / emit_advisory() per call,
so the two paths cannot drift.

The coarse Bash name-matcher and the info/warn severity labels are awareness
aids for the advisory line, NOT an enforcement decision — there is no block path.
"""
from __future__ import annotations

import sys
import os
import json
import fnmatch
import hashlib
import ipaddress
import re
import unicodedata
from datetime import datetime, timezone

# --------------------------------------------------------------------------
# Paths / constants
# --------------------------------------------------------------------------
HOME = os.path.expanduser("~")
CLAUDE_DIR = os.environ.get("CLAUDE_DIR", os.path.join(HOME, ".claude"))
EGRESS_LOG = os.path.join(CLAUDE_DIR, "logs", "egress.jsonl")
ERROR_LOG = os.path.join(CLAUDE_DIR, "logs", "hook-errors.log")
# Policy data: cwd is agent-writable, so only the installed copy is trusted; repo edits take effect after install.sh.
_POLICY_CANDIDATES = [
    os.path.join(CLAUDE_DIR, "config", "egress-policy.json"),
]


# --------------------------------------------------------------------------
# Infra (never raises)
# --------------------------------------------------------------------------
def _log_error(msg: str) -> None:
    try:
        os.makedirs(os.path.dirname(ERROR_LOG), exist_ok=True)
        ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        with open(ERROR_LOG, "a") as f:
            f.write(f"[{ts}] ERROR cast-egress-sentinel.py: {msg}\n")
    except Exception:
        pass


def _now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


# Shape of the policy keys classify() and _resolve_unknown_is_cloud_bound() read.
# Every section config/egress-policy.json defines is REQUIRED (a missing one is a
# shape error). Per section: (lists that must be present AND non-empty, lists that
# may be absent or empty). An absent/empty `commands` or `globs` list silently
# disables the whole Bash / credential-Read surface, so those two may not be empty;
# an empty mcp_servers list or `hosts` only makes classification noisier, never
# quieter, so those stay optional (fixtures and operators legitimately leave them []).
_POLICY_SHAPE = {
    "mcp_servers": ((), ("cloud_bound", "local_only", "anthropic_brokered")),
    "credential_path_globs": (("globs",), ()),
    "bash_network_commands": (("commands",), ()),
    "safelist_hosts": ((), ("hosts",)),
}
_ABSENT = object()


def _str_list_error(section: str, field: str, value) -> str | None:
    if not isinstance(value, list):
        return f"'{section}.{field}' is not a list"
    if not all(isinstance(x, str) for x in value):
        return f"'{section}.{field}' holds a non-string entry"
    return None


def _policy_shape_error(policy) -> str | None:
    """Return a reason string if `policy` has a shape classify() would raise on
    (or silently under-classify with), else None. Validates exactly the keys
    classify() / _resolve_unknown_is_cloud_bound() read. Reasons name structure
    only, never policy values. Never raises: an unexpected failure is itself
    reported as a shape error (fail-safe)."""
    try:
        if not isinstance(policy, dict):
            return "top level is not an object"
        for section, (required_lists, optional_lists) in _POLICY_SHAPE.items():
            if section not in policy:
                return f"missing required section '{section}'"
            sec = policy[section]
            if not isinstance(sec, dict):
                return f"'{section}' is not an object"
            for field in required_lists:
                value = sec.get(field, _ABSENT)
                if value is _ABSENT:
                    return f"'{section}.{field}' is missing"
                err = _str_list_error(section, field, value)
                if err:
                    return err
                if not value:
                    return f"'{section}.{field}' is empty"
            for field in optional_lists:
                value = sec.get(field, _ABSENT)
                if value is _ABSENT:
                    continue
                err = _str_list_error(section, field, value)
                if err:
                    return err
        default_unknown = policy["mcp_servers"].get("_default_unknown", _ABSENT)
        if default_unknown is not _ABSENT and not isinstance(default_unknown, str):
            return "'mcp_servers._default_unknown' is not a string"
        return None
    except Exception as e:
        return f"shape check failed: {type(e).__name__}"


def _load_policy() -> dict:
    """Load the installed egress policy. Returns {} (never raises) when the file
    is missing, unparseable, or has a shape _policy_shape_error() rejects; the
    reason is logged to hook-errors.log as `policy load failed (<path>): <why>`.
    An empty policy is the fail-safe path: MCP/WebFetch still record, and
    evaluate() adds an advisory so the un-classified Bash/Read surfaces are
    never silent."""
    for path in _POLICY_CANDIDATES:
        try:
            if not os.path.isfile(path):
                _log_error(f"policy load failed ({path}): file not found")
                continue
            with open(path) as f:
                policy = json.load(f)
            err = _policy_shape_error(policy)
            if err is None:
                return policy
            _log_error(f"policy load failed ({path}): {err}")
        except Exception as e:
            _log_error(f"policy load failed ({path}): {e}")
    return {}


def _expand(path: str) -> str:
    return os.path.expanduser(os.path.expandvars(path or ""))


_WHATWG_SPECIAL_SCHEMES = frozenset({"http", "https", "ws", "wss", "ftp"})
_C0_AND_SPACE = "".join(chr(i) for i in range(0x21))
_SCHEME_RE = re.compile(r"^([A-Za-z][A-Za-z0-9+.\-]*):")


def _whatwg_normalize(url) -> str:
    """Parse-only copy of `url` approximating how the WHATWG URL parser (what the
    fetch actually uses) reads a special-scheme URL, so Python's stricter RFC 3986
    urlsplit sees the SAME host the fetch will contact. Without this, a backslash
    disguises the host (`https://evil.example\\@github.com/` -> urlsplit says
    github.com, WHATWG fetches evil.example) and `https:\\\\host/`, `https:/host/`,
    `http:host/` parse hostless. Steps: strip leading/trailing C0 controls + space;
    drop ASCII tab/LF/CR anywhere; for http/https/ws/wss/ftp only, turn `\\` into `/`
    before the first `?`/`#` and rewrite `scheme:` + any run of slashes to
    `scheme://`. Non-special schemes are returned unchanged. Never raises."""
    try:
        s = str(url or "").strip(_C0_AND_SPACE)
        s = s.replace("\t", "").replace("\n", "").replace("\r", "")
        m = _SCHEME_RE.match(s)
        if not m or m.group(1).lower() not in _WHATWG_SPECIAL_SCHEMES:
            return s
        rest = s[m.end():]
        cut = min((i for i in (rest.find("?"), rest.find("#")) if i >= 0), default=len(rest))
        rest = rest[:cut].replace("\\", "/") + rest[cut:]
        return f"{m.group(1)}://{rest.lstrip('/')}"
    except Exception:
        return str(url or "")


def _fingerprint(text) -> str:
    """12-hex sha256 prefix. `surrogatepass`: a lone surrogate (agent-steerable via a
    URL) must not make the encode raise and cost the caller its ledger row."""
    return hashlib.sha256(str(text).encode("utf-8", "surrogatepass")).hexdigest()[:12]


# Host canonicalization (WHATWG host parsing = percent-decode, then UTS46 mapping).
# `.` look-alikes map to '.', UTS46-ignored code points are dropped.
_HOST_XLATE = {
    **dict.fromkeys((0x3002, 0xFF0E, 0xFF61), "."),
    **dict.fromkeys((0x00AD, 0x200B, 0x2060, 0xFEFF, 0x034F,
                     *range(0x180B, 0x180E), *range(0xFE00, 0xFE10))),
}
# NO '%': after the percent-decode a '%' is a WHATWG forbidden host code point.
_HOST_NAME_OK = frozenset(
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_~!$&'()*+,;=")
# Non-ASCII categories that make a host malformed: controls, surrogates, separators
# (incl. NBSP, U+3000, U+2028/2029). Every OTHER non-ASCII code point is recorded as-is.
_HOST_FATAL_CATS = frozenset({"Cc", "Cs", "Zs", "Zl", "Zp"})
_HOST_V6_RE = re.compile(r"[0-9A-Fa-f:.]+(?:%[A-Za-z0-9._~%\-]+)?")
_HOSTINFO_V6_RE = re.compile(r"\[[^\[\]]+\](?::([0-9]*))?")
_PORT_RE = re.compile(r"0*[0-9]{1,5}")


def _canonical_name(host: str):
    """Canonical form of a registered-name host, or None when it is malformed.
    Percent-decode (strict UTF-8) -> map U+3002/U+FF0E/U+FF61 to '.' and drop the
    UTS46-ignored code points (U+00AD, U+200B, U+2060, U+FEFF, U+034F, U+180B-180D,
    U+FE00-FE0F) -> lowercase, as WHATWG does, so `evil\u3002example` IS evil.example
    and `git\u00adhub.com` IS github.com. This does NOT try to keep pace with the rest
    of UTS46 (circled letters, U+180E/U+2062, IDN-valid punctuation ...): the fetch
    contacts those hosts, so refusing them would hide the destination. WHAT IS FATAL
    is deliberately narrow: an empty host; any ASCII char outside
    `A-Za-z0-9.-_~!$&'()*+,;=` (a decoded `% / @ \\ [ ] : ? # < > ^ |`, controls, space
    — the credential/userinfo smuggling class); any non-ASCII char of category Cc, Cs,
    Zs, Zl or Zp (NBSP, U+3000, U+2028/2029); invalid UTF-8. Every other non-ASCII
    code point is accepted and recorded as-is (the ledger json-escapes it). Safelist
    matching compares this text exactly / by suffix, so an exotic char never matches
    an ASCII entry (a safe-direction miss, e.g. `githu\u180eb.com` is not github.com)."""
    try:
        from urllib.parse import unquote_to_bytes
        text = unquote_to_bytes(host).decode("utf-8").translate(_HOST_XLATE).lower()
    except (UnicodeError, ValueError):
        return None
    if text and all((c in _HOST_NAME_OK) if ord(c) < 128
                    else unicodedata.category(c) not in _HOST_FATAL_CATS
                    for c in text):
        return text
    return None


def _canonical_authority(p):
    """(host, port) for a urlsplit result, canonicalized to the host the fetch will
    really contact, or None when the authority is not one it could contact (the caller
    then records no url / never safelists). `host` is lowercased and unbracketed;
    `port` is an int or None. `https: //UID:PWD[at]evil.example/p` normalizes to netloc ' '
    and `hostname` ' ' (truthy) with `UID:PWD[at]evil.example/p` left in the PATH; a bare
    truthiness test let that through and persisted the credentials. ([at] is the at-sign,
    spelled out so the PII scan does not read the example as an email address.)
    Bracketed IPv6 (hostname has ':'): hex digits, ':' and '.', an optional %zone, and
    the netloc host part must really be `[...]` (+ optional `:port`) — urlsplit also
    reads `evil[::1]` (balanced brackets) as host `::1`, dropping the text before the
    '['. Otherwise _canonical_name; a '[' / ']' anywhere in a non-bracketed host part
    is malformed. The port text must be ASCII digits only and <= 65535 (empty = none):
    Python 3.9's int() accepts `+80`, ` 80`, `8_0` and non-ASCII digits, which the
    WHATWG parser rejects. Never raises."""
    host = p.hostname
    if not host:
        return None
    hostinfo = p.netloc.rpartition("@")[2]
    if ":" in host:
        m = _HOSTINFO_V6_RE.fullmatch(hostinfo)
        if m is None or _HOST_V6_RE.fullmatch(host) is None:
            return None
        port_text = m.group(1) or ""
    else:
        if "[" in hostinfo or "]" in hostinfo:
            return None
        host = _canonical_name(host)
        if host is None:
            return None
        port_text = hostinfo.partition(":")[2]
    if not port_text:
        return host, None
    if _PORT_RE.fullmatch(port_text) is None or int(port_text) > 65535:
        return None
    return host, int(port_text)


def _safe_url(url: str) -> str:
    """Strip query string + fragment + userinfo before persisting — they carry
    secrets (OAuth access_token, pre-signed S3 signatures, API keys as query
    params, `https://user:pw@host/` credentials). Keep scheme, host (lowercased,
    IPv6 re-bracketed), port and path only; the query is fingerprinted separately.
    Parses _whatwg_normalize(url) (the host the fetch will really contact) and
    rebuilds from `hostname`/`port`, never `netloc`, so userinfo is dropped entirely
    (not even the username). Returns '' — the caller then stores `url_hash` instead —
    when the URL cannot be parsed confidently: urlsplit raises, the port is invalid
    (e.g. `https://user:pa/ss@host/` parses as host `user`, port `pa`, with the
    password tail in the path), or there is no host and the path holds an '@' (may
    be unparsed userinfo), or the authority fails _canonical_authority (malformed host
    or port, e.g. `https: //u:p@h/` parses as host ' ' with the credentials in the
    path). The host is recorded CANONICAL (`evil\u3002example` -> evil.example). A
    host with any non-ASCII char whose path holds an '@' is recorded with an EMPTY path:
    a non-fatal invisible filler (U+3164, U+115F, U+2063 ...) as the host of a
    WHATWG-rejected `https:\u3164//UID:PWD[at]evil.example/p` leaves the credentials in the
    path ([at] is the at-sign), and nothing after the visible destination is worth that
    risk. ASCII hosts
    keep their path (`@types/node`). Never raises."""
    try:
        from urllib.parse import urlsplit, urlunsplit
        p = urlsplit(_whatwg_normalize(url))
        if not p.hostname:
            return "" if "@" in p.path else urlunsplit((p.scheme, "", p.path, "", ""))
        auth = _canonical_authority(p)
        if auth is None:
            return ""
        host, port = auth
        if ":" in host:  # IPv6: hostname strips the brackets
            host = f"[{host}]"
        netloc = host if port is None else f"{host}:{port}"
        path = "" if "@" in p.path and not host.isascii() else p.path
        return urlunsplit((p.scheme, netloc, path, "", ""))
    except Exception:
        return ""


# Cache for the sibling shell tokenizer: None = not yet attempted, {} = attempted
# and unavailable (don't retry), populated dict = loaded callables.
_GUARD_TOKENIZER: dict | None = None


def _load_guard_tokenizer() -> dict:
    """Load the shell-aware segment tokenizer from the sibling cast-command-guard.py
    (issue #343). Reused rather than reimplemented so exfil-pipe detection shares the
    guard's quote/segment/heredoc-correct parser. Loaded via importlib because the
    sibling has a hyphenated filename; resolved relative to THIS file so it works both
    in-repo and installed. Returns {} on any failure — the caller falls back to a naive
    split, keeping the sentinel fail-open. Import-time safety: cast-command-guard.py has
    only module-level constants + defs (its main() is __name__-guarded), no side effects."""
    global _GUARD_TOKENIZER
    if _GUARD_TOKENIZER is not None:
        return _GUARD_TOKENIZER
    _GUARD_TOKENIZER = {}
    try:
        import importlib.util
        guard_path = os.path.join(
            os.path.dirname(os.path.abspath(__file__)), "cast-command-guard.py"
        )
        if not os.path.isfile(guard_path):
            return _GUARD_TOKENIZER
        spec = importlib.util.spec_from_file_location("cast_command_guard", guard_path)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        _GUARD_TOKENIZER = {
            "split_segments": mod.split_segments,
            "tokenize": mod.tokenize,
            "command_and_args": mod.command_and_args,
            "basename": mod.basename,
        }
    except Exception as e:
        _log_error(f"guard tokenizer load failed: {e}")
        _GUARD_TOKENIZER = {}
    return _GUARD_TOKENIZER


# --------------------------------------------------------------------------
# mcp_servers._default_unknown resolution — SINGLE reader of this key.
# scripts/cast-audit.py imports this function via importlib (see its
# _load_egress_sentinel_resolver()) rather than re-deriving the value, so
# the two classifiers can never disagree about what "unknown" means.
# --------------------------------------------------------------------------
def _resolve_unknown_is_cloud_bound(policy: dict) -> bool:
    """Resolve mcp_servers._default_unknown for a server that is in neither
    cloud_bound nor local_only.

    "local_only"  -> False (unknown treated as on-machine)
    "cloud_bound" -> True  (unknown treated as off-machine; this is the
                     current policy value, so today's observable behavior
                     is unchanged by this function existing)
    anything else (key missing, unrecognized value, policy not a dict,
    or any exception) -> True.

    FAIL-SAFE, non-negotiable: a missing key, a typo, or a malformed policy
    must never silently downgrade an unknown server to local. Only an
    explicit "local_only" value relaxes the default.
    """
    try:
        value = policy.get("mcp_servers", {}).get("_default_unknown")
        if value == "local_only":
            return False
        return True  # "cloud_bound", missing, or unrecognized -> fail safe
    except Exception:
        return True


# --------------------------------------------------------------------------
# Classification — returns an "egress event" dict or None if on-machine/safe
# --------------------------------------------------------------------------
def classify(tool_name: str, tool_input: dict, policy: dict) -> dict | None:
    """Return an egress-event dict {surface, ...} for off-machine-bound calls,
    or None when the call stays on the machine. Pure classification — no
    sensitivity scoring, no decision."""
    # --- Surface 1: MCP ----------------------------------------------------
    if tool_name.startswith("mcp__"):
        parts = tool_name.split("__")
        server = parts[1] if len(parts) >= 2 else ""
        mcp = policy.get("mcp_servers", {})
        if server in mcp.get("local_only", []):
            return None  # local vault / on-machine MCP
        cloud = server in mcp.get("cloud_bound", [])
        unknown = server not in mcp.get("cloud_bound", []) and server not in mcp.get("local_only", [])
        # mcp_servers._default_unknown decides how an unrecognized server is
        # treated; _resolve_unknown_is_cloud_bound() above is the single
        # reader of that key (fail-safe: defaults to cloud-bound).
        if cloud or (unknown and _resolve_unknown_is_cloud_bound(policy)):
            return {
                "surface": "mcp",
                "server": server,
                "anthropic_brokered": server in mcp.get("anthropic_brokered", []),
                "unknown_server": unknown,
            }
        return None

    # --- Surface 2: WebFetch / WebSearch ----------------------------------
    if tool_name == "WebFetch":
        url = tool_input.get("url", "") or ""
        return {"surface": "webfetch", "url": url,
                "safelisted": _host_safelisted(url, policy)}
    if tool_name == "WebSearch":
        # The search query is intentionally NOT carried in the event dict — it must
        # never reach the ledger (no-payload invariant). Record the surface only.
        return {"surface": "websearch"}

    # --- Surface 4: credential Read ---------------------------------------
    if tool_name == "Read":
        fp = tool_input.get("file_path") or tool_input.get("path") or ""
        if _is_credential_path(fp, policy):
            return {"surface": "credential_read", "file_path": fp,
                    "off_machine": False}  # a read is not itself egress; flag for correlation
        return None

    # --- Surface 3: Bash network egress -----------------------------------
    if tool_name == "Bash":
        cmd = tool_input.get("command", "") or ""
        net = _bash_network_hits(cmd, policy)
        if net:
            # Suppress loopback-only calls — they are on-machine by definition.
            # Fail-closed: if the target host can't be parsed confidently as
            # loopback, treat it as off-machine (record it).
            if _bash_all_targets_loopback(cmd):
                return None
            return {"surface": "bash", "commands": net,
                    "command_preview": cmd[:120].replace("\n", " ")}
        return None

    return None


def _is_ip_literal(h: str) -> bool:
    try:
        ipaddress.ip_address(h)
        return True
    except ValueError:
        return False


def _host_safelisted(url: str, policy: dict) -> bool:
    """True when the URL's parsed HOST is a safelist entry or a subdomain of one
    (`host == h or host.endswith('.' + h)`, case-insensitive, entries stripped).
    Matching the parsed hostname — not a substring of the whole URL — keeps
    `github.com` from matching `https://evil.com/github.com`, `evilgithub.com` or
    `https://github.com[at]evil.com/` ([at] is the at-sign). Empty / whitespace-only /
    non-string entries are
    skipped (an empty entry would match every host). The host comes from the same
    _whatwg_normalize() parse as _safe_url (a backslash can't disguise it), and a URL
    that does not parse confidently (invalid port, or an authority failing
    _canonical_authority) is never safelisted; the host compared is the CANONICAL one
    (`git\u00adhub.com` is github.com, `evil.example%2f.github.com` is malformed). An entry that is an IP literal (IPv4/IPv6, optionally
    bracketed) matches by EXACT host equality only — `evil.127.0.0.1` is not a
    subdomain of `127.0.0.1`; suffix matching is for DNS names. The result only sets
    the ledger's `safelisted` flag (assess_sensitivity never reads it). Never raises."""
    hosts = policy.get("safelist_hosts", {}).get("hosts", [])
    try:
        from urllib.parse import urlsplit
        auth = _canonical_authority(urlsplit(_whatwg_normalize(url)))
    except Exception:
        return False
    if auth is None:
        return False
    host = auth[0]
    for h in hosts:
        if not isinstance(h, str):
            continue
        h = h.strip().lower()
        if h.startswith("[") and h.endswith("]"):
            h = h[1:-1]
        if not h:
            continue
        if host == h:
            return True
        if not _is_ip_literal(h) and host.endswith("." + h):
            return True
    return False


def _is_credential_path(file_path: str, policy: dict) -> bool:
    if not file_path:
        return False
    target = _expand(file_path)
    for glob in policy.get("credential_path_globs", {}).get("globs", []):
        pat = _expand(glob)
        if fnmatch.fnmatch(target, pat) or fnmatch.fnmatch(file_path, glob):
            return True
    return False


def _parse_url_host(token: str) -> str:
    """Extract the host (no port) from a URL token or bare host:port string.
    Returns the lowercased host string, or '' on parse failure."""
    try:
        from urllib.parse import urlsplit
        t = token.strip("'\"`")
        if t.startswith("//") or "://" in t:
            parsed = urlsplit(t if "://" in t else "http:" + t)
            host = parsed.hostname or ""  # hostname strips port + lowercases
        elif t.startswith("["):
            # bare [::1] or [::1]:port
            bracket_end = t.find("]")
            host = t[1:bracket_end] if bracket_end > 0 else ""
        elif ":" in t and not t.startswith("-"):
            # bare host:port (no scheme). Guard against flag-like tokens.
            host = t.rsplit(":", 1)[0]
        else:
            host = t
        return host.lower()
    except Exception:
        return ""


# Exact loopback hosts — not substring checks.
# NOTE: 0.0.0.0 is intentionally excluded — it is the wildcard/all-interfaces
# bind address and IS network-reachable, not a true loopback. Fail-closed.
_LOOPBACK_HOSTS: frozenset = frozenset({"localhost", "::1", "[::1]"})


def _is_loopback_host(host: str) -> bool:
    """Return True iff 'host' (already lowercased, port-stripped) is a loopback
    address. Uses exact-set membership for names and prefix-check for the
    127.0.0.0/8 range. Does NOT do substring search — 'localhost.evil.com' is
    NOT loopback."""
    if not host:
        return False
    if host in _LOOPBACK_HOSTS:
        return True
    # 127.0.0.0/8: must be exactly four dot-separated octets starting with 127.
    parts = host.split(".")
    if len(parts) == 4 and parts[0] == "127":
        return all(p.isdigit() and 0 <= int(p) <= 255 for p in parts)
    return False


def _bash_extract_url_args(command: str) -> list[str]:
    """Pull tokens that look like URL or host:port arguments from a command.
    Conservative: only tokens that start with http/https/ftp scheme or contain
    '://', or bare host:port tokens that follow a network binary.  We also
    capture the token immediately after common URL-carrying flags (-H, -d, -o,
    --url, --output, --header are excluded; positional-arg tokens are captured).
    Returns a list of candidate host-bearing tokens."""
    skip_next = False
    skip_flags = {
        "-H", "--header", "-d", "--data", "--data-raw", "--data-binary",
        "-o", "--output", "-e", "--referer", "-u", "--user",
        "-F", "--form", "-X", "--request", "--cacert", "--cert",
    }
    tokens = command.replace("|", " ").replace("&", " ").replace(";", " ").split()
    url_args: list[str] = []
    for tok in tokens:
        if skip_next:
            skip_next = False
            continue
        if tok in skip_flags:
            skip_next = True
            continue
        if tok.startswith("-"):
            continue
        # Accept URLs with scheme or bare tokens containing a dot (domain-like)
        # or IPv6 brackets — but NOT short alphanumeric tokens (likely filenames).
        t = tok.strip("'\"`")
        if "://" in t or t.startswith("//"):
            url_args.append(t)
        elif t.startswith("[") and "]" in t:
            url_args.append(t)
    return url_args


def _bash_all_targets_loopback(command: str) -> bool:
    """Return True iff every URL/host argument in the command resolves to a
    loopback address. Returns False (fail-closed) when no URL arguments are
    found (we can't confirm the target is on-machine).

    SECURITY: DNS/connection-override flags (--resolve, --connect-to) can
    redirect a loopback URL to a remote IP at the network layer, making the
    parsed host meaningless. Fail-closed immediately on their presence."""
    # --resolve and --connect-to override DNS/connection routing — a curl that
    # looks like localhost may actually connect to an off-machine IP.
    if "--resolve" in command or "--connect-to" in command:
        return False
    args = _bash_extract_url_args(command)
    if not args:
        return False  # fail-closed: can't parse target, treat as off-machine
    return all(_is_loopback_host(_parse_url_host(a)) for a in args)


def _bash_network_hits(command: str, policy: dict) -> list:
    """Which network binaries a Bash command invokes as a bare word — as a command,
    a piped/backgrounded/substituted target, or an argument to a re-exec wrapper.
    Uses cast-command-guard.py's shell-aware segment tokenizer (issue #343): the
    command is split into segments (on unquoted | & ; ( ) { newline backtick) and
    each segment tokenized quote-correctly. Within a segment, leading VAR=
    assignments are dropped and the command word plus its argument tokens are
    matched against the network-binary allowlist.

    Scanning the arguments (not the command word alone) keeps recall for a network
    binary run behind a re-exec wrapper — `nohup curl …`, `env curl …`,
    `time/command/exec curl …`, `xargs curl`, `find . -exec curl …` — matching the
    old naive detector. But because `basename()` strips quotes, a network name
    that lives *inside a quoted string* stays one unmatched token, so a mention
    like `echo "run curl later"` is correctly NOT flagged — the false-positive
    suppression issue #343 asked for. Command substitution (`$(curl …)`, backticks)
    is caught: those are their own segments.

    KNOWN OUT-OF-SCOPE (documented, not silent — mirrors cast-command-guard.py's own
    evasion callouts): a network binary named *inside a quoted string that is itself
    re-executed* — `eval "curl …"`, `bash -c "curl …"`, `sh -c "…"` — is NOT
    detected, because that content stays a single opaque token; recording it would
    require recursively re-parsing the quoted argument as a command. Advisory-only
    tool, so this gap is a visible boundary, not an enforcement hole.

    Falls back to the pre-#343 naive whitespace/separator split when the tokenizer
    can't be loaded. AWARENESS ONLY — feeds the advisory record, no block path.
    Returns a sorted list of matched command basenames."""
    cmds = policy.get("bash_network_commands", {}).get("commands", [])
    if not cmds:
        return []
    toks: set = set()

    tk = _load_guard_tokenizer()
    if tk:
        try:
            for segment in tk["split_segments"](command):
                tokens = tk["tokenize"](segment)
                if not tokens:
                    continue
                # Drop leading VAR= assignments (so e.g. a PATH=/usr/bin/curl prefix
                # is not itself matched), then scan the command word AND its args.
                _assignments, cmd_word, args = tk["command_and_args"](tokens)
                scan = ([cmd_word] if cmd_word else []) + args
                for tok in scan:
                    base = tk["basename"](tok)
                    if base in cmds:
                        toks.add(base)
            return sorted(toks)
        except Exception as e:
            # Never let a parser edge case break the fail-open sentinel — fall
            # through to the naive split below.
            _log_error(f"tokenizer parse failed, using naive fallback: {e}")
            toks.clear()

    # Fallback (pre-#343 behavior): coarse name-match on a whitespace/separator
    # split. Broader (may false-positive on a network name used as an argument),
    # but never misses a real command-word hit.
    for raw in command.replace("|", " ").replace("&", " ").replace(";", " ").split():
        base = os.path.basename(raw.strip("'\"`"))
        if base in cmds:
            toks.add(base)
    return sorted(toks)


# --------------------------------------------------------------------------
# Sensitivity — awareness labels for the advisory line
# --------------------------------------------------------------------------
# Characters that must never reach the model-visible advisory (or a log viewer) raw:
# controls (Cc: newline, ESC), format incl. bidi overrides + zero-width (Cf), line/
# paragraph separators (Zl/Zp), surrogates (Cs) — the same set as
# scripts/cast-subagent-worktree-check.sh's _BAD_CATS — plus Cn (unassigned: U+2065,
# U+FFF0-FFF8, U+E0000-E0FFF ... are default-ignorable, i.e. invisible padding).
_BAD_CATS = frozenset({"Cc", "Cf", "Zl", "Zp", "Cs", "Cn"})
_REASON_VALUE_CAP = 200


def _clean(value, cap: int = _REASON_VALUE_CAP) -> str:
    """Printable single-line form of an agent-controlled value for interpolation into
    the advisory `reason`: each bad char (_BAD_CATS) -> '?', then capped at `cap`
    chars with a trailing '…'. file_path / commands / server all come from the tool
    input, so unsanitized they could forge lines in the model-visible advisory
    (prompt-injection-shaped). Never raises."""
    try:
        s = "".join("?" if unicodedata.category(ch) in _BAD_CATS else ch for ch in str(value))
    except Exception:
        return "?"
    return s if len(s) <= cap else s[:cap] + "…"


def _defang(text: str) -> str:
    """Square brackets -> parentheses, so agent text can never read as a
    `[CAST-EGRESS:...]` advisory tag even mid-line."""
    return text.replace("[", "(").replace("]", ")")


_QUOTE_CAP = 400  # hard cap on the FINAL quoted string (quotes + escapes included)


def _quote(value) -> str:
    """An agent-controlled value as a quoted literal: _clean + _defang, then repr()
    quoting — it reads unmistakably as a delimited VALUE (a forged `' ... [CAST-EGRESS
    ...]` cannot close the quote: repr escapes it), and repr escapes any remaining
    non-printable. Plain values render exactly as 'value'. The 200-char cap applies
    to the raw value (_clean), but repr can expand a char up to 10x (`\\U000f0000`),
    so the quoted result is ALSO hard-capped at _QUOTE_CAP chars: the SOURCE text is
    shortened (never the repr cut mid-escape) until repr(text + '…') fits, so the
    result still closes its quote, stays one line and round-trips ast.literal_eval."""
    s = _defang(_clean(value))
    q = repr(s)
    if len(q) <= _QUOTE_CAP:
        return q
    body = s[:-1] if s.endswith("…") else s
    while body and len(repr(body + "…")) > _QUOTE_CAP:
        body = body[:-1]
    return repr(body + "…")


def assess_sensitivity(event: dict, tool_input: dict) -> dict:
    """Label the egress for the advisory line. AWARENESS ONLY — no block path.
    Returns {'severity': 'info|warn', 'reason': str}. Every value interpolated from
    the tool input is sanitized — the reason is reflected to the model: file_path and
    server via _quote (cleaned, defanged, quoted); bash commands via _clean + _defang
    (they are only ever names that matched the installed policy's command list, and
    stay unquoted so the documented `bash network command(s): curl` format holds)."""
    severity = "info"
    reason = f"off-machine-bound {event.get('surface')} call recorded"
    if event.get("surface") == "credential_read":
        severity, reason = "warn", f"credential file read: {_quote(event.get('file_path'))}"
    if event.get("surface") == "bash" and event.get("commands"):
        severity = "warn"
        reason = f"bash network command(s): {', '.join(_defang(_clean(c)) for c in event['commands'])}"
    if event.get("surface") == "mcp" and event.get("unknown_server"):
        severity = "warn"
        reason = f"UNKNOWN MCP server {_quote(event.get('server'))} (classify it in egress-policy.json)"
    return {"severity": severity, "reason": reason}


# --------------------------------------------------------------------------
# Recording — the sovereignty deliverable
# --------------------------------------------------------------------------
def record(event: dict, verdict: dict, tool_name: str, session_id: str) -> None:
    """Append one line to the local egress ledger. Never raises.
    TODO(ed): optionally also emit a cast.db row (keep cast.db the record)."""
    try:
        os.makedirs(os.path.dirname(EGRESS_LOG), exist_ok=True)
        line = {
            "timestamp": _now_iso(),
            "session_id": session_id,
            "tool_name": tool_name,
            "surface": event.get("surface"),
            "severity": verdict.get("severity"),
            "reason": verdict.get("reason"),
            "repo_class": os.environ.get("CAST_REPO_CLASS", ""),
        }
        # Carry surface-specific, non-sensitive fields only. NO payloads:
        # `query` (WebSearch) is deliberately omitted; `url` is stripped of its
        # query/fragment (tokens) and the query is fingerprinted, not stored.
        for k in ("server", "url", "commands", "file_path", "unknown_server",
                  "anthropic_brokered", "safelisted"):
            if k not in event:
                continue
            if k == "url":
                raw_url = event["url"]
                line["url"] = _safe_url(raw_url)
                # Each fingerprint has its OWN try: a hashing failure must cost that one
                # field, never the whole ledger row (audit-evasion if agent-steerable).
                try:
                    from urllib.parse import urlsplit
                    q = urlsplit(_whatwg_normalize(raw_url)).query
                    if q:
                        line["url_query_hash"] = _fingerprint(q)
                except Exception:
                    pass
                if not line["url"] and raw_url:
                    # url could not be stored safely: keep a fingerprint so repeats correlate.
                    try:
                        line["url_hash"] = _fingerprint(raw_url)
                    except Exception:
                        pass
            else:
                line[k] = event[k]
        with open(EGRESS_LOG, "a") as f:
            f.write(json.dumps(line, separators=(",", ":")) + "\n")
    except Exception as e:
        _log_error(f"egress ledger write failed: {e}")


# --------------------------------------------------------------------------
# Output
# --------------------------------------------------------------------------
def advisory_context(verdict: dict) -> str:
    """The advisory text, shared by emit_advisory and by callers that fold it
    into a larger hookSpecificOutput object (cast-pretool-dispatch.py). A verdict
    with recorded=False (the policy-invalid notice alone) does not claim a ledger
    line was written."""
    suffix = " (recorded to logs/egress.jsonl)." if verdict.get("recorded", True) else "."
    return f"[CAST-EGRESS:{verdict['severity']}] {verdict['reason']}{suffix}"


def emit_advisory(verdict: dict) -> None:
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "additionalContext": advisory_context(verdict),
        }
    }))


# --------------------------------------------------------------------------
# Per-call evaluation — the ONE body main() and cast-pretool-dispatch.py's
# _run_egress both run, so the two paths cannot drift.
# --------------------------------------------------------------------------
_POLICY_INVALID_NOTE = ("egress policy missing or invalid - this call was not fully "
                        "classified (see logs/hook-errors.log)")
# Fixed, CLAUDE_DIR-rooted (never tempfile.gettempdir()) marker dir: one empty file per
# session that has already been shown _POLICY_INVALID_NOTE.
_NOTICE_STATE_DIR = os.path.join(CLAUDE_DIR, "state", "egress-policy-notice")


class _NoticeDirUnsafe(Exception):
    """The policy-notice marker dir is (or sits behind) a symlink, or resolves outside CLAUDE_DIR."""


def _claim_policy_notice(session_id) -> bool:
    """True when _POLICY_INVALID_NOTE should be shown on this call: the FIRST call of
    the session that finds the policy invalid. Atomic exclusive-create of a per-session
    marker (open(path, 'x')), so concurrent hooks yield exactly one winner. The session
    id is reduced to [A-Za-z0-9_-]{1,64} before it touches a path. Never raises, and
    fails LOUD: no usable session id ('' / 'unknown' in any case -- one shared marker
    would silence every such session forever), an unusable marker dir, or one that is /
    sits behind a symlink or resolves outside CLAUDE_DIR -> True (show the notice), so
    the notice can only ever be deduplicated, never lost to a state-dir fault. Every
    call still logs the reason to hook-errors.log via _load_policy()."""
    try:
        sid = re.sub(r"[^A-Za-z0-9_\-]", "", str(session_id or ""))[:64]
        if not sid or sid.lower() == "unknown":
            return True
        # The marker dir must RESOLVE to itself under CLAUDE_DIR: a symlink planted at
        # `state/` or `state/egress-policy-notice` would otherwise redirect the marker
        # (and the makedirs below) into the link target. Checked BEFORE makedirs so
        # nothing is created through a link, and again after (islink + realpath) to
        # narrow the window; any mismatch -> fail loud (the notice is shown).
        expected = os.path.join(os.path.realpath(CLAUDE_DIR), "state", "egress-policy-notice")
        if os.path.realpath(_NOTICE_STATE_DIR) != expected:
            raise _NoticeDirUnsafe()
        os.makedirs(_NOTICE_STATE_DIR, mode=0o700, exist_ok=True)
        if os.path.islink(_NOTICE_STATE_DIR) or os.path.realpath(_NOTICE_STATE_DIR) != expected:
            raise _NoticeDirUnsafe()
        marker = os.path.join(_NOTICE_STATE_DIR, f"{sid}.marker")
    except _NoticeDirUnsafe:
        _log_error("policy-notice marker dir is a symlink or resolves outside CLAUDE_DIR (notice shown)")
        return True
    except Exception as e:
        _log_error(f"policy-notice marker dir unusable (notice shown): {type(e).__name__}")
        return True
    try:
        with open(marker, "x"):
            pass
        return True
    except FileExistsError:
        return False  # already shown this session
    except Exception as e:
        _log_error(f"policy-notice marker write failed (notice shown): {type(e).__name__}")
        return True


def evaluate(tool_name: str, tool_input: dict, session_id: str) -> dict | None:
    """Load the policy, classify, assess and RECORD one tool call. Returns the
    verdict to advise ({severity: 'warn', reason, recorded}) or None for silence.

    When the effective policy is {} (missing / malformed / wrong-shape file --
    see _load_policy()) the advisory is added even for a call classify() found
    nothing to say about: with no bash_network_commands / credential_path_globs
    the Bash and Read surfaces cannot classify anything, and that must never be a
    silent state. The notice is shown ONCE per session (_claim_policy_notice); later
    calls in that session keep their own advisory/record and the per-call reason in
    hook-errors.log, but do not repeat the notice. The MCP/WebFetch fail-safe records
    are unchanged. A valid policy never produces this notice."""
    policy = _load_policy()
    verdict = None
    event = classify(tool_name, tool_input, policy)
    if event is not None:
        assessed = assess_sensitivity(event, tool_input)
        record(event, assessed, tool_name, session_id)
        if assessed.get("severity") == "warn":
            verdict = dict(assessed, recorded=True)
    if not policy and _claim_policy_notice(session_id):
        if verdict is None:
            verdict = {"severity": "warn", "reason": _POLICY_INVALID_NOTE, "recorded": False}
        else:
            verdict["reason"] = f"{verdict['reason']}; {_POLICY_INVALID_NOTE}"
    return verdict


# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------
def main() -> int:
    if os.environ.get("CLAUDE_SUBPROCESS", "0") == "1":
        return 0

    raw = sys.stdin.read()
    if not raw.strip():
        return 0
    try:
        data = json.loads(raw)
    except Exception:
        _log_error("invalid JSON on stdin")
        return 0

    tool_name = data.get("tool_name", "") or ""
    tool_input = data.get("tool_input", {}) or {}
    session_id = data.get("session_id") or os.environ.get("CLAUDE_SESSION_ID", "unknown")

    verdict = evaluate(tool_name, tool_input, session_id)
    if verdict is not None:
        emit_advisory(verdict)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as e:
        try:
            _log_error(f"unhandled exception (fail-open): {e}")
        except Exception:
            pass
        sys.exit(0)
