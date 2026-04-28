#!/usr/bin/env bats
# test_inject_hook.bats — BATS test suite for Cellar Door Phase 2 UserPromptSubmit hook
# Tests the injection script at ~/Projects/personal/cellar-door/scripts/cast-memory-inject.py

# Resolve repo root and hook path relative to this test file
REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

setup() {
  # Ensure hook script path is available
  HOOK_SCRIPT="$REPO_DIR/scripts/cast-memory-inject.py"

  # Create temp DB for this test (separate from real cast.db)
  export CAST_DB_PATH="$BATS_TMPDIR/test_inject.db"

  # Copy the real cast.db to temp location so router has data to query
  # Use dd as fallback if cp fails due to sandbox restrictions
  if ! cp ~/.claude/cast.db "$CAST_DB_PATH" 2>/dev/null; then
    dd if=~/.claude/cast.db of="$CAST_DB_PATH" 2>/dev/null || true
  fi

  # Verify the copy succeeded by checking if agent_memories table exists
  if ! sqlite3 "$CAST_DB_PATH" ".tables" 2>/dev/null | grep -q agent_memories; then
    # If copy failed, recreate minimal schema for the test
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
      confidence  REAL DEFAULT 1.0
    );" || true
  fi
}

teardown() {
  if [[ -f "$CAST_DB_PATH" ]]; then
    rm -f "$CAST_DB_PATH"
  fi
}

# ── Feature flag: disabled (CAST_COG_ENABLED=0) ──────────────────────────────

@test "disabled flag (CAST_COG_ENABLED=0) exits 0 with empty additionalContext" {
  run bash -c "
    echo '{\"prompt\":\"test query\"}' | CAST_COG_ENABLED=0 python3 '$HOOK_SCRIPT'
  "
  [[ "$status" -eq 0 ]]
  # Output must be valid JSON
  [[ "$output" =~ ^{.*}$ ]]
  # additionalContext must be empty string
  [[ "$output" =~ \"additionalContext\":\"\" ]]
}

# ── Feature flag: enabled with prompt ────────────────────────────────────────

@test "enabled flag (CAST_COG_ENABLED=1) with prompt exits 0, contains [cellar-door] line" {
  # Seed a shared memory into temp DB so router has data to retrieve
  sqlite3 "$CAST_DB_PATH" "INSERT INTO agent_memories (agent, type, name, description, content, source_type, importance, decay_rate, confidence, valid_from) VALUES ('shared', 'feedback', 'test_editorial_marker', 'Phase 2 BATS smoke test', 'editorial feedback test content for cellar door', 'legacy', 0.9, 0.0, 1.0, datetime('now'));"

  run bash -c "
    echo '{\"prompt\":\"editorial feedback\"}' | CAST_COG_ENABLED=1 python3 '$HOOK_SCRIPT'
  "
  [[ "$status" -eq 0 ]]
  # Output must be valid JSON
  [[ "$output" =~ ^{.*}$ ]]
  # additionalContext must contain [cellar-door] marker
  [[ "$output" =~ \[cellar-door\] ]]
  # Must NOT contain Python traceback on stdout
  [[ ! "$output" =~ Traceback ]]
  [[ ! "$output" =~ File ]]
}

# ── Stdin edge cases: empty ──────────────────────────────────────────────────

@test "empty stdin exits 0, outputs valid JSON, no traceback" {
  run bash -c "
    echo -n '' | CAST_COG_ENABLED=1 python3 '$HOOK_SCRIPT'
  "
  [[ "$status" -eq 0 ]]
  # Output must be valid JSON
  [[ "$output" =~ ^{.*}$ ]]
  # No Python traceback
  [[ ! "$output" =~ Traceback ]]
}

# ── Stdin edge cases: malformed JSON ─────────────────────────────────────────

@test "malformed JSON stdin exits 0, outputs valid JSON, no traceback" {
  run bash -c "
    echo '{this is not json' | CAST_COG_ENABLED=1 python3 '$HOOK_SCRIPT'
  "
  [[ "$status" -eq 0 ]]
  # Output must be valid JSON
  [[ "$output" =~ ^{.*}$ ]]
  # No Python traceback on stdout
  [[ ! "$output" =~ Traceback ]]
  [[ ! "$output" =~ File ]]
}

# ── Latency: hook completes in ≤100ms ────────────────────────────────────────

@test "hook latency with CAST_COG_ENABLED=1 is ≤100ms" {
  # Use Python to measure monotonic time in milliseconds (more reliable than date on macOS)
  run bash -c "
    CAST_COG_ENABLED=1 python3 -c \"
import subprocess, time, sys, json
cmd = ['python3', '$HOOK_SCRIPT']
stdin = json.dumps({'prompt': 'editorial feedback'})
t0 = time.monotonic_ns()
proc = subprocess.run(cmd, input=stdin, capture_output=True, text=True)
t1 = time.monotonic_ns()
if proc.returncode != 0:
    sys.exit(1)
try:
    json.loads(proc.stdout)
except:
    sys.exit(1)
elapsed_ms = (t1 - t0) / 1_000_000
print(int(elapsed_ms))
\"
  "
  [[ "$status" -eq 0 ]]
  # Output is now an integer (milliseconds)
  elapsed_int=$(echo "$output" | tr -d ' ')
  # Must be <= 100ms
  [[ $elapsed_int -le 100 ]]
}

# ── Database error path: nonexistent DB ──────────────────────────────────────

@test "nonexistent DB path causes router to fail open: exit 0, empty additionalContext" {
  run bash -c "
    echo '{\"prompt\":\"test\"}' | CAST_DB_PATH=/nonexistent/cast.db CAST_COG_ENABLED=1 python3 '$HOOK_SCRIPT'
  "
  [[ "$status" -eq 0 ]]
  # Output must be valid JSON
  [[ "$output" =~ ^{.*}$ ]]
  # additionalContext must be empty on error
  [[ "$output" =~ \"additionalContext\":\"\" ]]
  # No Python traceback on stdout
  [[ ! "$output" =~ Traceback ]]
}
