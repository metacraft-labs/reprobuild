## DSL-port M9.R.14e.3 — engine threads the resolver's auxiliary
## search-path channels onto per-action env vars at fork time.
##
## ## Context
##
## M9.R.14e.1 plumbed four new channels through the resolver +
## ``ToolActionIdentity``; the CLI's ``mkToolIdentityResolver``
## projects them onto ``ResolvedToolIdentity.{pkgConfigDirs,
## cmakePrefixDirs, includeDirs, libDirs}``; this milestone validates
## the engine consumes those lists and prepends them to the action's
## env at fork time:
##
##   * ``pkgConfigDirs``     → ``PKG_CONFIG_PATH``
##   * ``cmakePrefixDirs``   → ``CMAKE_PREFIX_PATH``
##   * ``includeDirs``       → ``CPATH``
##   * ``libDirs``           → ``LIBRARY_PATH`` AND ``LD_LIBRARY_PATH``
##
## ## What this test pins
##
##   1. ``prependEnvDirsToArgvEnv`` correctly inserts a fresh
##      ``KEY=VALUE`` entry when the env list doesn't already have one.
##   2. ``prependEnvDirsToArgvEnv`` prepends to an existing value with
##      the platform path separator.
##   3. ``prependEnvDirsToArgvEnv`` collapses duplicates last-write-wins
##      (matches ``prependPathDirsToArgvEnv`` semantics).
##   4. ``prependEnvDirs`` (StringTable variant) does the same for the
##      bypass-spawn path.
##   5. ``applyResolvedAuxPathsArgv`` threads all four channels in one
##      pass, including the ``libDirs`` → ``LIBRARY_PATH`` +
##      ``LD_LIBRARY_PATH`` fan-out.
##   6. ``applyResolvedAuxPathsTable`` mirrors the argv variant for the
##      StringTable spawn path.
##   7. Empty input lists are a no-op (no env entries injected).
##   8. The order of channels is deterministic.

import std/[strtabs, strutils, unittest]

import repro_build_engine

const Sep =
  when defined(windows): ";"
  else: ":"

proc envValue(env: seq[string]; key: string): string =
  for entry in env:
    let eq = entry.find('=')
    if eq <= 0: continue
    if entry[0 ..< eq] == key:
      return entry[eq + 1 .. ^1]
  ""

suite "DSL-port M9.R.14e.3 — engine threads aux search-path channels onto action env":

  test "prependEnvDirsToArgvEnv inserts a fresh KEY=VALUE entry":
    let env = @["PATH=/usr/bin"]
    let result = prependEnvDirsToArgvEnv(env, "PKG_CONFIG_PATH",
      @["/synth/wayland/lib/pkgconfig"])
    let v = envValue(result, "PKG_CONFIG_PATH")
    check v.startsWith("/synth/wayland/lib/pkgconfig")

  test "prependEnvDirsToArgvEnv prepends to an existing value":
    let env = @["PKG_CONFIG_PATH=/existing/path"]
    let result = prependEnvDirsToArgvEnv(env, "PKG_CONFIG_PATH",
      @["/synth/wayland/lib/pkgconfig"])
    let v = envValue(result, "PKG_CONFIG_PATH")
    check v == "/synth/wayland/lib/pkgconfig" & Sep & "/existing/path"

  test "prependEnvDirsToArgvEnv dedupes existing entries last-write-wins":
    let env = @[
      "PKG_CONFIG_PATH=/old/first",
      "OTHER=value",
      "PKG_CONFIG_PATH=/old/second"]
    let result = prependEnvDirsToArgvEnv(env, "PKG_CONFIG_PATH",
      @["/synth/wayland/lib/pkgconfig"])
    var count = 0
    for entry in result:
      if entry.startsWith("PKG_CONFIG_PATH="):
        inc count
    check count == 1
    let v = envValue(result, "PKG_CONFIG_PATH")
    # Last value wins (the dedup pass keeps the most recent, then
    # prepends the new dir to it).
    check v == "/synth/wayland/lib/pkgconfig" & Sep & "/old/second"
    # Other entries survive unmolested.
    check envValue(result, "OTHER") == "value"

  test "prependEnvDirs (StringTable) prepends to an existing value":
    let table = newStringTable(modeCaseSensitive)
    table["PKG_CONFIG_PATH"] = "/existing/path"
    prependEnvDirs(table, "PKG_CONFIG_PATH",
      @["/synth/wayland/lib/pkgconfig"])
    check table["PKG_CONFIG_PATH"] ==
      "/synth/wayland/lib/pkgconfig" & Sep & "/existing/path"

  test "prependEnvDirs (StringTable) sets a fresh value when absent":
    let table = newStringTable(modeCaseSensitive)
    prependEnvDirs(table, "CMAKE_PREFIX_PATH", @["/synth/foo/usr"])
    check table["CMAKE_PREFIX_PATH"].startsWith("/synth/foo/usr")

  test "applyResolvedAuxPathsArgv threads all four channels in one pass":
    let env = @["PATH=/usr/bin"]
    let paths = ResolvedAuxPaths(
      pkgConfigDirs: @["/synth/wayland/lib/pkgconfig"],
      cmakePrefixDirs: @["/synth/wayland/usr"],
      includeDirs: @["/synth/wayland/include"],
      libDirs: @["/synth/wayland/lib"])
    let result = applyResolvedAuxPathsArgv(env, paths)
    check envValue(result, "PKG_CONFIG_PATH").startsWith(
      "/synth/wayland/lib/pkgconfig")
    check envValue(result, "CMAKE_PREFIX_PATH").startsWith(
      "/synth/wayland/usr")
    check envValue(result, "CPATH").startsWith(
      "/synth/wayland/include")
    # libDirs fan-out: ``LIBRARY_PATH`` (link-time) + ``LD_LIBRARY_PATH``
    # (run-time test execution).
    check envValue(result, "LIBRARY_PATH").startsWith("/synth/wayland/lib")
    check envValue(result, "LD_LIBRARY_PATH").startsWith("/synth/wayland/lib")

  test "applyResolvedAuxPathsTable threads all four channels on StringTable":
    let table = newStringTable(modeCaseSensitive)
    let paths = ResolvedAuxPaths(
      pkgConfigDirs: @["/synth/proto/share/pkgconfig"],
      cmakePrefixDirs: @["/synth/proto/usr"],
      includeDirs: @["/synth/proto/include"],
      libDirs: @["/synth/proto/lib"])
    applyResolvedAuxPathsTable(table, paths)
    check table["PKG_CONFIG_PATH"].startsWith("/synth/proto/share/pkgconfig")
    check table["CMAKE_PREFIX_PATH"].startsWith("/synth/proto/usr")
    check table["CPATH"].startsWith("/synth/proto/include")
    check table["LIBRARY_PATH"].startsWith("/synth/proto/lib")
    check table["LD_LIBRARY_PATH"].startsWith("/synth/proto/lib")

  test "empty paths leave env untouched":
    let env = @["PATH=/usr/bin", "USER=alice"]
    let paths = ResolvedAuxPaths()  # all four lists empty
    let result = applyResolvedAuxPathsArgv(env, paths)
    check result == env

  test "deterministic: same inputs produce same env":
    let env = @["PATH=/usr/bin"]
    let paths = ResolvedAuxPaths(
      pkgConfigDirs: @["/a/pc1", "/a/pc2"],
      cmakePrefixDirs: @["/a/usr"],
      includeDirs: @["/a/include"],
      libDirs: @["/a/lib"])
    let r1 = applyResolvedAuxPathsArgv(env, paths)
    let r2 = applyResolvedAuxPathsArgv(env, paths)
    check r1 == r2

  test "multiple deps' paths concatenate in order":
    # Two distinct from-source deps each contribute a pkgconfig dir.
    # The order matches the ``toolIdentityRefs`` order — first ref
    # leftmost (matches the M9.N Batch B PATH-prepend convention).
    let env = @["PATH=/usr/bin"]
    let paths = ResolvedAuxPaths(
      pkgConfigDirs: @[
        "/synth/wayland/lib/pkgconfig",
        "/synth/expat/lib/pkgconfig"])
    let result = applyResolvedAuxPathsArgv(env, paths)
    let v = envValue(result, "PKG_CONFIG_PATH")
    check v.startsWith("/synth/wayland/lib/pkgconfig" & Sep &
      "/synth/expat/lib/pkgconfig")

# ===========================================================================
# DSL-port M9.R.15q.3.3 — env-var dedup against ARG_MAX explosion.
# ===========================================================================

suite "DSL-port M9.R.15q.3.3 — aux-env dedup keeps argv under ARG_MAX":

  test "prependEnvDirsToArgvEnv dedupes duplicate dirs within input list":
    # plasma-framework's 25+ buildDeps' transitive walks emit the same
    # /opt/repro/.../qt6-base/.repro/output/install/usr prefix root from
    # multiple refs. The first wins; duplicates are dropped.
    let env = @["PATH=/usr/bin"]
    let paths = ResolvedAuxPaths(
      cmakePrefixDirs: @[
        "/synth/qt6-base/usr",
        "/synth/kconfig/usr",
        "/synth/qt6-base/usr",  # dup from another ref's transitive walk
        "/synth/kconfig/usr",   # dup
        "/synth/kcoreaddons/usr"])
    let result = applyResolvedAuxPathsArgv(env, paths)
    let v = envValue(result, "CMAKE_PREFIX_PATH")
    # First occurrence wins; the resulting list has each path ONCE.
    check v.count("/synth/qt6-base/usr") == 1
    check v.count("/synth/kconfig/usr") == 1
    check v.count("/synth/kcoreaddons/usr") == 1
    # Order preserved (first occurrence).
    let parts = v.split(Sep)
    let idxQt = parts.find("/synth/qt6-base/usr")
    let idxKc = parts.find("/synth/kconfig/usr")
    let idxKca = parts.find("/synth/kcoreaddons/usr")
    check idxQt < idxKc
    check idxKc < idxKca

  test "prependEnvDirsToArgvEnv dedupes against existing env value":
    # Host env (e.g. nix-shell) already has /A and /B on CMAKE_PREFIX_PATH.
    # A new ref contributing /B + /C must not duplicate /B in the
    # rendered list.
    let env = @["CMAKE_PREFIX_PATH=/A" & Sep & "/B"]
    let result = prependEnvDirsToArgvEnv(env, "CMAKE_PREFIX_PATH",
      @["/B", "/C"])
    let v = envValue(result, "CMAKE_PREFIX_PATH")
    let parts = v.split(Sep)
    check parts.len == 3
    check parts == @["/B", "/C", "/A"]

  test "prependEnvDirs (StringTable) dedupes against existing value":
    let table = newStringTable(modeCaseSensitive)
    table["CMAKE_PREFIX_PATH"] = "/A" & Sep & "/B"
    prependEnvDirs(table, "CMAKE_PREFIX_PATH", @["/B", "/C"])
    let v = table["CMAKE_PREFIX_PATH"]
    let parts = v.split(Sep)
    check parts.len == 3
    check parts == @["/B", "/C", "/A"]

  test "prependEnvDirs dedupes duplicate dirs within input list":
    let table = newStringTable(modeCaseSensitive)
    prependEnvDirs(table, "CPATH", @["/x/include", "/x/include", "/y/include"])
    let parts = table["CPATH"].split(Sep)
    check parts.len == 2
    check parts == @["/x/include", "/y/include"]

  test "prependEnvDirs idempotent — re-running yields the same value":
    # Two consecutive merges with the same dir list must NOT keep
    # growing the env var. This is the ARG_MAX-killing pattern: an
    # action that gets re-prepended on every retry would otherwise
    # double its env each time.
    let table = newStringTable(modeCaseSensitive)
    table["CMAKE_PREFIX_PATH"] = "/host/sysroot"
    prependEnvDirs(table, "CMAKE_PREFIX_PATH", @["/synth/qt6-base/usr"])
    let firstValue = table["CMAKE_PREFIX_PATH"]
    prependEnvDirs(table, "CMAKE_PREFIX_PATH", @["/synth/qt6-base/usr"])
    let secondValue = table["CMAKE_PREFIX_PATH"]
    check firstValue == secondValue
    check firstValue.split(Sep).len == 2
