## DSL-port M9.R.15j.4 — stdlib provisioning stub for ``kcolorscheme``.
##
## Lifted to support the kconfigwidgets / kxmlgui cascade; the package
## surfaces as a ``buildDeps:`` entry on kconfigwidgets which kxmlgui
## consumes transitively.

import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package `kcolorscheme`:
  provisioning:
    nixPackage "nixpkgs#kdePackages.kcolorscheme", executablePath = "lib/libKF6ColorScheme.so",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash
