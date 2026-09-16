## t_runner_exclusive_phase_budget — the phase that owns the host must be
## given the host.
##
## THE DEFECT THIS PINS
## --------------------
## The execution phase is multiplicative: ``threads`` test processes, each able
## to spawn a nested ``repro build`` of its own. ``scripts/test_parallelism.sh``
## therefore splits one host budget in two — ``threads`` workers, and
## ``nested = budget / threads`` build workers for each of them — so that
## ``threads * nested <= budget`` holds by construction. On a 32-core host that
## is budget 24, 8 test workers, 3 nested workers each.
##
## That divide assumes ``threads`` cases are actually in flight. The runner's
## EXCLUSIVE phase breaks the assumption in the safe direction: the ~50 cases
## whose stem is in ``ExclusiveStems`` run strictly one at a time, on the main
## thread, BEFORE any worker thread is created. With one case in flight the
## multiplier is 1, so the same invariant permits the whole budget — and
## dividing anyway is pure waste. Those cases are exclusive precisely BECAUSE
## they drive nested compiles, and they were getting the smallest share of the
## machine at the one moment nothing else was competing for it. Below the stock
## default, even: ``buildMaxParallelismResolved`` uses 8 when the variable is
## absent entirely, so the split was derating them to 3.
##
## Measured on the full-suite run at reprobuild ``d280a94e6``: 9281 cases in
## 8h40m, of which the first 3h17m produced 51 cases at ``running=1``. That is
## 37.9% of the wall clock spent on 0.55% of the cases with 31 cores idle.
##
## Two properties are asserted here, and both were false before:
##
##   1. THE EXCLUSIVE CASE GETS THE UNDIVIDED BUDGET. A case on an exclusive
##      stem sees ``REPROBUILD_MAX_PARALLELISM`` equal to
##      ``REPROBUILD_EXCLUSIVE_MAX_PARALLELISM``.
##   2. THE POOL IS UNTOUCHED. A case NOT on an exclusive stem still sees the
##      divided per-worker share. Getting this backwards would raise nested
##      parallelism for every case simultaneously — exactly the multiplicative
##      oversubscription the budget split exists to prevent, and a far worse
##      bug than the one being fixed.
##
## Plus the operator-pin contract: with no
## ``REPROBUILD_EXCLUSIVE_MAX_PARALLELISM`` in the environment, the exclusive
## phase keeps whatever the parallel phase was given. An operator who pinned
## ``REPROBUILD_MAX_PARALLELISM`` by hand meant it for the whole run, and this
## change must not smuggle a larger value past that.
##
## NO MOCKS. The runner is the real binary and the fixtures are real compiled
## programs; the assertion reads what the child process actually received in
## its environment, which is the only thing that decides how many workers a
## nested build gets.
##
## ONE FIXTURE IS NAMED AFTER A PRODUCTION STEM ON PURPOSE. Exclusivity is
## decided by binary stem against the hardcoded ``ExclusiveStems`` list, so a
## fixture can only be classified exclusive by carrying one of those names.
## ``t_repro_https_cache_end_to_end`` is used as the label; nothing of that
## test's behaviour is reproduced or asserted here.

import std/[os, osproc, strutils, tempfiles, unittest]

const RepoRootMarker = "repro.nim"

## A stem from the runner's ``ExclusiveStems``. If the runner ever drops this
## name the test fails loudly (zero exclusive cases) rather than silently
## asserting nothing.
const ExclusiveStem = "t_repro_https_cache_end_to_end"
const ParallelStem = "t_exclusive_budget_parallel_probe"

proc findRepoRoot(): string =
  var dir = currentSourcePath().parentDir
  while dir.len > 0:
    if fileExists(dir / RepoRootMarker) and
        fileExists(dir / "repro_tests.nim"):
      return dir
    let parent = dir.parentDir
    if parent == dir:
      break
    dir = parent
  raise newException(IOError,
    "cannot locate reprobuild repo root from " & currentSourcePath())

proc writeProbeFixture(path, stem, observedPath: string) =
  ## A whole-binary test that records the one thing this test is about: the
  ## build parallelism its environment grants a nested ``repro build``.
  ##
  ## It refuses ``--list-json`` (exit 3) so the runner classifies it as a
  ## whole-binary case. That keeps the fixture free of the Tier-1 protocol,
  ## which has nothing to do with the property under test — the exclusive
  ## phase runs protocol-aware and whole-binary cases through the same env.
  writeFile(path, """
import std/[os, strutils]

when isMainModule:
  for i in 1 .. paramCount():
    if paramStr(i) == "--list-json":
      quit(3)
  let f = open(""" & escape(observedPath) & """, fmAppend)
  f.writeLine(""" & escape(stem) & """ & "=" &
    getEnv("REPROBUILD_MAX_PARALLELISM", "unset"))
  f.close()
  quit(0)
""")

proc compileFixture(workRoot, source, binary: string): bool =
  let cmd = "nim c --hints:off --warnings:off " &
    "--nimcache:" & quoteShell(workRoot / "nimcache" /
      splitFile(source).name) & " " &
    "--out:" & quoteShell(binary) & " " &
    quoteShell(source)
  execCmd(cmd) == 0

type RunFindings = object
  stderrText: string
  observed: string

proc runRunner(runner, binDir, workRoot, observedPath: string;
               exclusiveBudget: string): RunFindings =
  ## ``exclusiveBudget`` empty means "not set at all" — the operator-pin case.
  if fileExists(observedPath):
    removeFile(observedPath)
  let errPath = workRoot / "run.err"
  let cmd = quoteShell(runner) & " --no-build --threads=2" &
    " --no-runquota-history --test-timeout=120" &
    " --bin-dir=" & quoteShell(binDir) &
    " --summary-json=" & quoteShell(workRoot / "run.json") &
    " --results-dir=" & quoteShell(workRoot / "results") &
    " > " & quoteShell(workRoot / "run.out") &
    " 2> " & quoteShell(errPath)
  putEnv("REPROBUILD_MAX_PARALLELISM", "3")
  if exclusiveBudget.len > 0:
    putEnv("REPROBUILD_EXCLUSIVE_MAX_PARALLELISM", exclusiveBudget)
  else:
    delEnv("REPROBUILD_EXCLUSIVE_MAX_PARALLELISM")
  discard execCmd("sh -c " & quoteShell(cmd))
  delEnv("REPROBUILD_EXCLUSIVE_MAX_PARALLELISM")
  delEnv("REPROBUILD_MAX_PARALLELISM")
  result.stderrText = readFile(errPath)
  result.observed =
    if fileExists(observedPath): readFile(observedPath) else: ""

proc parallelismFor(observed, stem: string): string =
  for line in observed.splitLines():
    let parts = line.split('=', 1)
    if parts.len == 2 and parts[0] == stem:
      return parts[1].strip()
  ""

suite "t_runner_exclusive_phase_budget":

  setup:
    let repoRoot = findRepoRoot()
    let runner = repoRoot / "build" / "bin" /
      addFileExt("repro_test_runner", ExeExt)

  test "the exclusive phase spends the undivided budget, the pool does not":
    check fileExists(runner)
    if not fileExists(runner):
      return

    let workRoot = createTempDir("repro-exclusive-budget-", "")
    defer: removeDir(workRoot)
    let binDir = workRoot / "bin"
    let srcDir = workRoot / "src"
    createDir(binDir)
    createDir(srcDir)
    let observedPath = workRoot / "observed.txt"

    for stem in [ExclusiveStem, ParallelStem]:
      let src = srcDir / (stem & ".nim")
      writeProbeFixture(src, stem, observedPath)
      let ok = compileFixture(workRoot, src,
        binDir / addFileExt(stem, ExeExt))
      check ok
      if not ok:
        return

    let findings = runRunner(runner, binDir, workRoot, observedPath,
      exclusiveBudget = "24")

    # The runner must actually have classified one case as exclusive. Without
    # this the two assertions below could both pass vacuously on a runner that
    # had no exclusive phase at all.
    check "1 cases require exclusive execution" in findings.stderrText

    # 1. the exclusive case owns the host
    check parallelismFor(findings.observed, ExclusiveStem) == "24"
    # 2. the pool keeps the divided share
    check parallelismFor(findings.observed, ParallelStem) == "3"

  test "an operator-pinned parallelism is not overridden":
    check fileExists(runner)
    if not fileExists(runner):
      return

    let workRoot = createTempDir("repro-exclusive-pin-", "")
    defer: removeDir(workRoot)
    let binDir = workRoot / "bin"
    let srcDir = workRoot / "src"
    createDir(binDir)
    createDir(srcDir)
    let observedPath = workRoot / "observed.txt"

    for stem in [ExclusiveStem, ParallelStem]:
      let src = srcDir / (stem & ".nim")
      writeProbeFixture(src, stem, observedPath)
      let ok = compileFixture(workRoot, src,
        binDir / addFileExt(stem, ExeExt))
      check ok
      if not ok:
        return

    # No REPROBUILD_EXCLUSIVE_MAX_PARALLELISM: this is what the runner sees
    # when run_tests.sh declined to derive one because the operator pinned
    # REPROBUILD_MAX_PARALLELISM by hand.
    let findings = runRunner(runner, binDir, workRoot, observedPath,
      exclusiveBudget = "")

    check "1 cases require exclusive execution" in findings.stderrText
    check parallelismFor(findings.observed, ExclusiveStem) == "3"
    check parallelismFor(findings.observed, ParallelStem) == "3"
