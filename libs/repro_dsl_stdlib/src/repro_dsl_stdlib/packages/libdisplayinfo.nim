## DSL-port M9.R.15q.4.5 — stdlib provisioning stub for ``libdisplay-info``.
##
## ``libdisplay-info`` is the EDID + DisplayID parser kwin's drm
## backend uses to discover monitor capabilities. REQUIRED by kwin
## (``pkg_check_modules(libdisplayinfo REQUIRED ...)``).
##
## ## Provisioning channel — nixpkgs#libdisplay-info^*

import repro_project_dsl

package `libdisplay-info`:
  provisioning:
    nixPackage "nixpkgs#libdisplay-info^*", executablePath = "lib/libdisplay-info.so",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="
