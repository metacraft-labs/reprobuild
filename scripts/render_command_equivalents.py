#!/usr/bin/env python3
"""Render docs/users/content/reference/command-equivalents.md from its data file.

The page's table is a generated region: everything between

    <!-- generated:begin command-equivalents -->
    <!-- generated:end -->

is produced from docs/users/data/command-equivalents.toml and never edited by
hand.

Usage:
    python3 scripts/render_command_equivalents.py          # rewrite the region
    python3 scripts/render_command_equivalents.py --check  # exit 1 if stale

The check also refuses a row whose `repro` command names a top-level verb the
CLI does not dispatch. Until `repro` can describe its own command line in a
machine-readable form, the verb list is read from the dispatcher in
libs/repro_cli_support/src/repro_cli_support.nim (its `args[0] == "<verb>"`
tests). That catches a verb that does not exist; it cannot catch a subcommand
or a flag that does not exist, which needs the CLI model.
"""

from __future__ import annotations

import pathlib
import re
import sys
import tomllib

ROOT = pathlib.Path(__file__).resolve().parent.parent
DATA = ROOT / "docs/users/data/command-equivalents.toml"
PAGE = ROOT / "docs/users/content/reference/command-equivalents.md"
DISPATCHER = ROOT / "libs/repro_cli_support/src/repro_cli_support.nim"

BEGIN = "<!-- generated:begin command-equivalents -->"
END = "<!-- generated:end -->"


def dispatched_verbs() -> set[str]:
    """Top-level verbs the dispatcher tests for, plus the `ws` alias."""
    text = DISPATCHER.read_text(encoding="utf-8")
    verbs = set(re.findall(r'args\[0\] == "([a-z][a-z-]*)"', text))
    verbs.add("ws")
    return verbs


def cell(text: str) -> str:
    """A table cell: code-formatted command, pipes escaped."""
    return "`" + text.replace("|", "\\|") + "`" if text else "—"


def render(data: dict) -> str:
    out: list[str] = []
    for tool in data["tool"]:
        out.append(f"## {tool['title']}")
        out.append("")
        out.append(f"| {tool['title']} | reprobuild | Note |")
        out.append("|---|---|---|")
        for row in tool["row"]:
            theirs = ", ".join(cell(p.strip()) for p in row["theirs"].split(", "))
            out.append(f"| {theirs} | {cell(row['repro'])} | {row.get('note', '')} |")
        out.append("")
    return "\n".join(out).rstrip() + "\n"


def unknown_verbs(data: dict, verbs: set[str]) -> list[str]:
    problems = []
    for tool in data["tool"]:
        for row in tool["row"]:
            command = row["repro"]
            if not command:
                continue
            # `eval "$(repro shell hook bash)"` and plain `repro build` both work.
            match = re.search(r"\brepro\s+([a-z][a-z-]*)", command)
            if not match or match.group(1) not in verbs:
                problems.append(f"{tool['id']}: {command!r} names no dispatched verb")
    return problems


def main(argv: list[str]) -> int:
    check = "--check" in argv
    data = tomllib.loads(DATA.read_text(encoding="utf-8"))
    problems = unknown_verbs(data, dispatched_verbs())
    for problem in problems:
        print(f"command-equivalents: {problem}", file=sys.stderr)
    page = PAGE.read_text(encoding="utf-8")
    start = page.index(BEGIN) + len(BEGIN)
    stop = page.index(END, start)
    wanted = page[:start] + "\n" + render(data) + page[stop:]
    if check:
        if wanted != page:
            print("command-equivalents: the page is stale; run "
                  "scripts/render_command_equivalents.py", file=sys.stderr)
            return 1
        return 1 if problems else 0
    PAGE.write_text(wanted, encoding="utf-8")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
