## DSL-port M9.R.15q.9.2 — stdlib provisioning stub for ``kprison``.
##
## ``kprison`` (Prison in upstream KF6) is the barcode-rendering Qt
## library (QR + Code39 + Aztec + etc.) Plasma uses for the
## "share via QR code" widget.  Surfaces as a REQUIRED dep on
## plasma-workspace's ``find_package(KF6Prison REQUIRED)`` probe.
##
## ## Provisioning channel — nixpkgs#kdePackages.prison

import repro_project_dsl

package `kprison`:
  provisioning:
    nixPackage "nixpkgs#kdePackages.prison", executablePath = "lib/libKF6Prison.so",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="
