## Test-Binary-Grouping M2: the group plan (``ct_test_nim_unittest/grouping``).
##
## No mocks: the planner is a pure function of its arguments, and the text
## helpers take source text as a string, so every case below runs the
## production code on literal inputs.

import std/[algorithm, sequtils, strutils, tables, unittest]

import ct_test_nim_unittest/grouping

proc cand(source: string; key = ""; reason = "";
          compiled: seq[string] = @[]; cases: seq[string] = @[]):
    GroupCandidate =
  GroupCandidate(source: source,
    optionKey: if key.len > 0: key else: source[0 ..< source.rfind('/')],
    singleReason: reason, compiledC: compiled, caseNames: cases)

proc unitFiles(n: int; dir = "tests/unit"): seq[GroupCandidate] =
  for i in 0 ..< n:
    result.add cand(dir & "/t_" & align($i, 3, '0') & ".nim")

proc groupOf(plan: seq[GroupAssignment]; source: string): string =
  for row in plan:
    if row.source == source: return row.group
  raise newException(KeyError, source)

suite "test binary grouping: chunking":
  test "chunks are ceil(N/G) consecutive runs whose sizes differ by at most one":
    check balancedChunks(203, 50) == @[41, 41, 41, 40, 40]
    check balancedChunks(50, 50) == @[50]
    check balancedChunks(51, 50) == @[26, 25]
    check balancedChunks(0, 50).len == 0
    for n in 1 .. 230:
      let sizes = balancedChunks(n, 50)
      check sizes.foldl(a + b) == n
      check sizes.len == (n + 49) div 50
      check max(sizes) <= 50
      check max(sizes) - min(sizes) <= 1

  test "members are consecutive in sorted source order, at most G per group":
    let plan = planGroups(unitFiles(120), 50)
    let groups = groupMembers(plan)
    check groups.len == 3
    var seen: seq[string]
    for stem, members in groups:
      check members.len <= 50
      check members == members.sorted()
      seen.add members
    check seen == seen.sorted()
    check seen.len == 120

  test "group stems name the directory and the chunk index":
    let plan = planGroups(unitFiles(120), 50)
    check toSeq(groupMembers(plan).keys) == @[
      "t_group_tests_unit_g01", "t_group_tests_unit_g02",
      "t_group_tests_unit_g03"]

  test "a group stem is a valid Nim identifier, because it names the module":
    # ``nim c`` refuses a main module whose name is not an identifier
    # (``t_group__x`` was: "invalid module name").
    let dashed = compileOptionKey("tests/e2e/hcr-linux-threads/t_a.nim",
      ["reproProviderMode"], [], [], "soAny")
    for key in ["tests/unit", "libs/repro_core/tests", dashed, "a-/-b"]:
      for i in [0, 9, 99]:
        let stem = groupStem(key, i, 100)
        check stem.validIdentifier
        check "__" notin stem
        check stem.startsWith(GroupStemPrefix)

suite "test binary grouping: determinism":
  test "the plan does not depend on input order":
    var forward = unitFiles(77) & unitFiles(30, "libs/repro_core/tests")
    var backward = forward
    backward.reverse()
    check planGroups(forward, 25) == planGroups(backward, 25)

  test "the plan and the group module text are byte-identical on a second run":
    let a = planGroups(unitFiles(99), 50)
    let b = planGroups(unitFiles(99), 50)
    check a == b
    for stem, members in groupMembers(a):
      check groupModuleText(stem, members) ==
        groupModuleText(stem, members.reversed())

  test "the group module imports every member relative to build/test-groups":
    let text = groupModuleText("t_group_tests_unit_g01",
      @["tests/unit/t_b.nim", "tests/unit/t_a.nim"])
    check groupModulePath("t_group_tests_unit_g01") ==
      "build/test-groups/t_group_tests_unit_g01.nim"
    let imports = text.splitLines.filterIt(it.startsWith("import "))
    check imports == @["import \"../../tests/unit/t_a\"",
                       "import \"../../tests/unit/t_b\""]

suite "test binary grouping: eligibility":
  test "a source with a single reason never joins a group":
    var cands = unitFiles(10)
    cands[3].singleReason = "self-spawn marker isMainModule"
    let plan = planGroups(cands, 50)
    check plan.groupOf(cands[3].source) == ""
    check plan[3].singleReason == "self-spawn marker isMainModule"
    for i, row in plan:
      if i != 3: check row.group == "t_group_tests_unit_g01"

  test "only sources with equal compile-option keys share a binary":
    let plain = compileOptionKey("tests/unit/t_a.nim", [], [], [], "soAny")
    let provider = compileOptionKey("tests/unit/t_b.nim",
      ["reproProviderMode"], [], [], "soAny")
    check plain == "tests/unit"
    check provider != plain
    check compileOptionKey("tests/unit/t_c.nim", ["b", "a"], [], [], "soAny") ==
      compileOptionKey("tests/unit/t_d.nim", ["a", "b"], [], [], "soAny")
    check compileOptionKey("libs/x/tests/t_a.nim", [], [], [], "soAny") != plain
    let plan = planGroups(@[
      cand("tests/unit/t_a.nim", plain), cand("tests/unit/t_b.nim", provider),
      cand("tests/unit/t_c.nim", plain), cand("tests/unit/t_d.nim", provider)],
      50)
    check plan.groupOf("tests/unit/t_a.nim") ==
      plan.groupOf("tests/unit/t_c.nim")
    check plan.groupOf("tests/unit/t_b.nim") ==
      plan.groupOf("tests/unit/t_d.nim")
    check plan.groupOf("tests/unit/t_a.nim") !=
      plan.groupOf("tests/unit/t_b.nim")
    check plan.groupOf("tests/unit/t_b.nim").startsWith(
      "t_group_tests_unit_o")

  test "a key with one eligible source keeps it single":
    let plan = planGroups(@[cand("tests/e2e/x/t_only.nim")], 50)
    check plan[0].group == ""
    check plan[0].singleReason == "no other source shares its compile options"

  test "the later of two members compiling the same C file stays single":
    let plan = planGroups(@[
      cand("tests/unit/t_a.nim", compiled = @["libs/h/c/probe.c"]),
      cand("tests/unit/t_b.nim"),
      cand("tests/unit/t_c.nim", compiled = @["libs/h/c/probe.c"])], 50)
    check plan.groupOf("tests/unit/t_a.nim") != ""
    check plan.groupOf("tests/unit/t_c.nim") == ""
    check "libs/h/c/probe.c is also compiled by tests/unit/t_a.nim" in
      plan[2].singleReason

  test "the later of two members declaring the same case name stays single":
    let plan = planGroups(@[
      cand("tests/unit/t_a.nim", cases = @["s::x"]),
      cand("tests/unit/t_b.nim", cases = @["s::y"]),
      cand("tests/unit/t_c.nim", cases = @["s::x"])], 50)
    check plan.groupOf("tests/unit/t_c.nim") == ""
    check "case name `s::x` is also declared by tests/unit/t_a.nim" in
      plan[2].singleReason

  test "grouping can be switched off with a maximum below two":
    for row in planGroups(unitFiles(5), 1):
      check row.group == ""

proc prefixCand(source: string; defines: seq[string] = @[];
                reason = ""; cases: seq[string] = @[]): GroupCandidate =
  ## A candidate keyed the way the generator keys it.
  GroupCandidate(source: source,
    optionKey: compileOptionKey(source, defines, [], [], "soAny"),
    prefixKey: prefixOptionKey(source, defines, [], [], "soAny"),
    singleReason: reason, caseNames: cases)

proc scenarioFiles(n: int): seq[GroupCandidate] =
  ## One test per scenario directory, the tests/e2e/m<NN> shape.
  for i in 0 ..< n:
    let dir = "m" & align($i, 3, '0')
    result.add prefixCand("tests/e2e/" & dir & "/t_" & dir & ".nim")

suite "test binary grouping: directory-prefix fallback":
  test "prefix keys exist only under the configured roots":
    check DirectoryPrefixGroupRoots == ["tests/e2e"]
    # Recipe tests stay out: several recipe modules in one binary cost tens
    # of CPU-seconds of module initialisation per start (see the constant).
    check prefixOptionKey("recipes/packages/source/zlib/test_zlib_source.nim",
      [], [], [], "soAny") == ""
    check prefixOptionKey("tests/e2e/m73/t_x.nim", [], [], [], "soAny") ==
      "tests/e2e"
    check prefixOptionKey("tests/e2e/t_top.nim", [], [], [], "soAny") ==
      "tests/e2e"
    check prefixOptionKey("tests/unit/t_a.nim", [], [], [], "soAny") == ""
    # A sibling whose name only starts like a root is not under it.
    check prefixOptionKey("tests/e2e-extra/t_a.nim", [], [], [], "soAny") == ""
    # The options stay in the key: a prefix group never mixes them.
    check prefixOptionKey("tests/e2e/m73/t_x.nim", ["reproProviderMode"], [],
      [], "soAny") != "tests/e2e"

  test "sources alone in their directory group on the root, at most 25 each":
    check PrefixGroupMaxMembers == 25
    let plan = planGroups(scenarioFiles(195))
    let groups = groupMembers(plan)
    # ceil(195 / 25) = 8 balanced chunks (25, 25, 25, 24, ...), not 4 of 50.
    check groups.len == 8
    var total = 0
    for stem, members in groups:
      check stem.startsWith("t_group_tests_e2e_prefix_g0")
      check stem.validIdentifier
      check members.len <= 25
      check members.len >= 24
      total += members.len
    check total == 195
    check toSeq(groups.keys)[0] == "t_group_tests_e2e_prefix_g01"
    for row in plan: check row.singleReason == ""

  test "an explicit prefix cap is honoured independently of G":
    let plan = planGroups(scenarioFiles(30), 50, 10)
    let groups = groupMembers(plan)
    check groups.len == 3
    for stem, members in groups: check members.len == 10

  test "directories with several sources keep their exact-directory groups":
    var cands = @[
      prefixCand("tests/e2e/addon/t_a.nim"), prefixCand("tests/e2e/addon/t_b.nim"),
      prefixCand("tests/e2e/m73/t_lone.nim"), prefixCand("tests/e2e/m74/t_lone2.nim"),
      prefixCand("tests/e2e/t_top.nim")]
    let plan = planGroups(cands)
    check plan.groupOf("tests/e2e/addon/t_a.nim") == "t_group_tests_e2e_addon_g01"
    check plan.groupOf("tests/e2e/addon/t_b.nim") == "t_group_tests_e2e_addon_g01"
    for lone in ["tests/e2e/m73/t_lone.nim", "tests/e2e/m74/t_lone2.nim",
                 "tests/e2e/t_top.nim"]:
      check plan.groupOf(lone) == "t_group_tests_e2e_prefix_g01"

  test "a prefix group's stem cannot collide with the root's own group":
    # Two sources directly in tests/e2e form the root's exact-directory group;
    # the subdirectory leftovers form a prefix group with a distinct stem.
    let plan = planGroups(@[
      prefixCand("tests/e2e/t_a.nim"), prefixCand("tests/e2e/t_b.nim"),
      prefixCand("tests/e2e/m73/t_c.nim"), prefixCand("tests/e2e/m74/t_d.nim")])
    check plan.groupOf("tests/e2e/t_a.nim") == "t_group_tests_e2e_g01"
    check plan.groupOf("tests/e2e/m73/t_c.nim") == "t_group_tests_e2e_prefix_g01"

  test "single reasons and option keys still apply under a prefix":
    let plan = planGroups(@[
      prefixCand("tests/e2e/m73/t_a.nim"),
      prefixCand("tests/e2e/m74/t_b.nim", reason = "self-spawn marker isMainModule"),
      prefixCand("tests/e2e/m75/t_c.nim", defines = @["reproProviderMode"]),
      prefixCand("tests/e2e/m76/t_d.nim")])
    check plan.groupOf("tests/e2e/m73/t_a.nim") == "t_group_tests_e2e_prefix_g01"
    check plan.groupOf("tests/e2e/m76/t_d.nim") == "t_group_tests_e2e_prefix_g01"
    check plan.groupOf("tests/e2e/m74/t_b.nim") == ""
    check plan[1].singleReason == "self-spawn marker isMainModule"
    # Alone on its options even under the root: still single.
    check plan.groupOf("tests/e2e/m75/t_c.nim") == ""
    check plan[2].singleReason == "no other source shares its compile options"

  test "case-name clashes are checked across a prefix group's members":
    let plan = planGroups(@[
      prefixCand("tests/e2e/m73/t_a.nim", cases = @["s::x"]),
      prefixCand("tests/e2e/m74/t_b.nim", cases = @["s::y"]),
      prefixCand("tests/e2e/m75/t_c.nim", cases = @["s::x"])])
    check plan.groupOf("tests/e2e/m75/t_c.nim") == ""
    check "case name `s::x` is also declared by tests/e2e/m73/t_a.nim" in
      plan[2].singleReason
    check plan.groupOf("tests/e2e/m73/t_a.nim") ==
      plan.groupOf("tests/e2e/m74/t_b.nim")

  test "a lone source outside every root stays single":
    let plan = planGroups(@[prefixCand("tests/unit/t_only.nim"),
      prefixCand("recipes/packages/source/a/test_a_source.nim"),
      prefixCand("recipes/packages/source/b/test_b_source.nim")])
    for row in plan:
      check row.group == ""
      check row.singleReason == "no other source shares its compile options"

suite "test binary grouping: source text facts":
  test "self-spawn markers":
    check selfSpawnMarker("let me = getAppFilename()") == "getAppFilename"
    check selfSpawnMarker("when isMainModule:\n  main()") == "isMainModule"
    check selfSpawnMarker("import std/unittest") == ""

  test "self-spawn markers in comments only do not count":
    check selfSpawnMarker("# no getAppFilename here\nlet x = 1") == ""
    check selfSpawnMarker("## Doc: unlike t_x, this never calls " &
      "getAppFilename.\nlet x = 1") == ""
    check selfSpawnMarker("let x = 1 # not isMainModule") == ""
    check selfSpawnMarker("#[ getAppFilename\n  isMainModule ]#\nlet x = 1") == ""
    check selfSpawnMarker("##[ doc\n getAppFilename ]##\nlet x = 1") == ""
    # Block comments nest.
    check selfSpawnMarker("#[ a #[ b ]# getAppFilename ]#\nlet x = 1") == ""
    # Code after a closed block comment, or on the next line, still counts.
    check selfSpawnMarker("#[ c ]# let me = getAppFilename()") ==
      "getAppFilename"
    check selfSpawnMarker("# c\nwhen isMainModule: main()") == "isMainModule"

  test "a # inside a string or character literal does not start a comment":
    check selfSpawnMarker("let s = \"#\"; let me = getAppFilename()") ==
      "getAppFilename"
    check selfSpawnMarker("let s = \"a \\\"#\\\" b\"; discard getAppFilename()") ==
      "getAppFilename"
    check selfSpawnMarker("let s = r\"C:\\#\"; discard getAppFilename()") ==
      "getAppFilename"
    check selfSpawnMarker("let c = '#'; discard getAppFilename()") ==
      "getAppFilename"
    check selfSpawnMarker("let c = '\\''; discard getAppFilename() # x") ==
      "getAppFilename"
    let q = "\"\"\""
    check selfSpawnMarker("let s = " & q & "a # b" & q &
      "; discard getAppFilename()") == "getAppFilename"
    # A marker inside a string literal still counts (conservative).
    check selfSpawnMarker("let s = \"getAppFilename\"") == "getAppFilename"
    check selfSpawnMarker("let s = " & q & "\n# isMainModule\n" & q) ==
      "isMainModule"

  test "comments are removed and line breaks kept":
    check withoutComments("a # c\nb ## d\n#[ x\ny ]#c") == "a \nb \n\nc"
    check withoutComments("let n = 1'u8 # x") == "let n = 1'u8 "

  test "module-level process-global effects are found only at column 0":
    check moduleLevelSideEffect("putEnv(\"A\", \"1\")") == "putEnv"
    check moduleLevelSideEffect("  putEnv(\"A\", \"1\")") == ""
    check moduleLevelSideEffect("quitting = true") == ""

  test "program-wide pragmas":
    check globalLinkPragma("{.passL: \"-lsqlite3\".}") == "passL"
    check globalLinkPragma("  check s.contains(\"{.passL: x\")") == ""
    check globalLinkPragma("{.localPassC: \"-O0\".}") == ""
    # A define spelled in the source is a compile option of the whole group.
    check globalLinkPragma("{.define: reproDaemonParentPrewarmTest.}") ==
      "define"
    check globalLinkPragma("{.undef: release.}") == "undef"

  test "suite-scope work is found; tests, setup and declarations are not":
    # The shape that made full-suite run 41 crawl: fixture setup in the suite
    # body, outside any test, runs at every process start.
    # Fixture texts are line lists, so that no line of THIS file begins with
    # a suite or test declaration the static case scanners would count.
    let heavy = ["suite \"federated catalog diagnostics are actionable\":",
      "  loadGolden()", "  putEnv(\"REPRO_CACHE_DISABLE\", \"1\")",
      "  test \"a\":", "    check true", ""].join("\n")
    check suiteScopeWork(heavy) == "loadGolden()"
    let clean = ["suite \"clean\":", "  setup:", "    let x = 1",
      "  teardown:", "    discard", "  proc helper(): int = 1",
      "  const answer = 42", "  # a comment", "  when defined(linux):",
      "    test \"linux only\":", "      check helper() == 1",
      "  test \"b\":", "    let y = createTempDir(\"x\", \"\")",
      "    check y.len > 0", "  gatedTest \"a test-defining template\":",
      "    check true", ""].join("\n")
    check suiteScopeWork(clean) == ""
    # Module-level code after the suite is not the suite's body.
    check suiteScopeWork(["suite \"s\":", "  test \"t\":", "    discard",
      "let afterwards = 1", ""].join("\n")) == ""
    # A suite body inside a triple-quoted fixture is not this file's suite.
    let q = "\"\"\""
    check suiteScopeWork(["let src = " & q, "suite \"x\":", "  doWork()",
      q, ""].join("\n")) == ""

  test "module-level bare calls are found; declarations and string text are not":
    # t_e2e_home_profile_imports_contribution_catalog's shape: fixture setup
    # at column 0 runs at every process start.
    check moduleLevelWork(["let root = createTempDir(\"x\", \"\")",
      "createDir(root / \"payload\")", ""].join("\n")) ==
      "let root = createTempDir(\"x\", \"\")"
    check moduleLevelWork(["import std/os", "proc helper() = discard",
      "let x = 1", "when isMainModule:", "  main()", ""].join("\n")) == ""
    let q = "\"\"\""
    check moduleLevelWork(["const fixture = " & q, "console.log(1)", q,
      ""].join("\n")) == ""
    # A module-level initialiser that calls a proc runs it at start-up; an
    # object constructor does not.
    check moduleLevelWork("let marked = sharedSnpTestHierarchy(now)") ==
      "let marked = sharedSnpTestHierarchy(now)"
    check moduleLevelWork("let cfg = TrustConfig(strict: true)") == ""
    check moduleLevelWork("var n = 0") == ""

  test "compile pragma targets are repo-relative":
    check compilePragmaTargets("{.compile: \"../c/probe.c\".}",
      "libs/h/tests/t_a.nim") == @["libs/h/c/probe.c"]

  test "static case names follow suite scope by indentation":
    let text = """
suite "alpha":
  test "one":
    discard
  test "two":
    discard

test "loose":
  discard
"""
    check staticCaseNames(text) == @["alpha::one", "alpha::two", "::loose"]

  test "a triple-quoted fixture at column 0 does not end the suite":
    # The shape of the *_direct_convention and *_dep_scanner tests: a recipe
    # written at column 0 inside a test made every later test look
    # suite-less, so two files' tests in different suites seemed to clash.
    let q = "\"\"\""
    let text = ["suite \"beta\":", "  test \"one\":",
      "    writeFile(\"repro.nim\", " & q, "package p:", "  discard",
      q & ")", "  test \"two\":", "    discard", ""].join("\n")
    check staticCaseNames(text) == @["beta::one", "beta::two"]

suite "test binary grouping: case identity (runner keying)":
  const tableText = """
const reprobuildTestSpecs*: seq[TestSpec] = @[
  TestSpec(
    source: "tests/unit/t_alpha.nim",
    binary: "build/test-bin/t_alpha",
    selfInterposes: false,
    group: "t_group_tests_unit_g01",
    singleReason: ""),
  TestSpec(
    source: "tests/unit/t_beta.nim",
    binary: "build/test-bin/t_beta",
    selfInterposes: false,
    group: "t_group_tests_unit_g01",
    singleReason: ""),
  TestSpec(
    source: "tests/e2e/x/t_single.nim",
    binary: "build/test-bin/t_single",
    selfInterposes: false,
    group: "",
    singleReason: "self-spawn marker \"isMainModule\"")
]
"""
  let index = parseCaseSourceIndex(tableText)

  test "a grouped case and the same case in its single binary have one source":
    # Grouped: the binary is the group, the catalog row names the member.
    let grouped = index.caseSourceOf("t_group_tests_unit_g01", "t_beta.nim")
    # Fallback: the member compiled singly, as the compile fallback does.
    let single = index.caseSourceOf("t_beta", "t_beta.nim")
    check grouped == "tests/unit/t_beta.nim"
    check single == grouped

  test "a single binary's cases stay its own, whatever file declared them":
    check index.caseSourceOf("t_single", "helper_suite.nim") ==
      "tests/e2e/x/t_single.nim"

  test "group membership and escaped reasons are read from the table":
    check index.isGroupBinary("t_group_tests_unit_g01")
    check not index.isGroupBinary("t_single")
    check index.memberStems("t_group_tests_unit_g01") == @["t_alpha", "t_beta"]
    check index.byStem["t_single"] == "tests/e2e/x/t_single.nim"

  test "without a table a case falls back to its catalog file or binary":
    let empty = parseCaseSourceIndex("")
    check empty.caseSourceOf("t_group_x_g01", "t_member.nim") == "t_member.nim"
    check empty.caseSourceOf("t_plain", "t_plain.nim") == "t_plain"
