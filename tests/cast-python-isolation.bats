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
import os, re, subprocess, sys

# Interpreters: literal python[3[.x]], and variable interpreters ("$python_cmd", $PY, ${PYTHON:-python3}).
PY_RE = re.compile(r'(?<![\w.$-])(?:(?:/[\w.+-]+)*/)?python(?:3(?:\.\d+)?)?(?=\s|$)')
VAR_RE = re.compile(
    r'(?<![\w.$-])"?(?:\$([A-Za-z_]\w*)|\$\{([A-Za-z_]\w*)(?::?[-=+?][^}]*)?\})"?(?=\s|$)')
VAR_NAME_RE = re.compile(r'(?i)python|(?:^|_)py(?:$|_)')
# `sh -c "..."`, `bash -c '...'`, `eval "..."`: a quoted python3 after one of these IS executed.
WRAP_RE = re.compile(r'(?:\b(?:ba|z|da|k)?sh\s+(?:-[A-Za-z]+\s+)*-[A-Za-z]*c|\beval)\s+["\']')
OPT_RE = re.compile(r'\s+(-[A-Za-z0-9]*)(?=[\s<|;&)>"\'`]|$)')
SHELL_SHEBANG = re.compile(r'^#!.*\b(ba|z|da|k)?sh\b')
ROOTS = ["scripts", "bin", ".githooks", "install.sh"]


def shell_files(args):
    if args:
        out = args
    else:
        # tracked + untracked-not-ignored, so a new unstaged script is scanned too
        out = sorted(set(subprocess.check_output(
            ["git", "ls-files", "-co", "--exclude-standard"] + ROOTS, text=True).splitlines()))
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


def logical_lines(f):
    """Yield (first_lineno, text) with backslash-newline continuations joined."""
    with open(f, "r", encoding="utf-8", errors="replace") as fh:
        raw = fh.read().split("\n")
    i = 0
    while i < len(raw):
        start, text = i + 1, raw[i]
        while text.endswith("\\") and not text.lstrip().startswith("#") and i + 1 < len(raw):
            i += 1
            text = text[:-1] + " " + raw[i].lstrip()
        yield start, text
        i += 1


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


def candidates(line):
    spans = [(m.start(), m.end()) for m in PY_RE.finditer(line)]
    for m in VAR_RE.finditer(line):
        if re.search(r'>\s*$', line[:m.start()]):
            continue  # `cat > "$SOME_PY" <<EOF` WRITES a file named by the variable; it is not run
        if VAR_NAME_RE.search(m.group(1) or m.group(2)):
            spans.append((m.start(), m.end()))
    return sorted(spans)


def classify(line):
    """Return a list of 'NEED' (un-isolated code-from-cwd-sys.path invocation) / 'ALREADY' (-I)."""
    res = []
    if re.match(r'^\s*#', line):
        return res
    for start, end in candidates(line):
        sq, dq, in_comment = scan_state(line, start)
        if in_comment:
            continue
        in_string = sq or (dq and not re.search(r'\$\(|`', line[:start]))
        if in_string and not WRAP_RE.search(line[:start]):
            continue  # python3 named inside a string literal (grep pattern, echo message), not run
        pos = end
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
        elif code_flag or re.match(r'\s*<', line[pos:]):
            res.append("NEED")  # -c / - / -m, or code via heredoc / here-string / `< file`
    return res


files = shell_files(sys.argv[1:])
isolated = 0
offenders = []
for f in files:
    for n, line in logical_lines(f):
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

# ---------------------------------------------------------------------------------------------
# Scanner self-test: one offender per historical blind spot (each MUST be flagged) plus isolated
# / non-executing forms (MUST NOT be flagged). One file per case so a failure names the blind spot.
# Fixtures deliberately contain no test-declaration token (bats would parse it in THIS file).
# ---------------------------------------------------------------------------------------------
_mk_fixture() { # <dir> <name> <line...>  -- writes a bash script containing exactly the given lines
  local dir="$1" name="$2"
  shift 2
  { printf '#!/bin/bash\n'; printf '%s\n' "$@"; } > "$dir/$name"
}

@test "scanner self-test: flags each blind-spot offender, passes isolated forms, enumerates untracked" {
  local fx="$BATS_TEST_TMPDIR/fx"
  mkdir -p "$fx/scripts" "$fx/bin" "$fx/.githooks"
  cd "$fx"
  git init -q .

  # --- offenders (every one must be reported) ---
  _mk_fixture scripts off_literal.sh "python3 -c 'import json'"
  _mk_fixture scripts off_module.sh 'python3 -m venv "$D"'
  _mk_fixture scripts off_heredoc.sh "python3 - <<'EOF'" 'import json' 'EOF'
  _mk_fixture scripts off_stdin_redirect.sh 'python3 < "$f"'
  _mk_fixture scripts off_var_quoted.sh 'if ! "$python_cmd" -c "import textual"; then :; fi'
  _mk_fixture scripts off_var_bare.sh '$PY -c "x"'
  _mk_fixture scripts off_var_default.sh '"${PYTHON:-python3}" -c "x"'
  _mk_fixture scripts off_var_module.sh '"$VENV_PY" -m pytest'
  _mk_fixture scripts off_sh_c.sh "sh -c \"python3 -c 'import json'\""
  _mk_fixture scripts off_bash_c.sh "bash -c 'python3 -c \"import json\"'"
  _mk_fixture scripts off_continuation.sh 'python3 \' "  -c 'import json'"
  _mk_fixture scripts off_continuation_multi.sh 'python3 \' "  -c 'x' \\" '  | cat'
  _mk_fixture bin off_bin_noext "python3 -c 'x'"      # no .sh extension: found via shebang
  _mk_fixture .githooks off_hook "python3 -m json.tool"
  _mk_fixture . install.sh "python3 -m venv v"        # top-level install.sh is in scope
  # untracked-not-ignored must be scanned; ignored must not
  printf 'scripts/ignored_*.sh\n' > .gitignore
  _mk_fixture scripts ignored_offender.sh "python3 -c 'x'"

  # --- isolated / non-executing forms (none may be reported) ---
  _mk_fixture scripts ok_literal.sh "python3 -I -c 'import json'" 'python3 -I - <<EOF' 'EOF' 'python3 -I -m venv "$D"'
  _mk_fixture scripts ok_var.sh '"$python_cmd" -I -c "x"' '"${PYTHON:-python3}" -I -c "x"' '$PY -I -c x'
  _mk_fixture scripts ok_sh_c.sh "sh -c \"python3 -I -c 'x'\"" "bash -c 'python3 -I -c \"x\"'"
  _mk_fixture scripts ok_continuation.sh 'python3 \' "  -I -c 'x'"
  _mk_fixture scripts ok_script_path.sh 'python3 "$script" --flag' '"$PY" "$script"' 'python3 /abs/tool.py'
  _mk_fixture scripts ok_strings.sh 'grep -q "python3 -c" "$f"' 'echo "run python3 -m venv later"' \
    '# python3 -c commentary' 'x=1 # python3 -c trailing comment'
  _mk_fixture scripts ok_redirect_target.sh 'cat > "$_THING_PY" <<'"'EOF'" 'EOF' '"$COPYDIR" -c x'

  local scanner="$BATS_TEST_TMPDIR/scan.py"
  _write_scanner "$scanner"
  run python3 -I "$scanner"
  assert_success

  local f
  for f in scripts/off_literal.sh scripts/off_module.sh scripts/off_heredoc.sh \
    scripts/off_stdin_redirect.sh scripts/off_var_quoted.sh scripts/off_var_bare.sh \
    scripts/off_var_default.sh scripts/off_var_module.sh scripts/off_sh_c.sh scripts/off_bash_c.sh \
    scripts/off_continuation.sh scripts/off_continuation_multi.sh bin/off_bin_noext \
    .githooks/off_hook install.sh; do
    printf '%s\n' "$output" | grep -q "^OFFENDER $f:" || {
      echo "NOT FLAGGED (blind spot): $f" >&2
      echo "$output" >&2
      return 1
    }
  done
  # exactly the 15 planted offenders: nothing isolated, ignored or string-only was reported
  [[ "$output" == *"offenders=15"* ]] || { echo "$output" >&2; return 1; }
  [[ "$output" != *ok_* ]]
  [[ "$output" != *ignored_offender* ]]
}
