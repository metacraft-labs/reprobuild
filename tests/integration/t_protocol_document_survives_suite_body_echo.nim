## A stray `echo` in a suite body must not cost a binary its identity.
##
## THE HAZARD. `unittest`'s three stdout-bearing protocol modes — `--list`,
## `--list-json` and `--catalog -` — write their document to fd 1, the same
## channel the program under test writes to. A suite body is ordinary code
## that runs during REGISTRATION, and registration happens in every mode
## including the protocol ones, because registration is how the catalog is
## built. So an `echo` in a suite body interleaves with the document.
##
## This is not hypothetical and it is not cheap. The last time a consumer
## read a polluted stream as a catalog, 170 of the suite's 1207 binaries
## were classified opaque and 898 cases stopped being individually
## nameable, timeable and re-runnable. That instance (the probe merged the
## child's stderr into the stream it parsed) is fixed. The general hazard —
## the program's OWN stdout — is not, and cannot be fixed from this side.
##
## WHERE THE FIX BELONGS: THE EMITTER, `lib/pure/unittest.nim` IN THE
## codetracer-nim FORK. Three facts decide it.
##
##   1. `--list` is UNRECOVERABLE by any consumer. It emits one bare
##      `suite::test` line per case with no framing of any kind, so a line
##      of user output is byte-indistinguishable from a case name — and a
##      partial write with no trailing newline does not merely ADD a line,
##      it CORRUPTS a real one by prefixing it. `test "--list has no frame"`
##      below pins exactly that, on real output from a real binary. No
##      parser can undo it; only the producer can avoid it.
##   2. Recovery on the other two modes works today only because the noise
##      happens to arrive BEFORE the document (suite bodies run during
##      registration, the document is written from an exit proc). That is a
##      timing accident, not an invariant: an `addExitProc` handler
##      registered by user code, or any thread still writing, lands after
##      it.
##   3. Only the emitter knows a protocol mode is active before user code
##      runs, and only the emitter owns fd 1.
##
##   The upstream change: parse the protocol flags at `unittest` module
##   initialisation instead of lazily at the first `test`, and when a
##   stdout-bearing mode is active, `dup` the real stdout aside and
##   re-point `stdout` at stderr for the whole run, emitting the document
##   to the saved descriptor in `finishProtocol`. User output stays
##   visible on stderr, fd 1 carries the document and nothing else, all
##   three modes are fixed at once, and neither the protocol nor any
##   consumer has to change.
##
## WHAT THIS TEST IS. The consumer-side half, which is legitimately ours:
## proof that the recovery in `tools/test-runner/repro_test_runner.nim`
## and in `scripts/reprobuild_suite_inventory.py` actually holds a
## polluting binary's full identity, measured end to end through the real
## runner rather than by reimplementing the parse here; proof that the two
## implementations — required by their own comments to "keep them in step"
## — agree on the same stream; proof that `--catalog FILE` is immune; and
## a live pin on the `--list` corruption so that the day the emitter is
## fixed, this file fails and says so instead of quietly staying green.
##
## The fixture is `tests/fixtures/protocol-echo/`, excluded from the test
## edges by `scripts/generate_test_edges.nim`, and compiled here into a
## scratch directory — never into `build/test-bin`, which the inventory
## enumerates.

import std/[algorithm, json, os, osproc, strutils, times, unittest]

const RepoMarker = "repro.nim"

const FixtureRel =
  "tests/fixtures/protocol-echo/t_fixture_echoing_suite_body.nim"

const ExpectedCases = [
  "echoing suite::first case",
  "echoing suite::second case",
]

proc findRepoRoot(): string =
  var dir = currentSourcePath().parentDir
  while dir.len > 0:
    if fileExists(dir / RepoMarker) and
        fileExists(dir / "repro_tests.nim"):
      return dir
    let parent = dir.parentDir
    if parent == dir:
      break
    dir = parent
  raise newException(IOError,
    "cannot locate reprobuild repo root from " & currentSourcePath())

proc runOrRaise(cmd, workingDir, what: string): string =
  let (output, code) = execCmdEx(cmd, workingDir = workingDir)
  if code != 0:
    raise newException(IOError,
      what & " failed (" & $code & "):\n" & cmd & "\n" & output)
  output

proc buildFixture(repoRoot, outDir: string): string =
  ## Compile the polluting fixture into `outDir` and return its path.
  let nimExe = findExe("nim")
  if nimExe.len == 0:
    raise newException(IOError,
      "no `nim` on PATH; this suite compiles under `nix develop`")
  createDir(outDir)
  let binary = outDir / addFileExt("t_fixture_echoing_suite_body", ExeExt)
  let cmd = @[
    nimExe.quoteShell, "c", "--hints:off", "--warnings:off",
    "--nimcache:" & (outDir / "nimcache").quoteShell,
    "--out:" & binary.quoteShell,
    (repoRoot / FixtureRel).quoteShell,
  ].join(" ")
  discard runOrRaise(cmd, repoRoot, "fixture compile")
  if not fileExists(binary):
    raise newException(IOError, "fixture compile produced no " & binary)
  binary

proc ensureRunner(repoRoot: string): string =
  ## Build `repro_test_runner` when it is missing or older than its
  ## source — the same staleness rule `scripts/run_tests.sh` applies, and
  ## for the same reason: an existence-only check lets a stale runner
  ## survive every edit to the recovery this test is about.
  let binary = repoRoot / "build" / "bin" /
    addFileExt("repro_test_runner", ExeExt)
  let source = repoRoot / "tools" / "test-runner" / "repro_test_runner.nim"
  var rebuild = not fileExists(binary)
  if not rebuild:
    rebuild = getLastModificationTime(source) > getLastModificationTime(binary)
  if rebuild:
    let nimExe = findExe("nim")
    if nimExe.len == 0:
      raise newException(IOError,
        "no `nim` on PATH; this suite compiles under `nix develop`")
    let cmd = @[
      nimExe.quoteShell, "c", "-d:release", "--threads:on",
      "--hints:off", "--warnings:off",
      "--nimcache:build/nimcache/repro_test_runner",
      "--out:" & binary.quoteShell,
      source.quoteShell,
    ].join(" ")
    discard runOrRaise(cmd, repoRoot, "repro_test_runner build")
  binary

proc scratchDir(name: string): string =
  result = getTempDir() / ("repro-protocol-echo-" & name & "-" &
    $getCurrentProcessId())
  removeDir(result)
  createDir(result)

suite "protocol documents survive a suite-body echo":

  test "the runner keeps every case of a binary that echoes on stdout":
    ## The end-to-end claim, through the production consumer: a polluting
    ## binary is enumerated case by case and marked protocol-aware, not
    ## downgraded to one opaque whole-binary entry.
    let repoRoot = findRepoRoot()
    let work = scratchDir("runner")
    defer: removeDir(work)
    let binDir = work / "bin"
    discard buildFixture(repoRoot, binDir)
    let runner = ensureRunner(repoRoot)

    # The fixture writes noise on stdout; if the runner could not recover
    # its catalog it would fall back to whole-binary execution, which is
    # exactly the 170-binary failure mode.
    let summaryPath = work / "summary.json"
    let cmd = @[
      runner.quoteShell, "--no-build", "--threads=1",
      "--bin-dir=" & binDir.quoteShell,
      "--summary-json=" & summaryPath.quoteShell,
      "--results-dir=" & (work / "results").quoteShell,
    ].join(" ")
    checkpoint("running: " & cmd)
    let (output, exitCode) = execCmdEx(cmd, workingDir = repoRoot)
    checkpoint(output)
    check exitCode == 0
    check fileExists(summaryPath)

    let doc = parseFile(summaryPath)
    check doc{"summary", "total"}.getInt(-1) == ExpectedCases.len
    check doc{"summary", "passed"}.getInt(-1) == ExpectedCases.len

    var names: seq[string] = @[]
    var opaque: seq[string] = @[]
    for entry in doc{"tests"}:
      names.add(entry{"qualified_name"}.getStr())
      if not entry{"protocol_aware"}.getBool(false):
        opaque.add(entry{"qualified_name"}.getStr())
    check names == @ExpectedCases
    # A whole-binary entry is how a lost catalog shows up: one row, named
    # after the stem, `protocol_aware` false. Naming the offenders keeps
    # the failure diagnostic rather than a bare count.
    check opaque == newSeq[string]()

  test "--catalog FILE is immune to the same pollution":
    ## The one mode that does not share a channel with the program. It is
    ## the shape the stdout-bearing modes should be given upstream, and
    ## the control that proves the noise is a CHANNEL problem rather than
    ## a defect in how the document is built.
    let repoRoot = findRepoRoot()
    let work = scratchDir("catalog")
    defer: removeDir(work)
    let binary = buildFixture(repoRoot, work / "bin")

    let catalogPath = work / "catalog.json"
    let cmd = binary.quoteShell & " --catalog " & catalogPath.quoteShell
    let (output, exitCode) = execCmdEx(cmd, workingDir = work)
    checkpoint("stdout carried " & $output.len & " bytes of noise")
    check exitCode == 0
    # The noise really did happen — otherwise this case would pass
    # vacuously on a fixture that had stopped exercising the hazard.
    check "fixture noise" in output
    check fileExists(catalogPath)

    let raw = readFile(catalogPath)
    check "fixture noise" notin raw
    let doc = parseJson(raw)
    var names: seq[string] = @[]
    for name, _ in doc{"tests"}:
      names.add(name)
    names.sort()
    check names == @ExpectedCases

  test "--list has no frame and IS corrupted (upstream defect, pinned)":
    ## PINNED KNOWN DEFECT, not a skip and not a tolerance. `--list` emits
    ## bare `suite::test` lines, so the fixture's partial write with no
    ## trailing newline fuses onto the front of a real case name and its
    ## whole lines arrive as extra names. `--list` is consumed —
    ## `tests/unit/test_reprobuild_suite_inventory.py` cross-checks every
    ## binary's catalog against it — and that consumer is fail-loud, so
    ## today the damage surfaces as a failure rather than a wrong count.
    ##
    ## This case asserts the corruption is REAL so nobody re-reads `--list`
    ## as trustworthy. When the emitter fix described in this file's header
    ## lands in the codetracer-nim fork, `--list` becomes clean and THIS
    ## CASE FAILS. That is the intent: delete it then, and delete the
    ## recovery scaffolding it guards.
    let repoRoot = findRepoRoot()
    let work = scratchDir("list")
    defer: removeDir(work)
    let binary = buildFixture(repoRoot, work / "bin")

    let (output, exitCode) = execCmdEx(binary.quoteShell & " --list",
      workingDir = work)
    check exitCode == 0
    checkpoint(output)

    var lines: seq[string] = @[]
    for line in output.splitLines():
      if line.strip().len > 0:
        lines.add(line)
    check lines.len > ExpectedCases.len

    # The specific, unrecoverable damage: a real case name no longer
    # appears on a line of its own, because a partial write with no
    # newline prefixed it.
    check ExpectedCases[0] notin lines
    var fused = ""
    for line in lines:
      if line.endsWith(ExpectedCases[0]) and line != ExpectedCases[0]:
        fused = line
    check fused.len > 0
    checkpoint("a case name arrived fused to user output: " & fused)

  test "the runner and the inventory recover the same document":
    ## `extractCatalogDocument` in the Nim runner and
    ## `extract_catalog_document` in the Python inventory each carry a
    ## comment requiring the other to stay in step, because when they
    ## disagree the two surfaces disagree about which binaries are
    ## enumerable — the exact drift that hid 170 opaque binaries. Nothing
    ## checked that they do. This runs both over one polluted stream.
    let repoRoot = findRepoRoot()
    let work = scratchDir("agree")
    defer: removeDir(work)
    let binDir = work / "bin"
    let binary = buildFixture(repoRoot, binDir)

    let listJsonPath = work / "list.json"
    let capture = binary.quoteShell & " --list-json > " &
      listJsonPath.quoteShell & " 2>/dev/null"
    discard execCmdEx(capture, workingDir = work)
    let polluted = readFile(listJsonPath)
    # Proof the stream really is polluted; a clean stream would make the
    # rest of this case a test of nothing.
    check "fixture noise" in polluted
    check not polluted.strip().startsWith("{\"tests\":[")

    # The Nim side, exercised through the runner exactly as the suite
    # does — the runner only reaches per-case execution when its own
    # extractor decoded this stream.
    let runner = ensureRunner(repoRoot)
    let summaryPath = work / "summary.json"
    let runCmd = @[
      runner.quoteShell, "--no-build", "--threads=1",
      "--bin-dir=" & binDir.quoteShell,
      "--summary-json=" & summaryPath.quoteShell,
      "--results-dir=" & (work / "results").quoteShell,
    ].join(" ")
    discard execCmdEx(runCmd, workingDir = repoRoot)
    check fileExists(summaryPath)
    var nimNames: seq[string] = @[]
    for entry in parseFile(summaryPath){"tests"}:
      if entry{"protocol_aware"}.getBool(false):
        nimNames.add(entry{"qualified_name"}.getStr())

    # The Python side, calling the inventory's own extractor.
    let script = """
import json, sys
sys.path.insert(0, "scripts")
import reprobuild_suite_inventory as inventory
doc = inventory.extract_catalog_document(
    open(sys.argv[1], encoding="utf-8", errors="replace").read())
print(json.dumps([] if doc is None else [t["name"] for t in doc["tests"]]))
"""
    let scriptPath = work / "extract.py"
    writeFile(scriptPath, script)
    let pyExe = findExe("python3")
    check pyExe.len > 0
    let pyOut = runOrRaise(
      pyExe.quoteShell & " " & scriptPath.quoteShell & " " &
        listJsonPath.quoteShell,
      repoRoot, "inventory extractor")
    var pyNames: seq[string] = @[]
    for node in parseJson(pyOut.strip()):
      pyNames.add(node.getStr())

    checkpoint("nim:    " & nimNames.join(", "))
    checkpoint("python: " & pyNames.join(", "))
    check nimNames == @ExpectedCases
    check pyNames == @ExpectedCases
    check nimNames == pyNames
