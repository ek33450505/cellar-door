#!/usr/bin/env bats
# test_migrate_phase1.bats — BATS test suite for Cellar Door Phase 1 migration
# Tests the migration script at ~/Projects/personal/cellar-door/scripts/migrate_phase1.py

# Resolve repo root relative to this test file
REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

# Setup: create a fresh minimal SQLite DB with deterministic pre-migration rows
setup() {
  export CAST_DB_PATH="$BATS_TMPDIR/test_phase1_$BATS_TEST_NUMBER.db"
  # Create a minimal pre-migration schema (no Phase 1 columns yet)
  sqlite3 "$CAST_DB_PATH" <<'SQL'
CREATE TABLE agent_memories (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  agent TEXT NOT NULL,
  type TEXT NOT NULL DEFAULT 'user',
  name TEXT NOT NULL,
  description TEXT,
  content TEXT,
  created_at TEXT DEFAULT (datetime('now')),
  updated_at TEXT DEFAULT (datetime('now'))
);
INSERT INTO agent_memories (agent, type, name, description, content) VALUES
  ('planner',   'user',     'fact1', 'desc1', 'content1'),
  ('planner',   'feedback', 'fact2', 'desc2', 'content2'),
  ('shared',    'project',  'fact3', 'desc3', 'content3'),
  ('debugger',  'user',     'fact4', 'desc4', 'content4'),
  ('committer', 'reference','fact5', 'desc5', 'content5');
SQL
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

@test "FTS5 row count matches agent_memories count" {
  python3 "$REPO_DIR/scripts/migrate_phase1.py"
  # Get both counts and compare them — no hardcoded row number
  fts_count=$(sqlite3 "$CAST_DB_PATH" "SELECT COUNT(*) FROM agent_memories_fts;")
  am_count=$(sqlite3  "$CAST_DB_PATH" "SELECT COUNT(*) FROM agent_memories;")
  [[ "$status" -eq 0 ]]
  [[ "$fts_count" -eq "$am_count" ]]
}

# ── Backfill validation ──────────────────────────────────────────────────────

@test "legacy rows have source_type='legacy' after backfill" {
  python3 "$REPO_DIR/scripts/migrate_phase1.py"
  legacy_count=$(sqlite3 "$CAST_DB_PATH" "SELECT COUNT(*) FROM agent_memories WHERE source_type='legacy';")
  total_count=$(sqlite3  "$CAST_DB_PATH" "SELECT COUNT(*) FROM agent_memories;")
  [[ "$legacy_count" -eq "$total_count" ]]
}

# ── UNIQUE index validation ──────────────────────────────────────────────────

@test "UNIQUE index idx_agent_memories_agent_name does NOT exist (Phase 1.5 drop)" {
  python3 "$REPO_DIR/scripts/migrate_phase1.py"
  run sqlite3 "$CAST_DB_PATH" \
    "SELECT name FROM sqlite_master WHERE type='index' AND name='idx_agent_memories_agent_name';"
  [[ "$status" -eq 0 ]]
  [[ -z "$output" ]]  # index must NOT be present post-Phase-1.5
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
