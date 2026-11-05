#!/usr/bin/env bats
# moremole: the full main menu, the user's own commands and update_mole.

load helpers/common

setup_file() {
	mole_test_setup_home "moremole-menu"
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
_moremole_terminal_size() { echo "40 120"; }
MAIN_MENU_UPDATE_MESSAGE=""
EOF
}

@test "my commands get a section with one command per row and skip malformed lines" {
	printf '# comment\nFlush DNS\tsudo dscacheutil -flushcache\n\nno tab here\n\techo no name\nSay hi\techo hi\n' > "$HOME/.config/mole/my_commands"
	run /bin/bash --noprofile --norc -c "$(prelude)"'
moremole_load_menu_items
moremole_show_menu_items 1
printf "count=%s\n" "${#MOREMOLE_MY_NAMES[@]}"
'
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	# The heading runs across the 120-column window with its name centered:
	# 53 + " My commands " + 54 = 120.
	local left right
	left="$(printf '%*s' 53 '')"
	right="$(printf '%*s' 54 '')"
	local row=$'\r\033[2K'
	[[ "$output" == *"Update MoreMole"$'\n'"${row}${left// /─} My commands ${right// /─}"$'\n'"${row}  Add a command"$'\n'* ]] || return 1
	[[ "$output" == *"  Add a command"$'\n'*"  Flush DNS"*"Edit"*"Remove"$'\n'*"  Say hi"*"Edit"*"Remove"$'\n'* ]] || return 1
	[[ "$output" == *"count=2"* ]] || return 1
	[[ "$output" != *"no tab here"* ]]
}

@test "the line under the menu describes the selected item" {
	printf 'Say hi\techo hi\n' > "$HOME/.config/mole/my_commands"
	run /bin/bash --noprofile --norc -c "$(prelude)"'
moremole_load_menu_items
moremole_show_menu_items 2 | tail -n 1
moremole_show_menu_items 37 | tail -n 1
moremole_show_menu_items 38 | tail -n 1
moremole_show_menu_items 40 | tail -n 1
'
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[[ "$output" == *"Show what Clean would remove, without removing anything"* ]] || return 1
	[[ "$output" == *"Add your own command to this menu"* ]] || return 1
	[[ "$output" == *"Runs: echo hi"* ]] || return 1
	[[ "$output" == *'Remove "Say hi" from the menu'* ]]
}

@test "arrow keys keep the column when the next row has one" {
	run /bin/bash --noprofile --norc -c "$(prelude)"'
moremole_load_menu_items
c=1
for key in RIGHT RIGHT RIGHT DOWN DOWN RIGHT DOWN LEFT LEFT UP TOP UP BOTTOM DOWN UP DOWN; do
    c=$(moremole_menu_move "$c" "$key")
    printf "%s " "$c"
done
'
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	# Row 1 holds items 1-3, Optimize 4-6, Analyze 7-8, Status 9;
	# Update is 35, the section heading 36 is skipped, Add is 37.
	[ "$output" = "2 3 3 6 8 8 9 9 9 7 1 1 37 37 35 37 " ]
}

@test "a long list scrolls to keep the selection visible" {
	for i in 1 2 3 4 5 6 7; do
		printf 'Cmd %s\techo %s\n' "$i" "$i" >> "$HOME/.config/mole/my_commands"
	done
	run /bin/bash --noprofile --norc -c "$(prelude)"'
_moremole_terminal_size() { echo "24 80"; }
moremole_load_menu_items
last=${#MOREMOLE_MENU_LABELS[@]}
printf "first:\n"; moremole_show_menu_items 1
printf "last:\n"; moremole_show_menu_items "$last"
printf "lines=%s,%s\n" "$(moremole_show_menu_items 1 | wc -l)" "$(moremole_show_menu_items "$last" | wc -l)"
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
moremole_load_menu_items
moremole_menu_activate 37 < <(printf "  Say hi \necho hi\n")
echo "selected=$MOREMOLE_MENU_SELECTED"
moremole_show_menu_items "$MOREMOLE_MENU_SELECTED" | tail -n 1
echo "---"
cat "$MOREMOLE_MY_COMMANDS_FILE"
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
moremole_load_menu_items
moremole_menu_activate 37 < <(printf "\n")
moremole_show_menu_items 37 | tail -n 1
moremole_menu_activate 37 < <(printf "Name\n\n")
moremole_show_menu_items 37 | tail -n 1
[[ ! -e "$MOREMOLE_MY_COMMANDS_FILE" ]] && echo "NO_FILE"
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
moremole_load_menu_items
moremole_menu_activate 42 < <(printf "\necho two\n")
echo "selected=$MOREMOLE_MENU_SELECTED"
moremole_menu_activate 39 < <(printf "\n\n")
moremole_show_menu_items 38 | tail -n 1
echo "---"
cat "$MOREMOLE_MY_COMMANDS_FILE"
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
moremole_load_menu_items
moremole_menu_activate 40 < <(printf "n\n")
moremole_show_menu_items 40 | tail -n 1
moremole_menu_activate 40 < <(printf "y\n")
echo "selected=$MOREMOLE_MENU_SELECTED"
moremole_menu_activate 40 < <(printf "Y\n")
echo "selected=$MOREMOLE_MENU_SELECTED"
echo "---"
cat "$MOREMOLE_MY_COMMANDS_FILE"
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
moremole_load_menu_items
moremole_menu_activate 1
moremole_menu_activate 2
moremole_menu_activate 20
moremole_menu_activate 23
moremole_menu_activate 24
moremole_menu_activate 25
moremole_menu_activate 26
moremole_menu_activate 27
moremole_menu_activate 28
moremole_menu_activate 29
moremole_menu_activate 30
moremole_menu_activate 31
moremole_menu_activate 32
moremole_menu_activate 33
moremole_menu_activate 34
moremole_menu_activate 38
echo "STILL_IN_MENU"
'
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[[ "$output" == *"STILL_IN_MENU"* ]] || return 1
	[[ "$output" == *"RUN [$PROJECT_ROOT/bin/clean.sh]"$'\n'* ]] || return 1
	[[ "$output" == *"RUN [$PROJECT_ROOT/bin/clean.sh] [--dry-run]"* ]] || return 1
	[[ "$output" == *"RUN [$PROJECT_ROOT/bin/touchid.sh] [enable] [--dry-run]"* ]] || return 1
	[[ "$output" == *"RUN [$PROJECT_ROOT/bin/moremole-updates.sh]"$'\n'* ]] || return 1
	[[ "$output" == *"RUN [$PROJECT_ROOT/bin/moremole-updates.sh] [--dry-run]"* ]] || return 1
	# Software removal sits under Software updates.
	[[ "$output" == *"moremole-updates.sh] [--dry-run]"$'\n'*"RUN [$PROJECT_ROOT/bin/uninstall.sh]"$'\n'*"RUN [$PROJECT_ROOT/bin/uninstall.sh] [--dry-run]"* ]] || return 1
	# Ollama model updates, Add Ollama models, Add Hugging Face MLX, then
	# Ollama model removal, under it.
	[[ "$output" == *"uninstall.sh] [--dry-run]"$'\n'*"RUN [$PROJECT_ROOT/bin/moremole-models.sh]"$'\n'*"RUN [$PROJECT_ROOT/bin/moremole-models.sh] [--dry-run]"$'\n'*"RUN [$PROJECT_ROOT/bin/moremole-models.sh] [--download]"$'\n'*"RUN [$PROJECT_ROOT/bin/moremole-models.sh] [--download] [--dry-run]"$'\n'*"RUN [$PROJECT_ROOT/bin/moremole-models.sh] [--huggingface]"$'\n'*"RUN [$PROJECT_ROOT/bin/moremole-models.sh] [--huggingface] [--dry-run]"$'\n'*"RUN [$PROJECT_ROOT/bin/moremole-models.sh] [--remove]"$'\n'*"RUN [$PROJECT_ROOT/bin/moremole-models.sh] [--remove] [--dry-run]"$'\n'* ]] || return 1
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
keys=(ENTER DOWN DOWN DOWN ENTER QUIT)
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
cat > "$SCRIPT_DIR/bin/moremole-view-go" << "PANE"
#!/bin/bash
echo "PANE $(printf "%s|" "$@") CANCEL=$MOREMOLE_CANCEL_FILE"
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
moremole_load_menu_items
echo "== preview"
moremole_menu_activate 2 < /dev/null
echo "== analyze"
moremole_run_and_return "$SCRIPT_DIR/bin/analyze.sh" < /dev/null
echo "== mine"
moremole_menu_activate 38 < /dev/null
echo "== left: $(find "$TMPDIR" -mindepth 1 | wc -l | tr -d " ")"
'
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	local preview="${output#*== preview}" analyze="${output#*== analyze}" mine="${output#*== mine}"
	preview="${preview%%== analyze*}"
	analyze="${analyze%%== mine*}"
	mine="${mine%%== left*}"
	# The row and the variant name the screen; F may offer Clean's list.
	[[ "$preview" == *"PANE --title|Clean · Preview|--summary|Potential space|Items|Categories|--file|$HOME/.config/mole/clean-list.txt|--unstarted|$HOME/tmp/moremole-run."*"/unstarted|--|$HOME/fake/bin/clean.sh|--dry-run|"* ]] || { echo "$output"; return 1; }
	[[ "$preview" == *" CANCEL=$HOME/tmp/moremole-run."*"/cancelled"*"RAN_clean --dry-run"* ]] || return 1
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
    printf "%s => [%s]\n" "$args" "$(_moremole_summary_labels "$SCRIPT_DIR/bin/${words[0]}" "${words[@]:1}")"
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
cat > "$SCRIPT_DIR/bin/moremole-view-go" << "PANE"
#!/bin/bash
while [[ "$1" != "--unstarted" ]]; do shift; done
: > "$2"
exit 125
PANE
chmod +x "$SCRIPT_DIR"/bin/*
echo "== unstarted"
moremole_run_and_return "$SCRIPT_DIR/bin/history.sh" < <(printf "\n")
# A command that exits 125 itself is not run a second time.
printf "#!/bin/bash\necho PANE_RAN\nexit 125\n" > "$SCRIPT_DIR/bin/moremole-view-go"
echo "== own 125"
moremole_run_and_return "$SCRIPT_DIR/bin/history.sh" < <(printf "\n")
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
moremole_load_menu_items
moremole_menu_activate 38 < <(printf "\n")
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
printf "#!/bin/bash\nsource \"%s/lib/moremole/cancel.sh\"\necho RAN_slim\nmoremole_note_cancel\n" "$PROJECT_ROOT" > "$SCRIPT_DIR/bin/slim.sh"
chmod +x "$SCRIPT_DIR"/bin/*.sh
hide_cursor() { :; }
show_cursor() { :; }
clear() { echo CLEARED; }
drain_pending_input() { :; }
echo "== installer"
moremole_run_and_return "$SCRIPT_DIR/bin/installer.sh" --dry-run < <(printf "\n")
echo "== slim"
moremole_run_and_return "$SCRIPT_DIR/bin/slim.sh" < /dev/null
echo "== touchid"
moremole_run_and_return "$SCRIPT_DIR/bin/touchid.sh" < <(printf "q")
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

@test "the banner says MoreMole and points to the moremole repository" {
	run /bin/bash --noprofile --norc -c "$(prelude)"'
show_brand_banner
echo "---"
_moremole_terminal_size() { echo "40 60"; }
show_brand_banner
'
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	local wide="${output%%---*}" narrow="${output#*---}"
	# The logo spells MoreMole: its last row ends in the "Mole" letters.
	[[ "$wide" == *'|_|  |_|\___/|_|  \___|_|  |_|\___/|_|\___|'* ]] || return 1
	[[ "$wide" != *"mole.fit"* ]] || return 1
	# Wide: the address and the two tagline lines sit beside the logo's
	# last three rows, and no row is wider than 80 columns.
	[[ "$wide" == *'/ _ \  github.com/RosBradley/moremole'* ]] || return 1
	[[ "$wide" == *'__/  Deep clean and optimize your Mac.'* ]] || return 1
	[[ "$wide" == *'\___|  Manage, update and remove apps.'* ]] || return 1
	local row
	while IFS= read -r row; do
		[ "${#row}" -le 80 ] || { echo "too wide: $row"; return 1; }
	done <<< "$wide"
	# Narrow: they move under the logo, each on its own line.
	[[ "$narrow" == *$'\ngithub.com/RosBradley/moremole\nDeep clean and optimize your Mac.\nManage, update and remove apps.'* ]]
}

@test "the version screen names MoreMole and credits Mole" {
	run env HOME="$HOME" "$PROJECT_ROOT/mole" --version
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	local expected
	expected="$(sed -n 's/^VERSION="\(.*\)"$/\1/p' "$PROJECT_ROOT/mole")"
	[[ "$output" == *"MoreMole version $expected"* ]] || return 1
	[[ "$output" == *"Based on Mole by tw93: github.com/tw93/Mole"* ]] || return 1
	[[ "$output" == *"MoreMole: github.com/RosBradley/moremole"* ]] || return 1
	# Mole's own scripts read the number from the "Mole version" line.
	[ "$(printf '%s\n' "$output" | awk '/Mole version/ {print $NF; exit}')" = "$expected" ]
}

@test "moremole remove changes nothing and says what to remove instead" {
	mkdir -p "$HOME/.local/bin" "$HOME/.config/mole"
	printf 'keep\n' > "$HOME/.config/mole/my_commands"
	ln -sfn "$PROJECT_ROOT/mole" "$HOME/.local/bin/mm"
	ln -sfn /usr/bin/true "$HOME/.local/bin/mo"
	run env HOME="$HOME" NO_COLOR=1 "$PROJECT_ROOT/mole" remove
	[ "$status" -eq 1 ] || { echo "$output"; return 1; }
	[[ "$output" == *"does not remove MoreMole"* ]] || return 1
	[[ "$output" == *"rm $HOME/.local/bin/mm"*"move $PROJECT_ROOT to the Trash"*"brew uninstall mole"* ]] || return 1
	# Only links to this folder are listed; another tool's mo is not.
	[[ "$output" != *".local/bin/mo "* && "$output" != *".local/bin/mo"$'\n'* ]] || return 1
	[ "$(cat "$HOME/.config/mole/my_commands")" = "keep" ] || return 1
	[ "$(readlink "$HOME/.local/bin/mm")" = "$PROJECT_ROOT/mole" ] || return 1
	grep -qF "SKIPPED $PROJECT_ROOT (moremole remove is not supported)" "$HOME/Library/Logs/mole/operations.log" || return 1
	rm -f "$HOME/.local/bin/mm" "$HOME/.local/bin/mo" # SAFE: test-owned links under the test HOME
}

@test "the help screen names commands moremole, in one aligned column" {
	run env HOME="$HOME" NO_COLOR=1 "$PROJECT_ROOT/mole" --help
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[[ "$output" == *"  moremole clean --dry-run           Preview cleanup"* ]] || return 1
	[[ "$output" == *"  moremole touchid enable --dry-run  Preview Touch ID setup"* ]] || return 1
	[[ "$output" == *"  --debug                            Show detailed operation logs"* ]] || return 1
	[[ "$output" == *"  moremole update   "* && "$output" == *"  moremole remove --dry-run "* ]] || return 1
	# Mole's release channels do nothing in MoreMole, so they are not offered.
	[[ "$output" != *"update --force"* && "$output" != *"update --nightly"* ]] || return 1
	[[ "$output" != *$'\n  mo '* ]]
}

@test "update notices say run moremole update" {
	run /bin/bash --noprofile --norc -c "$(prelude)"'
mkdir -p "$HOME/.cache/mole"
printf "Update 9.8.7 available, run mo update\n" > "$HOME/.cache/mole/update_message"
read_update_message_cache "$HOME/.cache/mole/update_message"
'
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[ "$output" = "Update 9.8.7 available, run moremole update" ]
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

@test "Tab completion covers moremole and mm, and setup uses the moremole command" {
	run "$PROJECT_ROOT/bin/completion.sh" zsh
	[ "$status" -eq 0 ] || return 1
	[[ "$output" == *"#compdef mole mo moremole mm"* ]] || return 1
	[[ "$output" == *"compdef _mole mole mo moremole mm"* ]] || return 1
	run "$PROJECT_ROOT/bin/completion.sh" bash
	[[ "$output" == *"complete -F _mole_completions mole mo moremole mm"* ]] || return 1

	mkdir -p "$HOME/stub-bin"
	printf '#!/bin/bash\n' > "$HOME/stub-bin/moremole"
	chmod +x "$HOME/stub-bin/moremole"
	run env HOME="$HOME" SHELL=/bin/zsh MOLE_DRY_RUN=1 PATH="$HOME/stub-bin:/usr/bin:/bin" \
		"$PROJECT_ROOT/bin/completion.sh"
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	# shellcheck disable=SC2016  # Literal ~/.zshrc text, not an expansion.
	[[ "$output" == *'if output="$(moremole completion zsh 2>/dev/null)"; then eval "$output"; fi'* ]] || return 1

	# The line it writes is recognized again, so a rerun replaces it.
	run /bin/bash --noprofile --norc -c '
source "$1/lib/core/base.sh"
grep -Eq "$MOLE_COMPLETION_LINE_PATTERN" <<< "if output=\"\$(moremole completion zsh 2>/dev/null)\"; then eval \"\$output\"; fi"
' _ "$PROJECT_ROOT"
	[ "$status" -eq 0 ]
}

@test "update_mole runs the moremole sync script in the maintainer's git folder" {
	run /bin/bash --noprofile --norc -c "$(prelude)"'
SCRIPT_DIR="$HOME/fork"
mkdir -p "$SCRIPT_DIR/scripts"
git init -q "$SCRIPT_DIR"
git -C "$SCRIPT_DIR" remote add upstream https://github.com/tw93/Mole.git
printf "echo SYNC_RAN\n" > "$SCRIPT_DIR/scripts/moremole-sync.sh"
update_mole true false
'
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[[ "$output" == *"--force and --nightly are not used"* ]] || return 1
	[[ "$output" == *"SYNC_RAN"* ]]
}

@test "Mole's own updater runs only for Mole's tests of it, never to install Mole over MoreMole" {
	run /bin/bash --noprofile --norc -c "$(prelude)"'
declare -f _moremole_official_update_mole | grep -q "UPDATE_LOCK_CONTROL" || exit 1
_moremole_official_update_mole() { echo "OFFICIAL_UPDATE $*"; }
SCRIPT_DIR="$HOME/not-a-repo"
mkdir -p "$SCRIPT_DIR"
update_mole true false || echo "refused rc=$?"
MOREMOLE_TEST_MOLE_UPDATER=1 update_mole true false
'
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[[ "$output" == *"can't update itself"*"refused rc=1"* ]] || return 1
	[ "$(grep -c "OFFICIAL_UPDATE" <<< "$output")" -eq 1 ] || return 1
	[[ "$output" == *"OFFICIAL_UPDATE true false"* ]]
}

@test "on the menu's own screen, clearing keeps the terminal's scrollback" {
	run /bin/bash --noprofile --norc -c "$(prelude)"'
clear() { printf "CLEAR_CALLED"; }
printf "[%q]\n" "$(_moremole_clear_screen)" "$(_moremole_clear_all)" "$(moremole_menu_leave_screen)"
MOREMOLE_MENU_SCREEN=true
printf "[%q]\n" "$(_moremole_clear_screen)" "$(_moremole_clear_all)"
moremole_menu_leave_screen > "$HOME/leave"
printf "after=%s leave=[%q]\n" "$MOREMOLE_MENU_SCREEN" "$(cat "$HOME/leave")"
'
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	# Without the menu's screen: clear, as before; leaving does nothing.
	[[ "$output" == *"[CLEAR_CALLED]"$'\n'"[CLEAR_CALLED]"$'\n'"['']"* ]] || { echo "$output"; return 1; }
	# On it: escape codes for the screen only, no clear (which empties the
	# scrollback on macOS), and leaving switches back.
	[[ "$output" == *"[\$'\\E[H\\E[2J']"$'\n'"[\$'\\E[?1049h\\E[H\\E[2J']"* ]] || { echo "$output"; return 1; }
	[[ "$output" == *"after=false leave=[\$'\\E[?1049l']"* ]]
}
