#!/usr/bin/env bats
# fettle: the full main menu, the user's own commands and update_mole.

load helpers/common

setup_file() {
	mole_test_setup_home "fettle-menu"
}

teardown_file() {
	mole_test_teardown_home
}

setup() {
	rm -rf "${HOME:?}/.config" "${HOME:?}/fake" "${HOME:?}/tmp" # SAFE: test-owned mktemp HOME under tests/tmp-*
	mkdir -p "$HOME/.config/mole"
}

# Shared prelude: load the router without running it, at a fixed 40x120 size.
prelude() {
	cat << 'EOF'
set -euo pipefail
export MOLE_TEST_MODE=1 MOLE_SKIP_MAIN=1 NO_COLOR=1
source "$PROJECT_ROOT/mole"
_fettle_terminal_size() { echo "40 120"; }
MAIN_MENU_UPDATE_MESSAGE=""
EOF
}

@test "my commands get a section with one command per row and skip malformed lines" {
	printf '# comment\nFlush DNS\tsudo dscacheutil -flushcache\n\nno tab here\n\techo no name\nSay hi\techo hi\n' > "$HOME/.config/mole/my_commands"
	run /bin/bash --noprofile --norc -c "$(prelude)"'
fettle_load_menu_items
fettle_show_menu_items 1
printf "count=%s\n" "${#FETTLE_MY_NAMES[@]}"
'
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	# The heading runs across the 120-column window with its name centered:
	# 53 + " My commands " + 54 = 120.
	local left right
	left="$(printf '%*s' 53 '')"
	right="$(printf '%*s' 54 '')"
	local row=$'\r\033[2K'
	[[ "$output" == *"Update Fettle"$'\n'"${row}${left// /─} My commands ${right// /─}"$'\n'"${row}  Add a command"$'\n'* ]] || return 1
	[[ "$output" == *"  Add a command"$'\n'*"  Flush DNS"*"Edit"*"Remove"$'\n'*"  Say hi"*"Edit"*"Remove"$'\n'* ]] || return 1
	[[ "$output" == *"count=2"* ]] || return 1
	[[ "$output" != *"no tab here"* ]]
}

@test "the line under the menu describes the selected item" {
	printf 'Say hi\techo hi\n' > "$HOME/.config/mole/my_commands"
	run /bin/bash --noprofile --norc -c "$(prelude)"'
fettle_load_menu_items
fettle_show_menu_items 1 | tail -n 1
fettle_show_menu_items 3 | tail -n 1
fettle_show_menu_items 37 | tail -n 1
fettle_show_menu_items 38 | tail -n 1
fettle_show_menu_items 40 | tail -n 1
'
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	# Status is the first row.
	[[ "$output" == *"Monitor system health"*"Show what Clean would remove, without removing anything"* ]] || return 1
	[[ "$output" == *"Add your own command to this menu"* ]] || return 1
	[[ "$output" == *"Runs: echo hi"* ]] || return 1
	[[ "$output" == *'Remove "Say hi" from the menu'* ]]
}

@test "arrow keys keep the column when the next row has one" {
	run /bin/bash --noprofile --norc -c "$(prelude)"'
fettle_load_menu_items
c=2
for key in RIGHT RIGHT RIGHT DOWN DOWN RIGHT DOWN LEFT LEFT UP TOP UP BOTTOM DOWN UP DOWN; do
    c=$(fettle_menu_move "$c" "$key")
    printf "%s " "$c"
done
'
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	# Status is item 1, Clean 2-4, Optimize 5-7, Analyze 8-9, History
	# 10-11; Update is 35, the section heading 36 is skipped, Add is 37.
	[ "$output" = "3 4 4 7 9 9 11 10 10 8 1 1 37 37 35 37 " ]
}

@test "a long list scrolls to keep the selection visible" {
	for i in 1 2 3 4 5 6 7; do
		printf 'Cmd %s\techo %s\n' "$i" "$i" >> "$HOME/.config/mole/my_commands"
	done
	run /bin/bash --noprofile --norc -c "$(prelude)"'
_fettle_terminal_size() { echo "24 80"; }
fettle_load_menu_items
last=${#FETTLE_MENU_LABELS[@]}
printf "first:\n"; fettle_show_menu_items 1
printf "last:\n"; fettle_show_menu_items "$last"
printf "lines=%s,%s\n" "$(fettle_show_menu_items 1 | wc -l)" "$(fettle_show_menu_items "$last" | wc -l)"
'
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	local first="${output%%last:*}" last="${output#*last:}"
	# "more above" sits above the list and "more below" under it.
	[[ "$first" == *"Clean"*"more below"* ]] || return 1
	[[ "$first" != *"more above"* && "$first" != *"Cmd 7"* ]] || return 1
	[[ "$last" == *"more above"*"Cmd 7"* ]] || return 1
	local last_view="${last%%lines=*}"
	[[ "$last_view" != *"more below"* && "$last" != *"Protected caches"* ]] || return 1
	# Both hint rows are always there while scrolling, so the list keeps its place.
	[[ "$output" =~ lines=\ *([0-9]+),\ *([0-9]+) ]] || return 1
	[ "${BASH_REMATCH[1]}" -eq "${BASH_REMATCH[2]}" ]
}

# Items in the my-commands section: Add is 36, then each command's row holds
# the command, Edit and Remove (37-39 for the first, 40-42 for the second).

@test "Add appends a command, selects it and confirms" {
	printf '# my notes\nOne\techo 1' > "$HOME/.config/mole/my_commands"
	run /bin/bash --noprofile --norc -c "$(prelude)"'
clear() { :; }
drain_pending_input() { :; }
fettle_load_menu_items
fettle_menu_activate 37 < <(printf "  Say hi \necho hi\n")
echo "selected=$FETTLE_MENU_SELECTED"
fettle_show_menu_items "$FETTLE_MENU_SELECTED" | tail -n 1
echo "---"
cat "$FETTLE_MY_COMMANDS_FILE"
'
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[[ "$output" == *"selected=41"* ]] || return 1
	[[ "$output" == *'Added "Say hi".'* ]] || return 1
	[ "${output#*---}" = $'\n# my notes\nOne\techo 1\nSay hi\techo hi' ]
}

@test "Add with an empty name or command adds nothing" {
	run /bin/bash --noprofile --norc -c "$(prelude)"'
clear() { :; }
drain_pending_input() { :; }
fettle_load_menu_items
fettle_menu_activate 37 < <(printf "\n")
fettle_show_menu_items 37 | tail -n 1
fettle_menu_activate 37 < <(printf "Name\n\n")
fettle_show_menu_items 37 | tail -n 1
[[ ! -e "$FETTLE_MY_COMMANDS_FILE" ]] && echo "NO_FILE"
'
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[[ "$output" == *"Nothing added."* ]] || return 1
	[[ "$output" == *"Nothing added: the command was empty."* ]] || return 1
	[[ "$output" == *"NO_FILE"* ]]
}

@test "Edit changes one line, keeps the rest and Enter keeps a value" {
	printf '# my notes\nOne\techo 1\nnot a command\nTwo\techo 2\n' > "$HOME/.config/mole/my_commands"
	run /bin/bash --noprofile --norc -c "$(prelude)"'
clear() { :; }
drain_pending_input() { :; }
fettle_load_menu_items
fettle_menu_activate 42 < <(printf "\necho two\n")
echo "selected=$FETTLE_MENU_SELECTED"
fettle_menu_activate 39 < <(printf "\n\n")
fettle_show_menu_items 38 | tail -n 1
echo "---"
cat "$FETTLE_MY_COMMANDS_FILE"
'
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[[ "$output" == *"selected=41"* ]] || return 1
	[[ "$output" == *"Nothing changed."* ]] || return 1
	[ "${output#*---}" = $'\n# my notes\nOne\techo 1\nnot a command\nTwo\techo two' ]
}

@test "Remove asks first, keeps hand-written lines and moves the selection" {
	printf '# my notes\nOne\techo 1\nnot a command\nTwo\techo 2\n' > "$HOME/.config/mole/my_commands"
	run /bin/bash --noprofile --norc -c "$(prelude)"'
clear() { :; }
drain_pending_input() { :; }
fettle_load_menu_items
fettle_menu_activate 40 < <(printf "n\n")
fettle_show_menu_items 40 | tail -n 1
fettle_menu_activate 40 < <(printf "y\n")
echo "selected=$FETTLE_MENU_SELECTED"
fettle_menu_activate 40 < <(printf "Y\n")
echo "selected=$FETTLE_MENU_SELECTED"
echo "---"
cat "$FETTLE_MY_COMMANDS_FILE"
'
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[[ "$output" == *"Nothing removed."* ]] || return 1
	# Removing the first command selects the one that took its place; removing
	# the last selects Add.
	[[ "$output" == *"selected=38"*"selected=37"* ]] || return 1
	[ "${output#*---}" = $'\n# my notes\nnot a command' ]
}

@test "menu items launch the right Mole script, preview flags and own commands" {
	printf 'Say hi\techo "hi there"\n' > "$HOME/.config/mole/my_commands"
	run /bin/bash --noprofile --norc -c "$(prelude)"'
exec < /dev/null
clear() { :; }
drain_pending_input() { :; }
run_mole_command() { printf "RUN"; printf " [%s]" "$@"; printf "\n"; }
SHELL=/bin/sh
fettle_load_menu_items
fettle_menu_activate 2
fettle_menu_activate 3
fettle_menu_activate 20
fettle_menu_activate 23
fettle_menu_activate 24
fettle_menu_activate 25
fettle_menu_activate 26
fettle_menu_activate 27
fettle_menu_activate 28
fettle_menu_activate 29
fettle_menu_activate 30
fettle_menu_activate 31
fettle_menu_activate 32
fettle_menu_activate 33
fettle_menu_activate 34
fettle_menu_activate 38
echo "STILL_IN_MENU"
'
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[[ "$output" == *"STILL_IN_MENU"* ]] || return 1
	[[ "$output" == *"RUN [$PROJECT_ROOT/bin/clean.sh]"$'\n'* ]] || return 1
	[[ "$output" == *"RUN [$PROJECT_ROOT/bin/clean.sh] [--dry-run]"* ]] || return 1
	[[ "$output" == *"RUN [$PROJECT_ROOT/bin/touchid.sh] [enable] [--dry-run]"* ]] || return 1
	[[ "$output" == *"RUN [$PROJECT_ROOT/bin/fettle-updates.sh]"$'\n'* ]] || return 1
	[[ "$output" == *"RUN [$PROJECT_ROOT/bin/fettle-updates.sh] [--dry-run]"* ]] || return 1
	# Software removal sits under Software updates.
	[[ "$output" == *"fettle-updates.sh] [--dry-run]"$'\n'*"RUN [$PROJECT_ROOT/bin/uninstall.sh]"$'\n'*"RUN [$PROJECT_ROOT/bin/uninstall.sh] [--dry-run]"* ]] || return 1
	# Ollama model updates, Add Ollama models, Add Hugging Face MLX, then
	# Ollama model removal, under it.
	[[ "$output" == *"uninstall.sh] [--dry-run]"$'\n'*"RUN [$PROJECT_ROOT/bin/fettle-models.sh]"$'\n'*"RUN [$PROJECT_ROOT/bin/fettle-models.sh] [--dry-run]"$'\n'*"RUN [$PROJECT_ROOT/bin/fettle-models.sh] [--download]"$'\n'*"RUN [$PROJECT_ROOT/bin/fettle-models.sh] [--download] [--dry-run]"$'\n'*"RUN [$PROJECT_ROOT/bin/fettle-models.sh] [--huggingface]"$'\n'*"RUN [$PROJECT_ROOT/bin/fettle-models.sh] [--huggingface] [--dry-run]"$'\n'*"RUN [$PROJECT_ROOT/bin/fettle-models.sh] [--remove]"$'\n'*"RUN [$PROJECT_ROOT/bin/fettle-models.sh] [--remove] [--dry-run]"$'\n'* ]] || return 1
	[[ "$output" == *'RUN [/bin/sh] [-c] [echo "hi there"]'* ]]
}

@test "commands return to the menu, after Enter unless they are full-screen" {
	run /bin/bash --noprofile --norc -c "$(prelude)"'
SCRIPT_DIR="$HOME/fake"
mkdir -p "$SCRIPT_DIR/bin"
for name in clean status; do
    printf "#!/bin/bash\necho RAN_%s\nexit 3\n" "$name" > "$SCRIPT_DIR/bin/$name.sh"
    chmod +x "$SCRIPT_DIR/bin/$name.sh"
done
show_main_menu() { echo "MENU_DRAWN"; }
hide_cursor() { :; }
show_cursor() { :; }
clear() { :; }
drain_pending_input() { :; }
keys=(DOWN ENTER UP ENTER QUIT)
read_key() {
    local n=0
    [[ -f "$HOME/key-count" ]] && n=$(cat "$HOME/key-count")
    echo $((n + 1)) > "$HOME/key-count"
    echo "${keys[n]}"
}
rm -f "$HOME/key-count"
interactive_main_menu < <(printf "\n")
'
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[[ "$output" == *"RAN_clean"*"Press Enter or Q to return to the menu."*"MENU_DRAWN"*"RAN_status"*"MENU_DRAWN"* ]] || return 1
	# Status is full-screen, so it returns without asking for Enter.
	local after_status="${output#*RAN_status}"
	[[ "$after_status" != *"Press Enter"* ]]
}

@test "commands run in the pane, named after the menu row, with Clean's file list and the cancel marker" {
	printf 'Say hi\techo hi\n' > "$HOME/.config/mole/my_commands"
	run /bin/bash --noprofile --norc -c "$(prelude)"'
export TMPDIR="$HOME/tmp"
mkdir -p "$TMPDIR"
SCRIPT_DIR="$HOME/fake"
mkdir -p "$SCRIPT_DIR/bin"
printf "#!/bin/bash\necho RAN_clean \"\$*\"\n" > "$SCRIPT_DIR/bin/clean.sh"
printf "#!/bin/bash\necho RAN_analyze\n" > "$SCRIPT_DIR/bin/analyze.sh"
# The pane reports what it was given, then runs the command after --.
cat > "$SCRIPT_DIR/bin/fettle-view-go" << "PANE"
#!/bin/bash
echo "PANE $(printf "%s|" "$@") CANCEL=$FETTLE_CANCEL_FILE"
while [[ "$1" != "--" ]]; do shift; done
shift
"$@"
PANE
chmod +x "$SCRIPT_DIR"/bin/*
hide_cursor() { :; }
show_cursor() { :; }
clear() { echo CLEARED; }
drain_pending_input() { :; }
SHELL=/bin/sh
fettle_load_menu_items
echo "== preview"
fettle_menu_activate 3 < /dev/null
echo "== analyze"
fettle_run_and_return "$SCRIPT_DIR/bin/analyze.sh" < /dev/null
echo "== mine"
fettle_menu_activate 38 < /dev/null
echo "== left: $(find "$TMPDIR" -mindepth 1 | wc -l | tr -d " ")"
'
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	local preview="${output#*== preview}" analyze="${output#*== analyze}" mine="${output#*== mine}"
	preview="${preview%%== analyze*}"
	analyze="${analyze%%== mine*}"
	mine="${mine%%== left*}"
	# The row and the variant name the screen; F may offer Clean's list.
	[[ "$preview" == *"PANE --title|Clean · Preview|--summary|Potential space|Items|Categories|--file|$HOME/.config/mole/clean-list.txt|--unstarted|$HOME/tmp/fettle-run."*"/unstarted|--|$HOME/fake/bin/clean.sh|--dry-run|"* ]] || { echo "$output"; return 1; }
	[[ "$preview" == *" CANCEL=$HOME/tmp/fettle-run."*"/cancelled"*"RAN_clean --dry-run"* ]] || return 1
	# The pane shows the results, so the menu does not ask for Enter.
	[[ "$preview" != *"Press Enter"* ]] || return 1
	# Full-screen commands run on their own.
	[[ "$analyze" == *"RAN_analyze"* && "$analyze" != *"PANE"* ]] || return 1
	# My own commands keep their command line above the output.
	[[ "$mine" == *"PANE --title|Say hi|--note|\$ echo hi|"*"hi"* ]] || return 1
	[[ "$output" == *"== left: 0"* ]]
}

@test "only Clean names summary labels for the command screen" {
	run /bin/bash --noprofile --norc -c "$(prelude)"'
for args in "clean.sh --dry-run" "clean.sh" "clean.sh --whitelist" "purge.sh --dry-run"; do
    read -r -a words <<< "$args"
    printf "%s => [%s]\n" "$args" "$(_fettle_summary_labels "$SCRIPT_DIR/bin/${words[0]}" "${words[@]:1}")"
done
'
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[[ "$output" == *"clean.sh --dry-run => [Potential space|Items|Categories]"* ]] || return 1
	[[ "$output" == *"clean.sh => [Tracked cleanup|Items cleaned]"* ]] || return 1
	[[ "$output" == *"clean.sh --whitelist => []"* ]] || return 1
	[[ "$output" == *"purge.sh --dry-run => []"* ]]
}

@test "the menu runs a command the plain way only when the pane could not start it" {
	run /bin/bash --noprofile --norc -c "$(prelude)"'
SCRIPT_DIR="$HOME/fake"
mkdir -p "$SCRIPT_DIR/bin"
printf "#!/bin/bash\necho RAN_history\n" > "$SCRIPT_DIR/bin/history.sh"
hide_cursor() { :; }
show_cursor() { :; }
clear() { :; }
drain_pending_input() { :; }
# A pane that could not start: it says so in the --unstarted file.
cat > "$SCRIPT_DIR/bin/fettle-view-go" << "PANE"
#!/bin/bash
while [[ "$1" != "--unstarted" ]]; do shift; done
: > "$2"
exit 125
PANE
chmod +x "$SCRIPT_DIR"/bin/*
echo "== unstarted"
fettle_run_and_return "$SCRIPT_DIR/bin/history.sh" < <(printf "\n")
# A command that exits 125 itself is not run a second time.
printf "#!/bin/bash\necho PANE_RAN\nexit 125\n" > "$SCRIPT_DIR/bin/fettle-view-go"
echo "== own 125"
fettle_run_and_return "$SCRIPT_DIR/bin/history.sh" < <(printf "\n")
'
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	local unstarted="${output#*== unstarted}" own="${output#*== own 125}"
	unstarted="${unstarted%%== own 125*}"
	[[ "$unstarted" == *"RAN_history"*"Press Enter or Q to return to the menu."* ]] || { echo "$output"; return 1; }
	[[ "$own" == *"PANE_RAN"* && "$own" != *"RAN_history"* && "$own" != *"Press Enter"* ]]
}

@test "my own commands show their name and command line above their output" {
	printf 'Say hi\techo hi\n' > "$HOME/.config/mole/my_commands"
	run /bin/bash --noprofile --norc -c "$(prelude)"'
hide_cursor() { :; }
show_cursor() { :; }
clear() { echo CLEARED; }
drain_pending_input() { :; }
run_mole_command() { "$@"; }
SHELL=/bin/sh
fettle_load_menu_items
fettle_menu_activate 38 < <(printf "\n")
'
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[[ "$output" == $'CLEARED\nSay hi\n$ echo hi\n\nhi\n'*"Press Enter"* ]]
}

@test "without the pane, each command opens on a clear screen, and a cancelled one comes straight back" {
	run /bin/bash --noprofile --norc -c "$(prelude)"'
export TMPDIR="$HOME/tmp"
mkdir -p "$TMPDIR"
SCRIPT_DIR="$HOME/fake"
mkdir -p "$SCRIPT_DIR/bin"
printf "#!/bin/bash\necho RAN_installer\n" > "$SCRIPT_DIR/bin/installer.sh"
printf "#!/bin/bash\necho RAN_touchid\n" > "$SCRIPT_DIR/bin/touchid.sh"
# The cancel goes through the real note, as Mole commands send it.
printf "#!/bin/bash\nsource \"%s/lib/fettle/cancel.sh\"\necho RAN_slim\nfettle_note_cancel\n" "$PROJECT_ROOT" > "$SCRIPT_DIR/bin/slim.sh"
chmod +x "$SCRIPT_DIR"/bin/*.sh
hide_cursor() { :; }
show_cursor() { :; }
clear() { echo CLEARED; }
drain_pending_input() { :; }
echo "== installer"
fettle_run_and_return "$SCRIPT_DIR/bin/installer.sh" --dry-run < <(printf "\n")
echo "== slim"
fettle_run_and_return "$SCRIPT_DIR/bin/slim.sh" < /dev/null
echo "== touchid"
fettle_run_and_return "$SCRIPT_DIR/bin/touchid.sh" < <(printf "q")
echo "== left: $(find "$TMPDIR" -mindepth 1 | wc -l | tr -d " ")"
'
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	local installer="${output#*== installer}" slim="${output#*== slim}" touchid="${output#*== touchid}"
	installer="${installer%%== slim*}"
	slim="${slim%%== touchid*}"
	touchid="${touchid%%== left*}"
	# The menu is cleared first, and commands without a heading get one.
	[[ "$installer" == $'\nCLEARED\nInstaller files\n\nRAN_installer\n'*"Press Enter or Q to return to the menu."*"CLEARED"* ]] || { echo "$output"; return 1; }
	# A cancelled command skips the Enter prompt.
	[[ "$slim" == $'\nCLEARED\nSlim Intel code\n\nRAN_slim\nCLEARED\n' ]] || return 1
	# Touch ID starts its own screen with a blank line, so no second one.
	[[ "$touchid" == $'\nCLEARED\nTouch ID\nRAN_touchid\n'*"Press Enter"* ]] || return 1
	# The cancel marker folders are gone.
	[[ "$output" == *"== left: 0"* ]]
}

@test "the banner says Fettle and points to the fettle repository" {
	run /bin/bash --noprofile --norc -c "$(prelude)"'
show_brand_banner
echo "---"
_fettle_terminal_size() { echo "40 59"; }
show_brand_banner
'
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	local wide="${output%%---*}" narrow="${output#*---}"
	# The logo spells Fettle, not MoreMole.
	[[ "$wide" == *'|_|  \___|\__|\__|_|\___|'* ]] || return 1
	[[ "$wide" != *"mole.fit"* && "$wide" != *'|  \/  |'* ]] || return 1
	# Wide (60 columns or more): the address and the two tagline lines sit
	# beside the logo's last three rows, and no row is wider than 60 columns.
	[[ "$wide" == *'/ _ \  github.com/RosBradley/fettle-cli'* ]] || return 1
	[[ "$wide" == *'__/  Deep clean and optimize your Mac.'* ]] || return 1
	[[ "$wide" == *'\___|  Manage, update and remove apps.'* ]] || return 1
	local row
	while IFS= read -r row; do
		[ "${#row}" -le 60 ] || { echo "too wide: $row"; return 1; }
	done <<< "$wide"
	# Narrow: they move under the logo, each on its own line.
	[[ "$narrow" == *$'\ngithub.com/RosBradley/fettle-cli\nDeep clean and optimize your Mac.\nManage, update and remove apps.'* ]]
}

@test "the version screen names Fettle and credits Mole" {
	run env HOME="$HOME" "$PROJECT_ROOT/mole" --version
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	local expected
	expected="$(sed -n 's/^VERSION="\(.*\)"$/\1/p' "$PROJECT_ROOT/mole")"
	# This git folder names its commit; Mole's version moves to the credit.
	local commit
	commit="$(git -C "$PROJECT_ROOT" log -1 --format='%h (%cd)' --date=short)"
	[[ "$output" == *"Fettle version $commit"$'\ngithub.com/RosBradley/fettle-cli\n'"Based on Mole $expected by tw93: github.com/tw93/Mole"$'\n'* ]] || { echo "$output"; return 1; }
	[[ "$output" != *"Mole version"* ]]
}

@test "the git folder is recognized when its path is typed in another case" {
	local other
	other="$(dirname "$PROJECT_ROOT")/$(basename "$PROJECT_ROOT" | tr '[:lower:]' '[:upper:]')"
	[[ "$other" != "$PROJECT_ROOT" && -x "$other/mole" ]] || skip "the file system tells case apart"
	run env HOME="$HOME" "$other/mole" --version
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[[ "$output" == *"Fettle version "* ]] || { echo "$output"; return 1; }
}

@test "fettle remove changes nothing and says what to remove instead" {
	mkdir -p "$HOME/.local/bin" "$HOME/.config/mole"
	printf 'keep\n' > "$HOME/.config/mole/my_commands"
	ln -sfn "$PROJECT_ROOT/mole" "$HOME/.local/bin/ft"
	ln -sfn /usr/bin/true "$HOME/.local/bin/mo"
	run env HOME="$HOME" NO_COLOR=1 "$PROJECT_ROOT/mole" remove
	[ "$status" -eq 1 ] || { echo "$output"; return 1; }
	[[ "$output" == *"fettle remove changes nothing. To remove Fettle, nothing else:"* ]] || return 1
	[[ "$output" == *"rm $HOME/.local/bin/ft"*"move $PROJECT_ROOT to the Trash"* ]] || return 1
	[[ "$output" != *"Mole"* ]] || return 1
	# Only links to this folder are listed; another tool's mo is not.
	[[ "$output" != *".local/bin/mo "* && "$output" != *".local/bin/mo"$'\n'* ]] || return 1
	[ "$(cat "$HOME/.config/mole/my_commands")" = "keep" ] || return 1
	[ "$(readlink "$HOME/.local/bin/ft")" = "$PROJECT_ROOT/mole" ] || return 1
	grep -qF "SKIPPED $PROJECT_ROOT (fettle remove is not supported)" "$HOME/Library/Logs/mole/operations.log" || return 1
	rm -f "$HOME/.local/bin/ft" "$HOME/.local/bin/mo" # SAFE: test-owned links under the test HOME
}

@test "the help screen names commands fettle, in one aligned column" {
	run env HOME="$HOME" NO_COLOR=1 "$PROJECT_ROOT/mole" --help
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[[ "$output" == *"  fettle clean --dry-run           Preview cleanup"* ]] || return 1
	[[ "$output" == *"  fettle touchid enable --dry-run  Preview Touch ID setup"* ]] || return 1
	[[ "$output" == *"  --debug                          Show detailed operation logs"* ]] || return 1
	[[ "$output" == *"  fettle update   "* && "$output" == *"  fettle remove   "* ]] || return 1
	# fettle remove changes nothing, so it has no preview.
	[[ "$output" != *"remove --dry-run"* ]] || return 1
	# Mole's release channels do nothing in Fettle, so they are not offered.
	[[ "$output" != *"update --force"* && "$output" != *"update --nightly"* ]] || return 1
	[[ "$output" != *$'\n  mo '* ]]
}

@test "update notices say run fettle update" {
	run /bin/bash --noprofile --norc -c "$(prelude)"'
mkdir -p "$HOME/.cache/mole"
printf "Update 9.8.7 available, run mo update\n" > "$HOME/.cache/mole/update_message"
read_update_message_cache "$HOME/.cache/mole/update_message"
'
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[ "$output" = "Update 9.8.7 available, run fettle update" ]
}

@test "V and M show their screen and return to the menu on Q or Enter" {
	run /bin/bash --noprofile --norc -c "$(prelude)"'
show_main_menu() { echo "MENU_DRAWN"; }
show_help() { echo "HELP_SHOWN"; }
show_version() { echo "VERSION_SHOWN"; }
hide_cursor() { :; }
show_cursor() { :; }
clear() { :; }
drain_pending_input() { :; }
keys=(MORE VERSION QUIT)
read_key() {
    local n=0
    [[ -f "$HOME/key-count" ]] && n=$(cat "$HOME/key-count")
    echo $((n + 1)) > "$HOME/key-count"
    echo "${keys[n]}"
}
rm -f "$HOME/key-count"
# The help screen gets an ignored key, then Q; the version screen gets Enter.
interactive_main_menu < <(printf "xq\n")
'
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[[ "$output" == *"HELP_SHOWN"*"Press Enter or Q to return to the menu."*"MENU_DRAWN"*"VERSION_SHOWN"*"Press Enter"*"MENU_DRAWN"* ]]
}

@test "Tab completion covers fettle and ft, and setup uses the fettle command" {
	run "$PROJECT_ROOT/bin/completion.sh" zsh
	[ "$status" -eq 0 ] || return 1
	# Only Fettle's names: an official Mole keeps its own completion.
	[[ "$output" == *$'#compdef fettle ft\n'* ]] || return 1
	[[ "$output" == *$'\ncompdef _mole fettle ft' ]] || return 1
	run "$PROJECT_ROOT/bin/completion.sh" bash
	[[ "$output" == *$'\ncomplete -F _mole_completions fettle ft' ]] || return 1

	mkdir -p "$HOME/stub-bin"
	printf '#!/bin/bash\n' > "$HOME/stub-bin/fettle"
	chmod +x "$HOME/stub-bin/fettle"
	run env HOME="$HOME" SHELL=/bin/zsh MOLE_DRY_RUN=1 PATH="$HOME/stub-bin:/usr/bin:/bin" \
		"$PROJECT_ROOT/bin/completion.sh"
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	# shellcheck disable=SC2016  # Literal ~/.zshrc text, not an expansion.
	[[ "$output" == *'if output="$(fettle completion zsh 2>/dev/null)"; then eval "$output"; fi'* ]] || return 1

	# The line it writes is recognized again, so a rerun replaces it.
	run /bin/bash --noprofile --norc -c '
source "$1/lib/core/base.sh"
grep -Eq "$MOLE_COMPLETION_LINE_PATTERN" <<< "if output=\"\$(fettle completion zsh 2>/dev/null)\"; then eval \"\$output\"; fi" || exit 1
# So is the line MoreMole wrote before it was renamed Fettle.
grep -Eq "$MOLE_COMPLETION_LINE_PATTERN" <<< "if output=\"\$(moremole completion zsh 2>/dev/null)\"; then eval \"\$output\"; fi"
' _ "$PROJECT_ROOT"
	[ "$status" -eq 0 ]
}

@test "update_mole runs the fettle sync script in the maintainer's git folder" {
	run /bin/bash --noprofile --norc -c "$(prelude)"'
SCRIPT_DIR="$HOME/fork"
mkdir -p "$SCRIPT_DIR/scripts"
git init -q "$SCRIPT_DIR"
git -C "$SCRIPT_DIR" remote add upstream https://github.com/tw93/Mole.git
printf "echo SYNC_RAN\n" > "$SCRIPT_DIR/scripts/fettle-sync.sh"
update_mole true false
'
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[[ "$output" == *"--force and --nightly are not used"* ]] || return 1
	[[ "$output" == *"SYNC_RAN"* ]]
}

@test "Mole's own updater runs only for Mole's tests of it, never to install Mole over Fettle" {
	run /bin/bash --noprofile --norc -c "$(prelude)"'
declare -f _fettle_official_update_mole | grep -q "UPDATE_LOCK_CONTROL" || exit 1
_fettle_official_update_mole() { echo "OFFICIAL_UPDATE $*"; }
SCRIPT_DIR="$HOME/not-a-repo"
mkdir -p "$SCRIPT_DIR"
update_mole true false || echo "refused rc=$?"
FETTLE_TEST_MOLE_UPDATER=1 update_mole true false
'
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[[ "$output" == *"can't update itself"*"refused rc=1"* ]] || return 1
	[ "$(grep -c "OFFICIAL_UPDATE" <<< "$output")" -eq 1 ] || return 1
	[[ "$output" == *"OFFICIAL_UPDATE true false"* ]]
}

@test "on the menu's own screen, clearing keeps the terminal's scrollback" {
	run /bin/bash --noprofile --norc -c "$(prelude)"'
clear() { printf "CLEAR_CALLED"; }
printf "[%q]\n" "$(_fettle_clear_screen)" "$(_fettle_clear_all)" "$(fettle_menu_leave_screen)"
FETTLE_MENU_SCREEN=true
printf "[%q]\n" "$(_fettle_clear_screen)" "$(_fettle_clear_all)"
fettle_menu_leave_screen > "$HOME/leave"
printf "after=%s leave=[%q]\n" "$FETTLE_MENU_SCREEN" "$(cat "$HOME/leave")"
'
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	# Without the menu's screen: clear, as before; leaving does nothing.
	[[ "$output" == *"[CLEAR_CALLED]"$'\n'"[CLEAR_CALLED]"$'\n'"['']"* ]] || { echo "$output"; return 1; }
	# On it: escape codes for the screen only, no clear (which empties the
	# scrollback on macOS), and leaving switches back.
	[[ "$output" == *"[\$'\\E[H\\E[2J']"$'\n'"[\$'\\E[?1049h\\E[H\\E[2J']"* ]] || { echo "$output"; return 1; }
	[[ "$output" == *"after=false leave=[\$'\\E[?1049l']"* ]]
}
