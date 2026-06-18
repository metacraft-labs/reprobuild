## ReproOS-Generations-And-Foreign-Packages A3 P2 — repro-binary-cache-client CLI.
##
## Bridge between bash build-scripts and the in-process substitute /
## publish machinery. Single-user mode only (calls
## ``substituteInProcess`` + a direct HTTP publish to the server).
##
## ## Subcommands
##
##   lookup     <entry-key-hex>
##     GET /manifests/<hex>; exit 0 on 200, 1 on 404. Quiet on success;
##     prints "miss" on miss.
##
##   substitute <entry-key-hex> <out-prefix-dir>
##     Walks the closure; on success extracts the realised prefix into
##     ``<out-prefix-dir>``. Exit 0 on hit, 1 on miss / error.
##
##   publish    <entry-key-hex> <prefix-dir>
##     Packages ``<prefix-dir>`` into a deterministic archive (see
##     "Archive format" below), signs a binary-cache manifest with the
##     supplied ECDSA-P256 key, POSTs the manifest + payload to the
##     server. The cache-entry key supplied on the command line is
##     used to LABEL the manifest; for v1 the build script computes
##     it via ``deriveCacheEntryKey`` and threads the hex through.
##
## ## Environment variables
##
##   REPRO_BINARY_CACHE_URL          Default ``http://localhost:7878``.
##   REPRO_BINARY_CACHE_KEY_PATH     ECDSA-P256 private key (the
##                                   ``ecdsa-p256:<hex>`` format used by
##                                   ``repro_peer_cache``). Required for
##                                   ``publish``. ``substitute`` /
##                                   ``lookup`` do not need it.
##   REPRO_BINARY_CACHE_CERT_PATH    Matching pub key file (65-byte
##                                   uncompressed hex). Required for
##                                   ``publish``.
##   REPRO_LOCAL_STORE               Local store root for the substitute
##                                   sink. Defaults to ``$HOME/.local/
##                                   share/repro/local-store``.
##
## ## Archive format (``rbcarc-v1``)
##
## A flat, deterministic archive used in place of ``tar``:
##
##   magic        "RBCA"
##   version      u32-le == 1
##   entryCount   u32-le
##   for each entry:
##     pathLen   u32-le
##     path      utf-8 bytes (forward-slash separators, repeating "../"
##               forbidden so extract cannot escape the prefix root)
##     mode      u32-le (POSIX mode bits; 0o755 for executables,
##               0o644 for regular files; reduced to {755, 644} for
##               determinism — exec bit is preserved on Linux but
##               normalised away on Windows where it's meaningless).
##     size      u64-le
##     bytes     raw file bytes
##
## Empty dirs are not recorded; the extractor creates parent dirs as
## needed when materialising leaf files. The format is intentionally
## minimal — for v1 the build scripts produce small flat outputs
## (single binaries, a handful of header files). When R5+ phases land
## with thousands of files, swap this format for tar+zstd; the
## manifest carries ``compression`` + a ``name`` field that distinguishes.

import std/[algorithm, asyncdispatch, httpclient, httpcore, os, parseopt,
            random, sequtils, strutils, tables, times]

import ../../libs/repro_binary_cache_client/src/repro_binary_cache_client
import ../../libs/repro_binary_cache_server/src/repro_binary_cache_server/types
import ../../libs/repro_binary_cache_server/src/repro_binary_cache_server/key as bcsKey
import ../../libs/repro_binary_cache_server/src/repro_binary_cache_server/manifest_codec as serverCodec
import ../../libs/repro_peer_cache/src/repro_peer_cache/auth as peerAuth
import ../../libs/blake3/src/blake3

const
  DefaultUrl = "http://localhost:7878"
  Usage = """
repro-binary-cache-client — A3 P2 bridge for build-script cache wiring.

Usage:
  repro-binary-cache-client lookup     <entry-key-hex>
  repro-binary-cache-client substitute <entry-key-hex> <out-prefix-dir>
  repro-binary-cache-client publish    <entry-key-hex> <prefix-dir>   [identity-flags]
  repro-binary-cache-client derive-key                                 [identity-flags]

Identity flags (for publish + derive-key):
  --package-name=NAME       --package-version=VER
  --platform-cpu=CPU        --platform-os=OS
  --platform-abi=ABI        --platform-libc=LIBC
  --toolchain-name=N        --toolchain-version=V
  --toolchain-host-ldso=LDSO  --toolchain-extra=FP
  --provider-revision=HEX
  --dep=<hex>               (repeatable)
  --option=<name>=<value>   (repeatable)

Environment:
  REPRO_BINARY_CACHE_URL          default http://localhost:7878
  REPRO_BINARY_CACHE_KEY_PATH     ECDSA-P256 private key (required for publish)
  REPRO_BINARY_CACHE_CERT_PATH    matching pubkey file       (required for publish)
  REPRO_LOCAL_STORE               local store root for substitute
"""
  ArchiveMagic = "RBCA"
  ArchiveVersion = 1'u32

type
  PublishArgs = object
    entryKeyHex: string
    prefixDir: string
    packageName: string
    packageVersion: string
    platformCpu: string
    platformOs: string
    platformAbi: string
    platformLibc: string
    toolchainName: string
    toolchainVersion: string
    toolchainHostLdSo: string
    toolchainExtra: string
    providerRevision: string
    depHex: seq[string]
    options: seq[(string, string)]

# ---------------------------------------------------------------------------
# Archive writer
# ---------------------------------------------------------------------------

proc writeU32LE(buf: var seq[byte]; v: uint32) =
  for shift in countup(0, 24, 8):
    buf.add(byte((v shr uint32(shift)) and 0xff'u32))

proc writeU64LE(buf: var seq[byte]; v: uint64) =
  for shift in countup(0, 56, 8):
    buf.add(byte((v shr uint64(shift)) and 0xff'u64))

proc readU32LE(buf: openArray[byte]; pos: var int): uint32 =
  if pos + 4 > buf.len:
    raise newException(IOError, "rbcarc truncated reading u32")
  result = 0'u32
  for i in 0 ..< 4:
    result = result or (uint32(buf[pos + i]) shl uint32(i * 8))
  inc pos, 4

proc readU64LE(buf: openArray[byte]; pos: var int): uint64 =
  if pos + 8 > buf.len:
    raise newException(IOError, "rbcarc truncated reading u64")
  result = 0'u64
  for i in 0 ..< 8:
    result = result or (uint64(buf[pos + i]) shl uint64(i * 8))
  inc pos, 8

proc normaliseSep(p: string): string =
  result = p.replace('\\', '/')

proc walkPrefix(prefix: string): seq[string] =
  ## Returns paths relative to ``prefix`` (forward-slash separators),
  ## sorted lexicographically for determinism. Symlinks become regular
  ## files (their target is read + recorded as bytes).
  let prefixAbs = absolutePath(prefix)
  for path in walkDirRec(prefixAbs, yieldFilter = {pcFile, pcLinkToFile},
                         relative = true):
    result.add(normaliseSep(path))
  result.sort(cmp)

proc fileModeOctal(path: string): uint32 =
  ## Returns 0o755 if the file is executable, 0o644 otherwise. On
  ## Windows there's no exec bit; we approximate by extension
  ## (``.exe``, ``.com``, ``.bat``, ``.ps1``, ``.sh``).
  when defined(windows):
    let lower = path.toLowerAscii()
    if lower.endsWith(".exe") or lower.endsWith(".com") or
       lower.endsWith(".bat") or lower.endsWith(".ps1") or
       lower.endsWith(".sh"):
      return 0o755'u32
    return 0o644'u32
  else:
    let info = getFileInfo(path)
    if (info.permissions * {fpUserExec, fpGroupExec, fpOthersExec}).len > 0:
      return 0o755'u32
    return 0o644'u32

proc packPrefix(prefix: string): seq[byte] =
  ## Builds the deterministic archive bytes for the prefix tree.
  let entries = walkPrefix(prefix)
  result = newSeqOfCap[byte](4096)
  for ch in ArchiveMagic:
    result.add(byte(ch))
  writeU32LE(result, ArchiveVersion)
  writeU32LE(result, uint32(entries.len))
  for rel in entries:
    let absPath = prefix / rel
    let mode = fileModeOctal(absPath)
    let pathBytes = rel
    let payload = readFile(absPath)
    writeU32LE(result, uint32(pathBytes.len))
    for ch in pathBytes:
      result.add(byte(ch))
    writeU32LE(result, mode)
    writeU64LE(result, uint64(payload.len))
    for ch in payload:
      result.add(byte(ch))

proc extractPrefix(archive: openArray[byte]; outDir: string) =
  if archive.len < 4 + 4 + 4:
    raise newException(IOError, "rbcarc too short: " & $archive.len)
  for i in 0 ..< 4:
    if archive[i] != byte(ArchiveMagic[i]):
      raise newException(IOError, "rbcarc magic mismatch at byte " & $i)
  var pos = 4
  let ver = readU32LE(archive, pos)
  if ver != ArchiveVersion:
    raise newException(IOError, "rbcarc version mismatch: got " & $ver)
  let count = readU32LE(archive, pos)
  createDir(outDir)
  for _ in 0 ..< count:
    let pathLen = int(readU32LE(archive, pos))
    if pos + pathLen > archive.len:
      raise newException(IOError, "rbcarc truncated reading path")
    var rel = newString(pathLen)
    for i in 0 ..< pathLen:
      rel[i] = char(archive[pos + i])
    inc pos, pathLen
    if rel.contains("..") or rel.startsWith("/"):
      raise newException(IOError, "rbcarc rejected unsafe path: " & rel)
    let mode = readU32LE(archive, pos)
    let size = readU64LE(archive, pos)
    if pos + int(size) > archive.len:
      raise newException(IOError, "rbcarc truncated reading file body for " & rel)
    let absOut = outDir / rel
    createDir(parentDir(absOut))
    var data = newString(int(size))
    for i in 0 ..< int(size):
      data[i] = char(archive[pos + i])
    inc pos, int(size)
    writeFile(absOut, data)
    when not defined(windows):
      if (mode and 0o100'u32) != 0:
        var perms = getFilePermissions(absOut)
        perms.incl(fpUserExec)
        perms.incl(fpGroupExec)
        perms.incl(fpOthersExec)
        setFilePermissions(absOut, perms)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc defaultCacheUrl(): string =
  result = getEnv("REPRO_BINARY_CACHE_URL", DefaultUrl)

proc defaultStoreRoot(): string =
  let envRoot = getEnv("REPRO_LOCAL_STORE", "")
  if envRoot.len > 0:
    return envRoot
  when defined(windows):
    return getHomeDir() / "AppData" / "Local" / "repro" / "local-store"
  else:
    return getHomeDir() / ".local" / "share" / "repro" / "local-store"

proc parseEntryKeyHex(hex: string): string =
  ## Normalises + validates the entry-key hex CLI argument.
  if hex.len != 64:
    raise newException(ValueError,
      "entry-key hex must be 64 chars; got " & $hex.len)
  for ch in hex:
    if ch notin {'0'..'9', 'a'..'f', 'A'..'F'}:
      raise newException(ValueError,
        "entry-key hex carries non-hex char: " & hex)
  result = hex.toLowerAscii()

proc loadProducerKeypair(): peerAuth.PeerKeypair =
  let keyPath = getEnv("REPRO_BINARY_CACHE_KEY_PATH", "")
  let certPath = getEnv("REPRO_BINARY_CACHE_CERT_PATH", "")
  if keyPath.len == 0 or certPath.len == 0:
    raise newException(ValueError,
      "publish requires REPRO_BINARY_CACHE_KEY_PATH + " &
      "REPRO_BINARY_CACHE_CERT_PATH to be set")
  result = peerAuth.loadOrGenerateKeypair(certPath, keyPath)

# ---------------------------------------------------------------------------
# lookup / substitute
# ---------------------------------------------------------------------------

proc cmdLookup(args: seq[string]): int =
  if args.len != 1:
    stderr.writeLine(Usage)
    return 2
  let hex = parseEntryKeyHex(args[0])
  let url = defaultCacheUrl() & "/manifests/" & hex
  let client = newHttpClient(timeout = 15_000)
  defer: client.close()
  # Use GET (the A2 server only implements GET / POST routes; HEAD
  # returns 405 from Nim's asynchttpserver).
  try:
    let resp = client.get(url)
    case int(resp.code)
    of 200:
      echo "hit ", hex
      return 0
    of 404:
      echo "miss ", hex
      return 1
    else:
      stderr.writeLine("lookup failed: HTTP " & $resp.code)
      return 3
  except CatchableError as e:
    stderr.writeLine("lookup failed: " & e.msg)
    return 3

proc cmdSubstitute(args: seq[string]): int =
  if args.len != 2:
    stderr.writeLine(Usage)
    return 2
  let hex = parseEntryKeyHex(args[0])
  let outDir = args[1]

  let storeRoot = defaultStoreRoot()
  createDir(storeRoot)
  let endpoint = SubstituteEndpoint(
    baseUrl: defaultCacheUrl(),
    trustedSigners: @[],   # v1 trusts any signer the server returned
    priority: 0)
  let res = substituteInProcess(hex, storeRoot, @[endpoint])
  if not res.ok:
    stderr.writeLine("substitute failed: " & res.reason)
    return 1
  if res.outcomes.len == 0:
    stderr.writeLine("substitute returned no outcomes for " & hex)
    return 1
  let rootOutcome = res.outcomes[^1]
  if rootOutcome.casPath.len == 0 or not fileExists(rootOutcome.casPath):
    stderr.writeLine("substitute root CAS path missing: " & rootOutcome.casPath)
    return 1
  # The root's CAS blob is the packed prefix archive (per the publish
  # path). Extract it into outDir.
  let archiveBytes = readFile(rootOutcome.casPath)
  var asBytes = newSeq[byte](archiveBytes.len)
  for i, ch in archiveBytes:
    asBytes[i] = byte(ch)
  createDir(outDir)
  try:
    extractPrefix(asBytes, outDir)
  except IOError as e:
    # Not an archive: fall back to single-file extraction (the build
    # script's prefix was a single file like hex0).
    stderr.writeLine("substitute: archive parse failed (" & e.msg &
                     "); writing CAS blob verbatim to " & outDir)
    writeFile(outDir / "blob", archiveBytes)
  echo "hit ", hex, " -> ", outDir
  return 0

# ---------------------------------------------------------------------------
# publish
# ---------------------------------------------------------------------------

proc parseIdentityFlags(flagArgs: seq[string]): PublishArgs =
  # ``allowWhitespaceAfterColon = false`` keeps ``--platform-libc=`` from
  # consuming the next argv slot as its value (the build-script prelude
  # routinely passes empty values to opt out of a field).
  var p = initOptParser(flagArgs, allowWhitespaceAfterColon = false)
  while true:
    p.next()
    case p.kind
    of cmdEnd: break
    of cmdShortOption, cmdLongOption:
      case p.key
      of "package-name": result.packageName = p.val
      of "package-version": result.packageVersion = p.val
      of "platform-cpu": result.platformCpu = p.val
      of "platform-os": result.platformOs = p.val
      of "platform-abi": result.platformAbi = p.val
      of "platform-libc": result.platformLibc = p.val
      of "toolchain-name": result.toolchainName = p.val
      of "toolchain-version": result.toolchainVersion = p.val
      of "toolchain-host-ldso": result.toolchainHostLdSo = p.val
      of "toolchain-extra": result.toolchainExtra = p.val
      of "provider-revision": result.providerRevision = p.val
      of "dep":
        if p.val.len > 0:
          result.depHex.add(parseEntryKeyHex(p.val))
      of "option":
        let eq = p.val.find('=')
        if eq <= 0:
          stderr.writeLine("--option requires name=value form")
          quit(2)
        result.options.add((p.val[0 ..< eq], p.val[eq + 1 .. ^1]))
      else: discard
    of cmdArgument: discard

proc parsePublishArgs(args: seq[string]): PublishArgs =
  if args.len < 2:
    stderr.writeLine(Usage)
    quit(2)
  result = parseIdentityFlags(args[2 .. ^1])
  result.entryKeyHex = parseEntryKeyHex(args[0])
  result.prefixDir = args[1]

proc identityFromArgs(a: PublishArgs): CacheEntryIdentity =
  result = newCacheEntryIdentity(
    packageName = a.packageName,
    packageVersion = a.packageVersion,
    platform = PlatformTriple(
      cpu: a.platformCpu, os: a.platformOs,
      abi: a.platformAbi, libcVariant: a.platformLibc),
    toolchain = ToolchainIdentity(
      name: a.toolchainName, version: a.toolchainVersion,
      hostLdSoAbi: a.toolchainHostLdSo,
      extraFingerprint: a.toolchainExtra),
    providerRevision = a.providerRevision)
  for (k, v) in a.options:
    result.addOption(k, v)
  for depHex in a.depHex:
    result.addDep(depHex)

proc cmdDeriveKey(args: seq[string]): int =
  let parsed = parseIdentityFlags(args)
  let idy = identityFromArgs(parsed)
  echo deriveCacheEntryKeyHex(idy)
  return 0

proc cmdGenKey(args: seq[string]): int =
  ## Generates an ECDSA-P256 keypair and writes the matching key + cert
  ## files at the env-configured paths if missing. Returns 0 on success,
  ## or 0 too if the files already exist (idempotent). Useful for
  ## bootstrap from CI / shell scripts.
  let keyPath = getEnv("REPRO_BINARY_CACHE_KEY_PATH", "")
  let certPath = getEnv("REPRO_BINARY_CACHE_CERT_PATH", "")
  if keyPath.len == 0 or certPath.len == 0:
    stderr.writeLine("gen-key: REPRO_BINARY_CACHE_KEY_PATH + " &
                     "REPRO_BINARY_CACHE_CERT_PATH must be set")
    return 2
  let kp = peerAuth.loadOrGenerateKeypair(certPath, keyPath)
  const HexChars = "0123456789abcdef"
  var pubHex = newStringOfCap(130)
  for b in kp.publicKey:
    pubHex.add(HexChars[(int(b) shr 4) and 0xf])
    pubHex.add(HexChars[int(b) and 0xf])
  echo pubHex
  return 0

proc buildMultipartBody(boundary: string;
                        manifestBytes: openArray[byte];
                        payload: openArray[byte]): string =
  result = ""
  result.add("--" & boundary & "\r\n")
  result.add("Content-Disposition: form-data; name=\"manifest\"\r\n\r\n")
  for b in manifestBytes:
    result.add(char(b))
  result.add("\r\n")
  result.add("--" & boundary & "\r\n")
  result.add("Content-Disposition: form-data; name=\"payload\"\r\n\r\n")
  for b in payload:
    result.add(char(b))
  result.add("\r\n")
  result.add("--" & boundary & "--\r\n")

proc bytesOfStr(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  for i, ch in s:
    result[i] = byte(ch)

proc cmdPublish(rawArgs: seq[string]): int =
  ## M9.L.4-refactor Step A: thin wrapper that translates CLI flags +
  ## env vars into a ``PublishInProcessRequest`` and forwards to the
  ## library implementation. The pre-existing drift-guard +
  ## packaging + sign + POST live in ``publishInProcess``
  ## (libs/repro_binary_cache_client/src/repro_binary_cache_client/
  ## in_process.nim). Keeping CLI behaviour byte-identical:
  ##
  ##   * exit 2 — identity hex mismatch + missing prefix dir + missing
  ##     key/cert env vars (these are all caller-input errors, the
  ##     pre-refactor CLI also exited 2 on them).
  ##   * exit 1 — HTTP failure / network error.
  ##   * exit 0 — server accepted the publish.
  ##   * stdout — ``published <entryKeyHex>`` on success.
  ##   * stderr — diagnostic text on failure (unchanged).
  let args = parsePublishArgs(rawArgs)
  let idy = identityFromArgs(args)
  let kp =
    try: loadProducerKeypair()
    except ValueError as e:
      stderr.writeLine(e.msg)
      return 2
  let req = PublishInProcessRequest(
    entryKeyHex: args.entryKeyHex,
    prefixDir: args.prefixDir,
    identity: idy,
    endpoint: defaultCacheUrl(),
    keypair: kp)
  let res = publishInProcess(req)
  if not res.ok:
    stderr.writeLine(res.error)
    # Drift-guard + missing-prefix errors are caller-input failures
    # (exit 2); everything else is a runtime / network failure (exit 1).
    # The pre-refactor CLI used the same partitioning.
    if res.statusCode == 0 and
       (res.error.contains("identity-derived key does not match") or
        res.error.contains("prefix path does not exist")):
      return 2
    return 1
  echo "published ", res.responseBody.strip()
  return 0

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

proc main(): int =
  let rawParams = commandLineParams()
  if rawParams.len == 0:
    echo Usage
    return 0
  case rawParams[0]
  of "lookup":
    return cmdLookup(rawParams[1 .. ^1])
  of "substitute":
    return cmdSubstitute(rawParams[1 .. ^1])
  of "publish":
    return cmdPublish(rawParams[1 .. ^1])
  of "derive-key":
    return cmdDeriveKey(rawParams[1 .. ^1])
  of "gen-key":
    return cmdGenKey(rawParams[1 .. ^1])
  of "-h", "--help", "help":
    echo Usage
    return 0
  else:
    echo Usage
    return 2

when isMainModule:
  quit(main())
