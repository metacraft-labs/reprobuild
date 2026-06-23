## DSL-port M9.R.28.4 — stdlib provisioning stub for ``audit``.
##
## ``audit`` is the Linux audit-subsystem userspace (libaudit.so +
## auditd + ausearch + audisp-*) referenced by shadow-utils and
## util-linux as an optional build dep for security-event logging.
##
## Routed through nixpkgs#audit which ships libaudit.so under
## ``$prefix/lib/`` (no separate -dev split — Nix puts headers next
## to the library).

import repro_project_dsl

package `audit`:
  provisioning:
    nixPackage "nixpkgs#audit", executablePath = "lib/libaudit.so",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="
