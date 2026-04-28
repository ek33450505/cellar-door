#!/usr/bin/env bats
# test_writeback_parser.bats — BATS test suite for Cellar Door Phase 3 SubagentStop hook
# Tests the writeback parser at ~/Projects/personal/cellar-door/scripts/cast-memory-writeback.py

# Resolve repo root and hook path relative to this test file
REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

setup() {
  # Ensure hook script path is available
  HOOK_SCRIPT="$REPO_DIR/scripts/cast-memory-writeback.py"

  # Create temp DB for this test (separate from real cast.db)
  export CAST_DB_PATH="$BATS_TMPDIR/test_writeback.db"

  # Create minimal schema for agent_memories table
  sqlite3 "$CAST_DB_PATH" "CREATE TABLE IF NOT EXISTS agent_memories (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    agent       TEXT NOT NULL,
    project     TEXT,
    type        TEXT,
    name        TEXT,
    description TEXT,
    content     TEXT,
    created_at  TEXT,
    updated_at  TEXT,
    importance  REAL DEFAULT 0.5,
    decay_rate  REAL DEFAULT 0.0,
    valid_from  TEXT,
    valid_to    TEXT,
    superseded_by INTEGER,
    embedding   BLOB,
    source_type TEXT,
    confidence  REAL DEFAULT 1.0,
    UNIQUE(agent, name)
  );" || true
}

teardown() {
  if [[ -f "$CAST_DB_PATH" ]]; then
    rm -f "$CAST_DB_PATH"
  fi
}

# ── Test 1: happy path — trusted agent + valid Facts block ──────────────────

@test "happy path: researcher with valid Facts block writes 1 row, exits 0" {
  PAYLOAD=$(jq -n \
    --arg agent "researcher" \
    --arg output "## Facts
name: test-slug | type: feedback | content: This is a test fact
" \
    '{agent_name: $agent, output: $output}')

  run bash -c "
    echo '$PAYLOAD' | CAST_COG_ENABLED=1 python3 '$HOOK_SCRIPT'
  "
  [[ "$status" -eq 0 ]]

  COUNT=$(sqlite3 "$CAST_DB_PATH" "SELECT count(*) FROM agent_memories WHERE agent='shared';")
  [[ "$COUNT" -eq 1 ]]
}

# ── Test 2: ignored agent (commit) — count = 0, exit 0 ────────────────────────

@test "ignored agent (commit) produces no rows, exits 0" {
  PAYLOAD=$(jq -n \
    --arg agent "commit" \
    --arg output "## Facts
name: some-fact | type: feedback | content: This should not be written
" \
    '{agent_name: $agent, output: $output}')

  run bash -c "
    echo '$PAYLOAD' | CAST_COG_ENABLED=1 python3 '$HOOK_SCRIPT'
  "
  [[ "$status" -eq 0 ]]

  COUNT=$(sqlite3 "$CAST_DB_PATH" "SELECT count(*) FROM agent_memories WHERE agent='shared';")
  [[ "$COUNT" -eq 0 ]]
}

# ── Test 3: malformed mixed — 2 valid + 1 malformed → count = 2, exit 0 ─────

@test "malformed mixed: 2 valid facts + 1 malformed line writes 2 rows, exits 0" {
  PAYLOAD=$(jq -n \
    --arg agent "code-writer" \
    --arg output "## Facts
name: valid-fact-1 | type: user | content: First valid fact
invalid malformed line with no colons or pipes
name: valid-fact-2 | type: project | content: Second valid fact
" \
    '{agent_name: $agent, output: $output}')

  run bash -c "
    echo '$PAYLOAD' | CAST_COG_ENABLED=1 python3 '$HOOK_SCRIPT'
  "
  [[ "$status" -eq 0 ]]

  COUNT=$(sqlite3 "$CAST_DB_PATH" "SELECT count(*) FROM agent_memories WHERE agent='shared';")
  [[ "$COUNT" -eq 2 ]]
}

# ── Test 4: over-cap — 7 facts in block → count = 5 (capped), exit 0 ────────

@test "over-cap: 7 facts yields 5 written (MAX_FACTS=5), exits 0" {
  PAYLOAD=$(jq -n \
    --arg agent "planner" \
    --arg output "## Facts
name: fact-1 | type: feedback | content: Fact 1
name: fact-2 | type: feedback | content: Fact 2
name: fact-3 | type: feedback | content: Fact 3
name: fact-4 | type: feedback | content: Fact 4
name: fact-5 | type: feedback | content: Fact 5
name: fact-6 | type: feedback | content: Fact 6 (should be skipped)
name: fact-7 | type: feedback | content: Fact 7 (should be skipped)
" \
    '{agent_name: $agent, output: $output}')

  run bash -c "
    echo '$PAYLOAD' | CAST_COG_ENABLED=1 python3 '$HOOK_SCRIPT'
  "
  [[ "$status" -eq 0 ]]

  COUNT=$(sqlite3 "$CAST_DB_PATH" "SELECT count(*) FROM agent_memories WHERE agent='shared';")
  [[ "$COUNT" -eq 5 ]]
}

# ── Test 5: duplicate name — same fact twice → count = 1 (DO NOTHING), exit 0 ─

@test "duplicate name: same fact inserted twice yields 1 row (DO NOTHING), exits 0" {
  # Insert the fact once manually
  sqlite3 "$CAST_DB_PATH" "INSERT INTO agent_memories (agent, type, name, description, content, source_type, confidence, created_at, updated_at) VALUES ('shared', 'feedback', 'dup-test', 'manual insert', 'pre-inserted content', 'manual', 1.0, datetime('now'), datetime('now'));"

  PAYLOAD=$(jq -n \
    --arg agent "researcher" \
    --arg output "## Facts
name: dup-test | type: feedback | content: This should be ignored due to DO NOTHING
" \
    '{agent_name: $agent, output: $output}')

  run bash -c "
    echo '$PAYLOAD' | CAST_COG_ENABLED=1 python3 '$HOOK_SCRIPT'
  "
  [[ "$status" -eq 0 ]]

  COUNT=$(sqlite3 "$CAST_DB_PATH" "SELECT count(*) FROM agent_memories WHERE agent='shared';")
  [[ "$COUNT" -eq 1 ]]
}

# ── Test 6: feature flag off (CAST_COG_ENABLED unset) → count = 0, exit 0 ────

@test "feature flag off (CAST_COG_ENABLED=0) produces no rows, exits 0" {
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

  COUNT=$(sqlite3 "$CAST_DB_PATH" "SELECT count(*) FROM agent_memories WHERE agent='shared';")
  [[ "$COUNT" -eq 0 ]]
}

# ── Test 7: empty Facts block — ## Facts heading with no lines → count = 0 ────

@test "empty Facts block (heading only) produces no rows, exits 0" {
  PAYLOAD=$(jq -n \
    --arg agent "code-writer" \
    --arg output "## Facts

Some other text after the empty block.
" \
    '{agent_name: $agent, output: $output}')

  run bash -c "
    echo '$PAYLOAD' | CAST_COG_ENABLED=1 python3 '$HOOK_SCRIPT'
  "
  [[ "$status" -eq 0 ]]

  COUNT=$(sqlite3 "$CAST_DB_PATH" "SELECT count(*) FROM agent_memories WHERE agent='shared';")
  [[ "$COUNT" -eq 0 ]]
}

# ── Test 8: no Facts block at all → count = 0, exit 0 ────────────────────────

@test "no Facts block at all produces no rows, exits 0" {
  PAYLOAD=$(jq -n \
    --arg agent "planner" \
    --arg output "This is some agent output but it has no Facts block in it.
Just regular text.
" \
    '{agent_name: $agent, output: $output}')

  run bash -c "
    echo '$PAYLOAD' | CAST_COG_ENABLED=1 python3 '$HOOK_SCRIPT'
  "
  [[ "$status" -eq 0 ]]

  COUNT=$(sqlite3 "$CAST_DB_PATH" "SELECT count(*) FROM agent_memories WHERE agent='shared';")
  [[ "$COUNT" -eq 0 ]]
}
