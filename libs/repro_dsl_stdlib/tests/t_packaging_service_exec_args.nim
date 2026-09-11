## A service's ARGUMENTS are per-target, and two spellings of one path
## are a drift, not a duplicate.
##
## Distribution-And-Packaging M1's N22 and N6.
##
## N22 was found by reading `sc qc` on an installed MSI:
##
##   BINARY_PATH_NAME : "C:\Program Files\reprobuild-binary-cache\bin\
##       repro-binary-cache.exe" --root=/var/lib/repro-binary-cache
##       --listen=0.0.0.0:7878
##
## `/var/lib/repro-binary-cache` is not a path Windows has.
## `ServiceDef.execArgs` is carried verbatim by every renderer -- systemd,
## launchd, rc.d and the MSI `ServiceInstall` row all splice the same list
## -- so ONE list had to be right for a filesystem with a root directory
## and one with drive letters, and it was right for the first.
##
## The cases below are about three separable claims, and each is written
## so that it fails if the fix is reverted:
##
## 1. the argument list DIFFERS BY TARGET, and the Windows one is a
##    Windows path (drive letter, backslashes, no POSIX root);
## 2. the value the packaging layer renders is the SAME STRING as the
##    daemon's own compiled-in default, read out of the daemon's source
##    rather than restated here -- because the failure mode they guard
##    against is precisely the two drifting apart, and a test that
##    restated the literal would drift with them;
## N6 -- the same class of defect one layer down, where a recipe-supplied
## leaf name reached a generated shell script's `case` pattern list
## unquoted -- is covered in `t_packaging_runtime_closure`, beside the
## rest of the closure script's cases.

import std/[os, strutils, unittest]

import repro_project_dsl
import repro_dsl_stdlib/packaging
import ./packaging_test_support

proc cacheDaemonSource(): string =
  ## The daemon's own source, read from disk. The point of the guard is
  ## that the packaging layer and the program agree, so one of the two
  ## has to be read rather than repeated.
  let p = repoRootFromTest() &
    "/apps/repro-binary-cache/repro_binary_cache.nim"
  doAssert fileExists(p), "cache daemon source not found at " & p
  readFile(p)

suite "service exec arguments are per-target":

  test "the cache service's --root differs by target":
    let posix = reprobuildCacheService(toLinux)
    let win = reprobuildCacheService(toWindows)
    let darwin = reprobuildCacheService(toDarwin)
    doAssert posix.execArgs.len == 2
    doAssert win.execArgs.len == 2
    # The DEFECT, stated as an inequality. Before the fix these two were
    # the same string.
    doAssert posix.execArgs[0] != win.execArgs[0],
      "the POSIX and Windows --root are the same string: " &
        posix.execArgs[0]
    doAssert posix.execArgs[0] == "--root=/var/lib/repro-binary-cache"
    doAssert darwin.execArgs[0] == posix.execArgs[0]
    # The listen argument is genuinely target-independent and stays one
    # string; asserting that keeps "per-target" from being read as
    # "everything is per-target".
    doAssert posix.execArgs[1] == win.execArgs[1]

  test "the Windows --root is a Windows path":
    let win = reprobuildCacheService(toWindows)
    let root = win.execArgs[0]
    doAssert root.startsWith("--root="), root
    let path = root["--root=".len .. ^1]
    doAssert not path.startsWith("/"), path
    doAssert path.len > 2 and path[1] == ':' and path[0].isUpperAscii(), path
    doAssert '\\' in path, path
    doAssert '/' notin path, path
    # A literal environment reference would be WORSE than the POSIX path
    # it replaced: the SCM does not expand one in a service's argument
    # list, so the daemon would create a directory of that name.
    doAssert '%' notin path, path

  test "the layer's state directory is the daemon's own default":
    # N22's drift guard. `reprobuildCacheStateDir(toWindows)` and the
    # daemon's `WindowsCacheStateDir` are the same fact written twice; the
    # test reads the SECOND from source so a change to either alone fails
    # here rather than in a service that writes its state somewhere the
    # operator cannot find it.
    let src = cacheDaemonSource()
    for targetOs, konst in {toWindows: "WindowsCacheStateDir",
                            toLinux: "PosixCacheStateDir"}.items:
      let wanted = reprobuildCacheStateDir(targetOs)
      var found = false
      for line in src.splitLines():
        let t = line.strip()
        if t.startsWith(konst & "* ="):
          doAssert t.contains(wanted),
            konst & " in the daemon is " & t & ", the layer says " & wanted
          found = true
      doAssert found, konst & " not found in the cache daemon's source"

  test "the service name the layer registers is the name the binary answers to":
    # The SCM protocol the daemon now speaks (M1's N23) names itself when
    # it connects to the dispatcher. If that string and the
    # `ServiceInstall` row's name ever part company, nothing on Windows
    # reports it: for a SERVICE_WIN32_OWN_PROCESS service the SCM accepts
    # the connection regardless, and the divergence shows up only as a
    # service that behaves oddly under `sc control`.
    let name = reprobuildCacheService(toWindows).name
    doAssert name == "repro-binary-cache", name
    var found = false
    for line in cacheDaemonSource().splitLines():
      let t = line.strip()
      if t.startsWith("WindowsServiceName* ="):
        doAssert t.contains("\"" & name & "\""), t
        found = true
    doAssert found, "WindowsServiceName not found in the cache daemon"
