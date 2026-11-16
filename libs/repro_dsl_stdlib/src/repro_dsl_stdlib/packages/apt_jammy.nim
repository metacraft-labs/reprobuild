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
##     list of ``(name, version, debPath, sha256)`` sources; the live fetch
##     path is a TODO.
##   * Mirror policy / offline mode — flagged in spec §9 as open work.
##
## ## Store identity (spec §2, §3, §6)
##
## Every store path this module creates is named by a full, untruncated
## SHA-256 (64 lowercase hex chars) over a length-prefixed encoding of the
## BYTES it holds — never over the snapshot string, the request's argument
## order, or the caller's assertions about the result:
##
##   * ``apt.install``: the resolved set of ``(name, version, sha256)``
##     triples, sorted (``installFingerprint``).
##   * ``apt.extract``: the ``.deb``'s sha256 (``extractFingerprint``).
##   * ``apt.installSystemdUnit``: the unit name and the unit file's sha256.
##
## Why bytes and not the pin: a snapshot string such as
## ``ubuntu/jammy/20260615T000000Z`` names no digest, and any mirror it is
## resolved through can serve different ``.deb`` bytes for it. Keying the
## store by the pin let two hosts — or one host fed first by an honest and
## then by a hostile mirror — hold different bytes under one store path,
## poisoning any store or cache shared by that name (reprobuild-pm issue
## ``issues/2026-11-12-apt-adapter-the-snapshot-string-is-not-a-trust-root-inrelease-is-never-signature-checked.md``).
## The snapshot is therefore provenance only. ``expectedFiles`` is a CHECK run
## on every call, including a reuse of an existing path, and is not part of
## the identity: tightening an assertion that holds must not fork identical
## content into a new path.
##
## Encoding (``identityPreimage``): each field is an 8-byte big-endian
## unsigned length followed by the field's bytes; a count is the same 8-byte
## big-endian integer with no payload. With every field framed, no two
## distinct field sequences produce the same preimage, so (for example) the
## triples ``("ab", "c", s)`` and ``("a", "bc", s)`` cannot collide.
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

import std/[algorithm, hashes, os, osproc, sequtils, sets, strtabs, strutils]

import nimcrypto/sha2 as nc_sha2

# N48: the ONE ``tarOperand``. Every ``tar`` call site in the tree shares this
# implementation rather than growing a copy of it.
from repro_core/paths import tarOperand
from repro_core/host_tar import resolveHostTar, hostTarSearchDescription

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

  AptInputError* = object of AptAdapterError
    ## A request that cannot name a well-defined store identity: a
    ## malformed sha256 (not 64 lowercase hex chars), an empty or
    ## control-character-bearing package name or version, a package named
    ## twice in one request, or a unit name that is not a single path
    ## component. Raised BEFORE anything is read or written (fail-closed):
    ## an identity computed from such input would either be ambiguous or
    ## let one request overwrite another's bytes.
    field*: string        ## which input was rejected (e.g. "sha256")
    value*: string        ## the rejected value, verbatim

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
# Adapter version constant — part of every spec §2/§3 fingerprint
# ---------------------------------------------------------------------------

const
  AptJammyAdapterVersion* = "0.2.0"
    ## Mixed into every store identity, so bumping it invalidates every store
    ## path this adapter made. 0.2.0 replaced the pin-keyed, unframed,
    ## 16-hex-truncated identity of 0.1.0 with the byte-keyed, framed, full
    ## SHA-256 one described in the module header. Keep
    ## ``recipes/packages/adapters/apt-jammy/repro.nim`` (its ``versions:``
    ## key and ``config.adapterVersion``) equal to this; the NDE0-A test
    ## asserts they match.

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

proc addLengthPrefixed(buf: var string; n: uint64) =
  ## Append ``n`` as 8 big-endian bytes. Used both as a field's length prefix
  ## and, on its own, to encode a count.
  for shift in countdown(56, 0, 8):
    buf.add(char((n shr uint64(shift)) and 0xff'u64))

proc addField(buf: var string; field: string) =
  ## Append one framed field: its byte length (8 bytes, big-endian), then
  ## its bytes. The prefix is what makes the preimage injective — without
  ## it, adjacent fields could trade bytes across their boundary.
  buf.addLengthPrefixed(uint64(field.len))
  buf.add(field)

proc identityPreimage(tag: string; fields: openArray[string]): string =
  ## The bytes hashed for a store identity: ``tag``, the adapter version,
  ## then ``fields``, each framed by ``addField``. The tag keeps the
  ## identities of the three store-path kinds (install / extract / unit)
  ## disjoint even if their remaining fields happened to coincide.
  result.addField(tag)
  result.addField(AptJammyAdapterVersion)
  for f in fields:
    result.addField(f)

proc isLowerSha256Hex*(s: string): bool =
  ## True when ``s`` is a SHA-256 digest in the canonical form this adapter
  ## stores and compares: exactly 64 lowercase hex chars. A mixed-case or
  ## short digest is refused rather than normalised, so one digest never
  ## has two spellings in an identity.
  s.len == 64 and s.allCharsInSet({'0' .. '9', 'a' .. 'f'})

proc raiseInputError(field, value, why: string) {.noreturn.} =
  var e = newException(AptInputError,
    "apt-jammy: invalid " & field & " " & value.escape & ": " & why)
  e.field = field
  e.value = value
  raise e

proc requireSha256(field, value: string) =
  if not value.isLowerSha256Hex:
    raiseInputError(field, value, "expected 64 lowercase hex characters")

proc requirePrintableToken(field, value: string; allowEmpty: bool) =
  ## Package names and versions are Debian tokens (Debian Policy §5.6.1 and
  ## §5.6.12, https://www.debian.org/doc/debian-policy/ch-controlfields.html):
  ## no whitespace and no control characters. Refusing those keeps the
  ## idempotency marker (one line per triple) unambiguous; the identity
  ## itself is framed and would not need it.
  if value.len == 0 and not allowEmpty:
    raiseInputError(field, value, "must not be empty")
  for ch in value:
    if ord(ch) <= 0x20 or ord(ch) == 0x7f:
      raiseInputError(field, value,
        "must not contain whitespace or control characters")

proc sortedValidatedDebs(debs: openArray[ExtractedDeb]): seq[ExtractedDeb] =
  ## Validate a resolved ``(name, version, sha256)`` set and return it sorted
  ## by ``(name, version, sha256)``. Raises ``AptInputError`` (fail-closed)
  ## for an empty name, a whitespace/control character in a name or version,
  ## a malformed sha256, or a package name that appears twice — two archives
  ## for one package in one request would be extracted over each other, and
  ## which bytes survived would depend on the sort order.
  ##
  ## ``version`` may be empty: a caller that does not know it still names
  ## the bytes by sha256, and the empty string is framed like any other.
  result = @debs
  for d in result:
    requirePrintableToken("package name", d.name, allowEmpty = false)
    requirePrintableToken("version of " & d.name, d.version, allowEmpty = true)
    requireSha256("sha256 of " & d.name, d.sha256)
  result.sort(proc (a, b: ExtractedDeb): int =
    var c = cmp(a.name, b.name)
    if c == 0: c = cmp(a.version, b.version)
    if c == 0: c = cmp(a.sha256, b.sha256)
    c)
  for i in 1 ..< result.len:
    if result[i].name == result[i - 1].name:
      raiseInputError("package name", result[i].name,
        "named more than once in one request")

proc extractFingerprint*(sha256: string): string =
  ## Spec §2: the store-path name for ``apt.extract`` of the ``.deb`` whose
  ## bytes hash to ``sha256``:
  ##
  ##   hex(SHA-256(F("apt.extract") ‖ F(adapterVersion) ‖ F(sha256)))
  ##
  ## where ``F`` is the 8-byte big-endian length prefix + bytes framing of
  ## ``identityPreimage``. The full 64 hex chars are returned (no
  ## truncation). Raises ``AptInputError`` if ``sha256`` is not 64
  ## lowercase hex chars.
  requireSha256("sha256", sha256)
  sha256OfString(identityPreimage("apt.extract", [sha256]))

proc installFingerprint*(debs: openArray[ExtractedDeb]): string =
  ## Spec §3: the store-path name for ``apt.install`` of a resolved package
  ## set. The identity is the BYTES, named by their digests:
  ##
  ##   hex(SHA-256(F("apt.install") ‖ F(adapterVersion) ‖ N ‖
  ##               F(name_1) ‖ F(version_1) ‖ F(sha256_1) ‖ … ‖
  ##               F(name_N) ‖ F(version_N) ‖ F(sha256_N)))
  ##
  ## with ``N`` the count as an 8-byte big-endian integer, the triples sorted
  ## by ``(name, version, sha256)`` (argument order is not part of the key),
  ## and ``F`` the length-prefix framing of ``identityPreimage``. The full
  ## 64 hex chars are returned (no truncation).
  ##
  ## Deliberately NOT inputs:
  ##   * the snapshot string — it names no digest, so it cannot say which
  ##     bytes are stored; the same bytes reached under two snapshots share
  ##     one path, and different bytes under one snapshot never do;
  ##   * ``expectedFiles`` — an assertion about the result, checked by
  ##     ``installAptDeb`` on every call, not a property of the bytes.
  ##
  ## Raises ``AptInputError`` for an input set ``sortedValidatedDebs``
  ## refuses.
  let sorted = sortedValidatedDebs(debs)
  var fields: seq[string]
  for d in sorted:
    fields.add(d.name)
    fields.add(d.version)
    fields.add(d.sha256)
  var preimage = ""
  preimage.addField("apt.install")
  preimage.addField(AptJammyAdapterVersion)
  preimage.addLengthPrefixed(uint64(sorted.len))
  for f in fields:
    preimage.addField(f)
  sha256OfString(preimage)

# ---------------------------------------------------------------------------
# .deb (ar archive) parsing
# ---------------------------------------------------------------------------

type
  DebMemberInfo = object
    name: string         ## member name, trimmed
    size: int64          ## payload size in bytes
    offset: int64        ## payload offset in the .deb

const ArMagic = "!<arch>\n"
const ArHeaderSize = 60   ## 16+12+6+6+8+10+2 = 60
const DebCopyChunk = 256 * 1024
  ## The ``.deb`` reader copies a member in pieces of this size: its
  ## memory does not grow with the archive (an add-on apply unit runs under
  ## ``MemoryMax=``, and a closure member can be hundreds of MB).

const AptJammyMutation {.strdefine: "reproAddonMutation".} = ""
  ## The add-on's falsifying-build switch (``repro_addon/mutations``, which
  ## this package cannot import). ``apt-deb-reader-reads-whole-file``
  ## restores the reader that loaded the whole ``.deb`` into memory.

proc parseDebMembers(f: File; fileSize: int64): seq[DebMemberInfo] =
  ## Parse the ``ar`` archive open as ``f`` into its members' names, sizes
  ## and payload offsets, reading only the 8-byte magic and each 60-byte
  ## header (ar(5): name 16, mtime 12, uid 6, gid 6, mode 8, size 10,
  ## terminator "`\n"; payloads padded to even offsets). Stops on the
  ## first malformed header or a member that runs past the end of the
  ## file. Used to locate ``debian-binary`` / ``control.tar.*`` /
  ## ``data.tar.*`` within a .deb without loading it.
  result = @[]
  if fileSize < ArMagic.len: return
  var magic = newString(ArMagic.len)
  f.setFilePos(0)
  if f.readBuffer(addr magic[0], ArMagic.len) != ArMagic.len or
      magic != ArMagic:
    return
  var pos = int64(ArMagic.len)
  var hdr = newString(ArHeaderSize)
  while pos + ArHeaderSize <= fileSize:
    f.setFilePos(pos)
    if f.readBuffer(addr hdr[0], ArHeaderSize) != ArHeaderSize: break
    let name = hdr[0 ..< 16].strip(leading = false, trailing = true,
      chars = {' ', '/'})
    let sizeStr = hdr[48 ..< 58].strip(leading = false, trailing = true,
      chars = {' '})
    if hdr[58 ..< 60] != "`\n": break
    let size = try: parseBiggestInt(sizeStr) except ValueError: break
    if size < 0: break
    let payloadStart = pos + ArHeaderSize
    if payloadStart + size > fileSize: break
    result.add(DebMemberInfo(name: name, size: size, offset: payloadStart))
    # Even byte alignment per ar spec.
    pos = payloadStart + size + (size and 1)

proc locateDataMember(members: seq[DebMemberInfo]):
                    tuple[name: string, offset: int64, size: int64] =
  ## Locate the ``data.tar.*`` member. .deb spec allows
  ## data.tar / data.tar.gz / data.tar.xz / data.tar.bz2 / data.tar.zst.
  for m in members:
    if m.name.startsWith("data.tar"):
      return (m.name, m.offset, m.size)
  return ("", -1'i64, 0'i64)

proc copyDebMember(f: File; offset, size: int64; dest: string) =
  ## Write ``size`` bytes of ``f`` from ``offset`` to the new file ``dest``,
  ## in ``DebCopyChunk`` pieces. Raises ``IOError`` on a short read.
  let o = open(dest, fmWrite)
  try:
    f.setFilePos(offset)
    var buf = newString(DebCopyChunk)
    var remaining = size
    while remaining > 0:
      let want = int(min(remaining, int64(DebCopyChunk)))
      let got = f.readBuffer(addr buf[0], want)
      if got != want:
        raise newException(IOError, "short read in the .deb member at " &
          $offset)
      if o.writeBuffer(addr buf[0], got) != got:
        raise newException(IOError, "cannot write " & dest)
      remaining -= got
  finally:
    o.close()

proc writeDebMember(debPath: string; offset, size: int64; dest: string) =
  ## The data member of the ``.deb`` at ``debPath`` written to ``dest``.
  when AptJammyMutation == "apt-deb-reader-reads-whole-file":
    # Falsifying build: the whole archive in memory, as before.
    let debBytes = readFile(debPath)
    let o = open(dest, fmWrite)
    try:
      if size > 0:
        discard o.writeBuffer(
          cast[ptr UncheckedArray[byte]](debBytes[int(offset)].unsafeAddr),
          int(size))
    finally:
      o.close()
  else:
    let f = open(debPath, fmRead)
    try: copyDebMember(f, offset, size, dest)
    finally: f.close()

proc debDataMember(debPath: string):
    tuple[name: string, offset: int64, size: int64] =
  ## The ``data.tar.*`` member of the ``.deb`` at ``debPath``, from its
  ## headers alone; ``offset`` is -1 when there is none.
  let f = open(debPath, fmRead)
  try:
    result = locateDataMember(parseDebMembers(f, getFileSize(f)))
  finally:
    f.close()

proc tarFlagFor(memberName: string): string =
  ## Map a ``data.tar.*`` member name to the appropriate ``tar`` flag.
  ## We invoke through GNU tar / bsdtar; both accept the same flags.
  case memberName
  of "data.tar":     "-xf"
  of "data.tar.gz":  "-xzf"
  of "data.tar.xz":  "-xJf"
  of "data.tar.bz2": "-xjf"
  else: ""

proc newChildEnvTable(): StringTableRef =
  when defined(windows):
    result = newStringTable(modeCaseInsensitive)
  else:
    result = newStringTable(modeCaseSensitive)

proc pathListSep(): string =
  when defined(windows): ";"
  else: ":"

proc prependPathValue(existing, dir: string): string =
  if dir.len == 0:
    return existing
  if existing.len == 0:
    return dir
  dir & pathListSep() & existing

proc zstdChildEnv(prependZstdLib, stripLoaderVars: bool): StringTableRef =
  ## Build a child environment for zstd. Some dev shells carry a
  ## ``LD_LIBRARY_PATH`` whose first ``libzstd.so`` does not match the
  ## zstd binary. Prefer the test-runner/dev-shell ``ZSTD_LIB`` hint
  ## when present, and otherwise allow a clean-loader retry so Nix
  ## binaries resolve through their embedded rpath.
  result = newChildEnvTable()
  for k, v in envPairs():
    if stripLoaderVars and k in [
      "LD_LIBRARY_PATH", "DYLD_LIBRARY_PATH", "DYLD_FALLBACK_LIBRARY_PATH",
      "LD_PRELOAD", "DYLD_INSERT_LIBRARIES"]:
      discard
    else:
      result[k] = v
  let zstdLib = getEnv("ZSTD_LIB")
  if prependZstdLib and zstdLib.len > 0:
    result["LD_LIBRARY_PATH"] =
      prependPathValue(result.getOrDefault("LD_LIBRARY_PATH"), zstdLib)
    result["DYLD_LIBRARY_PATH"] =
      prependPathValue(result.getOrDefault("DYLD_LIBRARY_PATH"), zstdLib)
    result["DYLD_FALLBACK_LIBRARY_PATH"] =
      prependPathValue(result.getOrDefault("DYLD_FALLBACK_LIBRARY_PATH"),
        zstdLib)

proc findZstdDecompressor(): string =
  result = findExe("zstd", followSymlinks = false)
  if result.len == 0:
    result = findExe("unzstd", followSymlinks = false)

proc zstdDecompressCommand(zstd, src, dest: string): string =
  let leaf = zstd.extractFilename.toLowerAscii()
  let modeFlag = if leaf == "unzstd": "" else: " -d"
  quoteShell(zstd) & modeFlag & " -f -q -o " & quoteShell(dest) &
    " " & quoteShell(src)

proc decompressZstdToFile(src, dest: string):
    tuple[ok: bool; command: string; exitCode: int; output: string] =
  let zstd = findZstdDecompressor()
  if zstd.len == 0:
    return (ok: false, command: "zstd", exitCode: -1,
      output: "no zstd/unzstd decompressor on PATH")
  let cmd = zstdDecompressCommand(zstd, src, dest)
  let attempts =
    if getEnv("ZSTD_LIB").len > 0:
      @[
        zstdChildEnv(prependZstdLib = true, stripLoaderVars = false),
        zstdChildEnv(prependZstdLib = true, stripLoaderVars = true),
        zstdChildEnv(prependZstdLib = false, stripLoaderVars = true)
      ]
    else:
      @[
        zstdChildEnv(prependZstdLib = false, stripLoaderVars = true),
        zstdChildEnv(prependZstdLib = false, stripLoaderVars = false)
      ]
  for env in attempts:
    try:
      if fileExists(dest): removeFile(dest)
    except OSError:
      discard
    let res = execCmdEx(cmd, env = env)
    result = (ok: res.exitCode == 0, command: cmd,
      exitCode: res.exitCode, output: res.output)
    if result.ok:
      return

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

proc tarExtractDataMember(debPath, memberName: string;
                          memberOffset, memberSize: int64;
                          outDir: string) =
  ## Write the ``data.tar.*`` payload to a temp file then invoke ``tar``
  ## to extract it into ``outDir``. Raises ``AptExtractError`` if tar
  ## fails.
  if memberOffset < 0:
    raise newException(AptExtractError,
      "no data.tar.* member in " & debPath)
  let tmpData = outDir / ("__apt_jammy_data_" & memberName)
  writeDebMember(debPath, memberOffset, memberSize, tmpData)
  defer:
    try: removeFile(tmpData)
    except OSError: discard
  var tarInput = tmpData
  var scratchTar = ""
  defer:
    if scratchTar.len > 0:
      try: removeFile(scratchTar)
      except OSError: discard
  if memberName == "data.tar.zst":
    scratchTar = outDir / ("__apt_jammy_data_" & memberName & ".tar")
    let zstdRes = decompressZstdToFile(tmpData, scratchTar)
    if not zstdRes.ok:
      var e = newException(AptExtractError,
        "zstd decompression failed (exit " & $zstdRes.exitCode & "): " &
        zstdRes.output)
      e.debPath = debPath
      e.command = zstdRes.command
      e.exitCode = zstdRes.exitCode
      e.stderrText = zstdRes.output
      raise e
    tarInput = scratchTar
  let flag = if memberName == "data.tar.zst": "-xf" else: tarFlagFor(memberName)
  if flag.len == 0:
    var e = newException(AptExtractError,
      "unsupported data.tar variant: " & memberName)
    e.debPath = debPath
    raise e
  # Use --strip-components=0 so the ./ prefix is preserved as a relative
  # entry (canonicalisation strips ./). We pass -C to chdir.
  # Use osproc to run tar; failure surfaces as a non-zero exit and we
  # collect stderr for the diagnostic.
  #
  # N48: both operands go through ``tarOperand`` and ``--force-local`` is
  # offered in an attempt that is allowed to fail — W16's remedy, and both
  # halves of it are needed here. ``outDir`` and ``tarInput`` are ordinary
  # host paths, so on Windows they are absolute and backslashed, and GNU tar
  # UNQUOTES command-line names by default: an ``outDir`` whose leaf begins
  # ``a b f n r t v`` made tar raise with zero files extracted, and one
  # beginning ``\0`` made tar chdir to the PARENT, unpack the whole .deb
  # there and EXIT 0. GNU tar also reads a ``-f`` operand whose first ``:``
  # precedes any ``/`` as a remote ``host:path``, so the drive letter alone
  # ("Cannot connect to M: resolve failed") stopped it opening the member at
  # all.
  #
  # The two halves do not reach the same operand, which is why both are here:
  # measured on GNU tar 1.35, the unquoting reaches ``-C`` and NOT ``-f``, so
  # ``tarOperand`` is load-bearing on ``outDir`` and defence in depth on
  # ``tarInput``, while ``--force-local`` is the reverse. See the W16 block
  # comment in
  # ``libs/repro_home_apply/src/repro_home_apply/builtin_adapter.nim`` and
  # ``repro_core/paths.tarOperand`` for the measurements and for why the
  # rewrite is Windows-only.
  #
  # N51: argv[0] WAS the bare string ``"tar"`` while the failure path named
  # nothing at all. On Windows a bare name is resolved by ``CreateProcessW``,
  # which searches the SYSTEM DIRECTORY before ``%PATH%`` — so this ran
  # System32's bsdtar 3.8.8 on any host that also had GNU tar 1.35 on PATH,
  # and no reader of this code could tell. ``resolveHostTar`` reproduces that
  # order explicitly so the binary that runs is named, without changing WHICH
  # binary runs; see ``repro_core/host_tar``.
  # Modes and owners are whatever tar restores. As root, GNU tar restores
  # the archive's owners AND its setuid/setgid bits (``--preserve-permissions``
  # is the default for root; measured 2026-10-30 on Raspberry Pi OS trixie:
  # ``sudo tar --no-same-owner -xf`` still produced a 4755 root-owned
  # ``usr/bin/su``). So this path is for build-time extraction into a
  # store that nothing runs as a privileged service. The Add-On closure
  # realiser (``apt_closure.nim``) does not use it: it takes the plain tar
  # from ``extractDebDataMemberToTar`` and unpacks it in-process with its
  # own policy on names, link targets, entry kinds and modes.
  let tailArgs = [flag, tarOperand(tarInput), "-C", tarOperand(outDir)]
  let hostTar = resolveHostTar()
  if hostTar.exe.len == 0:
    var e = newException(AptExtractError,
      "no 'tar' found to extract " & memberName & " (looked in " &
      hostTarSearchDescription() & ")")
    e.debPath = debPath
    raise e
  proc tarCommand(withForceLocal: bool): string =
    var argv = @[quoteShell(hostTar.exe)]
    if withForceLocal: argv.add("--force-local")
    for a in tailArgs: argv.add(quoteShell(a))
    argv.join(" ")
  let gnuCmd = tarCommand(withForceLocal = true)
  var res = execCmdEx(gnuCmd)
  var cmd = gnuCmd
  var attempts = ""
  if res.exitCode != 0:
    # ``--force-local`` is a GNU extension; bsdtar answers "Option
    # --force-local is not supported" and exits 1, so the flag can never be
    # mandatory. Retry without it and report BOTH attempts.
    let plainCmd = tarCommand(withForceLocal = false)
    let plainRes = execCmdEx(plainCmd)
    attempts =
      "\n  attempt 1 (GNU: --force-local) exit=" & $res.exitCode & ": " &
      res.output.strip() &
      "\n  attempt 2 (no GNU-only flags) exit=" & $plainRes.exitCode & ": " &
      plainRes.output.strip()
    res = plainRes
    cmd = plainCmd
  if res.exitCode != 0:
    var e = newException(AptExtractError,
      "tar extraction failed (exit " & $res.exitCode & "): " & res.output &
      attempts)
    e.debPath = debPath
    e.command = cmd
    e.exitCode = res.exitCode
    e.stderrText = res.output
    raise e

proc extractDebDataMemberToTar*(debPath: string; outTarPath: string) =
  ## Write the ``data.tar.*`` member of the ``.deb`` at ``debPath`` to
  ## ``outTarPath`` as a PLAIN (decompressed) tar stream, through the same
  ## ``ar`` parser ``extractAptDeb`` uses and the host ``xz``, ``gzip`` or
  ## ``zstd`` for the compression the member carries. Nothing is unpacked
  ## and nothing is verified here: the caller owns digest verification, the
  ## destination directory, and the policy with which the tar is unpacked.
  ##
  ## This is the archive-level primitive the Add-On ``package(apt, ...)``
  ## closure realiser (``apt_closure.realiseAptClosure``) builds on,
  ## independent of suite, architecture or archive: it reads armhf trixie
  ## ``.deb``s exactly as this module reads amd64 jammy ones. Raises
  ## ``AptExtractError`` when the archive has no data member, carries a
  ## compression no host tool can decode, or the decompressor fails.
  ##
  ## The archive is never loaded whole: its ``ar`` headers are read by
  ## offset and the data member is copied in fixed-size chunks, so the
  ## memory used does not grow with the ``.deb``'s size.
  let (memName, memOff, memSize) = debDataMember(debPath)
  if memOff < 0:
    var e = newException(AptExtractError, "no data.tar.* member in " & debPath)
    e.debPath = debPath
    raise e
  let outDir = parentDir(outTarPath)
  if not dirExists(outDir):
    raise newException(IOError, "directory missing: " & outDir)
  if fileExists(outTarPath): removeFile(outTarPath)
  template fail(msg: string; cmd = ""; code = 0; text = "") =
    var e = newException(AptExtractError, msg)
    e.debPath = debPath
    e.command = cmd
    e.exitCode = code
    e.stderrText = text
    raise e
  template writeMember(path: string) =
    writeDebMember(debPath, memOff, memSize, path)
  case memName
  of "data.tar":
    writeMember(outTarPath)
  of "data.tar.zst":
    let packed = outTarPath & ".zst"
    writeMember(packed)
    defer:
      try: removeFile(packed)
      except OSError: discard
    let res = decompressZstdToFile(packed, outTarPath)
    if not res.ok:
      fail("zstd decompression failed (exit " & $res.exitCode & "): " &
        res.output, res.command, res.exitCode, res.output)
  of "data.tar.xz", "data.tar.gz", "data.tar.bz2":
    # ``<tool> -d <file.ext>`` replaces the file with its decompression,
    # so the member is written under the name the tool expects and the
    # output lands at ``outTarPath``.
    let (tool, ext) =
      if memName == "data.tar.xz": ("xz", ".xz")
      elif memName == "data.tar.gz": ("gzip", ".gz")
      else: ("bzip2", ".bz2")
    let exe = findExe(tool)
    if exe.len == 0:
      fail("no '" & tool & "' on PATH to decompress " & memName)
    let packed = outTarPath & ext
    writeMember(packed)
    let cmd = quoteShell(exe) & " -d -q -f " & quoteShell(packed)
    let res = execCmdEx(cmd)
    if res.exitCode != 0 or not fileExists(outTarPath):
      try: removeFile(packed)
      except OSError: discard
      fail(tool & " decompression failed (exit " & $res.exitCode & "): " &
        res.output, cmd, res.exitCode, res.output)
  else:
    fail("unsupported data.tar variant: " & memName)

proc extractAptDeb*(debPath: string;
                    sha256: string;
                    storeRoot: string = DefaultStoreRoot;
                    outputName: string = "extract"): AptFiles =
  ## Spec §2: lower-level primitive that consumes a pre-fetched .deb
  ## path + the expected sha256, verifies, extracts, and plants the
  ## content under ``storeRoot / <hash> /``.
  ##
  ## The store path is content-addressed by the ``.deb``'s sha256
  ## (``extractFingerprint``); re-invocation with the same bytes lands at
  ## the same path and is a graph-cache hit. Two .debs with different bytes
  ## land at distinct paths even if both have the same name.
  ##
  ## Failure modes (fail-closed):
  ##   * ``sha256`` not 64 lowercase hex chars → ``AptInputError``.
  ##   * Missing or unreadable ``debPath`` → ``IOError``.
  ##   * sha256 mismatch → ``AptVerifyError`` (no output written).
  ##   * ar/tar invocation failed → ``AptExtractError``.
  requireSha256("sha256", sha256)
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

  let (memName, memOff, memSize) = debDataMember(debPath)
  tarExtractDataMember(debPath, memName, memOff, memSize, storePath)

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

proc checkExpectedFiles(storePath: string; expectedFiles: seq[string]) =
  ## Spec §1: every ``expectedFiles`` entry must be a file in the extracted
  ## tree, else ``AptExpectedFileMissing``. Run on EVERY ``installAptDeb``
  ## call — a fresh extraction and a reuse of an existing path alike — so
  ## a caller's assertion is never satisfied by a cache hit it did not see.
  if expectedFiles.len == 0:
    return
  let actualSet = walkStoreRelFiles(storePath).toHashSet
  for ef in expectedFiles:
    let canon = canonicalisePath(ef)
    if canon notin actualSet:
      var e = newException(AptExpectedFileMissing,
        "expected file not present in extracted tree: " & ef)
      e.relPath = ef
      raise e

proc installMarkerContent(fingerprint: string;
                          sorted: openArray[ExtractedDeb]): string =
  ## The idempotency marker for an ``apt.install`` store path: the identity
  ## and the byte set it was computed from, one ``deb`` line per sorted
  ## triple. It records ONLY the byte identity — no snapshot, no
  ## ``expectedFiles`` — so the same bytes reached under two snapshots, or
  ## with different assertions, recognise one completed path. The marker is
  ## written last, so its presence means the extraction finished.
  ## ``sortedValidatedDebs`` has refused whitespace and control characters
  ## in names and versions, so the space-separated lines are unambiguous.
  result = "fingerprint=" & fingerprint & "\n"
  for d in sorted:
    result.add("deb=" & d.name & " " & d.version & " " & d.sha256 & "\n")

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
  ## Identity (spec §3): the store path is
  ## ``storeRoot / installFingerprint(<the (name, version, sha256) triples>)``
  ## — keyed by the bytes, so a different ``.deb`` for the same package name
  ## (e.g. one served by a substituting mirror) can never land at, or
  ## overwrite, the path of the bytes another caller installed.
  ##
  ## ``snapshot`` is PROVENANCE ONLY. It is kept in the signature for API
  ## compatibility and to say where the caller resolved the ``.deb``s from,
  ## but it names no digest and so is not part of the identity: the same
  ## bytes under two snapshots share one path. It is not consulted to fetch
  ## anything either; callers supply ``debPath`` + ``sha256`` for every
  ## package until the spec §6 four-link chain lands.
  ##
  ## ``expectedFiles`` is a check, not identity: it is evaluated against the
  ## store tree on every call, including when an existing completed path is
  ## reused.
  ##
  ## Failure modes (all fail-closed):
  ##   * An invalid source (empty name, whitespace/control character in a
  ##     name or version, sha256 not 64 lowercase hex chars, a package named
  ##     twice) → ``AptInputError``, before anything is read or written.
  ##   * Any per-.deb sha256 mismatch → ``AptVerifyError``. The store path
  ##     carries no marker, so the next call redoes it.
  ##   * Any ``expectedFiles`` entry absent → ``AptExpectedFileMissing``.
  ##     On a fresh extraction the marker is not written; on a reuse the
  ##     completed path is left as it is (its bytes are still correct for
  ##     their identity — only the caller's assertion failed).
  discard snapshot   # provenance only; see above
  let requested = debs.mapIt(ExtractedDeb(
    name: it.name, version: it.version, sha256: it.sha256))
  let sorted = sortedValidatedDebs(requested)
  let hash = installFingerprint(sorted)
  let storePath = storeRoot / hash
  let marker = storePath / ".apt-jammy-install"
  let markerContent = installMarkerContent(hash, sorted)

  result.storePath = storePath
  result.debs = sorted

  # Reuse: a completed path for this byte identity already exists. The
  # caller's assertions are still checked against it.
  if dirExists(storePath) and fileExists(marker) and
      readFile(marker) == markerContent:
    checkExpectedFiles(storePath, expectedFiles)
    return

  # Fresh extraction: remove any partial path (no marker, or a marker from
  # an older layout), recreate.
  if dirExists(storePath):
    removeDir(storePath)
  createDir(storePath)

  # Extract each .deb directly into the shared storePath. Sha verification
  # happens here (NOT via ``extractAptDeb`` so we don't pay for a separate
  # per-deb content-addressed dir). The sources are walked in the same
  # sorted order the identity uses, so the extraction order is a function of
  # the identity too.
  var sortedSources = debs
  sortedSources.sort(proc (a, b: AptDebSource): int = cmp(a.name, b.name))
  for d in sortedSources:
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
    let (memName, memOff, memSize) = debDataMember(d.debPath)
    tarExtractDataMember(d.debPath, memName, memOff, memSize,
                         storePath)

  # expectedFiles assertion (spec §1: fail-closed at build time). Checked
  # before the marker so a failing fresh extraction does not publish a
  # completed path on behalf of a call that raised.
  checkExpectedFiles(storePath, expectedFiles)

  writeFile(marker, markerContent)

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
  ## The output is itself content-addressed:
  ##
  ##   hex(SHA-256(F("apt.installSystemdUnit") ‖ F(adapterVersion) ‖
  ##               F(unitName) ‖ F(sha256(unit bytes))))
  ##
  ## (the framing of ``identityPreimage``; full 64 hex chars), so:
  ##   * Two unit files at the same source path but with different bytes
  ##     produce different output store paths.
  ##   * Re-installing the same unit twice is a graph-cache hit.
  ##
  ## ``unitName`` must be a single path component (no ``/`` or ``\``, not
  ## ``.`` or ``..``, no control characters): it is joined onto store paths,
  ## so anything else could read or write outside them. Raises
  ## ``AptInputError`` otherwise.
  requirePrintableToken("unit name", unitName, allowEmpty = false)
  if unitName in [".", ".."] or '/' in unitName or '\\' in unitName:
    raiseInputError("unit name", unitName, "must be a single path component")
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
  let hash = sha256OfString(
    identityPreimage("apt.installSystemdUnit", [unitName, bytesSha]))
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
