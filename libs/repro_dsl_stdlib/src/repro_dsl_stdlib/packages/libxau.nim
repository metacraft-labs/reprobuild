## DSL-port M9.R.15q.4.3 — stdlib provisioning stub for ``libxau``.
##
## ``libxau`` ships ``libXau.so`` + ``xau.pc`` — the X authentication
## file routines. libxcb's ``xcb.pc`` declares ``Requires.private:
## xau``, so any pkg-config probe that goes through xcb (including
## ECM's ``FindXCB.cmake`` cascade) needs xau on PKG_CONFIG_PATH or
## the probe fails with ``Package 'xau', required by 'xcb', not found``.
##
## ## Provisioning channel — nixpkgs#xorg.libXau^*

import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package `libxau`:
  provisioning:
    nixPackage "nixpkgs#xorg.libXau^*", executablePath = "lib/libXau.so",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash
