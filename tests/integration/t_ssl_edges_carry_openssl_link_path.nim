## Every ``-d:ssl`` edge gets OpenSSL's ``-L``, and none of them gets it from
## the recipe.
##
## ``nim.c`` appends ``-lssl -lcrypto`` to any edge whose ``defines`` include
## ``ssl``. On Linux and macOS the ``nixPackage`` arm behind ``uses:
## "openssl"`` supplies a search path for them; on Windows the package
## declared nothing at all, so the link died on ``ld.exe: cannot find -lssl``.
##
## The failure mode this file was written for is not "the fix is wrong". It is
## "the fix reached some edges". The original fix lived in ``repro.nim`` as
## ``windowsOpensslPassL()`` and was threaded onto the ``passL`` of exactly two
## edges, both in ``.#test-helpers`` — which happened to be the collection the
## work was validated against. The three ``.#apps`` edges that also set
## ``-d:ssl``, including the one that builds ``repro`` itself, were left with
## ``-lssl -lcrypto`` and nowhere to find them, so ``.#apps`` could not link on
## Windows at all. Note the shape of that: the three ``.#apps`` edges agreed
## with each other perfectly. They just disagreed with ``.#test-helpers``.
##
## M8 moved the derivation into ``nim.c`` itself, off the openssl package's
## declared Windows layout (``repro_dsl_stdlib/openssl_layout``). That changes
## what the STATIC test can usefully ask. "Does every ssl edge thread the
## helper?" is now the wrong question — there is no helper to thread, and a
## test still demanding one would pass only while someone kept re-adding the
## thing the milestone removed. The question that survives the change is the
## one the bug was really about: *can an ssl edge in this recipe express a
## search path of its own at all?* If the answer is no, partial coverage is
## unreachable by construction rather than by vigilance.
##
## So the static test now asserts the ABSENCE of a per-edge OpenSSL path, and
## the engine test keeps asking the lowered graph — with the assertion
## strengthened from "the edges agree" to "the edges agree AND, where the host
## can supply one, the directory they were given really holds the import
## libraries". Agreement alone was all the old mechanism could promise, since
## it could legitimately contribute nothing; a derivation that reports a
## directory can be held to the stronger claim.

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

proc holdsImportLibraries(dir: string): bool =
  ## Whether ``dir`` really carries an import library for both stems `nim.c`
  ## emits. Same acceptance rule as the package's own, restated here rather
  ## than imported so this test still fails if the package's rule is loosened
  ## to accept a directory the linker cannot use.
  if dir.len == 0 or not dirExists(dir):
    return false
  for stem in ["ssl", "crypto"]:
    var found = false
    for name in ["lib" & stem & ".dll.a", stem & ".dll.a", "lib" & stem & ".a",
                 "lib" & stem & ".lib", stem & ".lib"]:
      if fileExists(dir / name):
        found = true
        break
    if not found:
      return false
  true

suite "every ssl edge receives OpenSSL's link path":

  test "static: no -d:ssl edge in repro.nim carries a search path of its own":
    # M8 inverted this assertion deliberately. It used to demand that every
    # ssl edge thread ``opensslPassL``; the search path now comes from the
    # openssl package via ``nim.c``, so an edge that names one is a recipe
    # taking back a decision the producer owns — and the moment one edge can,
    # the others can be forgotten, which is the whole bug.
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

    var selfSupplied: seq[string] = @[]
    for edge in edges:
      if edge.actionId.len == 0:
        selfSupplied.add("<unparsed edge at line " & $edge.startLine & ">")
        continue
      let line = edge.passLLine
      if "openssl" in line.toLowerAscii or "-L" in line or "lssl" in line or
          "lcrypto" in line:
        selfSupplied.add(edge.actionId & " (passL: " & line & ")")
    if selfSupplied.len > 0:
      checkpoint("ssl edges naming an OpenSSL path themselves: " &
        selfSupplied.join(", "))
    check selfSupplied.len == 0

    # The recipe is still allowed to OFFER a prefix — it provisions MSYS2's
    # OpenSSL into a dev-deps tree only it knows about — but that is a prefix
    # handed to the package, not a flag handed to an edge. Exactly one such
    # offer, so the "which edges did it reach?" question cannot come back.
    checkpoint("registerOpensslPrefixCandidate occurrences: " &
      $countOccurrences(text, "registerOpensslPrefixCandidate("))
    check countOccurrences(text, "registerOpensslPrefixCandidate(") == 1
    check "proc windowsOpensslPassL" notin text

  test "engine: every ssl edge is handed the same usable OpenSSL search path":
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
    # AGREEMENT is asserted unconditionally; USABILITY is asserted whenever a
    # path was supplied at all. A host with no OpenSSL development libraries
    # anywhere legitimately gets nothing (and fails the link with a clear
    # `cannot find -lssl`), but a host that gets a directory must get one the
    # linker can actually resolve `-lssl` in -- a `-L` that resolves nothing
    # is worse than none, because it looks like the channel was supplied.
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

      # M8: what was handed over has to be usable. Before M8 this could only
      # ever have been "they agree", because the value came from a probe that
      # was allowed to produce nothing on a host that nonetheless had OpenSSL.
      var unusable: seq[string] = @[]
      for id, paths in searchPathOf:
        if paths.len == 0:
          continue
        for entry in paths.split("\x1f"):
          if not entry.startsWith("-L"):
            continue
          let dir = entry[2 .. ^1]
          if not holdsImportLibraries(dir):
            unusable.add(id & " -> " & dir)
      if unusable.len > 0:
        checkpoint("ssl edges handed a -L with no OpenSSL import library " &
          "in it: " & unusable.join("; "))
      check unusable.len == 0
