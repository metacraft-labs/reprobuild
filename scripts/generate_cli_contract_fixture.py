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
* `flag <path> <spelling>`: the flags (`--name`, `-x`, `-xx`) the command's page
  or section writes where it states syntax: in a code block, or in the code
  a list item starts with (`` - `--format json|text` — the output format``).
  Code in running prose (``like `--version`, ...``) does not count, because
  prose names other commands' and other tools' flags too.
* `env <path> <NAME>`: the environment variables that are inputs of the
  command's command line: those a flag's list item names in an
  `environment:` clause (`` - `--daemon VALUE` — ...; environment:
  `REPRO_DAEMON`. ``), the form the pages use for a variable that supplies a
  flag's value when the flag is absent. Every other upper-case name a page
  writes as code (a variable the command reads below its command line, one it
  carries to the actions it runs, an ELF header field, a C constant) is prose
  about what the command does, not an input of its command line, so it is not
  recorded.

A piece of code that starts with `repro <words>` belongs to the command those
words name (so `repro --version` in the `version` page is the root command's
flag); a piece that starts with a subcommand word of the page's command
(`update ...` in the `lock` page) belongs to that subcommand; any other piece
belongs to the page's command. A list item's `environment:` clause belongs to
the command its leading code does.

`--help` and `-h` are not recorded: every command accepts them, built into the
parser, so neither side lists them.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

# The commands whose flags and environment variables are compared, by their
# words after `repro` ("" is `repro` itself): every command repro declares
# (its hidden spellings aside). The test lists the same commands, and checks
# that its list is every command the description declares.
COVERED_COMMANDS = [
    "",
    "help",
    "version",
    "completion",
    "capabilities",
    "show-conventions",
    "configs",
    "tasks",
    "graph",
    "why",
    "deps",
    "deps refresh",
    "stats",
    "daemon",
    "store",
    "store gc",
    "store recover",
    "store roots",
    "store list",
    "store optimise",
    "store materialize",
    "store closure",
    "store export",
    "store import",
    "store copy",
    "store daemon",
    "store serve",
    "cas",
    "cas gc",
    "cas verify",
    "cas path",
    "cas exists",
    "cache",
    "cache lookup",
    "cache substitute",
    "cache publish",
    "cache derive-key",
    "cache gen-key",
    "bundle",
    "bundle create",
    "bundle publish",
    "bundle restore",
    "bundle inspect",
    "reap",
    "launch-plan",
    "launch-plan show",
    "launch-plan id",
    "cert-signer",
    "cert-signer serve",
    "cert-signer registration",
    "self",
    "self install",
    "self provision",
    "self hold",
    "self which",
    "self list",
    "self prune-roots",
    "home",
    "home add",
    "home remove",
    "home enable",
    "home disable",
    "home list",
    "home why",
    "home history",
    "home apply",
    "home plan",
    "home export",
    "home facts",
    "home compare",
    "home rollback",
    "home gc",
    "home set",
    "home get",
    "home adopt",
    "home resource",
    "home resource move",
    "home migrate-from-env-scripts",
    "system",
    "system add",
    "system remove",
    "system list",
    "system why",
    "system plan",
    "system apply",
    "system sync",
    "system history",
    "system rollback",
    "system audit",
    "infra",
    "infra plan",
    "infra apply",
    "infra cache-keys",
    "infra install-root",
    "infra image",
    "anywhere",
    "deploy-agent",
    "deploy-agent keygen",
    "deploy-agent compile-profile",
    "hardware",
    "hardware probe",
    "disk",
    "disk plan",
    "disk apply",
    "disk mount",
    "disk unmount",
    "disk generate",
    "disk image",
    "cargo",
    "cargo gc",
    "cargo record-live",
    "cargo run",
    "health",
    "debug",
    "debug artifact",
    "exec",
    "run",
    "shell",
    "shell hook",
    "allow",
    "deny",
    "dev-env",
    "dev-env export",
    "dev-env deactivate",
    "up",
    "down",
    "dev",
    "hcr",
    "hcr coordinate",
    "hcr prepare-object",
    "prompt",
    "prompt init",
    "workspace",
    "workspace restore",
    "workspace init",
    "workspace bootstrap",
    "workspace enable",
    "workspace disable",
    "workspace sets",
    "workspace sets list",
    "workspace sets resolve",
    "workspace sets add",
    "workspace sets remove",
    "workspace projects",
    "workspace projects list",
    "workspace projects resolve",
    "workspace projects add",
    "workspace projects remove",
    "workspace repos",
    "workspace repos list",
    "workspace repos add",
    "workspace repos remove",
    "workspace add",
    "workspace remove",
    "workspace status",
    "workspace lock",
    "workspace list",
    "workspace manifests",
    "workspace branch-roles",
    "workspace forall",
    "workspace shared-clones",
    "workspace sync",
    "workspace pull",
    "workspace new",
    "workspace switch",
    "workspace provision",
    "workspace migrate",
    "workspace migrate-locks",
    "workspace publish-evidence",
    "sync",
    "pull",
    "branch",
    "switch",
    "push",
    "check",
    "hooks",
    "hooks ensure",
    "hooks reinstall",
    "hooks uninstall",
    "lock",
    "lock list",
    "lock solve",
    "lock refresh",
    "lock update",
    "lock validate",
    "lock diff",
    "lock explain",
    "locking",
    "locking explain",
    "locking adopt-manifest",
    "gateway",
    "gateway pre-receive",
    "gateway post-receive",
    "gateway migrate",
    "add",
    "remove",
    "develop",
    "flake",
    "flake override-args",
    "flake refresh-lock",
    "flake override-status",
    "build",
    "bench",
    "lint",
    "clean",
    "test",
    "certify",
    "certificates",
    "certificates list",
    "certificates plan",
    "certificates policy",
    "ci",
    "ci plan",
    "watch",
    "attest",
    "attest expect",
    "attest challenge",
    "attest verify",
    "attest cross-check",
    "attest launch",
    "attest reap",
    # Every other command repro declares (round 8b): the list is every
    # command, hidden spellings aside.
    "daemon serve",
    "daemon start",
    "daemon status",
    "daemon stop",
    "daemon restart",
    "daemon sessions",
    "daemon logs",
    "store daemon start",
    "store daemon status",
    "store daemon stop",
    "home __build-bundle",
    "home __receive-bundle",
    "home __transfer-bundle",
    "home __remote-activate",
    "system addon",
    "system state",
    "system secret",
    "system adopt",
    "debug io",
    "debug io monitor",
    "hooks protocol",
    "hooks dispatch",
    "hooks cache-push",
    "pressure",
    "internal",
    "internal shared-pool-upload-pack",
    "internal resolve-package",
    "internal io",
    "internal io monitor",
    "internal runquota-helper",
    "internal compile-provider",
    "internal extract-interface",
    "internal compile-profile",
    "internal probe-profile-platforms",
    "internal dev-env-introspect",
    "internal render-dev-env-shell",
    "internal direnv-activate",
    "internal native-shell-activate",
    "internal dev-session-supervisor",
    "internal dev-session-http",
    "internal cmake-regenerate",
    "catalog",
    "catalog publish",
]

BUILT_IN_FLAGS = {"--help", "-h"}

FENCE = re.compile(r"^\s*```")
HEADING = re.compile(r"^(#+)\s+(.*)$")
INLINE_CODE = re.compile(r"`([^`\n]+)`")
LONG_FLAG = re.compile(r"(?<![\w-])--[a-z][a-z0-9-]*")
# A short spelling: one letter, or one letter doubled (`-vv`, which `repro
# build` declares beside `-v`).
SHORT_FLAG = re.compile(r"(?<![\w-])-([A-Za-z])\1?(?![\w-])")
# A list item's `environment:` clause: the code spans after it, up to the
# end of the item, each one variable name. Inside the clause a name needs no
# underscore (`SHELL`): the clause says the code is a variable.
ENV_CLAUSE = re.compile(r"\benvironment:\s*((?:`[A-Z][A-Z0-9]*(?:_[A-Z0-9]+)*`"
                        r"(?:\s*,\s*|\s+and\s+)?)+)")
ENV_NAME = re.compile(r"`([A-Z][A-Z0-9]*(?:_[A-Z0-9]+)*)`")
# A command word; an internal step may start with `__` (`home __build-bundle`).
COMMAND_WORD = re.compile(r"^(?:__)?[a-z][a-z0-9-]*$")
HEADED_COMMAND = re.compile(
    r"`repro ([a-z][a-z0-9-]*(?: (?:__)?[a-z][a-z0-9-]*)*)`")


BULLET_LEAD = re.compile(r"^\s*(?:[-*+]|\d+\.)\s+`([^`\n]+)`")
BULLET = re.compile(r"^(\s*)(?:[-*+]|\d+\.)\s+")


def flag_items(lines: list[str]) -> list[tuple[str, str]]:
    """The list items outside code blocks whose leading code states a flag,
    each as (its leading code, its whole text with continuation lines
    joined)."""
    items: list[tuple[str, str]] = []
    in_block = False
    current: list[str] | None = None
    lead = ""
    indent = 0

    def close() -> None:
        nonlocal current
        if current is not None:
            items.append((lead, " ".join(current)))
        current = None

    for line in lines:
        if FENCE.match(line):
            close()
            in_block = not in_block
            continue
        if in_block:
            continue
        bullet = BULLET.match(line)
        if bullet:
            close()
            first = BULLET_LEAD.match(line)
            if first and (LONG_FLAG.search(first.group(1)) or
                          SHORT_FLAG.search(first.group(1))):
                lead = first.group(1)
                indent = len(bullet.group(1))
                current = [line.strip()]
            continue
        if current is not None:
            stripped = line.strip()
            if stripped and len(line) - len(line.lstrip()) > indent:
                current.append(stripped)
            else:
                close()
    close()
    return items


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
    if not words:
        return page_command
    if words[0] != "repro":
        # A namespace page that lists its verbs writes them without the
        # `repro <namespace>` prefix (`` `update <dependency> [--to <rev>]` ``
        # in the `lock` page): such a piece belongs to that subcommand.
        path = page_command.split() if page_command else []
        best = ""
        for word in words:
            if not COMMAND_WORD.match(word):
                break
            path.append(word)
            if " ".join(path) in known:
                best = " ".join(path)
        return best or page_command
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
                for spelling in LONG_FLAG.findall(piece) + [
                        m.group(0) for m in SHORT_FLAG.finditer(piece)]:
                    if spelling not in BUILT_IN_FLAGS:
                        flags[target].add(spelling)
        for lead, text in flag_items(lines):
            target = owner(lead, command, known)
            if target not in envs:
                continue
            for clause in ENV_CLAUSE.findall(text):
                for name in ENV_NAME.findall(clause):
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
