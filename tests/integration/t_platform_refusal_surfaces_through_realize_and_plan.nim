## Platform-And-Microarchitecture-Constraints PMC-1 (Package-Model.md
## §"GAP: a package cannot declare the platforms it exists on") — the platform
## refusal reaches the USER, through both surfaces the milestone promises:
## ``realize`` reports it as a ``<platform>`` adapter failure, and ``--plan``
## preview reports it as a ``platform-unavailable:`` missing row.
##
## Why this test exists separately from the resolver tests. The sibling PMC-1
## tests pin the refusal at ``chainResolvePackage`` / ``resolvePackage`` — the
## place it is DECIDED. Nobody meets a resolver. An operator meets
## ``repro home apply`` (which raises ``EApplyRealizeFailed``) or ``repro home
## apply --plan`` (which prints a preview row), and PMC-1 claims both of those
## name the platform. Between the resolver and each surface sits a hand-written
## ``except EPackageUnavailableOnPlatform`` clause — four of them, in
## ``realize.nim`` — and every one is a place the reason can be lost. Deleting
## any of them leaves the sibling tests green while the operator goes back to
## reading "adapter chain exhausted".
##
## As with ``t_unavailable_package_fails_with_platform_reason``, the assertions
## are on message CONTENT, not merely on "something failed". A surface that
## still fails but has stopped saying WHY is the regression this milestone
## exists to prevent, and it is invisible to a test that only counts failures.
##
## THE FIXTURE, and why it is not ``chocolatey``. Both realize entry points
## resolve against the REAL host — ``realizeViaProductionCatalog`` has no
## ``hostCpu`` / ``hostOs`` seam, by design (it is the production path).
## ``chocolatey`` is declared ``[windows]``, so on a Windows developer box it
## is AVAILABLE and the refusal never fires. This file therefore declares its
## own package, ``pmc1AbsentHere``, whose declaration always names the OS this
## host is NOT — so the refusal fires on every host and the suite is
## host-agnostic rather than green-by-accident on two thirds of the fleet.
## ``pmc1PresentHere`` is its control twin, declared FOR this host.
##
## The preview surface, which does thread a synthetic host, is additionally
## exercised against the real ``chocolatey`` entry on a synthetic linux host,
## so the exact sentence an operator would read for the milestone's own example
## is pinned here too.
##
## Assertions:
##   1. REALIZE, legacy branch (no pinned version → ``useChain`` false, the
##      route a DSL-``tarball`` package like ``chocolatey`` actually takes):
##      ``realizePlannedPackages`` raises ``EApplyRealizeFailed`` whose
##      ``adapter`` field is the literal ``<platform>``, not ``<chain>`` and
##      not ``<none>``.
##   2. REALIZE, chain branch (pinned version → ``useChain`` true): the same
##      ``<platform>`` label. Both branches carry their own except clause and
##      both are asserted, because one can rot without the other.
##   3. REALIZE message content: it names the package, the declared set and
##      the host ("… is declared for <os> only; this host is <os>"), carries
##      the author's ``msg =`` verbatim, and still contains neither of the two
##      unfollowable remediations PMC-1 removed ("adapter chain exhausted",
##      "available on PATH").
##   4. REALIZE control: the twin package declared FOR this host is NOT
##      labelled ``<platform>``. It fails some other way (nothing catalogues
##      it), which proves the label comes from the availability gate rather
##      than from every realize failure.
##   5. PREVIEW, legacy branch: the row is ``ppkMissing`` and its ``detail``
##      STARTS WITH ``platform-unavailable: `` — the prefix is the contract;
##      a row that merely said "missing" would send the operator to catalogue
##      a package that cannot exist here.
##   6. PREVIEW, chain branch: same prefix, same reason.
##   7. PREVIEW message content: same content assertions as (3), and NOT the
##      ``adapter-chain-exhausted:`` prefix the same code path emits for the
##      genuinely-uncatalogued case.
##   8. PREVIEW against the real ``chocolatey`` entry on a synthetic linux
##      host reads, verbatim: ``platform-unavailable: chocolatey is declared
##      for windows only; this host is linux.`` plus the author's reason.
##   9. PLAN AND APPLY AGREE: for the SAME package, the preview's reason text
##      and the realize failure's reason text are the same sentence. The code
##      comment in ``realize.nim`` states this as the requirement ("the plan
##      and the apply must agree on why, or `--plan` teaches the operator the
##      wrong lesson"); nothing enforced it until now.
##
## Falsifiable, and MEASURED rather than assumed. Each of the two surfacing
## clauses was deleted in turn and the result observed:
##   * Removing realize's two ``except EPackageUnavailableOnPlatform`` clauses
##     makes (1)-(4) fail: the exception escapes ``realizePlannedPackages``
##     unconverted, so no ``EApplyRealizeFailed`` is ever raised and the
##     ``<platform>`` label does not exist.
##   * Removing preview's ``except EPackageUnavailableOnPlatform`` clauses
##     makes (5)-(9) fail: ``previewPackageResolutions`` propagates the
##     exception instead of returning a row.
## Both were restored afterwards.
##
## Hermetic: the fixture packages are declared in this file and exist only in
## this process; the Scoop probe is pointed at a non-existent root; the store
## is a temp dir removed on exit. Nothing is downloaded and no real package
## manager is consulted.

import std/[os, strutils, unittest]

import repro_project_dsl

import repro_local_store

import repro_dsl_stdlib/packages_schema
import repro_dsl_stdlib/catalog_registry
import repro_home_apply/plan
import repro_home_apply/realize
import repro_home_apply/errors
import repro_home_apply/package_catalog

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
  StoreRoot = "build/test-tmp/t-pmc1-realize-and-plan-surfaces"

proc sandboxScoopProbe(): string =
  ## Point every Scoop lookup at a root that does not exist, so no branch of
  ## the resolver can touch a real Scoop install on the developer's box.
  result = getTempDir() / "pmc1-surfaces-no-such-scoop-root"
  putEnv("SCOOP", result)
  putEnv("REPRO_TEST_SCOOP_OVERRIDE", result / "no-such-scoop.exe")

proc releaseScoopProbe() =
  delEnv("SCOOP")
  delEnv("REPRO_TEST_SCOOP_OVERRIDE")

proc checkPlatformReason(msg: string; packageId: string) =
  ## The content contract shared by both surfaces (assertions 3 and 7).
  let hostName = $detectHostOs()
  check msg.contains(packageId)
  check msg.contains("is declared for")
  check msg.contains(" only; this host is " & hostName)
  # The author's own words survive the trip to the surface. This is the part
  # a resolver cannot invent, and the part most likely to be dropped by a
  # handler that rewraps the message instead of forwarding it.
  check msg.contains(AuthorReason)
  # Neither piece of unfollowable advice reappears at the surface.
  check not msg.contains("adapter chain exhausted")
  check not msg.contains("available on PATH")
  check not msg.contains("adapter_preference")

suite "PMC-1 — the platform refusal reaches realize and --plan":

  test "t_platform_refusal_surfaces_through_realize_and_plan":
    discard sandboxScoopProbe()
    defer: releaseScoopProbe()

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

    # ---- (1)(3) REALIZE, legacy branch --------------------------------
    # No pinned version and no built-in catalog registration, so
    # ``realizeViaProductionCatalog``'s ``useChain`` is false and dispatch
    # goes through the legacy ``resolvePackage``. This is the route a
    # DSL-``tarball`` package such as ``chocolatey`` travels in production.
    block realizeLegacyBranch:
      var store = openStore(storeDir)
      defer: store.close()
      var raised = false
      try:
        discard realizePlannedPackages(store,
          @[PlannedPackage(packageId: AbsentId, fromActivity: "test")])
      except EApplyRealizeFailed as err:
        raised = true
        check err.packageId == AbsentId
        check err.adapter == PlatformAdapterLabel
        checkPlatformReason(err.msg, AbsentId)
        realizeReason = err.msg
      check raised

    # ---- (2)(3) REALIZE, chain branch ---------------------------------
    # A pinned version flips ``useChain`` on, routing through
    # ``callChainResolve`` -> ``chainResolvePackage``. That branch has its
    # own except clause; it can rot independently of the legacy one.
    block realizeChainBranch:
      var store = openStore(storeDir)
      defer: store.close()
      var raised = false
      try:
        discard realizePlannedPackages(store,
          @[PlannedPackage(packageId: AbsentId, fromActivity: "test",
            requestedVersion: "1.0.0")])
      except EApplyRealizeFailed as err:
        raised = true
        check err.adapter == PlatformAdapterLabel
        checkPlatformReason(err.msg, AbsentId)
      check raised

    # ---- (4) REALIZE control ------------------------------------------
    # The twin package satisfies its declaration on this host, so it passes
    # the gate and fails further down (nothing catalogues it). If THIS one
    # also came back as ``<platform>`` the label would be meaningless.
    block realizeControlAvailableHere:
      var store = openStore(storeDir)
      defer: store.close()
      var raised = false
      var sawPlatformLabel = false
      try:
        discard realizePlannedPackages(store,
          @[PlannedPackage(packageId: PresentId, fromActivity: "test")])
      except EApplyRealizeFailed as err:
        raised = true
        sawPlatformLabel = err.adapter == PlatformAdapterLabel
        if sawPlatformLabel:
          checkpoint "an AVAILABLE package was refused on platform grounds: " &
            err.msg
      check raised
      check not sawPlatformLabel

    # ---- (5)(7) PREVIEW, legacy branch --------------------------------
    block previewLegacyBranch:
      let rows = previewPackageResolutions(
        @[PlannedPackage(packageId: AbsentId, fromActivity: "test")])
      check rows.len == 1
      check rows[0].packageId == AbsentId
      check rows[0].kind == ppkMissing
      check rows[0].detail.startsWith(PreviewPrefix)
      check not rows[0].detail.startsWith("adapter-chain-exhausted:")
      checkPlatformReason(rows[0].detail, AbsentId)

      # ---- (9) the plan and the apply agree on WHY -------------------
      # Same package, two surfaces, one sentence. The reason text the
      # operator reads from ``--plan`` is the reason text the apply would
      # have raised.
      let previewReason = rows[0].detail[PreviewPrefix.len .. ^1]
      check previewReason.len > 0
      check realizeReason.contains(previewReason)

    # ---- (6)(7) PREVIEW, chain branch ---------------------------------
    block previewChainBranch:
      let rows = previewPackageResolutions(
        @[PlannedPackage(packageId: AbsentId, fromActivity: "test",
          requestedVersion: "1.0.0")])
      check rows.len == 1
      check rows[0].kind == ppkMissing
      check rows[0].detail.startsWith(PreviewPrefix)
      checkPlatformReason(rows[0].detail, AbsentId)

    # ---- (5 control) PREVIEW does not report an available package -----
    block previewControlAvailableHere:
      let rows = previewPackageResolutions(
        @[PlannedPackage(packageId: PresentId, fromActivity: "test")])
      check rows.len == 1
      if rows[0].detail.startsWith(PreviewPrefix):
        checkpoint "an AVAILABLE package previewed as platform-unavailable: " &
          rows[0].detail
      check not rows[0].detail.startsWith(PreviewPrefix)

    # ---- (8) the milestone's own example, verbatim --------------------
    # ``previewPackageResolutions`` DOES thread a synthetic host, so the real
    # catalog entry can be exercised here. A pinned version routes it through
    # the chain branch (``chocolatey`` is not in the built-in registry, so
    # ``useChain`` needs the version to fire).
    block previewRealChocolateyOnLinux:
      let rows = previewPackageResolutions(
        @[PlannedPackage(packageId: "chocolatey", fromActivity: "test",
          requestedVersion: "2.4.3")],
        hostCpu = pcX86_64, hostOs = poLinux)
      check rows.len == 1
      check rows[0].kind == ppkMissing
      check rows[0].detail.startsWith(
        PreviewPrefix &
        "chocolatey is declared for windows only; this host is linux.")
      # The author's reason, in the author's words, all the way to the
      # operator's terminal.
      check rows[0].detail.contains("Chocolatey is a Windows package manager")
