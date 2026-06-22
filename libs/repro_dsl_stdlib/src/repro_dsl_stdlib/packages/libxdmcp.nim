## DSL-port M9.R.15q.4.6 — stdlib provisioning stub for ``libxdmcp``.
##
## ``libxdmcp`` ships ``libXdmcp.so`` + ``xdmcp.pc`` — the X Display
## Manager Control Protocol library. libxcb's ``xcb.pc`` declares
## ``Requires.private: xau >= 0.99.2 xdmcp``, so any pkg-config probe
## that goes through xcb (libxkbcommon's xcb-xkb probe, Qt6's XCB
## QPA plugin, kwin's X11 backend) needs xdmcp on PKG_CONFIG_PATH.
##
## ## Provisioning channel — nixpkgs#xorg.libXdmcp^*

import repro_project_dsl

package `libxdmcp`:
  provisioning:
    nixPackage "nixpkgs#xorg.libXdmcp^*", executablePath = "lib/libXdmcp.so",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="
