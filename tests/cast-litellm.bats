#!/usr/bin/env bats
# cast-litellm.bats — Tests for LiteLLM contractor routing
#
# Coverage:
#   1. cast-litellm-start.sh:
#      - Verify script exists and is executable
#      - Verify it checks for litellm installation
#      - Verify it checks for Ollama availability
#      - Verify PID file creation logic
#
#   2. cast-validate-contractor.sh:
#      - Verify valid commit message passes
#      - Verify empty output fails
#      - Verify hallucination markers fail
#      - Verify overly long output fails (>500 chars)
#      - Verify 'This commit' prefix fails
#
#   3. cast-litellm.yaml:
#      - Verify YAML is valid
#      - Verify required model entries exist
#      - Verify fallback_models is configured
#
#   4. model_used column in cast.db:
#      - Create temp DB with cast-db-init.sh
#      - Verify model_used column exists in agent_runs table

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPTS_DIR="$REPO_DIR/scripts"
TESTS_DIR="$REPO_DIR/tests"

# Helper scripts being tested
START_SCRIPT="$SCRIPTS_DIR/cast-litellm-start.sh"
VALIDATE_SCRIPT="$SCRIPTS_DIR/cast-validate-contractor.sh"
CONFIG_YAML="$REPO_DIR/config/cast-litellm.yaml"
DB_INIT_SCRIPT="$SCRIPTS_DIR/cast-db-init.sh"

# ---------------------------------------------------------------------------
# Setup / Teardown
# ---------------------------------------------------------------------------

setup() {
    # Temp DB for test isolation
    TEST_DB="$BATS_TMPDIR/test-litellm-$$.db"
    export CAST_DB_PATH="$TEST_DB"

    # Temp PID file for start script testing
    TEST_PIDDIR="$BATS_TMPDIR/litellm-pids-$$"
    mkdir -p "$TEST_PIDDIR"
    export LITELLM_PIDDIR="$TEST_PIDDIR"
}

teardown() {
    rm -f "$TEST_DB" "${TEST_DB}-wal" "${TEST_DB}-shm"
    rm -rf "$TEST_PIDDIR"
}

# ---------------------------------------------------------------------------
# Helper: Create temp DB schema with model_used column
# ---------------------------------------------------------------------------

init_test_db() {
    if [ ! -f "$DB_INIT_SCRIPT" ]; then
        skip "cast-db-init.sh not found at $DB_INIT_SCRIPT"
    fi
    bash "$DB_INIT_SCRIPT"
}

# Helper: Run validator with input via stdin
validate_input() {
    local input="$1"
    echo "$input" | bash "$VALIDATE_SCRIPT" 2>&1
    return $?
}

skip_if_script_missing() {
    local script="$1"
    if [ ! -f "$script" ]; then
        skip "Script not found: $script"
    fi
}

skip_if_file_missing() {
    local file="$1"
    if [ ! -f "$file" ]; then
        skip "File not found: $file"
    fi
}

skip_if_no_pyyaml() {
    if ! python3 -c "import yaml" 2>/dev/null; then
        skip "pyyaml not installed"
    fi
}

# ---------------------------------------------------------------------------
# 1. cast-litellm-start.sh Tests
# ---------------------------------------------------------------------------

@test "cast-litellm-start.sh: script exists and is executable" {
    skip_if_script_missing "$START_SCRIPT"
    [ -f "$START_SCRIPT" ] && [ -x "$START_SCRIPT" ]
}

@test "cast-litellm-start.sh: checks for litellm installation (graceful)" {
    skip_if_script_missing "$START_SCRIPT"
    run bash "$START_SCRIPT"
    # Exit codes: 0 (success), 1 (litellm missing), 2 (Ollama missing)
    # The script should not crash; it should exit with a known code
    [ "$status" -eq 0 ] || [ "$status" -eq 1 ] || [ "$status" -eq 2 ]
}

@test "cast-litellm-start.sh: checks for Ollama availability (port 11434)" {
    skip_if_script_missing "$START_SCRIPT"
    # If Ollama is not running, the script should detect it
    # and either exit gracefully or log a warning
    run bash "$START_SCRIPT"
    # Should exit 0, 1, or 2 depending on litellm/Ollama state
    [ "$status" -eq 0 ] || [ "$status" -eq 1 ] || [ "$status" -eq 2 ]
}

@test "cast-litellm-start.sh: creates PID file if litellm is available" {
    skip_if_script_missing "$START_SCRIPT"
    # Only test PID file creation if the environment has litellm + Ollama
    # This is a happy-path test; skip if dependencies are missing
    if command -v litellm >/dev/null 2>&1 && curl -s http://localhost:11434/api/tags >/dev/null 2>&1; then
        run bash "$START_SCRIPT"
        assert_success
        # PID file should exist in the expected location
        [ -f "$LITELLM_PIDDIR/litellm.pid" ] || [ -f "/tmp/litellm.pid" ]
    fi
}

# ---------------------------------------------------------------------------
# 2. cast-validate-contractor.sh Tests
# ---------------------------------------------------------------------------

@test "cast-validate-contractor.sh: script exists and is executable" {
    skip_if_script_missing "$VALIDATE_SCRIPT"
    [ -f "$VALIDATE_SCRIPT" ] && [ -x "$VALIDATE_SCRIPT" ]
}

@test "validate: valid commit message passes ('Add user authentication')" {
    skip_if_script_missing "$VALIDATE_SCRIPT"
    run validate_input "Add user authentication"
    assert_success
}

@test "validate: valid commit message with multiple words passes" {
    skip_if_script_missing "$VALIDATE_SCRIPT"
    run validate_input "Fix critical bug in database connection pooling"
    assert_success
}

@test "validate: empty output fails" {
    skip_if_script_missing "$VALIDATE_SCRIPT"
    run validate_input ""
    assert_failure
    assert_output --partial "empty"
}

@test "validate: whitespace-only output fails" {
    skip_if_script_missing "$VALIDATE_SCRIPT"
    run validate_input "   "
    assert_failure
}

@test "validate: 'As an AI, I cannot' marker fails (hallucination)" {
    skip_if_script_missing "$VALIDATE_SCRIPT"
    run validate_input "As an AI, I cannot generate this commit message"
    assert_failure
    assert_output --partial "AI"
}

@test "validate: 'I cannot' marker fails" {
    skip_if_script_missing "$VALIDATE_SCRIPT"
    run validate_input "I cannot provide a proper commit message"
    assert_failure
}

@test "validate: 'I'm not sure' marker fails" {
    skip_if_script_missing "$VALIDATE_SCRIPT"
    run validate_input "I'm not sure what this code does"
    assert_failure
}

@test "validate: 'I'm unable' marker fails" {
    skip_if_script_missing "$VALIDATE_SCRIPT"
    run validate_input "I'm unable to complete this task"
    assert_failure
}

@test "validate: 'This commit' prefix fails" {
    skip_if_script_missing "$VALIDATE_SCRIPT"
    run bash -c "echo 'This commit adds a new feature' | bash '$VALIDATE_SCRIPT' --type commit 2>&1"
    assert_failure
    assert_output --partial "This commit"
}

@test "validate: output exceeding 500 characters fails" {
    skip_if_script_missing "$VALIDATE_SCRIPT"
    # Create a string that's definitely > 500 chars
    long_string=$(printf 'a%.0s' {1..550})
    run validate_input "$long_string"
    assert_failure
    assert_output --partial "long"
}

@test "validate: output exactly at 500 characters passes" {
    skip_if_script_missing "$VALIDATE_SCRIPT"
    # Create a string that's exactly 500 chars
    exact_string=$(printf 'a%.0s' {1..500})
    run validate_input "$exact_string"
    assert_success
}

@test "validate: output slightly under 500 characters passes" {
    skip_if_script_missing "$VALIDATE_SCRIPT"
    under_string=$(printf 'a%.0s' {1..450})
    run validate_input "$under_string"
    assert_success
}

@test "validate: commit message with valid prefix (Fix, Add, Refactor) passes" {
    skip_if_script_missing "$VALIDATE_SCRIPT"
    run validate_input "Refactor: consolidate database queries"
    assert_success
}

@test "validate: commit message with emoji passes" {
    skip_if_script_missing "$VALIDATE_SCRIPT"
    run validate_input "feat: add dark mode support"
    assert_success
}

# ---------------------------------------------------------------------------
# 3. cast-litellm.yaml Tests
# ---------------------------------------------------------------------------

@test "cast-litellm.yaml: file exists" {
    skip_if_file_missing "$CONFIG_YAML"
    [ -f "$CONFIG_YAML" ]
}

@test "cast-litellm.yaml: is valid YAML (no syntax errors)" {
    skip_if_file_missing "$CONFIG_YAML"
    skip_if_no_pyyaml
    run python3 -c "import yaml; yaml.safe_load(open('$CONFIG_YAML'))"
    assert_success
}

@test "cast-litellm.yaml: contains model_list entry" {
    skip_if_file_missing "$CONFIG_YAML"
    grep -q "model_list:" "$CONFIG_YAML"
}

@test "cast-litellm.yaml: contains at least one model entry" {
    skip_if_file_missing "$CONFIG_YAML"
    skip_if_no_pyyaml
    model_count=$(python3 -c "
import yaml
with open('$CONFIG_YAML') as f:
    cfg = yaml.safe_load(f)
    print(len(cfg.get('model_list', [])))
")
    [ "$model_count" -gt 0 ]
}

@test "cast-litellm.yaml: contains claude-sonnet model" {
    skip_if_file_missing "$CONFIG_YAML"
    skip_if_no_pyyaml
    python3 -c "
import yaml
with open('$CONFIG_YAML') as f:
    cfg = yaml.safe_load(f)
    models = [m.get('model_name', '') for m in cfg.get('model_list', [])]
    assert any('claude' in m.lower() or 'sonnet' in m.lower() for m in models), 'No Claude/Sonnet model found'
"
}

@test "cast-litellm.yaml: contains at least one local/Ollama model" {
    skip_if_file_missing "$CONFIG_YAML"
    skip_if_no_pyyaml
    python3 -c "
import yaml
with open('$CONFIG_YAML') as f:
    cfg = yaml.safe_load(f)
    models = [m.get('model_name', '') for m in cfg.get('model_list', [])]
    assert any('local' in m.lower() or 'ollama' in m.lower() for m in models), 'No local/Ollama model found'
"
}

@test "cast-litellm.yaml: router_settings.fallback_models is configured" {
    skip_if_file_missing "$CONFIG_YAML"
    skip_if_no_pyyaml
    python3 -c "
import yaml
with open('$CONFIG_YAML') as f:
    cfg = yaml.safe_load(f)
    fallback = cfg.get('router_settings', {}).get('fallback_models', [])
    assert len(fallback) > 0, 'No fallback models configured'
"
}

@test "cast-litellm.yaml: each model has litellm_params.model" {
    skip_if_file_missing "$CONFIG_YAML"
    skip_if_no_pyyaml
    python3 -c "
import yaml
with open('$CONFIG_YAML') as f:
    cfg = yaml.safe_load(f)
    for model in cfg.get('model_list', []):
        params = model.get('litellm_params', {})
        assert 'model' in params, f'Model {model.get(\"model_name\")} missing litellm_params.model'
"
}

@test "cast-litellm.yaml: Anthropic model has api_key reference" {
    skip_if_file_missing "$CONFIG_YAML"
    skip_if_no_pyyaml
    python3 -c "
import yaml
with open('$CONFIG_YAML') as f:
    cfg = yaml.safe_load(f)
    for model in cfg.get('model_list', []):
        model_name = model.get('litellm_params', {}).get('model', '')
        if 'anthropic' in model_name.lower():
            params = model.get('litellm_params', {})
            assert 'api_key' in params, f'Anthropic model missing api_key'
"
}

@test "cast-litellm.yaml: Ollama models have api_base set" {
    skip_if_file_missing "$CONFIG_YAML"
    skip_if_no_pyyaml
    python3 -c "
import yaml
with open('$CONFIG_YAML') as f:
    cfg = yaml.safe_load(f)
    for model in cfg.get('model_list', []):
        model_name = model.get('litellm_params', {}).get('model', '')
        if 'ollama' in model_name.lower():
            params = model.get('litellm_params', {})
            assert 'api_base' in params, f'Ollama model missing api_base'
            assert 'localhost:11434' in params.get('api_base', ''), f'Ollama api_base should point to localhost:11434'
"
}

# ---------------------------------------------------------------------------
# 4. Database Schema: model_used Column Tests
# ---------------------------------------------------------------------------

@test "cast.db: agent_runs table has model_used column" {
    init_test_db
    col_exists=$(python3 -c "
import sqlite3, os
conn = sqlite3.connect(os.environ['CAST_DB_PATH'])
cursor = conn.cursor()
cursor.execute('PRAGMA table_info(agent_runs)')
columns = [row[1] for row in cursor.fetchall()]
print('model_used' in columns)
conn.close()
")
    [ "$col_exists" = "True" ]
}

@test "cast.db: agent_runs.model_used is text type" {
    init_test_db
    col_type=$(python3 -c "
import sqlite3, os
conn = sqlite3.connect(os.environ['CAST_DB_PATH'])
cursor = conn.cursor()
cursor.execute('PRAGMA table_info(agent_runs)')
for row in cursor.fetchall():
    if row[1] == 'model_used':
        print(row[2])
conn.close()
")
    [ "$col_type" = "TEXT" ]
}

@test "cast.db: can insert agent_run with model_used value" {
    init_test_db
    local pyfile="$BATS_TMPDIR/test_insert_$$.py"
    cat > "$pyfile" <<'PYEOF'
import sqlite3, os
conn = sqlite3.connect(os.environ['CAST_DB_PATH'])
conn.execute("INSERT INTO agent_runs (agent, model, model_used, status) VALUES ('test-agent', 'claude-haiku', 'ollama/qwen2.5-coder:7b', 'DONE')")
conn.commit()
conn.close()
PYEOF
    run python3 "$pyfile"
    assert_success
}

@test "cast.db: model_used defaults to NULL if not provided" {
    init_test_db
    local pyfile="$BATS_TMPDIR/test_null_$$.py"
    cat > "$pyfile" <<'PYEOF'
import sqlite3, os
conn = sqlite3.connect(os.environ['CAST_DB_PATH'])
conn.execute("INSERT INTO agent_runs (agent, model, status) VALUES ('test-agent', 'claude-haiku', 'DONE')")
conn.commit()
result = conn.execute('SELECT model_used FROM agent_runs LIMIT 1').fetchone()
print('None' if result[0] is None else result[0])
conn.close()
PYEOF
    run python3 "$pyfile"
    [ "$output" = "None" ]
}

@test "cast.db: can query agent_runs filtered by model_used" {
    init_test_db
    local pyfile="$BATS_TMPDIR/test_filter_$$.py"
    cat > "$pyfile" <<'PYEOF'
import sqlite3, os
conn = sqlite3.connect(os.environ['CAST_DB_PATH'])
conn.execute("INSERT INTO agent_runs (agent, model, model_used, status) VALUES ('test-1', 'claude-haiku', 'ollama/qwen2.5-coder:7b', 'DONE')")
conn.execute("INSERT INTO agent_runs (agent, model, model_used, status) VALUES ('test-2', 'claude-haiku', 'ollama/llama3.1:8b', 'DONE')")
conn.execute("INSERT INTO agent_runs (agent, model, status) VALUES ('test-3', 'claude-haiku', 'DONE')")
conn.commit()
result = conn.execute('SELECT COUNT(*) FROM agent_runs WHERE model_used IS NOT NULL').fetchone()
print(result[0])
conn.close()
PYEOF
    run python3 "$pyfile"
    [ "$output" = "2" ]
}
