#!/bin/bash
# status-writer.sh — CAST Agent Status Protocol
# Sourced helper — do NOT execute directly.
#
# Usage:
#   source ~/.claude/scripts/status-writer.sh
#   cast_write_status "<STATUS>" "<summary>" "<agent-name>" "[concerns]" "[recommended_agents]" \
#                     "[session_id]" "[agent_type]"
#
# STATUS values: DONE | DONE_WITH_CONCERNS | BLOCKED | NEEDS_CONTEXT
#
# Optional args 6/7 (written ONLY when non-empty):
#   session_id  — the main-session id from the SubagentStop payload.
#   agent_type  — the TRUSTED roster type resolved from Claude Code's subagent
#                 sidecar (cast_subagent_stop.py:_resolve_roster_type), never the
#                 dispatch name. The requires_agent unblock gate trusts these two
#                 content fields only; the filename and "agent" stay display-only.
#
# Writes a JSON status file to ~/.claude/agent-status/<agent>-<timestamp>-<pid>-<hex>.json
# (the pid + random suffix makes each name unique, even within the same second).
# The dir is created if absent and pinned to mode 0700 by the python writer through
# a no-follow directory fd (never a path-based mkdir/chmod, which follows symlinks).
# Returns the written file path on stdout. Writes nothing (and returns 0) when the
# status dir is a symlink / not a directory. Hooks sourcing this must redirect its
# stdout — it is not safe to leak into a JSON-parsed hook stream.
#
# Called by: agent scripts at the end of their task to emit a structured status.
# Read by:   agent-status-reader.sh (PostToolUse hook) to surface BLOCKED / DONE_WITH_CONCERNS
#            to the main session.

CAST_STATUS_DIR="${HOME}/.claude/agent-status"

cast_write_status() {
  local _status="$1"
  local summary="$2"
  local agent="$3"
  local concerns="${4:-}"
  local recommended="${5:-}"
  local session_id="${6:-}"
  local agent_type="${7:-}"

  # A symlinked status dir would redirect the record to an arbitrary location:
  # refuse quietly. This early test is only a fast path — the python writer
  # creates the dir and does the chmod itself, on an O_NOFOLLOW directory fd, so
  # a symlink swapped in after this test is never followed (no path-based
  # mkdir/chmod here: chmod follows symlinks and re-moded an arbitrary victim).
  if [[ -L "$CAST_STATUS_DIR" ]]; then
    return 0
  fi

  local ts
  ts="$(date -u +%Y%m%dT%H%M%SZ)"

  # Use python3 stdlib only — no pip packages required.
  # Pass all values as positional argv to avoid shell-quoting pitfalls with
  # heredoc variables and to keep the inline script readable.
  #
  # The python block owns the whole write (confused-deputy hardening): this runs
  # unsandboxed from the SubagentStop hook, and a predictable <agent>-<ts>.json
  # path let a pre-planted symlink clobber an arbitrary file (and a path-based
  # chmod then re-moded it). So the final name is randomized (<agent>-<ts> stays
  # the leading prefix for prefix/ts-ordering readers; the pid + random suffix
  # also stops two same-second records overwriting each other), the dir is
  # refused unless it is a real directory, and the record is written O_EXCL |
  # O_NOFOLLOW 0600 to a dot-temp (not *.json) then os.replace()d into place —
  # rename replaces a link at the target rather than following it.
  # Stdout = the written path (empty when the write was refused). Hooks that
  # source this helper must redirect its stdout (their own stdout is JSON).
  # `|| true`: a refused/failed write is a no-op, never a failure of the caller.
  python3 -I - "$agent" "$_status" "$summary" "$concerns" "$recommended" "$ts" "$CAST_STATUS_DIR" "$session_id" "$agent_type" <<'PYEOF' || true
import json, os, stat, sys

agent, status, summary, concerns, recommended, ts, status_dir, session_id, agent_type = sys.argv[1:]

d = {
    "agent": agent,
    "status": status,
    "summary": summary,
    "concerns": concerns if concerns else None,
    "recommended_agents": recommended if recommended else None,
    "timestamp": ts
}
# Gate-trust content fields: present ONLY when supplied (absent != empty string).
if session_id:
    d["session_id"] = session_id
if agent_type:
    d["agent_type"] = agent_type

# Create the dir if absent (0700 before umask; fchmod below pins it), then refuse
# (no record, print nothing) unless status_dir is a real directory: lstat does
# not follow, so a symlink reads as S_IFLNK and fails S_ISDIR. All further access
# goes through the O_NOFOLLOW dir fd, so nothing path-based can be redirected.
try:
    os.makedirs(status_dir, mode=0o700, exist_ok=True)
    if not stat.S_ISDIR(os.lstat(status_dir).st_mode):
        sys.exit(0)
    dfd = os.open(status_dir, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | os.O_NOFOLLOW)
except OSError:
    sys.exit(0)

# Best-effort: keep writing if this fails (the record itself is created 0600).
try:
    os.fchmod(dfd, 0o700)
except OSError:
    pass

# "/" in an agent name must never become a path component.
base = agent.replace("/", "_")
final = f"{base}-{ts}-{os.getpid()}-{os.urandom(3).hex()}.json"
tmp = f".{final}.tmp-{os.urandom(3).hex()}"  # does not end in .json

created = False
try:
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=dfd)
    created = True
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w") as f:
            json.dump(d, f, indent=2)
    except BaseException:
        # fdopen owns fd once constructed; if it never got there, close it here.
        try:
            os.close(fd)
        except OSError:
            pass
        raise
    os.replace(tmp, final, src_dir_fd=dfd, dst_dir_fd=dfd)
except Exception as e:
    if created:
        try:
            os.unlink(tmp, dir_fd=dfd)
        except OSError:
            pass
    print(f"cast_write_status: write failed: {e}", file=sys.stderr)
    sys.exit(1)
finally:
    os.close(dfd)

print(os.path.join(status_dir, final))
PYEOF
}
