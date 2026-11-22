## NPC-M14 verification `test_npc_m14_nim_version_terms_evaluate_as_nim_does`
## (A3; NPC-AREQ7).
##
## Over a table of conditions and Nim versions, the reader's reading of each
## condition, evaluated by ``decide`` at each Nim version, equals Nim's own
## answer. Nim's answers are the table below, produced on 2026-11-22 by
## `nim e` of a script holding the same expressions (one `echo` each), run
## with `-d:NimMajor=<a> -d:NimMinor=<b> -d:NimPatch=<c>` for each version
## (the three are `intdefine`s in `system/compilation.nim`, and `NimVersion`
## is computed from them in `system.nim`):
##
## * Nim 2.2.4 (nixpkgs `nim`, tag `v2.2.4`), for all four versions: the
##   table;
## * Nim 1.6.20 (nixpkgs `nim1`), for all four versions: identical answers;
## * Nim 1.6.20 and Nim 2.2.4 without the defines (their own versions):
##   identical to the 1.6.20 and 2.2.4 rows.
##
## 1.10.0 is not a Nim release; it is the version at which `NimVersion`
## compared as a string disagrees with the version order, which is what the
## row is for.
##
## Falsifying mutation (recorded in the plan): comparing `NimVersion` as a
## version instead of a string answers true for `NimVersion >= "1.6.0"` at
## 1.10.0, and fails the test.

import std/[options, strutils, unittest]

import repro_nimble_reader

const
  Versions = ["1.6.20", "1.10.0", "2.0.0", "2.2.4"]
  ## (condition, Nim's answer at each of ``Versions``), from `nim e`.
  NimAnswers = [
    ("NimVersion >= \"1.6.0\"", [true, false, true, true]),
    ("(NimMajor, NimMinor) >= (1, 6)", [true, true, true, true]),
    ("NimMinor < 10", [true, false, true, true]),
    ("2 <= NimMajor", [false, false, true, true]),
    ("(NimMajor, NimMinor, NimPatch) == (2, 2, 4)", [false, false, false, true]),
    ("NimPatch != 4", [true, true, true, false]),
    ("NimMajor > 1", [false, false, true, true]),
    ("(NimMajor, NimMinor) < (2, 0)", [true, true, false, false]),
    ("\"2.0\" > NimVersion", [true, true, false, false]),
    ("(NimMajor, NimMinor, NimPatch) <= (1, 10, 0)", [true, true, false, false])]

proc readOne(cond: string): Condition =
  let f = readNimbleSource("when " & cond & ":\n  requires \"x\"\n",
    "terms.nimble")
  doAssert f.readerClass == rcClosedWhen, cond & ": " & $f.readerClass
  doAssert f.requires.len == 1, cond
  f.requires[0].condition

suite "NPC-M14: Nim-version terms evaluate as Nim evaluates them":
  test "every condition of the table is in the closed set":
    for (cond, _) in NimAnswers:
      checkpoint cond
      let c = readOne(cond)
      check c.kind == ckNimVersion
      check mentionsNimVersion(c)
      # Without a Nim version it is undecided, never true or false.
      check decide(c, "linux", "amd64", "linux", "amd64") == tUnknown

  test "each answer equals Nim's":
    for (cond, answers) in NimAnswers:
      let c = readOne(cond)
      for i, v in Versions:
        checkpoint cond & " at " & v
        var nv: NimVersionValue
        require parseNimVersionValue(v, nv)
        check evaluate(c, "linux", "amd64", "linux", "amd64", nv) == answers[i]
        check decide(c, "linux", "amd64", "linux", "amd64", some(nv)) ==
          (if answers[i]: tTrue else: tFalse)

  test "the literal on the left is normalised to the right":
    check $readOne("2 <= NimMajor") == "NimMajor >= 2"
    check $readOne("\"2.0\" > NimVersion") == "NimVersion < \"2.0\""
    check $readOne("(NimMajor, NimMinor) >= (1, 6)") ==
      "(NimMajor, NimMinor) >= (1, 6)"

  test "connectives over a Nim-version term follow Kleene's logic":
    let c = readOne("defined(windows) and NimMajor >= 2")
    check decide(c, "linux", "amd64", "linux", "amd64") == tFalse
    check decide(c, "windows", "amd64", "windows", "amd64") == tUnknown
    let o = readOne("defined(linux) or NimMajor >= 2")
    check decide(o, "linux", "amd64", "linux", "amd64") == tTrue
    check decide(o, "macosx", "arm64", "macosx", "arm64") == tUnknown
