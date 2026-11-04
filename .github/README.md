# MoreMole

MoreMole is a macOS cleanup and maintenance tool for the terminal, built on [Mole](https://github.com/tw93/Mole) by tw93. It does everything Mole does, from one menu, and adds software updates and Ollama model management.

```
➤ Clean                   Preview            Protected caches
  Optimize                Preview            Protected items
  Analyze                 External drives
  Status
  History                 Export
  Purge                   Preview            Choose folders
  Installer files         Preview
  Slim Intel code         Preview
  Touch ID                Preview
  Shell completion        Preview
  Software updates        Preview
  Software removal        Preview
  Ollama models           Preview            Download new
  Ollama model removal    Preview
  Update MoreMole
───────────────────────── My commands ─────────────────────────
  Add a command
```

## What it adds to Mole

### One menu for everything

Mole's menu shows five commands and keeps the rest behind a help screen. MoreMole's menu lists every one: Clean, Optimize, Analyze, Status, History, Purge, Installer files, Slim, Touch ID and Shell completion, plus MoreMole's own Software updates and Ollama models.

- **Each row has its variants beside it.** Preview shows what a command would do without doing anything. Other variants include Analyze's External drives, History's Export and Purge's Choose folders.
- **A bar at the bottom** describes the highlighted row and lists the keys.
- **Your own commands** get a section of their own. Add, edit and remove them from the menu itself. They run with your shell and are saved in `~/.config/mole/my_commands`.
- **The menu has a screen of its own,** as `vim` does. Quitting returns your terminal exactly as it was.

### A results screen

Commands started from the menu run inside a fixed frame. The title and summary stay at the top, a "Running" bar stays at the bottom, and the output scrolls between them.

- **When the command finishes,** the bar shows ✓, ! or ■ (finished, ended with an error, or stopped). The summary moves to the top.
- **Scroll back** through everything it printed, and **search** it with `/`. After Clean's Preview, **F** opens the full list of files Clean would remove.
- **Cancel** a command and you're back in the menu straight away, with nothing to dismiss.

### Software updates (`moremole updates`)

Mole leaves app updates out on purpose. MoreMole brings every source into one list:

- Homebrew apps and command-line tools, App Store apps, macOS, and apps with their own updater (Sparkle).
- Each row names its source. **Preview** only lists what's available.
- A confirm screen says what each pick will do: an app will quit, your copy will be replaced, or a password is needed.
- **It never updates the terminal app it's running in,** because that could stop the update partway. It tells you to update that app another way.
- The summary says what updated, what didn't and why, with the tool's own error line. Each one is recorded in History.
- Occasionally an app you installed yourself has a newer Homebrew version. MoreMole offers to move that app to Homebrew, but only when the app, its location and its bundle ID all match exactly.

### Ollama models (`moremole models`)

For [Ollama](https://ollama.com):

- **Check for updates.** It compares each model with its registry, then downloads only the parts that changed.
- **Download new** models in two steps. First pick models from Ollama's library, with what each can do (tools, vision, thinking), the sizes it comes in and how popular it is. Then pick their versions, each with its download size, whether it fits your Mac's memory (fits, tight or too big), its context window, what it reads (text, images), and an **MLX** flag on the versions built for Apple silicon.
- **Remove** the models you pick. A model in use is unloaded first. The confirm screen says that removed models don't go to the Trash.
- If Ollama is off, it offers to turn it on, and turns it off again when it's done.

### Lists you can search

Software removal, Slim, Installer files, Software updates and Ollama models share one pick list:

- **`/` searches** as you type, matching anywhere in the name.
- **Lists open A–Z.** S sorts by size, then by date (oldest first), and O flips the order.
- **Nothing is selected for you.** That includes Purge, where Mole selected everything older than 7 days.

### Analyze and Status fill the window

- **Analyze** lists as many rows as the window holds, instead of stopping at 30, with its keys on the bottom row. In a wide window its bars and names get longer.
- **Status** bars stretch to the width of the window.
- A GPU card shows GPU use, the chip and its GPU core count.
- **R** changes how often Status refreshes: from every 0.5 seconds to every 10.

### And smaller things

- **Optimize** names what it applied, or would apply in a Preview, in its summary.
- **Update MoreMole** installs the newest MoreMole release, checked against its published checksums. Mole's own updater never runs, because it would replace MoreMole with Mole.
- **`moremole remove`** changes nothing. It tells you exactly what to delete to remove MoreMole, instead of running Mole's remover, which would also move your settings to the Trash.
- **`mo` and `mole`** run MoreMole too, so scripts written for Mole keep working.

## Install

Paste this into Terminal:

```sh
curl -fsSL https://raw.githubusercontent.com/RosBradley/moremole/moremole/moremole-get.sh | bash
```

Then open a new Terminal window and type `moremole`, or `mm` for short.

It needs macOS 12 or newer, on Apple silicon or Intel. It installs in your home folder and asks for no password. Every download is checked against the checksums published with its release.

## Update

When a new MoreMole release is out, the menu says so. Choose **Update MoreMole** to install it; your own commands and settings stay.

## Uninstall

Delete the `~/.local/share/moremole` folder, and the links MoreMole made in `~/.local/bin`: `moremole` and `mm`, and `mo` and `mole` if it made those. Your settings stay in `~/.config/mole` until you delete that too.

## Mole and MoreMole

MoreMole follows Mole closely: Mole's changes are brought in regularly, and Mole's commands, options and output work the same, so scripts written for Mole keep working. If you'd rather have the official Mole, get it at [github.com/tw93/Mole](https://github.com/tw93/Mole).

The full list of changes, and how each part works, is in [MOREMOLE.md](https://github.com/RosBradley/moremole/blob/moremole/MOREMOLE.md).

MoreMole is not affiliated with or endorsed by the Mole project. Like Mole, it is licensed under [GPL-3.0](https://github.com/RosBradley/moremole/blob/moremole/LICENSE).
