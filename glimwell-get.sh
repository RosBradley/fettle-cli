#!/bin/bash
# Glimwell installer. Downloads the newest Glimwell release from GitHub,
# checks every file against the checksums published with the release, and
# installs it in ~/.local/share/glimwell. A first install then sets up the
# glimwell and gw commands (scripts/glimwell-install.sh).
#
# Install:  curl -fsSL https://raw.githubusercontent.com/RosBradley/glimwell-cli/glimwell/glimwell-get.sh | bash
# Update:   Update Glimwell in the menu runs the installed copy of this script
#           with --update, which replaces the copy it is in. Your settings in
#           ~/.config/mole stay.

set -euo pipefail

readonly REPO="RosBradley/glimwell-cli"
readonly GITHUB="https://github.com"
readonly INSTALL_LINE="curl -fsSL https://raw.githubusercontent.com/$REPO/glimwell/glimwell-get.sh | bash"
readonly RELEASE_FILE=".glimwell-release"
readonly VERSION_RE='^[0-9]{4}\.[0-9]{2}\.[0-9]{2}(\.[0-9]+)?$'
# The Go parts each release carries in bin/.
readonly GO_PARTS=(analyze-go status-go glimwell-updates-go glimwell-models-go glimwell-view-go)

OS_NAME="$(uname -s)"
ARCH=""
# Tests stand in for another Mac, never outside test mode.
if [[ "${MOLE_TEST_MODE:-0}" == "1" ]]; then
    OS_NAME="${GLIMWELL_TEST_OS:-$OS_NAME}"
    ARCH="${GLIMWELL_TEST_ARCH:-}"
fi

WORK=""
cleanup() {
    if [[ -n "$WORK" && -d "$WORK" ]]; then
        rm -rf "$WORK" # SAFE: removes only this run's mktemp folder, holding downloads and a replaced copy
    fi
}
trap cleanup EXIT

say() {
    printf '%s\n' "$1"
}

# Stop with the cause and what to do next.
stop() {
    printf 'Stopped: %s\n' "$1" >&2
    [[ -z "${2:-}" ]] || printf '%s\n' "$2" >&2
    exit 1
}

# Apple silicon Macs get arm64, Intel Macs amd64. A Terminal running under
# Rosetta still gets the Apple silicon build.
detect_arch() {
    [[ -z "$ARCH" ]] || return 0
    if [[ "$(/usr/sbin/sysctl -n hw.optional.arm64 2> /dev/null)" == "1" ]]; then
        ARCH="arm64"
    else
        case "$(uname -m)" in
            arm64) ARCH="arm64" ;;
            x86_64) ARCH="amd64" ;;
            *) stop "this Mac's processor ($(uname -m)) isn't one Glimwell is built for." ;;
        esac
    fi
}

fetch() {
    curl -fsSL --proto '=https' --connect-timeout 15 --max-time 600 --retry 2 -o "$2" "$1"
}

# The newest release's tag, from where GitHub's "latest release" link leads.
latest_tag() {
    local url
    url="$(curl -fsSLI --proto '=https' --connect-timeout 15 --max-time 60 -o /dev/null \
        -w '%{url_effective}' "$GITHUB/$REPO/releases/latest")" ||
        stop "couldn't reach GitHub (see the message above)." "Check the internet connection, then try again."
    case "$url" in
        */releases/tag/glimwell-*) ;;
        *) stop "no Glimwell release is published yet." "Try again later, or see $GITHUB/$REPO" ;;
    esac
    local tag="${url##*/releases/tag/}"
    [[ "${tag#glimwell-}" =~ $VERSION_RE ]] ||
        stop "GitHub's newest release, $tag, isn't a Glimwell release this installer knows." "See $GITHUB/$REPO/releases"
    printf '%s' "$tag"
}

# The version= line of a .glimwell-release file, if it holds a valid one.
release_version_in() {
    local line version=""
    [[ -f "$1" ]] || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" == version=* ]] && version="${line#version=}"
    done < "$1"
    [[ "$version" =~ $VERSION_RE ]] || return 1
    printf '%s' "$version"
}

sha256_of() {
    if command -v shasum > /dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    else
        sha256sum "$1" | awk '{print $1}'
    fi
}

# Stop unless $WORK/$1 matches its line in $WORK/SHA256SUMS.
check_sum() {
    local name="$1" version="$2" expected actual
    expected="$(awk -v n="$name" '{ f = $2; sub(/^\*/, "", f) } f == n { print $1; exit }' "$WORK/SHA256SUMS")"
    [[ "$expected" =~ ^[0-9a-f]{64}$ ]] ||
        stop "Glimwell $version lists no checksum for $name, so it can't be checked. Nothing was changed." \
            "Report it at $GITHUB/$REPO/issues"
    actual="$(sha256_of "$WORK/$name")"
    [[ "$actual" == "$expected" ]] ||
        stop "$name doesn't match the checksum published with Glimwell $version. Nothing was changed." \
            "Try again later; if it keeps happening, report it at $GITHUB/$REPO/issues"
}

# Run the command setup with the keyboard, even when this script itself
# arrived through a pipe (curl ... | bash).
set_up_commands() {
    if [[ -t 1 ]] && { : < /dev/tty; } 2> /dev/null; then
        /bin/bash "$1/scripts/glimwell-install.sh" < /dev/tty
    else
        /bin/bash "$1/scripts/glimwell-install.sh" < /dev/null
    fi
}

main() {
    local update=false arg
    for arg in "$@"; do
        case "$arg" in
            --update) update=true ;;
            *) stop "unknown option: $arg" "Install with: $INSTALL_LINE" ;;
        esac
    done
    [[ "$EUID" -ne 0 ]] || stop "the installer runs as you, not with sudo." "Run it again without sudo: $INSTALL_LINE"
    [[ "$OS_NAME" == "Darwin" ]] || stop "Glimwell runs on macOS only."
    detect_arch
    local tool
    for tool in curl tar awk; do
        command -v "$tool" > /dev/null 2>&1 || stop "this needs $tool, which isn't on this Mac."
    done

    # An update replaces the copy this script is in; an install goes to
    # ~/.local/share/glimwell.
    local target current=""
    if [[ "$update" == "true" ]]; then
        target="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
        current="$(release_version_in "$target/$RELEASE_FILE")" ||
            stop "this copy of Glimwell wasn't installed by the installer, so it can't update itself." \
                "Install Glimwell with: $INSTALL_LINE"
    else
        target="$HOME/.local/share/glimwell"
        if [[ -e "$target" || -L "$target" ]]; then
            if [[ -d "$target/.git" || -L "$target" ]] || ! current="$(release_version_in "$target/$RELEASE_FILE")"; then
                stop "$target already exists, and this installer didn't put it there." \
                    "Move it somewhere else, then run the installer again."
            fi
        fi
    fi

    local tag version
    tag="$(latest_tag)"
    version="${tag#glimwell-}"
    if [[ -n "$current" ]] && [[ "$current" == "$version" || "$(printf '%s\n' "$version" "$current" | sort -V | tail -n 1)" == "$current" ]]; then
        say "Glimwell $current is the newest release; nothing to update."
        [[ "$update" == "true" ]] || set_up_commands "$target"
        return 0
    fi
    if [[ -n "$current" ]]; then
        say "Updating Glimwell $current to $version..."
    else
        say "Installing Glimwell $version..."
    fi

    local parent go_file="glimwell-go-darwin-$ARCH.tar.gz" name
    parent="$(dirname "$target")"
    mkdir -p "$parent"
    # Next to the target, so the copy moves into place in one step.
    WORK="$(mktemp -d "$parent/.glimwell-get.XXXXXX")" ||
        stop "couldn't make a work folder in $parent." "Check that it's yours and has free space, then try again."
    for name in SHA256SUMS glimwell.tar.gz "$go_file"; do
        fetch "$GITHUB/$REPO/releases/download/$tag/$name" "$WORK/$name" ||
            stop "couldn't download $name from GitHub (see the message above). Nothing was changed." \
                "Check the internet connection, then try again."
    done
    check_sum glimwell.tar.gz "$version"
    check_sum "$go_file" "$version"

    tar -xzf "$WORK/glimwell.tar.gz" -C "$WORK" ||
        stop "couldn't unpack glimwell.tar.gz. Nothing was changed." "Try again; if it keeps happening, report it at $GITHUB/$REPO/issues"
    [[ -f "$WORK/glimwell/mole" && "$(release_version_in "$WORK/glimwell/$RELEASE_FILE" || true)" == "$version" ]] ||
        stop "the download doesn't hold Glimwell $version. Nothing was changed." "Report it at $GITHUB/$REPO/issues"
    tar -xzf "$WORK/$go_file" -C "$WORK/glimwell" ||
        stop "couldn't unpack $go_file. Nothing was changed." "Try again; if it keeps happening, report it at $GITHUB/$REPO/issues"
    local part
    for part in "${GO_PARTS[@]}"; do
        [[ -f "$WORK/glimwell/bin/$part" ]] ||
            stop "the download is missing bin/$part. Nothing was changed." "Report it at $GITHUB/$REPO/issues"
        chmod +x "$WORK/glimwell/bin/$part"
    done

    # The old copy moves aside first and comes back if the new one can't
    # take its place; the cleanup removes it with the downloads.
    if [[ -e "$target" ]]; then
        mv "$target" "$WORK/previous" ||
            stop "couldn't move the installed copy aside. Nothing was changed." "Check that $target is yours, then try again."
        if ! mv "$WORK/glimwell" "$target"; then
            mv "$WORK/previous" "$target" || true
            stop "couldn't put Glimwell $version in place; the installed copy was kept." "Try again."
        fi
    else
        mv "$WORK/glimwell" "$target" || stop "couldn't put Glimwell $version in $target." "Check that $parent is yours, then try again."
    fi

    if [[ -n "$current" ]]; then
        say "Glimwell is now $version."
    else
        say "Glimwell $version is installed in $target."
    fi
    # Running the installer again also repairs the commands.
    if [[ "$update" != "true" ]]; then
        printf '\n'
        set_up_commands "$target"
    fi
}

main "$@"
