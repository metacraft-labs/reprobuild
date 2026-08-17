## DSL-port M9.R.15j.2 — stdlib provisioning stub for ``kcodecs``.
##
## Lifted from the M9.R.10a exec-name audit pass shape: this package
## surfaces as a ``buildDeps:`` entry on the kcompletion source recipe
## (kcompletion's KHistoryComboBox + KCompletion proper consume KF6Codecs
## for text-encoding helpers). The stub registers the canonical name + a
## Nix provisioning channel so the resolver can find a usable adapter
## under ``--tool-provisioning=from-source`` / ``--tool-provisioning=nix``.

import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package `kcodecs`:
  provisioning:
    nixPackage "nixpkgs#kdePackages.kcodecs", executablePath = "lib/libKF6Codecs.so",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash
