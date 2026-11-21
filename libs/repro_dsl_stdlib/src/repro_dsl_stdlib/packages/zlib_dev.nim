## ``zlib-dev`` -- zlib's DEVELOPMENT channel: ``zlib.h`` / ``zconf.h`` on the
## include path and ``libz`` on the library path. A selector of its own for the
## reason ``zstd-dev`` is one (``packages/zstd_dev.nim``): "I compile against
## ``zlib.h``" is a different need from "I run a zlib tool", and a realization
## that supplies only a shared runtime object fails open, as a C compile error
## far from the dependency.
##
## ## Why it exists
##
## nim-libvterm's repo-local contribution used to supply zlib's headers and
## library from a repo-local Nix expression. Provisioning it natively needs a
## package every repo can name. Measured 2026-11-20: the pinned Bootlin
## x86-64 glibc toolchain archive carries ``lib/libz.so.1`` and
## ``lib/libz.so.1.3.2`` only -- no ``zlib.h``, no ``zconf.h``, no ``libz.so``
## and no ``libz.a`` -- so the compiler arm cannot stand in for it on any
## platform.
##
## ## Realizations
##
##   * Nix-capable hosts: ``nixpkgs#zlib^*`` (every output), with the HEADER as
##     the declared ``executablePath`` so a realization without it is refused
##     by name at resolution time -- the ``zstd-dev`` mechanism.
##   * Every other host and mode: no archive arm. Under tarball provisioning a
##     tool with no arm for the platform is realized from its source recipe,
##     and ``zlib-dev`` resolves to the ``zlib`` recipe in reprobuild-packages
##     (``FromSourceRecipeAliases`` in ``repro_tool_profiles``), built from
##     the upstream release archive and cached in the shared binary cache.
##
## No third-party binary is pinned here on purpose: zlib is small and its
## source recipe already exists, so a prebuilt archive would add a trust
## surface and a per-platform pin for nothing.

import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package `zlib-dev`:
  provisioning:
    nixPackage "nixpkgs#zlib^*", executablePath = "include/zlib.h",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash
