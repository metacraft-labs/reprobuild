import std/[json, os, osproc, re, sequtils, streams, strtabs, strutils,
    tempfiles, times, unittest]

import repro_interface_artifacts
import repro_local_store
import repro_store_daemon
import repro_tool_profiles

# ---------------------------------------------------------------------------
# Spec-layout invariants — see reprobuild-specs/Local-Content-Addressed-Store.md
# §"Why SQLite for the store index" / §"Schema" / §"`cas/`" and
# reprobuild-specs/Store-Daemon-And-Multi-User-Coordination.md §"Receipts".
#
# The exact on-disk shape of the store is the daemon's primary public
# contract. We assert it inside the M67 happy-path test rather than in a
# separate file so a change that drifts the layout fails next to the
# realization that produced it.
# ---------------------------------------------------------------------------

const
  ## `prefixes/<pkg>/<version>-<hash>` where the hash segment is the
  ## first 16 hex chars (lowercase) of the BLAKE3 realization id. See
  ## `realizationDirName` in libs/repro_local_store/src/repro_local_store/
  ## store.nim — keep this regex in lock-step with that proc.
  PrefixDirNameRe* = r"^[^/]+-[0-9a-f]{16}$"

  ## `cas/blake3/<aa>/<full-hash>` where `<aa>` is the first two hex
  ## chars of `<full-hash>`, and `<full-hash>` is exactly 64 lowercase
  ## hex chars (BLAKE3-256 → 32 bytes). See `casBlobRelative` in the
  ## same file.
  CasBlobNameRe* = r"^[0-9a-f]{64}$"
  CasShardDirRe* = r"^[0-9a-f]{2}$"

proc assertSpecLayoutAfterRealize(storeRoot, realizedPrefixPath: string) =
  ## Cross-check the spec-required directory shape of a populated store
  ## root after a successful daemon-mediated realization.
  ##
  ## The daemon must:
  ##
  ## * Leave the store in WAL-mode SQLite (`index.db` plus the sidecar
  ##   `index.db-wal` and `index.db-shm` files).
  ## * Lay realized prefixes under
  ##   `<root>/prefixes/<package-segment>/<version>-<16hex>/` where the
  ##   trailing dir name is exactly what `realizationDirName` in
  ##   `libs/repro_local_store/.../store.nim` emits. The intermediate
  ##   `<package-segment>` is adapter-specific (e.g. the tarball adapter
  ##   uses `<pkg>_<version>`, the Nix adapter uses
  ##   `<adapter>.<pkg>.<executable>`) — we assert the nesting depth
  ##   and the trailing-dir regex but do not impose a uniform package
  ##   segment shape across adapters.
  ## * Drop a `.repro-receipt` sidecar inside the realized prefix.
  ## * Materialize content-addressed blobs (when any are written) under
  ##   `<root>/cas/blake3/<aa>/<full-hash>` with the two-hex shard
  ##   matching the first two chars of the blob's full hash. The daemon
  ##   may take a direct-rename shortcut on fresh realizations that
  ##   leaves the CAS subtree empty; we assert only the sharding shape
  ##   for whatever blobs are present.

  # SQLite index in WAL mode.
  check fileExists(storeRoot / "index.db")
  check fileExists(storeRoot / "index.db-wal")
  check fileExists(storeRoot / "index.db-shm")

  # Realized prefix lives at depth 2 under `<root>/prefixes/...` and
  # carries the receipt sidecar.
  let prefixesRoot = storeRoot / "prefixes"
  check dirExists(prefixesRoot)
  check realizedPrefixPath.startsWith(prefixesRoot)
  check fileExists(realizedPrefixPath / ReceiptFileName)
  check realizedPrefixPath.parentDir.parentDir == prefixesRoot

  let realizationDir = realizedPrefixPath.extractFilename
  check realizationDir.match(re(PrefixDirNameRe))

  # Content-addressed cas/blake3/<aa>/<full-hash> sharding. Every blob
  # present must live under a two-hex-char shard whose name matches the
  # first two chars of its full hash; we do not require a minimum count
  # because the daemon is allowed to direct-rename a fresh realization
  # without round-tripping through `cas/`.
  let casRoot = storeRoot / "cas" / "blake3"
  check dirExists(casRoot)
  for shardKind, shardPath in walkDir(casRoot):
    if shardKind != pcDir:
      continue
    let shardName = shardPath.extractFilename
    check shardName.match(re(CasShardDirRe))
    for blobKind, blobPath in walkDir(shardPath):
      if blobKind != pcFile:
        continue
      let blobName = blobPath.extractFilename
      check blobName.match(re(CasBlobNameRe))
      check blobName[0 ..< 2] == shardName

proc shortEndpoint(name: string): string =
  "/tmp/repro-m67-" & $getCurrentProcessId() & "-" & name & ".sock"

proc binaryPath(): string = getAppFilename()

proc repoRoot(): string = getCurrentDir()

proc reprostoredBin(): string = repoRoot() / "build" / "bin" / addFileExt("reprostored", ExeExt)

proc makeEnv(endpoint, runtimeRoot: string): StringTableRef =
  result = newStringTable()
  for key, value in envPairs():
    result[key] = value
  result["REPROSTORED_ENDPOINT"] = endpoint
  result["XDG_RUNTIME_DIR"] = runtimeRoot

proc q(value: string): string = quoteShell(value)

proc shellCommand(args: openArray[string]): string =
  args.mapIt(q(it)).join(" ")

proc waitForStatus(endpoint, storeRoot: string; timeoutMs = 5000):
    StoreDaemonStatus =
  let deadline = epochTime() + float(timeoutMs) / 1000.0
  while epochTime() < deadline:
    let status = queryDevStatus(endpoint)
    if status.running and os.normalizedPath(status.storeRoot) ==
        os.normalizedPath(storeRoot):
      return status
    sleep(25)
  raise newException(OSError, "store daemon did not become ready at " &
    endpoint & " for store root " & storeRoot)

proc stopIfRunning(endpoint: string) =
  if queryDevStatus(endpoint).running:
    try: stopDevDaemon(endpoint) except CatchableError: discard

proc waitForBarrier(path: string) =
  if path == "-":
    return
  let deadline = epochTime() + 10.0
  while epochTime() < deadline and not fileExists(path):
    sleep(5)

proc buildTarballFixture(tempRoot: string): tuple[url: string; sha256: string] =
  let payloadRoot = tempRoot / "tarball-payload"
  let packageRoot = payloadRoot / "m67tarball-1.0.0"
  let binDir = packageRoot / "bin"
  createDir(binDir)
  let toolPath =
    when defined(windows): binDir / "m67tarball.cmd"
    else: binDir / "m67tarball"
  when defined(windows):
    writeFile(toolPath, "@echo off\r\necho m67tarball 1.0.0\r\n")
  else:
    writeFile(toolPath, "#!/bin/sh\nset -eu\necho m67tarball 1.0.0\n")
    setFilePermissions(toolPath, {fpUserRead, fpUserWrite, fpUserExec,
      fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})

  let archivePath = tempRoot / "m67tarball-1.0.0.tar.gz"
  let tarExe =
    when defined(windows):
      let systemTar = r"C:\Windows\System32\tar.exe"
      if fileExists(systemTar): systemTar else: findExe("tar")
    else:
      findExe("tar")
  doAssert tarExe.len > 0, "tar is required for the M67 tarball gate"
  let tar = execCmdEx(shellCommand([tarExe, "-czf", archivePath, "-C",
    payloadRoot, "m67tarball-1.0.0"]))
  doAssert tar.exitCode == 0, "tar failed: " & tar.output
  (url: "file://" & archivePath.replace('\\', '/'),
   sha256: fileSha256Hex(archivePath))

proc tarballUse(url, sha256: string): InterfaceToolUse =
  result = InterfaceToolUse(
    rawConstraint: "m67-tarball",
    packageSelector: "m67-tarball@1.0.0",
    executableName: "m67tarball",
    location: SourceLocation(file: "fixture", line: 1))
  result.tarballProvisioning = @[InterfaceTarballProvisioning(
    packageName: "m67-tarball",
    url: url,
    sha256: "sha256:" & sha256,
    archiveType: "tar.gz",
    executablePath:
      when defined(windows): "bin/m67tarball.cmd" else: "bin/m67tarball",
    stripComponents: 1,
    packageId: "m67-tarball@1.0.0",
    lockIdentity: "sha256:" & sha256,
    location: SourceLocation(file: "fixture", line: 2))]

proc nixUse(): InterfaceToolUse =
  result = InterfaceToolUse(
    rawConstraint: "m67-nix",
    packageSelector: "m67-nix@hello",
    executableName: "hello",
    location: SourceLocation(file: "fixture", line: 1))
  result.nixProvisioning = @[InterfaceNixProvisioning(
    packageName: "m67-nix",
    selector: "nixpkgs#hello",
    executablePath: "bin/hello",
    packageId: "m67-nix.hello",
    lockIdentity: "nixpkgs#hello",
    location: SourceLocation(file: "fixture", line: 2))]

proc runClientWorker(args: seq[string]): int =
  ## --client <tarball|nix> <endpoint> <storeRoot> <holder> <rootId>
  ##          <statusFile> <barrier> [tarballUrl tarballSha256]
  doAssert args.len >= 8
  let mode = args[1]
  let endpoint = args[2]
  let storeRoot = args[3]
  let holder = args[4]
  let rootId = args[5]
  let statusFile = args[6]
  let barrier = args[7]
  waitForBarrier(barrier)
  let res =
    if mode == "tarball":
      doAssert args.len >= 10
      let req = requestFromTarballUse(tarballUse(args[8], args[9]),
        storeRoot, holder, rootId)
      realizeTarballViaDaemon(req, endpoint)
    elif mode == "nix":
      let req = requestFromNixUse(nixUse(), storeRoot, holder, rootId)
      realizeNixViaDaemon(req, endpoint)
    else:
      raise newException(ValueError, "unknown client worker mode: " & mode)
  writeFile(statusFile, $(%*{
    "status": res.status,
    "path": res.realizedPrefixPath,
    "hash": res.realizationHashHex,
    "rootId": res.rootId,
    "writerMode": res.writerMode,
    "installMethod": res.installMethod,
    "selectedStorePath": res.selectedStorePath,
    "profileArtifactPath": res.profileArtifactPath
  }))
  0

when isMainModule:
  let args = commandLineParams()
  if args.len > 0 and args[0] == "--client":
    quit(runClientWorker(args))

proc runPair(mode, endpoint, storeRoot, root: string;
             extra: seq[string] = @[]): tuple[a, b: JsonNode] =
  let barrier = root / (mode & ".go")
  let statusA = root / (mode & "-a.json")
  let statusB = root / (mode & "-b.json")
  let baseA = @["--client", mode, endpoint, storeRoot, "holder-a",
    mode & "-root-a", statusA, barrier] & extra
  let baseB = @["--client", mode, endpoint, storeRoot, "holder-b",
    mode & "-root-b", statusB, barrier] & extra
  let p1 = startProcess(binaryPath(), args = baseA,
    options = {poStdErrToStdOut})
  let p2 = startProcess(binaryPath(), args = baseB,
    options = {poStdErrToStdOut})
  sleep(50)
  writeFile(barrier, "go")
  let rc1 = p1.waitForExit()
  let rc2 = p2.waitForExit()
  if rc1 != 0: checkpoint(p1.outputStream.readAll())
  if rc2 != 0: checkpoint(p2.outputStream.readAll())
  check rc1 == 0
  check rc2 == 0
  p1.close()
  p2.close()
  (a: parseJson(readFile(statusA)), b: parseJson(readFile(statusB)))

proc verifyPairResult(pair: tuple[a, b: JsonNode]; adapter, storeRoot: string) =
  check pair.a["path"].getStr() == pair.b["path"].getStr()
  check pair.a["writerMode"].getStr() == "daemon"
  check pair.b["writerMode"].getStr() == "daemon"
  check pair.a["installMethod"].getStr() == adapter
  check pair.b["installMethod"].getStr() == adapter
  check pair.a["path"].getStr().startsWith(storeRoot / "prefixes")
  check fileExists(pair.a["path"].getStr() / ReceiptFileName)
  for item in [pair.a, pair.b]:
    let artifactPath = item["profileArtifactPath"].getStr()
    check fileExists(artifactPath)
    let identity = readPathOnlyBuildIdentity(artifactPath)
    check identity.profiles.len == 1
    check identity.profiles[0].installMethod == adapter
    if adapter == "nix":
      check identity.profiles[0].selectedStorePath.startsWith("/nix/store/")
    else:
      check identity.profiles[0].selectedStorePath == item["path"].getStr()

suite "M67 daemon-mediated Nix and tarball realization":
  test "integration_daemon_nix_and_tarball_realize":
    when not defined(posix):
      echo "[platform N/A] reprostored --dev IPC is POSIX-only in M66/M67."
    else:
      let root = createTempDir("repro-m67-daemon-", "")
      defer:
        try: removeDir(root) except OSError: discard
      let runtimeRoot = root / "run"
      createDir(runtimeRoot)
      let endpoint = shortEndpoint("realize")
      let storeRoot = root / "store"
      defer: stopIfRunning(endpoint)

      let daemon = startProcess(reprostoredBin(),
        args = @["--dev", "--store-root", storeRoot, "--endpoint", endpoint],
        env = makeEnv(endpoint, runtimeRoot),
        options = {poStdErrToStdOut})
      defer: daemon.close()
      let status =
        try:
          waitForStatus(endpoint, storeRoot, timeoutMs = 60000)
        except CatchableError as err:
          var detail = err.msg
          if not daemon.running():
            let rc = daemon.waitForExit()
            detail.add("; reprostored exited " & $rc & ": " &
              daemon.outputStream.readAll())
          raise newException(OSError, detail)
      check status.daemonProfile == StoreDaemonProfileDev

      let fixture = buildTarballFixture(root)
      let tarPair = runPair("tarball", endpoint, storeRoot, root,
        @[fixture.url, fixture.sha256])
      verifyPairResult(tarPair, "tarball", storeRoot)
      assertSpecLayoutAfterRealize(storeRoot, tarPair.a["path"].getStr())

      block verifyTarballStore:
        var store = openStore(storeRoot)
        defer: store.close()
        let rows = store.listPrefixes()
        check rows.len == 1
        check rows[0].adapter == "tarball"
        check store.listRoots().len == 2
        let receipt = readReceiptFile(tarPair.a["path"].getStr() /
          ReceiptFileName)
        check receipt.writerMode == "daemon"

      when not defined(windows):
        if findExe("nix").len > 0:
          let nixPair = runPair("nix", endpoint, storeRoot, root)
          verifyPairResult(nixPair, "nix", storeRoot)
          assertSpecLayoutAfterRealize(storeRoot, nixPair.a["path"].getStr())
          var store = openStore(storeRoot)
          defer: store.close()
          let rows = store.listPrefixes()
          var nixRows = 0
          var tarballRows = 0
          for row in rows:
            if row.adapter == "nix": inc nixRows
            if row.adapter == "tarball": inc tarballRows
          check nixRows == 1
          check tarballRows == 1
          check store.listRoots().len == 4
          let receipt = readReceiptFile(nixPair.a["path"].getStr() /
            ReceiptFileName)
          check receipt.writerMode == "daemon"
        else:
          echo "[platform N/A] Nix is not installed on this host; skipping " &
            "the Nix sub-gate. Tarball daemon realization still ran."
      else:
        echo "[platform N/A] Nix is not available on Windows hosts; skipping " &
          "the Nix sub-gate per spec."

      check scoopRealizationIsPerUserFallthrough()
