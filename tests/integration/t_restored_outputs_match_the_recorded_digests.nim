## A library output restored from the bytes another checkout's build stored
## on this host is checked against the digest its record states, and stored
## bytes that were altered are rejected and rebuilt, never served.
##
## The project is `reprobuild-examples/c-cpp-mode3/binary-with-library`,
## copied into two Git checkouts at different absolute paths that share one
## action-cache root and one store root, built with the toolchain the engine
## realizes into the store root (`--tool-provisioning=tarball`) and the
## portable (path-independent) cache identity on. The first build stores the
## output bytes of each shareable record under
## `<action-cache root>/portable-outputs`, one file per content digest. The
## test finds the stored copy of `libmathlib.a` by its bytes, alters one
## byte of it in place, and builds the second checkout.
##
## What it requires of the second build: the archive edge's restore is
## refused with the engine's reason naming the library and "digest
## mismatch", the archive edge executes, the second checkout's
## `libmathlib.a` is byte-identical to the first's (not the altered bytes),
## and the altered copy is gone from the store.
##
## Vacuity guard: the first build executed the archive edge and stored
## exactly one copy of `libmathlib.a`, and the alteration changed it. A
## second case builds the same pair without altering anything and requires
## the archive edge to be served from the store (not launched, `cdHit`,
## byte-identical output), so the first case's "it executed" cannot come
## from a restore that never works.
##
## Falsifying mutation (run by hand, recorded in the plan): skipping the
## digest check of the restore serves the altered bytes, and the main case
## fails on the archive edge not executing and on the bytes.
##
## No mocks: the built `repro`, the C compiler and `ar` the engine realizes
## into the store root, real Git checkouts, the real monitor, action cache
## and output store.

import std/[os, strutils, tables, unittest]

import repro_test_support
import library_cache_sharing_fixture

const
  ArchiveEdge = "ccpp-direct-archive-mathlib"
  ArchivePath = ".repro/build/mathlib/libmathlib.a"
  StoredOutputsDir = "portable-outputs"

proc exampleSource(): string =
  result = workspaceRootForRepo(ReprobuildRoot) / "reprobuild-examples" /
    "c-cpp-mode3" / "binary-with-library"
  if not fileExists(result / "repro.nim"):
    raise newException(IOError, "the c-cpp-mode3/binary-with-library " &
      "example is not at " & result & "; this test builds it from the " &
      "reprobuild-examples checkout beside this repository")

proc storedCopiesOf(host: SharedHost; content: string): seq[string] =
  ## Every file under the output store whose bytes are `content`.
  let store = host.actionCacheRoot / StoredOutputsDir
  if not dirExists(store):
    return @[]
  for path in walkDirRec(store):
    if readFile(path) == content:
      result.add(path)

proc traceDetails(run: BuildRun; id, event: string): seq[string] =
  if id in run.edges:
    for item in run.edges[id].trace:
      if item.event == event:
        result.add(item.detail)

suite "restored outputs match the recorded digests":
  test "an altered stored library is rejected and rebuilt, not served":
    var host = newSharedHost("repro-restored-digests-")
    defer: cleanup(host)
    let first = host.scratch / "first" / "binary-with-library"
    let second = host.scratch / "second" / "elsewhere" / "binary-with-library"
    copyCheckout(exampleSource(), first)
    copyCheckout(exampleSource(), second)

    let one = host.build(first, portable = true, provisioning = "tarball")
    checkpoint("first build (" & first & "), exit " & $one.code & ":\n" &
      one.output & "\nengine reasons:\n" & engineReasons(one, ArchiveEdge))
    require one.code == 0
    # Vacuity guard: the archive ran, and exactly one stored copy of its
    # output exists to alter.
    require one.launched(ArchiveEdge)
    require nonEmptyFile(first / ArchivePath)
    let recorded = readFile(first / ArchivePath)
    let copies = host.storedCopiesOf(recorded)
    checkpoint("stored copies of libmathlib.a: " & $copies)
    require copies.len == 1
    var altered = recorded
    altered[altered.len div 2] = char(ord(altered[altered.len div 2]) xor 0xFF)
    require altered != recorded and altered.len == recorded.len
    writeFile(copies[0], altered)

    let two = host.build(second, portable = true, provisioning = "tarball")
    checkpoint("second build (" & second & "), exit " & $two.code & ":\n" &
      two.output & "\nengine reasons:\n" & engineReasons(two, ArchiveEdge))
    require two.code == 0
    require two.hasEdge(ArchiveEdge)
    # The engine's own account: the restore was refused for the digest.
    let refusals = two.traceDetails(ArchiveEdge, "portable-restore-failed")
    check refusals.len == 1
    check refusals.len == 1 and "libmathlib.a: digest mismatch" in refusals[0]
    # Rebuilt, not served: the edge executed and its output is the
    # recorded bytes.
    check two.launched(ArchiveEdge)
    check two.cacheDecision(ArchiveEdge) != "cdHit"
    check sameBytes(first / ArchivePath, second / ArchivePath)
    check readFile(second / ArchivePath) != altered
    # The altered copy is gone; the rebuild stored the right bytes again.
    check host.storedCopiesOf(altered).len == 0
    check host.storedCopiesOf(recorded).len == 1

  test "the same pair without the alteration is served from the store":
    var host = newSharedHost("repro-restored-digests-control-")
    defer: cleanup(host)
    let first = host.scratch / "first" / "binary-with-library"
    let second = host.scratch / "second" / "elsewhere" / "binary-with-library"
    copyCheckout(exampleSource(), first)
    copyCheckout(exampleSource(), second)

    let one = host.build(first, portable = true, provisioning = "tarball")
    checkpoint("first build, exit " & $one.code & ":\n" & one.output)
    require one.code == 0
    require one.launched(ArchiveEdge)

    let two = host.build(second, portable = true, provisioning = "tarball")
    checkpoint("second build, exit " & $two.code & ":\n" & two.output &
      "\nengine reasons:\n" & engineReasons(two, ArchiveEdge))
    require two.code == 0
    require two.hasEdge(ArchiveEdge)
    check not two.launched(ArchiveEdge)
    check two.cacheDecision(ArchiveEdge) == "cdHit"
    check two.traceDetails(ArchiveEdge, "portable-restore-failed").len == 0
    check sameBytes(first / ArchivePath, second / ArchivePath)
