## Archive realizations harvested by tools/catalog-harvester. GM4b: the
## harvester emits ``tarball`` statements, which live in the hand-maintained
## ``package`` block below; merge a re-harvest into it.
## Harvested from bucket: gh-releases:brechtsanders/winlibs_mingw
## Versions (newest-first): 16.1.0posix-14.0.0-ucrt-r2

import repro_project_dsl
import repro_dsl_stdlib/packages_schema
export packages_schema

package `gcc-winlibs`:
  provisioning:
    tarball url = "https://github.com/brechtsanders/winlibs_mingw/releases/download/16.1.0posix-14.0.0-ucrt-r2/winlibs-x86_64-posix-seh-gcc-16.1.0-mingw-w64ucrt-14.0.0-r2.7z",
      sha256 = "62fb8588d2deee7d662dbcbd386702adbf19643764c971c38aa4839472eee232",
      archiveType = "7z",
      executablePath = "bin/gcc.exe",
      extraExecutable = "bin/g++.exe",
      extraExecutable = "bin/gfortran.exe",
      extraExecutable = "bin/ld.exe",
      version = "16.1.0posix-14.0.0-ucrt-r2",
      packageId = "gcc-winlibs@16.1.0posix-14.0.0-ucrt-r2",
      extractPath = "mingw64",
      cpu = "x86_64",
      os = "windows"
