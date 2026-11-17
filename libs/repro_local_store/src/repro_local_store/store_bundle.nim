## Native-store bundles: closure query, export and import.
##
## A bundle carries what Reprobuild's own store and caches hold for one set
## of workspace roots, so that a fresh machine at the SAME absolute paths can
## build and enter the dev environment without re-running producers. The
## design, the format and the trust argument are in `docs/store-bundles.md`;
## the section numbers cited below (§N) refer to that document.
##
## The on-disk form reuses the dev-shell bundle conventions: a POSIX tar
## stream compressed with `zstd --long=27`, split into fixed-size parts, and a
## JSON transport manifest that lists every part with its SHA-256. The
## authoritative description of the bundle is the `contents` entry inside the
## stream (§4.1); the JSON manifest is only transport metadata.
##
## POSIX only: it relies on `lstat`/`utimensat` nanosecond timestamps, and
## the CLI does not offer the commands on Windows.
##
## The tar and zstd work is done by the system `tar` (GNU tar, for pax
## headers with nanosecond mtimes) and `zstd` executables. Both are present
## wherever the other bundle halves are produced and consumed.
##
## The part hashes come from the same unsigned manifest as the parts, so they
## say nothing about what the stream may write. Before any extraction, import
## lists the archive with the same GNU tar over the same verified parts
## (`listBundleMembers`) and refuses unless its members are exactly the ones
## `contents` declares (§5 step 3, `checkMembers`); the rules themselves are
## in `tar_members`.

# This module's C (including the SHA-256 it instantiates for part checks)
# runs once per byte of a bundle, so it is optimized whatever the Nim build
# mode is. See docs/store-bundles.md §10 for the measurement.
{.localPassC: "-O3".}

import std/[algorithm, json, monotimes, os, osproc, posix, sequtils, sets,
    streams, strutils, tables, times]
import nimcrypto/sha2
import blake3
import repro_hash
from repro_core import ReprobuildVersion, ReprobuildSourceRevision
import repro_core/ambient_execution
import ../repro_local_store
import ./store
import ./prefix_paths
import ./tar_members

type
  StoreBundleError* = object of CatchableError
    ## Raised for every refusal: a root mismatch, a part or content hash
    ## mismatch, a missing tool, a malformed manifest.

  BundleRoots* = object
    ## The absolute roots a bundle was produced at, or that an importer
    ## resolves locally. §3: import refuses unless they are identical.
    storeRoot*: string
    actionCacheRoot*: string
    workspaceRoots*: seq[string]

  BundleSelection* = object
    ## The part of the workspace roots a bundle carries (§2.1). A path is in
    ## the selection when it lies in a workspace root and the deepest of the
    ## roots, `exclude` and `include` directories holding it is not an
    ## `exclude` one. Both empty: the whole of every root.
    excluded*: seq[string]
    included*: seq[string]

  BundleProducer* = object
    ## The `repro` that wrote a bundle (§4.1): its version and its source
    ## revision ("unknown" when the build was not told it). The version alone
    ## does not identify a build, so import compares both (§5 step 2).
    version*: string
    revision*: string

  SkipKind* = enum
    ## Why a record that touches the selection is not carried as
    ## re-witnessable (`repro store closure`'s reason class).
    skOutputChanged = "output-changed"
      ## Its outputs fail the in-place check: the output metadata changed
      ## since the record was written.
    skOutputOutsideRoots = "output-outside-roots"
      ## An output outside the bundle roots, or below the store or
      ## action-cache root outside everything a bundle carries there.
    skOutputOutsideSelection = "output-outside-selection"
    skUnplaceable = "unplaceable"
      ## A relocatable record no selected project directory holds in its
      ## recorded state.

  SkippedRecord* = object
    edgeDir*: string
    strongHex*: string
    kind*: SkipKind
    reason*: string

  BundleEntryKind* = enum
    bekFile = "f"
    bekDir = "d"
    bekLink = "l"

  BundleEntry* = object
    ## One tar member, as recorded in `contents`.
    kind*: BundleEntryKind
    mode*: int
    size*: int64
    mtimeNs*: int64
    digest*: string
      ## BLAKE3 hex of a file's bytes, the link target of a symlink, "-" for
      ## a directory.
    path*: string

  RestampEntry* = object
    ## A fingerprinted input that is NOT carried by the bundle (it comes
    ## from version control) but whose mtime a timestamp-policy record
    ## compares. §5.3.
    size*: int64
    mtimeNs*: int64
    digest*: string
    path*: string

  FrozenDevEnv* = object
    projectRoot*: string
    scriptPath*: string

  BundleRecordRef* = object
    ## A record that passed the in-place output check on the exporting host
    ## and may therefore be re-witnessed after import (§5.1).
    edgeDir*: string
    strongHex*: string
    outputRoot*: string
      ## The action directory a relocatable record's relative paths resolve
      ## against; "" when every path it names is absolute.

  BundleClosure* = object
    producer*: BundleProducer
    roots*: BundleRoots
    selection*: BundleSelection
    edges*: seq[string]
    records*: seq[BundleRecordRef]
    prefixes*: seq[string]
    entries*: seq[BundleEntry]
    restamps*: seq[RestampEntry]
    devEnvs*: seq[FrozenDevEnv]
    skippedRecords*: seq[SkippedRecord]
      ## Records that touch the selection but were not exported as
      ## re-witnessable, with the reason (normally a stale output).

  BundlePart* = object
    ## One part of a half, as its manifest lists it (`{file, bytes, sha256}`,
    ## the dev-shell bundle format's field names).
    file*: string
    bytes*: int64
    sha256*: string

  ExportOptions* = object
    outDir*: string
    partSize*: int64
    zstdLevel*: int
    zstdThreads*: int
    halfName*: string

  ExportReport* = object
    bundleId*: string
    manifestPath*: string
    contentsPath*: string
    parts*: seq[BundlePart]
    entryCount*: int
    unpackedBytes*: int64
    compressedBytes*: int64

  ImportOptions* = object
    bundleDir*: string
    manifestName*: string
    force*: bool

  ImportReport* = object
    bundleId*: string
    skippedExtraction*: bool
      ## True when the bundle was already imported and still matches (§5
      ## step 6), so nothing was unpacked.
    excludedPrefixes*: seq[string]
    verifiedEntries*: int
    reinsertedPrefixes*: int
    quarantinedPrefixes*: seq[string]
    rewitnessedRecords*: int
    restamped*: int
    restampMismatches*: int
    devEnvs*: seq[FrozenDevEnv]
    roots*: BundleRoots
    phaseSeconds*: seq[tuple[phase: string, seconds: float]]
      ## Wall time per §5 step, in order, for `--json` and for measuring.

const
  ContentsHeader* = "reprobuild.store-bundle.contents.v2"
  ContentsHeaderV1 = "reprobuild.store-bundle.contents.v1"
  ManifestSchema* = "reprobuild.store-bundle.v2"
  DefaultHalfName* = "native-store"
  DefaultPartSize* = 64'i64 * 1024 * 1024
  DefaultZstdLevel* = 19
  ZstdWindowLog* = 27
  BundlesDirName* = "bundles"
  FrozenDevEnvDirName* = "frozen-dev-env"
  ImportedMarkerName* = "imported"
  MaxContentsBytes* = 1024 * 1024 * 1024
    ## The largest `contents` list import reads. It is read into memory
    ## before its SHA-256 is compared, from a stream the bundle's own,
    ## unsigned manifest describes, so without a bound a crafted first
    ## member could exhaust the importer's memory. A gibibyte is several
    ## million entries; export refuses to write a larger list.
  ReadChunk = 1 shl 20

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------

proc fail(msg: string) {.noreturn.} =
  raise newException(StoreBundleError, msg)

proc normalizedRoot(path: string): string =
  ## Absolute, normalized, no trailing separator. Roots are compared as
  ## strings (§3), so they must be spelled one way.
  result = normalizedPath(absolutePath(path))
  while result.len > 1 and result.endsWith("/"):
    result.setLen(result.len - 1)

proc isWithin*(path, root: string): bool =
  ## Whether `path` is `root` or lies below it (lexically).
  root.len > 0 and (path == root or path.startsWith(root & "/"))

proc withinAny(path: string; roots: openArray[string]): bool =
  for root in roots:
    if path.isWithin(root):
      return true

proc inSelection*(path: string; workspaceRoots: openArray[string];
                  sel: BundleSelection): bool =
  ## §2.1: `path` lies in a workspace root, and the deepest of the roots and
  ## the selection's directories that holds it is not an `exclude` one.
  var depth = -1
  var excluded = false
  for root in workspaceRoots:
    if path.isWithin(root) and root.len > depth:
      depth = root.len
      excluded = false
  if depth < 0:
    return false
  for dir in sel.excluded:
    if path.isWithin(dir) and dir.len > depth:
      depth = dir.len
      excluded = true
  for dir in sel.included:
    if path.isWithin(dir) and dir.len >= depth:
      depth = dir.len
      excluded = false
  not excluded

proc localProducer*(): BundleProducer =
  ## The running `repro`, as a bundle's `producer` line names it.
  BundleProducer(version: ReprobuildVersion,
    revision: (if ReprobuildSourceRevision.len > 0: ReprobuildSourceRevision
               else: "unknown"))

proc escapeField*(value: string): string =
  ## §4.1: `\`, TAB and newline escaped so a path is always one field.
  result = newStringOfCap(value.len)
  for ch in value:
    case ch
    of '\\': result.add("\\\\")
    of '\t': result.add("\\t")
    of '\n': result.add("\\n")
    else: result.add(ch)

proc unescapeField*(value: string): string =
  result = newStringOfCap(value.len)
  var i = 0
  while i < value.len:
    if value[i] == '\\' and i + 1 < value.len:
      case value[i + 1]
      of '\\': result.add('\\')
      of 't': result.add('\t')
      of 'n': result.add('\n')
      else: fail("malformed escape in bundle contents: " & value)
      i += 2
    else:
      result.add(value[i])
      inc i

proc lowerHex*(bytes: openArray[byte]): string =
  result = newStringOfCap(bytes.len * 2)
  for b in bytes:
    result.add(toHex(int(b), 2).toLowerAscii())

proc fileBlake3Hex*(path: string; buf: var seq[byte]): string =
  ## Streamed BLAKE3-256 of a file's bytes. `buf` is the caller's reusable
  ## read buffer: a bundle hashes tens of thousands of files, and a fresh
  ## zeroed buffer per file was the dominant cost of verification.
  var f: File
  if not open(f, path, fmRead):
    fail("cannot read " & path)
  defer: close(f)
  if buf.len == 0:
    buf = newSeq[byte](ReadChunk)
  let hasher = initHasher()
  defer: hasher.close()
  while true:
    let n = f.readBuffer(addr buf[0], buf.len)
    if n <= 0: break
    hasher.update(addr buf[0], n)
  hasher.finalize().toHex()

proc fileBlake3Hex*(path: string): string =
  var buf: seq[byte]
  fileBlake3Hex(path, buf)

type LiveState = object
  exists: bool
  kind: BundleEntryKind
  mode: int
  size: int64
  mtimeNs: int64

proc liveState(path: string): LiveState =
  var st: Stat
  if lstat(path.cstring, st) != 0:
    return
  result.exists = true
  result.mode = int(st.st_mode) and 0o7777
  result.size = int64(st.st_size)
  result.mtimeNs = int64(st.st_mtim.tv_sec) * 1_000_000_000 +
    int64(st.st_mtim.tv_nsec)
  if S_ISDIR(st.st_mode): result.kind = bekDir
  elif S_ISLNK(st.st_mode): result.kind = bekLink
  else: result.kind = bekFile

proc c_utimensat(dirfd: cint; path: cstring; times: ptr array[2, Timespec];
                 flags: cint): cint {.importc: "utimensat",
                                     header: "<sys/stat.h>".}

# Taken from the C headers: their values differ between Linux and macOS.
var
  AtFdCwd {.importc: "AT_FDCWD", header: "<fcntl.h>".}: cint
  AtSymlinkNoFollow {.importc: "AT_SYMLINK_NOFOLLOW", header: "<fcntl.h>".}: cint
  UtimeOmit {.importc: "UTIME_OMIT", header: "<sys/stat.h>".}: clong

proc setMtimeNs(path: string; mtimeNs: int64) =
  ## Nanosecond-exact mtime restore (std/times only reaches microseconds,
  ## and the timestamp policy compares nanoseconds). atime is left alone.
  var times: array[2, Timespec]
  times[0].tv_sec = posix.Time(0)
  times[0].tv_nsec = UtimeOmit
  times[1].tv_sec = posix.Time(mtimeNs div 1_000_000_000)
  times[1].tv_nsec = clong(mtimeNs mod 1_000_000_000)
  if c_utimensat(AtFdCwd, path.cstring, addr times, AtSymlinkNoFollow) != 0:
    raiseOSError(osLastError(), "utimensat " & path)

proc requireTool*(name: string): string =
  # Not following links: `nix-store` is a link to the multi-call `nix`,
  # which dispatches on the name it was run by.
  result = uncontrolledFindExe(name, followSymlinks = false)
  if result.len == 0:
    fail("`" & name & "` is not on PATH; store bundles need GNU tar and zstd")

proc relToSlash(path: string): string =
  ## tar member name for an absolute path: the path without its leading `/`.
  path[1 .. ^1]

# ---------------------------------------------------------------------------
# Action-cache enumeration
# ---------------------------------------------------------------------------

proc weakFromEdgeDirName*(name: string; weak: var ContentDigest): bool =
  ## Inverse of `perEdgeRecordFileName`: `<alg>-<dom>-<hex64>.rbar`.
  if not name.endsWith(".rbar"):
    return false
  let parts = name[0 ..< name.len - 5].split('-')
  if parts.len != 3 or parts[2].len != 64:
    return false
  try:
    let alg = parseInt(parts[0])
    let dom = parseInt(parts[1])
    if alg < ord(low(HashAlgorithm)) or alg > ord(high(HashAlgorithm)) or
        dom < ord(low(HashDomain)) or dom > ord(high(HashDomain)):
      return false
    weak.algorithm = HashAlgorithm(alg)
    weak.domain = HashDomain(dom)
    for i in 0 ..< 32:
      weak.bytes[i] = byte(parseHexInt(parts[2][2 * i .. 2 * i + 1]))
  except ValueError:
    return false
  perEdgeRecordFileName(weak) == name

proc edgeDirs(actionCacheRoot: string): seq[string] =
  let hot = actionCacheRoot / "hot-records"
  if not dirExists(hot):
    return
  for kind, path in walkDir(hot):
    if kind == pcDir and path.endsWith(".rbar"):
      result.add(path)
  result.sort()

proc recordTouches(record: ActionResultRecord; roots: openArray[string];
                   sel: BundleSelection): bool =
  ## Whether an absolute input or output of `record` is in the selection.
  for input in record.inputs:
    if input.path.isAbsolute and
        input.path.normalizedPath.inSelection(roots, sel):
      return true
  for output in record.outputs:
    if output.path.isAbsolute and
        output.path.normalizedPath.inSelection(roots, sel):
      return true

# ---------------------------------------------------------------------------
# Closure
# ---------------------------------------------------------------------------

proc prefixDirOf(path, storeRoot: string): string =
  ## The `prefixes/<pkg>/<dir>` or `tool-store/prefixes/<pkg>/<dir>`
  ## directory that contains `path`, or "".
  for base in [storeRoot / "prefixes", storeRoot / "tool-store" / "prefixes"]:
    if path.isWithin(base) and path != base:
      let rest = path[base.len + 1 .. ^1].split('/')
      if rest.len >= 2:
        return base / rest[0] / rest[1]
  ""

proc selectionWalkRoots(roots: openArray[string];
                        sel: BundleSelection): seq[string] =
  ## Where a walk of the selection starts: every root, and every `include`
  ## directory (it lies in an excluded one, which the walk does not enter).
  for root in roots: result.add(root)
  for dir in sel.included: result.add(dir)

proc findDotReproDirs(roots: openArray[string]; sel: BundleSelection;
                      excluded: openArray[string]; found: var seq[string]) =
  ## Every `.repro/` directory in the selection, not descending into `.git`,
  ## into a found `.repro`, into a directory the selection excludes, or into
  ## an `excluded` subtree (the store and the action cache, which have their
  ## own selection rules).
  var seen = initHashSet[string]()
  for root in selectionWalkRoots(roots, sel):
    if not dirExists(root):
      continue
    var stack = @[root]
    while stack.len > 0:
      let dir = stack.pop()
      for kind, path in walkDir(dir):
        if kind != pcDir:
          continue
        let name = path.extractFilename
        if name == ".git" or path.withinAny(excluded) or
            not path.inSelection(roots, sel):
          continue
        if name == ".repro":
          if path notin seen:
            seen.incl(path)
            found.add(path)
        else:
          stack.add(path)

proc scanStorePaths(text, storeRoot: string; prefixes: var HashSet[string]) =
  ## Every store prefix a text (a frozen dev-env script) names.
  var start = 0
  while true:
    let at = text.find(storeRoot & "/", start)
    if at < 0: break
    var stop = at
    while stop < text.len and text[stop] notin {':', '"', '\'', ' ', '\n',
        '\t', ';', '$', ')', '`'}:
      inc stop
    let prefix = prefixDirOf(normalizedPath(text[at ..< stop]), storeRoot)
    if prefix.len > 0 and dirExists(prefix):
      prefixes.incl(prefix)
    start = stop

proc expandInto(path: string; seen: var HashSet[string];
                entries: var seq[BundleEntry]; buf: var seq[byte]) =
  ## Add `path` and, for a directory, everything below it.
  var stack = @[path]
  while stack.len > 0:
    let p = stack.pop()
    if p in seen:
      continue
    let st = liveState(p)
    if not st.exists:
      continue
    seen.incl(p)
    var entry = BundleEntry(kind: st.kind, mode: st.mode, mtimeNs: st.mtimeNs,
      path: p)
    case st.kind
    of bekFile:
      entry.size = st.size
      entry.digest = fileBlake3Hex(p, buf)
    of bekLink:
      entry.digest = expandSymlink(p)
    of bekDir:
      entry.digest = "-"
      for _, child in walkDir(p):
        stack.add(child)
    entries.add(entry)

proc findProjectDirs(roots: openArray[string]; sel: BundleSelection;
                      excluded: openArray[string]; found: var seq[string]) =
  ## Every directory in the selection that holds a project file, plus each
  ## root and `include` directory itself: the candidate working directories
  ## of relocatable records.
  for root in selectionWalkRoots(roots, sel):
    if not dirExists(root) or root in found:
      continue
    found.add(root)
    var stack = @[root]
    while stack.len > 0:
      let dir = stack.pop()
      for kind, path in walkDir(dir):
        if kind != pcDir:
          continue
        let name = path.extractFilename
        if name in [".git", ".repro"] or path.withinAny(excluded) or
            not path.inSelection(roots, sel):
          continue
        if (fileExists(path / "repro.nim") or
            fileExists(path / "reprobuild.nim")) and path notin found:
          found.add(path)
        stack.add(path)

proc resolvedPath(root, path: string): string =
  if path.isAbsolute or root.len == 0: normalizedPath(path)
  else: normalizedPath(root / path)

proc hasRelativePaths(record: ActionResultRecord): bool =
  for output in record.outputs:
    if not output.path.isAbsolute: return true
  for input in record.inputs:
    if not input.path.isAbsolute: return true

proc inputsStillRecordedAt(record: ActionResultRecord; dir: string): bool =
  ## Whether every input `record` names relative to its directory is, under
  ## `dir`, the input it fingerprinted: the same content where the record
  ## carries a content hash (`hashedInputContentChanged`), else the same kind,
  ## size and mtime. Existence is not enough: every repro project's provider
  ## compile names `repro.nim` by the same relative path, so two checkouts
  ## share one relocatable edge, and only the checkout whose files the record
  ## fingerprinted is its directory. Without this a record made in an
  ## unselected checkout was placed, and re-witnessed, in a selected one, and
  ## its outputs travelled with the selection (§2.1).
  ##
  ## Absolute inputs are the same whichever directory is tried, so they do
  ## not tell candidates apart; as before, they need only exist (the
  ## importing build's own lookup judges them).
  var relative = record
  relative.inputs = @[]
  for input in record.inputs:
    if input.path.isAbsolute:
      # As before: an absolute input must at least exist.
      if input.metadata.kind == ffkRegular and not liveState(input.path).exists:
        return false
      continue
    if input.hasLocalHash:
      relative.inputs.add(input)
    elif input.metadata.kind == ffkRegular:
      let st = liveState(resolvedPath(dir, input.path))
      if not st.exists or st.kind != bekFile or
          uint64(st.size) != input.metadata.sizeBytes or
          uint64(st.mtimeNs) != input.metadata.mtimeNs:
        return false
  hashedInputContentChanged(relative, dir).len == 0

proc resolveRecordDir(record: ActionResultRecord;
                      candidates: openArray[string]): string =
  ## The candidate directory against which `record` describes the files on
  ## disk, or "". A record without outputs cannot be placed (there is
  ## nothing to check), and is not exported as re-witnessable.
  if record.outputs.len == 0:
    return ""
  for dir in candidates:
    var plausible = true
    for output in record.outputs:
      if output.metadata.kind != ffkMissing and
          not liveState(resolvedPath(dir, output.path)).exists:
        plausible = false
        break
    if plausible and not inputsStillRecordedAt(record, dir):
      plausible = false
    if plausible and outputStateMismatch(record, dir).len == 0:
      return dir
  ""

proc stateAreas(store, ac: string): seq[string] =
  ## The areas below the store and action-cache roots a closure carries
  ## besides prefixes and edge directories (§2). `recipe-compiles/` holds
  ## the outputs of the recipe-compile records (a compiled project provider,
  ## an extracted interface), which §2 carries like any recorded output: a
  ## bundle that left them out would have every importer recompile its
  ## providers. Like `cas/`, it holds only content-keyed record outputs,
  ## none of the importer's own state.
  @[store / "compiler-probes", store / "tool-store" / "compiler-probes",
    store / FrozenDevEnvDirName, ac / "cas", ac / RecipeCompilesDirName]

proc carriedClassProblem(c: BundleClosure; e: BundleEntry;
                         contentsPath: string): string =
  ## "" when entry `e` is something a closure carries (§2), as far as the
  ## store and action-cache roots go; otherwise why not. Below those two
  ## roots the importer, and every later `repro`, keeps its own state
  ## (`index.db`, `tmp/`, `gc/`, the action-cache index files, ...), which a
  ## bundle never carries and must not be able to replace: a crafted
  ## `index.db` could name prefix paths outside the store for a later GC to
  ## delete. So there an entry must lie in one of the areas the closure
  ## draws from -- a carried prefix, the compiler-probe markers, the frozen
  ## dev-env scripts, a carried action-cache edge, the action-cache CAS --
  ## or be a directory on the way to one of them (or to `contents`).
  ## `contentsPath` may be "" (at export, before the id).
  let store = c.roots.storeRoot
  let ac = c.roots.actionCacheRoot
  if not (e.path.isWithin(store) or e.path.isWithin(ac)):
    return ""
  # No exemption for a workspace root nested below either root: a bundle
  # may declare its own workspace roots when the importer names none, and
  # declaring `<action-cache>/action-cache` as one must not make the cache's
  # own files carriable.
  var areas = c.prefixes & c.edges
  areas.add(stateAreas(store, ac))
  if e.path.withinAny(areas):
    return ""
  if e.kind == bekDir and (areas & @[contentsPath]).anyIt(
      it.len > 0 and it.isWithin(e.path)):
    return ""
  "bundle entry " & e.path.escape & " lies below the store or " &
    "action-cache root outside everything a bundle carries there (carried " &
    "prefixes, compiler probes, frozen dev-env scripts, action-cache edges " &
    "and blobs)"

proc computeClosure*(roots: BundleRoots;
                     devEnvs: openArray[FrozenDevEnv] = [];
                     selection = BundleSelection()): BundleClosure =
  ## §2. Read-only: scans the action cache, the workspace roots (only the
  ## part `selection` keeps, §2.1) and the store; writes nothing.
  result.producer = localProducer()
  result.roots = BundleRoots(
    storeRoot: normalizedRoot(roots.storeRoot),
    actionCacheRoot: normalizedRoot(roots.actionCacheRoot))
  for root in roots.workspaceRoots:
    let r = normalizedRoot(root)
    if r notin result.roots.workspaceRoots:
      result.roots.workspaceRoots.add(r)
  for env in devEnvs:
    result.devEnvs.add(FrozenDevEnv(projectRoot: normalizedRoot(env.projectRoot),
      scriptPath: normalizedRoot(env.scriptPath)))
  let ws = result.roots.workspaceRoots
  let storeRoot = result.roots.storeRoot
  let acRoot = result.roots.actionCacheRoot
  if ws.len == 0:
    fail("a store bundle needs at least one workspace root (--root=DIR)")
  # §2.1: each selection directory must lie inside a workspace root, or it
  # selects nothing and only says something false about the bundle.
  for (label, dirs) in [("exclude", selection.excluded),
                        ("include", selection.included)]:
    var seenDirs = initHashSet[string]()
    for dir in dirs:
      let d = normalizedRoot(dir)
      if not d.withinAny(ws):
        fail("the selection's " & label & " directory " & d &
          " is not inside a workspace root")
      if d notin seenDirs:
        seenDirs.incl(d)
        if label == "exclude": result.selection.excluded.add(d)
        else: result.selection.included.add(d)
  result.selection.excluded.sort()
  result.selection.included.sort()
  let sel = result.selection

  var selected: seq[string]
  var prefixes = initHashSet[string]()
  # Candidate restamps, keyed by path; filtered against the bundled set once
  # the bundle is expanded.
  var inputs = initTable[string, FileFingerprint]()

  var projectDirs: seq[string]
  findProjectDirs(ws, sel, [storeRoot, acRoot], projectDirs)

  # 1. Action-cache edges (and 2. their outputs).
  # `acRoot` is the shared cache root `resolveActionCacheRoot` returns: the
  # engine keeps its records in `action-cache/` and payloads in `cas/`.
  let recordsRoot = acRoot / "action-cache"
  if dirExists(recordsRoot):
    var cache = openActionCache(recordsRoot, attachShm = false)
    let cas = LocalCas(root: acRoot / "cas")
    for edgeDir in edgeDirs(recordsRoot):
      var weak: ContentDigest
      if not weakFromEdgeDirName(edgeDir.extractFilename, weak):
        continue
      var touching = false
      for record in loadPerEdgeRecords(cache, weak):
        let strongHex = toHex(record.strongFingerprint.bytes)
        # A relocatable record names its paths relative to the action's
        # directory, which it does not record. Find it among the project
        # directories, accepting one only where the record's own in-place
        # output check passes (the check a warm build makes there).
        var outputRoot = ""
        if record.hasRelativePaths:
          outputRoot = resolveRecordDir(record, projectDirs)
          if outputRoot.len == 0:
            if record.recordTouches(ws, sel):
              result.skippedRecords.add(SkippedRecord(edgeDir: edgeDir,
                strongHex: strongHex, kind: skUnplaceable,
                reason: "no project directory in the selection holds its " &
                  "relative outputs in the recorded state"))
              touching = true
            continue
        elif not record.recordTouches(ws, sel):
          continue
        touching = true
        # Import refuses any member outside the declared roots or in an
        # excluded directory, so a record writing there cannot travel (and
        # is reported instead). Below the store and action-cache roots only
        # the carried areas travel (`carriedClassProblem`): an output there
        # must be in a receipted prefix or one of the state areas.
        var outside = ""
        var outsideKind = skOutputOutsideRoots
        var where = "outside the bundle roots"
        for output in record.outputs:
          let p = resolvedPath(outputRoot, output.path)
          if p.isWithin(storeRoot) or p.isWithin(acRoot):
            let prefix = prefixDirOf(p, storeRoot)
            if not ((prefix.len > 0 and
                fileExists(prefix / ReceiptFileName)) or
                p.withinAny(stateAreas(storeRoot, acRoot))):
              outside = p
              where = "below the store or action-cache root outside " &
                "everything a bundle carries there"
              break
            continue
          if not p.withinAny(ws):
            outside = p
            break
          if not p.inSelection(ws, sel):
            outside = p
            outsideKind = skOutputOutsideSelection
            where = "outside the selection"
            break
        if outside.len > 0:
          result.skippedRecords.add(SkippedRecord(edgeDir: edgeDir,
            strongHex: strongHex, kind: outsideKind,
            reason: "an output lies " & where & ": " & outside))
          continue
        if outputRoot.len == 0:
          let mismatch = outputStateMismatch(record, "")
          if mismatch.len > 0:
            result.skippedRecords.add(SkippedRecord(edgeDir: edgeDir,
              strongHex: strongHex, kind: skOutputChanged, reason: mismatch))
            continue
        result.records.add(BundleRecordRef(edgeDir: edgeDir,
          strongHex: strongHex, outputRoot: outputRoot))
        for output in record.outputs:
          if output.metadata.kind != ffkMissing:
            selected.add(resolvedPath(outputRoot, output.path))
          if record.outputPayloadKind == opkCasBlobs:
            # The engine records into a `Store` (`cas/blake3/<aa>/<hex>`);
            # a `LocalCas` uses its own layout. Carry whichever holds it.
            let hex = toHex(output.blob.digest.bytes)
            for blob in [acRoot / "cas" / "blake3" / hex[0 .. 1] / hex,
                         cas.blobPath(output.blob.digest)]:
              if fileExists(blob):
                selected.add(blob)
        for input in record.inputs:
          if input.metadata.kind == ffkRegular and
              (input.path.isAbsolute or outputRoot.len > 0):
            let p = resolvedPath(outputRoot, input.path)
            if p.inSelection(ws, sel) and not p.isWithin(storeRoot) and
                not p.isWithin(acRoot):
              inputs[p] = input
      if touching:
        result.edges.add(edgeDir)
        selected.add(edgeDir)

  # 3. Project state.
  var dotRepro: seq[string]
  findDotReproDirs(ws, sel, [storeRoot, acRoot], dotRepro)
  selected.add(dotRepro)

  # Compiler-capability probe results (`repro_tool_profiles`): one success
  # marker per probed compiler identity. Without them the first build on the
  # importing machine re-runs a compile probe for every recipe toolchain.
  for probes in [storeRoot / "tool-store" / "compiler-probes",
                 storeRoot / "compiler-probes"]:
    if dirExists(probes):
      selected.add(probes)

  # 5. Frozen dev-env scripts (and the prefixes they name).
  for env in result.devEnvs:
    if not fileExists(env.scriptPath):
      fail("frozen dev-env script is missing: " & env.scriptPath)
    selected.add(env.scriptPath)
    scanStorePaths(readFile(env.scriptPath), storeRoot, prefixes)

  # Expand everything selected so far, then add the prefixes it references.
  var seen = initHashSet[string]()
  var entries: seq[BundleEntry]
  var hashBuf: seq[byte]
  for path in selected:
    expandInto(path, seen, entries, hashBuf)
  for entry in entries:
    let prefix = prefixDirOf(entry.path, storeRoot)
    if prefix.len > 0:
      prefixes.incl(prefix)
    if entry.kind == bekFile and
        entry.path.extractFilename == ".realization-info":
      for line in readFile(entry.path).splitLines():
        if line.startsWith("store-relative-path="):
          let rel = line["store-relative-path=".len .. ^1].strip()
          if rel.len > 0:
            let prefix = prefixDirOf(normalizedPath(storeRoot / rel),
              storeRoot)
            if prefix.len > 0 and dirExists(prefix):
              prefixes.incl(prefix)
  # 4. Store prefixes, whole, with their receipts.
  for prefix in prefixes:
    if fileExists(prefix / ReceiptFileName):
      result.prefixes.add(prefix)
      expandInto(prefix, seen, entries, hashBuf)
  result.prefixes.sort()

  # A directory output (or a `.repro/` tree) can hold an excluded
  # directory; nothing in one travels (§2.1).
  if sel.excluded.len > 0:
    var kept: seq[BundleEntry]
    for entry in entries:
      if entry.path.withinAny(ws) and not entry.path.inSelection(ws, sel):
        seen.excl(entry.path)
        continue
      kept.add(entry)
    entries = kept

  # Every member's parent directories that lie inside a root are members
  # too, so the unpacked tree has the exporter's directory modes. A parent
  # the selection excludes (the checkout around an `include` directory) is
  # not: tar creates it, and the bundle says nothing about it.
  var parents: seq[string]
  for entry in entries:
    var dir = entry.path.parentDir
    while dir.len > 1 and dir notin seen and
        (dir.inSelection(ws, sel) or dir.isWithin(storeRoot) or
         dir.isWithin(acRoot)):
      seen.incl(dir)
      parents.add(dir)
      dir = dir.parentDir
  for dir in parents:
    let st = liveState(dir)
    entries.add(BundleEntry(kind: bekDir, mode: st.mode, mtimeNs: st.mtimeNs,
      digest: "-", path: dir))

  entries.sort(proc (a, b: BundleEntry): int = cmp(a.path, b.path))
  result.entries = entries
  # Import holds the store and action-cache side to the classes above
  # (`checkEntryPlacement`); a bundle it would refuse is not worth writing.
  for e in result.entries:
    let problem = carriedClassProblem(result, e, "")
    if problem.len > 0:
      fail("cannot export: " & problem)

  # §5.3 restamps: fingerprinted inputs the bundle does not carry.
  var restampPaths: seq[string]
  for path in inputs.keys:
    if path notin seen:
      restampPaths.add(path)
  restampPaths.sort()
  for path in restampPaths:
    let st = liveState(path)
    if not st.exists or st.kind != bekFile:
      continue
    let recorded = inputs[path].metadata
    # Only a live file in the recorded state is worth vouching for: one that
    # has changed since would make its records miss anyway.
    if uint64(st.size) != recorded.sizeBytes or
        uint64(st.mtimeNs) != recorded.mtimeNs:
      continue
    result.restamps.add(RestampEntry(size: st.size, mtimeNs: st.mtimeNs,
      digest: fileBlake3Hex(path, hashBuf), path: path))

proc unpackedBytes*(closure: BundleClosure): int64 =
  for entry in closure.entries:
    result += entry.size

# ---------------------------------------------------------------------------
# contents (§4.1)
# ---------------------------------------------------------------------------

proc renderContentsBody(c: BundleClosure; forId = false): string =
  ## Everything but the header. The bundle id is derived from this text, so
  ## it is a function of what the bundle carries.
  var lines: seq[string]
  lines.add("producer\t" & escapeField(c.producer.version) & "\t" &
    escapeField(c.producer.revision))
  lines.add("root\tstore\t" & escapeField(c.roots.storeRoot))
  lines.add("root\taction-cache\t" & escapeField(c.roots.actionCacheRoot))
  for root in c.roots.workspaceRoots:
    lines.add("root\tworkspace\t" & escapeField(root))
  for dir in c.selection.excluded:
    lines.add("exclude\t" & escapeField(dir))
  for dir in c.selection.included:
    lines.add("include\t" & escapeField(dir))
  for env in c.devEnvs:
    lines.add("devenv\t" & escapeField(env.projectRoot) & "\t" &
      escapeField(env.scriptPath))
  for edge in c.edges:
    lines.add("edge\t" & escapeField(edge))
  for record in c.records:
    lines.add("record\t" & record.strongHex & "\t" &
      escapeField(record.edgeDir) & "\t" & escapeField(record.outputRoot))
  for prefix in c.prefixes:
    lines.add("prefix\t" & escapeField(prefix))
  for e in c.entries:
    # A directory's mtime says nothing about what the bundle carries, and
    # exporting moves the store root's own (it creates `bundles/<id>/`), so
    # the id leaves it out. The tar still restores it.
    let mtime = (if forId and e.kind == bekDir: 0'i64 else: e.mtimeNs)
    lines.add("entry\t" & $e.kind & "\t" & toOct(e.mode, 4) & "\t" & $e.size &
      "\t" & $mtime & "\t" & escapeField(e.digest) & "\t" &
      escapeField(e.path))
  for r in c.restamps:
    lines.add("restamp\t" & $r.size & "\t" & $r.mtimeNs & "\t" & r.digest &
      "\t" & escapeField(r.path))
  lines.join("\n") & "\n"

proc renderContents*(c: BundleClosure): string =
  ContentsHeader & "\n" & renderContentsBody(c)

proc bundleIdOf*(c: BundleClosure): string =
  ## 32 hex digits of BLAKE3 over the contents body.
  blake3.digest(renderContentsBody(c, forId = true)).toHex()[0 ..< 32]

proc parseContents*(text: string): BundleClosure =
  let lines = text.splitLines()
  if lines.len > 0 and lines[0] == ContentsHeaderV1:
    fail("unsupported contents version (" & ContentsHeaderV1 & "): the " &
      "bundle names no producer, so this repro cannot check it was made " &
      "by the same build; export it again with this repro")
  if lines.len == 0 or lines[0] != ContentsHeader:
    fail("not a store-bundle contents file (expected header " &
      ContentsHeader & ")")
  var sawProducer = false
  for i in 1 ..< lines.len:
    let line = lines[i]
    if line.len == 0:
      continue
    let f = line.split('\t')
    try:
      case f[0]
      of "producer":
        result.producer = BundleProducer(version: unescapeField(f[1]),
          revision: unescapeField(f[2]))
        sawProducer = true
      of "exclude": result.selection.excluded.add(unescapeField(f[1]))
      of "include": result.selection.included.add(unescapeField(f[1]))
      of "root":
        let value = unescapeField(f[2])
        case f[1]
        of "store": result.roots.storeRoot = value
        of "action-cache": result.roots.actionCacheRoot = value
        of "workspace": result.roots.workspaceRoots.add(value)
        else: fail("unknown root kind: " & f[1])
      of "devenv":
        result.devEnvs.add(FrozenDevEnv(projectRoot: unescapeField(f[1]),
          scriptPath: unescapeField(f[2])))
      of "edge": result.edges.add(unescapeField(f[1]))
      of "record":
        result.records.add(BundleRecordRef(strongHex: f[1],
          edgeDir: unescapeField(f[2]),
          outputRoot: (if f.len > 3: unescapeField(f[3]) else: "")))
      of "prefix": result.prefixes.add(unescapeField(f[1]))
      of "entry":
        var e = BundleEntry(mode: parseOctInt(f[2]), size: parseBiggestInt(f[3]),
          mtimeNs: parseBiggestInt(f[4]), digest: unescapeField(f[5]),
          path: unescapeField(f[6]))
        case f[1]
        of "f": e.kind = bekFile
        of "d": e.kind = bekDir
        of "l": e.kind = bekLink
        else: fail("unknown entry kind: " & f[1])
        result.entries.add(e)
      of "restamp":
        result.restamps.add(RestampEntry(size: parseBiggestInt(f[1]),
          mtimeNs: parseBiggestInt(f[2]), digest: f[3],
          path: unescapeField(f[4])))
      else:
        fail("unknown contents line kind: " & f[0])
    except IndexDefect, ValueError:
      fail("malformed contents line " & $(i + 1) & ": " & line)
  if not sawProducer:
    fail("bundle contents names no producer")

proc contentsPathFor*(storeRoot, bundleId: string): string =
  storeRoot / BundlesDirName / bundleId / "contents"

# ---------------------------------------------------------------------------
# Export (§4)
# ---------------------------------------------------------------------------

proc defaultExportOptions*(outDir: string): ExportOptions =
  ExportOptions(outDir: outDir, partSize: DefaultPartSize,
    zstdLevel: DefaultZstdLevel, zstdThreads: 0, halfName: DefaultHalfName)

proc partName*(prefix: string; index: int): string =
  ## `part-0000`, `part-0001`, ...
  prefix & align($index, 4, '0')

const PartPrefix* = "part-"

proc zstdCompressCommand*(zstdExe: string; level, threads: int): string =
  ## The compressor every half uses: `zstd -<level> --long=27`. The restoring
  ## side must pass the same `--long`.
  quoteShell(zstdExe) & " -q -c -" & $level &
    (if level > 19: " --ultra" else: "") &
    " --long=" & $ZstdWindowLog & " -T" & $threads

proc partsJson*(parts: seq[BundlePart]): JsonNode =
  result = newJArray()
  for p in parts:
    result.add(%*{"file": p.file, "bytes": p.bytes, "sha256": p.sha256})

proc parsePartsJson*(node: JsonNode): seq[BundlePart] =
  ## Refuses part names that could leave the half's directory.
  for p in node:
    let name = p["file"].getStr()
    if name.len == 0 or '/' in name or name.startsWith("."):
      raise newException(StoreBundleError, "refusing part name " & name.escape)
    result.add(BundlePart(file: name, bytes: p["bytes"].getBiggestInt(),
      sha256: p["sha256"].getStr().toLowerAscii()))

proc writeCompressedParts*(pipeline, outDir: string; partSize: int64;
                           prefix = PartPrefix):
    tuple[parts: seq[BundlePart], total: int64] =
  ## Run the shell `pipeline`, which writes the compressed stream to its
  ## stdout, and split that stream into `outDir/<prefix>NNNN` files of
  ## `partSize` bytes, hashing each as it is written. Parts a previous run
  ## left in `outDir` are removed first, so the directory holds exactly what
  ## the returned list names.
  if partSize <= 0:
    raise newException(StoreBundleError, "part size must be positive")
  createDir(outDir)
  for kind, path in walkDir(outDir):
    if kind == pcFile and path.extractFilename.startsWith(prefix):
      removeFile(path)
  # stderr goes to a file: it is read only after stdout is drained, and a
  # chatty tar must not block on a full pipe meanwhile.
  let errPath = outDir / ".pipeline.stderr"
  defer: removeFile(errPath)
  let p = uncontrolledStartProcess(requireTool("bash"), args = ["-c",
    "set -o pipefail; (" & pipeline & ") 2>" & quoteShell(errPath)],
    options = {})
  let output = p.outputStream
  var buf = newString(ReadChunk)
  var index = 0
  var current: File
  var currentSize = 0'i64
  var ctx: sha256
  var open = false
  var parts: seq[BundlePart]
  var total = 0'i64
  template closePart() =
    current.close()
    parts.add(BundlePart(file: partName(prefix, index - 1),
      bytes: currentSize, sha256: lowerHex(ctx.finish().data)))
    open = false
  while true:
    let n = output.readData(addr buf[0], buf.len)
    if n <= 0: break
    var offset = 0
    while offset < n:
      if not open:
        current = system.open(outDir / partName(prefix, index), fmWrite)
        inc index
        currentSize = 0
        ctx.init()
        open = true
      let take = min(n - offset, int(partSize - currentSize))
      discard current.writeBuffer(addr buf[offset], take)
      ctx.update(cast[ptr byte](addr buf[offset]), uint(take))
      currentSize += take
      total += take
      offset += take
      if currentSize == partSize:
        closePart()
  if open:
    closePart()
  let code = p.waitForExit()
  p.close()
  let errText = (if fileExists(errPath): readFile(errPath) else: "")
  if code != 0:
    raise newException(StoreBundleError, "archive pipeline failed (exit " &
      $code & "): " & errText.strip())
  (parts, total)

proc manifestJson(c: BundleClosure; id, contentsPath, contentsSha: string;
                  opts: ExportOptions; parts: seq[BundlePart];
                  compressed: int64): JsonNode =
  var partNodes = newJArray()
  partNodes = partsJson(parts)
  var devEnvNodes = newJArray()
  for env in c.devEnvs:
    devEnvNodes.add(%*{"projectRoot": env.projectRoot,
      "script": env.scriptPath})
  %*{
    "schema": ManifestSchema,
    "half": opts.halfName,
    "bundleId": id,
    "archive": {"format": "tar", "tarFormat": "posix", "root": "/"},
    "compression": {"algorithm": "zstd", "level": opts.zstdLevel,
      "long": ZstdWindowLog},
    "partSize": opts.partSize,
    "parts": partNodes,
    "compressedBytes": compressed,
    "unpackedBytes": c.unpackedBytes,
    "entryCount": c.entries.len,
    "contents": {"path": contentsPath, "sha256": contentsSha},
    "roots": {"storeRoot": c.roots.storeRoot,
      "actionCacheRoot": c.roots.actionCacheRoot,
      "workspaceRoots": %c.roots.workspaceRoots},
    "selection": {"exclude": %c.selection.excluded,
      "include": %c.selection.included},
    "producer": {"version": c.producer.version,
      "revision": c.producer.revision},
    "frozenDevEnvs": devEnvNodes,
    # `v1`'s field, kept with the producer's revision.
    "reproRevision": c.producer.revision
  }

proc exportBundle*(c: BundleClosure; opts: ExportOptions): ExportReport =
  ## Write `c` as a bundle half under `opts.outDir`. Also writes the
  ## `contents` file under the exporting store's `bundles/<id>/`, because it
  ## travels as the first tar member at that very path.
  let tarExe = requireTool("tar")
  let zstdExe = requireTool("zstd")
  let id = bundleIdOf(c)
  let contentsText = renderContents(c)
  if contentsText.len > MaxContentsBytes:
    fail("the bundle's contents list is " & $contentsText.len &
      " bytes, more than import reads (" & $MaxContentsBytes & ")")
  let contentsPath = contentsPathFor(c.roots.storeRoot, id)
  createDir(contentsPath.parentDir)
  writeFile(contentsPath, contentsText)
  createDir(opts.outDir)
  let listPath = opts.outDir / ("." & opts.halfName & ".members")
  block:
    var list = open(listPath, fmWrite)
    defer: list.close()
    list.write(relToSlash(contentsPath))
    list.write('\0')
    for e in c.entries:
      list.write(relToSlash(e.path))
      list.write('\0')
  defer: removeFile(listPath)

  let pipeline = quoteShell(tarExe) &
    " --format=posix --numeric-owner --no-recursion --null" &
    " --verbatim-files-from -C / -cf - -T " & quoteShell(listPath) &
    " | " & zstdCompressCommand(zstdExe, opts.zstdLevel, opts.zstdThreads)
  let (parts, total) = writeCompressedParts(pipeline, opts.outDir,
    opts.partSize)
  let contentsSha = lowerHex(sha256.digest(contentsText).data)
  let manifestPath = opts.outDir / (opts.halfName & ".json")
  writeFile(manifestPath, pretty(manifestJson(c, id, contentsPath,
    contentsSha, opts, parts, total)) & "\n")
  result = ExportReport(bundleId: id, manifestPath: manifestPath,
    contentsPath: contentsPath, parts: parts, entryCount: c.entries.len,
    unpackedBytes: c.unpackedBytes, compressedBytes: total)

# ---------------------------------------------------------------------------
# Import (§5)
# ---------------------------------------------------------------------------

type ParsedManifest = object
  bundleId: string
  parts: seq[BundlePart]
  contentsPath: string
  contentsSha: string

proc readManifest(path: string): ParsedManifest =
  if not fileExists(path):
    fail("bundle manifest not found: " & path)
  let node =
    try: parseJson(readFile(path))
    except JsonParsingError as e: fail("malformed bundle manifest " & path &
      ": " & e.msg)
  try:
    if node["schema"].getStr() != ManifestSchema:
      fail("unsupported bundle schema " & node["schema"].getStr() &
        " (this repro reads " & ManifestSchema & ")")
    result.bundleId = node["bundleId"].getStr()
    result.contentsPath = node["contents"]["path"].getStr()
    result.contentsSha = node["contents"]["sha256"].getStr()
    result.parts = parsePartsJson(node["parts"])
  except KeyError as e:
    fail("bundle manifest " & path & " lacks a field: " & e.msg)
  if result.parts.len == 0:
    fail("bundle manifest lists no parts")
  if not result.contentsPath.isAbsolute:
    fail("bundle contents path must be absolute: " & result.contentsPath)

proc readVerifiedPart*(dir: string; part: BundlePart): string =
  ## The whole part, after its SHA-256 matched. §5 step 1: no byte reaches
  ## the decompressor before its part is verified.
  let path = dir / part.file
  if not fileExists(path):
    fail("bundle part missing: " & path)
  result = readFile(path)
  if int64(result.len) != part.bytes:
    fail("bundle part " & part.file & " is " & $result.len &
      " bytes, the manifest says " & $part.bytes)
  let actual = lowerHex(sha256.digest(result).data)
  if actual != part.sha256:
    fail("bundle part " & part.file & " has SHA-256 " & actual &
      ", the manifest says " & part.sha256)

type FeedShared = object
  ## Shared between `feedParts` and its writer thread. `writeError` is
  ## written by the writer only, and read only after it has been joined.
  chan: Channel[string]
  fd: cint
  writeError: cint

proc feedWriter(shared: ptr FeedShared) {.thread.} =
  ## Push each verified part into the unpacker's stdin. An empty string is
  ## the end. After a failed write it keeps draining, so the producer never
  ## blocks on a full channel.
  while true:
    let data = shared.chan.recv()
    if data.len == 0:
      break
    if shared.writeError != 0:
      continue
    var offset = 0
    while offset < data.len:
      let n = posix.write(shared.fd, unsafeAddr data[offset], data.len - offset)
      if n < 0:
        if errno == EINTR: continue
        shared.writeError = errno
        break
      offset += n

type CaptureShared = object
  ## Shared between `feedParts` and its reader thread, which drains the
  ## command's stdout into `chan` so the command never blocks on a full
  ## pipe while this process is busy feeding its stdin.
  chan: Channel[string]
  fd: cint
  limit: int

proc captureReader(shared: ptr CaptureShared) {.thread.} =
  var buf = newString(1 shl 16)
  var total = 0
  while true:
    let n = posix.read(shared.fd, addr buf[0], buf.len)
    if n < 0:
      if errno == EINTR: continue
      break
    if n == 0:
      break
    # Keep at most `limit` bytes in all. Past the limit the bytes are read
    # and dropped, so the command still runs to its end; the caller sees a
    # capture of exactly `limit` bytes and decides what that means.
    let keep = min(n, shared.limit - total)
    total += n
    if keep > 0:
      shared.chan.send(buf[0 ..< keep])

proc feedParts*(dir: string; parts: seq[BundlePart]; command: string;
               stopEarly: bool; captured: ptr string = nil;
               captureLimit = high(int)): int =
  ## Run `command` with the verified parts streamed to its stdin and return
  ## its exit code. Without `captured`, the command must redirect its own
  ## stdout and stderr to files: nothing reads those pipes while the feed
  ## runs. With `captured`, its stdout (at most `captureLimit` bytes) is read
  ## into memory, so a caller that must write nothing (the contents peek,
  ## §5 step 2) needs no scratch file; its stderr must still be redirected.
  ## With `stopEarly` the feed stops quietly when the command exits before
  ## reading everything (the contents peek).
  ##
  ## A writer thread pushes part N while this thread reads and hashes part
  ## N+1, so verification overlaps the unpack instead of adding to it; still,
  ## no byte reaches the unpacker before its whole part has been verified.
  ## SIGPIPE is ignored meanwhile, so an unpacker that dies mid-stream
  ## surfaces as its exit status rather than killing this process.
  var ignore, previous: Sigaction
  ignore.sa_handler = SIG_IGN
  discard sigemptyset(ignore.sa_mask)
  discard sigaction(SIGPIPE, ignore, previous)
  defer: discard sigaction(SIGPIPE, previous, ignore)
  let p = uncontrolledStartProcess(requireTool("bash"), args = ["-c", command],
    options = {})
  var completed = false
  defer:
    if not completed:
      # A refused part: stop the unpacker rather than let it finish on a
      # truncated stream, and reap it.
      try: p.terminate() except CatchableError: discard
      try: discard p.waitForExit(); p.close() except CatchableError: discard
  var capture: ptr CaptureShared = nil
  var reader: Thread[ptr CaptureShared]
  if captured != nil:
    capture = cast[ptr CaptureShared](allocShared0(sizeof(CaptureShared)))
    capture.chan.open()
    capture.fd = cint(p.outputHandle)
    capture.limit = captureLimit
    createThread(reader, captureReader, capture)
  var captureJoined = false
  defer:
    if capture != nil and not captureJoined:
      # A refused part: end the command so its stdout reaches end of file,
      # then reap the reader (this runs before the defer above closes `p`).
      try: p.terminate() except CatchableError: discard
      joinThread(reader)
      capture.chan.close()
      deallocShared(capture)
  let shared = cast[ptr FeedShared](allocShared0(sizeof(FeedShared)))
  shared.chan.open(maxItems = 1)
  shared.fd = cint(p.inputHandle)
  var writer: Thread[ptr FeedShared]
  createThread(writer, feedWriter, shared)
  var writeError: cint = 0
  try:
    for part in parts:
      if stopEarly and not p.running:
        break
      let bytes = readVerifiedPart(dir, part)
      if shared.writeError != 0 and stopEarly:
        break
      shared.chan.send(bytes)
  finally:
    shared.chan.send("")
    joinThread(writer)
    writeError = shared.writeError
    shared.chan.close()
    deallocShared(shared)
    # Closing through the stream closes the pipe exactly once (`close(p)`
    # closes the stream when one exists, the raw handle otherwise).
    try: p.inputStream.close() except CatchableError: discard
  result = p.waitForExit()
  if capture != nil:
    # The command has exited, so its stdout reaches end of file (unless a
    # child it left behind still holds it; the commands here leave none).
    joinThread(reader)
    captured[].setLen(0)
    while true:
      let (ok, chunk) = capture.chan.tryRecv()
      if not ok: break
      captured[].add(chunk)
    capture.chan.close()
    deallocShared(capture)
    captureJoined = true
  p.close()
  completed = true
  if writeError != 0 and result == 0 and not stopEarly:
    fail("writing to the unpacker failed: " & $strerror(writeError))

proc checkRoots*(bundle, local: BundleRoots) =
  ## §3: refuse before writing anything if any root differs.
  var problems: seq[string]
  if normalizedRoot(local.storeRoot) != bundle.storeRoot:
    problems.add("store root: bundle " & bundle.storeRoot & ", local " &
      normalizedRoot(local.storeRoot) &
      " (set REPRO_STORE_ROOT or --store-root)")
  if normalizedRoot(local.actionCacheRoot) != bundle.actionCacheRoot:
    problems.add("action-cache root: bundle " & bundle.actionCacheRoot &
      ", local " & normalizedRoot(local.actionCacheRoot) &
      " (set REPROBUILD_ACTION_CACHE_ROOT or --action-cache-root)")
  if local.workspaceRoots.len > 0:
    var localWs: seq[string]
    for r in local.workspaceRoots: localWs.add(normalizedRoot(r))
    for r in bundle.workspaceRoots:
      if r notin localWs:
        problems.add("workspace root " & r & " is not among the local " &
          "roots " & localWs.join(", "))
  if problems.len > 0:
    fail("bundle was produced at different absolute paths; relocation is " &
      "not supported, so nothing was imported:\n  " & problems.join("\n  "))

proc checkProducer*(bundle, local: BundleProducer) =
  ## §5 step 2: refuse, before writing anything, a bundle another `repro`
  ## made. Its provider-compile and interface records fingerprint the engine
  ## binary, so this one would miss on them after writing the whole bundle.
  if bundle.version != local.version or bundle.revision != local.revision:
    fail("bundle was made by repro " & bundle.version & " (revision " &
      bundle.revision & "), and this is repro " & local.version &
      " (revision " & local.revision & "); nothing was imported. Import it " &
      "with the repro that made it (a workspace bundle carries it in its " &
      "Nix half), or export it again with this one")

proc checkEntryPlacement*(c: BundleClosure; contentsPath: string) =
  ## Every declared entry must lie inside a declared root and in the
  ## selection (§2.1), and none below a declared symlink, so that what
  ## `contents` declares cannot write anywhere else. (`checkMembers` then
  ## holds the archive to exactly these entries.) `contentsPath` may be ""
  ## (at export, before the id).
  var allowed = @[c.roots.storeRoot, c.roots.actionCacheRoot]
  allowed.add(c.roots.workspaceRoots)
  for root in allowed:
    if not root.isAbsolute or root == "/":
      fail("bundle declares an unusable root: " & root.escape)
  let ws = c.roots.workspaceRoots
  for (label, dirs) in [("exclude", c.selection.excluded),
                        ("include", c.selection.included)]:
    for dir in dirs:
      if not dir.isAbsolute or normalizedPath(dir) != dir or
          not dir.withinAny(ws):
        fail("bundle declares an " & label &
          " directory outside its workspace roots: " & dir.escape)
  template inSel(path: string): bool =
    path.isWithin(c.roots.storeRoot) or
      path.isWithin(c.roots.actionCacheRoot) or path.inSelection(ws,
        c.selection)
  # A prefix line names a store prefix directory and nothing else: the
  # symlink rule below trusts what lies inside one, and the unpack excludes
  # an intact one wholesale.
  for prefix in c.prefixes:
    if normalizedPath(prefix) != prefix or
        prefixDirOf(prefix, c.roots.storeRoot) != prefix:
      fail("bundle declares " & prefix.escape & " as a prefix, which is " &
        "not a store prefix directory")
  # An edge line names a per-edge record directory and nothing else: the
  # rule below trusts what lies inside one.
  let hot = c.roots.actionCacheRoot / "action-cache" / "hot-records"
  for edge in c.edges:
    var weak: ContentDigest
    if edge.parentDir != hot or
        not weakFromEdgeDirName(edge.extractFilename, weak):
      fail("bundle declares " & edge.escape & " as an action-cache edge, " &
        "which is not a per-edge record directory")
  var links = initHashSet[string]()
  for e in c.entries:
    if not e.path.isAbsolute or normalizedPath(e.path) != e.path or
        not e.path.withinAny(allowed):
      fail("bundle entry outside its declared roots: " & e.path)
    if not inSel(e.path):
      fail("bundle entry in a directory its selection excludes: " & e.path)
    let classProblem = carriedClassProblem(c, e, contentsPath)
    if classProblem.len > 0:
      fail(classProblem)
    if e.kind == bekLink:
      # A link at a root, or above one, moves the whole root: everything the
      # importer writes there afterwards would follow it.
      for root in allowed:
        if root.isWithin(e.path):
          fail("bundle declares the symlink " & e.path.escape & " at or " &
            "above the root " & root.escape)
      # After the unpack the importer, and every later `repro`, opens its
      # own files below the store and action-cache roots (`index.db`, `cas/`,
      # `tmp/`, the per-edge records, ...) and follows a link it finds
      # there. Only a carried prefix holds links of its own (a package's
      # `lib/libfoo.so -> libfoo.so.1`), and nothing writes into a prefix
      # once it is registered, so a link anywhere else on that side is
      # refused: `<store>/index.db -> /etc/x` would otherwise have the store
      # open, and create, its database wherever the link points.
      if (e.path.isWithin(c.roots.storeRoot) or
          e.path.isWithin(c.roots.actionCacheRoot)) and
          not c.prefixes.anyIt(e.path.isWithin(it) and e.path != it):
        fail("bundle declares the symlink " & e.path.escape & " below the " &
          "store or action-cache root outside every carried prefix; the " &
          "importer would write through it")
      links.incl(e.path)
  if links.len > 0:
    # A member written below a symlink lands wherever the link points, and
    # so does a restamp's mtime write (step 5.3).
    for path in c.entries.mapIt(it.path) & c.restamps.mapIt(it.path) &
        @[contentsPath]:
      var dir = path.parentDir
      while dir.len > 1:
        if dir in links:
          fail("bundle path " & path & " lies below the symlink entry " & dir)
        dir = dir.parentDir
  for r in c.records:
    if r.outputRoot.len > 0 and not r.outputRoot.inSelection(ws,
        c.selection):
      fail("bundle record directory outside the workspace roots or the " &
        "selection: " & r.outputRoot)
  for r in c.restamps:
    if not r.path.inSelection(ws, c.selection):
      fail("bundle restamp outside the workspace roots or the selection: " &
        r.path)

proc deepestRoot(path: string; roots: openArray[string]): string =
  ## The longest of `roots` that holds `path`; refuses when none does.
  for r in roots:
    if path.isWithin(r) and r.len > result.len:
      result = r
  if result.len == 0:
    fail("bundle path outside its declared roots: " & path)

proc linkedAncestor(path, root: string;
                    memo: var Table[string, string]): string =
  ## The first existing directory strictly between `path` and `root` that is
  ## a symlink on this machine, or "". `memo` maps each directory already
  ## walked to its answer, so paths sharing directories lstat each once.
  var walked: seq[string]
  var dir = path.parentDir
  while dir.len > root.len and dir.isWithin(root):
    if dir in memo:
      result = memo[dir]
      break
    walked.add(dir)
    var st: Stat
    if lstat(dir.cstring, st) == 0 and S_ISLNK(st.st_mode):
      result = dir
      break
    dir = dir.parentDir
  for d in walked:
    memo[d] = result

proc checkNoLinkedAncestors(c: BundleClosure; contentsPath: string) =
  ## §5 step 3, before anything is written: GNU tar follows a symlink it
  ## finds on disk in a member's leading directories, and so do the
  ## importer's own writes (the import marker beside `contents`). A link
  ## already below a root, whether an earlier bundle declared it as an `l`
  ## entry or anyone else made it, would carry this unpack out of the roots
  ## although every member is declared. So no existing directory between a
  ## member and the deepest root that holds it may be a symlink. The roots
  ## themselves are the machine's own configuration and may be links.
  var roots = @[c.roots.storeRoot, c.roots.actionCacheRoot]
  roots.add(c.roots.workspaceRoots)
  var memo = initTable[string, string]()
  for path in c.entries.mapIt(it.path) & @[contentsPath]:
    let link = linkedAncestor(path, deepestRoot(path, roots), memo)
    if link.len > 0:
      fail("refusing the bundle before unpacking it: " & path.escape &
        " lies below " & link.escape & ", which is a symlink on this " &
        "machine, so the unpack would write through it; nothing was " &
        "written")

proc listBundleMembers*(dir: string; parts: seq[BundlePart];
                        listingPath: string; zstd = "") =
  ## Write GNU tar's verbose listing of the stream the verified `parts` of
  ## `dir` carry to `listingPath`, one member per line, in the form
  ## `tar_members.parseListingLine` reads. It is the very tar that extracts
  ## the stream, reading the same verified bytes, so the listing names what
  ## extraction will write: a check of it is a check of the extraction.
  ## `zstd` is the decompressor the extraction will use; empty means the one
  ## on `PATH` (the Nix half passes its own fallback, so a host without zstd
  ## can still be checked). Raises StoreBundleError when tar cannot read the
  ## whole stream.
  let zstdExe = if zstd.len > 0: zstd else: requireTool("zstd")
  let tarExe = requireTool("tar")
  let errPath = listingPath & ".stderr"
  defer: removeFile(errPath)
  # `LC_ALL=C`: every non-ASCII byte is listed as a `\ooo` escape, whatever
  # the caller's locale.
  let command = "set -o pipefail; (" & quoteShell(zstdExe) & " -q -dc --long=" &
    $ZstdWindowLog & " - | LC_ALL=C " & quoteShell(tarExe) &
    " -tvf - --quoting-style=c --numeric-owner --full-time) >" &
    quoteShell(listingPath) & " 2>" & quoteShell(errPath)
  let code = feedParts(dir, parts, command, stopEarly = false)
  if code != 0:
    fail("cannot list the bundle's archive (exit " & $code & "): " &
      (if fileExists(errPath): readFile(errPath).strip() else: ""))

proc checkMembers*(c: BundleClosure; contentsPath, listingPath: string) =
  ## §5 step 3, before anything is written: the archive's members, as listed
  ## in `listingPath`, must be exactly the `contents` member and one member
  ## per `entry` (§4.1: "Every tar entry has exactly one `entry` line, and
  ## there are no others"), each carried as the type it is declared with, a
  ## symlink with its declared target and a hard link to a declared file; and
  ## they must pass the rules every half applies (`tar_members.admit`,
  ## `finish`). Raises StoreBundleError naming the first offending member.
  template refuse(problem: string) =
    fail("refusing the bundle before unpacking it: " & problem &
      "; nothing was written")
  var declared = initTable[string, DeclaredMember]()
  declared[relToSlash(contentsPath)] = DeclaredMember(kind: dkPlainFile)
  for e in c.entries:
    let name = relToSlash(e.path)
    if name in declared:
      refuse("contents declares " & e.path.escape & " twice")
    declared[name] =
      case e.kind
      of bekFile: DeclaredMember(kind: dkFile)
      of bekDir: DeclaredMember(kind: dkDir)
      of bekLink: DeclaredMember(kind: dkLink, target: e.digest)
  var members = initMemberSet()
  try:
    for (_, m) in listingMembers(listingPath):
      var problem = members.admit(m)
      if problem.len == 0:
        let name = memberPath(m)
        if name notin declared:
          problem = "member " & m.name.escape &
            " is not declared in the bundle's contents"
        else:
          problem = declaredMemberProblem(m, declared[name])
          if problem.len == 0 and m.kind == 'h' and
              (m.linkTarget notin declared or
               declared[m.linkTarget].kind != dkFile):
            problem = "hard link " & m.name.escape & " names " &
              m.linkTarget.escape & ", which is not a declared file entry"
      if problem.len > 0:
        refuse(problem)
  except ValueError as e:
    refuse(e.msg)
  let late = members.finish()
  if late.len > 0:
    refuse(late)
  if members.len != declared.len:
    # Every member admitted is declared and distinct, so a short count means
    # a declared one is missing.
    for name in declared.keys:
      if name notin members:
        refuse("member " & ("/" & name).escape &
          ", which contents declares, is not in the archive")

proc entryMatches(e: BundleEntry; checkContent: bool;
                  buf: var seq[byte]): string =
  ## "" when the live path is in the recorded state.
  let st = liveState(e.path)
  if not st.exists:
    return "missing"
  if st.kind != e.kind:
    return "kind " & $st.kind & ", expected " & $e.kind
  case e.kind
  of bekFile:
    if st.size != e.size:
      return "size " & $st.size & ", expected " & $e.size
    if st.mtimeNs != e.mtimeNs:
      return "mtime " & $st.mtimeNs & ", expected " & $e.mtimeNs
    if checkContent and fileBlake3Hex(e.path, buf) != e.digest:
      return "content digest differs"
  of bekLink:
    if expandSymlink(e.path) != e.digest:
      return "link target differs"
  of bekDir:
    discard
  ""

proc prefixIntact(prefix: string): bool =
  ## A local prefix that a receipt seals under its own name (§5 step 3): its
  ## 40-hex name, or an older build's 16-hex name the receipt records as
  ## exactly this path (``prefixDirMatchesReceipt``). ``prefix`` lies at
  ## ``<root>/prefixes/<package>/<leaf>``, so its path relative to the root
  ## it was recorded against is the last three segments.
  let receiptPath = prefix / ReceiptFileName
  if not fileExists(receiptPath):
    return false
  try:
    let receipt = readReceiptFile(receiptPath)
    let relDir = "prefixes/" & prefix.parentDir.extractFilename & "/" &
      prefix.extractFilename
    prefixDirMatchesReceipt(relDir, receipt)
  except CatchableError:
    false

proc peekContents(dir: string; m: ParsedManifest): string =
  ## The `contents` member, which export writes first. It is read from the
  ## shortest prefix of the parts that yields it whole: one part, in every
  ## bundle whose compressed contents list fits in the first part. Each try
  ## is checked against the manifest's SHA-256 of `contents`. It is read
  ## into memory: §5 step 2 writes nothing, not even into the bundle's own
  ## directory, and `repro bundle inspect` writes nothing at all.
  let zstdExe = requireTool("zstd")
  let tarExe = requireTool("tar")
  let command = quoteShell(zstdExe) & " -q -dc --long=" &
    $ZstdWindowLog & " - 2>/dev/null | " & quoteShell(tarExe) &
    " -xOf - --occurrence=1 " & quoteShell(relToSlash(m.contentsPath)) &
    " 2>/dev/null"
  for count in 1 .. m.parts.len:
    # A truncated stream makes the pipeline fail; only the hash decides.
    var text = ""
    discard feedParts(dir, m.parts[0 ..< count], command, stopEarly = true,
      captured = addr text, captureLimit = MaxContentsBytes + 1)
    if text.len > MaxContentsBytes:
      fail("bundle contents entry is larger than " & $MaxContentsBytes &
        " bytes; nothing was imported")
    if lowerHex(sha256.digest(text).data) == m.contentsSha:
      return text
  fail("bundle contents entry does not match the manifest's SHA-256 " &
    "(or is not the first member)")

type VerifiedContents* = object
  ## A bundle half's `contents`, read from parts whose SHA-256 matched,
  ## whose own SHA-256 matched the manifest and whose bundle id matched
  ## (§5 steps 1 and 2, without the comparison with the local machine).
  bundleId*: string
  parts*: seq[BundlePart]
  contentsPath*: string
    ## Where `contents` unpacks (`<store>/bundles/<id>/contents`), checked
    ## against the id.
  closure*: BundleClosure
  manifest*: JsonNode
    ## The transport manifest as read; its fields are unverified.

proc readVerifiedContents*(dir: string;
                           manifestName = DefaultHalfName & ".json"):
    VerifiedContents =
  ## Read and verify a half's `contents` without writing anything. Shared by
  ## import and by `repro bundle inspect` (§7.1).
  let m = readManifest(dir / manifestName)
  let c = parseContents(peekContents(dir, m))
  if contentsPathFor(c.roots.storeRoot, m.bundleId) != m.contentsPath or
      bundleIdOf(c) != m.bundleId:
    fail("bundle id does not match its contents")
  checkEntryPlacement(c, m.contentsPath)
  result = VerifiedContents(bundleId: m.bundleId, parts: m.parts,
    contentsPath: m.contentsPath, closure: c,
    manifest: parseJson(readFile(dir / manifestName)))

proc importBundle*(opts: ImportOptions; local: BundleRoots;
                   producer = localProducer()): ImportReport =
  ## §5. `local` carries the roots resolved on this machine; workspace roots
  ## may be empty, in which case the bundle's are accepted as long as the
  ## store and action-cache roots match. `producer` is the `repro` doing the
  ## import (§5 step 2).
  let dir = opts.bundleDir
  let manifestName =
    if opts.manifestName.len > 0: opts.manifestName
    else: DefaultHalfName & ".json"
  var phaseStart = getMonoTime()
  template phaseDone(name: string) =
    let now = getMonoTime()
    result.phaseSeconds.add((name, (now - phaseStart).inNanoseconds.float / 1e9))
    phaseStart = now
  # Steps 1 + 2: verify the parts that carry `contents`, read it, check its
  # id, roots, producer and placement. Nothing is written before this.
  let verified = readVerifiedContents(dir, manifestName)
  let c = verified.closure
  let m = (bundleId: verified.bundleId, parts: verified.parts,
    contentsPath: verified.contentsPath)
  checkRoots(c.roots, local)
  checkProducer(c.producer, producer)
  result.bundleId = m.bundleId
  result.roots = c.roots
  result.devEnvs = c.devEnvs

  var hashBuf: seq[byte]
  let marker = c.roots.storeRoot / BundlesDirName / m.bundleId /
    ImportedMarkerName
  var alreadyThere = false
  if fileExists(marker) and not opts.force:
    alreadyThere = true
    for e in c.entries:
      # Re-witnessing (step 5.2) rewrote the record files of the earlier
      # import, so for those only presence is checked.
      if e.path.withinAny(c.edges):
        if not liveState(e.path).exists:
          alreadyThere = false
          break
        continue
      if entryMatches(e, checkContent = false, hashBuf).len > 0:
        alreadyThere = false
        break

  var excluded = initHashSet[string]()
  if alreadyThere:
    result.skippedExtraction = true
  else:
    phaseDone("verify contents + roots")
    # Step 3: before anything is written, list the archive with the tar that
    # will extract it and refuse unless its members are exactly the declared
    # ones. The part hashes come from the same unsigned manifest as the
    # parts, so they cannot confine the unpack; this check does.
    let listingPath = dir / ("." & m.bundleId & ".members")
    defer: removeFile(listingPath)
    listBundleMembers(dir, m.parts, listingPath)
    checkMembers(c, m.contentsPath, listingPath)
    removeFile(listingPath)
    checkNoLinkedAncestors(c, m.contentsPath)
    phaseDone("check members")
    # Then unpack, leaving intact content-addressed prefixes alone.
    for prefix in c.prefixes:
      if dirExists(prefix) and prefixIntact(prefix):
        excluded.incl(prefix)
        result.excludedPrefixes.add(prefix)
    let excludePath = dir / ("." & m.bundleId & ".exclude")
    block:
      var f = open(excludePath, fmWrite)
      defer: f.close()
      for prefix in result.excludedPrefixes:
        f.write(relToSlash(prefix) & "\n")
    defer: removeFile(excludePath)
    let zstdExe = requireTool("zstd")
    let tarExe = requireTool("tar")
    let errPath = dir / ("." & m.bundleId & ".stderr")
    defer: removeFile(errPath)
    let command = "set -o pipefail; (" & quoteShell(zstdExe) &
      " -q -dc --long=" & $ZstdWindowLog & " - | " & quoteShell(tarExe) &
      " -x -C / --numeric-owner --no-same-owner -p --anchored" &
      " --no-wildcards -X " & quoteShell(excludePath) & " -f -) >" &
      quoteShell(errPath) & " 2>&1"
    let code = feedParts(dir, m.parts, command, stopEarly = false)
    if code != 0:
      fail("unpack failed (exit " & $code & "): " &
        (if fileExists(errPath): readFile(errPath).strip() else: ""))

  phaseDone("unpack")
  # Step 4: verify every unpacked entry against `contents`.
  var excludedList: seq[string]
  for prefix in excluded: excludedList.add(prefix)
  for e in c.entries:
    if e.path.withinAny(excludedList):
      continue
    if alreadyThere and e.path.withinAny(c.edges):
      continue
    let problem = entryMatches(e, checkContent = not alreadyThere, hashBuf)
    if problem.len > 0:
      fail("unpacked entry does not match the bundle (" & problem & "): " &
        e.path & "; nothing was registered")
    inc result.verifiedEntries

  phaseDone("verify entries")
  # Step 5.1: prefixes, from their receipts, held by a bundle root.
  let recovered = recoverStoreRoot(c.roots.storeRoot)
  result.reinsertedPrefixes = recovered.reinsertedPrefixes.len
  result.quarantinedPrefixes = recovered.quarantinedPrefixes
  block:
    var store = openStore(c.roots.storeRoot)
    defer: store.close()
    let rootId = "bundle:" & m.bundleId
    store.registerRoot(rootId, rkWorkspace)
    for prefix in c.prefixes:
      if not fileExists(prefix / ReceiptFileName):
        continue
      let receipt = readReceiptFile(prefix / ReceiptFileName)
      if store.lookupPrefix(receipt.realizationHash).found:
        store.attachPrefixToRoot(rootId, receipt.realizationHash)

  phaseDone("register prefixes")
  # Step 5.2: re-witness the records the exporter vouched for.
  if c.records.len > 0:
    var cache = openActionCache(c.roots.actionCacheRoot / "action-cache",
      attachShm = false)
    var wanted = initTable[string, Table[string, string]]()
    for r in c.records:
      wanted.mgetOrPut(r.edgeDir, initTable[string, string]())[r.strongHex] =
        r.outputRoot
    for edgeDir, strongs in wanted:
      var weak: ContentDigest
      if not weakFromEdgeDirName(edgeDir.extractFilename, weak):
        continue
      for record in loadPerEdgeRecords(cache, weak):
        let hex = toHex(record.strongFingerprint.bytes)
        if hex in strongs:
          discard refreshRestoredOutputs(cache, record, strongs[hex])
          inc result.rewitnessedRecords

  phaseDone("re-witness records")
  # Step 5.3: restamp source inputs whose bytes are the recorded ones. The
  # mtime write follows symlinks in the path's directories, so a restamp
  # below a directory that is a symlink on this machine (one an earlier
  # bundle declared, say) would stamp a file outside the roots: it is left
  # alone and counted as a mismatch, which costs only a rebuild of what read it.
  var restampMemo = initTable[string, string]()
  for r in c.restamps:
    if linkedAncestor(r.path, deepestRoot(r.path, c.roots.workspaceRoots),
        restampMemo).len > 0:
      inc result.restampMismatches
      continue
    let st = liveState(r.path)
    if not st.exists or st.kind != bekFile or st.size != r.size:
      inc result.restampMismatches
      continue
    if st.mtimeNs == r.mtimeNs:
      continue
    if fileBlake3Hex(r.path, hashBuf) != r.digest:
      inc result.restampMismatches
      continue
    setMtimeNs(r.path, r.mtimeNs)
    inc result.restamped

  phaseDone("restamp inputs")
  # Step 6.
  createDir(marker.parentDir)
  writeFile(marker, m.bundleId & "\n")
