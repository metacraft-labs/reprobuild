## Mode 3 Nim dependency scanner.
##
## Walks a Nim workspace and emits a deterministic dep graph naming
## **only** the inter-workspace package edges. The scanner is the
## shared implementation behind Mode 1 (in-memory) and Mode 3 (persisted
## to ``repro.scanned-deps.nim``) per
## ``reprobuild-specs/Three-Mode-Convention-System.md`` §"The scanner
## contract".
##
## Scope of this milestone (Mode 3 Nim pilot):
##   * Recognise Nim ``executable`` / ``library`` members declared in a
##     workspace's ``repro.nim`` / ``reprobuild.nim`` files.
##   * For each member, walk its source tree (``<projectRoot>/src/``,
##     where ``projectRoot`` is the directory of the project file).
##   * Parse Nim ``import`` / ``from ... import`` / ``include "..."``
##     statements with a minimal line-scan (no full Nim parser).
##   * Resolve each import to ANOTHER workspace member when the leading
##     module path matches that member's declared name (case-folded,
##     ``snake_case`` and ``kebab-case`` collapsed to a normalised
##     identifier so ``my_lib`` / ``my-lib`` / ``myLib`` all match).
##   * Emit edges sorted by (fromPackage, toPackage, evidence) so the
##     output is byte-deterministic across runs.
##
## Out of scope (documented as outstanding):
##   * Imports of Nimble dependencies that happen to share a name with
##     a workspace member. The scanner does NOT consult ``.nimble``
##     files to disambiguate; it treats every matching import as a
##     workspace edge. Real conflicts are vanishingly rare for the
##     dogfooding target but a future M can fold in ``.nimble`` lookup.
##   * Conditional ``when defined(...): import x`` branches. We walk
##     them as if always taken; the scanner is conservative on the
##     "too many edges" side and the user can override via a manual
##     ``depends_on`` in ``repro.nim`` (per spec §"Manual override").
##   * Imports inside multi-line string literals or comments — see
##     the per-line strip logic below.

import std/[algorithm, os, strutils, tables]

import ./project_file

type
  WorkspaceMember* = object
    ## Single ``executable`` or ``library`` declaration discovered in a
    ## workspace project file. The scanner builds one of these per
    ## member and uses it both as a node in the dep graph AND as a
    ## resolution target for import lookups in other members' sources.
    package*: string
      ## The ``package`` identifier the member was declared inside.
      ## Used as the edge's ``from`` / ``to`` label so the generated
      ## ``repro.scanned-deps.nim`` reads as ``depends_on <pkg>: <pkg>``.
    member*: string
      ## The member's own name (``executable foo`` → ``foo``). Multiple
      ## members can share a package; their source dirs are the same
      ## ``<projectRoot>/src/`` and they may import each other's
      ## umbrella modules without producing an edge (a package never
      ## depends on itself).
    projectFile*: string
      ## Absolute path to the project file (``repro.nim`` /
      ## ``reprobuild.nim``) the member was declared in.
    projectRoot*: string
      ## Absolute path to the directory containing the project file.
      ## Used as the search root for source files when scanning imports.
    sourceFile*: string
      ## Absolute path to the entry source module the convention will
      ## compile (``<projectRoot>/src/<member>.nim``). May be empty
      ## when the file doesn't exist on disk; the scanner still records
      ## the member but skips source-walk for it.

  DepEdge* = object
    ## One scanned dep edge: ``fromPackage`` depends on ``toPackage``,
    ## proven by the import at ``evidence``. The triple is what's
    ## written to ``repro.scanned-deps.nim``; the evidence string is
    ## kept for future ``repro show-conventions`` / review-diff use,
    ## even though the file shape in this milestone embeds only the
    ## ``depends_on`` line (the evidence comment is generated alongside
    ## per spec §"`repro.scanned-deps.nim` file shape").
    fromPackage*: string
    toPackage*: string
    evidence*: string
      ## Human-readable evidence line of the form
      ## ``"src/foo.nim:12: import bar"`` (relative to the workspace
      ## root). Stable across runs because the line number is read
      ## directly from the parser; sort order uses the evidence string
      ## as a secondary key so two edges with the same endpoints stay
      ## adjacent for diff readability.

  ScanResult* = object
    ## Output of one scanner invocation. The scanner does NOT cache
    ## across invocations — every call walks the workspace fresh —
    ## but the result is a pure function of the source tree, so
    ## callers may cache externally if they like.
    members*: seq[WorkspaceMember]
    edges*: seq[DepEdge]
    diagnostics*: seq[string]
      ## Non-fatal observations. Today this is empty; the spec calls
      ## out "partial layout match" cases as a future addition. Kept
      ## as a seq so the wire shape is stable when those land.

# ----------------------------------------------------------------------
# Member discovery — read project files and pull out executable/library
# declarations. We reuse the same line-scanner heuristic as
# ``conventions/nim.nim`` (the Mode 2 Nim convention); see that file's
# extractEntrypoints/extractLibraries for the contract.
# ----------------------------------------------------------------------

proc stripLineComment(line: string): string =
  ## Drop everything after the first ``#`` that isn't inside a string
  ## literal. The scanner's source files are Nim — Nim comments start
  ## with ``#`` (line) or ``#[ ... ]#`` (block). We only handle the
  ## line form here; the block form is rare in import sections and
  ## skipping it produces at most a spurious edge (which the user can
  ## suppress per the spec §"Manual override").
  var inString = false
  var inChar = false
  for i, ch in line:
    if not inString and not inChar and ch == '#':
      return line[0 ..< i]
    if not inChar and ch == '"' and (i == 0 or line[i - 1] != '\\'):
      inString = not inString
    elif not inString and ch == '\'' and (i == 0 or line[i - 1] != '\\'):
      inChar = not inChar
  line

proc normaliseName*(text: string): string =
  ## Collapse ``snake_case`` / ``kebab-case`` / ``camelCase`` so two
  ## spellings of the same Nim package name compare equal.
  ##
  ## Examples:
  ##   ``"my_lib"`` → ``"mylib"``
  ##   ``"my-lib"`` → ``"mylib"``
  ##   ``"myLib"``  → ``"mylib"``
  ##
  ## We intentionally drop ``_`` and ``-`` rather than substituting
  ## them; Nim's import resolution is case-insensitive and
  ## underscore-insensitive (the ``style.nim`` style-insensitive
  ## identifier match), so two of these forms identify the same module
  ## from the compiler's perspective. The scanner mirrors that rule.
  for ch in text:
    if ch in {'_', '-'}:
      continue
    result.add(ch.toLowerAscii)

type
  ProjectMemberDecl = object
    package: string
    kind: string  ## "executable" or "library"
    name: string

proc extractMembersFromProjectFile(projectFile: string):
    seq[ProjectMemberDecl] =
  ## Mirror of ``conventions/nim.nim``'s ``extractEntrypoints`` +
  ## ``extractLibraries`` heuristics, extended to handle MULTIPLE
  ## ``package`` blocks in a single project file (the Mode 3 shape).
  ## Each member declaration is tagged with the most recent ``package
  ## <name>`` keyword the scanner has seen, so when the project file
  ## declares two packages back-to-back the members partition correctly.
  ##
  ## We don't import the Mode 2 ``conventions/nim.nim`` scanner here
  ## because it lives under ``repro_standard_provider`` (a higher-level
  ## library) and ``repro_core`` is the lowest layer in the dependency
  ## DAG; pulling it down would invert the layering. The duplication
  ## is intentional.
  if not fileExists(projectFile):
    return @[]
  let raw =
    try:
      readFile(projectFile)
    except CatchableError:
      return @[]
  var pkg = ""
  for rawLine in raw.splitLines():
    let cleaned = stripLineComment(rawLine)
    let stripped = cleaned.strip()
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
        result.add(ProjectMemberDecl(
          package: pkg, kind: "executable", name: name))
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
        result.add(ProjectMemberDecl(
          package: pkg, kind: "library", name: name))

proc discoverMembers*(workspaceRoot: string): seq[WorkspaceMember] =
  ## Walk ``workspaceRoot`` for every project file (``repro.nim`` or
  ## ``reprobuild.nim``) and produce one ``WorkspaceMember`` per
  ## executable/library declared in each. The walk is breadth-first by
  ## directory and skips ``.repro/`` (the build scratch dir) and
  ## ``node_modules/`` / ``.git/`` (commonly large dirs that never
  ## contain a Nim workspace).
  ##
  ## A single ``repro.nim`` can declare multiple members (the existing
  ## ``nim/multi-binary`` fixture is the canonical example). Each
  ## member becomes its own node in the dep graph.
  if not dirExists(workspaceRoot):
    return @[]
  var queue: seq[string] = @[workspaceRoot]
  while queue.len > 0:
    let dir = queue[0]
    queue.delete(0)
    let match = resolveProjectFile(dir)
    if match.path.len > 0:
      for decl in extractMembersFromProjectFile(match.path):
        let srcFile = dir / "src" / (decl.name & ".nim")
        result.add(WorkspaceMember(
          package: decl.package,
          member: decl.name,
          projectFile: match.path,
          projectRoot: dir,
          sourceFile: if fileExists(srcFile): srcFile else: ""))
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
# Import extraction — line-scan a Nim source for ``import`` / ``from``
# / ``include`` statements and return the first module token of each.
# This is intentionally NOT a Nim AST parser: building one would dwarf
# the rest of the milestone. The line-scan agrees with the Mode 2
# convention's own heuristic-grade scanners on the same project files.
# ----------------------------------------------------------------------

type
  ImportRef* = object
    ## One import-like statement extracted from a Nim source file.
    moduleHead*: string
      ## The first path segment of the imported module — what we'll
      ## try to match against another workspace member's name.
      ## For ``import foo/bar/baz`` the head is ``foo``; for ``import
      ## foo`` it's ``foo``. For ``from foo/bar import x`` the head is
      ## ``foo``. For ``include "foo/bar.nim"`` the head is ``foo``.
    lineNumber*: int
      ## 1-based line number where the import was discovered. Folded
      ## into the ``evidence`` string so downstream consumers can jump
      ## to the source location.
    raw*: string
      ## The stripped source line, with the leading whitespace
      ## removed and the trailing comment dropped. Used as the
      ## ``evidence`` payload.

proc parseImportLine(stripped: string): seq[string] =
  ## Return every module path mentioned on a single ``import`` /
  ## ``from`` / ``include`` line. A bare ``import foo`` yields
  ## ``["foo"]``; ``import foo, bar, baz`` yields ``["foo", "bar",
  ## "baz"]``; ``include "foo/bar.nim"`` yields ``["foo/bar.nim"]``.
  ##
  ## Tokens are returned with their wrapping quotes stripped so the
  ## caller can split on ``/`` to find the head segment.
  if stripped.startsWith("import "):
    let payload = stripped[len("import ") .. ^1]
    for part in payload.split(','):
      let token = part.strip().strip(chars = {'"', '\''})
      if token.len == 0 or token == "_":
        continue
      # Drop ``as foo`` / ``except foo`` clauses.
      var head = token
      for sep in [" as ", " except "]:
        let idx = head.find(sep)
        if idx >= 0:
          head = head[0 ..< idx]
      result.add(head.strip())
  elif stripped.startsWith("from "):
    let payload = stripped[len("from ") .. ^1]
    let importIdx = payload.find(" import")
    let module =
      if importIdx >= 0: payload[0 ..< importIdx]
      else: payload
    let token = module.strip().strip(chars = {'"', '\''})
    if token.len > 0:
      result.add(token)
  elif stripped.startsWith("include "):
    let payload = stripped[len("include ") .. ^1]
    for part in payload.split(','):
      let token = part.strip().strip(chars = {'"', '\''})
      if token.len == 0:
        continue
      result.add(token)

proc extractImports*(sourceText: string): seq[ImportRef] =
  ## Walk ``sourceText`` line-by-line and emit every recognised
  ## ``import`` / ``from`` / ``include`` head module. The scan stops
  ## at the first non-whitespace line that isn't an import-like
  ## statement OR a blank/comment line — the rationale being that
  ## hand-written Nim modules group their imports at the top, and we
  ## want to skip ``import`` strings buried inside string literals
  ## that the comment-stripper isn't sophisticated enough to handle.
  ##
  ## **Update**: that heuristic turns out to be too aggressive for
  ## test files that interleave ``import`` lines with ``proc`` defs.
  ## We instead scan the WHOLE file and accept any line that starts
  ## with ``import`` / ``from`` / ``include`` at any indentation
  ## level — the rare false positive on a multi-line string literal
  ## is suppressible via manual override.
  var lineNo = 0
  for rawLine in sourceText.splitLines():
    inc lineNo
    let cleaned = stripLineComment(rawLine)
    let stripped = cleaned.strip()
    if stripped.len == 0:
      continue
    if not (stripped.startsWith("import ") or stripped.startsWith("from ") or
        stripped.startsWith("include ")):
      continue
    for module in parseImportLine(stripped):
      # Drop the file extension (``include "foo/bar.nim"`` → ``foo/bar``)
      # so the head-segment lookup is consistent with ``import foo/bar``.
      var clean = module
      if clean.toLowerAscii.endsWith(".nim"):
        clean = clean[0 ..< clean.len - len(".nim")]
      let segments = clean.replace('\\', '/').split('/')
      if segments.len == 0:
        continue
      let head = segments[0].strip()
      if head.len == 0:
        continue
      result.add(ImportRef(
        moduleHead: head,
        lineNumber: lineNo,
        raw: stripped))

# ----------------------------------------------------------------------
# Stdlib filter. Nim's stdlib modules are top-level identifiers like
# ``os``, ``strutils``, ``tables``. We don't have an authoritative list
# at this layer (the Nim compiler does), so we keep a generous static
# set sourced from
# https://nim-lang.org/docs/lib.html and from the Nim system module
# index. Any import head matching this set is treated as stdlib and
# never produces an edge.
# ----------------------------------------------------------------------

const StdlibModules = [
  "algorithm", "ascii", "async", "asyncdispatch", "asyncfile", "asyncfutures",
  "asynchttpserver", "asyncnet", "asyncstreams", "atomics", "base64",
  "bitops", "browsers", "cgi", "channels", "complex", "cookies", "cpuinfo",
  "critbits", "cstrutils", "db_common", "db_mysql", "db_postgres",
  "db_sqlite", "decls", "deques", "distros", "dynlib", "editdistance",
  "encodings", "endians", "enumerate", "enumutils", "exitprocs",
  "fenv", "files", "genasts", "hashes", "heapqueue", "hotcodereloading",
  "htmlgen", "htmlparser", "httpclient", "httpcore", "imageio", "importutils",
  "intsets", "io", "isolation", "json", "jsonutils", "lenientops", "lexbase",
  "lists", "locks", "logging", "macrocache", "macros", "marshal", "math",
  "md5", "memfiles", "mimetypes", "monotimes", "nativesockets", "net",
  "nimprof", "nre", "objectdollar", "oids", "openssl", "options", "os",
  "osproc", "packedsets", "parsecfg", "parsecsv", "parsejson", "parseopt",
  "parsesql", "parseutils", "paths", "pathnorm", "pegs", "perm", "posix",
  "posix_utils", "prelude", "private", "pylib", "random", "rationals",
  "rdstdin", "registry", "repr", "reservedmem", "rlocks", "ropes",
  "rtarrays", "selectors", "sequtils", "setutils", "sets", "sha1",
  "smtp", "ssl_certs", "stats", "std", "stdio", "streams", "strbasics",
  "strformat", "strmisc", "strscans", "strtabs", "strutils", "sugar",
  "symbol", "syncio", "syslog", "tables", "tasks", "tempfiles", "terminal",
  "threadpool", "times", "tinyc", "typedthreads", "typeinfo", "typetraits",
  "unicode", "unidecode", "unittest", "uri", "varints", "volatile",
  "wordwrap", "wrapnils", "xmlparser", "xmltree", "system"
]

proc isStdlibImport*(head: string): bool =
  ## True when the head segment belongs to Nim's standard library and
  ## should be ignored. ``std/foo/bar`` imports normalise to ``std`` at
  ## the head and are caught by the explicit ``"std"`` entry.
  let lower = head.toLowerAscii
  for entry in StdlibModules:
    if entry == lower:
      return true
  false

# ----------------------------------------------------------------------
# The actual scan. Take a set of members; for each member, walk its
# source dir; for each source file, extract imports; for each import,
# look up the head against the member name index; emit one edge per
# matched head.
# ----------------------------------------------------------------------

proc relativeEvidence(workspaceRoot, sourceFile: string;
                      line: int; raw: string): string =
  ## Build the ``"<rel-path>:<line>: <raw>"`` evidence string. The
  ## relative path is computed against the workspace root, with path
  ## separators normalised to ``/`` so the output is byte-identical on
  ## Windows and POSIX.
  var rel =
    try:
      relativePath(sourceFile, workspaceRoot)
    except OSError:
      sourceFile
  rel = rel.replace('\\', '/')
  rel & ":" & $line & ": " & raw

proc transitiveSources(entrySource, srcDir: string): seq[string] =
  ## Return the set of ``.nim`` files reachable from ``entrySource`` via
  ## relative ``import`` / ``include`` statements that resolve under
  ## ``srcDir``. The walk is bounded — only files inside ``srcDir`` are
  ## followed, so the scanner never accidentally crosses workspace
  ## boundaries via a relative-path import. Files outside ``srcDir``
  ## are not added to the result and do not have their imports walked.
  ##
  ## Pragmatic boundaries for the M22-tier scanner:
  ##   * ``import foo`` resolves to ``<srcDir>/foo.nim`` when that file
  ##     exists. If it doesn't, the import is treated as either stdlib
  ##     or external (not a transitive source).
  ##   * ``import foo/bar`` resolves to ``<srcDir>/foo/bar.nim``.
  ##   * ``include "foo.nim"`` / ``include "foo/bar.nim"`` resolve the
  ##     same way (the include's target is a file path).
  ##
  ## This is intentionally a single-package-rooted resolution. The
  ## scanner does NOT attempt to follow imports across package
  ## boundaries — those are exactly the edges we want to emit, not
  ## walk.
  if entrySource.len == 0 or not fileExists(entrySource):
    return @[]
  result.add(entrySource)
  var visited: Table[string, bool]
  visited[entrySource] = true
  var queue: seq[string] = @[entrySource]
  while queue.len > 0:
    let path = queue[0]
    queue.delete(0)
    let text =
      try:
        readFile(path)
      except CatchableError:
        continue
    for imp in extractImports(text):
      # Reconstruct the full module path (with separators) the line
      # actually mentioned so we can map it to a file. The
      # ``moduleHead`` field carries only the first segment; we walk
      # the import line one more time to get the full token.
      let stripped = imp.raw
      var candidates: seq[string] = @[]
      for module in parseImportLine(stripped):
        var clean = module
        if clean.toLowerAscii.endsWith(".nim"):
          clean = clean[0 ..< clean.len - len(".nim")]
        candidates.add(clean.replace('\\', '/'))
      for cand in candidates:
        if cand.len == 0:
          continue
        let candPath = srcDir / cand.replace('/', DirSep) & ".nim"
        if not fileExists(candPath):
          continue
        if visited.getOrDefault(candPath, false):
          continue
        visited[candPath] = true
        result.add(candPath)
        queue.add(candPath)

proc scanMember(workspaceRoot: string; member: WorkspaceMember;
                memberIndex: Table[string, string]):
                  seq[DepEdge] =
  ## Walk a member's entry source plus its transitively-imported files
  ## (bounded to the same ``src/`` subtree); parse imports; resolve
  ## heads against ``memberIndex`` (normalised member-name → package
  ## name); emit edges. Self-edges (the member's package imports its
  ## own umbrella module) are suppressed; duplicate edges within the
  ## same member's walk are deduplicated by ``(toPackage, evidence)``
  ## so two imports of the same external module on different lines
  ## both surface in evidence but the dep edge itself is unique per
  ## source location.
  ##
  ## **Multi-package-per-project-file behaviour**: when two members
  ## share a ``src/`` tree (as in the Mode 3 pilot fixture), the
  ## scanner walks only the files reachable from each member's own
  ## entry source. That way ``src/hello.nim`` doesn't pollute the
  ## ``greet`` member's edge set with imports it doesn't actually own.
  if member.sourceFile.len == 0:
    return @[]
  let srcDir = member.projectRoot / "src"
  if not dirExists(srcDir):
    return @[]
  let files = transitiveSources(member.sourceFile, srcDir).sorted(
    system.cmp[string])
  var seen: Table[string, bool]
  for path in files:
    let text =
      try:
        readFile(path)
      except CatchableError:
        continue
    for imp in extractImports(text):
      if isStdlibImport(imp.moduleHead):
        continue
      let normalised = normaliseName(imp.moduleHead)
      if normalised.len == 0:
        continue
      if not memberIndex.hasKey(normalised):
        continue
      let toPackage = memberIndex[normalised]
      if toPackage == member.package:
        # Self-import (same package's umbrella module imported by
        # another file in the same package). Not a workspace edge.
        continue
      let evidence = relativeEvidence(workspaceRoot, path, imp.lineNumber,
        imp.raw)
      let key = toPackage & "\x1f" & evidence
      if seen.getOrDefault(key, false):
        continue
      seen[key] = true
      result.add(DepEdge(
        fromPackage: member.package,
        toPackage: toPackage,
        evidence: evidence))

proc scanWorkspace*(workspaceRoot: string): ScanResult =
  ## Top-level entry point. Discovers members, builds the
  ## normalised-name index, walks each member, returns a sorted
  ## ``ScanResult``.
  ##
  ## Determinism: the result is a pure function of the workspace
  ## contents. Two runs over the same tree produce a byte-identical
  ## ``ScanResult`` (modulo absolute paths in ``members``, which the
  ## caller does NOT serialise verbatim — see ``renderScannedDepsFile``
  ## for the byte-stable projection).
  let members = discoverMembers(workspaceRoot)
  result.members = members
  if members.len == 0:
    return
  var index: Table[string, string]
  for m in members:
    let key = normaliseName(m.member)
    if key.len == 0:
      continue
    # Last writer wins is fine here because the discovery order is
    # already deterministic (alphabetic by (package, member)) and the
    # underlying spec says workspace members can't share a name.
    index[key] = m.package
    # Also index by package name so an ``import packageName`` from
    # another member matches even when the package has no member with
    # exactly that name.
    let pkgKey = normaliseName(m.package)
    if pkgKey.len > 0 and not index.hasKey(pkgKey):
      index[pkgKey] = m.package
  var allEdges: seq[DepEdge] = @[]
  for m in members:
    for edge in scanMember(workspaceRoot, m, index):
      allEdges.add(edge)
  allEdges.sort(proc (a, b: DepEdge): int =
    let c1 = cmp(a.fromPackage, b.fromPackage)
    if c1 != 0: return c1
    let c2 = cmp(a.toPackage, b.toPackage)
    if c2 != 0: return c2
    cmp(a.evidence, b.evidence))
  result.edges = allEdges

# ----------------------------------------------------------------------
# Render ``repro.scanned-deps.nim``. The file shape is documented in
# ``Three-Mode-Convention-System.md`` §"`repro.scanned-deps.nim` file
# shape". The header is a ``DO NOT EDIT`` block; the body is a series
# of ``depends_on`` calls, one per scanned edge, grouped by fromPackage.
# ----------------------------------------------------------------------

const
  ScannerSchemaVersion* = "v1"
    ## Bump when the file shape changes in a way that breaks downstream
    ## ``include "repro.scanned-deps.nim"`` callers. Today there's only
    ## one schema, but the constant is exported so ``--check`` can
    ## detect a stale file emitted by a previous engine and warn rather
    ## than silently regenerating with the new shape.

proc renderScannedDepsFile*(edges: openArray[DepEdge];
                            engineVersion: string;
                            members: openArray[WorkspaceMember] = [];
                            workspaceRoot = ""): string =
  ## Produce the byte-deterministic text for ``repro.scanned-deps.nim``.
  ## Inputs:
  ##   * ``edges``: the sorted edge list from ``scanWorkspace``.
  ##   * ``engineVersion``: the ``ReprobuildVersion`` constant value.
  ##   * ``members`` / ``workspaceRoot``: optional, used only for the
  ##     header's "N targets scanned" line. When omitted the header
  ##     omits that line entirely so unit tests can render edge-only
  ##     fragments without surfacing path-dependent state.
  ##
  ## The file is plain Nim that ``import repro_project_dsl`` consumers
  ## evaluate at compile time (the ``depends_on`` macro expansion runs
  ## inline). The header is comment-only so any downstream Nim tool
  ## (``nim doc``, IDE go-to-definition, etc.) reads the file the same
  ## way the engine does.
  result = "# repro.scanned-deps.nim\n"
  result.add("#\n")
  result.add("# DO NOT EDIT — regenerated by `repro deps refresh`.\n")
  result.add("# Manual overrides belong in repro.nim.\n")
  result.add("#\n")
  result.add("# Engine version: " & engineVersion & "\n")
  result.add("# Scanner schema: " & ScannerSchemaVersion & "\n")
  if workspaceRoot.len > 0:
    # NOTE: we deliberately do NOT embed the workspace root path in the
    # generated output — that would make the file byte-dependent on
    # where the workspace lives on disk, breaking the byte-deterministic
    # contract across machines and CI checkouts. The parameter is
    # accepted for forward compatibility but not serialised today.
    discard
  if members.len > 0:
    var withEdges = 0
    var leaves = 0
    var seenFroms: Table[string, bool]
    for edge in edges:
      seenFroms[edge.fromPackage] = true
    var seenPackages: Table[string, bool]
    for m in members:
      if seenPackages.getOrDefault(m.package, false):
        continue
      seenPackages[m.package] = true
      if seenFroms.getOrDefault(m.package, false):
        inc withEdges
      else:
        inc leaves
    result.add("# Targets scanned: " & $(withEdges + leaves) &
      " (" & $withEdges & " with edges, " & $leaves & " leaves)\n")
  result.add("\n")
  if edges.len == 0:
    result.add("# (no inter-package dep edges discovered)\n")
    return
  # Group edges by fromPackage, dedup the dep list per fromPackage,
  # emit one ``depends_on <pkg>: <dep1>, <dep2>`` line per group plus
  # one evidence-comment line per individual edge so review-time diffs
  # explain why each edge was inferred.
  var grouped: Table[string, seq[DepEdge]]
  var orderedFroms: seq[string] = @[]
  for edge in edges:
    if not grouped.hasKey(edge.fromPackage):
      grouped[edge.fromPackage] = @[]
      orderedFroms.add(edge.fromPackage)
    grouped[edge.fromPackage].add(edge)
  for fromPkg in orderedFroms:
    let groupEdges = grouped[fromPkg]
    var seen: Table[string, bool]
    var uniqueDeps: seq[string] = @[]
    for edge in groupEdges:
      if seen.getOrDefault(edge.toPackage, false):
        continue
      seen[edge.toPackage] = true
      uniqueDeps.add(edge.toPackage)
    for edge in groupEdges:
      result.add("# " & edge.evidence & "\n")
    # Nim's parser rejects ``depends_on <pkg>: <a>, <b>, <c>`` (inline
    # comma form is treated as "invalid indentation" inside the
    # statement list after the colon). Use the inline form ONLY for
    # the single-dep case; for two-or-more deps, switch to the block
    # form which parses cleanly:
    #
    #     depends_on <pkg>:
    #       <a>
    #       <b>
    #       <c>
    #
    # The macro's `collectDependsOnEntries` walks both shapes; the
    # generated file shape is purely a rendering choice driven by what
    # Nim's parser accepts.
    if uniqueDeps.len == 1:
      result.add("depends_on " & fromPkg & ": " & uniqueDeps[0] & "\n")
    else:
      result.add("depends_on " & fromPkg & ":\n")
      for dep in uniqueDeps:
        result.add("  " & dep & "\n")
    result.add("\n")

# ----------------------------------------------------------------------
# --check support. Reads the on-disk file (if present) and compares it
# byte-for-byte to the freshly rendered content. Returns ``true`` when
# the file is up-to-date.
# ----------------------------------------------------------------------

proc readExistingScannedDeps*(path: string): string =
  ## Read the current contents of ``path``; return the empty string
  ## when the file doesn't exist. Any read error other than "not
  ## found" raises — the operator needs to know if the file is there
  ## but unreadable.
  if not fileExists(path):
    return ""
  readFile(path)

proc scannedDepsArePresent*(repoNimPath: string): bool =
  ## Quick check used by error messages: does the project file in
  ## ``repoNimPath``'s dir include the scanned-deps file? We don't
  ## parse the file; we just look for the literal ``include
  ## "repro.scanned-deps.nim"`` substring. False positives are
  ## acceptable (a comment mentioning the include line would qualify);
  ## false negatives are not (every real use mentions the literal
  ## string).
  if not fileExists(repoNimPath):
    return false
  let text =
    try:
      readFile(repoNimPath)
    except CatchableError:
      return false
  text.contains("repro.scanned-deps.nim")
