## DSL-port M9.R.15q.9.2 — stdlib provisioning stub for ``phonon4qt6``.
##
## ``phonon4qt6`` (Phonon in upstream) is the KDE multimedia
## abstraction library (audio/video playback dispatcher).  REQUIRED
## dep on plasma-workspace's ``find_package(Phonon4Qt6 REQUIRED)``
## probe; the Plasma notification daemon routes notification sounds
## through phonon.
##
## ## Provisioning channel — nixpkgs#kdePackages.phonon

import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package `phonon4qt6`:
  provisioning:
    nixPackage "nixpkgs#kdePackages.phonon", executablePath = "lib/libphonon4qt6.so",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash
