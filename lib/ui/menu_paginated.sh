#!/bin/bash
# Paginated menu with arrow key navigation

set -euo pipefail

# Terminal control functions
enter_alt_screen() {
    if command -v tput > /dev/null 2>&1 && [[ -t 1 ]]; then
        tput smcup 2> /dev/null || true
    fi
}
leave_alt_screen() {
    if command -v tput > /dev/null 2>&1 && [[ -t 1 ]]; then
        tput rmcup 2> /dev/null || true
    fi
}

# Get terminal height with fallback
_pm_get_terminal_height() {
    local height=0

    # Try stty size first (most reliable, real-time)
    # Use </dev/tty to ensure we read from terminal even if stdin is redirected
    if [[ -t 0 ]] || [[ -t 2 ]]; then
        height=$(stty size < /dev/tty 2> /dev/null | awk '{print $1}')
    fi

    # Fallback to tput
    if [[ -z "$height" || $height -le 0 ]]; then
        if command -v tput > /dev/null 2>&1; then
            height=$(tput lines 2> /dev/null || echo "24")
        else
            height=24
        fi
    fi

    echo "$height"
}

# Terminal width: COLUMNS when set, else the terminal itself. tput inside $()
# with its errors hidden can't see the terminal and says 80.
_pm_get_terminal_width() {
    local width="${COLUMNS:-}"
    if [[ ! "$width" =~ ^[0-9]+$ || "$width" -le 0 ]]; then
        width=""
        if [[ -t 0 ]] || [[ -t 2 ]]; then
            width=$(stty size < /dev/tty 2> /dev/null | awk '{print $2}')
        fi
        [[ "$width" =~ ^[0-9]+$ && "$width" -gt 0 ]] || width=$(tput cols 2> /dev/null || echo 80)
    fi
    [[ "$width" =~ ^[0-9]+$ && "$width" -gt 0 ]] || width=80
    echo "$width"
}

# Calculate dynamic items per page based on terminal height
_pm_calculate_items_per_page() {
    local term_height=$(_pm_get_terminal_height)
    # Header, two blank rows and a cursor row, plus the measured controls.
    local reserved=$((4 + ${1:-2}))
    local available=$((term_height - reserved))

    # Ensure minimum and maximum bounds
    if [[ $available -lt 1 ]]; then
        echo 1
    elif [[ $available -gt 50 ]]; then
        echo 50
    else
        echo "$available"
    fi
}

# Parse CSV into newline list (Bash 3.2)
_pm_parse_csv_to_array() {
    local csv="${1:-}"
    if [[ -z "$csv" ]]; then
        return 0
    fi
    local IFS=','
    for _tok in $csv; do
        printf "%s\n" "$_tok"
    done
}

# Main paginated multi-select menu function
paginated_multi_select() {
    local title="$1"
    shift
    local -a items=("$@")
    # A deliberate quit and a real failure both leave through return 1, and
    # callers deciding between "user cancelled" and "selection broke" need to
    # tell them apart. Reset here so a stale value from a previous menu can
    # never masquerade as this run's answer.
    _MOLE_MENU_USER_QUIT=0
    local external_alt_screen=false
    if [[ "${MOLE_MANAGED_ALT_SCREEN:-}" == "1" || "${MOLE_MANAGED_ALT_SCREEN:-}" == "true" ]]; then
        external_alt_screen=true
    fi

    # Validation
    if [[ ${#items[@]} -eq 0 ]]; then
        echo "No items provided" >&2
        return 1
    fi

    local total_items=${#items[@]}
    local items_per_page=$(_pm_calculate_items_per_page)
    local cursor_pos=0
    local top_index=0
    local sort_mode="${MOLE_MENU_SORT_MODE:-date}" # date|name|size
    local sort_reverse="${MOLE_MENU_SORT_REVERSE:-false}"
    local filter_text="" # Filter keyword
    local filter_text_lower=""
    local ignore_initial_enter="${MOLE_MENU_IGNORE_INITIAL_ENTER:-false}"
    # Only callers that opt in get A; selecting every app to remove in one key
    # is not a shortcut the app selector should offer.
    local select_all_enabled="${_MOLE_MENU_SELECT_ALL:-false}"
    # MoreMole: a caller that names a function printing a row's details gets
    # Enter for that row's details screen and D to save the selection.
    local details_fn="${MOLE_MENU_DETAILS_FN:-}"
    if [[ -n "$details_fn" ]] && ! declare -F "$details_fn" > /dev/null 2>&1; then
        details_fn=""
    fi
    # Rows are cut to the terminal's width, so none wraps onto a second line,
    # which would push every later row down and break the redraw.
    local row_width=0
    # MoreMole: a caller can name the columns in a heading line under the
    # search line; the list then starts a row lower.
    local column_header="${MOLE_MENU_COLUMNS_HEADER:-}"
    # MoreMole: MOLE_MENU_INTRO holds lines shown under the title, above the
    # search line, such as a model's description; the caller fits them to
    # the window. MOLE_MENU_SINGLE=true makes a list without checkboxes where
    # Enter returns the row under the cursor (MOLE_MENU_ENTER_LABEL names
    # it). MOLE_MENU_SIDE_RETURN=true makes Left and Right return, setting
    # MOLE_MENU_ACTION to prev or next, as a details screen moves between
    # rows. MOLE_MENU_CANCEL_LABEL names what Q does.
    local -a intro_lines=()
    if [[ -n "${MOLE_MENU_INTRO:-}" ]]; then
        local _intro_line
        while IFS= read -r _intro_line || [[ -n "$_intro_line" ]]; do
            intro_lines+=("$_intro_line")
        done <<< "$MOLE_MENU_INTRO"
    fi
    local single_mode="${MOLE_MENU_SINGLE:-false}" side_return="${MOLE_MENU_SIDE_RETURN:-false}"
    MOLE_MENU_ACTION=""
    local list_top=$((3 + ${#intro_lines[@]}))
    [[ -z "$column_header" ]] || list_top=$((list_top + 1))

    # Metadata (optional)
    # epochs[i]   -> last_used_epoch (numeric) for item i
    # sizekb[i]   -> size in KB (numeric) for item i
    # filter_names[i] -> name for filtering (if not set, use items[i])
    # count_meta[i] -> MoreMole: a count such as downloads, most first, named
    #                by MOLE_MENU_COUNT_LABEL
    local -a epochs=()
    local -a sizekb=()
    local -a count_meta=()
    local has_count_metadata="false"
    local count_label="${MOLE_MENU_COUNT_LABEL:-Count}"
    local -a filter_names=()
    local has_metadata="false"
    local has_epoch_metadata="false"
    local has_size_metadata="false"
    local has_filter_names="false"
    if [[ -n "${MOLE_MENU_META_EPOCHS:-}" ]]; then
        while IFS= read -r v; do
            epochs+=("${v:-0}")
            [[ "${v:-0}" =~ ^[0-9]+$ && "${v:-0}" -gt 0 ]] && has_epoch_metadata="true"
        done < <(_pm_parse_csv_to_array "$MOLE_MENU_META_EPOCHS")
    fi
    if [[ -n "${MOLE_MENU_META_SIZEKB:-}" ]]; then
        while IFS= read -r v; do
            sizekb+=("${v:-0}")
            [[ "${v:-0}" =~ ^[0-9]+$ && "${v:-0}" -gt 0 ]] && has_size_metadata="true"
        done < <(_pm_parse_csv_to_array "$MOLE_MENU_META_SIZEKB")
    fi
    if [[ -n "${MOLE_MENU_META_COUNTS:-}" ]]; then
        while IFS= read -r v; do
            count_meta+=("${v:-0}")
            [[ "${v:-0}" =~ ^[0-9]+$ && "${v:-0}" -gt 0 ]] && has_count_metadata="true"
        done < <(_pm_parse_csv_to_array "$MOLE_MENU_META_COUNTS")
    fi
    if [[ "$has_epoch_metadata" == "true" || "$has_size_metadata" == "true" || "$has_count_metadata" == "true" ]]; then
        has_metadata="true"
    fi
    if [[ -n "${MOLE_MENU_FILTER_NAMES:-}" ]]; then
        while IFS= read -r v; do filter_names+=("$v"); done <<< "$MOLE_MENU_FILTER_NAMES"
        has_filter_names="true"
    fi
    local has_sort_controls=false
    if [[ "$has_metadata" == true || "$has_filter_names" == true ]]; then
        has_sort_controls=true
    fi

    # MoreMole: a caller with a heading line can name its sortable columns in
    # MOLE_MENU_SORT_COLUMNS, one "Label|mode" each, left to right. The mode
    # is one of this menu's own sorts (name, size, date, count), or num or
    # text with the column's keys, one per item joined by the unit separator,
    # at the same place in MOLE_MENU_SORT_KEYS. ":asc" or ":desc" after the
    # mode is the order the column's first Enter sorts in. The mode filter,
    # with keys of 1 and 0, makes Enter show only the rows marked 1, and
    # Enter again all of them; MOLE_MENU_COLUMN_FILTERS lists the labels of
    # filters that start on. S moves into the heading line: Left and Right
    # pick a column, Enter sorts by it (or filters) and Enter again
    # reverses, Down goes back to the list.
    local -a sort_col_label=() sort_col_pos=() sort_col_mode=() sort_col_type=() sort_col_first=() sort_col_keys=() col_filter_on=()
    local sort_col_count=0 header_focus=false header_col=0
    # Until S is used in this list, the heading line ends with a hint that
    # says how to sort; MOLE_MENU_HEADINGS_USED carries that across reopens.
    local headings_used="${MOLE_MENU_HEADINGS_USED:-false}"
    if [[ -n "$column_header" ]]; then
        local _spec _label _mode _dir _from=0 _rest _prefix _s=0 _k
        local -a _keys=()
        for _spec in ${MOLE_MENU_SORT_COLUMNS[@]+"${MOLE_MENU_SORT_COLUMNS[@]}"}; do
            _label="${_spec%%|*}"
            _mode="${_spec#*|}"
            _dir=""
            if [[ "$_mode" == *:* ]]; then
                _dir="${_mode#*:}"
                _mode="${_mode%%:*}"
            fi
            _rest="${column_header:_from}"
            _prefix="${_rest%%"$_label"*}"
            if [[ -n "$_label" && "$_prefix" != "$_rest" ]]; then
                sort_col_label+=("$_label")
                sort_col_pos+=($((_from + ${#_prefix})))
                _from=$((_from + ${#_prefix} + ${#_label}))
                case "$_mode" in
                    num | text | filter)
                        sort_col_mode+=("col:$sort_col_count")
                        sort_col_type+=("$_mode")
                        _keys=()
                        IFS=$'\x1f' read -r -a _keys <<< "${MOLE_MENU_SORT_KEYS[_s]:-}"
                        for ((_k = 0; _k < total_items; _k++)); do
                            sort_col_keys[sort_col_count * total_items + _k]="${_keys[_k]:-}"
                        done
                        ;;
                    *)
                        sort_col_mode+=("$_mode")
                        sort_col_type+=("")
                        ;;
                esac
                sort_col_first+=("$_dir")
                if [[ "$_mode" == "filter" && ",${MOLE_MENU_COLUMN_FILTERS:-}," == *",$_label,"* ]]; then
                    col_filter_on+=(true)
                else
                    col_filter_on+=(false)
                fi
                sort_col_count=$((sort_col_count + 1))
            fi
            _s=$((_s + 1))
        done
    fi
    ((sort_col_count == 0)) || has_sort_controls=true

    sort_mode_available() {
        case "$1" in
            date) [[ "$has_epoch_metadata" == "true" ]] ;;
            size) [[ "$has_size_metadata" == "true" ]] ;;
            count) [[ "$has_count_metadata" == "true" ]] ;;
            name) return 0 ;;
            col:*) [[ "${1#col:}" =~ ^[0-9]+$ && ${1#col:} -lt $sort_col_count && ("${sort_col_type[${1#col:}]}" == "num" || "${sort_col_type[${1#col:}]}" == "text") ]] ;;
            *) return 1 ;;
        esac
    }

    # Whether a sort, with sort_reverse as it is, runs from small to large:
    # dates oldest first, sizes and counts largest first, the rest A-Z.
    sort_runs_ascending() {
        local ascending=true
        case "$1" in
            size | count) ascending=false ;;
        esac
        if [[ "$sort_reverse" == "true" ]]; then
            [[ "$ascending" != "true" ]]
        else
            [[ "$ascending" == "true" ]]
        fi
    }

    normalize_sort_mode() {
        sort_mode_available "$sort_mode" && return 0
        if [[ "$has_epoch_metadata" == "true" ]]; then
            sort_mode="date"
        elif [[ "$has_size_metadata" == "true" ]]; then
            sort_mode="size"
        elif [[ "$has_count_metadata" == "true" ]]; then
            sort_mode="count"
        else
            sort_mode="name"
        fi
    }

    cycle_sort_mode() {
        local candidate
        # Date, count, name, size, and round again; a list without a count
        # goes date, name, size as before.
        case "$sort_mode" in
            date) set -- count name size date ;;
            count) set -- name size date count ;;
            name) set -- size date count name ;;
            size) set -- date count name size ;;
            *) set -- date count name size ;;
        esac

        for candidate in "$@"; do
            if sort_mode_available "$candidate"; then
                sort_mode="$candidate"
                return 0
            fi
        done
        sort_mode="name"
    }

    # App names alone support name sorting, even before size/date metadata is
    # available. Generic callers without metadata retain their input order.
    if [[ "$sort_mode" == col:* ]] && sort_mode_available "$sort_mode"; then
        : # MoreMole: a column sort the caller asked for
    elif [[ "$has_metadata" == "false" ]]; then
        sort_mode="name"
    else
        normalize_sort_mode
    fi

    # Index mappings
    local -a orig_indices=()
    local -a view_indices=()
    local -a filter_targets_lower=()
    local has_ascii_lowercase=false
    declare -f mole_ascii_lowercase > /dev/null 2>&1 && has_ascii_lowercase=true
    local i
    for ((i = 0; i < total_items; i++)); do
        orig_indices[i]=$i
        view_indices[i]=$i
        local filter_target
        if [[ $has_filter_names == true && -n "${filter_names[i]:-}" ]]; then
            filter_target="${filter_names[i]}"
        else
            filter_target="${items[i]}"
        fi
        local filter_target_lower
        # Runs once per item before the first draw; skip the per-item fork
        # when base.sh is loaded. Both produce the bytes LC_ALL=C tr does.
        if [[ $has_ascii_lowercase == true ]]; then
            mole_ascii_lowercase filter_target_lower "$filter_target"
        else
            filter_target_lower=$(printf "%s" "$filter_target" | LC_ALL=C tr '[:upper:]' '[:lower:]')
        fi
        filter_targets_lower[i]="$filter_target_lower"
    done

    local -a selected=()
    local selected_count=0 # Cache selection count to avoid O(n) loops on every draw

    # Initialize selection array
    for ((i = 0; i < total_items; i++)); do
        selected[i]=false
    done

    if [[ -n "${MOLE_PRESELECTED_INDICES:-}" ]]; then
        local cleaned_preselect="${MOLE_PRESELECTED_INDICES//[[:space:]]/}"
        local -a initial_indices=()
        IFS=',' read -ra initial_indices <<< "$cleaned_preselect"
        for idx in "${initial_indices[@]}"; do
            if [[ "$idx" =~ ^[0-9]+$ && $idx -ge 0 && $idx -lt $total_items ]]; then
                # Only count if not already selected (handles duplicates)
                if [[ ${selected[idx]} != true ]]; then
                    selected[idx]=true
                    selected_count=$((selected_count + 1))
                fi
            fi
        done
    fi

    # Preserve original TTY settings so we can restore them reliably
    local original_stty=""
    if [[ -t 0 ]] && command -v stty > /dev/null 2>&1; then
        original_stty=$(stty -g 2> /dev/null || echo "")
    fi

    restore_terminal() {
        show_cursor
        if [[ -n "${original_stty-}" ]]; then
            stty "${original_stty}" 2> /dev/null || stty sane 2> /dev/null || stty echo icanon 2> /dev/null || true
        else
            stty sane 2> /dev/null || stty echo icanon 2> /dev/null || true
        fi
        if [[ "${external_alt_screen:-false}" == false ]]; then
            leave_alt_screen
        fi
    }

    # Save the caller's EXIT/INT/TERM traps before overriding them. Restoring
    # rather than clearing on exit keeps an outer handler alive, e.g.
    # bin/uninstall.sh arms `trap cleanup EXIT` whose only job is writing the
    # session-end operation log; a bare `trap - EXIT` here dropped it silently.
    local _menu_saved_exit _menu_saved_int _menu_saved_term
    _menu_saved_exit=$(trap -p EXIT)
    _menu_saved_int=$(trap -p INT)
    _menu_saved_term=$(trap -p TERM)
    # Uses :- defaults: _pm_cleanup() is the EXIT trap and may fire once more at
    # shell exit after this function has returned and the saved-trap locals
    # are gone. Degrading to `trap -` then is harmless (the caller's trap was
    # already restored on the normal-exit path below).
    # shellcheck disable=SC2329
    _menu_restore_traps() {
        if [[ -n "${_menu_saved_exit:-}" ]]; then eval "${_menu_saved_exit}"; else trap - EXIT; fi
        if [[ -n "${_menu_saved_int:-}" ]]; then eval "${_menu_saved_int}"; else trap - INT; fi
        if [[ -n "${_menu_saved_term:-}" ]]; then eval "${_menu_saved_term}"; else trap - TERM; fi
    }

    # Cleanup function
    _pm_cleanup() {
        # The EXIT trap can fire after the menu returned, when its state is gone.
        [[ -z "${sort_col_count+x}" ]] || _pm_export_state
        _menu_restore_traps
        unset MOLE_READ_KEY_FORCE_CHAR
        export MOLE_MENU_SORT_MODE="${sort_mode:-name}"
        export MOLE_MENU_SORT_REVERSE="${sort_reverse:-false}"
        restore_terminal
    }

    # Interrupt handler
    # shellcheck disable=SC2329
    _pm_handle_interrupt() {
        _pm_cleanup
        exit 130 # Standard exit code for Ctrl+C
    }

    trap _pm_cleanup EXIT
    trap _pm_handle_interrupt INT TERM

    # Setup terminal - preserve interrupt character
    stty -echo -icanon intr ^C 2> /dev/null || true
    if [[ $external_alt_screen == false ]]; then
        enter_alt_screen
        # Clear screen once on entry to alt screen
        printf "\033[2J\033[H" >&2
    else
        printf "\033[H" >&2
    fi
    hide_cursor

    # Helper functions
    _strip_ansi_len() {
        local text="$1"
        local stripped
        stripped=$(printf "%s" "$text" | LC_ALL=C awk '{gsub(/\033\[[0-9;]*[A-Za-z]/,""); print}' || true)
        [[ -z "$stripped" ]] && stripped="$text"
        # These controls use ASCII and single-cell arrows. Count UTF-8
        # characters even when the caller (including slim) uses LC_ALL=C.
        local LC_ALL=en_US.UTF-8
        printf "%d" "${#stripped}"
    }

    # Print footer lines wrapping only at separators
    _print_wrapped_controls() {
        local sep="$1"
        shift
        local -a segs=("$@")

        local cols
        cols=$(_pm_get_terminal_width)

        local line="" s candidate
        local clear_line=$'\r\033[2K'
        for s in "${segs[@]}"; do
            if [[ -z "$line" ]]; then
                candidate="$s"
            else
                candidate="$line${sep}${s}"
            fi
            local candidate_len
            candidate_len=$(_strip_ansi_len "$candidate")
            [[ -z "$candidate_len" ]] && candidate_len=0
            if [[ -n "$line" ]] && ((candidate_len > cols)); then
                printf "%s%s\n" "$clear_line" "$line" >&2
                line="$s"
            else
                line="$candidate"
            fi
        done
        printf "%s%s\n" "$clear_line" "$line" >&2
    }

    local sort_cache_key=""
    local -a sorted_indices_cache=()
    local filter_cache_key=""
    local filter_cache_text_lower=""
    local -a filter_cache_indices=()

    ensure_sorted_indices() {
        local requested_key="${sort_mode}:${sort_reverse}:${has_epoch_metadata}:${has_size_metadata}:${has_count_metadata}"
        if [[ "$requested_key" == "$sort_cache_key" && ${#sorted_indices_cache[@]} -gt 0 ]]; then
            return
        fi

        if [[ "$has_sort_controls" == "false" ]]; then
            sorted_indices_cache=("${orig_indices[@]}")
            sort_cache_key="$requested_key"
            return
        fi

        # Build sort key once; filtering should reuse this cached order.
        local sort_key
        if [[ "$sort_mode" == col:* ]]; then
            # MoreMole: a column's own keys, small to large unless reversed.
            if [[ "${sort_col_type[${sort_mode#col:}]}" == "num" ]]; then
                sort_key="-k1,1n"
                [[ "$sort_reverse" == "true" ]] && sort_key="-k1,1nr"
            else
                sort_key="-k1,1f"
                [[ "$sort_reverse" == "true" ]] && sort_key="-k1,1fr"
            fi
        elif [[ "$sort_mode" == "date" ]]; then
            # Date: ascending by default (oldest first)
            sort_key="-k1,1n"
            [[ "$sort_reverse" == "true" ]] && sort_key="-k1,1nr"
        elif [[ "$sort_mode" == "size" || "$sort_mode" == "count" ]]; then
            # Size and count: descending by default (largest first)
            sort_key="-k1,1nr"
            [[ "$sort_reverse" == "true" ]] && sort_key="-k1,1n"
        else
            # Name: ascending by default (A to Z)
            sort_key="-k1,1f"
            [[ "$sort_reverse" == "true" ]] && sort_key="-k1,1fr"
        fi

        local tmpfile
        tmpfile=$(mktemp 2> /dev/null) || tmpfile=""
        if [[ -n "$tmpfile" ]]; then
            local k id
            for id in "${orig_indices[@]}"; do
                case "$sort_mode" in
                    date) k="${epochs[id]:-0}" ;;
                    size) k="${sizekb[id]:-0}" ;;
                    count) k="${count_meta[id]:-0}" ;;
                    col:*)
                        k="${sort_col_keys[${sort_mode#col:} * total_items + id]:-}"
                        k="${k//$'\t'/ }"
                        [[ "${sort_col_type[${sort_mode#col:}]}" != "num" || "$k" =~ ^-?[0-9]+$ ]] || k=0
                        ;;
                    name | *)
                        # Full names, not the truncated, padded display row.
                        k="${filter_targets_lower[id]}"
                        k="${k//$'\t'/ }"
                        ;;
                esac
                printf "%s\t%s\n" "$k" "$id" >> "$tmpfile"
            done

            sorted_indices_cache=()
            while IFS=$'\t' read -r _key _id; do
                [[ -z "$_id" ]] && continue
                sorted_indices_cache+=("$_id")
            done < <(LC_ALL=C sort -t $'\t' $sort_key -k2,2n -- "$tmpfile" 2> /dev/null)

            rm -f "$tmpfile"
        else
            sorted_indices_cache=("${orig_indices[@]}")
        fi
        sort_cache_key="$requested_key"
    }

    # Rebuild the view_indices applying filter over cached sort order
    rebuild_view() {
        ensure_sorted_indices

        if [[ -n "$filter_text_lower" ]]; then
            local -a source_indices=()
            if [[ "$filter_cache_key" == "$sort_cache_key" &&
                "$filter_text_lower" == "$filter_cache_text_lower"* &&
                ${#filter_cache_indices[@]} -gt 0 ]]; then
                source_indices=("${filter_cache_indices[@]}")
            else
                if [[ ${#sorted_indices_cache[@]} -gt 0 ]]; then
                    source_indices=("${sorted_indices_cache[@]}")
                else
                    source_indices=()
                fi
            fi

            view_indices=()
            local id
            for id in "${source_indices[@]}"; do
                if [[ "${filter_targets_lower[id]:-}" == *"$filter_text_lower"* ]]; then
                    view_indices+=("$id")
                fi
            done

            filter_cache_key="$sort_cache_key"
            filter_cache_text_lower="$filter_text_lower"
            if [[ ${#view_indices[@]} -gt 0 ]]; then
                filter_cache_indices=("${view_indices[@]}")
            else
                filter_cache_indices=()
            fi
        else
            if [[ ${#sorted_indices_cache[@]} -gt 0 ]]; then
                view_indices=("${sorted_indices_cache[@]}")
            else
                view_indices=()
            fi
            filter_cache_key="$sort_cache_key"
            filter_cache_text_lower=""
            if [[ ${#view_indices[@]} -gt 0 ]]; then
                filter_cache_indices=("${view_indices[@]}")
            else
                filter_cache_indices=()
            fi
        fi

        # MoreMole: columns filtering the list keep only their rows marked 1.
        local _c _id
        local -a _kept=()
        for ((_c = 0; _c < sort_col_count; _c++)); do
            [[ "${col_filter_on[_c]}" == true ]] || continue
            _kept=()
            for _id in ${view_indices[@]+"${view_indices[@]}"}; do
                [[ "${sort_col_keys[_c * total_items + _id]:-}" != "1" ]] || _kept+=("$_id")
            done
            view_indices=(${_kept[@]+"${_kept[@]}"})
        done

        # Clamp cursor into visible range
        local visible_count=${#view_indices[@]}
        local max_top
        if [[ $visible_count -gt $items_per_page ]]; then
            max_top=$((visible_count - items_per_page))
        else
            max_top=0
        fi
        [[ $top_index -gt $max_top ]] && top_index=$max_top
        local current_visible=$((visible_count - top_index))
        [[ $current_visible -gt $items_per_page ]] && current_visible=$items_per_page
        if [[ $cursor_pos -ge $current_visible ]]; then
            cursor_pos=$((current_visible > 0 ? current_visible - 1 : 0))
        fi
        [[ $cursor_pos -lt 0 ]] && cursor_pos=0
    }

    # MoreMole: a list opened again comes back as it was left: its search
    # (MOLE_MENU_SEARCH) and the row under the cursor (MOLE_MENU_START_ITEM,
    # an item's index); _pm_export_state hands them back.
    if [[ -n "${MOLE_MENU_SEARCH:-}" ]]; then
        filter_text="$MOLE_MENU_SEARCH"
        filter_text_lower=$(printf '%s' "$filter_text" | LC_ALL=C tr '[:upper:]' '[:lower:]')
    fi

    # Initial view (default sort)
    rebuild_view

    if [[ "${MOLE_MENU_START_ITEM:-}" =~ ^[0-9]+$ ]]; then
        local _pos
        for ((_pos = 0; _pos < ${#view_indices[@]}; _pos++)); do
            [[ "${view_indices[_pos]}" == "$MOLE_MENU_START_ITEM" ]] || continue
            if ((_pos >= items_per_page)); then
                top_index=$((_pos - items_per_page / 2))
                local _max_top=$((${#view_indices[@]} - items_per_page))
                ((top_index <= _max_top)) || top_index=$_max_top
                ((top_index >= 0)) || top_index=0
            fi
            cursor_pos=$((_pos - top_index))
            break
        done
    fi

    # MoreMole: what a caller opening this list again needs to bring it
    # back as it was left.
    _pm_export_state() {
        [[ $sort_col_count -gt 0 || "$single_mode" == true || "$side_return" == true ]] || return 0
        local _c _filters="" _order=""
        for ((_c = 0; _c < sort_col_count; _c++)); do
            [[ "${col_filter_on[_c]}" != true ]] || _filters+="${_filters:+,}${sort_col_label[_c]}"
        done
        _order=$(
            IFS=','
            printf '%s' "${view_indices[*]-}"
        )
        export MOLE_MENU_SEARCH="$filter_text"
        export MOLE_MENU_COLUMN_FILTERS="$_filters"
        export MOLE_MENU_VIEW_ORDER="$_order"
        export MOLE_MENU_START_ITEM="${view_indices[top_index + cursor_pos]:-}"
        export MOLE_MENU_HEADINGS_USED="$headings_used"
    }

    render_item() {
        # $1: visible row index (0..items_per_page-1 in current window)
        # $2: is_current flag
        local vrow=$1 is_current=$2
        local idx=$((top_index + vrow))
        local real="${view_indices[idx]:--1}"
        [[ $real -lt 0 ]] && return
        local checkbox="$ICON_EMPTY"
        [[ ${selected[real]} == true ]] && checkbox="$ICON_SOLID"
        local _pm_row="${items[real]}"
        _pm_fit_row

        if [[ "$single_mode" == true ]]; then
            if [[ $is_current == true ]]; then
                printf "\r\033[2K${CYAN}${ICON_ARROW} %s${NC}\n" "$_pm_row" >&2
            else
                printf "\r\033[2K  %s\n" "$_pm_row" >&2
            fi
        elif [[ $is_current == true ]]; then
            printf "\r\033[2K${CYAN}${ICON_ARROW} %s %s${NC}\n" "$checkbox" "$_pm_row" >&2
        else
            printf "\r\033[2K  %s %s\n" "$checkbox" "$_pm_row" >&2
        fi
    }

    # Cut _pm_row to row_width. A byte count is never less than the display
    # width, so most rows are measured without a fork. Rows with color codes
    # are left alone, as their width can't be measured.
    _pm_row_bytes() {
        local LC_ALL=C
        _pm_bytes=${#1}
        # Three-byte characters led by 0xE2 (dashes, arrows, dots, boxes) are
        # one cell wide, though the width helper counts every three-byte
        # character as two, as for CJK.
        local _pm_rest="${1//$'\xe2'??/}"
        _pm_narrow3=$(((_pm_bytes - ${#_pm_rest}) / 3))
    }
    _pm_row_chars() {
        local LC_ALL=en_US.UTF-8
        _pm_chars=${#1}
    }
    _pm_fit_row() {
        ((row_width > 0)) || return 0
        local _pm_bytes=0 _pm_narrow3=0 _pm_chars=0
        _pm_row_bytes "$_pm_row"
        ((_pm_bytes > row_width)) || return 0
        [[ "$_pm_row" != *$'\033'* ]] || return 0
        # Its width without a fork: one cell a character, plus one more for
        # each wide (CJK) character, counted as the width helper does.
        _pm_row_chars "$_pm_row"
        (((_pm_chars + (_pm_bytes - _pm_chars - 2 * _pm_narrow3) / 2) > row_width)) || return 0
        _pm_row=$(truncate_by_display_width "$_pm_row" "$row_width")
    }

    # The details screen for the row under the cursor: the arrow keys show
    # the next or previous row's, Space selects it, any other key goes back
    # to the list with the cursor on the row last shown.
    _pm_show_details() {
        local pos=$((top_index + cursor_pos)) real dkey mark cols
        local last=$((${#view_indices[@]} - 1))
        cols=$(_pm_get_terminal_width)
        ((cols > 10)) || cols=80
        while true; do
            real="${view_indices[pos]}"
            mark="$ICON_EMPTY Not selected"
            [[ ${selected[real]} == true ]] && mark="$ICON_SOLID Selected"
            printf "\033[2J\033[H" >&2
            # The title is cut so the line never wraps.
            local _where _title="$title"
            _where="$((pos + 1)) of $((last + 1)) · $mark"
            if ((${#_title} + ${#_where} + 2 > cols)); then
                _title=$(truncate_by_display_width "$_title" "$((cols - ${#_where} - 3))")
            fi
            printf "${PURPLE_BOLD}%s${NC}  ${GRAY}%s${NC}\n\n" "$_title" "$_where" >&2
            # The function gets the width to wrap its lines to.
            MOLE_MENU_DETAILS_WIDTH="$cols" "$details_fn" "$real" >&2 || true
            printf '\n%b\n' "${GRAY}${ICON_NAV_UP}${ICON_NAV_DOWN} Previous, next${NC} ${GRAY}|${NC} ${GRAY}Space Select${NC} ${GRAY}|${NC} ${GRAY}Enter Back${NC} ${GRAY}|${NC} ${GRAY}Esc Back${NC}" >&2
            while ! dkey=$(read_key 1); do :; done
            drain_pending_input
            case "$dkey" in
                SPACE)
                    if [[ ${selected[real]} == true ]]; then
                        selected[real]=false
                        ((selected_count--))
                    else
                        selected[real]=true
                        selected_count=$((selected_count + 1))
                    fi
                    continue
                    ;;
                DOWN)
                    ((pos >= last)) || pos=$((pos + 1))
                    continue
                    ;;
                UP)
                    ((pos <= 0)) || pos=$((pos - 1))
                    continue
                    ;;
            esac
            break
        done
        if ((pos < top_index)); then
            top_index=$pos
        elif ((pos >= top_index + items_per_page)); then
            top_index=$((pos - items_per_page + 1))
        fi
        cursor_pos=$((pos - top_index))
        printf "\033[2J" >&2
        return 0
    }

    draw_header() {
        printf "\033[1;1H" >&2
        # MoreMole: the title stays on the first row and the search line
        # always shows on the second, where the list used to leave a gap.
        local _count_text _c _shown=""
        for ((_c = 0; _c < sort_col_count; _c++)); do
            [[ "${col_filter_on[_c]}" != true ]] || _shown+="${_shown:+, }${sort_col_label[_c]}"
        done
        if [[ "$single_mode" == true && $total_items -eq 1 ]]; then
            _count_text=""
        elif [[ "$single_mode" == true ]]; then
            _count_text="${#view_indices[@]} of $total_items"
        else
            _count_text="$selected_count/$total_items selected"
        fi
        [[ -z "$_shown" ]] || _count_text="$_shown only · $_count_text"
        printf "\r\033[2K${PURPLE_BOLD}%s${NC}  ${GRAY}%s${NC}\n" "${title}" "$_count_text" >&2
        local _intro_line
        for _intro_line in ${intro_lines[@]+"${intro_lines[@]}"}; do
            printf "\r\033[2K%s${NC}\n" "$_intro_line" >&2
        done
        if [[ -n "$filter_text" ]]; then
            local marker=""
            [[ -n "${MOLE_READ_KEY_FORCE_CHAR:-}" ]] && marker="_"
            local counts="(${#view_indices[@]}/$total_items; $selected_count selected)"
            local cols
            cols=$(_pm_get_terminal_width)
            local query_width=$((cols - ${#counts} - ${#marker} - 12))
            ((query_width < 1)) && query_width=1
            # Keep the newest characters of a long query visible while typing.
            local query_display="$filter_text" query_len
            query_len=$(get_display_width "$query_display")
            if ((query_len > query_width)); then
                query_display="${query_display:$((query_len - query_width + 3))}"
                while [[ -n "$query_display" ]] && (($(get_display_width "$query_display") + 3 > query_width)); do
                    query_display="${query_display:1}"
                done
                query_display="...$query_display"
            fi
            printf "\r\033[2K${YELLOW}/ Search: %s%s${NC}  ${GRAY}%s${NC}\n" "$query_display" "$marker" "$counts" >&2
        elif [[ -n "${MOLE_READ_KEY_FORCE_CHAR:-}" ]]; then
            printf '%b' "\r\033[2K${YELLOW}/ Search: _ ${NC}${GRAY}(type to search)${NC}\n" >&2
        else
            printf '%b' "\r\033[2K${GRAY}Search: press / and type${NC}\n" >&2
        fi
        if [[ -n "$column_header" ]]; then
            # Lined up with the rows: past the arrow, and the checkbox.
            local _indent="    "
            [[ "$single_mode" != true ]] || _indent="  "
            if ((sort_col_count > 0)); then
                printf "\r\033[2K%s${GRAY}%s${NC}\n" "$_indent" "$(_pm_column_header_text)" >&2
            else
                local _pm_row="$column_header"
                _pm_fit_row
                printf "\r\033[2K%s${GRAY}%s${NC}\n" "$_indent" "$_pm_row" >&2
            fi
        fi
    }

    # MoreMole: the heading line with the sorted column in white and an
    # arrow after it (up for small to large), and the column under the cursor
    # in reverse, cut to the row width like the rows.
    _pm_column_header_text() {
        local plain="$column_header" limit=$((row_width > 1 ? row_width - 1 : 0))
        ((limit == 0 || ${#plain} <= limit)) || plain="${plain:0:limit}"
        local out="" prev=0 c pos label end arrow
        for ((c = 0; c < sort_col_count; c++)); do
            pos=${sort_col_pos[c]}
            label="${sort_col_label[c]}"
            end=$((pos + ${#label}))
            ((end <= ${#plain})) || continue
            out+="${plain:prev:pos-prev}"
            if [[ "$header_focus" == true && $c -eq $header_col ]]; then
                out+="${NC}"$'\033[7m'"${label}${NC}${GRAY}"
            elif [[ "${sort_col_mode[c]}" == "$sort_mode" || "${col_filter_on[c]}" == true ]]; then
                out+="${NC}${label}${GRAY}"
            else
                out+="$label"
            fi
            prev=$end
            arrow=""
            if [[ "${col_filter_on[c]}" == true ]]; then
                arrow="●"
            elif [[ "${sort_col_mode[c]}" == "$sort_mode" ]]; then
                arrow="▼"
                sort_runs_ascending "$sort_mode" && arrow="▲"
            fi
            if [[ -n "$arrow" ]]; then
                out+="$arrow"
                [[ "${plain:end:1}" != " " ]] || prev=$((end + 1))
            fi
        done
        out+="${plain:prev}"
        # The hint, when it fits the row after the headings.
        local hint="S: sort by a column"
        if [[ "$headings_used" != true && "$header_focus" != true ]] && ((limit == 0 || ${#plain} + 4 + ${#hint} <= limit)); then
            out+="    ${NC}"$'\033[2m'"${hint}${NC}${GRAY}"
        fi
        printf '%s' "$out"
    }

    # MoreMole: Enter on a heading sorts by its column, and reverses a column
    # already sorted by; a new column starts in the order its spec names.
    _pm_sort_by_column() {
        local c="$1" mode first
        mode="${sort_col_mode[c]}"
        if [[ "${sort_col_type[c]}" == "filter" ]]; then
            if [[ "${col_filter_on[c]}" == true ]]; then col_filter_on[c]=false; else col_filter_on[c]=true; fi
            rebuild_view
            cursor_pos=0
            top_index=0
            return 0
        fi
        sort_mode_available "$mode" || return 0
        if [[ "$sort_mode" == "$mode" ]]; then
            if [[ "$sort_reverse" == "true" ]]; then sort_reverse=false; else sort_reverse=true; fi
        else
            sort_mode="$mode"
            sort_reverse=false
            first="${sort_col_first[c]}"
            if [[ -n "$first" ]]; then
                if sort_runs_ascending "$mode"; then
                    [[ "$first" != "desc" ]] || sort_reverse=true
                else
                    [[ "$first" != "asc" ]] || sort_reverse=true
                fi
            fi
        fi
        rebuild_view
        cursor_pos=0
        top_index=0
    }

    # Handle filter character input (reduces code duplication)
    # Returns 0 if character was handled, 1 if not in filter mode
    handle_filter_char() {
        local char="$1"
        if [[ -z "${MOLE_READ_KEY_FORCE_CHAR:-}" ]]; then
            return 1
        fi
        if [[ "$char" =~ ^[[:print:]]$ ]]; then
            local char_lower
            char_lower=$(printf "%s" "$char" | LC_ALL=C tr '[:upper:]' '[:lower:]')
            filter_text+="$char"
            filter_text_lower+="$char_lower"
            rebuild_view
            cursor_pos=0
            top_index=0
            need_full_redraw=true
        fi
        return 0
    }

    render_controls() {
        # Build sort status
        local sort_label=""
        case "$sort_mode" in
            date) sort_label="Date" ;;
            name) sort_label="Name" ;;
            size) sort_label="Size" ;;
            count) sort_label="$count_label" ;;
            col:*) sort_label="${sort_col_label[${sort_mode#col:}]}" ;;
        esac
        local sort_status="${sort_label}"

        # Keep core actions visible; secondary hints yield when space is tight.
        local sep=" ${GRAY}|${NC} "

        # Common menu items
        local nav="${GRAY}${ICON_NAV_UP}${ICON_NAV_DOWN}${NC}"
        local page_ctrl="${GRAY}h/l Page${NC}"
        local space_select="${GRAY}Space Select${NC}"
        local select_all="${GRAY}A All${NC}"
        local enter="${GRAY}Enter Save${NC}"
        # MoreMole: the caller names what D does, such as Download.
        [[ -z "$details_fn" ]] || enter="${GRAY}Enter Details${NC}${sep}${GRAY}D ${MOLE_MENU_DONE_LABEL:-Save}${NC}"
        local cancel_label="${GRAY}Q ${MOLE_MENU_CANCEL_LABEL:-Cancel}${NC}"
        # MoreMole: a single-pick list's Enter returns its row.
        [[ "$single_mode" != true ]] || enter="${GRAY}Enter ${MOLE_MENU_ENTER_LABEL:-Open}${NC}"
        [[ "$single_mode" == true || -z "${MOLE_MENU_ENTER_LABEL:-}" || -n "$details_fn" ]] || enter="${GRAY}Enter ${MOLE_MENU_ENTER_LABEL}${NC}"

        local reverse_arrow="↑"
        [[ "$sort_reverse" == "true" ]] && reverse_arrow="↓"
        if [[ "$sort_mode" == "name" || ("$sort_mode" == col:* && "${sort_col_type[${sort_mode#col:}]}" == "text") ]]; then
            reverse_arrow="A-Z"
            [[ "$sort_reverse" == "true" ]] && reverse_arrow="Z-A"
        fi

        local sort_ctrl="${GRAY}S ${sort_status}${NC}"
        local order_ctrl="${GRAY}O ${reverse_arrow}${NC}"
        # MoreMole: a list with sortable headings sorts from them; S goes there.
        if ((sort_col_count > 0)); then
            sort_ctrl="${GRAY}S Sort by column${NC}"
            order_ctrl=""
        fi
        local side_ctrl=""
        [[ "$side_return" != true ]] || side_ctrl="${GRAY}← → ${MOLE_MENU_SIDE_LABEL:-Other row}${NC}"
        local filter_ctrl="${GRAY}/ Search${NC}"

        local term_width
        term_width=$(_pm_get_terminal_width)
        local -a controls=() optional_controls=()
        if [[ -n "${MOLE_READ_KEY_FORCE_CHAR:-}" ]]; then
            local -a _segs_filter=("${GRAY}Enter Apply${NC}" "${GRAY}Backspace${NC}" "${GRAY}Ctrl+U Clear${NC}" "${GRAY}Esc Clear${NC}")
            controls=("${_segs_filter[@]}")
            optional_controls=("${GRAY}Ctrl+U Clear${NC}" "${GRAY}Backspace${NC}")
        elif [[ "$header_focus" == true ]]; then
            # MoreMole: the cursor is on the heading line.
            local _enter_head="${GRAY}Enter Sort, again to reverse${NC}"
            if [[ "${sort_col_type[header_col]}" == "filter" ]]; then
                if [[ "${col_filter_on[header_col]}" == true ]]; then
                    _enter_head="${GRAY}Enter Show all${NC}"
                else
                    _enter_head="${GRAY}Enter Show only ${sort_col_label[header_col]}${NC}"
                fi
            fi
            controls=("${GRAY}← → Column${NC}" "$_enter_head" "${GRAY}${ICON_NAV_DOWN} Back to the list${NC}" "$cancel_label")
            optional_controls=("$cancel_label")
        else
            # A single-pick list has no selection, so no Space hint.
            [[ "$single_mode" != true ]] || space_select=""
            local -a _segs=("$nav" "$space_select")
            [[ "$select_all_enabled" == true ]] && _segs+=("$select_all")
            _segs+=("$enter")
            [[ -z "$side_ctrl" ]] || _segs+=("$side_ctrl")
            # Q clears an applied search like Esc, so it only cancels without one.
            [[ -z "$filter_text" ]] && _segs+=("$cancel_label")
            local -a _segs_browse=("$filter_ctrl")
            if [[ "$has_sort_controls" == true && -n "$order_ctrl" ]]; then
                _segs_browse=("$sort_ctrl" "$order_ctrl" "$filter_ctrl")
            elif [[ "$has_sort_controls" == true ]]; then
                _segs_browse=("$sort_ctrl" "$filter_ctrl")
            fi
            [[ -n "$filter_text" ]] && _segs_browse+=("${GRAY}Esc Clear${NC}")
            _segs_browse+=("$page_ctrl")
            controls=("${_segs[@]}" "${_segs_browse[@]}")
            optional_controls=("$page_ctrl" "$nav" "$order_ctrl" "$select_all" "$sort_ctrl" "$filter_ctrl" "$side_ctrl")
        fi
        # Drop the hints this list doesn't have.
        local -a _present=()
        local _ctl
        for _ctl in "${controls[@]}"; do
            [[ -z "$_ctl" ]] || _present+=("$_ctl")
        done
        controls=("${_present[@]}")

        # Drop only hint text, in priority order. The key handlers stay active.
        local optional joined control
        local -a kept=()
        for optional in "${optional_controls[@]}"; do
            joined=""
            for control in "${controls[@]}"; do
                joined+="${joined:+$sep}$control"
            done
            [[ $(_strip_ansi_len "$joined") -gt $term_width ]] || break
            kept=()
            for control in "${controls[@]}"; do
                [[ "$control" == "$optional" ]] || kept+=("$control")
            done
            controls=("${kept[@]}")
        done
        _print_wrapped_controls "$sep" "${controls[@]}"
    }

    # Draw the complete menu
    draw_menu() {
        local controls control_line control_rows=0
        controls=$(render_controls 2>&1)
        while IFS= read -r control_line; do
            control_rows=$((control_rows + 1))
        done <<< "$controls"
        items_per_page=$(_pm_calculate_items_per_page "$((control_rows + list_top - 3))")
        local clear_line=$'\r\033[2K'
        local cols
        cols=$(_pm_get_terminal_width)
        # The arrow, checkbox and spaces before a row, and the last column,
        # which some terminals wrap at.
        row_width=$((cols - 5))
        # A single-pick list has no checkbox, so its rows get two more cells.
        [[ "$single_mode" != true ]] || row_width=$((cols - 3))
        ((row_width >= 10)) || row_width=10

        printf "\033[H" >&2

        draw_header

        # Visible slice
        local visible_total=${#view_indices[@]}
        local visible_count=$((visible_total - top_index))
        [[ $visible_count -gt $items_per_page ]] && visible_count=$items_per_page
        [[ $visible_count -le 0 ]] && visible_count=1
        if [[ $cursor_pos -ge $visible_count ]]; then
            cursor_pos=$((visible_count - 1))
            [[ $cursor_pos -lt 0 ]] && cursor_pos=0
        fi

        # Items for current window
        local start_idx=$top_index
        local end_idx=$((top_index + items_per_page - 1))
        [[ $end_idx -ge $visible_total ]] && end_idx=$((visible_total - 1))

        for ((i = start_idx; i <= end_idx; i++)); do
            [[ $i -lt 0 ]] && continue
            local is_current=false
            [[ $((i - start_idx)) -eq $cursor_pos && "$header_focus" != true ]] && is_current=true
            render_item $((i - start_idx)) $is_current
        done

        # Fill empty slots to clear previous content
        local items_shown=$((end_idx - start_idx + 1))
        [[ $items_shown -lt 0 ]] && items_shown=0
        if [[ $visible_total -eq 0 ]]; then
            printf '%b' "${clear_line}No matches\n" >&2
            items_shown=1
        fi
        for ((i = items_shown; i < items_per_page; i++)); do
            printf '%b' "${clear_line}\n" >&2
        done

        printf '%b' "${clear_line}\n" >&2

        printf '%s\n' "$controls" >&2
        printf '%b' "${clear_line}\033[J" >&2
    }

    # MoreMole: leave the menu with a result (the given rows, or else the
    # selected ones), handing the caller the list's state.
    _pm_finish_selection() {
        local -a _picked=()
        if [[ $# -gt 0 ]]; then
            _picked=("$@")
        else
            local _i
            for ((_i = 0; _i < total_items; _i++)); do
                [[ ${selected[_i]} != true ]] || _picked+=("$_i")
            done
        fi
        _pm_export_state
        _menu_restore_traps
        MOLE_SELECTION_RESULT=$(
            IFS=','
            printf '%s' "${_picked[*]-}"
        )
        unset MOLE_READ_KEY_FORCE_CHAR
        export MOLE_MENU_SORT_MODE="${sort_mode:-name}"
        export MOLE_MENU_SORT_REVERSE="${sort_reverse:-false}"
        restore_terminal
    }

    local need_full_redraw=true

    # Main interaction loop
    while true; do
        if [[ "$need_full_redraw" == "true" ]]; then
            draw_menu
            need_full_redraw=false
        fi

        local key
        # Idle ticks return to this shell once a second, so a TERM or HUP sent
        # to the menu process runs its trap instead of waiting for a keypress.
        if ! key=$(read_key 1); then
            continue
        fi
        if [[ "$ignore_initial_enter" == "true" || "$ignore_initial_enter" == "1" ]]; then
            ignore_initial_enter=false
            if [[ "$key" == "ENTER" ]]; then
                continue
            fi
        fi

        # MoreMole: moving through the list leaves the search line, so Space
        # selects and Enter saves; the search stays applied.
        case "$key" in
            UP | DOWN | LEFT | RIGHT | TOP | BOTTOM)
                if [[ -n "${MOLE_READ_KEY_FORCE_CHAR:-}" ]]; then
                    unset MOLE_READ_KEY_FORCE_CHAR
                    need_full_redraw=true
                fi
                ;;
        esac

        # MoreMole: S moves into the heading line of a list with sortable
        # headings; they replace S and O's own sorting there.
        if [[ ("$key" == "CHAR:s" || "$key" == "CHAR:S") && -z "${MOLE_READ_KEY_FORCE_CHAR:-}" && "$header_focus" != true && $sort_col_count -gt 0 ]]; then
            header_focus=true
            headings_used=true
            header_col=0
            local _c
            for ((_c = 0; _c < sort_col_count; _c++)); do
                [[ "${sort_col_mode[_c]}" != "$sort_mode" ]] || header_col=$_c
            done
            need_full_redraw=true
            continue
        fi
        if [[ "$header_focus" == true ]]; then
            case "$key" in
                LEFT | RIGHT)
                    if [[ "$key" == "LEFT" ]]; then
                        ((header_col == 0)) || header_col=$((header_col - 1))
                    else
                        ((header_col >= sort_col_count - 1)) || header_col=$((header_col + 1))
                    fi
                    # The keys line says what Enter does on this column.
                    need_full_redraw=true
                    continue
                    ;;
                ENTER)
                    _pm_sort_by_column "$header_col"
                    need_full_redraw=true
                    continue
                    ;;
                DOWN)
                    header_focus=false
                    need_full_redraw=true
                    continue
                    ;;
                UP | SPACE | CHAR:s | CHAR:S) continue ;;
                *)
                    # Any other key leaves the heading line and works as usual.
                    header_focus=false
                    need_full_redraw=true
                    ;;
            esac
        fi
        if [[ ("$key" == "CHAR:o" || "$key" == "CHAR:O") && -z "${MOLE_READ_KEY_FORCE_CHAR:-}" && $sort_col_count -gt 0 ]]; then
            continue
        fi

        # MoreMole: Up on the first row goes to the last, and Down on the
        # last to the first, so either end of a long list is one key away.
        if [[ ${#view_indices[@]} -gt 1 && -z "${MOLE_READ_KEY_FORCE_CHAR:-}" ]]; then
            if [[ "$key" == "UP" && $((top_index + cursor_pos)) -eq 0 ]]; then
                key="BOTTOM"
            elif [[ "$key" == "DOWN" && $((top_index + cursor_pos)) -eq $((${#view_indices[@]} - 1)) ]]; then
                key="TOP"
            fi
        fi

        # MoreMole: Left and Right return to the caller, to show another row.
        if [[ "$side_return" == true && ("$key" == "LEFT" || "$key" == "RIGHT") && -z "${MOLE_READ_KEY_FORCE_CHAR:-}" ]]; then
            MOLE_MENU_ACTION=next
            [[ "$key" != "LEFT" ]] || MOLE_MENU_ACTION=prev
            _pm_finish_selection
            return 0
        fi

        # MoreMole: a single-pick list returns the row under the cursor.
        if [[ "$single_mode" == true && -z "${MOLE_READ_KEY_FORCE_CHAR:-}" ]]; then
            case "$key" in
                ENTER)
                    local _idx=$((top_index + cursor_pos))
                    [[ $_idx -lt ${#view_indices[@]} ]] || continue
                    MOLE_MENU_ACTION=open
                    _pm_finish_selection "${view_indices[_idx]}"
                    return 0
                    ;;
                SPACE | CHAR:a | CHAR:A | CHAR:d | CHAR:D) continue ;;
            esac
        fi

        if [[ -n "$details_fn" && -z "${MOLE_READ_KEY_FORCE_CHAR:-}" ]]; then
            case "$key" in
                ENTER) key="DETAILS" ;;
                CHAR:d | CHAR:D) key="ENTER" ;;
            esac
        fi

        case "$key" in
            "DETAILS")
                local idx=$((top_index + cursor_pos))
                if [[ $idx -lt ${#view_indices[@]} ]]; then
                    _pm_show_details "${view_indices[idx]}"
                    need_full_redraw=true
                fi
                ;;
            "QUIT")
                if [[ -n "$filter_text" || -n "${MOLE_READ_KEY_FORCE_CHAR:-}" ]]; then
                    filter_text=""
                    filter_text_lower=""
                    unset MOLE_READ_KEY_FORCE_CHAR
                    rebuild_view
                    cursor_pos=0
                    top_index=0
                    need_full_redraw=true
                else
                    _MOLE_MENU_USER_QUIT=1
                    _pm_cleanup
                    return 1
                fi
                ;;
            "UP")
                if [[ ${#view_indices[@]} -eq 0 ]]; then
                    :
                elif [[ $cursor_pos -gt 0 ]]; then
                    local old_cursor=$cursor_pos
                    ((cursor_pos--))
                    local new_cursor=$cursor_pos

                    if [[ -n "$filter_text" || -n "${MOLE_READ_KEY_FORCE_CHAR:-}" ]]; then
                        draw_header
                    fi

                    local old_row=$((old_cursor + list_top))
                    local new_row=$((new_cursor + list_top))

                    printf "\033[%d;1H" "$old_row" >&2
                    render_item "$old_cursor" false
                    printf "\033[%d;1H" "$new_row" >&2
                    render_item "$new_cursor" true

                    printf "\033[%d;1H" "$((items_per_page + list_top + 1))" >&2

                    continue
                elif [[ $top_index -gt 0 ]]; then
                    ((top_index--))

                    if [[ -n "$filter_text" || -n "${MOLE_READ_KEY_FORCE_CHAR:-}" ]]; then
                        draw_header
                    fi

                    local start_idx=$top_index
                    local end_idx=$((top_index + items_per_page - 1))
                    local visible_total=${#view_indices[@]}
                    [[ $end_idx -ge $visible_total ]] && end_idx=$((visible_total - 1))

                    for ((i = start_idx; i <= end_idx; i++)); do
                        local row=$((i - start_idx + list_top))
                        printf "\033[%d;1H" "$row" >&2
                        local is_current=false
                        [[ $((i - start_idx)) -eq $cursor_pos ]] && is_current=true
                        render_item $((i - start_idx)) $is_current
                    done

                    printf "\033[%d;1H" "$((items_per_page + list_top + 1))" >&2

                    continue
                fi
                ;;
            "DOWN")
                if [[ ${#view_indices[@]} -eq 0 ]]; then
                    :
                else
                    local absolute_index=$((top_index + cursor_pos))
                    local last_index=$((${#view_indices[@]} - 1))
                    if [[ $absolute_index -lt $last_index ]]; then
                        local visible_count=$((${#view_indices[@]} - top_index))
                        [[ $visible_count -gt $items_per_page ]] && visible_count=$items_per_page

                        if [[ $cursor_pos -lt $((visible_count - 1)) ]]; then
                            local old_cursor=$cursor_pos
                            cursor_pos=$((cursor_pos + 1))
                            local new_cursor=$cursor_pos

                            if [[ -n "$filter_text" || -n "${MOLE_READ_KEY_FORCE_CHAR:-}" ]]; then
                                draw_header
                            fi

                            local old_row=$((old_cursor + list_top))
                            local new_row=$((new_cursor + list_top))

                            printf "\033[%d;1H" "$old_row" >&2
                            render_item "$old_cursor" false
                            printf "\033[%d;1H" "$new_row" >&2
                            render_item "$new_cursor" true

                            printf "\033[%d;1H" "$((items_per_page + list_top + 1))" >&2

                            continue
                        elif [[ $((top_index + visible_count)) -lt ${#view_indices[@]} ]]; then
                            top_index=$((top_index + 1))
                            visible_count=$((${#view_indices[@]} - top_index))
                            [[ $visible_count -gt $items_per_page ]] && visible_count=$items_per_page
                            if [[ $cursor_pos -ge $visible_count ]]; then
                                cursor_pos=$((visible_count - 1))
                            fi

                            if [[ -n "$filter_text" || -n "${MOLE_READ_KEY_FORCE_CHAR:-}" ]]; then
                                draw_header
                            fi

                            local start_idx=$top_index
                            local end_idx=$((top_index + items_per_page - 1))
                            local visible_total=${#view_indices[@]}
                            [[ $end_idx -ge $visible_total ]] && end_idx=$((visible_total - 1))

                            for ((i = start_idx; i <= end_idx; i++)); do
                                local row=$((i - start_idx + list_top))
                                printf "\033[%d;1H" "$row" >&2
                                local is_current=false
                                [[ $((i - start_idx)) -eq $cursor_pos ]] && is_current=true
                                render_item $((i - start_idx)) $is_current
                            done

                            printf "\033[%d;1H" "$((items_per_page + list_top + 1))" >&2

                            continue
                        fi
                    fi
                fi
                ;;
            "TOP")
                if [[ ${#view_indices[@]} -gt 0 ]]; then
                    cursor_pos=0
                    top_index=0
                    need_full_redraw=true
                fi
                ;;
            "BOTTOM")
                if [[ ${#view_indices[@]} -gt 0 ]]; then
                    local visible_total=${#view_indices[@]}
                    if [[ $visible_total -gt $items_per_page ]]; then
                        top_index=$((visible_total - items_per_page))
                        cursor_pos=$((items_per_page - 1))
                    else
                        top_index=0
                        cursor_pos=$((visible_total - 1))
                    fi
                    need_full_redraw=true
                fi
                ;;
            "LEFT")
                if [[ ${#view_indices[@]} -gt 0 ]]; then
                    if [[ $top_index -gt 0 ]]; then
                        top_index=$((top_index - items_per_page))
                        [[ $top_index -lt 0 ]] && top_index=0
                    fi
                    cursor_pos=0
                    need_full_redraw=true
                fi
                ;;
            "RIGHT")
                if [[ ${#view_indices[@]} -gt 0 ]]; then
                    local visible_total=${#view_indices[@]}
                    if [[ $((top_index + items_per_page)) -lt $visible_total ]]; then
                        top_index=$((top_index + items_per_page))
                        local _remaining=$((visible_total - top_index))
                        if [[ $_remaining -lt $items_per_page ]]; then
                            top_index=$((visible_total - items_per_page))
                            [[ $top_index -lt 0 ]] && top_index=0
                        fi
                    fi
                    cursor_pos=0
                    need_full_redraw=true
                fi
                ;;
            "SPACE")
                if handle_filter_char " "; then
                    continue
                fi
                local idx=$((top_index + cursor_pos))
                if [[ $idx -lt ${#view_indices[@]} ]]; then
                    local real="${view_indices[idx]}"
                    if [[ ${selected[real]} == true ]]; then
                        selected[real]=false
                        ((selected_count--))
                    else
                        selected[real]=true
                        selected_count=$((selected_count + 1))
                    fi

                    # Incremental update: only redraw header (for count) and current row
                    # Header is at row 1
                    draw_header

                    # Redraw current item row (+3: row 1=header, row 2=blank, row 3=first item)
                    local item_row=$((cursor_pos + list_top))
                    printf "\033[%d;1H" "$item_row" >&2
                    render_item "$cursor_pos" true

                    # Move cursor to footer to avoid visual artifacts (items + header + 2 blanks)
                    printf "\033[%d;1H" "$((items_per_page + list_top + 1))" >&2

                    continue # Skip full redraw
                fi
                ;;
            "CHAR:s" | "CHAR:S")
                if handle_filter_char "${key#CHAR:}"; then
                    : # Handled as filter input
                elif [[ "$has_sort_controls" == "true" ]]; then
                    cycle_sort_mode
                    rebuild_view
                    need_full_redraw=true
                fi
                ;;
            "CHAR:j")
                if handle_filter_char "${key#CHAR:}"; then
                    : # Handled as filter input
                elif [[ ${#view_indices[@]} -gt 0 ]]; then
                    local absolute_index=$((top_index + cursor_pos))
                    local last_index=$((${#view_indices[@]} - 1))
                    if [[ $absolute_index -lt $last_index ]]; then
                        local visible_count=$((${#view_indices[@]} - top_index))
                        [[ $visible_count -gt $items_per_page ]] && visible_count=$items_per_page
                        if [[ $cursor_pos -lt $((visible_count - 1)) ]]; then
                            cursor_pos=$((cursor_pos + 1))
                        elif [[ $((top_index + visible_count)) -lt ${#view_indices[@]} ]]; then
                            top_index=$((top_index + 1))
                        fi
                        need_full_redraw=true
                    fi
                fi
                ;;
            "CHAR:k")
                if handle_filter_char "${key#CHAR:}"; then
                    : # Handled as filter input
                elif [[ ${#view_indices[@]} -gt 0 ]]; then
                    if [[ $cursor_pos -gt 0 ]]; then
                        ((cursor_pos--))
                        need_full_redraw=true
                    elif [[ $top_index -gt 0 ]]; then
                        ((top_index--))
                        need_full_redraw=true
                    fi
                fi
                ;;
            "CHAR:o" | "CHAR:O")
                if handle_filter_char "${key#CHAR:}"; then
                    : # Handled as filter input
                elif [[ "$has_sort_controls" == "true" ]]; then
                    if [[ "$sort_reverse" == "true" ]]; then
                        sort_reverse="false"
                    else
                        sort_reverse="true"
                    fi
                    rebuild_view
                    need_full_redraw=true
                fi
                ;;
            "CHAR:a" | "CHAR:A")
                if handle_filter_char "${key#CHAR:}"; then
                    : # Handled as filter input
                elif [[ "$select_all_enabled" == true && ${#view_indices[@]} -gt 0 ]]; then
                    # Toggle the rows on screen: select them all, or clear them
                    # when every visible row is already selected.
                    local _real _all_selected=true
                    for _real in "${view_indices[@]}"; do
                        if [[ ${selected[_real]} != true ]]; then
                            _all_selected=false
                            break
                        fi
                    done
                    for _real in "${view_indices[@]}"; do
                        if [[ $_all_selected == true ]]; then
                            selected[_real]=false
                            selected_count=$((selected_count - 1))
                        elif [[ ${selected[_real]} != true ]]; then
                            selected[_real]=true
                            selected_count=$((selected_count + 1))
                        fi
                    done
                    need_full_redraw=true
                fi
                ;;
            "CHAR:?")
                if ! handle_filter_char "?"; then
                    export MOLE_READ_KEY_FORCE_CHAR=1
                    need_full_redraw=true
                fi
                ;;
            "CHAR:/")
                # MoreMole: while typing, / is part of the search, as in
                # owner/model; Enter or an arrow key finishes typing.
                if [[ -n "${MOLE_READ_KEY_FORCE_CHAR:-}" ]]; then
                    handle_filter_char "/"
                else
                    export MOLE_READ_KEY_FORCE_CHAR=1
                    need_full_redraw=true
                fi
                ;;
            "DELETE")
                if [[ -n "$filter_text" ]]; then
                    filter_text="${filter_text%?}"
                    filter_text_lower="${filter_text_lower%?}"
                    if [[ -z "$filter_text" ]]; then
                        filter_text_lower=""
                    fi
                    rebuild_view
                    cursor_pos=0
                    top_index=0
                    need_full_redraw=true
                fi
                ;;
            "CLEAR_LINE")
                if [[ -n "$filter_text" ]]; then
                    filter_text=""
                    filter_text_lower=""
                    rebuild_view
                    cursor_pos=0
                    top_index=0
                    need_full_redraw=true
                fi
                ;;
            "CHAR:"*)
                handle_filter_char "${key#CHAR:}" || true
                ;;
            "ENTER")
                if [[ -n "${MOLE_READ_KEY_FORCE_CHAR:-}" ]]; then
                    unset MOLE_READ_KEY_FORCE_CHAR
                    need_full_redraw=true
                    continue
                fi
                # Enter must not submit selections the search hides. Clear the
                # search instead so every selection is on screen before saving.
                if [[ -n "$filter_text" && $selected_count -gt 0 ]]; then
                    local -a _in_view=()
                    local _v _hidden=false
                    for _v in ${view_indices[@]+"${view_indices[@]}"}; do
                        _in_view[_v]=1
                    done
                    for ((i = 0; i < total_items; i++)); do
                        if [[ ${selected[i]} == true && -z "${_in_view[i]:-}" ]]; then
                            _hidden=true
                            break
                        fi
                    done
                    if [[ "$_hidden" == true ]]; then
                        filter_text=""
                        filter_text_lower=""
                        rebuild_view
                        cursor_pos=0
                        top_index=0
                        need_full_redraw=true
                        continue
                    fi
                fi
                [[ ${#view_indices[@]} -eq 0 ]] && continue
                # Smart Enter behavior
                # 1. Check if any items are already selected
                local has_selection=false
                for ((i = 0; i < total_items; i++)); do
                    if [[ ${selected[i]} == true ]]; then
                        has_selection=true
                        break
                    fi
                done

                # 2. If nothing selected, auto-select current item
                if [[ $has_selection == false && "${_MOLE_MENU_KEEP_EMPTY:-false}" != true ]]; then
                    local idx=$((top_index + cursor_pos))
                    if [[ $idx -lt ${#view_indices[@]} ]]; then
                        local real="${view_indices[idx]}"
                        selected[real]=true
                        selected_count=$((selected_count + 1))
                    fi
                fi

                # 3. Confirm and exit with current selections
                local -a selected_indices=()
                for ((i = 0; i < total_items; i++)); do
                    if [[ ${selected[i]} == true ]]; then
                        selected_indices+=("$i")
                    fi
                done

                local final_result=""
                if [[ ${#selected_indices[@]} -gt 0 ]]; then
                    local IFS=','
                    final_result="${selected_indices[*]}"
                fi

                _pm_export_state
                MOLE_MENU_ACTION=save
                _menu_restore_traps
                MOLE_SELECTION_RESULT="$final_result"
                unset MOLE_READ_KEY_FORCE_CHAR
                export MOLE_MENU_SORT_MODE="${sort_mode:-name}"
                export MOLE_MENU_SORT_REVERSE="${sort_reverse:-false}"
                restore_terminal
                return 0
                ;;
        esac

        # Drain any accumulated input after processing (e.g., mouse wheel events)
        # This prevents buffered events from causing jumps, without blocking keyboard input.
        # Search typing is that keyboard input: a paste or fast typing arrives as
        # one queued burst, so draining there would keep only its first character.
        # Any other key still drains, so the unread tail of a partly decoded
        # escape sequence (Shift+Arrow, F5) never lands in the search term.
        case "$key" in
            CHAR:* | SPACE | DELETE)
                if [[ -z "${MOLE_READ_KEY_FORCE_CHAR:-}" ]]; then
                    drain_pending_input
                fi
                ;;
            *) drain_pending_input ;;
        esac
    done
}

# Export function for external use
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "This is a library file. Source it from other scripts." >&2
    exit 1
fi
