## Parser hardening: what the TPM 2.0 codec refuses.
##
## ## Why this is the gate that matters
##
## The bytes this codec reads arrive from the machine whose
## trustworthiness is the open question, and they are length-prefixed. A
## TLV parser that trusts its length fields is a tool for whoever wrote
## them. The failure to be afraid of is not a crash — it is an
## **under-read**: a declared length longer than the input, satisfied
## with whatever bytes are there, after which every later field is read
## from the wrong offset and the parse reports success. The structure
## that comes out is not the structure the TPM signed, and nothing
## downstream can tell.
##
## So every case below is a refusal, and the refusals come in four
## shapes:
##
##   1. **Truncation.** Every prefix of every pinned real vector, at
##      every length, must be refused. Not a sample — the whole sweep, so
##      there is no field boundary where a short read happens to be
##      tolerated. A `TPM2B` whose size field is present but whose buffer
##      is cut in half is the exact shape of an under-read.
##   2. **Over-long.** Bytes appended to a complete structure. A parser
##      that stops when it has what it wanted accepts these, and "the TPM
##      signed these bytes" stops being a statement about the bytes that
##      arrived.
##   3. **Inconsistent length.** A length field pointing past the end,
##      and — separately, because they fail through different checks — a
##      length field that fits inside a large enough buffer but exceeds
##      what the structure may carry. The second is the subtle one: pad
##      the input and a 256-byte `TPM2B_DIGEST` is entirely readable. It
##      just swallows every field after it.
##   4. **Structurally valid but semantically impossible.** A magic that
##      is not `TPM_GENERATED_VALUE`, an attestation type whose payload
##      this codec cannot walk, a `TPMI_YES_NO` of 2, a bank listed
##      twice, a bitmap that selects nothing.
##
## ## The positive control, and why it is not decoration
##
## A parser that raises on everything passes every case above. The last
## test re-parses all seven unmutated vectors and checks they still come
## out right, so each refusal above is shown to be about *what changed*.
##
## ## Every mutation is checked to bite
##
## Each patch asserts the byte it is about to overwrite is the byte it
## expects. A mutation that silently became a no-op — because a vector
## moved, or an offset was mistyped — is a test case that passes while
## testing nothing, and this file is long enough for that to happen
## unnoticed.
##
## ## What this does not prove
##
## Nothing here says the codec parses *correctly* — that is
## `t_tpm2_structure_vectors`. Nothing here verifies a signature. And a
## refusal is not a guarantee of memory safety: it is a guarantee that
## these particular inputs produce a named error rather than a structure.
##
## ## Mocking
##
## None.

import std/[strutils, unittest]

import repro_attest
import ./tpm2_quote_vectors

# ---------------------------------------------------------------------
# Offsets inside the pinned 177-byte attest structure. Written out so a
# reader can check them against the encoding rather than trusting them.
# ---------------------------------------------------------------------

const
  OffMagic = 0            # UINT32
  OffType = 4             # UINT16
  OffNameSize = 6         # UINT16, 0x0022
  OffExtraDataSize = 42   # UINT16, 0x0040
  OffSafe = 124           # UINT8, 0x01
  OffBankCount = 133      # UINT32, 0x00000001
  OffBankAlg = 137        # UINT16, 0x000b
  OffSizeofSelect = 139   # UINT8, 0x03
  OffSelect = 140         # 3 bytes
  OffDigestSize = 143     # UINT16, 0x0020

proc patch(raw: string; offset: int; expectHex, newHex: string): string =
  ## Overwrite bytes, refusing to do so unless what is there is what the
  ## caller said was there. See the header: a mutation that does not
  ## mutate is a case that cannot fail.
  let expect = unhex(expectHex)
  let replacement = unhex(newHex)
  doAssert expect.len == replacement.len,
    "a patch must preserve length, or it is two mutations"
  doAssert offset + expect.len <= raw.len, "patch runs off the end"
  doAssert raw[offset ..< offset + expect.len] == expect,
    "patch at offset " & $offset & " expected " & expectHex & " but found " &
      toHexLower(raw[offset ..< offset + expect.len])
  result = raw
  result[offset ..< offset + replacement.len] = replacement

proc refusal(body: proc (): void): string =
  ## Run `body`, require it to raise `Tpm2CodecError`, and hand back the
  ## message. Requiring the TYPE matters: an `IndexDefect` escaping from
  ## an unchecked slice would also stop the parse, and would also be the
  ## bug this file exists to find.
  try:
    body()
  except Tpm2CodecError as e:
    return e.msg
  except CatchableError as e:
    return "WRONG-EXCEPTION-TYPE: " & $e.name & ": " & e.msg
  return "NO-REFUSAL"

proc attestRefusal(bytes: string): string =
  refusal(proc () = discard parseAttest(bytes))

proc signatureRefusal(bytes: string): string =
  refusal(proc () = discard parseSignature(bytes))

proc isRefusal(msg: string): bool =
  msg != "NO-REFUSAL" and not msg.startsWith("WRONG-EXCEPTION-TYPE")

let rsaAttest = unhex(QuoteVectors[0].attestHex)
let eccAttest = unhex(QuoteVectors[1].attestHex)
let twoBankAttest = unhex(QuoteVectors[4].attestHex)
let rsaSig = unhex(QuoteVectors[0].signatureHex)
let eccSig = unhex(QuoteVectors[1].signatureHex)

suite "TPM2 codec refuses malformed structures":

  test "t_tpm2_codec_rejects_malformed":

    # -----------------------------------------------------------------
    # 1. Truncation, exhaustively.
    # -----------------------------------------------------------------
    var truncationsChecked = 0
    for v in QuoteVectors:
      let attest = unhex(v.attestHex)
      for n in 0 ..< attest.len:
        let msg = attestRefusal(attest[0 ..< n])
        check isRefusal(msg)
        inc truncationsChecked
      let sig = unhex(v.signatureHex)
      for n in 0 ..< sig.len:
        let msg = signatureRefusal(sig[0 ..< n])
        check isRefusal(msg)
        inc truncationsChecked
    # 7 attests (5 × 177 + 183 + 209) plus 7 signatures
    # (2 × 262 + 5 × 72) — stated so a sweep that quietly stopped early
    # is visible.
    check truncationsChecked == (5 * 177 + 183 + 209) + (2 * 262 + 5 * 72)

    # The empty string is in that sweep, but it is worth naming: a codec
    # that returned a zero-valued structure for no input at all would be
    # the worst version of this bug.
    check isRefusal(attestRefusal(""))
    check isRefusal(signatureRefusal(""))

    # -----------------------------------------------------------------
    # 2. Over-long.
    # -----------------------------------------------------------------
    for extra in [1, 2, 64, 1024]:
      let padded = rsaAttest & repeat('\0', extra)
      let msg = attestRefusal(padded)
      check isRefusal(msg)
      check "trailing byte" in msg
      check isRefusal(signatureRefusal(rsaSig & repeat('\0', extra)))
      check isRefusal(signatureRefusal(eccSig & repeat('\0', extra)))
    # A single NON-zero byte too, so nothing can be excused as padding.
    check isRefusal(attestRefusal(rsaAttest & "\xff"))

    # -----------------------------------------------------------------
    # 3a. A length field pointing past the end of the input.
    # -----------------------------------------------------------------
    block:
      # qualifiedSigner claims 66 bytes (the maximum, so the ceiling
      # check passes) where 34 live. Everything after it is then read
      # from 32 bytes too far along.
      let m = attestRefusal(patch(rsaAttest, OffNameSize, "0022", "0042"))
      check isRefusal(m)
    block:
      # extraData claims 65, one more than it holds.
      let m = attestRefusal(patch(rsaAttest, OffExtraDataSize, "0040", "0041"))
      check isRefusal(m)
    block:
      # pcrDigest claims 64 where 32 remain: the classic under-read, and
      # the message has to be about the buffer rather than the ceiling,
      # because 64 IS the ceiling.
      let m = attestRefusal(patch(rsaAttest, OffDigestSize, "0020", "0040"))
      check isRefusal(m)
      check "only" in m and "remain" in m

    # -----------------------------------------------------------------
    # 3b. A length field that FITS, and is still refused. The input is
    #     padded so the remaining-bytes check cannot be what catches it;
    #     only the structure's own ceiling can.
    # -----------------------------------------------------------------
    block:
      let padded = rsaAttest & repeat('\0', 1024)
      let m = attestRefusal(patch(padded, OffDigestSize, "0020", "0100"))
      check isRefusal(m)
      check "carries at most" in m
      check "64" in m
    block:
      let padded = rsaAttest & repeat('\0', 1024)
      let m = attestRefusal(patch(padded, OffNameSize, "0022", "0100"))
      check isRefusal(m)
      check "carries at most" in m
    block:
      # TPM2B_PUBLIC_KEY_RSA tops out at 512; 513 fits the padded buffer.
      let padded = rsaSig & repeat('\0', 1024)
      let m = signatureRefusal(patch(padded, 4, "0100", "0201"))
      check isRefusal(m)
      check "carries at most" in m
    block:
      # TPM2B_ECC_PARAMETER tops out at 128.
      let padded = eccSig & repeat('\0', 1024)
      let m = signatureRefusal(patch(padded, 4, "0020", "0081"))
      check isRefusal(m)
      check "carries at most" in m

    # -----------------------------------------------------------------
    # 3c. The TPML count, which is a length field for a variable number
    #     of variable-length elements and therefore the most expensive
    #     one to trust.
    # -----------------------------------------------------------------
    block:
      let m = attestRefusal(patch(rsaAttest, OffBankCount, "00000001", "ffffffff"))
      check isRefusal(m)
      check "at most" in m
    block:
      let m = attestRefusal(patch(rsaAttest, OffBankCount, "00000001", "00000011"))
      check isRefusal(m)     # 17 banks
      check "at most" in m
    block:
      # Two banks declared, one supplied.
      let m = attestRefusal(patch(rsaAttest, OffBankCount, "00000001", "00000002"))
      check isRefusal(m)
    block:
      # One bank declared where two are supplied: the second selection
      # then looks like trailing bytes, which it is.
      let m = attestRefusal(patch(twoBankAttest, OffBankCount, "00000002", "00000001"))
      check isRefusal(m)
      check "trailing byte" in m

    # -----------------------------------------------------------------
    # 3d. sizeofSelect. A bitmap length the platform never emits, in
    #     both directions, including the zero-length one that would make
    #     a selection select nothing without saying so.
    #
    #     THIS BLOCK WAS FOUND UNFALSIFIABLE AND REWRITTEN. Its first
    #     form only overwrote the length byte of a real vector and
    #     checked that the parse failed. Every one of those inputs fails
    #     for a DIFFERENT reason — the bitmap then runs into the
    #     pcrDigest, whose size field is read from the wrong offset and
    #     lands outside TPM2B_DIGEST's ceiling, or the structure ends
    #     short, or bytes are left over. Deleting the bounds check
    #     entirely left the whole block green. Two things fix it: the
    #     refusal must NAME the bitmap rule, and the structure must
    #     otherwise be CONSISTENT, so that nothing else has grounds to
    #     object.
    # -----------------------------------------------------------------
    proc attestWithBitmap(sizeofSelectHex, selectHex: string): string =
      ## Rebuild the pinned attest's tail around an arbitrary bitmap
      ## length, keeping every other field self-consistent: one bank,
      ## the declared length equal to the bitmap actually supplied, and
      ## a well-formed 32-byte pcrDigest after it. Any refusal is then
      ## about the bitmap length and nothing else.
      doAssert selectHex.len div 2 == int(unhex(sizeofSelectHex)[0]),
        "the rebuilt structure must declare the bitmap it carries, or " &
        "this case tests inconsistency instead of the bound"
      rsaAttest[0 ..< OffBankCount] & unhex(
        "00000001" & "000b" & sizeofSelectHex & selectHex & "0020" &
        "783228bbaef08e490f5e0323574647d502f59d8a62aad96c3d91e970d7fcfbfe")

    # The control: rebuilt at the legal length, this IS the pinned
    # structure, so the rebuild is not itself the thing being refused.
    check attestWithBitmap("03", "930800") == rsaAttest
    check parseAttest(attestWithBitmap("03", "930800")).magic ==
      TpmGeneratedValue
    # And 4 is inside the bound, so the bound is not "exactly 3".
    check parseAttest(attestWithBitmap("04", "93080000")).quote.pcrSelect.
      selections[0].select.len == 4

    for (sizeHex, selHex) in [("00", ""), ("01", "93"), ("02", "9308"),
                              ("05", "9308000000"),
                              ("ff", repeat("00", 254) & "01")]:
      let m = attestRefusal(attestWithBitmap(sizeHex, selHex))
      check isRefusal(m)
      # The refusal has to be the bitmap rule. Without this line the
      # block passes with the bound deleted — measured, not assumed.
      check "bitmap" in m
      check "platform profile" in m

    # -----------------------------------------------------------------
    # 4. Well formed, and impossible.
    # -----------------------------------------------------------------
    block:
      # One byte of the magic. The structure is otherwise untouched and
      # exactly the right length.
      let m = attestRefusal(patch(rsaAttest, OffMagic, "ff544347", "ff544346"))
      check isRefusal(m)
      check "TPM_GENERATED_VALUE" in m
    block:
      # The magic of a structure a caller could have handed the TPM to
      # sign, rather than one the TPM attested to.
      let m = attestRefusal(patch(rsaAttest, OffMagic, "ff544347", "00000000"))
      check isRefusal(m)
      check "TPM_GENERATED_VALUE" in m
    block:
      # TPM_ST_ATTEST_CERTIFY. A real attestation structure, whose
      # payload is not a quote — so the union selector says this codec
      # cannot walk what follows.
      let m = attestRefusal(patch(rsaAttest, OffType, "8018", "8017"))
      check isRefusal(m)
      check "TPM_ST_ATTEST_QUOTE" in m
    block:
      # TPMI_YES_NO carrying 2. Refused rather than coerced, because a
      # bool that absorbed it would not re-serialise to the signed bytes.
      let m = attestRefusal(patch(rsaAttest, OffSafe, "01", "02"))
      check isRefusal(m)
      check "TPMI_YES_NO" in m
    block:
      # The same bank twice. Structurally fine; it would digest three
      # registers and present them as six.
      let dup = patch(patch(twoBankAttest, OffBankCount, "00000002", "00000002"),
                      OffBankAlg, "0004", "000b")
      let m = attestRefusal(dup)
      check isRefusal(m)
      check "twice" in m
    block:
      # A bitmap that selects nothing. The composite would be the digest
      # of the empty string — the same on every machine on earth.
      let m = attestRefusal(patch(rsaAttest, OffSelect, "930800", "000000"))
      check isRefusal(m)
      check "names no register" in m

    # -----------------------------------------------------------------
    # 5. TPMT_SIGNATURE: a tagged union whose tag decides the length.
    # -----------------------------------------------------------------
    block:
      # TPM_ALG_HMAC. A real algorithm, a real TPMT_SIGNATURE arm, and
      # not one this codec walks — so it is refused rather than skipped,
      # because there is nothing to skip TO.
      let m = signatureRefusal(patch(rsaSig, 0, "0014", "0005"))
      check isRefusal(m)
      check "not one this codec can walk" in m
    block:
      let m = signatureRefusal(patch(rsaSig, 0, "0014", "0000"))
      check isRefusal(m)
    block:
      # RSAPSS is accepted — same shape — so the refusal above is about
      # the shape and not about the codec knowing only one constant.
      let pss = parseSignature(patch(rsaSig, 0, "0014", "0016"))
      check pss.sigAlg == TpmAlgRsapss
      check pss.kind == tskRsa
      check pss.sig.len == 256
    block:
      # A scheme hash the codec cannot compute. It is also the algorithm
      # of the composite the signature covers, so a quote carrying it
      # could never be checked.
      let m = signatureRefusal(patch(eccSig, 2, "000b", "0099"))
      check isRefusal(m)
      check "PCR composite" in m
    block:
      # An ECDSA signature that stops after r.
      let m = signatureRefusal(eccSig[0 ..< 38])
      check isRefusal(m)

    # -----------------------------------------------------------------
    # 6. The composite's own refusals. Each of these would otherwise
    #    produce a digest that is confidently wrong.
    # -----------------------------------------------------------------
    let q = parseQuote(rsaAttest, rsaSig)
    let sel = q.attest.quote.pcrSelect

    proc value(bank: TpmAlgId; index: int): SelectedPcr =
      let name = if bank == TpmAlgSha1: "sha1" else: "sha256"
      let hex = pcrValueHex(name, index)
      doAssert hex.len > 0, "no pinned value for " & name & ":" & $index
      selectedPcr(bank, index, unhex(hex))

    let full = @[value(TpmAlgSha256, 0), value(TpmAlgSha256, 1),
                 value(TpmAlgSha256, 4), value(TpmAlgSha256, 7),
                 value(TpmAlgSha256, 11)]

    proc compositeRefusal(values: seq[SelectedPcr]): string =
      refusal(proc () = discard pcrComposite(TpmAlgSha256, sel, values))

    block:
      # One register short. A composite over a subset matches nothing,
      # and computing one anyway is how a verifier ends up comparing a
      # digest against a digest of a different thing.
      let m = compositeRefusal(full[0 ..< 4])
      check isRefusal(m)
      check "no value for it was supplied" in m
    block:
      # One register too many.
      let m = compositeRefusal(full & @[value(TpmAlgSha256, 8)])
      check isRefusal(m)
      check "does not name" in m
    block:
      # The same register twice — which, with one of the five dropped,
      # even keeps the count right.
      let m = compositeRefusal(full[0 ..< 4] & @[value(TpmAlgSha256, 0)])
      check isRefusal(m)
      check "supplied twice" in m
    block:
      # The right registers, from the wrong bank. Same count, same
      # indices, different values entirely.
      var wrongBank = full
      wrongBank[0] = selectedPcr(TpmAlgSha1, 0, unhex(pcrValueHex("sha1", 0)))
      let m = compositeRefusal(wrongBank)
      check isRefusal(m)
    block:
      # A register value of the wrong length: a SHA-1 digest offered for
      # a SHA-256 bank. Concatenation would silently shorten the
      # preimage by 12 bytes.
      var shortValue = full
      shortValue[2] = selectedPcr(TpmAlgSha256, 4, unhex(pcrValueHex("sha1", 4)))
      let m = compositeRefusal(shortValue)
      check isRefusal(m)
      check "register is 32" in m
    block:
      # A composite algorithm this codec cannot compute.
      let m = refusal(proc () =
        discard pcrComposite(TpmAlgId(0x0099'u16), sel, full))
      check isRefusal(m)
    block:
      # A selection naming nothing, reached directly rather than through
      # a parse, because `parseAttest` refuses it earlier and the
      # composite must refuse it too.
      let empty = TpmlPcrSelection(selections: @[
        TpmsPcrSelection(hashAlg: TpmAlgSha256, select: "\0\0\0")])
      let m = refusal(proc () = discard pcrComposite(TpmAlgSha256, empty, @[]))
      check isRefusal(m)
      check "names no register" in m

  test "t_tpm2_codec_still_accepts_the_real_thing":
    ## The positive control. Without it every case above is satisfied by
    ## a parser that refuses its own input.
    for v in QuoteVectors:
      let q = parseQuote(unhex(v.attestHex), unhex(v.signatureHex))
      check q.attest.magic == TpmGeneratedValue
      check toHexLower(q.attest.quote.pcrDigest) == v.printedPcrDigestHex
      check toHexLower(qualifyingData(q)) == QualifyingDataHex
      check serializeAttest(q.attest) == unhex(v.attestHex)
      check serializeSignature(q.signature) == unhex(v.signatureHex)
      check selectedPcrs(q.attest.quote.pcrSelect).len ==
        v.expectedSelected.len
