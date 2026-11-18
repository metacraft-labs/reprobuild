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

import std/[os, osproc, streams, strtabs, strutils, times, unittest]

const BackendCompilerUse = when defined(macosx): "clang >=1" else: "gcc >=1"
  ## `nim.c(...)` shells out to the platform's default C backend, which the
  ## recipe must declare so the edge's PATH can resolve it (the same rule as
  ## `t_measurement_flags_cli.nim`'s recipes).

const RecipeSource = """
import repro_project_dsl

package shelltempprobe:
  uses:
    "nim >=2.2 <3.0"
    """" & BackendCompilerUse & """"

  executable hello:
    build:
      discard nim.c(source = "src/hello.nim", binary = "hello")
"""

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
  let output = p.outputStream.readAll()
  (output: output, exitCode: p.waitForExit())

suite "a nim compile edge's key ignores the shell's temp directory":

  test "a build from a shell with another TMPDIR/TMP/TEMP/TEMPDIR hits":
    let repoRoot = getCurrentDir()
    let reproBin = reproBinary(repoRoot)
    if not fileExists(reproBin):
      # Never a silent pass: without the real CLI this test says nothing.
      checkpoint("missing " & reproBin & "; run `just build` first")
      fail()
    else:
      # A short root: the compile's argv is in its action key, and a deep
      # root makes the fixture needlessly fragile.
      let tempRoot = "/tmp/rb-nimtemp-" & $getCurrentProcessId()
      removeDir(tempRoot)
      createDir(tempRoot)
      defer: removeDir(tempRoot)

      let projectRoot = tempRoot / "project"
      createDir(projectRoot / "src")
      writeFile(projectRoot / "repro.nim", RecipeSource)
      writeFile(projectRoot / "src" / "hello.nim", HelloSource)
      let actionCacheRoot = tempRoot / "action-cache"
      createDir(actionCacheRoot)
      # Two existing directories, as two shells' `/tmp/nix-shell.XXXXXX`.
      let shellA = tempRoot / "nix-shell.A"
      let shellB = tempRoot / "nix-shell.B"
      createDir(shellA)
      createDir(shellB)
      let binary = projectRoot / addFileExt("hello", ExeExt)

      let cold = runBuildCli(reproBin, projectRoot, actionCacheRoot,
        shellEnv(shellA))
      checkpoint("cold (shell A): " & actionLine(cold.output))
      if cold.exitCode != 0:
        checkpoint(cold.output)
      require cold.exitCode == 0
      require fileExists(binary)
      check "launched=true" in actionLine(cold.output)

      let before = getLastModificationTime(binary)
      let warm = runBuildCli(reproBin, projectRoot, actionCacheRoot,
        shellEnv(shellB))
      let warmLine = actionLine(warm.output)
      checkpoint("warm (shell B): " & warmLine)
      if warm.exitCode != 0:
        checkpoint(warm.output)
      check warm.exitCode == 0
      check warmLine.len > 0
      check "cache=cdHit" in warmLine
      check "launched=false" in warmLine
      # Out-of-band: the binary on disk was not re-produced.
      check getLastModificationTime(binary) == before

      # Positive control: a change to what the edge compiles DOES rebuild,
      # from the same "new shell", so the hit above is not a probe that
      # cannot see a compile.
      writeFile(projectRoot / "src" / "hello.nim",
        HelloSource & "echo \"control\"\n")
      let edited = runBuildCli(reproBin, projectRoot, actionCacheRoot,
        shellEnv(shellB))
      let editedLine = actionLine(edited.output)
      checkpoint("source edited (shell B): " & editedLine)
      if edited.exitCode != 0:
        checkpoint(edited.output)
      check edited.exitCode == 0
      check "cache=cdMiss" in editedLine
      check "launched=true" in editedLine
