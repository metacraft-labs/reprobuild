## DSL-port M9.R.15q.4.1 — stdlib provisioning stub for
## ``xcb-util-wm``.
##
## ``xcb-util-wm`` ships ``libxcb-icccm.so`` + ``libxcb-ewmh.so`` —
## the ICCCM (Inter-Client Communication Conventions Manual) +
## EWMH (Extended Window Manager Hints) helper routines window
## managers + window-management libraries use to read / write the
## standard X11 hints.
##
## ## Provisioning channel — nixpkgs#xorg.xcbutilwm^*

import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package `xcb-util-wm`:
  provisioning:
    nixPackage "nixpkgs#xorg.xcbutilwm^*", executablePath = "lib/libxcb-icccm.so",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash
