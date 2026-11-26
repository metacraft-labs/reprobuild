## The generated ``repro health`` table in the user documentation has one row
## for every check ``repro health`` reports, and no row for a check it does not.
##
## WHAT IS UNDER TEST. ``scripts/render_user_docs_generated.py`` keeps a
## hand-written, ordered table of the health checks (``HEALTH_CHECK_SPECS``:
## name, what it inspects, whether ``--fix`` repairs it) and renders it into
## the generated region of
## ``docs/users/content/guides/troubleshooting/diagnose-with-repro-health.md``.
## Its ``--check`` refuses a table that disagrees with the checks
## ``repro_cli_support.nim`` constructs. A check added to the engine without a
## row (``hook-configs`` was) makes ``--check`` fail with
## ``Health check mismatch vs repro_cli_support.nim: missing=[...]``, and the
## documentation build, which runs ``--check``, fails with it.
##
## Two things are held:
##
##   * the committed page: its generated health table names exactly the checks
##     the engine source constructs. The names are read here from the whole of
##     ``repro_cli_support.nim``, with nothing shared with the generator (which
##     reads a window around ``gatherHealthChecks``), so the two cannot agree
##     by sharing a mistake. ``hook-configs`` must be among them, so the survey
##     cannot pass by matching nothing;
##   * the generator: ``--check`` runs to a verdict, reports no health-check
##     mismatch, and finds every generated region current.
##
## NO MOCKS. The real ``python3`` on ``PATH`` runs the real generator script
## over the real engine source and the committed page; nothing is stubbed.
## Like ``t_user_docs_command_rows_carry_one_line_help``, it needs no
## documentation-framework checkouts, so it runs wherever ``python3`` does.

import std/[os, osproc, sets, strutils, unittest]

# Running `python3` from PATH is the point of this test (it is how the site
# build and a contributor run the generator), so the ambient-execution
# wrapper says so.
from repro_core/ambient_execution import uncontrolledExecCmdEx

const
  RepoRoot = currentSourcePath().parentDir.parentDir.parentDir
  Generator = RepoRoot / "scripts" / "render_user_docs_generated.py"
  CliSupport = RepoRoot / "libs" / "repro_cli_support" / "src" /
    "repro_cli_support.nim"
  HealthPage = RepoRoot / "docs" / "users" / "content" / "guides" /
    "troubleshooting" / "diagnose-with-repro-health.md"
  RegionBegin = "<!-- generated:begin cli-reference health checks -->"
  RegionEnd = "<!-- generated:end -->"

proc literalAt(text: string; at: int): string =
  ## The string literal that opens at ``at`` after any whitespace, or "" when
  ## what is there is not a literal (``name: name`` names no check).
  var open = at
  while open < text.len and text[open] in Whitespace:
    inc open
  if open >= text.len or text[open] != '"':
    return ""
  let close = text.find('"', open + 1)
  if close < 0:
    return ""
  text[open + 1 ..< close]

proc checksTheEngineConstructs(): HashSet[string] =
  ## Every check name ``repro_cli_support.nim`` gives a ``HealthCheck``: the
  ## ``name:`` of each ``HealthCheck(`` constructor, the first argument of each
  ## ``skippedForUnresolvedManifest(`` (a check whose sweep had nothing to
  ## read), and the ``const name = "..."`` a check proc builds its rows from.
  let text = readFile(CliSupport)
  var at = 0
  while true:
    at = text.find("HealthCheck(", at)
    if at < 0:
      break
    at += "HealthCheck(".len
    var first = at
    while first < text.len and text[first] in Whitespace:
      inc first
    if text.continuesWith("name:", first):
      result.incl literalAt(text, first + "name:".len)
  at = 0
  while true:
    at = text.find("skippedForUnresolvedManifest(\"", at)
    if at < 0:
      break
    at += "skippedForUnresolvedManifest(".len
    result.incl literalAt(text, at)
  for line in text.splitLines:
    let stripped = line.strip
    if stripped.startsWith("const name = \""):
      result.incl literalAt(stripped, "const name =".len)
  result.excl ""

proc checksThePageNames(): HashSet[string] =
  ## The first cell of every row in the page's generated health table.
  let text = readFile(HealthPage)
  let begin = text.find(RegionBegin)
  doAssert begin >= 0, HealthPage & " has no " & RegionBegin
  let stop = text.find(RegionEnd, begin)
  doAssert stop > begin, HealthPage & ": the health region is not closed"
  for line in text[begin + RegionBegin.len ..< stop].splitLines:
    if line.startsWith("| `"):
      result.incl line.split('`')[1]

suite "user docs: the repro health table names every health check":
  test "the committed table has a row for exactly the checks the engine constructs":
    let engine = checksTheEngineConstructs()
    let page = checksThePageNames()
    # Not vacuous: the check whose missing row this test was written for.
    require "hook-configs" in engine
    require engine.len > 20
    checkpoint "in the engine, not on the page: " & $(engine - page)
    checkpoint "on the page, not in the engine: " & $(page - engine)
    check engine - page == initHashSet[string]()
    check page - engine == initHashSet[string]()

  test "the generator's --check finds no health-check mismatch":
    let (output, exitCode) = uncontrolledExecCmdEx(
      "python3 " & quoteShell(Generator) & " --check",
      options = {poStdErrToStdOut}, workingDir = RepoRoot)
    checkpoint output
    check "Health check mismatch" notin output
    check exitCode == 0
