## ``repro clean`` and the graph-refresh pruning resolve an output against
## the working directory of the action that writes it, not against the
## project root (clean.md §"Ownership Records").
##
## An action that runs in ``src/tool`` spells its declared outputs relative to
## that directory. The provider claims each output with the action's own
## spelling, so resolving a claim against the project root either refused it
## (``../../build/tool.bin`` leaves the root) or named a file the action does
## not write (``tool.out`` is ``<root>/tool.out``, not
## ``<root>/src/tool/tool.out``, and ``<root>/tool.out`` may be the user's).
## reprobuild-pm issues/2026-11-15-repro-clean-resolves-a-cwd-relative-output-against-the-project-root.md.
##
## The fixture has two process actions:
##
##   * an inline exec call run with ``cwd = "src/tool"``, declaring
##     ``tool.out`` and ``../../build/tool.bin``;
##   * an action with ``cwdKind = acwdCustom`` and
##     ``cwdCustomPath = "src/tool"``, declaring ``lib.out``.
##
## The user's files ``<root>/tool.out`` and ``<root>/lib.out`` are planted
## after the build. The cases check that ``repro clean`` removes the three
## real outputs and keeps both user files, and that a rebuild after both
## actions left the recipe prunes the same three outputs and keeps the files.
##
## No mocks: the test spawns the built ``repro`` binary against a real
## fixture project.

import repro_test_support/reasoned_skip
import std/[os, osproc, strutils, unittest]

const reproBinary =
  when defined(windows): "build/bin/repro.exe" else: "build/bin/repro"

const RepoMarker = "repro.nim"

proc findRepoRoot(): string =
  var dir = currentSourcePath().parentDir
  while dir.len > 0:
    if fileExists(dir / RepoMarker) and fileExists(dir / "repro_tests.nim"):
      return dir
    let parent = dir.parentDir
    if parent == dir:
      break
    dir = parent
  raise newException(IOError,
    "cannot locate reprobuild repo root from " & currentSourcePath())

proc q(value: string): string = quoteShell(value)

const FullRecipe = """
import repro_dsl_stdlib

package actioncwdclean:
  defaultToolProvisioning "path"
  build:
    let keep = fs.copyFile("src/main.txt", "build/main.txt",
      actionId = "copy_main")
    let tool = buildAction(id = "tool_in_subdir",
      call = inlineExecCall(@["sh", "-c",
        "mkdir -p ../../build && echo t > tool.out && echo b > ../../build/tool.bin"],
        "src/tool"),
      outputs = @["tool.out", "../../build/tool.bin"])
    let lib = buildAction(id = "lib_in_subdir",
      call = inlineExecCall(@["sh", "-c", "echo l > lib.out"]),
      outputs = @["lib.out"], cwdKind = acwdCustom,
      cwdCustomPath = "src/tool")
    target("all", @[keep, tool, lib])
"""

const ShrunkRecipe = """
import repro_dsl_stdlib

package actioncwdclean:
  defaultToolProvisioning "path"
  build:
    let keep = fs.copyFile("src/main.txt", "build/main.txt",
      actionId = "copy_main")
    target("all", @[keep])
"""

type Fixture = object
  repoRoot, reproAbs, scratch, projRoot: string

proc newFixture(repoRoot, tag: string): Fixture =
  result.repoRoot = repoRoot
  result.reproAbs = repoRoot / reproBinary
  result.scratch = getTempDir() / ("t_repro_clean_action_cwd-" & tag & "-" &
    $getCurrentProcessId())
  removeDir(result.scratch)
  createDir(result.scratch)
  result.projRoot = result.scratch / "proj"
  createDir(result.projRoot / "src" / "tool")
  writeFile(result.projRoot / "src" / "main.txt", "main\n")
  writeFile(result.projRoot / "repro.nim", FullRecipe)

proc build(f: Fixture): tuple[code: int; output: string] =
  let cmd = q(f.reproAbs) & " build " & q(f.projRoot / "repro.nim") &
    " --tool-provisioning=path --daemon=off --no-runquota" &
    " --log=summary --progress=quiet --measure=none" &
    " --action-cache-root=" & q(f.scratch / "action-cache")
  let res = execCmdEx(cmd, workingDir = f.repoRoot)
  (code: res.exitCode, output: res.output)

proc clean(f: Fixture; extra = ""): tuple[code: int; output: string] =
  let res = execCmdEx(q(f.reproAbs) & " clean" & extra,
    workingDir = f.projRoot)
  (code: res.exitCode, output: res.output)

proc actionOutputs(f: Fixture): seq[string] =
  @[f.projRoot / "src" / "tool" / "tool.out",
    f.projRoot / "build" / "tool.bin",
    f.projRoot / "src" / "tool" / "lib.out"]

proc userFiles(f: Fixture): seq[string] =
  @[f.projRoot / "tool.out", f.projRoot / "lib.out"]

proc buildAndPlant(f: Fixture) =
  let (code, output) = f.build()
  checkpoint(output)
  check code == 0
  for path in f.actionOutputs():
    check fileExists(path)
  for path in f.userFiles():
    writeFile(path, "user\n")

suite "repro clean resolves an output against its action's cwd":

  test "t_repro_clean_removes_the_file_a_subdirectory_action_writes":
    let repoRoot = findRepoRoot()
    if not fileExists(repoRoot / reproBinary):
      skip("build/bin/repro not built; this case spawns the repro binary " &
        "(run `just build` first)")
    else:
      let f = newFixture(repoRoot, "clean")
      defer: removeDir(f.scratch)
      f.buildAndPlant()

      let (codeDry, outDry) = f.clean(" --dry-run")
      checkpoint(outDry)
      check codeDry == 0
      for path in f.userFiles():
        check ("would remove " & path) notin outDry
      for path in f.actionOutputs():
        check ("would remove " & path) in outDry
        check fileExists(path)

      let (code, output) = f.clean()
      checkpoint(output)
      check code == 0
      check "outside the project root" notin output
      for path in f.actionOutputs():
        check not fileExists(path)
      for path in f.userFiles():
        check fileExists(path)
        if fileExists(path): check readFile(path) == "user\n"
      check not fileExists(f.projRoot / "build" / "main.txt")

  test "t_repro_clean_graph_refresh_prunes_the_file_a_subdirectory_action_wrote":
    let repoRoot = findRepoRoot()
    if not fileExists(repoRoot / reproBinary):
      skip("build/bin/repro not built; this case spawns the repro binary " &
        "(run `just build` first)")
    else:
      let f = newFixture(repoRoot, "prune")
      defer: removeDir(f.scratch)
      f.buildAndPlant()

      # Both actions leave the recipe; the refresh drops their claims.
      writeFile(f.projRoot / "repro.nim", ShrunkRecipe)
      let (code, output) = f.build()
      checkpoint(output)
      check code == 0
      check "outputCleanup REFUSED" notin output
      for path in f.actionOutputs():
        check not fileExists(path)
      for path in f.userFiles():
        check fileExists(path)
        if fileExists(path): check readFile(path) == "user\n"
