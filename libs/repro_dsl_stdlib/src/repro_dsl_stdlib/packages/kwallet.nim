## DSL-port M9.R.15q.9.2 — stdlib provisioning stub for ``kwallet``.
##
## ``kwallet`` (KWallet in upstream KF6) is KDE's secret-storage
## framework (passwords + keys).  REQUIRED dep on plasma-workspace's
## ``find_package(KF6Wallet REQUIRED)`` probe; the Plasma session
## leader integrates kwallet's unlock-on-login flow.
##
## ## Provisioning channel — nixpkgs#kdePackages.kwallet

import repro_project_dsl

package `kwallet`:
  provisioning:
    nixPackage "nixpkgs#kdePackages.kwallet", executablePath = "lib/libKF6Wallet.so",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="
