## Tarball provisioning falls through to a package's from-source realization
## when the package has no tarball for the host.
##
## reprobuild-specs Dependency-Provisioning-In-Build-Graph.md, "A mode with no
## realization for the host falls through to from-source": the selected mode
## is tried first; only when the package declares no realization of that mode
## for the host is its from-source recipe consulted. A host tarball, when one
## exists, is never bypassed -- not even when it fails to realize.
##
## Before this rule, `toolProfileFor(tpmTarball, ...)` called
## `resolveTarballTool` and nothing else, so a project whose Windows dev shell
## runs in tarball mode could not reach a package whose only Windows
## realization is a source recipe.
##
## Fixtures: each case lays a synthetic recipe catalog on the real filesystem
## and points `REPRO_FROM_SOURCE_ROOT` at it; a "built" recipe is one whose
## stage-copy artifact exists at `<root>/<name>/.repro/output/<name>/<name>`,
## which is exactly what `tryResolveFromSourceTool` probes for. Nothing is
## mocked: resolution runs through the public `toolBuildIdentity`, the same
## entry point `repro build` and the dev-env activation use.

import std/[os, strutils, tempfiles, unittest]

import repro_interface_artifacts
import repro_tool_profiles

proc foreignOs(): string =
  when defined(windows): "linux" else: "windows"

proc foreignTarball(name: string): InterfaceTarballProvisioning =
  ## A tarball pin for an OS this host is not: present in the recipe, never a
  ## realization for this host.
  InterfaceTarballProvisioning(
    packageName: name,
    url: "https://example.invalid/" & name & "-1.0.tar.gz",
    sha256: "0".repeat(64),
    archiveType: "tar.gz",
    executablePath: name,
    packageId: name & "@1.0",
    lockIdentity: "tarball:" & name & "@1.0:sha256:" & "0".repeat(64),
    cpu: "",
    os: foreignOs())

proc hostTarball(name: string): InterfaceTarballProvisioning =
  ## A tarball pin for every host, whose URL can never be fetched.
  InterfaceTarballProvisioning(
    packageName: name,
    url: "https://example.invalid/" & name & "-2.0.tar.gz",
    sha256: "0".repeat(64),
    archiveType: "tar.gz",
    executablePath: name,
    packageId: name & "@2.0",
    lockIdentity: "tarball:" & name & "@2.0:sha256:" & "0".repeat(64))

proc toolUse(name: string;
             tarball: seq[InterfaceTarballProvisioning]): InterfaceToolUse =
  InterfaceToolUse(rawConstraint: name, packageSelector: name,
    executableName: name, tarballProvisioning: tarball)

proc artifactFor(use: InterfaceToolUse): ProjectInterfaceArtifact =
  ProjectInterfaceArtifact(projectInterface: ProjectInterface(
    projectName: "t_tarball_mode_falls_through_to_from_source",
    defaultToolProvisioning: "tarball",
    toolUses: @[use]))

proc writeRecipe(root, name: string) =
  createDir(root / name)
  writeFile(root / name / "repro.nim", "## synthetic " & name & " recipe\n")

proc writeBuiltArtifact(root, name: string): string =
  let outDir = root / name / ".repro" / "output" / name
  createDir(outDir)
  result = outDir / (when defined(windows): name & ".exe" else: name)
  writeFile(result, "#!/bin/sh\nexit 0\n")
  when not defined(windows):
    setFilePermissions(result, {fpUserRead, fpUserWrite, fpUserExec,
      fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})

template withRecipeRoot(root: string; body: untyped) =
  let saved = getEnv(FromSourceRootEnvVar)
  putEnv(FromSourceRootEnvVar, root)
  try:
    body
  finally:
    if saved.len > 0: putEnv(FromSourceRootEnvVar, saved)
    else: delEnv(FromSourceRootEnvVar)

proc resolveError(use: InterfaceToolUse; storeRoot: string): string =
  try:
    discard toolBuildIdentity(artifactFor(use), tpmTarball,
      storeRoot = storeRoot)
    ""
  except CatchableError as exc:
    exc.msg

suite "tarball mode falls through to a from-source realization":
  let scratch = createTempDir("repro-tarball-from-source-", "")
  let recipes = scratch / "recipes"
  let store = scratch / "tool-store"
  createDir(recipes)

  test "a tarball for another OS only: the built source recipe is used":
    writeRecipe(recipes, "fsforeign")
    let built = writeBuiltArtifact(recipes, "fsforeign")
    withRecipeRoot(recipes):
      let identity = toolBuildIdentity(
        artifactFor(toolUse("fsforeign", @[foreignTarball("fsforeign")])),
        tpmTarball, storeRoot = store)
      check identity.profiles.len == 1
      if identity.profiles.len == 1:
        check identity.profiles[0].resolvedExecutablePath.normalizedPath ==
          built.normalizedPath

  test "no tarball at all: the built source recipe is used":
    writeRecipe(recipes, "fsnone")
    let built = writeBuiltArtifact(recipes, "fsnone")
    withRecipeRoot(recipes):
      let identity = toolBuildIdentity(
        artifactFor(toolUse("fsnone", @[])), tpmTarball, storeRoot = store)
      check identity.profiles.len == 1
      if identity.profiles.len == 1:
        check identity.profiles[0].resolvedExecutablePath.normalizedPath ==
          built.normalizedPath

  test "an unbuilt source recipe is named with the command that builds it":
    writeRecipe(recipes, "fsunbuilt")
    withRecipeRoot(recipes):
      let msg = resolveError(toolUse("fsunbuilt",
        @[foreignTarball("fsunbuilt")]), store)
      checkpoint msg
      check "no tarball realization for this host" in msg
      check (recipes / "fsunbuilt") in msg
      check "repro build" in msg

  test "neither a host tarball nor a source recipe: both are named":
    withRecipeRoot(recipes):
      let msg = resolveError(toolUse("fsnowhere",
        @[foreignTarball("fsnowhere")]), store)
      checkpoint msg
      check "no tarball realization for this host" in msg
      check (recipes / "fsnowhere" / "repro.nim") in msg

  test "a host tarball is never bypassed, even when it fails to realize":
    writeRecipe(recipes, "fshost")
    discard writeBuiltArtifact(recipes, "fshost")
    withRecipeRoot(recipes):
      let msg = resolveError(toolUse("fshost", @[hostTarball("fshost")]),
        store)
      checkpoint msg
      # The tarball's own failure, not a silent switch to the source build.
      check msg.len > 0
      check "from-source" notin msg

  removeDir(scratch)
