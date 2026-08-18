# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project shape

Local-first meeting transcription for macOS. Three cooperating pieces, not a single binary:

1. **`bin/meetink`** — zsh launcher. The CLI users actually invoke. Manages PIDs, builds the capture binary, starts/stops `whisper-server`, dispatches subcommands.
2. **`src/capture/Sources/main.swift`** — Swift executable (`meetink-capture`). Captures system audio (ScreenCaptureKit) + mic (AVAudioEngine), chunks both at 16 kHz mono / 3 s, POSTs WAVs to `whisper-server`, writes the transcript.
3. **`whisper-server`** — Homebrew-installed `whisper-cpp` daemon, run on `127.0.0.1:8178` by the launcher with the `small.en` model loaded once. Inference happens here; the Swift binary is a client.

A fourth, optional service runs on `127.0.0.1:8179`: a **diarize-server** (`/identify` endpoint) for speaker identification on the THEM stream. It is *not* installed by `setup` and is *not* mentioned in the README — `main.swift` tolerates its absence (3-strike fail counter, periodic retry). If you're adding diarization features, that's where the contract lives (`diarizeSpeaker` in `main.swift`).

```
zsh launcher ──spawns──▶ whisper-server (:8178)  ◀── HTTP /inference ── Swift capture binary
                            (loads model once)                                │
                                                                              ├─▶ transcript file
                                                  diarize-server (:8179)  ◀───┘   (optional)
```

## Deploy flow (multi-workspace)

Write code in any worktree/workspace, but **deploys always run from the
canonical checkout at `~/src/meetink`** (on `main`). `/opt/homebrew/bin/meetink`
symlinks there, and the running app resolves it at runtime: the watch daemon
and refine pipeline execute *that checkout's* Python/zsh live, while `app build`
installs compiled binaries to `~/.meetink/bin/`. Building from a feature
worktree deploys mismatched halves — don't.

Any agent ships from its own workspace with:

```sh
git push origin HEAD:main                      # publish (rebase on origin/main first if it moved)
git -C ~/src/meetink pull --ff-only            # sync the canonical checkout
~/src/meetink/bin/meetink app build            # kills + relaunches the app — NEVER while a
                                               # recording or its post-processing is live
```

Script-only changes (`src/watch/`, `src/lib/`, `src/refine/`) need no build —
step 2 alone deploys them; the app picks them up on the next daemon respawn.

### Multi-agent rules (read before deploying anything)

This machine is a LIVE meeting recorder for a real user, not a dev sandbox.
Several agents may work in parallel workspaces; these rules keep them from
stepping on each other and on live recordings:

- **Gate every deploy on recorder state.** Before the pull OR the build, check
  `meetink status` says "not recording" AND no post-processing is live
  (`/tmp/meetink-postproc.pid` absent or its PID dead, AND no live-pid run
  dir under `/tmp/meetink-postproc.d/` — concurrent postprocs each own one;
  the legacy pidfile mirrors only one of them). A mid-postproc pull
  swaps pipeline scripts between stages (mixed-version run); a mid-recording
  `app build` kills the app-owned watch daemon over a live call. Gate on the
  CHECK RESULT — never chain `status && deploy` and proceed regardless.
- **`pull --ff-only` failed → stop and ask the user.** It means the canonical
  checkout has uncommitted work (another agent mid-task) or main diverged.
  Never force-pull, stash someone else's WIP, or reset the canonical tree.
- **Never "test" against live data.** `~/.meetink` and `~/Documents/meetink`
  are the user's real profiles, meetings, and session state. `meetink stop`,
  `discard`, `profile` mutations, or importing server modules with the real
  env all mutate it (a unit test once wrote fake merges into the live session
  journal). Tests set `MEETINK_HOME`/`MEETINK_TRANSCRIPTS_DIR` to a tempdir,
  and destructive experiments run on a **Duplicate Meeting** copy, never the
  original.
- The subcommand is `app build` — `app --build` silently relaunches the OLD
  binary and exits 0 (verify a deploy landed via a fresh string in the binary
  or the bundle mtime).
- A running watch daemon keeps pre-pull code until it respawns; don't kill it
  to force that unless the recorder is idle (the app's reconciler respawns it
  within seconds).
- The diarize server (`:8179`) holds LIVE session voice clusters — restarting
  it mid-call loses them. Same gate: check, then act.

## Common commands

```sh
# First-time install: brew installs whisper-cpp, downloads model, builds Swift binary
./bin/meetink setup

# Build only the Swift capture binary (after editing main.swift)
cd src/capture && swiftc -O -o meetink-capture Sources/main.swift \
    -framework ScreenCaptureKit -framework AVFoundation \
    -framework CoreMedia -framework CoreAudio \
    -parse-as-library -target arm64-apple-macosx14.0 \
    -sdk /Library/Developer/CommandLineTools/SDKs/MacOSX15.5.sdk
# …or just re-run `./bin/meetink start` — it rebuilds if the binary is missing.

# Run / stop / inspect
./bin/meetink start       # spawns whisper-server then capture binary, both backgrounded
./bin/meetink stop        # SIGINTs both, cleans PID files
./bin/meetink status      # checks /tmp/meetink-capture.pid
./bin/meetink tail        # tail -f the transcript

# Logs (useful when something fails silently)
tail -f /tmp/meetink-whisper.log
tail -f /tmp/meetink-capture.log
```

There is a focused deterministic audio-policy suite (directionality, routes,
double-talk, and mic failure). Run it with the same NumPy-bearing environment
as refine:

```sh
~/.meetink/parakeet-venv/bin/python -m unittest discover -s tests -v
```

There is no general linter config. The Package.swift exists for tooling/IDE
support, but the launcher builds with `swiftc` directly (not `swift build`) so
it can pin the SDK and target.

## Things that bite

- **Two install locations for the binary.** `setup` / `build_capture` copies it to `$MK_HOME/bin/meetink-capture` (default `~/.meetink/bin`). The source-tree copy at `src/capture/meetink-capture` is gitignored and only used as a fallback. `find_capture_binary` in `bin/meetink` checks both. After editing `main.swift`, you have to either re-run `setup` or copy the new binary into `~/.meetink/bin/` — running `start` won't auto-rebuild if the old binary still exists.
- **SDK pinning matters.** `find_sdk` prefers `MacOSX15.5.sdk` then walks down. Newer SDKs from a freshly upgraded Xcode have caused Swift CLI mismatches; don't blindly switch to `MacOSX.sdk`. If a build breaks after an Xcode update, check which SDK `build_capture` actually picked.
- **Permissions attach to the terminal app, not the binary.** Granting Screen & System Audio Recording or Microphone to `meetink` itself does nothing — it has to be the terminal you launched from (Terminal.app, iTerm2, Ghostty, Warp). See `docs/permissions.md`.
- **`whisper-server` is global state.** It binds `:8178` for the whole machine. If a user already runs whisper-cpp for something else, `start_whisper_server` in the launcher will refuse (port collision, fails the 30 s readiness probe) — the existing PID-file check only catches *our own* server.
- **Hallucination filter is opinionated and aggressive.** `isHallucination` in `main.swift` drops common whisper artefacts (`(soft music)`, "thanks for watching", repetition loops, `©`/copyright strings, anything fully parenthesised under 40 chars). If a real utterance gets eaten, look here before assuming the transcription failed.
- **Transcript file is append-only with timestamped headers.** `main.swift` writes `# Meeting Transcript\nStarted: …` on start and `---\nEnded: …` on stop. The line format is `[HH:MM:SS] SPEAKER: text`. `TranscriptMerger` coalesces back-to-back same-speaker chunks (2 s gap or 5 s buffer max), so one user utterance ≠ one transcript line.

## Code map (the parts that need cross-file context)

- **Audio pipeline (`main.swift`):** `AudioBuffer` (lock-protected sample queues for sys + mic) → `tryExtractChunks` (every 1 s loop tick, pulls ≥3 s if available) → `writeWAV` → `transcribe` (multipart POST to whisper-server, includes the `MEETINK_PROMPT` file *plus* a 200-char rolling context per speaker via `TranscriptContext`) → `isHallucination` → `TranscriptMerger.add` → `live.txt`.
- **Speaker labelling.** Mic chunks always get `ME`. System chunks default to `THEM`; if the diarize-server is up, `DiarizeAudioBuffer` accumulates 10 s windows (with 3 s overlap), POSTs to `:8179/identify`, and the returned name uppercased becomes the live label until the next identification.
- **CLI dispatch.** `bin/meetink` switches on `$1` at the bottom of the file. New subcommands go there + a `cmd_<name>` function. `src/lib/ui.sh` provides the colour table `$C` and box-drawing helpers; `src/lib/welcome.sh` is the no-arg landing page (the one that detects `_has_binary`/`_has_model`/`_has_whisper`/`_is_running` to colour the status dots).

## Conventions

- The user-facing data dir is `$MEETINK_HOME` (default `~/.meetink`) with subdirs `bin/`, `models/`, `transcripts/`, `prompts/`. All paths in both the launcher and `main.swift` are env-overridable — see the `ENV OVERRIDES` block in `cmd_help` and the top of `main.swift` for the canonical list. Add new paths the same way (env var → fallback default).
- Custom whisper vocabulary lives in `~/.meetink/prompts/default.txt`, seeded from `src/capture/prompts/default.txt` on first `setup`. The example template at `src/capture/prompts/example.txt` is what users are pointed to in the README.
- Keep the launcher zsh-only (it uses `${0:A}`, `${name:h}`, `typeset -gA`, glob qualifiers). Don't port to bash without a reason.
