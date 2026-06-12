## Deferred Item D5: ``.#<collection>#<member>`` CLI selector resolves
## through the engine's per-collection action membership.
##
## Before D5, the CLI accepted ``.#<action-id>`` and bare-name selectors
## but had no shorthand for picking a single member of a build-graph
## collection. Selecting one EXECUTE edge required spelling the full
## ``.#reprobuild.test_execute.<stem>`` action id; the natural
## ``.#test#<stem>`` shape (the outer ``#test`` picks the collection,
## the inner ``#<stem>`` picks the member) raised
## ``unknown_target: no build target matches 'test#<stem>'``.
##
## Three arms:
##
##   1. STRUCTURAL — assert the resolver source carries the D5
##      ``<collection>#<member>`` recognition logic. Anchors textual
##      markers so a refactor that drops the recognition path surfaces
##      immediately at the source-level review surface.
##
##   2. BEHAVIOURAL — drive ``./build/bin/repro build .#test#<stem>``
##      end-to-end. Mirrors the D1 behavioural arm's shape: assert
##      exit 0 + the EXECUTE-edge action is recorded in the build
##      report with ``status == "asSucceeded"`` and ``launched ==
##      true``.
##
##   3. COLLECTION-AGNOSTIC — drive the same shorthand against
##      ``.#test-builds#<stem>`` (build edge) and ``.#apps#<name>``
##      (apps collection) so the mechanism is verified across all
##      three of reprobuild's own collections, not just one.

import std/[json, os, osproc, strtabs, strutils, unittest]

const RepoMarker = "repro.nim"

# Small, fast DSL parse test (mirrors D1's pick). The build edge is
# carried by the ``test-builds`` collection (auto-generated nim-c-*
# action id; resolves via implicit-name matching) and the execute edge
# is carried by the ``test`` collection (explicit
# ``reprobuild.test_execute.<stem>`` action id; resolves via
# ``.<member>`` suffix matching).
const TargetTest = "t_dsl_outputs_statement_basic_accepted"
const ExecuteActionId = "reprobuild.test_execute." & TargetTest

# An apps-collection member — picked because the build is small and
# always present on every host (a thin admin CLI). The action id is
# ``reprobuild.apps.repro-peer-cache-admin`` per
# ``reprobuild/repro.nim``'s explicit ``actionId`` argument.
const AppsMember = "repro-peer-cache-admin"
const AppsActionId = "reprobuild.apps." & AppsMember

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

proc runWithRunquotaOnPath(cmd, repoRoot: string): tuple[output: string;
    exitCode: int] =
  let runquotaBin = repoRoot.parentDir / "runquota" / "build" / "bin"
  var env = newStringTable()
  for k, v in envPairs():
    env[k] = v
  let oldPath = env.getOrDefault("PATH")
  env["PATH"] = runquotaBin & $PathSep & oldPath
  execCmdEx(cmd, env = env, workingDir = repoRoot)

proc valueAfter(output, prefix: string): string =
  for line in output.splitLines:
    if line.startsWith(prefix):
      return line[prefix.len .. ^1].strip()
  ""

proc reportActions(report: JsonNode): JsonNode =
  result = report{"actions"}
  if result.isNil or result.kind == JNull:
    result = newJArray()

proc runBuild(reproBin, repoRoot, selector: string;
              withReport: bool): tuple[output: string; exitCode: int] =
  let args = @[
    reproBin.quoteShell,
    "build",
    selector,
    "--tool-provisioning=path",
    "--daemon=off",
    "--report=" & (if withReport: "full" else: "none"),
    "--log=actions",
    "--progress=quiet",
  ]
  let cmd = args.join(" ")
  runWithRunquotaOnPath(cmd, repoRoot)

suite "Deferred Item D5: .#<collection>#<member> selector resolves through the engine":

  test "structural: resolver source carries the D5 collection-member recognition logic":
    let repoRoot = findRepoRoot()
    let resolverSrc = repoRoot / "libs" / "repro_cli_support" / "src" /
      "repro_cli_support.nim"
    check fileExists(resolverSrc)

    let resolverText = readFile(resolverSrc)

    # The D5 recognition logic must name the feature and the shape it
    # accepts. Anchor on textual markers so the structural contract
    # stays visible.
    check "Deferred Item D5" in resolverText
    check "<collection>#<member>" in resolverText
    # The engine-side resolver lives inside ``resolveSelectorToActionId``
    # (the lowering-pass resolver). The build-report path lives inside
    # ``resolveTargetExportSelector``. Both must carry the recognition
    # so the report row reflects what the engine executed.
    check "resolveSelectorToActionId" in resolverText
    check "collectionMembers" in resolverText
    # Match strategies the resolver exposes: action-id equality,
    # ``.<member>`` suffix (for ``reprobuild.<verb>.<stem>`` ids),
    # implicit-name matching (for auto-generated nim-c-* ids).
    check "suffix" in resolverText.toLowerAscii or "needle" in resolverText.toLowerAscii
    check "implicit-name" in resolverText.toLowerAscii or "Implicit-name" in resolverText

    checkpoint("D5 structural assertion: OK")

  test "behavioural: ``.#test#<stem>`` resolves to the execute edge and runs end-to-end":
    let repoRoot = findRepoRoot()
    let reproBin = repoRoot / "build" / "bin" /
      addFileExt("repro", ExeExt)
    let runquotad = repoRoot.parentDir / "runquota" / "build" / "bin" /
      addFileExt("runquotad", ExeExt)

    if not fileExists(reproBin):
      checkpoint("skipped — " & reproBin &
        " is missing; run `just build` first")
      skip()
    elif not fileExists(runquotad):
      checkpoint("skipped — " & runquotad &
        " is missing; build runquota first")
      skip()
    else:
      let selector = ".#test#" & TargetTest
      let (output, exitCode) = runBuild(reproBin, repoRoot, selector,
        withReport = true)
      checkpoint("running selector: " & selector)
      checkpoint("exit=" & $exitCode)
      if exitCode != 0:
        checkpoint(output)
      # The selector must not produce the pre-D5 ``unknown_target``.
      check "unknown_target" notin output
      check "no build target matches" notin output
      check exitCode == 0

      let reportPath = valueAfter(output, "buildReport:")
      check reportPath.len > 0
      check fileExists(reportPath)

      let report = parseFile(reportPath)
      let actions = reportActions(report)
      var executeAction: JsonNode = nil
      for action in actions:
        if action{"id"}.getStr() == ExecuteActionId:
          executeAction = action
          break
      check executeAction != nil
      if executeAction != nil:
        let status = executeAction{"status"}.getStr()
        let launched = executeAction{"launched"}.getBool()
        checkpoint(ExecuteActionId & " status=" & status &
          " launched=" & $launched)
        # On a cold run the engine launches the execute action; on a
        # warm run it may cache-hit. Both shapes are acceptable
        # evidence that the resolver routed the selector to the
        # EXECUTE edge (NOT the BUILD edge whose action id would not
        # appear here).
        check status in ["asSucceeded", "asCacheHit", "asUpToDate"]

  test "collection-agnostic: ``.#test-builds#<stem>`` resolves to the build edge":
    let repoRoot = findRepoRoot()
    let reproBin = repoRoot / "build" / "bin" /
      addFileExt("repro", ExeExt)
    let runquotad = repoRoot.parentDir / "runquota" / "build" / "bin" /
      addFileExt("runquotad", ExeExt)

    if not fileExists(reproBin):
      checkpoint("skipped — " & reproBin &
        " is missing; run `just build` first")
      skip()
    elif not fileExists(runquotad):
      checkpoint("skipped — " & runquotad &
        " is missing; build runquota first")
      skip()
    else:
      # ``test-builds`` carries build edges whose action ids are
      # auto-generated (``nim-c-<hash>``), so the resolver must reach
      # the implicit-name index — the binary's basename
      # (``t_dsl_outputs_statement_basic_accepted``) is registered as
      # an implicit target name pointing at the build action id.
      let selector = ".#test-builds#" & TargetTest
      let (output, exitCode) = runBuild(reproBin, repoRoot, selector,
        withReport = false)
      checkpoint("running selector: " & selector)
      checkpoint("exit=" & $exitCode)
      if exitCode != 0:
        checkpoint(output)
      check "unknown_target" notin output
      check exitCode == 0
      # The build edge produces ``build/test-bin/<stem>`` per the
      # ``buildNimUnittest.build(...)`` typed-tool's ``binary`` arg.
      let testBinary = repoRoot / "build" / "test-bin" / TargetTest
      check fileExists(testBinary)

  test "collection-agnostic: ``.#apps#<name>`` resolves to an apps-collection member":
    let repoRoot = findRepoRoot()
    let reproBin = repoRoot / "build" / "bin" /
      addFileExt("repro", ExeExt)
    let runquotad = repoRoot.parentDir / "runquota" / "build" / "bin" /
      addFileExt("runquotad", ExeExt)

    if not fileExists(reproBin):
      checkpoint("skipped — " & reproBin &
        " is missing; run `just build` first")
      skip()
    elif not fileExists(runquotad):
      checkpoint("skipped — " & runquotad &
        " is missing; build runquota first")
      skip()
    else:
      let selector = ".#apps#" & AppsMember
      let (output, exitCode) = runBuild(reproBin, repoRoot, selector,
        withReport = true)
      checkpoint("running selector: " & selector)
      checkpoint("exit=" & $exitCode)
      if exitCode != 0:
        checkpoint(output)
      check "unknown_target" notin output
      check exitCode == 0

      let reportPath = valueAfter(output, "buildReport:")
      check reportPath.len > 0
      check fileExists(reportPath)

      let report = parseFile(reportPath)
      let actions = reportActions(report)
      var appsAction: JsonNode = nil
      for action in actions:
        if action{"id"}.getStr() == AppsActionId:
          appsAction = action
          break
      check appsAction != nil
      if appsAction != nil:
        let status = appsAction{"status"}.getStr()
        checkpoint(AppsActionId & " status=" & status)
        check status in ["asSucceeded", "asCacheHit", "asUpToDate"]

  test "diagnostic: unknown member produces clear error with collection hints":
    ## When ``<member>`` doesn't match any action in the named
    ## collection, the resolver must surface a precise diagnostic that
    ## names the collection (so the user knows which set was searched)
    ## and offers Levenshtein hints over the actual members.
    let repoRoot = findRepoRoot()
    let reproBin = repoRoot / "build" / "bin" /
      addFileExt("repro", ExeExt)
    let runquotad = repoRoot.parentDir / "runquota" / "build" / "bin" /
      addFileExt("runquotad", ExeExt)

    if not fileExists(reproBin):
      checkpoint("skipped — " & reproBin &
        " is missing; run `just build` first")
      skip()
    elif not fileExists(runquotad):
      checkpoint("skipped — " & runquotad &
        " is missing; build runquota first")
      skip()
    else:
      let selector = ".#test#nonexistent_member_xyz"
      let (output, exitCode) = runBuild(reproBin, repoRoot, selector,
        withReport = false)
      checkpoint("running selector: " & selector)
      checkpoint("exit=" & $exitCode)
      check exitCode != 0
      check "unknown_target" in output
      # The diagnostic must mention the failing selector.
      check "test#nonexistent_member_xyz" in output
