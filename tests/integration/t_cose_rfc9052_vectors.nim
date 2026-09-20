## RFC 9052 (COSE) — the published examples, rebuilt from the document
## and verified against the public keys the document publishes.
##
## ## Where the vectors come from
##
## `Rfc9052AppendixC` is a VERBATIM copy of Appendix C of RFC 9052 as
## published by the RFC Editor, taken from
##
##   https://www.rfc-editor.org/rfc/rfc9052.txt
##   sha256 01eecd7f646537600e7aad665b1fa581ce6ec33dae4ef4add0997aaf38cd0a45
##
## lines 2940-3491 of that file: the C.1 heading through the last line
## of C.7.1. C.7.2 (the PRIVATE keys) is deliberately excluded — nothing
## here signs anything, so the private halves would be key material this
## repository has no use for.
##
## Appendix C is written entirely in CBOR diagnostic notation; it
## publishes no hex dump of any complete message. What it does publish,
## for every example, is
##
##   * the byte LENGTH of the encoded message ("Size of binary file is
##     N bytes"),
##   * the exact bytes of every protected header bucket, in the
##     `/ protected h'…' /` comment that precedes each `<< … >>`, and
##   * for the signed examples, the signature value and, in C.7.1, the
##     public key that has to verify it.
##
## All three are used. The first two pin the encoder against numbers the
## RFC computed; the third is the real test, because a signature that
## verifies is a statement about EVERY byte of the Sig_structure at
## once: the context string, the protected buckets as bytes, the
## external_aad and the payload.
##
## The algorithm and curve identifiers come from RFC 9053, whose
## Table 1 (ES256 = -7, ES384 = -35, ES512 = -36), Table 17 (EC2 = 2)
## and Table 18 (P-256 = 1, P-384 = 2, P-521 = 3) are transcribed into
## `repro_attest/cose` as named constants:
##
##   https://www.rfc-editor.org/rfc/rfc9053.txt
##   sha256 3d470615875620375f8453ba25b8dce7e4d0271e76b0b79a46df34ccb2d56ab0
##
## ## The corpus is constrained by its own gate
##
## Fifteen examples carry a published size, and every one is parsed and
## measured; twenty `<< … >>` blocks carry a published byte string, and
## every one is encoded and compared. Both counts are pinned, as is the
## number of keys in C.7.1, the number of signatures verified, and the
## number of examples that could not be read (zero). An example that
## stopped parsing would not be skipped — it would move a number.
##
## ## What is verified, and what is only measured
##
## VERIFIED cryptographically: C.1.1, C.1.2, C.1.3 (COSE_Sign) and
## C.2.1 (COSE_Sign1) — five signatures, four ES256 over P-256 and one
## ES512 over P-521.
##
## MEASURED ONLY: C.3.x, C.4.x, C.5.x and C.6.x. Those are enveloped,
## encrypted and MACed messages, and RFC 9052 publishes them WITHOUT the
## symmetric key material, so there is nothing offline to verify them
## against and this build implements none of those structures. They are
## still parsed and their published sizes are still pinned, which
## exercises the CBOR layer against real COSE shapes it would otherwise
## never see — partial IVs, recipient arrays, three levels of nesting.
## Saying they are "covered" would be false; they are read, not checked.
##
## ## What is NOT implemented at all
##
## Signing. COSE_Encrypt / Encrypt0 / Mac / Mac0 processing, recipient
## structures, key wrap, ECDH. EdDSA, RSA-PSS, HMAC, AES-CBC-MAC,
## AES-CCM, AES-GCM. Counter signatures. Private COSE keys. The OKP key
## type and point compression.
##
## ES384 has no published vector anywhere in RFC 9052 — no example in
## the document uses P-384 — so the COSE MESSAGE level cannot reach it.
## Its ECDSA path is pinned one layer down instead, against RFC 6979
## Appendix A.2.6; see the last suite in this file. What is therefore
## NOT shown for ES384, and is shown for ES256 and ES512, is a complete
## COSE_Sign1 or COSE_Sign verifying end to end.
##
## ## Mocking
##
## None. Every byte is either published by an RFC or computed by the
## code under test.

import std/[exitprocs, os, strutils, unittest]

import cbor
import repro_attest/cose

# ---------------------------------------------------------------------
# The refusal-site census
# ---------------------------------------------------------------------
#
# `CborError.site` carries the file and line of the rule that refused.
# Collecting them says which refusal sites any input in this suite can
# actually reach; a rule nothing reaches is a rule the program does not
# have. That is a shape counting finds and reading does not.
#
# The list is written out only when `REPRO_REFUSAL_CENSUS` names a file,
# so an ordinary run of the gate prints nothing extra.

var reachedSites: seq[string] = @[]
var lastSite = ""

proc noteSite(filename: string; line: int) =
  var base = filename
  let slash = base.rfind('/')
  if slash >= 0:
    base = base[slash + 1 .. ^1]
  lastSite = base & ":" & $line
  if lastSite notin reachedSites:
    reachedSites.add lastSite

proc writeCensus() {.noconv.} =
  let path = getEnv("REPRO_REFUSAL_CENSUS")
  if path.len == 0:
    return
  var f: File
  if open(f, path, fmAppend):
    for s in reachedSites:
      f.writeLine(s)
    f.close()

addExitProc(writeCensus)

const Rfc9052AppendixC = """C.1.  Examples of Signed Messages

C.1.1.  Single Signature

   This example uses the following:

   *  Signature Algorithm: ECDSA w/ SHA-256, Curve P-256

   Size of binary file is 103 bytes

   98(
     [
       / protected / h'',
       / unprotected / {},
       / payload / 'This is the content.',
       / signatures / [
         [
           / protected h'a10126' / << {
               / alg / 1:-7 / ECDSA 256 /
             } >>,
           / unprotected / {
             / kid / 4:'11'
           },
           / signature / h'e2aeafd40d69d19dfe6e52077c5d7ff4e408282cbefb
   5d06cbf414af2e19d982ac45ac98b8544c908b4507de1e90b717c3d34816fe926a2b
   98f53afd2fa0f30a'
         ]
       ]
     ]
   )

C.1.2.  Multiple Signers

   This example uses the following:

   *  Signature Algorithm: ECDSA w/ SHA-256, Curve P-256

   *  Signature Algorithm: ECDSA w/ SHA-512, Curve P-521

   Size of binary file is 277 bytes

   98(
     [
       / protected / h'',
       / unprotected / {},
       / payload / 'This is the content.',
       / signatures / [
         [
           / protected h'a10126' / << {
               / alg / 1:-7 / ECDSA 256 /
             } >>,
           / unprotected / {
             / kid / 4:'11'
           },
           / signature / h'e2aeafd40d69d19dfe6e52077c5d7ff4e408282cbefb
   5d06cbf414af2e19d982ac45ac98b8544c908b4507de1e90b717c3d34816fe926a2b
   98f53afd2fa0f30a'
         ],
         [
           / protected h'a1013823' / << {
               / alg / 1:-36 / ECDSA 521 /
             } >> ,
           / unprotected / {
             / kid / 4:'bilbo.baggins@hobbiton.example'
           },
           / signature / h'00a2d28a7c2bdb1587877420f65adf7d0b9a06635dd1
   de64bb62974c863f0b160dd2163734034e6ac003b01e8705524c5c4ca479a952f024
   7ee8cb0b4fb7397ba08d009e0c8bf482270cc5771aa143966e5a469a09f613488030
   c5b07ec6d722e3835adb5b2d8c44e95ffb13877dd2582866883535de3bb03d01753f
   83ab87bb4f7a0297'
         ]
       ]
     ]
   )

C.1.3.  Signature with Criticality

   This example uses the following:

   *  Signature Algorithm: ECDSA w/ SHA-256, Curve P-256

   *  There is a criticality marker on the "reserved" header parameter.

   Size of binary file is 125 bytes

   98(
     [
       / protected h'a2687265736572766564f40281687265736572766564' /
       << {
           "reserved":false,
           / crit / 2:[
             "reserved"
           ]
         } >>,
       / unprotected / {},
       / payload / 'This is the content.',
       / signatures / [
         [
           / protected h'a10126' / << {
               / alg / 1:-7 / ECDSA 256 /
             } >>,
           / unprotected / {
             / kid / 4:'11'
           },
           / signature / h'3fc54702aa56e1b2cb20284294c9106a63f91bac658d
   69351210a031d8fc7c5ff3e4be39445b1a3e83e1510d1aca2f2e8a7c081c7645042b
   18aba9d1fad1bd9c'
         ]
       ]
     ]
   )

C.2.  Single Signer Examples

C.2.1.  Single ECDSA Signature

   This example uses the following:

   *  Signature Algorithm: ECDSA w/ SHA-256, Curve P-256

   Size of binary file is 98 bytes

   18(
     [
       / protected h'a10126' / << {
           / alg / 1:-7 / ECDSA 256 /
         } >>,
       / unprotected / {
         / kid / 4:'11'
       },
       / payload / 'This is the content.',
       / signature / h'8eb33e4ca31d1c465ab05aac34cc6b23d58fef5c083106c4
   d25a91aef0b0117e2af9a291aa32e14ab834dc56ed2a223444547e01f11d3b0916e5
   a4c345cacb36'
     ]
   )

C.3.  Examples of Enveloped Messages

C.3.1.  Direct ECDH

   This example uses the following:

   *  CEK: AES-GCM w/ 128-bit key

   *  Recipient class: ECDH Ephemeral-Static, Curve P-256

   Size of binary file is 151 bytes

   96(
     [
       / protected h'a10101' / << {
           / alg / 1:1 / AES-GCM 128 /
         } >>,
       / unprotected / {
         / iv / 5:h'c9cf4df2fe6c632bf7886413'
       },
       / ciphertext / h'7adbe2709ca818fb415f1e5df66f4e1a51053ba6d65a1a0
   c52a357da7a644b8070a151b0',
       / recipients / [
         [
           / protected h'a1013818' / << {
               / alg / 1:-25 / ECDH-ES + HKDF-256 /
             } >>,
           / unprotected / {
             / ephemeral / -1:{
               / kty / 1:2,
               / crv / -1:1,
               / x / -2:h'98f50a4ff6c05861c8860d13a638ea56c3f5ad7590bbf
   bf054e1c7b4d91d6280',
               / y / -3:true
             },
             / kid / 4:'meriadoc.brandybuck@buckland.example'
           },
           / ciphertext / h''
         ]
       ]
     ]
   )

C.3.2.  Direct Plus Key Derivation

   This example uses the following:

   *  CEK: AES-CCM w/ 128-bit key, truncate the tag to 64 bits

   *  Recipient class: Use HKDF on a shared secret with the following
      implicit fields as part of the context.

      -  salt: "aabbccddeeffgghh"

      -  PartyU identity: "lighting-client"

      -  PartyV identity: "lighting-server"

      -  Supplementary Public Other: "Encryption Example 02"

   Size of binary file is 91 bytes

   96(
     [
       / protected h'a1010a' / << {
           / alg / 1:10 / AES-CCM-16-64-128 /
         } >>,
       / unprotected / {
         / iv / 5:h'89f52f65a1c580933b5261a76c'
       },
       / ciphertext / h'753548a19b1307084ca7b2056924ed95f2e3b17006dfe93
   1b687b847',
       / recipients / [
         [
           / protected h'a10129' / << {
               / alg / 1:-10
             } >>,
           / unprotected / {
             / salt / -20:'aabbccddeeffgghh',
             / kid / 4:'our-secret'
           },
           / ciphertext / h''
         ]
       ]
     ]
   )

C.3.3.  Encrypted Content with External Data

   This example uses the following:

   *  CEK: AES-GCM w/ 128-bit key

   *  Recipient class: ECDH Static-Static, Curve P-256 with AES Key Wrap

   *  Externally Supplied AAD: h'0011bbcc22dd44ee55ff660077'

   Size of binary file is 173 bytes

   96(
     [
       / protected h'a10101' / << {
           / alg / 1:1 / AES-GCM 128 /
         } >> ,
       / unprotected / {
         / iv / 5:h'02d1f7e6f26c43d4868d87ce'
       },
       / ciphertext / h'64f84d913ba60a76070a9a48f26e97e863e28529d8f5335
   e5f0165eee976b4a5f6c6f09d',
       / recipients / [
         [
           / protected / h'a101381f' / {
               \ alg \ 1:-32 \ ECDH-SS+A128KW \
             } / ,
           / unprotected / {
             / static kid / -3:'peregrin.took@tuckborough.example',
             / kid / 4:'meriadoc.brandybuck@buckland.example',
             / U nonce / -22:h'0101'
           },
           / ciphertext / h'41e0d76f579dbd0d936a662d54d8582037de2e366fd
   e1c62'
         ]
       ]
     ]
   )

C.4.  Examples of Encrypted Messages

C.4.1.  Simple Encrypted Message

   This example uses the following:

   *  CEK: AES-CCM w/ 128-bit key and a 64-bit tag

   Size of binary file is 52 bytes

   16(
     [
       / protected h'a1010a' / << {
           / alg / 1:10 / AES-CCM-16-64-128 /
         } >> ,
       / unprotected / {
         / iv / 5:h'89f52f65a1c580933b5261a78c'
       },
       / ciphertext / h'5974e1b99a3a4cc09a659aa2e9e7fff161d38ce71cb45ce
   460ffb569'
     ]
   )

C.4.2.  Encrypted Message with a Partial IV

   This example uses the following:

   *  CEK: AES-CCM w/ 128-bit key and a 64-bit tag

   *  Prefix for IV is 89F52F65A1C580933B52

   Size of binary file is 41 bytes

   16(
     [
       / protected h'a1010a' / << {
           / alg / 1:10 / AES-CCM-16-64-128 /
         } >> ,
       / unprotected / {
         / partial iv / 6:h'61a7'
       },
       / ciphertext / h'252a8911d465c125b6764739700f0141ed09192de139e05
   3bd09abca'
     ]
   )

C.5.  Examples of MACed Messages

C.5.1.  Shared Secret Direct MAC

   This example uses the following:

   *  MAC: AES-CMAC, 256-bit key, truncated to 64 bits

   *  Recipient class: direct shared secret

   Size of binary file is 57 bytes

   97(
     [
       / protected h'a1010f' / << {
           / alg / 1:15 / AES-CBC-MAC-256//64 /
         } >> ,
       / unprotected / {},
       / payload / 'This is the content.',
       / tag / h'9e1226ba1f81b848',
       / recipients / [
         [
           / protected / h'',
           / unprotected / {
             / alg / 1:-6 / direct /,
             / kid / 4:'our-secret'
           },
           / ciphertext / h''
         ]
       ]
     ]
   )

C.5.2.  ECDH Direct MAC

   This example uses the following:

   *  MAC: HMAC w/SHA-256, 256-bit key

   *  Recipient class: ECDH key agreement, two static keys, HKDF w/
      context structure

   Size of binary file is 214 bytes

   97(
     [
       / protected h'a10105' / << {
           / alg / 1:5 / HMAC 256//256 /
         } >> ,
       / unprotected / {},
       / payload / 'This is the content.',
       / tag / h'81a03448acd3d305376eaa11fb3fe416a955be2cbe7ec96f012c99
   4bc3f16a41',
       / recipients / [
         [
           / protected h'a101381a' / << {
               / alg / 1:-27 / ECDH-SS + HKDF-256 /
             } >> ,
           / unprotected / {
             / static kid / -3:'peregrin.took@tuckborough.example',
             / kid / 4:'meriadoc.brandybuck@buckland.example',
             / U nonce / -22:h'4d8553e7e74f3c6a3a9dd3ef286a8195cbf8a23d
   19558ccfec7d34b824f42d92bd06bd2c7f0271f0214e141fb779ae2856abf585a583
   68b017e7f2a9e5ce4db5'
           },
           / ciphertext / h''
         ]
       ]
     ]
   )

C.5.3.  Wrapped MAC

   This example uses the following:

   *  MAC: AES-MAC, 128-bit key, truncated to 64 bits

   *  Recipient class: AES Key Wrap w/ a preshared 256-bit key

   Size of binary file is 109 bytes

   97(
     [
       / protected h'a1010e' / << {
           / alg / 1:14 / AES-CBC-MAC-128//64 /
         } >> ,
       / unprotected / {},
       / payload / 'This is the content.',
       / tag / h'36f5afaf0bab5d43',
       / recipients / [
         [
           / protected / h'',
           / unprotected / {
             / alg / 1:-5 / A256KW /,
             / kid / 4:'018c0ae5-4d9b-471b-bfd6-eef314bc7037'
           },
           / ciphertext / h'711ab0dc2fc4585dce27effa6781c8093eba906f227
   b6eb0'
         ]
       ]
     ]
   )

C.5.4.  Multi-Recipient MACed Message

   This example uses the following:

   *  MAC: HMAC w/ SHA-256, 128-bit key

   *  Recipient class: Uses two different methods.

      1.  ECDH Ephemeral-Static, Curve P-521, AES Key Wrap w/ 128-bit
          key

      2.  AES Key Wrap w/ 256-bit key

   Size of binary file is 309 bytes

   97(
     [
       / protected h'a10105' / << {
           / alg / 1:5 / HMAC 256//256 /
         } >> ,
       / unprotected / {},
       / payload / 'This is the content.',
       / tag / h'bf48235e809b5c42e995f2b7d5fa13620e7ed834e337f6aa43df16
   1e49e9323e',
       / recipients / [
         [
           / protected h'a101381c' / << {
               / alg / 1:-29 / ECDH-ES+A128KW /
             } >> ,
           / unprotected / {
             / ephemeral / -1:{
               / kty / 1:2,
               / crv / -1:3,
               / x / -2:h'0043b12669acac3fd27898ffba0bcd2e6c366d53bc4db
   71f909a759304acfb5e18cdc7ba0b13ff8c7636271a6924b1ac63c02688075b55ef2
   d613574e7dc242f79c3',
               / y / -3:true
             },
             / kid / 4:'bilbo.baggins@hobbiton.example'
           },
           / ciphertext / h'339bc4f79984cdc6b3e6ce5f315a4c7d2b0ac466fce
   a69e8c07dfbca5bb1f661bc5f8e0df9e3eff5'
         ],
         [
           / protected / h'',
           / unprotected / {
             / alg / 1:-5 / A256KW /,
             / kid / 4:'018c0ae5-4d9b-471b-bfd6-eef314bc7037'
           },
           / ciphertext / h'0b2c7cfce04e98276342d6476a7723c090dfdd15f9a
   518e7736549e998370695e6d6a83b4ae507bb'
         ]
       ]
     ]
   )

C.6.  Examples of MAC0 Messages

C.6.1.  Shared-Secret Direct MAC

   This example uses the following:

   *  MAC: AES-CMAC, 256-bit key, truncated to 64 bits

   *  Recipient class: direct shared secret

   Size of binary file is 37 bytes

   17(
     [
       / protected h'a1010f' / << {
           / alg / 1:15 / AES-CBC-MAC-256//64 /
         } >> ,
       / unprotected / {},
       / payload / 'This is the content.',
       / tag / h'726043745027214f'
     ]
   )

   Note that this example uses the same inputs as Appendix C.5.1.

C.7.  COSE Keys

C.7.1.  Public Keys

   This is an example of a COSE Key Set.  This example includes the
   public keys for all of the previous examples.

   In order, the keys are:

   *  An EC key with a kid of "meriadoc.brandybuck@buckland.example"

   *  An EC key with a kid of "11"

   *  An EC key with a kid of "bilbo.baggins@hobbiton.example"

   *  An EC key with a kid of "peregrin.took@tuckborough.example"

   Size of binary file is 481 bytes

   [
     {
       -1:1,
       -2:h'65eda5a12577c2bae829437fe338701a10aaa375e1bb5b5de108de439c0
   8551d',
       -3:h'1e52ed75701163f7f9e40ddf9f341b3dc9ba860af7e0ca7ca7e9eecd008
   4d19c',
       1:2,
       2:'meriadoc.brandybuck@buckland.example'
     },
     {
       -1:1,
       -2:h'bac5b11cad8f99f9c72b05cf4b9e26d244dc189f745228255a219a86d6a
   09eff',
       -3:h'20138bf82dc1b6d562be0fa54ab7804a3a64b6d72ccfed6b6fb6ed28bbf
   c117e',
       1:2,
       2:'11'
     },
     {
       -1:3,
       -2:h'0072992cb3ac08ecf3e5c63dedec0d51a8c1f79ef2f82f94f3c737bf5de
   7986671eac625fe8257bbd0394644caaa3aaf8f27a4585fbbcad0f2457620085e5c8
   f42ad',
       -3:h'01dca6947bce88bc5790485ac97427342bc35f887d86d65a089377e247e
   60baa55e4e8501e2ada5724ac51d6909008033ebc10ac999b9d7f5cc2519f3fe1ea1
   d9475',
       1:2,
       2:'bilbo.baggins@hobbiton.example'
     },
     {
       -1:1,
       -2:h'98f50a4ff6c05861c8860d13a638ea56c3f5ad7590bbfbf054e1c7b4d91
   d6280',
       -3:h'f01400b089867804b8e9fc96c3932161f1934f4223069170d924b7e03bf
   822bb',
       1:2,
       2:'peregrin.took@tuckborough.example'
     }
   ]"""

# ---------------------------------------------------------------------
# Reading the published appendix
# ---------------------------------------------------------------------

type
  Example = object
    section: string
    title: string
    size: int
    diag: string

  Appendix = object
    examples: seq[Example]
    sectionsWithoutSize: int
    unreadable: seq[string]

const SizeMarker = "Size of binary file is "

proc isSectionHeading(line: string): bool =
  line.len > 3 and line[0] == 'C' and line[1] == '.' and
    not line.startsWith(" ")

proc headingSection(line: string): string =
  var i = 0
  while i < line.len and line[i] != ' ':
    inc i
  line[0 ..< i].strip(chars = {'.'})

proc parseAppendixC(text: string): Appendix =
  var lines = text.splitLines()
  var starts: seq[int] = @[]
  for i, line in lines:
    if isSectionHeading(line):
      starts.add i
  for n, s in starts:
    let e = if n + 1 < starts.len: starts[n + 1] else: lines.len
    var size = -1
    var sizeLine = -1
    for i in s ..< e:
      let at = lines[i].find(SizeMarker)
      if at >= 0:
        var j = at + SizeMarker.len
        var digits = ""
        while j < lines[i].len and lines[i][j] in Digits:
          digits.add lines[i][j]
          inc j
        size = parseInt(digits)
        sizeLine = i
        break
    if size < 0:
      inc result.sectionsWithoutSize
      continue
    # The diagnostic block: the lines after the size, grown one at a
    # time until they parse as ONE complete item. Growing rather than
    # bracket-counting means the trailing prose some sections carry
    # after the block is never taken for part of it, and a block that
    # does not parse is reported rather than silently shortened.
    var acc = ""
    var got = ""
    for i in sizeLine + 1 ..< e:
      if acc.len == 0 and lines[i].strip().len == 0:
        continue
      acc.add lines[i]
      acc.add "\n"
      if lines[i].strip().len == 0:
        continue
      try:
        discard parseDiagnostic(acc)
        got = acc
        break
      except CborError:
        discard
    let heading = lines[s]
    if got.len == 0:
      result.unreadable.add headingSection(heading)
      continue
    var title = heading
    let dot = title.find("  ")
    if dot >= 0:
      title = title[dot + 2 .. ^1].strip()
    result.examples.add Example(section: headingSection(heading),
                                title: title, size: size, diag: got)

let Corpus = parseAppendixC(Rfc9052AppendixC)

proc example(section: string): Example =
  for e in Corpus.examples:
    if e.section == section:
      return e
  raise newException(ValueError, "no example " & section)

proc itemOf(section: string): CborItem =
  parseDiagnostic(example(section).diag)

proc bytesOf(section: string): seq[byte] =
  encodeItem(itemOf(section))

# ---------------------------------------------------------------------
# The `/ protected h'…' / << … >>` cross-check
# ---------------------------------------------------------------------

type EmbeddedBlock = object
  publishedHex: string
  diag: string

proc normalizeSpace(text: string): string =
  var lastWasSpace = true
  for ch in text:
    if ch in {' ', '\t', '\r', '\n'}:
      if not lastWasSpace:
        result.add ' '
      lastWasSpace = true
    else:
      result.add ch
      lastWasSpace = false
  result = result.strip()

proc embeddedBlocks(text: string): seq[EmbeddedBlock] =
  ## Every `h'…' / << … >>` in the appendix: the byte string the RFC's
  ## own comment says the bucket encodes to, paired with the diagnostic
  ## notation that is supposed to produce it.
  const Open = "' / <<"
  let flat = normalizeSpace(text)
  var at = 0
  while true:
    let found = flat.find(Open, at)
    if found < 0:
      break
    at = found + Open.len
    # The hex runs backwards from the quote to the `h'` that opens it.
    var i = found
    while i > 0 and flat[i - 1] in HexDigits:
      dec i
    if i < 2 or flat[i - 1] != '\'' or flat[i - 2] != 'h':
      continue
    let hex = flat[i ..< found]
    let close = flat.find(">>", at)
    if close < 0:
      break
    result.add EmbeddedBlock(publishedHex: hex,
                             diag: flat[at ..< close].strip())
    at = close + 2

let Embedded = embeddedBlocks(Rfc9052AppendixC)

proc hexOf(b: openArray[byte]): string =
  for x in b:
    result.add toHex(int(x), 2).toLowerAscii()

# ---------------------------------------------------------------------
# The published keys
# ---------------------------------------------------------------------

let KeySet = parseCoseKeySet(itemOf("C.7.1"))

proc keyItem(i: int): CborItem = itemOf("C.7.1").elems[i]

proc kidOf(name: string): seq[byte] =
  for ch in name:
    result.add byte(ord(ch))

proc keyNamed(name: string): CoseKey =
  for k in KeySet.keys:
    if k.kid == kidOf(name):
      return k
  raise newException(ValueError, "no key " & name)

proc withEntry(m: CborItem; key, val: CborItem): CborItem =
  var entries: seq[CborPair] = @[]
  var replaced = false
  for e in m.entries:
    if equalValue(e.key, key):
      entries.add cPair(key, val)
      replaced = true
    else:
      entries.add e
  if not replaced:
    entries.add cPair(key, val)
  cMap(entries)

proc withoutEntry(m: CborItem; key: CborItem): CborItem =
  var entries: seq[CborPair] = @[]
  for e in m.entries:
    if not equalValue(e.key, key):
      entries.add e
  cMap(entries)

# ---------------------------------------------------------------------
# The instrument
# ---------------------------------------------------------------------

var reachedKinds: set[CoseErrorKind] = {}

template refusesWith(where: string; want: CoseErrorKind; body: untyped) =
  block:
    var raised = false
    try:
      body
    except CoseError as e:
      raised = true
      reachedKinds.incl e.kind
      noteSite(e.site.filename, e.site.line)
      if e.kind != want:
        checkpoint(where & ": wanted " & $want & ", got " & $e.kind &
          " — " & e.msg)
      check e.kind == want
    if not raised:
      checkpoint(where & ": nothing was refused")
    check raised

# The messages this gate verifies, and how many signatures each holds.
const SignExamples = [("C.1.1", 1), ("C.1.2", 2), ("C.1.3", 1)]
const Sign1Examples = ["C.2.1"]
const MeasuredOnly = ["C.3.1", "C.3.2", "C.3.3", "C.4.1", "C.4.2",
                      "C.5.1", "C.5.2", "C.5.3", "C.5.4", "C.6.1"]
const Payload = "This is the content."
let Understood = [cText("reserved")]

proc sign1Parts(): seq[CborItem] = itemOf("C.2.1").content.elems

proc rebuiltSign1(parts: openArray[CborItem]; tag = CoseSign1Tag): seq[byte] =
  encodeItem(cTag(tag, cArray(parts)))

proc protectedOf(map: CborItem): CborItem = cBytes(encodeItem(map))

suite "cose rfc 9052 appendix c corpus":

  test "t_cose_appendix_c_corpus_is_intact":
    check Corpus.unreadable.len == 0
    check Corpus.examples.len == 15
    check Corpus.sectionsWithoutSize == 7
    var sections: seq[string] = @[]
    for e in Corpus.examples:
      check e.size > 0
      check e.diag.len > 0
      sections.add e.section
    # The example set, by name, so one going missing is not absorbed
    # into a smaller loop.
    var expected: seq[string] = @[]
    for (s, _) in SignExamples: expected.add s
    for s in Sign1Examples: expected.add s
    for s in MeasuredOnly: expected.add s
    expected.add "C.7.1"
    check sections.len == expected.len
    for s in expected:
      check s in sections
    for s in sections:
      check s in expected
    check example("C.1.1").title == "Single Signature"
    check example("C.2.1").title == "Single ECDSA Signature"
    check example("C.7.1").title == "Public Keys"

  test "t_cose_appendix_c_published_sizes":
    # RFC 9052 states the encoded length of every example. Reproducing
    # all fifteen is a statement about this encoder that the document
    # made before this encoder existed.
    var compared = 0
    for e in Corpus.examples:
      let got = bytesOf(e.section).len
      if got != e.size:
        checkpoint("example " & e.section & " (" & e.title & ")")
      check got == e.size
      inc compared
    check compared == 15
    # Spot-pinned by value as well, so the loop cannot become vacuous:
    check example("C.2.1").size == 98
    check example("C.1.2").size == 277
    check example("C.7.1").size == 481

  test "t_cose_appendix_c_round_trips_and_is_deterministically_read":
    # Every example decodes to the item it was encoded from, and
    # re-encodes to the same bytes.
    var compared = 0
    for e in Corpus.examples:
      let raw = bytesOf(e.section)
      let back = decodeItem(raw)
      check equalValue(back, itemOf(e.section))
      check encodeItem(back) == raw
      inc compared
    check compared == 15

  test "t_cose_protected_buckets_match_the_published_comments":
    # Each `<< … >>` in the appendix is preceded by a comment giving the
    # bytes it encodes to. Twenty of them, each an independent
    # RFC-published expectation on this encoder.
    check Embedded.len == 20
    var compared = 0
    for b in Embedded:
      check b.publishedHex.len >= 6
      let got = hexOf(encodeItem(parseDiagnostic(b.diag)))
      if got != b.publishedHex:
        checkpoint("embedded block " & b.diag)
      check got == b.publishedHex
      inc compared
    check compared == 20
    # …and the same bytes read back as a header map.
    var distinctBuckets: seq[string] = @[]
    for b in Embedded:
      if b.publishedHex notin distinctBuckets:
        distinctBuckets.add b.publishedHex
      var raw: seq[byte] = @[]
      for i in 0 ..< b.publishedHex.len div 2:
        raw.add byte(parseHexInt(b.publishedHex[2 * i .. 2 * i + 1]))
      check decodeItem(raw).kind == ckMap
    check distinctBuckets.len == 12

suite "cose rfc 9052 public keys":

  test "t_cose_appendix_c_key_set":
    check KeySet.skipped == 0
    check KeySet.keys.len == 4
    var names: seq[string] = @[]
    for k in KeySet.keys:
      var s = ""
      for b in k.kid: s.add char(b)
      names.add s
    check names == @["meriadoc.brandybuck@buckland.example", "11",
                     "bilbo.baggins@hobbiton.example",
                     "peregrin.took@tuckborough.example"]
    var curves: seq[CoseCurve] = @[]
    for k in KeySet.keys:
      curves.add k.curve
      check k.point.len == 1 + 2 * CoseCurveCoordinateLen[k.curve]
      check k.point[0] == 0x04'u8
      check not k.hasAlgorithm
    check curves == @[ccP256, ccP256, ccP521, ccP256]
    # The RFC's leniency is a counted behaviour, not a silent one: a key
    # set with one unreadable element yields three keys and a skip.
    var mangled: seq[CborItem] = @[]
    for i in 0 ..< 4:
      mangled.add (if i == 2: cUInt(7) else: keyItem(i))
    let partial = parseCoseKeySet(cArray(mangled))
    check partial.keys.len == 3
    check partial.skipped == 1

suite "cose rfc 9052 signature verification":

  test "t_cose_appendix_c_signatures_verify":
    var verified = 0
    var algorithms: seq[CoseAlgorithm] = @[]
    for (section, count) in SignExamples:
      let got = verifyCoseSign(bytesOf(section), KeySet.keys,
                               understoodCritical = Understood)
      if got.len != count:
        checkpoint("example " & section)
      check got.len == count
      for v in got:
        var text = ""
        for b in v.payload: text.add char(b)
        check text == Payload
        algorithms.add v.algorithm
        verified.inc
    for section in Sign1Examples:
      let got = verifyCoseSign1(bytesOf(section), KeySet.keys)
      var text = ""
      for b in got.payload: text.add char(b)
      check text == Payload
      check got.kid == kidOf("11")
      algorithms.add got.algorithm
      verified.inc
    check verified == 5
    check algorithms == @[caEs256, caEs256, caEs512, caEs256, caEs256]
    # Both curves were exercised, which the algorithm list above says
    # and this restates as the thing that matters: P-521 arithmetic ran.
    check CoseAlgorithmCurve[caEs512] == ccP521
    check CoseCurveCoordinateLen[ccP521] == 66

  test "t_cose_sign_and_sign1_contexts_are_not_interchangeable":
    # The Sig_structure's first element is the reason a COSE_Sign
    # signature cannot be replayed as a COSE_Sign1 one. Pinned as bytes
    # against RFC 9052 §4.4, and then shown to matter.
    let protectedBytes = hexOf(itemOf("C.2.1").content.elems[0].bytes)
    check protectedBytes == "a10126"
    var payload: seq[byte] = @[]
    for ch in Payload: payload.add byte(ord(ch))
    let one = sigStructureSign1(
      itemOf("C.2.1").content.elems[0].bytes, [], payload)
    let many = sigStructureSign(
      itemOf("C.2.1").content.elems[0].bytes, [], [], payload)
    check one != many
    # The exact bytes, assembled from §4.4's CDDL rather than from this
    # module's output: [ "Signature1", h'a10126', h'', 'This is the
    # content.' ] is a 4-element array, a 10-character text string, a
    # 3-byte string, a 0-byte string and a 20-byte string.
    check hexOf(one) ==
      "84" & "6a" & "5369676e617475726531" & "43" & "a10126" & "40" &
      "54" & "546869732069732074686520636f6e74656e742e"
    check hexOf(many) ==
      "85" & "69" & "5369676e6174757265" & "43" & "a10126" & "40" & "40" &
      "54" & "546869732069732074686520636f6e74656e742e"
    check one.len == 1 + 1 + 10 + 1 + 3 + 1 + 1 + 20
    check many.len == 1 + 1 + 9 + 1 + 3 + 1 + 1 + 1 + 20
    # …and the signature C.2.1 publishes does not verify under the
    # COSE_Sign framing, which is the property those bytes exist for.
    refusesWith("C.2.1 read as a COSE_Sign body", cxeSignatureDidNotVerify):
      let parts = sign1Parts()
      discard verifyCoseSign(
        encodeItem(cTag(CoseSignTag, cArray(
          [parts[0], cMap([]), parts[2],
           cArray([cArray([parts[0], parts[1], parts[3]])])]))),
        KeySet.keys)

  test "t_cose_criticality_refuses_by_default_and_accepts_when_declared":
    # C.1.3 carries `crit: ["reserved"]`. A verifier that has not said
    # it understands "reserved" MUST refuse it; the same bytes with the
    # declaration verify. Both directions, because either alone would
    # be satisfied by a rule that always did one thing.
    refusesWith("C.1.3 without a declaration", cxeCritLabelNotUnderstood):
      discard verifyCoseSign(bytesOf("C.1.3"), KeySet.keys)
    check verifyCoseSign(bytesOf("C.1.3"), KeySet.keys,
                         understoodCritical = Understood).len == 1
    # Declaring a DIFFERENT label does not help, so the declaration is
    # matched rather than merely counted.
    refusesWith("C.1.3 with the wrong declaration",
                cxeCritLabelNotUnderstood):
      discard verifyCoseSign(bytesOf("C.1.3"), KeySet.keys,
                             understoodCritical = [cText("other")])
    # And the two examples with no `crit` verify with no declaration,
    # so the default is not refusing everything.
    check verifyCoseSign(bytesOf("C.1.1"), KeySet.keys).len == 1
    check verifyCoseSign(bytesOf("C.1.2"), KeySet.keys).len == 2

  test "t_cose_detached_payload_round_trip":
    # RFC 9052 §4.1: a detached payload is a nil in the payload slot and
    # the application supplies the bytes. The signature is over the
    # payload either way, so C.2.1 with its payload removed must still
    # verify when the payload is handed in — and must refuse when it is
    # not.
    var parts = sign1Parts()
    let original = parts[2].bytes
    parts[2] = cNull()
    let detachedMessage = rebuiltSign1(parts)
    refusesWith("detached, nothing supplied", cxeDetachedPayloadMissing):
      discard verifyCoseSign1(detachedMessage, KeySet.keys)
    let got = verifyCoseSign1(detachedMessage, KeySet.keys,
                              detachedPayload = original,
                              detachedPayloadSupplied = true)
    check got.payload == original
    # Supplying the WRONG detached payload fails the signature rather
    # than being accepted, which is what says the supplied bytes really
    # entered the Sig_structure.
    var wrong = original
    wrong[0] = wrong[0] xor 0x01'u8
    refusesWith("detached, wrong bytes", cxeSignatureDidNotVerify):
      discard verifyCoseSign1(detachedMessage, KeySet.keys,
                              detachedPayload = wrong,
                              detachedPayloadSupplied = true)
    # And a message that carries its own payload refuses a detached one.
    refusesWith("attached and detached at once",
                cxeDetachedPayloadUnexpected):
      discard verifyCoseSign1(bytesOf("C.2.1"), KeySet.keys,
                              detachedPayload = original,
                              detachedPayloadSupplied = true)

  test "t_cose_signature_covers_every_part_of_the_sig_structure":
    # Four mutations, each touching a DIFFERENT element of the
    # Sig_structure, each of which must break the signature. Without
    # these, "the signature verified" says only that some bytes were
    # signed.
    var parts = sign1Parts()
    check parts.len == 4
    # 1. the payload
    var flipped = parts
    var payload = parts[2].bytes
    payload[3] = payload[3] xor 0x01'u8
    flipped[2] = cBytes(payload)
    refusesWith("payload bit flipped", cxeSignatureDidNotVerify):
      discard verifyCoseSign1(rebuiltSign1(flipped), KeySet.keys)
    # 2. the signature itself
    flipped = parts
    var sig = parts[3].bytes
    sig[^1] = sig[^1] xor 0x01'u8
    flipped[3] = cBytes(sig)
    refusesWith("signature bit flipped", cxeSignatureDidNotVerify):
      discard verifyCoseSign1(rebuiltSign1(flipped), KeySet.keys)
    # 3. the protected bucket, re-spelled rather than changed. `{1: -7}`
    #    with the -7 written in two bytes instead of one decodes to the
    #    SAME map and is different bytes, so a verifier that re-encoded
    #    the bucket instead of using the bytes it arrived as would
    #    accept this. RFC 9052 §3 says that would be wrong.
    flipped = parts
    let respelled = @[0xa1'u8, 0x01'u8, 0x38'u8, 0x06'u8]
    check equalValue(decodeItem(respelled), decodeItem(parts[0].bytes))
    check respelled != parts[0].bytes
    flipped[0] = cBytes(respelled)
    refusesWith("protected bucket re-spelled", cxeSignatureDidNotVerify):
      discard verifyCoseSign1(rebuiltSign1(flipped), KeySet.keys)
    # 4. the external_aad, which is empty in every published example and
    #    would therefore never be exercised by them.
    refusesWith("external_aad supplied", cxeSignatureDidNotVerify):
      discard verifyCoseSign1(bytesOf("C.2.1"), KeySet.keys,
                              externalAad = [0x00'u8])
    # The unmutated message still verifies in this case's own scope, so
    # none of the four above is passing because the baseline is broken.
    check verifyCoseSign1(bytesOf("C.2.1"), KeySet.keys).payload.len == 20

suite "cose structural refusals":

  test "t_cose_malformed_cbor_never_becomes_a_verified_message":
    # The shape this whole library exists to avoid: a parse that failed,
    # read as "there was nothing to object to". Truncating the message
    # and appending to it are both CBOR failures, and both must surface
    # as refusals rather than as an empty structure that satisfies every
    # later check.
    let full = bytesOf("C.2.1")
    # The baseline verifies, in this case's own scope, so none of the
    # four refusals below can be passing because the message was already
    # unusable.
    check full.len == 98
    check verifyCoseSign1(full, KeySet.keys).payload.len == 20
    refusesWith("truncated message", cxeMalformedCbor):
      discard verifyCoseSign1(full[0 ..< full.len - 10], KeySet.keys)
    refusesWith("message with a byte appended", cxeMalformedCbor):
      var extra = full
      extra.add 0x00'u8
      discard verifyCoseSign1(extra, KeySet.keys)
    refusesWith("empty input", cxeMalformedCbor):
      discard verifyCoseSign1([], KeySet.keys)
    refusesWith("protected bucket is not CBOR", cxeMalformedCbor):
      var parts = sign1Parts()
      parts[0] = cBytes([0xff'u8])
      discard verifyCoseSign1(rebuiltSign1(parts), KeySet.keys)

  test "t_cose_envelope_refusals":
    var parts = sign1Parts()
    refusesWith("tag 17", cxeWrongTag):
      discard verifyCoseSign1(rebuiltSign1(parts, 17'u64), KeySet.keys)
    refusesWith("untagged", cxeNotTagged):
      discard verifyCoseSign1(encodeItem(cArray(parts)), KeySet.keys)
    # …and untagged is accepted when the caller says so, so the refusal
    # above is the requirement doing its job rather than a parse failure.
    check verifyCoseSign1(encodeItem(cArray(parts)), KeySet.keys,
                          requireTag = false).payload.len == 20
    refusesWith("not an array", cxeNotArray):
      discard verifyCoseSign1(encodeItem(cTag(CoseSign1Tag, cMap([]))),
                              KeySet.keys)
    refusesWith("three elements", cxeWrongArity):
      discard verifyCoseSign1(rebuiltSign1(parts[0 .. 2]), KeySet.keys)
    var broken = parts
    broken[0] = cMap([])
    refusesWith("protected is a map", cxeProtectedNotBytes):
      discard verifyCoseSign1(rebuiltSign1(broken), KeySet.keys)
    broken = parts
    broken[0] = cBytes(encodeItem(cArray([])))
    refusesWith("protected holds an array", cxeProtectedNotMap):
      discard verifyCoseSign1(rebuiltSign1(broken), KeySet.keys)
    broken = parts
    broken[1] = cBytes([])
    refusesWith("unprotected is a byte string", cxeUnprotectedNotMap):
      discard verifyCoseSign1(rebuiltSign1(broken), KeySet.keys)
    broken = parts
    broken[2] = cText("not bytes")
    refusesWith("payload is text", cxePayloadNotBytes):
      discard verifyCoseSign1(rebuiltSign1(broken), KeySet.keys)
    broken = parts
    broken[3] = cUInt(1)
    refusesWith("signature is an integer", cxeSignatureNotBytes):
      discard verifyCoseSign1(rebuiltSign1(broken), KeySet.keys)
    broken = parts
    broken[3] = cBytes(parts[3].bytes[0 ..< 63])
    refusesWith("signature is 63 bytes", cxeSignatureWrongLength):
      discard verifyCoseSign1(rebuiltSign1(broken), KeySet.keys)
    # An empty protected bucket is legal and so is `h'a0'`; RFC 9052 §3
    # requires recipients to accept both. Neither verifies here, because
    # the alg is what the bucket carried — the point is WHICH refusal.
    broken = parts
    broken[0] = cBytes([])
    refusesWith("empty protected bucket", cxeNoAlgorithm):
      discard verifyCoseSign1(rebuiltSign1(broken), KeySet.keys)
    broken[0] = cBytes(encodeItem(cMap([])))
    refusesWith("zero-length map bucket", cxeNoAlgorithm):
      discard verifyCoseSign1(rebuiltSign1(broken), KeySet.keys)

  test "t_cose_header_refusals":
    var parts = sign1Parts()
    check parts.len == 4
    check verifyCoseSign1(bytesOf("C.2.1"), KeySet.keys).algorithm == caEs256
    var broken = parts
    broken[0] = protectedOf(cMap([cPair(cUInt(1), cText("ES256"))]))
    refusesWith("alg is a text string", cxeAlgorithmNotInteger):
      discard verifyCoseSign1(rebuiltSign1(broken), KeySet.keys)
    broken[0] = protectedOf(cMap([cPair(cUInt(1), cNegInt(7))]))
    refusesWith("alg -8", cxeUnsupportedAlgorithm):
      discard verifyCoseSign1(rebuiltSign1(broken), KeySet.keys)
    broken = parts
    broken[1] = withEntry(parts[1], cUInt(1), cNegInt(6))
    refusesWith("alg in both buckets", cxeDuplicateLabelAcrossBuckets):
      discard verifyCoseSign1(rebuiltSign1(broken), KeySet.keys)
    broken = parts
    broken[1] = cMap([])
    refusesWith("no kid", cxeNoKeyIdentifier):
      discard verifyCoseSign1(rebuiltSign1(broken), KeySet.keys)
    broken[1] = cMap([cPair(cUInt(4), cUInt(11))])
    refusesWith("kid is an integer", cxeKeyIdentifierNotBytes):
      discard verifyCoseSign1(rebuiltSign1(broken), KeySet.keys)
    broken[1] = cMap([cPair(cUInt(4), cBytes(kidOf("nobody")))])
    refusesWith("unknown kid", cxeKeyNotFound):
      discard verifyCoseSign1(rebuiltSign1(broken), KeySet.keys)

  test "t_cose_criticality_refusals":
    var parts = sign1Parts()
    check parts.len == 4
    # A `crit` that names a label the protected bucket carries AND the
    # caller understands is accepted, so the four refusals below are the
    # individual rules and not `crit` being refused outright.
    check verifyCoseSign(bytesOf("C.1.3"), KeySet.keys,
                         understoodCritical = Understood).len == 1
    var broken = parts
    broken[1] = withEntry(parts[1], cUInt(2), cArray([cText("x")]))
    refusesWith("crit in the unprotected bucket", cxeCritNotProtected):
      discard verifyCoseSign1(rebuiltSign1(broken), KeySet.keys)
    broken = parts
    broken[0] = protectedOf(cMap([cPair(cUInt(1), cNegInt(6)),
                                  cPair(cUInt(2), cUInt(5))]))
    refusesWith("crit is an integer", cxeCritNotArray):
      discard verifyCoseSign1(rebuiltSign1(broken), KeySet.keys)
    broken[0] = protectedOf(cMap([cPair(cUInt(1), cNegInt(6)),
                                  cPair(cUInt(2), cArray([]))]))
    refusesWith("crit is empty", cxeCritEmpty):
      discard verifyCoseSign1(rebuiltSign1(broken), KeySet.keys)
    broken[0] = protectedOf(cMap([cPair(cUInt(1), cNegInt(6)),
                                  cPair(cUInt(2), cArray([cText("gone")]))]))
    refusesWith("crit names an absent label",
                cxeCritLabelNotInProtectedBucket):
      discard verifyCoseSign1(rebuiltSign1(broken), KeySet.keys,
                              understoodCritical = [cText("gone")])

  test "t_cose_multi_signer_refusals":
    var body = itemOf("C.1.1").content.elems
    check body.len == 4
    var broken = body
    broken[3] = cMap([])
    refusesWith("signatures is a map", cxeSignaturesNotArray):
      discard verifyCoseSign(encodeItem(cTag(CoseSignTag, cArray(broken))),
                             KeySet.keys)
    broken[3] = cArray([])
    refusesWith("no signatures", cxeNoSignatures):
      discard verifyCoseSign(encodeItem(cTag(CoseSignTag, cArray(broken))),
                             KeySet.keys)
    broken[3] = cArray([cArray([body[3].elems[0].elems[0],
                                body[3].elems[0].elems[1]])])
    refusesWith("a COSE_Signature of two elements", cxeWrongArity):
      discard verifyCoseSign(encodeItem(cTag(CoseSignTag, cArray(broken))),
                             KeySet.keys)
    broken[3] = cArray([cUInt(1)])
    refusesWith("a COSE_Signature that is an integer", cxeNotArray):
      discard verifyCoseSign(encodeItem(cTag(CoseSignTag, cArray(broken))),
                             KeySet.keys)
    refusesWith("a COSE_Sign body that is a map", cxeNotArray):
      discard verifyCoseSign(encodeItem(cTag(CoseSignTag, cMap([]))),
                             KeySet.keys)
    refusesWith("a COSE_Sign body of three elements", cxeWrongArity):
      discard verifyCoseSign(
        encodeItem(cTag(CoseSignTag, cArray(body[0 .. 2]))), KeySet.keys)
    # Every signature must verify: C.1.2 with its second signer's
    # signature corrupted is refused even though the first is intact.
    var two = itemOf("C.1.2").content.elems
    var signers = two[3].elems
    var second = signers[1].elems
    var sig = second[2].bytes
    sig[^1] = sig[^1] xor 0x01'u8
    second[2] = cBytes(sig)
    signers[1] = cArray(second)
    two[3] = cArray(signers)
    refusesWith("one of two signers corrupted", cxeSignatureDidNotVerify):
      discard verifyCoseSign(encodeItem(cTag(CoseSignTag, cArray(two))),
                             KeySet.keys)

  test "t_cose_key_refusals":
    refusesWith("key set is a map", cxeKeySetNotArray):
      discard parseCoseKeySet(cMap([]))
    refusesWith("key is an array", cxeKeyNotMap):
      discard parseCoseKey(cArray([]))
    let k = keyItem(1)
    check parseCoseKey(k).kid == kidOf("11")
    refusesWith("kty is OKP", cxeKeyNotEc2):
      discard parseCoseKey(withEntry(k, cUInt(1), cUInt(1)))
    refusesWith("no crv", cxeKeyCurveMissing):
      discard parseCoseKey(withoutEntry(k, cNegInt(0)))
    refusesWith("crv is X25519", cxeKeyCurveUnsupported):
      discard parseCoseKey(withEntry(k, cNegInt(0), cUInt(4)))
    refusesWith("crv is a text string", cxeKeyCurveUnsupported):
      discard parseCoseKey(withEntry(k, cNegInt(0), cText("P-256")))
    refusesWith("no x coordinate", cxeKeyCoordinateMissing):
      discard parseCoseKey(withoutEntry(k, cNegInt(1)))
    refusesWith("x is 31 bytes", cxeKeyCoordinateWrongLength):
      discard parseCoseKey(withEntry(k, cNegInt(1),
        cBytes(k.lookupInt(-2).bytes[0 ..< 31])))
    refusesWith("kid is not a byte string", cxeKeyIdentifierNotBytes):
      discard parseCoseKey(withEntry(k, cUInt(2), cUInt(11)))
    # A key that restricts itself to ES384 cannot verify an ES256
    # signature, and a P-521 key cannot be used for ES256 at all.
    let restricted = parseCoseKey(withEntry(k, cUInt(3), cNegInt(34)))
    check restricted.hasAlgorithm
    check restricted.algorithm == caEs384
    refusesWith("key restricted to ES384", cxeKeyAlgorithmRestricted):
      discard verifyCoseSign1(bytesOf("C.2.1"), [restricted])
    let wrongCurve = parseCoseKey(
      withEntry(keyItem(2), cUInt(2), cBytes(kidOf("11"))))
    check wrongCurve.curve == ccP521
    refusesWith("P-521 key for ES256", cxeKeyCurveAlgorithmMismatch):
      discard verifyCoseSign1(bytesOf("C.2.1"), [wrongCurve])
    # A key the CALLER BUILT rather than one this module parsed.
    # `parseCoseKey` cannot emit a point of the wrong width, so every
    # case above reaches the verifier with a well-formed point — and the
    # first non-test consumer of this module will not, because a public
    # key that arrives in a certificate never goes through `parseCoseKey`
    # at all. Without this case the width rule has no input, and the
    # message path reads past the end of the buffer instead of refusing.
    var handBuilt = keyNamed("11")
    check handBuilt.point.len == 65
    handBuilt.point = handBuilt.point[0 ..< 40]
    refusesWith("a hand-built key whose point is 40 bytes",
                cxeKeyCoordinateWrongLength):
      discard verifyCoseSign1(bytesOf("C.2.1"), [handBuilt])
    # The primitive declines the same key by value rather than by
    # dereferencing it, which is the layer underneath that refusal.
    check not ecdsaSignatureIsValid(handBuilt, caEs256, [0'u8],
                                    newSeq[byte](64))
    var emptyPoint = keyNamed("11")
    emptyPoint.point = @[]
    refusesWith("a hand-built key with no point at all",
                cxeKeyCoordinateWrongLength):
      discard verifyCoseSign1(bytesOf("C.2.1"), [emptyPoint])
    check not ecdsaSignatureIsValid(emptyPoint, caEs256, [0'u8],
                                    newSeq[byte](64))
    # …and the same key at its published width still verifies C.2.1, so
    # the three refusals above are about the width and not about the key.
    check verifyCoseSign1(bytesOf("C.2.1"),
                          [keyNamed("11")]).payload.len == 20


# ---------------------------------------------------------------------
# The ECDSA primitive, pinned against RFC 6979 Appendix A.2
# ---------------------------------------------------------------------
#
# RFC 9052 Appendix C publishes no ES384 message — no example anywhere
# in the document uses P-384 — so a COSE vector cannot reach that path
# at all. RFC 6979 Appendix A.2.5, A.2.6 and A.2.7 publish a key pair
# and a table of signatures for P-256, P-384 and P-521 with five hash
# functions each, which pins the curve-and-hash wiring directly:
#
#   https://www.rfc-editor.org/rfc/rfc6979.txt
#   sha256 456e8f17558fdbd206f968b96fc6f1b4a71ea331ab30ad17f711ab3adaa7d701
#
# lines 1799-2302 of that file. RFC 6979 is about how a signer chooses
# k; verification does not depend on that choice, so its (r, s) pairs
# are ordinary ECDSA signatures and are usable as verification vectors.
# The excerpt is VERBATIM, page headers, footers and form feeds
# included, and the parser below ignores them the same way it ignores
# every other line that is not a field.
#
# The private keys the appendix publishes are in the excerpt because
# removing them would stop it being verbatim. Nothing reads them: only
# `curve`, `Ux`, `Uy`, `r` and `s` are used, and this build cannot sign.

const Rfc6979AppendixA2 = """A.2.5.  ECDSA, 256 Bits (Prime Field)

   Key pair:

   curve: NIST P-256

   q = FFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551
   (qlen = 256 bits)

   private key:

   x = C9AFA9D845BA75166B5C215767B1D6934E50C3DB36E89B127B8A622B120F6721

   public key: U = xG

   Ux = 60FED4BA255A9D31C961EB74C6356D68C049B8923B61FA6CE669622E60F29FB6

   Uy = 7903FE1008B8BC99A41AE9E95628BC64F2F1B20C2D7E9F5177A3C294D4462299

   Signatures:

   With SHA-1, message = "sample":
   k = 882905F1227FD620FBF2ABF21244F0BA83D0DC3A9103DBBEE43A1FB858109DB4
   r = 61340C88C3AAEBEB4F6D667F672CA9759A6CCAA9FA8811313039EE4A35471D32
   s = 6D7F147DAC089441BB2E2FE8F7A3FA264B9C475098FDCF6E00D7C996E1B8B7EB

   With SHA-224, message = "sample":
   k = 103F90EE9DC52E5E7FB5132B7033C63066D194321491862059967C715985D473
   r = 53B2FFF5D1752B2C689DF257C04C40A587FABABB3F6FC2702F1343AF7CA9AA3F
   s = B9AFB64FDC03DC1A131C7D2386D11E349F070AA432A4ACC918BEA988BF75C74C

   With SHA-256, message = "sample":
   k = A6E3C57DD01ABE90086538398355DD4C3B17AA873382B0F24D6129493D8AAD60
   r = EFD48B2AACB6A8FD1140DD9CD45E81D69D2C877B56AAF991C34D0EA84EAF3716
   s = F7CB1C942D657C41D436C7A1B6E29F65F3E900DBB9AFF4064DC4AB2F843ACDA8

   With SHA-384, message = "sample":
   k = 09F634B188CEFD98E7EC88B1AA9852D734D0BC272F7D2A47DECC6EBEB375AAD4
   r = 0EAFEA039B20E9B42309FB1D89E213057CBF973DC0CFC8F129EDDDC800EF7719
   s = 4861F0491E6998B9455193E34E7B0D284DDD7149A74B95B9261F13ABDE940954

   With SHA-512, message = "sample":
   k = 5FA81C63109BADB88C1F367B47DA606DA28CAD69AA22C4FE6AD7DF73A7173AA5
   r = 8496A60B5E9B47C825488827E0495B0E3FA109EC4568FD3F8D1097678EB97F00
   s = 2362AB1ADBE2B8ADF9CB9EDAB740EA6049C028114F2460F96554F61FAE3302FE






Pornin                        Informational                    [Page 33]

RFC 6979               Deterministic DSA and ECDSA           August 2013


   With SHA-1, message = "test":
   k = 8C9520267C55D6B980DF741E56B4ADEE114D84FBFA2E62137954164028632A2E
   r = 0CBCC86FD6ABD1D99E703E1EC50069EE5C0B4BA4B9AC60E409E8EC5910D81A89
   s = 01B9D7B73DFAA60D5651EC4591A0136F87653E0FD780C3B1BC872FFDEAE479B1

   With SHA-224, message = "test":
   k = 669F4426F2688B8BE0DB3A6BD1989BDAEFFF84B649EEB84F3DD26080F667FAA7
   r = C37EDB6F0AE79D47C3C27E962FA269BB4F441770357E114EE511F662EC34A692
   s = C820053A05791E521FCAAD6042D40AEA1D6B1A540138558F47D0719800E18F2D

   With SHA-256, message = "test":
   k = D16B6AE827F17175E040871A1C7EC3500192C4C92677336EC2537ACAEE0008E0
   r = F1ABB023518351CD71D881567B1EA663ED3EFCF6C5132B354F28D3B0B7D38367
   s = 019F4113742A2B14BD25926B49C649155F267E60D3814B4C0CC84250E46F0083

   With SHA-384, message = "test":
   k = 16AEFFA357260B04B1DD199693960740066C1A8F3E8EDD79070AA914D361B3B8
   r = 83910E8B48BB0C74244EBDF7F07A1C5413D61472BD941EF3920E623FBCCEBEB6
   s = 8DDBEC54CF8CD5874883841D712142A56A8D0F218F5003CB0296B6B509619F2C

   With SHA-512, message = "test":
   k = 6915D11632ACA3C40D5D51C08DAF9C555933819548784480E93499000D9F0B7F
   r = 461D93F31B6540894788FD206C07CFA0CC35F46FA3C91816FFF1040AD1581A04
   s = 39AF9F15DE0DB8D97E72719C74820D304CE5226E32DEDAE67519E840D1194E55



























Pornin                        Informational                    [Page 34]

RFC 6979               Deterministic DSA and ECDSA           August 2013


A.2.6.  ECDSA, 384 Bits (Prime Field)

   Key pair:

   curve: NIST P-384

   q = FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFC7634D81F4372DDF
       581A0DB248B0A77AECEC196ACCC52973
   (qlen = 384 bits)

   private key:

   x = 6B9D3DAD2E1B8C1C05B19875B6659F4DE23C3B667BF297BA9AA47740787137D8
       96D5724E4C70A825F872C9EA60D2EDF5

   public key: U = xG

   Ux = EC3A4E415B4E19A4568618029F427FA5DA9A8BC4AE92E02E06AAE5286B300C64
        DEF8F0EA9055866064A254515480BC13

   Uy = 8015D9B72D7D57244EA8EF9AC0C621896708A59367F9DFB9F54CA84B3F1C9DB1
        288B231C3AE0D4FE7344FD2533264720

   Signatures:

   With SHA-1, message = "sample":
   k = 4471EF7518BB2C7C20F62EAE1C387AD0C5E8E470995DB4ACF694466E6AB09663
       0F29E5938D25106C3C340045A2DB01A7
   r = EC748D839243D6FBEF4FC5C4859A7DFFD7F3ABDDF72014540C16D73309834FA3
       7B9BA002899F6FDA3A4A9386790D4EB2
   s = A3BCFA947BEEF4732BF247AC17F71676CB31A847B9FF0CBC9C9ED4C1A5B3FACF
       26F49CA031D4857570CCB5CA4424A443

   With SHA-224, message = "sample":
   k = A4E4D2F0E729EB786B31FC20AD5D849E304450E0AE8E3E341134A5C1AFA03CAB
       8083EE4E3C45B06A5899EA56C51B5879
   r = 42356E76B55A6D9B4631C865445DBE54E056D3B3431766D0509244793C3F9366
       450F76EE3DE43F5A125333A6BE060122
   s = 9DA0C81787064021E78DF658F2FBB0B042BF304665DB721F077A4298B095E483
       4C082C03D83028EFBF93A3C23940CA8D

   With SHA-256, message = "sample":
   k = 180AE9F9AEC5438A44BC159A1FCB277C7BE54FA20E7CF404B490650A8ACC414E
       375572342863C899F9F2EDF9747A9B60
   r = 21B13D1E013C7FA1392D03C5F99AF8B30C570C6F98D4EA8E354B63A21D3DAA33
       BDE1E888E63355D92FA2B3C36D8FB2CD
   s = F3AA443FB107745BF4BD77CB3891674632068A10CA67E3D45DB2266FA7D1FEEB
       EFDC63ECCD1AC42EC0CB8668A4FA0AB0



Pornin                        Informational                    [Page 35]

RFC 6979               Deterministic DSA and ECDSA           August 2013


   With SHA-384, message = "sample":
   k = 94ED910D1A099DAD3254E9242AE85ABDE4BA15168EAF0CA87A555FD56D10FBCA
       2907E3E83BA95368623B8C4686915CF9
   r = 94EDBB92A5ECB8AAD4736E56C691916B3F88140666CE9FA73D64C4EA95AD133C
       81A648152E44ACF96E36DD1E80FABE46
   s = 99EF4AEB15F178CEA1FE40DB2603138F130E740A19624526203B6351D0A3A94F
       A329C145786E679E7B82C71A38628AC8

   With SHA-512, message = "sample":
   k = 92FC3C7183A883E24216D1141F1A8976C5B0DD797DFA597E3D7B32198BD35331
       A4E966532593A52980D0E3AAA5E10EC3
   r = ED0959D5880AB2D869AE7F6C2915C6D60F96507F9CB3E047C0046861DA4A799C
       FE30F35CC900056D7C99CD7882433709
   s = 512C8CCEEE3890A84058CE1E22DBC2198F42323CE8ACA9135329F03C068E5112
       DC7CC3EF3446DEFCEB01A45C2667FDD5

   With SHA-1, message = "test":
   k = 66CC2C8F4D303FC962E5FF6A27BD79F84EC812DDAE58CF5243B64A4AD8094D47
       EC3727F3A3C186C15054492E30698497
   r = 4BC35D3A50EF4E30576F58CD96CE6BF638025EE624004A1F7789A8B8E43D0678
       ACD9D29876DAF46638645F7F404B11C7
   s = D5A6326C494ED3FF614703878961C0FDE7B2C278F9A65FD8C4B7186201A29916
       95BA1C84541327E966FA7B50F7382282

   With SHA-224, message = "test":
   k = 18FA39DB95AA5F561F30FA3591DC59C0FA3653A80DAFFA0B48D1A4C6DFCBFF6E
       3D33BE4DC5EB8886A8ECD093F2935726
   r = E8C9D0B6EA72A0E7837FEA1D14A1A9557F29FAA45D3E7EE888FC5BF954B5E624
       64A9A817C47FF78B8C11066B24080E72
   s = 07041D4A7A0379AC7232FF72E6F77B6DDB8F09B16CCE0EC3286B2BD43FA8C614
       1C53EA5ABEF0D8231077A04540A96B66

   With SHA-256, message = "test":
   k = 0CFAC37587532347DC3389FDC98286BBA8C73807285B184C83E62E26C401C0FA
       A48DD070BA79921A3457ABFF2D630AD7
   r = 6D6DEFAC9AB64DABAFE36C6BF510352A4CC27001263638E5B16D9BB51D451559
       F918EEDAF2293BE5B475CC8F0188636B
   s = 2D46F3BECBCC523D5F1A1256BF0C9B024D879BA9E838144C8BA6BAEB4B53B47D
       51AB373F9845C0514EEFB14024787265

   With SHA-384, message = "test":
   k = 015EE46A5BF88773ED9123A5AB0807962D193719503C527B031B4C2D225092AD
       A71F4A459BC0DA98ADB95837DB8312EA
   r = 8203B63D3C853E8D77227FB377BCF7B7B772E97892A80F36AB775D509D7A5FEB
       0542A7F0812998DA8F1DD3CA3CF023DB
   s = DDD0760448D42D8A43AF45AF836FCE4DE8BE06B485E9B61B827C2F13173923E0
       6A739F040649A667BF3B828246BAA5A5




Pornin                        Informational                    [Page 36]

RFC 6979               Deterministic DSA and ECDSA           August 2013


   With SHA-512, message = "test":
   k = 3780C4F67CB15518B6ACAE34C9F83568D2E12E47DEAB6C50A4E4EE5319D1E8CE
       0E2CC8A136036DC4B9C00E6888F66B6C
   r = A0D5D090C9980FAF3C2CE57B7AE951D31977DD11C775D314AF55F76C676447D0
       6FB6495CD21B4B6E340FC236584FB277
   s = 976984E59B4C77B0E8E4460DCA3D9F20E07B9BB1F63BEEFAF576F6B2E8B22463
       4A2092CD3792E0159AD9CEE37659C736












































Pornin                        Informational                    [Page 37]

RFC 6979               Deterministic DSA and ECDSA           August 2013


A.2.7.  ECDSA, 521 Bits (Prime Field)

   Key pair:

   curve: NIST P-521

   q = 1FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF
       FFA51868783BF2F966B7FCC0148F709A5D03BB5C9B8899C47AEBB6FB71E91386
       409
   (qlen = 521 bits)

   private key:

   x = 0FAD06DAA62BA3B25D2FB40133DA757205DE67F5BB0018FEE8C86E1B68C7E75C
       AA896EB32F1F47C70855836A6D16FCC1466F6D8FBEC67DB89EC0C08B0E996B83
       538

   public key: U = xG

   Ux = 1894550D0785932E00EAA23B694F213F8C3121F86DC97A04E5A7167DB4E5BCD3
        71123D46E45DB6B5D5370A7F20FB633155D38FFA16D2BD761DCAC474B9A2F502
        3A4

   Uy = 0493101C962CD4D2FDDF782285E64584139C2F91B47F87FF82354D6630F746A2
        8A0DB25741B5B34A828008B22ACC23F924FAAFBD4D33F81EA66956DFEAA2BFDF
        CF5

   Signatures:

   With SHA-1, message = "sample":
   k = 089C071B419E1C2820962321787258469511958E80582E95D8378E0C2CCDB3CB
       42BEDE42F50E3FA3C71F5A76724281D31D9C89F0F91FC1BE4918DB1C03A5838D
       0F9
   r = 0343B6EC45728975EA5CBA6659BBB6062A5FF89EEA58BE3C80B619F322C87910
       FE092F7D45BB0F8EEE01ED3F20BABEC079D202AE677B243AB40B5431D497C55D
       75D
   s = 0E7B0E675A9B24413D448B8CC119D2BF7B2D2DF032741C096634D6D65D0DBE3D
       5694625FB9E8104D3B842C1B0E2D0B98BEA19341E8676AEF66AE4EBA3D5475D5
       D16












Pornin                        Informational                    [Page 38]

RFC 6979               Deterministic DSA and ECDSA           August 2013


   With SHA-224, message = "sample":
   k = 121415EC2CD7726330A61F7F3FA5DE14BE9436019C4DB8CB4041F3B54CF31BE0
       493EE3F427FB906393D895A19C9523F3A1D54BB8702BD4AA9C99DAB2597B9211
       3F3
   r = 1776331CFCDF927D666E032E00CF776187BC9FDD8E69D0DABB4109FFE1B5E2A3
       0715F4CC923A4A5E94D2503E9ACFED92857B7F31D7152E0F8C00C15FF3D87E2E
       D2E
   s = 050CB5265417FE2320BBB5A122B8E1A32BD699089851128E360E620A30C7E17B
       A41A666AF126CE100E5799B153B60528D5300D08489CA9178FB610A2006C254B
       41F

   With SHA-256, message = "sample":
   k = 0EDF38AFCAAECAB4383358B34D67C9F2216C8382AAEA44A3DAD5FDC9C3257576
       1793FEF24EB0FC276DFC4F6E3EC476752F043CF01415387470BCBD8678ED2C7E
       1A0
   r = 1511BB4D675114FE266FC4372B87682BAECC01D3CC62CF2303C92B3526012659
       D16876E25C7C1E57648F23B73564D67F61C6F14D527D54972810421E7D87589E
       1A7
   s = 04A171143A83163D6DF460AAF61522695F207A58B95C0644D87E52AA1A347916
       E4F7A72930B1BC06DBE22CE3F58264AFD23704CBB63B29B931F7DE6C9D949A7E
       CFC

   With SHA-384, message = "sample":
   k = 1546A108BC23A15D6F21872F7DED661FA8431DDBD922D0DCDB77CC878C8553FF
       AD064C95A920A750AC9137E527390D2D92F153E66196966EA554D9ADFCB109C4
       211
   r = 1EA842A0E17D2DE4F92C15315C63DDF72685C18195C2BB95E572B9C5136CA4B4
       B576AD712A52BE9730627D16054BA40CC0B8D3FF035B12AE75168397F5D50C67
       451
   s = 1F21A3CEE066E1961025FB048BD5FE2B7924D0CD797BABE0A83B66F1E35EEAF5
       FDE143FA85DC394A7DEE766523393784484BDF3E00114A1C857CDE1AA203DB65
       D61

   With SHA-512, message = "sample":
   k = 1DAE2EA071F8110DC26882D4D5EAE0621A3256FC8847FB9022E2B7D28E6F1019
       8B1574FDD03A9053C08A1854A168AA5A57470EC97DD5CE090124EF52A2F7ECBF
       FD3
   r = 0C328FAFCBD79DD77850370C46325D987CB525569FB63C5D3BC53950E6D4C5F1
       74E25A1EE9017B5D450606ADD152B534931D7D4E8455CC91F9B15BF05EC36E37
       7FA
   s = 0617CCE7CF5064806C467F678D3B4080D6F1CC50AF26CA209417308281B68AF2
       82623EAA63E5B5C0723D8B8C37FF0777B1A20F8CCB1DCCC43997F1EE0E44DA4A
       67A








Pornin                        Informational                    [Page 39]

RFC 6979               Deterministic DSA and ECDSA           August 2013


   With SHA-1, message = "test":
   k = 0BB9F2BF4FE1038CCF4DABD7139A56F6FD8BB1386561BD3C6A4FC818B20DF5DD
       BA80795A947107A1AB9D12DAA615B1ADE4F7A9DC05E8E6311150F47F5C57CE8B
       222
   r = 13BAD9F29ABE20DE37EBEB823C252CA0F63361284015A3BF430A46AAA80B87B0
       693F0694BD88AFE4E661FC33B094CD3B7963BED5A727ED8BD6A3A202ABE009D0
       367
   s = 1E9BB81FF7944CA409AD138DBBEE228E1AFCC0C890FC78EC8604639CB0DBDC90
       F717A99EAD9D272855D00162EE9527567DD6A92CBD629805C0445282BBC91679
       7FF

   With SHA-224, message = "test":
   k = 040D09FCF3C8A5F62CF4FB223CBBB2B9937F6B0577C27020A99602C25A011369
       87E452988781484EDBBCF1C47E554E7FC901BC3085E5206D9F619CFF07E73D6F
       706
   r = 1C7ED902E123E6815546065A2C4AF977B22AA8EADDB68B2C1110E7EA44D42086
       BFE4A34B67DDC0E17E96536E358219B23A706C6A6E16BA77B65E1C595D43CAE1
       7FB
   s = 177336676304FCB343CE028B38E7B4FBA76C1C1B277DA18CAD2A8478B2A9A9F5
       BEC0F3BA04F35DB3E4263569EC6AADE8C92746E4C82F8299AE1B8F1739F8FD51
       9A4

   With SHA-256, message = "test":
   k = 01DE74955EFAABC4C4F17F8E84D881D1310B5392D7700275F82F145C61E84384
       1AF09035BF7A6210F5A431A6A9E81C9323354A9E69135D44EBD2FCAA7731B909
       258
   r = 00E871C4A14F993C6C7369501900C4BC1E9C7B0B4BA44E04868B30B41D807104
       2EB28C4C250411D0CE08CD197E4188EA4876F279F90B3D8D74A3C76E6F1E4656
       AA8
   s = 0CD52DBAA33B063C3A6CD8058A1FB0A46A4754B034FCC644766CA14DA8CA5CA9
       FDE00E88C1AD60CCBA759025299079D7A427EC3CC5B619BFBC828E7769BCD694
       E86

   With SHA-384, message = "test":
   k = 1F1FC4A349A7DA9A9E116BFDD055DC08E78252FF8E23AC276AC88B1770AE0B5D
       CEB1ED14A4916B769A523CE1E90BA22846AF11DF8B300C38818F713DADD85DE0
       C88
   r = 14BEE21A18B6D8B3C93FAB08D43E739707953244FDBE924FA926D76669E7AC8C
       89DF62ED8975C2D8397A65A49DCC09F6B0AC62272741924D479354D74FF60755
       78C
   s = 133330865C067A0EAF72362A65E2D7BC4E461E8C8995C3B6226A21BD1AA78F0E
       D94FE536A0DCA35534F0CD1510C41525D163FE9D74D134881E35141ED5E8E95B
       979








Pornin                        Informational                    [Page 40]

RFC 6979               Deterministic DSA and ECDSA           August 2013


   With SHA-512, message = "test":
   k = 16200813020EC986863BEDFC1B121F605C1215645018AEA1A7B215A564DE9EB1
       B38A67AA1128B80CE391C4FB71187654AAA3431027BFC7F395766CA988C964DC
       56D
   r = 13E99020ABF5CEE7525D16B69B229652AB6BDF2AFFCAEF38773B4B7D08725F10
       CDB93482FDCC54EDCEE91ECA4166B2A7C6265EF0CE2BD7051B7CEF945BABD47E
       E6D
   s = 1FBD0013C674AA79CB39849527916CE301C66EA7CE8B80682786AD60F98F7E78
       A19CA69EFF5C57400E3B3A0AD66CE0978214D13BAF4E9AC60752F7B155E2DE4D
       CE3









































Pornin                        Informational                    [Page 41]

RFC 6979               Deterministic DSA and ECDSA           August 2013

"""

type
  EcdsaVector = object
    curveName: string
    ux, uy: string
    hashName: string
    message: string
    r, s: string

  Rfc6979 = object
    vectors: seq[EcdsaVector]
    curves: seq[string]

const UpperHex = {'0' .. '9', 'A' .. 'F'}

proc isUpperHex(s: string): bool =
  if s.len == 0: return false
  for ch in s:
    if ch notin UpperHex: return false
  true

proc parseRfc6979(text: string): Rfc6979 =
  var curve = ""
  var ux = ""
  var uy = ""
  var pending = -1          # index into result.vectors, or -1
  var lastField = ""        # "Ux", "Uy", "r", "s", … for continuations
  for raw in text.splitLines():
    let line = raw.strip()
    if line.startsWith("A.2.") and line.contains("ECDSA,"):
      curve = ""
      ux = ""
      uy = ""
      pending = -1
      lastField = ""
      continue
    if line.startsWith("curve: "):
      curve = line[7 .. ^1].strip()
      if curve.startsWith("NIST "):
        curve = curve[5 .. ^1]
      if curve notin result.curves:
        result.curves.add curve
      continue
    if line.startsWith("With ") and line.endsWith("\":"):
      let comma = line.find(", message = \"")
      if comma < 0:
        continue
      result.vectors.add EcdsaVector(
        curveName: curve, ux: ux, uy: uy,
        hashName: line[5 ..< comma],
        message: line[comma + 13 ..< line.len - 2])
      pending = result.vectors.high
      lastField = ""
      continue
    let eq = line.find(" = ")
    if eq > 0:
      let name = line[0 ..< eq]
      let value = line[eq + 3 .. ^1]
      if isUpperHex(value) and name.len <= 2:
        case name
        of "Ux":
          ux = value
          lastField = "Ux"
        of "Uy":
          uy = value
          lastField = "Uy"
        of "r":
          if pending >= 0:
            result.vectors[pending].r = value
            lastField = "r"
        of "s":
          if pending >= 0:
            result.vectors[pending].s = value
            lastField = "s"
        else:
          lastField = ""
        continue
      lastField = ""
      continue
    if isUpperHex(line) and lastField.len > 0:
      case lastField
      of "Ux": ux.add line
      of "Uy": uy.add line
      of "r":
        if pending >= 0: result.vectors[pending].r.add line
      of "s":
        if pending >= 0: result.vectors[pending].s.add line
      else: discard
      continue
    if line.len == 0:
      lastField = ""

let Ecdsa = parseRfc6979(Rfc6979AppendixA2)

# The three (curve, hash) pairs RFC 9053 §2.1 defines a COSE algorithm
# for. Everything else RFC 6979 publishes is a pair this build cannot
# name, and the count of those is pinned too.
const CosePairs = [("P-256", "SHA-256", caEs256),
                   ("P-384", "SHA-384", caEs384),
                   ("P-521", "SHA-512", caEs512)]

proc coseAlgorithmFor(v: EcdsaVector): (bool, CoseAlgorithm) =
  for (curve, hash, alg) in CosePairs:
    if v.curveName == curve and v.hashName == hash:
      return (true, alg)
  (false, caEs256)

proc curveOf(name: string): CoseCurve =
  for c in CoseCurve:
    if CoseCurveName[c] == name:
      return c
  raise newException(ValueError, "no curve " & name)

proc padHex(value: string; digits: int): string =
  if value.len > digits:
    raise newException(ValueError,
      "value is " & $value.len & " hex digits, wanted at most " & $digits)
  repeat('0', digits - value.len) & value

proc rawBytes(hex: string): seq[byte] =
  for i in 0 ..< hex.len div 2:
    result.add byte(parseHexInt(hex[2 * i .. 2 * i + 1]))

proc keyFor(v: EcdsaVector): CoseKey =
  let curve = curveOf(v.curveName)
  let digits = 2 * CoseCurveCoordinateLen[curve]
  result.curve = curve
  result.point = @[0x04'u8]
  for b in rawBytes(padHex(v.ux, digits)): result.point.add b
  for b in rawBytes(padHex(v.uy, digits)): result.point.add b

proc signatureFor(v: EcdsaVector): seq[byte] =
  let digits = 2 * CoseCurveCoordinateLen[curveOf(v.curveName)]
  result = rawBytes(padHex(v.r, digits))
  for b in rawBytes(padHex(v.s, digits)):
    result.add b

proc messageBytes(v: EcdsaVector): seq[byte] =
  for ch in v.message:
    result.add byte(ord(ch))

suite "cose ecdsa primitive against rfc 6979":

  test "t_cose_rfc6979_corpus_is_intact":
    check Ecdsa.curves == @["P-256", "P-384", "P-521"]
    check Ecdsa.vectors.len == 30
    var usable = 0
    var unusable = 0
    var messages: seq[string] = @[]
    var hashes: seq[string] = @[]
    for v in Ecdsa.vectors:
      check v.curveName.len > 0
      check v.ux.len > 0
      check v.uy.len > 0
      check v.r.len > 0
      check v.s.len > 0
      # RFC 6979 prints P-521 values as 131 hex digits, one short of the
      # 66 bytes RFC 9053 §2.1 requires, because the leading zero bits
      # are not printed. Left-padding is the RFC 9053 rule, applied.
      let digits = 2 * CoseCurveCoordinateLen[curveOf(v.curveName)]
      check v.r.len <= digits
      check v.s.len <= digits
      check v.ux.len <= digits
      if v.message notin messages: messages.add v.message
      if v.hashName notin hashes: hashes.add v.hashName
      if coseAlgorithmFor(v)[0]: inc usable else: inc unusable
    check messages == @["sample", "test"]
    check hashes == @["SHA-1", "SHA-224", "SHA-256", "SHA-384", "SHA-512"]
    check usable == 6
    check unusable == 24
    # The P-521 padding really is exercised: at least one published
    # value is shorter than the width the encoding requires.
    var padded = 0
    for v in Ecdsa.vectors:
      let digits = 2 * CoseCurveCoordinateLen[curveOf(v.curveName)]
      if v.r.len < digits or v.s.len < digits or v.ux.len < digits:
        inc padded
    check padded == 10

  test "t_cose_rfc6979_signatures_verify":
    # The six (curve, hash) pairs RFC 9053 names an algorithm for. This
    # is the ONLY published evidence in this repository that the
    # ES384 path computes anything: RFC 9052 has no P-384 example.
    var verified: seq[string] = @[]
    for v in Ecdsa.vectors:
      let (usable, alg) = coseAlgorithmFor(v)
      if not usable:
        continue
      let ok = ecdsaSignatureIsValid(keyFor(v), alg, messageBytes(v),
                                     signatureFor(v))
      if not ok:
        checkpoint("rfc 6979 " & v.curveName & " / " & v.hashName &
          " / " & v.message)
      check ok
      verified.add CoseAlgorithmName[alg] & ":" & v.message
    check verified == @["ES256:sample", "ES256:test",
                        "ES384:sample", "ES384:test",
                        "ES512:sample", "ES512:test"]

  test "t_cose_rfc6979_signatures_are_not_interchangeable":
    # A verifier that ignored the hash, the message or the signature
    # would pass the case above. Three mutations say it does not.
    var byName: seq[(string, EcdsaVector)] = @[]
    for v in Ecdsa.vectors:
      byName.add (v.curveName & "/" & v.hashName & "/" & v.message, v)
    proc pick(name: string): EcdsaVector =
      for (n, v) in byName:
        if n == name: return v
      raise newException(ValueError, "no vector " & name)
    let p384 = pick("P-384/SHA-384/sample")
    check ecdsaSignatureIsValid(keyFor(p384), caEs384,
                                messageBytes(p384), signatureFor(p384))
    # 1. the same curve and message, signed under a different hash.
    let p384other = pick("P-384/SHA-256/sample")
    check not ecdsaSignatureIsValid(keyFor(p384), caEs384,
                                    messageBytes(p384),
                                    signatureFor(p384other))
    # 2. the same curve and hash, a different message.
    let p384test = pick("P-384/SHA-384/test")
    check not ecdsaSignatureIsValid(keyFor(p384), caEs384,
                                    messageBytes(p384),
                                    signatureFor(p384test))
    # …and that signature IS valid over its own message, so mutation 2
    # is not simply using an unusable value.
    check ecdsaSignatureIsValid(keyFor(p384test), caEs384,
                                messageBytes(p384test),
                                signatureFor(p384test))
    # 3. one bit of r.
    var flipped = signatureFor(p384)
    flipped[0] = flipped[0] xor 0x01'u8
    check not ecdsaSignatureIsValid(keyFor(p384), caEs384,
                                    messageBytes(p384), flipped)
    # 4. a signature of the wrong length is refused rather than read
    #    past the end of the buffer.
    check not ecdsaSignatureIsValid(keyFor(p384), caEs384,
                                    messageBytes(p384),
                                    signatureFor(p384)[0 ..< 95])
    # 5. and the P-521 vector does not verify under the P-384 key, which
    #    is what the curve-and-algorithm pairing rule exists to stop
    #    reaching here in the first place.
    let p521 = pick("P-521/SHA-512/sample")
    check not ecdsaSignatureIsValid(keyFor(p384), caEs384,
                                    messageBytes(p521), signatureFor(p521))

suite "cose refusal coverage":

  test "t_cose_every_refusal_kind_is_reached":
    var unreached: seq[string] = @[]
    var count = 0
    for k in CoseErrorKind:
      inc count
      if k notin reachedKinds:
        unreached.add $k
    check count == 37
    if unreached.len > 0:
      checkpoint("never reached: " & unreached.join(", "))
    check unreached.len == 0

  test "t_cose_refusal_messages_are_distinguishable":
    var messages: seq[string] = @[]
    for k in CoseErrorKind:
      messages.add CoseErrorMessage[k]
      check CoseErrorMessage[k].len > 0
    check messages.len == 37
    check messagesAreDistinguishable(messages)
    # The predicate is the same one the CBOR layer uses, and it can
    # fail: two COSE-shaped messages where one contains the other.
    check not messagesAreDistinguishable(
      ["the key is missing its x",
       "the key is missing its x or its y coordinate"])
