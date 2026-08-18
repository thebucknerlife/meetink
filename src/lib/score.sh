# Perceptual audio-quality scoring (standalone assessment tool — no
# pipeline stage reads these scores). See src/tools/audio_score.py.

# meetink score <meeting-or-audio> [--compare <other>] [--window N] [--json out]
# <meeting-or-audio> accepts an .m4a/.wav path, a meeting .txt, or a
# meeting folder — the latter two resolve to the meeting's m4a.
cmd_audio_score() {
    local target="$1"
    if [[ -z "$target" ]]; then
        print -P "${C[red]}usage:${C[reset]} meetink score <meeting-or-audio> [--compare <other>] [--window N] [--json out]"
        return 1
    fi
    shift
    _score_resolve() {
        local p="$1"
        [[ -d "$p" ]] && p="$p/$(basename "$p").m4a"
        [[ "$p" == *.txt ]] && p="${p%.txt}.m4a"
        print -- "$p"
    }
    local audio=$(_score_resolve "$target")
    if [[ ! -f "$audio" ]]; then
        print -P "${C[red]}error:${C[reset]} no audio at $audio"
        return 1
    fi
    # Meeting targets bring their capture stems along automatically so
    # the completeness (content-loss) check always runs.
    local -a autosrc=()
    local sbase="${audio%.m4a}"
    [[ -f "$sbase.mic.wav" ]] && autosrc+=(--vs-source "$sbase.mic.wav")
    [[ -f "$sbase.sys.wav" ]] && autosrc+=(--vs-source "$sbase.sys.wav")
    # Rewrite --compare's argument through the same resolver.
    local -a rest=()
    while (( $# )); do
        if [[ "$1" == "--compare" && -n "$2" ]]; then
            rest+=(--compare "$(_score_resolve "$2")")
            shift 2
        else
            rest+=("$1")
            shift
        fi
    done
    "$MK_PARAKEET_VENV/bin/python" "$MK_ROOT/src/tools/audio_score.py" \
        "$audio" "${autosrc[@]}" "${rest[@]}"
}
