## Platform-And-Microarchitecture-Constraints PMC-1 (Package-Model.md
## §"GAP: a package cannot declare the platforms it exists on" → "Proposed
## shape") — an unguarded reference to a package that DECLARED it cannot exist
## on this host fails naming the PLATFORM, not the adapter chain.
##
## Before PMC-1, resolution had no notion of declared availability. A
## Windows-only package on Linux walked every adapter, found nothing, and
## raised a generic "nothing could supply this" diagnostic whose remediation
## (catalogue it, put it on PATH, reorder the preference) is impossible for a
## Windows package manager on Linux.
##
## GM4b: the gate lives in ``realization_selection.selectRealization`` (here
## reached through ``package_catalog.resolveProfilePackage``) and raises
## ``EPlatformUnavailable``, a type distinct from ``EMissingRealization``.
##
## This test asserts on the message CONTENT, deliberately: the diagnostic IS
## the milestone.
##
## Assertions:
##   1. ``chocolatey`` for a synthetic linux target raises
##      ``EPlatformUnavailable`` — not ``EMissingRealization``.
##   2. The message names the package, the declared platform set, and the
##      target: "chocolatey is declared for windows only; the target is linux".
##   3. The message carries the author-supplied ``msg`` from the declaration.
##   4. The message does NOT say "no realization" and does NOT advise making
##      the executable available on PATH or editing ``adapterPreference``.
##   5. The structured fields (``packageName`` / ``declaredPlatforms`` /
##      ``target`` / ``authorMessage``) carry the same facts.
##   6. The gate is TARGET-SENSITIVE, not a blanket refusal: for a windows
##      target the same package resolves (chocolatey's windows ``tarball``
##      realization is selected).
##
## Falsifiable: delete the availability gate in ``selectRealization`` and
## assertion (1) trips — the raise becomes ``EMissingRealization``. Blank the
## author ``msg`` on the declaration and (3) trips.
##
## Hermetic: the target is passed explicitly (``realizationTargetFor``), and
## no host inventory is supplied, so this runs identically on any machine.

import std/[options, strutils, unittest]

import repro_home_apply/package_catalog

suite "PMC-1 — an unavailable package fails naming the platform":

  test "t_unavailable_package_fails_with_platform_reason":
    # The declaration itself must be visible, or the rest is vacuous.
    let availability = packageAvailability("chocolatey")
    check availability.declared
    check availability.platforms.len == 1
    check availability.platforms[0].os == poWindows
    check availability.message.len > 0

    let linuxTarget = realizationTargetFor(pcX86_64, poLinux, mlX86_64_v1)
    let windowsTarget = realizationTargetFor(pcX86_64, poWindows, mlX86_64_v1)

    # ---- (1)-(5) synthetic LINUX target ---------------------------------
    var raised = false
    try:
      discard resolveProfilePackage("chocolatey", linuxTarget,
        DefaultSelectionPolicy)
    except EPlatformUnavailable as err:
      raised = true
      let msg = err.msg

      # (2) the package, the declaration, and the target, in one sentence.
      check msg.contains("chocolatey")
      check msg.contains("is declared for windows only")
      check msg.contains("the target is linux")

      # (3) the author's own reason, verbatim.
      check msg.contains("Chocolatey is a Windows package manager")
      check err.authorMessage.len > 0
      check msg.contains(err.authorMessage)

      # (4) neither piece of unfollowable advice survives.
      check not msg.contains("no realization of package")
      check not msg.contains("available on PATH")
      check not msg.contains("adapterPreference")

      # (5) the same facts, structured.
      check err.packageName == "chocolatey"
      check err.declaredPlatforms == "windows only"
      check err.target == "x86_64-linux"
    except EMissingRealization as err:
      checkpoint "still failing with the generic diagnostic: " & err.msg
      check false
    check raised

    # ---- (6) the gate is target-sensitive -------------------------------
    var platformRaised = false
    var selected = false
    try:
      let resolution = resolveProfilePackage("chocolatey", windowsTarget,
        @[rkTarball])
      selected = resolution.selection.kind == rkTarball
      check resolution.selection.tarball.os == "windows"
    except EPlatformUnavailable:
      platformRaised = true
    check selected
    check not platformRaised
