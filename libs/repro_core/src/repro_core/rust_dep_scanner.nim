## Mode 3 Rust dependency scanner.
##
## Walks a Rust workspace and emits a deterministic dep graph naming
## **only** the inter-workspace package edges proved by ``use <crate>::...``
## / ``extern crate <crate>;`` statements in each crate's ``.rs`` sources.
## Mirror of the Nim and C/C++ scanners in
## ``./nim_dep_scanner.nim`` + ``./cpp_dep_scanner.nim`` per
## ``reprobuild-specs/Three-Mode-Convention-System.md`` §"The scanner
## contract" — same shapes, same determinism guarantee — but parsing
## Rust source instead of Nim/C/C++ source.
##
## Scope of this milestone (M30, Mode 3 Rust pilot):
##   * Recognise Rust ``executable`` / ``library`` members declared in
##     a workspace's ``repro.nim`` / ``reprobuild.nim`` files. Detection
##     piggy-backs on the layout convention: a member is Rust iff
##     ``<projectRoot>/<member>/src/`` contains ``main.rs`` or ``lib.rs``
##     (Layout B), OR ``<projectRoot>/src/main.rs`` / ``src/lib.rs``
##     exists for a single-member project (Layout A).
##   * For each member, walk ``<crateRoot>/src/`` recursively for ``.rs``
##     files.
##   * Parse the import-like statements:
##       ``use <crate>::...``
##       ``use <crate>;``       (less common, but legal — pulls the crate root)
##       ``extern crate <crate>;``     (legacy 2015 edition shape)
##     The first path segment of the ``use`` / ``extern crate`` token is
##     resolved against the set of other in-workspace member names.
##   * Stdlib crates (``std``, ``core``, ``alloc``, plus the typical
##     macro prelude crates) are filtered. External crates that aren't
##     on the in-workspace member list are silently dropped — Mode 3
##     in-workspace only, per the M30 honest-scope cut.
##   * Emit edges sorted by ``(fromPackage, toPackage, evidence)`` so the
##     output is byte-deterministic across runs and across hosts.
##
## Out of scope (documented as outstanding, deferred):
##   * Conditional ``#[cfg(...)]`` branches — the scanner reads them as
##     if always taken. Edges that only manifest under a specific
##     ``--cfg`` are over-emitted on the conservative side; the spec
##     calls out manual ``depends_on`` overrides as the suppression
##     mechanism.
##   * ``use crate::...`` / ``use self::...`` / ``use super::...`` —
##     these are intra-crate paths and never produce a workspace edge.
##   * Re-exports through ``pub use`` are walked the same way as
##     plain ``use`` — a transitive consumer's evidence may surface a
##     re-export rather than the original import.
##   * ``mod`` declarations — these load a file from disk relative to
##     the current module path; they're an intra-crate detail and never
##     produce a workspace edge.
##   * crates.io / git deps — Mode 3 is in-workspace only; users who
##     need external crates write a ``Cargo.toml`` and let the Mode 2
##     Rust convention drive the build.
##
## The scanner shares the ``WorkspaceMember`` / ``DepEdge`` /
## ``ScanResult`` types with ``./nim_dep_scanner.nim`` so the
## ``repro deps refresh`` driver can merge the Nim, C/C++, and Rust
## passes' output into a single ``repro.scanned-deps.nim``.

import std/[algorithm, os, strutils, tables]

import ./nim_dep_scanner
import ./paths
import ./project_file

const
  RustSourceExtension* = ".rs"
    ## The single file extension the scanner treats as a Rust source
    ## file. Header-style ``.rs.in`` / pre-processed files are NOT
    ## walked — they'd be an extension and the scanner is intentionally
    ## minimal.

# ----------------------------------------------------------------------
# Member discovery — read project files and pull out executable/library
# declarations whose source layout looks like Rust (a ``main.rs`` or
# ``lib.rs`` under ``src/``). Members whose layout doesn't match are
# skipped; a Nim-only repo therefore produces zero Rust members and the
# scanner falls back to a no-op.
# ----------------------------------------------------------------------

proc extractRustMembersFromProjectFile(projectFile: string):
    seq[tuple[package: string; kind: string; name: string]] =
  ## Mirror of ``nim_dep_scanner.extractMembersFromProjectFile`` /
  ## ``cpp_dep_scanner.extractCCppMembersFromProjectFile`` for the Rust
  ## side. We don't reuse those because the per-language layout filter
  ## (does the package look like Rust?) lives at this scanner's
  ## discovery step.
  ##
  ## The text scan itself is identical to the Nim/C/C++ scanners'. We
  ## return raw declarations without filtering; the caller filters by
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

proc isRustSourceFile*(path: string): bool =
  ## True when ``path``'s extension matches a Rust source file.
  path.toLowerAscii.endsWith(RustSourceExtension)

proc dirHasRustSources(dir: string): bool =
  ## True when ``dir`` (or any nested subdir) contains a ``.rs`` file.
  ## Used as the layout filter — directories with no Rust sources never
  ## contribute to the Rust scanner's member list.
  if not dirExists(extendedPath(dir)):
    return false
  for path in walkDirRec(dir):
    if isRustSourceFile(path):
      return true
  false

proc resolveRustMemberDirs*(projectRoot, memberName, memberKind: string):
    tuple[srcDir: string; entrySource: string] =
  ## Resolve a single member's ``src/`` directory + crate root file
  ## (``main.rs`` for binaries, ``lib.rs`` for libraries) under a project
  ## root. Supports BOTH canonical Mode 3 layout shapes:
  ##
  ##   Layout A — one package per project file:
  ##     <projectRoot>/src/main.rs    (executable)
  ##     <projectRoot>/src/lib.rs     (library)
  ##
  ##   Layout B — multiple packages per project file:
  ##     <projectRoot>/<memberName>/src/main.rs    (executable)
  ##     <projectRoot>/<memberName>/src/lib.rs     (library)
  ##
  ## Layout B is tried FIRST because Layout A's ``src/`` directory is
  ## also present in a Layout B workspace (every package's subdir
  ## contains its own ``src/`` — but the workspace root itself does NOT
  ## have ``src/`` directly). Same ordering as the C/C++ scanner.
  ##
  ## Returns empty strings on both fields when neither layout matches.
  let entryBaseName =
    if memberKind == "library": "lib.rs"
    else: "main.rs"

  let subdirSrc = projectRoot / memberName / "src"
  let subdirEntry = subdirSrc / entryBaseName
  if fileExists(extendedPath(subdirEntry)):
    result.srcDir = subdirSrc
    result.entrySource = subdirEntry
    return

  let topSrc = projectRoot / "src"
  let topEntry = topSrc / entryBaseName
  if fileExists(extendedPath(topEntry)):
    result.srcDir = topSrc
    result.entrySource = topEntry
    return

proc discoverRustMembers*(workspaceRoot: string): seq[WorkspaceMember] =
  ## Walk ``workspaceRoot`` for every project file and produce one
  ## ``WorkspaceMember`` per ``executable`` / ``library`` declared in a
  ## ``package`` block whose layout matches one of the two canonical
  ## Rust Mode 3 shapes (see ``resolveRustMemberDirs``). Members whose
  ## layout doesn't match are silently skipped — they belong to another
  ## language's scanner.
  ##
  ## The walk skips ``.repro/``, ``.git/``, ``node_modules/``,
  ## ``.nimcache/``, ``.cargo/``, and ``target/`` — same as the Nim and
  ## C/C++ scanners — so a build's intermediates never pollute the
  ## member set.
  if not dirExists(extendedPath(workspaceRoot)):
    return @[]
  var queue: seq[string] = @[workspaceRoot]
  while queue.len > 0:
    let dir = queue[0]
    queue.delete(0)
    let match = resolveProjectFile(dir)
    if match.path.len > 0:
      for decl in extractRustMembersFromProjectFile(match.path):
        let resolved = resolveRustMemberDirs(dir, decl.name, decl.kind)
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
# Use / extern-crate extraction. The scanner is intentionally NOT a Rust
# parser: building one would dwarf the milestone. The line-scan below
# extracts the FIRST path segment of every ``use <crate>::...`` and
# ``extern crate <crate>;`` statement.
#
# Rust's grouped-use form ``use foo::{bar, baz};`` resolves to one root
# (``foo``), not three; the scanner extracts that single root. The
# ``use {a, b};`` shape (no leading path) isn't legal Rust at module
# scope and is skipped.
# ----------------------------------------------------------------------

type
  RustUseRef* = object
    ## One ``use`` / ``extern crate`` statement extracted from a Rust
    ## source file.
    crateHead*: string
      ## The first path segment of the ``use`` / ``extern crate`` token.
      ## For ``use mathlib::add;`` the head is ``mathlib``; for
      ## ``extern crate mathlib;`` likewise.
    lineNumber*: int
      ## 1-based line number where the statement was found.
    raw*: string
      ## The stripped source line for the evidence string.

proc stripRustLineComment(line: string): string =
  ## Drop everything after the first ``//`` that isn't inside a string
  ## literal. Block comments ``/* ... */`` are NOT handled — they're
  ## rare in the import region of real codebases and the cost of a
  ## stateful scanner would dwarf the rest of the milestone. A rogue
  ## block-comment-wrapped use would produce at most a spurious edge
  ## that the user can suppress via manual override per spec §"Manual
  ## override".
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

proc extractCrateHead(rest: string): string =
  ## Extract the first identifier from ``rest`` (i.e. the path segment
  ## up to the first ``::``, ``;``, ``{``, ``as``, or whitespace).
  ## Returns the empty string when ``rest`` doesn't start with a Rust
  ## identifier character.
  var head = ""
  var i = 0
  # Skip leading whitespace.
  while i < rest.len and rest[i] in {' ', '\t'}:
    inc i
  # Skip optional ``pub`` / ``pub(crate)`` / visibility prefixes that
  # were inadvertently caught by a ``pub use ...`` extraction. The
  # caller's stripping is supposed to handle that, but we're defensive.
  while i < rest.len:
    let ch = rest[i]
    if ch in {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '_'}:
      head.add(ch)
      inc i
    else:
      break
  head

proc extractRustUseRefs*(sourceText: string): seq[RustUseRef] =
  ## Walk ``sourceText`` line-by-line and emit every recognised
  ## ``use <crate>::...`` / ``use <crate>;`` / ``extern crate <crate>;``
  ## statement. The scanner accepts:
  ##
  ##   * Bare ``use foo::bar;`` (head = ``foo``)
  ##   * Grouped ``use foo::{bar, baz};`` (head = ``foo``)
  ##   * Aliased ``use foo as f;`` (head = ``foo``)
  ##   * Renamed ``use foo::bar as b;`` (head = ``foo``)
  ##   * ``pub use foo::bar;`` (head = ``foo``)
  ##   * ``pub(crate) use foo::bar;`` (head = ``foo``)
  ##   * ``extern crate foo;`` / ``extern crate foo as f;`` (head = ``foo``)
  ##
  ## Special intra-crate heads (``crate``, ``self``, ``super``) are
  ## emitted with their literal head so the stdlib filter at the
  ## resolution layer can drop them; emitting them here keeps the
  ## extractor language-pure and pushes the resolution policy into the
  ## caller (which is where stdlib / external filtering lives anyway).
  var lineNo = 0
  for rawLine in sourceText.splitLines():
    inc lineNo
    let cleaned = stripRustLineComment(rawLine)
    let stripped = cleaned.strip()
    if stripped.len == 0:
      continue
    # Drop leading visibility prefixes so the rest of the parser sees a
    # plain ``use`` / ``extern crate`` token. We accept ``pub``,
    # ``pub(crate)``, ``pub(super)``, ``pub(in ...)``.
    var work = stripped
    if work.startsWith("pub"):
      var idx = len("pub")
      # Optional ``(...)`` visibility scope.
      if idx < work.len and work[idx] == '(':
        let closeIdx = work.find(')', idx + 1)
        if closeIdx < 0:
          continue
        idx = closeIdx + 1
      # Require whitespace after the visibility token.
      if idx < work.len and work[idx] in {' ', '\t'}:
        work = work[idx .. ^1].strip()
      else:
        # Not a ``pub use`` — could be ``pub fn`` etc. Fall through to
        # the ``startsWith("use ")`` check below.
        discard
    var head = ""
    if work.startsWith("use ") or work.startsWith("use\t"):
      let rest = work[len("use ") .. ^1]
      head = extractCrateHead(rest)
    elif work.startsWith("extern ") or work.startsWith("extern\t"):
      let rest = work[len("extern ") .. ^1].strip()
      if rest.startsWith("crate ") or rest.startsWith("crate\t"):
        let after = rest[len("crate ") .. ^1]
        head = extractCrateHead(after)
    else:
      continue
    if head.len == 0:
      continue
    result.add(RustUseRef(
      crateHead: head,
      lineNumber: lineNo,
      raw: stripped))

# ----------------------------------------------------------------------
# Stdlib + intra-crate filter. Rust's stdlib crates are accessed by the
# top-level names ``std``, ``core``, and ``alloc`` (plus the
# ``proc_macro`` and ``test`` crates that ship with rustc). Intra-crate
# paths use the magic identifiers ``crate``, ``self``, ``super``.
# Anything matching this set never produces a workspace edge.
# ----------------------------------------------------------------------

const RustStdlibCrates* = [
  "std", "core", "alloc", "proc_macro", "test"
]
  ## The set of stdlib crate names the scanner filters out. ``proc_macro``
  ## and ``test`` ship with rustc and are reachable via ``extern crate``
  ## without a path-dep declaration; we include them defensively so a
  ## ``use proc_macro::TokenStream;`` line doesn't trigger an undeclared-
  ## dep diagnostic at the convention layer.

const RustIntraCrateHeads* = [
  "crate", "self", "super"
]
  ## Intra-crate path heads. ``crate::foo`` refers to the current crate's
  ## root; ``self::foo`` / ``super::foo`` refer to the current / parent
  ## module. None of these produce an edge.

proc isRustStdlibCrate*(head: string): bool =
  ## True when ``head`` belongs to Rust's standard distribution and
  ## should be ignored.
  for entry in RustStdlibCrates:
    if entry == head:
      return true
  false

proc isRustIntraCrateHead*(head: string): bool =
  ## True when ``head`` is one of Rust's intra-crate magic identifiers.
  for entry in RustIntraCrateHeads:
    if entry == head:
      return true
  false

# ----------------------------------------------------------------------
# Member-name normalisation. Cargo packages spelled with ``-`` map to
# rustc crate names with ``_``; the in-workspace lookup table is keyed
# on the underscored form so a ``use my_lib::foo;`` line matches a
# member declared as ``my-lib`` in ``repro.nim``.
# ----------------------------------------------------------------------

proc normaliseRustCrateName*(text: string): string =
  ## Collapse ``-`` → ``_`` so two spellings of the same crate name
  ## compare equal. Mirror of the Nim scanner's ``normaliseName`` minus
  ## the case-folding (Rust crate names are case-sensitive).
  result = newStringOfCap(text.len)
  for ch in text:
    if ch == '-':
      result.add('_')
    else:
      result.add(ch)

# ----------------------------------------------------------------------
# Source collection. For each member we walk every ``.rs`` file under
# its ``src/`` directory; the scanner is conservative on the include
# side (every file's imports count) the same way the Nim scanner walks
# every transitively-imported module.
# ----------------------------------------------------------------------

proc collectScanSources(member: WorkspaceMember): seq[string] =
  ## Every ``.rs`` file under the member's ``src/`` subtree. Resolved
  ## via the Layout A / Layout B fallback so single-package and
  ## multi-package workspaces both work.
  ##
  ## ``member.sourceFile`` already points at the crate root entry; we
  ## reuse its parent dir as the search root rather than re-running
  ## ``resolveRustMemberDirs`` so the scanner doesn't re-derive the
  ## layout decision (member is already pinned to a specific crate root).
  if member.sourceFile.len == 0:
    return @[]
  let srcDir = member.sourceFile.parentDir
  if not dirExists(extendedPath(srcDir)):
    return @[]
  for path in walkDirRec(srcDir):
    if isRustSourceFile(path):
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

proc scanWorkspaceRust*(workspaceRoot: string): ScanResult =
  ## Top-level Rust scanner entry point. Discovers members, builds the
  ## ``<crate-name> → <package>`` index, walks each member's sources,
  ## resolves ``use`` / ``extern crate`` heads, emits a sorted edge
  ## list.
  let members = discoverRustMembers(workspaceRoot)
  result.members = members
  if members.len == 0:
    return

  # Index every member's normalised crate name → owning package. We
  # also index by the package name so ``use packageName::foo;`` from
  # another member matches when the package has no member with that
  # exact name (rare but possible — same forgiveness the Nim scanner
  # applies).
  var crateIndex = initTable[string, string]()
  for m in members:
    let memberKey = normaliseRustCrateName(m.member)
    if memberKey.len > 0 and not crateIndex.hasKey(memberKey):
      crateIndex[memberKey] = m.package
    let pkgKey = normaliseRustCrateName(m.package)
    if pkgKey.len > 0 and not crateIndex.hasKey(pkgKey):
      crateIndex[pkgKey] = m.package

  var allEdges: seq[DepEdge] = @[]
  for m in members:
    var seen = initTable[string, bool]()
    for sourcePath in collectScanSources(m):
      let text =
        try:
          readFile(extendedPath(sourcePath))
        except CatchableError:
          continue
      for useRef in extractRustUseRefs(text):
        let head = useRef.crateHead
        if head.len == 0:
          continue
        if isRustIntraCrateHead(head):
          continue
        if isRustStdlibCrate(head):
          continue
        let lookupKey = normaliseRustCrateName(head)
        if not crateIndex.hasKey(lookupKey):
          # External crate (not in workspace, not stdlib) — silently
          # dropped. The M30 honest-scope cut: Mode 3 Rust is in-
          # workspace only, and external deps belong to the Cargo-
          # driven Mode 2 path.
          continue
        let toPackage = crateIndex[lookupKey]
        if toPackage == m.package:
          # Self-import via the package's own name — not a workspace
          # edge. Rare but possible when a crate uses ``extern crate
          # <self-name>;`` for backwards-compatible 2015-edition
          # reasons.
          continue
        let evidence = relativeEvidence(workspaceRoot, sourcePath,
          useRef.lineNumber, useRef.raw)
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
