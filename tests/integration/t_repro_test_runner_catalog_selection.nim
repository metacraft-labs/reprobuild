## t_repro_test_runner_catalog_selection —
## the runner retains the whole ``--list-json`` row, and selects cases by
## body-hash difference against a catalog it wrote earlier, fail-closed.
##
## Why this exists
## ---------------
## Every test binary in this repository is built by the codetracer-nim
## fork and already emits the full Tier-1 catalog row — ``file``,
## ``line``, ``column``, ``kind``, ``group``, ``threadsRequired``,
## ``xfail``, ``tags``, ``bodyHash``, ``deterministic``. The runner used
## to parse that row and keep exactly ``suite`` and ``name``, dropping the
## rest at the parse site. Downstream, a dropped field and a field the
## producer never emitted are indistinguishable: nothing that read the run
## artifact could say where a case lives or whether its body had changed,
## so the fork's body hashes had no consumer of any kind.
##
## The second half is the consumer. ``--catalog-write`` records every
## case's ``bodyHash``; ``--catalog-read`` compares a later probe against
## that record and runs only what differs.
##
## The property that actually matters here is not "it selects a subset".
## It is that it **cannot silently select too little**. A selection
## mechanism that under-runs turns lost coverage into a green summary —
## the exact failure class this work exists to remove — so every way of
## not understanding a catalog has to resolve to *run everything*, and
## each of those ways is asserted below with its own negative control.
##
## What this test guarantees
## -------------------------
##  * All ten catalog fields survive from ``--list-json`` into the run
##    summary, with the producer's own values.
##  * A catalog is written, and a rebuild that changed nothing selects
##    nothing.
##  * Editing exactly ONE test body selects exactly ONE case — the edited
##    one — while its two neighbours in the same binary keep their hashes.
##  * ``bodyHash`` over-approximates rather than under-approximates. A
##    shape-changing edit — one that changes how much the compiler
##    allocates while expanding the case — also moves the hashes of cases
##    declared LATER in the same module. That is
##    pinned as an inequality — the edited case must always be selected —
##    because the safe direction is the only one that matters and the
##    exact extra set is the compiler's business.
##  * A full run remains available at all times (omit ``--catalog-read``).
##  * FAIL-CLOSED, one negative control per refusal reason: an absent
##    catalog, a corrupt catalog, a catalog from a different project root,
##    a catalog from a future version, a binary the catalog never
##    mentions, and an empty recorded hash each run the affected cases
##    rather than skipping them.
##  * A binary built by this repository's OTHER protocol producer — the
##    vendored ``ct_test_unittest_parallel`` shim, which emits no
##    ``bodyHash`` at all — is never deselected. Two silences are not an
##    agreement, and thirteen test files import that shim today.
##
## Mocking: none, and none is possible here. The fixtures are real
## ``import std/unittest`` / ``import ct_test_unittest_parallel`` sources
## compiled by the real codetracer-nim toolchain — the body hashes under
## test are produced by that compiler and by nothing else, so a stand-in
## producer would test the stand-in.
## The component under test is the real compiled ``repro_test_runner``
## driven as a subprocess against real files on the real filesystem. The
## only fabricated inputs are the deliberately-damaged catalogs in the
## fail-closed test, which are damaged copies of a genuine catalog the
## runner itself wrote moments earlier.

import std/[json, os, osproc, strutils, tables, tempfiles, times, unittest]

template testWithReturn(name: string; body: untyped) =
  test name:
    proc runTestBody() =
      body
    runTestBody()

const RepoRootMarker = "repro.nim"

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

# Three cases in one suite. ``@@EDIT@@`` is the only token the
# body-difference test rewrites, so the edit is provably confined to
# ``beta``'s body and textually touches neither neighbour. Both
# substitutions keep the case PASSING — the property under test is
# "changed body ⇒ selected", and a case that starts failing when it is
# edited would let a broken selector look correct by running everything.
const FixtureTemplate = """
import std/unittest

suite "catalog_fixture":
  test "alpha":
    check 1 + 1 == 2

  test "beta":
    check @@EDIT@@ == @@EDIT@@

  test "gamma":
    check "x" & "y" == "xy"
"""

const RuntimeProbeFixture = """
import std/[os, strutils, unittest]

let probeArgs = commandLineParams()
if "--list-json" in probeArgs:
  # The runner contract is an exact argv vector, not a command string with
  # shell-added or shell-consumed words.
  if probeArgs != @["--list-json"]:
    quit(92)

  # Catalog stdin must be closed: an inherited terminal would park discovery.
  var unexpectedInput = ""
  if stdin.readLine(unexpectedInput):
    quit(93)

  if getEnv("REPRO_CATALOG_FIXTURE_HANG") == "1":
    sleep(3000)
  let forcedExit = getEnv("REPRO_CATALOG_FIXTURE_EXIT")
  if forcedExit.len > 0:
    quit(parseInt(forcedExit))

  # Both channels exceed ordinary pipe capacity. stderr begins with a valid
  # but deliberately false catalog: if the runner merges the streams or reads
  # stderr as catalog input, it will enumerate the wrong case. stdout carries
  # leading noise so the real catalog extraction path is exercised too.
  stderr.write("{\"tests\":[{\"name\":\"forged::stderr\",\"suite\":\"forged\"}]}\n")
  stderr.write(repeat("stderr-probe-noise-", 8192))
  stderr.flushFile()
  stdout.write(repeat("stdout-probe-noise-", 8192))
  stdout.flushFile()

suite "runtime_probe_fixture":
  test "direct argv and loader environment survive catalog probing":
    check true
"""

const InventoryProbeScript = """
import importlib.util
import json
import os
import pathlib
import sys

module_path = pathlib.Path(sys.argv[1])
spec = importlib.util.spec_from_file_location(
    "reprobuild_suite_inventory_runtime_probe", module_path
)
inventory = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = inventory
spec.loader.exec_module(inventory)

binary = pathlib.Path(sys.argv[2])
cwd = pathlib.Path(sys.argv[3])

# Snapshot the probe environment before the Nix runtime closure is available.
# Updating the parent environment afterwards is deliberately too late for this
# dict: subprocess.run receives the snapshot, not a live view of os.environ.
late_env = inventory.catalog_probe_env()
os.environ["LD_LIBRARY_PATH"] = sys.argv[4]
ready_env = inventory.catalog_probe_env()

print(json.dumps({
    "late": inventory.probe_binary_catalog(binary, cwd, late_env, 30),
    "ready": inventory.probe_binary_catalog(binary, cwd, ready_env, 30),
}))
"""

proc fixtureSource(editedValue: string): string =
  FixtureTemplate.replace("@@EDIT@@", editedValue)

proc compileFixture(workRoot, source, binary: string): bool =
  let cmd = "nim c --threads:on --hints:off --warnings:off " &
    "--nimcache:" & quoteShell(workRoot / "nimcache") & " " &
    "--out:" & quoteShell(binary) & " " & quoteShell(source)
  execCmd(cmd) == 0

proc compileRealClingoFixture(workRoot, binary: string): bool =
  ## Compile the repository's actual Clingo smoke source in place, so Nim
  ## discovers the same config.nims and produces the same relocatable loader
  ## shape as the full suite rather than a synthetic approximation of it.
  let source = findRepoRoot() / "libs" / "repro_solver" / "tests" /
    "t_clingo_smoke.nim"
  let cmd = "nim c --threads:on --hints:off --warnings:off " &
    "--nimcache:" & quoteShell(workRoot / "nimcache-clingo") & " " &
    "--out:" & quoteShell(binary) & " " & quoteShell(source)
  execCmd(cmd) == 0

type RunOutcome = object
  exitCode: int
  output: string
  summary: JsonNode

proc runRunner(runner, binDir, workRoot, tag: string;
               catalogWrite = ""; catalogRead = "";
               envOverrides: openArray[tuple[name, value: string]] = []):
               RunOutcome =
  ## Drive the real runner once and parse the summary it wrote.
  var savedEnv: seq[tuple[name: string; existed: bool; value: string]] = @[]
  for override in envOverrides:
    savedEnv.add((name: override.name, existed: existsEnv(override.name),
                  value: getEnv(override.name)))
    putEnv(override.name, override.value)
  defer:
    for saved in savedEnv:
      if saved.existed:
        putEnv(saved.name, saved.value)
      else:
        delEnv(saved.name)

  let summaryPath = workRoot / ("summary-" & tag & ".json")
  var cmd = quoteShell(runner) &
    " --no-build --threads=1 --quiet" &
    " --bin-dir=" & quoteShell(binDir) &
    " --summary-json=" & quoteShell(summaryPath) &
    " --results-dir=" & quoteShell(workRoot / ("results-" & tag))
  if catalogWrite.len > 0:
    cmd.add(" --catalog-write=" & quoteShell(catalogWrite))
  if catalogRead.len > 0:
    cmd.add(" --catalog-read=" & quoteShell(catalogRead))
  let (output, exitCode) = execCmdEx(cmd)
  result.exitCode = exitCode
  result.output = output
  result.summary =
    if fileExists(summaryPath): parseJson(readFile(summaryPath))
    else: newJNull()

proc selectedNames(summary: JsonNode): seq[string] =
  result = @[]
  if summary == nil or summary.kind != JObject:
    return
  for entry in summary{"tests"}:
    result.add(entry{"qualified_name"}.getStr())

proc locateRunner(): string =
  let repoRoot = findRepoRoot()
  repoRoot / "build" / "bin" / addFileExt("repro_test_runner", ExeExt)

suite "repro_test_runner catalog fidelity and hash-difference selection":

  testWithReturn "catalog rows and the real dynamic-loader probe path are preserved":
    let runner = locateRunner()
    check fileExists(runner)
    if not fileExists(runner):
      return

    let tempRoot = createTempDir("repro-m2-catalog-fidelity-", "")
    defer: removeDir(tempRoot)
    let binDir = tempRoot / "bin"
    createDir(binDir)
    const Stem = "t_catalog_fidelity_fixture"
    let src = tempRoot / (Stem & ".nim")
    writeFile(src, fixtureSource("10"))
    let fixtureBin = binDir / addFileExt(Stem, ExeExt)
    let compiled = compileFixture(tempRoot, src, fixtureBin)
    check compiled
    if not compiled:
      return

    # The producer's own row, read straight from the binary. Everything
    # below is compared against THIS, not against a hardcoded copy of it:
    # the assertion is "the runner did not drop or alter what the
    # compiler emitted", which a hardcoded expectation cannot express.
    let listed = execCmdEx(quoteShell(fixtureBin) & " --list-json")
    check listed.exitCode == 0
    let produced = parseJson(listed.output)
    var byName = initTable[string, JsonNode]()
    for entry in produced["tests"]:
      byName[entry{"name"}.getStr()] = entry
    check byName.len == 3

    let run = runRunner(runner, binDir, tempRoot, "fidelity")
    checkpoint("runner exit=" & $run.exitCode)
    if run.exitCode != 0:
      checkpoint(run.output)
    check run.exitCode == 0
    check run.summary{"summary"}{"total"}.getInt(-1) == 3
    check run.summary{"summary"}{"passed"}.getInt(-1) == 3

    var seen = 0
    for entry in run.summary["tests"]:
      check entry{"protocol_aware"}.getBool() == true
      let runName = entry{"run_name"}.getStr()
      check runName in byName
      if runName notin byName:
        continue
      inc seen
      let row = byName[runName]
      # The six fields the contract names, plus the three positional
      # ones, each carried verbatim. ``bodyHash`` is the only one of
      # these that varies today; the rest are producer constants and are
      # asserted equal to the producer rather than to a literal, so this
      # test keeps passing — and keeps being meaningful — on the day the
      # producer starts varying them.
      check entry{"file"}.getStr() == row{"file"}.getStr()
      check entry{"line"}.getInt(-1) == row{"line"}.getInt(-2)
      check entry{"column"}.getInt(-1) == row{"column"}.getInt(-2)
      check entry{"kind"}.getStr() == row{"kind"}.getStr()
      check entry{"group"}.getStr() == row{"group"}.getStr()
      check entry{"threads_required"}.getInt(-1) ==
        row{"threadsRequired"}.getInt(-2)
      check entry{"deterministic"}.getBool() ==
        row{"deterministic"}.getBool()
      check entry{"tags"}.kind == JArray
      check entry{"tags"}.len == row{"tags"}.len
      # ``xfail`` is JSON null in every row the fork emits today, and
      # "the producer said nothing" is not the claim "the producer said
      # false". Absence is preserved as absence.
      if row{"xfail"} == nil or row{"xfail"}.kind == JNull:
        check entry{"xfail"} == nil
      # The one measurement in the row.
      check entry{"body_hash"}.getStr() == row{"bodyHash"}.getStr()
      check entry{"body_hash"}.getStr().len > 0
    check seen == 3

    # macOS production regression: the real Clingo smoke binary dlopens the
    # Nix-provided library before Nim main. Beside it, a separate protocol
    # fixture emits more than a pipe's capacity on BOTH channels, presents a
    # forged catalog on stderr, and validates exact argv + stdin EOF. Both are
    # deliberately placed under one path containing whitespace and shell
    # metacharacters and driven by the real runner; no subprocess seam is
    # replaced.
    # Keep the generated source below the checkout so Nim discovers the real
    # repository config.nims. That config is what deliberately retains the
    # relocatable @rpath Clingo name instead of baking a Nix store path.
    let runtimeTempParent = findRepoRoot() / "build" / "test-tmp"
    createDir(runtimeTempParent)
    let runtimeRoot = createTempDir("catalog-runtime-", "",
                                    runtimeTempParent)
    defer: removeDir(runtimeRoot)
    let runtimeBinDir = runtimeRoot /
      "bin with spaces ; touch PROBE_SHELL_INJECTION ; #"
    createDir(runtimeBinDir)
    const
      RuntimeStem = "t_catalog_runtime_clingo_fixture"
      AdversarialStem = "t_catalog_adversarial_probe_fixture"
    let runtimeSrc = runtimeRoot / (AdversarialStem & ".nim")
    writeFile(runtimeSrc, RuntimeProbeFixture)
    let runtimeBuildDir = runtimeRoot / "runtime-build"
    createDir(runtimeBuildDir)
    let runtimeBuildBin = runtimeBuildDir / addFileExt(RuntimeStem, ExeExt)
    let runtimeBin = runtimeBinDir / addFileExt(RuntimeStem, ExeExt)
    let adversarialBuildBin = runtimeBuildDir /
      addFileExt(AdversarialStem, ExeExt)
    let adversarialBin = runtimeBinDir / addFileExt(AdversarialStem, ExeExt)
    let runtimeCompiled = compileRealClingoFixture(runtimeRoot / "runtime",
                                                   runtimeBuildBin)
    check runtimeCompiled
    if not runtimeCompiled:
      return
    let adversarialCompiled = compileFixture(runtimeRoot / "runtime",
                                             runtimeSrc,
                                             adversarialBuildBin)
    check adversarialCompiled
    if not adversarialCompiled:
      return
    moveFile(runtimeBuildBin, runtimeBin)
    moveFile(adversarialBuildBin, adversarialBin)

    when defined(macosx):
      # A temp source outside the repo can inherit linker-provided LC_RPATHs
      # even with nixbuild disabled. Remove them so this fixture has the same
      # loader shape as the pristine Clingo-linked suite binaries that exposed
      # the regression: an @rpath load requiring the runner's DYLD environment.
      let loadCommands = execCmdEx("otool -l " & quoteShell(runtimeBin))
      check loadCommands.exitCode == 0
      var expectRpath = false
      var rpaths: seq[string] = @[]
      for line in loadCommands.output.splitLines():
        let stripped = line.strip()
        if stripped == "cmd LC_RPATH":
          expectRpath = true
        elif expectRpath and stripped.startsWith("path "):
          let fields = stripped.splitWhitespace()
          if fields.len >= 2:
            rpaths.add(fields[1])
          expectRpath = false
      for rpath in rpaths:
        let removed = execCmdEx("install_name_tool -delete_rpath " &
          quoteShell(rpath) & " " & quoteShell(runtimeBin))
        checkpoint(removed.output)
        check removed.exitCode == 0
      let strippedCommands = execCmdEx("otool -l " & quoteShell(runtimeBin))
      check "LC_RPATH" notin strippedCommands.output
      let loaderStrings = execCmdEx("strings " & quoteShell(runtimeBin))
      check "@rpath/libclingo.dylib" in loaderStrings.output

      # Positive proof that this fixture actually depends on the runtime path
      # under test. With every loader path removed it dies before main rather
      # than emitting a catalog.
      let noRuntime = execCmdEx(
        "DYLD_LIBRARY_PATH='' DYLD_FALLBACK_LIBRARY_PATH='' " &
        "LD_LIBRARY_PATH='' " & quoteShell(runtimeBin) & " --list-json")
      checkpoint(if noRuntime.output.len > 300:
                   noRuntime.output[0 ..< 300]
                 else:
                   noRuntime.output)
      check noRuntime.exitCode != 0
      check "could not load" in noRuntime.output

      # Exercise the actual Python inventory probe over that same real Clingo
      # binary under the plain nix-develop environment shape: LD carries the
      # closure, while both DYLD variables begin empty. A probe environment
      # captured before LD is populated still fails at the loader (the RED for
      # absent/late normalization); a fresh catalog_probe_env created after LD
      # is populated must enumerate the real catalog successfully.
      let inheritedRuntimePath = getEnv("LD_LIBRARY_PATH")
      check inheritedRuntimePath.len > 0
      let inventoryProbePath = runtimeRoot / "inventory_runtime_probe.py"
      writeFile(inventoryProbePath, InventoryProbeScript)
      let inventoryProbe = execCmdEx(
        "DYLD_LIBRARY_PATH='' DYLD_FALLBACK_LIBRARY_PATH='' " &
        "LD_LIBRARY_PATH='' python3 " & quoteShell(inventoryProbePath) & " " &
        quoteShell(findRepoRoot() / "scripts" /
          "reprobuild_suite_inventory.py") & " " &
        quoteShell(runtimeBin) & " " & quoteShell(runtimeRoot) & " " &
        quoteShell(inheritedRuntimePath))
      checkpoint(inventoryProbe.output)
      check inventoryProbe.exitCode == 0
      if inventoryProbe.exitCode == 0:
        let inventoryResults = parseJson(inventoryProbe.output)
        check inventoryResults{"late"}{"status"}.getStr() ==
          "dynamic-link-failure"
        check inventoryResults{"ready"}{"status"}.getStr() == "ok"
        if inventoryResults{"ready"}{"status"}.getStr() == "ok":
          check inventoryResults{"ready"}{"cases"}.len == 1

    let injectionSentinel = getCurrentDir() / "PROBE_SHELL_INJECTION"
    if fileExists(injectionSentinel):
      removeFile(injectionSentinel)
    let runtimeRun = runRunner(runner, runtimeBinDir, tempRoot, "runtime",
      envOverrides = [
        (name: "DYLD_LIBRARY_PATH", value: ""),
        (name: "DYLD_FALLBACK_LIBRARY_PATH", value: ""),
        (name: "REPRO_TEST_PROBE_TIMEOUT", value: "3")])
    checkpoint(runtimeRun.output)
    check runtimeRun.exitCode == 0
    check not fileExists(injectionSentinel)
    check runtimeRun.summary{"summary"}{"total"}.getInt(-1) == 2
    check runtimeRun.summary{"summary"}{"passed"}.getInt(-1) == 2
    check runtimeRun.summary{"tests"}.len == 2
    var runtimeRows = initTable[string, JsonNode]()
    for row in runtimeRun.summary{"tests"}:
      runtimeRows[row{"binary_stem"}.getStr()] = row
    check RuntimeStem in runtimeRows
    check AdversarialStem in runtimeRows
    check runtimeRows[RuntimeStem]{"protocol_aware"}.getBool() == true
    check runtimeRows[RuntimeStem]{"qualified_name"}.getStr() ==
      "repro_solver.clingo_bindings: end-to-end smoke test::solve 'fact. " &
      "answer :- fact.' yields a model containing 'answer'"
    check runtimeRows[AdversarialStem]{"protocol_aware"}.getBool() == true
    check runtimeRows[AdversarialStem]{"qualified_name"}.getStr() ==
      "runtime_probe_fixture::direct argv and loader environment survive " &
      "catalog probing"
    check "forged::stderr" notin
      runtimeRows[AdversarialStem]{"qualified_name"}.getStr()

    # Timeout remains a downgrade to whole-binary execution, not a hung suite
    # or a false failure. The adversarial fixture sleeps only for the catalog
    # argv, so its later whole-binary fallback can still pass; the real Clingo
    # sibling must remain protocol-aware throughout.
    let timeoutStarted = epochTime()
    let timed = runRunner(runner, runtimeBinDir, tempRoot, "runtime-timeout",
      envOverrides = [
        (name: "DYLD_LIBRARY_PATH", value: ""),
        (name: "DYLD_FALLBACK_LIBRARY_PATH", value: ""),
        (name: "REPRO_TEST_PROBE_TIMEOUT", value: "1"),
        (name: "REPRO_CATALOG_FIXTURE_HANG", value: "1")])
    let timeoutElapsed = epochTime() - timeoutStarted
    checkpoint(timed.output)
    check timed.exitCode == 0
    check timeoutElapsed < 5.0
    check "exceeded 1s" in timed.output
    check timed.summary{"summary"}{"total"}.getInt(-1) == 2
    var timedRows = initTable[string, JsonNode]()
    for row in timed.summary{"tests"}:
      timedRows[row{"binary_stem"}.getStr()] = row
    check timedRows[RuntimeStem]{"protocol_aware"}.getBool() == true
    check timedRows[AdversarialStem]{"protocol_aware"}.getBool() == false

    # A real non-zero probe status retains its exact classification and also
    # downgrades to a successful whole-binary run.
    let nonzero = runRunner(runner, runtimeBinDir, tempRoot, "runtime-exit",
      envOverrides = [
        (name: "DYLD_LIBRARY_PATH", value: ""),
        (name: "DYLD_FALLBACK_LIBRARY_PATH", value: ""),
        (name: "REPRO_CATALOG_FIXTURE_EXIT", value: "23")])
    checkpoint(nonzero.output)
    check nonzero.exitCode == 0
    check "exited 23" in nonzero.output
    check nonzero.summary{"summary"}{"total"}.getInt(-1) == 2
    var nonzeroRows = initTable[string, JsonNode]()
    for row in nonzero.summary{"tests"}:
      nonzeroRows[row{"binary_stem"}.getStr()] = row
    check nonzeroRows[RuntimeStem]{"protocol_aware"}.getBool() == true
    check nonzeroRows[AdversarialStem]{"protocol_aware"}.getBool() == false

  testWithReturn "one edited body selects exactly one case":
    let runner = locateRunner()
    check fileExists(runner)
    if not fileExists(runner):
      return

    let tempRoot = createTempDir("repro-m2-catalog-select-", "")
    defer: removeDir(tempRoot)
    let binDir = tempRoot / "bin"
    createDir(binDir)
    const Stem = "t_catalog_select_fixture"
    let src = tempRoot / (Stem & ".nim")
    let fixtureBin = binDir / addFileExt(Stem, ExeExt)
    let catalogPath = tempRoot / "catalog.json"

    writeFile(src, fixtureSource("10"))
    var compiled = compileFixture(tempRoot, src, fixtureBin)
    check compiled
    if not compiled:
      return

    # 1. Baseline: everything runs, and a catalog is written.
    let baseline = runRunner(runner, binDir, tempRoot, "baseline",
      catalogWrite = catalogPath)
    checkpoint("baseline exit=" & $baseline.exitCode)
    if baseline.exitCode != 0:
      checkpoint(baseline.output)
    check baseline.exitCode == 0
    check baseline.summary{"summary"}{"total"}.getInt(-1) == 3
    check fileExists(catalogPath)
    let written = parseJson(readFile(catalogPath))
    check written{"version"}.getInt(-1) == 1
    check written{"projectRoot"}.getStr() == getCurrentDir()
    check written{"binDir"}.getStr() == binDir
    let writtenTests = written{"binaries"}{Stem}{"tests"}
    check writtenTests != nil
    check writtenTests.len == 3
    let baselineBeta =
      writtenTests{"catalog_fixture::beta"}.getStr()
    let baselineAlpha =
      writtenTests{"catalog_fixture::alpha"}.getStr()
    let baselineGamma =
      writtenTests{"catalog_fixture::gamma"}.getStr()
    check baselineBeta.len > 0

    # 2. Nothing changed: the catalog vouches for all three, so none run.
    #    This is the only place in this file where selecting nothing is
    #    the correct answer, and it is correct only because the hashes
    #    positively matched.
    let unchanged = runRunner(runner, binDir, tempRoot, "unchanged",
      catalogRead = catalogPath)
    check unchanged.exitCode == 0
    check unchanged.summary{"summary"}{"total"}.getInt(-1) == 0
    check unchanged.summary{"summary"}{"selection"}{"requested"}.getBool() ==
      true
    check unchanged.summary{"summary"}{"selection"}{"applied"}.getBool() ==
      true
    check unchanged.summary{"summary"}{"selection"}{
      "deselected_unchanged"}.getInt(-1) == 3
    check unchanged.summary{"summary"}{"selection"}{
      "selected_subset"}.getBool() == true

    # 3. Edit exactly one test body and rebuild. ``10`` -> ``11`` is a
    #    SHAPE-PRESERVING edit: same AST node count, same symbol count,
    #    same lines and columns for every following declaration. See the
    #    step-5 note below for why that distinction is load-bearing.
    writeFile(src, fixtureSource("11"))
    compiled = compileFixture(tempRoot, src, fixtureBin)
    check compiled
    if not compiled:
      return

    # The compiler's own view first: precisely one hash moved.
    let relisted = execCmdEx(quoteShell(fixtureBin) & " --catalog -")
    check relisted.exitCode == 0
    let rebuilt = parseJson(relisted.output){"tests"}
    check rebuilt{"catalog_fixture::alpha"}.getStr() == baselineAlpha
    check rebuilt{"catalog_fixture::gamma"}.getStr() == baselineGamma
    check rebuilt{"catalog_fixture::beta"}.getStr() != baselineBeta

    # And now the runner's: exactly one case, and it is that one.
    let edited = runRunner(runner, binDir, tempRoot, "edited",
      catalogRead = catalogPath)
    checkpoint("edited exit=" & $edited.exitCode)
    if edited.exitCode != 0:
      checkpoint(edited.output)
    check edited.exitCode == 0
    check edited.summary{"summary"}{"total"}.getInt(-1) == 1
    check edited.summary{"summary"}{"selection"}{
      "deselected_unchanged"}.getInt(-1) == 2
    check selectedNames(edited.summary) == @["catalog_fixture::beta"]

    # 5. A SHAPE-CHANGING edit to the same body. ``11`` -> ``5 + 5``
    #    changes how much the compiler allocates while expanding
    #    ``beta``, and the observed behaviour is that such an edit also
    #    moves the body hash of every case declared LATER in the same
    #    module (here ``gamma``), while cases declared earlier (``alpha``)
    #    are untouched. Measured directly on the codetracer-nim fork:
    #    ``10``->``11`` moves ``beta`` alone; ``10``->``5 + 5``, "add a
    #    ``let`` to beta" and "add a second ``check`` to beta" each move
    #    ``beta`` and ``gamma`` but not ``alpha``; that same ``let`` added
    #    to ``alpha`` instead moves all three; an edit confined to
    #    ``gamma`` moves ``gamma`` alone. Which textual edits are
    #    shape-changing in this sense is NOT predictable from the source
    #    alone — ``1 + 1``->``1 + 1 + 0`` in ``alpha`` adds tokens and
    #    moves nothing but ``alpha`` — which is exactly why this step
    #    pins an inequality rather than a set.
    #
    #    So ``bodyHash`` is an OVER-approximation of "this case changed",
    #    not an exact one. That direction is the safe one — it selects a
    #    superset, never a subset — and it is the direction this project
    #    needs, so it is pinned here as an inequality rather than being
    #    quietly relied on as an equality. The assertion deliberately does
    #    NOT pin which extra cases come along: that is the compiler's
    #    business and may legitimately change. What must never change is
    #    that the edited case is in the selection.
    writeFile(src, fixtureSource("5 + 5"))
    compiled = compileFixture(tempRoot, src, fixtureBin)
    check compiled
    if not compiled:
      return
    let reshaped = runRunner(runner, binDir, tempRoot, "reshaped",
      catalogRead = catalogPath)
    check reshaped.exitCode == 0
    # Pinned first: the catalog was still applied. Without this, a
    # regression that quietly fell back to the full run would satisfy the
    # inequality below by running everything, and the over-approximation
    # claim would stop being a claim about selection at all.
    check reshaped.summary{"summary"}{"selection"}{"applied"}.getBool() == true
    let reshapedNames = selectedNames(reshaped.summary)
    checkpoint("shape-changing edit selected: " & $reshapedNames)
    check "catalog_fixture::beta" in reshapedNames
    check reshapedNames.len >= 1
    check reshapedNames.len <= 3

    # 6. The full run is still available, and it is the DEFAULT: drop
    #    ``--catalog-read`` and all three run again. A selection
    #    mechanism you cannot turn off is not a selection mechanism.
    let full = runRunner(runner, binDir, tempRoot, "full")
    check full.exitCode == 0
    check full.summary{"summary"}{"total"}.getInt(-1) == 3
    check full.summary{"summary"}{"selection"}{"requested"}.getBool() == false
    check full.summary{"summary"}{"selection"}{
      "selected_subset"}.getBool() == false

  testWithReturn "an untrustworthy catalog runs every case, never none":
    let runner = locateRunner()
    check fileExists(runner)
    if not fileExists(runner):
      return

    let tempRoot = createTempDir("repro-m2-catalog-failclosed-", "")
    defer: removeDir(tempRoot)
    let binDir = tempRoot / "bin"
    createDir(binDir)
    const Stem = "t_catalog_failclosed_fixture"
    let src = tempRoot / (Stem & ".nim")
    writeFile(src, fixtureSource("10"))
    let fixtureBin = binDir / addFileExt(Stem, ExeExt)
    let compiled = compileFixture(tempRoot, src, fixtureBin)
    check compiled
    if not compiled:
      return

    let catalogPath = tempRoot / "catalog.json"
    let baseline = runRunner(runner, binDir, tempRoot, "fc-baseline",
      catalogWrite = catalogPath)
    check baseline.exitCode == 0
    check baseline.summary{"summary"}{"total"}.getInt(-1) == 3

    # Positive control: this genuine catalog DOES deselect all three. It
    # is the reference every damaged variant below is measured against —
    # without it, "3 ran" would be consistent with selection simply not
    # being wired up.
    let honest = runRunner(runner, binDir, tempRoot, "fc-honest",
      catalogRead = catalogPath)
    check honest.summary{"summary"}{"total"}.getInt(-1) == 0

    let genuine = readFile(catalogPath)

    proc damaged(name, content: string): string =
      let p = tempRoot / (name & ".json")
      writeFile(p, content)
      p

    # (a) absent — the ordinary first-ever run.
    let absent = runRunner(runner, binDir, tempRoot, "fc-absent",
      catalogRead = tempRoot / "no-such-catalog.json")
    check absent.exitCode == 0
    check absent.summary{"summary"}{"total"}.getInt(-1) == 3
    check absent.summary{"summary"}{"selection"}{"applied"}.getBool() == false
    check absent.summary{"summary"}{"selection"}{
      "fell_back_because"}.getStr().len > 0

    # (b) truncated mid-document — a run killed while writing it.
    let corrupt = runRunner(runner, binDir, tempRoot, "fc-corrupt",
      catalogRead = damaged("corrupt", genuine[0 ..< 40]))
    check corrupt.summary{"summary"}{"total"}.getInt(-1) == 3
    check corrupt.summary{"summary"}{"selection"}{"applied"}.getBool() == false

    # (c) a different project root. bodyHash bakes the source file's
    #     ABSOLUTE path into the hashed body, so hashes from another
    #     checkout are not comparable at all — and a mechanism that
    #     compared them anyway would look like it worked while
    #     deselecting nothing.
    var otherRoot = parseJson(genuine)
    otherRoot["projectRoot"] = %"/definitely/not/this/checkout"
    let foreign = runRunner(runner, binDir, tempRoot, "fc-root",
      catalogRead = damaged("otherroot", otherRoot.pretty()))
    check foreign.summary{"summary"}{"total"}.getInt(-1) == 3
    check foreign.summary{"summary"}{"selection"}{"applied"}.getBool() == false

    # (d) a version this runner does not know how to read.
    var future = parseJson(genuine)
    future["version"] = %99
    let versioned = runRunner(runner, binDir, tempRoot, "fc-version",
      catalogRead = damaged("v99", future.pretty()))
    check versioned.summary{"summary"}{"total"}.getInt(-1) == 3
    check versioned.summary{"summary"}{"selection"}{
      "applied"}.getBool() == false

    # (e) the catalog is valid and usable, but says nothing about this
    #     binary — i.e. a newly added test binary. The catalog stays in
    #     force for what it does cover; the unmentioned binary runs
    #     whole.
    var noBinary = parseJson(genuine)
    noBinary["binaries"] = newJObject()
    let unknown = runRunner(runner, binDir, tempRoot, "fc-unknown",
      catalogRead = damaged("nobinary", noBinary.pretty()))
    check unknown.summary{"summary"}{"total"}.getInt(-1) == 3
    check unknown.summary{"summary"}{"selection"}{"applied"}.getBool() == true
    check unknown.summary{"summary"}{"selection"}{
      "deselected_unchanged"}.getInt(-1) == 0

    # (f) the case is named but its recorded hash is empty. An empty
    #     hash means the producer told us nothing; matching it against
    #     another empty hash would be agreement about nothing.
    var blanked = parseJson(genuine)
    var blankedNames: seq[string] = @[]
    for name, _ in blanked["binaries"][Stem]["tests"].pairs:
      blankedNames.add(name)
    for name in blankedNames:
      blanked["binaries"][Stem]["tests"][name] = %""
    let blank = runRunner(runner, binDir, tempRoot, "fc-blank",
      catalogRead = damaged("blankhash", blanked.pretty()))
    check blank.summary{"summary"}{"total"}.getInt(-1) == 3
    check blank.summary{"summary"}{"selection"}{
      "deselected_unchanged"}.getInt(-1) == 0

  testWithReturn "a producer that emits no bodyHash is never deselected":
    ## The reachable negative control for the empty-hash guard, using a
    ## REAL second producer rather than a fabricated one.
    ##
    ## This repository ships its own older protocol producer, the
    ## vendored ``libs/ct_test_unittest_parallel`` shim, imported by
    ## thirteen test files. It answers ``--list-json`` with
    ## ``name``/``suite``/``file``/``line`` and emits no ``bodyHash``
    ## whatsoever. So there exists, today, a whole class of binaries in
    ## this suite for which the recorded hash and the observed hash are
    ## both the empty string — and a selector that compared them as
    ## equal would deselect every one of those cases on every run, for
    ## ever, while reporting a clean green summary. That is the precise
    ## silent-under-run this whole mechanism is built to be incapable of.
    ##
    ## Mocking: none. The fixture imports the real shim from
    ## ``libs/ct_test_unittest_parallel/src`` and is compiled by the real
    ## toolchain; the absence of ``bodyHash`` is that shim's genuine
    ## behaviour, not a stand-in for it.
    let runner = locateRunner()
    check fileExists(runner)
    if not fileExists(runner):
      return
    let repoRoot = findRepoRoot()
    let shimPath = repoRoot / "libs" / "ct_test_unittest_parallel" / "src"
    check dirExists(shimPath)
    if not dirExists(shimPath):
      return

    let tempRoot = createTempDir("repro-m2-catalog-nohash-", "")
    defer: removeDir(tempRoot)
    let binDir = tempRoot / "bin"
    createDir(binDir)
    const Stem = "t_catalog_nohash_fixture"
    let src = tempRoot / (Stem & ".nim")
    writeFile(src, """
import ct_test_unittest_parallel

suite "nohash_fixture":
  test "delta":
    check 1 + 1 == 2

  test "epsilon":
    check 2 + 2 == 4
""")
    let fixtureBin = binDir / addFileExt(Stem, ExeExt)
    let cmd = "nim c --threads:on --hints:off --warnings:off " &
      "--path:" & quoteShell(shimPath) & " " &
      "--nimcache:" & quoteShell(tempRoot / "nimcache") & " " &
      "--out:" & quoteShell(fixtureBin) & " " & quoteShell(src)
    let compiled = execCmd(cmd) == 0
    check compiled
    if not compiled:
      return

    # Pin the premise: this producer really does emit rows with no
    # ``bodyHash``. If the shim is ever upgraded to emit one, this
    # assertion fails loudly rather than letting the test quietly stop
    # testing anything.
    let listed = execCmdEx(quoteShell(fixtureBin) & " --list-json")
    check listed.exitCode == 0
    var rows = 0
    for entry in parseJson(listed.output)["tests"]:
      inc rows
      check entry{"bodyHash"} == nil
    check rows == 2

    let catalogPath = tempRoot / "catalog.json"
    let first = runRunner(runner, binDir, tempRoot, "nohash-first",
      catalogWrite = catalogPath)
    check first.exitCode == 0
    check first.summary{"summary"}{"total"}.getInt(-1) == 2
    # The catalog records the cases with empty hashes — recording what
    # the producer said, including that it said nothing.
    let recorded = parseJson(readFile(catalogPath)){"binaries"}{Stem}{"tests"}
    check recorded != nil
    check recorded.len == 2
    for _, hashNode in recorded.pairs:
      check hashNode.getStr() == ""

    # And on the very next run, with an unmodified binary and its own
    # freshly written catalog, both cases run again. Zero deselected.
    let second = runRunner(runner, binDir, tempRoot, "nohash-second",
      catalogRead = catalogPath)
    check second.exitCode == 0
    check second.summary{"summary"}{"total"}.getInt(-1) == 2
    check second.summary{"summary"}{"selection"}{"applied"}.getBool() == true
    check second.summary{"summary"}{"selection"}{
      "deselected_unchanged"}.getInt(-1) == 0
    check selectedNames(second.summary).len == 2
