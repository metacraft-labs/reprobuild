## DSL-port M9.R.15q.9.2 — stdlib provisioning stub for ``ksysguard``.
##
## ``ksysguard`` (libksysguard in upstream) is the Plasma system-load
## meter framework (CPU, memory, network, sensors).  REQUIRED dep on
## plasma-workspace's ``find_package(KSysGuard REQUIRED)`` probe; the
## Plasma panel's system-tray applets pull live sensor data through it.
##
## ## Provisioning channel — nixpkgs#kdePackages.libksysguard

import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package `ksysguard`:
  provisioning:
    nixPackage "nixpkgs#kdePackages.libksysguard", executablePath = "lib/libKSysGuardFormatter.so",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash
