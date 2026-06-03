## M55 Verification Gate: e2e_scoop_adapter_realize_and_launch
##
## Two sub-tests:
##
## 1. Library-level coverage (`e2e_scoop_adapter_realize_and_launch`):
##    Configures Scoop in a sandboxed root, declares a package using
##    scoopApp, exercises the adapter end-to-end through resolveScoopTool,
##    verifies the realized pointer prefix exists, the executable runs
##    through the typed wrapper (launchScoopExecutable), the execution-
##    profile checksum is recorded in the receipt, a second resolve is a
##    cache-hit-equivalent, and a corrupted post-install file is rejected
##    on the next launch. The pre-populated `apps/<app>/<version>/` dir
##    in this sub-test means the install branch of `resolveScoopTool` is
##    not driven here; the install-path coverage lives in sub-test 2.
##
## 2. Public-CLI + real-`scoop install` coverage
##    (`e2e_scoop_repro_build_drives_real_install`): Compiles
##    `apps/repro/repro.nim`, authors a fixture project that declares a
##    Scoop-provisioned tool through `scoopApp(...)` and a single
##    `repro build` action, shells out
##    `repro.exe build <fixture-project> --tool-provisioning=scoop`
##    against the sandboxed Scoop root, verifies that real `scoop install`
##    ran (it must, because `apps/<app>/<version>/` is NOT
##    pre-populated), the realized pointer prefix exists at the expected
##    path, the junction binds to `<scoop-root>/apps/<app>/<exact-version>/`
##    (NOT `current/`), the build action ran the Scoop-provisioned tool,
##    and the receipt records the practical-hardening tier.

when not defined(windows):
  {.warning[UnreachableCode]: off.}
  echo "[platform N/A] e2e_scoop_adapter_realize_and_launch: " &
    "this gate requires Windows and a real Scoop install"
  quit(0)

import std/[json, os, osproc, sequtils, strutils, tempfiles, unittest]

import repro_tool_profiles

import ./scoop_sandbox

import repro_test_support

suite "e2e_scoop_adapter_realize_and_launch":
  when isNixSupported:
    test "e2e_scoop_adapter_realize_and_launch":
      let scoopBinary = resolveScoopBinary()
      if scoopBinary.len == 0:
        raise newException(OSError,
          "M55 gate requires a real scoop binary on PATH (none found). " &
          "Install Scoop from https://scoop.sh/ before running this test.")
      check fileExists(scoopBinary) or scoopBinary.endsWith(".ps1")

      let tempRoot = createTempDir("repro-m55-realize-", "")
      defer: safeRemoveTempRoot(tempRoot)

      let sandbox = setupScoopSandbox(tempRoot, "main")
      let fixture = populateScoopApp(sandbox, app = "repro-m55-fixture",
        version = "1.0.0", executableName = "fixture-cli.cmd",
        executablePayload = fixtureExecutablePayload("fixture-cli 1.0.0 BUILD-A"))

      # Real Scoop must observe the sandboxed install. Use `scoop list`
      # against $env:SCOOP to verify; the spec requires "verifies
      # installation through real Scoop".
      let listing = execCmdEx(shellCommand([scoopBinary, "list"]))
      check listing.exitCode == 0
      check listing.output.contains("repro-m55-fixture")

      let storeRoot = tempRoot / "tool-store"
      let useDef = fixtureUseDef(
        packageSelector = "repro-m55-fixture",
        executableName = "fixture-cli",
        bucket = sandbox.bucketName,
        app = fixture.name,
        version = fixture.version,
        preferredVersion = "",
        manifestChecksum = "",
        executablePath = fixture.executableName)

      let profile = resolveScoopTool(useDef, storeRoot)

      # Realized prefix exists under the local tool store with a junction
      # to the exact-version directory — NEVER through current/.
      check profile.installMethod == "scoop"
      check profile.adapterStrength == asWeak
      check profile.practicalHardening == phPinnedAndProfileVerified
      check profile.cachePortability == cpPortable
      check profile.scoopBucket == sandbox.bucketName
      check profile.scoopApp == fixture.name
      check profile.scoopPinnedVersion == "1.0.0"
      check profile.scoopResolvedVersion == "1.0.0"
      check profile.scoopJunctionTarget == fixture.versionDir
      check profile.scoopManifestChecksum.len == 64
      check profile.scoopExecutionProfileChecksum.len == 64
      check dirExists(profile.selectedStorePath)

      let resolvedJunctionBin = profile.selectedStorePath / "bin"
      check dirExists(resolvedJunctionBin)

      # The junction bin/ MUST resolve to the exact-version directory,
      # never to apps/<app>/current. The spec is explicit: binding
      # through current/ would let `scoop update` swap the bytes our
      # launch plans reach. sameFile would follow both junctions to the
      # same backing inode, so compare the literal junction TARGET path
      # strings — the adapter records that target in profile.scoopJunctionTarget.
      let live = readJunctionTarget(resolvedJunctionBin)
      check live.len > 0
      check sameFile(live, fixture.versionDir)
      check absolutePath(live) == absolutePath(fixture.versionDir)
      check absolutePath(live) != absolutePath(fixture.currentDir)
      check profile.scoopJunctionTarget == fixture.versionDir
      check profile.scoopJunctionTarget != fixture.currentDir

      # Executable runs through the typed wrapper — launchScoopExecutable
      # verifies the receipt's execution-profile checksum FIRST, then
      # shells out.
      let firstLaunch = launchScoopExecutable(profile.selectedStorePath,
        ["--version"])
      check firstLaunch.exitCode == 0
      check firstLaunch.output.contains("fixture-cli 1.0.0 BUILD-A")

      # Receipt records all the practical-hardening evidence.
      let receiptPath = profile.selectedStorePath / ".repro-receipt.json"
      check fileExists(receiptPath)
      let receipt = parseFile(receiptPath)
      check receipt{"adapter"}.getStr() == "scoop"
      check receipt{"adapterStrength"}.getStr() == "weak"
      check receipt{"practicalHardening"}.getStr() ==
        "pinned-and-profile-verified"
      check receipt{"bucket"}.getStr() == sandbox.bucketName
      check receipt{"app"}.getStr() == fixture.name
      check receipt{"pinnedVersion"}.getStr() == "1.0.0"
      check receipt{"resolvedVersion"}.getStr() == "1.0.0"
      check receipt{"junctionTarget"}.getStr() == fixture.versionDir
      check receipt{"executionProfileChecksum"}.getStr().len == 64

      # Second resolve must be deterministic — same prefix, same checksums.
      let profile2 = resolveScoopTool(useDef, storeRoot)
      check profile2.selectedStorePath == profile.selectedStorePath
      check profile2.scoopManifestChecksum == profile.scoopManifestChecksum
      check profile2.scoopExecutionProfileChecksum ==
        profile.scoopExecutionProfileChecksum
      check profile2.profileFingerprint == profile.profileFingerprint

      # Corrupt a post-install file under the exact-version dir, then
      # re-launch through the typed wrapper. The execution-profile
      # checksum verification at launch time must reject this.
      writeFile(fixture.versionDir / "install.json",
        "{\"corrupted\": true, \"added-by-test\": \"M55-corruption\"}")
      expect EScoopProfileChecksumMismatch:
        discard launchScoopExecutable(profile.selectedStorePath, ["--version"])

# ---------------------------------------------------------------------------
# CLI-driven sub-test: drives the entire flow through the public
# `repro build --tool-provisioning=scoop` entry point and exercises the
# real `scoop install` shell-out path (apps/<app>/<version>/ NOT
# pre-populated). Together these two gate-2 issues from the M55 review
# are exercised by one focused public-CLI E2E.
# ---------------------------------------------------------------------------

proc valueAfter(output, prefix: string): string =
  for line in output.splitLines:
    if line.startsWith(prefix):
      return line[prefix.len .. ^1].strip()
  ""

proc requireSuccessShell(command: string; cwd = getCurrentDir()): string =
  let res = execCmdEx(command, workingDir = cwd)
  if res.exitCode != 0:
    echo "FAILED: " & command
    echo "stdout/stderr:\n" & res.output
    checkpoint(res.output)
  check res.exitCode == 0
  res.output

proc q2(value: string): string = quoteShell(value)

proc shellCmd2(args: openArray[string]): string =
  args.mapIt(q2(it)).join(" ")

proc snakeCaseSelectorModule(selector: string): string =
  ## Mirror the package DSL's `selectorModuleName`: camelCase to snake_case,
  ## lowercased. The reprobuild `uses` declaration produces an import path
  ## using this exact transformation, so the package file under
  ## `reprobuild/packages/` MUST be named accordingly.
  var previousWasWord = false
  for ch in selector:
    if ch.isAlphaNumeric():
      if ch.isUpperAscii() and previousWasWord and
          result.len > 0 and result[^1] != '_':
        result.add('_')
      result.add(ch.toLowerAscii())
      previousWasWord = true
    else:
      if result.len > 0 and result[^1] != '_':
        result.add('_')
      previousWasWord = false
  while result.len > 0 and result[^1] == '_':
    result.setLen(result.len - 1)
  if result.len == 0:
    result = "package"

proc writeScoopInstallFixtureProject(projectRoot, bucket, app, version,
                                    manifestChecksum, executableName: string) =
  ## Authors a self-contained reprobuild project that uses a
  ## Scoop-provisioned tool. The package definition declares the
  ## scoopApp metadata; the project root declares one build action
  ## that runs the tool with --source/--output to produce a marker
  ## file the test inspects after the build.
  createDir(projectRoot / "src")
  writeFile(projectRoot / "src" / "input.txt", "scoop-install-fixture")
  createDir(projectRoot / "reprobuild" / "packages")
  let packageModuleName = snakeCaseSelectorModule(app)
  writeFile(projectRoot / "reprobuild" / "packages" / (packageModuleName & ".nim"),
    "import repro_project_dsl\n\n" &
    "package " & app & ":\n" &
    "  provisioning:\n" &
    "    scoopApp(\n" &
    "      bucket = " & bucket.escape() & ",\n" &
    "      app = " & app.escape() & ",\n" &
    "      version = " & version.escape() & ",\n" &
    "      manifestChecksum = " & manifestChecksum.escape() & ",\n" &
    "      executablePath = " & executableName.escape() & ",\n" &
    "      requiresExecutionProfileChecksum = true,\n" &
    "      packageId = " & (bucket & "/" & app & "@" & version).escape() & ",\n" &
    "      lockIdentity = " & ("scoop:" & bucket & "/" & app & ":" &
        manifestChecksum).escape() & ")\n\n" &
    "  executable " & app & ":\n" &
    "    cli:\n" &
    "      call:\n" &
    "        flag source is string, alias = \"--source\", role = input, required = true\n" &
    "        flag output is string, alias = \"--output\", role = output, required = true\n")
  writeFile(projectRoot / "reprobuild.nim",
    "import repro_project_dsl\n\n" &
    "package scoopInstallProject:\n" &
    "  usesImportPath \"reprobuild/packages\"\n" &
    "  uses:\n" &
    "    \"" & app & " == " & version & "\"\n\n" &
    "  build:\n" &
    "    let produced = " & app & "(actionId = \"scoop-install-run\",\n" &
    "      source = \"src/input.txt\",\n" &
    "      output = \"build/scoop-install-output.txt\")\n" &
    "    defaultBuildAction(produced)\n")

proc compileReproForTest(repoRoot, tempRoot: string): string =
  let outBin = tempRoot / "repro-bin" / "repro.exe"
  createDir(outBin.parentDir)
  discard requireSuccessShell(shellCmd2([
    "nim", "c", "--verbosity:0", "--hints:off",
    "--nimcache:" & (tempRoot / "nimcache-repro"),
    "--out:" & outBin,
    repoRoot / "apps" / "repro" / "repro.nim"
  ]), repoRoot)
  outBin

suite "e2e_scoop_repro_build_drives_real_install":
  when isNixSupported:
    test "e2e_scoop_repro_build_drives_real_install":
      # This is the M55 gate's "public-CLI E2E coverage" + "real scoop
      # install shell-out" requirement, folded into one sub-test.
      let scoopBinary = resolveScoopBinary()
      if scoopBinary.len == 0:
        raise newException(OSError,
          "M55 gate requires a real scoop binary on PATH (none found). " &
          "Install Scoop from https://scoop.sh/ before running this test.")

      let repoRoot = getCurrentDir()
      let tempRoot = createTempDir("repro-m55-cli-install-", "")
      defer: safeRemoveTempRoot(tempRoot)

      # Compile the actual `repro` CLI binary the spec says we must drive.
      let reproBin = compileReproForTest(repoRoot, tempRoot)
      check fileExists(reproBin)

      # Sandboxed Scoop root, installable bucket manifest (file:// URL to a
      # real zip on disk), and CRITICALLY: NO pre-populated
      # apps/<app>/<version>/. Real `scoop install` must lay it down.
      # Use a non-`main` bucket name. `scoop update` (triggered by
      # `scoop install` when LAST_UPDATE is stale) auto-converts a
      # non-git `main` bucket to a git checkout of the upstream Main
      # bucket, which would wipe our fixture manifest. A custom-named
      # bucket is left alone ("not a git repository. Skipped.").
      let sandbox = setupScoopSandbox(tempRoot, "m55-fixture")
      # Scoop tolerates `-` in app names, but the package DSL identifier
      # (used for the executable function name in the generated provider)
      # follows Nim's identifier rules, so the package/app name is kept
      # underscored even though Scoop, the bucket layout, the SCOOP root,
      # etc. would all happily handle hyphens.
      let appName = "reproM55InstallFixture"
      let appVersion = "1.0.0"
      let exeName = "fixture-cli.cmd"
      let installable = setupInstallableScoopApp(sandbox, tempRoot,
        app = appName, version = appVersion,
        executableName = exeName,
        executablePayload = fixtureBuildActionPayload(
          "fixture-cli " & appVersion & " BUILD-A"))

      # Pre-condition for the install-path branch: the version dir does
      # NOT exist before the adapter is invoked.
      check not dirExists(installable.versionDir)
      check not dirExists(installable.currentDir)
      check fileExists(installable.archivePath)
      check installable.manifestChecksum.len == 64

      # Author the fixture project. The package definition uses scoopApp
      # with the manifestChecksum we just computed, so the adapter's
      # manifest-checksum verification is exercised too.
      let projectRoot = tempRoot / "project"
      writeScoopInstallFixtureProject(projectRoot,
        bucket = sandbox.bucketName,
        app = appName,
        version = appVersion,
        manifestChecksum = installable.manifestChecksum,
        executableName = exeName)

      # Shell out the public CLI. `$env:SCOOP` is already pointing at
      # the sandboxed root (setupScoopSandbox sets it), so real
      # scoop.exe will read/write only inside tempRoot.
      let buildOutput = requireSuccessShell(shellCmd2([reproBin, "build",
        projectRoot, "--tool-provisioning=scoop"]), repoRoot)

      # Public-CLI evidence the spec requires.
      check buildOutput.contains("tool-provisioning=scoop")
      check buildOutput.contains("action: scoop-install-run status=asSucceeded launched=true")

      # The build action ran the Scoop-provisioned tool; its output file
      # must exist with the expected marker, proving the tool resolved
      # under the realized prefix (not some random PATH binary).
      let outputFile = projectRoot / "build" / "scoop-install-output.txt"
      check fileExists(outputFile)
      let outputText = readFile(outputFile)
      check outputText.contains("fixture-cli " & appVersion & " BUILD-A")
      check outputText.contains("scoop-install-fixture")

      # The install-branch must have executed: apps/<app>/<version>/ is
      # now populated by Scoop's pipeline, including a `current` junction
      # that Scoop creates after install.
      check dirExists(installable.versionDir)
      check fileExists(installable.versionDir / exeName)
      check dirExists(installable.currentDir)

      # Adapter receipt evidence at the realized pointer prefix.
      let identityPath = valueAfter(buildOutput, "toolIdentity:")
      check identityPath.endsWith("scoop-tool-identities.rbtp")
      check readFile(identityPath)[0 .. 3] == "RBTP"
      let identity = readPathOnlyBuildIdentity(identityPath)
      check identity.profiles.len == 1
      let profile = identity.profiles[0]
      check profile.installMethod == "scoop"
      check profile.adapterStrength == asWeak
      check profile.practicalHardening == phPinnedAndProfileVerified
      check profile.cachePortability == cpPortable
      check profile.scoopBucket == sandbox.bucketName
      check profile.scoopApp == appName
      check profile.scoopResolvedVersion == appVersion
      check profile.scoopManifestChecksum == installable.manifestChecksum
      check profile.scoopExecutionProfileChecksum.len == 64
      check dirExists(profile.selectedStorePath)

      # Junction binds to the exact-version dir, NEVER to current/.
      let resolvedJunctionBin = profile.selectedStorePath / "bin"
      check dirExists(resolvedJunctionBin)
      let liveTarget = readJunctionTarget(resolvedJunctionBin)
      check liveTarget.len > 0
      check sameFile(liveTarget, installable.versionDir)
      check absolutePath(liveTarget) == absolutePath(installable.versionDir)
      check absolutePath(liveTarget) != absolutePath(installable.currentDir)
      check profile.scoopJunctionTarget == installable.versionDir
      check profile.scoopJunctionTarget != installable.currentDir

      # Receipt records the practical-hardening tier and other evidence.
      let receiptPath = profile.selectedStorePath / ".repro-receipt.json"
      check fileExists(receiptPath)
      let receipt = parseFile(receiptPath)
      check receipt{"adapter"}.getStr() == "scoop"
      check receipt{"practicalHardening"}.getStr() ==
        "pinned-and-profile-verified"
      check receipt{"bucket"}.getStr() == sandbox.bucketName
      check receipt{"app"}.getStr() == appName
      check receipt{"pinnedVersion"}.getStr() == appVersion
      check receipt{"resolvedVersion"}.getStr() == appVersion
      check receipt{"junctionTarget"}.getStr() == installable.versionDir
      check receipt{"manifestChecksum"}.getStr() == installable.manifestChecksum
      check receipt{"declaredManifestChecksum"}.getStr() ==
        installable.manifestChecksum
      check receipt{"executionProfileChecksum"}.getStr().len == 64
