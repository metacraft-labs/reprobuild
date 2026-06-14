## B1 P5: lowering integration test.
##
## Verifies:
##   * The sample config lowers into the expected edges (kernel,
##     kernel-cmdline, per-package, unit-graph, etc-skeleton).
##   * Re-lowering produces a byte-identical graph (the
##     reproducibility requirement from the B1 spec).
##   * Edge ids are stable and uniquely identify each edge.
##   * The payload survives deterministically sorted serialization.

import std/[options, os, sets, strutils, tables, unittest]

from repro_core/paths import extendedPath

import repro_system_apply

const SampleConfigPath =
  currentSourcePath.parentDir.parentDir.parentDir.parentDir /
    "recipes" / "reproos-sample-config" / "configuration.nim"

suite "B1 DSL lowering":

  test "sample config lowers to all edge kinds":
    let cfg = parseSystemConfigFile(SampleConfigPath)
    let graph = lower(cfg)
    # Collect distinct kinds.
    var kinds: HashSet[BuildEdgeKind]
    for e in graph.edges:
      kinds.incl e.kind
    check bekKernel in kinds
    check bekKernelCmdline in kinds
    check bekPackageFromSource in kinds
    check bekPackageForeignBundle in kinds
    check bekUnitGraphSnapshot in kinds
    check bekEtcSkeleton in kinds
    # Tier-1 packages: coreutils + bash + systemd (3 from-source).
    var srcCount = 0
    for e in graph.edges:
      if e.kind == bekPackageFromSource: inc srcCount
    check srcCount == 3
    # Tier-3 packages: vim + git (2 foreign).
    var fgnCount = 0
    for e in graph.edges:
      if e.kind == bekPackageForeignBundle: inc fgnCount
    check fgnCount == 2
    # Exactly one unit-graph + one etc-skeleton edge.
    var ugCount = 0
    var esCount = 0
    for e in graph.edges:
      if e.kind == bekUnitGraphSnapshot: inc ugCount
      if e.kind == bekEtcSkeleton: inc esCount
    check ugCount == 1
    check esCount == 1
    # Kernel edge.
    let kIdx = findEdge(graph, bekKernel, "reproosKernel")
    check kIdx >= 0

  test "re-lowering produces a byte-identical graph":
    let cfg = parseSystemConfigFile(SampleConfigPath)
    let g1 = lower(cfg)
    let g2 = lower(cfg)
    let s1 = serializeForReproCheck(g1)
    let s2 = serializeForReproCheck(g2)
    check s1 == s2
    check g1.edges.len == g2.edges.len
    for i, e1 in g1.edges:
      let e2 = g2.edges[i]
      check e1.kind == e2.kind
      check e1.edgeId == e2.edgeId
      check e1.primaryKey == e2.primaryKey

  test "edges are sorted deterministically by (kind, edgeId)":
    let cfg = parseSystemConfigFile(SampleConfigPath)
    let graph = lower(cfg)
    var prev = ""
    for e in graph.edges:
      let curKey = $ord(e.kind) & ":" & e.edgeId
      check curKey > prev
      prev = curKey

  test "edge ids are unique across the graph":
    let cfg = parseSystemConfigFile(SampleConfigPath)
    let graph = lower(cfg)
    var ids: HashSet[string]
    for e in graph.edges:
      check e.edgeId notin ids
      ids.incl e.edgeId

  test "kernel-cmdline edge payload joins parts space-separated":
    let cfg = parseSystemConfigFile(SampleConfigPath)
    let graph = lower(cfg)
    let edges = edgeOfKind(graph, bekKernelCmdline)
    check edges.len == 1
    let parts = edges[0].payload["parts"]
    check "console=ttyS0,115200n8" in parts
    check "init=/sbin/init" in parts
    check "rw" in parts

  test "unit-graph snapshot edge encodes every service":
    let cfg = parseSystemConfigFile(SampleConfigPath)
    let graph = lower(cfg)
    let edges = edgeOfKind(graph, bekUnitGraphSnapshot)
    check edges.len == 1
    let units = edges[0].payload["units"]
    check "systemd-networkd.service=enabled" in units
    check "serial-getty@ttyS0.service=enabled" in units
    check "systemd-resolved.service=disabled" in units

  test "etc-skeleton edge encodes every user + every mount":
    let cfg = parseSystemConfigFile(SampleConfigPath)
    let graph = lower(cfg)
    let edges = edgeOfKind(graph, bekEtcSkeleton)
    check edges.len == 1
    let users = edges[0].payload["users"]
    let mounts = edges[0].payload["mounts"]
    check "root|" in users
    check "ada|" in users
    check "/|LABEL=reproos-root|ext4|" in mounts
    check "/boot|LABEL=reproos-boot|vfat|" in mounts

  test "foreign-bundle edges retain snapshot pin in payload":
    let cfg = parseSystemConfigFile(SampleConfigPath)
    let graph = lower(cfg)
    var vimEdge: BuildEdge
    var gitEdge: BuildEdge
    for e in graph.edges:
      if e.kind == bekPackageForeignBundle and e.primaryKey == "vim":
        vimEdge = e
      if e.kind == bekPackageForeignBundle and e.primaryKey == "git":
        gitEdge = e
    check vimEdge.payload["distro"] == "apt"
    check vimEdge.payload["snapshot"] == "debian/bookworm/20260601T000000Z"
    check gitEdge.payload["distro"] == "apt"
    check gitEdge.payload["snapshot"] == "debian/bookworm/20260601T000000Z"

  test "empty config lowers to empty graph":
    let src = """
system empty:
  kernel = reproosKernel
"""
    let cfg = parseSystemConfigSource("test://empty.nim", src)
    let graph = lower(cfg)
    # Only the kernel edge — no packages, no services, no users, no
    # mounts, no kernel cmdline.
    check graph.edges.len == 1
    check graph.edges[0].kind == bekKernel

  test "graph with no kernel emits no kernel edge":
    let src = """
system noKernel:
  packages = [
    coreutils,
  ]
"""
    let cfg = parseSystemConfigSource("test://nok.nim", src)
    let graph = lower(cfg)
    check edgeOfKind(graph, bekKernel).len == 0
    check edgeOfKind(graph, bekPackageFromSource).len == 1
