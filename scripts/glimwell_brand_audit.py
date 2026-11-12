#!/usr/bin/env python3
"""glimwell: fail when Mole's name shows up in text Glimwell users see.

Glimwell keeps Mole's code names (the `mole` script, MOLE_ settings, the
~/.config/mole folders, the Go module path) so Mole's changes keep merging,
but everything it prints says Glimwell: "Glimwell", and "glimwell <command>"
instead of "mo <command>". A merge from Mole that adds a new message with
Mole's name fails this check, which lists each line to change.

Scans the router, bin/, lib/ and the Go commands (not their tests). Comment
lines, trailing "# SAFE:" notes, Go trailing comments and Go import paths
are skipped. The agent skill, its plugin copy and manifests, and llms.txt
are read whole, since other people's agents read them. Mole's updater and remover (lib/manage/update.sh and
lib/manage/remove.sh) are skipped because Glimwell replaces them
(lib/glimwell/menu.sh); tests/glimwell_brand.bats checks the screens Glimwell
still takes from them, help and version, as printed.

Usage: python3 scripts/glimwell_brand_audit.py
"""

from __future__ import annotations

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent

SKIPPED_FILES = {
    "lib/manage/update.sh": "Mole's updater; Glimwell replaces it and filters its help screen",
    "lib/manage/remove.sh": "Mole's remover; Glimwell replaces it",
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
    ("bin/completion.sh", 'echo "# Mole shell completion"', "marker MOLE_COMPLETION_LINE_PATTERN matches in shell rc files"),
    ("lib/core/base.sh", "MOLE_COMPLETION_LINE_PATTERN=", "matches the completion lines Mole and Glimwell wrote"),
    ("lib/core/commands.sh", '"remove:Remove Mole from system"', "lib/glimwell/commands.sh replaces this description"),
    ("lib/core/common.sh", "https://api.github.com/repos/tw93/mole/releases/tags/V", "Mole's Homebrew updater, which Glimwell never runs"),
    ("lib/core/common.sh", "https://github.com/tw93/Mole/releases/tag/V", "Mole's Homebrew updater, which Glimwell never runs"),
    ("lib/core/common.sh", 'start_inline_spinner "Upgrading Mole..."', "Mole's Homebrew updater, which Glimwell never runs"),
    ("lib/core/common.sh", 'echo "Upgrading Mole..."', "Mole's Homebrew updater, which Glimwell never runs"),
    ("lib/core/common.sh", "mo --version 2> /dev/null | awk '/Mole version/", "Mole's Homebrew updater, which Glimwell never runs"),
    ("lib/glimwell/menu.sh", '"mo update --force" | "mo update --nightly" | "mo remove --dry-run"', "drops Mole-only help lines"),
    ("lib/glimwell/menu.sh", "${message//run mo update/run glimwell update}", "turns Mole's update notice into Glimwell's"),
    ("lib/glimwell/menu.sh", '"$line" == "Mole version "*', "finds Mole's version line to replace it"),
    ("lib/glimwell/menu.sh", "printf 'Based on Mole %s by tw93: github.com/tw93/Mole", "the credit GPL-3.0 asks Glimwell to keep"),
    ("lib/glimwell/menu.sh", "Glimwell updates by bringing in Mole", "shown only in the maintainer's git folder"),
]


def code_part(path: str, line: str) -> str:
    """The line without a trailing comment Glimwell users never see."""
    if path.endswith(".go"):
        if re.match(r'\s*"[\w.]+/[\w./-]+"\s*$', line) or re.match(r'\s*import\s+"', line):
            return ""
        return line.split(" // ", 1)[0]
    return line.split(" # SAFE:", 1)[0]


def text_files() -> list[pathlib.Path]:
    found = sorted(ROOT.glob("skills/glimwell/**/*.md")) + sorted(ROOT.glob("plugins/glimwell/**/*"))
    found += [ROOT / "llms.txt", ROOT / ".claude-plugin/marketplace.json", ROOT / ".agents/plugins/marketplace.json"]
    return [p for p in found if p.is_file()]


def files() -> list[pathlib.Path]:
    found = [ROOT / "mole"]
    found += sorted(ROOT.glob("bin/*.sh"))
    found += sorted(ROOT.glob("lib/**/*.sh"))
    found += [p for p in sorted(ROOT.glob("cmd/**/*.go")) if not p.name.endswith("_test.go")]
    return found


def main() -> int:
    used = set()
    problems = []
    text_set = set(text_files())
    for path in files() + sorted(text_set):
        rel = path.relative_to(ROOT).as_posix()
        if rel in SKIPPED_FILES:
            continue
        whole = path in text_set
        for number, line in enumerate(path.read_text(errors="replace").splitlines(), 1):
            stripped = line.strip()
            if not whole and (stripped.startswith("#") or stripped.startswith("//")):
                continue
            if not PATTERN.search(line if whole else code_part(rel, line)):
                continue
            allowed = [i for i, (f, text, _) in enumerate(ALLOWED) if f == rel and text in line]
            if allowed:
                used.update(allowed)
                continue
            problems.append(f"  {rel}:{number}: {stripped[:160]}")
    stale = [f"  {f}: {text}" for i, (f, text, _) in enumerate(ALLOWED) if i not in used]
    if problems:
        print("Mole's name is in text Glimwell users see:")
        print("\n".join(problems))
        print("Say Glimwell, and glimwell <command> for mo <command>. If users never see the line, or it must")
        print("stay, add it to ALLOWED in scripts/glimwell_brand_audit.py with the reason.")
    if stale:
        print("These ALLOWED entries match no line any more; remove them from scripts/glimwell_brand_audit.py:")
        print("\n".join(stale))
    return 1 if problems or stale else 0


if __name__ == "__main__":
    sys.exit(main())
