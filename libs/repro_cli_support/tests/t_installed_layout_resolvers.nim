## The two resolvers that could not name an installed package's files.
##
## `resolveMonitorShimLibPath` and `providerDynamicLibDir` both look for
## a library the flake installs out of `build/lib`, and before this both
## looked for it ONLY under a reprobuild SOURCE CHECKOUT: an env
## override, an adjacent checkout derived from `getAppFilename()`, and
## `$REPROBUILD_SOURCE_ROOT/build/lib`. An installed `/usr/bin/repro.real`
## is inside no checkout and has no `build/` anywhere near it, so a
## native package matched none of them however its files were laid out —
## and the FIRST error of every `repro build` from a .deb was
## `repro internal io monitor: error: cannot find
## librepro_monitor_shim.so`, before anything else could be reached.
##
## That makes shipping the two libraries necessary and not sufficient,
## which is why the fix is here and not only in the packaging recipe.
## The arm each resolver grew reads `$REPROBUILD_RUNTIME_LIBRARY_PATH` —
## already part of the §5 wrapper contract, already set by the wrapper
## to the package's private libdir, and already the installed closure's
## search path under Nix — so no variable was invented and no drift
## guard changed.
##
## The shim arm lives in `repro_build_engine` rather than beside the
## develop-mode resolver in `repro_cli_support`, and that placement is
## itself a finding: `resolveMonitorShimLibPath` LOOKS like the resolver
## -- it has the arms and the doc comment -- but its answer only ever
## reaches the dev-env engine. The ordinary build path seeds
## `REPRO_MONITOR_SHIM_LIB` from the engine's `launchChildEnv`, out of
## io-mon's `findShimLibrary`, whose four arms are an env override,
## `<appDir>/../lib`, `<appDir>/` and `<cwd>/build/lib`. The second is
## the FLAKE's layout exactly (`$out/bin` beside `$out/lib`), which is
## why this never came up under Nix, and no native package can use it: at
## prefix `/usr` it names `/usr/lib/librepro_monitor_shim.so`, which is
## the one place a private library must not go.
##
## Both arms are exercised through an INJECTED existence probe and an
## explicit extension. That is not test scaffolding for its own sake:
## the layout these arms exist for is an installed prefix, which by
## construction is not the layout of the machine running the test, and a
## resolver whose only exercise was "install a package and see" would be
## verified by the packaging gate alone — which is exactly the state
## that let the gap ship.

import std/[os, strutils, unittest]

import repro_build_engine
import repro_interface_artifacts

const
  InstalledLibDir = "/usr/lib/repro/lib"
  OtherLibDir = "/opt/other/lib"

proc canonical(path: string): string =
  ## One path spelling, so a case can state a POSIX install tree and run
  ## on a host whose separator is the other one. See `probeFor`.
  result = newStringOfCap(path.len)
  for ch in path:
    result.add(if ch == '\\': '/' else: ch)

proc probeFor(present: openArray[string]): proc(path: string): bool =
  ## An existence probe over a fixed set of paths, so a case can
  ## describe a filesystem it is not running on.
  ##
  ## SEPARATORS ARE NORMALISED BEFORE COMPARISON, and that is the whole
  ## of what makes these cases runnable on Windows. The tree every case
  ## here describes is an INSTALLED POSIX PREFIX -- `/usr/lib/repro/lib`
  ## -- because that is the layout the two resolvers exist for. The
  ## resolvers join with the HOST's separator, so on Windows they ask the
  ## probe about `/usr/lib/repro/lib\librepro_monitor_shim.so` and an
  ## exact-string probe answers false for every arm at once: three cases
  ## failed for one reason that had nothing to do with either resolver.
  ##
  ## Normalising here rather than teaching the resolvers to emit `/`
  ## keeps the change inside the test: which separator a resolver joins
  ## with is the host's business and is correct as it stands.
  var known: seq[string] = @[]
  for item in present:
    known.add(canonical(item))
  result = proc(path: string): bool =
    let probe = canonical(path)
    for item in known:
      if item == probe:
        return true
    false

suite "installed-layout resolvers":

  test "the shim is found in the package's private libdir":
    let path = monitorShimLibInLibraryPath(
      InstalledLibDir, "so",
      probeFor([InstalledLibDir & "/librepro_monitor_shim.so"]))
    check canonical(path) == InstalledLibDir & "/librepro_monitor_shim.so"

  test "the library path is a LIST and every entry is probed in order":
    # The flake sets six directories in this variable; a native package
    # sets one. An arm that only looked at the first entry would work on
    # the package and silently do nothing under Nix.
    let listed = OtherLibDir & PathSep & InstalledLibDir
    let path = monitorShimLibInLibraryPath(
      listed, "so",
      probeFor([InstalledLibDir & "/librepro_monitor_shim.so"]))
    check canonical(path) == InstalledLibDir & "/librepro_monitor_shim.so"
    # ...and the FIRST match wins, not the last.
    let both = monitorShimLibInLibraryPath(
      listed, "so",
      probeFor([OtherLibDir & "/librepro_monitor_shim.so",
                InstalledLibDir & "/librepro_monitor_shim.so"]))
    check canonical(both) == OtherLibDir & "/librepro_monitor_shim.so"

  test "an empty or all-missing library path resolves to nothing":
    # The caller treats "" as "monitor not configured" and falls back to
    # bypass semantics, so answering a path that does not exist would be
    # strictly worse than answering nothing.
    check monitorShimLibInLibraryPath("", "so", probeFor([])) == ""
    check monitorShimLibInLibraryPath(InstalledLibDir, "so",
      probeFor([])) == ""
    check monitorShimLibInLibraryPath(PathSep & PathSep, "so",
      probeFor([])) == ""

  test "the shim's extension is the target's, not the host's":
    # Parameterised for the same reason
    # ``runtime_contract.runtimeRpathCompilerFlags`` takes a target: a
    # Linux host has to be able to check what a Windows or Darwin
    # package will look for.
    #
    # The Windows case uses a DRIVE-LESS path on purpose, and the reason
    # is the limit of this whole style of test rather than a detail:
    # ``PathSep`` is the HOST's, so on a POSIX host ``C:/repro/lib``
    # splits into ``C`` and ``/repro/lib`` and the case fails against a
    # resolver that is behaving correctly. (Measured -- it was written
    # the other way first.) Splitting is the one thing about this arm
    # that genuinely cannot be checked for a foreign target from here;
    # the EXTENSION, which is what the case is about, can.
    check canonical(monitorShimLibInLibraryPath("/repro/lib", "dll",
      probeFor(["/repro/lib/librepro_monitor_shim.dll"]))) ==
      "/repro/lib/librepro_monitor_shim.dll"
    check canonical(monitorShimLibInLibraryPath("/usr/lib/repro/lib", "dylib",
      probeFor(["/usr/lib/repro/lib/librepro_monitor_shim.dylib"]))) ==
      "/usr/lib/repro/lib/librepro_monitor_shim.dylib"
    # The stem is one constant, shared with the packaging recipe that
    # ships the file, so the two cannot drift.
    check MonitorShimLibStem == "librepro_monitor_shim"

  test "the DSL runtime library resolves to its DIRECTORY, not its path":
    # ``providerDynamicLibDir``'s consumer emits ``-L<dir>`` and
    # ``-lrepro_project_dsl_runtime``, so this arm has to answer with the
    # directory. Returning the file would produce a ``-L`` pointing at a
    # regular file and a link that fails on a library that is present.
    let dir = dslRuntimeLibDirInLibraryPath(
      OtherLibDir & PathSep & InstalledLibDir, "so",
      probeFor([InstalledLibDir & "/librepro_project_dsl_runtime.so"]))
    check canonical(dir) == InstalledLibDir
    check ProjectDslRuntimeLibStem == "librepro_project_dsl_runtime"

  test "a library path with no DSL runtime in it answers nothing":
    # Which leaves ``providerDynamicLibDir`` on its develop-mode default
    # (``<workDir>/build/lib``) rather than on a directory that merely
    # exists — the failure mode where the link finds no library and the
    # error names a path the user never configured.
    check dslRuntimeLibDirInLibraryPath(InstalledLibDir, "so",
      probeFor([InstalledLibDir & "/librepro_monitor_shim.so"])) == ""
    check dslRuntimeLibDirInLibraryPath("", "so", probeFor([])) == ""

  test "the two arms probe DIFFERENT files in the same directory":
    # Both libraries come out of ``build/lib`` and land in the same
    # private libdir, so a resolver that probed for the wrong leaf would
    # still find a file and still be wrong.
    let dir = InstalledLibDir
    let onlyShim = probeFor([dir & "/librepro_monitor_shim.so"])
    let onlyRuntime = probeFor([dir & "/librepro_project_dsl_runtime.so"])
    check monitorShimLibInLibraryPath(dir, "so", onlyShim).len > 0
    check monitorShimLibInLibraryPath(dir, "so", onlyRuntime).len == 0
    check dslRuntimeLibDirInLibraryPath(dir, "so", onlyRuntime).len > 0
    check dslRuntimeLibDirInLibraryPath(dir, "so", onlyShim).len == 0

  test "the host extension constant is one of the three the arms accept":
    check HostDynamicLibraryExt in ["so", "dll", "dylib"]
    check not HostDynamicLibraryExt.startsWith(".")
