#!/usr/bin/env bats
# test_migrate_phase1.bats — BATS test suite for Cellar Door Phase 1 migration
# Tests the migration script at ~/Projects/personal/cellar-door/scripts/migrate_phase1.py

# Resolve repo root relative to this test file
REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

# Setup: copy cast.db to temp location, set CAST_DB_PATH
setup() {
  # Create temp DB for this test
  export CAST_DB_PATH="$BATS_TMPDIR/test.db"

  # Copy the real cast.db to temp location for testing (do not mutate the real DB)
  cp ~/.claude/cast.db "$CAST_DB_PATH"
}

# Cleanup: remove temp DB after test
teardown() {
  if [[ -f "$CAST_DB_PATH" ]]; then
    rm -f "$CAST_DB_PATH"
  fi
}

# ── Migration script basic behavior ──────────────────────────────────────────

@test "migration exits 0 on first run" {
  run python3 "$REPO_DIR/scripts/migrate_phase1.py"
  [[ "$status" -eq 0 ]]
}

@test "migration is idempotent — exits 0 on second run" {
  python3 "$REPO_DIR/scripts/migrate_phase1.py"
  run python3 "$REPO_DIR/scripts/migrate_phase1.py"
  [[ "$status" -eq 0 ]]
}

# ── Schema validation: new columns ───────────────────────────────────────────

@test "all 7 new columns exist after migration" {
  python3 "$REPO_DIR/scripts/migrate_phase1.py"

  # Check each column is present in PRAGMA table_info output
  run sqlite3 "$CAST_DB_PATH" "PRAGMA table_info(agent_memories);"

  # Verify all 7 columns are present
  [[ "$output" == *"importance"* ]]
  [[ "$output" == *"decay_rate"* ]]
  [[ "$output" == *"valid_from"* ]]
  [[ "$output" == *"valid_to"* ]]
  [[ "$output" == *"superseded_by"* ]]
  [[ "$output" == *"source_type"* ]]
  [[ "$output" == *"confidence"* ]]
}

# ── FTS5 virtual table ───────────────────────────────────────────────────────

@test "FTS5 table exists after migration" {
  python3 "$REPO_DIR/scripts/migrate_phase1.py"
  run sqlite3 "$CAST_DB_PATH" \
    "SELECT name FROM sqlite_master WHERE type='table' AND name='agent_memories_fts';"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"agent_memories_fts"* ]]
}

@test "FTS5 row count matches agent_memories count (48 rows)" {
  python3 "$REPO_DIR/scripts/migrate_phase1.py"
  run sqlite3 "$CAST_DB_PATH" "SELECT COUNT(*) FROM agent_memories_fts;"
  [[ "$status" -eq 0 ]]
  [[ "$output" =~ ^[0-9]+$ ]]  # numeric output
  [[ "$output" -eq 48 ]]
}

# ── Backfill validation ──────────────────────────────────────────────────────

@test "legacy rows have source_type='legacy' after backfill" {
  python3 "$REPO_DIR/scripts/migrate_phase1.py"
  run sqlite3 "$CAST_DB_PATH" \
    "SELECT COUNT(*) FROM agent_memories WHERE source_type='legacy';"
  [[ "$status" -eq 0 ]]
  [[ "$output" =~ ^[0-9]+$ ]]
  [[ "$output" -eq 48 ]]
}

# ── UNIQUE index validation ──────────────────────────────────────────────────

@test "UNIQUE index idx_agent_memories_agent_name exists on (agent, name)" {
  python3 "$REPO_DIR/scripts/migrate_phase1.py"
  run sqlite3 "$CAST_DB_PATH" \
    "SELECT name FROM sqlite_master WHERE type='index' AND name='idx_agent_memories_agent_name';"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"idx_agent_memories_agent_name"* ]]
}

# ── FTS5 trigger validation: insert ──────────────────────────────────────────

@test "insert trigger keeps FTS5 in sync" {
  python3 "$REPO_DIR/scripts/migrate_phase1.py"

  # Insert a new row into agent_memories
  sqlite3 "$CAST_DB_PATH" \
    "INSERT INTO agent_memories (agent, type, name, description, content) VALUES ('test','user','trigger_test','desc','content_val');"

  # Verify the row appears in FTS5
  run sqlite3 "$CAST_DB_PATH" \
    "SELECT COUNT(*) FROM agent_memories_fts WHERE name='trigger_test';"
  [[ "$status" -eq 0 ]]
  [[ "$output" -eq 1 ]]
}

# ── FTS5 trigger validation: delete ──────────────────────────────────────────

@test "delete trigger removes from FTS5" {
  python3 "$REPO_DIR/scripts/migrate_phase1.py"

  # Insert a test row
  sqlite3 "$CAST_DB_PATH" \
    "INSERT INTO agent_memories (agent, type, name, description, content) VALUES ('test','user','del_test','d','c');"

  # Delete the row
  sqlite3 "$CAST_DB_PATH" \
    "DELETE FROM agent_memories WHERE name='del_test';"

  # Verify the row is removed from FTS5
  run sqlite3 "$CAST_DB_PATH" \
    "SELECT COUNT(*) FROM agent_memories_fts WHERE name='del_test';"
  [[ "$status" -eq 0 ]]
  [[ "$output" -eq 0 ]]
}
