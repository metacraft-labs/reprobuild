## Target-specific dynamic-library names used by the binary-cache client.
##
## Keep selection pure and explicit so non-Darwin hosts can verify the exact
## name passed to ``loadLib`` on Darwin.  A bare leaf name does not use the
## image's LC_RPATH entries; ``@rpath`` is therefore part of the Darwin name.

type ZstdDynlibTarget* = enum
  zdtWindows
  zdtLinux
  zdtDarwin
  zdtOtherPosix

func zstdDynlibName*(target: ZstdDynlibTarget): string =
  case target
  of zdtWindows:
    "libzstd.dll"
  of zdtLinux:
    "libzstd.so.1"
  of zdtDarwin:
    "@rpath/libzstd.1.dylib"
  of zdtOtherPosix:
    "libzstd.so.1"

const HostZstdDynlibTarget* =
  when defined(windows):
    zdtWindows
  elif defined(linux):
    zdtLinux
  elif defined(macosx):
    zdtDarwin
  else:
    zdtOtherPosix
