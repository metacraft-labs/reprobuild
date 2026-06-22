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

package `qrencode`:
  provisioning:
    nixPackage "nixpkgs#qrencode^*", executablePath = "lib/libqrencode.so",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="
