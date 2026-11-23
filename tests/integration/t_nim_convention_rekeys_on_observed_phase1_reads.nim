## t_nim_convention_rekeys_on_observed_phase1_reads — the Nim standard
## convention (Tier 2b, ``repro-standard-provider``) rebuilds what ``nim c``
## builds after a change that only Phase 1's monitor can see.
##
## What this test owns
## -------------------
## The Nim convention's contract for its emit-time Phase 1 run
## (``Nim.md`` §"Cross-module ordering"):
## the emit-time Phase 1 run is monitored, its manifest is reused only while
## every read it was observed to make would read the same, and those reads are
## the fragment's evaluation inputs, an environment variable as the host fact
## ``env:<NAME>`` (``Project-Provider-Graph-Protocol.md`` §"Evaluation
## Inputs"). Each case builds, makes one such change, rebuilds, and runs the
## binary:
##
##   (a) an environment variable a ``config.nims`` reads into ``--passC``;
##   (b) a module created in a ``path`` directory that Nim searches before the
##       one that supplied the module so far;
##   (c) a file read at compile time with ``staticExec``.
##
## Before the fix each rebuild linked objects compiled with the old flags, or
## from the old module, so the binary printed the old value. The expected
## value is what ``nim c -r`` of the same tree prints, so the expectation is
## Nim's own behaviour, not a transcription of it.
##
## Mocks: none. Each case drives the real built ``repro`` CLI, which
## dispatches the real prebuilt ``repro-standard-provider`` beside it and the
## real io monitor; the Nim toolchain is the one on PATH
## (``--tool-provisioning=path``).

import std/[os, osproc, strutils, tempfiles, unittest]
import repro_test_support/reasoned_skip

proc repoRoot(): string =
  currentSourcePath().parentDir.parentDir.parentDir

let reproBin = getEnv("REPROBUILD_REPRO",
  repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt))
let standardProviderBin = reproBin.parentDir /
  addFileExt("repro-standard-provider", ExeExt)

proc unavailable(): string =
  if not fileExists(reproBin):
    return "needs " & reproBin & " (run `just build`)"
  if not fileExists(standardProviderBin):
    return "needs " & standardProviderBin & " beside the CLI (run `just build`)"
  if findExe("nim").len == 0:
    return "nim not on PATH"
  ""

const
  ProbeVar = "REPRO_NIM_E2E_PHASE1_PROBE"
  ProjectFile = """
import repro_project_dsl

package nimPhase1Probe:
  uses:
    "nim >=2.2"

  executable $1:
    discard
"""
  # Prints the C macro ``REPRO_PROBE``, which only the C compile defines:
  # the value reaches the binary only through a Phase 2 command line.
  MacroMain = "var probe {.importc: \"REPRO_PROBE\", nodecl.}: cint\n" &
    "echo \"probe \", probe\n"

type Run = object
  exitCode: int
  output: string

proc explain(run: Run): string =
  "exit=" & $run.exitCode & "\n--- output ---\n" & run.output

proc runBuild(project: string): Run =
  var command = quoteShell(reproBin) & " build " & quoteShell(project)
  for arg in ["--tool-provisioning=path", "--daemon=off", "--no-runquota",
      "--progress=quiet", "--log=actions"]:
    command.add(" " & quoteShell(arg))
  let res = execCmdEx(command, workingDir = project)
  Run(exitCode: res.exitCode, output: res.output)

proc nimRun(project, entry: string): Run =
  ## Nim's own answer for the same tree, compiled into a scratch nimcache so
  ## it leaves the project's ``.repro`` alone.
  let scratch = createTempDir("repro-nim-reference-", "")
  defer: removeDir(scratch)
  let res = execCmdEx(quoteShell(findExe("nim")) &
    " c -r --hints:off --skipParentCfg --skipUserCfg --noNimblePath" &
    " --nimcache:" & quoteShell(scratch / "nimcache") &
    " --out:" & quoteShell(scratch / entry) & " " &
    quoteShell(project / "src" / (entry & ".nim")),
    options = {poUsePath}, workingDir = project)
  Run(exitCode: res.exitCode, output: res.output)

proc runBinary(project, entry: string): Run =
  let bin = project / ".repro" / "build" / entry / addFileExt(entry, ExeExt)
  if not fileExists(bin):
    return Run(exitCode: -1, output: "no built binary at " & bin)
  let res = execCmdEx(quoteShell(bin))
  Run(exitCode: res.exitCode, output: res.output)

proc writeTree(root: string; files: openArray[(string, string)]) =
  for (rel, content) in files:
    let path = root / rel
    createDir(path.parentDir)
    writeFile(path, content)

proc buildAndCompare(project, entry, expected: string) =
  ## Build, run the binary, and require that it prints ``expected`` and what
  ## ``nim c -r`` of the same tree prints.
  let reference = nimRun(project, entry)
  checkpoint("nim c -r: " & explain(reference))
  check reference.exitCode == 0
  check reference.output.strip == expected
  let build = runBuild(project)
  checkpoint("repro build: " & explain(build))
  check build.exitCode == 0
  check "standardDirect: dispatching" in build.output
  let ran = runBinary(project, entry)
  checkpoint("built binary: " & explain(ran))
  check ran.exitCode == 0
  check ran.output.strip == expected

proc storedEmitKeys(project: string): int =
  ## The emit-cache sidecars under the project's ``.repro``. One is written
  ## only for a Phase 1 run that the provider judged reusable, so after a
  ## build with nothing changed there must be one: a provider that never
  ## stores would make every case below pass by re-running Phase 1 each
  ## time, and would test nothing about the key.
  for path in walkDirRec(project / ".repro"):
    if extractFilename(path) == "nim-c-compileonly.repro-emit-fingerprint":
      inc result

suite "Nim convention: Phase 1 is keyed on what it was observed to read":

  test "(a) an environment variable a config.nims reads":
    let why = unavailable()
    if why.len > 0:
      skip(why)
    else:
      let root = createTempDir("repro-nim-env-", "")
      let hadProbe = existsEnv(ProbeVar)
      let savedProbe = getEnv(ProbeVar)
      defer:
        removeDir(root)
        if hadProbe: putEnv(ProbeVar, savedProbe)
        else: delEnv(ProbeVar)
      writeTree(root, [
        ("repro.nim", ProjectFile % "envprobe"),
        ("src/envprobe.nim", MacroMain),
        ("src/config.nims",
          "switch(\"passC\", \"-DREPRO_PROBE=\" & getEnv(\"" & ProbeVar &
            "\"))\n"),
      ])
      putEnv(ProbeVar, "7")
      buildAndCompare(root, "envprobe", "probe 7")
      # A second build with nothing changed stores the result, so the next
      # change is tested against a stored manifest and a stored graph.
      buildAndCompare(root, "envprobe", "probe 7")
      check storedEmitKeys(root) == 1
      putEnv(ProbeVar, "8")
      buildAndCompare(root, "envprobe", "probe 8")

  test "(b) a module created earlier on a search path":
    let why = unavailable()
    if why.len > 0:
      skip(why)
    else:
      let root = createTempDir("repro-nim-shadow-", "")
      defer: removeDir(root)
      # Nim searches a ``path`` added later before one added earlier.
      writeTree(root, [
        ("repro.nim", ProjectFile % "shadowprobe"),
        ("src/shadowprobe.nim", "import helper\necho \"helper \", which()\n"),
        ("src/config.nims",
          "switch(\"path\", thisDir() & \"/../early\")\n" &
          "switch(\"path\", thisDir() & \"/../late\")\n"),
        ("early/helper.nim", "proc which*(): string = \"early\"\n"),
      ])
      buildAndCompare(root, "shadowprobe", "helper early")
      buildAndCompare(root, "shadowprobe", "helper early")
      check storedEmitKeys(root) == 1
      writeTree(root, [("late/helper.nim",
        "proc which*(): string = \"late\"\n")])
      buildAndCompare(root, "shadowprobe", "helper late")

  test "(c) a file a module reads with staticExec":
    let why = unavailable()
    if why.len > 0:
      skip(why)
    else:
      let root = createTempDir("repro-nim-staticexec-", "")
      defer: removeDir(root)
      writeTree(root, [
        ("repro.nim", ProjectFile % "execprobe"),
        ("src/execprobe.nim",
          "{.passC: \"-DREPRO_PROBE=\" & staticExec(\"cat flag.txt\").}\n" &
            MacroMain),
        ("src/flag.txt", "3"),
      ])
      buildAndCompare(root, "execprobe", "probe 3")
      buildAndCompare(root, "execprobe", "probe 3")
      check storedEmitKeys(root) == 1
      writeTree(root, [("src/flag.txt", "4")])
      buildAndCompare(root, "execprobe", "probe 4")
