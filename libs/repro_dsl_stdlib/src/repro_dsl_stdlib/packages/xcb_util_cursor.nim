## DSL-port M9.R.15q.4.1 — stdlib provisioning stub for
## ``xcb-util-cursor``.
##
## ``xcb-util-cursor`` ships ``libxcb-cursor.so`` — the
## ``Xcursor``-compatible cursor-theme loader for XCB clients.
## Qt6 X11 platform plugin + KWin's X11 glue use this for the
## cursor-theme integration with the standard XDG cursor specs.
##
## ## Provisioning channel — nixpkgs#xorg.xcbutilcursor^*

import repro_project_dsl

package `xcb-util-cursor`:
  provisioning:
    nixPackage "nixpkgs#xorg.xcbutilcursor^*", executablePath = "lib/libxcb-cursor.so",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="
