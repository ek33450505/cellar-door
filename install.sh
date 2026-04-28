#!/bin/bash
# install.sh — cellar-door manual installer
#
# Usage: bash install.sh

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION="$(cat "${REPO_DIR}/VERSION" 2>/dev/null || echo "unknown")"

# ── Colors ────────────────────────────────────────────────────────────────────
if [ -t 1 ] && [ "${TERM:-}" != "dumb" ]; then
  C_BOLD='\033[1m'
  C_GREEN='\033[0;32m'
  C_YELLOW='\033[0;33m'
  C_RED='\033[0;31m'
  C_RESET='\033[0m'
else
  C_BOLD='' C_GREEN='' C_YELLOW='' C_RED='' C_RESET=''
fi

_ok()   { printf "${C_GREEN}  [ok]${C_RESET} %s\n" "$*"; }
_warn() { printf "${C_YELLOW}  [warn]${C_RESET} %s\n" "$*" >&2; }
_fail() { printf "${C_RED}  [fail]${C_RESET} %s\n" "$*" >&2; }
_step() { printf "\n${C_BOLD}%s${C_RESET}\n" "$*"; }

# ── Banner ────────────────────────────────────────────────────────────────────
printf "\n${C_BOLD}cellar-door v${VERSION} installer${C_RESET}\n"
printf "══════════════════════════════════════\n\n"

# ── Step 1: Check prerequisites ──────────────────────────────────────────────
_step "Checking prerequisites..."
if ! command -v python3 &>/dev/null; then
  _warn "python3 not found — memory scripts need Python 3.9+"
else
  _ok "python3 found"
fi

if ! command -v sqlite3 &>/dev/null; then
  _warn "sqlite3 not found — schema migration needs sqlite3"
else
  _ok "sqlite3 found"
fi

# ── Step 2: Create directories ───────────────────────────────────────────────
_step "Creating directories..."
SCRIPTS_DST="${HOME}/.claude/scripts/cellar-door"
if mkdir -p "$SCRIPTS_DST" 2>/dev/null; then
  _ok "~/.claude/scripts/cellar-door/"
else
  _fail "Could not create ~/.claude/scripts/cellar-door/ — check permissions"
  exit 1
fi

# ── Step 3: Copy scripts ─────────────────────────────────────────────────────
_step "Installing scripts..."
copied=0
errors=0
for f in "${REPO_DIR}/scripts/"*.py "${REPO_DIR}/scripts/"*.sh; do
  [ -f "$f" ] || continue
  base="$(basename "$f")"
  dest="${SCRIPTS_DST}/${base}"
  if cp "$f" "$dest" 2>/dev/null; then
    chmod +x "$dest" 2>/dev/null || true
    _ok "${base}"
    copied=$((copied + 1))
  else
    _fail "Could not copy ${base}"
    errors=$((errors + 1))
  fi
done

if [ "$copied" -eq 0 ]; then
  _warn "No scripts found in ${REPO_DIR}/scripts/ — migration scripts will be wired in Phase 1"
fi

if [ "$errors" -gt 0 ]; then
  _warn "${errors} script(s) failed to copy — check permissions"
fi

# ── Step 4: Phase 1 migration ────────────────────────────────────────────────
_step "Running Phase 1 migration..."
MIGRATION_SRC="${REPO_DIR}/scripts/migrate_phase1.py"
MIGRATION_DST_DIR="${HOME}/.claude/scripts/cellar-door/migrations"
MIGRATION_DST="${MIGRATION_DST_DIR}/migrate_phase1.py"
mkdir -p "$MIGRATION_DST_DIR"
if [ -f "$MIGRATION_SRC" ]; then
  cp "$MIGRATION_SRC" "$MIGRATION_DST"
  chmod +x "$MIGRATION_DST" 2>/dev/null || true
  if python3 "$MIGRATION_DST"; then
    _ok "Phase 1 migration complete"
  else
    _fail "Phase 1 migration failed — see error above"
    exit 1
  fi
else
  _warn "scripts/migrate_phase1.py not found — skipping migration step"
fi

# ── Step 5: Wire UserPromptSubmit hook (--yes required) ─────────────────────
_step "Wiring UserPromptSubmit hook..."
SETTINGS_FILE="${HOME}/.claude/settings.local.json"
HOOK_CMD="python3 ~/.claude/scripts/cellar-door/cast-memory-inject.py"

# Copy the hook script first so the path in settings.local.json points at a real file
HOOK_SRC="${REPO_DIR}/scripts/cast-memory-inject.py"
HOOK_DST_DIR="${HOME}/.claude/scripts/cellar-door"
HOOK_DST="${HOOK_DST_DIR}/cast-memory-inject.py"
mkdir -p "$HOOK_DST_DIR"
if [ -f "$HOOK_SRC" ]; then
  cp "$HOOK_SRC" "$HOOK_DST"
  chmod +x "$HOOK_DST" 2>/dev/null || true
  _ok "Hook script installed → $HOOK_DST"
fi

if [[ "${1:-}" == "--yes" ]]; then
  # Idempotency check: skip if cast-memory-inject is already referenced
  if [ -f "$SETTINGS_FILE" ] && python3 -c "
import json, sys
try:
    d = json.load(open('$SETTINGS_FILE'))
except Exception:
    sys.exit(1)
hooks = d.get('hooks', {}).get('UserPromptSubmit', [])
for entry in hooks:
    for h in entry.get('hooks', []):
        if 'cast-memory-inject' in h.get('command', ''):
            sys.exit(0)
sys.exit(1)
" 2>/dev/null; then
    _ok "Hook already present in settings.local.json (idempotent)"
  else
    # Merge using jq
    if command -v jq &>/dev/null; then
      SNIPPET="${REPO_DIR}/scripts/cellar-door-hook-snippet.json"
      EXISTING="$(cat "$SETTINGS_FILE" 2>/dev/null || echo '{}')"
      echo "$EXISTING" | jq --slurpfile snippet "$SNIPPET" \
        '.hooks.UserPromptSubmit += $snippet[0].hooks.UserPromptSubmit' \
        > "${SETTINGS_FILE}.tmp" && mv "${SETTINGS_FILE}.tmp" "$SETTINGS_FILE"
      _ok "Hook wired into settings.local.json"
    else
      _warn "jq not found — manually add hook entry from scripts/cellar-door-hook-snippet.json"
    fi
  fi
else
  _warn "Skipping settings merge (pass --yes to auto-merge):"
  printf "    bash install.sh --yes\n"
fi

# ── Step 6: Wire SubagentStop hook (--yes required) ──────────────────────────
_step "Wiring SubagentStop hook..."
WRITEBACK_SNIPPET="${REPO_DIR}/scripts/cellar-door-writeback-snippet.json"

if [[ "${1:-}" == "--yes" ]]; then
  # Idempotency check: skip if cast-memory-writeback is already referenced
  if [ -f "$SETTINGS_FILE" ] && python3 -c "
import json, sys
try:
    d = json.load(open('$SETTINGS_FILE'))
except Exception:
    sys.exit(1)
hooks = d.get('hooks', {}).get('SubagentStop', [])
for entry in hooks:
    for h in entry.get('hooks', []):
        if 'cast-memory-writeback' in h.get('command', ''):
            sys.exit(0)
sys.exit(1)
" 2>/dev/null; then
    _ok "SubagentStop hook already present in settings.local.json (idempotent)"
  else
    if command -v jq &>/dev/null; then
      EXISTING="$(cat "$SETTINGS_FILE" 2>/dev/null || echo '{}')"
      echo "$EXISTING" | jq --slurpfile snippet "$WRITEBACK_SNIPPET" \
        '.hooks.SubagentStop += $snippet[0].hooks.SubagentStop' \
        > "${SETTINGS_FILE}.tmp" && mv "${SETTINGS_FILE}.tmp" "$SETTINGS_FILE"
      _ok "SubagentStop hook wired into settings.local.json"
    else
      _warn "jq not found — manually add hook entry from scripts/cellar-door-writeback-snippet.json"
    fi
  fi
else
  _warn "Skipping SubagentStop hook merge (pass --yes to auto-merge)"
fi

# ── Step 7: Symlink CLI ──────────────────────────────────────────────────────
_step "Installing CLI..."
LOCAL_BIN="${HOME}/.local/bin"
CLI_SRC="${REPO_DIR}/bin/cellar"
CLI_DST="${LOCAL_BIN}/cellar"

if [ ! -f "$CLI_SRC" ]; then
  _warn "bin/cellar not found — CLI entry point lands in Phase 4"
else
  if mkdir -p "$LOCAL_BIN" 2>/dev/null; then
    if ln -sf "$CLI_SRC" "$CLI_DST" 2>/dev/null; then
      _ok "cellar → ~/.local/bin/cellar"
      if ! echo "$PATH" | grep -q "${LOCAL_BIN}"; then
        printf "\n  ${C_YELLOW}Note:${C_RESET} Add ~/.local/bin to your PATH:\n"
        printf "    echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.zshrc\n"
      fi
    else
      _warn "Could not symlink to ~/.local/bin — run from repo: ${CLI_SRC}"
    fi
  else
    _warn "Could not create ~/.local/bin — run from repo: ${CLI_SRC}"
  fi
fi

# ── Summary ──────────────────────────────────────────────────────────────────
printf "\n${C_BOLD}══════════════════════════════════════${C_RESET}\n"
printf "${C_GREEN}cellar-door v${VERSION} installed.${C_RESET}\n\n"
printf "  Scripts: ${SCRIPTS_DST} (${copied} files)\n"
printf "\n${C_BOLD}Next steps:${C_RESET}\n"
printf "  Phase 2+3 hooks installed. Enable with: CAST_COG_ENABLED=1 claude\n"
printf "  Or add to ~/.zshrc: export CAST_COG_ENABLED=1\n"
printf "  See ~/.claude/plans/cast-shared-cognition-roadmap.md for the full build plan.\n\n"
