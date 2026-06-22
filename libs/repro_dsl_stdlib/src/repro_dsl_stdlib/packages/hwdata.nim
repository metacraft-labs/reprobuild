## DSL-port M9.R.15q.4.5 — stdlib provisioning stub for ``hwdata``.
##
## ``hwdata`` is the hardware ID database (PCI vendor IDs, monitor
## vendor IDs, USB IDs). kwin uses it at runtime to map monitor
## hardware vendor IDs to full names. Optional dep in kwin's
## CMakeLists.txt.
##
## ## Provisioning channel — nixpkgs#hwdata

import repro_project_dsl

package `hwdata`:
  provisioning:
    nixPackage "nixpkgs#hwdata", executablePath = "share/hwdata/pci.ids",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="
