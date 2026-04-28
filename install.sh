#!/bin/bash
# install.sh — cellar-door manual installer
#
# Usage: bash install.sh

set -uo pipefail

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

# ── Step 5: Symlink CLI ──────────────────────────────────────────────────────
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
printf "  Phase 1 will add the schema migration and memory injection hook.\n"
printf "  See ~/.claude/plans/cast-shared-cognition-roadmap.md for the full build plan.\n\n"
