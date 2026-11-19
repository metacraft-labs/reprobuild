## Every object ``c_library`` and ``c_executable`` compile is
## position-independent, so a shared link does not depend on the
## toolchain's default.
##
## C-Cpp.md §"Mode A — Fine-grained build graph (primary)" lists ``-fPIC``
## in every per-source compile. Before this was fixed (reprobuild-pm issue
## 2026-11-17-stdlib-c-compile-never-passes-fpic-so-shared-links-depend-on-
## the-toolchain-default), ``gccCompile``, ``clangCompile`` and
## ``zigCompile`` never rendered it and ``c_library`` never asked for it, so
## a shared library's objects were PIC only if the toolchain made them so.
## A PIE default is not enough: ``-fPIE`` code reaches a global of default
## visibility through ``R_X86_64_PC32``, and ld refuses that in a shared
## object. Measured on Ubuntu 24.04, GCC 13.3 (PIE by default), before the
## fix, by the last case below: "relocation R_X86_64_PC32 against symbol
## `counter' can not be used when making a shared object; recompile with
## -fPIC".
##
## WHAT IS EXERCISED, AND WHAT IS MOCKED. Nothing is mocked. Each case opens
## a real ``build:`` frame for a registered package, calls ``c_library`` or
## ``c_executable`` as a recipe does, and reads the compile edges it
## registered. The last case also runs them: the compile and link edges'
## argv are rendered by the engine's own ``argvForCall`` against the host's
## gcc and executed. It is skipped, by name, on a host without ``gcc`` on
## ``PATH`` or that is not ELF. Inside a nixpkgs dev shell the gcc wrapper
## adds ``-fPIC`` itself while ``pic`` is in ``NIX_HARDENING_ENABLE`` (the
## stdenv default), which would make that case pass whatever the edge says,
## so it runs gcc with ``pic`` removed from that variable; a gcc outside Nix
## ignores it. Measured on
## NixOS, gcc-wrapper 15.2.0, before the fix: the same ld refusal.

import std/[os, sequtils, strtabs, strutils, unittest]

import repro_project_dsl
import repro_cli_support
import repro_tool_profiles
import repro_core/ambient_execution
import repro_test_support/reasoned_skip
import repro_dsl_stdlib/types/library
import repro_dsl_stdlib/operations/toolchain
import repro_dsl_stdlib/constructors/c_library
import repro_dsl_stdlib/constructors/c_executable

const
  Recipe = "picFixture"
  HostIsElf = not (defined(macosx) or defined(windows))
  # A native build on Windows targets PE, which takes no -fPIC (clang
  # refuses it for an MSVC target); every other host's objects carry it.
  NativePic = not defined(windows)
  ZigTriple = "armv7-unknown-linux-musleabihf"

package picFixture:
  nativeBuildDeps:
    "zig >=0.13 <0.15"
  library counter:
    api:
      soname "counter"
      sover "1"
      linkKind shared
  library archived:
    api:
      soname "archived"
      linkKind static
  # Its own name: an implicit target name is registered once per package,
  # and the real-link case's link edge differs from the cases above.
  library bumper:
    api:
      soname "bumper"
      sover "1"
      linkKind shared

proc withTarget(value: string; body: proc()) =
  ## Run ``body`` with the ``--target`` variant set as the CLI sets it.
  let saved = getEnv("REPRO_VARIANTS")
  if value.len > 0: putEnv("REPRO_VARIANTS", "targetTriple=" & value)
  else: delEnv("REPRO_VARIANTS")
  try: body()
  finally:
    if saved.len > 0: putEnv("REPRO_VARIANTS", saved)
    else: delEnv("REPRO_VARIANTS")

proc inBuild(body: proc()) =
  ## One ``build:`` frame for ``Recipe``, with an empty action registry.
  resetBuildActionRegistry()
  let state = beginBuildBlock(Recipe)
  try: body()
  finally: endBuildBlock(state)

proc compileEdges(): seq[BuildActionDef] =
  ## The registered compile edges: those carrying ``-c``.
  for a in registeredBuildActions():
    if a.call.arguments.anyIt(it.name == "compileOnly"):
      result.add(a)

proc renderedArgv(a: BuildActionDef): seq[string] =
  ## The argv the engine runs for ``a``, rendered by its own ``argvForCall``:
  ## the property is what the compiler is given, not how the call records it.
  argvForCall(a.call,
    PathOnlyToolProfile(resolvedExecutablePath: a.call.executableName))

proc hasPic(a: BuildActionDef): bool =
  "-fPIC" in renderedArgv(a)

proc withoutWrapperPic(): StringTableRef =
  ## The process environment with ``pic`` taken out of
  ## ``NIX_HARDENING_ENABLE``, so a nixpkgs cc-wrapper does not add the
  ## ``-fPIC`` the edge is being tested for. The stdenv setup hook fills the
  ## variable with its defaults, ``pic`` included, and the wrapper reads it
  ## only inside such an environment; outside one an empty value is inert.
  result = newStringTable(modeCaseSensitive)
  for k, v in envPairs():
    result[k] = v
  result["NIX_HARDENING_ENABLE"] =
    getEnv("NIX_HARDENING_ENABLE").splitWhitespace().filterIt(it != "pic").join(" ")

proc argvs(edges: seq[BuildActionDef]): string =
  for e in edges: result.add(e.id & ": " & $renderedArgv(e) & "\n")

suite "a c_library or c_executable object is position-independent":

  test "gcc and clang: every object of a shared library carries -fPIC":
    for compiler in ["gcc", "clang"]:
      setCompilerOverride(compiler)
      var edges: seq[BuildActionDef]
      try:
        withTarget("", proc() =
          inBuild(proc() =
            discard c_library(into = "counter", sources = @["a.c", "b.c"])
            edges = compileEdges()))
      finally:
        setCompilerOverride("")
      checkpoint(compiler & ":\n" & argvs(edges))
      check edges.len == 2
      check edges.allIt(it.call.packageName == compiler and hasPic(it) == NativePic)

  test "gcc: a static library's objects carry -fPIC too":
    setCompilerOverride("gcc")
    defer: setCompilerOverride("")
    var edges: seq[BuildActionDef]
    withTarget("", proc() =
      inBuild(proc() =
        let lib = c_library(into = "archived", sources = @["a.c"])
        # The ``api:`` block is honoured: this is the static archive, not
        # the shared path tested a second time.
        check lib.install.outputs == @["lib/libarchived.a"]
        edges = compileEdges()))
    checkpoint(argvs(edges))
    check edges.len == 1
    check edges.allIt(hasPic(it) == NativePic)

  test "gcc: an executable's objects carry -fPIC":
    setCompilerOverride("gcc")
    defer: setCompilerOverride("")
    var edges: seq[BuildActionDef]
    withTarget("", proc() =
      inBuild(proc() =
        discard c_executable(into = "main", sources = @["main.c"])
        edges = compileEdges()))
    checkpoint(argvs(edges))
    check edges.len == 1
    check edges.allIt(hasPic(it) == NativePic)

  test "zig target: every object of a shared library carries -fPIC":
    withTarget(ZigTriple, proc() =
      inBuild(proc() =
        discard c_library(into = "counter", sources = @["a.c"])
        let edges = compileEdges()
        check edges.len == 1
        for e in edges:
          check e.call.packageName == "zig"
          check hasPic(e)))

suite "a real gcc shared link of the edges":

  test "a library whose source references a global links":
    let gcc = uncontrolledFindExe("gcc")
    if not HostIsElf or gcc.len == 0:
      skip("needs an ELF host with gcc on PATH (gcc='" & gcc & "')")
    else:
      let root = getTempDir() / ("t_pic_" & $getCurrentProcessId())
      removeDir(root)
      createDir(root)
      defer: removeDir(root)
      # A global of default visibility: -fPIE code reaches it through
      # R_X86_64_PC32, which no shared object may carry.
      writeFile(root / "bumper.c",
        "int counter;\nint bump(void) { return ++counter; }\n")
      let env = withoutWrapperPic()
      proc run(argv: seq[string]): (string, int) =
        checkpoint("$ " & argv.join(" "))
        result = uncontrolledExecCmdEx(quoteShellCommand(argv), env = env,
          workingDir = root)
        checkpoint(result[0])
      var lib: Library
      var compiles: seq[BuildActionDef]
      setCompilerOverride("gcc")
      defer: setCompilerOverride("")
      withTarget("", proc() =
        inBuild(proc() =
          lib = c_library(into = "bumper", sources = @["bumper.c"])
          compiles = compileEdges()))
      check compiles.len == 1
      let profile = PathOnlyToolProfile(resolvedExecutablePath: gcc)
      for c in compiles:
        check run(argvForCall(c.call, profile))[1] == 0
      createDir(root / "lib")
      let (linkOut, linkCode) = run(argvForCall(lib.install.call, profile))
      check linkCode == 0
      check "recompile with -fPIC" notin linkOut
      check fileExists(root / lib.install.outputs[0])
