## Mode 3 C/C++ dependency scanner.
##
## Walks a C/C++ workspace and emits the inter-package edges proved by
## ``#include "..."`` lines in each package's sources. Mirror of the Nim
## scanner in ``./nim_dep_scanner.nim`` per
## ``reprobuild-specs/Three-Mode-Convention-System.md`` §"The scanner
## contract" — same shapes, same determinism guarantee — but parsing
## C/C++ source instead of Nim source.
##
## Scope of this milestone (Mode 3 C/C++ pilot):
##   * Recognise C/C++ ``executable`` / ``library`` members declared in
##     a workspace's ``repro.nim`` / ``reprobuild.nim`` files. Detection
##     piggy-backs on the layout convention: a member is C/C++ iff
##     ``<projectRoot>/src/`` contains at least one ``.c`` / ``.cpp`` /
##     ``.cc`` / ``.cxx`` file. The scanner declines to emit edges for
##     members whose layout doesn't match (a Nim member declared next to
##     a C file would still parse as Nim by the Nim scanner; the two
##     scanners coexist and operate on the same workspace).
##   * For each member, walk ``<projectRoot>/src/`` AND
##     ``<projectRoot>/include/`` recursively for C/C++ source/header
##     files.
##   * Parse ``#include "..."`` lines (the quoted form). The angle-
##     bracket form ``#include <...>`` is treated as ecosystem-external
##     and never emits an edge — that's the spec's filter for "system or
##     third-party header".
##   * Resolve each include path against the set of other packages'
##     ``include/`` and ``src/`` roots. A match emits one ``DepEdge``
##     ``(fromPackage, toPackage, evidence)``.
##   * Emit edges sorted by ``(fromPackage, toPackage, evidence)`` so
##     the output is byte-deterministic across runs and across hosts.
##
## Out of scope (documented as outstanding):
##   * Conditional ``#ifdef``/``#if`` branches — the scanner reads them
##     as if always taken. Edges that only manifest under a specific
##     ``-D`` define are over-emitted on the conservative side; the spec
##     calls out manual ``depends_on`` overrides as the suppression
##     mechanism.
##   * Forward-declared types that the user threads through a header
##     without ``#include``-ing it (rare; the manual override applies).
##   * C++20 modules ``import std.foo;`` — the C/C++ plain convention
##     explicitly excludes module-using projects, and the scanner
##     follows suit.
##
## The scanner shares the ``WorkspaceMember`` / ``DepEdge`` /
## ``ScanResult`` types with ``./nim_dep_scanner.nim`` so the
## ``repro deps refresh`` driver can merge the two passes' output into a
## single ``repro.scanned-deps.nim``.

import std/[algorithm, os, sets, strutils, tables]

import ./go_dep_scanner
import ./jsts_dep_scanner
import ./nim_dep_scanner
import ./paths
import ./project_file
import ./python_dep_scanner
import ./rust_dep_scanner

const
  CCppSourceExtensions* = [".c", ".cc", ".cpp", ".cxx", ".m", ".mm"]
    ## File extensions the scanner treats as C/C++ compilation units.
    ## ObjC sources are included for layout-recognition completeness;
    ## the convention currently emits compile actions only for ``.c`` /
    ## ``.cpp`` (the ObjC drivers are a follow-up).
  CCppHeaderExtensions* = [".h", ".hh", ".hpp", ".hxx", ".inl"]
    ## File extensions the scanner treats as C/C++ headers. The scanner
    ## walks headers AND sources looking for ``#include`` lines so a
    ## library's public header that itself ``#include``s another
    ## library's header still produces the transitive edge.

# ----------------------------------------------------------------------
# Member discovery — read project files and pull out executable/library
# declarations whose source layout looks like C/C++ (a ``.c``/``.cpp``
# file under ``src/``). Members whose layout doesn't match are skipped;
# a Nim-only repo therefore produces zero C/C++ members and the scanner
# falls back to a no-op.
# ----------------------------------------------------------------------

proc extractCCppMembersFromProjectFile(projectFile: string):
    seq[tuple[package: string; kind: string; name: string]] =
  ## Mirror of ``nim_dep_scanner.extractMembersFromProjectFile`` for the
  ## C/C++ side. We don't reuse that function because the ``WorkspaceMember``
  ## layer doesn't carry language information — every member discovered
  ## by either scanner ends up in the same ``WorkspaceMember`` seq —
  ## but the per-language filter (does the package look like C/C++?)
  ## lives at the C/C++ scanner's discovery step.
  ##
  ## The text scan itself is identical to the Nim scanner's. We just
  ## return the raw declarations without filtering; the caller filters
  ## by layout.
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

proc isCCppSourceFile*(path: string): bool =
  ## True when ``path``'s extension matches a C/C++ compilation unit.
  let lower = path.toLowerAscii
  for ext in CCppSourceExtensions:
    if lower.endsWith(ext):
      return true
  false

proc isCCppHeaderFile*(path: string): bool =
  ## True when ``path``'s extension matches a C/C++ header. Used to
  ## decide whether to walk a file for ``#include`` lines (headers count
  ## as sources for the include graph).
  let lower = path.toLowerAscii
  for ext in CCppHeaderExtensions:
    if lower.endsWith(ext):
      return true
  false

proc dirHasCCppSources(dir: string): bool =
  ## True when ``dir`` (or any nested subdir) contains a ``.c``/``.cpp``/
  ## etc file. Used as the layout filter — directories with no C/C++
  ## sources never contribute to the C/C++ scanner's member list.
  if not dirExists(extendedPath(dir)):
    return false
  for path in walkDirRec(dir):
    if isCCppSourceFile(path):
      return true
  false

proc resolveMemberDirs*(projectRoot, memberName: string):
    tuple[srcDir: string; includeDir: string; entrySource: string] =
  ## Resolve a single member's ``src/`` + ``include/`` directories under
  ## a project root. Supports BOTH the canonical Mode 3 layout shapes:
  ##
  ##   Layout A — one package per project file:
  ##     <projectRoot>/src/<sources>.c
  ##     <projectRoot>/include/<headers>.h
  ##
  ##   Layout B — multiple packages per project file:
  ##     <projectRoot>/<memberName>/src/<sources>.c
  ##     <projectRoot>/<memberName>/include/<headers>.h
  ##
  ## Layout B is tried FIRST because layout A's directories are also
  ## present in a layout-B workspace (every package's subdir contains
  ## its own ``src/`` and ``include/`` — but the workspace root itself
  ## does NOT have ``src/``/``include/`` directly). The opposite is not
  ## true: layout A's project root has ``src/`` and ``include/`` but no
  ## ``<memberName>/`` subdir. The order keeps the two unambiguous.
  ##
  ## Returns empty strings on all three fields when neither layout
  ## matches.
  let subdirSrc = projectRoot / memberName / "src"
  let subdirInclude = projectRoot / memberName / "include"
  if dirHasCCppSources(subdirSrc):
    result.srcDir = subdirSrc
    if dirExists(extendedPath(subdirInclude)):
      result.includeDir = subdirInclude
    # Entry source: first matching ``<src>/<member>.{c,cpp}`` or
    # ``<src>/main.{c,cpp}``.
    for ext in CCppSourceExtensions:
      let cand = subdirSrc / (memberName & ext)
      if fileExists(extendedPath(cand)):
        result.entrySource = cand
        return
      let mainCand = subdirSrc / ("main" & ext)
      if fileExists(extendedPath(mainCand)):
        result.entrySource = mainCand
        return
    # Fall back to any source under src/.
    for path in walkDirRec(subdirSrc):
      if isCCppSourceFile(path):
        result.entrySource = path
        return
    return
  let topSrc = projectRoot / "src"
  let topInclude = projectRoot / "include"
  if dirHasCCppSources(topSrc):
    result.srcDir = topSrc
    if dirExists(extendedPath(topInclude)):
      result.includeDir = topInclude
    for ext in CCppSourceExtensions:
      let cand = topSrc / (memberName & ext)
      if fileExists(extendedPath(cand)):
        result.entrySource = cand
        return
      let mainCand = topSrc / ("main" & ext)
      if fileExists(extendedPath(mainCand)):
        result.entrySource = mainCand
        return
    for path in walkDirRec(topSrc):
      if isCCppSourceFile(path):
        result.entrySource = path
        return

proc discoverCCppMembers*(workspaceRoot: string): seq[WorkspaceMember] =
  ## Walk ``workspaceRoot`` for every project file and produce one
  ## ``WorkspaceMember`` per ``executable`` / ``library`` declared in a
  ## ``package`` block whose layout matches one of the two canonical
  ## C/C++ Mode 3 shapes (see ``resolveMemberDirs``). Members whose
  ## layout doesn't match are silently skipped — they belong to
  ## another language's scanner.
  ##
  ## The walk skips ``.repro/``, ``.git/``, ``node_modules/``,
  ## ``.nimcache/``, ``.cargo/``, and ``target/`` — same as the Nim
  ## scanner — so a build's intermediates never pollute the member set.
  if not dirExists(extendedPath(workspaceRoot)):
    return @[]
  var queue: seq[string] = @[workspaceRoot]
  while queue.len > 0:
    let dir = queue[0]
    queue.delete(0)
    let match = resolveProjectFile(dir)
    if match.path.len > 0:
      for decl in extractCCppMembersFromProjectFile(match.path):
        let resolved = resolveMemberDirs(dir, decl.name)
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
# Include extraction. The scanner is intentionally NOT a C preprocessor:
# building one is far out of scope for the milestone. The line-scan
# below extracts every ``#include "..."`` (quoted form) at any column
# and treats ``#include <...>`` as ecosystem-external regardless of
# whether the surrounded path would resolve to a workspace header.
# ----------------------------------------------------------------------

type
  CCppIncludeRef* = object
    ## One ``#include "..."`` statement extracted from a source/header
    ## file.
    target*: string
      ## The bareword path between the quotes — e.g. ``"foo/bar.h"`` →
      ## ``foo/bar.h``. Resolution against workspace roots is the
      ## caller's job.
    lineNumber*: int
      ## 1-based line number where the include was found.
    raw*: string
      ## The stripped source line for the evidence string.

proc stripCCppLineComment(line: string): string =
  ## Drop everything after the first ``//`` that isn't inside a string
  ## literal. Block comments ``/* ... */`` are NOT handled — they're
  ## rare in ``#include`` regions of real codebases, and the cost of a
  ## stateful scanner would dwarf the rest of the milestone. A rogue
  ## block-comment-wrapped include would produce at most a spurious
  ## edge that the user can suppress via manual override per spec
  ## §"Manual override".
  var inString = false
  var i = 0
  while i < line.len:
    let ch = line[i]
    if not inString:
      if ch == '/' and i + 1 < line.len and line[i + 1] == '/':
        return line[0 ..< i]
      if ch == '"':
        inString = true
    else:
      if ch == '\\' and i + 1 < line.len:
        # Skip the escaped char so an escaped quote inside a string
        # literal doesn't close the string.
        inc i
      elif ch == '"':
        inString = false
    inc i
  line

proc extractCCppIncludes*(sourceText: string): seq[CCppIncludeRef] =
  ## Walk ``sourceText`` line-by-line and emit every recognised
  ## ``#include "..."`` directive. Angle-bracketed includes (``#include
  ## <...>``) are intentionally ignored — they're the spec's filter for
  ## "system or third-party" and never produce a workspace edge.
  ##
  ## The scan accepts arbitrary leading whitespace before ``#`` (some
  ## styles indent ``#`` inside ``#ifdef`` blocks) and arbitrary
  ## whitespace between ``#``, ``include``, and the opening quote.
  var lineNo = 0
  for rawLine in sourceText.splitLines():
    inc lineNo
    let cleaned = stripCCppLineComment(rawLine)
    let stripped = cleaned.strip()
    if stripped.len == 0:
      continue
    if not stripped.startsWith("#"):
      continue
    # Skip the ``#`` and any whitespace before ``include``.
    var rest = stripped[1 .. ^1].strip()
    if not rest.startsWith("include"):
      continue
    rest = rest[len("include") .. ^1]
    # The next non-whitespace char decides the include flavor.
    let trimmed = rest.strip()
    if trimmed.len == 0:
      continue
    if trimmed[0] != '"':
      # ``#include <...>`` or some other macro form — out of scope.
      continue
    # Find the closing quote.
    let closeIdx = trimmed.find('"', start = 1)
    if closeIdx <= 1:
      continue
    let target = trimmed[1 ..< closeIdx]
    if target.len == 0:
      continue
    result.add(CCppIncludeRef(
      target: target,
      lineNumber: lineNo,
      raw: stripped))

# ----------------------------------------------------------------------
# Resolution. For each member we precompute its "header search roots" —
# the directories another package's source could ``#include "x/y.h"``
# from and have it resolve to one of THIS member's headers. The standard
# layout is ``<projectRoot>/include/`` (the public header dir) plus
# ``<projectRoot>/src/`` (when an internal header is exposed). The
# scanner indexes header paths relative to each root so a quoted include
# like ``"mathlib/add.h"`` can be matched against ``<root>/mathlib/add.h``.
# ----------------------------------------------------------------------

type
  PackageHeaderRoot = object
    package: string
    member: string
    root: string
    relativeHeader: string  ## "mathlib/add.h" style
    absolutePath: string

proc collectHeaderRoots(member: WorkspaceMember): seq[string] =
  ## Return the directories the scanner considers public header roots
  ## for a member. The per-member ``include/`` is the canonical public
  ## root; ``src/`` is a fallback for the "headers live next to sources"
  ## layout. Layout A vs Layout B is resolved by ``resolveMemberDirs``.
  let resolved = resolveMemberDirs(member.projectRoot, member.member)
  if resolved.includeDir.len > 0 and
      dirExists(extendedPath(resolved.includeDir)):
    result.add(resolved.includeDir)
  if resolved.srcDir.len > 0 and dirExists(extendedPath(resolved.srcDir)):
    result.add(resolved.srcDir)

proc collectMemberHeaders(member: WorkspaceMember): seq[PackageHeaderRoot] =
  ## Enumerate every header file under each of the member's search
  ## roots and emit the ``(root, relative, absolute)`` triples the
  ## resolver compares quoted includes against.
  for root in collectHeaderRoots(member):
    if not dirExists(extendedPath(root)):
      continue
    for path in walkDirRec(root):
      if not isCCppHeaderFile(path):
        continue
      var rel: string
      try:
        rel = relativePath(path, root)
      except OSError:
        continue
      rel = rel.replace('\\', '/')
      result.add(PackageHeaderRoot(
        package: member.package,
        member: member.member,
        root: root,
        relativeHeader: rel,
        absolutePath: path))

proc collectScanSources(member: WorkspaceMember): seq[string] =
  ## Sources + headers a member contributes to the include graph. The
  ## scanner walks each one for ``#include "..."`` lines and matches
  ## the quoted target against the workspace index.
  let resolved = resolveMemberDirs(member.projectRoot, member.member)
  var scanRoots: seq[string] = @[]
  if resolved.srcDir.len > 0:
    scanRoots.add(resolved.srcDir)
  if resolved.includeDir.len > 0:
    scanRoots.add(resolved.includeDir)
  for root in scanRoots:
    if not dirExists(extendedPath(root)):
      continue
    for path in walkDirRec(root):
      if isCCppSourceFile(path) or isCCppHeaderFile(path):
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

proc scanWorkspaceCpp*(workspaceRoot: string): ScanResult =
  ## Top-level C/C++ scanner entry point. Discovers members, builds the
  ## ``relativeHeader`` → ``package`` index, walks each member's
  ## sources + headers, resolves quoted includes, emits a sorted
  ## edge list.
  let members = discoverCCppMembers(workspaceRoot)
  result.members = members
  if members.len == 0:
    return

  # Header index: every ``relativeHeader`` -> owning package.
  # Two packages exposing the same relative header is a collision; we
  # keep the first one (declaration-order-sorted) and the rest are
  # treated as "ambiguous, don't emit". This matches the spec's
  # "partial layout match" disposition (diagnose, don't silently
  # mis-resolve).
  #
  # Multi-package-per-project-file caveat: two members declared in the
  # same ``repro.nim`` share a ``projectRoot``, so walking each
  # member's ``include/`` reports the same headers twice. We dedup by
  # absolute path so the second pass doesn't fire the ambiguous-package
  # branch on a header that's actually owned by exactly one package
  # (the FIRST declared in the project file wins — declaration-order
  # sort gave us that already).
  var headerIndex = initTable[string, string]()
  var ambiguous = initHashSet[string]()
  var seenAbsPath = initHashSet[string]()
  for m in members:
    for hdr in collectMemberHeaders(m):
      if seenAbsPath.contains(hdr.absolutePath):
        continue
      seenAbsPath.incl(hdr.absolutePath)
      if ambiguous.contains(hdr.relativeHeader):
        continue
      if headerIndex.hasKey(hdr.relativeHeader):
        if headerIndex[hdr.relativeHeader] != m.package:
          ambiguous.incl(hdr.relativeHeader)
          headerIndex.del(hdr.relativeHeader)
        continue
      headerIndex[hdr.relativeHeader] = m.package

  var allEdges: seq[DepEdge] = @[]
  for m in members:
    var seen = initTable[string, bool]()
    for sourcePath in collectScanSources(m):
      let text =
        try:
          readFile(extendedPath(sourcePath))
        except CatchableError:
          continue
      for inc in extractCCppIncludes(text):
        let normalised = inc.target.replace('\\', '/')
        if not headerIndex.hasKey(normalised):
          continue
        let toPackage = headerIndex[normalised]
        if toPackage == m.package:
          continue
        let evidence = relativeEvidence(workspaceRoot, sourcePath,
          inc.lineNumber, inc.raw)
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

# ----------------------------------------------------------------------
# Unified workspace scan — runs the Nim scanner first, the C/C++
# scanner second, merges both members lists and edges lists, and
# returns a single deterministic ``ScanResult``. This is what the
# ``repro deps refresh`` CLI calls.
# ----------------------------------------------------------------------

proc mergeScanResults*(nimScan, cppScan: ScanResult): ScanResult =
  ## Combine two language scanner outputs into one ``ScanResult`` with
  ## deduplicated members and sorted edges. The Nim scanner currently
  ## discovers EVERY member (Nim doesn't filter by layout because the
  ## scanner predates the multi-language requirement), so a C/C++
  ## member can appear in both seq — the merge deduplicates on
  ## ``(package, member)`` and prefers the C/C++ scanner's
  ## ``WorkspaceMember`` entry when both are present (its ``sourceFile``
  ## points at the C source rather than at a non-existent
  ## ``src/<member>.nim``).
  var seenMembers = initTable[string, bool]()
  # C/C++ first so its WorkspaceMember entries win on collisions.
  for m in cppScan.members:
    let key = m.package & "\x1f" & m.member
    if seenMembers.getOrDefault(key, false):
      continue
    seenMembers[key] = true
    result.members.add(m)
  for m in nimScan.members:
    let key = m.package & "\x1f" & m.member
    if seenMembers.getOrDefault(key, false):
      continue
    seenMembers[key] = true
    result.members.add(m)
  result.members.sort(proc (a, b: WorkspaceMember): int =
    cmp((a.package, a.member), (b.package, b.member)))

  # Edges union, deduped on (from, to, evidence).
  var seenEdges = initTable[string, bool]()
  for e in nimScan.edges:
    let key = e.fromPackage & "\x1f" & e.toPackage & "\x1f" & e.evidence
    if seenEdges.getOrDefault(key, false):
      continue
    seenEdges[key] = true
    result.edges.add(e)
  for e in cppScan.edges:
    let key = e.fromPackage & "\x1f" & e.toPackage & "\x1f" & e.evidence
    if seenEdges.getOrDefault(key, false):
      continue
    seenEdges[key] = true
    result.edges.add(e)
  result.edges.sort(proc (a, b: DepEdge): int =
    let c1 = cmp(a.fromPackage, b.fromPackage)
    if c1 != 0: return c1
    let c2 = cmp(a.toPackage, b.toPackage)
    if c2 != 0: return c2
    cmp(a.evidence, b.evidence))

  # Diagnostics union (both seqs are empty today; future-proof).
  for d in nimScan.diagnostics:
    result.diagnostics.add(d)
  for d in cppScan.diagnostics:
    result.diagnostics.add(d)

proc scanWorkspaceAll*(workspaceRoot: string): ScanResult =
  ## Run the Nim, C/C++, Rust, Go, Python, and JS/TS scanners over
  ## ``workspaceRoot`` and merge their outputs into a single
  ## deterministic ``ScanResult``. This is the entry point
  ## ``repro deps refresh`` calls.
  ##
  ## M30 added the Rust scanner. M31 added the Go scanner. M32 added
  ## the Python scanner. M33 added the JS/TS scanner. The merge order
  ## keeps the C/C++, Rust, Go, Python, and JS/TS scanners'
  ## ``WorkspaceMember`` entries winning on collisions with the Nim
  ## scanner — all five of the newer scanners filter by layout (only
  ## members whose source dir looks like that language appear in their
  ## member list), so when both fire for the same ``(package, member)``
  ## pair their entry's ``sourceFile`` points at the real source file,
  ## not at a non-existent ``src/<member>.nim``.
  let nimScan = scanWorkspace(workspaceRoot)
  let cppScan = scanWorkspaceCpp(workspaceRoot)
  let rustScan = scanWorkspaceRust(workspaceRoot)
  let goScan = scanWorkspaceGo(workspaceRoot)
  let pythonScan = scanWorkspacePython(workspaceRoot)
  let jsTsScan = scanWorkspaceJsTs(workspaceRoot)
  let nimCpp = mergeScanResults(nimScan, cppScan)
  let withRust = mergeScanResults(nimCpp, rustScan)
  let withGo = mergeScanResults(withRust, goScan)
  let withPython = mergeScanResults(withGo, pythonScan)
  mergeScanResults(withPython, jsTsScan)
