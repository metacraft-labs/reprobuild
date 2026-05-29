## Mode 3 JavaScript / TypeScript dependency scanner.
##
## Walks a JS/TS workspace and emits a deterministic dep graph naming
## **only** the inter-workspace package edges proved by bare-specifier
## ``import`` / ``require`` statements in each member's ``.ts`` /
## ``.tsx`` / ``.js`` / ``.mjs`` / ``.cjs`` sources. Mirror of the Nim,
## C/C++, Rust, Go, and Python scanners in ``./nim_dep_scanner.nim`` /
## ``./cpp_dep_scanner.nim`` / ``./rust_dep_scanner.nim`` /
## ``./go_dep_scanner.nim`` / ``./python_dep_scanner.nim`` per
## ``reprobuild-specs/Three-Mode-Convention-System.md`` §"The scanner
## contract" — same shapes, same determinism guarantee — but parsing
## JS/TS source instead.
##
## Scope of this milestone (M33, Mode 3 JS/TS pilot):
##   * Recognise JS/TS ``executable`` / ``library`` members declared in
##     a workspace's ``repro.nim`` / ``reprobuild.nim`` files. Detection
##     piggy-backs on layout: a member is JS/TS iff
##     ``<projectRoot>/<member>/src/index.ts|.tsx|.js|.mjs|.cjs``
##     (Layout B-src — library) OR
##     ``<projectRoot>/<member>/src/main.ts|.tsx|.js|.mjs|.cjs``
##     (Layout B-src — executable) OR
##     ``<projectRoot>/<member>/index.ts|...`` /
##     ``<projectRoot>/<member>/main.ts|...`` (Layout B-flat) OR
##     ``<projectRoot>/src/<member>.ts|...`` (Layout A) exists. Members
##     whose layout doesn't match are silently skipped.
##   * For each member, walk its source directory recursively for
##     ``.ts`` / ``.tsx`` / ``.js`` / ``.mjs`` / ``.cjs`` files
##     (excluding ``node_modules/`` / ``dist/`` / ``.repro/`` /
##     ``__pycache__/`` directories).
##   * Parse ESM ``import`` statements in every recognised shape:
##       ``import "mathlib";``                       (side-effect)
##       ``import mathlib from "mathlib";``          (default)
##       ``import { add } from "mathlib";``          (named)
##       ``import * as mathlib from "mathlib";``     (namespace)
##       ``import type { Foo } from "mathlib";``     (type-only)
##       ``import("mathlib")``                       (dynamic, literal)
##       ``export { add } from "mathlib";``          (re-export)
##       ``export * from "mathlib";``                (star re-export)
##     Plus CommonJS ``require("mathlib")`` calls for ``.cjs`` /
##     ``.js`` sources.
##   * Bare specifiers (``"mathlib"``) resolve against in-workspace
##     members. Relative specifiers (``"./local"``, ``"../sibling"``)
##     never produce a workspace edge — they're intra-package paths.
##   * Sub-path specifiers like ``"mathlib/sub"`` resolve to the
##     package's root (head before the first ``/``).
##   * Node builtins are filtered via a static list
##     (``NodeBuiltinModules`` — ``fs``, ``path``, ``http``, etc., plus
##     the ``node:`` URI prefix shape).
##   * External packages — anything whose head is neither a Node builtin
##     nor an in-workspace member — are silently dropped. Mode 3 JS/TS
##     is in-workspace only; users with npm deps write a
##     ``package.json`` and let the Mode 2 path drive the build.
##   * Emit edges sorted by ``(fromPackage, toPackage, evidence)`` so
##     the output is byte-deterministic across runs and hosts.
##
## Out of scope (documented as outstanding, deferred):
##   * Non-literal dynamic ``import(...)`` — scanner-invisible by design.
##     Per spec §"Manual override" the user adds explicit ``depends_on``
##     edges to wire those.
##   * ``tsconfig.json`` ``paths`` aliases — Mode 3 has no tsconfig at
##     the workspace root; users with path aliases write a tsconfig and
##     let the Mode 2 (typescript) convention drive the build.
##   * JSX / React syntactic features beyond what the bare ``import``
##     line shape provides — the scanner reads import statements only,
##     never parses JSX expressions.
##   * Triple-slash ``/// <reference path="..." />`` directives — these
##     are intra-project type references, not module imports.
##   * Source maps (``.map`` files) — never walked.
##   * Declaration files (``.d.ts``) — walked as regular ``.ts`` would
##     be, but typically empty of runtime imports.
##
## The scanner shares the ``WorkspaceMember`` / ``DepEdge`` /
## ``ScanResult`` types with ``./nim_dep_scanner.nim`` so the
## ``repro deps refresh`` driver can merge the Nim, C/C++, Rust, Go,
## Python, and JS/TS passes' output into a single
## ``repro.scanned-deps.nim``.

import std/[algorithm, os, strutils, tables]

import ./nim_dep_scanner
import ./paths
import ./project_file

const
  JsTsSourceExtensions* = [".ts", ".tsx", ".js", ".mjs", ".cjs"]
    ## File extensions the scanner treats as JS/TS source. ``.d.ts``
    ## files match the ``.ts`` extension but typically contain no
    ## runtime imports (they're type declarations) so they pass through
    ## the import extractor as a no-op. ``.jsx`` is omitted at M33 —
    ## React projects almost always ship a ``package.json`` and route
    ## through Mode 2.

  JsTsEntryFileNames* = [
    "index.ts", "index.tsx", "index.js", "index.mjs", "index.cjs",
    "main.ts", "main.tsx", "main.js", "main.mjs", "main.cjs",
  ]
    ## Canonical entry file names the scanner probes for at the member's
    ## source root. ``index.*`` matches the library convention (every
    ## ESM ``import "lib"`` resolves to ``lib/index.{js,ts}`` by default);
    ## ``main.*`` matches the executable convention (the entry script
    ## that runs under ``node``).

# ----------------------------------------------------------------------
# Member discovery — read project files and pull out executable/library
# declarations whose source layout looks like JS/TS (an entry file with
# one of the recognised extensions exists under the member's source
# dir). Members whose layout doesn't match are skipped; a Nim-only repo
# therefore produces zero JS/TS members and the scanner falls back to
# a no-op.
# ----------------------------------------------------------------------

proc extractJsTsMembersFromProjectFile(projectFile: string):
    seq[tuple[package: string; kind: string; name: string]] =
  ## Mirror of ``nim_dep_scanner.extractMembersFromProjectFile`` /
  ## ``python_dep_scanner.extractPythonMembersFromProjectFile``. The
  ## text scan itself is identical to the other scanners'; we return
  ## raw declarations without filtering and the caller filters by
  ## layout.
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

proc isJsTsSourceFile*(path: string): bool =
  ## True when ``path``'s extension is one of the recognised JS/TS
  ## source extensions.
  let lower = path.toLowerAscii
  for ext in JsTsSourceExtensions:
    if lower.endsWith(ext):
      return true
  false

proc dirHasJsTsSources(dir: string): bool =
  ## True when ``dir`` (or any nested subdir, excluding
  ## ``node_modules/`` / ``.repro/`` / ``dist/``) contains at least one
  ## JS/TS source file. Used as the layout filter for member discovery.
  if not dirExists(extendedPath(dir)):
    return false
  for path in walkDirRec(dir):
    let normalised = path.replace('\\', '/')
    if "/node_modules/" in normalised:
      continue
    if "/.repro/" in normalised:
      continue
    if "/dist/" in normalised:
      continue
    if isJsTsSourceFile(path):
      return true
  false

proc findFirstEntryFile(dir: string): string =
  ## Probe ``dir`` for one of the canonical ``JsTsEntryFileNames``.
  ## Returns the absolute path of the first match (in the order
  ## listed in ``JsTsEntryFileNames`` — ``.ts`` before ``.js``,
  ## ``index.*`` before ``main.*``). Returns empty string when no
  ## canonical entry file exists.
  for name in JsTsEntryFileNames:
    let candidate = dir / name
    if fileExists(extendedPath(candidate)):
      return candidate
  ""

proc resolveJsTsMemberDirs*(projectRoot, memberName: string):
    tuple[srcDir: string; entrySource: string] =
  ## Resolve a single member's source directory + entry-point source
  ## file under a project root. ``srcDir`` is the directory holding
  ## the entry file (and any sibling modules the convention will
  ## bundle); ``entrySource`` is the entry file itself.
  ##
  ## Supports the canonical Mode 3 JS/TS layout shapes:
  ##
  ##   Layout B-src — per-member ``src/`` (canonical multi-package
  ##                  shape; idiomatic JS/TS)::
  ##     <projectRoot>/<memberName>/src/index.{ts,tsx,js,mjs,cjs}
  ##     <projectRoot>/<memberName>/src/main.{ts,tsx,js,mjs,cjs}
  ##
  ##   Layout B-flat — per-member without ``src/`` (compact shape)::
  ##     <projectRoot>/<memberName>/index.{ts,tsx,js,mjs,cjs}
  ##     <projectRoot>/<memberName>/main.{ts,tsx,js,mjs,cjs}
  ##
  ##   Layout A — single-package project::
  ##     <projectRoot>/src/<memberName>.{ts,tsx,js,mjs,cjs}
  ##
  ## The most specific (multi-package) layouts are tried FIRST so the
  ## ambient ``src/`` directory of a Layout A project doesn't
  ## accidentally match a Layout B probe. Returns empty strings on
  ## both fields when no layout matches.
  let bSrc = projectRoot / memberName / "src"
  if dirExists(extendedPath(bSrc)):
    let entry = findFirstEntryFile(bSrc)
    if entry.len > 0:
      result.srcDir = bSrc
      result.entrySource = entry
      return

  let bFlat = projectRoot / memberName
  if dirExists(extendedPath(bFlat)):
    let entry = findFirstEntryFile(bFlat)
    if entry.len > 0:
      result.srcDir = bFlat
      result.entrySource = entry
      return

  let topSrc = projectRoot / "src"
  if dirExists(extendedPath(topSrc)):
    for ext in JsTsSourceExtensions:
      let candidate = topSrc / (memberName & ext)
      if fileExists(extendedPath(candidate)):
        result.srcDir = topSrc
        result.entrySource = candidate
        return

proc discoverJsTsMembers*(workspaceRoot: string): seq[WorkspaceMember] =
  ## Walk ``workspaceRoot`` for every project file and produce one
  ## ``WorkspaceMember`` per ``executable`` / ``library`` declared in a
  ## ``package`` block whose layout matches one of the canonical Mode 3
  ## JS/TS shapes (see ``resolveJsTsMemberDirs``). Members whose
  ## layout doesn't match are silently skipped — they belong to
  ## another language's scanner.
  ##
  ## The walk skips ``.repro/``, ``.git/``, ``node_modules/``,
  ## ``.nimcache/``, ``.cargo/``, ``target/``, ``__pycache__/``, and
  ## ``dist/`` — same as the other scanners — so a build's
  ## intermediates never pollute the member set.
  if not dirExists(extendedPath(workspaceRoot)):
    return @[]
  var queue: seq[string] = @[workspaceRoot]
  while queue.len > 0:
    let dir = queue[0]
    queue.delete(0)
    let match = resolveProjectFile(dir)
    if match.path.len > 0:
      for decl in extractJsTsMembersFromProjectFile(match.path):
        let resolved = resolveJsTsMemberDirs(dir, decl.name)
        if resolved.srcDir.len == 0:
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
            ".cargo", "target", "__pycache__", "dist"]:
          continue
        queue.add(entry)
    except OSError:
      discard
  result.sort(proc (a, b: WorkspaceMember): int =
    cmp((a.package, a.member), (b.package, b.member)))

# ----------------------------------------------------------------------
# Import extraction. The scanner is intentionally NOT a JS/TS parser:
# building one would dwarf the milestone. The line-scan below extracts
# every recognised ``import`` / ``export ... from`` / ``require(...)``
# / ``import(...)`` statement.
#
# JS/TS import shapes the scanner handles:
#   ESM:
#     * ``import "mod";``
#     * ``import mod from "mod";``
#     * ``import { a } from "mod";``
#     * ``import { a, b as c } from "mod";``
#     * ``import * as mod from "mod";``
#     * ``import mod, { a } from "mod";``
#     * ``import type { Foo } from "mod";``
#     * ``import("mod")``                  (literal dynamic import)
#     * ``export { a } from "mod";``
#     * ``export * from "mod";``
#     * ``export * as ns from "mod";``
#   CommonJS:
#     * ``require("mod")``
#
# Relative specifiers (``"./local"``, ``"../sibling"``, ``"/abs"``) are
# emitted with the literal head ``""`` (empty) so the caller's
# resolution layer can drop them — they're intra-package paths and
# never produce a workspace edge.
# ----------------------------------------------------------------------

type
  JsTsImportRef* = object
    ## One module specifier extracted from a JS/TS source file.
    head*: string
      ## The first path segment of the bare specifier. For
      ## ``"mathlib"`` the head is ``mathlib``; for ``"mathlib/sub"``
      ## the head is also ``mathlib``. Relative specifiers
      ## (``"./local"``) yield the empty head so the resolver drops
      ## them at the filter step.
    lineNumber*: int
      ## 1-based line number where the import was found.
    raw*: string
      ## The stripped source line for the evidence string.

proc stripJsTsLineComments(line: string): string =
  ## Drop everything after the first ``//`` that isn't inside a string
  ## literal or template literal. Block comments ``/* ... */`` are NOT
  ## tracked across line boundaries — they're rare in import regions
  ## of real codebases and the cost of a stateful scanner would dwarf
  ## the rest of the milestone. A rogue block-comment-wrapped import
  ## would produce at most a spurious edge that the user can suppress
  ## via manual override per spec §"Manual override".
  var inString = false
  var stringChar = '\0'
  var i = 0
  while i < line.len:
    let ch = line[i]
    if not inString:
      if ch == '/' and i + 1 < line.len and line[i + 1] == '/':
        return line[0 ..< i]
      if ch == '"' or ch == '\'' or ch == '`':
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

proc extractQuotedSpecifier(line: string; startIdx: int):
    tuple[ok: bool; value: string; endIdx: int] =
  ## Extract the contents of the next ``"..."`` or ``'...'`` string
  ## literal starting at or after ``startIdx``. Returns ``ok=false``
  ## when no string literal is found.
  ##
  ## ``endIdx`` points one past the closing quote when ``ok=true`` so
  ## the caller can scan for additional literals on the same line
  ## (rare but possible — comma-separated multi-import is not legal
  ## JS, but ``export { a } from "x"; import "y";`` on one line is).
  var i = startIdx
  while i < line.len:
    let ch = line[i]
    if ch == '"' or ch == '\'':
      let quote = ch
      inc i
      var value = ""
      while i < line.len:
        let c = line[i]
        if c == '\\' and i + 1 < line.len:
          # Pass-through escape — append the escaped char verbatim.
          # We don't translate ``\n`` etc because the bare-specifier
          # restriction (no slashes-with-special-chars-at-start)
          # means real specifiers never need them.
          value.add(line[i + 1])
          inc i, 2
          continue
        if c == quote:
          inc i
          return (true, value, i)
        value.add(c)
        inc i
      return (false, "", i)
    inc i
  (false, "", i)

proc isIdentifierChar(ch: char): bool =
  ch in {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '_', '$'}

proc extractBareSpecifierHead*(specifier: string): string =
  ## Return the first ``/``-separated segment of a bare specifier.
  ## Returns empty string when ``specifier`` is empty, starts with
  ## ``.`` or ``/`` (relative / absolute path — not a bare specifier),
  ## or starts with ``@`` followed by a scope (e.g. ``@scope/pkg`` →
  ## the head is ``@scope/pkg`` so it can route through the
  ## workspace-member lookup even though the head technically spans
  ## two segments; this matches npm's scoped-package convention).
  ##
  ## Sub-paths like ``"mathlib/sub/path"`` resolve to the head
  ## ``mathlib`` (the package root). For scoped packages
  ## ``"@scope/pkg/sub"`` resolve to ``@scope/pkg``.
  if specifier.len == 0:
    return ""
  if specifier.startsWith("./") or specifier.startsWith("../") or
      specifier == "." or specifier == "..":
    return ""
  if specifier.startsWith("/"):
    return ""
  if specifier.startsWith("@"):
    # Scoped package: the head is two segments (``@scope/pkg``).
    let firstSlash = specifier.find('/')
    if firstSlash < 0:
      # Malformed scoped specifier (no ``/`` after ``@scope``); treat
      # the whole thing as the head.
      return specifier
    let secondSlash = specifier.find('/', firstSlash + 1)
    if secondSlash < 0:
      return specifier
    return specifier[0 ..< secondSlash]
  let slashIdx = specifier.find('/')
  if slashIdx < 0:
    return specifier
  specifier[0 ..< slashIdx]

proc findKeywordAt(line: string; startIdx: int; keyword: string):
    tuple[ok: bool; endIdx: int] =
  ## True when ``line[startIdx ..]`` begins with ``keyword`` followed by
  ## a non-identifier character (or end of line). Returns the index one
  ## past the keyword on success. Used so ``"importer"`` and ``"requires"``
  ## aren't accidentally tokenised as ``import`` / ``require``.
  if startIdx + keyword.len > line.len:
    return (false, startIdx)
  if line[startIdx ..< startIdx + keyword.len] != keyword:
    return (false, startIdx)
  let afterIdx = startIdx + keyword.len
  if afterIdx < line.len and isIdentifierChar(line[afterIdx]):
    return (false, startIdx)
  (true, afterIdx)

proc skipWhitespace(line: string; startIdx: int): int =
  var i = startIdx
  while i < line.len and line[i] in {' ', '\t'}:
    inc i
  i

proc handleEsmFromClause(line: string; afterImportOrExport: int):
    tuple[ok: bool; specifier: string] =
  ## Find ``from "..."`` (or ``from '...'``) on the line and extract the
  ## quoted specifier. Returns ``ok=false`` when no ``from`` clause is
  ## present (rare — ``import "side-effect-only"`` doesn't have one;
  ## that shape is handled separately).
  var i = afterImportOrExport
  while i < line.len:
    # Find the ``from`` keyword. The simplest correct scan is to look
    # for the literal token ``from`` not preceded by an identifier
    # char.
    if line[i] == '"' or line[i] == '\'':
      # No ``from`` keyword — this is ``import "mod"`` /
      # ``export "mod"`` (the latter isn't legal JS but we tolerate
      # it).
      let r = extractQuotedSpecifier(line, i)
      return (r.ok, r.value)
    let probe = findKeywordAt(line, i, "from")
    if probe.ok:
      let afterFrom = skipWhitespace(line, probe.endIdx)
      let r = extractQuotedSpecifier(line, afterFrom)
      return (r.ok, r.value)
    inc i
  (false, "")

proc extractJsTsImportRefs*(sourceText: string): seq[JsTsImportRef] =
  ## Walk ``sourceText`` line-by-line and emit every recognised
  ## ``import`` / ``export ... from`` / ``import(...)`` / ``require(...)``
  ## statement. Handles all the shapes documented in this module's
  ## docstring.
  ##
  ## The scanner does NOT track multi-line ``import { ... }`` blocks —
  ## the ``from`` clause and its quoted specifier MUST live on the
  ## same source line as the closing brace. Real-world JS/TS code
  ## puts ``from "..."`` on the closing-brace line, which is what
  ## modern formatters (Prettier, ESLint) enforce. Multi-line
  ## ``require`` calls are similarly out of scope.
  var lineNo = 0
  for rawLine in sourceText.splitLines():
    inc lineNo
    let cleaned = stripJsTsLineComments(rawLine)
    let stripped = cleaned.strip()
    if stripped.len == 0:
      continue

    # ESM ``import ...``. Handles:
    #   * ``import "mod";``
    #   * ``import x from "mod";``
    #   * ``import { ... } from "mod";``
    #   * ``import * as x from "mod";``
    #   * ``import type ... from "mod";``
    block esmImport:
      let probe = findKeywordAt(stripped, 0, "import")
      if not probe.ok:
        break esmImport
      let afterImport = skipWhitespace(stripped, probe.endIdx)
      if afterImport >= stripped.len:
        break esmImport
      # ``import(...)`` dynamic — handled below in the dynamic block.
      if stripped[afterImport] == '(':
        break esmImport
      let extract = handleEsmFromClause(stripped, afterImport)
      if not extract.ok:
        break esmImport
      let head = extractBareSpecifierHead(extract.specifier)
      result.add(JsTsImportRef(
        head: head,
        lineNumber: lineNo,
        raw: stripped))
      continue

    # ESM ``export ... from "..."`` (re-exports). Handles:
    #   * ``export { a } from "mod";``
    #   * ``export * from "mod";``
    #   * ``export * as ns from "mod";``
    #   * ``export type { Foo } from "mod";``
    block esmExportFrom:
      let probe = findKeywordAt(stripped, 0, "export")
      if not probe.ok:
        break esmExportFrom
      let afterExport = skipWhitespace(stripped, probe.endIdx)
      if afterExport >= stripped.len:
        break esmExportFrom
      let extract = handleEsmFromClause(stripped, afterExport)
      if not extract.ok:
        break esmExportFrom
      let head = extractBareSpecifierHead(extract.specifier)
      result.add(JsTsImportRef(
        head: head,
        lineNumber: lineNo,
        raw: stripped))
      continue

    # Dynamic ``import("mod")`` calls — scan anywhere on the line.
    # Multiple dynamic imports per line are supported.
    var dynScan = 0
    while dynScan < stripped.len:
      let idx = stripped.find("import", dynScan)
      if idx < 0:
        break
      # Guard against ``importer`` / ``Importx`` etc.
      if idx > 0 and isIdentifierChar(stripped[idx - 1]):
        dynScan = idx + len("import")
        continue
      let afterImport = idx + len("import")
      if afterImport >= stripped.len:
        break
      # Must be followed (after optional whitespace) by ``(``.
      let i2 = skipWhitespace(stripped, afterImport)
      if i2 >= stripped.len or stripped[i2] != '(':
        dynScan = afterImport
        continue
      let r = extractQuotedSpecifier(stripped, i2 + 1)
      if r.ok:
        let head = extractBareSpecifierHead(r.value)
        result.add(JsTsImportRef(
          head: head,
          lineNumber: lineNo,
          raw: stripped))
      dynScan = if r.ok: r.endIdx else: afterImport

    # CommonJS ``require("mod")`` calls — scan anywhere on the line.
    var reqScan = 0
    while reqScan < stripped.len:
      let idx = stripped.find("require", reqScan)
      if idx < 0:
        break
      if idx > 0 and isIdentifierChar(stripped[idx - 1]):
        reqScan = idx + len("require")
        continue
      let afterRequire = idx + len("require")
      if afterRequire >= stripped.len:
        break
      let i2 = skipWhitespace(stripped, afterRequire)
      if i2 >= stripped.len or stripped[i2] != '(':
        reqScan = afterRequire
        continue
      let r = extractQuotedSpecifier(stripped, i2 + 1)
      if r.ok:
        let head = extractBareSpecifierHead(r.value)
        result.add(JsTsImportRef(
          head: head,
          lineNumber: lineNo,
          raw: stripped))
      reqScan = if r.ok: r.endIdx else: afterRequire

# ----------------------------------------------------------------------
# Node-builtin filter. Node's built-in modules ship with the runtime
# and address-resolve to the runtime itself rather than to a workspace
# member. We filter via a static list generated from Node 22's
# ``module.builtinModules`` snapshot; it's belt-and-suspenders versus
# the "everything not in-workspace is external" heuristic that drops
# imports past the workspace lookup table.
#
# Modern Node also accepts the ``node:`` URI prefix
# (``node:fs``, ``node:path``); the head extractor strips the prefix
# explicitly so both forms resolve to the same filter outcome.
# ----------------------------------------------------------------------

const NodeBuiltinModules* = [
  "_http_agent", "_http_client", "_http_common", "_http_incoming",
  "_http_outgoing", "_http_server", "_stream_duplex",
  "_stream_passthrough", "_stream_readable", "_stream_transform",
  "_stream_wrap", "_stream_writable", "_tls_common", "_tls_wrap",
  "assert", "async_hooks", "buffer", "child_process", "cluster",
  "console", "constants", "crypto", "dgram", "diagnostics_channel",
  "dns", "domain", "events", "fs", "http", "http2", "https",
  "inspector", "module", "net", "os", "path", "perf_hooks",
  "process", "punycode", "querystring", "readline", "repl",
  "stream", "string_decoder", "sys", "timers", "tls",
  "trace_events", "tty", "url", "util", "v8", "vm", "wasi",
  "worker_threads", "zlib",
  # ECMAScript test helpers Node exposes as builtins:
  "test", "test/reporters", "test/mock",
]
  ## The static Node builtin list. Anything missing from this list
  ## falls through to the workspace-member lookup; a hit there means
  ## a workspace edge, a miss means a silent drop (third-party
  ## npm package).

proc isNodeBuiltinModule*(head: string): bool =
  ## True when ``head`` is a Node built-in module. Accepts both the
  ## bare form (``"fs"``) and the modern ``node:`` URI prefix form
  ## (``"node:fs"``). Comparison is case-sensitive (Node module names
  ## are case-sensitive on all platforms).
  if head.len == 0:
    return false
  let candidate =
    if head.startsWith("node:"): head[len("node:") .. ^1]
    else: head
  for entry in NodeBuiltinModules:
    if entry == candidate:
      return true
  false

# ----------------------------------------------------------------------
# Member-name normalisation. JavaScript identifiers allow ``$`` and
# ``_`` but the npm package-name grammar additionally allows ``-``
# (kebab-case is the canonical npm style). The scanner keeps the names
# verbatim and matches case-sensitively (npm package names are
# case-sensitive in modern registry semantics; legacy mixed-case names
# are a registry-historical wart we don't try to model).
# ----------------------------------------------------------------------

proc normaliseJsTsPackageName*(text: string): string =
  ## Identity for now (kept as a hook for future normalisation rules
  ## if any Mode 3 fixture warrants them). Mirror of the Go and
  ## Python scanners' ``normalise*PackageName``.
  text

# ----------------------------------------------------------------------
# Source collection. For each member we walk every JS/TS file under
# its source dir (excluding ``node_modules/`` / ``.repro/`` / ``dist/``
# / ``__pycache__/``); the scanner is conservative on the include
# side (every file's imports count).
# ----------------------------------------------------------------------

proc collectScanSources(member: WorkspaceMember): seq[string] =
  ## Every recognised JS/TS source file under the member's source
  ## subtree. Resolved via the entry file's parent dir so single-file
  ## and multi-file members both work.
  if member.sourceFile.len == 0:
    return @[]
  let srcDir = member.sourceFile.parentDir
  if not dirExists(extendedPath(srcDir)):
    return @[]
  for path in walkDirRec(srcDir):
    let normalised = path.replace('\\', '/')
    if "/node_modules/" in normalised:
      continue
    if "/.repro/" in normalised:
      continue
    if "/dist/" in normalised:
      continue
    if "/__pycache__/" in normalised:
      continue
    if isJsTsSourceFile(path):
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

proc scanWorkspaceJsTs*(workspaceRoot: string): ScanResult =
  ## Top-level JS/TS scanner entry point. Discovers members, builds
  ## the ``<package-name> → <package>`` index, walks each member's
  ## sources, resolves ``import`` heads, emits a sorted edge list.
  ##
  ## Resolution rules:
  ##   * Skip empty heads (relative imports).
  ##   * Skip Node builtin heads (``isNodeBuiltinModule``).
  ##   * Anything else — the head must match an in-workspace member's
  ##     name (or owning package's name). On match, emit a
  ##     ``(fromPackage → toPackage)`` edge. On miss, silently drop
  ##     the import (the convention layer separately diagnoses
  ##     undeclared deps via its ``depends_on`` validation).
  let members = discoverJsTsMembers(workspaceRoot)
  result.members = members
  if members.len == 0:
    return

  # Index every member's JS/TS package name → owning package.
  # Also index by the owning package name so ``import "pkgname"`` from
  # another member matches when the package has no member with that
  # exact name.
  var nameIndex = initTable[string, string]()
  for m in members:
    let memberKey = normaliseJsTsPackageName(m.member)
    if memberKey.len > 0 and not nameIndex.hasKey(memberKey):
      nameIndex[memberKey] = m.package
    let pkgKey = normaliseJsTsPackageName(m.package)
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
      for importRef in extractJsTsImportRefs(text):
        let head = importRef.head
        if head.len == 0:
          continue
        if isNodeBuiltinModule(head):
          continue
        let lookupKey = normaliseJsTsPackageName(head)
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
