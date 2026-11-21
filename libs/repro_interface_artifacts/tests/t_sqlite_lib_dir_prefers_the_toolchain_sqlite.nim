## The provider / interface-extract compile links the SQLite of the toolchain
## that built `repro`, not the first `*-sqlite-*` the Nix store sorts to.
##
## WHY. `externalHashFlags` adds the SQLite `-L` (and `-rpath`) for the
## binaries Reprobuild compiles from a recipe. Those compiles run with an
## allowlisted environment, so the dev shell's `SQLITE_PREFIX` is not visible,
## and resolution fell straight through to the store glob. A store holds many
## SQLite builds, each linked against the glibc of the nixpkgs revision that
## produced it, and "first sorted" is arbitrary with respect to that glibc. The
## provider link then failed against a SQLite built for a NEWER glibc than the
## toolchain's:
##
##   ld: /nix/store/9x0m6s73…-sqlite-3.53.3/lib/libsqlite3.so:
##       undefined reference to `sinh@GLIBC_2.44'
##
## `config.nims` already consulted the dev shell's own `-L` inputs
## (`NIX_LDFLAGS`) before the glob; the replay here did not, and it had no
## build-time prefix of its own the way blake3 / xxhash / clingo do
## (`BuiltLibraryPrefixes`).
##
## HOW. `resolveSqliteLibDir` takes every input — the explicit env values, the
## prefix baked in when `repro` was built, `NIX_LDFLAGS` and the store root —
## as parameters, so the cases below build a store-shaped directory in a temp
## dir. In it the prefix that sorts FIRST (`0000…-sqlite-…`) is never the
## toolchain's; a resolver that consults the glob before the toolchain's own
## choice returns it. The last case drives the real `consumerCompilePathFlags`
## over the real `/nix/store` with the caller's SQLite variables removed, the
## shape of the allowlisted provider edge.
##
## Falsifiability (observed at a49608e63 with only the extraction applied, the
## order unchanged): the built-prefix and NIX_LDFLAGS cases return
## `0000…-sqlite-3.53.3/lib`, and on a host whose first sorted store SQLite is
## not the dev shell's the real-store case reports that first match.
##
## NO MOCKS. The fake store root is a directory of real files: the property is
## "pick the toolchain's build over an earlier-sorting one", and the host's own
## `/nix/store` cannot be relied on to hold two builds in that order. The
## `libsqlite3.so` files carry a real host-architecture ELF header because
## `nixLibDirIn` rejects candidates whose header names another architecture
## (`soMatchesHostArch`); the header is the only part of the file it reads.

import std/[os, strutils, tempfiles, unittest]
import repro_test_support/reasoned_skip

import repro_interface_artifacts

when hostCPU == "arm64":
  const hostMachine = 0xB7'u16          # EM_AARCH64
else:
  const hostMachine = 0x3E'u16          # EM_X86_64

const
  ## Store-path names. `0000…` sorts first and stands for a SQLite built
  ## against a newer glibc than the toolchain's; `5555…` is the toolchain's.
  newerGlibcSqlite = "0000aaaa-sqlite-3.53.3"
  toolchainSqlite = "5555bbbb-sqlite-3.51.2"
  ## The SQLite the dev shell that compiled THIS test exported. The library
  ## bakes the same value into `BuiltLibraryPrefixes`, so the real-store case
  ## below can name what the resolution should produce.
  compileTimeSqlitePrefix = static(getEnv("SQLITE_PREFIX"))

proc elf64Header(machine: uint16): string =
  ## A little-endian 64-bit ELF identification + `e_machine` (System V gABI,
  ## https://www.sco.com/developers/gabi/latest/ch4.eheader.html).
  result = newString(64)
  result[0] = '\x7F'
  result[1] = 'E'
  result[2] = 'L'
  result[3] = 'F'
  result[4] = '\x02'                      # ELFCLASS64
  result[5] = '\x01'                      # ELFDATA2LSB
  result[6] = '\x01'                      # EV_CURRENT
  result[18] = char(machine and 0xFF)
  result[19] = char(machine shr 8)

proc addSqlitePrefix(storeRoot, name: string): string =
  ## Create `<storeRoot>/<name>/lib/libsqlite3.so` and return the libdir.
  result = storeRoot / name / "lib"
  createDir(result)
  writeFile(result / "libsqlite3.so", elf64Header(hostMachine))

suite "sqlite lib dir prefers the toolchain's sqlite":
  when defined(windows) or defined(macosx):
    test "sqlite_resolution_is_linux_only":
      skip("the SQLite -L/-rpath block exists only on Linux-like hosts")
  else:
    var tmp: string
    var store: string
    var firstLib, toolchainLib: string

    setup:
      tmp = createTempDir("repro-sqlite-libdir-", "")
      store = tmp / "store"
      firstLib = addSqlitePrefix(store, newerGlibcSqlite)
      toolchainLib = addSqlitePrefix(store, toolchainSqlite)

    teardown:
      removeDir(tmp)

    test "built_prefix_wins_over_the_first_sorted_store_sqlite":
      # The packaged / dev-shell-built `repro` carries the SQLite it was
      # linked with; that is the one whose glibc matches the toolchain.
      check resolveSqliteLibDir("", "", store / toolchainSqlite, "",
        store, hostDirs = []) == toolchainLib

    test "nix_ldflags_wins_over_the_first_sorted_store_sqlite":
      # A `repro` built without a baked prefix, run in a Nix shell: the
      # shell's own link inputs are its deliberate choice for its target.
      let ldflags = "-L/nonexistent -L" & toolchainLib & " -lfoo"
      check resolveSqliteLibDir("", "", "", ldflags, store,
        hostDirs = []) == toolchainLib

    test "missing_built_prefix_falls_through_to_nix_ldflags":
      # A relocated binary whose baked store path does not exist on this host.
      check resolveSqliteLibDir("", "", tmp / "gone", "-L" & toolchainLib,
        store, hostDirs = []) == toolchainLib

    test "explicit_libdir_and_prefix_win_over_everything":
      let explicitLib = addSqlitePrefix(tmp / "explicit", "sqlite")
      check resolveSqliteLibDir(explicitLib, "", store / toolchainSqlite,
        "-L" & toolchainLib, store, hostDirs = []) == explicitLib
      check resolveSqliteLibDir("", tmp / "explicit" / "sqlite",
        store / toolchainSqlite, "-L" & toolchainLib, store,
        hostDirs = []) == explicitLib

    test "store_glob_remains_the_fallback":
      # Nothing names a SQLite: the old behaviour, the first sorted match.
      check resolveSqliteLibDir("", "", "", "", store,
        hostDirs = []) == firstLib

    test "host_dirs_only_without_a_nix_store":
      let hostLib = addSqlitePrefix(tmp / "host", "usr")
      check resolveSqliteLibDir("", "", "", "", tmp / "no-store",
        hostDirs = [tmp / "host" / "usr"]) == hostLib

    test "real_provider_flags_link_the_build_shells_sqlite":
      # The allowlisted provider edge: no caller SQLite variables and no
      # NIX_LDFLAGS. The flags must still name the SQLite of the shell that
      # built this binary rather than whatever `/nix/store` sorts first.
      if compileTimeSqlitePrefix.len == 0 or
          not fileExists(compileTimeSqlitePrefix / "lib" / "libsqlite3.so"):
        skip("compiled outside a shell exporting SQLITE_PREFIX; no " &
          "build-time SQLite to compare against")
      else:
        var saved: seq[(string, string)] = @[]
        for name in ["SQLITE_LIBDIR", "SQLITE_PREFIX", "NIX_LDFLAGS"]:
          saved.add((name, getEnv(name)))
          delEnv(name)
        defer:
          for (name, value) in saved:
            if value.len > 0: putEnv(name, value)
        var sqliteL = ""
        for f in consumerCompilePathFlags():
          if f.startsWith("--passL:-L") and
              fileExists(f[10 .. ^1] / "libsqlite3.so"):
            sqliteL = f[10 .. ^1]
        checkpoint("sqlite -L: " & sqliteL)
        check sqliteL == compileTimeSqlitePrefix / "lib"
