## A source package's mutable output path can outlive the process that built
## it. The sidecar must prevent another host platform from treating those
## bytes as a completed local realization.

import std/[os, tempfiles, unittest]

import repro_interface_artifacts
import repro_project_dsl/install_mirror_resolver
import repro_tool_profiles

proc makeRecipe(root, name, platformTag: string) =
  let recipeDir = root / name
  let libDir = recipeDir / ".repro" / "output" / "install" / "usr" / "lib"
  createDir(libDir)
  writeFile(recipeDir / "repro.nim", "## synthetic source recipe\n")
  let suffix =
    when defined(windows): ".dll"
    elif defined(macosx): ".dylib"
    else: ".so"
  writeFile(libDir / ("lib" & name & suffix), "synthetic library\n")
  writeFile(realizationInfoPath(root, name),
    "platform=" & platformTag & "\n")

proc useDef(name: string): InterfaceToolUse =
  InterfaceToolUse(
    rawConstraint: name,
    packageSelector: name,
    executableName: name)

suite "from-source realization platform provenance":
  test "foreign realization requires a source rebuild":
    let scratch = createTempDir("repro-foreign-realization-", "")
    defer: removeDir(scratch)
    makeRecipe(scratch, "cairo", "foreign-cpu")

    let outcome = tryResolveFromSourceTool(useDef("cairo"), scratch)

    check outcome.kind == rrNeedsBuild

  test "current-platform realization remains resolvable":
    let scratch = createTempDir("repro-native-realization-", "")
    defer: removeDir(scratch)
    makeRecipe(scratch, "cairo", currentRealizationPlatformTag())

    let outcome = tryResolveFromSourceTool(useDef("cairo"), scratch)

    check outcome.kind == rrResolved
    check outcome.profile.installMethod == "from-source"
