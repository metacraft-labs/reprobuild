## The REAL build-action dispatcher carries a declared restart through to
## the apply — no mock anywhere on the path.
##
## Its companion, `repro_infra`'s
## `t_an_apply_reports_reboot_required_from_a_build_action.nim`, drives the
## fold with a scripted dispatcher because that is the only way to put both
## polarities through one apply. That leaves exactly one joint unproved: the
## PRODUCTION dispatcher — `mkBuildActionDispatcher`, the closure
## `attachBuildActionDispatcher` wires into `repro infra apply` — has to
## actually set `BuildActionApplyOutcome.rebootRequired` from the action's
## declaration. If it did not, every case in that file would keep passing on
## hand-built outcomes while no real apply ever raised the flag.
##
## So this file forks real processes through the real engine and asserts on
## what the real closure returns.
##
## The freshness condition is asserted rather than assumed. A declared
## restart is carried by an edge that RAN, and deliberately not by a cache
## hit: the effect of a cache-hit edge was applied by an earlier apply,
## which already told the operator, and repeating the notice on every
## converged apply afterwards is how a notice stops being read. The second
## case runs the SAME edge twice in the same cache root and requires the
## second run to be a hit and to be quiet — which also happens to be the
## strongest available check that the flag is not simply hard-wired on.
##
## No mocks: a real temp tree, a real `/bin/sh` fork, the real engine, the
## real dispatcher closure.

import std/[os, tempfiles, unittest]

import repro_elevation
import repro_infra
import repro_profile
import repro_profile_compile

proc shellEdge(id, outputPath, payload: string;
               rebootRequired: bool): ProfileBuildAction =
  ## An edge that writes `payload` to `outputPath` via `/bin/sh -c`.
  ## `requiresElevation = true` routes it through the broker's in-process
  ## fast path, which is the arm that spawns without a monitor CLI wired.
  let script = "printf %s '" & payload & "' > '" & outputPath & "'"
  ProfileBuildAction(
    id: id,
    argv: @["/bin/sh", "-c", script],
    outputs: @[outputPath],
    commandStatsId: "shell.write",
    requiresElevation: true,
    cacheable: true,
    rebootRequired: rebootRequired)

suite "the production dispatcher carries a declared restart":

  test "an edge declaring a restart comes back with rebootRequired set":
    when defined(linux) or defined(macosx):
      let tmpRoot = createTempDir("reboot-real-disp-", "")
      defer:
        try: removeDir(tmpRoot)
        except CatchableError: discard
      let cacheRoot = tmpRoot / "build-cache"
      let outputDir = tmpRoot / "outputs"
      createDir(cacheRoot)
      createDir(outputDir)

      let ctx = FixtureContext(filePrefix: tmpRoot)
      let dispatcher = mkBuildActionDispatcher(cacheRoot, ctx)
      let outcomes = dispatcher(@[
        shellEdge("needs-restart", outputDir / "a.out", "a",
                  rebootRequired = true),
        shellEdge("no-restart", outputDir / "b.out", "b",
                  rebootRequired = false)], nil)

      check outcomes.len == 2
      # Both really ran: the assertion below is about edges that did work,
      # not about a dispatcher that returned early.
      check fileExists(outputDir / "a.out")
      check fileExists(outputDir / "b.out")
      for o in outcomes:
        check o.ok
        check not o.cacheHit
        if o.id == "needs-restart":
          check o.rebootRequired
        else:
          # POLARITY CONTROL, in the same dispatch as the positive case.
          check not o.rebootRequired

  test "a cache HIT of the same edge does NOT re-raise the restart":
    when defined(linux) or defined(macosx):
      let tmpRoot = createTempDir("reboot-real-disp-hit-", "")
      defer:
        try: removeDir(tmpRoot)
        except CatchableError: discard
      let cacheRoot = tmpRoot / "build-cache"
      let outputDir = tmpRoot / "outputs"
      createDir(cacheRoot)
      createDir(outputDir)

      let ctx = FixtureContext(filePrefix: tmpRoot)
      let dispatcher = mkBuildActionDispatcher(cacheRoot, ctx)
      let edge = shellEdge("needs-restart-once", outputDir / "once.out",
                           "once", rebootRequired = true)

      let first = dispatcher(@[edge], nil)
      check first.len == 1
      check first[0].ok
      check not first[0].cacheHit
      check first[0].rebootRequired

      let second = dispatcher(@[edge], nil)
      check second.len == 1
      check second[0].ok
      # The precondition of the claim. If the second run were not a hit,
      # the assertion under it would be about a fresh run and would prove
      # the opposite of what it says.
      check second[0].cacheHit
      check not second[0].rebootRequired
