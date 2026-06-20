## DSL-port M9.R.15g.2 — stdlib provisioning stub for ``libsystemd``.
##
## libsystemd is the systemd client library (``libsystemd.so`` +
## ``systemd/sd-login.h`` + the rest of the ``sd-*`` headers).
## gdm 47.x's daemon links against libsystemd unconditionally for its
## logind-provider integration (``src/common/gdm-common.c`` includes
## ``systemd/sd-login.h`` to query the current session class via
## ``sd_pid_get_session`` / ``sd_session_get_class``).
##
## ## Provisioning channel — nixpkgs#systemdMinimal.dev
##
## nixpkgs's full ``systemd`` package is split-output (``out`` / ``dev``
## / ``man`` / ...).  The ``dev`` output ships the headers + the
## ``libsystemd.pc`` pkg-config file.  We point at the ``dev`` output
## so the compile-time include path picks up ``systemd/sd-login.h``.

import repro_project_dsl

package `libsystemd`:
  provisioning:
    nixPackage "nixpkgs#systemdMinimal.dev",
      executablePath = "lib/pkgconfig/libsystemd.pc",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="
