## ``libtool`` — GNU libtool, the portable shared-library wrapper used
## by every autotools-driven C/C++ project to build / link shared
## libraries cross-platform.
##
## M9.R.14c.8 — added as part of the bootstrap-floor widening. The
## from-source autoconf / automake / libtool tools are perl scripts
## whose execution requires sibling ``share/<tool>/`` + ``lib/<tool>/``
## trees with macro databases + perl modules. The autotools_package
## stage-copy convention (M9.R.14c.5) stages only the executable
## binary, dropping the sibling tree context. Until M9.L's per-artifact
## install-glue lands, these tools come from stdlib (nix on Linux/macOS,
## scoop on Windows) which ships the full install tree intact.

import std/tables
import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin
import repro_dsl_stdlib/packages_schema
export packages_schema

package libtool:
  provisioning:
    nixPackage "nixpkgs#libtool", executablePath = "bin/libtool",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

package libtoolize:
  provisioning:
    nixPackage "nixpkgs#libtool", executablePath = "bin/libtoolize",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

# ---------------------------------------------------------------------------
# Harvested MSYS2 catalog (cakBuiltin adapter consumer on Windows).
# ---------------------------------------------------------------------------

let libtoolCatalog* = @[
  VersionedProvisioning(
    version: "2.5.4-5",
    archive_format: afTarZst,
    install_method: imMsys2Pacman,
    bin_relpath: @["bin/libtool", "bin/libtoolize"],
    platforms: @[
      PlatformBinary(cpu: pcX86_64, os: poWindows, url: "https://repo.msys2.org/msys/x86_64/libtool-2.5.4-5-x86_64.pkg.tar.zst", sha256: "e7d27e7543dbe6ce2dae863a412455ab68f7bf8d1670762a0aded62480bf08f0", sha512: "", sha1: "", extract_path: "usr")
    ],
    installer_args: @[],
    pacman_packages: @["libtool"],
    bootstrap_argv: @[],
    env: initTable[string, string]())
]

let libtoolizeCatalog* = libtoolCatalog
