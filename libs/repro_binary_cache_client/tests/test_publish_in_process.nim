## M9.L.4-refactor Step A — publishInProcess library API gate.
##
## Exercises the new ``publishInProcess`` library API (lifted from the
## ``repro cache publish`` handler in
## ``libs/repro_binary_cache_client/src/repro_binary_cache_client/cli_dispatch.nim``
## §cmdPublish) directly, without going through the CLI binary, so
## the engine's new ``binaryCachePublisher`` closure can adopt it
## without forking.
##
## Coverage:
##   * Drift-guard fires when the supplied entry-key hex does not
##     match the identity-derived hex (HARD-FAIL before any byte
##     hits the network).
##   * Missing prefix path produces a structured error result.
##   * Multi-file directory round-trip publishes against the real
##     A2 server subprocess; the manifest's signature verifies.
##   * Single-file prefix round-trip exercises the
##     ``packSingleFilePrefix`` fallback.
##   * Result.bytesUploaded is populated on success.
##
## Server subprocess is shared with the existing A2/A3 gates.

import std/[net, os, osproc, random, streams, strutils, times, unittest]

import ../src/repro_binary_cache_client
import ../../repro_binary_cache_server/src/repro_binary_cache_server/types
import ../../repro_binary_cache_server/src/repro_binary_cache_server/manifest_codec as serverCodec
import ../../repro_peer_cache/src/repro_peer_cache/auth as peerAuth

const
  ServerBinary = "build/test-bin" / addFileExt("repro_binary_cache", ExeExt)

proc pickPort(): int =
  var sock = newSocket()
  sock.bindAddr(Port(0), "127.0.0.1")
  let local = sock.getLocalAddr()
  sock.close()
  int(local[1])

proc waitForListener(srvProc: Process; port: int; tries = 2400;
                     sleepMs = 50): bool =
  for _ in 0 ..< tries:
    if not srvProc.running():
      checkpoint("server exited before opening listener; exit=" &
        $srvProc.peekExitCode())
      return false
    var sock: Socket
    try:
      sock = newSocket()
      sock.connect("127.0.0.1", Port(port))
      return true
    except CatchableError:
      sleep(sleepMs)
    finally:
      if not sock.isNil:
        try: sock.close() except CatchableError: discard
  return false

proc startServer(serverRoot: string; port: int): Process =
  startProcess(absolutePath(ServerBinary),
               args = @["--root=" & serverRoot,
                        "--listen=127.0.0.1:" & $port,
                        "--print-pubkey"],
               options = {poStdErrToStdOut})

proc waitForExitWithin(p: Process; millis: int): bool =
  let deadline = epochTime() + (millis.float / 1000.0)
  while epochTime() < deadline:
    if p.peekExitCode() != -1:
      return true
    sleep(20)
  p.peekExitCode() != -1

proc drainServerOutput(p: Process): string =
  try:
    let stream = p.outputStream
    if stream.isNil:
      return ""
    result = stream.readAll()
  except CatchableError as e:
    result = "failed to read server output: " & e.msg & "\n"

proc stopServer(p: Process): string =
  try:
    if p.peekExitCode() == -1:
      try: p.terminate() except CatchableError: discard
      if not waitForExitWithin(p, 5000):
        try: p.kill() except CatchableError: discard
        discard waitForExitWithin(p, 30_000)
    if p.peekExitCode() != -1:
      discard p.waitForExit()
      result = drainServerOutput(p)
    else:
      result = "server process did not exit after terminate/kill\n"
  finally:
    try: p.close() except CatchableError: discard

proc checkpointServerOutput(prefix: string; output: string) =
  if output.len > 0:
    checkpoint(prefix & " server output:\n" & output)
  else:
    checkpoint(prefix & " server produced no output")

proc localPlatform(): PlatformTriple =
  when defined(amd64) or defined(x86_64):
    const cpu = "x86_64"
  elif defined(arm64) or defined(aarch64):
    const cpu = "aarch64"
  else:
    const cpu = "unknown"
  when defined(linux):
    const osName = "linux"; const abi = "gnu"
  elif defined(windows):
    const osName = "windows"; const abi = "msvc"
  else:
    const osName = "darwin"; const abi = ""
  PlatformTriple(cpu: cpu, os: osName, abi: abi, libcVariant: "")

proc stubIdentity(name = "publish-in-process-test";
                  ver = "1.0.0";
                  rev = "rev-001"): CacheEntryIdentity =
  result = newCacheEntryIdentity(
    packageName = name,
    packageVersion = ver,
    platform = localPlatform(),
    toolchain = ToolchainIdentity(name: "stub", version: "1",
                                  hostLdSoAbi: "", extraFingerprint: ""),
    providerRevision = rev)

proc addU32Le(bytes: var seq[byte]; value: uint32) =
  for shift in countup(0, 24, 8):
    bytes.add(byte((value shr uint32(shift)) and 0xff'u32))

proc addU64Le(bytes: var seq[byte]; value: uint64) =
  for shift in countup(0, 56, 8):
    bytes.add(byte((value shr uint64(shift)) and 0xff'u64))

suite "M9.L.4-refactor Step A — publishInProcess library API":

  test "rbcarc v2 preserves directories, permissions, and symlinks":
    let prefixDir = getTempDir() / ("rbcarc_v2_prefix_" & $rand(999_999))
    let outputDir = getTempDir() / ("rbcarc_v2_output_" & $rand(999_999))
    removeDir(prefixDir)
    removeDir(outputDir)
    createDir(prefixDir / "bin")
    createDir(prefixDir / "empty")
    writeFile(prefixDir / "bin" / "tool", "payload\n")
    when not defined(windows):
      setFilePermissions(prefixDir / "bin" / "tool",
        {fpUserRead, fpUserWrite, fpUserExec, fpGroupRead, fpGroupExec,
         fpOthersRead, fpOthersExec})
      createSymlink("tool", prefixDir / "bin" / "tool-link")
    defer:
      try: removeDir(prefixDir) except CatchableError: discard
      try: removeDir(outputDir) except CatchableError: discard

    let archive = packPrefix(prefixDir)
    check archive == packPrefix(prefixDir)
    extractPrefix(archive, outputDir)
    check readFile(outputDir / "bin" / "tool") == "payload\n"
    check dirExists(outputDir / "empty")
    when not defined(windows):
      check symlinkExists(outputDir / "bin" / "tool-link")
      check expandSymlink(outputDir / "bin" / "tool-link") == "tool"
      check fpUserExec in getFilePermissions(outputDir / "bin" / "tool")
      check fpGroupExec in getFilePermissions(outputDir / "bin" / "tool")
      check fpOthersExec in getFilePermissions(outputDir / "bin" / "tool")

  test "rbcarc v1 archives remain extractable":
    let outputDir = getTempDir() / ("rbcarc_v1_output_" & $rand(999_999))
    removeDir(outputDir)
    defer:
      try: removeDir(outputDir) except CatchableError: discard
    let relativePath = "legacy.txt"
    let payload = "legacy payload\n"
    var archive: seq[byte] = @[]
    for ch in "RBCA":
      archive.add(byte(ch))
    archive.addU32Le(1'u32)
    archive.addU32Le(1'u32)
    archive.addU32Le(uint32(relativePath.len))
    for ch in relativePath:
      archive.add(byte(ch))
    archive.addU32Le(0o644'u32)
    archive.addU64Le(uint64(payload.len))
    for ch in payload:
      archive.add(byte(ch))

    extractPrefix(archive, outputDir)
    check readFile(outputDir / relativePath) == payload

  test "drift-guard fires when supplied hex disagrees with identity-derived hex":
    let identity = stubIdentity()
    # 64-char all-zero hex is not the identity's derived key.
    let req = PublishInProcessRequest(
      entryKeyHex: "0000000000000000000000000000000000000000000000000000000000000000",
      prefixDir: getTempDir(),
      identity: identity,
      endpoint: "http://127.0.0.1:1",  # bogus port; we MUST short-circuit
      keypair: peerAuth.generateKeypair())
    let res = publishInProcess(req)
    check (not res.ok)
    check res.statusCode == 0  # no HTTP issued
    check res.error.contains("identity-derived key does not match")
    check res.bytesUploaded == 0

  test "missing prefix path produces a structured error":
    let identity = stubIdentity(rev = "missing-prefix")
    let derivedHex = deriveCacheEntryKeyHex(identity)
    let req = PublishInProcessRequest(
      entryKeyHex: derivedHex,
      prefixDir: getTempDir() / "this-path-does-not-exist-" & $rand(999_999),
      identity: identity,
      endpoint: "http://127.0.0.1:1",
      keypair: peerAuth.generateKeypair())
    let res = publishInProcess(req)
    check (not res.ok)
    check res.error.contains("prefix path does not exist")

  test "oversized archive is rejected before allocation or HTTP":
    # The payload is RANDOM, not a run of zeros. The limit is now weighed
    # against the bytes actually uploaded, and 4 KiB of zeros compresses to a
    # few dozen bytes — which is the point of compressing, but would make
    # this gate pass for the wrong reason and stop testing the rejection at
    # all. Random bytes are incompressible, so the archive stays oversized
    # whether or not this host can load libzstd.
    let prefixDir = getTempDir() / ("pub_in_proc_oversized_" & $rand(999_999))
    createDir(prefixDir)
    defer:
      try: removeDir(prefixDir) except CatchableError: discard
    var incompressible = newString(4096)
    for i in 0 ..< incompressible.len:
      incompressible[i] = char(rand(255))
    writeFile(prefixDir / "payload.bin", incompressible)

    let identity = stubIdentity(rev = "oversized-prefix")
    let req = PublishInProcessRequest(
      entryKeyHex: deriveCacheEntryKeyHex(identity),
      prefixDir: prefixDir,
      identity: identity,
      endpoint: "http://127.0.0.1:1",
      keypair: peerAuth.generateKeypair(),
      maxArchiveBytes: 1024)
    let res = publishInProcess(req)
    check (not res.ok)
    check res.statusCode == 0
    check res.bytesUploaded == 0
    check res.error.contains("exceeding the 1024-byte /publish payload limit")

  test "a compressible prefix over the raw limit publishes compressed":
    # The behaviour the compressor exists for. Before it, the limit was
    # checked against the UNCOMPRESSED archive, so a prefix whose compressed
    # form fits comfortably was refused outright — which is exactly the
    # situation of every toolchain big enough to be worth caching.
    #
    # Skipped rather than failed where libzstd is unavailable: publishing
    # uncompressed is a supported outcome, and a host without the codec is
    # not a broken host.
    if not supportsCompressor(ckZstd):
      skip()
    else:
      let port = pickPort()
      let serverRoot = getTempDir() / ("pub_in_proc_zsrv_" & $rand(999_999))
      let prefixDir = getTempDir() / ("pub_in_proc_zpfx_" & $rand(999_999))
      removeDir(serverRoot); removeDir(prefixDir)
      createDir(serverRoot); createDir(prefixDir)
      defer:
        try: removeDir(serverRoot) except CatchableError: discard
        try: removeDir(prefixDir) except CatchableError: discard

      # 4 MiB of highly compressible content: well over the 1 MiB cap below
      # raw, far under it compressed.
      writeFile(prefixDir / "payload.bin", repeat("compressible-", 322_122))

      let srvProc = startServer(serverRoot, port)
      defer:
        try:
          if srvProc.running(): srvProc.terminate()
          srvProc.close()
        except CatchableError: discard
      check waitForListener(srvProc, port)

      let baseUrl = "http://127.0.0.1:" & $port
      let kp = peerAuth.generateKeypair()
      let identity = stubIdentity(rev = "compressed-publish")
      let derivedHex = deriveCacheEntryKeyHex(identity)
      let res = publishInProcess(PublishInProcessRequest(
        entryKeyHex: derivedHex,
        prefixDir: prefixDir,
        identity: identity,
        endpoint: baseUrl,
        keypair: kp,
        maxArchiveBytes: 1024 * 1024))
      if not res.ok:
        echo "compressed publish failed: status=", res.statusCode,
          " err=", res.error
      check res.ok
      check res.bytesUploaded > 0
      # Uploaded well under the raw size: proof the cap was applied to the
      # compressed form rather than merely being raised.
      check res.bytesUploaded < 1024 * 1024

      let pool = newHttpPool()
      defer: pool.close()
      let cfg = defaultConfig(
        getTempDir() / ("pub_in_proc_zcli_" & $rand(999_999)), @[
          SubstituteEndpoint(
            baseUrl: baseUrl,
            trustedSigners: @[kp.publicKey],
            priority: 30)])
      let ctx = newClientContext(cfg)
      defer: ctx.close()
      let fetched = fetchAndVerifyManifest(ctx, pool, cfg.endpoints[0],
        derivedHex)
      check serverCodec.verifyManifest(fetched)
      check fetched.payloads.len == 1
      # The manifest must DECLARE the codec: a consumer has only the
      # manifest to tell it how to read the bytes.
      check fetched.payloads[0].compression == ckZstd
      check fetched.payloads[0].declaredSize < fetched.payloads[0].uncompressedSize
      check fetched.payloads[0].uncompressedSize > 1024'u64 * 1024

  test "extractPrefix reads a zstd-compressed archive transparently":
    # The consumer half of the same contract. The CAS stores the payload
    # exactly as the producer signed it, so a substituted blob arrives
    # compressed with no manifest attached; every call site that unpacks one
    # relies on extractPrefix sniffing the frame rather than being told.
    if not supportsCompressor(ckZstd):
      skip()
    else:
      let sourceDir = getTempDir() / ("extract_zstd_src_" & $rand(999_999))
      let outDir = getTempDir() / ("extract_zstd_out_" & $rand(999_999))
      removeDir(sourceDir); removeDir(outDir)
      createDir(sourceDir / "bin")
      defer:
        try: removeDir(sourceDir) except CatchableError: discard
        try: removeDir(outDir) except CatchableError: discard
      writeFile(sourceDir / "bin" / "tool", repeat("payload-", 100_000))
      writeFile(sourceDir / "readme.txt", "hello\nworld\n")

      let plain = packPrefix(sourceDir)
      let rawPath = getTempDir() / ("extract_zstd_" & $rand(999_999) & ".rbcarc")
      let zstPath = rawPath & ".zst"
      defer:
        try: removeFile(rawPath) except CatchableError: discard
        try: removeFile(zstPath) except CatchableError: discard
      var rawText = newString(plain.len)
      for i, b in plain:
        rawText[i] = char(b)
      writeFile(rawPath, rawText)
      let compressedSize = compressFileToFile(rawPath, zstPath, ckZstd)
      check compressedSize > 0
      check compressedSize < plain.len

      let compressedText = readFile(zstPath)
      var compressedBytes = newSeq[byte](compressedText.len)
      for i, ch in compressedText:
        compressedBytes[i] = byte(ch)
      check isZstdFrame(compressedBytes)

      extractPrefix(compressedBytes, outDir)
      check readFile(outDir / "readme.txt") == "hello\nworld\n"
      check readFile(outDir / "bin" / "tool") == repeat("payload-", 100_000)

  test "multi-file directory round-trip + signature verifies":
    let port = pickPort()
    let serverRoot = getTempDir() / ("pub_in_proc_srv_" & $rand(999_999))
    let prefixDir = getTempDir() / ("pub_in_proc_prefix_" & $rand(999_999))
    removeDir(serverRoot); removeDir(prefixDir)
    createDir(serverRoot); createDir(prefixDir)
    defer:
      try: removeDir(serverRoot) except CatchableError: discard
      try: removeDir(prefixDir) except CatchableError: discard

    # 3-file prefix.
    createDir(prefixDir / "bin")
    createDir(prefixDir / "share")
    writeFile(prefixDir / "bin" / "exec", "executable-payload")
    writeFile(prefixDir / "share" / "data.txt", "text payload\nline two\n")
    # Exercise the same bounded HTTP upload path used by production artifacts.
    var blob = newString(24 * 1024 * 1024)
    for i in 0 ..< blob.len:
      blob[i] = char(i mod 256)
    writeFile(prefixDir / "blob.bin", blob)

    let srvProc = startServer(serverRoot, port)
    var serverStopped = false
    var serverOutput = ""
    proc stopServerOnce() =
      if not serverStopped:
        serverOutput = stopServer(srvProc)
        serverStopped = true
    defer:
      stopServerOnce()
      if serverOutput.contains("Traceback") or
          serverOutput.contains("Error:") or
          serverOutput.contains("Exception"):
        checkpointServerOutput("multi-file", serverOutput)
    if not waitForListener(srvProc, port):
      checkpoint("server did not listen on port " & $port)
      stopServerOnce()
      checkpointServerOutput("multi-file", serverOutput)
      check false
    else:
      let baseUrl = "http://127.0.0.1:" & $port

      let kp = peerAuth.generateKeypair()
      let identity = stubIdentity(rev = "multi-file-rev")
      let derivedHex = deriveCacheEntryKeyHex(identity)
      let req = PublishInProcessRequest(
        entryKeyHex: derivedHex,
        prefixDir: prefixDir,
        identity: identity,
        endpoint: baseUrl,
        keypair: kp)
      let res = publishInProcess(req)
      if not res.ok:
        echo "publish failed: status=", res.statusCode, " err=", res.error
      check res.ok
      check res.statusCode in 200 .. 299
      check res.bytesUploaded > 0
      check res.responseBody.contains(derivedHex)

      # The server now holds a manifest under derivedHex; fetch it
      # back via the lookup HTTP route to confirm the signature shape
      # is what the codec produced.
      let pool = newHttpPool()
      defer: pool.close()
      let cfg = defaultConfig(
        getTempDir() / ("pub_in_proc_cli_" & $rand(999_999)), @[
          SubstituteEndpoint(
            baseUrl: baseUrl,
            trustedSigners: @[kp.publicKey],
            priority: 30)])
      let ctx = newClientContext(cfg)
      defer: ctx.close()
      let endpoint = cfg.endpoints[0]
      let fetched = fetchAndVerifyManifest(ctx, pool, endpoint, derivedHex)
      check serverCodec.verifyManifest(fetched)
      check fetched.entryKey.packageName == "publish-in-process-test"
      check fetched.payloads.len == 1
      check fetched.producerPubKey == kp.publicKey

  test "single-file prefix round-trip exercises packSingleFilePrefix":
    let port = pickPort()
    let serverRoot = getTempDir() / ("pub_in_proc_srv_sf_" & $rand(999_999))
    let prefixFile = getTempDir() / ("pub_in_proc_file_" & $rand(999_999))
    removeDir(serverRoot)
    if fileExists(prefixFile): removeFile(prefixFile)
    createDir(serverRoot)
    defer:
      try: removeDir(serverRoot) except CatchableError: discard
      try: removeFile(prefixFile) except CatchableError: discard

    writeFile(prefixFile, "single-file payload contents")

    let srvProc = startServer(serverRoot, port)
    var serverStopped = false
    var serverOutput = ""
    proc stopServerOnce() =
      if not serverStopped:
        serverOutput = stopServer(srvProc)
        serverStopped = true
    defer:
      stopServerOnce()
      if serverOutput.contains("Traceback") or
          serverOutput.contains("Error:") or
          serverOutput.contains("Exception"):
        checkpointServerOutput("single-file", serverOutput)
    if not waitForListener(srvProc, port):
      checkpoint("server did not listen on port " & $port)
      stopServerOnce()
      checkpointServerOutput("single-file", serverOutput)
      check false
    else:
      let baseUrl = "http://127.0.0.1:" & $port

      let kp = peerAuth.generateKeypair()
      let identity = stubIdentity(rev = "single-file-rev")
      let derivedHex = deriveCacheEntryKeyHex(identity)
      let req = PublishInProcessRequest(
        entryKeyHex: derivedHex,
        prefixDir: prefixFile,
        identity: identity,
        endpoint: baseUrl,
        keypair: kp)
      let res = publishInProcess(req)
      if not res.ok:
        echo "single-file publish failed: status=", res.statusCode,
             " err=", res.error
      check res.ok
      check res.bytesUploaded > 0
