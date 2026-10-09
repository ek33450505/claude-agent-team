#!/usr/bin/env python3
"""cast_config_change_guard.py -- ConfigChange hook evaluator (S3d follow-up F1b).

THREAT. A project ``.claude/settings.json`` or ``.claude/settings.local.json``
is hot-reloaded mid-session. Two of its keys defeat every CAST guard:

  * ``"disableAllHooks": true`` switches off USER hooks (every CAST guard is a
    user hook).
  * ``env`` "reaches every subprocess Claude Code starts", hook processes
    included, and project/local ``env`` is NOT filtered for PATH, BASH_ENV,
    BASH_FUNC_*, LD_*/DYLD_*, PYTHON*, GIT_* -- so it can plant code execution
    inside every bash/python hook, or set a guard override.

NATIVE CONTROL. Claude Code's ``ConfigChange`` hook event fires on a settings
change and can veto it ("When blocked, the new settings are not applied to the
running session"). This module is the evaluator behind
``scripts/cast-config-change-guard.sh``.

CONTRACT.
  * stdin  : JSON object (common fields + ``source`` + optional ``file_path``).
    A well-formed non-object is not a payload this guard can judge -> silent.
    Unparseable / invalid-UTF-8 / empty / oversize (> 1 MiB) stdin fails closed.
    Unparseable stdin fails closed; the contract validators' payload expansion
    currently appends a stray '}' (separate fix), so they observe decision=block
    here.
  * stdout : empty = allow; ``{"decision":"block","reason":...}`` = veto.
  * exit   : always 0 (the shell wrapper turns a non-zero exit into a block).
  * Fails CLOSED: any unexpected exception, or an unreadable/oversize
    (> 256 KiB)/non-regular/unparseable settings TARGET, blocks. When the payload
    carries no ``file_path`` BOTH ``$CLAUDE_PROJECT_DIR/.claude/<file>`` and
    ``<cwd>/.claude/<file>`` are judged (deduped if equal): either offending or
    unverifiable blocks, and ``<no-target-file>`` blocks only when BOTH are missing.
    With a ``file_path`` a missing file is a deletion and is allowed.
  * Env KEY SYNTAX is judged, not just the spelling: a key that is not a plain
    ``[A-Za-z_][A-Za-z0-9_]*`` name is offending (``env:<bad-name>``), because a
    NUL / ``=`` / whitespace suffix is truncated or trimmed by the consumer (Node's
    process.env setter truncates at NUL) so ``"BASH_ENV\\0x"`` would reach child
    bash as BASH_ENV. The part before the first NUL / ``=`` (trimmed) is also
    tested against the denylist so the report names the real variable.
  * Bounded time: a hard self-deadline (SIGALRM, DEADLINE_SECONDS) emits a block
    and exits. A command hook that hits Claude Code's own timeout renders NO
    decision and the change would apply, so the guard must answer first.
  * Logs NAMES only, never values (a secret in an env value must not reach
    stdout, the reason string, or the audit log).

DEFENCE IN DEPTH. The primary layer is the native ``Edit(**/.claude/settings*.json)``
deny; this guard covers non-tool writers mid-session. Its denylist is a best-effort
net, not a proof: it will not chase every environment variable.

DOCUMENTED RESIDUALS (deliberately out of scope for this unit):
  * Only ``disableAllHooks`` and the ``env`` key names are judged. Other
    settings keys that can run code or widen trust (``hooks``, ``statusLine``,
    ``apiKeyHelper``/``awsAuthRefresh``-style helpers, ``permissions``,
    ``sandbox``) are NOT inspected here.
  * A blocked change stays on disk and applies at the NEXT startup
    (ConfigChange does not fire at startup).
  * ``policy_settings`` cannot be blocked by any hook.
  * TOCTOU: the hook reads the file AFTER the change. A writer that flips the
    content between the guard's read and Claude Code's load can show the guard
    something benign and Claude Code something malicious. Only an OS-level
    deny-write closes that (sandbox ``denyWrite`` on the settings paths when the
    sandbox is on); a hook cannot.
  * Over-blocking is deliberate (fail closed): a UTF-8 BOM, JSONC comments, a
    trailing comma, or ``disableAllHooks`` set to null / 0 / "false" all block,
    as do ANTHROPIC_* / CLAUDE_CODE_* / proxy / CA-bundle env keys.
"""
from __future__ import annotations

import datetime
import json
import os
import re
import signal
import stat
import sys

# Sources this guard judges. user/policy/skills changes are not an agent-writable
# project channel (and policy_settings cannot be blocked anyway) -> silent allow.
WATCHED_SOURCES = frozenset({"project_settings", "local_settings"})

MAX_BYTES = 1 << 20  # 1 MiB bound for the stdin payload (Claude Code's channel)
MAX_SETTINGS_BYTES = 256 * 1024  # bound for the agent-writable settings file
MAX_NAMES = 20  # stop collecting after this many offenders: one hit already blocks
MAX_NAME_LEN = 64
MAX_PATH_LEN = 512
MAX_SESSION_LEN = 128
# Must stay well under the hook's own 5 s timeout (managed-settings.d/25-hooks-security.json).
DEADLINE_SECONDS = 2.5

# --- env keys that are exec- or guard-relevant -------------------------------
# Exact names, compared after .upper() so a lowercase spelling cannot slip by.
EXACT = frozenset({
    # Command / library resolution and shell startup injection: every bash hook
    # inherits these, so setting them is code execution inside every guard.
    "PATH", "BASH_ENV", "ENV", "SHELLOPTS", "BASHOPTS", "CDPATH", "GLOBIGNORE",
    "IFS", "PS4", "PROMPT_COMMAND", "SHELL", "ZDOTDIR",
    # Bash behaviour switches that change how hook scripts parse/trace/load code:
    # FUNCNEST/POSIXLY_CORRECT alter evaluation, BASH_XTRACEFD redirects the xtrace
    # stream to an attacker-chosen fd, BASH_LOADABLES_PATH loads builtins from a dir.
    "FUNCNEST", "POSIXLY_CORRECT", "BASH_XTRACEFD", "BASH_LOADABLES_PATH",
    # Attestation enforcement switch consulted by CAST hooks.
    "ATTEST_ENFORCE_AGENTS",
    # Interpreter option / library-path injection for non-Python, non-Node runtimes
    # that hooks or agent tooling may launch (Python is the PYTHON prefix below,
    # Node is the NODE_ prefix below).
    "RUBYOPT", "PERL5OPT", "PERL5LIB", "PERLLIB",
    # Traffic redirection / TLS trust: a proxy or an attacker CA lets a MITM read
    # or rewrite every outbound request (API keys, model streams, git over https).
    # SSLKEYLOGFILE makes TLS libraries write session secrets to a file the
    # attacker can read, which decrypts captured traffic.
    "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY", "SSL_CERT_FILE",
    "SSL_CERT_DIR", "CURL_CA_BUNDLE", "REQUESTS_CA_BUNDLE", "SSLKEYLOGFILE",
    # Programs launched on the user's behalf (git/less/ssh read these): an editor,
    # pager, LESSOPEN preprocessor or ssh askpass/agent socket is a command-exec
    # or credential-theft hook.
    "EDITOR", "VISUAL", "PAGER", "LESSOPEN", "SSH_ASKPASS", "SSH_AUTH_SOCK",
    # macOS xcrun shims: /usr/bin/python3 and /usr/bin/git are xcrun stubs that
    # exec <DEVELOPER_DIR>/usr/bin/xcrun first, so an attacker DEVELOPER_DIR runs
    # its fake xcrun even under `python3 -I` / `-E -s` (probe: exec for python3 and
    # git). TOOLCHAINS selects the toolchain xcrun resolves tools from (no exec
    # reproduced on a CommandLineTools-only host; blocked as a tool-resolution
    # redirect). The xcrun_* knobs are the XCRUN_ prefix below (xcrun_db is the
    # cache path; probe-proven exec via cache poisoning).
    "DEVELOPER_DIR", "TOOLCHAINS",
})

# Prefix families, compared after .upper().
PREFIXES = (
    "CAST_",       # every CAST override / policy / DB-path knob (CAST_POLICY_OVERRIDE ...)
    "LD_",         # glibc dynamic-loader injection (LD_PRELOAD, LD_LIBRARY_PATH)
    "DYLD_",       # macOS dynamic-loader injection (DYLD_INSERT_LIBRARIES)
    "XCRUN_",      # xcrun_db redirects xcrun's tool-path cache to an attacker-written file:
                   # a poisoned entry makes /usr/bin/python3 and /usr/bin/git exec an
                   # arbitrary binary (probe-confirmed); the other xcrun_* knobs
                   # (nocache/log/verbose) showed no exec alone and are blocked as
                   # the same family
    "PYTHON",      # PYTHONPATH/PYTHONSTARTUP/PYTHONHOME ... (python3 hooks)
    "GIT_",        # GIT_SSH_COMMAND/GIT_EXEC_PATH/GIT_CONFIG_* (git runs inside hooks)
    "BASH_FUNC_",  # exported bash functions: BASH_FUNC_name%% defines code
    "ANTHROPIC_",  # base URL / custom headers / API key: redirects the model stream
                   # and exfiltrates the key
    "CLAUDE_",     # blanket Claude Code control surface: CLAUDE_SUBPROCESS (makes every
                   # CAST hook exit 0), CLAUDE_ENV_FILE (shell startup), CLAUDE_PROJECT_DIR
                   # (steers what this guard reads), CLAUDE_CODE_* (shell prefix/shell,
                   # env scrubbing, script caps, spawn limits), CLAUDE_BASH_MAINTAIN_
                   # PROJECT_WORKING_DIR, and any future knob
    "NODE_",       # NODE_OPTIONS (--require code exec), NODE_TLS_REJECT_UNAUTHORIZED
                   # (disables TLS verification), NODE_EXTRA_CA_CERTS (attacker CA),
                   # NODE_PATH (module hijack)
    "AWS_",        # credential/endpoint/profile redirection (AWS_ENDPOINT_URL, AWS_PROFILE,
                   # AWS_CONFIG_FILE ...): sends signed requests or secrets elsewhere
    "GOOGLE_",     # GOOGLE_APPLICATION_CREDENTIALS and friends: swaps the credential
                   # identity / endpoint used by Google SDKs and gcloud
)

# A plain environment-variable name. Anything else is fail-closed (see CONTRACT).
_ENV_NAME_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
# Consumers truncate a key at NUL and split at "=": the real variable is the head.
_ENV_NAME_HEAD_SPLIT_RE = re.compile(r"[\x00=]")

# Control chars + the Unicode line/paragraph separators. Built with chr() so the
# source carries no literal separator characters.
_CTRL_RE = re.compile(r"[\x00-\x1f\x7f-\x9f" + chr(0x2028) + chr(0x2029) + "]")


class _Unverifiable(Exception):
    """The target could not be safely judged; carries a pseudo-name tag."""

    def __init__(self, tag: str) -> None:
        super().__init__(tag)
        self.tag = tag


def _env_offender(key: str):
    """Return the offending name for an env ``key``, or None if it is allowed."""
    head = _ENV_NAME_HEAD_SPLIT_RE.split(key, 1)[0].strip()
    upper = head.upper()
    if upper in EXACT or upper.startswith(PREFIXES):
        return head
    if not _ENV_NAME_RE.fullmatch(key):
        return "env:<bad-name>"
    return None


def evaluate(settings_obj) -> list:
    """Return the offending names in ``settings_obj`` (empty list = allow).

    Names only -- never values. Linear time; stops after MAX_NAMES offenders.
    """
    if not isinstance(settings_obj, dict):
        return ["settings:<non-object>"]
    names: list = []
    seen: set = set()

    def add(name: str) -> bool:
        """Record an offender; True once MAX_NAMES are held (one hit already blocks)."""
        if name not in seen:
            seen.add(name)
            names.append(name)
        return len(names) >= MAX_NAMES

    if "disableAllHooks" in settings_obj and settings_obj["disableAllHooks"] is not False:
        if add("disableAllHooks"):
            return names

    if "env" in settings_obj:
        env = settings_obj["env"]
        if not isinstance(env, dict):
            add("env:<non-object>")
        else:
            for key in env:
                offender = (
                    _env_offender(key) if isinstance(key, str) else "env:<non-string-key>"
                )
                if offender is not None and add(offender):
                    break
    return names


def _clean(value, limit: int) -> str:
    """Strip control chars and truncate; non-str becomes empty."""
    if not isinstance(value, str):
        return ""
    return _CTRL_RE.sub("", value)[:limit]


def _clean_names(names: list) -> list:
    return [_clean(n, MAX_NAME_LEN) for n in names[:MAX_NAMES]]


def _read_bounded(fd: int, limit: int) -> bytes:
    chunks = []
    total = 0
    while total <= limit:
        chunk = os.read(fd, min(65536, limit + 1 - total))
        if not chunk:
            break
        chunks.append(chunk)
        total += len(chunk)
    return b"".join(chunks)


def _target_paths(payload: dict, source: str):
    """Return ``(paths, derived)``; ``derived`` is True when file_path was absent.

    Without a ``file_path`` we cannot tell which directory Claude Code treated as
    the project root, so BOTH ``$CLAUDE_PROJECT_DIR`` and ``cwd`` are candidates
    (CLAUDE_PROJECT_DIR first, deduped if they resolve to the same file).
    """
    file_path = payload.get("file_path")
    if isinstance(file_path, str) and file_path:
        return [file_path], False
    name = "settings.json" if source == "project_settings" else "settings.local.json"
    paths: list = []
    for base in (os.environ.get("CLAUDE_PROJECT_DIR"), payload.get("cwd")):
        if isinstance(base, str) and base:
            candidate = os.path.join(base, ".claude", name)
            if os.path.normpath(candidate) not in [os.path.normpath(p) for p in paths]:
                paths.append(candidate)
    if not paths:
        raise _Unverifiable("<no-target-path>")
    return paths, True


def _load_target(path: str):
    """Return the parsed settings dict, or None if the file does not exist.

    Raises _Unverifiable for anything that cannot be safely judged. os.stat
    follows symlinks on purpose: we judge what Claude Code will actually load.
    """
    try:
        st = os.stat(path)
    except FileNotFoundError:
        return None  # deleting/absent file adds no key
    except (OSError, ValueError):
        raise _Unverifiable("<unreadable>")
    if not stat.S_ISREG(st.st_mode):
        raise _Unverifiable("<not-regular-file>")  # never open a FIFO/device/dir
    if st.st_size > MAX_SETTINGS_BYTES:
        raise _Unverifiable("<oversize>")
    try:
        # O_NONBLOCK: a FIFO swapped in after the stat cannot hang the open.
        fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
    except FileNotFoundError:
        return None
    except (OSError, ValueError):
        raise _Unverifiable("<unreadable>")
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            raise _Unverifiable("<not-regular-file>")
        data = _read_bounded(fd, MAX_SETTINGS_BYTES)
    except OSError:
        raise _Unverifiable("<unreadable>")
    finally:
        os.close(fd)
    if len(data) > MAX_SETTINGS_BYTES:
        raise _Unverifiable("<oversize>")
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError:
        raise _Unverifiable("<invalid-utf8>")
    try:
        obj = json.loads(text)
    except ValueError:
        raise _Unverifiable("<invalid-json>")
    if not isinstance(obj, dict):
        raise _Unverifiable("<non-object>")
    return obj


def _audit(session_id, source, file_path, verdict: str, names: list) -> None:
    """Append one names-only JSON line; a failure never changes the verdict.

    A failure is reported on stderr (the wrapper appends it to hook-errors.log)
    so a planted symlink / unwritable log is not silent.
    """
    try:
        home = os.environ.get("HOME") or os.path.expanduser("~")
        log_dir = os.path.join(home, ".claude", "logs")
        os.makedirs(log_dir, mode=0o700, exist_ok=True)
        record = {
            "ts": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "session_id": _clean(session_id, MAX_SESSION_LEN),
            "source": _clean(source, MAX_NAME_LEN),
            "file_path": _clean(file_path, MAX_PATH_LEN),
            "verdict": verdict,
            "names": _clean_names(names),
        }
        line = (json.dumps(record) + "\n").encode("utf-8")
        fd = os.open(
            os.path.join(log_dir, "config-change-guard.jsonl"),
            os.O_WRONLY | os.O_APPEND | os.O_CREAT | os.O_NOFOLLOW,
            0o600,
        )
        try:
            os.write(fd, line)
        finally:
            os.close(fd)
    except Exception as exc:  # noqa: BLE001 -- logging must never change the verdict
        try:
            sys.stderr.write(
                f"cast-config-change-guard: audit log write failed ({type(exc).__name__})\n"
            )
        except Exception:  # noqa: BLE001
            pass


def _block_json(source: str, names: list, structural: bool) -> str:
    shown = _clean_names(names)
    extra = len(names) - len(shown)
    listing = ", ".join(shown) + (f" (+{extra} more)" if extra > 0 else "")
    verb = "unverifiable" if structural else "sets"
    src = _clean(source, MAX_NAME_LEN) or "unknown"
    return json.dumps({
        "decision": "block",
        "reason": f"cast-config-change-guard: {src} {verb} {listing}",
    })


def _run() -> str:
    """Return the stdout payload ('' = allow). May raise -> main() fails closed."""
    raw = sys.stdin.buffer.read(MAX_BYTES + 1)
    if len(raw) > MAX_BYTES:
        _audit("", "", "", "block", ["<stdin-oversize>"])
        return _block_json("", ["<stdin-oversize>"], structural=True)
    try:
        payload = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, ValueError):
        # Fail closed: a security guard that cannot parse its own input cannot
        # tell whether the change is safe. Names nothing from the input.
        sys.stderr.write("cast-config-change-guard: stdin is not valid JSON; blocking\n")
        _audit("", "", "", "block", ["<stdin-invalid-json>"])
        return _block_json("", ["<stdin-invalid-json>"], structural=True)
    if not isinstance(payload, dict):
        return ""
    source = payload.get("source")
    if source not in WATCHED_SOURCES:
        return ""

    session_id = payload.get("session_id")
    file_path = ""
    names: list = []
    try:
        paths, derived = _target_paths(payload, source)
        file_path = " | ".join(paths)
        loaded = 0
        for path in paths:
            settings = _load_target(path)  # unverifiable (either candidate) -> block
            if settings is None:
                continue
            loaded += 1
            names = evaluate(settings)
            if names:  # offending (either candidate) -> block
                file_path = path
                break
        if not loaded and derived:
            # No file_path to anchor on and every derived candidate is missing (e.g.
            # cwd is a subdirectory): we cannot tell which file Claude Code loaded.
            raise _Unverifiable("<no-target-file>")
    except _Unverifiable as exc:
        _audit(session_id, source, file_path, "block", [exc.tag])
        return _block_json(source, [exc.tag], structural=True)
    if names:
        _audit(session_id, source, file_path, "block", names)
        return _block_json(source, names, structural=False)
    _audit(session_id, source, file_path, "allow", [])
    return ""


def _on_deadline(signum, frame) -> None:  # noqa: ARG001
    """SIGALRM: answer BLOCK now. Claude Code's own timeout renders no decision."""
    try:
        os.write(
            1,
            b'{"decision": "block", "reason": '
            b'"cast-config-change-guard: evaluation deadline exceeded"}\n',
        )
        os.write(2, b"cast-config-change-guard: evaluation deadline exceeded; blocking\n")
    finally:
        os._exit(0)


def main() -> int:
    previous = signal.signal(signal.SIGALRM, _on_deadline)
    signal.setitimer(signal.ITIMER_REAL, DEADLINE_SECONDS)
    try:
        try:
            out = _run()
        except Exception:  # noqa: BLE001 -- fail closed on anything unexpected
            out = json.dumps({
                "decision": "block",
                "reason": "cast-config-change-guard: evaluator error",
            })
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
        signal.signal(signal.SIGALRM, previous if previous is not None else signal.SIG_DFL)
    if out:
        sys.stdout.write(out + "\n")
        sys.stdout.flush()
    return 0


if __name__ == "__main__":
    sys.exit(main())
