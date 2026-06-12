# Shared setup for all install tests
# Uses a temp dir instead of $HOME to avoid polluting real ~/.claude

setup_temp_home() {
  export ORIG_HOME="$HOME"
  export HOME="$(mktemp -d)"
  # Sentinel: teardown_temp_home will refuse to delete any HOME that lacks this marker
  touch "$HOME/.cast-test-home"
  export TEST_INSTALL_DIR="$HOME/.claude"
}

teardown_temp_home() {
  local target="$HOME"

  # Guard (a): sentinel marker must exist
  if [[ ! -f "$target/.cast-test-home" ]]; then
    echo "FATAL [teardown_temp_home]: refusing to delete '$target' — not a verified test fixture (missing .cast-test-home)" >&2
    export HOME="$ORIG_HOME"
    return 1
  fi

  # Guard (b): path must begin with a known temp prefix
  local is_tmp=0
  case "$target" in
    /tmp/*)                  is_tmp=1 ;;
    /private/tmp/*)          is_tmp=1 ;;
    /var/folders/*)          is_tmp=1 ;;
    /private/var/folders/*)  is_tmp=1 ;;
  esac
  if [[ "$is_tmp" -eq 0 ]]; then
    echo "FATAL [teardown_temp_home]: refusing to delete '$target' — not a verified test fixture (not under /tmp, /private/tmp, or /var/folders)" >&2
    export HOME="$ORIG_HOME"
    return 1
  fi

  # Guard (c): must not equal the invoking user's real home
  local real_home="${ORIG_HOME:-}"
  # Fallback: reject anything that looks like /Users/<name> without a temp suffix
  if [[ -n "$real_home" && "$target" = "$real_home" ]]; then
    echo "FATAL [teardown_temp_home]: refusing to delete '$target' — matches ORIG_HOME (real user home)" >&2
    export HOME="$ORIG_HOME"
    return 1
  fi
  if [[ -z "$real_home" ]]; then
    case "$target" in
      /Users/*)
        echo "FATAL [teardown_temp_home]: refusing to delete '$target' — looks like a real home directory (ORIG_HOME unset)" >&2
        export HOME="$ORIG_HOME"
        return 1
        ;;
    esac
  fi

  rm -rf "$target"
  export HOME="$ORIG_HOME"
}
