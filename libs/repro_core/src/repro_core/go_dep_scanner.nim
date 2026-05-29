## Mode 3 Go dependency scanner.
##
## Walks a Go workspace and emits a deterministic dep graph naming
## **only** the inter-workspace package edges proved by ``import "..."``
## statements in each package's ``.go`` sources. Mirror of the Nim,
## C/C++, and Rust scanners in ``./nim_dep_scanner.nim`` /
## ``./cpp_dep_scanner.nim`` / ``./rust_dep_scanner.nim`` per
## ``reprobuild-specs/Three-Mode-Convention-System.md`` §"The scanner
## contract" — same shapes, same determinism guarantee — but parsing
## Go source instead.
##
## Scope of this milestone (M31, Mode 3 Go pilot):
##   * Recognise Go ``executable`` / ``library`` members declared in a
##     workspace's ``repro.nim`` / ``reprobuild.nim`` files. Detection
##     piggy-backs on layout: a member is Go iff
##     ``<projectRoot>/<member>/`` (Layout B) OR ``<projectRoot>/`` /
##     ``<projectRoot>/src/`` (Layout A) contains at least one ``.go``
##     source file.
##   * For each member, walk its source directory recursively for
##     ``.go`` files (excluding ``_test.go`` — tests are deferred to a
##     future milestone, matching the M5/M14 Mode 2 stance).
##   * Parse ``import`` statements in both single-line and grouped
##     forms:
##       ``import "fmt"``
##       ``import (`` ... ``)``
##     The quoted path's last segment (or full path when it has no
##     slash) is resolved against the set of other in-workspace member
##     names. Mode 3 Go has no ``go.mod`` at the workspace root, so
##     there's no module path to anchor full import paths against —
##     in-workspace lookups use the bare package name.
##   * Stdlib imports are filtered via the static list
##     ``GoStdlibPackages``. Any import path whose first segment is on
##     that list (``fmt`` / ``os`` / ``encoding/json`` / ``net/http`` /
##     etc.) drops out — the scanner never emits an edge for stdlib.
##   * External-module imports — paths whose first segment contains a
##     dot (``github.com/...``, ``golang.org/x/...``, ``example.com/...``)
##     — are silently dropped. Mode 3 Go is in-workspace only; external
##     modules belong to the ``go.mod``-driven Mode 2 path.
##   * Emit edges sorted by ``(fromPackage, toPackage, evidence)`` so
##     the output is byte-deterministic across runs and hosts.
##
## Out of scope (documented as outstanding, deferred):
##   * Build-tag-conditioned imports (``//go:build linux`` blocks) —
##     the scanner reads them as if always taken. Edges that only
##     manifest under a specific build tag are over-emitted on the
##     conservative side; the spec calls out manual ``depends_on``
##     overrides as the suppression mechanism.
##   * ``_test.go`` files are skipped entirely. Test discovery for
##     Mode 3 Go matches the Mode 2 honest-scope cut (M22 added test
##     discovery to Mode 2; the equivalent Mode 3 surface is a future
##     milestone).
##   * cgo (``import "C"``) — Mode 3 inherits the M5/M14 stance and
##     never emits an edge for the magic ``"C"`` import. cgo support
##     proper is deferred to M36 (Go ↔ C cross-language).
##   * ``internal/`` cross-package access restrictions — Mode 3 does
##     NOT enforce these. A future milestone may add the diagnostic.
##   * External Go modules (anything with a dot in the first path
##     segment) are silently dropped. Users with external deps write a
##     ``go.mod`` and let the Mode 2 convention drive the build.
##
## The scanner shares the ``WorkspaceMember`` / ``DepEdge`` /
## ``ScanResult`` types with ``./nim_dep_scanner.nim`` so the
## ``repro deps refresh`` driver can merge the Nim, C/C++, Rust, and
## Go passes' output into a single ``repro.scanned-deps.nim``.

import std/[algorithm, os, strutils, tables]

import ./nim_dep_scanner
import ./paths
import ./project_file

const
  GoSourceExtension* = ".go"
    ## The single file extension the scanner treats as a Go source
    ## file. ``_test.go`` is filtered at the file-name level so the
    ## ext alone suffices here.

# ----------------------------------------------------------------------
# Member discovery — read project files and pull out executable/library
# declarations whose source layout looks like Go (at least one ``.go``
# source under one of the canonical Mode 3 Go shapes). Members whose
# layout doesn't match are skipped; a Nim-only repo therefore produces
# zero Go members and the scanner falls back to a no-op.
# ----------------------------------------------------------------------

proc extractGoMembersFromProjectFile(projectFile: string):
    seq[tuple[package: string; kind: string; name: string]] =
  ## Mirror of ``nim_dep_scanner.extractMembersFromProjectFile`` /
  ## ``rust_dep_scanner.extractRustMembersFromProjectFile``. The text
  ## scan itself is identical to the other scanners'; we return raw
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

proc isGoSourceFile*(path: string): bool =
  ## True when ``path``'s extension is ``.go`` AND it is NOT a
  ## ``_test.go`` file. The test-file filter lives here because the
  ## scanner walks every recursed path and we want every callsite to
  ## see the same definition of "Go source we care about".
  let lower = path.toLowerAscii
  if not lower.endsWith(GoSourceExtension):
    return false
  if extractFilename(lower).endsWith("_test.go"):
    return false
  true

proc dirHasGoSources(dir: string): bool =
  ## True when ``dir`` (or any nested subdir) contains a non-test ``.go``
  ## file. Used as the layout filter — directories with no Go sources
  ## never contribute to the Go scanner's member list.
  if not dirExists(extendedPath(dir)):
    return false
  for path in walkDirRec(dir):
    if isGoSourceFile(path):
      return true
  false

proc resolveGoMemberDirs*(projectRoot, memberName: string):
    tuple[srcDir: string; entrySource: string] =
  ## Resolve a single member's source directory under a project root.
  ## Supports the two canonical Mode 3 Go layout shapes:
  ##
  ##   Layout B — multiple packages per project file (the canonical
  ##              Mode 3 multi-package shape; idiomatic Go)::
  ##
  ##       <projectRoot>/<memberName>/*.go
  ##
  ##   Layout A — one package per project file::
  ##
  ##       <projectRoot>/src/*.go
  ##       <projectRoot>/*.go
  ##
  ## Layout B is tried FIRST because Layout A's project root may also
  ## contain ``<memberName>/`` directories. The opposite is not true:
  ## Layout B always lives under a per-member subdir.
  ##
  ## ``entrySource`` is set to the first ``.go`` file found
  ## (alphabetical, deterministic) for member-scaffold attribution; the
  ## convention walks every ``.go`` under ``srcDir`` for actual compile
  ## inputs. Returns empty strings on both fields when no layout
  ## matches.
  let subdir = projectRoot / memberName
  if dirHasGoSources(subdir):
    result.srcDir = subdir
    var firstSource = ""
    for path in walkDirRec(subdir):
      if isGoSourceFile(path):
        if firstSource.len == 0 or path < firstSource:
          firstSource = path
    result.entrySource = firstSource
    return

  let topSrc = projectRoot / "src"
  if dirHasGoSources(topSrc):
    result.srcDir = topSrc
    var firstSource = ""
    for path in walkDirRec(topSrc):
      if isGoSourceFile(path):
        if firstSource.len == 0 or path < firstSource:
          firstSource = path
    result.entrySource = firstSource
    return

  if dirHasGoSources(projectRoot):
    result.srcDir = projectRoot
    var firstSource = ""
    for kind, entry in walkDir(projectRoot):
      if kind != pcFile:
        continue
      if isGoSourceFile(entry):
        if firstSource.len == 0 or entry < firstSource:
          firstSource = entry
    result.entrySource = firstSource

proc discoverGoMembers*(workspaceRoot: string): seq[WorkspaceMember] =
  ## Walk ``workspaceRoot`` for every project file and produce one
  ## ``WorkspaceMember`` per ``executable`` / ``library`` declared in a
  ## ``package`` block whose layout matches one of the two canonical
  ## Go Mode 3 shapes (see ``resolveGoMemberDirs``). Members whose
  ## layout doesn't match are silently skipped — they belong to another
  ## language's scanner.
  ##
  ## The walk skips ``.repro/``, ``.git/``, ``node_modules/``,
  ## ``.nimcache/``, ``.cargo/``, and ``target/`` — same as the Nim,
  ## C/C++, and Rust scanners — so a build's intermediates never
  ## pollute the member set.
  if not dirExists(extendedPath(workspaceRoot)):
    return @[]
  var queue: seq[string] = @[workspaceRoot]
  while queue.len > 0:
    let dir = queue[0]
    queue.delete(0)
    let match = resolveProjectFile(dir)
    if match.path.len > 0:
      for decl in extractGoMembersFromProjectFile(match.path):
        let resolved = resolveGoMemberDirs(dir, decl.name)
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
            ".cargo", "target"]:
          continue
        queue.add(entry)
    except OSError:
      discard
  result.sort(proc (a, b: WorkspaceMember): int =
    cmp((a.package, a.member), (b.package, b.member)))

# ----------------------------------------------------------------------
# Import extraction. The scanner is intentionally NOT a Go parser:
# building one would dwarf the milestone. The line-scan below extracts
# every quoted string inside an ``import`` block (single-line or
# grouped) and treats the quoted text as the import path.
#
# Go's import shapes the scanner handles:
#   * ``import "fmt"``                     — single-line, no alias
#   * ``import f "fmt"``                   — single-line, aliased
#   * ``import _ "fmt"``                   — single-line, blank import
#   * ``import . "fmt"``                   — single-line, dot import
#   * ``import (``                         — grouped block
#         ``"fmt"``
#         ``j "encoding/json"``
##         ``_ "embed"``
#     ``)``
# ----------------------------------------------------------------------

type
  GoImportRef* = object
    ## One quoted import path extracted from a ``.go`` source file.
    path*: string
      ## The bareword between the quotes — e.g. ``"net/http"`` → ``net/http``.
      ## Resolution against workspace members / stdlib / external modules
      ## is the caller's job.
    lineNumber*: int
      ## 1-based line number where the quoted path was found.
    raw*: string
      ## The stripped source line for the evidence string.

proc stripGoLineComment(line: string): string =
  ## Drop everything after the first ``//`` that isn't inside a string
  ## literal. Block comments ``/* ... */`` are NOT handled — they're
  ## rare in import regions of real codebases and the cost of a
  ## stateful scanner would dwarf the rest of the milestone. A rogue
  ## block-comment-wrapped import would produce at most a spurious
  ## edge that the user can suppress via manual override per spec
  ## §"Manual override".
  var inString = false
  var inRawString = false
  var i = 0
  while i < line.len:
    let ch = line[i]
    if inRawString:
      if ch == '`':
        inRawString = false
      inc i
      continue
    if not inString:
      if ch == '/' and i + 1 < line.len and line[i + 1] == '/':
        return line[0 ..< i]
      if ch == '"':
        inString = true
      elif ch == '`':
        inRawString = true
    else:
      if ch == '\\' and i + 1 < line.len:
        # Skip the escaped char so an escaped quote inside a string
        # literal doesn't close the string.
        inc i
      elif ch == '"':
        inString = false
    inc i
  line

proc extractQuotedString(line: string): string =
  ## Return the contents of the first ``"..."`` on ``line``, or empty
  ## when no quoted string is present.
  let openIdx = line.find('"')
  if openIdx < 0:
    return ""
  let closeIdx = line.find('"', openIdx + 1)
  if closeIdx <= openIdx:
    return ""
  line[openIdx + 1 ..< closeIdx]

proc extractGoImportRefs*(sourceText: string): seq[GoImportRef] =
  ## Walk ``sourceText`` line-by-line and emit every recognised
  ## ``import`` quoted path. Handles:
  ##
  ##   * Single-line ``import "<path>"``
  ##   * Single-line ``import <alias|_|.> "<path>"``
  ##   * Grouped ``import (`` ... ``)`` blocks; every line inside the
  ##     block is scanned for a quoted path. Lines with ``//`` comments
  ##     have the comment stripped first.
  ##
  ## Lines outside ``import`` blocks are skipped — Go syntactically
  ## requires all imports to live in ``import`` declarations at the top
  ## of the file. We track whether we're inside a grouped block so a
  ## later string literal in (say) a ``fmt.Println(...)`` body never
  ## false-positives as an import.
  var lineNo = 0
  var inGroupBlock = false
  for rawLine in sourceText.splitLines():
    inc lineNo
    let cleaned = stripGoLineComment(rawLine)
    let stripped = cleaned.strip()
    if stripped.len == 0:
      continue

    if inGroupBlock:
      if stripped.startsWith(")"):
        inGroupBlock = false
        continue
      let path = extractQuotedString(stripped)
      if path.len == 0:
        continue
      result.add(GoImportRef(
        path: path,
        lineNumber: lineNo,
        raw: stripped))
      continue

    if not stripped.startsWith("import"):
      continue
    if stripped.len > len("import") and
        stripped[len("import")] notin {' ', '\t', '('}:
      # ``importPath`` identifier or similar — not the import keyword.
      continue
    let rest = stripped[len("import") .. ^1].strip()
    if rest.len == 0:
      # ``import`` on its own line followed by ``(`` on the next? Go's
      # grammar doesn't allow that — ``import`` must be followed by
      # either ``"..."``, ``<alias> "..."``, or ``(``. We accept the
      # malformed shape defensively (the parser is not a syntax
      # checker).
      continue
    if rest.startsWith("("):
      inGroupBlock = true
      # The opening ``(`` may have a quoted path on the same line in
      # the (unusual but legal) ``import ("path")`` form — handle it.
      let afterParen = rest[1 .. ^1].strip()
      if afterParen.startsWith(")"):
        inGroupBlock = false
        continue
      if afterParen.len > 0:
        let path = extractQuotedString(afterParen)
        if path.len > 0:
          result.add(GoImportRef(
            path: path,
            lineNumber: lineNo,
            raw: stripped))
      continue
    # Single-line ``import "<path>"`` or ``import <alias> "<path>"``.
    let path = extractQuotedString(rest)
    if path.len == 0:
      continue
    result.add(GoImportRef(
      path: path,
      lineNumber: lineNo,
      raw: stripped))

# ----------------------------------------------------------------------
# Stdlib filter. Go's standard library packages are addressed by paths
# whose first segment has no dot in it (``fmt``, ``encoding/json``,
# ``net/http``). External modules use a domain-like first segment with
# a dot (``github.com/...``, ``golang.org/x/...``, ``example.com/...``).
# Both rules together cover the universe of Go imports.
#
# The dot-in-first-segment heuristic is the same one ``go list -m`` uses
# to distinguish stdlib from module paths; it's the official Go
# convention for module-path namespacing.
#
# We additionally maintain a static ``GoStdlibPackages`` list as a
# defensive belt-and-suspenders so a stdlib root-name like ``cmd`` (Go's
# command-source-tree namespace) doesn't accidentally collide with a
# workspace member named ``cmd`` (which is a common Mode 3 layout
# shape).
# ----------------------------------------------------------------------

const GoStdlibPackages* = [
  # Top-level stdlib packages (Go 1.23). Used as the prefix match for
  # ``isGoStdlibImport`` — any import path whose first segment is on
  # this list is stdlib.
  "archive", "bufio", "builtin", "bytes", "cmp", "compress",
  "container", "context", "crypto", "database", "debug",
  "embed", "encoding", "errors", "expvar", "flag", "fmt",
  "go", "hash", "html", "image", "index", "io", "iter",
  "log", "maps", "math", "mime", "net", "os", "path",
  "plugin", "reflect", "regexp", "runtime", "slices", "sort",
  "strconv", "strings", "structs", "sync", "syscall", "testing",
  "text", "time", "unicode", "unique", "unsafe",
  # Special package the Go toolchain reserves; used by the language
  # itself.
  "internal",
  # cgo's magic single-letter "C" pseudo-package. Mode 3 cgo is
  # explicitly out of scope (M31 keeps rejecting cgo); listing it
  # here ensures a stray ``import "C"`` doesn't spuriously become a
  # workspace edge.
  "C",
]
  ## The set of stdlib top-level package names the scanner filters
  ## out. An import path whose first ``/``-separated segment is one of
  ## these is dropped without producing an edge.

proc importFirstSegment(path: string): string =
  let slashIdx = path.find('/')
  if slashIdx < 0:
    return path
  path[0 ..< slashIdx]

proc isGoStdlibImport*(path: string): bool =
  ## True when the import path resolves to a stdlib package (its first
  ## ``/``-separated segment is on ``GoStdlibPackages``).
  let head = importFirstSegment(path)
  for entry in GoStdlibPackages:
    if entry == head:
      return true
  false

proc isGoExternalModuleImport*(path: string): bool =
  ## True when the import path looks like an external module
  ## (``github.com/foo/bar``, ``golang.org/x/...``, ``example.com/...``).
  ## The convention is: the first segment contains a dot. Mode 3 Go is
  ## in-workspace only, so external imports are silently dropped — the
  ## escape hatch is to write a ``go.mod`` and let Mode 2 handle them.
  let head = importFirstSegment(path)
  '.' in head

proc importLastSegment*(path: string): string =
  ## The last ``/``-separated segment of an import path. Used as the
  ## key into the in-workspace member index when the import path has
  ## slashes — Mode 3 has no go.mod so the full path can't anchor on a
  ## module prefix; we match by trailing package name.
  let slashIdx = path.rfind('/')
  if slashIdx < 0:
    return path
  path[slashIdx + 1 .. ^1]

# ----------------------------------------------------------------------
# Member-name normalisation. Go package names are typically the
# directory basename — no ``-`` mangling like Rust's, because Go's
# package identifier rules disallow ``-`` in the package name. The
# scanner keeps the names verbatim and matches case-sensitively (Go
# package names are case-sensitive too).
# ----------------------------------------------------------------------

proc normaliseGoPackageName*(text: string): string =
  ## Identity for now (kept as a hook for future ``-`` → ``_`` style
  ## rules if any Mode 3 fixture warrants them). Mirror of the Rust
  ## scanner's ``normaliseRustCrateName`` — the convention there
  ## collapses ``-`` to ``_``; we don't because Go disallows ``-`` in
  ## the on-the-wire package identifier already.
  text

# ----------------------------------------------------------------------
# Source collection. For each member we walk every ``.go`` file under
# its source dir (excluding ``_test.go``); the scanner is conservative
# on the include side (every non-test file's imports count).
# ----------------------------------------------------------------------

proc collectScanSources(member: WorkspaceMember): seq[string] =
  ## Every non-test ``.go`` file under the member's source subtree.
  ## Resolved via the Layout B / Layout A fallback so single-package
  ## and multi-package workspaces both work.
  ##
  ## ``member.sourceFile`` already points at a Go file inside the
  ## chosen source dir; we reuse its parent dir as the search root
  ## rather than re-running ``resolveGoMemberDirs``.
  if member.sourceFile.len == 0:
    return @[]
  let srcDir = member.sourceFile.parentDir
  if not dirExists(extendedPath(srcDir)):
    return @[]
  # Member's source dir might be ``<root>/<member>/`` (Layout B) or
  # ``<root>/src/`` or ``<root>/`` (Layout A). Walk recursively so
  # nested sub-packages (a member with ``cmd/<name>/main.go`` etc) get
  # included — Mode 3 has no go.mod so nested packages aren't strictly
  # supported, but we walk to be conservative on the input side.
  for path in walkDirRec(srcDir):
    if isGoSourceFile(path):
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

proc scanWorkspaceGo*(workspaceRoot: string): ScanResult =
  ## Top-level Go scanner entry point. Discovers members, builds the
  ## ``<package-name> → <package>`` index, walks each member's
  ## non-test sources, resolves ``import`` paths, emits a sorted edge
  ## list.
  ##
  ## Resolution rules:
  ##   * Skip stdlib paths (``isGoStdlibImport``).
  ##   * Skip external-module paths (``isGoExternalModuleImport``).
  ##   * Anything else — the import's last segment must match an
  ##     in-workspace member's name (or owning package's name). On
  ##     match, emit a ``(fromPackage → toPackage)`` edge. On miss,
  ##     silently drop the import (the convention layer separately
  ##     diagnoses undeclared deps via its ``depends_on`` validation).
  let members = discoverGoMembers(workspaceRoot)
  result.members = members
  if members.len == 0:
    return

  # Index every member's Go package name → owning package.
  # We also index by the package name so ``import "pkgname"`` from
  # another member matches when the package has no member with that
  # exact name (rare but possible — same forgiveness the Rust scanner
  # applies).
  var nameIndex = initTable[string, string]()
  for m in members:
    let memberKey = normaliseGoPackageName(m.member)
    if memberKey.len > 0 and not nameIndex.hasKey(memberKey):
      nameIndex[memberKey] = m.package
    let pkgKey = normaliseGoPackageName(m.package)
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
      for importRef in extractGoImportRefs(text):
        let path = importRef.path
        if path.len == 0:
          continue
        if isGoStdlibImport(path):
          continue
        if isGoExternalModuleImport(path):
          continue
        # In-workspace candidate — match by the import path's last
        # segment (Mode 3 has no go.mod, so the bare package name is
        # the resolution key).
        let lookupKey = normaliseGoPackageName(importLastSegment(path))
        if not nameIndex.hasKey(lookupKey):
          continue
        let toPackage = nameIndex[lookupKey]
        if toPackage == m.package:
          # Self-import via the package's own name — not a workspace
          # edge. Rare but possible when a member imports a sibling
          # member that happens to share the owning package name.
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
