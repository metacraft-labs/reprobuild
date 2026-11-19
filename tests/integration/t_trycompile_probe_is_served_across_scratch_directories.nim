## t_trycompile_probe_is_served_across_scratch_directories — a CMake
## try_compile probe recorded in one configure's scratch directory is served
## to the same probe in another configure's, output included.
##
## What this test owns
## -------------------
## reprobuild-pm issue 2026-10-10 "trycompile-edge-cache-key-is-unique-to-
## its-configure": every configure runs its probes in a fresh
## `CMakeFiles/CMakeScratch/TryCompile-<random>` directory, and the probe's
## key carried that directory (the cwd, through `action()` and through the
## inline-exec caller fingerprint over the raw payload) and the digest of the
## scratch directory's generated `reprobuild.nim`, so no probe was ever served
## from cache. A `trycompile.rbsz` v6 envelope says the project's actions are
## relocatable; the lowering then keys the argv in its relocatable names, the
## cwd by depth, and leaves the scratch directory out of the caller
## fingerprint.
##
## The cases pin, through the real `repro` and the shipped direct provider:
##
##   * a relocatable probe built in scratch directory B after the same probe
##     was built in scratch directory A (same depth, one store root) is
##     served (`launched=false`), its output file restored, and its captured
##     stdout and stderr printed as A's run printed them
##     (Provider-Compile-Tiering.md "A TryCompile hit must replay the probe's
##     output");
##   * the control: the same two probes in a v5 envelope (not relocatable)
##     both run.
##
## The probe reads a "staged source" under the store root by absolute path,
## as the generator's canonical try_compile sources are, so that input stays
## named absolutely (the store is a relocation anchor).

import std/[os, osproc, strutils, tempfiles, unittest]
import repro_test_support/reasoned_skip
import repro_cmake_trycompile

proc repoRoot(): string =
  currentSourcePath().parentDir.parentDir.parentDir

let reproBin = getEnv("REPROBUILD_REPRO",
  repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt))
let tryCompileProviderBin = reproBin.parentDir /
  addFileExt("repro-cmake-trycompile-provider", ExeExt)

const
  StdoutMarker = "tc-probe-stdout-marker"
  StderrMarker = "tc-probe-stderr-marker"
  ProbeId = "compile-cmTC-probe"

type BuildRun = object
  exitCode: int
  output: string

proc unavailable(): string =
  if not fileExists(reproBin):
    return "needs " & reproBin & " (run `just build`)"
  if not fileExists(tryCompileProviderBin):
    return "needs " & tryCompileProviderBin & " beside the CLI (run `just build`)"
  if findExe("sh").len == 0:
    return "needs `sh` on PATH for the probe's inline action"
  ""

proc writeProbe(scratch, stagedSource: string; relocatable: bool) =
  ## One inline, cacheable action as the generator emits a probe compile:
  ## absolute tool, absolute staged source, cwd-relative output. The
  ## generated `reprobuild.nim` names the scratch directory, as the real one
  ## does (its digest used to key the probe apart).
  createDir(scratch)
  # Forward slashes: `sh` reads a backslash as an escape.
  let command = "cat " & quoteShell(stagedSource.replace('\\', '/')) &
    " > out.txt && " &
    "echo " & StdoutMarker & " && echo " & StderrMarker & " >&2"
  let meta = TryCompileMetadata(
    actions: @[TryCompileActionDef(id: ProbeId,
      inline: true,
      inlineArgv: @[findExe("sh"), "-c", command],
      inlineCwd: scratch,
      inputs: @[stagedSource],
      outputs: @["out.txt"],
      cacheable: true,
      commandStatsId: ProbeId)],
    targets: @[TryCompileTargetDef(name: "cmTC", actionIds: @[ProbeId])],
    defaultTargetName: "cmTC",
    relocatable: relocatable)
  var encoded = encodeTryCompileMetadata(meta)
  if not relocatable:
    # A v5 envelope, as a generator writes for a `repro` that does not list
    # `trycompile-relocatable-probes`: version 5 and no v6 trailer.
    # version-literal-ok: v5 is the frozen pre-relocatable envelope version
    encoded[4] = 5'u8
    encoded.setLen(encoded.len - 1)
    let payloadLen = uint32(encoded.len - 10)
    for i in 0 .. 3:
      encoded[6 + i] = byte((payloadLen shr (8 * i)) and 0xff)
  writeFile(scratch / "reprobuild.nim",
    "import repro_project_dsl\n\n# generated in " & scratch &
    "\npackage cmTCProbe:\n  discard\n")
  var bytes = newString(encoded.len)
  for i, b in encoded:
    bytes[i] = char(b)
  writeFile(scratch / "trycompile.rbsz", bytes)

proc runProbe(scratch: string): BuildRun =
  ## `output` is repro's STDOUT alone, where `--action-output=all` and the
  ## `--log=actions` status lines go; stderr is sent to a file through `sh`,
  ## as in `t_build_action_output_all_passes_action_output_through`: merged
  ## with the progress renderer's carriage returns on stderr, the first
  ## character of each printed chunk is lost on Windows.
  let stderrPath = scratch.parentDir / "build-stderr.txt"
  var command = quoteShell(findExe("sh")) & " -c " &
    quoteShell("exec \"$0\" \"$@\" 2>\"$REPRO_TEST_STDERR\"") & " " &
    quoteShell(reproBin)
  for arg in ["build", scratch & "#cmTC", "--tool-provisioning=path",
      "--daemon=off", "--no-runquota",
      "--progress=quiet", "--measure=none", "--no-write-report",
      "--log=actions", "--action-output=all", "--restore-cached-outputs",
      "--work-root=" & scratch / "CMakeFiles" / "reprobuild"]:
    command.add(" " & quoteShell(arg))
  putEnv("REPRO_TEST_STDERR", stderrPath)
  let res = execCmdEx(command, workingDir = scratch)
  BuildRun(exitCode: res.exitCode,
    output: res.output & "\n--- stderr ---\n" & readFile(stderrPath))

proc explain(run: BuildRun): string =
  "exit=" & $run.exitCode & "\n--- output ---\n" & run.output

proc probeLine(run: BuildRun): string =
  ## The build's one action line (the status line names the probe by its
  ## target when the target has a single action).
  for line in run.output.splitLines():
    if line.startsWith("action: "):
      return line
  ""

let root = createTempDir("repro-tc-reloc-", "")
let storeRoot = root / "store"
putEnv("REPROBUILD_STORE_ROOT", storeRoot)
let stagedSource = storeRoot / "cmake-trycompile-sources" / "0123abcd" /
  "probe.c"
createDir(stagedSource.parentDir)
writeFile(stagedSource, "int main(void) { return 0; }\n")

suite "a try_compile probe across scratch directories":

  test "a relocatable probe is served in another scratch directory":
    let why = unavailable()
    if why.len > 0:
      skip(why)
    else:
      let first = root / "conf-a" / "TryCompile-aaa111"
      let second = root / "conf-b" / "TryCompile-bbb222"
      writeProbe(first, stagedSource, relocatable = true)
      writeProbe(second, stagedSource, relocatable = true)
      let miss = runProbe(first)
      checkpoint(explain(miss))
      check miss.exitCode == 0
      check "launched=true" in miss.probeLine()
      let hit = runProbe(second)
      checkpoint(explain(hit))
      check hit.exitCode == 0
      check "launched=false" in hit.probeLine()
      check readFile(second / "out.txt") == readFile(stagedSource)
      # The hit prints what the run printed, once each.
      check hit.output.count(StdoutMarker) == 1
      check hit.output.count(StderrMarker) == 1

  test "control: the same probes in a v5 envelope both run":
    let why = unavailable()
    if why.len > 0:
      skip(why)
    else:
      let first = root / "ctrl-a" / "TryCompile-ccc333"
      let second = root / "ctrl-b" / "TryCompile-ddd444"
      writeProbe(first, stagedSource, relocatable = false)
      writeProbe(second, stagedSource, relocatable = false)
      let one = runProbe(first)
      checkpoint(explain(one))
      check one.exitCode == 0
      check "launched=true" in one.probeLine()
      let two = runProbe(second)
      checkpoint(explain(two))
      check two.exitCode == 0
      check "launched=true" in two.probeLine()

try:
  removeDir(root)
except OSError:
  discard
