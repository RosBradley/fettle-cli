#!/usr/bin/env python3
"""Every row of docs/incidents.md names real commits, a known layer and a catcher the code defines.

    python3 scripts/audit_incidents.py [--ledger PATH]

The incident table is the eval set for the review layers (docs/incidents.md
says why and what each layer means). A row fails when its ID repeats, its
Reported cell is not a date, its Fixed commit is missing or does not resolve,
its Introduced commit is neither `unknown` nor a commit, its layer is not one
of LAYERS, or a backticked catcher is defined nowhere: not a Bats test name,
a Go Test function, a Python test function or a file in this repository.

In a shallow clone (the Check and Validation workflows check out one commit)
the commits cannot be resolved and are only shape-checked, which the output
says; the Security Checks job checks out full history and resolves them.
"""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]
LEDGER = PROJECT_ROOT / "docs" / "incidents.md"
LAYERS = ("write-time", "check", "unit", "compat", "review", "e2e", "release", "field")
COLUMNS = ["ID", "Reported", "Symptom", "Introduced", "Fixed", "Layer", "Caught by"]
SHA = re.compile(r"^[0-9a-f]{7,40}$")
BATS_TEST = re.compile(r"""^\s*@test\s+(?:"((?:[^"\\]|\\.)*)"|'([^']*)')\s*\{""")
GO_TEST = re.compile(r"^func\s+(Test[A-Za-z0-9_]*)\s*\(", re.MULTILINE)
PY_TEST = re.compile(r"^\s*def\s+(test_[A-Za-z0-9_]*)\s*\(", re.MULTILINE)
SKIP_PARTS = {".git", "node_modules"}


def _source_files(directory: str, pattern: str):
    base = PROJECT_ROOT / directory
    if not base.is_dir():
        return
    for path in sorted(base.rglob(pattern)):
        parts = path.relative_to(PROJECT_ROOT).parts
        if SKIP_PARTS.intersection(parts) or any(part.startswith("tmp-") for part in parts):
            continue
        yield path


def defined_catchers() -> set[str]:
    names: set[str] = set()
    for path in _source_files("tests", "*.bats"):
        for line in path.read_text("utf-8", errors="replace").splitlines():
            match = BATS_TEST.match(line)
            if match:
                name = match.group(1) if match.group(1) is not None else match.group(2)
                names.add(re.sub(r"\\(.)", r"\1", name))
    for directory in ("cmd", "internal"):
        for path in _source_files(directory, "*_test.go"):
            names.update(GO_TEST.findall(path.read_text("utf-8", errors="replace")))
    for directory in ("tests", "scripts"):
        for path in _source_files(directory, "*.py"):
            names.update(PY_TEST.findall(path.read_text("utf-8", errors="replace")))
    return names


def is_defined(catcher: str, defined: set[str]) -> bool:
    if catcher in defined:
        return True
    # A gate script or test file named by its repository path.
    return "/" in catcher and (PROJECT_ROOT / catcher).is_file()


def rows(text: str):
    """The table under '## Incidents' as (line number, cells), header and rule excluded."""
    section = False
    for number, line in enumerate(text.splitlines(), 1):
        if line.startswith("## "):
            section = line.strip() == "## Incidents"
            continue
        if section and line.startswith("|"):
            cells = [cell.strip() for cell in line.strip().strip("|").split("|")]
            if cells == COLUMNS or set("".join(cells)) <= set("-: "):
                continue
            yield number, cells


def is_shallow() -> bool:
    out = subprocess.run(
        ["git", "-C", str(PROJECT_ROOT), "rev-parse", "--is-shallow-repository"],
        capture_output=True,
        text=True,
    )
    return out.stdout.strip() == "true"


def resolves(sha: str) -> bool:
    return (
        subprocess.run(
            ["git", "-C", str(PROJECT_ROOT), "cat-file", "-e", sha + "^{commit}"],
            capture_output=True,
        ).returncode
        == 0
    )


def problems(text: str, label: str, defined: set[str], check_commits: bool) -> list[str]:
    found: list[str] = []
    seen: set[str] = set()
    for number, cells in rows(text):
        where = f"{label}:{number}"
        if len(cells) != len(COLUMNS):
            found.append(f"{where}: expected {len(COLUMNS)} cells, found {len(cells)}")
            continue
        row = dict(zip(COLUMNS, cells))
        if row["ID"] in seen:
            found.append(f"{where}: {row['ID']} repeats")
        seen.add(row["ID"])
        if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", row["Reported"]):
            found.append(f"{where}: Reported is not a date: {row['Reported']}")
        for column, optional in (("Fixed", False), ("Introduced", True)):
            value = row[column]
            if optional and value == "unknown":
                continue
            if not SHA.match(value):
                found.append(f"{where}: {column} is not a commit: {value}")
            elif check_commits and not resolves(value):
                found.append(f"{where}: {column} {value} does not resolve")
        if row["Layer"] not in LAYERS:
            found.append(f"{where}: layer {row['Layer']} is not one of {', '.join(LAYERS)}")
        catchers = re.findall(r"`([^`]+)`", row["Caught by"])
        if not catchers:
            found.append(f"{where}: no catcher named")
        found.extend(
            f"{where}: catcher `{name}` is not a test or gate in this repository"
            for name in catchers
            if not is_defined(name, defined)
        )
    return found


def main(argv: list[str]) -> int:
    ledger = LEDGER
    if len(argv) == 2 and argv[0] == "--ledger":
        ledger = Path(argv[1]).resolve()
    elif argv:
        print("usage: audit_incidents.py [--ledger PATH]", file=sys.stderr)
        return 2
    text = ledger.read_text("utf-8")
    try:
        label = str(ledger.relative_to(PROJECT_ROOT))
    except ValueError:
        label = str(ledger)
    shallow = is_shallow()
    found = problems(text, label, defined_catchers(), check_commits=not shallow)
    for row in found:
        print(row)
    if found:
        return 1
    note = ", commits shape-checked only (shallow clone)" if shallow else ""
    print(f"incidents-audit-ok rows={sum(1 for _ in rows(text))}{note}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
