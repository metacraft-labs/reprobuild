#!/usr/bin/env python3
"""Find command STRINGS that carry shell metacharacters to an exec API that is
not guaranteed to run a shell.

This is the scanner behind ``scripts/check_shell_command_strings.sh``. Run it
directly to see the candidates with their file and line; the shell wrapper
compares its output against a checked-in baseline.

THE RULE
--------
Nim's ``execCmdEx`` / ``execProcess`` (and ``startProcess`` with
``poEvalCommand``) take a command STRING. On POSIX Nim hands that string to
``/bin/sh -c``, so ``<``, ``>``, ``|``, ``&&`` and backticks mean what a shell
author expects. On Windows there is NO shell: ``startProcess`` passes the
string to ``CreateProcessW`` verbatim, so every one of those characters becomes
an ordinary argv token. The redirect does not fail — it silently does nothing,
and the child runs with the wrong arguments and an unredirected stdin.

So: a command string containing a shell operator is a defect UNLESS it is
provably shell-bound. This scanner encodes the three ways a site can prove
that, because all three were re-derived by hand in five separate reviews:

  * ``execShellCmd`` — a real shell on both platforms (``system()`` on POSIX,
    ``cmd /c`` on Windows). Never scanned.
  * an explicit ``sh -c`` / ``bash -c`` / ``cmd /c`` at the head of the
    command, so the shell is argv[0] and the operator lands in its body. The
    exemption covers operators PACKED INTO AN ARGUMENT (``quoteShell(body)``);
    it does not cover a bare concatenation element, because
    ``"sh -c " & quoteShell(body) & " > " & log`` puts the redirect in a LATER
    argv element where no shell ever sees it.
  * a platform guard — the site is lexically inside a ``when`` whose WHOLE
    condition is POSIX-only, the ``else:`` arm of a ``when`` whose condition is
    exactly ``defined(windows)``, or an ``of`` arm that names a POSIX target ON
    A SUBJECT THAT IS AN OPERATING SYSTEM.

Anything else is reported. What survives on a clean tree goes in the baseline
with a reason; a NEW one is the thing this check exists to stop.

Each of those exemptions is a licence to ignore a real defect, so each is
probed with a complete, genuine instance in
``scripts/shell-command-strings-probes/`` and asserted by
``check_shell_command_strings.sh --self-test``. The blind spots that REMAIN are
pinned by the same probe set, so one cannot close or re-open unnoticed.

WHAT IT DELIBERATELY DOES NOT DO
--------------------------------
It is a lexical scanner, not a compiler. It resolves at most one level of local
``let``/``var``/``const`` binding for the command expression (plus any later
``&=`` / ``.add`` on the same name), which covers every instance this
repository has produced. That resolution reaches an identifier that IS the
command expression, not one that is merely a TERM in the concatenation at the
call site: ``execCmdEx(Cmd)`` resolves ``Cmd``, ``execCmdEx("x" & Redirect)``
does not resolve ``Redirect``. A command assembled through a helper proc two
files away is out of reach — the compile-time ambient-execution linter is the
tool for that class. Operators are matched per LITERAL, so a multi-character
operator torn across two adjacent literals carries none in either. And
``poEvalCommand`` must appear literally in a ``startProcess`` call's argument
text; supplied through a named option set it is invisible. Those five are
``missed_*`` in the probe directory, with a row each in its README.
"""

from __future__ import annotations

import argparse
import os
import re
import sys

# Exec APIs that take a command STRING (poEvalCommand is in their default
# options). `execShellCmd` is deliberately absent: it runs a real shell on both
# platforms, so a redirect in its argument is correct, not a defect.
STRING_APIS = ("execCmdEx", "execProcess", "execCmd")
# `startProcess` takes an argv by default; it only becomes a command-string API
# when the caller opts into poEvalCommand.
ARGV_APIS = ("startProcess",)

CALL_RE = re.compile(r"\b(" + "|".join(STRING_APIS + ARGV_APIS) + r")\s*\(")

# A shell operator, tested against the CONTENT of one string literal.
#   ` && ` ` || ` ` | `     command sequencing / pipes
#   ` > ` ` >> ` ` 2> `     output redirection (also at end of literal, which
#                           is how a concatenated `" > " & path` looks)
#   ` < `                   input redirection — the W10 defect
#   `2>&1` `>&2`            fd duplication
#   backtick                command substitution
SHELL_OPERATORS = [
    ("and-or-pipe", re.compile(r"(?:^|\s)(?:&&|\|\||\|)(?:\s|$)")),
    ("redirect-out", re.compile(r"(?:^|\s)[0-9]?>>?(?:[\s'\"/$~.]|$)")),
    ("redirect-in", re.compile(r"(?:^|\s)[0-9]?<(?:[\s'\"/$~.]|$)")),
    ("fd-dup", re.compile(r"[0-9]?>&[0-9-]")),
    ("backtick", re.compile(r"`")),
]

# Heads that prove a shell is argv[0] and the operator lands in its body.
EXPLICIT_SHELL_RE = re.compile(
    r"^\s*(?:[^\s]*/)?(?:sh|bash|dash|zsh|ksh|cmd(?:\.exe)?|powershell(?:\.exe)?|pwsh)"
    r"(?:\s+/[dD])?\s+(?:-c|/[cC]|-Command)\b"
)
SHELL_ARGV0_RE = re.compile(
    r"^(?:[^\s]*/)?(?:sh|bash|dash|zsh|ksh|cmd(?:\.exe)?|powershell(?:\.exe)?|pwsh)$"
)

# Block headers that make a POSIX shell certain for everything inside them.
#
# These are deliberately WHOLE-CONDITION tests rather than prefix matches. A
# prefix match reads `when defined(linux) or defined(windows):` as POSIX-only
# and waves the Windows half of it through — the condition it actually
# encodes is the opposite of the one it is being asked about.
POSIX_TERM_RE = re.compile(
    r"^(?:defined\((?:posix|linux|macosx|macos|osx|bsd|freebsd|openbsd|netbsd|android|unix)\)"
    r"|not\s+defined\(windows\))$"
)
WINDOWS_TERM_RE = re.compile(r"^defined\(windows\)$")

# A `case` arm may only claim the POSIX exemption when the thing being
# SWITCHED ON is an operating system. An arm named `sfPosixStyle` on a
# shell-FLAVOUR enum, or `of "linux-headers":` on an artefact name, is
# reachable on Windows and is exactly the shape this exemption used to wave
# through.
OS_SUBJECT_RE = re.compile(
    r"^(?:[A-Za-z_][A-Za-z0-9_]*\.)*"
    r"(?:target_?os|host_?os|current_?os|[a-z_]*platform|os|osname|goos)$",
    re.IGNORECASE,
)
POSIX_ARM_NAME_RE = re.compile(
    r"^of\s+([A-Za-z_][A-Za-z0-9_]*(?:\s*,\s*[A-Za-z_][A-Za-z0-9_]*)*)\s*:$"
)
POSIX_ARM_TOKEN_RE = re.compile(r"posix|linux|darwin|macos|unix|bsd", re.IGNORECASE)


def split_top_level(condition: str, keyword: str) -> list[str]:
    """Split ``condition`` on a top-level (unparenthesised) ``keyword``."""
    parts: list[str] = []
    depth = 0
    buf: list[str] = []
    tokens = re.split(r"(\s+|\(|\))", condition)
    for tok in tokens:
        if tok == "(":
            depth += 1
        elif tok == ")":
            depth -= 1
        if depth == 0 and tok == keyword:
            parts.append("".join(buf).strip())
            buf = []
            continue
        buf.append(tok)
    parts.append("".join(buf).strip())
    return [p for p in parts if p]


def unwrap_parens(text: str) -> str:
    """Drop parentheses that WRAP the whole expression, and only those.

    ``str.strip("()")`` is not this function: on ``defined(windows)`` it eats
    the closing paren of the call and leaves ``defined(windows``, which then
    matches nothing.
    """
    text = text.strip()
    while text.startswith("(") and text.endswith(")"):
        depth = 0
        wraps = True
        for i, ch in enumerate(text):
            if ch == "(":
                depth += 1
            elif ch == ")":
                depth -= 1
                if depth == 0 and i != len(text) - 1:
                    wraps = False
                    break
        if not wraps:
            break
        text = text[1:-1].strip()
    return text


def when_condition(stripped: str) -> str:
    """The condition of a ``when``/``elif`` header, without the trailing colon."""
    body = stripped[len("when "):] if stripped.startswith("when ") else stripped[len("elif "):]
    return body.rstrip().rstrip(":").strip()


def condition_is_posix_only(condition: str) -> bool:
    """True when the condition can only hold on a POSIX target.

    ``or`` WIDENS, so every disjunct must be POSIX-only; ``and`` NARROWS, so a
    single POSIX-only conjunct is enough.
    """
    disjuncts = split_top_level(condition, "or")
    if not disjuncts:
        return False
    for disjunct in disjuncts:
        conjuncts = split_top_level(disjunct, "and")
        if not any(POSIX_TERM_RE.match(unwrap_parens(c)) for c in conjuncts):
            return False
    return True


def condition_else_is_posix_only(condition: str) -> bool:
    """True when the ``else:`` arm of ``when <condition>`` can only be POSIX.

    That needs ``not condition`` to imply POSIX, i.e. the condition must be
    exactly ``defined(windows)``. ``when defined(windows) and X:`` does NOT
    qualify — its ``else`` still contains Windows-without-X.
    """
    return bool(WINDOWS_TERM_RE.match(unwrap_parens(condition)))


def strip_comment(line: str) -> str:
    """Drop a trailing Nim comment, honouring string literals and char literals."""
    out = []
    i, n = 0, len(line)
    in_str = False
    in_chr = False
    while i < n:
        ch = line[i]
        if in_str:
            out.append(ch)
            if ch == "\\":
                if i + 1 < n:
                    out.append(line[i + 1])
                i += 2
                continue
            if ch == '"':
                in_str = False
            i += 1
            continue
        if in_chr:
            out.append(ch)
            if ch == "\\":
                if i + 1 < n:
                    out.append(line[i + 1])
                i += 2
                continue
            if ch == "'":
                in_chr = False
            i += 1
            continue
        if ch == "#":
            break
        if ch == '"':
            in_str = True
        elif ch == "'" and not (i and (line[i - 1].isalnum() or line[i - 1] == "_")):
            # A `'` right after an alphanumeric is Nim's numeric type suffix
            # (`100'u32`), not a char literal. Treating it as one would swallow
            # the rest of the line and hide a command string later on it.
            in_chr = True
        out.append(ch)
        i += 1
    return "".join(out)


def string_literals_with_depth(text: str) -> list[tuple[str, int]]:
    """Every double-quoted literal in ``text`` with its parenthesis depth.

    Depth matters for the ``sh -c`` exemption: a literal at depth 0 is a BARE
    element of the concatenation that builds the command, so it sits OUTSIDE
    the ``-c`` body; a literal inside a call (``quoteShell(...)``, ``q(...)``)
    is being packed into one argv element and is therefore inside it.
    """
    literals: list[tuple[str, int]] = []
    i, n = 0, len(text)
    depth = 0
    while i < n:
        ch = text[i]
        if ch in "([{":
            depth += 1
            i += 1
            continue
        if ch in ")]}":
            depth -= 1
            i += 1
            continue
        if ch == '"':
            j = i + 1
            buf = []
            while j < n:
                if text[j] == "\\" and j + 1 < n:
                    buf.append(text[j : j + 2])
                    j += 2
                    continue
                if text[j] == '"':
                    break
                buf.append(text[j])
                j += 1
            literals.append(("".join(buf), depth))
            i = j + 1
            continue
        i += 1
    return literals


def string_literals(text: str) -> list[str]:
    """Every double-quoted literal in ``text``, with escapes left as written."""
    return [lit for lit, _ in string_literals_with_depth(text)]


def offending_literals(expr: str) -> list[tuple[str, str, int]]:
    """(operator-class, literal, paren-depth) for every literal carrying one."""
    hits = []
    for lit, depth in string_literals_with_depth(expr):
        for name, pattern in SHELL_OPERATORS:
            if pattern.search(lit):
                hits.append((name, lit, depth))
                break
    return hits


def indent_of(line: str) -> int:
    return len(line) - len(line.lstrip(" "))


class Source:
    """One Nim file, pre-chewed into comment-free lines plus block context."""

    def __init__(self, path: str, text: str):
        self.path = path
        self.raw = text.split("\n")
        self.code = [strip_comment(ln).rstrip() for ln in self.raw]
        self.posix_guarded = self._compute_platform_guards()

    def _compute_platform_guards(self) -> list[bool]:
        """True for every line lexically inside a POSIX-only block."""
        guarded = [False] * len(self.code)
        # stack of (indent, is_posix_only)
        stack: list[tuple[int, bool]] = []
        # The condition of the branch most recently opened at each indent, so
        # an `else:` at that indent can be resolved against it.
        #
        # EVERY block header at an indent overwrites this, and every entry at a
        # deeper indent is dropped when the indentation comes back out. Before,
        # only `when`/`elif` wrote here and nothing ever cleared it, so an
        # ordinary runtime `if` / `else` pair inherited an unrelated
        # `when defined(windows)` from earlier in the file and its `else:`
        # silently became a "POSIX arm". That needed no adversarial intent at
        # all — it is the ordinary shape of a Nim file.
        last_branch: dict[int, str] = {}
        # The subject of the innermost enclosing `case`, per indent, so an `of`
        # arm can be asked WHAT is being switched on rather than only what the
        # arm happens to be called.
        case_subject: list[tuple[int, str]] = []
        for idx, line in enumerate(self.code):
            stripped = line.strip()
            if not stripped:
                guarded[idx] = bool(stack) and any(p for _, p in stack)
                continue
            ind = indent_of(line)
            while stack and stack[-1][0] >= ind:
                stack.pop()
            for deeper in [k for k in last_branch if k > ind]:
                del last_branch[deeper]
            while case_subject and case_subject[-1][0] > ind:
                case_subject.pop()
            guarded[idx] = any(p for _, p in stack)
            if stripped.startswith("case "):
                subject = stripped[len("case "):].rstrip().rstrip(":").strip()
                case_subject.append((ind, subject))
                last_branch[ind] = stripped
                continue
            if not stripped.endswith(":"):
                continue
            posix_only = False
            is_of_arm = stripped.startswith("of ")
            if stripped.startswith("when ") or stripped.startswith("elif "):
                posix_only = condition_is_posix_only(when_condition(stripped))
                if stripped.startswith("when "):
                    last_branch[ind] = stripped
            elif stripped == "else:":
                prior = last_branch.get(ind, "")
                # The `else:` of `when defined(windows)` is the POSIX arm — but
                # only when `prior` really is that `when`, and only when its
                # condition is exactly `defined(windows)`.
                if prior.startswith("when "):
                    posix_only = condition_else_is_posix_only(when_condition(prior))
            elif is_of_arm:
                posix_only = self._arm_is_posix_only(stripped, case_subject)
                last_branch[ind] = stripped
            else:
                last_branch[ind] = stripped
            stack.append((ind, posix_only))
        return guarded

    @staticmethod
    def _arm_is_posix_only(stripped: str, case_subject: list[tuple[int, str]]) -> bool:
        """Whether an ``of`` arm proves a POSIX target.

        Two conditions, and the exemption used to check neither:

        * the case SUBJECT must be an operating system. `of sfPosixStyle:` on a
          shell-flavour enum is reachable on Windows however POSIX its name
          reads.
        * the arm must be a bare enum identifier. `of "linux-headers":` names an
          artefact, not a platform, and is likewise reachable on Windows.
        """
        if not case_subject:
            return False
        subject = case_subject[-1][1]
        if not OS_SUBJECT_RE.match(subject):
            return False
        match = POSIX_ARM_NAME_RE.match(stripped)
        if not match:
            return False
        names = [n.strip() for n in match.group(1).split(",")]
        if any("windows" in n.lower() for n in names):
            return False
        return all(POSIX_ARM_TOKEN_RE.search(n) for n in names)

    def call_argument_text(self, line_idx: int, paren_col: int) -> str:
        """The text between the call's parentheses, across continuation lines."""
        depth = 0
        chunks: list[str] = []
        idx = line_idx
        col = paren_col
        while idx < len(self.code) and idx < line_idx + 60:
            line = self.code[idx]
            buf = []
            i = col
            in_str = False
            while i < len(line):
                ch = line[i]
                if in_str:
                    buf.append(ch)
                    if ch == "\\":
                        if i + 1 < len(line):
                            buf.append(line[i + 1])
                        i += 2
                        continue
                    if ch == '"':
                        in_str = False
                    i += 1
                    continue
                if ch == '"':
                    in_str = True
                    buf.append(ch)
                    i += 1
                    continue
                if ch in "([{":
                    depth += 1
                    if depth == 1 and ch == "(":
                        i += 1
                        continue
                elif ch in ")]}":
                    depth -= 1
                    if depth == 0:
                        chunks.append("".join(buf))
                        return " ".join(chunks)
                buf.append(ch)
                i += 1
            chunks.append("".join(buf))
            idx += 1
            col = 0
        return " ".join(chunks)


IDENT_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
STATEMENT_START_RE = re.compile(
    r"^(let|var|const|if|elif|else|for|while|case|of|try|except|finally|"
    r"return|result|discard|proc|func|template|macro|when|block|yield|raise)\b"
)


def resolve_binding(src: Source, name: str, call_idx: int) -> str:
    """The RHS of the nearest ``let``/``var`` binding of ``name`` above the call,
    plus any later ``&=`` / ``.add`` on the same name before the call."""
    bind_re = re.compile(r"^\s*(?:let|var|const)\s+" + re.escape(name) + r"\b[^=]*=(.*)$")
    # `var cmd: string` followed by `cmd = "…"` is the same binding, spelled in
    # two statements; without this the command expression resolves to nothing
    # and the site reports clean.
    assign_re = re.compile(r"^\s*" + re.escape(name) + r"\s*=(?!=)(.*)$")
    start = None
    matched = None
    for idx in range(call_idx, -1, -1):
        m = bind_re.match(src.code[idx]) or assign_re.match(src.code[idx])
        if m:
            start = idx
            matched = m
            break
    if start is None:
        return ""
    base_indent = indent_of(src.code[start])
    parts = [matched.group(1)]
    idx = start + 1
    while idx < len(src.code) and idx < start + 40:
        line = src.code[idx]
        if not line.strip():
            idx += 1
            continue
        if indent_of(line) <= base_indent:
            break
        if STATEMENT_START_RE.match(line.strip()):
            break
        parts.append(line.strip())
        idx += 1
    # later mutation of the same name, e.g. `cmd.add(" 2>&1")` / `cmd &= " < f"`
    mutate_re = re.compile(
        r"^\s*" + re.escape(name) + r"\s*(?:&=|=\s*" + re.escape(name) + r"\b)|"
        r"^\s*" + re.escape(name) + r"\.add\("
    )
    for idx in range(start + 1, call_idx + 1):
        if mutate_re.match(src.code[idx]):
            parts.append(src.code[idx].strip())
    return " ".join(parts)


def first_positional(arg_text: str) -> str:
    """The first positional argument of a call argument list."""
    depth = 0
    in_str = False
    for i, ch in enumerate(arg_text):
        if in_str:
            if ch == "\\":
                continue
            if ch == '"':
                in_str = False
            continue
        if ch == '"':
            in_str = True
            continue
        if ch in "([{":
            depth += 1
        elif ch in ")]}":
            depth -= 1
        elif ch == "," and depth == 0:
            return arg_text[:i].strip()
    return arg_text.strip()


def normalize(text: str) -> str:
    return " ".join(text.split())


def scan_file(path: str, rel: str) -> list[dict]:
    with open(path, "r", encoding="utf-8", errors="replace", newline="") as handle:
        text = handle.read().replace("\r\n", "\n")
    src = Source(rel, text)
    findings = []
    for idx, line in enumerate(src.code):
        for match in CALL_RE.finditer(line):
            api = match.group(1)
            arg_text = src.call_argument_text(idx, match.end() - 1)
            if not arg_text.strip():
                continue
            if api in ARGV_APIS and "poEvalCommand" not in arg_text:
                # argv form: the operator can only be a defect if it is inside a
                # command string, and there is none. Still worth a look when
                # argv[0] is a shell — but that is the SAFE case by definition.
                continue
            if api in STRING_APIS and "options" in arg_text and "poEvalCommand" not in arg_text:
                # An explicit option set without poEvalCommand means argv, not a
                # command string.
                if re.search(r"\boptions\s*=\s*\{", arg_text):
                    continue
            expr = first_positional(arg_text)
            resolved = expr
            if IDENT_RE.match(expr):
                bound = resolve_binding(src, expr, idx)
                if bound:
                    resolved = bound
            hits = offending_literals(resolved)
            if not hits:
                continue
            literals = string_literals(resolved)
            head = literals[0] if literals else ""
            if EXPLICIT_SHELL_RE.match(head) or SHELL_ARGV0_RE.match(head.strip()):
                # A shell IS argv[0] — but that only exempts operators INSIDE
                # its `-c` body. `"sh -c " & quoteShell(body) & " > " & log`
                # puts the redirect in a LATER argv element, where `sh` receives
                # `>` and the path as ordinary positional parameters and the
                # redirect never happens. Keep the exemption for literals packed
                # into an argument (depth > 0) and withdraw it for bare
                # concatenation elements, which is where that shape lives.
                #
                # The head literal itself is at depth 0 and is exempt by
                # construction: it is the one that carries the `-c`.
                outside = [
                    h for h in hits
                    if h[2] == 0 and h[1] != head
                ]
                if not outside:
                    continue
                hits = outside
            if src.posix_guarded[idx]:
                continue
            classes = sorted({name for name, _, _ in hits})
            offenders = " ".join(sorted({normalize(lit) for _, lit, _ in hits}))
            findings.append(
                {
                    "file": rel,
                    "line": idx + 1,
                    "api": api,
                    "classes": ",".join(classes),
                    "offenders": offenders,
                }
            )
    return findings


def iter_sources(roots: list[str]) -> list[tuple[str, str]]:
    seen = []
    for root in roots:
        if os.path.isfile(root):
            seen.append((root, root.replace(os.sep, "/")))
            continue
        for dirpath, dirnames, filenames in os.walk(root):
            dirnames[:] = [
                d for d in dirnames if d not in ("tests", "vendor", "nimcache", "build")
            ]
            for name in sorted(filenames):
                if not name.endswith(".nim"):
                    continue
                full = os.path.join(dirpath, name)
                rel = full.replace(os.sep, "/")
                if "/tests/" in rel or rel.endswith("/ambient_execution.nim"):
                    continue
                seen.append((full, rel))
    return sorted(seen, key=lambda pair: pair[1])


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Find command strings whose shell metacharacters reach an "
                    "exec API that does not run a shell on every platform. "
                    "The rule, the three exemptions it encodes and their "
                    "evidence are in this file's module docstring.")
    parser.add_argument(
        "roots",
        nargs="*",
        default=["libs", "apps", "tools", "repro.nim"],
        help="directories/files to scan (default: the first-party production tree)",
    )
    parser.add_argument(
        "--with-lines",
        action="store_true",
        help="include file:line in the output (human view; NOT baseline-stable)",
    )
    args = parser.parse_args()

    findings: list[dict] = []
    for full, rel in iter_sources(args.roots):
        findings.extend(scan_file(full, rel))

    rows = set()
    for f in findings:
        if args.with_lines:
            rows.add(f"{f['file']}:{f['line']}|{f['api']}|{f['classes']}|{f['offenders']}")
        else:
            # Line-number free so the baseline survives edits above the site.
            rows.add(f"{f['file']}|{f['api']}|{f['classes']}|{f['offenders']}")
    for row in sorted(rows):
        print(row)
    return 0


if __name__ == "__main__":
    sys.exit(main())
