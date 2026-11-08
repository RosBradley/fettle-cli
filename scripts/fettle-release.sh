#!/bin/bash
# fettle: publish a Fettle release. Tags the commit you're on as
# fettle-<today's date> and pushes the tag. GitHub then tests and builds
# the release and publishes it (.github/workflows/fettle-release.yml), and
# Update Fettle offers it to everyone who installed Fettle with its
# installer. A second release on the same day gets .2, then .3.
#
# Usage: bash scripts/fettle-release.sh

set -euo pipefail

readonly PERSONAL_BRANCH="fettle"

TODAY="$(date +%Y.%m.%d)"
# Tests choose the day, never outside test mode.
if [[ "${MOLE_TEST_MODE:-0}" == "1" ]]; then
    TODAY="${FETTLE_TEST_TODAY:-$TODAY}"
fi

die() {
    printf 'Stopped: %s\n' "$1" >&2
    exit 1
}

# Whether someone is there to answer. Tests replace it.
interactive() {
    [[ -t 0 && -t 1 ]]
}

# The GitHub page of origin, such as https://github.com/RosBradley/fettle-cli.
github_page() {
    local url
    url="$(git remote get-url origin 2> /dev/null)" || return 1
    case "$url" in
        https://github.com/*) url="${url#https://github.com/}" ;;
        git@github.com:*) url="${url#git@github.com:}" ;;
        *) return 1 ;;
    esac
    printf 'https://github.com/%s' "${url%.git}"
}

main() {
    local repo_root
    repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
    cd "$repo_root"
    [[ "$(git rev-parse --show-toplevel 2> /dev/null)" == "$repo_root" ]] ||
        die "this script must stay in the scripts folder of your fettle git folder."

    local branch
    branch="$(git symbolic-ref --quiet --short HEAD || true)"
    [[ "$branch" == "$PERSONAL_BRANCH" ]] ||
        die "you're on '${branch:-a detached HEAD}'. Releases come from $PERSONAL_BRANCH. Run: git checkout $PERSONAL_BRANCH"
    [[ -z "$(git status --porcelain --untracked-files=no)" ]] ||
        die "there are uncommitted changes. Commit and push them first (git status shows them)."

    printf 'Checking GitHub...\n'
    git fetch --quiet --tags origin "$PERSONAL_BRANCH" ||
        die "couldn't reach GitHub (see the message above). Check the internet connection and try again."
    local head remote
    head="$(git rev-parse HEAD)"
    remote="$(git rev-parse "origin/$PERSONAL_BRANCH")"
    if [[ "$head" != "$remote" ]]; then
        if git merge-base --is-ancestor "$remote" HEAD; then
            die "this commit isn't on GitHub yet, so GitHub can't build it. Push first: git push origin $PERSONAL_BRANCH"
        fi
        die "GitHub has changes this folder doesn't. Bring them down first (git pull), then push and run this again."
    fi
    local released
    if released="$(git describe --exact-match --tags --match 'fettle-*' HEAD 2> /dev/null)"; then
        die "this commit is already tagged as $released. If GitHub didn't publish it, remove the tag (git push origin --delete $released; git tag -d $released), then run this again."
    fi

    local version="$TODAY" n=1
    while git rev-parse --quiet --verify "refs/tags/fettle-$version" > /dev/null; do
        n=$((n + 1))
        version="$TODAY.$n"
    done
    local tag="fettle-$version" mole_version
    mole_version="$(sed -n 's/^VERSION="\([^"]*\)"$/\1/p' mole)"

    printf '\nPublish Fettle %s, based on Mole %s, from commit %s?\n' "$version" "${mole_version:-?}" "${head:0:7}"
    printf 'GitHub tests and builds it; then everyone who installed Fettle gets it with Update Fettle.\n'
    interactive || die "this asks before publishing, so run it in a terminal."
    local key=""
    printf 'Enter publish, ESC cancel: '
    IFS= read -r -s -n1 key || key="cancel"
    printf '\n'
    if [[ -n "$key" && "$key" != $'\n' && "$key" != $'\r' ]]; then
        printf 'Cancelled; nothing was published.\n'
        return 0
    fi

    git tag -a "$tag" -m "Fettle $version"
    if ! git push --quiet origin "refs/tags/$tag"; then
        git tag -d "$tag" > /dev/null
        die "couldn't push the tag (see the message above). Nothing was published; try again."
    fi

    local page
    page="$(github_page)" || page=""
    printf '\nPushed %s. GitHub is testing and building Fettle %s now; it takes about 10 minutes.\n' "$tag" "$version"
    if [[ -n "$page" ]]; then
        printf 'Progress: %s/actions\n' "$page"
        printf 'Then it appears at: %s/releases\n' "$page"
    fi
    printf 'If GitHub stops on a problem, nothing is published; fix it and run this again.\n'
}

if [[ "${MOLE_TEST_MODE:-0}" != "1" ]]; then
    main "$@"
fi
