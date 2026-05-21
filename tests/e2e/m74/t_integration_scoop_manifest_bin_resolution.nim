## M74 Verification Gate: integration_scoop_manifest_bin_resolution
##
## The Scoop adapter resolves a realized app's executable path(s) from
## the app's Scoop manifest `bin` field rather than assuming a fixed
## `bin/` on-disk layout. Discovered when the M70 real-host migration
## failed realizing `gh`: `gh`'s executable is at
## `<versionDir>/bin/gh.exe`, but the adapter assumed `<versionDir>/`.
##
## Per the M74 verification block, four fixture Scoop apps:
##
##   1. `bin` declared as a `bin\<exe>` SUBDIRECTORY path — the
##      executable-presence check and the launcher resolve
##      `<versionDir>/bin/<exe>` (the `gh` shape that broke M70).
##   2. `bin` declared at the version ROOT — also realizes (the M55
##      fixture shape; proves the manifest-driven path is not a blind
##      replacement of `bin/` with `versionRoot`).
##   3. `bin` declared as an ARRAY that includes the `[path, alias,
##      args]` form — every declared executable resolves.
##   4. `bin` declares a file that is GENUINELY ABSENT on disk — still
##      fails with a structured `EScoopInstallFailed` naming the
##      expected path (the check stays strict, it is now correct).
##
## The adapter is exercised through the real `resolveScoopTool` entry
## point against a sandboxed Scoop root (the M55 sandboxed-Scoop
## fixture pattern). The launcher consumes `profile.resolvedExecutablePath`
## directly (`materialize_launchers.nim:buildLaunchPlan` sets
## `LaunchPlan.executablePath = rec.resolvedExecutablePath`), so a
## strong assertion on that field is a strong assertion on the launcher.

when not defined(windows):
  {.warning[UnreachableCode]: off.}
  echo "[platform N/A] integration_scoop_manifest_bin_resolution: " &
    "this gate requires Windows and a real Scoop install"
  quit(0)

import std/[json, os, strutils, tempfiles, unittest]

import repro_tool_profiles

import ../scoop/scoop_sandbox

# ---------------------------------------------------------------------------
# M74 fixture helper: a Scoop app whose ON-DISK executable layout and
# whose manifest `bin` field are chosen independently, so the gate can
# stage realistic apps (exe in `bin/`, exe at the version root, an exe
# the manifest declares but does not place on disk).
# ---------------------------------------------------------------------------

type
  ManifestBinFixture = object
    name: string
    version: string
    versionDir: string
    bucketManifestPath: string

proc writeFixtureExe(path, marker: string) =
  ## A byte-stable Windows batch fixture that prints `marker` on
  ## `--version`. `.cmd` extension so the launch wrapper resolves it
  ## without a real PE; identical pattern to the M55 fixtures.
  createDir(path.parentDir)
  writeFile(path,
    "@echo off\r\n" &
    "if /I \"%1\"==\"--version\" ( echo " & marker & " & exit /b 0 )\r\n" &
    "echo " & marker & " args=%*\r\n" &
    "exit /b 0\r\n")

proc stageManifestBinApp(sandbox: ScoopSandbox; app, version: string;
                         binField: JsonNode;
                         exesOnDisk: seq[string]): ManifestBinFixture =
  ## Stage an already-installed Scoop app under the sandboxed root.
  ##   * `binField`     — the JSON value written verbatim as the
  ##                      manifest `bin` field (string / array / array
  ##                      with `[path, alias, args]` entries).
  ##   * `exesOnDisk`   — the version-dir-relative paths at which a real
  ##                      fixture executable is actually placed. Leave a
  ##                      `bin` entry OUT of this list to simulate a
  ##                      manifest that declares an executable the
  ##                      install did not produce.
  ## Scoop copies the bucket manifest into `<versionDir>/manifest.json`
  ## on install; this fixture writes BOTH the bucket manifest and the
  ## version-dir copy with the same `bin` field, mirroring real Scoop.
  let versionDir = sandbox.appsDir / app / version
  createDir(versionDir)
  for rel in exesOnDisk:
    writeFixtureExe(versionDir / rel.replace('/', DirSep).replace('\\', DirSep),
      app & " " & version)
  let installJson = %*{"architecture": "64bit", "bucket": sandbox.bucketName}
  writeFile(versionDir / "install.json", installJson.pretty())
  let manifest = %*{
    "version": version,
    "description": "Reprobuild M74 manifest-bin fixture",
    "bin": binField}
  writeFile(versionDir / "manifest.json", manifest.pretty())
  let bucketManifestPath = sandbox.bucketManifestDir / (app & ".json")
  createDir(bucketManifestPath.parentDir)
  writeFile(bucketManifestPath, manifest.pretty())
  ManifestBinFixture(name: app, version: version, versionDir: versionDir,
    bucketManifestPath: bucketManifestPath)

suite "integration_scoop_manifest_bin_resolution":
  test "integration_scoop_manifest_bin_resolution":
    let scoopBinary = resolveScoopBinary()
    if scoopBinary.len == 0:
      raise newException(OSError,
        "M74 gate requires a real scoop binary on PATH (none found). " &
        "Install Scoop from https://scoop.sh/ before running this test.")

    let tempRoot = createTempDir("repro-m74-manifest-bin-", "")
    defer: safeRemoveTempRoot(tempRoot)
    let sandbox = setupScoopSandbox(tempRoot, "main")
    let storeRoot = tempRoot / "tool-store"

    # -----------------------------------------------------------------
    # Case 1: `bin` as a `bin\<exe>` SUBDIRECTORY path (the `gh` shape).
    # The adapter must resolve `<versionDir>/bin/<exe>`, not
    # `<versionDir>/<exe>`.
    # -----------------------------------------------------------------
    block subdirBin:
      let fixture = stageManifestBinApp(sandbox,
        app = "m74-subdir-app", version = "2.0.0",
        binField = %"bin\\m74cli.cmd",
        exesOnDisk = @["bin/m74cli.cmd"])
      let useDef = fixtureUseDef(
        packageSelector = "m74-subdir",
        executableName = "m74cli",
        bucket = sandbox.bucketName,
        app = fixture.name,
        version = fixture.version,
        preferredVersion = "",
        manifestChecksum = "",
        # The package-declared executable path is the bare leaf — the
        # OLD behavior would resolve `<prefix>/bin/m74cli.cmd` (the
        # version root) and fail. The manifest `bin` is authoritative.
        executablePath = "m74cli.cmd",
        requiresExecutionProfileChecksum = true)

      let profile = resolveScoopTool(useDef, storeRoot)

      # The realized executable resolves through the junction to the
      # real `<versionDir>/bin/m74cli.cmd`.
      let expected = profile.selectedStorePath / "bin" / "bin" / "m74cli.cmd"
      check profile.resolvedExecutablePath == expected
      check fileExists(profile.resolvedExecutablePath)
      check sameFile(profile.resolvedExecutablePath,
        fixture.versionDir / "bin" / "m74cli.cmd")
      # The launcher consumes `resolvedExecutablePath` verbatim — assert
      # it points into the manifest-declared `bin\` subdir.
      check profile.resolvedExecutablePath.replace('\\', '/')
        .endsWith("/bin/m74cli.cmd")
      # `declaredExecutablePath` records the manifest-resolved path
      # (relative to the version dir / junction), NOT the bare leaf.
      check profile.declaredExecutablePath.replace('\\', '/') ==
        "bin/m74cli.cmd"

      # The receipt records the manifest-resolved path and the full
      # manifest `bin` list.
      let receipt = parseFile(
        profile.selectedStorePath / ".repro-receipt.json")
      check receipt{"declaredExecutablePath"}.getStr().replace('\\', '/') ==
        "bin/m74cli.cmd"
      check receipt{"manifestBin"}.kind == JArray
      check receipt{"manifestBin"}.len == 1
      check receipt{"manifestBin"}[0].getStr().replace('\\', '/') ==
        "bin/m74cli.cmd"

      # The executable actually runs through the typed launch wrapper.
      let launched = launchScoopExecutable(profile.selectedStorePath,
        ["--version"])
      check launched.exitCode == 0
      check launched.output.contains("m74-subdir-app 2.0.0")

    # -----------------------------------------------------------------
    # Case 2: `bin` at the version ROOT — also realizes. This proves
    # the fix is manifest-driven, not a blind swap of `bin/` for the
    # version root.
    # -----------------------------------------------------------------
    block rootBin:
      let fixture = stageManifestBinApp(sandbox,
        app = "m74-root-app", version = "1.5.0",
        binField = %"m74root.cmd",
        exesOnDisk = @["m74root.cmd"])
      let useDef = fixtureUseDef(
        packageSelector = "m74-root",
        executableName = "m74root",
        bucket = sandbox.bucketName,
        app = fixture.name,
        version = fixture.version,
        preferredVersion = "",
        manifestChecksum = "",
        executablePath = "m74root.cmd",
        requiresExecutionProfileChecksum = true)

      let profile = resolveScoopTool(useDef, storeRoot)
      let expected = profile.selectedStorePath / "bin" / "m74root.cmd"
      check profile.resolvedExecutablePath == expected
      check fileExists(profile.resolvedExecutablePath)
      check sameFile(profile.resolvedExecutablePath,
        fixture.versionDir / "m74root.cmd")
      check profile.declaredExecutablePath == "m74root.cmd"

      let launched = launchScoopExecutable(profile.selectedStorePath,
        ["--version"])
      check launched.exitCode == 0
      check launched.output.contains("m74-root-app 1.5.0")

    # -----------------------------------------------------------------
    # Case 3: `bin` as an ARRAY mixing a plain string and a
    # `[path, alias, args]` entry — every declared executable resolves.
    # -----------------------------------------------------------------
    block arrayBin:
      let binArray = %* [
        "tool-a.cmd",
        ["bin\\tool-b.cmd", "tb", "--quiet"]]
      let fixture = stageManifestBinApp(sandbox,
        app = "m74-array-app", version = "3.1.0",
        binField = binArray,
        exesOnDisk = @["tool-a.cmd", "bin/tool-b.cmd"])
      let useDef = fixtureUseDef(
        packageSelector = "m74-array",
        executableName = "tool-a",
        bucket = sandbox.bucketName,
        app = fixture.name,
        version = fixture.version,
        preferredVersion = "",
        manifestChecksum = "",
        executablePath = "tool-a.cmd",
        requiresExecutionProfileChecksum = true)

      let profile = resolveScoopTool(useDef, storeRoot)
      # The realize step's presence check walked EVERY declared `bin`
      # entry — a missing one of them would have raised. Both files
      # actually exist under the junction:
      let junction = profile.selectedStorePath / "bin"
      check fileExists(junction / "tool-a.cmd")
      check fileExists(junction / "bin" / "tool-b.cmd")
      # `executableName = tool-a` makes `tool-a.cmd` the primary.
      check profile.resolvedExecutablePath == junction / "tool-a.cmd"
      check profile.declaredExecutablePath == "tool-a.cmd"

      # The receipt records BOTH declared `bin` entries.
      let receipt = parseFile(
        profile.selectedStorePath / ".repro-receipt.json")
      check receipt{"manifestBin"}.len == 2
      var recordedBins: seq[string]
      for n in receipt{"manifestBin"}:
        recordedBins.add(n.getStr().replace('\\', '/'))
      check "tool-a.cmd" in recordedBins
      check "bin/tool-b.cmd" in recordedBins

      # The `[path, alias, args]` entry's first element is taken as the
      # primary when the package selects it by leaf name.
      let useDefB = fixtureUseDef(
        packageSelector = "m74-array-b",
        executableName = "tool-b",
        bucket = sandbox.bucketName,
        app = fixture.name,
        version = fixture.version,
        preferredVersion = "",
        manifestChecksum = "",
        executablePath = "tool-b.cmd",
        requiresExecutionProfileChecksum = true)
      let profileB = resolveScoopTool(useDefB, storeRoot)
      check profileB.resolvedExecutablePath ==
        profileB.selectedStorePath / "bin" / "bin" / "tool-b.cmd"
      check profileB.declaredExecutablePath.replace('\\', '/') ==
        "bin/tool-b.cmd"

    # -----------------------------------------------------------------
    # Case 4: a `bin` entry that names a file GENUINELY ABSENT on disk
    # — the post-install presence check stays STRICT and raises a
    # structured `EScoopInstallFailed` naming the expected path.
    # -----------------------------------------------------------------
    block missingBin:
      # Manifest declares `bin\ghost.cmd`; the install staged NOTHING
      # there (exesOnDisk is empty for that path).
      let fixture = stageManifestBinApp(sandbox,
        app = "m74-missing-app", version = "0.9.0",
        binField = %"bin\\ghost.cmd",
        exesOnDisk = @[])
      discard fixture
      let useDef = fixtureUseDef(
        packageSelector = "m74-missing",
        executableName = "ghost",
        bucket = sandbox.bucketName,
        app = "m74-missing-app",
        version = "0.9.0",
        preferredVersion = "",
        manifestChecksum = "",
        executablePath = "ghost.cmd",
        requiresExecutionProfileChecksum = true)

      var raised = false
      try:
        discard resolveScoopTool(useDef, storeRoot)
      except EScoopInstallFailed as err:
        raised = true
        # The diagnostic must NAME the expected path — the
        # manifest-declared `bin\ghost.cmd` location under the junction.
        check err.msg.contains("executable not present after install")
        check err.msg.replace('\\', '/').contains("/bin/ghost.cmd")
      check raised

    # -----------------------------------------------------------------
    # Case 5: a manifest with NO `bin` field — a library / env-add-path
    # app. Realizes gracefully: no executable, no error.
    # -----------------------------------------------------------------
    block noBin:
      let versionDir = sandbox.appsDir / "m74-lib-app" / "1.0.0"
      createDir(versionDir)
      writeFile(versionDir / "install.json",
        ($ %*{"architecture": "64bit", "bucket": sandbox.bucketName}))
      # Manifest deliberately omits `bin`.
      writeFile(versionDir / "manifest.json",
        ($ %*{"version": "1.0.0", "description": "library, no bin"}))
      writeFile(sandbox.bucketManifestDir / "m74-lib-app.json",
        ($ %*{"version": "1.0.0", "description": "library, no bin"}))
      let useDef = fixtureUseDef(
        packageSelector = "m74-lib",
        executableName = "m74lib",
        bucket = sandbox.bucketName,
        app = "m74-lib-app",
        version = "1.0.0",
        preferredVersion = "",
        manifestChecksum = "",
        executablePath = "m74lib.exe",
        requiresExecutionProfileChecksum = true)

      # No `bin` → no executable, no error.
      let profile = resolveScoopTool(useDef, storeRoot)
      check profile.resolvedExecutablePath == ""
      check profile.declaredExecutablePath == ""
      check dirExists(profile.selectedStorePath)
      let receipt = parseFile(
        profile.selectedStorePath / ".repro-receipt.json")
      check receipt{"manifestBin"}.kind == JArray
      check receipt{"manifestBin"}.len == 0
