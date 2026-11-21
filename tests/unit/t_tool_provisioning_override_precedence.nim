## Per-tool provisioning overrides: the surfaces, their precedence, and the
## identity they key.
##
## What is asserted:
##
##   * each surface is read: the `--tool-provisioning-for` values, the
##     `REPRO_TOOL_PROVISIONING_OVERRIDES` variable, and the
##     `[tool-provisioning.overrides]` table of the user configuration, the
##     committed `repro-workspace.toml` and `repro-workspace.local.toml`;
##   * each precedence level beats the next, one case per adjacent pair:
##     flag > variable > local file > committed file > user file >
##     invocation-wide mode (an override beats an explicit
##     `--tool-provisioning`);
##   * one package twice at one level is a usage error, and a mode outside
##     the vocabulary is refused naming where it is written;
##   * an override naming a package no `uses:` entry references is an error
##     from the flag and a note from the variable or configuration;
##   * through the CLI's own tool-identity path (`warmResolveAndWriteIdentity`,
##     the one `repro build` uses): in a `path` invocation an overridden
##     archive tool realizes from its archive into the SHARED tool store
##     (`<store root>/tool-store`) while the other tool resolves from PATH;
##     every profile records `kind` and `overriddenBy`, in the identity file
##     and its inspection JSON; the identity files and the cache key are
##     keyed by the override set (a change of overrides is a miss, and no
##     overrides keeps the historical file names); and the override is
##     logged by name.
##
## No mocks: real configuration files in a temporary workspace, a real
## archive served from a `file://` URL (a local fixture is all precedence
## needs: no real upstream is involved), a real executable on a real PATH.

import std/[json, os, strutils, tables, tempfiles, unittest]

import repro_cli_support
import repro_dev_env_engine
import repro_interface_artifacts
import repro_tool_profiles
import repro_test_support/process_fixtures

proc writeExecutable(path, body: string) =
  createDir(parentDir(path))
  writeFile(path, body)
  when not defined(windows):
    setFilePermissions(path, {fpUserRead, fpUserWrite, fpUserExec,
      fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})

proc sdkUse(archiveDir: string): InterfaceToolUse =
  ## A package with a host archive (a raw file served from `file://`) and a
  ## PATH arm (it names an executable), so it can be overridden either way.
  let payload = archiveDir / "sdktool.cmd"
  createDir(archiveDir)
  writeFile(payload, "@echo sdktool 1.0\n")
  result = InterfaceToolUse(rawConstraint: "sdkfixture",
    packageSelector: "sdkfixture", executableName: "sdkfixture")
  result.tarballProvisioning = @[InterfaceTarballProvisioning(
    packageName: "sdkfixture",
    url: "file://" & payload.replace('\\', '/'),
    sha256: fileSha256Hex(payload), archiveType: "raw",
    executablePath: "bin/sdkfixture.cmd", packageId: "sdkfixture@1.0",
    lockIdentity: "tarball:sdkfixture@1.0:" & fileSha256Hex(payload))]

proc pathUse(): InterfaceToolUse =
  InterfaceToolUse(rawConstraint: "pathfixture",
    packageSelector: "pathfixture", executableName: "pathfixture")

proc artifactOf(uses: seq[InterfaceToolUse];
                defaultMode = ""): ProjectInterfaceArtifact =
  ProjectInterfaceArtifact(projectInterface: ProjectInterface(
    projectName: "t_tool_provisioning_override_precedence",
    defaultToolProvisioning: defaultMode, toolUses: uses))

template withEnv(name, value: string; body: untyped) =
  let had = existsEnv(name)
  let saved = getEnv(name)
  if value.len > 0: putEnv(name, value) else: delEnv(name)
  try:
    body
  finally:
    if had: putEnv(name, saved) else: delEnv(name)

proc workspace(root: string; shared, local: string) =
  ## A workspace whose settings files carry `shared` / `local` as their
  ## `[tool-provisioning.overrides]` bodies ("" for none / no local file).
  createDir(root / "proj")
  writeFile(root / "repro-workspace.toml",
    "schema = \"reprobuild.workspace.settings.v1\"\n" &
    (if shared.len > 0: "\n[tool-provisioning.overrides]\n" & shared else: ""))
  if local.len > 0:
    writeFile(root / "repro-workspace.local.toml",
      "schema = \"reprobuild.workspace.settings-local.v1\"\n\n" &
      "[tool-provisioning.overrides]\n" & local)
  else:
    removeFile(root / "repro-workspace.local.toml")

proc userConfig(path, body: string) =
  writeFile(path, "schema = \"reprobuild.config.v1\"\n" &
    (if body.len > 0: "\n[tool-provisioning.overrides]\n" & body else: ""))

proc selectionFor(flags: seq[string]; root, userPath: string;
                  requested = tpmUnspecified;
                  package = "sdkfixture"): ToolModeSelection =
  let overrides = loadToolProvisioningOverrides(flags, root / "proj", userPath)
  resolveToolUseProvisioning(requested, overrides,
    artifactOf(@[], defaultMode = "path"),
    InterfaceToolUse(packageSelector: package))

suite "per-tool provisioning overrides: surfaces and precedence":
  putEnv("REPRO_CACHE_DISABLE", "1")
  let scratch = createTempDir("repro-tool-overrides-", "")
  releaseDirAtProcessExit(scratch)
  let ws = scratch / "ws"
  let userPath = scratch / "user-config.toml"

  test "each surface is read, and its source is recorded":
    withEnv("REPRO_WORKSPACE_CONFIG", ""):
      withEnv(ToolProvisioningOverridesEnvVar, "a=nix, b=tarball"):
        workspace(ws, "c = \"scoop\"\n", "d = \"from-source\"\n")
        userConfig(userPath, "e = \"path\"\n")
        let overrides = loadToolProvisioningOverrides(@["f=tarball"],
          ws / "proj", userPath)
        var seen = initTable[string, ToolProvisioningOverride]()
        for entry in overrides.entries:
          seen[entry.packageSelector] = entry
        check seen["f"].source == tosFlag
        check seen["f"].overriddenBy == "flag"
        check seen["a"].source == tosEnv and seen["a"].mode == tpmNix
        check seen["b"].mode == tpmTarball and seen["b"].overriddenBy == "env"
        check seen["c"].source == tosWorkspace
        check seen["c"].overriddenBy ==
          "config:" & ws / "repro-workspace.toml"
        check seen["d"].source == tosWorkspaceLocal
        check seen["d"].mode == tpmFromSource
        check seen["e"].source == tosUser
        # The diagnostics name the configuration file and line.
        check (userPath & ":4") in seen["e"].location

  test "each level beats the next (§4.2), one adjacent pair at a time":
    withEnv("REPRO_WORKSPACE_CONFIG", ""):
      userConfig(userPath, "sdkfixture = \"nix\"\n")
      workspace(ws, "sdkfixture = \"scoop\"\n", "sdkfixture = \"from-source\"\n")
      withEnv(ToolProvisioningOverridesEnvVar, "sdkfixture=path"):
        # flag > variable
        let byFlag = selectionFor(@["sdkfixture=tarball"], ws, userPath)
        check byFlag.mode == tpmTarball and byFlag.overriddenBy == "flag"
        # variable > workspace-local configuration
        let byEnv = selectionFor(@[], ws, userPath)
        check byEnv.mode == tpmPathOnly and byEnv.overriddenBy == "env"
      # workspace-local > committed workspace file
      let byLocal = selectionFor(@[], ws, userPath)
      check byLocal.mode == tpmFromSource
      check byLocal.overriddenBy ==
        "config:" & ws / "repro-workspace.local.toml"
      # committed workspace file > user scope
      workspace(ws, "sdkfixture = \"scoop\"\n", "")
      let byShared = selectionFor(@[], ws, userPath)
      check byShared.mode == tpmScoop
      check byShared.overriddenBy == "config:" & ws / "repro-workspace.toml"
      # user scope > the invocation-wide mode, even an explicit flag
      workspace(ws, "", "")
      let byUser = selectionFor(@[], ws, userPath, requested = tpmPathOnly)
      check byUser.mode == tpmNix and byUser.overriddenBy == "config:" & userPath
      # with no override the invocation-wide mode applies, unmarked
      userConfig(userPath, "")
      let invocation = selectionFor(@[], ws, userPath, requested = tpmTarball)
      check invocation.mode == tpmTarball and invocation.overriddenBy == ""

  test "an override beats an explicit --tool-provisioning":
    withEnv("REPRO_WORKSPACE_CONFIG", ""):
      workspace(ws, "", "")
      userConfig(userPath, "")
      let selection = selectionFor(@["sdkfixture=tarball"], ws, userPath,
        requested = tpmPathOnly)
      check selection.mode == tpmTarball
      # ...and leaves every other tool on the invocation's mode.
      let other = selectionFor(@["sdkfixture=tarball"], ws, userPath,
        requested = tpmPathOnly, package = "pathfixture")
      check other.mode == tpmPathOnly and other.overriddenBy == ""

  test "one package twice at one level, or an unknown mode, is a usage error":
    expect ToolProvisioningOverrideError:
      discard parseToolProvisioningOverrideList(
        @["sdk=tarball", "sdk=nix"], tosFlag)
    expect ToolProvisioningOverrideError:
      discard parseToolProvisioningOverrideList(["sdk=tarball,sdk=nix"],
        tosEnv)
    expect ToolProvisioningOverrideError:
      discard parseToolProvisioningOverrideList(@["sdk=zip"], tosFlag)
    expect ToolProvisioningOverrideError:
      discard parseToolProvisioningOverrideList(@["sdk"], tosFlag)
    withEnv("REPRO_WORKSPACE_CONFIG", ""):
      workspace(ws, "sdkfixture = \"brew\"\n", "")
      try:
        discard loadToolProvisioningOverrides(@[], ws / "proj", "")
        check false
      except ToolProvisioningOverrideError as err:
        check (ws / "repro-workspace.toml") in err.msg
        check "brew" in err.msg

  test "an unmatched override is an error from the flag, a note otherwise":
    let uses = @[pathUse()]
    var notes: seq[string] = @[]
    let fromFlag = ToolProvisioningOverrides(entries: @[
      ToolProvisioningOverride(packageSelector: "absent", mode: tpmTarball,
        source: tosFlag)])
    expect ToolProvisioningOverrideError:
      checkOverridesMatch(fromFlag, uses, notes)
    let fromEnv = ToolProvisioningOverrides(entries: @[
      ToolProvisioningOverride(packageSelector: "absent", mode: tpmTarball,
        source: tosEnv)])
    checkOverridesMatch(fromEnv, uses, notes)
    check notes.len == 1
    check "absent" in notes[0]

suite "per-tool provisioning overrides: store, kind and identity":
  putEnv("REPRO_CACHE_DISABLE", "1")
  let scratch = createTempDir("repro-tool-overrides-identity-", "")
  releaseDirAtProcessExit(scratch)

  test "an overridden archive tool in a path invocation realizes in the shared tool store":
    let storeRoot = scratch / "store"
    let outDir = scratch / "out"
    let pathBin = scratch / "path-bin"
    writeExecutable(pathBin / "pathfixture",
      "#!/bin/sh\necho pathfixture 1.0\n")
    writeExecutable(pathBin / "pathfixture.cmd", "@echo pathfixture 1.0\n")
    let artifact = artifactOf(@[pathUse(), sdkUse(scratch / "archive")],
      defaultMode = "path")
    withEnv("REPRO_STORE_ROOT", storeRoot):
      withEnv("PATH", pathBin & $PathSep & getEnv("PATH")):
        # Without overrides: the historical identity file names.
        activeToolProvisioningOverrides = ToolProvisioningOverrides()
        let plainKey = toolIdentityCacheKeyInfo(artifact, tpmPathOnly).key
        activeToolProvisioningOverrides = ToolProvisioningOverrides(entries: @[
          ToolProvisioningOverride(packageSelector: "sdkfixture",
            mode: tpmTarball, source: tosFlag)])
        defer: activeToolProvisioningOverrides = ToolProvisioningOverrides()
        let overriddenKey = toolIdentityCacheKeyInfo(artifact, tpmPathOnly).key
        check overriddenKey != plainKey
        clearToolFallbackNotices()
        let resolved = warmResolveAndWriteIdentity(artifact, outDir,
          tpmPathOnly, storeRootOverride = buildToolStoreRoot(tpmPathOnly))
        let identity = resolved.identity
        check identity.profiles.len == 2
        var byPackage = initTable[string, PathOnlyToolProfile]()
        for profile in identity.profiles:
          byPackage[profile.packageSelector] = profile
        check byPackage["pathfixture"].kind == "path"
        check byPackage["pathfixture"].overriddenBy == ""
        check byPackage["pathfixture"].installMethod == "path"
        let sdk = byPackage["sdkfixture"]
        check sdk.kind == "tarball"
        check sdk.overriddenBy == "flag"
        check sdk.installMethod == "tarball"
        # The store follows the tool's effective kind: the shared store, not
        # the outDir's.
        check sdk.selectedStorePath.normalizedPath.startsWith(
          (storeRoot / "tool-store").normalizedPath)
        check fileExists(sdk.resolvedExecutablePath)
        # Identity files are keyed by the override set...
        check "+overrides-" in extractFilename(resolved.identityPath)
        # ...and carry the kind in both the binary file and the inspection.
        let reread = readPathOnlyBuildIdentity(resolved.identityPath)
        var kinds: seq[string] = @[]
        for profile in reread.profiles:
          kinds.add(profile.packageSelector & ":" & profile.kind & ":" &
            profile.overriddenBy)
        check "sdkfixture:tarball:flag" in kinds
        check "pathfixture:path:" in kinds
        let inspection = parseJson(readFile(resolved.inspectionPath))
        var inspected: seq[string] = @[]
        for profile in inspection["profiles"]:
          inspected.add(profile["packageSelector"].getStr() & ":" &
            profile["kind"].getStr() & ":" & profile["overriddenBy"].getStr())
        check "sdkfixture:tarball:flag" in inspected
        # The override is logged by name, with the realizing arm.
        var logged = false
        for notice in toolFallbackNotices():
          if notice.packageSelector == "sdkfixture" and
              notice.fallback == ToolFallbackOverride:
            logged = notice.installMethod == "tarball" and notice.mode == "path"
        check logged
        # The same override from another source is another identity: the
        # profile records where it came from.
        activeToolProvisioningOverrides = ToolProvisioningOverrides(entries: @[
          ToolProvisioningOverride(packageSelector: "sdkfixture",
            mode: tpmTarball, source: tosEnv)])
        check toolIdentityCacheKeyInfo(artifact, tpmPathOnly).key notin
          [plainKey, overriddenKey]
        let fromEnv = warmResolveAndWriteIdentity(artifact, outDir,
          tpmPathOnly, storeRootOverride = buildToolStoreRoot(tpmPathOnly))
        check fromEnv.identityPath != resolved.identityPath
        for profile in fromEnv.identity.profiles:
          if profile.packageSelector == "sdkfixture":
            check profile.overriddenBy == "env"
            # Same archive, same content-keyed prefix.
            check profile.selectedStorePath == sdk.selectedStorePath
        # No overrides: the historical names and no tarball realization.
        activeToolProvisioningOverrides = ToolProvisioningOverrides()
        let plain = toolIdentityCacheKeyInfo(artifactOf(@[pathUse()],
          defaultMode = "path"), tpmPathOnly)
        check plain.key.len > 0
        let plainResolved = warmResolveAndWriteIdentity(artifactOf(
          @[pathUse()], defaultMode = "path"), outDir, tpmPathOnly)
        check extractFilename(plainResolved.identityPath) ==
          "path-only-tool-identities.rbtp"
        check plainResolved.identity.profiles[0].kind == "path"

  test "the store follows the tool's own kind":
    withEnv("REPRO_STORE_ROOT", scratch / "store"):
      check buildToolStoreRoot(tpmPathOnly) == ""
      check buildToolStoreRoot(tpmTarball).len > 0
      check buildToolStoreRoot(tpmTarball, overridden = true).len > 0
      check buildToolStoreRoot(tpmFromSource) == ""
      check buildToolStoreRoot(tpmFromSource, overridden = true).len > 0
      check buildToolStoreRoot(tpmNix, overridden = true) == ""
      check buildToolStoreRoot(tpmScoop, overridden = true) == ""
      # Where ``toolBuildIdentity`` puts an overridden tool. A build names no
      # store for every tool: an archive or source override goes to the
      # shared store, and a Nix or Scoop override stays in the invocation's
      # own per-outDir store, even in a tarball invocation, whose shared store
      # is for archives only.
      let own = scratch / "out" / "tool-store"
      let buildFor = overriddenToolStoreRoot("", ownStore = own)
      check buildFor(tpmTarball) == buildToolStoreRoot(tpmTarball,
        overridden = true)
      check buildFor(tpmFromSource) == buildToolStoreRoot(tpmFromSource,
        overridden = true)
      check buildFor(tpmNix) == own
      check buildFor(tpmScoop) == own
      # An activation keeps every tool in its one user store.
      let activationFor = overriddenToolStoreRoot(scratch / "user-store",
        ownStore = own)
      check activationFor(tpmNix) == scratch / "user-store"
      check activationFor(tpmTarball) == scratch / "user-store"

  test "the override digest is a function of the sorted override set":
    var a = initTable[string, ToolModeSelection]()
    a["x"] = ToolModeSelection(mode: tpmTarball, overriddenBy: "flag")
    a["y"] = ToolModeSelection(mode: tpmNix, overriddenBy: "env")
    var b = initTable[string, ToolModeSelection]()
    b["y"] = ToolModeSelection(mode: tpmNix, overriddenBy: "env")
    b["x"] = ToolModeSelection(mode: tpmTarball, overriddenBy: "flag")
    check overrideSetDigest(a) == overrideSetDigest(b)
    check overrideSetDigest(initTable[string, ToolModeSelection]()) == ""
    b["x"] = ToolModeSelection(mode: tpmNix, overriddenBy: "flag")
    check overrideSetDigest(a) != overrideSetDigest(b)
