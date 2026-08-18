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

# ---------------------------------------------------------------------------
# Post-processing run registry. Concurrent runs are real (meeting B ends
# while meeting A still renders — field case: a 13 s orphan's pipeline raced
# a 32-minute meeting's and the app pinned "processing" on the wrong row).
# Each run owns /tmp/meetink-postproc.d/<session-id>/{pid,state,path}; the
# legacy /tmp/meetink-postproc.{pid,state,path} singleton stays mirrored to
# a live run at claim/handoff so old readers and the multi-agent deploy gate
# ("postproc.pid absent or dead" = no postproc) keep working.
typeset -g MK_PP_DIR="" \
          MK_PP_STATE=/tmp/meetink-postproc.state \
          MK_PP_PATH=/tmp/meetink-postproc.path

pp_claim() {   # $1 = transcript path this run is processing
    local id="${${1:t}:r}"
    MK_PP_DIR="/tmp/meetink-postproc.d/$id"
    MK_PP_STATE="$MK_PP_DIR/state"
    MK_PP_PATH="$MK_PP_DIR/path"
    mkdir -p "$MK_PP_DIR" 2>/dev/null
    print -- $$   > "$MK_PP_DIR/pid"
    print -- "$1" > "$MK_PP_PATH"
    print -- $$   > /tmp/meetink-postproc.pid
    print -- "$1" > /tmp/meetink-postproc.path
}

pp_state() {   # $1 = narration line for the app's status surfaces
    print -- "$1" > "$MK_PP_STATE" 2>/dev/null
    # Mirror into the legacy slot while we own it (or its owner died).
    local lp=$(cat /tmp/meetink-postproc.pid 2>/dev/null)
    if [[ -z "$lp" || "$lp" == "$$" ]] || ! kill -0 "$lp" 2>/dev/null; then
        print -- $$ > /tmp/meetink-postproc.pid 2>/dev/null
        [[ -f "$MK_PP_PATH" ]] && \
            cat "$MK_PP_PATH" > /tmp/meetink-postproc.path 2>/dev/null
        print -- "$1" > /tmp/meetink-postproc.state 2>/dev/null
    fi
    return 0
}

pp_path_set() {   # $1 = retargeted transcript path (rename followed)
    print -- "$1" > "$MK_PP_PATH" 2>/dev/null
    [[ "$(cat /tmp/meetink-postproc.pid 2>/dev/null)" == "$$" ]] && \
        print -- "$1" > /tmp/meetink-postproc.path 2>/dev/null
    return 0
}

pp_done() {   # release this run; hand the legacy slot to a survivor
    [[ -n "$MK_PP_DIR" ]] && rm -rf "$MK_PP_DIR"
    MK_PP_DIR=""
    MK_PP_STATE=/tmp/meetink-postproc.state
    MK_PP_PATH=/tmp/meetink-postproc.path
    local d p live=""
    for d in /tmp/meetink-postproc.d/*(N/om); do
        p=$(cat "$d/pid" 2>/dev/null)
        if [[ -n "$p" ]] && kill -0 "$p" 2>/dev/null; then
            [[ -z "$live" ]] && live="$d"
        else
            rm -rf "$d"   # dead leftover from a killed run
        fi
    done
    if [[ -n "$live" ]]; then
        cat "$live/pid"   > /tmp/meetink-postproc.pid   2>/dev/null
        cat "$live/path"  > /tmp/meetink-postproc.path  2>/dev/null
        cat "$live/state" > /tmp/meetink-postproc.state 2>/dev/null
    else
        rm -f /tmp/meetink-postproc.pid /tmp/meetink-postproc.path \
              /tmp/meetink-postproc.state
        rmdir /tmp/meetink-postproc.d 2>/dev/null
    fi
    return 0
}


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
          "$MK_SPOOL_DIR"/session-sys.48k.raw "$MK_SPOOL_DIR"/session-mic.48k.raw \
          "$MK_SPOOL_DIR"/route.jsonl "$MK_SPOOL_DIR"/health.jsonl
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
    if [[ -n "$MK_PP_DIR" ]]; then pp_path_set "$actual"; else pp_claim "$actual"; fi
    # Stream progress into the postproc state file so the app's status bar
    # can narrate ("post-processing… identifying speakers 43% (step 2/3)").
    # rc comes from pipestatus[1] — the pipeline's last command is the
    # reader loop, which always succeeds.
    local state="$MK_PP_STATE"
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
            [[ -f "$MK_PP_PATH" ]] || print -- "$actual" > "$MK_PP_PATH" 2>/dev/null
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
with open(meta + ".tmp", "w") as f:
    json.dump(d, f, sort_keys=True)
os.replace(meta + ".tmp", meta)
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

# Conservative denoise on the MIC stream only (AC hum, birds, distant
# traffic — stationary ambience is DFN's sweet spot). Attenuation is
# capped so voices stay natural (the "tinny" scars); sys is NEVER
# touched. denoise=off in config disables. Prints the path to use.
_denoise_mic() { _denoise_stream "$1" "$2" "$3" 12 mic }

# DFN a raw stream. $4 = attenuation cap dB (mic keeps the conservative
# 12; contaminated sys runs 100 = full — the Krisp-parity lever the
# user validated by ear), $5 = label for progress lines.
_denoise_stream() {
    local in="$1" rate="$2" td="$3" atten="${4:-12}" what="${5:-mic}"
    local dfn="$MK_HOME/enhance-venv/bin/deepFilter"
    local v=$(grep '^denoise=' "$MK_CONFIG_FILE" 2>/dev/null | head -1 | cut -d= -f2-)
    if [[ "$v" == "off" || "$v" == "false" || ! -x "$dfn" || ! -s "$in" ]]; then
        print -- "$in"; return 0
    fi
    print -- "mixing audio — denoising ${what} ~0% (step 3/3)" \
        > "$MK_PP_STATE" 2>/dev/null
    local drc=1
    if ffmpeg -v error -y -f s16le -ar $rate -ac 1 -i "$in" "$td/dn-in-$what.wav" 2>>/tmp/meetink-refine.log; then
        # DFN prints nothing until it finishes, but its realtime factor
        # is stable (~0.04 on this hardware) — an elapsed/expected
        # estimate is honest enough to prove it hasn't hung. Capped at
        # ~95% so it never claims done early.
        local audio_s=$(( $(stat -f%z "$in" 2>/dev/null || echo 0) / (2 * rate) ))
        local expect=$(( audio_s / 18 ))
        (( expect < 6 )) && expect=6
        "$dfn" "$td/dn-in-$what.wav" -o "$td" --atten-lim $atten >>/tmp/meetink-refine.log 2>&1 &
        local dpid=$! dt0=$SECONDS dpct=0
        while kill -0 $dpid 2>/dev/null; do
            sleep 2
            dpct=$(( (SECONDS - dt0) * 100 / expect ))
            (( dpct > 95 )) && dpct=95
            print -- "mixing audio — denoising ${what} ~${dpct}% (step 3/3)" \
                > "$MK_PP_STATE" 2>/dev/null
        done
        wait $dpid 2>/dev/null; drc=$?
    fi
    if (( drc == 0 )) && [[ -f "$td/dn-in-${what}_DeepFilterNet3.wav" ]] \
        && ffmpeg -v error -y -i "$td/dn-in-${what}_DeepFilterNet3.wav" -f s16le -ar $rate -ac 1 \
               "$td/dn-$what.raw" 2>>/tmp/meetink-refine.log; then
        print -- "$td/dn-$what.raw"
    else
        print -- "$in"   # denoise is best-effort, never blocks the mix
    fi
}

# Run playback_mix.py with its stderr streamed into the refine log AND
# the postproc state file ("playback-mix: progress N label" lines become
# "mixing audio — label N%"), so the app's status row moves during the
# render instead of sitting on one string for minutes.
_pmix_run() {
    "$MK_PARAKEET_VENV/bin/python" "$MK_ROOT/src/refine/playback_mix.py" "$@" \
        2>&1 >/dev/null | while IFS= read -r line; do
        print -r -- "$line" >> /tmp/meetink-refine.log
        case "$line" in
            ("playback-mix: progress "*)
                local -a w=(${=line})
                print -- "mixing audio — ${w[4]:-rendering} ${w[3]}% (step 3/3)" \
                    > "$MK_PP_STATE" 2>/dev/null ;;
        esac
    done
    return ${pipestatus[1]}
}

# Mix two raw spools into a listenable m4a using directional path evidence
# and static render recipes. Transcript labels never control amplitude.
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
    # Unified renderer: per-window speakers/headphones detection with
    # crossfades — the user takes headphones on and off mid-call, and a
    # whole-meeting mode choice mistreats one half. Uniform meetings
    # render identically to the previous single-mode paths (speakers →
    # mic-only, headphones → level-matched guarded sum). The mic gets a
    # capped conservative denoise first (AC/birds/traffic; sys never
    # touched). mix_mode=mic|split forces a single mode; =neural routes
    # to the DTLN experiment below.
    local mix_mode=$(grep '^mix_mode=' "$MK_CONFIG_FILE" 2>/dev/null | head -1 | cut -d= -f2-)
    if [[ -x "$MK_PARAKEET_VENV/bin/python" && -s "$mic" \
          && "$mix_mode" != "neural" ]]; then
        local pmic="$mic" psys="$sys" par=16000
        (( have48 )) && { pmic="$mic48"; psys="$sys48"; par=48000; }
        local pd=$(mktemp -d -t meetink-pmix)
        # ANALYSIS streams must be RAW: the 16 kHz transcription spools
        # carry the live-AEC3-cleaned mic, so the speaker bleed the mode
        # detector / echo gate / DTLN reference math need to see has
        # already been removed from them (field case: a speakers meeting
        # detected 0/61 windows on the cleaned spools and 61/61 on the
        # raw archive — the sum ran and layered bleed reverb under sys).
        local amic="$mic" asys="$sys"
        if (( have48 )); then
            if ffmpeg -v error -y -f s16le -ar 48000 -ac 1 -i "$mic48" \
                    -ar 16000 -f s16le "$pd/analysis-mic.raw" 2>>/tmp/meetink-refine.log \
               && ffmpeg -v error -y -f s16le -ar 48000 -ac 1 -i "$sys48" \
                    -ar 16000 -f s16le "$pd/analysis-sys.raw" 2>>/tmp/meetink-refine.log; then
                amic="$pd/analysis-mic.raw"
                asys="$pd/analysis-sys.raw"
            fi
        fi
        local dmic=$(_denoise_mic "$pmic" $par "$pd")
        # Returned-self contamination (a participant echoing the meeting
        # back): the sys stream then carries the user's echo AND the
        # others under someone's bad audio path. The mixer handles the
        # user side (selection); the others' side gets DFN at FULL
        # attenuation — the Krisp-parity lever the user validated by ear
        # ("cleaned was definitely the best"). Clean meetings keep the
        # faithful untouched sys.
        local psys_render="$psys"
        local sys_processor=raw
        # Probe only under an UNAMBIGUOUS headphones route — the
        # energy-domain detector is invalid where speaker bleed exists
        # (field false-positive: a clean speakers 1:1 measured 2.1).
        local rjson_pre="${mic:h}/route.jsonl"
        [[ -s "$rjson_pre" ]] || rjson_pre="${out%.m4a}.route.jsonl"
        local contam=""
        if [[ -s "$rjson_pre" ]] \
           && grep -q '"kind": "headphones"' "$rjson_pre" \
           && ! grep -qE '"kind": "(speakers|unknown)"' "$rjson_pre"; then
            contam=$("$MK_PARAKEET_VENV/bin/python" \
                "$MK_ROOT/src/refine/playback_mix.py" \
                --mic16 "$amic" --sys16 "$asys" --mic /dev/null --sys /dev/null \
                --out /dev/null --probe-contamination 2>/dev/null)
        fi
        if print -- "$contam" | grep -q '"contaminated": true'; then
            print -r -- "playback-mix: contamination probe: $contam" \
                >> /tmp/meetink-refine.log
            local dsys=$(_denoise_stream "$psys" $par "$pd" 100 sys)
            if [[ "$dsys" != "$psys" ]]; then
                psys_render="$dsys"
                sys_processor=deepfilternet3-full
            fi
        fi
        local -a fm=()
        local mic_processor=raw
        [[ "$dmic" != "$pmic" ]] && mic_processor=deepfilternet3-capped-12db
        fm+=(--mic-processor "$mic_processor")
        fm+=(--sys-processor "$sys_processor")
        [[ "$mix_mode" == "mic" || "$mix_mode" == "split" ]] && \
            fm+=(--force-mode "$mix_mode")
        # A complete one-kind physical route journal is authoritative; mixed
        # or unknown routes fall back to directional acoustic windows. Health
        # events are retained in the decision manifest either way.
        local rjson="${mic:h}/route.jsonl"
        [[ -s "$rjson" ]] || rjson="${out%.m4a}.route.jsonl"
        [[ -s "$rjson" ]] && fm+=(--route "$rjson")
        local hjson="${mic:h}/health.jsonl"
        [[ -s "$hjson" ]] || hjson="${out%.m4a}.health.jsonl"
        [[ -s "$hjson" ]] && fm+=(--health "$hjson")
        # Codec processing can decorrelate returned self enough that waveform
        # direction is inconclusive. User timing nominates candidate spans;
        # playback_mix still requires a live direct-mic copy before ducking.
        if [[ -s "$timing" ]]; then
            local duck_me=$(me_name_get 2>/dev/null)
            fm+=(--duck-timing "$timing" --duck-label "${duck_me:-ME}")
        fi
        fm+=(--decision-out "${out%.m4a}.audio.json")
        _pmix_run --mic16 "$amic" --sys16 "$asys" \
                --mic "$dmic" --sys "$psys_render" --rate $par \
                "${fm[@]}" \
                --out "$pd/mixed.raw"
        local pmrc=$?
        if (( pmrc == 0 )); then
            local prc=0
            ffmpeg -v error -y -f s16le -ar $par -ac 1 -i "$pd/mixed.raw" \
                -c:a aac -b:a 96k "$out" 2>>/tmp/meetink-refine.log || prc=$?
            rm -rf "$pd"
            print -- "$(date '+%Y-%m-%d %H:%M:%S')  kind=mix name=${${out:t}:r} total_s=$((SECONDS - _mix_t0)) mode=playback" \
                >> "$MK_HOME/perf.log" 2>/dev/null || true
            return $prc
        fi
        # rc 3 = weak-speakers: an acoustic path exists but the bleed is
        # too quiet for mic-only and too audible for a plain sum. Render
        # pristine sys + the DTLN-separated mic instead (weak bleed =
        # negligible neural residual). Needs the dtln venv; without it,
        # mic-only is the safer of the two bad options.
        if (( pmrc == 3 )); then
            local dtln_py="$MK_HOME/dtln-venv/bin/python"
            if [[ -x "$dtln_py" && -f "$MK_HOME/dtln/dtln_aec_512_1.tflite" ]] \
                && "$dtln_py" "$MK_ROOT/src/refine/neural_mix.py" \
                    --mode cleanmix \
                    --mic16 "$amic" --sys16 "$asys" \
                    --mic "$dmic" --sys "$psys" --rate $par \
                    --progress-state "$MK_PP_STATE" \
                    --out "$pd/mixed.raw" 2>>/tmp/meetink-refine.log; then
                local crc=0
                ffmpeg -v error -y -f s16le -ar $par -ac 1 -i "$pd/mixed.raw" \
                    -c:a aac -b:a 96k "$out" 2>>/tmp/meetink-refine.log || crc=$?
                rm -rf "$pd"
                print -- "$(date '+%Y-%m-%d %H:%M:%S')  kind=mix name=${${out:t}:r} total_s=$((SECONDS - _mix_t0)) mode=cleanmix" \
                    >> "$MK_HOME/perf.log" 2>/dev/null || true
                return $crc
            fi
            if _pmix_run --mic16 "$amic" --sys16 "$asys" \
                    --mic "$dmic" --sys "$psys" --rate $par \
                    --force-mode mic \
                    --out "$pd/mixed.raw"; then
                local mrc2=0
                ffmpeg -v error -y -f s16le -ar $par -ac 1 -i "$pd/mixed.raw" \
                    -c:a aac -b:a 96k "$out" 2>>/tmp/meetink-refine.log || mrc2=$?
                rm -rf "$pd"
                print -- "$(date '+%Y-%m-%d %H:%M:%S')  kind=mix name=${${out:t}:r} total_s=$((SECONDS - _mix_t0)) mode=mic-weak" \
                    >> "$MK_HOME/perf.log" 2>/dev/null || true
                return $mrc2
            fi
        fi
        rm -rf "$pd"
        print -P "${C[dim]}  (playback mix bailed — fallback)${C[reset]}"
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
                --progress-state "$MK_PP_STATE" \
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
                --progress-state "$MK_PP_STATE" \
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
    # Concurrent runs each own a dir — kill every run's shell (checking
    # the pid still belongs to a meetink process; pids get recycled),
    # then the worker processes by pattern (those can't be run-scoped).
    local d p
    _pp_kill_if_ours() {
        [[ -n "$1" ]] || return 0
        ps -p "$1" -o command= 2>/dev/null | grep -q meetink && \
            kill -9 "$1" 2>/dev/null
        return 0
    }
    for d in /tmp/meetink-postproc.d/*(N/); do
        _pp_kill_if_ours "$(cat "$d/pid" 2>/dev/null)"
    done
    _pp_kill_if_ours "$(cat /tmp/meetink-postproc.pid 2>/dev/null)"
    pkill -9 -f "src/refine/refine.py" 2>/dev/null || true
    pkill -9 -f "src/refine/enhance.py" 2>/dev/null || true
    pkill -9 -f "src/refine/pyannote_diar.py" 2>/dev/null || true
    pkill -9 -f "enhance-venv/bin/deepFilter" 2>/dev/null || true
    rm -rf /tmp/meetink-refine.lock /tmp/meetink-postproc.d
    rm -f /tmp/meetink-postproc.state /tmp/meetink-postproc.path \
          /tmp/meetink-postproc.pid
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
        print -- "enhancing audio — DeepFilterNet (step 3/3)" > "$MK_PP_STATE"
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
        rm -f "$mic" "$sys" "${mic%.raw}.48k.raw" "${sys%.raw}.48k.raw" \
              "${mic:h}/route.jsonl" "${mic:h}/health.jsonl"
        return 0
    fi

    local base="${actual%.txt}"
    # Keep the output-route journal beside the stems: reprocess re-runs
    # the playback mix from the wavs and wants the same route prior.
    # Titling renames <base>.* siblings in lockstep, so it travels.
    [[ -s "${mic:h}/route.jsonl" ]] && \
        cp "${mic:h}/route.jsonl" "${base}.route.jsonl" 2>/dev/null || true
    [[ -s "${mic:h}/health.jsonl" ]] && \
        cp "${mic:h}/health.jsonl" "${base}.health.jsonl" 2>/dev/null || true
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
    rm -f "$mic" "$sys" "${mic%.raw}.48k.raw" "${sys%.raw}.48k.raw" \
          "${mic:h}/route.jsonl" "${mic:h}/health.jsonl"
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

    # Stranded session spools: a stop pipeline that died mid-flight (app
    # or watch restart SIGPIPEs its children — the Eddie incident) leaves
    # raw session PCM next to the transcript with no kept wavs. Materialize
    # the wavs the pipeline would have produced, then proceed exactly like
    # any kept-audio meeting. 48 kHz spool preferred (full bandwidth).
    local sdir="${actual:h}"
    if [[ ! -s "$base.mic.wav" && ! -s "$base.sys.wav" && ! -s "$base.m4a" ]]; then
        local st
        for st in mic sys; do
            local r48="$sdir/session-$st.48k.raw" r16="$sdir/session-$st.raw"
            if [[ -s "$r48" ]]; then
                ffmpeg -v error -y -f s16le -ar 48000 -ac 1 -i "$r48" \
                    "$base.$st.wav" 2>>/tmp/meetink-refine.log || true
            elif [[ -s "$r16" ]]; then
                ffmpeg -v error -y -f s16le -ar 16000 -ac 1 -i "$r16" \
                    "$base.$st.wav" 2>>/tmp/meetink-refine.log || true
            fi
        done
        if [[ -s "$base.mic.wav" || -s "$base.sys.wav" ]]; then
            print -P "${C[green]}✓${C[reset]} Recovered stranded session audio ${C[dim]}(a previous post-process died mid-flight)${C[reset]}"
            [[ -s "$sdir/route.jsonl" && ! -s "$base.route.jsonl" ]] && \
                cp "$sdir/route.jsonl" "$base.route.jsonl" 2>/dev/null
            [[ -s "$sdir/health.jsonl" && ! -s "$base.health.jsonl" ]] && \
                cp "$sdir/health.jsonl" "$base.health.jsonl" 2>/dev/null
            # Each raw is deleted only once its lossless wav exists.
            [[ -s "$base.mic.wav" ]] && rm -f "$sdir/session-mic.raw" "$sdir/session-mic.48k.raw"
            [[ -s "$base.sys.wav" ]] && rm -f "$sdir/session-sys.raw" "$sdir/session-sys.48k.raw"
            rm -f "$sdir/route.jsonl" "$sdir/health.jsonl"
        fi
    fi

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
    if [[ -n "$MK_PP_DIR" ]]; then pp_path_set "$actual"; else pp_claim "$actual"; fi
    local state="$MK_PP_STATE"
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
            [[ -f "$MK_PP_PATH" ]] || print -- "$actual" > "$MK_PP_PATH" 2>/dev/null
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
            print -- "enhancing audio (step 3/3)" > "$MK_PP_STATE"
            _mix_enhanced_m4a "$tmpdir/mic.raw" "$tmpdir/sys.raw" "${base}.m4a" && \
                print -P "${C[green]}✓${C[reset]} Audio rebuilt: ${C[dim]}${base:t}.m4a (enhanced)${C[reset]}"
        fi
        # Parity with the stop pipeline's tail: title (meta wins, no LLM
        # guess when one exists) and a summary regenerated from the NEW
        # transcript. A recovered meeting (stranded spools) gets its
        # summary here — the original pipeline died before this step.
        print -- "generating title and summary (step 3/3)" > "$MK_PP_STATE"
        if typeset -f infer_event_link >/dev/null 2>&1; then
            infer_event_link "$actual"
        fi
        if typeset -f title_session_file >/dev/null 2>&1; then
            title_session_file "$actual"
        fi
    else
        rm -rf "$tmpdir"
        pp_done
        print -P "${C[red]}error:${C[reset]} reprocess failed ${C[dim]}(see /tmp/meetink-refine.log)${C[reset]}"
        return 1
    fi
    rm -rf "$tmpdir"
    pp_done
    typeset -f mk_notify >/dev/null 2>&1 && \
        mk_notify "Reprocess done" "${${actual:t}:r}"
}

# Split a recorded meeting into two at a time offset (seconds from the
# session start — the app passes the playhead). Everything after the cut
# becomes a new meeting; the event link stays with the original.
#   $1 = transcript path, $2 = seconds
cmd_split() {
    local file="$1" secs="$2" actual
    actual="$file"
    [[ -L "$file" ]] && actual=$(readlink "$file" 2>/dev/null)
    if [[ ! -f "$actual" || -z "$secs" ]]; then
        print -P "${C[red]}usage:${C[reset]} meetink split <transcript.txt> <seconds>"
        return 1
    fi
    local py="$MK_PY_VENV/bin/python"
    [[ -x "$py" ]] || py=python3
    local out
    out=$("$py" "$MK_ROOT/src/refine/split_meeting.py" "$actual" "$secs") || {
        print -P "${C[red]}error:${C[reset]} split failed"
        return 1
    }
    local new_txt="${out##*$'\n'}"
    print -P "${C[green]}✓${C[reset]} Split at ${secs}s → ${C[bright_cyan]}${new_txt:h:t}${C[reset]}"
    typeset -f mk_activity >/dev/null 2>&1 && {
        mk_activity "split — ${${actual:t}:r} at ${secs%%.*}s"
        mk_activity "created by split — ${${new_txt:t}:r}"
    }
    print -- "$new_txt"
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
    if [[ -n "$MK_PP_DIR" ]]; then pp_path_set "$actual"; else pp_claim "$actual"; fi
    local state="$MK_PP_STATE"
    print -- "relabeling speakers (fast)" > "$state"
    local rc=0
    # Stream refine.py's stdout through the state file — the embedding
    # loop emits "refine: progress diarize N" every ~4%, which is the
    # bulk of a relabel's wall time (field ask: relabel needs a % too).
    "$MK_PARAKEET_VENV/bin/python" "$MK_ROOT/src/refine/refine.py" \
        --relabel "$actual" --me "${me:-ME}" --out "$tmp" \
        2>>/tmp/meetink-refine.log | while IFS= read -r line; do
            case "$line" in
                "refine: progress diarize "*)
                    print -- "relabeling speakers ${line##* }%" > "$state" 2>/dev/null ;;
                "refine: status "*)
                    print -- "relabeling — ${line#refine: status }" > "$state" 2>/dev/null ;;
            esac
        done
    rc=${pipestatus[1]}
    _refine_unlock
    if (( rc == 0 )) && grep -qE '^\[' "$tmp"; then
        cat "$tmp" > "$actual"
        print -P "${C[green]}✓${C[reset]} Speakers relabeled ${C[dim]}(see /tmp/meetink-refine.log for the change count)${C[reset]}"
        typeset -f mk_activity >/dev/null && mk_activity "relabeled — ${${actual:t}:r}"
    else
        print -P "${C[red]}error:${C[reset]} relabel failed ${C[dim]}(see /tmp/meetink-refine.log — full reprocess is the fallback)${C[reset]}"
    fi
    rm -f "$tmp"
    pp_done
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
    if [[ -n "$MK_PP_DIR" ]]; then pp_path_set "$out"; else pp_claim "$out"; fi
    local state="$MK_PP_STATE"
    print -- "starting (step 1/3)" > "$state"
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
            [[ -f "$MK_PP_PATH" ]] || print -- "$actual" > "$MK_PP_PATH" 2>/dev/null
        done
    rc=${pipestatus[1]}
    _refine_unlock
    if (( rc != 0 )); then
        rm -rf "$sess_dir"   # no ghost meeting from a failed import
        pp_done
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
        print -- "inferring speaker names (step 2/3)" > "$MK_PP_STATE"
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
    print -- "generating title and summary (step 3/3)" > "$MK_PP_STATE"
    local ino=$(stat -f %i "$out" 2>/dev/null)
    if typeset -f title_session_file >/dev/null 2>&1; then
        title_session_file "$out"
    fi

    pp_done
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
