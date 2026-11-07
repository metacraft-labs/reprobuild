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

# This module's C (including the SHA-256 it instantiates for part checks)
# runs once per byte of a bundle, so it is optimized whatever the Nim build
# mode is. See docs/store-bundles.md §10 for the measurement.
{.localPassC: "-O3".}

import std/[algorithm, json, monotimes, os, osproc, posix, sets, streams,
    strutils, tables, times]
import nimcrypto/sha2
import blake3
import repro_hash
import repro_core/ambient_execution
import ../repro_local_store
import ./store
import ./prefix_paths

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
    roots*: BundleRoots
    edges*: seq[string]
    records*: seq[BundleRecordRef]
    prefixes*: seq[string]
    entries*: seq[BundleEntry]
    restamps*: seq[RestampEntry]
    devEnvs*: seq[FrozenDevEnv]
    skippedRecords*: seq[tuple[edgeDir, strongHex, reason: string]]
      ## Records that touch a workspace root but were not exported as
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
    reproRevision*: string

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
  ContentsHeader* = "reprobuild.store-bundle.contents.v1"
  ManifestSchema* = "reprobuild.store-bundle.v1"
  DefaultHalfName* = "native-store"
  DefaultPartSize* = 64'i64 * 1024 * 1024
  DefaultZstdLevel* = 19
  ZstdWindowLog* = 27
  BundlesDirName* = "bundles"
  FrozenDevEnvDirName* = "frozen-dev-env"
  ImportedMarkerName* = "imported"
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

proc recordTouches(record: ActionResultRecord;
                   roots: openArray[string]): bool =
  for input in record.inputs:
    if input.path.isAbsolute and input.path.normalizedPath.withinAny(roots):
      return true
  for output in record.outputs:
    if output.path.isAbsolute and output.path.normalizedPath.withinAny(roots):
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

proc findDotReproDirs(root: string; excluded: openArray[string];
                      found: var seq[string]) =
  ## Every `.repro/` directory under `root`, not descending into `.git`,
  ## into a found `.repro`, or into an excluded subtree (the store and the
  ## action cache, which have their own selection rules).
  if not dirExists(root):
    return
  var stack = @[root]
  while stack.len > 0:
    let dir = stack.pop()
    for kind, path in walkDir(dir):
      if kind != pcDir:
        continue
      let name = path.extractFilename
      if name == ".git" or path.withinAny(excluded):
        continue
      if name == ".repro":
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

proc findProjectDirs(root: string; excluded: openArray[string];
                      found: var seq[string]) =
  ## Every directory under `root` that holds a project file, plus `root`
  ## itself: the candidate working directories of relocatable records.
  if not dirExists(root):
    return
  found.add(root)
  var stack = @[root]
  while stack.len > 0:
    let dir = stack.pop()
    for kind, path in walkDir(dir):
      if kind != pcDir:
        continue
      let name = path.extractFilename
      if name in [".git", ".repro"] or path.withinAny(excluded):
        continue
      if fileExists(path / "repro.nim") or fileExists(path / "reprobuild.nim"):
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
    if plausible:
      for input in record.inputs:
        if input.metadata.kind == ffkRegular and
            not liveState(resolvedPath(dir, input.path)).exists:
          plausible = false
          break
    if plausible and outputStateMismatch(record, dir).len == 0:
      return dir
  ""

proc computeClosure*(roots: BundleRoots;
                     devEnvs: openArray[FrozenDevEnv] = []): BundleClosure =
  ## §2. Read-only: scans the action cache, the workspace roots and the
  ## store; writes nothing.
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

  var selected: seq[string]
  var prefixes = initHashSet[string]()
  # Candidate restamps, keyed by path; filtered against the bundled set once
  # the bundle is expanded.
  var inputs = initTable[string, FileFingerprint]()

  var projectDirs: seq[string]
  for root in ws:
    findProjectDirs(root, [storeRoot, acRoot], projectDirs)

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
            if record.recordTouches(ws):
              result.skippedRecords.add((edgeDir, strongHex,
                "no project directory under the roots holds its relative " &
                "outputs in the recorded state"))
              touching = true
            continue
        elif not record.recordTouches(ws):
          continue
        touching = true
        # Import refuses any member outside the declared roots, so a record
        # writing elsewhere cannot travel (and is reported instead).
        var outside = ""
        for output in record.outputs:
          let p = resolvedPath(outputRoot, output.path)
          if not (p.withinAny(ws) or p.isWithin(storeRoot) or
              p.isWithin(acRoot)):
            outside = p
            break
        if outside.len > 0:
          result.skippedRecords.add((edgeDir, strongHex,
            "an output lies outside the bundle roots: " & outside))
          continue
        if outputRoot.len == 0:
          let mismatch = outputStateMismatch(record, "")
          if mismatch.len > 0:
            result.skippedRecords.add((edgeDir, strongHex, mismatch))
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
            if p.withinAny(ws) and not p.isWithin(storeRoot) and
                not p.isWithin(acRoot):
              inputs[p] = input
      if touching:
        result.edges.add(edgeDir)
        selected.add(edgeDir)

  # 3. Project state.
  var dotRepro: seq[string]
  for root in ws:
    findDotReproDirs(root, [storeRoot, acRoot], dotRepro)
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

  # Every member's parent directories that lie inside a root are members
  # too, so the unpacked tree has the exporter's directory modes.
  var parents: seq[string]
  for entry in entries:
    var dir = entry.path.parentDir
    while dir.len > 1 and dir notin seen and
        (dir.withinAny(ws) or dir.isWithin(storeRoot) or dir.isWithin(acRoot)):
      seen.incl(dir)
      parents.add(dir)
      dir = dir.parentDir
  for dir in parents:
    let st = liveState(dir)
    entries.add(BundleEntry(kind: bekDir, mode: st.mode, mtimeNs: st.mtimeNs,
      digest: "-", path: dir))

  entries.sort(proc (a, b: BundleEntry): int = cmp(a.path, b.path))
  result.entries = entries

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
  lines.add("root\tstore\t" & escapeField(c.roots.storeRoot))
  lines.add("root\taction-cache\t" & escapeField(c.roots.actionCacheRoot))
  for root in c.roots.workspaceRoots:
    lines.add("root\tworkspace\t" & escapeField(root))
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
  if lines.len == 0 or lines[0] != ContentsHeader:
    fail("not a store-bundle contents file (expected header " &
      ContentsHeader & ")")
  for i in 1 ..< lines.len:
    let line = lines[i]
    if line.len == 0:
      continue
    let f = line.split('\t')
    try:
      case f[0]
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
    "frozenDevEnvs": devEnvNodes,
    "reproRevision": opts.reproRevision
  }

proc exportBundle*(c: BundleClosure; opts: ExportOptions): ExportReport =
  ## Write `c` as a bundle half under `opts.outDir`. Also writes the
  ## `contents` file under the exporting store's `bundles/<id>/`, because it
  ## travels as the first tar member at that very path.
  let tarExe = requireTool("tar")
  let zstdExe = requireTool("zstd")
  let id = bundleIdOf(c)
  let contentsText = renderContents(c)
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

proc feedParts*(dir: string; parts: seq[BundlePart]; command: string;
               stopEarly: bool): int =
  ## Run `command` with the verified parts streamed to its stdin and return
  ## its exit code. The command must redirect its own stdout and stderr to
  ## files: nothing reads those pipes while the feed runs. With `stopEarly`
  ## the feed stops quietly when the command exits before reading
  ## everything (the contents peek).
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

proc checkEntryPlacement(c: BundleClosure) =
  ## Every member must lie inside a declared root, so an unpack cannot
  ## write anywhere else.
  var allowed = @[c.roots.storeRoot, c.roots.actionCacheRoot]
  allowed.add(c.roots.workspaceRoots)
  for root in allowed:
    if not root.isAbsolute or root == "/":
      fail("bundle declares an unusable root: " & root.escape)
  for e in c.entries:
    if not e.path.isAbsolute or normalizedPath(e.path) != e.path or
        not e.path.withinAny(allowed):
      fail("bundle entry outside its declared roots: " & e.path)
  for r in c.records:
    if r.outputRoot.len > 0 and not r.outputRoot.withinAny(
        c.roots.workspaceRoots):
      fail("bundle record directory outside the workspace roots: " &
        r.outputRoot)
  for r in c.restamps:
    if not r.path.withinAny(c.roots.workspaceRoots):
      fail("bundle restamp outside the workspace roots: " & r.path)

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
  ## A local prefix that a receipt seals under its own name (§5 step 3).
  let receiptPath = prefix / ReceiptFileName
  if not fileExists(receiptPath):
    return false
  try:
    let receipt = readReceiptFile(receiptPath)
    prefix.extractFilename == realizationDirName(receipt.version,
      receipt.realizationHash)
  except CatchableError:
    false

proc peekContents(dir: string; m: ParsedManifest): string =
  ## The `contents` member, which export writes first. It is read from the
  ## shortest prefix of the parts that yields it whole: one part, in every
  ## bundle whose compressed contents list fits in the first part. Each try
  ## is checked against the manifest's SHA-256 of `contents`.
  let zstdExe = requireTool("zstd")
  let tarExe = requireTool("tar")
  let outPath = dir / ("." & m.bundleId & ".contents")
  defer: removeFile(outPath)
  let command = "(" & quoteShell(zstdExe) & " -q -dc --long=" &
    $ZstdWindowLog & " - | " & quoteShell(tarExe) &
    " -xOf - --occurrence=1 " & quoteShell(relToSlash(m.contentsPath)) &
    ") >" & quoteShell(outPath) & " 2>/dev/null"
  for count in 1 .. m.parts.len:
    removeFile(outPath)
    # A truncated stream makes the pipeline fail; only the hash decides.
    discard feedParts(dir, m.parts[0 ..< count], command, stopEarly = true)
    result = (if fileExists(outPath): readFile(outPath) else: "")
    if lowerHex(sha256.digest(result).data) == m.contentsSha:
      return
  fail("bundle contents entry does not match the manifest's SHA-256 " &
    "(or is not the first member)")

proc importBundle*(opts: ImportOptions; local: BundleRoots): ImportReport =
  ## §5. `local` carries the roots resolved on this machine; workspace roots
  ## may be empty, in which case the bundle's are accepted as long as the
  ## store and action-cache roots match.
  let dir = opts.bundleDir
  let manifestName =
    if opts.manifestName.len > 0: opts.manifestName
    else: DefaultHalfName & ".json"
  let m = readManifest(dir / manifestName)
  var phaseStart = getMonoTime()
  template phaseDone(name: string) =
    let now = getMonoTime()
    result.phaseSeconds.add((name, (now - phaseStart).inNanoseconds.float / 1e9))
    phaseStart = now
  # Steps 1 + 2: verify the parts that carry `contents`, read it, check roots.
  let contentsText = peekContents(dir, m)
  let c = parseContents(contentsText)
  checkRoots(c.roots, local)
  checkEntryPlacement(c)
  if contentsPathFor(c.roots.storeRoot, m.bundleId) != m.contentsPath or
      bundleIdOf(c) != m.bundleId:
    fail("bundle id does not match its contents")
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
    # Step 3: unpack, leaving intact content-addressed prefixes alone.
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
  # Step 5.3: restamp source inputs whose bytes are the recorded ones.
  for r in c.restamps:
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
