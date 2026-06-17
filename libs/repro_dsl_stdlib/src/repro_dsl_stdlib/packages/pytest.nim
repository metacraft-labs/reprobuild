## ``pytest`` — Python test runner.
##
## ## M7 (reprobuild Windows migration) note: NO Windows tarball entry
##
## ``pytest`` is a pure-Python package distributed via PyPI; it has no
## standalone Windows binary distribution to point a ``tarball`` block
## at. The provisioning surface stays Nix-only here. Recipes that
## need ``pytest`` on Windows install it into a workspace-local
## ``<repro-store>/uv-tools/`` dir via ``uv tool install pytest``,
## using the ``uv`` + ``python-dev`` tarball pair (both real
## tarball-provisioned packages) as the bootstrap. See
## ``codetracer-python-recorder/repro.nim`` for the canonical
## bootstrap build edge.

import repro_project_dsl

package pytest:
  provisioning:
    nixPackage "nixpkgs#python3Packages.pytest", executablePath = "bin/pytest",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="
