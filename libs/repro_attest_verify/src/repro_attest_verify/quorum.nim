## What a bundle of edge attestations is worth: a K-of-N quorum over
## rebuilder signatures, and inclusion in a transparency log.
##
## ## The two questions, and why they are separate
##
## A quorum answers "did K independent rebuilders reach this output?".
## A log inclusion proof answers "is this claim in an append-only record
## whose root I already hold?". The first defends against a single
## compromised builder; the second against a publisher quietly replacing
## an old claim with a new one. Neither implies the other, so neither is
## folded into the other here, and a policy may require either, both or
## nothing.
##
## ## Why this is not built on ``verifyCoseSign``
##
## ``repro_attest/cose`` refuses a ``COSE_Sign`` unless **every**
## signature in it verifies, and says in its own header that choosing
## whose verdict counts is an application decision a library must not
## make silently. A quorum is exactly that decision, so it is made here.
##
## Each rebuilder therefore contributes its own detached ``COSE_Sign1``,
## as a separate entry in the bundle, and each is evaluated on its own
## through the library's ordinary ``verifyCoseSign1``. Nothing in the
## library is relaxed and no second signature implementation exists: a
## signature that would be refused there is refused here.
##
## ## The three ways an entry can fail to count, which are not the same
##
## A verifier that lumped them together would be unreadable, and worse,
## would make two of them silent:
##
##   * **Not a signer.** The kid is outside the admitted set. This is not
##     a defect in the document — an unadmitted party may sign whatever
##     it likes — so it does not reject. It is named, and it counts for
##     nothing.
##   * **A second vote from a signer already counted.** Counted once.
##     This is the whole content of "distinct signer" at the level this
##     design can support, and it is the reason a bundle cannot reach K
##     by repeating one rebuilder K times.
##   * **A defect.** The bytes are not a ``COSE_Sign1``, or the signature
##     does not verify under the key its own kid names, or it is a
##     signature over some *other* claim. Each of these means the
##     document has been tampered with or assembled wrongly, and each
##     **rejects**, rather than quietly lowering the count. A bundle that
##     reached K while carrying a forged signature would be accepted on
##     the strength of the honest ones, which is precisely the reading a
##     forger wants.
##
## ## What "distinct" does NOT establish
##
## Distinctness here is key-distinctness, and nothing else. The design
## speaks of "N independent rebuilders", but nothing in a signature says
## who holds the key: one party holding K keys satisfies every rule in
## this file. That gap is the design's, not this module's, and it is
## reported as a caveat on every evidence-backed acceptance rather than
## papered over.
##
## ## Mocking
##
## None. Real ECDSA over real bytes.

import std/[algorithm, strutils, tables]

import repro_attest
import repro_attest/cose

type
  SignerAdmission* = object
    ## For how long a rebuilder's key is admitted, and whether it has
    ## been revoked.
    ##
    ## There is no "admitted forever" spelling and that is deliberate.
    ## `hasNotAfter` is REQUIRED by `validateRoster`, so an operator
    ## cannot admit a key by leaving a field at its zero value — which
    ## is how key lifetime gets skipped in practice, not by anyone
    ## deciding it should be unbounded.
    ##
    ## Rotation is expressed by OVERLAP rather than by replacement: the
    ## successor's window opens before the predecessor's closes, so a
    ## bundle signed during the handover reaches the threshold under
    ## both rosters. Closing one window at the instant the next opens
    ## leaves anything in flight short.
    notBefore*: int64
    hasNotAfter*: bool
    notAfter*: int64
    revoked*: bool
    revokedAt*: int64
      ## The instant from which this key stops counting. See
      ## `RevocationHasNoSigningTimeCaveat` for what that can and
      ## cannot mean here.
    revocationReason*: string
      ## Required when `revoked`. A revocation with no reason is a
      ## decision nobody can review.

  AdmissionState* = enum
    saAdmitted = "admitted"
    saNotYetAdmitted = "not-yet-admitted"
    saAdmissionEnded = "admission-ended"
    saRevoked = "revoked"

  QuorumSigner* = object
    ## One admitted rebuilder, as the verifier's operator supplied it.
    ##
    ## There is no name field. A signer's identity IS its key
    ## identifier, so there is no second name for a policy and a roster
    ## to come to disagree about.
    key*: CoseKey
    admission*: SignerAdmission

  WitnessedLogRoot* = object
    ## A transparency-log root this verifier obtained from somewhere
    ## other than the document under test. Supplied by the caller and
    ## never read out of a bundle: a log that chose the root it is
    ## checked against has proved nothing.
    logId*: string
    treeSize*: int
    rootHash*: string          ## 64 lower-case hex characters

  QuorumEntryOutcome* = enum
    qeoCounted = "counted"
    qeoNotAnAdmittedSigner = "not-an-admitted-signer"
    qeoSignerNotYetAdmitted = "signer-not-yet-admitted"
    qeoSignerAdmissionEnded = "signer-admission-ended"
    qeoSignerRevoked = "signer-revoked"
    qeoAlreadyCounted = "already-counted"
    qeoMalformed = "malformed"
    qeoSignatureDidNotVerify = "signature-did-not-verify"
    qeoWrongClaim = "signed-a-different-claim"

  QuorumEntry* = object
    index*: int
    outcome*: QuorumEntryOutcome
    signer*: string            ## the kid, lower-case hex; empty if unread
    detail*: string

  QuorumEvaluation* = object
    caveats*: seq[string]
      ## What this evaluation could not establish. Carried out of here
      ## rather than composed by the caller, because the limits belong
      ## to the rule that has them.
    entries*: seq[QuorumEntry]
    countedSigners*: seq[string]
      ## Distinct kids that contributed, in the order first counted.
    defects*: seq[string]
      ## One sentence per entry whose failure is a document defect. A
      ## non-empty list rejects however many signatures were counted.

  InclusionEntryOutcome* = enum
    ieoVerified = "verified"
    ieoMalformed = "malformed"
    ieoNoWitnessedRoot = "no-witnessed-root-for-this-log"
    ieoTreeSizeNotWitnessed = "tree-size-not-the-witnessed-one"
    ieoRootMismatch = "recomputed-a-different-root"

  InclusionEntry* = object
    index*: int
    outcome*: InclusionEntryOutcome
    logId*: string
    detail*: string

  InclusionEvaluation* = object
    entries*: seq[InclusionEntry]
    verifiedLogs*: seq[string]
    defects*: seq[string]

  RosterError* = object of CatchableError
    ## Raised for a roster this build will not evaluate against. The
    ## reader is whoever configured the verifier.

const
  MaxRoster* = 64
    ## The admitted set is a page of decisions, like the pinned-manifest
    ## list beside it.

  DistinctSignerCaveat* =
    "the quorum counted distinct signing keys; nothing in a signature " &
    "says who holds the key, so one party holding several of the " &
    "admitted keys would satisfy this threshold alone"

  RevocationHasNoSigningTimeCaveat* =
    "a revocation here is evaluated at verification time; a quorum " &
    "signature carries no signing time, so nothing distinguishes a " &
    "signature made before a key was revoked from one made after, and " &
    "revoking a key therefore withdraws every bundle it contributed to"

  UnverifiedLogAgeCaveat* =
    "this verdict establishes that the claim is in a log whose root " &
    "this verifier already held; it establishes nothing about how long " &
    "it has been there, because a witnessed root carries no signed time"

proc hexOfKid(kid: openArray[byte]): string =
  ## A key identifier as lower-case hex, through the library's ONE hex
  ## writer. The conversion to a string is the whole of this procedure;
  ## the spelling itself is `binding`'s.
  var raw = newString(kid.len)
  for i in 0 ..< kid.len: raw[i] = char(kid[i])
  bytesToHex(raw)

proc signerNameOf*(key: CoseKey): string =
  ## The one spelling of a signer's identity: its key identifier, lower
  ## case hex. Written once so a policy, a roster and a verdict cannot
  ## come to disagree about how a signer is named.
  hexOfKid(key.kid)

proc validateRoster*(roster: openArray[QuorumSigner]) =
  ## Every rule a roster must satisfy before it is used to judge
  ## anything. Called by the evaluator, so a caller cannot skip it.
  if roster.len > MaxRoster:
    raise newException(RosterError,
      "the signer roster holds " & $roster.len & " keys and at most " &
      $MaxRoster & " are evaluated")
  var seen = initTable[string, int]()
  for i, s in roster:
    if s.key.kid.len == 0:
      raise newException(RosterError,
        "roster entry " & $i & " carries no key identifier; a signer " &
        "with no identity cannot be counted once")
    let name = signerNameOf(s.key)
    if seen.hasKey(name):
      raise newException(RosterError,
        "the signer roster carries the key identifier " & name &
        " twice, at entries " & $seen[name] & " and " & $i &
        "; two entries with one identity would be counted as one signer " &
        "or as two depending on which was reached first")
    seen[name] = i
    if not s.admission.hasNotAfter:
      raise newException(RosterError,
        "roster entry " & $i & " (" & name & ") states no end to its " &
        "admission; this build has no spelling for a key that is " &
        "admitted forever, because an unbounded key is what an " &
        "operator ends up with by leaving a field alone rather than " &
        "by deciding anything")
    if s.admission.notAfter <= s.admission.notBefore:
      raise newException(RosterError,
        "roster entry " & $i & " (" & name & ") is admitted from " &
        $s.admission.notBefore & " until " & $s.admission.notAfter &
        ", which is not a window; a key admitted for no time at all " &
        "would count for nothing at every instant and read as a key " &
        "that was never admitted")
    if s.admission.revoked:
      if s.admission.revocationReason.len == 0:
        raise newException(RosterError,
          "roster entry " & $i & " (" & name & ") is revoked with no " &
          "reason; a revocation nobody can review is a decision nobody " &
          "can undo either")
      if s.admission.revokedAt < s.admission.notBefore:
        raise newException(RosterError,
          "roster entry " & $i & " (" & name & ") is revoked at " &
          $s.admission.revokedAt & ", before its admission began at " &
          $s.admission.notBefore & "; a key revoked before it was " &
          "admitted was never admitted, and saying it twice invites " &
          "the two statements to disagree")

proc classifyAdmission*(a: SignerAdmission; nowSeconds: int64):
    AdmissionState =
  ## Whether a key counts at `nowSeconds`.
  ##
  ## Revocation is tested FIRST, and only once its instant has passed.
  ## A revoked key inside its window is revoked, which is the fact a
  ## reader needs; testing the window first would report a key whose
  ## holder lost control of it as merely "admitted".
  if a.revoked and nowSeconds >= a.revokedAt: return saRevoked
  if nowSeconds < a.notBefore: return saNotYetAdmitted
  if a.hasNotAfter and nowSeconds >= a.notAfter: return saAdmissionEnded
  saAdmitted

proc outcomeFor*(state: AdmissionState): QuorumEntryOutcome =
  ## The entry outcome an admission state produces. A total function
  ## over the enumeration, so a state added without a decision does not
  ## compile — and written here rather than inline in the evaluator,
  ## where the `saAdmitted` arm would have been unreachable and an
  ## unreachable arm is a rule with no input.
  case state
  of saAdmitted: qeoCounted
  of saNotYetAdmitted: qeoSignerNotYetAdmitted
  of saAdmissionEnded: qeoSignerAdmissionEnded
  of saRevoked: qeoSignerRevoked

proc admittedSigner*(key: CoseKey; notBefore, notAfter: int64):
    QuorumSigner =
  ## A roster entry with a stated window and no revocation. The one
  ## constructor, so a caller cannot produce an entry with a default
  ## admission and have it silently mean "forever".
  QuorumSigner(key: key, admission: SignerAdmission(
    notBefore: notBefore, hasNotAfter: true, notAfter: notAfter))

proc revoked*(signer: QuorumSigner; at: int64; reason: string):
    QuorumSigner =
  result = signer
  result.admission.revoked = true
  result.admission.revokedAt = at
  result.admission.revocationReason = reason

proc rosterNames*(roster: openArray[QuorumSigner]): seq[string] =
  for s in roster: result.add signerNameOf(s.key)
  result.sort()

proc quorumEntriesOf*(bundle: EdgeAttestationBundle): seq[int] =
  ## The indices of the entries a quorum is computed from.
  for i, a in bundle.attestations:
    if a.verifier == QuorumVerifierId: result.add i

proc inclusionEntriesOf*(bundle: EdgeAttestationBundle): seq[int] =
  for i, a in bundle.attestations:
    if a.verifier == TransparencyLogVerifierId: result.add i

proc unevaluatedVerifiers*(bundle: EdgeAttestationBundle): seq[string] =
  ## The verifier identifiers this build carries no evaluator for, in
  ## first-seen order.
  ##
  ## Reported rather than ignored. An attestation nobody looked at is
  ## the honest-absence shape: it makes a bundle look better attested
  ## than the verdict it produced, and a reader who is not told cannot
  ## know the difference.
  for a in bundle.attestations:
    if a.verifier notin KnownVerifierIds and a.verifier notin result:
      result.add a.verifier

# ---------------------------------------------------------------------
# The quorum
# ---------------------------------------------------------------------

proc evaluateQuorum*(bundle: EdgeAttestationBundle; claim: EdgeClaim;
                     roster: openArray[QuorumSigner];
                     nowSeconds: int64): QuorumEvaluation =
  ## Evaluate every ``signed-quorum.v1`` entry against the admitted set.
  ##
  ## ``claim`` is the claim the VERIFIER computed from the manifest it
  ## holds, never the bundle's own ``subject``. The statement each
  ## signature is checked against is derived from it here, so a bundle
  ## cannot choose what its signatures are compared to. That is the same
  ## rule the report verifier applies to a challenge, for the same
  ## reason.
  validateRoster(roster)
  for s in roster:
    if s.admission.revoked and nowSeconds >= s.admission.revokedAt:
      # Carried on every evaluation that applied a revocation, whatever
      # it concluded. A reader who is not told what a revocation here
      # does and does not establish cannot tell a withdrawn key from a
      # key that never signed.
      result.caveats.add RevocationHasNoSigningTimeCaveat
      break
  let statement = edgeStatementBytes(claim)
  var payload = newSeq[byte](statement.len)
  for i in 0 ..< statement.len: payload[i] = byte(statement[i])

  var keys: seq[CoseKey] = @[]
  for s in roster: keys.add s.key

  for idx in quorumEntriesOf(bundle):
    let at = "attestations[" & $idx & "]"
    var entry = QuorumEntry(index: idx)
    var raw = ""
    try:
      raw = hexToBytes(at & ".proof", bundle.attestations[idx].proof)
    except BindingError as err:
      entry.outcome = qeoMalformed
      entry.detail = at & " does not decode: " & err.msg
      result.entries.add entry
      result.defects.add entry.detail
      continue
    var message = newSeq[byte](raw.len)
    for i in 0 ..< raw.len: message[i] = byte(raw[i])

    var verified: CoseVerified
    var failure = ""
    var failureKind = cxeMalformedCbor
    var refused = false
    try:
      # The statement is DETACHED: the payload a signature covers is the
      # verifier's own bytes, so a bundle carrying its own copy of the
      # claim would be refused by `cxeDetachedPayloadUnexpected` rather
      # than judged against it.
      #
      # A CBOR-level refusal arrives here as a `CoseError` too: `cose`'s
      # own decoder converts every one of them, so there is no second
      # exception type a reader of this block has to know about.
      verified = verifyCoseSign1(message, keys,
                                 detachedPayload = payload,
                                 detachedPayloadSupplied = true)
    except CoseError as err:
      refused = true
      failure = err.msg
      failureKind = err.kind

    if refused and failureKind == cxeKeyNotFound:
      entry.outcome = qeoNotAnAdmittedSigner
      entry.detail = at & " is signed by a key identifier the policy " &
        "does not admit, so it contributes nothing: " & failure
      result.entries.add entry
      continue

    if refused:
      # Every other refusal is a defect in the document, and the two
      # that matter most are told apart by the REFUSAL'S OWN KIND rather
      # than by reading its prose, so rewording a message cannot move an
      # entry from one class into the other.
      entry.outcome =
        (if failureKind == cxeSignatureDidNotVerify: qeoSignatureDidNotVerify
         else: qeoMalformed)
      entry.detail = at &
        (if entry.outcome == qeoSignatureDidNotVerify:
           " carries a signature that does not verify under the key its " &
             "own key identifier names: "
         else: " is not a signature this build can read: ") & failure
      result.entries.add entry
      result.defects.add entry.detail
      continue

    # The payload was detached, so `verified.payload` is the statement
    # this verifier supplied. Compared anyway, because a future change to
    # the detachment discipline must not turn this rule off in silence.
    if verified.payload != payload:
      entry.outcome = qeoWrongClaim
      entry.detail = at & " verified over bytes other than the claim " &
        "this verifier is checking"
      result.entries.add entry
      result.defects.add entry.detail
      continue

    entry.signer = hexOfKid(verified.kid)

    # The signature verified under an admitted key's scalar. Whether
    # that key still counts is a separate question, asked here rather
    # than by withholding the key from the verifier above: filtering
    # the key set would have reported a lapsed or revoked signer as one
    # the policy never admitted, which is a different fact and sends
    # the reader somewhere else.
    #
    # None of these is a DEFECT. A lapsed or revoked signature beside a
    # bundle that reaches the threshold on other signers must not deny
    # it, for the same reason an unadmitted party's signature does not:
    # appending a signature to a published bundle would otherwise be a
    # denial of service.
    block admission:
      var state = saAdmitted
      var because = ""
      for s in roster:
        if signerNameOf(s.key) != entry.signer: continue
        state = classifyAdmission(s.admission, nowSeconds)
        because =
          case state
          of saAdmitted: ""
          of saNotYetAdmitted:
            " is admitted from " & $s.admission.notBefore & " and this " &
              "verdict is being reached at " & $nowSeconds
          of saAdmissionEnded:
            " stopped being admitted at " & $s.admission.notAfter &
              " and this verdict is being reached at " & $nowSeconds
          of saRevoked:
            " was revoked at " & $s.admission.revokedAt & ": " &
              s.admission.revocationReason
        break
      if state == saAdmitted: break admission
      entry.outcome = outcomeFor(state)
      entry.detail = at & " is signed by " & entry.signer & ", which" &
        because & ", so it contributes nothing"
      result.entries.add entry
      continue

    if entry.signer in result.countedSigners:
      entry.outcome = qeoAlreadyCounted
      entry.detail = at & " is a second signature by " & entry.signer &
        ", which has already been counted; a quorum counts signers, " &
        "not signatures"
      result.entries.add entry
      continue

    entry.outcome = qeoCounted
    entry.detail = at & " is a valid signature by " & entry.signer
    result.countedSigners.add entry.signer
    result.entries.add entry

# ---------------------------------------------------------------------
# Transparency-log inclusion
# ---------------------------------------------------------------------

proc evaluateInclusion*(bundle: EdgeAttestationBundle; claim: EdgeClaim;
                        witnessed: openArray[WitnessedLogRoot]):
                       InclusionEvaluation =
  ## Evaluate every ``transparency-log-inclusion.v1`` entry against the
  ## roots this verifier already holds.
  ##
  ## The leaf is computed here from ``claim``. A proof carries no leaf
  ## hash and no root, so the only two values it could use to steer the
  ## comparison are both supplied from outside it.
  let statement = edgeStatementBytes(claim)
  let leafHash = merkleLeafHash(statement)

  for idx in inclusionEntriesOf(bundle):
    let at = "attestations[" & $idx & "]"
    var entry = InclusionEntry(index: idx)
    var proof: LogInclusionProof
    var complaint = ""
    try:
      proof = parseLogInclusionProof(
        hexToBytes(at & ".proof", bundle.attestations[idx].proof), at)
    except BindingError as err:
      complaint = err.msg
    except EdgeAttestationError as err:
      complaint = err.msg
    if complaint.len > 0:
      entry.outcome = ieoMalformed
      entry.detail = at & " is not an inclusion proof this build reads: " &
        complaint
      result.entries.add entry
      result.defects.add entry.detail
      continue
    entry.logId = proof.logId

    var haveRoot = false
    var witnessedRoot: WitnessedLogRoot
    for w in witnessed:
      if w.logId == proof.logId:
        haveRoot = true
        witnessedRoot = w
        break
    if not haveRoot:
      entry.outcome = ieoNoWitnessedRoot
      entry.detail = at & " proves inclusion in the log " &
        proof.logId.escape() & ", and this verifier holds no witnessed " &
        "root for that log; an inclusion proof checked against a root " &
        "the same document supplied would establish nothing, so the " &
        "question cannot be asked here at all"
      result.entries.add entry
      result.defects.add entry.detail
      continue

    if proof.treeSize != witnessedRoot.treeSize:
      entry.outcome = ieoTreeSizeNotWitnessed
      entry.detail = at & " proves inclusion in a tree of " &
        $proof.treeSize & " entries and the witnessed root for " &
        proof.logId & " describes a tree of " & $witnessedRoot.treeSize &
        "; relating two tree sizes needs a consistency proof, which this " &
        "build neither carries nor evaluates"
      result.entries.add entry
      result.defects.add entry.detail
      continue

    var recomputed = ""
    try:
      recomputed = rootFromInclusionProof(leafHash, proof.leafIndex,
                                          proof.treeSize, proof.auditPath)
    except MerkleError as err:
      entry.outcome = ieoMalformed
      entry.detail = at & " does not evaluate: " & err.msg
      result.entries.add entry
      result.defects.add entry.detail
      continue

    if recomputed != witnessedRoot.rootHash:
      entry.outcome = ieoRootMismatch
      entry.detail = at & " recomputes the root " & recomputed &
        " and the witnessed root for " & proof.logId & " is " &
        witnessedRoot.rootHash & "; either this claim is not the one " &
        "that was logged, or it is in a different tree"
      result.entries.add entry
      result.defects.add entry.detail
      continue

    entry.outcome = ieoVerified
    entry.detail = at & " proves this claim is entry " & $proof.leafIndex &
      " of " & proof.logId & " at the tree of " & $proof.treeSize &
      " entries this verifier has witnessed"
    if proof.logId notin result.verifiedLogs:
      result.verifiedLogs.add proof.logId
    result.entries.add entry
