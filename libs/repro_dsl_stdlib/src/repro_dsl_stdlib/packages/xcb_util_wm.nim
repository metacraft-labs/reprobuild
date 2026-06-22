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

package `xcb-util-wm`:
  provisioning:
    nixPackage "nixpkgs#xorg.xcbutilwm^*", executablePath = "lib/libxcb-icccm.so",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="
