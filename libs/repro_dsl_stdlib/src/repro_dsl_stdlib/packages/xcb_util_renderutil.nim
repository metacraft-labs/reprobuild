## DSL-port M9.R.15q.4.1 — stdlib provisioning stub for
## ``xcb-util-renderutil``.
##
## ``xcb-util-renderutil`` ships ``libxcb-render-util.so`` — the
## convenience routines for the XCB Render extension (PictFormat
## lookup, glyph composition setup). Plasma's KWin compositor X11
## glue layer consumes this for the Render-extension fallback path
## (when EGL/GBM is unavailable).
##
## ## Provisioning channel — nixpkgs#xorg.xcbutilrenderutil^*

import repro_project_dsl

package `xcb-util-renderutil`:
  provisioning:
    nixPackage "nixpkgs#xorg.xcbutilrenderutil^*", executablePath = "lib/libxcb-render-util.so",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="
