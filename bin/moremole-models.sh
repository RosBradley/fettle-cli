#!/bin/bash
# moremole - AI models (Ollama).
# Checks the installed models for updates and installs the ones picked,
# downloads models from Ollama's library, and removes models. When Ollama is
# off it offers to turn it on, and turns it off again when done.
# moremole-models-go does the looking; this script shows the lists and runs
# `ollama pull` and `ollama rm`.

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

MODE="update"
OLLAMA_APP=""
OLLAMA_CLI=""
OLLAMA_RUNNING=0
MAC_MEMORY=0
# How this run turned Ollama on, to turn it off again: app, serve or "".
STARTED=""
SERVE_PID=""

# Installed models.
M_NAME=()
M_SIZE=()
M_MODIFIED=()
M_STATUS=()
M_LOADED=()
# Models in Ollama's library.
L_NAME=()
L_CAPS=()
L_PULLS=()
L_UPDATED=()
L_INSTALLED=()
L_DESC=()
NOTICE_KEYS=()
NOTICE_TEXTS=()

total_done=0
total_failed=0
FAILURES=()
SUMMARY_NOTES=()
SUMMARY_SHOWN=false

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
  --download        Pick models from ollama.com/library to download
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

# Read installed models ("model name size modified status loaded").
load_models() {
    local kind name size modified status loaded
    while IFS="$MODELS_FIELD_SEP" read -r kind name size modified status loaded || [[ -n "${kind:-}" ]]; do
        case "$kind" in
            notice) add_notice "$name" "$size" ;;
            model)
                M_NAME+=("$name")
                M_SIZE+=("${size:-0}")
                M_MODIFIED+=("${modified:-0}")
                M_STATUS+=("$status")
                M_LOADED+=("${loaded:-0}")
                ;;
        esac
    done
}

# Read the library ("model name capabilities pulls updated installed description").
load_library() {
    local kind name caps pulls updated installed desc
    while IFS="$MODELS_FIELD_SEP" read -r kind name caps pulls updated installed desc || [[ -n "${kind:-}" ]]; do
        case "$kind" in
            notice) add_notice "$name" "$caps" ;;
            model)
                L_NAME+=("$name")
                L_CAPS+=("$caps")
                L_PULLS+=("$pulls")
                L_UPDATED+=("${updated:-0}")
                L_INSTALLED+=("${installed:-0}")
                L_DESC+=("$desc")
                ;;
        esac
    done
}

human_size() {
    if [[ "$1" =~ ^[0-9]+$ && "$1" -gt 0 ]]; then
        bytes_to_human "$1"
    else
        printf 'size unknown'
    fi
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

status_text() {
    case "$1" in
        update) printf 'update available' ;;
        current) printf 'up to date' ;;
        local) printf 'made on this Mac' ;;
        unknown) printf "couldn't check" ;;
        *) printf '%s' "$1" ;;
    esac
}

# Pad or cut text to a display width.
fit_cell() {
    local text width="$2" shown
    text=$(mole_terminal_safe_text "$1")
    shown=$(truncate_by_display_width "$text" "$width")
    printf '%s%*s' "$shown" "$((width - $(get_display_width "$shown")))" ""
}

name_width() {
    local width=12 name w
    for name in "$@"; do
        w=$(get_display_width "$name")
        ((w <= width)) || width=$w
    done
    ((width <= 36)) || width=36
    printf '%s' "$width"
}

model_row_text() {
    local i="$1" width="$2" extra
    extra="$(human_size "${M_SIZE[i]}")"
    [[ -z "${M_STATUS[i]}" ]] || extra+=" · $(status_text "${M_STATUS[i]}")"
    [[ "${M_LOADED[i]}" != "1" ]] || extra+=" · in use"
    printf '%s  %s' "$(fit_cell "${M_NAME[i]}" "$width")" "$extra"
}

library_row_text() {
    local i="$1" width="$2" text
    text="$(fit_cell "${L_NAME[i]}" "$width")"
    [[ -z "${L_CAPS[i]}" ]] || text+="  ${L_CAPS[i]//,/, }"
    [[ -z "${L_PULLS[i]}" ]] || text+="  ${L_PULLS[i]} pulls"
    [[ "${L_INSTALLED[i]}" != "1" ]] || text+="  (installed)"
    printf '%s' "$text"
}

print_model_list() {
    local width i total=0
    width=$(name_width "${M_NAME[@]}")
    echo -e "${PURPLE_BOLD}${#M_NAME[@]} models${NC}"
    for ((i = 0; i < ${#M_NAME[@]}; i++)); do
        printf '  %s\n' "$(model_row_text "$i" "$width")"
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
pull_models() {
    local action_detail="$1"
    shift
    local name
    MOREMOLE_RUN_ERRORS=$(create_temp_file)
    for name in "$@"; do
        echo -e "${BLUE}${ICON_ARROW} $(mole_terminal_safe_text "$name")${NC}"
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
        echo -e "${GREEN}${ICON_SUCCESS}${NC} No models installed. Download one with the Download item."
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

    local -a rows=() names=()
    local width
    width=$(name_width "${M_NAME[@]}")
    for i in "${updates[@]}"; do
        rows+=("$(model_row_text "$i" "$width")")
        names+=("${M_NAME[i]}")
    done
    if ! pick "Select model updates to install" "${rows[@]}"; then
        moremole_note_cancel
        return 0
    fi
    local -a chosen=()
    for i in "${PICKED[@]}"; do
        chosen+=("${names[i]}")
    done

    echo -e "${PURPLE_BOLD}Models to update:${NC}"
    local name
    for name in "${chosen[@]}"; do
        printf '  %s%s%s %s\n' "$GREEN" "$ICON_SUCCESS" "$NC" "$(mole_terminal_safe_text "$name")"
    done
    printf '\n%sOllama downloads only the parts that changed.%s\n' "$GRAY" "$NC"
    if ! confirm "Update ${#chosen[@]} models"; then
        moremole_note_cancel
        return 0
    fi
    log_operation_session_start "$MOLE_CURRENT_COMMAND"
    pull_models "updated" "${chosen[@]}"
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
    # Enter with nothing picked picks nothing, never the row under the cursor.
    local rc=0 _MOLE_MENU_KEEP_EMPTY=true
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
    pick "Select models to remove" "$@"
}

# The library opens A-Z; S sorts by when each model was last updated.
# Search finds a model by its name, what it can do, or its description.
pick_to_download() {
    local -a search=()
    local i
    for ((i = 0; i < ${#L_NAME[@]}; i++)); do
        search+=("${L_NAME[i]} ${L_CAPS[i]//,/ } ${L_DESC[i]}")
    done
    local MOLE_MENU_META_EPOCHS MOLE_MENU_FILTER_NAMES
    MOLE_MENU_META_EPOCHS=$(
        IFS=','
        printf '%s' "${L_UPDATED[*]}"
    )
    MOLE_MENU_FILTER_NAMES=$(printf '%s\n' "${search[@]}")
    local MOLE_MENU_SORT_MODE=name MOLE_MENU_SORT_REVERSE=false
    pick "Select models to download" "$@"
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
    for ((i = 0; i < ${#M_NAME[@]}; i++)); do
        rows+=("$(model_row_text "$i" "$width")")
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
        echo -e "${PURPLE_BOLD}${#L_NAME[@]} models in Ollama's library${NC}"
        for ((i = 0; i < ${#L_NAME[@]}; i++)); do
            printf '  %s\n' "$(library_row_text "$i" "$width")"
        done
        return 0
    else
        local -a rows=()
        local i width
        width=$(name_width "${L_NAME[@]}")
        for ((i = 0; i < ${#L_NAME[@]}; i++)); do
            rows+=("$(library_row_text "$i" "$width")")
        done
        if ! pick_to_download "${rows[@]}"; then
            moremole_note_cancel
            return 0
        fi
        for i in "${PICKED[@]}"; do
            chosen+=("${L_NAME[i]}")
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
    pull_models "downloaded" "${found[@]}"
    log_operation_session_end "$MOLE_CURRENT_COMMAND" "$total_done" 0
    turn_off_if_started
    show_summary "Models downloaded" "Downloaded"
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
            *)
                echo "Unknown option: $arg" >&2
                echo "Use 'moremole models --help' for supported options." >&2
                return 1
                ;;
        esac
    done

    if [[ ! -x "$MODELS_HELPER" ]]; then
        echo -e "${RED}${ICON_ERROR}${NC} AI models needs building first. In your moremole folder, run: make build" >&2
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
