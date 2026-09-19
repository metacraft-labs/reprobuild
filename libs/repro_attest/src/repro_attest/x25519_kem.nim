## The key-encapsulation mechanism an attested instance carries: X25519
## key agreement, and HPKE base mode over it.
##
## ## What this is, and where it sits
##
## ``driver`` declares two halves of one seam — mint a key pair, open
## what was released to it — and says nothing about how either is done.
## This module is the implementation the build ships:
##
##   * **DHKEM(X25519, HKDF-SHA256) / HKDF-SHA256 / AES-128-GCM**, the
##     mandatory-to-implement RFC 9180 suite, composed by
##     ``repro_attest/hpke`` over the vendored BearSSL.
##   * **The private key never leaves the process.** It is minted here,
##     lives in the agent's session table, is handed back to
##     ``openReleasedSecret`` once, and is overwritten when the session
##     ends. Nothing writes it anywhere.
##
## ## Where the randomness comes from, and why that is stated here
##
## ``hpke`` has no random number generator at all, on purpose: every key
## it produces comes from ``deriveKeyPair(ikm)`` and every encapsulation
## takes its ephemeral key as an argument, so the published test vectors
## can be reproduced exactly. That leaves *somebody* holding the
## responsibility for entropy, and it is this module. The seed is drawn
## from the operating system — ``nimcrypto/sysrand``, which is
## ``getrandom``/``arc4random``/``BCryptGenRandom`` — and a short read is
## a **refusal**, not a retry and not a top-up from a weaker source. A
## key agreement is worth exactly what its seed is worth, so a key source
## that could not get entropy must produce no key.
##
## Seed width is ``SeedBytes``, which is ``Nsk`` and not less. RFC 9180's
## ``DeriveKeyPair`` refuses anything shorter, and this module draws the
## full width rather than relying on that refusal, so the floor is held
## in two independent places.
##
## ## The context a release is opened under
##
## ``openReleasedSecret`` does **not** take the context from the request.
## It rebuilds it from the session the agent holds — the challenge that
## key agreement was issued under and the public key the evidence bound —
## through ``provision.provisionInfo``, whose framed preimage is the very
## byte string the hardware hashed. A ciphertext composed for another
## session therefore fails to open, and it fails inside the AEAD rather
## than at a comparison somebody could forget to write.
##
## ## Mocking
##
## None. This is the mechanism; ``mock_backend``'s ``MockKeySource`` is a
## published non-mechanism that exists so the endpoint could be built
## before this module was, and it names itself ``mock-not-a-kem`` so the
## two are not confusable.

import std/[strutils]

import nimcrypto/sysrand

import ./driver
import ./hpke
import ./provision

const
  X25519KemAlgorithm* = "hpke-x25519-hkdf-sha256-aes128gcm"
    ## What ``/health`` reports and what the party holding a secret reads
    ## to know which mechanism to encrypt with. It names all three
    ## primitives, because "X25519" alone names a key agreement and not a
    ## way to encrypt anything.

  ProvisionAead* = haAes128Gcm
    ## RFC 9180 §7.3's mandatory-to-implement AEAD. Named once here so
    ## the sender, the receiver and the blob's ``aeadId`` cannot drift
    ## apart.

  SeedBytes* = Nsk
    ## The width drawn from the operating system per key agreement.

  EphemeralPublicKeyBytes* = Npk
    ## What a report's ``bindings.ephemeralPub`` decodes to under this
    ## mechanism.

  EncapsulatedKeyBytes* = Nenc
    ## What a released blob's ``enc`` member is under this mechanism.

type
  X25519KeySource* = ref object of EphemeralKeySource
    ## The shipped mechanism. Stateless: every key agreement draws its own
    ## seed, so two sessions share nothing and the source holds no
    ## material between calls.

  KemError* = object of CatchableError
    ## Raised for a release this build will not open. Every message below
    ## has exactly one producing site.

proc requireFullDraw*(got: int) =
  ## The rule about a short draw, separated from the draw itself.
  ##
  ## It is here as its own procedure for one reason: the branch cannot be
  ## reached through ``drawSeed`` by any test that is not a replacement
  ## for the operating system's random source, and a rule nothing can
  ## reach is a sentence rather than a rule. Split out, the rule has an
  ## input and the syscall keeps its one caller.
  if got != SeedBytes:
    raise newException(DriverError,
      "the operating system returned " & $got & " of " & $SeedBytes &
      " bytes of entropy for an ephemeral key; this build refuses to " &
      "stretch a short draw, because a key agreement is worth exactly " &
      "what its seed is worth")

proc requireDerivedWidths*(pkLen, skLen: int) =
  ## Likewise for the widths ``deriveKeyPair`` produced. The derivation
  ## cannot produce another width, which is exactly why the check would
  ## otherwise be unfalsifiable: it is what the build would need to
  ## notice if it ever could.
  if pkLen != Npk or skLen != Nsk:
    raise newException(DriverError,
      "key derivation produced a " & $pkLen & "-byte public key " &
      "and a " & $skLen & "-byte private key; " & $Npk & " and " &
      $Nsk & " are what this mechanism binds")

proc drawSeed(): string =
  ## ``SeedBytes`` from the operating system, or a refusal.
  result = newString(SeedBytes)
  let got = randomBytes(addr result[0], SeedBytes)
  if got != SeedBytes:
    # Overwrite whatever partial draw landed before raising. A short read
    # is the one case where a buffer holds material that is neither
    # random nor empty, and it must not survive the failure.
    for i in 0 ..< result.len: result[i] = '\0'
  requireFullDraw(got)

method generateEphemeralKeyPair*(s: X25519KeySource): EphemeralKeyPair =
  ## A fresh X25519 pair from a fresh operating-system seed.
  var seed = drawSeed()
  let pair =
    try:
      deriveKeyPair(seed)
    finally:
      for i in 0 ..< seed.len: seed[i] = '\0'
  requireDerivedWidths(pair.pk.len, pair.sk.len)
  EphemeralKeyPair(publicKey: pair.pk, privateKey: pair.sk)

method openReleasedSecret*(s: X25519KeySource; r: SecretRelease): string =
  ## Recover a released secret, or raise.
  ##
  ## The order matters and is the whole of the security argument:
  ##
  ##   1. The blob is parsed by ``provision``, which frames its two
  ##      variable-length parts, so what is treated as the encapsulated
  ##      key and what is treated as the ciphertext is a fact of the
  ##      document rather than a guess.
  ##   2. The suite is checked against the one this build composes. A
  ##      blob naming another suite is refused rather than opened with
  ##      this one — the AEAD would refuse anyway, and a diagnostic that
  ##      says "wrong suite" is worth more than one that says "bad tag".
  ##   3. The context is rebuilt from the SESSION, never from the
  ##      request.
  ##   4. ``openBase`` either returns an authenticated plaintext or
  ##      raises. There is no third outcome and nothing below this line
  ##      inspects a tag.
  if r.privateKey.len != Nsk:
    raise newException(KemError,
      "this key agreement holds a " & $r.privateKey.len &
      "-byte private key and this mechanism uses " & $Nsk)
  let parsed = parseWrappedSecret(r.wrapped)
  if parsed.aeadId != uint16(ProvisionAead):
    raise newException(KemError,
      "the released secret names authenticated-encryption suite 0x" &
      toHex(parsed.aeadId) & " and this build composes 0x" &
      toHex(uint16(ProvisionAead)) & " (" & X25519KemAlgorithm &
      "); it will not open a document under a suite the sender did not " &
      "use")
  if parsed.enc.len != Nenc:
    raise newException(KemError,
      "the released secret carries a " & $parsed.enc.len &
      "-byte encapsulated key and this mechanism encapsulates " & $Nenc)
  let info = provisionInfo(r.challenge, r.ephemeralPub)
  let aad = provisionAad(r.name)
  try:
    result = openBase(ProvisionAead, parsed.enc, r.privateKey, info, aad,
                      parsed.ciphertext)
  except HpkeError as err:
    raise newException(KemError,
      "the released secret did not open under this key agreement: " &
      err.msg & "; the context is rebuilt from the session this agent " &
      "issued, so a ciphertext composed for another session, another " &
      "name or another key cannot be recovered here")
  if result.len > MaxSecretBytes:
    raise newException(KemError,
      "the released secret is " & $result.len & " bytes; at most " &
      $MaxSecretBytes & " are accepted")

proc newX25519KeySource*(): X25519KeySource =
  result = X25519KeySource()
  initEphemeralKeySource(result, X25519KemAlgorithm)

# ---------------------------------------------------------------------
# The sending half
# ---------------------------------------------------------------------

proc wrapSecretForEphemeral*(recipientPub, challenge, name, secret: string;
                             senderSeed: string): string =
  ## Compose the blob that releases ``secret`` to the instance holding
  ## the private half of ``recipientPub``.
  ##
  ## It lives here, beside the opener, so the two halves of one
  ## construction cannot drift: the ``info``, the ``aad``, the suite and
  ## the framing are each written once and read by both. A sender in
  ## another repository re-derives them from ``provision``; a sender in
  ## this one calls this.
  ##
  ## ``senderSeed`` is the HPKE ephemeral key's seed and is supplied by
  ## the caller rather than drawn here, for the reason ``hpke`` gives:
  ## a construction whose randomness is a parameter can be pinned against
  ## published vectors. Callers that have no vector to reproduce use
  ## ``drawSenderSeed``.
  validateSecretName(name)
  if recipientPub.len != Npk:
    raise newException(KemError,
      "a release is encrypted to a " & $Npk & "-byte X25519 public key " &
      "and this one is " & $recipientPub.len & " bytes")
  if secret.len == 0:
    raise newException(KemError,
      "the secret is empty; releasing nothing to an attested machine is " &
      "a mistake that would look exactly like success")
  if secret.len > MaxSecretBytes:
    raise newException(KemError,
      "the secret is " & $secret.len & " bytes; at most " & $MaxSecretBytes &
      " are released, this being a credential rather than a channel")
  let ephemeral = deriveKeyPair(senderSeed)
  let info = provisionInfo(challenge, recipientPub)
  let aad = provisionAad(name)
  let (enc, ct) = sealBase(ProvisionAead, recipientPub, ephemeral, info, aad,
                           secret)
  renderWrappedSecret(uint16(ProvisionAead), enc, ct)

proc drawSenderSeed*(): string =
  ## ``SeedBytes`` of operating-system entropy for the sender's ephemeral
  ## key. Separate from the recipient's draw so that a caller reading
  ## this code can see there are two ephemeral keys in an HPKE release —
  ## the instance's, which the evidence binds, and the sender's, which
  ## rides in the blob — and that neither is reused.
  drawSeed()
