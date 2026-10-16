## The ``reproos.inference-statement.v1`` document: what an agent claims
## about one inference, and the exact bytes it signs to claim it.
##
## ## What the document is for
##
## An answer from a model is a file. Nothing about the bytes says which
## agent asked, under which configuration, from which model, on which
## machine, against which policy, or whether the question it answers is
## the question that was asked. A statement is the assertion that binds
## all of those to one another, so that a reader who trusts the signer
## can conclude something narrower and more useful than "this text
## exists".
##
## This module carries the transport and the canonical bytes, and only
## those. It holds no key, performs no signature, verifies nothing and
## decides nothing. **Nothing in this file makes a statement true.**
##
## ## The eleven bound fields, and why a statement is worthless without
## all of them
##
## The fields are an enum, ``InferenceField``, and the signed bytes are
## produced by walking it. That is not a stylistic choice: it is what
## makes "every field is bound" a property of the code rather than a
## claim in a comment. A field added to the enum is in the preimage the
## moment it compiles, and ``fieldOf``'s ``case`` is exhaustive, so a
## field added without a value fails to *build* rather than being bound
## to the empty string in silence.
##
## Each field is there because dropping it admits a specific
## substitution, and the header says which:
##
##   * ``agent`` — without it, any program's output is this agent's.
##   * ``agentConfig`` — without it, an agent run with its safety
##     configuration removed produces statements indistinguishable from
##     one run with it.
##   * ``model`` — without it, a cheap model's answer is a expensive
##     model's answer.
##   * ``inferenceServer`` — without it, a serving stack with a
##     different sampler, a different quantisation or a different
##     tokenizer is the same statement. The weights are not the whole of
##     what produces an answer.
##   * ``systemGeneration`` — the ``sha256:`` digest of the measurement
##     manifest identifying the machine's system generation, spelled the
##     same way a policy's ``measurements.manifests`` and an edge
##     attestation's claim spell it. Without it, an answer computed on an
##     unattested machine is an answer computed on an attested one.
##   * ``policy`` — the digest of the attestation policy in force.
##     Without it, a statement produced under a permissive policy reads
##     as one produced under a strict one.
##   * ``request`` / ``response`` — commitments, never plaintext. See
##     ``repro_attest/commitment``. Without them the statement is about
##     no particular exchange at all, which is the degenerate case every
##     other field is there to sharpen.
##   * ``nonce`` — the verifier's own challenge, under the same floor the
##     hardware binding discipline applies to one. Without it every
##     statement is replayable for ever.
##   * ``timestamp`` — when the signer says it signed. Weaker than the
##     nonce and not a substitute for it: a signer choosing its own clock
##     value is a claim, not evidence.
##   * ``certificate`` — the ``sha256:`` digest of the signer's leaf
##     certificate DER. Without it a statement is bound to a *key* and
##     not to the identity a chain certifies that key as, so a key that
##     appears under two certificates carries whichever one the presenter
##     chooses.
##
## ## The certificate field is a binding, NOT a validity check
##
## Worth stating in the negative, because the opposite is the natural
## assumption. This field binds *which certificate* the signer says it is
## speaking as, and the verifier's job is to check that the certificate
## it actually evaluated is that one. It establishes nothing about when
## that certificate is valid: the COSE key material in this library
## carries no validity period, and adding one is a change with its own
## rules and its own gates, not a consequence of this field existing.
##
## ## Why every field is length-prefixed, and its NAME with it
##
## The same hazard ``binding`` records, worse. Eleven adjacent
## variable-length strings concatenated without framing collide trivially:
## ``(agent = "ab", model = "c")`` and ``(agent = "a", model = "bc")``
## produce identical bytes, so a signature over one is a signature over
## the other. With eleven fields there are many more such re-splittings
## than there are fields.
##
## Both the field NAME and the field VALUE are framed, and the name is
## included at all so that a future reordering of the enum cannot make
## two different statements share a preimage either. The prefix is
## ``binding``'s ``be32Prefix`` — one implementation of "where does this
## field end" for the whole library.
##
## ## Mocking
##
## None.

import std/[json, strutils]

import ./binding
import ./manifest
import ./measurement

type
  InferenceField* = enum
    ## Every field the signature covers, in the order the preimage walks
    ## them and the order the document writes them.
    ##
    ## The string value is both the JSON key and the name framed into the
    ## preimage. One spelling, so a document and the bytes signed over it
    ## cannot come to disagree about what a field is called.
    ifAgent = "agent"
    ifAgentConfig = "agentConfig"
    ifModel = "model"
    ifInferenceServer = "inferenceServer"
    ifSystemGeneration = "systemGeneration"
    ifPolicy = "policy"
    ifRequestCommitment = "request"
    ifResponseCommitment = "response"
    ifNonce = "nonce"
    ifTimestamp = "timestamp"
    ifCertificate = "certificate"

  InferenceStatement* = object
    ## One inference, as its agent describes it. Every member is bound;
    ## see ``fieldOf``.
    agent*: string
    agentConfig*: string
    model*: string
    inferenceServer*: string
    systemGeneration*: string
    policy*: string
    requestCommitment*: string
    responseCommitment*: string
    nonce*: string
    timestamp*: string
    certificate*: string

  InferenceStatementError* = object of CatchableError
    ## Raised for a document this module will not honour. Its reader is
    ## whoever has to regenerate the document.

const
  InferenceStatementSchema* = "reproos.inference-statement.v1"

  InferenceStatementDomainTag* = "ReproOS-INF-STATEMENT-v1"
    ## First in the preimage and versioned. A future construction is a
    ## new tag, never a new reading of this one. It is also what stops a
    ## statement's bytes from being read as some other framed document in
    ## this library that happens to share a field layout.

  InferenceAuditRecordSchema* = "reproos.inference-audit-record.v1"

  MaxInferenceStatementBytes* = 65_536
  MaxFieldLen* = 512
    ## Every field here is a digest, a nonce or a timestamp. None of them
    ## is a payload, and the ceiling says so.

proc inferenceStatementKeys*(): seq[string] =
  ## The JSON keys a statement document carries, derived from the enum
  ## rather than transcribed beside it. A field added to the enum is a
  ## required key in the parser immediately; there is no second list to
  ## forget.
  result = @["schema"]
  for f in InferenceField: result.add $f

proc fieldOf*(s: InferenceStatement; f: InferenceField): string =
  ## The value of one bound field.
  ##
  ## The ``case`` is exhaustive on purpose. A member added to
  ## ``InferenceField`` with no arm here fails to compile, naming the
  ## missing member — which is the difference between a new field being
  ## bound and a new field being silently bound to "".
  case f
  of ifAgent: s.agent
  of ifAgentConfig: s.agentConfig
  of ifModel: s.model
  of ifInferenceServer: s.inferenceServer
  of ifSystemGeneration: s.systemGeneration
  of ifPolicy: s.policy
  of ifRequestCommitment: s.requestCommitment
  of ifResponseCommitment: s.responseCommitment
  of ifNonce: s.nonce
  of ifTimestamp: s.timestamp
  of ifCertificate: s.certificate

proc withField*(s: InferenceStatement; f: InferenceField;
                value: string): InferenceStatement =
  ## The same statement with one field replaced.
  ##
  ## Exists so a caller that walks the enum — a mutation table, an audit
  ## renderer — can change exactly one axis without a transcribed list of
  ## its own. The ``case`` is exhaustive for the same reason ``fieldOf``'s
  ## is.
  result = s
  case f
  of ifAgent: result.agent = value
  of ifAgentConfig: result.agentConfig = value
  of ifModel: result.model = value
  of ifInferenceServer: result.inferenceServer = value
  of ifSystemGeneration: result.systemGeneration = value
  of ifPolicy: result.policy = value
  of ifRequestCommitment: result.requestCommitment = value
  of ifResponseCommitment: result.responseCommitment = value
  of ifNonce: result.nonce = value
  of ifTimestamp: result.timestamp = value
  of ifCertificate: result.certificate = value

# ---------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------

proc fail(msg: string) {.noreturn.} =
  raise newException(InferenceStatementError, msg)

proc isLowerHexOf(s: string; want: int): bool =
  if want > 0 and s.len != want: return false
  if s.len == 0 or (s.len and 1) == 1: return false
  for c in s:
    if c notin {'0' .. '9', 'a' .. 'f'}: return false
  true

proc requireDigest(where, value: string) =
  if not value.startsWith(DigestPrefix) or
     not isLowerHexOf(value[DigestPrefix.len .. ^1], 64):
    fail(where & " must be \"" & DigestPrefix &
      "<64 lower-case hex characters>\", got " & value.escapeJson())

proc requireTimestamp(where, value: string) =
  ## ``YYYY-MM-DDTHH:MM:SSZ``, and nothing else.
  ##
  ## One spelling, UTC only, no offsets and no fractional seconds: a
  ## timestamp with two spellings is two preimages for one instant, and
  ## a signature over one of them is not a signature over the other.
  if value.len != 20:
    fail(where & " must be an RFC 3339 UTC timestamp spelled " &
      "YYYY-MM-DDTHH:MM:SSZ, got " & value.escapeJson())
  for i, c in value:
    let ok =
      case i
      of 4, 7: c == '-'
      of 10: c == 'T'
      of 13, 16: c == ':'
      of 19: c == 'Z'
      else: c in {'0' .. '9'}
    if not ok:
      fail(where & " must be an RFC 3339 UTC timestamp spelled " &
        "YYYY-MM-DDTHH:MM:SSZ, got " & value.escapeJson())

proc daysFromCivil(y, m, d: int): int64 =
  ## Howard Hinnant's civil-to-days, which is exact for every date this
  ## will ever see. Written out rather than taken from ``std/times``
  ## because ``times`` parses a *format* and this module validated the
  ## format already; what is wanted here is only the arithmetic.
  var yy = y
  if m <= 2: yy.dec
  let era = (if yy >= 0: yy else: yy - 399) div 400
  let yoe = yy - era * 400
  let mp = (m + 9) mod 12
  let doy = (153 * mp + 2) div 5 + d - 1
  let doe = yoe * 365 + yoe div 4 - yoe div 100 + doy
  int64(era) * 146_097 + int64(doe) - 719_468

proc timestampSeconds*(value: string): int64 =
  ## Unix seconds for a timestamp this module has already validated.
  ##
  ## Range-checks the components too: ``requireTimestamp`` establishes the
  ## SHAPE, and a shape check accepts month 19 quite happily.
  requireTimestamp("timestamp", value)
  let
    year = parseInt(value[0 .. 3])
    month = parseInt(value[5 .. 6])
    day = parseInt(value[8 .. 9])
    hour = parseInt(value[11 .. 12])
    minute = parseInt(value[14 .. 15])
    second = parseInt(value[17 .. 18])
  if month < 1 or month > 12 or day < 1 or day > 31 or
     hour > 23 or minute > 59 or second > 60:
    fail("timestamp " & value.escapeJson() &
      " is well shaped and names no instant")
  daysFromCivil(year, month, day) * 86_400 +
    int64(hour) * 3_600 + int64(minute) * 60 + int64(second)

proc validateField*(f: InferenceField; value: string) =
  ## The rule for one field. Exhaustive, so a new field cannot arrive
  ## unvalidated.
  if value.len > MaxFieldLen:
    fail($f & " is " & $value.len & " characters; no field of a statement " &
      "is a payload and at most " & $MaxFieldLen & " are read")
  case f
  of ifAgent, ifAgentConfig, ifModel, ifInferenceServer,
     ifSystemGeneration, ifPolicy, ifCertificate:
    requireDigest($f, value)
  of ifRequestCommitment, ifResponseCommitment:
    requireDigest($f, value)
  of ifNonce:
    try:
      validateChallengeHex(value)
    except BindingError as err:
      fail("nonce: " & err.msg)
  of ifTimestamp:
    discard timestampSeconds(value)

proc validateInferenceStatement*(s: InferenceStatement) =
  ## Every field, through the enum. The renderer runs this before it
  ## writes and the parser runs it after it reads, so a document cannot
  ## become valid by the route it travelled.
  for f in InferenceField: validateField(f, fieldOf(s, f))

# ---------------------------------------------------------------------
# The signed bytes
# ---------------------------------------------------------------------

proc inferenceStatementPreimage*(s: InferenceStatement): string =
  ## The exact bytes a signature covers.
  ##
  ## Exposed for the reason ``bindingPreimage`` and
  ## ``commitmentPreimage`` are: a second implementation can be checked
  ## against the *framing*, so a wrong framing that agrees on one vector
  ## is visible instead of merely improbable.
  ##
  ## No validation here. This is the construction; ``inferenceStatementBytes``
  ## is the entry point that applies the rules first.
  result = InferenceStatementDomainTag
  result.add be32Prefix(InferenceStatementSchema.len)
  result.add InferenceStatementSchema
  for f in InferenceField:
    let name = $f
    let value = fieldOf(s, f)
    result.add be32Prefix(name.len)
    result.add name
    result.add be32Prefix(value.len)
    result.add value

proc inferenceStatementBytes*(s: InferenceStatement): string =
  ## What a signer signs and what a verifier checks against, with the
  ## field rules applied first.
  validateInferenceStatement(s)
  inferenceStatementPreimage(s)

proc inferenceStatementDigest*(s: InferenceStatement): string =
  ## ``sha256:<hex>`` of the signed bytes — how an audit record and a log
  ## leaf name one statement.
  DigestPrefix & sha256Hex(inferenceStatementBytes(s))

# ---------------------------------------------------------------------
# The document
# ---------------------------------------------------------------------

proc renderInferenceStatement*(s: InferenceStatement): string =
  ## The canonical bytes, in enum order with a fixed indent.
  validateInferenceStatement(s)
  proc q(v: string): string = "\"" & v & "\""
  result = "{\n"
  result.add "  \"schema\": " & q(InferenceStatementSchema) & ",\n"
  for f in InferenceField:
    result.add "  " & q($f) & ": " & q(fieldOf(s, f))
    result.add (if f == high(InferenceField): "\n" else: ",\n")
  result.add "}\n"

proc parseInferenceStatement*(text, source: string): InferenceStatement =
  ## Parse and fully validate a statement.
  ##
  ## Strict in both directions: an unknown key is refused, and a missing
  ## one is refused. A document a reader only partly understands is a
  ## document whose signature covers bytes the reader cannot account for.
  if text.len > MaxInferenceStatementBytes:
    fail(source & ": is " & $text.len & " bytes; at most " &
      $MaxInferenceStatementBytes & " are read")
  var doc: JsonNode
  try:
    doc = parseJson(text)
  except CatchableError as err:
    fail(source & ": not JSON: " & err.msg)
  if doc.kind != JObject:
    fail(source & " must be a JSON object")
  let allowed = inferenceStatementKeys()
  for key in doc.keys:
    if key notin allowed:
      fail(source & " carries the unknown field " & key.escapeJson() &
        "; this build understands " & allowed.join(", ") &
        " and refuses a document it cannot fully honour")
  for key in allowed:
    if not doc.hasKey(key):
      fail(source & " is missing the required field " & key.escapeJson())
    if doc[key].kind != JString:
      fail(source & "." & key & " must be a string")
  let schema = doc["schema"].getStr
  if schema != InferenceStatementSchema:
    fail(source & ": schema is " & schema.escapeJson() & "; this build " &
      "understands " & InferenceStatementSchema.escapeJson() &
      " and refuses a document it cannot fully honour")
  for f in InferenceField:
    result = withField(result, f, doc[$f].getStr)
  try:
    validateInferenceStatement(result)
  except InferenceStatementError as err:
    fail(source & ": " & err.msg)

# ---------------------------------------------------------------------
# The audit record
# ---------------------------------------------------------------------

proc renderInferenceAuditRecord*(s: InferenceStatement;
                                 verdict, trust: string): string =
  ## What a certified-review or security-audit trail records about one
  ## statement.
  ##
  ## It is the statement's bound fields, its digest, and the verdict —
  ## and **it carries no plaintext, by construction**: every field of a
  ## statement is a digest, a commitment, a nonce or a timestamp, so
  ## there is nothing here to redact. That is the privacy property
  ## arriving where it is easiest to lose it. An audit record is the
  ## document most likely to be copied into a ticket, a report or a
  ## mailing list, and a scheme that protected the wire and then wrote
  ## the prompt into the audit trail would have protected nothing.
  ##
  ## ``verdict`` and ``trust`` are the verifier's own strings. This
  ## module does not produce them and cannot: it verifies nothing.
  validateInferenceStatement(s)
  proc q(v: string): string = "\"" & v & "\""
  result = "{\n"
  result.add "  \"schema\": " & q(InferenceAuditRecordSchema) & ",\n"
  result.add "  \"statement\": " & q(inferenceStatementDigest(s)) & ",\n"
  result.add "  \"verdict\": " & q(verdict) & ",\n"
  result.add "  \"trust\": " & q(trust) & ",\n"
  result.add "  \"bound\": {\n"
  for f in InferenceField:
    result.add "    " & q($f) & ": " & q(fieldOf(s, f))
    result.add (if f == high(InferenceField): "\n" else: ",\n")
  result.add "  }\n"
  result.add "}\n"
