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
    # `|| rc=$?`: the launcher runs with set -e — a bare failing command
    # would kill the whole script before the error branch runs.
    local rc=0
    "$MK_PARAKEET_VENV/bin/python" "$MK_ROOT/src/refine/refine.py" "${args[@]}" 2>/tmp/meetink-refine.log || rc=$?
    _refine_unlock
    if (( rc == 0 )); then
        # Keep the raw live version for comparison/debugging, then replace
        # the transcript's content in place (truncate-and-write keeps the
        # inode, so the app window and any tail keep streaming — same
        # rationale as _rewrite_transcript_label).
        cp "$actual" "${actual%.txt}.live-raw.txt" 2>/dev/null
        cat "$tmp" > "$actual"
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
    local out="$MK_TRANSCRIPTS_DIR/$(date +%Y-%m-%d_%H-%M)_import-${base}.txt"
    mkdir -p "$MK_TRANSCRIPTS_DIR"

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
    print -P "${C[green]}✓${C[reset]} Transcribed: ${C[bright_cyan]}${out/$HOME/~}${C[reset]} ${C[dim]}(${n} lines)${C[reset]}"

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
        local by_ino=$(find "$MK_TRANSCRIPTS_DIR" -maxdepth 1 -name '*.txt' -inum "$ino" 2>/dev/null | head -1)
        [[ -n "$by_ino" && -f "$by_ino" ]] && final="$by_ino"
    fi
    [[ -f "$final" ]] || final="$out"
    print -- "TRANSCRIPT_PATH: $final"
}
