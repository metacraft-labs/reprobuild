## ``rpmbuild`` — the RPM package builder, as a reprobuild package.
##
## Distribution-And-Packaging.md §6 rules 1 + 2, same shape as
## ``packages/dpkg_deb.nim``.
##
## **There is no rpm PRODUCER yet.** M0's gate makes ``.rpm`` optional
## (the amended gate pairs ``.deb`` with ``.msi`` instead, because
## rpm-vs-deb agrees with deb on every axis the abstraction could leak
## along and MSI disagrees on all of them), and M0 did not write one.
## This module exists anyway because M0's own summary lists the
## packaging TOOLS — "dpkg/rpmbuild/tar/nsis/wix3/create-dmg/patchelf/
## zstd" — as things that get real reprobuild package definitions, and
## because the tool package is the half that has to be right before a
## producer can be written at all: a producer is then a translation of
## an already-staged tree, which is the whole point of the layer.
##
## The mode an rpm producer will use is ``rpmbuild -bb`` (binary
## package only), with ``--define`` carrying ``_topdir`` / ``_rpmdir``
## / ``buildroot`` so nothing is written to ``$HOME/rpmbuild`` — which
## would be both non-hermetic and outside the edge's declared output
## scope. Note for whoever writes it: rpm resolves those macros
## against the process CWD in ways that make RELATIVE paths unreliable,
## which is the first thing to get right and the reason this was not a
## five-minute addition to M0.

import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin
# DSL-port M9.R.2c — typed slot var for ``executable rpmbuildBin:``.
import repro_dsl_stdlib/types/executable

package rpmbuild:
  provisioning:
    nixPackage "nixpkgs#rpm", executablePath = "bin/rpmbuild",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

  executable rpmbuildBin:
    cli:
      dependencyPolicy automaticMonitor

      call:
        boolFlag binaryOnly is bool, alias = "-bb"
        flag defines is seq[string],
          alias = "--define",
          format = separate,
          repeated = true
        flag target is string,
          alias = "--target",
          format = separate
        boolFlag quiet is bool, alias = "--quiet"
        pos specFile is string,
          position = 0,
          role = input,
          required = true
