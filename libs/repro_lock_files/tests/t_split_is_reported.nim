## NLF-DIA-7 — a split is reported, not silent.
##
## Named-Lock-Files NLF-M8. Corpus case **NLF-DIA-7**:
##
## > Two lock files with genuinely irreconcilable constraints on `libfoo`,
## > which declares `multiVersion allowed`. Build succeeds with two instances.
## > **Expect.** `repro graph` (or the build report) states that `libfoo` was
## > **split**, naming both versions and the constraints that forced it.
##
## ## What this catches
##
## > Silent duplication. A build that quietly produces two copies of a library
## > is how a closure doubles without anyone noticing, and it is the
## > observability half of §8's argument that trimming is not needed at v1 —
## > that argument depends on explosion being *visible*.
##
## ## Why `multiVersion allowed` is part of the input
##
## Because a split that ERRORS is trivially visible — the error is the report.
## The case that matters is the one that succeeds. `allowed` withdraws the
## objection to co-linking and must not withdraw the reporting with it;
## conflating the two is the exact defect, and it is easy to write, because
## "no error" and "nothing to say" look the same at a call site that returns a
## single seq.
##
## Note this shape ALSO succeeds where NLF-DIA-3's does: the two are the same
## rule seen from two sides. DIA-3 asserts no conflict; this one asserts a
## report, over a workspace whose split spans two lock files rather than one.
##
## ## Test-double policy: NO mocks, doubles, or fakes
##
## See `nlf_m8_fixture`'s header.

import std/[strutils, unittest]

import ./nlf_m8_fixture

const
  Tool = "tool"
  App = "app"
  LibFoo = "libfoo"
  BinTool = "build/tool"
  BinApp = "build/app"
  TargetRuntime = "targetRuntime"
  ToolRange = ">=2.0 <3.0"
  AppRange = ">=1.4 <2.0"
  Published = ["1.0.0", "1.4.2", "1.9.0", "2.0.0", "2.5.0"]

proc workspace(policy = mvAllowed): M8Recipe =
  M8Recipe(
    packages: @[
      m8pkg(Tool, @["1.0.0"], @[m8dep(LibFoo, ToolRange)]),
      m8pkg(App, @["1.0.0"], @[m8dep(LibFoo, AppRange)]),
      m8pkg(LibFoo, @Published, multiVersion = policy)],
    artifacts: @[
      m8artifact(BinTool, Tool, HostToolsLockFileName),
      m8artifact(BinApp, App, TargetRuntime)])

suite "NLF-DIA-7 a split is reported, not silent":

  setup:
    resetLockFileDeclarations()
    discard declareLockFile(TargetRuntime,
      description = "Everything we ship.")

  test "the build succeeds with two instances":
    let solved = solveDiamond(workspace())
    check solved.solvedVersionsOf(LibFoo).len == 2
    check solved.conflicts.len == 0

  test "the split is reported":
    let solved = solveDiamond(workspace())
    check solved.splits.len == 1
    check solved.splitFor(LibFoo).library == LibFoo

  test "the report names BOTH versions":
    let solved = solveDiamond(workspace())
    let report = solved.splitFor(LibFoo)
    let rendered = renderSplitReport(report)
    checkpoint(rendered)
    let versions = solved.solvedVersionsOf(LibFoo)
    check report.versions == versions
    for v in versions:
      check (LibFoo & " " & v) in rendered

  test "the report names the constraints that forced it":
    # "naming both versions **and the constraints that forced it**". A report
    # that named only the versions would say a split happened and leave the
    # reader to find out why, which is the same half-answer §9.4 rejects for
    # the error.
    let rendered = renderSplitReport(solveDiamond(workspace()).splitFor(LibFoo))
    checkpoint(rendered)
    check ToolRange in rendered
    check AppRange in rendered

  test "the report names the lock files involved":
    let rendered = renderSplitReport(solveDiamond(workspace()).splitFor(LibFoo))
    checkpoint(rendered)
    check HostToolsLockFileName in rendered
    check TargetRuntime in rendered

  test "reporting is independent of whether anybody objected":
    # `multiVersion` decides whether the split is an ERROR. It does not decide
    # whether the split HAPPENED, and an implementation that reported only
    # what it also refused would go silent exactly where the closure is
    # doubling without complaint.
    #
    # Neither of these two workspaces errors — each binary links one version,
    # which is NLF-DIA-1's rule — and that is the point: the report must
    # survive `forbidden` as well as `allowed`, because in NEITHER case is
    # there an error carrying the news.
    let allowed = solveDiamond(workspace(mvAllowed))
    let forbidden = solveDiamond(workspace(mvForbidden))
    check allowed.conflicts.len == 0
    check forbidden.conflicts.len == 0
    check allowed.splits.len == 1
    check forbidden.splits.len == 1
    check allowed.splitFor(LibFoo).versions ==
      forbidden.splitFor(LibFoo).versions
    check renderSplitReport(allowed.splitFor(LibFoo)) ==
      renderSplitReport(forbidden.splitFor(LibFoo))
