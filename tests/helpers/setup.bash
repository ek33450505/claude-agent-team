# Shared setup for all install tests
# Uses a temp dir instead of $HOME to avoid polluting real ~/.claude

setup_temp_home() {
  export ORIG_HOME="$HOME"
  export HOME="$(mktemp -d)"
  export TEST_INSTALL_DIR="$HOME/.claude"
}

teardown_temp_home() {
  rm -rf "$HOME"
  export HOME="$ORIG_HOME"
}
