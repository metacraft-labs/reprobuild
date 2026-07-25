#!/usr/bin/env python3
"""Generate the M0 reprobuild test-suite inventory.

The default mode is static and quick: it reads the checked-in test edge table,
classifies the current tests, finds direct compiler invocations in test bodies,
and writes a markdown report plus JSON details.

Use --run-suite in an isolated campaign worktree when a timed baseline is
needed. With --clean-first, that mode removes repo-local build outputs, runs
scripts/run_tests.sh once for the cold pass, and then runs N warm passes while
preserving each runner summary under bench-results.
"""

from __future__ import annotations

import argparse
import ast
import dataclasses
import datetime as dt
import hashlib
import json
import os
import platform
import re
import shutil
import signal
import stat
import subprocess
import sys
import time
from collections.abc import Mapping
from pathlib import Path
from typing import Any


DEFAULT_JSON = Path("benchmarks/reports/reprobuild-suite-m0-inventory.json")
DEFAULT_REPORT = Path("benchmarks/reports/reprobuild-suite-m0-baseline.md")
DEFAULT_SLOW_REVIEWS = Path("benchmarks/reports/reprobuild-suite-m0-slow-reviews.json")
GENERATED_RESULTS_DIR = Path("bench-results/reprobuild-suite-m0")
SOURCE_FINGERPRINT_EXCLUDES = {
    DEFAULT_JSON.as_posix(),
    DEFAULT_REPORT.as_posix(),
    DEFAULT_SLOW_REVIEWS.as_posix(),
}
SLOW_REVIEW_CATEGORIES = {
    "product inefficiency",
    "runtime compilation",
    "redundant setup",
    "oversized fixture",
    "justified integration scope",
}

COMPILER_PATTERNS = [
    ("nim-c", re.compile(r"(?<![\w-])nim\s+c(?:\s|[\"',\]]|$)")),
    ("nim-compile", re.compile(r"(?<![\w-])nim\s+compile(?:\s|[\"',\]]|$)")),
    ("nim-argv", re.compile(r"[\"']nim[\"'].{0,80}[\"'](?:c|compile)[\"']")),
    ("nim-variable-argv", re.compile(r"\bnim(?:Exe|Bin|Compiler)\b.{0,80}[\"'](?:c|compile)[\"']")),
    # Nim commands are often assembled in stages, for example
    # `compileVerb = "c --compileOnly ..."`, then `cmd = nimExe & compileVerb`,
    # then `execCmdEx(cmd)`. The data-flow pass in `compiler_invocations`
    # verifies that this fragment eventually reaches an executor.
    ("nim-compile-verb", re.compile(r"[\"']c\s+(?:--compileOnly|--run|--out:|--nimcache:)")),
    ("nimble-build", re.compile(r"(?<![\w-])nimble\s+build(?:\s|[\"',\]]|$)")),
    ("gcc", re.compile(r"(?<![\w-])gcc(?:\s|[\"',\]]|$)")),
    ("g++", re.compile(r"(?<![\w-])g\+\+(?:\s|[\"',\]]|$)")),
    ("clang", re.compile(r"(?<![\w-])clang(?:\s|[\"',\]]|$)")),
    ("clang++", re.compile(r"(?<![\w-])clang\+\+(?:\s|[\"',\]]|$)")),
    ("cc", re.compile(r"(?<![\w-])cc(?:\s|[\"',\]]|$)")),
    ("c++", re.compile(r"(?<![\w-])c\+\+(?:\s|[\"',\]]|$)")),
    ("rustc", re.compile(r"(?<![\w-])rustc(?:\s|[\"',\]]|$)")),
    ("javac", re.compile(r"(?<![\w-])javac(?:\s|[\"',\]]|$)")),
    ("swiftc", re.compile(r"(?<![\w-])swiftc(?:\s|[\"',\]]|$)")),
    ("zig-build", re.compile(r"(?<![\w-])zig\s+build(?:\s|[\"',\]]|$)")),
    ("cargo-build", re.compile(r"(?<![\w-])cargo\s+build(?:\s|[\"',\]]|$)")),
    ("go-build", re.compile(r"(?<![\w-])go\s+build(?:\s|[\"',\]]|$)")),
    ("dotnet-build", re.compile(r"(?<![\w-])dotnet\s+build(?:\s|[\"',\]]|$)")),
    ("cmake-build", re.compile(r"(?<![\w-])cmake\s+--build(?:\s|[\"',\]]|$)")),
    ("make", re.compile(r"(?<![\w-])make(?:\s|[\"',\]]|$)")),
    ("ninja", re.compile(r"(?<![\w-])ninja(?:\s|[\"',\]]|$)")),
    ("dynamic-c-compiler", re.compile(r"\b(?:startProcess|execProcess)\(\s*(?:ccPath|crossGcc)\b")),
    ("wix-candle", re.compile(r"\bquoteShell\(candle\)")),
    ("wix-light", re.compile(r"\bquoteShell\(light\)")),
    ("inno-iscc", re.compile(r"\bquoteShell\(iscc\)")),
]

EXECUTOR_PATTERN = re.compile(
    r"\b(execCmdEx|execCmd|execProcess|startProcess|runShell|shellCommand|"
    r"runCommand|runNim|runSuccess|requireSuccess|requireNimSuccess)\b"
)

ARGV_COMPILER_TOKEN = re.compile(
    r"[\"'](?:nim|nimble|gcc|g\+\+|clang|clang\+\+|cc|c\+\+|rustc|javac|"
    r"swiftc|zig|cargo|go|dotnet|cmake|make|ninja)[\"']\s*,"
)

PLATFORM_PATH_TOKENS = [
    "macos",
    "windows",
    "scoop",
    "launcher-isolation",
    "dotfiles-replacement",
    "system_generations",
    "integration-real",
]

PLATFORM_CONTENT_PATTERNS = [
    re.compile(r"\b(sudo|privileged|firewall|launchd|systemd\s+system|wsl|tart|lima)\b", re.I),
    re.compile(r"\b(real[-_ ]host|disposable[-_ ]vm|_vm\b|vm_)\b", re.I),
]

INTEGRATION_CONTENT_PATTERNS = [
    re.compile(r"\bbuild/bin/repro\b"),
    re.compile(r"\breproBin\b"),
    re.compile(r"\bexecCmdEx\("),
    re.compile(r"\bstartProcess\("),
    re.compile(r"\brunShell\("),
]


@dataclasses.dataclass
class TestSpec:
    source: str
    binary: str
    defines: list[str]
    requires_repro_binary: bool
    target_os: str
    language: str = "nim"

    @property
    def stem(self) -> str:
        return Path(self.source).stem

    @property
    def owner(self) -> str:
        parts = Path(self.source).parts
        if len(parts) >= 2 and parts[0] == "libs":
            return "/".join(parts[:2])
        if len(parts) >= 2 and parts[0] == "tools":
            return "/".join(parts[:2])
        if len(parts) >= 2 and parts[0] == "tests":
            return "/".join(parts[:2])
        if len(parts) >= 3 and parts[0] == "recipes":
            return "/".join(parts[:3])
        return parts[0] if parts else "."


def rel(path: Path, root: Path) -> str:
    try:
        return path.relative_to(root).as_posix()
    except ValueError:
        return path.as_posix()


def now_utc() -> str:
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def git_value(root: Path, *args: str) -> str:
    try:
        return subprocess.check_output(
            ["git", *args], cwd=root, text=True, stderr=subprocess.DEVNULL
        ).strip()
    except (OSError, subprocess.CalledProcessError):
        return "unknown"


def source_fingerprint(root: Path) -> str:
    """Fingerprint the exact source snapshot used by a timing run.

    Generated M0 reports are excluded so regenerating the report does not
    invalidate its own timing evidence. Every tracked path plus every relevant
    untracked path is hashed from worktree content, including executable and
    symlink state. The result is deliberately independent of HEAD and index
    state, so committing an otherwise identical measured tree does not make
    the checked-in timing evidence stale. Ignored build outputs are omitted.
    """
    digest = hashlib.sha256()
    try:
        raw = subprocess.check_output(
            ["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"],
            cwd=root,
        )
    except (OSError, subprocess.CalledProcessError):
        raw = b""
        digest.update(b"GIT-LS-FILES-UNAVAILABLE\0")
    paths = sorted(
        path.decode("utf-8", errors="surrogateescape")
        for path in raw.split(b"\0")
        if path
    )
    for path in paths:
        if path in SOURCE_FINGERPRINT_EXCLUDES:
            continue
        source_path = root / path
        # A tracked deletion remains in git ls-files until it is committed.
        # Omit absent paths so an otherwise identical content snapshot has the
        # same fingerprint before and after that commit.
        if not os.path.lexists(source_path):
            continue
        digest.update(b"PATH\0")
        digest.update(path.encode("utf-8", errors="surrogateescape"))
        digest.update(b"\0")
        try:
            mode = source_path.lstat().st_mode
            if stat.S_ISLNK(mode):
                digest.update(b"SYMLINK\0")
                content = os.readlink(source_path).encode(
                    "utf-8", errors="surrogateescape"
                )
                digest.update(len(content).to_bytes(8, "big"))
                digest.update(content)
            elif stat.S_ISREG(mode):
                digest.update(b"REGULAR\0")
                digest.update(b"EXEC\0" if mode & 0o111 else b"NOEXEC\0")
                content = source_path.read_bytes()
                digest.update(len(content).to_bytes(8, "big"))
                digest.update(content)
            else:
                digest.update(("MODE\0" + oct(mode) + "\0").encode())
        except OSError:
            digest.update(b"MISSING\0")
        digest.update(b"\0")
    return digest.hexdigest()


def checkout_metadata(path: Path) -> dict[str, Any] | None:
    """Describe a Git checkout that contributes source to the suite run."""
    if not path.exists():
        return None
    top_level = git_value(path, "rev-parse", "--show-toplevel")
    if top_level == "unknown":
        return None
    root = Path(top_level)
    status = git_value(root, "status", "--short")
    return {
        "path": str(root),
        "head": git_value(root, "rev-parse", "HEAD"),
        "branch": git_value(root, "branch", "--show-current"),
        "dirty": status not in ("", "unknown"),
        "status": status,
    }


def external_source_checkouts(
    environ: Mapping[str, str] | None = None,
) -> dict[str, dict[str, Any]]:
    """Capture revisions for out-of-tree source consumed by integration tests.

    The CodeTracer subset tests intentionally exercise a real checkout and its
    sibling source producers. Merely recording their filesystem paths is not
    reproducible: those paths can advance independently of reprobuild. Record
    the exact Git state used by every timed run.
    """
    environment = os.environ if environ is None else environ
    candidates: dict[str, Path] = {}
    code_tracer_root = environment.get("CODETRACER_ROOT", "")
    if code_tracer_root:
        root = Path(code_tracer_root).expanduser().absolute()
        candidates["codetracer"] = root
        for name in [
            "codetracer-trace-format-nim",
            "isonim",
            "nim-acp",
            "nim-agent-harbor",
            "nim-agents",
            "nim-everywhere",
        ]:
            candidates[name] = root.parent / name
    elif environment.get("CODETRACER_SRC", ""):
        source = Path(environment["CODETRACER_SRC"]).expanduser().absolute()
        candidates["codetracer"] = source.parent if source.name == "src" else source

    fixture_isonim = environment.get("CODETRACER_TEST_ISONIM_ROOT", "")
    if fixture_isonim:
        source = Path(fixture_isonim).expanduser().absolute()
        candidates["isonim"] = source.parent if source.name == "src" else source

    env_sources = {
        "codetracer-trace-format-nim": ("CODETRACER_TRACE_FORMAT_NIM_SRC",),
        "io-mon": ("IO_MON_SRC",),
        "runquota": ("RUNQUOTA_SRC",),
        "nim-shm-queue": ("SHM_QUEUE_SRC",),
        "nim-shm-gset": ("SHM_GSET_SRC",),
        "nim-stackable-hooks": (
            "NIM_STACKABLE_HOOKS_SRC",
            "STACKABLE_HOOKS_SRC",
        ),
        "reprobuild-test-adapters": ("REPRO_TEST_ADAPTERS_SRC",),
        "reprobuild-ct-test-runner": ("REPRO_CT_TEST_RUNNER_SRC",),
    }
    for name, env_names in env_sources.items():
        value = next(
            (environment.get(env_name, "") for env_name in env_names
             if environment.get(env_name, "")),
            "",
        )
        if value and name not in candidates:
            candidates[name] = Path(value).expanduser().absolute()

    result: dict[str, dict[str, Any]] = {}
    for name, candidate in candidates.items():
        metadata = checkout_metadata(candidate)
        if metadata is not None:
            result[name] = metadata
    return result


def runtime_metadata(
    environ: Mapping[str, str] | None = None,
) -> dict[str, Any]:
    environment = os.environ if environ is None else environ
    tracked_env = [
        "TMPDIR",
        "TMP",
        "TEMP",
        "REPROBUILD_MAX_PARALLELISM",
        "REPROBUILD_TEST_THREADS",
        "REPROBUILD_TEST_WARM_REUSE",
        "REPROBUILD_BENCH_LIVE",
        "NIX_BUILD_CORES",
        "NIX_CONFIG",
        "CODETRACER_ROOT",
        "CODETRACER_SRC",
        "CODETRACER_TEST_ISONIM_ROOT",
        "CODETRACER_TRACE_FORMAT_NIM_SRC",
        "CODETRACER_RESULTS_SRC",
        "IO_MON_SRC",
        "RUNQUOTA_SRC",
        "SHM_QUEUE_SRC",
        "SHM_GSET_SRC",
        "NIM_STACKABLE_HOOKS_SRC",
        "STACKABLE_HOOKS_SRC",
        "REPRO_TEST_ADAPTERS_SRC",
        "REPRO_CT_TEST_RUNNER_SRC",
    ]
    tools: dict[str, str] = {"python": f"Python {platform.python_version()}"}
    for name, command in {
        "git": ["git", "--version"],
        "nim": ["nim", "--version"],
        "nix": ["nix", "--version"],
    }.items():
        try:
            output = subprocess.check_output(
                command,
                stderr=subprocess.STDOUT,
                text=True,
                timeout=10,
            )
            tools[name] = output.splitlines()[0].strip()
        except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired):
            tools[name] = "unavailable"
    return {
        "argv": sys.argv,
        "cwd": str(Path.cwd()),
        "pythonExecutable": sys.executable,
        "pythonVersion": platform.python_version(),
        "host": {
            "platform": platform.platform(),
            "machine": platform.machine(),
            "logicalCpuCount": os.cpu_count(),
        },
        "tools": tools,
        "environment": {
            key: environment[key] for key in tracked_env if key in environment
        },
        "sourceCheckouts": external_source_checkouts(environment),
    }


def parse_string_seq(src: str) -> list[str]:
    return re.findall(r'"((?:\\"|[^"])*)"', src)


def parse_repro_tests(root: Path) -> tuple[list[TestSpec], list[TestSpec]]:
    text = (root / "repro_tests.nim").read_text(encoding="utf-8")
    spec_re = re.compile(
        r"TestSpec\(\s*"
        r'source:\s*"([^"]+)",\s*'
        r'binary:\s*"([^"]+)",\s*'
        r"defines:\s*@\[(.*?)\],\s*"
        r"requiresReproBinary:\s*(true|false),\s*"
        r"extraPassC:\s*@\[(.*?)\],\s*"
        r"extraPassL:\s*@\[(.*?)\],\s*"
        r"targetOs:\s*(\w+)\)",
        re.S,
    )
    nim_specs = [
        TestSpec(
            source=m.group(1),
            binary=m.group(2),
            defines=parse_string_seq(m.group(3)),
            requires_repro_binary=m.group(4) == "true",
            target_os=m.group(7),
        )
        for m in spec_re.finditer(text)
    ]

    py_specs: list[TestSpec] = []
    py_match = re.search(r"const\s+pythonTestPaths\*:\s*seq\[string\]\s*=\s*@\[(.*?)\]", text, re.S)
    if py_match:
        for source in parse_string_seq(py_match.group(1)):
            py_specs.append(
                TestSpec(
                    source=source,
                    binary="",
                    defines=[],
                    requires_repro_binary=False,
                    target_os="soAny",
                    language="python",
                )
            )
    return nim_specs, py_specs


def read_text(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return ""


def load_slow_review_document(root: Path) -> dict[str, Any]:
    path = root / DEFAULT_SLOW_REVIEWS
    try:
        doc = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {"provenance": {}, "reviews": {}}
    reviews = doc.get("reviews", {})
    if not isinstance(reviews, dict):
        reviews = {}
    result: dict[str, dict[str, str]] = {}
    for name, review in reviews.items():
        if not isinstance(name, str) or not isinstance(review, dict):
            continue
        category = str(review.get("classification", ""))
        justification = str(review.get("justification", ""))
        follow_up = str(review.get("followUp", ""))
        if category not in SLOW_REVIEW_CATEGORIES or not justification or not follow_up:
            continue
        result[name] = {
            "classification": category,
            "justification": justification,
            "followUp": follow_up,
        }
    provenance = doc.get("provenance", {})
    if not isinstance(provenance, dict):
        provenance = {}
    return {"provenance": provenance, "reviews": result}


def load_slow_reviews(root: Path) -> dict[str, dict[str, str]]:
    return load_slow_review_document(root)["reviews"]


@dataclasses.dataclass(frozen=True)
class NimToken:
    kind: str
    value: str
    line: int
    column: int


@dataclasses.dataclass(frozen=True)
class NimUnittestBindings:
    unqualified: frozenset[str]
    qualifiers: frozenset[str]


@dataclasses.dataclass(frozen=True)
class NimDeclaration:
    kind: str
    token: NimToken
    expression_start: int
    colon: int


NIM_DELIMITERS = {"(": ")", "[": "]", "{": "}"}
NIM_CLOSING_DELIMITERS = set(NIM_DELIMITERS.values())
NIM_WORD_OPERATORS = {
    "and",
    "div",
    "in",
    "is",
    "isnot",
    "mod",
    "notin",
    "or",
    "shl",
    "shr",
    "xor",
}
NIM_INLINE_BLOCK_KEYWORDS = {
    "block",
    "case",
    "defer",
    "elif",
    "else",
    "except",
    "finally",
    "for",
    "if",
    "of",
    "static",
    "try",
    "when",
    "while",
}
NIM_BINDING_KEYWORDS = {
    "const",
    "func",
    "let",
    "macro",
    "proc",
    "template",
    "type",
    "var",
}
NIM_UNITTEST_PROVIDER_MODULES = {
    # This repository's protocol shim deliberately overrides and re-exports
    # std/unittest's suite/test templates.
    "ct_test_unittest_parallel",
}


def nim_identifier_value(token: NimToken) -> str | None:
    if token.kind == "identifier":
        return token.value
    if token.kind == "quoted_identifier" and token.value.endswith("`"):
        return token.value[1:-1]
    return None


def nim_name_key(name: str) -> str:
    if not name:
        return ""
    return name[0] + name[1:].replace("_", "").lower()


def nim_identifier_matches(token: NimToken, expected: str) -> bool:
    identifier = nim_identifier_value(token)
    return (
        identifier is not None
        and nim_name_key(identifier) == nim_name_key(expected)
    )


def nim_tokens(text: str) -> list[NimToken]:
    """Lex enough Nim syntax to find command-style test declarations.

    The inventory must not mistake fixture source, shell snippets, or comments
    for declarations. A full Nim parser would require compiling every test
    with its platform-specific dependency graph. This lexer instead recognizes
    all lexical constructs that can contain arbitrary text, including raw and
    generalized strings, and retains the punctuation needed by the
    import/statement analysis below.
    """

    tokens: list[NimToken] = []
    index = 0
    line = 1
    column = 0
    length = len(text)

    def advance(count: int = 1) -> None:
        nonlocal index, line, column
        for _ in range(count):
            if index >= length:
                return
            if text[index] == "\n":
                line += 1
                column = 0
            elif text[index] == "\t":
                column = (column // 8 + 1) * 8
            else:
                column += 1
            index += 1

    def add(kind: str, value: str, token_line: int, token_column: int) -> None:
        tokens.append(NimToken(kind, value, token_line, token_column))

    def consume_string(raw: bool) -> None:
        triple = text.startswith('"""', index)
        advance(3 if triple else 1)
        while index < length:
            if triple:
                if text.startswith('"""', index):
                    advance(3)
                    return
                advance()
            elif text[index] == "\n":
                # Single-line Nim strings cannot cross a physical line.
                return
            elif text[index] == '"':
                if raw and index + 1 < length and text[index + 1] == '"':
                    # Raw/generalized strings spell an embedded quote as "".
                    advance(2)
                else:
                    advance()
                    return
            elif not raw and text[index] == "\\":
                advance(min(2, length - index))
            else:
                advance()

    while index < length:
        char = text[index]
        if char in " \t\f\v\r":
            advance()
            continue
        if char == "\n":
            add("newline", "\n", line, column)
            advance()
            continue

        if text.startswith("#[", index):
            depth = 1
            advance(2)
            while index < length and depth:
                if text.startswith("#[", index):
                    depth += 1
                    advance(2)
                elif text.startswith("]#", index):
                    depth -= 1
                    advance(2)
                elif text[index] == "\n":
                    add("newline", "\n", line, column)
                    advance()
                else:
                    advance()
            continue
        if char == "#":
            while index < length and text[index] != "\n":
                advance()
            continue

        if char == '"':
            token_line, token_column = line, column
            start = index
            consume_string(raw=False)
            add("string", text[start:index], token_line, token_column)
            continue

        if char == "`":
            token_line, token_column = line, column
            start = index
            advance()
            while index < length and text[index] not in "`\n":
                advance()
            if index < length and text[index] == "`":
                advance()
            add("quoted_identifier", text[start:index], token_line, token_column)
            continue

        if char == "'" and (
            index == 0 or not (text[index - 1].isalnum() or text[index - 1] == "_")
        ):
            token_line, token_column = line, column
            start = index
            advance()
            while index < length and text[index] != "\n":
                if text[index] == "\\":
                    advance(min(2, length - index))
                elif text[index] == "'":
                    advance()
                    break
                else:
                    advance()
            add("char", text[start:index], token_line, token_column)
            continue

        if char.isalpha() or char == "_" or ord(char) >= 128:
            token_line, token_column = line, column
            start = index
            while index < length and (
                text[index].isalnum() or text[index] == "_" or ord(text[index]) >= 128
            ):
                advance()
            identifier = text[start:index]
            if index < length and text[index] == '"':
                # Generalized strings (including r"...", fmt"...", and their
                # triple-quoted forms) are one expression token. Treating the
                # prefix separately would expose embedded fixture source.
                consume_string(raw=True)
                add("string", text[start:index], token_line, token_column)
            else:
                add("identifier", identifier, token_line, token_column)
            continue

        if char.isdigit():
            token_line, token_column = line, column
            start = index
            while index < length and (
                text[index].isalnum() or text[index] in "._'"
            ):
                advance()
            add("atom", text[start:index], token_line, token_column)
            continue

        token_line, token_column = line, column
        if char in "()[]{}:;,":
            add("punctuation", char, token_line, token_column)
            advance()
            continue
        if char in "+-*/\\<>!?^.|%=~&@$":
            start = index
            while index < length and text[index] in "+-*/\\<>!?^.|%=~&@$":
                advance()
            add("operator", text[start:index], token_line, token_column)
            continue
        add("punctuation", char, token_line, token_column)
        advance()

    return tokens


def nim_outer_depths(tokens: list[NimToken]) -> list[int]:
    """Return delimiter depth, using -1 after structurally invalid input."""

    depths: list[int] = []
    stack: list[str] = []
    structurally_invalid = False
    for token in tokens:
        depths.append(-1 if structurally_invalid else len(stack))
        if structurally_invalid:
            continue
        if token.value in NIM_DELIMITERS:
            stack.append(NIM_DELIMITERS[token.value])
        elif token.value in NIM_CLOSING_DELIMITERS:
            if stack and stack[-1] == token.value:
                stack.pop()
            else:
                structurally_invalid = True
    return depths


def nim_previous_token(tokens: list[NimToken], position: int) -> int | None:
    position -= 1
    while position >= 0 and tokens[position].kind == "newline":
        position -= 1
    return position if position >= 0 else None


def nim_is_word_operator(token: NimToken) -> bool:
    identifier = nim_identifier_value(token)
    return (
        identifier is not None
        and nim_name_key(identifier) in NIM_WORD_OPERATORS
    )


def nim_is_continuation(token: NimToken) -> bool:
    return (
        token.kind == "operator"
        or nim_is_word_operator(token)
        or token.value in {",", "(", "[", "{"}
    )


def nim_statement_start(
    tokens: list[NimToken],
    depths: list[int],
    position: int,
    body_colons: set[int],
) -> bool:
    if depths[position] != 0:
        return False
    previous = nim_previous_token(tokens, position)
    if previous is None:
        return True
    previous_token = tokens[previous]
    if previous_token.line == tokens[position].line:
        return previous_token.value == ";" or previous in body_colons
    return not nim_is_continuation(previous_token)


def nim_statement_end(
    tokens: list[NimToken], depths: list[int], position: int
) -> int:
    """Find the conservative end of an import/from statement."""

    start_depth = depths[position]
    cursor = position + 1
    previous: NimToken | None = None
    while cursor < len(tokens):
        token = tokens[cursor]
        if token.value == ";" and depths[cursor] == start_depth:
            return cursor
        if token.kind == "newline" and depths[cursor] == start_depth:
            if previous is not None and not nim_is_continuation(previous):
                return cursor
        elif token.kind != "newline":
            previous = token
        cursor += 1
    return len(tokens)


def nim_direct_unittest_imports(
    statement: list[NimToken],
) -> tuple[set[str], set[str]]:
    """Resolve direct ``std/unittest`` imports and module aliases.

    Bare ``import unittest`` is deliberately not inferred: a local module can
    shadow the standard library. Re-exported and ``include``-provided bindings
    are likewise outside a lexical inventory. The corpus gate below requires
    every counted test file to have an explicit, resolvable stdlib binding.
    """

    unqualified: set[str] = set()
    qualifiers: set[str] = set()
    cursor = 0
    while cursor < len(statement):
        provider = nim_identifier_value(statement[cursor])
        if (
            provider is not None
            and any(
                nim_name_key(provider) == nim_name_key(name)
                for name in NIM_UNITTEST_PROVIDER_MODULES
            )
            and (cursor == 0 or statement[cursor - 1].value == ",")
        ):
            tail = cursor + 1
            alias: str | None = None
            if (
                tail + 1 < len(statement)
                and nim_identifier_matches(statement[tail], "as")
            ):
                alias = nim_identifier_value(statement[tail + 1])
                tail += 2
            qualifiers.add(alias or provider)
            if alias is None:
                unqualified.update({"test", "suite"})
            cursor = tail
            continue

        if cursor + 2 >= len(statement):
            break
        if not (
            nim_identifier_matches(statement[cursor], "std")
            and statement[cursor + 1].value == "/"
        ):
            cursor += 1
            continue

        module = statement[cursor + 2]
        if nim_identifier_matches(module, "unittest"):
            tail = cursor + 3
            alias: str | None = None
            if (
                tail + 1 < len(statement)
                and nim_identifier_matches(statement[tail], "as")
            ):
                alias = nim_identifier_value(statement[tail + 1])
                tail += 2
            qualifiers.add(alias or "unittest")
            if alias is None:
                excluded: set[str] = set()
                except_position = next(
                    (
                        index
                        for index in range(tail, len(statement))
                        if nim_identifier_matches(statement[index], "except")
                    ),
                    None,
                )
                if except_position is not None:
                    excluded = {
                        name
                        for token in statement[except_position + 1 :]
                        if (name := nim_identifier_value(token)) is not None
                    }
                unqualified.update({"test", "suite"} - {
                    name
                    for name in {"test", "suite"}
                    if any(
                        nim_name_key(name) == nim_name_key(excluded_name)
                        for excluded_name in excluded
                    )
                })
            cursor = tail
            continue

        if module.value == "[":
            bracket_depth = 1
            member = cursor + 3
            while member < len(statement) and bracket_depth:
                token = statement[member]
                if token.value == "[":
                    bracket_depth += 1
                elif token.value == "]":
                    bracket_depth -= 1
                elif bracket_depth == 1 and nim_identifier_matches(token, "unittest"):
                    alias: str | None = None
                    if (
                        member + 2 < len(statement)
                        and nim_identifier_matches(statement[member + 1], "as")
                    ):
                        alias = nim_identifier_value(statement[member + 2])
                    qualifiers.add(alias or "unittest")
                    if alias is None:
                        unqualified.update({"test", "suite"})
                member += 1
            cursor = member
            continue
        cursor += 1

    return unqualified, qualifiers


def nim_unittest_bindings(
    tokens: list[NimToken], depths: list[int]
) -> NimUnittestBindings:
    """Return std/unittest names that are lexically unambiguous in this file."""

    unqualified: set[str] = set()
    qualifiers: set[str] = set()
    body_colons: set[int] = set()

    for position, token in enumerate(tokens):
        if depths[position] != 0 or token.kind == "newline":
            continue
        if token.value == ":":
            previous = nim_previous_token(tokens, position)
            if previous is not None:
                head = previous
                while head > 0 and not nim_statement_start(
                    tokens, depths, head, body_colons
                ):
                    head -= 1
                identifier = nim_identifier_value(tokens[head])
                if (
                    identifier is not None
                    and nim_name_key(identifier) in NIM_INLINE_BLOCK_KEYWORDS
                ):
                    body_colons.add(position)
            continue
        if not nim_statement_start(tokens, depths, position, body_colons):
            continue

        if nim_identifier_matches(token, "import"):
            end = nim_statement_end(tokens, depths, position)
            statement = [
                item
                for item in tokens[position + 1 : end]
                if item.kind != "newline"
            ]
            bare, modules = nim_direct_unittest_imports(statement)
            unqualified.update(bare)
            qualifiers.update(modules)
        elif nim_identifier_matches(token, "from"):
            end = nim_statement_end(tokens, depths, position)
            statement = [
                item
                for item in tokens[position + 1 : end]
                if item.kind != "newline"
            ]
            if (
                len(statement) >= 4
                and nim_identifier_matches(statement[0], "std")
                and statement[1].value == "/"
                and nim_identifier_matches(statement[2], "unittest")
                and nim_identifier_matches(statement[3], "import")
            ):
                for item in statement[4:]:
                    for name in ("test", "suite"):
                        if nim_identifier_matches(item, name):
                            unqualified.add(name)

    # A local declaration with one of these names makes whole-file lexical
    # resolution ambiguous without Nim's semantic scope graph. Fail
    # conservatively rather than count an unrelated macro or receiver.
    shadowed: set[str] = set()
    for position, token in enumerate(tokens):
        identifier = nim_identifier_value(token)
        if (
            identifier is None
            or nim_name_key(identifier) not in NIM_BINDING_KEYWORDS
            or not nim_statement_start(tokens, depths, position, body_colons)
        ):
            continue
        cursor = position + 1
        while cursor < len(tokens) and tokens[cursor].kind == "newline":
            cursor += 1
        if cursor >= len(tokens):
            continue
        bound_name = nim_identifier_value(tokens[cursor])
        if bound_name is not None:
            shadowed.add(bound_name)

    return NimUnittestBindings(
        unqualified=frozenset(
            name
            for name in unqualified
            if not any(nim_name_key(name) == nim_name_key(item) for item in shadowed)
        ),
        qualifiers=frozenset(
            name
            for name in qualifiers
            if not any(nim_name_key(name) == nim_name_key(item) for item in shadowed)
        ),
    )


def nim_declaration_reference(
    tokens: list[NimToken],
    position: int,
    bindings: NimUnittestBindings,
) -> tuple[str, int] | None:
    for name in ("suite", "test"):
        if (
            nim_identifier_matches(tokens[position], name)
            and name in bindings.unqualified
        ):
            return name, position

    if position + 2 >= len(tokens) or tokens[position + 1].value != ".":
        return None
    qualifier = nim_identifier_value(tokens[position])
    if qualifier is None or not any(
        nim_name_key(qualifier) == nim_name_key(item)
        for item in bindings.qualifiers
    ):
        return None
    for name in ("suite", "test"):
        if nim_identifier_matches(tokens[position + 2], name):
            return name, position + 2
    return None


def nim_parse_declaration(
    tokens: list[NimToken],
    reference_start: int,
    keyword_position: int,
    kind: str,
) -> NimDeclaration | None:
    """Parse one complete unittest declaration from a statement start."""

    stack: list[str] = []
    saw_expression = False
    expression_token: NimToken | None = None
    expression_start = keyword_position + 1
    cursor = expression_start
    declaration_colon: int | None = None

    while cursor < len(tokens):
        candidate = tokens[cursor]
        if candidate.kind == "newline":
            if not stack:
                next_position = cursor + 1
                while (
                    next_position < len(tokens)
                    and tokens[next_position].kind == "newline"
                ):
                    next_position += 1
                if next_position >= len(tokens):
                    break
                next_token = tokens[next_position]
                can_continue = (
                    not saw_expression
                    or (
                        expression_token is not None
                        and nim_is_continuation(expression_token)
                    )
                    or next_token.kind == "operator"
                    or nim_is_word_operator(next_token)
                )
                if (
                    next_token.column <= tokens[reference_start].column
                    or not can_continue
                ):
                    break
            cursor += 1
            continue

        if candidate.value in NIM_DELIMITERS:
            stack.append(NIM_DELIMITERS[candidate.value])
            saw_expression = True
        elif candidate.value in NIM_CLOSING_DELIMITERS:
            if not stack or stack[-1] != candidate.value:
                break
            stack.pop()
            saw_expression = True
        elif candidate.value == ":" and not stack:
            if (
                saw_expression
                and expression_token is not None
                and not nim_is_continuation(expression_token)
                and expression_token.value not in {",", ";"}
            ):
                declaration_colon = cursor
            break
        elif candidate.value == ";" and not stack:
            break
        elif (
            not stack
            and candidate.kind == "operator"
            and candidate.value.endswith("=")
            and candidate.value not in {"==", "<=", ">=", "!="}
        ):
            break
        else:
            saw_expression = True
        expression_token = candidate
        cursor += 1

    if declaration_colon is None:
        return None

    body_position = declaration_colon + 1
    while (
        body_position < len(tokens)
        and tokens[body_position].kind == "newline"
    ):
        body_position += 1
    if body_position >= len(tokens) or tokens[body_position].value == ";":
        return None
    body_token = tokens[body_position]
    colon_token = tokens[declaration_colon]
    if (
        body_token.line != colon_token.line
        and body_token.column <= tokens[reference_start].column
    ):
        return None
    return NimDeclaration(
        kind=kind,
        token=tokens[keyword_position],
        expression_start=expression_start,
        colon=declaration_colon,
    )


def nim_declarations(tokens: list[NimToken]) -> list[NimDeclaration]:
    """Return lexically resolvable std/unittest suite/test declarations."""

    depths = nim_outer_depths(tokens)
    bindings = nim_unittest_bindings(tokens, depths)
    declarations: list[NimDeclaration] = []
    body_colons: set[int] = set()

    for position, token in enumerate(tokens):
        if depths[position] != 0:
            continue
        if token.value == ":":
            previous = nim_previous_token(tokens, position)
            if previous is not None:
                head = previous
                while head > 0 and not nim_statement_start(
                    tokens, depths, head, body_colons
                ):
                    head -= 1
                identifier = nim_identifier_value(tokens[head])
                if (
                    identifier is not None
                    and nim_name_key(identifier) in NIM_INLINE_BLOCK_KEYWORDS
                ):
                    body_colons.add(position)
            continue
        reference = nim_declaration_reference(tokens, position, bindings)
        if reference is None or not nim_statement_start(
            tokens, depths, position, body_colons
        ):
            continue
        kind, keyword_position = reference
        declaration = nim_parse_declaration(
            tokens, position, keyword_position, kind
        )
        if declaration is None:
            continue
        declarations.append(declaration)
        body_colons.add(declaration.colon)

    return declarations


def count_nim_cases(text: str) -> dict[str, Any]:
    tokens = nim_tokens(text)
    declarations = nim_declarations(tokens)
    suite_declarations = [
        declaration for declaration in declarations if declaration.kind == "suite"
    ]
    tests = [
        declaration for declaration in declarations if declaration.kind == "test"
    ]
    suites: list[str] = []
    for declaration in suite_declarations:
        expression_position = declaration.expression_start
        while (
            expression_position < len(tokens)
            and tokens[expression_position].kind == "newline"
        ):
            expression_position += 1
        if expression_position >= len(tokens):
            continue
        expression = tokens[expression_position]
        if (
            expression.kind == "string"
            and expression.value.startswith('"')
            and not expression.value.startswith('"""')
            and expression.value.endswith('"')
        ):
            suites.append(expression.value[1:-1])
    return {
        "suiteCount": len(suite_declarations),
        "caseCount": len(tests),
        "suites": suites,
    }


def count_python_cases(path: Path) -> dict[str, Any]:
    text = read_text(path)
    try:
        tree = ast.parse(text, filename=str(path))
    except SyntaxError:
        return {"suiteCount": 0, "caseCount": 0, "suites": []}
    count = 0
    for node in ast.walk(tree):
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)) and node.name.startswith("test_"):
            count += 1
    return {"suiteCount": 1 if count else 0, "caseCount": count, "suites": [path.stem] if count else []}


def compiler_invocations(path: str, text: str) -> list[dict[str, Any]]:
    lines = text.splitlines()
    assignment_blocks: dict[str, tuple[int, int, str]] = {}
    assignment_at_line: dict[int, str] = {}
    assignment_starts: list[tuple[int, int, str]] = []
    for line_idx, line in enumerate(lines):
        assigned = re.match(
            r"^(\s*)(?:let|var)\s+([A-Za-z_][A-Za-z0-9_]*)\s*=", line
        )
        if assigned:
            assignment_starts.append(
                (line_idx, len(assigned.group(1).expandtabs(8)), assigned.group(2))
            )
    for position, (start, indent, name) in enumerate(assignment_starts):
        end = len(lines)
        for candidate in range(start + 1, len(lines)):
            stripped = lines[candidate].strip()
            if not stripped or stripped.startswith("#"):
                continue
            candidate_indent = len(lines[candidate]) - len(lines[candidate].lstrip())
            if candidate_indent <= indent:
                end = candidate
                break
        # A later assignment nested inside this expression is not a boundary;
        # the indentation scan above owns the exact expression span.
        block = "\n".join(lines[start:end])
        assignment_blocks[name] = (start, end, block)
        for owned_line in range(start, end):
            assignment_at_line.setdefault(owned_line, name)

    assignment_names = set(assignment_blocks)
    dependencies: dict[str, set[str]] = {}
    for name, (_, _, block) in assignment_blocks.items():
        dependencies[name] = {
            candidate
            for candidate in assignment_names
            if candidate != name
            and re.search(r"\b" + re.escape(candidate) + r"\b", block)
        }

    executed_vars: set[str] = set()
    for line_idx, line in enumerate(lines):
        executor = EXECUTOR_PATTERN.search(line)
        if executor is None:
            continue
        expression = line[executor.start() :]
        balance = expression.count("(") - expression.count(")")
        cursor = line_idx + 1
        while balance > 0 and cursor < len(lines):
            expression += "\n" + lines[cursor]
            balance += lines[cursor].count("(") - lines[cursor].count(")")
            cursor += 1
        executed_vars.update(
            name
            for name in assignment_names
            if re.search(r"\b" + re.escape(name) + r"\b", expression)
        )

    flows_to_executor: dict[str, bool] = {}

    def reaches_executor(name: str, visiting: set[str] | None = None) -> bool:
        if name in flows_to_executor:
            return flows_to_executor[name]
        if name in executed_vars:
            flows_to_executor[name] = True
            return True
        visiting = set() if visiting is None else visiting
        if name in visiting:
            return False
        visiting.add(name)
        dependants = {
            candidate
            for candidate, refs in dependencies.items()
            if name in refs
        }
        result = any(reaches_executor(candidate, visiting) for candidate in dependants)
        visiting.remove(name)
        flows_to_executor[name] = result
        return result

    matches: list[dict[str, Any]] = []

    for idx, line in enumerate(lines, start=1):
        stripped = line.strip()
        if not stripped or stripped.startswith("#") or stripped.startswith("##"):
            continue
        pattern_names = [name for name, pat in COMPILER_PATTERNS if pat.search(stripped)]
        if not pattern_names:
            continue
        assignment_name = assignment_at_line.get(idx - 1, "")
        assignment_text = (
            assignment_blocks[assignment_name][2] if assignment_name else stripped
        )
        # A shell preflight that merely verifies compilers are installed is not
        # a runtime compilation. Keep the inventory about materialized test
        # artifacts, not PATH capability checks such as
        # `for tool in nim gcc ...; command -v "$tool"`.
        if (
            re.search(r"\bfor\s+\w+\s+in\b", stripped)
            and "command -v" in assignment_text
        ):
            continue
        assigned_var = assignment_name
        nearby_before = "\n".join(lines[max(0, idx - 4) : idx])
        executor_matches = list(EXECUTOR_PATTERN.finditer(nearby_before))
        inside_multiline_executor = False
        if executor_matches:
            executor_context = nearby_before[executor_matches[-1].start() :]
            inside_multiline_executor = (
                executor_context.count("(") > executor_context.count(")")
            )
        direct_exec = bool(
            EXECUTOR_PATTERN.search(stripped)
            or (ARGV_COMPILER_TOKEN.search(stripped) and inside_multiline_executor)
        )
        matches.append(
            {
                "path": path,
                "line": idx,
                "patterns": pattern_names,
                "snippet": stripped[:220],
                "directExecutionLine": direct_exec,
                "assignedCommandVariable": assigned_var,
            }
        )

    for item in matches:
        assigned_var = item.get("assignedCommandVariable", "")
        item["commandVariableExecuted"] = bool(
            assigned_var and reaches_executor(assigned_var)
        )
        item["executedVariables"] = sorted(executed_vars)

    return [
        item
        for item in matches
        if item.get("directExecutionLine") or item.get("commandVariableExecuted")
    ]


def classify(spec: TestSpec, text: str, compile_matches: list[dict[str, Any]]) -> tuple[str, str]:
    source = spec.source
    lower_path = source.lower()

    if (
        any(token in lower_path for token in PLATFORM_PATH_TOKENS)
        or spec.target_os != "soAny"
        or any(p.search(text) for p in PLATFORM_CONTENT_PATTERNS)
    ):
        return "platform/destructive", "platform path, target OS, VM, privileged, or host mutation signal"

    if source.startswith("tests/e2e/") or source.startswith("tests/integration/") or spec.requires_repro_binary:
        return "integration", "e2e/integration path or requires the repro binary"

    if compile_matches:
        return "graph-fixture", "test body compiles or links a helper/fixture artifact"

    if "fixture" in lower_path or "fixtures" in lower_path:
        return "graph-fixture", "fixture path or fixture-oriented test"

    if any(p.search(text) for p in INTEGRATION_CONTENT_PATTERNS):
        return "integration", "subprocess or repro CLI invocation in test body"

    return "pure unit", "in-process source-level test with no detected subprocess or fixture compile"


def local_dependency_shape(spec: TestSpec, text: str) -> list[str]:
    """Return the non-stdlib dependency roots relevant to consolidation.

    Consolidating tests with the same repository owner is only safe when their
    project dependencies also have the same shape. Standard-library imports do
    not affect that boundary. Relative imports within a library remain covered
    by the owner; cross-library and recipe imports are recorded explicitly.
    """
    if spec.language != "nim":
        return []
    import_text = "\n".join(
        match.group(1)
        for match in re.finditer(
            r"(?m)^\s*(?:import|from|include)\s+([^\n]+)", text
        )
    )
    roots = {
        match.group(1).split("/", 1)[0]
        for match in re.finditer(
            r"(?<![A-Za-z0-9_])((?:(?:repro|ct_test)_[A-Za-z0-9_]+|io_mon|nim_stackable_hooks)(?:/[A-Za-z0-9_./-]+)?)",
            import_text,
        )
    }
    for match in re.finditer(r"(?:\.\./)+libs/([^/\"']+)", import_text):
        roots.add(match.group(1))
    if re.search(r"(?:\.\./)+recipes/packages/source/", import_text):
        roots.add("recipes/packages/source")
    return sorted(roots)


def parse_graph_owned_artifacts(root: Path) -> list[dict[str, str]]:
    text = read_text(root / "repro.nim")
    artifacts: list[dict[str, str]] = []
    block_re = re.compile(r"nim\.c\(\s*(.*?)\)\)", re.S)
    for block in block_re.finditer(text):
        body = block.group(1)
        action = re.search(r'actionId\s*=\s*"([^"]+)"', body)
        if not action:
            continue
        action_id = action.group(1)
        if not (
            action_id.startswith("reprobuild.test_helpers.")
            or action_id.startswith("reprobuild.test_fixtures.")
        ):
            continue
        source = re.search(r'source\s*=\s*"([^"]+)"', body)
        binary = re.search(r'binary\s*=\s*"([^"]+)"', body)
        artifacts.append(
            {
                "actionId": action_id,
                "source": source.group(1) if source else "dynamic",
                "output": binary.group(1) if binary else "dynamic",
                "kind": "test-helper" if ".test_helpers." in action_id else "test-fixture",
            }
        )
    artifacts.sort(key=lambda item: item["actionId"])
    return artifacts


def summarize_runner(summary_path: Path) -> dict[str, Any] | None:
    if not summary_path.exists():
        return None
    try:
        doc = json.loads(summary_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None
    tests = doc.get("tests", [])
    slowest = sorted(tests, key=lambda item: item.get("duration_ms", 0), reverse=True)[:20]
    protocol_aware = [t for t in tests if t.get("protocol_aware")]
    failed = [t for t in tests if t.get("status") not in ("PASS", "SKIP")]
    return {
        "path": str(summary_path),
        "summary": doc.get("summary", {}),
        "protocolAwareCases": len(protocol_aware),
        "wholeBinaryCases": len(tests) - len(protocol_aware),
        "slowestTests": slowest,
        "failedTests": failed,
        "warmReviewCandidates": [t for t in tests if t.get("duration_ms", 0) > 20_000],
    }


def du_kib(path: Path) -> int | None:
    if not path.exists():
        return None
    try:
        output = subprocess.check_output(["du", "-sk", str(path)], text=True)
        return int(output.split()[0])
    except (OSError, subprocess.CalledProcessError, ValueError, IndexError):
        return None


def count_executable_files(path: Path) -> int | None:
    if not path.exists():
        return None
    count = 0
    for child in path.iterdir():
        if child.is_file() and os.access(child, os.X_OK):
            count += 1
    return count


def footprint(root: Path) -> dict[str, Any]:
    paths = [
        "build/bin",
        "build/test-bin",
        "build/nimcache",
        "build/lib",
        ".repro",
        "test-logs/results",
    ]
    entries = []
    for item in paths:
        p = root / item
        entries.append({"path": item, "kib": du_kib(p), "executableFiles": count_executable_files(p)})
    total = sum(e["kib"] for e in entries if isinstance(e["kib"], int))
    return {"entries": entries, "totalKiB": total if total else None}


def clean_for_cold_run(root: Path) -> None:
    for item in [
        "build",
        ".repro",
        "test-logs/results",
        "test-logs/parallel-run.json",
        "test-logs/test.log",
    ]:
        target = root / item
        if target.is_dir():
            shutil.rmtree(target)
        elif target.exists():
            target.unlink()


def run_logged_command(
    root: Path,
    command: list[str],
    log_path: Path,
    timeout_seconds: int,
    env: dict[str, str] | None = None,
) -> tuple[int, bool]:
    with log_path.open("w", encoding="utf-8") as log:
        proc = subprocess.Popen(
            command,
            cwd=root,
            stdout=log,
            stderr=subprocess.STDOUT,
            start_new_session=True,
            env=env,
        )
        timed_out = False
        try:
            return proc.wait(timeout=timeout_seconds if timeout_seconds > 0 else None), timed_out
        except subprocess.TimeoutExpired:
            timed_out = True
            log.write(f"\n[reprobuild_suite_inventory] timeout after {timeout_seconds}s; terminating process group\n")
            log.flush()
            try:
                os.killpg(proc.pid, signal.SIGTERM)
            except OSError:
                proc.terminate()
            try:
                proc.wait(timeout=30)
            except subprocess.TimeoutExpired:
                log.write("[reprobuild_suite_inventory] SIGTERM grace expired; killing process group\n")
                log.flush()
                try:
                    os.killpg(proc.pid, signal.SIGKILL)
                except OSError:
                    proc.kill()
                proc.wait()
            return 124, timed_out


LOG_RESULT_RE = re.compile(r"^\[(PASS|FAIL|TIMEOUT)\]\s+(.+?)\s+\(([^)]*)\)\s+\((\d+)ms\)")


def summarize_log_results(root: Path, run: dict[str, Any]) -> dict[str, Any] | None:
    log_value = run.get("log")
    if not log_value:
        return None
    log_path = root / log_value
    if not log_path.exists():
        return None

    results = []
    for raw in log_path.read_text(encoding="utf-8", errors="replace").replace("\r", "\n").splitlines():
        match = LOG_RESULT_RE.match(raw)
        if not match:
            continue
        status, name, mode, duration_ms = match.groups()
        results.append(
            {
                "status": status.lower(),
                "name": name,
                "mode": mode,
                "durationMs": int(duration_ms),
            }
        )

    if not results:
        return None
    counts: dict[str, int] = {}
    for result in results:
        counts[result["status"]] = counts.get(result["status"], 0) + 1
    return {
        "total": len(results),
        "passed": counts.get("pass", 0),
        "failed": counts.get("fail", 0),
        "timedOut": counts.get("timeout", 0),
        "lastResult": results[-1],
        "slowestResults": sorted(results, key=lambda item: item["durationMs"], reverse=True)[:10],
    }


def enrich_timing_runs(root: Path, timing: dict[str, Any]) -> dict[str, Any]:
    for run in timing.get("runs", []):
        summary_value = run.get("summaryJson")
        if summary_value:
            summary_path = root / summary_value
            refreshed = summarize_runner(summary_path)
            if refreshed:
                run["runnerSummary"] = refreshed
        if run.get("runnerSummary") is None:
            partial = summarize_log_results(root, run)
            if partial:
                run["partialLogSummary"] = partial
        exit_code = run.get("exitCode")
        if isinstance(exit_code, int) and exit_code < 0:
            run["aborted"] = True
            run["abortedBySignal"] = -exit_code
            run.setdefault(
                "abortReason",
                "redirected from the single-thread fallback runner before suite completion",
            )
    return timing


def completed_clean_runs(timing: dict[str, Any]) -> dict[str, dict[str, Any]] | None:
    """Return the newest coherent cold-plus-two-warm evidence set."""
    current_fingerprint = timing.get(
        "currentSourceFingerprint", timing.get("sourceFingerprint")
    )
    if current_fingerprint != timing.get("sourceFingerprint"):
        return None
    expected = ["clean-cold", "clean-warm-1", "clean-warm-2"]
    by_attempt: dict[int, dict[str, dict[str, Any]]] = {}
    for run in timing.get("runs", []):
        if run.get("attemptKind") != "clean" or run.get("cleanFirst") is not True:
            continue
        attempt = int(run.get("attemptIndex", 0))
        label = str(run.get("label", ""))
        selected = by_attempt.setdefault(attempt, {})
        if label in selected:
            selected[label] = {}
        else:
            selected[label] = run
    for attempt in sorted(by_attempt, reverse=True):
        selected = by_attempt[attempt]
        if not all(label in selected and selected[label] for label in expected):
            continue
        runs = [selected[label] for label in expected]
        fingerprints = {run.get("sourceFingerprint") for run in runs}
        summaries = [
            (run.get("runnerSummary") or {}).get("summary", {}) for run in runs
        ]
        summaries_are_complete = all(
            isinstance(summary.get("total"), int)
            and summary["total"] > 0
            and summary.get("passed") == summary["total"]
            and summary.get("failed") == 0
            and summary.get("skipped") == 0
            for summary in summaries
        )
        elapsed_is_measured = all(
            isinstance(run.get("elapsedMs"), (int, float))
            and not isinstance(run.get("elapsedMs"), bool)
            and run["elapsedMs"] > 0
            for run in runs
        )
        summaries_have_provenance = all(
            isinstance(run.get("summaryJson"), str)
            and bool(run["summaryJson"])
            and isinstance(run.get("summarySha256"), str)
            and bool(re.fullmatch(r"[0-9a-f]{64}", run["summarySha256"]))
            for run in runs
        )
        if (
            all(run.get("exitCode") == 0 and not run.get("timedOut") for run in runs)
            and summaries_are_complete
            and elapsed_is_measured
            and summaries_have_provenance
            and len(fingerprints) == 1
            and None not in fingerprints
            and fingerprints == {timing.get("sourceFingerprint")}
        ):
            return selected
    return None


def completed_clean_attempt(timing: dict[str, Any]) -> int | None:
    """Return the newest attempt containing one cold and two clean warm passes."""
    selected = completed_clean_runs(timing)
    if selected is None:
        return None
    return int(selected["clean-cold"]["attemptIndex"])


def measured_timing(timing: dict[str, Any]) -> dict[str, Any]:
    selected = completed_clean_runs(timing)
    if selected is None:
        return {"coldRunMs": None, "warmRunMs": [], "speedupFactor": None}
    cold = selected["clean-cold"]["elapsedMs"]
    warm = [
        selected["clean-warm-1"]["elapsedMs"],
        selected["clean-warm-2"]["elapsedMs"],
    ]
    return {
        "coldRunMs": cold,
        "warmRunMs": warm,
        "speedupFactor": round(cold / warm[-1], 3),
    }


def slow_review_provenance_matches(root: Path, timing: dict[str, Any]) -> bool:
    """Return whether reviews name the exact completed final-warm evidence."""
    selected = completed_clean_runs(timing)
    if selected is None:
        return False
    final_warm = selected["clean-warm-2"]
    document = load_slow_review_document(root)
    provenance = document["provenance"]
    expected = {
        "measurementStatus": "authoritative",
        "sourceFingerprint": timing.get("sourceFingerprint"),
        "attemptIndex": final_warm.get("attemptIndex"),
        "summaryLabel": "clean-warm-2",
        "summaryJson": final_warm.get("summaryJson"),
        "summarySha256": final_warm.get("summarySha256"),
    }
    return all(provenance.get(key) == value for key, value in expected.items())


def authoritative_slow_reviews(
    root: Path, timing: dict[str, Any]
) -> dict[str, dict[str, str]]:
    """Accept reviews only when they name the exact final-warm evidence."""
    if not slow_review_provenance_matches(root, timing):
        return {}
    return load_slow_review_document(root)["reviews"]


def annotate_timing(timing: dict[str, Any]) -> dict[str, Any]:
    runs = timing.get("runs", [])
    notes: list[str] = []
    if not runs:
        notes.append("No suite run was requested for this inventory.")
    else:
        completed_attempt = completed_clean_attempt(timing)
        if completed_attempt is None:
            notes.append(
                "The clean cold end-to-end timing remains incomplete because no single clean "
                "attempt contains one successful cold run plus two successful repeated warm runs "
                "from the same source fingerprint with complete all-pass runner summaries."
            )
        else:
            timing["completedAttemptIndex"] = completed_attempt
        if any(str(run.get("attemptKind", "")).startswith("continuation") for run in runs):
            notes.append(
                "Continuation attempts reuse existing build artifacts and are not equivalent to a clean cold baseline."
            )
        if any(run.get("aborted") for run in runs):
            notes.append("At least one timing attempt was aborted before suite completion.")
    timing["notes"] = notes
    timing["complete"] = completed_clean_attempt(timing) is not None
    return timing


def load_previous_timing(root: Path, json_path: Path, append: bool) -> dict[str, Any] | None:
    if not append or not json_path.exists():
        return None
    try:
        doc = json.loads(json_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None
    timing = doc.get("timing")
    if isinstance(timing, dict) and isinstance(timing.get("runs"), list):
        if timing.get("sourceFingerprint") != source_fingerprint(root):
            return None
        return enrich_timing_runs(root, timing)
    return None


def run_suite(root: Path, warm_runs: int, clean_first: bool, timeout_seconds: int,
              previous_timing: dict[str, Any] | None = None) -> dict[str, Any]:
    if clean_first:
        clean_for_cold_run(root)

    results_dir = root / GENERATED_RESULTS_DIR
    results_dir.mkdir(parents=True, exist_ok=True)
    run_source_fingerprint = source_fingerprint(root)
    runs = list((previous_timing or {}).get("runs", []))
    attempt_index = max([run.get("attemptIndex", 0) for run in runs] + [0]) + 1
    if clean_first:
        attempt_kind = "clean"
    elif any(run.get("label") == "clean-cold" for run in runs):
        attempt_kind = "continuation-after-clean-build"
    else:
        attempt_kind = "continuation"
    total_runs = 1 + warm_runs
    for index in range(total_runs):
        if clean_first:
          label = "clean-cold" if index == 0 else f"clean-warm-{index}"
        else:
          label = attempt_kind if index == 0 else f"{attempt_kind}-warm-{index}"
        log_label = f"attempt-{attempt_index}-{label}"
        log_path = results_dir / f"{label}.log"
        summary_copy = results_dir / f"{label}-parallel-run.json"
        if any(run.get("log") == rel(log_path, root) for run in runs):
            log_path = results_dir / f"{log_label}.log"
            summary_copy = results_dir / f"{log_label}-parallel-run.json"
        if summary_copy.exists():
            summary_copy.unlink()
        started = time.monotonic()
        run_env = os.environ.copy()
        # Authoritative M0 measurements may not accept the benchmark-policy
        # module's default opt-in skip. Force its live path for every cold and
        # warm pass and record the exact child environment below.
        run_env["REPROBUILD_BENCH_LIVE"] = "1"
        if index > 0:
            run_env["REPROBUILD_TEST_WARM_REUSE"] = "1"
        else:
            run_env.pop("REPROBUILD_TEST_WARM_REUSE", None)
        return_code, timed_out = run_logged_command(
            root,
            ["bash", "scripts/run_tests.sh"],
            log_path,
            timeout_seconds,
            env=run_env,
        )
        elapsed_ms = int((time.monotonic() - started) * 1000)
        source_summary = root / "test-logs/parallel-run.json"
        copied = False
        if source_summary.exists():
            shutil.copy2(source_summary, summary_copy)
            copied = True
        summary_sha256 = None
        if copied:
            summary_sha256 = hashlib.sha256(summary_copy.read_bytes()).hexdigest()
        run_runtime = runtime_metadata(run_env)
        runs.append(
            {
                "label": label,
                "command": "bash scripts/run_tests.sh",
                "exitCode": return_code,
                "timedOut": timed_out,
                "elapsedMs": elapsed_ms,
                "log": rel(log_path, root),
                "summaryJson": rel(summary_copy, root) if copied else None,
                "summarySha256": summary_sha256,
                "runnerSummary": summarize_runner(summary_copy) if copied else None,
                "attemptIndex": attempt_index,
                "attemptKind": attempt_kind,
                "cleanFirst": clean_first,
                "timeoutSeconds": timeout_seconds if timeout_seconds > 0 else None,
                "environment": run_runtime["environment"],
                "sourceCheckouts": run_runtime["sourceCheckouts"],
                "warmArtifactReuse": index > 0,
                "sourceFingerprint": run_source_fingerprint,
            }
        )
        enrich_timing_runs(root, {"runs": runs})
        if return_code != 0 or timed_out:
            break
    return {
        "runs": runs,
        "sourceFingerprint": run_source_fingerprint,
        "warmRunsRequested": warm_runs,
        "cleanFirst": clean_first,
        "timeoutSeconds": timeout_seconds if timeout_seconds > 0 else None,
    }


def build_inventory(root: Path, run_data: dict[str, Any] | None) -> dict[str, Any]:
    nim_specs, py_specs = parse_repro_tests(root)
    all_specs = nim_specs + py_specs
    tests = []
    helper_compiles = []
    class_counts: dict[str, int] = {}
    source_case_count = 0

    for spec in all_specs:
        source_path = root / spec.source
        text = read_text(source_path)
        case_info = count_python_cases(source_path) if spec.language == "python" else count_nim_cases(text)
        source_case_count += case_info["caseCount"]
        compiles = compiler_invocations(spec.source, text)
        category, reason = classify(spec, text, compiles)
        class_counts[category] = class_counts.get(category, 0) + 1
        if compiles:
            helper_compiles.append(
                {
                    "source": spec.source,
                    "class": category,
                    "matches": compiles,
                }
            )
        tests.append(
            {
                "source": spec.source,
                "binary": spec.binary,
                "language": spec.language,
                "owner": spec.owner,
                "defines": spec.defines,
                "requiresReproBinary": spec.requires_repro_binary,
                "targetOs": spec.target_os,
                "sourceCaseCount": case_info["caseCount"],
                "sourceSuiteCount": case_info["suiteCount"],
                "class": category,
                "classificationReason": reason,
                "helperCompilationInTestBody": bool(compiles),
                "localDependencyShape": local_dependency_shape(spec, text),
            }
        )

    consolidation_candidates = []
    by_boundary: dict[tuple[Any, ...], list[dict[str, Any]]] = {}
    for item in tests:
        if (
            item["language"] == "nim"
            and item["class"] == "pure unit"
            and not item["helperCompilationInTestBody"]
        ):
            dependencies = tuple(item["localDependencyShape"])
            # tests/unit is a catch-all directory rather than a meaningful
            # ownership boundary. Stdlib-only files there remain separate
            # unless a future review assigns them an explicit owner.
            unit_fallback = item["source"] if item["owner"] == "tests/unit" and not dependencies else ""
            boundary = (
                item["owner"],
                dependencies,
                tuple(item["defines"]),
                item["targetOs"],
                unit_fallback,
            )
            by_boundary.setdefault(boundary, []).append(item)
    for boundary, items in sorted(by_boundary.items()):
        if len(items) < 2:
            continue
        owner, dependencies, defines, target_os, _ = boundary
        consolidation_candidates.append(
            {
                "owner": owner,
                "dependencyShape": list(dependencies),
                "defines": list(defines),
                "targetOs": target_os,
                "count": len(items),
                "sourceCaseCount": sum(item["sourceCaseCount"] for item in items),
                "sources": [item["source"] for item in items],
            }
        )

    runner_summaries = []
    if run_data:
        for run in run_data.get("runs", []):
            if run.get("runnerSummary"):
                runner_summaries.append(run["runnerSummary"])

    current_source_fingerprint = source_fingerprint(root)
    timing = run_data or {"runs": []}
    timing["currentSourceFingerprint"] = current_source_fingerprint
    timing = annotate_timing(timing)
    completed_runs = completed_clean_runs(timing)
    authoritative_runner = (
        completed_runs["clean-warm-2"].get("runnerSummary")
        if completed_runs
        else None
    )
    current_runner = runner_summaries[-1] if runner_summaries else None

    tests_by_stem = {
        Path(item["binary"]).stem: item
        for item in tests
        if item.get("binary")
    }
    slow_review_document = load_slow_review_document(root)
    slow_reviews = slow_review_document["reviews"]
    provenance_matches = slow_review_provenance_matches(root, timing)
    accepted_reviews = authoritative_slow_reviews(root, timing)
    for summary in runner_summaries:
        for candidate in summary.get("warmReviewCandidates", []):
            stem = candidate.get("binary_stem", "")
            inventory_item = tests_by_stem.get(stem, {})
            candidate["source"] = inventory_item.get("source", "")
            candidate["testClass"] = inventory_item.get("class", "unknown")
            candidate["testClassificationReason"] = inventory_item.get(
                "classificationReason", "no matching source inventory"
            )
            candidate["helperCompilationInTestBody"] = inventory_item.get(
                "helperCompilationInTestBody", False
            )
            review_name = candidate.get("qualified_name", "")
            review = accepted_reviews.get(review_name) or accepted_reviews.get(stem)
            diagnostic_review = slow_reviews.get(review_name) or slow_reviews.get(stem)
            if summary is authoritative_runner and review:
                candidate["warmReview"] = {"status": "reviewed", **review}
            elif diagnostic_review:
                candidate["warmReview"] = {
                    "status": "diagnostic-only",
                    **diagnostic_review,
                }
            else:
                candidate["warmReview"] = {
                    "status": "missing",
                    "classification": "",
                    "justification": "",
                    "followUp": "",
                }

    measured_runner = authoritative_runner or current_runner
    measured_protocol_cases = (
        measured_runner["protocolAwareCases"] if measured_runner else None
    )
    latest_warm_candidates = (
        authoritative_runner.get("warmReviewCandidates", [])
        if authoritative_runner
        else current_runner.get("warmReviewCandidates", []) if current_runner else []
    )
    # An empty candidate set is meaningful only after one coherent clean-cold
    # plus two-warm attempt has passed.  Without authoritative timing, treating
    # ``all([])`` as completion would incorrectly close the 20-second review
    # gate merely because no warm summary exists.
    slow_review_complete = (
        bool(timing.get("complete"))
        and provenance_matches
        and all(
            item.get("warmReview", {}).get("status") == "reviewed"
            for item in latest_warm_candidates
        )
    )

    performance_assessment = {
        "status": (
            "measured-baseline-complete"
            if timing.get("complete") and slow_review_complete
            else "structural-inference-only"
        ),
        "measured": measured_timing(timing),
        "observedStructuralFacts": {
            "testEntries": len(all_specs),
            "nimTestBinaries": len(nim_specs),
            "sourceCases": source_case_count,
            "pureUnitTests": class_counts.get("pure unit", 0),
            "pureUnitConsolidationGroups": len(consolidation_candidates),
            "runtimeCompilerCallTests": len(helper_compiles),
            "graphOwnedHelperArtifacts": len(parse_graph_owned_artifacts(root)),
        },
        "inferences": [
            (
                "Parallel execution can reduce the serial execution component, "
                "but the exclusive lane and longest dependency chain bound the "
                "achievable wall-time reduction."
            ),
            (
                "Consolidating compatible pure-unit groups should reduce repeated "
                "Nim compilation, link, and process-start overhead while preserving "
                "logical case identity."
            ),
            (
                "Moving test-body helper compilation into graph-owned artifacts "
                "should enable cache reuse and avoid repeated fixture compilation."
            ),
        ],
        "limitations": [
            (
                "No uncontaminated cold or repeated-warm suite timing is available "
                "for this source fingerprint."
            ),
            (
                "Contended or rejected diagnostic attempts are intentionally absent "
                "from measured timing and speedup fields."
            ),
            (
                "No numeric performance improvement may be claimed until the "
                "deferred clean-cold plus two-warm attempt completes."
            ),
        ],
        "deferredMeasurementCommand": (
            "REPROBUILD_BENCH_LIVE=1 REPROBUILD_TEST_THREADS=4 "
            "direnv exec . python3 "
            "scripts/reprobuild_suite_inventory.py --run-suite --clean-first "
            "--warm-runs 2 --suite-timeout-seconds 7200"
        ),
    }

    return {
        "metadata": {
            "generatedAt": now_utc(),
            "repoRoot": str(root),
            "head": git_value(root, "rev-parse", "HEAD"),
            "headShort": git_value(root, "rev-parse", "--short", "HEAD"),
            "branch": git_value(root, "branch", "--show-current"),
            "sourceFingerprint": current_source_fingerprint,
            "status": git_value(root, "status", "--short"),
            "runtime": runtime_metadata(),
        },
        "static": {
            "nimTestBinaryCount": len(nim_specs),
            "pythonTestFileCount": len(py_specs),
            "testEntryCount": len(all_specs),
            "sourceCaseCount": source_case_count,
            "measuredProtocolAwareCaseCount": measured_protocol_cases,
            "classificationCounts": class_counts,
            "graphOwnedTestArtifacts": parse_graph_owned_artifacts(root),
        },
        "tests": tests,
        "helperCompilationInTestBody": helper_compiles,
        "pureUnitConsolidationCandidates": consolidation_candidates,
        "timing": timing,
        "runnerSummaries": runner_summaries,
        "performanceAssessment": performance_assessment,
        "slowTestReview": {
            "path": DEFAULT_SLOW_REVIEWS.as_posix(),
            "candidateCount": len(latest_warm_candidates),
            "reviewedCount": sum(
                item.get("warmReview", {}).get("status") == "reviewed"
                for item in latest_warm_candidates
            ),
            "retainedDiagnosticReviewCount": len(slow_reviews),
            "complete": slow_review_complete,
        },
        "footprint": footprint(root),
    }


def md_table(headers: list[str], rows: list[list[str]]) -> list[str]:
    out = ["| " + " | ".join(headers) + " |", "| " + " | ".join(["---"] * len(headers)) + " |"]
    for row in rows:
        out.append("| " + " | ".join(cell.replace("\n", " ") for cell in row) + " |")
    return out


def fmt_ms(value: int | float | None) -> str:
    if value is None:
        return "not measured"
    seconds = float(value) / 1000.0
    if seconds >= 60:
        return f"{seconds / 60.0:.2f} min ({int(value)} ms)"
    return f"{seconds:.2f} s ({int(value)} ms)"


def failure_excerpt(item: dict[str, Any], max_len: int = 220) -> str:
    output = item.get("stdout") or item.get("stderr") or ""
    if not output:
        return ""
    lines = [line.strip() for line in output.splitlines() if line.strip()]
    interesting = [
        line
        for line in lines
        if "Check failed:" in line
        or "Unhandled exception:" in line
        or "Error:" in line
        or "FAILED" in line
        or "Additional info:" in line
    ]
    selected = interesting[-3:] if interesting else lines[-3:]
    excerpt = " / ".join(selected)
    if len(excerpt) > max_len:
        excerpt = excerpt[: max_len - 3] + "..."
    return excerpt.replace("|", "\\|")


def render_report(data: dict[str, Any], json_path: str) -> str:
    static = data["static"]
    metadata = data["metadata"]
    lines: list[str] = []
    lines.append("# Reprobuild Suite M0 Baseline")
    lines.append("")
    lines.append("This report is generated by `scripts/reprobuild_suite_inventory.py`.")
    lines.append("")
    lines.append("## Regeneration")
    lines.append("")
    lines.append("Static inventory:")
    lines.append("")
    lines.append("```sh")
    lines.append("direnv exec . python3 scripts/reprobuild_suite_inventory.py")
    lines.append("```")
    lines.append("")
    lines.append("Timed cold plus repeated warm baseline after cleaning repo-local build outputs:")
    lines.append("")
    lines.append("```sh")
    lines.append("REPROBUILD_BENCH_LIVE=1 REPROBUILD_TEST_THREADS=4 direnv exec . python3 scripts/reprobuild_suite_inventory.py --run-suite --clean-first --warm-runs 2 --suite-timeout-seconds 7200")
    lines.append("```")
    lines.append("")
    lines.append("Bounded timing attempt, useful when the full suite is too slow for an interactive audit:")
    lines.append("")
    lines.append("```sh")
    lines.append("REPROBUILD_BENCH_LIVE=1 REPROBUILD_TEST_THREADS=4 direnv exec . python3 scripts/reprobuild_suite_inventory.py --run-suite --clean-first --warm-runs 0 --suite-timeout-seconds 1800")
    lines.append("```")
    lines.append("")
    lines.append("## Source")
    lines.append("")
    lines.extend(
        md_table(
            ["Field", "Value"],
            [
                ["Generated at", metadata["generatedAt"]],
                ["HEAD", metadata["head"]],
                ["HEAD short", metadata["headShort"]],
                ["Branch", metadata["branch"] or "(detached)"],
                ["Source fingerprint", metadata["sourceFingerprint"]],
                ["Runtime argv", " ".join(metadata.get("runtime", {}).get("argv", []))],
                ["Runtime env", json.dumps(metadata.get("runtime", {}).get("environment", {}), sort_keys=True)],
                ["External source checkouts", json.dumps(metadata.get("runtime", {}).get("sourceCheckouts", {}), sort_keys=True)],
                ["Host", json.dumps(metadata.get("runtime", {}).get("host", {}), sort_keys=True)],
                ["Tool versions", json.dumps(metadata.get("runtime", {}).get("tools", {}), sort_keys=True)],
                ["Inventory JSON", json_path],
            ],
        )
    )
    lines.append("")
    lines.append("## Counts")
    lines.append("")
    protocol_count = static["measuredProtocolAwareCaseCount"]
    protocol_text = str(protocol_count) if protocol_count is not None else "not measured (requires runner summary)"
    graph_artifacts = static["graphOwnedTestArtifacts"]
    lines.extend(
        md_table(
            ["Metric", "Value"],
            [
                ["Test entries", str(static["testEntryCount"])],
                ["Nim test binaries", str(static["nimTestBinaryCount"])],
                ["Python test files", str(static["pythonTestFileCount"])],
                ["Source-level cases", str(static["sourceCaseCount"])],
                ["Measured protocol-aware cases", protocol_text],
                ["Graph-owned helper/fixture artifacts", str(len(graph_artifacts))],
                ["Tests with direct helper/fixture compiler calls", str(len(data["helperCompilationInTestBody"]))],
                ["Pure-unit consolidation groups", str(len(data["pureUnitConsolidationCandidates"]))],
            ],
        )
    )
    lines.append("")
    lines.append("## Evidence Status")
    lines.append("")
    assessment = data["performanceAssessment"]
    if assessment["status"] == "measured-baseline-complete":
        lines.append(
            "The measured cold-plus-two-warm baseline is complete for this exact "
            "source fingerprint."
        )
    else:
        lines.append(
            "This artifact is authoritative for structural inventory and correctness "
            "facts only. It contains no authoritative cold-run, repeated-warm, or "
            "numeric speedup measurement for this source fingerprint."
        )
        lines.append("")
        lines.append(
            "Earlier contended or rejected timing attempts are diagnostic only and "
            "are intentionally not copied into measured fields. The slow-review file "
            f"retains {data['slowTestReview']['retainedDiagnosticReviewCount']} "
            "source-specific reviews as planning input; they do not satisfy the "
            "current repeated-warm gate."
        )
    lines.append("")
    lines.append("## Theoretical Performance Assessment")
    lines.append("")
    facts = assessment["observedStructuralFacts"]
    lines.append(
        f"The current graph contains {facts['nimTestBinaries']} Nim test binaries, "
        f"{facts['pureUnitTests']} statically classified pure-unit entries in "
        f"{facts['pureUnitConsolidationGroups']} compatible consolidation groups, "
        f"and {facts['runtimeCompilerCallTests']} tests with detected runtime compiler "
        "calls. These are measured structural counts, not timing results."
    )
    lines.append("")
    for inference in assessment["inferences"]:
        lines.append(f"- {inference}")
    lines.append("")
    lines.append(
        "The direction of these effects is supported by the graph shape and scheduling "
        "contracts, but their magnitude is unknown. The exclusive lane and longest "
        "dependency chain impose a serial lower bound, and shared-host contention can "
        "distort both cold and warm cache behavior. No numeric speedup is claimed."
    )
    lines.append("")
    lines.append("## Timing")
    lines.append("")
    runs = data["timing"].get("runs", [])
    if not runs:
        lines.append("No cold or warm suite timing has been recorded in this generated report.")
    else:
        timing_rows = []
        for run in runs:
            summary = (run.get("runnerSummary") or {}).get("summary", {})
            partial = run.get("partialLogSummary") or {}
            partial_text = (
                f"{partial.get('total')} ({partial.get('passed')} pass/{partial.get('failed')} fail/"
                f"{partial.get('timedOut')} timeout)"
                if partial
                else ""
            )
            timing_rows.append(
                [
                    str(run.get("attemptIndex", "")),
                    run.get("attemptKind", ""),
                    run["label"],
                    "yes" if run.get("warmArtifactReuse") else "no",
                    str(run["exitCode"]),
                    "yes" if run.get("timedOut") else "no",
                    f"yes (SIG{run.get('abortedBySignal')})" if run.get("aborted") else "no",
                    str(run.get("timeoutSeconds", "")),
                    fmt_ms(run["elapsedMs"]),
                    fmt_ms(summary.get("wall_time_ms")),
                    str(summary.get("total", "n/a")),
                    str(summary.get("passed", "n/a")),
                    str(summary.get("failed", "n/a")),
                    partial_text,
                    run.get("summaryJson") or "missing",
                    run.get("log", ""),
                ]
            )
        lines.extend(
            md_table(
                [
                    "Attempt",
                    "Kind",
                    "Run",
                    "Warm artifact reuse",
                    "Exit",
                    "Timed out",
                    "Aborted",
                    "Timeout s",
                    "Outer time",
                    "Runner wall",
                    "Total",
                    "Passed",
                    "Failed",
                    "Partial log",
                    "Summary",
                    "Log",
                ],
                timing_rows,
            )
        )
    lines.append("")
    lines.append("## Slowest Tests")
    lines.append("")
    latest_runner = data["runnerSummaries"][-1] if data["runnerSummaries"] else None
    if not latest_runner:
        lines.append("No runner summary is available, so slowest-test and warm-run >20s review data is not measured.")
    else:
        rows = []
        for item in latest_runner["slowestTests"][:15]:
            rows.append(
                [
                    item.get("qualified_name", ""),
                    item.get("binary_stem", ""),
                    fmt_ms(item.get("duration_ms")),
                    str(item.get("protocol_aware", "")),
                    item.get("status", ""),
                ]
            )
        lines.extend(md_table(["Test", "Binary", "Duration", "Protocol-aware", "Status"], rows))
        lines.append("")
        candidates = latest_runner.get("warmReviewCandidates", [])
        if candidates:
            lines.append(f"{len(candidates)} tests exceeded the 20-second warm-run review threshold in the latest summary.")
            lines.append("")
            review_rows = []
            for item in sorted(
                candidates,
                key=lambda candidate: candidate.get("duration_ms", 0),
                reverse=True,
            ):
                review = item.get("warmReview", {})
                review_rows.append(
                    [
                        item.get("qualified_name", ""),
                        fmt_ms(item.get("duration_ms")),
                        item.get("source", ""),
                        item.get("testClass", ""),
                        review.get("classification") or "MISSING REVIEW",
                        review.get("justification") or "MISSING REVIEW",
                        review.get("followUp") or "MISSING REVIEW",
                    ]
                )
            lines.extend(
                md_table(
                    [
                        "Test",
                        "Duration",
                        "Source",
                        "Test class",
                        "Warm review",
                        "Justification",
                        "Follow-up",
                    ],
                    review_rows,
                )
            )
            lines.append("")
            reviewed = data["slowTestReview"]["reviewedCount"]
            lines.append(
                f"Warm review coverage: {reviewed}/{len(candidates)}; source: "
                f"`{data['slowTestReview']['path']}`."
            )
        else:
            lines.append("No tests exceeded the 20-second warm-run review threshold in the latest summary.")
    lines.append("")
    lines.append("## Failed Tests")
    lines.append("")
    if not latest_runner:
        lines.append("No runner summary is available, so failed-test details are not measured.")
    else:
        failed = latest_runner.get("failedTests", [])
        if not failed:
            lines.append("No failed tests were reported in the latest runner summary.")
        else:
            rows = []
            for item in failed:
                rows.append(
                    [
                        item.get("qualified_name", ""),
                        item.get("binary_stem", ""),
                        fmt_ms(item.get("duration_ms")),
                        item.get("status", ""),
                        failure_excerpt(item),
                    ]
                )
            lines.extend(md_table(["Test", "Binary", "Duration", "Status", "Excerpt"], rows))
    lines.append("")
    lines.append("## Build Artifact Footprint")
    lines.append("")
    foot_rows = []
    for entry in data["footprint"]["entries"]:
        kib = entry["kib"]
        mib = "not present" if kib is None else f"{kib / 1024.0:.1f} MiB"
        exe = "n/a" if entry["executableFiles"] is None else str(entry["executableFiles"])
        foot_rows.append([entry["path"], mib, exe])
    lines.extend(md_table(["Path", "Size", "Executable files"], foot_rows))
    lines.append("")
    lines.append("## Classification")
    lines.append("")
    class_rows = [[name, str(count)] for name, count in sorted(static["classificationCounts"].items())]
    lines.extend(md_table(["Class", "Count"], class_rows))
    lines.append("")
    lines.append("Every test entry and its class is recorded in the JSON inventory.")
    lines.append("")
    lines.append("## Test-Body Helper Compilation")
    lines.append("")
    if not data["helperCompilationInTestBody"]:
        lines.append("No direct helper or fixture compiler invocations were detected in current test bodies.")
    else:
        rows = []
        for item in data["helperCompilationInTestBody"]:
            first = item["matches"][0]
            rows.append(
                [
                    item["source"],
                    item["class"],
                    str(first["line"]),
                    ",".join(first["patterns"]),
                    first["snippet"].replace("|", "\\|"),
                ]
            )
        lines.extend(md_table(["Source", "Class", "Line", "Compiler", "First matching command"], rows))
    lines.append("")
    lines.append("## Graph-Owned Helper Artifacts")
    lines.append("")
    lines.extend(
        md_table(
            ["Kind", "Action", "Output", "Source"],
            [[a["kind"], a["actionId"], a["output"], a["source"]] for a in graph_artifacts],
        )
    )
    lines.append("")
    lines.append("## Pure-Unit Consolidation Candidates")
    lines.append("")
    if not data["pureUnitConsolidationCandidates"]:
        lines.append("No pure-unit consolidation groups with at least two tests were found.")
    else:
        rows = []
        for group in data["pureUnitConsolidationCandidates"][:40]:
            rows.append(
                [
                    group["owner"],
                    ", ".join(group["dependencyShape"]) or "owner-local only",
                    str(group["count"]),
                    str(group["sourceCaseCount"]),
                    ", ".join(group["sources"][:8]) + (" ..." if len(group["sources"]) > 8 else ""),
                ]
            )
        lines.extend(md_table(["Owner", "Dependency shape", "Tests", "Cases", "Sources"], rows))
    lines.append("")
    lines.append("## M0 Completion Note")
    lines.append("")
    if data["timing"].get("complete") and data["slowTestReview"].get("complete"):
        lines.append("The required cold run and repeated warm-run timing baseline is present.")
    else:
        lines.append(
            "The static inventory deliverables are present, but the M0 timing baseline is incomplete "
            "until a cold run plus repeated warm runs complete successfully and every repeated-warm "
            "test above 20 seconds has a recorded review."
        )
        if not data["slowTestReview"].get("complete"):
            if runs:
                lines.append(
                    f"Authoritative slow-test review coverage is "
                    f"{data['slowTestReview']['reviewedCount']}/"
                    f"{data['slowTestReview']['candidateCount']}."
                )
            else:
                lines.append(
                    "Authoritative slow-test review coverage is unavailable until the "
                    "deferred repeated-warm summary defines the current candidate set."
                )
            lines.append(
                f"{data['slowTestReview']['retainedDiagnosticReviewCount']} prior "
                "diagnostic reviews remain available for follow-up planning."
            )
        lines.append(
            "Deferred empirical command: `" +
            data["performanceAssessment"]["deferredMeasurementCommand"] + "`."
        )
        aborted = [run for run in runs if run.get("aborted")]
        if aborted:
            latest = aborted[-1]
            partial = latest.get("partialLogSummary") or {}
            lines.append(
                "The clean single-thread attempt was intentionally aborted/redirected before completion "
                f"after {fmt_ms(latest.get('elapsedMs'))}; partial log results: "
                f"{partial.get('total', 'n/a')} total, {partial.get('passed', 'n/a')} passed, "
                f"{partial.get('failed', 'n/a')} failed."
            )
        failed_clean = [
            run
            for run in runs
            if run.get("attemptKind") == "clean"
            and run.get("cleanFirst") is True
            and run.get("exitCode") != 0
        ]
        if failed_clean:
            latest = failed_clean[-1]
            summary = (latest.get("runnerSummary") or {}).get("summary", {})
            lines.append(
                f"The clean-cold attempt failed after {fmt_ms(latest.get('elapsedMs'))}; "
                f"runner summary: {summary.get('total', 'n/a')} total, "
                f"{summary.get('passed', 'n/a')} passed, {summary.get('failed', 'n/a')} failed; "
                f"log: {latest.get('log', 'n/a')}."
            )
        failed_continuations = [
            run
            for run in runs
            if str(run.get("attemptKind", "")).startswith("continuation")
            and run.get("exitCode") != 0
        ]
        if failed_continuations:
            latest = failed_continuations[-1]
            summary = (latest.get("runnerSummary") or {}).get("summary", {})
            lines.append(
                f"The {latest.get('label')} attempt failed after {fmt_ms(latest.get('elapsedMs'))}; "
                f"runner summary: {summary.get('total', 'n/a')} total, "
                f"{summary.get('passed', 'n/a')} passed, {summary.get('failed', 'n/a')} failed; "
                f"log: {latest.get('log', 'n/a')}."
            )
    lines.append("")
    return "\n".join(lines)


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo-root", default=".", help="repository root")
    parser.add_argument("--json", default=str(DEFAULT_JSON), help="JSON inventory output path")
    parser.add_argument("--report", default=str(DEFAULT_REPORT), help="markdown report output path")
    parser.add_argument("--run-suite", action="store_true", help="run scripts/run_tests.sh before generating the report")
    parser.add_argument("--warm-runs", type=int, default=0, help="number of warm suite runs after the cold run")
    parser.add_argument("--clean-first", action="store_true", help="remove repo-local build outputs before the cold run")
    parser.add_argument(
        "--suite-timeout-seconds",
        type=int,
        default=0,
        help="per-suite-run wall timeout; 0 means no timeout",
    )
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    root = Path(args.repo_root).resolve()
    json_path = Path(args.json)
    report_path = Path(args.report)
    if not json_path.is_absolute():
        json_path = root / json_path
    if not report_path.is_absolute():
        report_path = root / report_path

    run_data = None
    if args.run_suite:
        previous_timing = load_previous_timing(root, json_path, append=not args.clean_first)
        run_data = run_suite(
            root,
            args.warm_runs,
            args.clean_first,
            args.suite_timeout_seconds,
            previous_timing=previous_timing,
        )
    else:
        run_data = load_previous_timing(root, json_path, append=True)

    data = build_inventory(root, run_data)
    json_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.parent.mkdir(parents=True, exist_ok=True)
    json_path.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    report_path.write_text(render_report(data, rel(json_path, root)), encoding="utf-8")

    print(f"wrote {rel(json_path, root)}")
    print(f"wrote {rel(report_path, root)}")

    if args.run_suite:
        failed = [run for run in data["timing"]["runs"] if run.get("exitCode") != 0]
        return 1 if failed else 0
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
