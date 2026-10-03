## The ``reproos.edge-attestations.v1`` document: proofs that a build
## edge really produced the output it claims.
##
## ## What the document is for
##
## A build-graph edge is a typed claim ``(recipe, inputs) → output``.
## Content addressing proves the bytes match a key; it says nothing about
## whether the key is the right one. An **edge attestation** is any
## verifier of that claim, and a single edge may carry several at once
## with different trust assumptions and costs.
##
## This module carries the transport for them, and only the transport.
## It holds no key, performs no cryptography, and decides nothing: it
## defines the bytes a rebuilder signs, the container those proofs travel
## in, and the strict reader for both. Which proofs are worth anything is
## a policy question, answered by the verifier.
##
## ## The edge this build attests
##
## One: the edge whose output is a measurement manifest. A manifest is an
## ordinary build output, so it can carry the same attestations any other
## node can — and it is the node where the build-time and run-time
## evidence planes meet, because a verifier who trusts the rebuilder set
## can accept a manifest it did not build itself.
##
## The claim is therefore ``configFingerprint → manifest digest``: the
## recipe-and-inputs identity on the left, the output hash on the right.
## **Both halves are signed and both are checked**, and that is not
## belt-and-braces. A signature over the digest alone is a statement
## about a document with no subject; a signature over the fingerprint
## alone is satisfied by any manifest that configuration ever produced,
## including the one it produced before a defect was fixed.
##
## ## Why the proof is opaque bytes
##
## Every entry is ``(verifier identifier, proof bytes)``. The identifier
## says which rules evaluate the bytes; the bytes mean nothing without
## it. An entry naming a verifier this build does not implement is
## **kept and carried**, not refused — the whole point of a pluggable
## evidence model is that a document may hold proofs for verifiers older
## and newer than any one reader. It is the *verifier*, not the parser,
## that must then decline to count what it cannot evaluate, and say so.
##
## That division is the one place this module could go wrong quietly, so
## it is worth stating in the negative: **nothing in this file makes an
## attestation count for anything.** A parse that succeeds establishes
## that a document is well formed. It establishes nothing about a build.
##
## ## Mocking
##
## None.

import std/[json, strutils]

import ./manifest
import ./measurement

type
  EdgeAttestationError* = object of CatchableError
    ## Raised for any document this module will not honour. The message
    ## names the offending key, because its reader is whoever has to
    ## regenerate the document.

  EdgeClaim* = object
    ## The claim a rebuilder signs: which configuration, and which
    ## manifest that configuration produced.
    configFingerprint*: string
    manifestDigest*: string
      ## ``sha256:<hex>`` of the manifest document's canonical bytes —
      ## the same string a policy's ``measurements.manifests`` pins, so
      ## a pinned manifest and an attested one are named the same way.

  EdgeAttestation* = object
    verifier*: string
      ## Which rules evaluate ``proof``. Not an enum: a document may
      ## carry a proof for a verifier this build has never heard of.
    proof*: string
      ## Lower-case hex. Opaque here by construction.

  EdgeAttestationBundle* = object
    subject*: EdgeClaim
    attestations*: seq[EdgeAttestation]

  LogInclusionProof* = object
    ## What a ``reproos.log-inclusion-proof.v1`` proof decodes to.
    ##
    ## There is deliberately no ``leafHash`` and no ``root`` field. The
    ## leaf is the statement, so a verifier computes its hash from the
    ## claim it is checking; and the root is the verifier's own witnessed
    ## value, never the document's. A proof that supplied either would be
    ## choosing what it is compared against.
    logId*: string
    leafIndex*: int
    treeSize*: int
    auditPath*: seq[string]

const
  EdgeAttestationsSchema* = "reproos.edge-attestations.v1"
  EdgeStatementSchema* = "reproos.edge-attestation-statement.v1"
  LogInclusionProofSchema* = "reproos.log-inclusion-proof.v1"

  EdgeAttestationsFileName* = "reproos.edge-attestations.json"
    ## What the document is called when it rides a manifest. Declared
    ## beside the schema so the tool that writes it and the verifier that
    ## looks for it cannot disagree about the name.

  MeasurementManifestEdge* = "reproos.measurement-manifest"
    ## The edge kind this build attests, written into every statement.
    ## A signature minted for one kind of edge is then not a signature
    ## for another, whatever the two claims happen to have in common.

  QuorumVerifierId* = "signed-quorum.v1"
    ## A detached COSE_Sign1 over the statement bytes, by one rebuilder.
    ## One entry per rebuilder: independent rebuilds produce independent
    ## documents, and a single multi-signature blob would make one
    ## malformed signature a reason to discard the others.

  TransparencyLogVerifierId* = "transparency-log-inclusion.v1"
    ## A ``reproos.log-inclusion-proof.v1`` document, hex-encoded.

  KnownVerifierIds*: array[2, string] =
    [QuorumVerifierId, TransparencyLogVerifierId]
    ## The verifiers THIS build evaluates. A document may name others;
    ## this array is what the verifier uses to say which entries it
    ## declined to evaluate, and it is not a parse-time allow list.

  MaxAttestations* = 64
  MaxProofHexLen* = 16_384
  MaxVerifierIdLen* = 64
  MaxLogIdLen* = 128
  MaxAuditPathElements* = 64
  MaxBundleBytes* = 262_144

  BundleTopLevelKeys*: array[3, string] = ["schema", "subject", "attestations"]
  SubjectKeys*: array[2, string] = ["configFingerprint", "manifest"]
  AttestationKeys*: array[2, string] = ["verifier", "proof"]
  InclusionProofKeys*: array[5, string] =
    ["schema", "logId", "leafIndex", "treeSize", "auditPath"]

proc isLowerHex(s: string; want: int): bool =
  if want > 0 and s.len != want: return false
  if s.len == 0 or (s.len and 1) == 1: return false
  for c in s:
    if c notin {'0' .. '9', 'a' .. 'f'}: return false
  true

proc isSafeToken(s: string; maxLen: int): bool =
  if s.len == 0 or s.len > maxLen: return false
  for c in s:
    if c notin {'0' .. '9', 'a' .. 'z', 'A' .. 'Z', '.', '_', '-', ':',
                '+', '/', '=', ';', ',', '@'}:
      return false
  true

proc fail(msg: string) {.noreturn.} =
  raise newException(EdgeAttestationError, msg)

proc requireManifestDigest(where, value: string) =
  if not value.startsWith(DigestPrefix) or
     not isLowerHex(value[DigestPrefix.len .. ^1], 64):
    fail(where & " must be \"" & DigestPrefix &
      "<64 lower-case hex characters>\", got " & value.escapeJson())

# ---------------------------------------------------------------------
# The claim, and the bytes it is signed as
# ---------------------------------------------------------------------

proc validateEdgeClaim*(c: EdgeClaim) =
  if not isSafeToken(c.configFingerprint, FingerprintMaxLen):
    fail("configFingerprint must be a non-empty token of at most " &
      $FingerprintMaxLen & " characters from [0-9A-Za-z._:;,+/=@-], got " &
      c.configFingerprint.escapeJson())
  requireManifestDigest("manifest", c.manifestDigest)

proc edgeStatementBytes*(c: EdgeClaim): string =
  ## The exact bytes a rebuilder signs, and the exact bytes a
  ## transparency log holds as the leaf.
  ##
  ## Hand-rendered in a fixed key order, like every other document in
  ## this chain: two parties who agree about a claim have to produce the
  ## same bytes for it, or a signature made by one is unverifiable by the
  ## other for reasons that have nothing to do with trust.
  ##
  ## The ``edge`` key is what stops a statement being replayed as a
  ## different kind of claim that happens to carry the same two strings.
  validateEdgeClaim(c)
  proc q(s: string): string = "\"" & s & "\""
  result = "{\n"
  result.add "  \"schema\": " & q(EdgeStatementSchema) & ",\n"
  result.add "  \"edge\": " & q(MeasurementManifestEdge) & ",\n"
  result.add "  \"configFingerprint\": " & q(c.configFingerprint) & ",\n"
  result.add "  \"manifest\": " & q(c.manifestDigest) & "\n"
  result.add "}\n"

proc manifestDigestOf*(manifestText: string): string =
  ## ``sha256:<hex>`` of a manifest's bytes, spelled the one way the
  ## policy, the verdict and this document all spell it.
  DigestPrefix & sha256Hex(manifestText)

proc claimForManifest*(manifestText, source: string): EdgeClaim =
  ## The claim a manifest's own bytes make. Parsed rather than scanned,
  ## so a document that is not a manifest cannot produce a claim about
  ## one.
  let m = parseAttestedImageManifest(manifestText, source)
  result = EdgeClaim(configFingerprint: m.configFingerprint,
                     manifestDigest: manifestDigestOf(manifestText))
  validateEdgeClaim(result)

# ---------------------------------------------------------------------
# Validation of a bundle
# ---------------------------------------------------------------------

proc validateEdgeAttestationBundle*(b: EdgeAttestationBundle) =
  ## The single validator. The renderer runs it before it writes and the
  ## parser runs it after it reads, so a document cannot become valid by
  ## the route it travelled.
  validateEdgeClaim(b.subject)
  if b.attestations.len > MaxAttestations:
    fail("attestations carries " & $b.attestations.len & " entries and at " &
      "most " & $MaxAttestations & " are read")
  for i, a in b.attestations:
    let at = "attestations[" & $i & "]"
    if not isSafeToken(a.verifier, MaxVerifierIdLen):
      fail(at & ".verifier must be a non-empty token of at most " &
        $MaxVerifierIdLen & " characters from [0-9A-Za-z._:;,+/=@-], got " &
        a.verifier.escapeJson())
    if a.proof.len > MaxProofHexLen:
      fail(at & ".proof is " & $a.proof.len & " hex characters and at most " &
        $MaxProofHexLen & " are read")
    if not isLowerHex(a.proof, 0):
      fail(at & ".proof must be an even number of lower-case hex " &
        "characters; every proof this document carries is opaque bytes")

# ---------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------

proc renderEdgeAttestationBundle*(b: EdgeAttestationBundle): string =
  ## The canonical bytes, in a fixed key order with a fixed indent.
  validateEdgeAttestationBundle(b)
  proc q(s: string): string = "\"" & s & "\""
  result = "{\n"
  result.add "  \"schema\": " & q(EdgeAttestationsSchema) & ",\n"
  result.add "  \"subject\": {\n"
  result.add "    \"configFingerprint\": " & q(b.subject.configFingerprint) &
    ",\n"
  result.add "    \"manifest\": " & q(b.subject.manifestDigest) & "\n"
  result.add "  },\n"
  result.add "  \"attestations\": ["
  for i, a in b.attestations:
    result.add (if i == 0: "\n" else: ",\n")
    result.add "    {\n"
    result.add "      \"verifier\": " & q(a.verifier) & ",\n"
    result.add "      \"proof\": " & q(a.proof) & "\n"
    result.add "    }"
  result.add (if b.attestations.len > 0: "\n  ]\n" else: "]\n")
  result.add "}\n"

# ---------------------------------------------------------------------
# Parsing
# ---------------------------------------------------------------------

proc requireObject(node: JsonNode; where: string): JsonNode =
  if node.kind != JObject:
    fail(where & " must be a JSON object")
  node

proc requireKeys(node: JsonNode; where: string; allowed: openArray[string]) =
  for key in node.keys:
    if key notin allowed:
      fail(where & " carries the unknown field " & key.escapeJson() &
        "; this build understands " & allowed.join(", ") &
        " and refuses a document it cannot fully honour")
  for key in allowed:
    if not node.hasKey(key):
      fail(where & " is missing the required field " & key.escapeJson())

proc str(node: JsonNode; where, key: string): string =
  let v = node[key]
  if v.kind != JString:
    fail(where & "." & key & " must be a string")
  v.getStr

proc intOf(node: JsonNode; where, key: string): int =
  let v = node[key]
  if v.kind != JInt:
    fail(where & "." & key & " must be an integer")
  v.getInt

proc parseEdgeAttestationBundle*(text, source: string): EdgeAttestationBundle =
  ## Parse and fully validate a bundle.
  ##
  ## An entry naming a verifier this build does not implement parses. See
  ## the module header: refusing it here would make the evidence model
  ## unextendable, and counting it is not this module's to do.
  if text.len > MaxBundleBytes:
    fail(source & ": is " & $text.len & " bytes; at most " &
      $MaxBundleBytes & " are read")
  var doc: JsonNode
  try:
    doc = parseJson(text)
  except CatchableError as err:
    fail(source & ": not JSON: " & err.msg)
  discard requireObject(doc, source)
  requireKeys(doc, source, BundleTopLevelKeys)

  let schema = str(doc, source, "schema")
  if schema != EdgeAttestationsSchema:
    fail(source & ": schema is " & schema.escapeJson() & "; this build " &
      "understands " & EdgeAttestationsSchema.escapeJson() &
      " and refuses a document it cannot fully honour")

  let subject = requireObject(doc["subject"], source & ".subject")
  requireKeys(subject, source & ".subject", SubjectKeys)
  result.subject = EdgeClaim(
    configFingerprint: str(subject, source & ".subject", "configFingerprint"),
    manifestDigest: str(subject, source & ".subject", "manifest"))

  if doc["attestations"].kind != JArray:
    fail(source & ".attestations must be an array of proofs, even when " &
      "it is empty")
  for i, entry in doc["attestations"].elems:
    let at = source & ".attestations[" & $i & "]"
    discard requireObject(entry, at)
    requireKeys(entry, at, AttestationKeys)
    result.attestations.add EdgeAttestation(
      verifier: str(entry, at, "verifier"),
      proof: str(entry, at, "proof"))

  try:
    validateEdgeAttestationBundle(result)
  except EdgeAttestationError as err:
    fail(source & ": " & err.msg)

# ---------------------------------------------------------------------
# Proof bytes
# ---------------------------------------------------------------------

# A proof's hex is decoded with ``repro_attest/binding``'s
# ``hexToBytes`` and emitted with its ``bytesToHex``. Not re-implemented
# here, deliberately: two hex readers in one library is two answers to
# what a byte is, and the one that is wrong is whichever one a document
# did not travel through.

proc parseLogInclusionProof*(text, source: string): LogInclusionProof =
  ## Read the document a ``transparency-log-inclusion.v1`` proof's bytes
  ## spell. Strict in the same way and for the same reasons as every
  ## other reader here.
  var doc: JsonNode
  try:
    doc = parseJson(text)
  except CatchableError as err:
    fail(source & ": the inclusion proof is not JSON: " & err.msg)
  discard requireObject(doc, source)
  requireKeys(doc, source, InclusionProofKeys)
  let schema = str(doc, source, "schema")
  if schema != LogInclusionProofSchema:
    fail(source & ": the inclusion proof's schema is " & schema.escapeJson() &
      "; this build understands " & LogInclusionProofSchema.escapeJson())
  result.logId = str(doc, source, "logId")
  if not isSafeToken(result.logId, MaxLogIdLen):
    fail(source & ".logId must be a non-empty token of at most " &
      $MaxLogIdLen & " characters from [0-9A-Za-z._:;,+/=@-]")
  result.leafIndex = intOf(doc, source, "leafIndex")
  result.treeSize = intOf(doc, source, "treeSize")
  if doc["auditPath"].kind != JArray:
    fail(source & ".auditPath must be an array of hashes, even when it " &
      "is empty")
  if doc["auditPath"].elems.len > MaxAuditPathElements:
    fail(source & ".auditPath carries " & $doc["auditPath"].elems.len &
      " hashes and at most " & $MaxAuditPathElements & " are evaluated")
  for i, e in doc["auditPath"].elems:
    if e.kind != JString:
      fail(source & ".auditPath[" & $i & "] must be a string")
    if not isLowerHex(e.getStr, 64):
      fail(source & ".auditPath[" & $i & "] must be 64 lower-case hex " &
        "characters")
    result.auditPath.add e.getStr

proc renderLogInclusionProof*(p: LogInclusionProof): string =
  ## The canonical bytes of an inclusion proof, which are what a proof
  ## entry's hex spells.
  proc q(s: string): string = "\"" & s & "\""
  result = "{\n"
  result.add "  \"schema\": " & q(LogInclusionProofSchema) & ",\n"
  result.add "  \"logId\": " & q(p.logId) & ",\n"
  result.add "  \"leafIndex\": " & $p.leafIndex & ",\n"
  result.add "  \"treeSize\": " & $p.treeSize & ",\n"
  result.add "  \"auditPath\": ["
  for i, h in p.auditPath:
    result.add (if i == 0: "\n" else: ",\n") & "    " & q(h)
  result.add (if p.auditPath.len > 0: "\n  ]\n" else: "]\n")
  result.add "}\n"
