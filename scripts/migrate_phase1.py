#!/usr/bin/env python3
"""
Cellar Door Phase 1 — Schema Migration
Adds provenance/scoring columns, FTS5 virtual table, sync triggers, and backfills 48 legacy rows.

Pre-check 2026-04-28: 48 rows, no duplicates — UNIQUE index added without dedup pass.
(bash-specialist confirmed zero duplicate (agent, name) pairs in existing 48 rows.)
"""

import os
import sys
import sqlite3
import time
from pathlib import Path


# ── Path guard ────────────────────────────────────────────────────────────────
def _resolve_db_path() -> str:
    """Resolve DB path from env var. Refuse if outside allowed dirs (path-traversal guard)."""
    raw = os.environ.get('CAST_DB_PATH', str(Path.home() / '.claude' / 'cast.db'))
    resolved = str(Path(raw).resolve())

    allowed_prefixes = (
        str(Path.home() / '.claude'),
        str(Path.home() / 'Projects'),
        # Allow macOS/Linux temp dirs for BATS test runs (BATS_TMPDIR, TMPDIR)
        '/tmp',
        '/private/tmp',
        '/var/folders',
        '/private/var/folders',
    )

    def _is_allowed(resolved: str, prefix: str) -> bool:
        p = prefix.rstrip(os.sep)
        return resolved == p or resolved.startswith(p + os.sep)

    if not any(_is_allowed(resolved, p) for p in allowed_prefixes):
        print(
            f"ERROR: CAST_DB_PATH resolves to '{resolved}' which is outside allowed directories "
            f"({', '.join(allowed_prefixes)}). Refusing to run.",
            file=sys.stderr,
        )
        sys.exit(1)

    return resolved


# ── Connection ────────────────────────────────────────────────────────────────
def _open_connection(db_path: str) -> sqlite3.Connection:
    """Open a connection with WAL mode and foreign keys enabled."""
    Path(db_path).parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(db_path, timeout=10)
    conn.execute("PRAGMA foreign_keys = ON")
    conn.execute("PRAGMA journal_mode = WAL")
    return conn


# ── Migration helpers ─────────────────────────────────────────────────────────
def _add_column(conn: sqlite3.Connection, col_def: str) -> bool:
    """Attempt ALTER TABLE ADD COLUMN. Returns True if added, False if already exists."""
    try:
        conn.execute(f"ALTER TABLE agent_memories ADD COLUMN {col_def}")
        return True
    except sqlite3.OperationalError as e:
        if "duplicate column name" in str(e):
            return False
        raise


def _fts_table_exists(conn: sqlite3.Connection) -> bool:
    row = conn.execute(
        "SELECT 1 FROM sqlite_master WHERE type='table' AND name='agent_memories_fts'"
    ).fetchone()
    return row is not None


def run_migration(db_path: str) -> None:
    """Run the full Phase 1 migration inside a single BEGIN IMMEDIATE transaction."""
    conn = _open_connection(db_path)

    # Retry once on locked DB
    for attempt in range(2):
        try:
            conn.execute("BEGIN IMMEDIATE")
            break
        except sqlite3.OperationalError as e:
            if "database is locked" in str(e) and attempt == 0:
                print("Database locked — waiting 1s and retrying...", file=sys.stderr)
                conn.close()
                time.sleep(1.0)
                conn = _open_connection(db_path)
            else:
                print(f"ERROR: Could not acquire DB lock: {e}", file=sys.stderr)
                sys.exit(1)

    try:
        # ── Step 1: Add new columns ───────────────────────────────────────────
        columns_added = 0
        column_defs = [
            "importance REAL DEFAULT 0.5",
            "decay_rate REAL DEFAULT 0.0",
            "valid_from TEXT",
            "valid_to TEXT",
            "superseded_by INTEGER REFERENCES agent_memories(id)",
            "embedding BLOB",
            "source_type TEXT",
            "confidence REAL DEFAULT 1.0",
        ]
        for col_def in column_defs:
            if _add_column(conn, col_def):
                columns_added += 1

        # ── Step 2: Drop UNIQUE index on (agent, name) if it exists ─────────────
        # Phase 1.5 dropped this index — supersession model uses INSERT + retroactive
        # UPDATE, not ON CONFLICT. A UNIQUE index would reject valid re-inserts.
        conn.execute("DROP INDEX IF EXISTS idx_agent_memories_agent_name")

        # ── Step 3: Backfill legacy rows ──────────────────────────────────────
        # Guard: WHERE source_type IS NULL ensures idempotency.
        conn.execute("""
            UPDATE agent_memories SET
                importance  = 0.5,
                decay_rate  = 0.0,
                confidence  = 1.0,
                source_type = 'legacy',
                valid_from  = COALESCE(created_at, datetime('now'))
            WHERE source_type IS NULL
        """)

        # ── Step 4: FTS5 virtual table ────────────────────────────────────────
        # External-content table: content= points at agent_memories, triggers handle sync.
        # A rebuild is required after creation (and after any out-of-band writes).
        fts_was_new = not _fts_table_exists(conn)
        conn.execute("""
            CREATE VIRTUAL TABLE IF NOT EXISTS agent_memories_fts
            USING fts5(
                name, description, content,
                content=agent_memories,
                content_rowid=id
            )
        """)

        # Rebuild to populate FTS from existing rows.
        # Safe to run repeatedly — FTS rebuild is always idempotent.
        conn.execute("INSERT INTO agent_memories_fts(agent_memories_fts) VALUES('rebuild')")

        # ── Step 5: Sync triggers ─────────────────────────────────────────────
        conn.execute("""
            CREATE TRIGGER IF NOT EXISTS fts_ai
            AFTER INSERT ON agent_memories
            BEGIN
                INSERT INTO agent_memories_fts(rowid, name, description, content)
                VALUES (new.id, new.name, new.description, new.content);
            END
        """)

        conn.execute("""
            CREATE TRIGGER IF NOT EXISTS fts_au
            AFTER UPDATE ON agent_memories
            BEGIN
                DELETE FROM agent_memories_fts WHERE rowid = old.id;
                INSERT INTO agent_memories_fts(rowid, name, description, content)
                VALUES (new.id, new.name, new.description, new.content);
            END
        """)

        conn.execute("""
            CREATE TRIGGER IF NOT EXISTS fts_ad
            AFTER DELETE ON agent_memories
            BEGIN
                DELETE FROM agent_memories_fts WHERE rowid = old.id;
            END
        """)

        conn.execute("COMMIT")

    except Exception as e:
        try:
            conn.execute("ROLLBACK")
        except Exception:
            pass
        print(f"ERROR: Migration failed — {e}", file=sys.stderr)
        conn.close()
        sys.exit(1)

    # ── Step 6: Verify and report ─────────────────────────────────────────────
    try:
        fts_count = conn.execute("SELECT COUNT(*) FROM agent_memories_fts").fetchone()[0]
        sourced_count = conn.execute(
            "SELECT COUNT(*) FROM agent_memories WHERE source_type IS NOT NULL"
        ).fetchone()[0]
        important_count = conn.execute(
            "SELECT COUNT(*) FROM agent_memories WHERE importance IS NOT NULL"
        ).fetchone()[0]
    finally:
        conn.close()

    if columns_added == 0 and not fts_was_new:
        print("Already migrated — skipping.")
    elif columns_added == 0 and fts_was_new:
        print("Migration complete (FTS5 table created from existing schema).")
    else:
        print("Migration complete.")

    print(f"  agent_memories_fts rows:              {fts_count}")
    print(f"  agent_memories with source_type set:  {sourced_count}")
    print(f"  agent_memories with importance set:   {important_count}")


# ── Entrypoint ────────────────────────────────────────────────────────────────
if __name__ == "__main__":
    db_path = _resolve_db_path()
    run_migration(db_path)
