## DSL-port M9.R.15q.4.3 — stdlib provisioning stub for ``xorgproto``.
##
## ``xorgproto`` is the X Window System protocol headers package
## (X11/X.h + X11/Xproto.h + X11/Xatom.h + X11/keysymdef.h +
## X11/extensions/* protocol-level type declarations). CMake's
## builtin ``FindX11.cmake`` probes ``find_path(X11_X11_INCLUDE_PATH
## X11/X.h ...)`` — but ``X.h`` ships in xorgproto, NOT in
## libX11. Without this stub kwindowsystem's KWINDOWSYSTEM_X11=ON
## build fails with ``Could NOT find X11 (missing:
## X11_X11_INCLUDE_PATH)``.
##
## ## Provisioning channel — nixpkgs#xorg.xorgproto
##
## ``xorgproto`` is a single-output package (no dev/out split); the
## headers ship in the default output. No ``^*`` needed.

import repro_project_dsl

package `xorgproto`:
  provisioning:
    nixPackage "nixpkgs#xorg.xorgproto", executablePath = "include/X11/X.h",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="
