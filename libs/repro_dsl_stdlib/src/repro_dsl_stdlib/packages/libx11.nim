## DSL-port M9.R.15q.4.1 — stdlib provisioning stub for ``libx11``.
##
## ``libx11`` is the canonical Xlib client library — the historical
## X Window System protocol library that ships ``libX11.so`` and the
## ``X11/`` header tree (``X11/Xlib.h`` + extensions). KF6 / Plasma
## modules that opt into the X11 backend (kwindowsystem with
## ``KWINDOWSYSTEM_X11=ON`` exposes ``KX11Extras``; downstream
## consumers like plasma-framework, kwin's X11 session glue, etc.)
## resolve ``find_package(X11 REQUIRED)`` against this surface.
##
## ## Provisioning channel — nixpkgs#xorg.libX11^*
##
## The ``^*`` multi-output realization brings the .pc + headers (dev
## output) AND ``libX11.so`` (out output) onto the resolver's path
## set per the M9.R.14f.10 pattern. ``find_package(X11)`` walks both.

import repro_project_dsl

package `libx11`:
  provisioning:
    nixPackage "nixpkgs#xorg.libX11^*", executablePath = "lib/libX11.so",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="
