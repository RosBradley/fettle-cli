#!/usr/bin/env bats
# shellcheck disable=SC2016  # inner bash scripts expand their own arguments
# shellcheck disable=SC2030,SC2031  # each test sets the fake GitHub's state for itself
# MoreMole releases: moremole-get.sh installs and updates from them, Update
# MoreMole picks the right way to update, scripts/moremole-release.sh
# publishes one and scripts/moremole-release-build.sh builds its files. A
# fake curl stands in for GitHub, serving releases from a folder.

load helpers/common

setup_file() {
	mole_test_setup_home "moremole-release"
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
	TARGET="$FAKE_HOME/.local/share/moremole"
	mkdir -p "$FAKE_HOME" "$STUBS" "$RELEASES"
	: > "$CURL_LOG"
	FAKE_LATEST="https://github.com/RosBradley/moremole/releases"
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
    https://github.com/RosBradley/moremole/releases/latest) printf '%s' "$FAKE_LATEST" ;;
    https://github.com/RosBradley/moremole/releases/download/*)
        file="$RELEASES/${url#https://github.com/RosBradley/moremole/releases/download/}"
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
	local version="$1" dir="$RELEASES/moremole-$1" src="$HOME/src-$1" arch part
	rm -rf "$src" # SAFE: test-owned scratch under tests/tmp-*
	mkdir -p "$dir" "$src/moremole/scripts" "$src/moremole/lib/moremole"
	cp "$PROJECT_ROOT/moremole-get.sh" "$src/moremole/"
	cp "$PROJECT_ROOT/scripts/moremole-install.sh" "$src/moremole/scripts/"
	printf '#!/bin/bash\necho "MOREMOLE %s"\n' "$version" > "$src/moremole/mole"
	chmod +x "$src/moremole/mole"
	: > "$src/moremole/lib/moremole/menu.sh"
	printf 'version=%s\ncommit=abc1234\nmole=1.64.0\n' "$version" > "$src/moremole/.moremole-release"
	tar -czf "$dir/moremole.tar.gz" -C "$src" moremole
	for arch in arm64 amd64; do
		mkdir -p "$src/go-$arch/bin"
		for part in analyze-go status-go moremole-updates-go moremole-models-go moremole-view-go; do
			printf '%s %s\n' "$arch" "$version" > "$src/go-$arch/bin/$part"
		done
		tar -czf "$dir/moremole-go-darwin-$arch.tar.gz" -C "$src/go-$arch" bin
	done
	(cd "$dir" && sha256_lines moremole.tar.gz moremole-go-darwin-arm64.tar.gz moremole-go-darwin-amd64.tar.gz > SHA256SUMS)
	FAKE_LATEST="https://github.com/RosBradley/moremole/releases/tag/moremole-$version"
}

# Run a script as a Mac user of the fake home, with GitHub stood in for.
as_user() {
	env HOME="$FAKE_HOME" PATH="$STUBS:/usr/bin:/bin" MOLE_TEST_MODE=1 \
		MOREMOLE_TEST_OS="${TEST_OS:-Darwin}" MOREMOLE_TEST_ARCH="${TEST_ARCH:-arm64}" \
		RELEASES="$RELEASES" CURL_LOG="$CURL_LOG" FAKE_LATEST="$FAKE_LATEST" FAKE_OFFLINE="$FAKE_OFFLINE" \
		COPYFILE_DISABLE=1 /bin/bash "$@" < /dev/null
}

@test "the installer checks the downloads, installs the newest release and sets up the commands" {
	publish 2026.10.26
	run as_user "$PROJECT_ROOT/moremole-get.sh"
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[[ "$output" == *"Installing MoreMole 2026.10.26..."*"MoreMole 2026.10.26 is installed in $TARGET."*"Setting up the moremole and mm commands"* ]] || return 1
	[ "$(readlink "$FAKE_HOME/.local/bin/moremole")" = "$TARGET/mole" ] || return 1
	[ "$(readlink "$FAKE_HOME/.local/bin/mm")" = "$TARGET/mole" ] || return 1
	[ "$(cat "$TARGET/bin/moremole-view-go")" = "arm64 2026.10.26" ] || return 1
	[ -x "$TARGET/bin/analyze-go" ] || return 1
	grep -q '^version=2026.10.26$' "$TARGET/.moremole-release" || return 1
	# Only the Apple silicon build was downloaded, and the work folder is gone.
	! grep -q "amd64" "$CURL_LOG" || return 1
	[ "$(ls -A "$FAKE_HOME/.local/share")" = "moremole" ] || return 1

	# Running it again repairs the commands and downloads nothing.
	rm "$FAKE_HOME/.local/bin/mm"
	: > "$CURL_LOG"
	run as_user "$PROJECT_ROOT/moremole-get.sh"
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[[ "$output" == *"MoreMole 2026.10.26 is the newest release; nothing to update."* ]] || return 1
	[ "$(readlink "$FAKE_HOME/.local/bin/mm")" = "$TARGET/mole" ] || return 1
	run grep -c "releases/download" "$CURL_LOG"
	[ "$output" = "0" ]
}

@test "an Intel Mac gets the Intel build" {
	publish 2026.10.26
	TEST_ARCH=amd64 run as_user "$PROJECT_ROOT/moremole-get.sh"
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[ "$(cat "$TARGET/bin/status-go")" = "amd64 2026.10.26" ]
}

@test "a download that doesn't match its checksum changes nothing" {
	publish 2026.10.26
	run as_user "$PROJECT_ROOT/moremole-get.sh"
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	publish 2026.10.27
	printf 'tampered' >> "$RELEASES/moremole-2026.10.27/moremole-go-darwin-arm64.tar.gz"
	run as_user "$TARGET/moremole-get.sh" --update
	[ "$status" -eq 1 ] || { echo "$output"; return 1; }
	[[ "$output" == *"Stopped: moremole-go-darwin-arm64.tar.gz doesn't match the checksum published with MoreMole 2026.10.27. Nothing was changed."* ]] || return 1
	[[ "$output" == *"report it at https://github.com/RosBradley/moremole/issues"* ]] || return 1
	grep -q '^version=2026.10.26$' "$TARGET/.moremole-release" || return 1
	[ "$(cat "$TARGET/bin/status-go")" = "arm64 2026.10.26" ] || return 1
	[ "$(ls -A "$FAKE_HOME/.local/share")" = "moremole" ] || return 1

	# A release without a checksum for a file is refused the same way.
	publish 2026.10.28
	grep -v "moremole.tar.gz" "$RELEASES/moremole-2026.10.28/SHA256SUMS" > "$HOME/sums"
	cp "$HOME/sums" "$RELEASES/moremole-2026.10.28/SHA256SUMS"
	run as_user "$TARGET/moremole-get.sh" --update
	[ "$status" -eq 1 ] || { echo "$output"; return 1; }
	[[ "$output" == *"MoreMole 2026.10.28 lists no checksum for moremole.tar.gz"* ]] || return 1
	grep -q '^version=2026.10.26$' "$TARGET/.moremole-release"
}

@test "the installer leaves alone a folder it didn't put there, and says why it can't go on" {
	mkdir -p "$TARGET/.git"
	publish 2026.10.26
	run as_user "$PROJECT_ROOT/moremole-get.sh"
	[ "$status" -eq 1 ] || { echo "$output"; return 1; }
	[[ "$output" == *"Stopped: $TARGET already exists, and this installer didn't put it there."*"Move it somewhere else"* ]] || return 1
	[ -d "$TARGET/.git" ] || return 1
	rm -rf "$TARGET" # SAFE: test-owned fake home under tests/tmp-*

	FAKE_LATEST="https://github.com/RosBradley/moremole/releases"
	run as_user "$PROJECT_ROOT/moremole-get.sh"
	[[ "$output" == *"Stopped: no MoreMole release is published yet."* ]] || return 1
	FAKE_OFFLINE=1
	run as_user "$PROJECT_ROOT/moremole-get.sh"
	[[ "$output" == *"Stopped: couldn't reach GitHub"*"Check the internet connection"* ]] || return 1
	FAKE_OFFLINE=0
	TEST_OS=Linux run as_user "$PROJECT_ROOT/moremole-get.sh"
	[[ "$output" == *"Stopped: MoreMole runs on macOS only."* ]] || return 1
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
		MOREMOLE_TEST_OS=Darwin MOREMOLE_TEST_ARCH=arm64 \
		RELEASES="$RELEASES" CURL_LOG="$CURL_LOG" FAKE_LATEST="$FAKE_LATEST" FAKE_OFFLINE="$FAKE_OFFLINE" \
		COPYFILE_DISABLE=1 /bin/bash --noprofile --norc -c "$(prelude)$1" < /dev/null
}

@test "Update MoreMole in a copy from the installer installs the newest release and logs it" {
	publish 2026.10.26
	run as_user "$PROJECT_ROOT/moremole-get.sh"
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	mkdir -p "$FAKE_HOME/.config/mole"
	printf 'Say hi\techo hi\n' > "$FAKE_HOME/.config/mole/my_commands"
	publish 2026.10.27
	run as_menu_user '
SCRIPT_DIR="$HOME/.local/share/moremole"
update_mole true false
echo "after=$(_moremole_release_version)"
update_mole
'
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[[ "$output" == *"MoreMole updates to its newest release; --force and --nightly are not used."* ]] || return 1
	[[ "$output" == *"Updating MoreMole 2026.10.26 to 2026.10.27..."*"MoreMole is now 2026.10.27."*"after=2026.10.27"* ]] || return 1
	[[ "$output" == *"MoreMole 2026.10.27 is the newest release; nothing to update."* ]] || return 1
	[ "$(cat "$TARGET/bin/analyze-go")" = "arm64 2026.10.27" ] || return 1
	[ "$(cat "$FAKE_HOME/.config/mole/my_commands")" = $'Say hi\techo hi' ] || return 1
	grep -q "REBUILT $TARGET (MoreMole 2026.10.26 -> 2026.10.27)" "$FAKE_HOME/Library/Logs/mole/operations.log"
}

@test "Update MoreMole never installs Mole over MoreMole, and says how each other copy updates" {
	run as_menu_user '
curl() { echo "CURL $*"; }
SCRIPT_DIR="$HOME/clone"
mkdir -p "$SCRIPT_DIR/scripts"
git init -q "$SCRIPT_DIR"
printf "echo SYNC_RAN\n" > "$SCRIPT_DIR/scripts/moremole-sync.sh"
update_mole || echo "clone rc=$?"
SCRIPT_DIR="$HOME/unpacked"
mkdir -p "$SCRIPT_DIR/scripts"
update_mole || echo "unpacked rc=$?"
'
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[[ "$output" == *"This is a git copy of MoreMole. To update it, run these in $FAKE_HOME/clone:"$'\n'"  git pull"$'\n'"  make build"*"clone rc=1"* ]] || return 1
	[[ "$output" == *"This copy of MoreMole wasn't installed by its installer, so it can't update itself."*"curl -fsSL https://raw.githubusercontent.com/RosBradley/moremole/moremole/moremole-get.sh | bash"*"unpacked rc=1"* ]] || return 1
	[[ "$output" != *"SYNC_RAN"* && "$output" != *"CURL"* ]]
}

@test "a copy from the installer is told about newer MoreMole releases only" {
	publish 2026.10.26
	run as_user "$PROJECT_ROOT/moremole-get.sh"
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	FAKE_LATEST="https://github.com/RosBradley/moremole/releases/tag/moremole-2026.10.30"
	: > "$CURL_LOG"
	run as_menu_user '
SCRIPT_DIR="$HOME/.local/share/moremole"
cache="$HOME/.cache/mole/update_message"
check_for_updates
for _ in $(seq 1 100); do
    [[ -s "$cache" ]] && break
    sleep 0.1
done
echo "notice=[$(read_update_message_cache "$cache")]"
# Checked once a day.
check_for_updates
echo "stamp=$(cut -d" " -f2 "$HOME/.cache/mole/moremole_release_check")"
# Once 2026.10.30 is installed, its notice is gone; so is a notice of Mole'"'"'s.
printf "version=2026.10.30\n" > "$SCRIPT_DIR/.moremole-release"
echo "installed=[$(read_update_message_cache "$cache")]"
printf "Update 9.9.9 available, run mo update" > "$cache"
echo "mole=[$(read_update_message_cache "$cache")]"
show_version | grep "^MoreMole:"
'
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[[ "$output" == *"notice=[MoreMole 2026.10.30 available, run moremole update]"* ]] || return 1
	[[ "$output" == *"stamp=86400"* ]] || return 1
	[[ "$output" == *"installed=[]"*"mole=[]"* ]] || return 1
	[[ "$output" == *"MoreMole: github.com/RosBradley/moremole (release 2026.10.30)"* ]] || return 1
	[ "$(grep -c "releases/latest" "$CURL_LOG")" -eq 1 ]
}

@test "a git folder keeps Mole's update check" {
	run as_menu_user '
_moremole_official_check_for_updates() { echo "MOLE_CHECK"; }
SCRIPT_DIR="$HOME/fork"
mkdir -p "$SCRIPT_DIR/scripts"
git init -q "$SCRIPT_DIR"
: > "$SCRIPT_DIR/scripts/moremole-sync.sh"
check_for_updates
printf "Update 9.9.9 available, run mo update" > "$HOME/notice"
touch -t 203001010000 "$HOME/notice"
echo "mole=[$(read_update_message_cache "$HOME/notice")]"
'
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[[ "$output" == *"MOLE_CHECK"* ]] || return 1
	[[ "$output" == *"mole=[Update 9.9.9 available, run moremole update]"* ]]
}

# A moremole git folder with its GitHub copy (a bare repository) and the
# publish script, on the moremole branch, pushed.
make_repo() {
	export GIT_AUTHOR_NAME=Tester GIT_AUTHOR_EMAIL=tester@example.com
	export GIT_COMMITTER_NAME=Tester GIT_COMMITTER_EMAIL=tester@example.com
	ORIGIN="$HOME/origin.git"
	WORK="$HOME/work"
	rm -rf "$ORIGIN" "$WORK" # SAFE: test-owned scratch under tests/tmp-*
	git init -q --bare "$ORIGIN"
	git init -q "$WORK"
	git -C "$WORK" checkout -q -b moremole
	mkdir -p "$WORK/scripts"
	cp "$PROJECT_ROOT/scripts/moremole-release.sh" "$PROJECT_ROOT/scripts/moremole-release-build.sh" "$WORK/scripts/"
	printf 'VERSION="1.64.0"\n' > "$WORK/mole"
	git -C "$WORK" add -A
	git -C "$WORK" commit -q -m "First"
	git -C "$WORK" remote add origin "$ORIGIN"
	git -C "$WORK" push -q origin moremole
	export ORIGIN WORK
}

publish_release() {
	(cd "$WORK" && env MOLE_TEST_MODE=1 MOREMOLE_TEST_TODAY=2026.10.26 /bin/bash -c '
source scripts/moremole-release.sh
interactive() { return 0; }
main
') <<< "$1"
}

@test "publishing tags the pushed commit with today's date, then .2 for a second release" {
	make_repo
	run publish_release ""
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[[ "$output" == *"Publish MoreMole 2026.10.26, based on Mole 1.64.0, from commit "* ]] || return 1
	[[ "$output" == *"Pushed moremole-2026.10.26. GitHub is testing and building MoreMole 2026.10.26 now"* ]] || return 1
	git -C "$ORIGIN" rev-parse --verify --quiet refs/tags/moremole-2026.10.26 > /dev/null || return 1

	run publish_release ""
	[ "$status" -eq 1 ] || { echo "$output"; return 1; }
	[[ "$output" == *"Stopped: this commit is already tagged as moremole-2026.10.26. If GitHub didn't publish it, remove the tag"* ]] || return 1

	git -C "$WORK" commit -q --allow-empty -m "Second"
	run publish_release ""
	[ "$status" -eq 1 ] || { echo "$output"; return 1; }
	[[ "$output" == *"Stopped: this commit isn't on GitHub yet, so GitHub can't build it. Push first: git push origin moremole"* ]] || return 1
	git -C "$WORK" push -q origin moremole
	# ESC publishes nothing.
	run publish_release $'\e'
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[[ "$output" == *"Cancelled; nothing was published."* ]] || return 1
	! git -C "$ORIGIN" rev-parse --verify --quiet refs/tags/moremole-2026.10.26.2 > /dev/null || return 1
	run publish_release ""
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	git -C "$ORIGIN" rev-parse --verify --quiet refs/tags/moremole-2026.10.26.2 > /dev/null
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
	[[ "$output" == *"Stopped: you're on 'main'. Releases come from moremole. Run: git checkout moremole"* ]] || return 1
	[ -z "$(git -C "$ORIGIN" tag)" ]
}

@test "the release build packs this commit, the Go parts for both chips, checksums and notes" {
	make_repo
	git -C "$WORK" tag -a moremole-2026.10.20 -m old
	git -C "$WORK" commit -q --allow-empty -m "Add AI models"
	git -C "$WORK" checkout -q -b main
	git -C "$WORK" commit -q --allow-empty -m "Mole fix"
	git -C "$WORK" checkout -q moremole
	git -C "$WORK" merge -q --no-ff --no-edit main
	git -C "$WORK" commit -q --allow-empty -m "Merge remote-tracking branch 'origin/moremole' into moremole"
	git -C "$WORK" commit -q --allow-empty -m "MOREMOLE.md: AI models"
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
	run env PATH="$STUBS:$PATH" COPYFILE_DISABLE=1 /bin/bash "$WORK/scripts/moremole-release-build.sh" 2026.10.26 "$HOME/dist"
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	cd "$HOME/dist"
	run sha256_lines -c SHA256SUMS
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[[ "$output" == *"moremole.tar.gz: OK"*"moremole-go-darwin-arm64.tar.gz: OK"*"moremole-go-darwin-amd64.tar.gz: OK"* ]] || return 1
	[ "$(tar -xzOf moremole.tar.gz moremole/.moremole-release | head -n 1)" = "version=2026.10.26" ] || return 1
	tar -xzOf moremole.tar.gz moremole/.moremole-release | grep -q '^mole=1.64.0$' || return 1
	[ "$(tar -xzOf moremole-go-darwin-amd64.tar.gz bin/moremole-models-go)" = "darwin amd64 ./cmd/moremole-models" ] || return 1
	[ "$(tar -tzf moremole-go-darwin-arm64.tar.gz | grep -c -- '-go$')" -eq 5 ] || return 1
	run cat notes.md
	[[ "$output" == *"MoreMole 2026.10.26, based on Mole 1.64.0."*"moremole-get.sh | bash"* ]] || return 1
	[[ "$output" == *$'Changes since 2026.10.20:\n\n- MOREMOLE.md: AI models\n- Brought in Mole\'s latest changes\n- Add AI models'* ]] || return 1
	[[ "$output" != *"origin/moremole"* ]] || return 1

	run /bin/bash "$WORK/scripts/moremole-release-build.sh" 26.10.2026 "$HOME/dist2"
	[ "$status" -eq 1 ] || return 1
	[[ "$output" == *"usage: bash scripts/moremole-release-build.sh YYYY.MM.DD[.N] OUT_DIR"* ]]
}

# A git folder like the user's, for Update MoreMole's sync: origin and an
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
	cp "$PROJECT_ROOT/scripts/moremole-sync.sh" "$WORK/scripts/"
	printf 'package main\n' > "$WORK/cmd/status/main.go"
	printf 'bin/*-go\n' > "$WORK/.gitignore"
	git -C "$WORK" add -A
	git -C "$WORK" commit -q -m "First"
	git -C "$WORK" remote add upstream "$UPSTREAM"
	git -C "$WORK" push -q upstream main
	git -C "$WORK" checkout -q -b moremole
	git -C "$WORK" remote add origin "$ORIGIN"
	git -C "$WORK" push -q origin main moremole
	local part
	for part in analyze-go status-go moremole-updates-go moremole-models-go moremole-view-go; do
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
	(cd "$WORK" && PATH="$STUBS:$PATH" /bin/bash scripts/moremole-sync.sh)
}

@test "Update MoreMole's sync rebuilds old Go parts even when it stops on uncommitted changes or no network" {
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

@test "Update MoreMole's sync builds nothing when it stops and the Go parts are current" {
	make_sync_repo
	printf 'changed\n' >> "$WORK/scripts/moremole-sync.sh"
	run run_sync
	[ "$status" -eq 1 ] || { echo "$output"; return 1; }
	[[ "$output" == *"Stopped: there are uncommitted changes."* ]] || return 1
	[[ "$output" != *"Rebuilding"* ]] || return 1
	[ ! -e "$MAKE_LOG" ]
}

@test "Update MoreMole's sync still leaves a conflicted merge unbuilt" {
	make_sync_repo
	printf 'package main // moremole\n' > "$WORK/cmd/status/main.go"
	git -C "$WORK" commit -q -am "MoreMole's change"
	git -C "$WORK" push -q origin moremole
	git -C "$WORK" checkout -q main
	printf 'package main // mole\n' > "$WORK/cmd/status/main.go"
	git -C "$WORK" commit -q -am "Mole's change"
	git -C "$WORK" push -q upstream main
	git -C "$WORK" reset -q --hard HEAD~1
	git -C "$WORK" checkout -q moremole
	age_go_parts
	run run_sync
	[ "$status" -eq 1 ] || { echo "$output"; return 1; }
	[[ "$output" == *"The merge stopped on a conflict: Mole changed the same lines"* ]] || return 1
	[[ "$output" != *"Rebuilding"* ]] || return 1
	[ ! -e "$MAKE_LOG" ]
}
