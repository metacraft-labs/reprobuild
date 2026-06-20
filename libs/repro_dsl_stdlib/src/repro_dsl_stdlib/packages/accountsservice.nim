## DSL-port M9.R.15e.10 — stdlib provisioning stub for
## ``accountsservice``.
##
## accountsservice is the D-Bus daemon that exposes a typed API over
## ``/etc/passwd`` + ``/etc/shadow`` + per-user GSettings (so login
## managers, polkit dialogs, and account-settings UIs don't need to
## parse those files directly).  Pinned by gdm 47.x's
## ``meson.build:69`` as a hard dependency (``>= 0.6.35``).
##
## ## Provisioning channel — nixpkgs#accountsservice
##
## Standard nixpkgs entry; the multi-output package ships
## ``accountsservice.pc`` under the ``-dev`` output's
## ``lib/pkgconfig/``.

import repro_project_dsl

package `accountsservice`:
  provisioning:
    nixPackage "nixpkgs#accountsservice",
      executablePath = "lib/pkgconfig/accountsservice.pc",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="
