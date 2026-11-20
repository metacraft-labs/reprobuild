## What a project declares it can share across checkouts is what the engine
## does when a second checkout is built.
##
## The declaration is `repro cache sharing <project> --json`
## (`reprobuild.cache-sharing.v1`): for each action of the project's default
## selection, whether its record can be served to another checkout on this
## host, and for the project `per-library`, `per-build` or `none`. It is
## computed from the planned graph, before anything is built. This test
## builds each fixture in two checkouts of one tree at different paths, with
## one shared action cache and store, and compares the declaration with what
## the second checkout's build did:
##
## * the typed `cargo` tool (`tests/fixtures/cargo-two-binaries-features`:
##   the whole-invocation edge and the per-package library and binary edges,
##   path provisioning);
## * a CMake project through the Reprobuild generator
##   (`tests/fixtures/cmake-feature-libraries`: two static libraries from one
##   source with different defines and two executables, configured by the
##   workspace's `reprobuild-cmake` build with the compiler on `PATH`);
## * NEGATIVE CONTROL, a fixture that IS shareable: the build-file library
##   project of the library-sharing gates (`writeLibraryProject`, typed `gcc`
##   and `ar` edges under `--tool-provisioning=tarball`), whose compile and
##   archive edges a second checkout is served.
##
## For each: the measured verdict (`none` when the second checkout executed
## every action, otherwise `per-library`, or `per-build` for a selection of
## one cacheable action) equals the declared one; every action the second
## checkout was served is declared shareable; every action declared not
## shareable was executed by the second checkout. So a fixture that is not
## shareable is declared so, and a shareable one is declared shareable.
##
## VACUITY GUARD: each fixture's second checkout is at another path than
## the first (another parent, another depth), both builds exit 0, and the
## first checkout's repeat build is served from its own records, so "the
## second checkout executed it" is about checkouts, not about an edge that
## never caches.
##
## No mocks: the built `repro`, the dev shell's cargo / rustc / gcc, the
## workspace's forked CMake, the C toolchain the engine realizes into the
## store root, real Git checkouts and the engine's build reports.
##
## Skip rule: POSIX only. A fixture whose tools are missing (cargo, rustc
## and gcc on PATH; `../reprobuild-cmake/build/bin/cmake`) is skipped loudly;
## a skip is not a pass.

import std/[json, os, osproc, sets, strutils, tables, unittest]

import repro_test_support/reasoned_skip
import library_cache_sharing_fixture

const
  CargoFixture = ReprobuildRoot / "tests" / "fixtures" /
    "cargo-two-binaries-features"
  CMakeFixture = ReprobuildRoot / "tests" / "fixtures" /
    "cmake-feature-libraries"

proc forkedCMake(): string =
  ## The workspace's `reprobuild-cmake` build, beside this repository.
  let candidate = ReprobuildRoot.parentDir / "reprobuild-cmake" / "build" /
    "bin" / "cmake"
  if fileExists(candidate): candidate else: ""

proc declaredShareable(declaration: JsonNode): HashSet[string] =
  for action in declaration["actions"]:
    if action["shareable"].getBool():
      result.incl(action["id"].getStr())

proc declaredIds(declaration: JsonNode): seq[string] =
  for action in declaration["actions"]:
    result.add(action["id"].getStr())

proc measuredSharing(second: BuildRun; declaration: JsonNode): string =
  ## The verdict the second checkout's build shows: `none` when it was
  ## served no action (every action of the build executed), else
  ## `per-build` for a selection of one cacheable action and `per-library`
  ## otherwise.
  var served = 0
  for id, edge in second.edges:
    if not edge.launched and edge.cacheDecision == "cdHit":
      inc served
  if served == 0: "none"
  elif declaration["cacheableActions"].getInt() == 1: "per-build"
  else: "per-library"

proc checkDeclaredAsMeasured(declaration: JsonNode; first, again,
                             second: BuildRun) =
  ## The comparison every fixture makes; see the module comment.
  ##
  ## Actions are matched by id. A CMake build directory's build report names
  ## a link `link-<target>` where the graph inspection the declaration comes
  ## from names it `<target>` (a known mismatch between the two routes: the
  ## inspection applies the build file's target aliases to the action ids),
  ## so every action the build ran must also be accounted for by count: the
  ## build ran as many actions as the declaration lists.
  checkpoint("declaration:\n" & pretty(declaration))
  checkpoint("second checkout:\n" & second.allEngineReasons())
  require first.code == 0
  require again.code == 0
  require second.code == 0
  let shareable = declaredShareable(declaration)
  let ids = declaredIds(declaration)
  require ids.len > 0
  check second.edges.len == ids.len
  var cachedHere = 0
  for id, edge in again.edges:
    if edge.cacheDecision == "cdHit":
      inc cachedHere
  for id, edge in second.edges:
    if not edge.launched:
      # Served to the second checkout: declared shareable, under this id.
      check id in shareable
  for id in ids:
    if id notin shareable and second.hasEdge(id):
      # Declared not shareable: the second checkout executed it.
      check second.launched(id)
  if declaration["sharing"].getStr() == "none":
    # Nothing is declared shareable, so the second checkout executed every
    # action, whatever the report calls it.
    for id, edge in second.edges:
      check edge.launched
  # Vacuity guard: the first checkout's own repeat build was served.
  check cachedHere > 0
  check declaration["sharing"].getStr() == measuredSharing(second, declaration)

proc runChecked(args: openArray[string]; workingDir: string) =
  let res = execCmdEx(quoteShellCommand(args), workingDir = workingDir)
  if res.exitCode != 0:
    raise newException(OSError, args.join(" ") & " exited " &
      $res.exitCode & ":\n" & res.output)

suite "cross-checkout sharing is declared as measured":
  test "the typed cargo tool is declared not shareable, as measured":
    when not defined(posix):
      skip("POSIX only: the fixtures are built with POSIX tools")
    else:
      if findExe("cargo").len == 0 or findExe("rustc").len == 0 or
          findExe("gcc").len == 0:
        skip("cargo, rustc and gcc must be on PATH")
      else:
        var host = newSharedHost("cargo-sharing-declared-")
        defer: host.cleanup()
        let one = host.scratch / "one" / "ws"
        let two = host.scratch / "two" / "deeper" / "ws"
        copyCheckout(CargoFixture, one)
        copyCheckout(CargoFixture, two)
        let declaration = host.cacheSharing(one, provisioning = "path")
        check declaration["schema"].getStr() == "reprobuild.cache-sharing.v1"
        check declaration["sharing"].getStr() == "none"
        let first = host.build(one, portable = false, provisioning = "path")
        let again = host.build(one, portable = false, provisioning = "path")
        let second = host.build(two, portable = false, provisioning = "path")
        checkDeclaredAsMeasured(declaration, first, again, second)
        # The second checkout's declaration is the first's.
        check host.cacheSharing(two, provisioning = "path")["sharing"] ==
          declaration["sharing"]

  test "a CMake project through the Reprobuild generator is declared not shareable, as measured":
    when not defined(posix):
      skip("POSIX only: the fixtures are built with POSIX tools")
    else:
      let cmake = forkedCMake()
      if cmake.len == 0 or findExe("gcc").len == 0:
        skip("needs ../reprobuild-cmake/build/bin/cmake and gcc on PATH")
      else:
        var host = newSharedHost("cmake-sharing-declared-")
        defer: host.cleanup()
        let one = host.scratch / "one" / "proj"
        let two = host.scratch / "two" / "deeper" / "proj"
        for checkout in [one, two]:
          copyCheckout(CMakeFixture, checkout)
          runChecked([cmake, "-S", checkout, "-B", checkout / "build",
            "-G", "Reprobuild", "-DCMAKE_MAKE_PROGRAM=" & reproBinary(),
            "-DCMAKE_BUILD_TYPE=Release"], checkout)
        let declaration = host.cacheSharing(one / "build#all",
          provisioning = "path")
        check declaration["sharing"].getStr() == "none"
        let first = host.build(one, portable = false, provisioning = "path",
          target = "build#all")
        let again = host.build(one, portable = false, provisioning = "path",
          target = "build#all")
        let second = host.build(two, portable = false, provisioning = "path",
          target = "build#all")
        checkDeclaredAsMeasured(declaration, first, again, second)

  test "negative control: a shareable library project is declared shareable, as measured":
    when not defined(posix):
      skip("POSIX only: the fixtures are built with POSIX tools")
    else:
      var host = newSharedHost("library-sharing-declared-")
      defer: host.cleanup()
      let one = host.scratch / "one" / "lib"
      let two = host.scratch / "two" / "deeper" / "lib"
      writeLibraryProject(one, "sharing_control", ["-O2"],
        mapPrefix = false, greeting = "hello")
      copyCheckout(one, two)
      let declaration = host.cacheSharing(one, provisioning = "tarball")
      check declaration["sharing"].getStr() == "per-library"
      let shareable = declaredShareable(declaration)
      check LibraryCompileEdge in shareable
      check LibraryArchiveEdge in shareable
      let first = host.build(one, portable = false, provisioning = "tarball")
      let again = host.build(one, portable = false, provisioning = "tarball")
      let second = host.build(two, portable = false, provisioning = "tarball")
      checkDeclaredAsMeasured(declaration, first, again, second)
      # What the gates of the library-sharing design require of it.
      check not second.launched(LibraryCompileEdge)
      check not second.launched(LibraryArchiveEdge)
