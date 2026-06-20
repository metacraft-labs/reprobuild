## DSL-port M9.R.15e.4 — stdlib provisioning stub for ``libgudev``.
##
## libgudev is the GLib-style GObject wrapper around libudev — gives
## C/GObject consumers a typed event-driven device-hotplug API instead
## of the raw libudev FD-pump interface.  Pinned by mutter 47.x's
## ``src/meson.build:237`` (gated on ``native_backend=true``); also
## consumed by gnome-settings-daemon, gnome-shell, NetworkManager.
##
## ## Provisioning channel — nixpkgs#libgudev
##
## Standard nixpkgs entry; the multi-output package ships
## ``gudev-1.0.pc`` under the ``-dev`` output's ``lib/pkgconfig/``.

import repro_project_dsl

package `gudev`:
  provisioning:
    nixPackage "nixpkgs#libgudev", executablePath = "lib/pkgconfig/gudev-1.0.pc",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="
