#!/usr/bin/env python3
"""
migrate_phase6_injection_log.py — idempotent migration for injection_log table.
Part of Cellar Door Phase 6.5.

Adds the injection_log table and two indexes:
  - idx_injection_log_session(session_id, injected_at)
  - idx_injection_log_fact(fact_id)

Safe to run multiple times (CREATE TABLE IF NOT EXISTS, CREATE INDEX IF NOT EXISTS).
"""

import os
import sys
import sqlite3
from pathlib import Path


def _resolve_db_path() -> str:
    """Resolve DB path from env var. Refuse if outside allowed dirs (path-traversal guard)."""
    raw = os.environ.get('CAST_DB_PATH', str(Path.home() / '.claude' / 'cast.db'))
    resolved = str(Path(raw).resolve())

    allowed_prefixes = (
        str(Path.home() / '.claude'),
        str(Path.home() / 'Projects'),
        '/tmp',
        '/private/tmp',
        '/var/folders',
        '/private/var/folders',
    )

    def _is_allowed(r: str, prefix: str) -> bool:
        p = prefix.rstrip(os.sep)
        return r == p or r.startswith(p + os.sep)

    if not any(_is_allowed(resolved, p) for p in allowed_prefixes):
        print(
            f"ERROR: CAST_DB_PATH resolves to '{resolved}' which is outside allowed directories.",
            file=sys.stderr,
        )
        sys.exit(1)

    return resolved


def run_migration(db_path: str) -> None:
    Path(db_path).parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(db_path, timeout=10)
    conn.execute("PRAGMA journal_mode = WAL")

    try:
        conn.execute("""
            CREATE TABLE IF NOT EXISTS injection_log (
              id              INTEGER PRIMARY KEY AUTOINCREMENT,
              session_id      TEXT,
              prompt_hash     TEXT NOT NULL,
              fact_id         INTEGER NOT NULL,
              score           REAL,
              score_breakdown TEXT,
              injected_at     TEXT NOT NULL DEFAULT (datetime('now'))
            )
        """)
        conn.execute("""
            CREATE INDEX IF NOT EXISTS idx_injection_log_session
              ON injection_log(session_id, injected_at)
        """)
        conn.execute("""
            CREATE INDEX IF NOT EXISTS idx_injection_log_fact
              ON injection_log(fact_id)
        """)
        conn.commit()
    except Exception as e:
        try:
            conn.rollback()
        except Exception:
            pass
        print(f"ERROR: Migration failed — {e}", file=sys.stderr)
        conn.close()
        sys.exit(1)

    conn.close()
    print("[OK] injection_log table ready")


def main() -> None:
    db_path = _resolve_db_path()
    run_migration(db_path)


if __name__ == '__main__':
    main()
