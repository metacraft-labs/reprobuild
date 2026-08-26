## ``dpkg-deb`` — the Debian package builder backend for the DSL packaging
## layer (``packaging/producers.nim``'s ``deb`` producer).
##
## ``packages/dpkg.nim`` already declares the ``dpkg`` front-end tool
## (``bin/dpkg``), but a ``.deb`` PRODUCER invokes the low-level
## ``dpkg-deb --build`` binary directly by its own tool identity so the
## engine's ``toolIdentityRefs`` resolver prepends the right bin dir to
## the packaging action's PATH at fork time. Both binaries ship in the
## same nixpkgs ``dpkg`` derivation; this file simply exposes the
## ``dpkg-deb`` identity as its own package frame (mirroring how the
## engine treats ``tar`` / ``unzip`` as distinct identities even when
## they share a coreutils-adjacent origin).
##
## On Debian/Ubuntu hosts ``dpkg-deb`` is already on ``PATH`` (part of the
## base ``dpkg`` package), so ``--tool-provisioning=path`` resolves it
## without Nix — which is exactly the mode the M0 sample-project test
## uses. The Nix channel is the cross-platform happy path (a macOS or
## Fedora host can still emit a ``.deb`` because reprobuild provisions
## ``dpkg-deb`` from nixpkgs).

import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package `dpkg-deb`:
  provisioning:
    nixPackage "nixpkgs#dpkg", executablePath = "bin/dpkg-deb",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash
