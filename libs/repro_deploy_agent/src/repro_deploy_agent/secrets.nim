## Encrypted secrets for the reprobuild deploy manifest (RDMF v2).
##
## ## Why this exists
##
## An RDMF manifest is SIGNED, not encrypted: every field is plaintext, the
## publish directory is world-readable by design ("the signature, not the ACL,
## is what makes them trustworthy"), and the guest hop is plain HTTP. That is
## the right shape for desired state, which is a public assertion. It is the
## wrong shape for the two things a pull-model box also needs: its binary-cache
## publisher key, and a GitHub registration token that expires hourly.
##
## Before this module those arrived by the controller SCP-ing them into the
## guest on every bootstrap, which is exactly the push dependency the deploy
## agent exists to remove. A dedicated bare-metal box (`win-ci-bare-001`) has
## no such controller leg, so it had no route for either.
##
## This adds a sealed section to the manifest, addressed to ONE recipient.
##
## ## What this does NOT remove
##
## It does not remove the need for a provisioning-time credential; it reduces
## it to exactly one. The box must hold the private half of its recipient
## keypair to open the envelope, and that key has to be installed the same way
## its computer name and SSH key are. What is bought is that everything
## *after* it — publisher key, hourly tokens, anything later — rides the
## manifest and can rotate without touching the box.
##
## ## Construction
##
## Standard ECIES over the curve the codebase already uses, with no new
## dependency: every primitive below is BearSSL, which the guest already links
## for cache signature verification.
##
##   Z        = ECDH(ephemeralPrivate, recipientPublic).X     (32 bytes)
##   K || N   = HKDF-SHA256(ikm = Z,
##                          salt = "RDMF-secrets-v2",
##                          info = target || ephemeralPublic || recipientPublic)
##   sealed   = AES-256-GCM(key = K, nonce = N,
##                          aad = "RDMF-v2:" & target,
##                          plaintext = encoded secret-file list)
##
## `K` is 32 bytes and `N` is 12, taken from one 44-byte HKDF stream.
##
## **On the nonce being derived rather than random.** GCM is catastrophically
## broken by nonce reuse under one key. Here the ephemeral keypair is fresh for
## every seal, so `Z` — and therefore `K` — is fresh for every seal, and a
## derived nonce cannot collide under a repeated key because the key never
## repeats. Deriving it is strictly safer than sampling 12 random bytes, which
## would have a birthday bound if the ephemeral key were ever reused by a
## caller bug.
##
## **On `info` binding.** Binding the target name and both public keys into the
## KDF means an envelope sealed for one target cannot be replayed at another
## even by a producer the box trusts: the derived key would differ and the tag
## check would fail. The AAD repeats the target for defence in depth.
##
## **On placement.** The sealed blob lives INSIDE the manifest's signed prefix,
## so the producer's ECDSA signature already covers it. The GCM tag protects
## the ciphertext against a tamperer who never had the signing key; the
## signature protects it against one who did not have it either but could
## reach the served bytes. Neither is redundant: the tag is what makes
## decryption fail closed, and it is checked BEFORE any plaintext is used.

import std/[os, strutils]

import ../../../repro_peer_cache/src/repro_peer_cache/auth as peerAuth

import bearssl/abi/consttypes as bsslConst
import bearssl/abi/bearssl_ec as bsslEc
import bearssl/abi/bearssl_hash as bsslHash
import bearssl/abi/bearssl_kdf as bsslKdf
import bearssl/abi/bearssl_aead as bsslAead
import bearssl/abi/bearssl_block as bsslBlock

const
  GcmNonceLen* = 12
  GcmTagLen* = 16
  AesKeyLen* = 32
  SharedSecretLen* = 32

  HkdfSalt = "RDMF-secrets-v2"
  AadPrefix = "RDMF-v2:"

  P256Curve = cint(bsslEc.EC_secp256r1)

type
  SecretFile* = object
    ## One file to materialise on the target before the apply runs.
    path*: string
      ## Destination, RELATIVE to the agent's secrets directory. Validated:
      ## forward slashes only, no drive letter, no leading separator, no `..`
      ## component. See `validateSecretPath`.
    mode*: uint32
      ## POSIX-style mode. On Windows only the "is this private" bit of it is
      ## meaningful, and the agent tightens the DACL regardless; it is carried
      ## so the same manifest is usable on a POSIX target later.
    content*: seq[byte]

  SealedSecrets* = object
    ## The encrypted section as it appears on the wire.
    ephemeralPubKey*: peerAuth.PublicKeyBytes
    nonce*: array[GcmNonceLen, byte]
    tag*: array[GcmTagLen, byte]
    ciphertext*: seq[byte]

  SecretsError* = object of CatchableError
    ## Malformed secret list, bad key material, or a failed tag check.

# ---------------------------------------------------------------------------
# Path validation.
#
# The agent writes these paths under a directory it owns. A manifest is signed
# by a producer the box trusts, so this is not the primary trust boundary --
# but a path that escapes the secrets directory would let a compromised or
# simply buggy producer drop a file anywhere the agent can write, as SYSTEM.
# Validate structurally and reject, rather than normalise and hope.
# ---------------------------------------------------------------------------

proc validateSecretPath*(path: string) =
  ## Raise `SecretsError` unless `path` is a safe relative destination.
  if path.len == 0:
    raise newException(SecretsError, "secret file path is empty")
  if '\\' in path:
    raise newException(SecretsError,
      "secret file path must use forward slashes, got: " & path)
  if path[0] == '/':
    raise newException(SecretsError,
      "secret file path must be relative, got: " & path)
  if path.len >= 2 and path[1] == ':':
    raise newException(SecretsError,
      "secret file path must not carry a drive letter, got: " & path)
  for part in path.split('/'):
    if part.len == 0:
      raise newException(SecretsError,
        "secret file path has an empty component, got: " & path)
    if part == "..":
      raise newException(SecretsError,
        "secret file path must not contain '..', got: " & path)

# ---------------------------------------------------------------------------
# Plaintext codec for the secret-file list.
#
# Same hand-rolled little-endian shape as the manifest envelope so the whole
# format stays byte-traceable by a reviewer.
# ---------------------------------------------------------------------------

proc writeU32LE(buf: var seq[byte]; v: uint32) =
  for shift in countup(0, 24, 8):
    buf.add(byte((v shr uint32(shift)) and 0xff'u32))

proc readU32LE(buf: openArray[byte]; pos: var int): uint32 =
  if buf.len - pos < 4:
    raise newException(SecretsError, "secret payload truncated reading u32")
  result = 0'u32
  for i in 0 ..< 4:
    result = result or (uint32(buf[pos + i]) shl uint32(i * 8))
  inc pos, 4

proc encodeSecretFiles*(files: seq[SecretFile]): seq[byte] =
  ## Canonical plaintext for the sealed section.
  result = newSeqOfCap[byte](256)
  writeU32LE(result, uint32(files.len))
  for f in files:
    validateSecretPath(f.path)
    writeU32LE(result, uint32(f.path.len))
    for ch in f.path:
      result.add(byte(ch))
    writeU32LE(result, f.mode)
    writeU32LE(result, uint32(f.content.len))
    for b in f.content:
      result.add(b)

proc decodeSecretFiles*(buf: openArray[byte]): seq[SecretFile] =
  ## Inverse of `encodeSecretFiles`. Rejects trailing bytes: a decoder that
  ## silently ignores them would accept a payload the producer did not mean.
  var pos = 0
  let count = int(readU32LE(buf, pos))
  result = newSeqOfCap[SecretFile](count)
  for _ in 0 ..< count:
    var f = SecretFile()
    let pathLen = int(readU32LE(buf, pos))
    if buf.len - pos < pathLen:
      raise newException(SecretsError, "secret payload truncated reading path")
    f.path = newString(pathLen)
    for i in 0 ..< pathLen:
      f.path[i] = char(buf[pos + i])
    inc pos, pathLen
    validateSecretPath(f.path)
    f.mode = readU32LE(buf, pos)
    let contentLen = int(readU32LE(buf, pos))
    if buf.len - pos < contentLen:
      raise newException(SecretsError,
        "secret payload truncated reading content of " & f.path)
    f.content = newSeq[byte](contentLen)
    for i in 0 ..< contentLen:
      f.content[i] = buf[pos + i]
    inc pos, contentLen
    result.add(f)
  if pos != buf.len:
    raise newException(SecretsError,
      "secret payload has trailing bytes: pos=" & $pos & " len=" & $buf.len)

# ---------------------------------------------------------------------------
# ECDH + HKDF.
# ---------------------------------------------------------------------------

proc ecdhSharedX(privateKey: peerAuth.PrivateKeyBytes;
                 peerPublicKey: peerAuth.PublicKeyBytes): array[SharedSecretLen, byte] =
  ## Raw ECDH: multiply the peer's public point by our scalar and return the X
  ## coordinate of the result.
  ##
  ## `mul` works IN PLACE on a mutable copy of the point, and returns 0 for a
  ## point that is not on the curve or a scalar out of range -- which is the
  ## invalid-public-key check, so it is a hard error rather than a value we
  ## proceed with.
  var point: array[peerAuth.P256PubLen, byte]
  for i in 0 ..< peerAuth.P256PubLen:
    point[i] = peerPublicKey[i]
  var scalar: array[peerAuth.P256PrivLen, byte]
  for i in 0 ..< peerAuth.P256PrivLen:
    scalar[i] = privateKey[i]

  let impl = bsslEc.ecGetDefault()
  let ok = impl.mul(addr point[0], csize_t(peerAuth.P256PubLen),
                    cast[bsslConst.ConstPtrByte](addr scalar[0]),
                    csize_t(peerAuth.P256PrivLen), P256Curve)
  if ok != 1'u32:
    raise newException(SecretsError,
      "ECDH failed: recipient public key is not a valid P-256 point")

  var xlen: uint
  let xoff = int(impl.xoff(P256Curve, xlen))
  if int(xlen) != SharedSecretLen:
    raise newException(SecretsError,
      "ECDH produced an X coordinate of " & $xlen & " bytes, expected " &
      $SharedSecretLen)
  for i in 0 ..< SharedSecretLen:
    result[i] = point[xoff + i]

proc deriveKeyAndNonce(shared: array[SharedSecretLen, byte];
                       target: string;
                       ephemeralPub, recipientPub: peerAuth.PublicKeyBytes):
    tuple[key: array[AesKeyLen, byte], nonce: array[GcmNonceLen, byte]] =
  ## HKDF-SHA256 over the shared secret, binding the target name and both
  ## public keys so an envelope cannot be replayed at a different target.
  var info = newSeqOfCap[byte](target.len + 2 * peerAuth.P256PubLen)
  for ch in target:
    info.add(byte(ch))
  for b in ephemeralPub:
    info.add(b)
  for b in recipientPub:
    info.add(b)

  var salt = HkdfSalt
  var ikm = shared
  var hc: bsslKdf.HkdfContext
  bsslKdf.hkdfInit(hc, addr bsslHash.sha256Vtable, addr salt[0],
                   csize_t(salt.len))
  bsslKdf.hkdfInject(hc, addr ikm[0], csize_t(SharedSecretLen))
  bsslKdf.hkdfFlip(hc)

  var stream: array[AesKeyLen + GcmNonceLen, byte]
  let produced = bsslKdf.hkdfProduce(hc, addr info[0], csize_t(info.len),
                                     addr stream[0], csize_t(stream.len))
  if int(produced) != stream.len:
    raise newException(SecretsError,
      "HKDF produced " & $produced & " bytes, expected " & $stream.len)
  for i in 0 ..< AesKeyLen:
    result.key[i] = stream[i]
  for i in 0 ..< GcmNonceLen:
    result.nonce[i] = stream[AesKeyLen + i]

proc gcmTransform(key: array[AesKeyLen, byte];
                  nonce: array[GcmNonceLen, byte];
                  aad: string;
                  data: var seq[byte];
                  encrypt: bool;
                  tag: var array[GcmTagLen, byte]): bool =
  ## Run AES-256-GCM over `data` in place. When `encrypt`, writes the
  ## authentication tag into `tag` and returns true. When decrypting, checks
  ## `tag` and returns whether it matched -- the caller MUST NOT use `data` if
  ## this returns false.
  var keyCopy = key
  var nonceCopy = nonce
  var aadCopy = aad

  var bc: bsslBlock.AesCtCtrKeys
  bsslBlock.aesCtCtrInit(bc, addr keyCopy[0], csize_t(AesKeyLen))

  var gc: bsslAead.GcmContext
  bsslAead.gcmInit(gc, addr bc.vtable, bsslHash.ghashCtmul32)
  bsslAead.gcmReset(gc, addr nonceCopy[0], csize_t(GcmNonceLen))
  if aadCopy.len > 0:
    bsslAead.gcmAadInject(gc, addr aadCopy[0], csize_t(aadCopy.len))
  bsslAead.gcmFlip(gc)
  if data.len > 0:
    bsslAead.gcmRun(gc, (if encrypt: cint(1) else: cint(0)), addr data[0],
                    csize_t(data.len))
  else:
    bsslAead.gcmRun(gc, (if encrypt: cint(1) else: cint(0)), nil, csize_t(0))

  if encrypt:
    bsslAead.gcmGetTag(gc, addr tag[0])
    result = true
  else:
    result = bsslAead.gcmCheckTag(gc, addr tag[0]) == 1'u32

# ---------------------------------------------------------------------------
# Seal / open.
# ---------------------------------------------------------------------------

proc sealSecrets*(recipientPubKey: peerAuth.PublicKeyBytes;
                  target: string;
                  files: seq[SecretFile]): SealedSecrets =
  ## Encrypt `files` to `recipientPubKey`. A fresh ephemeral keypair is
  ## generated per call, so the derived AES key is unique per envelope.
  let ephemeral = peerAuth.generateKeypair()
  let shared = ecdhSharedX(ephemeral.privateKey, recipientPubKey)
  let derived = deriveKeyAndNonce(shared, target, ephemeral.publicKey,
                                  recipientPubKey)
  var payload = encodeSecretFiles(files)
  var tag: array[GcmTagLen, byte]
  discard gcmTransform(derived.key, derived.nonce, AadPrefix & target,
                       payload, encrypt = true, tag = tag)
  result.ephemeralPubKey = ephemeral.publicKey
  result.nonce = derived.nonce
  result.tag = tag
  result.ciphertext = payload

proc openSecrets*(recipientPrivKey: peerAuth.PrivateKeyBytes;
                  target: string;
                  sealed: SealedSecrets): seq[SecretFile] =
  ## Decrypt and parse. Raises `SecretsError` on a failed tag check, on a
  ## malformed payload, or on an unusable ephemeral key.
  ##
  ## Fails CLOSED and loudly: there is no partial-success path, and no
  ## plaintext is parsed before the tag is verified.
  let recipientPub = peerAuth.derivePublicKey(recipientPrivKey)
  let shared = ecdhSharedX(recipientPrivKey, sealed.ephemeralPubKey)
  let derived = deriveKeyAndNonce(shared, target, sealed.ephemeralPubKey,
                                  recipientPub)
  var payload = sealed.ciphertext
  var tag = sealed.tag
  if not gcmTransform(derived.key, derived.nonce, AadPrefix & target,
                      payload, encrypt = false, tag = tag):
    raise newException(SecretsError,
      "sealed secrets failed authentication for target '" & target &
      "': wrong recipient key, wrong target, or tampered ciphertext")
  decodeSecretFiles(payload)

# ---------------------------------------------------------------------------
# Materialisation.
# ---------------------------------------------------------------------------

proc materialiseSecrets*(files: seq[SecretFile]; destDir: string): seq[string] =
  ## Write the opened secrets under `destDir`, returning the absolute paths.
  ##
  ## **Each file is published atomically** — staged alongside, then renamed
  ## into place. A registration token is read by a separate process
  ## (`register-runner.ps1`) that polls for it, so a consumer must never be
  ## able to observe the path existing with partial content. Renaming within
  ## the same directory is atomic on both NTFS and POSIX.
  ##
  ## **Securing `destDir` is the PROFILE's job, not this proc's.** The
  ## directory carries the DACL and the files inherit it, exactly as
  ## `C:\actions-runner-tokens` already does (an `fs.systemDirectory` paired
  ## with a `windows.acl`). Setting per-file ACLs here would mean the agent
  ## and the profile both assert who may read these bytes, and the profile
  ## would re-apply forever against whatever the agent last wrote. The POSIX
  ## mode below is applied only where it is the whole story.
  createDir(destDir)
  result = newSeqOfCap[string](files.len)
  for f in files:
    validateSecretPath(f.path)
    let dest = destDir / f.path
    let parent = parentDir(dest)
    if parent.len > 0:
      createDir(parent)
    let staged = dest & ".staged"
    var content = newString(f.content.len)
    for i, b in f.content:
      content[i] = char(b)
    writeFile(staged, content)
    when defined(posix):
      var perms: set[FilePermission] = {}
      if (f.mode and 0o400'u32) != 0: perms.incl(fpUserRead)
      if (f.mode and 0o200'u32) != 0: perms.incl(fpUserWrite)
      if (f.mode and 0o040'u32) != 0: perms.incl(fpGroupRead)
      if (f.mode and 0o004'u32) != 0: perms.incl(fpOthersRead)
      setFilePermissions(staged, perms)
    moveFile(staged, dest)
    result.add(dest)
