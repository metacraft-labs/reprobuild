## ``rpmbuild`` — the RPM package builder, as a reprobuild package.
##
## Distribution-And-Packaging.md §6 rules 1 + 2, same shape as
## ``packages/dpkg_deb.nim``.
##
## **M0 shipped this module without a producer**; M1 wrote one, and it
## lives in ``packaging/producers/rpm.nim``. M0's gate made ``.rpm``
## optional (the amended gate pairs ``.deb`` with ``.msi`` instead,
## because rpm-vs-deb agrees with deb on every axis the abstraction
## could leak along and MSI disagrees on all of them), but the tool
## package was written anyway, because it is the half that has to be
## right before a producer can be written at all: a producer is then a
## translation of an already-staged tree, which is the whole point of
## the layer.
##
## The producer uses ``rpmbuild -bb`` (binary package only), with
## ``--define`` carrying ``_topdir`` / ``_rpmdir`` / ``buildroot`` so
## nothing is written to ``$HOME/rpmbuild`` — which would be both
## non-hermetic and outside the edge's declared output scope. The note
## this header used to leave for whoever wrote the producer was
## MEASURED and is real: rpm 4.20 does not resolve a relative macro
## path against the process CWD, it PREPENDS A SLASH. The producer
## answers it with ``%(pwd)``, which rpm expands through a shell at use
## time, so the graph holds a relative path and the action computes the
## absolute one — see ``producers/rpm.nim``'s ``AbsolutePathMacro``.

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
        # ``--buildroot`` is an OPTION rather than a ``--define``, and
        # the two are not interchangeable: rpm treats the option as
        # authoritative and lets ``%buildroot`` derive from it, whereas
        # defining ``buildroot`` by hand loses to the option whenever
        # both are present. It must be ABSOLUTE — rpm 4.20 does not
        # resolve a relative value against the CWD, it prepends a
        # slash, and the build then fails with ``File not found:
        # /<relative path>`` for a tree that is there. See
        # ``packaging/producers/rpm.AbsolutePathMacro``.
        flag buildRoot is string,
          alias = "--buildroot",
          format = separate
        boolFlag quiet is bool, alias = "--quiet"
        pos specFile is string,
          position = 0,
          role = input,
          required = true
