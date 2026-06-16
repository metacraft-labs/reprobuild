## NDE0-A: apt-jammy native catalog adapter (Tier-1 native).
##
## Implements the surface specified in
## ``reprobuild-specs/External-Package-Catalog-Adapters.md`` §"Distro-Snapshot
## Adapters: apt, dnf, pacman" for the first realised adapter (``apt-jammy``).
##
## ## Scope decision (v1)
##
## This module ships the **build-time primitives** the adapter package's
## ``build:`` block invokes:
##
##   * ``extractAptDeb`` — spec §2: verified ``.deb`` -> content-addressed
##     store path. Pre-fetched ``.deb`` is the input (path + sha256).
##   * ``installAptDeb`` — spec §1: consumes a pre-supplied registry of
##     ``(name, url, sha256)`` triples + local cache, fetches if missing
##     (via the existing tarball-acquisition path; v1 is offline-only
##     when cache is hit), and delegates to ``extractAptDeb`` per .deb.
##   * ``installSystemdUnit`` — spec §5: normalises a unit file from
##     either ``lib/systemd/system/<n>`` or ``usr/lib/systemd/system/<n>``
##     in an extracted store path to ``usr/lib/systemd/system/<n>`` in
##     the output. Closes cascade-G (DE-G/DE-H/DE-K dbus.socket fix).
##
## **NOT implemented in v1** (deferred to follow-up milestones):
##
##   * The full spec §6 four-link snapshot chain (snapshot string → InRelease →
##     Packages index → .deb URL with content-addressed mirror selection).
##     Network fetching against ``snapshot.ubuntu.com`` is non-trivial and
##     deserves its own milestone. ``installAptDeb`` takes a pre-supplied
##     ``debRegistry`` map; the snapshot string is plumbed into the
##     fingerprint per spec §3 but the live fetch path is a TODO.
##   * Mirror policy / offline mode — flagged in spec §9 as open work.
##
## ## DSL embedding
##
## The accompanying ``recipes/packages/adapters/apt-jammy/repro.nim``
## declares a ``package aptJammy:`` block with ``config:`` (snapshot pin,
## adapter version, cache dir) and a ``build:`` body that delegates to the
## procs in this module. The DSL macro at
## ``libs/repro_project_dsl/src/repro_project_dsl/macros_a.nim``
## (``parsePackageDef``) currently recognises only
## ``executable`` / ``library`` / ``uses`` / ``config`` / ``outputs``
## section heads; the ``files`` block called out in the spec
## (``files runtime: build: apt.install(...)``) is purely spec at this
## point. Consumers therefore call these procs directly (not via
## ``apt.install`` method-call syntax).
##
## See ``apt_jammy.md`` (sibling of this file in the same dir) for the
## migration story when the DSL gains user-extensible ``files``-output
## procs.

import std/[algorithm, hashes, os, osproc, sequtils, sets, strutils]

import nimcrypto/sha2 as nc_sha2

# ---------------------------------------------------------------------------
# Public errors (spec §1, §2)
# ---------------------------------------------------------------------------

type
  AptAdapterError* = object of CatchableError
    ## Base for every apt-jammy adapter diagnostic.

  AptSnapshotError* = object of AptAdapterError
    ## Spec §1: snapshot resolution failed (mirror unreachable, snapshot
    ## not in chain, etc.). v1 only raises this from the unimplemented
    ## live-fetch path; cache-hit + extract paths do not raise it.
    snapshot*: string

  AptVerifyError* = object of AptAdapterError
    ## Spec §1, §2: ``.deb`` sha256 mismatch (fail-closed). The action
    ## produces no output when raised.
    debPath*: string
    expectedSha*: string
    observedSha*: string

  AptExpectedFileMissing* = object of AptAdapterError
    ## Spec §1: an ``expectedFiles`` entry was not present in the union
    ## of extracted .deb trees after extraction.
    relPath*: string

  AptExtractError* = object of AptAdapterError
    ## ar/tar invocation failed; typically a malformed archive or a
    ## missing host tool. Carries the failed command for diagnostics.
    debPath*: string
    command*: string
    exitCode*: int
    stderrText*: string

# ---------------------------------------------------------------------------
# Files (v1 partial: typed output handle the spec's §1/§2/§5 return)
# ---------------------------------------------------------------------------

type
  ExtractedDeb* = object
    ## One .deb's metadata as planted in the store path. Spec §1 names
    ## this the ``.debs`` field of the returned ``Files`` value.
    name*: string
    version*: string
    sha256*: string

  AptFiles* = object
    ## Spec §1: typed output of ``apt.install()`` / ``apt.extract()`` /
    ## ``apt.installSystemdUnit()``. Until the DSL grows a real ``Files``
    ## handle (Package-Model.md §"Packaging Artifacts As Build Outputs"),
    ## this is the v1 stand-in. Callers consume ``.storePath`` and
    ## ``.tree(...)`` exactly as the spec describes.
    storePath*: string                ## absolute store path under
                                      ## ``/opt/reproos-linux/store/<hash>/``
                                      ## (or test-override base)
    debs*: seq[ExtractedDeb]          ## sorted (name, version, sha256)

# ---------------------------------------------------------------------------
# Adapter version constant — part of the spec §3 fingerprint
# ---------------------------------------------------------------------------

const
  AptJammyAdapterVersion* = "0.1.0"

  ## Default store root. Tests override via ``storeRoot`` arg.
  DefaultStoreRoot* = "/opt/reproos-linux/store"

# ---------------------------------------------------------------------------
# sha256 helpers
# ---------------------------------------------------------------------------

proc sha256OfBytes(bytes: openArray[byte]): string =
  ## Lowercase 64-char hex sha256.
  var ctx: nc_sha2.sha256
  ctx.init()
  ctx.update(bytes)
  let digest = ctx.finish()
  result = newStringOfCap(64)
  const Hex = "0123456789abcdef"
  for i in 0 ..< 32:
    let b = digest.data[i].uint8
    result.add(Hex[int(b shr 4)])
    result.add(Hex[int(b and 0x0f)])

proc sha256OfFile*(path: string): string =
  ## Streaming sha256 of a file's bytes; raises ``IOError`` on read failure.
  var ctx: nc_sha2.sha256
  ctx.init()
  let f = open(path, fmRead)
  defer: f.close()
  var buf = newString(65536)
  while true:
    let n = f.readBuffer(buf[0].addr, buf.len)
    if n <= 0: break
    ctx.update(cast[ptr UncheckedArray[byte]](buf[0].addr).toOpenArray(0, n - 1))
  let digest = ctx.finish()
  result = newStringOfCap(64)
  const Hex = "0123456789abcdef"
  for i in 0 ..< 32:
    let b = digest.data[i].uint8
    result.add(Hex[int(b shr 4)])
    result.add(Hex[int(b and 0x0f)])

proc sha256OfString*(s: string): string =
  ## Sha256 of a string's bytes (for fingerprint composition).
  if s.len == 0:
    sha256OfBytes(default(array[0, byte]))
  else:
    sha256OfBytes(cast[ptr UncheckedArray[byte]](s[0].unsafeAddr).toOpenArray(0, s.len - 1))

# ---------------------------------------------------------------------------
# Fingerprint composition (spec §3)
# ---------------------------------------------------------------------------

proc extractFingerprint*(sha256: string): string =
  ## Spec §2: ``<hash>`` for ``apt.extract`` is
  ##   sha256("apt.extract" || adapterVersion || sha256(deb))
  ## truncated to 16 hex chars.
  ##
  ## The string concatenation matches the §3 layout (no separators —
  ## consistent with the shell-script's ``catalog_hash`` in
  ## ``recipes/reproos-mvp-config/build-linux-graphics-stack.sh``).
  let composed = "apt.extract" & AptJammyAdapterVersion & sha256
  let h = sha256OfString(composed)
  result = h[0 ..< 16]

proc installFingerprint*(snapshot: string;
                         debNames: seq[string];
                         expectedFiles: seq[string]): string =
  ## Spec §3: ``<hash>`` for ``apt.install`` is
  ##   sha256(
  ##     "apt.install" || adapterVersion || snapshot ||
  ##     sortedDebNames.joinNul() || sortedExpectedFiles.joinNul()
  ##   )
  ## truncated to 16 hex chars.
  ##
  ## Sorting is intentional: argument order is not part of the cache key.
  ## NUL separator avoids ambiguity if a name happens to contain the
  ## separator characters of any other formatter we might add later.
  var debs = debNames
  debs.sort(cmp[string])
  var ef = expectedFiles
  ef.sort(cmp[string])
  const NUL = "\x00"
  let composed = "apt.install" & AptJammyAdapterVersion & snapshot &
                 debs.join(NUL) & NUL & ef.join(NUL)
  let h = sha256OfString(composed)
  result = h[0 ..< 16]

# ---------------------------------------------------------------------------
# .deb (ar archive) parsing
# ---------------------------------------------------------------------------

type
  DebMemberInfo = object
    name: string         ## member name, trimmed
    size: int            ## payload size in bytes
    offset: int          ## payload offset in the .deb

const ArMagic = "!<arch>\n"
const ArHeaderSize = 60   ## 16+12+6+6+8+10+2 = 60

proc parseDebMembers(debBytes: string): seq[DebMemberInfo] =
  ## Parse an ar archive into a sequence of member infos. Stops on the
  ## first malformed header. Used to locate ``debian-binary`` /
  ## ``control.tar.*`` / ``data.tar.*`` within a .deb.
  result = @[]
  if debBytes.len < ArMagic.len or
      debBytes[0 ..< ArMagic.len] != ArMagic:
    return
  var pos = ArMagic.len
  while pos + ArHeaderSize <= debBytes.len:
    var name = debBytes[pos ..< pos + 16].strip(leading = false,
      trailing = true, chars = {' ', '/'})
    let sizeStr = debBytes[pos + 48 ..< pos + 58].strip(leading = false,
      trailing = true, chars = {' '})
    let sentinel = debBytes[pos + 58 ..< pos + 60]
    if sentinel != "`\n":
      break
    let size = try: parseInt(sizeStr) except ValueError: break
    let payloadStart = pos + ArHeaderSize
    if payloadStart + size > debBytes.len:
      break
    result.add(DebMemberInfo(name: name, size: size, offset: payloadStart))
    # Even byte alignment per ar spec.
    let advance = if (size and 1) == 1: size + 1 else: size
    pos = payloadStart + advance

proc locateDataMember(debBytes: string;
                      members: seq[DebMemberInfo]):
                    tuple[name: string, offset: int, size: int] =
  ## Locate the ``data.tar.*`` member. .deb spec allows
  ## data.tar / data.tar.gz / data.tar.xz / data.tar.bz2 / data.tar.zst.
  for m in members:
    if m.name.startsWith("data.tar"):
      return (m.name, m.offset, m.size)
  return ("", -1, 0)

proc tarFlagFor(memberName: string): string =
  ## Map a ``data.tar.*`` member name to the appropriate ``tar`` flag.
  ## We invoke through GNU tar / bsdtar; both accept the same flags.
  case memberName
  of "data.tar":     "-xf"
  of "data.tar.gz":  "-xzf"
  of "data.tar.xz":  "-xJf"
  of "data.tar.bz2": "-xjf"
  of "data.tar.zst":
    # GNU tar 1.32+ supports --zstd. We treat the flag as "filter +
    # extract from stdin". The caller pipes via a temp file.
    "--zstd -xf"
  else: ""

# ---------------------------------------------------------------------------
# Public: extractAptDeb (spec §2)
# ---------------------------------------------------------------------------

proc canonicalisePath(p: string): string =
  ## Normalise an in-archive path to a forward-slash relative form.
  ## tar emits entries like ``./usr/lib/...`` — we strip the leading
  ## ``./``. Forward-slashes are kept on Windows too so the store-relative
  ## entries in ``expectedFiles`` (which the spec describes as POSIX-style
  ## paths under the union of extracted .deb trees) match irrespective of
  ## host.
  var s = p
  if s.startsWith("./"):
    s = s[2 .. ^1]
  while s.endsWith("/"):
    s.setLen(s.len - 1)
  s

proc walkStoreRelFiles(root: string): seq[string] =
  ## Enumerate every regular file under ``root`` and return paths
  ## relative to ``root`` in POSIX form, sorted. Used to honour
  ## ``expectedFiles`` membership checks (spec §1).
  result = @[]
  for path in walkDirRec(root, relative = true):
    var rel = path.replace('\\', '/')
    result.add(rel)
  result.sort(cmp[string])

proc tarExtractDataMember(debPath, debBytes, memberName: string;
                          memberOffset, memberSize: int;
                          outDir: string) =
  ## Write the ``data.tar.*`` payload to a temp file then invoke ``tar``
  ## to extract it into ``outDir``. Raises ``AptExtractError`` if tar
  ## fails.
  if memberOffset < 0:
    raise newException(AptExtractError,
      "no data.tar.* member in " & debPath)
  let tmpData = outDir / ("__apt_jammy_data_" & memberName)
  let f = open(tmpData, fmWrite)
  if memberSize > 0:
    discard f.writeBuffer(
      cast[ptr UncheckedArray[byte]](debBytes[memberOffset].unsafeAddr),
      memberSize)
  f.close()
  defer:
    try: removeFile(tmpData)
    except OSError: discard
  let flag = tarFlagFor(memberName)
  if flag.len == 0:
    var e = newException(AptExtractError,
      "unsupported data.tar variant: " & memberName)
    e.debPath = debPath
    raise e
  # Use --strip-components=0 so the ./ prefix is preserved as a relative
  # entry (canonicalisation strips ./). We pass -C to chdir.
  # Use osproc to run tar; failure surfaces as a non-zero exit and we
  # collect stderr for the diagnostic.
  let cmd = "tar " & flag & " " & quoteShell(tmpData) &
            " -C " & quoteShell(outDir)
  let res = execCmdEx(cmd)
  if res.exitCode != 0:
    var e = newException(AptExtractError,
      "tar extraction failed (exit " & $res.exitCode & "): " & res.output)
    e.debPath = debPath
    e.command = cmd
    e.exitCode = res.exitCode
    e.stderrText = res.output
    raise e

proc extractAptDeb*(debPath: string;
                    sha256: string;
                    storeRoot: string = DefaultStoreRoot;
                    outputName: string = "extract"): AptFiles =
  ## Spec §2: lower-level primitive that consumes a pre-fetched .deb
  ## path + the expected sha256, verifies, extracts, and plants the
  ## content under ``storeRoot / <hash> /``.
  ##
  ## The store path is content-addressed; re-invocation with the same
  ## (debPath, sha256, storeRoot) lands at the same path and (when the
  ## bytes match) is a graph-cache hit. Two .debs with different bytes
  ## land at distinct paths even if both have the same name.
  ##
  ## Failure modes (fail-closed):
  ##   * Missing or unreadable ``debPath`` → ``IOError``.
  ##   * sha256 mismatch → ``AptVerifyError`` (no output written).
  ##   * ar/tar invocation failed → ``AptExtractError``.
  if not fileExists(debPath):
    raise newException(IOError, "deb missing: " & debPath)

  let observedSha = sha256OfFile(debPath)
  if observedSha != sha256:
    var e = newException(AptVerifyError,
      "sha256 mismatch for " & debPath &
      " (expected " & sha256 & ", got " & observedSha & ")")
    e.debPath = debPath
    e.expectedSha = sha256
    e.observedSha = observedSha
    raise e

  let hash = extractFingerprint(sha256)
  let storePath = storeRoot / hash
  # Idempotency: if the store path already exists with the marker file,
  # re-use it. The marker carries the input sha so a partial extraction
  # from an aborted earlier run is re-done.
  let marker = storePath / ".apt-jammy-sha256"
  if dirExists(storePath) and fileExists(marker):
    let existing = readFile(marker).strip()
    if existing == sha256:
      result.storePath = storePath
      result.debs = @[ExtractedDeb(
        name: debPath.extractFilename,
        version: "",
        sha256: sha256)]
      return

  # Fresh extraction: remove any partial path, recreate.
  if dirExists(storePath):
    removeDir(storePath)
  createDir(storePath)

  let debBytes = readFile(debPath)
  let members = parseDebMembers(debBytes)
  let (memName, memOff, memSize) = locateDataMember(debBytes, members)
  tarExtractDataMember(debPath, debBytes, memName, memOff, memSize, storePath)

  # Write the marker file last so a crashed extraction is re-done.
  writeFile(marker, sha256)

  result.storePath = storePath
  result.debs = @[ExtractedDeb(
    name: debPath.extractFilename,
    version: "",
    sha256: sha256)]

# ---------------------------------------------------------------------------
# Public: installAptDeb (spec §1; v1 partial)
# ---------------------------------------------------------------------------

type
  AptDebSource* = object
    ## Pre-supplied registry entry binding a jammy package name to a
    ## known-good .deb on disk (or a future URL+sha256 the live-fetch
    ## path will resolve). v1 only supports the on-disk path.
    name*: string         ## jammy package name (e.g. "libwayland-client0")
    version*: string      ## informational, lands in ExtractedDeb
    debPath*: string      ## absolute path to a pre-fetched .deb on disk
    sha256*: string       ## expected sha256 of the .deb's bytes

proc installAptDeb*(snapshot: string;
                    debs: seq[AptDebSource];
                    expectedFiles: seq[string] = @[];
                    storeRoot: string = DefaultStoreRoot;
                    outputName: string = "install"): AptFiles =
  ## Spec §1: high-level entry point. Consumes a pre-supplied list of
  ## .deb sources + an optional ``expectedFiles`` assertion list and
  ## produces a single content-addressed store path that is the union
  ## of the extracted trees.
  ##
  ## v1 limitation: the snapshot string is part of the fingerprint
  ## (spec §3) but is **not** consulted to fetch .debs over the
  ## network. Callers must supply ``debPath`` + ``sha256`` for every
  ## package; the snapshot is informational+identity-only until the
  ## spec §6 four-link chain lands in a follow-up milestone.
  ##
  ## Failure modes:
  ##   * Any per-.deb sha256 mismatch → ``AptVerifyError`` (action
  ##     produces no output).
  ##   * Any ``expectedFiles`` entry absent after extraction →
  ##     ``AptExpectedFileMissing``.
  let debNames = debs.mapIt(it.name)
  let hash = installFingerprint(snapshot, debNames, expectedFiles)
  let storePath = storeRoot / hash

  # Idempotency: identity marker file carrying snapshot + sorted debs.
  let marker = storePath / ".apt-jammy-install"
  var sortedDebs = debs
  sortedDebs.sort(proc (a, b: AptDebSource): int = cmp(a.name, b.name))
  let markerContent = "snapshot=" & snapshot & "\n" &
    "debs=" & sortedDebs.mapIt(it.name & ":" & it.sha256).join(",") & "\n"
  if dirExists(storePath) and fileExists(marker):
    let existing = readFile(marker).strip()
    if existing == markerContent.strip():
      result.storePath = storePath
      result.debs = sortedDebs.mapIt(ExtractedDeb(
        name: it.name, version: it.version, sha256: it.sha256))
      return

  if dirExists(storePath):
    removeDir(storePath)
  createDir(storePath)

  # Extract each .deb directly into the shared storePath. Sha verification
  # happens here (NOT via ``extractAptDeb`` so we don't pay for a separate
  # per-deb content-addressed dir).
  for d in sortedDebs:
    if not fileExists(d.debPath):
      raise newException(IOError, "deb missing for " & d.name & ": " & d.debPath)
    let observedSha = sha256OfFile(d.debPath)
    if observedSha != d.sha256:
      var e = newException(AptVerifyError,
        "sha256 mismatch for " & d.name & " at " & d.debPath &
        " (expected " & d.sha256 & ", got " & observedSha & ")")
      e.debPath = d.debPath
      e.expectedSha = d.sha256
      e.observedSha = observedSha
      raise e
    let debBytes = readFile(d.debPath)
    let members = parseDebMembers(debBytes)
    let (memName, memOff, memSize) = locateDataMember(debBytes, members)
    tarExtractDataMember(d.debPath, debBytes, memName, memOff, memSize,
                         storePath)

  # expectedFiles assertion (spec §1: fail-closed at build time).
  if expectedFiles.len > 0:
    let actual = walkStoreRelFiles(storePath)
    let actualSet = actual.toHashSet
    for ef in expectedFiles:
      let canon = canonicalisePath(ef)
      if canon notin actualSet:
        var e = newException(AptExpectedFileMissing,
          "expected file not present in extracted tree: " & ef)
        e.relPath = ef
        raise e

  writeFile(marker, markerContent)

  result.storePath = storePath
  result.debs = sortedDebs.mapIt(ExtractedDeb(
    name: it.name, version: it.version, sha256: it.sha256))

# ---------------------------------------------------------------------------
# Public: installSystemdUnit (spec §5)
# ---------------------------------------------------------------------------

proc installSystemdUnit*(unit: AptFiles;
                        unitName: string;
                        storeRoot: string = DefaultStoreRoot;
                        outputName: string = "systemdUnit"): AptFiles =
  ## Spec §5: emit a store path whose layout guarantees
  ## ``usr/lib/systemd/system/<unitName>`` resolves to the same bytes
  ## the upstream .deb shipped under either ``lib/systemd/system/`` or
  ## ``usr/lib/systemd/system/``. Closes the cascade-G bug DE-G/DE-H/DE-K
  ## all hit (R9 systemd's compiled-in ``UnitPath`` does not include
  ## ``/lib/systemd/system/``).
  ##
  ## The output is itself content-addressed; the hash mixes the source
  ## unit's bytes with the canonical destination path so:
  ##   * Two unit files at the same source path but with different bytes
  ##     produce different output store paths.
  ##   * Re-installing the same unit twice is a graph-cache hit.
  let candidateA = unit.storePath / "lib" / "systemd" / "system" / unitName
  let candidateB = unit.storePath / "usr" / "lib" / "systemd" / "system" / unitName
  var src = ""
  if fileExists(candidateB):
    src = candidateB
  elif fileExists(candidateA):
    src = candidateA
  else:
    raise newException(AptExpectedFileMissing,
      "systemd unit " & unitName & " not found at " & candidateA &
      " nor " & candidateB)
  let bytes = readFile(src)
  let bytesSha = sha256OfBytes(
    if bytes.len == 0:
      cast[ptr UncheckedArray[byte]](nil).toOpenArray(0, -1)
    else:
      cast[ptr UncheckedArray[byte]](bytes[0].unsafeAddr).toOpenArray(0, bytes.len - 1))
  let composed = "apt.installSystemdUnit" & AptJammyAdapterVersion &
                 unitName & bytesSha
  let h = sha256OfString(composed)
  let hash = h[0 ..< 16]
  let storePath = storeRoot / hash
  let marker = storePath / ".apt-jammy-unit"
  if dirExists(storePath) and fileExists(marker):
    let existing = readFile(marker).strip()
    if existing == bytesSha:
      result.storePath = storePath
      result.debs = unit.debs
      return
  if dirExists(storePath):
    removeDir(storePath)
  createDir(storePath)
  let destDir = storePath / "usr" / "lib" / "systemd" / "system"
  createDir(destDir)
  writeFile(destDir / unitName, bytes)
  writeFile(marker, bytesSha)
  result.storePath = storePath
  result.debs = unit.debs

# ---------------------------------------------------------------------------
# .tree(rel) accessor (spec §1)
# ---------------------------------------------------------------------------

proc tree*(f: AptFiles; rel: string): string =
  ## Spec §1: typed sub-path accessor. Joins the store path with the
  ## archive-relative entry, normalising separators for the host. The
  ## DSL's ``string-with-context`` discipline is approximated here as a
  ## plain string; a full ``BuildOutput.path`` wrapper is deferred until
  ## the DSL gains a real ``Files`` handle.
  let canon = canonicalisePath(rel)
  result = f.storePath / canon
