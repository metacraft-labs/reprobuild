## Compile a recipe fixture and capture the compiler's diagnostic.
##
## Not named `t_*` / `test_*`, so `scripts/generate_test_edges.nim` does not
## register it as a test binary of its own.
##
## Named-Lock-Files NLF-M7. Two corpus cases require a **recipe compile
## error** and both require assertions on its CONTENT:
##
##   * **NLF-STAT-1** — an undeclared lock-file name. "Assert on diagnostic
##     content, not merely on failure."
##   * **NLF-DOC-5** — `## @id BadID` and `## @nonsense`. "Catches a
##     hand-rolled scanner instead of the canonical `parseDocComment`."
##
## §4.9 is why the assertion has to be on content: the requirement is not that
## the build stops, it is that the author is told which name they typed, what
## is in scope, and what they probably meant. A recipe that failed to compile
## with `Error: undeclared identifier` would satisfy "it failed" and none of
## the requirement.
##
## ## Why the fixture is written under the repo and not in /tmp
##
## Nim finds `config.nims` by walking up from the compiled file, and this
## repo's `config.nims` is what puts every `libs/*/src` on the module path. A
## fixture in the system temp directory compiles against a different world and
## would fail for reasons that have nothing to do with lock files. `build/` is
## build output and is not tracked, so a scratch directory under it is the
## right place.
##
## ## Test-double policy: NO mocks, doubles, or fakes
##
## The compiler is the real `nim` binary this repo is built with, invoked on a
## real file, and the text asserted on is its real stderr. There is no
## in-process re-implementation of macro expansion anywhere here.

import std/[os, osproc, strutils]

type
  CompileProbeResult* = object
    ok*: bool
      ## True when the compile SUCCEEDED. A test asserting a compile error
      ## reads this as false.
    output*: string
      ## stdout and stderr, joined. Nim writes diagnostics to stderr and
      ## hints to stdout, and a caller that read only one of them would miss
      ## half of what it means to assert on.

proc repoRoot(): string =
  currentSourcePath().parentDir().parentDir().parentDir().parentDir()

proc nimExe(): string =
  let found = findExe("nim")
  if found.len > 0: found else: "nim"

proc checkRecipeSource*(source: string; tag: string): CompileProbeResult =
  ## Write `source` as a recipe under the repo's `build/` scratch and run
  ## `nim check` on it.
  ##
  ## `nim check` rather than `nim c`: the property under test is a
  ## MACRO-EXPANSION-time error, which `check` reaches, and skipping code
  ## generation makes the probe fast enough to run several per test without
  ## the file becoming the suite's bottleneck.
  let scratch = repoRoot() / "build" /
    ("lock-file-probe-" & tag & "-" & $getCurrentProcessId())
  createDir(scratch)
  defer:
    try: removeDir(scratch)
    except CatchableError: discard
  let path = scratch / "recipe.nim"
  writeFile(path, source)
  let (output, exitCode) = execCmdEx(
    nimExe() & " check --hints:off --colors:off -d:reproProviderMode " &
      quoteShell(path),
    workingDir = repoRoot())
  CompileProbeResult(ok: exitCode == 0, output: output)
