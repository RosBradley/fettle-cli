#!/bin/bash
# Fettle: fork-only commands for help and completions, listed after slim.
# lib/core/commands.sh sources this after defining MOLE_COMMANDS.

_fettle_commands=()
for _fettle_entry in "${MOLE_COMMANDS[@]}"; do
    # remove only explains how to remove Fettle (lib/fettle/menu.sh).
    [[ "$_fettle_entry" == remove:* ]] && _fettle_entry="remove:Show how to remove Fettle"
    _fettle_commands+=("$_fettle_entry")
    [[ "$_fettle_entry" == slim:* ]] && _fettle_commands+=("updates:Update apps, tools, macOS and Ollama models" "models:Update, download and remove Ollama models")
done
MOLE_COMMANDS=("${_fettle_commands[@]}")
unset _fettle_commands _fettle_entry
