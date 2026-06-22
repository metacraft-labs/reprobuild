## DSL-port M9.R.15q.4.1 — stdlib provisioning stub for
## ``xcb-util``.
##
## ``xcb-util`` is the umbrella XCB-utilities package shipping
## ``libxcb-util.so`` — the convenience routines shared across the
## xcb-util-* family (atom interning + struct helpers).
##
## ## Provisioning channel — nixpkgs#xorg.xcbutil^*

import repro_project_dsl

package `xcb-util`:
  provisioning:
    nixPackage "nixpkgs#xorg.xcbutil^*", executablePath = "lib/libxcb-util.so",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="
