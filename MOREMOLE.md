# moremole

moremole is a personal fork of [Mole](https://github.com/tw93/Mole) by tw93, modified since October 2026. Mole and moremole are licensed under GPL-3.0 (see `LICENSE`); moremole is not affiliated with or endorsed by the Mole project. It keeps everything Mole does and changes these things:

- **The banner says MoreMole** and points to this repository, on the menu and the help screen. Its tagline keeps Mole's line, "Deep clean and optimize your Mac.", and adds "Manage, update and remove apps." The version screen (V) credits Mole and shows the moremole commit that is running.
- **The main menu lists every command** from Mole's More screen (M), not just the first five. Each command has its own row, with its preview (dry-run) and other variants beside it, and a bar at the bottom of the window describes the highlighted item and lists the keys.
- **You can add your own commands to the menu,** and edit or remove them, right in the menu. They get a section of their own.
- **Commands run inside a MoreMole screen:** the title and the command's summary stay at the top and a bar at the bottom says it's running, while its output scrolls between them, like the menu. When it finishes, the bar says so and shows the keys; you scroll back through everything it printed, search it with /, and open Clean's file list with F. A cancelled command returns to the menu straight away.
- **Status fills the window:** its bars stretch with the window, it has a GPU card, and R changes how often it refreshes.
- **Software updates** finds updates for Homebrew apps and tools, App Store apps, macOS and apps with their own updater, and installs the ones you pick.
- **AI models** checks your Ollama models for updates, downloads new ones from Ollama's library, and removes the ones you pick. If Ollama is off, it offers to turn it on, and turns it off again when done.
- **Pick lists have a search line and open A–Z:** type to narrow the list, and sort by name, size or date. Installer files uses the same list, so it gains both.
- **Optimize names what it applied,** or in a preview what it would apply, in the summary at the top.
- **Anyone can install it with one line, and Update MoreMole keeps it current.** People get the MoreMole releases you publish; your own folder brings in Mole's latest changes and keeps MoreMole's. Mole's own update never runs: it would install the official Mole over MoreMole.

The moremole changes live in their own files, so Mole's updates merge cleanly:

| File | What it is |
|---|---|
| `lib/moremole/menu.sh` | The menu, your commands, and Update |
| `cmd/status/moremole.go` | Status: stretching bars and the GPU card |
| `bin/moremole-updates.sh`, `cmd/moremole-updates/` | Software updates: the screen, and the Go helper that finds updates |
| `bin/moremole-models.sh`, `cmd/moremole-models/` | AI models: the screens, and the Go helper that asks Ollama, its registry and its library |
| `lib/moremole/runs.sh` | Shared by Software updates and AI models: runs a tool with its output on screen and keeps its error line |
| `lib/moremole/commands.sh` | Adds `updates` and `models` to help and Tab completion |
| `lib/moremole/cancel.sh` | Lets a cancelled command tell the menu to come straight back |
| `lib/moremole/lists.sh` | Puts Installer files on the shared pick list |
| `cmd/moremole-view/` | The command screen: runs a command inside the fixed frame, then shows its results |
| `scripts/moremole-sync.sh` | Brings in Mole's latest changes |
| `moremole-get.sh` | The installer: installs the newest MoreMole release, and updates a copy it installed |
| `scripts/moremole-release.sh`, `scripts/moremole-release-build.sh`, `.github/workflows/moremole-release.yml` | Publishing a release: you tag it, GitHub tests, builds and publishes it |
| `.github/README.md` | The front page on GitHub, shown instead of Mole's README |
| `tests/moremole_*.bats`, `cmd/status/moremole_test.go`, `cmd/moremole-updates/*_test.go`, `cmd/moremole-models/*_test.go`, `cmd/moremole-view/*_test.go` | Tests for the above |
| `mole`, `Makefile`, `lib/core/commands.sh`, `lib/core/common.sh`, `cmd/status/*.go` | A few marked lines (`moremole`) that hook the above in |
| `lib/ui/menu_paginated.sh`, `lib/ui/app_selector.sh`, `bin/slim.sh`, `bin/installer.sh`, `bin/optimize.sh`, `lib/clean/project.sh` | Marked lines (`MoreMole`) for the search line, A–Z first, Optimize's names, and Purge's find showing what you type and starting with nothing selected; `tests/slim.bats`, `tests/uninstall_menu.bats`, `tests/purge.bats` and `tests/purge_menu_pty.py` have the tests that relied on the old behavior changed to match |
| `tests/update.bats` | One marked line in its setup, so Mole's tests of its own updater keep running it; MoreMole never runs Mole's updater, which would install the official Mole over MoreMole |
| Mole's commands: `bin/clean.sh`, `bin/completion.sh`, `bin/installer.sh`, `bin/purge.sh`, `bin/slim.sh`, `bin/touchid.sh`, `bin/uninstall.sh`, `lib/uninstall/batch.sh`, `lib/manage/whitelist.sh` | One `moremole_note_cancel` line at each place the user cancels (`tests/moremole_cancel.bats` checks they're all there) |

## Running it

moremole runs straight from its folder. This section is for your git folder; everyone else installs with one line (see Installing for everyone else), which runs the same setup. Set up the `moremole` command, with `mm` as a short name for it, once:

```sh
cd ~/Developer/moremole
bash scripts/moremole-install.sh
```

Then open a new Terminal window and type `moremole` or `mm`.

The installer:

- links `moremole` and `mm` in `~/.local/bin` to this folder, so updates take effect straight away, and adds `~/.local/bin` to `PATH` in `~/.zshrc` if it isn't there;
- replaces an older `alias mm=` line in `~/.zshrc`;
- builds Analyze, Status, Software updates, AI models and the command screen, which are written in Go, if one of them was never built (install Go first with `brew install go`); after that, the update rebuilds them whenever they change;
- offers Tab completion for `moremole` and `mm`, asking before it changes `~/.zshrc` (later: `moremole completion`);
- offers to remove the official Mole if Homebrew installed it, with `brew uninstall mole`, which keeps `~/.config/mole`. Don't use Mole's own `mo remove` for this: it also moves `~/.config/mole`, including your MoreMole commands, to the Trash;
- links Mole's own names, `mo` and `mole`, to MoreMole too, so scripts written for Mole keep working. A name that already runs something else, such as an official Mole you kept, stays as it is; run the installer again after removing that Mole to take the name over.

It's safe to run again. To undo it, delete `moremole`, `mm`, `mo` and `mole` from `~/.local/bin`.

## Scripts and the command line

Every command works from the command line and in scripts as in Mole: same commands, options, output and exit codes, and `moremole status --json` is unchanged. The menu's additions (the command screen, cancel) only happen when a command runs from the menu. The differences:

- `moremole update` (and `mo update` once `mo` runs MoreMole) updates MoreMole the way it was installed (see Updating), instead of installing a Mole release; the help screen leaves out Mole's `--force` and `--nightly`, which MoreMole's update does not use.
- `moremole updates` (Software updates) and `moremole models` (AI models) are new.
- The help screen names commands `moremole ...`; hints inside commands still say `mo ...`.
- `moremole remove` doesn't run Mole's remover, which would leave MoreMole in place and move `~/.config/mole`, with your menu commands and protected lists, to the Trash. It changes nothing: it lists the links and folder to delete, notes that your settings stay, and records the refusal in History. It is not in the menu.

## The menu

```
➤ Clean                  Preview            Protected caches
  Optimize               Preview            Protected items
  Analyze                External drives
  Status
  History                Export
  Purge                  Preview            Choose folders
  Installer files        Preview
  Slim Intel code        Preview
  Touch ID               Preview
  Shell completion       Preview
  Software updates       Preview
  Software removal       Preview
  AI models              Preview            Download
  AI model removal       Preview
  Update MoreMole
───────────────────────── My commands ─────────────────────────
  Add a command
  Flush DNS              Edit               Remove

  Free up disk space
```

- Move with the arrow keys and press Enter. Preview shows what a command would do without doing it.
- A bar at the bottom of the window, under a divider, describes the highlighted item and lists the keys, as on the command screen.
- The menu has a screen of its own, the terminal's alternate screen, as full-screen apps such as `vim` and `htop` do. Q returns you to the terminal as it was before `mm`, history included, and terminal marks such as iTerm2's prompt marks don't show on the menu. Commands return to the menu's screen when they end. Update MoreMole and T (Touch ID) leave it first, so what they print stays on the terminal.
- Software removal is Mole's Uninstall, next to Software updates.
- 1 to 5 still start Clean, Software removal (Uninstall), Optimize, Analyze and Status directly. M (help) and V (version) show their screen and come back to the menu on Enter or Q; T, U and Q work as before.
- The help screen and update notices name commands `moremole ...` instead of `mo ...`.
- Each command runs on the command screen, named after the menu item (for example "Clean · Preview"). The title and the command's summary stay at the top, a bar stays at the bottom, and the command's output scrolls between them; the terminal itself never scrolls.
- While the command runs, the bar at the bottom shows a spinner and "Running". Clean also shows its summary's labels at the top with the spinner where the numbers will go (Potential space, Items and Categories for Preview; Tracked cleanup and Items cleaned for a real Clean). Other commands' summaries are sentences, so only the bar shows.
- Keys go to the running command: its prompts, passwords and pick lists work as usual, and Ctrl-C stops it.
- When it finishes, the bar says so where your eyes are: ✓ and the summary's heading (for example "✓ Updates installed"), or "✓ Done"; "!" when it ended with an error and "■ Stopped" after Ctrl-C. The rest of the bar lists the keys. The summary (the block Mole prints between two rows of `=`) moves to the top, and the rest of the output scrolls below, opened at the end. Scroll with the arrow keys, PgUp and PgDn, or Home and End; in most terminals the trackpad scrolls it too. Enter, Q or ESC returns to the menu.
- **/** searches the output, the same way as the pick lists: it narrows to the matching lines as you type, upper or lower case alike, with the matches marked, and the bar counts them. Enter or an arrow key finishes typing, and ESC or Q clears the search and goes back to where you were. History, every Preview and every command's results can be searched this way.
- History from the menu shows the last 200 entries (`moremole history` alone shows 20).
- After Clean's Preview, **F** shows the list of files Clean would remove (`~/.config/mole/clean-list.txt`, which stays where Mole puts it), long paths wrapped in full; the summary's "Detailed file list" line says "(F to view)". Q goes back to the results.
- The results keep the colors and drop what was only on screen for a moment: progress spinners, pick lists, and screens a command cleared.
- Analyze and Status are full-screen already and run on their own; they come back as soon as you quit them.
- If the command screen is not built yet, commands run on a clear screen and the menu asks for Enter afterwards, as before.
- If you cancel instead (Q or ESC in a pick list, or at the final "Enter confirm, ESC cancel" step), the menu comes back straight away, with nothing to dismiss. This covers Clean's password step, Software removal, Purge, Installer files, Slim, Touch ID, Shell completion, Software updates, AI models and the Protected caches and Protected items lists.
- Update MoreMole is the exception: it ends the menu, because it may have changed moremole's files. Type `mm` to start the new version. How it updates depends on how MoreMole was installed (see Updating).
- A window too short for every row scrolls with the arrow keys, and says so under the list.

## Pick lists

The lists you choose items from (Software removal, Slim Intel code, Installer files, Software updates, AI models, and Software removal's personal data) work the same way:

- A search line sits under the title. Press **/** and type: the list narrows as you type, matching anywhere in the name, upper or lower case.
- The arrow keys take you from the search line into the narrowed list, so Space selects and Enter saves. Enter on the search line just finishes the search.
- **Esc** or **Q** clears an applied search; Q again goes back. Selections stay when the search changes, and Enter never saves a selection the search is hiding: it clears the search first, so you see everything you picked.
- Lists open A–Z. Where the list knows sizes or dates, **S** switches to largest first, then oldest first, then back to A–Z, and **O** flips the order. Installer files sorts by file name, size and date modified; Software removal by name, size and last used; AI model removal by name, size and date downloaded; AI models' Download by name and when Ollama last updated the model.
- Nothing starts selected: you pick, or press **A** to select everything. Mole's Purge selected the artifacts older than 7 days for you; in moremole its list starts empty too, and the age column still shows which are old. Two lists keep their ticks, because they show what is already protected rather than a suggestion: Clean's Protected caches and Optimize's Protected items. Software removal ticks personal data only when you ask for it with `--with-data`.
- Purge keeps its own list, grouped by project with the biggest first. **/** asks for a project or folder name; type it and press Enter to jump to the first match, then **n** for the next one.

## Your own commands

They're at the bottom of the menu:

- **Add a command** asks for the name the menu shows, then the command to run. Leave the name empty to cancel.
- **Enter on a command's name** runs it.
- **Edit**, beside it, changes the name or the command. Press Enter to keep what's shown in brackets.
- **Remove** takes it off the menu, after you confirm.

Each runs with your shell (`$SHELL -c`), in the folder you started moremole from. Aliases from `~/.zshrc` aren't loaded there, so use the full command. Commands that use `sudo` ask for your password as usual.

They're saved in `~/.config/mole/my_commands`, one per line as name, a Tab, then the command. You can edit that file directly; lines starting with `#` are ignored, and the menu keeps them.

## Status

- The bars stretch to fill the window; make the window wider for longer bars.
- **R** changes how often Status refreshes: 0.5, 1, 2, 5 or 10 seconds, starting at 1. It remembers your choice. A line at the bottom shows the current setting and the keys.
- **C** (Mole's own key) cycles through 2, 4, 8 and all CPU cores and remembers your choice; a window too short for all of them shows fewer.
- The GPU card shows total GPU use, updated with every refresh like CPU use, plus the chip and its GPU core count. macOS reports GPU use for the GPU as a whole, not for each GPU core.

If you pull changes with `git pull`, the next update rebuilds the Go parts if needed, or run `make build` yourself.

## Software updates

Choose **Software updates** in the menu, or run `moremole updates`. **Preview** (`moremole updates --dry-run`) only lists what's available.

It checks Homebrew, the App Store, macOS and your other apps, then shows one A–Z list with each row's source. Nothing starts selected: pick with the arrow keys and Space (A selects all, / searches), Enter to continue.

| Source (as the list shows it) | Installs with |
|---|---|
| Homebrew: Homebrew apps; "updates itself" marks apps that also update on their own | `brew upgrade --cask --greedy` |
| Move to Homebrew: apps you installed yourself that Homebrew has a newer version of | `brew install --cask --force`, which replaces your copy; settings stay |
| Own updater: apps you installed yourself whose own updater (Sparkle) lists a newer version | opens the app, whose updater installs it |
| App Store | `mas upgrade`, which may ask for your password |
| Command-line tool (Homebrew formulae) | `brew upgrade --formula` |
| macOS | `softwareupdate --install`, after your password |
| macOS, "needs a restart" | opens Software Update in System Settings |

- A confirm screen lists your picks and warns about what they do (apps quit, your copy is replaced, a password is needed). Enter installs; any other key cancels.
- **The app moremole is running in is never updated from moremole.** Updating your terminal (iTerm2, for one) from inside it can end the run: Homebrew may quit the app midway, which stops moremole and the update with it, and an app's own updater restarts it. moremole recognizes that app (from the app that started your shell, `TERM_PROGRAM`, and the parent processes), marks its row "runs MoreMole", and if you pick it, leaves it out: the confirm screen and the summary say to use the app's own Check for Updates, or to update it from another terminal (Terminal, say). History records it as skipped.
- Each update runs with its own output on screen, then a summary says what updated and what didn't, and why. Each one is recorded in History. When an update fails, the summary and History give the tool's own error line (Homebrew's or mas's "Error: ..."), not just which tool failed.
- Homebrew sometimes stops an upgrade because a copy of the item's own file is still in Homebrew's folder for it, left by an earlier upgrade that stopped partway: "It seems there is already a Font at '/opt/homebrew/Caskroom/<name>/<version>/<file>'". Software updates then tries once more with `--force`, which lets Homebrew replace that copy, and the summary names what was updated this way. When the file named is anywhere outside that item's own Homebrew folder, nothing is retried and the error is shown.
- Checking can take a minute: Homebrew refreshes its version list first, and macOS is slowest to answer.
- No Homebrew: Homebrew apps and tools are skipped, with a note. No `mas` (the App Store tool): it offers to install it with Homebrew.
- Pinned formulae (`brew pin`) are left out. Apps that report no version number (`latest`) are marked "always reinstalls".
- "older version, Homebrew's choice" marks an update to a lower version number: Homebrew moved that formula to another line on purpose (openssl@3 went from 3.6 to its long-term 3.5 line).
- "Own updater" reads the update feed the app names in its Info.plist (`SUFeedURL`), skipping beta channels and versions that need a newer macOS. Installing stays with the app, which checks the download's signature: the apps open after the other updates, and the summary names them. If an app doesn't offer the update, choose Check for Updates in its menu. Apps Homebrew manages, App Store and Apple apps, and apps offered for Move to Homebrew aren't checked this way.
- An app joins "Move to Homebrew" only when all of these hold:
  - exactly one Homebrew app matches its name, and that Homebrew app doesn't update itself;
  - your copy is the only one, at the place Homebrew would put it (`/Applications/<name>.app`);
  - its bundle ID is one the Homebrew app names;
  - Homebrew's version is clearly newer.

  App Store and Apple apps never qualify. Most Homebrew apps name a different install location for their app, so these apps can't qualify either, and the offer is rare.
- Software updates is a moremole addition. Mole leaves package management out on purpose, so this part won't be offered to Mole.

## AI models

For [Ollama](https://ollama.com) models. Choose **AI models** in the menu, or run `moremole models`:

| Menu | Command | What it does |
|---|---|---|
| AI models | `moremole models` | Checks each model for an update and installs the ones you pick |
| Preview | `moremole models --dry-run` | Lists your models with size, update status and which are in use, changing nothing |
| Download | `moremole models --download` | Downloads models you pick from Ollama's library |
| AI model removal | `moremole models --remove` | Removes the models you pick |
| Preview | `moremole models --remove --dry-run` | Lists your models and their sizes, removing nothing |

- **Ollama off:** the models are only reachable while Ollama runs. If it's off, AI models asks first (Enter turns it on, ESC goes back), opens the Ollama app in the background (or runs `ollama serve` when there's only the command), and turns it off again when it's done, so Ollama ends as it was found. The summary says so. If Ollama isn't installed, it says where to get it. From a script, or in a Preview, it doesn't turn Ollama on; it says to open the app.
- **Update check:** for each model, it asks the model's registry (Ollama's, or another such as hf.co) for the model's current manifest and compares it with the one Ollama saved when it downloaded the model. A model that changed shows "update available"; one built on this Mac (`ollama create`) shows "made on this Mac"; one it couldn't reach shows "couldn't check", and the list ends with how many couldn't be checked instead of "No updates". The list shows only models with an update, none selected. Updating runs `ollama pull`, which downloads only the parts that changed.
- **Download:** Ollama has no list of its models for programs, so the list comes from its web page, ollama.com/library: one row per model and size (`gemma3:4b`, `gemma3:27b`), with what it can do (tools, vision, thinking...) and how often it's pulled. Models that only run on Ollama's servers are left out, and the ones you have say "(installed)". Search finds a model by name, ability or description. Before downloading, the confirm screen gives each model's download size (from the registry) and whether it fits this Mac's memory: "fits" up to half the memory, "tight" up to three quarters, "too big" beyond. If the page can't be read (offline, or redesigned), it asks for a name as the library shows it and checks it with the registry first.
- **Removal:** the list shows every model, A–Z; S sorts by size, then date. A model in use is unloaded first (`ollama stop`), then `ollama rm` deletes it: Ollama's models don't go to the Trash, and the confirm screen says so. Models share some files, so the space freed can be less than the sizes shown; the summary counts only models that were removed.
- Downloads, updates and removals are recorded in History, with Ollama's own error line when one fails.
- It talks to Ollama where the `ollama` command does: `OLLAMA_HOST`, else this Mac.
- Not yet tried against the live library page and registry, which weren't reachable while it was written; the tests use saved copies of their answers.
- AI models is a moremole addition, like Software updates.

## Updating

Choose **Update MoreMole** in the menu, press U when an update notice shows, or run `moremole update`. What it does depends on how this copy was installed:

| Copy | Update MoreMole |
|---|---|
| Installed with the one-line installer (`~/.local/share/moremole`) | Installs the newest MoreMole release: downloads it, checks it against its checksums, and puts it in place of the old copy. Your commands and settings in `~/.config/mole` stay. History records it. |
| Your git folder, which has Mole as its `upstream` remote | Brings in Mole's latest changes (below) |
| Another git copy (a clone without `upstream`) | Says to run `git pull`, then `make build` |
| Anything else (a downloaded zip, say) | Says to install with the one-line installer |

The menu's update notice works the same way: a copy from the installer is told when a newer MoreMole release is out (checked once a day, in the background); your git folder is told when Mole has a new release to bring in.

### Bringing in Mole's changes (your git folder)

```sh
bash scripts/moremole-sync.sh
```

It first brings down any moremole changes already on GitHub, then copies Mole's latest changes into `main`, merges them into the `moremole` branch, and pushes both to GitHub. When one of the Go parts (Analyze, Status, Software updates, AI models, the command screen) is older than its code, including after a `git pull`, it rebuilds them (`make build`). It stops and says what to do if you have uncommitted changes, are on another branch, or if Mole changed the same lines as moremole.

People who installed MoreMole get these changes with the next release you publish.

## Installing for everyone else

The front page (`.github/README.md`) gives this line to paste into Terminal:

```sh
curl -fsSL https://raw.githubusercontent.com/RosBradley/moremole/moremole/moremole-get.sh | bash
```

`moremole-get.sh` asks GitHub for the newest MoreMole release, downloads its files and the Go parts built for that Mac (Apple silicon or Intel), and checks each against the release's `SHA256SUMS`; a mismatch stops it with nothing changed. It installs to `~/.local/share/moremole` and runs `scripts/moremole-install.sh` from there to set up the commands, so it needs no Go, no git and no password. Running it again repairs the commands. It refuses to replace a `~/.local/share/moremole` it didn't put there.

## Publishing a release

People only get what you publish, so a release is your "this version is ready". When the `moremole` branch is pushed and you've tried it:

```sh
bash scripts/moremole-release.sh
```

It checks that you're on `moremole` with everything committed and pushed, shows the version (today's date, such as `2026.10.26`; a second release that day is `2026.10.26.2`), and asks before publishing (Enter publishes, ESC cancels). Then it pushes the tag `moremole-2026.10.26`. GitHub takes it from there (`.github/workflows/moremole-release.yml`, about 10 minutes):

1. checks that the tag is on the `moremole` branch;
2. runs the Go tests and MoreMole's tests (`tests/moremole_*.bats`) on a Mac;
3. builds the release files (`scripts/moremole-release-build.sh`): the files of that commit, the Go parts for Apple silicon and for Intel, and their checksums;
4. records that GitHub built them (an attestation anyone can check with `gh attestation verify`);
5. publishes the release, with notes listing the changes since the last one.

If a step fails, nothing is published: fix it, push, and run the script again. A commit whose tag never became a release can be tagged again after removing the tag; the script says how.

You can add it to the menu under My commands, as `bash ~/Developer/moremole/scripts/moremole-release.sh`.

One-time setup on GitHub:

- **Actions** must be on for the fork (the Actions tab offers to turn them on). Mole's own workflows then run on pushes to `main` too; turn them off one by one in the Actions tab if you don't want them. Mole's Release only answers to `V` tags and its contributors robot only runs in tw93's repository, so neither touches MoreMole.
- **Default branch:** set it to `moremole` (Settings, General), so the repository's page shows MoreMole's front page and files instead of Mole's.
