#!/bin/bash
# moremole: bring in the latest Mole changes from tw93/Mole.
#
# First brings down any moremole changes already on GitHub (origin), then
# updates main to match upstream (fast-forward only), merges main into the
# moremole branch, pushes both to origin, and rebuilds the Go parts when they
# changed. Stops before changing anything if there are uncommitted changes or
# if main has commits upstream doesn't. When it stops on uncommitted changes
# or because GitHub or Mole can't be reached, it still rebuilds Go parts that
# are older than the code in this folder, so MoreMole runs that code.
#
# Usage: bash scripts/moremole-sync.sh

set -euo pipefail

readonly PERSONAL_BRANCH="moremole"
readonly MIRROR_BRANCH="main"
readonly UPSTREAM_REMOTE="upstream"

die() {
    printf 'Stopped: %s\n' "$1" >&2
    exit 1
}

# Merge $1 into the current branch, or stop at a conflict and list the files
# to look at; $2 says where the other changes came from.
merge_or_stop() {
    git merge --no-edit "$1" && return 0
    printf '\nThe merge stopped on a conflict: %s changed the same lines as this folder.\n' "$2" >&2
    printf 'Files to look at:\n' >&2
    git diff --name-only --diff-filter=U | sed 's/^/    /' >&2
    printf 'To undo the merge and get back to where you were: git merge --abort\n' >&2
    exit 1
}

# Everything runs inside main so bash has read the whole script before git
# touches the working tree.
main() {
    local repo_root
    repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    cd "$repo_root"

    git remote get-url "$UPSTREAM_REMOTE" > /dev/null 2>&1 ||
        die "no '$UPSTREAM_REMOTE' remote. Add it with: git remote add $UPSTREAM_REMOTE https://github.com/tw93/Mole.git"

    local current_branch
    current_branch="$(git symbolic-ref --quiet --short HEAD || true)"
    [[ "$current_branch" == "$PERSONAL_BRANCH" ]] ||
        die "you're on '${current_branch:-a detached HEAD}'. Run: git checkout $PERSONAL_BRANCH"

    # Untracked files don't count; git merge still refuses to overwrite one.
    [[ -z "$(git status --porcelain --untracked-files=no)" ]] ||
        stop_after_rebuild "there are uncommitted changes. Commit them first (git status shows them)."

    local old_main

    # Changes pushed to GitHub from elsewhere come down first, or the push at
    # the end would be refused.
    printf 'Fetching your GitHub copy...\n'
    git fetch origin "$PERSONAL_BRANCH" ||
        stop_after_rebuild "could not reach origin (see the message above). Check your internet connection and try again."
    if ! git merge-base --is-ancestor "origin/$PERSONAL_BRANCH" HEAD; then
        printf 'Bringing down the changes on GitHub first.\n'
        merge_or_stop "origin/$PERSONAL_BRANCH" "your GitHub copy"
    fi

    old_main="$(git rev-parse "$MIRROR_BRANCH")"

    printf 'Fetching %s...\n' "$UPSTREAM_REMOTE"
    git fetch "$UPSTREAM_REMOTE" "$MIRROR_BRANCH" ||
        stop_after_rebuild "could not reach $UPSTREAM_REMOTE (see the message above). Check your internet connection and try again."

    # main only ever mirrors upstream, so a commit made on it by mistake stops
    # the sync instead of being merged.
    git merge-base --is-ancestor "$MIRROR_BRANCH" "$UPSTREAM_REMOTE/$MIRROR_BRANCH" ||
        die "'$MIRROR_BRANCH' has commits that aren't in $UPSTREAM_REMOTE/$MIRROR_BRANCH. It should only ever mirror upstream; ask for help before going further."

    git fetch --quiet . "$UPSTREAM_REMOTE/$MIRROR_BRANCH:$MIRROR_BRANCH" ||
        die "could not move '$MIRROR_BRANCH' forward (see the message above). If another folder has '$MIRROR_BRANCH' checked out, switch that folder to another branch and try again."

    local new_main
    new_main="$(git rev-parse "$MIRROR_BRANCH")"

    if [[ "$old_main" == "$new_main" ]]; then
        printf 'Mole has no new changes since your last sync.\n'
    else
        local count
        count="$(git rev-list --count "$old_main..$new_main")"
        printf '%s new commit(s) from Mole.\n' "$count"
    fi

    git push origin "$MIRROR_BRANCH" ||
        stop_after_rebuild "could not push '$MIRROR_BRANCH' to origin (see the message above). Check your internet connection and try again."

    if git merge-base --is-ancestor "$MIRROR_BRANCH" HEAD; then
        printf '%s already has everything from %s.\n' "$PERSONAL_BRANCH" "$MIRROR_BRANCH"
    else
        merge_or_stop "$MIRROR_BRANCH" "Mole"
    fi

    git push origin "$PERSONAL_BRANCH" ||
        stop_after_rebuild "could not push '$PERSONAL_BRANCH' to origin (see the message above). Mole's changes are merged here; check your internet connection, then run: git push origin $PERSONAL_BRANCH"

    printf '\n%s is up to date with Mole.\n' "$PERSONAL_BRANCH"

    if go_parts_stale; then
        rebuild_go_parts
    fi
    printf '\nDone.\n'
}

# What `make build` builds: Analyze, Status, the Software updates and Ollama
# models helpers and the command screen.
readonly GO_PARTS=(bin/analyze-go bin/status-go bin/moremole-updates-go bin/moremole-models-go bin/moremole-view-go)
readonly GO_PARTS_NAMES="Analyze, Status, Software updates, Ollama models and the command screen"

# Whether any Go part is missing or older than any of the Go source.
# Comparing file times catches Go changes from any source: this update, a
# git pull, or an edit, and git writes every file it changes with the
# current time.
go_parts_stale() {
    local binary
    for binary in "${GO_PARTS[@]}"; do
        [[ -x "$binary" ]] || return 0
        [[ -z "$(find cmd go.mod go.sum -newer "$binary" -print -quit 2> /dev/null)" ]] || return 0
    done
    return 1
}

# Rebuild the Go parts. The update itself has already finished, so a failed
# build says how to retry instead of undoing anything.
rebuild_go_parts() {
    if ! command -v go > /dev/null 2>&1; then
        die "$GO_PARTS_NAMES need rebuilding, but Go is not installed. Install it with: brew install go, then run: make build"
    fi
    printf '\nRebuilding %s...\n' "$GO_PARTS_NAMES"
    make build ||
        die "the rebuild failed (see the message above). The update itself is done; fix the problem, then run: make build"
}

# Stop for a reason that leaves this folder's code whole (uncommitted
# changes, GitHub or Mole out of reach), after rebuilding the Go parts if
# they're older than that code. A conflict stops with merge_or_stop instead,
# since the code is half merged then.
stop_after_rebuild() {
    if go_parts_stale; then
        if ! command -v go > /dev/null 2>&1; then
            printf '%s need rebuilding, but Go is not installed. Install it with: brew install go, then run: make build\n' "$GO_PARTS_NAMES" >&2
        else
            printf 'Rebuilding %s first, from the code in this folder...\n' "$GO_PARTS_NAMES"
            make build ||
                printf 'The rebuild failed too (see the message above). Fix the problem, then run: make build\n' >&2
        fi
    fi
    die "$1"
}

main "$@"
exit
