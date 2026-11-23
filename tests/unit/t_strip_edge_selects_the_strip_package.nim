## A strip edge names the package that declares ``strip``, and that package
## has its own view of each toolchain archive that carries the program.
##
## Dependency-Provisioning-In-Build-Graph.md §4.2, "Several packages realized
## from one archive (views)": a typed operation reaches an executable through
## the package that owns it, never through an aggregate selector whose
## provisioning names a different program. The ``binutils`` aggregate
## provisions ``ld`` and declares no executable. A strip edge sent through it
## found the real ``strip`` only when the project also declared the ``strip``
## package; a project that declared ``binutils`` alone ran ``ld`` with
## ``strip``'s arguments, and the selector the edge named had no archive
## realization on any host (reprobuild-pm issue
## ``2026-11-18-gcc-and-clang-strip-name-an-executable-the-binutils-aggregate-does-not-declare.md``).
##
## Cases:
##   * ``gccStrip`` and ``clangStrip`` name a registered package that declares
##     the executable their call names;
##   * the edge still renders ``-o <target>``, one ``-K <symbol>`` per kept
##     symbol and the input, in ``strip``'s own argument order;
##   * a strip that would rewrite its input in place (no target, or a target
##     naming the input) is refused, and the ``strip`` package's typed call
##     cannot be written without an output: an in-place strip would
##     rewrite the link edge's declared output from a second edge that
##     declares no write;
##   * the edge is ordered after the edge that produces its input;
##   * ``strip`` selects its own program and the Binutils version in the
##     WinLibs archive (Windows x64) and in the Bootlin archive (Linux
##     x86_64), under the pin and lock identity ``gcc`` uses;
##   * GCC's version cannot satisfy a ``strip`` constraint;
##   * the Linux C toolchain fall-back rule covers ``strip`` as it covers
##     ``ar``: a path-mode or nix-mode build is not handed the toolchain
##     archive's ``strip``.
##
## Falsifying mutations: sending either edge back through ``binutils`` turns
## the first case red; dropping the ``keepSymbols`` flag from the ``strip``
## package (or not passing it) turns the second red; accepting an empty or
## input-naming target turns the refusal case red, and giving the package's
## ``output`` flag a default turns the typed-call case red; not passing
## ``after`` turns the ordering case red; removing a view arm, or giving it
## ``gcc``'s version or executable, turns the WinLibs and Bootlin cases red;
## dropping ``strip`` from ``LinuxHostToolchainPackages`` turns the last red.
##
## No mocks: the real registered stdlib packages, the production selection
## function and the production argv renderer. Nothing is downloaded or run.
# ``strutils.strip`` would shadow the ``strip`` package's typed call that the
# typed-call case below compiles.
import std/strutils except strip
import std/unittest
import repro_project_dsl
import repro_interface_artifacts
import repro_tool_profiles
import repro_cli_support
import repro_dsl_stdlib/packages_schema
import repro_dsl_stdlib/packages/gcc as gccPackage
import repro_dsl_stdlib/packages/clang as clangPackage
import repro_dsl_stdlib/packages/binutils as binutilsModule
import repro_dsl_stdlib/types/options

proc toolUse(selector, versionRange: string): InterfaceToolUse =
  let constraint = selector & (if versionRange.len > 0: " " & versionRange else: "")
  let consumer = PackageDef(packageName: "stripSelectionControl",
    toolUses: @[PackageUseDef(rawConstraint: constraint,
      packageSelector: selector, executableName: selector)])
  let iface = toProjectInterface(consumer, registeredPackages())
  doAssert iface.toolUses.len == 1
  iface.toolUses[0]

proc targetFor(cpu, os: string): RealizationTarget =
  realizationTargetFor(parseEnum[PlatformCpu](cpu), parseEnum[PlatformOs](os),
    baselineMicroarchLevel(parseEnum[PlatformCpu](cpu)))

proc declaringPackage(call: PublicCliCall): string =
  ## "" when a registered package named ``call.packageName`` declares the
  ## executable the call names; otherwise what is wrong, for the failure line.
  for pkg in registeredPackages():
    if pkg.packageName != call.packageName:
      continue
    for exe in pkg.executables:
      if call.executableName in [exe.exportName, exe.binaryName]:
        return ""
    return "package '" & pkg.packageName & "' declares no executable '" &
      call.executableName & "' (it declares " & $pkg.executables.len & ")"
  "no registered package is named '" & call.packageName & "'"

proc stripArgv(action: BuildActionDef): seq[string] =
  argvForCall(action.call, PathOnlyToolProfile(resolvedExecutablePath: "strip"))

type StripEdge = proc (opts: StripOptions): BuildActionDef {.nimcall.}

const stripEdges: array[2, (string, StripEdge)] = [
  ("gccStrip", gccPackage.gccStrip),
  ("clangStrip", clangPackage.clangStrip)]

suite "a strip edge selects the strip package":
  test "gccStrip and clangStrip name a package that declares strip":
    for (name, edge) in stripEdges:
      let action = edge(StripOptions(
        input: BuildActionDef(outputs: @["app"]), target: "app.stripped"))
      checkpoint name & ": " & declaringPackage(action.call)
      check declaringPackage(action.call) == ""
      check action.call.packageName == "strip"

  test "the edge keeps the output, the kept symbols and the input":
    for (name, edge) in stripEdges:
      checkpoint name
      let action = edge(StripOptions(
        input: BuildActionDef(outputs: @["app"]), target: "app.stripped",
        keepSymbols: @["main", "init_hook"]))
      check stripArgv(action) == @["strip", "-o", "app.stripped",
        "-K", "main", "-K", "init_hook", "app"]
      check action.outputs == @["app.stripped"]

  test "a strip that would rewrite its input is refused":
    # ``strip <input>`` (no ``-o``) and ``strip -o <input> <input>`` both
    # rewrite the link edge's declared output from a second edge: a double
    # write and a rewrite of a nominally read-only input, both errors by
    # default (Filesystem-Policy-And-Observed-Inputs.md §"Double Writes",
    # §"Source Rewrites"). The edge is refused when it is built, before any
    # graph holds it.
    for (name, edge) in stripEdges:
      for target in ["", "app", "./app", "dir/../app"]:
        checkpoint name & " target='" & target & "'"
        var refusal = ""
        try:
          discard edge(StripOptions(
            input: BuildActionDef(id: "link-app", outputs: @["app"]),
            target: target))
        except ValueError as error:
          refusal = error.msg
        check "separate output" in refusal
        check "'app'" in refusal

  test "the strip package's typed call cannot omit its output":
    # The refusal above guards the stdlib operation; the package's own typed
    # call must not offer the in-place form either, so ``output`` has no
    # default. The positive control beside it keeps the negative check from
    # passing for an unrelated reason, such as another ``strip`` in scope.
    check not compiles(strip(input = "app"))
    check compiles(strip(output = "app.stripped", input = "app"))

  test "the edge runs after the edge that produces its input":
    for (name, edge) in stripEdges:
      checkpoint name
      let action = edge(StripOptions(
        input: BuildActionDef(id: "link-app", outputs: @["app"]),
        target: "app.stripped"))
      check action.deps == @["link-app"]
      check action.inputs == @["app"]

  test "strip selects its own program and version in the WinLibs archive":
    let windowsX64 = targetFor("x86_64", "windows")
    let gcc = selectTarballProvisioning(toolUse("gcc", ">=12"),
      target = windowsX64)
    let strip = selectTarballProvisioning(toolUse("strip", ""),
      target = windowsX64)
    check strip.url == gcc.url
    check strip.sha256 == gcc.sha256
    check strip.archiveType == gcc.archiveType
    check strip.stripComponents == gcc.stripComponents
    check strip.lockIdentity == gcc.lockIdentity
    check strip.executablePath == "bin/strip.exe"
    check strip.detail.version == "2.46.0.20260210"

  test "strip selects its own program and version in the Bootlin archive":
    let linuxX64 = targetFor("x86_64", "linux")
    let gcc = selectTarballProvisioning(toolUse("gcc", ">=12"),
      target = linuxX64)
    let ar = selectTarballProvisioning(toolUse("ar", ""), target = linuxX64)
    let strip = selectTarballProvisioning(toolUse("strip", ">=2.45 <3"),
      target = linuxX64)
    check strip.url == gcc.url
    check strip.sha256 == gcc.sha256
    check strip.archiveType == gcc.archiveType
    check strip.stripComponents == gcc.stripComponents
    check strip.lockIdentity == gcc.lockIdentity
    check strip.executablePath == "x86_64-buildroot-linux-gnu/bin/strip"
    check strip.detail.version == "2.45.1"
    # The same relocation as the archiver beside it: an unrelocated strip
    # would not start on a host whose loader is elsewhere.
    check strip.detail.elfInterpreter == ar.detail.elfInterpreter
    check strip.detail.elfRunpath == ar.detail.elfRunpath
    check strip.detail.elfPatchDirs == ar.detail.elfPatchDirs

  test "GCC's version cannot satisfy a strip constraint":
    for (cpu, os) in [("x86_64", "windows"), ("x86_64", "linux")]:
      checkpoint os
      var refusal = ""
      try:
        discard selectTarballProvisioning(toolUse("strip", ">=15"),
          target = targetFor(cpu, os))
      except ValueError as error:
        refusal = error.msg
      check "no tarball realization satisfies range" in refusal

  test "the Linux C toolchain fall-back rule covers strip as it covers ar":
    check linuxHostToolchainFallThroughSkipsArchive(toolUse("ar", ""),
      hostOs = "linux")
    check linuxHostToolchainFallThroughSkipsArchive(toolUse("strip", ""),
      hostOs = "linux")
    check not linuxHostToolchainFallThroughSkipsArchive(toolUse("strip", ""),
      hostOs = "windows")
