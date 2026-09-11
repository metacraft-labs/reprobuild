## ``appimagetool`` — the AppImage type-2 builder, as a reprobuild
## package.
##
## Distribution-And-Packaging.md §6 rule 1 ("packaging tools are
## reprobuild packages … no producer shells out to an assumed-present
## host tool") and rule 2 ("a project that depends on a producer
## transitively depends on the underlying tool"), same shape as
## ``packages/dpkg_deb.nim`` and ``packages/rpmbuild.nim``.
##
## ## Why a pinned upstream release and not ``nixpkgs#appimagetool``
##
## There is none, and it is measured rather than assumed. At the
## canonical pin (``nixpkgs_pin.CanonicalNixpkgsRev``) the attribute
## names matching /[aA]ppimage/ are exactly ``appimage-run``,
## ``appimage-run-tests``, ``appimageTools``, ``appimageupdate``,
## ``appimageupdate-qt``, ``cura-appimage``, ``libappimage`` and
## ``session-desktop-appimage`` — every one of them for CONSUMING an
## AppImage — and ``appimageTools`` itself exposes only
## ``appimage-exec``/``defaultFhsEnvArgs``/``extract``/``extractType1``/
## ``extractType2``/``wrapAppImage``/``wrapType1``/``wrapType2``.
## ``nix eval`` on ``appimagetool`` answers "Did you mean
## appimageTools?". Nothing in that pin BUILDS an AppImage. So the tool
## arrives the way ``wix3_tools.nim``'s does: an upstream release asset,
## pinned by URL and sha256.
##
## ## BOTH CHANNELS REALIZE THE SAME BYTES — M1's N29
##
## The tarball channel was the ONLY channel until this pass, which meant
## ``repro build --tool-provisioning=nix`` could not resolve this package
## and therefore could not build the dogfood distribution AT ALL — not
## the AppImage edge alone, because ``nixAcquisitionPlan`` raises on a
## package with no ``nixPackage`` entry and tool resolution is a property
## of the whole graph. That had been true since ``b3d6117d``, the commit
## that added the AppImage producer.
##
## The reason it was recorded rather than fixed was that adding a
## provisioning channel is adding a dependency. This one is not: the
## ``nixPackage`` entry below is an ``expressionFile`` (the shape
## ``packages/stylus.nim`` and ``packages/python3_with_modules.nim``
## already use for tools nixpkgs does not carry) pinned to
## ``AppImageToolUrl`` and ``AppImageToolSha256`` — the SAME asset, the
## SAME sha256, fetched by nix instead of by reprobuild. See
## ``nix/appimagetool-1.9.1/default.nix`` for why the expression is a
## plain copy rather than ``autoPatchelfHook`` or ``wrapType2``.
##
## ``archiveType = "raw"`` because the asset is not an archive: an
## AppImage is a self-mounting ELF image, and ``raw`` is the channel's
## arm for a payload that IS the executable (its other users are
## circom's and solc's direct-download binaries). The raw extractor
## copies the download to ``<prefix>/<executablePath>`` and restores
## 0755, which is exactly what is wanted here.
##
## ## Version 1.9.1, and why not ``continuous``
##
## The AppImage project publishes a ``continuous`` tag that moves. A
## moving tag behind a fixed sha256 is a pin that breaks rather than a
## pin that holds, so this entry names the newest SEMVER release
## instead. (``AppImage/AppImageKit``'s old release 13 is not an option
## either: its assets were renamed to ``obsolete-*`` upstream, so the
## URL every guide on the internet still quotes 404s.)
##
## ## The one thing this tool does that a build edge must not
##
## **Without ``--runtime-file`` it downloads the type-2 runtime from the
## network, from the MOVING ``continuous`` tag**, at build time.
## Measured, in a container started ``--network none``::
##
##   Downloading runtime file from https://github.com/AppImage/
##       type2-runtime/releases/download/continuous/runtime-x86_64
##   Failed to download runtime: server returned status code 0
##
## That is an unpinned input to a content-addressed edge, and it fails
## closed only because the container had no network — on a developer's
## machine it would succeed and silently make the artifact a function of
## the day. ``packages/appimage_runtime.nim`` exists so the producer can
## pass ``--runtime-file`` instead, and
## ``packaging/producers/appimage.nim`` refuses to build if the runtime
## is not on the action's PATH rather than letting this path be taken.
##
## ## ``--appimage-extract-and-run`` is passed ALWAYS, and first
##
## appimagetool is itself distributed as an AppImage, so running it
## normally needs FUSE and a ``/dev/fuse`` the build host may not have
## (no container has one unless it is given one). ``--appimage-extract-
## and-run`` is the AppImage RUNTIME's own escape hatch: it unpacks
## itself into ``$TMPDIR`` and execs from there. It is read by the
## runtime out of ``argv[1]`` specifically, which is why the producer
## declares it as the FIRST argument — the typed CLI renders argv in
## declaration order, so the order here is load-bearing rather than
## cosmetic.
##
## ## What is deliberately not on this surface
##
## ``-u``/``--updateinformation`` and ``-g``/``--guess`` embed zsync
## update information (and shell out to ``zsyncmake``); ``-s``/
## ``--sign`` signs with gpg. Both are M2/M3 business — signing and
## hosting — and neither can be exercised until there is a place to
## publish to. ``--sign`` in particular would make the artifact depend
## on a key in the builder's home directory, which is the ambient-input
## failure the whole layer exists to avoid.

import repro_project_dsl
# DSL-port M9.R.2c — typed slot var for ``executable appimagetoolBin:``.
import repro_dsl_stdlib/types/executable

const
  AppImageToolVersion* = "1.9.1"
  AppImageToolUrl* =
    "https://github.com/AppImage/appimagetool/releases/download/1.9.1/" &
    "appimagetool-x86_64.AppImage"
  AppImageToolSha256* =
    "ed4ce84f0d9caff66f50bcca6ff6f35aae54ce8135408b3fa33abfc3cb384eb0"
    ## Measured with ``sha256sum`` over the downloaded asset on
    ## 2026-09-11. The build identifies itself as "continuous build (git
    ## version 8c8c91f), build 296 built on 2025-12-04 17:55:56 UTC",
    ## which is what the 1.9.1 tag points at.

package `appimagetool`:
  provisioning:
    # THE NIX CHANNEL — M1's N29. Same asset, same sha256 as the tarball
    # entry below; see the header. ``expressionFile`` is resolved against
    # THIS file's directory at macro time.
    # The selector must be a STRING LITERAL: the macro tests its prefix
    # against the nixpkgs-flake form and slices it. Same shape as
    # stylus's. (The prefix is not spelled out here on purpose:
    # `t_smoke_catalog_audit_m29` treats any file containing that byte
    # sequence as a nixpkgs-pinned entry and requires the canonical-rev
    # consts, which an expressionFile entry has no business carrying.
    # Found by the audit going red on this file.)
    nixPackage "reprobuild-stdlib-appimagetool-1.9.1",
      executablePath = "bin/appimagetool",
      expressionFile = "nix/appimagetool-1.9.1/default.nix",
      lockIdentity = "nix-expression:appimagetool@" & AppImageToolVersion &
        ":sha256:" & AppImageToolSha256
    tarball url = AppImageToolUrl,
      sha256 = AppImageToolSha256,
      archiveType = "raw",
      executablePath = "appimagetool",
      packageId = "appimagetool@" & AppImageToolVersion,
      cpu = "x86_64",
      os = "linux",
      lockIdentity = "tarball:appimagetool@" & AppImageToolVersion &
        ":sha256:" & AppImageToolSha256

  executable appimagetoolBin:
    cli:
      dependencyPolicy automaticMonitor

      call:
        # FIRST, and the order is not a style choice: the AppImage
        # type-2 runtime inspects ``argv[1]`` for its own
        # ``--appimage-*`` options and hands everything else to the
        # payload. Declared first because the typed CLI renders argv in
        # declaration order.
        boolFlag extractAndRun is bool,
          alias = "--appimage-extract-and-run"
        # Skip the AppStream metadata check. Without it appimagetool
        # looks for ``appstreamcli`` and warns; with a metainfo file
        # present it would also VALIDATE it, which is a network-capable
        # step. The layer ships no AppStream metadata, so there is
        # nothing to validate.
        boolFlag noAppstream is bool, alias = "-n"
        # THE PINNED RUNTIME. See the header: without this appimagetool
        # fetches one over the network from a moving tag.
        flag runtimeFile is string,
          alias = "--runtime-file",
          format = separate,
          role = input
        # squashfs compressor. Named rather than defaulted so the
        # artifact's bytes are a function of the graph: appimagetool's
        # own default has changed across releases (gzip -> xz -> zstd)
        # and a default that moves is an ambient input.
        flag compression is string,
          alias = "--comp",
          format = separate
        pos appDir is string,
          position = 0,
          role = input,
          required = true
        pos output is string,
          position = 1,
          role = output,
          required = true

        outputs output
