## The submission validator (`Remix-Registry.md` §"Zones": Edge, sandboxed).
##
## The validator is where attacker-authored manifests, patches and bundles
## are parsed. Its only output is a `Verdict`: a small fixed-schema record
## the Interior registrar decodes instead of the hostile input. That keeps
## the large, complex parsers out of the Interior; the registrar still
## verifies every signature itself, so a lying validator cannot change who
## authored a record (threat model T13: it can at most get a well-formed
## malicious release logged, which client acceptance and Trust And
## Reputation exist for).
##
## In the local development double the validator runs in-process
## (deviation D1); a hosted registry runs `validateSubmission` in a VM-grade
## guest with no network (gap G3). The function is pure over its input so
## either placement runs the same code.

import ssz_serialization
import repro_remix

const
  MaxVerdictBlobs* = MaxEntries * 2 + MaxSmallLists * 2

type
  VerdictBlob* = object
    id*: Digest32
    size*: uint64

  Verdict* = object
    ok*: bool
    refusal*: RemixRefusal
    detail*: string
    recordKind*: RecordKind
    identity*: Digest32
    remixName*: string
    authors*: seq[Digest32]
    parents*: seq[Digest32]
    blobs*: seq[VerdictBlob]
      ## Every blob the manifest references, deduplicated.
    statementKind*: uint8
      ## For a statement: its kind tag (0 otherwise).
    subject*: Digest32
      ## For a statement: what it is about.

  VerdictBlobW = object
    id: Digest32
    size: uint64

  VerdictW = object
    ok: bool
    refusal: uint8
    detail: List[byte, 1024]
    recordKind: uint8
    identity: Digest32
    remixName: List[byte, MaxNameBytes]
    authors: List[Digest32, MaxSignatures]
    parents: List[Digest32, MaxParents]
    blobs: List[VerdictBlobW, MaxVerdictBlobs]
    statementKind: uint8
    subject: Digest32

const
  SubmittableStatements* = {skYank, skReview, skVouch, skVulnerabilityClaim,
                            skBuildEvidence, skTestEvidence, skAttestedInference}
    ## Statements an author, reviewer, builder or verifier submits through
    ## the Boundary. Verdicts, revocations and moderation are policy and
    ## arrive only through the Interior policy inbox.

proc bytesOf(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  for i, c in s: result[i] = byte(ord(c))

proc strOf(b: openArray[byte]): string =
  result = newString(b.len)
  for i, x in b: result[i] = char(x)

proc validateSubmission*(payload: openArray[byte]): Verdict =
  ## Decode and check one `submit-release` payload. Never raises.
  try:
    let env = decodeEnvelope(payload)
    result.recordKind = env.recordKind
    result.identity = envelopeIdentity(env)
    case env.recordKind
    of rkManifest:
      let v = verifyManifestEnvelope(env)
      result.remixName = v.manifest.remixName
      result.authors = v.manifest.authors
      result.parents = v.manifest.parents
      var refs: seq[BlobRef]
      for p in v.manifest.patches: refs.add p.blob
      for c in v.manifest.configuration: refs.add c.value
      refs.add v.manifest.graphFragments
      refs.add v.manifest.assets
      for r in refs:
        var dup = false
        for b in result.blobs:
          if b.id == r.id: dup = true
        if not dup:
          result.blobs.add VerdictBlob(id: r.id, size: r.size)
    of rkKeyLogEntry:
      # Key-log entries are small fixed-schema records; the registrar
      # replays the chain itself. Here: canonical form and signatures.
      discard decodeKeyLogEntry(env.body)
      discard verifiedSigners(env)
    of rkStatement:
      let st = decodeStatement(env.body)
      if st.kind notin SubmittableStatements:
        refuse(rrForbiddenContent, $st.kind & " is not submitted through the Boundary")
      if st.subjectKind != sbRelease:
        refuse(rrForbiddenContent, "submitted statements are about releases")
      result.statementKind = uint8(ord(st.kind))
      result.subject = st.subject
      result.authors = verifiedSigners(env)
      if result.authors != @[st.issuer]:
        refuse(rrForbiddenContent, "a personal statement is signed by its issuer alone")
    else:
      refuse(rrForbiddenContent, "only manifests, key-log entries and statements are submitted")
    result.ok = true
  except RemixError as e:
    result.ok = false
    result.refusal = e.reason
    result.detail = e.msg[0 ..< min(e.msg.len, 1024)]

proc encodeVerdict*(v: Verdict): seq[byte] =
  var bs: seq[VerdictBlobW]
  for b in v.blobs: bs.add VerdictBlobW(id: b.id, size: b.size)
  SSZ.encode(VerdictW(ok: v.ok, refusal: uint8(ord(v.refusal)),
    detail: List[byte, 1024].init(bytesOf(v.detail)),
    recordKind: uint8(ord(v.recordKind)), identity: v.identity,
    remixName: List[byte, MaxNameBytes].init(bytesOf(v.remixName)),
    authors: List[Digest32, MaxSignatures].init(v.authors),
    parents: List[Digest32, MaxParents].init(v.parents),
    blobs: List[VerdictBlobW, MaxVerdictBlobs].init(bs),
    statementKind: v.statementKind, subject: v.subject))

proc decodeVerdict*(bytes: openArray[byte]): Verdict =
  ## What the registrar runs on the validator's output: a bounded,
  ## fixed-schema decode with vocabulary checks.
  var w: VerdictW
  try:
    w = SSZ.decode(bytes, VerdictW)
  except SerializationError as e:
    refuse(rrMalformed, "validator verdict: " & e.msg)
  if w.refusal > uint8(ord(RemixRefusal.high)):
    refuse(rrUnknownVocabulary, "verdict refusal code")
  if w.ok and (w.recordKind < 1 or w.recordKind > uint8(ord(RecordKind.high))):
    refuse(rrUnknownVocabulary, "verdict record kind")
  result = Verdict(ok: w.ok, refusal: RemixRefusal(w.refusal),
    detail: strOf(asSeq(w.detail)), identity: w.identity,
    remixName: strOf(asSeq(w.remixName)), authors: asSeq(w.authors),
    parents: asSeq(w.parents), statementKind: w.statementKind, subject: w.subject)
  if w.ok:
    result.recordKind = RecordKind(w.recordKind)
  for b in asSeq(w.blobs):
    result.blobs.add VerdictBlob(id: b.id, size: b.size)
