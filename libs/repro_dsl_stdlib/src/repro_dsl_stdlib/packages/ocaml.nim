## Archive realizations harvested by tools/catalog-harvester. GM4b: the
## harvester emits ``tarball`` statements, which live in the hand-maintained
## ``package`` block below; merge a re-harvest into it.
## Harvested from bucket: msys2:mingw64/ocaml
## Versions (newest-first): 5.4.1-2

import repro_project_dsl
import repro_dsl_stdlib/packages_schema
export packages_schema

package ocaml:
  provisioning:
    tarball url = "https://repo.msys2.org/mingw/mingw64/mingw-w64-x86_64-ocaml-5.4.1-2-any.pkg.tar.zst",
      sha256 = "8510b89feaf0ad861f813e88901d1b61745168a1019488eb4706c6f8b0a3ae2d",
      archiveType = "tar.zst",
      executablePath = "bin/ocaml.exe",
      version = "5.4.1-2",
      packageId = "ocaml@5.4.1-2",
      installMethod = "msys2-pacman",
      extractPath = "mingw64",
      pacmanPackage = "mingw-w64-x86_64-ocaml",
      cpu = "x86_64",
      os = "windows"
