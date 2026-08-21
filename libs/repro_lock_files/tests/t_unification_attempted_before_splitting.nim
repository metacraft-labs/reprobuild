## NLF-DIA-6 — two lock files, overlapping ranges, ONE instance.
##
## Named-Lock-Files NLF-M8. Corpus case **NLF-DIA-6**:
##
## > Two lock files each needing `libfoo`, with **overlapping** ranges
## > (`>=1.2` and `>=1.4 <2.0`) that admit a common version. **Expect.** One
## > `libfoo` instance, at a version in the intersection. One set of actions.
##
## ## What this catches
##
## > An implementation that splits per lock file *by construction* — solving
## > each independently and never attempting reuse. That is the naive reading
## > of "two lock files" and it is wrong (§9.1): it would duplicate every
## > shared dependency in the workspace, which is the cost that makes the
## > feature not worth having.
##
## The naive implementation is not hypothetical — it is what NLF-M7 shipped,
## and correctly so for the questions NLF-M7 asked: `nlf_m7_fixture` runs one
## solve per lock file, which cannot unify because the two solves never see
## each other. §9.1 says why one solve is the right shape here: "Reprobuild's
## lock files are *declared*, so the set to unify over is known up front and
## can be one solve with reuse as a minimisation objective, rather than a
## sequence of solves whose result depends on what was solved before."
##
## ## Why the ranges are chosen the way they are
##
## `>=1.2` admits four of the five published versions and `>=1.4 <2.0` admits
## two. Two independent solves have no reason to agree, and a `#minimize` over
## distinct versions has exactly one reason to. The assertion is therefore on
## the INSTANCE COUNT and on both consumers reading the same version, not on
## which version was picked — the objective's job is to make them agree, and
## which member of the intersection they agree on is the version preference's
## business and not this case's.
##
## ## Test-double policy: NO mocks, doubles, or fakes
##
## See `nlf_m8_fixture`'s header. The `#minimize` asserted on below is read
## out of the real ASP program text the real encoder produced.

import std/[strutils, tables, unittest]

import ./nlf_m8_fixture

const
  Tool = "tool"
  App = "app"
  LibFoo = "libfoo"
  BinTool = "build/tool"
  BinApp = "build/app"
  TargetRuntime = "targetRuntime"
  Published = ["1.0.0", "1.2.0", "1.4.2", "1.9.0", "2.5.0"]

proc workspace(): M8Recipe =
  M8Recipe(
    packages: @[
      m8pkg(Tool, @["1.0.0"], @[m8dep(LibFoo, ">=1.2")]),
      m8pkg(App, @["1.0.0"], @[m8dep(LibFoo, ">=1.4 <2.0")]),
      m8pkg(LibFoo, @Published, multiVersion = mvForbidden)],
    artifacts: @[
      m8artifact(BinTool, Tool, HostToolsLockFileName),
      m8artifact(BinApp, App, TargetRuntime)])

suite "NLF-DIA-6 unification is attempted before splitting":

  setup:
    resetLockFileDeclarations()
    discard declareLockFile(TargetRuntime,
      description = "Everything we ship.")

  test "the two consumers really are under two different lock files":
    # The premise. If both landed in one lock file the case would be testing
    # ordinary constraint intersection rather than unification across a
    # boundary.
    let prop = propagationOf(workspace())
    check prop.instanceCount(LibFoo) == 2
    let governing = prop.lockFilesByPackage[LibFoo]
    check governing == @[HostToolsLockFileName, TargetRuntime]

  test "the encoder emits a unification objective for libfoo":
    # The mechanism, asserted on directly. §9.1: "Unification is therefore an
    # optimisation objective, not a precondition." An implementation that
    # unified by intersecting ranges in Nim before encoding would pass every
    # other assertion in this file and emit nothing here — and would then
    # produce an UNSAT for NLF-DIA-2, whose ranges do not intersect.
    let text = solveDiamond(workspace()).programText
    checkpoint(text)
    check "instance_version(\"" & LibFoo & "\", V)" in text
    check "#minimize { 1@-1, B, V : instance_version(B, V) }." in text

  test "the solve yields ONE instance, in the intersection":
    let solved = solveDiamond(workspace())
    let versions = solved.solvedVersionsOf(LibFoo)
    checkpoint("libfoo instances: " & $versions)
    check versions.len == 1
    # In the intersection of `>=1.2` and `>=1.4 <2.0`.
    check versions[0] in ["1.4.2", "1.9.0"]

  test "both binaries link the SAME version":
    let solved = solveDiamond(workspace())
    check solved.versionsReached(BinTool, LibFoo).len == 1
    check solved.versionsReached(BinApp, LibFoo).len == 1
    check solved.versionsReached(BinTool, LibFoo) ==
      solved.versionsReached(BinApp, LibFoo)

  test "and nothing is reported as split":
    # §9.1's "most shared dependencies collapse to one version and are built
    # once", read off the report rather than inferred.
    let solved = solveDiamond(workspace())
    for report in solved.splits:
      checkpoint(renderSplitReport(report))
    check solved.splits.len == 0
    check solved.conflicts.len == 0
