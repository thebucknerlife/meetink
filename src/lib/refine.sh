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
    rm -f "$MK_SPOOL_DIR"/session-sys.raw "$MK_SPOOL_DIR"/session-mic.raw
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

    local mic="$MK_SPOOL_DIR/session-mic.raw"
    local sys="$MK_SPOOL_DIR/session-sys.raw"
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
        rm -f "$tmp" "$mic" "$sys"
        local n=$(grep -cE '^\[[0-9:]{8}\]' "$actual" 2>/dev/null)
        # NOTE: no nested ${${...}text:t} tricks here — that exact form is a
        # runtime "bad substitution" in zsh, and under set -e it killed
        # cmd_stop mid-pipeline (transcript replaced, but consolidation /
        # names / titling never ran — field-debugged from the launcher log).
        local raw_name="${actual%.txt}.live-raw.txt"
        print -P "${C[green]}✓${C[reset]} Refined: ${n} lines ${C[dim]}(raw kept: ${raw_name:t}; spool deleted)${C[reset]}"
    else
        rm -f "$tmp"
        print -P "${C[yellow]}⚠${C[reset]} Refine failed — keeping the live transcript ${C[dim]}(see /tmp/meetink-refine.log)${C[reset]}"
    fi
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
    local keep_audio=0 keep_spools=0
    mk_config_bool keep_audio && keep_audio=1
    mk_config_bool keep_spools && keep_spools=1
    (( keep_audio || keep_spools )) || return 0
    if ! command -v ffmpeg >/dev/null 2>&1; then
        print -P "${C[yellow]}⚠${C[reset]} keep audio: ffmpeg not found — skipping"
        return 0
    fi

    local actual="$1"
    [[ -L "$actual" ]] && actual=$(readlink "$actual" 2>/dev/null)
    [[ -f "$actual" ]] || return 0
    local mic="$MK_SPOOL_DIR/session-mic.raw"
    local sys="$MK_SPOOL_DIR/session-sys.raw"
    [[ -s "$mic" || -s "$sys" ]] || return 0

    local base="${actual%.txt}"
    local -a raw=(-f s16le -ar 16000 -ac 1)
    if (( keep_audio )); then
        local rc=0
        if [[ -s "$mic" && -s "$sys" ]]; then
            # Cross-ducked mix, not a plain sum. A naive amix reproduces the
            # echo the transcript pipeline suppresses: while the user talks,
            # sys carries their delayed remote echo (audible slap-back); while
            # others talk, headphone bleed into the mic comb-filters the sum
            # (the "tin can" hollowness). Ducking each stream by the other
            # keeps whoever is actually speaking clean.
            ffmpeg -v error -y "${raw[@]}" -i "$mic" "${raw[@]}" -i "$sys" \
                -filter_complex "[0:a]asplit=2[m1][m2];[1:a]asplit=2[s1][s2];[s1][m1]sidechaincompress=threshold=0.02:ratio=8:attack=10:release=400[sd];[m2][s2]sidechaincompress=threshold=0.02:ratio=8:attack=10:release=400[md];[md][sd]amix=inputs=2:duration=longest:normalize=0" \
                -c:a aac -b:a 96k "${base}.m4a" 2>>/tmp/meetink-refine.log || rc=$?
        else
            local only="$mic"
            [[ -s "$sys" ]] && only="$sys"
            ffmpeg -v error -y "${raw[@]}" -i "$only" \
                -c:a aac -b:a 96k "${base}.m4a" 2>>/tmp/meetink-refine.log || rc=$?
        fi
        if (( rc == 0 )); then
            print -P "${C[green]}✓${C[reset]} Audio kept: ${C[dim]}${base:t}.m4a${C[reset]}"
        else
            print -P "${C[yellow]}⚠${C[reset]} keep audio: mixdown failed ${C[dim]}(see /tmp/meetink-refine.log)${C[reset]}"
        fi
    fi
    if (( keep_spools )); then
        local kept=""
        if [[ -s "$mic" ]] && ffmpeg -v error -y "${raw[@]}" -i "$mic" "${base}.mic.wav" 2>>/tmp/meetink-refine.log; then
            kept="${base:t}.mic.wav"
        fi
        if [[ -s "$sys" ]] && ffmpeg -v error -y "${raw[@]}" -i "$sys" "${base}.sys.wav" 2>>/tmp/meetink-refine.log; then
            kept="${kept:+$kept / }${base:t}.sys.wav"
        fi
        [[ -n "$kept" ]] && print -P "${C[green]}✓${C[reset]} Spools kept: ${C[dim]}${kept}${C[reset]}"
    fi
    # When refine won't run (it normally deletes the spools itself), tidy
    # now so stale audio can't bleed into the next session.
    refine_enabled 2>/dev/null || rm -f "$mic" "$sys"
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
    local started=$(grep '^Started:' "$actual" 2>/dev/null | head -1 | sed 's/^Started: //')
    local me=$(me_name_get 2>/dev/null)
    local tmpdir=$(mktemp -d -t meetink-reproc)
    local -a args=(--out "$tmpdir/out.txt" --me "${me:-ME}" --header-from "$actual")
    [[ -n "$started" ]] && args+=(--started "$started")

    if [[ -s "$base.mic.wav" || -s "$base.sys.wav" ]]; then
        [[ -s "$base.mic.wav" ]] && { ffmpeg -v error -y -i "$base.mic.wav" -ar 16000 -ac 1 -f s16le "$tmpdir/mic.raw" && args+=(--mic "$tmpdir/mic.raw"); }
        [[ -s "$base.sys.wav" ]] && { ffmpeg -v error -y -i "$base.sys.wav" -ar 16000 -ac 1 -f s16le "$tmpdir/sys.raw" && args+=(--sys "$tmpdir/sys.raw"); }
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
    local rc=0
    "$MK_PARAKEET_VENV/bin/python" "$MK_ROOT/src/refine/refine.py" "${args[@]}" 2>/tmp/meetink-refine.log || rc=$?
    _refine_unlock
    if (( rc == 0 )) && grep -qE '^\[' "$tmpdir/out.txt"; then
        cp "$actual" "${base}.pre-reprocess.txt" 2>/dev/null
        cat "$tmpdir/out.txt" > "$actual"
        [[ -f "$tmpdir/out.txt.timing.json" ]] && mv "$tmpdir/out.txt.timing.json" "${base}.timing.json"
        local n=$(grep -cE '^\[[0-9:]{8}\]' "$actual")
        print -P "${C[green]}✓${C[reset]} Reprocessed: ${n} lines ${C[dim]}(previous kept: ${base:t}.pre-reprocess.txt)${C[reset]}"
    else
        print -P "${C[red]}error:${C[reset]} reprocess failed ${C[dim]}(see /tmp/meetink-refine.log)${C[reset]}"
    fi
    rm -rf "$tmpdir"
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

    print -P "${C[bright_yellow]}▸${C[reset]} Transcribing ${C[bold]}${input:t}${C[reset]} ${C[dim]}(parakeet)...${C[reset]}"
    _refine_lock
    local rc=0
    "$MK_PARAKEET_VENV/bin/python" "$MK_ROOT/src/refine/refine.py" \
            --input "$input" --out "$out" 2>/tmp/meetink-refine.log || rc=$?
    _refine_unlock
    if (( rc != 0 )); then
        print -P "${C[red]}error:${C[reset]} transcription failed ${C[dim]}(see /tmp/meetink-refine.log)${C[reset]}"
        return 1
    fi
    local n=$(grep -cE '^\[[0-9:]{8}\]' "$out" 2>/dev/null)
    [[ -f "$out.timing.json" ]] && mv "$out.timing.json" "${out%.txt}.timing.json"
    print -P "${C[green]}✓${C[reset]} Transcribed: ${C[bright_cyan]}${out/$HOME/~}${C[reset]} ${C[dim]}(${n} lines)${C[reset]}"

    # Settings: keep audio → the source file moves in next to the transcript
    # (a copy — the user's original stays where it was).
    local ext="${input:e}"
    if mk_config_bool keep_audio && [[ -n "$ext" ]]; then
        cp "$input" "$sess_dir/$sess.$ext" 2>/dev/null || true
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
    local ino=$(stat -f %i "$out" 2>/dev/null)
    if typeset -f title_session_file >/dev/null 2>&1; then
        title_session_file "$out"
    fi

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
    print -- "TRANSCRIPT_PATH: $final"
}
