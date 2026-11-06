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
	rm -rf "$HOME/Library/Logs/mole" "$HOME/Library/Caches/moremole" "$HOME/.config/mole/moremole-hf-models" # SAFE: test-owned HOME under tests/tmp-*
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
	hf-files)
		shift
		for repo in "$@"; do
			awk -F $'\x1f' -v r="$repo" '$2 == r' "$ROWS_DIR/hf-files" 2> /dev/null
		done
		;;
	hf-download)
		printf 'hf-download %s\n' "${*:2}" >> "$CALLS"
		if [[ "$2" == *broken* ]]; then
			mkdir -p "$4" && printf 'part' > "$4/model.safetensors.part"
			echo "Error: model.safetensors: HTTP 503" >&2
			exit 1
		fi
		mkdir -p "$4" && printf 'FROM .\n' > "$4/Modelfile"
		echo "downloaded 5 GB in 3 files"
		;;
	hf-verify)
		printf 'hf-verify %s\n' "$2" >> "$CALLS"
		if [[ "$2" == *nochat* ]]; then
			printf 'notice\x1fverify-failed\x1fits family has no chat template in Ollama, so Ollama couldn'"'"'t chat with it\n'
		else
			printf 'verified\x1f%s\n' "$2"
		fi
		;;
	*) cat "$ROWS_DIR/$1" 2> /dev/null ;;
esac
exit 0
EOF
	chmod +x "$BATS_TEST_TMPDIR/helper"
	printf 'app=/Applications/Ollama.app\ncli=%s\nrunning=1\nmemory=17179869184\n' "$BATS_TEST_TMPDIR/fake-bin/ollama" > "$ROWS_DIR/status"
	mole_test_fake_command ollama 'printf "ollama %s\n" "$*" >> "$CALLS"
[[ "$1" != create || -f Modelfile ]] || { echo "Error: no Modelfile in $PWD" >&2; exit 1; }
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
	[[ "$output" == *$'updates:Update apps, tools, macOS and Ollama models\nmodels:Update, download and remove Ollama models\n'* ]]
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
	[[ "$output" == *"update      gemma3:4b"*"3.30GB"* ]] || return 1
	[[ "$output" == *"up to date  llama3.2:latest"*"2.00GB · in use"* ]] || return 1
	[[ "$output" == *"made here   my-assistant:latest"* ]] || return 1
	[[ "$output" == *"Together"*"on disk"* ]] || return 1
	[ ! -s "$CALLS" ]
}

@test "models the registry couldn't be asked about are not called up to date" {
	row list-check model gemma3:4b 3300000000 1790848800 unknown 0
	row list-check model my-assistant:latest 2000000000 1788343200 local 0
	run models_env /bin/bash -c 'source "$1"; main --dry-run' bash "$PROJECT_ROOT/bin/moremole-models.sh" < /dev/null
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[[ "$output" == *"unchecked   gemma3:4b"*"Couldn't check 1 of 2 models with their registry. Check the internet connection"* ]] || return 1
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
	printf '%s\n' DOWN SPACE CHAR:d > "$KEYS_FILE"
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
	printf '%s\n' SPACE DOWN DOWN SPACE CHAR:d > "$KEYS_FILE"
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
	printf '%s\n' DOWN DOWN SPACE CHAR:d > "$KEYS_FILE"
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

@test "saving with nothing selected removes no model" {
	installed_models
	printf '%s\n' CHAR:d > "$KEYS_FILE"
	run models_env /bin/bash -c '
		source "$1"
		eval "$2"
		printf "\n" | main --remove
	' bash "$PROJECT_ROOT/bin/moremole-models.sh" "$SCRIPTED"
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[[ "$output" != *"Models to remove:"* ]] || return 1
	[ ! -s "$CALLS" ]
}

@test "Enter shows a model's details, where Space selects it, and status comes first" {
	installed_models
	# A-Z: gemma3, llama3.2, my-assistant, qwen3. Open llama3.2's details and
	# select it there; the arrows go on to qwen3's and back to my-assistant's,
	# where the list's cursor then is: select it there too and save.
	printf '%s\n' DOWN ENTER SPACE DOWN DOWN UP QUIT SPACE CHAR:d > "$KEYS_FILE"
	run models_env /bin/bash -c '
		source "$1"
		eval "$2"
		printf "\033" | main --remove
	' bash "$PROJECT_ROOT/bin/moremole-models.sh" "$SCRIPTED"
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[[ "$output" == *"up to date  llama3.2:latest"*"2.00GB · in use"* ]] || return 1
	[[ "$output" == *"Enter Details"*"D Remove"* ]] || return 1
	[[ "$output" == *"Not selected"*"llama3.2:latest"*"Status"*"up to date"*"Size on disk"*"2.00GB"*"In use"*"yes, loaded in memory now"*"Page"*"https://ollama.com/library/llama3.2"*"Space Select"*"Enter Back"* ]] || return 1
	[[ "$output" == *"2 of 4 · ● Selected"*"llama3.2:latest"*"3 of 4"*"my-assistant:latest"*"4 of 4"*"qwen3:8b"*"3 of 4"*"my-assistant:latest"* ]] || return 1
	[[ "$output" == *"Previous, next"* ]] || return 1
	[[ "$output" == *"Models to remove:"*"llama3.2:latest"*"my-assistant:latest"* ]] || return 1
	[ ! -s "$CALLS" ]
}

@test "a Hugging Face model's details say how big it is, whether it fits, and its name in Ollama" {
	hf_models
	printf '%s\n' ENTER QUIT QUIT > "$KEYS_FILE"
	run models_env /bin/bash -c '
		source "$1"
		eval "$2"
		main --huggingface
	' bash "$PROJECT_ROOT/bin/moremole-models.sh" "$SCRIPTED"
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[[ "$output" == *"mlx-community/Qwen3.5-9B-4bit"*"Family"*"Qwen 3.5"*"Quantization"*"4-bit"*"Size"*"5.95GB in 10 files"*"Memory"*"fits in 17.18GB memory"*"Downloads"*"719843 in the last month"*"Published"*"2 March 2026"*"Updated"*"In Ollama as"*"hf.co/mlx-community/qwen3.5-9b-4bit"*"https://huggingface.co/mlx-community/Qwen3.5-9B-4bit"* ]] || return 1
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
	row library model gemma3 "vision" 30.1M 1790000000 1 "1b,4b,27b" 1 "Gemma 3 from Google."
	row library model llama3.1 "tools" 120.6M 1733006040 0 "8b,70b,405b" 0 "Llama 3.1 from Meta."
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
	printf '%s\n' SPACE DOWN SPACE CHAR:d DOWN SPACE DOWN SPACE DOWN SPACE CHAR:d > "$KEYS_FILE"
	run models_env /bin/bash -c '
		source "$1"
		eval "$2"
		printf "\n" | main --download
	' bash "$PROJECT_ROOT/bin/moremole-models.sh" "$SCRIPTED"
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[ "$(cat "$ROWS_DIR/tags-asked")" = "gemma3 llama3.1" ] || return 1
	[[ "$output" == *"Select models, then choose their versions; MLX: it has versions for Apple silicon"* ]] || return 1
	[[ "$output" == *"Status     MLX  Name"*"Can do"*"Sizes"*"Pulls  Updated"* ]] || return 1
	[[ "$output" == *"installed  MLX  gemma3"*"vision"*"1b–27b"*"30.1M  2026-09-21"* ]] || return 1
	[[ "$output" == *"Status     Memory   Version"*"Size"*"Context"*"Input"*"MLX"* ]] || return 1
	[[ "$output" == *"Select versions to download; MLX: runs on Apple silicon"* ]] || return 1
	[[ "$output" == *"installed  fits     gemma3:4b "*"3.3GB"*"128K"*"Text, Image"* ]] || return 1
	[[ "$output" == *"fits     gemma3:4b-mlx"*"3.5GB"*"MLX"* ]] || return 1
	[[ "$output" == *"too big  llama3.1:405b"*"243GB"* ]] || return 1
	[[ "$output" == *"Models to download:"*"gemma3:27b"*"17.00GB · too big for 17.18GB memory"*"gemma3:4b-mlx"*"3.50GB · fits"*"llama3.1:405b"*"243.00GB · too big"* ]] || return 1
	[[ "$output" == *"D Next"*"D Download"* ]] || return 1
	[[ "$output" == *"gemma3:27b"*"1 of 3"*"gemma3:4b-mlx"*"2 of 3"*"llama3.1:405b"*"3 of 3"* ]] || return 1
	[[ "$output" == *"Downloads up to 263.50GB"*"Models downloaded"*"Downloaded"*"3"* ]] || return 1
	[ "$(cat "$CALLS")" = "ollama pull gemma3:27b
ollama pull gemma3:4b-mlx
ollama pull llama3.1:405b" ] || { cat "$CALLS"; return 1; }
}

@test "/mlx in the library finds only the models with MLX versions" {
	library_models
	printf 'mlx=1\n' >> "$ROWS_DIR/status"
	row tags tag gemma3:4b-mlx 3500000000 3.5GB 128K "Text, Image" 1 0 0
	printf '%s\n' CHAR:/ CHAR:m CHAR:l CHAR:x ENTER SPACE CHAR:d QUIT > "$KEYS_FILE"
	run models_env /bin/bash -c '
		source "$1"
		eval "$2"
		main --download
	' bash "$PROJECT_ROOT/bin/moremole-models.sh" "$SCRIPTED"
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[ "$(cat "$ROWS_DIR/tags-asked")" = "gemma3" ] || { cat "$ROWS_DIR/tags-asked"; return 1; }
	[ ! -s "$CALLS" ]
}

@test "an Intel Mac's version list doesn't mention MLX, and cancelling it downloads nothing" {
	library_models
	row tags tag gemma3:4b 3300000000 3.3GB 128K "Text, Image" 0 1 0
	printf '%s\n' SPACE CHAR:d QUIT > "$KEYS_FILE"
	run models_env /bin/bash -c '
		source "$1"
		eval "$2"
		main --download
	' bash "$PROJECT_ROOT/bin/moremole-models.sh" "$SCRIPTED"
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[[ "$output" == *"Select versions to download"* ]] || return 1
	[[ "$output" != *"MLX"* ]] || return 1
	[ ! -s "$CALLS" ]
}

@test "a model whose versions can't be read still offers its sizes" {
	library_models
	row tags notice tags-failed llama3.1
	printf 'llama3.1:70b 43000000000\n' > "$ROWS_DIR/sizes"
	# Pick llama3.1; its versions are 8b, 70b, 405b with no sizes, A-Z
	# within equal sizes: pick 70b.
	printf '%s\n' DOWN SPACE CHAR:d DOWN SPACE CHAR:d > "$KEYS_FILE"
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

readonly HF_SHA=0123456789abcdef0123456789abcdef01234567
readonly HF_NEW=fedcba9876543210fedcba9876543210fedcba98

hf_models() {
	printf 'mlx=1\n' >> "$ROWS_DIR/status"
	row hf-list hf mlx-community/Qwen3.5-9B-4bit qwen3_5 4-bit 5950000000 719843 1790000000 0 "Text, Image" 1772409600
	row hf-list hf someone/Gemma-4-nochat-bf16 gemma4 bf16 2000000000 10 1780000000 0 Text
	row hf-files files mlx-community/Qwen3.5-9B-4bit "$HF_SHA" 5950062560 10 hf.co/mlx-community/qwen3.5-9b-4bit
	row hf-files files someone/Gemma-4-nochat-bf16 "$HF_SHA" 2000000000 6 hf.co/someone/gemma-4-nochat-bf16
}

@test "a search can hold a slash, as in owner/model" {
	hf_models
	# Typing someone/ narrows the list to someone's model; Enter finishes.
	printf '%s\n' CHAR:/ CHAR:s CHAR:o CHAR:m CHAR:e CHAR:o CHAR:n CHAR:e CHAR:/ CHAR:g ENTER SPACE CHAR:d > "$KEYS_FILE"
	run models_env /bin/bash -c '
		source "$1"
		eval "$2"
		printf "\033" | main --huggingface
	' bash "$PROJECT_ROOT/bin/moremole-models.sh" "$SCRIPTED"
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[[ "$output" == *"Search: someone/g"*"(1/2"* ]] || return 1
	[[ "$output" == *"Models to add from Hugging Face:"*"someone/Gemma-4-nochat-bf16"* ]] || return 1
}

@test "S sorts Hugging Face models by downloads and the library by pulls" {
	hf_models
	# A-Z, then S for size, date and downloads, most first: Qwen (719,843),
	# then Gemma (10). O flips it, so the first row is Gemma.
	printf '%s\n' CHAR:s CHAR:s CHAR:s CHAR:o SPACE CHAR:d > "$KEYS_FILE"
	run models_env /bin/bash -c '
		source "$1"
		eval "$2"
		printf "\033" | main --huggingface
	' bash "$PROJECT_ROOT/bin/moremole-models.sh" "$SCRIPTED"
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[[ "$output" == *"S Downloads"* ]] || return 1
	[[ "$output" == *"Models to add from Hugging Face:"*"someone/Gemma-4-nochat-bf16"* ]] || return 1
	[[ "$output" != *"Models to add from Hugging Face:"*"mlx-community/Qwen3.5-9B-4bit "*"· as"* ]] || return 1

	# The library: A-Z, then S for date and pulls, most first: llama3.1
	# (120.6M) before gemma3 (30.1M).
	library_models
	: > "$KEY_STATE"
	printf '%s\n' CHAR:s CHAR:s SPACE CHAR:d QUIT > "$KEYS_FILE"
	run models_env /bin/bash -c '
		source "$1"
		eval "$2"
		main --download
	' bash "$PROJECT_ROOT/bin/moremole-models.sh" "$SCRIPTED"
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[[ "$output" == *"S Pulls"* ]] || return 1
	[ "$(cat "$ROWS_DIR/tags-asked")" = "llama3.1" ] || { cat "$ROWS_DIR/tags-asked"; return 1; }
}

@test "adding from Hugging Face downloads, adds, starts and only then names each model" {
	hf_models
	# A-Z: mlx-community/..., someone/...; pick both, then confirm.
	printf '%s\n' SPACE DOWN SPACE CHAR:d > "$KEYS_FILE"
	run models_env /bin/bash -c '
		source "$1"
		eval "$2"
		printf "\n" | main --huggingface
	' bash "$PROJECT_ROOT/bin/moremole-models.sh" "$SCRIPTED"
	[ "$status" -eq 1 ] || { echo "$output"; return 1; }
	[[ "$output" == *"Select MLX models from Hugging Face"* ]] || return 1
	# Rows are cut to the terminal's 100 columns; the details show the rest.
	[[ "$output" == *"Status   Name"*"Bits"*"Size"*"Can do"*"Downloads  Published"* ]] || return 1
	[[ "$output" == *"fits     mlx-community/Qwen3.5-9B-4bit"*"4-bit"*"~5.95GB"*"vision"*"719.8K  2026-03-02"* ]] || return 1
	[[ "$output" == *"Models to add from Hugging Face:"*"mlx-community/Qwen3.5-9B-4bit "*"5.95GB · fits in 17.18GB memory · as hf.co/mlx-community/qwen3.5-9b-4bit"* ]] || return 1
	[[ "$output" == *"it needs twice its size free"*"started once to check that it works"* ]] || return 1
	[[ "$output" == *"Added as hf.co/mlx-community/qwen3.5-9b-4bit:latest, and it works"* ]] || return 1
	[[ "$output" == *"Some models did not finish"*"Added"*"1"*"Not done: hf.co/someone/gemma-4-nochat-bf16:latest: it was removed again because its family has no chat template in Ollama"* ]] || return 1
	local staging="$HOME/Library/Caches/moremole/models/hf"
	[ "$(cat "$CALLS")" = "hf-download mlx-community/Qwen3.5-9B-4bit $HF_SHA $staging/mlx-community--Qwen3.5-9B-4bit
ollama create hf.co/mlx-community/qwen3.5-9b-4bit-moremole-check
hf-verify hf.co/mlx-community/qwen3.5-9b-4bit-moremole-check
ollama cp hf.co/mlx-community/qwen3.5-9b-4bit-moremole-check hf.co/mlx-community/qwen3.5-9b-4bit:latest
ollama rm hf.co/mlx-community/qwen3.5-9b-4bit-moremole-check
hf-download someone/Gemma-4-nochat-bf16 $HF_SHA $staging/someone--Gemma-4-nochat-bf16
ollama create hf.co/someone/gemma-4-nochat-bf16-moremole-check
hf-verify hf.co/someone/gemma-4-nochat-bf16-moremole-check
ollama rm hf.co/someone/gemma-4-nochat-bf16-moremole-check" ] || { cat "$CALLS"; return 1; }
	# The downloads are deleted once Ollama has them; only the working one
	# is recorded.
	[ -z "$(ls -A "$staging")" ] || { ls -la "$staging"; return 1; }
	[ "$(cat "$HOME/.config/mole/moremole-hf-models")" = "hf.co/mlx-community/qwen3.5-9b-4bit:latest"$'\t'"mlx-community/Qwen3.5-9B-4bit"$'\t'"$HF_SHA" ] || return 1
	local log="$HOME/Library/Logs/mole/operations.log"
	grep -q "REBUILT hf.co/mlx-community/qwen3.5-9b-4bit:latest (added from Hugging Face mlx-community/Qwen3.5-9B-4bit at 0123456)" "$log" || return 1
	grep -q "FAILED hf.co/someone/gemma-4-nochat-bf16:latest (it was removed again because its family has no chat template" "$log"
}

@test "a Hugging Face download that stops keeps its part to continue, and adds nothing" {
	printf 'mlx=1\n' >> "$ROWS_DIR/status"
	row hf-list hf me/broken-4bit qwen3_5 4-bit 1000000 5 1780000000 0 Text
	row hf-files files me/broken-4bit "$HF_SHA" 1000000 3 hf.co/me/broken-4bit
	printf '%s\n' SPACE CHAR:d > "$KEYS_FILE"
	run models_env /bin/bash -c '
		source "$1"
		eval "$2"
		printf "\n" | main --huggingface
	' bash "$PROJECT_ROOT/bin/moremole-models.sh" "$SCRIPTED"
	[ "$status" -eq 1 ] || { echo "$output"; return 1; }
	local part="$HOME/Library/Caches/moremole/models/hf/me--broken-4bit"
	[[ "$output" == *"Not done: hf.co/me/broken-4bit:latest: model.safetensors: HTTP 503"* ]] || return 1
	[[ "$output" == *"The downloaded part is kept in $part, so trying again continues"* ]] || return 1
	[ -f "$part/model.safetensors.part" ] || return 1
	[[ "$(cat "$CALLS")" != *"ollama create"* ]] || return 1
	[ ! -e "$HOME/.config/mole/moremole-hf-models" ]
}

@test "the Hugging Face preview lists without downloading, and an Intel Mac is told MLX needs Apple silicon" {
	hf_models
	run models_env /bin/bash -c 'source "$1"; main --huggingface --dry-run' bash "$PROJECT_ROOT/bin/moremole-models.sh" < /dev/null
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[[ "$output" == *"2 MLX models on Hugging Face that Ollama runs"*"mlx-community/Qwen3.5-9B-4bit"*"someone/Gemma-4-nochat-bf16"*"Sizes are estimates until you pick a model."* ]] || return 1
	[ ! -s "$CALLS" ] || return 1

	sed -i.bak '/^mlx=1$/d' "$ROWS_DIR/status"
	run models_env /bin/bash -c 'source "$1"; main --huggingface' bash "$PROJECT_ROOT/bin/moremole-models.sh" < /dev/null
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[[ "$output" == *"MLX models need a Mac with Apple silicon; this Mac has an Intel chip."* ]] || return 1
	[ ! -s "$CALLS" ]
}

@test "a model added from Hugging Face updates from there, and removing it drops its record" {
	mkdir -p "$HOME/.config/mole"
	printf 'hf.co/me/m-4bit:latest\tme/M-4bit\t%s\nother:latest\tme/Other\t%s\n' "$HF_SHA" "$HF_SHA" > "$HOME/.config/mole/moremole-hf-models"
	row list-check model gemma3:4b 3300000000 1790848800 update 0 ""
	row list-check model hf.co/me/m-4bit:latest 5000000000 1790848800 update 0 me/M-4bit
	row hf-files files me/M-4bit "$HF_NEW" 5100000000 3 hf.co/me/m-4bit
	printf 'mlx=1\n' >> "$ROWS_DIR/status"
	printf '%s\n' SPACE DOWN SPACE CHAR:d > "$KEYS_FILE"
	run models_env /bin/bash -c '
		source "$1"
		eval "$2"
		printf "\n" | main
	' bash "$PROJECT_ROOT/bin/moremole-models.sh" "$SCRIPTED"
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[[ "$output" == *"update      hf.co/me/m-4bit:latest"*"from Hugging Face"* ]] || return 1
	[[ "$output" == *"Models to update:"*"gemma3:4b"*"hf.co/me/m-4bit:latest "*"from Hugging Face"* ]] || return 1
	[[ "$output" == *"Ollama downloads only the parts that changed."*"Models from Hugging Face download again in full, and replace the old version only once the new one starts."* ]] || return 1
	[[ "$(cat "$CALLS")" == "ollama pull gemma3:4b
hf-download me/M-4bit $HF_NEW "*"/me--M-4bit
ollama create hf.co/me/m-4bit-moremole-check
hf-verify hf.co/me/m-4bit-moremole-check
ollama cp hf.co/me/m-4bit-moremole-check hf.co/me/m-4bit:latest
ollama rm hf.co/me/m-4bit-moremole-check" ]] || { cat "$CALLS"; return 1; }
	[ "$(cat "$HOME/.config/mole/moremole-hf-models")" = "other:latest"$'\t'"me/Other"$'\t'"$HF_SHA"$'\n'"hf.co/me/m-4bit:latest"$'\t'"me/M-4bit"$'\t'"$HF_NEW" ] || { cat "$HOME/.config/mole/moremole-hf-models"; return 1; }

	: > "$CALLS"
	: > "$KEY_STATE"
	printf '%s\n' DOWN SPACE CHAR:d > "$KEYS_FILE"
	run models_env /bin/bash -c '
		source "$1"
		eval "$2"
		printf "\n" | main --remove
	' bash "$PROJECT_ROOT/bin/moremole-models.sh" "$SCRIPTED"
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[[ "$output" == *"You can download them again."* ]] || return 1
	[ "$(cat "$CALLS")" = "ollama rm hf.co/me/m-4bit:latest" ] || { cat "$CALLS"; return 1; }
	[ "$(cat "$HOME/.config/mole/moremole-hf-models")" = "other:latest"$'\t'"me/Other"$'\t'"$HF_SHA" ]
}

@test "Software updates' model updates turn Ollama on without asking, update each, and hand back the results" {
	sed -i.bak 's/^running=1$/running=0/' "$ROWS_DIR/status"
	mkdir -p "$HOME/.config/mole"
	printf 'hf.co/me/m-4bit:latest\tme/M-4bit\t%s\n' "$HF_SHA" > "$HOME/.config/mole/moremole-hf-models"
	row hf-files files me/M-4bit "$HF_NEW" 5100000000 3 hf.co/me/m-4bit
	local results="$BATS_TEST_TMPDIR/results"
	# Nothing to read: it never asks.
	run models_env MOREMOLE_MODELS_RESULTS="$results" MOLE_CURRENT_COMMAND=updates /bin/bash -c '
		source "$1"
		main --install-updates gemma3:4b broken:latest hf.co/me/m-4bit:latest < /dev/null
	' bash "$PROJECT_ROOT/bin/moremole-models.sh"
	[ "$status" -eq 1 ] || { echo "$output"; return 1; }
	[[ "$output" != *"Turn Ollama on?"* ]] || return 1
	[[ "$output" == *"turning it on for the model updates"* ]] || return 1
	[[ "$output" == *"gemma3:4b"*"1 of 3"* ]] || return 1
	[[ "$(cat "$CALLS")" == "open -g -a /Applications/Ollama.app
ollama pull gemma3:4b
ollama pull broken:latest
hf-download me/M-4bit $HF_NEW "*"
ollama cp hf.co/me/m-4bit-moremole-check hf.co/me/m-4bit:latest
ollama rm hf.co/me/m-4bit-moremole-check
osascript -e quit app \"Ollama\"" ]] || { cat "$CALLS"; return 1; }
	[ "$(cat "$results")" = "done	2
failed	broken:latest: model is damaged
note	Ollama was off, so it is off again" ] || { cat "$results"; return 1; }
	local log="$HOME/Library/Logs/mole/operations.log"
	grep -q "\[updates\] REBUILT gemma3:4b (updated)" "$log" || { cat "$log"; return 1; }
	grep -q "\[updates\] FAILED broken:latest" "$log" || return 1
	grep -q "\[updates\] REBUILT hf.co/me/m-4bit:latest (updated from Hugging Face me/M-4bit" "$log"
}
