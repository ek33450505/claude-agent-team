# Shared fixture for the pre-push hook suites (U6b-2b-2).
#
# .githooks/pre-push runs ONLY installed scripts under $HOME/.claude/scripts (never a repo file;
# the repo is passed as data via CAST_REPO_ROOT) and sources the installed cast-hook-lib.sh.
# seed_prepush_install builds a temp-HOME "install" the hook can run against: the REAL
# cast-hook-lib.sh plus an exit-0 stub for every script the hook calls. A suite overwrites an
# installed stub (e.g. gen-cast-stats.sh) to script a particular outcome.
#
# Requires setup_temp_home (helpers/setup.bash) to have run first, so $HOME is a temp dir.

seed_prepush_install() {
  local repo_root s
  repo_root="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  INSTALLED="$HOME/.claude/scripts"
  mkdir -p "$INSTALLED"
  cp "$repo_root/scripts/cast-hook-lib.sh" "$INSTALLED/cast-hook-lib.sh"
  for s in pre-push-ci-check.sh gen-cast-stats.sh gen-stats.sh gen-rules-manifest.sh \
    cast-check-skip-ledger.sh cast-lint-bash32-parse.sh pre-push-ubuntu-check.sh; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$INSTALLED/$s"
  done
  # The rules-drift step needs the generator to leave a manifest in the repo it was pointed at.
  cat > "$INSTALLED/gen-rules-manifest.sh" <<'STUBEOF'
#!/usr/bin/env bash
mkdir -p "$CAST_REPO_ROOT/.github"
touch "$CAST_REPO_ROOT/.github/rules-core.manifest"
exit 0
STUBEOF
  cat > "$INSTALLED/cast-db-contract.py" <<'STUBEOF'
#!/usr/bin/env python3
import sys
if '--check' in sys.argv:
    exit(0)
STUBEOF
  cat > "$INSTALLED/cast-commit-reconcile.py" <<'STUBEOF'
#!/usr/bin/env python3
print('{"status": "clean"}')
STUBEOF
  chmod +x "$INSTALLED"/*.sh "$INSTALLED"/*.py
}
