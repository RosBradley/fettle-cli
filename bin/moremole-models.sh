#!/bin/bash
# moremole - Ollama models.
# Checks the installed models for updates and installs the ones picked,
# downloads models from Ollama's library, adds MLX models from Hugging Face,
# and removes models. When Ollama is off it offers to turn it on, and turns
# it off again when done.
# moremole-models-go does the looking and the Hugging Face downloads; this
# script shows the lists and runs `ollama pull`, `ollama create` and
# `ollama rm`.

set -euo pipefail

# User state and installed tools must never run with inherited root privileges.
if [[ "$EUID" -eq 0 ]]; then
    printf '%s\n' 'Run moremole without sudo.' >&2
    exit 1
fi

# shellcheck disable=SC2154
# External variables set by menu_paginated.sh
declare MOLE_SELECTION_RESULT

export MOLE_CURRENT_COMMAND="${MOLE_CURRENT_COMMAND:-models}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/core/common.sh"
source "$SCRIPT_DIR/../lib/ui/menu_paginated.sh"
source "$SCRIPT_DIR/../lib/moremole/runs.sh"
source "$SCRIPT_DIR/../lib/moremole/details.sh"

MODELS_HELPER="$SCRIPT_DIR/moremole-models-go"
MODELS_OPEN=/usr/bin/open
MODELS_OSASCRIPT=/usr/bin/osascript
MODELS_START_WAIT=20
# Tests swap in a fake helper, open and osascript, never outside test mode.
if [[ "${MOLE_TEST_MODE:-0}" == "1" ]]; then
    MODELS_HELPER="${MOREMOLE_TEST_MODELS_HELPER:-$MODELS_HELPER}"
    MODELS_OPEN="${MOREMOLE_TEST_OPEN:-$MODELS_OPEN}"
    MODELS_OSASCRIPT="${MOREMOLE_TEST_OSASCRIPT:-$MODELS_OSASCRIPT}"
    MODELS_START_WAIT="${MOREMOLE_TEST_START_WAIT:-$MODELS_START_WAIT}"
fi
readonly MODELS_FIELD_SEP=$'\x1f'
# The models MoreMole added from Hugging Face ("name<TAB>repo<TAB>commit"),
# so Ollama models can check them with Hugging Face, and where their files
# wait while Ollama adds them.
HF_RECORD="$HOME/.config/mole/moremole-hf-models"
HF_STAGING="$HOME/Library/Caches/moremole/models/hf"
readonly HF_REPO_RE='^[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]*$'

MODE="update"
OLLAMA_APP=""
OLLAMA_CLI=""
OLLAMA_RUNNING=0
MAC_MEMORY=0
# 1 on Apple silicon, where MLX versions of models run.
MODELS_APPLE_SILICON=0
# How this run turned Ollama on, to turn it off again: app, serve or "".
STARTED=""
SERVE_PID=""

# Installed models.
M_NAME=()
M_SIZE=()
M_MODIFIED=()
M_STATUS=()
M_LOADED=()
M_REPO=()
# Models in Ollama's library.
L_NAME=()
L_CAPS=()
L_PULLS=()
L_UPDATED=()
L_INSTALLED=()
L_SIZES=()
L_MLX=()
L_DESC=()
# The versions of the models picked for download, from their tags pages.
T_NAME=()
T_BYTES=()
T_SIZE=()
T_CONTEXT=()
T_INPUT=()
T_MLX=()
T_DEFAULT=()
T_INSTALLED=()
# MLX models on Hugging Face that Ollama runs.
H_REPO=()
H_FAMILY=()
H_QUANT=()
H_BYTES=()
H_DOWNLOADS=()
H_UPDATED=()
H_INSTALLED=()
H_INPUT=()
H_CREATED=()
# Exact download sizes, read when a model's details are opened.
H_EXACT=()
NOTICE_KEYS=()
NOTICE_TEXTS=()

total_done=0
total_failed=0
FAILURES=()
SUMMARY_NOTES=()
SUMMARY_SHOWN=false
# Downloads from Hugging Face that stopped partway, kept to continue.
HF_KEPT=()

cleanup() {
    turn_off_if_started > /dev/null 2>&1 || true
    show_cursor
    cleanup_temp_files
}
trap cleanup EXIT
trap 'trap - EXIT; cleanup; exit 130' INT TERM

show_models_help() {
    cat << 'EOF'
Usage: moremole models [OPTIONS]

Check your Ollama models for updates and install the ones you pick,
download new models from Ollama's library, or remove models.
Nothing starts selected; you pick. If Ollama is off, it offers to turn
it on, and turns it off again when done.

Options:
  --download        Pick models from ollama.com/library, then the versions to download
  --huggingface     Pick MLX models from Hugging Face to add to Ollama (Apple silicon)
  --remove          Pick installed models to remove
  -n, --dry-run     List, without downloading or removing anything
  --debug           Show detailed logs
  -h, --help        Show this help message
EOF
}

# Whether someone is there to answer: a terminal on both ends. Tests replace it.
interactive() {
    [[ -t 0 && -t 1 ]]
}

run_helper() {
    "$MODELS_HELPER" "$@" 2> /dev/null || true
}

spin() {
    [[ -t 1 ]] && start_inline_spinner "$1"
    return 0
}

unspin() {
    [[ -t 1 ]] && stop_inline_spinner
    return 0
}

read_status() {
    local line
    OLLAMA_APP="" OLLAMA_CLI="" OLLAMA_RUNNING=0 MAC_MEMORY=0
    while IFS= read -r line; do
        case "$line" in
            app=*) OLLAMA_APP="${line#app=}" ;;
            cli=*) OLLAMA_CLI="${line#cli=}" ;;
            running=*) OLLAMA_RUNNING="${line#running=}" ;;
            memory=*) MAC_MEMORY="${line#memory=}" ;;
            mlx=*) MODELS_APPLE_SILICON="${line#mlx=}" ;;
        esac
    done < <(run_helper status)
    [[ "$MAC_MEMORY" =~ ^[0-9]+$ ]] || MAC_MEMORY=0
}

# Make sure Ollama's service runs: offer to turn it on, then wait for it.
# Returns 1 when it can't run, 2 when the user would rather not.
ensure_ollama() {
    read_status
    if [[ -z "$OLLAMA_CLI" && -z "$OLLAMA_APP" ]]; then
        echo -e "${YELLOW}${ICON_WARNING}${NC} Ollama isn't installed on this Mac."
        echo "Get it at https://ollama.com/download, or with Homebrew: brew install --cask ollama"
        return 1
    fi
    [[ "$OLLAMA_RUNNING" == "1" ]] && return 0
    if ! interactive; then
        echo -e "${YELLOW}${ICON_WARNING}${NC} Ollama is off."
        echo "Open the Ollama app, then run moremole models again."
        return 1
    fi
    if [[ "${MOLE_DRY_RUN:-0}" == "1" ]]; then
        echo -e "${YELLOW}${ICON_WARNING}${NC} Ollama is off, and a dry run doesn't turn it on."
        echo "Open the Ollama app, then run this again to see its models."
        return 2
    fi

    echo -e "${GRAY}Ollama is off. It needs to be on to look at its models; it goes off again when this is done.${NC}"
    echo -ne "${PURPLE}${ICON_ARROW}${NC} Turn Ollama on?  ${GREEN}Enter${NC} turn on, ${GRAY}ESC${NC} cancel: "
    local key
    IFS= read -r -s -n1 key || key="cancel"
    printf '\n'
    case "$key" in
        "" | $'\n' | $'\r') ;;
        *)
            moremole_note_cancel
            return 2
            ;;
    esac

    if [[ -n "$OLLAMA_APP" ]]; then
        # The app starts the service with its own settings, such as where
        # models are kept.
        "$MODELS_OPEN" -g -a "$OLLAMA_APP" 2> /dev/null || true
        STARTED="app"
    else
        local serve_log
        serve_log=$(create_temp_file)
        "$OLLAMA_CLI" serve > "$serve_log" 2>&1 &
        SERVE_PID=$!
        STARTED="serve"
    fi

    spin "Turning Ollama on..."
    local waited=0
    while ((waited < MODELS_START_WAIT * 2)); do
        read_status
        [[ "$OLLAMA_RUNNING" == "1" ]] && break
        sleep 0.5
        waited=$((waited + 1))
    done
    unspin
    if [[ "$OLLAMA_RUNNING" != "1" ]]; then
        echo -e "${YELLOW}${ICON_WARNING}${NC} Ollama didn't start within ${MODELS_START_WAIT} seconds."
        echo "Open the Ollama app, then run moremole models again."
        turn_off_if_started || true
        return 1
    fi
    return 0
}

# Leave Ollama as it was found: off again if this run turned it on.
turn_off_if_started() {
    case "$STARTED" in
        app)
            local name="${OLLAMA_APP##*/}"
            "$MODELS_OSASCRIPT" -e "quit app \"${name%.app}\"" > /dev/null 2>&1 || true
            ;;
        serve)
            if [[ -n "$SERVE_PID" ]]; then
                kill "$SERVE_PID" 2> /dev/null || true
                wait "$SERVE_PID" 2> /dev/null || true
            fi
            ;;
        *) return 0 ;;
    esac
    STARTED=""
    SERVE_PID=""
    SUMMARY_NOTES+=("Ollama was off, so it is off again")
}

add_notice() {
    NOTICE_KEYS+=("$1")
    NOTICE_TEXTS+=("$2")
}

print_notices() {
    local i
    for ((i = 0; i < ${#NOTICE_TEXTS[@]}; i++)); do
        echo -e "${YELLOW}${ICON_WARNING}${NC} $(mole_terminal_safe_text "${NOTICE_TEXTS[i]}")"
    done
    [[ ${#NOTICE_TEXTS[@]} -eq 0 ]] || printf '\n'
}

# Read installed models ("model name size modified status loaded repo");
# repo is the Hugging Face model it was added from by MoreMole.
load_models() {
    local kind name size modified status loaded repo
    while IFS="$MODELS_FIELD_SEP" read -r kind name size modified status loaded repo || [[ -n "${kind:-}" ]]; do
        case "$kind" in
            notice) add_notice "$name" "$size" ;;
            model)
                M_NAME+=("$name")
                M_SIZE+=("${size:-0}")
                M_MODIFIED+=("${modified:-0}")
                M_STATUS+=("$status")
                M_LOADED+=("${loaded:-0}")
                M_REPO+=("${repo:-}")
                ;;
        esac
    done
}

# Read the library ("model name capabilities pulls updated installed sizes
# mlx description"), one row per model; mlx is how many MLX versions it has.
load_library() {
    local kind name caps pulls updated installed sizes mlx desc
    while IFS="$MODELS_FIELD_SEP" read -r kind name caps pulls updated installed sizes mlx desc || [[ -n "${kind:-}" ]]; do
        case "$kind" in
            notice) add_notice "$name" "$caps" ;;
            model)
                L_NAME+=("$name")
                L_CAPS+=("$caps")
                L_PULLS+=("$pulls")
                L_UPDATED+=("${updated:-0}")
                L_INSTALLED+=("${installed:-0}")
                L_SIZES+=("$sizes")
                L_MLX+=("${mlx:-}")
                L_DESC+=("$desc")
                ;;
        esac
    done
}

# Read the versions of the picked models ("tag name bytes size context input
# mlx default installed"). TAGS_FAILED holds the models whose tags page
# couldn't be read.
TAGS_FAILED=()
load_tags() {
    local kind name bytes size context input mlx default installed
    while IFS="$MODELS_FIELD_SEP" read -r kind name bytes size context input mlx default installed || [[ -n "${kind:-}" ]]; do
        case "$kind" in
            notice) [[ "$name" != "tags-failed" ]] || TAGS_FAILED+=("$bytes") ;;
            tag)
                T_NAME+=("$name")
                T_BYTES+=("${bytes:-0}")
                T_SIZE+=("$size")
                T_CONTEXT+=("$context")
                T_INPUT+=("$input")
                T_MLX+=("${mlx:-0}")
                T_DEFAULT+=("${default:-0}")
                T_INSTALLED+=("${installed:-0}")
                ;;
        esac
    done
}

# Read the MLX models on Hugging Face ("hf repo family quant bytes downloads
# updated installed input created").
load_hf() {
    local kind repo family quant bytes downloads updated installed input created
    while IFS="$MODELS_FIELD_SEP" read -r kind repo family quant bytes downloads updated installed input created || [[ -n "${kind:-}" ]]; do
        case "$kind" in
            notice) add_notice "$repo" "$family" ;;
            hf)
                [[ "$repo" =~ $HF_REPO_RE ]] || continue
                H_REPO+=("$repo")
                H_FAMILY+=("$family")
                H_QUANT+=("$quant")
                H_BYTES+=("${bytes:-0}")
                H_DOWNLOADS+=("${downloads:-0}")
                H_UPDATED+=("${updated:-0}")
                H_INSTALLED+=("${installed:-0}")
                H_INPUT+=("$input")
                H_CREATED+=("${created:-0}")
                ;;
        esac
    done
}

# A model whose tags page couldn't be read still offers its sizes, without
# the details the page gives.
add_plain_versions() {
    local i="$1" size
    local -a sizes=()
    [[ -z "${L_SIZES[i]}" ]] || IFS=',' read -r -a sizes <<< "${L_SIZES[i]}"
    [[ ${#sizes[@]} -gt 0 ]] || sizes=(latest)
    for size in "${sizes[@]}"; do
        T_NAME+=("${L_NAME[i]}:$size")
        T_BYTES+=(0)
        T_SIZE+=("")
        T_CONTEXT+=("")
        T_INPUT+=("")
        T_MLX+=(0)
        T_DEFAULT+=(0)
        T_INSTALLED+=(0)
    done
}

# The lists have hundreds of rows, so building one forks nothing: these
# helpers set TEXT, and the row builders set ROW, instead of printing for a
# $(...) to read. (With a fork per cell, 553 Hugging Face rows took 21s.)
TEXT=""
ROW=""

# A size as bytes_to_human gives it (3.30GB, 512.0MB, 20KB), or "size unknown".
size_text() {
    local bytes="$1" scaled
    if [[ ! "$bytes" =~ ^[0-9]+$ || "$bytes" -eq 0 ]]; then
        TEXT="size unknown"
    elif ((bytes >= 1000000000)); then
        scaled=$(((bytes * 100 + 500000000) / 1000000000))
        printf -v TEXT '%d.%02dGB' $((scaled / 100)) $((scaled % 100))
    elif ((bytes >= 1000000)); then
        scaled=$(((bytes * 10 + 500000) / 1000000))
        printf -v TEXT '%d.%01dMB' $((scaled / 10)) $((scaled % 10))
    elif ((bytes >= 1000)); then
        TEXT="$(((bytes + 500) / 1000))KB"
    else
        TEXT="${bytes}B"
    fi
}

human_size() {
    size_text "$1"
    printf '%s' "$TEXT"
}

# A model needs about its file size in memory, plus room for what it reads.
fit_text() {
    local bytes="$1"
    [[ "$bytes" =~ ^[0-9]+$ && "$bytes" -gt 0 && "$MAC_MEMORY" -gt 0 ]] || return 0
    local share=$((bytes * 100 / MAC_MEMORY)) memory
    memory=$(bytes_to_human "$MAC_MEMORY")
    if ((share <= 50)); then
        printf 'fits in %s memory' "$memory"
    elif ((share <= 75)); then
        printf 'tight in %s memory: close other apps first' "$memory"
    else
        printf 'too big for %s memory' "$memory"
    fi
}

# One word for whether a download fits this Mac's memory, as fit_text says.
fit_word() {
    local bytes="$1" share
    TEXT=""
    [[ "$bytes" =~ ^[0-9]+$ && "$bytes" -gt 0 && "$MAC_MEMORY" -gt 0 ]] || return 0
    share=$((bytes * 100 / MAC_MEMORY))
    if ((share <= 50)); then
        TEXT="fits"
    elif ((share <= 75)); then
        TEXT="tight"
    else
        TEXT="too big"
    fi
}

# A model's registry check in words; "short" gives the list's first column.
status_text() {
    local short="${2:-}"
    case "$1" in
        update) TEXT="update available" ;;
        current) TEXT="up to date" ;;
        local) TEXT="made on this Mac" ;;
        unknown) TEXT="couldn't check" ;;
        *) TEXT="$1" ;;
    esac
    if [[ -n "$short" ]]; then
        case "$1" in
            update) TEXT="update" ;;
            local) TEXT="made here" ;;
            unknown) TEXT="unchecked" ;;
        esac
    fi
}

# Add text to ROW, cut or padded to width, after two spaces unless it's the
# first cell. Control characters can't reach the terminal. Width counts
# characters, which is right for every name these lists show.
cell() {
    local text="$1" width="$2" chars pad=""
    [[ "$width" =~ ^[0-9]+$ ]] || width=0
    text="${text//[$'\t\n\r']/ }"
    text="${text//[[:cntrl:]]/?}"
    local LC_ALL=en_US.UTF-8
    chars=${#text}
    if ((chars > width)); then
        if ((width > 3)); then text="${text:0:width-3}..."; else text="${text:0:width}"; fi
        chars=$width
    fi
    ((chars >= width)) || printf -v pad '%*s' "$((width - chars))" ""
    ROW+="${ROW:+  }$text$pad"
}

# The same, lined up on the right, for numbers.
rcell() {
    local text="$1" width="$2" pad=""
    ((${#text} >= width)) || printf -v pad '%*s' "$((width - ${#text}))" ""
    ROW+="${ROW:+  }$pad$text"
}

# The terminal's width: COLUMNS, else the terminal itself, else 100.
terminal_cols() {
    local cols="${COLUMNS:-}"
    if [[ ! "$cols" =~ ^[0-9]+$ ]]; then
        cols=$(stty size < /dev/tty 2> /dev/null) || cols=""
        cols="${cols##* }"
    fi
    [[ "$cols" =~ ^[0-9]+$ && "$cols" -gt 0 ]] || cols=100
    printf '%s' "$cols"
}

# The width of the longest name, at least 12 and at most MODELS_NAME_MAX.
name_width() {
    local width=12 name LC_ALL=en_US.UTF-8
    for name in "$@"; do
        ((${#name} <= width)) || width=${#name}
    done
    ((width <= ${MODELS_NAME_MAX:-36})) || width=${MODELS_NAME_MAX:-36}
    printf '%s' "$width"
}

# An installed model: its status first, then name, size, and whether it's in
# use or came from Hugging Face.
model_row_text() {
    local i="$1" width="$2" extra
    size_text "${M_SIZE[i]}"
    extra="$TEXT"
    [[ "${M_LOADED[i]}" != "1" ]] || extra+=" · in use"
    [[ -z "${M_REPO[i]:-}" ]] || extra+=" · from Hugging Face"
    ROW=""
    status_text "${M_STATUS[i]}" short
    cell "$TEXT" 10
    cell "${M_NAME[i]}" "$width"
    ROW+="  $extra"
}

# Each list's column headings, built with its rows' cells so they line up;
# they set COLUMNS_HEADER, which pick shows under the search line.
COLUMNS_HEADER=""
model_header() {
    ROW=""
    cell "Status" 10
    cell "Name" "$1"
    ROW+="  Size"
    COLUMNS_HEADER="$ROW"
}

library_header() {
    ROW=""
    cell "Status" 9
    [[ "${MODELS_APPLE_SILICON:-0}" != "1" ]] || cell "MLX" 3
    cell "Name" "$1"
    cell "Can do" 18
    cell "Sizes" 12
    rcell "Pulls" 6
    cell "Updated" 10
    COLUMNS_HEADER="$ROW"
}

tag_header() {
    ROW=""
    cell "Status" 9
    cell "Memory" 7
    cell "Version" "$1"
    cell "Size" 11
    cell "Context" 7
    cell "Input" 12
    [[ "${MODELS_APPLE_SILICON:-0}" != "1" ]] || ROW+="  MLX"
    COLUMNS_HEADER="$ROW"
}

hf_header() {
    ROW=""
    cell "Status" 7
    cell "Name" "$1"
    cell "Bits" 6
    cell "Size" 9
    cell "Can do" 6
    rcell "Downloads" 9
    cell "Published" 10
    COLUMNS_HEADER="$ROW"
}

# The sizes a model comes in: "8b, 70b", or the smallest to the largest.
sizes_text() {
    local -a sizes=()
    TEXT=""
    [[ -n "$1" ]] || return 0
    IFS=',' read -r -a sizes <<< "$1"
    if [[ ${#sizes[@]} -le 2 ]]; then
        TEXT="${1//,/, }"
    else
        TEXT="${sizes[0]}–${sizes[${#sizes[@]} - 1]}"
    fi
}

# A library model: installed first, and on Apple silicon MLX when it has MLX
# versions, then name, what it can do, its sizes, pulls and when Ollama last
# updated it.
library_row_text() {
    local i="$1" width="$2" mlx="" status=""
    [[ "${L_INSTALLED[i]}" != "1" ]] || status="installed"
    ROW=""
    cell "$status" 9
    if [[ "${MODELS_APPLE_SILICON:-0}" == "1" ]]; then
        [[ ! "${L_MLX[i]:-}" =~ ^[1-9][0-9]*$ ]] || mlx="MLX"
        cell "$mlx" 3
    fi
    cell "${L_NAME[i]}" "$width"
    caps_text "${L_CAPS[i]}"
    cell "$TEXT" 18
    sizes_text "${L_SIZES[i]}"
    cell "$TEXT" 12
    pulls_number "${L_PULLS[i]}"
    count_text "$TEXT"
    [[ "$TEXT" != "0" ]] || TEXT=""
    rcell "$TEXT" 6
    date_cell_text "${L_UPDATED[i]}"
    cell "$TEXT" 10
}

# The library's pull count as a number: 30.1M is 30100000, 2,538 is 2538;
# 0 when it can't be read.
pulls_number() {
    local text="${1//,/}" unit=1 whole frac=""
    TEXT=0
    case "$text" in
        *K) unit=1000 ;;
        *M) unit=1000000 ;;
        *B) unit=1000000000 ;;
    esac
    ((unit == 1)) || text="${text%?}"
    [[ "$text" =~ ^([0-9]+)(\.([0-9]))?$ ]] || return 0
    whole="${BASH_REMATCH[1]}"
    frac="${BASH_REMATCH[3]:-0}"
    TEXT=$((10#$whole * unit + 10#$frac * unit / 10))
}

# A model family as people say it: qwen3_5_moe is Qwen 3.5 MoE.
family_text() {
    case "$1" in
        qwen3_5) TEXT="Qwen 3.5" ;;
        qwen3_5_moe) TEXT="Qwen 3.5 MoE" ;;
        qwen3_5_text) TEXT="Qwen 3.5 text" ;;
        qwen4_exp) TEXT="Qwen 4 exp" ;;
        gemma4) TEXT="Gemma 4" ;;
        nemotron_h) TEXT="Nemotron H" ;;
        nemotron_h_omni) TEXT="Nemotron H omni" ;;
        lfm3) TEXT="LFM3" ;;
        lfm3_vl) TEXT="LFM3 VL" ;;
        lfm3_omni) TEXT="LFM3 omni" ;;
        lfm3_audio) TEXT="LFM3 audio" ;;
        laguna) TEXT="Laguna" ;;
        cohere2_moe) TEXT="Cohere 2 MoE" ;;
        muse_glimmer) TEXT="Muse Glimmer" ;;
        *) TEXT="$1" ;;
    esac
}

# A count with one decimal and its unit, so every row reads alike: 3.5K,
# 719.8K, 30.1M, 1.2B; under a thousand as it is.
count_text() {
    local n="$1" unit="" div=1
    TEXT=""
    [[ "$n" =~ ^[0-9]+$ ]] || return 0
    if ((n >= 1000000000)); then
        unit=B div=1000000000
    elif ((n >= 1000000)); then
        unit=M div=1000000
    elif ((n >= 1000)); then
        unit=K div=1000
    else
        TEXT="$n"
        return 0
    fi
    TEXT="$((n / div)).$((n % div * 10 / div))$unit"
}

# A date as 2026-10-14 (UTC), worked out without a fork; empty for none.
date_cell_text() {
    local t="$1" z era doe yoe y doy mp d m
    TEXT=""
    [[ "$t" =~ ^[0-9]+$ && "$t" -gt 0 ]] || return 0
    z=$((t / 86400 + 719468))
    era=$((z / 146097))
    doe=$((z - era * 146097))
    yoe=$(((doe - doe / 1460 + doe / 36524 - doe / 146096) / 365))
    y=$((yoe + era * 400))
    doy=$((doe - (365 * yoe + yoe / 4 - yoe / 100)))
    mp=$(((5 * doy + 2) / 153))
    d=$((doy - (153 * mp + 2) / 5 + 1))
    if ((mp < 10)); then m=$((mp + 3)); else m=$((mp - 9)); fi
    ((m > 2)) || y=$((y + 1))
    printf -v TEXT '%04d-%02d-%02d' "$y" "$m" "$d"
}

# What a library model can do, in short words: tools vision think.
caps_text() {
    local cap
    TEXT=""
    for cap in ${1//,/ }; do
        case "$cap" in
            thinking) cap=think ;;
            embedding) cap=embed ;;
            decision) cap=decide ;;
        esac
        TEXT+="${TEXT:+ }$cap"
    done
}

# A Hugging Face model: added, or else whether it fits, first, then name,
# quantization, about how big, vision when it reads images, downloads in
# the last month and when it was published. The family is on the details
# screen, and search finds it; most names say it anyway.
hf_row_text() {
    local i="$1" width="$2"
    ROW=""
    fit_word "${H_BYTES[i]}"
    [[ "${H_INSTALLED[i]}" != "1" ]] || TEXT="added"
    cell "$TEXT" 7
    cell "${H_REPO[i]}" "$width"
    cell "${H_QUANT[i]}" 6
    if [[ "${H_BYTES[i]}" =~ ^[1-9][0-9]*$ ]]; then
        size_text "${H_BYTES[i]}"
        TEXT="~$TEXT"
    else
        TEXT="?"
    fi
    cell "$TEXT" 9
    TEXT=""
    [[ "${H_INPUT[i]}" != *Image* ]] || TEXT="vision"
    cell "$TEXT" 6
    count_text "${H_DOWNLOADS[i]}"
    rcell "$TEXT" 9
    date_cell_text "${H_CREATED[i]:-0}"
    cell "$TEXT" 10
}

# The width left for Hugging Face names: the row's other columns take 59,
# and the list's arrow and checkbox 5. At least 20, at most 50.
hf_name_width() {
    local room longest
    room=$(($(terminal_cols) - 64))
    longest=$(MODELS_NAME_MAX=50 name_width "${H_REPO[@]}")
    ((room >= 20)) || room=20
    ((room <= longest)) || room=$longest
    printf '%s' "$room"
}

# A version: installed or default and its memory fit first, then name, size,
# context window, input, and MLX.
tag_row_text() {
    local i="$1" width="$2" status=""
    [[ "${T_DEFAULT[i]}" != "1" ]] || status="default"
    [[ "${T_INSTALLED[i]}" != "1" ]] || status="installed"
    ROW=""
    cell "$status" 9
    fit_word "${T_BYTES[i]}"
    cell "$TEXT" 7
    cell "${T_NAME[i]}" "$width"
    cell "${T_SIZE[i]:-?}" 11
    cell "${T_CONTEXT[i]}" 7
    cell "${T_INPUT[i]}" 12
    [[ "${T_MLX[i]}" != "1" ]] || ROW+="  MLX"
}

# The details screen of a pick list's row. DETAILS_KIND says which list it
# is; DETAILS_MAP turns a row into its model when the list shows only some.
DETAILS_KIND=""
DETAILS_MAP=()
# What D does in the pick list, shown in its keys.
DONE_LABEL=""
show_model_details() {
    local i="${DETAILS_MAP[$1]:-$1}"
    case "$DETAILS_KIND" in
        installed) installed_details "$i" ;;
        library) library_details "$i" ;;
        tag) tag_details "$i" ;;
        hf) hf_details "$i" ;;
    esac
}

date_text() {
    [[ "$1" =~ ^[0-9]+$ && "$1" -gt 0 ]] || return 0
    "$_DATE_CMD" -u -r "$1" '+%-d %B %Y' 2> /dev/null || true
}

# A model's page: ollama.com for its registry, huggingface.co for a model
# from there.
model_page() {
    local name="${1%:latest}"
    case "$name" in
        hf.co/* | */*/*) ;;
        */*) printf 'https://ollama.com/%s' "$name" ;;
        *) printf 'https://ollama.com/library/%s' "$name" ;;
    esac
}

installed_details() {
    local i="$1" in_use=""
    [[ "${M_LOADED[i]}" != "1" ]] || in_use="yes, loaded in memory now"
    detail_name "${M_NAME[i]}"
    status_text "${M_STATUS[i]}"
    detail_line "Status" "$TEXT"
    detail_line "Size on disk" "$(human_size "${M_SIZE[i]}")"
    detail_line "Changed" "$(date_text "${M_MODIFIED[i]}")"
    detail_line "In use" "$in_use"
    if [[ -n "${M_REPO[i]:-}" ]]; then
        detail_line "Added from" "Hugging Face, ${M_REPO[i]}"
        detail_line "Page" "https://huggingface.co/${M_REPO[i]}"
    else
        detail_line "Page" "$(model_page "${M_NAME[i]}")"
    fi
}

library_details() {
    local i="$1" mlx="" installed="" pulls=""
    [[ "${L_INSTALLED[i]}" != "1" ]] || installed="yes"
    [[ -z "${L_PULLS[i]}" ]] || pulls="${L_PULLS[i]}"
    if [[ "${MODELS_APPLE_SILICON:-0}" == "1" && "${L_MLX[i]:-}" =~ ^[1-9][0-9]*$ ]]; then
        mlx="${L_MLX[i]} versions for Apple silicon"
        [[ "${L_MLX[i]}" != "1" ]] || mlx="1 version for Apple silicon"
    fi
    detail_name "${L_NAME[i]}"
    if [[ -n "${L_DESC[i]}" ]]; then
        mole_terminal_safe_text "${L_DESC[i]}" | fold -s -w "${MOLE_MENU_DETAILS_WIDTH:-80}"
        printf '\n\n'
    fi
    detail_line "Can do" "${L_CAPS[i]//,/, }"
    detail_line "Sizes" "${L_SIZES[i]//,/, }"
    detail_line "Pulls" "$pulls"
    detail_line "Updated" "$(date_text "${L_UPDATED[i]}")"
    detail_line "MLX" "$mlx"
    detail_line "Installed" "$installed"
    detail_line "Page" "$(model_page "${L_NAME[i]}")"
    printf '\n%sSelect it, save, then choose which versions to download.%s\n' "$GRAY" "$NC"
}

tag_details() {
    local i="$1" mlx="" default="" installed=""
    [[ "${T_MLX[i]}" != "1" ]] || mlx="yes, runs on Ollama's MLX engine for Apple silicon"
    [[ "${T_DEFAULT[i]}" != "1" ]] || default="yes, what ollama pull ${T_NAME[i]%%:*} downloads"
    [[ "${T_INSTALLED[i]}" != "1" ]] || installed="yes"
    detail_name "${T_NAME[i]}"
    detail_line "Size" "${T_SIZE[i]:-unknown}"
    detail_line "Memory" "$(fit_text "${T_BYTES[i]}")"
    detail_line "Context" "${T_CONTEXT[i]}"
    detail_line "Input" "${T_INPUT[i]}"
    detail_line "MLX" "$mlx"
    detail_line "Default" "$default"
    detail_line "Installed" "$installed"
    detail_line "Page" "$(model_page "${T_NAME[i]}")"
}

# The exact download size of Hugging Face model i, asked once.
hf_exact_size() {
    local i="$1" kind repo sha bytes count rest
    [[ -z "${H_EXACT[i]:-}" ]] || return 0
    H_EXACT[i]="-"
    while IFS="$MODELS_FIELD_SEP" read -r kind repo sha bytes count rest || [[ -n "${kind:-}" ]]; do
        [[ "$kind" == "files" && "$bytes" =~ ^[1-9][0-9]*$ ]] && H_EXACT[i]="$bytes $count"
    done < <(run_helper hf-files "${H_REPO[i]}" 2> /dev/null)
}

hf_details() {
    local i="$1"
    local size="" downloads="" added="" name bytes="${H_BYTES[i]}"
    name="hf.co/$(printf '%s' "${H_REPO[i]}" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
    hf_exact_size "$i"
    if [[ "${H_EXACT[i]}" != "-" ]]; then
        bytes="${H_EXACT[i]%% *}"
        size="$(bytes_to_human "$bytes") in ${H_EXACT[i]#* } files"
    elif [[ "$bytes" =~ ^[1-9][0-9]*$ ]]; then
        size="about $(bytes_to_human "$bytes"); Hugging Face couldn't give the exact size"
    fi
    [[ ! "${H_DOWNLOADS[i]}" =~ ^[0-9]+$ ]] || downloads="${H_DOWNLOADS[i]} in the last month"
    [[ "${H_INSTALLED[i]}" != "1" ]] || added="yes"
    detail_name "${H_REPO[i]}"
    family_text "${H_FAMILY[i]}"
    detail_line "Family" "$TEXT"
    detail_line "Quantization" "${H_QUANT[i]}"
    detail_line "Size" "$size"
    detail_line "Memory" "$(fit_text "$bytes")"
    detail_line "Input" "${H_INPUT[i]}"
    detail_line "Downloads" "$downloads"
    detail_line "Published" "$(date_text "${H_CREATED[i]:-0}")"
    detail_line "Updated" "$(date_text "${H_UPDATED[i]}")"
    detail_line "Added" "$added"
    detail_line "In Ollama as" "$name"
    detail_line "Page" "https://huggingface.co/${H_REPO[i]}"
}

print_model_list() {
    local width i total=0
    width=$(name_width "${M_NAME[@]}")
    model_header "$width"
    echo -e "${PURPLE_BOLD}${#M_NAME[@]} models${NC}"
    printf '  %s%s%s\n' "$GRAY" "$COLUMNS_HEADER" "$NC"
    for ((i = 0; i < ${#M_NAME[@]}; i++)); do
        model_row_text "$i" "$width"
        printf '  %s\n' "$ROW"
        [[ "${M_SIZE[i]}" =~ ^[0-9]+$ ]] && total=$((total + M_SIZE[i]))
    done
    printf '\n%sTogether %s on disk; models share some files, so it may be less.%s\n' "$GRAY" "$(bytes_to_human "$total")" "$NC"
}

# Ask a yes-or-no question with Enter and ESC; a failed read cancels.
confirm() {
    local key
    echo -ne "${PURPLE}${ICON_ARROW}${NC} $1  ${GREEN}Enter${NC} confirm, ${GRAY}ESC${NC} cancel: "
    if ! IFS= read -r -s -n1 key; then
        printf '\n'
        return 1
    fi
    case "$key" in
        "" | $'\n' | $'\r')
            printf '\r\033[K\n'
            return 0
            ;;
    esac
    printf '\n'
    return 1
}

record_result() {
    local name="$1" ok="$2" action="$3" detail="$4"
    if [[ "$ok" == "true" ]]; then
        total_done=$((total_done + 1))
        log_operation "$MOLE_CURRENT_COMMAND" "$action" "$name" "$detail"
    else
        local reason
        reason=$(moremole_run_error_line)
        reason="${reason:-ollama reported an error}"
        total_failed=$((total_failed + 1))
        FAILURES+=("$name: $reason")
        log_operation "$MOLE_CURRENT_COMMAND" "FAILED" "$name" "$reason"
    fi
}

# Pull each model, with Ollama's own progress on screen.
# Each model's heading while it downloads, with how far along the run is
# (2 of 3) when there are several. Callers set PROGRESS_TOTAL first.
PROGRESS_N=0
PROGRESS_TOTAL=0
model_heading() {
    local count=""
    PROGRESS_N=$((PROGRESS_N + 1))
    ((PROGRESS_TOTAL <= 1)) || count="  ${GRAY}${PROGRESS_N} of ${PROGRESS_TOTAL}${NC}"
    echo -e "${BLUE}${ICON_ARROW} $(mole_terminal_safe_text "$1")${NC}${count}"
}

pull_models() {
    local action_detail="$1"
    shift
    local name
    MOREMOLE_RUN_ERRORS=$(create_temp_file)
    for name in "$@"; do
        model_heading "$name"
        if moremole_run_shown "$OLLAMA_CLI" pull "$name"; then
            record_result "$name" true "REBUILT" "$action_detail"
        else
            record_result "$name" false "" ""
        fi
        printf '\n'
    done
}

show_summary() {
    local heading="$1" done_label="$2"
    local -a details=()
    [[ $total_failed -eq 0 ]] || heading="Some models did not finish"
    if [[ $total_done -gt 0 ]]; then
        details+=("$done_label ${GREEN}$total_done${NC}")
    else
        details+=("Nothing was changed")
    fi
    local item
    for item in "${FAILURES[@]+"${FAILURES[@]}"}"; do
        details+=("${ICON_WARNING} Not done: $(mole_terminal_safe_text "$item")")
    done
    for item in "${SUMMARY_NOTES[@]+"${SUMMARY_NOTES[@]}"}"; do
        details+=("$item")
    done
    print_summary_block "$heading" "${details[@]}"
    printf '\n'
    SUMMARY_SHOWN=true
}

# Where a Hugging Face model's files wait while Ollama adds it.
hf_staging_dir() {
    printf '%s/%s' "$HF_STAGING" "${1//\//--}"
}

hf_record_remove() {
    local name="$1" line kept
    [[ -f "$HF_RECORD" ]] || return 0
    kept=$(create_temp_file)
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "${line%%$'\t'*}" == "$name" ]] || printf '%s\n' "$line"
    done < "$HF_RECORD" > "$kept"
    cat "$kept" > "$HF_RECORD"
}

hf_record_add() {
    local name="$1" repo="$2" sha="$3"
    mkdir -p "${HF_RECORD%/*}"
    hf_record_remove "$name"
    printf '%s\t%s\t%s\n' "$name" "$repo" "$sha" >> "$HF_RECORD"
}

# `ollama create` reads the Modelfile in the folder it runs in.
ollama_create_in() {
    (cd "$1" && "$OLLAMA_CLI" create "$2")
}

# Add one model from Hugging Face as NAME: download its files at commit SHA,
# checked, add them under a name of their own, start that once, and only
# when it works give it NAME. A model that fails leaves NAME as it was.
hf_install() {
    local repo="$1" sha="$2" name="$3" detail="$4" dir trial reason=""
    # Ollama lists a model without a tag as :latest.
    [[ "${name##*/}" == *:* ]] || name+=":latest"
    [[ "$repo" =~ $HF_REPO_RE && "$sha" =~ ^[0-9a-f]{40}$ ]] || {
        record_hf_failure "$name" "not a Hugging Face model"
        return 0
    }
    dir=$(hf_staging_dir "$repo")
    trial="${name%:latest}-moremole-check"
    model_heading "$repo"
    if ! moremole_run_shown "$MODELS_HELPER" hf-download "$repo" "$sha" "$dir"; then
        reason=$(moremole_run_error_line)
        HF_KEPT+=("$dir")
        record_hf_failure "$name" "${reason:-the download stopped}"
        return 0
    fi
    if ! moremole_run_shown ollama_create_in "$dir" "$trial"; then
        reason=$(moremole_run_error_line)
        "$OLLAMA_CLI" rm "$trial" > /dev/null 2>&1 || true
        hf_remove_staging "$dir"
        record_hf_failure "$name" "Ollama couldn't add it: ${reason:-ollama create failed}"
        return 0
    fi
    hf_remove_staging "$dir"

    spin "Starting it once to check that it works..."
    local kind key text verified=false
    while IFS="$MODELS_FIELD_SEP" read -r kind key text || [[ -n "${kind:-}" ]]; do
        case "$kind" in
            verified) verified=true ;;
            notice) reason="$text" ;;
        esac
    done < <(run_helper hf-verify "$trial")
    unspin
    if [[ "$verified" != "true" ]]; then
        "$OLLAMA_CLI" rm "$trial" > /dev/null 2>&1 || true
        record_hf_failure "$name" "it was removed again because ${reason:-it did not start}"
        return 0
    fi
    if ! "$OLLAMA_CLI" cp "$trial" "$name" > /dev/null 2>&1; then
        "$OLLAMA_CLI" rm "$trial" > /dev/null 2>&1 || true
        record_hf_failure "$name" "Ollama couldn't name it $name"
        return 0
    fi
    "$OLLAMA_CLI" rm "$trial" > /dev/null 2>&1 || true
    hf_record_add "$name" "$repo" "$sha"
    echo -e "${GREEN}${ICON_SUCCESS}${NC} Added as $(mole_terminal_safe_text "$name"), and it works"
    total_done=$((total_done + 1))
    log_operation "$MOLE_CURRENT_COMMAND" "REBUILT" "$name" "$detail from Hugging Face $repo at ${sha:0:7}"
    printf '\n'
}

record_hf_failure() {
    local name="$1" reason="$2"
    total_failed=$((total_failed + 1))
    FAILURES+=("$name: $reason")
    log_operation "$MOLE_CURRENT_COMMAND" "FAILED" "$name" "$reason"
    echo -e "${YELLOW}${ICON_WARNING}${NC} $(mole_terminal_safe_text "$name"): $(mole_terminal_safe_text "$reason")"
    printf '\n'
}

# The staging folder is MoreMole's own copy of the download; Ollama keeps
# its own once the model is added.
hf_remove_staging() {
    local dir="$1"
    [[ "$dir" == "$HF_STAGING"/* && "$dir" != *..* && -d "$dir" ]] || return 0
    rm -rf "$dir" # SAFE: MoreMole's own Hugging Face download folder under ~/Library/Caches/moremole/models/hf, already added to Ollama
}

# Read hf-files rows ("files repo sha bytes count name") into the F_ arrays;
# a model Hugging Face couldn't give is named in a warning.
F_REPO=()
F_SHA=()
F_BYTES=()
F_NAME=()
load_hf_files() {
    local kind repo sha bytes count name
    F_REPO=() F_SHA=() F_BYTES=() F_NAME=()
    while IFS="$MODELS_FIELD_SEP" read -r kind repo sha bytes count name || [[ -n "${kind:-}" ]]; do
        case "$kind" in
            files)
                [[ "$repo" =~ $HF_REPO_RE && "$sha" =~ ^[0-9a-f]{40}$ ]] || continue
                F_REPO+=("$repo")
                F_SHA+=("$sha")
                F_BYTES+=("${bytes:-0}")
                F_NAME+=("$name")
                ;;
            notice) echo -e "${YELLOW}${ICON_WARNING}${NC} Couldn't get $(mole_terminal_safe_text "$sha") from Hugging Face." ;;
        esac
    done
}

# Download Hugging Face models again at their newest commit, each entry
# "name<TAB>repo".
update_from_hf() {
    local entry name repo j
    for entry in "$@"; do
        name="${entry%%$'\t'*}"
        repo="${entry#*$'\t'}"
        load_hf_files < <(run_helper hf-files "$repo")
        if [[ ${#F_REPO[@]} -eq 0 ]]; then
            record_hf_failure "$name" "couldn't get it from Hugging Face"
            continue
        fi
        for ((j = 0; j < ${#F_REPO[@]}; j++)); do
            hf_install "${F_REPO[j]}" "${F_SHA[j]}" "$name" "updated"
        done
    done
}

# Update: check every model with its registry, then pull the picked ones.
run_update() {
    spin "Checking models with Ollama's registry..."
    load_models < <(run_helper list --check)
    unspin
    print_notices
    if has_notice service-failed; then
        return 1
    fi
    if [[ ${#M_NAME[@]} -eq 0 ]]; then
        echo -e "${GREEN}${ICON_SUCCESS}${NC} No models installed. Download one with Add Ollama models."
        return 0
    fi

    local -a updates=()
    local i unchecked=0
    for ((i = 0; i < ${#M_NAME[@]}; i++)); do
        case "${M_STATUS[i]}" in
            update) updates+=("$i") ;;
            unknown) unchecked=$((unchecked + 1)) ;;
        esac
    done
    local unchecked_note=""
    ((unchecked == 0)) || unchecked_note="${YELLOW}${ICON_WARNING}${NC} Couldn't check $unchecked of ${#M_NAME[@]} models with their registry. Check the internet connection, then try again."
    if [[ "${MOLE_DRY_RUN:-0}" == "1" || ${#updates[@]} -eq 0 ]] || ! interactive; then
        print_model_list
        if [[ -n "$unchecked_note" ]]; then
            printf '\n'
            echo -e "$unchecked_note"
        elif [[ ${#updates[@]} -eq 0 ]]; then
            printf '\n'
            echo -e "${GREEN}${ICON_SUCCESS}${NC} No updates: every model the registry knows is up to date"
        fi
        if [[ ${#updates[@]} -gt 0 && "${MOLE_DRY_RUN:-0}" != "1" ]]; then
            printf 'Run moremole models in a terminal to choose updates.\n'
        fi
        return 0
    fi
    [[ -z "$unchecked_note" ]] || echo -e "$unchecked_note"

    local -a rows=() names=() repos=()
    local width
    width=$(name_width "${M_NAME[@]}")
    model_header "$width"
    for i in "${updates[@]}"; do
        model_row_text "$i" "$width"
        rows+=("$ROW")
        names+=("${M_NAME[i]}")
        repos+=("${M_REPO[i]:-}")
    done
    DETAILS_KIND=installed
    DETAILS_MAP=("${updates[@]}")
    DONE_LABEL=Update
    if ! pick "Select model updates to install" "${rows[@]}"; then
        moremole_note_cancel
        return 0
    fi
    local -a chosen=() from_hf=()
    for i in "${PICKED[@]}"; do
        if [[ -n "${repos[i]}" ]]; then
            from_hf+=("${names[i]}"$'\t'"${repos[i]}")
        else
            chosen+=("${names[i]}")
        fi
    done

    echo -e "${PURPLE_BOLD}Models to update:${NC}"
    local name entry
    for name in "${chosen[@]+"${chosen[@]}"}"; do
        printf '  %s%s%s %s\n' "$GREEN" "$ICON_SUCCESS" "$NC" "$(mole_terminal_safe_text "$name")"
    done
    for entry in "${from_hf[@]+"${from_hf[@]}"}"; do
        printf '  %s%s%s %s %sfrom Hugging Face%s\n' "$GREEN" "$ICON_SUCCESS" "$NC" "$(mole_terminal_safe_text "${entry%%$'\t'*}")" "$GRAY" "$NC"
    done
    printf '\n'
    [[ ${#chosen[@]} -eq 0 ]] || printf '%sOllama downloads only the parts that changed.%s\n' "$GRAY" "$NC"
    [[ ${#from_hf[@]} -eq 0 ]] || printf '%sModels from Hugging Face download again in full, and replace the old version only once the new one starts.%s\n' "$GRAY" "$NC"
    if ! confirm "Update $((${#chosen[@]} + ${#from_hf[@]})) models"; then
        moremole_note_cancel
        return 0
    fi
    log_operation_session_start "$MOLE_CURRENT_COMMAND"
    PROGRESS_TOTAL=$((${#chosen[@]} + ${#from_hf[@]}))
    [[ ${#chosen[@]} -eq 0 ]] || pull_models "updated" "${chosen[@]}"
    if [[ ${#from_hf[@]} -gt 0 ]]; then
        MOREMOLE_RUN_ERRORS=$(create_temp_file)
        update_from_hf "${from_hf[@]}"
    fi
    log_operation_session_end "$MOLE_CURRENT_COMMAND" "$total_done" 0
    turn_off_if_started
    show_summary "Models updated" "Updated"
}

# Show a pick list; PICKED holds the picked indices. Callers set the list's
# MOLE_MENU_* options as locals.
PICKED=()
pick() {
    local title="$1"
    shift
    MOLE_SELECTION_RESULT=""
    PICKED=()
    # Saving with nothing picked picks nothing, never the row under the cursor.
    # Enter shows the row's details.
    local rc=0 _MOLE_MENU_KEEP_EMPTY=true MOLE_MENU_DETAILS_FN="" MOLE_MENU_DONE_LABEL="${DONE_LABEL:-Save}"
    local MOLE_MENU_COLUMNS_HEADER="$COLUMNS_HEADER"
    [[ -z "$DETAILS_KIND" ]] || MOLE_MENU_DETAILS_FN=show_model_details
    hide_cursor
    paginated_multi_select "$title" "$@" || rc=$?
    show_cursor
    [[ $rc -eq 0 && -n "$MOLE_SELECTION_RESULT" ]] || return 1
    IFS=',' read -r -a PICKED <<< "$MOLE_SELECTION_RESULT"
}

# The removal list opens A-Z; S sorts by size, then by date.
pick_to_remove() {
    local -a sizes_kb=() epochs=()
    local i
    for ((i = 0; i < ${#M_NAME[@]}; i++)); do
        sizes_kb+=("$((${M_SIZE[i]:-0} / 1024))")
        epochs+=("${M_MODIFIED[i]:-0}")
    done
    local MOLE_MENU_META_SIZEKB MOLE_MENU_META_EPOCHS MOLE_MENU_FILTER_NAMES
    MOLE_MENU_META_SIZEKB=$(
        IFS=','
        printf '%s' "${sizes_kb[*]}"
    )
    MOLE_MENU_META_EPOCHS=$(
        IFS=','
        printf '%s' "${epochs[*]}"
    )
    MOLE_MENU_FILTER_NAMES=$(printf '%s\n' "${M_NAME[@]}")
    local MOLE_MENU_SORT_MODE=name MOLE_MENU_SORT_REVERSE=false _MOLE_MENU_SELECT_ALL=true
    DETAILS_KIND=installed
    DETAILS_MAP=()
    DONE_LABEL=Remove
    pick "Select models to remove" "$@"
}

# The library opens A-Z; S sorts by when each model was last updated.
# Search finds a model by its name, what it can do, or its description.
pick_models_to_download() {
    local -a search=()
    local i
    local words
    for ((i = 0; i < ${#L_NAME[@]}; i++)); do
        words="${L_NAME[i]} ${L_CAPS[i]//,/ } ${L_DESC[i]}"
        [[ ! "${L_MLX[i]:-}" =~ ^[1-9][0-9]*$ ]] || words+=" mlx"
        search+=("$words")
    done
    local MOLE_MENU_META_EPOCHS MOLE_MENU_FILTER_NAMES
    MOLE_MENU_META_EPOCHS=$(
        IFS=','
        printf '%s' "${L_UPDATED[*]}"
    )
    MOLE_MENU_FILTER_NAMES=$(printf '%s\n' "${search[@]}")
    local -a pulls=()
    for ((i = 0; i < ${#L_NAME[@]}; i++)); do
        pulls_number "${L_PULLS[i]}"
        pulls+=("$TEXT")
    done
    local MOLE_MENU_META_COUNTS MOLE_MENU_COUNT_LABEL=Pulls
    MOLE_MENU_META_COUNTS=$(
        IFS=','
        printf '%s' "${pulls[*]}"
    )
    local MOLE_MENU_SORT_MODE=name MOLE_MENU_SORT_REVERSE=false
    local title="Select models, then choose their versions"
    [[ "${MODELS_APPLE_SILICON:-0}" != "1" ]] || title+="; MLX: it has versions for Apple silicon"
    DETAILS_KIND=library
    DETAILS_MAP=()
    DONE_LABEL=Next
    pick "$title" "$@"
}

# The Hugging Face list opens A-Z; S sorts by size, then by when it was
# published, then by downloads. Search finds a model by its name, family,
# quantization, what it reads, vision, or added.
pick_hf_models() {
    local -a search=() sizes_kb=() published=()
    local i words
    for ((i = 0; i < ${#H_REPO[@]}; i++)); do
        family_text "${H_FAMILY[i]}"
        words="${H_REPO[i]} $TEXT ${H_FAMILY[i]} ${H_QUANT[i]} ${H_INPUT[i]//,/}"
        [[ "${H_INSTALLED[i]}" != "1" ]] || words+=" added"
        [[ "${H_INPUT[i]}" != *Image* ]] || words+=" vision"
        search+=("$words")
        sizes_kb+=("$((${H_BYTES[i]:-0} / 1024))")
        if [[ "${H_CREATED[i]:-0}" =~ ^[1-9][0-9]*$ ]]; then
            published+=("${H_CREATED[i]}")
        else
            published+=("${H_UPDATED[i]:-0}")
        fi
    done
    local MOLE_MENU_META_SIZEKB MOLE_MENU_META_EPOCHS MOLE_MENU_FILTER_NAMES
    MOLE_MENU_META_SIZEKB=$(
        IFS=','
        printf '%s' "${sizes_kb[*]}"
    )
    MOLE_MENU_META_EPOCHS=$(
        IFS=','
        printf '%s' "${published[*]}"
    )
    MOLE_MENU_FILTER_NAMES=$(printf '%s\n' "${search[@]}")
    local MOLE_MENU_META_COUNTS MOLE_MENU_COUNT_LABEL=Downloads
    MOLE_MENU_META_COUNTS=$(
        IFS=','
        printf '%s' "${H_DOWNLOADS[*]}"
    )
    local MOLE_MENU_SORT_MODE=name MOLE_MENU_SORT_REVERSE=false
    DETAILS_KIND=hf
    DETAILS_MAP=()
    DONE_LABEL=Add
    pick "Select MLX models from Hugging Face" "$@"
}

# The versions open smallest first; S sorts A-Z. Search finds a version by
# its name, MLX, what it reads, or default and installed.
pick_versions_to_download() {
    local -a search=() sizes_kb=()
    local i words
    for ((i = 0; i < ${#T_NAME[@]}; i++)); do
        words="${T_NAME[i]} ${T_INPUT[i]//,/}"
        [[ "${T_MLX[i]}" != "1" ]] || words+=" mlx"
        [[ "${T_DEFAULT[i]}" != "1" ]] || words+=" default"
        [[ "${T_INSTALLED[i]}" != "1" ]] || words+=" installed"
        search+=("$words")
        sizes_kb+=("$((${T_BYTES[i]:-0} / 1024))")
    done
    local MOLE_MENU_META_SIZEKB MOLE_MENU_FILTER_NAMES
    MOLE_MENU_META_SIZEKB=$(
        IFS=','
        printf '%s' "${sizes_kb[*]}"
    )
    MOLE_MENU_FILTER_NAMES=$(printf '%s\n' "${search[@]}")
    local MOLE_MENU_SORT_MODE=size MOLE_MENU_SORT_REVERSE=true
    local title="Select versions to download"
    [[ "${MODELS_APPLE_SILICON:-0}" != "1" ]] || title+="; MLX: runs on Apple silicon"
    DETAILS_KIND=tag
    DETAILS_MAP=()
    DONE_LABEL=Download
    pick "$title" "$@"
}

# Remove: pick installed models and remove them with `ollama rm`.
run_remove() {
    # The registry check tells which models can be downloaded again.
    spin "Checking models with Ollama's registry..."
    load_models < <(run_helper list --check)
    unspin
    print_notices
    if has_notice service-failed; then
        return 1
    fi
    if [[ ${#M_NAME[@]} -eq 0 ]]; then
        echo -e "${GREEN}${ICON_SUCCESS}${NC} No models installed"
        return 0
    fi
    if [[ "${MOLE_DRY_RUN:-0}" == "1" ]] || ! interactive; then
        print_model_list
        [[ "${MOLE_DRY_RUN:-0}" == "1" ]] || printf 'Run moremole models --remove in a terminal to choose models.\n'
        return 0
    fi

    local -a rows=()
    local i width
    width=$(name_width "${M_NAME[@]}")
    model_header "$width"
    for ((i = 0; i < ${#M_NAME[@]}; i++)); do
        model_row_text "$i" "$width"
        rows+=("$ROW")
    done
    if ! pick_to_remove "${rows[@]}"; then
        moremole_note_cancel
        return 0
    fi

    local total=0 loaded=false
    local -a no_copy=()
    echo -e "${PURPLE_BOLD}Models to remove:${NC}"
    for i in "${PICKED[@]}"; do
        [[ "${M_SIZE[i]}" =~ ^[0-9]+$ ]] && total=$((total + M_SIZE[i]))
        [[ "${M_LOADED[i]}" == "1" ]] && loaded=true
        case "${M_STATUS[i]}" in
            current | update) ;;
            *) no_copy+=("$(mole_terminal_safe_text "${M_NAME[i]}")") ;;
        esac
        printf '  %s%s%s %s %s%s%s\n' "$RED" "$ICON_ERROR" "$NC" "$(mole_terminal_safe_text "${M_NAME[i]}")" \
            "$GRAY" "$(human_size "${M_SIZE[i]}")" "$NC"
    done
    printf '\n%sFrees up to %s; models share some files, which stay while another model uses them.%s\n' "$GRAY" "$(bytes_to_human "$total")" "$NC"
    if [[ ${#no_copy[@]} -eq 0 ]]; then
        printf '%sOllama deletes them; they do not go to the Trash. You can download them again.%s\n' "$GRAY" "$NC"
    else
        printf '%sOllama deletes them; they do not go to the Trash.%s\n' "$GRAY" "$NC"
        local listed
        listed=$(printf '%s, ' "${no_copy[@]}")
        echo -e "${YELLOW}${ICON_WARNING}${NC} Made on this Mac or not found in Ollama's registry, so they may not download again: ${listed%, }"
    fi
    [[ "$loaded" != "true" ]] || printf '%sA model in use is unloaded first.%s\n' "$GRAY" "$NC"
    if ! confirm "Remove ${#PICKED[@]} models"; then
        moremole_note_cancel
        return 0
    fi

    log_operation_session_start "$MOLE_CURRENT_COMMAND"
    MOREMOLE_RUN_ERRORS=$(create_temp_file)
    local freed=0
    for i in "${PICKED[@]}"; do
        if [[ "${M_LOADED[i]}" == "1" ]]; then
            "$OLLAMA_CLI" stop "${M_NAME[i]}" > /dev/null 2>&1 || true
        fi
        if moremole_run_shown "$OLLAMA_CLI" rm "${M_NAME[i]}"; then
            [[ -z "${M_REPO[i]:-}" ]] || hf_record_remove "${M_NAME[i]}"
            record_result "${M_NAME[i]}" true "REMOVED" "removed with ollama rm"
            [[ "${M_SIZE[i]}" =~ ^[0-9]+$ ]] && freed=$((freed + M_SIZE[i]))
        else
            record_result "${M_NAME[i]}" false "" ""
        fi
    done
    log_operation_session_end "$MOLE_CURRENT_COMMAND" "$total_done" 0
    printf '\n'
    [[ $freed -eq 0 ]] || SUMMARY_NOTES+=("Freed up to $(bytes_to_human "$freed")")
    turn_off_if_started
    show_summary "Models removed" "Removed"
}

# Download: pick models from ollama.com/library, or type a name when the
# page can't be read.
run_download() {
    spin "Reading Ollama's model list..."
    load_library < <(run_helper library)
    unspin
    print_notices

    local -a chosen=()
    if [[ ${#L_NAME[@]} -eq 0 ]]; then
        if [[ "${MOLE_DRY_RUN:-0}" == "1" ]]; then
            echo "Nothing to list without Ollama's model list; nothing was downloaded."
            return 0
        fi
        interactive || return 1
        local typed
        echo "Type a model's name as ollama.com/library shows it, such as gemma3:4b."
        IFS= read -r -p "Model to download (empty to cancel): " typed || typed=""
        typed="${typed//[[:space:]]/}"
        if [[ -z "$typed" ]]; then
            moremole_note_cancel
            return 0
        fi
        chosen=("$typed")
    elif [[ "${MOLE_DRY_RUN:-0}" == "1" ]] || ! interactive; then
        local i width
        width=$(name_width "${L_NAME[@]}")
        library_header "$width"
        echo -e "${PURPLE_BOLD}${#L_NAME[@]} models in Ollama's library${NC}"
        printf '  %s%s%s\n' "$GRAY" "$COLUMNS_HEADER" "$NC"
        for ((i = 0; i < ${#L_NAME[@]}; i++)); do
            library_row_text "$i" "$width"
            printf '  %s\n' "$ROW"
        done
        return 0
    else
        local -a rows=() models=()
        local i width
        width=$(name_width "${L_NAME[@]}")
        library_header "$width"
        for ((i = 0; i < ${#L_NAME[@]}; i++)); do
            library_row_text "$i" "$width"
            rows+=("$ROW")
        done
        if ! pick_models_to_download "${rows[@]}"; then
            moremole_note_cancel
            return 0
        fi
        for i in "${PICKED[@]}"; do
            models+=("${L_NAME[i]}")
        done

        # Each model's tags page lists its versions, with what they need.
        spin "Reading the versions of ${#models[@]} models..."
        load_tags < <(run_helper tags "${models[@]}")
        unspin
        local failed
        for i in "${PICKED[@]}"; do
            for failed in "${TAGS_FAILED[@]+"${TAGS_FAILED[@]}"}"; do
                if [[ "$failed" == "${L_NAME[i]}" ]]; then
                    echo -e "${YELLOW}${ICON_WARNING}${NC} Couldn't read the versions of $(mole_terminal_safe_text "$failed") at ollama.com/library/$(mole_terminal_safe_text "$failed")/tags, so its sizes are listed without details."
                    add_plain_versions "$i"
                fi
            done
        done
        rows=()
        width=$(name_width "${T_NAME[@]+"${T_NAME[@]}"}")
        tag_header "$width"
        for ((i = 0; i < ${#T_NAME[@]}; i++)); do
            tag_row_text "$i" "$width"
            rows+=("$ROW")
        done
        if ! pick_versions_to_download "${rows[@]}"; then
            moremole_note_cancel
            return 0
        fi
        for i in "${PICKED[@]}"; do
            chosen+=("${T_NAME[i]}")
        done
    fi

    # Sizes come from the registry, which also says whether a typed name exists.
    spin "Getting download sizes..."
    local -a sizes=() found=()
    local kind name size
    while IFS="$MODELS_FIELD_SEP" read -r kind name size || [[ -n "${kind:-}" ]]; do
        case "$kind" in
            size)
                found+=("$name")
                sizes+=("${size:-0}")
                ;;
            notice) echo -e "${YELLOW}${ICON_WARNING}${NC} $(mole_terminal_safe_text "$size") isn't in Ollama's registry; check the name on ollama.com/library." ;;
        esac
    done < <(run_helper size "${chosen[@]}")
    unspin
    if [[ ${#found[@]} -eq 0 ]]; then
        return 1
    fi

    echo -e "${PURPLE_BOLD}Models to download:${NC}"
    local j total=0 fit
    for ((j = 0; j < ${#found[@]}; j++)); do
        fit=$(fit_text "${sizes[j]}")
        printf '  %s%s%s %s %s%s%s%s\n' "$GREEN" "$ICON_SUCCESS" "$NC" "$(mole_terminal_safe_text "${found[j]}")" \
            "$GRAY" "$(human_size "${sizes[j]}")" "${fit:+ · $fit}" "$NC"
        [[ "${sizes[j]}" =~ ^[0-9]+$ ]] && total=$((total + sizes[j]))
    done
    printf '\n%sDownloads up to %s.%s\n' "$GRAY" "$(bytes_to_human "$total")" "$NC"
    if ! confirm "Download ${#found[@]} models"; then
        moremole_note_cancel
        return 0
    fi
    log_operation_session_start "$MOLE_CURRENT_COMMAND"
    PROGRESS_TOTAL=${#found[@]}
    pull_models "downloaded" "${found[@]}"
    log_operation_session_end "$MOLE_CURRENT_COMMAND" "$total_done" 0
    turn_off_if_started
    show_summary "Models downloaded" "Downloaded"
}

# Hugging Face: pick MLX models that Ollama runs, then add them, each
# checked by starting it once.
run_huggingface() {
    if [[ "${MODELS_APPLE_SILICON:-0}" != "1" ]]; then
        echo -e "${YELLOW}${ICON_WARNING}${NC} MLX models need a Mac with Apple silicon; this Mac has an Intel chip."
        echo "Choose Add Ollama models for models that run here."
        return 0
    fi
    spin "Reading the MLX models on Hugging Face that Ollama runs..."
    load_hf < <(run_helper hf-list)
    unspin
    print_notices
    if [[ ${#H_REPO[@]} -eq 0 ]]; then
        has_notice hf-failed && return 1
        echo "No MLX models on Hugging Face are in a family Ollama's MLX engine runs."
        return 0
    fi
    local i width
    width=$(hf_name_width)
    hf_header "$width"
    if [[ "${MOLE_DRY_RUN:-0}" == "1" ]] || ! interactive; then
        echo -e "${PURPLE_BOLD}${#H_REPO[@]} MLX models on Hugging Face that Ollama runs${NC}"
        printf '  %s%s%s\n' "$GRAY" "$COLUMNS_HEADER" "$NC"
        for ((i = 0; i < ${#H_REPO[@]}; i++)); do
            hf_row_text "$i" "$width"
            printf '  %s\n' "$ROW"
        done
        printf '\n%sSizes are estimates until you pick a model.%s\n' "$GRAY" "$NC"
        [[ "${MOLE_DRY_RUN:-0}" == "1" ]] || printf 'Run moremole models --huggingface in a terminal to choose models.\n'
        return 0
    fi

    local -a rows=() repos=()
    for ((i = 0; i < ${#H_REPO[@]}; i++)); do
        hf_row_text "$i" "$width"
        rows+=("$ROW")
    done
    if ! pick_hf_models "${rows[@]}"; then
        moremole_note_cancel
        return 0
    fi
    for i in "${PICKED[@]}"; do
        repos+=("${H_REPO[i]}")
    done

    spin "Getting download sizes from Hugging Face..."
    load_hf_files < <(run_helper hf-files "${repos[@]}")
    unspin
    [[ ${#F_REPO[@]} -gt 0 ]] || return 1

    echo -e "${PURPLE_BOLD}Models to add from Hugging Face:${NC}"
    local j total=0 fit
    for ((j = 0; j < ${#F_REPO[@]}; j++)); do
        fit=$(fit_text "${F_BYTES[j]}")
        printf '  %s%s%s %s %s%s%s · as %s%s\n' "$GREEN" "$ICON_SUCCESS" "$NC" "$(mole_terminal_safe_text "${F_REPO[j]}")" \
            "$GRAY" "$(human_size "${F_BYTES[j]}")" "${fit:+ · $fit}" "$(mole_terminal_safe_text "${F_NAME[j]}")" "$NC"
        [[ "${F_BYTES[j]}" =~ ^[0-9]+$ ]] && total=$((total + F_BYTES[j]))
    done
    printf '\n%sDownloads up to %s, each file checked against Hugging Face.%s\n' "$GRAY" "$(bytes_to_human "$total")" "$NC"
    printf "%sWhile a model is added it needs twice its size free: the download, then Ollama's copy. The download is deleted once Ollama has it.%s\n" "$GRAY" "$NC"
    printf "%sEach model is started once to check that it works; one that doesn't is removed again.%s\n" "$GRAY" "$NC"
    if ! confirm "Add ${#F_REPO[@]} models"; then
        moremole_note_cancel
        return 0
    fi
    log_operation_session_start "$MOLE_CURRENT_COMMAND"
    MOREMOLE_RUN_ERRORS=$(create_temp_file)
    PROGRESS_TOTAL=${#F_REPO[@]}
    for ((j = 0; j < ${#F_REPO[@]}; j++)); do
        hf_install "${F_REPO[j]}" "${F_SHA[j]}" "${F_NAME[j]}" "added"
    done
    log_operation_session_end "$MOLE_CURRENT_COMMAND" "$total_done" 0
    local dir
    for dir in "${HF_KEPT[@]+"${HF_KEPT[@]}"}"; do
        SUMMARY_NOTES+=("The downloaded part is kept in $(mole_terminal_safe_text "$dir"), so trying again continues; delete that folder to free the space instead")
    done
    turn_off_if_started
    show_summary "Models added" "Added"
}

main() {
    local arg
    for arg in "$@"; do
        case "$arg" in
            "--help" | "-h")
                show_models_help
                return 0
                ;;
            "--debug") export MO_DEBUG=1 ;;
            "--dry-run" | "-n") export MOLE_DRY_RUN=1 ;;
            "--remove") MODE="remove" ;;
            "--download") MODE="download" ;;
            "--huggingface") MODE="huggingface" ;;
            *)
                echo "Unknown option: $arg" >&2
                echo "Use 'moremole models --help' for supported options." >&2
                return 1
                ;;
        esac
    done

    if [[ ! -x "$MODELS_HELPER" ]]; then
        echo -e "${RED}${ICON_ERROR}${NC} Ollama models needs building first. In your moremole folder, run: make build" >&2
        return 1
    fi
    if [[ "${MOLE_DRY_RUN:-0}" == "1" ]]; then
        echo -e "${YELLOW}${ICON_DRY_RUN} DRY RUN MODE${NC}, nothing will be downloaded or removed"
        printf '\n'
    fi

    local rc=0
    ensure_ollama || rc=$?
    case "$rc" in
        0) ;;
        2) return 0 ;;
        *) return 1 ;;
    esac
    case "$MODE" in
        update) run_update || rc=$? ;;
        remove) run_remove || rc=$? ;;
        download) run_download || rc=$? ;;
        huggingface) run_huggingface || rc=$? ;;
    esac
    # Lists and previews end without a summary; say so here.
    if [[ "$SUMMARY_SHOWN" != "true" ]]; then
        turn_off_if_started
        if [[ ${#SUMMARY_NOTES[@]} -gt 0 ]]; then
            printf '\n%s%s.%s\n' "$GRAY" "${SUMMARY_NOTES[*]}" "$NC"
        fi
    fi
    [[ $rc -eq 0 && $total_failed -eq 0 ]]
}

if [[ "${MOLE_TEST_MODE:-0}" != "1" ]]; then
    main "$@"
fi
