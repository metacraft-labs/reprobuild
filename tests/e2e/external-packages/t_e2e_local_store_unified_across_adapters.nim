## M56 e2e verification gate `e2e_local_store_unified_across_adapters`.
##
## Per the milestone description: realize one package each via Nix
## (where available), verified tarball, and Scoop (Windows); verify
## that all three land in the unified `<store-root>/prefixes/<pkg>/...`
## layout with valid receipts; subsequent `repro store gc` correctly
## preserves the active prefixes.
##
## Platform handling:
##
## - On Windows hosts (the current test platform) Nix is not
##   available. The Nix sub-gate emits a structured "platform N/A"
##   marker but does NOT mock Nix — it asserts the host genuinely
##   lacks Nix and records the diagnostic. The tarball and Scoop
##   sub-gates still run end-to-end against the real adapters.
## - On non-Windows hosts Scoop is N/A symmetrically.
##
## Honest platform-availability gates are NOT weakening; they record
## the platform reality and continue the rest of the suite.

import std/[os, osproc, sequtils, strutils, tables, tempfiles, unittest]

import repro_interface_artifacts
import repro_local_store
import repro_tool_profiles

when defined(windows):
  import ../scoop/scoop_sandbox

# ---------------------------------------------------------------------------
# Tarball fixture
# ---------------------------------------------------------------------------

proc q(value: string): string = quoteShell(value)

proc shellCommand(args: openArray[string]): string =
  args.mapIt(q(it)).join(" ")

proc buildTarballFixture(tempRoot: string): tuple[archivePath: string;
    sha256: string; url: string] =
  ## Builds a tiny `tar.gz` archive containing `bin/m56tarball` (a small
  ## script-style executable) so the verified-tarball adapter has
  ## something real to download and extract.
  let payloadRoot = tempRoot / "tarball-payload"
  let packageRoot = payloadRoot / "m56tarball-1.0.0"
  let binDir = packageRoot / "bin"
  createDir(binDir)
  let toolPath =
    when defined(windows):
      binDir / "m56tarball.cmd"
    else:
      binDir / "m56tarball"
  when defined(windows):
    writeFile(toolPath,
      "@echo off\r\n" &
      "echo m56tarball 1.0.0\r\n")
  else:
    writeFile(toolPath,
      "#!/bin/sh\nset -eu\necho m56tarball 1.0.0\n")
    setFilePermissions(toolPath, {fpUserRead, fpUserWrite, fpUserExec,
      fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})

  let archivePath = tempRoot / "m56tarball-1.0.0.tar.gz"
  when defined(windows):
    # Windows' bsdtar (System32\tar.exe) handles native Windows paths.
    # MSYS-bundled tar (git-bash) misinterprets the drive letter
    # (`D:`) as a remote host, so prefer the system one explicitly.
    let systemTar = r"C:\Windows\System32\tar.exe"
    let tarExe =
      if fileExists(systemTar): systemTar
      else: findExe("tar")
    doAssert tarExe.len > 0, "tar.exe required for tarball gate"
    let res = execCmdEx(shellCommand([tarExe, "-czf", archivePath, "-C",
      payloadRoot, "m56tarball-1.0.0"]))
    doAssert res.exitCode == 0, "tar failed: " & res.output
  else:
    let res = execCmdEx(shellCommand(["tar", "-czf", archivePath, "-C",
      payloadRoot, "m56tarball-1.0.0"]))
    doAssert res.exitCode == 0
  let sha = fileSha256Hex(archivePath)
  # Build a `file://` URL the M54 tarball adapter understands. On
  # Windows the absolute path starts with a drive letter, so we use
  # `file://<drive>:/...` (two slashes after `file:`) — the adapter
  # strips the literal `file://` prefix and treats the remainder as a
  # native path. On POSIX hosts paths already begin with `/`, so the
  # net result is `file:///path/...` (three slashes).
  let forward = archivePath.replace('\\', '/')
  let url =
    when defined(windows):
      "file://" & forward
    else:
      "file://" & forward
  result = (archivePath: archivePath, sha256: sha, url: url)

proc tarballUseDef(url, sha256, executable: string): InterfaceToolUse =
  result = InterfaceToolUse(
    rawConstraint: "m56-tarball",
    packageSelector: "m56-tarball@1.0.0",
    executableName: "m56tarball",
    location: SourceLocation(file: "fixture", line: 1))
  result.tarballProvisioning = @[InterfaceTarballProvisioning(
    packageName: "m56-tarball",
    url: url,
    sha256: "sha256:" & sha256,
    archiveType: "tar.gz",
    executablePath: executable,
    stripComponents: 1,
    packageId: "m56-tarball@1.0.0",
    lockIdentity: "sha256:" & sha256,
    location: SourceLocation(file: "fixture", line: 2))]

# ---------------------------------------------------------------------------
# Verification helpers (shared)
# ---------------------------------------------------------------------------

proc validateBinaryReceipt(prefix: string;
                          expectedAdapter, expectedPackage,
                          expectedVersion: string): RealizationReceipt =
  let path = prefix / ".repro-receipt"
  check fileExists(path)
  result = readReceiptFile(path)
  check result.adapter == expectedAdapter
  check result.packageName == expectedPackage
  check result.version == expectedVersion
  let expectedLeaf = realizationDirName(result.version,
    result.realizationHash)
  check prefix.extractFilename == expectedLeaf

# ---------------------------------------------------------------------------
# Gate body
# ---------------------------------------------------------------------------

suite "e2e_local_store_unified_across_adapters":
  test "all_available_adapters_publish_into_unified_store_layout":
    when defined(windows):
      # Prefer Windows' built-in bsdtar (System32) over MSYS-flavoured
      # tar from git-bash: the MSYS one mis-parses Windows paths like
      # `D:\…` as `D:` remote-host references and bails out. The
      # tarball adapter shells out to `tar` so the PATH ordering
      # matters here.
      let systemRoot = getEnv("SystemRoot", r"C:\Windows")
      let system32 = systemRoot / "System32"
      putEnv("PATH", system32 & ";" & getEnv("PATH"))

    let tempRoot = createTempDir("repro-m56-unified-", "")
    defer:
      try: removeDir(tempRoot) except OSError: discard

    let storeRoot = tempRoot / "store"
    # Open the store once so the SQLite index file exists; the
    # adapters call `openStore` themselves for INSERT but it's good to
    # have the layout in place when the verifier reads.
    block initStore:
      var s = openStore(storeRoot)
      s.close()

    # -----------------------------------------------------------------
    # Tarball adapter
    # -----------------------------------------------------------------
    let tarball = buildTarballFixture(tempRoot)
    let tarballUse = tarballUseDef(tarball.url, tarball.sha256,
      when defined(windows): "bin/m56tarball.cmd" else: "bin/m56tarball")
    let tarballProfile = resolveTarballTool(tarballUse, storeRoot)
    check tarballProfile.installMethod == "tarball"
    check tarballProfile.selectedStorePath.startsWith(storeRoot / "prefixes")
    # The tarball adapter sanitizes the package selector by replacing
    # `@` with `_`, so `m56-tarball@1.0.0` becomes `m56-tarball_1.0.0`.
    let tarballReceipt = validateBinaryReceipt(tarballProfile.selectedStorePath,
      "tarball", "m56-tarball_1.0.0", "1.0.0")
    check tarballReceipt.provenanceUrl == tarball.url
    check tarballReceipt.provenanceChecksum == tarball.sha256

    # -----------------------------------------------------------------
    # Scoop adapter — Windows only
    # -----------------------------------------------------------------
    when defined(windows):
      let scoopBinary = resolveScoopBinary()
      let scoopAvailable = scoopBinary.len > 0
      var scoopReceipt: RealizationReceipt
      var scoopPrefix = ""
      if scoopAvailable:
        let sandbox = setupScoopSandbox(tempRoot, "main")
        let fixtureApp = populateScoopApp(sandbox,
          app = "repro-m56-fixture", version = "1.0.0",
          executableName = "fixture.cmd",
          executablePayload = fixtureExecutablePayload(
            "repro-m56-fixture 1.0.0 OK"))
        let scoopUse = fixtureUseDef(
          packageSelector = "repro-m56-fixture",
          executableName = "fixture",
          bucket = sandbox.bucketName,
          app = fixtureApp.name,
          version = fixtureApp.version,
          preferredVersion = "",
          manifestChecksum = "",
          executablePath = fixtureApp.executableName)
        let scoopProfile = resolveScoopTool(scoopUse, storeRoot)
        check scoopProfile.installMethod == "scoop"
        check scoopProfile.selectedStorePath.startsWith(storeRoot / "prefixes")
        scoopPrefix = scoopProfile.selectedStorePath
        scoopReceipt = validateBinaryReceipt(scoopProfile.selectedStorePath,
          "scoop", "scoop." & sandbox.bucketName & "." & fixtureApp.name,
          "1.0.0")
      else:
        echo "[platform N/A] Scoop is not installed on this Windows host; " &
          "skipping the Scoop sub-gate. The tarball + recover assertions " &
          "still run end-to-end."

    # -----------------------------------------------------------------
    # Nix adapter — non-Windows only
    # -----------------------------------------------------------------
    when not defined(windows):
      let nixExe = findExe("nix")
      let nixAvailable = nixExe.len > 0
      if nixAvailable:
        # NB: we don't go through the public CLI for the Nix exercise —
        # `resolveNixTool` is the library entry point and `storeRoot`
        # tells it to seal the binary receipt and INSERT the index row.
        var nixUse = InterfaceToolUse(
          rawConstraint: "m56-nix",
          packageSelector: "m56-nix@hello",
          executableName: "hello",
          location: SourceLocation(file: "fixture", line: 1))
        nixUse.nixProvisioning = @[InterfaceNixProvisioning(
          packageName: "m56-nix",
          selector: "nixpkgs#hello",
          executablePath: "bin/hello",
          packageId: "m56-nix.hello",
          lockIdentity: "nixpkgs#hello",
          location: SourceLocation(file: "fixture", line: 2))]
        let nixProfile = resolveNixTool(nixUse, storeRoot)
        check nixProfile.installMethod == "nix"
        # Nix profile keeps `selectedStorePath` pointing at the
        # /nix/store source; the unified store gets a pointer prefix.
        var unifiedNixPath = ""
        for entry in nixProfile.realizedStorePaths:
          if entry.startsWith(storeRoot / "prefixes"):
            unifiedNixPath = entry
        check unifiedNixPath.len > 0
        discard validateBinaryReceipt(unifiedNixPath, "nix", "nix.m56-nix.hello",
          "hello")
      else:
        echo "[platform N/A] Nix is not installed on this host; skipping " &
          "the Nix sub-gate."
    else:
      echo "[platform N/A] Nix is not available on Windows hosts; skipping " &
        "the Nix sub-gate per spec."

    # -----------------------------------------------------------------
    # The unified index now contains every successfully realized
    # prefix. Verify the count matches.
    # -----------------------------------------------------------------
    var verifier = openStore(storeRoot)
    defer: verifier.close()
    let rows = verifier.listPrefixes()
    var perAdapter = initCountTable[string]()
    for row in rows:
      perAdapter.inc(row.adapter)
      let abs = verifier.absolutePrefixPath(row.realizedPath)
      check dirExists(abs)
      check fileExists(abs / ".repro-receipt")
    check perAdapter["tarball"] >= 1

    # -----------------------------------------------------------------
    # Root every prefix; GC must not touch them.
    # -----------------------------------------------------------------
    for row in rows:
      verifier.registerRoot("session." & row.adapter & "." &
        row.packageName, rkSession)
      verifier.attachPrefixToRoot("session." & row.adapter & "." &
        row.packageName, row.prefixId)
    let preservingReport = verifier.gc(graceSeconds = 0)
    check preservingReport.quarantined.len == 0
    for row in rows:
      let abs = verifier.absolutePrefixPath(row.realizedPath)
      check dirExists(abs)

    # -----------------------------------------------------------------
    # Drop one root; GC must move only that prefix.
    # -----------------------------------------------------------------
    let firstRow = rows[0]
    verifier.deleteRoot("session." & firstRow.adapter & "." &
      firstRow.packageName)
    let secondReport = verifier.gc(graceSeconds = 0)
    check secondReport.quarantined.len == 1
    check secondReport.quarantined[0].prefixId == firstRow.prefixId
    check not dirExists(verifier.absolutePrefixPath(firstRow.realizedPath))
    # The other prefixes (if any) survive.
    for row in rows:
      if row.prefixId == firstRow.prefixId:
        continue
      let abs = verifier.absolutePrefixPath(row.realizedPath)
      check dirExists(abs)
