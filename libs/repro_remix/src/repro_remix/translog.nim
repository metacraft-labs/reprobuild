## Append-only transparency log (spec §"Transparency log").
##
## Tree shape and proof algorithms are RFC 9162 (Certificate Transparency
## Version 2.0) §2.1, with BLAKE3 in place of SHA-256 (spec OD-9):
##   https://www.rfc-editor.org/rfc/rfc9162#section-2.1
## The two hash prefixes (0x00 leaf, 0x01 node) are what keep a leaf from
## ever being presented as an interior node.
##
## `MerkleLog` is an in-memory log: the registry's local development
## double and the test harness use it to produce proofs. Verification
## (`verifyInclusion`, `verifyConsistency`) needs only hashes and is what
## clients run offline.

import blake3

import ./types

type
  MerkleLog* = object
    leaves*: seq[Digest32]
      ## Leaf hashes, in append order. Position = index.

proc toD(d: Blake3Digest): Digest32 =
  for i in 0 ..< 32: result[i] = d[i]

proc hashLeaf*(leaf: openArray[byte]): Digest32 =
  let h = initHasher()
  try:
    h.update([0x00'u8])
    h.update(leaf)
    result = toD(h.finalize())
  finally:
    h.close()

proc hashNode*(left, right: Digest32): Digest32 =
  let h = initHasher()
  try:
    h.update([0x01'u8])
    h.update(left)
    h.update(right)
    result = toD(h.finalize())
  finally:
    h.close()

proc emptyRoot*(): Digest32 =
  ## MTH({}) = HASH() — the hash of the empty string.
  toD(blake3.digest(newSeq[byte]()))

proc logLeaf*(recordKind: RecordKind; identity: Digest32;
              envelopeBytes: openArray[byte]): seq[byte] =
  ## The leaf a record is logged as: kind, identity and a digest of the
  ## exact signed bytes, so the log commits to signatures as well.
  result = @[byte(ord(recordKind))]
  result.add identity
  let d = blake3.digest(envelopeBytes)
  for b in d: result.add b

proc largestPowerOfTwoBelow(n: int): int =
  ## The k of RFC 9162: the largest power of two strictly less than n (n > 1).
  result = 1
  while result * 2 < n:
    result *= 2

proc subtreeRoot(leaves: openArray[Digest32]; lo, hi: int): Digest32 =
  let n = hi - lo
  if n == 0: return emptyRoot()
  if n == 1: return leaves[lo]
  let k = largestPowerOfTwoBelow(n)
  hashNode(subtreeRoot(leaves, lo, lo + k), subtreeRoot(leaves, lo + k, hi))

proc append*(log: var MerkleLog; leaf: openArray[byte]): int =
  ## Append a leaf; returns its position.
  log.leaves.add hashLeaf(leaf)
  log.leaves.len - 1

proc size*(log: MerkleLog): int = log.leaves.len

proc root*(log: MerkleLog; size = -1): Digest32 =
  ## Root of the first `size` leaves (default: all).
  let n = (if size < 0: log.leaves.len else: size)
  if n > log.leaves.len:
    refuse(rrBound, "tree size beyond the log")
  subtreeRoot(log.leaves, 0, n)

proc inclusionPath(leaves: openArray[Digest32]; m, lo, hi: int): seq[Digest32] =
  ## PATH(m, D[lo:hi]) of RFC 9162 §2.1.3.1.
  let n = hi - lo
  if n <= 1: return @[]
  let k = largestPowerOfTwoBelow(n)
  if m < k:
    result = inclusionPath(leaves, m, lo, lo + k)
    result.add subtreeRoot(leaves, lo + k, hi)
  else:
    result = inclusionPath(leaves, m - k, lo + k, hi)
    result.add subtreeRoot(leaves, lo, lo + k)

proc inclusionProof*(log: MerkleLog; index, size: int): seq[Digest32] =
  if index < 0 or size > log.leaves.len or index >= size:
    refuse(rrBound, "inclusion proof outside the tree")
  inclusionPath(log.leaves, index, 0, size)

proc subproof(leaves: openArray[Digest32]; m, lo, hi: int; b: bool): seq[Digest32] =
  ## SUBPROOF(m, D[lo:hi], b) of RFC 9162 §2.1.4.1.
  let n = hi - lo
  if m == n:
    if b: return @[]
    return @[subtreeRoot(leaves, lo, hi)]
  let k = largestPowerOfTwoBelow(n)
  if m <= k:
    result = subproof(leaves, m, lo, lo + k, b)
    result.add subtreeRoot(leaves, lo + k, hi)
  else:
    result = subproof(leaves, m - k, lo + k, hi, false)
    result.add subtreeRoot(leaves, lo, lo + k)

proc consistencyProof*(log: MerkleLog; first, second: int): seq[Digest32] =
  if first <= 0 or first > second or second > log.leaves.len:
    refuse(rrBound, "consistency proof outside the tree")
  if first == second: return @[]
  subproof(log.leaves, first, 0, second, true)

proc isPowerOfTwo(x: uint64): bool = x != 0 and (x and (x - 1)) == 0

proc verifyInclusion*(leafHash: Digest32; index, size: uint64;
                      proof: openArray[Digest32]; root: Digest32): bool =
  ## RFC 9162 §2.1.3.2.
  if index >= size: return false
  var fn = index
  var sn = size - 1
  var r = leafHash
  for p in proof:
    if sn == 0: return false
    if (fn and 1) == 1 or fn == sn:
      r = hashNode(p, r)
      if (fn and 1) == 0:
        while (fn and 1) == 0 and fn != 0:
          fn = fn shr 1
          sn = sn shr 1
    else:
      r = hashNode(r, p)
    fn = fn shr 1
    sn = sn shr 1
  sn == 0 and r == root

proc verifyConsistency*(first, second: uint64; firstRoot, secondRoot: Digest32;
                        proof: openArray[Digest32]): bool =
  ## RFC 9162 §2.1.4.2.
  if first > second: return false
  if first == second:
    return proof.len == 0 and firstRoot == secondRoot
  if first == 0:
    return proof.len == 0           # the empty tree is consistent with all
  var path = @proof
  if isPowerOfTwo(first):
    path.insert(firstRoot, 0)
  if path.len == 0: return false
  var fn = first - 1
  var sn = second - 1
  while (fn and 1) == 1:
    fn = fn shr 1
    sn = sn shr 1
  var fr = path[0]
  var sr = path[0]
  for c in path[1 .. ^1]:
    if sn == 0: return false
    if (fn and 1) == 1 or fn == sn:
      fr = hashNode(c, fr)
      sr = hashNode(c, sr)
      if (fn and 1) == 0:
        while (fn and 1) == 0 and fn != 0:
          fn = fn shr 1
          sn = sn shr 1
    else:
      sr = hashNode(sr, c)
    fn = fn shr 1
    sn = sn shr 1
  fr == firstRoot and sr == secondRoot and sn == 0
