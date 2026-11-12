#!/usr/bin/env bats
# shellcheck disable=SC2016  # inner bash scripts expand their own arguments
# shellcheck disable=SC2030,SC2031  # each test sets the fake GitHub's state for itself
# Glimwell releases: glimwell-get.sh installs and updates from them, Update
# Glimwell picks the right way to update, scripts/glimwell-release.sh
# publishes one and scripts/glimwell-release-build.sh builds its files. A
# fake curl stands in for GitHub, serving releases from a folder.

load helpers/common

setup_file() {
	mole_test_setup_home "glimwell-release"
}

teardown_file() {
	mole_test_teardown_home
}

setup() {
	rm -rf "${HOME:?}/home" "${HOME:?}/stubs" "${HOME:?}/releases" "${HOME:?}/.cache" "${HOME:?}/Library" # SAFE: test-owned mktemp HOME under tests/tmp-*
	FAKE_HOME="$HOME/home"
	STUBS="$HOME/stubs"
	RELEASES="$HOME/releases"
	CURL_LOG="$HOME/curl.log"
	TARGET="$FAKE_HOME/.local/share/glimwell"
	mkdir -p "$FAKE_HOME" "$STUBS" "$RELEASES"
	: > "$CURL_LOG"
	FAKE_LATEST="https://github.com/RosBradley/glimwell-cli/releases"
	FAKE_OFFLINE=0
	export FAKE_HOME STUBS RELEASES CURL_LOG TARGET FAKE_LATEST FAKE_OFFLINE
	export COPYFILE_DISABLE=1

	cat > "$STUBS/curl" << 'EOF'
#!/bin/bash
printf 'curl %s\n' "$*" >> "$CURL_LOG"
out="" url=""
while (($#)); do
    case "$1" in
        -o) out="$2"; shift 2 ;;
        -w | --proto | --connect-timeout | --max-time | --retry) shift 2 ;;
        -*) shift ;;
        *) url="$1"; shift ;;
    esac
done
if [[ "$FAKE_OFFLINE" == "1" ]]; then
    echo "curl: (6) Could not resolve host: github.com" >&2
    exit 6
fi
case "$url" in
    https://github.com/RosBradley/glimwell-cli/releases/latest) printf '%s' "$FAKE_LATEST" ;;
    https://github.com/RosBradley/glimwell-cli/releases/download/*)
        file="$RELEASES/${url#https://github.com/RosBradley/glimwell-cli/releases/download/}"
        if [[ ! -f "$file" ]]; then
            echo "curl: (22) The requested URL returned error: 404" >&2
            exit 22
        fi
        cp "$file" "$out"
        ;;
    *) echo "unexpected URL $url" >&2; exit 99 ;;
esac
EOF
	printf '#!/bin/bash\nexit 1\n' > "$STUBS/brew"
	chmod +x "$STUBS/curl" "$STUBS/brew"
}

sha256_lines() {
	if command -v shasum > /dev/null 2>&1; then
		shasum -a 256 "$@"
	else
		sha256sum "$@"
	fi
}

# Publish a release of VERSION with this branch's installer in it, and make
# it GitHub's latest.
publish() {
	local version="$1" dir="$RELEASES/glimwell-$1" src="$HOME/src-$1" arch part
	rm -rf "$src" # SAFE: test-owned scratch under tests/tmp-*
	mkdir -p "$dir" "$src/glimwell/scripts" "$src/glimwell/lib/glimwell"
	cp "$PROJECT_ROOT/glimwell-get.sh" "$src/glimwell/"
	cp "$PROJECT_ROOT/scripts/glimwell-install.sh" "$src/glimwell/scripts/"
	printf '#!/bin/bash\necho "GLIMWELL %s"\n' "$version" > "$src/glimwell/mole"
	chmod +x "$src/glimwell/mole"
	: > "$src/glimwell/lib/glimwell/menu.sh"
	cp "$PROJECT_ROOT/lib/glimwell/migrate.sh" "$src/glimwell/lib/glimwell/"
	printf 'version=%s\ncommit=abc1234\nmole=1.64.0\n' "$version" > "$src/glimwell/.glimwell-release"
	tar -czf "$dir/glimwell.tar.gz" -C "$src" glimwell
	for arch in arm64 amd64; do
		mkdir -p "$src/go-$arch/bin"
		for part in analyze-go status-go glimwell-updates-go glimwell-models-go glimwell-view-go; do
			printf '%s %s\n' "$arch" "$version" > "$src/go-$arch/bin/$part"
		done
		tar -czf "$dir/glimwell-go-darwin-$arch.tar.gz" -C "$src/go-$arch" bin
	done
	(cd "$dir" && sha256_lines glimwell.tar.gz glimwell-go-darwin-arm64.tar.gz glimwell-go-darwin-amd64.tar.gz > SHA256SUMS)
	FAKE_LATEST="https://github.com/RosBradley/glimwell-cli/releases/tag/glimwell-$version"
}

# Run a script as a Mac user of the fake home, with GitHub stood in for.
as_user() {
	env HOME="$FAKE_HOME" PATH="$STUBS:/usr/bin:/bin" MOLE_TEST_MODE=1 \
		GLIMWELL_TEST_OS="${TEST_OS:-Darwin}" GLIMWELL_TEST_ARCH="${TEST_ARCH:-arm64}" \
		RELEASES="$RELEASES" CURL_LOG="$CURL_LOG" FAKE_LATEST="$FAKE_LATEST" FAKE_OFFLINE="$FAKE_OFFLINE" \
		COPYFILE_DISABLE=1 /bin/bash "$@" < /dev/null
}

@test "the installer checks the downloads, installs the newest release and sets up the commands" {
	publish 2026.10.26
	run as_user "$PROJECT_ROOT/glimwell-get.sh"
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[[ "$output" == *"Installing Glimwell 2026.10.26..."*"Glimwell 2026.10.26 is installed in $TARGET."*"Setting up the glimwell and gw commands"* ]] || return 1
	[ "$(readlink "$FAKE_HOME/.local/bin/glimwell")" = "$TARGET/mole" ] || return 1
	[ "$(readlink "$FAKE_HOME/.local/bin/gw")" = "$TARGET/mole" ] || return 1
	[ "$(cat "$TARGET/bin/glimwell-view-go")" = "arm64 2026.10.26" ] || return 1
	[ -x "$TARGET/bin/analyze-go" ] || return 1
	grep -q '^version=2026.10.26$' "$TARGET/.glimwell-release" || return 1
	# Only the Apple silicon build was downloaded, and the work folder is gone.
	! grep -q "amd64" "$CURL_LOG" || return 1
	[ "$(ls -A "$FAKE_HOME/.local/share")" = "glimwell" ] || return 1

	# Running it again repairs the commands and downloads nothing.
	rm "$FAKE_HOME/.local/bin/gw"
	: > "$CURL_LOG"
	run as_user "$PROJECT_ROOT/glimwell-get.sh"
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[[ "$output" == *"Glimwell 2026.10.26 is the newest release; nothing to update."* ]] || return 1
	[ "$(readlink "$FAKE_HOME/.local/bin/gw")" = "$TARGET/mole" ] || return 1
	run grep -c "releases/download" "$CURL_LOG"
	[ "$output" = "0" ]
}

@test "an Intel Mac gets the Intel build" {
	publish 2026.10.26
	TEST_ARCH=amd64 run as_user "$PROJECT_ROOT/glimwell-get.sh"
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[ "$(cat "$TARGET/bin/status-go")" = "amd64 2026.10.26" ]
}

@test "a download that doesn't match its checksum changes nothing" {
	publish 2026.10.26
	run as_user "$PROJECT_ROOT/glimwell-get.sh"
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	publish 2026.10.27
	printf 'tampered' >> "$RELEASES/glimwell-2026.10.27/glimwell-go-darwin-arm64.tar.gz"
	run as_user "$TARGET/glimwell-get.sh" --update
	[ "$status" -eq 1 ] || { echo "$output"; return 1; }
	[[ "$output" == *"Stopped: glimwell-go-darwin-arm64.tar.gz doesn't match the checksum published with Glimwell 2026.10.27. Nothing was changed."* ]] || return 1
	[[ "$output" == *"report it at https://github.com/RosBradley/glimwell-cli/issues"* ]] || return 1
	grep -q '^version=2026.10.26$' "$TARGET/.glimwell-release" || return 1
	[ "$(cat "$TARGET/bin/status-go")" = "arm64 2026.10.26" ] || return 1
	[ "$(ls -A "$FAKE_HOME/.local/share")" = "glimwell" ] || return 1

	# A release without a checksum for a file is refused the same way.
	publish 2026.10.28
	grep -v "glimwell.tar.gz" "$RELEASES/glimwell-2026.10.28/SHA256SUMS" > "$HOME/sums"
	cp "$HOME/sums" "$RELEASES/glimwell-2026.10.28/SHA256SUMS"
	run as_user "$TARGET/glimwell-get.sh" --update
	[ "$status" -eq 1 ] || { echo "$output"; return 1; }
	[[ "$output" == *"Glimwell 2026.10.28 lists no checksum for glimwell.tar.gz"* ]] || return 1
	grep -q '^version=2026.10.26$' "$TARGET/.glimwell-release"
}

@test "the installer leaves alone a folder it didn't put there, and says why it can't go on" {
	mkdir -p "$TARGET/.git"
	publish 2026.10.26
	run as_user "$PROJECT_ROOT/glimwell-get.sh"
	[ "$status" -eq 1 ] || { echo "$output"; return 1; }
	[[ "$output" == *"Stopped: $TARGET already exists, and this installer didn't put it there."*"Move it somewhere else"* ]] || return 1
	[ -d "$TARGET/.git" ] || return 1
	rm -rf "$TARGET" # SAFE: test-owned fake home under tests/tmp-*

	FAKE_LATEST="https://github.com/RosBradley/glimwell-cli/releases"
	run as_user "$PROJECT_ROOT/glimwell-get.sh"
	[[ "$output" == *"Stopped: no Glimwell release is published yet."* ]] || return 1
	FAKE_OFFLINE=1
	run as_user "$PROJECT_ROOT/glimwell-get.sh"
	[[ "$output" == *"Stopped: couldn't reach GitHub"*"Check the internet connection"* ]] || return 1
	FAKE_OFFLINE=0
	TEST_OS=Linux run as_user "$PROJECT_ROOT/glimwell-get.sh"
	[[ "$output" == *"Stopped: Glimwell runs on macOS only."* ]] || return 1
	[ ! -e "$TARGET" ]
}

# Load the router without running it, the way the menu tests do.
prelude() {
	cat << 'EOF'
set -euo pipefail
export MOLE_TEST_MODE=1 MOLE_SKIP_MAIN=1 NO_COLOR=1
source "$PROJECT_ROOT/mole"
EOF
}

as_menu_user() {
	env HOME="$FAKE_HOME" PATH="$STUBS:$PATH" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_MODE=1 \
		GLIMWELL_TEST_OS=Darwin GLIMWELL_TEST_ARCH=arm64 \
		RELEASES="$RELEASES" CURL_LOG="$CURL_LOG" FAKE_LATEST="$FAKE_LATEST" FAKE_OFFLINE="$FAKE_OFFLINE" \
		COPYFILE_DISABLE=1 /bin/bash --noprofile --norc -c "$(prelude)$1" < /dev/null
}

@test "Update Glimwell in a copy from the installer installs the newest release and logs it" {
	publish 2026.10.26
	run as_user "$PROJECT_ROOT/glimwell-get.sh"
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	mkdir -p "$FAKE_HOME/.config/mole"
	printf 'Say hi\techo hi\n' > "$FAKE_HOME/.config/mole/my_commands"
	publish 2026.10.27
	run as_menu_user '
SCRIPT_DIR="$HOME/.local/share/glimwell"
update_mole true false
echo "after=$(_glimwell_release_version)"
update_mole
'
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[[ "$output" == *"Glimwell updates to its newest release; --force and --nightly are not used."* ]] || return 1
	[[ "$output" == *"Updating Glimwell 2026.10.26 to 2026.10.27..."*"Glimwell is now 2026.10.27."*"after=2026.10.27"* ]] || return 1
	[[ "$output" == *"Glimwell 2026.10.27 is the newest release; nothing to update."* ]] || return 1
	[ "$(cat "$TARGET/bin/analyze-go")" = "arm64 2026.10.27" ] || return 1
	[ "$(cat "$FAKE_HOME/.config/mole/my_commands")" = $'Say hi\techo hi' ] || return 1
	grep -q "REBUILT $TARGET (Glimwell 2026.10.26 -> 2026.10.27)" "$FAKE_HOME/Library/Logs/mole/operations.log"
}

@test "Update Glimwell never installs Mole over Glimwell, and says how each other copy updates" {
	run as_menu_user '
curl() { echo "CURL $*"; }
SCRIPT_DIR="$HOME/clone"
mkdir -p "$SCRIPT_DIR/scripts"
git init -q "$SCRIPT_DIR"
printf "echo SYNC_RAN\n" > "$SCRIPT_DIR/scripts/glimwell-sync.sh"
update_mole || echo "clone rc=$?"
SCRIPT_DIR="$HOME/unpacked"
mkdir -p "$SCRIPT_DIR/scripts"
update_mole || echo "unpacked rc=$?"
'
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[[ "$output" == *"This is a git copy of Glimwell. To update it, run these in $FAKE_HOME/clone:"$'\n'"  git pull"$'\n'"  make build"*"clone rc=1"* ]] || return 1
	[[ "$output" == *"This copy of Glimwell wasn't installed by its installer, so it can't update itself."*"curl -fsSL https://raw.githubusercontent.com/RosBradley/glimwell-cli/glimwell/glimwell-get.sh | bash"*"unpacked rc=1"* ]] || return 1
	[[ "$output" != *"SYNC_RAN"* && "$output" != *"CURL"* ]]
}

@test "a copy from the installer is told about newer Glimwell releases only" {
	publish 2026.10.26
	run as_user "$PROJECT_ROOT/glimwell-get.sh"
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	FAKE_LATEST="https://github.com/RosBradley/glimwell-cli/releases/tag/glimwell-2026.10.30"
	: > "$CURL_LOG"
	run as_menu_user '
SCRIPT_DIR="$HOME/.local/share/glimwell"
cache="$HOME/.cache/mole/update_message"
check_for_updates
for _ in $(seq 1 100); do
    [[ -s "$cache" ]] && break
    sleep 0.1
done
echo "notice=[$(read_update_message_cache "$cache")]"
# Checked once a day.
check_for_updates
echo "stamp=$(cut -d" " -f2 "$HOME/.cache/mole/glimwell_release_check")"
# Once 2026.10.30 is installed, its notice is gone; so is a notice of Mole'"'"'s.
printf "version=2026.10.30\n" > "$SCRIPT_DIR/.glimwell-release"
echo "installed=[$(read_update_message_cache "$cache")]"
printf "Update 9.9.9 available, run mo update" > "$cache"
echo "mole=[$(read_update_message_cache "$cache")]"
show_version | grep "^Glimwell version"
'
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[[ "$output" == *"notice=[Glimwell 2026.10.30 available, run glimwell update]"* ]] || return 1
	[[ "$output" == *"stamp=86400"* ]] || return 1
	[[ "$output" == *"installed=[]"*"mole=[]"* ]] || return 1
	[[ "$output" == *"Glimwell version 2026.10.30"* ]] || return 1
	[ "$(grep -c "releases/latest" "$CURL_LOG")" -eq 1 ]
}

@test "a git folder keeps Mole's update check" {
	run as_menu_user '
_glimwell_official_check_for_updates() { echo "MOLE_CHECK"; }
SCRIPT_DIR="$HOME/fork"
mkdir -p "$SCRIPT_DIR/scripts"
git init -q "$SCRIPT_DIR"
: > "$SCRIPT_DIR/scripts/glimwell-sync.sh"
check_for_updates
printf "Update 9.9.9 available, run mo update" > "$HOME/notice"
touch -t 203001010000 "$HOME/notice"
echo "mole=[$(read_update_message_cache "$HOME/notice")]"
'
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[[ "$output" == *"MOLE_CHECK"* ]] || return 1
	[[ "$output" == *"mole=[Update 9.9.9 available, run glimwell update]"* ]]
}

# A glimwell git folder with its GitHub copy (a bare repository) and the
# publish script, on the glimwell branch, pushed.
make_repo() {
	export GIT_AUTHOR_NAME=Tester GIT_AUTHOR_EMAIL=tester@example.com
	export GIT_COMMITTER_NAME=Tester GIT_COMMITTER_EMAIL=tester@example.com
	ORIGIN="$HOME/origin.git"
	WORK="$HOME/work"
	rm -rf "$ORIGIN" "$WORK" # SAFE: test-owned scratch under tests/tmp-*
	git init -q --bare "$ORIGIN"
	git init -q "$WORK"
	git -C "$WORK" checkout -q -b glimwell
	mkdir -p "$WORK/scripts"
	cp "$PROJECT_ROOT/scripts/glimwell-release.sh" "$PROJECT_ROOT/scripts/glimwell-release-build.sh" "$WORK/scripts/"
	printf 'VERSION="1.64.0"\n' > "$WORK/mole"
	git -C "$WORK" add -A
	git -C "$WORK" commit -q -m "First"
	git -C "$WORK" remote add origin "$ORIGIN"
	git -C "$WORK" push -q origin glimwell
	export ORIGIN WORK
}

publish_release() {
	(cd "$WORK" && env MOLE_TEST_MODE=1 GLIMWELL_TEST_TODAY=2026.10.26 /bin/bash -c '
source scripts/glimwell-release.sh
interactive() { return 0; }
main
') <<< "$1"
}

@test "publishing tags the pushed commit with today's date, then .2 for a second release" {
	make_repo
	run publish_release ""
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[[ "$output" == *"Publish Glimwell 2026.10.26, based on Mole 1.64.0, from commit "* ]] || return 1
	[[ "$output" == *"Pushed glimwell-2026.10.26. GitHub is testing and building Glimwell 2026.10.26 now"* ]] || return 1
	git -C "$ORIGIN" rev-parse --verify --quiet refs/tags/glimwell-2026.10.26 > /dev/null || return 1

	run publish_release ""
	[ "$status" -eq 1 ] || { echo "$output"; return 1; }
	[[ "$output" == *"Stopped: this commit is already tagged as glimwell-2026.10.26. If GitHub didn't publish it, remove the tag"* ]] || return 1

	git -C "$WORK" commit -q --allow-empty -m "Second"
	run publish_release ""
	[ "$status" -eq 1 ] || { echo "$output"; return 1; }
	[[ "$output" == *"Stopped: this commit isn't on GitHub yet, so GitHub can't build it. Push first: git push origin glimwell"* ]] || return 1
	git -C "$WORK" push -q origin glimwell
	# ESC publishes nothing.
	run publish_release $'\e'
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[[ "$output" == *"Cancelled; nothing was published."* ]] || return 1
	! git -C "$ORIGIN" rev-parse --verify --quiet refs/tags/glimwell-2026.10.26.2 > /dev/null || return 1
	run publish_release ""
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	git -C "$ORIGIN" rev-parse --verify --quiet refs/tags/glimwell-2026.10.26.2 > /dev/null
}

@test "publishing stops on uncommitted changes or another branch, naming what to do" {
	make_repo
	printf 'changed\n' >> "$WORK/mole"
	run publish_release ""
	[ "$status" -eq 1 ] || { echo "$output"; return 1; }
	[[ "$output" == *"Stopped: there are uncommitted changes. Commit and push them first"* ]] || return 1
	git -C "$WORK" checkout -q -- mole
	git -C "$WORK" checkout -q -b main
	run publish_release ""
	[ "$status" -eq 1 ] || { echo "$output"; return 1; }
	[[ "$output" == *"Stopped: you're on 'main'. Releases come from glimwell. Run: git checkout glimwell"* ]] || return 1
	[ -z "$(git -C "$ORIGIN" tag)" ]
}

@test "the release build packs this commit, the Go parts for both chips, checksums and notes" {
	make_repo
	git -C "$WORK" tag -a glimwell-2026.10.20 -m old
	git -C "$WORK" commit -q --allow-empty -m "Add AI models"
	git -C "$WORK" checkout -q -b main
	git -C "$WORK" commit -q --allow-empty -m "Mole fix"
	git -C "$WORK" checkout -q glimwell
	git -C "$WORK" merge -q --no-ff --no-edit main
	git -C "$WORK" commit -q --allow-empty -m "Merge remote-tracking branch 'origin/glimwell' into glimwell"
	git -C "$WORK" commit -q --allow-empty -m "GLIMWELL.md: AI models"
	cat > "$STUBS/go" << 'EOF'
#!/bin/bash
out="" last=""
while (($#)); do
    case "$1" in
        -o) out="$2"; shift 2 ;;
        *) last="$1"; shift ;;
    esac
done
printf '%s %s %s\n' "$GOOS" "$GOARCH" "$last" > "$out"
EOF
	chmod +x "$STUBS/go"
	run env PATH="$STUBS:$PATH" COPYFILE_DISABLE=1 /bin/bash "$WORK/scripts/glimwell-release-build.sh" 2026.10.26 "$HOME/dist"
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	cd "$HOME/dist"
	run sha256_lines -c SHA256SUMS
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[[ "$output" == *"glimwell.tar.gz: OK"*"glimwell-go-darwin-arm64.tar.gz: OK"*"glimwell-go-darwin-amd64.tar.gz: OK"* ]] || return 1
	[ "$(tar -xzOf glimwell.tar.gz glimwell/.glimwell-release | head -n 1)" = "version=2026.10.26" ] || return 1
	tar -xzOf glimwell.tar.gz glimwell/.glimwell-release | grep -q '^mole=1.64.0$' || return 1
	[ "$(tar -xzOf glimwell-go-darwin-amd64.tar.gz bin/glimwell-models-go)" = "darwin amd64 ./cmd/glimwell-models" ] || return 1
	[ "$(tar -tzf glimwell-go-darwin-arm64.tar.gz | grep -c -- '-go$')" -eq 5 ] || return 1
	run cat notes.md
	[[ "$output" == *"Glimwell 2026.10.26, based on Mole 1.64.0."*"glimwell-get.sh | bash"* ]] || return 1
	[[ "$output" == *$'Changes since 2026.10.20:\n\n- GLIMWELL.md: AI models\n- Brought in Mole\'s latest changes\n- Add AI models'* ]] || return 1
	[[ "$output" != *"origin/glimwell"* ]] || return 1

	run /bin/bash "$WORK/scripts/glimwell-release-build.sh" 26.10.2026 "$HOME/dist2"
	[ "$status" -eq 1 ] || return 1
	[[ "$output" == *"usage: bash scripts/glimwell-release-build.sh YYYY.MM.DD[.N] OUT_DIR"* ]]
}

# A git folder like the user's, for Update Glimwell's sync: origin and an
# upstream with main, the sync script, Go source and built Go parts, and a
# make that only notes it ran.
make_sync_repo() {
	export GIT_AUTHOR_NAME=Tester GIT_AUTHOR_EMAIL=tester@example.com
	export GIT_COMMITTER_NAME=Tester GIT_COMMITTER_EMAIL=tester@example.com
	ORIGIN="$HOME/origin.git"
	UPSTREAM="$HOME/upstream.git"
	WORK="$HOME/work"
	MAKE_LOG="$HOME/make.log"
	rm -rf "$ORIGIN" "$UPSTREAM" "$WORK" "$MAKE_LOG" # SAFE: test-owned scratch under tests/tmp-*
	git init -q --bare "$ORIGIN"
	git init -q --bare "$UPSTREAM"
	git init -q "$WORK"
	git -C "$WORK" checkout -q -b main
	mkdir -p "$WORK/scripts" "$WORK/cmd/status" "$WORK/bin"
	cp "$PROJECT_ROOT/scripts/glimwell-sync.sh" "$WORK/scripts/"
	printf 'package main\n' > "$WORK/cmd/status/main.go"
	printf 'bin/*-go\n' > "$WORK/.gitignore"
	git -C "$WORK" add -A
	git -C "$WORK" commit -q -m "First"
	git -C "$WORK" remote add upstream "$UPSTREAM"
	git -C "$WORK" push -q upstream main
	git -C "$WORK" checkout -q -b glimwell
	git -C "$WORK" remote add origin "$ORIGIN"
	git -C "$WORK" push -q origin main glimwell
	local part
	for part in analyze-go status-go glimwell-updates-go glimwell-models-go glimwell-view-go; do
		printf '#!/bin/sh\n' > "$WORK/bin/$part"
		chmod +x "$WORK/bin/$part"
	done
	printf '#!/bin/bash\nprintf "make %%s\\n" "$*" >> "%s"\n' "$MAKE_LOG" > "$STUBS/make"
	printf '#!/bin/bash\nexit 0\n' > "$STUBS/go"
	chmod +x "$STUBS/make" "$STUBS/go"
	export ORIGIN UPSTREAM WORK MAKE_LOG
}

# Make the Go parts older than the Go source, as after a code change.
age_go_parts() {
	touch -t 202601010000 "$WORK"/bin/*-go
}

run_sync() {
	(cd "$WORK" && PATH="$STUBS:$PATH" /bin/bash scripts/glimwell-sync.sh)
}

@test "Update Glimwell's sync rebuilds old Go parts even when it stops on uncommitted changes or no network" {
	make_sync_repo
	age_go_parts
	printf '// changed\n' >> "$WORK/cmd/status/main.go"
	run run_sync
	[ "$status" -eq 1 ] || { echo "$output"; return 1; }
	[[ "$output" == *"Rebuilding Analyze, Status, Software updates, Ollama models and the command screen first, from the code in this folder..."*"Stopped: there are uncommitted changes. Commit them first"* ]] || return 1
	[ "$(cat "$MAKE_LOG")" = "make build" ] || return 1

	git -C "$WORK" commit -q -am "Change"
	git -C "$WORK" remote set-url origin "$HOME/missing.git"
	rm -f "$MAKE_LOG" # SAFE: test-owned scratch log
	age_go_parts
	run run_sync
	[ "$status" -eq 1 ] || { echo "$output"; return 1; }
	[[ "$output" == *"Rebuilding"*"Stopped: could not reach origin"* ]] || return 1
	[ "$(cat "$MAKE_LOG")" = "make build" ]
}

@test "Update Glimwell's sync builds nothing when it stops and the Go parts are current" {
	make_sync_repo
	printf 'changed\n' >> "$WORK/scripts/glimwell-sync.sh"
	run run_sync
	[ "$status" -eq 1 ] || { echo "$output"; return 1; }
	[[ "$output" == *"Stopped: there are uncommitted changes."* ]] || return 1
	[[ "$output" != *"Rebuilding"* ]] || return 1
	[ ! -e "$MAKE_LOG" ]
}

@test "Update Glimwell's sync still leaves a conflicted merge unbuilt" {
	make_sync_repo
	printf 'package main // glimwell\n' > "$WORK/cmd/status/main.go"
	git -C "$WORK" commit -q -am "Glimwell's change"
	git -C "$WORK" push -q origin glimwell
	git -C "$WORK" checkout -q main
	printf 'package main // mole\n' > "$WORK/cmd/status/main.go"
	git -C "$WORK" commit -q -am "Mole's change"
	git -C "$WORK" push -q upstream main
	git -C "$WORK" reset -q --hard HEAD~1
	git -C "$WORK" checkout -q glimwell
	age_go_parts
	run run_sync
	[ "$status" -eq 1 ] || { echo "$output"; return 1; }
	[[ "$output" == *"The merge stopped on a conflict: Mole changed the same lines"* ]] || return 1
	[[ "$output" != *"Rebuilding"* ]] || return 1
	[ ! -e "$MAKE_LOG" ]
}

@test "Update Glimwell's sync keeps Glimwell's side of Mole files it removed or rewrote" {
	make_sync_repo
	git -C "$WORK" checkout -q main
	printf '# Mole\n' > "$WORK/README.md"
	printf 'Email Mole\n' > "$WORK/SECURITY.md"
	git -C "$WORK" add -A
	git -C "$WORK" commit -q -m "Mole's docs"
	git -C "$WORK" push -q upstream main
	git -C "$WORK" checkout -q glimwell
	git -C "$WORK" merge -q --no-edit main
	git -C "$WORK" rm -q README.md
	printf 'Report Glimwell issues privately\n' > "$WORK/SECURITY.md"
	git -C "$WORK" commit -q -am "Glimwell's docs"
	git -C "$WORK" push -q origin glimwell
	git -C "$WORK" checkout -q main
	printf '# Mole, now with more\n' > "$WORK/README.md"
	printf 'Email Mole at a new address\n' > "$WORK/SECURITY.md"
	git -C "$WORK" commit -q -am "Mole's new docs"
	git -C "$WORK" push -q upstream main
	git -C "$WORK" reset -q --hard HEAD~1
	git -C "$WORK" checkout -q glimwell
	run run_sync
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[[ "$output" == *"Kept Glimwell's side of "*"README.md"*"which Glimwell removed or rewrote."* ]] || { echo "$output"; return 1; }
	[ ! -e "$WORK/README.md" ] || return 1
	[ "$(cat "$WORK/SECURITY.md")" = "Report Glimwell issues privately" ] || return 1
	git -C "$WORK" merge-base --is-ancestor upstream/main glimwell || return 1
	[ -z "$(git -C "$WORK" status --porcelain --untracked-files=no)" ]
}

@test "Update Glimwell's sync still stops when another file conflicts beside them" {
	make_sync_repo
	git -C "$WORK" checkout -q main
	printf '# Mole\n' > "$WORK/README.md"
	git -C "$WORK" add -A
	git -C "$WORK" commit -q -m "Mole's docs"
	git -C "$WORK" push -q upstream main
	git -C "$WORK" checkout -q glimwell
	git -C "$WORK" merge -q --no-edit main
	git -C "$WORK" rm -q README.md
	printf 'package main // glimwell\n' > "$WORK/cmd/status/main.go"
	git -C "$WORK" commit -q -am "Glimwell's changes"
	git -C "$WORK" push -q origin glimwell
	git -C "$WORK" checkout -q main
	printf '# Mole, now with more\n' > "$WORK/README.md"
	printf 'package main // mole\n' > "$WORK/cmd/status/main.go"
	git -C "$WORK" commit -q -am "Mole's changes"
	git -C "$WORK" push -q upstream main
	git -C "$WORK" reset -q --hard HEAD~1
	git -C "$WORK" checkout -q glimwell
	run run_sync
	[ "$status" -eq 1 ] || { echo "$output"; return 1; }
	[[ "$output" == *"The merge stopped on a conflict: Mole changed the same lines"*"    cmd/status/main.go"* ]] || { echo "$output"; return 1; }
	[[ "$output" != *"    README.md"* ]] || return 1
	git -C "$WORK" rev-parse -q --verify MERGE_HEAD > /dev/null
}

@test "Glimwell's incident ledger names real commits, layers and catchers" {
	run python3 "$PROJECT_ROOT/scripts/audit_incidents.py" --ledger "$PROJECT_ROOT/docs/glimwell-incidents.md"
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[[ "$output" == "incidents-audit-ok rows="[1-9]* ]]
}
