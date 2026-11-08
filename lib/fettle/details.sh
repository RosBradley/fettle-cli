#!/bin/bash
# Fettle: the lines of a pick list's details screen, shared by Ollama
# models and Software updates. The menu (lib/ui/menu_paginated.sh) sets
# MOLE_MENU_DETAILS_WIDTH to the window's width while the screen is drawn.

detail_name() {
    printf '%s%s%s\n\n' "$BLUE" "$(mole_terminal_safe_text "$1")" "$NC"
}

# A label and its value, the value wrapped to the details screen's width
# and lined up under itself.
detail_line() {
    [[ -n "$2" ]] || return 0
    local width=$((${MOLE_MENU_DETAILS_WIDTH:-80} - 16)) line first=true
    ((width >= 20)) || width=20
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$first" == true ]]; then
            printf '%s%-14s%s %s\n' "$GRAY" "$1" "$NC" "$line"
            first=false
        else
            printf '%15s%s\n' "" "$line"
        fi
    done < <(mole_terminal_safe_text "$2" | fold -s -w "$width")
}
