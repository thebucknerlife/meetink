#!/usr/bin/env python3
"""Streaming client for the resident mlx_lm server (/ask local backend).

The old path loaded the multi-GB model into Metal on EVERY question —
the user's "does the LLM have to warm up?" was exactly right. Now the
model loads once into a long-lived `mlx_lm.server` and questions stream
from it: first-token latency instead of load+eval+full-generation.

Prints answer text to stdout chunk by chunk (flushed — the app's chat
panel renders it live). Qwen's <think>…</think> reasoning block is
routed to stdout too, wrapped in the same tags on their own lines, so
callers that want the trace can show it and the shell path can strip
it. Exits nonzero if the server can't be reached (caller falls back to
the one-shot loader).
"""
from __future__ import annotations

import argparse
import json
import sys
import urllib.request


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--system", default="")
    ap.add_argument("--prompt", default="")
    # Multi-turn mode: base prompt (context+transcript, ending with
    # "Question from the user: ") from a file, chat history as JSON
    # [{"q":..,"a":..}], and the new question. Reconstructing the FIRST
    # user message byte-identically to the previous request is what
    # lets the server's LRU prompt cache extend instead of re-evaluating
    # the whole ~12K-token context per question.
    ap.add_argument("--base-file", default="")
    ap.add_argument("--hist-file", default="")
    ap.add_argument("--question", default="")
    ap.add_argument("--max-tokens", type=int, default=512)
    ap.add_argument("--temp", type=float, default=0.4)
    args = ap.parse_args()

    messages: list[dict] = []
    if args.system:
        messages.append({"role": "system", "content": args.system})
    if args.base_file:
        with open(args.base_file, encoding="utf-8") as f:
            base = f.read()
        hist = []
        if args.hist_file:
            try:
                with open(args.hist_file, encoding="utf-8") as f:
                    hist = json.load(f) or []
            except (OSError, ValueError):
                hist = []
        first_q = hist[0]["q"] if hist else args.question
        messages.append({"role": "user", "content": base + first_q})
        if hist:
            messages.append({"role": "assistant", "content": hist[0]["a"]})
            for turn in hist[1:]:
                messages.append({"role": "user", "content": turn["q"]})
                messages.append({"role": "assistant", "content": turn["a"]})
            messages.append({"role": "user", "content": args.question})
    else:
        messages.append({"role": "user", "content": args.prompt})

    body = json.dumps({
        "messages": messages,
        "stream": True,
        "max_tokens": args.max_tokens,
        "temperature": args.temp,
        # Qwen3.5 defaults to reasoning mode and burns the whole budget
        # inside it; the server honors enable_thinking via template
        # kwargs (verified against mlx-lm 0.31).
        "chat_template_kwargs": {"enable_thinking": False},
    }).encode()
    req = urllib.request.Request(
        f"http://127.0.0.1:{args.port}/v1/chat/completions",
        data=body,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        resp = urllib.request.urlopen(req, timeout=600)
    except Exception as e:
        print(f"mlx server unreachable: {e}", file=sys.stderr)
        return 1

    in_think = False
    for raw in resp:
        line = raw.decode("utf-8", "replace").strip()
        if not line.startswith("data:"):
            continue
        payload = line[5:].strip()
        if payload == "[DONE]":
            break
        try:
            delta = (json.loads(payload)["choices"][0]
                     .get("delta") or {})
        except (ValueError, KeyError, IndexError):
            continue
        # Reasoning arrives as its own delta field on this server —
        # wrap it in explicit think markers so callers can show or
        # strip the trace.
        reasoning = delta.get("reasoning") or ""
        if reasoning:
            if not in_think:
                sys.stdout.write("<think>\n")
                in_think = True
            sys.stdout.write(reasoning)
            sys.stdout.flush()
        text = delta.get("content") or ""
        if not text:
            continue
        if in_think:
            sys.stdout.write("\n</think>\n")
            in_think = False
        # Pass <think> spans through explicitly delimited so the caller
        # can render them as a trace or strip them.
        while text:
            if in_think:
                end = text.find("</think>")
                if end < 0:
                    sys.stdout.write(text)
                    text = ""
                else:
                    sys.stdout.write(text[:end] + "\n</think>\n")
                    text = text[end + len("</think>"):]
                    in_think = False
            else:
                start = text.find("<think>")
                if start < 0:
                    sys.stdout.write(text)
                    text = ""
                else:
                    sys.stdout.write(text[:start] + "<think>\n")
                    text = text[start + len("<think>"):]
                    in_think = True
        sys.stdout.flush()
    print()
    return 0


if __name__ == "__main__":
    sys.exit(main())
