## A strategy with no candidate universe to rank is REPORTED, not accepted
## quietly.
##
## Named-Lock-Files NLF-M6, **third folded criterion from NLF-M5**:
##
## > **A strategy that cannot take effect must say so.** M5 found `--strategy`
## > accepted, printed in the run summary, and silently inert on every project
## > in this workspace, because none configures a registry. The fix landed; the
## > *class* has not been closed. A test must assert that a strategy with no
## > candidate universe to narrow is reported, not accepted quietly.
##
## ## The difference between the instance and the class
##
## NLF-M5's INSTANCE was that the strategy was applied only to universes that
## came off the wire, so a project with no registry got it silently ignored.
## That was fixed by applying it to declared universes too.
##
## The CLASS is wider and survives that fix: a strategy is a rule for RANKING
## candidates, and there is nothing to rank when every unpinned package offers
## at most one version — whatever the reason, and whether or not a registry is
## configured. A user who asked for `lowest` and got `default`'s answer has
## been told nothing either way. So the report is derived from the CONSULTED
## universe after the fetch, not from whether an endpoint was named.
##
## ## Both directions, because a report that always fires says nothing
##
## Each test below is paired with its opposite:
##
##   * no registry AND single declared versions → reported;
##   * no registry but MULTIPLE declared versions → NOT reported, because the
##     strategy really does decide something (this is the M5 instance, and its
##     fix must not be undone by the new report);
##   * a registry publishing one version → reported;
##   * a registry publishing several → not reported;
##   * `default` → never reported, because it is not a narrowing rule and a
##     warning on every ordinary invocation is noise.
##
## ## Test-double policy: NO mocks, doubles, or fakes
##
## See `nlf_m6_fixture`'s header, which states the policy in full.

import std/[os, strutils, tables, unittest]

import repro_lock_gen
import repro_solver

import ./nlf_m6_fixture

const
  App = "app"
  LibFoo = "libfoo"

proc oneVersionEach(): seq[PackageDecl] =
  @[
    newPackage(App, @["1.0.0"], @[newDependency(LibFoo, ">=1.2")]),
    newPackage(LibFoo, @["1.2.0"])]

proc severalVersions(): seq[PackageDecl] =
  @[
    newPackage(App, @["1.0.0"], @[newDependency(LibFoo, ">=1.2")]),
    newPackage(LibFoo, @["1.2.0", "1.4.0", "1.9.0"])]

proc hermeticRequest(packages: seq[PackageDecl]; strategy: LockStrategy;
                     workDir: string): LockGenerationRequest =
  ## No `endpoints`, so no `netFetch` edge is emitted at all — the shape every
  ## project in this workspace has today, and the one NLF-M5 got wrong.
  LockGenerationRequest(
    variants: @[], packages: packages, inputsText: "nlf-m6 no-registry",
    platform: currentPlatformId(), strategy: strategy, endpoints: @[],
    workDir: workDir, entryPoint: lgeLockSolve)

suite "with no registry, the report tracks the DECLARED universe":

  test "single declared versions: reported":
    let reg = startRegistry("report-hermetic-one")
    try:
      let r = runLockSolve(hermeticRequest(oneVersionEach(), lsLowest,
        reg.scratch / "hermetic-one"), "")
      check r.strategyReport.len > 0
      check r.strategyReport.contains("lowest")
      check r.strategyReport.contains("no candidate universe")
      # And it says WHY, since "no registry is configured" is the actionable
      # half for the case NLF-M5 actually hit.
      check r.strategyReport.contains("no registry is configured")
    finally:
      reg.shutdown()

  test "several declared versions: NOT reported, and the strategy really acts":
    # The M5 instance's fix, guarded. If the strategy stopped applying to
    # declared universes, this would start being reported — and the answer
    # would stop being the minimum.
    let reg = startRegistry("report-hermetic-many")
    try:
      let lo = runLockSolve(hermeticRequest(severalVersions(), lsLowest,
        reg.scratch / "hermetic-lo"), "")
      let hi = runLockSolve(hermeticRequest(severalVersions(), lsHighest,
        reg.scratch / "hermetic-hi"), "")
      check lo.strategyReport.len == 0
      check hi.strategyReport.len == 0
      check lo.resolved()[LibFoo] == "1.2.0"
      check hi.resolved()[LibFoo] == "1.9.0"
    finally:
      reg.shutdown()

suite "with a registry, the report tracks the CONSULTED universe":

  test "a registry publishing one version: reported":
    let reg = startRegistry("report-registry-one")
    try:
      reg.server.publish(App, ["1.0.0"])
      reg.server.publish(LibFoo, ["1.2.0"])
      let r = reg.generate(oneVersionEach(), lsLowest)
      check r.strategyReport.len > 0
      # A registry IS configured here, so the endpoint clause must not fire —
      # a diagnostic that named the wrong cause would send a reader to fix
      # something that is not broken.
      check not r.strategyReport.contains("no registry is configured")
    finally:
      reg.shutdown()

  test "a registry publishing several: not reported":
    let reg = startRegistry("report-registry-many")
    try:
      reg.server.publish(App, ["1.0.0"])
      reg.server.publish(LibFoo, ["1.2.0", "1.4.0", "1.9.0"])
      let r = reg.generate(oneVersionEach(), lsLowest)
      check r.strategyReport.len == 0
      check r.resolved()[LibFoo] == "1.2.0"
    finally:
      reg.shutdown()

  test "the report is about the CONSULTED universe, not the declared one":
    # The declarations name one version; the registry publishes three. A
    # report derived from the request rather than from what was fetched would
    # fire here, which is the same gap-between-the-two the M5 defect lived in.
    let reg = startRegistry("report-consulted")
    try:
      reg.server.publish(App, ["1.0.0"])
      reg.server.publish(LibFoo, ["1.2.0", "1.4.0"])
      let declaredOne = reg.generate(oneVersionEach(), lsHighest)
      check declaredOne.strategyReport.len == 0
      check declaredOne.resolved()[LibFoo] == "1.4.0"
    finally:
      reg.shutdown()

suite "default is never reported":

  test "the ordinary invocation stays quiet":
    let reg = startRegistry("report-default")
    try:
      let r = runLockSolve(hermeticRequest(oneVersionEach(), lsDefault,
        reg.scratch / "default"), "")
      check r.strategyReport.len == 0
    finally:
      reg.shutdown()

  test "every non-default strategy is subject to the report":
    # Enumerated from the enum rather than listed, so a strategy added later
    # cannot quietly opt out of the criterion.
    let reg = startRegistry("report-all")
    try:
      for strategy in LockStrategy:
        let r = runLockSolve(hermeticRequest(oneVersionEach(), strategy,
          reg.scratch / ("all-" & $strategy)), "")
        if strategy == lsDefault:
          check r.strategyReport.len == 0
        else:
          check r.strategyReport.len > 0
    finally:
      reg.shutdown()
