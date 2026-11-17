## A shared library built by ``c_library`` is written under its SONAME, and
## carries that SONAME, whichever toolchain links it.
##
## C-Cpp.md §"Mode A — Fine-grained build graph (primary)": a consumer's
## ``DT_NEEDED`` is the library's SONAME, and the dynamic loader opens a file
## of exactly that name. So the library is written as
## ``lib<soname>.so.<sover>``, carries that string as its ``DT_SONAME``,
## and ``lib<soname>.so`` is a link-time symlink to it; both are declared
## outputs. Before this was fixed (reprobuild-pm issue
## 2026-11-12-stdlib-shared-libraries-get-a-soname-no-file-carries-or-none):
##
## * the gcc and clang link adapters passed no SONAME at all, so a consumer
##   recorded whatever path it was linked with and a versioned upgrade could
##   not work;
## * the zig adapter baked in the bare base name (``greet``), so a consumer
##   recorded ``DT_NEEDED greet`` -- a file nobody writes -- and failed to
##   start;
## * every adapter wrote the file as ``lib<soname>.so``, and under a zig
##   target the file NAME (not its directory) was target-keyed
##   (``libgreet.so@<triple>``), so even the right SONAME named no file.
##
## WHAT IS EXERCISED, AND WHAT IS MOCKED. Nothing is mocked. Each case opens
## a real ``build:`` frame for a registered package whose ``library`` block
## declares the ``api:``, calls ``c_library`` as a recipe does, and reads the
## edges it registered. The last case also runs the link edge: its argv is
## rendered by the engine's own ``argvForCall`` against the host's gcc,
## executed, and the result read back with ``readelf``; then a consumer is
## linked with ``-lgreet`` and started. It is skipped, by name, on a host
## without ``gcc`` and ``readelf`` on ``PATH``.

import std/[os, osproc, sequtils, strtabs, strutils, unittest]

import repro_project_dsl
import repro_cli_support
import repro_tool_profiles
import repro_core/ambient_execution
import repro_test_support/reasoned_skip
import repro_dsl_stdlib/types/library
import repro_dsl_stdlib/types/options
import repro_dsl_stdlib/operations/toolchain
import repro_dsl_stdlib/operations/link
import repro_dsl_stdlib/constructors/c_library

const
  Recipe = "sonameFixture"
  # A native build's library is ELF only on an ELF host; macOS (Mach-O)
  # and Windows (PE) have no ``DT_SONAME``, so ``c_library`` passes none
  # there. The host-native cases assert the layout the host must produce.
  HostIsElf = not (defined(macosx) or defined(windows))
  ZigTriple = "armv7-unknown-linux-musleabihf"

package sonameFixture:
  nativeBuildDeps:
    "zig >=0.13 <0.15"
  library greet:
    api:
      soname "greet"
      sover "1"
      linkKind shared
  library plain:
    api:
      soname "plain"
      linkKind shared
  library archived:
    api:
      soname "archived"
      sover "1"
      linkKind static

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

proc args(a: BuildActionDef): seq[string] =
  for arg in a.call.arguments:
    result.add(arg.name & "=" & arg.encodedValue.replace("\x1f", " "))

proc checkNativeLayout(lib: Library) =
  ## The layout every native toolchain must produce for ``greet``.
  let a = args(lib.install)
  when not HostIsElf:
    # No SONAME on a non-ELF host: the file is the link-time name.
    checkpoint("args(lib.install) was " & $a)
    check a.allIt(not it.startsWith("soname="))
    check "output=lib/libgreet.so" in a
    check lib.linkTimeName.id.len == 0
    return
  checkpoint("args(lib.install) was " & $a)
  check "soname=libgreet.so.1" in a
  check "output=lib/libgreet.so.1" in a
  check lib.install.outputs == @["lib/libgreet.so.1"]
  # The link-time name, as a symlink to the SONAME-named file.
  let ln = lib.linkTimeName
  checkpoint("linkTimeName: " & $args(ln) & " outputs=" & $ln.outputs)
  check ln.id.len > 0
  check ln.outputs == @["lib/libgreet.so"]
  check ln.deps == @[lib.install.id]
  check ln.inputs == @["lib/libgreet.so.1"]
  check "argv=ln -sfn libgreet.so.1 lib/libgreet.so" in args(ln)
  check registeredBuildActions().anyIt(it.id == ln.id)

suite "a shared library is written under its SONAME":

  test "sharedLibrarySoname derives lib<soname>.so[.<sover>]":
    check sharedLibrarySoname("greet", "1") == "libgreet.so.1"
    check sharedLibrarySoname("greet", "1.2.3") == "libgreet.so.1.2.3"
    check sharedLibrarySoname("greet", "") == "libgreet.so"

  test "gcc: the file, -Wl,-soname, and the declared output agree":
    setCompilerOverride("gcc")
    defer: setCompilerOverride("")
    withTarget("", proc() =
      inBuild(proc() =
        let lib = c_library(into = "greet", sources = @["greet.c"])
        check lib.install.call.packageName == "gcc"
        checkNativeLayout(lib)))

  test "clang: the file, -Wl,-soname, and the declared output agree":
    setCompilerOverride("clang")
    defer: setCompilerOverride("")
    withTarget("", proc() =
      inBuild(proc() =
        let lib = c_library(into = "greet", sources = @["greet.c"])
        check lib.install.call.packageName == "clang"
        checkNativeLayout(lib)))

  test "zig target: the full SONAME, the directory keyed, the file not":
    withTarget(ZigTriple, proc() =
      inBuild(proc() =
        let lib = c_library(into = "greet", sources = @["greet.c"])
        let a = args(lib.install)
        checkpoint($a)
        check lib.install.call.packageName == "zig"
        check "soname=libgreet.so.1" in a
        check ("output=lib@" & ZigTriple & "/libgreet.so.1") in a
        check lib.linkTimeName.outputs ==
          @["lib@" & ZigTriple & "/libgreet.so"]
        check ("argv=ln -sfn libgreet.so.1 lib@" & ZigTriple &
          "/libgreet.so") in args(lib.linkTimeName)))

  test "no sover: the SONAME is the link-time name, so no symlink edge":
    setCompilerOverride("gcc")
    defer: setCompilerOverride("")
    withTarget("", proc() =
      inBuild(proc() =
        let lib = c_library(into = "plain", sources = @["plain.c"])
        let a = args(lib.install)
        checkpoint($a)
        when HostIsElf:
          check "soname=libplain.so" in a
        else:
          check a.allIt(not it.startsWith("soname="))
        check "output=lib/libplain.so" in a
        check lib.linkTimeName.id.len == 0
        check registeredBuildActions().allIt(
          not it.id.startsWith("c-library-link-time-name-"))))

  test "a static library carries no SONAME and gets no symlink":
    setCompilerOverride("gcc")
    defer: setCompilerOverride("")
    withTarget("", proc() =
      inBuild(proc() =
        let lib = c_library(into = "archived", sources = @["a.c"])
        let a = args(lib.install)
        checkpoint($a)
        check a.allIt(not it.startsWith("soname="))
        check "output=lib/libarchived.a" in a
        check lib.linkTimeName.id.len == 0))

  test "a direct gcc link of an executable ignores LinkOptions.soname":
    setCompilerOverride("gcc")
    defer: setCompilerOverride("")
    withTarget("", proc() =
      inBuild(proc() =
        let exe = link(LinkOptions(
          objects: @[BuildActionDef(outputs: @["main.o"])],
          kind: lokExecutable, target: "bin/main", soname: "libx.so.1"))
        check args(exe).allIt(not it.startsWith("soname="))))

suite "a real gcc link of the edge":

  test "DT_SONAME is libgreet.so.1, and a -lgreet consumer starts":
    let gcc = uncontrolledFindExe("gcc")
    let readelf = uncontrolledFindExe("readelf")
    if not HostIsElf or gcc.len == 0 or readelf.len == 0:
      skip("needs an ELF host with gcc and readelf on PATH (gcc='" & gcc &
        "', readelf='" & readelf & "')")
    else:
      let root = getTempDir() / ("t_soname_" & $getCurrentProcessId())
      removeDir(root)
      createDir(root)
      defer: removeDir(root)
      writeFile(root / "greet.c", "int greet(void) { return 42; }\n")
      writeFile(root / "main.c",
        "int greet(void);\nint main(void) { return greet() == 42 ? 0 : 1; }\n")
      proc run(argv: seq[string]): (string, int) =
        checkpoint("$ " & argv.join(" "))
        result = uncontrolledExecCmdEx(quoteShellCommand(argv), workingDir = root)
        checkpoint(result[0])
      # The object is not under test; it is compiled position-independent
      # so the shared link is valid on every host default (PIE or not).
      check run(@[gcc, "-fPIC", "-c", "-o", "greet.c.o", "greet.c"])[1] == 0
      var lib: Library
      setCompilerOverride("gcc")
      defer: setCompilerOverride("")
      withTarget("", proc() =
        inBuild(proc() =
          lib = c_library(into = "greet", sources = @["greet.c"])))
      createDir(root / "lib")
      let profile = PathOnlyToolProfile(resolvedExecutablePath: gcc)
      check run(argvForCall(lib.install.call, profile))[1] == 0
      # The symlink edge's argv, run as the engine runs an inline exec.
      var lnArgv: seq[string]
      for arg in lib.linkTimeName.call.arguments:
        if arg.name == "argv": lnArgv = arg.encodedValue.split("\x1f")
      check lnArgv.len == 4
      check run(lnArgv)[1] == 0
      check fileExists(root / "lib/libgreet.so.1")
      check symlinkExists(root / "lib/libgreet.so")
      if symlinkExists(root / "lib/libgreet.so"):
        check expandSymlink(root / "lib/libgreet.so") == "libgreet.so.1"
      let (dyn, dynCode) = run(@[readelf, "-d", "lib/libgreet.so.1"])
      check dynCode == 0
      check "Library soname: [libgreet.so.1]" in dyn
      check run(@[gcc, "-o", "main", "main.c", "-Llib", "-lgreet"])[1] == 0
      let (needed, _) = run(@[readelf, "-d", "main"])
      check "Shared library: [libgreet.so.1]" in needed
      let (_, startCode) = uncontrolledExecCmdEx("./main", workingDir = root,
        env = newStringTable({"LD_LIBRARY_PATH": root / "lib"}))
      check startCode == 0
