## The provider-compile toolchain does not wait for a provisioning mode, on
## any host.
##
## A recipe's ``defaultToolProvisioning`` is readable only after its provider
## is compiled, so the compiler for that compile cannot come from the recipe's
## mode. ``ensureBootstrapToolchainEnv`` used to fire only under ``tarball``
## and ``from-source``, which in practice meant only when
## ``REPRO_TOOL_PROVISIONING`` said so in advance. Measured 2026-09-23 on a
## Windows host without the DIY ``env.ps1``: ``repro shell`` compiled the
## workspace recipe with ``nim`` from ``PATH``, found none, and failed with
## ``CreateProcessW failed (2)``, although the recipe declares ``tarball``.
##
## Windows was ungated first (reprobuild 1dcf1516b). Linux and macOS kept the
## gate because they had no route that worked in every mode: Linux resolved
## through Nix only, macOS had no arm at all. Now every host has one
## (``bootstrapNimRoute`` / ``bootstrapCRoute``), so the bootstrap provisions
## in every mode everywhere (reprobuild-specs
## Distribution-And-Packaging.milestones.org, M5, rule 2).
##
## Restore ``mode != tpmTarball and mode != tpmFromSource: return`` (or the
## old per-host ``when``) and the second case fails for ``path``, ``nix``,
## ``scoop`` and the unspecified mode; drop a host's route and the third
## fails on that host.
##
## No mocks: these are the real policy procs.

import std/[strutils, unittest]

import repro_tool_profiles

suite "bootstrap toolchain provisioning":
  test "tarball and from-source provision on every host":
    check bootstrapToolchainProvisioned(tpmTarball)
    check bootstrapToolchainProvisioned(tpmFromSource)

  test "every other mode provisions too, on every host":
    for mode in [tpmUnspecified, tpmPathOnly, tpmNix, tpmScoop]:
      checkpoint $mode
      check bootstrapToolchainProvisioned(mode)

  test "this host has a route for both compilers":
    let nimRoute = bootstrapNimRoute()
    let cRoute = bootstrapCRoute()
    checkpoint "nim: " & describeBootstrapNimRoute(nimRoute)
    checkpoint "cc: " & describeBootstrapCRoute(cRoute,
      bootstrapSystemCCompilers)
    when defined(windows):
      check nimRoute == bnrArchive
      check cRoute == bcrArchive
    elif defined(macosx):
      # The official darwin archive for THIS cpu, not the Linux one that
      # used to be the fall-through.
      check nimRoute == bnrArchive
      check cRoute == bcrXcode
      let nim = bootstrapNimToolUse()
      check nim.tarballProvisioning.len == 2
      for entry in nim.tarballProvisioning:
        check entry.os == "macos"
        check "macosx_" in entry.url
    elif defined(linux):
      if bootstrapHostHasNix():
        check nimRoute == bnrNix
        check cRoute == bcrNix
      else:
        check nimRoute == bnrSource
        check cRoute == bcrSystem
    else:
      check nimRoute == bnrSource
      check cRoute == bcrSystem
    # Whatever the route, the description names something concrete rather
    # than "none".
    check "of which" notin describeBootstrapNimRoute(nimRoute)
    check "of which" notin describeBootstrapCRoute(cRoute,
      bootstrapSystemCCompilers)
