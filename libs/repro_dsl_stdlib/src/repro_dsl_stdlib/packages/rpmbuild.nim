## ``rpmbuild`` — the RPM package builder backend for the DSL packaging
## layer (``packaging/producers.nim``'s ``rpm`` producer).
##
## ``rpmbuild -bb <spec>`` turns a generated ``.spec`` + a populated
## ``%buildroot`` into a binary ``.rpm``. The producer invokes it by bare
## name and threads ``rpmbuild`` through ``toolIdentityRefs`` so the
## engine resolves the bin dir at fork time.
##
## nixpkgs ships ``rpmbuild`` inside the ``rpm`` derivation
## (``bin/rpmbuild``). On a Fedora/RHEL/openSUSE host the same binary is
## already on ``PATH`` via the base ``rpm-build`` package, so
## ``--tool-provisioning=path`` resolves it without Nix; the Nix channel
## keeps the producer cross-platform (a Debian or macOS host can still
## emit an ``.rpm``).

import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package rpmbuild:
  provisioning:
    nixPackage "nixpkgs#rpm", executablePath = "bin/rpmbuild",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash
