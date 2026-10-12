## Interface extractions of one recipe that differ only in the environment
## they observe each keep their own result: switching back and forth between
## them extracts once per variant, not once per switch.
##
## reprobuild-specs issues/2026-10-12-interface-extraction-variants-of-one-
## recipe-overwrite-each-others-outputs.md: the recipe-relative extraction
## writes its outputs into ONE directory per location-independent identity
## (`recipeCompileOutputDir`), and that identity cannot name the environment
## the compile observes (`PATH` here — the monitor records it only when the
## edge runs). The records ARE split by it. Records were metadata-only, so
## the second variant's run overwrote the first's outputs and the first
## variant's record, inputs unchanged, could not serve: every switch
## re-extracted. `t_e2e_codetracer_in_place_project_file` paid six full
## extractions per switch between its three PATH variants.
##
## Measured before the fix (agents @ da8b52f79, this fixture's shape): PATH
## A, B, A, B extracted 4 times. The properties:
##
##   * THE VARIANTS ARE REAL: the B build extracts (its observed PATH differs,
##     so A's record cannot serve it) — without this the rest is vacuous;
##   * SWITCHING BACK IS SERVED: A again and B again extract nothing;
##   * A DIFFERENT COMPILER STILL RE-EXTRACTS: a PATH and compiler that
##     resolve another `nim` extract again, and switching back to A after it
##     extracts nothing.
##
## MOCK POLICY - none. The real `build/bin/repro` drives real compiles; the
## only stand-ins are shell wrappers around the real `nim` that count
## interface-extraction compiles before exec'ing it. Being shell scripts
## they read `PATH`, which is what makes the observed environment differ —
## as the CodeTracer recipe does, resolving `sh`, `find` and `sort` there.

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

proc extractionCount(actionCacheRoot: string): int =
  ## Interface-extraction compiles so far, summed over every extraction
  ## directory (one per identity; another compiler is another identity).
  for log in walkFiles(actionCacheRoot / "recipe-compiles" / "interface" /
      "*" / "work" / WitnessLog):
    for line in readFile(log).splitLines:
      if line.startsWith("extract "):
        inc result

proc writeWitness(dir, name, nim: string): string =
  ## A wrapper around the real `nim` that logs every interface-extraction
  ## compile. It logs INTO the extraction's own derived scratch tree (two
  ## levels above its `--nimcache:`, the edge's `work/`), which the edge
  ## declares machine-local derived state: a log anywhere else is a file the
  ## extraction writes and does not declare, the S7 gate rightly withholds
  ## the record's payloads for it, and the fixture would measure itself.
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

proc build(reproBin, path, witness, projectRoot, actionCacheRoot,
           storeRoot: string): tuple[output: string; exitCode: int] =
  let res = execCmdEx(quoteShellCommand([
    "env",
    "PATH=" & path,
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

  test "PATH A, B, A, B extracts once per variant; another nim re-extracts":
    when defined(windows):
      skip("the recipe-relative interface extraction is POSIX-only")
    else:
      let repoRoot = getCurrentDir()
      let reproBin = repoRoot / "build" / "bin" / "repro"
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
        let emptyDir = tempRoot / "empty-bin"
        createDir(emptyDir)
        let hostPath = getEnv("PATH")
        let pathA = parentDir(witnessA) & ":" & hostPath
        let pathB = emptyDir & ":" & pathA
        let pathC = parentDir(witnessC) & ":" & hostPath
        let actionCacheRoot = tempRoot / "action-cache"
        let storeRoot = tempRoot / "store"
        createDir(actionCacheRoot)
        let project = tempRoot / "project"
        createDir(project)
        writeFile(project / "repro.nim", Recipe)

        var failures: seq[string] = @[]
        proc step(label, path, witness: string): int =
          ## Build under one variant; the extraction count after it. A failed
          ## build or a wrong product is collected and asserted below.
          let res = build(reproBin, path, witness, project, actionCacheRoot,
            storeRoot)
          if res.exitCode != 0:
            failures.add(label & " exited " & $res.exitCode & ":\n" &
              res.output)
          elif readFile(project / "out" / "probe.txt") != "probe\n":
            failures.add(label & ": wrong out/probe.txt")
          extractionCount(actionCacheRoot)

        let afterA1 = step("A1", pathA, witnessA)
        let afterB1 = step("B1", pathB, witnessA)
        let afterA2 = step("A2", pathA, witnessA)
        let afterB2 = step("B2", pathB, witnessA)
        let afterC1 = step("C1", pathC, witnessC)
        let afterA3 = step("A3", pathA, witnessA)
        checkpoint("extractions after A1 B1 A2 B2 C1 A3: " &
          $[afterA1, afterB1, afterA2, afterB2, afterC1, afterA3])
        checkpoint(failures.join("\n"))
        check failures.len == 0
        check afterA1 >= 1
        # THE VARIANTS ARE REAL.
        check afterB1 == afterA1 + 1
        # SWITCHING BACK IS SERVED, in both directions.
        check afterA2 == afterB1
        check afterB2 == afterB1
        # A DIFFERENT COMPILER STILL RE-EXTRACTS, and does not evict A.
        check afterC1 == afterB2 + 1
        check afterA3 == afterC1
