## The wire format a released secret travels in, and the two context
## strings that bind it to one key agreement.
##
## ## What this module is for
##
## A key agreement establishes one public key inside one boot session and
## puts it inside signed evidence. Whoever holds the secret checks that
## evidence, encrypts to that key, and hands the result back. This module
## owns the *shape* of what is handed back and the *context* the
## encryption runs under — and nothing else. There is no cryptography
## here: the sender and the receiver both live above this module, so the
## framing can be read, gated and argued about without a key schedule in
## the way.
##
## ## The blob
##
## ::
##
##   wrapped := "reproos.provisioned-secret.v1"
##            ‖ be16(aeadId)
##            ‖ be32(len enc) ‖ enc
##            ‖ be32(len ct)  ‖ ct
##
## The tag is a fixed constant at offset zero, so its right edge is
## already fixed and it needs no prefix. ``aeadId`` is two fixed-width
## bytes and is likewise self-delimiting. Everything of variable length
## is framed.
##
## That is not decoration. Without the two length prefixes, ``(enc = AB,
## ct = C)`` and ``(enc = A, ct = BC)`` are the *same bytes*, so a relay
## could move the boundary between the encapsulated key and the
## ciphertext and hand the receiver a different message from the one the
## sender composed. It would not open — but "it does not open" is a
## property of the AEAD, reached by accident, and the receiver would have
## no way to say what it was handed. Framing makes the split a fact of the
## document rather than a consequence of a tag check. ``framedJoin``
## below is the one place that framing happens, and a gate constructs
## the collision the unframed join really does produce.
##
## ## The two context strings
##
## HPKE takes an ``info`` at setup and an ``aad`` per message. Both are
## used, and both are framed — though for a weaker reason than the blob
## above, and the difference is stated because the first version of this
## header did not state it. Each of these has exactly ONE
## variable-length field, at the end, after a fixed prefix, so it is
## already self-delimiting and no *current* pair of inputs collides
## without the frame. The frame is there so that a second field cannot
## be appended later without the question being reopened — which is
## exactly why ``binding.nim`` frames ``purpose`` even though today's
## two spellings would survive unframed.
##
## ::
##
##   info := "reproos.provision.info.v1"
##         ‖ be32(len preimage) ‖ preimage
##
##   aad  := "reproos.provision.aad.v1"
##         ‖ be32(len name) ‖ name
##
## where ``preimage`` is ``bindingPreimage(bpKeyAgreement, challenge,
## ephemeralPub)`` — **the very bytes the hardware hashed into the
## evidence**. That is the whole point of the choice: the context the
## secret is encrypted under and the context the quote was signed under
## are the same object, so a ciphertext composed against one session
## cannot be opened by another session even if, by some accident of key
## reuse, the private key were the same. The sender does not get to
## describe the session; it re-derives it from the report.
##
## The ``aad`` carries the secret's NAME, so a relay cannot relabel a
## released secret — handing a machine its database password under the
## name of its TLS key is a privilege escalation performed entirely with
## ciphertext nobody could read. The name is authenticated and not
## encrypted, which is what ``aad`` is for.
##
## ## Bounds
##
## Everything a caller can grow is bounded here rather than at each call
## site. The receiver is a pre-authentication surface, so a bound that
## lives in a comment is a bound that does not exist.
##
## ## Mocking
##
## None. There is nothing here to mock — it is bytes in, bytes out.

import std/[strutils]

import ./binding

const
  WrappedSecretTag* = "reproos.provisioned-secret.v1"
    ## Versioned: a different framing is a different tag, never a
    ## re-reading of this one.

  ProvisionInfoTag* = "reproos.provision.info.v1"
    ## Domain separation for the HPKE ``info``. Distinct from the tag
    ## above and from ``ReportDataDomainTag``, so the same session's
    ## bytes never serve two constructions.

  ProvisionAadTag* = "reproos.provision.aad.v1"
    ## Domain separation for the HPKE ``aad``.

  MaxEncapsulatedKeyBytes* = 256
    ## The same ceiling ``EphemeralPubMaxBytes`` puts on the key the
    ## evidence binds. DHKEM(X25519) encapsulates 32.

  MaxWrappedCiphertextBytes* = 65_536
    ## A released secret is a credential, a key or an unlock token — not
    ## a payload. Sixty-four kilobytes is far more than any of those and
    ## far less than a channel.

  MaxSecretBytes* = MaxWrappedCiphertextBytes - 64
    ## The plaintext ceiling, left below the ciphertext ceiling by more
    ## than any AEAD's tag, so a secret this module accepts cannot
    ## produce a blob this module refuses.

  MaxSecretNameLen* = 64
    ## A file name in a runtime directory, not a path.

  SecretNameChars* = {'a' .. 'z', '0' .. '9', '-', '_', '.'}
    ## Deliberately narrow: lower case only, no slash, no ``..`` (the
    ## whole-name check below rules that out separately), nothing a shell
    ## or a path walker treats specially. A released secret becomes a file
    ## name chosen by whoever sent the ciphertext.

  DefaultSecretName* = "secret"
    ## What an unnamed release is called. Named rather than empty so the
    ## ``aad`` is never a zero-length string whose absence and whose
    ## emptiness would look alike.

type
  ProvisionError* = object of CatchableError
    ## Every refusal in this module. Each message below has exactly one
    ## producing site, so a test that matches one cannot be satisfied by
    ## another.

  WrappedSecret* = object
    ## A parsed blob. ``aeadId`` is carried as the registered number
    ## rather than as an enum, because this module does not know which
    ## AEADs the build above it composes and must not refuse on its own
    ## authority a suite that build implements.
    aeadId*: uint16
    enc*: string
      ## RAW encapsulated-key bytes.
    ciphertext*: string
      ## RAW AEAD output, tag included.

proc be16(n: int): string =
  result = newString(2)
  result[0] = char((n shr 8) and 0xFF)
  result[1] = char(n and 0xFF)

proc be32(n: int): string =
  ## Four-byte big-endian length, spelled the same way ``binding.nim``
  ## spells it and for the same reasons.
  result = newString(4)
  result[0] = char((n shr 24) and 0xFF)
  result[1] = char((n shr 16) and 0xFF)
  result[2] = char((n shr 8) and 0xFF)
  result[3] = char(n and 0xFF)

proc readBe16(s: string; at: int): int =
  (int(uint8(s[at])) shl 8) or int(uint8(s[at + 1]))

proc readBe32(s: string; at: int): int64 =
  (int64(uint8(s[at])) shl 24) or (int64(uint8(s[at + 1])) shl 16) or
  (int64(uint8(s[at + 2])) shl 8) or int64(uint8(s[at + 3]))

# ---------------------------------------------------------------------
# Framing, and the context strings
# ---------------------------------------------------------------------

proc framedJoin*(parts: openArray[string]): string =
  ## The framing, and the ONLY framing: every construction in this module
  ## is a fixed tag followed by this.
  ##
  ## It is one procedure rather than three open-coded loops because a
  ## framing spelled three times is a framing that can be deleted from
  ## one of them, and because a gate can then check it BY VALUE — read
  ## the length prefix back and compare it against what follows —
  ## instead of comparing two inputs and hoping the difference came from
  ## here.
  ##
  ## The previous shape of this was a predicate,
  ## ``framingIsInjective(a, b)``, and it was a tautology: a framed join
  ## IS injective, so the procedure could only ever return true, and a
  ## body of ``return true`` passed every case that used it. Measured,
  ## not supposed. What replaces it answers in both directions, because
  ## the gate joins the same parts WITHOUT the frames and shows that
  ## those really do collide.
  for p in parts:
    result.add be32(p.len)
    result.add p

proc provisionInfo*(challenge, ephemeralPub: string): string =
  ## The HPKE ``info`` for a release into the session that bound
  ## ``ephemeralPub`` under ``challenge``. RAW bytes in — the bytes the
  ## hex in a report envelope decodes to, not the hex text, exactly as
  ## ``bindingPreimage`` takes them.
  ##
  ## The preimage is embedded whole and framed rather than rebuilt field
  ## by field, so there is one construction of "which session is this"
  ## in the codebase and the hardware signed over it.
  result = ProvisionInfoTag
  result.add framedJoin(
    [bindingPreimage(bpKeyAgreement, challenge, ephemeralPub)])

proc provisionAad*(name: string): string =
  ## The HPKE ``aad`` for a secret released under ``name``.
  result = ProvisionAadTag
  result.add framedJoin([name])


# ---------------------------------------------------------------------
# Names
# ---------------------------------------------------------------------

proc validateSecretName*(name: string) =
  ## A released secret becomes a file in a runtime directory, and the
  ## name comes off the wire. Every rule here is about that.
  if name.len == 0:
    raise newException(ProvisionError,
      "the secret name is empty; a release is named so the machine can " &
      "tell two of them apart, and " & DefaultSecretName.escape() &
      " is what an unnamed one is called")
  if name.len > MaxSecretNameLen:
    raise newException(ProvisionError,
      "the secret name is " & $name.len & " characters; at most " &
      $MaxSecretNameLen & " are accepted, a name being a name")
  for c in name:
    if c notin SecretNameChars:
      raise newException(ProvisionError,
        "the secret name " & name.escape() & " carries " & ($c).escape() &
        ", and a name that becomes a file is restricted to lower-case " &
        "letters, digits, hyphen, underscore and dot")
  if name == "." or name == "..":
    # BEFORE the leading-dot rule below, and with its own sentence,
    # because both spellings also begin with a dot: without this order
    # and this message, deleting the rule would leave the other one
    # answering and nothing would notice. An operator told that ``..``
    # "begins with a dot" has been told the wrong thing.
    raise newException(ProvisionError,
      "the secret name " & name.escape() &
      " is a directory entry that names a directory; it would not create " &
      "a file, it would rename one")
  if name.startsWith('.'):
    raise newException(ProvisionError,
      "the secret name " & name.escape() &
      " begins with a dot; a released secret is not hidden from the " &
      "operator who has to know what their machine is holding")

# ---------------------------------------------------------------------
# The blob
# ---------------------------------------------------------------------

proc renderWrappedSecret*(aeadId: uint16; enc, ciphertext: string): string =
  ## Compose the blob. Refuses the same shapes the parser refuses, so a
  ## sender cannot build a document its own receiver would reject.
  if enc.len == 0:
    raise newException(ProvisionError,
      "the encapsulated key is empty; there is nothing for the receiver " &
      "to derive a shared secret from")
  if enc.len > MaxEncapsulatedKeyBytes:
    raise newException(ProvisionError,
      "the encapsulated key is " & $enc.len & " bytes; at most " &
      $MaxEncapsulatedKeyBytes & " are carried")
  if ciphertext.len == 0:
    raise newException(ProvisionError,
      "the ciphertext is empty; an authenticated encryption of nothing " &
      "is still a tag, so a zero-length one is a malformed document " &
      "rather than an empty secret")
  if ciphertext.len > MaxWrappedCiphertextBytes:
    raise newException(ProvisionError,
      "the ciphertext is " & $ciphertext.len & " bytes; at most " &
      $MaxWrappedCiphertextBytes & " are carried")
  result = WrappedSecretTag
  result.add be16(int(aeadId))
  result.add framedJoin([enc, ciphertext])

proc parseWrappedSecret*(blob: string): WrappedSecret =
  ## Strict, and strict about its own edges: a blob with bytes left over
  ## is refused rather than read up to the part that parsed. A trailing
  ## remainder is how one document becomes two.
  const hdr = WrappedSecretTag.len + 2
  if blob.len < hdr:
    raise newException(ProvisionError,
      "a wrapped secret is at least " & $hdr & " bytes of header and this " &
      "one is " & $blob.len)
  if blob[0 ..< WrappedSecretTag.len] != WrappedSecretTag:
    raise newException(ProvisionError,
      "a wrapped secret begins with " & WrappedSecretTag.escape() &
      " and this one begins with " &
      blob[0 ..< WrappedSecretTag.len].escape())
  result.aeadId = uint16(readBe16(blob, WrappedSecretTag.len))

  var at = hdr
  if blob.len < at + 4:
    raise newException(ProvisionError,
      "the wrapped secret ends before the length of its encapsulated key")
  let encLen = readBe32(blob, at)
  at += 4
  if encLen == 0:
    raise newException(ProvisionError,
      "the wrapped secret frames an encapsulated key of zero bytes")
  if encLen > MaxEncapsulatedKeyBytes:
    raise newException(ProvisionError,
      "the wrapped secret frames an encapsulated key of " & $encLen &
      " bytes; at most " & $MaxEncapsulatedKeyBytes & " are carried")
  if int64(blob.len) < int64(at) + encLen:
    raise newException(ProvisionError,
      "the wrapped secret frames " & $encLen & " bytes of encapsulated " &
      "key and carries " & $(blob.len - at))
  result.enc = blob[at ..< at + int(encLen)]
  at += int(encLen)

  if blob.len < at + 4:
    raise newException(ProvisionError,
      "the wrapped secret ends before the length of its ciphertext")
  let ctLen = readBe32(blob, at)
  at += 4
  if ctLen == 0:
    raise newException(ProvisionError,
      "the wrapped secret frames a ciphertext of zero bytes")
  if ctLen > MaxWrappedCiphertextBytes:
    raise newException(ProvisionError,
      "the wrapped secret frames a ciphertext of " & $ctLen &
      " bytes; at most " & $MaxWrappedCiphertextBytes & " are carried")
  if int64(blob.len) < int64(at) + ctLen:
    raise newException(ProvisionError,
      "the wrapped secret frames " & $ctLen & " bytes of ciphertext and " &
      "carries " & $(blob.len - at))
  result.ciphertext = blob[at ..< at + int(ctLen)]
  at += int(ctLen)

  if at != blob.len:
    raise newException(ProvisionError,
      "the wrapped secret has " & $(blob.len - at) &
      " bytes after its ciphertext; a document with a remainder is two " &
      "documents, and this reader will not choose which one it read")
