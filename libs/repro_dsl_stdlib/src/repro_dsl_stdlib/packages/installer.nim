## ``installer`` — PyPA's reference wheel installer (PEP 427 / PEP 660).
##
## Used by the Python convention's M20 A5 console-script wrapper shim
## sub-graph: ``python3 -m installer`` unpacks a built wheel into a
## per-member ``install/`` scratch directory and materialises the
## per-``[project.scripts]``-entry runnable launchers. Without this
## package importable from the bundled Python the convention's A5
## action fails with ``ModuleNotFoundError: No module named 'installer'``.
##
## Nix attribute: ``nixpkgs#python3Packages.installer`` mirrors the
## existing ``python3Packages.{pytest,flake8}`` shape — the same nixpkgs
## pin used by the rest of the Python toolchain. ``executablePath`` is
## intentionally empty because the consumer is ``python3 -m installer``
## (a Python module entry-point) rather than a standalone binary —
## reprobuild's provisioning layer treats this catalog entry as
## "make the module importable from PYTHONPATH"; the bin/installer
## launcher that ships in the nix store as part of this package is
## incidental and not relied on.

import repro_project_dsl

package installer:
  provisioning:
    nixPackage "nixpkgs#python3Packages.installer", executablePath = "bin/installer",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="
