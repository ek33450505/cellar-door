#!/bin/bash
# check_parity_env.sh — Pre-flight environment check for CCR/Ollama parity testing.
# Verifies ccr, ollama, deepseek-coder model, python3+sqlite3, cast.db, and CAST_COG_ENABLED.
# Exits 0 if all checks pass. Exits 1 if any [FAIL] check fails.

set -uo pipefail

PASS=0
FAIL=0

_pass() { echo "[PASS] $*"; PASS=$((PASS+1)); }
_fail() { echo "[FAIL] $*" >&2; FAIL=$((FAIL+1)); }
_warn() { echo "[WARN] $*"; }

# ── Check 1: ccr binary exists ────────────────────────────────────────────────
if which ccr >/dev/null 2>&1; then
  _pass "ccr binary found at: $(which ccr)"
else
  _fail "ccr binary not found on PATH or at /opt/homebrew/bin/ccr. Install claude-code-router."
fi

# ── Check 2: ccr version responds ─────────────────────────────────────────────
# ccr uses `-v` (not --version); any output with exit 0 is sufficient.
if which ccr >/dev/null 2>&1 && ccr -v >/dev/null 2>&1; then
  _pass "ccr -v responded: $(ccr -v 2>&1 | head -1)"
else
  _fail "ccr -v failed or exited non-zero. Check ccr installation."
fi

# ── Check 3: ollama binary exists ─────────────────────────────────────────────
if which ollama >/dev/null 2>&1; then
  _pass "ollama binary found at: $(which ollama)"
else
  _fail "ollama binary not found on PATH. Install Ollama from https://ollama.ai"
fi

# ── Check 4: deepseek-coder model present in ollama list ──────────────────────
if which ollama >/dev/null 2>&1; then
  # grep -q causes SIGPIPE with pipefail when it exits after first match; use redirect instead.
  if ollama list 2>/dev/null | grep "deepseek-coder" > /dev/null 2>&1; then
    _pass "deepseek-coder model found in ollama list"
  else
    _fail "deepseek-coder not found in ollama list. Run: ollama pull deepseek-coder:latest"
  fi
else
  _fail "Skipping deepseek-coder check — ollama binary not available"
fi

# ── Check 5: python3 + sqlite3 available ──────────────────────────────────────
# Use sqlite3.sqlite_version (the underlying lib version), not sqlite3.__version__.
if python3 -c "import sqlite3; print(sqlite3.sqlite_version)" >/dev/null 2>&1; then
  sqlite3_ver=$(python3 -c "import sqlite3; print(sqlite3.sqlite_version)")
  _pass "python3 + sqlite3 available (sqlite3 version: $sqlite3_ver)"
else
  _fail "python3 or sqlite3 not available. Ensure python3 is installed with sqlite3 support."
fi

# ── Check 6: cast.db exists and is readable ───────────────────────────────────
CAST_DB_PATH="${CAST_DB_PATH:-$HOME/.claude/cast.db}"
if [[ -f "$CAST_DB_PATH" && -r "$CAST_DB_PATH" ]]; then
  _pass "cast.db exists and is readable at: $CAST_DB_PATH"
else
  _fail "cast.db not found or not readable at: $CAST_DB_PATH. Initialize CAST first."
fi

# ── Check 7: CAST_COG_ENABLED ─────────────────────────────────────────────────
if [[ "${CAST_COG_ENABLED:-0}" == "1" ]]; then
  _pass "CAST_COG_ENABLED=1 (Phase 2 hook is active)"
else
  _warn "CAST_COG_ENABLED is not set. Phase 2 hook is disabled; parity tests will force-enable via env override."
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "Preflight: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
