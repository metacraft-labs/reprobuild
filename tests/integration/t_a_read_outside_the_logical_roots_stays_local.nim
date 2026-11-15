## A compile that reads a file outside every logical root keeps its local,
## path-dependent key and says which file kept it local; the same compile
## with that file inside the project is shareable between checkouts.
##
## The portable (path-independent) identity names every path an edge read as
## a logical root (the project, its repository, its build output directory,
## the reprobuild store) plus a relative path. A read under no root cannot be
## named on another checkout or host, so the edge must not get a portable
## record at all: it builds and caches locally, and the trace says
## `portable-fingerprint-unavailable … outside every logical root: <path>`.
## Anything else would let a second checkout reuse a result whose input it
## never compared.
##
## The project is `reprobuild-examples/c-cpp-mode3/binary-with-library`, built
## by the C convention with the C toolchain the engine provisions into the
## store root (`--tool-provisioning=tarball`). That matters for what the test
## can tell apart: with a toolchain from `PATH` on a Nix host every edge reads
## `/nix/store` and is non-portable for that reason alone, so an edge's
## non-portability would say nothing about the file under test. With the
## store-root toolchain every toolchain read is inside the `store` root, which
## the negative control below shows: the same compile with the header inside
## the project gets a portable record.
##
## Main case: `mathlib/src/add.c` includes a header by an absolute path in a
## directory beside the checkouts, under no logical root. In both of two
## checkouts at different paths, sharing one action cache and store, the
## compile edge
##   * executes (vacuity guard: it did run, in the first checkout),
##   * gets no portable record (`portable-fingerprint` is absent), and the
##     `portable-fingerprint-unavailable` reason names that header and says it
##     is outside every logical root,
##   * and in the second checkout is not resolved from the first's record
##     (no `portable-resolved`), so it executes again under its own key.
## No publication can happen without a record; the builds also disable every
## remote cache (`REPRO_CACHE_DISABLE=1`, no `REPRO_BINARY_CACHE_*`), so
## nothing leaves the host either way.
##
## Negative control: the same project with the header moved into
## `mathlib/src` (included by a relative name) is shareable. The first
## checkout's compile gets a portable record and no `-unavailable` event, and
## the second checkout finds that record by its portable key
## (`portable-resolved`). Whether the second checkout then restores the
## record's outputs or executes is the restore's business, not this test's.
##
## Network: the first build on a store that does not yet hold the toolchain
## fetches its archive (102 MB, pinned by SHA-256) and `patchelf` once into the store, as the
## catalog conformance sweep does. Set `REPRO_CONFORMANCE_STORE` to a
## directory that survives between runs to pay that once per pin.
##
## Both builds also assert the archive edge: the relocated `ar` runs under
## the monitor (its reads are recorded, among them the realized toolchain's
## files in the store) and gets one portable record, so the compile edge is
## the only one the outside header keeps local.
##
## No mocks: the built `repro`, the engine-provisioned GCC and `ar`, real Git
## checkouts at different absolute paths, the real monitor and action cache,
## and the build report the engine writes.

import std/[os, sequtils, strutils, tables, unittest]

import repro_test_support
import library_cache_sharing_fixture

const
  CompileEdge = "ccpp-direct-compile-mathlib-add.c"
  ArchiveEdge = "ccpp-direct-archive-mathlib"
  OutsideRootReason = "outside every logical root"

proc exampleSource(): string =
  result = workspaceRootForRepo(ReprobuildRoot) / "reprobuild-examples" /
    "c-cpp-mode3" / "binary-with-library"
  if not fileExists(result / "repro.nim"):
    raise newException(IOError, "the c-cpp-mode3/binary-with-library " &
      "example is not at " & result & "; this test builds it from the " &
      "reprobuild-examples checkout beside this repository")

proc events(run: BuildRun; id, event: string): seq[string] =
  ## The details of every `event` the trace recorded for edge `id`.
  if id in run.edges:
    for entry in run.edges[id].trace:
      if entry.event == event:
        result.add(entry.detail)

proc checkArchiveEdgeIsMonitoredAndPortable(run: BuildRun; host: SharedHost) =
  ## The archive edge ran the engine-provisioned `ar` UNDER THE MONITOR, and
  ## every read the monitor saw is inside the logical roots: it gets exactly
  ## one portable record and no `-unavailable` reason. The monitor evidence
  ## is the proof that the preload shim entered the relocated `ar` (a
  ## statically linked archiver, or one whose loader cannot load the shim,
  ## records no reads and is reported as a monitor loss instead): among its
  ## reads are the object it archived and the realized toolchain's own files
  ## under the store's tool store (its loader and C library).
  require run.hasEdge(ArchiveEdge)
  check run.launched(ArchiveEdge)
  let edge = run.edges[ArchiveEdge]
  checkpoint("archive edge: policy " & edge.dependencyPolicyKind &
    ", monitor reads:\n  " & edge.monitorReads.join("\n  "))
  check edge.dependencyPolicyKind == "dgAutomaticMonitor"
  check edge.monitorReads.anyIt(it.endsWith("add.o"))
  let toolStore = host.storeRoot / "tool-store"
  check edge.monitorReads.anyIt(it.startsWith(toolStore & "/"))
  check run.events(ArchiveEdge, "portable-fingerprint").len == 1
  check run.events(ArchiveEdge, "portable-fingerprint-unavailable").len == 0

proc includeHeader(checkout, includeLine: string) =
  ## Make `add.c` include a header through `includeLine` and use a macro it
  ## defines, so the compile really reads the header (an include the
  ## preprocessor could skip would prove nothing), then commit.
  let source = checkout / "mathlib" / "src" / "add.c"
  let original = readFile(source)
  let edited = includeLine & "\n" & original.replace("return a + b;",
    "return a + b + MATHLIB_EXTRA;")
  doAssert edited.contains("MATHLIB_EXTRA;"),
    "add.c no longer contains `return a + b;`; adjust this fixture"
  writeFile(source, edited)
  commitCheckout(checkout)

proc writeExtraHeader(path: string) =
  createDir(path.parentDir)
  writeFile(path, "#ifndef MATHLIB_EXTRA\n#define MATHLIB_EXTRA 0\n#endif\n")

suite "a read outside the logical roots stays local":
  test "a compile that includes a header from outside every root keeps its local key and names the header":
    var host = newSharedHost("repro-outside-roots-")
    defer: cleanup(host)
    # Beside the checkouts and the action cache, under no root: not the store
    # (`<scratch>/store`, or a persistent store elsewhere), not either
    # checkout, not a repository.
    let outsideHeader = host.scratch / "outside-include" / "mathlib_extra.h"
    writeExtraHeader(outsideHeader)
    let first = host.scratch / "first" / "binary-with-library"
    let second = host.scratch / "second" / "nested" / "binary-with-library"
    for checkout in [first, second]:
      copyCheckout(exampleSource(), checkout)
      includeHeader(checkout, "#include \"" & outsideHeader & "\"")

    let one = host.build(first, portable = true, provisioning = "tarball")
    checkpoint("first build (" & first & "), exit " & $one.code & ":\n" &
      one.output & "\nengine reasons:\n" & allEngineReasons(one))
    require one.code == 0
    require one.hasEdge(CompileEdge)
    # Vacuity guard: the compile ran, so its record (or the absence of one)
    # is about this execution.
    check one.launched(CompileEdge)
    # That the toolchain's own reads are inside the roots, so the
    # non-portability below is the header's and not the toolchain's, is what
    # the negative control shows: the same compile, with the header moved
    # into the project, gets a portable record.
    # The compile has no portable record, and the reason names the header.
    check one.events(CompileEdge, "portable-fingerprint").len == 0
    let reasons = one.events(CompileEdge, "portable-fingerprint-unavailable")
    check reasons.len == 1
    for reason in reasons:
      check OutsideRootReason in reason
      check outsideHeader in reason
    check one.events(CompileEdge, "portable-memo-published").len == 0
    # Only the compile is kept local: the archive edge reads the object, not
    # the header, and is shareable.
    checkArchiveEdgeIsMonitoredAndPortable(one, host)

    let two = host.build(second, portable = true, provisioning = "tarball")
    checkpoint("second build (" & second & "), exit " & $two.code & ":\n" &
      two.output & "\nengine reasons:\n" & allEngineReasons(two))
    require two.code == 0
    require two.hasEdge(CompileEdge)
    # Not resolved from the first checkout's (absent) portable record: it
    # executes under its own, path-dependent key, and again says why.
    check two.events(CompileEdge, "portable-resolved").len == 0
    check two.launched(CompileEdge)
    check two.cacheDecision(CompileEdge) != "cdHit"
    check two.events(CompileEdge, "portable-fingerprint").len == 0
    let secondReasons = two.events(CompileEdge,
      "portable-fingerprint-unavailable")
    check secondReasons.len == 1
    for reason in secondReasons:
      check OutsideRootReason in reason
      check outsideHeader in reason

  test "the same compile with the header inside the project is shareable":
    var host = newSharedHost("repro-outside-roots-control-")
    defer: cleanup(host)
    let first = host.scratch / "first" / "binary-with-library"
    let second = host.scratch / "second" / "nested" / "binary-with-library"
    for checkout in [first, second]:
      copyCheckout(exampleSource(), checkout)
      writeExtraHeader(checkout / "mathlib" / "src" / "mathlib_extra.h")
      includeHeader(checkout, "#include \"mathlib_extra.h\"")

    let one = host.build(first, portable = true, provisioning = "tarball")
    checkpoint("first build (" & first & "), exit " & $one.code & ":\n" &
      one.output & "\nengine reasons:\n" & allEngineReasons(one))
    require one.code == 0
    require one.hasEdge(CompileEdge)
    check one.launched(CompileEdge)
    check one.events(CompileEdge, "portable-fingerprint").len == 1
    check one.events(CompileEdge, "portable-fingerprint-unavailable").len == 0
    checkArchiveEdgeIsMonitoredAndPortable(one, host)

    let two = host.build(second, portable = true, provisioning = "tarball")
    checkpoint("second build (" & second & "), exit " & $two.code & ":\n" &
      two.output & "\nengine reasons:\n" & allEngineReasons(two))
    require two.code == 0
    require two.hasEdge(CompileEdge)
    check two.events(CompileEdge, "portable-resolved").len >= 1
