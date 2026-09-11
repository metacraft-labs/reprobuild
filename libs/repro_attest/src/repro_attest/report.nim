## The ``reproos.attestation-report.v1`` envelope.
##
## ## What the document is for
##
## An attested instance answers a challenge with one backend-neutral JSON
## object. The agent that produces it and the verifier that consumes it
## are different programs on different machines, often built from
## different checkouts, so the envelope is the whole of their agreement:
## what a report contains, what it means, and — the part a schema usually
## leaves to prose — what a reader is allowed to *believe*.
##
## The document is deliberately small. Almost nothing in it is a fact; it
## is a wrapper around one field that is.
##
## ## The three rules, and where each is enforced
##
## **1. ``evidence`` is the only authoritative field.** It is the
## backend-native quote or report the hardware signed. Everything else is
## either derived from it, checkable against it, or a convenience. The
## rule is enforced by shape rather than by prose: the decoder is called
## ``authoritativeEvidence``, and every convenience field lives in
## ``UnverifiedClaims``, whose fields are *named* ``unverified*`` — a
## compile-time assertion below keeps them so. A call site that reads a
## claim has to write the word.
##
## **2. Freshness comes from the challenge, never from the clock.**
## ``timestampInformational`` is exactly what its name says. This module
## offers no way to compare it to anything, and the parser will accept a
## timestamp in 1970 or in 3000 without complaint, because a report is not
## stale by virtue of its own claim about the time. What the parser *does*
## refuse is a challenge below 128 bits, and a ``reportData`` that is not
## the 64 bytes this report's own challenge and bindings produce. A report
## whose 64 bytes do not follow from what it says it bound is a report
## disagreeing with itself, and there is no safe half to believe.
##
## Note what that check is and is not: it proves the envelope is
## self-consistent with the binding discipline. It says nothing about
## whether the *hardware* signed those 64 bytes — that requires parsing
## ``evidence``, which is the verifier's work, not the schema's.
##
## **3. ``certificates`` may be omitted, and is never trusted standalone.**
## Omission is normal: a verifier that fetches vendor collateral itself
## does not need the instance's copy, and preferring its own is the safer
## posture. So the field is genuinely optional here — and present-but-empty
## is refused, because a chain of nothing is an omission spelled in a way
## that could be mistaken for a chain. The accessor is
## ``certificatesForCrossCheck``: bundled certificates are material to
## compare against an authoritative distribution point, not a chain to
## trust because it arrived.
##
## ## Why parsing is strict
##
## Same reason the measurement manifest's is. Unknown fields, absent
## fields, wrong-typed fields, an unknown tier or backend or purpose, a
## backend that does not belong to the tier that names it — every one is a
## refusal. A report is read by something that is about to decide whether
## to hand over a secret; the failure mode of a lenient parser is
## believing something the instance did not say.
##
## ## Mocking
##
## None.

import std/[base64, json, options, strutils]

import ./binding
import ./manifest

export binding

type
  AttestationTier* = enum
    ## What kind of root of trust produced the evidence.
    atCvm = "cvm"
      ## A confidential-computing guest: the CPU vendor's root signs a
      ## launch measurement of the whole guest.
    atTpm = "tpm"
      ## Measured boot: a discrete or virtual TPM signs the registers the
      ## firmware and the stub extended.
    atMock = "mock"
      ## No root of trust at all. Useful for development and for testing
      ## a verifier's refusals; a production policy must refuse it.

  AttestationBackend* = enum
    ## The driver that produced the evidence.
    abSevSnp = "sev-snp"
    abTdx = "tdx"
    abTpm2 = "tpm2"
    abMock = "mock"

  UnverifiedClaims* = object
    ## **Not authoritative.** These are the instance's own statements
    ## about itself, carried so that a log is readable and a verifier can
    ## cheaply pre-check before doing expensive work. A verdict derived
    ## from any of them is a verdict an attacker writes.
    ##
    ## Every field is named ``unverified*`` and a ``static`` assertion
    ## below enforces it, so the word appears at each call site rather
    ## than only in this comment.
    unverifiedGeneration*: string
    unverifiedConfigFingerprint*: string
    unverifiedVerityRootHash*: string

  AttestationReport* = object
    tier*: AttestationTier
    backend*: AttestationBackend
    timestampInformational*: string
      ## RFC 3339, and informational only. Named for what it is: nothing
      ## in this library compares it to a clock, and nothing downstream
      ## may derive freshness from it.
    challenge*: string
      ## The verifier-supplied nonce, lower-case hex. The sole source of
      ## freshness.
    reportData*: string
      ## The exact 64 bytes bound into the quote, as 128 lower-case hex
      ## characters. Always equal to what ``challenge`` and ``bindings``
      ## produce under the binding discipline; the parser refuses a
      ## report where it is not.
    bindings*: ReportBindings
    evidence*: string
      ## The backend-native quote, report, or TPM quote plus event log,
      ## base64. **The only authoritative field.** Read it through
      ## ``authoritativeEvidence``.
    certificates*: Option[seq[string]]
      ## The backend-native chain, base64 DER per element, when the
      ## instance bundled one. Read it through
      ## ``certificatesForCrossCheck``.
    claims*: UnverifiedClaims

  ReportError* = object of CatchableError
    ## Raised for any envelope this module will not honour.

static:
  # Rule 1, made mechanical. If a future field of `UnverifiedClaims` is
  # named without the prefix, this build stops rather than shipping a
  # convenience that reads like a fact.
  var probe: UnverifiedClaims
  for name, _ in probe.fieldPairs:
    doAssert name.startsWith("unverified"),
      "UnverifiedClaims." & name & " must be named \"unverified...\": a " &
      "claim a call site can read without saying so is a claim someone " &
      "will eventually trust"

const
  AttestationReportSchema* = "reproos.attestation-report.v1"

  TopLevelRequired*: array[9, string] = [
    "schema", "tier", "backend", "timestamp", "challenge", "reportData",
    "bindings", "evidence", "claims"]

  TopLevelOptional*: array[1, string] = ["certificates"]
    ## The complete set of optional keys, and it has one member. Every
    ## other absence is a refusal.

  BindingKeysAttest*: array[1, string] = ["purpose"]
  BindingKeysKeyAgreement*: array[2, string] = ["purpose", "ephemeralPub"]
  ClaimKeys*: array[3, string] =
    ["generation", "configFingerprint", "verityRootHash"]

  MaxEvidenceBase64* = 1_048_576
    ## A document bound, not a transport bound. A signed SNP report is
    ## about 1.2 KiB and a TPM quote with its event log is tens of KiB, so
    ## a mebibyte of base64 is generous by two orders of magnitude while
    ## still refusing a report that is really a payload. Request-size
    ## limits on a listening socket are a separate, additional concern.

  MaxCertificates* = 16
  MaxCertificateBase64* = 65_536
  MaxClaimTokenLen* = 256

  Base64Alphabet = {'A' .. 'Z', 'a' .. 'z', '0' .. '9', '+', '/'}

# ---------------------------------------------------------------------
# Tier and backend
# ---------------------------------------------------------------------

proc backendsOfTier*(tier: AttestationTier): seq[AttestationBackend] =
  ## Which drivers a tier can possibly have used. A report naming a
  ## backend outside its tier is refused: the tier is what a policy is
  ## written against, so a report that could raise its own tier by
  ## renaming its backend would make every policy advisory.
  case tier
  of atCvm: @[abSevSnp, abTdx]
  of atTpm: @[abTpm2]
  of atMock: @[abMock]

proc tierOf*(backend: AttestationBackend): AttestationTier =
  case backend
  of abSevSnp, abTdx: atCvm
  of abTpm2: atTpm
  of abMock: atMock

proc manifestBackendKey*(backend: AttestationBackend): string =
  ## The ``expected.<key>`` in a measurement manifest that this report's
  ## backend is verified against.
  ##
  ## The two documents do not spell the TPM backend the same way — a
  ## report names the driver (``tpm2``), a manifest names the launch-
  ## measurement shape (``tpm``) — so the mapping is written down once,
  ## here, rather than being re-derived by string equality at each use.
  ## The mock backend takes no launch measurement and has no key; it
  ## answers with the empty string.
  case backend
  of abSevSnp: BackendSevSnp
  of abTdx: BackendTdx
  of abTpm2: BackendTpm
  of abMock: ""

proc parseTier*(where, s: string): AttestationTier =
  for t in AttestationTier:
    if $t == s: return t
  var known: seq[string] = @[]
  for t in AttestationTier: known.add $t
  raise newException(ReportError,
    where & " is " & s.escapeJson() & "; this build understands the tiers " &
    known.join(", ") & " and refuses one it cannot honour")

proc parseBackend*(where, s: string): AttestationBackend =
  for b in AttestationBackend:
    if $b == s: return b
  var known: seq[string] = @[]
  for b in AttestationBackend: known.add $b
  raise newException(ReportError,
    where & " is " & s.escapeJson() & "; this build understands the " &
    "backends " & known.join(", ") &
    " and refuses one it cannot honour")

# ---------------------------------------------------------------------
# Scalar shapes
# ---------------------------------------------------------------------

proc isSafeToken(s: string; maxLen: int): bool =
  if s.len == 0 or s.len > maxLen: return false
  for c in s:
    if c notin {'0' .. '9', 'a' .. 'z', 'A' .. 'Z', '.', '_', '-', ':',
                '+', '/', '=', ';', ',', '@'}:
      return false
  true

proc isCanonicalBase64(s: string): bool =
  ## Base64 with correct padding, and *canonical*: re-encoding what it
  ## decodes to must reproduce it. Two spellings of the same bytes would
  ## let one report be two documents, and the trailing bits of a padded
  ## group are exactly where that hides.
  if s.len == 0 or s.len mod 4 != 0: return false
  var pad = 0
  while pad < 2 and s.len - pad - 1 >= 0 and s[s.len - pad - 1] == '=':
    inc pad
  for i in 0 ..< s.len - pad:
    if s[i] notin Base64Alphabet: return false
  var decoded: string
  try:
    decoded = base64.decode(s)
  except CatchableError:
    return false
  if decoded.len == 0: return false
  base64.encode(decoded) == s

proc digitsAt(s: string; at, n: int): bool =
  if at + n > s.len: return false
  for i in at ..< at + n:
    if s[i] notin {'0' .. '9'}: return false
  true

proc twoDigit(s: string; at: int): int =
  (ord(s[at]) - ord('0')) * 10 + (ord(s[at + 1]) - ord('0'))

proc isRfc3339*(s: string): bool =
  ## ``YYYY-MM-DDTHH:MM:SS[.fraction](Z|±HH:MM)``, with the separator and
  ## the zulu marker upper-case so one instant has one spelling.
  ##
  ## The shape is checked; the value is not interpreted. That is the
  ## point: this module never turns a timestamp into a moment, because a
  ## moment is a thing something could be tempted to compare.
  if s.len < 20: return false
  if not digitsAt(s, 0, 4): return false
  if s[4] != '-' or not digitsAt(s, 5, 2): return false
  if s[7] != '-' or not digitsAt(s, 8, 2): return false
  if s[10] != 'T': return false
  if not digitsAt(s, 11, 2): return false
  if s[13] != ':' or not digitsAt(s, 14, 2): return false
  if s[16] != ':' or not digitsAt(s, 17, 2): return false
  let month = twoDigit(s, 5)
  let day = twoDigit(s, 8)
  let hour = twoDigit(s, 11)
  let minute = twoDigit(s, 14)
  let second = twoDigit(s, 17)
  if month < 1 or month > 12: return false
  if day < 1 or day > 31: return false
  if hour > 23 or minute > 59 or second > 60: return false
  var i = 19
  if i < s.len and s[i] == '.':
    inc i
    let start = i
    while i < s.len and s[i] in {'0' .. '9'}: inc i
    if i == start or i - start > 9: return false
  if i >= s.len: return false
  if s[i] == 'Z':
    return i == s.len - 1
  if s[i] notin {'+', '-'}: return false
  if i + 6 != s.len: return false
  if not digitsAt(s, i + 1, 2): return false
  if s[i + 3] != ':' or not digitsAt(s, i + 4, 2): return false
  twoDigit(s, i + 1) <= 23 and twoDigit(s, i + 4) <= 59

# ---------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------

proc validateUnverifiedClaims*(c: UnverifiedClaims) =
  ## The claim fields' shapes, on their own.
  ##
  ## Extracted from ``validateAttestationReport`` — which calls it, so
  ## there is still exactly one implementation — because an agent has to
  ## check the identity it was configured with at start-up, and a daemon
  ## that discovers its configuration is unusable on the first request
  ## has already been running for hours by the time anyone finds out.
  if not isSafeToken(c.unverifiedGeneration, MaxClaimTokenLen):
    raise newException(ReportError,
      "claims.generation must be a non-empty token of at most " &
      $MaxClaimTokenLen & " characters from [0-9A-Za-z._:;,+/=@-], got " &
      c.unverifiedGeneration.escapeJson())
  if not isSafeToken(c.unverifiedConfigFingerprint, MaxClaimTokenLen):
    raise newException(ReportError,
      "claims.configFingerprint must be a non-empty token of at most " &
      $MaxClaimTokenLen & " characters from [0-9A-Za-z._:;,+/=@-], got " &
      c.unverifiedConfigFingerprint.escapeJson())
  if c.unverifiedVerityRootHash.len != 64 or
     not isLowerHex(c.unverifiedVerityRootHash):
    raise newException(ReportError,
      "claims.verityRootHash must be 64 lower-case hex characters — the " &
      "same spelling a measurement manifest uses, so the cheap pre-check " &
      "is a string comparison — got " &
      c.unverifiedVerityRootHash.escapeJson())

proc validateAttestationReport*(r: AttestationReport) =
  ## The single validator. The renderer runs it before it writes and the
  ## parser runs it after it reads, so a report cannot become acceptable
  ## by the route it travelled.
  if r.backend notin backendsOfTier(r.tier):
    var allowed: seq[string] = @[]
    for b in backendsOfTier(r.tier): allowed.add $b
    raise newException(ReportError,
      "backend " & ($r.backend).escapeJson() & " does not belong to tier " &
      ($r.tier).escapeJson() & ", which is served by " & allowed.join(", ") &
      "; a report that could raise its own tier by renaming its backend " &
      "would make every policy advisory")

  if not isRfc3339(r.timestampInformational):
    raise newException(ReportError,
      "timestamp must be RFC 3339 (YYYY-MM-DDTHH:MM:SS[.f](Z|+HH:MM)), got " &
      r.timestampInformational.escapeJson())

  # The discipline's own refusals are raised as `ReportError` here, so an
  # envelope has exactly one error type escaping it however it was built.
  try:
    validateChallengeHex(r.challenge)
    validateBindings(r.bindings)
  except BindingError as err:
    raise newException(ReportError, err.msg)

  if r.reportData.len != ReportDataHexLen or not isLowerHex(r.reportData):
    raise newException(ReportError,
      "reportData must be " & $ReportDataHexLen &
      " lower-case hex characters (" & $ReportDataSize & " bytes), got " &
      r.reportData.escapeJson())

  let expected = reportDataHexFor(r.bindings, r.challenge)
  if r.reportData != expected:
    raise newException(ReportError,
      "reportData is " & r.reportData & " but this report's own challenge " &
      "and bindings produce " & expected &
      "; a report that disagrees with itself about what it bound is refused")

  if r.evidence.len == 0:
    raise newException(ReportError,
      "evidence is empty; it is the only authoritative field a report has, " &
      "so a report without it is not a weaker report, it is not a report")
  if r.evidence.len > MaxEvidenceBase64:
    raise newException(ReportError,
      "evidence is " & $r.evidence.len & " base64 characters; at most " &
      $MaxEvidenceBase64 & " are carried")
  if not isCanonicalBase64(r.evidence):
    raise newException(ReportError,
      "evidence must be canonical base64; it is the field a verdict rests " &
      "on and it has to decode to exactly one thing")

  if r.certificates.isSome:
    let chain = r.certificates.get
    if chain.len == 0:
      raise newException(ReportError,
        "certificates is present and empty; omit the field when no chain " &
        "is bundled, so that \"fetch your own collateral\" cannot be " &
        "mistaken for \"here is a chain\"")
    if chain.len > MaxCertificates:
      raise newException(ReportError,
        "certificates carries " & $chain.len & " elements; at most " &
        $MaxCertificates & " are accepted")
    for i, cert in chain:
      if cert.len > MaxCertificateBase64:
        raise newException(ReportError,
          "certificates[" & $i & "] is " & $cert.len &
          " base64 characters; at most " & $MaxCertificateBase64 & " are accepted")
      if not isCanonicalBase64(cert):
        raise newException(ReportError,
          "certificates[" & $i & "] must be canonical base64")

  validateUnverifiedClaims(r.claims)

# ---------------------------------------------------------------------
# Reading a report, with the trust rules in the names
# ---------------------------------------------------------------------

proc authoritativeEvidence*(r: AttestationReport): string =
  ## The backend-native evidence, decoded. This is the only field of a
  ## report from which a verdict may be derived; everything else is
  ## either checkable against it or a convenience.
  base64.decode(r.evidence)

proc hasBundledCertificates*(r: AttestationReport): bool =
  r.certificates.isSome

proc certificatesForCrossCheck*(r: AttestationReport): seq[string] =
  ## The bundled chain, decoded, or nothing when none was bundled.
  ##
  ## Named for the only correct use: comparing against what an
  ## authoritative distribution point serves. A chain that arrives with
  ## the thing it vouches for vouches for nothing.
  if r.certificates.isNone: return @[]
  for cert in r.certificates.get:
    result.add base64.decode(cert)

proc bindsChallenge*(r: AttestationReport; expectedChallengeHex: string): bool =
  ## Whether this report answers *that* challenge.
  ##
  ## This — not the timestamp — is what makes a report fresh. A verifier
  ## that issued ``expectedChallengeHex`` and gets true here knows the
  ## envelope is the answer to it; whether the hardware signed those bytes
  ## is the separate question that reading the evidence answers.
  if not isLowerHex(expectedChallengeHex): return false
  # The `and` short-circuits, so the recomputation only ever runs on a
  # challenge equal to one the report already carries — which is a
  # validated report's challenge, and therefore one the discipline accepts.
  r.challenge == expectedChallengeHex and
    r.reportData == reportDataHexFor(r.bindings, expectedChallengeHex)

# ---------------------------------------------------------------------
# Construction
# ---------------------------------------------------------------------

proc attestationReport*(backend: AttestationBackend;
                        timestamp, challengeHex: string;
                        bindings: ReportBindings;
                        evidence: string;
                        claims: UnverifiedClaims;
                        certificates: Option[seq[string]] =
                          none(seq[string])): AttestationReport =
  ## Build a report from one backend's raw evidence bytes.
  ##
  ## The tier follows from the backend and the 64 bytes are computed here,
  ## so a driver cannot report a binding it did not perform, or place
  ## itself in a tier it does not belong to, by filling in a field.
  ## ``evidence`` and each element of ``certificates`` are RAW bytes; the
  ## base64 is this function's business.
  # The discipline's refusals become `ReportError` here for the same
  # reason they do in the validator: one error type escapes an envelope,
  # however it was built.
  let bound = try:
      reportDataHexFor(bindings, challengeHex)
    except BindingError as err:
      raise newException(ReportError, err.msg)
  result = AttestationReport(
    tier: tierOf(backend),
    backend: backend,
    timestampInformational: timestamp,
    challenge: challengeHex,
    reportData: bound,
    bindings: bindings,
    evidence: base64.encode(evidence),
    claims: claims)
  if certificates.isSome:
    var encoded: seq[string] = @[]
    for cert in certificates.get: encoded.add base64.encode(cert)
    result.certificates = some(encoded)
  validateAttestationReport(result)

# ---------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------

proc renderAttestationReport*(r: AttestationReport): string =
  ## The canonical bytes: a fixed key order and a fixed indent, so the
  ## same report is the same document wherever it was assembled. Written
  ## by hand rather than by a serializer so the bytes do not move with a
  ## compiler version; every scalar is confined to a checked character set
  ## on the way in, which is what makes that safe.
  validateAttestationReport(r)
  proc q(s: string): string = "\"" & s & "\""
  result = "{\n"
  result.add "  \"schema\": " & q(AttestationReportSchema) & ",\n"
  result.add "  \"tier\": " & q($r.tier) & ",\n"
  result.add "  \"backend\": " & q($r.backend) & ",\n"
  result.add "  \"timestamp\": " & q(r.timestampInformational) & ",\n"
  result.add "  \"challenge\": " & q(r.challenge) & ",\n"
  result.add "  \"reportData\": " & q(r.reportData) & ",\n"
  result.add "  \"bindings\": {\n"
  result.add "    \"purpose\": " & q($r.bindings.purpose)
  if r.bindings.ephemeralPub.len > 0:
    result.add ",\n    \"ephemeralPub\": " & q(r.bindings.ephemeralPub)
  result.add "\n  },\n"
  result.add "  \"evidence\": " & q(r.evidence) & ",\n"
  if r.certificates.isSome:
    result.add "  \"certificates\": [\n"
    for i, cert in r.certificates.get:
      result.add "    " & q(cert) & (if i == r.certificates.get.high: "\n"
                                     else: ",\n")
    result.add "  ],\n"
  result.add "  \"claims\": {\n"
  result.add "    \"generation\": " & q(r.claims.unverifiedGeneration) & ",\n"
  result.add "    \"configFingerprint\": " &
    q(r.claims.unverifiedConfigFingerprint) & ",\n"
  result.add "    \"verityRootHash\": " &
    q(r.claims.unverifiedVerityRootHash) & "\n"
  result.add "  }\n"
  result.add "}\n"

# ---------------------------------------------------------------------
# Parsing
# ---------------------------------------------------------------------

proc requireObject(node: JsonNode; where: string): JsonNode =
  if node.kind != JObject:
    raise newException(ReportError, where & " must be a JSON object")
  node

proc requireKeys(node: JsonNode; where: string;
                 required: openArray[string];
                 optional: openArray[string]) =
  for key in node.keys:
    if key notin required and key notin optional:
      raise newException(ReportError,
        where & " carries the unknown field " & key.escapeJson() &
        "; this build understands " & required.join(", ") &
        (if optional.len > 0: " and the optional " & optional.join(", ")
         else: "") &
        ", and refuses a document it cannot fully honour")
  for key in required:
    if not node.hasKey(key):
      raise newException(ReportError,
        where & " is missing the required field " & key.escapeJson())

proc str(node: JsonNode; where, key: string): string =
  let v = node[key]
  if v.kind != JString:
    raise newException(ReportError, where & "." & key & " must be a string")
  v.getStr

proc parseAttestationReport*(text, source: string): AttestationReport =
  ## Parse and fully validate a report. ``source`` names the document in
  ## every message, because these errors are read by whoever has to
  ## explain why an instance was not believed.
  var doc: JsonNode
  try:
    doc = parseJson(text)
  except CatchableError as err:
    raise newException(ReportError, source & ": not JSON: " & err.msg)
  discard requireObject(doc, source)
  requireKeys(doc, source, TopLevelRequired, TopLevelOptional)

  let schema = str(doc, source, "schema")
  if schema != AttestationReportSchema:
    raise newException(ReportError,
      source & ": schema is " & schema.escapeJson() & "; this build " &
      "understands " & AttestationReportSchema.escapeJson() &
      " and refuses a document it cannot fully honour")

  result.tier = parseTier(source & ".tier", str(doc, source, "tier"))
  result.backend = parseBackend(source & ".backend", str(doc, source, "backend"))
  result.timestampInformational = str(doc, source, "timestamp")
  result.challenge = str(doc, source, "challenge")
  result.reportData = str(doc, source, "reportData")
  result.evidence = str(doc, source, "evidence")

  let bindings = requireObject(doc["bindings"], source & ".bindings")
  if not bindings.hasKey("purpose"):
    raise newException(ReportError,
      source & ".bindings is missing the required field \"purpose\"")
  let purpose = try:
      parseBindingPurpose(source & ".bindings.purpose",
                          str(bindings, source & ".bindings", "purpose"))
    except BindingError as err:
      raise newException(ReportError, err.msg)
  # Which keys are required depends on the purpose, which is the coupling
  # itself: an ephemeral key is not an optional extra, it is required by
  # one purpose and forbidden by the other.
  case purpose
  of bpAttest:
    requireKeys(bindings, source & ".bindings", BindingKeysAttest, [])
    result.bindings = ReportBindings(purpose: purpose, ephemeralPub: "")
  of bpKeyAgreement:
    requireKeys(bindings, source & ".bindings", BindingKeysKeyAgreement, [])
    result.bindings = ReportBindings(purpose: purpose,
      ephemeralPub: str(bindings, source & ".bindings", "ephemeralPub"))

  if doc.hasKey("certificates"):
    if doc["certificates"].kind != JArray:
      raise newException(ReportError,
        source & ".certificates must be an array of base64 certificates")
    var chain: seq[string] = @[]
    for i, cert in doc["certificates"].elems:
      if cert.kind != JString:
        raise newException(ReportError,
          source & ".certificates[" & $i & "] must be a string")
      chain.add cert.getStr
    result.certificates = some(chain)

  let claims = requireObject(doc["claims"], source & ".claims")
  requireKeys(claims, source & ".claims", ClaimKeys, [])
  result.claims = UnverifiedClaims(
    unverifiedGeneration: str(claims, source & ".claims", "generation"),
    unverifiedConfigFingerprint:
      str(claims, source & ".claims", "configFingerprint"),
    unverifiedVerityRootHash:
      str(claims, source & ".claims", "verityRootHash"))

  try:
    validateAttestationReport(result)
  except ReportError as err:
    raise newException(ReportError, source & ": " & err.msg)
  except BindingError as err:
    raise newException(ReportError, source & ": " & err.msg)
