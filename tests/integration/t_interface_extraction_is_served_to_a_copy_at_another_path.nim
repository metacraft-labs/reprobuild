## t_interface_extraction_is_served_to_a_copy_at_another_path — a
## byte-identical recipe built from a second project directory that shares
## the action cache gets its project interface from the cache, not from a
## second extraction compile.
##
## What this test owns
## -------------------
## Hermetic-Builds-And-Path-Independence.md §"Engine-internal recipe
## compiles": the interface extraction (`__repro-extract-interface`) is keyed
## path-independently by default, so "a test fixture copied into a fresh
## temporary directory" is served by the record the first copy wrote. The
## provider compile's half of that promise is pinned by
## `t_provider_compile_follows_the_recipe`; nothing pinned the extraction's.
##
## The defect it guards against (reprobuild-specs issue 2026-10-17, "the
## identical relocatable interface-extraction edge misses the cache from each
## fresh project dir"), measured with reprobuild at `b6ef218db`: the second
## copy's extraction edge was skipped before its cache lookup with
##
##   nix-store-references-missing: /nix/store/<hash>-source=, ... named by
##   this action's outputs when they were produced are no longer in the Nix
##   store
##
## The interface artifact stores a `/nix/store/<hash>-source` path followed by
## a length byte that is also a Nix name character (`=`, `9`, `D`), so the
## reference scanner recorded paths that never existed. A copy at another
## path has no ledger manifest for the shared output, rescanned it, decided
## the store paths were lost, and re-ran the compile. Every fresh fixture
## directory in a suite run paid a full extraction while the others queued on
## its lock. Fixed by resolving a scanned reference by its hash (`86c42bf6e`).
##
## The engine's own account is the witness: the build report's
## `interfaceExtractActions` carries the extraction edge's settle state and
## miss reason, and `interfaceExtractTrace` its scheduler trace, so a failure
## here names the reason instead of only the wall time.
##
## The fixture is the recipe of `t_build_action_output_all_passes_action_output_through`
## (the suite case that exposed the defect): it imports the catalog's `sh`
## package, which is what puts the Nix store reference into the interface.
##
## MOCK POLICY — none. The real `build/bin/repro` runs real extraction
## compiles against real recipes in real directories.

import std/[json, os, osproc, strutils, tempfiles, unittest]
import repro_test_support/reasoned_skip

proc repoRoot(): string =
  currentSourcePath().parentDir.parentDir.parentDir

let reproBin = getEnv("REPROBUILD_REPRO",
  repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt))

const Recipe = """
import repro_project_dsl
import repro_dsl_stdlib/packages/sh

package interfaceCopyProbe:
  defaultToolProvisioning "path"

  uses:
    "sh"

  build:
    let keyed = shell(
      command = "mkdir -p build && printf 'k\\n' > build/keyed.txt",
      actionId = "interface-copy.keyed",
      extraOutputs = @["build/keyed.txt"])
    discard target("keyed", keyed)
"""

type BuildRun = object
  exitCode: int
  output: string
  report: JsonNode

proc buildCopy(project, actionCacheRoot: string): BuildRun =
  let res = execCmdEx(quoteShellCommand([reproBin, "build", "keyed",
    "--tool-provisioning=path", "--daemon=off", "--no-runquota",
    "--progress=quiet", "--log=quiet",
    "--action-cache-root=" & actionCacheRoot, "--write-report"]),
    workingDir = project)
  result.exitCode = res.exitCode
  result.output = res.output
  let reportPath = project / ".repro" / "build" / "repro" /
    "build-report.json"
  result.report =
    if fileExists(reportPath): parseFile(reportPath) else: newJObject()

proc extractionItems(run: BuildRun): seq[JsonNode] =
  for item in run.report{"interfaceExtractActions"}.getElems():
    result.add(item)

proc explain(run: BuildRun): string =
  "exit=" & $run.exitCode & "\n--- interfaceExtractActions ---\n" &
    $run.report{"interfaceExtractActions"} &
    "\n--- interfaceExtractTrace ---\n" &
    $run.report{"interfaceExtractTrace"} & "\n--- output ---\n" & run.output

suite "the interface extraction follows the recipe":

  test "a byte-identical copy at another path is served from the cache":
    when defined(windows):
      skip("recipe-relative extraction is POSIX-only " &
        "(recipeRelativeCompilePossible)")
    else:
      if not fileExists(reproBin):
        checkpoint("missing " & reproBin & "; run `just build` first")
        fail()
      else:
        # Both copies at the same depth: the relocatable record is keyed on
        # the depth of its working directory.
        let root = createTempDir("repro-iface-copy-", "")
        defer: removeDir(root)
        let actionCacheRoot = root / "action-cache"
        createDir(actionCacheRoot)
        let projectA = root / "a" / "project"
        let projectB = root / "b" / "project"
        for project in [projectA, projectB]:
          createDir(project)
          writeFile(project / "repro.nim", Recipe)

        let first = buildCopy(projectA, actionCacheRoot)
        checkpoint("A: " & explain(first))
        require first.exitCode == 0
        let itemsA = first.extractionItems()
        # The report really carries the edge: the cold copy ran it.
        require itemsA.len >= 1
        check itemsA[0]{"launched"}.getBool

        let second = buildCopy(projectB, actionCacheRoot)
        checkpoint("B: " & explain(second))
        require second.exitCode == 0
        let itemsB = second.extractionItems()
        require itemsB.len >= 1
        for item in itemsB:
          check not item{"launched"}.getBool
          check item{"cacheDecision"}.getStr in ["cdHit", "cdHybridCutoff"]
        check fileExists(projectB / ".repro" / "build" / "repro" /
          "project-interface.rbsz")
