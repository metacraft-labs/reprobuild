## TPM 2.0 structure codec: the big-endian TLV a measured-boot machine
## signs, read and written by hand.
##
## ## What this is
##
## A TPM answers `TPM2_Quote` with two byte strings and nothing else: a
## `TPMS_ATTEST` — the thing it signed — and a `TPMT_SIGNATURE` over it.
## Everything a verifier wants to conclude from a measured boot is inside
## those bytes, so something has to read them, and reading them is not a
## formality: the bytes arrive from the machine whose trustworthiness is
## the open question. This module is that reader, plus the writer that
## proves the reader understood what it read.
##
## It is a **codec**. It parses, it re-serialises, and it recomputes the
## PCR composite digest. It does not verify a signature, does not walk a
## certificate chain, does not decide whether a measurement is acceptable
## and does not talk to a device. Those are separate concerns living in
## separate places, and a codec that quietly did any of them would be a
## codec whose failures are indistinguishable from policy decisions.
##
## ## Encoding rules, stated once
##
## The TPM wire encoding is fixed-width big-endian integers with no
## alignment, no padding and no tags. Two shapes recur:
##
##   * **`TPM2B_*`** — a `UINT16` byte count followed by exactly that many
##     bytes. Every variant (`TPM2B_DIGEST`, `TPM2B_NAME`, `TPM2B_DATA`,
##     `TPM2B_ECC_PARAMETER`, `TPM2B_PUBLIC_KEY_RSA`) is that and differs
##     only in the maximum the spec allows. The maxima are enforced, not
##     documented: see *Why the maxima are checked* below.
##   * **`TPML_*`** — a `UINT32` element count followed by that many
##     elements.
##
## `TPMT_SIGNATURE` is a tagged union: a `TPM_ALG_ID` selector followed by
## a payload whose *shape depends on the selector*. A parser that does not
## know the selector cannot find the end of the structure, so an
## unrecognised signature algorithm is refused rather than skipped.
##
## ## Why the maxima are checked
##
## A length-prefixed format is only as safe as its length checks, and this
## one's lengths are attacker-chosen: the bytes come from the machine
## under verification, which is precisely the party with a motive to lie
## about them. Two failure modes matter and they fail in opposite
## directions:
##
##   * A length **longer than the remaining input** must be a refusal. The
##     tempting alternative — take what is there — is an *under-read*: the
##     structure is accepted, the field is short, and every later field is
##     read from the wrong offset while the parse reports success.
##   * A length **within the input but beyond what the spec allows** must
##     also be a refusal, because the field would then swallow the fields
##     after it. A 64-byte `TPM2B_DIGEST` declared as 1000 bytes inside a
##     2000-byte buffer parses "fine" and produces a different structure
##     than the TPM signed.
##
## So every read is bounded twice — against what remains and against the
## spec's maximum — and the message names the structure, the field, the
## declared length and the offset, because whoever reads it is looking at
## a machine that would not attest.
##
## Trailing bytes are an error too. A quote with one byte appended is not
## the quote the TPM signed, and a parser that stops when it has what it
## wanted would accept it.
##
## ## The PCR composite, and why the selection is the dangerous part
##
## `pcrDigest` inside a quote is *not* a PCR value. It is
##
## ::
##
##   pcrDigest = H( PCR[s₀] ‖ PCR[s₁] ‖ … ‖ PCR[sₙ] )
##
## over the registers the quote's `TPML_PCR_SELECTION` names, in the order
## that structure enumerates them, where `H` is the hash of the *signing
## scheme* — not the hash of the bank the registers came from. A two-bank
## selection quoted with an SHA-256 scheme digests the SHA-1 values and
## the SHA-256 values, concatenated in list order, under SHA-256.
##
## The enumeration order is therefore a wire fact, and this module takes
## it from the wire:
##
##   1. selections in the order they appear in the `TPML_PCR_SELECTION`;
##   2. within a selection, PCR index ascending;
##   3. PCR *n* is selected when bit *n mod 8* of byte *n div 8* of
##      `pcrSelect` is set — the bitmap is little-endian *within* each
##      byte even though every integer around it is big-endian.
##
## `pcrComposite` consequently refuses to take an order from its caller.
## It is handed the selection and a bag of `(bank, index, value)` triples,
## it checks that the bag is **exactly** the set the selection names — no
## missing register, no extra one, no duplicate — and then it emits them
## in the selection's order. A composite over the right registers in the
## wrong order, or over a superset that happens to contain them, is the
## error this shape is built to make unspellable: it would verify happily
## against itself and against nothing else.
##
## For the same reason a selection that names **no** register at all is
## refused. It is structurally well formed and utterly vacuous — the
## digest of the empty string, identical on every machine in the world,
## and a policy comparing it against a stored copy of itself would pass
## forever.
##
## ## Round-tripping is a property, not a convenience
##
## `serializeAttest(parseAttest(x)) == x` matters because it is the only
## cheap evidence that the parser assigned every byte to the field that
## owns it. A parser that reads a 34-byte name as a 2-byte length plus a
## 32-byte digest, or that swaps `resetCount` and `restartCount`, is
## invisible to a field-by-field test written from the same
## misunderstanding; it is not invisible to a byte-exact re-serialisation
## of a quote a real TPM produced.
##
## It is *not* evidence that the parse is correct in the sense that
## matters to a verifier, and this module does not pretend otherwise:
## round-tripping bytes this code also produced would prove nothing at
## all. The pinned vectors exercising it come from a real TPM and are
## cross-checked field by field against a third-party implementation.
##
## Which is also why `Tpm2Quote` retains `attestBytes` verbatim. A
## signature covers the bytes that arrived, never a re-serialisation of
## them — a re-serialisation is this code's opinion about what the TPM
## meant, and verifying a signature against an opinion is how a codec bug
## becomes a signature-forgery oracle. The re-serialisation exists to be
## *compared*, not to be *verified against*.
##
## ## Mocking
##
## None. Nothing here stands in for a TPM; the module never opens one.

import std/[algorithm, strutils, tables]

import nimcrypto/[hash, sha, sha2]

type
  Tpm2CodecError* = object of CatchableError
    ## Raised for any byte string this codec will not accept as the
    ## structure it was asked to read, and for any structure it will not
    ## write. The message names the structure, the field and the offset.

  TpmAlgId* = distinct uint16
    ## A `TPM_ALG_ID`. Deliberately not an `enum`: the registry is open,
    ## a TPM may carry a bank this codec has never heard of, and an
    ## `enum` with holes would let an unchecked `TpmAlgId(x)` fabricate a
    ## value that is not any of its members. Unknown identifiers are
    ## carried through structurally and refused only where their meaning
    ## is actually needed.

proc `==`*(a, b: TpmAlgId): bool {.borrow.}

const
  # --- algorithm identifiers, TCG Algorithm Registry -----------------
  TpmAlgSha1* = TpmAlgId(0x0004'u16)
  TpmAlgHmac* = TpmAlgId(0x0005'u16)
  TpmAlgSha256* = TpmAlgId(0x000B'u16)
  TpmAlgSha384* = TpmAlgId(0x000C'u16)
  TpmAlgSha512* = TpmAlgId(0x000D'u16)
  TpmAlgNull* = TpmAlgId(0x0010'u16)
  TpmAlgRsassa* = TpmAlgId(0x0014'u16)
  TpmAlgRsapss* = TpmAlgId(0x0016'u16)
  TpmAlgEcdsa* = TpmAlgId(0x0018'u16)

  TpmGeneratedValue* = 0xFF544347'u32
    ## `TPM_GENERATED_VALUE`. The four bytes `0xFF 'T' 'C' 'G'` open every
    ## structure a TPM signed with a restricted key, and no structure a
    ## caller may hand the TPM to sign is permitted to start with them.
    ## That is what makes checking it a genuine validity test rather than
    ## a formality: it is the one field distinguishing "the TPM attested
    ## to this" from "somebody asked the TPM to sign this".

  TpmStAttestQuote* = 0x8018'u16
    ## `TPM_ST_ATTEST_QUOTE`. The `type` field is the union selector for
    ## `attested`, so a structure carrying any other value describes a
    ## payload this codec cannot walk.

  # --- TPM2B maxima, from the reference header's union sizes ---------
  MaxNameBytes* = 66
    ## `sizeof(TPMU_NAME)` — a `TPMT_HA` of the largest digest, i.e. a
    ## 2-byte algorithm identifier plus 64 bytes.
  MaxDataBytes* = 66
    ## `sizeof(TPMT_HA)`, which is what `TPM2B_DATA` is sized to.
  MaxDigestBytes* = 64
    ## `sizeof(TPMU_HA)` — SHA-512.
  MaxEccParamBytes* = 128
    ## `TPM2_MAX_ECC_KEY_BYTES`.
  MaxRsaSigBytes* = 512
    ## `TPM2_MAX_RSA_KEY_BYTES`, i.e. a 4096-bit modulus.

  MaxPcrBanks* = 16
    ## `TPM2_NUM_PCR_BANKS`. A `TPML_PCR_SELECTION` longer than this
    ## describes a TPM that cannot exist.
  PcrSelectMin* = 3
    ## The PC Client Platform TPM Profile fixes `PCR_SELECT_MIN` at 3 —
    ## 24 registers — and the swtpm this codec is pinned against reports
    ## exactly that through `TPM2_PT_PCR_SELECT_MIN`.
  PcrSelectMax* = 4
    ## `TPM2_PCR_SELECT_MAX`. Both bounds are enforced: a `sizeofSelect`
    ## outside them is a length field nothing on this platform produces,
    ## and accepting it would let a bitmap run past the structure.

proc `$`*(a: TpmAlgId): string =
  ## Diagnostics only. Named algorithms get their registry spelling;
  ## everything else gets its identifier, because an operator reading a
  ## refusal needs the number to look it up.
  case uint16(a)
  of 0x0004'u16: "sha1"
  of 0x0005'u16: "hmac"
  of 0x000B'u16: "sha256"
  of 0x000C'u16: "sha384"
  of 0x000D'u16: "sha512"
  of 0x0010'u16: "null"
  of 0x0014'u16: "rsassa"
  of 0x0016'u16: "rsapss"
  of 0x0018'u16: "ecdsa"
  else: "0x" & toHex(uint16(a), 4).toLowerAscii

proc digestSize*(alg: TpmAlgId): int =
  ## Bytes in a digest of `alg`, or `0` when `alg` is not a hash this
  ## codec can compute. Zero is not an error here — a bank whose digest
  ## length is unknown parses fine and only becomes a problem when
  ## somebody asks for a composite over it.
  case uint16(alg)
  of 0x0004'u16: 20
  of 0x000B'u16: 32
  of 0x000C'u16: 48
  of 0x000D'u16: 64
  else: 0

proc digestOf(alg: TpmAlgId; data: string): string =
  ## The raw digest bytes. Private: the composite is the only caller, and
  ## a general-purpose hash front door here would invite this module to
  ## grow a crypto surface it has no business owning.
  case uint16(alg)
  of 0x0004'u16:
    let d = sha1.digest(data)
    result = newString(20)
    for i in 0 ..< 20: result[i] = char(d.data[i])
  of 0x000B'u16:
    let d = sha256.digest(data)
    result = newString(32)
    for i in 0 ..< 32: result[i] = char(d.data[i])
  of 0x000C'u16:
    let d = sha384.digest(data)
    result = newString(48)
    for i in 0 ..< 48: result[i] = char(d.data[i])
  of 0x000D'u16:
    let d = sha512.digest(data)
    result = newString(64)
    for i in 0 ..< 64: result[i] = char(d.data[i])
  else:
    raise newException(Tpm2CodecError,
      "cannot digest under algorithm " & $alg & "; this codec computes " &
      "sha1, sha256, sha384 and sha512")

# ---------------------------------------------------------------------
# The cursor
# ---------------------------------------------------------------------

type
  Tpm2Reader* = object
    ## A bounds-checked cursor over one structure's bytes.
    ##
    ## Public because the event-log reader above this module walks the
    ## same `TPM2B`/`TPML` shapes and must not grow a second, differently
    ## hardened, copy of these checks.
    data: string
    pos: int
    structure: string

  Tpm2Writer* = object
    ## The mirror of `Tpm2Reader`. Every write is unconditional — a
    ## writer's inputs come from this process, not from the wire — except
    ## the length bounds, which are checked because a structure this code
    ## would emit and then refuse to read is a bug worth catching on the
    ## way out.
    data: string
    structure: string

proc initTpm2Reader*(data: string; structure: string): Tpm2Reader =
  ## `structure` is the name every refusal from this cursor will carry.
  Tpm2Reader(data: data, pos: 0, structure: structure)

proc initTpm2Writer*(structure: string): Tpm2Writer =
  Tpm2Writer(data: "", structure: structure)

proc remaining*(r: Tpm2Reader): int =
  ## Bytes not yet consumed.
  r.data.len - r.pos

proc offset*(r: Tpm2Reader): int =
  ## Where the next read starts. Reported in refusals.
  r.pos

proc bytes*(w: Tpm2Writer): string =
  ## What has been written so far.
  w.data

proc need(r: var Tpm2Reader; field: string; n: int) =
  if n > r.remaining:
    raise newException(Tpm2CodecError,
      r.structure & ": field " & field & " needs " & $n & " byte" &
      (if n == 1: "" else: "s") & " at offset " & $r.pos & ", but only " &
      $r.remaining & " remain in a " & $r.data.len & "-byte structure")

proc readU8*(r: var Tpm2Reader; field: string): uint8 =
  r.need(field, 1)
  result = uint8(r.data[r.pos])
  inc r.pos

proc readU16*(r: var Tpm2Reader; field: string): uint16 =
  r.need(field, 2)
  result = (uint16(uint8(r.data[r.pos])) shl 8) or uint16(uint8(r.data[r.pos + 1]))
  r.pos += 2

proc readU32*(r: var Tpm2Reader; field: string): uint32 =
  r.need(field, 4)
  result = 0'u32
  for i in 0 ..< 4:
    result = (result shl 8) or uint32(uint8(r.data[r.pos + i]))
  r.pos += 4

proc readU64*(r: var Tpm2Reader; field: string): uint64 =
  r.need(field, 8)
  result = 0'u64
  for i in 0 ..< 8:
    result = (result shl 8) or uint64(uint8(r.data[r.pos + i]))
  r.pos += 8

proc readBytes*(r: var Tpm2Reader; field: string; n: int): string =
  if n < 0:
    raise newException(Tpm2CodecError,
      r.structure & ": field " & field & " asked for " & $n & " bytes")
  r.need(field, n)
  result = r.data[r.pos ..< r.pos + n]
  r.pos += n

proc readAlg*(r: var Tpm2Reader; field: string): TpmAlgId =
  TpmAlgId(r.readU16(field))

proc readTpm2b*(r: var Tpm2Reader; field: string; maxLen: int): string =
  ## A `TPM2B_*`: `UINT16` size, then exactly that many bytes.
  ##
  ## `maxLen` is the spec's ceiling for this particular `TPM2B` variant,
  ## and it is checked BEFORE the remaining-bytes check so that an
  ## over-long declaration inside a large buffer is refused as what it is
  ## rather than surviving because the buffer happened to be big enough.
  let declared = int(r.readU16(field & ".size"))
  if declared > maxLen:
    raise newException(Tpm2CodecError,
      r.structure & ": field " & field & " declares " & $declared &
      " bytes at offset " & $(r.pos - 2) & ", but a " & field &
      " carries at most " & $maxLen)
  result = r.readBytes(field & ".buffer", declared)

proc finish*(r: var Tpm2Reader) =
  ## Assert the structure is exactly as long as it said it was.
  ##
  ## Called at the end of every top-level parse. Without it a quote with
  ## bytes appended parses successfully, and "the TPM signed these bytes"
  ## stops being a statement about the bytes that arrived.
  if r.remaining != 0:
    raise newException(Tpm2CodecError,
      r.structure & ": " & $r.remaining & " trailing byte" &
      (if r.remaining == 1: "" else: "s") & " after a complete structure " &
      "ending at offset " & $r.pos & "; a structure with anything appended " &
      "is not the structure that was signed")

proc writeU8*(w: var Tpm2Writer; v: uint8) =
  w.data.add char(v)

proc writeU16*(w: var Tpm2Writer; v: uint16) =
  w.data.add char(uint8(v shr 8))
  w.data.add char(uint8(v and 0xFF'u16))

proc writeU32*(w: var Tpm2Writer; v: uint32) =
  for i in countdown(3, 0):
    w.data.add char(uint8((v shr (8 * i)) and 0xFF'u32))

proc writeU64*(w: var Tpm2Writer; v: uint64) =
  for i in countdown(7, 0):
    w.data.add char(uint8((v shr (8 * i)) and 0xFF'u64))

proc writeAlg*(w: var Tpm2Writer; a: TpmAlgId) =
  w.writeU16(uint16(a))

proc writeBytes*(w: var Tpm2Writer; b: string) =
  w.data.add b

proc writeTpm2b*(w: var Tpm2Writer; field: string; b: string; maxLen: int) =
  if b.len > maxLen:
    raise newException(Tpm2CodecError,
      w.structure & ": field " & field & " holds " & $b.len &
      " bytes, but a " & field & " carries at most " & $maxLen)
  w.writeU16(uint16(b.len))
  w.data.add b

# ---------------------------------------------------------------------
# TPMS_PCR_SELECTION / TPML_PCR_SELECTION
# ---------------------------------------------------------------------

type
  TpmsPcrSelection* = object
    ## One bank's worth of selected registers.
    hashAlg*: TpmAlgId
      ## The PCR bank. Carried verbatim even when unrecognised: a codec
      ## that refused an unknown bank could not read a quote from a TPM
      ## with one, and reading it is harmless — only `pcrComposite`
      ## needs to know what the algorithm means.
    select*: string
      ## `sizeofSelect` raw bitmap bytes. PCR *n* is selected when bit
      ## *n mod 8* of byte *n div 8* is set.

  TpmlPcrSelection* = object
    selections*: seq[TpmsPcrSelection]

  TpmsClockInfo* = object
    clock*: uint64
    resetCount*: uint32
    restartCount*: uint32
    safe*: bool
      ## `TPMI_YES_NO`, which the wire permits to be exactly 0 or 1. Any
      ## other byte is refused: a `bool` that silently absorbed 0x02
      ## would not re-serialise to the bytes that were signed.

  TpmsQuoteInfo* = object
    pcrSelect*: TpmlPcrSelection
    pcrDigest*: string
      ## RAW digest bytes, not hex. This is the composite — see the
      ## module header.

  TpmsAttest* = object
    ## The structure a TPM signs. Only the `quote` variant of `attested`
    ## is decoded; see `parseAttest`.
    magic*: uint32
    attestType*: uint16
    qualifiedSigner*: string
      ## `TPM2B_NAME` of the signing key, RAW bytes. Its leading two
      ## bytes are the name algorithm, which is why a 32-byte SHA-256
      ## name is 34 bytes on the wire.
    extraData*: string
      ## `qualifyingData` as the caller supplied it — for this system,
      ## the 64 bytes the binding discipline produced.
    clockInfo*: TpmsClockInfo
    firmwareVersion*: uint64
    quote*: TpmsQuoteInfo

  TpmtSignatureKind* = enum
    tskRsa
    tskEcc

  TpmtSignature* = object
    ## A tagged union over `sigAlg`. The two arms are the two shapes a
    ## quote from an attestation key comes in.
    sigAlg*: TpmAlgId
    hashAlg*: TpmAlgId
      ## The scheme's hash. It is also the hash of the composite in the
      ## attest structure this signature covers, which is the only place
      ## a verifier can learn that algorithm from.
    case kind*: TpmtSignatureKind
    of tskRsa:
      sig*: string
        ## `TPM2B_PUBLIC_KEY_RSA`, RAW.
    of tskEcc:
      signatureR*: string
      signatureS*: string
        ## Two `TPM2B_ECC_PARAMETER`s, RAW and unpadded. Note this is
        ## NOT the DER `SEQUENCE` an X.509 toolchain expects; converting
        ## is a caller's job and not a codec's.

  Tpm2Quote* = object
    ## One `TPM2_Quote` answer, whole.
    attestBytes*: string
      ## The attest structure EXACTLY as it arrived. See the module
      ## header: the signature covers these bytes and never a
      ## re-serialisation of them.
    attest*: TpmsAttest
    signatureBytes*: string
    signature*: TpmtSignature

proc selectedPcrs*(sel: TpmlPcrSelection): seq[tuple[bank: TpmAlgId, index: int]] =
  ## The registers a selection names, in the order the composite digests
  ## them: list order across banks, index ascending within a bank.
  ##
  ## This is the single definition of that order. Nothing else in the
  ## tree is allowed a second opinion about it, because a composite over
  ## the right registers in a different order is a digest that matches
  ## nothing and explains nothing.
  result = @[]
  for s in sel.selections:
    for byteIndex in 0 ..< s.select.len:
      let b = uint8(s.select[byteIndex])
      for bit in 0 ..< 8:
        if (b and uint8(1'u8 shl bit)) != 0'u8:
          result.add (bank: s.hashAlg, index: byteIndex * 8 + bit)

proc readPcrSelection(r: var Tpm2Reader): TpmlPcrSelection =
  let count = r.readU32("pcrSelect.count")
  if count > uint32(MaxPcrBanks):
    raise newException(Tpm2CodecError,
      "TPML_PCR_SELECTION: declares " & $count & " banks at offset " &
      $(r.offset - 4) & ", but a TPM carries at most " & $MaxPcrBanks)
  result = TpmlPcrSelection(selections: @[])
  var seen: seq[TpmAlgId] = @[]
  for i in 0 ..< int(count):
    let alg = r.readAlg("pcrSelections[" & $i & "].hash")
    if alg in seen:
      raise newException(Tpm2CodecError,
        "TPML_PCR_SELECTION: bank " & $alg & " appears twice, at " &
        "selection " & $i & "; a TPM merges the selections for one bank, " &
        "so two of them would digest a register twice and call it two " &
        "registers")
    seen.add alg
    let sizeofSelect = int(r.readU8("pcrSelections[" & $i & "].sizeofSelect"))
    if sizeofSelect < PcrSelectMin or sizeofSelect > PcrSelectMax:
      raise newException(Tpm2CodecError,
        "TPML_PCR_SELECTION: selection " & $i & " declares a " &
        $sizeofSelect & "-byte bitmap at offset " & $(r.offset - 1) &
        "; the platform profile fixes it between " & $PcrSelectMin &
        " and " & $PcrSelectMax)
    let select = r.readBytes("pcrSelections[" & $i & "].pcrSelect", sizeofSelect)
    result.selections.add TpmsPcrSelection(hashAlg: alg, select: select)

proc writePcrSelection(w: var Tpm2Writer; sel: TpmlPcrSelection) =
  if sel.selections.len > MaxPcrBanks:
    raise newException(Tpm2CodecError,
      "TPML_PCR_SELECTION: " & $sel.selections.len & " banks, at most " &
      $MaxPcrBanks & " are carried")
  w.writeU32(uint32(sel.selections.len))
  for i, s in sel.selections:
    w.writeAlg(s.hashAlg)
    if s.select.len < PcrSelectMin or s.select.len > PcrSelectMax:
      raise newException(Tpm2CodecError,
        "TPML_PCR_SELECTION: selection " & $i & " holds a " &
        $s.select.len & "-byte bitmap; the platform profile fixes it " &
        "between " & $PcrSelectMin & " and " & $PcrSelectMax)
    w.writeU8(uint8(s.select.len))
    w.writeBytes(s.select)

# ---------------------------------------------------------------------
# TPMS_ATTEST
# ---------------------------------------------------------------------

proc parseAttest*(data: string): TpmsAttest =
  ## Read a `TPMS_ATTEST` carrying a quote.
  ##
  ## The magic and the attestation type are checked before anything else
  ## is read. The magic because it is the field that says a TPM produced
  ## this at all; the type because it selects the union at the end, so a
  ## parser that guessed it would be walking a payload of a shape it does
  ## not know.
  var r = initTpm2Reader(data, "TPMS_ATTEST")
  result.magic = r.readU32("magic")
  if result.magic != TpmGeneratedValue:
    raise newException(Tpm2CodecError,
      "TPMS_ATTEST: magic is 0x" & toHex(result.magic, 8).toLowerAscii &
      ", not TPM_GENERATED_VALUE (0x" &
      toHex(TpmGeneratedValue, 8).toLowerAscii &
      "); these bytes were not produced by a TPM signing with a " &
      "restricted key")
  result.attestType = r.readU16("type")
  if result.attestType != TpmStAttestQuote:
    raise newException(Tpm2CodecError,
      "TPMS_ATTEST: type is 0x" & toHex(result.attestType, 4).toLowerAscii &
      ", not TPM_ST_ATTEST_QUOTE (0x" &
      toHex(TpmStAttestQuote, 4).toLowerAscii &
      "); this codec reads quotes and cannot walk another attestation " &
      "structure's payload")
  result.qualifiedSigner = r.readTpm2b("qualifiedSigner", MaxNameBytes)
  result.extraData = r.readTpm2b("extraData", MaxDataBytes)
  result.clockInfo.clock = r.readU64("clockInfo.clock")
  result.clockInfo.resetCount = r.readU32("clockInfo.resetCount")
  result.clockInfo.restartCount = r.readU32("clockInfo.restartCount")
  let safe = r.readU8("clockInfo.safe")
  if safe > 1'u8:
    raise newException(Tpm2CodecError,
      "TPMS_ATTEST: clockInfo.safe is " & $safe & " at offset " &
      $(r.offset - 1) & "; a TPMI_YES_NO is 0 or 1")
  result.clockInfo.safe = safe == 1'u8
  result.firmwareVersion = r.readU64("firmwareVersion")
  result.quote.pcrSelect = readPcrSelection(r)
  result.quote.pcrDigest = r.readTpm2b("pcrDigest", MaxDigestBytes)
  r.finish()

  if selectedPcrs(result.quote.pcrSelect).len == 0:
    raise newException(Tpm2CodecError,
      "TPMS_ATTEST: the quote's PCR selection names no register; its " &
      "digest is the digest of the empty string, which is the same on " &
      "every machine and attests to nothing")

proc serializeAttest*(a: TpmsAttest): string =
  ## Write a `TPMS_ATTEST` back. Byte-for-byte identical to what
  ## `parseAttest` accepted — see the module header for why that is the
  ## property worth having.
  var w = initTpm2Writer("TPMS_ATTEST")
  w.writeU32(a.magic)
  w.writeU16(a.attestType)
  w.writeTpm2b("qualifiedSigner", a.qualifiedSigner, MaxNameBytes)
  w.writeTpm2b("extraData", a.extraData, MaxDataBytes)
  w.writeU64(a.clockInfo.clock)
  w.writeU32(a.clockInfo.resetCount)
  w.writeU32(a.clockInfo.restartCount)
  w.writeU8(if a.clockInfo.safe: 1'u8 else: 0'u8)
  w.writeU64(a.firmwareVersion)
  writePcrSelection(w, a.quote.pcrSelect)
  w.writeTpm2b("pcrDigest", a.quote.pcrDigest, MaxDigestBytes)
  result = w.bytes

# ---------------------------------------------------------------------
# TPMT_SIGNATURE
# ---------------------------------------------------------------------

proc parseSignature*(data: string): TpmtSignature =
  ## Read a `TPMT_SIGNATURE`.
  ##
  ## The selector is read first and an unrecognised one is refused, not
  ## skipped: the payload's length is a function of the selector, so
  ## there is no "rest of the structure" to skip to.
  var r = initTpm2Reader(data, "TPMT_SIGNATURE")
  let sigAlg = r.readAlg("sigAlg")
  if sigAlg == TpmAlgRsassa or sigAlg == TpmAlgRsapss:
    let hashAlg = r.readAlg("signature.rsassa.hash")
    let sig = r.readTpm2b("signature.rsassa.sig", MaxRsaSigBytes)
    result = TpmtSignature(sigAlg: sigAlg, hashAlg: hashAlg,
                           kind: tskRsa, sig: sig)
  elif sigAlg == TpmAlgEcdsa:
    let hashAlg = r.readAlg("signature.ecdsa.hash")
    let sigR = r.readTpm2b("signature.ecdsa.signatureR", MaxEccParamBytes)
    let sigS = r.readTpm2b("signature.ecdsa.signatureS", MaxEccParamBytes)
    result = TpmtSignature(sigAlg: sigAlg, hashAlg: hashAlg,
                           kind: tskEcc, signatureR: sigR, signatureS: sigS)
  else:
    raise newException(Tpm2CodecError,
      "TPMT_SIGNATURE: signature algorithm " & $sigAlg & " is not one " &
      "this codec can walk; the payload's shape follows the algorithm, " &
      "so an unrecognised one has no known length")
  if digestSize(result.hashAlg) == 0:
    raise newException(Tpm2CodecError,
      "TPMT_SIGNATURE: scheme hash " & $result.hashAlg & " is not a " &
      "digest this codec knows; it is also the algorithm of the PCR " &
      "composite the signature covers, so a quote carrying it could not " &
      "be checked")
  if result.kind == tskRsa and result.sig.len == 0:
    raise newException(Tpm2CodecError,
      "TPMT_SIGNATURE: an RSA signature of zero bytes")
  if result.kind == tskEcc and
      (result.signatureR.len == 0 or result.signatureS.len == 0):
    raise newException(Tpm2CodecError,
      "TPMT_SIGNATURE: an ECDSA signature with an empty r or s")
  r.finish()

proc serializeSignature*(s: TpmtSignature): string =
  var w = initTpm2Writer("TPMT_SIGNATURE")
  w.writeAlg(s.sigAlg)
  w.writeAlg(s.hashAlg)
  case s.kind
  of tskRsa:
    w.writeTpm2b("signature.rsassa.sig", s.sig, MaxRsaSigBytes)
  of tskEcc:
    w.writeTpm2b("signature.ecdsa.signatureR", s.signatureR, MaxEccParamBytes)
    w.writeTpm2b("signature.ecdsa.signatureS", s.signatureS, MaxEccParamBytes)
  result = w.bytes

# ---------------------------------------------------------------------
# The quote
# ---------------------------------------------------------------------

proc parseQuote*(attestBytes, signatureBytes: string): Tpm2Quote =
  ## Read both halves of a `TPM2_Quote` answer and keep the originals.
  result.attestBytes = attestBytes
  result.attest = parseAttest(attestBytes)
  result.signatureBytes = signatureBytes
  result.signature = parseSignature(signatureBytes)

proc qualifyingData*(q: Tpm2Quote): string =
  ## The bytes the instance bound into this quote — for this system, the
  ## 64 the binding discipline produced. Named as the TPM names them
  ## rather than as the structure field is spelled, because
  ## `extraData` reads like a place to put something optional.
  q.attest.extraData

proc compositeAlg*(q: Tpm2Quote): TpmAlgId =
  ## The hash the quote's `pcrDigest` was computed under.
  ##
  ## It is the SIGNING SCHEME's hash, not any bank's. A quote whose
  ## selection is entirely SHA-1 still has a SHA-256 composite when the
  ## key signs with SHA-256, and reaching for the bank instead is the
  ## mistake this accessor exists to stop anyone making twice.
  q.signature.hashAlg

# ---------------------------------------------------------------------
# The PCR composite
# ---------------------------------------------------------------------

type
  SelectedPcr* = object
    ## One register's contribution to a composite.
    bank*: TpmAlgId
    index*: int
    value*: string
      ## RAW digest bytes, exactly `digestSize(bank)` long.

proc selectedPcr*(bank: TpmAlgId; index: int; value: string): SelectedPcr =
  SelectedPcr(bank: bank, index: index, value: value)

proc pcrComposite*(compositeAlg: TpmAlgId; sel: TpmlPcrSelection;
                   values: openArray[SelectedPcr]): string =
  ## Recompute a quote's `pcrDigest` from the register values.
  ##
  ## Returns RAW digest bytes, to compare against `pcrDigest` directly.
  ##
  ## The ORDER is taken from `sel` and never from `values` — see the
  ## module header. `values` is checked to be exactly the set `sel`
  ## names: a missing register, an extra one, or the same one twice is a
  ## refusal, because each of those silently produces a digest that is
  ## right about nothing.
  if digestSize(compositeAlg) == 0:
    raise newException(Tpm2CodecError,
      "PCR composite: " & $compositeAlg & " is not a digest this codec " &
      "computes")

  let want = selectedPcrs(sel)
  if want.len == 0:
    raise newException(Tpm2CodecError,
      "PCR composite: the selection names no register; the result would " &
      "be the digest of the empty string, identical on every machine")

  var have = initTable[(uint16, int), string]()
  for v in values:
    let key = (uint16(v.bank), v.index)
    if key in have:
      raise newException(Tpm2CodecError,
        "PCR composite: PCR " & $v.index & " of bank " & $v.bank &
        " was supplied twice")
    let bankDigestLen = digestSize(v.bank)
    if bankDigestLen == 0:
      raise newException(Tpm2CodecError,
        "PCR composite: PCR " & $v.index & " is in bank " & $v.bank &
        ", whose digest length this codec does not know")
    if v.value.len != bankDigestLen:
      raise newException(Tpm2CodecError,
        "PCR composite: PCR " & $v.index & " of bank " & $v.bank &
        " carries " & $v.value.len & " bytes; a " & $v.bank &
        " register is " & $bankDigestLen)
    have[key] = v.value

  var preimage = ""
  for w in want:
    let key = (uint16(w.bank), w.index)
    if key notin have:
      raise newException(Tpm2CodecError,
        "PCR composite: the selection names PCR " & $w.index & " of bank " &
        $w.bank & ", and no value for it was supplied; a composite over " &
        "a subset of the selected registers matches nothing")
    preimage.add have[key]

  if have.len != want.len:
    var extra: seq[string] = @[]
    var selected = initTable[(uint16, int), bool]()
    for w in want: selected[(uint16(w.bank), w.index)] = true
    for k in have.keys:
      if k notin selected:
        extra.add $TpmAlgId(k[0]) & ":" & $k[1]
    sort(extra)
    raise newException(Tpm2CodecError,
      "PCR composite: " & $(have.len - want.len) & " value" &
      (if have.len - want.len == 1: " was" else: "s were") &
      " supplied that the selection does not name (" & extra.join(", ") &
      "); a composite over a superset of the selected registers is not " &
      "the quoted one")

  result = digestOf(compositeAlg, preimage)

proc pcrCompositeMatches*(q: Tpm2Quote; values: openArray[SelectedPcr]): bool =
  ## Whether the register values recompute to the composite this quote
  ## carries.
  ##
  ## Deliberately NOT a verification: it says the quoted digest is
  ## explained by these values, and says nothing about whether the quote
  ## is authentic or the values are acceptable. A caller that has not
  ## checked the signature has learned only that the machine is
  ## internally consistent about numbers it chose.
  pcrComposite(compositeAlg(q), q.attest.quote.pcrSelect, values) ==
    q.attest.quote.pcrDigest
