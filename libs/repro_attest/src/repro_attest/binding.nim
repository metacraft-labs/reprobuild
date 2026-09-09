## The 64-byte binding discipline: the report data an attested instance
## puts into hardware evidence.
##
## ## What the 64 bytes are for
##
## SEV-SNP's ``REPORT_DATA``, TDX's ``REPORTDATA`` and a TPM quote's
## ``qualifyingData`` are all guest-chosen bytes that the hardware signs
## alongside the launch measurement. They carry **freshness and session
## binding only** — never configuration identity, which rides in the
## measurement itself. Concretely they answer two questions a launch
## measurement cannot:
##
##   * *Is this instance answering the challenge I just issued, or is it
##     replaying a quote it answered for someone else?*
##   * *If a key was agreed, is the key I am about to encrypt to the one
##     this same boot session holds?*
##
## Every backend must construct those bytes the same way or the two
## questions get different answers on different hardware, so the
## construction is here, once, and each driver calls it.
##
## ## The construction
##
## ::
##
##   report_data = SHA-512( "ReproOS-ATT-v1"
##                        ‖ be32(len purpose)      ‖ purpose
##                        ‖ be32(len challenge)    ‖ challenge
##                        ‖ be32(len ephemeralPub) ‖ ephemeralPub )
##
## ``purpose`` is the ASCII spelling of the enum below. ``challenge`` and
## ``ephemeralPub`` are RAW bytes — the bytes the hex in a report envelope
## decodes to, not the hex text. An absent ephemeral key is a length of
## zero followed by nothing.
##
## ## Why the length prefixes are here
##
## The design's formula is written as a plain concatenation of the four
## parts. A plain concatenation of variable-length parts is **ambiguous**,
## and the ambiguity is not decorative: with no framing,
##
##   (key-agreement, challenge = X,     pub = Y)      and
##   (key-agreement, challenge = X ‖ Y1, pub = Y2)  where Y = Y1 ‖ Y2
##
## produce the *same* 64 bytes. Two different session bindings that a
## hardware root would sign as one. Anything that re-splits the boundary
## between a variable-length challenge and a variable-length key collides,
## and a challenge is chosen by the verifier while the key is chosen by
## the instance — so an instance picks one side of that boundary.
##
## The tag needs no prefix: it is a fixed constant at offset zero, so its
## right edge is fixed. ``purpose`` would survive without one too, because
## the enum is closed and neither spelling is a prefix of the other — but
## that is a property of today's enum, not of the framing, and a third
## purpose could quietly break it. So every variable part is framed.
##
## This is a deliberate, recorded deviation from the formula as first
## written; the design document carries the framed form now, and the
## unframed form is not implemented anywhere.
##
## ## Mocking
##
## None.

import std/strutils

import nimcrypto/[hash, sha2]

type
  BindingPurpose* = enum
    ## What the 64 bytes are being used for. The purpose is inside the
    ## hash so the same challenge answered for a different protocol is a
    ## different set of bytes — cross-protocol reuse of one quote is what
    ## this closes.
    bpAttest = "attest"
    bpKeyAgreement = "key-agreement"

  ReportBindings* = object
    ## The ``bindings`` object of a report envelope.
    purpose*: BindingPurpose
    ephemeralPub*: string
      ## Lower-case hex of the instance's ephemeral public key, or the
      ## empty string. Present exactly when ``purpose`` is
      ## ``bpKeyAgreement`` — see ``validateBindings``.

  BindingError* = object of CatchableError
    ## Raised for inputs the discipline will not bind. The message names
    ## the offending value, because whoever reads it has to fix a request.

const
  ReportDataDomainTag* = "ReproOS-ATT-v1"
    ## The domain-separation tag. It is the first thing hashed and it is
    ## versioned: a future construction is a new tag, never a new
    ## interpretation of this one.

  ReportDataSize* = 64
    ## Exactly what SNP and TDX carry, and exactly what SHA-512 produces.

  ReportDataHexLen* = ReportDataSize * 2

  ChallengeMinBytes* = 16
    ## 128 bits. A shorter nonce is refused rather than accepted with a
    ## warning: freshness is the only thing the challenge provides, and a
    ## guessable challenge provides none of it.

  ChallengeMaxBytes* = 128
    ## A nonce, not a payload. The ceiling stops a caller from smuggling
    ## data through the freshness field.

  EphemeralPubMaxBytes* = 256
    ## Room for any public key a key agreement could use; X25519 needs 32
    ## and P-384 needs 97.

# ---------------------------------------------------------------------
# Hex
# ---------------------------------------------------------------------

proc isLowerHex*(s: string): bool =
  ## Lower-case hex of even length. Case is fixed so one value has one
  ## spelling: a document whose bytes depend on how it was typed cannot be
  ## compared, and comparison is what all of this is for.
  if s.len mod 2 != 0: return false
  for c in s:
    if c notin {'0' .. '9', 'a' .. 'f'}: return false
  true

proc hexToBytes*(where, s: string): string =
  ## Decode lower-case hex. Raises ``BindingError`` naming ``where``.
  if not isLowerHex(s):
    raise newException(BindingError,
      where & " must be an even number of lower-case hex characters, got " &
      s.escape())
  result = newString(s.len div 2)
  for i in 0 ..< result.len:
    result[i] = char(parseHexInt(s[2 * i .. 2 * i + 1]))

proc bytesToHex*(data: string): string =
  ## Lower-case hex, the one spelling this library emits.
  const digits = "0123456789abcdef"
  result = newString(data.len * 2)
  for i, ch in data:
    let b = int(uint8(ch))
    result[2 * i] = digits[b shr 4]
    result[2 * i + 1] = digits[b and 0xF]

# ---------------------------------------------------------------------
# The construction
# ---------------------------------------------------------------------

proc sha512Hex*(data: string): string =
  ## Lower-case hex SHA-512, the one digest this module speaks.
  ##
  ## Exposed so the primitive can be pinned against the published FIPS
  ## vectors on its own. A construction checked only through its own
  ## helper is a construction checked against itself.
  toLowerAscii($sha512.digest(data))

proc be32(n: int): string =
  ## Four-byte big-endian length. Big-endian because every wire format
  ## this evidence travels beside is, and a fixed width because a
  ## self-describing one would need framing of its own.
  result = newString(4)
  result[0] = char((n shr 24) and 0xFF)
  result[1] = char((n shr 16) and 0xFF)
  result[2] = char((n shr 8) and 0xFF)
  result[3] = char(n and 0xFF)

proc bindingPreimage*(purpose: BindingPurpose;
                      challenge, ephemeralPub: string): string =
  ## The exact bytes that are hashed, raw in and raw out.
  ##
  ## Exposed on purpose: a second implementation in another language can
  ## be checked against the *framing* rather than only against the digest,
  ## and a wrong framing that happens to agree on one vector is then
  ## visible instead of merely improbable.
  ##
  ## This is the construction and carries no policy — it will frame a
  ## challenge of any length, including lengths the discipline refuses.
  ## Use ``reportDataHexFor`` for anything a backend actually binds.
  result = ReportDataDomainTag
  let p = $purpose
  result.add be32(p.len)
  result.add p
  result.add be32(challenge.len)
  result.add challenge
  result.add be32(ephemeralPub.len)
  result.add ephemeralPub

proc reportData*(purpose: BindingPurpose;
                 challenge, ephemeralPub: string): string =
  ## The 64 raw bytes that go into ``REPORT_DATA`` / ``REPORTDATA`` /
  ## ``qualifyingData``. Raw challenge and key bytes in. No policy; see
  ## ``bindingPreimage``.
  let d = sha512.digest(bindingPreimage(purpose, challenge, ephemeralPub))
  result = newString(ReportDataSize)
  for i in 0 ..< ReportDataSize:
    result[i] = char(d.data[i])

proc reportDataHex*(purpose: BindingPurpose;
                    challenge, ephemeralPub: string): string =
  ## The same 64 bytes as 128 lower-case hex characters — how a report
  ## envelope spells them. Raw bytes in. No policy; see
  ## ``bindingPreimage``.
  bytesToHex(reportData(purpose, challenge, ephemeralPub))

# ---------------------------------------------------------------------
# Policy
# ---------------------------------------------------------------------

proc validateBindings*(b: ReportBindings) =
  ## The coupling the report envelope states and the hash construction
  ## does not: an ephemeral key is present exactly when the purpose is a
  ## key agreement.
  ##
  ## Both polarities are refused. A key under ``attest`` is a third,
  ## unnamed use of the same 64 bytes, which is the thing the purpose
  ## field exists to prevent; a key agreement without a key is a request
  ## that cannot bind the channel it claims to establish. A new use is a
  ## new ``purpose``, never a new combination of the old ones.
  case b.purpose
  of bpAttest:
    if b.ephemeralPub.len != 0:
      raise newException(BindingError,
        "bindings.ephemeralPub is set under purpose " & $bpAttest &
        ", which binds no key; a use that binds one is a distinct purpose")
  of bpKeyAgreement:
    if b.ephemeralPub.len == 0:
      raise newException(BindingError,
        "bindings.ephemeralPub is required under purpose " & $bpKeyAgreement &
        "; an agreement that binds no key cannot bind the channel it opens")
  if b.ephemeralPub.len != 0:
    if not isLowerHex(b.ephemeralPub):
      raise newException(BindingError,
        "bindings.ephemeralPub must be lower-case hex, got " &
        b.ephemeralPub.escape())
    let n = b.ephemeralPub.len div 2
    if n > EphemeralPubMaxBytes:
      raise newException(BindingError,
        "bindings.ephemeralPub is " & $n & " bytes; at most " &
        $EphemeralPubMaxBytes & " are bound")

proc validateChallengeHex*(challengeHex: string) =
  ## A challenge is the only source of freshness a report has, so its
  ## floor is enforced here rather than left to each caller.
  if not isLowerHex(challengeHex):
    raise newException(BindingError,
      "challenge must be lower-case hex, got " & challengeHex.escape())
  let n = challengeHex.len div 2
  if n < ChallengeMinBytes:
    raise newException(BindingError,
      "challenge is " & $n & " bytes; freshness rests on it alone, so at " &
      "least " & $ChallengeMinBytes & " bytes are required")
  if n > ChallengeMaxBytes:
    raise newException(BindingError,
      "challenge is " & $n & " bytes; at most " & $ChallengeMaxBytes &
      " are bound, a nonce being a nonce")

proc reportDataHexFor*(b: ReportBindings; challengeHex: string): string =
  ## The entry point every backend driver uses: hex in, hex out, with the
  ## discipline's rules applied first. There is one of these so that
  ## "what did this instance bind?" has one answer on every backend.
  validateBindings(b)
  validateChallengeHex(challengeHex)
  reportDataHex(b.purpose,
                hexToBytes("challenge", challengeHex),
                (if b.ephemeralPub.len == 0: ""
                 else: hexToBytes("bindings.ephemeralPub", b.ephemeralPub)))

proc parseBindingPurpose*(where, s: string): BindingPurpose =
  ## Fail-closed: a purpose this build does not implement is refused, not
  ## treated as the default one.
  for p in BindingPurpose:
    if $p == s: return p
  var known: seq[string] = @[]
  for p in BindingPurpose: known.add $p
  raise newException(BindingError,
    where & " is " & s.escape() & "; this build binds " &
    known.join(", ") & " and refuses a purpose it cannot honour")
