## Bootstrap provisioning adapter for XCB protocol data.

import repro_project_dsl

package `xcb-proto`:
  provisioning:
    nixPackage "nixpkgs#xcb-proto", executablePath = "share/xcb/xproto.xml",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="
