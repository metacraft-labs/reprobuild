## A recipe's interface extraction reuses the compiled library objects of an
## earlier extraction under the same compile configuration: a fresh
## action-cache root and an edited recipe recompile the recipe, not the
## ~220 C files of reprobuild and stdlib code it imports.
##
## reprobuild-specs issues/2026-10-22-recipe-interface-extraction-recompiles-
## library-code-per-cache-root-and-per-edit.md. The extraction's nimcache sat
## in its edge's output directory, under the action-cache root and named by
## the recipe's bytes, so neither case could reuse a single object: measured
## 290-310 s CPU for a one-line recipe in a fresh root and 249 s after a
## one-comment edit, against 2-3 s when nothing changed.
##
## The properties, each counted in compiled objects rather than time:
##
##   * THE INSTRUMENT DISCRIMINATES: the first, cold build compiles the
##     library (a large count), and its extraction really ran;
##   * A FRESH ACTION-CACHE ROOT re-runs the extraction (nothing in the new
##     root can serve it) and compiles at most a handful of objects;
##   * AN EDITED RECIPE re-runs the extraction and compiles at most a
##     handful of objects -- the recipe's own module, not the library.
##
## The counts are taken over every `.o` written anywhere under the fixture's
## root, which holds the action-cache roots AND the temporary directory the
## builds run with, so the property does not depend on where an
## implementation keeps its nimcache. Objects of the provider compile (its
## nimcache is `repro-nimcache-provider`) are not the subject and are left
## out.
##
## MOCK POLICY - none. The real `build/bin/repro` drives real compiles; the
## only stand-in is a shell wrapper around the real `nim` that logs each
## interface-extraction compile before exec'ing it, to show the extraction
## re-ran (without it, "no objects compiled" could mean "nothing ran").

import std/[os, osproc, strutils, times, unittest]
import repro_test_support/reasoned_skip

const Recipe = """
import repro_project_dsl

package objreuseprobe:
  build:
    fs.writeText(actionId = "write-probe", output = "out/probe.txt",
      text = "probe\n")
"""

const WitnessLog = "objreuse-witness.log"

proc writeWitness(dir, nim: string): string =
  ## Logs every interface-extraction compile two levels above its
  ## `--nimcache:`, which is inside the extraction's derived scratch state
  ## wherever the nimcache lives.
  createDir(dir)
  result = dir / "nim"
  writeFile(result, "#!/bin/sh\n" &
    "case \"$*\" in\n" &
    "  *--define:reproInterfaceMode*)\n" &
    "    for a in \"$@\"; do\n" &
    "      case \"$a\" in --nimcache:*) nc=\"${a#--nimcache:}\" ;; esac\n" &
    "    done\n" &
    "    w=\"${nc%/*}\"; w=\"${w%/*}\"\n" &
    "    echo extract >> \"$w/" & WitnessLog & "\" ;;\n" &
    "esac\nexec " & quoteShell(nim) & " \"$@\"\n")
  setFilePermissions(result, {fpUserRead, fpUserWrite, fpUserExec})

proc extractions(root: string): int =
  for path in walkDirRec(root):
    if path.extractFilename == WitnessLog:
      result += readFile(path).countLines - 1

proc objectsSince(root: string; since: Time): int =
  ## Interface-extraction C objects written at or after `since`.
  for path in walkDirRec(root):
    if path.endsWith(".o") and "repro-nimcache-provider" notin path and
        getLastModificationTime(path) >= since:
      inc result

suite "interface extraction reuses library objects":

  test "a fresh action-cache root and an edited recipe recompile the recipe only":
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
        # Short, like the other recipe-relative fixtures: sockets are bound
        # under the TMPDIR handed to the builds.
        let tempRoot = "/tmp/rb-objreuse-" & $getCurrentProcessId()
        removeDir(tempRoot)
        createDir(tempRoot)
        defer: removeDir(tempRoot)
        let witness = writeWitness(tempRoot / "nim-witness", nim)
        let tmp = tempRoot / "tmp"
        let storeRoot = tempRoot / "store"
        let project = tempRoot / "project"
        createDir(tmp)
        createDir(project)
        writeFile(project / "repro.nim", Recipe)

        var failures: seq[string] = @[]
        proc step(label, actionCacheRoot: string):
            tuple[objects, extracted: int] =
          createDir(actionCacheRoot)
          let before = extractions(tempRoot)
          let since = getTime()
          # Coarse-timestamp filesystems: keep the boundary unambiguous.
          sleep(1100)
          let res = execCmdEx(quoteShellCommand([
            "env",
            "TMPDIR=" & tmp,
            "PATH=" & parentDir(witness) & ":" & getEnv("PATH"),
            "REPRO_NIM_COMPILER=" & witness,
            "REPROBUILD_STORE_ROOT=" & storeRoot,
            "REPRO_STORE_ROOT=" & storeRoot,
            reproBin, "build",
            "--daemon=off",
            "--tool-provisioning=path",
            "--action-cache-root=" & actionCacheRoot,
            "--progress=quiet",
            project]))
          if res.exitCode != 0:
            failures.add(label & " exited " & $res.exitCode & ":\n" &
              res.output)
          elif readFile(project / "out" / "probe.txt") != "probe\n":
            failures.add(label & ": wrong out/probe.txt")
          (objects: objectsSince(tempRoot, since),
           extracted: extractions(tempRoot) - before)

        let cold = step("cold", tempRoot / "cache-1")
        let freshRoot = step("fresh root", tempRoot / "cache-2")
        writeFile(project / "repro.nim", Recipe & "# an edit\n")
        let edited = step("edited recipe", tempRoot / "cache-2")
        checkpoint("compiled objects / extractions: cold " & $cold &
          ", fresh root " & $freshRoot & ", edited " & $edited)
        checkpoint(failures.join("\n"))
        check failures.len == 0
        # THE INSTRUMENT DISCRIMINATES.
        check cold.extracted >= 1
        check cold.objects >= 50
        # A FRESH ACTION-CACHE ROOT: re-extracted, library reused.
        check freshRoot.extracted >= 1
        check freshRoot.objects <= 3
        # AN EDITED RECIPE: re-extracted, library reused.
        check edited.extracted >= 1
        check edited.objects <= 3
