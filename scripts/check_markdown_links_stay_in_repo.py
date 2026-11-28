#!/usr/bin/env python3
"""Refuse a relative Markdown link whose target lies outside this repository.

WHY THIS EXISTS
===============

This repository is public and is read on its own: on its hosting site, in a
plain clone, in a source tarball. A relative link such as
``[the plan](../../some-sibling/plan.md)`` resolves only in a checkout that
happens to have that sibling directory next to this one. Everywhere else it is
a broken link, and when the sibling is a private repository it is also a
pointer to a place the reader is not allowed to go, naming files that were
never meant to be published.

The organisation's policy on public documentation says so directly: a public
document must not link to, name the path of, or cite a private specification;
it should state what the reader needs in the document itself ("rewrite rather
than link"); and every Markdown hyperlink must resolve to a public URL or to a
file inside the public repository. A relative link that leaves the repository
root fails that last rule whatever it points at, so this lint refuses all of
them. A link to another PUBLIC repository is written as that repository's
public URL instead.

WHAT THIS IS
============

A ZERO-TOLERANCE gate, not a ratchet: there is no baseline. Every finding
fails the run. (Contrast ``check_private_pm_references.py``, which pins a
large existing population and only stops it growing.)

WHAT IS SCANNED
===============

TRACKED Markdown files only (``*.md``, ``*.markdown`` from ``git ls-files``),
read from the working tree, so an edit is judged before it is committed and an
untracked or ignored file is never judged. Excluded: everything under the
top-level ``references/`` (third-party trees vendored to cite, never modified)
and every path with a ``vendor`` component (third-party source).

WHAT COUNTS AS A LINK
=====================

  * Inline links and images, ``[text](target)`` and ``![alt](target)``,
    including the angle-bracket form ``[text](<target with spaces>)`` and link
    text that spans several lines (only the ``](`` that opens the destination
    is anchored on, so the text can be anything).
  * Reference definitions, ``[id]: target`` at the start of a line, in either
    form, including one inside a block quote or a list item (``> [id]: ...``,
    ``- [id]: ...``): CommonMark allows a definition in any container block.
    Indentation is not limited to three spaces, so an indented code block
    that shows a definition is judged too; a false refusal there costs a
    rewrite, a false pass would cost the gate.
  * Raw HTML ``href`` and ``src`` attributes (``<a href="...">``,
    ``<img src="...">``, quoted or not). GitHub renders them as links.

NOT judged:

  * Anything inside a fenced code block (```` ``` ```` or ``~~~``) or an
    inline code span. Those are examples and prose about links, not links.
    A code span is masked only when it closes on the line it opens on.
    CommonMark lets one continue onto the next line of the same paragraph,
    but this lint does not parse blocks, so it cannot tell that line from the
    next list item, table row or heading; a stray backtick there would
    otherwise hide every link up to the next backtick.
  * A target with a URL scheme (``https:``, ``mailto:``, ...) or a
    protocol-relative ``//host`` target: it does not resolve against the file.
  * A pure ``#anchor`` target.
  * A ``/rooted`` target: hosting sites resolve it against the repository
    root, so it cannot leave the repository.

HOW A TARGET IS RESOLVED
========================

The fragment (``#...``) and query (``?...``) are dropped, percent-escapes are
decoded, and the rest is joined to the linking file's directory and normalised
lexically (``posixpath.normpath``; symbolic links are not followed). A result
that starts with ``..`` has left the repository root and is a finding. A
target that stays inside the repository but names a file that does not exist
is NOT this lint's business.

OUTPUT AND EXIT CODES
=====================

One ``path:line: target`` line per finding on stderr, followed by the remedy.
``line`` is the 1-based line of the link destination.

  0 -- no finding.
  1 -- at least one finding, OR the scan failed (``git`` is missing or the
       directory is not a checkout), OR it saw fewer tracked Markdown files
       than ``MARKDOWN_FILE_FLOOR`` -- a scan that saw nothing finds nothing,
       and must not read as a pass.

USAGE
=====

  scripts/check_markdown_links_stay_in_repo.py
      [--markdown-file-floor N]   # lower the anti-vacuity floor; for this
                                  # lint's own test only

As a library: ``find_escaping_links(text, path)`` judges one document,
``tracked_markdown_files(root)`` lists the corpus, ``scan(root)`` does both,
and ``main(argv)`` returns the exit code.
"""

from __future__ import annotations

import argparse
import dataclasses
import pathlib
import posixpath
import re
import subprocess
import sys
import urllib.parse

SCRIPT = pathlib.Path(__file__).resolve()
ROOT = SCRIPT.parent.parent

MARKDOWN_SUFFIXES = (".md", ".markdown")

# Measured 305 tracked Markdown files (one under references/, four under a
# vendor/ component) at 5ca03a195. A floor, not a pin: it tells "the tree is
# clean" from "the scan saw nothing".
MARKDOWN_FILE_FLOOR = 150

REMEDY = (
    "A relative link must resolve to a file inside this repository. State the "
    "fact the reader needs in the document itself (rewrite rather than link), "
    "or, for another public repository, link to its public URL."
)


@dataclasses.dataclass(frozen=True)
class Finding:
    """One relative link that escapes the repository root."""

    path: str
    line: int
    target: str

    def __str__(self) -> str:
        return f"{self.path}:{self.line}: {self.target}"


class ScanError(Exception):
    """The scan could not be trusted; never to be read as "no findings"."""


# ---------------------------------------------------------------------------
# Masking the parts of a document that are not links
# ---------------------------------------------------------------------------

# A fence opener: up to three spaces, then three or more backticks or tildes.
# CommonMark: https://spec.commonmark.org/0.31.2/#fenced-code-blocks
_FENCE = re.compile(r"^ {0,3}(`{3,}|~{3,})")

# An inline code span: a run of N backticks, the shortest content, and a run
# of exactly N backticks, on one line. CommonMark lets a span continue onto
# the next line of its paragraph, but without a block parser that line cannot
# be told from the next list item or table row, and an unmatched backtick
# would then mask the real links up to the next backtick. Keeping spans to one
# line can only make this lint judge more, never less.
# https://spec.commonmark.org/0.31.2/#code-spans
_CODE_SPAN = re.compile(r"(?<!`)(`+)(?!`)([^\n]+?)(?<!`)\1(?!`)")


def _blank(text: str) -> str:
    """Replace every character but newlines with a space, keeping offsets."""
    return re.sub(r"[^\n]", " ", text)


def mask_code(text: str) -> str:
    """Return ``text`` with fenced code blocks and code spans blanked out.

    Offsets and line numbers are preserved, so a match in the result is
    reported at its position in the original document.
    """
    lines = text.split("\n")
    fence: str | None = None
    for index, line in enumerate(lines):
        if fence is None:
            opener = _FENCE.match(line)
            if opener:
                fence = opener.group(1)
                lines[index] = _blank(line)
        else:
            closer = _FENCE.match(line)
            if (
                closer
                and closer.group(1)[0] == fence[0]
                and len(closer.group(1)) >= len(fence)
                and line.strip() == closer.group(1)
            ):
                fence = None
            lines[index] = _blank(line)
    masked = "\n".join(lines)
    return _CODE_SPAN.sub(lambda m: _blank(m.group(0)), masked)


# ---------------------------------------------------------------------------
# Finding link destinations
# ---------------------------------------------------------------------------

# The destination of an inline link or image: after "](" and optional
# whitespace (a newline included), either <...> or a run without whitespace
# that may hold one level of balanced parentheses.
# https://spec.commonmark.org/0.31.2/#link-destination
_INLINE = re.compile(
    r"\]\(\s*(?:<(?P<angle>[^<>\n]*)>|(?P<bare>(?:[^\s()<]|\([^\s()]*\))+))"
)

# A link reference definition at the start of a line, after any indentation
# and any block-quote or list-item markers (a definition may sit in any
# container block).
# https://spec.commonmark.org/0.31.2/#link-reference-definitions
_REFERENCE = re.compile(
    r"^[ \t]*(?:(?:>|[-*+]|\d{1,9}[.)])[ \t]*)*"
    r"\[(?:[^\]\\]|\\.)+\]:[ \t]*\n?[ \t]*(?:<(?P<angle>[^<>\n]*)>|(?P<bare>\S+))",
    re.M,
)

# A raw HTML href or src attribute, double-quoted, single-quoted or unquoted.
# https://spec.commonmark.org/0.31.2/#raw-html
_HTML_ATTRIBUTE = re.compile(
    r"<[A-Za-z][A-Za-z0-9-]*\b[^>]*?\s(?:href|src)\s*=\s*"
    r"(?:\"(?P<dq>[^\"]*)\"|'(?P<sq>[^']*)'|(?P<bare>[^\s\"'=<>`]+))",
    re.I,
)

_SCHEME = re.compile(r"^[A-Za-z][A-Za-z0-9+.-]*:")


def link_destinations(text: str) -> list[tuple[int, str]]:
    """Every link destination in ``text`` as ``(offset, target)``, code excluded."""
    masked = mask_code(text)
    found = []
    for pattern in (_INLINE, _REFERENCE, _HTML_ATTRIBUTE):
        for match in pattern.finditer(masked):
            group = next(
                name for name, value in match.groupdict().items() if value is not None
            )
            found.append((match.start(group), match.group(group)))
    return sorted(found)


def escapes_root(document: str, target: str) -> bool:
    """Whether ``target``, linked from root-relative ``document``, leaves the root."""
    if not target or target.startswith("#") or target.startswith("/"):
        return False
    if _SCHEME.match(target):
        return False
    path = urllib.parse.unquote(re.split(r"[#?]", target, maxsplit=1)[0])
    if not path:
        return False
    resolved = posixpath.normpath(posixpath.join(posixpath.dirname(document), path))
    return resolved == ".." or resolved.startswith("../")


def find_escaping_links(text: str, document: str) -> list[Finding]:
    """Judge one document. ``document`` is its root-relative POSIX path."""
    findings = []
    for offset, target in link_destinations(text):
        if escapes_root(document, target):
            line = text.count("\n", 0, offset) + 1
            findings.append(Finding(document, line, target))
    return findings


# ---------------------------------------------------------------------------
# The corpus
# ---------------------------------------------------------------------------


def is_excluded(document: str) -> bool:
    """Third-party trees: top-level ``references/`` and any ``vendor`` component."""
    parts = document.split("/")
    return parts[0] == "references" or "vendor" in parts[:-1]


def tracked_markdown_files(root: pathlib.Path) -> list[str]:
    """Root-relative paths of the tracked Markdown files this lint judges."""
    try:
        listed = subprocess.run(
            ["git", "-C", str(root), "ls-files", "-z"], capture_output=True
        )
    except OSError as error:
        raise ScanError(f"cannot run git: {error}") from error
    if listed.returncode != 0:
        raise ScanError(
            f"`git ls-files` failed (exit {listed.returncode}): "
            f"{listed.stderr.decode(errors='replace').strip()}"
        )
    names = [
        name.decode("utf-8", errors="surrogateescape")
        for name in listed.stdout.split(b"\0")
        if name
    ]
    return sorted(
        name
        for name in names
        if name.lower().endswith(MARKDOWN_SUFFIXES) and not is_excluded(name)
    )


def scan(root: pathlib.Path) -> tuple[list[Finding], int]:
    """Judge every tracked Markdown file. Returns ``(findings, files_scanned)``.

    A tracked file missing from the working tree (deleted, not yet staged) is
    skipped: what a commit would carry is then its deletion.
    """
    findings: list[Finding] = []
    scanned = 0
    for document in tracked_markdown_files(root):
        path = root / document
        if not path.is_file():
            continue
        text = path.read_text(encoding="utf-8", errors="replace")
        scanned += 1
        findings.extend(find_escaping_links(text, document))
    return findings, scanned


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Refuse a relative Markdown link that leaves the repository "
        "(see the module docstring)."
    )
    # For this lint's own test, which runs the script in a scratch repository
    # of a handful of files. Never passed by the `lint` recipe.
    parser.add_argument(
        "--markdown-file-floor", type=int, default=MARKDOWN_FILE_FLOOR,
        help=argparse.SUPPRESS,
    )
    arguments = parser.parse_args(argv)

    try:
        findings, scanned = scan(ROOT)
    except ScanError as error:
        print(f"error: {error}", file=sys.stderr)
        print("       Refusing rather than reading a failed scan as a pass.", file=sys.stderr)
        return 1

    if scanned < arguments.markdown_file_floor:
        print(
            f"error: only {scanned} tracked Markdown files, floor "
            f"{arguments.markdown_file_floor}. Refusing rather than reading a "
            f"scan this small as a pass.",
            file=sys.stderr,
        )
        return 1

    if findings:
        for finding in findings:
            print(finding, file=sys.stderr)
        print("", file=sys.stderr)
        print(
            f"check_markdown_links_stay_in_repo: {len(findings)} relative link(s) "
            f"leave the repository. {REMEDY}",
            file=sys.stderr,
        )
        return 1

    print(
        f"check_markdown_links_stay_in_repo: {scanned} tracked Markdown files; "
        f"no relative link leaves the repository."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
