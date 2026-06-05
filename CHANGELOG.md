# Changelog

## [v0.3.1] — 2026-06-05

### Fixed
- **Security:** `cast-memory-router.py` — added `_is_safe_url` / `_ALLOWED_EMBED_HOSTS` guard so a misconfigured `OLLAMA_EMBED_URL` pointing to a non-local host is rejected before any network call is made (backport from flagship).
- **Correctness:** `cast-memory-router.py` — added `user_profile` to `VALID_TYPES` so `write_shared_memory()` no longer rejects that type.
- **Correctness:** `cast-memory-router.py` — added `db_write` import and `_log_injection()` function; retrieve mode now writes telemetry rows to `injection_log` (backport from flagship).
- **Correctness:** `cast-memory-router.py` — added `--session-id` CLI arg wired to `_log_injection` session tracking.
- **Docs:** `README.md` — replaced private `~/.claude/plans/` path with in-repo `research/` reference.
- **Docs:** `scripts/migrate_phase1.py` — removed stale "48 legacy rows" count from docstring; updated to reflect idempotent behaviour.

## [v0.3.0] — prior

See git history.
