#!/bin/bash
# MoreMole: fork-only commands for help and completions, listed after slim.
# lib/core/commands.sh sources this after defining MOLE_COMMANDS.

_moremole_commands=()
for _moremole_entry in "${MOLE_COMMANDS[@]}"; do
    # remove only explains how to remove MoreMole (lib/moremole/menu.sh).
    [[ "$_moremole_entry" == remove:* ]] && _moremole_entry="remove:Show how to remove MoreMole"
    _moremole_commands+=("$_moremole_entry")
    [[ "$_moremole_entry" == slim:* ]] && _moremole_commands+=("updates:Update apps, tools, macOS and Ollama models" "models:Update, download and remove Ollama models")
done
MOLE_COMMANDS=("${_moremole_commands[@]}")
unset _moremole_commands _moremole_entry
