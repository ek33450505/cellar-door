#!/usr/bin/env bats
# test_parity_writeback.bats — Cellar Door Phase 5: write-back (write) parity tests.
#
# Verifies that cast-memory-writeback.py parses ## Facts blocks and writes rows
# to agent_memories identically on both Claude and CCR/Ollama paths.

load 'helpers/parity_helper.bash'

setup()    { parity_setup; }
teardown() { parity_teardown; }

WRITEBACK_SCRIPT="$REPO_DIR/scripts/cast-memory-writeback.py"

# Helper: write SubagentStop JSON payload to a temp file.
# Uses Python to correctly JSON-encode the facts block string.
# Sets PAYLOAD_FILE (path to temp file caller can pipe from).
_write_payload_file() {
  local agent_type="$1" facts_block="$2"
  PAYLOAD_FILE="$BATS_TMPDIR/payload_$$.json"
  python3 - <<PYEOF
import json
agent_type = ${agent_type@Q}
facts_block = ${facts_block@Q}
payload = {"agent_type": agent_type, "last_assistant_message": facts_block}
with open(${PAYLOAD_FILE@Q}, "w") as f:
    json.dump(payload, f)
PYEOF
}

# Constant facts block used across most tests
FACTS_BLOCK="## Facts
name: parity_wb_test | type: feedback | content: write-back parity verified under both backends"

# ── Test 1: trusted agent with valid facts block exits 0 ────────────────────

@test "write-back exits 0 for trusted agent with valid facts block" {
  python3 -c "
import json, sys
payload = {'agent_type': 'researcher', 'last_assistant_message': '## Facts\nname: parity_wb_test | type: feedback | content: write-back parity verified under both backends'}
print(json.dumps(payload))
" | CAST_COG_ENABLED=1 CAST_DB_PATH="$CAST_DB_PATH" \
    python3 "$WRITEBACK_SCRIPT"
}

# ── Test 2: fact is inserted into agent_memories ─────────────────────────────

@test "write-back inserts fact into agent_memories" {
  python3 -c "
import json
payload = {'agent_type': 'researcher', 'last_assistant_message': '## Facts\nname: parity_wb_test | type: feedback | content: write-back parity verified under both backends'}
print(json.dumps(payload))
" | CAST_COG_ENABLED=1 CAST_DB_PATH="$CAST_DB_PATH" \
    python3 "$WRITEBACK_SCRIPT"

  count=$(sqlite3 "$CAST_DB_PATH" \
    "SELECT COUNT(*) FROM agent_memories WHERE name='parity_wb_test';")
  [[ "$count" -gt 0 ]]
}

# ── Test 3: untrusted agent type is skipped ──────────────────────────────────

@test "write-back skips untrusted agent type" {
  python3 -c "
import json
payload = {'agent_type': 'unknown-agent', 'last_assistant_message': '## Facts\nname: parity_wb_test | type: feedback | content: write-back parity verified under both backends'}
print(json.dumps(payload))
" | CAST_COG_ENABLED=1 CAST_DB_PATH="$CAST_DB_PATH" \
    python3 "$WRITEBACK_SCRIPT"

  run bash -c "sqlite3 \"$CAST_DB_PATH\" \"SELECT COUNT(*) FROM agent_memories WHERE name='parity_wb_test';\""
  [[ "$output" -eq 0 ]]
}

# ── Test 4: malformed fact line does not crash ───────────────────────────────

@test "write-back handles malformed fact line without crashing" {
  run python3 -c "
import json, subprocess, os, sys
facts = '## Facts\nname: bad-line\nname: parity_wb_valid | type: feedback | content: this line is good'
payload = json.dumps({'agent_type': 'researcher', 'last_assistant_message': facts})
env = {**os.environ, 'CAST_COG_ENABLED': '1', 'CAST_DB_PATH': os.environ['CAST_DB_PATH']}
result = subprocess.run(['python3', '$WRITEBACK_SCRIPT'], input=payload, capture_output=True, text=True, env=env)
sys.exit(result.returncode)
"
  [[ "$status" -eq 0 ]]

  valid_count=$(sqlite3 "$CAST_DB_PATH" \
    "SELECT COUNT(*) FROM agent_memories WHERE name='parity_wb_valid';")
  [[ "$valid_count" -eq 1 ]]
}

# ── Test 5: write-back supersedes existing fact with same name ───────────────

@test "write-back supersedes existing fact with same name" {
  local fact_name="parity_supersede_test"

  # Seed an existing current row directly
  sqlite3 "$CAST_DB_PATH" \
    "INSERT INTO agent_memories (agent, type, name, content, source_type, confidence, importance, decay_rate, valid_from, valid_to, created_at, updated_at)
     VALUES ('shared', 'feedback', '${fact_name}', 'original content', 'inference', 1.0, 0.5, 0.0, datetime('now'), NULL, datetime('now'), datetime('now'));"

  python3 -c "
import json
fact_name = '${fact_name}'
payload = {'agent_type': 'researcher', 'last_assistant_message': '## Facts\nname: ' + fact_name + ' | type: feedback | content: updated content via write-back'}
print(json.dumps(payload))
" | CAST_COG_ENABLED=1 CAST_DB_PATH="$CAST_DB_PATH" \
    python3 "$WRITEBACK_SCRIPT"

  # Old row must now have valid_to set (not NULL)
  old_valid_to=$(sqlite3 "$CAST_DB_PATH" \
    "SELECT valid_to FROM agent_memories WHERE agent='shared' AND name='${fact_name}' ORDER BY id ASC LIMIT 1;")
  [[ -n "$old_valid_to" && "$old_valid_to" != "None" ]]
}

# ── Test 6: CCR session env produces identical write-back behavior ───────────

@test "CCR session env produces identical write-back behavior as Claude session env" {
  # Use unique names per run for idempotency
  local claude_fact="parity_ccr_claude_$$"
  local ccr_fact="parity_ccr_session_$$"

  # Claude env run (no CCR_SESSION)
  python3 -c "
import json
payload = {'agent_type': 'researcher', 'last_assistant_message': '## Facts\nname: ${claude_fact} | type: feedback | content: written by claude-env path'}
print(json.dumps(payload))
" | CAST_COG_ENABLED=1 CAST_DB_PATH="$CAST_DB_PATH" \
    python3 "$WRITEBACK_SCRIPT"

  # CCR session env run (adds CCR_SESSION=1)
  python3 -c "
import json
payload = {'agent_type': 'researcher', 'last_assistant_message': '## Facts\nname: ${ccr_fact} | type: feedback | content: written by ccr-env path'}
print(json.dumps(payload))
" | CAST_COG_ENABLED=1 CAST_DB_PATH="$CAST_DB_PATH" CCR_SESSION=1 \
    python3 "$WRITEBACK_SCRIPT"

  # Both facts must be present in agent_memories
  claude_count=$(sqlite3 "$CAST_DB_PATH" \
    "SELECT COUNT(*) FROM agent_memories WHERE name='${claude_fact}';")
  ccr_count=$(sqlite3 "$CAST_DB_PATH" \
    "SELECT COUNT(*) FROM agent_memories WHERE name='${ccr_fact}';")

  [[ "$claude_count" -eq 1 ]]
  [[ "$ccr_count" -eq 1 ]]
}
