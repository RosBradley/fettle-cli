#!/usr/bin/env python3
"""fettle: fail when Mole's name shows up in text Fettle users see.

Fettle keeps Mole's code names (the `mole` script, MOLE_ settings, the
~/.config/mole folders, the Go module path) so Mole's changes keep merging,
but everything it prints says Fettle: "Fettle", and "fettle <command>"
instead of "mo <command>". A merge from Mole that adds a new message with
Mole's name fails this check, which lists each line to change.

Scans the router, bin/, lib/ and the Go commands (not their tests). Comment
lines, trailing "# SAFE:" notes, Go trailing comments and Go import paths
are skipped. Mole's updater and remover (lib/manage/update.sh and
lib/manage/remove.sh) are skipped because Fettle replaces them
(lib/fettle/menu.sh); tests/fettle_brand.bats checks the screens Fettle
still takes from them, help and version, as printed.

Usage: python3 scripts/fettle_brand_audit.py
"""

from __future__ import annotations

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent

SKIPPED_FILES = {
    "lib/manage/update.sh": "Mole's updater; Fettle replaces it and filters its help screen",
    "lib/manage/remove.sh": "Mole's remover; Fettle replaces it",
}

COMMANDS = (
    r"(?:clean|uninstall|optimize|analyze|analyse|status|purge|installer|update"
    r"|history|slim|touchid|completion|remove|updates|models)"
)
PATTERN = re.compile(
    r"\bMole\b"
    rf"|\bmo (?:{COMMANDS}\b|--|<)"
    rf"|['\"`]mole (?:{COMMANDS}\b|--)"
    r"|\bmole\.fit\b"
    r"|(?<!com\.)\btw93\b"
)

# (file, text on the line, why it stays). Keep each entry to one line it
# names exactly; a reason says why users never see it or why it must stay.
ALLOWED = [
    ("bin/completion.sh", "# Mole completions for mo (alias)", "first line of Fish's file for Mole's names"),
    ("bin/completion.sh", 'echo "# Mole shell completion"', "marker MOLE_COMPLETION_LINE_PATTERN matches in shell rc files"),
    ("lib/core/base.sh", "MOLE_COMPLETION_LINE_PATTERN=", "matches the completion lines Mole and Fettle wrote"),
    ("lib/core/commands.sh", '"remove:Remove Mole from system"', "lib/fettle/commands.sh replaces this description"),
    ("lib/core/common.sh", "https://api.github.com/repos/tw93/mole/releases/tags/V", "Mole's Homebrew updater, which Fettle never runs"),
    ("lib/core/common.sh", "https://github.com/tw93/Mole/releases/tag/V", "Mole's Homebrew updater, which Fettle never runs"),
    ("lib/core/common.sh", 'start_inline_spinner "Upgrading Mole..."', "Mole's Homebrew updater, which Fettle never runs"),
    ("lib/core/common.sh", 'echo "Upgrading Mole..."', "Mole's Homebrew updater, which Fettle never runs"),
    ("lib/core/common.sh", "mo --version 2> /dev/null | awk '/Mole version/", "Mole's Homebrew updater, which Fettle never runs"),
    ("lib/fettle/menu.sh", '"mo update --force" | "mo update --nightly" | "mo remove --dry-run"', "drops Mole-only help lines"),
    ("lib/fettle/menu.sh", "${message//run mo update/run fettle update}", "turns Mole's update notice into Fettle's"),
    ("lib/fettle/menu.sh", '"$line" == "Mole version "*', "finds Mole's version line to replace it"),
    ("lib/fettle/menu.sh", "printf 'Based on Mole %s by tw93: github.com/tw93/Mole", "the credit GPL-3.0 asks Fettle to keep"),
    ("lib/fettle/menu.sh", "Fettle updates by bringing in Mole", "shown only in the maintainer's git folder"),
]


def code_part(path: str, line: str) -> str:
    """The line without a trailing comment Fettle users never see."""
    if path.endswith(".go"):
        if re.match(r'\s*"[\w.]+/[\w./-]+"\s*$', line) or re.match(r'\s*import\s+"', line):
            return ""
        return line.split(" // ", 1)[0]
    return line.split(" # SAFE:", 1)[0]


def files() -> list[pathlib.Path]:
    found = [ROOT / "mole"]
    found += sorted(ROOT.glob("bin/*.sh"))
    found += sorted(ROOT.glob("lib/**/*.sh"))
    found += [p for p in sorted(ROOT.glob("cmd/**/*.go")) if not p.name.endswith("_test.go")]
    return found


def main() -> int:
    used = set()
    problems = []
    for path in files():
        rel = path.relative_to(ROOT).as_posix()
        if rel in SKIPPED_FILES:
            continue
        for number, line in enumerate(path.read_text(errors="replace").splitlines(), 1):
            stripped = line.strip()
            if stripped.startswith("#") or stripped.startswith("//"):
                continue
            if not PATTERN.search(code_part(rel, line)):
                continue
            allowed = [i for i, (f, text, _) in enumerate(ALLOWED) if f == rel and text in line]
            if allowed:
                used.update(allowed)
                continue
            problems.append(f"  {rel}:{number}: {stripped[:160]}")
    stale = [f"  {f}: {text}" for i, (f, text, _) in enumerate(ALLOWED) if i not in used]
    if problems:
        print("Mole's name is in text Fettle users see:")
        print("\n".join(problems))
        print("Say Fettle, and fettle <command> for mo <command>. If users never see the line, or it must")
        print("stay, add it to ALLOWED in scripts/fettle_brand_audit.py with the reason.")
    if stale:
        print("These ALLOWED entries match no line any more; remove them from scripts/fettle_brand_audit.py:")
        print("\n".join(stale))
    return 1 if problems or stale else 0


if __name__ == "__main__":
    sys.exit(main())
