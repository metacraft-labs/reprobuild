## DSL-port M9.R.15q.4.5 — stdlib provisioning stub for ``hwdata``.
##
## ``hwdata`` is the hardware ID database (PCI vendor IDs, monitor
## vendor IDs, USB IDs). kwin uses it at runtime to map monitor
## hardware vendor IDs to full names. Optional dep in kwin's
## CMakeLists.txt.
##
## ## Provisioning channel — nixpkgs#hwdata

import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package `hwdata`:
  provisioning:
    nixPackage "nixpkgs#hwdata", executablePath = "share/hwdata/pnp.ids",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash
