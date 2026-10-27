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
##
## The case does not own the engine checkout its provider compile is keyed
## on (every `.nim`/`.nims` under its `libs/`). A miss whose recompile
## reports a moved SOURCE fingerprint is that checkout changing under the
## case, not the shell; it is re-baselined and re-tried, a bounded number
## of times (see the loop below). Full suite run 38 (`ec078fc52e`) failed
## the TERM step once with `cache=cdMiss`. Re-run outside the suite against
## a build of `c4a1556cb`, 53 of 56 warm variations hit, and each of the 3
## misses coincided with an edit under that checkout's `libs/`.

import std/[os, osproc, streams, strtabs, strutils, times, unittest]

import repro_hash
import repro_interface_artifacts

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

const MaxBaselineAttempts = 3
  ## How many times one variation may be re-tried after the engine
  ## checkout moved under it. A checkout that keeps moving for that long
  ## is reported, not waited out.

proc sourcesFingerprint(artifactPath: string): ContentDigest =
  ## The provider compile's SOURCE fingerprint as the compile that produced
  ## `artifactPath` recorded it: the interface, the recipe's source closure
  ## and the engine's library sources — and nothing from the caller's
  ## environment or the compile command.
  readProviderCompileArtifact(artifactPath).providerFingerprint

proc digestHex(digest: ContentDigest): string =
  for b in digest.bytes[0 ..< 8]:
    result.add(toHex(b, 2).toLowerAscii)

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
      let providerBinary =
        projectRoot / ".repro" / "build" / "repro" / "provider" /
          "project-provider"
      let providerArtifact =
        projectRoot / ".repro" / "build" / "repro" / "provider-compile.rbsz"

      # A fresh action cache per baseline, so a re-baseline (below) is a real
      # cold compile and the variation that follows it can only hit the
      # record the BASE environment wrote.
      var baselines = 0
      var actionCacheRoot = ""
      proc coldBaseline(): ContentDigest =
        inc baselines
        actionCacheRoot = tempRoot / ("action-cache-" & $baselines)
        createDir(actionCacheRoot)
        let cold = runBuildCli(reproBin, projectRoot, actionCacheRoot,
          baseEnv())
        if cold.exitCode != 0:
          checkpoint(cold.output)
        require cold.exitCode == 0
        checkpoint("cold baseline " & $baselines & ": " &
          providerLine(cold.output))
        require fileExists(providerBinary)
        sourcesFingerprint(providerArtifact)

      var baseline = coldBaseline()

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
        # A miss is the caller's shell only if the provider's SOURCE
        # fingerprint did not move with it. That fingerprint covers the
        # recipe and every `.nim`/`.nims` under the engine checkout's
        # `libs/` (Compiles-Are-Normal-Edges.md, "The gate that survived
        # behind the edge"), which this test does not own: an edit to that
        # checkout while the case runs — another session's, or a suite
        # sibling's — re-keys the compile with no shell involved. Measured:
        # a comment-only `.nim` file added under `libs/` between the cold
        # build and a TERM variation turns the variation into a miss, and
        # removing it turns it back into a hit. So a miss whose recompile
        # reports a different source fingerprint re-establishes a cold
        # baseline from those sources and tries the variation again; a miss
        # with the sources unchanged fails at once. The re-baseline uses a
        # new action cache, so the retry cannot be served by the record the
        # missed variation itself wrote.
        var attempt = 0
        while true:
          inc attempt
          # Compared per step, so a recompile under one variation does not
          # also fail every later one.
          let before = mtimeOf(providerBinary)
          let warm = runBuildCli(reproBin, projectRoot, actionCacheRoot, env)
          let line = providerLine(warm.output)
          checkpoint(name & "=" & value & " (attempt " & $attempt & "): " &
            line)
          if warm.exitCode != 0:
            checkpoint(warm.output)
          check warm.exitCode == 0
          check line.len > 0
          if "cache=cdHit" notin line and attempt < MaxBaselineAttempts:
            let now = sourcesFingerprint(providerArtifact)
            if now != baseline:
              # Echoed as well as checkpointed: a re-baseline is worth seeing
              # in the log of a run that PASSES, too.
              let note = name & ": the provider's source fingerprint moved " &
                "under this case (" & digestHex(baseline) & " -> " &
                digestHex(now) & "): the engine checkout changed, not the " &
                "shell; re-baselining"
              echo note
              checkpoint(note)
              baseline = coldBaseline()
              continue
          check "cache=cdHit" in line
          check "launched=false" in line
          # Out-of-band: the binary on disk was not re-produced.
          check mtimeOf(providerBinary) == before
          break

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
