## Spec-Implementation M5 — end-to-end cross-compilation verification.
##
## Drives the cross-aarch64-linux-gnu adapter through the M3 active
## build-context machinery (so the active-context resolution path is
## exercised), reads back the resolved ``Toolchain``'s ``compile`` /
## ``link`` argv, executes the argv against the fixture's C source,
## and asserts the produced binary is an aarch64 ELF.
##
## Per the milestone brief, the e2e build itself must succeed when a
## cross gcc is available. The test discovers cross-gcc through three
## probes (same order as the adapter itself):
##   1. The ``REPRO_AARCH64_GCC`` env var.
##   2. ``aarch64-linux-gnu-gcc`` on ``$PATH``.
##   3. ``aarch64-unknown-linux-gnu-gcc`` on ``$PATH`` (nixpkgs name).
##
## When none of the three resolves the test reports the probe failure
## via ``checkpoint`` and skips the execution sub-test — the
## ``Toolchain.compile`` interface assertion still runs (it doesn't
## need the binary on disk).
##
## Optional sub-step: when ``qemu-aarch64`` is on ``$PATH`` the test
## runs the produced binary under emulation and asserts its exit code
## and stdout. When qemu-user is missing the run sub-step is skipped.

import std/[os, osproc, strutils, unittest]

import repro_dsl_stdlib
import repro_dsl_stdlib/configurables

import repro_project_dsl

proc findOnPath(binary: string): string =
  let pathEnv = getEnv("PATH")
  if pathEnv.len == 0:
    return ""
  for entry in pathEnv.split(PathSep):
    if entry.len == 0:
      continue
    let candidate = entry / binary
    if fileExists(candidate):
      return candidate
  ""

proc findCrossGcc(): string =
  let envOverride = getEnv("REPRO_AARCH64_GCC")
  if envOverride.len > 0 and fileExists(envOverride):
    return envOverride
  let canonical = findOnPath("aarch64-linux-gnu-gcc")
  if canonical.len > 0:
    return canonical
  let nixForm = findOnPath("aarch64-unknown-linux-gnu-gcc")
  if nixForm.len > 0:
    return nixForm
  ""

proc reproRoot(): string =
  var dir = currentSourcePath().parentDir
  while dir.len > 1:
    if fileExists(dir / "Justfile"):
      return dir
    let parent = dir.parentDir
    if parent == dir:
      break
    dir = parent
  raise newException(IOError,
    "cannot locate reprobuild repo root from " & currentSourcePath())

proc declareTargetTripleVariant() =
  let info = instantiationInfo(fullPaths = true)
  let site = newSourceSite(info.filename, info.line, info.column, ckDefault)
  discard declareVariant[string](
    defaultValue = "native",
    scopeName = "targetTriple",
    description = "",
    explicitId = "",
    descriptionFile = "",
    descriptionLine = 0,
    descriptionColumn = 0,
    site = site)

suite "Spec-Implementation M5: cross-compilation aarch64 e2e":

  setup:
    resetVariantState()

  test "active context's toolchain produces a cross-aarch64 compile argv":
    addVariantCliOverride("targetTriple", "aarch64-linux-gnu")
    declareTargetTripleVariant()
    finalizeVariants()
    let state = beginBuildBlock("cross_compilation")
    try:
      let ctx = currentBuildContext()
      let action = ctx.toolchain.compile(
        "src/hello.c", "build/obj/hello.o", @[])
      check action.argv.len >= 4
      check action.argv[0].contains("aarch64")
      check "-c" in action.argv
      check action.inputs == @["src/hello.c"]
      check action.outputs == @["build/obj/hello.o"]
    finally:
      endBuildBlock(state)

  test "cross gcc + link produces an aarch64 ELF binary":
    let crossGcc = findCrossGcc()
    if crossGcc.len == 0:
      checkpoint("no aarch64 cross-gcc available on this host;")
      checkpoint("set REPRO_AARCH64_GCC=/path/to/aarch64-linux-gnu-gcc")
      checkpoint("or install gcc-aarch64-linux-gnu to enable this test")
      skip()
    else:
      let root = reproRoot()
      let fixtureRoot =
        root / "tests" / "fixtures" / "spec-examples" / "cross-compilation"
      let sourcePath = fixtureRoot / "src" / "hello.c"
      check fileExists(sourcePath)

      let workRoot = root / "build" / "test-tmp" / "cross-compilation-e2e"
      createDir(workRoot)
      let objPath = workRoot / "hello.o"
      let binPath = workRoot / "hello"
      removeFile(objPath)
      removeFile(binPath)

      # Wire the adapter through the active build context — same
      # codepath ``repro build --variant targetTriple=aarch64-linux-gnu
      # build`` would take.
      putEnv("REPRO_AARCH64_GCC", crossGcc)
      try:
        addVariantCliOverride("targetTriple", "aarch64-linux-gnu")
        declareTargetTripleVariant()
        finalizeVariants()
        let state = beginBuildBlock("cross_compilation")
        var compileArgv: seq[string]
        var linkArgv: seq[string]
        try:
          let ctx = currentBuildContext()
          check ctx.toolchain.name == "cross-aarch64-linux-gnu-toolchain"
          compileArgv = ctx.toolchain.compile(
            sourcePath, objPath, @[]).argv
          linkArgv = ctx.toolchain.link(
            @[objPath], binPath, @[]).argv
        finally:
          endBuildBlock(state)

        check compileArgv.len > 0
        check linkArgv.len > 0
        check compileArgv[0] == crossGcc
        check linkArgv[0] == crossGcc

        # Execute the compile + link directly. The engine's full
        # provisioning path is overkill for the e2e check — we already
        # know the active-context picked the right adapter; what we
        # want to verify is that the chosen argv actually produces an
        # aarch64 binary.
        let compileResult = execProcess(crossGcc,
          args = compileArgv[1 .. ^1],
          options = {poStdErrToStdOut, poUsePath})
        checkpoint("compile output:\n" & compileResult)
        check fileExists(objPath)

        let linkResult = execProcess(crossGcc,
          args = linkArgv[1 .. ^1],
          options = {poStdErrToStdOut, poUsePath})
        checkpoint("link output:\n" & linkResult)
        check fileExists(binPath)

        # Verify the binary's architecture via ``file``. The output
        # contains ``ELF 64-bit LSB`` + ``ARM aarch64`` on every
        # modern ``file`` build.
        let fileOutput = execProcess("file",
          args = @[binPath], options = {poUsePath, poStdErrToStdOut})
        checkpoint("file output: " & fileOutput)
        check "ELF" in fileOutput
        check "aarch64" in fileOutput
        check "ARM" in fileOutput

        # Optional: run under qemu-user when available.
        let qemu = findOnPath("qemu-aarch64")
        if qemu.len == 0:
          checkpoint("qemu-aarch64 not on PATH; skipping run sub-step")
        else:
          let runResult = execCmdEx(qemu & " " & binPath)
          checkpoint("qemu run exit=" & $runResult.exitCode)
          checkpoint("qemu run output: " & runResult.output)
          check runResult.exitCode == 0
          check "hello from a cross-compiled binary" in runResult.output
      finally:
        delEnv("REPRO_AARCH64_GCC")
