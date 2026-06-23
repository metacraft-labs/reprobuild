## DSL-port M9.R.15r.1 — stdlib provisioning stub for ``mesa-gl-headers``.
##
## Pure-header package surfacing the mesa-specific GL / EGL extension
## headers that the Khronos-only ``libglvnd`` ``-dev`` output does NOT
## ship:
##
##   * ``EGL/eglmesaext.h``      — Mesa EGL extension declarations
##   * ``EGL/eglext_angle.h``    — Google ANGLE EGL extension declarations
##   * ``GL/internal/dri_interface.h`` — DRI interface header
##
## Consumed by mutter 47.x (via ``meta/meta-backend-types.h`` ->
## ``EGL/eglmesaext.h``) and downstream by any compositor /
## OpenGL-renderer that pokes the mesa-specific extension namespace
## (gnome-shell, wlroots EGL backend, Qt6 EGL platform, ...). The
## sibling ``libegl-headers`` stub covers the Khronos EGL header set
## (``egl.h`` / ``eglext.h`` / ``eglplatform.h``); ``mesa-gl-headers``
## fills the mesa-extension gap.
##
## ## Why this stub exists separately from the mesa driver derivation
##
## ``nixpkgs#mesa`` builds the full Gallium-driver closure (~30 minutes
## of wall-time, pulls in llvm + libdrm + libglvnd) and does NOT ship
## a multi-output ``dev`` variant carrying public headers. Upstream
## nixpkgs splits the mesa header set into its own derivation
## (``nixpkgs#mesa-gl-headers``) so compositor recipes that only need
## the extension declarations at compile-time can pull a slim
## header-only payload without the full mesa driver build.
##
## ## Provisioning channel — nixpkgs#mesa-gl-headers
##
## Confirmed locally on the eli-wsl smoke host:
##
##   /nix/store/.../mesa-gl-headers-25.0.1/include/EGL/eglmesaext.h
##   /nix/store/.../mesa-gl-headers-25.0.1/include/EGL/eglext_angle.h
##   /nix/store/.../mesa-gl-headers-25.0.1/include/GL/internal/dri_interface.h
##
## The M9.R.14e.1 from-source resolver threads the package's
## ``include`` dir onto ``CPATH`` at action-fork time via the
## ``executablePath = "include/EGL/eglmesaext.h"`` anchor below; the
## anchor is matched against the package's ``out`` output and the
## resolver's CPATH-thread pass walks back to ``$out/include``.

import repro_project_dsl

package `mesa-gl-headers`:
  provisioning:
    nixPackage "nixpkgs#mesa-gl-headers", executablePath = "include/EGL/eglmesaext.h",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="
