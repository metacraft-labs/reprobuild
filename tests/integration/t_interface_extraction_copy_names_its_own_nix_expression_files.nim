## t_interface_extraction_copy_names_its_own_nix_expression_files — a copy
## of a recipe served the interface another copy extracted names ITS OWN
## Nix expression files, never the other copy's.
##
## What this test owns
## -------------------
## Hermetic-Builds-And-Path-Independence.md §"Engine-internal recipe
## compiles": the interface extraction is keyed path-independently, so one
## record answers every copy of a recipe, and "what the compile writes is
## relocatable: an interface artifact's source locations outside the anchors
## are written relative to the recipe, and are rebased onto the consulting
## location". `t_interface_extraction_is_served_to_a_copy_at_another_path`
## pins that the second copy is SERVED; this test pins that what it is served
## describes the second copy.
##
## The defect it guards against (reprobuild-pm issue 2026-11-11, "a relocated
## interface artifact carries the producing checkout's nix expression paths"),
## measured with reprobuild at `d0469cdda`: `nixPackage ..., expressionFile`
## is absolutised against the declaring file at macro time, and the artifact
## codec relocated `SourceLocation`s but wrote `expressionFile` verbatim; the
## CLI also copied the edge's Nim stub verbatim, which the extraction runner
## wrote from the producer's absolute artifact. A sibling checkout of
## codetracer-trace-format then failed with
##
##   Daemon resolution error: Nix expression file does not exist:
##   <the other, removed checkout>/ci/native-compiler-profiles.nix
##
## The witness is the bytes the second copy's build left at its own interface
## paths (`project-interface.rbsz` and the stub `project-interface.nim`), read
## after the FIRST copy has been deleted, as in the observed failure.
##
## MOCK POLICY — none. The real `build/bin/repro` runs real extraction
## compiles against real recipes in real directories. The Nix expression file
## is never evaluated: the build provisions tools from PATH (`bin/sh`). The
## recipe declares it twice: in a package the root uses (it reaches the
## interface artifact) and in a `provisioningFor` contribution (it reaches
## the Nim stub too, which emits contributions only).

import std/[json, os, osproc, strutils, tempfiles, unittest]
import repro_test_support/reasoned_skip

proc repoRoot(): string =
  currentSourcePath().parentDir.parentDir.parentDir

let reproBin = getEnv("REPROBUILD_REPRO",
  repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt))

const Recipe = """
import repro_project_dsl
import repro_dsl_stdlib/packages/sh

package nixPathCopyProbe:
  defaultToolProvisioning "path"

  uses:
    "sh"
    "nixPathCopyTool"

  build:
    let keyed = shell(
      command = "mkdir -p build && printf 'k\\n' > build/keyed.txt",
      actionId = "nix-path-copy.keyed",
      extraOutputs = @["build/keyed.txt"])
    discard target("keyed", keyed)

package nixPathCopyTool:
  provisioning:
    nixPackage "nixPathCopyTool", executablePath = "bin/sh",
      expressionFile = "ci/probe-tool.nix",
      lockIdentity = "nix-path-copy-probe"


provisioningFor "sh":
  developInterface
  contributor "nix-path-copy-contribution"
  nixPackage "nixPathCopySh", executablePath = "bin/sh",
    expressionFile = "ci/probe-tool.nix",
    lockIdentity = "nix-path-copy-contribution"
"""

const Expression = "{ }: throw \"never evaluated by this test\"\n"

proc buildCopy(project, actionCacheRoot: string): tuple[output: string;
    exitCode: int] =
  execCmdEx(quoteShellCommand([reproBin, "build", "keyed",
    "--tool-provisioning=path", "--daemon=off", "--no-runquota",
    "--progress=quiet", "--log=quiet",
    "--action-cache-root=" & actionCacheRoot, "--write-report"]),
    workingDir = project)

proc extractionItems(project: string): seq[JsonNode] =
  let reportPath = project / ".repro" / "build" / "repro" /
    "build-report.json"
  if fileExists(reportPath):
    for item in parseFile(reportPath){"interfaceExtractActions"}.getElems():
      result.add(item)

suite "an interface served to a copy names the copy's own files":

  test "nix expressionFile and the stub are rebased onto the consulting copy":
    when defined(windows):
      skip("recipe-relative extraction is POSIX-only " &
        "(recipeRelativeCompilePossible)")
    else:
      if not fileExists(reproBin):
        checkpoint("missing " & reproBin & "; run `just build` first")
        fail()
      else:
        # Both copies at the same depth: the relocatable record is keyed on
        # the depth of its working directory, so this is the case served.
        let root = createTempDir("repro-iface-nixpath-", "")
        defer: removeDir(root)
        let actionCacheRoot = root / "action-cache"
        createDir(actionCacheRoot)
        let projectA = root / "a" / "project"
        let projectB = root / "b" / "project"
        for project in [projectA, projectB]:
          createDir(project / "ci")
          writeFile(project / "repro.nim", Recipe)
          writeFile(project / "ci" / "probe-tool.nix", Expression)

        let first = buildCopy(projectA, actionCacheRoot)
        checkpoint("A: exit=" & $first.exitCode & "\n" & first.output)
        require first.exitCode == 0
        let artifactA = projectA / ".repro" / "build" / "repro" /
          "project-interface.rbsz"
        # Positive control: the interface really carries the expression
        # file, so its absence from B's bytes below is not vacuous.
        require readFile(artifactA).contains(
          projectA / "ci" / "probe-tool.nix")
        require readFile(projectA / ".repro" / "build" / "repro" /
          "project-interface.nim").contains(projectA / "ci" / "probe-tool.nix")
        # The observed failure: the producing checkout is gone.
        removeDir(root / "a")

        let second = buildCopy(projectB, actionCacheRoot)
        checkpoint("B: exit=" & $second.exitCode & "\n" & second.output)
        require second.exitCode == 0
        # The copy really was served A's record; otherwise it extracted its
        # own interface and the checks below would pass vacuously.
        let itemsB = extractionItems(projectB)
        checkpoint("B extraction: " & $itemsB)
        require itemsB.len >= 1
        for item in itemsB:
          require not item{"launched"}.getBool
        let outB = projectB / ".repro" / "build" / "repro"
        for name in ["project-interface.rbsz", "project-interface.nim"]:
          let bytes = readFile(outB / name)
          checkpoint(name & ":\n" & bytes)
          check projectA notin bytes
        check readFile(outB / "project-interface.rbsz").contains(
          projectB / "ci" / "probe-tool.nix")
