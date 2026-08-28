## Every constructed tool profile must be SEALED — i.e. must have had
## ``refreshProfileIdentity`` run on it — because an unsealed profile does
## not merely lack a fingerprint, it carries a fingerprint that collides
## with every other unsealed profile.
##
## ## The defect this pins
##
## ``refreshProfileIdentity``'s docstring claimed: "Every adapter goes
## through here so no construction site can produce a profile whose
## fingerprint claims a content identity it never computed."
##
## That was false. ``mkAuxChannelProducerProfile`` — the
## Cross-Repo-Source-Consumption SC-3 adapter for a ``uses:`` selector
## that resolves to a from-source sibling LIBRARY producer — returned an
## object literal and never sealed. Measured on two SC-3 library-channel
## producers with entirely DIFFERENT realized include / lib directories:
##
##     profileFingerprint A = 0000…0000
##     profileFingerprint B = 0000…0000
##     zero digest? true    A == B (collision)? true
##
## ``ContentDigest``'s zero value is not a "no identity" sentinel that
## anything downstream tests for; it is just another digest, and it is the
## SAME one for every profile that skipped the seal. So the two producers
## were indistinguishable to every consumer of the field — including
## ``repro_cli_support``'s ``reprobuild.localProjectAction`` weak
## fingerprint, which folds ``digestHex(profile.profileFingerprint)``
## straight into a live action cache key.
##
## ``actionFingerprint`` is computed separately (``actionFingerprintFor``
## runs unconditionally in ``actionIdentityFor``) and does distinguish the
## two, which is why the hole had not obviously bitten. That is a reason it
## was latent, not a reason it was safe: the two structures key different
## things, and only one of them had the guard.
##
## ## What is asserted, and why each direction is needed
##
##   1. An aux-channel producer profile is sealed: its fingerprint is not
##      the zero digest. (Fails on the unsealed construction.)
##   2. Two producers with different realized dirs get DIFFERENT
##      fingerprints. (This is the collision itself; it also fails on the
##      unsealed construction, and it is what makes (1) mean something —
##      a "seal" that produced a constant would satisfy (1) alone.)
##   3. Two producers with the SAME realized dirs get the SAME
##      fingerprint. Anti-vacuity for (2): a fingerprint that folded a
##      timestamp or an address would pass (2) and be useless as a cache
##      key.
##   4. Each aux channel is individually load-bearing — moving only the
##      include dirs, only the lib dirs, only the pkg-config dirs, or only
##      the cmake prefix dirs each moves the fingerprint.
##   5. Sealing an aux profile costs no I/O: it has no resolved
##      executable, and ``resolvedExecutableContentDigest("")`` returns
##      the empty string rather than reading anything.
##
## ## No mocks
##
## Driven through the real exported ``toolBuildIdentity`` with a real
## ``producerAuxSelectors`` table — the same entry point
## ``resolveAndWriteIdentity`` calls — so the assertions run against the
## production construction path rather than a re-implementation of it.

import std/[tables, unittest]

import repro_interface_artifacts
import repro_tool_profiles

const ProducerSelector = "sealed-fixture-library"

proc artifact(): ProjectInterfaceArtifact =
  ProjectInterfaceArtifact(
    projectInterface: ProjectInterface(
      projectName: "sealed-fixture-project",
      packageName: "sealed-fixture-package",
      toolUses: @[InterfaceToolUse(
        rawConstraint: ProducerSelector,
        packageSelector: ProducerSelector,
        executableName: ProducerSelector)]))

proc auxProfile(dirs: ProducerAuxDirs): PathOnlyToolProfile =
  var selectors = initTable[string, ProducerAuxDirs]()
  selectors[ProducerSelector] = dirs
  let identity = toolBuildIdentity(artifact(), tpmPathOnly,
    producerAuxSelectors = selectors)
  doAssert identity.profiles.len == 1
  identity.profiles[0]

proc dirsA(): ProducerAuxDirs =
  ProducerAuxDirs(
    includeDirs: @["/producers/liba/rev-aaaa/build/include"],
    libDirs: @["/producers/liba/rev-aaaa/build/lib"],
    pkgConfigDirs: @["/producers/liba/rev-aaaa/build/lib/pkgconfig"],
    cmakePrefixDirs: @["/producers/liba/rev-aaaa/build"])

proc dirsB(): ProducerAuxDirs =
  ProducerAuxDirs(
    includeDirs: @["/producers/libb/rev-bbbb/build/include"],
    libDirs: @["/producers/libb/rev-bbbb/build/lib"],
    pkgConfigDirs: @["/producers/libb/rev-bbbb/build/lib/pkgconfig"],
    cmakePrefixDirs: @["/producers/libb/rev-bbbb/build"])

proc zeroDigest(): auto =
  ## The value an UNSEALED profile ships — the field's zero value, read
  ## off a freshly default-constructed profile rather than named as a
  ## literal, so this stays correct if ``ContentDigest`` changes shape.
  PathOnlyToolProfile().profileFingerprint

suite "every_tool_profile_is_sealed":
  test "an aux-channel producer profile carries a sealed fingerprint":
    let profile = auxProfile(dirsA())
    # Precondition: this really is the aux-channel adapter's output — no
    # executable was resolved, which is the branch that used to skip the
    # seal.
    check profile.resolvedExecutablePath == ""
    check profile.cpathList == dirsA().includeDirs

    check profile.profileFingerprint != zeroDigest()

  test "two producers with different realized dirs do not collide":
    let a = auxProfile(dirsA())
    let b = auxProfile(dirsB())
    check a.cpathList != b.cpathList
    check a.profileFingerprint != b.profileFingerprint

  test "two producers with the same realized dirs agree":
    check auxProfile(dirsA()).profileFingerprint ==
      auxProfile(dirsA()).profileFingerprint

  test "each aux channel is individually keyed":
    let baseline = auxProfile(dirsA()).profileFingerprint

    var onlyInclude = dirsA()
    onlyInclude.includeDirs = @["/producers/liba/rev-cccc/build/include"]
    check auxProfile(onlyInclude).profileFingerprint != baseline

    var onlyLib = dirsA()
    onlyLib.libDirs = @["/producers/liba/rev-cccc/build/lib"]
    check auxProfile(onlyLib).profileFingerprint != baseline

    var onlyPkgConfig = dirsA()
    onlyPkgConfig.pkgConfigDirs =
      @["/producers/liba/rev-cccc/build/lib/pkgconfig"]
    check auxProfile(onlyPkgConfig).profileFingerprint != baseline

    var onlyCmake = dirsA()
    onlyCmake.cmakePrefixDirs = @["/producers/liba/rev-cccc/build"]
    check auxProfile(onlyCmake).profileFingerprint != baseline

  test "sealing a profile with no resolved executable reads nothing":
    # The seal's first step is a content digest of the resolved
    # executable. For this adapter there is none, and the digest helper
    # short-circuits on the empty path — so making the invariant hold here
    # costs no filesystem I/O.
    check resolvedExecutableContentDigest("") == ""
    check auxProfile(dirsA()).resolvedExecutableDigest == ""

  test "refreshProfileIdentity is reachable as the one sealing entry point":
    # Exported so construction sites outside this module (the synthetic
    # metadata-selection profiles in ``repro_cli_support``) can obey the
    # same rule instead of being a documented exception to it.
    var profile = PathOnlyToolProfile(
      installMethod: "path",
      packageSelector: "manual",
      executableName: "manual")
    check profile.profileFingerprint == zeroDigest()
    refreshProfileIdentity(profile)
    check profile.profileFingerprint != zeroDigest()
