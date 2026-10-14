## The C compiler that compiles a recipe is chosen on purpose, and a bad one
## is refused by name.
##
## ## The defect this pins
##
## Measured 2026-09-23 on a Windows workstation: every `repro exec` (so every
## `just` recipe of the Agent Harbor repository, whose Justfile runs recipes
## through it) died compiling the recipe with
##
##     M:\m\dev\reprobuild\libs\blake3\src\blake3\capi.c:1: stddef.h: No such file or directory
##
## from a `gcc.exe` nobody had chosen: the Machine PATH listed FPC's install,
## which ships a 1999-era i386 gcc 2.95, and Windows puts the Machine PATH ahead
## of the User PATH. The recipe compile had been handed no `--gcc.exe` at all,
## so Nim looked `gcc.exe` up on PATH itself, silently. The diagnostic named a
## C file of reprobuild's, not the compiler, and gave no way out.
##
## What this file holds the selection to:
##
## * a compiler that cannot compile a trivial translation unit including
##   `<stddef.h>` is refused, and the refusal names the compiler, where it was
##   selected from, the compiler's own complaint, and `REPRO_BOOTSTRAP_CC`;
## * a `REPRO_BOOTSTRAP_CC` that does not name a file is an error, not a reason
##   to fall through to some other compiler;
## * on Windows, where there is no system `cc`, the last-resort `gcc.exe` from
##   PATH is probed before use, and an unusable one is refused rather than
##   handed to Nim.
##
## The pinned compiler that ends up being published instead is covered by
## `libs/repro_tool_profiles/tests/t_bootstrap_cc_override_is_honoured_and_scoped.nim`
## and, end to end, by `tests/e2e/dev-env/t_e2e_repro_exec_recipe_compiler.nim`.

import std/[os, osproc, strutils, tempfiles, unittest]

import repro_interface_artifacts
when defined(macosx):
  import repro_core/c_compiler

proc writeUnrunnableCompiler(dir: string): string =
  ## A file named like a compiler that is not a program at all: the portable
  ## stand-in for "a compiler that exists on PATH but cannot do the job". Its
  ## probe fails at process creation on Windows and at `exec` on POSIX, which
  ## is exactly the class of failure the probe must turn into a diagnostic.
  result = dir / addFileExt("gcc", ExeExt)
  writeFile(result, "this is not a compiler\n")
  setFilePermissions(result, {fpUserRead, fpUserWrite, fpUserExec})

template withEnv(names: openArray[string]; body: untyped) =
  var saved: seq[tuple[name: string; present: bool; value: string]]
  for name in names:
    saved.add((name: name, present: existsEnv(name), value: getEnv(name)))
  try:
    body
  finally:
    for entry in saved:
      if entry.present: putEnv(entry.name, entry.value)
      else: delEnv(entry.name)

suite "probing the recipe-compile C compiler":

  test "an unrunnable compiler is unusable, and the probe says why":
    let dir = createTempDir("repro-cc-probe-test-", "")
    defer: removeDir(dir)
    let fake = writeUnrunnableCompiler(dir)
    let probe = probeCCompiler(fake)
    check not probe.usable
    check probe.compiler == fake
    check probe.detail.len > 0

  test "a missing compiler is unusable without running anything":
    let probe = probeCCompiler(getTempDir() / "no-such-dir-repro" /
      addFileExt("gcc", ExeExt))
    check not probe.usable
    check probe.detail == "no such file"

  test "the refusal names the compiler, its origin, and the override":
    let dir = createTempDir("repro-cc-probe-test-", "")
    defer: removeDir(dir)
    let fake = writeUnrunnableCompiler(dir)
    var raised = false
    try:
      requireUsableCCompiler(fake, "the first gcc.exe on PATH")
    except CCompilerUnusableError as err:
      raised = true
      check fake in err.msg
      check "selected from: the first gcc.exe on PATH" in err.msg
      check "<stddef.h>" in err.msg
      check bootstrapCCompilerEnv in err.msg
    check raised

  test "a failed probe is never remembered as a success":
    # The marker cache must only ever record SUCCESS: a probe that failed is
    # usually fixed in the environment, and the next run has to see the fix.
    let dir = createTempDir("repro-cc-probe-test-", "")
    defer: removeDir(dir)
    let cacheDir = dir / "cache"
    let fake = writeUnrunnableCompiler(dir)
    check not probeCCompiler(fake, cacheDir).usable
    var markers = 0
    if dirExists(cacheDir):
      for _ in walkDir(cacheDir):
        inc markers
    check markers == 0

suite "selecting the recipe-compile C compiler":

  test "a REPRO_BOOTSTRAP_CC that names no file is an error, not a fallthrough":
    withEnv([bootstrapCCompilerEnv]):
      for bogus in ["gcc", getTempDir() / "no-such-dir-repro" /
          addFileExt("gcc", ExeExt)]:
        putEnv(bootstrapCCompilerEnv, bogus)
        var raised = false
        try:
          discard recipeCCompilerPath()
        except CCompilerUnusableError as err:
          raised = true
          check (bootstrapCCompilerEnv & "=" & bogus) in err.msg
          check "does not name an existing file" in err.msg
        check raised

  test "a REPRO_BOOTSTRAP_CC that names a file is what the compile gets":
    withEnv([bootstrapCCompilerEnv]):
      let dir = createTempDir("repro-cc-select-test-", "")
      defer: removeDir(dir)
      let chosen = writeUnrunnableCompiler(dir)
      putEnv(bootstrapCCompilerEnv, chosen)
      # Selection honours the explicit choice verbatim; whether it WORKS is
      # checked once, where it is published (ensureBootstrapToolchainEnv).
      check recipeCCompilerPath() == chosen

  when defined(windows):
    test "an unusable gcc.exe on PATH is refused, not handed to Nim":
      withEnv([bootstrapCCompilerEnv, "CC", "PATH"]):
        let dir = createTempDir("repro-cc-path-test-", "")
        defer: removeDir(dir)
        let fake = writeUnrunnableCompiler(dir)
        delEnv(bootstrapCCompilerEnv)
        delEnv("CC")
        # PATH = that directory alone: its gcc.exe is the first (only) one,
        # the position FPC's gcc 2.95 held on the affected host.
        putEnv("PATH", dir)
        var raised = false
        try:
          discard recipeCCompilerPath()
        except CCompilerUnusableError as err:
          raised = true
          check fake in err.msg
          check "the first gcc.exe on PATH" in err.msg
          check bootstrapCCompilerEnv in err.msg
        check raised

    test "no gcc.exe anywhere is said plainly":
      withEnv([bootstrapCCompilerEnv, "CC", "PATH"]):
        let dir = createTempDir("repro-cc-path-test-", "")
        defer: removeDir(dir)
        delEnv(bootstrapCCompilerEnv)
        delEnv("CC")
        putEnv("PATH", dir)
        var raised = false
        try:
          discard recipeCCompilerPath()
        except CCompilerUnusableError as err:
          raised = true
          check "there is no gcc.exe on PATH" in err.msg
        check raised

when defined(macosx):
  suite "Darwin recipe compilers reach platform frameworks":
    test "implicit selection prefers real clang over an earlier nixpkgs gcc cc":
      # Real compiler aliases recreate the consumer's PATH ordering without
      # replacing compiler behavior: GCC must actually fail on the framework
      # header, and the selected compiler must actually compile it.
      let gcc = getEnv("REPRO_TEST_DARWIN_GCC", findExe("gcc"))
      let clang = findExe("clang")
      doAssert gcc.len > 0 and cCompilerFamily(gcc) == "gcc",
        "this regression requires a real GCC (run in the Nix dev shell)"
      doAssert clang.len > 0 and cCompilerFamily(clang) == "clang"
      let dir = createTempDir("repro-darwin-compiler-", "")
      defer: removeDir(dir)
      createDir(dir / "gcc-first")
      createDir(dir / "clang-second")
      createSymlink(gcc, dir / "gcc-first" / "cc")
      createSymlink(clang, dir / "clang-second" / "clang")
      let source = dir / "framework.c"
      writeFile(source, "#include <Security/SecRandom.h>\nint repro_framework(void) { return 0; }\n")
      let rejected = execCmdEx(quoteShell(gcc) & " -c " & quoteShell(source) &
        " -o " & quoteShell(dir / "gcc.o"))
      check rejected.exitCode != 0
      check "Security/SecRandom.h" in rejected.output
      withEnv([bootstrapCCompilerEnv, "CC", "PATH"]):
        delEnv(bootstrapCCompilerEnv)
        delEnv("CC")
        putEnv("PATH", dir / "gcc-first" & $PathSep & dir / "clang-second" &
          $PathSep & getEnv("PATH"))
        let chosen = recipeCCompilerPath()
        check cCompilerFamily(chosen) == "clang"
        let compiled = execCmdEx(quoteShell(chosen) & " -c " & quoteShell(source) &
          " -o " & quoteShell(dir / "clang.o"))
        check compiled.exitCode == 0
        check fileExists(dir / "clang.o")
        putEnv(bootstrapCCompilerEnv, gcc)
        check recipeCCompilerPath() == gcc
        delEnv(bootstrapCCompilerEnv)
        putEnv("CC", gcc)
        check recipeCCompilerPath() == gcc
        delEnv("CC")
        putEnv("PATH", dir / "gcc-first")
        check recipeCCompilerPath() == gcc

    test "framework-incompatible GCC is refused with compiler SDK and remedy":
      let gcc = getEnv("REPRO_TEST_DARWIN_GCC", findExe("gcc"))
      doAssert gcc.len > 0 and cCompilerFamily(gcc) == "gcc"
      let probe = probeCCompiler(gcc)
      check not probe.usable
      check "Security/SecRandom.h" in probe.detail
      let diagnostic = cCompilerUnusableMessage(probe, "explicit compiler")
      check gcc in diagnostic
      check "SDKROOT" in diagnostic
      check getEnv("SDKROOT") in diagnostic
      check bootstrapCCompilerEnv in diagnostic

    test "a cached clang success is invalidated when wrapper header flags change":
      let clang = findExe("clang")
      doAssert clang.len > 0 and cCompilerFamily(clang) == "clang"
      let dir = createTempDir("repro-darwin-probe-cache-", "")
      defer: removeDir(dir)
      withEnv(["NIX_CFLAGS_COMPILE"]):
        check probeCCompiler(clang, dir).usable
        # This real wrapper flag makes C headers unavailable. A cached success
        # from the previous environment must not conceal the compiler failure.
        putEnv("NIX_CFLAGS_COMPILE", getEnv("NIX_CFLAGS_COMPILE") & " -nostdinc")
        let invalid = probeCCompiler(clang, dir)
        check not invalid.usable
        check "stddef.h" in invalid.detail

    test "disk probe markers preserve case-sensitive compiler flags":
      let clang = findExe("clang")
      doAssert clang.len > 0 and cCompilerFamily(clang) == "clang"
      let dir = createTempDir("repro-darwin-probe-case-", "")
      defer: removeDir(dir)
      let includeDir = dir / "headers"
      createDir(includeDir)
      let cacheDir = dir / "cache"
      withEnv(["NIX_CFLAGS_COMPILE"]):
        let original = getEnv("NIX_CFLAGS_COMPILE")
        putEnv("NIX_CFLAGS_COMPILE", original & " -I" & includeDir)
        check probeCCompiler(clang, cacheDir).usable
        var markers = 0
        for kind, path in walkDir(cacheDir):
          if kind == pcFile and path.endsWith(".ok"):
            inc markers
        check markers == 1
        # -I is a valid include-directory flag; -i is an invalid clang option.
        # The memo keys differ, so an incorrectly lowercased disk-marker name
        # is the only way the second call can inherit the first call's success.
        putEnv("NIX_CFLAGS_COMPILE", original & " -i" & includeDir)
        let invalid = probeCCompiler(clang, cacheDir)
        check not invalid.usable
        check "unknown argument" in invalid.detail
        check "-i" & includeDir in invalid.detail
