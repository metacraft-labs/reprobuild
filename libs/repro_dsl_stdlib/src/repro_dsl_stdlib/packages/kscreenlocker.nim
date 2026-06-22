## DSL-port M9.R.15q.4.5 — stdlib provisioning stub for ``kscreenlocker``.
##
## ``kscreenlocker`` is the Plasma lock-screen daemon kwin's session
## lifecycle hooks invoke at lock time. REQUIRED by kwin when
## ``KWIN_BUILD_SCREENLOCKER=ON`` (default).
##
## ## Provisioning channel — nixpkgs#kdePackages.kscreenlocker

import repro_project_dsl

package `kscreenlocker`:
  provisioning:
    nixPackage "nixpkgs#kdePackages.kscreenlocker", executablePath = "lib/libKScreenLocker.so",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="
