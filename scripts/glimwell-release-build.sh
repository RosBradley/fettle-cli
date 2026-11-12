#!/bin/bash
# glimwell: build a release's files from the commit checked out here. The
# release workflow (.github/workflows/glimwell-release.yml) runs it on the
# tagged commit; it also runs anywhere Go is installed, to try a build.
#
# Usage: bash scripts/glimwell-release-build.sh VERSION OUT_DIR
#
# Writes to OUT_DIR:
#   glimwell.tar.gz                   this commit's files in glimwell/, with
#                                     .glimwell-release naming the release
#   glimwell-go-darwin-arm64.tar.gz   the Go parts (bin/*-go) for Apple silicon
#   glimwell-go-darwin-amd64.tar.gz   the Go parts for Intel
#   SHA256SUMS                        the checksums of the three files above
#   notes.md                          the release notes

set -euo pipefail

readonly VERSION_RE='^[0-9]{4}\.[0-9]{2}\.[0-9]{2}(\.[0-9]+)?$'
# Each Go part: the name it is installed as in bin/, and its source.
readonly GO_PARTS=(
    "analyze-go ./cmd/analyze"
    "status-go ./cmd/status"
    "glimwell-updates-go ./cmd/glimwell-updates"
    "glimwell-models-go ./cmd/glimwell-models"
    "glimwell-view-go ./cmd/glimwell-view"
)
readonly ARCHES=(arm64 amd64)
readonly INSTALL_URL="https://raw.githubusercontent.com/${GITHUB_REPOSITORY:-RosBradley/glimwell-cli}/glimwell/glimwell-get.sh"

die() {
    printf 'Stopped: %s\n' "$1" >&2
    exit 1
}

sha256_lines() {
    if command -v shasum > /dev/null 2>&1; then
        shasum -a 256 "$@"
    else
        sha256sum "$@"
    fi
}

# The commits since the last release, newest first. A merge of Mole's main
# branch reads as one line; merges of the GitHub copy add nothing to read.
change_lines() {
    local previous=""
    previous="$(git describe --tags --abbrev=0 --match 'glimwell-*' HEAD^ 2> /dev/null)" || previous=""
    if [[ -z "$previous" ]]; then
        printf 'The first Glimwell release.\n'
        return 0
    fi
    printf 'Changes since %s:\n\n' "${previous#glimwell-}"
    git log --first-parent --no-decorate --format='%s' "$previous..HEAD" |
        sed -E "s/^Merge branch 'main' into glimwell$/Brought in Mole's latest changes/" |
        { grep -v '^Merge ' || true; } |
        awk 'NR <= 60 { print "- " $0 }'
}

main() {
    local version="${1:-}" out="${2:-}"
    [[ "$version" =~ $VERSION_RE && -n "$out" ]] ||
        die "usage: bash scripts/glimwell-release-build.sh YYYY.MM.DD[.N] OUT_DIR"
    local repo_root
    repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    cd "$repo_root"
    git rev-parse --verify --quiet HEAD > /dev/null || die "this must run in the glimwell git folder."
    command -v go > /dev/null 2>&1 || die "Go is needed to build the release. Install it with: brew install go"

    local mole_version commit
    mole_version="$(sed -n 's/^VERSION="\([^"]*\)"$/\1/p' mole)"
    [[ -n "$mole_version" ]] || die "could not read Mole's version from the mole file."
    commit="$(git rev-parse HEAD)"

    mkdir -p "$out"
    out="$(cd "$out" && pwd)"
    local stage
    stage="$(mktemp -d "${TMPDIR:-/tmp}/glimwell-release.XXXXXX")"
    # shellcheck disable=SC2064  # the path is fixed now, on purpose.
    trap "rm -rf '$stage'" EXIT # SAFE: removes only this run's mktemp staging folder

    # macOS tar would otherwise add ._ files holding extended attributes.
    export COPYFILE_DISABLE=1

    printf 'Packing the files of %s...\n' "${commit:0:7}"
    git archive --format=tar --prefix=glimwell/ HEAD | tar -xf - -C "$stage"
    printf 'version=%s\ncommit=%s\nmole=%s\n' "$version" "$commit" "$mole_version" > "$stage/glimwell/.glimwell-release"
    tar -czf "$out/glimwell.tar.gz" -C "$stage" glimwell

    local arch part name src
    for arch in "${ARCHES[@]}"; do
        printf 'Building the Go parts for darwin/%s...\n' "$arch"
        mkdir -p "$stage/go-$arch/bin"
        for part in "${GO_PARTS[@]}"; do
            name="${part%% *}"
            src="${part#* }"
            CGO_ENABLED=0 GOOS=darwin GOARCH="$arch" go build -trimpath -ldflags="-s -w" \
                -o "$stage/go-$arch/bin/$name" "$src"
        done
        tar -czf "$out/glimwell-go-darwin-$arch.tar.gz" -C "$stage/go-$arch" bin
    done

    (cd "$out" && sha256_lines glimwell.tar.gz glimwell-go-darwin-arm64.tar.gz glimwell-go-darwin-amd64.tar.gz > SHA256SUMS)

    local fence='```'
    {
        printf 'Glimwell %s, based on Mole %s.\n\n' "$version" "$mole_version"
        printf 'Install it by pasting this into Terminal:\n\n'
        printf '%ssh\ncurl -fsSL %s | bash\n%s\n\n' "$fence" "$INSTALL_URL" "$fence"
        printf 'Already installed? Choose Update Glimwell in the menu.\n\n'
        change_lines
    } > "$out/notes.md"

    printf 'Done: %s\n' "$out"
    ls -l "$out"
}

main "$@"
