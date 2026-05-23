#!/usr/bin/env python3
"""Offline tests for server_helper pure functions. No network.
Run: python3 src/llm/test_server_helper.py   (prints OK)  — also pytest-compatible."""
from __future__ import annotations
import os, sys
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from llm.server_helper import (
    parse_models, extract_message, strip_think, _api_base, _apply_no_think,
)


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


def test_apply_no_think():
    s, p = _apply_no_think("be brief", "hello")
    assert s == "be brief /no_think" and p == "hello"
    s, p = _apply_no_think("", "hello")
    assert s == "" and p == "hello /no_think"


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
