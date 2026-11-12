import std/[json, os, osproc, re, sequtils, streams, strtabs, strutils,
    tempfiles, times, unittest]

import repro_interface_artifacts
import repro_local_store
import repro_store_daemon
import repro_test_support
import repro_tool_profiles
import repro_tool_profiles/archive_digest

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

proc publicReproBin(): string = repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt)
  ## Executable-Consolidation M3/M5: the standalone ``reprostored`` binary was
  ## removed; the dev store daemon is the ``repro`` image run as
  ## ``repro store serve --dev`` (the same self-spawn ``startDevDaemon`` uses).
  ## The test spawns that process form directly so it controls the daemon
  ## lifecycle (kill/restart) the way the M66/M67 scenarios require.

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

proc buildTarballFixture(tempRoot: string):
    tuple[url: string; sha256: string; sha512: string] =
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
   sha256: fileSha256Hex(archivePath),
   sha512: fileShaHex(archivePath, "sha512"))

const
  ## The ranged ``uses:`` constraint and the version the fixture record
  ## declares for it. The client judges the range against the record it
  ## selects; the daemon rebuilds that record from the request and judges it
  ## again, so the version has to cross the socket for the two to agree.
  RangedTarballConstraint = "m67-tarball >=1.0"
  FixtureTarballVersion = "1.0.0"

proc tarballUse(url, sha256: string; constraint = "m67-tarball";
                version = ""): InterfaceToolUse =
  result = InterfaceToolUse(
    rawConstraint: constraint,
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
  result.tarballProvisioning[0].detail.version = version

proc sha512OnlyTarballUse(url, sha512: string): InterfaceToolUse =
  ## The fixture archive pinned only by SHA-512, as an upstream that
  ## publishes no SHA-256 is. The digest lives in the record's archive
  ## detail, and the client's plan carries an empty ``sha256`` for it.
  result = tarballUse(url, "")
  result.tarballProvisioning[0].sha256 = ""
  result.tarballProvisioning[0].lockIdentity = ""
  result.tarballProvisioning[0].detail.sha512 = "sha512:" & sha512

proc extractPathTarballUse(url, sha256: string): InterfaceToolUse =
  ## The fixture archive realized through an installer feature: instead of
  ## ``stripComponents``, the record names the inner directory to flatten to
  ## the prefix root (``extractPath``, part of the archive detail). Extracted
  ## as a plain archive, the executable would sit one directory down.
  result = tarballUse(url, sha256)
  result.tarballProvisioning[0].stripComponents = 0
  result.tarballProvisioning[0].detail.extractPath = "m67tarball-1.0.0"

const
  ## The closure fixture: a directory beside the archive standing in for the
  ## one that holds the declaring ``repro.nim``, the manifest it declares by
  ## a RELATIVE path, and the one archive that manifest names.
  ClosureDeclDir = "decl"
  ClosureManifestName = "closure.manifest"
  ClosureEntryDir = "lib"
  ClosureEntryFile = "dep.txt"

proc fixtureRootOf(url: string): string =
  ## The temp root ``buildTarballFixture`` wrote the archive into, recovered
  ## from its ``file://`` URL so a client worker needs no extra argument.
  parentDir(url.substr("file://".len))

proc closureTarballUse(url, sha256: string): InterfaceToolUse =
  ## The fixture archive with a closure, declared by a record whose
  ## ``closureManifest`` is relative to the file that declared it. Neither
  ## the client's nor the daemon's working directory is that file's
  ## directory, so only a manifest resolved against the declaring file is
  ## found.
  result = tarballUse(url, sha256)
  result.tarballProvisioning[0].closureManifest = ClosureManifestName
  result.tarballProvisioning[0].location = SourceLocation(
    file: fixtureRootOf(url) / ClosureDeclDir / "repro.nim", line: 2)

proc buildClosureFixture(root: string) =
  ## Write the closure archive and the manifest naming it, next to the
  ## declaring file ``closureTarballUse`` reports.
  let payload = root / "closure-payload" / "dep"
  createDir(payload)
  writeFile(payload / ClosureEntryFile, "closure entry\n")
  let archive = root / "dep.tar.gz"
  let tar = execCmdEx(shellCommand([findExe("tar"), "-czf", archive, "-C",
    root / "closure-payload", "dep"]))
  doAssert tar.exitCode == 0, "tar failed: " & tar.output
  createDir(root / ClosureDeclDir)
  writeFile(root / ClosureDeclDir / ClosureManifestName,
    ClosureEntryDir & " " & fileSha256Hex(archive) & " file://" & archive &
    " tar.gz 1\n")

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

const
  LocalFlakeSelector = ".#hello-sh"
  LocalFlakeText = "printf '%s\\n' reprobuild-nix-daemon-fixture"

proc localFlakeUse(): InterfaceToolUse =
  ## A ``.#attr`` selector: the flake it names is the one in the requesting
  ## client's working directory.
  result = nixUse()
  result.nixProvisioning[0].selector = LocalFlakeSelector
  result.nixProvisioning[0].executablePath = "bin/reprobuild-nix-daemon-fixture"
  result.nixProvisioning[0].packageId = "m67-nix-local-flake"
  result.nixProvisioning[0].lockIdentity = "fixture#" & LocalFlakeSelector

proc runClientWorker(args: seq[string]): int =
  ## --client <tarball|tarball-ranged|tarball-sha512|tarball-extract-path|
  ##           tarball-closure|nix>
  ##          <endpoint> <storeRoot> <holder> <rootId> <statusFile> <barrier>
  ##          [tarballUrl tarballDigest]
  ##
  ## ``tarballDigest`` is the archive's SHA-512 for ``tarball-sha512`` and
  ## its SHA-256 for every other tarball mode.
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
    elif mode == "tarball-ranged":
      doAssert args.len >= 10
      let req = requestFromTarballUse(tarballUse(args[8], args[9],
        RangedTarballConstraint, FixtureTarballVersion),
        storeRoot, holder, rootId)
      realizeTarballViaDaemon(req, endpoint)
    elif mode == "tarball-sha512":
      doAssert args.len >= 10
      let req = requestFromTarballUse(sha512OnlyTarballUse(args[8], args[9]),
        storeRoot, holder, rootId)
      realizeTarballViaDaemon(req, endpoint)
    elif mode == "tarball-extract-path":
      doAssert args.len >= 10
      let req = requestFromTarballUse(extractPathTarballUse(args[8], args[9]),
        storeRoot, holder, rootId)
      realizeTarballViaDaemon(req, endpoint)
    elif mode == "tarball-closure":
      doAssert args.len >= 10
      let req = requestFromTarballUse(closureTarballUse(args[8], args[9]),
        storeRoot, holder, rootId)
      realizeTarballViaDaemon(req, endpoint)
    elif mode == "nix-local-flake":
      # <flakeDir>: the client's working directory, which is not the daemon's.
      doAssert args.len >= 9
      setCurrentDir(args[8])
      let req = requestFromNixUse(localFlakeUse(), storeRoot, holder, rootId)
      realizeNixViaDaemon(req, endpoint)
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

proc startDaemon(endpoint, storeRoot, runtimeRoot: string;
                 workingDir = ""): Process =
  ## Spawn ``repro store serve --dev`` and wait until it answers for
  ## ``storeRoot``. A daemon that exits during start-up is reported with its
  ## output, so the failure names the cause rather than a status timeout.
  ## ``workingDir`` empty runs it in this process's working directory.
  result = startProcess(publicReproBin(), workingDir = workingDir,
    args = @["store", "serve", "--dev", "--store-root", storeRoot,
      "--endpoint", endpoint],
    env = makeEnv(endpoint, runtimeRoot),
    options = {poStdErrToStdOut})
  let status =
    try:
      waitForStatus(endpoint, storeRoot, timeoutMs = 60000)
    except CatchableError as err:
      var detail = err.msg
      if not result.running():
        let rc = result.waitForExit()
        detail.add("; repro store serve exited " & $rc & ": " &
          result.outputStream.readAll())
      result.close()
      raise newException(OSError, detail)
  check status.daemonProfile == StoreDaemonProfileDev

proc checkDaemonRealizesLikeInProcess(mode, prefixName, digest: string;
    inProcessUse: proc (url, digest: string): InterfaceToolUse;
    prepare: proc (root: string) = nil; expectedFiles: seq[string] = @[]) =
  ## Realize one fixture record through the daemon (two concurrent holders,
  ## as every case here does) and in-process into a second store, and
  ## require the same prefix from both: the same store-relative path, the
  ## same realization hash, the executable at the declared path. The daemon
  ## rebuilds the record from the request, so any part of the record the
  ## request drops shows up here as a refusal or as a different prefix.
  ##
  ## The daemon runs in a directory of its own, so a path the request leaves
  ## relative is not found by accident in the test's working directory.
  ## ``prepare`` writes any further fixture files into the temp root before
  ## either realize, and every prefix-relative path in ``expectedFiles`` must
  ## exist in both prefixes.
  let root = createTempDir("repro-m67-daemon-" & prefixName & "-", "")
  defer:
    try: removeDir(root) except OSError: discard
  let runtimeRoot = root / "run"
  createDir(runtimeRoot)
  let endpoint = shortEndpoint(prefixName)
  let storeRoot = root / "store"
  defer: stopIfRunning(endpoint)

  let daemonCwd = root / "daemon-cwd"
  createDir(daemonCwd)
  let daemon = startDaemon(endpoint, storeRoot, runtimeRoot, daemonCwd)
  defer: daemon.close()

  let fixture = buildTarballFixture(root)
  if prepare != nil:
    prepare(root)
  let fixtureDigest = if digest == "sha512": fixture.sha512 else: fixture.sha256
  let pair = runPair(mode, endpoint, storeRoot, root,
    @[fixture.url, fixtureDigest])
  verifyPairResult(pair, "tarball", storeRoot)
  let daemonPrefix = pair.a["path"].getStr()
  assertSpecLayoutAfterRealize(storeRoot, daemonPrefix)

  let directStore = root / "direct-store"
  let direct = resolveTarballTool(inProcessUse(fixture.url, fixtureDigest),
    directStore)
  check relativePath(daemonPrefix, storeRoot) ==
    relativePath(direct.selectedStorePath, directStore)
  check readReceiptFile(daemonPrefix / ReceiptFileName).realizationHash ==
    readReceiptFile(direct.selectedStorePath / ReceiptFileName).realizationHash
  let executable =
    when defined(windows): "bin" / "m67tarball.cmd" else: "bin" / "m67tarball"
  check fileExists(daemonPrefix / executable)
  for path in expectedFiles:
    check fileExists(daemonPrefix / path)
    check fileExists(direct.selectedStorePath / path)

suite "M67 daemon-mediated Nix and tarball realization":
  test "integration_daemon_nix_and_tarball_realize":
    when not defined(posix):
      echo "[platform N/A] dev store-daemon IPC is POSIX-only in M66/M67."
    else:
      let root = createTempDir("repro-m67-daemon-", "")
      defer:
        try: removeDir(root) except OSError: discard
      let runtimeRoot = root / "run"
      createDir(runtimeRoot)
      let endpoint = shortEndpoint("realize")
      let storeRoot = root / "store"
      defer: stopIfRunning(endpoint)

      let daemon = startDaemon(endpoint, storeRoot, runtimeRoot)
      defer: daemon.close()

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

      when isNixSupported:
        # Nix is required on the dev environment; no runtime
        # ``findExe("nix")`` probe — a missing nix means the test
        # surface should fail rather than silently pass.
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

      check scoopRealizationIsPerUserFallthrough()

  test "integration_daemon_tarball_realize_ranged_uses":
    # A ``uses:`` with a version range, served by a record that declares a
    # version inside it. The client selects that record; the daemon must
    # realize it rather than refuse it as unversioned.
    when not defined(posix):
      echo "[platform N/A] dev store-daemon IPC is POSIX-only in M66/M67."
    else:
      let root = createTempDir("repro-m67-daemon-ranged-", "")
      defer:
        try: removeDir(root) except OSError: discard
      let runtimeRoot = root / "run"
      createDir(runtimeRoot)
      let endpoint = shortEndpoint("ranged")
      let storeRoot = root / "store"
      defer: stopIfRunning(endpoint)

      let daemon = startDaemon(endpoint, storeRoot, runtimeRoot)
      defer: daemon.close()

      let fixture = buildTarballFixture(root)
      let pair = runPair("tarball-ranged", endpoint, storeRoot, root,
        @[fixture.url, fixture.sha256])
      verifyPairResult(pair, "tarball", storeRoot)
      assertSpecLayoutAfterRealize(storeRoot, pair.a["path"].getStr())

  test "integration_daemon_tarball_realize_sha512_only_record":
    # A record pinned only by SHA-512. The digest is part of the record's
    # archive detail; the daemon must verify against it, as the same realize
    # does in-process, rather than find no digest at all.
    when not defined(posix):
      echo "[platform N/A] dev store-daemon IPC is POSIX-only in M66/M67."
    else:
      checkDaemonRealizesLikeInProcess("tarball-sha512", "sha512", "sha512",
        sha512OnlyTarballUse)

  test "integration_daemon_tarball_realize_installer_feature_record":
    # A record realized through an installer feature (``extractPath``). The
    # daemon must lay out the prefix the in-process realize does, rather than
    # extract the archive as a plain one.
    when not defined(posix):
      echo "[platform N/A] dev store-daemon IPC is POSIX-only in M66/M67."
    else:
      checkDaemonRealizesLikeInProcess("tarball-extract-path", "extract",
        "sha256", extractPathTarballUse)

  test "integration_daemon_tarball_realize_relative_closure_manifest":
    # A record whose ``closureManifest`` is relative to the file that
    # declared it. In-process the manifest resolves next to that file; the
    # daemon, running in another directory, must open the same manifest and
    # lay the same closure into the same prefix, rather than look for the
    # relative path under its own working directory.
    when not defined(posix):
      echo "[platform N/A] dev store-daemon IPC is POSIX-only in M66/M67."
    else:
      checkDaemonRealizesLikeInProcess("tarball-closure", "closure",
        "sha256", closureTarballUse, buildClosureFixture,
        @[ClosureEntryDir / ClosureEntryFile])

  test "integration_daemon_nix_realize_resolves_selector_against_client_dir":
    # A ``.#attr`` selector names the flake in the requesting client's working
    # directory. The daemon runs elsewhere, so it must resolve the selector
    # against the directory the request carries, as the in-process realize
    # resolves it against its own.
    when not defined(posix) or not isNixSupported:
      echo "[platform N/A] dev store-daemon IPC and Nix are POSIX-only."
    else:
      let root = createTempDir("repro-m67-daemon-nixdir-", "")
      defer:
        try: removeDir(root) except OSError: discard
      let runtimeRoot = root / "run"
      createDir(runtimeRoot)
      let endpoint = shortEndpoint("nixdir")
      let storeRoot = root / "store"
      defer: stopIfRunning(endpoint)

      let fixtureRoot = repoRoot() / "tests" / "fixtures" /
        "nix-daemon-local-flake"
      let flakeDir = root / "client-project"
      createDir(flakeDir)
      let flakeText = readFile(fixtureRoot / "flake.nix")
      doAssert LocalFlakeText in flakeText
      # Unique output, so the realized store path is private to this run.
      writeFile(flakeDir / "flake.nix", flakeText.replace(LocalFlakeText,
        "printf '%s\\n' reprobuild-m67-nixdir-" & $getCurrentProcessId()))
      copyFile(fixtureRoot / "flake.lock", flakeDir / "flake.lock")
      for gitArgs in ["init -q", "add flake.nix flake.lock"]:
        let (output, code) = execCmdEx("git -C " & q(flakeDir) & " " & gitArgs)
        doAssert code == 0, "failed to prepare fixture flake: " & output

      let helper = repoRoot() / "build" / "bin" / "reprobuild-nix-daemon"
      if fileExists(helper):
        putEnv("REPROBUILD_NIX_DAEMON_BIN", helper)
      # Its own directory, which holds no flake: only the client's does.
      let daemonCwd = root / "daemon-cwd"
      createDir(daemonCwd)
      let daemon = startDaemon(endpoint, storeRoot, runtimeRoot, daemonCwd)
      defer: daemon.close()

      let statusFile = root / "nixdir.json"
      let worker = startProcess(binaryPath(),
        args = @["--client", "nix-local-flake", endpoint, storeRoot, "holder-a",
          "nixdir-root", statusFile, "-", flakeDir],
        options = {poStdErrToStdOut})
      let rc = worker.waitForExit()
      if rc != 0: checkpoint(worker.outputStream.readAll())
      worker.close()
      check rc == 0
      if rc == 0:
        let res = parseJson(readFile(statusFile))
        check res["installMethod"].getStr() == "nix"
        check res["selectedStorePath"].getStr().startsWith("/nix/store/")
        check fileExists(res["selectedStorePath"].getStr() /
          "bin" / "reprobuild-nix-daemon-fixture")
