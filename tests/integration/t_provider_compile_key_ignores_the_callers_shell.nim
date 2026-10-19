## The provider-compile edge must not key on the CALLER's shell.
##
## MOCK POLICY — NO MOCKS ARE USED IN THIS FILE, AND NONE MAY BE ADDED.
## The test drives the real ``build/bin/repro`` binary as a subprocess
## against a real recipe in a real temporary directory, with a real Nim
## compile of a real provider binary under the real monitor. The defect is
## in which observed environment values the monitored edge's cache key
## records, so only the production launch + monitor + action cache can
## reproduce it.
##
## The defect (reprobuild-pm issue
## ``2026-09-28-provider-compile-key-includes-the-callers-path-and-terminal``,
## observed at ``13052f77a``): the edge inherited the caller's environment
## and its monitor recorded ``PATH``, ``TERM``, ``LANG``, ``HOME``,
## ``LD_LIBRARY_PATH`` and ``CXX`` by value. A ``repro exec`` started under
## ``perf`` (which prepends to ``PATH``) recompiled the provider with
## ``input metadata changed: PATH``. None of those variables changes what
## the provider binary is: the toolchain is already keyed by the compiler
## identities, and a terminal or a locale only changes diagnostics text
## (Dev-Env-Warm-Entry.md §2).
##
## The property: after one cold compile, a build started from a shell that
## differs ONLY in such variables reuses the provider — the logged
## consultation is a cache hit and the provider binary is untouched. Each
## variation is applied on its own, on top of the cold run's environment,
## so a failure names the variable that moved the key.
##
## Positive control: editing the recipe DOES recompile. Without it, a probe
## that could not observe a recompile at all would pass vacuously.
##
## Measured against the build of ``6270e15d`` (the parent of the fix
## ``6f581746``): the prepended ``PATH`` and the changed ``TERM`` each
## recompile there (``cache=cdMiss``), so this test is red on the defect.

import std/[os, osproc, streams, strtabs, strutils, times, unittest]

const RecipeSource = """
import repro_project_dsl

package callershellprobe:
  build:
    discard
"""

const ProviderLinePrefix = "providerCompileAction: __repro_provider_compile"

proc reproBinary(repoRoot: string): string =
  repoRoot / "build" / "bin" / addFileExt("repro", ExeExt)

proc providerLine(output: string): string =
  for line in output.splitLines:
    let stripped = line.strip()
    if stripped.startsWith(ProviderLinePrefix):
      return stripped
  ""

proc baseEnv(): StringTableRef =
  ## The cold run's environment: this process's own, with the variables the
  ## variations change pinned to known values so every variation is a real
  ## change whatever shell started the test.
  result = newStringTable(modeCaseSensitive)
  for name, value in envPairs():
    result[name] = value
  result["TERM"] = "xterm-256color"
  result["LANG"] = "C.UTF-8"
  result["TZ"] = "UTC"
  if result.hasKey("LC_ALL"):
    result.del("LC_ALL")
  if result.hasKey("CXX"):
    result.del("CXX")

proc runBuildCli(reproBin, projectRoot, actionCacheRoot: string;
                 env: StringTableRef): tuple[output: string; exitCode: int] =
  let p = startProcess(reproBin,
    args = ["build", "--daemon=off", "--tool-provisioning=path",
      "--action-cache-root=" & actionCacheRoot, "--progress=quiet",
      "--log=actions", projectRoot],
    env = env, options = {poStdErrToStdOut})
  defer: p.close()
  let output = p.outputStream.readAll()
  (output: output, exitCode: p.waitForExit())

proc mtimeOf(path: string): times.Time =
  getLastModificationTime(path)

suite "the provider-compile key ignores the caller's shell":

  test "a different PATH, terminal, locale or CXX reuses the provider":
    let repoRoot = getCurrentDir()
    let reproBin = reproBinary(repoRoot)
    if not fileExists(reproBin):
      # Never a silent pass: without the real CLI this test says nothing.
      checkpoint("missing " & reproBin & "; run `just build` first")
      fail()
    else:
      # A short root: the provider compile's argv is in its action key, and a
      # deep root makes the fixture needlessly fragile.
      let tempRoot = "/tmp/rb-callershell-" & $getCurrentProcessId()
      removeDir(tempRoot)
      createDir(tempRoot)
      defer: removeDir(tempRoot)

      let projectRoot = tempRoot / "project"
      createDir(projectRoot)
      writeFile(projectRoot / "repro.nim", RecipeSource)
      let actionCacheRoot = tempRoot / "action-cache"
      createDir(actionCacheRoot)
      let providerBinary =
        projectRoot / ".repro" / "build" / "repro" / "provider" /
          "project-provider"

      let cold = runBuildCli(reproBin, projectRoot, actionCacheRoot,
        baseEnv())
      if cold.exitCode != 0:
        checkpoint(cold.output)
      require cold.exitCode == 0
      checkpoint("cold: " & providerLine(cold.output))
      require fileExists(providerBinary)

      # A directory that does not exist: it resolves nothing, so it cannot
      # change which compiler runs — exactly the `perf` / IDE / direnv case.
      let variations = [
        ("PATH", "/opt/repro-test-nonexistent" & $PathSep &
          getEnv("PATH")),
        ("TERM", "tmux-256color"),
        ("LANG", "de_DE.UTF-8"),
        ("LC_ALL", "C.UTF-8"),
        ("TZ", "Asia/Tokyo"),
        ("CXX", "/bin/false"),
      ]
      for (name, value) in variations:
        let env = baseEnv()
        env[name] = value
        # Compared per step, so a recompile under one variation does not
        # also fail every later one.
        let before = mtimeOf(providerBinary)
        let warm = runBuildCli(reproBin, projectRoot, actionCacheRoot, env)
        let line = providerLine(warm.output)
        checkpoint(name & "=" & value & ": " & line)
        if warm.exitCode != 0:
          checkpoint(warm.output)
        check warm.exitCode == 0
        check line.len > 0
        check "cache=cdHit" in line
        check "launched=false" in line
        # Out-of-band: the binary on disk was not re-produced.
        check mtimeOf(providerBinary) == before

      # Positive control: a change that DOES alter the provider recompiles,
      # so the hits above are not a probe that cannot see a compile.
      writeFile(projectRoot / "repro.nim", RecipeSource & "\n# control\n")
      let edited = runBuildCli(reproBin, projectRoot, actionCacheRoot,
        baseEnv())
      let editedLine = providerLine(edited.output)
      checkpoint("recipe edited: " & editedLine)
      check edited.exitCode == 0
      check "cache=cdMiss" in editedLine
      check "launched=true" in editedLine
