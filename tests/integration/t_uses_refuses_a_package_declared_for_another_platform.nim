## A recipe's ``uses:`` applies the declared-platforms gate (PMC-1) that a
## home profile's reference already applies, through the same code
## (``realization_selection.refuseUnavailablePlatform``).
##
## Package-Model.md §"GAP: a package cannot declare the platforms it exists
## on" → "Proposed shape": "Unconditional `uses:` on an unavailable package
## fails with a REASON, e.g. 'chocolatey is declared for windows only; this
## host is linux'", and `cakPath` "stops being reachable for a package known
## to be unavailable". Provisioning-Contributions.md §"Profile Package
## References" → Selection, step 1, which a recipe's `uses:` applies before
## its mode's selector.
##
## Regression test for reprobuild-pm
## issues/2026-10-13-uses-acquisition-skips-the-declared-platforms-gate.md.
## Before the fix the interface artifact a recipe's tool use is resolved from
## (``InterfaceToolUse``) did not carry the declaration, and the per-kind
## ``uses:`` entry points did not consult it: an unguarded
## ``uses: "chocolatey"`` on Linux in tarball mode failed with "no tarball
## provisioning entry for package \"chocolatey\" matches host cpu=x86_64
## os=linux", and in path mode resolved to whatever same-named executable
## PATH held.
##
## Production code throughout: the consumer's interface is extracted from the
## REAL stdlib ``chocolatey`` definition by ``toProjectInterface``, encoded and
## decoded by the real codec, and resolved by the real ``uses:`` entry points
## (``tarballAcquisitionPlan`` / ``nixAcquisitionPlan`` /
## ``scoopAcquisitionPlan`` with an explicit target, ``toolBuildIdentity`` for
## a mode). No mocks. Explicit targets keep cases 2-3 hermetic; the
## ``toolBuildIdentity`` cases resolve for the host, so they run on a host
## outside chocolatey's declared set (every non-Windows host).
##
## Falsifiable: drop the ``refuseUnavailablePlatform`` call from the
## selectors or from ``toolProfileFor`` and cases 2/4/5 raise a different
## error (or, in path mode, select the planted executable); drop the
## ``platforms`` block from the codec and case 1's round trip loses it.

import std/[options, os, strutils, tables, tempfiles, unittest]

import repro_project_dsl
import repro_project_dsl/install_mirror_resolver
import repro_dsl_stdlib/packages/chocolatey as chocolatey_pkg
import repro_interface_artifacts
import repro_tool_profiles

proc chocolateyConsumer(): ProjectInterface =
  let consumer = PackageDef(packageName: "needsChocolatey",
    toolUses: @[PackageUseDef(rawConstraint: "chocolatey",
      packageSelector: "chocolatey", executableName: "chocolatey",
      policyPath: @["uses"], depKind: "target",
      sourceFile: "repro.nim", sourceLine: 7)])
  toProjectInterface(consumer, registeredPackages())

proc chocolateyUse(): InterfaceToolUse =
  let pi = chocolateyConsumer()
  doAssert pi.toolUses.len == 1, "fixture drift: one tool use expected"
  pi.toolUses[0]

proc checkPlatformRefusal(err: ref EPlatformUnavailable; target: string) =
  check err.msg.contains("chocolatey is declared for windows only")
  check err.msg.contains("the target is " & target)
  # The author's reason, carried through the artifact verbatim.
  check err.msg.contains("Chocolatey is a Windows package manager")
  check err.packageName == "chocolatey"
  check err.declaredPlatforms == "windows only"

suite "uses: applies the declared-platforms gate":

  test "1. the interface artifact carries the declaration through the codec":
    let pi = chocolateyConsumer()
    let use = pi.toolUses[0]
    check use.platformsDeclared
    check use.declaredPlatforms == @[InterfaceDeclaredPlatform(cpu: "any",
      os: "windows")]
    check use.platformsMessage.contains("Chocolatey is a Windows package")
    let back = decodeInterfacePayload(encodeInterfacePayload(pi,
      interfaceEnvelopeVersion()), interfaceEnvelopeVersion())
    check back.toolUses[0].platformsDeclared
    check back.toolUses[0].declaredPlatforms == use.declaredPlatforms
    check back.toolUses[0].platformsMessage == use.platformsMessage

  test "2. every per-kind uses: entry point refuses a linux target by reason":
    let linux = realizationTargetFor(pcX86_64, poLinux, mlX86_64_v1)
    let use = chocolateyUse()
    var raised = 0
    try:
      discard tarballAcquisitionPlan(use, target = linux)
    except EPlatformUnavailable as err:
      inc raised
      checkPlatformRefusal(err, "linux")
    try:
      discard selectTarballProvisioning(use, target = linux)
    except EPlatformUnavailable as err:
      inc raised
      checkPlatformRefusal(err, "linux")
    # The nix and scoop selectors are gated before they look at records, so
    # a package with no records of their kind is refused by reason too.
    var withNix = use
    withNix.nixProvisioning = @[InterfaceNixProvisioning(
      packageName: "chocolatey", selector: "chocolatey",
      executablePath: "bin/choco")]
    try:
      discard nixAcquisitionPlan(withNix, target = linux)
    except EPlatformUnavailable as err:
      inc raised
      checkPlatformRefusal(err, "linux")
    var withScoop = use
    withScoop.scoopProvisioning = @[InterfaceScoopProvisioning(
      packageName: "chocolatey", bucket: "main", app: "chocolatey", version: "2.4.3", executablePath: "choco.exe")]
    try:
      discard scoopAcquisitionPlan(withScoop,
        target = realizationTargetFor(pcX86_64, poLinux, mlX86_64_v1))
    except EPlatformUnavailable as err:
      inc raised
      checkPlatformRefusal(err, "linux")
    check raised == 4

  test "3. the gate is target-sensitive: a windows target selects":
    let windows = realizationTargetFor(pcX86_64, poWindows, mlX86_64_v1)
    let plan = tarballAcquisitionPlan(chocolateyUse(), target = windows)
    check plan.declaredExecutablePath == "tools/chocolateyInstall/choco.exe"

  when not defined(windows):
    test "4. path mode never reaches a same-named executable on PATH":
      let scratch = createTempDir("repro-uses-platforms-", "")
      defer: removeDir(scratch)
      for name in ["chocolatey", "choco"]:
        let planted = scratch / name
        writeFile(planted, "#!/bin/sh\necho 2.4.3\n")
        setFilePermissions(planted, {fpUserRead, fpUserWrite, fpUserExec})
      let artifact = ProjectInterfaceArtifact(
        projectInterface: chocolateyConsumer())
      var raised = false
      try:
        let identity = toolBuildIdentity(artifact, tpmPathOnly,
          pathValue = scratch)
        checkpoint "resolved to " & identity.profiles[0].resolvedExecutablePath
      except EPlatformUnavailable as err:
        raised = true
        checkPlatformRefusal(err, $detectHostOs())
      check raised

    test "5. tarball mode refuses by reason, not by a missing entry":
      let artifact = ProjectInterfaceArtifact(
        projectInterface: chocolateyConsumer())
      var raised = false
      try:
        discard toolBuildIdentity(artifact, tpmTarball,
          storeRoot = createTempDir("repro-uses-platforms-store-", ""))
      except EPlatformUnavailable as err:
        raised = true
        checkPlatformRefusal(err, $detectHostOs())
        check not err.msg.contains("no tarball provisioning entry")
      check raised

    test "6. a producer binding is not consulted for an unavailable package":
      let scratch = createTempDir("repro-uses-platforms-producer-", "")
      defer: removeDir(scratch)
      let planted = scratch / "chocolatey"
      writeFile(planted, "#!/bin/sh\necho 2.4.3\n")
      setFilePermissions(planted, {fpUserRead, fpUserWrite, fpUserExec})
      let artifact = ProjectInterfaceArtifact(
        projectInterface: chocolateyConsumer())
      var producers = initTable[string, ProducerExecutableDirs]()
      producers["chocolatey"] = ProducerExecutableDirs(binDirs: @[scratch])
      var raised = false
      try:
        discard toolBuildIdentity(artifact, tpmPathOnly, pathValue = "",
          producerExecutableSelectors = producers)
      except EPlatformUnavailable as err:
        raised = true
        checkPlatformRefusal(err, $detectHostOs())
      check raised

  test "7. a cross build's target-side dependency is gated against --target":
    let before = getEnv("REPRO_VARIANTS")
    defer: putEnv("REPRO_VARIANTS", before)
    let artifact = ProjectInterfaceArtifact(
      projectInterface: chocolateyConsumer())
    check chocolateyUse().depKind == "target"
    # A Windows target: chocolatey exists there, so whatever path mode then
    # says about the cross dependency, it is not a platform refusal.
    putEnv("REPRO_VARIANTS", "targetTriple=x86_64-w64-mingw32")
    for mode in [tpmPathOnly, tpmTarball]:
      checkpoint $mode
      try:
        discard toolBuildIdentity(artifact, mode, pathValue = "",
          storeRoot = createTempDir("repro-uses-platforms-x-", ""))
      except EPlatformUnavailable as err:
        checkpoint err.msg
        check false
      except CatchableError:
        discard
    # A Linux target: refused by reason in every mode, naming the target.
    putEnv("REPRO_VARIANTS", "targetTriple=aarch64-unknown-linux-gnu")
    for mode in [tpmPathOnly, tpmTarball, tpmNix, tpmFromSource]:
      checkpoint $mode
      var raised = false
      try:
        discard toolBuildIdentity(artifact, mode, pathValue = "",
          storeRoot = createTempDir("repro-uses-platforms-x-", ""))
      except EPlatformUnavailable as err:
        raised = true
        checkPlatformRefusal(err, "linux")
      check raised
    # A `nativeBuildDeps:` tool is resolved -- with its recipe's from-source
    # closure, whose target-kind uses are that recipe's -- under the native
    # mirror override, because it is built for the build host. Its uses are
    # gated against the host there, not against --target: under a Windows
    # target, chocolatey is still refused for this (non-Windows) host.
    putEnv("REPRO_VARIANTS", "targetTriple=x86_64-w64-mingw32")
    check usesGateTarget(chocolateyUse(), hostRealizationTarget()).get.os ==
      poWindows
    withInstallMirrorTarget(""):
      let gated = usesGateTarget(chocolateyUse(), hostRealizationTarget())
      check gated.get.os == hostRealizationTarget().os
      when not defined(windows):
        check not isAvailableForUse(chocolateyUse(), hostRealizationTarget())

  test "8. triples name their platform; an unknown one does not gate":
    check platformOfTriple("x86_64-w64-mingw32").get.os == poWindows
    check platformOfTriple("aarch64-unknown-linux-gnu").get.os == poLinux
    check platformOfTriple("aarch64-unknown-linux-gnu").get.platform.family ==
      pcAarch64
    check platformOfTriple("arm64-apple-darwin").get.os == poMacos
    check platformOfTriple("x86_64-apple-macosx10.12").get.os == poMacos
    check platformOfTriple("wasm32-unknown-unknown").isNone
    # The ``apple`` vendor does not name macOS: an iOS target is an
    # unrecognised OS, so it does not gate rather than be tested as macOS.
    check platformOfTriple("aarch64-apple-ios").isNone

  test "9. the author's reason is not part of the interface fingerprint":
    var a = chocolateyConsumer()
    var b = a
    b.toolUses[0].platformsMessage = "Reworded."
    check interfaceFingerprint(a) == interfaceFingerprint(b)
    var c = a
    c.toolUses[0].declaredPlatforms[0].os = "linux"
    check interfaceFingerprint(a) != interfaceFingerprint(c)
