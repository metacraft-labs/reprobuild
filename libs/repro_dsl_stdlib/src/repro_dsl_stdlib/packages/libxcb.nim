## DSL-port M9.R.15q.4.1 — stdlib provisioning stub for ``libxcb``.
##
## ``libxcb`` is the modern XCB (X C Binding) client library —
## a replacement / supplement for Xlib offering async + thread-safe
## X11 protocol access. KF6 / Plasma modules that include the X11
## backend depend on libxcb directly (xcb-keysyms, xcb-icccm, etc.
## sit on top of it).
##
## ## Provisioning channel — nixpkgs#xorg.libxcb^*
##
## The ``^*`` multi-output realization brings the .pc + headers (dev
## output) AND ``libxcb.so`` (out output) per the M9.R.14f.10
## pattern.

import repro_project_dsl

package `libxcb`:
  provisioning:
    nixPackage "nixpkgs#xorg.libxcb^*", executablePath = "lib/libxcb.so",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="
