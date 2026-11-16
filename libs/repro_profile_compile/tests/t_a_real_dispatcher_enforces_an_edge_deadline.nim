## A profile edge's `timeoutSeconds` reaches the spawn, through the real
## dispatcher, and an edge past it fails instead of holding the apply.
##
## `repro_elevation`'s `t_inline_exec_deadline_and_output.nim` proves the
## spawn honours a deadline it is given. This file proves the deadline the
## profile declares is the one it is given: the profile helper records it,
## the two encodings a compiled profile crosses on its way to the apply
## (the JSON the profile binary prints, and the RBPI envelope) both carry it,
## and the production dispatcher (`mkBuildActionDispatcher`, the closure
## `repro infra apply` and `repro deploy-agent` attach) hands it to the
## broker spawn. No mocks: a real `/bin/sh` fork through the real engine.

import std/[os, strutils, tempfiles, times, unittest]

import repro_elevation
import repro_infra
import repro_profile
import repro_profile_compile
import repro_profile_intent

proc sleeperEdge(id, outputPath: string; timeoutSeconds: int): ProfileBuildAction =
  ## Sleeps far past any deadline below, then writes its output. If the
  ## output appears, the deadline did not stop it.
  ProfileBuildAction(
    id: id,
    argv: @["/bin/sh", "-c", "sleep 300; printf done > '" & outputPath & "'"],
    outputs: @[outputPath],
    commandStatsId: "shell.sleep",
    requiresElevation: true,
    cacheable: true,
    timeoutSeconds: timeoutSeconds)

proc writerEdge(id, outputPath: string; timeoutSeconds: int): ProfileBuildAction =
  ProfileBuildAction(
    id: id,
    argv: @["/bin/sh", "-c", "printf ok > '" & outputPath & "'"],
    outputs: @[outputPath],
    commandStatsId: "shell.write",
    requiresElevation: true,
    cacheable: true,
    timeoutSeconds: timeoutSeconds)

# Pin the binary cache off, as the sibling dispatcher gates do, so a host
# /etc/repro/caches.conf cannot turn a local run into a substitute attempt.
putEnv("REPRO_CACHE_DISABLE", "1")

suite "an edge's own deadline is enforced by the production dispatcher":

  test "the profile helper records timeoutSeconds and refuses a negative one":
    var actions: seq[ProfileBuildAction] = @[]
    profileInlineExecActionEdge(actions, @["/bin/true"], address = "bounded",
      requiresElevation = true, timeoutSeconds = 90)
    profileInlineExecActionEdge(actions, @["/bin/true"], address = "default",
      requiresElevation = true)
    check actions.len == 2
    check actions[0].timeoutSeconds == 90
    check actions[1].timeoutSeconds == 0
    expect ValueError:
      profileInlineExecActionEdge(actions, @["/bin/true"], address = "neg",
        timeoutSeconds = -1)

  test "timeoutSeconds survives the JSON and RBPI encodings of a compiled profile":
    var intent = ProfileIntent(name: "deadline-roundtrip")
    intent.buildActions = @[
      writerEdge("bounded", "/tmp/never-a", 90),
      writerEdge("default", "/tmp/never-b", 0)]
    let viaJson = parseProfileIntentJson(emitProfileIntentJson(intent))
    check viaJson.buildActions.len == 2
    check viaJson.buildActions[0].timeoutSeconds == 90
    check viaJson.buildActions[1].timeoutSeconds == 0
    let viaRbpi = decodeRbpi(encodeRbpi(viaJson))
    check viaRbpi.buildActions.len == 2
    check viaRbpi.buildActions[0].timeoutSeconds == 90
    check viaRbpi.buildActions[1].timeoutSeconds == 0
    # An edge without a deadline encodes exactly as before: no key at all.
    check "timeoutSeconds" notin emitProfileIntentJson(ProfileIntent(
      name: "no-deadline", buildActions: @[writerEdge("d", "/tmp/x", 0)]))

  test "an edge past its own deadline fails within it, and its sibling still runs":
    when defined(linux) or defined(macosx):
      let tmpRoot = createTempDir("deadline-real-disp-", "")
      defer:
        try: removeDir(tmpRoot)
        except CatchableError: discard
      let cacheRoot = tmpRoot / "build-cache"
      let outputDir = tmpRoot / "outputs"
      createDir(cacheRoot)
      createDir(outputDir)

      let ctx = FixtureContext(filePrefix: tmpRoot)
      let dispatcher = mkBuildActionDispatcher(cacheRoot, ctx)
      let t0 = epochTime()
      let outcomes = dispatcher(@[
        sleeperEdge("hangs", outputDir / "hangs.out", timeoutSeconds = 2),
        writerEdge("quick", outputDir / "quick.out", timeoutSeconds = 30)], nil)
      let elapsed = epochTime() - t0

      check outcomes.len == 2
      # Bounded by the 2-second deadline, nowhere near the 300-second sleep.
      check elapsed < 60.0
      check not fileExists(outputDir / "hangs.out")
      for o in outcomes:
        if o.id == "hangs":
          check not o.ok
          check "deadline of 2 s" in o.diagnostic
        else:
          # POLARITY CONTROL in the same dispatch: a bounded edge that
          # finishes in time is unaffected.
          check o.ok
      check fileExists(outputDir / "quick.out")
