## DSL-port M9.R.15q.9.2 — stdlib provisioning stub for ``plasma5support``.
##
## ``plasma5support`` (Plasma5Support in upstream) is the bridging
## library that exposes Plasma-5-era APIs to Plasma-6 widgets / plugins
## (kept around so existing Plasma-5 third-party plasmoids keep
## working).  REQUIRED dep on plasma-workspace's
## ``find_package(Plasma5Support REQUIRED)`` probe.
##
## ## Provisioning channel — nixpkgs#kdePackages.plasma5support

import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package `plasma5support`:
  provisioning:
    nixPackage "nixpkgs#kdePackages.plasma5support", executablePath = "lib/libPlasma5Support.so",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash
