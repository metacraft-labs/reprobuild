## DSL-port M9.R.15e.4 — stdlib provisioning stubs for ``gl`` / ``egl``
## / ``glesv2`` (the libglvnd OpenGL vendor-neutral dispatch family).
##
## The libglvnd ``-dev`` output ships THREE pkg-config files used by
## OpenGL consumers:
##
##   * ``gl.pc``       — desktop OpenGL (libGL)
##   * ``egl.pc``      — EGL window-system layer (libEGL)
##   * ``glesv2.pc``   — OpenGL ES 2 (libGLESv2)
##
## All three resolve to the same nixpkgs derivation
## (``nixpkgs#libglvnd``); the resolver dedups the
## ``pkgConfigSearchList`` entry so the pc files are reachable once.
## Each stub is named after the pkg-config dependency token mutter /
## gtk / qt query, so the resolver's name -> stub map works without
## the recipe having to know that all three come from the same nix
## derivation.
##
## ## Sibling: libegl-headers
##
## The M9.R.15d.1 ``libegl-headers`` stub exposes the same nixpkgs
## derivation under a different name — used by libepoxy when it
## needs the Khronos EGL header set but not the full libEGL runtime.
## These M9.R.15e.4 stubs are for consumers that pkg-config-query
## ``gl`` / ``egl`` / ``glesv2`` directly.

import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package `gl`:
  provisioning:
    nixPackage "nixpkgs#libglvnd", executablePath = "lib/pkgconfig/gl.pc",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

package `egl`:
  provisioning:
    nixPackage "nixpkgs#libglvnd", executablePath = "lib/pkgconfig/egl.pc",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

package `glesv2`:
  provisioning:
    nixPackage "nixpkgs#libglvnd", executablePath = "lib/pkgconfig/glesv2.pc",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash
