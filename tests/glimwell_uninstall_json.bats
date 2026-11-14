#!/usr/bin/env bats
# glimwell: `uninstall --list --json`, `uninstall --dry-run --json --only FILE`
# and `uninstall --json --only FILE`, the interface the Glimwell app uses for
# Uninstall (lib/glimwell/uninstall_json.sh).
# The bash -c and Python scripts below expand in the child, not here; EXTRA is
# set per test, before the call that reads it.
# shellcheck disable=SC2016,SC2030,SC2031

load helpers/common

bats_require_minimum_version 1.5.0

setup_file() {
	mole_test_setup_home "glimwell-uninstall-json"
}

teardown_file() {
	mole_test_teardown_home
}

setup() {
	if [[ "$HOME" != "${BATS_TEST_DIRNAME}/tmp-"* ]]; then
		printf 'FATAL: HOME is not a test temp dir: %s\n' "$HOME" >&2
		return 1
	fi
	chmod -R u+w "$HOME" 2> /dev/null || true
	rm -rf "${HOME:?}"/*
	mkdir -p "$HOME/Applications" "$HOME/Library/Caches" "$HOME/stubs"
	# Anything that could quit an app or ask for a password records its call.
	local t
	for t in osascript sudo pkill killall; do
		printf '#!/bin/bash\necho "%s $*" >> "%s/stub.calls"\nexit 1\n' "$t" "$HOME" > "$HOME/stubs/$t"
		chmod +x "$HOME/stubs/$t"
	done
}

# make_app NAME BUNDLE_ID: an app in ~/Applications with the leftovers a real
# app leaves: a cache, app data, preferences, saved state, an App Group.
# Bundle IDs are odd words: the live-cache guard keeps a cache whose ID
# appears in any running process's command line.
make_app() {
	local name="$1" bundle="$2" app="$HOME/Applications/$1.app"
	mkdir -p "$app/Contents/MacOS"
	cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$bundle</string>
<key>CFBundleName</key><string>$name</string>
<key>CFBundleExecutable</key><string>$name</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
	printf '#!/bin/sh\nexit 0\n' > "$app/Contents/MacOS/$name"
	chmod +x "$app/Contents/MacOS/$name"
	mkdir -p "$HOME/Library/Caches/$bundle" "$HOME/Library/Application Support/$name" \
		"$HOME/Library/Preferences" "$HOME/Library/Group Containers/ABCDE12345.$bundle" \
		"$HOME/Library/Saved Application State/$bundle.savedState"
	echo cache > "$HOME/Library/Caches/$bundle/c"
	echo data > "$HOME/Library/Application Support/$name/d"
	echo prefs > "$HOME/Library/Preferences/$bundle.plist"
	echo group > "$HOME/Library/Group Containers/ABCDE12345.$bundle/g"
}

# Run `glimwell uninstall` with an app inventory confined to ~/Applications
# and no Homebrew. EXTRA is shell code run after loading, before main.
uj() {
	run --separate-stderr env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" PATH="$HOME/stubs:$PATH" \
		MOLE_TEST_NO_AUTH=1 MOLE_TEST_TRASH_DIR="$HOME/.TestTrash" EXTRA="${EXTRA:-}" \
		/bin/bash --noprofile --norc -c '
source "$PROJECT_ROOT/bin/uninstall.sh"
source "$PROJECT_ROOT/tests/helpers/uninstall.bash"
uninstall_print_app_search_dirs() { printf "%s\n" "$HOME/Applications"; }
mole_test_isolate_uninstall_inventory
is_homebrew_available() { return 1; }
eval "$EXTRA"
main "$@"' _ "$@"
}

# Every stdout line is one JSON object, the first is start, the last summary.
assert_json_stream() {
	[[ -n "$output" ]] || { echo "no output; stderr: $stderr"; return 1; }
	run_perl_check=$(printf '%s\n' "$output" | /usr/bin/perl -MJSON::PP -ne 'JSON::PP->new->decode($_); END { print "ok" }' 2>&1) ||
		{ echo "a line is not JSON: $run_perl_check"; echo "$output"; return 1; }
	[[ "${lines[0]}" == '{"type":"start"'* ]] || { echo "$output"; return 1; }
	[[ "${lines[${#lines[@]} - 1]}" == '{"type":"summary"'* ]] || { echo "$output"; return 1; }
}

sel() { printf '%s\n' "$@" > "$HOME/sel.txt"; }

@test "a selection file lists app and path IDs; every other line is refused" {
	make_app Fixture org.example.qzvujfix
	local app="$HOME/Applications/Fixture.app" line
	sel "app:$app" "" "path:$HOME/Library/Caches/org.example.qzvujfix"
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc -c '
source "$PROJECT_ROOT/bin/uninstall.sh"
glimwell_uninstall_selection_load "$HOME/sel.txt" 0 && printf "%s\n" "${#_GLIMWELL_UJ_SEL_APPS[@]} ${#_GLIMWELL_UJ_SEL_PATHS[@]}"'
	[[ "$output" == "1 1" ]] || { echo "$output"; return 1; }

	for line in "app:/Applications" "app:$HOME/Applications/../x.app" "app:relative/x.app" "app:$HOME/Applications/Fixture" \
		"path:/" "path:/Users" "path:$HOME/./Library" "path:$HOME//Library" "step:npm-cache" "rm -rf /" \
		"app:$app"$'\x01'; do
		sel "app:$app" "$line"
		uj --json --only "$HOME/sel.txt"
		[ "$status" -eq 1 ] || { echo "accepted: $line"; return 1; }
		[[ -z "$output" && "$stderr" == "glimwell uninstall: --only: line 2 "* ]] || { echo "[$line] $output / $stderr"; return 1; }
	done
	printf 'app:%s\n\0' "$app" > "$HOME/sel.txt"
	uj --json --only "$HOME/sel.txt"
	[[ "$status" -eq 1 && "$stderr" == *"NUL byte"* ]] || { echo "$stderr"; return 1; }
	sel "path:$HOME/Library/Caches/org.example.qzvujfix"
	uj --json --only "$HOME/sel.txt"
	[[ "$status" -eq 1 && "$stderr" == *"leftovers but no app"* ]] || { echo "$stderr"; return 1; }
	: > "$HOME/sel.txt"
	uj --json --only "$HOME/sel.txt"
	[[ "$status" -eq 1 && "$stderr" == *"lists no app"* ]] || { echo "$stderr"; return 1; }
	ln -s "$HOME/sel.txt" "$HOME/link.txt"
	uj --json --only "$HOME/link.txt"
	[[ "$status" -eq 1 && "$stderr" == *"not a link"* ]] || { echo "$stderr"; return 1; }
	[[ -d "$app" ]]
}

@test "uninstall --json refuses calls it was not built for, before any scan" {
	make_app Fixture org.example.qzvujfix
	sel "app:$HOME/Applications/Fixture.app"
	local -a call
	local expect
	while IFS='|' read -r expect args; do
		read -r -a call <<< "${args//SEL/$HOME/sel.txt}"
		uj "${call[@]}"
		[ "$status" -eq 1 ] || { echo "accepted: $args"; return 1; }
		[[ -z "$output" && "$stderr" == *"$expect"* ]] || { echo "[$args] $output / $stderr"; return 1; }
	done <<- 'CALLS'
		needs --only FILE|--json
		works only with --json|--only SEL
		takes no app names|--json --only SEL Fixture
		refuses --permanent|--json --permanent --only SEL
		refuses --permanent|--json --with-data --only SEL
		takes no --only|--list --json --only SEL
		needs a file|--json --only
	CALLS
	[[ -d "$HOME/Applications/Fixture.app" ]] || { echo "the app was touched"; return 1; }
	run grep -sE 'REMOVED|TRASHED|SKIPPED' "$HOME/Library/Logs/mole/operations.log"
	[ "$status" -ne 0 ] || { echo "a refused call logged an action: $output"; return 1; }
}

@test "preview items carry kind, preselect, caution and bytes, as JSON only, and change nothing" {
	make_app Fixture org.example.qzvujfix
	local app="$HOME/Applications/Fixture.app"
	sel "app:$app" "app:$HOME/Applications/Gone.app"
	uj --dry-run --json --only "$HOME/sel.txt"
	[ "$status" -eq 0 ] || { echo "$output / $stderr"; return 1; }
	assert_json_stream
	[[ "$output" == *"{\"type\":\"app\",\"app\":\"$app\",\"name\":\"Fixture\",\"bundle_id\":\"org.example.qzvujfix\",\"bytes\":"*",\"cask\":null,\"status\":\"ok\",\"running\":false,\"needs_admin\":false,\"bundle_only\":false,\"note\":null}"* ]] || { echo "$output"; return 1; }
	[[ "$output" == *"\"id\":\"path:$HOME/Library/Caches/org.example.qzvujfix\",\"app\":\"$app\",\"kind\":\"cache\",\"label\":\"Caches\",\"path\":\"$HOME/Library/Caches/org.example.qzvujfix\",\"bytes\":4096,\"preselect\":true,\"caution\":null}"* ]] || { echo "$output"; return 1; }
	[[ "$output" == *"\"kind\":\"data\",\"label\":\"Application Support\",\"path\":\"$HOME/Library/Application Support/Fixture\",\"bytes\":4096,\"preselect\":false,\"caution\":null}"* ]] || { echo "$output"; return 1; }
	[[ "$output" == *"\"kind\":\"data\",\"label\":\"Preferences\""*"\"preselect\":false"* ]] || { echo "$output"; return 1; }
	# Without Full Disk Access an App Group goes unmeasured, and it is shared.
	[[ "$output" == *"\"label\":\"Group Containers\",\"path\":\"$HOME/Library/Group Containers/ABCDE12345.org.example.qzvujfix\",\"bytes\":"*",\"preselect\":false,\"caution\":\"shared\"}"* ]] || { echo "$output"; return 1; }
	[[ "$output" == *"{\"type\":\"app\",\"app\":\"$HOME/Applications/Gone.app\",\"name\":\"Gone\",\"bundle_id\":null,\"bytes\":null,\"cask\":null,\"status\":\"missing\""* ]] || { echo "$output"; return 1; }
	[[ "${lines[${#lines[@]} - 1]}" == '{"type":"summary","dry_run":true,"status":"complete","exit":0,"apps":1,"items":5}' ]] || { echo "$output"; return 1; }
	[[ -d "$app" && -d "$HOME/Library/Caches/org.example.qzvujfix" && ! -d "$HOME/.TestTrash" ]] || { echo "the preview changed something"; return 1; }
	# A JSON preview writes no dry-run rows to the deletion log.
	run grep -s dry-run "$HOME/Library/Logs/mole/deletions.log"
	[ "$status" -ne 0 ] || { echo "$output"; return 1; }
}

@test "caution marks the user's own libraries and App Groups" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc -c '
source "$PROJECT_ROOT/bin/uninstall.sh"
for p in "Library/Group Containers/X.com.a" "Library/Application Support/Firefox/Profiles" \
	"Library/Containers/com.utmapp.UTM" "Library/Application Support/OpenEmu" "Library/Application Support/Foo"; do
	_glimwell_uj_caution "$HOME/$p" c; printf "%s=%s\n" "${p##*/}" "${c:-none}"
done'
	[[ "$output" == $'X.com.a=shared\nProfiles=library\ncom.utmapp.UTM=library\nOpenEmu=library\nFoo=none' ]] || { echo "$output"; return 1; }
}

@test "a listed app with no listed leftovers removes only the bundle, to the Trash" {
	make_app Fixture org.example.qzvujfix
	local app="$HOME/Applications/Fixture.app"
	sel "app:$app"
	uj --json --only "$HOME/sel.txt"
	[ "$status" -eq 0 ] || { echo "$output / $stderr"; return 1; }
	assert_json_stream
	[[ "${lines[1]}" == "{\"type\":\"app_start\",\"app\":\"$app\",\"name\":\"Fixture\"}" ]] || { echo "$output"; return 1; }
	[[ "${lines[2]}" == "{\"type\":\"removed\",\"app\":\"$app\",\"path\":\"$app\",\"detail\":"* ]] || { echo "$output"; return 1; }
	[[ "${lines[3]}" == "{\"type\":\"app_done\",\"app\":\"$app\",\"status\":\"removed\",\"reason\":null}" ]] || { echo "$output"; return 1; }
	[[ "${lines[4]}" == '{"type":"summary","dry_run":false,"status":"complete","exit":0,"apps":1,"removed":1,"kept":0}' ]] || { echo "$output"; return 1; }
	[[ ! -e "$app" ]] || { echo "the bundle survived"; return 1; }
	compgen -G "$HOME/.TestTrash/Fixture.app.*" > /dev/null || { echo "the bundle is not in the Trash"; return 1; }
	[[ -d "$HOME/Library/Caches/org.example.qzvujfix" && -d "$HOME/Library/Application Support/Fixture" &&
		-f "$HOME/Library/Preferences/org.example.qzvujfix.plist" ]] || { echo "an unlisted leftover was removed"; return 1; }
	run grep -c 'TRASHED' "$HOME/Library/Logs/mole/operations.log"
	[[ "$output" == 1 ]] || { echo "$output"; return 1; }
	run grep 'SKIPPED' "$HOME/Library/Logs/mole/operations.log"
	[ "$status" -ne 0 ] || { echo "an unlisted leftover got a SKIPPED row: $output"; return 1; }
}

@test "a listed leftover the fresh scan does not find, and an unlisted one it does find, both stay" {
	make_app Fixture org.example.qzvujfix
	local app="$HOME/Applications/Fixture.app" cache="$HOME/Library/Caches/org.example.qzvujfix"
	mkdir -p "$HOME/Library/Caches/com.example.unrelated" "$HOME/Documents/mine"
	sel "app:$app" "path:$cache" "path:$HOME/Library/Caches/com.example.unrelated" "path:$HOME/Documents/mine"
	uj --json --only "$HOME/sel.txt"
	[ "$status" -eq 0 ] || { echo "$output / $stderr"; return 1; }
	assert_json_stream
	[[ "$output" == *"{\"type\":\"removed\",\"app\":\"$app\",\"path\":\"$cache\",\"detail\":null}"* ]] || { echo "$output"; return 1; }
	[[ "$output" == *"{\"type\":\"kept\",\"app\":null,\"path\":\"$HOME/Library/Caches/com.example.unrelated\",\"reason\":\"not_found\""* ]] || { echo "$output"; return 1; }
	[[ "$output" == *"{\"type\":\"kept\",\"app\":null,\"path\":\"$HOME/Documents/mine\",\"reason\":\"not_found\""* ]] || { echo "$output"; return 1; }
	[[ ! -e "$app" && ! -e "$cache" ]] || { echo "a listed item survived"; return 1; }
	[[ -d "$HOME/Library/Caches/com.example.unrelated" && -d "$HOME/Documents/mine" ]] || { echo "a path the scan did not find was removed"; return 1; }
	[[ -d "$HOME/Library/Application Support/Fixture" && -d "$HOME/Library/Group Containers/ABCDE12345.org.example.qzvujfix" ]] ||
		{ echo "an unlisted leftover was removed"; return 1; }
}

@test "the deletion funnel refuses every path but the app in hand and its chosen leftovers" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" GLIMWELL_UNINSTALL_JSON=1 _GLIMWELL_UJ_ALLOW_ACTIVE=1 _GLIMWELL_UJ_UNLOAD_PROBE=1 \
		/bin/bash --noprofile --norc -c '
source "$PROJECT_ROOT/bin/uninstall.sh"
export MOLE_CURRENT_COMMAND=uninstall
check() { if validate_path_for_deletion "$HOME/$1" 2> /dev/null; then echo "$1=ok"; else echo "$1=${_MOLE_VALIDATION_REASON}"; fi; }
# Inherited values count for nothing: loading reset them.
echo "json=$GLIMWELL_UNINSTALL_JSON active=$_GLIMWELL_UJ_ALLOW_ACTIVE probe=$_GLIMWELL_UJ_UNLOAD_PROBE"
GLIMWELL_UNINSTALL_JSON=1
check Applications/A.app
_GLIMWELL_UJ_ALLOW=("$HOME/Applications/A.app" "$HOME/Library/Application Support/A")
_GLIMWELL_UJ_ALLOW_ACTIVE=1
check Applications/A.app
check "Library/Application Support/A/inner"
check "Library/Application Support/AB"
check "Library/Application Support"
check Applications/B.app
_GLIMWELL_UJ_UNLOAD_PROBE=1 check Library/LaunchAgents/com.a.plist
MOLE_CURRENT_COMMAND=clean check Applications/B.app'
	[[ "$output" == $'json=0 active=0 probe=0\nApplications/A.app=not selected\nApplications/A.app=ok\nLibrary/Application Support/A/inner=ok\nLibrary/Application Support/AB=not selected\nLibrary/Application Support=not selected\nApplications/B.app=not selected\nLibrary/LaunchAgents/com.a.plist=ok\nApplications/B.app=ok' ]] ||
		{ echo "$output"; return 1; }
}

@test "a running app is kept untouched and never signalled" {
	command -v codesign > /dev/null 2>&1 || skip "codesign is not available"
	# A name no other test uses: the check also matches the executable name.
	make_app GlimwellRunFixture org.example.qzvujrun
	local app="$HOME/Applications/GlimwellRunFixture.app"
	# A real executable inside the bundle, so the process runs from it.
	cp /bin/sleep "$app/Contents/MacOS/GlimwellRunFixture"
	codesign -f -s - "$app/Contents/MacOS/GlimwellRunFixture" > /dev/null 2>&1
	"$app/Contents/MacOS/GlimwellRunFixture" 60 &
	local pid=$!
	sleep 0.5
	kill -0 "$pid" || skip "the fixture app could not start"

	sel "app:$app"
	uj --dry-run --json --only "$HOME/sel.txt"
	[[ "$output" == *"\"status\":\"ok\",\"running\":true,"* ]] || { kill "$pid"; echo "$output"; return 1; }

	sel "app:$app" "path:$HOME/Library/Caches/org.example.qzvujrun"
	uj --json --only "$HOME/sel.txt"
	local alive=0
	kill -0 "$pid" 2> /dev/null && alive=1
	kill "$pid" 2> /dev/null || true
	[ "$alive" -eq 1 ] || { echo "the running app was stopped"; return 1; }
	[ "$status" -eq 1 ] || { echo "$output / $stderr"; return 1; }
	assert_json_stream
	[[ "$output" == *"{\"type\":\"kept\",\"app\":\"$app\",\"path\":\"$app\",\"reason\":\"running\""* ]] || { echo "$output"; return 1; }
	[[ "$output" == *"{\"type\":\"app_done\",\"app\":\"$app\",\"status\":\"kept\",\"reason\":\"running\"}"* ]] || { echo "$output"; return 1; }
	[[ -d "$app" && -d "$HOME/Library/Caches/org.example.qzvujrun" ]] || { echo "the kept app or its leftover was touched"; return 1; }
	[[ ! -e "$HOME/stub.calls" ]] || { echo "quit or sudo was attempted: $(cat "$HOME/stub.calls")"; return 1; }
}

@test "needs_admin is reported without any prompt or sudo call" {
	make_app Fixture org.example.qzvujfix
	local app="$HOME/Applications/Fixture.app"
	chmod 555 "$HOME/Applications"
	# Removing from a folder the user cannot write needs a password. The fake
	# home is user-writable, which the terminal treats as unsafe for sudo, so
	# model a root-owned parent here.
	EXTRA='_mole_privileged_path_has_mutable_ancestor() { return 1; }
ensure_sudo_session() { echo "ensure_sudo_session" >> "$HOME/stub.calls"; return 1; }
request_sudo_access() { echo "request_sudo_access" >> "$HOME/stub.calls"; return 1; }'
	sel "app:$app"
	uj --dry-run --json --only "$HOME/sel.txt"
	[[ "$output" == *"\"status\":\"ok\",\"running\":false,\"needs_admin\":true,"* ]] || { echo "$output / $stderr"; return 1; }
	sel "app:$app" "path:$HOME/Library/Caches/org.example.qzvujfix"
	uj --json --only "$HOME/sel.txt"
	chmod 755 "$HOME/Applications"
	[ "$status" -eq 1 ] || { echo "$output / $stderr"; return 1; }
	assert_json_stream
	[[ "$output" == *"{\"type\":\"app_done\",\"app\":\"$app\",\"status\":\"kept\",\"reason\":\"needs_admin\"}"* ]] || { echo "$output"; return 1; }
	[[ -d "$app" && -d "$HOME/Library/Caches/org.example.qzvujfix" ]] || { echo "the app or its leftover was removed"; return 1; }
	[[ ! -e "$HOME/stub.calls" ]] || { echo "a prompt or sudo ran: $(cat "$HOME/stub.calls")"; return 1; }
}

@test "a Homebrew cask is removed by brew, which cannot ask for a password" {
	make_app Fixture org.example.qzvujfix
	local app="$HOME/Applications/Fixture.app"
	cat > "$HOME/stubs/brew" <<- 'BREW'
		#!/bin/bash
		if [[ "$1 $2 $3" == "info --cask --json=v2" ]]; then
			if [[ -e "$HOME/brew-cask-quits" ]]; then
				echo '{"casks":[{"token":"fixture","artifacts":[{"uninstall":[{"quit":"com.example.helper"}]},{"app":["Fixture.app"]}]}]}'
			else
				echo '{"casks":[{"token":"fixture","artifacts":[{"app":["Fixture.app"]},{"binary":["fixture"]},{"zap":[{"trash":"~/Documents/Fixture"}]}]}]}'
			fi
			exit 0
		fi
		printf '%s\n' "brew $* askpass=${SUDO_ASKPASS:-} noninteractive=${NONINTERACTIVE:-}" >> "$HOME/brew.log"
		[[ "$1 $2" == "uninstall --cask" ]] || exit 1
		if [[ -e "$HOME/brew-needs-password" ]]; then
			echo "==> Uninstalling Cask fixture"
			echo "sudo: a password is required" >&2
			exit 1
		fi
		/bin/mv "$HOME/Applications/Fixture.app" "$HOME/brew-removed.app"
		[[ ! -e "$HOME/brew-step-fails" ]] || exit 1
	BREW
	chmod +x "$HOME/stubs/brew"
	# SUDO_USER in the environment never routes brew through sudo.
	EXTRA='export SUDO_USER=nobody
is_homebrew_available() { return 0; }
get_brew_cask_name() { [[ "$1" == "$HOME/Applications/Fixture.app" ]] && echo fixture; }
is_brew_cask_installed() { [[ -e "$HOME/Applications/Fixture.app" || -e "$HOME/brew-step-fails" ]]; }'
	sel "app:$app" "path:$HOME/Library/Caches/org.example.qzvujfix"

	touch "$HOME/brew-needs-password"
	uj --json --only "$HOME/sel.txt"
	[ "$status" -eq 1 ] || { echo "$output / $stderr"; return 1; }
	assert_json_stream
	[[ "$output" == *"{\"type\":\"app_done\",\"app\":\"$app\",\"status\":\"kept\",\"reason\":\"needs_admin\"}"* ]] || { echo "$output"; return 1; }
	[[ -d "$app" && -d "$HOME/Library/Caches/org.example.qzvujfix" ]] || { echo "the bundle went behind brew's back"; return 1; }
	[[ "$(cat "$HOME/brew.log")" == "brew uninstall --cask fixture askpass=/usr/bin/false noninteractive=1" ]] || { cat "$HOME/brew.log"; return 1; }
	[[ ! -e "$HOME/stub.calls" ]] || { echo "a prompt or sudo ran: $(cat "$HOME/stub.calls")"; return 1; }

	rm -f "$HOME/brew-needs-password" "$HOME/brew.log"
	uj --json --only "$HOME/sel.txt"
	[ "$status" -eq 0 ] || { echo "$output / $stderr"; return 1; }
	[[ "$output" == *"{\"type\":\"removed\",\"app\":\"$app\",\"path\":\"$app\",\"detail\":null}"* ]] || { echo "$output"; return 1; }
	[[ "$output" == *"{\"type\":\"app_done\",\"app\":\"$app\",\"status\":\"removed\",\"reason\":null}"* ]] || { echo "$output"; return 1; }
	[[ -d "$HOME/brew-removed.app" && ! -e "$HOME/Library/Caches/org.example.qzvujfix" ]] || { echo "brew or the leftover removal did not run"; return 1; }
}

@test "a cask with uninstall steps of its own is left to the terminal, and a half-done brew run is reported" {
	make_app Fixture org.example.qzvujfix
	local app="$HOME/Applications/Fixture.app"
	cat > "$HOME/stubs/brew" <<- 'BREW'
		#!/bin/bash
		if [[ "$1 $2 $3" == "info --cask --json=v2" ]]; then
			if [[ -e "$HOME/brew-cask-quits" ]]; then
				echo '{"casks":[{"token":"fixture","artifacts":[{"uninstall":[{"quit":"com.example.helper"}]},{"app":["Fixture.app"]}]}]}'
			else
				echo '{"casks":[{"token":"fixture","artifacts":[{"app":["Fixture.app"]}]}]}'
			fi
			exit 0
		fi
		printf '%s\n' "brew $*" >> "$HOME/brew.log"
		[[ "$1 $2" == "uninstall --cask" ]] || exit 1
		/bin/mv "$HOME/Applications/Fixture.app" "$HOME/brew-removed.app"
		exit 1
	BREW
	chmod +x "$HOME/stubs/brew"
	EXTRA='is_homebrew_available() { return 0; }
get_brew_cask_name() { [[ "$1" == "$HOME/Applications/Fixture.app" ]] && echo fixture; }
is_brew_cask_installed() { return 0; }'
	sel "app:$app" "path:$HOME/Library/Caches/org.example.qzvujfix"

	touch "$HOME/brew-cask-quits"
	uj --dry-run --json --only "$HOME/sel.txt"
	[[ "$output" == *"\"cask\":\"fixture\",\"status\":\"manual\""*"brew uninstall --cask fixture in Terminal"* ]] || { echo "$output / $stderr"; return 1; }
	uj --json --only "$HOME/sel.txt"
	[ "$status" -eq 1 ] || { echo "$output / $stderr"; return 1; }
	[[ "$output" == *"{\"type\":\"app_done\",\"app\":\"$app\",\"status\":\"kept\",\"reason\":\"failed\"}"* ]] || { echo "$output"; return 1; }
	[[ ! -e "$HOME/brew.log" && -d "$app" ]] || { echo "brew ran a cask with its own uninstall steps"; return 1; }

	# brew removes the bundle, then fails while the cask stays registered.
	rm -f "$HOME/brew-cask-quits"
	uj --json --only "$HOME/sel.txt"
	[[ "$output" == *"{\"type\":\"removed\",\"app\":\"$app\",\"path\":\"$app\",\"detail\":null}"* ]] || { echo "$output / $stderr"; return 1; }
	[[ "$output" == *"{\"type\":\"app_done\",\"app\":\"$app\",\"status\":\"partial\",\"reason\":\"failed\"}"* ]] || { echo "$output"; return 1; }
	[[ -d "$HOME/Library/Caches/org.example.qzvujfix" ]] || { echo "leftovers went after a failed brew step"; return 1; }
	run grep -F "REMOVED $app (brew uninstall)" "$HOME/Library/Logs/mole/operations.log"
	[ "$status" -eq 0 ] || { echo "the bundle brew removed has no operations.log row"; return 1; }
}

# The test flags short-circuit these sinks, so check them with the flags off
# and every outside tool stubbed.
@test "under --json, Trash moves never use Finder and lsof never uses sudo, test flags off" {
	run env -u MOLE_TEST_MODE -u MOLE_TEST_NO_AUTH HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" PATH="$HOME/stubs:$PATH" \
		/bin/bash --noprofile --norc -c '
source "$PROJECT_ROOT/bin/uninstall.sh"
unset MOLE_TEST_MODE MOLE_TEST_NO_AUTH
printf "#!/bin/bash\necho \"trash \$*\" >> \"$HOME/stub.calls\"\nexit 0\n" > "$HOME/stubs/trash"
printf "#!/bin/bash\nexit 0\n" > "$HOME/stubs/lsof"
chmod +x "$HOME/stubs/trash" "$HOME/stubs/lsof"
_mole_move_path_to_user_trash() { echo "direct $1 sudo=$2"; return 0; }
GLIMWELL_UNINSTALL_JSON=1
mkdir -p "$HOME/Applications/A.app" "$HOME/Library/Caches/x"
_mole_move_to_trash "$HOME/Applications/A.app" false
_mole_move_to_trash "$HOME/Library/Caches/x" false
_mole_move_to_trash "$HOME/Library/Caches/x" true || echo "sudo move refused"
unset _MOLE_COMPLETE_LSOF_MODE
rc=0; _mole_complete_lsof_mode || rc=$?
echo "lsof=$rc mode=$_MOLE_COMPLETE_LSOF_MODE"
GLIMWELL_UNINSTALL_JSON=0
_GLIMWELL_UJ_APP="$HOME/Applications/A.app"
GLIMWELL_UNINSTALL_JSON=1
exec 8>&1
glimwell_uninstall_json_operation REMOVED "A" "login item"
glimwell_uninstall_json_operation REMOVED "$HOME/Library/LaunchAgents/a.plist" "launchctl unload"
glimwell_uninstall_json_operation TRASHED "$HOME/Library/Caches/x" "12KB"'
	[[ "${lines[0]}" == "direct $HOME/Applications/A.app sudo=false" && "${lines[1]}" == "direct $HOME/Library/Caches/x sudo=false" ]] || { echo "$output"; return 1; }
	[[ "${lines[2]}" == "sudo move refused" && "${lines[3]}" == "lsof=2 mode=unknown" ]] || { echo "$output"; return 1; }
	[[ "${lines[4]}" == "{\"type\":\"removed\",\"app\":\"$HOME/Applications/A.app\",\"path\":\"$HOME/Library/Caches/x\",\"detail\":\"12KB\"}" && ${lines[5]} == '{"type":"summary"'* && ${#lines[@]} -eq 6 ]] || { echo "$output"; return 1; }
	[[ ! -e "$HOME/stub.calls" ]] || { echo "Finder, trash or sudo ran: $(cat "$HOME/stub.calls")"; return 1; }
}

@test "uninstall --list --json adds bytes, last_used and cask to the app list" {
	make_app Fixture org.example.qzvujfix
	uj --list --json
	[ "$status" -eq 0 ] || { echo "$output / $stderr"; return 1; }
	run /usr/bin/perl -MJSON::PP -e '
		local $/; my $a = JSON::PP->new->decode(<STDIN>);
		die "not one app\n" unless @$a == 1;
		my $r = $a->[0];
		for my $k (qw(name bundle_id source uninstall_name path size bytes last_used cask)) { die "no $k\n" unless exists $r->{$k} }
		die "bad bytes\n" if defined $r->{bytes} && $r->{bytes} !~ /^\d+$/;
		die "bad last_used\n" if defined $r->{last_used} && $r->{last_used} !~ /^\d+$/;
		die "cask\n" if defined $r->{cask};
		print "$r->{name} $r->{bundle_id} $r->{source}\n";' <<< "$output"
	[[ "$output" == "Fixture org.example.qzvujfix App" ]] || { echo "$output"; return 1; }
}

# A signal sent to a background job of a non-interactive shell is ignored,
# so Python starts the CLI and sends it.
run_and_signal() {
	local after="$1"
	shift
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" PATH="$HOME/stubs:$PATH" MOLE_TEST_NO_AUTH=1 \
		MOLE_TEST_TRASH_DIR="$HOME/.TestTrash" EXTRA="${EXTRA:-}" AFTER="$after" /usr/bin/python3 -I -c '
import os, signal, subprocess, sys
script = """source "$PROJECT_ROOT/bin/uninstall.sh"
source "$PROJECT_ROOT/tests/helpers/uninstall.bash"
uninstall_print_app_search_dirs() { printf "%s\\n" "$HOME/Applications"; }
mole_test_isolate_uninstall_inventory
is_homebrew_available() { return 1; }
eval "$EXTRA"
main "$@"
"""
p = subprocess.Popen(["/bin/bash", "--noprofile", "--norc", "-c", script, "_"] + sys.argv[1:],
                     stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
out = []
for line in p.stdout:
    out.append(line.decode())
    if os.environ["AFTER"] in out[-1]:
        p.send_signal(signal.SIGINT)
        break
out.extend(l.decode() for l in p.stdout)
p.wait()
sys.stdout.write("".join(out))
print("rc=%d" % p.returncode)
' "$@"
}

@test "SIGINT ends a preview, and a real run after the app in hand, with a cancelled summary" {
	make_app Fixture org.example.qzvujfix
	make_app Second org.example.qzvujsec
	EXTRA='get_path_size_kb() { sleep 1; echo 4; }'
	sel "app:$HOME/Applications/Fixture.app" "app:$HOME/Applications/Second.app"
	run_and_signal '"type":"item"' --dry-run --json --only "$HOME/sel.txt"
	[[ "${lines[${#lines[@]} - 2]}" == '{"type":"summary","dry_run":true,"status":"cancelled","exit":130,'* ]] || { echo "$output"; return 1; }
	[[ "${lines[${#lines[@]} - 1]}" == "rc=130" ]] || { echo "$output"; return 1; }

	sel "app:$HOME/Applications/Fixture.app" "app:$HOME/Applications/Second.app"
	run_and_signal '"type":"app_start"' --json --only "$HOME/sel.txt"
	[[ "${lines[${#lines[@]} - 2]}" == '{"type":"summary","dry_run":false,"status":"cancelled","exit":130,'* ]] || { echo "$output"; return 1; }
	[[ "${lines[${#lines[@]} - 1]}" == "rc=130" ]] || { echo "$output"; return 1; }
	# The app in hand finished; the next one was never started.
	[[ "$output" == *"\"type\":\"app_done\",\"app\":\"$HOME/Applications/Fixture.app\",\"status\":\"removed\""* ]] || { echo "$output"; return 1; }
	[[ "$output" != *"Second.app\",\"name\""* && -d "$HOME/Applications/Second.app" ]] || { echo "$output"; return 1; }
}

# The whole pipeline through the router, in this test's HOME, inside a macOS
# sandbox profile that denies every write outside HOME and the temp folders:
# a broken check fails this test instead of touching the host. The inventory
# is the real one (read only) plus the fixture.
@test "a real uninstall --json run in a sandbox removes only the listed app and leftover" {
	command -v sandbox-exec > /dev/null 2>&1 || skip "sandbox-exec is not available"
	make_app GlimwellUJFixture org.example.qzvuje2e
	local real_home real_tmp darwin_tmp
	real_home=$(cd "$HOME" && pwd -P)
	real_tmp=$(cd "${TMPDIR:-/tmp}" && pwd -P)
	darwin_tmp=$(cd "$(getconf DARWIN_USER_TEMP_DIR)" && pwd -P)
	local app="$real_home/Applications/GlimwellUJFixture.app" prefs="$real_home/Library/Preferences/org.example.qzvuje2e.plist"
	local profile="(version 1)(allow default)(deny file-write*)(allow file-write* (subpath \"$real_home\") (subpath \"$real_tmp\") (subpath \"$darwin_tmp\") (subpath \"/private/tmp\") (subpath \"/private/var/tmp\") (subpath \"/dev\"))"
	local -a run_env=(env HOME="$real_home" TMPDIR="$real_tmp" PATH="$HOME/stubs:/usr/bin:/bin:/usr/sbin:/sbin"
		MOLE_TEST_NO_AUTH=1 MOLE_TEST_TRASH_DIR="$real_home/.TestTrash" MOLE_LSREGISTER_PATH="")

	printf '%s\n' "app:$app" > "$HOME/sel.txt"
	run --separate-stderr sandbox-exec -p "$profile" "${run_env[@]}" "$PROJECT_ROOT/mole" uninstall --dry-run --json --only "$HOME/sel.txt"
	[ "$status" -eq 0 ] || { echo "$output / $stderr"; return 1; }
	assert_json_stream
	[[ "$output" == *"\"id\":\"path:$prefs\""* ]] || { echo "$output"; return 1; }

	printf '%s\n' "app:$app" "path:$prefs" > "$HOME/sel.txt"
	run --separate-stderr sandbox-exec -p "$profile" "${run_env[@]}" "$PROJECT_ROOT/mole" uninstall --json --only "$HOME/sel.txt"
	[ "$status" -eq 0 ] || { echo "$output / $stderr"; return 1; }
	assert_json_stream
	[[ "$output" == *"{\"type\":\"removed\",\"app\":\"$app\",\"path\":\"$prefs\""* ]] || { echo "$output"; return 1; }
	[[ "${lines[${#lines[@]} - 1]}" == *'"status":"complete","exit":0,"apps":1,"removed":2,"kept":0}' ]] || { echo "$output"; return 1; }
	[[ ! -e "$app" && ! -e "$prefs" ]] || { echo "a listed item survived"; return 1; }
	[[ -d "$real_home/Library/Caches/org.example.qzvuje2e" && -d "$real_home/Library/Application Support/GlimwellUJFixture" &&
		-d "$real_home/Library/Group Containers/ABCDE12345.org.example.qzvuje2e" ]] || { echo "an unlisted leftover was removed"; return 1; }
	[[ ! -e "$HOME/stub.calls" ]] || { echo "quit or sudo was attempted: $(cat "$HOME/stub.calls")"; return 1; }
}
