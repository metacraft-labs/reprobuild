## `GraphCacheDescriptor` — the content-addressed graph a worker hydrates
## (Distributed-Execution M7 receiver shape; M4 extends it with pip ids,
## priorities and `ExpectedPeakWorkingSetMb`).
##
## The descriptor is the ONLY source of what a worker may execute. It names
## the snapshot content it was evaluated from (`snapshotContentId`, a TC-8
## `git-tree-sha1:<hex>`), the platform, and the nodes — each with its argv,
## working directory, declared inputs and declared outputs, all relative to
## the worktree. A worker fetches it by its BLAKE3 digest (the content plane
## verifies the bytes), refuses it unless the snapshot it materialized hashes
## to `snapshotContentId`, and then runs a node's argv exactly as written
## here. A `ReachGoalRequest` names a node; it never supplies the command.
##
## Version 2 (trust profiles, 2026-10-20) adds per node:
##
## * `egress` — the names of the operator-declared destinations the node
##   needs. A lease gets forwarders for exactly these and has NO network
##   otherwise ("network off unless the action declares destinations");
##   a name the worker does not allow is refused.
## * `impure` + `fixedOutputs` — a DECLARED IMPURE ACTION in the shape of a
##   Nix fixed-output derivation: an action that fetches or provisions
##   (it is typically the one that declares egress) whose every declared
##   output carries the BLAKE3 digest it must have. The worker publishes
##   its outputs only when each matches; any mismatch fails the goal and is
##   recorded (`impure-output-mismatch`). Running such an action with
##   administrator rights, outside the lease, is NOT done here: that part
##   is M2's (target-OS tool provisioning), see the milestone.
##
## Version 3 (review fixes, 2026-10-20) adds per node `inputNodes` — the
## ids of the EARLIER nodes whose declared outputs this node consumes (a test
## node that runs the binary a build node produced). A `ReachGoalRequest`
## for the node may carry those outputs as content-addressed input
## artifacts; the worker materializes them read-only and executable beside
## the worktree (`receiver.nim`), never into the writable, noexec worktree.
##
## Decoding is strict and bounded (the bytes came from another host), and
## `validateDescriptor` refuses argv that does not start with an absolute
## tool path, relative paths that escape the worktree, and environment
## entries that inject code into the tools (`LD_PRELOAD`, `LD_AUDIT`,
## `DYLD_*` — the DET-1 vectors).

import std/[algorithm, os, sets, strutils]

import blake3
from repro_core/codec import elementCountFits

import repro_workspace_snapshot/manifest

const
  DescriptorSchema* = "repro.graph-cache-descriptor.v1"
  DescriptorMagic = "RGCD"
  DescriptorVersion = 3'u16
  MaxNodes* = 100_000
  MaxArgs* = 4_096
  MaxArgBytes* = 64 * 1024
  MaxNodePaths* = 100_000
  MaxEnv* = 256
  MaxNameBytes* = 1_024
  ForbiddenEnvPrefixes* = ["LD_PRELOAD", "LD_AUDIT", "LD_LIBRARY_PATH",
                           "DYLD_", "REPRO_LEASE_"]
  MaxEgressNames* = 16

type
  GraphNode* = object
    id*: string
    argv*: seq[string]
    cwd*: string
      ## Worktree-relative; "" is the worktree root.
    inputs*: seq[string]
    outputs*: seq[string]
    env*: seq[(string, string)]
    isTest*: bool
      ## A test node: passing it can be certified (TC-8).
    egress*: seq[string]
      ## Names of operator-declared egress destinations the node needs;
      ## empty = no network at all.
    impure*: bool
      ## A declared impure (fixed-output) action; see the module doc.
    fixedOutputs*: seq[(string, array[32, byte])]
      ## For an impure node: (declared output, BLAKE3 digest it must have),
      ## one per declared output.
    inputNodes*: seq[string]
      ## Ids of other nodes of this descriptor whose declared outputs this
      ## node consumes as input artifacts; see the module doc.

  GraphCacheDescriptor* = object
    schema*: string
    project*: string
    platform*: string
    snapshotContentId*: string
    nodes*: seq[GraphNode]
      ## Sorted by id, unique.

  DescriptorError* = object of CatchableError

proc findNode*(d: GraphCacheDescriptor; id: string): int =
  for i, n in d.nodes:
    if n.id == id: return i
  -1

proc validateDescriptor*(d: GraphCacheDescriptor): string =
  ## "" when the descriptor is safe to act on, else the first reason.
  if d.schema != DescriptorSchema:
    return "unsupported descriptor schema: " & d.schema
  if not d.snapshotContentId.startsWith("git-tree-sha1:") or
      d.snapshotContentId.len != "git-tree-sha1:".len + 40:
    return "descriptor names no git-tree-sha1 snapshot content"
  if d.nodes.len == 0 or d.nodes.len > MaxNodes:
    return "descriptor node count out of range"
  var prev = ""
  for i, n in d.nodes:
    if n.id.len == 0 or n.id.len > MaxNameBytes:
      return "node id missing or too long"
    if i > 0 and n.id <= prev:
      return "descriptor nodes are not sorted and unique"
    prev = n.id
    if n.argv.len == 0 or n.argv.len > MaxArgs:
      return "node " & n.id & ": argv empty or too long"
    if not n.argv[0].isAbsolute:
      return "node " & n.id & ": argv[0] is not an absolute tool path"
    for a in n.argv:
      if a.len > MaxArgBytes or '\0' in a:
        return "node " & n.id & ": malformed argument"
    if n.cwd.len > 0:
      let bad = validateRelPath(n.cwd)
      if bad.len > 0: return "node " & n.id & " cwd: " & bad
    if n.inputs.len > MaxNodePaths or n.outputs.len > MaxNodePaths:
      return "node " & n.id & ": too many paths"
    for p in n.inputs & n.outputs:
      let bad = validateRelPath(p)
      if bad.len > 0: return "node " & n.id & ": " & bad
    if n.env.len > MaxEnv:
      return "node " & n.id & ": too many environment entries"
    for (k, v) in n.env:
      if k.len == 0 or '=' in k or '\0' in k or '\0' in v:
        return "node " & n.id & ": malformed environment entry"
      for prefix in ForbiddenEnvPrefixes:
        if k.startsWith(prefix):
          return "node " & n.id & ": environment entry " & k &
            " is not permitted in a lease"
    if n.egress.len > MaxEgressNames:
      return "node " & n.id & ": too many egress names"
    for name in n.egress:
      if name.len == 0 or name.len > 64:
        return "node " & n.id & ": malformed egress name"
      for ch in name:
        if not (ch.isAlphaNumeric or ch in {'-', '_'}):
          return "node " & n.id & ": malformed egress name " & name
    if n.impure:
      if n.outputs.len == 0:
        return "node " & n.id & ": an impure action must declare outputs"
      var fixed = initHashSet[string]()
      for (path, _) in n.fixedOutputs:
        if path in fixed:
          return "node " & n.id & ": duplicate fixed output " & path
        fixed.incl(path)
      for o in n.outputs:
        if o notin fixed:
          return "node " & n.id & ": impure action output " & o &
            " has no fixed digest (outputs of an impure action are " &
            "content-addressed)"
      if fixed.len != n.outputs.len:
        return "node " & n.id & ": a fixed digest names an undeclared output"
    elif n.fixedOutputs.len > 0:
      return "node " & n.id & ": fixed outputs are declared only by an " &
        "impure action"
    if n.inputNodes.len > MaxNodePaths:
      return "node " & n.id & ": too many input nodes"
    var seenInputs = initHashSet[string]()
    for dep in n.inputNodes:
      if dep == n.id:
        return "node " & n.id & ": a node cannot be its own input node"
      # An input node's id names the directory its artifacts are
      # materialized in (`<lease>/inputs/<id>/…`): a plain name, never a
      # path.
      if dep in [".", ".."] or dep.len > 255:
        return "node " & n.id & ": input node " & dep & " is not a plain name"
      for ch in dep:
        if not (ch.isAlphaNumeric or ch in {'-', '_', '.'}):
          return "node " & n.id & ": input node " & dep & " is not a plain name"
      if dep in seenInputs:
        return "node " & n.id & ": duplicate input node " & dep
      seenInputs.incl(dep)
      if d.findNode(dep) < 0:
        return "node " & n.id & ": input node " & dep &
          " is not in the descriptor"
  ""

proc sortNodes*(d: var GraphCacheDescriptor) =
  d.nodes.sort(proc(a, b: GraphNode): int = cmp(a.id, b.id))

# ---------------------------------------------------------------------------
# Codec.
# ---------------------------------------------------------------------------

proc putU16(b: var seq[byte]; v: uint16) =
  b.add(byte(v and 0xff)); b.add(byte(v shr 8))
proc putU32(b: var seq[byte]; v: uint32) =
  for s in countup(0, 24, 8): b.add(byte((v shr uint32(s)) and 0xff))
proc putStr(b: var seq[byte]; s: string) =
  b.putU32(uint32(s.len))
  for ch in s: b.add(byte(ord(ch)))
proc putStrs(b: var seq[byte]; xs: seq[string]) =
  b.putU32(uint32(xs.len))
  for x in xs: b.putStr(x)

proc need(d: openArray[byte]; pos, n: int) =
  if n < 0 or pos + n > d.len:
    raise newException(DescriptorError, "truncated graph descriptor")
proc getU16(d: openArray[byte]; pos: var int): uint16 =
  need(d, pos, 2)
  result = uint16(d[pos]) or (uint16(d[pos + 1]) shl 8)
  pos += 2
proc getU32(d: openArray[byte]; pos: var int): uint32 =
  need(d, pos, 4)
  for i in 0 ..< 4: result = result or (uint32(d[pos + i]) shl uint32(8 * i))
  pos += 4
proc getCount(d: openArray[byte]; pos: var int; minimumBytes: int): int =
  ## An element count, bounded BEFORE anything is sized or looped over by
  ## it: each element takes at least `minimumBytes` (repro_core/codec).
  let raw = getU32(d, pos)
  if not elementCountFits(raw, d.len - pos, minimumBytes):
    raise newException(DescriptorError, "graph descriptor element count exceeds remaining bytes")
  int(raw)
proc getStr(d: openArray[byte]; pos: var int; maxLen: int): string =
  let n = int(getU32(d, pos))
  if n > maxLen:
    raise newException(DescriptorError, "graph descriptor string too long")
  need(d, pos, n)
  result = newString(n)
  for i in 0 ..< n: result[i] = char(d[pos + i])
  pos += n
proc getStrs(d: openArray[byte]; pos: var int; maxCount, maxLen: int): seq[string] =
  let n = getCount(d, pos, 4)
  if n > maxCount:
    raise newException(DescriptorError, "graph descriptor list too long")
  for _ in 0 ..< n: result.add(getStr(d, pos, maxLen))

proc encodeDescriptor*(d: GraphCacheDescriptor): seq[byte] =
  for ch in DescriptorMagic: result.add(byte(ord(ch)))
  result.putU16(DescriptorVersion)
  result.putStr(d.schema)
  result.putStr(d.project)
  result.putStr(d.platform)
  result.putStr(d.snapshotContentId)
  result.putU32(uint32(d.nodes.len))
  for n in d.nodes:
    result.putStr(n.id)
    result.putStrs(n.argv)
    result.putStr(n.cwd)
    result.putStrs(n.inputs)
    result.putStrs(n.outputs)
    result.putU32(uint32(n.env.len))
    for (k, v) in n.env:
      result.putStr(k)
      result.putStr(v)
    result.add(if n.isTest: 1'u8 else: 0'u8)
    result.putStrs(n.egress)
    result.add(if n.impure: 1'u8 else: 0'u8)
    result.putU32(uint32(n.fixedOutputs.len))
    for (path, digest) in n.fixedOutputs:
      result.putStr(path)
      result.add(digest)
    result.putStrs(n.inputNodes)

proc decodeDescriptor*(data: openArray[byte]): GraphCacheDescriptor =
  need(data, 0, DescriptorMagic.len)
  for i, ch in DescriptorMagic:
    if data[i] != byte(ord(ch)):
      raise newException(DescriptorError, "not a graph descriptor")
  var pos = DescriptorMagic.len
  if getU16(data, pos) != DescriptorVersion:
    raise newException(DescriptorError, "unsupported graph descriptor version")
  result.schema = getStr(data, pos, 128)
  result.project = getStr(data, pos, MaxNameBytes)
  result.platform = getStr(data, pos, 128)
  result.snapshotContentId = getStr(data, pos, 128)
  # A node is at least 38 bytes: id, argv, cwd, inputs, outputs, env,
  # egress, fixed outputs and input nodes (a u32 each) plus two flag bytes.
  let n = getCount(data, pos, 38)
  if n > MaxNodes:
    raise newException(DescriptorError, "too many graph nodes")
  for _ in 0 ..< n:
    var node: GraphNode
    node.id = getStr(data, pos, MaxNameBytes)
    node.argv = getStrs(data, pos, MaxArgs, MaxArgBytes)
    node.cwd = getStr(data, pos, MaxPathBytes)
    node.inputs = getStrs(data, pos, MaxNodePaths, MaxPathBytes)
    node.outputs = getStrs(data, pos, MaxNodePaths, MaxPathBytes)
    let ne = getCount(data, pos, 8)
    if ne > MaxEnv:
      raise newException(DescriptorError, "too many environment entries")
    for _ in 0 ..< ne:
      let k = getStr(data, pos, MaxNameBytes)
      let v = getStr(data, pos, MaxArgBytes)
      node.env.add((k, v))
    need(data, pos, 1)
    node.isTest = data[pos] != 0
    inc pos
    node.egress = getStrs(data, pos, MaxEgressNames, 64)
    need(data, pos, 1)
    node.impure = data[pos] != 0
    inc pos
    let nf = getCount(data, pos, 36)
    if nf > MaxNodePaths:
      raise newException(DescriptorError, "too many fixed outputs")
    for _ in 0 ..< nf:
      let path = getStr(data, pos, MaxPathBytes)
      need(data, pos, 32)
      var digest: array[32, byte]
      for i in 0 ..< 32: digest[i] = data[pos + i]
      pos += 32
      node.fixedOutputs.add((path, digest))
    node.inputNodes = getStrs(data, pos, MaxNodePaths, MaxNameBytes)
    result.nodes.add(node)
  if pos != data.len:
    raise newException(DescriptorError, "trailing bytes after graph descriptor")

proc descriptorDigest*(d: GraphCacheDescriptor): array[32, byte] =
  blake3.digest(encodeDescriptor(d))
