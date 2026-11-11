#!/usr/bin/env python3
"""Refuse a PARSE of git output that has git's stderr merged into it.

WHY THIS EXISTS
===============

``gitRunPlain`` (``libs/repro_cli_support``) runs git with its stderr merged
into its stdout. That is the right shape for a command whose exit status is
the answer, or whose text is only ever quoted back in an error message. It is
the wrong shape for a command whose stdout is the answer: git writes warnings
to stderr while still exiting 0 with the right answer on stdout, and the
merged stream then carries the warning in front of the answer.

The warning that made this concrete is ``warning: unable to find all
commit-graph files``, which git prints in a checkout whose split commit-graph
chain names a pruned graph file (a state a checkout borrowing objects through
``objects/info/alternates`` can re-enter at any time). ``rev-parse``,
``rev-list``, ``merge-base``, ``for-each-ref``, ``log`` and ``status`` all
print it. ``git rev-parse <name>`` for a name that is both a branch and a tag
prints ``warning: refname '<name>' is ambiguous.`` the same way. A caller
that ``strip()``s the merged text and takes it as an object id, a ref name, a
count or a "dirty" verdict then reads the warning as the answer.

``gitRunPlainQuery`` is the reader for an answer: ``output`` is stdout alone
and ``diagnostic`` is the merged text, for the error message.
``gitRunSeparated`` (``libs/repro_core/src/repro_core/git_separated.nim``) is the
same reader for a caller that needs its own git binary or environment. This
gate keeps the parse sites on them, so the class cannot grow back one site at
a time.

WHAT IS REFUSED
===============

Two families of call produce the merged stream.

1. A NAMED merged reader: a proc whose header carries
   ``# git-merged-reader: <reason>`` (on the header lines, or as the first
   line of its body) because it hands its callers git's merged stream --
   ``gitRunPlain``, ``gitRunPlainEnv``, ``git_actions.runGit`` and the like.
   Its calls are checked in the file declaring it and, for an exported
   (``*``) reader, in every file that imports its module. The reader's own
   body is exempt: building the merged stream is its job. ``gitRunPlain`` and
   ``gitRunPlainEnv`` (``MERGED_READERS``) must carry the marker, so dropping
   it is itself a finding rather than a way to switch the check off.

2. A DIRECT run of the git binary whose stderr is merged, outside a
   declared reader's body: an ``execCmdEx``,
   ``execCmdExCloseOnce``, ``execProcess`` or ``startProcess`` (or their
   ``uncontrolled*`` spellings) that passes ``poStdErrToStdOut``, or passes
   no ``options`` at all -- every one of them DEFAULTS to the merged stream
   (``std/osproc``: https://nim-lang.org/docs/osproc.html). A call is "of the
   git binary" when its first argument names git (``"git ..."``,
   ``identity.binaryPath``, ``gitBin``, ``quoteShell(git)``, ...) directly or
   through a variable built from such a name earlier in the proc. This
   family is checked outside test trees only (``libs``, ``apps``, ``tools``,
   excluding ``tests/`` directories): a test's own fixture plumbing runs git
   to SET UP the situation, and its assertions read the streams it chooses.

For either family, the call's result is followed. A wrapper that returns a
direct run's merged text to ITS callers is such a use -- through a tuple
(``(code: res.exitCode, output: res.output)``), or whole: ``return <call>``,
``result = <call>``, or the call as the routine's bare final expression
(``proc f(): string = execProcess(...)``). It is refused until the wrapper
either reads the streams apart or is declared a merged reader, which puts its
callers under the same check.

* bound to a name (``let r = <call>``, ``var r = ...``, a reassignment of a
  ``var`` declared earlier, or a multi-line binding whose value, or one
  ``if``/``case`` branch of it, is the call), any use of the merged text in
  the name's block that is not an ALLOWED use below. The merged text is
  ``r.output`` for the named readers and ``execCmdEx``, ``r.outputStream`` /
  ``r.outputHandle`` for ``startProcess``, ``r`` itself for ``execProcess``,
  and the FIRST name of a destructuring ``let (text, code) = execCmdEx(...)``;
* used inline, ``<call>.output``.

ALLOWED uses of the merged text -- the ones that read it BECAUSE it is
diagnostic:

* concatenated into a message: the use directly follows ``&``
  (``"git add failed: " & addRes.output.strip()``), on its line or as the
  first token of a continuation line after a line ending in ``&``;
* passed to a function that classifies git's diagnostic text, named in
  ``DIAGNOSTIC_CONSUMERS``;
* (not a use at all) a call that passes ``mergeStderr = false`` to a reader
  whose streams are a parameter;
* annotated on its line with ``# git-merged-text: <reason>``, for a site that
  deliberately parses or forwards the merged stream -- the merged readers'
  own bodies, a clone classifier that reads git's stderr. The reason is
  mandatory.

HOW TO SATISFY IT
=================

Read the answer with ``gitRunPlainQuery`` (or ``gitRunSeparated``) and quote
``.diagnostic`` (not ``.output``) in the error message, so a failure still
shows git's stderr.

``python3 scripts/check_git_run_plain_parses.py --self-test`` proves the scan
still catches each refused shape and still passes each allowed one.
"""

from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCAN_DIRS = ("libs", "apps", "tools", "tests")
#: Directories the DIRECT-exec family is checked in (see the docstring).
DIRECT_SCAN_DIRS = ("libs", "apps", "tools")

#: Functions whose job is to classify git's DIAGNOSTIC text, so the merged
#: stream is exactly what they should be given.
DIAGNOSTIC_CONSUMERS = ("isTransientGitLockContention",
                        "pushOutputIsNonFastForward", "pushOutputOneLine",
                        "pushOutputHookRefusalLines")

#: Procs that return git's stdout and stderr merged in ``output``.
#: Procs that return git's stdout and stderr merged in ``output`` and must
#: carry the ``# git-merged-reader:`` marker. The marker is what the scan
#: goes by; this list only makes REMOVING it from these two a finding too.
MERGED_READERS = ("gitRunPlain", "gitRunPlainEnv")

ANNOTATION = re.compile(r"#\s*git-merged-text:\s*\S")
READER_MARK = re.compile(r"#\s*git-merged-reader:\s*\S")
#: A reader whose streams are a parameter is not merged when told so.
UNMERGED_ARG = re.compile(r"\bmergeStderr\s*=\s*false\b")
READER_DECL = re.compile(r"^(\s*)proc\s+(\w+)(\*?)")

#: Process launchers, by what their result carries. Every one of them
#: defaults to ``poStdErrToStdOut`` when ``options`` is not passed.
EXEC_TEXT = ("execCmdEx", "execCmdExCloseOnce", "uncontrolledExecCmdEx")
EXEC_STRING = ("execProcess", "uncontrolledExecProcess")
EXEC_PROCESS = ("startProcess", "uncontrolledStartProcess")
#: Bare or qualified with the module (``osproc.execCmdEx(``), which is how a
#: module that also imports the rewrite templates reaches the stdlib's.
EXEC_CALL = re.compile(
    r"(?<![.\w])(?:osproc\.)?(%s)\(" % "|".join(EXEC_TEXT + EXEC_STRING +
                                              EXEC_PROCESS))
EXEC_DECL = re.compile(
    r"^\s*proc\s+(?:%s)\*?\s*\(" % "|".join(EXEC_TEXT + EXEC_STRING +
                                            EXEC_PROCESS))

#: Something in a command's first argument that names the git binary.
GIT_HINT = re.compile(
    r'"git(?:\.exe)?(?:\s|")|\bgit\b|\bgit(?:Bin|Exe|Binary|ForRefs|Cmd|Path)\w*'
    r'|\bgitIdentity\b|\bGitBin\w*')
#: ``binaryPath`` is the field every resolved tool identity carries (git's,
#: hg's, a provider's), so it names git only inside a routine whose header
#: says it is about git (``identity: GitToolIdentity``, ``probeGitVersion``).
BINARY_PATH = re.compile(r"\bbinaryPath\b")
GIT_HEADER = re.compile(r"(?i)git")

BIND = re.compile(
    r"(?<![.\w])(?:(let|var)\s+)?(\w+)\s*(?::[^=]*)?=\s*(?:\w+\.)?\w+\($")
TUPLE_BIND = re.compile(
    r"(?<![.\w])(let|var)\s+\((\w+)\s*,\s*(\w+)[^)]*\)\s*=\s*(?:\w+\.)?\w+\($")
#: A ``let``/``var`` whose value is a multi-line expression: the line ends at
#: ``=``, or opens an ``if``/``case``/``when`` expression after it.
EXPR_BIND = re.compile(
    r"^\s*(let|var)\s+(\w+)\s*(?::[^=]*)?=\s*(?:(?:if|case|when)\b.*)?$")
#: A branch header inside such an expression.
BRANCH_HEAD = re.compile(r"^\s*(?:if|elif|else|of|when|case)\b")
#: What may precede the call on its own line when it is a branch's value.
BRANCH_PREFIX = re.compile(r"^\s*(?:(?:elif|else|of|if|when)\b[^#]*:\s*)?$")
PROC_HEAD = re.compile(r"^\s*(?:proc|func|method|iterator|template|macro)\b")


@dataclass(frozen=True)
class Hit:
    path: str
    line: int
    text: str
    why: str


def indent_of(line: str) -> int:
    return len(line) - len(line.lstrip(" "))


def code_of(line: str) -> str:
    """``line`` without its comment. A ``#`` inside a string literal is kept,
    so ``"#"`` does not cut the line short."""
    in_str = False
    i = 0
    while i < len(line):
        ch = line[i]
        if ch == '"':
            in_str = not in_str
        elif ch == "\\" and in_str:
            i += 1
        elif ch == "#" and not in_str:
            return line[:i]
        i += 1
    return line


def call_end(lines: list[str], row: int, col: int) -> tuple[int, int]:
    """Row and column just past the ``)`` closing the call opened at
    ``lines[row][col]`` (``col`` indexes the ``(``)."""
    depth = 0
    r, c = row, col
    while r < len(lines):
        text = code_of(lines[r])
        in_str = False
        while c < len(text):
            ch = text[c]
            if ch == '"':
                in_str = not in_str
            elif in_str:
                if ch == "\\":
                    c += 1
            elif ch == "(" or ch == "[":
                depth += 1
            elif ch == ")" or ch == "]":
                depth -= 1
                if depth == 0:
                    return r, c + 1
            c += 1
        r += 1
        c = 0
    return row, len(lines[row])


def call_text(lines: list[str], row: int, col: int,
              end: tuple[int, int]) -> str:
    end_row, end_col = end
    if end_row == row:
        return code_of(lines[row])[col:end_col]
    parts = [code_of(lines[row])[col:]]
    parts.extend(code_of(lines[r]) for r in range(row + 1, end_row))
    parts.append(code_of(lines[end_row])[:end_col])
    return "\n".join(parts)


def first_argument(text: str) -> str:
    """The call's first argument: ``text`` from just past ``(`` up to the
    first top-level comma (or the closing paren)."""
    depth = 0
    in_str = False
    for i, ch in enumerate(text[1:], start=1):
        if ch == '"':
            in_str = not in_str
        elif in_str:
            continue
        elif ch in "([":
            depth += 1
        elif ch in ")]":
            if depth == 0:
                return text[1:i]
            depth -= 1
        elif ch == "," and depth == 0:
            return text[1:i]
    return text[1:]


def proc_start(lines: list[str], row: int) -> int:
    """Row of the nearest enclosing routine header at or above ``row``."""
    for r in range(row, -1, -1):
        if PROC_HEAD.match(lines[r]) and indent_of(lines[r]) < max(
                indent_of(lines[row]), 1):
            return r
    return 0


def names_git(lines: list[str], row: int, text: str) -> bool:
    """Does the command in ``text`` (a call opened on ``row``) run git?"""
    head = first_argument(text)
    if GIT_HINT.search(head):
        return True
    if BINARY_PATH.search(head) and git_routine(lines, row):
        return True
    # A command assembled in a variable first: ``var cmd = quoteShell(gitBin)``
    # then ``execCmdEx(cmd, ...)``.
    names = set(re.findall(r"(?<![.\w\"])([A-Za-z_]\w*)\b(?!\s*\()", head))
    names -= {"options", "env", "workingDir", "args", "true", "false"}
    if not names:
        return False
    top = proc_start(lines, row)
    for name in names:
        built = re.compile(
            rf"(?:\b(?:let|var|const)\s+{re.escape(name)}\b|^\s*{re.escape(name)}"
            rf"\s*(?:=|\.add\b)|\bfor\s+{re.escape(name)}\b)")
        for r in range(row - 1, top - 1, -1):
            code = code_of(lines[r])
            if built.search(code):
                # The assignment may continue on the next lines.
                chunk = code
                k = r + 1
                while chunk.rstrip().endswith(("&", "(", ",", "=")) and k < row:
                    chunk += "\n" + code_of(lines[k])
                    k += 1
                value = chunk.split("=", 1)[-1]
                if GIT_HINT.search(value) or (BINARY_PATH.search(value) and
                                              git_routine(lines, row)):
                    return True
    return False


def git_routine(lines: list[str], row: int) -> bool:
    """Does the header of a routine enclosing ``row`` (the nearest one, or a
    routine it is nested in) mention git?"""
    r = row
    while r > 0:
        top = proc_start(lines, r)
        header = code_of(lines[top])
        k = top + 1
        while not header.rstrip().endswith("=") and k < len(lines) and k < top + 6:
            header += " " + code_of(lines[k])
            k += 1
        if GIT_HEADER.search(header):
            return True
        if top == 0 or indent_of(lines[top]) == 0:
            return False
        r = top - 1
    return False


def merged_options(lines: list[str], row: int, text: str) -> bool:
    """Is stderr merged into the captured stream of this call?"""
    if "poStdErrToStdOut" in text:
        return True
    opt = re.search(r"\boptions\s*=\s*(\w+)\b", text)
    if not opt:
        # No explicit set (named or as the positional set literal): every
        # launcher scanned here defaults to ``poStdErrToStdOut``.
        return not re.search(r"\{\s*(?:po\w+|\})", text)
    name = opt.group(1)
    if name.startswith("po"):
        return False
    top = proc_start(lines, row)
    pattern = re.compile(rf"\b{re.escape(name)}\b")
    for r in range(row - 1, top - 1, -1):
        code = code_of(lines[r])
        if pattern.search(code) and "poStdErrToStdOut" in code:
            return True
    return False


def block_end(lines: list[str], row: int) -> int:
    """Index of the first line after the block that contains ``lines[row]``:
    the first later non-blank, non-comment line indented less than it."""
    base = indent_of(lines[row])
    for r in range(row + 1, len(lines)):
        stripped = lines[r].strip()
        if not stripped or stripped.startswith("#"):
            continue
        if indent_of(lines[r]) < base:
            return r
    return len(lines)


def declaration_row(lines: list[str], row: int, name: str) -> int:
    """The row declaring ``name`` that a bare reassignment at ``row`` refers
    to: the nearest earlier ``var name`` at an indentation no deeper."""
    pattern = re.compile(rf"^\s*var\s+{re.escape(name)}\b")
    for r in range(row - 1, -1, -1):
        if pattern.match(lines[r]) and indent_of(lines[r]) <= indent_of(lines[row]):
            return r
    return row


def expression_binding(lines: list[str], row: int,
                       prefix: str) -> tuple[str, str, int] | None:
    """For a call that is the value of a multi-line binding -- ``let r =``
    with the call on the next line, or one branch of ``let r = if ...:`` /
    ``let r =`` + ``if``/``else`` -- the keyword, the name and the binding's
    row. ``prefix`` is the code before the call on its line."""
    if not BRANCH_PREFIX.match(prefix):
        return None
    current = indent_of(lines[row])
    for r in range(row - 1, -1, -1):
        code = code_of(lines[r]).rstrip()
        if not code.strip():
            continue
        if indent_of(lines[r]) >= current:
            continue
        bound = EXPR_BIND.match(code)
        if bound:
            return bound.group(1), bound.group(2), r
        if BRANCH_HEAD.match(code):
            current = indent_of(lines[r])
            continue
        return None
    return None


def use_is_allowed(lines: list[str], row: int, col: int) -> bool:
    line = lines[row]
    if ANNOTATION.search(line):
        return True
    before = line[:col].rstrip()
    if before.endswith("&"):
        return True
    if not before:
        for r in range(row - 1, -1, -1):
            prev = code_of(lines[r]).rstrip()
            if prev:
                return prev.endswith("&")
        return False
    for consumer in DIAGNOSTIC_CONSUMERS:
        if before.endswith(consumer + "("):
            return True
    return False


def check_uses(lines: list[str], path: str, start: int, name: str,
               use: re.Pattern[str], what: str, hits: list[Hit],
               scope: int | None = None) -> None:
    """Report each unallowed ``use`` after row ``start``, until the end of the
    block declaring ``name`` (row ``scope``, default ``start``) or the next
    binding of or assignment to ``name``: that value is followed on its own,
    when it is merged text at all."""
    stop = block_end(lines, start if scope is None else scope)
    rebind = re.compile(rf"\b(?:let|var)\s+\(?{re.escape(name)}\b"
                        rf"|^\s*{re.escape(name)}\s*=(?!=)")
    for r in range(start + 1, stop):
        body = code_of(lines[r])
        if rebind.search(body):
            break
        for u in use.finditer(body):
            if not use_is_allowed(lines, r, u.start()):
                hits.append(Hit(path, r + 1, lines[r].strip(),
                                f"{what} parsed (bound at line {start + 1})"))


#: What may precede a call on its line when the call's value is what the
#: enclosing routine returns: nothing (a bare final expression), a branch
#: header of such an expression, ``return`` or ``result =``.
FORWARD_PREFIX = re.compile(
    r"^\s*(?:(?:(?:elif|else|of|if|when)\b[^#]*:\s*)|return\s+|"
    r"result\s*=\s*)?$")
#: A previous line ending like this continues into the call's line, so the
#: call is an operand or argument there, not a value of its own.
CONTINUED = re.compile(r"(?:[(\[{,&=+\-*/<>]|\band|\bor|\bnot|\bin)\s*$")


def report_forwarded(lines: list[str], path: str, row: int,
                     match: re.Match[str], end: tuple[int, int], label: str,
                     hits: list[Hit]) -> None:
    """Report a merged call whose whole value is handed back to the routine's
    caller -- ``return <call>``, ``result = <call>``, or a bare final
    expression (``proc f(): string = execProcess(...)``) -- by a routine not
    declared ``# git-merged-reader:``. Nim makes a bare non-``void`` call a
    compile error unless its value is used, so a call that is a statement of
    its own here IS the routine's (or the branch's) value. Its callers then
    parse git's merged stream with nothing in this file naming it, the same
    hole a forwarding tuple (``(code: r.exitCode, output: r.output)``) is."""
    code = code_of(lines[row])
    end_row, end_col = end
    if ANNOTATION.search(lines[row]) or ANNOTATION.search(lines[end_row]):
        return
    if not FORWARD_PREFIX.match(code[: match.start()]):
        return
    if code_of(lines[end_row])[end_col:].strip():
        # ``<call>.exitCode == 0``, ``<call>.code``, an operand: not the value.
        return
    if not code[: match.start()].strip():
        # The routine's own header ends in ``=`` too; that is not a
        # continuation but the start of the body the call is the value of.
        top = proc_start(lines, row)
        header_end = top
        while header_end < row and \
                not code_of(lines[header_end]).rstrip().endswith("="):
            header_end += 1
        for r in range(row - 1, -1, -1):
            prev = code_of(lines[r]).rstrip()
            if prev.strip():
                if CONTINUED.search(prev) and not (top <= r <= header_end and
                                                   PROC_HEAD.match(lines[top])):
                    return
                break
    hits.append(Hit(path, row + 1, lines[row].strip(),
                    f"{label}(...) returned whole to the routine's caller; "
                    "declare the routine `# git-merged-reader:` or read the "
                    "streams apart"))


def follow_result(lines: list[str], path: str, row: int, match: re.Match[str],
                  end: tuple[int, int], kind: str, label: str,
                  seen: set[tuple[str, int]], hits: list[Hit],
                  may_forward: bool = False) -> None:
    """Report each unallowed use of the merged text the call at ``match``
    produced. ``kind`` is ``text`` (``.output``), ``string`` (the value) or
    ``process`` (``.outputStream`` / ``.outputHandle``). ``may_forward``: the
    call is in a declared merged reader's body, whose job is to hand the
    merged stream to its callers whole."""
    code = code_of(lines[row])
    end_row, end_col = end
    tail = lines[end_row][end_col:]
    if kind == "text" and tail.startswith(".output") and \
            not ANNOTATION.search(lines[end_row]):
        hits.append(Hit(path, end_row + 1, lines[end_row].strip(),
                        f"inline {label}(...).output"))
        return
    if kind == "process" and re.match(r"\.output(?:Stream|Handle)\b", tail) \
            and not ANNOTATION.search(lines[end_row]):
        hits.append(Hit(path, end_row + 1, lines[end_row].strip(),
                        f"inline {label}(...).outputStream"))
        return
    head = code[: match.end()]
    tupled = TUPLE_BIND.search(head)
    if tupled and kind == "text":
        # ``execCmdEx`` answers ``(output, exitCode)``; every merged reader
        # answers ``(code, output)``.
        name = tupled.group(2) if label.startswith("merged git") else \
            tupled.group(3)
        start = row
        if (name, start) in seen:
            return
        seen.add((name, start))
        check_uses(lines, path, start, name,
                   re.compile(rf"(?<![.\w]){re.escape(name)}\b(?!\s*[:=][^=])"),
                   f"{name} (merged text of {label})", hits)
        return
    bound = BIND.search(head)
    if bound:
        keyword, name = bound.group(1), bound.group(2)
        if name == "result" and not keyword:
            # ``result = <call>``: the merged value IS the routine's answer.
            if not may_forward:
                report_forwarded(lines, path, row, match, end, label, hits)
            return
        start = row
        scope = row if keyword else declaration_row(lines, row, name)
    else:
        outer = expression_binding(lines, row, code[: match.start()])
        if not outer:
            if not may_forward:
                report_forwarded(lines, path, row, match, end, label, hits)
            return
        keyword, name, start = outer
        scope = start
    if (name, start) in seen:
        return
    seen.add((name, start))
    if kind == "text":
        use = re.compile(rf"\b{re.escape(name)}\.output\b")
        what = f"{name}.output"
    elif kind == "process":
        use = re.compile(rf"\b{re.escape(name)}\.output(?:Stream|Handle)\b")
        what = f"{name}.outputStream"
    else:
        use = re.compile(rf"(?<![.\w]){re.escape(name)}\b(?!\s*[:=][^=])")
        what = name
    check_uses(lines, path, start, name, use, f"{what} (merged text of {label})",
               hits, scope)


@dataclass(frozen=True)
class Reader:
    """A proc declared ``# git-merged-reader:``: it hands its callers git's
    merged stream, so its CALLERS are checked the way ``gitRunPlain``'s are,
    and its own body (which builds the merged stream on purpose) is not."""
    name: str
    exported: bool
    module: str
    first: int  # row of the ``proc`` line
    last: int   # first row after its body


def header_text(lines: list[str], row: int) -> str:
    """A routine's header: its ``proc`` line through the line ending ``=``,
    plus a comment-only line straight after it (where a long signature leaves
    room for the marker)."""
    text = lines[row]
    k = row + 1
    while not code_of(text).rstrip().endswith("=") and k < len(lines) and \
            k < row + 8:
        text += "\n" + lines[k]
        k += 1
    if k < len(lines) and lines[k].strip().startswith("#"):
        text += "\n" + lines[k]
    return text


def is_definition(lines: list[str], row: int) -> bool:
    """A routine with a body, not a forward declaration: its header ends at
    ``=``."""
    return any(code_of(l).rstrip().endswith("=")
               for l in header_text(lines, row).split("\n"))


def declared_readers(path: str, text: str) -> list[Reader]:
    lines = text.split("\n")
    module = Path(path).stem
    found: list[Reader] = []
    for row, line in enumerate(lines):
        decl = READER_DECL.match(code_of(line))
        if not decl or not READER_MARK.search(header_text(lines, row)):
            continue
        body = row + 1
        while body < len(lines) and not code_of(lines[body - 1]).rstrip() \
                .endswith("="):
            body += 1
        while body < len(lines) and not code_of(lines[body]).strip():
            body += 1
        last = block_end(lines, body) if body < len(lines) else len(lines)
        found.append(Reader(decl.group(2), bool(decl.group(3)), module, row,
                            last))
    return found


def readers_seen_by(text: str, own: list[Reader],
                    exported: list[Reader]) -> list[Reader]:
    """``own`` plus each exported reader whose module ``text`` imports."""
    seen = list(own)
    imports = "\n".join(l for l in text.split("\n")
                        if re.match(r"\s*(?:import|from|include)\b", l))
    for reader in exported:
        if reader in own:
            continue
        if re.search(rf"\b{re.escape(reader.module)}\b", imports):
            seen.append(reader)
    return seen


def scan_text(path: str, text: str, direct: bool = True,
              exported: list[Reader] | None = None) -> list[Hit]:
    lines = text.split("\n")
    hits: list[Hit] = []
    own = declared_readers(path, text)
    readers = readers_seen_by(text, own, exported or [])
    for row, line in enumerate(lines):
        decl = READER_DECL.match(code_of(line))
        if decl and decl.group(2) in MERGED_READERS and \
                is_definition(lines, row) and \
                not READER_MARK.search(header_text(lines, row)):
            hits.append(Hit(path, row + 1, line.strip(),
                            f"{decl.group(2)} merges git's stderr into its "
                            "output but is not declared `# git-merged-reader:`"))
    names = sorted({r.name for r in readers})
    named_call = (re.compile(r"(?<![.\w])(?:%s)\(" % "|".join(names))
                  if names else None)
    bodies = [(r.first, r.last) for r in own]
    seen: set[tuple[str, int]] = set()
    for row, line in enumerate(lines):
        code = code_of(line)
        if READER_DECL.match(code):
            continue
        if named_call:
            for match in named_call.finditer(code):
                open_col = match.end() - 1
                end = call_end(lines, row, open_col)
                label = match.group(0)[:-1]
                if UNMERGED_ARG.search(call_text(lines, row, open_col, end)):
                    continue
                follow_result(lines, path, row, match, end, "text", label,
                              seen, hits,
                              any(first <= row < last
                                  for first, last in bodies))
        if not direct or EXEC_DECL.match(code):
            continue
        if any(first <= row < last for first, last in bodies):
            continue
        for match in EXEC_CALL.finditer(code):
            open_col = match.end() - 1
            end = call_end(lines, row, open_col)
            body = call_text(lines, row, open_col, end)
            if not merged_options(lines, row, body):
                continue
            if not names_git(lines, row, body):
                continue
            fn = match.group(1)
            kind = ("text" if fn in EXEC_TEXT else
                    "string" if fn in EXEC_STRING else "process")
            follow_result(lines, path, row, match, end, kind,
                          f"merged git {fn}", seen, hits)
    # One finding per line and reason, however often the name recurs on it.
    unique: list[Hit] = []
    for hit in hits:
        if hit not in unique:
            unique.append(hit)
    return unique


#: Prepended to every probe: the two readers as the real file declares them.
SELF_TEST_PRELUDE = """
proc gitRunPlain(identity: GitToolIdentity;
                 args: openArray[string]): tuple[code: int; output: string] =
  # git-merged-reader: exit status and diagnostics only
  let res = execCmdEx(quoteShell(identity.binaryPath) & " " & args.join(" "),
    options = {poStdErrToStdOut, poUsePath})
  (code: res.exitCode, output: res.output)

proc gitRunPlainEnv(identity: GitToolIdentity; args: openArray[string];
    capability = ""): tuple[code: int; output: string] =  # git-merged-reader: push transcript
  let res = execCmdEx(quoteShell(identity.binaryPath) & " " & args.join(" "))
  (res.exitCode, res.output)
"""

SELF_TESTS: list[tuple[str, str, int]] = [
    ("caught_strip_as_answer", """
proc f() =
  let head = gitRunPlain(identity, ["rev-parse", "HEAD"])
  if head.code == 0:
    result = head.output.strip()
""", 1),
    ("caught_continuation_args", """
proc f() =
  let res = gitRunPlain(identity,
    ["-C", dir, "rev-list", "--count", "HEAD"])
  let n = parseInt(res.output.strip())
""", 1),
    ("caught_split_lines", """
proc f() =
  let r = gitRunPlain(identity, ["remote"])
  for line in r.output.splitLines():
    echo line
""", 1),
    ("caught_inline_output", """
proc f(): string =
  gitRunPlain(identity, ["rev-parse", "HEAD"]).output.strip()
""", 1),
    ("caught_reassigned_var", """
proc f() =
  var fetched: tuple[code: int; output: string]
  for attempt in 0 .. 3:
    fetched = gitRunPlain(identity, ["log", "--format=%H"])
  for sha in fetched.output.splitLines():
    echo sha
""", 1),
    ("caught_emptiness_verdict", """
proc f() =
  let status = gitRunPlain(identity, ["status", "--porcelain"])
  result.dirty = status.output.strip().len > 0
""", 1),
    ("caught_unannotated_beside_message", """
proc f() =
  let r = gitRunPlain(identity, ["merge-base", a, b])
  if r.code != 0: return "failed: " & r.output.strip()
  return r.output.strip()
""", 1),
    ("caught_branch_value_binding", """
proc f() =
  let staged =
    if paths.len == 0:
      (code: 0, output: "")
    else:
      gitRunPlain(identity, @["diff", "--cached", "--name-status"] & paths)
  for line in staged.output.splitLines():
    echo line
""", 1),
    ("caught_next_line_value", """
proc f() =
  let head =
    gitRunPlain(identity, ["rev-parse", "HEAD"])
  result = head.output.strip()
""", 1),
    ("caught_env_reader", """
proc f() =
  let urls = gitRunPlainEnv(identity, ["remote", "get-url", "--push", "--all",
    remote])
  for line in urls.output.splitLines():
    echo line
""", 1),
    ("caught_direct_exec_merged", """
proc f(identity: GitToolIdentity; repo, spec: string): string =
  let res = execCmdEx(
    quoteShell(identity.binaryPath) & " -C " & quoteShell(repo) &
      " rev-parse " & quoteShell(spec),
    options = {poStdErrToStdOut, poUsePath},
    env = scrubbedGitRepositoryEnv())
  if res.exitCode == 0:
    res.output.strip()
  else:
    ""
""", 1),
    ("caught_direct_exec_default_options", """
proc f(target: string): string =
  let res = execCmdEx(shellCommand(@["git", "-C", target,
    "rev-parse", "--show-toplevel"]), env = scrubbedGitRepositoryEnv())
  if res.exitCode == 0:
    result = res.output.strip()
""", 1),
    ("caught_direct_exec_built_command", """
proc f(identity: GitToolIdentity; repo: string): seq[string] =
  var command = quoteShell(identity.binaryPath) & " -C " &
    quoteShell(repo) & " rev-parse"
  for name in names:
    command.add(" --git-path " & quoteShell(name))
  var res: tuple[output: string; exitCode: int]
  try:
    res = execCmdEx(command, options = {poStdErrToStdOut, poUsePath})
  except CatchableError:
    return
  for raw in res.output.splitLines():
    result.add(raw)
""", 1),
    ("caught_direct_exec_tuple_binding", """
proc f(dir: string): string =
  let (output, code) = execCmdEx("git -C " & quoteShell(dir) &
    " rev-parse HEAD")
  if code == 0:
    result = output.strip()
""", 1),
    ("caught_direct_start_process", """
proc f(gitBin: string; args: seq[string]): string =
  let p = startProcess(gitBin, args = args,
    options = {poStdErrToStdOut, poUsePath})
  defer: p.close()
  result = p.outputStream.readAll()
""", 1),
    ("caught_direct_exec_options_variable", """
proc f(args: openArray[string]): string =
  let opts = {poUsePath, poStdErrToStdOut}
  var p = startProcess("git", args = @args, options = opts)
  result = p.outputStream.readAll().strip()
""", 1),
    ("caught_reader_tuple_binding", """
proc runGit*(args: openArray[string]): tuple[exitCode: int; output: string] =
  # git-merged-reader: advisory text
  discard

proc versions(file: string): seq[string] =
  let (rc, outp) = runGit(["log", "--format=%H", "--", file])
  if rc != 0: return @[]
  for line in outp.splitLines():
    result.add(line)
""", 1),
    ("allowed_reader_told_not_to_merge", """
proc runGit*(gitExe: string; args: openArray[string];
             mergeStderr = true): GitRun =
  # git-merged-reader: by default; parse sites pass mergeStderr = false
  discard

proc tree(gitExe, commit: string): seq[string] =
  let res = runGit(gitExe, ["ls-tree", "-r", "-z", commit],
    mergeStderr = false)
  result = res.output.split('\0')
""", 0),
    ("allowed_reassigned_unmerged", """
proc runGit*(gitExe: string; args: openArray[string];
             mergeStderr = true): GitRun =
  # git-merged-reader: by default; parse sites pass mergeStderr = false
  discard

proc base(gitExe: string): seq[string] =
  var res = runGit(gitExe, ["read-tree", "--reset", "-u", "HEAD"])
  if res.code != 0: return
  res = runGit(gitExe, ["ls-files", "-s", "-z"], mergeStderr = false)
  result = res.output.split('\0')
""", 0),
    ("allowed_direct_exec_separate_streams", """
proc f(identity: GitToolIdentity; repo: string): string =
  let res = execCmdEx(quoteShell(identity.binaryPath) & " -C " & repo &
    " rev-parse HEAD 2>/dev/null", options = {poUsePath})
  result = res.output.strip()
""", 0),
    ("allowed_direct_exec_not_git", """
proc f(nim: string): string =
  let res = execCmdEx(quoteShell(nim) & " --version")
  result = res.output.strip()
""", 0),
    ("allowed_direct_exec_exit_status_only", """
proc f(dir: string): bool =
  let res = execCmdEx("git -C " & quoteShell(dir) & " diff --quiet")
  res.exitCode == 0
""", 0),
    ("allowed_direct_exec_message_concat", """
proc f(gitBin, dir: string) =
  let res = execCmdEx(quoteShell(gitBin) & " -C " & dir & " fetch",
    options = {poStdErrToStdOut, poUsePath})
  if res.exitCode != 0:
    raise newException(OSError, "git fetch failed: " & res.output.strip())
""", 0),
    ("allowed_direct_exec_annotated_reader", """
proc gitMergedReader(gitBin: string; args: seq[string]):
    tuple[code: int; output: string] =
  let res = execCmdEx(quoteShell(gitBin) & " " & args.join(" "),
    options = {poStdErrToStdOut, poUsePath})
  (code: res.exitCode, output: res.output)  # git-merged-text: diagnostic reader
""", 0),
    ("allowed_branch_in_bool_proc", """
proc f(): bool =
  if cond:
    gitRunPlain(identity, ["cat-file", "-e", sha]).code == 0
  else:
    false
""", 0),
    ("allowed_message_concat", """
proc f() =
  let addRes = gitRunPlain(identity, ["add", "--", rel])
  if addRes.code != 0:
    return failed("git add failed: " & addRes.output.strip())
""", 0),
    ("allowed_continuation_concat", """
proc f() =
  let co = gitRunPlain(identity, ["checkout", branch])
  if co.code != 0:
    return (false, "checkout failed: " &
      co.output.strip())
""", 0),
    ("allowed_diagnostic_consumer", """
proc f() =
  let fetched = gitRunPlain(identity, ["fetch"])
  if not isTransientGitLockContention(fetched.output):
    discard
""", 0),
    ("allowed_annotated", """
proc f() =
  let r = gitRunPlain(identity, ["fetch"])
  let joined = r.output.splitLines().join(" | ")  # git-merged-text: quoted in a finding
""", 0),
    ("allowed_exit_status_only", """
proc f(): bool =
  gitRunPlain(identity, ["merge-base", "--is-ancestor", a, b]).code == 0
""", 0),
    ("allowed_query_reader", """
proc f() =
  let head = gitRunPlainQuery(identity, ["rev-parse", "HEAD"])
  result = head.output.strip()
""", 0),
    ("allowed_out_of_scope_name", """
proc f() =
  if cond:
    let r = gitRunPlain(identity, ["add", "--", rel])
    discard r.code
  let r = gitRunPlainQuery(identity, ["rev-parse", "HEAD"])
  result = r.output.strip()
""", 0),
    ("caught_unmarked_forwarding_wrapper", """
proc runGit(gitBin: string; args: seq[string]): tuple[code: int; output: string] =
  let res = execCmdEx(quoteShell(gitBin) & " " & args.join(" "),
    options = {poStdErrToStdOut, poUsePath})
  (code: res.exitCode, output: res.output)
""", 1),
    ("caught_marked_reader_caller", """
proc runGit(gitBin: string; args: seq[string]): tuple[code: int; output: string] =
  ## git-merged-reader: the clone classifier reads git's stderr
  let res = execCmdEx(quoteShell(gitBin) & " " & args.join(" "),
    options = {poStdErrToStdOut, poUsePath})
  (code: res.exitCode, output: res.output)

proc head(gitBin, dir: string): string =
  let r = runGit(gitBin, @["-C", dir, "rev-parse", "HEAD"])
  result = r.output.strip()
""", 1),
    ("allowed_marked_reader_body", """
proc runGit(gitBin: string; args: seq[string]): tuple[code: int; output: string] =
  # git-merged-reader: the clone classifier reads git's stderr
  var p = startProcess(gitBin, args = args, options = {poStdErrToStdOut})
  result.output = p.outputStream.readAll()
  result.code = p.waitForExit()
""", 0),
    ("caught_bare_expression_wrapper", """
proc runGit(gitBin: string; args: seq[string]): string =
  execProcess(quoteShell(gitBin) & " " & args.join(" "))
""", 1),
    ("caught_bare_tuple_wrapper", """
proc headOf(gitBin, dir: string): tuple[output: string; exitCode: int] =
  execCmdEx(quoteShell(gitBin) & " -C " & quoteShell(dir) &
    " rev-parse HEAD")
""", 1),
    ("caught_result_assigned_wrapper", """
proc headOf(dir: string): tuple[output: string; exitCode: int] =
  result = execCmdEx("git -C " & quoteShell(dir) & " rev-parse HEAD")
""", 1),
    ("caught_returned_wrapper", """
proc headOf(identity: GitToolIdentity; dir: string): tuple[code: int; output: string] =
  if dir.len == 0:
    return (1, "")
  return gitRunPlain(identity, ["-C", dir, "rev-parse", "HEAD"])
""", 1),
    ("caught_branch_value_wrapper", """
proc headOf(gitBin, dir: string): string =
  if dir.len == 0: ""
  else: execProcess(quoteShell(gitBin) & " -C " & dir & " rev-parse HEAD")
""", 1),
    ("allowed_bare_exit_status", """
proc clean(gitBin, dir: string): bool =
  execCmdEx(quoteShell(gitBin) & " -C " & dir & " diff --quiet").exitCode == 0
""", 0),
    ("allowed_bare_argument", """
proc report(gitBin, dir: string) =
  showMessage("fetch: " &
    execProcess(quoteShell(gitBin) & " -C " & dir & " fetch"))
""", 0),
    ("allowed_bare_marked_reader", """
proc runGit(gitBin: string; args: seq[string]): string =
  # git-merged-reader: progress text for the operator
  execProcess(quoteShell(gitBin) & " " & args.join(" "))
""", 0),
    ("caught_module_qualified_exec", """
proc headOf(gitBin, dir: string): string =
  let res = osproc.execCmdEx(quoteShell(gitBin) & " -C " & dir &
    " rev-parse HEAD")
  result = res.output.strip()
""", 1),
    ("allowed_marked_reader_forwards_reader", """
proc pushIt(identity: GitToolIdentity): tuple[code: int; output: string] =
  # git-merged-reader: the push transcript, quoted on failure
  result = gitRunPlainEnv(identity, ["push"])
""", 0),
    ("allowed_bare_annotated", """
proc runGit(gitBin: string; args: seq[string]): string =
  execProcess(quoteShell(gitBin) & " " & args.join(" "))  # git-merged-text: shown verbatim
""", 0),
    ("annotation_needs_reason", """
proc f() =
  let r = gitRunPlain(identity, ["fetch"])
  let joined = r.output.strip()  # git-merged-text:
""", 1),
]


def self_test() -> int:
    failures = 0
    for name, body, expected in SELF_TESTS:
        hits = scan_text(f"<self-test:{name}>",
                         SELF_TEST_PRELUDE.lstrip("\n") + body.lstrip("\n"))
        if len(hits) != expected:
            failures += 1
            print(f"check_git_run_plain_parses --self-test FAILED: {name}: "
                  f"expected {expected} finding(s), got {len(hits)}")
            for hit in hits:
                print(f"    {hit.line}: {hit.why}: {hit.text}")
    # A merged reader that loses its marker is itself a finding (the probes
    # above all carry the prelude, so it is checked on a bare text here).
    unmarked = scan_text("<self-test:unmarked_reader>", SELF_TEST_PRELUDE
                         .replace("# git-merged-reader: push transcript", "")
                         .lstrip("\n"))
    # Two: the undeclared reader, and its body forwarding the merged text.
    if len(unmarked) != 2:
        failures += 1
        print("check_git_run_plain_parses --self-test FAILED: "
              f"unmarked_reader: expected 2 finding(s), got {len(unmarked)}")
    # An EXPORTED reader's callers are checked in a module that imports it,
    # and not in one that does not.
    library = """
proc runGit*(gitExe: string; args: openArray[string]): GitRun =
  # git-merged-reader: progress text for the operator
  discard
"""
    caller = """
proc tips(gitExe: string): seq[string] =
  let r = runGit(gitExe, ["for-each-ref", "--format=%(objectname)"])
  result = r.output.splitLines()
"""
    exported = declared_readers("libs/x/src/x/git_process.nim", library)
    importing = scan_text("<self-test:importer>",
                          "import ./git_process\n" + caller, True, exported)
    unrelated = scan_text("<self-test:non_importer>",
                          "import ./other\n" + caller, True, exported)
    if len(importing) != 1 or len(unrelated) != 0:
        failures += 1
        print("check_git_run_plain_parses --self-test FAILED: exported_reader: "
              f"expected 1 finding in the importer and 0 elsewhere, got "
              f"{len(importing)} and {len(unrelated)}")
    if failures:
        print(f"\ncheck_git_run_plain_parses: self-test FAILED "
              f"({failures} of {len(SELF_TESTS) + 2} probes)")
        return 1
    print(f"check_git_run_plain_parses: self-test ok "
          f"({len(SELF_TESTS) + 2} probes)")
    return 0


def checks_direct(path: Path) -> bool:
    """Is ``path`` in the tree the direct-exec family is checked in?"""
    try:
        rel = path.resolve().relative_to(ROOT)
    except ValueError:
        return True
    parts = rel.parts
    return bool(parts) and parts[0] in DIRECT_SCAN_DIRS and "tests" not in parts


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    ap.add_argument("--self-test", action="store_true",
                    help="prove the scan catches each refused shape")
    ap.add_argument("paths", nargs="*", help="files to scan (default: tree)")
    args = ap.parse_args()
    if args.self_test:
        return self_test()
    if args.paths:
        files = [Path(p) for p in args.paths]
    else:
        files = sorted(p for d in SCAN_DIRS for p in (ROOT / d).rglob("*.nim"))
    hits: list[Hit] = []
    texts: list[tuple[Path, str, str]] = []
    exported: list[Reader] = []
    for path in files:
        try:
            text = path.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError) as err:
            print(f"check_git_run_plain_parses: cannot read {path}: {err}")
            return 2
        try:
            shown = str(path.resolve().relative_to(ROOT))
        except ValueError:
            shown = str(path)
        texts.append((path, shown, text))
        if "git-merged-reader" in text:
            exported.extend(r for r in declared_readers(shown, text)
                            if r.exported)
    for path, shown, text in texts:
        hits.extend(scan_text(shown, text, checks_direct(path), exported))
    for hit in hits:
        print(f"{hit.path}:{hit.line}: {hit.why}: {hit.text}")
    if hits:
        print(f"\ncheck_git_run_plain_parses: FAIL: {len(hits)} parse(s) of "
              "git's merged stdout+stderr. Read the answer with "
              "gitRunPlainQuery (or gitRunSeparated) and quote .diagnostic in "
              "the error message, or annotate a deliberate merged-text site "
              "with `# git-merged-text: <reason>`.")
        return 1
    print(f"check_git_run_plain_parses: ok ({len(files)} files scanned)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
