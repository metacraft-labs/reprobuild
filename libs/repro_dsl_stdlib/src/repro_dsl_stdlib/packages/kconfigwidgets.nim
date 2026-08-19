## DSL-port M9.R.15j.4 — stdlib provisioning stub for ``kconfigwidgets``.
##
## Lifted to support the kxmlgui cascade; the package surfaces as a
## ``buildDeps:`` entry on kxmlgui.

import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package `kconfigwidgets`:
  provisioning:
    nixPackage "nixpkgs#kdePackages.kconfigwidgets", executablePath = "lib/libKF6ConfigWidgets.so",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash
