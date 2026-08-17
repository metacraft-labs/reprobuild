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
import repro_dsl_stdlib/nixpkgs_pin

package `xcb-util-renderutil`:
  provisioning:
    nixPackage "nixpkgs#xorg.xcbutilrenderutil^*", executablePath = "lib/libxcb-render-util.so",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash
