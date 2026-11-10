---
name: fettle
description: "Drive the Fettle CLI (`fettle`) on macOS: find what uses disk space, preview and run cleanup, uninstall apps, check for software and Ollama model updates, and read system health and cleanup history. Use before running any `fettle` command. Not for editing Fettle source code."
when_to_use: "磁盘满了, 空间不够, 清理磁盘, 清理缓存, 卸载应用, 电脑很卡, 什么占了空间, ディスク容量, 디스크 정리, disk full, free up space, clean my Mac, uninstall an app, what is using my disk, computer is slow, update my apps, did Fettle delete, Fettle"
---

# Fettle

Fettle (`fettle`, or `ft` for short) is a maintenance CLI for macOS. It deletes
real files on the user's own Mac. Your job is to read the machine, show the
user exactly what would change, and hand them the decision. Done means the
user's question is answered from Fettle's own output, and nothing was removed
that the user had not seen and approved.

## 1. Check the install

Run `fettle --version`. Its first line names the Fettle release or commit.
Then use only the commands in [references/macos.md](references/macos.md). If a
flag is rejected, run `fettle <command> --help` and trust it over this skill.

If `fettle` is not found, say so and offer the install line from the
reference. Install only after the user agrees.

## 2. Rules

1. **Read before you change.** Answer with the read-only commands first:
   `analyze --json`, `status --json`, `history --json`, `uninstall --list`, and
   every `--dry-run`. They are safe to run without asking.
2. **Preview before every removal.** Run the command with `--dry-run`, read
   the result, and summarize it for the user: total size, the largest groups,
   and for each group whether it is gone for good, goes to the Trash, or needs
   a download to rebuild. A preview is a snapshot; the real run rescans, so do
   not promise an exact number.
3. **Get consent before you type a removing command.** Without a terminal,
   `fettle clean` and `fettle optimize` do not ask for confirmation: they start
   as soon as they are invoked. The consent therefore has to come first, in
   this conversation, after the user has seen the preview. "Why is my disk
   full" is a question, not consent; "go ahead and clean those" after the
   preview is. Consent covers what the preview showed. If the user wants only
   part of it, protect the rest first or hand the interactive command to the
   user.
4. **Some steps belong to the user's terminal.** App uninstall, installing
   updates, interactive selection lists, whitelist editors, and anything that
   needs an administrator password cannot be completed from an agent. Give the
   user the exact command to run in their own terminal and stop. Never run
   `sudo`, ask for a password, or try to elevate.
5. **Use only the surfaces in the reference.** Never parse a full-screen
   screen, never invent a flag such as `--yes` or `--force` where the reference
   does not list it, and never fall back to `rm` or `find -delete` to remove
   what Fettle skipped or protected. A skip is Fettle's answer.
6. **Leave Fettle itself alone.** Do not run `fettle update` or
   `fettle remove` unless the user asked for that command.
7. **Stay out of the user's files.** What you read can leave the machine with
   this conversation. Answer from Fettle's output and logs. Do not list
   personal folders, run `find` or `mdfind` over them, or repeat file names
   from documents and photos unless the user asked you to look there. Report
   folders and sizes rather than the names inside them, and never rerun
   `fettle` with a different `HOME`.

## 3. If your shell is sandboxed

Many agent hosts deny writes outside the workspace. Fettle writes under the
home folder, and removing a file counts as a write, so a sandbox changes what
its output means. The signs are `Operation not permitted` or `No such file or
directory` on `clean-list.txt` or `operations.log`, `audit log unavailable`,
`Unable to create a safe cleanup preview file`, and `top_processes: null` with
`fork/exec /bin/ps: operation not permitted`.

- A failed preview is the sandbox, not an empty result and not a Fettle bug.
  Say so.
- **Never run a removing command inside the sandbox.** `fettle clean` can print
  `Cleanup complete` and exit 0 with nothing removed, because a denied delete
  reads as nothing to clean.
- Ask for wider access through the host's approval flow, for the exact command
  and with the reason, only if the host offers one. Otherwise give the user the
  command for their own terminal and stop. Rule 3 still applies either way.
- `status`, `analyze`, `history` and `uninstall --list` still read inside a
  sandbox. Without `top_processes`, say which process is using the CPU is
  unknown and hand the user `fettle status`.

## 4. Which command answers which question

| The user asks | Read first | Then |
|---|---|---|
| "What is using my disk?" | `fettle analyze --json`, then `fettle analyze --json <path>` on the largest entries | Map each large entry to the command below that handles it; say plainly when none does (documents, media, VMs) |
| "Free up space" | `fettle clean --dry-run` and its path list | After consent, `fettle clean` |
| "Remove this app" | `fettle uninstall --list` | Per reference; the final uninstall runs in the user's terminal |
| "Clean old projects" | `fettle purge --dry-run` | Per reference |
| "Update my apps" | `fettle updates --dry-run` | The user picks and installs with `fettle updates` in their terminal |
| "Update my AI models" | `fettle models --dry-run` | The user picks with `fettle models` in their terminal |
| "My computer is slow" | `fettle status --json`, plus a short `--watch` sample if one snapshot is not enough | Name the process or resource; offer `fettle optimize --dry-run` only when maintenance fits the finding |
| "Did Fettle delete my file?" | `fettle history --json --limit 200` | Match the path and anything under it, then offer to protect it. If the oldest entry returned is newer than the date in question, read the log file named in `logs`. No match means Fettle has no record of it, not that Fettle did not touch it. Stop there: do not search other logs, the Trash or the user's folders |
| "Keep this folder" | The whitelist section of the reference | Never a hand-made exclusion |

When explaining a disk analysis, map what you found: cache directories
(`cleanable: true`), logs and leftovers of deleted apps go to `clean`; build
output and dependency folders inside projects go to `purge`; installed apps go
to `uninstall`; installer files go to `installer`. Documents, photos, media
libraries, virtual machines and device backups are the user's data: report
their size and location and let the user decide, since no Fettle command
removes them.

## 5. Where your judgment adds to Fettle

Fettle's rules decide what is safe to remove. They cannot tell what is worth
removing for this user today. That part is yours, and it only ever narrows: you
may rank, explain, warn and advise keeping something, but never add a path, a
wider scope or a command Fettle did not offer.

- **Start from the goal.** Find out what the user needs: a number ("30 GB for
  the macOS update"), or a reason. If `status` shows plenty of free space, say
  that cleaning is not needed before offering it. Given a number, propose the
  smallest set of steps that reaches it and stop there.
- **Rank by regret, not by size.** First what costs nothing: logs and caches
  that rebuild offline. Then what needs a download: dependencies, model and
  container caches. Last what the user might miss. A large cache that takes a
  day to download again can rank below a smaller pile of logs.
- **Say what a thing is.** Fettle gives paths and sizes. You can often name the
  tool behind a folder and what it holds. Mark that as your reading rather than
  Fettle's finding, say "unknown" instead of guessing, and never treat a name
  as proof that something is safe to remove. Whether Fettle covers it comes
  from a preview, not from reading Fettle's source.
- **Read the preview against this conversation.** Point out items the user
  would care about even though Fettle calls them safe: the project they
  mentioned, a tool that is running, a cache that is costly on their network,
  anything in the Trash. Offer the whitelist before the run.
- **Do not add up what overlaps.** `analyze` sizes nest and include things no
  command removes. Only a preview total answers "how much can I free".
- **Explain a slow machine.** Compare two or three samples to separate a spike
  from sustained load. Consider known background work such as indexing, backups
  or thermal throttling before blaming an app, and call a cause likely, not
  certain, unless the samples show it.
- **Name the other route.** For what no Fettle command handles, such as Xcode
  archives, container images or a photo library, say which app's own setting or
  command manages it. That is the user's decision in the user's terminal, and
  never a `rm` command from you.

## 6. Reporting

- Lead with the conclusion, then what you recommend and why, in a few rows.
  Keep what Fettle measured apart from what you inferred.

- Quote sizes and counts from Fettle's output, not from your own `du`, and
  keep Fettle's partial or unavailable markers: a partial scan is a lower
  bound, not a total.
- After a real run, read the command's summary and `fettle history --json
  --limit 1`, report what was removed and what failed or was skipped. Do not
  run the command again to retry what Fettle skipped; a skip is deliberate.
- When something the user cares about appears in a preview, say so before the
  run and offer the whitelist, instead of hoping it is not removed.
