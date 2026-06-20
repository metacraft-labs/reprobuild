## DSL-port M9.R.15d.1 — stdlib provisioning stub for ``libegl-headers``.
##
## Pure-header package surfacing the Khronos EGL/EGL extension headers
## (``EGL/egl.h`` + ``EGL/eglext.h`` + ``EGL/eglplatform.h``). Consumed
## by libepoxy (when built with ``egl=yes``) and downstream by every
## GTK4 / Qt6 OpenGL backend that resolves EGL function pointers at
## runtime through libepoxy or its own loader.
##
## ## Why this stub exists separately from a full mesa from-source
## recipe
##
## libepoxy's meson build only needs the EGL **header set** at
## configure + compile time; the actual ``libEGL.so`` is dlopen'd at
## runtime by the consumer (gtk4 / qt6 / etc.) against the host's
## mesa-driver installation. Shipping mesa as a from-source recipe
## costs ~30 minutes of build wall-time and pulls in llvm + libdrm +
## libglvnd as transitive deps. Splitting "EGL headers" off keeps the
## v1 closure honest about what libepoxy actually needs.
##
## ## Provisioning channel — nixpkgs#libglvnd.dev
##
## libglvnd (the OpenGL/EGL/GLX vendor-neutral dispatch library)
## ships the canonical Khronos EGL headers in its ``dev`` output:
##   /nix/store/...-libglvnd-1.7.0-dev/include/EGL/
##     ├── egl.h
##     ├── eglext.h
##     └── eglplatform.h
##
## The ``out`` output carries only ``lib/`` — the headers live
## exclusively under the ``dev`` multi-output. The selector
## ``nixpkgs#libglvnd.dev`` resolves to the dev output.
##
## ## TODO(M9.R.15e+)
##
## Widen the channel set with a tarball entry for the Khronos
## EGL-Registry headers (https://github.com/KhronosGroup/EGL-Registry)
## as a universal fall-through on non-Nix hosts.

import repro_project_dsl

package `libegl-headers`:
  provisioning:
    nixPackage "nixpkgs#libglvnd.dev", executablePath = "include/EGL/egl.h",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="
