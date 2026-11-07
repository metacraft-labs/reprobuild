## ``automake`` — GNU automake, generates ``Makefile.in`` templates
## from ``Makefile.am`` sources.
##
## Required by the C/C++ Autotools convention (M17, M28). The
## convention's ``autoreconf -fi`` action invokes
## ``aclocal`` + ``autoconf`` + ``automake --add-missing`` + ``libtool``
## to regenerate the build's configure / Makefile templates.
##
## Listed in M29 (Provisioning catalog cleanup) alongside ``autoconf``
## so the Autotools dispatch path has a closed-set catalog footprint.

import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin
import repro_dsl_stdlib/packages_schema
export packages_schema

package automake:
  provisioning:
    nixPackage "nixpkgs#automake", executablePath = "bin/automake",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash
    # GM4b: archive realizations formerly held by the retired
    # `VersionedProvisioning` catalog record (see the conflict notes
    # in the Gradual-Nix-To-Reprobuild-Migration GM4b milestone).
    tarball url = "https://repo.msys2.org/msys/x86_64/automake1.16-1.16.5-1-any.pkg.tar.zst",
      sha256 = "1963b5fa0ab5eaf1bdc311501cd742c6bb19941e831dcc8ab1e51a8c7f1634fe",
      archiveType = "tar.zst",
      executablePath = "bin/aclocal",
      extraExecutable = "bin/automake",
      version = "1.16.5-1",
      packageId = "automake@1.16.5-1",
      installMethod = "msys2-pacman",
      extractPath = "usr",
      pacmanPackage = "automake1.16",
      preInstall = preInstallAction("copy-item", "$dir\\bin\\automake-1.16", "$dir\\bin\\automake", false, ""),
      preInstall = preInstallAction("copy-item", "$dir\\bin\\aclocal-1.16", "$dir\\bin\\aclocal", false, ""),
      cpu = "x86_64",
      os = "windows"
