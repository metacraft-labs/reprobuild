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
import repro_dsl_stdlib/nixpkgs_pin

package `libxcb`:
  provisioning:
    nixPackage "nixpkgs#xorg.libxcb^*", executablePath = "lib/libxcb.so",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash
