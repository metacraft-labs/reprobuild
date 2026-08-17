## DSL-port M9.R.15e.4 — stdlib provisioning stub for ``libei``.
##
## libei (Emulated Input) is the userspace emulated-input protocol
## library — Wayland's modern alternative to XTest for remote-desktop
## input injection.  Pinned by mutter 47.x's ``src/meson.build:131``
## as an unconditional dependency (the meson check happens even when
## ``remote_desktop=false`` because the dep symbol is referenced in
## the compositor's core type definitions).
##
## ## Provisioning channel — nixpkgs#libei
##
## A single nixpkgs entry ships BOTH ``libei-1.0.pc`` AND
## ``libeis-1.0.pc`` (server-side counterpart) under
## ``lib/pkgconfig/``.  See the sibling ``libeis`` stub which points
## at the same nixpkgs derivation; both stubs resolve to the same
## /nix/store output so PKG_CONFIG_PATH covers both pc names.

import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package `libei`:
  provisioning:
    nixPackage "nixpkgs#libei", executablePath = "lib/pkgconfig/libei-1.0.pc",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash
