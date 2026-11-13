## Archive realizations harvested by tools/catalog-harvester. GM4b: the
## harvester emits ``tarball`` statements, which live in the hand-maintained
## ``package`` block below; merge a re-harvest into it.
## Harvested from bucket: ScoopInstaller/Main
## Versions (newest-first): 4.3.3
##
## M9.5 (hand-edited): added the x86_64-linux tarball
## realization harvested via ``--source gh-releases:Kitware/CMake
## --asset-pattern 'cmake-4\.3\.3-linux-x86_64\.tar\.gz' --platform-os
## linux``. The Linux tarball is ``tar.gz`` (vs. ``zip``) and the
## binaries live under ``bin/cmake`` (no ``.exe``); the windows-only
## ``cmcldeps.exe`` + ``cmake-gui.exe`` are dropped from the override.
## Upstream CMake's Linux build targets glibc 2.17 (RHEL 7 / CentOS 7
## floor) — matches the M9.5 spec's glibc-2.17 honest-scope target.

import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin
import repro_dsl_stdlib/packages_schema
# DSL-port M9.R.2c — typed slot var for ``executable cmakeBin:``.
import repro_dsl_stdlib/types/executable
export packages_schema

# ---------------------------------------------------------------------------
# DSL-port M9.R.2 — hand-authored ``package cmake:`` DSL block carrying
# provisioning shape + the typed Layer-3 CLI surface so recipes can write
# ``cmake.configure(srcDir = ..., buildDir = ..., generator = "Ninja",
# cacheVars = @["CMAKE_BUILD_TYPE=Release"])`` instead of an inline
# ``sh.call(["cmake", "-S", ...])``.
#
# Positional / flag shape mirrors the canonical CMake CLI:
#
#   * ``cmake -S <srcDir> -B <buildDir> -G <gen> -D<var>=<val>`` for
#     configure.
#   * ``cmake --build <buildDir> --target <name> --config <cfg>`` for
#     build.
#   * ``cmake --install <buildDir> --prefix <prefix> --component <comp>``
#     for install.
#
# Cross-link: see ``CMake-Reprobuild-Generator.md`` for the longer-term
# CMake → reprobuild generator integration.
# ---------------------------------------------------------------------------

package cmake:
  provisioning:
    nixPackage "nixpkgs#cmake", executablePath = "bin/cmake",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash
    scoopApp(bucket = "main", app = "cmake",
      preferredVersion = ">=3.20", executablePath = "bin/cmake.exe",
      requiresExecutionProfileChecksum = false)
    tarball url = "https://github.com/Kitware/CMake/releases/download/v4.3.3/cmake-4.3.3-windows-x86_64.zip",
      sha256 = "935ade9e5e8723583c07f44c5592cea2a1c8f65c56ca7e07b34c025c880e0bd6",
      archiveType = "zip",
      stripComponents = 1,
      executablePath = "bin/cmake.exe",
      packageId = "cmake@4.3.3",
      cpu = "x86_64",
      os = "windows",
      lockIdentity = "tarball:cmake@4.3.3:sha256:935ade9e5e8723583c07f44c5592cea2a1c8f65c56ca7e07b34c025c880e0bd6",
      version = "4.3.3",
      extraExecutable = "bin\\cmcldeps.exe",
      extraExecutable = "bin\\cpack.exe",
      extraExecutable = "bin\\ctest.exe",
      extraExecutable = "bin\\cmake-gui.exe"
    tarball url = "https://github.com/Kitware/CMake/releases/download/v4.3.3/cmake-4.3.3-linux-x86_64.tar.gz",
      sha256 = "927b2368a946c37269c3a66225ab00544e756459cdd0b5d0da438694fb9ff802",
      archiveType = "tar.gz",
      stripComponents = 1,
      executablePath = "bin/cmake",
      packageId = "cmake@4.3.3-linux",
      cpu = "x86_64",
      os = "linux",
      lockIdentity = "tarball:cmake@4.3.3-linux:sha256:927b2368a946c37269c3a66225ab00544e756459cdd0b5d0da438694fb9ff802",
      version = "4.3.3",
      extraExecutable = "bin/cpack",
      extraExecutable = "bin/ctest"
    # GM4b: archive realizations formerly held by the retired
    # `VersionedProvisioning` catalog record (see the conflict notes
    # in the Gradual-Nix-To-Reprobuild-Migration GM4b milestone).
    tarball url = "https://github.com/Kitware/CMake/releases/download/v4.3.3/cmake-4.3.3-windows-arm64.zip",
      sha256 = "db6e902b5ba6a08d0abed136763c4bd95adda17e882d659c0f5d14fe158f7395",
      archiveType = "zip",
      executablePath = "bin\\cmake.exe",
      extraExecutable = "bin\\cmcldeps.exe",
      extraExecutable = "bin\\cpack.exe",
      extraExecutable = "bin\\ctest.exe",
      extraExecutable = "bin\\cmake-gui.exe",
      version = "4.3.3",
      packageId = "cmake@4.3.3",
      extractPath = "cmake-4.3.3-windows-arm64",
      cpu = "aarch64",
      os = "windows"

  executable cmakeBin:
    cli:
      dependencyPolicy automaticMonitor

      subcmd "configure":
        flag srcDir is string,
          alias = "-S",
          format = separate,
          role = input
        flag buildDir is string,
          alias = "-B",
          format = separate,
          role = output
        flag generator is string,
          alias = "-G",
          format = separate
        flag cacheVars is seq[string],
          alias = "-D",
          format = concat,
          repeated = true
        flag toolchainFile is string,
          alias = "--toolchain=",
          format = concat
        flag config is string,
          alias = "--config=",
          format = concat
        flag fresh is bool,
          alias = "--fresh"

        outputs buildDir

      subcmd "build":
        flag buildDir is string,
          alias = "--build",
          format = separate,
          role = input,
          required = true
        flag target is string,
          alias = "--target",
          format = separate
        flag config is string,
          alias = "--config",
          format = separate
        flag jobs is int,
          alias = "-j",
          format = separate
        flag parallel is int,
          alias = "--parallel",
          format = separate

      subcmd "install":
        flag buildDir is string,
          alias = "--install",
          format = separate,
          role = input,
          required = true
        flag prefix is string,
          alias = "--prefix",
          format = separate,
          role = output
        flag component is string,
          alias = "--component",
          format = separate
        flag config is string,
          alias = "--config",
          format = separate
