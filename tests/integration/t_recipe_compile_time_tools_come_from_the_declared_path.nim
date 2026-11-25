## A program a recipe starts at compile time is found on the `PATH` the
## recipe compile declares, never on the caller's: a tool that only the
## caller's shell can see is not found by the interface extraction or by the
## provider compile, and the build still succeeds.
##
## WHY. The engine's two recipe compiles, the interface extraction and the
## provider compile, declare their `PATH`: the directories of the Nim and C
## compilers they run (`recipeCompilePathEnv`; Hermetic-Builds-And-Path-
## Independence.md, "The action's `PATH`" and "Engine-internal recipe
## compiles"). The provider compile has done so since 2026-09-28; the
## extraction inherited the caller's `PATH` until reprobuild a956a1b0dab.
## Recipe code that runs a program by bare name at compile time
## (`staticExec`, `gorgeEx`) is evaluated by both compiles, so with the
## extraction inheriting, the same line resolved the caller's tool while the
## interface was lifted and no tool while the provider was compiled: the two
## halves of one recipe saw two different programs, and a tool prepended to
## the caller's `PATH` decided the interface without being an input of it.
## A tool-only `PATH` for the extraction was once rejected because a large
## recipe's compile looked up shell tools on `PATH`; that recipe now extracts
## under the declared `PATH`, so this test is the standing check that a
## recipe resolving a tool on `PATH` at compile time sees the declared
## `PATH` in both compiles.
##
## THE FIXTURE. The recipe runs the stub tool twice in each compile:
##   * by BARE NAME (`xrecipetoolprobe`). The stub's directory is first on the
##     caller's `PATH` and on no declared one, so neither compile may find it.
##     A run of it logs `<compile> bare` to the witness file;
##   * by ABSOLUTE PATH, the spelling the spec tells a recipe to use for a
##     program outside the compilers' directories. It must run in both
##     compiles: it logs `<compile> absolute`. This is the vacuity guard --
##     it proves the recipe's compile-time code ran in each compile, so the
##     absence of a `bare` line means the tool was not found, not that the
##     line never executed.
## `<compile>` is `interface` under `--define:reproInterfaceMode` and
## `provider` otherwise. The bare run's exit code reaches the built product
## through the provider, so the test also sees that the recipe was told the
## tool is missing (non-zero) rather than handed some other program.
##
## A control run of the stub from the test itself, through the same caller
## `PATH`, proves the stub is executable and resolvable there: without it a
## broken stub would pass every assertion above.
##
## MOCK POLICY - one stand-in: the stub tool is a three-line shell script
## that appends its argument to a witness file. It stands for any host tool
## a recipe could name; the property under test is where the compile looks
## for it, which the real `build/bin/repro` and the real Nim and C compilers
## decide. No engine component is mocked.

import std/[os, osproc, strutils, unittest]
import repro_test_support/reasoned_skip

const ProbeTool = "xrecipetoolprobe"

proc recipeFor(stubPath: string): string =
  ## The fixture recipe. `stubPath` is the stub's absolute path, baked in for
  ## the absolute-path run.
  "import repro_project_dsl\n" &
  "\n" &
  "const compileRole =\n" &
  "  when defined(reproInterfaceMode): \"interface\" else: \"provider\"\n" &
  "const bareProbe = gorgeEx(\"" & ProbeTool & " \" & compileRole & \"-bare\")\n" &
  "const absoluteProbe = gorgeEx(" & escape(quoteShell(stubPath)) &
    " & \" \" & compileRole & \"-absolute\")\n" &
  "\n" &
  "package xtoolpathprobe:\n" &
  "  build:\n" &
  "    fs.writeText(actionId = \"write-probe\", output = \"out/probe.txt\",\n" &
  "      text = \"bare=\" & $bareProbe.exitCode & \" absolute=\" &\n" &
  "        $absoluteProbe.exitCode & \"\\n\")\n"

proc writeStub(dir, witness: string): string =
  ## The stub tool: appends its first argument to `witness` and exits 0.
  createDir(dir)
  result = dir / ProbeTool
  writeFile(result, "#!/bin/sh\n" &
    "echo \"$1\" >> " & quoteShell(witness) & "\n" &
    "exit 0\n")
  setFilePermissions(result, {fpUserRead, fpUserWrite, fpUserExec})

proc witnessLines(witness: string): seq[string] =
  if fileExists(witness):
    for line in readFile(witness).splitLines:
      if line.len > 0:
        result.add(line)

suite "a recipe's compile-time tools come from the declared PATH":

  test "a tool only the caller's PATH holds is found by neither recipe compile":
    when defined(windows):
      skip("the recipe-relative interface extraction is POSIX-only")
    else:
      let repoRoot = getCurrentDir()
      let reproBin = repoRoot / "build" / "bin" / "repro".addFileExt(ExeExt)
      if not fileExists(reproBin):
        checkpoint("missing " & reproBin & "; run `just build` first")
        fail()
      else:
        let tempRoot = "/tmp/rb-xtoolpath-" & $getCurrentProcessId()
        removeDir(tempRoot)
        createDir(tempRoot)
        defer: removeDir(tempRoot)
        let witness = tempRoot / "witness" / "probe.log"
        createDir(parentDir(witness))
        let stub = writeStub(tempRoot / "caller-tools", witness)
        let callerPath = parentDir(stub) & ":" & getEnv("PATH")

        # CONTROL: the caller's PATH resolves the stub, and the stub logs.
        let control = execCmdEx(quoteShellCommand([
          "env", "PATH=" & callerPath, "sh", "-c", ProbeTool & " control"]))
        checkpoint("control: exit " & $control.exitCode & ": " & control.output)
        check control.exitCode == 0
        check witnessLines(witness) == @["control"]
        removeFile(witness)

        let project = tempRoot / "project"
        createDir(project)
        writeFile(project / "repro.nim", recipeFor(stub))
        let tmp = tempRoot / "tmp"
        createDir(tmp)
        let home = tempRoot / "home"
        createDir(home)
        let res = execCmdEx(quoteShellCommand([
          "env",
          "TMPDIR=" & tmp,
          # The fixture's own user cache: the extraction's shared nimcache
          # pool and the provider nimcache are fresh, so both compiles run.
          "XDG_CACHE_HOME=" & tmp / "cache",
          "HOME=" & home,
          "PATH=" & callerPath,
          "REPROBUILD_STORE_ROOT=" & tempRoot / "store",
          "REPRO_STORE_ROOT=" & tempRoot / "store",
          reproBin, "build",
          "--daemon=off",
          "--tool-provisioning=path",
          "--action-cache-root=" & tempRoot / "action-cache",
          "--progress=quiet",
          project]))
        checkpoint("repro build exited " & $res.exitCode & ":\n" & res.output)
        check res.exitCode == 0

        let lines = witnessLines(witness)
        checkpoint("witness: " & $lines)
        # VACUITY GUARD: the recipe's compile-time code ran in both compiles.
        check "interface-absolute" in lines
        check "provider-absolute" in lines
        # THE PROPERTY: the caller's tool reached neither compile.
        check "interface-bare" notin lines
        check "provider-bare" notin lines

        # The recipe was told the bare-named tool is missing, and the
        # absolute one succeeded.
        let product = project / "out" / "probe.txt"
        check fileExists(product)
        if fileExists(product):
          let text = readFile(product).strip
          checkpoint("out/probe.txt: " & text)
          check text.startsWith("bare=")
          check not text.startsWith("bare=0 ")
          check text.endsWith(" absolute=0")
