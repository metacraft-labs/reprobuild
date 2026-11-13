## Platform-And-Microarchitecture-Constraints PMC-1 (Package-Model.md
## §"GAP: a package cannot declare the platforms it exists on") — a package
## that DECLARED it cannot exist here must not reach the ``path`` kind.
##
## This is the most important test in the milestone, and the reason is that
## the failure it guards does not look like a failure. ``path`` is the last
## kind in the default selection policy and it resolves "the executable is
## already on PATH". So an unavailable package did not merely fail with a
## confusing message before PMC-1 — on a host that happens to carry a
## same-named binary it RESOLVED, silently, to something nobody declared.
##
## GM4b: resolution is ``realization_selection.selectRealization`` (reached
## here through ``package_catalog.resolveProfilePackage``, the entry point a
## home profile uses). The availability gate runs before any kind.
##
## Assertions:
##   1. A ``chocolatey`` executable really is discoverable on the PATH this
##      test builds. Without this the rest is vacuous.
##   2. CONTROL: with the SAME planted binary, the policy ``[path]`` and a
##      synthetic *windows* host target (where the declaration is satisfied),
##      resolution selects ``path`` and points at the planted file. This
##      proves the PATH inventory can see it, so assertion (3) is about the
##      availability gate and nothing else.
##   3. With the only change being a synthetic *linux* host target,
##      resolution FAILS with ``EPlatformUnavailable``. It does not resolve,
##      and it does not fall through.
##   4. The failure is raised even when ``path`` is the ONLY kind in the
##      policy, so it cannot be an artefact of some earlier kind refusing
##      first — the gate runs before the policy is walked.
##   5. The failure carries no policy steps: no kind was consulted, so the
##      PATH probe never ran.
##   6. The full default policy behaves the same on the unavailable target.
##
## Falsifiable: this test FAILS if the ``path`` step ever becomes reachable
## for a declared-unavailable package — e.g. by moving the
## ``isAvailableOn`` gate in ``selectRealization`` after the policy loop, or
## deleting it: assertion (3) then resolves quietly through ``path`` to the
## planted stub — the exact silent-wrong-thing outcome.
##
## Hermetic: the target comes from ``realizationTargetFor`` (a synthetic
## host target), and the planted binary lives in a temp dir that is removed
## afterwards; PATH is restored on exit. No mocks: the real PATH inventory
## probe (``pathInventoryProbe``) and the real stdlib ``chocolatey``
## definition.

import std/[options, os, strutils, tempfiles, unittest]

import repro_home_apply/package_catalog

suite "PMC-1 — an unavailable package never reaches the PATH inventory":

  test "t_unavailable_package_does_not_fall_through_to_path":
    let scratch = createTempDir("repro-pmc1-path-", "")
    defer: removeDir(scratch)

    let binDir = scratch / "bin"
    createDir(binDir)

    # Plant a same-named executable, exactly the hazard the spec describes.
    let planted =
      when defined(windows): binDir / "chocolatey.cmd"
      else: binDir / "chocolatey"
    let body =
      when defined(windows): "@echo not-the-real-chocolatey\r\n"
      else: "#!/bin/sh\necho not-the-real-chocolatey\n"
    writeFile(planted, body)
    when not defined(windows):
      setFilePermissions(planted, {fpUserRead, fpUserWrite, fpUserExec})

    let originalPath = getEnv("PATH")
    putEnv("PATH", binDir & PathSep & originalPath)
    defer:
      putEnv("PATH", originalPath)

    # ---- (1) the hazard is really present -------------------------------
    let discovered = findExe("chocolatey")
    check discovered.len > 0
    check discovered.extractFilename.startsWith("chocolatey")

    # The declaration must be armed, or (3) proves nothing.
    check packageAvailability("chocolatey").declared

    let inventory = HostInventory(probePath: pathInventoryProbe())
    let windowsHost = realizationTargetFor(pcX86_64, poWindows, isHost = true)
    let linuxHost = realizationTargetFor(pcX86_64, poLinux, isHost = true)

    # ---- (2) CONTROL: on a satisfied host, path DOES resolve it ---------
    block controlWindowsHost:
      let resolution = resolveProfilePackage("chocolatey", windowsHost,
        @[rkPath], inventory = inventory)
      check resolution.selection.kind == rkPath
      check resolution.selection.ambient
      check resolution.selection.pathExecutable.extractFilename.startsWith(
        "chocolatey")

    # ---- (3)(4)(5) same binary, same policy, unavailable host -----------
    block unavailableLinuxHost:
      var raised = false
      var didResolve = false
      try:
        discard resolveProfilePackage("chocolatey", linuxHost, @[rkPath],
          inventory = inventory)
        didResolve = true
      except EPlatformUnavailable as err:
        raised = true
        check err.packageName == "chocolatey"
        check err.msg.contains("the target is linux")
        # (5) the gate ran before any kind: no step, so no PATH probe.
        check err.steps.len == 0
      check raised
      check not didResolve

    # ---- (6) the full default policy behaves the same -------------------
    block fullPolicyUnavailableHost:
      var raised = false
      try:
        discard resolveProfilePackage("chocolatey", linuxHost,
          DefaultSelectionPolicy, inventory = inventory)
      except EPlatformUnavailable:
        raised = true
      except EMissingRealization as err:
        checkpoint "reached the policy instead of the gate: " & err.msg
      check raised
