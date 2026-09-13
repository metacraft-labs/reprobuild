## Pinned `TPM2_Quote` answers from a real TPM, and the third-party
## readings that say what is in them.
##
## ## Where these bytes came from
##
## Every byte below was produced by **swtpm 0.10.1** — the IBM software
## TPM 2.0, i.e. libtpms, which is derived from the TCG reference
## implementation — driven by **tpm2-tools 5.7** over the `swtpm` TCTI.
## None of it came from the codec under test. That distinction is the
## whole point of this file: a vector an encoder generated and its own
## decoder accepts proves that the code agrees with itself, which it
## would do just as happily if it were wrong.
##
## ## Regenerating them
##
## The sequence is reproducible from this comment alone. `$SWTPM` and
## `$TOOLS` are the two `bin` directories; neither package is in this
## host's profile, so both are put on `PATH` from their store paths.
##
## ::
##
##   swtpm socket --tpm2 --server type=tcp,port=$P \
##       --ctrl type=tcp,port=$((P+1)) --tpmstate dir=$STATE \
##       --flags not-need-init,startup-clear --daemon
##   export TPM2TOOLS_TCTI="swtpm:host=127.0.0.1,port=$P"
##
##   tpm2_pcrextend  0:sha256=00…01   1:sha256=00…02
##   tpm2_pcrextend  4:sha256=00…aa   7:sha256=00…bb   11:sha256=00…cc
##   tpm2_createek -c ek.ctx -G rsa -u ek.pub
##   tpm2_createak -C ek.ctx -c ak_rsa.ctx -G rsa -g sha256 -s rsassa \
##       -u ak_rsa.pub -f pem -n ak_rsa.name
##   tpm2_flushcontext -t
##   tpm2_createak -C ek.ctx -c ak_ecc.ctx -G ecc -g sha256 -s ecdsa \
##       -u ak_ecc.pub -f pem -n ak_ecc.name
##
##   Q=030a11…b5bc                                   # the 64 bytes below
##   tpm2_quote -c ak_rsa.ctx -l sha256:0,1,4,7,11 -q $Q \
##       -m q_rsa.msg -s q_rsa.sig -o q_rsa.pcrs -f tss
##
## …and likewise for the other five, after extending the SHA-1 bank and
## PCRs 8, 16 and 23 so that no vector below is a digest over registers
## that are all zero. The exact `-l` of each is in its record.
##
## ## What each vector is anchored by, and by what that is not this code
##
##   * **The structure's fields** — `tpm2_print -t TPMS_ATTEST <file>`,
##     transcribed into `printed*` below. tpm2-tools is an independent
##     parser of the same bytes; if it and this codec disagree about
##     where a field starts, one of them is wrong and the test says so.
##   * **`qualifiedSigner`** — the `qualified name:` line `tpm2_createak`
##     printed when the key was created, i.e. *before* any quote existed.
##   * **`firmwareVersion`** — `tpm2_getcap properties-fixed` reported
##     `TPM2_PT_FIRMWARE_VERSION_1 = 0x20240125` and
##     `TPM2_PT_FIRMWARE_VERSION_2 = 0x00120000`, so the `UINT64` on the
##     wire is `0x2024012500120000`. Worth stating because this is the
##     one field where `tpm2_print`'s rendering is NOT a cross-check: it
##     prints `0000120025012420`, the same eight bytes in the opposite
##     order.
##   * **`extraData`** — the 64 `qualifyingData` bytes, chosen here and
##     passed to `tpm2_quote` on its command line. Neither the TPM nor
##     the codec had any say in them.
##   * **`pcrDigest`** — the composite the TPM itself computed and
##     SIGNED, cross-checked against the `calcDigest:` line `tpm2_quote`
##     prints, which tpm2-tools computes independently by reading the
##     registers.
##   * **The signatures** — `tpm2_checkquote -u <ak.pub> -m <msg>
##     -s <sig> -f <pcrs> -q $Q -g sha256` accepted every one of them.
##     This file does not verify signatures and neither does the codec;
##     the check is recorded because it establishes that these are
##     genuine signed quotes rather than well-formed byte strings.
##
## ## Mocking
##
## None, and the distinction matters here more than usual. swtpm is not
## a mock of a TPM — it is a TPM implementation without a chip around
## it. What it cannot stand in for is a *discrete* TPM's firmware
## quirks, and nothing in this file claims otherwise.

import std/strutils

type
  PcrRef* = object
    ## One register, as `tpm2_pcrread` reported it.
    bank*: string
    index*: int
    valueHex*: string

  QuoteVector* = object
    name*: string
    selectionArg*: string
      ## The `-l` argument that produced it, verbatim.
    attestHex*: string
    signatureHex*: string

    # --- what tpm2_print read out of attestHex -----------------------
    printedMagicHex*: string
    printedTypeHex*: string
    printedQualifiedSignerHex*: string
    printedExtraDataHex*: string
    printedClock*: uint64
    printedResetCount*: uint32
    printedRestartCount*: uint32
    printedSafe*: bool
    printedBankAlgIds*: seq[uint16]
    printedSizeofSelect*: seq[int]
    printedSelectHex*: seq[string]
    printedPcrDigestHex*: string

    # --- what the selection names, spelled out by hand ---------------
    expectedSelected*: seq[tuple[bank: string, index: int]]
      ## Transcribed from the `-l` argument, NOT decoded from the bitmap
      ## by this file. It is the independent statement of which
      ## registers the quote covers, against which the codec's bitmap
      ## walk is checked.

    toolsCalcDigestHex*: string
      ## The `calcDigest:` line tpm2-tools printed.

const
  ## The 64 bytes handed to every `tpm2_quote` below as `-q`.
  QualifyingDataHex* =
    "030a11181f262d343b424950575e656c737a81888f969da4abb2b9c0c7ced5dc" &
    "e3eaf1f8ff060d141b222930373e454c535a61686f767d848b9299a0a7aeb5bc"

  AkRsaQualifiedNameHex* =
    "000bf10cbe6b730eb214d2dbdd7d0ebfd69a6cf4fb514b4cc8af39321fbfb196a6e7"
  AkEccQualifiedNameHex* =
    "000babb7e1acbfe7678de748272c978c9549ffa0243ded82035e9fb49c55eb73fb64"

  ## `TPM2_PT_FIRMWARE_VERSION_1` ‖ `_2`, from `tpm2_getcap`.
  FirmwareVersion* = 0x2024012500120000'u64

  Zero32 = "0000000000000000000000000000000000000000000000000000000000000000"
  Ones32 = "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"

  ## `tpm2_pcrread sha256:0,…,23` and `tpm2_pcrread sha1:0,1,4`, taken
  ## after the last quote below, lower-cased. PCRs 2, 3, 5, 6, 9, 10 and
  ## 12–15 were never extended; 17–22 are the locality-4-only registers
  ## a TPM leaves at all-ones.
  PcrValues*: seq[PcrRef] = @[
    PcrRef(bank: "sha256", index: 0,
      valueHex: "90f4b39548df55ad6187a1d20d731ecee78c545b94afd16f42ef7592d99cd365"),
    PcrRef(bank: "sha256", index: 1,
      valueHex: "bdc9bd36ac7f258351c81a3155a19ea5837b6ef164074f0189d876a5ec17f920"),
    PcrRef(bank: "sha256", index: 2, valueHex: Zero32),
    PcrRef(bank: "sha256", index: 3, valueHex: Zero32),
    PcrRef(bank: "sha256", index: 4,
      valueHex: "17eaf835d8496ed16d40454b53344de18ffac7e5fbbb87860889922e51f47d70"),
    PcrRef(bank: "sha256", index: 5, valueHex: Zero32),
    PcrRef(bank: "sha256", index: 6, valueHex: Zero32),
    PcrRef(bank: "sha256", index: 7,
      valueHex: "aec46cfd6e873da59ee2ff2096b2682227d2e2f9e412b16aca4387e9c046d93d"),
    PcrRef(bank: "sha256", index: 8,
      valueHex: "47f06d5f97bfcdf256f48ee736060997e5b8dcf01cb8e49b36bd4e5970c0c366"),
    PcrRef(bank: "sha256", index: 9, valueHex: Zero32),
    PcrRef(bank: "sha256", index: 10, valueHex: Zero32),
    PcrRef(bank: "sha256", index: 11,
      valueHex: "2efd0a11c4938f8c43c5172762be50cb5ee2ea5dba9f85b757b083f58d4b6141"),
    PcrRef(bank: "sha256", index: 12, valueHex: Zero32),
    PcrRef(bank: "sha256", index: 13, valueHex: Zero32),
    PcrRef(bank: "sha256", index: 14, valueHex: Zero32),
    PcrRef(bank: "sha256", index: 15, valueHex: Zero32),
    PcrRef(bank: "sha256", index: 16,
      valueHex: "6031f906ed21e391399b24df8d479fc5066d43355ae43c496a5e5528fdd74987"),
    PcrRef(bank: "sha256", index: 17, valueHex: Ones32),
    PcrRef(bank: "sha256", index: 18, valueHex: Ones32),
    PcrRef(bank: "sha256", index: 19, valueHex: Ones32),
    PcrRef(bank: "sha256", index: 20, valueHex: Ones32),
    PcrRef(bank: "sha256", index: 21, valueHex: Ones32),
    PcrRef(bank: "sha256", index: 22, valueHex: Ones32),
    PcrRef(bank: "sha256", index: 23,
      valueHex: "144dd441a39c237cb2bbe914cade062e51ee83c7f6ab52ddf85e816add3c95ff"),
    PcrRef(bank: "sha1", index: 0,
      valueHex: "27aa53b041577b2a9c7db5189d58161340052648"),
    PcrRef(bank: "sha1", index: 1,
      valueHex: "0faa4d08769d57f29a2102d8129ea120c4cfbf1a"),
    PcrRef(bank: "sha1", index: 4,
      valueHex: "022de90c24797a888f5e66beaae9498d1a776402")]

proc pcrValueHex*(bank: string; index: int): string =
  ## The pinned register value, or `""` when this file does not carry
  ## one. Callers assert rather than default: a missing register that
  ## silently became the empty string would produce a composite over
  ## fewer bytes than the selection names.
  for p in PcrValues:
    if p.bank == bank and p.index == index:
      return p.valueHex
  return ""

const
  AttestCommonPrefix = "ff54434780180022"
  ExtraDataFramed = "0040" & QualifyingDataHex

  QuoteVectors*: seq[QuoteVector] = @[

    # -- an RSASSA-signed quote; the only RSA signature in the set, and
    #    the reason the RSA arm of TPMT_SIGNATURE has a real vector.
    QuoteVector(
      name: "rsassa-sha256-pcr-0-1-4-7-11",
      selectionArg: "sha256:0,1,4,7,11",
      attestHex:
        AttestCommonPrefix & AkRsaQualifiedNameHex &
        ExtraDataFramed &
        "000000000000c346" & "00000001" & "00000000" & "01" &
        "2024012500120000" &
        "00000001" & "000b" & "03" & "930800" &
        "0020" &
        "783228bbaef08e490f5e0323574647d502f59d8a62aad96c3d91e970d7fcfbfe",
      signatureHex:
        "0014000b0100" &
        "13a8aa23bc5b8ae5a2f95bb8c6385c24cd09a0274b1c8505cca7e70b02f0396e" &
        "8dfe7ae511a2aa76c91d1bac566158e3c93af6a8bb56c3baac5472ab2c7d7fa8" &
        "41ab21347184f770725523afcda5b1ea4ba3c1cae87127e7d8c5e0c772f6bb15" &
        "ebf6c0998c7bc835c6ea0b5bcc30fe3ef6ab9c2e0793698e143428ed5c58b7eb" &
        "00af9ff1409eb42ec92661fc8d41f296555ca133f5edba844004a23eea7dafe7" &
        "c98c803bc500944ef05707085fdb01d4e3e525d81bce88190015b8abf64c4e44" &
        "116787d37150c51f8abd0f3908b0e866b5bd4cb3118e683d5043c0744040eddb" &
        "0eed00540fe9de3b9467dd40b8ee22231828787124033b6baa3f199b43d438f8",
      printedMagicHex: "ff544347",
      printedTypeHex: "8018",
      printedQualifiedSignerHex: AkRsaQualifiedNameHex,
      printedExtraDataHex: QualifyingDataHex,
      printedClock: 49990'u64,
      printedResetCount: 1'u32,
      printedRestartCount: 0'u32,
      printedSafe: true,
      printedBankAlgIds: @[0x000B'u16],
      printedSizeofSelect: @[3],
      printedSelectHex: @["930800"],
      printedPcrDigestHex:
        "783228bbaef08e490f5e0323574647d502f59d8a62aad96c3d91e970d7fcfbfe",
      expectedSelected: @[("sha256", 0), ("sha256", 1), ("sha256", 4),
                          ("sha256", 7), ("sha256", 11)],
      toolsCalcDigestHex:
        "783228bbaef08e490f5e0323574647d502f59d8a62aad96c3d91e970d7fcfbfe"),

    # -- the same selection, signed by an ECDSA key. Same composite,
    #    different signature shape and a different clock: proof the two
    #    are independent axes.
    QuoteVector(
      name: "ecdsa-sha256-pcr-0-1-4-7-11",
      selectionArg: "sha256:0,1,4,7,11",
      attestHex:
        AttestCommonPrefix & AkEccQualifiedNameHex &
        ExtraDataFramed &
        "000000000000c3a5" & "00000001" & "00000000" & "01" &
        "2024012500120000" &
        "00000001" & "000b" & "03" & "930800" &
        "0020" &
        "783228bbaef08e490f5e0323574647d502f59d8a62aad96c3d91e970d7fcfbfe",
      signatureHex:
        "0018000b0020" &
        "61cbf77937b747dbd67e6c1fab43d2dcbec5083c11195319d5cbd12447b30efb" &
        "0020" &
        "69b47e04ce5cb9387973135ad35d59bb37570137473683f4bf2bf276e3d45906",
      printedMagicHex: "ff544347",
      printedTypeHex: "8018",
      printedQualifiedSignerHex: AkEccQualifiedNameHex,
      printedExtraDataHex: QualifyingDataHex,
      printedClock: 50085'u64,
      printedResetCount: 1'u32,
      printedRestartCount: 0'u32,
      printedSafe: true,
      printedBankAlgIds: @[0x000B'u16],
      printedSizeofSelect: @[3],
      printedSelectHex: @["930800"],
      printedPcrDigestHex:
        "783228bbaef08e490f5e0323574647d502f59d8a62aad96c3d91e970d7fcfbfe",
      expectedSelected: @[("sha256", 0), ("sha256", 1), ("sha256", 4),
                          ("sha256", 7), ("sha256", 11)],
      toolsCalcDigestHex:
        "783228bbaef08e490f5e0323574647d502f59d8a62aad96c3d91e970d7fcfbfe"),

    # -- one register. The degenerate-but-legal case: a bitmap with a
    #    single bit set, and a composite that is H(one PCR value).
    QuoteVector(
      name: "ecdsa-sha256-pcr-0-only",
      selectionArg: "sha256:0",
      attestHex:
        AttestCommonPrefix & AkEccQualifiedNameHex &
        ExtraDataFramed &
        "00000000000151ec" & "00000001" & "00000000" & "01" &
        "2024012500120000" &
        "00000001" & "000b" & "03" & "010000" &
        "0020" &
        "02dfa311a6e1e44e445ce44fee4a3a38df03885bf1cd166ab0701373762dca8b",
      signatureHex:
        "0018000b0020" &
        "609c944617cb30eef17262becd4cb7b9537bf0cf2c629311e8034e828af8affb" &
        "0020" &
        "494b8119b5becf7b38d52509d1cd2c323101fd5dc6b02ef4c5825ab359a74be8",
      printedMagicHex: "ff544347",
      printedTypeHex: "8018",
      printedQualifiedSignerHex: AkEccQualifiedNameHex,
      printedExtraDataHex: QualifyingDataHex,
      printedClock: 86508'u64,
      printedResetCount: 1'u32,
      printedRestartCount: 0'u32,
      printedSafe: true,
      printedBankAlgIds: @[0x000B'u16],
      printedSizeofSelect: @[3],
      printedSelectHex: @["010000"],
      printedPcrDigestHex:
        "02dfa311a6e1e44e445ce44fee4a3a38df03885bf1cd166ab0701373762dca8b",
      expectedSelected: @[("sha256", 0)],
      toolsCalcDigestHex:
        "02dfa311a6e1e44e445ce44fee4a3a38df03885bf1cd166ab0701373762dca8b"),

    # -- registers 0, 8, 16 and 23: one bit in each of the three bitmap
    #    bytes, and bit 7 of the last. This is the vector that pins the
    #    bit order INSIDE a byte, which is the one place the encoding
    #    stops being big-endian. A codec that read the bitmap MSB-first
    #    would select 7, 15, 23 and 16 here and land on a different
    #    digest.
    QuoteVector(
      name: "ecdsa-sha256-pcr-0-8-16-23",
      selectionArg: "sha256:0,8,16,23",
      attestHex:
        AttestCommonPrefix & AkEccQualifiedNameHex &
        ExtraDataFramed &
        "0000000000015243" & "00000001" & "00000000" & "01" &
        "2024012500120000" &
        "00000001" & "000b" & "03" & "010181" &
        "0020" &
        "715f0a65ffe3a248bc9350efa22deeb57d61ef2d27c4bd0bfbef1488e259be2f",
      signatureHex:
        "0018000b0020" &
        "21050daa6560b03cabaabe3a7b5f0b0b2ae33b998cccf0b54b3d8df1943512de" &
        "0020" &
        "7c8466db2488ce31b7dd30f6d8c85f6e1a522c72a1e9eb6acc46f4c199cf2c9b",
      printedMagicHex: "ff544347",
      printedTypeHex: "8018",
      printedQualifiedSignerHex: AkEccQualifiedNameHex,
      printedExtraDataHex: QualifyingDataHex,
      printedClock: 86595'u64,
      printedResetCount: 1'u32,
      printedRestartCount: 0'u32,
      printedSafe: true,
      printedBankAlgIds: @[0x000B'u16],
      printedSizeofSelect: @[3],
      printedSelectHex: @["010181"],
      printedPcrDigestHex:
        "715f0a65ffe3a248bc9350efa22deeb57d61ef2d27c4bd0bfbef1488e259be2f",
      expectedSelected: @[("sha256", 0), ("sha256", 8), ("sha256", 16),
                          ("sha256", 23)],
      toolsCalcDigestHex:
        "715f0a65ffe3a248bc9350efa22deeb57d61ef2d27c4bd0bfbef1488e259be2f"),

    # -- two banks. The vector that pins the composite's ACROSS-bank
    #    order and its algorithm: three 20-byte SHA-1 values followed by
    #    three 32-byte SHA-256 values, all digested under SHA-256
    #    because that is the SIGNING scheme's hash. A codec that
    #    digested under the bank's own algorithm, or that put the
    #    SHA-256 bank first, lands elsewhere.
    QuoteVector(
      name: "ecdsa-sha256-sha1-and-sha256-pcr-0-1-4",
      selectionArg: "sha1:0,1,4+sha256:0,1,4",
      attestHex:
        AttestCommonPrefix & AkEccQualifiedNameHex &
        ExtraDataFramed &
        "0000000000015295" & "00000001" & "00000000" & "01" &
        "2024012500120000" &
        "00000002" & "0004" & "03" & "130000" &
                     "000b" & "03" & "130000" &
        "0020" &
        "0278af4e1250021df62c5e7ef0d37c051411c6abdee3b1df26854b537553e098",
      signatureHex:
        "0018000b0020" &
        "16de52dd1634792cb8d28709baed2fa7b056a1aef5032788bc6ca87f9be7b7a1" &
        "0020" &
        "91777d7818f5898de5d77c3f21007a40754bf1a920d43fe193fd9f43ec48c255",
      printedMagicHex: "ff544347",
      printedTypeHex: "8018",
      printedQualifiedSignerHex: AkEccQualifiedNameHex,
      printedExtraDataHex: QualifyingDataHex,
      printedClock: 86677'u64,
      printedResetCount: 1'u32,
      printedRestartCount: 0'u32,
      printedSafe: true,
      printedBankAlgIds: @[0x0004'u16, 0x000B'u16],
      printedSizeofSelect: @[3, 3],
      printedSelectHex: @["130000", "130000"],
      printedPcrDigestHex:
        "0278af4e1250021df62c5e7ef0d37c051411c6abdee3b1df26854b537553e098",
      expectedSelected: @[("sha1", 0), ("sha1", 1), ("sha1", 4),
                          ("sha256", 0), ("sha256", 1), ("sha256", 4)],
      toolsCalcDigestHex:
        "0278af4e1250021df62c5e7ef0d37c051411c6abdee3b1df26854b537553e098"),

    # -- every register the platform has. All 24 bits set, which is the
    #    widest a PC Client profile bitmap goes, and the only vector
    #    whose preimage is 768 bytes long.
    QuoteVector(
      name: "ecdsa-sha256-pcr-all-24",
      selectionArg: "sha256:0..23",
      attestHex:
        AttestCommonPrefix & AkEccQualifiedNameHex &
        ExtraDataFramed &
        "00000000000152e9" & "00000001" & "00000000" & "01" &
        "2024012500120000" &
        "00000001" & "000b" & "03" & "ffffff" &
        "0020" &
        "2a4ace64483ecec2da75eac977a4fd2948e04db313e7bd097998d34a0af6eb34",
      signatureHex:
        "0018000b0020" &
        "d8aa3c34f1121e960c68f3bb4eb15d2f9cf1e53356a0dbd1762014498fe2776d" &
        "0020" &
        "ba0c4ac1c47de5740528df493c3d4d12ecf029303cfdf805247992ce097cdcc7",
      printedMagicHex: "ff544347",
      printedTypeHex: "8018",
      printedQualifiedSignerHex: AkEccQualifiedNameHex,
      printedExtraDataHex: QualifyingDataHex,
      printedClock: 86761'u64,
      printedResetCount: 1'u32,
      printedRestartCount: 0'u32,
      printedSafe: true,
      printedBankAlgIds: @[0x000B'u16],
      printedSizeofSelect: @[3],
      printedSelectHex: @["ffffff"],
      printedPcrDigestHex:
        "2a4ace64483ecec2da75eac977a4fd2948e04db313e7bd097998d34a0af6eb34",
      expectedSelected: @[("sha256", 0), ("sha256", 1), ("sha256", 2),
                          ("sha256", 3), ("sha256", 4), ("sha256", 5),
                          ("sha256", 6), ("sha256", 7), ("sha256", 8),
                          ("sha256", 9), ("sha256", 10), ("sha256", 11),
                          ("sha256", 12), ("sha256", 13), ("sha256", 14),
                          ("sha256", 15), ("sha256", 16), ("sha256", 17),
                          ("sha256", 18), ("sha256", 19), ("sha256", 20),
                          ("sha256", 21), ("sha256", 22), ("sha256", 23)],
      toolsCalcDigestHex:
        "2a4ace64483ecec2da75eac977a4fd2948e04db313e7bd097998d34a0af6eb34"),

    # -- a SHA-384 SIGNING SCHEME over a SHA-256 bank. The vector that
    #    makes the composite's algorithm observable at all: the other six
    #    are signed SHA-256, so a codec that ignored the scheme and
    #    hard-coded SHA-256 would satisfy every one of them. Here the
    #    bank is SHA-256, the composite is 48 bytes, and the two cannot
    #    be confused.
    #
    #    tpm2_createak fixes the scheme hash at the name algorithm, so
    #    this key was built by hand:
    #
    #      tpm2_createprimary -C e -c eprim.ctx -G rsa -g sha256
    #      tpm2_create -C eprim.ctx -G rsa2048:rsassa-sha384:null \
    #          -g sha384 -a "fixedtpm|fixedparent|sensitivedataorigin\
    #          |userwithauth|restricted|sign" -u k.pub -r k.priv
    #      tpm2_load -C eprim.ctx -u k.pub -r k.priv -c k.ctx
    #      tpm2_quote -c k.ctx -l sha256:0,1,4,7,11 -q $Q -g sha384 …
    #
    #    `-C e` is load-bearing and was established the hard way. The
    #    same key under the OWNER hierarchy produced a quote whose
    #    `resetCount` was 1112168004, `restartCount` 1591067252 and
    #    `firmwareVersion` 0xee33716d1dfabf71 — a TPM OBFUSCATES those
    #    three fields for a signer outside the endorsement and platform
    #    hierarchies. Nothing is wrong with such a quote and this codec
    #    parses it; but a verifier that reads `firmwareVersion` as the
    #    TPM's firmware version has to know which hierarchy signed.
    QuoteVector(
      name: "rsassa-sha384-scheme-over-sha256-bank-pcr-0-1-4-7-11",
      selectionArg: "sha256:0,1,4,7,11 (-g sha384)",
      attestHex:
        "ff54434780180032" &
        "000c16c90188b6c9838ee4a549d1be19204f47b6bcdd50e648419253233a5f6" &
        "c9e0a5d64ca38864f023c5b149009b74b2cd1" &
        ExtraDataFramed &
        "000000000045fa3b" & "00000001" & "00000000" & "01" &
        "2024012500120000" &
        "00000001" & "000b" & "03" & "930800" &
        "0030" &
        "60a4229c8889771ffe0f5f31f95307d13790bf6bf51c9069ffadd77a9030f98" &
        "422238865875099518f8f3c98a6595ae8",
      signatureHex:
        "0014000c0100" &
        "780b4c752eb02d5225d34ca70f49bc679cf1f19d62cd18924eb28a9c8b15b16a" &
        "7e431c0b7876e66dd84b9fb3742ac358df0904ed158eedd1f84353b9f93c4bc8" &
        "04a58c02b95531739c38e1108b089c05a9a74ee9bc67f8bd6e1910d51efb245d" &
        "2958cfc460266bbdc98ac57620ba03fb341c1797f86aa7010e8b299965bee156" &
        "674a1eb4e4821af2133ffb93f3a72370c39ab196119ac4fb3d86c22650a45382" &
        "200c298cee83a8194d09a9a7856dd0d513d13306a96eb2fe5a9161f441c821af" &
        "e9f9557db7a63d3f1adae7be550a9e7a9f0a227a9d086aee908fdb96268b3440" &
        "89eff79122449eede92d16600895a48a45a4282bb88db3a72ab4fd156c2148d0",
      printedMagicHex: "ff544347",
      printedTypeHex: "8018",
      printedQualifiedSignerHex:
        "000c16c90188b6c9838ee4a549d1be19204f47b6bcdd50e648419253233a5f6" &
        "c9e0a5d64ca38864f023c5b149009b74b2cd1",
      printedExtraDataHex: QualifyingDataHex,
      printedClock: 4586043'u64,
      printedResetCount: 1'u32,
      printedRestartCount: 0'u32,
      printedSafe: true,
      printedBankAlgIds: @[0x000B'u16],
      printedSizeofSelect: @[3],
      printedSelectHex: @["930800"],
      printedPcrDigestHex:
        "60a4229c8889771ffe0f5f31f95307d13790bf6bf51c9069ffadd77a9030f98" &
        "422238865875099518f8f3c98a6595ae8",
      expectedSelected: @[("sha256", 0), ("sha256", 1), ("sha256", 4),
                          ("sha256", 7), ("sha256", 11)],
      toolsCalcDigestHex:
        "60a4229c8889771ffe0f5f31f95307d13790bf6bf51c9069ffadd77a9030f98" &
        "422238865875099518f8f3c98a6595ae8")]

proc unhex*(h: string): string =
  ## Lower-case hex to raw bytes.
  ##
  ## `parseHexStr` is the standard library's, deliberately: a hand-rolled
  ## nibble loop in the file that holds the vectors is one more place a
  ## mistyped vector could become a differently-wrong one without
  ## anybody noticing.
  doAssert h.len mod 2 == 0, "odd-length hex literal: " & $h.len
  for c in h:
    doAssert c in {'0' .. '9', 'a' .. 'f'},
      "vector hex must be lower-case: " & $c
  parseHexStr(h)

proc toHexLower*(raw: string): string =
  ## Raw bytes to lower-case hex, for comparing against the readings
  ## third-party tools printed.
  toLowerAscii(toHex(raw))
