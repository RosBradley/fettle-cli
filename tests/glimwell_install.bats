#!/usr/bin/env bats
# glimwell: scripts/glimwell-install.sh sets up the glimwell and gw commands.

load helpers/common

setup_file() {
	mole_test_setup_home "glimwell-install"
}

teardown_file() {
	mole_test_teardown_home
}

# A fake glimwell folder holding the installer, already built, and a brew
# stub that reports whether Mole is installed ($BREW_HAS_MOLE) and logs calls.
setup() {
	rm -rf "${HOME:?}/home" "${HOME:?}/repo" "${HOME:?}/stubs" # SAFE: test-owned mktemp HOME under tests/tmp-*
	FAKE_HOME="$HOME/home"
	REPO="$HOME/repo"
	STUBS="$HOME/stubs"
	mkdir -p "$FAKE_HOME" "$REPO/scripts" "$REPO/lib/glimwell" "$REPO/bin" "$STUBS"
	cp "$PROJECT_ROOT/scripts/glimwell-install.sh" "$REPO/scripts/"
	printf '#!/bin/bash\necho GLIMWELL\n' > "$REPO/mole"
	: > "$REPO/lib/glimwell/menu.sh"
	cp "$PROJECT_ROOT/lib/glimwell/migrate.sh" "$REPO/lib/glimwell/"
	printf '#!/bin/bash\n' > "$REPO/bin/analyze-go"
	printf '#!/bin/bash\n' > "$REPO/bin/status-go"
	chmod +x "$REPO/mole" "$REPO/bin/analyze-go" "$REPO/bin/status-go"
	cat > "$STUBS/brew" << 'EOF'
#!/bin/bash
echo "brew $*" >> "$BREW_LOG"
if [[ "$1" == "list" ]]; then
    [[ "${BREW_HAS_MOLE:-0}" == "1" ]]
fi
EOF
	chmod +x "$STUBS/brew"
	BREW_LOG="$HOME/brew.log"
	rm -f "$BREW_LOG"
	export FAKE_HOME REPO STUBS BREW_LOG
}

install() {
	env HOME="$FAKE_HOME" PATH="$STUBS:/usr/bin:/bin" BREW_LOG="$BREW_LOG" \
		BREW_HAS_MOLE="${BREW_HAS_MOLE:-0}" /bin/bash "$REPO/scripts/glimwell-install.sh" < /dev/null
}

@test "installer links glimwell and gw to the folder and adds PATH once" {
	run install
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[ "$(readlink "$FAKE_HOME/.local/bin/glimwell")" = "$REPO/mole" ] || return 1
	[ "$(readlink "$FAKE_HOME/.local/bin/gw")" = "$REPO/mole" ] || return 1
	[ "$("$FAKE_HOME/.local/bin/gw")" = "GLIMWELL" ] || return 1
	[[ "$output" == *"Open a new Terminal window"* ]] || return 1
	[[ "$output" == *"To set up Tab completion for glimwell and gw, run: glimwell completion"* ]] || return 1

	run install
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	# shellcheck disable=SC2016  # Literal ~/.zshrc text, not an expansion.
	[ "$(grep -c 'export PATH="$HOME/.local/bin:$PATH"' "$FAKE_HOME/.zshrc")" -eq 1 ]
}

@test "installer replaces the old mm alias and keeps every other line" {
	# shellcheck disable=SC2016  # Literal ~/.zshrc text, not an expansion.
	printf '# mine\nalias ll="ls -l"\nalias mm="$HOME/Developer/moremole/mole"\nexport EDITOR=vim\n' > "$FAKE_HOME/.zshrc"
	run install
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[[ "$output" == *'Removed the old "alias mm=" line'* ]] || return 1
	! grep -q 'alias mm=' "$FAKE_HOME/.zshrc" || return 1
	[[ "$(cat "$FAKE_HOME/.zshrc")" == $'# mine\nalias ll="ls -l"\nexport EDITOR=vim\n\n# glimwell'* ]]
}

@test "installer never replaces a real file where a link would go" {
	mkdir -p "$FAKE_HOME/.local/bin"
	printf 'mine\n' > "$FAKE_HOME/.local/bin/gw"
	run install
	[ "$status" -ne 0 ] || return 1
	[[ "$output" == *"already exists and is not a link"* ]] || return 1
	[ "$(cat "$FAKE_HOME/.local/bin/gw")" = "mine" ]
}

@test "installer never takes over a link that isn't Glimwell's" {
	mkdir -p "$FAKE_HOME/.local/bin" "$HOME/other"
	printf '#!/bin/bash\necho OTHER\n' > "$HOME/other/gw"
	ln -s "$HOME/other/gw" "$FAKE_HOME/.local/bin/gw"
	run install
	[ "$status" -ne 0 ] || return 1
	[[ "$output" == *"already links to $HOME/other/gw, which isn't Glimwell"* ]] || return 1
	[ "$(readlink "$FAKE_HOME/.local/bin/gw")" = "$HOME/other/gw" ]
}

@test "installer moves a link from an earlier Glimwell folder to this one" {
	mkdir -p "$FAKE_HOME/.local/bin" "$HOME/old-copy/lib/glimwell"
	: > "$HOME/old-copy/lib/glimwell/menu.sh"
	ln -s "$HOME/old-copy/mole" "$FAKE_HOME/.local/bin/gw"
	run install
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[ "$(readlink "$FAKE_HOME/.local/bin/gw")" = "$REPO/mole" ]
}

@test "installer removes MoreMole's moremole and mm links and keeps anyone else's" {
	mkdir -p "$FAKE_HOME/.local/bin" "$HOME/old-moremole/lib/moremole" "$HOME/other"
	: > "$HOME/old-moremole/lib/moremole/menu.sh"
	ln -s "$HOME/old-moremole/mole" "$FAKE_HOME/.local/bin/moremole"
	printf '#!/bin/bash\necho OTHER\n' > "$HOME/other/mm"
	ln -s "$HOME/other/mm" "$FAKE_HOME/.local/bin/mm"
	run install
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[[ "$output" == *"Removed $FAKE_HOME/.local/bin/moremole, MoreMole's old name for it."* ]] || return 1
	[ ! -e "$FAKE_HOME/.local/bin/moremole" ] && [ ! -L "$FAKE_HOME/.local/bin/moremole" ] || return 1
	[ "$(readlink "$FAKE_HOME/.local/bin/mm")" = "$HOME/other/mm" ]
}

@test "installer moves MoreMole's Hugging Face record and cache, never over Glimwell's" {
	mkdir -p "$FAKE_HOME/.config/mole" "$FAKE_HOME/Library/Caches/moremole/models" "$FAKE_HOME/Library/Caches/glimwell"
	printf 'hf.co/me/a:latest\tme/A\n' > "$FAKE_HOME/.config/mole/moremole-hf-models"
	printf 'old\n' > "$FAKE_HOME/Library/Caches/moremole/models/tags.json"
	run install
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[ "$(cat "$FAKE_HOME/.config/mole/glimwell-hf-models")" = $'hf.co/me/a:latest\tme/A' ] || return 1
	[ ! -e "$FAKE_HOME/.config/mole/moremole-hf-models" ] || return 1
	# Glimwell's cache was already there, so MoreMole's stays where it is.
	[ "$(cat "$FAKE_HOME/Library/Caches/moremole/models/tags.json")" = "old" ] || return 1
	[ ! -e "$FAKE_HOME/Library/Caches/glimwell/models" ]
}

@test "the move of MoreMole's state waits in a dry run" {
	mkdir -p "$FAKE_HOME/.config/mole"
	printf 'record\n' > "$FAKE_HOME/.config/mole/moremole-hf-models"
	# shellcheck disable=SC2016  # $1 expands in the inner shell.
	run env HOME="$FAKE_HOME" MOLE_DRY_RUN=1 /bin/bash -c 'source "$1"; glimwell_migrate_state' _ "$PROJECT_ROOT/lib/glimwell/migrate.sh"
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[ -f "$FAKE_HOME/.config/mole/moremole-hf-models" ] && [ ! -e "$FAKE_HOME/.config/mole/glimwell-hf-models" ] || return 1
	# shellcheck disable=SC2016  # $1 expands in the inner shell.
	run env HOME="$FAKE_HOME" /bin/bash -c 'source "$1"; glimwell_migrate_state' _ "$PROJECT_ROOT/lib/glimwell/migrate.sh"
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[ "$(cat "$FAKE_HOME/.config/mole/glimwell-hf-models")" = "record" ]
}

@test "installer keeps the PATH line MoreMole added instead of adding another" {
	# shellcheck disable=SC2016  # Literal ~/.zshrc text, not an expansion.
	printf '\n# moremole: commands in ~/.local/bin\nexport PATH="$HOME/.local/bin:$PATH"\n' > "$FAKE_HOME/.zshrc"
	run install
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[ "$(grep -c 'local/bin:' "$FAKE_HOME/.zshrc")" -eq 1 ] || return 1
	run grep -qF '# glimwell: commands' "$FAKE_HOME/.zshrc"
	[ "$status" -eq 1 ]
}

@test "installer logs each change it makes in operations.log" {
	mkdir -p "$REPO/lib/core"
	cp "$PROJECT_ROOT/lib/core/base.sh" "$PROJECT_ROOT/lib/core/log.sh" "$REPO/lib/core/"
	# shellcheck disable=SC2016  # Literal ~/.zshrc text, not an expansion.
	printf 'alias mm="$HOME/moremole/mole"\n' > "$FAKE_HOME/.zshrc"
	run install
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	local log="$FAKE_HOME/Library/Logs/mole/operations.log"
	grep -qF "[install] REBUILT $FAKE_HOME/.local/bin/glimwell (links to $REPO/mole)" "$log" || { cat "$log"; return 1; }
	grep -qF "[install] REBUILT $FAKE_HOME/.local/bin/gw (links to $REPO/mole)" "$log" || return 1
	grep -qF "[install] REBUILT $FAKE_HOME/.zshrc (added ~/.local/bin to PATH)" "$log" || return 1
	grep -qF "[install] REMOVED $FAKE_HOME/.zshrc (old alias mm= line)" "$log" || return 1

	# Running it again changes nothing, so it logs nothing new.
	local before
	before=$(grep -c '\[install\] ' "$log")
	run install
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[ "$(grep -c '\[install\] ' "$log")" -eq "$before" ]
}

@test "installer only suggests removing a Homebrew Mole without a terminal" {
	BREW_HAS_MOLE=1 run install
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[[ "$output" == *"installed with Homebrew"*"To remove it, run: brew uninstall mole"* ]] || return 1
	! grep -q "uninstall" "$BREW_LOG" || return 1
	# A kept Homebrew Mole is not reported a second time as some other install.
	[[ "$output" != *"not installed with Homebrew"* ]]
}

@test "installer warns that mo remove would trash the settings of another Mole" {
	printf '#!/bin/bash\n' > "$STUBS/mo"
	chmod +x "$STUBS/mo"
	run install
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[[ "$output" == *"Another Mole is still installed: $STUBS/mo"* ]] || return 1
	[[ "$output" == *'Do not remove it with "mo remove"'* ]]
}

@test "installer removes the mo and mole links Glimwell made and keeps anyone else's" {
	mkdir -p "$FAKE_HOME/.local/bin" "$HOME/old-glimwell/lib/glimwell" "$REPO/lib/core"
	cp "$PROJECT_ROOT/lib/core/base.sh" "$PROJECT_ROOT/lib/core/log.sh" "$REPO/lib/core/"
	: > "$HOME/old-glimwell/lib/glimwell/menu.sh"
	ln -s "$REPO/mole" "$FAKE_HOME/.local/bin/mo"
	ln -s "$HOME/old-glimwell/mole" "$FAKE_HOME/.local/bin/mole"
	run install
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[ ! -e "$FAKE_HOME/.local/bin/mo" ] && [ ! -L "$FAKE_HOME/.local/bin/mo" ] || return 1
	[ ! -e "$FAKE_HOME/.local/bin/mole" ] && [ ! -L "$FAKE_HOME/.local/bin/mole" ] || return 1
	[[ "$output" == *"Removed $FAKE_HOME/.local/bin/mo: Glimwell answers to glimwell and gw."* ]] || return 1
	[[ "$output" == *"Removed $FAKE_HOME/.local/bin/mole: Glimwell answers to glimwell and gw."* ]] || return 1
	grep -qF "[install] REMOVED $FAKE_HOME/.local/bin/mo (Mole's name for the command, which Glimwell no longer uses)" \
		"$FAKE_HOME/Library/Logs/mole/operations.log" || return 1

	# An official Mole's links are never touched, and Glimwell makes no new ones.
	rm -f "$FAKE_HOME/.local/bin/glimwell" "$FAKE_HOME/.local/bin/gw" # SAFE: links in the test-owned fake HOME
	ln -s /opt/mole/mole "$FAKE_HOME/.local/bin/mole"
	run install
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[ "$(readlink "$FAKE_HOME/.local/bin/mole")" = "/opt/mole/mole" ] || return 1
	[ ! -e "$FAKE_HOME/.local/bin/mo" ] && [ ! -L "$FAKE_HOME/.local/bin/mo" ] || return 1
	[[ "$output" != *"Removed $FAKE_HOME/.local/bin/mole"* ]]
}
