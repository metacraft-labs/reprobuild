## ``dpkg-deb`` — the Debian archive builder, as a reprobuild package.
##
## Distribution-And-Packaging.md §6 rule 1: "packaging tools are
## reprobuild packages … no producer shells out to an assumed-present
## host tool", and rule 2: the ``.deb`` producer takes a REAL
## build-graph dependency on this package, so a project that depends on
## ``debPackage`` transitively depends on dpkg through the ordinary
## dependency mechanism — hermetically, with no engine provisioning.
##
## **Why a separate ``package`` block rather than a second
## ``executable`` inside ``packages/dpkg.nim``.** The DSL macro layer
## emits the typed per-subcommand wrapper procs only when the
## surrounding ``package`` declares exactly ONE ``executable`` block
## (``toolActionWrapperCode``'s early return in
## ``libs/repro_project_dsl/src/repro_project_dsl/macros_a.nim``). The
## same constraint is why ``packages/binutils.nim`` ships seven
## top-level packages in one file instead of one package with seven
## executables; this module follows that established shape. Both
## packages provision from the same ``nixpkgs#dpkg`` derivation and
## differ only in ``executablePath``.
##
## **No Windows channel, deliberately.** There is no host dpkg on
## Windows. Per §6.1 an unavailable format is just an unresolvable
## tool dependency surfaced through the normal mechanism — the engine
## does not know what a ``.deb`` is and must not gain a switch that
## says so.

import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin
# DSL-port M9.R.2c — typed slot var for ``executable dpkgDebBin:``.
import repro_dsl_stdlib/types/executable

package `dpkg-deb`:
  provisioning:
    nixPackage "nixpkgs#dpkg", executablePath = "bin/dpkg-deb",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

  executable dpkgDebBin:
    cli:
      dependencyPolicy automaticMonitor

      call:
        # Flag ORDER here is argv order, and dpkg-deb's synopsis is
        # ``dpkg-deb [option...] --build directory [archive]``. GNU
        # getopt would permute these anyway, but writing them in the
        # documented order means the argv a reader sees in a build log
        # is the command line the dpkg manual describes.
        #
        # dpkg-deb stamps the *building* user's uid/gid into the ar
        # members unless told otherwise, which would make the produced
        # archive depend on who ran the build — fatal for a
        # content-addressed edge, and wrong for a system package whose
        # payload must be root-owned. ``--root-owner-group`` forces 0:0
        # (dpkg >= 1.19).
        boolFlag rootOwnerGroup is bool, alias = "--root-owner-group"
        # Pin the payload compressor + level so the archive bytes are a
        # function of the tree, not of the dpkg build's defaults.
        flag compression is string,
          alias = "-Z",
          format = separate
        flag compressLevel is string,
          alias = "-z",
          format = separate
        # ``--build <tree> <archive>``. The two positionals below carry
        # the operands; this boolFlag carries the mode selector.
        boolFlag build is bool, alias = "--build"
        pos tree is string,
          position = 0,
          role = input,
          required = true
        pos archive is string,
          position = 1,
          role = output,
          required = true

        outputs archive
