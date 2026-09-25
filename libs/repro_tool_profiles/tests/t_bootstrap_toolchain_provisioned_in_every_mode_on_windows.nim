## The provider-compile toolchain does not wait for a provisioning mode.
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
## On Windows the bootstrap now provisions in every mode
## (reprobuild-specs/Distribution-And-Packaging.milestones.org, M5, rule 2).
## Linux and macOS keep the old gate until they have a route that works in
## every mode; ``bootstrapToolchainProvisioned`` records that, and so does
## this test.
##
## Restore ``mode != tpmTarball and mode != tpmFromSource: return`` and the
## Windows case fails for ``path``, ``nix``, ``scoop`` and the unspecified
## mode.

import std/unittest

import repro_tool_profiles

suite "bootstrap toolchain provisioning":
  test "tarball and from-source provision on every host":
    check bootstrapToolchainProvisioned(tpmTarball)
    check bootstrapToolchainProvisioned(tpmFromSource)

  test "every other mode provisions on Windows, and only there":
    for mode in [tpmUnspecified, tpmPathOnly, tpmNix, tpmScoop]:
      checkpoint $mode
      when defined(windows):
        check bootstrapToolchainProvisioned(mode)
      else:
        check not bootstrapToolchainProvisioned(mode)
