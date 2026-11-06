#!/usr/bin/env bats
# shellcheck disable=SC2016  # inner bash scripts expand their own arguments
# MoreMole: Software updates (bin/moremole-updates.sh). A fake helper stands
# in for moremole-updates-go, and fake brew, mas and open record what would
# have run; nothing touches the real Homebrew, App Store or macOS.

load helpers/common

setup_file() {
	mole_test_setup_home moremole-updates
}

teardown_file() {
	mole_test_teardown_home
}

setup() {
	if [[ "$HOME" != "${BATS_TEST_DIRNAME}/tmp-"* ]]; then
		printf 'FATAL: HOME is not a test temp dir: %s\n' "$HOME" >&2
		return 1
	fi
	export TERM="xterm-256color"
	export MO_DEBUG=0
	rm -rf "$HOME/Library/Logs/mole" # SAFE: test-owned HOME under tests/tmp-*
	ROWS_DIR="$BATS_TEST_TMPDIR/rows"
	CALLS="$BATS_TEST_TMPDIR/calls"
	mkdir -p "$ROWS_DIR"
	: > "$CALLS"
	export ROWS_DIR CALLS

	cat > "$BATS_TEST_TMPDIR/helper" << 'EOF'
#!/bin/bash
[[ -f "$ROWS_DIR/$1" ]] && cat "$ROWS_DIR/$1"
exit 0
EOF
	chmod +x "$BATS_TEST_TMPDIR/helper"
	# The models script records its arguments and hands back the results it
	# is given, or stops without any.
	cat > "$BATS_TEST_TMPDIR/models-script" << 'EOF2'
#!/bin/bash
printf 'models %s\n' "$*" >> "$CALLS"
[[ -f "$BATS_TEST_TMPDIR/model-results" ]] || exit 3
cat "$BATS_TEST_TMPDIR/model-results" > "$MOREMOLE_MODELS_RESULTS"
EOF2
	chmod +x "$BATS_TEST_TMPDIR/models-script"
	mole_test_fake_command brew 'printf "brew %s\n" "$*" >> "$CALLS"; [[ "$*" != *broken* ]]'
	mole_test_fake_command mas 'printf "mas %s\n" "$*" >> "$CALLS"'
	mole_test_fake_command open 'printf "open %s\n" "$*" >> "$CALLS"'
}

# Append a helper row: kind id name installed available note [bundle].
row() {
	local file="$ROWS_DIR/$1"
	shift
	local IFS=$'\x1f'
	printf '%s\n' "$*" >> "$file"
}

updates_env() {
	env HOME="$HOME" PATH="$PATH" MOLE_TEST_MODE=1 \
		MOREMOLE_TEST_UPDATES_HELPER="$BATS_TEST_TMPDIR/helper" \
		MOREMOLE_TEST_MODELS_HELPER="$BATS_TEST_TMPDIR/helper" \
		MOREMOLE_TEST_MODELS_SCRIPT="$BATS_TEST_TMPDIR/models-script" \
		BATS_TEST_TMPDIR="$BATS_TEST_TMPDIR" \
		MOREMOLE_TEST_OPEN="$BATS_TEST_TMPDIR/fake-bin/open" "$@"
}

full_scan_rows() {
	row brew notice homebrew-stale "" "" "" "Couldn't refresh Homebrew's version list."
	row brew app google-chrome "Google Chrome" 124.0 125.0 "updates itself"
	row brew app visual-studio-code "Visual Studio Code" 1.88.0 1.89.0 ""
	row brew tool git git 2.44.0 2.45.0 ""
	row store store 497799835 Xcode 15.0 15.1 ""
	row apps takeover firefox Firefox 129.0 130.0 "replaces your copy"
	row apps feed "/Applications/Postico 2.app" "Postico 2" 2.1 2.2 "opens the app"
	row macos macos-settings "macOS Sequoia 15.1-24B83" "macOS Sequoia 15.1" "" 15.1 "needs a restart, opens Settings"
	row macos macos "Safari18.1-18.1" Safari "" 18.1 ""
}

@test "a dry run lists every source A-Z, none marked, and installs nothing" {
	full_scan_rows
	run updates_env /bin/bash -c 'source "$1"; main --dry-run' bash "$PROJECT_ROOT/bin/moremole-updates.sh"
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[[ "$output" == *"DRY RUN"*"Couldn't refresh Homebrew's version list."*"8 updates available"* ]] || return 1
	# One A-Z list, upper and lower case together, whatever the source.
	[[ "$output" == *"Firefox"*"git"*"Google Chrome"*"macOS Sequoia"*"Postico 2"*"Safari"*"Visual Studio Code"*"Xcode"* ]] || return 1
	# The source comes first, under a heading line.
	[[ "$output" == *"Source       Name"*"Version"*"Note"* ]] || return 1
	[[ "$output" == *$'\n  Homebrew     Visual Studio Code'*"1.88.0 → 1.89.0"* ]] || return 1
	[[ "$output" == *"Homebrew     Google Chrome"*"updates itself"* ]] || return 1
	[[ "$output" == *"To Homebrew  Firefox"*"replaces your copy"* ]] || return 1
	[[ "$output" == *"Own updater  Postico 2"*"2.1 → 2.2"*"opens the app"* ]] || return 1
	[[ "$output" == *"App Store    Xcode"* ]] || return 1
	[[ "$output" == *"CLI tool     git"* ]] || return 1
	[[ "$output" == *"macOS        macOS Sequoia 15.1"*"needs a restart"* ]] || return 1
	# The DRY RUN banner's own icon is a ○, so only the list after it is checked.
	local list="${output#*DRY RUN MODE}"
	[[ "$list" != *"●"* && "$list" != *"○"* ]] || return 1
	[ ! -s "$CALLS" ]
}

@test "without a terminal the list is shown and nothing is installed" {
	full_scan_rows
	run updates_env /bin/bash -c 'source "$1"; main < /dev/null' bash "$PROJECT_ROOT/bin/moremole-updates.sh"
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[[ "$output" != *"DRY RUN"* ]] || return 1
	[[ "$output" == *"8 updates available"*"Run moremole updates in a terminal to choose updates."* ]] || return 1
	[ ! -s "$CALLS" ]
}

@test "nothing to update says so, and a missing helper says how to build it" {
	run updates_env /bin/bash -c 'source "$1"; main --dry-run' bash "$PROJECT_ROOT/bin/moremole-updates.sh"
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[[ "$output" == *"Everything is up to date"* ]] || return 1

	run updates_env MOREMOLE_TEST_UPDATES_HELPER="$BATS_TEST_TMPDIR/missing" \
		/bin/bash -c 'source "$1"; main --dry-run' bash "$PROJECT_ROOT/bin/moremole-updates.sh"
	[ "$status" -eq 1 ] || { echo "$output"; return 1; }
	[[ "$output" == *"make build"* ]] || return 1

	run updates_env /bin/bash -c 'source "$1"; main --bogus' bash "$PROJECT_ROOT/bin/moremole-updates.sh"
	[ "$status" -eq 1 ]
}

@test "helper rows keep empty fields and notices stay out of the update list" {
	row brew notice mas-missing "" "" "" "App Store apps need mas."
	row brew macos "Label-1" "Safari" "" 18.1 ""
	run updates_env /bin/bash -c '
		source "$1"
		load_update_rows < "$ROWS_DIR/brew"
		printf "count=%s notices=%s\n" "${#U_KIND[@]}" "${NOTICE_KEYS[*]}"
		printf "[%s][%s][%s][%s][%s][%s]\n" "${U_KIND[0]}" "${U_ID[0]}" "${U_NAME[0]}" "${U_FROM[0]}" "${U_TO[0]}" "${U_NOTE[0]}"
		printf "version=%s\n" "$(version_text 0)"
	' bash "$PROJECT_ROOT/bin/moremole-updates.sh"
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[[ "$output" == *"count=1 notices=mas-missing"* ]] || return 1
	[[ "$output" == *"[macos][Label-1][Safari][][18.1][]"* ]] || return 1
	[[ "$output" == *"version=18.1"* ]]
}

@test "D with nothing selected installs nothing" {
	full_scan_rows
	printf '%s\n' CHAR:d > "$BATS_TEST_TMPDIR/keys"
	run updates_env KEYS_FILE="$BATS_TEST_TMPDIR/keys" KEY_STATE="$BATS_TEST_TMPDIR/key-state" /bin/bash -c '
		source "$1"
		enter_alt_screen() { :; }
		leave_alt_screen() { :; }
		stty() { :; }
		tput() { if [[ "$1" == cols ]]; then echo 80; else echo 20; fi; }
		drain_pending_input() { :; }
		read_key() {
			local index key
			index=$(cat "$KEY_STATE" 2>/dev/null || echo 0)
			index=$((index + 1))
			printf "%s\n" "$index" > "$KEY_STATE"
			key=$(sed -n "${index}p" "$KEYS_FILE")
			printf "%s\n" "${key:-QUIT}"
		}
		for source in brew store apps macos; do
			load_update_rows < "$ROWS_DIR/$source"
		done
		order_update_rows
		if select_updates; then echo PICKED; else echo NOTHING; fi
		printf "RESULT=[%s]\n" "$MOLE_SELECTION_RESULT"
	' bash "$PROJECT_ROOT/bin/moremole-updates.sh"
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[[ "$output" == *"NOTHING"*"RESULT=[]"* ]] || return 1
	[ ! -s "$CALLS" ]
}

@test "the pick list starts with nothing selected, in A-Z order" {
	full_scan_rows
	printf '%s\n' SPACE DOWN DOWN SPACE CHAR:d > "$BATS_TEST_TMPDIR/keys"
	run updates_env COLUMNS=60 KEYS_FILE="$BATS_TEST_TMPDIR/keys" KEY_STATE="$BATS_TEST_TMPDIR/key-state" /bin/bash -c '
		source "$1"
		enter_alt_screen() { :; }
		leave_alt_screen() { :; }
		stty() { :; }
		tput() { if [[ "$1" == cols ]]; then echo 60; else echo 20; fi; }
		drain_pending_input() { :; }
		read_key() {
			local index key
			index=$(cat "$KEY_STATE" 2>/dev/null || echo 0)
			index=$((index + 1))
			printf "%s\n" "$index" > "$KEY_STATE"
			key=$(sed -n "${index}p" "$KEYS_FILE")
			printf "%s\n" "${key:-QUIT}"
		}
		for source in brew store apps macos; do
			load_update_rows < "$ROWS_DIR/$source"
		done
		order_update_rows
		select_updates || exit 1
		printf "RESULT=%s\n" "$MOLE_SELECTION_RESULT"
		printf "first=%s last=%s\n" "${U_NAME[0]}" "${U_NAME[7]}"
		measure_columns
		for ((i = 0; i < ${#U_KIND[@]}; i++)); do
			w=$(text_width "$(update_row_text "$i")")
			((w <= 56)) || { echo "row $i is $w cells wide"; exit 1; }
		done
	' bash "$PROJECT_ROOT/bin/moremole-updates.sh"
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	# Only the rows picked with Space: Firefox (0) and Google Chrome (2).
	[[ "$output" == *"RESULT=0,2"* ]] || return 1
	[[ "$output" == *"first=Firefox last=Xcode"* ]]
}

@test "Enter shows an update's details: its source, versions and what updating does" {
	full_scan_rows
	# A-Z: Firefox first. Its details, then the next (git), then back.
	printf '%s\n' ENTER DOWN QUIT QUIT > "$BATS_TEST_TMPDIR/keys"
	run updates_env COLUMNS=100 KEYS_FILE="$BATS_TEST_TMPDIR/keys" KEY_STATE="$BATS_TEST_TMPDIR/key-state" /bin/bash -c '
		source "$1"
		enter_alt_screen() { :; }
		leave_alt_screen() { :; }
		stty() { :; }
		tput() { if [[ "$1" == cols ]]; then echo 100; else echo 30; fi; }
		drain_pending_input() { :; }
		read_key() {
			local index key
			index=$(cat "$KEY_STATE" 2>/dev/null || echo 0)
			index=$((index + 1))
			printf "%s\n" "$index" > "$KEY_STATE"
			key=$(sed -n "${index}p" "$KEYS_FILE")
			printf "%s\n" "${key:-QUIT}"
		}
		for source in brew store apps macos; do
			load_update_rows < "$ROWS_DIR/$source"
		done
		order_update_rows
		select_updates || echo NOTHING
	' bash "$PROJECT_ROOT/bin/moremole-updates.sh"
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[[ "$output" == *"Source"*"Name"*"Version"*"Note"* ]] || return 1
	[[ "$output" == *"Enter Details"*"D Update"* ]] || return 1
	[[ "$output" == *"1 of 8"*"Firefox"*"Source"*"Move to Homebrew"*"Version"*"129.0 → 130.0"*"Homebrew name"*"firefox"*"Updating"*"brew install --cask --force firefox"* ]] || return 1
	[[ "$output" == *"2 of 8"*"git"*"Command-line tool"*"brew upgrade --formula git"* ]] || return 1
	[[ "$output" == *"NOTHING"* ]] || return 1
	[ ! -s "$CALLS" ]
}

@test "the confirm screen warns about what each kind of update does" {
	full_scan_rows
	run updates_env /bin/bash -c '
		source "$1"
		for source in brew store apps macos; do
			load_update_rows < "$ROWS_DIR/$source"
		done
		order_update_rows
		# Firefox, Google Chrome, macOS Sequoia, Postico 2, Safari, Xcode.
		printf "\n" | confirm_updates 0 2 3 4 5 7 && echo CONFIRMED
		printf "x" | confirm_updates 1 || echo CANCELLED
	' bash "$PROJECT_ROOT/bin/moremole-updates.sh"
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[[ "$output" == *"Apps being updated may quit"* ]] || return 1
	[[ "$output" == *"Apps moved to Homebrew are replaced by Homebrew's copy"* ]] || return 1
	[[ "$output" == *"App Store updates may ask for your password"* ]] || return 1
	[[ "$output" == *"macOS updates ask for your password"* ]] || return 1
	[[ "$output" == *"Updates that restart the Mac open Software Update"* ]] || return 1
	[[ "$output" == *"Apps with their own updater open at the end"* ]] || return 1
	[[ "$output" == *"Install 6 updates"*"CONFIRMED"* ]] || return 1
	[[ "$output" == *"CANCELLED"* ]]
}

@test "installing runs each source's own command, logs each one and opens Software Update once" {
	row scan app visual-studio-code "Visual Studio Code" 1.88.0 1.89.0 ""
	row scan app broken "Broken App" 1.0 2.0 ""
	row scan tool git git 2.44.0 2.45.0 ""
	row scan takeover firefox Firefox 129.0 130.0 ""
	row scan store 497799835 Xcode 15.0 15.1 ""
	row scan macos "Safari18.1-18.1" Safari "" 18.1 ""
	row scan macos-settings "macOS Sequoia 15.1-24B83" "macOS Sequoia 15.1" "" 15.1 ""
	row scan macos-settings "Some Firmware-1.0" "Some Firmware" "" 1.0 ""
	run updates_env /bin/bash -c '
		source "$1"
		load_update_rows < "$ROWS_DIR/scan"
		install_updates 0 1 2 3 4 5 6 7
		show_updates_summary
		printf "updated=%s failed=%s\n" "$total_updated" "$total_failed"
	' bash "$PROJECT_ROOT/bin/moremole-updates.sh"
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[[ "$output" != *"UNSTUBBED"* ]] || return 1
	[[ "$output" == *"updated=4 failed=2"* ]] || return 1
	[[ "$output" == *"Some updates did not install"*"Updated"*"4"* ]] || return 1
	[[ "$output" == *"Not updated: Broken App: brew reported an error"* ]] || return 1
	[[ "$output" == *"Not updated: Safari: needs your password"* ]] || return 1
	[[ "$output" == *"Opened Software Update for: macOS Sequoia 15.1, Some Firmware"* ]] || return 1

	local calls
	calls=$(cat "$CALLS")
	[ "$calls" = "brew upgrade --cask --greedy visual-studio-code
brew upgrade --cask --greedy broken
brew upgrade --formula git
brew install --cask --force firefox
mas upgrade 497799835
open x-apple.systempreferences:com.apple.Software-Update-Settings.extension" ] || { echo "$calls"; return 1; }

	local log="$HOME/Library/Logs/mole/operations.log"
	grep -q "REBUILT Visual Studio Code (updated to 1.89.0, Homebrew)" "$log" || return 1
	grep -q "REBUILT Firefox (updated to 130.0, Move to Homebrew)" "$log" || return 1
	grep -q "FAILED Broken App (brew reported an error)" "$log" || return 1
	grep -q "FAILED Safari (needs your password)" "$log" || return 1
	grep -q "SKIPPED Some Firmware (opened Software Update in System Settings)" "$log" || return 1
	[ "$(grep -c "REBUILT" "$log")" -eq 4 ]
}

@test "apps with their own updater open after the other updates, and a missing app is not opened" {
	mkdir -p "$BATS_TEST_TMPDIR/Apps/Postico 2.app" "$BATS_TEST_TMPDIR/Apps/Other.app"
	row scan feed "$BATS_TEST_TMPDIR/Apps/Postico 2.app" "Postico 2" 2.1 2.2 ""
	row scan app visual-studio-code "Visual Studio Code" 1.88.0 1.89.0 ""
	row scan feed "$BATS_TEST_TMPDIR/Apps/Gone.app" Gone 1.0 2.0 ""
	row scan feed "$BATS_TEST_TMPDIR/Apps/Other.app" Other 3.0 3.1 ""
	run updates_env /bin/bash -c '
		source "$1"
		load_update_rows < "$ROWS_DIR/scan"
		install_updates 0 1 2 3
		show_updates_summary
		printf "updated=%s failed=%s\n" "$total_updated" "$total_failed"
	' bash "$PROJECT_ROOT/bin/moremole-updates.sh"
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[[ "$output" == *"updated=1 failed=1"* ]] || return 1
	[[ "$output" == *"Not updated: Gone: app not found"* ]] || return 1
	[[ "$output" == *"Opened for their own updater: Postico 2, Other"*"Check for Updates"* ]] || return 1

	local calls
	calls=$(cat "$CALLS")
	[ "$calls" = "brew upgrade --cask --greedy visual-studio-code
open $BATS_TEST_TMPDIR/Apps/Postico 2.app
open $BATS_TEST_TMPDIR/Apps/Other.app" ] || { echo "$calls"; return 1; }

	local log="$HOME/Library/Logs/mole/operations.log"
	grep -q "SKIPPED Postico 2 (opened for its own updater)" "$log" || return 1
	grep -q "FAILED Gone (app not found)" "$log"
}

@test "opening only apps with their own updater asks to finish in each app" {
	mkdir -p "$BATS_TEST_TMPDIR/Apps/Postico 2.app"
	row scan feed "$BATS_TEST_TMPDIR/Apps/Postico 2.app" "Postico 2" 2.1 2.2 ""
	run updates_env /bin/bash -c '
		source "$1"
		load_update_rows < "$ROWS_DIR/scan"
		install_updates 0
		show_updates_summary
	' bash "$PROJECT_ROOT/bin/moremole-updates.sh"
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[[ "$output" == *"Finish in each app"*"Opened for their own updater: Postico 2"* ]] || return 1
	[[ "$output" != *"Nothing was updated"* ]]
}

@test "the app MoreMole runs inside is marked, left out at confirm and never installed" {
	printf '%s\n' com.googlecode.iterm2 > "$ROWS_DIR/host"
	row brew app iterm2 iTerm2 3.7.5 3.7.6 "updates itself" com.googlecode.iterm2
	row brew app visual-studio-code "Visual Studio Code" 1.88.0 1.89.0 "" com.microsoft.VSCode
	run updates_env COLUMNS=120 /bin/bash -c 'source "$1"; main --dry-run' bash "$PROJECT_ROOT/bin/moremole-updates.sh"
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[[ "$output" == *"Homebrew     iTerm2"*"runs MoreMole, updates itself"* ]] || return 1
	[[ "$output" != *"Visual Studio Code"*"runs MoreMole"* ]] || return 1

	run updates_env /bin/bash -c '
		source "$1"
		HOST_BUNDLES=(com.googlecode.iterm2)
		load_update_rows < "$ROWS_DIR/brew"
		order_update_rows
		printf "\n" | confirm_updates 0 1 && echo CONFIRMED
		echo ---
		confirm_updates 0 < /dev/null && echo NO_QUESTION
		echo ---
		install_updates 0 1
		show_updates_summary
	' bash "$PROJECT_ROOT/bin/moremole-updates.sh"
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	local confirm="${output%%---*}" alone rest
	rest="${output#*---}"
	alone="${rest%%---*}"
	[[ "$confirm" == *"- iTerm2"*"left out: it runs MoreMole"* ]] || return 1
	[[ "$confirm" == *"iTerm2 runs MoreMole, so updating it from here could end this run. To update it, quit iTerm2, open Terminal (Applications › Utilities) and run:"$'\n'"    brew upgrade --cask --greedy iterm2"$'\n'* ]] || return 1
	[[ "$confirm" == *"Install 1 updates"*"CONFIRMED"* ]] || return 1
	# Picking only that app asks nothing; the summary explains.
	[[ "$alone" == *"left out"*"NO_QUESTION"* && "$alone" != *"Install"*"updates  "* ]] || return 1
	[[ "$output" == *"Updates installed"*"Updated"*"1"*"Left out: iTerm2 runs MoreMole"*"and run:"$'\n'"    brew upgrade --cask --greedy iterm2"$'\n'* ]] || return 1

	local calls
	calls=$(cat "$CALLS")
	[ "$calls" = "brew upgrade --cask --greedy visual-studio-code" ] || { echo "$calls"; return 1; }
	grep -q "SKIPPED iTerm2 (runs MoreMole; update it from another terminal)" "$HOME/Library/Logs/mole/operations.log"
}

@test "picking only the app MoreMole runs inside installs nothing and says so" {
	printf '%s\n' com.googlecode.iterm2 > "$ROWS_DIR/host"
	row scan feed "$BATS_TEST_TMPDIR/iTerm.app" iTerm2 3.7.5 3.7.6 "opens the app" com.googlecode.iterm2
	mkdir -p "$BATS_TEST_TMPDIR/iTerm.app"
	run updates_env /bin/bash -c '
		source "$1"
		HOST_BUNDLES=(com.googlecode.iterm2)
		load_update_rows < "$ROWS_DIR/scan"
		install_updates 0
		show_updates_summary
	' bash "$PROJECT_ROOT/bin/moremole-updates.sh"
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[[ "$output" == *"Nothing installed"*"Nothing was updated"*"Left out: iTerm2 runs MoreMole"*"To update it, choose Check for Updates in the iTerm2 menu."* ]] || return 1
	[[ "$output" != *"brew upgrade"* ]] || return 1
	[ ! -s "$CALLS" ]
}

@test "each app MoreMole runs inside gets the steps for where its update comes from" {
	row scan app ghostty Ghostty 1.2.0 1.2.1 "" com.mitchellh.ghostty
	row scan takeover wezterm WezTerm 2024 2025 "" com.github.wez.wezterm
	row scan store 1234567 "Store Term" 1.0 1.1 "" com.example.storeterm
	row scan app 'bad;token' "Odd Term" 1.0 1.1 "" com.example.odd
	run updates_env /bin/bash -c '
		source "$1"
		HOST_BUNDLES=(com.mitchellh.ghostty com.github.wez.wezterm com.example.storeterm com.example.odd)
		load_update_rows < "$ROWS_DIR/scan"
		confirm_updates 0 1 2 3 < /dev/null
	' bash "$PROJECT_ROOT/bin/moremole-updates.sh"
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[[ "$output" == *"quit Ghostty, open Terminal (Applications › Utilities) and run:"$'\n'"    brew upgrade --cask --greedy ghostty"$'\n'* ]] || return 1
	[[ "$output" == *"quit WezTerm, open Terminal (Applications › Utilities) and run:"$'\n'"    brew install --cask --force wezterm"$'\n'* ]] || return 1
	[[ "$output" == *"To update it, open the App Store, click Updates and update Store Term there."* ]] || return 1
	# A name that isn't a plain Homebrew token is never printed as a command.
	[[ "$output" == *"Odd Term runs MoreMole"*"Use the app's own Check for Updates, or update it from another terminal."* ]] || return 1
	[[ "$output" != *"bad;token"* ]]
}

@test "a failed update names the tool's own error in the summary and History" {
	# shellcheck disable=SC2016  # the fake brew expands its own arguments
	mole_test_fake_command brew 'printf "brew %s\n" "$*" >> "$CALLS"
printf "==> Downloading\n"
printf "\033[31mError:\033[0m broken: Download failed: could not resolve host\n" >&2
exit 1'
	row scan app broken "Broken App" 1.0 2.0 ""
	run updates_env /bin/bash -c '
		source "$1"
		load_update_rows < "$ROWS_DIR/scan"
		install_updates 0
		show_updates_summary
	' bash "$PROJECT_ROOT/bin/moremole-updates.sh"
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	# Shown live, then named in the summary.
	[[ "$output" == *"==> Downloading"*"Download failed"*"Not updated: Broken App: broken: Download failed: could not resolve host"* ]] || return 1
	grep -q "FAILED Broken App (broken: Download failed: could not resolve host)" "$HOME/Library/Logs/mole/operations.log"
}

@test "a cask stopped by Homebrew's own leftover copy is retried once with --force, nothing else is" {
	# shellcheck disable=SC2016  # the fake brew expands its own arguments
	mole_test_fake_command brew 'printf "brew %s\n" "$*" >> "$CALLS"
case "$*" in
	--caskroom) echo /opt/homebrew/Caskroom ;;
	*--force*) exit 0 ;;
	*font-x) echo "Error: font-x: It seems there is already a Font at '"'"'/opt/homebrew/Caskroom/font-x/3.4.0/X.ttf'"'"'." >&2; exit 1 ;;
	*outside) echo "Error: outside: It seems there is already a Font at '"'"'/Users/me/Library/Fonts/X.ttf'"'"'." >&2; exit 1 ;;
	*climber) echo "Error: climber: It seems there is already an App at '"'"'/opt/homebrew/Caskroom/climber/../other/A.app'"'"'." >&2; exit 1 ;;
esac'
	row scan app font-x "Font X" 3.4.0 3.5.1 ""
	row scan app outside "Outside" 1.0 2.0 ""
	row scan app climber "Climber" 1.0 2.0 ""
	run updates_env /bin/bash -c '
		source "$1"
		load_update_rows < "$ROWS_DIR/scan"
		install_updates 0 1 2
		show_updates_summary
		printf "updated=%s failed=%s\n" "$total_updated" "$total_failed"
	' bash "$PROJECT_ROOT/bin/moremole-updates.sh"
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[[ "$output" == *"trying again with --force"* ]] || return 1
	[[ "$output" == *"updated=1 failed=2"* ]] || return 1
	[[ "$output" == *"Updated after replacing Homebrew's leftover copy: Font X"* ]] || return 1
	[[ "$output" == *"Not updated: Outside: outside: It seems there is already a Font at '/Users/me/Library/Fonts/X.ttf'."* ]] || return 1
	# The log says the update needed --force.
	grep -qE "REBUILT Font X \(updated to 3\.5\.1, .*retried with --force\)" "$HOME/Library/Logs/mole/operations.log" || { cat "$HOME/Library/Logs/mole/operations.log"; return 1; }

	local calls
	calls=$(cat "$CALLS")
	[ "$calls" = "brew upgrade --cask --greedy font-x
brew --caskroom
brew upgrade --cask --greedy --force font-x
brew upgrade --cask --greedy outside
brew --caskroom
brew upgrade --cask --greedy climber
brew --caskroom" ] || { echo "$calls"; return 1; }
}

@test "updates is a command with help, completion and a menu row" {
	run "$PROJECT_ROOT/mole" updates --help
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[[ "$output" == *"Usage: moremole updates"*"--dry-run"* ]] || return 1

	run /bin/bash -c 'source "$1/lib/core/commands.sh"; printf "%s\n" "${MOLE_COMMANDS[@]}"' bash "$PROJECT_ROOT"
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[[ "$output" == *$'slim:Remove Intel code from universal apps\nupdates:Update apps, tools, macOS and Ollama models\n'* ]] || return 1

	run "$PROJECT_ROOT/mole" --help
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[[ "$output" == *"slim"*"updates"*"Update apps, tools, macOS and Ollama models"* ]]
}

@test "Ollama models with an update join the list, and the picked ones update after the rest in one run" {
	row brew app visual-studio-code "Visual Studio Code" 1.88.0 1.89.0 ""
	row updates model llama3.2:latest llama3.2:latest "" "" "newer download on Ollama"
	row updates model-hf hf.co/me/m-4bit:latest hf.co/me/m-4bit:latest "" "" "newer files on Hugging Face"
	row updates notice models-unchecked "" "" "" "Couldn't check 1 of 3 Ollama models for updates."
	run updates_env COLUMNS=120 /bin/bash -c 'source "$1"; main --dry-run' bash "$PROJECT_ROOT/bin/moremole-updates.sh"
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[[ "$output" == *"Couldn't check 1 of 3 Ollama models"*"3 updates available"* ]] || return 1
	[[ "$output" == *"Ollama       hf.co/me/m-4bit:latest"*"newer files on Hugging Face"*"Ollama       llama3.2:latest"*"newer download on Ollama"*"Homebrew     Visual Studio Code"* ]] || return 1
	[ ! -s "$CALLS" ] || return 1

	# Installing: Homebrew first, then one models run with every picked model.
	printf 'done\t1\nfailed\thf.co/me/m-4bit:latest: couldn'"'"'t get it from Hugging Face\nnote\tOllama was off, so it is off again\n' > "$BATS_TEST_TMPDIR/model-results"
	run updates_env /bin/bash -c '
		source "$1"
		for source in brew updates; do
			load_update_rows < "$ROWS_DIR/$source"
		done
		order_update_rows
		printf "\n" | confirm_updates 0 1 2 && echo CONFIRMED
		install_updates 0 1 2
		show_updates_summary
		printf "updated=%s failed=%s\n" "$total_updated" "$total_failed"
	' bash "$PROJECT_ROOT/bin/moremole-updates.sh"
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[[ "$output" == *"Ollama models download only the parts that changed."*"Models from Hugging Face download again in full"*"If Ollama is off, it is turned on for the models and off again after."*"Install 3 updates"*"CONFIRMED"* ]] || return 1
	[[ "$output" == *"updated=2 failed=1"* ]] || return 1
	[[ "$output" == *"Not updated: hf.co/me/m-4bit:latest: couldn't get it from Hugging Face"*"Ollama was off, so it is off again"* ]] || return 1
	[ "$(cat "$CALLS")" = "brew upgrade --cask --greedy visual-studio-code
models --install-updates hf.co/me/m-4bit:latest llama3.2:latest" ] || { cat "$CALLS"; return 1; }

	# A models run that stops before saying how it went fails each model.
	rm -f "$BATS_TEST_TMPDIR/model-results"
	: > "$CALLS"
	run updates_env /bin/bash -c '
		source "$1"
		load_update_rows < "$ROWS_DIR/updates"
		install_updates 0 1
		show_updates_summary
		printf "updated=%s failed=%s\n" "$total_updated" "$total_failed"
	' bash "$PROJECT_ROOT/bin/moremole-updates.sh"
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[[ "$output" == *"Not updated: llama3.2:latest: the model update stopped (exit 3)"*"updated=0 failed=2"* ]] || { echo "$output"; return 1; }
	grep -q "FAILED hf.co/me/m-4bit:latest (the model update stopped (exit 3))" "$HOME/Library/Logs/mole/operations.log"
}
