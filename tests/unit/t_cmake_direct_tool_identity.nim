import std/[os, tempfiles, unittest]

import repro_cli_support
import repro_cmake_trycompile

const Wrapper = "reprobuild-cmake-wrapper-fixture"

proc metadata(): TryCompileMetadata =
  TryCompileMetadata(
    usedTools: @[Wrapper, "unused-inline-compiler", Wrapper],
    actions: @[
      TryCompileActionDef(id: "compile", inline: true,
        inlineArgv: @["/resolved/compiler"], toolId: "unused-inline-compiler"),
      TryCompileActionDef(id: "post-build", toolId: Wrapper)])

proc sidecar(root, body: string): string =
  result = root / "wrapper"
  writeFile(result, body)
  writeFile(root / (Wrapper & ".repro-tool-profile"),
    "reprobuild-tool-profile-v1\nresolvedExecutablePath=" & result & "\n")

suite "CMake direct-provider tool identity":
  var root: string
  setup:
    root = createTempDir("repro-cmake-tools-", "")
  teardown:
    removeDir(root)

  test "inline-only projects do not resolve unused compiler declarations":
    var meta = metadata()
    meta.actions.setLen(1)
    let identity = cmakeDirectBuildIdentity(meta, root)
    check identity.profiles.len == 0
    check identity.actionIdentities.len == 0

  test "wrapper actions resolve once through the existing profile resolver":
    let executable = sidecar(root, "first wrapper bytes\n")
    let identity = cmakeDirectBuildIdentity(metadata(), root)
    require identity.profiles.len == 1
    require identity.actionIdentities.len == 1
    check identity.profiles[0].executableName == Wrapper
    check identity.profiles[0].resolvedExecutablePath == executable
    check identity.actionIdentities[0].packageSelector == Wrapper

  test "changing wrapper bytes changes its resolved identity":
    discard sidecar(root, "first wrapper bytes\n")
    let before = cmakeDirectBuildIdentity(metadata(), root)
    discard sidecar(root, "other wrapper bytes\n")
    let after = cmakeDirectBuildIdentity(metadata(), root)
    require before.profiles.len == 1
    require after.profiles.len == 1
    check before.profiles[0].profileFingerprint != after.profiles[0].profileFingerprint

  test "missing wrappers fail resolution instead of inheriting a guessed tool":
    expect OSError:
      discard cmakeDirectBuildIdentity(metadata(), root)

  test "non-inline actions must reference a declared tool":
    var meta = metadata()
    meta.usedTools = @[]
    expect ValueError:
      discard cmakeDirectBuildIdentity(meta, root)
