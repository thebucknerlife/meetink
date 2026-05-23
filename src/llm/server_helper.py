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


def _apply_no_think(system: str, prompt: str) -> tuple[str, str]:
    """Append Qwen3's `/no_think` soft-switch so reasoning models answer
    directly instead of spending the token budget on a <think> / separate
    reasoning_content block (which leaves `content` empty for short caps like
    titling). Prefer the system message; fall back to the user prompt when
    there is no system message. Harmless trailing text for non-Qwen models."""
    if system:
        return (system.rstrip() + " /no_think", prompt)
    return (system, prompt.rstrip() + " /no_think")


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
    system, prompt = _apply_no_think(system, prompt)
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
        # Belt-and-suspenders: some servers honour this template kwarg, others
        # ignore it (LM Studio's MLX engine does) — `/no_think` above covers Qwen3.
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
