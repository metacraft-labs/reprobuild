## Shared supplier declaration for views of the same verified toolchain.
## GCC and GNU ar have different versions; the upstream release lists both:
## https://github.com/brechtsanders/winlibs_mingw/releases/tag/16.1.0posix-14.0.0-ucrt-r2
## Keep one archive pin and lock identity so the normal realizer can reuse a
## verified sibling prefix instead of downloading/extracting this bundle twice.
const
  WinLibsX64Url* = "https://github.com/brechtsanders/winlibs_mingw/releases/download/16.1.0posix-14.0.0-ucrt-r2/winlibs-x86_64-posix-seh-gcc-16.1.0-mingw-w64ucrt-14.0.0-r2.7z"
  WinLibsX64Sha256* = "62fb8588d2deee7d662dbcbd386702adbf19643764c971c38aa4839472eee232"
  WinLibsX64LockIdentity* = "tarball:gcc-winlibs@16.1.0:sha256:62fb8588d2deee7d662dbcbd386702adbf19643764c971c38aa4839472eee232"
  WinLibsX64PackageId* = "gcc-winlibs@16.1.0"
  WinLibsGccVersion* = "16.1.0"
  # Preserve the supplier snapshot spelling. The current SemVer uses-range
  # grammar does not accept four components; bare ar selection remains valid.
  WinLibsBinutilsVersion* = "2.46.0.20260210"
