## ReproOS-Generations-And-Foreign-Packages A2.5 — manifest codec re-export.
##
## A2's ``libs/repro_binary_cache_server/src/repro_binary_cache_server/
## manifest_codec.nim`` already implements decode + sign/verify in a
## way that's directly consumable by the client. Rather than
## duplicating the bytewise envelope decoder (and risking drift
## between encoder + decoder), the client module re-exports the
## shared decoder and layers an ``decodeAndVerify`` proc that maps a
## raw response body to a verified ``BinaryCacheManifest`` or raises
## a structured error.
##
## When the server-side codec moves out of ``repro_binary_cache_server/``
## into a shared ``repro_binary_cache_codec/`` lib (followup), this
## module's imports update and the call sites stay the same.

import std/[strutils]

import ../../../repro_binary_cache_server/src/repro_binary_cache_server/types
import ../../../repro_binary_cache_server/src/repro_binary_cache_server/manifest_codec as serverCodec

export types
export serverCodec.decodeManifest, serverCodec.encodeManifest,
       serverCodec.verifyManifest, serverCodec.verifyManifestOrRaise,
       serverCodec.BinaryCacheCodecError,
       serverCodec.BinaryCacheSignatureError

type
  ClientManifestError* = object of CatchableError
    ## Raised by ``decodeAndVerify`` when either the envelope is
    ## malformed or the signature doesn't verify. Callers can
    ## ``try ... except ClientManifestError`` to fall back to a
    ## different upstream or a local build.

proc pubKeyHex*(pk: PublicKeyBytes): string =
  const HexChars = "0123456789abcdef"
  result = newStringOfCap(pk.len * 2)
  for b in pk:
    result.add(HexChars[int(b shr 4) and 0x0f])
    result.add(HexChars[int(b) and 0x0f])

proc decodeAndVerify*(bytes: openArray[byte]): BinaryCacheManifest =
  ## Single entry point: parse the envelope, validate the embedded
  ## CacheEntryKey-digest sentinel, validate the ECDSA-P256
  ## signature, return the manifest. On any failure raises
  ## ``ClientManifestError`` with a structured message.
  var m: BinaryCacheManifest
  try:
    m = serverCodec.decodeManifest(bytes)
  except BinaryCacheCodecError as e:
    raise newException(ClientManifestError,
      "manifest envelope decode failed: " & e.msg)
  if not serverCodec.verifyManifest(m):
    raise newException(ClientManifestError,
      "manifest signature verification failed for producer key " &
      pubKeyHex(m.producerPubKey))
  return m
