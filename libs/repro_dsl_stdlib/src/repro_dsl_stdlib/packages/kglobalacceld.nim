## DSL-port M9.R.15q.4.5 — stdlib provisioning stub for ``kglobalacceld``.
##
## ``kglobalacceld`` is the Plasma global-accelerator daemon kwin's
## global-shortcut surface connects to. REQUIRED by kwin when
## ``KWIN_BUILD_GLOBALSHORTCUTS=ON`` (default).
##
## ## Provisioning channel — nixpkgs#kdePackages.kglobalacceld

import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package `kglobalacceld`:
  provisioning:
    nixPackage "nixpkgs#kdePackages.kglobalacceld", executablePath = "libexec/kglobalacceld",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash
