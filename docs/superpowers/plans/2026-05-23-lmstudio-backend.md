# LM Studio Backend Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `lmstudio` as a third meetink LLM backend (alongside `local` MLX and `claude`) that auto-discovers the models LM Studio already serves and uses them for titling, summaries, and `/ask`.

**Architecture:** A new stdlib-only Python HTTP client (`src/llm/server_helper.py`) talks to LM Studio's OpenAI-compatible `/v1/chat/completions` and its native `/api/v0/models` discovery endpoint. A new shell module (`src/lib/lmstudio.sh`) wraps it and plugs an `lmstudio` case into the four existing backend dispatch sites. The interactive REPL (`repl.py`) and the welcome screen learn the new backend so routing, the budget chip, and status display stay correct. The existing `local`/`claude` paths are untouched.

**Tech Stack:** zsh (launcher + lib), Python 3 stdlib (`urllib`/`json`), LM Studio local server (default `http://127.0.0.1:1234`), Qwen3 MLX models.

**Conventions:** Project commits use Conventional Commits and **no attribution trailer** (attribution disabled in the user's git config). There is no automated test framework in this repo; pure Python helpers get offline assert-tests, everything else gets a concrete live smoke command against the running LM Studio server.

---

## File Structure

**Create:**
- `src/llm/server_helper.py` — stdlib HTTP client: pure parse/extract helpers + `discover()`/`chat()` + a CLI (`--list` and generate modes). Importable `chat()` reused by `context_helper.py`.
- `src/llm/test_server_helper.py` — offline assert-tests for the pure functions (runnable with plain `python3`, also pytest-compatible).
- `src/lib/lmstudio.sh` — backend shell helpers (endpoint/model/ctx config, availability, list, generate wrapper).

**Modify:**
- `bin/meetink` — source `lmstudio.sh`.
- `src/lib/titling.sh` — accept `lmstudio` in backend validation; dispatch titling; `/llm` backend/list/use/status.
- `src/lib/summary.sh` — `lmstudio` case in `summary_save`.
- `src/lib/ask.sh` — make the `claude` precheck backend-conditional; add `_ask_lmstudio`.
- `src/lib/context.sh` — `lmstudio` case in the context-doc summary dispatch.
- `src/llm/context_helper.py` — accept `--backend lmstudio` + `--endpoint`, import `chat()`.
- `src/repl/repl.py` — `_title_backend` accept `lmstudio`; budget + label + autocomplete.
- `src/lib/welcome.sh` — `_titling_backend`/`_titling_label`/`_has_titling` learn `lmstudio`.
- `README.md`, `CHANGELOG.md` — docs.

**Shared contracts (must stay consistent across tasks):**
- Config file: `$MK_HOME/config` (`MK_CONFIG_FILE`), `key=value` lines.
- New config keys: `title_backend=lmstudio`, `lmstudio_endpoint=`, `lmstudio_model=`, `lmstudio_ctx=`.
- New env overrides: `MEETINK_LMSTUDIO_URL`, `MEETINK_LMSTUDIO_MODEL` (`MEETINK_TITLE_BACKEND=lmstudio` already exists).
- Default endpoint constant: `http://127.0.0.1:1234`.
- `server_helper.py` generate CLI flags mirror `mlx_helper.py`: `--model --system --prompt --max-tokens --temp`, plus `--endpoint`.
- `--list` output is TSV: `id\tstate\tquant\tmax_ctx\tloaded_ctx` (trailing fields empty when unknown).

---

## Task 1: `server_helper.py` — HTTP client + pure helpers + offline tests

**Files:**
- Create: `src/llm/server_helper.py`
- Create: `src/llm/test_server_helper.py`

- [ ] **Step 1: Write the failing offline test**

Create `src/llm/test_server_helper.py`:

```python
#!/usr/bin/env python3
"""Offline tests for server_helper pure functions. No network.
Run: python3 src/llm/test_server_helper.py   (prints OK)  — also pytest-compatible."""
from __future__ import annotations
import os, sys
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from llm.server_helper import parse_models, extract_message, strip_think, _api_base


def test_parse_models_api_v0():
    payload = {"data": [
        {"id": "qwen3-1.7b-mlx", "state": "not-loaded", "quantization": "8bit",
         "max_context_length": 40960},
        {"id": "qwen3-vl-30b-a3b-thinking-mlx", "state": "loaded", "quantization": "8bit",
         "max_context_length": 262144, "loaded_context_length": 32768},
    ]}
    rows = parse_models(payload)
    assert rows[0] == {"id": "qwen3-1.7b-mlx", "state": "not-loaded", "quant": "8bit",
                       "max_ctx": 40960, "loaded_ctx": 0}
    assert rows[1]["loaded_ctx"] == 32768 and rows[1]["state"] == "loaded"


def test_parse_models_v1_fallback():
    # /v1/models has only ids — other fields blank/zero.
    payload = {"data": [{"id": "foo", "object": "model"}]}
    rows = parse_models(payload)
    assert rows == [{"id": "foo", "state": "", "quant": "", "max_ctx": 0, "loaded_ctx": 0}]


def test_extract_message_and_strip_think():
    payload = {"choices": [{"message": {"content": "<think>hmm</think>\nproject kickoff sync"}}]}
    assert extract_message(payload) == "project kickoff sync"


def test_strip_think_multiline():
    assert strip_think("<think>\na\nb\n</think>\nanswer") == "answer"
    assert strip_think("no tags here") == "no tags here"


def test_api_base_normalizes():
    assert _api_base("http://127.0.0.1:1234/") == "http://127.0.0.1:1234"
    assert _api_base("http://127.0.0.1:1234/v1") == "http://127.0.0.1:1234"
    assert _api_base("http://host:1234/v1/") == "http://host:1234"


def _run():
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            fn(); print(f"  ok {name}")
    print("OK")


if __name__ == "__main__":
    _run()
```

- [ ] **Step 2: Run it to verify it fails**

Run: `python3 src/llm/test_server_helper.py`
Expected: FAIL — `ModuleNotFoundError: No module named 'llm.server_helper'`.

- [ ] **Step 3: Implement `server_helper.py`**

Create `src/llm/server_helper.py`:

```python
#!/usr/bin/env python3
"""OpenAI-compatible chat client for meetink's `lmstudio` backend.

Talks to LM Studio's local server (default http://127.0.0.1:1234):
  - discovery via the native REST  GET /api/v0/models  (rich metadata),
    falling back to OpenAI         GET /v1/models       (ids only);
  - generation via OpenAI          POST /v1/chat/completions.

stdlib only (urllib + json) — no third-party deps. Mirrors mlx_helper.py's
CLI shape so the shell dispatch sites call it the same way. The chat()
function is also imported by context_helper.py for context-doc summaries.

Exit codes (CLI): 0 ok · 2 server unreachable / HTTP error · 3 bad response.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
import urllib.error
import urllib.request

DEFAULT_ENDPOINT = "http://127.0.0.1:1234"
_THINK_RE = re.compile(r"<think>.*?</think>", re.DOTALL)


def _api_base(endpoint: str) -> str:
    """Normalize a user-supplied endpoint to the bare base URL.
    Accepts http://host:port, .../, or .../v1[/]; returns http://host:port."""
    base = endpoint.strip().rstrip("/")
    if base.endswith("/v1"):
        base = base[: -len("/v1")]
    return base


def strip_think(text: str) -> str:
    """Remove <think>…</think> reasoning blocks and trim surrounding blanks."""
    return _THINK_RE.sub("", text).strip()


def parse_models(payload: dict) -> list[dict]:
    """Normalize an /api/v0/models or /v1/models response into uniform rows."""
    rows: list[dict] = []
    for m in payload.get("data", []):
        rows.append({
            "id": m.get("id", ""),
            "state": m.get("state", ""),
            "quant": m.get("quantization", ""),
            "max_ctx": int(m.get("max_context_length", 0) or 0),
            "loaded_ctx": int(m.get("loaded_context_length", 0) or 0),
        })
    return rows


def extract_message(payload: dict) -> str:
    """Pull the assistant text out of a chat-completions response (think-stripped)."""
    choices = payload.get("choices") or []
    if not choices:
        return ""
    content = (choices[0].get("message") or {}).get("content", "") or ""
    return strip_think(content)


def _get_json(url: str, timeout: float = 5.0) -> dict:
    req = urllib.request.Request(url, headers={"Accept": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode("utf-8"))


def _post_json(url: str, body: dict, timeout: float = 120.0) -> dict:
    data = json.dumps(body).encode("utf-8")
    req = urllib.request.Request(
        url, data=data,
        headers={"Content-Type": "application/json",
                 "Authorization": "Bearer lm-studio"},  # placeholder; LM Studio ignores
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode("utf-8"))


def discover(endpoint: str) -> list[dict]:
    """Return model rows. Prefer /api/v0/models, fall back to /v1/models."""
    base = _api_base(endpoint)
    try:
        return parse_models(_get_json(f"{base}/api/v0/models"))
    except (urllib.error.URLError, ValueError, KeyError):
        return parse_models(_get_json(f"{base}/v1/models"))


def chat(endpoint: str, model: str, system: str, prompt: str,
         max_tokens: int = 512, temp: float = 0.4) -> str:
    """One-shot chat completion. Returns the assistant text (think-stripped).

    Sends chat_template_kwargs:{enable_thinking:false} so Qwen3 reasoning
    models answer directly; retries once without that field for servers that
    reject unknown keys (older LM Studio)."""
    base = _api_base(endpoint)
    url = f"{base}/v1/chat/completions"
    messages = []
    if system:
        messages.append({"role": "system", "content": system})
    messages.append({"role": "user", "content": prompt})
    body = {
        "model": model,
        "messages": messages,
        "max_tokens": max_tokens,
        "temperature": temp,
        "stream": False,
        "chat_template_kwargs": {"enable_thinking": False},
    }
    try:
        return extract_message(_post_json(url, body))
    except urllib.error.HTTPError as e:
        if e.code == 400:  # server may reject chat_template_kwargs — retry plain
            body.pop("chat_template_kwargs", None)
            return extract_message(_post_json(url, body))
        raise


def _die(code: int, msg: str) -> None:
    print(f"server_helper: {msg}", file=sys.stderr)
    sys.exit(code)


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--endpoint", default=DEFAULT_ENDPOINT)
    p.add_argument("--list", action="store_true", help="print discovered models as TSV")
    p.add_argument("--model", default="")
    p.add_argument("--system", default="")
    p.add_argument("--prompt", default="")
    p.add_argument("--max-tokens", type=int, default=512)
    p.add_argument("--temp", type=float, default=0.4)
    args = p.parse_args()

    if args.list:
        try:
            rows = discover(args.endpoint)
        except (urllib.error.URLError, ValueError) as e:
            _die(2, f"cannot reach LM Studio at {args.endpoint}: {e}")
        for r in rows:
            print(f"{r['id']}\t{r['state']}\t{r['quant']}\t{r['max_ctx']}\t{r['loaded_ctx']}")
        return 0

    if not args.model or not args.prompt:
        _die(3, "generate mode requires --model and --prompt")
    try:
        out = chat(args.endpoint, args.model, args.system, args.prompt,
                   args.max_tokens, args.temp)
    except urllib.error.URLError as e:
        _die(2, f"request failed: {e}")
    except (ValueError, KeyError) as e:
        _die(3, f"bad response: {e}")
    print(out, end="")
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 4: Run the offline tests to verify they pass**

Run: `python3 src/llm/test_server_helper.py`
Expected: prints `ok test_...` lines then `OK`, exit 0.

- [ ] **Step 5: Live smoke against the running LM Studio server**

Run: `python3 src/llm/server_helper.py --list --endpoint http://127.0.0.1:1234`
Expected: 5 TSV rows incl. `qwen3-1.7b-mlx	not-loaded	8bit	40960	0` and a `…thinking-mlx	loaded	8bit	262144	32768` row.

Run a generation:
`python3 src/llm/server_helper.py --endpoint http://127.0.0.1:1234 --model qwen3-1.7b-mlx --system "Reply with exactly one lowercase word." --prompt "say hello" --max-tokens 10 --temp 0.2`
Expected: a short word printed, no `<think>` tags. (LM Studio JIT-loads `qwen3-1.7b-mlx` on first call; allow a few seconds.)

- [ ] **Step 6: Commit**

```bash
git add src/llm/server_helper.py src/llm/test_server_helper.py
git commit -m "feat(llm): OpenAI-compatible LM Studio HTTP client (server_helper)"
```

---

## Task 2: `lmstudio.sh` — backend shell helpers

**Files:**
- Create: `src/lib/lmstudio.sh`
- Modify: `bin/meetink:40` (add source line)

- [ ] **Step 1: Implement `src/lib/lmstudio.sh`**

Create `src/lib/lmstudio.sh`:

```zsh
#!/bin/zsh
# LM Studio backend helpers. The `lmstudio` backend talks to LM Studio's
# OpenAI-compatible local server (default http://127.0.0.1:1234) via
# src/llm/server_helper.py. Discovery uses LM Studio's /api/v0/models so we
# can show which models are downloaded/loaded and their context length.
#
# Sourced by bin/meetink AFTER titling.sh (shares $MK_CONFIG_FILE from
# models.sh and the C[] colour table from ui.sh).
# Depends on: $MK_CONFIG_FILE, $MK_PY_VENV, $MK_ROOT, C[].

MK_LMSTUDIO_DEFAULT_URL="http://127.0.0.1:1234"

# Python that can run server_helper.py. Prefer the REPL venv (always present
# after setup), fall back to system python3 — server_helper is stdlib-only.
_lmstudio_python() {
    if [[ -x "$MK_PY_VENV/bin/python" ]]; then
        print -n -- "$MK_PY_VENV/bin/python"
    else
        print -n -- "python3"
    fi
}

# Active endpoint: env > config > default.
lmstudio_endpoint() {
    if [[ -n "$MEETINK_LMSTUDIO_URL" ]]; then
        print -n -- "$MEETINK_LMSTUDIO_URL"; return
    fi
    if [[ -f "$MK_CONFIG_FILE" ]]; then
        local v=$(grep '^lmstudio_endpoint=' "$MK_CONFIG_FILE" 2>/dev/null | head -1 | cut -d= -f2-)
        [[ -n "$v" ]] && { print -n -- "$v"; return; }
    fi
    print -n -- "$MK_LMSTUDIO_DEFAULT_URL"
}

# Raw configured model id (may be empty): env > config.
lmstudio_model_get() {
    if [[ -n "$MEETINK_LMSTUDIO_MODEL" ]]; then
        print -n -- "$MEETINK_LMSTUDIO_MODEL"; return
    fi
    if [[ -f "$MK_CONFIG_FILE" ]]; then
        grep '^lmstudio_model=' "$MK_CONFIG_FILE" 2>/dev/null | head -1 | cut -d= -f2-
    fi
}

# Discover models as TSV rows: id<TAB>state<TAB>quant<TAB>max_ctx<TAB>loaded_ctx
_lmstudio_discover() {
    "$(_lmstudio_python)" "$MK_ROOT/src/llm/server_helper.py" \
        --list --endpoint "$(lmstudio_endpoint)" 2>/dev/null
}

# Resolve the model id to actually use: configured value, else the model the
# server reports as `loaded`, else the first discovered model. Empty if none.
lmstudio_model_resolve() {
    local m=$(lmstudio_model_get)
    [[ -n "$m" ]] && { print -n -- "$m"; return; }
    local rows=$(_lmstudio_discover)
    [[ -z "$rows" ]] && return 1
    # Prefer a loaded model.
    local loaded=$(print -- "$rows" | awk -F'\t' '$2=="loaded"{print $1; exit}')
    [[ -n "$loaded" ]] && { print -n -- "$loaded"; return; }
    print -- "$rows" | awk -F'\t' 'NR==1{print $1; exit}'
}

# Set the active LM Studio model (validated against discovery). Persists both
# lmstudio_model= and lmstudio_ctx= (loaded_ctx if >0 else max_ctx).
lmstudio_model_set() {
    local id="$1"
    local rows=$(_lmstudio_discover)
    if [[ -z "$rows" ]]; then
        print -P "${C[red]}error:${C[reset]} LM Studio not reachable at ${C[bold]}$(lmstudio_endpoint)${C[reset]}"
        return 1
    fi
    local line=$(print -- "$rows" | awk -F'\t' -v id="$id" '$1==id{print; exit}')
    if [[ -z "$line" ]]; then
        print -P "${C[red]}error:${C[reset]} model ${C[bold]}$id${C[reset]} not found in LM Studio"
        print -P "  Run ${C[bright_cyan]}/llm list${C[reset]} to see available models."
        return 1
    fi
    local max_ctx=$(print -- "$line" | cut -f4)
    local loaded_ctx=$(print -- "$line" | cut -f5)
    local ctx="$max_ctx"
    [[ -n "$loaded_ctx" && "$loaded_ctx" != "0" ]] && ctx="$loaded_ctx"
    [[ -z "$ctx" || "$ctx" == "0" ]] && ctx="8192"

    mkdir -p "${MK_CONFIG_FILE:h}"
    _lmstudio_cfg_put "lmstudio_model" "$id"
    _lmstudio_cfg_put "lmstudio_ctx" "$ctx"
    print -P "${C[green]}✓${C[reset]} Active LM Studio model: ${C[bold]}$id${C[reset]} ${C[dim]}(ctx ${ctx})${C[reset]}"
}

# Upsert a key=value line in the config file.
_lmstudio_cfg_put() {
    local key="$1" val="$2"
    if [[ -f "$MK_CONFIG_FILE" ]] && grep -q "^${key}=" "$MK_CONFIG_FILE"; then
        sed -i '' "s|^${key}=.*|${key}=${val}|" "$MK_CONFIG_FILE"
    else
        echo "${key}=${val}" >> "$MK_CONFIG_FILE"
    fi
}

# Cheap reachability check (curl, 2s timeout) — used by availability + status.
_lmstudio_reachable() {
    local base="${$(lmstudio_endpoint)%/}"
    base="${base%/v1}"
    curl -s --max-time 2 -o /dev/null "${base}/v1/models" 2>/dev/null
}

# Backend is available when the server is reachable AND a model resolves.
_lmstudio_available() {
    _lmstudio_reachable || return 1
    [[ -n "$(lmstudio_model_resolve 2>/dev/null)" ]]
}

# /llm list rendering when backend=lmstudio.
lmstudio_list() {
    print -P ""
    print -P "${C[bright_yellow]}LM STUDIO MODELS${C[reset]} ${C[dim]}($(lmstudio_endpoint))${C[reset]}"
    if ! _lmstudio_reachable; then
        print -P "  ${C[red]}○${C[reset]} server not reachable — start LM Studio's local server"
        print -P ""
        return 0
    fi
    local active=$(lmstudio_model_resolve 2>/dev/null)
    local rows=$(_lmstudio_discover)
    if [[ -z "$rows" ]]; then
        print -P "  ${C[dim]}no models reported${C[reset]}"; print -P ""; return 0
    fi
    local id state quant max_ctx loaded_ctx
    print -- "$rows" | while IFS=$'\t' read -r id state quant max_ctx loaded_ctx; do
        local marker="  "
        [[ "$id" == "$active" ]] && marker="${C[bright_cyan]}▸ ${C[reset]}"
        local dot="${C[gray]}○${C[reset]}"
        [[ "$state" == "loaded" ]] && dot="${C[green]}●${C[reset]}"
        local ctx="$max_ctx"
        [[ -n "$loaded_ctx" && "$loaded_ctx" != "0" ]] && ctx="${loaded_ctx}/${max_ctx}"
        print -P "${marker}${C[bold]}${id}${C[reset]}  ${C[dim]}${quant}  ctx ${ctx}${C[reset]}  ${dot} ${state}"
    done
    print -P ""
    print -P "  ${C[dim]}/llm use <id>${C[reset]}   set active LM Studio model (▸)"
    print -P ""
}

# Core generate wrapper used by titling/summary/ask.
# Args: $1=system  $2=prompt  $3=max_tokens  $4=temp
_generate_lmstudio() {
    local model=$(lmstudio_model_resolve 2>/dev/null)
    [[ -z "$model" ]] && return 1
    "$(_lmstudio_python)" "$MK_ROOT/src/llm/server_helper.py" \
        --endpoint "$(lmstudio_endpoint)" \
        --model "$model" \
        --system "$1" \
        --prompt "$2" \
        --max-tokens "$3" \
        --temp "$4" \
        2>/dev/null
}
```

- [ ] **Step 2: Source it from `bin/meetink`**

Modify `bin/meetink` — add a line immediately after line 40 (`source "$MK_ROOT/src/lib/titling.sh"`):

```zsh
source "$MK_ROOT/src/lib/lmstudio.sh"
```

- [ ] **Step 3: Verify the module loads and helpers resolve**

Run: `bin/meetink llm backend` (this sources everything; should not error).
Then a direct function check:
`zsh -c 'MK_HOME=$HOME/.meetink; MK_ROOT="$PWD"; MK_PY_VENV=$HOME/.meetink/py-venv; source src/lib/ui.sh; source src/lib/models.sh; source src/lib/lmstudio.sh; lmstudio_endpoint; echo; _lmstudio_discover | head -2'`
Expected: prints `http://127.0.0.1:1234` then two TSV model rows.

- [ ] **Step 4: Commit**

```bash
git add src/lib/lmstudio.sh bin/meetink
git commit -m "feat(llm): lmstudio.sh backend helpers; source from launcher"
```

---

## Task 3: Wire `titling.sh` — validation, dispatch, `/llm` subcommands

**Files:**
- Modify: `src/lib/titling.sh` (lines ~147, ~188, ~514, `cmd_llm` ~671, `llm_status` ~379)

- [ ] **Step 1: Accept `lmstudio` in `title_backend_active`**

In `title_backend_active()` change the validation (line ~147) from:

```zsh
        if [[ "$v" == "local" || "$v" == "claude" ]]; then
```
to:
```zsh
        if [[ "$v" == "local" || "$v" == "claude" || "$v" == "lmstudio" ]]; then
```

- [ ] **Step 2: Add the availability case**

In `llm_available()` (line ~188), add a case branch:

```zsh
llm_available() {
    case "$(title_backend_active)" in
        claude)   _claude_available ;;
        lmstudio) _lmstudio_available ;;
        *)        _local_available  ;;
    esac
}
```

- [ ] **Step 3: Add the titling generator + dispatch**

Add `_generate_title_lmstudio` next to `_generate_title_local` (after line ~475):

```zsh
_generate_title_lmstudio() {
    local content="$1"
    local system_prompt="You name the SUBJECT of a meeting transcript in 3 to 5 lowercase words.
Output rules:
- ONLY the 3-5 word topic, nothing else
- lowercase, no punctuation, no quotes, no \"title:\" prefix
- describe what was discussed; do NOT say \"meeting\", \"transcript\", or \"conversation\"
- if there's not enough content to tell, output: untitled session"
    local user_prompt="${content}

Topic (3-5 words):"
    _generate_lmstudio "$system_prompt" "$user_prompt" 30 0.3
}
```

In `generate_title()` (line ~514) add the dispatch case:

```zsh
    case "$(title_backend_active)" in
        claude)   raw=$(_generate_title_claude   "$content") ;;
        lmstudio) raw=$(_generate_title_lmstudio "$content") ;;
        *)        raw=$(_generate_title_local    "$content") ;;
    esac
```

- [ ] **Step 4: Wire `/llm list` and `/llm use` to the backend**

In `cmd_llm()`, change the `list` case (line ~659) to branch by backend:

```zsh
        list|ls|models)
            if [[ "$(title_backend_active)" == "lmstudio" ]]; then
                lmstudio_list
            else
                llm_list
            fi
            ;;
```

Change the `use` case (line ~665) to branch by backend:

```zsh
        use|switch|set)
            if [[ "$(title_backend_active)" == "lmstudio" ]]; then
                lmstudio_model_set "$2"
            else
                llm_use "$2"
            fi
            ;;
```

- [ ] **Step 5: Add the `lmstudio` backend choice**

In the `backend)` case (line ~671), add an `lmstudio` choice and mention it in the no-arg help:

```zsh
                "")
                    print -P "  Backend: ${C[bold]}$(title_backend_active)${C[reset]}"
                    print -P "  ${C[dim]}/llm backend local${C[reset]}     on-device MLX (Qwen3.5, offline)"
                    print -P "  ${C[dim]}/llm backend lmstudio${C[reset]}  models served by LM Studio"
                    print -P "  ${C[dim]}/llm backend claude${C[reset]}    Claude via subscription (network)"
                    ;;
```

and add the case arm (after the `claude)` arm, before `*)`):

```zsh
                lmstudio)
                    title_backend_set "lmstudio"
                    print -P "${C[green]}✓${C[reset]} Backend set to ${C[bold]}lmstudio${C[reset]} ${C[dim]}($(lmstudio_endpoint))${C[reset]}"
                    if ! _lmstudio_reachable; then
                        print -P "  ${C[red]}!${C[reset]} ${C[dim]}server not reachable — start LM Studio's local server${C[reset]}"
                    elif [[ -z "$(lmstudio_model_get)" ]]; then
                        print -P "  ${C[dim]}Using LM Studio's loaded model. Pin one with${C[reset]} ${C[bright_cyan]}/llm use <id>${C[reset]} ${C[dim]}(see /llm list).${C[reset]}"
                    fi
                    ;;
```

Also update the unknown-backend error line to list `lmstudio`:

```zsh
                *)
                    print -P "${C[red]}unknown backend:${C[reset]} ${C[dim]}$choice${C[reset]} ${C[dim]}(use: local | lmstudio | claude)${C[reset]}"
                    ;;
```

- [ ] **Step 6: Add an `lmstudio` branch to `llm_status`**

In `llm_status()` (line ~379), after the `if [[ "$backend" == "claude" ]]` block, insert an `elif` for lmstudio:

```zsh
    elif [[ "$backend" == "lmstudio" ]]; then
        print -P "  Endpoint: ${C[bold]}$(lmstudio_endpoint)${C[reset]}"
        if _lmstudio_reachable; then
            print -P "  ${C[green]}●${C[reset]} server reachable ${C[dim]}(model: $(lmstudio_model_resolve 2>/dev/null))${C[reset]}"
        else
            print -P "  ${C[gray]}○${C[reset]} server not reachable ${C[dim]}(start LM Studio's local server)${C[reset]}"
        fi
```

(Convert the existing `if … else` to `if … elif … else` so the local branch stays the `else`.)

- [ ] **Step 7: Verify backend switching + dispatch end-to-end**

```bash
bin/meetink llm backend lmstudio        # → "Backend set to lmstudio (…)"
bin/meetink llm list                     # → LM Studio model table with ● loaded marker
bin/meetink llm use qwen3-1.7b-mlx        # → "Active LM Studio model: qwen3-1.7b-mlx (ctx 40960)"
bin/meetink llm status                    # → Endpoint + reachable + model line
```

Title generation against a sample transcript:
```bash
printf '# Meeting Transcript\nStarted: now\n[00:00:01] ME: lets finalize the q3 pricing tiers and the launch date\n[00:00:05] THEM: agreed, ill draft the pricing table\n' > /tmp/mk-sample.txt
zsh -c 'MK_HOME=$HOME/.meetink; MK_ROOT="$PWD"; MK_PY_VENV=$HOME/.meetink/py-venv; MEETINK_TITLE_BACKEND=lmstudio; source src/lib/ui.sh; source src/lib/models.sh; source src/lib/titling.sh; source src/lib/lmstudio.sh; generate_title /tmp/mk-sample.txt'
```
Expected: a 3-5 word lowercase slug (e.g. `q3-pricing-tiers-launch`), no `<think>` leakage.

- [ ] **Step 8: Commit**

```bash
git add src/lib/titling.sh
git commit -m "feat(llm): titling + /llm dispatch for lmstudio backend"
```

---

## Task 4: Wire `summary.sh`

**Files:**
- Modify: `src/lib/summary.sh` (`_summary_generate_lmstudio` + `summary_save` case ~114)

- [ ] **Step 1: Add the lmstudio summary generator**

After `_summary_generate_claude` (line ~96) add:

```zsh
_summary_generate_lmstudio() {
    local transcript_text="$1"
    _generate_lmstudio "$(_summary_system_prompt)" "$transcript_text" 600 0.3
}
```

- [ ] **Step 2: Add the dispatch case**

In `summary_save()` (line ~114) add an `lmstudio)` arm before the `*)` local arm:

```zsh
    case "$backend" in
        claude)
            if ! command -v claude >/dev/null 2>&1; then
                return 1
            fi
            model_label=$(claude_model_active)
            raw=$(_summary_generate_claude "$body") || return 1
            ;;
        lmstudio)
            _lmstudio_available || return 1
            model_label=$(lmstudio_model_resolve 2>/dev/null)
            raw=$(_summary_generate_lmstudio "$body") || return 1
            ;;
        *)
            model_label=$(local_llm_active_get)
            raw=$(_summary_generate_local "$body") || return 1
            ;;
    esac
```

- [ ] **Step 3: Verify summary generation**

```bash
zsh -c 'MK_HOME=$HOME/.meetink; MK_ROOT="$PWD"; MK_PY_VENV=$HOME/.meetink/py-venv; MEETINK_TITLE_BACKEND=lmstudio; source src/lib/ui.sh; source src/lib/models.sh; source src/lib/titling.sh; source src/lib/lmstudio.sh; source src/lib/summary.sh; cp /tmp/mk-sample.txt /tmp/mk-sum.txt; summary_save /tmp/mk-sum.txt; echo "----"; cat /tmp/mk-sum.summary.md'
```
Expected: a `.summary.md` with `generated_by: <model id>` frontmatter and the four sections (Topics/Decisions/Action items/Open questions), no `<think>`.

- [ ] **Step 4: Commit**

```bash
git add src/lib/summary.sh
git commit -m "feat(llm): per-meeting summaries via lmstudio backend"
```

---

## Task 5: Wire `context.sh` + `context_helper.py`

**Files:**
- Modify: `src/llm/context_helper.py` (argparse ~277, `cmd_summarize` ~159-198)
- Modify: `src/lib/context.sh` (dispatch ~229-255)

- [ ] **Step 1: Teach `context_helper.py` the lmstudio backend**

In `cmd_summarize()` add an lmstudio branch between the `elif backend == "claude":` block and the final `else: _die(2, f"unknown backend: {backend}")`. It assigns to `out` (the same variable the local/claude branches use), reusing the existing `_SUMMARY_SYSTEM` constant and the `body` text — so the shared `<think>`-strip + write-frontmatter tail (lines ~200-227) works unchanged:

```python
    elif backend == "lmstudio":
        from llm.server_helper import chat
        try:
            out = chat(args.endpoint, model, _SUMMARY_SYSTEM, body,
                       max_tokens=600, temp=0.3)
        except Exception as e:  # noqa: BLE001 - surface any client/transport error
            _die(3, f"lmstudio request failed: {e}")
```

In `main()` update the argparse for the summarize subparser (line ~277):

```python
    p_sum.add_argument("--backend", choices=["local", "claude", "lmstudio"], required=True)
    p_sum.add_argument("--endpoint", default="http://127.0.0.1:1234",
                       help="LM Studio base URL (backend=lmstudio)")
```

- [ ] **Step 2: Dispatch lmstudio from `context.sh`**

In the context-doc summary `case "$backend"` (line ~229) add an `lmstudio)` arm before `*)`:

```zsh
        lmstudio)
            if ! _lmstudio_available; then
                print -P "  ${C[yellow]}⚠${C[reset]} LM Studio not reachable — skipping summary"
                return 0
            fi
            model_label=$(lmstudio_model_resolve 2>/dev/null)
            ;;
```

Then extend the `context_helper.py` invocation (line ~250) to pass the endpoint:

```zsh
    if "$MK_PY_VENV/bin/python" "$MK_ROOT/src/llm/context_helper.py" \
            summarize "$target" \
            --output "$summary_target" \
            --backend "$backend" \
            --model "$model_label" \
            --model-path "$model_path" \
            --endpoint "$(lmstudio_endpoint)"; then
```

(`--endpoint` is harmless for local/claude — they ignore it.)

- [ ] **Step 3: Verify context-doc summary under lmstudio**

```bash
printf '# Q3 Strategy\n\nWe will raise prices 10%% and launch the pro tier in September. Owner: Stijn.\n' > /tmp/mk-ctx.md
zsh -c 'MK_HOME=$HOME/.meetink; MK_ROOT="$PWD"; MK_PY_VENV=$HOME/.meetink/py-venv; MEETINK_TITLE_BACKEND=lmstudio; source src/lib/ui.sh; source src/lib/models.sh; source src/lib/titling.sh; source src/lib/lmstudio.sh; PYTHONPATH="$PWD/src" "$MK_PY_VENV/bin/python" src/llm/context_helper.py summarize /tmp/mk-ctx.md --output /tmp/mk-ctx.summary.md --backend lmstudio --model "$(lmstudio_model_resolve)" --model-path "" --endpoint "$(lmstudio_endpoint)"; echo ----; cat /tmp/mk-ctx.summary.md'
```
Expected: a `.summary.md` with the four sections, generated via LM Studio.

- [ ] **Step 4: Commit**

```bash
git add src/llm/context_helper.py src/lib/context.sh
git commit -m "feat(llm): context-doc summaries via lmstudio backend"
```

---

## Task 6: Wire `ask.sh`

**Files:**
- Modify: `src/lib/ask.sh` (precheck ~64-68, dispatch ~137-147, new `_ask_lmstudio`)

- [ ] **Step 1: Make the `claude` precheck backend-conditional**

Replace the unconditional claude-CLI check (lines ~64-68) so it only fires when the active backend is claude. Resolve the backend first:

```zsh
    # Resolve the active backend up front so we only enforce backend-specific
    # prerequisites (claude CLI is NOT needed for local/lmstudio).
    local backend="claude"
    if typeset -f title_backend_active >/dev/null; then
        backend=$(title_backend_active)
    fi
    if [[ "$backend" == "claude" ]] && ! command -v claude >/dev/null 2>&1; then
        print -P "${C[red]}error:${C[reset]} ${C[bold]}claude${C[reset]} CLI not found"
        print -P "  Install Claude Code from ${C[dim]}https://claude.com/code${C[reset]}"
        return 1
    fi
```

Then delete the now-duplicate backend re-resolution block at lines ~137-140 (the `local backend="claude"; if typeset -f …` block), keeping the dispatch below.

- [ ] **Step 2: Add the lmstudio dispatch + handler**

Change the dispatch (line ~142) to a three-way:

```zsh
    if [[ "$backend" == "local" ]]; then
        _ask_local "$prompt"
    elif [[ "$backend" == "lmstudio" ]]; then
        _ask_lmstudio "$prompt"
    else
        _ask_claude "$prompt"
    fi
```

Add `_ask_lmstudio` after `_ask_local` (end of file):

```zsh
_ask_lmstudio() {
    local user_prompt="$1"
    if ! _lmstudio_available; then
        print -P "${C[red]}error:${C[reset]} LM Studio not reachable at ${C[bold]}$(lmstudio_endpoint)${C[reset]}"
        print -P "  Start LM Studio's local server, or switch backend with ${C[bright_cyan]}/llm backend claude${C[reset]}"
        return 1
    fi
    local model=$(lmstudio_model_resolve 2>/dev/null)
    local system_prompt="You answer questions about a meeting transcript. Be concise and grounded only in the transcript and provided context. If the transcript doesn't contain enough information, say so plainly rather than guessing."
    print -P "${C[dim]}Asking ${model}...${C[reset]}"
    print -P ""
    _generate_lmstudio "$system_prompt" "$user_prompt" 512 0.4
    print -P ""
}
```

- [ ] **Step 3: Verify `/ask` under lmstudio (no claude CLI required)**

```bash
zsh -c 'MK_HOME=$HOME/.meetink; MK_ROOT="$PWD"; MK_PY_VENV=$HOME/.meetink/py-venv; MEETINK_TITLE_BACKEND=lmstudio; MK_TRANSCRIPT=/tmp/mk-sample.txt; MK_TRANSCRIPTS_DIR=/tmp; source src/lib/ui.sh; source src/lib/models.sh; source src/lib/titling.sh; source src/lib/lmstudio.sh; source src/lib/identity.sh; source src/lib/projects.sh; source src/lib/ask.sh; cmd_ask what did we decide about pricing?'
```
Expected: a grounded answer referencing the q3 pricing/launch decision, printed from LM Studio; no "claude CLI not found" error.

- [ ] **Step 4: Commit**

```bash
git add src/lib/ask.sh
git commit -m "feat(llm): /ask via lmstudio backend; gate claude precheck by backend"
```

---

## Task 7: REPL awareness (`repl.py`)

**Files:**
- Modify: `src/repl/repl.py` (`_title_backend` ~177-192, `_active_backend_budget` ~616-621, new `_lmstudio_budget`, `_titling_label` ~272-297, autocomplete ~971)

- [ ] **Step 1: Accept `lmstudio` in `_title_backend`**

In `_title_backend()` (lines ~180 and ~188) replace both `in ("local", "claude")` membership tests with `in ("local", "claude", "lmstudio")`:

```python
    env = os.environ.get("MEETINK_TITLE_BACKEND")
    if env in ("local", "claude", "lmstudio"):
        return env
    cfg = MK_HOME / "config"
    if cfg.exists():
        try:
            for line in cfg.read_text().splitlines():
                if line.startswith("title_backend="):
                    val = line.split("=", 1)[1].strip()
                    if val in ("local", "claude", "lmstudio"):
                        return val
        except OSError:
            pass
    return "local"
```

- [ ] **Step 2: Add the lmstudio budget + branch**

Add `_lmstudio_budget()` near `_claude_budget()` (after line ~613):

```python
def _lmstudio_budget() -> int:
    """Context window for the active LM Studio model, persisted as
    lmstudio_ctx= by `/llm use` (set from the model's loaded/max context).
    Falls back to a conservative default. Tokens, not characters."""
    cfg = MK_HOME / "config"
    if cfg.exists():
        try:
            for line in cfg.read_text().splitlines():
                if line.startswith("lmstudio_ctx="):
                    val = line.split("=", 1)[1].strip()
                    if val.isdigit():
                        return int(val)
        except OSError:
            pass
    return 8_000
```

In `_active_backend_budget()` (line ~616) add the branch:

```python
def _active_backend_budget() -> int:
    backend = _title_backend()
    if backend == "claude":
        return _claude_budget()
    if backend == "lmstudio":
        return _lmstudio_budget()
    return _ask_budget_for(_active_local_llm_key())
```

> Note: the footer `reserved` calc at line ~639 (`2000 if claude else 600`) is
> fine as-is for lmstudio (600 reserve), no change needed.

- [ ] **Step 3: Add the lmstudio label**

In `_titling_label()` (line ~272), after the `if _title_backend() == "claude":` block, add:

```python
    if _title_backend() == "lmstudio":
        cfg = MK_HOME / "config"
        if cfg.exists():
            try:
                for line in cfg.read_text().splitlines():
                    if line.startswith("lmstudio_model="):
                        val = line.split("=", 1)[1].strip()
                        if val:
                            return val
            except OSError:
                pass
        return "LM Studio"
```

- [ ] **Step 4: Add backend autocomplete entry**

In the `/llm` completer dict (line ~971) add `lmstudio`:

```python
        "backend": {"local": None, "lmstudio": None, "claude": None},
```

- [ ] **Step 5: Verify REPL routing + budget (offline checks)**

```bash
zsh -c 'MEETINK_TITLE_BACKEND=lmstudio "$HOME/.meetink/py-venv/bin/python" - <<PY
import os, sys
sys.path.insert(0, os.path.join(os.getcwd(), "src"))
from repl import repl
assert repl._title_backend() == "lmstudio", repl._title_backend()
print("backend:", repl._title_backend())
print("budget:", repl._active_backend_budget())
print("label:", repl._titling_label())
assert repl._try_handle_ask_local("x") is False  # must fall through to subprocess
print("ask falls through: ok")
PY'
```
Expected: `backend: lmstudio`, a numeric budget (the configured `lmstudio_ctx`, e.g. 40960 after pinning the 1.7b), the model id as label, and `ask falls through: ok`. (If `repl` imports heavy deps and errors on import, run the same checks by importing the functions directly; the assertions are what matter.)

- [ ] **Step 6: Commit**

```bash
git add src/repl/repl.py
git commit -m "feat(repl): lmstudio backend routing, budget chip, and label"
```

---

## Task 8: Welcome-screen awareness (`welcome.sh`)

**Files:**
- Modify: `src/lib/welcome.sh` (`_titling_backend` ~27, `_titling_label` ~37, `_has_titling` ~91)

- [ ] **Step 1: Accept `lmstudio` in `_titling_backend`**

In `_titling_backend()` (line ~27) change:

```zsh
        if [[ "$v" == "claude" || "$v" == "local" ]]; then
```
to:
```zsh
        if [[ "$v" == "claude" || "$v" == "local" || "$v" == "lmstudio" ]]; then
```

- [ ] **Step 2: Add an lmstudio label branch**

In `_titling_label()` (line ~37), before the existing `if [[ … == "claude" ]]`, add a guard:

```zsh
    if [[ "$(_titling_backend)" == "lmstudio" ]]; then
        local m="${MEETINK_LMSTUDIO_MODEL:-}"
        if [[ -z "$m" && -f "$MK_HOME/config" ]]; then
            m=$(grep '^lmstudio_model=' "$MK_HOME/config" 2>/dev/null | head -1 | cut -d= -f2-)
        fi
        [[ -z "$m" ]] && m="LM Studio"
        print -n -- "$m"
        return
    fi
```

- [ ] **Step 3: Add an lmstudio availability branch**

In `_has_titling()` (line ~91), add an lmstudio branch (cheap — no network ping on the landing page; "available" = a model is configured):

```zsh
_has_titling() {
    if [[ "$(_titling_backend)" == "claude" ]]; then
        command -v claude >/dev/null 2>&1
    elif [[ "$(_titling_backend)" == "lmstudio" ]]; then
        [[ -n "${MEETINK_LMSTUDIO_MODEL:-}" ]] || \
            { [[ -f "$MK_HOME/config" ]] && grep -q '^lmstudio_model=' "$MK_HOME/config" 2>/dev/null; }
    else
        [[ -n "$(/bin/ls -d "$MK_PY_VENV"/lib/python*/site-packages/mlx_lm 2>/dev/null | head -1)" ]] \
            && [[ -f "$(_active_local_llm_path)/config.json" ]]
    fi
}
```

- [ ] **Step 4: Verify the welcome screen renders the lmstudio label**

```bash
zsh -c 'MEETINK_TITLE_BACKEND=lmstudio MK_ROOT="$PWD" MK_PY_VENV=$HOME/.meetink/py-venv bin/meetink' | sed -n '1,40p'
```
Expected: the Status block shows the LM Studio model id (e.g. `qwen3-1.7b-mlx titling`) with a green dot (since a model is pinned), not "AI titling (optional)".

- [ ] **Step 5: Commit**

```bash
git add src/lib/welcome.sh
git commit -m "feat(welcome): show lmstudio backend in status block"
```

---

## Task 9: Documentation

**Files:**
- Modify: `README.md` (the `/llm` backend section, ~lines 324-348)
- Modify: `CHANGELOG.md` (create if absent)

- [ ] **Step 1: Document the backend in README**

In the `### Local LLM (titling / summary / /ask)` table, add rows after the existing `/llm backend …` entries:

```markdown
| `/llm backend lmstudio` | Use models served by **LM Studio** (its local server, default `http://127.0.0.1:1234`). Auto-discovers whatever LM Studio has downloaded — including small/fast models for titling and large ones for `/ask`. No model re-download into meetink. |
| `/llm list` *(lmstudio)* | When `backend=lmstudio`, lists the models LM Studio serves with quantization, context length, and loaded/not-loaded state. |
| `/llm use <id>` *(lmstudio)* | Pin which LM Studio model meetink uses (e.g. `qwen3-1.7b-mlx`). Defaults to LM Studio's currently-loaded model. |
```

Add an env-override note near the existing override docs:

```markdown
- `MEETINK_LMSTUDIO_URL` — LM Studio base URL (default `http://127.0.0.1:1234`).
- `MEETINK_LMSTUDIO_MODEL` — pin the LM Studio model id without persisting it.
```

And one line in the requirements/notes area: the `lmstudio` backend needs LM Studio's local server running (Developer tab → Start Server / `lms server start`).

- [ ] **Step 2: Add a CHANGELOG entry**

Create or prepend to `CHANGELOG.md`:

```markdown
## [unreleased] - 2026-05-23
### Features
- New `lmstudio` LLM backend: titling, summaries, and `/ask` can use models
  served by LM Studio's local server (OpenAI-compatible). Auto-discovers
  downloaded models (id, quant, context length, loaded state) via
  `/api/v0/models`; generation via `/v1/chat/completions`. `/llm backend
  lmstudio`, `/llm list`, `/llm use <id>`.
### Design Rationale
- Additive third backend — `local` (MLX) and `claude` are unchanged. Transport
  is plain OpenAI `/v1`, so `MEETINK_LMSTUDIO_URL` can target any compatible
  server; LM Studio's native `/api/v0` is used only for richer discovery.
- stdlib-only HTTP client (`server_helper.py`) — no new Python dependencies.
- `enable_thinking:false` + `<think>` stripping keep Qwen3 reasoning models
  from polluting titles/summaries.
### Notes & Caveats
- Requires LM Studio's local server running. Falls back gracefully (no-op
  titling/summaries, clear `/ask` message) when unreachable.
- Budget chip uses the model's reported context window, persisted on `/llm use`.
```

- [ ] **Step 3: Commit**

```bash
git add README.md CHANGELOG.md
git commit -m "docs(llm): document lmstudio backend + changelog"
```

---

## Final integration verification

Run the full lifecycle against the live server (LM Studio running):

```bash
bin/meetink llm backend lmstudio
bin/meetink llm list                 # table of 5 models, ● on the loaded one
bin/meetink llm use qwen3-1.7b-mlx    # pins fast model, ctx 40960
bin/meetink llm status                # endpoint + reachable + model
# titling + summary (simulate a finished transcript via title_session_file path)
# /ask:
bin/meetink ask "what did we decide about pricing?"   # grounded answer
# graceful degradation:
#   Quit LM Studio's server, then:
bin/meetink llm status                # ○ not reachable
bin/meetink ask "anything?"           # clear "LM Studio not reachable" message
bin/meetink llm backend local         # back to MLX — unchanged behaviour
```

All green ⇒ feature complete. Then proceed to branch finishing (merge/PR) per
`superpowers:finishing-a-development-branch`.
```
