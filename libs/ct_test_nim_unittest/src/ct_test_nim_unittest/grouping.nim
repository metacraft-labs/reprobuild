## ct_test_nim_unittest/grouping — which test sources share one binary.
##
## Test-Binary-Grouping M2 (``reprobuild-specs`` ``spec/Test-Binary-Grouping.md``).
## Compiling one executable per test source re-analyses and re-compiles the
## shared library closure once per file; a "group" binary imports up to
## ``DefaultMaxGroupMembers`` member modules and pays for that closure once.
## M1 measured 51 instead of 314 CPU-seconds per ``tests/unit`` source at
## G = 50, with the same cases passing.
##
## This module is PURE: no file system, no environment, no clock. Everything
## it decides is a function of its arguments, so the generator that stamps the
## plan into ``repro_tests.nim`` (``scripts/generate_test_edges.nim``), the
## recipe that turns the plan into build edges (``repro.nim``) and the unit
## tests all see the same answer. The facts it needs about a source's TEXT
## (self-spawn markers, ``{.compile:}`` targets, case names) are extracted by
## the helpers at the bottom, which take the text as a string.
##
## MEMBERSHIP RULE. Sources group only with sources whose compile is the same
## except for the source path: equal ``compileOptionKey`` (directory plus
## every per-test compile option). Within one key, the sorted list of eligible
## sources is cut into k = ceil(N / G) consecutive chunks whose sizes differ by
## at most one, so there is no small tail group paying the closure for a few
## files (M1, "Partition"). Group names are a function of the key and the
## chunk index, so the same tree always produces the same groups.

import std/[algorithm, os, strutils, tables]

const
  DefaultMaxGroupMembers* = 50
    ## The owner-approved default (spec, "M1 results": G = 50, on the
    ## condition that a failed group compile falls back to single compiles —
    ## see ``scripts/test_group_fallback.py`` — and that members with heavy
    ## module initialisation are kept apart).

  GroupStemPrefix* = "t_group_"
    ## Group binaries live in ``build/test-bin`` beside the single ones, so the
    ## suite runner, which executes every ``t_*`` executable there, runs them
    ## without being told about groups. A stem is also the group MODULE'S
    ## name, so it must be a valid Nim identifier: no doubled or trailing
    ## underscore (see ``groupStem``). The generator refuses a stem that
    ## collides with a test source's.

  GroupModuleDir* = "build/test-groups"
    ## Where the recipe's ``writeText`` edges put the generated group modules.
    ## Under ``build/`` so no generated source ever lands in the tree; its
    ## parent chain carries the same Nim configuration as every test directory
    ## (only the repository root has a ``config.nims``; a test directory with
    ## its own config is kept single, see the generator).

type
  GroupCandidate* = object
    ## One test source, as the planner sees it.
    source*: string
      ## Repo-relative, forward slashes.
    optionKey*: string
      ## ``compileOptionKey`` of the source. Two sources may share a binary
      ## only when these are equal.
    singleReason*: string
      ## Non-empty when the source must keep its own binary, with the reason.
      ## The planner adds its own reasons (clashes, a key with one member) on
      ## top of these.
    compiledC*: seq[string]
      ## Repo-relative paths of the C files the source ``{.compile:}``s. Two
      ## members compiling the same file link its object twice ("multiple
      ## definition", found by M1).
    caseNames*: seq[string]
      ## The statically visible ``suite::test`` names of the source. The
      ## runner selects a case with ``--run <name>``, which does not name the
      ## file, so a name must be unique inside a binary.

  GroupAssignment* = object
    source*: string
    group*: string
      ## The group binary stem, or "" when the source keeps its own binary.
    singleReason*: string
      ## Why the source keeps its own binary; "" when it is grouped.

proc fnv1a32(s: string): uint32 =
  ## A fixed hash, independent of the Nim version's ``hash`` seed.
  result = 2166136261'u32
  for c in s:
    result = (result xor uint32(ord(c))) * 16777619'u32

proc sourceDir(source: string): string =
  let slash = source.rfind('/')
  if slash < 0: "" else: source[0 ..< slash]

proc compileOptionKey*(source: string; defines, extraPassC,
                       extraPassL: openArray[string];
                       targetOs: string): string =
  ## The compile-option key: the source's directory, then every per-test
  ## option that changes the compile. The directory is part of the key for two
  ## reasons: a group binary then stays bisectable to one owner, and Nim reads
  ## ``nim.cfg`` / ``config.nims`` from the main module's parent chain, so
  ## sources from different directories can differ in configuration the
  ## ``TestSpec`` row does not show.
  ##
  ## Defines are sorted: their order on the command line changes nothing.
  result = sourceDir(source)
  var opts: seq[string]
  var ds = @defines
  ds.sort()
  for d in ds: opts.add "-d:" & d
  for c in extraPassC: opts.add "--passC:" & c
  for l in extraPassL: opts.add "--passL:" & l
  if targetOs.len > 0 and targetOs != "soAny":
    opts.add "targetOs:" & targetOs
  if opts.len > 0:
    result.add "|" & opts.join(" ")

proc groupTag(optionKey: string): string =
  ## A file-name-safe tag for a key: the directory, sanitised, plus a short
  ## stable hash of the options when there are any.
  let bar = optionKey.find('|')
  let dir = if bar < 0: optionKey else: optionKey[0 ..< bar]
  for ch in dir:
    let c = if ch.isAlphaNumeric: ch else: '_'
    # A module name must be a Nim identifier: no doubled underscores.
    if c == '_' and (result.len == 0 or result[^1] == '_'): continue
    result.add c
  if result.endsWith("_"): result.setLen(result.len - 1)
  if bar >= 0:
    result.add "_o" & toHex(fnv1a32(optionKey[bar + 1 .. ^1]), 8).toLowerAscii

proc balancedChunks*(n, maxMembers: int): seq[int] =
  ## Sizes of k = ceil(n / maxMembers) consecutive chunks that differ by at
  ## most one, largest first.
  if n <= 0 or maxMembers <= 0: return
  let k = (n + maxMembers - 1) div maxMembers
  for i in 0 ..< k:
    result.add(n div k + (if i < n mod k: 1 else: 0))

proc groupStem*(optionKey: string; index, count: int): string =
  ## ``t_group_<tag>_g<NN>``: index is 0-based, printed 1-based and padded
  ## to the width of ``count`` (at least two digits). A valid Nim identifier,
  ## because it is also the generated group module's name.
  let width = max(2, len($count))
  GroupStemPrefix & groupTag(optionKey) & "_g" & align($(index + 1), width, '0')

proc planGroups*(candidates: openArray[GroupCandidate];
                 maxMembers = DefaultMaxGroupMembers): seq[GroupAssignment] =
  ## Assign every candidate to a group or to a single binary. The result is in
  ## source order and does not depend on the input order.
  var cands = @candidates
  cands.sort(proc (a, b: GroupCandidate): int = cmp(a.source, b.source))
  result = newSeq[GroupAssignment](cands.len)
  var buckets = initTable[string, seq[int]]()
  var keys: seq[string]
  for i, c in cands:
    result[i] = GroupAssignment(source: c.source, singleReason: c.singleReason)
    if c.singleReason.len > 0:
      continue
    if maxMembers < 2:
      result[i].singleReason = "grouping disabled (maximum group size " &
        $maxMembers & ")"
      continue
    if c.optionKey notin buckets:
      buckets[c.optionKey] = @[]
      keys.add c.optionKey
    buckets[c.optionKey].add i
  keys.sort()
  for key in keys:
    var kept: seq[int]
    var compiledBy = initTable[string, string]()
    var caseBy = initTable[string, string]()
    for i in buckets[key]:
      let c = cands[i]
      var clash = ""
      for target in c.compiledC:
        if target in compiledBy:
          clash = "{.compile.} " & target & " is also compiled by " &
            compiledBy[target]
          break
      if clash.len == 0:
        for name in c.caseNames:
          if name in caseBy and caseBy[name] != c.source:
            clash = "case name `" & name & "` is also declared by " &
              caseBy[name]
            break
      if clash.len > 0:
        # The first source in sorted order keeps its place; later ones stay
        # single, so adding a source never moves an earlier one out.
        result[i].singleReason = clash
        continue
      for target in c.compiledC: compiledBy[target] = c.source
      for name in c.caseNames:
        if name notin caseBy: caseBy[name] = c.source
      kept.add i
    if kept.len < 2:
      for i in kept:
        result[i].singleReason = "no other source shares its compile options"
      continue
    let sizes = balancedChunks(kept.len, maxMembers)
    var at = 0
    for chunk, size in sizes:
      let stem = groupStem(key, chunk, sizes.len)
      for j in at ..< at + size:
        result[kept[j]].group = stem
      at += size

proc groupMembers*(plan: openArray[GroupAssignment]): OrderedTable[string, seq[string]] =
  ## group stem -> sorted member sources, groups in sorted stem order.
  var stems: seq[string]
  var tmp = initTable[string, seq[string]]()
  for row in plan:
    if row.group.len == 0: continue
    if row.group notin tmp:
      tmp[row.group] = @[]
      stems.add row.group
    tmp[row.group].add row.source
  stems.sort()
  result = initOrderedTable[string, seq[string]]()
  for s in stems:
    var members = tmp[s]
    members.sort()
    result[s] = members

proc groupModulePath*(groupStem: string): string =
  GroupModuleDir & "/" & groupStem & ".nim"

proc groupModuleText*(groupStem: string; members: openArray[string]): string =
  ## The generated group module: one quoted relative ``import`` per member, in
  ## sorted order (module initialisation order is import order), and nothing
  ## else.
  ##
  ## ``import``, not ``include``: each member keeps its own module scope, so
  ## two members that both declare a top-level ``ExpectedUrl`` do not collide;
  ## ``suite`` / ``test`` register into ``unittest``'s process-wide tables at
  ## module initialisation, which is what puts every member's cases in one
  ## binary. Quoted because a directory containing ``-`` cannot be spelled
  ## with Nim's dotted import syntax.
  var sortedMembers = @members
  sortedMembers.sort()
  var up = ""
  for _ in GroupModuleDir.split('/'):
    up.add "../"
  result = "## GENERATED by the reprobuild recipe from repro_tests.nim -- do " &
    "not edit.\n## Test-Binary-Grouping group " & groupStem & " (" &
    $sortedMembers.len & " members).\n"
  for m in sortedMembers:
    let modPath = if m.endsWith(".nim"): m[0 ..< m.len - 4] else: m
    result.add "import \"" & up & modPath & "\"\n"

# ---------------------------------------------------------------------------
# Facts about a source's text. Each returns "" (or an empty list) when the
# source is fine to share a binary.
# ---------------------------------------------------------------------------

const
  SelfSpawnMarkers* = ["isMainModule", "getAppFilename"]
    ## A source that names either re-executes its own binary as a worker or
    ## guards code on being the main module. In a group binary
    ## ``isMainModule`` is false in every member and ``getAppFilename`` names
    ## the group, so neither would behave (spec M3 gives them a supported
    ## path). Matched anywhere in the text, comments included: a false
    ## positive costs one single compile, a false negative a broken case.

  ModuleLevelSideEffects* = ["setCurrentDir", "putEnv", "delEnv",
    "addExitProc", "quit", "setControlCHook", "onSignal"]
    ## Process-global effects at column 0 run whenever the group binary
    ## starts, for every member's cases.

  GlobalLinkPragmas* = ["{.passC", "{.passc", "{.passL", "{.passl", "{.link"]
    ## Pragmas whose effect is the whole program's C or link flags, so they
    ## would apply to every member of a group.

proc selfSpawnMarker*(text: string): string =
  for m in SelfSpawnMarkers:
    if m in text: return m
  ""

proc moduleLevelSideEffect*(text: string): string =
  for line in text.splitLines:
    for s in ModuleLevelSideEffects:
      if line.startsWith(s) and (line.len == s.len or
          line[s.len] in {'(', ' ', '.'}):
        return s
  ""

proc globalLinkPragma*(text: string): string =
  for line in text.splitLines:
    let t = line.strip(trailing = false)
    for p in GlobalLinkPragmas:
      if t.startsWith(p) and t.len > p.len and t[p.len] in {':', '.', ' '}:
        return p[2 .. ^1]
  ""

proc compilePragmaTargets*(text, source: string): seq[string] =
  ## Repo-relative paths named by a literal ``{.compile: "<path>"...}`` in the
  ## text of ``source`` (itself repo-relative). Non-literal arguments are not
  ## resolvable here; a clash among those is caught by the compile fallback.
  let dir = sourceDir(source)
  for line in text.splitLines:
    let at = line.find("{.compile:")
    if at < 0: continue
    let q1 = line.find('"', at)
    if q1 < 0: continue
    let q2 = line.find('"', q1 + 1)
    if q2 < 0: continue
    let rel = line[q1 + 1 ..< q2]
    let joined = if dir.len == 0: rel else: dir & "/" & rel
    result.add normalizedPath(joined).replace('\\', '/')

proc staticCaseNames*(text: string): seq[string] =
  ## ``suite::test`` for every literal ``suite "..."`` / ``test "..."`` the
  ## text declares; ``::test`` for a test outside any suite (the form the
  ## ``std/unittest`` fork catalogs it under). Names built at run time are
  ## invisible here; the runner refuses an ambiguous ``--run`` name it meets
  ## in a catalog regardless.
  var suiteName = ""
  var suiteIndent = -1
  for line in text.splitLines:
    let t = line.strip(trailing = false)
    let indent = line.len - t.len
    if suiteIndent >= 0 and t.len > 0 and indent <= suiteIndent and
        not t.startsWith("#"):
      suiteName = ""
      suiteIndent = -1
    for (kw, isSuite) in [("suite \"", true), ("test \"", false)]:
      if not t.startsWith(kw): continue
      let close = t.find('"', kw.len)
      if close < 0: continue
      let name = t[kw.len ..< close]
      if isSuite:
        suiteName = name
        suiteIndent = indent
      else:
        let qualified = (if suiteIndent >= 0: suiteName else: "") & "::" & name
        if qualified notin result:
          result.add qualified

# ---------------------------------------------------------------------------
# From a binary and a catalog row back to the case's source file.
#
# A case's identity is ``<source file> :: <suite> :: <test>`` (spec, "What does
# not change"); the binary is a build artefact. The suite runner keys result
# files, the console and its report on the source this resolves, so a case
# keeps its identity whether its file is compiled alone, into a group, or
# alone again by the compile fallback.
# ---------------------------------------------------------------------------

type
  CaseSourceIndex* = object
    byStem*: Table[string, string]
      ## source stem -> repo-relative source
    groupMembers*: Table[string, seq[string]]
      ## group binary stem -> repo-relative member sources, table order

proc quotedField(line, field: string): tuple[found: bool; value: string] =
  ## ``    <field>: "<value>",`` -> value, with the generator's escapes
  ## (``\\`` and ``\"``) undone.
  let t = line.strip()
  let prefix = field & ": \""
  if not t.startsWith(prefix): return
  let close = t.rfind('"')
  if close < prefix.len: return
  result.found = true
  var i = prefix.len
  while i < close:
    if t[i] == '\\' and i + 1 < close:
      result.value.add t[i + 1]
      i += 2
    else:
      result.value.add t[i]
      inc i

proc parseCaseSourceIndex*(tableText: string): CaseSourceIndex =
  ## Read the ``source`` / ``group`` fields of a ``repro_tests.nim`` table.
  result.byStem = initTable[string, string]()
  result.groupMembers = initTable[string, seq[string]]()
  var current = ""
  for line in tableText.splitLines:
    let src = quotedField(line, "source")
    if src.found:
      current = src.value
      result.byStem[splitFile(current).name] = current
      continue
    let grp = quotedField(line, "group")
    if grp.found and grp.value.len > 0 and current.len > 0:
      result.groupMembers.mgetOrPut(grp.value, @[]).add(current)

proc isGroupBinary*(index: CaseSourceIndex; binaryStem: string): bool =
  binaryStem in index.groupMembers or binaryStem.startsWith(GroupStemPrefix)

proc caseSourceOf*(index: CaseSourceIndex; binaryStem, catalogFile: string):
    string =
  ## The source a case belongs to. For a group binary: the member whose file
  ## name the catalog row's ``file`` reports (the declaring module). For a
  ## single-file binary: the binary's own source, whatever ``file`` says, so a
  ## case declared through a helper module stays attributed to the test that
  ## compiled it, as it always was. Without an index entry, the catalog file
  ## name (group) or the binary stem (single).
  if index.isGroupBinary(binaryStem):
    let file = extractFilename(catalogFile.replace('\\', '/'))
    for member in index.groupMembers.getOrDefault(binaryStem):
      if extractFilename(member) == file:
        return member
    if file.len > 0:
      return index.byStem.getOrDefault(splitFile(file).name, file)
    return binaryStem
  index.byStem.getOrDefault(binaryStem, binaryStem)

proc memberStems*(index: CaseSourceIndex; binaryStem: string): seq[string] =
  for member in index.groupMembers.getOrDefault(binaryStem):
    result.add(splitFile(member).name)
