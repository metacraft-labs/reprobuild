## ``mingw-gcc`` — the WinLibs MinGW-w64 GCC distribution for Windows.
##
## Distinct from ``gcc`` on purpose. ``gcc`` is the generic C-compiler
## interface a recipe names when it wants "a C compiler"; this package is the
## specific WinLibs UCRT build, named when a project needs the MinGW ABI
## rather than MSVC — Agent Harbor puts it FIRST on PATH so the GNU driver
## wins for the sources that need it, ahead of anything else that answers to
## ``gcc``.
##
## The archive carries a ``mingw64/`` top-level directory holding the whole
## sysroot (bin, lib, include, the target triple tree), so it is NOT
## flattened: ``gcc.exe`` finds its own headers and libraries by walking
## relative to its location, and stripping the wrapper would separate the
## driver from the sysroot it resolves against. ``executablePath`` therefore
## reaches into the tree rather than sitting at the prefix root.
##
## The version string is upstream's compound release tag — GCC version, the
## threading model, the mingw-w64 runtime version and a release revision —
## not a semver. Digest is Agent Harbor's ``MINGW_GCC_SHA256_X86_64``.

import repro_project_dsl

const MingwGccVersion = "16.1.0posix-14.0.0-ucrt-r2"

package `mingw-gcc`:
  provisioning:
    tarball url = "https://github.com/brechtsanders/winlibs_mingw/releases/download/" &
        MingwGccVersion &
        "/winlibs-x86_64-posix-seh-gcc-16.1.0-mingw-w64ucrt-14.0.0-r2.zip",
      sha256 = "78eff1e2e804b6a6320c713f084b8f820c662104a24cea6a3bfcab82032bdd60",
      archiveType = "zip",
      executablePath = "mingw64/bin/gcc.exe",
      packageId = "mingw-gcc@" & MingwGccVersion,
      cpu = "x86_64",
      os = "windows",
      lockIdentity = "tarball:mingw-gcc@" & MingwGccVersion &
        ":windows-x86_64:sha256:78eff1e2e804b6a6320c713f084b8f820c662104a24cea6a3bfcab82032bdd60"
