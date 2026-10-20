## Stdlib provisioning for ``swig``.
##
## ``swig`` (Simplified Wrapper and Interface Generator) is consumed by
## recipes that expose C/C++ bindings to scripting languages.
##
## Every realization below yields a runnable ``swig``:
##
## * ``nixPackage`` — nixpkgs' swig, the Nix-capable hosts' channel.
## * ``scoopApp`` — the ``swigwin`` build through ScoopInstaller/Main's
##   ``swig`` manifest.
## * ``tarball`` — the same official ``swigwin`` zip, Windows only.
##
## **No Linux or macOS tarball, on purpose.** ``spec/CLI/build.md``
## (``--tool-provisioning=tarball``): "a package with no tarball for the
## host falls through to its from-source recipe". Upstream publishes binaries
## only for Windows; elsewhere swig is a source release. That source release
## used to be declared here as an ``os = "any"`` arm whose executable was
## ``autogen.sh``, so tarball mode handed every host a build script where a
## swig was expected, and the fall-through never happened — the same defect
## as ``perl``'s former ``Configure`` arm (reprobuild-pm/issues/
## 2026-10-20-stdlib-perl-tarball-realization-is-a-source-tree-not-a-perl.md).
## A source tree belongs in a from-source recipe, not in a ``tarball`` arm.

import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package `swig`:
  provisioning:
    nixPackage "nixpkgs#swig", executablePath = "bin/swig",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash
    scoopApp(bucket = "main", app = "swig",
      preferredVersion = ">=4", executablePath = "swig.exe",
      requiresExecutionProfileChecksum = false)
    # Windows x86_64: SWIG's official ``swigwin`` zip — ``swig.exe`` plus
    # the ``Lib/`` tree it reads its interface files from, under one
    # top-level ``swigwin-4.5.1/`` directory (hence ``stripComponents = 1``).
    #
    # **sha256**: computed 2026-10-20 from the downloaded asset
    # (13430173 bytes). Upstream publishes only a sha1 for it; the
    # download's sha1 (``da43a48c…``) matches both SourceForge's and the
    # ScoopInstaller/Main ``swig`` manifest's.
    tarball url = "https://downloads.sourceforge.net/project/swig/swigwin/swigwin-4.5.1/swigwin-4.5.1.zip",
      sha256 = "6a8662c063ba4d1e72beaecef24da4af3d631d73ffdde958fb42aa50fdefb962",
      archiveType = "zip",
      stripComponents = 1,
      executablePath = "swig.exe",
      packageId = "swigwin@4.5.1",
      cpu = "x86_64",
      os = "windows",
      lockIdentity = "tarball:swigwin@4.5.1:windows-x86_64:sha256:6a8662c063ba4d1e72beaecef24da4af3d631d73ffdde958fb42aa50fdefb962",
      version = "4.5.1"
    # Windows aarch64: the SAME x64 zip (``swig.exe`` is a PE32+ x86-64
    # binary). SWIG publishes no arm64 Windows build; Windows 11 on ARM
    # runs it under its built-in x64 emulation, which is adequate for a
    # code generator invoked at build time. A native arm64 swig replaces
    # this arm when one is published.
    # The lock identity names the target so the two arms stay
    # distinguishable in a lock even though their bytes agree.
    tarball url = "https://downloads.sourceforge.net/project/swig/swigwin/swigwin-4.5.1/swigwin-4.5.1.zip",
      sha256 = "6a8662c063ba4d1e72beaecef24da4af3d631d73ffdde958fb42aa50fdefb962",
      archiveType = "zip",
      stripComponents = 1,
      executablePath = "swig.exe",
      packageId = "swigwin@4.5.1",
      cpu = "aarch64",
      os = "windows",
      lockIdentity = "tarball:swigwin@4.5.1:windows-aarch64:sha256:6a8662c063ba4d1e72beaecef24da4af3d631d73ffdde958fb42aa50fdefb962",
      version = "4.5.1"
