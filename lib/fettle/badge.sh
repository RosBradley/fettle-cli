#!/bin/bash
# fettle: the Fettle mark as a small badge in front of a command's title: a
# white F and a copper dot on verdigris (xterm-256 colors 30 and 166), as in
# assets/fettle/mark.svg and on the Status title. Four columns, then two
# spaces. Shown only on a terminal with colors on; inside the Fettle screen
# (cmd/fettle-view, which sets FETTLE_IN_PANE) the screen's own title carries
# it, so the command's title line does not repeat it.

if [[ -n "${FETTLE_BADGE_LOADED:-}" ]]; then
    return 0
fi
readonly FETTLE_BADGE_LOADED=1

FETTLE_BADGE=""
if [[ -t 1 && -n "${PURPLE_BOLD:-}" && -z "${FETTLE_IN_PANE:-}" ]]; then
    FETTLE_BADGE=$'\033[1;97;48;5;30m F\033[0;38;5;166;48;5;30m\xe2\x96\xaa\033[0;48;5;30m \033[0m  '
fi
