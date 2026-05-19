## M58 gate: `integration_configurable_system_basic_resolution`.
##
## Normative description from the milestone:
##
##   Two independent `evalConfig` blocks resolve different values for
##   the same configurable construction site; priority precedence is
##   enforced; RBCG round-trips with scope-derived names and any
##   explicit ids; construction ids are NOT present in the persisted
##   bytes; corrupted RBCG is rejected.

import std/[os, strutils, tables, unittest]
import repro_dsl_stdlib/configurables

suite "M58 basic resolution":

  test "two evalConfig blocks produce independent resolved values":
    var pHandle1: Configurable[int]
    var pHandle2: Configurable[int]
    let staging = evalConfig:
      let port = configurable 8080
      port.override 4
      pHandle1 = port
    let production = evalConfig:
      let port = configurable 8080
      port.override 32
      pHandle2 = port
    check staging.read(pHandle1) == 4
    check production.read(pHandle2) == 32
    # The two contexts must share NO state.
    check staging != production

  test "priority precedence: prForce > prOverride > prSet > prDefault":
    var phandle: Configurable[int]
    let ctx = evalConfig:
      let port = configurable 8080      # prDefault
      port := 8090                       # prSet
      port.override 9000                 # prOverride
      port.force 9999                    # prForce
      phandle = port
    check ctx.read(phandle) == 9999

  test "second prForce raises EDuplicateForce":
    expect EDuplicateForce:
      discard evalConfig:
        let port = configurable 8080
        port.force 9000
        port.force 9100

  test "RBCG round-trip preserves scope and explicit id; no construction ids":
    var portHandle, replicasHandle: Configurable[int]
    let ctx = evalConfig:
      config:
        ## TCP port the API server binds.
        ## @id api-server-port
        port = 8080

        ## Worker replicas.
        replicas = 1
      port.override 9000
      replicas.override 4
      portHandle = port
      replicasHandle = replicas
    let bytes = encodeRbcg(ctx)
    # Envelope shape sanity: magic "RBCG", body, trailing checksum.
    check bytes.len > 4 + 2 + 4 + 32
    check char(bytes[0]) == 'R'
    check char(bytes[1]) == 'B'
    check char(bytes[2]) == 'C'
    check char(bytes[3]) == 'G'

    # Decode standalone and verify scope-derived names + explicit ids.
    let decoded = decodeRbcg(bytes)
    var sawPort = false
    var sawReplicas = false
    for n in decoded.nodes:
      if n.scopeDerivedName == "port":
        sawPort = true
        check n.explicitId == "api-server-port"
        check unwrapInt(n.resolvedVal) == 9000
        check n.description.contains("TCP port")
        # The @id line MUST NOT appear in the persisted description.
        check not n.description.contains("@id")
      elif n.scopeDerivedName == "replicas":
        sawReplicas = true
        check n.explicitId.len == 0
        check unwrapInt(n.resolvedVal) == 4
    check sawPort
    check sawReplicas

    # Construction ids must NOT appear in the persisted bytes.
    # Byte-determinism alone (encoding twice produces identical
    # output) is necessary but not sufficient — a leaking encoder
    # would still be deterministic. The substantive guard lives in
    # the next subtest, which builds a graph specifically designed
    # so any construction-id leakage would be byte-detectable, then
    # scans the envelope.
    let bytes2 = encodeRbcg(ctx)
    check bytes == bytes2

  test "RBCG envelope leaks no construction ids and round-trips edges":
    # This subtest exists because the on-disk shape was once buggy:
    # the dep list of each node was written as raw u64 ConstructionId
    # values, which the spec explicitly forbids ("Construction ids
    # are never persisted and never appear in RBCG envelopes"). To
    # catch a regression of that bug we build a graph where every
    # field that could legitimately carry a small u64 value is
    # crafted to NOT collide with the byte-shape of a leaked
    # construction id, then scan the encoded bytes for that shape.
    #
    # Graph layout (chosen to make the scan unambiguous):
    #
    #   id 0: port0    leaf, value w/ all 8 bytes nonzero
    #                  NEVER depended on — reserves id 0 so no
    #                  dep slot ever holds the value 0
    #   id 1: port1    leaf, depended on by summed
    #   id 2: port2    leaf, depended on by summed
    #   id 3: summed   operator (port1 + port2), deps @[1, 2]
    #   id 4: port3    leaf, name "port3" — placed BETWEEN summed
    #                  and doubled so summed's deps section is not
    #                  immediately followed by an empty-named node
    #                  (which would create a `dep_u32 || 4 zero
    #                  bytes` false-positive pattern)
    #   id 5: doubled  operator (port3 * 2), deps @[4] — last node
    #                  in the envelope, so its dep section ends at
    #                  end-of-body and the 8-byte sliding window
    #                  never straddles past it
    #
    # All four leaf values use bytes that are all nonzero, so a
    # cvkInt value-u64 field cannot be mistaken for a leaked
    # construction id at any sliding-window offset.

    const
      v0: int = 0x1122_3344_5566_7788
      v1: int = 0x1122_3344_5566_7799
      v2: int = 0x1122_3344_5566_77AA
      v3: int = 0x1122_3344_5566_77BB
      nodeCount = 6   # 4 leaves + 2 operators

    var sumHandle, doubledHandle: Configurable[int]
    var port0Handle, port1Handle, port2Handle, port3Handle: Configurable[int]
    let ctx = evalConfig:
      # The `config:` block gives each leaf a scope-derived name. We
      # need names to (a) verify scope-derived-name round-trip and
      # (b) cleanly identify nodes after decoding.
      config:
        port0 = v0   # id 0 (reserved; never a dep)
        port1 = v1   # id 1
        port2 = v2   # id 2
      let summed = port1 + port2    # id 3, deps @[1, 2]
      config:
        port3 = v3   # id 4 (separator + doubled's source)
      let doubled = port3 * 2       # id 5, deps @[4]
      port0Handle = port0
      port1Handle = port1
      port2Handle = port2
      port3Handle = port3
      sumHandle = summed
      doubledHandle = doubled

    # Sanity: edges resolved correctly in the source context.
    check ctx.read(port0Handle) == v0
    check ctx.read(sumHandle) == v1 + v2
    check ctx.read(doubledHandle) == v3 * 2

    let bytes = encodeRbcg(ctx)

    # ---- Byte scan: no construction-id-as-u64-LE pattern appears.
    # A construction id N written as u64-LE is `[N, 0, 0, 0, 0, 0, 0,
    # 0]`. The buggy v1 encoder wrote each dep as exactly such a
    # u64-LE; the v2 encoder writes each dep as a u32 = 4 bytes, so
    # the trailing 4 bytes are determined by the NEXT field rather
    # than being forced to zero. We scan every 8-byte window in the
    # body and assert that none equals `[k, 0, 0, 0, 0, 0, 0, 0]` for
    # any k in the set of construction ids actually referenced as
    # deps in this graph: {1, 2, 4}. (We do not scan for k=0 because
    # all-zero windows occur naturally in empty-string length fields,
    # zero descriptionLine/Column, and the depCount of leaves with
    # no deps — none of which is a leak.)
    let depReferencedIds: array[3, uint64] = [1'u64, 2'u64, 4'u64]
    let bodyStart = 4 + 2 + 4 + 6   # envelope hdr + body's u16 ver + u32 nodeCount
    let bodyEnd = bytes.len - 32    # exclude trailing checksum
    var leaks: seq[(int, uint64)] = @[]
    for off in bodyStart .. bodyEnd - 8:
      var u: uint64 = 0
      for k in 0 ..< 8:
        u = u or (uint64(bytes[off + k]) shl (8 * k))
      for refId in depReferencedIds:
        if u == refId:
          leaks.add((off, u))
          break
    if leaks.len != 0:
      checkpoint("construction-id-shaped leaks found at: " & $leaks)
    check leaks.len == 0

    # ---- Round-trip: decode, then verify each dep edge points at
    # the right node *by scope-derived name*. This proves the new
    # encoding actually preserves the edges it claims to preserve
    # (i.e. that the u32 serialization-position indices were
    # correctly resolved back to the depended-on nodes).
    let decoded = decodeRbcg(bytes)
    check decoded.nodes.len == nodeCount

    # Locate each named leaf by scope-derived name.
    var idxByName: Table[string, int]
    for i, n in decoded.nodes:
      if n.scopeDerivedName.len > 0:
        idxByName[n.scopeDerivedName] = i

    for name in ["port0", "port1", "port2", "port3"]:
      check name in idxByName

    # The operator-derived nodes have empty scope names; find them by
    # their non-empty deps lists.
    var depNodes: seq[ConfigurableNode]
    for n in decoded.nodes:
      if n.deps.len > 0: depNodes.add n
    check depNodes.len == 2

    # Each dep edge must point at one of the named leaf nodes.
    let leafIndices = [idxByName["port0"], idxByName["port1"],
                       idxByName["port2"], idxByName["port3"]]
    for n in depNodes:
      for d in n.deps:
        check int(d) in leafIndices

    # Specifically: one operator depends on {port1, port2}; the other
    # depends on {port3}. We identify them by inspecting the
    # resolvedVal we computed for them (which round-tripped through
    # the envelope verbatim).
    var sawSum, sawDoubled = false
    for n in depNodes:
      var depIdxs: seq[int]
      for d in n.deps: depIdxs.add int(d)
      if depIdxs.len == 2 and
         idxByName["port1"] in depIdxs and
         idxByName["port2"] in depIdxs:
        sawSum = true
        check unwrapInt(n.resolvedVal) == v1 + v2
      elif depIdxs.len == 1 and depIdxs[0] == idxByName["port3"]:
        sawDoubled = true
        check unwrapInt(n.resolvedVal) == v3 * 2
    check sawSum
    check sawDoubled

  test "corrupted RBCG is rejected by trailing checksum":
    let ctx = evalConfig:
      let port = configurable 8080
      port.override 9000
    var bytes = encodeRbcg(ctx)
    # Flip one byte inside the body (away from the trailing checksum).
    let target = bytes.len - 40
    bytes[target] = bytes[target] xor 0xFF'u8
    expect ECorruptEnvelope:
      discard decodeRbcg(bytes)

  test "evalConfig is reentrant within a thread":
    var outer, inner: Configurable[int]
    let outerCtx = evalConfig:
      let a = configurable 1
      outer = a
      let innerCtx = evalConfig:
        let b = configurable 2
        b.override 20
        inner = b
      check innerCtx.read(inner) == 20
      a.override 10
    check outerCtx.read(outer) == 10
