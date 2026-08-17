## DSL-port M9.R.15q.4.1 — stdlib provisioning stub for
## ``xcb-util-keysyms``.
##
## ``xcb-util-keysyms`` ships ``libxcb-keysyms.so`` — the standard
## keysym definitions + keysym-to-keycode conversion routines XCB
## clients use for key-binding lookup. kwindowsystem's X11 backend
## (KX11Extras' global-shortcut surface) consumes this.
##
## ## Provisioning channel — nixpkgs#xorg.xcbutilkeysyms^*

import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package `xcb-util-keysyms`:
  provisioning:
    nixPackage "nixpkgs#xorg.xcbutilkeysyms^*", executablePath = "lib/libxcb-keysyms.so",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash
