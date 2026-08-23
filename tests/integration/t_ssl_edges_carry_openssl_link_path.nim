## Every ``-d:ssl`` edge needs OpenSSL's ``-L``, not just the ones that were
## looked at.
##
## ``nim.c`` appends ``-lssl -lcrypto`` to any edge whose ``defines`` include
## ``ssl`` (``opensslPassLForSsl``). It does NOT supply a search path for
## them. On Linux and macOS the ``nixPackage`` entry behind ``uses:
## "openssl"`` does; on Windows that entry resolves to whichever
## ``openssl.exe`` is on PATH -- typically Git-for-Windows', which ships no
## development libraries at all -- so the link dies on ``ld.exe: cannot find
## -lssl``. ``repro.nim``'s ``windowsOpensslPassL()`` closes that by probing
## MSYS2's mingw64 lib directory and contributing a ``-L``.
##
## The failure mode this file exists for is not "the fix is wrong". It is
## "the fix reached some edges". ``opensslPassL`` was originally threaded into
## exactly two edges, both in ``.#test-helpers`` -- which happened to be the
## collection the work was validated against. The three ``.#apps`` edges that
## also set ``-d:ssl``, including the one that builds ``repro`` itself, were
## left with ``-lssl -lcrypto`` and nowhere to find them, so ``.#apps`` could
## not link on Windows at all.
##
## Partial coverage is therefore the thing to assert against, and both tests
## below are written to catch it rather than to catch a wholly missing fix:
## the static one demands the flag at EVERY ssl edge the recipe declares, and
## the dynamic one demands that the edges agree with each other about the
## search path they receive. Under the original bug the two test-helper edges
## carried a ``-L`` and the three apps edges did not, which is precisely a
## disagreement.

import std/[json, os, osproc, strtabs, strutils, tables, unittest]

const RepoMarker = "repro.nim"

type SslEdge = object
  actionId: string
  binary: string
  passLLine: string
  startLine: int

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

proc projectText(repoRoot: string): string =
  readFile(repoRoot / RepoMarker).replace("\r\n", "\n")

proc countOccurrences(haystack, needle: string): int =
  if needle.len == 0:
    return 0
  var idx = 0
  while true:
    let hit = haystack.find(needle, idx)
    if hit < 0: break
    inc result
    idx = hit + needle.len

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
  ## The ``<field> = ...`` line inside a call block, or "" if the call does
  ## not set it. Matched on the stripped prefix so ``extraPassL`` is not
  ## mistaken for ``passL``.
  for i in first .. last:
    let stripped = lines[i].strip()
    if stripped.startsWith(field & " =") or stripped.startsWith(field & "="):
      return stripped
  ""

proc sslEdgesOf(text: string): seq[SslEdge] =
  ## Every ``nim.c(...)`` call in ``repro.nim`` whose ``defines`` list carries
  ## ``ssl``. Bounded backwards by the call's own ``nim.c(`` opener and
  ## forwards by its ``actionId =`` line, which every such edge sets.
  let lines = text.splitLines()
  for i in 0 ..< lines.len:
    if not (lines[i].contains("defines =") and lines[i].contains("\"ssl\"")):
      continue
    var first = i
    while first >= 0 and not lines[first].contains("nim.c("):
      dec first
    var last = i
    while last < lines.len and not lines[last].contains("actionId = \""):
      inc last
    if first < 0 or last >= lines.len:
      # Leave a broken edge in the result with empty fields rather than
      # dropping it: a silently shorter list is the exact shape of bug this
      # test is here to refuse.
      result.add(SslEdge(actionId: "", binary: "", passLLine: "",
        startLine: i + 1))
      continue
    result.add(SslEdge(
      actionId: literalAfter(lines[last], "actionId ="),
      binary: literalAfter(fieldLine(lines, first, last, "binary"), "binary ="),
      passLLine: fieldLine(lines, first, last, "passL"),
      startLine: first + 1))

proc runWithRunquotaOnPath(cmd, repoRoot: string): tuple[output: string;
    exitCode: int] =
  ## ``poStdErrToStdOut`` is deliberately NOT in the option set, unlike
  ## ``execCmdEx``'s default. The engine writes advisory diagnostics to stderr
  ## — on this host, an "MSVC dev-env activation: VsDevCmd.bat exited 255"
  ## notice on every invocation — and merging them into stdout puts non-JSON
  ## text in front of the document ``--format=json`` produced.
  let runquotaBin = repoRoot.parentDir / "runquota" / "build" / "bin"
  var env = newStringTable()
  for k, v in envPairs():
    env[k] = v
  let oldPath = env.getOrDefault("PATH")
  env["PATH"] = runquotaBin & $PathSep & oldPath
  execCmdEx(cmd, options = {poEvalCommand, poUsePath}, env = env,
    workingDir = repoRoot)

proc parseGraphJson(output: string): JsonNode =
  ## ``nil`` when ``output`` holds no parseable JSON document. Parsing from
  ## the first ``{`` rather than from position 0 keeps any stray banner line
  ## from costing the whole document.
  let start = output.find('{')
  if start < 0:
    return nil
  try:
    return parseJson(output[start .. ^1])
  except JsonParsingError:
    return nil

proc passLValues(action: JsonNode): seq[string] =
  let argv = action{"argv"}
  if argv.isNil or argv.kind == JNull:
    return @[]
  for entry in argv:
    let value = entry.getStr()
    if value.startsWith("--passL:"):
      result.add(value[len("--passL:") .. ^1])

suite "every ssl edge receives OpenSSL's link path":

  test "static: every -d:ssl edge in repro.nim threads opensslPassL":
    let repoRoot = findRepoRoot()
    let text = projectText(repoRoot)
    let edges = sslEdgesOf(text)

    for edge in edges:
      checkpoint("ssl edge at repro.nim:" & $edge.startLine & " -> " &
        edge.actionId & " (" & edge.binary & ") | " & edge.passLLine)

    # Guard the scan itself. A scanner that matched nothing would report a
    # clean sweep, which is the same lie as the bug.
    check edges.len >= 5
    # And guard against the scan going stale: every ``"ssl"`` literal in the
    # recipe belongs to one of these ``defines`` lists, so a new edge that
    # spells its defines some other way shows up here as a mismatch rather
    # than as silent non-coverage.
    checkpoint("edges found: " & $edges.len & ", \"ssl\" literals: " &
      $countOccurrences(text, "\"ssl\""))
    check edges.len == countOccurrences(text, "\"ssl\"")

    var uncovered: seq[string] = @[]
    for edge in edges:
      if edge.actionId.len == 0:
        uncovered.add("<unparsed edge at line " & $edge.startLine & ">")
      elif "opensslPassL" notin edge.passLLine:
        uncovered.add(edge.actionId & " (passL: " &
          (if edge.passLLine.len == 0: "<absent>" else: edge.passLLine) & ")")
    if uncovered.len > 0:
      checkpoint("ssl edges without opensslPassL: " & uncovered.join(", "))
    check uncovered.len == 0

  test "engine: every ssl edge is handed the same OpenSSL search path":
    # The static test reads the recipe; this one reads the argv the engine
    # will actually run. The edges to look for still come out of the recipe
    # scan, so a newly added ssl edge is covered without touching this file --
    # and if one ever lands outside the two collections lowered here, it shows
    # up as "not found in any lowered collection" rather than as silence.
    #
    # Two collection selectors rather than five per-edge ones: a `repro graph`
    # invocation pays for compiling the project provider, and on Windows that
    # currently dominates everything else this test does.
    #
    # The assertion is AGREEMENT rather than "a -L is present", and that is
    # deliberate: `windowsOpensslPassL()` legitimately contributes nothing on
    # a host without MSYS2's OpenSSL, and nothing at all off Windows. What is
    # never legitimate is some ssl edges getting the path and others not,
    # which is exactly the state this fix found the tree in -- and note that
    # BOTH collections have to be in one comparison for that to be caught:
    # before the fix, the three `.#apps` edges agreed with each other
    # perfectly. They just disagreed with `.#test-helpers`.
    let repoRoot = findRepoRoot()
    let reproBin = repoRoot / "build" / "bin" / addFileExt("repro", ExeExt)
    check fileExists(reproBin)

    block engineArm:
      if not fileExists(reproBin):
        break engineArm

      let edges = sslEdgesOf(projectText(repoRoot))
      check edges.len >= 5

      # actionId -> the `-L` values that edge is handed, `\x1f`-joined.
      var searchPathOf = initTable[string, string]()
      var missingLssl: seq[string] = @[]
      for collection in ["apps", "test-helpers"]:
        let args = @[
          reproBin.quoteShell,
          "graph",
          ".#" & collection,
          "--tool-provisioning=path",
          "--format=json",
        ]
        let (output, exitCode) = runWithRunquotaOnPath(args.join(" "), repoRoot)
        checkpoint(".#" & collection & " graph exit=" & $exitCode)
        if exitCode != 0:
          checkpoint(output)
        check exitCode == 0
        if exitCode != 0:
          continue

        let graph = parseGraphJson(output)
        # ``not graph.isNil`` rather than ``graph != nil``: the `check` macro
        # renders its operands on failure, and ``$`` of a nil ``JsonNode``
        # segfaults, which would replace the diagnostic with a crash.
        if graph.isNil:
          checkpoint("graph output was not JSON:\n" & output)
        check not graph.isNil
        if graph.isNil:
          continue

        let actions = graph{"actions"}
        check not actions.isNil
        if actions.isNil:
          continue

        for action in actions:
          let id = action{"id"}.getStr()
          let values = passLValues(action)
          if "-lssl" notin values:
            continue
          var searchPaths: seq[string] = @[]
          for value in values:
            if value.startsWith("-L"):
              searchPaths.add(value)
          checkpoint(id & " links -lssl with search paths: " & $searchPaths)
          searchPathOf[id] = searchPaths.join("\x1f")

      # Every edge the recipe declares as an ssl edge has to have turned up as
      # an edge the engine links -lssl into. A recipe entry with no lowered
      # counterpart means the scan and the graph have drifted apart, and the
      # comparison below would then be quietly measuring a subset.
      for edge in edges:
        check edge.actionId.len > 0
        if edge.actionId.len == 0:
          continue
        if edge.actionId notin searchPathOf:
          missingLssl.add(edge.actionId)
      if missingLssl.len > 0:
        checkpoint("recipe ssl edges not lowered with -lssl in .#apps or " &
          ".#test-helpers: " & missingLssl.join(", "))
      check missingLssl.len == 0
      check searchPathOf.len >= edges.len

      var reference = ""
      var referenceId = ""
      var disagreeing: seq[string] = @[]
      for id, paths in searchPathOf:
        if referenceId.len == 0:
          referenceId = id
          reference = paths
        elif paths != reference:
          disagreeing.add(id & " got [" & paths.replace("\x1f", ", ") &
            "] where " & referenceId & " got [" &
            reference.replace("\x1f", ", ") & "]")
      if disagreeing.len > 0:
        checkpoint("ssl edges disagreeing about the OpenSSL search path: " &
          disagreeing.join("; "))
      check disagreeing.len == 0
