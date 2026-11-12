#!/usr/bin/env bats
# shellcheck disable=SC2016  # inner bash scripts expand their own arguments
# Glimwell: a command the user cancels tells the menu so, through
# lib/glimwell/cancel.sh, and the menu comes straight back.

load helpers/common

setup_file() {
	mole_test_setup_home glimwell-cancel
}

teardown_file() {
	mole_test_teardown_home
}

setup() {
	if [[ "$HOME" != "${BATS_TEST_DIRNAME}/tmp-"* ]]; then
		printf 'FATAL: HOME is not a test temp dir: %s\n' "$HOME" >&2
		return 1
	fi
	rm -rf "$HOME/.zshrc" "$HOME/.config" # SAFE: test-owned mktemp HOME under tests/tmp-*
	MARKER="$BATS_TEST_TMPDIR/cancelled"
	rm -f "$MARKER"
	export MARKER
}

@test "the cancel note only creates the marker the menu named" {
	run /bin/bash -c '
		source "$1/lib/glimwell/cancel.sh"
		unset GLIMWELL_CANCEL_FILE
		glimwell_note_cancel
		GLIMWELL_CANCEL_FILE="$MARKER" glimwell_note_cancel
		[[ -e "$MARKER" ]] || exit 1
		printf "keep" > "$MARKER"
		GLIMWELL_CANCEL_FILE="$MARKER" glimwell_note_cancel
		cat "$MARKER"
	' bash "$PROJECT_ROOT"
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	# An existing file is never truncated.
	[ "$output" = "keep" ]
}

@test "Q on the Touch ID screen counts as a cancel" {
	local pam_file="$HOME/pam_test"
	printf 'auth       sufficient     pam_opendirectory.so\n' > "$pam_file"
	run env MOLE_TEST_MODE=1 MOLE_PAM_SUDO_FILE="$pam_file" GLIMWELL_CANCEL_FILE="$MARKER" \
		/bin/bash -c 'printf q | "$1/bin/touchid.sh"' bash "$PROJECT_ROOT"
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[[ "$output" == *"not configured"* ]] || return 1
	[ -e "$MARKER" ]
}

@test "Q at the completion prompt counts as a cancel and Enter does not" {
	run env HOME="$HOME" PATH="$PROJECT_ROOT:$PATH" SHELL=/bin/zsh GLIMWELL_CANCEL_FILE="$MARKER" \
		/bin/bash -c 'printf q | "$1/bin/completion.sh"' bash "$PROJECT_ROOT"
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[[ "$output" == *"Cancelled"* ]] || return 1
	[ -e "$MARKER" ] || return 1

	rm -f "$MARKER"
	run env HOME="$HOME" PATH="$PROJECT_ROOT:$PATH" SHELL=/bin/zsh GLIMWELL_CANCEL_FILE="$MARKER" \
		/bin/bash -c 'printf y | "$1/bin/completion.sh"' bash "$PROJECT_ROOT"
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[ ! -e "$MARKER" ]
}

# Mole's updates merge into these files; a hook lost in a merge would bring
# the old "Press Enter" prompt back after that cancel without failing
# anything else.
@test "every cancel path still calls the cancel note" {
	local entry file want got
	for entry in \
		bin/clean.sh:1 bin/completion.sh:2 bin/installer.sh:1 bin/purge.sh:1 \
		bin/slim.sh:2 bin/touchid.sh:3 bin/uninstall.sh:1 \
		lib/uninstall/batch.sh:1 lib/manage/whitelist.sh:1 bin/glimwell-updates.sh:2 \
		bin/glimwell-models.sh:8; do
		file="${entry%:*}"
		want="${entry##*:}"
		got=$(grep -v '^[[:space:]]*#' "$PROJECT_ROOT/$file" | grep -c 'glimwell_note_cancel' || true)
		[ "$got" -eq "$want" ] || { echo "$file: $got calls, expected $want"; return 1; }
	done
	grep -q '^source .*/glimwell/cancel.sh"$' "$PROJECT_ROOT/lib/core/common.sh"
}
