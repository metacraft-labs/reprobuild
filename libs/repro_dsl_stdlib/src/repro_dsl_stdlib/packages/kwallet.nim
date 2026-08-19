## DSL-port M9.R.15q.9.2 — stdlib provisioning stub for ``kwallet``.
##
## ``kwallet`` (KWallet in upstream KF6) is KDE's secret-storage
## framework (passwords + keys).  REQUIRED dep on plasma-workspace's
## ``find_package(KF6Wallet REQUIRED)`` probe; the Plasma session
## leader integrates kwallet's unlock-on-login flow.
##
## ## Provisioning channel — nixpkgs#kdePackages.kwallet

import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package `kwallet`:
  provisioning:
    nixPackage "nixpkgs#kdePackages.kwallet", executablePath = "lib/libKF6Wallet.so",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash
