#!/bin/bash
# fettle: MoreMole was renamed Fettle on 2026-11-07. This moves what MoreMole
# kept under its old name to Fettle's place for it, once: the record of the
# models added from Hugging Face, and the cache (model lists, unfinished
# Hugging Face downloads, Homebrew's app list). A move happens only while the
# new place doesn't exist yet, so nothing is merged or written over, and never
# in a dry run. Sourced by lib/fettle/menu.sh and scripts/fettle-install.sh.

fettle_migrate_state() {
    [[ "${MOLE_DRY_RUN:-0}" == "1" ]] && return 0
    local -a pairs=(
        "$HOME/.config/mole/moremole-hf-models" "$HOME/.config/mole/fettle-hf-models"
        "$HOME/Library/Caches/moremole" "$HOME/Library/Caches/fettle"
    )
    local i old new
    for ((i = 0; i < ${#pairs[@]}; i += 2)); do
        old="${pairs[i]}"
        new="${pairs[i + 1]}"
        [[ -e "$old" && ! -L "$old" ]] || continue
        [[ ! -e "$new" && ! -L "$new" ]] || continue
        mv "$old" "$new" 2> /dev/null || continue
        if declare -F log_operation > /dev/null; then
            log_operation "fettle" "REBUILT" "$new" "moved from $old, MoreMole's name for it" 2> /dev/null || true
        fi
    done
    return 0
}
