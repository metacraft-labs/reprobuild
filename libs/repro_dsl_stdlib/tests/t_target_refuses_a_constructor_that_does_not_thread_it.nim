## Under a non-native `--target`, a constructor that does not thread the
## target refuses before it emits anything.
##
## ReproOS-Add-On-Mode A15. Before the guard, `repro build --target=armv7-…`
## of a recipe built with `autotools_package` exited 0 with an x86-64
## `libz.so` mirrored under `install@armv7-…` and a cache identity that said
## armv7. Every constructor except `cargo_package` ignored the CrossTarget
## slot. `requireCrossTargetConsulted` is now the first statement of each of
## them, and of the `compile` / `link` / `nim.c` operations the C and Nim
## constructors reach.
##
## WHAT IS EXERCISED, AND WHAT IS MOCKED. Nothing is mocked. Each case opens
## a real `build:` frame (`beginBuildBlock`, what the lowered `build:` body
## calls), sets the target the way `--target` does (`REPRO_VARIANTS`), calls
## the constructor as a recipe does, and reads the action registry the
## engine would emit from. "Nothing emitted" is the registry being empty
## after the refusal. The end-to-end half (exit status, no `install@<triple>`
## mirror, nothing in the store) is
## `tests/integration/t_target_build_refuses_a_recipe_that_does_not_thread_it`.

import std/[os, sequtils, strutils, unittest]

import repro_project_dsl
import repro_dsl_stdlib/active_context
import repro_dsl_stdlib/toolchain_policy
import repro_dsl_stdlib/operations/compile
import repro_dsl_stdlib/operations/link
import repro_dsl_stdlib/types/options
import repro_dsl_stdlib/constructors/c_executable
import repro_dsl_stdlib/constructors/nim_executable
import repro_dsl_stdlib/constructors/nim_library
import repro_dsl_stdlib/constructors/cmake_package
import repro_dsl_stdlib/constructors/autotools_package
import repro_dsl_stdlib/constructors/meson_package
import repro_dsl_stdlib/constructors/go_package
import repro_dsl_stdlib/constructors/cabal_package
import repro_dsl_stdlib/constructors/node_package
import repro_dsl_stdlib/constructors/cargo_package

const
  # The guard's triple: a cross target no adapter threads for the C
  # operations (the generic stub), so every non-threading constructor
  # refuses. A zig target is threaded by `compile` / `link` / `archive`
  # (`operations/zig_c`), so it is `ZigTriple`, below.
  Triple = "riscv64-unknown-linux-gnu"
  ZigTriple = "armv7-unknown-linux-musleabihf"
  Recipe = "hostOnlyProbe"

proc withTarget(value: string; body: proc()) =
  let saved = getEnv("REPRO_VARIANTS")
  if value.len > 0: putEnv("REPRO_VARIANTS", "targetTriple=" & value)
  else: delEnv("REPRO_VARIANTS")
  try: body()
  finally:
    if saved.len > 0: putEnv("REPRO_VARIANTS", saved)
    else: delEnv("REPRO_VARIANTS")

proc inBuild(body: proc()) =
  ## One `build:` frame for `Recipe`, with an empty action registry.
  resetBuildActionRegistry()
  let state = beginBuildBlock(Recipe)
  try: body()
  finally: endBuildBlock(state)

proc refusal(call: proc()): string =
  ## The refusal's message, or "" when `call` did not raise.
  try:
    call()
  except ValueError as e:
    return e.msg
  ""

proc checkRefused(caller: string; call: proc()) =
  let msg = refusal(call)
  checkpoint(caller & " -> " & msg)
  check msg.len > 0
  check ("recipe '" & Recipe & "'") in msg
  check caller in msg
  check Triple in msg
  check registeredBuildActions().len == 0

suite "--target refuses every constructor that does not thread it":

  test "each refuses before emitting, naming the recipe, itself and the target":
    withTarget(Triple, proc() =
      let cases: seq[(string, proc())] = @[
        ("compile", proc() =
          discard compile("src/a.c", "build/a.o")),
        ("link", proc() =
          discard link(@[], "build/a")),
        ("compile", proc() =
          discard c_executable("hello", @["src/hello.c"])),
        ("nim_executable", proc() =
          discard nim_executable("hello", "src/hello.nim")),
        ("nim_library", proc() =
          discard nim_library("hello", "src/hello.nim")),
        ("cmake_package", proc() =
          discard cmake_package("src")),
        ("autotools_package", proc() =
          discard autotools_package("src")),
        ("meson_package", proc() =
          discard meson_package("src")),
        ("go_package", proc() =
          discard go_package("hello")),
        ("cabal_package", proc() =
          discard cabal_package("exe:hello")),
        ("node_package", proc() =
          discard node_package(entry = "bundle/hello.js")),
      ]
      for i in 0 ..< cases.len:
        let caller = cases[i][0]
        let call = cases[i][1]
        inBuild(proc() = checkRefused(caller, call)))

  test "outside a build: block the refusal is unconditional":
    withTarget(Triple, proc() =
      resetBuildActionRegistry()
      setCurrentOwningPackageOverride(Recipe)
      defer: clearCurrentOwningPackageOverride()
      checkRefused("compile", proc() =
        discard compile("src/a.c", "build/a.o")))

suite "what the guard lets through":

  test "a native build is unchanged":
    withTarget("", proc() =
      inBuild(proc() =
        check refusal(proc() =
          discard compile("src/a.c", "build/a.o")) == ""
        check registeredBuildActions().len == 1))
    withTarget("native", proc() =
      inBuild(proc() =
        check refusal(proc() =
          discard compile("src/a.c", "build/a.o")) == ""))

  test "a recipe that read activeCrossTarget() threads it itself":
    withTarget(Triple, proc() =
      inBuild(proc() =
        check activeCrossTarget().triple == Triple
        let msg = refusal(proc() =
          discard compile("src/a.c", "build/a.o"))
        checkpoint(msg)
        check msg == ""
        check registeredBuildActions().len == 1))

  test "cargo_package is cross-aware and does not lift the guard for others":
    withTarget(ZigTriple, proc() =
      inBuild(proc() =
        setCurrentOwningPackageOverride(Recipe)
        defer: clearCurrentOwningPackageOverride()
        let res = cargo_package()
        check res.compileEdge.id.len > 0
        let emitted = registeredBuildActions().len
        # A neighbour that does not thread a zig target (cmake_package and
        # autotools_package now do).
        let msg = refusal(proc() = discard meson_package("src"))
        check "meson_package" in msg
        check registeredBuildActions().len == emitted))

suite "nested frames, helper reads and host triples":

  test "a read in the package's build: covers an artifact frame nested in it":
    withTarget(Triple, proc() =
      inBuild(proc() =
        discard activeCrossTarget()
        let inner = beginBuildBlock(Recipe, ownerKind = "executable",
          ownerName = "hello")
        try:
          check refusal(proc() =
            discard compile("src/a.c", "build/a.o")) == ""
        finally:
          endBuildBlock(inner)))

  test "a read in another package's enclosing frame does not cover this one":
    withTarget(Triple, proc() =
      inBuild(proc() =
        discard activeCrossTarget()
        let other = beginBuildBlock("someOtherPackage")
        try:
          check "compile" in refusal(proc() =
            discard compile("src/a.c", "build/a.o"))
        finally:
          endBuildBlock(other)))

  test "a helper reading through peekActiveCrossTarget lifts nothing":
    withTarget(Triple, proc() =
      inBuild(proc() =
        proc helper(): string = peekActiveCrossTarget().triple
        check helper() == Triple
        let inner = beginBuildBlock(Recipe, ownerKind = "executable",
          ownerName = "hello")
        try:
          check helper() == Triple
          check "compile" in refusal(proc() =
            discard compile("src/a.c", "build/a.o"))
        finally:
          endBuildBlock(inner)
        check "compile" in refusal(proc() =
          discard compile("src/a.c", "build/a.o"))))

  test "--target naming the build host is native: no refusal":
    when defined(linux) and defined(amd64):
      for host in ["x86_64-unknown-linux-gnu", "x86_64-pc-linux-gnu"]:
        withTarget(host, proc() =
          check not isCrossTriple(host)
          check activeTargetTriple() == ""
          check activeTargetTripleTag() == ""
          inBuild(proc() =
            check refusal(proc() =
              discard compile("src/a.c", "build/a.o")) == ""))
      check isCrossTriple("x86_64-unknown-linux-musl")
    check isCrossTriple(Triple)
    check not isCrossTriple("native")

suite "declared object-check exemptions":
  proc exemptionsEnvOf(a: BuildActionDef): string =
    for (k, v) in a.env:
      if k == "REPRO_TARGET_OBJECT_EXEMPTIONS": return v

  test "every action the package emits carries its exemptions":
    inBuild(proc() =
      targetObjectExemption("usr/lib/bpf/prog.o", "an eBPF program")
      let first = buildAction(id = "x-first", call = inlineExecCall(@["true"]))
      let inner = beginBuildBlock(Recipe, ownerKind = "executable",
        ownerName = "hello")
      try:
        let nested = buildAction(id = "x-nested",
          call = inlineExecCall(@["true"]))
        check exemptionsEnvOf(nested) == "usr/lib/bpf/prog.o\tan eBPF program"
      finally:
        endBuildBlock(inner)
      check exemptionsEnvOf(first) == "usr/lib/bpf/prog.o\tan eBPF program")

  test "an exemption after the package emitted an action is refused":
    inBuild(proc() =
      discard buildAction(id = "x-early", call = inlineExecCall(@["true"]))
      check "after the package emitted an action" in refusal(proc() =
        targetObjectExemption("usr/lib/fw.bin", "firmware")))

  test "a duplicate, a pattern and a missing reason are refused":
    inBuild(proc() =
      targetObjectExemption("usr/lib/fw.bin", "firmware")
      check "declared twice" in refusal(proc() =
        targetObjectExemption("usr/lib/fw.bin", "again"))
      check refusal(proc() =
        targetObjectExemption("usr/lib/*.bin", "firmware")).len > 0
      check "no reason" in refusal(proc() =
        targetObjectExemption("usr/lib/other.bin", "")))

  test "a new evaluation of the package starts with no exemptions or seal":
    inBuild(proc() =
      targetObjectExemption("usr/lib/fw.bin", "firmware")
      discard buildAction(id = "x-a", call = inlineExecCall(@["true"])))
    inBuild(proc() =
      targetObjectExemption("usr/lib/other.bin", "firmware")
      let a = buildAction(id = "x-b", call = inlineExecCall(@["true"]))
      check exemptionsEnvOf(a) == "usr/lib/other.bin\tfirmware")

suite "a zig target is threaded into the C operations":
  proc argStrings(a: BuildActionDef): seq[string] =
    for arg in a.call.arguments:
      result.add(arg.name & "=" & arg.encodedValue.replace("\x1f", " "))

  test "compile, link and c_executable emit zig cc with the target's flags":
    withTarget(ZigTriple, proc() =
      inBuild(proc() =
        let o = compile("src/a.c", "build/a.o")
        check o.call.packageName == "zig"
        check o.call.subcommand == "cc"
        let args = argStrings(o)
        checkpoint($args)
        check args.anyIt(it.startsWith(
          "targetArgs=-target arm-linux-musleabihf -mcpu="))
        check "sources=src/a.c" in args
        check "compileOnly=true" in args
        let o2 = compile("src/b.c", "build/b.o")
        let exe = link(@[o, o2], "build/hello")
        check exe.call.subcommand == "cc"
        # Every object, not only the first; each at its target-keyed path.
        check "output=build@" & ZigTriple & "/a.o" in args
        check "sources=build@" & ZigTriple & "/a.o build@" & ZigTriple &
          "/b.o" in argStrings(exe)
        check "output=build/hello@" & ZigTriple in argStrings(exe) or
          "output=build@" & ZigTriple & "/hello" in argStrings(exe)
        let before = registeredBuildActions().len
        discard c_executable("hello2", @["src/hello.c"])
        check registeredBuildActions().len > before))

  test "a static library is a zig ar archive":
    withTarget(ZigTriple, proc() =
      inBuild(proc() =
        let o = compile("src/a.c", "build/a.o")
        let lib = link(LinkOptions(objects: @[o], kind: lokStatic,
          target: "build/liba.a"))
        check lib.call.packageName == "zig"
        check lib.call.subcommand == "ar"
        check "archive=build@" & ZigTriple & "/liba.a" in argStrings(lib)))

  test "a native build still emits the native compiler, at the bare path":
    withTarget("", proc() =
      inBuild(proc() =
        let o = compile("src/a.c", "build/a.o")
        check o.call.packageName != "zig"
        check "build/a.o" in o.outputs
        check nim_executable("hello", "src/hello.nim").install.outputs.anyIt(
          it.endsWith("hello") and "@" notin it)))

  test "a registered package that does not declare zig is refused":
    withTarget(ZigTriple, proc() =
      inBuild(proc() =
        # `Recipe` is not a registered package here; register a frame for
        # one that is: the stdlib's own `zig` package does not declare zig
        # as a native dependency of itself.
        let other = beginBuildBlock("zig")
        try:
          let msg = refusal(proc() = discard compile("src/a.c", "build/a.o"))
          checkpoint(msg)
          check "does not declare `zig` in `nativeBuildDeps:`" in msg
        finally:
          endBuildBlock(other)))

  test "nim_executable and nim_library build for the zig target":
    withTarget(ZigTriple, proc() =
      inBuild(proc() =
        let exe = nim_executable("hello", "src/hello.nim")
        let args = argStrings(exe.install)
        checkpoint($args)
        check "cpu=arm" in args
        check "os=linux" in args
        # Keyed output, so the native build's `hello` is a different file.
        check "output=hello@" & ZigTriple in args
        check "cc=clang" in args
        check args.anyIt(it.startsWith("clangExe=") and
          it.endsWith("/" & ZigTriple & "/wrappers/cc") or
          (it.startsWith("clangExe=") and it.endsWith("/cc")))
        var wrapperIds: seq[string]
        for a in registeredBuildActions():
          if a.id.startsWith("zig-cross-wrappers-"): wrapperIds.add(a.id)
        check wrapperIds.len == 1
        check wrapperIds[0] in exe.install.deps
        let lib = nim_library("hello", "src/hello.nim")
        check "cpu=arm" in argStrings(lib.install)))

  test "cmake_package configures with a toolchain file naming the wrappers":
    withTarget(ZigTriple, proc() =
      inBuild(proc() =
        setCurrentOwningPackageOverride(Recipe)
        defer: clearCurrentOwningPackageOverride()
        discard cmake_package("src")
        var configure: BuildActionDef
        var wrappers = ""
        for a in registeredBuildActions():
          if a.call.subcommand == "configure": configure = a
          if a.id.startsWith("zig-cross-wrappers-"): wrappers = a.id
        check wrappers.len > 0
        let args = argStrings(configure).join("\n")
        checkpoint(args)
        check "CMAKE_TOOLCHAIN_FILE=" in args
        check "toolchain.cmake" in args))

  test "autotools_package configures with the zig toolchain and --host":
    withTarget(ZigTriple, proc() =
      inBuild(proc() =
        setCurrentOwningPackageOverride(Recipe)
        defer: clearCurrentOwningPackageOverride()
        discard autotools_package("src")
        var configure: BuildActionDef
        var wrappers = ""
        for a in registeredBuildActions():
          if a.commandStatsId == "autotools_package.configure": configure = a
          if a.id.startsWith("zig-cross-wrappers-"): wrappers = a.id
        check wrappers.len > 0
        check wrappers in configure.deps
        var cc = ""
        for (k, v) in configure.env:
          if k == "CC": cc = v
        check cc.endsWith("/" & ZigTriple & "/wrappers/cc") or cc.endsWith("/cc")
        let script = argStrings(configure).join(" ")
        checkpoint(script)
        check "Generated by GNU Autoconf" in script
        check "--host=arm-linux-musleabihf" in script))
