## t_an_unchanged_project_does_not_compile_its_provider_twice -- the second
## build of an unchanged checkout serves the provider compile from the cache.
##
## The defect (reprobuild-specs issue 2026-11-26-a-second-build-in-the-same-
## checkout-compiles-the-provider-again-on-both-edges). codetracer's re-run of
## an unchanged checkout compiled its recipe's provider again on BOTH edges,
## the recipe-relative one and the location-bound one, ten minutes under load.
## The two records of each edge (same weak fingerprint) differed in one input
## the build itself writes: `repro.paths`. The project's `config.nims` carries
## the managed `repro-paths-bootstrap` block, which includes `repro.paths`
## when it exists, and the provider compile evaluates that `config.nims`. The
## first build compiles the provider before its `generate_nim_paths_*` edge has
## written the file; the second build finds it, so its provider compile read a
## different input set and missed. The fix keeps the include out of the
## recipe's own compiles (`-d:reproProviderMode`, `-d:reproInterfaceMode`).
##
## What is graded. A recipe that generates `repro.paths` is built once in a
## scratch tree, to obtain the `config.nims` the build writes (the managed
## block). A fresh copy holding only what a checkout would track (`repro.nim`,
## that `config.nims` and `.gitignore`; no `repro.paths`, no `.repro`) is then built twice
## against its own empty action cache:
##
##   * the first build compiles the provider (positive control) and writes
##     `repro.paths`;
##   * the second must not compile it: its `providerCompileAction` line
##     reports `compiled=false` for the whole invocation.
##
## The `compiled=` field counts the compiles of the whole invocation in this
## process (`providerCompileLaunchedInThisProcess`), so it is the measurement
## of "the provider was compiled", and releases before this fix print it too,
## which is how the negative control was run.
##
## MOCK POLICY -- none. The real `build/bin/repro` (or `$REPROBUILD_REPRO`)
## compiles a real recipe in real directories.

import std/[os, osproc, strutils, tempfiles, unittest]
import repro_test_support/reasoned_skip

proc repoRoot(): string =
  currentSourcePath().parentDir.parentDir.parentDir

let reproBin = getEnv("REPROBUILD_REPRO",
  repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt))

const Recipe = """
import repro_project_dsl
import repro_dsl_stdlib/packages/sh

package pathsProviderProbe:
  defaultToolProvisioning "path"

  uses:
    "nim"
    "sh"

  build:
    discard nim.nimRepropathsConfig()
    # Builtins only: a shell action's PATH holds the package's declared
    # tools, and this recipe declares none besides `sh` and `nim`.
    let keyed = shell(
      command = "printf 'k\\n' > keyed.txt",
      actionId = "paths-provider.keyed",
      extraOutputs = @["keyed.txt"])
    discard target("keyed", keyed)
"""

proc build(project, actionCacheRoot, diagnostics: string):
    tuple[output: string, exitCode: int] =
  execCmdEx(quoteShellCommand([reproBin, "build", ".",
    "--tool-provisioning=path", "--daemon=off", "--no-runquota",
    "--progress=quiet", "--action-cache-root=" & actionCacheRoot,
    "--write-diagnostics=" & diagnostics]),
    workingDir = project)

proc providerLine(diagnostics: string): string =
  for line in readFile(diagnostics).splitLines():
    if line.startsWith("providerCompileAction:"):
      return line

suite "an unchanged project and its provider compile":
  test "the second build does not compile the provider":
    when defined(windows):
      skip("the managed repro.paths block is exercised on POSIX hosts")
    else:
      if not fileExists(reproBin):
        checkpoint("missing " & reproBin & "; run `just build` first")
        fail()
      else:
        let root = createTempDir("repro-provider-twice-", "")
        defer: removeDir(root)

        # The config.nims a build writes, from a throwaway tree.
        let seed = root / "seed" / "project"
        createDir(seed)
        writeFile(seed / "repro.nim", Recipe)
        let seedRun = build(seed, root / "seed-cache", root / "seed.diag")
        checkpoint("seed: exit=" & $seedRun.exitCode & "\n" & seedRun.output)
        require seedRun.exitCode == 0
        require fileExists(seed / "config.nims")
        require "repro-paths-bootstrap" in readFile(seed / "config.nims")
        require fileExists(seed / "repro.paths")

        # A fresh checkout: the tracked files only.
        let project = root / "checkout" / "project"
        createDir(project)
        writeFile(project / "repro.nim", Recipe)
        writeFile(project / "config.nims", readFile(seed / "config.nims"))
        if fileExists(seed / ".gitignore"):
          writeFile(project / ".gitignore", readFile(seed / ".gitignore"))
        let cache = root / "action-cache"
        createDir(cache)

        let first = build(project, cache, root / "first.diag")
        checkpoint("first: exit=" & $first.exitCode & "\n" & first.output)
        require first.exitCode == 0
        let firstLine = providerLine(root / "first.diag")
        checkpoint("first: " & firstLine)
        # Positive control: a fresh cache compiles.
        check "compiled=true" in firstLine
        check fileExists(project / "repro.paths")

        let second = build(project, cache, root / "second.diag")
        checkpoint("second: exit=" & $second.exitCode & "\n" & second.output)
        require second.exitCode == 0
        let secondLine = providerLine(root / "second.diag")
        checkpoint("second: " & secondLine)
        for line in readFile(root / "second.diag").splitLines():
          if line.startsWith("providerCompileEdge:") or
              line.startsWith("  cache-miss:"):
            checkpoint("second: " & line)
        check secondLine.len > 0
        check "compiled=false" in secondLine
