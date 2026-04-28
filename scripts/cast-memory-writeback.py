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
    """Write facts to agent_memories with supersession.

    For each fact: if a current row exists for (agent='shared', name),
    set old.valid_to = now and old.superseded_by = new_id, then insert the new row.
    Returns count of new rows inserted.
    """
    sys.path.insert(0, os.path.expanduser("~/.claude/scripts"))
    db_path = os.environ.get("CAST_DB_PATH", os.path.expanduser("~/.claude/cast.db"))
    os.environ["CAST_DB_PATH"] = db_path
    from cast_db import _connect  # type: ignore
    conn = _connect()

    written = 0
    now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())

    try:
        conn.execute("BEGIN IMMEDIATE")

        for fact in facts:
            # 1. Check for existing current row with same name
            existing = conn.execute(
                "SELECT id FROM agent_memories WHERE agent = 'shared' AND name = ? AND valid_to IS NULL",
                (fact["name"],)
            ).fetchone()

            # 2. Insert new row first (need its id for superseded_by)
            conn.execute(
                """
                INSERT INTO agent_memories
                    (agent, type, name, description, content,
                     source_type, confidence, importance, decay_rate,
                     valid_from, created_at, updated_at)
                VALUES ('shared', ?, ?, ?, ?, 'inference', ?, 0.5, 0.0, ?, ?, ?)
                """,
                (
                    fact["type"], fact["name"], fact["description"],
                    fact["content"], fact["confidence"],
                    now, now, now,
                ),
            )
            new_id = conn.execute("SELECT last_insert_rowid()").fetchone()[0]
            written += 1

            # 3. Supersede old row if it existed
            if existing:
                old_id = existing[0]
                conn.execute(
                    "UPDATE agent_memories SET valid_to = ?, superseded_by = ? WHERE id = ?",
                    (now, new_id, old_id),
                )
                _log(f"superseded fact id={old_id} with new id={new_id} (name={fact['name']!r})")
            else:
                _log(f"inserted new fact id={new_id} (name={fact['name']!r})")

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
