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
import repro_dsl_stdlib/nixpkgs_pin

package `libsystemd`:
  provisioning:
    nixPackage "nixpkgs#systemdMinimal.dev",
      executablePath = "lib/pkgconfig/libsystemd.pc",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash
