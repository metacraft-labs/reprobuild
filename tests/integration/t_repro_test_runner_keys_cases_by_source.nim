## t_repro_test_runner_keys_cases_by_source -- Test-Binary-Grouping M2.
##
## Up to fifty test sources are compiled into one ``t_group_*`` binary, and a
## group that fails to compile falls back to its members' own binaries. A case
## must keep ONE identity across all of that: the runner keys its result file,
## its console line and its report entry on the case's SOURCE FILE, and keeps
## the binary only as an attribute (reprobuild-specs
## ``spec/Test-Binary-Grouping.md``, "What does not change").
##
## What is asserted, against the real runner (``build/bin/repro_test_runner``)
## over real binaries compiled from two real ``std/unittest`` member modules:
##
## 1. Every case of the group binary reports ``source`` = its member's
##    repo-relative path (resolved through a ``repro_tests.nim`` in the
##    runner's working directory, the table the build graph is made from),
##    ``binary_stem`` = the group, and a result file named after the MEMBER.
## 2. The same cases run from a member's own single binary (the fallback) carry
##    the same ``source``, ``qualified_name`` and result-file name.
## 3. ``--filter <member stem>`` selects exactly that member's cases out of the
##    group binary, although the binary's own stem does not match.
## 4. A ``suite::test`` name declared by two members cannot be addressed by
##    ``--run``; both cases are reported ERROR with the reason, never run as
##    whichever one the binary picks.
##
## Mocking: none. The fixtures are compiled by the real compiler in the test
## body, as the other ``t_repro_test_runner_*`` gates do: they are synthetic
## protocol binaries the runner is pointed at, not graph artefacts of this
## repository.

import std/[json, os, osproc, strutils, tempfiles, unittest]
import repro_test_support/reasoned_skip

proc findRepoRoot(): string =
  var dir = currentSourcePath().parentDir
  while dir.len > 0:
    if fileExists(dir / "repro.nim") and fileExists(dir / "repro_tests.nim"):
      return dir
    let parent = dir.parentDir
    if parent == dir: break
    dir = parent
  raise newException(IOError, "cannot locate the repo root")

const
  GroupStem = "t_group_tests_fx_g01"
  MemberA = "t_member_alpha"
  MemberB = "t_member_beta"

  # Spelled as line lists so that no line of THIS file begins with a suite or
  # test declaration: the static case scanners would count the fixtures'
  # cases as this file's own.
  MemberASource = ["import std/unittest",
    "suite \"alpha\":",
    "  test \"adds\":", "    check 1 + 1 == 2",
    "  test \"shared name\":", "    check true", ""].join("\n")
  MemberBSource = ["import std/unittest",
    "suite \"beta\":",
    "  test \"subtracts\":", "    check 3 - 1 == 2",
    "suite \"alpha\":",
    "  test \"shared name\":", "    check true", ""].join("\n")

proc tableRow(stem, group: string): string =
  "  TestSpec(\n" &
  "    source: \"tests/fx/" & stem & ".nim\",\n" &
  "    binary: \"build/test-bin/" & stem & "\",\n" &
  "    defines: @[],\n    requiresReproBinary: false,\n" &
  "    extraPassC: @[],\n    extraPassL: @[],\n    targetOs: soAny,\n" &
  "    selfInterposes: false,\n" &
  "    group: \"" & group & "\",\n    singleReason: \"\")"

proc compile(root, source, binary: string): bool =
  let cmd = "nim c --threads:on --hints:off --warnings:off " &
    "--nimcache:" & quoteShell(root / "nimcache" / binary.extractFilename) &
    " --out:" & quoteShell(binary) & " " & quoteShell(source)
  execCmd(cmd) == 0

proc runRunner(root, binDir, tag: string; extra = ""): JsonNode =
  let runner = findRepoRoot() / "build" / "bin" /
    addFileExt("repro_test_runner", ExeExt)
  let summary = root / (tag & ".json")
  let cmd = quoteShell(runner) & " --no-build --threads=1 --quiet" &
    " --bin-dir=" & quoteShell(binDir) &
    " --summary-json=" & quoteShell(summary) &
    " --results-dir=" & quoteShell(root / ("results-" & tag)) & extra
  let (output, _) = execCmdEx(cmd, workingDir = root)
  checkpoint(tag & ": " & output)
  if fileExists(summary): parseJson(readFile(summary)) else: newJNull()

proc entries(doc: JsonNode; qualified: string): seq[JsonNode] =
  if doc.kind == JObject:
    for e in doc["tests"]:
      if e{"qualified_name"}.getStr() == qualified:
        result.add e

suite "the runner keys a case on its source file":
  let runner = findRepoRoot() / "build" / "bin" /
    addFileExt("repro_test_runner", ExeExt)
  let haveRunner = fileExists(runner)
  if not haveRunner:
    test "the runner is built":
      skip("the suite runner is not built at " & runner &
        "; this case runs it (`just build`)")
  else:
    let root = createTempDir("repro-runner-source-keys-", "")
    let fx = root / "tests" / "fx"
    createDir(fx)
    writeFile(fx / (MemberA & ".nim"), MemberASource)
    writeFile(fx / (MemberB & ".nim"), MemberBSource)
    # The group module, in the shape ``groupModuleText`` writes.
    let groupDir = root / "build" / "test-groups"
    createDir(groupDir)
    writeFile(groupDir / (GroupStem & ".nim"),
      "import \"../../tests/fx/" & MemberA & "\"\n" &
      "import \"../../tests/fx/" & MemberB & "\"\n")
    writeFile(root / "repro_tests.nim",
      "const reprobuildTestSpecs*: seq[TestSpec] = @[\n" &
      tableRow(MemberA, GroupStem) & ",\n" & tableRow(MemberB, GroupStem) &
      "\n]\n")
    let groupBin = root / "group-bin"
    let singleBin = root / "single-bin"
    createDir(groupBin)
    createDir(singleBin)
    let built =
      compile(root, groupDir / (GroupStem & ".nim"),
        groupBin / addFileExt(GroupStem, ExeExt)) and
      compile(root, fx / (MemberA & ".nim"),
        singleBin / addFileExt(MemberA, ExeExt))
    let grouped = if built: runRunner(root, groupBin, "grouped") else: newJNull()
    let single = if built: runRunner(root, singleBin, "single") else: newJNull()
    let filtered =
      if built: runRunner(root, groupBin, "filtered", " --filter=" & MemberB)
      else: newJNull()

    test "fixtures compiled and every run wrote a summary":
      check built
      check grouped.kind == JObject
      check single.kind == JObject
      check filtered.kind == JObject

    test "a group binary's cases are attributed to their member sources":
      let adds = grouped.entries("alpha::adds")
      let subtracts = grouped.entries("beta::subtracts")
      check adds.len == 1
      check subtracts.len == 1
      if adds.len == 1 and subtracts.len == 1:
        check adds[0]{"source"}.getStr() == "tests/fx/" & MemberA & ".nim"
        check subtracts[0]{"source"}.getStr() == "tests/fx/" & MemberB & ".nim"
        check adds[0]{"binary_stem"}.getStr() == GroupStem
        check adds[0]{"status"}.getStr() == "PASS"
        check adds[0]{"result_file"}.getStr().extractFilename ==
          MemberA & "__alpha__adds.json"

    test "the same case run from its own binary has the same identity":
      let g = grouped.entries("alpha::adds")
      let s = single.entries("alpha::adds")
      check g.len == 1
      check s.len == 1
      if g.len == 1 and s.len == 1:
        check s[0]{"source"}.getStr() == g[0]{"source"}.getStr()
        check s[0]{"result_file"}.getStr().extractFilename ==
          g[0]{"result_file"}.getStr().extractFilename
        check s[0]{"binary_stem"}.getStr() == MemberA

    test "a member filter selects that member's cases out of the group":
      var sources: seq[string]
      if filtered.kind == JObject:
        for e in filtered["tests"]:
          sources.add e{"source"}.getStr()
      check sources.len > 0
      for s in sources:
        check s == "tests/fx/" & MemberB & ".nim"

    test "a name two members declare is refused, not run ambiguously":
      let shared = grouped.entries("alpha::shared name")
      check shared.len == 2
      for e in shared:
        check e{"status"}.getStr() == "ERROR"
        check "cannot select one of them" in e{"harness_error"}.getStr()

    removeDir(root)
