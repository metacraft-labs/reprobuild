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

import std/tables
import repro_project_dsl
import repro_dsl_stdlib/packages_schema
export packages_schema

package automake:
  provisioning:
    nixPackage "nixpkgs#automake", executablePath = "bin/automake",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="

# ---------------------------------------------------------------------------
# Harvested MSYS2 catalog (cakBuiltin adapter consumer on Windows).
# ---------------------------------------------------------------------------

let automakeCatalog* = @[
  VersionedProvisioning(
    version: "1.16.5-1",
    archive_format: afTarZst,
    install_method: imMsys2Pacman,
    bin_relpath: @["bin/aclocal", "bin/automake"],
    platforms: @[
      PlatformBinary(cpu: pcX86_64, os: poWindows, url: "https://repo.msys2.org/msys/x86_64/automake1.16-1.16.5-1-any.pkg.tar.zst", sha256: "1963b5fa0ab5eaf1bdc311501cd742c6bb19941e831dcc8ab1e51a8c7f1634fe", sha512: "", sha1: "", extract_path: "usr")
    ],
    installer_args: @[],
    pacman_packages: @["automake1.16"],
    bootstrap_argv: @[],
    env: initTable[string, string](),
    pre_install_actions: @[
      PreInstallAction(kind: piaCopyItem, source: "$dir\\bin\\automake-1.16", target: "$dir\\bin\\automake", recurse: false, literal: ""),
      PreInstallAction(kind: piaCopyItem, source: "$dir\\bin\\aclocal-1.16", target: "$dir\\bin\\aclocal", recurse: false, literal: "")
    ])
]
