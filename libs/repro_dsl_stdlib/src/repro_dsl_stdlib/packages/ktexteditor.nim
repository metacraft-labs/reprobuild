## DSL-port M9.R.15q.9.8 — stdlib provisioning stub for ``ktexteditor``.
##
## ``ktexteditor`` (KTextEditor in upstream KF6) is the powerful text-
## editing widget framework Kate / KWrite are built on.  REQUIRED dep
## on plasma-workspace's
## ``find_package(KF6 ... COMPONENTS TextEditor REQUIRED)`` probe.
##
## ## Provisioning channel — nixpkgs#kdePackages.ktexteditor

import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package `ktexteditor`:
  provisioning:
    nixPackage "nixpkgs#kdePackages.ktexteditor", executablePath = "lib/libKF6TextEditor.so",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash
