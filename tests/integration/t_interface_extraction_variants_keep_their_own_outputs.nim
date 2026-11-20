## Interface extractions of one recipe that differ only in the environment
## they observe each keep their own result: switching back and forth between
## them extracts once per variant, not once per switch.
##
## reprobuild-specs issues/2026-10-12-interface-extraction-variants-of-one-
## recipe-overwrite-each-others-outputs.md: the recipe-relative extraction
## writes its outputs into ONE directory per location-independent identity
## (`recipeCompileOutputDir`), and that identity cannot name the environment
## the compile observes (the monitor records it only when the edge runs).
## The records ARE split by it. Records were metadata-only, so the second
## variant's run overwrote the first's outputs and the first variant's
## record, inputs unchanged, could not serve: every switch re-extracted.
## `t_e2e_codetracer_in_place_project_file` paid six full extractions per
## switch between its three PATH variants.
##
## Measured before the fix (agents @ da8b52f79, this fixture's shape): A, B,
## A, B extracted 4 times. The properties:
##
##   * THE VARIANTS ARE REAL: the B build extracts (its observed environment
##     differs, so A's record cannot serve it) — without this the rest is
##     vacuous;
##   * SWITCHING BACK IS SERVED: A again and B again extract nothing;
##   * A DIFFERENT COMPILER STILL RE-EXTRACTS: a PATH and compiler that
##     resolve another `nim` extract again, and switching back to A after it
##     extracts nothing.
##
## WHICH VARIABLE MAKES THE VARIANTS. The variants once differed in the
## caller's `PATH`. The extraction edge now declares its own `PATH` -- the
## directories of the resolved `nim` and C compiler
## (`recipeCompilePathEnvForModule`, reprobuild b05397a84fc) -- so a caller's
## `PATH` no longer reaches it, and two callers that differ only there
## rightly share one extraction. The variants here differ in `HOME`, which
## the compile genuinely reads and which the edge takes from the caller by
## value: with `XDG_CONFIG_HOME` not declared, `nim` looks for the user's
## `~/.config/nim` configuration under it, so a different `HOME` can change
## the compile and its record must not serve the other. Every other value
## is held equal between A and B, `XDG_CACHE_HOME` included, so `HOME` is
## the only difference.
##
## MOCK POLICY - none. The real `build/bin/repro` drives real compiles; the
## only stand-ins are shell wrappers around the real `nim` that count
## interface-extraction compiles before exec'ing it.

import std/[os, osproc, strutils, unittest]
import repro_test_support/reasoned_skip

const Recipe = """
import repro_project_dsl

package xvariantprobe:
  build:
    fs.writeText(actionId = "write-probe", output = "out/probe.txt",
      text = "probe\n")
"""

const WitnessLog = "xvariant-witness.log"

proc extractionCount(root: string): int =
  ## Interface-extraction compiles so far, summed over every log under the
  ## fixture root (one per nimcache configuration; another compiler is
  ## another configuration).
  for log in walkDirRec(root):
    if log.extractFilename != WitnessLog:
      continue
    for line in readFile(log).splitLines:
      if line.startsWith("extract "):
        inc result

proc writeWitness(dir, name, nim: string): string =
  ## A wrapper around the real `nim` that logs every interface-extraction
  ## compile. It logs INTO the extraction's own derived state (two levels
  ## above its `--nimcache:`, inside the shared interface nimcache root),
  ## which the edge declares machine-local derived state: a log anywhere
  ## else is a file the extraction writes and does not declare, the S7 gate
  ## rightly withholds the record's payloads for it, and the fixture would
  ## measure itself.
  createDir(dir)
  result = dir / "nim"
  writeFile(result, "#!/bin/sh\n" &
    "case \"$*\" in\n" &
    "  *--define:reproInterfaceMode*)\n" &
    "    for a in \"$@\"; do\n" &
    "      case \"$a\" in --nimcache:*) nc=\"${a#--nimcache:}\" ;; esac\n" &
    "    done\n" &
    "    w=\"${nc%/*}\"; w=\"${w%/*}\"\n" &
    "    echo 'extract " & name & "' >> \"$w/" & WitnessLog & "\" ;;\n" &
    "esac\nexec " & quoteShell(nim) & " \"$@\"\n")
  setFilePermissions(result, {fpUserRead, fpUserWrite, fpUserExec})

proc build(reproBin, path, home, cacheHome, witness, projectRoot,
           actionCacheRoot, storeRoot, tmp: string):
    tuple[output: string; exitCode: int] =
  let res = execCmdEx(quoteShellCommand([
    "env",
    "TMPDIR=" & tmp,
    # The shared interface nimcache (and the witness logs inside it) is under
    # the user cache directory.
    "XDG_CACHE_HOME=" & tmp / "cache",
    "PATH=" & path,
    "HOME=" & home,
    "XDG_CACHE_HOME=" & cacheHome,
    "REPRO_NIM_COMPILER=" & witness,
    "REPROBUILD_STORE_ROOT=" & storeRoot,
    "REPRO_STORE_ROOT=" & storeRoot,
    reproBin, "build",
    "--daemon=off",
    "--tool-provisioning=path",
    "--action-cache-root=" & actionCacheRoot,
    "--progress=quiet",
    projectRoot]))
  (output: res.output, exitCode: res.exitCode)

suite "interface extraction variants keep their own outputs":

  test "A, B, A, B extracts once per variant; another nim re-extracts":
    when defined(windows):
      skip("the recipe-relative interface extraction is POSIX-only")
    else:
      let repoRoot = getCurrentDir()
      let reproBin = repoRoot / "build" / "bin" / "repro".addFileExt(ExeExt)
      let nim = findExe("nim")
      if not fileExists(reproBin) or nim.len == 0:
        checkpoint("missing " & reproBin & " or nim; run `just build` first")
        fail()
      else:
        let tempRoot = "/tmp/rb-xvariant-" & $getCurrentProcessId()
        removeDir(tempRoot)
        createDir(tempRoot)
        defer: removeDir(tempRoot)
        let witnessA = writeWitness(tempRoot / "nim-a", "a", nim)
        let witnessC = writeWitness(tempRoot / "nim-c", "c", nim)
        let hostPath = getEnv("PATH")
        let pathA = parentDir(witnessA) & ":" & hostPath
        let pathC = parentDir(witnessC) & ":" & hostPath
        # A and B differ in HOME alone; both homes are private and empty, so
        # nothing else about the build differs between them. The cache base
        # is pinned to the caller's, so the provider nimcache stays warm and
        # is the same for both.
        let homeA = tempRoot / "home-a"
        let homeB = tempRoot / "home-b"
        createDir(homeA)
        createDir(homeB)
        let cacheHome = getCacheDir()
        let actionCacheRoot = tempRoot / "action-cache"
        let storeRoot = tempRoot / "store"
        # A private temporary directory, and a cache directory inside it
        # (`build`), so the shared interface nimcache and the witness logs
        # inside it belong to this fixture alone.
        createDir(tempRoot / "tmp")
        createDir(actionCacheRoot)
        let project = tempRoot / "project"
        createDir(project)
        writeFile(project / "repro.nim", Recipe)

        var failures: seq[string] = @[]
        proc step(label, path, home, witness: string): int =
          ## Build under one variant; the extraction count after it. A failed
          ## build or a wrong product is collected and asserted below.
          let res = build(reproBin, path, home, cacheHome, witness, project,
            actionCacheRoot, storeRoot, tempRoot / "tmp")
          if res.exitCode != 0:
            failures.add(label & " exited " & $res.exitCode & ":\n" &
              res.output)
          elif readFile(project / "out" / "probe.txt") != "probe\n":
            failures.add(label & ": wrong out/probe.txt")
          extractionCount(tempRoot)

        let afterA1 = step("A1", pathA, homeA, witnessA)
        let afterB1 = step("B1", pathA, homeB, witnessA)
        let afterA2 = step("A2", pathA, homeA, witnessA)
        let afterB2 = step("B2", pathA, homeB, witnessA)
        let afterC1 = step("C1", pathC, homeA, witnessC)
        let afterA3 = step("A3", pathA, homeA, witnessA)
        checkpoint("extractions after A1 B1 A2 B2 C1 A3: " &
          $[afterA1, afterB1, afterA2, afterB2, afterC1, afterA3])
        checkpoint(failures.join("\n"))
        check failures.len == 0
        check afterA1 >= 1
        # THE VARIANTS ARE REAL: B's record is not A's. If this fails while
        # the rest holds, the extraction no longer observes HOME and the
        # fixture needs another variable that it does observe.
        check afterB1 == afterA1 + 1
        # SWITCHING BACK IS SERVED, in both directions.
        check afterA2 == afterB1
        check afterB2 == afterB1
        # A DIFFERENT COMPILER STILL RE-EXTRACTS, and does not evict A.
        check afterC1 == afterB2 + 1
        check afterA3 == afterC1
