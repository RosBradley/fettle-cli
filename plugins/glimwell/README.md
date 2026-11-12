# Glimwell agent skill

This plugin installs the skill for the free, open-source Glimwell CLI (`glimwell`) on macOS. With it, Claude Code and Codex answer "what is using my disk?" from Glimwell's own JSON output, show every cleanup with `--dry-run` and wait for your consent before anything is removed, and leave app uninstalls, update installs and administrator steps for you to run in your own terminal.

Install it in Claude Code with `/plugin marketplace add RosBradley/glimwell-cli`, then `/plugin install glimwell@glimwell`; in Codex with `codex plugin marketplace add RosBradley/glimwell-cli`, then `codex plugin add glimwell@glimwell`.

The skill needs the Glimwell CLI on the Mac: `curl -fsSL https://raw.githubusercontent.com/RosBradley/glimwell-cli/glimwell/glimwell-get.sh | bash`. Source and license (GPL-3.0) are at https://github.com/RosBradley/glimwell-cli.

`skills/glimwell` here is a copy of `skills/glimwell` at the repository root, since Codex drops symbolic links when it installs a plugin.
