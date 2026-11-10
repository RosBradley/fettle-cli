# Fettle agent skill

This plugin installs the skill for the free, open-source Fettle CLI (`fettle`) on macOS. With it, Claude Code and Codex answer "what is using my disk?" from Fettle's own JSON output, show every cleanup with `--dry-run` and wait for your consent before anything is removed, and leave app uninstalls, update installs and administrator steps for you to run in your own terminal.

Install it in Claude Code with `/plugin marketplace add RosBradley/fettle-cli`, then `/plugin install fettle@fettle`; in Codex with `codex plugin marketplace add RosBradley/fettle-cli`, then `codex plugin add fettle@fettle`.

The skill needs the Fettle CLI on the Mac: `curl -fsSL https://raw.githubusercontent.com/RosBradley/fettle-cli/fettle/fettle-get.sh | bash`. Source and license (GPL-3.0) are at https://github.com/RosBradley/fettle-cli.

`skills/fettle` here is a copy of `skills/fettle` at the repository root, since Codex drops symbolic links when it installs a plugin.
