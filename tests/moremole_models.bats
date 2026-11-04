#!/usr/bin/env bats
# shellcheck disable=SC2016  # inner bash scripts expand their own arguments
# MoreMole: Ollama models (bin/moremole-models.sh). A fake helper stands in for
# moremole-models-go, and fake ollama, open and osascript commands record what
# would have run; nothing touches a real Ollama.

load helpers/common

setup_file() {
	mole_test_setup_home moremole-models
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
	KEYS_FILE="$BATS_TEST_TMPDIR/keys"
	KEY_STATE="$BATS_TEST_TMPDIR/key-state"
	mkdir -p "$ROWS_DIR"
	: > "$CALLS"
	: > "$KEY_STATE"
	export ROWS_DIR CALLS KEYS_FILE KEY_STATE

	# The helper answers from files; "size" looks names up in $ROWS_DIR/sizes.
	cat > "$BATS_TEST_TMPDIR/helper" << 'EOF'
#!/bin/bash
case "$1" in
	size)
		shift
		for name in "$@"; do
			bytes=$(awk -v n="$name" '$1 == n { print $2 }' "$ROWS_DIR/sizes" 2> /dev/null)
			if [[ -n "$bytes" ]]; then
				printf 'size\x1f%s\x1f%s\n' "$name" "$bytes"
			else
				printf 'notice\x1fnot-found\x1f%s\n' "$name"
			fi
		done
		;;
	list) [[ "${2:-}" == --check ]] && cat "$ROWS_DIR/list-check" || cat "$ROWS_DIR/list" ;;
	tags)
		shift
		printf '%s\n' "$*" >> "$ROWS_DIR/tags-asked"
		for model in "$@"; do
			awk -F $'\x1f' -v m="$model" '($1 == "tag" && index($2, m ":") == 1) || ($1 == "notice" && $3 == m)' "$ROWS_DIR/tags" 2> /dev/null
		done
		;;
	*) cat "$ROWS_DIR/$1" 2> /dev/null ;;
esac
exit 0
EOF
	chmod +x "$BATS_TEST_TMPDIR/helper"
	printf 'app=/Applications/Ollama.app\ncli=%s\nrunning=1\nmemory=17179869184\n' "$BATS_TEST_TMPDIR/fake-bin/ollama" > "$ROWS_DIR/status"
	mole_test_fake_command ollama 'printf "ollama %s\n" "$*" >> "$CALLS"
[[ "$*" != *broken* ]] || { echo "Error: model is damaged" >&2; exit 1; }'
	# Opening the app turns the service on.
	mole_test_fake_command open 'printf "open %s\n" "$*" >> "$CALLS"; sed -i.bak "s/^running=0$/running=1/" "$ROWS_DIR/status"'
	mole_test_fake_command osascript 'printf "osascript %s\n" "$*" >> "$CALLS"'
}

# Append a helper row; fields are joined with the unit separator.
row() {
	local file="$ROWS_DIR/$1"
	shift
	local IFS=$'\x1f'
	printf '%s\n' "$*" >> "$file"
}

models_env() {
	env HOME="$HOME" PATH="$PATH" MOLE_TEST_MODE=1 COLUMNS=100 \
		MOREMOLE_TEST_MODELS_HELPER="$BATS_TEST_TMPDIR/helper" \
		MOREMOLE_TEST_OPEN="$BATS_TEST_TMPDIR/fake-bin/open" \
		MOREMOLE_TEST_OSASCRIPT="$BATS_TEST_TMPDIR/fake-bin/osascript" \
		MOREMOLE_TEST_START_WAIT=1 "$@"
}

# Shell code that drives the pick lists with the keys in $KEYS_FILE and lets
# the script ask its questions without a terminal.
readonly SCRIPTED='
interactive() { return 0; }
enter_alt_screen() { :; }
leave_alt_screen() { :; }
stty() { :; }
tput() { if [[ "$1" == cols ]]; then echo 100; else echo 30; fi; }
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

installed_models() {
	row list-check model gemma3:4b 3300000000 1790848800 update 0
	row list-check model llama3.2:latest 2000000000 1788256800 current 1
	row list-check model my-assistant:latest 2000000000 1788343200 local 0
	row list-check model qwen3:8b 5200000000 1788343200 update 0
	row list model gemma3:4b 3300000000 1790848800 "" 0
	row list model llama3.2:latest 2000000000 1788256800 "" 1
	row list model qwen3:8b 5200000000 1788343200 "" 0
}

@test "models is a command with help and completion" {
	run "$PROJECT_ROOT/mole" models --help
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[[ "$output" == *"Usage: moremole models"*"--download"*"--remove"*"--dry-run"* ]] || return 1

	run /bin/bash -c 'source "$1/lib/core/commands.sh"; printf "%s\n" "${MOLE_COMMANDS[@]}"' bash "$PROJECT_ROOT"
	[[ "$output" == *$'updates:Update apps, tools and macOS\nmodels:Update, download and remove Ollama models\n'* ]]
}

@test "without Ollama it says how to get it, and runs nothing" {
	printf 'app=\ncli=\nrunning=0\nmemory=0\n' > "$ROWS_DIR/status"
	run models_env /bin/bash -c 'source "$1"; main' bash "$PROJECT_ROOT/bin/moremole-models.sh" < /dev/null
	[ "$status" -eq 1 ] || { echo "$output"; return 1; }
	[[ "$output" == *"Ollama isn't installed"*"https://ollama.com/download"*"brew install --cask ollama"* ]] || return 1
	[ ! -s "$CALLS" ]
}

@test "with Ollama off and nobody to ask, it says to open the app" {
	sed -i.bak 's/^running=1$/running=0/' "$ROWS_DIR/status"
	run models_env /bin/bash -c 'source "$1"; main --dry-run' bash "$PROJECT_ROOT/bin/moremole-models.sh" < /dev/null
	[ "$status" -eq 1 ] || { echo "$output"; return 1; }
	[[ "$output" == *"Ollama is off."*"Open the Ollama app, then run moremole models again."* ]] || return 1
	[ ! -s "$CALLS" ]
}

@test "a dry run with Ollama off leaves it off and says how to see the models" {
	sed -i.bak 's/^running=1$/running=0/' "$ROWS_DIR/status"
	installed_models
	run models_env /bin/bash -c '
		source "$1"
		eval "$2"
		printf "\n" | main --dry-run
	' bash "$PROJECT_ROOT/bin/moremole-models.sh" "$SCRIPTED"
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[[ "$output" == *"Ollama is off, and a dry run doesn't turn it on."*"Open the Ollama app"* ]] || return 1
	[[ "$output" != *"Turn Ollama on?"* ]] || return 1
	[ ! -s "$CALLS" ]
}

@test "with Ollama off it offers to turn it on, then turns it off again" {
	sed -i.bak 's/^running=1$/running=0/' "$ROWS_DIR/status"
	installed_models
	run models_env /bin/bash -c '
		source "$1"
		eval "$2"
		printf "\n" | main --remove
	' bash "$PROJECT_ROOT/bin/moremole-models.sh" "$SCRIPTED"
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[[ "$output" == *"Turn Ollama on?"*"Ollama was off, so it is off again."* ]] || return 1
	[ "$(cat "$CALLS")" = "open -g -a /Applications/Ollama.app
osascript -e quit app \"Ollama\"" ] || { cat "$CALLS"; return 1; }

	# ESC leaves it off and goes back to the menu.
	sed -i.bak 's/^running=1$/running=0/' "$ROWS_DIR/status"
	: > "$CALLS"
	run models_env MOREMOLE_CANCEL_FILE="$BATS_TEST_TMPDIR/cancelled" /bin/bash -c '
		source "$1"
		eval "$2"
		printf "\033" | main
	' bash "$PROJECT_ROOT/bin/moremole-models.sh" "$SCRIPTED"
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[ ! -s "$CALLS" ] || return 1
	[ -e "$BATS_TEST_TMPDIR/cancelled" ]
}

@test "the preview lists every model with its status and changes nothing" {
	installed_models
	run models_env /bin/bash -c 'source "$1"; main --dry-run' bash "$PROJECT_ROOT/bin/moremole-models.sh" < /dev/null
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[[ "$output" == *"DRY RUN"*"4 models"* ]] || return 1
	[[ "$output" == *"gemma3:4b"*"3.30GB · update available"* ]] || return 1
	[[ "$output" == *"llama3.2:latest"*"up to date · in use"* ]] || return 1
	[[ "$output" == *"my-assistant:latest"*"made on this Mac"* ]] || return 1
	[[ "$output" == *"Together"*"on disk"* ]] || return 1
	[ ! -s "$CALLS" ]
}

@test "models the registry couldn't be asked about are not called up to date" {
	row list-check model gemma3:4b 3300000000 1790848800 unknown 0
	row list-check model my-assistant:latest 2000000000 1788343200 local 0
	run models_env /bin/bash -c 'source "$1"; main --dry-run' bash "$PROJECT_ROOT/bin/moremole-models.sh" < /dev/null
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[[ "$output" == *"gemma3:4b"*"couldn't check"*"Couldn't check 1 of 2 models with their registry. Check the internet connection"* ]] || return 1
	[[ "$output" != *"No updates"* ]] || return 1

	# With every model checked, it says there are none.
	: > "$ROWS_DIR/list-check"
	row list-check model gemma3:4b 3300000000 1790848800 current 0
	row list-check model my-assistant:latest 2000000000 1788343200 local 0
	run models_env /bin/bash -c 'source "$1"; main --dry-run' bash "$PROJECT_ROOT/bin/moremole-models.sh" < /dev/null
	[[ "$output" == *"No updates: every model the registry knows is up to date"* ]] || return 1
	[[ "$output" != *"Couldn't check"* ]]
}

@test "updating offers only models with an update, nothing selected, and pulls the picked ones" {
	installed_models
	# The list holds gemma3 and qwen3; pick the second.
	printf '%s\n' DOWN SPACE ENTER > "$KEYS_FILE"
	run models_env /bin/bash -c '
		source "$1"
		eval "$2"
		printf "\n" | main
	' bash "$PROJECT_ROOT/bin/moremole-models.sh" "$SCRIPTED"
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[[ "$output" == *"Models to update:"*"qwen3:8b"*"Update 1 models"* ]] || return 1
	[[ "$output" == *"Models updated"*"Updated"*"1"* ]] || return 1
	[ "$(cat "$CALLS")" = "ollama pull qwen3:8b" ] || { cat "$CALLS"; return 1; }
	grep -q "REBUILT qwen3:8b (updated)" "$HOME/Library/Logs/mole/operations.log"
}

@test "removing picks from every model, stops one in use, and frees only what was removed" {
	row list-check model broken:1b 1000000000 1788343200 current 0
	installed_models
	# A-Z, as Ollama lists them: broken, gemma3, llama3.2 (in use), qwen3.
	# Pick broken and llama3.2.
	printf '%s\n' SPACE DOWN DOWN SPACE ENTER > "$KEYS_FILE"
	run models_env /bin/bash -c '
		source "$1"
		eval "$2"
		printf "\n" | main --remove
	' bash "$PROJECT_ROOT/bin/moremole-models.sh" "$SCRIPTED"
	[ "$status" -eq 1 ] || { echo "$output"; return 1; }
	[[ "$output" == *"Models to remove:"*"broken:1b"*"llama3.2:latest"*"Frees up to 3.00GB"*"do not go to the Trash. You can download them again."*"A model in use is unloaded first"* ]] || return 1
	[[ "$output" != *"may not download again"* ]] || return 1
	[[ "$output" == *"Some models did not finish"*"Removed"*"1"*"Not done: broken:1b: model is damaged"*"Freed up to 2.00GB"* ]] || return 1
	[ "$(cat "$CALLS")" = "ollama rm broken:1b
ollama stop llama3.2:latest
ollama rm llama3.2:latest" ] || { cat "$CALLS"; return 1; }
	grep -q "REMOVED llama3.2:latest (removed with ollama rm)" "$HOME/Library/Logs/mole/operations.log" || return 1
	grep -q "FAILED broken:1b (model is damaged)" "$HOME/Library/Logs/mole/operations.log"
}

@test "removing a model made on this Mac warns it may not download again" {
	installed_models
	# A-Z: gemma3, llama3.2, my-assistant (made on this Mac), qwen3; pick my-assistant.
	printf '%s\n' DOWN DOWN SPACE ENTER > "$KEYS_FILE"
	run models_env /bin/bash -c '
		source "$1"
		eval "$2"
		printf "\033" | main --remove
	' bash "$PROJECT_ROOT/bin/moremole-models.sh" "$SCRIPTED"
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[[ "$output" == *"my-assistant:latest"*"do not go to the Trash."*"may not download again: my-assistant:latest"* ]] || return 1
	[[ "$output" != *"You can download them again"* ]] || return 1
	[ ! -s "$CALLS" ]
}

@test "Enter with nothing selected removes no model" {
	installed_models
	printf '%s\n' ENTER ENTER > "$KEYS_FILE"
	run models_env /bin/bash -c '
		source "$1"
		eval "$2"
		printf "\n" | main --remove
	' bash "$PROJECT_ROOT/bin/moremole-models.sh" "$SCRIPTED"
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[[ "$output" != *"Models to remove:"* ]] || return 1
	[ ! -s "$CALLS" ]
}

@test "a dry run with no library to show downloads nothing and asks nothing" {
	row library notice library-failed "Couldn't read Ollama's model list at ollama.com/library (HTTP 503)."
	printf 'gemma3:4b 3300000000\n' > "$ROWS_DIR/sizes"
	run models_env /bin/bash -c '
		source "$1"
		eval "$2"
		printf "gemma3:4b\n\n" | main --download --dry-run
	' bash "$PROJECT_ROOT/bin/moremole-models.sh" "$SCRIPTED"
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[[ "$output" == *"nothing was downloaded"* ]] || return 1
	[[ "$output" != *"Model to download"* && "$output" != *"Models downloaded"* ]] || return 1
	[ ! -s "$CALLS" ]
}

library_models() {
	row library model gemma3 "vision" 30.1M 1790000000 1 "1b,4b,27b" "Gemma 3 from Google."
	row library model llama3.1 "tools" 120.6M 1733006040 0 "8b,70b,405b" "Llama 3.1 from Meta."
}

@test "downloading picks models, then their versions, with size, fit, context, input and MLX" {
	library_models
	printf 'mlx=1\n' >> "$ROWS_DIR/status"
	row tags tag gemma3:27b 17000000000 17GB 128K "Text, Image" 0 0 0
	row tags tag gemma3:4b 3300000000 3.3GB 128K "Text, Image" 0 1 1
	row tags tag gemma3:4b-mlx 3500000000 3.5GB 128K "Text, Image" 1 0 0
	row tags tag llama3.1:405b 243000000000 243GB 128K Text 0 0 0
	printf 'gemma3:27b 17000000000\ngemma3:4b-mlx 3500000000\nllama3.1:405b 243000000000\n' > "$ROWS_DIR/sizes"
	# Models A-Z: gemma3, llama3.1; pick both. Versions smallest first:
	# gemma3:4b, gemma3:4b-mlx, gemma3:27b, llama3.1:405b; pick the last three.
	printf '%s\n' SPACE DOWN SPACE ENTER DOWN SPACE DOWN SPACE DOWN SPACE ENTER > "$KEYS_FILE"
	run models_env /bin/bash -c '
		source "$1"
		eval "$2"
		printf "\n" | main --download
	' bash "$PROJECT_ROOT/bin/moremole-models.sh" "$SCRIPTED"
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[ "$(cat "$ROWS_DIR/tags-asked")" = "gemma3 llama3.1" ] || return 1
	[[ "$output" == *"Select models, then choose their versions"* ]] || return 1
	[[ "$output" == *"gemma3"*"vision"*"1b–27b"*"30.1M pulls"*"installed"* ]] || return 1
	[[ "$output" == *"Select versions: size, fit in memory, context, input, MLX for Apple silicon"* ]] || return 1
	[[ "$output" == *"gemma3:4b "*"3.3GB"*"fits"*"128K"*"Text, Image"*"default, installed"* ]] || return 1
	[[ "$output" == *"gemma3:4b-mlx"*"3.5GB"*"fits"*"MLX"* ]] || return 1
	[[ "$output" == *"llama3.1:405b"*"243GB"*"too big"* ]] || return 1
	[[ "$output" == *"Models to download:"*"gemma3:27b"*"17.00GB · too big for 17.18GB memory"*"gemma3:4b-mlx"*"3.50GB · fits"*"llama3.1:405b"*"243.00GB · too big"* ]] || return 1
	[[ "$output" == *"Downloads up to 263.50GB"*"Models downloaded"*"Downloaded"*"3"* ]] || return 1
	[ "$(cat "$CALLS")" = "ollama pull gemma3:27b
ollama pull gemma3:4b-mlx
ollama pull llama3.1:405b" ] || { cat "$CALLS"; return 1; }
}

@test "an Intel Mac's version list doesn't mention MLX, and cancelling it downloads nothing" {
	library_models
	row tags tag gemma3:4b 3300000000 3.3GB 128K "Text, Image" 0 1 0
	printf '%s\n' SPACE ENTER QUIT > "$KEYS_FILE"
	run models_env /bin/bash -c '
		source "$1"
		eval "$2"
		main --download
	' bash "$PROJECT_ROOT/bin/moremole-models.sh" "$SCRIPTED"
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[[ "$output" == *"Select versions: size, fit in memory, context, input"* ]] || return 1
	[[ "$output" != *"MLX"* ]] || return 1
	[ ! -s "$CALLS" ]
}

@test "a model whose versions can't be read still offers its sizes" {
	library_models
	row tags notice tags-failed llama3.1
	printf 'llama3.1:70b 43000000000\n' > "$ROWS_DIR/sizes"
	# Pick llama3.1; its versions are 8b, 70b, 405b with no sizes, A-Z
	# within equal sizes: pick 70b.
	printf '%s\n' DOWN SPACE ENTER DOWN SPACE ENTER > "$KEYS_FILE"
	run models_env /bin/bash -c '
		source "$1"
		eval "$2"
		printf "\n" | main --download
	' bash "$PROJECT_ROOT/bin/moremole-models.sh" "$SCRIPTED"
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[[ "$output" == *"Couldn't read the versions of llama3.1 at ollama.com/library/llama3.1/tags, so its sizes are listed without details."* ]] || return 1
	[[ "$output" == *"llama3.1:8b"*"llama3.1:70b"*"llama3.1:405b"* ]] || return 1
	[ "$(cat "$CALLS")" = "ollama pull llama3.1:70b" ] || { cat "$CALLS"; return 1; }
}

@test "when the library page can't be read, a typed name is checked before downloading" {
	row library notice library-failed "Couldn't read Ollama's model list at ollama.com/library (HTTP 503)."
	printf 'gemma3:4b 3300000000\n' > "$ROWS_DIR/sizes"
	run models_env /bin/bash -c '
		source "$1"
		eval "$2"
		printf "gemma3:4b\n\n" | main --download
	' bash "$PROJECT_ROOT/bin/moremole-models.sh" "$SCRIPTED"
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[[ "$output" == *"Couldn't read Ollama's model list"*"gemma3:4b"*"3.30GB · fits in 17.18GB memory"* ]] || return 1
	[ "$(cat "$CALLS")" = "ollama pull gemma3:4b" ] || { cat "$CALLS"; return 1; }

	# A name the registry doesn't have downloads nothing.
	: > "$CALLS"
	run models_env /bin/bash -c '
		source "$1"
		eval "$2"
		printf "gemma9:1b\n" | main --download
	' bash "$PROJECT_ROOT/bin/moremole-models.sh" "$SCRIPTED"
	[[ "$output" == *"gemma9:1b isn't in Ollama's registry"* ]] || return 1
	[ ! -s "$CALLS" ]
}
