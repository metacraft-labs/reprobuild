## Two checkouts of one project at different absolute paths, on Apple
## Silicon, building a static library with tools the engine provisions into
## its store root: what is shared, and what the platform does not yet let
## be shared.
##
## This is the macOS counterpart of `t_two_checkouts_share_a_static_library_edge`
## (the Linux gate). That gate cannot run here: its builds request
## `--tool-provisioning=tarball` and the catalog has no macOS arm for `gcc`
## (`tool-resolution failed: package "gcc" has no tarball realization for
## this host (cpu=aarch64 os=macos ...)`). The only C compiler and archiver
## the catalog provisions into the store root on Apple Silicon is zig's
## (`zig cc`, `zig ar`, the 0.14.1 archive), so the library is built with
## those, from a build file that declares the edges (`writeMacosLibraryProject`).
##
## THE RECORDED LIMIT. On macOS no library edge can be served to a second
## checkout today, whatever the toolchain. What the engine says, per edge:
##
##   * the edge draws entropy (zig names its temporary files from
##     `arc4random`) and no tool declaration blesses it, so the first run is
##     not published (`unblessed-entropy`);
##   * once the determinism probe has admitted it (a second build with
##     byte-identical inputs and outputs), the edge is cached, but only under
##     its checkout-specific key: the portable identity is unavailable
##     because the monitored process tree reads paths outside every logical
##     root (`portable-fingerprint-unavailable ... outside every logical
##     root`): the system's locale files, a diagnostics filter under
##     `/Library/Preferences`, and the wrapper shell's files under
##     `/nix/store`. The macOS sealed-volume binding that would let the
##     system's reads be bound by the OS build is specified and not
##     implemented, and `/Library` and `/nix/store` are outside it.
##
## This test pins both: the second checkout executes both library edges and
## does not resolve the first checkout's records, and each edge's own
## reasons are the recorded ones. When the limit is lifted this test fails
## on exactly those assertions, and the documentation of the limit is to be
## updated with it; it does not pass by accident, and it is not loosened.
## What it does require everywhere is the part that is sound: the outputs
## of the two checkouts are byte-identical, so the limit is in the identity
## of the record and not in the bytes, and the same checkout hits its own
## records.
##
## Vacuity guards: the first build executed the compile and archive edges
## through the toolchain in the store root (the compiler image is read from
## `<store root>/tool-store`, and no `/usr/bin` image appears in the edge's
## evidence), under the automatic monitor, with no monitor loss, and left
## non-empty outputs; a build of the same checkout hits both edges (so
## "the second checkout does not hit" is about checkouts, not about edges
## that can never be cached).
##
## Negative control: the same four edges with `/usr/bin/gcc` and
## `/usr/bin/ar`. The compile edge then reports the monitor loss the
## store-provisioned compile does not (the platform strips the monitor from
## a SIP-protected root image), so the assertion on the store-provisioned
## edge ("no monitor loss") is shown to be able to fail; and the two
## checkouts' archives differ although their objects are identical (Apple's
## `ar` stores each member's modification time), which the store-provisioned
## archiver's do not.
##
## No mocks: the built `repro`, zig realized into a real store root from its
## real release archive, the system's own `gcc` and `ar`, real Git checkouts,
## the real monitor and action cache.

import std/[os, strutils, tables, unittest]

import repro_test_support
import repro_test_support/reasoned_skip
import library_cache_sharing_fixture

when defined(macosx) and defined(arm64):
  proc eventDetails(run: BuildRun; id, kind: string): seq[string] =
    if id in run.edges:
      for event in run.edges[id].trace:
        if event.event == kind:
          result.add(event.detail)

  proc publishSkip(run: BuildRun; id: string): string =
    if id in run.edges: run.edges[id].cachePublishSkipReason else: ""

  proc readsToolUnderStoreRoot(run: BuildRun; id: string): bool =
    ## The edge's monitored reads include the zig image the engine realized
    ## into the store root's tool store.
    if id notin run.edges:
      return false
    for path in run.edges[id].monitorReads:
      if "/tool-store/prefixes/zig/" in path and path.endsWith("/zig"):
        return true

  proc readsUsrBinImage(run: BuildRun; id: string): bool =
    if id notin run.edges:
      return false
    for path in run.edges[id].monitorReads:
      if path.startsWith("/usr/bin/"):
        return true

  suite "two checkouts share a static library edge (macOS)":
    test "store-provisioned zig: the edges are monitored and deterministic, cached in their own checkout, and not shared with another (recorded limit)":
      var host = newSharedHost("repro-two-checkouts-macos-")
      defer: cleanup(host)
      let first = host.scratch / "first" / "mathlibproj"
      let second = host.scratch / "second" / "nested" / "deeper" / "mathlibproj"
      writeMacosLibraryProject(first, "mathlibMacos", mtStoreZig)
      writeMacosLibraryProject(second, "mathlibMacos", mtStoreZig)

      # Build 1: the vacuity guards.
      let one = host.build(first, portable = true, provisioning = "tarball")
      checkpoint("first build (" & first & "), exit " & $one.code & ":\n" &
        one.output)
      require one.code == 0
      for edge in [LibraryCompileEdge, LibraryArchiveEdge]:
        require one.hasEdge(edge)
        check one.launched(edge)
        check one.edges[edge].dependencyPolicyKind == "dgAutomaticMonitor"
        # Executed through the store root's toolchain, not the system's.
        check one.edges[edge].monitorReads.len > 0
        check not one.readsUsrBinImage(edge)
        # The monitor entered every process of the edge.
        check "monitor-loss" notin one.publishSkip(edge)
        # Recorded limit 1: zig's temporary-file names are an unblessed
        # entropy draw, so the first run is not published.
        check "unblessed-entropy" in one.publishSkip(edge)
      check one.readsToolUnderStoreRoot(LibraryCompileEdge)
      check nonEmptyFile(first / LibraryObject)
      check nonEmptyFile(first / LibraryArchive)

      # Build 2: the determinism probe admits the edges; the portable
      # identity is then what is asked for, and it is unavailable.
      let two = host.build(first, portable = true, provisioning = "tarball")
      checkpoint("first checkout, second build, exit " & $two.code & ":\n" &
        two.output)
      require two.code == 0
      for edge in [LibraryCompileEdge, LibraryArchiveEdge]:
        let unavailable = two.eventDetails(edge,
          "portable-fingerprint-unavailable")
        checkpoint("engine reasons for " & edge & ":\n" &
          engineReasons(two, edge))
        # Recorded limit 2: reads outside every logical root.
        check unavailable.len == 1
        if unavailable.len == 1:
          check "outside every logical root" in unavailable[0]
        check two.eventDetails(edge, "portable-fingerprint").len == 0

      # Build 3: the same checkout is served from its own records.
      let three = host.build(first, portable = true, provisioning = "tarball")
      checkpoint("first checkout, third build, exit " & $three.code & ":\n" &
        three.output)
      require three.code == 0
      for edge in [LibraryCompileEdge, LibraryArchiveEdge]:
        require three.hasEdge(edge)
        check not three.launched(edge)
        check three.cacheDecision(edge) == "cdHit"

      # The second checkout: both edges execute and resolve nothing.
      let other = host.build(second, portable = true, provisioning = "tarball")
      checkpoint("second checkout (" & second & "), exit " & $other.code &
        ":\n" & other.output)
      require other.code == 0
      for edge in [LibraryCompileEdge, LibraryArchiveEdge]:
        require other.hasEdge(edge)
        checkpoint("engine reasons for " & edge & " in the second checkout:\n" &
          engineReasons(other, edge))
        check other.launched(edge)
        check other.cacheDecision(edge) != "cdHit"
        check other.eventDetails(edge, "portable-resolved").len == 0
        check "unblessed-entropy" in other.publishSkip(edge)

      # What does hold across the two checkouts: the bytes.
      check nonEmptyFile(second / LibraryObject)
      check sameBytes(first / LibraryObject, second / LibraryObject)
      check nonEmptyFile(second / LibraryArchive)
      check sameBytes(first / LibraryArchive, second / LibraryArchive)

    test "negative control: with /usr/bin/gcc and ar the compile edge reports the monitor loss and the archives differ":
      var host = newSharedHost("repro-two-checkouts-macos-control-")
      defer: cleanup(host)
      let first = host.scratch / "first" / "mathlibproj"
      let second = host.scratch / "second" / "nested" / "deeper" / "mathlibproj"
      writeMacosLibraryProject(first, "mathlibMacos", mtSystemUsrBin)
      writeMacosLibraryProject(second, "mathlibMacos", mtSystemUsrBin)

      let one = host.build(first, portable = true, provisioning = "path")
      checkpoint("first build (" & first & "), exit " & $one.code & ":\n" &
        one.output)
      require one.code == 0
      # Vacuity: both edges ran and left outputs.
      for edge in [LibraryCompileEdge, LibraryArchiveEdge]:
        require one.hasEdge(edge)
        check one.launched(edge)
      check nonEmptyFile(first / LibraryObject)
      check nonEmptyFile(first / LibraryArchive)
      # The recorded limit with the system's tools: a SIP-protected root
      # image cannot carry the monitor.
      let skip = one.publishSkip(LibraryCompileEdge)
      check "monitor-loss" in skip
      check "/usr/bin/gcc" in skip
      check "SIP" in skip

      # Apple's `ar` stores member modification times: the same objects
      # archived in another checkout, later, give different bytes.
      sleep(1100)
      let other = host.build(second, portable = true, provisioning = "path")
      checkpoint("second checkout (" & second & "), exit " & $other.code &
        ":\n" & other.output)
      require other.code == 0
      check other.launched(LibraryCompileEdge)
      check other.launched(LibraryArchiveEdge)
      check sameBytes(first / LibraryObject, second / LibraryObject)
      check nonEmptyFile(second / LibraryArchive)
      check not sameBytes(first / LibraryArchive, second / LibraryArchive)

else:
  suite "two checkouts share a static library edge (macOS)":
    test "the macOS parity gate is macOS-only":
      skip("macOS (Apple Silicon) only: this gate builds with the macOS " &
        "toolchains and records the macOS limit; the Linux gate is " &
        "t_two_checkouts_share_a_static_library_edge, in this directory")
