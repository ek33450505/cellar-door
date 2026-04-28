#!/usr/bin/env python3
"""
Cellar Door Phase 1.5 — Schema Migration
Drops the UNIQUE index on (agent, name) that was created in Phase 1.
Supersession logic (Phase 4) manages uniqueness in application code, so the
DB-level unique constraint is no longer appropriate and blocks multi-row history.

Drops both known index names:
  - idx_agent_memories_agent_name  (production)
  - idx_am_agent_name              (test fixtures)

Both DROP INDEX calls use IF EXISTS so the script is fully idempotent.
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


# ── Migration ─────────────────────────────────────────────────────────────────
def run_migration(db_path: str) -> None:
    """Drop the UNIQUE index on (agent, name) inside a single BEGIN IMMEDIATE transaction."""
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

    # Check which indexes exist before dropping, to produce a useful report.
    def _index_exists(name: str) -> bool:
        row = conn.execute(
            "SELECT 1 FROM sqlite_master WHERE type='index' AND name=?", (name,)
        ).fetchone()
        return row is not None

    prod_existed = _index_exists("idx_agent_memories_agent_name")
    test_existed = _index_exists("idx_am_agent_name")

    try:
        # Drop production index (created by Phase 1 migration)
        conn.execute("DROP INDEX IF EXISTS idx_agent_memories_agent_name")

        # Drop test-fixture index (created in BATS setup())
        conn.execute("DROP INDEX IF EXISTS idx_am_agent_name")

        conn.execute("COMMIT")

    except Exception as e:
        try:
            conn.execute("ROLLBACK")
        except Exception:
            pass
        print(f"ERROR: Migration failed — {e}", file=sys.stderr)
        conn.close()
        sys.exit(1)

    conn.close()

    # ── Report ────────────────────────────────────────────────────────────────
    if not prod_existed and not test_existed:
        print("Already migrated — no indexes to drop (idempotent run).")
    else:
        dropped = []
        if prod_existed:
            dropped.append("idx_agent_memories_agent_name")
        if test_existed:
            dropped.append("idx_am_agent_name")
        print("Migration complete.")
        for name in dropped:
            print(f"  Dropped index: {name}")


# ── Entrypoint ────────────────────────────────────────────────────────────────
if __name__ == "__main__":
    db_path = _resolve_db_path()
    run_migration(db_path)
