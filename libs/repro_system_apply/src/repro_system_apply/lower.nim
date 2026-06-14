## B1 P3: lower a parsed `SystemConfig` into a typed `BuildGraph`.
##
## The lowering pass emits one edge per kernel build action, one edge
## per package (Tier 1 / Tier 2 / Tier 3), one singleton edge per
## "unit-graph snapshot" collected from the `services:` block, and
## one singleton edge per "/etc skeleton" collected from `users:`,
## `mounts:`, and `kernel_cmdline`. The result is the input to B2's
## apply pipeline (delivered later in the campaign).
##
## Reproducibility (the B1 spec's "re-lowering produces byte-identical
## graph" requirement):
##
##   * Edges are sorted by `(kind enum value, edgeId)` before return.
##   * `edgeId` is derived from `(kind, primaryKey)` only — never from
##     run-environment facts (no timestamps, no PIDs, no host names).
##   * Per-edge `payload` is a `Table[string, string]` that the
##     `serializeForReproCheck` helper renders as alphabetically
##     ordered key=value pairs joined by `\n` so two lowerings of the
##     same config produce the same byte sequence.

import std/[algorithm, options, sequtils, strutils, tables]

import ./types

# ---------------------------------------------------------------------------
# Edge-id derivation. Stable across runs and platforms.
# ---------------------------------------------------------------------------

proc sanitizeIdSegment(s: string): string =
  result = newStringOfCap(s.len)
  for c in s:
    if c in {'a'..'z', 'A'..'Z', '0'..'9', '-', '_', '.'}:
      result.add c
    elif c in {'/', '\\', ':', '@', ' '}:
      result.add '_'
    # Everything else is dropped (mount sources can contain
    # `LABEL=...` etc.; the equals sign is dropped here but the full
    # untransformed string is preserved in the `payload`).

proc deriveEdgeId(kind: BuildEdgeKind; primaryKey: string): string =
  case kind
  of bekKernel:
    "kernel:" & sanitizeIdSegment(primaryKey)
  of bekKernelCmdline:
    "kernel-cmdline:default"
  of bekPackageFromSource:
    "pkg-src:" & sanitizeIdSegment(primaryKey)
  of bekPackageStandalone:
    "pkg-std:" & sanitizeIdSegment(primaryKey)
  of bekPackageForeignBundle:
    "pkg-fgn:" & sanitizeIdSegment(primaryKey)
  of bekUnitGraphSnapshot:
    "unit-graph:default"
  of bekEtcSkeleton:
    "etc-skel:default"

# ---------------------------------------------------------------------------
# Sorting + serialization helpers.
# ---------------------------------------------------------------------------

proc edgeSortKey(e: BuildEdge): string =
  $ord(e.kind) & ":" & e.edgeId

proc sortEdges(edges: var seq[BuildEdge]) =
  edges.sort(proc(a, b: BuildEdge): int = cmp(edgeSortKey(a), edgeSortKey(b)))

# ---------------------------------------------------------------------------
# Per-section edge emitters.
# ---------------------------------------------------------------------------

proc emitKernelEdge(cfg: SystemConfig; out_edges: var seq[BuildEdge]) =
  if cfg.kernel.isEmpty: return
  var payload = initTable[string, string]()
  payload["kernelName"] = cfg.kernel.name
  payload["sourceFile"] = cfg.kernel.sourceFile
  payload["sourceLine"] = $cfg.kernel.sourceLine
  out_edges.add BuildEdge(kind: bekKernel,
    edgeId: deriveEdgeId(bekKernel, cfg.kernel.name),
    primaryKey: cfg.kernel.name,
    payload: payload)

proc emitKernelCmdlineEdge(cfg: SystemConfig; out_edges: var seq[BuildEdge]) =
  if cfg.kernelCmdline.isEmpty: return
  var payload = initTable[string, string]()
  payload["parts"] = cfg.kernelCmdline.parts.join(" ")
  payload["sourceFile"] = cfg.kernelCmdline.sourceFile
  payload["sourceLine"] = $cfg.kernelCmdline.sourceLine
  out_edges.add BuildEdge(kind: bekKernelCmdline,
    edgeId: deriveEdgeId(bekKernelCmdline, ""),
    primaryKey: "",
    payload: payload)

proc emitPackageEdges(cfg: SystemConfig; out_edges: var seq[BuildEdge]) =
  ## Deduplicate by `name` with last-write-wins semantics matching the
  ## DSL composition rule documented in `dsl.nim`.
  var byName = initOrderedTable[string, PackageRef]()
  for p in cfg.packages:
    byName[p.name] = p
  for p in byName.values:
    var payload = initTable[string, string]()
    payload["packageName"] = p.name
    payload["tier"] = $p.tier
    if p.distro.len > 0:
      payload["distro"] = p.distro
    if p.snapshot.len > 0:
      payload["snapshot"] = p.snapshot
    payload["sourceFile"] = p.sourceFile
    payload["sourceLine"] = $p.sourceLine
    let kind = case p.tier
               of ptFromSource: bekPackageFromSource
               of ptStandaloneBinary: bekPackageStandalone
               of ptForeignBundle: bekPackageForeignBundle
    out_edges.add BuildEdge(kind: kind,
      edgeId: deriveEdgeId(kind, p.name),
      primaryKey: p.name,
      payload: payload)

proc emitUnitGraphEdge(cfg: SystemConfig; out_edges: var seq[BuildEdge]) =
  if cfg.services.len == 0: return
  var byUnit = initOrderedTable[string, ServiceState]()
  for s in cfg.services:
    byUnit[s.unit] = s
  var units = toSeq(byUnit.keys)
  units.sort()
  var payload = initTable[string, string]()
  var encoded = newSeq[string](0)
  for u in units:
    encoded.add u & "=" & $byUnit[u].state
  payload["units"] = encoded.join(";")
  payload["count"] = $units.len
  out_edges.add BuildEdge(kind: bekUnitGraphSnapshot,
    edgeId: deriveEdgeId(bekUnitGraphSnapshot, ""),
    primaryKey: "",
    payload: payload)

proc emitEtcSkeletonEdge(cfg: SystemConfig; out_edges: var seq[BuildEdge]) =
  ## The `/etc` skeleton snapshot collects every config-driven file
  ## that lands under `/etc` at boot time. B1 only records the
  ## inputs; the actual rendering of `/etc/passwd`, `/etc/group`,
  ## `/etc/fstab`, etc. is B2's responsibility.
  if cfg.users.len == 0 and cfg.mounts.len == 0 and
     cfg.kernelCmdline.isEmpty:
    return
  var payload = initTable[string, string]()
  # Users — sorted by name for byte stability.
  var userNames: seq[string]
  var byName = initOrderedTable[string, User]()
  for u in cfg.users:
    byName[u.name] = u
    userNames.add u.name
  userNames.sort()
  var userEnc: seq[string]
  for n in userNames:
    let u = byName[n]
    var groupsCopy = u.groups
    groupsCopy.sort()
    let groupsStr = groupsCopy.join(",")
    let uidStr = if u.uid.isSome: $u.uid.get else: ""
    userEnc.add n & "|" & uidStr & "|" & u.shell & "|" & u.homeDir & "|" &
      groupsStr & "|" & u.passwordHash
  payload["users"] = userEnc.join(";")
  payload["userCount"] = $userNames.len

  # Mounts — sorted by mount point for byte stability.
  var mountPoints: seq[string]
  var byPoint = initOrderedTable[string, MountEntry]()
  for m in cfg.mounts:
    byPoint[m.mountPoint] = m
    mountPoints.add m.mountPoint
  mountPoints.sort()
  var mountEnc: seq[string]
  for mp in mountPoints:
    let m = byPoint[mp]
    var opts = m.options
    opts.sort()
    let optStr = if opts.len > 0: opts.join(",") else: "defaults"
    mountEnc.add mp & "|" & m.source & "|" & m.fstype & "|" &
      optStr & "|" & $m.dump & "|" & $m.pass
  payload["mounts"] = mountEnc.join(";")
  payload["mountCount"] = $mountPoints.len

  out_edges.add BuildEdge(kind: bekEtcSkeleton,
    edgeId: deriveEdgeId(bekEtcSkeleton, ""),
    primaryKey: "",
    payload: payload)

# ---------------------------------------------------------------------------
# Public entry point.
# ---------------------------------------------------------------------------

proc lower*(cfg: SystemConfig): BuildGraph =
  ## Lower `cfg` into a deterministic `BuildGraph`. Re-lowering the
  ## same config produces a byte-identical graph (verified by
  ## `serializeForReproCheck` and the t_b1_dsl_lowering test).
  var edges: seq[BuildEdge]
  emitKernelEdge(cfg, edges)
  emitKernelCmdlineEdge(cfg, edges)
  emitPackageEdges(cfg, edges)
  emitUnitGraphEdge(cfg, edges)
  emitEtcSkeletonEdge(cfg, edges)
  sortEdges(edges)
  BuildGraph(edges: edges)

proc serializeForReproCheck*(g: BuildGraph): string =
  ## Byte-stable serialization of `g` suitable for hashing /
  ## comparison. Renders each edge as:
  ##
  ## .. code-block:: text
  ##
  ##   <kind>\t<edgeId>\t<primaryKey>
  ##     <payloadKeyA>=<payloadValueA>
  ##     <payloadKeyB>=<payloadValueB>
  ##
  ## The payload keys are sorted alphabetically.
  var buf = newStringOfCap(1024)
  for e in g.edges:
    buf.add $e.kind
    buf.add '\t'
    buf.add e.edgeId
    buf.add '\t'
    buf.add e.primaryKey
    buf.add '\n'
    var keys = toSeq(e.payload.keys)
    keys.sort()
    for k in keys:
      buf.add "  "
      buf.add k
      buf.add '='
      buf.add e.payload[k]
      buf.add '\n'
  buf

proc edgeOfKind*(g: BuildGraph; kind: BuildEdgeKind): seq[BuildEdge] =
  for e in g.edges:
    if e.kind == kind:
      result.add e

proc findEdge*(g: BuildGraph; kind: BuildEdgeKind;
               primaryKey: string): int =
  ## Linear lookup that returns the 0-based index of the matching
  ## edge or -1 if not found. The graph is small (tens of edges in
  ## realistic configurations) so the O(n) cost is negligible.
  for i, e in g.edges:
    if e.kind == kind and e.primaryKey == primaryKey:
      return i
  -1
