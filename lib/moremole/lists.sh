#!/bin/bash
# MoreMole: lists that use the shared pick list (lib/ui/menu_paginated.sh),
# which has the search line and sorts A-Z, by size and by date.

# Installer files: pick from INSTALLER_PATHS, INSTALLER_SIZES (bytes) and
# DISPLAY_NAMES, A-Z by file name first. Sets MOLE_SELECTION_RESULT to the
# picked indices; returns 1 when the user goes back.
moremole_select_installers() {
    local -a names=() sizes_kb=() epochs=()
    local i path name mtime
    for ((i = 0; i < ${#DISPLAY_NAMES[@]}; i++)); do
        path="${INSTALLER_PATHS[i]}"
        name="${path##*/}"
        # Homebrew keeps downloads as <sha256>--<name>; sort and search the name.
        [[ "$name" =~ ^[0-9a-f]{64}--(.*) ]] && name="${BASH_REMATCH[1]}"
        names+=("$(installer_display_text "$name")")
        sizes_kb+=("$((${INSTALLER_SIZES[i]:-0} / 1024))")
        mtime=$("$STAT_BSD" -f %m "$path" 2> /dev/null) || mtime=0
        [[ "$mtime" =~ ^[0-9]+$ ]] || mtime=0
        epochs+=("$mtime")
    done

    local MOLE_MENU_FILTER_NAMES MOLE_MENU_META_SIZEKB MOLE_MENU_META_EPOCHS
    MOLE_MENU_FILTER_NAMES=$(printf '%s\n' "${names[@]}")
    MOLE_MENU_META_SIZEKB=$(
        IFS=','
        printf '%s' "${sizes_kb[*]}"
    )
    MOLE_MENU_META_EPOCHS=$(
        IFS=','
        printf '%s' "${epochs[*]}"
    )
    local MOLE_MENU_SORT_MODE=name MOLE_MENU_SORT_REVERSE=false
    # The installer screen already owns the alternate screen.
    local MOLE_MANAGED_ALT_SCREEN=1 _MOLE_MENU_SELECT_ALL=true
    # Enter with nothing picked removes nothing, never the row under the cursor.
    local _MOLE_MENU_KEEP_EMPTY=true

    MOLE_SELECTION_RESULT=""
    paginated_multi_select "Select Installers to Remove" "${DISPLAY_NAMES[@]}" || return 1
    [[ -n "$MOLE_SELECTION_RESULT" ]]
}
