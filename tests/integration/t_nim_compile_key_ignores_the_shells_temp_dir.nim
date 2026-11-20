## A `nim.c` compile edge must not key on the shell's temp directory.
##
## MOCK POLICY — NO MOCKS ARE USED IN THIS FILE, AND NONE MAY BE ADDED.
## The test drives the real ``build/bin/repro`` binary as a subprocess
## against a real recipe in a real temporary directory: a real `nim c` of a
## real hello-world, driving the real C backend under the real monitor. The
## defect is in which observed environment values the monitored edge's cache
## key records, so only the production launch + monitor + action cache can
## reproduce it.
##
## The defect (reprobuild-pm issue
## ``2026-10-18-compile-edges-record-the-shells-temp-so-every-new-nix-develop-shell-misses``):
## `nix develop` exports a fresh ``/tmp/nix-shell.XXXXXX`` as ``TMPDIR``,
## ``TMP``, ``TEMP`` and ``TEMPDIR`` in every shell. The compile reads them,
## io-mon records the reads, and the engine keyed each observed read by its
## VALUE, so the first build in every new shell missed every Nim compile
## edge of an unchanged tree with ``input changed: environment: TEMP``.
##
## The property: after one cold build with all four variables pointing at
## directory A, a build whose four variables point at directory B -- what a
## second `nix develop` shell looks like to the edge -- reuses the record: the
## logged consultation is a cache hit and the binary is untouched.
##
## Positive control: editing the compiled source DOES rebuild in that same
## "new shell". Without it, a probe that could not observe a rebuild at all
## would pass vacuously.
##
## Two spellings of the compile are driven, because they reached the
## passthrough by different routes: the `nim.c(..., binary = ...)` shorthand,
## and the typed-tool form `nim.c(source = ..., output = ..., <typed flags>)`
## that the `cli:` block of the `nim` tool generates (what codetracer's `ct`
## and `ct-test` edges use, since the shorthand lacks their typed flags). The
## typed form missed in every new shell until the `nim` tool declared the
## passthrough itself (`envPassthrough` in its `cli:` block).

from repro_core/process_streams import drainStream
import std/[os, osproc, streams, strtabs, strutils, times, unittest]

const BackendCompilerUse = when defined(macosx): "clang >=1" else: "gcc >=1"
  ## `nim.c(...)` shells out to the platform's default C backend, which the
  ## recipe must declare so the edge's PATH can resolve it (the same rule as
  ## `t_measurement_flags_cli.nim`'s recipes).

proc recipeSource(compileCall: string): string =
  ## A one-edge recipe whose only edge is `compileCall`.
  """
import repro_project_dsl

package shelltempprobe:
  uses:
    "nim >=2.2 <3.0"
    """" & BackendCompilerUse & """"

  executable hello:
    build:
      discard """ & compileCall & "\n"

const AliasCompileCall = "nim.c(source = \"src/hello.nim\", binary = \"hello\")"
  ## The `binary =` shorthand (`proc c*(pkg: NimPackage; source, binary...)`).

const TypedCompileCall =
  "nim.c(source = \"src/hello.nim\", output = \"hello\", hintsOff = true)"
  ## The typed-tool form, with a typed flag the shorthand does not take --
  ## the shape of codetracer's `ct` / `ct-test` compile edges.

const HelloSource = "echo \"hello from the shell-temp probe\"\n"

const ScratchNames = ["TMPDIR", "TMP", "TEMP", "TEMPDIR"]

const ActionLinePrefix = "action: nim-c-"

proc reproBinary(repoRoot: string): string =
  repoRoot / "build" / "bin" / addFileExt("repro", ExeExt)

proc actionLine(output: string): string =
  for line in output.splitLines:
    let stripped = line.strip()
    if stripped.startsWith(ActionLinePrefix):
      return stripped
  ""

proc shellEnv(scratchDir: string): StringTableRef =
  ## This process's environment with the four temp-directory variables all
  ## pointing at `scratchDir`, as one `nix develop` shell exports them.
  ## Everything else is held fixed, so a miss can only be these four.
  result = newStringTable(modeCaseSensitive)
  for name, value in envPairs():
    result[name] = value
  for name in ScratchNames:
    result[name] = scratchDir

proc runBuildCli(reproBin, projectRoot, actionCacheRoot: string;
                 env: StringTableRef): tuple[output: string; exitCode: int] =
  let p = startProcess(reproBin,
    args = ["build", "--daemon=off", "--tool-provisioning=path",
      "--no-runquota", "--action-cache-root=" & actionCacheRoot,
      "--progress=quiet", "--log=actions", projectRoot],
    env = env, options = {poStdErrToStdOut})
  defer: p.close()
  let output = drainStream(p.outputStream)
  (output: output, exitCode: p.waitForExit())

type
  BuildObservation = object
    ## One `repro build` run: its exit code, its `nim-c-` action line (the
    ## consultation and launch verdict), and its full output for diagnostics.
    exitCode: int
    line: string
    output: string

  ShellTempObservations = object
    ## What the three builds of one probe saw. The probe only OBSERVES; each
    ## test body asserts on these fields, so every requirement is visible
    ## where the case is declared.
    reproBin: string
    reproFound: bool
      ## False when `build/bin/repro` is missing: nothing else was run.
    cold: BuildObservation
      ## Shell A, empty cache.
    coldProducedBinary: bool
    ranWarm: bool
      ## False when the cold build failed or produced no binary: the warm
      ## and edited builds were not run, and their fields are empty.
    warm: BuildObservation
      ## Shell B, unchanged tree.
    binaryUntouchedByWarm: bool
      ## Out-of-band: the binary's mtime before and after the warm build.
    edited: BuildObservation
      ## Shell B, the compiled source edited (the positive control).

proc observeBuild(reproBin, projectRoot, actionCacheRoot, label: string;
                  env: StringTableRef): BuildObservation =
  let run = runBuildCli(reproBin, projectRoot, actionCacheRoot, env)
  result = BuildObservation(exitCode: run.exitCode,
    line: actionLine(run.output), output: run.output)
  checkpoint(label & ": " & result.line)
  if result.exitCode != 0:
    checkpoint(result.output)

proc observeBuildsFromTwoShells(compileCall: string): ShellTempObservations =
  ## Cold build in shell A, warm build in shell B, then an edited source in
  ## shell B: see the module header. Records what each saw and asserts
  ## nothing; the callers' `test` bodies do.
  let repoRoot = getCurrentDir()
  result.reproBin = reproBinary(repoRoot)
  result.reproFound = fileExists(result.reproBin)
  if not result.reproFound:
    checkpoint("missing " & result.reproBin & "; run `just build` first")
    return

  # A short root: the compile's argv is in its action key, and a deep root
  # makes the fixture needlessly fragile.
  let tempRoot = "/tmp/rb-nimtemp-" & $getCurrentProcessId()
  removeDir(tempRoot)
  createDir(tempRoot)
  defer: removeDir(tempRoot)

  let projectRoot = tempRoot / "project"
  createDir(projectRoot / "src")
  writeFile(projectRoot / "repro.nim", recipeSource(compileCall))
  writeFile(projectRoot / "src" / "hello.nim", HelloSource)
  let actionCacheRoot = tempRoot / "action-cache"
  createDir(actionCacheRoot)
  # Two existing directories, as two shells' `/tmp/nix-shell.XXXXXX`.
  let shellA = tempRoot / "nix-shell.A"
  let shellB = tempRoot / "nix-shell.B"
  createDir(shellA)
  createDir(shellB)
  let binary = projectRoot / addFileExt("hello", ExeExt)

  result.cold = observeBuild(result.reproBin, projectRoot, actionCacheRoot,
    "cold (shell A)", shellEnv(shellA))
  result.coldProducedBinary = fileExists(binary)
  if result.cold.exitCode != 0 or not result.coldProducedBinary:
    return
  result.ranWarm = true

  let before = getLastModificationTime(binary)
  result.warm = observeBuild(result.reproBin, projectRoot, actionCacheRoot,
    "warm (shell B)", shellEnv(shellB))
  result.binaryUntouchedByWarm =
    fileExists(binary) and getLastModificationTime(binary) == before

  # Positive control: a change to what the edge compiles DOES rebuild, from
  # the same "new shell", so a hit is not a probe that cannot see a compile.
  writeFile(projectRoot / "src" / "hello.nim",
    HelloSource & "echo \"control\"\n")
  result.edited = observeBuild(result.reproBin, projectRoot, actionCacheRoot,
    "source edited (shell B)", shellEnv(shellB))

suite "a nim compile edge's key ignores the shell's temp directory":

  # Each body below states the same requirements in full rather than
  # through a shared asserting helper, so each case's assertions are visible
  # in the case itself.

  test "a build from a shell with another TMPDIR/TMP/TEMP/TEMPDIR hits":
    let seen = observeBuildsFromTwoShells(AliasCompileCall)
    # Never a silent pass: without the real CLI this test says nothing.
    require seen.reproFound
    require seen.cold.exitCode == 0
    require seen.coldProducedBinary
    require seen.ranWarm
    check "launched=true" in seen.cold.line
    check seen.warm.exitCode == 0
    check seen.warm.line.len > 0
    check "cache=cdHit" in seen.warm.line
    check "launched=false" in seen.warm.line
    check seen.binaryUntouchedByWarm
    check seen.edited.exitCode == 0
    check "cache=cdMiss" in seen.edited.line
    check "launched=true" in seen.edited.line

  test "the typed nim.c(output = ...) form hits from another shell too":
    let seen = observeBuildsFromTwoShells(TypedCompileCall)
    require seen.reproFound
    require seen.cold.exitCode == 0
    require seen.coldProducedBinary
    require seen.ranWarm
    check "launched=true" in seen.cold.line
    check seen.warm.exitCode == 0
    check seen.warm.line.len > 0
    check "cache=cdHit" in seen.warm.line
    check "launched=false" in seen.warm.line
    check seen.binaryUntouchedByWarm
    check seen.edited.exitCode == 0
    check "cache=cdMiss" in seen.edited.line
    check "launched=true" in seen.edited.line
