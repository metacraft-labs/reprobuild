## ``clingo`` -- the Potassco Answer Set Programming solver.
##
## STATUS: SCAFFOLD. This entry is deliberately NOT imported by
## ``catalog_registry.nim`` yet, so it does not participate in resolution. See
## "Why this is not wired yet" below. Adding the import is the whole of the
## follow-up once the Windows source kind exists.
##
## ``repro_solver`` binds clingo's C API through ``{.dynlib.}`` and resolves it
## at MODULE INIT -- before ``main``. That makes clingo unlike every other
## entry in this directory: it is not a tool some recipe may declare
## ``uses:``, it is a hard runtime prerequisite of ``repro`` itself and of
## every helper binary reprobuild compiles for itself (the interface-extract
## runner, the project provider). A host without it has no working ``repro``
## subcommand at all, not even ``--version``.
##
## Today that prerequisite is satisfied out-of-band on each platform:
##
##   * Linux/macOS -- ``flake.nix`` puts ``pkgs.clingo`` in the devShell and
##     bakes its lib dir into DT_RUNPATH / LC_RPATH via
##     ``runtimeRpathCompilerFlags``.
##   * Windows -- ``windows/ensure-clingo.ps1`` installs the pinned
##     conda-forge package, ``scripts/build_apps.sh`` stages ``clingo.dll``
##     next to the built binaries, and
##     ``repro_interface_artifacts.stageHostDynlibsBesideBinary`` copies it
##     beside each scratch-compiled helper.
##
## Routing this through the engine's own tool-provisioning store is the
## durable replacement for that out-of-band arrangement: one pin, one
## lock entry, one substitutable artifact per platform, instead of a
## PowerShell provisioner plus a shell staging step plus a Nix input that
## have to be kept in agreement by hand.
##
## Why this is not wired yet
## -------------------------
##
## The Windows source cannot be expressed with the source kinds this DSL
## currently has. potassco publishes no prebuilt Windows binaries (source
## tarballs only) and the PyPI wheel statically links the C library into
## ``_clingo.cp312-win_amd64.pyd``, so conda-forge is the only source of a
## standalone ``clingo.dll``. A ``.conda`` package is a NESTED archive: an
## outer ZIP holding ``info-*.tar.zst`` and ``pkg-*.tar.zst``, with the
## payload at ``pkg-*/Library/bin/clingo.dll``. ``tarball`` fetches and
## unpacks exactly one archive, so it cannot reach that path -- there is no
## ``stripComponents`` value that descends through a second archive.
##
## Closing this needs one of:
##
##   1. a ``condaPackage`` source kind that understands the two-layer format
##      (what ``windows/ensure-clingo.ps1`` already does imperatively:
##      Expand-Archive, then tar.exe on the ``pkg-`` payload); or
##   2. nested-archive support on ``tarball`` (an inner-archive selector plus
##      its own strip depth); or
##   3. a reprobuild-published mirror of the extracted ``Library/bin`` as a
##      plain zip, which makes the entry expressible today at the cost of
##      owning a redistribution.
##
## (1) is the honest model of the upstream artifact and keeps the pin pointing
## at conda-forge's own bytes. Whichever lands, keep the version and checksum
## in agreement with ``windows/toolchain-versions.env`` (CLINGO_VERSION /
## CLINGO_BUILD_STRING / CLINGO_SHA256) and with the clingo resource in
## ``infra/machines/server/_windows-runner-001/system_windows_runner.nim``,
## which provisions the same package for the CI runner.
##
## The bootstrap ordering is worth stating explicitly, because it does not go
## away once this entry is wired: ``repro`` needs clingo in order to run the
## solver that would resolve this package, so the engine can never be what
## provisions clingo for ``repro`` ITSELF. This entry serves recipes that
## declare ``uses: "clingo"`` and the helper binaries reprobuild compiles
## after installation. The release archive must still ship ``clingo.dll``
## beside ``repro.exe`` -- ``scripts/verify_release.sh`` enforces that.

import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin
import repro_dsl_stdlib/prefix_layout

package clingo:
  provisioning:
    # POSIX only for now. Matches the ``pkgs.clingo`` input flake.nix already
    # uses for the devShell, on the repo's dominant nixpkgs pin.
    nixPackage "nixpkgs#clingo", executablePath = "bin/clingo",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash
    # Windows: conda-forge, via the `conda` archiveType. When this entry was
    # first scaffolded the arm did not exist and a `tarball` here would have
    # unpacked to the two inner `.tar.zst` members rather than to `clingo.dll`
    # — a resolver that succeeds and then produces a broken realization. The
    # archiveType now unwraps both layers, so the entry is real.
    #
    # conda-forge is the only redistributable source: potassco ships source
    # tarballs only, and the PyPI wheel statically links the C library into
    # `_clingo.cp312-win_amd64.pyd`. The `pyXXX` build string is part of the
    # asset name and therefore part of the pin, but it only affects the bundled
    # `.pyd` we discard — `clingo.dll` itself is ABI-stable across those
    # variants.
    #
    # No stripComponents: the payload's own `Library/bin` layout is the prefix
    # shape, and `executablePath` addresses into it. Verified by realizing the
    # pinned asset by hand — the resulting clingo.dll is sha256 a55d01d3…,
    # byte-identical to the one in a working install.
    tarball url = "https://anaconda.org/conda-forge/clingo/5.8.0/download/win-64/clingo-5.8.0-py312he3f8637_1.conda",
      sha256 = "a9e5eb699dd8de3dcc555c28f47a46ca0b3005f784f76aadf70f47267e5afee9",
      archiveType = "conda",
      executablePath = binDir(plConda) & "/clingo.exe",
      packageId = "clingo@5.8.0",
      cpu = "x86_64",
      os = "windows",
      lockIdentity = "tarball:clingo@5.8.0:sha256:a9e5eb699dd8de3dcc555c28f47a46ca0b3005f784f76aadf70f47267e5afee9"

  # This package provides the SHARED LIBRARY `repro_solver` dlopens at module
  # init, not only a `clingo` CLI. That is now declarable.
  #
  # `library <name>:` is still NOT the vehicle and never was: its
  # `exportedPath` is "the producer-relative directory a Nim library-consumer
  # threads onto its `nim c --path:`" (types.nim), i.e. a Nim SOURCE path, and
  # its `kind:` describes a library the package BUILDS. Pointing `exportedPath`
  # at `Library/bin` would tell Nim consumers to add a DLL directory to their
  # source path. Hence a separate `runtimeLibrary` member.
  #
  # One entry per provisioning arm, because the directory follows the SOURCE:
  # conda-forge win-64 puts the loadable DLL under `Library/bin` (Windows keeps
  # DLLs beside the executables, not in `lib`), while nixpkgs uses `lib`.
  # `runtimeLibDir` names both — see repro_dsl_stdlib/prefix_layout.
  runtimeLibrary "clingo", dir = runtimeLibDir(plConda),
    cpu = "x86_64", os = "windows"
  runtimeLibrary "clingo", dir = runtimeLibDir(plUnix), os = "linux"
  runtimeLibrary "clingo", dir = runtimeLibDir(plUnix), os = "macos"
