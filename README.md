# Cellar Door

> "Cellar door." Tolkien called it the most beautiful phrase in English.
> You store things in a cellar — facts, memories, the stuff agents need to remember.
> The name is the spec.

## What It Is

Cellar Door is a typed, cross-agent shared-memory subsystem for local AI agents.
It gives CAST agents a common fact store with provenance, temporal supersession,
and model-agnostic injection — so a Claude-routed `code-writer` and an
Ollama-routed `code-reviewer` can share what they know without being told the same
things twice. Storage is SQLite inside the existing `~/.claude/cast.db`.
No daemon, no port, no cloud.

## Status

- Phase 0: scaffold complete
- Phase 1: schema migration + FTS5 (in progress)

## Install

```bash
bash install.sh
```

## Architecture

See `~/.claude/plans/cast-shared-cognition-roadmap.md` for the full phased build plan,
schema decisions, and injection-hook design.

## License

MIT — see [LICENSE](LICENSE).
