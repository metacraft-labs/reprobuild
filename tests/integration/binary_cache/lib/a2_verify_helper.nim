## A2 integration-test verify helper.
##
## Decodes a manifest file via the production codec + signature
## verifier, exit-codes the verification outcome. Used by
## ``t_a2_signature_verification.sh`` to assert the client-side
## verify path rejects tampered bytes with a clearly-worded error
## that cites the signature mismatch.
##
## Sub-modes:
##
##   --in=PATH           Decode + verify. Exit 0 on success, 2 on
##                       any signature or codec error.
##   --tamper=IN --out=OUT Read IN, flip one byte inside the realized-
##                       prefix-digest region (covered by the
##                       signature but NOT by the entry-key sentinel),
##                       write to OUT.

import std/[os, parseopt, strutils]

import repro_binary_cache_server

type
  HelperMode = enum
    hmVerify
    hmTamper

  HelperOpts = object
    mode: HelperMode
    inPath: string
    outPath: string

proc parseCli(): HelperOpts =
  var p = initOptParser(commandLineParams())
  while true:
    p.next()
    case p.kind
    of cmdEnd: break
    of cmdShortOption, cmdLongOption:
      case p.key
      of "in":
        result.mode = hmVerify
        result.inPath = p.val
      of "tamper":
        result.mode = hmTamper
        result.inPath = p.val
      of "out":
        result.outPath = p.val
      else:
        discard
    of cmdArgument: discard

proc bytesOf(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  for i, ch in s:
    result[i] = byte(ch)

proc stringOf(b: openArray[byte]): string =
  result = newString(b.len)
  for i in 0 ..< b.len:
    result[i] = char(b[i])

proc tamperPayloadDigest(buf: var seq[byte]) =
  ## Flip a single byte of the first PayloadObject digest. The
  ## envelope layout (see manifest_codec.nim):
  ##   4 (magic) + 2 (version) + 2 (reserved) + 32 (keyDigest) +
  ##   4 (keyBlockLen) + keyBlockLen + 4 (payloadCount) +
  ##   per-payload: 1 (kind) + 1 (comp) + 8 (size) + 8 (uncomp) +
  ##               32 (digest) + 4 (nameLen) + name
  ## We tamper the first 32-byte digest, which is covered by the
  ## signature but does NOT participate in the entry-key sentinel.
  var pos = 4 + 2 + 2 + 32
  let keyBlockLen = int(buf[pos]) or (int(buf[pos+1]) shl 8) or
                    (int(buf[pos+2]) shl 16) or (int(buf[pos+3]) shl 24)
  pos += 4 + keyBlockLen
  pos += 4    # payloadCount
  pos += 1 + 1 + 8 + 8
  # Now pos points at the first byte of the first payload's digest.
  buf[pos] = buf[pos] xor 0x55'u8

proc main() =
  let opts = parseCli()
  case opts.mode
  of hmVerify:
    if opts.inPath.len == 0:
      stderr.writeLine("--in required for verify mode")
      quit(2)
    let bytes = bytesOf(readFile(opts.inPath))
    try:
      let manifest = decodeManifest(bytes)
      if not verifyManifest(manifest):
        stderr.writeLine("manifest signature verification FAILED")
        quit(2)
      echo "manifest signature verified OK"
      quit(0)
    except BinaryCacheCodecError as e:
      stderr.writeLine("codec error (possible tamper): " & e.msg)
      quit(2)
    except BinaryCacheSignatureError as e:
      stderr.writeLine("signature error: " & e.msg)
      quit(2)
  of hmTamper:
    if opts.inPath.len == 0 or opts.outPath.len == 0:
      stderr.writeLine("--tamper and --out required for tamper mode")
      quit(2)
    var bytes = bytesOf(readFile(opts.inPath))
    tamperPayloadDigest(bytes)
    writeFile(opts.outPath, stringOf(bytes))
    quit(0)

when isMainModule:
  main()
