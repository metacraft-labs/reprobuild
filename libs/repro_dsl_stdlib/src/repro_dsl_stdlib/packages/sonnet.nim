## DSL-port M9.R.15q.9.9 — stdlib provisioning stub for ``sonnet``.
##
## ``sonnet`` (KF6Sonnet in upstream) is the KF6 spell-checking
## library. Surfaces as a TRANSITIVE find_package probe via
## ktextwidgets's CMake config (``KF6TextWidgets`` depends on
## ``KF6Sonnet`` at configure time).
##
## ## Provisioning channel — nixpkgs#kdePackages.sonnet

import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package `sonnet`:
  provisioning:
    nixPackage "nixpkgs#kdePackages.sonnet", executablePath = "lib/libKF6SonnetCore.so",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash
