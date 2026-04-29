#!/usr/bin/env bash
# parity_helper.bash — Shared BATS fixture helper for Cellar Door Phase 5 parity tests.
#
# Provides:
#   parity_setup    — create temp cast.db, run Phase 1 + Phase 1.5 migrations, seed 3 facts
#   parity_teardown — remove temp DB
#
# Exported env vars (available to all tests that load this helper):
#   REPO_DIR           — absolute path to the cellar-door repo root
#   CAST_DB_PATH       — path to the temp test DB (under BATS_TMPDIR)
#   CAST_COG_ENABLED   — "1" (force-enable inject hook for all parity tests)
#   CAST_COG_MIN_SCORE — "0.0" (accept all scores so all 3 seeded facts are retrievable)

# Resolve repo root: one level up from tests/helpers/
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export REPO_DIR

parity_setup() {
  # Create a fresh temp DB for this test run.
  export CAST_DB_PATH="$BATS_TMPDIR/parity_test_$$.db"

  # Force-enable inject hook and accept all relevance scores.
  export CAST_COG_ENABLED=1
  export CAST_COG_MIN_SCORE=0.0

  # ── Bootstrap: create base agent_memories table (required before migrations) ──
  # Phase 1 migrate_phase1.py expects the table to already exist (it only ALTERs it).
  sqlite3 "$CAST_DB_PATH" <<'SQL'
CREATE TABLE IF NOT EXISTS agent_memories (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  agent       TEXT NOT NULL,
  project     TEXT,
  type        TEXT,
  name        TEXT,
  description TEXT,
  content     TEXT,
  created_at  TEXT DEFAULT (datetime('now')),
  updated_at  TEXT DEFAULT (datetime('now'))
);
SQL

  # ── Phase 1 migration (idempotent): adds provenance columns, FTS5, triggers ──
  python3 "$REPO_DIR/scripts/migrate_phase1.py" >/dev/null 2>&1

  # ── Phase 1.5 migration (idempotent): drops UNIQUE index ─────────────────────
  python3 "$REPO_DIR/scripts/migrate_phase1_5.py" >/dev/null 2>&1

  # ── Seed fixed 3-fact corpus ──────────────────────────────────────────────────
  # Uses `content` column (actual schema column; plan spec says 'body' but schema has 'content').
  # importance + source_type + confidence are Phase 1 provenance columns.
  sqlite3 "$CAST_DB_PATH" <<'SQL'
INSERT INTO agent_memories (agent, type, name, content, importance, source_type, confidence)
VALUES
  ('test-agent', 'feedback', 'parity_fact_a', 'memory system works under both backends', 0.9, 'system', 1.0),
  ('test-agent', 'project',  'parity_fact_b', 'cellar-door model-agnostic injection verified', 0.8, 'system', 1.0),
  ('test-agent', 'user',     'parity_fact_c', 'ollama deepseek-coder reads shared memory pool', 0.7, 'system', 1.0);
SQL

  # ── Rebuild FTS5 index to include seeded rows ─────────────────────────────────
  sqlite3 "$CAST_DB_PATH" \
    "INSERT INTO agent_memories_fts(agent_memories_fts) VALUES('rebuild');"
}

parity_teardown() {
  if [[ -n "${CAST_DB_PATH:-}" && -f "$CAST_DB_PATH" ]]; then
    rm -f "$CAST_DB_PATH"
  fi
}
