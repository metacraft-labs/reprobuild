## DSL-port M9.R.15q.11.1 — stdlib provisioning stub for ``libnl``.
##
## ``libnl`` (libnl-3 family) is the userspace netlink library Linux
## tooling uses to talk to the in-kernel netlink subsystem. ksysguard's
## CMakeLists.txt declares
## ``find_package(NL)`` + ``set_package_properties(NL PROPERTIES TYPE
## REQUIRED ...)`` for socket-info / sock_diag gathering — without it
## ``feature_summary(REQUIRED_PACKAGES_NOT_FOUND
## FATAL_ON_MISSING_REQUIRED_PACKAGES)`` aborts the configure run with
## ``REQUIRED package(s) are missing``.
##
## The KDE-vendored ``FindNL.cmake`` shipped with ksysguard's source
## tree uses ``pkg_check_modules(NL3 libnl-3.0 libnl-route-3.0)`` to
## locate libnl-3 + the libnl-route-3 subpackage; both ship as
## ``.pc`` files under the dev output of ``nixpkgs#libnl``.
##
## ## Provisioning channel — nixpkgs#libnl^*
##
## The ``^*`` multi-output realization brings the .pc + headers (dev
## output) AND the runtime ``libnl-3.so`` + ``libnl-route-3.so``
## (out output) per the M9.R.14f.10 pattern.

import repro_project_dsl

package `libnl`:
  provisioning:
    nixPackage "nixpkgs#libnl^*", executablePath = "lib/libnl-3.so",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="
