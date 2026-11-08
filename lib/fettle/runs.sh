#!/bin/bash
# Fettle: shared by Software updates and Ollama models, which run other tools
# (brew, mas, ollama) with their output on screen and read the notices their
# Go helpers print.

# A copy of what the last fettle_run_shown command printed on standard
# error. Callers set it to a temporary file first.
FETTLE_RUN_ERRORS=""

# Run a command with its output shown live, keeping a copy of what it prints
# on standard error in FETTLE_RUN_ERRORS.
fettle_run_shown() {
    : > "$FETTLE_RUN_ERRORS"
    { "$@" 2>&1 1>&3 3>&- | tee "$FETTLE_RUN_ERRORS" >&2 3>&-; } 3>&1
}

# The tool's own last "Error:" line from that copy, without colors.
fettle_run_error_line() {
    awk -v esc=$'\033' '
        { gsub(esc "\\[[0-9;]*[A-Za-z]", ""); sub(/\r$/, "") }
        /^Error: / { sub(/^Error: /, ""); last = $0 }
        END { print last }
    ' "$FETTLE_RUN_ERRORS" 2> /dev/null || true
}

# Whether the helper sent a notice with this key; callers keep the keys in
# NOTICE_KEYS.
has_notice() {
    local key
    for key in "${NOTICE_KEYS[@]+"${NOTICE_KEYS[@]}"}"; do
        [[ "$key" == "$1" ]] && return 0
    done
    return 1
}
