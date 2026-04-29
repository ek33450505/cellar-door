#!/usr/bin/env bats
# test_cast_memory_prune.bats — BATS tests for cast-memory prune subcommand
# Covers: --before required, dry-run, type filter, actual deletion, live-fact protection

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
CAST_MEMORY_CLI="${REPO_DIR}/bin/cast-memory"

setup() {
  export CAST_DB_PATH="$BATS_TMPDIR/prune_test_$BATS_TEST_NUMBER.db"
  sqlite3 "$CAST_DB_PATH" <<'SQL'
CREATE TABLE agent_memories (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  agent TEXT NOT NULL,
  type TEXT NOT NULL DEFAULT 'user',
  name TEXT NOT NULL,
  description TEXT,
  content TEXT,
  source_type TEXT,
  valid_from TEXT DEFAULT (datetime('now')),
  valid_to TEXT,
  created_at TEXT DEFAULT (datetime('now')),
  updated_at TEXT DEFAULT (datetime('now')),
  importance REAL DEFAULT 0.5,
  decay_rate REAL DEFAULT 0.995,
  superseded_by INTEGER,
  confidence REAL DEFAULT 1.0
);
-- Old superseded row (100 days ago)
INSERT INTO agent_memories (agent,type,name,content,source_type,valid_to,created_at)
  VALUES ('planner','feedback','old_fact','v1','agent',
          datetime('now','-100 days'), datetime('now','-100 days'));
-- Old legacy row (200 days ago, valid_to NULL)
INSERT INTO agent_memories (agent,type,name,content,source_type,created_at)
  VALUES ('shared','project','legacy_old','content','legacy', datetime('now','-200 days'));
-- Current live fact (valid_to NULL, non-legacy, also old created_at — must NOT be pruned)
INSERT INTO agent_memories (agent,type,name,content,source_type,created_at)
  VALUES ('shared','feedback','live_fact','content','agent', datetime('now','-200 days'));
SQL
}

teardown() {
  rm -f "$CAST_DB_PATH"
}

@test "prune without --before exits non-zero" {
  run bash "$CAST_MEMORY_CLI" prune --dry-run
  [ "$status" -ne 0 ]
}

@test "dry-run with no matches prints 'No rows match' and exits 0" {
  # Wipe the old rows and insert only brand-new rows (just created).
  # With a 50d window, no rows are older than 50 days — so count = 0.
  sqlite3 "$CAST_DB_PATH" "DELETE FROM agent_memories;"
  sqlite3 "$CAST_DB_PATH" <<'SQL'
INSERT INTO agent_memories (agent,type,name,content,source_type,created_at)
  VALUES ('shared','feedback','fresh_fact','content','agent', datetime('now'));
SQL
  run bash "$CAST_MEMORY_CLI" prune --before 50d --dry-run
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "No rows match"
}

@test "dry-run with matching old superseded rows prints correct count and exits 0" {
  # 90d window: both the old superseded row (100d) and old legacy row (200d) match
  run bash "$CAST_MEMORY_CLI" prune --before 90d --dry-run
  [ "$status" -eq 0 ]
  # Should mention dry-run and count 2
  echo "$output" | grep -q "\[dry-run\]"
  echo "$output" | grep -q "2 row(s)"
  # No actual deletion occurred
  count=$(sqlite3 "$CAST_DB_PATH" "SELECT COUNT(*) FROM agent_memories;")
  [ "$count" -eq 3 ]
}

@test "dry-run with --type filter counts only matching type" {
  # Only 'feedback' type rows match within the 90d window
  # old_fact is type='feedback' (superseded, 100d old) → 1 match
  # legacy_old is type='project' → excluded by type filter
  run bash "$CAST_MEMORY_CLI" prune --before 90d --type feedback --dry-run
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "1 row(s)"
  # No rows deleted
  count=$(sqlite3 "$CAST_DB_PATH" "SELECT COUNT(*) FROM agent_memories;")
  [ "$count" -eq 3 ]
}

@test "actual deletion removes exactly the expected rows when confirmed with y" {
  # Pipe 'y' as confirmation; 90d window hits 2 rows (old superseded + old legacy)
  run bash -c "echo 'y' | bash '$CAST_MEMORY_CLI' prune --before 90d"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Deleted 2 row(s)"
  # Only the live_fact row should remain
  count=$(sqlite3 "$CAST_DB_PATH" "SELECT COUNT(*) FROM agent_memories;")
  [ "$count" -eq 1 ]
  remaining=$(sqlite3 "$CAST_DB_PATH" "SELECT name FROM agent_memories;")
  [ "$remaining" = "live_fact" ]
}

@test "live non-legacy rows with valid_to NULL are NOT pruned even when old" {
  # live_fact: source_type='agent', valid_to=NULL, created_at=200 days ago
  # It must survive even a 1d prune window
  run bash -c "echo 'y' | bash '$CAST_MEMORY_CLI' prune --before 1d"
  [ "$status" -eq 0 ]
  live_count=$(sqlite3 "$CAST_DB_PATH" "SELECT COUNT(*) FROM agent_memories WHERE name='live_fact';")
  [ "$live_count" -eq 1 ]
}

@test "invalid --type value exits non-zero with descriptive error" {
  run bash "$CAST_MEMORY_CLI" prune --before 90d --type invalid_type --dry-run
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "invalid --type"
  echo "$output" | grep -q "user, feedback, project, reference, procedural"
}
