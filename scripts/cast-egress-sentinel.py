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

  Surfaces recorded (matcher: "mcp__.*|WebFetch|WebSearch|Bash|Read"):
    1. Cloud-bound MCP calls   (mcp__<server>__<tool>, classified per-server)
    2. WebFetch / WebSearch    (URL host/path only; query/tokens never stored)
    3. Bash network egress     (curl/wget/scp/rsync/ssh/nc/... — name-matched)
    4. Credential reads        (Read of .env, ~/.ssh/id_*, *.pem) for local
                                correlation

DESIGN BOUNDARY (local-first thesis):
  Native Claude Code permissions.deny handles COARSE access control; the OS
  sandbox is the real Bash-egress / filesystem boundary. This sentinel does NOT
  enforce — it is the local record those layers don't keep. PreToolUse hooks are
  also bypassed in headless/cron runs, so it could never be a hard guarantee.
  See docs/v9-a1-egress-sentinel.md.

CONTRACT:
  stdin  — raw PreToolUse hook JSON (tool_name, tool_input, session_id, cwd...)
  stdout — PreToolUse hookSpecificOutput JSON (additionalContext advisory only)
  exit 0 — always. *** FAIL-OPEN: any internal error -> exit 0, log to
           hook-errors.log, never interrupt the user's work. ***

The coarse Bash name-matcher and the info/warn severity labels are awareness
aids for the advisory line, NOT an enforcement decision — there is no block path.
"""
import sys
import os
import json
import fnmatch
import hashlib
from datetime import datetime, timezone

# --------------------------------------------------------------------------
# Paths / constants
# --------------------------------------------------------------------------
HOME = os.path.expanduser("~")
CLAUDE_DIR = os.environ.get("CLAUDE_DIR", os.path.join(HOME, ".claude"))
EGRESS_LOG = os.path.join(CLAUDE_DIR, "logs", "egress.jsonl")
ERROR_LOG = os.path.join(CLAUDE_DIR, "logs", "hook-errors.log")
# Policy data: prefer repo cwd (dev), fall back to installed ~/.claude.
_POLICY_CANDIDATES = [
    os.path.join(os.getcwd(), "config", "egress-policy.json"),
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


def _load_policy() -> dict:
    for path in _POLICY_CANDIDATES:
        try:
            if os.path.isfile(path):
                with open(path) as f:
                    return json.load(f)
        except Exception as e:
            _log_error(f"policy load failed ({path}): {e}")
    return {}


def _expand(path: str) -> str:
    return os.path.expanduser(os.path.expandvars(path or ""))


def _safe_url(url: str) -> str:
    """Strip query string + fragment before persisting — they carry secrets
    (OAuth access_token, pre-signed S3 signatures, API keys as query params).
    Keep scheme/host/path only; the query is fingerprinted separately."""
    try:
        from urllib.parse import urlsplit, urlunsplit
        p = urlsplit(url or "")
        return urlunsplit((p.scheme, p.netloc, p.path, "", ""))
    except Exception:
        return ""


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
        # default_unknown = cloud_bound -> treat unknown as cloud-bound (record it)
        if cloud or unknown:
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


def _host_safelisted(url: str, policy: dict) -> bool:
    hosts = policy.get("safelist_hosts", {}).get("hosts", [])
    low = (url or "").lower()
    return any(h in low for h in hosts)


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
    """Coarse, conservative first-pass: which network binaries appear as a
    command token. TODO(ed): replace with the cast-command-guard.py segment
    tokenizer for real exfil-pipe detection (`cat secret | curl ...`),
    loopback-vs-remote host parsing, and FP suppression. This stub only
    name-matches — it is deliberately NOT an enforcement-grade parser."""
    cmds = policy.get("bash_network_commands", {}).get("commands", [])
    toks = set()
    for raw in command.replace("|", " ").replace("&", " ").replace(";", " ").split():
        base = os.path.basename(raw.strip("'\"`"))
        if base in cmds:
            toks.add(base)
    return sorted(toks)


# --------------------------------------------------------------------------
# Sensitivity — awareness labels for the advisory line
# --------------------------------------------------------------------------
def assess_sensitivity(event: dict, tool_input: dict) -> dict:
    """Label the egress for the advisory line. AWARENESS ONLY — no block path.
    Returns {'severity': 'info|warn', 'reason': str}."""
    severity = "info"
    reason = f"off-machine-bound {event.get('surface')} call recorded"
    if event.get("surface") == "credential_read":
        severity, reason = "warn", f"credential file read: {event.get('file_path')}"
    if event.get("surface") == "bash" and event.get("commands"):
        severity = "warn"
        reason = f"bash network command(s): {', '.join(event['commands'])}"
    if event.get("surface") == "mcp" and event.get("unknown_server"):
        severity = "warn"
        reason = f"UNKNOWN MCP server '{event.get('server')}' (classify it in egress-policy.json)"
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
                line["url"] = _safe_url(event["url"])
                try:
                    from urllib.parse import urlsplit
                    q = urlsplit(event["url"] or "").query
                except Exception:
                    q = ""
                if q:
                    line["url_query_hash"] = hashlib.sha256(q.encode()).hexdigest()[:12]
            else:
                line[k] = event[k]
        with open(EGRESS_LOG, "a") as f:
            f.write(json.dumps(line, separators=(",", ":")) + "\n")
    except Exception as e:
        _log_error(f"egress ledger write failed: {e}")


# --------------------------------------------------------------------------
# Output
# --------------------------------------------------------------------------
def emit_advisory(verdict: dict) -> None:
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "additionalContext": f"[CAST-EGRESS:{verdict['severity']}] {verdict['reason']} "
                                 f"(recorded to logs/egress.jsonl).",
        }
    }))


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

    policy = _load_policy()

    event = classify(tool_name, tool_input, policy)
    if event is None:
        return 0  # on-machine / not egress — say nothing

    verdict = assess_sensitivity(event, tool_input)
    record(event, verdict, tool_name, session_id)

    if verdict.get("severity") == "warn":
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
