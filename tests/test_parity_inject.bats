#!/usr/bin/env bats
# test_parity_inject.bats — Cellar Door Phase 5: inject (read) parity tests.
#
# Verifies that cast-memory-inject.py retrieves facts from the seeded corpus
# identically regardless of backend session env (Claude vs CCR/Ollama).
# The hook is model-agnostic — it talks to cast.db, not the LLM.

load 'helpers/parity_helper.bash'

setup()    { parity_setup; }
teardown() { parity_teardown; }

# CAST_COG_AGENT must be exported as 'test-agent' to match the seeded fixture row;
# the inject hook filters agent_memories by agent name, so mismatches yield empty output.
INJECT_SCRIPT="$REPO_DIR/scripts/cast-memory-inject.py"

# ── Test 1: exits 0 with feature flag enabled ────────────────────────────────

@test "inject hook exits 0 with CAST_COG_ENABLED=1" {
  run bash -c "
    echo '{\"prompt\":\"parity backend verification memory injection\"}' \
      | CAST_COG_ENABLED=1 CAST_DB_PATH=\"$CAST_DB_PATH\" CAST_COG_AGENT=test-agent \
        python3 \"$INJECT_SCRIPT\"
  "
  [[ "$status" -eq 0 ]]
}

# ── Test 2: additionalContext contains seeded parity_fact_a ─────────────────

@test "inject hook returns additionalContext with seeded fact" {
  run bash -c "
    echo '{\"prompt\":\"parity backend verification memory injection\"}' \
      | CAST_COG_ENABLED=1 CAST_DB_PATH=\"$CAST_DB_PATH\" CAST_COG_AGENT=test-agent \
        python3 \"$INJECT_SCRIPT\"
  "
  [[ "$status" -eq 0 ]]
  # Output must be valid JSON object
  [[ "$output" =~ ^\{.*\}$ ]]
  # additionalContext must contain the seeded fact name
  [[ "$output" =~ parity_fact_a ]]
}

# ── Test 3: returns empty context when feature flag is disabled ──────────────

@test "inject hook returns empty context when CAST_COG_ENABLED=0" {
  run bash -c "
    echo '{\"prompt\":\"parity backend verification memory injection\"}' \
      | CAST_COG_ENABLED=0 CAST_DB_PATH=\"$CAST_DB_PATH\" CAST_COG_AGENT=test-agent \
        python3 \"$INJECT_SCRIPT\"
  "
  [[ "$status" -eq 0 ]]
  [[ "$output" =~ \"additionalContext\":\"\" ]]
}

# ── Test 4: respects CAST_COG_TOP_K=1 ───────────────────────────────────────

@test "inject hook respects CAST_COG_TOP_K=1" {
  run bash -c "
    echo '{\"prompt\":\"parity backend verification memory injection\"}' \
      | CAST_COG_ENABLED=1 CAST_DB_PATH=\"$CAST_DB_PATH\" CAST_COG_AGENT=test-agent \
        CAST_COG_TOP_K=1 CAST_COG_MIN_SCORE=0.0 \
        python3 \"$INJECT_SCRIPT\"
  "
  [[ "$status" -eq 0 ]]
  # Count [mem] lines — there must be exactly 1
  mem_count=$(echo "$output" | python3 -c "
import sys, json
data = json.loads(sys.stdin.read())
ctx = data.get('hookSpecificOutput', {}).get('additionalContext', '')
print(ctx.count('[mem]'))
")
  [[ "$mem_count" -eq 1 ]]
}

# ── Test 5: hook completes in under 500ms ───────────────────────────────────

@test "inject hook completes in under 500ms" {
  elapsed_ms=$(python3 -c "
import subprocess, time, json, os
cmd = ['python3', '$INJECT_SCRIPT']
stdin = json.dumps({'prompt': 'parity backend verification memory injection'})
t0 = time.monotonic_ns()
proc = subprocess.run(cmd, input=stdin, capture_output=True, text=True,
                      env={**os.environ,
                           'CAST_COG_ENABLED': '1',
                           'CAST_DB_PATH': '$CAST_DB_PATH',
                           'CAST_COG_AGENT': 'test-agent',
                           'CAST_COG_MIN_SCORE': '0.0'})
t1 = time.monotonic_ns()
print(int((t1 - t0) / 1_000_000))
")
  [[ "$elapsed_ms" -lt 500 ]]
}

# ── Test 6: CCR session env produces identical inject output as Claude env ───

@test "CCR session env produces identical inject output as Claude session env" {
  # Run without CCR env var (standard Claude session)
  claude_out=$(echo '{"prompt":"parity backend verification memory injection"}' \
    | CAST_COG_ENABLED=1 CAST_DB_PATH="$CAST_DB_PATH" CAST_COG_AGENT=test-agent \
      CAST_COG_MIN_SCORE=0.0 \
      python3 "$INJECT_SCRIPT")

  # Run with CCR_SESSION=1 (simulates a ccr/Ollama session env)
  ccr_out=$(echo '{"prompt":"parity backend verification memory injection"}' \
    | CAST_COG_ENABLED=1 CAST_DB_PATH="$CAST_DB_PATH" CAST_COG_AGENT=test-agent \
      CAST_COG_MIN_SCORE=0.0 CCR_SESSION=1 \
      python3 "$INJECT_SCRIPT")

  # Extract additionalContext from each
  claude_ctx=$(echo "$claude_out" | python3 -c "
import sys, json
print(json.loads(sys.stdin.read()).get('hookSpecificOutput', {}).get('additionalContext', ''))
")
  ccr_ctx=$(echo "$ccr_out" | python3 -c "
import sys, json
print(json.loads(sys.stdin.read()).get('hookSpecificOutput', {}).get('additionalContext', ''))
")

  # Must be identical — hook is model-agnostic; CCR_SESSION=1 must not alter output
  [[ "$claude_ctx" == "$ccr_ctx" ]]
}
