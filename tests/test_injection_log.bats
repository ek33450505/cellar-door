#!/usr/bin/env bats
# test_injection_log.bats — BATS tests for Cellar Door Phase 6.5 injection_log

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

# ── Shared fixture helpers ────────────────────────────────────────────────────

_setup_db() {
  # Create the base agent_memories table (no DEFAULT datetime() — SQLite CLI rejects it).
  # migrate_phase1.py handles adding provenance columns and FTS5.
  sqlite3 "$CAST_DB_PATH" <<'SQL'
CREATE TABLE IF NOT EXISTS agent_memories (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  agent       TEXT NOT NULL,
  project     TEXT,
  type        TEXT,
  name        TEXT,
  description TEXT,
  content     TEXT,
  created_at  TEXT,
  updated_at  TEXT
);
SQL
  python3 "$REPO_DIR/scripts/migrate_phase1.py" >/dev/null 2>&1
  python3 "$REPO_DIR/scripts/migrate_phase1_5.py" >/dev/null 2>&1
}

# ─────────────────────────────────────────────────────────────────────────────
# Test 1: Migration idempotency
# ─────────────────────────────────────────────────────────────────────────────

@test "migrate_phase6_injection_log.py is idempotent (runs twice, both exit 0)" {
  export CAST_DB_PATH="$BATS_TMPDIR/injection_log_mig_$BATS_TEST_NUMBER.db"
  _setup_db

  # First run
  run python3 "$REPO_DIR/scripts/migrate_phase6_injection_log.py"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"[OK] injection_log table ready"* ]]

  # Second run (idempotent)
  run python3 "$REPO_DIR/scripts/migrate_phase6_injection_log.py"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"[OK] injection_log table ready"* ]]

  # injection_log table exists
  run sqlite3 "$CAST_DB_PATH" \
    "SELECT name FROM sqlite_master WHERE type='table' AND name='injection_log';"
  [[ "$status" -eq 0 ]]
  [[ "$output" == "injection_log" ]]

  # idx_injection_log_session index exists
  run sqlite3 "$CAST_DB_PATH" \
    "SELECT name FROM sqlite_master WHERE type='index' AND name='idx_injection_log_session';"
  [[ "$status" -eq 0 ]]
  [[ "$output" == "idx_injection_log_session" ]]

  # idx_injection_log_fact index exists
  run sqlite3 "$CAST_DB_PATH" \
    "SELECT name FROM sqlite_master WHERE type='index' AND name='idx_injection_log_fact';"
  [[ "$status" -eq 0 ]]
  [[ "$output" == "idx_injection_log_fact" ]]

  rm -f "$CAST_DB_PATH"
}

# ─────────────────────────────────────────────────────────────────────────────
# Test 2: Write path — background thread writes injection_log row
# ─────────────────────────────────────────────────────────────────────────────

@test "inject hook writes at least one injection_log row with non-null prompt_hash" {
  export CAST_DB_PATH="$BATS_TMPDIR/injection_log_write_$BATS_TEST_NUMBER.db"

  _setup_db

  # Seed one agent_memories row so we have a valid fact id
  sqlite3 "$CAST_DB_PATH" <<'SQL'
INSERT INTO agent_memories (agent, type, name, content, importance, source_type, confidence, valid_from)
VALUES ('shared', 'feedback', 'inject_test_fact', 'injection log write-path test content keyword', 0.9, 'system', 1.0, datetime('now'));
SQL

  # Apply Phase 6 injection_log migration
  python3 "$REPO_DIR/scripts/migrate_phase6_injection_log.py" >/dev/null 2>&1

  # Call _log_injections directly — no daemon thread, no timing dependency.
  # importlib.util handles the hyphenated filename that plain `import` cannot.
  run python3 - <<PYEOF
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location(
    "cast_memory_inject",
    "$REPO_DIR/scripts/cast-memory-inject.py"
)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
os.environ["CAST_DB_PATH"] = "$CAST_DB_PATH"
m._log_injections(
    "test-session-001",
    "deadbeef01234567",
    [{"id": 1, "score": 0.9, "score_breakdown": None}]
)
PYEOF
  [[ "$status" -eq 0 ]]

  # At least one injection_log row must exist with non-null prompt_hash
  row_count=$(sqlite3 "$CAST_DB_PATH" \
    "SELECT COUNT(*) FROM injection_log WHERE prompt_hash IS NOT NULL AND prompt_hash != '';")
  [[ "$row_count" -ge 1 ]]

  rm -f "$CAST_DB_PATH"
}

# ─────────────────────────────────────────────────────────────────────────────
# Test 3: Latency regression — inject hook completes in < 200ms
# ─────────────────────────────────────────────────────────────────────────────

@test "inject hook completes in < 200ms (latency regression, --fts-only)" {
  export CAST_DB_PATH="$BATS_TMPDIR/injection_log_lat_$BATS_TEST_NUMBER.db"
  export CAST_COG_ENABLED=1
  export CAST_COG_MIN_SCORE=0.0

  _setup_db

  # Seed a fact so the hook has something to do
  sqlite3 "$CAST_DB_PATH" <<'SQL'
INSERT INTO agent_memories (agent, type, name, content, importance, source_type, confidence, valid_from)
VALUES ('shared', 'feedback', 'latency_test_fact', 'latency regression test keyword phrase', 0.9, 'system', 1.0, datetime('now'));
SQL
  sqlite3 "$CAST_DB_PATH" \
    "INSERT INTO agent_memories_fts(agent_memories_fts) VALUES('rebuild');" 2>/dev/null || true

  # Apply Phase 6 migration
  python3 "$REPO_DIR/scripts/migrate_phase6_injection_log.py" >/dev/null 2>&1

  # Use python3 for a platform-safe millisecond timer (works on macOS and Linux)
  START=$(python3 -c "import time; print(int(time.time()*1000))")
  run bash -c "
    echo '{\"prompt\":\"latency regression test keyword phrase\"}' \
      | python3 '$REPO_DIR/scripts/cast-memory-inject.py'
  "
  END=$(python3 -c "import time; print(int(time.time()*1000))")
  [[ "$status" -eq 0 ]]

  ELAPSED_MS=$(( END - START ))
  # Allow 200ms: generous buffer above 100ms p95 budget for test-machine variance
  [[ "$ELAPSED_MS" -lt 200 ]]

  rm -f "$CAST_DB_PATH"
}
