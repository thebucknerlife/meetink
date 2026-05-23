#!/bin/zsh
# LM Studio backend helpers. The `lmstudio` backend talks to LM Studio's
# OpenAI-compatible local server (default http://127.0.0.1:1234) via
# src/llm/server_helper.py. Discovery uses LM Studio's /api/v0/models so we
# can show which models are downloaded/loaded and their context length.
#
# Sourced by bin/meetink AFTER titling.sh (shares $MK_CONFIG_FILE from
# models.sh and the C[] colour table from ui.sh).
# Depends on: $MK_CONFIG_FILE, $MK_PY_VENV, $MK_ROOT, C[].

MK_LMSTUDIO_DEFAULT_URL="http://127.0.0.1:1234"

# Python that can run server_helper.py. Prefer the REPL venv (always present
# after setup), fall back to system python3 — server_helper is stdlib-only.
_lmstudio_python() {
    if [[ -x "$MK_PY_VENV/bin/python" ]]; then
        print -n -- "$MK_PY_VENV/bin/python"
    else
        print -n -- "python3"
    fi
}

# Active endpoint: env > config > default.
lmstudio_endpoint() {
    if [[ -n "$MEETINK_LMSTUDIO_URL" ]]; then
        print -n -- "$MEETINK_LMSTUDIO_URL"; return
    fi
    if [[ -f "$MK_CONFIG_FILE" ]]; then
        local v=$(grep '^lmstudio_endpoint=' "$MK_CONFIG_FILE" 2>/dev/null | head -1 | cut -d= -f2-)
        [[ -n "$v" ]] && { print -n -- "$v"; return; }
    fi
    print -n -- "$MK_LMSTUDIO_DEFAULT_URL"
}

# Raw configured model id (may be empty): env > config.
lmstudio_model_get() {
    if [[ -n "$MEETINK_LMSTUDIO_MODEL" ]]; then
        print -n -- "$MEETINK_LMSTUDIO_MODEL"; return
    fi
    if [[ -f "$MK_CONFIG_FILE" ]]; then
        grep '^lmstudio_model=' "$MK_CONFIG_FILE" 2>/dev/null | head -1 | cut -d= -f2-
    fi
}

# Discover models as TSV rows: id<TAB>state<TAB>quant<TAB>max_ctx<TAB>loaded_ctx
_lmstudio_discover() {
    "$(_lmstudio_python)" "$MK_ROOT/src/llm/server_helper.py" \
        --list --endpoint "$(lmstudio_endpoint)" 2>/dev/null
}

# Resolve the model id to actually use: configured value, else the model the
# server reports as `loaded`, else the first discovered model. Empty if none.
lmstudio_model_resolve() {
    local m=$(lmstudio_model_get)
    [[ -n "$m" ]] && { print -n -- "$m"; return; }
    local rows=$(_lmstudio_discover)
    [[ -z "$rows" ]] && return 1
    # Prefer a loaded model.
    local loaded=$(print -- "$rows" | awk -F'\t' '$2=="loaded"{print $1; exit}')
    [[ -n "$loaded" ]] && { print -n -- "$loaded"; return; }
    print -- "$rows" | awk -F'\t' 'NR==1{print $1; exit}'
}

# Upsert a key=value line in the config file.
_lmstudio_cfg_put() {
    local key="$1" val="$2"
    if [[ -f "$MK_CONFIG_FILE" ]] && grep -q "^${key}=" "$MK_CONFIG_FILE"; then
        sed -i '' "s|^${key}=.*|${key}=${val}|" "$MK_CONFIG_FILE"
    else
        echo "${key}=${val}" >> "$MK_CONFIG_FILE"
    fi
}

# Set the active LM Studio model (validated against discovery). Persists both
# lmstudio_model= and lmstudio_ctx= (loaded_ctx if >0 else max_ctx).
lmstudio_model_set() {
    local id="$1"
    local rows=$(_lmstudio_discover)
    if [[ -z "$rows" ]]; then
        print -P "${C[red]}error:${C[reset]} LM Studio not reachable at ${C[bold]}$(lmstudio_endpoint)${C[reset]}"
        return 1
    fi
    local line=$(print -- "$rows" | awk -F'\t' -v id="$id" '$1==id{print; exit}')
    if [[ -z "$line" ]]; then
        print -P "${C[red]}error:${C[reset]} model ${C[bold]}$id${C[reset]} not found in LM Studio"
        print -P "  Run ${C[bright_cyan]}/llm list${C[reset]} to see available models."
        return 1
    fi
    local max_ctx=$(print -- "$line" | cut -f4)
    local loaded_ctx=$(print -- "$line" | cut -f5)
    local ctx="$max_ctx"
    [[ -n "$loaded_ctx" && "$loaded_ctx" != "0" ]] && ctx="$loaded_ctx"
    [[ -z "$ctx" || "$ctx" == "0" ]] && ctx="8192"

    mkdir -p "${MK_CONFIG_FILE:h}"
    _lmstudio_cfg_put "lmstudio_model" "$id"
    _lmstudio_cfg_put "lmstudio_ctx" "$ctx"
    print -P "${C[green]}✓${C[reset]} Active LM Studio model: ${C[bold]}$id${C[reset]} ${C[dim]}(ctx ${ctx})${C[reset]}"
}

# Cheap reachability check (curl, 2s timeout) — used by availability + status.
_lmstudio_reachable() {
    local base=$(lmstudio_endpoint)
    base="${base%/}"; base="${base%/v1}"
    curl -s --max-time 2 -o /dev/null "${base}/v1/models" 2>/dev/null
}

# Backend is available when the server is reachable AND a model resolves.
_lmstudio_available() {
    _lmstudio_reachable || return 1
    [[ -n "$(lmstudio_model_resolve 2>/dev/null)" ]]
}

# /llm list rendering when backend=lmstudio.
lmstudio_list() {
    print -P ""
    print -P "${C[bright_yellow]}LM STUDIO MODELS${C[reset]} ${C[dim]}($(lmstudio_endpoint))${C[reset]}"
    if ! _lmstudio_reachable; then
        print -P "  ${C[red]}○${C[reset]} server not reachable — start LM Studio's local server"
        print -P ""
        return 0
    fi
    local active=$(lmstudio_model_resolve 2>/dev/null)
    local rows=$(_lmstudio_discover)
    if [[ -z "$rows" ]]; then
        print -P "  ${C[dim]}no models reported${C[reset]}"; print -P ""; return 0
    fi
    local id state quant max_ctx loaded_ctx
    print -- "$rows" | while IFS=$'\t' read -r id state quant max_ctx loaded_ctx; do
        local marker="  "
        [[ "$id" == "$active" ]] && marker="${C[bright_cyan]}▸ ${C[reset]}"
        local dot="${C[gray]}○${C[reset]}"
        [[ "$state" == "loaded" ]] && dot="${C[green]}●${C[reset]}"
        local ctx="$max_ctx"
        [[ -n "$loaded_ctx" && "$loaded_ctx" != "0" ]] && ctx="${loaded_ctx}/${max_ctx}"
        print -P "${marker}${C[bold]}${id}${C[reset]}  ${C[dim]}${quant}  ctx ${ctx}${C[reset]}  ${dot} ${state}"
    done
    print -P ""
    print -P "  ${C[dim]}/llm use <id>${C[reset]}   set active LM Studio model (▸)"
    print -P ""
}

# Core generate wrapper used by titling/summary/ask.
# Args: $1=system  $2=prompt  $3=max_tokens  $4=temp
_generate_lmstudio() {
    local model=$(lmstudio_model_resolve 2>/dev/null)
    [[ -z "$model" ]] && return 1
    "$(_lmstudio_python)" "$MK_ROOT/src/llm/server_helper.py" \
        --endpoint "$(lmstudio_endpoint)" \
        --model "$model" \
        --system "$1" \
        --prompt "$2" \
        --max-tokens "$3" \
        --temp "$4" \
        2>/dev/null
}
