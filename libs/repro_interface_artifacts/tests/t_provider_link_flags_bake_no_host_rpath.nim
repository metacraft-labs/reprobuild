## The provider / interface-extract compile never bakes a HOST library
## directory into the binary's RPATH.
##
## WHY. `externalHashFlags` replays `config.nims`'s C-library flags for the
## binaries Reprobuild compiles from a recipe (the project provider, the
## interface extract runner). Its SQLite block preferred `/usr/lib` and added
## `-Wl,-rpath,/usr/lib`. Those compiles run in an allowlisted environment, so
## `SQLITE_LIBDIR`/`SQLITE_PREFIX` from the dev shell are not visible and the
## host directory won. On a distribution whose glibc differs from Nix's, the
## provider then loaded the host libc from that RPATH under Nix's loader and
## died with SIGSEGV (`provider exited with code 139`) before reading the
## recipe — every `repro exec` / `repro build` of a recipe failed.
##
## Asserts, with SQLITE_LIBDIR / SQLITE_PREFIX unset (the allowlisted-edge
## shape):
##   1. no `-Wl,-rpath,` flag names a directory under `/usr` or `/lib*`;
##   2. when a Nix store SQLite exists on this host, the SQLite `-L` names it.
## Falsifiability (observed): on a host with /usr/lib/libsqlite3.so the
## pre-fix flags carry `--passL:-Wl,-rpath,/usr/lib`.
##
## NO MOCKS: the real flag builder over the real filesystem and /nix/store.

import std/[os, strutils, unittest]

import repro_interface_artifacts

proc isHostDir(d: string): bool =
  d == "/usr" or d.startsWith("/usr/") or d == "/lib" or
    d.startsWith("/lib/") or d == "/lib64" or d.startsWith("/lib64/")

suite "provider link flags bake no host RPATH":
  test "sqlite_resolution_never_bakes_a_host_rpath":
    when defined(windows) or defined(macosx):
      skip("the SQLite -L/-rpath block exists only on Linux-like hosts")
    else:
      let savedLib = getEnv("SQLITE_LIBDIR")
      let savedPrefix = getEnv("SQLITE_PREFIX")
      delEnv("SQLITE_LIBDIR")
      delEnv("SQLITE_PREFIX")
      defer:
        if savedLib.len > 0: putEnv("SQLITE_LIBDIR", savedLib)
        if savedPrefix.len > 0: putEnv("SQLITE_PREFIX", savedPrefix)
      let flags = consumerCompilePathFlags()
      var hostRpaths: seq[string] = @[]
      var sqliteL = ""
      for f in flags:
        const rp = "--passL:-Wl,-rpath,"
        if f.startsWith(rp):
          for d in f[rp.len .. ^1].split(':'):
            if isHostDir(d): hostRpaths.add(d)
        if f.startsWith("--passL:-L") and
            (fileExists(f[10 .. ^1] / "libsqlite3.so") or
             fileExists(f[10 .. ^1] / "libsqlite3.a")):
          sqliteL = f[10 .. ^1]
      checkpoint("host rpaths: " & $hostRpaths & "; sqlite -L: " & sqliteL)
      check hostRpaths.len == 0
      var nixSqlite = false
      for kind, path in walkDir("/nix/store"):
        if kind == pcDir and "-sqlite-" in path and
            fileExists(path / "lib" / "libsqlite3.so"):
          nixSqlite = true
          break
      if nixSqlite:
        check sqliteL.startsWith("/nix/store/")
