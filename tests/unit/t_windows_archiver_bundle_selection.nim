## Canonical archiver selection must retain its own version and typed call,
## while sharing the already pinned compiler distribution. These controls use
## real registered stdlib packages and the production selection/plan functions;
## no replacement package or fake tool stands in for the supplier declaration.
import std/[json, jsonutils, strutils, unittest]
import repro_project_dsl
import repro_interface_artifacts
import repro_tool_profiles
import repro_dsl_stdlib/packages_schema
import repro_dsl_stdlib/packages/gcc as gccPackage
import repro_dsl_stdlib/packages/binutils
import repro_dsl_stdlib/types/options

proc toolUse(selector, versionRange: string): InterfaceToolUse =
  let constraint = selector & (if versionRange.len > 0: " " & versionRange else: "")
  let consumer = PackageDef(packageName: "archiverSelectionControl",
    toolUses: @[PackageUseDef(rawConstraint: constraint,
      packageSelector: selector, executableName: selector)])
  let iface = toProjectInterface(consumer, registeredPackages())
  doAssert iface.toolUses.len == 1
  iface.toolUses[0]

let windowsX64 = realizationTargetFor(parseEnum[PlatformCpu]("x86_64"),
  parseEnum[PlatformOs]("windows"),
  baselineMicroarchLevel(parseEnum[PlatformCpu]("x86_64")))

suite "Windows archiver bundle selection":
  test "the existing GCC supplier declaration is unchanged":
    let selected = selectTarballProvisioning(toolUse("gcc", ">=12"),
      target = windowsX64)
    check selected.url == "https://github.com/brechtsanders/winlibs_mingw/releases/download/16.1.0posix-14.0.0-ucrt-r2/winlibs-x86_64-posix-seh-gcc-16.1.0-mingw-w64ucrt-14.0.0-r2.7z"
    check selected.sha256 == "62fb8588d2deee7d662dbcbd386702adbf19643764c971c38aa4839472eee232"
    check selected.archiveType == "7z"
    check selected.stripComponents == 1
    check selected.executablePath == "bin/gcc.exe"
    check selected.lockIdentity == "tarball:gcc-winlibs@16.1.0:sha256:62fb8588d2deee7d662dbcbd386702adbf19643764c971c38aa4839472eee232"
    check selected.detail.version == "16.1.0"
    var semanticRecord = jsonutils.toJson(selected)
    semanticRecord.delete("location")
    echo "GCC_RECORD " & $semanticRecord

  test "bare ar selects its actual binary and binutils version in that bundle":
    let gcc = selectTarballProvisioning(toolUse("gcc", ">=12"),
      target = windowsX64)
    let ar = selectTarballProvisioning(toolUse("ar", ""),
      target = windowsX64)
    check ar.url == gcc.url
    check ar.sha256 == gcc.sha256
    check ar.archiveType == gcc.archiveType
    check ar.stripComponents == gcc.stripComponents
    check ar.lockIdentity == gcc.lockIdentity
    check ar.executablePath == "bin/ar.exe"
    check ar.detail.version == "2.46.0.20260210"

  test "the exact non-SemVer supplier version cannot prove a ranged use":
    var refusal = ""
    try:
      discard selectTarballProvisioning(toolUse("ar", ">=2.46 <3"),
        target = windowsX64)
    except ValueError as error:
      refusal = error.msg
    check "no tarball realization satisfies range" in refusal
    check ">=2.46 <3" in refusal
    check "offered: 2.46.0.20260210" in refusal

  test "GCC's version cannot satisfy an ar constraint":
    expect ValueError:
      discard selectTarballProvisioning(toolUse("ar", ">=16"),
        target = windowsX64)
    expect ValueError:
      discard selectTarballProvisioning(toolUse("ar", "<2.46"),
        target = windowsX64)

  test "the typed archive selects ar and preserves all input objects":
    let objects = @[BuildActionDef(outputs: @["one.o"]),
                    BuildActionDef(outputs: @["two.o"]),
                    BuildActionDef(outputs: @["three.o"])]
    let action = gccPackage.gccArchive(ArchiveOptions(
      objects: objects, target: "grammars.a"))
    check action.call.packageName == "ar"
    check action.outputs == @["grammars.a"]
    var inputs: seq[string]
    for arg in action.call.arguments:
      if arg.role == carInput:
        if arg.nimType == "seq[string]":
          inputs.add(arg.encodedValue.split('\x1f'))
        else:
          inputs.add(arg.encodedValue)
    check inputs == @["one.o", "two.o", "three.o"]
