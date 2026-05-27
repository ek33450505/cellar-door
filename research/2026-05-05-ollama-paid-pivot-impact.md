# Ollama "Paid Pivot" Impact Assessment — Cellar Door

**Date:** 2026-05-05
**Author:** researcher agent (sonnet)
**Scope:** Cellar Door Desktop Phase 7c Ollama integration; Phase 7e embedded inference decision

---

## TL;DR

- **Ollama did NOT go fully paid.** The local CLI, `ollama serve`, and open-weight
  model inference on your own hardware remain **completely free, no account required**.
- **What went paid is a separate cloud product**: Ollama Cloud (preview, September 2025)
  — $0/$20/$100/month tiers for datacenter-hosted inference on hardware you don't own.
- **Phase 7c is unaffected.** The sidecar (`ollama serve` at `localhost:11434`),
  `/api/chat` with `tools` array, NDJSON streaming, and `/api/tags` model list are all
  local-only features. No paywall touches them.
- **The "free pitch" narrative holds** — the differentiating claim (free local LLM stack)
  is still factually accurate. No correction needed to the product pitch.
- **Recommendation:** Stay on Ollama (Option a) with one caveat: document the dependency
  clearly in the README and track the cloud product's evolution. Phase 7e (embedded
  inference) remains optional and should not be pulled forward based on this event.

---

## 1. What Ollama Actually Announced

### Cloud Product Launch (September 2025)

Ollama launched **Ollama Cloud** in preview — a managed inference service that runs
models on Ollama's datacenter hardware. This is an additive product, not a replacement
of the local stack.

**Pricing (as of 2026-05-05):**

| Tier | Price | Concurrent cloud models | Usage level |
|------|-------|------------------------|-------------|
| Free | $0/month | 1 | Light (daily quota, 5h session reset) |
| Pro | $20/month ($200/year) | 3 | Day-to-day coding/research |
| Max | $100/month | 10 | Sustained agent workflows |

Source: [https://ollama.com/pricing](https://ollama.com/pricing) (verified 2026-05-05)

**Key quote from official X post** ([@ollama](https://x.com/ollama/status/2032744932633620611)):
> "Ollama's Cloud comes with fixed subscription rates at $0, $20, and $100. This means
> you won't wake up to surprise overage bills if you leave Claude Code or OpenClaw
> running."

### What Stays Free — Verbatim Policy

From [https://ollama.com/pricing](https://ollama.com/pricing):
> "Running models on your own hardware is always unlimited."

From [https://docs.ollama.com/cloud](https://docs.ollama.com/cloud):
> "Ollama can run in local-only mode by disabling Ollama's cloud features."

Local deployment requires no account, no API key, and no subscription. The `ollama serve`
process, `ollama pull`, `/api/chat`, `/api/tags`, and all local model inference are
unchanged.

### What Changed

- To access **cloud-hosted models**, users must `ollama signin` (create an account).
- A new `OLLAMA_API_KEY` env var enables **direct API access** to ollama.com (cloud only).
- Cloud usage is GPU-time billed, not token billed.
- Usage-based metered pricing (pay-per-use) is slated but not yet live.

Source: [https://ollama.com/blog/cloud-models](https://ollama.com/blog/cloud-models)

### Timeline

Cloud was in **preview as of September 2025**. As of this writing (May 2026) it remains
an additive product. The local runtime has had no breaking changes.

---

## 2. Compatibility Check for Phase 7c

Phase 7c's integration (see `src-tauri/src/agent_loop.rs` and `src-tauri/src/ollama.rs`):

| Integration point | Affected by cloud announcement? | Notes |
|---|---|---|
| `ollama serve` sidecar spawn | **No** | Local binary, no auth needed |
| `GET /api/tags` health/model list | **No** | Local endpoint, no paywall |
| `POST /api/chat` with `tools` array | **No** | Local endpoint, no paywall |
| `message.tool_calls` response shape | **No** | API contract unchanged |
| NDJSON streaming | **No** | Local only; cloud is separate |
| `stream: false` non-streaming mode | **No** | Confirmed unchanged |
| JSON-fence fallback for non-tool models | **No** | Internal fallback, unaffected |

**Verdict: Zero technical impact on Phase 7c.** The integration continues to function
exactly as shipped. No paywall, no auth requirement, no API change.

The one operational note worth tracking: if a user attempts to use an Ollama cloud model
(signed into ollama.com) via the local API, it may require the `OLLAMA_API_KEY` header.
Cellar Door Desktop only pulls from local `/api/tags` — models that are not locally
pulled will not appear in the dropdown, so this edge case does not apply.

---

## 3. Alternative Sidecar Shortlist

Evaluated for the hypothetical case that Ollama's local runtime were to change. Ordered
roughly by relevance to Cellar Door's architecture.

### 3a. `llama-server` (llama.cpp native server)

- **License:** MIT
- **Distribution:** Requires user to build from source or download a pre-built binary
  from GitHub releases. Not a single-binary drag-and-drop.
- **Tool-call API parity:** Yes, native OpenAI-compatible `/v1/chat/completions` with
  `tools` array and `message.tool_calls` response. Requires `--jinja` flag; some models
  need an explicit `--chat-template-file` override.
  Source: [llama.cpp function-calling docs](https://github.com/ggml-org/llama.cpp/blob/master/docs/function-calling.md)
- **Streaming:** Yes, SSE format (same as OpenAI). Would require a streaming parser change
  in Cellar Door since Phase 7c currently uses Ollama's NDJSON format.
- **Maintenance health:** Extremely active (hundreds of commits/month, ggml-org org).
- **Fits Cellar Door because:** Protocol-complete, actively maintained, same GGUF model
  files Ollama uses internally.
- **Doesn't fit because:** No `brew install` story; distribution/bundling is complex;
  SSE vs NDJSON is a non-trivial adapter change in `agent_loop.rs`.

### 3b. `llamafile` (Mozilla)

- **License:** Apache 2.0
- **Distribution:** Single self-contained executable per model (model weights baked in).
  The Cellar Door model selector would need to be rethought — one binary per model is
  architecturally different from a model-agnostic server with a model dropdown.
- **Tool-call API parity:** Yes as of v0.10.0 (released 2025). OpenAI-compatible
  `/v1/chat/completions` with tool calling.
  Source: [mozilla-ai/llamafile GitHub](https://github.com/mozilla-ai/llamafile)
- **Streaming:** Yes, SSE.
- **Maintenance health:** Moderate; Mozilla backing but slower cadence than llama.cpp.
- **Fits Cellar Door because:** Zero install friction for end users (one file to download).
- **Doesn't fit because:** Single-binary-per-model model inverts the current UX (model
  dropdown from `/api/tags`); SSE streaming; bundling large binaries via Tauri is awkward.

### 3c. `mistral.rs` (Rust, server or embedded)

- **License:** MIT
- **Distribution:** Single Rust binary; can be shipped as a sidecar or embedded as a
  library. `cargo install mistralrs-server` or Tauri bundled binary.
- **Tool-call API parity:** Yes, native. OpenAI-compatible tool calling on the HTTP
  server. Supports both client-side (OpenAI loop) and server-side auto-execution.
  Source: [mistral.rs tool calling docs](https://github.com/EricLBuehler/mistral.rs/blob/master/docs/TOOL_CALLING.md)
- **Streaming:** Yes, SSE.
- **Maintenance health:** Active (single maintainer + community; solid GitHub activity).
- **Fits Cellar Door because:** Rust-native (natural fit for Tauri/Rust codebase); dual
  server/embedded modes; tool-call parity is native. If Phase 7e is ever pulled forward,
  this is the embedded path.
- **Doesn't fit because:** Less model variety than Ollama ecosystem; SSE streaming differs
  from Ollama NDJSON; smaller community support base.

### 3d. `LM Studio` local server

- **License:** Proprietary freeware (not open-source)
- **Distribution:** GUI app with embedded server; cannot be bundled or sidecar-spawned
  from Tauri.
- **Tool-call API parity:** Yes, full OpenAI-compatible `/v1/chat/completions` with tools.
  Source: [LM Studio tool use docs](https://lmstudio.ai/docs/developer/openai-compat/tools)
- **Streaming:** Yes, SSE.
- **Maintenance health:** Good; well-resourced company.
- **Fits Cellar Door because:** Nothing — it is a desktop app the user must run separately,
  not a sidecar we can manage.
- **Doesn't fit because:** Not embeddable, not open-source, requires user to have LM
  Studio installed and running as a separate app. Not viable as a Phase 7 sidecar.

### 3e. `candle` (Hugging Face, Rust, embedded only)

- **License:** Apache 2.0 / MIT dual
- **Distribution:** Rust library (no server mode).
- **Tool-call API parity:** None — library-only, no HTTP server, no OpenAI API surface.
  Tool calling would require implementing the entire protocol from scratch.
- **Maintenance health:** Active (Hugging Face internal project).
- **Fits Cellar Door because:** Pure Rust, no external binary dependency.
- **Doesn't fit because:** No HTTP server, no tool-call protocol — would require rewriting
  the entire inference layer, not just swapping a sidecar. This is the "maximum complexity"
  path of Phase 7e.

### 3f. `llama-cpp-rs` (Rust binding)

- **License:** MIT
- **Distribution:** Rust crate wrapping libllama. Embedded, no server.
- **Tool-call API parity:** Binding level only — tool calling requires implementing the
  prompt template and response parsing in Rust. No HTTP server.
- **Maintenance health:** Community maintained; slower cadence.
- **Fits Cellar Door because:** Rust-native, no subprocess.
- **Doesn't fit because:** Same problem as candle — no OpenAI API surface. Complete
  agent_loop.rs rewrite required.

### Summary Matrix

| Option | Tool-call parity | Streaming format | Embeddable | Open-source | Sidecar viable |
|--------|-----------------|-----------------|------------|-------------|----------------|
| Ollama (current) | Native | NDJSON | No (brew install) | Yes | Yes |
| llama-server | Native | SSE | No | Yes | Yes (complex) |
| llamafile | Native (v0.10+) | SSE | Partial | Yes | Awkward |
| mistral.rs | Native | SSE | Yes | Yes | Yes |
| LM Studio | Native | SSE | No | No | No |
| candle | None | N/A | Yes | Yes | No |
| llama-cpp-rs | None | N/A | Yes | Yes | No |

---

## 4. Tool-Call Parity Deep Dive

Phase 7c uses this Ollama-specific shape (confirmed in `agent_loop.rs:129-134`):

**Request:**
```json
{
  "model": "mistral",
  "messages": [...],
  "tools": [{"type": "function", "function": {"name": "...", "description": "...", "parameters": {...}}}],
  "stream": false
}
```

**Response expected:**
```json
{
  "message": {
    "tool_calls": [{"function": {"name": "read_memory", "arguments": {...}}}]
  }
}
```

The existing JSON-fence fallback in `agent_loop.rs:452-484` already handles models that
cannot emit structured `tool_calls` — so even weaker models degrade gracefully.

**Which alternatives need no protocol change:** None of the server-mode alternatives use
Ollama's exact NDJSON envelope. Switching would require:
1. Changing the streaming parser (NDJSON → SSE for all alternatives)
2. Changing the endpoint path (`/api/chat` → `/v1/chat/completions` for all alternatives)
3. The response shape (`message.tool_calls` vs OpenAI's `choices[0].message.tool_calls`)

These are bounded changes (~50-100 lines in `agent_loop.rs` + `ollama.rs`) but they are
real costs. Ollama's value is that it already speaks a protocol Phase 7c was built for.

---

## 5. Recommendation

**Option (a): Stay on Ollama. Ship as-is.**

The factual premise of the user's concern — that Ollama is "going paid" — is incorrect
as applied to the local runtime. Cloud is a separate additive product. The pitch is
intact. Phase 7c's entire integration path is unaffected.

**Rationale:**

1. Local `ollama serve` is explicitly guaranteed free ("always unlimited") per the
   published pricing page.
2. Phase 7c was purpose-built against Ollama's API contract. Switching now pays real
   migration cost for zero user benefit.
3. No viable alternative has better distribution story, model ecosystem breadth, or
   native macOS (`brew install ollama`) UX.
4. The JSON-fence fallback already protects against models that can't emit `tool_calls`
   — the existing code is more defensive than it appears.

**What to do instead of migrating:**

- **README update:** Clarify that Cellar Door uses the local `ollama serve` runtime, not
  Ollama Cloud. Explicitly state "no account or subscription required." This closes the
  narrative ambiguity that prompted this research.
- **Watch signal:** If Ollama ever gates `/api/chat` behind an auth header for local
  requests, that is the trip wire. Add a comment in `ollama.rs` to that effect.
- **Phase 7e posture:** Keep optional. If pulled forward, `mistral.rs` is the correct
  candidate — it has native tool-call support, is Rust-native, and can run in server
  mode (matching the current architecture) or embedded (the Phase 7e vision).

**Next concrete step:**
Open a PR to update `cellar-door-desktop/README.md` with a "Prerequisites" section that
explicitly states: "Ollama local runtime is free and open-source. No account is required.
Cellar Door does not use Ollama Cloud." This closes the narrative gap and protects the
product pitch against the "Ollama went paid" rumor.

---

## Sources

- [https://ollama.com/pricing](https://ollama.com/pricing) — Official pricing page, verified 2026-05-05
- [https://ollama.com/blog/cloud-models](https://ollama.com/blog/cloud-models) — Cloud launch blog post
- [https://docs.ollama.com/cloud](https://docs.ollama.com/cloud) — Ollama Cloud documentation
- [https://x.com/ollama/status/2032744932633620611](https://x.com/ollama/status/2032744932633620611) — Ollama's official X announcement on pricing tiers
- [https://github.com/ggml-org/llama.cpp/blob/master/docs/function-calling.md](https://github.com/ggml-org/llama.cpp/blob/master/docs/function-calling.md) — llama.cpp function-calling docs
- [https://github.com/EricLBuehler/mistral.rs/blob/master/docs/TOOL_CALLING.md](https://github.com/EricLBuehler/mistral.rs/blob/master/docs/TOOL_CALLING.md) — mistral.rs tool calling docs
- [https://lmstudio.ai/docs/developer/openai-compat/tools](https://lmstudio.ai/docs/developer/openai-compat/tools) — LM Studio tool use docs
- [https://github.com/mozilla-ai/llamafile](https://github.com/mozilla-ai/llamafile) — llamafile GitHub
- [https://github.com/mozilla-ai/llamafile/discussions/638](https://github.com/mozilla-ai/llamafile/discussions/638) — llamafile function calling discussion [unverified content — linked from search]
- Codebase: `cellar-door-desktop/src-tauri/src/agent_loop.rs` — Phase 7c tool-call loop
- Codebase: `cellar-door-desktop/src-tauri/src/ollama.rs` — sidecar spawn and health check
