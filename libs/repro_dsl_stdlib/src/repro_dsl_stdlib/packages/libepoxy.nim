## DSL-port M9.R.15q.4.5 — stdlib provisioning stub for ``libepoxy``.
##
## ``libepoxy`` is the OpenGL/GLES/EGL/GLX runtime-dispatch library
## (replaces glew). REQUIRED by kwin's CMakeLists.txt
## (``find_package(epoxy 1.3)``); kwin uses libepoxy to load GL
## function pointers in the compositor render thread.
##
## ## Provisioning channel — nixpkgs#libepoxy^*

import repro_project_dsl

package `libepoxy`:
  provisioning:
    nixPackage "nixpkgs#libepoxy^*", executablePath = "lib/libepoxy.so",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="
