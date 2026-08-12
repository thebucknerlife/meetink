#!/bin/zsh
# Post-meeting refine pass — re-transcribe the whole session with Parakeet.
#
# The live transcript is assembled from independent 3 s chunks; whisper never
# sees cross-chunk context. When the parakeet venv is installed, /stop
# re-transcribes the spooled session audio in full (sentence-level timestamps,
# sentence-level re-diarization against the sidecar) and REPLACES the live
# transcript's content in place — titling, summaries, meetings.md, /ask and
# the app window all consume the refined text with zero further changes. The
# raw live version is kept next to it as <session>.live-raw.txt.
#
# Also powers `meetink refine <audio-file>` (and the app's drag-and-drop):
# import any audio file as a transcript.
#
# Sourced by bin/meetink. Depends on: $MK_HOME, $MK_TRANSCRIPTS_DIR,
# $MK_TRANSCRIPT, C[] from ui.sh, me_name_get from identity.sh,
# title_session_file from titling.sh, summary_save from summary.sh,
# _rewrite-style inode-preserving writes (see diarize.sh for rationale).

MK_SPOOL_DIR="${MEETINK_SPOOL_DIR:-$MK_HOME/spool}"
MK_PARAKEET_VENV="$MK_HOME/parakeet-venv"

# One transcription at a time, machine-wide. Two concurrent refines would
# double-load the parakeet model AND interleave their /identify calls into
# the same diarize session (file A's speakers contaminating file B's
# clusters). Windows/queues stay concurrent — the WORK serializes here.
# mkdir is the atomic primitive; a pid file inside expires stale locks.
_refine_lock() {
    local lock="/tmp/meetink-refine.lock"
    local announced=0
    while ! mkdir "$lock" 2>/dev/null; do
        local owner=$(cat "$lock/pid" 2>/dev/null)
        if [[ -n "$owner" ]] && ! kill -0 "$owner" 2>/dev/null; then
            rm -rf "$lock"    # crashed holder — reclaim
            continue
        fi
        if (( ! announced )); then
            # Parsed by the app's import window ("refine: status ...").
            print -- "refine: status queued behind another transcription"
            announced=1
        fi
        sleep 2
    done
    echo $$ > "$lock/pid"
}

_refine_unlock() {
    rm -rf /tmp/meetink-refine.lock
}

refine_available() {
    [[ -x "$MK_PARAKEET_VENV/bin/python" ]]
}

# Env → config → default (on when installed). MEETINK_REFINE=off disables.
refine_enabled() {
    refine_available || return 1
    case "$MEETINK_REFINE" in
        off|false|0) return 1 ;;
        on|true|1)   return 0 ;;
    esac
    local v=$(grep '^refine=' "$MK_HOME/config" 2>/dev/null | head -1 | cut -d= -f2-)
    [[ "$v" != "false" && "$v" != "off" && "$v" != "0" ]]
}

# Clear stale spools before a new session so a crash's leftovers can't get
# stitched onto the wrong meeting. Called from cmd_start.
refine_clear_spool() {
    rm -f "$MK_SPOOL_DIR"/session-sys.raw "$MK_SPOOL_DIR"/session-mic.raw \
          "$MK_SPOOL_DIR"/session-sys.48k.raw "$MK_SPOOL_DIR"/session-mic.48k.raw
}

# Refine the just-stopped session in place. Called from cmd_stop after label
# consolidation, before name inference (inference then reads the refined
# text, and refine's sentence-level /identify calls have already fed the
# session clusters). Soft no-op whenever anything is missing.
#   $1 = transcript path (symlink)
refine_session() {
    refine_enabled || return 0
    local file="$1" actual="$1"
    [[ -L "$file" ]] && actual=$(readlink "$file" 2>/dev/null)
    [[ -f "$actual" ]] || return 0

    # Spools live in the session's folder now; the shared dir is the
    # legacy fallback for sessions started by an older build.
    local mic="${actual:h}/session-mic.raw"
    local sys="${actual:h}/session-sys.raw"
    if [[ ! -s "$mic" && ! -s "$sys" ]]; then
        mic="$MK_SPOOL_DIR/session-mic.raw"
        sys="$MK_SPOOL_DIR/session-sys.raw"
    fi
    [[ -s "$mic" || -s "$sys" ]] || return 0

    local started=$(grep '^Started:' "$actual" 2>/dev/null | head -1 | sed 's/^Started: //')
    local me=$(me_name_get 2>/dev/null)

    print -P "${C[bright_yellow]}▸${C[reset]} Refining transcript ${C[dim]}(parakeet, full-session context)...${C[reset]}"
    local tmp=$(mktemp -t meetink-refine) || return 0
    local -a args=(--out "$tmp" --me "${me:-ME}" --header-from "$actual")
    [[ -n "$started" ]] && args+=(--started "$started")
    [[ -s "$mic" ]] && args+=(--mic "$mic")
    [[ -s "$sys" ]] && args+=(--sys "$sys")

    _refine_lock
    print -- "$actual" > /tmp/meetink-postproc.path
    # Stream progress into the postproc state file so the app's status bar
    # can narrate ("post-processing… identifying speakers 43% (step 2/3)").
    # rc comes from pipestatus[1] — the pipeline's last command is the
    # reader loop, which always succeeds.
    local state=/tmp/meetink-postproc.state
    print -- "starting (step 1/3)" > "$state"
    local rc=0
    "$MK_PARAKEET_VENV/bin/python" "$MK_ROOT/src/refine/refine.py" "${args[@]}" 2>/tmp/meetink-refine.log | \
        while IFS= read -r line; do
            print -- "$line"
            case "$line" in
                "refine: progress diarize "*)
                    print -- "identifying speakers ${line##* }% (step 2/3)" > "$state" ;;
                "refine: progress "*)
                    local -a w=(${=line})
                    print -- "transcribing ${w[3]} ${w[4]}% (step 1/3)" > "$state" ;;
                "refine: status "*)
                    print -- "${line#refine: status } (step 2/3)" > "$state" ;;
            esac
            # Re-assert the target pointer — a raced cleanup can delete it
            # mid-run, blanking the meeting's scoped status (self-heals on
            # the next line).
            [[ -f /tmp/meetink-postproc.path ]] || print -- "$actual" > /tmp/meetink-postproc.path 2>/dev/null
        done
    rc=${pipestatus[1]}
    _refine_unlock
    if (( rc == 0 )); then
        # Keep the raw live version for comparison/debugging, then replace
        # the transcript's content in place (truncate-and-write keeps the
        # inode, so the app window and any tail keep streaming — same
        # rationale as _rewrite_transcript_label).
        cp "$actual" "${actual%.txt}.live-raw.txt" 2>/dev/null
        cat "$tmp" > "$actual"
        # Playback timing sidecar — lands as <base>.timing.json so titling
        # renames it with the transcript (same-basename rule).
        [[ -f "$tmp.timing.json" ]] && mv "$tmp.timing.json" "${actual%.txt}.timing.json"
        # Spools survive refine now: audio_archive_session runs AFTER us
        # (the transcript-driven mix needs the timing sidecar) and owns
        # their deletion.
        rm -f "$tmp"
        local n=$(grep -cE '^\[[0-9:]{8}\]' "$actual" 2>/dev/null)
        # NOTE: no nested ${${...}text:t} tricks here — that exact form is a
        # runtime "bad substitution" in zsh, and under set -e it killed
        # cmd_stop mid-pipeline (transcript replaced, but consolidation /
        # names / titling never ran — field-debugged from the launcher log).
        local raw_name="${actual%.txt}.live-raw.txt"
        print -P "${C[green]}✓${C[reset]} Refined: ${n} lines ${C[dim]}(raw kept: ${raw_name:t})${C[reset]}"
    else
        rm -f "$tmp"
        print -P "${C[yellow]}⚠${C[reset]} Refine failed — keeping the live transcript ${C[dim]}(see /tmp/meetink-refine.log)${C[reset]}"
    fi
}

# Trim a huge silent tail off the session spools (forgotten recordings).
# Runs from cmd_stop BEFORE audio_archive_session/refine_session so the
# m4a and the transcription both see the trimmed streams. Leaves a note
# in the transcript header (refine's --header-from carries it through)
# and in meta.json (the app's export header reads it).
trim_trailing_silence() {
    local actual="$1"
    [[ -L "$actual" ]] && actual=$(readlink "$actual" 2>/dev/null)
    [[ -f "$actual" ]] || return 0
    local mic="${actual:h}/session-mic.raw"
    local sys="${actual:h}/session-sys.raw"
    [[ -s "$mic" || -s "$sys" ]] || return 0
    [[ -x "$MK_PARAKEET_VENV/bin/python" ]] || return 0
    local cut=$("$MK_PARAKEET_VENV/bin/python" "$MK_ROOT/src/refine/trim_silence.py" \
        --mic "$mic" --sys "$sys" 2>>/tmp/meetink-refine.log)
    [[ "$cut" == <-> ]] && (( cut > 0 )) || return 0
    print -P "${C[green]}✓${C[reset]} Trimmed $(( cut / 60 ))m of trailing silence"
    typeset -f mk_activity >/dev/null 2>&1 && \
        mk_activity "trimmed $(( cut / 60 ))m trailing silence — ${${actual:t}:r}"
    python3 - "$actual" "$cut" <<'PYEOF9' 2>/dev/null || true
import json, os, sys
txt, cut = sys.argv[1], int(sys.argv[2])
meta = txt[:-4] + ".meta.json"
d = {}
if os.path.exists(meta):
    try:
        d = json.load(open(meta))
    except Exception:
        d = {}
d["trimmed_trailing_s"] = cut
json.dump(d, open(meta, "w"), sort_keys=True)
data = open(txt, errors="replace").read()
note = (f"# note: trimmed {cut // 60} minutes of trailing silence "
        "(recording ran past the end of the meeting)\n")
if "# note: trimmed" not in data:
    i = data.find("Started:")
    if i >= 0:
        open(txt, "w").write(data[:i] + note + data[i:])
PYEOF9
}

# --- Audio enhancement (echo cancellation + optional DeepFilterNet) ---
# enhance.py cross-cancels each stream's echo of the other (numpy NLMS —
# always available, the parakeet venv has numpy) and, when the enhance
# venv is installed, runs DeepFilterNet3 denoise/de-reverb per stream.
# Disable with enhance=off in config or MEETINK_ENHANCE=off.
enhance_enabled() {
    [[ "$MEETINK_ENHANCE" == "off" ]] && return 1
    local v=$(grep '^enhance=' "$MK_CONFIG_FILE" 2>/dev/null | head -1 | cut -d= -f2-)
    [[ "$v" != "off" && "$v" != "false" ]]
}

# Mix two raw spools into a listenable m4a: enhance (best-effort), then
# cross-duck so whoever is speaking is heard from their clean stream.
#   $1 = mic.raw  $2 = sys.raw  $3 = out.m4a
_mix_enhanced_m4a() {
    local mic="$1" sys="$2" out="$3"
    local _mix_t0=$SECONDS
    local ed=""
    # 48 kHz archive spools (capture writes them when keep_audio is on):
    # when the sibling pair exists with real content, the mix runs at
    # 48 kHz — a 16 kHz m4a caps playback at 8 kHz bandwidth ("tinny"
    # field report). Sub-second files are sim-mode leftovers; skip them.
    local mic48="${mic%.raw}.48k.raw" sys48="${sys%.raw}.48k.raw"
    local ar=16000
    local have48=0
    if [[ -s "$mic48" && -s "$sys48" ]] \
        && (( $(stat -f%z "$mic48" 2>/dev/null || echo 0) > 96000 )) \
        && (( $(stat -f%z "$sys48" 2>/dev/null || echo 0) > 96000 )); then
        have48=1
    fi
    local timing="${out%.m4a}.timing.json"

    # SPEAKERS-MODE: when the mic clearly carries the system audio
    # (strong bleed path), the mic stream alone IS the meeting — one
    # copy of every voice, echo impossible by construction. Every
    # layered mix doubled somebody (the entire v2-v9 saga); the user's
    # verdict on the raw mic spool: "the best version". mix_mode=auto
    # (default) detects it; =mic / =split force either path.
    local mix_mode=$(grep '^mix_mode=' "$MK_CONFIG_FILE" 2>/dev/null | head -1 | cut -d= -f2-)
    local mic_only=0
    if [[ "$mix_mode" == "mic" ]]; then
        mic_only=1
    elif [[ "$mix_mode" != "split" && -s "$mic" && -s "$sys" \
            && -x "$MK_PARAKEET_VENV/bin/python" ]]; then
        mic_only=$("$MK_PARAKEET_VENV/bin/python" - "$mic" "$sys" <<'PYEOF7' 2>/dev/null || print 0
import sys as _s
import numpy as np
mic = np.fromfile(_s.argv[1], dtype=np.int16).astype(np.float32) / 32768.0
sy = np.fromfile(_s.argv[2], dtype=np.int16).astype(np.float32) / 32768.0
n = min(len(mic), len(sy))
B = 1600  # 100 ms at 16 kHz
nb = n // B
if nb < 50:
    print(0); raise SystemExit
m = np.sqrt((mic[:nb*B].reshape(nb, B)**2).mean(axis=1))
s = np.sqrt((sy[:nb*B].reshape(nb, B)**2).mean(axis=1))
# Volume-adaptive loudness floor — a fixed 0.05 missed a quiet-playback
# speakers meeting, it got MIXED, and the mix re-added echo + pumping
# to two individually clean streams (field case). Half the 75th
# percentile of sys's non-silent blocks, never below 0.01.
act = s[s > 0.001]
floor = max(0.01, float(np.percentile(act, 75)) * 0.5) if len(act) > 50 else 0.05
loud = s > floor
# Speakers: the mic tracks the system audio at a substantial fraction
# (measured 1.03 quiet-playback, 0.57 normal). Headphone leak: 0.004.
print(1 if loud.sum() > 20 and float(np.median(m[loud] / s[loud])) > 0.15 else 0)
PYEOF7
)
    fi
    if (( mic_only )) && [[ -s "$mic" ]]; then
        local monly="$mic" mar=16000
        (( have48 )) && { monly="$mic48"; mar=48000; }
        local mrc=0
        ffmpeg -v error -y -f s16le -ar $mar -ac 1 -i "$monly" \
            -c:a aac -b:a 96k "$out" 2>>/tmp/meetink-refine.log || mrc=$?
        print -- "$(date '+%Y-%m-%d %H:%M:%S')  kind=mix name=${${out:t}:r} total_s=$((SECONDS - _mix_t0)) mode=mic-only" \
            >> "$MK_HOME/perf.log" 2>/dev/null || true
        (( mrc == 0 )) && print -P "${C[dim]}  (speakers-mode meeting — mic stream is the mix)${C[reset]}"
        return $mrc
    fi

    # Headphone mix: the streams are already the clean separation (no
    # bleed in the mic), so the mix is raw mic + sys with ONLY the
    # targeted residual-echo gate for the user's remote echo. The heavy
    # neural path ran on an AirPods field test and manufactured every
    # artifact it existed to prevent (mask-transfer "glass jar" on a
    # clean voice, span-duck pumping, hard-clip distortion) — with no
    # bleed there is nothing for it to do. DTLN (neural_mix.py) stays
    # available behind mix_mode=neural for future bleed-y edge cases.
    if [[ -x "$MK_PARAKEET_VENV/bin/python" && -s "$mic" && -s "$sys" \
          && "$mix_mode" != "neural" ]]; then
        local nmic="$mic" nsys="$sys" nar=16000
        (( have48 )) && { nmic="$mic48"; nsys="$sys48"; nar=48000; }
        local nd=$(mktemp -d -t meetink-hmix)
        if "$MK_PARAKEET_VENV/bin/python" "$MK_ROOT/src/refine/headphone_mix.py" \
                --mic16 "$mic" --sys16 "$sys" \
                --mic "$nmic" --sys "$nsys" --rate $nar \
                --out "$nd/mixed.raw" 2>>/tmp/meetink-refine.log; then
            local nrc=0
            ffmpeg -v error -y -f s16le -ar $nar -ac 1 -i "$nd/mixed.raw" \
                -c:a aac -b:a 96k "$out" 2>>/tmp/meetink-refine.log || nrc=$?
            rm -rf "$nd"
            print -- "$(date '+%Y-%m-%d %H:%M:%S')  kind=mix name=${${out:t}:r} total_s=$((SECONDS - _mix_t0)) mode=headphone" \
                >> "$MK_HOME/perf.log" 2>/dev/null || true
            return $nrc
        fi
        rm -rf "$nd"
        print -P "${C[dim]}  (headphone mix bailed — fallback)${C[reset]}"
    fi

    # DTLN neural mix — opt-in via mix_mode=neural (see headphone mix
    # comment above for why it is no longer the default).
    local dtln_py="$MK_HOME/dtln-venv/bin/python"
    if [[ "$mix_mode" == "neural" && -f "$timing" && -x "$dtln_py" \
          && -f "$MK_HOME/dtln/dtln_aec_512_1.tflite" \
          && -s "$mic" && -s "$sys" ]]; then
        local nmic="$mic" nsys="$sys" nar=16000
        (( have48 )) && { nmic="$mic48"; nsys="$sys48"; nar=48000; }
        local nd=$(mktemp -d -t meetink-nmix)
        if "$dtln_py" "$MK_ROOT/src/refine/neural_mix.py" \
                --mic16 "$mic" --sys16 "$sys" \
                --mic "$nmic" --sys "$nsys" --rate $nar \
                --timing "$timing" --me "$(me_name_get 2>/dev/null || print ME)" \
                --progress-state /tmp/meetink-postproc.state \
                --out "$nd/mixed.raw" 2>>/tmp/meetink-refine.log; then
            local nrc=0
            ffmpeg -v error -y -f s16le -ar $nar -ac 1 -i "$nd/mixed.raw" \
                -c:a aac -b:a 96k "$out" 2>>/tmp/meetink-refine.log || nrc=$?
            rm -rf "$nd"
            print -- "$(date '+%Y-%m-%d %H:%M:%S')  kind=mix name=${${out:t}:r} total_s=$((SECONDS - _mix_t0)) mode=neural" \
                >> "$MK_HOME/perf.log" 2>/dev/null || true
            return $nrc
        fi
        rm -rf "$nd"
        print -P "${C[dim]}  (neural mix bailed — transcript fallback)${C[reset]}"
    fi

    # Transcript-driven mix (the "what I heard on the call" path): sys
    # passes through UNTOUCHED — it is the audio the user heard, so no
    # enhance/DFN coloration — and the mic opens only inside the user's
    # own word spans (plus mic-exclusive speech for in-person voices).
    # Requires refine's timing sidecar, which is why the m4a step runs
    # AFTER refine now. Falls back to enhance + sidechain duck when the
    # timing is missing or the gating bails.
    if [[ -f "$timing" && -x "$MK_PARAKEET_VENV/bin/python" ]]; then
        local tmic="$mic" tsys="$sys" tar=16000
        (( have48 )) && { tmic="$mic48"; tsys="$sys48"; tar=48000; }
        local md=$(mktemp -d -t meetink-mix)
        if "$MK_PARAKEET_VENV/bin/python" "$MK_ROOT/src/refine/transcript_mix.py" \
                --mic "$tmic" --sys "$tsys" --rate $tar \
                --timing "$timing" --me "$(me_name_get 2>/dev/null || print ME)" \
                --out "$md/mixed.raw" 2>>/tmp/meetink-refine.log; then
            local rc2=0
            ffmpeg -v error -y -f s16le -ar $tar -ac 1 -i "$md/mixed.raw" \
                -c:a aac -b:a 96k "$out" 2>>/tmp/meetink-refine.log || rc2=$?
            rm -rf "$md"
            print -- "$(date '+%Y-%m-%d %H:%M:%S')  kind=mix name=${${out:t}:r} total_s=$((SECONDS - _mix_t0)) mode=transcript" \
                >> "$MK_HOME/perf.log" 2>/dev/null || true
            return $rc2
        fi
        rm -rf "$md"
        print -P "${C[dim]}  (transcript mix bailed — enhance + duck fallback)${C[reset]}"
    fi

    if enhance_enabled && [[ -x "$MK_PARAKEET_VENV/bin/python" ]]; then
        ed=$(mktemp -d -t meetink-enhance)
        # live_deepfilter=off keeps the echo-cancel but skips DFN on live
        # mixes — DFN's denoise can leave voices tinny/robotic (same
        # artifact class that made it opt-in for imports).
        local -a dfnflag=()
        [[ "$(grep '^live_deepfilter=' "$MK_CONFIG_FILE" 2>/dev/null | cut -d= -f2-)" == "off" ]] \
            && dfnflag=(--no-deepfilter)
        local -a arch=()
        (( have48 )) && arch=(--mic48 "$mic48" --sys48 "$sys48")
        if "$MK_PARAKEET_VENV/bin/python" "$MK_ROOT/src/refine/enhance.py" \
                --mic "$mic" --sys "$sys" \
                --out-mic "$ed/mic.raw" --out-sys "$ed/sys.raw" \
                --progress-state /tmp/meetink-postproc.state \
                "${arch[@]}" "${dfnflag[@]}" \
                2>>/tmp/meetink-refine.log; then
            mic="$ed/mic.raw"
            sys="$ed/sys.raw"
            # enhance.py emits 48 kHz outputs when it got the 48 kHz pair
            (( have48 )) && ar=48000
        elif (( have48 )); then
            # enhance failed — still mix the raw archive streams rather
            # than falling back to the band-limited pair.
            mic="$mic48"; sys="$sys48"; ar=48000
        fi
    elif (( have48 )); then
        mic="$mic48"; sys="$sys48"; ar=48000
    fi
    local -a raw=(-f s16le -ar $ar -ac 1)
    local rc=0
    ffmpeg -v error -y "${raw[@]}" -i "$mic" "${raw[@]}" -i "$sys" \
        -filter_complex "[0:a]asplit=2[m1][m2];[1:a]asplit=2[s1][s2];[s1][m1]sidechaincompress=threshold=0.02:ratio=8:attack=10:release=400[sd];[m2][s2]sidechaincompress=threshold=0.02:ratio=8:attack=10:release=400[md];[md][sd]amix=inputs=2:duration=longest:normalize=0" \
        -c:a aac -b:a 96k "$out" 2>>/tmp/meetink-refine.log || rc=$?
    [[ -n "$ed" ]] && rm -rf "$ed"
    print -- "$(date '+%Y-%m-%d %H:%M:%S')  kind=mix name=${${out:t}:r} total_s=$((SECONDS - _mix_t0))" \
        >> "$MK_HOME/perf.log" 2>/dev/null || true
    return $rc
}

# Kill any in-flight post-processing (stop pipeline or reprocess): the
# lock-holder shell, its python workers, and the narration files. Used by
# discard and by the app's Delete — a deleted meeting must not keep a
# multi-hour refine chewing on its corpse.
postproc_kill() {
    local holder=$(cat /tmp/meetink-refine.lock/pid 2>/dev/null)
    [[ -n "$holder" ]] && kill -9 "$holder" 2>/dev/null || true
    pkill -9 -f "src/refine/refine.py" 2>/dev/null || true
    pkill -9 -f "src/refine/enhance.py" 2>/dev/null || true
    pkill -9 -f "src/refine/pyannote_diar.py" 2>/dev/null || true
    pkill -9 -f "enhance-venv/bin/deepFilter" 2>/dev/null || true
    rm -rf /tmp/meetink-refine.lock
    rm -f /tmp/meetink-postproc.state /tmp/meetink-postproc.path
}

# Listening copy for an IMPORT: single stream, so no echo cancellation
# is possible (nothing to use as a reference) — but DeepFilterNet
# denoise/de-reverb applies fine, and loudness normalization helps the
# quiet-recording case. Falls back to a plain normalized transcode when
# the enhance venv isn't installed.
#   $1 = source audio file  $2 = out.m4a
_import_enhanced_m4a() {
    local input="$1" out="$2"
    local dfn="$MK_HOME/enhance-venv/bin/deepFilter"
    local td=$(mktemp -d -t meetink-import-enh)
    local rc=1
    # DFN is OPT-IN for imports (import_deepfilter=on): on single-stream
    # room recordings its noise reduction eats faint far-mic speech — the
    # transcript (from the original audio) shows words the enhanced m4a
    # no longer contains, which reads as broken playback sync. Recordings
    # keep DFN: near-mic streams survive it.
    local dfn_ok=""
    [[ "$(grep '^import_deepfilter=' "$MK_CONFIG_FILE" 2>/dev/null | cut -d= -f2-)" == "on" ]] && dfn_ok=1
    if [[ -n "$dfn_ok" ]] && enhance_enabled && [[ -x "$dfn" ]]; then
        print -- "enhancing audio — DeepFilterNet (step 3/3)" > /tmp/meetink-postproc.state
        if ffmpeg -v error -y -i "$input" -vn -ar 48000 -ac 1 "$td/in.wav" 2>>/tmp/meetink-refine.log && \
           "$dfn" "$td/in.wav" -o "$td" >>/tmp/meetink-refine.log 2>&1 && \
           [[ -f "$td/in_DeepFilterNet3.wav" ]] && \
           ffmpeg -v error -y -i "$td/in_DeepFilterNet3.wav" -af loudnorm=I=-18 \
               -c:a aac -b:a 128k "$out" 2>>/tmp/meetink-refine.log; then
            rc=0
        fi
    fi
    if (( rc != 0 )); then
        ffmpeg -v error -y -i "$input" -vn -af loudnorm=I=-18 \
            -c:a aac -b:a 128k "$out" 2>>/tmp/meetink-refine.log || rc=$?
        [[ -f "$out" ]] && rc=0
    fi
    rm -rf "$td"
    return $rc
}

# Install the DeepFilterNet venv (torch — a large download; opt-in).
cmd_enhance_install() {
    local venv="$MK_HOME/enhance-venv"
    if [[ -x "$venv/bin/deepFilter" ]]; then
        print -P "${C[green]}✓${C[reset]} DeepFilterNet already installed ${C[dim]}($venv)${C[reset]}"
        return 0
    fi
    print -P "${C[bright_yellow]}▸${C[reset]} Installing DeepFilterNet ${C[dim]}(torch — several hundred MB)...${C[reset]}"
    if command -v uv >/dev/null 2>&1; then
        # Python 3.10 + torch 2.0: deepfilterlib has no wheels for newer
        # pythons, and DFN 0.5.x imports the torchaudio.backend API that
        # torchaudio >= 2.1 removed. Both skews field-debugged.
        uv venv "$venv" --python 3.10 && \
        uv pip install --python "$venv/bin/python" deepfilternet "torch==2.0.1" "torchaudio==2.0.2" || return 1
    else
        python3 -m venv "$venv" && "$venv/bin/pip" install deepfilternet "torch==2.0.1" "torchaudio==2.0.2" || return 1
    fi
    print -P "${C[green]}✓${C[reset]} DeepFilterNet installed — future recordings (and reprocess) use it automatically"
}

# Install the pyannote venv — the premium import diarizer. The pinned
# set below is a MATRIX, not preferences: pyannote.audio 4.x requires
# accepting a different gated model (community-1); 3.x needs the old
# torchaudio API (< 2.3), which needs numpy 1.x, which needs scipy
# < 1.12, and huggingface_hub >= 0.26 removed use_auth_token. Every pin
# was field-derived; loosen at your peril.
cmd_pyannote_install() {
    local venv="$MK_HOME/pyannote-venv"
    print -P "${C[bright_yellow]}▸${C[reset]} Installing pyannote ${C[dim]}(torch — a large download)...${C[reset]}"
    if command -v uv >/dev/null 2>&1; then
        uv venv "$venv" --python 3.12 && \
        uv pip install --python "$venv/bin/python" \
            'pyannote.audio<4' 'torch==2.2.2' 'torchaudio==2.2.2' \
            'huggingface_hub==0.25.2' 'numpy<2' 'scipy==1.11.4' || return 1
    else
        python3 -m venv "$venv" && "$venv/bin/pip" install \
            'pyannote.audio<4' 'torch==2.2.2' 'torchaudio==2.2.2' \
            'huggingface_hub==0.25.2' 'numpy<2' 'scipy==1.11.4' || return 1
    fi
    print -P "${C[green]}✓${C[reset]} pyannote installed. Accept the gated models once (huggingface.co:"
    print -P "  ${C[dim]}pyannote/speaker-diarization-3.1 and pyannote/segmentation-3.0), log in"
    print -P "  via huggingface-cli, and imports use it automatically.${C[reset]}"
}

# Archive the just-stopped session's audio next to its transcript (i.e.
# into the per-session folder). Two independent knobs from $MK_HOME/config:
#   keep_audio  → <base>.m4a  — mic+sys mixed into one listenable file
#   keep_spools → <base>.mic.wav / <base>.sys.wav — the two raw streams,
#                 replayable through `meetink simulate --mic/--sys`
# Called from cmd_stop BEFORE refine_session (refine deletes the raw spools
# on success). Best-effort — never blocks the stop pipeline. Titling later
# renames these in lockstep with the transcript (same-basename rule).
audio_archive_session() {
    local actual="$1"
    [[ -L "$actual" ]] && actual=$(readlink "$actual" 2>/dev/null)
    [[ -f "$actual" ]] || return 0
    local mic="${actual:h}/session-mic.raw"
    local sys="${actual:h}/session-sys.raw"
    if [[ ! -s "$mic" && ! -s "$sys" ]]; then
        mic="$MK_SPOOL_DIR/session-mic.raw"
        sys="$MK_SPOOL_DIR/session-sys.raw"
    fi
    [[ -s "$mic" || -s "$sys" ]] || return 0

    # This step is the spools' last consumer (it runs after refine now),
    # so every exit path below deletes them.
    local keep_audio=0 keep_spools=0
    mk_config_bool keep_audio && keep_audio=1
    mk_config_bool keep_spools && keep_spools=1
    if (( ! keep_audio && ! keep_spools )) || ! command -v ffmpeg >/dev/null 2>&1; then
        (( keep_audio || keep_spools )) && \
            print -P "${C[yellow]}⚠${C[reset]} keep audio: ffmpeg not found — skipping"
        rm -f "$mic" "$sys" "${mic%.raw}.48k.raw" "${sys%.raw}.48k.raw"
        return 0
    fi

    local base="${actual%.txt}"
    local -a raw=(-f s16le -ar 16000 -ac 1)
    if (( keep_audio )); then
        local rc=0
        if [[ -s "$mic" && -s "$sys" ]]; then
            # Enhanced mix: echo-cancel the streams against each other
            # (plus DeepFilterNet when installed), then cross-duck. See
            # _mix_enhanced_m4a / enhance.py.
            _mix_enhanced_m4a "$mic" "$sys" "${base}.m4a" || rc=$?
        else
            local only="$mic"
            [[ -s "$sys" ]] && only="$sys"
            local -a onlyraw=("${raw[@]}")
            if [[ -s "${only%.raw}.48k.raw" ]] \
                && (( $(stat -f%z "${only%.raw}.48k.raw" 2>/dev/null || echo 0) > 96000 )); then
                only="${only%.raw}.48k.raw"
                onlyraw=(-f s16le -ar 48000 -ac 1)
            fi
            ffmpeg -v error -y "${onlyraw[@]}" -i "$only" \
                -c:a aac -b:a 96k "${base}.m4a" 2>>/tmp/meetink-refine.log || rc=$?
        fi
        if (( rc == 0 )); then
            print -P "${C[green]}✓${C[reset]} Audio kept: ${C[dim]}${base:t}.m4a${C[reset]}"
        else
            print -P "${C[yellow]}⚠${C[reset]} keep audio: mixdown failed ${C[dim]}(see /tmp/meetink-refine.log)${C[reset]}"
        fi
    fi
    if (( keep_spools )); then
        # Archive the best copy we have: the 48 kHz spool when capture
        # wrote one (full bandwidth), else the 16 kHz transcription spool.
        # Every consumer of these wavs resamples explicitly (reprocess
        # -ar 16000, simulate -ar 16000), so the higher rate is safe.
        local kept="" src stream
        local -a wavin
        for stream in mic sys; do
            src="$mic"
            [[ "$stream" == sys ]] && src="$sys"
            wavin=("${raw[@]}")
            if [[ -s "${src%.raw}.48k.raw" ]] \
                && (( $(stat -f%z "${src%.raw}.48k.raw" 2>/dev/null || echo 0) > 96000 )); then
                src="${src%.raw}.48k.raw"
                wavin=(-f s16le -ar 48000 -ac 1)
            fi
            if [[ -s "$src" ]] && ffmpeg -v error -y "${wavin[@]}" -i "$src" "${base}.${stream}.wav" 2>>/tmp/meetink-refine.log; then
                kept="${kept:+$kept / }${base:t}.${stream}.wav"
            fi
        done
        [[ -n "$kept" ]] && print -P "${C[green]}✓${C[reset]} Spools kept: ${C[dim]}${kept}${C[reset]}"
    fi
    # Spools consumed — tidy so stale audio can't bleed into the next
    # session (refine_clear_spool at the next start is the backstop).
    rm -f "$mic" "$sys" "${mic%.raw}.48k.raw" "${sys%.raw}.48k.raw"
    return 0
}

# Re-run the refine pipeline on an EXISTING meeting using its kept audio —
# for picking up pipeline improvements (echo suppression, diarization,
# thresholds) on old transcripts. Prefers the two spool wavs (full
# mic/sys separation); falls back to the mixed .m4a (single-stream).
#   $1 = transcript path (or empty = the live/latest transcript)
cmd_reprocess() {
    local file="${1:-$MK_TRANSCRIPT}" actual
    actual="$file"
    [[ -L "$file" ]] && actual=$(readlink "$file" 2>/dev/null)
    if [[ ! -f "$actual" ]]; then
        print -P "${C[red]}error:${C[reset]} no such transcript: $file"
        return 1
    fi
    if ! refine_available; then
        print -P "${C[red]}error:${C[reset]} parakeet venv not installed"
        return 1
    fi
    local base="${actual%.txt}"
    local ino=$(stat -f %i "$actual" 2>/dev/null)
    local started=$(grep '^Started:' "$actual" 2>/dev/null | head -1 | sed 's/^Started: //')
    local me=$(me_name_get 2>/dev/null)
    local tmpdir=$(mktemp -d -t meetink-reproc)
    # The current transcript's labels seed the new diarization — manual
    # speaker corrections survive the reprocess instead of re-deriving
    # from voiceprints alone.
    local -a args=(--out "$tmpdir/out.txt" --me "${me:-ME}" --header-from "$actual" --prior "$actual")
    [[ -n "$started" ]] && args+=(--started "$started")

    if [[ -s "$base.mic.wav" || -s "$base.sys.wav" ]]; then
        [[ -s "$base.mic.wav" ]] && { ffmpeg -v error -y -i "$base.mic.wav" -ar 16000 -ac 1 -f s16le "$tmpdir/mic.raw" && args+=(--mic "$tmpdir/mic.raw"); }
        [[ -s "$base.sys.wav" ]] && { ffmpeg -v error -y -i "$base.sys.wav" -ar 16000 -ac 1 -f s16le "$tmpdir/sys.raw" && args+=(--sys "$tmpdir/sys.raw"); }
        # Kept wavs recorded at 48 kHz → re-derive the archive pair too, so
        # the rebuilt m4a keeps full bandwidth (the mix step finds them as
        # siblings of $tmpdir/{mic,sys}.raw).
        local wavrate=$(ffprobe -v error -select_streams a:0 -show_entries stream=sample_rate -of csv=p=0 "$base.mic.wav" 2>/dev/null)
        if [[ "$wavrate" == "48000" && -s "$base.mic.wav" && -s "$base.sys.wav" ]]; then
            ffmpeg -v error -y -i "$base.mic.wav" -ar 48000 -ac 1 -f s16le "$tmpdir/mic.48k.raw" 2>>/tmp/meetink-refine.log || true
            ffmpeg -v error -y -i "$base.sys.wav" -ar 48000 -ac 1 -f s16le "$tmpdir/sys.48k.raw" 2>>/tmp/meetink-refine.log || true
        fi
        print -P "${C[bright_yellow]}▸${C[reset]} Reprocessing ${C[bold]}${actual:t}${C[reset]} ${C[dim]}(from kept spools)...${C[reset]}"
    elif [[ -s "$base.m4a" ]]; then
        ffmpeg -v error -y -i "$base.m4a" -ar 16000 -ac 1 -f s16le "$tmpdir/sys.raw" || { rm -rf "$tmpdir"; return 1 }
        args+=(--sys "$tmpdir/sys.raw")
        print -P "${C[bright_yellow]}▸${C[reset]} Reprocessing ${C[bold]}${actual:t}${C[reset]} ${C[dim]}(from kept .m4a — single stream, no mic/sys separation)...${C[reset]}"
    else
        print -P "${C[red]}error:${C[reset]} no kept audio for this meeting ${C[dim]}(needs .mic/.sys.wav or .m4a — enable keep audio in Settings)${C[reset]}"
        rm -rf "$tmpdir"
        return 1
    fi

    _refine_lock
    # Same progress narration cmd_stop's refine gets — the app's status
    # bar shows "post-processing… <phase> (step N/3)" while this runs.
    local state=/tmp/meetink-postproc.state
    print -- "starting (step 1/3)" > "$state"
    print -- "$actual" > /tmp/meetink-postproc.path
    local rc=0
    "$MK_PARAKEET_VENV/bin/python" "$MK_ROOT/src/refine/refine.py" "${args[@]}" 2>/tmp/meetink-refine.log | \
        while IFS= read -r line; do
            print -- "$line"
            case "$line" in
                "refine: progress diarize "*)
                    print -- "identifying speakers ${line##* }% (step 2/3)" > "$state" ;;
                "refine: progress "*)
                    local -a w=(${=line})
                    print -- "transcribing ${w[3]} ${w[4]}% (step 1/3)" > "$state" ;;
                "refine: status "*)
                    print -- "${line#refine: status } (step 2/3)" > "$state" ;;
            esac
            # Re-assert the target pointer — a raced cleanup can delete it
            # mid-run, blanking the meeting's scoped status (self-heals on
            # the next line).
            [[ -f /tmp/meetink-postproc.path ]] || print -- "$actual" > /tmp/meetink-postproc.path 2>/dev/null
        done
    rc=${pipestatus[1]}
    _refine_unlock
    # Re-resolve by inode: a rename during the run moved the folder and
    # every file in it — mv preserves inodes, so find our transcript
    # wherever it lives now (same trick cmd_refine uses for titling).
    if [[ -n "$ino" && ! -f "$actual" ]]; then
        local by_ino=$(find "$MK_TRANSCRIPTS_DIR" -maxdepth 2 -name '*.txt' -inum "$ino" 2>/dev/null | head -1)
        if [[ -n "$by_ino" && -f "$by_ino" ]]; then
            print -P "  ${C[dim]}(meeting was renamed mid-run — following it to ${by_ino:t})${C[reset]}"
            actual="$by_ino"
            base="${actual%.txt}"
        fi
    fi
    if (( rc == 0 )) && [[ -f "$actual" ]] && grep -qE '^\[' "$tmpdir/out.txt"; then
        cp "$actual" "${base}.pre-reprocess.txt" 2>/dev/null || true
        cat "$tmpdir/out.txt" > "$actual"
        [[ -f "$tmpdir/out.txt.timing.json" ]] && mv "$tmpdir/out.txt.timing.json" "${base}.timing.json"
        local n=$(grep -cE '^\[[0-9:]{8}\]' "$actual")
        print -P "${C[green]}✓${C[reset]} Reprocessed: ${n} lines ${C[dim]}(previous kept: ${base:t}.pre-reprocess.txt)${C[reset]}"
        typeset -f mk_activity >/dev/null && mk_activity "reprocessed — ${${actual:t}:r}"
        # Rebuild the listenable m4a too — reprocess exists to pick up
        # pipeline improvements, and the audio pipeline is part of that.
        if [[ -s "$tmpdir/mic.raw" && -s "$tmpdir/sys.raw" ]]; then
            print -- "enhancing audio (step 3/3)" > /tmp/meetink-postproc.state
            _mix_enhanced_m4a "$tmpdir/mic.raw" "$tmpdir/sys.raw" "${base}.m4a" && \
                print -P "${C[green]}✓${C[reset]} Audio rebuilt: ${C[dim]}${base:t}.m4a (enhanced)${C[reset]}"
        fi
    else
        rm -rf "$tmpdir"
        rm -f /tmp/meetink-postproc.state /tmp/meetink-postproc.path
        print -P "${C[red]}error:${C[reset]} reprocess failed ${C[dim]}(see /tmp/meetink-refine.log)${C[reset]}"
        return 1
    fi
    rm -rf "$tmpdir"
    rm -f /tmp/meetink-postproc.state /tmp/meetink-postproc.path
    typeset -f mk_notify >/dev/null 2>&1 && \
        mk_notify "Reprocess done" "${${actual:t}:r}"
}

# Fast recluster of an existing meeting: no transcription, no
# enhancement — embeddings + clustering + the user's label corrections
# as exemplars. The 'I fixed two segments, propagate that' loop in about
# a minute instead of a full reprocess.
#   $1 = transcript path (or empty = latest)
cmd_relabel() {
    local file="${1:-$MK_TRANSCRIPT}" actual
    actual="$file"
    [[ -L "$file" ]] && actual=$(readlink "$file" 2>/dev/null)
    if [[ ! -f "$actual" ]]; then
        print -P "${C[red]}error:${C[reset]} no such transcript: $file"
        return 1
    fi
    refine_available || { print -P "${C[red]}error:${C[reset]} parakeet venv missing"; return 1 }
    local me=$(me_name_get 2>/dev/null)
    local tmp=$(mktemp -t meetink-relabel)
    print -P "${C[bright_yellow]}▸${C[reset]} Relabeling speakers ${C[bold]}${actual:t}${C[reset]} ${C[dim]}(fast — no retranscription)...${C[reset]}"
    _refine_lock
    local state=/tmp/meetink-postproc.state
    print -- "relabeling speakers (fast)" > "$state"
    print -- "$actual" > /tmp/meetink-postproc.path
    local rc=0
    "$MK_PARAKEET_VENV/bin/python" "$MK_ROOT/src/refine/refine.py" \
        --relabel "$actual" --me "${me:-ME}" --out "$tmp" \
        2>>/tmp/meetink-refine.log || rc=$?
    _refine_unlock
    if (( rc == 0 )) && grep -qE '^\[' "$tmp"; then
        cat "$tmp" > "$actual"
        print -P "${C[green]}✓${C[reset]} Speakers relabeled ${C[dim]}(see /tmp/meetink-refine.log for the change count)${C[reset]}"
        typeset -f mk_activity >/dev/null && mk_activity "relabeled — ${${actual:t}:r}"
    else
        print -P "${C[red]}error:${C[reset]} relabel failed ${C[dim]}(see /tmp/meetink-refine.log — full reprocess is the fallback)${C[reset]}"
    fi
    rm -f "$tmp" /tmp/meetink-postproc.state /tmp/meetink-postproc.path
    (( rc == 0 ))
}

# Import an audio file as a transcript: decode → parakeet → diarize →
# title → summary. The transcript lands in the active project's folder and
# live.txt points at it (unless a recording is in flight), so the app
# window shows the result the moment it's ready.
#   $1 = path to audio file
cmd_refine() {
    local input="$1"
    if [[ -z "$input" ]]; then
        print -P "${C[red]}usage:${C[reset]} meetink refine <audio-file>"
        print -P "  ${C[dim]}Transcribe an audio file (wav/m4a/mp3/aiff/... — anything ffmpeg reads).${C[reset]}"
        print -P "  ${C[dim]}The post-meeting refine of live recordings runs automatically on stop.${C[reset]}"
        return 1
    fi
    if ! refine_available; then
        print -P "${C[red]}error:${C[reset]} parakeet venv not found at $MK_PARAKEET_VENV"
        print -P "  ${C[dim]}uv venv $MK_PARAKEET_VENV --python 3.12 && uv pip install --python $MK_PARAKEET_VENV/bin/python parakeet-mlx${C[reset]}"
        return 1
    fi
    if [[ ! -f "$input" ]]; then
        print -P "${C[red]}error:${C[reset]} no such file: $input"
        return 1
    fi

    local base="${${input:t}:r}"
    # Sanitize for a filename: keep alnum/dash/underscore.
    base=$(print -rn -- "$base" | tr -c 'A-Za-z0-9_-' '-' | sed 's/--*/-/g')
    # Imports get a per-session folder too (same layout as recordings).
    local sess="$(date +%Y-%m-%d_%H-%M)_import-${base}"
    local sess_dir="$MK_TRANSCRIPTS_DIR/$sess"
    mkdir -p "$sess_dir"
    local out="$sess_dir/$sess.txt"

    # Placeholder transcript so the meeting appears in the app's Meetings
    # list the moment the upload starts (the real content lands when the
    # refine finishes and overwrites this file in place).
    {
        print -- "# Meeting Transcript (importing audio)"
        print -- "# source: ${input:t}"
        print -- "Started: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } > "$out"

    print -P "${C[bright_yellow]}▸${C[reset]} Transcribing ${C[bold]}${input:t}${C[reset]} ${C[dim]}(parakeet)...${C[reset]}"
    typeset -f mk_activity >/dev/null && mk_activity "import started — ${input:t}"
    _refine_lock
    # Same narration files the stop pipeline uses — the Meetings page
    # marks THIS row orange while the import works.
    local state=/tmp/meetink-postproc.state
    print -- "starting (step 1/3)" > "$state"
    print -- "$out" > /tmp/meetink-postproc.path
    local rc=0
    "$MK_PARAKEET_VENV/bin/python" "$MK_ROOT/src/refine/refine.py" \
            --input "$input" --out "$out" 2>/tmp/meetink-refine.log | \
        while IFS= read -r line; do
            print -- "$line"
            case "$line" in
                "refine: progress diarize "*)
                    print -- "identifying speakers ${line##* }% (step 2/3)" > "$state" ;;
                "refine: progress "*)
                    local -a w=(${=line})
                    print -- "transcribing ${w[3]} ${w[4]}% (step 1/3)" > "$state" ;;
                "refine: status "*)
                    print -- "${line#refine: status } (step 2/3)" > "$state" ;;
            esac
            # Re-assert the target pointer — a raced cleanup can delete it
            # mid-run, blanking the meeting's scoped status (self-heals on
            # the next line).
            [[ -f /tmp/meetink-postproc.path ]] || print -- "$actual" > /tmp/meetink-postproc.path 2>/dev/null
        done
    rc=${pipestatus[1]}
    _refine_unlock
    if (( rc != 0 )); then
        rm -rf "$sess_dir"   # no ghost meeting from a failed import
        rm -f /tmp/meetink-postproc.state /tmp/meetink-postproc.path
        print -P "${C[red]}error:${C[reset]} transcription failed ${C[dim]}(see /tmp/meetink-refine.log)${C[reset]}"
        return 1
    fi
    local n=$(grep -cE '^\[[0-9:]{8}\]' "$out" 2>/dev/null)
    [[ -f "$out.timing.json" ]] && mv "$out.timing.json" "${out%.txt}.timing.json"
    print -P "${C[green]}✓${C[reset]} Transcribed: ${C[bright_cyan]}${out/$HOME/~}${C[reset]} ${C[dim]}(${n} lines)${C[reset]}"

    # Settings: keep audio → an enhanced, normalized .m4a (DeepFilterNet
    # when installed) — uniform with recordings, so the player always
    # finds it. The user's original stays where it was.
    if mk_config_bool keep_audio; then
        _import_enhanced_m4a "$input" "$sess_dir/$sess.m4a" && \
            print -P "${C[green]}✓${C[reset]} Audio kept: ${C[dim]}${sess}.m4a (enhanced)${C[reset]}"
    fi

    # Same name inference a live meeting gets — the offline diarizer just
    # handed this import's clusters to the sidecar, so confident names
    # both rewrite the transcript AND enroll voices.
    if typeset -f infer_speaker_names >/dev/null 2>&1; then
        print -- "inferring speaker names (step 2/3)" > /tmp/meetink-postproc.state
        infer_speaker_names "$out"
    fi

    # Point live.txt at the import so the app window shows it — but never
    # steal the symlink from an in-flight recording.
    if ! _is_running 2>/dev/null; then
        ln -sf "$out" "$MK_TRANSCRIPT" 2>/dev/null
    fi

    # Same post-processing a live meeting gets. Titling renames the file
    # and retargets live.txt; summary lands next to it. Capture the inode
    # first — the rename preserves it (see TRANSCRIPT_PATH below).
    # The status line keeps the app's import window narrating through the
    # LLM phase, which has no measurable progress.
    print -- "refine: status generating title and summary"
    # The state file too — post-transcription stages ran silently there
    # and Activity showed a stale 'pyannote 100%' for minutes (field
    # report: 'hanging at 100%' while the summary LLM worked).
    print -- "generating title and summary (step 3/3)" > /tmp/meetink-postproc.state
    local ino=$(stat -f %i "$out" 2>/dev/null)
    if typeset -f title_session_file >/dev/null 2>&1; then
        title_session_file "$out"
    fi

    rm -f /tmp/meetink-postproc.state /tmp/meetink-postproc.path
    # Machine-readable final location (titling may have renamed the file).
    # Tracked by INODE, not via live.txt: with two imports in flight the
    # symlink points wherever the later one left it — mv preserves the
    # inode, so this finds OUR file no matter what it was renamed to.
    local final="$out"
    if [[ -n "$ino" ]]; then
        local by_ino=$(find "$MK_TRANSCRIPTS_DIR" -maxdepth 2 -name '*.txt' -inum "$ino" 2>/dev/null | head -1)
        [[ -n "$by_ino" && -f "$by_ino" ]] && final="$by_ino"
    fi
    [[ -f "$final" ]] || final="$out"
    typeset -f mk_activity >/dev/null && mk_activity "import finished — ${${final:t}:r}"
    print -- "TRANSCRIPT_PATH: $final"
}
