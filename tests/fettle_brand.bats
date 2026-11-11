#!/usr/bin/env bats
# fettle: what users see says Fettle, not Mole (scripts/fettle_brand_audit.py),
# in the Patina colors, with Mole credited once on the version screen.

load helpers/common

setup_file() {
	mole_test_setup_home "fettle-brand"
}

teardown_file() {
	mole_test_teardown_home
}

# Run the router with color, as a terminal would show it, at 100 columns.
router() {
	env MOLE_TEST_NO_AUTH=1 COLUMNS=100 LINES=40 "$PROJECT_ROOT/mole" "$@"
}

@test "no user-visible text in the code names Mole or its mo command" {
	run python3 -I "$PROJECT_ROOT/scripts/fettle_brand_audit.py"
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "the audit names a new Mole message and says how to fix it" {
	mkdir -p "$HOME/repo/scripts" "$HOME/repo/bin"
	cp "$PROJECT_ROOT/scripts/fettle_brand_audit.py" "$HOME/repo/scripts/"
	printf '#!/bin/bash\n' > "$HOME/repo/mole"
	# shellcheck disable=SC2016  # Literal shell source for the fixture.
	printf '#!/bin/bash\n# Mole in a comment is fine\necho "Run mo clean to free space"\nrm -rf "$x" # SAFE: Mole temp\n' > "$HOME/repo/bin/new.sh"
	run python3 -I "$HOME/repo/scripts/fettle_brand_audit.py"
	[ "$status" -eq 1 ] || { echo "$output"; return 1; }
	[[ "$output" == *"bin/new.sh:3: echo \"Run mo clean to free space\""* ]] || { echo "$output"; return 1; }
	[[ "$output" != *"bin/new.sh:2"* && "$output" != *"bin/new.sh:4"* ]] || { echo "$output"; return 1; }
	[[ "$output" == *"Say Fettle, and fettle <command> for mo <command>."* ]]
}

@test "help, update, remove and completion help name Fettle only" {
	local screen
	for screen in "--help" "update --help" "remove --help" "completion --help"; do
		# shellcheck disable=SC2086  # Each screen is a command and its option.
		run router $screen
		[ "$status" -eq 0 ] || { echo "$screen: $output"; return 1; }
		[[ "$output" == *fettle* ]] || { echo "$screen: $output"; return 1; }
		if printf '%s\n' "$output" | grep -Eq '\bMole\b|\bmole (completion|update|remove)|(^|[^[:alnum:]])mo (clean|update|remove|completion|--)'; then
			echo "$screen still names Mole:"
			printf '%s\n' "$output" | grep -E '\bMole\b|\bmole |(^|[^[:alnum:]])mo '
			return 1
		fi
	done
}

@test "the version screen names Fettle first and credits Mole once" {
	local expected
	expected="$(sed -n 's/^VERSION="\(.*\)"$/\1/p' "$PROJECT_ROOT/mole" | head -1)"
	run router --version
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[[ "$(printf '%s\n' "$output" | grep -v '^$' | head -1)" == "Fettle"* ]] || { echo "$output"; return 1; }
	[[ "$output" == *$'\ngithub.com/RosBradley/fettle-cli\n'"Based on Mole $expected by tw93: github.com/tw93/Mole"$'\n'* ]] || { echo "$output"; return 1; }
	[ "$(printf '%s\n' "$output" | grep -c 'Mole')" -eq 1 ]
}

@test "the banner spells Fettle in the accent color with the repository in copper" {
	run router --help
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	local esc=$'\033'
	[[ "$output" == *"${esc}[0;38;5;30m|_|  \\___|\\__|\\__|_|\\___|${esc}[0m  Manage, update and remove apps."* ]] || { echo "$output"; return 1; }
	[[ "$output" == *"${esc}[1;38;5;166mgithub.com/RosBradley/fettle-cli${esc}[0m"* ]] || { echo "$output"; return 1; }
	[[ "$output" != *"|  \\/  |"* ]]
}

@test "the Patina colors replace Mole's purple in every screen" {
	run /bin/bash --noprofile --norc -c 'MOLE_TEST_NO_AUTH=1 source "$1/lib/core/base.sh"; printf "%q\n" "$PURPLE" "$PURPLE_BOLD" "$CYAN" "$BLUE" "$GREEN" "$YELLOW" "$RED"' _ "$PROJECT_ROOT"
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[ "$output" = "$(printf '%s\n' "\$'\\E[0;38;5;30m'" "\$'\\E[1;38;5;30m'" "\$'\\E[0;38;5;30m'" "\$'\\E[1;38;5;166m'" "\$'\\E[0;32m'" "\$'\\E[0;33m'" "\$'\\E[0;31m'")" ] || { echo "$output"; return 1; }
	grep -qF 'colorPurpleBold = "\033[1;38;5;30m"' "$PROJECT_ROOT/cmd/analyze/constants.go" || return 1
	grep -qF 'titleStyle  = "\x1b[1;38;5;30m"' "$PROJECT_ROOT/cmd/fettle-view/view.go" || return 1
	grep -qF 'titleStyle  = lipgloss.NewStyle().Foreground(lipgloss.Color("30")).Bold(true)' "$PROJECT_ROOT/cmd/status/view.go"
}

@test "command titles carry the Fettle badge only on a color terminal outside the Fettle screen" {
	# shellcheck disable=SC2016  # The inner bash expands these.
	local probe='source "$PROJECT_ROOT/lib/core/common.sh"; printf "[%s]\n" "$FETTLE_BADGE"'
	run env PROJECT_ROOT="$PROJECT_ROOT" script -q /dev/null /bin/bash -c "$probe" < /dev/null
	[[ "$output" == *$'\033[1;97;48;5;30m F'* ]] || { printf '%q\n' "$output"; return 1; }
	run env PROJECT_ROOT="$PROJECT_ROOT" FETTLE_IN_PANE=1 script -q /dev/null /bin/bash -c "$probe" < /dev/null
	[[ "$output" == *"[]"* ]] || { printf '%q\n' "$output"; return 1; }
	run env PROJECT_ROOT="$PROJECT_ROOT" NO_COLOR=1 script -q /dev/null /bin/bash -c "$probe" < /dev/null
	[[ "$output" == *"[]"* ]] || { printf '%q\n' "$output"; return 1; }
	run env PROJECT_ROOT="$PROJECT_ROOT" /bin/bash -c "$probe"
	[ "$output" = "[]" ]
}

# shellcheck disable=SC2016  # Literal source text to find.
@test "each command title and the Fettle screen use the badge" {
	grep -Fq '${FETTLE_BADGE}${PURPLE_BOLD}Clean Your Mac' "$PROJECT_ROOT/bin/clean.sh" || return 1
	grep -Fq '${FETTLE_BADGE}${PURPLE_BOLD}Clean External Volume' "$PROJECT_ROOT/bin/clean.sh" || return 1
	grep -Fq '${FETTLE_BADGE}${PURPLE_BOLD}Optimize' "$PROJECT_ROOT/bin/optimize.sh" || return 1
	[ "$(grep -Fc '${FETTLE_BADGE}${PURPLE_BOLD}Purge Project Artifacts' "$PROJECT_ROOT/bin/purge.sh")" -eq 2 ] || return 1
	grep -Fq '${FETTLE_BADGE}${PURPLE_BOLD}Software updates' "$PROJECT_ROOT/bin/fettle-updates.sh" || return 1
	grep -Fq 'FETTLE_IN_PANE=1 FETTLE_CANCEL_FILE=' "$PROJECT_ROOT/lib/fettle/menu.sh"
}
