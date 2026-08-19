## DSL-port M9.R.15q.4.5 — stdlib provisioning stub for ``libepoxy``.
##
## ``libepoxy`` is the OpenGL/GLES/EGL/GLX runtime-dispatch library
## (replaces glew). REQUIRED by kwin's CMakeLists.txt
## (``find_package(epoxy 1.3)``); kwin uses libepoxy to load GL
## function pointers in the compositor render thread.
##
## ## Provisioning channel — nixpkgs#libepoxy^*

import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package `libepoxy`:
  provisioning:
    nixPackage "nixpkgs#libepoxy^*", executablePath = "lib/libepoxy.so",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash
