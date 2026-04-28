#!/usr/bin/env python3
"""cast-memory-writeback.py — SubagentStop hook: parse ## Facts blocks, write to agent_memories.

Reads SubagentStop stdin JSON. Trusted agents only. Exits 0 on every code path.
Feature flag: CAST_COG_ENABLED=1 (matches Phase 2 pattern).
"""
import json
import os
import re
import sys
import time

# ── Config ────────────────────────────────────────────────────────────────────
TRUSTED_AGENTS = {"researcher", "code-writer", "planner"}
MAX_FACTS = 5
MAX_CONTENT_LEN = 500
MAX_NAME_LEN = 80
VALID_TYPES = {"user", "feedback", "project", "reference", "procedural"}
LOG_PATH = os.path.expanduser("~/.claude/logs/cellar-door-writeback.log")
STDIN_LIMIT = 1 * 1024 * 1024   # 1 MiB
OUTPUT_LIMIT = 256 * 1024       # 256 KiB

# ── Logging ───────────────────────────────────────────────────────────────────
def _log(msg: str) -> None:
    ts = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    try:
        os.makedirs(os.path.dirname(LOG_PATH), exist_ok=True)
        with open(LOG_PATH, "a") as f:
            f.write(f"[{ts}] {msg}\n")
    except Exception:
        pass  # never fail

# ── Parser ────────────────────────────────────────────────────────────────────
def parse_facts(output: str) -> list[dict]:
    """Extract ## Facts block and parse pipe-delimited lines. Tolerant."""
    # Bound the output slice
    output = output[:OUTPUT_LIMIT]

    # Find the ## Facts block
    match = re.search(r"^##\s+Facts\s*\n(.*?)(?=^##|\Z)", output, re.MULTILINE | re.DOTALL)
    if not match:
        return []

    block = match.group(1)
    facts = []
    for line in block.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        try:
            fact = _parse_line(line)
            if fact:
                facts.append(fact)
        except Exception as e:
            _log(f"skipped malformed line: {line!r} — {e}")
        if len(facts) >= MAX_FACTS:
            break

    return facts

def _parse_line(line: str) -> dict | None:
    """Parse a single pipe-delimited fact line. Returns None on validation failure."""
    parts = [p.strip() for p in line.split("|")]
    kv = {}
    for part in parts:
        if ":" not in part:
            continue
        k, _, v = part.partition(":")
        kv[k.strip().lower()] = v.strip()

    name = kv.get("name", "")
    fact_type = kv.get("type", "")
    content = kv.get("content", "")

    # Validate required fields
    if not name or not content:
        _log(f"skipped fact: missing name or content — {line!r}")
        return None
    if re.search(r"\s", name) or len(name) > MAX_NAME_LEN:
        _log(f"skipped fact: invalid name {name!r}")
        return None
    if fact_type and fact_type not in VALID_TYPES:
        _log(f"skipped fact: invalid type {fact_type!r} — {name!r}")
        return None

    return {
        "name": name,
        "type": fact_type or "reference",
        "content": content[:MAX_CONTENT_LEN],
        "description": kv.get("description", ""),
        "confidence": _parse_confidence(kv.get("confidence", "1.0")),
    }

def _parse_confidence(val: str) -> float:
    try:
        f = float(val)
        return max(0.0, min(1.0, f))
    except (ValueError, TypeError):
        return 1.0

# ── Write-back ────────────────────────────────────────────────────────────────
def write_facts(facts: list[dict]) -> int:
    """Write facts to agent_memories. Returns count written."""
    sys.path.insert(0, os.path.expanduser("~/.claude/scripts"))
    # cast_db._connect() reads CAST_DB_PATH from env — set it before calling.
    # (Do NOT pass db_path as an argument; _connect() takes none.)
    db_path = os.environ.get("CAST_DB_PATH", os.path.expanduser("~/.claude/cast.db"))
    os.environ["CAST_DB_PATH"] = db_path
    from cast_db import _connect  # type: ignore
    conn = _connect()

    written = 0
    now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())

    try:
        conn.execute("BEGIN IMMEDIATE")
        for fact in facts:
            conn.execute(
                """
                INSERT OR IGNORE INTO agent_memories
                    (agent, type, name, description, content,
                     source_type, confidence, importance, decay_rate,
                     created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, 'inference', ?, 0.5, 0.0, ?, ?)
                """,
                (
                    "shared",
                    fact["type"],
                    fact["name"],
                    fact["description"],
                    fact["content"],
                    fact["confidence"],
                    now,
                    now,
                ),
            )
            if conn.execute(
                "SELECT changes()"
            ).fetchone()[0] > 0:
                written += 1
            else:
                _log(f"duplicate skipped (INSERT OR IGNORE): {fact['name']!r}")
        conn.execute("COMMIT")
    except Exception as e:
        conn.execute("ROLLBACK")
        _log(f"write_facts error: {e}")
        raise
    finally:
        conn.close()

    return written

# ── Main ──────────────────────────────────────────────────────────────────────
def main() -> None:
    # Feature flag: must be explicitly "1"
    if os.environ.get("CAST_COG_ENABLED") != "1":
        sys.exit(0)

    # Read stdin (bounded)
    try:
        raw = sys.stdin.read(STDIN_LIMIT)
        data = json.loads(raw)
    except Exception as e:
        _log(f"stdin parse error: {e}")
        sys.exit(0)

    agent_name = data.get("agent_type") or data.get("agent_name") or data.get("subagent_name") or ""
    if agent_name not in TRUSTED_AGENTS:
        sys.exit(0)

    output = data.get("last_assistant_message") or data.get("output") or ""
    if not output:
        sys.exit(0)

    facts = parse_facts(output)
    if not facts:
        sys.exit(0)

    try:
        written = write_facts(facts)
        if written:
            _log(f"wrote {written} fact(s) from agent={agent_name!r}")
    except Exception as e:
        _log(f"write error (agent={agent_name!r}): {e}")

    sys.exit(0)

if __name__ == "__main__":
    main()
