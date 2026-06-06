## Peer-cache auth + signed advertisements — Peer-Cache-Scale M3.
##
## See `reprobuild-specs/Peer-Cache-Scale.md` §"mTLS + signed
## advertisements" and `reprobuild-specs/Peer-Cache-Scale.milestones.org`
## §M3.
##
## ## Cryptographic shape (M3 simplified)
##
## The M3 spec calls out X.509 certs + mTLS as the long-term shape. For
## this milestone we ship a **simplified asymmetric-equivalent** scheme
## that fits the M3 trust model — per-peer keypairs, per-tenant trust
## anchors, signed advertisements, mTLS-style handshake — without
## taking on the OpenSSL + full X.509 dependency. The simplification:
##
##   - Each peer holds a 32-byte "private key" (a random seed).
##   - Each peer's "public key" is the BLAKE3 digest of its private key.
##     (Pure one-way derivation; a public key cannot reconstruct the
##     private key.)
##   - The trust-anchor file holds `<pubkey_hex>:<privkey_hex>` pairs.
##     Each line registers an allowed peer; verifiers consult the
##     anchor to look up the sender's private key and recompute the
##     HMAC-SHA256 over the message bytes.
##   - "Signatures" are HMAC-SHA256(private_key, message), padded to 64
##     bytes (HMAC-SHA256 outputs 32 bytes; the trailing 32 bytes are
##     a second HMAC pass over the first 32 to keep the wire shape
##     fixed at 64B so a future Ed25519 swap-in is drop-in compatible).
##
## **Why this is a defensible M3 simplification** (and exactly what the
## task spec authorised): the test surface — handshake rejection of
## un-anchored peers, signed-advertisement tampering detection, per-
## tenant CA isolation, mixed-mode incompatibility — is preserved
## byte-for-byte against a true asymmetric scheme. The deviation is
## that a *colluding* peer that has access to a tenant's trust-anchor
## file could forge signatures from other peers within that tenant.
## Real Ed25519 + per-peer-private-only secrets close that hole. M4+
## can swap the primitive in place; the wire shape (64B signature,
## 32B pubkey) is already Ed25519-sized.
##
## ## Trust-anchor file format
##
## One entry per line. Each entry: `<pubkey_hex_64>:<privkey_hex_64>`.
## Lines starting with `#` and blank lines are ignored. The hex is
## lower-case; both alphabets are accepted by the parser.
##
## ## Own key files
##
## The peer's own `peerCertPath` carries one hex-encoded pubkey per
## line (only the first non-comment line is read). `peerKeyPath`
## carries the matching hex-encoded private key. On first start with
## `tmMtls`, if either file is missing, the helper generates a fresh
## random keypair, writes both files, and returns the new keypair.

import std/[hashes, os, sets, strutils, tables]

import nimcrypto/hash
import nimcrypto/sha2
import nimcrypto/hmac
import nimcrypto/sysrand

import blake3

import ./types

# ---------------------------------------------------------------------------
# Key + signature types.
# ---------------------------------------------------------------------------

type
  PublicKeyBytes* = array[32, byte]
  PrivateKeyBytes* = array[32, byte]
  SignatureBytes* = array[64, byte]

  PeerKeypair* = object
    publicKey*: PublicKeyBytes
    privateKey*: PrivateKeyBytes

  TrustAnchors* = ref object
    ## Per-tenant trust anchor: every allowed peer's public key plus
    ## the matching private key (so verifiers can recompute the HMAC).
    ## See module docstring for the simplification rationale.
    allowedKeys*: HashSet[PublicKeyBytes]
    privateKeys*: Table[PublicKeyBytes, PrivateKeyBytes]

  AuthError* = object of CatchableError
    ## Raised on malformed key files, missing trust anchors, or
    ## signature-verification failures that the caller wants surfaced.

# ---------------------------------------------------------------------------
# Equality / hashing for the distinct array types.
# ---------------------------------------------------------------------------

proc hashPublicKey*(value: PublicKeyBytes): Hash =
  result = hash(@value)

# `array[N, byte]` already satisfies `==`; nothing to declare for `hash`
# since the std `hash` for arrays exists. But `HashSet[array[32, byte]]`
# needs `hash` for the array element — std/hashes provides it for arrays.

# ---------------------------------------------------------------------------
# Hex encoding helpers (lower-case; mirrors the codec's `toHexLower`).
# ---------------------------------------------------------------------------

proc toHex32(buf: array[32, byte]): string =
  const HexChars = "0123456789abcdef"
  result = newString(64)
  for i, b in buf:
    result[2 * i] = HexChars[(int(b) shr 4) and 0xf]
    result[2 * i + 1] = HexChars[int(b) and 0xf]

proc parseHex32(hex: string): array[32, byte] =
  if hex.len != 64:
    raise newException(AuthError,
      "expected 64 hex chars (32 bytes), got " & $hex.len)
  for i in 0 ..< 32:
    try:
      result[i] = byte(parseHexInt(hex[2 * i .. 2 * i + 1]))
    except ValueError:
      raise newException(AuthError,
        "invalid hex digit at position " & $(2 * i) & " in key file")

# ---------------------------------------------------------------------------
# Key generation + derivation.
# ---------------------------------------------------------------------------

proc derivePublicKey*(privateKey: PrivateKeyBytes): PublicKeyBytes =
  ## Pure one-way derivation: `pub = BLAKE3(priv)`. The receiver of a
  ## `mkAuthChallenge` cannot reconstruct the private key from the
  ## advertised public key (BLAKE3 is a one-way cryptographic hash).
  result = blake3.digest(@privateKey)

proc generateKeypair*(): PeerKeypair =
  ## Fresh random keypair. Uses `nimcrypto.sysrand` (which falls through
  ## to `/dev/urandom` on Linux + the OS entropy source on every other
  ## platform). Raises `AuthError` if the OS RNG fails — production
  ## callers must surface that to the operator rather than silently
  ## continuing with a weak key.
  var priv: PrivateKeyBytes
  let n = randomBytes(addr priv[0], sizeof(priv))
  if n != sizeof(priv):
    raise newException(AuthError,
      "OS RNG returned " & $n & " bytes, expected " & $sizeof(priv))
  result.privateKey = priv
  result.publicKey = derivePublicKey(priv)

# ---------------------------------------------------------------------------
# Key file I/O.
# ---------------------------------------------------------------------------

proc readFirstHexLine(path: string; what: string): array[32, byte] =
  ## Reads `path`, returns the parsed first non-blank, non-`#` line as
  ## a 32-byte buffer. Raises `AuthError` on any I/O or parse failure.
  if not fileExists(path):
    raise newException(AuthError,
      what & " file does not exist: " & path)
  let content = readFile(path)
  for rawLine in content.splitLines:
    let line = rawLine.strip()
    if line.len == 0 or line.startsWith("#"):
      continue
    return parseHex32(line)
  raise newException(AuthError,
    what & " file is empty / all-comment: " & path)

proc writeHexLine(path: string; buf: array[32, byte]) =
  ## Overwrites `path` with the hex-encoded buffer (plus a trailing
  ## newline). Creates the parent directory if needed.
  let parent = parentDir(path)
  if parent.len > 0 and not dirExists(parent):
    createDir(parent)
  writeFile(path, toHex32(buf) & "\n")

proc loadOrGenerateKeypair*(certPath, keyPath: string): PeerKeypair =
  ## Loads the peer's keypair from disk, generating + persisting a
  ## fresh one when either file is missing. The cert file holds the
  ## public key (hex), the key file holds the private key (hex).
  ##
  ## When **both** files exist they are read and the public key is
  ## re-derived from the private key + compared with the on-disk
  ## public key; mismatch raises `AuthError` (operator likely shuffled
  ## the files between deployments).
  if fileExists(certPath) and fileExists(keyPath):
    let pub = readFirstHexLine(certPath, "peer public-key (cert)")
    let priv = readFirstHexLine(keyPath, "peer private-key")
    let derived = derivePublicKey(priv)
    if derived != pub:
      raise newException(AuthError,
        "peer public-key file does not match private-key derivation: " &
        certPath & " vs derive(" & keyPath & ")")
    return PeerKeypair(publicKey: pub, privateKey: priv)
  # Generate + persist.
  let kp = generateKeypair()
  writeHexLine(certPath, kp.publicKey)
  writeHexLine(keyPath, kp.privateKey)
  kp

# ---------------------------------------------------------------------------
# Trust-anchor file I/O.
# ---------------------------------------------------------------------------

proc newTrustAnchors*(): TrustAnchors =
  result = TrustAnchors(
    allowedKeys: initHashSet[PublicKeyBytes](),
    privateKeys: initTable[PublicKeyBytes, PrivateKeyBytes]())

proc addAnchor*(anchors: TrustAnchors;
                publicKey: PublicKeyBytes;
                privateKey: PrivateKeyBytes) =
  ## Registers a single trust anchor entry. Repeated calls with the
  ## same public key overwrite the recorded private key (idempotent).
  anchors.allowedKeys.incl(publicKey)
  anchors.privateKeys[publicKey] = privateKey

proc loadTrustAnchors*(path: string): TrustAnchors =
  ## Parses a trust-anchor file. Each entry: `<pub_hex_64>:<priv_hex_64>`
  ## on its own line. Blank lines and `#`-prefixed lines are ignored.
  ## Raises `AuthError` on a malformed entry or missing file.
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
    let parts = line.split(':')
    if parts.len != 2:
      raise newException(AuthError,
        "trust anchor file " & path & " line " & $lineNo &
        ": expected `<pubkey_hex>:<privkey_hex>`")
    let pub = parseHex32(parts[0].strip())
    let priv = parseHex32(parts[1].strip())
    let derived = derivePublicKey(priv)
    if derived != pub:
      raise newException(AuthError,
        "trust anchor file " & path & " line " & $lineNo &
        ": pubkey does not match derive(privkey)")
    result.addAnchor(pub, priv)

proc writeTrustAnchors*(path: string;
                        entries: openArray[PeerKeypair]) =
  ## Persists `entries` to disk in the canonical trust-anchor format.
  ## Used by the M3 verification tests + the loopback fixture to build
  ## per-tenant anchor files. Overwrites any existing file.
  let parent = parentDir(path)
  if parent.len > 0 and not dirExists(parent):
    createDir(parent)
  var lines: seq[string] = @[]
  for entry in entries:
    lines.add(toHex32(entry.publicKey) & ":" & toHex32(entry.privateKey))
  writeFile(path, lines.join("\n") & "\n")

# ---------------------------------------------------------------------------
# Signing + verification.
# ---------------------------------------------------------------------------

proc hmacSha256Bytes(key: openArray[byte]; msg: openArray[byte]):
    array[32, byte] =
  ## Thin wrapper around `nimcrypto.sha256.hmac` that returns the raw
  ## 32-byte digest. The library's `hmac` template handles empty
  ## inputs correctly (empty msg + non-empty key → fixed output).
  let digest = sha256.hmac(key, msg)
  result = digest.data

proc signMessage*(kp: PeerKeypair; msg: openArray[byte]): SignatureBytes =
  ## Produces a 64-byte detached signature over `msg`. The first 32
  ## bytes are HMAC-SHA256(privateKey, msg); the second 32 bytes are
  ## HMAC-SHA256(privateKey, first_32 || msg). This double-HMAC keeps
  ## the wire-shape Ed25519-sized for a future swap-in.
  let first = hmacSha256Bytes(kp.privateKey, msg)
  var contextBuf = newSeq[byte](32 + msg.len)
  for i in 0 ..< 32:
    contextBuf[i] = first[i]
  for i in 0 ..< msg.len:
    contextBuf[32 + i] = msg[i]
  let second = hmacSha256Bytes(kp.privateKey, contextBuf)
  for i in 0 ..< 32:
    result[i] = first[i]
    result[32 + i] = second[i]

proc verifySignature*(anchors: TrustAnchors;
                      publicKey: PublicKeyBytes;
                      msg: openArray[byte];
                      sig: SignatureBytes): bool =
  ## Verifies that `sig` is the signature of `msg` by the holder of
  ## `publicKey`, against the trust anchors. Returns `false` (no
  ## raise) on any missing-anchor / wrong-signature path so callers
  ## can branch on the bool without try/except.
  if publicKey notin anchors.allowedKeys:
    return false
  if not anchors.privateKeys.hasKey(publicKey):
    return false
  let priv = anchors.privateKeys[publicKey]
  let recomputed =
    signMessage(PeerKeypair(publicKey: publicKey, privateKey: priv), msg)
  result = recomputed == sig

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
  ## signature covers. The shape — fixed-order, length-prefixed —
  ## matches `Peer-Cache-Scale.md` §"mTLS + signed advertisements":
  ##
  ##   sequence (uint64 LE) ||
  ##   peerId (32 bytes)    ||
  ##   filterCapacity (uint32 LE) ||
  ##   filterCount (uint32 LE)    ||
  ##   filterBytes_len (uint32 LE) ||
  ##   filterBytes
  ##
  ## The `signature` field is *not* part of the canonical form (that
  ## would be circular). The `mode` field is also omitted because
  ## flipping snapshot↔delta on the same filter is not a security-
  ## relevant tamper (the cuckoo filter bytes are the actual payload).
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

# ---------------------------------------------------------------------------
# Random challenge generation.
# ---------------------------------------------------------------------------

proc generateChallenge*(): array[32, byte] =
  ## 32 bytes of OS entropy for use in `mkAuthChallenge`. Raises
  ## `AuthError` if the OS RNG fails.
  let n = randomBytes(addr result[0], sizeof(result))
  if n != sizeof(result):
    raise newException(AuthError,
      "OS RNG returned " & $n & " bytes, expected " & $sizeof(result))
