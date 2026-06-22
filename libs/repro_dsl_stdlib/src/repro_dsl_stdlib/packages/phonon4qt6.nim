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

package `phonon4qt6`:
  provisioning:
    nixPackage "nixpkgs#kdePackages.phonon", executablePath = "lib/libPhonon4Qt6.so",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="
