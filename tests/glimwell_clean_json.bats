#!/usr/bin/env bats
# glimwell: `clean --dry-run --json` and `clean --json --only FILE`, the
# interface the Glimwell app uses for Clean (lib/glimwell/clean_json.sh).

load helpers/common

setup_file() {
	mole_test_setup_home "glimwell-clean-json"
}

teardown_file() {
	mole_test_teardown_home
}

setup() {
	if [[ "$HOME" != "${BATS_TEST_DIRNAME}/tmp-"* ]]; then
		printf 'FATAL: HOME is not a test temp dir: %s\n' "$HOME" >&2
		return 1
	fi
	rm -rf "${HOME:?}"/*
	mkdir -p "$HOME/.config/mole" "$HOME/Library/Caches"
}

# Run a script with the clean command loaded, in this test's HOME.
with_clean() {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_MODE=1 MOLE_TEST_NO_AUTH=1 \
		MOLE_CURRENT_COMMAND=clean /bin/bash --noprofile --norc -c "set -euo pipefail
source \"\$PROJECT_ROOT/bin/clean.sh\"
set +e
$1"
}

@test "a selection file lists only path and step IDs below a top-level folder" {
	local good="$HOME/good.txt"
	printf '%s\n' "path:$HOME/Library/Caches/a" "" "step:npm-cache" > "$good"
	with_clean "glimwell_clean_selection_check_file '$good' && echo OK"
	[[ "$output" == *OK* ]] || { echo "$output"; return 1; }

	local bad="$HOME/bad.txt" line
	for line in "path:/" "path:/Users" "path:$HOME/../etc" "rm -rf /" "step:npm cache" "path:relative/x"; do
		printf '%s\n' "$line" > "$bad"
		with_clean "glimwell_clean_selection_check_file '$bad'; echo \"rc=\$?\""
		[[ "$output" == *"rc=1"* && "$output" == *"glimwell clean --only: line 1"* ]] || { echo "$line -> $output"; return 1; }
	done

	: > "$bad"
	with_clean "glimwell_clean_selection_check_file '$bad'; echo \"rc=\$?\""
	[[ "$output" == *"rc=1"* && "$output" == *"lists nothing to remove"* ]] || { echo "$output"; return 1; }
	with_clean "glimwell_clean_selection_check_file '$HOME/missing.txt'; echo \"rc=\$?\""
	[[ "$output" == *"rc=1"* && "$output" == *"was not found"* ]] || { echo "$output"; return 1; }
}

@test "a selected path covers itself and what is inside it, never a neighbor or a parent" {
	local sel="$HOME/sel.txt"
	printf '%s\n' \
		"path:$HOME/Library/Caches/go-build" \
		"path:$HOME/Library/Caches/Homebrew/downloads/a b(1).tar.gz" \
		"path:$HOME/Library/Caches/日本/cache" \
		"step:npm-cache" > "$sel"
	with_clean "export MOLE_CLEAN_ONLY_FILE='$sel'
for p in '$HOME/Library/Caches/go-build' '$HOME/Library/Caches/go-build/' '$HOME/Library/Caches/go-build/x/y' \
	'$HOME/Library/Caches/Homebrew/downloads/a b(1).tar.gz' '$HOME/Library/Caches/日本/cache/z' \
	'$HOME/Library/Caches/go-buildX' '$HOME/Library/Caches' '$HOME/Library/Caches/Homebrew' \
	'$HOME/Library/Caches/Homebrew/downloads/a b(2).tar.gz' '$HOME/Library/Caches/日本' \
	'$HOME/Library/Caches/go-build/../Other'; do
	if glimwell_clean_selection_allows_path \"\$p\"; then echo \"ALLOW \$p\"; else echo \"KEEP \$p\"; fi
done
glimwell_clean_step_selected 'npm cache' && echo 'STEP npm'
glimwell_clean_step_selected 'pip cache' || echo 'NOSTEP pip'"
	local expect
	for expect in "ALLOW $HOME/Library/Caches/go-build" "ALLOW $HOME/Library/Caches/go-build/" \
		"ALLOW $HOME/Library/Caches/go-build/x/y" "ALLOW $HOME/Library/Caches/Homebrew/downloads/a b(1).tar.gz" \
		"ALLOW $HOME/Library/Caches/日本/cache/z" "KEEP $HOME/Library/Caches/go-buildX" \
		"KEEP $HOME/Library/Caches"$'\n' "KEEP $HOME/Library/Caches/Homebrew"$'\n' \
		"KEEP $HOME/Library/Caches/Homebrew/downloads/a b(2).tar.gz" "KEEP $HOME/Library/Caches/日本"$'\n' \
		"KEEP $HOME/Library/Caches/go-build/../Other" \
		"STEP npm" "NOSTEP pip"; do
		[[ "$output"$'\n' == *"$expect"* ]] || { echo "missing: $expect"; echo "$output"; return 1; }
	done
}

@test "the deletion funnel refuses an unselected path under --only, and an unreadable selection refuses all" {
	mkdir -p "$HOME/.cache/fixture-tool/picked" "$HOME/.cache/fixture-tool/left"
	echo data > "$HOME/.cache/fixture-tool/picked/f"
	echo data > "$HOME/.cache/fixture-tool/left/f"
	local sel="$HOME/sel.txt"
	printf '%s\n' "path:$HOME/.cache/fixture-tool/picked" > "$sel"
	with_clean "export MOLE_CLEAN_ONLY_FILE='$sel'
validate_path_for_deletion '$HOME/.cache/fixture-tool/picked/f' && echo PICKED_OK
validate_path_for_deletion '$HOME/.cache/fixture-tool/left/f' || echo \"LEFT_REFUSED \$_MOLE_VALIDATION_REASON\"
_MOLE_SELECTED_STEP=1 validate_path_for_deletion '$HOME/.cache/fixture-tool/left/f' && echo STEP_SCOPE_OK
export MOLE_CLEAN_ONLY_FILE='$HOME/missing.txt'
validate_path_for_deletion '$HOME/.cache/fixture-tool/picked/f' || echo UNREADABLE_REFUSED"
	[[ "$output" == *PICKED_OK* ]] || { echo "$output"; return 1; }
	[[ "$output" == *"LEFT_REFUSED not selected"* ]] || { echo "$output"; return 1; }
	[[ "$output" == *STEP_SCOPE_OK* ]] || { echo "$output"; return 1; }
	[[ "$output" == *UNREADABLE_REFUSED* ]] || { echo "$output"; return 1; }
}

@test "safe_clean under --only removes the selected target and keeps the rest, new files included" {
	local base="$HOME/.cache/fixture-tool"
	mkdir -p "$base/picked" "$base/left"
	head -c 4096 /dev/zero > "$base/picked/f"
	head -c 4096 /dev/zero > "$base/left/f"
	local sel="$HOME/sel.txt"
	printf '%s\n' "path:$base/picked" > "$sel"
	# A folder that appears after the preview is not in the selection.
	mkdir -p "$base/new"
	echo data > "$base/new/f"
	with_clean "DRY_RUN=false; files_cleaned=0; total_size_cleaned=0; total_items=0
export MOLE_CLEAN_ONLY_FILE='$sel'
safe_clean '$base'/* 'Fixture cache'
echo \"FILES=\$files_cleaned\""
	[[ "$output" == *"FILES=1"* ]] || { echo "$output"; return 1; }
	[[ ! -e "$base/picked" ]] || { echo "selected target survived"; echo "$output"; return 1; }
	[[ -f "$base/left/f" && -f "$base/new/f" ]] || { echo "an unselected target was removed"; echo "$output"; return 1; }
	# The unselected targets were never part of the run: no SKIPPED rows.
	run grep -q 'not selected' "$HOME/Library/Logs/mole/operations.log"
	[ "$status" -ne 0 ]
}

@test "safe_find_delete under --only passes over unselected matches and still succeeds" {
	local base="$HOME/.cache/fixture-logs"
	mkdir -p "$base"
	echo old > "$base/a.log"
	echo old > "$base/b.log"
	touch -t 202001010000 "$base/a.log" "$base/b.log"
	local sel="$HOME/sel.txt"
	printf '%s\n' "path:$base/a.log" > "$sel"
	with_clean "DRY_RUN=false
export MOLE_CLEAN_ONLY_FILE='$sel'
safe_find_delete '$base' '*.log' 1 f; echo \"rc=\$?\""
	[[ "$output" == *"rc=0"* ]] || { echo "$output"; return 1; }
	[[ ! -e "$base/a.log" && -f "$base/b.log" ]] || { echo "$output"; ls -la "$base"; return 1; }
}

@test "a tool step runs under --only only when its step ID was selected" {
	local marker="$HOME/ran.txt"
	local sel="$HOME/sel.txt"
	mkdir -p "$HOME/.cache/fixture-owner" "$HOME/.cache/other-owner"
	with_clean "glimwell_clean_step_id 'Fixture tool cache' '$HOME/.cache/fixture-owner' id; echo \"\$id\""
	printf '%s\n' "$output" > "$sel"
	[[ "$output" == "step:Fixture-tool-cache-"[0-9]* ]] || { echo "$output"; return 1; }
	with_clean "DRY_RUN=false
owner_cache_root_is_safe() { return 0; }
export MOLE_CLEAN_ONLY_FILE='$sel'
clean_tool_cache 'Fixture tool cache' '$HOME/.cache/fixture-owner' /bin/sh -c 'echo selected >> \"$marker\"'
clean_tool_cache 'Fixture tool cache' '$HOME/.cache/other-owner' /bin/sh -c 'echo same-tool-other-folder >> \"$marker\"'
clean_tool_cache 'Other tool cache' '$HOME/.cache/other-owner' /bin/sh -c 'echo other >> \"$marker\"'
echo done"
	[[ "$output" == *done* ]] || { echo "$output"; return 1; }
	[[ "$(cat "$marker")" == "selected" ]] || { echo "marker: $(cat "$marker" 2> /dev/null)"; echo "$output"; return 1; }
}

@test "json events quote any path and mirror removals and refusals, without SKIPPED rows for unselected items" {
	local sel="$HOME/sel.txt"
	printf '%s\n' "path:$HOME/x/y" > "$sel"
	with_clean "exec 8>&1; GLIMWELL_CLEAN_JSON=1; DRY_RUN=false
export MOLE_CLEAN_ONLY_FILE='$sel'
log_operation clean REMOVED '$HOME/x/y/a \"q\"	tab' '4KB'
log_operation clean SKIPPED '$HOME/x/y/b' 'live user cache'
log_operation clean FAILED '$HOME/x/y/c' 'removal timed out'
log_operation clean SKIPPED '$HOME/x/z' 'not selected'
glimwell_clean_json_section 'Developer tools'
glimwell_clean_json_summary complete 0 12 3 false"
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	run /usr/bin/perl -MJSON::PP -ne 'my $d = JSON::PP->new->decode($_); print "$d->{type}|", ($d->{reason} // ""), "|", ($d->{path} // $d->{name} // $d->{bytes} // ""), "\n"' <<< "$output"
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[[ "$output" == *"removed||$HOME/x/y/a \"q\""$'\t'"tab"* ]] || { echo "$output"; return 1; }
	[[ "$output" == *"kept|in_use|$HOME/x/y/b"* ]] || { echo "$output"; return 1; }
	[[ "$output" == *"kept|timeout|$HOME/x/y/c"* ]] || { echo "$output"; return 1; }
	[[ "$output" != *"$HOME/x/z"* ]] || { echo "$output"; return 1; }
	[[ "$output" == *"section||Developer tools"* ]] || { echo "$output"; return 1; }
	[[ "$output" == *"summary||12288"* ]] || { echo "$output"; return 1; }
	run grep -q "$HOME/x/z" "$HOME/Library/Logs/mole/operations.log"
	[ "$status" -ne 0 ]
}

@test "preview items carry the row name, size in bytes and the covering parent" {
	local ledger="$HOME/ledger" labels="$HOME/labels"
	printf '%s\0%s\0%s\0%s\0%s\0%s\0%s\0' \
		"id1" "8" "1" "true" "User essentials" "$HOME/Library/Caches/Homebrew/" "" \
		"id2" "4" "2" "true" "Developer tools" "$HOME/Library/Caches/Homebrew/downloads/x" "$HOME/Library/Caches/Homebrew" \
		"id3" "0" "1" "false" "Browsers" "$HOME/odd"$'\n'"name" "" > "$ledger"
	printf '%s\0%s\0' "id1" "Homebrew cache" > "$labels"
	with_clean "exec 8>&1; GLIMWELL_CLEAN_JSON=1
glimwell_clean_json_items_from_ledger '$ledger' '$labels'"
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	run /usr/bin/perl -MJSON::PP -ne 'my $d = JSON::PP->new->decode($_); print join("|", $d->{id}, $d->{label} // "null", $d->{bytes} // "null", $d->{files}, $d->{covered_by} // "null"), "\n"' <<< "$output"
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[[ "$output" == *"path:$HOME/Library/Caches/Homebrew|Homebrew cache|8192|1|null"* ]] || { echo "$output"; return 1; }
	[[ "$output" == *"path:$HOME/Library/Caches/Homebrew/downloads/x|null|4096|2|path:$HOME/Library/Caches/Homebrew"* ]] || { echo "$output"; return 1; }
	# A name holding a newline can never be removed and could not be written
	# back as one line of a selection, so it is not offered.
	[[ "$output" != *"odd"* ]] || { echo "$output"; return 1; }
}

@test "clean --only needs --json, refuses a dry run and names a bad selection" {
	local sel="$HOME/sel.txt"
	printf '%s\n' "path:$HOME/Library/Caches/a" > "$sel"
	run env HOME="$HOME" MOLE_TEST_MODE=1 MOLE_TEST_NO_AUTH=1 "$PROJECT_ROOT/mole" clean --only "$sel"
	[ "$status" -eq 1 ] && [[ "$output" == *"works only together with --json"* ]] || { echo "$output"; return 1; }
	run env HOME="$HOME" MOLE_TEST_MODE=1 MOLE_TEST_NO_AUTH=1 "$PROJECT_ROOT/mole" clean --json --dry-run --only "$sel"
	[ "$status" -eq 1 ] && [[ "$output" == *"cannot run as a dry run"* ]] || { echo "$output"; return 1; }
	printf 'nonsense\n' > "$sel"
	run env HOME="$HOME" MOLE_TEST_MODE=1 MOLE_TEST_NO_AUTH=1 "$PROJECT_ROOT/mole" clean --json --only "$sel"
	[ "$status" -eq 1 ] && [[ "$output" == *"line 1 is neither"* ]] || { echo "$output"; return 1; }
	[[ "$output" != *'"type"'* ]] || { echo "$output"; return 1; }
	run env HOME="$HOME" MOLE_TEST_MODE=1 MOLE_TEST_NO_AUTH=1 "$PROJECT_ROOT/mole" clean --json
	[ "$status" -eq 1 ] && [[ "$output" == *"removes only listed items"* ]] || { echo "$output"; return 1; }
}

@test "clean --json prints only JSON lines, from start to summary" {
	run env HOME="$HOME" MOLE_TEST_MODE=1 MOLE_TEST_NO_AUTH=1 "$PROJECT_ROOT/mole" clean --dry-run --json
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	run /usr/bin/perl -MJSON::PP -ne 'print JSON::PP->new->decode($_)->{type}, "\n"' <<< "$output"
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[[ "${lines[0]}" == "start" && "${lines[${#lines[@]} - 1]}" == "summary" ]] || { echo "$output"; return 1; }
}

@test "a stale MOLE_CLEAN_ONLY_FILE never narrows a plain clean run" {
	# shellcheck disable=SC2016  # script for the child shell
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_MODE=1 MOLE_CLEAN_ONLY_FILE="$HOME/x" \
		/bin/bash --noprofile --norc -c 'source "$PROJECT_ROOT/bin/clean.sh"; echo "only=${MOLE_CLEAN_ONLY_FILE:-unset}"'
	[[ "$output" == *"only=unset"* ]] || { echo "$output"; return 1; }
}

@test "a step scope or table entry inherited from the environment never widens a selection" {
	local sel="$HOME/sel.txt"
	printf '%s\n' "path:$HOME/Library/Caches/sel" > "$sel"
	# shellcheck disable=SC2016  # script for the child shell
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_MODE=1 MOLE_CURRENT_COMMAND=clean \
		_MOLE_SELECTED_STEP=1 _GLIMWELL_SEL_P__2fUsers=1 _GLIMWELL_SEL_S_Homebrew_2dcleanup=1 \
		/bin/bash --noprofile --norc -c '
source "$PROJECT_ROOT/bin/clean.sh"
export MOLE_CLEAN_ONLY_FILE="$1"
glimwell_clean_selection_refuses_path "$HOME/Library/Caches/other" && echo "OTHER_REFUSED"
glimwell_clean_selection_refuses_path "/Users/someone/x" && echo "USERS_REFUSED"
glimwell_clean_step_selected "Homebrew cleanup" || echo "BREW_NOT_SELECTED"' _ "$sel"
	[[ "$output" == *OTHER_REFUSED* && "$output" == *USERS_REFUSED* && "$output" == *BREW_NOT_SELECTED* ]] || { echo "$output"; return 1; }
}

@test "a selection file left in the environment does not restrict other commands" {
	mkdir -p "$HOME/.cache/fixture-tool"
	echo data > "$HOME/.cache/fixture-tool/f"
	# shellcheck disable=SC2016  # script for the child shell
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_MODE=1 MOLE_CURRENT_COMMAND=uninstall \
		MOLE_CLEAN_ONLY_FILE="$HOME/missing.txt" /bin/bash --noprofile --norc -c '
source "$PROJECT_ROOT/lib/core/common.sh"
validate_path_for_deletion "$HOME/.cache/fixture-tool/f" && echo "ALLOWED"'
	[[ "$output" == *ALLOWED* ]] || { echo "$output"; return 1; }
}

# The whole pipeline, in this test's HOME, inside a macOS sandbox profile that
# denies every write outside HOME and the temp folders (bash 3.2 writes its
# here-documents to /tmp or /var/tmp): a broken selection
# check fails this test instead of touching the host.
@test "a real --only run through every section removes only the listed item" {
	command -v sandbox-exec > /dev/null 2>&1 || skip "sandbox-exec is not available"
	set_mock_tools() {
		local bin="$HOME/tool-bin" t
		mkdir -p "$bin"
		for t in brew go xcrun docker tart gh npm pip3 uv bun pnpm conda mise nix-store corepack tmutil; do
			printf '#!/bin/bash\necho "%s $*" >> "%s/tool.log"\nexit 1\n' "$t" "$HOME" > "$bin/$t"
			chmod +x "$bin/$t"
		done
	}
	set_mock_tools
	mkdir -p "$HOME/.Trash" "$HOME/Library/Caches/com.example.left"
	head -c 5000 /dev/zero > "$HOME/.Trash/picked"
	head -c 5000 /dev/zero > "$HOME/.Trash/left"
	head -c 5000 /dev/zero > "$HOME/Library/Caches/com.example.left/data"
	local real_home real_tmp darwin_tmp
	real_home=$(cd "$HOME" && pwd -P)
	real_tmp=$(cd "${TMPDIR:-/tmp}" && pwd -P)
	darwin_tmp=$(cd "$(getconf DARWIN_USER_TEMP_DIR)" && pwd -P)
	local profile="(version 1)(allow default)(deny file-write*)(allow file-write* (subpath \"$real_home\") (subpath \"$real_tmp\") (subpath \"$darwin_tmp\") (subpath \"/private/tmp\") (subpath \"/private/var/tmp\") (subpath \"/dev\"))"
	local -a run_env=(env HOME="$HOME" TMPDIR="$real_tmp" PATH="$HOME/tool-bin:/usr/bin:/bin:/usr/sbin:/sbin" MOLE_TEST_MODE=0 MOLE_TEST_NO_AUTH=1 MOLE_LSREGISTER_PATH="")

	run sandbox-exec -p "$profile" "${run_env[@]}" "$PROJECT_ROOT/mole" clean --dry-run --json
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	local preview="$output"
	[[ "$preview" == *"\"id\":\"path:$real_home/.Trash/picked\""* || "$preview" == *"\"id\":\"path:$HOME/.Trash/picked\""* ]] || { echo "$preview"; return 1; }
	[[ "$preview" == *'"label":"Trash"'* ]] || { echo "$preview"; return 1; }
	run /usr/bin/perl -MJSON::PP -ne 'JSON::PP->new->decode($_)' <<< "$preview"
	[ "$status" -eq 0 ] || { echo "a preview line is not JSON: $output"; return 1; }

	printf '%s\n' "path:$HOME/.Trash/picked" > "$HOME/sel.txt"
	: > "$HOME/tool.log"
	run sandbox-exec -p "$profile" "${run_env[@]}" "$PROJECT_ROOT/mole" clean --json --only "$HOME/sel.txt"
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[[ "$output" == *'"type":"removed"'*'/.Trash/picked"'* ]] || { echo "$output"; return 1; }
	[[ "${lines[${#lines[@]} - 1]}" == *'"type":"summary"'*'"status":"complete"'* ]] || { echo "$output"; return 1; }
	[[ ! -e "$HOME/.Trash/picked" ]] || { echo "the listed item survived"; return 1; }
	[[ -f "$HOME/.Trash/left" && -f "$HOME/Library/Caches/com.example.left/data" ]] || { echo "an unlisted item was removed"; return 1; }
	# Only read-only probes ran: no tool cleanup was selected.
	run grep -E 'cleanup --prune=30$|^go clean|prune -f|cache clean|cache purge|cache prune|store prune|cache clear|--gc|delete' "$HOME/tool.log"
	[ "$status" -ne 0 ] || { echo "a tool cleanup ran: $output"; return 1; }
}

# Every clean step that changes the Mac outside the deletion funnel must check
# the selection itself. A new such step fails here until it does.
@test "every mutation outside the deletion funnel sits in a function that checks the selection" {
	# One row per site: file, a literal piece of the mutating line, the
	# function that holds it, and the selection check that function must call.
	# The GitHub CLI and Go commands run in bound helpers whose only callers
	# are the gated functions named here.
	local -a files=() patterns=() fns=() checks=()
	add_site() { files+=("$1"); patterns+=("$2"); fns+=("$3"); checks+=("$4"); }
	# shellcheck disable=SC2016  # Literal source text to match, not expansions.
	{
		add_site lib/clean/brew.sh 'brew cleanup --prune=30 >' clean_homebrew glimwell_clean_step_selected
		add_site lib/clean/dev.sh 'gh config clear-cache || command_status' _run_github_cli_clear_cache_bound ''
		add_site lib/clean/dev.sh '_run_github_cli_clear_cache_bound "' clean_github_cli_cache glimwell_clean_step_selected
		add_site lib/clean/dev.sh 'command_args=(env "$cache_kind=$physical_root" go clean)' _run_go_cache_clean_bound ''
		add_site lib/clean/dev.sh '    _run_go_cache_clean_bound ' clean_go_cache_root glimwell_clean_step_selected
		add_site lib/clean/dev.sh 'docker builder prune' clean_docker_unused_data glimwell_clean_step_selected
		add_site lib/clean/dev.sh 'docker image prune' clean_docker_unused_data glimwell_clean_step_selected
		add_site lib/clean/dev.sh 'delete unavailable 2>&1' clean_dev_mobile glimwell_clean_selection_refuses_path
		add_site lib/clean/dev.sh 'kill -TERM "$pid"' clean_dev_automation_browsers glimwell_clean_step_selected
		add_site lib/clean/dev.sh '"$@" > /dev/null 2>&1 || command_rc=$?' clean_tool_cache glimwell_clean_step_selected
		add_site lib/clean/user.sh 'tart prune --entries' clean_tart_caches glimwell_clean_step_selected
		add_site lib/clean/system.sh 'tmutil delete "$inprogress_file"' clean_time_machine_failed_backups glimwell_clean_selection_refuses_path
		add_site lib/clean/apps.sh 'command rmdir -- "$container_dir"' _remove_verified_container_stub ''
		add_site lib/clean/apps.sh '                _remove_verified_container_stub ' clean_orphaned_container_stubs glimwell_clean_selection_refuses_path
	}
	local i file pattern fn check count
	for ((i = 0; i < ${#files[@]}; i++)); do
		file="${files[$i]}" pattern="${patterns[$i]}" fn="${fns[$i]}" check="${checks[$i]}"
		# The function holding each match, by the last "name() {" line above it.
		# shellcheck disable=SC2016  # awk program, not shell
		# The pattern travels in the environment: awk -v would read backslashes.
		run env PAT="$pattern" /usr/bin/awk '
			/^[A-Za-z_][A-Za-z0-9_]*\(\) \{/ { name = $1; sub(/\(\)/, "", name) }
			/^[[:space:]]*#/ { next }
			index($0, ENVIRON["PAT"]) { print name }
		' "$PROJECT_ROOT/$file"
		[ "$status" -eq 0 ] || return 1
		count=$(printf '%s\n' "$output" | grep -c . || true)
		[[ "$count" -ge 1 ]] || { echo "$file: no line matches '$pattern' any more; update this table"; return 1; }
		[[ "$(printf '%s\n' "$output" | sort -u)" == "$fn" ]] || { echo "$file: '$pattern' is in: $output (expected only $fn)"; return 1; }
		if [[ -z "$check" ]]; then
			# shellcheck disable=SC2016  # awk program, not shell
			# A bound helper: every caller must be the gated function in the next row.
			run env PAT="$fn" /usr/bin/awk '
				/^[A-Za-z_][A-Za-z0-9_]*\(\) \{/ { name = $1; sub(/\(\)/, "", name); next }
				/^[[:space:]]*#/ { next }
				index($0, ENVIRON["PAT"]) { print name }
			' "$PROJECT_ROOT/$file"
			[[ "$(printf '%s\n' "$output" | sort -u)" == "${fns[$((i + 1))]}" ]] ||
				{ echo "$fn in $file is called from: $output (expected only ${fns[$((i + 1))]})"; return 1; }
			continue
		fi
		run /usr/bin/awk -v fn="$fn" '
			$0 ~ "^" fn "\\(\\) \\{" { inside = 1; next }
			inside && /^\}/ { inside = 0 }
			inside { print }
		' "$PROJECT_ROOT/$file"
		[[ "$output" == *"$check"* ]] || { echo "$fn in $file does not call $check"; return 1; }
	done

	# The gated tool steps above are the only tool commands in clean that change
	# anything; a new one must join the table.
	# Stopping Mole's own background workers ($$, a prefetch or scan pid) is not
	# a change to the Mac; a user process is always "$pid" here.
	# shellcheck disable=SC2016  # Literal regex text.
	run /usr/bin/grep -nE '((^|[^A-Za-z])brew (cleanup|autoremove)[^-.]|go clean|docker [a-z]+ prune|tart prune|simctl.*delete|tmutil delete|clear-cache[^ -]|kill -(TERM|9) "\$pid")' \
		"$PROJECT_ROOT/lib/clean/brew.sh" "$PROJECT_ROOT/lib/clean/dev.sh" "$PROJECT_ROOT/lib/clean/user.sh" \
		"$PROJECT_ROOT/lib/clean/system.sh" "$PROJECT_ROOT/lib/clean/apps.sh" "$PROJECT_ROOT/lib/clean/app_caches.sh" \
		"$PROJECT_ROOT/lib/clean/caches.sh"
	[[ -n "$output" ]] || { echo "the tool command scan matched nothing"; return 1; }
	local line text unexpected=""
	while IFS= read -r line; do
		[[ -n "$line" ]] || continue
		text="${line#*:}"
		text="${text#*:}"
		[[ "$text" =~ ^[[:space:]]*# ]] && continue
		# shellcheck disable=SC2016  # literal source text to match
		case "$line" in
			*'brew cleanup --prune=30 >'* | *'go clean)'* | *'go clean $clean_flag'* | *'docker builder prune'* | *'docker image prune'* | \
				*'tart prune --entries'* | *'delete unavailable 2>&1'* | *'tmutil delete "$inprogress_file"'* | \
				*'gh config clear-cache ||'* | *'gh config clear-cache --help'* | *'kill -TERM "$pid"'* | *'kill -9 "$pid"'* | \
				*'echo -e'* | *'debug_log'* | *'log_warning_to_file'* | *'brew autoremove --dry-run'* | *'brew cleanup --prune=30 --dry-run'*) ;;
			*) unexpected+="$line"$'\n' ;;
		esac
	done <<< "$output"
	[[ -z "$unexpected" ]] || { echo "Tool commands not covered by the selection table:"; echo "$unexpected"; return 1; }
}
