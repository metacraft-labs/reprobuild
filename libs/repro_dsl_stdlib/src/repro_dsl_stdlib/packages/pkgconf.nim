import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

const PkgconfMsys2Version* = "2.5.1-2"
  ## MSYS2's ``pkgver-pkgrel`` of the Windows realization (the package file
  ## carries MSYS2's epoch, ``1~``); the record's ``version`` is pkgconf's.

package pkgconf:
  provisioning:
    nixPackage "nixpkgs#pkgconf", executablePath = "bin/pkgconf",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash
    # Windows x86_64: MSYS2's UCRT64 pkgconf, a native program (not an MSYS
    # one), so it runs without an MSYS runtime. ``bin`` keeps ``pkgconf.exe``,
    # its ``pkg-config.exe`` spelling and the ``libpkgconf-7.dll`` both load
    # from their own directory; the library's headers, import library and
    # documentation are pruned. On Windows pkgconf derives a ``.pc`` file's
    # ``prefix`` from the file's own location, which is what makes the
    # MSYS2 ``-dev`` archives' ``prefix=/ucrt64`` usable from any prefix.
    tarball url = "https://repo.msys2.org/mingw/ucrt64/mingw-w64-ucrt-x86_64-pkgconf-1~" &
        PkgconfMsys2Version & "-any.pkg.tar.zst",
      sha256 = "8b99a0fb51d13cb9d86cefcd1b130142b9a198a86e9786cd56ab59e452e0e4ba",
      archiveType = "tar.zst",
      stripComponents = 1,
      prune = "include",
      prune = "lib",
      prune = "share",
      executablePath = "bin/pkgconf.exe",
      extraExecutable = "bin/pkg-config.exe",
      version = "2.5.1",
      packageId = "pkgconf@" & PkgconfMsys2Version,
      cpu = "x86_64",
      os = "windows",
      lockIdentity = "tarball:pkgconf@" & PkgconfMsys2Version &
        ":windows-x86_64:sha256:8b99a0fb51d13cb9d86cefcd1b130142b9a198a86e9786cd56ab59e452e0e4ba"

  executable pkgconf:
    discard
