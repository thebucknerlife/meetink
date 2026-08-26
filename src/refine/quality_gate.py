#!/usr/bin/env python3
"""Post-refine transcript quality gate — FLAG, never block.

The watch principle is recall over precision: audio is sacred, labels
are fixable. So this gate never rejects or retries anything; it prints
one warning per line (empty output = clean, exit code always 0) and the
caller surfaces them (refine log, notification, activity). Born from
the Sol review: a 1:1 shipped with 'Speaker 2' owning 98% of the words
and nobody noticed until the user read the transcript.

Usage: quality_gate.py <transcript.txt>
"""
from __future__ import annotations

import difflib
import re
import sys
from pathlib import Path

LINE_RE = re.compile(r"^\[(\d{2}:\d{2}:\d{2})\] ([^:]+): (.*)$")


def attendee_first_names(header_lines: list[str]) -> tuple[list[str], str | None]:
    user = None
    names: list[str] = []
    for line in header_lines:
        if line.startswith("# user:"):
            user = line.split(":", 1)[1].strip().upper() or None
        elif line.startswith("# attendees:"):
            for ent in line.split(":", 1)[1].split(","):
                ent = ent.strip()
                if not ent:
                    continue
                name = ent.split("<", 1)[0].strip()
                if not name and "<" in ent:
                    name = ent.split("<", 1)[1].split(">", 1)[0].strip()
                if "@" in name:
                    name = re.split(r"[@.]", name)[0]
                parts = name.split()
                if parts:
                    names.append(parts[0].upper())
    return names, user


def main() -> int:
    if len(sys.argv) != 2:
        return 0
    try:
        text = Path(sys.argv[1]).read_text(errors="replace")
    except OSError:
        return 0
    all_lines = text.splitlines()
    header = [l for l in all_lines if not LINE_RE.match(l)]
    rows = [LINE_RE.match(l) for l in all_lines]
    rows = [(m.group(2).strip(), m.group(3)) for m in rows if m]
    if not rows:
        return 0

    words: dict[str, int] = {}
    for sp, tx in rows:
        words[sp] = words.get(sp, 0) + len(tx.split())
    total = sum(words.values())

    names, user = attendee_first_names(header)
    me = user or ""
    others = []
    for n in names:
        if n and n != me and n not in others:
            others.append(n)
    is_1on1 = len(others) == 1
    # A degenerate parse ("r@rossingram.com" -> "R") still identifies a
    # 1:1; show the raw header entry in messages instead of the initial.
    remote_desc = others[0] if others and len(others[0]) >= 2 else None
    if is_1on1 and remote_desc is None:
        for line in header:
            if line.startswith("# attendees:"):
                ents = [e.strip() for e in line.split(":", 1)[1].split(",")]
                ents = [e for e in ents if e and me.lower() not in e.lower()]
                if ents:
                    remote_desc = ents[0]
                break
    if is_1on1 and remote_desc is None:
        remote_desc = "the attendee"

    warnings: list[str] = []

    # 1. Collapse: one voice owning a two-person conversation.
    if is_1on1 and total >= 500:
        top, top_w = max(words.items(), key=lambda kv: kv[1])
        if top_w >= 0.9 * total:
            warnings.append(
                f"diarization may have collapsed — {top} owns "
                f"{100 * top_w // total}% of a 1:1; Reprocess re-anchors it")

    # 2. A substantial unnamed voice in a 1:1 whose remote attendee is known.
    if is_1on1 and total >= 500:
        for sp, w in words.items():
            if sp.startswith("Speaker ") and w >= 0.2 * total:
                warnings.append(
                    f"remote speaker unnamed — {sp} owns "
                    f"{100 * w // total}% (calendar says {remote_desc}); "
                    f"Relabel Speakers can fix it")
                break

    # 3. Unreadable containers.
    giant = sum(1 for _, tx in rows if len(tx.split()) > 120)
    if giant:
        warnings.append(f"{giant} line(s) over 120 words")

    # 4. Near-duplicate passages (same speaker, close together).
    def norm(t: str) -> str:
        return re.sub(r"[^a-z0-9 ]", "", t.lower()).strip()

    dups = 0
    normed = [(sp, norm(tx)) for sp, tx in rows]
    for i in range(len(normed)):
        si, xi = normed[i]
        if len(xi) < 60:
            continue
        for j in range(i + 1, min(i + 6, len(normed))):
            sj, xj = normed[j]
            if si != sj or len(xj) < 60:
                continue
            if xi in xj or xj in xi or \
                    difflib.SequenceMatcher(None, xi, xj).ratio() >= 0.8:
                dups += 1
                break
    if dups > 3:
        warnings.append(f"{dups} near-duplicate passages")

    # 5. Stacked refine headers (reprocess hygiene).
    if sum(1 for l in header if l.startswith("# refined:")) > 1:
        warnings.append("stacked '# refined:' headers")

    for w in warnings:
        print(f"quality: {w}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
