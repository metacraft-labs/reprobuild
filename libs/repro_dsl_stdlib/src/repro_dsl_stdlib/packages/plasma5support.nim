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

package `plasma5support`:
  provisioning:
    nixPackage "nixpkgs#kdePackages.plasma5support", executablePath = "lib/libPlasma5Support.so",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="
