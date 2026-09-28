## RFC 6962 Merkle inclusion proofs, and nothing else.
##
## ## What this is for
##
## A transparency log is an append-only tree. An **inclusion proof** is
## the sequence of sibling hashes that recomputes the tree's root from
## one leaf. A verifier that recomputes a root it already trusts has
## established that the leaf really is in the tree that root describes —
## and, crucially, that the log operator cannot have replaced the leaf
## afterwards without the root changing.
##
## ## Why the root is never an argument this module takes on trust
##
## ``rootFromInclusionProof`` **returns** a root. It does not compare one.
## The comparison is the caller's, and it is deliberately not offered
## here, because the only safe right-hand side of that comparison is a
## root the verifier obtained from somewhere other than the document
## under test. A procedure that took both the proof and the expected root
## would be one call away from being handed the proof's own idea of the
## root, which establishes nothing at all.
##
## ## The two domain separators are not decoration
##
## RFC 6962 §2.1 prefixes a leaf with ``0x00`` and an interior node with
## ``0x01``. Without them a leaf whose bytes happen to be two
## concatenated hashes could be presented as an interior node — the
## second-preimage attack the prefixes exist to close. They are written
## as named constants below so a reader can see that both are present
## and that they differ.
##
## ## Mocking
##
## None. Real SHA-256 over real bytes.

import ./measurement

type
  MerkleError* = object of CatchableError
    ## Raised for a proof this module will not evaluate. Every message
    ## says what was structurally wrong, because a proof that does not
    ## evaluate is a document defect rather than a verdict.

const
  LeafPrefix* = '\x00'
  NodePrefix* = '\x01'
  DigestBytes* = 32
  DigestHexLen* = DigestBytes * 2

  MaxAuditPath* = 64
    ## A path of 64 sibling hashes describes a tree of 2^64 leaves. A
    ## longer one is not a bigger log, it is a document trying to make a
    ## verifier work; bounded here so the bound is a stated rule rather
    ## than whatever the machine runs out of first.

proc isLowerHexDigest(s: string): bool =
  if s.len != DigestHexLen: return false
  for c in s:
    if c notin {'0' .. '9', 'a' .. 'f'}: return false
  true

proc requireDigest(where, value: string) =
  if not isLowerHexDigest(value):
    raise newException(MerkleError,
      where & " must be " & $DigestHexLen &
      " lower-case hex characters, got " & $value.len & " characters")

proc rawOf(hexDigest: string): string =
  ## The 32 bytes a hex digest spells. Not exported: every boundary of
  ## this module speaks hex, so there is exactly one place that converts.
  result = newString(DigestBytes)
  const Values = "0123456789abcdef"
  for i in 0 ..< DigestBytes:
    let hi = Values.find(hexDigest[2 * i])
    let lo = Values.find(hexDigest[2 * i + 1])
    result[i] = char(hi * 16 + lo)

proc merkleLeafHash*(leaf: string): string =
  ## ``SHA-256(0x00 ‖ leaf)`` — RFC 6962 §2.1. ``leaf`` is the entry's
  ## bytes, not a digest of them.
  sha256Hex(LeafPrefix & leaf)

proc merkleNodeHash*(left, right: string): string =
  ## ``SHA-256(0x01 ‖ left ‖ right)`` — RFC 6962 §2.1. Both arguments are
  ## hex digests and so is the result, so a caller cannot accidentally
  ## feed this the hex text instead of the bytes it hashes.
  requireDigest("the left child", left)
  requireDigest("the right child", right)
  sha256Hex(NodePrefix & rawOf(left) & rawOf(right))

proc rootFromInclusionProof*(leafHash: string; leafIndex, treeSize: int;
                             auditPath: openArray[string]): string =
  ## The root this proof recomputes, by RFC 6962 §2.1.1.
  ##
  ## Refuses rather than returns a wrong answer for every structural
  ## defect the algorithm can detect: an index outside the tree, a
  ## non-positive tree, a path that runs out before the root, and a path
  ## with hashes left over once the root is reached. The last two are the
  ## ones worth naming — a proof of the right *shape* for a different
  ## tree size is exactly what an attacker submits, and an implementation
  ## that stopped consuming the path when it felt finished would accept
  ## it.
  if treeSize <= 0:
    raise newException(MerkleError,
      "a tree of " & $treeSize & " leaves contains nothing to prove")
  if leafIndex < 0 or leafIndex >= treeSize:
    raise newException(MerkleError,
      "leaf index " & $leafIndex & " is outside a tree of " & $treeSize &
      " leaves")
  if auditPath.len > MaxAuditPath:
    raise newException(MerkleError,
      "the audit path carries " & $auditPath.len & " hashes and at most " &
      $MaxAuditPath & " are evaluated")
  requireDigest("the leaf hash", leafHash)
  for i, p in auditPath:
    requireDigest("audit path element " & $i, p)

  var fn = leafIndex
  var sn = treeSize - 1
  result = leafHash
  for i, sibling in auditPath:
    if sn == 0:
      raise newException(MerkleError,
        "the audit path carries " & $auditPath.len & " hashes and the " &
        "root of a tree of " & $treeSize & " leaves was reached after " &
        $i & "; the remaining hashes belong to some other tree")
    if (fn and 1) == 1 or fn == sn:
      result = merkleNodeHash(sibling, result)
      while fn != 0 and (fn and 1) == 0:
        fn = fn shr 1
        sn = sn shr 1
    else:
      result = merkleNodeHash(result, sibling)
    fn = fn shr 1
    sn = sn shr 1
  if sn != 0:
    raise newException(MerkleError,
      "the audit path carries " & $auditPath.len & " hashes, which is " &
      "too few to reach the root of a tree of " & $treeSize & " leaves")

proc merkleRootOf*(leaves: openArray[string]): string =
  ## The root of a tree over these leaves, by RFC 6962 §2.1. Present so a
  ## caller — a test, a log operator's own consistency check — can build
  ## a tree without reaching for a second implementation of the hashing
  ## rules above.
  if leaves.len == 0:
    raise newException(MerkleError,
      "a Merkle tree over no leaves has no root; RFC 6962 gives the " &
      "empty tree the hash of the empty string, which is a different " &
      "thing and is not what any caller here means")
  var level: seq[string] = @[]
  for leaf in leaves: level.add merkleLeafHash(leaf)
  while level.len > 1:
    var next: seq[string] = @[]
    var i = 0
    while i + 1 < level.len:
      next.add merkleNodeHash(level[i], level[i + 1])
      i += 2
    if i < level.len: next.add level[i]
    level = next
  level[0]

proc inclusionPathFor*(leaves: openArray[string]; leafIndex: int):
                      seq[string] =
  ## The audit path for one leaf of the tree ``merkleRootOf`` builds.
  ##
  ## The companion to the procedure above and present for the same
  ## reason: a proof a test builds by hand is a proof that tests the
  ## hand, not the verifier.
  if leafIndex < 0 or leafIndex >= leaves.len:
    raise newException(MerkleError,
      "leaf index " & $leafIndex & " is outside a tree of " & $leaves.len &
      " leaves")
  var level: seq[string] = @[]
  for leaf in leaves: level.add merkleLeafHash(leaf)
  var idx = leafIndex
  while level.len > 1:
    let sibling = (if (idx and 1) == 1: idx - 1 else: idx + 1)
    if sibling < level.len: result.add level[sibling]
    var next: seq[string] = @[]
    var i = 0
    while i + 1 < level.len:
      next.add merkleNodeHash(level[i], level[i + 1])
      i += 2
    if i < level.len: next.add level[i]
    level = next
    idx = idx shr 1
