#!/usr/bin/env python3
"""Unified playback renderer: per-window mode detection + crossfade.

The two field-validated recipes, now selected PER WINDOW instead of per
meeting (the user takes headphones on and off mid-call):

  speakers window   → mic-only (one copy of every voice; echo
                      structurally impossible — the A/B-winning mix)
  headphones window → level-matched plain sum of both raw streams; a
                      returned-self gate is allowed only when waveform
                      evidence establishes a causal mic → sys path

An unambiguous physical route journal is authoritative: a clean headphone mic
cannot safely become mic-only no matter what codec-decorrelated correlation
suggests. Mixed/unknown routes use directional evidence: sys → mic is local
speaker bleed; mic → sys is returned self. Transcript spans provide a second
returned-self candidate map, but only direct mic energy authorizes ducking.

Both renders share one set of static per-stream gains so crossfades
(0.4 s equal-power) never step in loudness. Soft tanh headroom instead
of a hard clip. No learned audio models — numpy only.
"""
from __future__ import annotations

import argparse
import json
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from audio_health import assess_mic_health, mic_health_summary
from enhance import EchoPathEvidence, echo_path_evidence, residual_echo_gate

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


def authoritative_route_mode(
        events: list[tuple[float, str]] | None) -> str | None:
    """Return the render forced by a complete, unambiguous route journal.

    Directional waveform evidence remains useful diagnostics for ambiguous
    routes, but conferencing codecs can decorrelate a returned-self copy until
    direction ratios become noise. A journal containing exactly one physical
    kind is therefore authoritative: it is unsafe to select mic-only on an
    all-headphones meeting because the mic cannot contain remote participants.
    Any unknown event or real route switch restores acoustic window analysis.
    """
    if not events:
        return None
    kinds = {kind for _, kind in events}
    if kinds == {"headphones"}:
        return "split"
    if kinds == {"speakers"}:
        return "mic"
    return None


def authoritative_route_decisions(mic16: np.ndarray, sys16: np.ndarray,
                                  mode: str) -> list[dict]:
    """Expand route authority into windows while preserving mic failures.

    This intentionally performs no echo-direction analysis. The only override
    is the stronger health invariant: a literal-zero mic window with active
    sys must preserve sys bit-for-bit even on an all-speakers route.
    """
    window = WIN_S * RATE
    n = min(len(mic16), len(sys16))
    decisions: list[dict] = []
    for start in range(0, n, window):
        end = min(n, start + window)
        mic = mic16[start:end]
        sys_ = sys16[start:end]
        mic_nonzero = float(np.mean(
            np.abs(mic) >= (1.0 / 32768.0))) if len(mic) else 0.0
        sys_rms = float(np.sqrt(np.mean(sys_ ** 2))) if len(sys_) else 0.0
        passthrough = mic_nonzero < 0.001 and sys_rms > 0.001
        decisions.append({
            "start_s": start / RATE,
            "end_s": end / RATE,
            "route": "speakers" if mode == "mic" else "headphones",
            "sys_active_blocks": None,
            "mic_sys_ratio": None,
            "mic_nonzero_fraction": round(mic_nonzero, 6),
            "local_sys_to_mic": _path_dict(EchoPathEvidence(False)),
            "returned_mic_to_sys": _path_dict(EchoPathEvidence(False)),
            "render": "sys-passthrough" if passthrough else (
                "mic-only" if mode == "mic" else "sum"),
            "basis": ("mic-window-digital-silence" if passthrough
                      else "unambiguous-route-authority"),
            "weak_local_path": False,
        })
    return decisions


def detect_modes(mic16: np.ndarray, sys16: np.ndarray,
                 route: list[tuple[float, str]] | None = None) -> list[bool]:
    """Compatibility wrapper: True = speakers, False = headphones/sum."""
    return [d["render"] == "mic-only"
            for d in analyze_windows(mic16, sys16, route)]


def _path_dict(ev: EchoPathEvidence) -> dict:
    return ev.to_dict()


def analyze_windows(mic16: np.ndarray, sys16: np.ndarray,
                    route: list[tuple[float, str]] | None = None) -> list[dict]:
    """Classify windows using two explicitly directional echo detectors."""
    B = RATE // 10
    n = min(len(mic16), len(sys16))
    nb = n // B
    if nb == 0:
        return []
    m = np.sqrt((mic16[: nb * B].reshape(nb, B) ** 2).mean(axis=1))
    s = np.sqrt((sys16[: nb * B].reshape(nb, B) ** 2).mean(axis=1))
    act = s[s > 0.001]
    floor = max(0.01, float(np.percentile(act, 75)) * 0.5) if len(act) > 50 else 0.05

    decisions: list[dict] = []
    wb = WIN_S * 10  # blocks per window
    for w0 in range(0, nb, wb):
        w1 = min(nb, w0 + wb)
        sl = slice(w0, w1)
        loud = s[sl] > floor
        start_s = w0 / 10.0
        route_kind = route_kind_at(route or [], start_s + WIN_S / 2)
        decision = {
            "start_s": start_s,
            "end_s": w1 / 10.0,
            "route": route_kind or "unknown",
            "sys_active_blocks": int(loud.sum()),
            "mic_sys_ratio": None,
            "mic_nonzero_fraction": 0.0,
            "local_sys_to_mic": _path_dict(EchoPathEvidence(False)),
            "returned_mic_to_sys": _path_dict(EchoPathEvidence(False)),
            "render": None,
            "basis": "insufficient-signal",
            "weak_local_path": False,
        }
        mic_window = mic16[w0 * B:w1 * B]
        mic_nonzero = float(np.mean(
            np.abs(mic_window) >= (1.0 / 32768.0))) if len(mic_window) else 0.0
        decision["mic_nonzero_fraction"] = round(mic_nonzero, 6)
        if loud.sum() >= 10 and mic_nonzero < 0.001:
            decision["render"] = "sys-passthrough"
            decision["basis"] = "mic-window-digital-silence"
            decisions.append(decision)
            continue
        if loud.sum() < 10:
            if route_kind:
                decision["render"] = (
                    "mic-only" if route_kind == "speakers" else "sum")
                decision["basis"] = "route-during-silence"
            decisions.append(decision)
            continue
        ratio = float(np.median(m[sl][loud] / s[sl][loud]))
        a, b = w0 * B, w1 * B
        local = echo_path_evidence(sys16[a:b], mic16[a:b],
                                   min_delay_s=0.004, max_delay_s=0.6)
        returned = echo_path_evidence(mic16[a:b], sys16[a:b],
                                      min_delay_s=0.04, max_delay_s=1.5)
        decision["mic_sys_ratio"] = round(ratio, 4)
        decision["local_sys_to_mic"] = _path_dict(local)
        decision["returned_mic_to_sys"] = _path_dict(returned)

        # A route is useful context, but a strong path in the opposite
        # direction can contradict a stale or misleading USB/AirPlay label.
        if local.detected and ratio > RATIO_THRESHOLD:
            decision["render"] = "mic-only"
            decision["basis"] = "local-path"
        elif returned.detected and not local.detected:
            decision["render"] = "sum"
            decision["basis"] = "returned-path"
        elif route_kind == "speakers":
            decision["render"] = "mic-only"
            decision["basis"] = "speaker-route-prior"
        elif route_kind == "headphones":
            decision["render"] = "sum"
            decision["basis"] = "headphone-route-prior"
        elif local.detected and ratio > 0.02:
            # A real but quiet local path needs the neural-clean fallback;
            # plain sum adds room reverb while mic-only makes remotes faint.
            decision["render"] = "sum"
            decision["basis"] = "weak-local-path"
            decision["weak_local_path"] = True
        else:
            # Directionless energy overlap is ordinary double-talk until a
            # causal path proves otherwise.
            decision["render"] = "sum"
            decision["basis"] = "no-local-path"
        decisions.append(decision)

    # Fill evidence-less windows from the nearest decided neighbor
    # (forward first, then backward for a silent head).
    last: str | None = None
    for d in decisions:
        if d["render"] is None:
            d["render"] = last
            if last is not None:
                d["basis"] = "inherited-previous"
        else:
            last = d["render"]
    last = None
    for d in reversed(decisions):
        if d["render"] is None:
            d["render"] = last if last is not None else "sum"
            d["basis"] = "inherited-next" if last is not None else "safe-sum-default"
        else:
            last = d["render"]

    # Hysteresis: a single dissenting window between agreeing neighbors
    # is measurement noise, not a device change.
    for i in range(1, len(decisions) - 1):
        if decisions[i]["basis"] == "mic-window-digital-silence":
            continue
        if decisions[i]["render"] != decisions[i - 1]["render"] \
                and decisions[i]["render"] != decisions[i + 1]["render"]:
            decisions[i]["render"] = decisions[i - 1]["render"]
            decisions[i]["basis"] += "+hysteresis"
    return decisions


def load_duck_spans(timing_path: str, label: str,
                    pad_lead: float = 0.15, pad_tail: float = 0.7,
                    gap: float = 1.0) -> list[tuple[float, float]]:
    """Load user word spans that nominate returned-self echo candidates.

    Transcript timing chooses *where to inspect*, never whether sys is safe to
    attenuate. ``gate_duck_spans_on_mic`` separately requires a live direct-mic
    copy for every span, so a dead/truncated mic leaves the only surviving sys
    copy untouched. The long tail covers conferencing round-trip delay.
    """
    try:
        with open(timing_path) as f:
            lines = json.load(f)["lines"]
    except (OSError, ValueError, KeyError):
        return []
    words: list[tuple[float, float]] = []
    want = label.upper()
    for line in lines:
        if str(line.get("label", "")).upper() != want:
            continue
        for word in line.get("words") or []:
            start = float(word.get("s", 0.0))
            end = max(float(word.get("e", start)), start + 0.05)
            words.append((start, end))
    words.sort()
    spans: list[list[float]] = []
    for start, end in words:
        if spans and start - spans[-1][1] <= gap:
            spans[-1][1] = max(spans[-1][1], end)
        else:
            spans.append([start, end])
    return [(max(0.0, start - pad_lead), end + pad_tail)
            for start, end in spans]


def mic_energy_duck_spans(mic16: np.ndarray,
                          pad_lead: float = 0.1, pad_tail: float = 0.7,
                          gap: float = 0.5) -> list[tuple[float, float]]:
    """Candidate spans from the MIC ITSELF — covers what ASR never wrote.

    Transcript-word candidates miss every untranscribed vocalization:
    laughs, acks, false starts, overlap the recognizer attributed
    elsewhere. Field measurement (AE x Tom): 203 s — 21% — of the user's
    clearly-vocal mic time had no word span, and its returned copy came
    through unducked as 'uneven' residual echo. With any mic activity,
    the user is vocalizing and the returned-self window applies; the
    threshold adapts to the meeting's own mic speech level, and the same
    mic-alive authorization gate still applies downstream (a dead mic
    produces no energy, so this source is self-gating by construction).
    """
    block = RATE // 10
    nblocks = len(mic16) // block
    if nblocks == 0:
        return []
    rms = np.sqrt((mic16[:nblocks * block].reshape(nblocks, block) ** 2)
                  .mean(axis=1))
    act = rms[rms > 0.003]
    if len(act) < 20:
        return []
    thr = max(0.01, float(np.percentile(act, 75)) * 0.15)
    on = rms > thr
    spans: list[list[float]] = []
    for i in range(nblocks):
        if not on[i]:
            continue
        t0, t1 = i / 10.0, (i + 1) / 10.0
        if spans and t0 - spans[-1][1] <= gap:
            spans[-1][1] = t1
        else:
            spans.append([t0, t1])
    return [(max(0.0, s - pad_lead), e + pad_tail) for s, e in spans]


def merge_spans(spans: list[tuple[float, float]]) -> list[tuple[float, float]]:
    """Sort + coalesce overlapping spans from multiple candidate sources."""
    out: list[list[float]] = []
    for s, e in sorted(spans):
        if out and s <= out[-1][1]:
            out[-1][1] = max(out[-1][1], e)
        else:
            out.append([s, e])
    return [(s, e) for s, e in out]


def gate_duck_spans_on_mic(spans: list[tuple[float, float]],
                           mic16: np.ndarray,
                           floor: float = 0.008) -> list[tuple[float, float]]:
    """Intersect candidate spans with time-local direct-mic evidence.

    A whole-span RMS (and especially checking only its first few seconds) can
    authorize ducking long after a mid-call mic death. Work in 100 ms blocks
    instead. Each ducked block must have live mic within 1 s before or 200 ms
    after it; that admits the conferencing echo tail and 150 ms lead pad while
    stopping within about a second of the physical mic disappearing.
    """
    block = RATE // 10
    nblocks = len(mic16) // block
    if nblocks == 0:
        return []
    rms = np.sqrt((mic16[:nblocks * block].reshape(nblocks, block) ** 2)
                  .mean(axis=1))
    alive = rms >= floor
    authorized = np.zeros(nblocks, dtype=bool)
    for index in range(nblocks):
        authorized[index] = bool(np.any(
            alive[max(0, index - 10):min(nblocks, index + 3)]))

    kept: list[tuple[float, float]] = []
    for start, end in spans:
        first = max(0, int(np.floor(start * 10)))
        last = min(nblocks, int(np.ceil(end * 10)))
        run_start: int | None = None
        for index in range(first, last + 1):
            on = index < last and authorized[index]
            if on and run_start is None:
                run_start = index
            elif not on and run_start is not None:
                kept.append((max(start, run_start / 10.0),
                             min(end, index / 10.0)))
                run_start = None
    return kept


def duck_envelope_for_chunk(spans: list[tuple[float, float]], pos: int,
                            take: int, rate: int,
                            factor: float = 0.05,
                            ramp_seconds: float = 0.08) -> np.ndarray | None:
    """Raised-cosine sys envelope for one playback chunk."""
    if not spans:
        return None
    t0 = pos / rate
    t1 = (pos + take) / rate
    envelope = np.ones(take, dtype=np.float32)
    ramp = max(1, int(ramp_seconds * rate))
    touched = False
    for start, end in spans:
        if end < t0 - ramp_seconds:
            continue
        if start > t1 + ramp_seconds:
            break
        a = int(start * rate)
        b = int(end * rate)
        ca, cb = max(a - pos, 0), min(b - pos, take)
        if ca < cb:
            envelope[ca:cb] = factor
            touched = True
        # Entry ramp [a-ramp, a): 1 -> factor.
        ra, rb = max(a - ramp - pos, 0), min(a - pos, take)
        if ra < rb:
            t = (np.arange(ra, rb) + pos - (a - ramp)) / ramp
            shaped = 1.0 - (1 - np.cos(np.pi * t)) / 2 * (1 - factor)
            envelope[ra:rb] = np.minimum(
                envelope[ra:rb], shaped.astype(np.float32))
            touched = True
        # Exit ramp [b, b+ramp): factor -> 1.
        ra, rb = max(b - pos, 0), min(b + ramp - pos, take)
        if ra < rb:
            t = (np.arange(ra, rb) + pos - b) / ramp
            shaped = factor + (1 - np.cos(np.pi * t)) / 2 * (1 - factor)
            envelope[ra:rb] = np.minimum(
                envelope[ra:rb], shaped.astype(np.float32))
            touched = True
    return envelope if touched else None


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


def load_jsonl(path: str | None) -> list[dict]:
    if not path:
        return []
    out: list[dict] = []
    try:
        with open(path) as f:
            for line in f:
                try:
                    value = json.loads(line)
                    if isinstance(value, dict):
                        out.append(value)
                except ValueError:
                    continue
    except OSError:
        pass
    return out


def write_manifest(path: str | None, manifest: dict) -> None:
    if not path:
        return
    try:
        with open(path, "w") as f:
            json.dump(manifest, f, indent=2, sort_keys=True)
            f.write("\n")
    except OSError as exc:
        log(f"could not write decision manifest {path}: {exc}")


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
                    "device journal) — authoritative when unambiguous")
    ap.add_argument("--health", help="capture's health.jsonl event journal")
    ap.add_argument("--mic-processor", default="raw",
                    help="description/version of upstream mic processing")
    ap.add_argument("--duck-timing", help="timing.json whose user-word "
                    "spans nominate returned-self echo candidates")
    ap.add_argument("--duck-label", default="ME",
                    help="the user's transcript label (e.g. GREG)")
    ap.add_argument("--decision-out", help="write the audio decision manifest")
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    def load16(path: str) -> np.ndarray:
        try:
            return np.fromfile(path, dtype=np.int16).astype(np.float32) / 32768.0
        except OSError:
            return np.zeros(0, dtype=np.float32)

    mic16 = load16(args.mic16)
    sys16 = load16(args.sys16)
    sys_was_empty = not len(sys16)
    health = assess_mic_health(mic16, sys16, RATE)
    manifest = {
        "version": 1,
        "renderer": {"name": "playback_mix", "policy_version": 3},
        "analysis_rate": RATE,
        "playback_rate": args.rate,
        "mic_health": health,
        "capture_health_events": load_jsonl(args.health),
        "route_timeline": load_jsonl(args.route),
        "windows": [],
        "returned_echo": _path_dict(EchoPathEvidence(False)),
        "returned_echo_gated_seconds": 0.0,
        "mic_alive_span_duck": {
            "candidate_spans": 0,
            "authorized_spans": 0,
            "authorized_seconds": 0.0,
            "factor": 0.05,
        },
        "processors": [],
    }
    if not len(sys16):
        # In-person recording: no system audio at all → pure mic-only.
        sys16 = np.zeros(len(mic16), dtype=np.float32)

    log("progress 5 analyzing")
    route = load_route(args.route)
    if route:
        log(f"route journal: {len(route)} event(s), "
            f"initial {route[0][1]} ({args.route})")

    degraded_sys_passthrough = bool(len(sys16) and not health["healthy"])
    decisions: list[dict] = []
    route_mode = authoritative_route_mode(route) if not args.force_mode else None
    if degraded_sys_passthrough:
        # The sys stem may contain the only surviving copy of the user. Do
        # not level it, gate it, or combine it with a partial mic timeline.
        modes = [False]
        log(f"WARNING: {mic_health_summary(health)} — preserving sys "
            "bit-for-bit; all echo suppression disabled")
        manifest["render"] = "sys-passthrough-mic-degraded"
        manifest["processors"] = []
    elif sys_was_empty:
        modes = [True]
        manifest["render"] = "mic-only-no-system-audio"
        log("system stream empty — mic-only in-person recording")
    elif args.force_mode:
        modes = [args.force_mode == "mic"]
        log(f"mode forced: {'speakers/mic-only' if modes[0] else 'headphones/sum'}")
        manifest["render"] = f"config-forced-{args.force_mode}"
    elif route_mode:
        decisions = authoritative_route_decisions(mic16, sys16, route_mode)
        modes = [decision["render"] == "mic-only"
                 for decision in decisions] or [route_mode == "mic"]
        kind = route[0][1]
        manifest["render"] = f"route-authoritative-{route_mode}"
        manifest["windows"] = decisions
        manifest["route_authority"] = {
            "kind": kind,
            "events": len(route),
            "acoustic_analysis_skipped": True,
        }
        log(f"route journal unambiguous ({kind}, {len(route)} event(s), "
            f"0 switches) — "
            f"{'speakers/mic-only' if route_mode == 'mic' else 'headphones/sum'} "
            f"throughout (mic-health overrides remain); acoustic mode "
            f"decisions skipped")
    else:
        decisions = analyze_windows(mic16, sys16, route)
        modes = [d["render"] == "mic-only" for d in decisions]
        switches = sum(1 for i in range(1, len(modes)) if modes[i] != modes[i - 1])
        log(f"modes: {sum(modes)}/{len(modes)} windows speakers, "
            f"{switches} device switch(es)")
        manifest["windows"] = decisions
        if decisions and not any(modes) \
                and any(d["weak_local_path"] for d in decisions):
            manifest["render"] = "deferred-neural-weak-local-path"
            write_manifest(args.decision_out, manifest)
            log("weak-speakers: directional local path is too quiet for "
                "mic-only — deferring to neural clean-mix")
            return EXIT_WEAK_SPEAKERS

    if not modes:
        modes = [False]
    has_sum_windows = (any(decision["render"] == "sum"
                           for decision in decisions)
                       if decisions else not all(modes))

    log("progress 15 echo-gate")
    # This waveform gate is legal only after a directional mic→sys path is
    # proven. The separate span fallback below has its own mic authorization.
    gains = None
    returned = EchoPathEvidence(False)
    if not degraded_sys_passthrough and has_sum_windows:
        returned = echo_path_evidence(mic16, sys16,
                                      min_delay_s=0.04, max_delay_s=1.5)
        manifest["returned_echo"] = _path_dict(returned)
        if returned.detected:
            _, gains = residual_echo_gate(
                mic16, sys16, returned.delay_samples)
            if gains is not None:
                ducked = float((gains < 0.9).mean())
                if ducked > 0.20:
                    log(f"gate misfire (would duck {ducked*100:.0f}%) — no gate")
                    gains = None
                else:
                    gated_s = float((gains < 0.9).sum()) * 0.05
                    manifest["returned_echo_gated_seconds"] = round(gated_s, 2)
                    manifest["processors"].append(
                        "waveform-returned-echo-gate-v1")
                    log(f"returned-self gate armed (waveform path at "
                        f"{returned.delay_ms:.0f} ms)")
        else:
            log("no directional mic→sys path — waveform gate stood down")

    # Field fallback for codec-decorrelated returned self. TWO candidate
    # sources nominate returned-self windows — transcript word spans and
    # the mic's own energy (which covers everything ASR never wrote:
    # laughs, acks, overlap) — and direct mic energy authorizes each
    # block. Global degraded health and per-window raw-sys passthrough
    # remain stronger invariants, so the only surviving user copy can
    # never be ducked.
    duck_spans: list[tuple[float, float]] = []
    if not degraded_sys_passthrough and has_sum_windows:
        word_spans = (load_duck_spans(args.duck_timing, args.duck_label)
                      if args.duck_timing else [])
        energy_spans = mic_energy_duck_spans(mic16)
        raw_spans = merge_spans(word_spans + energy_spans)
        duck_spans = gate_duck_spans_on_mic(raw_spans, mic16)
        manifest["mic_alive_span_duck"] = {
            "word_candidate_spans": len(word_spans),
            "energy_candidate_spans": len(energy_spans),
            "merged_candidate_spans": len(raw_spans),
            "authorized_spans": len(duck_spans),
            "authorized_seconds": round(
                sum(end - start for start, end in duck_spans), 2),
            "factor": 0.05,
        }
        if duck_spans:
            total = sum(end - start for start, end in duck_spans)
            manifest["processors"].append("mic-alive-span-duck-v3-energy")
            log(f"mic-alive sys duck armed: {total:.0f}s across "
                f"{len(duck_spans)} span(s) "
                f"(words {len(word_spans)} + energy {len(energy_spans)} "
                f"candidates)")
        elif raw_spans:
            log(f"mic-alive sys duck stood down: mic silent across all "
                f"{len(raw_spans)} candidate span(s)")

    # Block-level dead-mic passthrough inside mic-only regions: a mic
    # dying MID-WINDOW (the AirPods handoff wedge) previously rendered
    # up to a window of silence — the window-granularity passthrough
    # can't see a sub-window death (field case: the 10 s hole at the
    # Gov BD Weekly Sync switch, mic died 8 s into a mic-only window).
    # A digitally-dead mic makes the sum identical to sys, so forcing
    # the render weight to sum on dead 100 ms blocks IS sys-passthrough
    # at block resolution. No-op when the mic is alive throughout.
    mic_alive_env: "np.ndarray | None" = None
    if not degraded_sys_passthrough and len(mic16):
        blk = RATE // 10
        nbl = len(mic16) // blk
        if nbl:
            alive = ((np.abs(mic16[:nbl * blk]).reshape(nbl, blk)
                      >= (1.0 / 32768.0)).mean(axis=1) >= 0.001)
            if not alive.all():
                env = np.convolve(alive.astype(np.float32),
                                  np.ones(3, dtype=np.float32) / 3.0,
                                  mode="same")
                mic_alive_env = env
                dead_s = float((~alive).sum()) / 10.0
                manifest["processors"].append("block-dead-mic-passthrough-v1")
                log(f"dead-mic blocks: {dead_s:.0f}s render as sys "
                    f"regardless of window mode")

    log("progress 25 rendering")
    mic_gain = 0.0 if degraded_sys_passthrough else stream_gain(mic16)
    sys_gain = 1.0 if degraded_sys_passthrough else stream_gain(sys16)
    log(f"level match: mic x{mic_gain:.2f}, sys x{sys_gain:.2f}")
    manifest["stream_gains"] = {"mic": round(mic_gain, 4),
                                "sys": round(sys_gain, 4)}
    if not degraded_sys_passthrough:
        if args.mic_processor != "raw":
            manifest["processors"].append(args.mic_processor)
        manifest["processors"].extend(
            ["static-level-match-v1", "soft-headroom-v1"])

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

    def sys_passthrough_for_chunk(pos: int, take: int) -> np.ndarray | None:
        if not decisions or not any(
                d["render"] == "sys-passthrough" for d in decisions):
            return None
        idx = np.minimum((np.arange(take) + pos) // win_hi,
                         len(decisions) - 1)
        renders = np.array(
            [d["render"] == "sys-passthrough" for d in decisions],
            dtype=bool)
        return renders[idx]

    B_hi = args.rate // 20
    CHUNK = args.rate * 10
    mic_src = args.mic if fsize(args.mic) else os.devnull
    sys_src = args.sys_ if fsize(args.sys_) else os.devnull
    last_pct = 25
    with open(mic_src, "rb") as fm, open(sys_src, "rb") as fs, \
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
            if degraded_sys_passthrough:
                # Do not round-trip through float: this is intentionally a
                # bit-for-bit preservation of the only trustworthy stem.
                fo.write(sy.tobytes())
                pos += len(sy)
                if len(sy) == 0:
                    break
                continue
            m = np.zeros(take, dtype=np.float32)
            s = np.zeros(take, dtype=np.float32)
            raw_sys = np.zeros(take, dtype=np.int16)
            m[: len(mic)] = mic.astype(np.float32) / 32768.0
            s[: len(sy)] = sy.astype(np.float32) / 32768.0
            raw_sys[: len(sy)] = sy
            if gains is not None:
                gidx = np.minimum((np.arange(take) + pos) // B_hi,
                                  len(gains) - 1)
                s = s * gains[gidx]
            duck = duck_envelope_for_chunk(
                duck_spans, pos, take, args.rate)
            if duck is not None:
                s = s * duck
            alpha = alpha_for_chunk(pos, take)   # 1 = mic-only, 0 = sum
            if mic_alive_env is not None:
                # Dead-mic blocks force the sum weighting; with a zero
                # mic the sum IS sys — block-level passthrough.
                bidx = np.minimum((np.arange(take) + pos) * 10 // args.rate,
                                  len(mic_alive_env) - 1)
                alpha = alpha * mic_alive_env[bidx]
            mic_track = m * mic_gain             # shared by both renders
            sum_track = mic_track + s * sys_gain
            mixed = alpha * mic_track + (1.0 - alpha) * sum_track
            over = np.abs(mixed) > 0.85
            mixed[over] = np.sign(mixed[over]) * (
                0.85 + 0.13 * np.tanh((np.abs(mixed[over]) - 0.85) / 0.13))
            rendered = (mixed * 32767.0).astype(np.int16)
            passthrough = sys_passthrough_for_chunk(pos, take)
            if passthrough is not None:
                rendered[passthrough] = raw_sys[passthrough]
            fo.write(rendered.tobytes())
            pos += take
    if "render" not in manifest:
        manifest["render"] = "windowed-mic-only-and-sum"
    write_manifest(args.decision_out, manifest)
    log("playback mix complete")
    return 0


if __name__ == "__main__":
    sys.exit(main())
