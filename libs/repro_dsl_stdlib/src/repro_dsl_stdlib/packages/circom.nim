## Circom -- zk-SNARK circuit compiler from iden3.
##
## No ``nixpkgs#circom`` is available at the catalog-wide pinned
## nixpkgs rev; the metacraft-labs ``nix-blockchain-development``
## flake carries an out-of-tree ``self'.packages.circom`` instead.
## To keep this catalog entry self-contained we pull the raw Linux
## binary from upstream's GitHub Release (iden3/circom is itself a
## Rust project; the published binary is the canonical artefact for
## Linux). The version matches the ``nix-blockchain-development``
## pin (``packages/circom/default.nix`` -> ``version = "2.1.5"``)
## so the dev-shell-via-nix and dev-shell-via-reprobuild paths agree
## on which compiler the recorder sees.
##
## The ``bus_type`` fixtures inside codetracer-circom-recorder pull
## in circom 2.2.3 via ``CIRCOM_2_2_BIN``; that secondary binary is
## a per-test runtime input, not a dev-env tool, so it stays out of
## this catalog entry and is the recorder's responsibility to
## provision at test time.

import repro_project_dsl

package circom:
  provisioning:
    tarball url = "https://github.com/iden3/circom/releases/download/v2.1.5/circom-linux-amd64",
      sha256 = "8bbceaa993e757998808cfe9966daa80da04f41505f22c989c62f66e8ce2dcb2",
      archiveType = "binary",
      executablePath = "bin/circom"
