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
import repro_dsl_stdlib/nixpkgs_pin

package `xcb-util-cursor`:
  provisioning:
    nixPackage "nixpkgs#xorg.xcbutilcursor^*", executablePath = "lib/libxcb-cursor.so",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash
