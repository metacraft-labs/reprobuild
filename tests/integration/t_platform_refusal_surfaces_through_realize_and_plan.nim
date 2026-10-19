## Platform-And-Microarchitecture-Constraints PMC-1 (Package-Model.md
## §"GAP: a package cannot declare the platforms it exists on") — the platform
## refusal reaches the USER, through both surfaces the milestone promises:
## ``realize`` reports it as a ``<platform>`` adapter failure, and ``--plan``
## preview reports it as a ``platform-unavailable:`` missing row.
##
## Why this test exists separately from the resolver tests. The sibling PMC-1
## tests pin the refusal at ``selectRealization`` (through
## ``resolveProfilePackage``) — the place it is DECIDED. Nobody meets a
## resolver. An operator meets ``repro home apply`` (which raises
## ``EApplyRealizeFailed``) or ``repro home apply --plan`` (which prints a
## preview row), and PMC-1 claims both of those name the platform. Between the
## selection and each surface sits a hand-written conversion in
## ``realize.nim`` — the ``except EPlatformUnavailable`` clause of
## ``realizePlannedPackages`` and ``previewResolutionFailure`` — and each is a
## place the reason can be lost. Deleting either leaves the sibling tests green
## while the operator goes back to reading a generic missing-realization line.
##
## As with ``t_unavailable_package_fails_with_platform_reason``, the assertions
## are on message CONTENT, not merely on "something failed". A surface that
## still fails but has stopped saying WHY is the regression this milestone
## exists to prevent, and it is invisible to a test that only counts failures.
##
## THE FIXTURE, and why it is not ``chocolatey``. The realize half runs in
## the context of the REAL host (``hostProfileResolutionContext``), which is
## what production apply builds.
## ``chocolatey`` is declared ``[windows]``, so on a Windows developer box it
## is AVAILABLE and the refusal never fires. This file therefore declares its
## own package, ``pmc1AbsentHere``, whose declaration always names the OS this
## host is NOT — so the refusal fires on every host and the suite is
## host-agnostic rather than green-by-accident on two thirds of the fleet.
## ``pmc1PresentHere`` is its control twin, declared FOR this host.
##
## The preview surface is additionally exercised against the real
## ``chocolatey`` entry in a synthetic linux target context,
## so the exact sentence an operator would read for the milestone's own example
## is pinned here too.
##
## Assertions:
##   1. REALIZE, unpinned reference: ``realizePlannedPackages`` raises
##      ``EApplyRealizeFailed`` whose ``adapter`` field is the literal
##      ``<platform>``, not ``<selection>``.
##   2. REALIZE, version-pinned reference: the same ``<platform>`` label — a
##      pin must not route around the gate.
##   3. REALIZE message content: it names the package, the declared set and
##      the target ("… is declared for <os> only; the target is <os>"),
##      carries the author's ``msg =`` verbatim, and contains none of the
##      unfollowable remediations PMC-1 removed ("no realization of package",
##      "available on PATH", "adapterPreference").
##   4. REALIZE control: the twin package declared FOR this host is NOT
##      labelled ``<platform>``. It fails some other way (nothing realizes
##      it), which proves the label comes from the availability gate rather
##      than from every realize failure.
##   5. PREVIEW, unpinned: the row is ``ppkMissing`` and its ``detail``
##      STARTS WITH ``platform-unavailable: `` — the prefix is the contract.
##   6. PREVIEW, version-pinned: same prefix, same reason.
##   7. PREVIEW message content: same content assertions as (3), and NOT the
##      ``missing-realization:`` prefix the same code path emits for the
##      genuinely-unrealizable case.
##   8. PREVIEW against the real ``chocolatey`` entry in a synthetic linux
##      target context reads, verbatim: ``platform-unavailable: chocolatey is
##      declared for windows only; the target is linux.`` plus the author's
##      reason.
##   9. PLAN AND APPLY AGREE: for the SAME package, the preview's reason text
##      and the realize failure's reason text are the same sentence. The code
##      comment in ``realize.nim`` states this as the requirement ("the plan
##      and the apply must agree on why, or `--plan` teaches the operator the
##      wrong lesson"); nothing enforced it until now.
##
## Falsifiable (measured before GM4b against the then-current clauses; the
## same mutations apply to the GM4b code): removing the ``except
## EPlatformUnavailable`` clause of ``realizePlannedPackages`` makes (1)-(3)
## fail (the refusal is labelled ``<selection>``); removing the
## ``EPlatformUnavailable`` arm of ``previewResolutionFailure`` makes (5)-(9)
## fail (the row is labelled ``missing-realization``).
##
## Hermetic: the fixture packages are declared in this file and exist only in
## this process; the store is a temp dir removed on exit. Nothing is
## downloaded and no package manager is consulted (the fixtures declare no
## realization).

import std/[os, strutils, tables, unittest]

import repro_project_dsl

import repro_local_store

import repro_dsl_stdlib/packages_schema
import repro_home_apply/plan
import repro_home_apply/realize
import repro_home_apply/errors
import repro_home_apply/package_catalog
from repro_test_support import testCaseScratchSlug

# ---------------------------------------------------------------------------
# Fixture packages
# ---------------------------------------------------------------------------
#
# ``pmc1AbsentHere`` always declares the OS this host is NOT, so the gate
# fires wherever the suite runs. ``pmc1PresentHere`` declares THIS host, so it
# passes the gate and fails downstream — the control for assertion (4).
#
# Neither carries a provisioning arm. That is deliberate: an arm outside the
# declared set is a lint error (``lintArmsAgainstDeclaredPlatforms``), and an
# arm inside it would give the resolver something to find, which would test
# the adapter chain rather than the gate in front of it.

when defined(windows):
  package pmc1AbsentHere:
    platforms:
      [linux]
      msg = "Test fixture for PMC-1: declared for Linux only."

  package pmc1PresentHere:
    platforms:
      [windows]
      msg = "Test fixture for PMC-1: declared for the running host."
else:
  package pmc1AbsentHere:
    platforms:
      [windows]
      msg = "Test fixture for PMC-1: declared for Windows only."

  when defined(macosx) or defined(osx):
    package pmc1PresentHere:
      platforms:
        [macos]
        msg = "Test fixture for PMC-1: declared for the running host."
  else:
    package pmc1PresentHere:
      platforms:
        [linux]
        msg = "Test fixture for PMC-1: declared for the running host."

const
  AbsentId = "pmc1AbsentHere"
  PresentId = "pmc1PresentHere"
  AuthorReason = "Test fixture for PMC-1: declared for "
  PlatformAdapterLabel = "<platform>"
  PreviewPrefix = "platform-unavailable: "
let StoreRoot = "build/test-tmp/t-pmc1-realize-and-plan-surfaces" /
  testCaseScratchSlug()

proc checkPlatformReason(msg: string; packageId: string) =
  ## The content contract shared by both surfaces (assertions 3 and 7).
  let hostName = $detectHostOs()
  check msg.contains(packageId)
  check msg.contains("is declared for")
  check msg.contains(" only; the target is " & hostName)
  # The author's own words survive the trip to the surface. This is the part
  # a resolver cannot invent, and the part most likely to be dropped by a
  # handler that rewraps the message instead of forwarding it.
  check msg.contains(AuthorReason)
  # Neither piece of unfollowable advice reappears at the surface.
  check not msg.contains("no realization of package")
  check not msg.contains("available on PATH")
  check not msg.contains("adapterPreference")

suite "PMC-1 — the platform refusal reaches realize and --plan":

  test "t_platform_refusal_surfaces_through_realize_and_plan":
    # The context production apply builds for this machine.
    let ctx = hostProfileResolutionContext()

    # The fixtures must be armed, or every assertion below is vacuous.
    let absent = packageAvailability(AbsentId)
    check absent.declared
    check not absent.isAvailableOn(detectHostCpu(), detectHostOs())
    let present = packageAvailability(PresentId)
    check present.declared
    check present.isAvailableOn(detectHostCpu(), detectHostOs())

    let storeDir = StoreRoot / "store"
    if dirExists(storeDir): removeDir(storeDir)
    createDir(storeDir)
    defer: removeDir(StoreRoot)

    var realizeReason = ""

    # ---- (1)(3) REALIZE, unpinned --------------------------------------
    block realizeUnpinned:
      var store = openStore(storeDir)
      defer: store.close()
      var raised = false
      try:
        discard realizePlannedPackages(store,
          @[PlannedPackage(packageId: AbsentId, fromActivity: "test")], ctx)
      except EApplyRealizeFailed as err:
        raised = true
        check err.packageId == AbsentId
        check err.adapter == PlatformAdapterLabel
        checkPlatformReason(err.msg, AbsentId)
        realizeReason = err.msg
      check raised

    # ---- (2)(3) REALIZE, version-pinned ---------------------------------
    # A pin narrows selection to that version; it must not route around the
    # availability gate.
    block realizePinned:
      var store = openStore(storeDir)
      defer: store.close()
      var raised = false
      try:
        discard realizePlannedPackages(store,
          @[PlannedPackage(packageId: AbsentId, fromActivity: "test",
            requestedVersion: "1.0.0")], ctx)
      except EApplyRealizeFailed as err:
        raised = true
        check err.adapter == PlatformAdapterLabel
        checkPlatformReason(err.msg, AbsentId)
      check raised

    # ---- (4) REALIZE control ------------------------------------------
    # The twin package satisfies its declaration on this host, so it passes
    # the gate and fails further down (nothing realizes it). If THIS one
    # also came back as ``<platform>`` the label would be meaningless.
    block realizeControlAvailableHere:
      var store = openStore(storeDir)
      defer: store.close()
      var raised = false
      var sawPlatformLabel = false
      try:
        discard realizePlannedPackages(store,
          @[PlannedPackage(packageId: PresentId, fromActivity: "test")], ctx)
      except EApplyRealizeFailed as err:
        raised = true
        sawPlatformLabel = err.adapter == PlatformAdapterLabel
        if sawPlatformLabel:
          checkpoint "an AVAILABLE package was refused on platform grounds: " &
            err.msg
      check raised
      check not sawPlatformLabel

    # ---- (5)(7) PREVIEW, unpinned ---------------------------------------
    block previewUnpinned:
      let rows = previewPackageResolutions(
        @[PlannedPackage(packageId: AbsentId, fromActivity: "test")], ctx)
      check rows.len == 1
      check rows[0].packageId == AbsentId
      check rows[0].kind == ppkMissing
      check rows[0].detail.startsWith(PreviewPrefix)
      check not rows[0].detail.startsWith("missing-realization:")
      checkPlatformReason(rows[0].detail, AbsentId)

      # ---- (9) the plan and the apply agree on WHY -------------------
      # Same package, two surfaces, one sentence. The reason text the
      # operator reads from ``--plan`` is the reason text the apply would
      # have raised.
      let previewReason = rows[0].detail[PreviewPrefix.len .. ^1]
      check previewReason.len > 0
      check realizeReason.contains(previewReason)

    # ---- (6)(7) PREVIEW, version-pinned ---------------------------------
    block previewPinned:
      let rows = previewPackageResolutions(
        @[PlannedPackage(packageId: AbsentId, fromActivity: "test",
          requestedVersion: "1.0.0")], ctx)
      check rows.len == 1
      check rows[0].kind == ppkMissing
      check rows[0].detail.startsWith(PreviewPrefix)
      checkPlatformReason(rows[0].detail, AbsentId)

    # ---- (5 control) PREVIEW does not report an available package -----
    block previewControlAvailableHere:
      let rows = previewPackageResolutions(
        @[PlannedPackage(packageId: PresentId, fromActivity: "test")], ctx)
      check rows.len == 1
      if rows[0].detail.startsWith(PreviewPrefix):
        checkpoint "an AVAILABLE package previewed as platform-unavailable: " &
          rows[0].detail
      check not rows[0].detail.startsWith(PreviewPrefix)

    # ---- (8) the milestone's own example, verbatim --------------------
    # The preview resolves in whatever context it is given, so the real
    # stdlib entry is exercised for a synthetic linux target. Pinned, so a
    # pin is shown not to route around the gate on this surface either.
    block previewRealChocolateyOnLinux:
      let linuxCtx = profileResolutionContext(
        initOrderedTable[string, seq[string]](), "linux", "x86_64",
        isHost = false)
      let rows = previewPackageResolutions(
        @[PlannedPackage(packageId: "chocolatey", fromActivity: "test",
          requestedVersion: "2.4.3")], linuxCtx)
      check rows.len == 1
      check rows[0].kind == ppkMissing
      check rows[0].detail.startsWith(
        PreviewPrefix &
        "chocolatey is declared for windows only; the target is linux.")
      # The author's reason, in the author's words, all the way to the
      # operator's terminal.
      check rows[0].detail.contains("Chocolatey is a Windows package manager")
