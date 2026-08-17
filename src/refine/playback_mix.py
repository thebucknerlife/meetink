#!/usr/bin/env python3
"""Unified playback renderer: per-window mode detection + crossfade.

The two field-validated recipes, now selected PER WINDOW instead of per
meeting (the user takes headphones on and off mid-call):

  speakers window   → mic-only (one copy of every voice; echo
                      structurally impossible — the A/B-winning mix)
  headphones window → level-matched plain sum of both raw streams,
                      with the twice-guarded residual echo gate

Mode evidence: the mic tracks sys at a substantial fraction when
speakers play (measured 0.57-1.03) and barely at all with headphones
(0.004). Windows without enough sys activity inherit their neighbor
(hysteresis: two consecutive windows must disagree to switch). A
uniform meeting renders identically to the old single-mode paths.

Both renders share one set of static per-stream gains so crossfades
(0.4 s equal-power) never step in loudness. Soft tanh headroom instead
of a hard clip. No transcript, no labels, no models — numpy only.
"""
from __future__ import annotations

import argparse
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from enhance import gcc_phat_delay, residual_echo_gate

# Exit code signalling "weak-speakers": an acoustic sys→mic path exists
# but the bleed is too quiet for mic-only (remote side would be faint
# and roomy) AND too audible for a plain sum (it layers under clean sys
# as reverb — field case: 0/61 windows detected, sum ran, remote voices
# sounded like echo-y rooms). The caller renders sys + neurally-cleaned
# mic instead; weak bleed is exactly where the neural residual is
# negligible relative to sys.
EXIT_WEAK_SPEAKERS = 3

RATE = 16000
WIN_S = 15           # mode-detection window
RATIO_THRESHOLD = 0.15


def log(msg: str) -> None:
    print(f"playback-mix: {msg}", file=sys.stderr, flush=True)


def load_route(path: str | None) -> list[tuple[float, str]]:
    """Parse capture's route.jsonl: [(t_seconds, kind)] sorted by t.

    Only "headphones"/"speakers" carry information; "unknown" events
    (virtual devices — Krisp Speaker, BlackHole, aggregates — hide the
    physical endpoint) are kept so a switch TO a virtual device ends
    the previous prior rather than extending it.
    """
    if not path:
        return []
    events: list[tuple[float, str]] = []
    try:
        import json
        with open(path) as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    o = json.loads(line)
                    events.append((float(o["t"]), str(o["kind"])))
                except (ValueError, KeyError):
                    continue
    except OSError:
        return []
    events.sort()
    return events


def route_kind_at(events: list[tuple[float, str]], t: float) -> str | None:
    """OS-reported output kind at time t, or None (no journal/unknown)."""
    kind = None
    for et, ek in events:
        if et > t:
            break
        kind = ek
    return kind if kind in ("headphones", "speakers") else None


def detect_modes(mic16: np.ndarray, sys16: np.ndarray,
                 route: list[tuple[float, str]] | None = None) -> list[bool]:
    """Per-window: True = speakers (mic-only), False = headphones (sum)."""
    B = RATE // 10
    n = min(len(mic16), len(sys16))
    nb = n // B
    m = np.sqrt((mic16[: nb * B].reshape(nb, B) ** 2).mean(axis=1))
    s = np.sqrt((sys16[: nb * B].reshape(nb, B) ** 2).mean(axis=1))
    act = s[s > 0.001]
    floor = max(0.01, float(np.percentile(act, 75)) * 0.5) if len(act) > 50 else 0.05

    per_win: list[bool | None] = []
    wb = WIN_S * 10  # blocks per window
    for w0 in range(0, nb, wb):
        sl = slice(w0, min(nb, w0 + wb))
        loud = s[sl] > floor
        if loud.sum() < 10:
            per_win.append(None)   # not enough evidence — inherit
            continue
        ratio = float(np.median(m[sl][loud] / s[sl][loud]))
        per_win.append(ratio > RATIO_THRESHOLD)

    # Route journal as prior: acoustic evidence always wins where it
    # exists, but a window WITHOUT evidence (silence, nobody talking)
    # takes the OS-reported output device over blind neighbor-inherit —
    # this is what catches headphones coming on/off during a lull.
    if route:
        agree = disagree = filled = 0
        for i, v in enumerate(per_win):
            kind = route_kind_at(route, (i + 0.5) * WIN_S)
            if kind is None:
                continue
            route_says = kind == "speakers"
            if v is None:
                per_win[i] = route_says
                filled += 1
            elif v == route_says:
                agree += 1
            else:
                disagree += 1
        if agree or disagree or filled:
            log(f"route prior: {agree} agree, {disagree} disagree, "
                f"{filled} silent window(s) filled")

    # Fill evidence-less windows from the nearest decided neighbor
    # (forward first, then backward for a silent head).
    last: bool | None = None
    for i, v in enumerate(per_win):
        if v is None:
            per_win[i] = last
        else:
            last = v
    last = None
    for i in range(len(per_win) - 1, -1, -1):
        if per_win[i] is None:
            per_win[i] = last if last is not None else False
        else:
            last = per_win[i]

    # Hysteresis: a single dissenting window between agreeing neighbors
    # is measurement noise, not a device change.
    modes = [bool(v) for v in per_win]
    for i in range(1, len(modes) - 1):
        if modes[i] != modes[i - 1] and modes[i] != modes[i + 1]:
            modes[i] = modes[i - 1]
    return modes


def load_duck_spans(timing_path: str, label: str,
                    pad_lead: float = 0.15, pad_tail: float = 0.7,
                    gap: float = 1.0) -> list[tuple[float, float]]:
    """The USER's speech spans from timing.json — sys-duck windows for
    the sum render. A far-end return of the user's own voice in sys
    (a participant echoing the meeting back) summed onto the direct mic
    is manufactured echo: neither stream echoes alone, the sum doubles
    them (AE x Tom incident). Ducking sys under the user's words kills
    that copy; genuine crosstalk survives, just quieter under their
    voice. Merged word spans; the TAIL pad is generous because the
    returned copy lags the direct voice by a 100-400 ms round trip —
    each echoed phrase-ending outlives the words that caused it (field
    listen: v1's symmetric 0.12 s pad let every tail through).
    """
    import json
    try:
        with open(timing_path) as f:
            lines = json.load(f)["lines"]
    except (OSError, ValueError, KeyError):
        return []
    words: list[tuple[float, float]] = []
    want = label.upper()
    for ln in lines:
        if str(ln.get("label", "")).upper() != want:
            continue
        for w in ln.get("words") or []:
            s = float(w.get("s", 0.0))
            e = max(float(w.get("e", s)), s + 0.05)
            words.append((s, e))
    words.sort()
    spans: list[list[float]] = []
    for s, e in words:
        if spans and s - spans[-1][1] <= gap:
            spans[-1][1] = max(spans[-1][1], e)
        else:
            spans.append([s, e])
    return [(max(0.0, s - pad_lead), e + pad_tail) for s, e in spans]


def gate_duck_spans_on_mic(spans: list[tuple[float, float]],
                           mic16: np.ndarray,
                           floor: float = 0.008) -> list[tuple[float, float]]:
    """Keep only spans where the MIC actually carried the user.

    The dual failure mode (the AE x Adam Russell meeting): when the mic
    dies, the sys stream holds the ONLY copy of the user — machinery
    that treats sys-user audio as a disposable duplicate then erases
    them from the record. Ducking is only correct where the direct mic
    copy exists; a span whose mic audio is near-silent keeps sys at
    full level. Per-span, so a mid-call mic death flips behavior right
    at the boundary.
    """
    kept: list[tuple[float, float]] = []
    for s, e in spans:
        a, b = int(s * RATE), int(min(e, s + 8.0) * RATE)
        seg = mic16[a:b]
        if len(seg) < RATE // 4:
            continue
        rms = float(np.sqrt(np.mean(seg ** 2)))
        if rms >= floor:
            kept.append((s, e))
    return kept


def stream_gain(x: np.ndarray, target: float = 0.07) -> float:
    B = RATE // 10
    nb = len(x) // B
    if nb < 20:
        return 1.0
    r = np.sqrt((x[: nb * B].reshape(nb, B) ** 2).mean(axis=1))
    act = r[r > 0.01]
    if len(act) < 10:
        return 1.0
    return float(np.clip(target / max(float(np.percentile(act, 75)), 1e-4),
                         0.25, 4.0))


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--mic16", required=True)
    ap.add_argument("--sys16", required=True)
    ap.add_argument("--mic", required=True, help="playback-rate mic stream")
    ap.add_argument("--sys", dest="sys_", required=True)
    ap.add_argument("--rate", type=int, default=48000)
    ap.add_argument("--force-mode", choices=["mic", "split"],
                    help="override detection (mix_mode config)")
    ap.add_argument("--route", help="capture's route.jsonl (OS output-"
                    "device journal) — prior for the mode decision")
    ap.add_argument("--duck-timing", help="timing.json — the user's word "
                    "spans duck sys in sum renders (far-end echo guard)")
    ap.add_argument("--duck-label", default="ME",
                    help="the user's transcript label (e.g. GREG)")
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    def load16(path: str) -> np.ndarray:
        try:
            return np.fromfile(path, dtype=np.int16).astype(np.float32) / 32768.0
        except OSError:
            return np.zeros(0, dtype=np.float32)

    mic16 = load16(args.mic16)
    sys16 = load16(args.sys16)
    if not len(mic16):
        log("mic stream empty — falling back")
        return 1
    if not len(sys16):
        # In-person recording: no system audio at all → pure mic-only.
        sys16 = np.zeros(len(mic16), dtype=np.float32)

    log("progress 5 analyzing")
    route = load_route(args.route)
    if route:
        log(f"route journal: {len(route)} event(s), "
            f"initial {route[0][1]} ({args.route})")

    # An UNAMBIGUOUS route journal is ground truth about the physical
    # setup: one kind, zero switches, no virtual-device gaps ("unknown"
    # breaks unambiguity and falls through to acoustics). Per-window
    # acoustic detection exists for the ambiguous cases — letting it
    # override hard fact is how a far-end return of the user's voice
    # (indistinguishable from speaker bleed by correlation) hallucinated
    # 48 device switches on an all-AirPods meeting (AE x Tom).
    route_forced: str | None = None
    if not args.force_mode and route:
        kinds = {k for _, k in route}
        if kinds == {"headphones"}:
            route_forced = "split"
        elif kinds == {"speakers"}:
            route_forced = "mic"

    if args.force_mode:
        modes = [args.force_mode == "mic"]
        log(f"mode forced: {'speakers/mic-only' if modes[0] else 'headphones/sum'}")
    elif route_forced:
        modes = [route_forced == "mic"]
        log(f"route journal unambiguous ({route[0][1]}, {len(route)} "
            f"event(s), 0 switches) — "
            f"{'speakers/mic-only' if modes[0] else 'headphones/sum'} "
            f"throughout, acoustic detection skipped")
    else:
        modes = detect_modes(mic16, sys16, route)
        switches = sum(1 for i in range(1, len(modes)) if modes[i] != modes[i - 1])
        log(f"modes: {sum(modes)}/{len(modes)} windows speakers, "
            f"{switches} device switch(es)")
        # Weak-speakers check: the energy-ratio detector reads quiet
        # speakers as "headphones", but a real acoustic path means the
        # sum would layer bleed reverb under clean sys. Coherence (a
        # gcc delay peak) is the path evidence the ratio test misses.
        if not any(modes) and float(np.abs(sys16).mean()) > 1e-4:
            delay = gcc_phat_delay(sys16, mic16, max_delay_s=0.6)
            if delay >= 0:
                B = RATE // 10
                nb = min(len(mic16), len(sys16)) // B
                m = np.sqrt((mic16[:nb*B].reshape(nb, B)**2).mean(axis=1))
                s_ = np.sqrt((sys16[:nb*B].reshape(nb, B)**2).mean(axis=1))
                loud = s_ > max(0.02, float(np.percentile(s_[s_ > 0.001], 75)) * 0.5) \
                    if (s_ > 0.001).sum() > 50 else s_ > 0.05
                if loud.sum() > 20:
                    ratio = float(np.median(m[loud] / s_[loud]))
                    if ratio > 0.02:
                        # Route tiebreak for the ambiguous band: if the
                        # OS says headphones throughout, the weak path
                        # is earcup leak (AirPods spill), which the sum
                        # handles fine — cleanmix would be needless
                        # neural surgery. Speakers/unknown/virtual
                        # (Krisp) → the acoustic default stands.
                        n_hp = sum(
                            1 for i in range(len(modes))
                            if route_kind_at(route, (i + 0.5) * WIN_S)
                            == "headphones")
                        if route and n_hp == len(modes):
                            log(f"weak path (ratio {ratio:.3f}) but "
                                f"route says headphones throughout — "
                                f"earcup leak, keeping the sum")
                        else:
                            log(f"weak-speakers: acoustic path at "
                                f"{delay/16.0:.0f} ms, bleed ratio "
                                f"{ratio:.3f} — deferring to neural "
                                f"clean-mix")
                            return EXIT_WEAK_SPEAKERS

    log("progress 15 echo-gate")
    # Echo gate for the SUM segments only (twice-guarded, as shipped).
    gains = None
    if not all(modes):
        delay = gcc_phat_delay(mic16, sys16, max_delay_s=0.6)
        if delay >= 0:
            _, gains = residual_echo_gate(mic16, sys16, delay)
            if gains is not None:
                ducked = float((gains < 0.9).mean())
                if ducked > 0.20:
                    log(f"gate misfire (would duck {ducked*100:.0f}%) — no gate")
                    gains = None
                else:
                    log(f"echo gate armed (delay {delay/16.0:.0f} ms)")

    # Far-end echo guard: wherever the SUM renders, sys drops -14 dB
    # under the user's own words (see load_duck_spans). No-op on normal
    # meetings (sys is near-silent there anyway) and on mic-only renders.
    duck_spans: list[tuple[float, float]] = []
    if args.duck_timing and not all(modes):
        raw_spans = load_duck_spans(args.duck_timing, args.duck_label)
        duck_spans = gate_duck_spans_on_mic(raw_spans, mic16)
        if duck_spans:
            total = sum(e - s for s, e in duck_spans)
            log(f"sys duck armed: {len(duck_spans)}/{len(raw_spans)} "
                f"span(s) of {args.duck_label} speech ({total:.0f}s; "
                f"{len(raw_spans) - len(duck_spans)} skipped, mic silent)")
        elif raw_spans:
            log(f"sys duck stood down: mic silent across all "
                f"{len(raw_spans)} span(s) — sys is the only copy of "
                f"{args.duck_label} (dead-mic meeting)")

    log("progress 25 rendering")
    mic_gain = stream_gain(mic16)
    sys_gain = stream_gain(sys16)
    log(f"level match: mic x{mic_gain:.2f}, sys x{sys_gain:.2f}")

    # Sample-level speakers-mode weight from the window modes, with
    # 0.4 s equal-power crossfades at every transition.
    def fsize(path: str) -> int:
        try:
            return os.path.getsize(path)
        except OSError:
            return 0

    n = max(fsize(args.mic) // 2, fsize(args.sys_) // 2)
    win_hi = WIN_S * args.rate
    fade_hi = int(0.4 * args.rate)

    def alpha_for_chunk(pos: int, take: int) -> np.ndarray:
        idx = np.minimum((np.arange(take) + pos) // win_hi, len(modes) - 1)
        a = np.array([1.0 if modes[i] else 0.0 for i in range(len(modes))],
                     dtype=np.float32)[idx]
        # Smooth transitions: linear ramp over fade_hi around each
        # window boundary where the mode flips.
        for w in range(1, len(modes)):
            if modes[w] == modes[w - 1]:
                continue
            b_pos = w * win_hi          # global sample of the flip
            lo, hi = b_pos - fade_hi // 2, b_pos + fade_hi // 2
            s0, s1 = max(lo, pos), min(hi, pos + take)
            if s0 < s1:
                t = (np.arange(s0, s1) - lo) / max(1, hi - lo)
                ramp = (1 - np.cos(np.pi * t)) / 2
                seg = ramp if modes[w] else 1 - ramp
                a[s0 - pos:s1 - pos] = seg.astype(np.float32)
        return a

    # -26 dB: the far-end copy runs as HOT as the direct mic (measured
    # 0.146 vs 0.147 on AE x Tom) and the level-match can run sys hotter
    # than mic — v1's -14 dB left the echo only ~11 dB under the direct
    # voice, plainly audible. -26 dB puts it ~23 dB down: masked.
    DUCK = 0.05
    duck_ramp = int(0.08 * args.rate)

    def duck_for_chunk(pos: int, take: int) -> "np.ndarray | None":
        """Sys gain envelope for [pos, pos+take): DUCK inside the user's
        spans with raised-cosine edges, 1.0 elsewhere. Absolute-sample
        math so ramps crossing chunk boundaries stay continuous."""
        if not duck_spans:
            return None
        t0 = pos / args.rate
        t1 = (pos + take) / args.rate
        d = np.ones(take, dtype=np.float32)
        touched = False
        for s0, e0 in duck_spans:
            if e0 < t0 - 0.2:
                continue
            if s0 > t1 + 0.2:
                break
            a = int(s0 * args.rate)
            b = int(e0 * args.rate)
            ca, cb = max(a - pos, 0), min(b - pos, take)
            if ca < cb:
                d[ca:cb] = DUCK
                touched = True
            # entry ramp [a-ramp, a): 1 -> DUCK
            ra, rb = max(a - duck_ramp - pos, 0), min(a - pos, take)
            if ra < rb:
                t = (np.arange(ra, rb) + pos - (a - duck_ramp)) / duck_ramp
                d[ra:rb] = np.minimum(
                    d[ra:rb],
                    (1.0 - (1 - np.cos(np.pi * t)) / 2 * (1 - DUCK))
                    .astype(np.float32))
                touched = True
            # exit ramp [b, b+ramp): DUCK -> 1
            ra, rb = max(b - pos, 0), min(b + duck_ramp - pos, take)
            if ra < rb:
                t = (np.arange(ra, rb) + pos - b) / duck_ramp
                d[ra:rb] = np.minimum(
                    d[ra:rb],
                    (DUCK + (1 - np.cos(np.pi * t)) / 2 * (1 - DUCK))
                    .astype(np.float32))
                touched = True
        return d if touched else None

    B_hi = args.rate // 20
    CHUNK = args.rate * 10
    sys_src = args.sys_ if fsize(args.sys_) else os.devnull
    last_pct = 25
    with open(args.mic, "rb") as fm, open(sys_src, "rb") as fs, \
         open(args.out, "wb") as fo:
        pos = 0
        while pos < n:
            pct = 25 + int(70 * pos / max(1, n))
            if pct >= last_pct + 5:
                log(f"progress {pct} rendering")
                last_pct = pct
            take = min(CHUNK, n - pos)
            mic = np.frombuffer(fm.read(take * 2), dtype=np.int16)
            sy = np.frombuffer(fs.read(take * 2), dtype=np.int16)
            m = np.zeros(take, dtype=np.float32)
            s = np.zeros(take, dtype=np.float32)
            m[: len(mic)] = mic.astype(np.float32) / 32768.0
            s[: len(sy)] = sy.astype(np.float32) / 32768.0
            if gains is not None:
                gidx = np.minimum((np.arange(take) + pos) // B_hi,
                                  len(gains) - 1)
                s = s * gains[gidx]
            duck = duck_for_chunk(pos, take)
            if duck is not None:
                s = s * duck
            alpha = alpha_for_chunk(pos, take)   # 1 = mic-only, 0 = sum
            mic_track = m * mic_gain             # shared by both renders
            sum_track = mic_track + s * sys_gain
            mixed = alpha * mic_track + (1.0 - alpha) * sum_track
            over = np.abs(mixed) > 0.85
            mixed[over] = np.sign(mixed[over]) * (
                0.85 + 0.13 * np.tanh((np.abs(mixed[over]) - 0.85) / 0.13))
            fo.write((mixed * 32767.0).astype(np.int16).tobytes())
            pos += take
    log("playback mix complete")
    return 0


if __name__ == "__main__":
    sys.exit(main())
