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
##   * linux x86_64 tarball: a metacraft-labs release asset in
##     reprobuild-packages holding the install tree of the ``zlib`` source
##     recipe (zlib 1.3.1 built with the pinned Bootlin gcc 15.3.0). It is an
##     archive because a from-source realization is ``local-only`` (not
##     cache-portable), while an archive arm is substitutable from the shared
##     binary cache on every host.
##   * Every other host and mode: no archive arm. Under tarball provisioning a
##     tool with no arm for the platform is realized from its source recipe,
##     and ``zlib-dev`` resolves to the ``zlib`` recipe in reprobuild-packages
##     (``FromSourceRecipeAliases`` in ``repro_tool_profiles``).

import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package `zlib-dev`:
  provisioning:
    nixPackage "nixpkgs#zlib^*", executablePath = "include/zlib.h",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash
    tarball url = "https://github.com/metacraft-labs/reprobuild-packages/releases/download/zlib-dev-1.3.1-linux-x86_64/zlib-dev-1.3.1-linux-x86_64.tar.xz",
      sha256 = "45994537e6330d5b200505d8f7f36d418313527ec7b8642e1d6b4db03670c9ea",
      archiveType = "tar.xz",
      executablePath = "include/zlib.h",
      version = "1.3.1",
      packageId = "zlib-dev@1.3.1",
      cpu = "x86_64",
      os = "linux",
      lockIdentity = "tarball:zlib-dev@1.3.1:linux-x86_64:sha256:45994537e6330d5b200505d8f7f36d418313527ec7b8642e1d6b4db03670c9ea"
