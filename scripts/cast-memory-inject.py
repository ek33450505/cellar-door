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
import subprocess
import time


def main():
    t_start = time.monotonic()

    # SS1: stdin parsing — never crash on empty/malformed
    try:
        data = json.loads(sys.stdin.read() or "{}")
    except Exception:
        data = {}

    # SS4: feature flag guard — exit immediately if not enabled
    if os.environ.get("CAST_COG_ENABLED", "0") != "1":
        _emit_empty()
        return

    prompt = data.get("prompt", "")
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
        content = str(r.get("content", r.get("body", ""))).replace('"', "'")[:120]
        lines.append(
            f'[mem] type={r.get("type", "")} name={r.get("name", "")} '
            f'score={r.get("score", 0):.2f} content="{content}"'
        )
    context = "\n".join(lines)

    # SS6: emit valid JSON (compact separators so BATS regex matches work)
    out = {"hookSpecificOutput": {"additionalContext": context}}
    print(json.dumps(out, separators=(',', ':')))

    elapsed_ms = (time.monotonic() - t_start) * 1000
    if elapsed_ms > 100:
        print(
            f"[cellar-door] WARNING: hook latency {elapsed_ms:.0f}ms exceeded 100ms target",
            file=sys.stderr,
        )


def _emit_empty():
    print(json.dumps({"hookSpecificOutput": {"additionalContext": ""}}, separators=(',', ':')))


if __name__ == "__main__":
    main()
