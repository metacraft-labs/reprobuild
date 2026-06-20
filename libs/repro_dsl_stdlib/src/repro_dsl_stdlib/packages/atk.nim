## DSL-port M9.R.15e.4 — stdlib provisioning stub for ``atk``.
##
## ATK (Accessibility Toolkit) is the GNOME accessibility interface
## library — abstract accessibility APIs that GTK widgets implement
## so screen readers (orca / accerciser / brltty) can introspect a
## running GUI.  Pinned by mutter 47.x's ``src/meson.build:126`` as
## an unconditional dependency.
##
## ## Provisioning channel — nixpkgs#atk
##
## Modern nixpkgs (24.11+) routes ``atk`` through the at-spi2-core
## package (the GNOME accessibility stack was consolidated upstream;
## see ``nixpkgs/pkgs/development/libraries/atk`` aliasing to
## ``at-spi2-core``).  The .pc file ``atk.pc`` ships under the
## ``-dev`` output's ``lib/pkgconfig/``.
##
## ## TODO(M9.R.15f+)
##
## ATK is small (~200 KB compiled) and a from-source recipe would be
## straightforward; the stub keeps the v1 GNOME closure tractable
## while preserving the option of a swap-in later.

import repro_project_dsl

package `atk`:
  provisioning:
    nixPackage "nixpkgs#atk", executablePath = "lib/pkgconfig/atk.pc",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="
