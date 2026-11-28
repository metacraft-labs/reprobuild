#!/usr/bin/env python3
"""Refuse a relative Markdown link whose target is not in this repository.

WHY THIS EXISTS
===============

A relative link in a Markdown file is a claim: "the document I mean is at this
path, next to me". GitHub, an editor and a reader with a checkout all follow
it as a path inside this repository. When nothing is tracked at that path the
link is dead for every reader, and it usually means one of two things:

  * the target was a design document that never lived in this public
    repository -- it was written next to the private planning documents and
    copied here with its relative links intact -- so the link names a file
    that a public reader cannot have and that is not where the link says in
    any case; or
  * the target was moved or renamed and the link was not updated.

Either way the fix is in the document: state the fact the link was meant to
supply, in words a reader of this repository can check, or point the link at
the file that now carries it. This gate keeps the population at zero.

ITS SIBLING, AND WHAT THE TWO SHARE
===================================

``check_markdown_links_stay_in_repo.py`` refuses a relative link that LEAVES
the repository root; this gate refuses one that stays inside it and names a
path nothing is tracked at. Between them every relative link is judged once.
They must agree on what a link is, so this gate takes the corpus
(``tracked_markdown_files``) and the link destinations (``link_destinations``:
inline links and images, link text spanning lines, reference definitions in
any container block, raw HTML ``href``/``src``; fenced code and code spans
excluded) from that module rather than parsing Markdown a second time. Read
its header for those rules.

WHAT IS CHECKED HERE
====================

A destination is checked when it is a relative path: no URL scheme
(``https:``, ``mailto:`` ...), not ``//host``, not a bare ``#anchor``. The
``#fragment`` and ``?query`` are dropped and percent-escapes decoded. A target
starting with ``/`` is taken from the repository root, as GitHub renders it;
any other from the linking file's directory. The link passes when the
resolved path is a TRACKED file or a directory that holds one: an untracked
file in a working checkout is not something a reader of the repository has.

WHAT IS NOT CHECKED, AND WHY
============================

  * A target that resolves outside the repository: the sibling gate's.
  * A footnote definition (``[^1]: text``, GitHub Flavored Markdown). Its
    text is prose, and the shared reference-definition pattern would read its
    first word as a target.
  * Anchors. Whether ``#heading`` names a heading is a rendering question
    this gate does not answer; ``just check-links`` answers it for the
    published site under ``docs/users/``.
  * A tracked SYMLINK (git mode 120000). Its text is the text of the file it
    points at, which is checked at its own path, where its relative links
    are written to resolve; ``.agents/AGENTS.md -> ../AGENTS.md`` is one.

Exit status: 0 when every checked link resolves, 1 when any does not (each
one is printed as ``file:line: target``), 2 when git itself fails.
"""

from __future__ import annotations

import posixpath
import re
import subprocess
import sys
from pathlib import Path
from urllib.parse import unquote

sys.path.insert(0, str(Path(__file__).resolve().parent))
import check_markdown_links_stay_in_repo as shared  # noqa: E402

# A URL scheme per RFC 3986 section 3.1: a letter, then letters, digits, "+",
# "-" or ".", then ":". Anything carrying one is not a repository path.
SCHEME = re.compile(r"^[A-Za-z][A-Za-z0-9+.-]*:")

# A footnote definition, "[^label]:" and the whitespace after it, after the
# container markers the shared reference pattern also allows. Group "text"
# starts where that pattern would read a destination.
FOOTNOTE_DEFINITION = re.compile(
    r"^[ \t]*(?:(?:>|[-*+]|\d{1,9}[.)])[ \t]*)*\[\^[^\]]*\]:[ \t]*(?P<text>)",
    re.M,
)


def repository_path(document: str, target: str) -> str | None:
    """The repository-relative path a target names, or None when unchecked."""
    if not target or target.startswith("#") or target.startswith("//"):
        return None
    if SCHEME.match(target):
        return None
    path = unquote(re.split(r"[#?]", target, maxsplit=1)[0])
    if not path:
        return None
    if path.startswith("/"):
        joined = path.lstrip("/")
    else:
        joined = posixpath.join(posixpath.dirname(document), path)
    resolved = posixpath.normpath(joined)
    if resolved == ".":
        return ""
    if resolved == ".." or resolved.startswith("../"):
        return None
    return resolved


def link_targets(text: str):
    """Yield (line number, target) for every link destination outside code."""
    # Only the word the reference pattern takes as a footnote's destination is
    # dropped; a real link written inside the footnote's text is still judged.
    footnote_text = {match.start("text") for match in FOOTNOTE_DEFINITION.finditer(text)}
    for offset, target in shared.link_destinations(text):
        if offset in footnote_text:
            continue
        yield text.count("\n", 0, offset) + 1, target


def tracked_entries(root: Path) -> dict[str, bool]:
    """Every tracked path, with whether git records it as a symlink."""
    result = subprocess.run(
        ["git", "-C", str(root), "ls-files", "-s", "-z"],
        capture_output=True,
        check=False,
    )
    if result.returncode != 0:
        sys.stderr.write(result.stderr.decode(errors="replace"))
        raise SystemExit(2)
    entries = {}
    for record in result.stdout.decode(errors="surrogateescape").split("\0"):
        if not record:
            continue
        # "<mode> <object> <stage>\t<path>"; a conflicted path has several
        # stages, so a dict keeps one entry per path.
        meta, path = record.split("\t", 1)
        entries[path] = meta.split(" ", 1)[0] == "120000"
    return entries


def broken_links(root: Path) -> list[tuple[str, int, str]]:
    entries = tracked_entries(root)
    known = set(entries)
    for path in entries:
        parent = posixpath.dirname(path)
        while parent and parent not in known:
            known.add(parent)
            parent = posixpath.dirname(parent)
    known.add("")
    try:
        corpus = shared.tracked_markdown_files(root)
    except shared.ScanError as error:
        sys.stderr.write(f"{error}\n")
        raise SystemExit(2)
    findings = []
    for document in corpus:
        if entries.get(document, False):
            continue
        source = root / document
        if not source.is_file():
            # Tracked but deleted in the working tree: nothing to read.
            continue
        text = source.read_text(encoding="utf-8", errors="replace")
        for number, target in link_targets(text):
            resolved = repository_path(document, target)
            if resolved is not None and resolved not in known:
                findings.append((document, number, target))
    return findings


def main() -> int:
    root = Path(__file__).resolve().parent.parent
    findings = broken_links(root)
    if findings:
        print(
            "check_markdown_link_targets: these relative links name a path "
            "that is not tracked in this repository. State the fact the link "
            "was meant to supply in the document itself, or point the link at "
            "the file that now carries it:",
            file=sys.stderr,
        )
        for document, number, target in findings:
            print(f"{document}:{number}: {target}", file=sys.stderr)
        return 1
    print("check_markdown_link_targets: OK (every relative Markdown link names a tracked path)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
