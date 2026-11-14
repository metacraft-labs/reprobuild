#!/usr/bin/env python3
"""Generate the command-line contract fixture from the command specification.

Every `repro` command is specified by a page of the command specification: a
Markdown file per command (`<command>.md`), a directory per namespace
(`<namespace>/README.md`), or a section headed with the command
(``### `repro <command>` ``) inside another page. Those pages are the
authoritative interface contract; repro's command-line description
(`libs/repro_cli_support/src/repro_cli_support/cli_description.nim`) is its
implementation. `tests/unit/t_cs_m6_spec_pages_match_declarations.nim` checks
that the two name the same commands, flags and environment variables.

The specification is not part of this repository, so the test cannot read it.
This script reads it and writes what the test compares against,
`tests/fixtures/cli-contract/spec-surface.tsv`, which is committed. Run it
whenever a page or the covered command list changes:

    python3 scripts/generate_cli_contract_fixture.py <directory of the pages>

What it extracts, and from where:

* `verb <word>`: every top-level command the pages specify: a page or a
  namespace directory named after it, or a heading that names `repro <word>`.
* `command <path>`: each command in `COVERED_COMMANDS`, whose flags and
  environment variables the test compares (a command is covered once its
  parsing has moved onto the description).
* `flag <path> <spelling>`: the flags (`--name`, `-x`) the command's page
  or section writes where it states syntax: in a code block, or in the code
  a list item starts with (`` - `--format json|text` — the output format``).
  Code in running prose (``like `--version`, ...``) does not count, because
  prose names other commands' and other tools' flags too.
* `env <path> <NAME>`: the environment variables (`UPPER_CASE` names with an
  underscore) written in any code in the command's page or section. A piece of code that starts with `repro <words>` belongs to the
  command those words name (so `repro --version` in the `version` page is
  the root command's flag); any other piece belongs to the page's command.

`--help` and `-h` are not recorded: every command accepts them, built into the
parser, so neither side lists them.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

# The commands whose flags and environment variables are compared, by their
# words after `repro` ("" is `repro` itself). Each later group of commands is
# added here when its parsing moves onto the description, and the test lists
# the same commands.
COVERED_COMMANDS = [
    "",
    "help",
    "version",
    "completion",
    "capabilities",
    "show-conventions",
]

BUILT_IN_FLAGS = {"--help", "-h"}

FENCE = re.compile(r"^\s*```")
HEADING = re.compile(r"^(#+)\s+(.*)$")
INLINE_CODE = re.compile(r"`([^`\n]+)`")
LONG_FLAG = re.compile(r"(?<![\w-])--[a-z][a-z0-9-]*")
SHORT_FLAG = re.compile(r"(?<![\w-])-[A-Za-z](?![\w-])")
ENV_VAR = re.compile(r"(?<![\w$])[A-Z][A-Z0-9]*(?:_[A-Z0-9]+)+(?![\w])")
COMMAND_WORD = re.compile(r"^[a-z][a-z0-9-]*$")
HEADED_COMMAND = re.compile(r"`repro ([a-z][a-z0-9-]*(?: [a-z][a-z0-9-]*)*)`")


BULLET_LEAD = re.compile(r"^\s*(?:[-*+]|\d+\.)\s+`([^`\n]+)`")


def code_pieces(lines: list[str]) -> list[tuple[str, bool]]:
    """The code in a run of Markdown lines, each with whether it states the
    command's syntax: a line of a code block (a continued line joined to the
    next) or the code a list item starts with (``- `--format json|text` ...``)
    does; any other inline code span (``like `--version`, ...``) is prose."""
    pieces: list[tuple[str, bool]] = []
    in_block = False
    pending = ""
    for line in lines:
        if FENCE.match(line):
            in_block = not in_block
            continue
        if in_block:
            text = pending + line.strip()
            if text.endswith("\\"):
                pending = text[:-1] + " "
                continue
            pending = ""
            pieces.append((text, True))
        else:
            lead = BULLET_LEAD.match(line)
            for i, span in enumerate(INLINE_CODE.findall(line)):
                pieces.append((span, lead is not None and i == 0))
    return pieces


def owner(piece: str, page_command: str, known: set[str]) -> str:
    """The command a piece of code belongs to: the longest known command its
    leading `repro <words>` name, else the page's command."""
    words = piece.split()
    if not words or words[0] != "repro":
        return page_command
    path: list[str] = []
    best = ""
    for word in words[1:]:
        if not COMMAND_WORD.match(word):
            break
        path.append(word)
        if " ".join(path) in known:
            best = " ".join(path)
    if best:
        return best
    # `repro --version`, `repro -V`: the root command's own flags.
    if len(words) > 1 and words[1].startswith("-"):
        return ""
    return page_command if not path else " ".join(path)


def sections(path: Path) -> list[tuple[str, list[str]]]:
    """A page's sections: (heading text, lines), the first one headless."""
    result: list[tuple[str, list[str]]] = [("", [])]
    in_block = False
    for line in path.read_text(encoding="utf-8").splitlines():
        if FENCE.match(line):
            in_block = not in_block
        match = None if in_block else HEADING.match(line)
        if match:
            result.append((match.group(2), []))
        else:
            result[-1][1].append(line)
    return result


def command_regions(pages: Path) -> tuple[set[str], dict[str, list[str]]]:
    """The top-level verbs the pages specify, and for each covered command the
    lines that specify it."""
    verbs: set[str] = set()
    regions: dict[str, list[str]] = {}
    for page in sorted(pages.rglob("*.md")):
        relative = page.relative_to(pages)
        if len(relative.parts) == 1 and page.stem != "README":
            verbs.add(page.stem)
        elif len(relative.parts) == 2 and page.stem == "README":
            verbs.add(relative.parts[0])
        page_command = (page.stem if len(relative.parts) == 1
                        else " ".join(relative.parts[:-1] + (
                            () if page.stem == "README" else (page.stem,))))
        for heading, lines in sections(page):
            headed = HEADED_COMMAND.search(heading)
            if headed:
                command = headed.group(1)
                verbs.add(command.split()[0])
                if command in COVERED_COMMANDS:
                    regions.setdefault(command, []).extend(lines)
                continue
            if page_command in COVERED_COMMANDS:
                regions.setdefault(page_command, []).extend(lines)
    verbs.discard("push-hook-publication-protocol")
    return verbs, regions


def surface(pages: Path) -> list[str]:
    verbs, regions = command_regions(pages)
    known = set(COVERED_COMMANDS)
    flags: dict[str, set[str]] = {c: set() for c in COVERED_COMMANDS}
    envs: dict[str, set[str]] = {c: set() for c in COVERED_COMMANDS}
    for command, lines in regions.items():
        for piece, syntax in code_pieces(lines):
            target = owner(piece, command, known)
            if target not in flags:
                continue
            if syntax:
                for spelling in LONG_FLAG.findall(piece) + SHORT_FLAG.findall(
                        piece):
                    if spelling not in BUILT_IN_FLAGS:
                        flags[target].add(spelling)
            for name in ENV_VAR.findall(piece):
                envs[target].add(name)
    rows = [
        "# The command-line contract the command specification states, for",
        "# tests/unit/t_cs_m6_spec_pages_match_declarations.nim. Generated by",
        "# scripts/generate_cli_contract_fixture.py; do not edit by hand.",
    ]
    rows += [f"verb\t{verb}" for verb in sorted(verbs)]
    for command in COVERED_COMMANDS:
        name = ("repro " + command).strip()
        rows.append(f"command\t{name}")
        rows += [f"flag\t{name}\t{s}" for s in sorted(flags[command])]
        rows += [f"env\t{name}\t{e}" for e in sorted(envs[command])]
    return rows


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("pages", type=Path,
                        help="the directory of command specification pages")
    parser.add_argument("--out", type=Path, default=Path(
        "tests/fixtures/cli-contract/spec-surface.tsv"))
    args = parser.parse_args()
    if not args.pages.is_dir():
        print(f"not a directory: {args.pages}", file=sys.stderr)
        return 2
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text("\n".join(surface(args.pages)) + "\n",
                        encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())
