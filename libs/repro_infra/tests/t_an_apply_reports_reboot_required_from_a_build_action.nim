## `repro infra apply` can report "a reboot is required" on this platform.
##
## The state this pins, and why it needed pinning
## ----------------------------------------------
## `runInfraApply` prints
##
##     NOTE: a reboot is required to finish one or more changes;
##     Reprobuild does not auto-reboot.
##
## when `ApplyResult.restartNeeded` is set. Before the seam this file
## exercises, that flag had:
##
##   * exactly ONE write site (`apply.nim`'s fold over `outcome.applyLog`),
##   * fed by exactly ONE record type (`ApplyLogRecord.restartNeeded`),
##   * fed by exactly FOUR driver-level originators — the Windows
##     optional-feature, capability, hostname and VS-installer drivers —
##   * every one of which sits behind `when defined(windows)`, whose
##     `else` arm raises "not implemented on this platform".
##
## On Linux the flag was therefore provably always `false`. The notice was
## not conservative, and it was not merely untested: it was a rule with no
## constructible input, which is the shape that reads like a live check and
## is not one. The build-action half could not contribute either — not
## because no dispatcher chose to, but because `BuildActionApplyOutcome`
## had no such field, `dispatchBuildActions` had no such fold, and the
## build-action audit writer wrote a literal `false` into every record.
##
## So the input is constructed rather than the rule deleted: a profile
## action edge may DECLARE that its effect needs a restart, an edge that
## actually RAN folds that into `ApplyResult.restartNeeded`, and the audit
## log records the same thing the summary printed.
##
## What this file does NOT establish, said plainly so the row is not read
## as wider than it is: nothing routes an apply on an attested root through
## a generation stager. That second half of the defect needs an attested
## image that can be installed, and the layout an attested image needs is
## still refused at plan time. This file closes the seam; it does not close
## the routing.
##
## Mock justification (repo policy: every mock is justified where it is
## used). The dispatcher here is a scripted closure rather than the real
## `mkBuildActionDispatcher`. That is deliberate and narrow: the unit under
## test is the FOLD from a per-edge outcome into `ApplyResult` and into the
## audit log, and a scripted dispatcher is the only way to drive both
## polarities — an edge that owes a reboot and one that does not — through
## the same apply in one run. Everything else is real: a real state
## directory on a real filesystem, the real `runInfraApply`, the real
## audit-log encoder and the real reader. The REAL dispatcher's end of the
## same wire is covered in `repro_profile_compile`'s tests, where a real
## process is forked by the real engine.

import std/[os, strutils, tempfiles, unittest]

import repro_elevation
import repro_infra
import repro_profile

const
  RebootingEdgeId = "edge-that-needs-a-restart"
  QuietEdgeId = "edge-that-does-not"
  EmptyProfileText = ""

proc mkApplyOptions(stateDir: string): ApplyOptions =
  result.stateDir = stateDir
  result.hostIdentity = "reboot-seam-test-host"
  result.reproExe = "/usr/bin/false"   # never spawned by these cases
  result.planId = ""
  result.elevationMode = emNoElevate
  result.noPreview = true

proc mkScriptedDispatcher(): BuildActionDispatcher =
  ## Return one outcome per action, carrying through the action's OWN
  ## declaration. This mirrors what the real dispatcher does for a freshly
  ## run edge, and — importantly — it does not invent the flag: an action
  ## that did not declare a reboot cannot get one from here, so a fold
  ## that sets the flag unconditionally is visible as a failure of the
  ## polarity case rather than as a pass everywhere.
  result = proc(actions: seq[ProfileBuildAction];
                onProgress: ApplyProgressHook):
      seq[BuildActionApplyOutcome] {.gcsafe.} =
    {.cast(gcsafe).}:
      for a in actions:
        result.add(BuildActionApplyOutcome(
          id: a.id,
          address: a.id,
          ok: true,
          cacheHit: false,
          rebootRequired: a.rebootRequired,
          fingerprintHex: "00"))

proc applyWith(stateDir: string;
               actions: seq[ProfileBuildAction]): ApplyResult =
  var opts = mkApplyOptions(stateDir)
  opts.buildActions = actions
  opts.buildActionDispatcher = mkScriptedDispatcher()
  runInfraApply(EmptyProfileText, opts)

proc rebootingEdge(): ProfileBuildAction =
  ProfileBuildAction(id: RebootingEdgeId, argv: @["/bin/true"],
                     cacheable: true, rebootRequired: true)

proc quietEdge(): ProfileBuildAction =
  ProfileBuildAction(id: QuietEdgeId, argv: @["/bin/true"],
                     cacheable: true, rebootRequired: false)

suite "an apply can report reboot-required without a Windows driver":

  test "an edge that declares a restart sets ApplyResult.restartNeeded":
    let tmp = createTempDir("reboot-seam-positive-", "")
    defer:
      try: removeDir(tmp)
      except CatchableError: discard
    let res = applyWith(tmp, @[rebootingEdge()])
    check res.buildActionResults.len == 1
    check res.restartNeeded

  test "an apply with no such edge does NOT set it":
    # POLARITY CONTROL. A fold that raises the flag for every edge, or a
    # field hard-wired to `true`, satisfies the case above and tells the
    # operator to reboot after every apply forever.
    let tmp = createTempDir("reboot-seam-negative-", "")
    defer:
      try: removeDir(tmp)
      except CatchableError: discard
    let res = applyWith(tmp, @[quietEdge()])
    check res.buildActionResults.len == 1
    check not res.restartNeeded

  test "the audit log records WHICH edge owed the reboot":
    # The writer used to put a literal `false` in every build-action
    # record, so the on-disk log contradicted the summary the same apply
    # printed and no reader could attribute the reboot to an edge. Both
    # edges go through ONE apply so the assertion is a discrimination and
    # not two separate constants.
    let tmp = createTempDir("reboot-seam-audit-", "")
    defer:
      try: removeDir(tmp)
      except CatchableError: discard
    let res = applyWith(tmp, @[rebootingEdge(), quietEdge()])
    check res.restartNeeded
    check res.auditLogPath.len > 0
    check fileExists(res.auditLogPath)
    let log = readAuditLog(res.auditLogPath)
    var seenRebooting = false
    var seenQuiet = false
    for rec in log.records:
      if rec.recordClass != AuditClassBuildAction:
        continue
      if rec.resourceAddress == RebootingEdgeId:
        seenRebooting = true
        check rec.restartNeeded
      elif rec.resourceAddress == QuietEdgeId:
        seenQuiet = true
        check not rec.restartNeeded
    check seenRebooting
    check seenQuiet

  test "the declaration survives the profile envelope round trip":
    # The flag is only reachable from a profile if it survives the
    # serialisation between the profile macro and the apply driver. An
    # encoder that writes it and a decoder that ignores it would leave the
    # cases above passing on hand-built values while every real profile
    # arrived with `false`.
    var intent = ProfileIntent(name: "reboot-seam")
    intent.buildActions = @[rebootingEdge(), quietEdge()]
    let json = emitProfileIntentJson(intent)
    check json.contains("\"rebootRequired\":true")
    check json.contains("\"rebootRequired\":false")
    let back = parseProfileIntentJson(json)
    check back.buildActions.len == 2
    check back.buildActions[0].rebootRequired
    check not back.buildActions[1].rebootRequired
