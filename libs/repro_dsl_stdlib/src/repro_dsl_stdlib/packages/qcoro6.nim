## DSL-port M9.R.15q.9.2 — stdlib provisioning stub for ``qcoro6``.
##
## ``qcoro6`` (QCoro on upstream) is the C++20 coroutines wrapper
## library plasma-workspace + several KF6 modules link against for
## async-await-style Qt task composition. Surfaces as a REQUIRED dep
## on plasma-workspace's CMakeLists.txt ``find_package(QCoro6 ...)``
## probe.
##
## ## Provisioning channel — nixpkgs#kdePackages.qcoro

import repro_project_dsl

package `qcoro6`:
  provisioning:
    nixPackage "nixpkgs#kdePackages.qcoro", executablePath = "lib/libQCoro6Core.a",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="
