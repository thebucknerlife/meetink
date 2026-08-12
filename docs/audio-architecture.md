# Playback Audio Architecture

Final state of the audio pipeline as of `audio-checkpoint-v1`+, and the
condensed lessons of how it got here. The full external review lives in
`Sol audio architecture.pdf` / `Sol response to the journey summary we
made.pdf`; the field history lives in the commit log (v2–v9 mixes).

## The system

Two streams per recording, both archived raw:

- **sys** — system audio via ScreenCaptureKit at 48 kHz: a digitally
  clean copy of what the speakers/headphones played.
- **mic** — the microphone at 48 kHz: the user, plus (on speakers)
  everything the speakers played, as the room heard it.

**Wall-clock spool timelines** (`SpoolWriter`): every write is stamped
with the buffer's own capture timestamp (SCK presentation time,
`AVAudioTime` for the mic — never callback-arrival time), silence fills
gaps > 40 ms, and all spools share one session epoch. The two streams
are therefore mutually aligned by construction. This was the decisive
fix of the whole saga: before it, dropped buffers silently compressed
the timelines and their relative delay random-walked 40 ms–1.4 s,
which broke every reference-based echo tool ever pointed at the files.

**Live transcription** (16 kHz path): WebRTC AEC3 runs in capture with
sys as the far-end reference; speaker bleed never reaches the gate,
whisper, or the spools. This eliminated the doubled-transcript /
"mic thinks it's me" problem and is untouched by playback concerns.

**Playback rendering** (`src/refine/playback_mix.py`, runs at stop and
on reprocess, after refine):

1. Conservative mic denoise (`_denoise_mic`: DeepFilterNet capped at
   −12 dB attenuation; Settings toggle `denoise`, default on). sys is
   never processed — it is what the user heard.
2. Per-15 s-window **mode detection**: does the mic track sys at a
   substantial fraction (median ratio > 0.15 over sys-active blocks,
   volume-adaptive floor)? Measured: 0.57–1.03 on speakers, 0.004 on
   headphones. Windows without evidence inherit neighbors; single-window
   flips are smoothed; 0.4 s equal-power crossfades at real switches.
3. **Speakers windows → mic-only.** One acoustic capture holds one copy
   of every voice, so echo is structurally impossible. This beat every
   engineered mix in blind A/B, including sys + neurally-cleaned mic on
   correctly aligned timelines.
4. **Headphones windows → level-matched plain sum.** No bleed exists,
   so the streams are already the separation; one static gain per
   stream (never an AGC), soft tanh headroom, plus the residual echo
   gate for the user's remote echo — guarded twice (delay < 600 ms,
   duck fraction < 20 %, else pure sum).
5. Fallbacks: DTLN neural mix behind `mix_mode=neural`; the classic
   enhance+duck chain if everything bails.

**Imports** are exempt from all of the above: single stream, separate
path (`_import_enhanced_m4a`), DFN opt-in only.

## The lessons (paid for in nine rejected mixes)

1. **Layering two streams that carry delayed copies of the same voices
   IS echo.** No suppression is perfect; residue under a clean copy is
   audible. Prefer one coherent stream when it contains the whole
   meeting.
2. **Alignment beats models.** Reference-based cancellers (AEC3, FDAF,
   DTLN-aec) assume a near-static delay. DTLN scored 0 dB suppression
   on desynchronized spools and 24 dB on aligned ones — same model,
   same meeting.
3. **Never let transcript labels control audio.** A diarization mistake
   must not be able to mute or garble a voice (the "JAMES" incident).
4. **No dynamic processors in the canonical render.** Sidechain ducks,
   AEC residual suppressors, hard gates, and aggressive denoise caused
   every "robotic / pumping / glass jar" verdict. Static gains and
   passthrough won every A/B.
5. **The raw stems are sacred.** Denoise/mix/gates operate on temp
   copies; `.mic.wav`/`.sys.wav` stay pristine (sole exception: the
   10+ min trailing-silence trim on forgotten recordings), so every
   meeting can be re-rendered as the stack improves.
6. **Judge residual echo relative to the clean copy, not by suppression
   dB.** 24 dB of cancellation still lost the A/B.

## Roadmap (only if regressions or ambition demand)

Single-stream SCK capture (`captureMicrophone`, macOS 15+), coherence-
based mode detection with hysteresis, AEC3 `EchoCanceller3Config`
archival tuning / linear-only output, process-tap vs full-render
reference split, virtual speaker/microphone device (the Krisp
topology, last).
