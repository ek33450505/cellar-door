#!/usr/bin/env bats
# test_writeback_supersession.bats — BATS test suite for Cellar Door Phase 4 supersession
# Tests the supersession logic in cast-memory-writeback.py
# These tests are designed to FAIL until Task 2 (supersession implementation) is complete.

# Resolve repo root and hook path relative to this test file
REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

setup() {
  # Ensure hook script path is available
  HOOK_SCRIPT="$REPO_DIR/scripts/cast-memory-writeback.py"

  # Create temp DB for this test (separate from real cast.db)
  export TMPDIR_TEST="$(mktemp -d)"
  export CAST_DB_PATH="${TMPDIR_TEST}/cast_test.db"
  export CAST_COG_ENABLED=1

  # Create agent_memories table with full schema including supersession columns
  python3 - <<'EOF'
import sqlite3, os
db = os.environ['CAST_DB_PATH']
conn = sqlite3.connect(db)
conn.execute("""CREATE TABLE agent_memories (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  agent TEXT,
  type TEXT,
  name TEXT,
  description TEXT,
  content TEXT,
  source_type TEXT,
  confidence REAL,
  importance REAL,
  decay_rate REAL,
  valid_from TEXT,
  valid_to TEXT,
  superseded_by INTEGER,
  embedding BLOB,
  created_at TEXT,
  updated_at TEXT
)""")
conn.commit()
conn.close()
EOF
}

teardown() {
  if [[ -n "${TMPDIR_TEST:-}" && -d "$TMPDIR_TEST" ]]; then
    rm -rf "${TMPDIR_TEST}"
  fi
}

# ── Test 1: New fact inserts cleanly ──────────────────────────────────────────
@test "Test 1: new fact inserts cleanly with valid_to IS NULL" {
  PAYLOAD=$(jq -n \
    --arg agent "researcher" \
    --arg output "## Facts
name: test-foo | type: feedback | content: First version of foo fact
" \
    '{agent_name: $agent, output: $output}')

  run bash -c "
    echo '$PAYLOAD' | CAST_COG_ENABLED=1 python3 '$HOOK_SCRIPT'
  "
  [[ "$status" -eq 0 ]]

  # Assert: 1 row inserted
  COUNT=$(sqlite3 "$CAST_DB_PATH" "SELECT count(*) FROM agent_memories WHERE agent='shared';")
  [[ "$COUNT" -eq 1 ]]

  # Assert: valid_to IS NULL for the new row
  VALID_TO=$(sqlite3 "$CAST_DB_PATH" "SELECT valid_to FROM agent_memories WHERE agent='shared' AND name='test-foo';")
  [[ -z "$VALID_TO" || "$VALID_TO" == "None" ]]
}

# ── Test 2: Duplicate name triggers supersession ──────────────────────────────
@test "Test 2: duplicate name triggers supersession (old row has valid_to and superseded_by)" {
  # Insert first version manually with valid_to IS NULL
  sqlite3 "$CAST_DB_PATH" \
    "INSERT INTO agent_memories (agent, type, name, description, content, source_type, confidence, created_at, updated_at, valid_to) VALUES ('shared', 'feedback', 'test-foo', 'v1', 'First version', 'inference', 1.0, datetime('now'), datetime('now'), NULL);"

  PAYLOAD=$(jq -n \
    --arg agent "researcher" \
    --arg output "## Facts
name: test-foo | type: feedback | content: Second version of foo fact
" \
    '{agent_name: $agent, output: $output}')

  run bash -c "
    echo '$PAYLOAD' | CAST_COG_ENABLED=1 python3 '$HOOK_SCRIPT'
  "
  [[ "$status" -eq 0 ]]

  # Assert: 2 rows total
  COUNT=$(sqlite3 "$CAST_DB_PATH" "SELECT count(*) FROM agent_memories WHERE agent='shared' AND name='test-foo';")
  [[ "$COUNT" -eq 2 ]]

  # Assert: old row has valid_to IS NOT NULL
  OLD_VALID_TO=$(sqlite3 "$CAST_DB_PATH" "SELECT valid_to FROM agent_memories WHERE agent='shared' AND name='test-foo' ORDER BY id ASC LIMIT 1;")
  [[ -n "$OLD_VALID_TO" && "$OLD_VALID_TO" != "None" ]]

  # Assert: old row has superseded_by = new_id
  OLD_ID=$(sqlite3 "$CAST_DB_PATH" "SELECT id FROM agent_memories WHERE agent='shared' AND name='test-foo' ORDER BY id ASC LIMIT 1;")
  NEW_ID=$(sqlite3 "$CAST_DB_PATH" "SELECT id FROM agent_memories WHERE agent='shared' AND name='test-foo' ORDER BY id DESC LIMIT 1;")
  OLD_SUPERSEDED_BY=$(sqlite3 "$CAST_DB_PATH" "SELECT superseded_by FROM agent_memories WHERE id=$OLD_ID;")
  [[ "$OLD_SUPERSEDED_BY" == "$NEW_ID" ]]

  # Assert: new row has valid_to IS NULL
  NEW_VALID_TO=$(sqlite3 "$CAST_DB_PATH" "SELECT valid_to FROM agent_memories WHERE id=$NEW_ID;")
  [[ -z "$NEW_VALID_TO" || "$NEW_VALID_TO" == "None" ]]
}

# ── Test 3: Concurrent names are independent ─────────────────────────────────
@test "Test 3: inserting new name=foo supersedes only foo, leaves bar untouched" {
  # Insert first version of foo
  sqlite3 "$CAST_DB_PATH" \
    "INSERT INTO agent_memories (agent, type, name, description, content, source_type, confidence, created_at, updated_at, valid_to) VALUES ('shared', 'feedback', 'test-foo', 'v1', 'First foo', 'inference', 1.0, datetime('now'), datetime('now'), NULL);"

  # Insert first version of bar
  sqlite3 "$CAST_DB_PATH" \
    "INSERT INTO agent_memories (agent, type, name, description, content, source_type, confidence, created_at, updated_at, valid_to) VALUES ('shared', 'feedback', 'test-bar', 'v1', 'First bar', 'inference', 1.0, datetime('now'), datetime('now'), NULL);"

  PAYLOAD=$(jq -n \
    --arg agent "researcher" \
    --arg output "## Facts
name: test-foo | type: feedback | content: Second version of foo
" \
    '{agent_name: $agent, output: $output}')

  run bash -c "
    echo '$PAYLOAD' | CAST_COG_ENABLED=1 python3 '$HOOK_SCRIPT'
  "
  [[ "$status" -eq 0 ]]

  # Assert: 3 rows total (old foo, new foo, bar)
  COUNT=$(sqlite3 "$CAST_DB_PATH" "SELECT count(*) FROM agent_memories WHERE agent='shared';")
  [[ "$COUNT" -eq 3 ]]

  # Assert: foo was superseded (has valid_to)
  FOO_SUPERSEDED=$(sqlite3 "$CAST_DB_PATH" "SELECT count(*) FROM agent_memories WHERE agent='shared' AND name='test-foo' AND valid_to IS NOT NULL;")
  [[ "$FOO_SUPERSEDED" -eq 1 ]]

  # Assert: bar is still current (valid_to IS NULL)
  BAR_CURRENT=$(sqlite3 "$CAST_DB_PATH" "SELECT count(*) FROM agent_memories WHERE agent='shared' AND name='test-bar' AND valid_to IS NULL;")
  [[ "$BAR_CURRENT" -eq 1 ]]

  # Assert: no bar row has valid_to set
  BAR_SUPERSEDED=$(sqlite3 "$CAST_DB_PATH" "SELECT count(*) FROM agent_memories WHERE agent='shared' AND name='test-bar' AND valid_to IS NOT NULL;")
  [[ "$BAR_SUPERSEDED" -eq 0 ]]
}

# ── Test 4: Malformed agent output (no Facts block) ──────────────────────────
@test "Test 4: malformed agent output with no Facts block produces 0 rows, exits 0" {
  PAYLOAD=$(jq -n \
    --arg agent "researcher" \
    --arg output "This is some agent output but it has no Facts block in it.
Just regular text and no structured facts.
" \
    '{agent_name: $agent, output: $output}')

  run bash -c "
    echo '$PAYLOAD' | CAST_COG_ENABLED=1 python3 '$HOOK_SCRIPT'
  "
  [[ "$status" -eq 0 ]]

  # Assert: 0 rows inserted
  COUNT=$(sqlite3 "$CAST_DB_PATH" "SELECT count(*) FROM agent_memories WHERE agent='shared';")
  [[ "$COUNT" -eq 0 ]]
}

# ── Test 5: CAST_COG_ENABLED=0 exits 0 without writing ──────────────────────
@test "Test 5: CAST_COG_ENABLED=0 exits 0 with no DB writes" {
  PAYLOAD=$(jq -n \
    --arg agent "researcher" \
    --arg output "## Facts
name: should-not-write | type: feedback | content: This fact is skipped
" \
    '{agent_name: $agent, output: $output}')

  run bash -c "
    echo '$PAYLOAD' | CAST_COG_ENABLED=0 python3 '$HOOK_SCRIPT'
  "
  [[ "$status" -eq 0 ]]

  # Assert: 0 rows inserted
  COUNT=$(sqlite3 "$CAST_DB_PATH" "SELECT count(*) FROM agent_memories WHERE agent='shared';")
  [[ "$COUNT" -eq 0 ]]
}

# ── Test 6: Two facts with same name in a single batch — last-writer-wins ─────
@test "Test 6: two facts with same name in one batch — first is superseded by second" {
  # Emit a single ## Facts block with two entries sharing name=foo
  PAYLOAD=$(jq -n \
    --arg agent "researcher" \
    --arg output "## Facts
name: foo | type: feedback | content: First foo in batch
name: foo | type: feedback | content: Second foo in batch
" \
    '{agent_name: $agent, output: $output}')

  run bash -c "
    echo '$PAYLOAD' | CAST_COG_ENABLED=1 python3 '$HOOK_SCRIPT'
  "
  [[ "$status" -eq 0 ]]

  # Assert: 2 rows total for name=foo
  COUNT=$(sqlite3 "$CAST_DB_PATH" "SELECT count(*) FROM agent_memories WHERE agent='shared' AND name='foo';")
  [[ "$COUNT" -eq 2 ]]

  # Assert: first row (lower id) has valid_to IS NOT NULL
  FIRST_ID=$(sqlite3 "$CAST_DB_PATH" "SELECT id FROM agent_memories WHERE agent='shared' AND name='foo' ORDER BY id ASC LIMIT 1;")
  FIRST_VALID_TO=$(sqlite3 "$CAST_DB_PATH" "SELECT valid_to FROM agent_memories WHERE id=${FIRST_ID};")
  [[ -n "$FIRST_VALID_TO" && "$FIRST_VALID_TO" != "None" ]]

  # Assert: first row has superseded_by pointing to the second row
  SECOND_ID=$(sqlite3 "$CAST_DB_PATH" "SELECT id FROM agent_memories WHERE agent='shared' AND name='foo' ORDER BY id DESC LIMIT 1;")
  FIRST_SUPERSEDED_BY=$(sqlite3 "$CAST_DB_PATH" "SELECT superseded_by FROM agent_memories WHERE id=${FIRST_ID};")
  [[ "$FIRST_SUPERSEDED_BY" == "$SECOND_ID" ]]

  # Assert: second row has valid_to IS NULL (it is the current version)
  SECOND_VALID_TO=$(sqlite3 "$CAST_DB_PATH" "SELECT valid_to FROM agent_memories WHERE id=${SECOND_ID};")
  [[ -z "$SECOND_VALID_TO" || "$SECOND_VALID_TO" == "None" ]]
}
