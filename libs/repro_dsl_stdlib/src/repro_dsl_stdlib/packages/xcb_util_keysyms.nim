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

package `xcb-util-keysyms`:
  provisioning:
    nixPackage "nixpkgs#xorg.xcbutilkeysyms^*", executablePath = "lib/libxcb-keysyms.so",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="
