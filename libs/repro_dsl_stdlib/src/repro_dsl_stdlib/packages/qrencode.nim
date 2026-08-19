## DSL-port M9.R.15q.10.7d — stdlib provisioning stub for ``qrencode``.
##
## libqrencode is a small C library that generates QR-code 2D barcodes.
## kprison 6.10.0's CMakeLists declares
## ``find_package(QRencode REQUIRED)`` — without it,
## ``feature_summary(REQUIRED_PACKAGES_NOT_FOUND
## FATAL_ON_MISSING_REQUIRED_PACKAGES)`` aborts the configure run.
##
## ## Provisioning channel — nixpkgs#qrencode

import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package `qrencode`:
  provisioning:
    nixPackage "nixpkgs#qrencode^*", executablePath = "lib/libqrencode.so",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash
