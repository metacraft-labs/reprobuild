## DSL-port M9.R.15q.9.2 — stdlib provisioning stub for ``kprison``.
##
## ``kprison`` (Prison in upstream KF6) is the barcode-rendering Qt
## library (QR + Code39 + Aztec + etc.) Plasma uses for the
## "share via QR code" widget.  Surfaces as a REQUIRED dep on
## plasma-workspace's ``find_package(KF6Prison REQUIRED)`` probe.
##
## ## Provisioning channel — nixpkgs#kdePackages.prison

import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package `kprison`:
  provisioning:
    nixPackage "nixpkgs#kdePackages.prison", executablePath = "lib/libKF6Prison.so",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash
