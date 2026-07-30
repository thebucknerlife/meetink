#!/bin/zsh
# Post-meeting speaker-name inference — map unresolved "Speaker N" labels to
# real names using the conversation itself. People address each other by name
# constantly ("thanks, Melanie", "this is Kate from finance"), so by /stop
# the transcript usually contains the evidence. Runs after cluster
# consolidation and before titling/summary, so those see named speakers.
#
# Deliberately conservative: the model must find explicit evidence (the
# person is addressed by name and responds, or introduces themselves). A
# wrong name is strictly worse than no name — the assignment also creates a
# voice profile, which would keep matching that voice under the wrong
# identity in every future meeting. Guards, in order:
#   - only clusters the diarize-server holds ≥ MIN_SAMPLES embeddings for
#     (a two-chunk noise cluster isn't worth naming, let alone enrolling)
#   - the model may answer null and is told null beats guessing
#   - names must appear verbatim in the transcript (hallucination guard)
#   - names must be plausible (alphabetic, short) and not the mic user
#
# Sourced by bin/meetink. Depends on: titling.sh (backend resolution),
# lmstudio.sh (_generate_lmstudio), diarize.sh (profile_assign,
# diarize_running), $MK_CONFIG_FILE from models.sh.

# Minimum embeddings a cluster must hold before we'll auto-name it.
MK_NAMES_MIN_SAMPLES="${MEETINK_INFER_NAMES_MIN_SAMPLES:-3}"

_names_enabled() {
    # Env wins; else config key infer_names; else on. Mirrors the
    # env → config → default precedence used everywhere else.
    case "$MEETINK_INFER_NAMES" in
        off|false|0) return 1 ;;
        on|true|1)   return 0 ;;
    esac
    local v=$(grep '^infer_names=' "$MK_CONFIG_FILE" 2>/dev/null | head -1 | cut -d= -f2-)
    [[ "$v" != "false" && "$v" != "off" && "$v" != "0" ]]
}

_names_system_prompt() {
    cat <<'EOF'
You identify meeting speakers from a transcript. Some lines are labeled "Speaker 1", "Speaker 2", etc. — voices whose names are unknown.

Determine each unknown speaker's real first name ONLY from explicit evidence inside the transcript:
- another participant addresses them by name and they respond in a way that fits
- they introduce themselves ("hi, this is Kate", "Kate here")
- a "# attendees:" header line unambiguously narrows who they must be

Rules:
- Output ONLY a JSON object mapping speaker numbers to names, e.g. {"1": "Kate", "2": null}
- Use null whenever you are not CERTAIN. A wrong name is far worse than null.
- Include exactly the speaker numbers you were asked about, no others.
- First names only, capitalized, as spelled in the transcript.
- No commentary, no markdown fences — just the JSON object.
EOF
}

# Generate the mapping via the active titling backend. Same dispatch shape
# as summary_save — one place per backend, no new transport code.
#   $1 = user prompt body. Prints raw model output.
_names_generate() {
    local body="$1"
    local backend=$(title_backend_active)
    case "$backend" in
        claude)
            command -v claude >/dev/null 2>&1 || return 1
            claude -p \
                --model "$(claude_model_active)" \
                --tools "" \
                --strict-mcp-config \
                "$(_names_system_prompt)

${body}" </dev/null 2>/dev/null
            ;;
        lmstudio)
            _lmstudio_available || return 1
            _generate_lmstudio "$(_names_system_prompt)" "$body" 200 0.1
            ;;
        *)
            local model_path=$(llm_path "$(local_llm_active_get)")
            [[ -f "$model_path/config.json" ]] || return 1
            "$MK_PY_VENV/bin/python" "$MK_ROOT/src/llm/mlx_helper.py" \
                --model "$model_path" \
                --system "$(_names_system_prompt)" \
                --prompt "$body" \
                --max-tokens 200 \
                --temp 0.1 \
                2>/dev/null
            ;;
    esac
}

# Public entry point, called from cmd_stop.
#   $1 = transcript path (symlink or file)
infer_speaker_names() {
    _names_enabled || return 0
    diarize_running || return 0   # assignment needs the sidecar anyway

    local file="$1" actual="$1"
    [[ -L "$file" ]] && actual=$(readlink "$file" 2>/dev/null)
    [[ -f "$actual" ]] || return 0

    # Speaker numbers actually present in the transcript…
    local present=$(sed -nE 's/^\[[0-9:]+\] Speaker ([0-9]+):.*/\1/p' "$actual" | sort -un)
    [[ -z "$present" ]] && return 0

    # …intersected with clusters the server holds enough evidence for.
    local clusters_json=$(curl -s -m 2 "http://127.0.0.1:$MK_DIARIZE_PORT/session/clusters" 2>/dev/null)
    [[ -z "$clusters_json" ]] && return 0
    local eligible=$(print -- "$clusters_json" | python3 -c '
import json, sys
try:
    for c in json.load(sys.stdin).get("clusters", []):
        if int(c.get("samples", 0)) >= int(sys.argv[1]):
            print(c["letter"])
except Exception:
    pass' "$MK_NAMES_MIN_SAMPLES" 2>/dev/null)
    [[ -z "$eligible" ]] && return 0

    local -a ask=()
    local n
    for n in ${(f)present}; do
        if print -- "$eligible" | grep -qx "$n"; then
            ask+=("$n")
        fi
    done
    (( ${#ask[@]} == 0 )) && return 0

    print -P "${C[dim]}Inferring speaker names ($(title_backend_active))...${C[reset]}"

    # Cap the transcript we send: name evidence clusters at the start
    # (greetings, intros) and end (goodbyes, action-item handoffs), so send
    # the head and tail when the middle would blow the budget.
    local body
    local size=$(wc -c < "$actual" | tr -d ' ')
    if (( size > 16000 )); then
        body="$(head -c 8000 "$actual")
[... middle of transcript omitted ...]
$(tail -c 8000 "$actual")"
    else
        body=$(cat "$actual")
    fi

    local raw=$(_names_generate "Unknown speakers: ${(j:, :)ask}

Transcript:
${body}")
    [[ -z "$raw" ]] && return 0

    # Parse + validate. Emits "num name" pairs that survive every guard;
    # validation lives in python (JSON + case-insensitive word search).
    local pairs=$(print -- "$raw" | python3 -c '
import json, re, sys
raw = sys.stdin.read()
me = sys.argv[1].strip().lower()
allowed = set(sys.argv[2].split(","))
path = sys.argv[3]
m = re.search(r"\{[^{}]*\}", raw, re.S)   # tolerate prose/fences around the JSON
if not m:
    sys.exit(0)
try:
    mapping = json.loads(m.group(0))
except Exception:
    sys.exit(0)
text = open(path, errors="replace").read().lower()
for num, name in mapping.items():
    num = str(num).strip()
    if num not in allowed or not isinstance(name, str):
        continue
    name = name.strip()
    if not re.fullmatch(r"[A-Za-z][A-Za-z\x27-]{1,23}", name):
        continue
    if name.lower() == me:
        continue
    # Hallucination guard: the name must exist in the transcript itself.
    if not re.search(r"\b" + re.escape(name.lower()) + r"\b", text):
        continue
    print(num, name.capitalize())' \
        "$(me_name_get 2>/dev/null)" "${(j:,:)ask}" "$actual" 2>/dev/null)
    [[ -z "$pairs" ]] && { print -P "  ${C[dim]}(no confident names found)${C[reset]}"; return 0 }

    local num name
    while read -r num name; do
        [[ -z "$num" || -z "$name" ]] && continue
        # profile_assign does the heavy lifting: enrolls the cluster as a
        # voice profile AND rewrites the transcript's Speaker-N lines.
        profile_assign "$num" "$name"
    done <<< "$pairs"
}
