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
##                              + ``QT_ADDITIONAL_PACKAGES_PREFIX_PATH``
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

import std/[options, strtabs, strutils, unittest]

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
    check envValue(result, "QT_ADDITIONAL_PACKAGES_PREFIX_PATH").startsWith(
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
    check table["QT_ADDITIONAL_PACKAGES_PREFIX_PATH"].startsWith(
      "/synth/proto/usr")
    check table["CPATH"].startsWith("/synth/proto/include")
    check table["LIBRARY_PATH"].startsWith("/synth/proto/lib")
    check table["LD_LIBRARY_PATH"].startsWith("/synth/proto/lib")

  test "source Perl module roots reach both action launch paths":
    let perlLib =
      "/workspace/recipes/packages/source/perl/.repro/output/install/usr/lib"
    let moduleRoot = perlLib & "/perl5"
    let paths = ResolvedAuxPaths(libDirs: @[perlLib, "/synth/other/lib"])

    let argvResult = applyResolvedAuxPathsArgv(
      @["PERL5LIB=/inherited/perl"], paths)
    check envValue(argvResult, "PERL5LIB") ==
      moduleRoot & Sep & "/inherited/perl"

    let table = newStringTable(modeCaseSensitive)
    table["PERL5LIB"] = "/inherited/perl"
    applyResolvedAuxPathsTable(table, paths)
    check table["PERL5LIB"] == moduleRoot & Sep & "/inherited/perl"

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

  test "explicit runtime loader env overrides dependency projection":
    let paths = ResolvedAuxPaths(libDirs: @["/source/readline/lib"])

    let projectedArgv = applyResolvedAuxPathsArgv(
      @["LD_LIBRARY_PATH=/inherited/lib"], paths)
    let overriddenArgv = applyExplicitRuntimeLibraryEnvOverrides(
      projectedArgv, @["LD_LIBRARY_PATH="])
    check envValue(overriddenArgv, "LD_LIBRARY_PATH") == ""

    let table = newStringTable(modeCaseSensitive)
    table["LD_LIBRARY_PATH"] = "/inherited/lib"
    applyResolvedAuxPathsTable(table, paths)
    applyExplicitRuntimeLibraryEnvOverrides(table, @["LD_LIBRARY_PATH="])
    check table.hasKey("LD_LIBRARY_PATH")
    check table["LD_LIBRARY_PATH"] == ""

  test "explicit runtime loader env uses last action value":
    let projected = @["PATH=/usr/bin", "LD_LIBRARY_PATH=/source/lib"]
    let overridden = applyExplicitRuntimeLibraryEnvOverrides(projected,
      @["LD_LIBRARY_PATH=/first", "LD_LIBRARY_PATH=/selected"])
    check envValue(overridden, "LD_LIBRARY_PATH") == "/selected"
    var loaderEntries = 0
    for entry in overridden:
      if entry.startsWith("LD_LIBRARY_PATH="):
        inc loaderEntries
    check loaderEntries == 1

  when defined(posix):
    test "shell actions export runtime paths after interpreter startup":
      let argv = @["/nix/store/bash/bin/sh", "-c", "printf ready"]
      let env = @[
        "PATH=/usr/bin",
        "LD_LIBRARY_PATH=/source/readline/lib:/host/lib",
        "OTHER=value"]
      let deferred = deferRuntimeLibraryEnvForShell(argv, env)
      check envValue(deferred.env, "LD_LIBRARY_PATH") == ""
      check envValue(deferred.env, "OTHER") == "value"
      check deferred.argv[0] == argv[0]
      check deferred.argv[2].startsWith(
        "export LD_LIBRARY_PATH=/source/readline/lib:/host/lib; ")
      check deferred.argv[2].endsWith("printf ready")

    test "monitor-wrapped shell actions defer runtime paths":
      let argv = @[
        "/opt/repro/bin/repro", "internal", "io", "monitor",
        "--depfile", "/tmp/action.rdep", "--",
        "/nix/store/bash/bin/bash", "-lc", "run-build"]
      let env = @[
        "LD_LIBRARY_PATH=/source/lib",
        "DYLD_LIBRARY_PATH=/source/macos/lib"]
      let deferred = deferRuntimeLibraryEnvForShell(argv, env)
      check deferred.env.len == 0
      check deferred.argv[9].startsWith(
        "export LD_LIBRARY_PATH=/source/lib; " &
        "export DYLD_LIBRARY_PATH=/source/macos/lib; ")
      check deferred.argv[9].endsWith("run-build")

    test "monitor-wrapped direct actions defer runtime paths":
      let argv = @[
        "/opt/repro/bin/repro", "internal", "io", "monitor",
        "--depfile", "/tmp/action.rdep", "--",
        "/nix/store/cmake/bin/cmake", "-S", ".", "-B", "build"]
      let env = @[
        "PATH=/usr/bin",
        "LD_LIBRARY_PATH=/source/sqlite/lib"]
      let deferred = deferRuntimeLibraryEnvForShell(argv, env)
      check envValue(deferred.env, "LD_LIBRARY_PATH") == ""
      check envValue(deferred.env, "PATH") == "/usr/bin"
      check deferred.argv[0 .. 6] == argv[0 .. 6]
      when defined(macosx):
        check deferred.argv[7] == resolveNonSipShell()
        check deferred.argv[7].len > 0
        check deferred.argv[7] != "/bin/sh"
      else:
        check deferred.argv[7] == "/bin/sh"
      check deferred.argv[8] == "-c"
      check deferred.argv[9].startsWith(
        "export LD_LIBRARY_PATH=/source/sqlite/lib; ")
      check deferred.argv[9].endsWith("exec \"$@\"")
      check deferred.argv[10] == "sh"
      check deferred.argv[11 .. ^1] == argv[7 .. ^1]

    test "non-shell actions retain runtime paths in their environment":
      let argv = @["/usr/bin/cc", "input.c"]
      let env = @["LD_LIBRARY_PATH=/source/lib"]
      let deferred = deferRuntimeLibraryEnvForShell(argv, env)
      check deferred.argv == argv
      check deferred.env == env

    test "StringTable launcher defers shell runtime paths":
      let argv = @["/bin/sh", "-c", "run-build"]
      let table = newStringTable(modeCaseSensitive)
      table["PATH"] = "/usr/bin"
      table["LD_LIBRARY_PATH"] = "/source/lib"
      let deferredArgv = deferRuntimeLibraryEnvForShell(argv, table)
      check not table.hasKey("LD_LIBRARY_PATH")
      check table["PATH"] == "/usr/bin"
      check deferredArgv[2].startsWith(
        "export LD_LIBRARY_PATH=/source/lib; ")
      check deferredArgv[2].endsWith("run-build")

    test "StringTable launcher defers monitored direct runtime paths":
      let argv = @[
        "/opt/repro/bin/repro", "internal", "io", "monitor",
        "--depfile", "/tmp/action.rdep", "--", "/usr/bin/cmake"]
      let table = newStringTable(modeCaseSensitive)
      table["LD_LIBRARY_PATH"] = "/source/sqlite/lib"
      let deferredArgv = deferRuntimeLibraryEnvForShell(argv, table)
      check not table.hasKey("LD_LIBRARY_PATH")
      when defined(macosx):
        check deferredArgv[7] == resolveNonSipShell()
        check deferredArgv[7].len > 0
        check deferredArgv[7] != "/bin/sh"
      else:
        check deferredArgv[7] == "/bin/sh"
      check deferredArgv[8] == "-c"
      check deferredArgv[9].contains(
        "export LD_LIBRARY_PATH=/source/sqlite/lib; ")
      check deferredArgv[9].endsWith("exec \"$@\"")
      check deferredArgv[11] == "/usr/bin/cmake"

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

  test "host dependency paths precede native toolchain paths":
    let action = BuildAction(
      governingLockIdentity: lockIdentityOutsideSolvedGraph(),
      toolIdentityRefs: @["gcc", "libdrm", "wayland"],
      toolIdentityRefKinds: @[dkNative, dkBuild, dkBuild])
    let resolver: ToolIdentityResolver =
      proc(name: string; kind: DepKind):
          Option[ResolvedToolIdentity] {.gcsafe, closure.} =
        case name
        of "gcc":
          check kind == dkNative
          some(ResolvedToolIdentity(
            includeDirs: @["/sysroot/include", "/sysroot/include/drm"],
            libDirs: @["/sysroot/lib"]))
        of "libdrm":
          check kind == dkBuild
          some(ResolvedToolIdentity(
            includeDirs: @["/libdrm/include", "/libdrm/include/libdrm"],
            libDirs: @["/libdrm/lib"]))
        of "wayland":
          check kind == dkBuild
          some(ResolvedToolIdentity(includeDirs: @["/wayland/include"]))
        else:
          none(ResolvedToolIdentity)

    let paths = collectResolvedAuxPaths(action, resolver)
    check paths.includeDirs == @["/libdrm/include",
      "/libdrm/include/libdrm", "/wayland/include",
      "/sysroot/include", "/sysroot/include/drm"]
    check paths.libDirs == @["/libdrm/lib", "/sysroot/lib"]

  test "source toolchain headers use ordered compiler system flags":
    let glibcRoot =
      "/workspace/recipes/packages/source/glibc/.repro/output/install/usr/include"
    let linuxRoot =
      "/workspace/recipes/packages/source/linux-headers/.repro/output/install/usr/include"
    let paths = ResolvedAuxPaths(includeDirs: @[
      linuxRoot,
      "/workspace/recipes/packages/source/gcc/.repro/output/install/usr/include/c++/14.2.0",
      glibcRoot & "/x86_64-linux-gnu",
      "/workspace/recipes/packages/source/libdrm/.repro/output/install/usr/include/libdrm",
      glibcRoot])
    let env = @[
      "CPATH=/inherited/include",
      "CPPFLAGS=-D_FILE_OFFSET_BITS=64",
      "CFLAGS=-O2",
      "CXXFLAGS=-O3",
      "HOSTCFLAGS=-Os",
      "HOSTCXXFLAGS=-Oz",
      "CPPFLAGS_FOR_BUILD=-DBUILD_HELPER",
      "CFLAGS_FOR_BUILD=-Og",
      "CXXFLAGS_FOR_BUILD=-O0"]
    let result = applyResolvedAuxPathsArgv(env, paths)
    let systemFlags =
      "-idirafter " & glibcRoot & " -idirafter " & linuxRoot
    check envValue(result, "CPATH") ==
      "/workspace/recipes/packages/source/libdrm/.repro/output/install/usr/include/libdrm" &
      Sep & "/inherited/include"
    check envValue(result, "CPPFLAGS") ==
      systemFlags & " -D_FILE_OFFSET_BITS=64"
    check envValue(result, "CFLAGS") == systemFlags & " -O2"
    check envValue(result, "CXXFLAGS") == systemFlags & " -O3"
    check envValue(result, "HOSTCFLAGS") == systemFlags & " -Os"
    check envValue(result, "HOSTCXXFLAGS") == systemFlags & " -Oz"
    check envValue(result, "CPPFLAGS_FOR_BUILD") ==
      systemFlags & " -DBUILD_HELPER"
    check envValue(result, "CFLAGS_FOR_BUILD") == systemFlags & " -Og"
    check envValue(result, "CXXFLAGS_FOR_BUILD") == systemFlags & " -O0"

  test "StringTable source system-header projection mirrors argv env":
    let glibcRoot =
      "/workspace/recipes/packages/source/glibc/.repro/output/install/usr/include"
    let linuxRoot =
      "/workspace/recipes/packages/source/linux-headers/.repro/output/install/usr/include"
    let paths = ResolvedAuxPaths(includeDirs: @[
      "/workspace/recipes/packages/source/gcc/.repro/output/install/usr/include",
      linuxRoot,
      "/ordinary/include",
      glibcRoot])
    let table = newStringTable(modeCaseSensitive)
    table["CPATH"] = "/inherited/include"
    table["CPPFLAGS"] = "-DTEST"
    table["CFLAGS"] = "-O1"
    table["CXXFLAGS"] = "-O2"
    table["HOSTCFLAGS"] = "-Os"
    table["HOSTCXXFLAGS"] = "-Oz"
    table["CPPFLAGS_FOR_BUILD"] = "-DBUILD"
    table["CFLAGS_FOR_BUILD"] = "-Og"
    table["CXXFLAGS_FOR_BUILD"] = "-O0"
    applyResolvedAuxPathsTable(table, paths)
    let systemFlags =
      "-idirafter " & glibcRoot & " -idirafter " & linuxRoot
    check table["CPATH"] == "/ordinary/include" & Sep & "/inherited/include"
    check table["CPPFLAGS"] == systemFlags & " -DTEST"
    check table["CFLAGS"] == systemFlags & " -O1"
    check table["CXXFLAGS"] == systemFlags & " -O2"
    check table["HOSTCFLAGS"] == systemFlags & " -Os"
    check table["HOSTCXXFLAGS"] == systemFlags & " -Oz"
    check table["CPPFLAGS_FOR_BUILD"] == systemFlags & " -DBUILD"
    check table["CFLAGS_FOR_BUILD"] == systemFlags & " -Og"
    check table["CXXFLAGS_FOR_BUILD"] == systemFlags & " -O0"

  test "direct GCC-family compiler actions receive system includes":
    let glibcRoot = "/source/glibc/usr/include"
    let linuxRoot = "/source/linux/usr/include"
    let argv = @[
      "/opt/repro/bin/repro", "internal", "io", "monitor",
      "--depfile", "/tmp/action.rdep", "--",
      "/source/gcc/bin/x86_64-linux-gnu-g++-14", "-c", "input.cc"]
    let result = applyCompilerSystemIncludeArgs(argv,
      @[glibcRoot, linuxRoot])
    check result == @[
      "/opt/repro/bin/repro", "internal", "io", "monitor",
      "--depfile", "/tmp/action.rdep", "--",
      "/source/gcc/bin/x86_64-linux-gnu-g++-14",
      "-idirafter", glibcRoot, "-idirafter", linuxRoot,
      "-c", "input.cc"]

  test "non-compiler argv ignores system include projection":
    let argv = @["meson", "compile", "-C", "build"]
    check applyCompilerSystemIncludeArgs(argv,
      @["/source/glibc/usr/include"]) == argv

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
