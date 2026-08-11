#!/usr/bin/env python3
"""Generate the M0 reprobuild test-suite inventory.

The default mode is static and quick: it reads the checked-in test edge table,
classifies the current tests, statically detects compiler flows in test bodies,
and writes a markdown report plus JSON details. Detection covers both explicit
compiler commands and calls through the repository's known compilation APIs;
it is deliberately described as static rather than exhaustive.

Use --run-suite in an isolated campaign worktree when a timed baseline is
needed. With --clean-first, that mode removes repo-local build outputs, runs
scripts/run_tests.sh once for the cold pass, and then runs N warm passes while
preserving each runner summary under bench-results.
"""

from __future__ import annotations

import argparse
import ast
import dataclasses
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
import tempfile
import time
from collections.abc import Mapping
from pathlib import Path
from typing import Any


DEFAULT_JSON = Path("benchmarks/reports/reprobuild-suite-m0-inventory.json")
DEFAULT_REPORT = Path("benchmarks/reports/reprobuild-suite-m0-baseline.md")
DEFAULT_SLOW_REVIEWS = Path("benchmarks/reports/reprobuild-suite-m0-slow-reviews.json")

# The human-readable half of the measurement environment. Build-local and
# untracked, for the same reason its JSON counterpart is: a `du` over a
# multi-GiB nimcache, a kernel/glibc version and a set of nix-store paths
# rewrite the document on every build and on every host. The TRACKED
# report keeps only what is stable and points here.
DEFAULT_ENVIRONMENT_REPORT = Path("build/reprobuild-suite-m0-environment.md")

# Paths measured by ``footprint``. Hoisted to a constant because the
# TRACKED report names them (which is stable) without their sizes (which
# are not).
FOOTPRINT_PATHS = (
    "build/bin",
    "build/test-bin",
    "build/nimcache",
    "build/lib",
    ".repro",
    "test-logs/results",
)
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

# Public Reprobuild APIs whose successful cold path materializes a Nim-compiled
# artifact. Keep this allow-list tied to authoritative implementation modules:
# importing an unrelated module that happens to export the same spelling must
# never classify a test as a runtime compiler flow.
#
# ``providerCompilePlan`` and ``interfaceLiftPlan`` are intentionally absent.
# They declare commands/build edges but do not execute a compiler. Their
# materializing counterparts below do. The two CLI-support adapters are
# included because their implementation unconditionally enters
# ``compileProfileToRbpi`` before adapting the result.
NIM_RUNTIME_COMPILER_API_MODULES: dict[str, dict[str, str]] = {
    "repro_interface_artifacts": {
        "compileProviderBinary": "repro-compile-provider-binary",
        "extractInterfaceFromModule": "repro-extract-interface",
        "liftInterfaceArtifact": "repro-lift-interface-artifact",
    },
    "repro_profile_compile": {
        "compileProfileBinary": "repro-compile-profile-binary",
        "compileProfileToRbpi": "repro-compile-profile-edge",
    },
    "repro_profile_compile/compile": {
        "compileProfileBinary": "repro-compile-profile-binary",
    },
    "repro_profile_compile/edge": {
        "compileProfileToRbpi": "repro-compile-profile-edge",
    },
    "repro_cli_support/home": {
        "compileAndAdaptHomeProfile": "repro-compile-home-profile",
    },
    "repro_cli_support/infra": {
        "compileAndAdaptSystemProfile": "repro-compile-system-profile",
    },
}

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


# An absolute POSIX path of at least two components, not preceded by a word
# character, ``:`` or ``/`` so that ``https://host/path`` and ``a/b/c`` are
# left alone.
ABSOLUTE_PATH_RE = re.compile(r"(?<![\w:/])((?:/[A-Za-z0-9._+~@%-]+){2,})")


def redact_absolute_paths(text: str) -> str:
    """Replace absolute host paths with ``<abs>/<basename>``.

    The tracked inventory must be byte-identical across checkouts. An
    absolute path defeats that for exactly the same reason an embedded
    timestamp does (spec §16.4), and ``$REPO_ROOT`` is not the only source
    of them: ``/nix/store/...`` entries in the recorded environment and the
    ``.so`` path in a loader-failure message are absolute and live outside
    the repository, so a guard that only looks for the repo root sees
    nothing wrong.

    The final component is kept because it is the part that carries signal
    (*which* library failed to load), and it is not host-specific.
    """
    return ABSOLUTE_PATH_RE.sub(
        lambda match: "<abs>/" + match.group(1).rsplit("/", 1)[-1], text
    )


def redact_absolute_paths_deep(value: Any) -> Any:
    """Apply :func:`redact_absolute_paths` to every string in a JSON tree.

    Keys are left alone; they are field names, never paths. This runs as the
    last step before the tracked artifact is written, so the no-absolute-path
    property is enforced by construction rather than by remembering to
    sanitize each new field that someone adds later.
    """
    if isinstance(value, str):
        return redact_absolute_paths(value)
    if isinstance(value, dict):
        return {key: redact_absolute_paths_deep(item) for key, item in value.items()}
    if isinstance(value, list):
        return [redact_absolute_paths_deep(item) for item in value]
    return value


# A ``now_utc()`` helper used to live here and stamped ``metadata.generatedAt``
# into the tracked inventory. It was removed rather than left unused: spec
# §16.4 forbids an embedded build timestamp because it makes the artifact
# differ on every regeneration even when nothing changed, and keeping a
# ready-made timestamp helper around invites exactly that regression.


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
    # ``argv``, ``cwd`` and ``pythonExecutable`` are deliberately absent.
    # They are absolute host paths (a scratch job directory, a nix store
    # interpreter path) that differ per developer and per invocation while
    # carrying no information about the suite. Recording them rewrote the
    # tracked artifact on every regeneration, which is the same defect
    # spec §16.4 forbids for an embedded build timestamp: it defeats
    # byte-level comparison of the artifact.
    return {
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


@dataclasses.dataclass(frozen=True)
class NimRuntimeCompilerApi:
    module: str
    name: str
    pattern: str


@dataclasses.dataclass(frozen=True)
class NimCallable:
    name: str
    declaration_start: int
    body_start: int
    end: int


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


# ---------------------------------------------------------------------------
# Built-binary case catalog (spec §3.2 / §6.5 ``--list-json``, §16.4 catalog)
# ---------------------------------------------------------------------------
#
# The static ``count_nim_cases`` scanner above counts ``test "..."``
# declarations in source text. That model does not match runtime
# registration and cannot be repaired with better heuristics. To be correct
# it would have to:
#
#   * evaluate ``when`` conditions — the scanner sums every branch, but
#     only one registers (44 sources over-counted on this tree);
#   * expand user-defined wrapper templates such as
#     ``template gatedTest(name: string; body: untyped) = test name:`` —
#     the scanner sees no ``test`` declaration at all and counts zero
#     (13 sources under-counted);
#   * evaluate loops that register a case per element, e.g.
#     ``for example in PopulatedExamples: test "example " & example`` —
#     one literal declaration, 71 registered cases.
#
# All three require being a Nim compiler.
#
# The built binary already knows the answer, so it is the authority here.
# ``--list-json`` is the only surface that carries the per-case protocol
# fields (``bodyHash``, ``group``, ``threadsRequired``, ``xfail``, ``tags``,
# ``deterministic``); ``--catalog`` emits only ``{name: bodyHash}``. Those
# fields are retained verbatim in the JSON inventory, which makes this the
# first consumer of M1's catalog artifacts.
#
# A binary that cannot enumerate is never silently recorded as zero cases.
# It lands in an enumerated quarantine list with a machine-readable reason,
# so the failure stays visible and shrinkable instead of masquerading as a
# coverage fact. Its static count is retained as `staticCaseCount` for
# visibility but is EXCLUDED from the authoritative total: the static scan
# sums every `when`/`else` branch, which is the very over-count this
# rework exists to remove, so importing it here would reintroduce the bug
# at exactly the point where the binary went silent.

# Per-case protocol detail is written HERE, not into the tracked inventory.
#
# This artifact is deliberately UNTRACKED (build/ is gitignored) and must
# stay that way until campaign defect #52 is fixed. `bodyHash` is a function
# of the project's ABSOLUTE PATH: any construct that expands to a string
# literal carrying the absolute source path (`check` via
# `newStrLitNode(checked.lineInfo)`, `doAssert` via `instantiationInfo`) is
# hashed verbatim by the compiler's `hashBodyTree`, so catalog hashes are
# comparable only within one fixed project path.
#
# Checking these in would therefore rewrite every hash for every developer
# and CI runner whose checkout lives at a different path — churn that
# carries no signal and that defeats the byte-level catalog diffing spec
# §16.4 protects when it forbids an embedded `compiled_at`.
#
# Once #52 is fixed and hashes are path-stable, this artifact becomes the
# input to M6's cross-host catalog diffing. Do not "helpfully" track it
# before then.
DEFAULT_CASE_CATALOG = Path("build/reprobuild-suite-case-catalog.json")
CASE_CATALOG_SCHEMA = "reprobuild-suite-case-catalog/1"

CATALOG_CACHE_PATH = Path("build/reprobuild-suite-catalog-cache.json")
# Version 2 refuses to read a version-1 cache. Version 1 stored NEGATIVE
# results (a `timeout`, a `dynamic-link-failure`) keyed by the binary's
# size and mtime, so one loaded host permanently pinned an environmental
# failure into every later run on that machine. Any v1 file on disk is
# therefore assumed poisoned and ignored rather than migrated.
CATALOG_CACHE_VERSION = 2

# Per-binary wall-clock bound for the PARALLEL probe pass.
#
# Sized from measurement, not taste. The slowest binary in the tree,
# `recipes/packages/source/plasma-workspace/test_plasma_workspace_source.nim`,
# needs ~230 s to answer `--list-json` on an idle host (it runs heavy
# module-init work before argv parsing). The inventory suite as a whole was
# observed taking 703 s against a ~104 s idle baseline on a contended host —
# a ~7x inflation — which puts the contended worst case near 1,610 s. The
# parallel bound is set above that.
#
# This is defence in depth ONLY. The bound existing at all is what turns a
# slow host into a wrong answer, so the real fix is the environmental-reason
# handling below: a `timeout` is never cached, is retried serially, and then
# aborts the run instead of quietly joining the pinned quarantine set.
CATALOG_PROBE_TIMEOUT_SECONDS = 1800
# Retry bound for the SERIAL second pass. The retry runs one binary at a
# time with the parallel pool already drained, so the host is far closer to
# idle; the larger budget exists so that a genuinely slow binary cannot be
# condemned twice by the same transient load.
CATALOG_PROBE_RETRY_TIMEOUT_SECONDS = 3600
CATALOG_PROBE_WORKERS = 16

# Per-case protocol fields retained verbatim from ``--list-json``.
CATALOG_CASE_FIELDS = (
    "suite",
    "name",
    "test",
    "file",
    "line",
    "column",
    "kind",
    "group",
    "threadsRequired",
    "xfail",
    "tags",
    "bodyHash",
    "deterministic",
)

# Byte-scan markers mirroring ``looksProtocolAwareByStrings`` in
# tools/test-runner/repro_test_runner.nim. A binary carrying neither marker
# does not implement the protocol at all, which is a different fact from a
# binary that implements it and then failed.
CATALOG_PROTOCOL_MARKERS = (
    b"ct_test_unittest_parallel",
    b"unittest: --run requires a test name",
)

# Dynamic-loader failure signatures. These are ENVIRONMENT defects (the
# binary never reached its own main), not properties of the test, and must
# never be conflated with a missing protocol.
DYNAMIC_LINK_MARKERS = (
    "could not load:",                       # Nim dlopen shim
    "error while loading shared libraries",  # glibc ld.so
    "cannot open shared object file",        # glibc ld.so detail line
    "Library not loaded:",                   # macOS dyld
    "image not found",                       # macOS dyld detail line
)

QUARANTINE_REASON_DESCRIPTIONS = {
    "dynamic-link-failure": (
        "the dynamic loader could not resolve a shared library, so the "
        "binary never reached its own entry point (environment defect)"
    ),
    "no-protocol-support": (
        "the binary carries no protocol marker string, so it does not "
        "implement --list-json at all"
    ),
    "empty-output": "--list-json exited zero but wrote nothing to stdout",
    "nonzero-exit": "--list-json exited non-zero",
    "timeout": "--list-json exceeded the per-binary wall-clock bound",
    "unparseable-json": "--list-json stdout contained no decodable catalog document",
    "malformed-catalog": "the catalog document has no `tests` array",
}

# Probe-failure taxonomy, split by WHAT THE FAILURE IS A FACT ABOUT. This
# split is the whole point of the quarantine mechanism and every other rule
# in this module derives from it.
#
# INTRINSIC — a property of the binary's own content, reproducible on any
# host from the same bytes. It may be cached, and it may legitimately be a
# member of the pinned quarantine set: the set is then a statement about the
# tree, which is what a pin is for.
INTRINSIC_QUARANTINE_REASONS = frozenset(
    {
        # No protocol marker in the image at all: nothing to enumerate.
        "no-protocol-support",
        # The binary answered and its answer is not a catalog. That is the
        # binary's output, not the host's.
        "unparseable-json",
        "malformed-catalog",
    }
)

# ENVIRONMENTAL — a property of THIS HOST or THIS RUN, not of the test. A
# timeout is not a fact about a test; neither is a missing shared library,
# an OOM kill surfacing as a non-zero exit, or a truncated stdout.
#
# Three rules, all enforced below:
#   1. never cached — caching one makes a transient load permanent;
#   2. always retried serially with a longer budget, because the parallel
#      pass is exactly the condition that produces them;
#   3. if the retry also fails, the run ABORTS with an explicit environment
#      error. It must never silently mutate the pinned quarantine set,
#      because that converts "this host was busy" into "this test lost
#      coverage".
ENVIRONMENTAL_QUARANTINE_REASONS = frozenset(
    {
        "timeout",
        "dynamic-link-failure",
        "empty-output",
        # Ambiguous by nature (a genuinely broken binary also exits
        # non-zero), and deliberately classified as environmental: the
        # consequence of misclassifying it that way is a loud abort that a
        # human resolves, while the consequence of the other choice is a
        # silent coverage loss. Fail towards the noisy option.
        "nonzero-exit",
    }
)


class CatalogEnvironmentError(RuntimeError):
    """A probe failed for a reason that is a fact about the host, not the tree.

    Raised only after the serial retry pass has also failed. Aborting is the
    designed outcome: the alternative is emitting an inventory whose case
    counts silently encode how busy the machine happened to be.
    """


def catalog_probe_env() -> dict[str, str]:
    """Environment for probing test binaries.

    Mirrors the runtime library-path construction in scripts/run_tests.sh so
    a probe sees exactly what the suite runner sees. Note that in the current
    nix dev shell ``CLINGO_LIB``/``ZSTD_LIB`` are empty and the working
    mechanism is the dev shell's own ``LD_LIBRARY_PATH``; this construction is
    kept for parity with run_tests.sh on hosts that do set them.
    """
    env = dict(os.environ)
    runtime_lib_dirs = [
        candidate
        for candidate in (env.get("CLINGO_LIB", ""), env.get("ZSTD_LIB", ""))
        if candidate and Path(candidate).is_dir()
    ]
    if runtime_lib_dirs:
        joined = ":".join(runtime_lib_dirs)
        for var in (
            "LD_LIBRARY_PATH",
            "DYLD_LIBRARY_PATH",
            "DYLD_FALLBACK_LIBRARY_PATH",
        ):
            existing = env.get(var, "")
            env[var] = f"{joined}:{existing}" if existing else joined
    return env


def binary_has_protocol_marker(path: Path) -> bool:
    """Cheap byte-scan for a protocol marker, chunked with overlap."""
    max_marker = max(len(marker) for marker in CATALOG_PROTOCOL_MARKERS)
    chunk_size = 64 * 1024
    tail = b""
    try:
        with path.open("rb") as handle:
            while True:
                chunk = handle.read(chunk_size)
                if not chunk:
                    return False
                window = tail + chunk
                if any(marker in window for marker in CATALOG_PROTOCOL_MARKERS):
                    return True
                tail = window[-max_marker:] if len(window) >= max_marker else window
    except OSError:
        return False


def first_line(text: str, limit: int = 200) -> str:
    for line in (text or "").splitlines():
        stripped = line.strip()
        if stripped:
            return stripped[:limit]
    return ""


def extract_catalog_document(stdout: str) -> dict[str, Any] | None:
    """Decode the ``--list-json`` payload out of a possibly polluted stream.

    Campaign spec A-2 finding 4 (re-confirmed and unfixed) records that
    ``--list=``/``--list-json``/``--catalog -`` are corruptible by ordinary
    stdout: a source with a top-level ``echo`` interleaves its output with
    the payload. The runner's own probe gives up whenever stdout does not
    start with ``{``. Three progressively more tolerant strategies are used
    here so leaked output degrades into a correct parse rather than a
    spurious quarantine entry.
    """
    text = (stdout or "").strip()
    if not text:
        return None

    def accept(candidate: Any) -> dict[str, Any] | None:
        if isinstance(candidate, dict) and isinstance(candidate.get("tests"), list):
            return candidate
        return None

    # (1) the clean case: the whole stream is the document.
    try:
        found = accept(json.loads(text))
    except ValueError:
        found = None
    if found is not None:
        return found

    # (2) the payload is one line among leaked lines.
    for line in text.splitlines():
        stripped = line.strip()
        if not stripped.startswith("{") or '"tests"' not in stripped:
            continue
        try:
            found = accept(json.loads(stripped))
        except ValueError:
            continue
        if found is not None:
            return found

    # (3) the payload is embedded with leading and/or trailing noise.
    decoder = json.JSONDecoder()
    marker = '{"tests"'
    index = text.find(marker)
    while index >= 0:
        try:
            candidate, _ = decoder.raw_decode(text[index:])
        except ValueError:
            candidate = None
        found = accept(candidate) if candidate is not None else None
        if found is not None:
            return found
        index = text.find(marker, index + 1)
    return None


def probe_binary_catalog(
    binary_path: Path,
    cwd: Path,
    env: dict[str, str],
    timeout_seconds: int,
) -> dict[str, Any]:
    """Enumerate one built test binary through ``--list-json``."""
    if not binary_has_protocol_marker(binary_path):
        return {
            "status": "no-protocol-support",
            "detail": "no protocol marker string present in the binary",
        }
    try:
        completed = subprocess.run(
            [str(binary_path), "--list-json"],
            capture_output=True,
            text=True,
            errors="replace",
            timeout=timeout_seconds,
            cwd=str(cwd),
            env=env,
        )
    except subprocess.TimeoutExpired:
        return {
            "status": "timeout",
            "detail": f"--list-json exceeded {timeout_seconds}s",
        }
    except OSError as exc:
        return {"status": "nonzero-exit", "detail": f"could not execute: {exc}"}

    stderr = completed.stderr or ""
    # The loader check comes first: a link failure can surface as any exit
    # code, and misreading it as "no protocol" is precisely the error this
    # quarantine taxonomy exists to prevent.
    if any(marker in stderr for marker in DYNAMIC_LINK_MARKERS):
        return {"status": "dynamic-link-failure", "detail": first_line(stderr)}
    # TWO-CHANNEL RULE (shared with tools/test-runner/repro_test_runner.nim;
    # keep the two in step).
    #
    # A component that reads two status channels for the same fact — here
    # the process exit code and the `--list-json` document on stdout —
    # must never ABSORB a disagreement between them. It may choose which
    # channel labels the individual item, but a disagreement has to reach
    # the aggregate outcome.
    #
    # The runner resolves the per-case label towards the result document
    # (the case's own first-hand account) and now makes any disagreement
    # force a non-zero aggregate exit. This probe resolves the per-binary
    # label towards the exit code, because a non-zero exit from a program
    # asked only to print its catalog means the enumeration itself is
    # untrustworthy, whatever landed on stdout. The two resolutions differ;
    # the invariant does not, because `nonzero-exit` is classified
    # ENVIRONMENTAL and therefore aborts the run rather than degrading the
    # source to a static count.
    if completed.returncode != 0:
        return {
            "status": "nonzero-exit",
            "detail": f"exit {completed.returncode}: {first_line(stderr)}".strip(),
        }

    document = extract_catalog_document(completed.stdout or "")
    if document is None:
        if not (completed.stdout or "").strip():
            return {"status": "empty-output", "detail": first_line(stderr)}
        return {"status": "unparseable-json", "detail": first_line(completed.stdout)}

    cases: list[dict[str, Any]] = []
    for entry in document["tests"]:
        if not isinstance(entry, Mapping):
            return {"status": "malformed-catalog", "detail": "non-object test entry"}
        cases.append({field: entry.get(field) for field in CATALOG_CASE_FIELDS})
    return {"status": "ok", "cases": cases}


def binary_cache_key(path: Path) -> str | None:
    try:
        info = path.stat()
    except OSError:
        return None
    return f"{info.st_size}:{info.st_mtime_ns}"


def load_catalog_cache(path: Path) -> dict[str, Any]:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    if not isinstance(payload, dict) or payload.get("version") != CATALOG_CACHE_VERSION:
        return {}
    entries = payload.get("entries")
    return entries if isinstance(entries, dict) else {}


def store_catalog_cache(path: Path, entries: dict[str, Any]) -> None:
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(
            json.dumps(
                {"version": CATALOG_CACHE_VERSION, "entries": entries},
                sort_keys=True,
            ),
            encoding="utf-8",
        )
    except OSError:
        # The cache is an optimization only; losing it costs time, not
        # correctness, so a read-only or full filesystem must not abort the run.
        pass


def specs_digest(specs: list[TestSpec]) -> str:
    """Identity of the spec set a catalog index was built for.

    Part of the memo key. Without it, ``catalog_index`` returns whatever
    the FIRST caller in the process asked for: a one-spec probe (the
    missing-binary regression test) would satisfy a later full-tree call,
    every real source would degrade to ``missing-binary``, and the whole
    inventory would silently revert to the static scan the binary-as-
    authority rework exists to replace.
    """
    digest = hashlib.sha256()
    for spec in specs:
        digest.update(spec.source.encode("utf-8"))
        digest.update(b"\0")
        digest.update((spec.binary or "").encode("utf-8"))
        digest.update(b"\0")
        digest.update((spec.language or "").encode("utf-8"))
        digest.update(b"\0\0")
    return digest.hexdigest()


_CATALOG_INDEX_MEMO: dict[tuple[str, str, int, int, bool], dict[str, Any]] = {}


def catalog_index(
    root: Path,
    specs: list[TestSpec],
    timeout_seconds: int = CATALOG_PROBE_TIMEOUT_SECONDS,
    workers: int = CATALOG_PROBE_WORKERS,
    use_cache: bool = True,
    retry_timeout_seconds: int = CATALOG_PROBE_RETRY_TIMEOUT_SECONDS,
) -> dict[str, dict[str, Any]]:
    """Probe every built test binary, memoized per process and cached on disk.

    Probing 1200+ binaries costs a few minutes of wall time on a cold cache
    (a handful of ``recipes/packages/source/*`` binaries run heavy module-init
    work before argv parsing; one takes almost four minutes on its own). The
    on-disk cache is keyed by each binary's size and mtime, so a rebuild
    re-probes exactly the binaries that changed and nothing else.

    Three properties this function is required to hold:

    * **Only successful probes are cached.** A cached failure is a lie about
      the tree that survives the condition that produced it.
    * **Environmental failures are retried serially** with a longer budget
      before being believed, because a contended parallel pass is the
      dominant cause of them.
    * **A surviving environmental failure aborts** via
      ``CatalogEnvironmentError``. Degrading to a static count would encode
      host load as a coverage fact.

    The probe runs each binary with ``cwd`` set to a scratch directory, never
    the repo root: test binaries have been observed dropping stray files
    (``test_kglobalaccel_source_linkerArgs.txt``) into their working
    directory, and ``source_fingerprint`` hashes untracked files, so probing
    in-tree let the measurement change the fingerprint it was recording.
    """
    memo_key = (
        str(root),
        specs_digest(specs),
        timeout_seconds,
        workers,
        use_cache,
    )
    memoized = _CATALOG_INDEX_MEMO.get(memo_key)
    if memoized is not None:
        return memoized

    cache_path = root / CATALOG_CACHE_PATH
    cached = load_catalog_cache(cache_path) if use_cache else {}
    env = catalog_probe_env()

    results: dict[str, dict[str, Any]] = {}
    pending: list[tuple[str, Path]] = []
    for spec in specs:
        if spec.language != "nim" or not spec.binary:
            continue
        binary_path = root / spec.binary
        key = binary_cache_key(binary_path)
        if key is None:
            results[spec.source] = {
                "status": "missing-binary",
                "detail": "no built binary under build/test-bin",
            }
            continue
        entry = cached.get(spec.source)
        if (
            use_cache
            and isinstance(entry, dict)
            and entry.get("key") == key
            and isinstance(entry.get("result"), dict)
            # Defence in depth behind ``store_catalog_cache``: even a cache
            # written by an older or hand-edited version cannot replay a
            # failure. Only an ``ok`` entry is ever reused.
            and entry["result"].get("status") == "ok"
        ):
            results[spec.source] = entry["result"]
            continue
        pending.append((spec.source, binary_path))

    with tempfile.TemporaryDirectory(prefix="repro-catalog-probe-") as scratch:
        probe_cwd = Path(scratch)
        if pending:
            from concurrent.futures import ThreadPoolExecutor

            def run_one(item: tuple[str, Path]) -> tuple[str, dict[str, Any]]:
                source, binary_path = item
                return source, probe_binary_catalog(
                    binary_path, probe_cwd, env, timeout_seconds
                )

            with ThreadPoolExecutor(max_workers=max(1, workers)) as pool:
                for source, outcome in pool.map(run_one, pending):
                    results[source] = outcome

        # Serial retry pass. Environmental failures are the ones the
        # parallel pass itself can manufacture, so they are re-measured
        # with the pool drained and a longer budget before being believed.
        retried: dict[str, dict[str, Any]] = {}
        by_source = {spec.source: spec for spec in specs}
        for source in sorted(results):
            outcome = results[source]
            if outcome.get("status") not in ENVIRONMENTAL_QUARANTINE_REASONS:
                continue
            spec = by_source.get(source)
            if spec is None or not spec.binary:
                continue
            print(
                "reprobuild_suite_inventory: re-probing "
                f"{source} serially after an environmental failure "
                f"({outcome.get('status')}); budget {retry_timeout_seconds}s",
                file=sys.stderr,
            )
            second = probe_binary_catalog(
                root / spec.binary, probe_cwd, env, retry_timeout_seconds
            )
            results[source] = second
            retried[source] = second

    surviving = {
        source: outcome
        for source, outcome in retried.items()
        if outcome.get("status") in ENVIRONMENTAL_QUARANTINE_REASONS
    }
    if surviving:
        details = "; ".join(
            f"{source}: {outcome.get('status')} "
            f"({outcome.get('detail', '')})"
            for source, outcome in sorted(surviving.items())
        )
        raise CatalogEnvironmentError(
            f"{len(surviving)} test binaries failed --list-json for "
            "environmental reasons on both the parallel and the serial "
            f"retry pass (retry budget {retry_timeout_seconds}s): {details}. "
            "These are facts about this host, not about the suite, so the "
            "inventory refuses to record them as quarantined coverage. "
            "Re-run on an idle host inside the nix dev shell "
            "(`direnv exec .`)."
        )

    if use_cache:
        refreshed = dict(cached)
        for spec in specs:
            if spec.language != "nim" or not spec.binary:
                continue
            outcome = results.get(spec.source)
            key = binary_cache_key(root / spec.binary)
            if outcome is None or key is None:
                continue
            # NEVER cache a non-ok probe. A cached `timeout` replays a
            # busy afternoon into every future run on the machine, and
            # there is no way to tell from the cache entry that it was
            # ever transient. A stale POSITIVE cannot happen: the key is
            # the binary's size and mtime.
            if outcome.get("status") != "ok":
                refreshed.pop(spec.source, None)
                continue
            refreshed[spec.source] = {"key": key, "result": outcome}
        store_catalog_cache(cache_path, refreshed)

    _CATALOG_INDEX_MEMO[memo_key] = results
    return results


def nim_next_token(tokens: list[NimToken], position: int) -> int | None:
    position += 1
    while position < len(tokens) and tokens[position].kind == "newline":
        position += 1
    return position if position < len(tokens) else None


def nim_module_key(tokens: list[NimToken]) -> str:
    """Normalize one explicit Nim module path without guessing resolution."""

    parts: list[str] = []
    for token in tokens:
        name = nim_identifier_value(token)
        if name is not None:
            parts.append(nim_name_key(name))
        elif token.value in {".", "/"}:
            parts.append(token.value)
    result = "".join(parts)
    while result.startswith("./"):
        result = result[2:]
    return result


def nim_runtime_api_modules() -> dict[str, dict[str, NimRuntimeCompilerApi]]:
    result: dict[str, dict[str, NimRuntimeCompilerApi]] = {}
    for module, names in NIM_RUNTIME_COMPILER_API_MODULES.items():
        result[nim_module_key(nim_tokens(module))] = {
            nim_name_key(name): NimRuntimeCompilerApi(module, name, pattern)
            for name, pattern in names.items()
        }
    return result


def nim_split_import_items(tokens: list[NimToken]) -> list[list[NimToken]]:
    """Split a comma-separated import list while preserving bracket groups."""

    items: list[list[NimToken]] = []
    current: list[NimToken] = []
    stack: list[str] = []
    for token in tokens:
        if token.value in NIM_DELIMITERS:
            stack.append(NIM_DELIMITERS[token.value])
        elif token.value in NIM_CLOSING_DELIMITERS:
            if stack and stack[-1] == token.value:
                stack.pop()
        if token.value == "," and not stack:
            if current:
                items.append(current)
            current = []
        else:
            current.append(token)
    if current:
        items.append(current)
    return items


def nim_first_identifier(tokens: list[NimToken], start: int) -> tuple[int, str] | None:
    cursor = start
    while cursor < len(tokens):
        name = nim_identifier_value(tokens[cursor])
        if name is not None:
            return cursor, name
        if tokens[cursor].kind != "newline" and tokens[cursor].value not in {"*", "`"}:
            return None
        cursor += 1
    return None


def nim_runtime_compiler_bindings(
    tokens: list[NimToken], depths: list[int]
) -> tuple[
    dict[str, NimRuntimeCompilerApi],
    dict[str, dict[str, NimRuntimeCompilerApi]],
]:
    """Resolve only explicit imports of authoritative compiler-owning modules.

    Local bindings and selective imports from unrelated modules are treated as
    shadows for the whole file. This intentionally prefers a false negative to
    classifying a same-named local helper or third-party API as Reprobuild's
    compiler entry point.
    """

    modules = nim_runtime_api_modules()
    unqualified: dict[str, NimRuntimeCompilerApi] = {}
    qualifiers: dict[str, dict[str, NimRuntimeCompilerApi]] = {}
    ambiguous_unqualified: set[str] = set()
    ambiguous_qualifiers: set[str] = set()
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
            for item in nim_split_import_items(statement):
                alias_position = next(
                    (
                        index
                        for index, candidate in enumerate(item)
                        if nim_identifier_matches(candidate, "as")
                    ),
                    None,
                )
                except_position = next(
                    (
                        index
                        for index, candidate in enumerate(item)
                        if nim_identifier_matches(candidate, "except")
                    ),
                    None,
                )
                module_end = min(
                    index
                    for index in [
                        alias_position if alias_position is not None else len(item),
                        except_position if except_position is not None else len(item),
                    ]
                )
                module_key = nim_module_key(item[:module_end])
                module_apis = modules.get(module_key)
                alias = (
                    nim_identifier_value(item[alias_position + 1])
                    if alias_position is not None
                    and alias_position + 1 < len(item)
                    else None
                )
                default_qualifier = next(
                    (
                        nim_identifier_value(candidate)
                        for candidate in reversed(item[:module_end])
                        if nim_identifier_value(candidate) is not None
                    ),
                    None,
                )
                qualifier = alias or default_qualifier
                if module_apis is None:
                    if alias is not None:
                        ambiguous_qualifiers.add(nim_name_key(alias))
                    continue
                if qualifier is not None:
                    qualifiers[nim_name_key(qualifier)] = module_apis
                # An aliased module is deliberately accepted only through its
                # qualifier. That is the unambiguous spelling the alias exists
                # to provide.
                if alias is not None:
                    continue
                excluded = {
                    nim_name_key(name)
                    for candidate in (
                        item[except_position + 1 :]
                        if except_position is not None
                        else []
                    )
                    if (name := nim_identifier_value(candidate)) is not None
                }
                for name, api in module_apis.items():
                    if name not in excluded:
                        unqualified[name] = api

        elif nim_identifier_matches(token, "from"):
            end = nim_statement_end(tokens, depths, position)
            statement = [
                item
                for item in tokens[position + 1 : end]
                if item.kind != "newline"
            ]
            import_position = next(
                (
                    index
                    for index, candidate in enumerate(statement)
                    if nim_identifier_matches(candidate, "import")
                ),
                None,
            )
            if import_position is None:
                continue
            module_key = nim_module_key(statement[:import_position])
            module_apis = modules.get(module_key)
            for member in nim_split_import_items(statement[import_position + 1 :]):
                if not member:
                    continue
                source_name = nim_identifier_value(member[0])
                if source_name is None:
                    continue
                alias = None
                if (
                    len(member) >= 3
                    and nim_identifier_matches(member[1], "as")
                ):
                    alias = nim_identifier_value(member[2])
                bound_name = alias or source_name
                source_key = nim_name_key(source_name)
                bound_key = nim_name_key(bound_name)
                if module_apis is not None and source_key in module_apis:
                    unqualified[bound_key] = module_apis[source_key]
                elif source_key in {
                    name
                    for apis in modules.values()
                    for name in apis
                }:
                    ambiguous_unqualified.add(bound_key)

    local_bindings: set[str] = set()
    for position, token in enumerate(tokens):
        identifier = nim_identifier_value(token)
        if (
            identifier is None
            or nim_name_key(identifier) not in NIM_BINDING_KEYWORDS
        ):
            continue
        found = nim_first_identifier(tokens, position + 1)
        if found is not None:
            local_bindings.add(nim_name_key(found[1]))

    for name in local_bindings | ambiguous_unqualified:
        unqualified.pop(name, None)
    for name in local_bindings | ambiguous_qualifiers:
        qualifiers.pop(name, None)
    return unqualified, qualifiers


def nim_callable_declarations(
    tokens: list[NimToken], depths: list[int]
) -> list[NimCallable]:
    """Find local callable bodies needed for conservative reachability."""

    callables: list[NimCallable] = []
    callable_keywords = {"proc", "func", "template", "macro", "method", "iterator"}
    for position, token in enumerate(tokens):
        identifier = nim_identifier_value(token)
        if identifier is None or nim_name_key(identifier) not in callable_keywords:
            continue
        previous = nim_previous_token(tokens, position)
        if (
            previous is not None
            and tokens[previous].line == token.line
            and tokens[previous].value not in {":", ";"}
        ):
            continue
        found = nim_first_identifier(tokens, position + 1)
        if found is None:
            continue
        _, name = found
        base_depth = depths[position]
        body_marker: int | None = None
        cursor = found[0] + 1
        while cursor < len(tokens):
            candidate = tokens[cursor]
            if (
                candidate.kind == "operator"
                and candidate.value == "="
                and depths[cursor] == base_depth
            ):
                body_marker = cursor
                break
            if (
                candidate.kind == "newline"
                and depths[cursor] == base_depth
                and candidate.line > token.line + 8
            ):
                break
            cursor += 1
        if body_marker is None:
            continue
        body_start = nim_next_token(tokens, body_marker)
        if body_start is None:
            continue
        end = len(tokens)
        for candidate_position in range(body_start + 1, len(tokens)):
            candidate = tokens[candidate_position]
            if (
                candidate.line > tokens[body_start].line
                and candidate.column <= token.column
                and depths[candidate_position] == base_depth
                and candidate.kind != "newline"
            ):
                end = candidate_position
                break
        callables.append(
            NimCallable(
                name=name,
                declaration_start=position,
                body_start=body_start,
                end=end,
            )
        )
    return callables


def nim_non_runtime_ranges(
    tokens: list[NimToken], depths: list[int]
) -> list[tuple[int, int]]:
    """Find explicit compile-time or lexically dead blocks."""

    ranges: list[tuple[int, int]] = []
    for position, token in enumerate(tokens):
        is_static = nim_identifier_matches(token, "static")
        is_false_when = False
        if nim_identifier_matches(token, "when"):
            value_position = nim_next_token(tokens, position)
            is_false_when = (
                value_position is not None
                and nim_identifier_matches(tokens[value_position], "false")
            )
        if not (is_static or is_false_when):
            continue
        base_depth = depths[position]
        colon: int | None = None
        cursor = position + 1
        while cursor < len(tokens):
            if tokens[cursor].value == ":" and depths[cursor] == base_depth:
                colon = cursor
                break
            if (
                tokens[cursor].kind == "newline"
                and depths[cursor] == base_depth
                and tokens[cursor].line > token.line
            ):
                break
            cursor += 1
        if colon is None:
            continue
        body_start = nim_next_token(tokens, colon)
        if body_start is None:
            continue
        end = len(tokens)
        for candidate_position in range(body_start + 1, len(tokens)):
            candidate = tokens[candidate_position]
            if (
                candidate.line > tokens[body_start].line
                and candidate.column <= token.column
                and depths[candidate_position] == base_depth
                and candidate.kind != "newline"
            ):
                end = candidate_position
                break
        ranges.append((body_start, end))
    return ranges


def nim_token_is_call(tokens: list[NimToken], name_position: int) -> bool:
    next_position = nim_next_token(tokens, name_position)
    return (
        next_position is not None
        and tokens[next_position].value == "("
    )


def nim_enclosing_callable(
    callables: list[NimCallable], position: int
) -> NimCallable | None:
    candidates = [
        callable
        for callable in callables
        if callable.body_start <= position < callable.end
    ]
    return max(candidates, key=lambda callable: callable.body_start) if candidates else None


def nim_runtime_compiler_api_invocations(
    path: str, text: str
) -> list[dict[str, Any]]:
    """Find reachable calls through known Reprobuild compilation APIs.

    This is intentionally a static lexical/call-closure detector, not a Nim
    semantic proof. It recognizes exact trusted imports and follows ordinary
    local callable wrappers. Dynamic dispatch, include/re-export bindings,
    function-value data flow, and calls assembled by macros remain outside its
    scope and are stated as limitations in the generated report.
    """

    if not path.endswith(".nim"):
        return []
    tokens = nim_tokens(text)
    depths = nim_outer_depths(tokens)
    unqualified, qualifiers = nim_runtime_compiler_bindings(tokens, depths)
    if not unqualified and not qualifiers:
        return []

    callables = nim_callable_declarations(tokens, depths)
    excluded_ranges = nim_non_runtime_ranges(tokens, depths)

    def excluded(position: int) -> bool:
        return any(start <= position < end for start, end in excluded_ranges)

    local_names = {
        nim_name_key(callable.name)
        for callable in callables
    }
    roots: set[str] = set()
    edges: dict[str, set[str]] = {
        name: set()
        for name in local_names
    }
    for position, token in enumerate(tokens):
        name = nim_identifier_value(token)
        if name is None or nim_name_key(name) not in local_names:
            continue
        if not nim_token_is_call(tokens, position) or excluded(position):
            continue
        # Do not mistake ``proc wrapper(...) =`` for an invocation.
        if any(
            callable.declaration_start < position < callable.body_start
            for callable in callables
            if nim_name_key(callable.name) == nim_name_key(name)
        ):
            continue
        owner = nim_enclosing_callable(callables, position)
        if owner is None:
            roots.add(nim_name_key(name))
        else:
            edges.setdefault(nim_name_key(owner.name), set()).add(
                nim_name_key(name)
            )

    reachable = set(roots)
    pending = list(roots)
    while pending:
        caller = pending.pop()
        for callee in edges.get(caller, set()):
            if callee not in reachable:
                reachable.add(callee)
                pending.append(callee)

    source_lines = text.splitlines()
    matches: list[dict[str, Any]] = []
    for position, token in enumerate(tokens):
        if excluded(position):
            continue
        api: NimRuntimeCompilerApi | None = None
        name_position = position
        name = nim_identifier_value(token)
        if name is not None:
            api = unqualified.get(nim_name_key(name))
        if api is None and position + 2 < len(tokens):
            qualifier = nim_identifier_value(token)
            member = nim_identifier_value(tokens[position + 2])
            if (
                qualifier is not None
                and tokens[position + 1].value == "."
                and member is not None
            ):
                api = qualifiers.get(nim_name_key(qualifier), {}).get(
                    nim_name_key(member)
                )
                name_position = position + 2
        if api is None or not nim_token_is_call(tokens, name_position):
            continue
        owner = nim_enclosing_callable(callables, position)
        if owner is not None and nim_name_key(owner.name) not in reachable:
            continue
        line = tokens[name_position].line
        matches.append(
            {
                "path": path,
                "line": line,
                "patterns": [api.pattern],
                "snippet": (
                    source_lines[line - 1].strip()[:220]
                    if 0 < line <= len(source_lines)
                    else api.name
                ),
                "directExecutionLine": owner is None,
                "assignedCommandVariable": "",
                "commandVariableExecuted": False,
                "executedVariables": [],
                "runtimeCompilerApi": api.name,
                "runtimeCompilerApiModule": api.module,
                "enclosingCallable": owner.name if owner is not None else "",
                "callableReachable": owner is None or (
                    nim_name_key(owner.name) in reachable
                ),
            }
        )
    return matches


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

    explicit_matches = [
        item
        for item in matches
        if item.get("directExecutionLine") or item.get("commandVariableExecuted")
    ]
    return sorted(
        explicit_matches + nim_runtime_compiler_api_invocations(path, text),
        key=lambda item: (item["line"], item["patterns"]),
    )


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
    failed = [t for t in tests if t.get("status") == "FAIL"]
    # A case the runner could not START is a distinct outcome from a case
    # that ran and failed (repro_test_runner ``TestStatus.tsHarnessError``
    # / summary ``harness_errors``). Rolling it into ``failedTests`` here
    # would re-merge, in the consumer, the distinction the producer just
    # went to the trouble of making.
    harness_errors = [t for t in tests if t.get("status") == "ERROR"]
    other = [
        t for t in tests
        if t.get("status") not in ("PASS", "SKIP", "FAIL", "ERROR")
    ]
    # EVERY case must be nameable from this artifact alone. The whole
    # point of a machine-readable summary is that a gate does not have to
    # grep a console log to learn which case it is looking at; an entry
    # with no ``name`` silently pushes verification back to log-grepping,
    # which is how a "zero skips" conclusion once survived three runs
    # that each carried 176 skips. Surfaced as data rather than raised so
    # that inspecting a damaged artifact stays possible.
    unnamed = [
        t for t in tests
        if not isinstance(t.get("name"), str) or not t.get("name").strip()
    ]
    return {
        "path": str(summary_path),
        "summary": doc.get("summary", {}),
        "protocolAwareCases": len(protocol_aware),
        "wholeBinaryCases": len(tests) - len(protocol_aware),
        "slowestTests": slowest,
        "failedTests": failed,
        "harnessErrorTests": harness_errors,
        "unrecognizedStatusTests": other,
        "unnamedCaseCount": len(unnamed),
        "unnamedCases": unnamed[:20],
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
    entries = []
    for item in FOOTPRINT_PATHS:
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


def catalog_count_source(outcome: dict[str, Any] | None) -> str:
    """Label the provenance of one Nim source's case count.

    Four distinct labels, deliberately not three:

    ``catalog``        the built binary enumerated itself (authoritative);
    ``missing-binary`` no binary was built, so nothing could enumerate;
    ``quarantined``    a binary exists and could not enumerate;
    ``static``         no probe was attempted at all (``--no-catalog``).

    ``missing-binary`` used to be folded into ``static``, which made it
    indistinguishable from a Python file that legitimately has no binary —
    a build gap and a language property reported with the same word.
    """
    if outcome is None:
        return "static"
    status = outcome.get("status")
    if status == "ok":
        return "catalog"
    if status == "missing-binary":
        return "missing-binary"
    return "quarantined"


def build_inventory(
    root: Path,
    run_data: dict[str, Any] | None,
    use_catalog: bool = True,
    use_catalog_cache: bool = True,
) -> dict[str, Any]:
    nim_specs, py_specs = parse_repro_tests(root)
    all_specs = nim_specs + py_specs
    tests = []
    helper_compiles = []
    class_counts: dict[str, int] = {}
    source_case_count = 0

    catalog = (
        catalog_index(root, nim_specs, use_cache=use_catalog_cache)
        if use_catalog
        else {}
    )
    quarantine: list[dict[str, Any]] = []
    count_source_counts: dict[str, int] = {}

    for spec in all_specs:
        source_path = root / spec.source
        text = read_text(source_path)
        case_info = count_python_cases(source_path) if spec.language == "python" else count_nim_cases(text)
        static_case_count = case_info["caseCount"]

        # Authoritative case count. The built binary wins whenever it can
        # enumerate; otherwise the static scan is used and the entry is
        # explicitly labelled so no reader can mistake one mechanism for the
        # other. A failed probe never silently becomes zero.
        catalog_cases: list[dict[str, Any]] | None = None
        catalog_suite_count: int | None = None
        quarantine_reason = ""
        if spec.language == "python":
            count_source = "static"
        else:
            outcome = catalog.get(spec.source)
            count_source = catalog_count_source(outcome)
            if count_source == "catalog":
                catalog_cases = outcome["cases"]
                catalog_suite_count = len(
                    {case.get("suite") or "" for case in catalog_cases}
                )
            elif count_source == "quarantined":
                quarantine_reason = str(outcome.get("status", "unknown"))
                quarantine.append(
                    {
                        "source": spec.source,
                        "binary": spec.binary,
                        "reason": quarantine_reason,
                        "reasonDescription": QUARANTINE_REASON_DESCRIPTIONS.get(
                            quarantine_reason, "unclassified probe failure"
                        ),
                        # Sanitized: a loader failure's first stderr line
                        # names an absolute `.so` path, and this record is
                        # carried into the TRACKED artifact.
                        "detail": redact_absolute_paths(
                            str(outcome.get("detail", ""))
                        ),
                        "staticCaseCount": static_case_count,
                    }
                )

        if catalog_cases is not None:
            case_count = len(catalog_cases)
        elif count_source == "quarantined":
            # A quarantined source contributes NOTHING to the authoritative
            # total. The binary is the enumeration authority; when it cannot
            # answer, the honest number is "unknown", and substituting the
            # static scan is precisely the `when`-branch over-count this
            # rework exists to remove.
            #
            # Concretely: t_n7_multicast_windows_smoke.nim wraps its whole
            # body in `when defined(windows)` with `else: discard`, so it
            # registers 0 cases on Linux while the static scanner sees 1.
            # Feeding that 1 into the total made the pinned Nim total 6821
            # against a true registered total of 6820 — the number the
            # independent `--list` cross-check produces. The static count
            # stays visible
            # as `staticCaseCount`; it just no longer votes.
            case_count = 0
        else:
            case_count = static_case_count
        count_source_counts[count_source] = count_source_counts.get(count_source, 0) + 1
        source_case_count += case_count

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
        entry: dict[str, Any] = {
            "source": spec.source,
            "binary": spec.binary,
            "language": spec.language,
            "owner": spec.owner,
            "defines": spec.defines,
            "requiresReproBinary": spec.requires_repro_binary,
            "targetOs": spec.target_os,
            "sourceCaseCount": case_count,
            "countSource": count_source,
            "staticCaseCount": static_case_count,
            "sourceSuiteCount": case_info["suiteCount"],
            "class": category,
            "classificationReason": reason,
            "staticallyDetectedRuntimeCompilerFlow": bool(compiles),
            "localDependencyShape": local_dependency_shape(spec, text),
        }
        if quarantine_reason:
            entry["quarantineReason"] = quarantine_reason
        if catalog_cases is not None:
            entry["catalogSuiteCount"] = catalog_suite_count
            entry["catalogCases"] = catalog_cases
        tests.append(entry)

    quarantine.sort(key=lambda item: item["source"])
    quarantine_reason_counts: dict[str, int] = {}
    for item in quarantine:
        quarantine_reason_counts[item["reason"]] = (
            quarantine_reason_counts.get(item["reason"], 0) + 1
        )
    # A mass dynamic-link failure means the probe ran outside the nix dev
    # shell, not that the suite lost coverage. Surfacing it as an ordinary
    # quarantine would let an environment problem be read as a coverage fact,
    # which is the same class of error the catalog rework exists to remove.
    #
    # This count is now structurally zero: `dynamic-link-failure` is an
    # ENVIRONMENTAL reason, so `catalog_index` retries it serially and then
    # raises `CatalogEnvironmentError` rather than returning it. The field
    # and its note are retained as a second line of defence — if an
    # environmental reason ever reaches this code again, it is still
    # reported as an environment defect and never as coverage.
    dynamic_link_failures = quarantine_reason_counts.get("dynamic-link-failure", 0)
    catalog_enumeration = {
        "method": "built binary --list-json (spec §3.2/§6.5)",
        "retainedCaseFields": list(CATALOG_CASE_FIELDS),
        "probeTimeoutSeconds": CATALOG_PROBE_TIMEOUT_SECONDS,
        "probeRetryTimeoutSeconds": CATALOG_PROBE_RETRY_TIMEOUT_SECONDS,
        "cacheEnabled": use_catalog_cache,
        # The taxonomy is published in the artifact so a reader can tell,
        # without reading this script, which quarantine memberships are
        # claims about the tree and which could never have been recorded.
        "intrinsicQuarantineReasons": sorted(INTRINSIC_QUARANTINE_REASONS),
        "environmentalQuarantineReasons": sorted(
            ENVIRONMENTAL_QUARANTINE_REASONS
        ),
        "environmentalReasonPolicy": (
            "never cached, retried serially with a longer budget, and if "
            "still failing the run aborts; an environmental failure may not "
            "join the quarantine set or change any case count"
        ),
        "quarantinedCasesExcludedFromTotal": True,
        "enabled": use_catalog,
        "countSourceCounts": count_source_counts,
        "quarantineCount": len(quarantine),
        "quarantineReasonCounts": quarantine_reason_counts,
        "quarantine": quarantine,
        "dynamicLinkFailureCount": dynamic_link_failures,
        "environmentDegraded": dynamic_link_failures > 0,
        "environmentNote": (
            (
                f"{dynamic_link_failures} binaries could not be dynamically "
                "linked. This inventory was probed WITHOUT the nix dev-shell "
                "runtime library path; the affected counts fell back to the "
                "static scan and are an environment defect, not a coverage "
                "fact. Re-run under `direnv exec .`."
            )
            if dynamic_link_failures
            else ""
        ),
    }
    if dynamic_link_failures:
        print(
            "reprobuild_suite_inventory: WARNING: "
            + catalog_enumeration["environmentNote"],
            file=sys.stderr,
        )

    consolidation_candidates = []
    by_boundary: dict[tuple[Any, ...], list[dict[str, Any]]] = {}
    for item in tests:
        if (
            item["language"] == "nim"
            and item["class"] == "pure unit"
            and not item["staticallyDetectedRuntimeCompilerFlow"]
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
            candidate["staticallyDetectedRuntimeCompilerFlow"] = inventory_item.get(
                "staticallyDetectedRuntimeCompilerFlow", False
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
            "staticallyDetectedRuntimeCompilerFlowTests": len(helper_compiles),
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
        # ``generatedAt`` and an absolute ``repoRoot`` are deliberately
        # absent. Spec §16.4 forbids an embedded build timestamp precisely
        # because it makes the document differ on every regeneration even
        # when nothing changed, defeating byte-level comparison; an absolute
        # repo root is the same defect keyed on checkout location instead of
        # wall-clock. ``head``/``branch``/``sourceFingerprint`` below already
        # identify exactly which tree produced this artifact.
        "metadata": {
            "repoRoot": ".",
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
        "catalogEnumeration": catalog_enumeration,
        "tests": tests,
        "staticallyDetectedRuntimeCompilerFlows": helper_compiles,
        "runtimeCompilerFlowDetection": {
            "method": (
                "static lexical, explicit-command data-flow, trusted-import, "
                "and reachable local-call-closure analysis"
            ),
            "exhaustive": False,
            "limitations": [
                (
                    "Dynamic dispatch, macro-generated calls, include/re-export "
                    "bindings, and function-value data flow are not resolved."
                ),
                (
                    "A statically detected API flow may take a valid cache-hit "
                    "fast path and avoid launching the compiler on a particular run."
                ),
                (
                    "Normal product-level repro invocations are not inferred to "
                    "compile merely because a selected build could compile a provider."
                ),
            ],
        },
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
    # Order matters: prefer the case's OWN account over free-form output.
    #
    # A per-case child runs `<binary> --run "<case>"`, which puts the
    # unittest fork into pmRun -- a mode that registers no console
    # formatter -- so the child prints nothing and `stdout` is empty for
    # every ordinary assertion failure. Reading only stdout/stderr
    # therefore rendered a BLANK excerpt for exactly the failures a
    # reader opens this report to understand, while still filling in for
    # the runner-synthesised harness-fault text. `checkpoints`,
    # `exception` and `harness_error` come from the result document and
    # are the only channels a per-case failure has.
    parts = [
        "\n".join(item.get("checkpoints") or []),
        item.get("exception") or "",
        item.get("harness_error") or "",
        item.get("stdout") or "",
        item.get("stderr") or "",
    ]
    output = "\n".join(part for part in parts if part)
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


FAILURE_SECTION_GROUPS = (
    ("failedTests", "Tests that ran and failed."),
    (
        "harnessErrorTests",
        "Cases the harness could not run (ERROR). These are statements "
        "about the run, not about the tree; each one still fails the run.",
    ),
    (
        "unrecognizedStatusTests",
        "Cases reporting a status this runner does not recognise "
        "(a protocol violation in the test binary).",
    ),
)


def render_failed_tests_section(
    latest_runner: dict[str, Any] | None,
) -> list[str]:
    """Render "## Failed Tests" covering EVERY non-passing outcome.

    `summarize_runner` deliberately splits the runner's three non-passing
    outcomes -- FAIL (the case ran and failed), ERROR (the harness could
    not obtain a verdict) and an unrecognized status (a protocol
    violation) -- because they demand different responses. This section
    used to render `failedTests` alone, so a run that exited NON-ZERO
    purely on harness errors printed "No failed tests were reported" into
    the tracked baseline, and `harnessErrorTests` /
    `unrecognizedStatusTests` rendered nowhere at all. The split closed a
    hole in the runner and opened the same green-over-red hole one layer
    up, in the artifact a reader actually reads.

    The "nothing to report" sentence is now owed to all three groups
    being empty, so a green sentence can never outrank a red run.

    Split out of `render_report` so this rule can be asserted directly
    rather than through a full inventory build.
    """
    lines: list[str] = ["## Failed Tests", ""]
    if not latest_runner:
        lines.append(
            "No runner summary is available, so failed-test details are "
            "not measured."
        )
        return lines
    rendered_any = False
    for key, caption in FAILURE_SECTION_GROUPS:
        items = latest_runner.get(key) or []
        if not items:
            continue
        rendered_any = True
        lines.append(caption)
        lines.append("")
        rows = []
        for item in items:
            rows.append(
                [
                    item.get("qualified_name", ""),
                    item.get("binary_stem", ""),
                    fmt_ms(item.get("duration_ms")),
                    item.get("status", ""),
                    failure_excerpt(item),
                ]
            )
        lines.extend(
            md_table(["Test", "Binary", "Duration", "Status", "Excerpt"], rows)
        )
        lines.append("")
    if not rendered_any:
        lines.append(
            "No failed tests, harness errors or unrecognized statuses were "
            "reported in the latest runner summary."
        )
    return lines


def split_case_catalog(
    data: dict[str, Any],
    case_catalog_path: Path,
    environment_report_path: Path = DEFAULT_ENVIRONMENT_REPORT,
) -> tuple[dict[str, Any], dict[str, Any]]:
    """Separate the tracked inventory from the build-local case detail.

    Returns ``(tracked, detail)``. The in-memory ``data`` is left untouched
    so callers that need the full structure (the inventory's own tests,
    which assert per-case identity against each binary's ``--list``) keep
    seeing it.

    The tracked half retains everything the suite's gates depend on and that
    is stable across checkout paths: per-source `sourceCaseCount`,
    `staticCaseCount`, `countSource`, `catalogSuiteCount`, the enumerated
    quarantine with reason codes, the classification aggregates and totals.

    The detail half carries the per-case protocol fields — `bodyHash`,
    `group`, `tags`, `threadsRequired`, `xfail`, `deterministic`, `line`,
    `column` and the case names. See DEFAULT_CASE_CATALOG for why that half
    must not be tracked.

    The detail half ALSO carries every measurement that is a property of the
    machine rather than of the tree, because the tracked artifact claims
    byte-level reproducibility and these fields silently broke that claim:

    * ``footprint`` — a ``du`` over ``build/bin``, ``build/test-bin`` and
      ``build/nimcache`` (multi-GiB). It changes on every build, so the
      tracked artifact changed on every build.
    * ``metadata.runtime.environment`` — ``/nix/store/...`` values, absolute
      and per-evaluation. Not under the repo root, so a guard that only
      looked for ``$REPO_ROOT`` never saw them.
    * ``metadata.runtime.host`` — kernel and glibc version, CPU count.
    * ``metadata.runtime.tools`` — git/nim/nix/python versions.
    * ``metadata.runtime.sourceCheckouts`` — absolute sibling checkout paths
      and their working-tree status.

    What survives into the tracked half from that block is the part that is
    a fact about the *inputs* rather than the *host*: each external
    checkout's revision, keyed by name, with no path.
    """
    tracked = dict(data)
    tracked_tests: list[dict[str, Any]] = []
    sources: dict[str, Any] = {}
    for item in data.get("tests", []):
        entry = dict(item)
        cases = entry.pop("catalogCases", None)
        if cases is not None:
            sources[entry["source"]] = {
                "binary": entry.get("binary", ""),
                "caseCount": len(cases),
                "cases": cases,
            }
        tracked_tests.append(entry)
    tracked["tests"] = tracked_tests

    catalog_enumeration = dict(tracked.get("catalogEnumeration", {}))
    if catalog_enumeration:
        catalog_enumeration["caseDetailPath"] = case_catalog_path.as_posix()
        catalog_enumeration["caseDetailTracked"] = False
        catalog_enumeration["caseDetailUntrackedReason"] = (
            "bodyHash is a function of the project's absolute path "
            "(campaign defect #52), so tracking per-case detail would "
            "rewrite every hash per checkout path and defeat byte-level "
            "catalog diffing"
        )
        tracked["catalogEnumeration"] = catalog_enumeration

    # --- host-dependent halves move out of the tracked document ----------
    build_footprint = tracked.pop("footprint", None)
    metadata = dict(tracked.get("metadata", {}))
    runtime = dict(metadata.pop("runtime", {}) or {})
    checkouts = runtime.get("sourceCheckouts", {}) or {}
    metadata["sourceCheckoutRevisions"] = {
        name: {
            "head": entry.get("head", ""),
            "branch": entry.get("branch", ""),
            "dirty": bool(entry.get("dirty", False)),
        }
        for name, entry in sorted(checkouts.items())
    }
    # ``git status --short`` names every dirty path in the checkout that
    # generated the run. This repository is public and this artifact is
    # tracked, so a regeneration from a working tree would publish local
    # scratch filenames verbatim. Only the fact of dirtiness is a property of
    # the run worth recording; the file list is not. Same reduction the
    # sibling checkouts above already get.
    repo_status = metadata.pop("status", "")
    metadata["dirty"] = repo_status not in ("", "unknown")
    metadata["runtimeDetailPath"] = case_catalog_path.as_posix()
    metadata["environmentReportPath"] = environment_report_path.as_posix()
    metadata["runtimeDetailTracked"] = False
    metadata["runtimeDetailReason"] = (
        "footprint, host, tool versions, the recorded environment and the "
        "sibling-checkout paths are properties of the machine and of the "
        "moment, not of the tree; keeping them here made the tracked "
        "artifact differ on every build and every host, which is the defect "
        "spec §16.4 forbids for an embedded build timestamp"
    )
    tracked["metadata"] = metadata

    detail = {
        "schema": CASE_CATALOG_SCHEMA,
        "tracked": False,
        "note": (
            "Build-local artifact. NOT tracked in git: bodyHash depends on "
            "the absolute project path (campaign defect #52), so these "
            "values are comparable only within one fixed checkout path. "
            "Once #52 is fixed this becomes the input to M6 cross-host "
            "catalog diffing. This artifact also holds the host-dependent "
            "measurements (footprint, environment, host, tools, checkout "
            "paths) that must not enter the tracked inventory."
        ),
        "head": data.get("metadata", {}).get("head", ""),
        "sourceFingerprint": data.get("metadata", {}).get(
            "sourceFingerprint", ""
        ),
        "retainedCaseFields": list(CATALOG_CASE_FIELDS),
        "sourceCount": len(sources),
        "caseCount": sum(item["caseCount"] for item in sources.values()),
        "sources": sources,
        "runtime": runtime,
        "footprint": build_footprint,
    }
    # Enforced by construction, not by remembering: whatever any future
    # field carries, the tracked half leaves with no absolute path in it.
    tracked = redact_absolute_paths_deep(tracked)
    return tracked, detail


def render_catalog_enumeration(data: dict[str, Any]) -> list[str]:
    """Render the case-enumeration provenance and the quarantine list.

    The quarantine is enumerated in full, never summarized to a number: it is
    the mechanism by which a binary that cannot enumerate stays visible and
    shrinkable instead of silently contributing a zero or an unlabelled
    static count.
    """
    catalog = data.get("catalogEnumeration")
    lines: list[str] = ["## Case Enumeration Provenance", ""]
    if not catalog:
        lines.extend(["Not recorded in this inventory.", ""])
        return lines

    if not catalog.get("enabled", True):
        lines.append(
            "Catalog enumeration was DISABLED for this run (`--no-catalog`); "
            "every count below comes from the static source scan."
        )
        lines.append("")

    counts = catalog.get("countSourceCounts", {})
    lines.append(
        "Case counts come from each built binary's `--list-json` catalog "
        "(spec §3.2/§6.5). The static source scan is a labelled fallback only: "
        "it sums every `when`/`else` branch and cannot see cases declared "
        "through wrapper templates."
    )
    lines.append("")
    lines.extend(
        md_table(
            ["Count source", "Test entries", "Meaning"],
            [
                [
                    "catalog",
                    str(counts.get("catalog", 0)),
                    "authoritative: enumerated from the built binary",
                ],
                [
                    "static",
                    str(counts.get("static", 0)),
                    "Python file, or probing disabled; counted by source scan",
                ],
                [
                    "missing-binary",
                    str(counts.get("missing-binary", 0)),
                    "Nim source with no built binary; counted by source scan",
                ],
                [
                    "quarantined",
                    str(counts.get("quarantined", 0)),
                    "binary exists but could not enumerate; contributes 0 "
                    "cases to the total",
                ],
            ],
        )
    )
    lines.append("")
    lines.append(
        "Retained per-case protocol fields: "
        + ", ".join(f"`{field}`" for field in catalog.get("retainedCaseFields", []))
        + "."
    )
    lines.append("")
    if catalog.get("caseDetailPath"):
        lines.append(
            f"Per-case detail is written to `{catalog['caseDetailPath']}`, "
            "which is build-local and **deliberately untracked**: "
            + catalog.get("caseDetailUntrackedReason", "")
            + ". This report and the tracked inventory keep only "
            "path-stable counts."
        )
        lines.append("")

    if catalog.get("environmentDegraded"):
        lines.append("> [!WARNING]")
        lines.append("> " + catalog.get("environmentNote", ""))
        lines.append("")

    quarantine = catalog.get("quarantine", [])
    lines.append(f"### Quarantined binaries ({len(quarantine)})")
    lines.append("")
    if not quarantine:
        lines.append("None: every built test binary enumerated its cases.")
        lines.append("")
        return lines
    lines.append(
        "A quarantined binary contributes **0** cases to the authoritative "
        "total. Its static scan is shown for visibility only: substituting "
        "it is exactly the `when`/`else` over-count that made the binary the "
        "enumeration authority in the first place."
    )
    lines.append("")
    lines.extend(
        md_table(
            ["Source", "Reason", "Static count (excluded)", "Detail"],
            [
                [
                    f"`{item['source']}`",
                    f"`{item['reason']}`",
                    str(item["staticCaseCount"]),
                    (item.get("detail") or "").replace("|", "\\|")[:120],
                ]
                for item in quarantine
            ],
        )
    )
    lines.append("")
    lines.append("Reason codes:")
    lines.append("")
    for reason in sorted(catalog.get("quarantineReasonCounts", {})):
        lines.append(
            f"- `{reason}` ({catalog['quarantineReasonCounts'][reason]}): "
            + QUARANTINE_REASON_DESCRIPTIONS.get(reason, "unclassified")
        )
    lines.append("")
    return lines


def render_environment_report(
    data: dict[str, Any], build_local: dict[str, Any] | None = None
) -> str:
    """The human-readable measurement environment — BUILD-LOCAL, untracked.

    Everything the tracked baseline report used to carry and could not keep
    stable: the recorded environment (absolute ``/nix/store`` values), the
    host's kernel and glibc version, the tool versions, the sibling
    checkout paths, and a ``du`` over ``build/`` — 5.5 GiB of nimcache that
    changes on every build.

    The information is not lost, it is relocated. A reader who wants to
    know which machine produced a measurement reads this file; a reader
    diffing two checkouts byte-for-byte reads the tracked one.
    """
    metadata = data.get("metadata", {})
    runtime = (build_local or {}).get("runtime") or metadata.get("runtime") or {}
    foot = (build_local or {}).get("footprint")
    if foot is None:
        foot = data.get("footprint") or {"entries": []}

    lines: list[str] = ["# Reprobuild Suite M0 — Measurement Environment", ""]
    lines.append(
        "Generated by `scripts/reprobuild_suite_inventory.py` alongside "
        f"`{DEFAULT_REPORT.as_posix()}`."
    )
    lines.append("")
    lines.append("> [!NOTE]")
    lines.append(
        "> This file is **build-local and untracked**. Every value below is "
        "a property of the machine or of the moment — absolute store paths, "
        "a kernel and glibc version, tool versions, and a `du` over a "
        "multi-GiB nimcache — so keeping it in git would rewrite the "
        "artifact on every build and every host. Spec §16.4 forbids an "
        "embedded build timestamp for exactly that reason; these fields are "
        "the same defect wearing different clothes."
    )
    lines.append("")
    lines.append("## Tree")
    lines.append("")
    lines.extend(
        md_table(
            ["Field", "Value"],
            [
                ["HEAD", metadata.get("head", "")],
                ["Branch", metadata.get("branch", "") or "(detached)"],
                ["Source fingerprint", metadata.get("sourceFingerprint", "")],
            ],
        )
    )
    lines.append("")
    lines.append("## Host")
    lines.append("")
    host = runtime.get("host", {})
    lines.extend(
        md_table(
            ["Field", "Value"],
            [[key, str(host[key])] for key in sorted(host)]
            or [["(not recorded)", ""]],
        )
    )
    lines.append("")
    lines.append("## Tool versions")
    lines.append("")
    tools = runtime.get("tools", {})
    lines.extend(
        md_table(
            ["Tool", "Version"],
            [[key, str(tools[key])] for key in sorted(tools)]
            or [["(not recorded)", ""]],
        )
    )
    lines.append("")
    lines.append("## Recorded environment")
    lines.append("")
    environment = runtime.get("environment", {})
    lines.extend(
        md_table(
            ["Variable", "Value"],
            [[key, str(environment[key])] for key in sorted(environment)]
            or [["(none recorded)", ""]],
        )
    )
    lines.append("")
    lines.append("## External source checkouts")
    lines.append("")
    checkouts = runtime.get("sourceCheckouts", {})
    if not checkouts:
        lines.append("No external source checkouts were recorded.")
    else:
        lines.extend(
            md_table(
                ["Name", "Path", "HEAD", "Branch", "Dirty"],
                [
                    [
                        name,
                        str(entry.get("path", "")),
                        str(entry.get("head", "")),
                        str(entry.get("branch", "")),
                        str(entry.get("dirty", "")),
                    ]
                    for name, entry in sorted(checkouts.items())
                ],
            )
        )
    lines.append("")
    lines.append("## Build artifact footprint")
    lines.append("")
    foot_rows = []
    for entry in foot.get("entries", []):
        kib = entry["kib"]
        mib = "not present" if kib is None else f"{kib / 1024.0:.1f} MiB"
        exe = (
            "n/a"
            if entry["executableFiles"] is None
            else str(entry["executableFiles"])
        )
        foot_rows.append([entry["path"], mib, exe])
    lines.extend(
        md_table(["Path", "Size", "Executable files"], foot_rows)
        if foot_rows
        else ["(not measured)"]
    )
    lines.append("")
    return "\n".join(lines)


def render_report(
    data: dict[str, Any],
    json_path: str,
    build_local: dict[str, Any] | None = None,
) -> str:
    static = data["static"]
    metadata = data["metadata"]
    environment_report = (
        metadata.get("environmentReportPath")
        or DEFAULT_ENVIRONMENT_REPORT.as_posix()
    )
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
                ["HEAD", metadata["head"]],
                ["HEAD short", metadata["headShort"]],
                ["Branch", metadata["branch"] or "(detached)"],
                ["Source fingerprint", metadata["sourceFingerprint"]],
                [
                    "External source revisions",
                    json.dumps(
                        metadata.get("sourceCheckoutRevisions", {}),
                        sort_keys=True,
                    ),
                ],
                ["Inventory JSON", json_path],
                [
                    "Per-case protocol detail",
                    metadata.get("runtimeDetailPath")
                    or DEFAULT_CASE_CATALOG.as_posix(),
                ],
                ["Measurement environment", environment_report],
            ],
        )
    )
    lines.append("")
    # The host block is deliberately absent from this table. `Runtime env`
    # (absolute /nix/store values), `Host` (kernel + glibc version, CPU
    # count) and `Tool versions` are properties of the machine, and this
    # report is TRACKED: a `du` over a 5.5 GiB nimcache or a kernel bump
    # rewrote it on every regeneration, which is precisely the byte-level
    # comparability spec §16.4 protects when it forbids an embedded
    # `compiled_at`. They are rendered in full in the build-local report
    # named above.
    lines.append(
        "The measurement environment — host kernel and glibc, tool "
        "versions, the recorded environment variables, the sibling "
        f"checkout paths and the build-artifact footprint — is in "
        f"`{environment_report}`. It is build-local and **deliberately "
        "untracked**: every one of those values changes per host or per "
        "build, so carrying them here would rewrite this tracked report "
        "each time it is regenerated even when nothing about the suite "
        "changed."
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
                ["Case count (catalog-authoritative)", str(static["sourceCaseCount"])],
                ["Measured protocol-aware cases", protocol_text],
                ["Graph-owned helper/fixture artifacts", str(len(graph_artifacts))],
                [
                    "Tests with statically detected runtime compiler flows",
                    str(len(data["staticallyDetectedRuntimeCompilerFlows"])),
                ],
                ["Pure-unit consolidation groups", str(len(data["pureUnitConsolidationCandidates"]))],
            ],
        )
    )
    lines.append("")
    lines.extend(render_catalog_enumeration(data))
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
        f"and {facts['staticallyDetectedRuntimeCompilerFlowTests']} tests with "
        "statically detected runtime compiler flows. These are structural counts, "
        "not timing results or an exhaustive semantic proof."
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
    lines.extend(render_failed_tests_section(latest_runner))
    lines.append("")
    lines.append("## Build Artifact Footprint")
    lines.append("")
    # Which paths are measured is a property of this script and is stable.
    # How large they are is a property of the last build — `build/nimcache`
    # alone is multi-GiB and moves every time anything is compiled — so the
    # sizes live in the build-local environment report.
    lines.append(
        "The following paths are measured on every run: "
        + ", ".join(f"`{item}`" for item in FOOTPRINT_PATHS)
        + ". Their measured sizes and executable-file counts change on "
        "every build and are therefore recorded in "
        f"`{environment_report}`, not here."
    )
    lines.append("")
    lines.append("## Classification")
    lines.append("")
    class_rows = [[name, str(count)] for name, count in sorted(static["classificationCounts"].items())]
    lines.extend(md_table(["Class", "Count"], class_rows))
    lines.append("")
    lines.append("Every test entry and its class is recorded in the JSON inventory.")
    lines.append("")
    lines.append("## Statically Detected Runtime Compiler Flows")
    lines.append("")
    detection = data["runtimeCompilerFlowDetection"]
    lines.append(
        "This static audit combines explicit compiler-command data flow with "
        "trusted Reprobuild compilation-API imports and reachable local wrapper "
        "calls. It is intentionally not exhaustive: "
        + " ".join(detection["limitations"])
    )
    lines.append("")
    if not data["staticallyDetectedRuntimeCompilerFlows"]:
        lines.append(
            "No runtime compiler flows were statically detected in current test bodies."
        )
    else:
        rows = []
        for item in data["staticallyDetectedRuntimeCompilerFlows"]:
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
        lines.extend(
            md_table(
                ["Source", "Class", "Line", "Detector", "First matching flow"],
                rows,
            )
        )
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
    # The rendered markdown is tracked alongside the JSON and is held to the
    # same property. The un-redacted values remain in the build-local
    # artifact named in the "Detail" row above.
    return redact_absolute_paths("\n".join(lines))


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo-root", default=".", help="repository root")
    parser.add_argument("--json", default=str(DEFAULT_JSON), help="JSON inventory output path")
    parser.add_argument("--write-report", default=str(DEFAULT_REPORT), help="markdown report output path")
    parser.add_argument("--run-suite", action="store_true", help="run scripts/run_tests.sh before generating the report")
    parser.add_argument("--warm-runs", type=int, default=0, help="number of warm suite runs after the cold run")
    parser.add_argument("--clean-first", action="store_true", help="remove repo-local build outputs before the cold run")
    parser.add_argument(
        "--suite-timeout-seconds",
        type=int,
        default=0,
        help="per-suite-run wall timeout; 0 means no timeout",
    )
    parser.add_argument(
        "--case-catalog",
        default=str(DEFAULT_CASE_CATALOG),
        help=(
            "build-local per-case protocol detail output path; deliberately "
            "untracked (see DEFAULT_CASE_CATALOG / campaign defect #52)"
        ),
    )
    parser.add_argument(
        "--environment-report",
        default=str(DEFAULT_ENVIRONMENT_REPORT),
        help=(
            "build-local human-readable measurement-environment report "
            "(host, tool versions, recorded environment, footprint); "
            "deliberately untracked because every value in it changes per "
            "host or per build"
        ),
    )
    parser.add_argument(
        "--no-catalog",
        action="store_true",
        help=(
            "skip the built-binary --list-json probe and count every Nim case "
            "with the static source scan (diagnostic only: the static scan "
            "mis-counts when/else branches and wrapper templates)"
        ),
    )
    parser.add_argument(
        "--no-cache",
        action="store_true",
        help=(
            "re-probe every test binary instead of reusing "
            "build/reprobuild-suite-catalog-cache.json; the catalog is still "
            "used (unlike --no-catalog), it is just measured fresh"
        ),
    )
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    root = Path(args.repo_root).resolve()
    json_path = Path(args.json)
    report_path = Path(args.write_report)
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

    try:
        data = build_inventory(
            root,
            run_data,
            use_catalog=not args.no_catalog,
            use_catalog_cache=not args.no_cache,
        )
    except CatalogEnvironmentError as exc:
        print(f"reprobuild_suite_inventory: ENVIRONMENT ERROR: {exc}", file=sys.stderr)
        return 2

    case_catalog_path = Path(args.case_catalog)
    if not case_catalog_path.is_absolute():
        case_catalog_path = root / case_catalog_path
    environment_report_path = Path(args.environment_report)
    if not environment_report_path.is_absolute():
        environment_report_path = root / environment_report_path
    # Always record the ROOT-RELATIVE path. The raw argument used to be
    # written straight into the tracked artifact, so `--case-catalog
    # /abs/path` leaked one developer's directory into a file whose whole
    # purpose is to be identical for everyone. Same for the environment
    # report's pointer.
    tracked, case_detail = split_case_catalog(
        data,
        Path(rel(case_catalog_path, root)),
        Path(rel(environment_report_path, root)),
    )

    json_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.parent.mkdir(parents=True, exist_ok=True)
    case_catalog_path.parent.mkdir(parents=True, exist_ok=True)
    environment_report_path.parent.mkdir(parents=True, exist_ok=True)
    json_path.write_text(json.dumps(tracked, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    case_catalog_path.write_text(
        json.dumps(case_detail, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    report_path.write_text(
        render_report(tracked, rel(json_path, root), case_detail),
        encoding="utf-8",
    )
    environment_report_path.write_text(
        render_environment_report(data, case_detail), encoding="utf-8"
    )

    print(f"wrote {rel(json_path, root)}")
    print(f"wrote {rel(case_catalog_path, root)} (build-local, untracked)")
    print(f"wrote {rel(report_path, root)}")
    print(
        f"wrote {rel(environment_report_path, root)} (build-local, untracked)"
    )

    if args.run_suite:
        failed = [run for run in data["timing"]["runs"] if run.get("exitCode") != 0]
        return 1 if failed else 0
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
