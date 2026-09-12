## The TPM 2.0 structure codec, against quotes a real TPM produced.
##
## ## What this case is worth, and what it is not
##
## What this case owes is "parse and re-serialise pinned real quotes
## byte-for-byte". Byte-for-byte round-tripping is a real property — it
## catches every parser that assigns a byte to the wrong field, because
## a writer built from the same misunderstanding puts it back somewhere
## else — but on its own it is also the classic self-confirming test. Run
## it over a vector this codec's own encoder produced and it proves
## exactly nothing: the encoder and the decoder would agree on a format
## neither the TPM nor anyone else speaks.
##
## So the round-trip is only half of each case, and the vectors are not
## this codec's:
##
##   * They come from **swtpm 0.10.1** driven by **tpm2-tools 5.7**, and
##     `tpm2_checkquote` accepted every signature. See
##     `tpm2_quote_vectors` for the full regeneration recipe and for
##     what anchors each field.
##   * Every field the parse produces is compared against **tpm2-tools'
##     own reading of the same bytes** (`tpm2_print -t TPMS_ATTEST`),
##     transcribed into the vector records. A parser that read
##     `resetCount` where `restartCount` lives round-trips perfectly and
##     fails here.
##   * `extraData` is compared against the 64 bytes that were typed on
##     the `tpm2_quote` command line — a value that existed before the
##     TPM did anything and that no implementation on either side of
##     this test computed.
##   * `firmwareVersion` is compared against `tpm2_getcap`'s
##     `TPM2_PT_FIRMWARE_VERSION_1`/`_2`, because it is the one field
##     where `tpm2_print` renders the bytes in the opposite order and is
##     therefore not usable as a cross-check.
##   * The registers the selection names are compared against the `-l`
##     argument, **spelled out by hand** in the vector rather than
##     decoded from the bitmap. That is what pins the bit order inside a
##     bitmap byte, which is the one place this encoding stops being
##     big-endian.
##
## `t_tpm2_signature_shapes` covers `TPMT_SIGNATURE`'s two arms. There is
## no `tpm2_print` type for a bare signature, so its anchor is different:
## the RSA arm's payload must be the exact 256 bytes `tpm2_quote` printed
## on its `sig:` line, and the ECDSA arm's `r` and `s` must be the two
## halves of the integers inside the DER `tpm2_checkquote` printed.
##
## What none of this proves: nothing here verifies a signature, replays
## an event log, or says whether a measurement is acceptable. And swtpm
## is a TPM implementation rather than a discrete chip — a firmware
## quirk of a real one is outside every claim below.
##
## ## Mocking
##
## None.

import std/[strutils, unittest]

import repro_attest
import ./tpm2_quote_vectors

proc bankAlg(name: string): TpmAlgId =
  case name
  of "sha1": TpmAlgSha1
  of "sha256": TpmAlgSha256
  else:
    doAssert false, "the vectors carry no bank called " & name
    TpmAlgNull

suite "TPM2 structure codec against real quotes":

  test "t_tpm2_structure_vectors":
    check QuoteVectors.len == 7

    for v in QuoteVectors:
      let attestBytes = unhex(v.attestHex)
      let sigBytes = unhex(v.signatureHex)

      # A vector that is not the length the TPM's file was would be a
      # transcription error, and every comparison below would then be
      # comparing this file against itself.
      check attestBytes.len in {177, 183, 209}

      let q = parseQuote(attestBytes, sigBytes)

      # --- the half that cannot confirm itself: field by field, against
      #     a different implementation's reading of the same bytes.
      check toLowerAscii(toHex(q.attest.magic, 8)) == v.printedMagicHex
      check q.attest.magic == TpmGeneratedValue
      check toLowerAscii(toHex(q.attest.attestType, 4)) == v.printedTypeHex
      check toHexLower(q.attest.qualifiedSigner) ==
        v.printedQualifiedSignerHex
      check toHexLower(q.attest.extraData) == v.printedExtraDataHex
      check q.attest.clockInfo.clock == v.printedClock
      check q.attest.clockInfo.resetCount == v.printedResetCount
      check q.attest.clockInfo.restartCount == v.printedRestartCount
      check q.attest.clockInfo.safe == v.printedSafe
      check toHexLower(q.attest.quote.pcrDigest) == v.printedPcrDigestHex

      # Not from tpm2_print — see the header.
      check q.attest.firmwareVersion == FirmwareVersion
      check toHexLower(qualifyingData(q)) == QualifyingDataHex
      check qualifyingData(q).len == 64

      # The selection list, as tpm2_print enumerated it.
      check q.attest.quote.pcrSelect.selections.len == v.printedBankAlgIds.len
      for i, s in q.attest.quote.pcrSelect.selections:
        check uint16(s.hashAlg) == v.printedBankAlgIds[i]
        check s.select.len == v.printedSizeofSelect[i]
        check toHexLower(s.select) == v.printedSelectHex[i]

      # The bitmap walk, against the `-l` argument written out by hand.
      let walked = selectedPcrs(q.attest.quote.pcrSelect)
      check walked.len == v.expectedSelected.len
      for i in 0 ..< min(walked.len, v.expectedSelected.len):
        check walked[i].bank == bankAlg(v.expectedSelected[i].bank)
        check walked[i].index == v.expectedSelected[i].index

      # --- the round-trip half.
      check serializeAttest(q.attest) == attestBytes
      check serializeSignature(q.signature) == sigBytes

      # And the originals are retained rather than reconstructed: a
      # signature covers the bytes that arrived.
      check q.attestBytes == attestBytes
      check q.signatureBytes == sigBytes

  test "t_tpm2_signature_shapes":
    # The RSA arm. The 256-byte payload is the `sig:` line tpm2_quote
    # printed, so a codec that mislaid the 2-byte TPM2B length would
    # produce 254 or 258 bytes here and land somewhere else.
    let rsa = parseSignature(unhex(QuoteVectors[0].signatureHex))
    check rsa.kind == tskRsa
    check rsa.sigAlg == TpmAlgRsassa
    check rsa.hashAlg == TpmAlgSha256
    check rsa.sig.len == 256
    check toHexLower(rsa.sig).startsWith("13a8aa23bc5b8ae5")
    check toHexLower(rsa.sig).endsWith("199b43d438f8")

    # The ECDSA arm. `tpm2_checkquote` printed the same signature as
    # DER, `3044 0220 61cbf779… 0220 69b47e04…`; r and s below are those
    # two integers, and the codec has to reach them through two
    # TPM2B_ECC_PARAMETERs rather than through a SEQUENCE.
    let ecc = parseSignature(unhex(QuoteVectors[1].signatureHex))
    check ecc.kind == tskEcc
    check ecc.sigAlg == TpmAlgEcdsa
    check ecc.hashAlg == TpmAlgSha256
    check ecc.signatureR.len == 32
    check ecc.signatureS.len == 32
    check toHexLower(ecc.signatureR) ==
      "61cbf77937b747dbd67e6c1fab43d2dcbec5083c11195319d5cbd12447b30efb"
    check toHexLower(ecc.signatureS) ==
      "69b47e04ce5cb9387973135ad35d59bb37570137473683f4bf2bf276e3d45906"

    # The scheme hash is what the composite is computed under, and it is
    # NOT the bank: the two-bank vector's selection is half SHA-1 and its
    # composite is still SHA-256.
    let twoBank = parseQuote(unhex(QuoteVectors[4].attestHex),
                             unhex(QuoteVectors[4].signatureHex))
    check twoBank.attest.quote.pcrSelect.selections[0].hashAlg == TpmAlgSha1
    check compositeAlg(twoBank) == TpmAlgSha256
    check twoBank.attest.quote.pcrDigest.len == 32

    # And the vector that makes the scheme hash observable at all. Six of
    # the seven are signed SHA-256, so a codec that never looked at the
    # scheme and returned SHA-256 would satisfy every one of them —
    # including the two-bank case above. This one is a SHA-384 scheme
    # over a SHA-256 bank: the composite is 48 bytes, the bank is not,
    # and neither can stand in for the other.
    let wide = parseQuote(unhex(QuoteVectors[6].attestHex),
                          unhex(QuoteVectors[6].signatureHex))
    check wide.signature.sigAlg == TpmAlgRsassa
    check compositeAlg(wide) == TpmAlgSha384
    check wide.attest.quote.pcrSelect.selections[0].hashAlg == TpmAlgSha256
    check wide.attest.quote.pcrDigest.len == 48
    check digestSize(compositeAlg(wide)) == 48
    # Its qualifiedSigner is a SHA-384 name, so it is 50 bytes where the
    # others are 34 — a TPM2B whose length a fixed-size reader would miss.
    check wide.attest.qualifiedSigner.len == 50
