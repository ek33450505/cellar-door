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
- Phase 1: schema migration + FTS5 (live)
- Phase 2: UserPromptSubmit injection hook (live)

## Install

```bash
bash install.sh
# With Phase 2 hook wiring:
bash install.sh --yes
```

## Phase 2 — Memory Injection (opt-in)

Phase 2 adds a `UserPromptSubmit` hook that retrieves relevant memories from
`cast.db` and injects them as `additionalContext` before every Claude/Ollama prompt.

### Enable

Per session:
```bash
CAST_COG_ENABLED=1 claude
```

Always-on (add to `~/.zshrc`):
```bash
export CAST_COG_ENABLED=1
```

### What it does

On each user prompt, the hook calls `cast-memory-router.py --fts-only` to retrieve
the top-5 most relevant memories from the shared memory pool. Retrieved memories are
injected into `additionalContext` in this format:

```
[cellar-door] retrieved 3 memories
[mem] type=feedback name=editorial_pullback score=0.78 content="lean toward complete shippable choices"
[mem] type=user name=collaboration_style score=0.62 content="values teammate dynamic over tool dynamic"
[mem] type=project name=aether score=0.51 content="commercial dev terminal, 26-week roadmap"
```

Content is truncated at 120 characters.

### Env overrides

| Variable | Default | Description |
|---|---|---|
| `CAST_COG_TOP_K` | `5` | Max memories to retrieve per prompt |
| `CAST_COG_AGENT` | `shared` | Memory pool to query |
| `CAST_COG_TYPE_FILTER` | (none) | Filter by type: `user`, `feedback`, `project`, `reference` |
| `CAST_COG_MIN_SCORE` | `0.3` | Minimum relevance score threshold |

### CCR parity

The hook fires in the main Claude Code session before routing. Both Anthropic-backed
and Ollama-backed (CCR) model paths receive identical injected context — no extra
configuration needed.

### Latency

Target: <100ms p95. FTS-only retrieval (no Ollama embed call) typically runs in
10–30ms. The hook self-monitors and logs a warning to stderr if latency exceeds 100ms.
Hook never blocks the prompt — any error path exits 0 with empty `additionalContext`.

## Architecture

See `~/.claude/plans/cast-shared-cognition-roadmap.md` for the full phased build plan,
schema decisions, and injection-hook design.

## License

MIT — see [LICENSE](LICENSE).
