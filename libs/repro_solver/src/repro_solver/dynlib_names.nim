## Target-specific dynamic-library names used by the clingo bindings.
##
## Darwin must name the LC_RPATH token explicitly.  Unlike ELF soname lookup,
## ``dlopen("libclingo.dylib")`` does not search an image's LC_RPATH entries.

type ClingoDynlibTarget* = enum
  cdtWindows
  cdtLinux
  cdtDarwin
  cdtOtherPosix

func clingoDynlibName*(target: ClingoDynlibTarget): string =
  case target
  of cdtWindows:
    "clingo.dll"
  of cdtLinux:
    "libclingo.so"
  of cdtDarwin:
    "@rpath/libclingo.dylib"
  of cdtOtherPosix:
    "libclingo.so"

const HostClingoDynlibTarget* =
  when defined(windows):
    cdtWindows
  elif defined(linux):
    cdtLinux
  elif defined(macosx):
    cdtDarwin
  else:
    cdtOtherPosix
