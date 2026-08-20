## Platform-And-Microarchitecture-Constraints PMC-1 (Package-Model.md
## §"GAP: a package cannot declare the platforms it exists on") — a package
## that DECLARED it cannot exist here must not reach the ``cakPath`` adapter.
##
## This is the most important test in the milestone, and the reason is that
## the failure it guards does not look like a failure. ``cakPath`` is the last
## adapter in every default chain and it resolves "the executable is already
## on PATH". So an unavailable package did not merely fail with a confusing
## message before PMC-1 — on a host that happens to carry a same-named binary
## it RESOLVED, silently, to something nobody declared. The spec calls this
## out explicitly: "an unguarded dependency does not fail at the catalog, it
## falls through to probing PATH. On a host that happens to have a same-named
## binary it would resolve to *that*."
##
## The test plants exactly that hazard and asserts the resolver refuses it.
##
## Assertions:
##   1. A ``chocolatey`` executable really is discoverable on the PATH this
##      test builds. Without this the rest is vacuous — it would be asserting
##      a refusal that had nothing to refuse.
##   2. CONTROL: with the SAME planted binary, the SAME ``[cakPath]`` chain,
##      and a synthetic *windows* host (where the declaration is satisfied),
##      resolution succeeds via ``cakPath`` and points at the planted file.
##      This proves the PATH adapter can see it, so assertion (3) is about
##      the availability gate and nothing else.
##   3. With the only change being a synthetic *linux* host, resolution
##      FAILS with ``EPackageUnavailableOnPlatform``. It does not resolve, and
##      it does not fall through.
##   4. The failure is raised even when ``cakPath`` is the ONLY adapter in the
##      chain, so it cannot be an artefact of some earlier adapter refusing
##      first — the gate runs before the chain, not inside it.
##   5. No resolution is produced at all: the returned value is never
##      observed, and in particular never carries a ``sourcePath`` pointing
##      at the planted binary.
##   6. The LEGACY ``resolvePackage`` entry point is gated identically. That
##      is the route this package actually takes in production —
##      ``realizeViaProductionCatalog`` only uses the chain for packages with
##      a built-in catalog registration or a pinned version, and ``chocolatey``
##      has neither — and both of its exits end at the PATH probe.
##
## Falsifiable: this test FAILS if the ``cakPath`` step ever becomes reachable
## for a declared-unavailable package. Confirmed by removing the gate from
## ``chainResolvePackage``: assertion (3) then resolves quietly through
## ``cakPath`` to the planted stub — the exact silent-wrong-thing outcome.
##
## Hermetic: the host target comes from the ``hostCpu`` / ``hostOs``
## parameters, and the planted binary lives in a temp dir that is removed
## afterwards; PATH is restored on exit.

import std/[options, os, osproc, strutils, tempfiles, unittest]

import repro_dsl_stdlib/packages_schema
import repro_dsl_stdlib/catalog_registry
import repro_home_apply/package_catalog

suite "PMC-1 — an unavailable package never reaches the PATH adapter":

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
      discard execShellCmd("chmod +x " & quoteShell(planted))

    let originalPath = getEnv("PATH")
    putEnv("PATH", binDir & PathSep & originalPath)
    # Keep the Scoop branch inert so nothing consults a real install.
    putEnv("SCOOP", scratch / "no-such-scoop-root")
    putEnv("REPRO_TEST_SCOOP_OVERRIDE", scratch / "no-such-scoop.exe")
    defer:
      putEnv("PATH", originalPath)
      delEnv("SCOOP")
      delEnv("REPRO_TEST_SCOOP_OVERRIDE")

    # ---- (1) the hazard is really present -------------------------------
    let discovered = findExe("chocolatey")
    check discovered.len > 0
    check discovered.extractFilename.startsWith("chocolatey")

    # The declaration must be armed, or (3) proves nothing.
    check packageAvailability("chocolatey").declared

    var cat = openProductionCatalog()

    # ---- (2) CONTROL: on a satisfied host, cakPath DOES resolve it ------
    block controlWindowsHost:
      let resolution = chainResolvePackage(cat, "chocolatey",
        chain = @[cakPath], hostCpu = pcX86_64, hostOs = poWindows)
      check resolution.adapter == cakPath
      check resolution.sourcePath.len > 0
      check resolution.sourcePath.extractFilename.startsWith("chocolatey")

    # ---- (3)(4)(5) same binary, same chain, unavailable host ------------
    block unavailableLinuxHost:
      var raised = false
      var resolvedAnyway = CatalogResolution()
      var didResolve = false
      try:
        resolvedAnyway = chainResolvePackage(cat, "chocolatey",
          chain = @[cakPath], hostCpu = pcX86_64, hostOs = poLinux)
        didResolve = true
      except EPackageUnavailableOnPlatform as err:
        raised = true
        check err.packageId == "chocolatey"
        check err.msg.contains("this host is linux")
      check raised
      check not didResolve
      # (5) nothing was produced. ``resolvedAnyway`` still holds the default
      # ``CatalogResolution``: no package id was bound and, decisively, no
      # ``sourcePath`` — which is the field a ``cakPath`` hit populates with
      # the planted binary.
      check resolvedAnyway.packageId.len == 0
      check resolvedAnyway.sourcePath.len == 0

    # ---- (6) the LEGACY resolver is gated too ---------------------------
    # ``realizeViaProductionCatalog`` only routes through the adapter chain
    # when the package has a built-in catalog registration or a pinned
    # version. ``chocolatey`` has neither — it is a DSL ``tarball`` arm — so
    # in production it takes the legacy ``resolvePackage`` path, whose every
    # exit ends at the PATH probe. Gating only the chain would have left the
    # hole open on precisely the route this package travels.
    block legacyResolverControl:
      let resolution = resolvePackage(cat, "chocolatey",
        hostCpu = pcX86_64, hostOs = poWindows)
      check resolution.adapter == cakPath
      check resolution.sourcePath.extractFilename.startsWith("chocolatey")

    block legacyResolverGated:
      var raised = false
      try:
        discard resolvePackage(cat, "chocolatey",
          hostCpu = pcX86_64, hostOs = poLinux)
      except EPackageUnavailableOnPlatform as err:
        raised = true
        check err.msg.contains("this host is linux")
      check raised

    # ---- (4 cont.) the full default-shaped chain behaves the same -------
    block fullChainUnavailableHost:
      var raised = false
      try:
        discard chainResolvePackage(cat, "chocolatey",
          chain = @[cakNix, cakBuiltin, cakPath],
          hostCpu = pcX86_64, hostOs = poLinux)
      except EPackageUnavailableOnPlatform:
        raised = true
      except EAdapterChainExhausted as err:
        checkpoint "reached the chain instead of the gate: " & err.msg
      check raised
