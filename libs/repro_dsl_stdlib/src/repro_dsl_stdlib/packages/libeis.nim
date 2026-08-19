## DSL-port M9.R.15e.4 — stdlib provisioning stub for ``libeis``.
##
## libeis is the server-side counterpart of libei (Emulated Input
## Server) — used by Wayland compositors to receive emulated input
## events from libei clients (remote-desktop tools, accessibility
## controllers, ...). Pinned by mutter 47.x's
## ``src/meson.build:130`` as an unconditional dependency.
##
## ## Provisioning channel — nixpkgs#libei
##
## The nixpkgs libei derivation ships BOTH ``libei-1.0.pc`` (client)
## AND ``libeis-1.0.pc`` (server) under ``lib/pkgconfig/``.  This stub
## points at the same /nix/store output as the sibling ``libei``
## stub; the resolver dedups the pkgConfigSearchList entry so the
## .pc file is reachable once.

import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package `libeis`:
  provisioning:
    nixPackage "nixpkgs#libei", executablePath = "lib/pkgconfig/libeis-1.0.pc",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash
