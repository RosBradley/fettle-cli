#!/usr/bin/env python3
"""Name the verification a change needs from the paths it touches, not from who wrote it.

    python3 scripts/risk_tier.py [path ...]
    python3 scripts/risk_tier.py --self-check

With no paths it reads the change not yet on the upstream branch: commits since
the merge base with @{upstream} (origin/main when there is none) plus staged,
unstaged and untracked files. It prints one line per tier the change reaches,
highest first, and nothing when only the default checks apply. It is advice
printed by check.sh, never a failure: the gates it names need a real Mac, the
release flow or the maintainer, where check.sh cannot prove they ran. Several
sessions can share a checkout, so pass your own files when the worktree holds
other work.

--self-check exits 1 when a tier pattern matches no tracked file: a rename
would otherwise drop that file to the default tier without anyone noticing.
"""

from __future__ import annotations

import datetime as dt
import fnmatch
import subprocess
import sys
from collections import Counter
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]

# Highest first. A path takes every tier it matches, so lib/core/file_ops.sh
# needs both the deletion and the privilege gates.
TIERS = [
    (
        "release",
        "the release-flow pre-flight (.claude/skills/release-flow): make release-amd64 release-arm64, "
        "scripts/check_release_minos.sh, the Nix workflow and scripts/e2e_macos.py on a real Mac before tagging",
        [
            ".github/workflows/release.yml",
            "Makefile",
            "scripts/check_release_minos.sh",
            "package.nix",
            "flake.nix",
            "overlay.nix",
            "scripts/test_nix_package.py",
        ],
    ),
    (
        "ci",
        "the maintainer's review of the diff; each changed job green at the exact pushed SHA "
        "(gh run list --commit <sha> --json status,conclusion); a changed gate red-run once on a known-bad sample",
        [
            ".github/workflows/*",
            ".githooks/*",
            "scripts/check.sh",
            "scripts/test.sh",
            "scripts/audit_*.py",
        ],
    ),
    (
        "install-update",
        "MOLE_TEST_NO_AUTH=1 bats tests/update.bats tests/cli.bats tests/install_checksum.bats; "
        "fail-closed verification kept (.claude/rules/install-update.md); scripts/e2e_macos.py before release",
        [
            "mole",
            "mo",
            "install.sh",
            "lib/manage/update.sh",
            "lib/manage/remove.sh",
        ],
    ),
    (
        "deletion",
        "line-by-line sink review (AGENTS.md Critical Safety Rules); a test red on the old code; "
        "the area's Bats command from its .claude/rules file, then MOLE_TEST_NO_AUTH=1 ./scripts/test.sh",
        [
            "lib/core/file_ops.sh",
            "lib/core/app_protection.sh",
            "lib/core/app_protection_data.sh",
            "lib/core/bundle_resolver.sh",
            "lib/clean/*",
            "lib/uninstall/*",
            "lib/optimize/*",
            "lib/manage/purge_paths.sh",
            "lib/manage/whitelist.sh",
            "bin/clean.sh",
            "bin/uninstall.sh",
            "bin/purge.sh",
            "bin/installer.sh",
            "bin/slim.sh",
            "bin/optimize.sh",
            "cmd/analyze/delete.go",
        ],
    ),
    (
        "privilege",
        "MOLE_TEST_NO_AUTH=1 bats tests/manage_sudo.bats; every new sudo, osascript or launchctl call "
        "behind a MOLE_TEST_MODE / MOLE_TEST_NO_AUTH guard (AGENTS.md); no real authorization prompt in verification",
        [
            "lib/core/sudo.sh",
            "lib/core/file_ops.sh",
            "lib/core/app_protection.sh",
            "lib/clean/apps.sh",
            "lib/clean/brew.sh",
            "lib/clean/system.sh",
            "lib/optimize/tasks.sh",
            "lib/uninstall/batch.sh",
            "lib/uninstall/brew.sh",
            "bin/clean.sh",
            "bin/touchid.sh",
        ],
    ),
]


def git(*args: str) -> list[str]:
    out = subprocess.run(["git", "-C", str(PROJECT_ROOT), *args], capture_output=True, text=True)
    return out.stdout.split("\n") if out.returncode == 0 else []


def pending_paths() -> list[str]:
    base = (git("merge-base", "HEAD", "@{upstream}") or git("merge-base", "HEAD", "origin/main") or [""])[0]
    paths = set(git("diff", "--name-only", base)) if base else set()
    paths.update(git("ls-files", "--others", "--exclude-standard"))
    return sorted(p for p in paths if p)


def tiers_for(paths: list[str]) -> list[tuple[str, str, list[str]]]:
    hits = []
    for name, gates, patterns in TIERS:
        matched = [p for p in paths if any(fnmatch.fnmatchcase(p, pattern) for pattern in patterns)]
        if matched:
            hits.append((name, gates, matched))
    return hits


def dead_patterns() -> list[str]:
    tracked = [p for p in git("ls-files") if p]
    return [
        f"{name}: {pattern}"
        for name, _, patterns in TIERS
        for pattern in patterns
        if not any(fnmatch.fnmatchcase(p, pattern) for p in tracked)
    ]


# Circuit breaker: once users met BREAKER_ROWS defects within BREAKER_DAYS (docs/incidents.md, by Reported date),
# every change that reaches a tier also needs the full gate, and the layers those defects slipped past are named
# so they are tightened first. It clears on its own as the rows age out; a future date is never counted.
BREAKER_DAYS, BREAKER_ROWS = 7, 5
BREAKER_GATE = '`./scripts/check.sh --no-format` and the whole `MOLE_TEST_NO_AUTH=1 ./scripts/test.sh` instead of single Bats files, and the maintainer reading each listed fix before the next release'
LEDGER = PROJECT_ROOT / 'docs/incidents.md'


def recent_incidents(today: dt.date | None = None, ledger: Path | None = None) -> list[tuple[str, str]]:
    """(ID, layer) of every ledger row reported within the last BREAKER_DAYS days."""
    today = today or dt.date.today()
    try:
        text = (ledger or LEDGER).read_text("utf-8")
    except OSError:
        return []
    header: list[str] | None = None
    found = []
    for line in text.split("\n## Incidents", 1)[-1].splitlines():
        if not line.startswith("|"):
            continue
        cells = [cell.strip() for cell in line.strip().strip("|").split("|")]
        if header is None:
            header = cells
            continue
        if set("".join(cells)) <= set("-: "):
            continue
        row = dict(zip(header, cells))
        try:
            age = (today - dt.date.fromisoformat(row.get("Reported", ""))).days
        except ValueError:
            continue
        if 0 <= age < BREAKER_DAYS:
            found.append((row.get("ID", ""), row.get("Layer", "")))
    return found


def breaker_line(recent: list[tuple[str, str]]) -> str | None:
    if len(recent) < BREAKER_ROWS:
        return None
    ids = ", ".join(ident for ident, _ in recent)
    layers = ", ".join(f"{layer} {count}" for layer, count in Counter(layer for _, layer in recent).most_common())
    return (f"risk: breaker ({len(recent)} incidents in the last {BREAKER_DAYS} days: {ids}): until the rate drops "
            f"every tiered change needs {BREAKER_GATE}; tighten first the layers they slipped past ({layers})")


def main(argv: list[str]) -> int:
    if argv == ["--self-check"]:
        dead = dead_patterns()
        for row in dead:
            print(f"{row} matches no tracked file")
        return 1 if dead else 0
    paths = argv or pending_paths()
    hits = tiers_for(paths)
    for name, gates, matched in hits:
        more = f" and {len(matched) - 1} more" if len(matched) > 1 else ""
        print(f"risk: {name} ({matched[0]}{more}) needs {gates}")
    breaker = breaker_line(recent_incidents())
    if hits and breaker:
        print(breaker)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
