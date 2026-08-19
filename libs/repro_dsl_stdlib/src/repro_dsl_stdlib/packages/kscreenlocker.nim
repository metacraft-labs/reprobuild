## DSL-port M9.R.15q.4.5 — stdlib provisioning stub for ``kscreenlocker``.
##
## ``kscreenlocker`` is the Plasma lock-screen daemon kwin's session
## lifecycle hooks invoke at lock time. REQUIRED by kwin when
## ``KWIN_BUILD_SCREENLOCKER=ON`` (default).
##
## ## Provisioning channel — nixpkgs#kdePackages.kscreenlocker

import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package `kscreenlocker`:
  provisioning:
    nixPackage "nixpkgs#kdePackages.kscreenlocker", executablePath = "lib/libKScreenLocker.so",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash
