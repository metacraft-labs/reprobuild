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
##
## M9.R.16.1 — pinned to nixpkgs release-24.11 tip
## (``5ab036a8d97cb9476fbe81b09076e6e91d15e1b6``) where accountsservice
## is built against glib 2.82.1. The default rolling rev
## (``addf7cf...``) ships an accountsservice built against glib
## 2.84+, which exports symbols (``g_variant_builder_init_static``)
## that ``glib2Source`` (pinned at 2.82.5) does not provide; the
## resulting link error in ``daemon/gdm-session-worker`` was:
## ``undefined reference to 'g_variant_builder_init_static'``.

import repro_project_dsl

package `accountsservice`:
  provisioning:
    nixPackage "nixpkgs#accountsservice",
      executablePath = "lib/pkgconfig/accountsservice.pc",
      nixpkgsRev = "5ab036a8d97cb9476fbe81b09076e6e91d15e1b6",
      nixpkgsNarHash = "sha256-kNf+obkpJZWar7HZymXZbW+Rlk3HTEIMlpc6FCNz0Ds="
