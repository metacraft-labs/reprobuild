## Every Windows monitor-artefact edge must link libgcc STATICALLY.
##
## The shim is not loaded the way an ordinary DLL is. The engine
## ``LoadLibraryW``s it into arbitrary children — gcc, cc1, as, ld, whatever a
## monitored action spawns — so it has to resolve with no help at all from the
## child's DLL search path. Linked dynamically, a mingw-built shim imports
## ``libgcc_s_seh-1.dll``, which lives only in the bin directory of whichever
## mingw happened to build it. That directory is on a developer's interactive
## PATH, which is exactly why the omission is invisible where it is made; it is
## NOT on the PATH the engine composes for a monitored action, and the injected
## child then dies with::
##
##   repro internal io monitor: error: LoadLibraryW in child returned NULL
##
## io-mon's ``scripts/build_shim.sh`` passes ``--passL:"-static-libgcc"`` on
## every one of its Windows ``nim c`` invocations and carries that reasoning as
## a comment. When S1 turned those four invocations into graph edges the flag
## reached three of them; the 64-bit shim — the one artefact that is ALWAYS
## built, on every Windows host, and the anchor the other three hang off — was
## the one that lost it.
##
## Why this needs a test rather than a comment
## -------------------------------------------
## The failure is silent in the way this whole initiative is about. A shim that
## fails to load does not fail the build: the child simply runs unmonitored,
## which is an unknown-scope evidence loss, which makes the owning action
## uncacheable — and an uncacheable action looks exactly like an action that
## legitimately had to re-run. Nothing prints. Worse, whether the flag matters
## is TOOLCHAIN-dependent: a gcc that links libgcc statically by default
## produces a byte-clean artefact without it, so the tree can sit in the broken
## state for as long as nobody's compiler changes. That is a defect that only
## reproduces on someone else's machine, which is the definition of one worth
## pinning with a test.
##
## Two arms, deliberately
## ----------------------
## The static arm reads ``repro.nim`` and demands the flag at EVERY edge that
## stages a monitor artefact, so a fifth artefact added later without it fails
## here rather than in the field. The engine arm reads the argv the engine will
## actually hand ``nim``, which is the only thing that is really binding: the
## recipe is a claim, ``--passL:-static-libgcc`` in the lowered action is the
## fact. Both are needed — the static one covers the edges a host cannot build
## (no i686 toolchain means three of the four never lower at all), and the
## engine one covers the possibility that the wrapper drops what the recipe
## sets.

import std/[json, os, osproc, sequtils, strtabs, strutils, unittest]

import repro_dsl_stdlib/monitor_shim_artifacts

const
  RepoMarker = "repro.nim"
  StaticLibgcc = "-static-libgcc"

type MonitorEdge = object
  actionId: string
  binaryLine: string
  passLLine: string
  startLine: int

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

proc projectText(repoRoot: string): string =
  readFile(repoRoot / RepoMarker).replace("\r\n", "\n")

proc literalAfter(text, marker: string): string =
  let pos = text.find(marker)
  if pos < 0:
    return ""
  let rest = text[pos + marker.len .. ^1]
  let open = rest.find('"')
  if open < 0:
    return ""
  let close = rest.find('"', open + 1)
  if close < 0:
    return ""
  rest[open + 1 ..< close]

proc fieldLine(lines: openArray[string]; first, last: int;
    field: string): string =
  ## The ``<field> = ...`` line inside a call block, or "" if the call does not
  ## set it. Matched on the stripped prefix so ``extraPassL`` is never mistaken
  ## for ``passL``.
  for i in first .. last:
    let stripped = lines[i].strip()
    if stripped.startsWith(field & " =") or stripped.startsWith(field & "="):
      return stripped
  ""

proc monitorEdgesOf(text: string): seq[MonitorEdge] =
  ## Every ``nim.c(...)`` call in ``repro.nim`` that stages a Windows monitor
  ## artefact, i.e. whose ``binary`` is a ``monitorArtifactPath(...)``. Bounded
  ## backwards by the call's own ``nim.c(`` opener and forwards by its
  ## ``actionId =`` line, which all four of them set.
  let lines = text.splitLines()
  for i in 0 ..< lines.len:
    let stripped = lines[i].strip()
    if not (stripped.startsWith("binary =") and
            stripped.contains("monitorArtifactPath(")):
      continue
    var first = i
    while first >= 0 and not lines[first].contains("nim.c("):
      dec first
    var last = i
    while last < lines.len and not lines[last].contains("actionId = \""):
      inc last
    if first < 0 or last >= lines.len:
      # An unparsed edge stays in the result with empty fields rather than
      # being dropped. A silently shorter list is the same lie as the bug.
      result.add(MonitorEdge(actionId: "", binaryLine: stripped,
        passLLine: "", startLine: i + 1))
      continue
    result.add(MonitorEdge(
      actionId: literalAfter(lines[last], "actionId ="),
      binaryLine: stripped,
      passLLine: fieldLine(lines, first, last, "passL"),
      startLine: first + 1))

proc runWithRunquotaOnPath(cmd, repoRoot: string): tuple[output: string;
    exitCode: int] =
  ## ``poStdErrToStdOut`` is deliberately absent, unlike ``execCmdEx``'s
  ## default: the engine writes advisory diagnostics to stderr (on a Windows
  ## host, an "MSVC dev-env activation: VsDevCmd.bat exited 255" notice on
  ## every invocation) and merging them into stdout puts non-JSON text in front
  ## of the document ``--format=json`` produced.
  let runquotaBin = repoRoot.parentDir / "runquota" / "build" / "bin"
  var env = newStringTable()
  for k, v in envPairs():
    env[k] = v
  let oldPath = env.getOrDefault("PATH")
  env["PATH"] = runquotaBin & $PathSep & oldPath
  execCmdEx(cmd, options = {poEvalCommand, poUsePath}, env = env,
    workingDir = repoRoot)

proc parseGraphJson(output: string): JsonNode =
  ## ``nil`` when ``output`` holds no parseable JSON document. Parsing from the
  ## first ``{`` rather than from position 0 keeps a stray banner line from
  ## costing the whole document.
  let start = output.find('{')
  if start < 0:
    return nil
  try:
    return parseJson(output[start .. ^1])
  except JsonParsingError:
    return nil

proc argvOf(action: JsonNode): seq[string] =
  let argv = action{"argv"}
  if argv.isNil or argv.kind == JNull:
    return @[]
  for entry in argv:
    result.add(entry.getStr())

suite "every Windows monitor-artefact edge links libgcc statically":

  test "static: every monitorArtifactPath edge in repro.nim passes " &
      "-static-libgcc":
    let repoRoot = findRepoRoot()
    let edges = monitorEdgesOf(projectText(repoRoot))

    for edge in edges:
      checkpoint("monitor edge at repro.nim:" & $edge.startLine & " -> " &
        edge.actionId & " | " & edge.binaryLine & " | " &
        (if edge.passLLine.len == 0: "passL: <absent>" else: edge.passLLine))

    # Guard the scan itself, twice over. A scanner that matched nothing would
    # report a clean sweep, and the artefact list is the authority on how many
    # there should be — so adding a fifth artefact without an edge, or an edge
    # without an artefact, shows up here as a count mismatch rather than as
    # silent non-coverage.
    checkpoint("edges found: " & $edges.len & ", artefacts declared: " &
      $windowsMonitorArtifactNames().len)
    check edges.len == windowsMonitorArtifactNames().len

    var uncovered: seq[string] = @[]
    for edge in edges:
      if edge.actionId.len == 0:
        uncovered.add("<unparsed edge at line " & $edge.startLine & ">")
      elif StaticLibgcc notin edge.passLLine:
        uncovered.add(edge.actionId & " (passL: " &
          (if edge.passLLine.len == 0: "<absent>" else: edge.passLLine) & ")")
    if uncovered.len > 0:
      checkpoint("monitor edges without " & StaticLibgcc & ": " &
        uncovered.join(", "))
    check uncovered.len == 0

  test "the sibling io-mon script still agrees that the flag is required":
    # A cheap staleness check across the repository seam this fix straddles.
    # If io-mon ever drops ``-static-libgcc`` from its own shim build, these
    # edges are mirroring a decision that no longer exists and somebody should
    # look. Skipped rather than failed when the sibling is absent: a reprobuild
    # checkout is not required to have one.
    let sibling = findRepoRoot().parentDir / "io-mon" / "scripts" /
      "build_shim.sh"
    if not fileExists(sibling):
      checkpoint("[not applicable] no io-mon sibling at " & sibling)
      skip()
    else:
      let text = readFile(sibling)
      checkpoint(sibling & " mentions " & StaticLibgcc & ": " &
        $text.contains(StaticLibgcc))
      check text.contains(StaticLibgcc)

  test "engine: every lowered monitor-artefact action carries " &
      "--passL:-static-libgcc":
    # The static arm reads the recipe; this one reads the argv the engine will
    # actually run, which is the only binding artefact. The edge ids still come
    # out of the recipe scan, so a newly added artefact edge is covered without
    # touching this file.
    #
    # Off Windows the whole ``elif defined(windows)`` arm that declares these
    # edges is not compiled into the provider at all, so there is nothing to
    # lower and nothing this arm could assert.
    when not defined(windows):
      checkpoint("[platform N/A] the monitor-artefact edges are Windows-only")
      skip()
    else:
      let repoRoot = findRepoRoot()
      let reproBin = repoRoot / "build" / "bin" / addFileExt("repro", ExeExt)
      check fileExists(reproBin)

      block engineArm:
        if not fileExists(reproBin):
          break engineArm

        let edges = monitorEdgesOf(projectText(repoRoot))
        check edges.len == windowsMonitorArtifactNames().len

        let cmd = @[
          reproBin.quoteShell,
          "graph",
          ".#test-fixtures",
          "--tool-provisioning=path",
          "--format=json",
        ].join(" ")
        let (output, exitCode) = runWithRunquotaOnPath(cmd, repoRoot)
        checkpoint(".#test-fixtures graph exit=" & $exitCode)
        if exitCode != 0:
          checkpoint(output)
        check exitCode == 0
        if exitCode != 0:
          break engineArm

        let graph = parseGraphJson(output)
        # ``not graph.isNil`` rather than ``graph != nil``: ``check`` renders
        # its operands on failure and ``$`` of a nil ``JsonNode`` crashes,
        # which would replace the diagnostic with a segfault.
        if graph.isNil:
          checkpoint("graph output was not JSON:\n" & output)
        check not graph.isNil
        if graph.isNil:
          break engineArm

        let actions = graph{"actions"}
        check not actions.isNil
        if actions.isNil:
          break engineArm

        var lowered: seq[string] = @[]
        var missingFlag: seq[string] = @[]
        for action in actions:
          let id = action{"id"}.getStr()
          var wanted = false
          for edge in edges:
            if edge.actionId.len > 0 and edge.actionId == id:
              wanted = true
          if not wanted:
            continue
          lowered.add(id)
          let argv = argvOf(action)
          checkpoint(id & " passL args: " &
            $argv.filterIt(it.startsWith("--passL:")))
          if ("--passL:" & StaticLibgcc) notin argv:
            missingFlag.add(id)

        # The 64-bit shim is the one edge every Windows host declares; the
        # other three exist only where an i686 toolchain does, and their
        # absence is a documented degradation rather than a failure. So the
        # floor is "the anchor lowered", not "all four".
        let shim64Id = block:
          var found = ""
          for edge in edges:
            if edge.binaryLine.contains("MonitorShim64Name"):
              found = edge.actionId
          found
        checkpoint("lowered monitor-artefact actions: " & $lowered &
          "; 64-bit shim edge is " & shim64Id)
        check shim64Id.len > 0
        check shim64Id in lowered

        if missingFlag.len > 0:
          checkpoint("lowered actions missing --passL:" & StaticLibgcc & ": " &
            missingFlag.join(", "))
        check missingFlag.len == 0
