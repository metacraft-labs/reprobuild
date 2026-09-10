import std/[sequtils, unittest]
import repro_project_dsl
import repro_interface_artifacts
import repro_dsl_stdlib/configurables/variants
import repro_dsl_stdlib/constructors/cmake_package as cmake_constructor
import repro_dsl_stdlib/constructors/meson_package as meson_constructor
import repro_dsl_stdlib/constructors/autotools_package as autotools_constructor
import repro_dsl_stdlib/types/package_result
import repro_dsl_stdlib/synthesis
import "../fixtures/install-mirror-tools/repro" as mirror_recipe
import ./fixtures/install_mirror_no_synthesis/repro as no_synthesis_recipe

const FetchHash = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

package explicitMirrorTools:
  nativeBuildDeps:
    "rm >=8"
    "cmake >=3.24"
  build:
    discard cmake_constructor.cmake_package(srcDir = "src")

package unrelatedMirrorMetadata:
  nativeBuildDeps:
    "cmake >=3.24"
  build:
    discard

package mesonMirrorTools:
  build:
    discard meson_constructor.meson_package(srcDir = "src")

package glibcSource:
  build:
    discard autotools_constructor.autotools_package(srcDir = "src")

package cmakeSynthMirror:
  nativeBuildDeps:
    "cmake >=3.24"
  fetch:
    url: "https://example.invalid/mirror.tar.gz"
    sha256: FetchHash
  executable cmakeSynthProbe:
    discard

package mesonSynthMirror:
  nativeBuildDeps:
    "meson >=1"
  fetch:
    url: "https://example.invalid/mirror.tar.gz"
    sha256: FetchHash
  executable mesonSynthProbe:
    discard

package autotoolsSynthMirror:
  nativeBuildDeps:
    "autoconf >=2"
  fetch:
    url: "https://example.invalid/mirror.tar.gz"
    sha256: FetchHash
  executable autotoolsSynthProbe:
    discard

package explicitNoMirror:
  nativeBuildDeps:
    "cmake >=3.24"
  fetch:
    url: "https://example.invalid/mirror.tar.gz"
    sha256: FetchHash
  build:
    discard

package customShellMirrorTools:
  nativeBuildDeps:
    "sed"
  build:
    shell "mkdir -p $out/lib"

suite "install mirror tool metadata":
  test "custom shell mirrors declare normalization tools without executing build bodies":
    let packages = registeredPackages().filterIt(
      it.packageName == "customShellMirrorTools")
    require packages.len == 1
    check registeredShellActions("customShellMirrorTools").len == 0
    let iface = toProjectInterface(packages[0], registeredPackages())
    for name in typedInstallMirrorShellTools("customShellMirrorTools"):
      let uses = iface.toolUses.filterIt(it.executableName == name)
      check uses.len == 1
      if uses.len == 1:
        check uses[0].nixProvisioning.len > 0
    let sedDeps = packages[0].nativeBuildDeps.filterIt(it.executableName == "sed")
    require sedDeps.len == 1
    check sedDeps[0].rawConstraint == "sed"
  test "constructor tools belong to the recipe rather than its same-name stub":
    let packages = registeredPackages()
    let recipes = packages.filterIt(it.packageName == "sed" and
      it.sourceFile == MirrorRecipeSource)
    let stubs = packages.filterIt(it.packageName == "sed" and
      it.sourceFile != MirrorRecipeSource)
    require recipes.len == 1
    require stubs.len == 1
    check stubs[0].nativeBuildDeps.len == 0
    let iface = artifactFromRegisteredDsl(MirrorRecipeSource).projectInterface
    check iface.packageName == "sed"
    for name in ["sh", "rm", "mkdir", "cp", "touch", "sed", "chmod"]:
      let uses = iface.toolUses.filterIt(it.executableName == name)
      check uses.len == 1
      if uses.len == 1:
        check uses[0].nixProvisioning.len > 0
      let declared = recipes[0].nativeBuildDeps.filterIt(
        it.executableName == name)
      check declared.len == 1
      if declared.len == 1:
        check declared[0].depKind == DepKindNative
        check declared[0].sourceFile == MirrorRecipeSource
      let solverUses = pendingSolverDependencies().filterIt(
        it.parentPackage == "sed" and it.depPackage == name)
      check solverUses.len == 1
      if solverUses.len == 1:
        check solverUses[0].depKind == DepKindNative

  test "platform shell helpers have provisioning metadata":
    let iface = artifactFromRegisteredDsl(MirrorRecipeSource).projectInterface
    when defined(linux):
      for name in ["find", "head", "od", "tr", "sort", "grep",
                   "dirname", "basename", "wc", "patchelf", "readlink"]:
        let uses = iface.toolUses.filterIt(it.executableName == name)
        check uses.len == 1
        if uses.len == 1:
          check uses[0].nixProvisioning.len > 0
    else:
      check "readlink" notin iface.toolUses.mapIt(it.executableName)
    check "ln" notin iface.toolUses.mapIt(it.executableName)

  test "qualified constructors preserve explicit native constraints":
    let packages = registeredPackages().filterIt(
      it.packageName == "explicitMirrorTools")
    require packages.len == 1
    let uses = packages[0].nativeBuildDeps.filterIt(it.executableName == "rm")
    require uses.len == 1
    check uses[0].rawConstraint == "rm >=8"
    check packages[0].nativeBuildDeps.filterIt(it.executableName == "sh").len == 1

  test "an unrelated build body gains no generated mirror dependencies":
    let packages = registeredPackages().filterIt(
      it.packageName == "unrelatedMirrorMetadata")
    require packages.len == 1
    check packages[0].nativeBuildDeps.mapIt(it.executableName) == @["cmake"]

  test "Meson and Autotools constructors share the generated tool contract":
    for packageName in ["mesonMirrorTools", "glibcSource"]:
      let packages = registeredPackages().filterIt(it.packageName == packageName)
      require packages.len == 1
      let iface = toProjectInterface(packages[0], registeredPackages())
      for name in typedInstallMirrorShellTools(packageName):
        let uses = iface.toolUses.filterIt(it.executableName == name)
        check uses.len == 1
        if uses.len == 1:
          check uses[0].nixProvisioning.len > 0

  test "real default synthesis declares mirror tools during interface extraction":
    for packageName in ["cmakeSynthMirror", "mesonSynthMirror", "autotoolsSynthMirror"]:
      let packages = registeredPackages().filterIt(it.packageName == packageName)
      require packages.len == 1
      check registeredBuildActions(packageName).len > 0
      let iface = toProjectInterface(packages[0], registeredPackages())
      for name in typedInstallMirrorShellTools(packageName):
        let uses = iface.toolUses.filterIt(it.executableName == name)
        check uses.len == 1
        if uses.len == 1:
          check uses[0].nixProvisioning.len > 0

  test "synthesis metadata respects the import gate and explicit build bodies":
    for packageName in ["noSynthesisMirror", "explicitNoMirror"]:
      let packages = registeredPackages().filterIt(it.packageName == packageName)
      require packages.len == 1
      let iface = toProjectInterface(packages[0], registeredPackages())
      check "sha256sum" in iface.toolUses.mapIt(it.executableName)
      check "sed" notin iface.toolUses.mapIt(it.executableName)
