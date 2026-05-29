# Changelog

## [unreleased] - 2026-05-28
### Fixes
- **diarize-server orphaned after terminal-close (multi-GB leak).** The REPL
  only ran `diarize_stop` on the graceful exit paths (`/quit`, EOF/Ctrl-D) —
  there was no `HUP`/`TERM`/`EXIT` trap, so closing the terminal window
  (SIGHUP) or killing the launcher skipped cleanup and orphaned the
  `disown`ed sidecar. Observed in the wild as a 10-hour, 31 GB python
  process. Fixed on two layers: (1) `src/lib/repl.sh` now traps
  `EXIT`/`HUP`/`TERM` to call the (idempotent) `diarize_stop`, covering
  terminal-close and SIGTERM; `INT` is intentionally left untrapped so
  Ctrl-C keeps clearing the input line. (2) `src/diarize/server.py` runs a
  daemon parent-death watchdog that hard-exits when its PPID changes (kernel
  reparents to launchd on launcher death), covering the paths a trap can't
  reach — `kill -9`, panics, power-edge crashes.

### Design Rationale
- Belt-and-suspenders by design: the trap is the primary, fast path; the
  watchdog is the safety net for un-trappable deaths. `diarize_stop` is
  pidfile-guarded so firing via both trap and the existing inline post-loop
  call is a harmless no-op. PPID-change (rather than `== 1`) is the orphan
  signal — general across platforms and subreapers.

### Notes & Caveats
- The watchdog polls every 5 s, so an orphaned server lingers at most ~5 s
  after its launcher dies (negligible vs. the prior unbounded lifetime).
- `/stop` still deliberately leaves the sidecar running (cluster inspection
  / `/profile assign` afterwards); lifetime is bound to the REPL, not to an
  individual recording.

## [unreleased] - 2026-05-23
### Fixes
- **diarize-server memory leak (~44 GB over 5 days).** `_cluster_or_create`
  appended a row to a session cluster's sample matrix via `np.vstack` on every
  unmatched `/identify`, with no cap. The monotonically-growing realloc churn
  fragmented macOS libmalloc's MEDIUM magazine (which never returns freed
  blocks to the OS), so RSS ballooned to ~73× the live data and persisted even
  across `/session/clear`. Root-caused by isolation (constant-input `embed()`
  plateaus at ~650 MB; the cluster churn alone hit 1.5 GB per 20k calls).
  Fixed by capping per-cluster samples to the most-recent `CLUSTER_MAX_SAMPLES`
  (default 64, `MEETINK_CLUSTER_MAX_SAMPLES`) with a contiguous copy, so every
  allocation stays the same size class and the heap no longer fragments. The
  same recent-window cap now bounds the auto-train profile path
  (`PROFILE_MAX_SAMPLES`, default 500, `MEETINK_PROFILE_MAX_SAMPLES`). Verified:
  the cluster path's RSS growth dropped from +1502 MB/20k calls to +3.3 MB/40k
  calls (flat); the full `embed()`+cluster `/identify` path plateaus at ~700 MB.
  Bonus: also removes the latent O(N²) per-call CPU cost of recomputing the
  centroid over an ever-growing matrix.

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
