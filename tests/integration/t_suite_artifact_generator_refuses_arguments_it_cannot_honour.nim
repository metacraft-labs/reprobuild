## t_suite_artifact_generator_refuses_arguments_it_cannot_honour —
## ``scripts/generate_test_edges.nim`` must refuse an argument it cannot
## honour, by name, before it does any work, instead of discarding it and
## printing a success line.
##
## The defect this file exists for
## -------------------------------
## The generator had no command-line parsing at all: ``grep -nE
## 'paramStr|commandLineParams'`` over it returned nothing. Any argument was
## accepted, discarded, and the run printed its two "is up to date" lines and
## exited 0::
##
##   $ nim r --hints:off scripts/generate_test_edges.nim --totally-made-up-flag
##   generate_test_edges: repro_tests.nim is up to date (…)
##   generate_test_edges: scripts/reprobuild-test-shape-parity.tsv is up to date (…)
##   $ echo $?
##   0
##
## The cost was not a wrong artifact — it was a worthless piece of evidence. A
## command that silently does nothing while printing a success line is
## indistinguishable, in a log or a milestone drawer, from one that did the
## work. An agent recorded in a drawer that it had regenerated the suite
## artifacts with ``nim r scripts/generate_test_edges.nim
## --write-static-case-counts``; that command regenerates neither artifact,
## and the claim was caught only because a reviewer re-derived it.
## ``reprobuild-pm/issues/2026-10-09-generate-test-edges-accepts-any-flag-and-
## reports-success.md`` records it.
##
## ``--write-static-case-counts`` and ``--write-inventory-sources`` matter
## particularly, and get a case each below, because they are REAL flags — of a
## DIFFERENT tool, ``scripts/reprobuild_suite_inventory.py``. Handed to this
## generator they did nothing, and the "up to date" lines that followed read
## as confirmation that they had been honoured.
##
## What is settled, and what each case pins
## ----------------------------------------
## This script takes no arguments. Given any, it refuses before
## ``writeBundleSources`` / ``discoverTests``, writes no file, prints a
## message that names the offending argument verbatim, says the script takes
## no arguments, and says where the ``--write-*`` / ``--check-*``
## suite-artifact flags actually live; and it exits 2.
##
##   * The first case is the control: the ordinary no-argument run is
##     untouched, so a refusal that fired on everything cannot satisfy the
##     rest of this file.
##   * The next three check the message itself — an invented flag, and the
##     other tool's two real write flags.
##   * The last is the WIRING, read out of the generator's source text: that
##     it reads the command line at all, and that ``main`` consults the
##     refusal BEFORE the first line that does work. The issue's own
##     measurement is a grep over this file returning nothing, so that case
##     is the issue's claim turned into a gate.
##
## Why the last case reads source text rather than running the generator
## ---------------------------------------------------------------------
## ``tests/integration/t_no_runtime_compilation_in_tests.nim`` forbids a test
## from invoking the Nim compiler, so this file cannot spawn ``nim r`` to
## observe the exit code. Importing the module and calling
## ``argumentRefusal`` covers the message; the ordering inside ``main`` is not
## reachable that way, because calling ``main`` would regenerate the
## repository's checked-in artifacts as a side effect of running a test.
## Source-text assertions on exactly this generator are established practice
## here — ``tests/integration/t_m4_pure_unit_consolidation.nim`` reads its
## ``PureUnitBundles`` table out of the file, and
## ``tests/unit/test_generated_artifact_merge_policy.py`` reads its ``const``
## block.
##
## Mocking: none. The refusal is the real procedure from the real module, and
## the source text is the real file at the real repository root.

import std/[os, strutils, unittest]

import "../../scripts/generate_test_edges"

const
  RepoRootMarker = "repro.nim"
  TestTablePath = "repro_tests.nim"
  GeneratorPath = "scripts/generate_test_edges.nim"
  InventoryScript = "scripts/reprobuild_suite_inventory.py"
  OtherToolsWriteFlags = ["--write-static-case-counts",
                          "--write-inventory-sources"]
    ## Real flags of ``scripts/reprobuild_suite_inventory.py``, listed here
    ## because these two are the ones that produced the false "artifacts
    ## regenerated" claim the issue records. A refusal that handled an
    ## obviously-invented flag but let a plausible one through would have
    ## left exactly that failure in place.

proc findRepoRoot(): string =
  var dir = currentSourcePath().parentDir
  while dir.len > 0:
    if fileExists(dir / RepoRootMarker) and fileExists(dir / TestTablePath):
      return dir
    let parent = dir.parentDir
    if parent == dir: break
    dir = parent
  raise newException(IOError,
    "could not find the reprobuild checkout root above " & currentSourcePath())

proc codeOutsideComments(source: string): string =
  ## ``source`` with every comment blanked to spaces, offsets preserved.
  ##
  ## WITHOUT THIS THE WIRING CASES BELOW ARE SATISFIED BY A COMMENT. The
  ## generator carries a comment at its entry point explaining that
  ## ``commandLineParams()`` is called there; replace the call itself with
  ## ``main(@[])`` and leave that comment standing and the generator is back
  ## to accepting and discarding every argument — with every case in this
  ## file still green, because ``"commandLineParams" in generatorSource``
  ## matched the prose. Reading the code with the prose removed is what makes
  ## "the generator reads its command line" an assertion about the generator
  ## rather than about its documentation.
  ##
  ## Offsets are preserved (blanked, not deleted) so the ordering comparisons
  ## and the offsets quoted in failure messages still point into the real
  ## file. The generator has no block comments and no triple-quoted strings;
  ## string and character literals are tracked so that a ``#`` inside one —
  ## the generated artifacts' own header lines are full of them — is not
  ## mistaken for the start of a comment.
  result = source
  var i = 0
  var inString = false
  var inChar = false
  var escaped = false
  while i < source.len:
    let c = source[i]
    if inString or inChar:
      if escaped:
        escaped = false
      elif c == '\\':
        escaped = true
      elif c == '\n':
        inString = false
        inChar = false
      elif inString and c == '"':
        inString = false
      elif inChar and c == '\'':
        inChar = false
    elif c == '"':
      inString = true
    elif c == '\'':
      inChar = true
    elif c == '#':
      while i < source.len and source[i] != '\n':
        result[i] = ' '
        inc i
      continue
    inc i

let repoRoot = findRepoRoot()
let generatorSource = readFile(repoRoot / GeneratorPath)
let generatorCode = codeOutsideComments(generatorSource)
  ## What the wiring cases read. See ``codeOutsideComments``.

template requireThat(condition: bool; explanation: string) =
  ## ``check`` with the diagnosis attached, in the order that prints it.
  ##
  ## ``unittest``'s ``checkpoint`` is flushed by the NEXT failing ``check``
  ## and discarded otherwise, so the common ``check x`` / ``if not x:
  ## checkpoint(...)`` spelling emits the explanation only if a later
  ## assertion also fails. Here the explanation is laid down first, so the
  ## failure that needs it is the failure that carries it.
  ##
  ## It also keeps the 60 KB of generator source text out of the report: a
  ## bare ``check "commandLineParams" in generatorSource`` dumps both
  ## operands, and a failure nobody can read is a failure nobody acts on.
  let outcome = condition
  if not outcome:
    checkpoint(explanation)
  check outcome

proc assertRefusesByName(argument: string) =
  ## Every property the refusal message owes its reader, for one argument.
  let refusal = argumentRefusal(@[argument])
  requireThat(refusal.len > 0,
    "argumentRefusal(@[\"" & argument & "\"]) returned the empty string, " &
    "which means the generator would accept this argument, discard it, do " &
    "the work and print a success line. That is the whole defect: the " &
    "caller cannot tell a honoured flag from an ignored one.")
  if refusal.len == 0:
    return
  requireThat(argument in refusal,
    "the refusal does not name '" & argument & "' verbatim: " & refusal &
    ". A refusal that does not quote back what it refused leaves the caller " &
    "guessing which of their arguments was the problem.")
  requireThat("takes no arguments" in refusal,
    "the refusal does not say that " & GeneratorPath & " takes no " &
    "arguments: " & refusal & ". The recognised set here is EMPTY, and that " &
    "is the one fact the caller needs; without it the message reads like a " &
    "typo report and invites a second guess at the spelling.")
  requireThat(InventoryScript in refusal,
    "the refusal does not name " & InventoryScript & ": " & refusal &
    ". The --write-*/--check-* suite-artifact flags belong to that script, " &
    "and sending the caller there is the difference between a refusal and " &
    "an obstruction.")

suite "generate_test_edges refuses arguments it cannot honour":

  test "the ordinary no-argument run is refused nothing":
    ## The control. Every other case below asserts that SOMETHING is refused;
    ## a predicate that refused unconditionally would satisfy all of them and
    ## break the one command that is supposed to work.
    var noArguments: seq[string] = @[]
    check argumentRefusal(noArguments) == ""

  test "an unrecognised flag is named verbatim and refused":
    assertRefusesByName("--totally-made-up-flag")

  test "the inventory script's real write flags are refused too":
    ## These are the ones that cost something. See `OtherToolsWriteFlags`.
    for flag in OtherToolsWriteFlags:
      checkpoint("refusing " & flag)
      assertRefusesByName(flag)

  test "a bare positional argument is refused as well as a flag":
    ## The refusal is about arguments, not about leading dashes. A parser
    ## that only inspected `--`-prefixed words would still accept
    ## `nim r scripts/generate_test_edges.nim repro_tests.nim` in silence.
    assertRefusesByName("repro_tests.nim")

  test "main reads the command line and consults the refusal before working":
    ## THE WIRING, and the issue's own measurement turned into a gate.
    ##
    ## `argumentRefusal` being correct buys nothing if `main` never calls it,
    ## or calls it after the generator has already walked the tree and
    ## rewritten the checked-in artifacts. Both halves are read out of the
    ## generator's source text because the alternative — running `main` — is
    ## a test that regenerates the repository as a side effect.
    ##
    ## Read out of `generatorCode`, which is the file with its comments
    ## blanked: the generator explains at its entry point that it calls
    ## `commandLineParams()` there, and a case that accepted that sentence as
    ## evidence would stay green with the call itself removed.
    requireThat("commandLineParams(" in generatorCode,
      GeneratorPath & " never CALLS `commandLineParams` outside a comment. " &
      "This is the issue's own measurement turned into a gate: `grep -nE " &
      "'paramStr|commandLineParams' " & GeneratorPath & "` returns nothing, " &
      "so every argument is accepted, discarded, and followed by a success " &
      "line that reads like confirmation it was honoured. A comment SAYING " &
      "the command line is read does not read it.")
    if "commandLineParams(" notin generatorCode:
      return

    let mainAt = generatorCode.find("\nproc main(")
    requireThat(mainAt >= 0,
      "could not find `proc main(` in " & GeneratorPath & "; this case can " &
      "no longer tell where the work begins, and would pass vacuously.")
    if mainAt < 0:
      return
    let mainOnwards = generatorCode[mainAt .. ^1]

    var workAt = -1
    var workMarker = ""
    for marker in ["writeBundleSources(", "discoverTests("]:
      let at = mainOnwards.find(marker)
      if at >= 0 and (workAt < 0 or at < workAt):
        workAt = at
        workMarker = marker
    requireThat(workAt >= 0,
      "`main` in " & GeneratorPath & " no longer calls `writeBundleSources` " &
      "or `discoverTests`, so this case cannot see where the work begins " &
      "and would pass vacuously. Name the new first-work call here.")
    if workAt < 0:
      return

    let refusalAt = mainOnwards.find("argumentRefusal")
    requireThat(refusalAt >= 0,
      "`main` in " & GeneratorPath & " never consults `argumentRefusal`. " &
      "The refusal exists but nothing reaches it, so the command line is " &
      "still accepted and discarded.")
    if refusalAt < 0:
      return
    requireThat(refusalAt < workAt,
      "`main` in " & GeneratorPath & " calls `" & workMarker & "` before it " &
      "consults `argumentRefusal`. The refusal must happen BEFORE any work: " &
      "a run that rewrites a checked-in artifact and then complains has " &
      "already done the thing it was refusing to do.")
    if refusalAt >= workAt:
      return

    # ...and the refusal path must leave with a usage exit code rather than
    # fall through to the work. 2 is the usage error; 0 would be the original
    # defect wearing a message.
    let refusalPath = mainOnwards[refusalAt ..< workAt]
    requireThat("quit(2)" in refusalPath,
      "the refusal path in `main` does not `quit(2)` before the first unit " &
      "of work. A refusal that prints and carries on is the " &
      "`--write-static-case-counts` drawer entry again: a success line " &
      "after an argument nobody honoured.")

  test "the command line is read inside `when isMainModule`, not at module scope":
    ## `scripts/generate_test_edges` is IMPORTED by
    ## `tests/integration/t_test_edge_migration_covers_all_test_files.nim`,
    ## and that test binary receives its own arguments. A
    ## `commandLineParams()` evaluated at module scope would read the
    ## importer's argv and refuse the test runner's own flags — so the
    ## generator's refusal would break every binary that imports it.
    ##
    ## `generatorCode` again, not `generatorSource`: the prose beside the
    ## call says `commandLineParams()`, and comparing offsets of prose would
    ## make this case a statement about where a sentence sits in the file.
    let guardAt = generatorCode.find("when isMainModule:")
    let paramsAt = generatorCode.find("commandLineParams(")
    requireThat(guardAt >= 0 and paramsAt >= 0 and paramsAt > guardAt,
      "`commandLineParams` must be called only under `when isMainModule:` " &
      "in " & GeneratorPath & " (found `when isMainModule:` at offset " &
      $guardAt & ", the first `commandLineParams(` call at offset " &
      $paramsAt & "). " &
      "Calling it at module scope would make every binary that imports this " &
      "module read ITS OWN argv through the generator's refusal.")
    if not (guardAt >= 0 and paramsAt >= 0 and paramsAt > guardAt):
      return

    # ...and what it is read FOR. `main(@[])` under the guard, with the call
    # left standing somewhere, would read the command line and throw it
    # away — the original defect with extra steps. So the argument `main` is
    # given has to BE the command line, either written out at the call or
    # bound to a local first.
    let entryPoint = generatorCode[guardAt .. ^1].replace(" ", "")
    let callAt = entryPoint.find("main(")
    requireThat(callAt >= 0,
      "the `when isMainModule:` block of " & GeneratorPath & " no longer " &
      "calls `main`; this case cannot see what the entry point does with " &
      "the command line and would pass vacuously.")
    if callAt < 0:
      return
    let argStart = callAt + "main(".len
    var depth = 0
    var argEnd = -1
    for j in argStart - 1 ..< entryPoint.len:
      if entryPoint[j] == '(':
        inc depth
      elif entryPoint[j] == ')':
        dec depth
        if depth == 0:
          argEnd = j
          break
    requireThat(argEnd > argStart,
      "`main` is called with no argument in the `when isMainModule:` block " &
      "of " & GeneratorPath & ", so whatever the command line says is " &
      "discarded before `argumentRefusal` ever sees it.")
    if argEnd <= argStart:
      return
    let argument = entryPoint[argStart ..< argEnd]
    requireThat("commandLineParams()" in argument or
        (argument & "=commandLineParams()") in entryPoint,
      "`main` is called with `" & argument & "` rather than with the " &
      "command line in the `when isMainModule:` block of " & GeneratorPath &
      ". Reading argv and then handing `main` something else leaves every " &
      "argument discarded, which is the defect this file exists for.")
