# Changelog

## [unreleased] - 2026-05-23
### Features
- New `lmstudio` LLM backend: titling, per-meeting summaries, context-doc
  summaries, and `/ask` can use models served by LM Studio's local server
  (OpenAI-compatible). Auto-discovers downloaded models (id, quantization,
  context length, loaded state) via `/api/v0/models`; generation via
  `/v1/chat/completions`. New commands: `/llm backend lmstudio`, and
  `/llm list` / `/llm use <id>` operate on LM Studio's models when active.

### Design Rationale
- Additive third backend — `local` (MLX) and `claude` are unchanged. Transport
  is plain OpenAI `/v1`, so `MEETINK_LMSTUDIO_URL` can target any compatible
  server (llama.cpp-server, vLLM, …); LM Studio's native `/api/v0` is used only
  for richer discovery (falls back to `/v1/models` elsewhere).
- stdlib-only HTTP client (`src/llm/server_helper.py`) — no new Python deps.
- LM Studio's MLX engine ignores `chat_template_kwargs.enable_thinking`, so
  Qwen3's `/no_think` soft-switch is injected (plus defensive `<think>`
  stripping) to keep reasoning models from spending the token budget on a
  separate `reasoning_content` block and returning empty `content`.
- The lmstudio titling prompt drops the local path's "untitled session" escape
  hatch, which small models (e.g. `qwen3-1.7b`) emit for nearly any input.

### Notes & Caveats
- Requires LM Studio's local server running (Developer tab → Start Server, or
  `lms server start`). Falls back gracefully — no-op titling/summaries and a
  clear `/ask` message — when unreachable.
- The REPL budget chip uses the active model's reported context window,
  persisted as `lmstudio_ctx=` on `/llm use`.
- Summary/`/ask` quality scales with model size; the fast small model is best
  for titling, a larger one for `/ask`.
