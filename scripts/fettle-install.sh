#!/bin/bash
# fettle: set up the `fettle` command, with `ft` as a short name for it.
#
# Links both names in ~/.local/bin to this folder's `mole`, so updates to the
# folder take effect at once; removes MoreMole's `moremole` and `mm` links
# (Fettle was called MoreMole until 2026-11-07) and moves what MoreMole kept
# under its old name; adds ~/.local/bin to PATH in ~/.zshrc when it is
# missing; replaces an older `alias mm=` line; builds Analyze, Status,
# Software updates, Ollama models and the command screen when one of them was
# never built; offers to remove the official Mole when Homebrew installed it;
# links Mole's own names, mo and mole, too when no other Mole answers to them;
# and offers Tab completion for fettle and ft. Safe to run again.
#
# Usage: bash scripts/fettle-install.sh

set -euo pipefail

readonly LINK_DIR="$HOME/.local/bin"
readonly LINK_NAMES=(fettle ft)
# MoreMole's names for the same commands, removed when they link to a
# Fettle or MoreMole folder.
readonly OLD_LINK_NAMES=(moremole mm)
# What `make build` builds.
readonly GO_PARTS=(bin/analyze-go bin/status-go bin/fettle-updates-go bin/fettle-models-go bin/fettle-view-go)
readonly GO_PARTS_NAMES="Analyze, Status, Software updates, Ollama models and the command screen"
# Mole's own names, linked only while no other Mole answers to them.
readonly MOLE_NAMES=(mo mole)
readonly SHELL_RC="$HOME/.zshrc"
readonly PATH_MARKER="# fettle: commands in ~/.local/bin"
# The same line as MoreMole wrote it.
readonly OLD_PATH_MARKER="# moremole: commands in ~/.local/bin"

die() {
    printf 'Stopped: %s\n' "$1" >&2
    exit 1
}

# Every change this makes to the Mac leaves an operations.log row, as Mole's
# own commands do. Logging never stops the setup.
oplog() {
    declare -F log_operation > /dev/null || return 0
    log_operation "install" "$@" 2> /dev/null || true
}

# Whether the link at $1 belongs to Fettle: it points at a Fettle folder's
# mole, this one or an earlier copy, or at a MoreMole folder's.
is_fettle_link() {
    local target dir
    [[ -L "$1" ]] || return 1
    target="$(readlink "$1")"
    [[ "$target" == */mole ]] || return 1
    dir="$(dirname "$target")"
    [[ -f "$dir/lib/fettle/menu.sh" || -f "$dir/lib/moremole/menu.sh" ]]
}

# Remove MoreMole's moremole and mm links. Only links to a Fettle or MoreMole
# folder go; anything else with those names is someone else's and stays.
remove_old_links() {
    local name link
    for name in "${OLD_LINK_NAMES[@]}"; do
        link="$LINK_DIR/$name"
        is_fettle_link "$link" || continue
        rm -f "$link" # SAFE: MoreMole's own link in ~/.local/bin, checked to point at a Fettle or MoreMole folder
        oplog "REMOVED" "$link" "MoreMole's old name for the command"
        printf '  Removed %s, MoreMole'"'"'s old name for it.\n' "$link"
    done
}

# Point $LINK_DIR/$1 at $2. Only a Fettle link is replaced; anything else
# with that name is someone else's and stays.
link_command() {
    local link="$LINK_DIR/$1" target="$2"
    if [[ -L "$link" && "$(readlink "$link")" == "$target" ]]; then
        printf '  %s -> %s\n' "$link" "$target"
        return 0
    fi
    if [[ -e "$link" || -L "$link" ]] && ! is_fettle_link "$link"; then
        if [[ -L "$link" ]]; then
            die "$link already links to $(readlink "$link"), which isn't Fettle. Remove that link or rename it, then run this again."
        fi
        die "$link already exists and is not a link. Move it aside, then run this again."
    fi
    ln -sfn "$target" "$link"
    oplog "REBUILT" "$link" "links to $target"
    printf '  %s -> %s\n' "$link" "$target"
}

# Add ~/.local/bin to PATH in ~/.zshrc unless it is already on PATH or added.
ensure_path() {
    case ":$PATH:" in
        *":$LINK_DIR:"*) return 0 ;;
    esac
    if [[ -f "$SHELL_RC" ]] && grep -qF -e "$PATH_MARKER" -e "$OLD_PATH_MARKER" "$SHELL_RC"; then
        return 0
    fi
    # shellcheck disable=SC2016  # $HOME and $PATH expand when ~/.zshrc runs.
    printf '\n%s\nexport PATH="$HOME/.local/bin:$PATH"\n' "$PATH_MARKER" >> "$SHELL_RC"
    oplog "REBUILT" "$SHELL_RC" "added ~/.local/bin to PATH"
    printf 'Added ~/.local/bin to PATH in %s.\n' "$SHELL_RC"
    NEW_WINDOW_NEEDED=true
}

# Drop an `alias mm=` line that points at a MoreMole folder; the ft link
# replaces it.
# Other lines stay byte for byte, and a symlinked ~/.zshrc is written in place.
remove_old_alias() {
    [[ -f "$SHELL_RC" ]] || return 0
    local pattern='^[[:space:]]*alias mm=.*moremole/mole["'"'"']?[[:space:]]*$'
    grep -qE "$pattern" "$SHELL_RC" || return 0
    local kept
    kept="$(grep -vE "$pattern" "$SHELL_RC" || true)"
    printf '%s\n' "$kept" > "$SHELL_RC"
    oplog "REMOVED" "$SHELL_RC" "old alias mm= line"
    printf 'Removed the old "alias mm=" line from %s; the ft command replaces it.\n' "$SHELL_RC"
    NEW_WINDOW_NEEDED=true
}

# Offer to remove the official Mole when Homebrew installed it. Homebrew's
# uninstall leaves ~/.config/mole, which Fettle uses too, in place.
offer_official_removal() {
    command -v brew > /dev/null 2>&1 || return 0
    brew list --formula mole > /dev/null 2>&1 || return 0
    printf '\nThe official Mole (the mo command) is installed with Homebrew.\n'
    if [[ ! -t 0 ]]; then
        printf 'To remove it, run: brew uninstall mole\n'
        return 0
    fi
    local answer=""
    printf 'Remove it? Your settings in ~/.config/mole stay. (y/N): '
    IFS= read -r answer || answer=""
    if [[ "$answer" == "y" || "$answer" == "Y" ]]; then
        if brew uninstall mole; then
            oplog "REMOVED" "mole" "official Mole, uninstalled with Homebrew"
        else
            oplog "FAILED" "mole" "brew uninstall mole failed"
        fi
        hash -r
    else
        printf 'Kept. Remove it later with: brew uninstall mole\n'
    fi
}

# Whether $1 is this installer's own link for a name, pointing at $2.
is_our_link() {
    [[ -L "$1" && "$(readlink "$1")" == "$2" ]]
}

# Report a Mole that was not installed by Homebrew without touching it: its
# own `mo remove` would also move ~/.config/mole, and your commands, to Trash.
report_other_mole() {
    local repo_root="$1"
    # A Homebrew Mole was already offered for removal above.
    if command -v brew > /dev/null 2>&1 && brew list --formula mole > /dev/null 2>&1; then
        return 0
    fi
    local name path
    for name in "${MOLE_NAMES[@]}"; do
        path="$(command -v "$name" 2> /dev/null || true)"
        [[ -n "$path" && "$path" == /* ]] || continue
        ! is_our_link "$path" "$repo_root/mole" || continue
        printf '\nAnother Mole is still installed: %s\n' "$path"
        printf 'It was not installed with Homebrew. Do not remove it with "mo remove",\n'
        printf 'which also moves ~/.config/mole, and your Fettle commands, to the Trash.\n'
        return 0
    done
}

# Link mo and mole to Fettle too, so scripts written for Mole keep working,
# unless something else already answers to the name: it keeps the name.
link_mole_names() {
    local repo_root="$1" name link taken path
    local -a linked=()
    for name in "${MOLE_NAMES[@]}"; do
        link="$LINK_DIR/$name"
        taken=""
        if [[ -e "$link" || -L "$link" ]]; then
            is_our_link "$link" "$repo_root/mole" || taken="$link"
        fi
        if [[ -z "$taken" ]]; then
            path="$(command -v "$name" 2> /dev/null || true)"
            [[ -z "$path" || "$path" == "$link" ]] || taken="$path"
        fi
        if [[ -n "$taken" ]]; then
            printf '%s already runs %s, so it stays as it is.\n' "$name" "$taken"
            continue
        fi
        if ! is_our_link "$link" "$repo_root/mole"; then
            ln -sfn "$repo_root/mole" "$link"
            oplog "REBUILT" "$link" "links to $repo_root/mole"
        fi
        linked+=("$name")
    done
    case ${#linked[@]} in
        1) printf '%s now runs Fettle too.\n' "${linked[0]}" ;;
        2) printf '%s and %s now run Fettle too.\n' "${linked[0]}" "${linked[1]}" ;;
    esac
}

main() {
    local repo_root
    repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    [[ -x "$repo_root/mole" && -f "$repo_root/lib/fettle/menu.sh" ]] ||
        die "this script must stay in the scripts folder of your fettle folder."

    NEW_WINDOW_NEEDED=false
    # Mole's operation log, for oplog. Setup carries on without it.
    if [[ -f "$repo_root/lib/core/base.sh" && -f "$repo_root/lib/core/log.sh" ]]; then
        # shellcheck source=/dev/null
        source "$repo_root/lib/core/base.sh" && source "$repo_root/lib/core/log.sh" || true
    fi

    printf 'Setting up the fettle and ft commands:\n'
    mkdir -p "$LINK_DIR"
    local name
    for name in "${LINK_NAMES[@]}"; do
        link_command "$name" "$repo_root/mole"
    done
    remove_old_links
    ensure_path
    remove_old_alias
    # shellcheck source=lib/fettle/migrate.sh
    source "$repo_root/lib/fettle/migrate.sh"
    fettle_migrate_state

    local part missing=false
    for part in "${GO_PARTS[@]}"; do
        [[ -x "$repo_root/$part" ]] || missing=true
    done
    if [[ "$missing" == "true" ]]; then
        if command -v go > /dev/null 2>&1; then
            printf '\nBuilding %s...\n' "$GO_PARTS_NAMES"
            (cd "$repo_root" && make build) ||
                die "the build failed (see the message above). The commands are set up; fix the problem, then run: make build"
        else
            printf '\n%s need Go to build. Install it with: brew install go, then run: make build\n' "$GO_PARTS_NAMES"
        fi
    fi

    offer_official_removal
    report_other_mole "$repo_root"
    printf '\n'
    link_mole_names "$repo_root"

    # Mole's own completion setup asks before it changes ~/.zshrc and replaces
    # an earlier Mole completion line. ~/.local/bin goes first on PATH so it
    # finds fettle even before a new window loads the PATH line.
    printf '\n'
    if [[ -t 0 ]]; then
        PATH="$LINK_DIR:$PATH" "$repo_root/mole" completion ||
            printf 'Tab completion was not set up. To try again, run: fettle completion\n'
    else
        printf 'To set up Tab completion for fettle and ft, run: fettle completion\n'
    fi

    printf '\nDone. '
    if [[ "$NEW_WINDOW_NEEDED" == "true" ]]; then
        printf 'Open a new Terminal window, then type fettle or ft.\n'
    else
        printf 'Type fettle or ft.\n'
    fi
}

main "$@"
exit
