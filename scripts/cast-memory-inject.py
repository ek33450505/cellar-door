#!/usr/bin/env python3
"""
cast-memory-inject.py — UserPromptSubmit hook for Cellar Door Phase 2.

Reads stdin JSON from Claude Code hook pipeline, retrieves top-K memories
from cast.db via cast-memory-router.py --fts-only, emits hookSpecificOutput
additionalContext as compact key:value lines.

Feature flag: CAST_COG_ENABLED=1 (default: 0 = disabled)
Defaults overridable via env vars:
  CAST_COG_TOP_K        — max memories to retrieve (default: 5)
  CAST_COG_AGENT        — agent pool to query (default: shared)
  CAST_COG_TYPE_FILTER  — filter by memory type (default: none)
  CAST_COG_MIN_SCORE    — minimum relevance score threshold (default: 0.3)
"""
import sys
import os
import json
import sqlite3
import subprocess
import time
import threading
import hashlib


def main():
    t_start = time.monotonic()

    # SS1: stdin parsing — never crash on empty/malformed
    try:
        data = json.loads(sys.stdin.read(1_048_576) or "{}")
    except Exception:
        data = {}

    # SS4: feature flag guard — exit immediately if not enabled
    if os.environ.get("CAST_COG_ENABLED", "0") != "1":
        _emit_empty()
        return

    prompt = data.get("prompt", "")
    prompt = prompt[:8192]
    if not prompt:
        _emit_empty()
        return

    # SS7: env var overrides with defaults
    top_n = int(os.environ.get("CAST_COG_TOP_K", "5"))
    agent = os.environ.get("CAST_COG_AGENT", "shared")
    min_sc = float(os.environ.get("CAST_COG_MIN_SCORE", "0.3"))
    typ = os.environ.get("CAST_COG_TYPE_FILTER", "")

    router = os.path.expanduser("~/.claude/scripts/cast-memory-router.py")

    # SS3: always pass --fts-only to avoid Ollama embed timeout (~3s)
    # Use list form — no shell=True, no injection risk
    cmd = [
        sys.executable, router,
        "--mode", "retrieve",
        "--agent", agent,
        "--prompt", prompt,
        "--top-n", str(top_n),
        "--fts-only",
    ]
    if typ:
        cmd += ["--type", typ]

    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=0.8)
        rows = json.loads(result.stdout.strip() or "[]")
    except Exception as e:
        print(f"[cellar-door] router error: {e}", file=sys.stderr)
        _emit_empty()
        return

    if not isinstance(rows, list):
        _emit_empty()
        return

    # Filter by min_score
    rows = [r for r in rows if isinstance(r, dict) and r.get("score", 0) >= min_sc]

    if not rows:
        _emit_empty()
        return

    # SS2: compact [cellar-door] + [mem] key:value lines, content truncated to 120 chars
    lines = [f"[cellar-door] retrieved {len(rows)} memories"]
    for r in rows:
        content = str(r.get("content", r.get("body", "")))[:120]
        lines.append(
            f'[mem] type={r.get("type", "")} name={r.get("name", "")} '
            f'score={r.get("score", 0):.2f} content="{content}"'
        )
    context = "\n".join(lines)

    # SS6: emit valid JSON (compact separators so BATS regex matches work)
    out = {"hookSpecificOutput": {"hookEventName": "UserPromptSubmit", "additionalContext": context}}
    print(json.dumps(out, separators=(',', ':')))

    # Fire-and-forget injection log writes — must not block the main thread.
    # The thread is daemon=True so it does not delay process exit.
    session_id = data.get("session_id") or os.environ.get("CAST_SESSION_ID", "")
    prompt_hash = hashlib.sha256(prompt.encode()).hexdigest()[:16]
    t_log = threading.Thread(
        target=_log_injections,
        args=(session_id, prompt_hash, rows),
        daemon=True,
    )
    t_log.start()
    # Fire-and-forget: no join. Daemon thread races with process exit.
    # Partial log rows are acceptable per spec; blocking is not.

    elapsed_ms = (time.monotonic() - t_start) * 1000
    if elapsed_ms > 500:
        print(
            f"[cellar-door] WARNING: hook latency {elapsed_ms:.0f}ms exceeded 500ms target",
            file=sys.stderr,
        )


def _resolve_db_path() -> str:
    """Resolve DB path from env var. Return empty string if outside allowed dirs (path-traversal guard)."""
    from pathlib import Path
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
            f"[injection_log] CAST_DB_PATH resolves to '{resolved}' which is outside allowed directories.",
            file=sys.stderr,
        )
        return ""

    return resolved


def _log_injections(session_id: str, prompt_hash: str, facts: list) -> None:
    """Write injection_log rows for each retrieved fact. Runs in a background daemon thread."""
    try:
        db_path = _resolve_db_path()
        if not db_path:
            return
        conn = sqlite3.connect(db_path, timeout=2)
        for fact in facts:
            fact_id = fact.get('id')
            if fact_id is None:
                continue
            score = fact.get('score')
            breakdown = fact.get('score_breakdown')
            conn.execute(
                """INSERT INTO injection_log (session_id, prompt_hash, fact_id, score, score_breakdown)
                   VALUES (?, ?, ?, ?, ?)""",
                (
                    session_id,
                    prompt_hash,
                    fact_id,
                    score,
                    json.dumps(breakdown) if breakdown else None,
                ),
            )
        conn.commit()
        conn.close()
    except Exception as e:
        print(f"[injection_log] background write failed: {e}", file=sys.stderr)


def _emit_empty():
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "UserPromptSubmit", "additionalContext": ""}}, separators=(',', ':')))


if __name__ == "__main__":
    main()
