## The source root the payload stagers fill (`share/repro/source`).
##
## `reprobuildShippedTreeComponents` ships `prebuilt/tree/share/repro/source`
## as ONE `crSourceTree`, so the package carries exactly what the stager put
## there and nothing in the layer can add a file the stager forgot. The
## release archives' stager shipped `config.nims` beside `libs/`; the two
## payload stagers copied `libs/` alone, so every package the layer built had
## a source root the profile compile refuses. The cases below run the payload
## stagers' own staging function against this checkout and hand the result to
## that refusal, and pin every stager of a source root to the one list.
##
## A file of its own rather than a suite of `t_packaging_shipped_payload`:
## the first case runs `sh`, and that file's cases are pure.

import std/[os, osproc, strutils, unittest]

from repro_profile_compile/compile import requireReprobuildSources,
  CompileFailure
import ./packaging_test_support

const
  SourceRootHelperRel = "scripts/lib/stage_source_root.sh"
  PayloadStagerRels = ["scripts/stage_payload_linux.sh",
                       "scripts/stage_payload_windows.sh"]
  ReleaseStagerRel = "scripts/release/stage_release_sources.sh"

proc codeLines(rel: string): seq[string] =
  ## A staging script's lines with comments dropped, so a case below reads
  ## what the script DOES rather than what its prose mentions.
  let path = repoRootFromTest() & "/" & rel
  doAssert fileExists(path), "staging script not found at " & path
  for line in readFile(path).splitLines():
    let stripped = line.strip()
    if stripped.len > 0 and not stripped.startsWith("#"):
      result.add(stripped)

proc sourcesHelper(lines: seq[string]): bool =
  for line in lines:
    if (line.startsWith(". ") or line.startsWith("source ")) and
        line.contains("lib/stage_source_root.sh"):
      return true

proc stageSourceRoot(dest: string): tuple[output: string, exitCode: int] =
  ## Run the payload stagers' `stage_source_root` against this checkout.
  let root = repoRootFromTest()
  let script = ". " & quoteShell(root & "/" & SourceRootHelperRel) &
    " && stage_source_root " & quoteShell(root) & " " & quoteShell(dest)
  result = execCmdEx("sh -c " & quoteShell(script))

suite "packaging: the source root the payload stagers fill":

  test "the staged source root is one the profile compile accepts":
    let root = repoRootFromTest()
    let dest = absolutePath("build/test-tmp/staged-source-root")
    removeDir(dest)
    createDir(dest)
    let run = stageSourceRoot(dest)
    checkpoint run.output
    check run.exitCode == 0
    # The profile compile's refusal of a source root, applied to what a
    # package ships.
    var refusal = ""
    try:
      requireReprobuildSources(dest)
    except CompileFailure as err:
      refusal = err.msg
    check refusal == ""
    # Byte-identical to the checkout's: the profile compile includes this
    # file, so a package's copy and a checkout's must not differ.
    check fileExists(dest / "config.nims")
    if fileExists(dest / "config.nims"):
      check readFile(dest / "config.nims") == readFile(root / "config.nims")
    # The root-level compatibility modules, which resolve through the
    # source root itself rather than through `libs/*/src`, as in the
    # release archives.
    check fileExists(dest / "lints" / "ambient_execution.nim")
    # Tests stay out: they are never on `--path:`.
    check not dirExists(dest / "libs" / "repro_profile_compile" / "tests")

  test "the payload stagers stage the source root through that function":
    # A stager with a copy loop of its own is how `config.nims` went
    # missing from the packages while the release archives carried it.
    for rel in PayloadStagerRels:
      let lines = codeLines(rel)
      check sourcesHelper(lines)
      var calls = 0
      for line in lines:
        if line.startsWith("stage_source_root "):
          calls.inc
          check line.contains("share/repro/source")
      checkpoint rel
      check calls == 1

  test "the release stager stages from the same list":
    # It keeps its own copy mechanism (tracked files, one tar pipe), so
    # what it must share is the list: an entry named here and not there
    # is the drift this suite exists to stop.
    let lines = codeLines(ReleaseStagerRel)
    check sourcesHelper(lines)
    var trees, files = false
    for line in lines:
      if line.contains("$REPRO_SOURCE_ROOT_TREES"): trees = true
      if line.contains("$REPRO_SOURCE_ROOT_FILES"): files = true
      # No entry of the list spelled out beside it.
      check not line.contains("config.nims")
    check trees
    check files
