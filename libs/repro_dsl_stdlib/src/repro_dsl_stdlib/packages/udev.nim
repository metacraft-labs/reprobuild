## DSL-port M9.R.15e.4 — stdlib provisioning stub for ``udev``.
##
## ``udev`` is the dynamic device-management daemon shipped by systemd
## (or eudev as an independent fork).  mutter's KMS/DRM backend
## queries ``dependency('udev')`` (not ``libudev``) in
## ``src/meson.build:238`` to pick up the ``udev.pc`` file that
## ships udev rules + helper-program paths.
##
## ## Provisioning channel — nixpkgs#systemd^*
##
## systemd ships ``udev.pc`` under ``-dev``'s ``share/pkgconfig/``
## (different output + dir than ``libudev.pc`` which lives under
## ``-dev/lib/pkgconfig/``).  The resolver's M9.R.14e.1 share/pkgconfig
## channel picks it up automatically.

import repro_project_dsl

package `udev`:
  provisioning:
    nixPackage "nixpkgs#systemd^*",
      executablePath = "share/pkgconfig/udev.pc",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="
