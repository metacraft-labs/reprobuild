## DSL-port M9.R.15q.4.1 — stdlib provisioning stub for
## ``xcb-util``.
##
## ``xcb-util`` is the umbrella XCB-utilities package shipping
## ``libxcb-util.so`` — the convenience routines shared across the
## xcb-util-* family (atom interning + struct helpers).
##
## ## Provisioning channel — nixpkgs#xorg.xcbutil^*

import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package `xcb-util`:
  provisioning:
    nixPackage "nixpkgs#xorg.xcbutil^*", executablePath = "lib/libxcb-util.so",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash
