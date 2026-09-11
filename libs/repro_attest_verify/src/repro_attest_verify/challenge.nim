## Minting a challenge, and remembering when it was minted.
##
## ## Why a document and not a hex string
##
## Freshness comes from the challenge and never from the clock in a
## report (``report.timestampInformational`` exists to be ignored). But
## "this report answers the challenge I issued" only bounds age if the
## verifier knows *when* it issued it — otherwise a report answering a
## challenge from last March is as fresh as one answering a challenge
## from a second ago.
##
## The verifier could keep that in a database. For a command-line
## verifier and for an embedding broker that mints and verifies in two
## different processes, the cheaper answer is to write it down beside the
## nonce: ``repro attest challenge`` emits a small
## ``reproos.attestation-challenge.v1`` record carrying the nonce and its
## issuance instant, and ``repro attest verify --challenge-file`` reads
## both back.
##
## The issuance time is the *verifier's own* statement about its own
## clock. It is not attested and does not need to be: the party it
## constrains is the one that wrote it.
##
## ## Why the time is NOT hidden inside the nonce
##
## It would fit — eight bytes of timestamp and twenty-four of entropy
## still clears the 128-bit floor. It was rejected because every 32-byte
## string then *looks* like a minted nonce, so a verifier handed an
## arbitrary challenge would silently read eight arbitrary bytes as an
## issuance time and report a freshness result it had no basis for. A
## separate record is either present or absent, and absence makes the
## freshness check report itself inapplicable, which is the truth.
##
## ## Mocking
##
## None. The entropy comes from the operating system's random source and
## a failure to obtain it is a refusal, not a fallback: a nonce from a
## degraded source is a nonce that provides no freshness while looking
## exactly like one that does.

import std/[json, strutils, sysrand, times]

import repro_attest

type
  ChallengeError* = object of CatchableError

  MintedChallenge* = object
    challengeHex*: string
    issuedAt*: string
      ## RFC 3339, whole seconds, UTC, ``Z`` — the one spelling this
      ## module writes and the only one it reads back.

const
  AttestationChallengeSchema* = "reproos.attestation-challenge.v1"

  ChallengeBytes* = 32
    ## 256 bits. Twice the discipline's floor, because the cost of a
    ## larger nonce is nothing and the cost of a guessable one is the
    ## whole freshness property.

  ChallengeRecordKeys*: array[3, string] = ["schema", "challenge", "issuedAt"]

  IssuedAtFormat* = "yyyy-MM-dd'T'HH:mm:ss'Z'"

proc formatIssuedAt*(epochMs: int64): string =
  utc(fromUnix(epochMs div 1000)).format(IssuedAtFormat)

proc parseIssuedAtMs*(s: string): int64 =
  ## The inverse, and strict: exactly the spelling ``formatIssuedAt``
  ## writes. A record in another spelling is refused rather than read
  ## approximately — an issuance time off by a time zone is a freshness
  ## window off by hours.
  if not isRfc3339(s):
    raise newException(ChallengeError,
      "issuedAt is " & s.escape() & ", which is not RFC 3339")
  if s.len != IssuedAtFormat.len - 4 or s[^1] != 'Z':
    # `yyyy-MM-dd'T'HH:mm:ss'Z'` is 24 characters of format producing 20
    # characters of output.
    raise newException(ChallengeError,
      "issuedAt is " & s.escape() & "; this build writes and reads whole " &
      "seconds in UTC (" & formatIssuedAt(0) & ") and refuses another " &
      "spelling rather than guess at an offset")
  try:
    result = parse(s, IssuedAtFormat, utc()).toTime().toUnix() * 1000
  except CatchableError as err:
    raise newException(ChallengeError,
      "issuedAt is " & s.escape() & ": " & err.msg)

proc mintChallenge*(nowMs: int64; bytes = ChallengeBytes): MintedChallenge =
  ## A fresh nonce and the instant it was minted.
  if bytes < ChallengeMinBytes or bytes > ChallengeMaxBytes:
    raise newException(ChallengeError,
      "a challenge of " & $bytes & " bytes is outside the " &
      $ChallengeMinBytes & "–" & $ChallengeMaxBytes &
      " the binding discipline accepts")
  var buf = newSeq[byte](bytes)
  if not urandom(buf):
    raise newException(ChallengeError,
      "the operating system's random source would not produce " & $bytes &
      " bytes; refusing to mint a challenge from anything else, because a " &
      "nonce nobody can predict and a nonce someone can are the same " &
      "length and only one of them is a nonce")
  var raw = newString(bytes)
  for i, b in buf: raw[i] = char(b)
  result.challengeHex = bytesToHex(raw)
  result.issuedAt = formatIssuedAt(nowMs)
  # The discipline's own floor, applied to what this module just made.
  validateChallengeHex(result.challengeHex)

proc renderChallengeRecord*(c: MintedChallenge): string =
  ## Canonical bytes, fixed key order, hand-rendered like every other
  ## document in this chain.
  proc q(s: string): string = "\"" & s & "\""
  result = "{\n"
  result.add "  \"schema\": " & q(AttestationChallengeSchema) & ",\n"
  result.add "  \"challenge\": " & q(c.challengeHex) & ",\n"
  result.add "  \"issuedAt\": " & q(c.issuedAt) & "\n"
  result.add "}\n"

proc parseChallengeRecord*(text, source: string): MintedChallenge =
  ## Strict for the same reason everything else here is: a verifier that
  ## mis-read its own record would bound freshness against the wrong
  ## instant and never know.
  var doc: JsonNode
  try:
    doc = parseJson(text)
  except CatchableError as err:
    raise newException(ChallengeError, source & ": not JSON: " & err.msg)
  if doc.kind != JObject:
    raise newException(ChallengeError, source & " must be a JSON object")
  for key in doc.keys:
    if key notin ChallengeRecordKeys:
      raise newException(ChallengeError,
        source & " carries the unknown field " & key.escape() &
        "; this build understands " & ChallengeRecordKeys.join(", "))
  for key in ChallengeRecordKeys:
    if not doc.hasKey(key):
      raise newException(ChallengeError,
        source & " is missing the required field " & key.escape())
    if doc[key].kind != JString:
      raise newException(ChallengeError,
        source & "." & key & " must be a string")
  if doc["schema"].getStr != AttestationChallengeSchema:
    raise newException(ChallengeError,
      source & ": schema is " & doc["schema"].getStr.escape() &
      "; this build understands " & AttestationChallengeSchema.escape())
  result.challengeHex = doc["challenge"].getStr
  result.issuedAt = doc["issuedAt"].getStr
  try:
    validateChallengeHex(result.challengeHex)
  except BindingError as err:
    raise newException(ChallengeError, source & ": " & err.msg)
  discard parseIssuedAtMs(result.issuedAt)
