## Windows-System-Resources Phase F — minimal stdlib provisioning stub
## for ``tar``.
##
## GNU/BSD ``tar`` is consumed by the ``expandArchive`` typed tool (see
## ``packages/expand_archive.nim``) when extracting tar-family archives
## (``tar`` / ``tar.gz`` / ``tar.bz2`` / ``tar.xz``) on Linux / macOS.
##
## On Windows ``tar.exe`` ships with Win11 in ``%SystemRoot%\System32\``
## so no Windows provisioning channel is declared here (the typed-tool
## dispatch resolves ``tar`` from ``%PATH%`` directly via the engine's
## tool-identity resolver). The Linux/macOS happy path uses Nix.

import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package `tar`:
  provisioning:
    nixPackage "nixpkgs#gnutar", executablePath = "bin/tar",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

  # ---------------------------------------------------------------------------
  # ``tar`` as a PACKAGING tool.
  #
  # Distribution-And-Packaging.md §6 rule 1 makes the packaging tools
  # reprobuild packages and rule 2 makes each format producer take a real
  # build-graph dependency on its tool. The tarball producer
  # (``packaging/producers/tarball.nim``) is the simplest instance of
  # that rule and the control against which the deb and MSI producers are
  # read: it consumes exactly the same staged install tree and differs
  # only in which tool turns that tree into one file.
  #
  # The ``executable`` block below is the typed Layer-3 CLI surface for
  # that use. It sits on the SAME ``package tar:`` block the
  # ``expandArchive`` consumer already resolves, so nothing about the
  # existing extraction path changes — the macro simply also emits the
  # ``tar(...)`` wrapper proc.
  #
  # ``--sort=name`` + ``--mtime`` + ``--owner``/``--group`` are not
  # cosmetic. Without them the archive's member order comes from
  # readdir() order and its timestamps and ownership from the building
  # host, so two builds of the same tree would produce different bytes
  # and the producer would not be a content-addressed edge in any useful
  # sense. They are GNU tar options; the producer states that dependency
  # rather than silently degrading on bsdtar.
  # ---------------------------------------------------------------------------

  executable tarBin:
    cli:
      dependencyPolicy automaticMonitor

      call:
        boolFlag create is bool, alias = "-c"
        boolFlag gzip is bool, alias = "-z"
        flag file is string,
          alias = "-f",
          format = separate,
          role = output
        flag directory is string,
          alias = "-C",
          format = separate,
          role = input
        boolFlag sortByName is bool, alias = "--sort=name"
        flag mtime is string,
          alias = "--mtime=",
          format = concat
        flag owner is string,
          alias = "--owner=",
          format = concat
        flag group is string,
          alias = "--group=",
          format = concat
        boolFlag numericOwner is bool, alias = "--numeric-owner"
        flag transform is string,
          alias = "--transform=",
          format = concat
        pos members is seq[string],
          position = 0,
          repeated = true

        outputs file
