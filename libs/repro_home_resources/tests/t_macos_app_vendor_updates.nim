## GM7: a placed application's vendor update and a running application
## (Store-And-Installation-Layout.md § macOS Application Bundles, "Vendor
## updates", "Running applications").
##
## Three layers, each against real inputs:
##
## * the version order (`compareVersionStrings`) over the version strings the
##   catalog's applications actually carry;
## * the identity-bytes test (`vendorUpdateCandidate`) and the full test
##   (`isAcceptedVendorUpdate`) over bundles built and signed at test time
##   with the real `codesign`; and the running-process probe
##   (`processesRunningFrom`) against a real process started from a fixture
##   bundle;
## * the lifecycle decision (`decideAction`) for every combination the spec
##   lists: kept, replaced by a newer declared version, drift for anything
##   that is not a vendor update, removal of a vendor update, and deferral
##   of an update / destroy while the object is in use (drift stays drift).
##
## The fixture bundles are ad-hoc signed with a team identifier, so the two
## checks that need Apple (Developer ID chain, notarization) cannot pass for
## them: the STRICT policy is asserted to refuse them (so the full test is
## proven to run those checks), and the relaxed policy -- reachable only
## through the library API, as in `t_macos_app_bundle_placement` -- is used
## to show acceptance. No mocks.
##
## Falsifying mutations (performed for GM7): dropping the version comparison
## from `vendorUpdateCandidate` turns "a downgrade is never a vendor update"
## red; dropping the trust checks from `isAcceptedVendorUpdate` turns "the
## strict policy refuses an ad-hoc vendor update" red; making
## `decideAction` ignore `busy` turns the deferral cases red.

import std/[os, osproc, strutils, tempfiles, unittest]

import repro_home_resources
import repro_home_resources/drivers/app_bundle

suite "GM7: bundle version order":
  test "numeric components compare numerically":
    check compareVersionStrings("1.142.0", "1.141.0") == 1
    check compareVersionStrings("2.42304.0", "2.37337.1") == 1
    check compareVersionStrings("26.1007.41230", "26.623.141536") == 1
    check compareVersionStrings("3.7.4", "3.6.11") == 1
    check compareVersionStrings("0.0.416", "0.0.416") == 0
    check compareVersionStrings("1.9", "1.10") == -1
    check compareVersionStrings("1.2", "1.2.1") == -1
    check compareVersionStrings("1.02", "1.2") == 0

  test "CFBundleVersion breaks a tie of the short version":
    let a = AppBundleIdentity(shortVersion: "13.0", bundleVersion: "283305")
    let b = AppBundleIdentity(shortVersion: "13.0", bundleVersion: "283299")
    check compareBundleVersions(a, b) == 1
    check compareBundleVersions(b, a) == -1

when defined(macosx):
  import repro_test_support/macos_app_fixtures

  const
    AppId = "dev.reprobuild.gm7.vendor"
    Relaxed = {atrUnanchoredTeamIdentifier, atrSkipNotarization}

  let root = createTempDir("repro-gm7-vendor-", "")
  let v1 = makeFixtureApp(root / "v1", "Vendor", AppId, "1.0.0")
  let v2 = makeFixtureApp(root / "v2", "Vendor", AppId, "2.0.0")
  let other = makeFixtureApp(root / "other", "Vendor", "dev.reprobuild.other",
    "3.0.0")
  let otherTeam = makeFixtureApp(root / "team", "Vendor", AppId, "3.0.0",
    teamId = "ZYXWV98765")
  let unsigned = makeFixtureApp(root / "unsigned", "Vendor", AppId, "3.0.0",
    sign = false)
  let id1 = appBundleCanonicalBytes(readAppBundleIdentity(v1))
  let id2 = appBundleCanonicalBytes(readAppBundleIdentity(v2))

  suite "GM7: what a vendor update is":
    test "identity bytes round-trip; a folder identity is not a bundle":
      var parsed: AppBundleIdentity
      check parseAppBundleIdentityBytes(id1, parsed)
      check parsed.bundleId == AppId
      check parsed.shortVersion == "1.0.0"
      check parsed.teamId == FixtureTeamId
      check parsed.cdhash.len == 40
      let folder = "macos.appFolder.v1\nbundle=Vendor.app\n"
      var bytes: seq[byte]
      for ch in folder: bytes.add byte(ord(ch))
      check not parseAppBundleIdentityBytes(bytes, parsed)
      check describeIdentityVersion(id2) == "2.0.0"

    test "a newer build of the same application and team is a candidate":
      check vendorUpdateCandidate(id1, id2)

    test "a downgrade is never a vendor update":
      check not vendorUpdateCandidate(id2, id1)
      check not vendorUpdateCandidate(id1, id1)

    test "another application, another team or an unsigned copy is not":
      check not vendorUpdateCandidate(id1,
        appBundleCanonicalBytes(readAppBundleIdentity(other)))
      check not vendorUpdateCandidate(id1,
        appBundleCanonicalBytes(readAppBundleIdentity(otherTeam)))
      check not vendorUpdateCandidate(id1,
        appBundleCanonicalBytes(readAppBundleIdentity(unsigned)))

    test "the relaxed policy accepts the newer build on disk":
      check isAcceptedVendorUpdate(id1, id2, v2, Relaxed)

    test "the strict policy refuses an ad-hoc vendor update":
      # The Developer ID requirement and notarization run (real codesign -R
      # and spctl) and refuse the ad-hoc fixture.
      check not isAcceptedVendorUpdate(id1, id2, v2)

    test "a tampered newer build is refused (signature check)":
      let tampered = makeFixtureApp(root / "tampered", "Vendor", AppId,
        "2.0.0")
      let tamperedId = appBundleCanonicalBytes(readAppBundleIdentity(tampered))
      tamperFixtureApp(tampered)
      check not isAcceptedVendorUpdate(id1, tamperedId, tampered, Relaxed)

    test "the bytes must be the bundle's own":
      # Observed bytes that are not what is on disk (an updater swapped the
      # bundle between the observation and the checks) are refused.
      check not isAcceptedVendorUpdate(id1, id2, v1, Relaxed)

  suite "GM7: running applications":
    test "a process started from inside a bundle is found, and only there":
      let runner = makeFixtureApp(root / "run", "Runner", AppId, "1.0.0",
        sign = false)
      let exe = runner / "Contents" / "MacOS" / "Runner"
      writeFile(root / "runner.c",
        "#include <unistd.h>\nint main(void) { sleep(30); return 0; }\n")
      let cc = execCmdEx(quoteShellCommand(["/usr/bin/cc", "-o", exe,
        root / "runner.c"]))
      doAssert cc.exitCode == 0, cc.output
      check processesRunningFrom(runner).len == 0
      let p = startProcess(exe, options = {})
      try:
        var found: seq[int]
        for _ in 0 ..< 50:
          found = processesRunningFrom(runner)
          if found.len > 0: break
          sleep(20)
        check found == @[p.processID]
        # A sibling path sharing the prefix is not inside the bundle.
        check processesRunningFrom(root / "run" / "Run").len == 0
        check processesRunningFrom(v1).len == 0
      finally:
        p.terminate()
        discard p.waitForExit()
        p.close()
      check processesRunningFrom(runner).len == 0

  removeDir(root)

proc bytesOf(s: string): seq[byte] =
  for ch in s: result.add byte(ord(ch))

let
  recordedId = bytesOf("recorded")
  liveId = bytesOf("live")
  declaredId = bytesOf("declared")

proc lifecycleState(desiredBytes, observedBytes: seq[byte];
                    hasDesired = true): ResourceState =
  result.address = "home.package.vendor.app"
  if hasDesired:
    result.hasDesired = true
    result.desired = Resource(kind: rkMacosAppBundle,
      address: result.address, appBundleIdentity: desiredBytes)
  result.observed = ObservedState(present: true,
    digest: digestOfBytes(observedBytes), rawBytes: observedBytes)
  result.hasRecorded = true
  result.recorded = RecordedBinding(address: result.address,
    kind: rkMacosAppBundle, postWriteDigest: digestOfBytes(recordedId),
    payloadBytes: recordedId)

suite "GM7: lifecycle decision for vendor updates and objects in use":
  test "a changed bundle that is no vendor update is drift":
    let a = decideAction(lifecycleState(recordedId, liveId))
    check a.kind == rakDriftBlocked

  test "a vendor update is kept while the profile declares the recorded version":
    var s = lifecycleState(recordedId, liveId)
    s.vendorUpdate = true
    let a = decideAction(s)
    check a.kind == rakNoOp
    check a.keptVendorUpdate
    check "vendor update kept" in a.summary

  test "a vendor update is kept over an older declared version, never downgraded":
    var s = lifecycleState(declaredId, liveId)
    s.vendorUpdate = true
    s.desiredSupersedesObserved = false
    check decideAction(s).kind == rakNoOp

  test "a newer declared version replaces the vendor update":
    var s = lifecycleState(declaredId, liveId)
    s.vendorUpdate = true
    s.desiredSupersedesObserved = true
    let a = decideAction(s)
    check a.kind == rakUpdate
    check not a.keptVendorUpdate

  test "an application no longer declared is removed even when it updated itself":
    var s = lifecycleState(@[], liveId, hasDesired = false)
    check decideAction(s).kind == rakDriftBlocked
    s.vendorUpdate = true
    check decideAction(s).kind == rakDestroy

  test "an update of an object in use is deferred":
    var s = lifecycleState(declaredId, recordedId)
    check decideAction(s).kind == rakUpdate
    s.busy = "running process 4242"
    let a = decideAction(s)
    check a.kind == rakNoOp
    check a.deferred
    check "deferred: in use by running process 4242" in a.summary

  test "a destroy of an object in use is deferred":
    var s = lifecycleState(@[], recordedId, hasDesired = false)
    check decideAction(s).kind == rakDestroy
    s.busy = "running process 4242"
    check decideAction(s).deferred

  test "an object in use does not hide drift, and a cache hit stays one":
    var s = lifecycleState(recordedId, liveId)
    s.busy = "running process 4242"
    check decideAction(s).kind == rakDriftBlocked
    var hit = lifecycleState(recordedId, recordedId)
    hit.busy = "running process 4242"
    let a = decideAction(hit)
    check a.kind == rakNoOp
    check not a.deferred
