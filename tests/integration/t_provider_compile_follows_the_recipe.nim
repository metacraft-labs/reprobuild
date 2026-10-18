## The provider compile is served to a byte-identical copy of the recipe at
## another path, and the provider it serves works THERE.
##
## Hermetic-Builds-And-Path-Independence.md §"Engine-internal recipe
## compiles", stage 2 (owner decision 2026-10-11, "relative on the wire"):
## the provider-compile edge runs in the recipe's directory, is keyed by
## recipe-relative identities, writes its outputs under the action-cache
## root, and produces a binary that names the recipe's own files relative to
## the recipe. The engine launches it with its working directory at the
## project root and resolves the relative paths in its responses there
## (Provider-Runtime-Protocol-v1.md, "Paths in responses").
##
## Measured before the change (agents @ 652dce595, same fixture): the copy at
## B paid a full provider compile (61 s of a 61 s build). The properties:
##
##   * SERVED: the copy at B does not run the compiler (witness compiler
##     count) and the provider-compile line says so;
##   * CORRECT AT B: the project-root fallback for a package the provider
##     does not own names B's directory, and B's provider-graph snapshot
##     records B's recipe as its evaluation input, not A's;
##   * NOT OVER-SHARED: an edit to B's recipe compiles again;
##   * NOT SHARED WHEN LOCATION-BOUND: a recipe whose provider bakes in its
##     own absolute location (`currentSourcePath()`) is compiled at each
##     copy, so each copy evaluates its own paths and keeps its cache hits.
##
## MOCK POLICY - none. The real `build/bin/repro` drives real compiles; the
## only stand-in is a shell wrapper around the real `nim` that counts
## provider compiles before exec'ing it.

import std/[os, osproc, strutils, unittest]

const OtherModule = """
import repro_project_dsl

package relocother:
  build:
    discard
"""

const Recipe = """
import repro_project_dsl
import other

package relocprobe:
  build:
    fs.writeText(actionId = "write-root", output = "out/root.txt",
      text = packageProjectRoot("relocother") & "\n")
"""

const BakedRecipe = """
import std/os
import repro_project_dsl
import other

const recipeRoot = parentDir(currentSourcePath())

package relocprobe:
  build:
    fs.writeText(actionId = "write-baked-root", output = "out/root.txt",
      text = recipeRoot & "\n")
"""

const ProviderLinePrefix = "providerCompileAction: __repro_provider_compile"

proc providerLine(output: string): string =
  for line in output.splitLines:
    let stripped = line.strip()
    if stripped.startsWith(ProviderLinePrefix):
      return stripped
  ""

proc compileCount(log: string): int =
  if not fileExists(log):
    return 0
  for line in readFile(log).splitLines:
    if line == "provider":
      inc result

proc writeProject(dir, recipe: string) =
  createDir(dir)
  writeFile(dir / "other.nim", OtherModule)
  writeFile(dir / "repro.nim", recipe)

proc build(reproBin, witness, projectRoot, actionCacheRoot, storeRoot: string):
    tuple[output: string; exitCode: int] =
  let res = execCmdEx(quoteShellCommand([
    "env",
    "REPRO_NIM_COMPILER=" & witness,
    "REPROBUILD_STORE_ROOT=" & storeRoot,
    "REPRO_STORE_ROOT=" & storeRoot,
    reproBin, "build",
    "--daemon=off",
    "--tool-provisioning=path",
    "--action-cache-root=" & actionCacheRoot,
    "--progress=quiet",
    "--log=actions",
    projectRoot]))
  (output: res.output, exitCode: res.exitCode)

proc snapshotOf(projectRoot: string): string =
  for path in walkDirRec(projectRoot / ".repro"):
    if extractFilename(path) == "provider-fragments.rbsz":
      return readFile(path)
  ""

suite "the provider compile follows the recipe":

  test "a copy at another path is served, and its provider runs there":
    let repoRoot = getCurrentDir()
    let reproBin = repoRoot / "build" / "bin" / addFileExt("repro", ExeExt)
    let nim = findExe("nim")
    if not fileExists(reproBin) or nim.len == 0:
      checkpoint("missing " & reproBin & " or nim; run `just build` first")
      fail()
    else:
      # A short root, and A and B at the same depth: the relocatable record
      # is keyed on the depth of its working directory.
      let tempRoot = "/tmp/rb-provreloc-" & $getCurrentProcessId()
      removeDir(tempRoot)
      createDir(tempRoot)
      defer: removeDir(tempRoot)
      let compileLog = tempRoot / "provider-compiles"
      let witness = tempRoot / "witness-nim"
      writeFile(witness, "#!/bin/sh\n" &
        "case \"$*\" in\n" &
        "  *--define:reproProviderMode*) echo provider >> " &
          quoteShell(compileLog) & " ;;\n" &
        "esac\nexec " & quoteShell(nim) & " \"$@\"\n")
      setFilePermissions(witness, {fpUserRead, fpUserWrite, fpUserExec})
      let actionCacheRoot = tempRoot / "action-cache"
      let storeRoot = tempRoot / "store"
      createDir(actionCacheRoot)
      let projectA = tempRoot / "a" / "project"
      let projectB = tempRoot / "b" / "project"
      writeProject(projectA, Recipe)
      writeProject(projectB, Recipe)

      let first = build(reproBin, witness, projectA, actionCacheRoot,
        storeRoot)
      if first.exitCode != 0:
        checkpoint(first.output)
      require first.exitCode == 0
      let compiledAtA = compileCount(compileLog)
      checkpoint("A: " & providerLine(first.output))
      check compiledAtA >= 1
      check readFile(projectA / "out" / "root.txt").strip() == projectA

      # --- B: the same bytes at another path. ---------------------------
      let second = build(reproBin, witness, projectB, actionCacheRoot,
        storeRoot)
      if second.exitCode != 0:
        checkpoint(second.output)
      require second.exitCode == 0
      let lineAtB = providerLine(second.output)
      checkpoint("B: " & lineAtB)
      # SERVED: no compiler ran for B.
      check compileCount(compileLog) == compiledAtA
      check "launched=false" in lineAtB
      check "compiled=false" in lineAtB
      # CORRECT AT B: the provider resolves the recipe's own paths at B.
      check fileExists(projectB / ".repro" / "build" / "repro" / "provider" /
        "project-provider")
      check readFile(projectB / "out" / "root.txt").strip() == projectB
      let snapshotB = snapshotOf(projectB)
      check snapshotB.len > 0
      check (projectB / "repro.nim") in snapshotB
      check projectA notin snapshotB

      # --- NOT OVER-SHARED: B's own edit compiles. ----------------------
      writeFile(projectB / "repro.nim", Recipe & "# edited at B\n")
      let edited = build(reproBin, witness, projectB, actionCacheRoot,
        storeRoot)
      if edited.exitCode != 0:
        checkpoint(edited.output)
      require edited.exitCode == 0
      checkpoint("B edited: " & providerLine(edited.output))
      check compileCount(compileLog) > compiledAtA
      check readFile(projectB / "out" / "root.txt").strip() == projectB

  test "a recipe that bakes in its own location is compiled at each location":
    # `currentSourcePath()` is absolute in a recipe-relative compile too, and
    # a recipe may evaluate it (CodeTracer: `projectRootPath =
    # parentDir(currentSourcePath())` in a `const`, joined onto every
    # `--path` of its `nim js` edges). Served to another copy, such a binary
    # evaluates the copy that COMPILED it. Measured at 5276f7284 with this
    # shape of recipe and one shared action-cache root: A, then B (which
    # recompiled the shared binary), then A again wrote B's directory into
    # A's output and re-ran A's action - the key moved between two builds of
    # an unchanged tree, and the output named the wrong project.
    let repoRoot = getCurrentDir()
    let reproBin = repoRoot / "build" / "bin" / addFileExt("repro", ExeExt)
    let nim = findExe("nim")
    if not fileExists(reproBin) or nim.len == 0:
      checkpoint("missing " & reproBin & " or nim; run `just build` first")
      fail()
    else:
      let tempRoot = "/tmp/rb-provbaked-" & $getCurrentProcessId()
      removeDir(tempRoot)
      createDir(tempRoot)
      defer: removeDir(tempRoot)
      let compileLog = tempRoot / "provider-compiles"
      let witness = tempRoot / "witness-nim"
      writeFile(witness, "#!/bin/sh\n" &
        "case \"$*\" in\n" &
        "  *--define:reproProviderMode*) echo provider >> " &
          quoteShell(compileLog) & " ;;\n" &
        "esac\nexec " & quoteShell(nim) & " \"$@\"\n")
      setFilePermissions(witness, {fpUserRead, fpUserWrite, fpUserExec})
      let actionCacheRoot = tempRoot / "action-cache"
      let storeRoot = tempRoot / "store"
      createDir(actionCacheRoot)
      let projectA = tempRoot / "a" / "project"
      let projectB = tempRoot / "b" / "project"
      writeProject(projectA, BakedRecipe)
      writeProject(projectB, BakedRecipe)

      for (label, project) in [("A", projectA), ("B", projectB),
                               ("A again", projectA)]:
        let res = build(reproBin, witness, project, actionCacheRoot,
          storeRoot)
        if res.exitCode != 0:
          checkpoint(res.output)
        require res.exitCode == 0
        checkpoint(label & ": " & providerLine(res.output))
        # CORRECT AT EACH COPY: the baked location is this copy's own.
        check readFile(project / "out" / "root.txt").strip() == project
        if label == "A again":
          # STABLE: nothing changed at A, so its edge is not re-run.
          check "action: write-baked-root status=asUpToDate" in res.output
      # B could not be served A's binary: it compiled its own.
      check compileCount(compileLog) >= 2
