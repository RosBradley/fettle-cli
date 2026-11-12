#!/usr/bin/env bats
# shellcheck disable=SC2016  # inner bash scripts expand their own arguments
# Glimwell: Optimize's summary names the optimizations it applied, or that a
# preview would apply, instead of only counting them.

load helpers/common

setup_file() {
	mole_test_setup_home glimwell-optimize
}

teardown_file() {
	mole_test_teardown_home
}

# Load the summary from bin/optimize.sh with every helper it calls, record
# outcomes for the catalog's first three tasks, and print the summary.
summary() {
	run env HOME="$HOME" NO_COLOR=1 MOLE_DRY_RUN="$1" /bin/bash --noprofile --norc -c '
		set -euo pipefail
		source "$1/lib/core/common.sh"
		source "$1/lib/optimize/catalog.sh"
		source "$1/lib/optimize/tasks.sh"
		eval "$(sed -n "/^show_optimization_summary()/,/^}/p" "$1/bin/optimize.sh")"
		optimize_outcomes_reset
		outcomes=(applied unchanged applied)
		for i in 0 1 2; do
			optimize_task_start > /dev/null
			optimize_task_result "${outcomes[i]}"
			optimize_task_finish "${MOLE_OPTIMIZE_ACTIONS[i]}" > /dev/null
		done
		printf "NAMES=%s, %s\n" "${MOLE_OPTIMIZE_HEALTH_NAMES[0]}" "${MOLE_OPTIMIZE_HEALTH_NAMES[2]}"
		show_optimization_summary
	' bash "$PROJECT_ROOT"
}

@test "a preview's summary names the optimizations it would apply" {
	summary 1
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	local names="${output#*NAMES=}"
	names="${names%%$'\n'*}"
	[[ -n "$names" && "$names" != ", " ]] || return 1
	[[ "$output" == *"Would apply 2 optimizations"$'\n'"  $names"$'\n'"1 unchanged"* ]] || { echo "$output"; return 1; }
}

@test "a real run's summary names the optimizations it applied" {
	summary 0
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	local names="${output#*NAMES=}"
	names="${names%%$'\n'*}"
	[[ "$output" == *"Applied 2 optimizations"$'\n'"  $names"$'\n'"1 unchanged"* ]] || { echo "$output"; return 1; }
}
