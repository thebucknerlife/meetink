from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import numpy as np


ROOT = Path(__file__).resolve().parents[1]
REFINE = ROOT / "src" / "refine"
sys.path.insert(0, str(REFINE))

from audio_health import assess_mic_health  # noqa: E402
from enhance import echo_path_evidence  # noqa: E402
from playback_mix import (  # noqa: E402
    analyze_windows,
    authoritative_route_decisions,
    authoritative_route_mode,
    duck_envelope_for_chunk,
    gate_duck_spans_on_mic,
)


RATE = 16000


class AudioPolicyTests(unittest.TestCase):
    def setUp(self) -> None:
        self.rng = np.random.default_rng(20260817)

    def source(self, seconds: int = 30, level: float = 0.2) -> np.ndarray:
        white = self.rng.normal(0, 1, seconds * RATE).astype(np.float32)
        # Speech-like colored energy, deterministic and broadband enough for
        # the GCC-PHAT path estimator.
        return (np.convolve(white, np.ones(25) / 25, mode="same")
                .astype(np.float32) * level)

    @staticmethod
    def delayed(source: np.ndarray, delay_ms: int, gain: float) -> np.ndarray:
        delay = delay_ms * RATE // 1000
        out = np.zeros_like(source)
        out[delay:] = source[:-delay] * gain
        return out

    def test_local_speakers_detect_sys_to_mic(self) -> None:
        sys_audio = self.source()
        mic = self.source(level=0.03) + self.delayed(sys_audio, 120, 0.55)

        local = echo_path_evidence(sys_audio, mic, max_delay_s=0.6)
        returned = echo_path_evidence(mic, sys_audio,
                                      min_delay_s=0.04, max_delay_s=1.5)
        self.assertTrue(local.detected)
        self.assertAlmostEqual(local.delay_ms, 120, delta=2)
        self.assertFalse(returned.detected)
        self.assertTrue(all(d["render"] == "mic-only"
                            for d in analyze_windows(mic, sys_audio)))

    def test_far_end_return_is_not_local_speaker_bleed(self) -> None:
        mic = self.source()
        sys_audio = self.source(level=0.06) + self.delayed(mic, 240, 0.7)

        decisions = analyze_windows(mic, sys_audio)
        self.assertTrue(all(d["returned_mic_to_sys"]["detected"]
                            for d in decisions))
        self.assertTrue(all(not d["local_sys_to_mic"]["detected"]
                            for d in decisions))
        self.assertTrue(all(d["render"] == "sum" for d in decisions))

    def test_quiet_local_speaker_path_uses_cleanmix_fallback(self) -> None:
        sys_audio = self.source()
        mic = self.source(level=0.01) + self.delayed(sys_audio, 110, 0.08)
        decisions = analyze_windows(mic, sys_audio)
        self.assertTrue(all(d["local_sys_to_mic"]["detected"]
                            for d in decisions))
        self.assertTrue(all(d["weak_local_path"] for d in decisions))
        self.assertTrue(all(d["basis"] == "weak-local-path"
                            for d in decisions))

    def test_double_talk_does_not_create_an_echo_path(self) -> None:
        mic = self.source(level=0.12)
        sys_audio = self.source(level=0.12)
        decisions = analyze_windows(mic, sys_audio)
        self.assertTrue(all(d["basis"] == "no-local-path" for d in decisions))
        self.assertTrue(all(d["render"] == "sum" for d in decisions))

    def test_route_is_a_prior_not_ground_truth(self) -> None:
        mic = self.source()
        sys_audio = self.source(level=0.06) + self.delayed(mic, 180, 0.65)
        # A stale/ambiguous physical label says speakers, but the only causal
        # waveform path is the opposite direction.
        decisions = analyze_windows(mic, sys_audio, [(0.0, "speakers")])
        self.assertTrue(all(d["basis"] == "returned-path" for d in decisions))
        self.assertTrue(all(d["render"] == "sum" for d in decisions))

    def test_unambiguous_headphones_override_noisy_acoustics(self) -> None:
        fixture = json.loads((ROOT / "tests" / "fixtures" /
                              "headset_returned_echo_field.json").read_text())
        route = [(float(event["t"]), str(event["kind"]))
                 for event in fixture["route_events"]]
        self.assertEqual(fixture["regressed_acoustic_result"], {
            "speaker_windows": 103, "device_switches": 48})
        self.assertEqual(authoritative_route_mode(route), "split")

        # The route resolver, not the noisy 103-window acoustic vote, owns the
        # recipe. One mode covers all 268 field windows: zero switches and no
        # mic-only windows capable of erasing remote participants.
        expected = fixture["expected_result"]
        modes = [authoritative_route_mode(route) == "mic"] * fixture["windows"]
        self.assertEqual(sum(modes), expected["speaker_windows"])
        self.assertEqual(sum(a != b for a, b in zip(modes, modes[1:])),
                         expected["device_switches"])

    def test_route_authority_still_yields_to_dead_mic_window(self) -> None:
        sys_audio = self.source(seconds=30)
        mic = self.source(seconds=30, level=0.08)
        mic[15 * RATE:] = 0
        decisions = authoritative_route_decisions(mic, sys_audio, "mic")
        self.assertEqual([d["render"] for d in decisions],
                         ["mic-only", "sys-passthrough"])

    def test_both_echo_directions_are_reported_separately(self) -> None:
        direct_mic = self.source(level=0.18)
        remote = self.source(level=0.12)
        sys_audio = remote + self.delayed(direct_mic, 220, 0.6)
        mic = direct_mic + self.delayed(sys_audio, 90, 0.5)
        decisions = analyze_windows(mic, sys_audio)
        self.assertTrue(all(d["local_sys_to_mic"]["detected"]
                            for d in decisions))
        self.assertTrue(all(d["returned_mic_to_sys"]["detected"]
                            for d in decisions))

    def test_route_change_during_silence_changes_the_recipe(self) -> None:
        sys_audio = np.zeros(45 * RATE, dtype=np.float32)
        mic = np.zeros_like(sys_audio)
        first_sys = self.source(seconds=15)
        sys_audio[:15 * RATE] = first_sys
        mic[:15 * RATE] = (self.source(seconds=15, level=0.03)
                           + self.delayed(first_sys, 100, 0.5))
        tail = self.source(seconds=15, level=0.12)
        sys_audio[30 * RATE:] = tail
        mic[30 * RATE:] = self.source(seconds=15, level=0.08)
        decisions = analyze_windows(
            mic, sys_audio, [(0.0, "speakers"), (20.0, "headphones")])
        self.assertEqual([d["render"] for d in decisions],
                         ["mic-only", "sum", "sum"])
        self.assertEqual(decisions[1]["basis"], "route-during-silence")

    def test_health_flags_truncation_and_literal_zeroes(self) -> None:
        sys_audio = self.source()
        short_mic = self.source(seconds=3)
        truncated = assess_mic_health(short_mic, sys_audio, RATE)
        self.assertFalse(truncated["healthy"])
        self.assertEqual(truncated["reason"], "truncated")

        zeros = np.zeros_like(sys_audio)
        silent = assess_mic_health(zeros, sys_audio, RATE)
        self.assertFalse(silent["healthy"])
        self.assertEqual(silent["reason"], "digital-silence")

    def test_span_duck_requires_live_mic_and_has_expected_depth(self) -> None:
        spans = [(1.0, 2.0)]
        alive = np.full(3 * RATE, 0.02, dtype=np.float32)
        dead = np.zeros_like(alive)
        self.assertEqual(gate_duck_spans_on_mic(spans, alive), spans)
        self.assertEqual(gate_duck_spans_on_mic(spans, dead), [])

        envelope = duck_envelope_for_chunk(spans, 0, 3 * RATE, RATE)
        self.assertIsNotNone(envelope)
        self.assertAlmostEqual(float(envelope[int(1.5 * RATE)]), 0.05,
                               places=5)
        self.assertAlmostEqual(float(envelope[int(0.5 * RATE)]), 1.0,
                               places=5)

        # A long candidate span cannot remain authorized after the mic dies.
        partial = np.zeros(10 * RATE, dtype=np.float32)
        partial[:2 * RATE] = 0.02
        authorized = gate_duck_spans_on_mic([(0.0, 10.0)], partial)
        self.assertTrue(authorized)
        self.assertLessEqual(authorized[-1][1], 3.1)

    def test_dead_mic_render_preserves_sys_bit_for_bit(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            tmp = Path(td)
            mic16 = tmp / "mic16.raw"
            mic = tmp / "mic.raw"
            sys16 = tmp / "sys16.raw"
            sys_play = tmp / "sys.raw"
            out = tmp / "out.raw"
            manifest = tmp / "audio.json"
            mic16.write_bytes(b"")
            mic.write_bytes(b"")
            samples = (np.clip(self.source(seconds=6), -0.9, 0.9) * 32767)
            samples = samples.astype(np.int16)
            sys16.write_bytes(samples.tobytes())
            sys_play.write_bytes(samples.tobytes())

            proc = subprocess.run([
                sys.executable, str(REFINE / "playback_mix.py"),
                "--mic16", str(mic16), "--sys16", str(sys16),
                "--mic", str(mic), "--sys", str(sys_play),
                "--rate", str(RATE), "--out", str(out),
                "--decision-out", str(manifest),
            ], capture_output=True, text=True)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertEqual(out.read_bytes(), sys_play.read_bytes())
            decision = json.loads(manifest.read_text())
            self.assertEqual(decision["render"],
                             "sys-passthrough-mic-degraded")
            self.assertEqual(decision["processors"], [])

    def test_midcall_zero_mic_window_preserves_that_sys_window(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            tmp = Path(td)
            mic_path = tmp / "mic.raw"
            sys_path = tmp / "sys.raw"
            out = tmp / "out.raw"
            manifest = tmp / "audio.json"
            sys_samples = (np.clip(self.source(seconds=30), -0.9, 0.9)
                           * 32767).astype(np.int16)
            mic_samples = (np.clip(self.source(seconds=30), -0.9, 0.9)
                           * 32767).astype(np.int16)
            mic_samples[15 * RATE:] = 0
            mic_path.write_bytes(mic_samples.tobytes())
            sys_path.write_bytes(sys_samples.tobytes())

            proc = subprocess.run([
                sys.executable, str(REFINE / "playback_mix.py"),
                "--mic16", str(mic_path), "--sys16", str(sys_path),
                "--mic", str(mic_path), "--sys", str(sys_path),
                "--rate", str(RATE), "--out", str(out),
                "--decision-out", str(manifest),
            ], capture_output=True, text=True)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            rendered = np.frombuffer(out.read_bytes(), dtype=np.int16)
            np.testing.assert_array_equal(rendered[15 * RATE:],
                                          sys_samples[15 * RATE:])
            decision = json.loads(manifest.read_text())
            self.assertEqual(decision["windows"][1]["render"],
                             "sys-passthrough")

    def test_subwindow_mic_death_renders_sys_at_block_level(self) -> None:
        """The Gov BD field hole: mic dies 8 s INTO a mic-only window and
        the window-granularity passthrough can't see it — those seconds
        rendered as silence. Dead 100 ms blocks must render sys."""
        with tempfile.TemporaryDirectory() as td:
            tmp = Path(td)
            seconds = 30
            sys_audio = np.clip(self.source(seconds=seconds, level=0.10),
                                -0.9, 0.9)
            mic = np.clip(self.source(seconds=seconds, level=0.10),
                          -0.9, 0.9)
            mic[22 * RATE:] = 0.0          # dies 7 s into the 15-30 window
            (tmp / "mic.raw").write_bytes(
                (mic * 32767).astype(np.int16).tobytes())
            (tmp / "sys.raw").write_bytes(
                (sys_audio * 32767).astype(np.int16).tobytes())
            (tmp / "route.jsonl").write_text(
                '{"t": 0, "kind": "speakers"}\n')   # mic-only authority
            out = tmp / "mixed.raw"
            proc = subprocess.run([
                sys.executable, str(REFINE / "playback_mix.py"),
                "--mic16", str(tmp / "mic.raw"),
                "--sys16", str(tmp / "sys.raw"),
                "--mic", str(tmp / "mic.raw"), "--sys", str(tmp / "sys.raw"),
                "--rate", str(RATE), "--route", str(tmp / "route.jsonl"),
                "--out", str(out),
            ], capture_output=True, text=True)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            mixed = np.frombuffer(out.read_bytes(),
                                  dtype=np.int16).astype(np.float32) / 32768.0
            alive_rms = float(np.sqrt(np.mean(mixed[10 * RATE:20 * RATE] ** 2)))
            dead_rms = float(np.sqrt(np.mean(mixed[24 * RATE:29 * RATE] ** 2)))
            # The dead-mic span must carry sys audio, not silence —
            # comparable in level to the alive mic-only span.
            self.assertGreater(dead_rms, alive_rms * 0.3,
                               f"dead-mic span near-silent: {dead_rms:.4f} "
                               f"vs alive {alive_rms:.4f}")

    def test_cli_headphone_route_and_mic_alive_duck_are_wired(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            tmp = Path(td)
            mic_path = tmp / "mic.raw"
            sys_path = tmp / "sys.raw"
            route_path = tmp / "route.jsonl"
            timing_path = tmp / "timing.json"
            plain_out = tmp / "plain.raw"
            ducked_out = tmp / "ducked.raw"
            manifest = tmp / "audio.json"
            # Contaminated-by-construction: the user talks 0-15 s and a
            # returned copy of them fills sys there (hot under the user);
            # others talk 15-30 s at a lower level. Detector: ratio >> 0.8.
            mic_f = np.zeros(30 * RATE, dtype=np.float32)
            mic_f[:15 * RATE] = self.source(seconds=15, level=0.10)
            sys_f = np.zeros(30 * RATE, dtype=np.float32)
            sys_f[:15 * RATE] = mic_f[:15 * RATE] * 0.8   # returned self
            sys_f[15 * RATE:] = self.source(seconds=15, level=0.05)
            mic = (np.clip(mic_f, -0.9, 0.9) * 32767).astype(np.int16)
            sys_audio = (np.clip(sys_f, -0.9, 0.9) * 32767).astype(np.int16)
            mic_path.write_bytes(mic.tobytes())
            sys_path.write_bytes(sys_audio.tobytes())
            route_path.write_text('{"t": 0, "kind": "headphones"}\n')
            timing_path.write_text(json.dumps({"lines": [{
                "label": "ME",
                "words": [{"w": "hello", "s": 1.0, "e": 2.0}],
            }]}))
            plain_manifest = tmp / "plain-audio.json"
            base = [
                sys.executable, str(REFINE / "playback_mix.py"),
                "--mic16", str(mic_path), "--sys16", str(sys_path),
                "--mic", str(mic_path), "--sys", str(sys_path),
                "--rate", str(RATE), "--route", str(route_path),
            ]
            plain = subprocess.run(base + [
                "--decision-out", str(plain_manifest), "--out", str(plain_out),
            ], capture_output=True, text=True)
            ducked = subprocess.run(base + [
                "--duck-timing", str(timing_path), "--duck-label", "ME",
                "--decision-out", str(manifest), "--out", str(ducked_out),
            ], capture_output=True, text=True)
            self.assertEqual(plain.returncode, 0, plain.stderr)
            self.assertEqual(ducked.returncode, 0, ducked.stderr)

            # The mic is continuously vocal, so ENERGY candidates cover
            # the whole clip even with no transcript at all — untranscribed
            # vocalizations (laughs, acks) must duck the returned copy too
            # (AE x Tom residual-echo field case). The word span adds no
            # coverage energy didn't already nominate: identical renders.
            before = np.frombuffer(plain_out.read_bytes(), dtype=np.int16)
            after = np.frombuffer(ducked_out.read_bytes(), dtype=np.int16)
            np.testing.assert_array_equal(before, after)

            pm = json.loads(plain_manifest.read_text())
            self.assertEqual(
                pm["mic_alive_span_duck"]["word_candidate_spans"], 0)
            self.assertGreater(
                pm["mic_alive_span_duck"]["energy_candidate_spans"], 0)
            self.assertGreater(
                pm["mic_alive_span_duck"]["authorized_seconds"], 1.0)

            decision = json.loads(manifest.read_text())
            self.assertEqual(decision["render"], "route-authoritative-split")
            # The user's half renders sum; the mic-silent half is
            # per-window sys-passthrough — both legal here.
            self.assertTrue(all(w["render"] in ("sum", "sys-passthrough")
                                for w in decision["windows"]))
            self.assertTrue(
                decision["returned_self_contamination"]["contaminated"])
            self.assertEqual(
                decision["mic_alive_span_duck"]["word_candidate_spans"], 1)
            self.assertEqual(decision["mic_alive_span_duck"]["factor"], 0.0)
            self.assertIn("returned-self-selection-v1",
                          decision["processors"])


if __name__ == "__main__":
    unittest.main()
