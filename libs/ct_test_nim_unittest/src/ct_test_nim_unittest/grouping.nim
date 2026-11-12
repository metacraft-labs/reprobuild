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
##
## DIRECTORY-PREFIX FALLBACK. The spec's grouping key is "a compile-option key
## and a directory prefix". Most directories group on their own directory, but
## some trees hold one test per subdirectory (a scenario per milestone under
## ``tests/e2e``), so each of their sources would be alone on its
## exact-directory key. Under
## the roots in ``DirectoryPrefixGroupRoots``, a source that would be ALONE on
## its exact-directory key is keyed again on the root (``prefixOptionKey``:
## the same options, the root as the directory) and grouped there, in
## ``t_group_<root>_prefix[_o<hash>]_gNN`` groups of at most
## ``PrefixGroupMaxMembers``. Sources that already share their exact
## directory keep their groups, and every other single reason applies first,
## unchanged.

import std/[algorithm, os, strutils, tables]

const
  DefaultMaxGroupMembers* = 50
    ## The owner-approved default (spec, "M1 results": G = 50, on the
    ## condition that a failed group compile falls back to single compiles —
    ## see ``scripts/test_group_fallback.py`` — and that members with heavy
    ## module initialisation are kept apart).

  PrefixGroupMaxMembers* = 25
    ## The maximum size of a directory-prefix group, below the general G = 50
    ## because the members of such a tree are typically one-per-directory
    ## scenario or recipe tests that ``import ./repro``: a recipe module's
    ## ``package`` block registers with the DSL at module initialisation, and
    ## a group binary runs every member's initialisation for every case it
    ## starts (M1 measured 56-68 ms of start-up for sources importing recipe
    ## modules; spec, "Per-case start-up overhead"). G = 25 halves that
    ## per-case cost against G = 50.

  DirectoryPrefixGroupRoots* = ["tests/e2e"]
    ## Roots whose sources, when alone on their exact directory, group on the
    ## root instead (see "DIRECTORY-PREFIX FALLBACK" above). A source directly
    ## in the root takes part too: its exact key is the root's already. A
    ## ``nim.cfg`` / ``config.nims`` between a source and the repository root
    ## keeps it single before the planner sees it (the generator's
    ## ``directoryConfigReason``), so a prefix group never loses one.
    ##
    ## NOT ``recipes/packages/source``, although its one-per-directory recipe
    ## tests were the first candidates. Start-up is no longer the reason:
    ## measured 2026-10-31 at ``agents`` 3cfae787b7, 25 recipe tests in one
    ## binary spent 43 s of user CPU initialising (147 clingo solves over a
    ## program that grew with each recipe), but since reprobuild aa127fd53
    ## a ``package`` block's registration runs no solve
    ## (``t_several_recipe_modules_init_without_a_solve_each``). Measured
    ## 2026-11-11 at ``agents`` a2eb4cfed, all 201 recipe tests in sorted
    ## groups of 25: 0 solves and 0.13-3.87 s user at start-up per group.
    ## The slowest group holds plasma-workspace, which alone takes 3.37 s,
    ## so a group costs about its slowest member plus well under a second.
    ##
    ## The reason now is the cases themselves. The same groups fail 94 of
    ## 1090 cases, almost all ``registeredArtifacts(p).len`` /
    ## ``registeredVersions(p).len`` checks: they count every registration
    ## of ``p`` in the program, and in a group other members' recipes
    ## register ``p`` again, which the registry keeps by design
    ## (``registerArtifact`` / ``registerVersion`` do not collapse
    ## duplicates). Grouping this root needs those cases to stop assuming
    ## they are alone in the program.

  PrefixGroupTagSuffix* = "_prefix"
    ## Appended to a prefix group's directory tag, so that its stems
    ## (``t_group_tests_e2e_prefix_g01``) never equal those of a group keyed
    ## on the root's own exact directory (``t_group_tests_e2e_g01``).

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
    prefixKey*: string
      ## ``prefixOptionKey`` of the source: the key it is grouped on when it
      ## is alone on ``optionKey``. "" when it is under no root in
      ## ``DirectoryPrefixGroupRoots``.
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

proc optionKeyFor(dir: string; defines, extraPassC,
                  extraPassL: openArray[string]; targetOs: string): string =
  result = dir
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
  optionKeyFor(sourceDir(source), defines, extraPassC, extraPassL, targetOs)

proc directoryPrefixRoot*(source: string): string =
  ## The ``DirectoryPrefixGroupRoots`` entry that ``source`` is under, or "".
  let dir = sourceDir(source)
  for root in DirectoryPrefixGroupRoots:
    if dir == root or dir.startsWith(root & "/"):
      return root
  ""

proc prefixOptionKey*(source: string; defines, extraPassC,
                      extraPassL: openArray[string];
                      targetOs: string): string =
  ## ``compileOptionKey`` with the source's directory replaced by its
  ## ``DirectoryPrefixGroupRoots`` root, or "" when it is under none. The
  ## group still traces to one owner: the root directory.
  let root = directoryPrefixRoot(source)
  if root.len == 0: return ""
  optionKeyFor(root, defines, extraPassC, extraPassL, targetOs)

proc groupTag(optionKey: string; prefixGroup = false): string =
  ## A file-name-safe tag for a key: the directory, sanitised, then
  ## ``PrefixGroupTagSuffix`` for a directory-prefix group, plus a short
  ## stable hash of the options when there are any.
  let bar = optionKey.find('|')
  let dir = if bar < 0: optionKey else: optionKey[0 ..< bar]
  for ch in dir:
    let c = if ch.isAlphaNumeric: ch else: '_'
    # A module name must be a Nim identifier: no doubled underscores.
    if c == '_' and (result.len == 0 or result[^1] == '_'): continue
    result.add c
  if result.endsWith("_"): result.setLen(result.len - 1)
  if prefixGroup:
    result.add PrefixGroupTagSuffix
  if bar >= 0:
    result.add "_o" & toHex(fnv1a32(optionKey[bar + 1 .. ^1]), 8).toLowerAscii

proc balancedChunks*(n, maxMembers: int): seq[int] =
  ## Sizes of k = ceil(n / maxMembers) consecutive chunks that differ by at
  ## most one, largest first.
  if n <= 0 or maxMembers <= 0: return
  let k = (n + maxMembers - 1) div maxMembers
  for i in 0 ..< k:
    result.add(n div k + (if i < n mod k: 1 else: 0))

proc groupStem*(optionKey: string; index, count: int;
                prefixGroup = false): string =
  ## ``t_group_<tag>_g<NN>``: index is 0-based, printed 1-based and padded
  ## to the width of ``count`` (at least two digits). A valid Nim identifier,
  ## because it is also the generated group module's name.
  let width = max(2, len($count))
  GroupStemPrefix & groupTag(optionKey, prefixGroup) & "_g" &
    align($(index + 1), width, '0')

proc planGroups*(candidates: openArray[GroupCandidate];
                 maxMembers = DefaultMaxGroupMembers;
                 prefixMaxMembers = PrefixGroupMaxMembers):
    seq[GroupAssignment] =
  ## Assign every candidate to a group or to a single binary. The result is in
  ## source order and does not depend on the input order.
  ##
  ## Two passes. The first groups on ``optionKey`` (the exact directory), at
  ## most ``maxMembers`` per group. The second takes the sources the first
  ## left ALONE on their key that carry a ``prefixKey`` and groups them on
  ## it, at most ``prefixMaxMembers`` per group. The clash rules
  ## (``{.compile:}`` targets, case names) apply within each pass's key.
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

  proc place(res: var seq[GroupAssignment]; cands: seq[GroupCandidate];
             key: string; members: seq[int]; limit: int;
             prefixGroup: bool): seq[int] =
    ## Group ``members`` (sorted indices into ``cands`` sharing ``key``) and
    ## return the ones left alone, without a reason.
    var kept: seq[int]
    var compiledBy = initTable[string, string]()
    var caseBy = initTable[string, string]()
    for i in members:
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
        res[i].singleReason = clash
        continue
      for target in c.compiledC: compiledBy[target] = c.source
      for name in c.caseNames:
        if name notin caseBy: caseBy[name] = c.source
      kept.add i
    if kept.len < 2 or limit < 2:
      return kept
    let sizes = balancedChunks(kept.len, limit)
    var at = 0
    for chunk, size in sizes:
      let stem = groupStem(key, chunk, sizes.len, prefixGroup)
      for j in at ..< at + size:
        res[kept[j]].group = stem
      at += size

  const Alone = "no other source shares its compile options"
  var alone: seq[int]
  for key in keys:
    alone.add place(result, cands, key, buckets[key], maxMembers, false)
  var prefixBuckets = initTable[string, seq[int]]()
  var prefixKeys: seq[string]
  for i in alone:
    let pk = cands[i].prefixKey
    if pk.len == 0:
      result[i].singleReason = Alone
      continue
    if pk notin prefixBuckets:
      prefixBuckets[pk] = @[]
      prefixKeys.add pk
    prefixBuckets[pk].add i
  prefixKeys.sort()
  for key in prefixKeys:
    var members = prefixBuckets[key]
    members.sort()
    for i in place(result, cands, key, members, prefixMaxMembers, true):
      result[i].singleReason = Alone

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
    ## path). Matched anywhere in the CODE, string literals included (a false
    ## positive costs one single compile, a false negative a broken case),
    ## but not in comments: a comment that mentions ``getAppFilename`` runs
    ## nothing (see ``withoutComments``).

  ModuleLevelSideEffects* = ["setCurrentDir", "putEnv", "delEnv",
    "addExitProc", "quit", "setControlCHook", "onSignal"]
    ## Process-global effects at column 0 run whenever the group binary
    ## starts, for every member's cases.

  GlobalLinkPragmas* = ["{.passC", "{.passc", "{.passL", "{.passl", "{.link",
    "{.define", "{.undef"]
    ## Pragmas whose effect is the whole program's C or link flags, so they
    ## would apply to every member of a group -- and ``{.define:}`` /
    ## ``{.undef:}``, which are compile options spelled in the source: a
    ## library's ``when defined(x)`` sees the define only if the defining
    ## module is processed before the library, which in a group it is not.
    ## Found by the M2 gate: ``t_daemon_parent_prewarm`` opens with
    ## ``{.define: reproDaemonParentPrewarmTest.}`` and its group failed with
    ## an undeclared identifier.

proc isIdentChar(c: char): bool = c.isAlphaNumeric or c == '_'

proc withoutComments*(text: string): string =
  ## ``text`` with every Nim comment removed: ``#`` / ``##`` line comments
  ## and ``#[ ]#`` / ``##[ ]##`` block comments (which nest). Line breaks are
  ## kept. String and character literals are copied verbatim, so a ``#``
  ## inside ``"…"``, ``r"…"``, a triple-quoted string or ``'#'`` does not
  ## start a comment. Where the lexing is approximate (an unterminated
  ## literal runs to the end of its line, or of the text for a triple quote)
  ## it errs towards keeping text, which can only make a marker visible.
  let n = text.len
  var i = 0
  while i < n:
    let c = text[i]
    if c == '#':
      let blockStart =
        if i + 1 < n and text[i + 1] == '[': 2
        elif i + 2 < n and text[i + 1] == '#' and text[i + 2] == '[': 3
        else: 0
      if blockStart == 0:
        while i < n and text[i] != '\n': inc i
        continue
      var depth = 1
      i += blockStart
      while i < n and depth > 0:
        if text[i] == '#' and i + 1 < n and text[i + 1] == '[':
          inc depth
          i += 2
        elif text[i] == '#' and i + 2 < n and text[i + 1] == '#' and
            text[i + 2] == '[':
          inc depth
          i += 3
        elif text[i] == ']' and i + 1 < n and text[i + 1] == '#':
          dec depth
          i += 2
          if i < n and text[i] == '#': inc i # the closing ``]##``
        else:
          if text[i] == '\n': result.add '\n'
          inc i
    elif c == '"' and i + 2 < n and text[i + 1] == '"' and text[i + 2] == '"':
      # Triple-quoted: no escapes; it ends at the first run of three or more
      # quotes (the extra ones belong to the literal).
      result.add "\"\"\""
      i += 3
      while i < n:
        if text[i] == '"' and i + 2 < n and text[i + 1] == '"' and
            text[i + 2] == '"':
          while i < n and text[i] == '"':
            result.add '"'
            inc i
          break
        result.add text[i]
        inc i
    elif c == '"':
      # After an identifier character this is a raw or generalized raw
      # literal (``r"…"``, ``fmt"…"``): no backslash escapes, ``""`` is a
      # quote.
      let raw = i > 0 and isIdentChar(text[i - 1])
      result.add c
      inc i
      while i < n and text[i] != '\n':
        let d = text[i]
        if not raw and d == '\\' and i + 1 < n:
          result.add text[i .. i + 1]
          i += 2
        elif d == '"' and raw and i + 1 < n and text[i + 1] == '"':
          result.add "\"\""
          i += 2
        elif d == '"':
          result.add d
          inc i
          break
        else:
          result.add d
          inc i
    elif c == '\'' and not (i > 0 and isIdentChar(text[i - 1])):
      # A character literal (``'#'``, ``'\''``, ``'\x23'``). After an
      # identifier character a quote is a numeric suffix (``1'u8``).
      var j = i + 1
      if j < n and text[j] == '\\':
        j += 2
        while j < n and text[j] notin {'\'', '\n'}: inc j
      else:
        inc j
      if j < n and text[j] == '\'':
        result.add text[i .. j]
        i = j + 1
      else:
        result.add c
        inc i
    else:
      result.add c
      inc i

proc selfSpawnMarker*(text: string): string =
  let code = withoutComments(text)
  for m in SelfSpawnMarkers:
    if m in code: return m
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
  ##
  ## Lines inside a triple-quoted string are not this file's code and are
  ## skipped: a fixture recipe written at column 0 inside a ``suite`` must
  ## not end the suite. It did, and ten sources whose later tests share a
  ## name with another file's (in a DIFFERENT suite) were kept single for a
  ## clash that ``--run suite::test`` never sees.
  var suiteName = ""
  var suiteIndent = -1
  var inTripleQuote = false
  for line in text.splitLines:
    if line.count("\"\"\"") mod 2 == 1:
      inTripleQuote = not inTripleQuote
      continue
    if inTripleQuote: continue
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

const
  SuiteScopeDeclarations = ["test ", "test(", "setup:", "teardown:",
    "proc ", "func ", "template ", "macro ", "iterator ", "converter ",
    "const ", "type ", "#", "discard", "when ", "else:", "elif ", "of "]
    ## What may stand directly in a ``suite`` body without running at module
    ## initialisation. ``when`` is allowed as a line (its branches are deeper
    ## and are scanned only for their own statement keyword, not followed).

proc suiteScopeWork*(text: string): string =
  ## The first statement that runs in a ``suite`` body outside any ``test``
  ## (or ``setup`` / ``teardown``), or "". ``std/unittest`` runs a suite body
  ## when the module initialises, so such a statement runs in EVERY process
  ## the binary starts. Grouped, that is every case of every member: full-suite
  ## run 41 measured minutes per case in ``t_group_tests_integration_g05``,
  ## whose member ``t_federated_catalog_diagnostics_are_actionable`` builds
  ## and publishes fixture catalogs (spawning ``nim c``) at suite scope.
  ##
  ## A ``suite`` header whose name expression is continued on further lines
  ## (``suite "a, " &`` / ``    "b":``) ends at the line that ends in ``:``;
  ## its continuation lines are the header, not the body, and do not fix the
  ## body's indentation.
  var suiteIndent = -1
  var bodyIndent = -1
  var inHeader = false
  var inTripleQuote = false
  proc endsHeader(t: string): bool =
    withoutComments(t).strip(leading = false).endsWith(":")
  for line in text.splitLines:
    if line.count("\"\"\"") mod 2 == 1:
      inTripleQuote = not inTripleQuote
      continue
    if inTripleQuote: continue
    let t = line.strip(trailing = false)
    if t.len == 0: continue
    let indent = line.len - t.len
    if t.startsWith("suite ") or t.startsWith("suite("):
      suiteIndent = indent
      bodyIndent = -1
      inHeader = not endsHeader(t)
      continue
    if suiteIndent < 0: continue
    if indent <= suiteIndent:
      if not t.startsWith("#"):
        suiteIndent = -1
      continue
    if inHeader:
      if endsHeader(t): inHeader = false
      continue
    if bodyIndent < 0: bodyIndent = indent
    if indent != bodyIndent: continue
    var declared = t.startsWith("\"")
      # a continuation of a string expression begun on an earlier line
    for d in SuiteScopeDeclarations:
      if t.startsWith(d):
        declared = true
        break
    if not declared:
      # A test-defining template (``gatedTest "name":``,
      # ``testWithReturn "name":``): an identifier, a string literal, a
      # block. It registers a case like ``test`` does; it is not work.
      var i = 0
      while i < t.len and (t[i].isAlphaNumeric or t[i] == '_'): inc i
      if i > 0 and i + 1 < t.len and t[i] == ' ' and t[i + 1] == '"' and
          t.endsWith(":"):
        declared = true
    if not declared:
      return t
  ""

proc moduleLevelWork*(text: string): string =
  ## The first bare call statement at column 0 (``createDir(…)``,
  ## ``writeFile(…)``, ``register(…)``), outside string literals, or "".
  ## Like suite-scope work it runs whenever the binary starts, for every case
  ## of every member of a group: ``t_e2e_home_profile_imports_contribution_catalog``
  ## builds its fixture tree and extracts a recipe at module level, and its
  ## group could not reach a first case within 120 s.
  var inTripleQuote = false
  for line in text.splitLines:
    if line.count("\"\"\"") mod 2 == 1:
      inTripleQuote = not inTripleQuote
      continue
    if inTripleQuote or line.len == 0 or line[0] notin {'a' .. 'z'}:
      continue
    if line.startsWith("let ") or line.startsWith("var "):
      # ``let x = f(...)`` at module level runs ``f`` at every start-up:
      # ``let markedSnp = sharedSnpTestHierarchy(…)`` generates RSA-4096
      # keys, ~33 CPU-s for every case of its group. A capitalised callee is
      # an object constructor and does no work.
      let eq = line.find('=')
      if eq > 0 and (eq + 1 >= line.len or line[eq + 1] != '='):
        let rhs = line[eq + 1 .. ^1].strip()
        var k = 0
        while k < rhs.len and (rhs[k].isAlphaNumeric or rhs[k] in {'_', '.'}):
          inc k
        if k > 0 and k < rhs.len and rhs[k] == '(' and rhs[0] in {'a' .. 'z'}:
          return line
      continue
    var i = 0
    while i < line.len and (line[i].isAlphaNumeric or line[i] in {'_', '.'}):
      inc i
    if i < line.len and line[i] == '(':
      return line
  ""
