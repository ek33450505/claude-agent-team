#!/usr/bin/env bats
# tests/cast-python-isolation.bats
#
# Guards the S3a-U5 fix: every python3 invocation in the CAST shell surface whose code comes from
# `-c`, stdin (`-` / heredoc / here-string) or `-m` MUST run in isolated mode (`python3 -I`).
#
# Why: `python3 -c`, `python3 -` (stdin) and `python3 -m` put the CURRENT DIRECTORY first on
# sys.path. CAST hooks run outside the Bash sandbox with cwd = the project dir, which a sandboxed
# agent can write to -- so an agent that plants `json.py` in the repo gets code execution outside
# the sandbox on the next hook. `-I` drops cwd from sys.path (and ignores PYTHON* env + user site).
# `-P` is NOT used: it needs Python >= 3.11 and the system python3 is 3.9.
# `python3 /path/to/script.py` is safe (sys.path[0] = the script's dir) and is not matched here.
#
#   1. Static    - scan git-tracked shell files under scripts/ bin/ .githooks/ for an un-isolated
#                  invocation (asserts the scan is non-vacuous: files scanned > 0 AND -I sites > 0).
#   2. Behaviour - control proves a planted json.py IS executed by a bare `python3 -c`; then two
#                  real hooks run with cwd = that dir and must NOT execute it.

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'
load 'helpers/setup'

REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"

setup() {
  setup_temp_home
  mkdir -p "$HOME/.claude/logs"
  # PYTHONSAFEPATH=1 would neuter the planted-module probe (and make -I moot); CLAUDE_SUBPROCESS=1
  # would make every hook exit before reaching python (vacuous pass). Neutralise both.
  unset PYTHONSAFEPATH PYTHONPATH CLAUDE_SUBPROCESS
}

teardown() {
  teardown_temp_home
}

# ---------------------------------------------------------------------------------------------
# Detection logic (same as the one-shot transform that applied the fix). Prints:
#   SUMMARY scanned=<files> isolated=<-I sites> offenders=<n>
#   OFFENDER <file>:<line>: <text>
# ---------------------------------------------------------------------------------------------
_write_scanner() {
  cat > "$1" <<'PYSCAN'
import os, re, subprocess

PY_RE = re.compile(r'(?<![\w.$-])(?:(?:/[\w.+-]+)*/)?python3(?:\.\d+)?(?=\s|$)')
OPT_RE = re.compile(r'\s+(-[A-Za-z0-9]*)(?=[\s<|;&)>"\'`]|$)')
SHELL_SHEBANG = re.compile(r'^#!.*\b(ba|z|da|k)?sh\b')


def shell_files():
    out = subprocess.check_output(["git", "ls-files", "scripts", "bin", ".githooks"], text=True).splitlines()
    res = []
    for f in out:
        if not os.path.isfile(f) or os.path.islink(f):
            continue
        if f.endswith((".sh", ".bash")):
            res.append(f)
            continue
        with open(f, "r", encoding="utf-8", errors="replace") as fh:
            if SHELL_SHEBANG.match(fh.readline()):
                res.append(f)
    return res


def scan_state(line, idx):
    sq = dq = False
    i = 0
    while i < idx:
        c = line[i]
        if c == "\\" and not sq:
            i += 2
            continue
        if c == "'" and not dq:
            sq = not sq
        elif c == '"' and not sq:
            dq = not dq
        elif c == "#" and not sq and not dq and (i == 0 or line[i - 1] in " \t;|&("):
            return sq, dq, True
        i += 1
    return sq, dq, False


def classify(line):
    """Return a list of 'NEED' (un-isolated code-from-cwd-sys.path invocation) / 'ALREADY' (-I)."""
    res = []
    if re.match(r'^\s*#', line):
        return res
    for m in PY_RE.finditer(line):
        sq, dq, in_comment = scan_state(line, m.start())
        if in_comment:
            continue
        if sq or (dq and not re.search(r'\$\(|`', line[:m.start()])):
            continue  # python3 named inside a string literal (grep pattern, echo message), not run
        pos = m.end()
        opts = []
        while True:
            om = OPT_RE.match(line, pos)
            if not om:
                break
            opt = om.group(1)
            opts.append(opt)
            pos = om.end()
            if opt in ("-W", "-X"):
                am = re.match(r'\s+\S+', line[pos:])
                if am:
                    pos += am.end()
            if opt == "-" or re.search(r'[cm]', opt[1:]):
                break
        has_i = any(re.fullmatch(r'-[A-Za-z]*I[A-Za-z]*', o) for o in opts)
        code_flag = any(o == "-" or re.search(r'[cm]', o[1:]) for o in opts)
        if has_i:
            res.append("ALREADY")
        elif code_flag or line[pos:].lstrip().startswith("<<"):
            res.append("NEED")
    return res


files = shell_files()
isolated = 0
offenders = []
for f in files:
    with open(f, "r", encoding="utf-8", errors="replace") as fh:
        for n, line in enumerate(fh, 1):
            line = line.rstrip("\n")
            for kind in classify(line):
                if kind == "ALREADY":
                    isolated += 1
                else:
                    offenders.append("%s:%d: %s" % (f, n, line.strip()[:160]))
print("SUMMARY scanned=%d isolated=%d offenders=%d" % (len(files), isolated, len(offenders)))
for o in offenders:
    print("OFFENDER " + o)
PYSCAN
}

@test "static: no un-isolated python3 -c / - / heredoc / -m invocation in scripts/ bin/ .githooks/" {
  local scanner="$BATS_TEST_TMPDIR/scan.py"
  _write_scanner "$scanner"
  run bash -c 'cd "$1" && python3 -I "$2"' _ "$REPO_ROOT" "$scanner"
  assert_success
  local summary scanned isolated offenders
  summary="$(printf '%s\n' "$output" | grep '^SUMMARY ')"
  scanned="$(printf '%s\n' "$summary" | sed -E 's/.*scanned=([0-9]+).*/\1/')"
  isolated="$(printf '%s\n' "$summary" | sed -E 's/.*isolated=([0-9]+).*/\1/')"
  offenders="$(printf '%s\n' "$summary" | sed -E 's/.*offenders=([0-9]+).*/\1/')"
  # Non-vacuous: the scan must actually have looked at files and seen isolated sites.
  [ "$scanned" -gt 0 ]
  [ "$isolated" -gt 0 ]
  if [ "$offenders" -ne 0 ]; then
    printf '%s\n' "$output" | grep '^OFFENDER ' >&2
  fi
  [ "$offenders" -eq 0 ]
}

@test "behaviour: a planted json.py in cwd is executed by bare python3 -c (control) but not by hooks" {
  local dir="$BATS_TEST_TMPDIR/planted"
  local marker="$BATS_TEST_TMPDIR/PLANTED_MODULE_RAN"
  mkdir -p "$dir"
  printf 'open("%s", "w").close()\n' "$marker" > "$dir/json.py"

  # CONTROL: proves the probe works on this interpreter. Without it a green result below could
  # mean "the plant never fires here", not "the hooks are isolated".
  (cd "$dir" && python3 -c 'import json' >/dev/null 2>&1) || true
  [ -f "$marker" ]
  rm -f "$marker"
  [ ! -f "$marker" ]

  # Hook 1: SessionStart time-context (python3 -I -c with json, always reached).
  run bash -c 'cd "$1" && printf "%s" "{}" | bash "$2"' _ "$dir" "$REPO_ROOT/scripts/cast-time-context-hook.sh"
  assert_success
  [ ! -f "$marker" ]                          # checked FIRST: the planted module must not have run
  [[ "$output" == *hookSpecificOutput* ]]     # ...and the python snippet really ran (real json)

  # Hook 2: UserPromptSubmit (python3 -I - heredoc, json imported first). It logs a prompt row,
  # which proves the interpreter ran past `import json`.
  run bash -c 'cd "$1" && printf "%s" "{}" | bash "$2"' _ "$dir" "$REPO_ROOT/scripts/cast-user-prompt-hook.sh"
  assert_success
  [ ! -f "$marker" ]
  [ -f "$HOME/.claude/cast/user-prompts.jsonl" ]
}
