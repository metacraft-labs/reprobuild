## Peer-cache auth + signed advertisements — Peer-Cache-BearSSL M1.
##
## Replaces the M3 HMAC-SHA256 "asymmetric-signature stand-in" with
## real ECDSA-P256 sign + verify via `nim-bearssl`.
##
## See `reprobuild-specs/Peer-Cache-BearSSL.md` §"Identity model" and
## `reprobuild-specs/Peer-Cache-BearSSL.milestones.org` §M1.
##
## ## Cryptographic shape (M1, real primitive)
##
##   - Each peer holds an ECDSA-P256 keypair:
##       * 32-byte raw private scalar
##       * 65-byte uncompressed public key (`0x04 || X(32) || Y(32)`)
##   - Signatures are 64-byte raw ECDSA-P256 (`r || s`, two 32-byte
##     scalars, big-endian; matches the existing `AdvertiseV2.signature`
##     wire slot).
##   - `signMessage` SHA-256 hashes the canonical message bytes, then
##     calls `ecdsaSignRawGetDefault` (BearSSL's deterministic
##     RFC 6979 signer).
##   - `verifySignature` calls `ecdsaVrfyRawGetDefault` against the
##     pubkey + SHA-256 digest. No private-key recompute path —
##     verification is asymmetric.
##   - `derivePublicKey` is real `ecComputePub` from the private scalar.
##   - PeerId = `BLAKE3-256(publicKey)` — unchanged size (32 B) but the
##     derivation binds the on-wire PeerId to a real public identity.
##
## ## Trust-anchor file format (changed at M1)
##
## One hex-encoded **public key** per line (130 hex chars = 65 B
## uncompressed ECDSA-P256 pubkey). Blank lines and `#`-prefixed lines
## are ignored. The legacy M3 `<pubkey_hex>:<privkey_hex>` format is
## rejected with a clear error. There is no auto-migration; nothing
## has shipped under the M3 stand-in.
##
## ## Keypair on-disk format (M1)
##
## The peer's `keyPath` carries a single line of the form:
##
##   `ecdsa-p256:<hex_of_32_byte_scalar>`
##
## The `ecdsa-p256:` prefix is mandatory — a file without it is treated
## as a legacy M3 stand-in keypair and rejected. The peer's `certPath`
## carries the hex-encoded uncompressed public key (130 hex chars) on
## a single line (later milestones replace this with an X.509 PEM cert).
##
## ## Buffer lifetime
##
## BearSSL's `EcPrivateKey` / `EcPublicKey` carry `ptr byte` fields that
## point into externally-owned buffers. We copy raw scalar / point bytes
## out of those buffers immediately after `ecKeygen` / `ecComputePub`
## into fixed-size `array` fields on `PeerKeypair`, then reconstruct
## `EcPrivateKey` / `EcPublicKey` on demand per sign / verify call so
## the BearSSL ABI types only ever reference Nim-stack-local storage
## owned by the proc currently calling them.

import std/[hashes, os, sets, strutils]

import bearssl/[rand, ec, hash as bsslHash]
import bearssl/abi/bearssl_ec as bsslEcAbi
import bearssl/abi/bearssl_hash as bsslHashAbi

import blake3

import ./types
import ./key_types
export key_types

# ---------------------------------------------------------------------------
# Key + signature types.
#
# The plain byte-array key / signature types and their P256 length
# constants live in the BearSSL-free `key_types` module (re-exported
# above) so downstream type-only consumers — `repro_binary_cache_server/
# types`, `repro_binary_cache_client/cache_key`, the project DSL — do not
# pull in the BearSSL FFI that this module's sign / verify procedures use.
# Only the BearSSL-dependent curve handle stays here.
# ---------------------------------------------------------------------------

const
  P256Curve    = cint(bsslEcAbi.EC_secp256r1)

type
  TrustAnchors* = ref object
    ## Per-tenant trust anchor: every allowed peer's ECDSA-P256
    ## public key. Real asymmetric verify uses pubkey only; the M3
    ## `privateKeys` table is gone.
    publicKeys*: HashSet[PublicKeyBytes]

  AuthError* = object of CatchableError
    ## Raised on malformed key files, missing trust anchors, or
    ## signature-verification failures that the caller wants surfaced.

const
  KeyFilePrefix = "ecdsa-p256:"

# ---------------------------------------------------------------------------
# Equality / hashing for `PublicKeyBytes`. std/hashes provides `hash`
# for `array[N, byte]`, so `HashSet[PublicKeyBytes]` just works.
# ---------------------------------------------------------------------------

proc hashPublicKey*(value: PublicKeyBytes): Hash =
  result = hash(@value)

# ---------------------------------------------------------------------------
# Hex encoding helpers (lower-case; mirrors the codec's `toHexLower`).
# ---------------------------------------------------------------------------

const HexChars = "0123456789abcdef"

proc toHexN(buf: openArray[byte]): string =
  result = newString(buf.len * 2)
  for i, b in buf:
    result[2 * i] = HexChars[(int(b) shr 4) and 0xf]
    result[2 * i + 1] = HexChars[int(b) and 0xf]

proc toHex32(buf: array[P256PrivLen, byte]): string = toHexN(buf)
proc toHex65(buf: array[P256PubLen, byte]): string = toHexN(buf)

proc parseHexBuf(hex: string; expectedBytes: int; what: string):
    seq[byte] =
  if hex.len != expectedBytes * 2:
    raise newException(AuthError,
      what & ": expected " & $(expectedBytes * 2) &
      " hex chars (" & $expectedBytes & " bytes), got " & $hex.len)
  result = newSeq[byte](expectedBytes)
  for i in 0 ..< expectedBytes:
    try:
      result[i] = byte(parseHexInt(hex[2 * i .. 2 * i + 1]))
    except ValueError:
      raise newException(AuthError,
        what & ": invalid hex digit at position " & $(2 * i))

proc parsePrivHex(hex: string): PrivateKeyBytes =
  let buf = parseHexBuf(hex, P256PrivLen, "private-key hex")
  for i in 0 ..< P256PrivLen:
    result[i] = buf[i]

proc parsePubHex(hex: string): PublicKeyBytes =
  let buf = parseHexBuf(hex, P256PubLen, "public-key hex")
  for i in 0 ..< P256PubLen:
    result[i] = buf[i]

# ---------------------------------------------------------------------------
# ECDSA-P256 primitives.
# ---------------------------------------------------------------------------

proc sha256Digest(msg: openArray[byte]): array[32, byte] =
  ## SHA-256 over `msg` via BearSSL's hash surface. Returns a fixed
  ## 32-byte digest used as input to `ecdsaSignRawGetDefault` and
  ## `ecdsaVrfyRawGetDefault`.
  var ctx: bsslHashAbi.Sha256Context
  bsslHashAbi.sha256Init(ctx)
  if msg.len > 0:
    bsslHashAbi.sha256Update(ctx, unsafeAddr msg[0], csize_t(msg.len))
  bsslHashAbi.sha256Out(ctx, addr result[0])

proc derivePublicKey*(privateKey: PrivateKeyBytes): PublicKeyBytes =
  ## Real ECDSA-P256 public-key derivation via BearSSL's `ecComputePub`.
  ## Reconstructs an `EcPrivateKey` referencing a mutable local copy of
  ## the 32-byte scalar; the resulting public key is copied out before
  ## the local buffers go out of scope.
  var skBytes: array[P256PrivLen, byte]
  for i in 0 ..< P256PrivLen:
    skBytes[i] = privateKey[i]
  var sk: bsslEcAbi.EcPrivateKey
  sk.curve = P256Curve
  sk.x = addr skBytes[0]
  sk.xlen = uint(P256PrivLen)
  let ecImpl = bsslEcAbi.ecGetDefault()
  var pkBuf: array[bsslEcAbi.EC_KBUF_PUB_MAX_SIZE, byte]
  var pk: bsslEcAbi.EcPublicKey
  let pkLen = bsslEcAbi.ecComputePub(
    ecImpl, addr pk, addr pkBuf[0], addr sk)
  if pkLen == 0 or pk.qlen != uint(P256PubLen):
    raise newException(AuthError,
      "BearSSL ecComputePub failed (pkLen=" & $pkLen & ")")
  # Copy the 65-byte uncompressed pubkey out of pkBuf (which `pk.q`
  # points into) so the caller can hold the bytes after `pkBuf` is
  # released.
  for i in 0 ..< P256PubLen:
    result[i] = pkBuf[i]

proc generateKeypair*(): PeerKeypair =
  ## Fresh random ECDSA-P256 keypair. Uses BearSSL's HMAC-DRBG seeded by
  ## OS entropy for the keygen step; the public key is then derived via
  ## `ecComputePub`. The 32-byte scalar and 65-byte uncompressed point
  ## are copied into fixed-size arrays so the BearSSL ABI buffers can
  ## be released immediately.
  let rng = HmacDrbgContext.new()
  let ecImpl = bsslEcAbi.ecGetDefault()
  var skBuf: array[bsslEcAbi.EC_KBUF_PRIV_MAX_SIZE, byte]
  var sk: bsslEcAbi.EcPrivateKey
  let skLen = bsslEcAbi.ecKeygen(
    PrngClassPointerConst(addr rng.vtable), ecImpl,
    addr sk, addr skBuf[0], P256Curve)
  if skLen == 0 or sk.xlen != uint(P256PrivLen):
    raise newException(AuthError,
      "BearSSL ecKeygen failed (skLen=" & $skLen & ")")
  # Copy the raw 32-byte scalar out of skBuf.
  for i in 0 ..< P256PrivLen:
    result.privateKey[i] = skBuf[i]
  result.publicKey = derivePublicKey(result.privateKey)

proc signMessage*(kp: PeerKeypair; msg: openArray[byte]): SignatureBytes =
  ## Hashes `msg` with SHA-256 then produces a 64-byte raw ECDSA-P256
  ## signature via BearSSL's `ecdsaSignRawGetDefault` (RFC 6979
  ## deterministic). Reconstructs an `EcPrivateKey` against a local
  ## mutable copy of the 32-byte scalar so the BearSSL ABI sees a
  ## live, owned buffer.
  let digest = sha256Digest(msg)
  var skBytes: array[P256PrivLen, byte]
  for i in 0 ..< P256PrivLen:
    skBytes[i] = kp.privateKey[i]
  var sk: bsslEcAbi.EcPrivateKey
  sk.curve = P256Curve
  sk.x = addr skBytes[0]
  sk.xlen = uint(P256PrivLen)
  let ecImpl = bsslEcAbi.ecGetDefault()
  let signer = bsslEcAbi.ecdsaSignRawGetDefault()
  var sigBuf: array[P256SigLen, byte]
  let sigLen = signer(ecImpl, addr bsslHashAbi.sha256Vtable,
                      addr digest[0], addr sk, addr sigBuf[0])
  if sigLen != uint(P256SigLen):
    raise newException(AuthError,
      "BearSSL ecdsaSignRaw produced unexpected sig length: " & $sigLen)
  for i in 0 ..< P256SigLen:
    result[i] = sigBuf[i]

proc verifySignature*(publicKey: PublicKeyBytes;
                      msg: openArray[byte];
                      sig: SignatureBytes): bool =
  ## Verifies a 64-byte raw ECDSA-P256 signature over SHA-256(msg) with
  ## `publicKey`. Returns `false` on any failure (malformed point,
  ## bad signature, BearSSL error) so callers can branch on the bool
  ## without try/except.
  let digest = sha256Digest(msg)
  var pkBytes: array[P256PubLen, byte]
  for i in 0 ..< P256PubLen:
    pkBytes[i] = publicKey[i]
  var sigBytes: array[P256SigLen, byte]
  for i in 0 ..< P256SigLen:
    sigBytes[i] = sig[i]
  var pk: bsslEcAbi.EcPublicKey
  pk.curve = P256Curve
  pk.q = addr pkBytes[0]
  pk.qlen = uint(P256PubLen)
  let ecImpl = bsslEcAbi.ecGetDefault()
  let verifier = bsslEcAbi.ecdsaVrfyRawGetDefault()
  let ok = verifier(ecImpl, addr digest[0], csize_t(digest.len),
                    addr pk, addr sigBytes[0], csize_t(sigBytes.len))
  result = ok == 1'u32

# ---------------------------------------------------------------------------
# Convenience verifier that also checks the pubkey is in a trust anchor
# set. The M3 signature `(anchors, pubKey, msg, sig)` is preserved so
# call sites in `server.nim` / `client.nim` only need to widen the
# pubkey-buffer type.
# ---------------------------------------------------------------------------

proc verifySignature*(anchors: TrustAnchors;
                      publicKey: PublicKeyBytes;
                      msg: openArray[byte];
                      sig: SignatureBytes): bool =
  if anchors.isNil:
    return false
  if publicKey notin anchors.publicKeys:
    return false
  result = verifySignature(publicKey, msg, sig)

# ---------------------------------------------------------------------------
# Key file I/O.
# ---------------------------------------------------------------------------

proc writeKeyFile(path: string; priv: PrivateKeyBytes) =
  ## Persists the private scalar to `path` as `ecdsa-p256:<hex>` so the
  ## file is unambiguously an ECDSA-P256 key, not an M3 stand-in seed.
  let parent = parentDir(path)
  if parent.len > 0 and not dirExists(parent):
    createDir(parent)
  writeFile(path, KeyFilePrefix & toHex32(priv) & "\n")

proc writeCertFile(path: string; pub: PublicKeyBytes) =
  ## Persists the public key to `path` as a single 130-char hex line.
  let parent = parentDir(path)
  if parent.len > 0 and not dirExists(parent):
    createDir(parent)
  writeFile(path, toHex65(pub) & "\n")

proc readSingleHexLine(path: string; what: string): string =
  if not fileExists(path):
    raise newException(AuthError,
      what & " file does not exist: " & path)
  let content = readFile(path)
  for rawLine in content.splitLines:
    let line = rawLine.strip()
    if line.len == 0 or line.startsWith("#"):
      continue
    return line
  raise newException(AuthError,
    what & " file is empty / all-comment: " & path)

proc readKeyFile(path: string): PrivateKeyBytes =
  ## Parses an `ecdsa-p256:<hex>` file. A file without the prefix is
  ## treated as a legacy M3 stand-in keypair and rejected (per the
  ## hard-cutover stance).
  let line = readSingleHexLine(path, "peer private-key")
  if not line.startsWith(KeyFilePrefix):
    raise newException(AuthError,
      "peer private-key file " & path &
      " lacks the `ecdsa-p256:` marker — looks like a legacy M3 " &
      "stand-in keypair. Regenerate the file: this campaign does " &
      "not auto-migrate legacy keys.")
  result = parsePrivHex(line[KeyFilePrefix.len .. ^1])

proc readCertFile(path: string): PublicKeyBytes =
  let line = readSingleHexLine(path, "peer public-key (cert)")
  if line.startsWith(KeyFilePrefix):
    raise newException(AuthError,
      "peer cert file " & path & " carries an `ecdsa-p256:` marker " &
      "— that's the private-key marker; cert file should be a bare " &
      "hex pubkey on its own line.")
  result = parsePubHex(line)

proc loadOrGenerateKeypair*(certPath, keyPath: string): PeerKeypair =
  ## Loads the peer's keypair from disk, generating + persisting a
  ## fresh one when either file is missing. The cert file holds the
  ## 65-byte uncompressed ECDSA-P256 public key (hex); the key file
  ## holds the 32-byte private scalar (hex, prefixed `ecdsa-p256:`).
  ##
  ## When **both** files exist they are read and the public key is
  ## re-derived from the private key + compared with the on-disk
  ## public key; mismatch raises `AuthError`.
  if fileExists(certPath) and fileExists(keyPath):
    let pub = readCertFile(certPath)
    let priv = readKeyFile(keyPath)
    let derived = derivePublicKey(priv)
    if derived != pub:
      raise newException(AuthError,
        "peer public-key file does not match ECDSA-P256 derive(" &
        "privkey): " & certPath & " vs derive(" & keyPath & ")")
    return PeerKeypair(publicKey: pub, privateKey: priv)
  let kp = generateKeypair()
  writeCertFile(certPath, kp.publicKey)
  writeKeyFile(keyPath, kp.privateKey)
  kp

# ---------------------------------------------------------------------------
# Trust-anchor file I/O.
# ---------------------------------------------------------------------------

proc newTrustAnchors*(): TrustAnchors =
  result = TrustAnchors(publicKeys: initHashSet[PublicKeyBytes]())

proc addAnchor*(anchors: TrustAnchors; publicKey: PublicKeyBytes) =
  ## Registers a single trust anchor pubkey. Idempotent.
  anchors.publicKeys.incl(publicKey)

proc loadTrustAnchors*(path: string): TrustAnchors =
  ## Parses a trust-anchor file. Each non-blank, non-`#` line carries a
  ## hex-encoded uncompressed ECDSA-P256 public key (130 hex chars).
  ##
  ## The M3 `<pubkey_hex>:<privkey_hex>` shape is rejected with a clear
  ## error so operators know to migrate. Malformed hex lines raise
  ## `AuthError` carrying the offending line number.
  if not fileExists(path):
    raise newException(AuthError,
      "trust anchor file does not exist: " & path)
  result = newTrustAnchors()
  var lineNo = 0
  for rawLine in readFile(path).splitLines:
    inc lineNo
    let line = rawLine.strip()
    if line.len == 0 or line.startsWith("#"):
      continue
    if ':' in line:
      raise newException(AuthError,
        "trust anchor file " & path & " line " & $lineNo &
        ": uses legacy `<pubkey_hex>:<privkey_hex>` format; M1 " &
        "switched to pubkey-only one-per-line. Regenerate the " &
        "anchor file from the peer keypairs — no auto-migration.")
    if line.len != P256PubLen * 2:
      raise newException(AuthError,
        "trust anchor file " & path & " line " & $lineNo &
        ": expected " & $(P256PubLen * 2) &
        " hex chars (65-byte ECDSA-P256 pubkey), got " & $line.len)
    var pub: PublicKeyBytes
    try:
      pub = parsePubHex(line)
    except AuthError as err:
      raise newException(AuthError,
        "trust anchor file " & path & " line " & $lineNo &
        ": " & err.msg)
    if pub[0] != 0x04'u8:
      raise newException(AuthError,
        "trust anchor file " & path & " line " & $lineNo &
        ": pubkey does not start with the 0x04 uncompressed-form " &
        "marker (got 0x" & toHexN([pub[0]]) & ")")
    result.addAnchor(pub)

proc writeTrustAnchors*(path: string; anchors: TrustAnchors) =
  ## Persists `anchors.publicKeys` to disk in the M1 anchor-file shape
  ## (one hex pubkey per line). Overwrites any existing file.
  let parent = parentDir(path)
  if parent.len > 0 and not dirExists(parent):
    createDir(parent)
  var lines: seq[string] = @[]
  for pub in anchors.publicKeys:
    lines.add(toHex65(pub))
  writeFile(path, lines.join("\n") & "\n")

# Peer-Cache-BearSSL M3: the `writeTrustAnchors(path, openArray[PeerKeypair])`
# convenience overload (M1 fixture-compat shim) was deleted in this
# milestone. M3 fixtures live in the cert-directory world built by
# `pki.nim`; loopback tests cross-install per-peer `*.crt` files instead.

# ---------------------------------------------------------------------------
# Canonical advertisement bytes (the message that gets signed).
# ---------------------------------------------------------------------------

proc writeU32Le(buf: var seq[byte]; value: uint32) =
  for shift in countup(0, 24, 8):
    buf.add(byte((value shr uint32(shift)) and 0xff'u32))

proc writeU64Le(buf: var seq[byte]; value: uint64) =
  for shift in countup(0, 56, 8):
    buf.add(byte((value shr uint64(shift)) and 0xff'u64))

proc canonicaliseAdvertiseForSigning*(peerId: PeerId;
                                      ad: AdvertiseV2): seq[byte] =
  ## Produces the canonical byte sequence that an `AdvertiseV2`
  ## signature covers. Shape preserved from M3 (length-prefixed, fixed
  ## order): sequence || peerId || filterCapacity || filterCount ||
  ## filterBytes_len || filterBytes.
  result = @[]
  result.writeU64Le(ad.sequence)
  let raw = bytes(peerId)
  for b in raw:
    result.add(b)
  result.writeU32Le(ad.filterCapacity)
  result.writeU32Le(ad.filterCount)
  result.writeU32Le(uint32(ad.filterBytes.len))
  for b in ad.filterBytes:
    result.add(b)

# Peer-Cache-BearSSL M3: `generateChallenge` (random nonce for the
# synthetic `mkAuthChallenge` handshake) was deleted in this milestone.
# TLS owns nonce generation under `tmTls`.
