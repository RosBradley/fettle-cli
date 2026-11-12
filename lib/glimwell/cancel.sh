#!/bin/bash
# Glimwell: lets a command tell the menu that the user cancelled it, so the
# menu comes straight back instead of asking for Enter. The menu names an
# empty marker path in GLIMWELL_CANCEL_FILE for each command it runs; marked
# lines in the commands' cancel paths call glimwell_note_cancel.

glimwell_note_cancel() {
    local marker="${GLIMWELL_CANCEL_FILE:-}"
    [[ -n "$marker" && ! -e "$marker" ]] || return 0
    : > "$marker" 2> /dev/null || true
}
