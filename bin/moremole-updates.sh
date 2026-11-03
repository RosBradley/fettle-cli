#!/bin/bash
# moremole - Software updates.
# Lists updates for Homebrew apps and command-line tools, App Store apps,
# macOS, and apps installed without Homebrew, either from Homebrew's newer
# copy or from the app's own updater; then installs the ones picked.
# moremole-updates-go does the scanning; this script shows the list and runs
# the updates.

set -euo pipefail

# User state and installed tools must never run with inherited root privileges.
if [[ "$EUID" -eq 0 ]]; then
    printf '%s\n' 'Run moremole without sudo; it asks for your password when an update needs it.' >&2
    exit 1
fi

# shellcheck disable=SC2154
# External variables set by menu_paginated.sh
declare MOLE_SELECTION_RESULT

export MOLE_CURRENT_COMMAND="${MOLE_CURRENT_COMMAND:-updates}"
# The scan already refreshed Homebrew; each upgrade need not do it again.
export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ENV_HINTS=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/core/common.sh"
source "$SCRIPT_DIR/../lib/ui/menu_paginated.sh"
source "$SCRIPT_DIR/../lib/moremole/runs.sh"

UPDATES_HELPER="$SCRIPT_DIR/moremole-updates-go"
UPDATES_OPEN=/usr/bin/open
# Tests swap in a fake helper and a fake open, never outside test mode.
if [[ "${MOLE_TEST_MODE:-0}" == "1" ]]; then
    UPDATES_HELPER="${MOREMOLE_TEST_UPDATES_HELPER:-$UPDATES_HELPER}"
    UPDATES_OPEN="${MOREMOLE_TEST_OPEN:-$UPDATES_OPEN}"
fi
readonly UPDATES_SETTINGS_URL="x-apple.systempreferences:com.apple.Software-Update-Settings.extension"
readonly UPDATES_FIELD_SEP=$'\x1f'

# Scan results, one index per update.
U_KIND=()
U_ID=()
U_NAME=()
U_FROM=()
U_TO=()
U_NOTE=()
U_BUNDLE=()
NOTICE_KEYS=()
NOTICE_TEXTS=()
UPDATES_MACOS_PID=""
# The apps MoreMole runs inside, such as the terminal; updating one from
# here could end the run, so it is left out.
HOST_BUNDLES=()

total_updated=0
total_failed=0
UPDATE_FAILURES=()
SETTINGS_ITEMS=()
OPEN_INDICES=()
OPENED_NAMES=()
HOST_SKIPPED=()
RETRIED_NAMES=()

cleanup() {
    if [[ -n "$UPDATES_MACOS_PID" ]]; then
        kill "$UPDATES_MACOS_PID" 2> /dev/null || true
    fi
    show_cursor
    cleanup_temp_files
}
trap cleanup EXIT
trap 'trap - EXIT; cleanup; exit 130' INT TERM

show_updates_help() {
    cat << 'EOF'
Usage: moremole updates [OPTIONS]

Find and install updates for Homebrew apps and command-line tools,
App Store apps (with mas), macOS, and apps installed without Homebrew:
Homebrew's newer copy, or the app's own updater, which opens the app.
The list is A-Z and nothing starts selected; you pick.

Options:
  -n, --dry-run     List available updates without installing anything
  --debug           Show detailed logs
  -h, --help        Show this help message
EOF
}

# Program paths, found on PATH or in Homebrew's folders.
find_tool() {
    local name="$1" dir
    if command -v "$name" > /dev/null 2>&1; then
        command -v "$name"
        return 0
    fi
    for dir in /opt/homebrew/bin /usr/local/bin; do
        if [[ -x "$dir/$name" ]]; then
            printf '%s\n' "$dir/$name"
            return 0
        fi
    done
    return 1
}

# Read helper rows ("kind id name installed available note bundle") from
# standard input into the scan arrays; notices go to the notice arrays.
load_update_rows() {
    local kind id name from to note bundle
    while IFS="$UPDATES_FIELD_SEP" read -r kind id name from to note bundle || [[ -n "${kind:-}" ]]; do
        [[ -n "$kind" ]] || continue
        if [[ "$kind" == "notice" ]]; then
            NOTICE_KEYS+=("$id")
            NOTICE_TEXTS+=("$note")
            continue
        fi
        U_KIND+=("$kind")
        U_ID+=("$id")
        U_NAME+=("$name")
        U_FROM+=("$from")
        U_TO+=("$to")
        U_NOTE+=("$note")
        U_BUNDLE+=("$bundle")
    done
}

# Whether update $1 is for an app MoreMole runs inside.
is_host_update() {
    local bundle="${U_BUNDLE[$1]:-}" host
    [[ -n "$bundle" ]] || return 1
    for host in "${HOST_BUNDLES[@]+"${HOST_BUNDLES[@]}"}"; do
        [[ "$host" == "$bundle" ]] && return 0
    done
    return 1
}

run_helper() {
    "$UPDATES_HELPER" "$1" 2> /dev/null || true
}

drop_notice() {
    local -a keys=() texts=()
    local i
    for ((i = 0; i < ${#NOTICE_KEYS[@]}; i++)); do
        [[ "${NOTICE_KEYS[i]}" == "$1" ]] && continue
        keys+=("${NOTICE_KEYS[i]}")
        texts+=("${NOTICE_TEXTS[i]}")
    done
    NOTICE_KEYS=("${keys[@]+"${keys[@]}"}")
    NOTICE_TEXTS=("${texts[@]+"${texts[@]}"}")
}

# Put the scan arrays in A-Z order by name, whatever their source; each row
# shows where it comes from.
order_update_rows() {
    local -a o_kind=() o_id=() o_name=() o_from=() o_to=() o_note=() o_bundle=()
    local i _name
    while IFS=$'\t' read -r _name i; do
        o_kind+=("${U_KIND[i]}")
        o_id+=("${U_ID[i]}")
        o_name+=("${U_NAME[i]}")
        o_from+=("${U_FROM[i]}")
        o_to+=("${U_TO[i]}")
        o_note+=("${U_NOTE[i]}")
        o_bundle+=("${U_BUNDLE[i]}")
    done < <(
        for ((i = 0; i < ${#U_KIND[@]}; i++)); do
            printf '%s\t%s\n' "${U_NAME[i]}" "$i"
        done | LC_ALL=C sort -f -s -t $'\t' -k1,1
    )
    U_KIND=("${o_kind[@]+"${o_kind[@]}"}")
    U_ID=("${o_id[@]+"${o_id[@]}"}")
    U_NAME=("${o_name[@]+"${o_name[@]}"}")
    U_FROM=("${o_from[@]+"${o_from[@]}"}")
    U_TO=("${o_to[@]+"${o_to[@]}"}")
    U_NOTE=("${o_note[@]+"${o_note[@]}"}")
    U_BUNDLE=("${o_bundle[@]+"${o_bundle[@]}"}")
}

spin() {
    [[ -t 1 ]] && start_inline_spinner "$1"
    return 0
}

unspin() {
    [[ -t 1 ]] && stop_inline_spinner
    return 0
}

# Check every source. macOS takes longest, so it runs in the background
# while the others are checked.
scan_updates() {
    local macos_out
    macos_out=$(create_temp_file)
    "$UPDATES_HELPER" macos > "$macos_out" 2> /dev/null &
    UPDATES_MACOS_PID=$!

    local host
    while IFS= read -r host; do
        [[ -n "$host" ]] && HOST_BUNDLES+=("$host")
    done < <(run_helper host)

    spin "Checking Homebrew apps and tools..."
    load_update_rows < <(run_helper brew)
    unspin
    spin "Checking App Store apps..."
    load_update_rows < <(run_helper store)
    unspin
    spin "Checking apps installed without Homebrew..."
    load_update_rows < <(run_helper apps)
    unspin
    spin "Checking macOS updates..."
    wait "$UPDATES_MACOS_PID" 2> /dev/null || true
    UPDATES_MACOS_PID=""
    load_update_rows < "$macos_out"
    unspin

    order_update_rows
}

# Offer to install mas, the tool that checks App Store apps, then check them.
offer_mas_install() {
    has_notice mas-missing || return 0
    has_notice homebrew-missing && return 0
    [[ "${MOLE_DRY_RUN:-0}" == "1" || ! -t 0 || ! -t 1 ]] && return 0
    local brew key
    brew=$(find_tool brew) || return 0

    echo -e "${GRAY}App Store apps need mas, a free tool, to be checked.${NC}"
    echo -ne "${PURPLE}${ICON_ARROW}${NC} Install mas with Homebrew?  ${GREEN}Enter${NC} install, ${GRAY}ESC${NC} skip: "
    IFS= read -r -s -n1 key || key="skip"
    printf '\n'
    case "$key" in
        "" | $'\n' | $'\r') ;;
        *) return 0 ;;
    esac
    if "$brew" install mas; then
        log_operation "$MOLE_CURRENT_COMMAND" "REBUILT" "mas" "installed with Homebrew to check App Store apps"
        drop_notice mas-missing
        spin "Checking App Store apps..."
        load_update_rows < <(run_helper store)
        unspin
        order_update_rows
    fi
    printf '\n'
}

print_notices() {
    local i
    for ((i = 0; i < ${#NOTICE_KEYS[@]}; i++)); do
        echo -e "${YELLOW}${ICON_WARNING}${NC} $(mole_terminal_safe_text "${NOTICE_TEXTS[i]}")"
    done
    [[ ${#NOTICE_KEYS[@]} -eq 0 ]] || printf '\n'
}

kind_label() {
    case "$1" in
        app) printf 'Homebrew' ;;
        takeover) printf 'Move to Homebrew' ;;
        store) printf 'App Store' ;;
        tool) printf 'Command-line tool' ;;
        feed) printf 'Own updater' ;;
        macos | macos-settings) printf 'macOS' ;;
        *) printf '%s' "$1" ;;
    esac
}

version_text() {
    local from="${U_FROM[$1]}" to="${U_TO[$1]}"
    if [[ -n "$from" && -n "$to" ]]; then
        printf '%s → %s' "$from" "$to"
    else
        printf '%s' "$to"
    fi
}

# Display width; get_display_width counts the one-cell arrow as two.
text_width() {
    get_display_width "${1//→/-}"
}

# Cut text wider than $2 cells to fit, ending in "...". Callers run it in
# $(...), so the locale change stays here.
cut_width() {
    local text="$1" max="$2"
    if (($(text_width "$text") <= max)); then
        printf '%s\n' "$text"
        return 0
    fi
    local LC_ALL=en_US.UTF-8
    # Every character takes at least one cell, so start there and step down.
    local k=$((max - 3))
    ((k <= ${#text})) || k=${#text}
    while ((k > 0)) && (($(text_width "${text:0:k}") + 3 > max)); do
        k=$((k - 1))
    done
    printf '%s...\n' "${text:0:k}"
}

# Pad or cut text to a display width.
fit_width() {
    local text width="$2"
    text=$(cut_width "$1" "$width")
    printf '%s%*s' "$text" "$((width - $(text_width "$text")))" ""
}

# Column widths that fit the terminal: names up to 32 cells, versions up
# to 26, both narrower when the terminal is.
UPDATES_NAME_W=10
UPDATES_VER_W=10
UPDATES_ROW_W=76
measure_columns() {
    local columns="${COLUMNS:-$(tput cols 2> /dev/null || echo 80)}"
    [[ "$columns" =~ ^[0-9]+$ && "$columns" -gt 0 ]] || columns=80
    # The menu puts four cells before each row.
    UPDATES_ROW_W=$((columns - 4))
    ((UPDATES_ROW_W >= 20)) || UPDATES_ROW_W=20
    UPDATES_NAME_W=10
    UPDATES_VER_W=10
    local i width
    for ((i = 0; i < ${#U_KIND[@]}; i++)); do
        width=$(text_width "$(mole_terminal_safe_text "${U_NAME[i]}")")
        ((width <= UPDATES_NAME_W)) || UPDATES_NAME_W=$width
        width=$(text_width "$(version_text "$i")")
        ((width <= UPDATES_VER_W)) || UPDATES_VER_W=$width
    done
    ((UPDATES_NAME_W <= 32)) || UPDATES_NAME_W=32
    ((UPDATES_VER_W <= 26)) || UPDATES_VER_W=26
    # Leave room for the source column on narrow terminals.
    local room=$((UPDATES_ROW_W - 14))
    ((UPDATES_NAME_W + UPDATES_VER_W <= room)) || UPDATES_NAME_W=$((room - UPDATES_VER_W))
    if ((UPDATES_NAME_W < 8)); then
        UPDATES_NAME_W=8
        UPDATES_VER_W=$((room - UPDATES_NAME_W))
        ((UPDATES_VER_W >= 4)) || UPDATES_VER_W=4
    fi
}

# One display row per update: name, versions, then where it comes from and
# any note, cut to the terminal width. Sources and notes are plain ASCII.
update_row_text() {
    local i="$1" tag room note="${U_NOTE[$1]}"
    tag=$(kind_label "${U_KIND[i]}")
    if is_host_update "$i"; then
        note="runs MoreMole${note:+, $note}"
    fi
    [[ -z "$note" ]] || tag+=" ($note)"
    tag=$(mole_terminal_safe_text "$tag")
    room=$((UPDATES_ROW_W - UPDATES_NAME_W - UPDATES_VER_W - 4))
    ((${#tag} <= room)) || tag="${tag:0:$((room - 3))}..."
    printf '%s  %s  %s' "$(fit_width "$(mole_terminal_safe_text "${U_NAME[i]}")" "$UPDATES_NAME_W")" \
        "$(fit_width "$(version_text "$i")" "$UPDATES_VER_W")" "$tag"
}

# Without a terminal, or with --dry-run, list the updates and stop.
print_update_list() {
    measure_columns
    local i
    echo -e "${PURPLE_BOLD}${#U_KIND[@]} updates available${NC}"
    for ((i = 0; i < ${#U_KIND[@]}; i++)); do
        printf '  %s\n' "$(update_row_text "$i")"
    done
}

select_updates() {
    measure_columns
    local -a rows=()
    local i
    for ((i = 0; i < ${#U_KIND[@]}; i++)); do
        rows+=("$(update_row_text "$i")")
    done
    export _MOLE_MENU_SELECT_ALL=true
    # Enter with nothing picked installs nothing, never the row under the cursor.
    local _MOLE_MENU_KEEP_EMPTY=true

    MOLE_SELECTION_RESULT=""
    local rc=0
    paginated_multi_select "Select updates to install" "${rows[@]}" || rc=$?
    unset _MOLE_MENU_SELECT_ALL
    [[ $rc -eq 0 && -n "$MOLE_SELECTION_RESULT" ]]
}

confirm_updates() {
    local -a indices=("$@") hosts=()
    local idx installable=0 has_app=false has_takeover=false has_store=false has_macos=false has_settings=false has_feed=false
    echo -e "${PURPLE_BOLD}Updates to install:${NC}"
    for idx in "${indices[@]}"; do
        if is_host_update "$idx"; then
            hosts+=("$(mole_terminal_safe_text "${U_NAME[idx]}")")
            printf '  %s- %s %s · left out: it runs MoreMole%s\n' "$GRAY" \
                "$(mole_terminal_safe_text "${U_NAME[idx]}")" "$(version_text "$idx")" "$NC"
            continue
        fi
        installable=$((installable + 1))
        printf '  %s%s%s %s %s%s · %s%s\n' "$GREEN" "$ICON_SUCCESS" "$NC" \
            "$(mole_terminal_safe_text "${U_NAME[idx]}")" "$GRAY" "$(version_text "$idx")" "$(kind_label "${U_KIND[idx]}")" "$NC"
        case "${U_KIND[idx]}" in
            app) has_app=true ;;
            takeover) has_takeover=true ;;
            store) has_store=true ;;
            macos) has_macos=true ;;
            macos-settings) has_settings=true ;;
            feed) has_feed=true ;;
        esac
    done
    echo ""
    if [[ "$has_app" == "true" || "$has_takeover" == "true" ]]; then
        echo -e "${GRAY}Apps being updated may quit; save your work in them first.${NC}"
    fi
    if [[ "$has_takeover" == "true" ]]; then
        echo -e "${GRAY}Apps moved to Homebrew are replaced by Homebrew's copy; their settings stay.${NC}"
    fi
    if [[ "$has_store" == "true" ]]; then
        echo -e "${GRAY}App Store updates may ask for your password.${NC}"
    fi
    if [[ "$has_macos" == "true" ]]; then
        echo -e "${GRAY}macOS updates ask for your password.${NC}"
    fi
    if [[ "$has_settings" == "true" ]]; then
        echo -e "${GRAY}Updates that restart the Mac open Software Update in System Settings.${NC}"
    fi
    if [[ "$has_feed" == "true" ]]; then
        echo -e "${GRAY}Apps with their own updater open at the end; it installs the update.${NC}"
    fi
    if [[ ${#hosts[@]} -gt 0 ]]; then
        echo -e "${YELLOW}${ICON_WARNING}${NC} $(host_advice "${hosts[@]}")"
    fi
    # Nothing to ask when everything picked is left out; the summary says why.
    [[ $installable -gt 0 ]] || return 0
    echo -ne "${PURPLE}${ICON_ARROW}${NC} Install ${installable} updates  ${GREEN}Enter${NC} confirm, ${GRAY}ESC${NC} cancel: "

    local confirm
    if ! IFS= read -r -s -n1 confirm; then
        printf '\n'
        return 1
    fi
    case "$confirm" in
        "" | $'\n' | $'\r')
            printf '\r\033[K\n'
            return 0
            ;;
    esac
    printf '\n'
    return 1
}

# The advice for apps left out because MoreMole runs inside them.
host_advice() {
    local names="$1" verb="runs"
    shift
    while [[ $# -gt 0 ]]; do
        names+=", $1"
        verb="run"
        shift
    done
    printf '%s %s MoreMole, so updating from here could end this run: use the app'"'"'s own Check for Updates, or update it from another terminal.' "$names" "$verb"
}

record_update() {
    local idx="$1" ok="$2" reason="${3:-}" note="${4:-}"
    local name="${U_NAME[idx]}"
    if [[ "$ok" == "true" ]]; then
        total_updated=$((total_updated + 1))
        log_operation "$MOLE_CURRENT_COMMAND" "REBUILT" "$name" "updated to ${U_TO[idx]:-latest}, $(kind_label "${U_KIND[idx]}")${note:+, $note}"
    else
        total_failed=$((total_failed + 1))
        UPDATE_FAILURES+=("$name${reason:+: $reason}")
        log_operation "$MOLE_CURRENT_COMMAND" "FAILED" "$name" "${reason:-update failed}"
    fi
}

# Whether a failed cask upgrade stopped only because Homebrew found a copy
# of one of the cask's own files left in its own folder for that cask, as an
# upgrade that stopped partway can leave behind ("It seems there is already
# a Font at '<Caskroom>/<token>/<version>/<file>'"). The retry's --force
# covers the whole upgrade, not only that copy: Homebrew may then overwrite
# any of this cask's own files where it installs them.
leftover_copy_in_caskroom() {
    local tool="$1" token="$2" error caskroom path
    # Homebrew names the cask first: "<token>: It seems there is already ...".
    local re="^([^ ]+: )?It seems there is already an? .+ at '([^']+)'"
    error=$(moremole_run_error_line)
    [[ "$error" =~ $re ]] || return 1
    path="${BASH_REMATCH[2]}"
    caskroom=$("$tool" --caskroom 2> /dev/null) || return 1
    [[ -n "$caskroom" && -n "$token" && "$token" != */* ]] || return 1
    [[ "$path" == "$caskroom/$token/"* && "$path" != *"/../"* && "$path" != *"/.." ]]
}

# Install one update, with the tool's own output shown live.
install_update() {
    local idx="$1" kind="${U_KIND[$1]}" id="${U_ID[$1]}"
    local -a cmd=()
    local tool

    if is_host_update "$idx"; then
        HOST_SKIPPED+=("${U_NAME[idx]}")
        log_operation "$MOLE_CURRENT_COMMAND" "SKIPPED" "${U_NAME[idx]}" "runs MoreMole; update it from another terminal"
        return 0
    fi
    case "$kind" in
        macos-settings)
            SETTINGS_ITEMS+=("${U_NAME[idx]}")
            return 0
            ;;
        feed)
            # The app's own updater checks the download's signature; opening
            # the app hands the update to it.
            if [[ "$id" != /*.app || ! -d "$id" ]]; then
                record_update "$idx" false "app not found"
                return 0
            fi
            OPEN_INDICES+=("$idx")
            return 0
            ;;
        app | tool | takeover)
            if ! tool=$(find_tool brew); then
                record_update "$idx" false "Homebrew not found"
                return 0
            fi
            case "$kind" in
                app) cmd=("$tool" upgrade --cask --greedy "$id") ;;
                tool) cmd=("$tool" upgrade --formula "$id") ;;
                takeover) cmd=("$tool" install --cask --force "$id") ;;
            esac
            ;;
        store)
            if ! tool=$(find_tool mas); then
                record_update "$idx" false "mas not found"
                return 0
            fi
            cmd=("$tool" upgrade "$id")
            ;;
        macos)
            if ! ensure_sudo_session "Installing macOS updates needs your password"; then
                record_update "$idx" false "needs your password"
                return 0
            fi
            cmd=(sudo -n /usr/sbin/softwareupdate --install "$id")
            ;;
        *)
            record_update "$idx" false "unknown kind $kind"
            return 0
            ;;
    esac

    echo -e "${BLUE}${ICON_ARROW} $(mole_terminal_safe_text "${U_NAME[idx]}")${NC} ${GRAY}$(version_text "$idx")${NC}"
    if moremole_run_shown "${cmd[@]}"; then
        record_update "$idx" true
    elif [[ "$kind" == "app" ]] && leftover_copy_in_caskroom "$tool" "$id"; then
        echo -e "${YELLOW}${ICON_WARNING}${NC} Homebrew kept a copy of this app's file from an earlier update in its own folder; trying again with --force, which lets Homebrew overwrite this app's own files."
        cmd=("$tool" upgrade --cask --greedy --force "$id")
        if moremole_run_shown "${cmd[@]}"; then
            RETRIED_NAMES+=("${U_NAME[idx]}")
            record_update "$idx" true "" "retried with --force"
        else
            record_update "$idx" false "$(update_failure_reason "${cmd[0]}")"
        fi
    else
        record_update "$idx" false "$(update_failure_reason "${cmd[0]}")"
    fi
    printf '\n'
}

# Why the last update failed: the tool's own error line, else which tool.
update_failure_reason() {
    local error
    error=$(moremole_run_error_line)
    if [[ -n "$error" ]]; then
        printf '%s' "$error"
    else
        printf '%s reported an error' "${1##*/}"
    fi
}

install_updates() {
    local -a indices=("$@")
    local idx
    MOREMOLE_RUN_ERRORS=$(create_temp_file)
    log_operation_session_start "$MOLE_CURRENT_COMMAND"
    for idx in "${indices[@]}"; do
        [[ "$idx" =~ ^[0-9]+$ && $idx -lt ${#U_KIND[@]} ]] || continue
        install_update "$idx"
    done
    if [[ ${#SETTINGS_ITEMS[@]} -gt 0 ]]; then
        "$UPDATES_OPEN" "$UPDATES_SETTINGS_URL" 2> /dev/null || true
        local item
        for item in "${SETTINGS_ITEMS[@]}"; do
            log_operation "$MOLE_CURRENT_COMMAND" "SKIPPED" "$item" "opened Software Update in System Settings"
        done
    fi
    for idx in "${OPEN_INDICES[@]+"${OPEN_INDICES[@]}"}"; do
        if "$UPDATES_OPEN" "${U_ID[idx]}" 2> /dev/null; then
            OPENED_NAMES+=("${U_NAME[idx]}")
            log_operation "$MOLE_CURRENT_COMMAND" "SKIPPED" "${U_NAME[idx]}" "opened for its own updater"
        else
            record_update "$idx" false "could not open the app"
        fi
    done
    log_operation_session_end "$MOLE_CURRENT_COMMAND" "$total_updated" 0
}

show_updates_summary() {
    local heading="Updates installed"
    local -a details=()
    if [[ $total_failed -gt 0 ]]; then
        heading="Some updates did not install"
    elif [[ $total_updated -eq 0 ]]; then
        heading="Finish in System Settings"
        if [[ ${#OPENED_NAMES[@]} -gt 0 && ${#SETTINGS_ITEMS[@]} -gt 0 ]]; then
            heading="Finish in System Settings and each app"
        elif [[ ${#OPENED_NAMES[@]} -gt 0 ]]; then
            heading="Finish in each app"
        elif [[ ${#SETTINGS_ITEMS[@]} -eq 0 ]]; then
            heading="Nothing installed"
        fi
    fi
    if [[ $total_updated -gt 0 ]]; then
        details+=("Updated ${GREEN}$total_updated${NC}")
    elif [[ ${#SETTINGS_ITEMS[@]} -eq 0 && ${#OPENED_NAMES[@]} -eq 0 ]]; then
        details+=("Nothing was updated")
    fi
    if [[ ${#HOST_SKIPPED[@]} -gt 0 ]]; then
        local -a host_names=()
        local host_name
        for host_name in "${HOST_SKIPPED[@]}"; do
            host_names+=("$(mole_terminal_safe_text "$host_name")")
        done
        details+=("${ICON_WARNING} Left out: $(host_advice "${host_names[@]}")")
    fi
    local item
    for item in "${UPDATE_FAILURES[@]+"${UPDATE_FAILURES[@]}"}"; do
        details+=("${ICON_WARNING} Not updated: $(mole_terminal_safe_text "$item")")
    done
    if [[ ${#SETTINGS_ITEMS[@]} -gt 0 ]]; then
        local names="${SETTINGS_ITEMS[0]}"
        for item in "${SETTINGS_ITEMS[@]:1}"; do
            names+=", $item"
        done
        details+=("Opened Software Update for: $(mole_terminal_safe_text "$names")")
    fi
    if [[ ${#RETRIED_NAMES[@]} -gt 0 ]]; then
        local retried="${RETRIED_NAMES[0]}" retried_name
        for retried_name in "${RETRIED_NAMES[@]:1}"; do
            retried+=", $retried_name"
        done
        details+=("Updated after replacing Homebrew's leftover copy: $(mole_terminal_safe_text "$retried")")
    fi
    if [[ ${#OPENED_NAMES[@]} -gt 0 ]]; then
        local names="${OPENED_NAMES[0]}"
        for item in "${OPENED_NAMES[@]:1}"; do
            names+=", $item"
        done
        details+=("Opened for their own updater: $(mole_terminal_safe_text "$names")")
        details+=("If an app does not offer the update, choose Check for Updates in its menu")
    fi
    print_summary_block "$heading" "${details[@]}"
    printf '\n'
}

main() {
    local arg
    for arg in "$@"; do
        case "$arg" in
            "--help" | "-h")
                show_updates_help
                return 0
                ;;
            "--debug") export MO_DEBUG=1 ;;
            "--dry-run" | "-n") export MOLE_DRY_RUN=1 ;;
            *)
                echo "Unknown option: $arg" >&2
                echo "Use 'moremole updates --help' for supported options." >&2
                return 1
                ;;
        esac
    done

    if [[ ! -x "$UPDATES_HELPER" ]]; then
        echo -e "${RED}${ICON_ERROR}${NC} Software updates needs building first. In your moremole folder, run: make build" >&2
        return 1
    fi

    echo -e "${PURPLE_BOLD}Software updates${NC}"
    printf '\n'
    if [[ "${MOLE_DRY_RUN:-0}" == "1" ]]; then
        echo -e "${YELLOW}${ICON_DRY_RUN} DRY RUN MODE${NC}, nothing will be installed"
        printf '\n'
    fi

    scan_updates
    offer_mas_install
    print_notices

    if [[ ${#U_KIND[@]} -eq 0 ]]; then
        echo -e "${GREEN}${ICON_SUCCESS}${NC} Everything is up to date"
        return 0
    fi

    # Without a terminal there is nobody to choose: list and stop.
    if [[ "${MOLE_DRY_RUN:-0}" == "1" || ! -t 0 || ! -t 1 ]]; then
        print_update_list
        if [[ "${MOLE_DRY_RUN:-0}" != "1" ]]; then
            printf 'Run moremole updates in a terminal to choose updates.\n'
        fi
        return 0
    fi

    hide_cursor
    if ! select_updates; then
        show_cursor
        printf '\n'
        moremole_note_cancel
        return 0
    fi
    show_cursor

    local -a indices=()
    IFS=',' read -ra indices <<< "$MOLE_SELECTION_RESULT"
    if ! confirm_updates "${indices[@]}"; then
        moremole_note_cancel
        return 0
    fi

    install_updates "${indices[@]}"
    show_updates_summary
    [[ $total_failed -eq 0 ]]
}

if [[ "${MOLE_TEST_MODE:-0}" != "1" ]]; then
    main "$@"
fi
