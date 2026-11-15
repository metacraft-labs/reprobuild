## Two checkouts of one project at different absolute paths, sharing one
## action cache, build the project's static library once between them.
##
## The project is `reprobuild-examples/c-cpp-mode3/binary-with-library`: the
## C convention compiles `mathlib/src/add.c` and archives it into
## `libmathlib.a`, then compiles and links `calc` against it. The test copies
## it into two Git checkouts at different absolute paths, turns the portable
## (path-independent) cache identity on, and builds the first and then the
## second against one `--action-cache-root` and one store root.
##
## What it requires of the second build: the compile and archive edges of
## `mathlib` do not execute, `libmathlib.a` is put in place from the cache,
## and the library's object and archive are byte-identical to the first
## checkout's. When it fails, the message names the engine's own reason for
## each library edge: its cache decision and every `portable-*` event the
## build report's trace recorded for it.
##
## EXPECTED RED until the library edge can be shared across checkouts. On
## the commit that added it the engine reports, per edge, either that a read
## of the toolchain lies outside every logical root, or (when the toolchain's
## reads are inside them) that the record was found but its outputs were
## never stored where another checkout can restore them from.
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
## Vacuity guard: the first build must have executed the compile and archive
## edges and produced a non-empty object and archive; otherwise "the second
## build did not execute them" would be true of a build that never built.
##
## Negative control: a third checkout whose `add.c` differs by one line must
## execute the compile and archive again, so a passing run cannot come from
## a key that ignores the source.
##
## No mocks: the built `repro`, the C compiler and `ar` on `PATH`, real Git
## checkouts, the real monitor and action cache.

import std/[os, strutils, unittest]

import repro_test_support
import library_cache_sharing_fixture

const
  CompileEdge = "ccpp-direct-compile-mathlib-add.c"
  ArchiveEdge = "ccpp-direct-archive-mathlib"
  ObjectPath = ".repro/build/mathlib/obj/add.o"
  ArchivePath = ".repro/build/mathlib/libmathlib.a"

proc exampleSource(): string =
  result = workspaceRootForRepo(ReprobuildRoot) / "reprobuild-examples" /
    "c-cpp-mode3" / "binary-with-library"
  if not fileExists(result / "repro.nim"):
    raise newException(IOError, "the c-cpp-mode3/binary-with-library " &
      "example is not at " & result & "; this test builds it from the " &
      "reprobuild-examples checkout beside this repository")

suite "two checkouts share a static library edge":
  test "the second checkout executes no compile or archive for mathlib and restores libmathlib.a byte-identically":
    var host = newSharedHost("repro-two-checkouts-")
    defer: cleanup(host)
    let first = host.scratch / "first" / "binary-with-library"
    let second = host.scratch / "second" / "nested" / "deeper" /
      "binary-with-library"
    copyCheckout(exampleSource(), first)
    copyCheckout(exampleSource(), second)

    let one = host.build(first, portable = true)
    checkpoint("first build (" & first & "), exit " & $one.code & ":\n" &
      one.output)
    require one.code == 0
    # Vacuity guard.
    check one.launched(CompileEdge)
    check one.launched(ArchiveEdge)
    check nonEmptyFile(first / ObjectPath)
    check nonEmptyFile(first / ArchivePath)

    let two = host.build(second, portable = true)
    checkpoint("second build (" & second & "), exit " & $two.code & ":\n" &
      two.output)
    require two.code == 0
    checkpoint("engine reasons in the second checkout:\n" &
      engineReasons(two, CompileEdge) & "\n" & engineReasons(two, ArchiveEdge))
    # The engine's own evidence that the cache served each library edge: the
    # edge is in the report (so "not launched" cannot come from an edge the
    # report never listed), it did not launch, and its decision is a hit.
    for edge in [CompileEdge, ArchiveEdge]:
      require two.hasEdge(edge)
      check not two.launched(edge)
      check two.cacheDecision(edge) == "cdHit"
    check nonEmptyFile(second / ArchivePath)
    check sameBytes(first / ObjectPath, second / ObjectPath)
    check sameBytes(first / ArchivePath, second / ArchivePath)

  test "a third checkout with one source line changed executes the compile and archive again":
    var host = newSharedHost("repro-two-checkouts-control-")
    defer: cleanup(host)
    let first = host.scratch / "first" / "binary-with-library"
    let changed = host.scratch / "third" / "binary-with-library"
    copyCheckout(exampleSource(), first)
    copyCheckout(exampleSource(), changed)
    let source = changed / "mathlib" / "src" / "add.c"
    let original = readFile(source)
    let edited = original.replace("return a + b;",
      "return b + a; /* edited */")
    require edited != original
    writeFile(source, edited)
    commitCheckout(changed)

    let one = host.build(first, portable = true)
    checkpoint("first build, exit " & $one.code & ":\n" & one.output)
    require one.code == 0
    check one.launched(CompileEdge)
    check one.launched(ArchiveEdge)

    let three = host.build(changed, portable = true)
    checkpoint("changed checkout, exit " & $three.code & ":\n" &
      three.output & "\nengine reasons:\n" &
      engineReasons(three, CompileEdge) & "\n" &
      engineReasons(three, ArchiveEdge))
    require three.code == 0
    check three.launched(CompileEdge)
    check three.launched(ArchiveEdge)
