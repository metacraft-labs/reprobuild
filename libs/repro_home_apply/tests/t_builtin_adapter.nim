## M64 — home archive realizer (`builtin_adapter`) unit tests.
##
## All tests are HERMETIC: artifacts are served from `file://` URLs
## pointing at fixtures the test materializes on disk, so no network
## traffic touches CI.  An optional integration test that hits the
## live Adoptium JDK URL can live separately (and is gated behind
## the `REPRO_M64_LIVE_DOWNLOAD` env var) — this file does not run
## it.
##
## Coverage:
##   1. Tarball selection feeding the realizer (GM4b): default (first
##      declared) + explicit version + miss + no record
##   2. realizeBuiltinPackage() with imExtract + afRaw on a synthetic
##      file:// URL — verifies the realized prefix carries the
##      declared binary and the env bindings are substituted.
##   3. Cache-hit: a second realize against the same inputs returns
##      cacheHit=true without re-fetching.
##   4. SHA-256 mismatch fails closed with `EBuiltinDigestMismatch`;
##      no prefix is written.
##   5. Zip extraction with extract_path flatten — requires a host
##      zip tool (unzip or PowerShell). Skipped on
##      hosts without one.
##   6. Installer mode: mocked via `REPRO_TEST_BUILTIN_INSTALLER_MOCK`
##      so the test does not exec a real installer; asserts the argv
##      composition (NSIS-style `/S /D=<dir>`).
##   7. The realized prefix's receipt records the archive realizer
##      (`BuiltinAdapterName`) and populated digest/url fields.
##
## GM4b: resolutions are synthetic `tarball` records selected by
## `selectRealization` and projected by `archiveRealizationOf` (see the
## helpers below); the `VersionedProvisioning` catalogs they replaced
## are gone.

import std/[os, osproc, strutils, tables, unittest]
import repro_test_support/reasoned_skip
from repro_core/paths import extendedPath

import repro_local_store
import repro_dsl_stdlib/packages_schema
import repro_interface_artifacts

import repro_home_apply/package_catalog
import repro_home_apply/builtin_adapter
import repro_home_apply/realize
from repro_test_support import testCaseScratchSlug

let FixtureRoot = "build/test-tmp/t-builtin-adapter" / testCaseScratchSlug()

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc resetDir(path: string) =
  if dirExists(extendedPath(path)):
    removeDir(extendedPath(path))
  createDir(extendedPath(path))

proc fileToUrl(absPath: string): string =
  ## Produce a portable `file://` URL for an absolute on-disk path. On
  ## Windows the convention is `file:///C:/...` (the leading triple
  ## slash + drive letter). On POSIX it is `file:///path`.
  let normalized = absPath.replace('\\', '/')
  when defined(windows):
    if normalized.len >= 2 and normalized[1] == ':':
      "file:///" & normalized
    else:
      "file://" & normalized
  else:
    "file://" & normalized

proc sha256OfBytes(bytes: openArray[byte]): string =
  ## Shell out to the same sha256 tool the adapter does. We write the
  ## payload to a tempfile and reuse `fileShaHex`.
  let tmpDir = FixtureRoot / "sha-tmp"
  createDir(extendedPath(tmpDir))
  let tmpPath = tmpDir / "sha-input.bin"
  var raw = newString(bytes.len)
  for i, b in bytes:
    raw[i] = char(b)
  writeFile(extendedPath(tmpPath), raw)
  let h = fileShaHex(tmpPath, "sha256")
  removeFile(extendedPath(tmpPath))
  h

proc writePayloadFile(path: string; content: string): string =
  ## Write `content` to `path` and return its SHA-256 hex.
  createDir(extendedPath(parentDir(path)))
  writeFile(extendedPath(path), content)
  fileShaHex(path, "sha256")

# ---------------------------------------------------------------------------
# GM4b: an archive realization is a `tarball` record of a package definition
# (Provisioning-Contributions.md §"Profile Package References"). A test
# realization is a synthetic record for this host, SELECTED by the same
# `selectRealization` a profile reference goes through and projected by
# `archiveRealizationOf` into the archive realizer's input — so the realizer
# is driven exactly as `repro home apply` drives it.
# ---------------------------------------------------------------------------

proc hostRecord(url, archiveType, executablePath: string;
                extraExecutables: seq[string] = @[];
                sha256 = ""; sha1 = ""; version = "1.0.0";
                installMethod = ""; extractPath = "";
                installerArgs: seq[string] = @[];
                pacmanPackages: seq[string] = @[];
                env: seq[string] = @[]; nested7z = false;
                msiAdminInstall = false;
                preInstall: seq[string] = @[];
                preInstallUnrecognized: seq[string] = @[];
                launcherEmit: seq[string] = @[];
                anyCpu = false): InterfaceTarballProvisioning =
  ## A synthetic `tarball` record for this host's (cpu, os); ``anyCpu``
  ## leaves the cpu open, as a record for every CPU family does.
  let host = hostRealizationTarget()
  result = InterfaceTarballProvisioning(url: url, sha256: sha256,
    archiveType: archiveType, executablePath: executablePath,
    cpu: (if anyCpu: "" else: $host.platform.family), os: $host.os)
  result.detail.version = version
  result.detail.sha1 = sha1
  result.detail.installMethod = installMethod
  result.detail.extractPath = extractPath
  result.detail.extraExecutables = extraExecutables
  result.detail.installerArgs = installerArgs
  result.detail.pacmanPackages = pacmanPackages
  result.detail.env = env
  result.detail.nested7z = nested7z
  result.detail.msiAdminInstall = msiAdminInstall
  result.detail.preInstall = preInstall
  result.detail.preInstallUnrecognized = preInstallUnrecognized
  result.detail.launcherEmit = launcherEmit

proc selectArchive(packageId: string;
                   records: openArray[InterfaceTarballProvisioning];
                   version = ""): ArchiveRealization =
  ## Select among ``records`` for this host (policy ``[tarball]``) and
  ## project the selection into the archive realizer's input.
  var useDef = InterfaceToolUse(rawConstraint: packageId,
    packageSelector: packageId, executableName: packageId)
  useDef.tarballProvisioning = @records
  let selection = selectRealization(useDef, SelectionRequest(
    packageName: packageId, target: hostRealizationTarget(),
    policy: @[rkTarball], version: version, definitionKnown: true))
  archiveRealizationOf(packageId, selection.tarball)

proc rawRecord(version, url, sha256: string;
               binRelpath: seq[string] = @["bin/tool"]):
    InterfaceTarballProvisioning =
  hostRecord(url, "raw", binRelpath[0], binRelpath[1 .. ^1],
    sha256 = sha256, version = version,
    env = @["TOOL_BIN=${prefix}/bin/tool", "TOOL_HOME=${prefix}"])

proc rawRecordSha1(version, url, sha1: string;
                   binRelpath: seq[string] = @["bin/tool"]):
    InterfaceTarballProvisioning =
  ## Mirrors ``rawRecord`` but pins the archive by ``sha1``. Used by the
  ## M1 test that exercises the sha1 verification path.
  hostRecord(url, "raw", binRelpath[0], binRelpath[1 .. ^1],
    sha1 = sha1, version = version,
    env = @["TOOL_BIN=${prefix}/bin/tool", "TOOL_HOME=${prefix}"])

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

suite "M64 — home archive realizer":

  test "tarball selection: default version + explicit version + miss":
    let fixtureDir = FixtureRoot / "resolve"
    resetDir(fixtureDir)
    let payload = "v2-payload"
    let payloadPath = fixtureDir / "tool-2.0.0.bin"
    let sha = writePayloadFile(payloadPath, payload)
    let url = fileToUrl(absolutePath(payloadPath))

    let records = @[
      rawRecord("2.0.0", url, sha),
      rawRecord("1.0.0", url, sha),
    ]

    # Default: the FIRST eligible record in declaration order (2.0.0) —
    # GM4b's rule (a package lists its default version first).
    let defRes = selectArchive("tool", records)
    check defRes.builtinVersion == "2.0.0"
    check defRes.urlUsed == url
    check defRes.digestAlgorithm == "sha256"
    check defRes.digestValue == sha
    check defRes.archiveFormat == afRaw

    # Explicit: 1.0.0 must resolve to the second record.
    let explicit = selectArchive("tool", records, version = "1.0.0")
    check explicit.builtinVersion == "1.0.0"

    # Version miss: a structured missing-realization error naming the
    # version and the versions offered; no resolution.
    var missMsg = ""
    try:
      discard selectArchive("tool", records, version = "9.9.9")
    except EMissingRealization as err:
      missMsg = err.msg
    check "9.9.9" in missMsg
    check "2.0.0" in missMsg and "1.0.0" in missMsg

    # No record at all: structured error too.
    var emptyMsg = ""
    try:
      discard selectArchive("tool", newSeq[InterfaceTarballProvisioning]())
    except EMissingRealization as err:
      emptyMsg = err.msg
    check "no tarball realization declared" in emptyMsg

  test "realizeBuiltinPackage: imExtract + afRaw materializes the prefix":
    let fixtureDir = FixtureRoot / "raw-realize"
    let storeDir = fixtureDir / "store"
    let payloadDir = fixtureDir / "payload"
    resetDir(fixtureDir)
    resetDir(storeDir)
    resetDir(payloadDir)
    let payload = "raw-tool-bytes-v1"
    let payloadPath = payloadDir / "tool.bin"
    let sha = writePayloadFile(payloadPath, payload)
    let url = fileToUrl(absolutePath(payloadPath))
    let records = @[rawRecord("1.0.0", url, sha,
      binRelpath = @["bin/tool"])]
    let res = selectArchive("tool", records)

    var store = openStore(storeDir)
    defer: store.close()

    let out1 = realizeBuiltinPackage(store, res)
    check (not out1.cacheHit)
    check out1.prefixAbsolutePath.len > 0
    check dirExists(extendedPath(out1.prefixAbsolutePath))
    # The afRaw install path places the payload at bin_relpath[0].
    let realizedBin = out1.prefixAbsolutePath / "bin" / "tool"
    check fileExists(extendedPath(realizedBin))
    # Content fidelity: the realized bin equals the source payload.
    check readFile(extendedPath(realizedBin)) == payload
    # Env substitution: `${prefix}` is replaced with the prefix abs.
    var envMap = initTable[string, string]()
    for b in out1.envBindings: envMap[b.name] = b.value
    check envMap["TOOL_HOME"] == out1.prefixAbsolutePath
    check envMap["TOOL_BIN"] ==
      out1.prefixAbsolutePath & "/bin/tool"
    # The receipt's recorded digest matches.
    check out1.digestAlgorithm == "sha256"
    check out1.digestValue == sha
    check out1.urlUsed == url

  test "realizeBuiltinPackage: second realize is a cache-hit":
    let fixtureDir = FixtureRoot / "cache-hit"
    let storeDir = fixtureDir / "store"
    let payloadDir = fixtureDir / "payload"
    resetDir(fixtureDir)
    resetDir(storeDir)
    resetDir(payloadDir)
    let payload = "cache-tool-bytes"
    let payloadPath = payloadDir / "tool.bin"
    let sha = writePayloadFile(payloadPath, payload)
    let url = fileToUrl(absolutePath(payloadPath))
    let records = @[rawRecord("3.0.0", url, sha)]
    let res = selectArchive("tool", records)

    var store = openStore(storeDir)
    defer: store.close()

    let out1 = realizeBuiltinPackage(store, res)
    check (not out1.cacheHit)
    # Wipe the source payload so a second download would FAIL — the
    # cache-hit must skip the download entirely.
    removeFile(extendedPath(payloadPath))
    let out2 = realizeBuiltinPackage(store, res)
    check out2.cacheHit
    check out2.prefixId == out1.prefixId
    check out2.prefixAbsolutePath == out1.prefixAbsolutePath

  test "realizeBuiltinPackage: SHA-256 mismatch fails closed; no prefix":
    let fixtureDir = FixtureRoot / "sha-mismatch"
    let storeDir = fixtureDir / "store"
    let payloadDir = fixtureDir / "payload"
    resetDir(fixtureDir)
    resetDir(storeDir)
    resetDir(payloadDir)
    let payload = "real-bytes"
    let payloadPath = payloadDir / "tool.bin"
    discard writePayloadFile(payloadPath, payload)
    let url = fileToUrl(absolutePath(payloadPath))
    # Declare a digest that does NOT match the payload.
    let wrong = "deadbeef".repeat(8)  # 64 hex chars
    let records = @[rawRecord("1.0.0", url, wrong)]
    let res = selectArchive("tool", records)

    var store = openStore(storeDir)
    defer: store.close()

    var raised = false
    var expected = ""
    var observed = ""
    try:
      discard realizeBuiltinPackage(store, res)
    except EBuiltinDigestMismatch as err:
      raised = true
      expected = err.expectedDigest
      observed = err.observedDigest
    check raised
    check expected == wrong
    # The observed digest must be a 64-char hex string (the real one).
    check observed.len == 64
    check expected != observed
    # No prefix landed.
    let prefixesDir = storeDir / "prefixes"
    var anyPrefix = false
    if dirExists(extendedPath(prefixesDir)):
      for kind, p in walkDir(extendedPath(prefixesDir)):
        if kind in {pcDir, pcLinkToDir}:
          for vk, vp in walkDir(extendedPath(p)):
            if vk in {pcDir, pcLinkToDir}:
              anyPrefix = true
    check (not anyPrefix)

  test "realizeBuiltinPackage: zip extraction + extract_path flatten":
    # Build a real .zip on disk, drive the adapter through afZip
    # imExtract with an inner-dir flatten, then assert the realized
    # prefix carries the inner-dir contents directly.
    #
    # Skipped when no zip producer is on PATH (POSIX `zip` or
    # PowerShell's Compress-Archive). Both are available on the M64
    # CI matrix.
    let fixtureDir = FixtureRoot / "zip-flatten"
    let storeDir = fixtureDir / "store"
    let stagingDir = fixtureDir / "staging"
    resetDir(fixtureDir)
    resetDir(storeDir)
    resetDir(stagingDir)

    # Lay out the inner dir the archive will ship:
    #   stagingDir / tool-1.0.0 / bin / tool.cmd
    #   stagingDir / tool-1.0.0 / lib / runtime.txt
    let innerDir = stagingDir / "tool-1.0.0"
    createDir(extendedPath(innerDir / "bin"))
    createDir(extendedPath(innerDir / "lib"))
    writeFile(extendedPath(innerDir / "bin" / "tool.cmd"),
      "@echo hello from tool\n")
    writeFile(extendedPath(innerDir / "lib" / "runtime.txt"),
      "runtime-marker\n")

    # Produce the zip. Prefer `zip` (POSIX) then PowerShell.
    let zipPath = fixtureDir / "tool-1.0.0.zip"
    let posixZip = findExe("zip")
    var zipped = false
    if posixZip.len > 0:
      let cmd = quoteShell(posixZip) & " -q -r " & quoteShell(zipPath) &
        " " & quoteShell("tool-1.0.0")
      let res = execCmdEx(cmd, workingDir = stagingDir)
      zipped = res.exitCode == 0
    if not zipped:
      when defined(windows):
        let pwsh = findExe("powershell")
        if pwsh.len > 0:
          # Use absolute paths and -Force; Compress-Archive will create
          # the zip carrying the literal subdir name.
          let ps = "Compress-Archive -Path " &
            quoteShell(absolutePath(innerDir)) & " -DestinationPath " &
            quoteShell(absolutePath(zipPath)) & " -Force"
          let cmd = quoteShell(pwsh) &
            " -NoProfile -ExecutionPolicy Bypass -Command " & quoteShell(ps)
          let res = execCmdEx(cmd)
          zipped = res.exitCode == 0
    if not zipped:
      echo "  [skip] no zip producer on PATH; skipping afZip test"
      skip("no zip producer on PATH (neither `zip` nor PowerShell Compress-Archive)")
    else:
      let sha = fileShaHex(zipPath, "sha256")
      let url = fileToUrl(absolutePath(zipPath))
      let res = selectArchive("tool", [hostRecord(url, "zip",
        "bin/tool.cmd", @["lib/runtime.txt"], sha256 = sha,
        extractPath = "tool-1.0.0")])

      var store = openStore(storeDir)
      defer: store.close()

      let outR = realizeBuiltinPackage(store, res)
      check (not outR.cacheHit)
      # The flatten removed the `tool-1.0.0/` prefix.
      let bin = outR.prefixAbsolutePath / "bin" / "tool.cmd"
      let lib = outR.prefixAbsolutePath / "lib" / "runtime.txt"
      check fileExists(extendedPath(bin))
      check fileExists(extendedPath(lib))
      check readFile(extendedPath(lib)).contains("runtime-marker")

  test "realizeBuiltinPackage: 7z extraction + extract_path flatten":
    # M64 step 12: build a real .7z archive on disk via the `7z`
    # CLI, drive the adapter through afSevenZip imExtract with an
    # inner-dir flatten, and assert the realized prefix carries the
    # inner-dir contents directly.
    #
    # Skipped when no `7z` binary is on PATH. On the M69 Hyper-V
    # harness the Scoop bootstrap installs `7zip`, satisfying this.
    let fixtureDir = FixtureRoot / "seven-zip-flatten"
    let storeDir = fixtureDir / "store"
    let stagingDir = fixtureDir / "staging"
    resetDir(fixtureDir)
    resetDir(storeDir)
    resetDir(stagingDir)

    let sevenZip = findExe("7z")
    if sevenZip.len == 0:
      echo "  [skip] no 7z binary on PATH; skipping afSevenZip test"
      skip("7z not on PATH")
    else:
      # Lay out the inner dir the archive will ship:
      #   stagingDir / tool-1.0.0 / bin / tool.cmd
      #   stagingDir / tool-1.0.0 / lib / runtime.txt
      let innerDir = stagingDir / "tool-1.0.0"
      createDir(extendedPath(innerDir / "bin"))
      createDir(extendedPath(innerDir / "lib"))
      writeFile(extendedPath(innerDir / "bin" / "tool.cmd"),
        "@echo hello from 7z tool\n")
      writeFile(extendedPath(innerDir / "lib" / "runtime.txt"),
        "seven-zip-runtime-marker\n")

      # Produce the .7z archive. Use `7z a` to add the inner dir
      # tree; -bsp0/-bso0 suppress chatty progress + status lines.
      let archivePath = fixtureDir / "tool-1.0.0.7z"
      let addCmd = quoteShell(sevenZip) & " a -t7z " &
        quoteShell(absolutePath(archivePath)) & " " &
        quoteShell("tool-1.0.0") & " -y -bsp0 -bso0"
      let addRes = execCmdEx(addCmd, workingDir = stagingDir)
      check addRes.exitCode == 0
      check fileExists(extendedPath(archivePath))

      let sha = fileShaHex(archivePath, "sha256")
      let url = fileToUrl(absolutePath(archivePath))
      let res = selectArchive("tool-7z", [hostRecord(url, "7z",
        "bin/tool.cmd", @["lib/runtime.txt"], sha256 = sha,
        extractPath = "tool-1.0.0")])

      var store = openStore(storeDir)
      defer: store.close()

      let outR = realizeBuiltinPackage(store, res)
      check (not outR.cacheHit)
      # The flatten removed the `tool-1.0.0/` prefix.
      let bin = outR.prefixAbsolutePath / "bin" / "tool.cmd"
      let lib = outR.prefixAbsolutePath / "lib" / "runtime.txt"
      check fileExists(extendedPath(bin))
      check fileExists(extendedPath(lib))
      check readFile(extendedPath(lib)).contains("seven-zip-runtime-marker")
      check outR.archiveFormat == afSevenZip

  test "realizeBuiltinPackage: installer mode captures argv via mock":
    # Mock the installer invocation so the test is hermetic. The
    # adapter writes the recorded argv into `$REPRO_TEST_BUILTIN_INSTALLER_MOCK`
    # and synthesizes the install_dir on disk; we assert the argv
    # composition + that the staged tree contains the declared bin.
    let fixtureDir = FixtureRoot / "installer-mock"
    let storeDir = fixtureDir / "store"
    let payloadDir = fixtureDir / "payload"
    resetDir(fixtureDir)
    resetDir(storeDir)
    resetDir(payloadDir)
    # The fake "installer" is a stub file — the mock dispatch never
    # executes it, only records the argv that would have run.
    let installerPath = payloadDir / "fake-installer.exe"
    let installerSha = writePayloadFile(installerPath,
      "fake-installer-bytes")
    let url = fileToUrl(absolutePath(installerPath))
    # The bin_relpath must point at a file the mock places under the
    # install dir. We use a tiny post-install hook: after the mock
    # writes the argv, the test creates the expected bin so the
    # post-extraction `bin_relpath` check passes.
    #
    # We do this by registering a custom mock that ALSO writes the bin
    # — but the adapter's mock path only ensures destDir exists. So
    # we use a two-step approach: realize INSIDE a wrapper that
    # post-populates the staging directory before validation runs.
    #
    # Simpler: declare an empty `bin_relpath` so the validation loop
    # is a no-op. The schema requires at least one entry for
    # imExtract; for imInstallerSilent the schema requires
    # installer_args, not bin_relpath, so an empty bin_relpath is
    # valid. We still set executableName via packageId.
    let argvCapture = fixtureDir / "argv.txt"
    putEnv(BuiltinTestInstallerMockEnvVar, argvCapture)
    defer: delEnv(BuiltinTestInstallerMockEnvVar)

    var res = selectArchive("tool-with-installer", [hostRecord(url,
      "installer-nsis", "tool.exe", sha256 = installerSha,
      installMethod = "installer-silent", installerArgs = @["/S"])])
    # The mock installer lays down no files, so this case realizes with
    # no exported executable (what an installer-only record with an empty
    # `bin_relpath` meant before GM4b); a `tarball` record always names
    # one, so the projection's list is cleared here.
    res.binRelpath = @[]

    var store = openStore(storeDir)
    defer: store.close()

    let outR = realizeBuiltinPackage(store, res)
    check (not outR.cacheHit)
    check outR.installerArgvUsed.len >= 3  # installer + /S + /D=<dir>
    check outR.installerArgvUsed[0] == absolutePath(installerPath) or
      outR.installerArgvUsed[0].endsWith("fake-installer.exe") or
      outR.installerArgvUsed[0].contains("artifact.")
        # The download is staged into a CAS-tmp dir; the adapter
        # invokes the staged copy, not the source. We accept any of
        # these for robustness.
    check outR.installerArgvUsed.contains("/S")
    var sawDFlag = false
    for a in outR.installerArgvUsed:
      if a.startsWith("/D="):
        sawDFlag = true
    check sawDFlag
    # The capture file recorded the argv.
    check fileExists(extendedPath(argvCapture))
    let argvFile = readFile(extendedPath(argvCapture))
    check argvFile.contains("/S")
    check argvFile.contains("/D=")

  test "archive realizer: realized prefix carries the dispatch fields":
    # End-to-end from a selected record: the realizer's outcome carries
    # url/digest/format and its receipt names the archive realizer.
    let fixtureDir = FixtureRoot / "dispatch"
    let storeDir = fixtureDir / "store"
    let payloadDir = fixtureDir / "payload"
    resetDir(fixtureDir)
    resetDir(storeDir)
    resetDir(payloadDir)
    let payloadPath = payloadDir / "tool.bin"
    let sha = writePayloadFile(payloadPath, "dispatch-bytes")
    let url = fileToUrl(absolutePath(payloadPath))
    let records = @[rawRecord("4.0.0", url, sha,
      binRelpath = @["bin/tool"])]
    let res = selectArchive("dispatch-tool", records)

    var store = openStore(storeDir)
    defer: store.close()

    # `realizeBuiltinPackage` is the entry point realize.nim's
    # `realizeBuiltinAdapter` calls for an installer-route selection.
    let outR = realizeBuiltinPackage(store, res)
    check (not outR.cacheHit)
    check outR.urlUsed == url
    check outR.digestAlgorithm == "sha256"
    check outR.digestValue == sha
    check outR.archiveFormat == afRaw
    check outR.resolvedExecutablePath ==
      outR.prefixAbsolutePath / "bin" / "tool"
    # The realized prefix's receipt records adapter == BuiltinAdapterName.
    let receiptPath = outR.prefixAbsolutePath / ".repro-receipt"
    check fileExists(extendedPath(receiptPath))
    let receipt = readReceiptFile(receiptPath)
    check receipt.adapter == BuiltinAdapterName
    check receipt.packageName == "dispatch-tool"
    check receipt.version == "4.0.0"
    check receipt.provenanceUrl == url
    check receipt.provenanceChecksum == "sha256:" & sha

  # ===========================================================================
  # M1 (Realize-Closure spec) — sha1 weak-hash realize path.
  # ===========================================================================

  test "test_m1_realize_accepts_sha1_digest":
    ## Hermetic file:// realize against a fixture whose sha1 digest is
    ## the record's declared hash. The realize loop verifies via sha1
    ## and the prefix lands successfully. Mirrors the SHA-256 happy-
    ## path test up-suite.
    let fixtureDir = FixtureRoot / "sha1-realize"
    let storeDir = fixtureDir / "store"
    let payloadDir = fixtureDir / "payload"
    resetDir(fixtureDir)
    resetDir(storeDir)
    resetDir(payloadDir)
    let payload = "sha1-tool-bytes-v1"
    let payloadPath = payloadDir / "tool.bin"
    createDir(extendedPath(parentDir(payloadPath)))
    writeFile(extendedPath(payloadPath), payload)
    # Use the adapter's own fileShaHex(sha1) to compute the truth
    # digest — exercises the M1 sha1sum / certutil dispatch end-to-end.
    let sha1 = fileShaHex(payloadPath, "sha1")
    check sha1.len == 40
    let url = fileToUrl(absolutePath(payloadPath))
    let records = @[rawRecordSha1("1.0.0", url, sha1,
      binRelpath = @["bin/tool"])]
    let res = selectArchive("sha1-tool", records)
    check res.digestAlgorithm == "sha1"
    check res.digestValue == sha1

    var store = openStore(storeDir)
    defer: store.close()

    let outR = realizeBuiltinPackage(store, res)
    check (not outR.cacheHit)
    check outR.digestAlgorithm == "sha1"
    check outR.digestValue == sha1
    # The realized prefix carries the payload at bin_relpath[0].
    let realizedBin = outR.prefixAbsolutePath / "bin" / "tool"
    check fileExists(extendedPath(realizedBin))
    check readFile(extendedPath(realizedBin)) == payload

  test "test_m1_realize_sha1_mismatch_fails_closed":
    ## A 1-byte-mutated fixture must fail closed with the same error
    ## shape sha256-mismatch produces (``EBuiltinDigestMismatch``).
    let fixtureDir = FixtureRoot / "sha1-mismatch"
    let storeDir = fixtureDir / "store"
    let payloadDir = fixtureDir / "payload"
    resetDir(fixtureDir)
    resetDir(storeDir)
    resetDir(payloadDir)
    let payload = "real-bytes"
    let payloadPath = payloadDir / "tool.bin"
    createDir(extendedPath(parentDir(payloadPath)))
    writeFile(extendedPath(payloadPath), payload)
    let url = fileToUrl(absolutePath(payloadPath))
    # Declare a sha1 digest that does NOT match the payload.
    let wrong = "deadbeef".repeat(5)  # 40 hex chars
    let records = @[rawRecordSha1("1.0.0", url, wrong)]
    let res = selectArchive("sha1-tool", records)
    check res.digestAlgorithm == "sha1"

    var store = openStore(storeDir)
    defer: store.close()

    var raised = false
    var expected = ""
    var observed = ""
    var expectedAlgo = ""
    try:
      discard realizeBuiltinPackage(store, res)
    except EBuiltinDigestMismatch as err:
      raised = true
      expected = err.expectedDigest
      observed = err.observedDigest
      expectedAlgo = err.expectedAlgorithm
    check raised
    check expected == wrong
    check expectedAlgo == "sha1"
    check observed.len == 40
    check expected != observed
