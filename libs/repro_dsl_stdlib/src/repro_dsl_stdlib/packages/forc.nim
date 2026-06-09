## Forc -- the Fuel/Sway compiler driver.
##
## No ``nixpkgs#forc`` is available at the catalog-wide pinned
## nixpkgs rev; the metacraft-labs ``nix-blockchain-development``
## flake builds it from source (FuelLabs/sway, pinned to
## ``v0.70.3`` -- see ``packages/forc/default.nix``). To keep this
## catalog entry self-contained we pull the matching upstream
## ``forc-binaries`` tarball (the FuelLabs release artefact bundles
## ``forc``, ``forc-fmt``, ``forc-lsp``, ``forc-deploy``, and
## ``forc-run`` under one archive root).
##
## ``executablePath`` points at the top-level ``forc`` binary that
## ships at the archive root after extraction; the other companion
## binaries land alongside it and resolve via PATH once the
## prefix's ``bin/`` is on the dev shell.

import repro_project_dsl

package forc:
  provisioning:
    tarball url = "https://github.com/FuelLabs/sway/releases/download/v0.70.3/forc-binaries-linux_amd64.tar.gz",
      sha256 = "572a61acae22887e28b1f3222b98951ae4cf253cab1d6c5668f71aee239f07cc",
      archiveType = "tar.gz",
      executablePath = "forc-binaries/forc",
      stripComponents = 0
