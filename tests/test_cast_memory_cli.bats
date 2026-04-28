#!/usr/bin/env bats
# test_cast_memory_cli.bats — BATS tests for bin/cast-memory CLI
# Covers: history, at, ls subcommands with a seeded supersession chain

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
CAST_MEMORY_CLI="${REPO_DIR}/bin/cast-memory"

setup() {
  export TMPDIR_TEST="$(mktemp -d)"
  export CAST_DB_PATH="${TMPDIR_TEST}/cast_test.db"

  # Seed a 3-row supersession chain: v1 -> v2 -> v3 (v3 current)
  python3 - <<'EOF'
import sqlite3, os
db = os.environ['CAST_DB_PATH']
conn = sqlite3.connect(db)
conn.execute("""CREATE TABLE agent_memories (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  agent TEXT, type TEXT, name TEXT, description TEXT, content TEXT,
  source_type TEXT, confidence REAL, importance REAL, decay_rate REAL,
  valid_from TEXT, valid_to TEXT, superseded_by INTEGER,
  embedding BLOB, created_at TEXT, updated_at TEXT
)""")

# v1: superseded by v2
conn.execute("""
  INSERT INTO agent_memories
    (agent, type, name, content, valid_from, valid_to, superseded_by, created_at, updated_at)
  VALUES
    ('shared', 'feedback', 'test_fact', 'v1 content',
     '2026-01-01T00:00:00Z', '2026-02-01T00:00:00Z', 2,
     '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z')
""")
# v2: superseded by v3
conn.execute("""
  INSERT INTO agent_memories
    (agent, type, name, content, valid_from, valid_to, superseded_by, created_at, updated_at)
  VALUES
    ('shared', 'feedback', 'test_fact', 'v2 content',
     '2026-02-01T00:00:00Z', '2026-03-01T00:00:00Z', 3,
     '2026-02-01T00:00:00Z', '2026-02-01T00:00:00Z')
""")
# v3: current
conn.execute("""
  INSERT INTO agent_memories
    (agent, type, name, content, valid_from, valid_to, superseded_by, created_at, updated_at)
  VALUES
    ('shared', 'feedback', 'test_fact', 'v3 content',
     '2026-03-01T00:00:00Z', NULL, NULL,
     '2026-03-01T00:00:00Z', '2026-03-01T00:00:00Z')
""")
# Unrelated fact under agent='planner'
conn.execute("""
  INSERT INTO agent_memories
    (agent, type, name, content, valid_from, valid_to, created_at, updated_at)
  VALUES
    ('planner', 'project', 'planner_fact', 'planner content',
     '2026-01-01T00:00:00Z', NULL,
     '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z')
""")
conn.commit()
conn.close()
EOF
}

teardown() {
  rm -rf "${TMPDIR_TEST}"
}

@test "history: all 3 rows for test_fact appear, ordered by id ASC" {
  run bash "$CAST_MEMORY_CLI" history test_fact
  [ "$status" -eq 0 ]
  # All three version contents should appear
  echo "$output" | grep -q "v1 content"
  echo "$output" | grep -q "v2 content"
  echo "$output" | grep -q "v3 content"
  # v1 should come before v3 (ascending order by id)
  v1_line=$(echo "$output" | grep -n "v1 content" | cut -d: -f1)
  v3_line=$(echo "$output" | grep -n "v3 content" | cut -d: -f1)
  [ "$v1_line" -lt "$v3_line" ]
}

@test "at: timestamp between v1 and v2 returns v1 only, not v2 or v3" {
  run bash "$CAST_MEMORY_CLI" at "2026-01-15T00:00:00Z"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "v1 content"
  ! echo "$output" | grep -q "v2 content"
  ! echo "$output" | grep -q "v3 content"
}

@test "at: timestamp between v2 and v3 returns v2 only" {
  run bash "$CAST_MEMORY_CLI" at "2026-02-15T00:00:00Z"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "v2 content"
  ! echo "$output" | grep -q "v1 content"
  ! echo "$output" | grep -q "v3 content"
}

@test "at: 'now' returns only v3 (current row)" {
  run bash "$CAST_MEMORY_CLI" at now
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "v3 content"
  ! echo "$output" | grep -q "v1 content"
  ! echo "$output" | grep -q "v2 content"
}

@test "ls: only v3 (valid_to IS NULL) appears for test_fact" {
  run bash "$CAST_MEMORY_CLI" ls
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "test_fact"
  # Should show only 1 test_fact row (v3)
  count=$(echo "$output" | grep -c "test_fact" || true)
  [ "$count" -eq 1 ]
  ! echo "$output" | grep -q "v1 content"
  ! echo "$output" | grep -q "v2 content"
}

@test "ls --agent planner: returns planner_fact, not test_fact" {
  run bash "$CAST_MEMORY_CLI" ls --agent planner
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "planner_fact"
  ! echo "$output" | grep -q "test_fact"
}

@test "ls --agent nonexistent: returns 0 data rows" {
  run bash "$CAST_MEMORY_CLI" ls --agent nonexistent
  [ "$status" -eq 0 ]
  # Should have header row but no data
  data_rows=$(echo "$output" | grep -v "^id\|^-\|^$" | wc -l | tr -d ' ')
  [ "$data_rows" -eq 0 ]
}

@test "no args: exits 1 and prints usage to stderr" {
  run bash "$CAST_MEMORY_CLI"
  [ "$status" -eq 1 ]
  echo "$output" | grep -iq "usage"
}

@test "history: missing name arg exits 1 with error" {
  run bash "$CAST_MEMORY_CLI" history
  [ "$status" -eq 1 ]
  echo "$output" | grep -iq "error"
}

@test "at: missing timestamp arg exits 1 with error" {
  run bash "$CAST_MEMORY_CLI" at
  [ "$status" -eq 1 ]
  echo "$output" | grep -iq "error"
}
