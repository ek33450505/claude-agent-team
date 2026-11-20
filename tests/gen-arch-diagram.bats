#!/usr/bin/env bats
# Tests for scripts/gen-arch-diagram.sh (Mermaid -> SVG render).
#
# The script hardcodes its output to docs/architecture/cast-architecture.svg
# under its repo root and replaces it atomically. It cannot be redirected, so
# every run happens inside a private copy of the repo; npx is replaced by a
# recording stub that writes the -o target. The real repo is never written.

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'
load 'helpers/setup'

REPO_ROOT_REAL="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

setup() {
  setup_temp_home
  SHIM_DIR="$BATS_TEST_TMPDIR/shims"
  mkdir -p "$SHIM_DIR"
  local _gui
  for _gui in osascript open terminal-notifier screencapture; do
    printf '#!/bin/bash\nexit 0\n' > "$SHIM_DIR/$_gui"
    chmod +x "$SHIM_DIR/$_gui"
  done

  # npx stub: logs its argv (one per line) and writes the -o target.
  # NPX_MODE=fail exits 1 without output; NPX_MODE=empty writes a 0-byte file.
  cat > "$SHIM_DIR/npx" <<'EOF'
#!/bin/bash
printf '%s\n' "$@" > "$NPX_LOG"
out=""
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "-o" ]]; then out="$2"; fi
  shift
done
case "${NPX_MODE:-ok}" in
  fail) exit 1 ;;
  empty) : > "$out"; exit 0 ;;
  *) printf '<svg>rendered</svg>\n' > "$out"; exit 0 ;;
esac
EOF
  chmod +x "$SHIM_DIR/npx"
  export PATH="$SHIM_DIR:$PATH"
  export NPX_LOG="$BATS_TEST_TMPDIR/npx-argv.log"

  # Minimal copy: the script and its two architecture inputs, git-initialised so
  # `git rev-parse --show-toplevel` resolves the root the way it does in a real
  # checkout. On macOS that is the /private/var form, so paths are resolved with
  # pwd -P before any comparison.
  COPY="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$COPY/scripts" "$COPY/docs/architecture"
  cp "$REPO_ROOT_REAL/scripts/gen-arch-diagram.sh" "$COPY/scripts/"
  cp "$REPO_ROOT_REAL/docs/architecture/cast-architecture.mmd" "$COPY/docs/architecture/"
  env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE git -C "$COPY" init -q
  COPY_REAL="$(cd "$COPY" && pwd -P)"
  COPY_SVG="$COPY/docs/architecture/cast-architecture.svg"
  COPY_MMD="$COPY/docs/architecture/cast-architecture.mmd"
  printf '<svg>original</svg>\n' > "$COPY_SVG"
}

teardown() {
  teardown_temp_home
}

@test "renders the copy's Mermaid source and replaces its SVG on success" {
  cd "$COPY"
  run bash "$COPY/scripts/gen-arch-diagram.sh"
  assert_success
  assert_output --partial "Done. SVG written to"
  run cat "$COPY_SVG"
  assert_output "<svg>rendered</svg>"
}

@test "passes mermaid-cli the input, transparent background and puppeteer config" {
  cd "$COPY"
  run bash "$COPY/scripts/gen-arch-diagram.sh"
  assert_success
  run cat "$NPX_LOG"
  assert_output --partial "$COPY_REAL/docs/architecture/cast-architecture.mmd"
  assert_output --partial "transparent"
  assert_output --partial "--puppeteerConfigFile"
  assert_output --partial "@mermaid-js/mermaid-cli@latest"
}

@test "writes the render to a temp output path, never directly into the repo docs dir" {
  cd "$COPY"
  run bash "$COPY/scripts/gen-arch-diagram.sh"
  assert_success
  local out_arg
  out_arg="$(awk 'prev == "-o" { print; exit } { prev = $0 }' "$NPX_LOG")"
  [[ -n "$out_arg" ]] || fail "no -o argument recorded"
  [[ "$out_arg" != "$COPY_REAL/docs/"* ]] || fail "render written into repo docs dir: $out_arg"
  # Positive check: the render lands under the mktemp root the script creates.
  # Same expression the script uses, so a trailing slash in TMPDIR matches too.
  [[ "$out_arg" == "${TMPDIR:-/tmp}"/cast-arch-diagram.*/cast-architecture.svg ]] \
    || fail "render not under the temp root: $out_arg"
}

@test "leaves the real repo's SVG byte-identical after rendering a copy" {
  local before after
  before="$(shasum -a 256 "$REPO_ROOT_REAL/docs/architecture/cast-architecture.svg" | awk '{print $1}')"
  cd "$COPY"
  run bash "$COPY/scripts/gen-arch-diagram.sh"
  assert_success
  after="$(shasum -a 256 "$REPO_ROOT_REAL/docs/architecture/cast-architecture.svg" | awk '{print $1}')"
  assert_equal "$before" "$after"
}

@test "fails and keeps the existing SVG when mermaid-cli exits non-zero" {
  cd "$COPY"
  NPX_MODE=fail run bash "$COPY/scripts/gen-arch-diagram.sh"
  assert_failure
  assert_output --partial "mermaid-cli render failed. Existing SVG unchanged."
  run cat "$COPY_SVG"
  assert_output "<svg>original</svg>"
}

@test "fails and keeps the existing SVG when mermaid-cli produces an empty file" {
  cd "$COPY"
  NPX_MODE=empty run bash "$COPY/scripts/gen-arch-diagram.sh"
  assert_failure
  assert_output --partial "produced an empty SVG. Existing SVG unchanged."
  run cat "$COPY_SVG"
  assert_output "<svg>original</svg>"
}

@test "fails with a source-not-found error when the Mermaid input is missing" {
  rm -f "$COPY_MMD"
  cd "$COPY"
  run bash "$COPY/scripts/gen-arch-diagram.sh"
  assert_failure
  assert_output --partial "Mermaid source not found"
  run cat "$COPY_SVG"
  assert_output "<svg>original</svg>"
}

@test "fails with a clear error when npx is not on PATH" {
  if [[ -e /usr/bin/npx || -e /bin/npx ]]; then
    skip "npx is installed in a system bin dir; cannot hide it with a PATH override"
  fi
  cd "$COPY"
  run env PATH="/usr/bin:/bin" /bin/bash "$COPY/scripts/gen-arch-diagram.sh"
  assert_failure
  assert_output --partial "npx not found"
}
