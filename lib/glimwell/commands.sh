#!/bin/bash
# Glimwell: fork-only commands for help and completions, listed after slim.
# lib/core/commands.sh sources this after defining MOLE_COMMANDS.

_glimwell_commands=()
for _glimwell_entry in "${MOLE_COMMANDS[@]}"; do
    # remove only explains how to remove Glimwell (lib/glimwell/menu.sh).
    [[ "$_glimwell_entry" == remove:* ]] && _glimwell_entry="remove:Show how to remove Glimwell"
    _glimwell_commands+=("$_glimwell_entry")
    [[ "$_glimwell_entry" == slim:* ]] && _glimwell_commands+=("updates:Update apps, tools, macOS and Ollama models" "models:Update, download and remove Ollama models")
done
MOLE_COMMANDS=("${_glimwell_commands[@]}")
unset _glimwell_commands _glimwell_entry
