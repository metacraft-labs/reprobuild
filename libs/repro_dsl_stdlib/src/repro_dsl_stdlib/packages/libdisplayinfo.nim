## DSL-port M9.R.15q.4.5 — stdlib provisioning stub for ``libdisplay-info``.
##
## ``libdisplay-info`` is the EDID + DisplayID parser kwin's drm
## backend uses to discover monitor capabilities. REQUIRED by kwin
## (``pkg_check_modules(libdisplayinfo REQUIRED ...)``).
##
## ## Provisioning channel — nixpkgs#libdisplay-info^*

import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package `libdisplay-info`:
  provisioning:
    nixPackage "nixpkgs#libdisplay-info^*", executablePath = "lib/libdisplay-info.so",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash
