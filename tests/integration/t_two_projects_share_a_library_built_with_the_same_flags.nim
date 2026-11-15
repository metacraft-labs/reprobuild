## Two different projects, at different absolute paths, whose build files
## compile one library source with the same flags, build that library once
## between them.
##
## Each project carries its own copy of the `mathlib` source and builds it
## with `-O2`; their applications differ (each prints its own greeting) and
## their package names differ. They share one action cache and one store
## root, with the portable (path-independent) cache identity on. The C
## convention compiles with fixed flags, so the projects declare their edges
## in their build files (`writeLibraryProject`), the way a project that
## chooses its flags does.
##
## What it requires of the second project's build: its library compile and
## archive do not execute, its `libmathlib.a` is put in place from the cache
## and is byte-identical to the first project's, and its application edges,
## which differ, do execute. When it fails, the message names the engine's
## own reason for each library edge.
##
## EXPECTED RED until the library edge can be shared across projects. On the
## commit that added it the engine reports, per edge, a toolchain read
## outside every logical root, a key that differs between the two projects,
## or a record found whose outputs were never stored for another checkout to
## restore.
##
## Where the toolchain comes from. The builds take the C compiler and
## archiver from `PATH` (`--tool-provisioning=path`), the only mode in which
## the engine builds a C convention project today. In the dev shell that
## toolchain lives under `/nix/store`, and a read there stays outside every
## logical root, so it can never make an edge portable. These builds can
## share only once the toolchain is provisioned into the reprobuild store
## root by the engine itself; when that exists they must request it instead
## of `path`. That is the one change this test is meant to take: its
## assertions stay as they are.
##
## Vacuity guard: the second project's application compile and link are
## asserted to have executed, and the first project's library edges too, so
## the comparison is between two builds that both did work.
##
## Negative control: a third project that compiles the library with `-O1`
## instead of `-O2` executes its library edges, so a passing run cannot come
## from a key that ignores the flags.
##
## No mocks: the built `repro`, the C compiler and `ar` on `PATH`, real Git
## checkouts, the real monitor and action cache.

import std/[os, unittest]

import library_cache_sharing_fixture

suite "two projects share a library built with the same flags":
  test "the second project's library edges hit and its application edges execute":
    var host = newSharedHost("repro-two-projects-")
    defer: cleanup(host)
    let projectA = host.scratch / "team-a" / "calculator"
    let projectB = host.scratch / "elsewhere" / "team-b" / "reporter"
    writeLibraryProject(projectA, "calculatorPkg", ["-O2"],
      mapPrefix = false, greeting = "calculator")
    writeLibraryProject(projectB, "reporterPkg", ["-O2"],
      mapPrefix = false, greeting = "reporter")

    let a = host.build(projectA, portable = true)
    checkpoint("first project (" & projectA & "), exit " & $a.code & ":\n" &
      a.output)
    require a.code == 0
    check a.launched(LibraryCompileEdge)
    check a.launched(LibraryArchiveEdge)
    check nonEmptyFile(projectA / LibraryArchive)

    let b = host.build(projectB, portable = true)
    checkpoint("second project (" & projectB & "), exit " & $b.code & ":\n" &
      b.output)
    require b.code == 0
    checkpoint("engine reasons in the second project:\n" &
      engineReasons(b, LibraryCompileEdge) & "\n" &
      engineReasons(b, LibraryArchiveEdge))
    # Vacuity guard: the edges that differ did run.
    check b.launched(AppCompileEdge)
    check b.launched(AppLinkEdge)
    # The engine's own evidence that the cache served each library edge: the
    # edge is in the report, it did not launch, and its decision is a hit.
    for edge in [LibraryCompileEdge, LibraryArchiveEdge]:
      require b.hasEdge(edge)
      check not b.launched(edge)
      check b.cacheDecision(edge) == "cdHit"
    check nonEmptyFile(projectB / LibraryArchive)
    check sameBytes(projectA / LibraryObject, projectB / LibraryObject)
    check sameBytes(projectA / LibraryArchive, projectB / LibraryArchive)

  test "a project that changes one compile flag executes its library edges":
    var host = newSharedHost("repro-two-projects-control-")
    defer: cleanup(host)
    let projectA = host.scratch / "team-a" / "calculator"
    let projectC = host.scratch / "team-c" / "auditor"
    writeLibraryProject(projectA, "calculatorPkg", ["-O2"],
      mapPrefix = false, greeting = "calculator")
    writeLibraryProject(projectC, "auditorPkg", ["-O1"],
      mapPrefix = false, greeting = "auditor")

    let a = host.build(projectA, portable = true)
    checkpoint("first project, exit " & $a.code & ":\n" & a.output)
    require a.code == 0
    check a.launched(LibraryCompileEdge)
    check a.launched(LibraryArchiveEdge)

    let c = host.build(projectC, portable = true)
    checkpoint("project with -O1, exit " & $c.code & ":\n" & c.output &
      "\nengine reasons:\n" & engineReasons(c, LibraryCompileEdge) & "\n" &
      engineReasons(c, LibraryArchiveEdge))
    require c.code == 0
    check c.launched(LibraryCompileEdge)
    check c.launched(LibraryArchiveEdge)
