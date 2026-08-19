## Bootstrap provisioning adapter for XCB protocol data.

import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package `xcb-proto`:
  provisioning:
    nixPackage "nixpkgs#xcb-proto", executablePath = "share/xcb/xproto.xml",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash
