## A stray `echo` in a suite body must not cost a binary its identity.
##
## THE HAZARD. `unittest`'s three stdout-bearing protocol modes — `--list`,
## `--list-json` and `--catalog -` — write their document to fd 1, the same
## channel the program under test writes to. A suite body is ordinary code
## that runs during REGISTRATION, and registration happens in every mode
## including the protocol ones, because registration is how the catalog is
## built. So an `echo` in a suite body interleaves with the document.
##
## This was not hypothetical and it was not cheap. The last time a consumer
## read a polluted stream as a catalog, 170 of the suite's 1207 binaries
## were classified opaque and 898 cases stopped being individually
## nameable, timeable and re-runnable. That instance (the probe merged the
## child's stderr into the stream it parsed) was fixed here. The general
## hazard — the program's OWN stdout — could not be fixed from this side.
##
## THE FIX LANDED IN THE EMITTER, `lib/pure/unittest.nim` in the
## codetracer-nim fork, which is where it belonged. Three facts decided it.
##
##   1. `--list` was UNRECOVERABLE by any consumer. It emits one bare
##      `suite::test` line per case with no framing of any kind, so a line
##      of user output is byte-indistinguishable from a case name — and a
##      partial write with no trailing newline does not merely ADD a line,
##      it CORRUPTS a real one by prefixing it. No parser can undo that;
##      only the producer can avoid it.
##   2. Recovery on the other two modes worked only because the noise
##      happened to arrive BEFORE the document (suite bodies run during
##      registration, the document is written from an exit proc). That was
##      a timing accident, not an invariant: an `addExitProc` handler
##      registered by user code, or any thread still writing, lands after
##      it.
##   3. Only the emitter knows a protocol mode is active before user code
##      runs, and only the emitter owns fd 1.
##
##   What the fork does: at module initialisation — which precedes the body
##   of every module importing it, and so every `suite` declaration — it
##   dups the real standard output aside and points descriptor 1 at
##   standard error for the rest of the run, emitting the document to the
##   saved descriptor. User output stays visible on stderr, fd 1 carries
##   the document and nothing else, all three modes are fixed at once, and
##   neither the protocol nor any consumer had to change. Because the move
##   is made at the descriptor level rather than by reassigning `stdout`,
##   it also covers C code writing to `stdout` and child processes that
##   inherit the descriptor.
##
## WHAT THIS TEST IS. The consumer-side half, which is legitimately ours:
## proof that a binary which prints from a suite body is still enumerated
## case by case through the real runner rather than collapsed into one
## opaque whole-binary entry; proof that the two extractor implementations
## — required by their own comments to "keep them in step" — read the same
## stream the same way; proof that `--catalog FILE` is immune; and a live
## guard that each of the three stdout-bearing modes still carries its
## document alone, so that handing the channel back is a test failure and
## not a silent regression.
##
## Two of these cases were written the other way round, against the
## unfixed emitter, and asserted that the damage was real. They were
## inverted when the fix landed, which is what they said they were for.
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

proc ensureRunner(repoRoot, scratch: string): string =
  ## Resolve a `repro_test_runner` to drive, WITHOUT writing anything into
  ## the repository.
  ##
  ## The repo's own `build/bin/repro_test_runner` is used when it exists and
  ## is no older than its source — the staleness rule
  ## `scripts/run_tests.sh` applies, and for the same reason: an
  ## existence-only check lets a stale runner survive every edit to the
  ## recovery this test is about. That use is READ-ONLY.
  ##
  ## Otherwise a private copy is built into this case's own scratch
  ## directory. It must not be built into `build/bin`: `run_tests.sh` only
  ## builds that binary on its fallback path, so on a host with
  ## `ct-test-runner` installed it is absent — and the suite runs
  ## process-per-test, so the two cases here that need a runner would race
  ## two concurrent `nim c` invocations on the same output file and the same
  ## nimcache. A test may not corrupt a shared build output to run.
  let shared = repoRoot / "build" / "bin" /
    addFileExt("repro_test_runner", ExeExt)
  let source = repoRoot / "tools" / "test-runner" / "repro_test_runner.nim"
  if fileExists(shared) and
      getLastModificationTime(shared) >= getLastModificationTime(source):
    return shared

  let nimExe = findExe("nim")
  if nimExe.len == 0:
    raise newException(IOError,
      "no `nim` on PATH; this suite compiles under `nix develop`")
  ## The private build is a DEBUG build. What is under test is the runner's
  ## catalog recovery, not its speed, and this test drives it over two
  ## trivial cases — so an optimised build buys nothing and costs minutes on
  ## exactly the hosts that need the private path. The suite's CI job already
  ## runs close to its wall-clock ceiling.
  let private = scratch / addFileExt("repro_test_runner", ExeExt)
  let cmd = @[
    nimExe.quoteShell, "c", "--threads:on",
    "--hints:off", "--warnings:off",
    "--nimcache:" & (scratch / "runner-nimcache").quoteShell,
    "--out:" & private.quoteShell,
    source.quoteShell,
  ].join(" ")
  discard runOrRaise(cmd, repoRoot, "repro_test_runner build")
  private

proc scratchDir(name: string): string =
  result = getTempDir() / ("repro-protocol-echo-" & name & "-" &
    $getCurrentProcessId())
  removeDir(result)
  createDir(result)

suite "protocol documents survive a suite-body echo":

  test "the runner keeps every case of a binary that echoes on stdout":
    ## The end-to-end claim, through the production consumer: a binary that
    ## prints from a suite body is enumerated case by case and marked
    ## protocol-aware, not downgraded to one opaque whole-binary entry.
    ##
    ## This is the case that does not care WHERE the fix lives. It held
    ## when the runner had to recover a polluted catalog and it holds now
    ## that the emitter hands it a clean one, because what it asserts is
    ## the outcome the suite depends on rather than the mechanism that
    ## produces it.
    let repoRoot = findRepoRoot()
    let work = scratchDir("runner")
    defer: removeDir(work)
    let binDir = work / "bin"
    discard buildFixture(repoRoot, binDir)
    let runner = ensureRunner(repoRoot, work)

    # If the runner could not get a catalog out of this binary it would
    # fall back to whole-binary execution, which is exactly the
    # 170-binary failure mode.
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
    ## The one mode that never shared a channel with the program, and so
    ## never needed fixing. It is the shape the three stdout-bearing modes
    ## have now been given upstream, and the control that proves the noise
    ## was a CHANNEL problem rather than a defect in how the document is
    ## built — which is why the fix could be a redirect and did not have to
    ## touch the document at all.
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

  test "--list carries the document alone and the noise goes to stderr":
    ## WAS A PINNED DEFECT, IS NOW A REGRESSION GUARD. `--list` emits bare
    ## `suite::test` lines with no framing of any kind, so a partial write
    ## with no trailing newline did not merely ADD a line — it fused onto
    ## the front of a real case name, and the whole lines arrived as extra
    ## names. Nothing in the byte stream said where the noise stopped and a
    ## name started, so no consumer could undo it. This case used to assert
    ## that damage was real, and recorded that it would fail the day the
    ## emitter was fixed.
    ##
    ## It has been. The fork now dups the real stdout aside at module
    ## initialisation and points fd 1 at stderr for the whole run, so the
    ## document is the only thing on the channel. The case is inverted
    ## rather than deleted: the property is worth a live test, and this is
    ## what will say so if the channel is ever handed back.
    ##
    ## `--list` is consumed — `tests/unit/test_reprobuild_suite_inventory.py`
    ## cross-checks every binary's catalog against it — and that consumer
    ## reads stdout alone, so what it sees is what is asserted here.
    let repoRoot = findRepoRoot()
    let work = scratchDir("list")
    defer: removeDir(work)
    let binary = buildFixture(repoRoot, work / "bin")

    # Captured SEPARATELY, on purpose. A stream a consumer merges by hand
    # (`prog --list 2>&1`) is outside what the emitter can fix and always
    # was, so merging them here would test the one thing the fix does not
    # claim. Both of this repository's consumers keep them apart.
    let outPath = work / "list.out"
    let errPath = work / "list.err"
    let (_, exitCode) = execCmdEx(
      binary.quoteShell & " --list > " & outPath.quoteShell &
        " 2> " & errPath.quoteShell,
      workingDir = work)
    check exitCode == 0

    let listOut = readFile(outPath)
    let listErr = readFile(errPath)
    checkpoint("stdout: " & listOut)
    checkpoint("stderr: " & listErr)

    var lines: seq[string] = @[]
    for line in listOut.splitLines():
      if line.strip().len > 0:
        lines.add(line)
    # Exactly the cases, each alone on a line of its own, in registration
    # order — not merely "the names are in there somewhere".
    check lines == @ExpectedCases
    check "fixture noise" notin listOut

    # The other half of the fix, and the reason it is a redirect rather
    # than a suppression: the author's output is still there to be read.
    # A fix that silently dropped it would trade one invisible failure for
    # another.
    check "fixture noise" in listErr

  test "the runner and the inventory read the same document":
    ## `extractCatalogDocument` in the Nim runner and
    ## `extract_catalog_document` in the Python inventory each carry a
    ## comment requiring the other to stay in step, because when they
    ## disagree the two surfaces disagree about which binaries are
    ## enumerable — the exact drift that hid 170 opaque binaries. Nothing
    ## checked that they do. This runs both over one stream from one
    ## binary and requires the same answer.
    ##
    ## It used to run them over a POLLUTED stream, because this fixture
    ## could pollute its own `--list-json`. It no longer can: the emitter
    ## owns the channel now, so the preconditions below assert the
    ## document is clean rather than that it is damaged.
    ##
    ## What that costs, stated rather than left implicit: the recovery
    ## scaffolding in both extractors is no longer reachable from any
    ## conforming `unittest` binary, so nothing here exercises it. It is
    ## deliberately NOT deleted in this change — the protocol's own
    ## conformance contract lets a project put its own harness behind
    ## these flags, and such a producer can still emit a stream that needs
    ## recovering. Whether to keep the scaffolding, and to cover it with a
    ## hand-written non-conforming producer instead of this fixture, is a
    ## separate decision from bumping the compiler.
    let repoRoot = findRepoRoot()
    let work = scratchDir("agree")
    defer: removeDir(work)
    let binDir = work / "bin"
    let binary = buildFixture(repoRoot, binDir)

    let listJsonPath = work / "list.json"
    let errPath = work / "list-json.err"
    let capture = binary.quoteShell & " --list-json > " &
      listJsonPath.quoteShell & " 2> " & errPath.quoteShell
    discard execCmdEx(capture, workingDir = work)
    let document = readFile(listJsonPath)
    # The stream really is clean, and the noise really did still happen —
    # otherwise this case would pass vacuously on a fixture that had
    # stopped exercising the hazard at all.
    check "fixture noise" notin document
    check document.strip().startsWith("{\"tests\":[")
    check "fixture noise" in readFile(errPath)

    # The Nim side, exercised through the runner exactly as the suite
    # does — the runner only reaches per-case execution when its own
    # extractor decoded this stream.
    let runner = ensureRunner(repoRoot, work)
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
