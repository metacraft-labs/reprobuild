## Mode 3 Python dependency scanner.
##
## Walks a Python workspace and emits a deterministic dep graph naming
## **only** the inter-workspace package edges proved by ``import X`` /
## ``from X import Y`` statements in each member's ``.py`` sources.
## Mirror of the Nim, C/C++, Rust, and Go scanners in
## ``./nim_dep_scanner.nim`` / ``./cpp_dep_scanner.nim`` /
## ``./rust_dep_scanner.nim`` / ``./go_dep_scanner.nim`` per
## ``reprobuild-specs/Three-Mode-Convention-System.md`` §"The scanner
## contract" — same shapes, same determinism guarantee — but parsing
## Python source instead.
##
## Scope of this milestone (M32, Mode 3 Python pilot):
##   * Recognise Python ``executable`` / ``library`` members declared
##     in a workspace's ``repro.nim`` / ``reprobuild.nim`` files.
##     Detection piggy-backs on layout: a member is Python iff
##     ``<projectRoot>/<member>/<member>/__init__.py`` (Layout B) OR
##     ``<projectRoot>/<member>/src/<member>/__init__.py`` (Layout B
##     with ``src/``) OR ``<projectRoot>/src/<member>/__init__.py``
##     (Layout A) exists. Members whose layout doesn't match are
##     silently skipped.
##   * For each member, walk its package directory recursively for
##     ``.py`` files (excluding ``__pycache__`` directories).
##   * Parse ``import X`` / ``from X import Y`` statements. Both
##     single-form and grouped-form ``from X import (a, b)`` are
##     supported. The first segment of the dotted module path (e.g.
##     ``mathlib`` from ``mathlib.submod``) is resolved against the set
##     of in-workspace Python members.
##   * Stdlib imports are filtered via a static list
##     (``PythonStdlibModules``). Any top-level import whose head is on
##     that list (``sys``, ``os``, ``json``, ``typing``, etc.) is
##     dropped without producing an edge.
##   * Third-party imports — anything whose head is neither stdlib nor
##     an in-workspace member — are silently dropped. Mode 3 Python is
##     in-workspace only; users with PyPI deps write a
##     ``pyproject.toml`` and let the Mode 2 path drive the build.
##   * Emit edges sorted by ``(fromPackage, toPackage, evidence)`` so
##     the output is byte-deterministic across runs and hosts.
##
## Out of scope (documented as outstanding, deferred):
##   * Dynamic imports (``importlib.import_module``, ``__import__``) —
##     scanner-invisible by design. Per spec §"Manual override" the
##     user adds explicit ``depends_on`` edges to wire those.
##   * Relative imports (``from . import sibling``, ``from .. import
##     parent``) are intra-package paths and never produce a workspace
##     edge.
##   * PEP 420 namespace packages (no ``__init__.py``) are NOT
##     supported by member discovery; require ``__init__.py``.
##   * ``if TYPE_CHECKING:`` blocks and conditional imports — the
##     scanner reads them as if always taken. Edges that only manifest
##     under a particular runtime condition are over-emitted on the
##     conservative side.
##   * Native extensions (``.pyd`` / ``.so``) — Mode 2 territory
##     (maturin / scikit-build-core).
##
## The scanner shares the ``WorkspaceMember`` / ``DepEdge`` /
## ``ScanResult`` types with ``./nim_dep_scanner.nim`` so the
## ``repro deps refresh`` driver can merge the Nim, C/C++, Rust, Go,
## and Python passes' output into a single ``repro.scanned-deps.nim``.

import std/[algorithm, os, strutils, tables]

import ./nim_dep_scanner
import ./paths
import ./project_file

const
  PythonSourceExtension* = ".py"
    ## The single file extension the scanner treats as a Python source
    ## file. ``.pyi`` stub files and ``.pyx`` Cython sources are NOT
    ## walked — stubs are type-checker hints with no runtime imports,
    ## and Cython is Mode 2 territory.

# ----------------------------------------------------------------------
# Member discovery — read project files and pull out executable/library
# declarations whose source layout looks like Python (an importable
# package directory with ``__init__.py``). Members whose layout doesn't
# match are skipped; a Nim-only repo therefore produces zero Python
# members and the scanner falls back to a no-op.
# ----------------------------------------------------------------------

proc extractPythonMembersFromProjectFile(projectFile: string):
    seq[tuple[package: string; kind: string; name: string]] =
  ## Mirror of ``nim_dep_scanner.extractMembersFromProjectFile`` /
  ## ``go_dep_scanner.extractGoMembersFromProjectFile``. The text scan
  ## itself is identical to the other scanners'; we return raw
  ## declarations without filtering and the caller filters by layout.
  if not fileExists(extendedPath(projectFile)):
    return @[]
  let raw =
    try:
      readFile(extendedPath(projectFile))
    except CatchableError:
      return @[]
  var pkg = ""
  for rawLine in raw.splitLines():
    var line = rawLine
    let commentIdx = line.find('#')
    if commentIdx >= 0:
      line = line[0 ..< commentIdx]
    let stripped = line.strip()
    if stripped.startsWith("package "):
      var name = ""
      for ch in stripped[len("package ") .. ^1]:
        if ch in {' ', '\t', ':', ','}:
          break
        name.add(ch)
      if name.len > 0:
        pkg = name
      continue
    if pkg.len == 0:
      continue
    if stripped.startsWith("executable"):
      let rest =
        if stripped.len > len("executable") and
            stripped[len("executable")] in {' ', '\t'}:
          stripped[len("executable") .. ^1].strip()
        else:
          ""
      if rest.len == 0:
        continue
      var name = ""
      for ch in rest:
        if ch in {' ', '\t', ':', ','}:
          break
        name.add(ch)
      if name.len > 0:
        result.add((package: pkg, kind: "executable", name: name))
      continue
    if stripped.startsWith("library"):
      let rest =
        if stripped.len > len("library") and
            stripped[len("library")] in {' ', '\t'}:
          stripped[len("library") .. ^1].strip()
        else:
          ""
      if rest.len == 0:
        continue
      var name = ""
      for ch in rest:
        if ch in {' ', '\t', ':', ','}:
          break
        name.add(ch)
      if name.len > 0:
        result.add((package: pkg, kind: "library", name: name))

proc isPythonSourceFile*(path: string): bool =
  ## True when ``path``'s extension is ``.py``.
  path.toLowerAscii.endsWith(PythonSourceExtension)

proc dirHasPythonPackage(dir: string): bool =
  ## True when ``dir`` is an importable Python package (contains
  ## ``__init__.py``). Used as the layout filter for member discovery.
  fileExists(extendedPath(dir / "__init__.py"))

proc resolvePythonMemberDirs*(projectRoot, memberName: string):
    tuple[pkgDir: string; entrySource: string] =
  ## Resolve a single member's package directory + entry-point source
  ## file under a project root. ``pkgDir`` is the directory holding
  ## ``__init__.py``; ``entrySource`` is ``__init__.py`` itself.
  ##
  ## Supports the canonical Mode 3 Python layout shapes:
  ##
  ##   Layout B-flat — multiple packages per project file (canonical
  ##                   Mode 3 multi-package shape):
  ##     <projectRoot>/<memberName>/<memberName>/__init__.py
  ##
  ##   Layout B-src  — per-member ``src/`` (matches Python's src-layout
  ##                   convention for Mode 2 + Mode 3):
  ##     <projectRoot>/<memberName>/src/<memberName>/__init__.py
  ##
  ##   Layout A      — single-package project file:
  ##     <projectRoot>/src/<memberName>/__init__.py
  ##     <projectRoot>/<memberName>/__init__.py
  ##
  ## The most specific (multi-package) layouts are tried FIRST so the
  ## ambient ``src/`` directory of a Layout B-src project doesn't
  ## accidentally match a Layout A probe. Returns empty strings on both
  ## fields when no layout matches.
  let flatPkg = projectRoot / memberName / memberName
  if dirHasPythonPackage(flatPkg):
    result.pkgDir = flatPkg
    result.entrySource = flatPkg / "__init__.py"
    return

  let srcPkg = projectRoot / memberName / "src" / memberName
  if dirHasPythonPackage(srcPkg):
    result.pkgDir = srcPkg
    result.entrySource = srcPkg / "__init__.py"
    return

  let topSrcPkg = projectRoot / "src" / memberName
  if dirHasPythonPackage(topSrcPkg):
    result.pkgDir = topSrcPkg
    result.entrySource = topSrcPkg / "__init__.py"
    return

  let topPkg = projectRoot / memberName
  if dirHasPythonPackage(topPkg):
    result.pkgDir = topPkg
    result.entrySource = topPkg / "__init__.py"
    return

proc discoverPythonMembers*(workspaceRoot: string): seq[WorkspaceMember] =
  ## Walk ``workspaceRoot`` for every project file and produce one
  ## ``WorkspaceMember`` per ``executable`` / ``library`` declared in
  ## a ``package`` block whose layout matches one of the canonical
  ## Mode 3 Python shapes (see ``resolvePythonMemberDirs``). Members
  ## whose layout doesn't match are silently skipped — they belong to
  ## another language's scanner.
  ##
  ## The walk skips ``.repro/``, ``.git/``, ``node_modules/``,
  ## ``.nimcache/``, ``.cargo/``, ``target/``, and ``__pycache__/`` —
  ## same as the Nim/C/C++/Rust/Go scanners — so a build's
  ## intermediates never pollute the member set.
  if not dirExists(extendedPath(workspaceRoot)):
    return @[]
  var queue: seq[string] = @[workspaceRoot]
  while queue.len > 0:
    let dir = queue[0]
    queue.delete(0)
    let match = resolveProjectFile(dir)
    if match.path.len > 0:
      for decl in extractPythonMembersFromProjectFile(match.path):
        let resolved = resolvePythonMemberDirs(dir, decl.name)
        if resolved.pkgDir.len == 0:
          continue
        result.add(WorkspaceMember(
          package: decl.package,
          member: decl.name,
          projectFile: match.path,
          projectRoot: dir,
          sourceFile: resolved.entrySource))
    try:
      for kind, entry in walkDir(dir):
        if kind != pcDir:
          continue
        let basename = extractFilename(entry)
        if basename in [".repro", ".git", "node_modules", ".nimcache",
            ".cargo", "target", "__pycache__"]:
          continue
        queue.add(entry)
    except OSError:
      discard
  result.sort(proc (a, b: WorkspaceMember): int =
    cmp((a.package, a.member), (b.package, b.member)))

# ----------------------------------------------------------------------
# Import extraction. The scanner is intentionally NOT a Python parser:
# building one would dwarf the milestone. The line-scan below extracts
# every recognised ``import`` / ``from ... import ...`` statement.
#
# Python's import shapes the scanner handles:
#   * ``import foo``
#   * ``import foo.bar``
#   * ``import foo as f``
#   * ``import foo, bar``                  (comma-separated)
#   * ``from foo import bar``
#   * ``from foo.baz import bar``
#   * ``from foo import (a, b, c)``        (grouped, single-line)
#   * ``from foo import (``                (grouped, multi-line)
#         ``    a,``
#         ``    b,``
#     ``)``
#   * ``from foo import *``
#
# Relative imports (``from . import sibling``, ``from .. import x``)
# are emitted with the literal head ``""`` (empty) so the caller's
# resolution layer can drop them — they're intra-package paths and
# never produce a workspace edge.
# ----------------------------------------------------------------------

type
  PythonImportRef* = object
    ## One module path extracted from a Python source file.
    head*: string
      ## The first dotted segment. For ``import foo.bar`` the head is
      ## ``foo``; for ``from foo.baz import bar`` the head is also
      ## ``foo``. Relative imports (``from . import sibling``) yield
      ## the empty head so the resolver drops them at the filter step.
    lineNumber*: int
      ## 1-based line number where the import was found.
    raw*: string
      ## The stripped source line for the evidence string.

proc stripPythonLineComment(line: string): string =
  ## Drop everything after the first ``#`` that isn't inside a string
  ## literal. Triple-quoted strings are NOT tracked — they're typically
  ## docstrings far from the import region of real codebases, and the
  ## cost of a stateful scanner would dwarf the rest of the milestone.
  ## A rogue comment-wrapped import would produce at most a spurious
  ## edge that the user can suppress via manual override per spec
  ## §"Manual override".
  var inString = false
  var stringChar = '\0'
  var i = 0
  while i < line.len:
    let ch = line[i]
    if not inString:
      if ch == '#':
        return line[0 ..< i]
      if ch == '"' or ch == '\'':
        inString = true
        stringChar = ch
    else:
      if ch == '\\' and i + 1 < line.len:
        # Skip the escaped char so an escaped quote inside a string
        # literal doesn't close the string.
        inc i
      elif ch == stringChar:
        inString = false
    inc i
  line

proc extractDottedHead(token: string): string =
  ## Return the first segment of a dotted module path (e.g. ``foo``
  ## for ``foo.bar.baz``). Stops at the first non-identifier character.
  ## Returns empty string when ``token`` is empty or starts with a dot
  ## (relative import — handled separately by the caller).
  var head = ""
  for ch in token:
    if ch in {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '_'}:
      head.add(ch)
    else:
      break
  head

proc extractPythonImportRefs*(sourceText: string): seq[PythonImportRef] =
  ## Walk ``sourceText`` line-by-line and emit every recognised
  ## ``import`` / ``from ... import ...`` statement. Handles all the
  ## shapes documented above, including multi-line grouped imports
  ## (the scanner tracks parenthesis depth across newlines so a
  ## ``from foo import (`` block is fully consumed before the next
  ## logical statement begins).
  var lineNo = 0
  var continuationActive = false
  var parenDepth = 0
  for rawLine in sourceText.splitLines():
    inc lineNo
    let cleaned = stripPythonLineComment(rawLine)
    let stripped = cleaned.strip()
    if continuationActive:
      # We're inside a multi-line grouped import — the head was
      # already emitted on the first line; just track paren depth so
      # we know when we exit the block.
      for ch in stripped:
        if ch == '(':
          inc parenDepth
        elif ch == ')':
          dec parenDepth
      if parenDepth <= 0:
        continuationActive = false
        parenDepth = 0
      continue
    if stripped.len == 0:
      continue
    if stripped.startsWith("from "):
      # ``from <module> import ...``
      let rest = stripped[len("from ") .. ^1].strip()
      if rest.len == 0:
        continue
      # Find the ``import`` keyword.
      let importIdx = rest.find(" import")
      if importIdx < 0:
        continue
      let moduleText = rest[0 ..< importIdx].strip()
      let importTail = rest[importIdx + len(" import") .. ^1]
      if moduleText.len == 0:
        continue
      # Relative imports (``from . import sibling``, ``from ..pkg
      # import x``) start with one or more dots. We emit an empty
      # head so the caller's filter drops them.
      if moduleText.startsWith("."):
        result.add(PythonImportRef(
          head: "",
          lineNumber: lineNo,
          raw: stripped))
      else:
        let head = extractDottedHead(moduleText)
        if head.len > 0:
          result.add(PythonImportRef(
            head: head,
            lineNumber: lineNo,
            raw: stripped))
      # If the tail starts with ``(`` and the closing ``)`` is NOT on
      # the same line, we enter continuation mode so subsequent lines'
      # ``import``-like prefixes don't accidentally match.
      let tailStripped = importTail.strip()
      if tailStripped.startsWith("("):
        # Count parens on this line.
        var depth = 0
        for ch in tailStripped:
          if ch == '(':
            inc depth
          elif ch == ')':
            dec depth
        if depth > 0:
          continuationActive = true
          parenDepth = depth
      continue
    if stripped.startsWith("import "):
      let rest = stripped[len("import ") .. ^1].strip()
      if rest.len == 0:
        continue
      # ``import foo, bar`` — split on commas, each piece may have an
      # ``as`` alias.
      for piece in rest.split(','):
        var work = piece.strip()
        # Drop trailing ``as <alias>``.
        let asIdx = work.find(" as ")
        if asIdx >= 0:
          work = work[0 ..< asIdx].strip()
        if work.len == 0:
          continue
        let head = extractDottedHead(work)
        if head.len == 0:
          continue
        result.add(PythonImportRef(
          head: head,
          lineNumber: lineNo,
          raw: stripped))
      continue

# ----------------------------------------------------------------------
# Stdlib filter. Python's standard library is reachable via a top-level
# module name that the interpreter ships with. We use a static list
# generated from the CPython 3.12 ``sys.stdlib_module_names`` snapshot;
# it's belt-and-suspenders versus the "everything not in-workspace is
# external" heuristic that drops imports past the workspace lookup
# table.
#
# We also include the common builtin / pseudo modules (``__future__``,
# ``builtins``, ``typing``) that ``stdlib_module_names`` may or may not
# enumerate depending on the Python version. Better to over-filter than
# to emit a spurious workspace edge.
# ----------------------------------------------------------------------

const PythonStdlibModules* = [
  "__future__", "_thread", "abc", "aifc", "antigravity", "argparse",
  "array", "ast", "asynchat", "asyncio", "asyncore", "atexit",
  "audioop", "base64", "bdb", "binascii", "bisect", "builtins",
  "bz2", "cProfile", "calendar", "cgi", "cgitb", "chunk", "cmath",
  "cmd", "code", "codecs", "codeop", "collections", "colorsys",
  "compileall", "concurrent", "configparser", "contextlib",
  "contextvars", "copy", "copyreg", "crypt", "csv", "ctypes",
  "curses", "dataclasses", "datetime", "dbm", "decimal", "difflib",
  "dis", "distutils", "doctest", "email", "encodings", "ensurepip",
  "enum", "errno", "faulthandler", "fcntl", "filecmp", "fileinput",
  "fnmatch", "fractions", "ftplib", "functools", "gc", "genericpath",
  "getopt", "getpass", "gettext", "glob", "graphlib", "grp", "gzip",
  "hashlib", "heapq", "hmac", "html", "http", "idlelib", "imaplib",
  "imghdr", "imp", "importlib", "inspect", "io", "ipaddress",
  "itertools", "json", "keyword", "lib2to3", "linecache", "locale",
  "logging", "lzma", "mailbox", "mailcap", "marshal", "math",
  "mimetypes", "mmap", "modulefinder", "msilib", "msvcrt",
  "multiprocessing", "netrc", "nis", "nntplib", "ntpath", "numbers",
  "opcode", "operator", "optparse", "os", "ossaudiodev", "pathlib",
  "pdb", "pickle", "pickletools", "pipes", "pkgutil", "platform",
  "plistlib", "poplib", "posix", "posixpath", "pprint", "profile",
  "pstats", "pty", "pwd", "py_compile", "pyclbr", "pydoc",
  "pydoc_data", "pyexpat", "queue", "quopri", "random", "re",
  "readline", "reprlib", "resource", "rlcompleter", "runpy",
  "sched", "secrets", "select", "selectors", "shelve", "shlex",
  "shutil", "signal", "site", "smtpd", "smtplib", "sndhdr", "socket",
  "socketserver", "spwd", "sqlite3", "sre_compile", "sre_constants",
  "sre_parse", "ssl", "stat", "statistics", "string", "stringprep",
  "struct", "subprocess", "sunau", "symtable", "sys", "sysconfig",
  "syslog", "tabnanny", "tarfile", "telnetlib", "tempfile",
  "termios", "test", "textwrap", "threading", "time", "timeit",
  "tkinter", "token", "tokenize", "tomllib", "trace", "traceback",
  "tracemalloc", "tty", "turtle", "turtledemo", "types", "typing",
  "unicodedata", "unittest", "urllib", "uu", "uuid", "venv",
  "warnings", "wave", "weakref", "webbrowser", "winreg", "winsound",
  "wsgiref", "xdrlib", "xml", "xmlrpc", "zipapp", "zipfile",
  "zipimport", "zlib", "zoneinfo",
]
  ## The static stdlib list. Python adds a handful of modules per
  ## release (``tomllib`` arrived in 3.11; ``zoneinfo`` in 3.9);
  ## entries here cover 3.8 through 3.13. Anything missing from this
  ## list falls through to the workspace-member lookup; a hit there
  ## means a workspace edge, a miss means a silent drop (third-party).

proc isPythonStdlibModule*(head: string): bool =
  ## True when ``head`` belongs to Python's standard distribution and
  ## should be ignored. Comparison is case-sensitive (Python's module
  ## names are case-sensitive on all platforms).
  for entry in PythonStdlibModules:
    if entry == head:
      return true
  false

# ----------------------------------------------------------------------
# Member-name normalisation. Python identifiers disallow ``-`` so a
# member declared as ``my-pkg`` in ``repro.nim`` would not be a legal
# package name anyway. The scanner keeps the names verbatim and matches
# case-sensitively (Python module names are case-sensitive).
# ----------------------------------------------------------------------

proc normalisePythonPackageName*(text: string): string =
  ## Identity for now (kept as a hook for future normalisation rules
  ## if any Mode 3 fixture warrants them). Mirror of the Go scanner's
  ## ``normaliseGoPackageName``.
  text

# ----------------------------------------------------------------------
# Source collection. For each member we walk every ``.py`` file under
# its package directory; the scanner is conservative on the include
# side (every file's imports count).
# ----------------------------------------------------------------------

proc collectScanSources(member: WorkspaceMember): seq[string] =
  ## Every ``.py`` file under the member's package dir, recursively.
  ## ``member.sourceFile`` already points at the package's
  ## ``__init__.py``; we walk its parent directory.
  if member.sourceFile.len == 0:
    return @[]
  let pkgDir = member.sourceFile.parentDir
  if not dirExists(extendedPath(pkgDir)):
    return @[]
  for path in walkDirRec(pkgDir):
    let normalised = path.replace('\\', '/')
    if "/__pycache__/" in normalised:
      continue
    if isPythonSourceFile(path):
      result.add(path)
  result.sort(system.cmp[string])

proc relativeEvidence(workspaceRoot, sourceFile: string;
                      line: int; raw: string): string =
  var rel =
    try:
      relativePath(sourceFile, workspaceRoot)
    except OSError:
      sourceFile
  rel = rel.replace('\\', '/')
  rel & ":" & $line & ": " & raw

proc scanWorkspacePython*(workspaceRoot: string): ScanResult =
  ## Top-level Python scanner entry point. Discovers members, builds
  ## the ``<package-name> → <package>`` index, walks each member's
  ## sources, resolves ``import`` heads, emits a sorted edge list.
  ##
  ## Resolution rules:
  ##   * Skip empty heads (relative imports).
  ##   * Skip stdlib heads (``isPythonStdlibModule``).
  ##   * Anything else — the head must match an in-workspace member's
  ##     name (or owning package's name). On match, emit a
  ##     ``(fromPackage → toPackage)`` edge. On miss, silently drop
  ##     the import (the convention layer separately diagnoses
  ##     undeclared deps via its ``depends_on`` validation).
  let members = discoverPythonMembers(workspaceRoot)
  result.members = members
  if members.len == 0:
    return

  # Index every member's Python package name → owning package.
  var nameIndex = initTable[string, string]()
  for m in members:
    let memberKey = normalisePythonPackageName(m.member)
    if memberKey.len > 0 and not nameIndex.hasKey(memberKey):
      nameIndex[memberKey] = m.package
    let pkgKey = normalisePythonPackageName(m.package)
    if pkgKey.len > 0 and not nameIndex.hasKey(pkgKey):
      nameIndex[pkgKey] = m.package

  var allEdges: seq[DepEdge] = @[]
  for m in members:
    var seen = initTable[string, bool]()
    for sourcePath in collectScanSources(m):
      let text =
        try:
          readFile(extendedPath(sourcePath))
        except CatchableError:
          continue
      for importRef in extractPythonImportRefs(text):
        let head = importRef.head
        if head.len == 0:
          continue
        if isPythonStdlibModule(head):
          continue
        let lookupKey = normalisePythonPackageName(head)
        if not nameIndex.hasKey(lookupKey):
          continue
        let toPackage = nameIndex[lookupKey]
        if toPackage == m.package:
          # Self-import via a sibling member sharing the same owning
          # package — no workspace edge needed.
          continue
        let evidence = relativeEvidence(workspaceRoot, sourcePath,
          importRef.lineNumber, importRef.raw)
        let key = toPackage & "\x1f" & evidence
        if seen.getOrDefault(key, false):
          continue
        seen[key] = true
        allEdges.add(DepEdge(
          fromPackage: m.package,
          toPackage: toPackage,
          evidence: evidence))
  allEdges.sort(proc (a, b: DepEdge): int =
    let c1 = cmp(a.fromPackage, b.fromPackage)
    if c1 != 0: return c1
    let c2 = cmp(a.toPackage, b.toPackage)
    if c2 != 0: return c2
    cmp(a.evidence, b.evidence))
  result.edges = allEdges
