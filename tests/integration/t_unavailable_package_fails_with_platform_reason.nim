## Platform-And-Microarchitecture-Constraints PMC-1 (Package-Model.md
## §"GAP: a package cannot declare the platforms it exists on" → "Proposed
## shape") — an unguarded reference to a package that DECLARED it cannot exist
## on this host fails naming the PLATFORM, not the adapter chain.
##
## Before PMC-1, resolution had no notion of declared availability. A
## Windows-only package on Linux walked the whole chain, found nothing, and
## raised ``EAdapterChainExhausted``, whose remediation text reads: "Declare
## the package in a recognized adapter catalog (built-in registry, Scoop,
## Nix), make its executable available on PATH, or override
## `adapter_preference:`". For a Windows package manager on Linux every one of
## those is impossible — the message describes the ONE situation the resolver
## could not distinguish from this one ("someone just has not catalogued it")
## and sends the reader to add a Linux arm for a tool with no POSIX build.
##
## This test asserts on the message CONTENT, deliberately. A test that only
## checked "it raises" would keep passing while the diagnostic rots, and the
## diagnostic IS the milestone.
##
## Assertions:
##   1. ``chocolatey`` on a synthetic linux host raises
##      ``EPackageUnavailableOnPlatform`` — a DISTINCT type, not
##      ``EAdapterChainExhausted``.
##   2. The message names the package, the declared platform set, and the
##      host: "chocolatey is declared for windows only; this host is linux".
##   3. The message carries the author-supplied ``msg`` from the declaration
##      (Spack's ``msg=``), so the reason reaches the reader in the author's
##      own words rather than being guessed at.
##   4. The message does NOT say "adapter chain exhausted" and does NOT advise
##      making the executable available on PATH — the two pieces of
##      unfollowable advice PMC-1 exists to remove.
##   5. The structured fields (``packageId`` / ``declaredPlatforms`` /
##      ``hostTarget`` / ``authorMessage``) carry the same facts, so a CLI
##      layer can render them without re-parsing prose.
##   6. The gate is HOST-SENSITIVE, not a blanket refusal: on a synthetic
##      windows host the same package reaches the adapter chain and fails the
##      old way (chocolatey has no built-in ``VersionedProvisioning`` catalog,
##      so the chain legitimately exhausts there).
##
## Falsifiable: delete the availability gate in ``chainResolvePackage`` and
## assertion (1) trips — the raise becomes ``EAdapterChainExhausted`` again.
## Blank the author ``msg`` on the declaration and (3) trips.
##
## Hermetic: the host target is passed explicitly through the ``hostCpu`` /
## ``hostOs`` parameters, so this runs identically on any machine and never
## consults the real host.

import std/[options, os, strutils, unittest]

import repro_dsl_stdlib/packages_schema
import repro_dsl_stdlib/catalog_registry
import repro_home_apply/package_catalog

suite "PMC-1 — an unavailable package fails naming the platform":

  test "t_unavailable_package_fails_with_platform_reason":
    # Point the Scoop probe at a directory that does not exist so no branch
    # of the chain can touch a real Scoop install on the developer's box.
    let sandbox = getTempDir() / "pmc1-no-such-scoop-root"
    putEnv("SCOOP", sandbox)
    putEnv("REPRO_TEST_SCOOP_OVERRIDE", sandbox / "no-such-scoop.exe")
    defer:
      delEnv("SCOOP")
      delEnv("REPRO_TEST_SCOOP_OVERRIDE")

    # The declaration itself must be visible, or the rest of the test is
    # vacuous: it would be asserting the absence of a gate that was never
    # armed.
    let availability = packageAvailability("chocolatey")
    check availability.declared
    check availability.platforms.len == 1
    check availability.platforms[0].os == poWindows
    check availability.message.len > 0

    var cat = openProductionCatalog()

    # ---- (1)-(5) synthetic LINUX host -----------------------------------
    var raised = false
    try:
      discard chainResolvePackage(cat, "chocolatey",
        chain = @[cakNix, cakBuiltin, cakPath],
        hostCpu = pcX86_64, hostOs = poLinux)
    except EPackageUnavailableOnPlatform as err:
      raised = true
      let msg = err.msg

      # (2) the package, the declaration, and the host, in one sentence.
      check msg.contains("chocolatey")
      check msg.contains("is declared for windows only")
      check msg.contains("this host is linux")

      # (3) the author's own reason, verbatim.
      check msg.contains("Chocolatey is a Windows package manager")
      check err.authorMessage.len > 0
      check msg.contains(err.authorMessage)

      # (4) neither piece of unfollowable advice survives.
      check not msg.contains("adapter chain exhausted")
      check not msg.contains("available on PATH")
      check not msg.contains("adapter_preference")

      # (5) the same facts, structured.
      check err.packageId == "chocolatey"
      check err.declaredPlatforms == "windows only"
      check err.hostTarget == "linux"
    except EAdapterChainExhausted as err:
      checkpoint "still failing with the generic chain diagnostic: " & err.msg
      check false
    check raised

    # ---- (6) the gate is host-sensitive ---------------------------------
    # On a windows host the declaration is satisfied, so resolution proceeds
    # into the chain exactly as it did before PMC-1. chocolatey has no
    # built-in VersionedProvisioning catalog (it is a DSL ``tarball`` arm), so
    # the chain exhausts — the OLD error, which is the correct one here.
    var chainRaised = false
    var platformRaised = false
    try:
      discard chainResolvePackage(cat, "chocolatey",
        chain = @[cakBuiltin],
        hostCpu = pcX86_64, hostOs = poWindows)
    except EPackageUnavailableOnPlatform:
      platformRaised = true
    except EAdapterChainExhausted:
      chainRaised = true
    check chainRaised
    check not platformRaised
