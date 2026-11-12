#!/usr/bin/env bats
# shellcheck disable=SC2016  # inner bash scripts expand their own arguments
# Glimwell: every pick list shows its search line, opens A-Z, and lets the
# arrows leave the search so Space selects and Enter saves. Installer files
# uses the shared list (lib/glimwell/lists.sh) for search and sorting.

load helpers/common

setup_file() {
	mole_test_setup_home glimwell-lists
}

teardown_file() {
	mole_test_teardown_home
}

setup() {
	if [[ "$HOME" != "${BATS_TEST_DIRNAME}/tmp-"* ]]; then
		printf 'FATAL: HOME is not a test temp dir: %s\n' "$HOME" >&2
		return 1
	fi
	KEYS_FILE="$BATS_TEST_TMPDIR/keys"
	KEY_STATE="$BATS_TEST_TMPDIR/key-state"
	MENU_OUTPUT="$BATS_TEST_TMPDIR/menu-output"
	: > "$KEY_STATE"
	export KEYS_FILE KEY_STATE MENU_OUTPUT
}

# The keys a test presses, one read_key result per line.
keys() {
	printf '%s\n' "$@" > "$KEYS_FILE"
}

# Shell code that runs the shared list off-screen with the scripted keys.
readonly SCRIPTED_MENU='
enter_alt_screen() { :; }
leave_alt_screen() { :; }
stty() { :; }
tput() { if [[ "$1" == cols ]]; then echo 80; else echo 20; fi; }
drain_pending_input() { :; }
read_key() {
	local index key
	index=$(cat "$KEY_STATE" 2> /dev/null || echo 0)
	index=$((index + 1))
	printf "%s\n" "$index" > "$KEY_STATE"
	key=$(sed -n "${index}p" "$KEYS_FILE")
	printf "%s\n" "${key:-QUIT}"
}
'

@test "the search line always shows under the title" {
	keys ENTER
	run env TERM=xterm-256color /bin/bash -c '
		source "$1/lib/core/common.sh"
		source "$1/lib/ui/menu_paginated.sh"
		eval "$2"
		paginated_multi_select Pick "Alpha one" "Zebra two" 2> "$MENU_OUTPUT" || echo CANCELLED
		printf "RESULT=%s\n" "$MOLE_SELECTION_RESULT"
	' bash "$PROJECT_ROOT" "$SCRIPTED_MENU"
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[[ "$output" == *"RESULT=0"* ]] || return 1
	local frame
	frame=$(sed $'s/\033\\[[0-9;]*[A-Za-z]//g; s/\r//g' "$MENU_OUTPUT")
	[[ "$frame" == *$'Pick  0/2 selected\nSearch: press / and type\n'*"Alpha one"* ]] || { echo "$frame"; return 1; }
}

@test "the arrows leave the search line, so Space selects and Enter saves" {
	keys CHAR:/ CHAR:z CHAR:e DOWN SPACE ENTER
	run env TERM=xterm-256color /bin/bash -c '
		source "$1/lib/core/common.sh"
		source "$1/lib/ui/menu_paginated.sh"
		eval "$2"
		paginated_multi_select Pick "Alpha one" "Zebra two" "Zebra three" 2> "$MENU_OUTPUT" || echo CANCELLED
		printf "RESULT=%s KEYS=%s\n" "$MOLE_SELECTION_RESULT" "$(cat "$KEY_STATE")"
	' bash "$PROJECT_ROOT" "$SCRIPTED_MENU"
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	# "ze" leaves both Zebras; Down moves to the second and Space picks it.
	[[ "$output" == *"RESULT=2 KEYS=6"* ]] || return 1
	run cat "$MENU_OUTPUT"
	# The search stays applied after leaving the line, without its cursor.
	[[ "$output" == *"/ Search: ze"$'\033'*"1 selected"* ]]
}

@test "installer files open A-Z by name and sort by size, then date" {
	run env TERM=xterm-256color MOLE_TEST_MODE=1 /bin/bash -c '
		source "$1/bin/installer.sh"
		eval "$2"
		fake_stat() {
			case "$3" in
				*/b-tool.pkg) echo 300 ;;
				*/a-app.dmg) echo 100 ;;
				*) echo 200 ;;
			esac
		}
		STAT_BSD=fake_stat
		hash=$(printf "%064d" 0)
		INSTALLER_PATHS=("$HOME/Downloads/b-tool.pkg" "$HOME/Downloads/a-app.dmg" "$HOME/Library/Caches/Homebrew/downloads/${hash}--C-Cask.dmg")
		INSTALLER_SIZES=(2048 1048576 4096)
		DISPLAY_NAMES=("b-tool.pkg  2KB | Downloads" "a-app.dmg  1MB | Downloads" "C-Cask.dmg  4KB | Homebrew")
		for keys in "SPACE ENTER" "CHAR:s SPACE ENTER" "CHAR:s CHAR:s SPACE ENTER" "CHAR:/ CHAR:c CHAR:a CHAR:s CHAR:k ENTER SPACE ENTER"; do
			printf "%s\n" $keys > "$KEYS_FILE"
			: > "$KEY_STATE"
			# The command'"'"'s own menu step, which uses the shared list.
			show_installer_menu 2> "$MENU_OUTPUT" > /dev/null || echo CANCELLED
			printf "%s -> %s\n" "$keys" "$MOLE_SELECTION_RESULT"
		done
	' bash "$PROJECT_ROOT" "$SCRIPTED_MENU"
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	# A-Z: a-app.dmg (1) first; size: a-app.dmg (1MB) first; date: oldest,
	# a-app.dmg, first. Search finds the Homebrew download by its name.
	[[ "$output" == *$'SPACE ENTER -> 1\n'* ]] || return 1
	[[ "$output" == *"CHAR:s SPACE ENTER -> 1"* ]] || return 1
	[[ "$output" == *"CHAR:s CHAR:s SPACE ENTER -> 1"* ]] || return 1
	[[ "$output" == *"CHAR:c CHAR:a CHAR:s CHAR:k ENTER SPACE ENTER -> 2"* ]] || return 1
	[[ "$output" != *CANCELLED* ]]
}

@test "installer files sort order flips with O and the sort key cycles name, size, date" {
	run env TERM=xterm-256color MOLE_TEST_MODE=1 /bin/bash -c '
		source "$1/bin/installer.sh"
		eval "$2"
		fake_stat() {
			case "$3" in
				*/b.pkg) echo 100 ;;
				*/c.dmg) echo 300 ;;
				*) echo 200 ;;
			esac
		}
		STAT_BSD=fake_stat
		INSTALLER_PATHS=("$HOME/Downloads/a.dmg" "$HOME/Downloads/b.pkg" "$HOME/Downloads/c.dmg")
		INSTALLER_SIZES=(4096 1024 2048)
		DISPLAY_NAMES=("a.dmg" "b.pkg" "c.dmg")
		# O on A-Z gives Z-A; S then S gives date, oldest first (b.pkg);
		# one more S comes back to A-Z.
		for keys in "CHAR:o SPACE ENTER" "CHAR:s SPACE ENTER" "CHAR:s CHAR:s SPACE ENTER" "CHAR:s CHAR:s CHAR:s SPACE ENTER"; do
			printf "%s\n" $keys > "$KEYS_FILE"
			: > "$KEY_STATE"
			glimwell_select_installers 2> "$MENU_OUTPUT" || echo CANCELLED
			printf "%s -> %s\n" "$keys" "$MOLE_SELECTION_RESULT"
		done
	' bash "$PROJECT_ROOT" "$SCRIPTED_MENU"
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[[ "$output" == *$'CHAR:o SPACE ENTER -> 2\n'* ]] || return 1
	[[ "$output" == *$'\nCHAR:s SPACE ENTER -> 0\n'* ]] || return 1
	[[ "$output" == *$'\nCHAR:s CHAR:s SPACE ENTER -> 1\n'* ]] || return 1
	# The last line, so nothing follows it.
	[[ "$output" == *$'\nCHAR:s CHAR:s CHAR:s SPACE ENTER -> 0' ]] || return 1
	[[ "$output" != *CANCELLED* ]]
}

@test "installer files: Enter with nothing selected removes nothing" {
	keys ENTER ENTER
	run env TERM=xterm-256color MOLE_TEST_MODE=1 /bin/bash -c '
		source "$1/bin/installer.sh"
		eval "$2"
		INSTALLER_PATHS=("$HOME/Downloads/a.dmg" "$HOME/Downloads/b.pkg")
		INSTALLER_SIZES=(4096 1024)
		DISPLAY_NAMES=("a.dmg" "b.pkg")
		if show_installer_menu 2> "$MENU_OUTPUT" > /dev/null; then echo PICKED; else echo NOTHING; fi
		printf "RESULT=[%s]\n" "$MOLE_SELECTION_RESULT"
	' bash "$PROJECT_ROOT" "$SCRIPTED_MENU"
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[[ "$output" == *"NOTHING"*"RESULT=[]"* ]] || return 1
	[[ "$output" != *PICKED* ]]
}

@test "the app removal list and Slim open A-Z" {
	keys ENTER
	run env TERM=xterm-256color MOLE_TEST_NO_AUTH=1 WITH_METADATA=1 PROJECT_ROOT="$PROJECT_ROOT" \
		/bin/bash "$PROJECT_ROOT/tests/fixtures/uninstall_menu.sh"
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[[ "$output" == *"SORT=name REVERSE=false"* ]] || return 1

	run env TERM=xterm-256color MOLE_TEST_MODE=1 /bin/bash -c '
		source "$1/bin/slim.sh"
		paginated_multi_select() { printf "sort=%s\n" "$MOLE_MENU_SORT_MODE"; return 1; }
		SLIM_APP_PATHS=(/Applications/B.app /Applications/A.app)
		SLIM_APP_NAMES=(B A)
		SLIM_APP_BYTES=(2048 1024)
		select_slim_apps || true
	' bash "$PROJECT_ROOT"
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[[ "$output" == *"sort=name"* ]]
}

@test "Purge's find shows what you type (real terminal)" {
	command -v python3 > /dev/null 2>&1 || skip "python3 is required for the PTY fixture"
	run python3 "$PROJECT_ROOT/tests/glimwell_purge_find_pty.py"
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[[ "$output" == *"PASS"* ]]
}

@test "Purge's list starts with nothing selected, old artifacts included" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'SCRIPT'
set -euo pipefail
source "$PROJECT_ROOT/lib/clean/project.sh"
PURGE_CATEGORY_SIZES="1,2"
PURGE_RECENT_CATEGORIES="false,false"
select_purge_categories "old node_modules" "old dist" <<< $'\n' > /dev/null
printf 'RESULT=[%s]\n' "$PURGE_SELECTION_RESULT"
select_purge_categories "old node_modules" "old dist" <<< $'a\n' > /dev/null
printf 'ALL=[%s]\n' "$PURGE_SELECTION_RESULT"
SCRIPT
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[[ "$output" == *"RESULT=[]"* ]] || return 1
	[[ "$output" == *"ALL=[0,1]"* ]]
}
