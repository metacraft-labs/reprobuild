## DSL-port M9.R.15e.12 — stdlib provisioning stub for ``json-glib``.
##
## json-glib is the GLib-style GObject JSON parser + serializer library
## consumed by gdm's greeter for messaging the Wayland session over the
## D-Bus configuration channel.  Pinned by gdm 47.x's
## ``meson.build:67`` (`json-glib-1.0`).
##
## ## Provisioning channel — nixpkgs#json-glib

import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package `json-glib`:
  provisioning:
    nixPackage "nixpkgs#json-glib",
      executablePath = "lib/pkgconfig/json-glib-1.0.pc",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash
