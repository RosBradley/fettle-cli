# Fettle CLI (macOS)

Written against the November 2026 Fettle releases. An older copy may lack a
flag or field below; check `fettle <command> --help` first.

## Install

Show the user this line and let them paste it into Terminal; do not pipe a
download into a shell yourself:

```bash
curl -fsSL https://raw.githubusercontent.com/RosBradley/fettle-cli/fettle/fettle-get.sh | bash
```

It installs in the home folder, needs no password, and adds the `fettle` and
`ft` commands. Details: https://github.com/RosBradley/fettle-cli

Run Fettle as the normal user, never with `sudo fettle …`: it refuses a root
invocation and asks for administrator access itself when a step needs it.

## Commands

| Command | Without a terminal (how an agent runs it) | Who runs the real thing |
|---|---|---|
| `fettle analyze --json [path]` | Read-only JSON | Agent |
| `fettle status --json` / `fettle status --watch --interval 1s` | Read-only JSON / NDJSON | Agent |
| `fettle history --json --limit N` | Read-only JSON, N is 1-200 | Agent |
| `fettle uninstall --list` | Read-only JSON app inventory | Agent |
| `fettle clean --dry-run` | Preview, writes the path list | Agent |
| `fettle clean` | **Starts immediately, no confirmation.** User-level cleanup runs; system-level cleanup runs only if a sudo session is already cached, otherwise it is skipped and the output says so | Agent after consent, or the user for a full run including system caches |
| `fettle optimize --dry-run` | Preview of maintenance tasks | Agent |
| `fettle optimize` | **Starts immediately, no confirmation.** Tasks that need admin access are skipped without a cached sudo session | Agent after consent, or the user |
| `fettle purge --dry-run` | Preview of project artifacts | Agent |
| `fettle purge --yes` | Removes every eligible candidate unattended; without `--yes` a non-terminal run refuses | Agent only after consent to that exact candidate list |
| `fettle uninstall --dry-run <name>` | Prints the removal plan and ends with "Dry run complete" and exit 0; nothing is removed | Agent |
| `fettle uninstall <name>` | Refuses without a terminal | User |
| `fettle installer --dry-run` | Preview of `.dmg`, `.pkg`, `.iso`, `.xip`, `.zip` installers | Agent |
| `fettle installer` | Selection list, needs a terminal | User |
| `fettle slim --dry-run` | Lists universal apps and the Intel code that could be removed | Agent |
| `fettle slim` | Without a terminal it only lists apps | User |
| `fettle clean --whitelist`, `fettle optimize --whitelist`, `fettle purge --paths` | Interactive editors | User |
| `fettle clean --external <volume>` | Removes `.DS_Store`, AppleDouble `._*` files and `.TemporaryItems` from a mounted external volume, never its Trash; preview with `--dry-run` | Agent after consent |
| `fettle updates --dry-run` | Lists available updates for Homebrew apps and tools, App Store apps, macOS, apps with their own updater, and Ollama models | Agent |
| `fettle updates` | Selection list, needs a terminal; nothing starts selected | User |
| `fettle models --dry-run` | Lists the user's Ollama models and their updates; add `--download`, `--huggingface` or `--remove` to preview those lists | Agent |
| `fettle models` | Selection lists, need a terminal | User |

`fettle uninstall` takes the `uninstall_name` from `--list`, several at once
(`fettle uninstall slack zoom`). `--with-data` starts with personal data selected;
by default it is kept. `--permanent` skips the Trash; never suggest it unless
the user asks to bypass the Trash.

System-level cleanup and some optimize tasks need administrator access. The
agent cannot provide it. When the preview says system caches need sudo, ask
the user to choose before running anything: either they run `fettle clean` (or
`fettle optimize`) in their own terminal, where Fettle asks for the password and
covers both levels in one run, or you run the user-level part now and the
system part is left out. Do not do both; the second run would rescan and
repeat the user-level work. The agent never runs `sudo`.

`fettle purge` has no path argument. `fettle purge --help` prints the roots it scans;
the user changes them with `fettle purge --paths`. `--yes` takes every eligible
artifact the preview listed, except those with file activity in the last 7
days or activity Fettle could not verify, and skips cloud-synced folders. When
the user wants only some projects, hand them `fettle purge`, whose selection list
lets them pick.

For `fettle uninstall`, "remove it completely" is a question about personal data:
by default settings and app data are kept, and `--with-data` starts with them
selected. Show the user the "Personal data kept" list from the dry run and let
them choose. The plan marks apps that are running; ask the user to quit them
first.

## What a removal can be undone

- `fettle clean`, `fettle purge`, `fettle installer` and `fettle optimize` delete permanently.
  There is no undo, which is why the preview matters.
- `fettle uninstall` moves the app and its leftovers to the Trash, unless
  `--permanent` was passed. `fettle slim` moves the original app to the Trash after
  the slimmed copy passes code signing and Gatekeeper checks; an app update
  brings the Intel code back.
- `fettle purge` removes two kinds of directories: build output (`target/`,
  `build/`, `dist/`, `.next/`) that a rebuild recreates offline, and
  dependency folders (`node_modules/`, `Pods/`, `venv/`, `vendor/`) that need a
  download to restore. Say which kind the candidates are. Folders with authored
  content are protected, and a probe that cannot decide keeps the candidate.
- `fettle clean` empties `~/.Trash` by default unless the Trash row is protected in
  `fettle clean --whitelist`. Mention this in every clean preview; users often keep
  things in the Trash on purpose.

## JSON surfaces

**`fettle analyze --json [path]`.** One object: `scan_status`, `path`, `overview`,
`total_size`, `total_files`, `large_files[]` of `{name, path, size}`, and
`entries[]` of `{scan_status, name, path, size, is_dir, insight, cleanable,
last_access}`. Sizes are bytes. `scan_status` is `complete`, `partial` or
`unavailable`; a `partial` size is a lower bound and an `unavailable` one is
unknown, not zero. Without a path it measures the overview locations; `insight:
true` marks a known heavy location such as an iOS backup. `cleanable: true`
means a directory Fettle recognizes as a cache. Put `--json` before the path: the
flag parser stops at the first positional argument.

**`fettle status --json`.** One snapshot with `health_score`, `health_score_msg`,
`cpu`, `memory` (including `pressure`), `disks[]`, `disk_io`, `network[]`,
`batteries[]`, `thermal`, `top_processes[]`, `trash_size`, `zombie_count` and
`zombie_parents[]`, plus host and hardware fields. It also switches to JSON when
stdout is not a terminal, but pass `--json` anyway. `--watch` prints one object
per line; bound it (for example `fettle status --watch --interval 1s | head -n 10`;
macOS has no `timeout` command by default) and never leave it running.

**`fettle history --json --limit N`.** `logs` (paths of the operations and
deletions logs), `limit`, `sessions[]` of `{command, run_id, attribution,
started_at, ended_at, items, size, operation_count, failed_tasks, actions}`
where `actions` counts removed, trashed, skipped, failed, rebuilt and other,
and `deletions[]` of `{timestamp, mode, status, size_kb, path}`. `mode` is
`permanent` or `trash`. `status` is `ok` for a completed removal and `dry-run`
for a preview; any other value is the reason Fettle refused or failed, and the
path was not removed. Fettle may log a folder or only files inside it, so match
the path as a prefix. A preview
session is named `<command>-dry-run`. `attribution: ambiguous` means older
markers cannot assign the counts to one run. Control bytes in paths appear as
`\n`, `\r`, `\t` or `\xHH`. For entries older than the limit, read the
deletions log named in `logs` (one tab-separated line per deletion).

**`fettle uninstall --list`.** When stdout is not a terminal it prints a JSON array
of `{name, bundle_id, source, uninstall_name, path, size}`. `source` is `App`
or `Homebrew`; `size` is a display string such as `968.3MB`. Pass
`uninstall_name` to `fettle uninstall`.

**`fettle clean --dry-run` path list.** The summary goes to the terminal and every
candidate path goes to `~/.config/mole/clean-list.txt`. Read that file to see
what was found. It is a snapshot, not a plan: the real run rescans. Only
`clean` writes it; `purge`, `installer` and `optimize` previews print to the
terminal.

## Protecting a path

`~/.config/mole/whitelist` holds clean protections, one path per line (`~`
and `$HOME` are expanded, `#` starts a comment, a line with `..` is rejected),
and
`~/.config/mole/whitelist_optimize` holds optimize protections. When the file
already exists, append the path after the user agrees. When it does not exist,
do not create it: an existing file replaces Fettle's optional default
protections. Ask the user to run `fettle clean --whitelist` and press Enter once to
save the defaults, then append; if the file still does not exist afterwards,
stop and say so. Confirm the protection with a fresh `fettle clean --dry-run`: the
path should no longer be in `clean-list.txt`. If the whitelist cannot be read,
`clean`, `purge` and `optimize` stop instead of running without it.

## Gotchas

- `--debug` prints the detailed operation log. Use it when a command silently
  did nothing, not by default.
- `fettle clean` also removes leftovers of apps that are already gone. It never
  touches installed apps; that is `fettle uninstall`.
- A routine skip or timeout of a single item is not reported in the summary.
  It is in `--debug` output and the operations log; do not retry it by hand.
- `fettle update` installs the newest Fettle release. Run it only when the user
  asks.
