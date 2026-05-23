# LM Studio backend for meetink LLM tasks

**Date:** 2026-05-23
**Status:** Approved (design)
**Topic:** Add LM Studio as a third LLM backend alongside `local` (MLX) and `claude`.

## Problem

meetink's titling, per-meeting summaries, and `/ask` run through a pluggable LLM
backend (`src/lib/titling.sh`). Today there are two backends:

- `local` — on-device Qwen3.5 via MLX, snapshotted into `~/.meetink/models/mlx/`
  and run in-process by `src/llm/mlx_helper.py`.
- `claude` — `claude -p` headless CLI, billed against the user's subscription.

Users who already run **LM Studio** (an OpenAI-compatible local server, default
`http://127.0.0.1:1234`) have larger / different models loaded there
(Qwen3-Coder-Next, Qwen3-VL-30B, a fast Qwen3-1.7B, …). They want those models
usable from meetink **without** re-downloading them into meetink's own MLX
store, and without disrupting the existing `local`/`claude` flow for everyone else.

## Goals

- Add an `lmstudio` backend, fully **additive** — `local` and `claude` behave
  exactly as today.
- Auto-discover the models LM Studio already has (including the fast small one),
  with their loaded-state and context length — no manual registry to maintain.
- Cover all three LLM tasks (titling, summaries, `/ask` + context summaries),
  matching the existing backends.
- Stay reusable: because the transport is plain OpenAI `/v1`, pointing the
  endpoint at any other OpenAI-compatible server also works.

## Non-goals

- No per-task model split (fast model for titling, big model for `/ask`) in this
  iteration — single active model, like the existing backends. Deferred; small
  follow-up if wanted.
- No changes to the capture/whisper/diarize pipeline.
- No new third-party Python dependencies (stdlib `urllib`/`json` only).

## Approach (chosen)

**A — `lmstudio` backend: LM-Studio-aware discovery + OpenAI transport.**

Discovery uses LM Studio's native REST `GET /api/v0/models`, which returns rich
metadata per model: `id`, `type` (llm/vlm), `quantization`, `state`
(`loaded`/`not-loaded`), `max_context_length`, `loaded_context_length`. Chat uses
the stable OpenAI-compatible `POST /v1/chat/completions`. If `/api/v0/models`
is absent (non-LM-Studio endpoint), discovery falls back to `/v1/models`
(bare ids only).

Rejected: a bare generic `server` backend (loses loaded-state / context length,
so `/llm list` and the budget chip degrade); filesystem scan of
`~/.lmstudio/models` (fragile id mapping, still needs the server up to infer).

## Architecture

### New files

- **`src/lib/lmstudio.sh`** — backend-specific shell helpers, sourced by
  `bin/meetink` alongside the other `src/lib/*.sh`. Provides:
  - `lmstudio_endpoint()` — `MEETINK_LMSTUDIO_URL` → config `lmstudio_endpoint=`
    → default `http://127.0.0.1:1234`.
  - `lmstudio_model_get()` / `lmstudio_model_set()` — active model id, persisted
    as `lmstudio_model=` in `$MK_CONFIG_FILE`; env override
    `MEETINK_LMSTUDIO_MODEL`. Default = the model LM Studio reports as `loaded`.
  - `_lmstudio_available()` — server reachable (short-timeout GET) **and** an
    active model resolvable. Used by `llm_available()`.
  - `lmstudio_list()` — render the discovered models (id · quant · ctx ·
    ●loaded/○not), marking the active one.
  - `_generate_lmstudio()` — wrapper that calls `server_helper.py` with the
    active endpoint/model.
  - `lmstudio_ctx()` — active model's `loaded_context_length` (fallback
    `max_context_length`, fallback 8192) for the budget chip.

- **`src/llm/server_helper.py`** — stdlib-only HTTP client mirroring
  `mlx_helper.py`'s CLI shape:
  - `--list --endpoint <url>` → prints discovered models as TSV
    (`id\tstate\tquant\tmax_ctx\tloaded_ctx`), trying `/api/v0/models` then
    `/v1/models`.
  - generate mode: `--endpoint --model --system --prompt --max-tokens --temp`
    → `POST /v1/chat/completions`, prints the assistant message text to stdout.
    Sends `chat_template_kwargs: {"enable_thinking": false}` to suppress Qwen3
    reasoning traces; strips any residual `<think>…</think>` defensively.
    Non-zero exit + empty stdout on any error (so callers treat it as "skip").

### Modified files

- **`src/lib/titling.sh`**
  - `title_backend_active()` — accept `lmstudio` (currently only `local`/`claude`
    pass validation, line ~147).
  - `llm_available()` — add `lmstudio) _lmstudio_available ;;`.
  - `generate_title()` — add `lmstudio) raw=$(_generate_title_lmstudio …) ;;`
    (thin wrapper over `_generate_lmstudio` with the title system prompt).
  - `cmd_llm`:
    - `backend` subcommand — accept/print `lmstudio`; on switch, warn if the
      server is unreachable.
    - `list` — when `backend=lmstudio`, call `lmstudio_list` instead of the MLX
      registry list.
    - `use` — when `backend=lmstudio`, set the active LM Studio model (validated
      against discovery) instead of an MLX registry entry.
  - `llm_status` — render the `lmstudio` branch (endpoint, active model, loaded
    state, reachability).
- **`src/lib/summary.sh`** — add `lmstudio)` to its backend `case`.
- **`src/lib/context.sh`** — add `lmstudio)` to its backend `case` (context-doc
  summaries).
- **`src/lib/ask.sh`** — route `/ask` through the lmstudio backend when active.
- **`src/lib/window.sh`** — budget chip uses `lmstudio_ctx()` for the token
  window when `backend=lmstudio`.
- **`src/lib/welcome.sh`** — `_titling_backend` / status dots recognise
  `lmstudio`.
- **`README.md`** — `/llm` section documents the `lmstudio` backend and its
  auto-discovery; note it needs LM Studio's local server running.
- **`CHANGELOG.md`** — version entry.

## Data flow (titling example)

```
/stop → title_session_file → generate_title
  └─ case backend=lmstudio → _generate_title_lmstudio
       └─ server_helper.py --endpoint http://127.0.0.1:1234
                           --model <active> --system <rules> --prompt <body>
            └─ POST /v1/chat/completions  → assistant text → _clean_title → slug
```

Summaries (`summary.sh`), context-doc summaries (`context.sh`), and `/ask`
(`ask.sh`) follow the same dispatch shape, each already guarded by
`llm_available`.

## Config & environment

| Concern        | Config key (`$MK_CONFIG_FILE`) | Env override            | Default                   |
|----------------|--------------------------------|-------------------------|---------------------------|
| Active backend | `title_backend=lmstudio`       | `MEETINK_TITLE_BACKEND` | `local`                   |
| Endpoint       | `lmstudio_endpoint=`           | `MEETINK_LMSTUDIO_URL`  | `http://127.0.0.1:1234`   |
| Active model   | `lmstudio_model=`              | `MEETINK_LMSTUDIO_MODEL`| LM Studio's `loaded` model|

## Error handling & degradation

- Server down / unreachable → `_lmstudio_available` false → titling & summaries
  no-op with the existing "(titling skipped)" path; `/ask` prints a clear
  "LM Studio not reachable at <endpoint>" message.
- No model resolvable (none loaded, none pinned, JIT off) → treated as
  unavailable; `/llm status` explains how to pin one (`/llm use <id>`).
- Thinking models → `enable_thinking:false` + `<think>` stripping keep titles and
  summaries clean.

## Verification (no automated test suite in this repo)

Manual, against the live server:
1. `meetink llm backend lmstudio` → confirms switch, warns if server down.
2. `meetink llm list` → shows the discovered models with state/quant/ctx.
3. `meetink llm use qwen3-1.7b-mlx` → pins the fast model.
4. Generate a title on a sample transcript → produces a slug, no `<think>` leakage.
5. `meetink ask "<question>"` against a recent transcript → coherent answer;
   budget chip shows the model's context window.
6. Quit LM Studio → titling/summary no-op gracefully; `/ask` prints the
   unreachable message. Switch back to `local` → unchanged behaviour.

## Deferred

- Per-task model split (fast titling model + big `/ask` model).
- Surfacing LM Studio JIT-load hints in `/llm status`.
