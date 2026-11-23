## GM4b fixture: a canonical package with in-package realizations and an
## external provisioning contribution, shaped so that resolution exercises
## every selection rule on three targets.
##
## Imported twice by ``t_e2e_home_profile_resolves_like_uses``:
##
## * by the TEST PROCESS, which links it like the engine links the stdlib
##   (``repro_dsl_stdlib/package_registry``), so a home profile naming
##   ``gm4bcontrib`` resolves against it;
## * by the RECIPE the test compiles through real interface extraction, so a
##   ``uses: "gm4bcontrib"`` projects the same records.
##
## Realizations (nothing here is ever downloaded — selection is static):
##
## ===================  =====================  =================================
## target               tarball                other kinds
## ===================  =====================  =================================
## x86_64-linux         in-package (canonical) nix: in-package
## aarch64-macos        contribution A         nix: in-package
## x86_64-windows       in-package AND A       scoop: contribution A
##                      -> AMBIGUOUS
## ===================  =====================  =================================
##
## So the macOS tarball's lock identity carries A's contributor prefix, the
## Windows tarball is ambiguous on both paths (and, because ambiguity never
## falls through, so is the default policy there), and a Windows ``scoop``
## selection comes from the contribution.

import repro_project_dsl

const
  Gm4bContributor* = "github:example/gm4b-contribution-a"
    ## The contributor below (``contributor`` takes a literal).
  Gm4bLinuxSha* =
    "1111111111111111111111111111111111111111111111111111111111111111"
  Gm4bMacSha* =
    "2222222222222222222222222222222222222222222222222222222222222222"
  Gm4bWindowsSha* =
    "3333333333333333333333333333333333333333333333333333333333333333"
  Gm4bWindowsContribSha* =
    "4444444444444444444444444444444444444444444444444444444444444444"

package gm4bcontrib:
  provisioning:
    nixPackage "nixpkgs#hello", executablePath = "bin/hello",
      packageId = "gm4bcontrib-nix"
    tarball url = "https://example.invalid/gm4bcontrib-1.0-linux-x64.tar.gz",
      sha256 = Gm4bLinuxSha,
      archiveType = "tar.gz",
      executablePath = "bin/gm4bcontrib",
      packageId = "gm4bcontrib@1.0",
      version = "1.0",
      cpu = "x86_64",
      os = "linux"
    tarball url = "https://example.invalid/gm4bcontrib-1.0-windows-x64.zip",
      sha256 = Gm4bWindowsSha,
      archiveType = "zip",
      executablePath = "gm4bcontrib.exe",
      packageId = "gm4bcontrib@1.0",
      version = "1.0",
      cpu = "x86_64",
      os = "windows"

provisioningFor "gm4bcontrib":
  developInterface
  contributor "github:example/gm4b-contribution-a"
  tarball url = "https://example.invalid/a/gm4bcontrib-1.0-macos-arm64.tar.gz",
    sha256 = Gm4bMacSha,
    archiveType = "tar.gz",
    executablePath = "bin/gm4bcontrib",
    packageId = "gm4bcontrib@1.0",
    version = "1.0",
    cpu = "aarch64",
    os = "macos"
  tarball url = "https://example.invalid/a/gm4bcontrib-1.0-windows-x64.zip",
    sha256 = Gm4bWindowsContribSha,
    archiveType = "zip",
    executablePath = "gm4bcontrib.exe",
    packageId = "gm4bcontrib@1.0",
    version = "1.0",
    cpu = "x86_64",
    os = "windows"
  scoopApp(bucket = "main", app = "gm4bcontrib", version = "1.0",
    executablePath = "gm4bcontrib.exe",
    requiresExecutionProfileChecksum = false)
