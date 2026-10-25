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

suite "test binary grouping: source text facts":
  test "self-spawn markers":
    check selfSpawnMarker("let me = getAppFilename()") == "getAppFilename"
    check selfSpawnMarker("when isMainModule:\n  main()") == "isMainModule"
    check selfSpawnMarker("import std/unittest") == ""

  test "module-level process-global effects are found only at column 0":
    check moduleLevelSideEffect("putEnv(\"A\", \"1\")") == "putEnv"
    check moduleLevelSideEffect("  putEnv(\"A\", \"1\")") == ""
    check moduleLevelSideEffect("quitting = true") == ""

  test "program-wide pragmas":
    check globalLinkPragma("{.passL: \"-lsqlite3\".}") == "passL"
    check globalLinkPragma("  check s.contains(\"{.passL: x\")") == ""
    check globalLinkPragma("{.localPassC: \"-O0\".}") == ""

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
