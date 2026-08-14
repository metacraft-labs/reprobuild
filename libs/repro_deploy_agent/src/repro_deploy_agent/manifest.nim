## Windows-Runner-Binary-Cache-Deploy M5 — signed desired-state manifest.
##
## The reprobuild-native analog of the Linux ``mcl-deploy-agent`` manifest
## (nixos-modules ``packages/mcl/src/mcl/utils/deploy_manifest.d``). Where
## the Linux model uses a JSON document + an OpenSSH ``allowed-signers``
## file, this reuses reprobuild's OWN signature scheme:
##
##   * ECDSA-P256 sign / verify via ``repro_peer_cache/auth`` — the SAME
##     primitive the binary cache uses to sign published manifests
##     (``repro_binary_cache_server/manifest_codec.signManifest``). No new
##     crypto is invented.
##   * An allowed-signers set is the peer-cache ``TrustAnchors`` (a
##     ``HashSet[PublicKeyBytes]`` of 65-byte uncompressed ECDSA-P256
##     public keys). A manifest is accepted iff its signature verifies
##     against the embedded producer pubkey AND that pubkey is in the
##     allowed-signers set. This is exactly ``peerAuth.verifySignature(
##     anchors, pubKey, msg, sig)``.
##
## ## Why this scheme (vs. the Linux ssh allowed-signers model)
##
## The reprobuild deploy agent runs INSIDE the reprobuild product on the
## Windows box. That box already carries the binary-cache client, which
## already links ``repro_peer_cache/auth`` and already trusts ECDSA-P256
## producer keys for cache substitution. Reusing the same key material +
## the same verify primitive means:
##
##   * ZERO new dependencies on the guest (no ``ssh-keygen -Y verify``
##     shell-out, which the Windows box would need OpenSSH for);
##   * the deployment-signing key and the cache-publishing key are the
##     SAME KIND of key, so one CI signer can sign both the cache
##     manifests and the desired-state manifests;
##   * the trust-anchor file format is already specified + tested
##     (``auth.loadTrustAnchors`` / ``writeTrustAnchors``: one 130-char
##     hex pubkey per line).
##
## ## Desired-state schema (smallest honest set for the two gates)
##
## A ``DeployManifest`` carries exactly what the two gates need:
##
##   * ``target``          — the target name this manifest applies to. The
##                           agent IGNORES manifests for other targets.
##   * ``sequence``        — a monotonic uint64. The agent applies only the
##                           HIGHEST valid sequence and never re-applies an
##                           older/equal one.
##   * ``deploymentId``    — a stable id for this desired state (used for
##                           the ambiguity check + converged short-circuit).
##   * ``profileText``     — the desired ``system.nim`` profile text the
##                           agent applies via the M4 ``runInfraApply`` path
##                           (build-action outputs substituted from the
##                           binary cache).
##   * ``buildActions``    — the profile's action-edge intent items
##                           (id/argv/cwd/outputs/…), the same
##                           ``ProfileBuildAction`` shape the apply path
##                           threads into ``ApplyOptions.buildActions``.
##                           Carrying them in the manifest keeps the
##                           hermetic gate self-contained (no on-box profile
##                           compile) while exercising the REAL apply +
##                           substitute path.
##   * ``producerPubKey``  — 65-byte uncompressed ECDSA-P256 pubkey of the
##                           signer.
##   * ``signature``       — 64-byte raw ECDSA-P256 (r||s) over the
##                           canonical unsigned prefix.
##
## The canonical byte encoding follows the cache codec's hand-rolled,
## length-prefixed, little-endian pattern so the signed bytes are stable
## and reviewers can byte-trace it. The signed payload is everything UP TO
## ``signature``.

import ../../../repro_peer_cache/src/repro_peer_cache/auth as peerAuth
import repro_profile as reproProfile
import ./secrets as reproSecrets

export reproSecrets.SealedSecrets, reproSecrets.SecretFile,
       reproSecrets.SecretsError

type
  DeployManifest* = object
    ## A signed desired-state document for ONE target.
    formatVersion*: uint16
    target*: string
    sequence*: uint64
    deploymentId*: string
    profileText*: string
    buildActions*: seq[reproProfile.ProfileBuildAction]
    hasSecrets*: bool
      ## Whether ``secrets`` carries a sealed section. Only ever true for a
      ## v2 envelope; see ``DeployManifestFormatVersionV2``.
    secrets*: reproSecrets.SealedSecrets
    producerPubKey*: peerAuth.PublicKeyBytes
    signature*: peerAuth.SignatureBytes

  DeployManifestCodecError* = object of CatchableError
    ## Malformed envelope or version mismatch.

  DeployManifestSignatureError* = object of CatchableError
    ## Signature did not verify (bad signature or untrusted signer).

const
  DeployManifestMagic* = "RDMF"
    ## "Reprobuild Deploy ManiFest" — the FORMAT FAMILY identifier, and
    ## nothing else. It carries no version and must never be bumped for a
    ## schema change; `formatVersion` below is the sole version. This is the
    ## PNG/RIFF split, and it is deliberate: the previous magic was `RDM1`,
    ## whose trailing digit read as a version and then contradicted a v2
    ## envelope that still began with the bytes `RDM1`. Anyone hexdumping a
    ## manifest while debugging met that contradiction at the worst moment.
  DeployManifestFormatVersionV1* = 1'u16
    ## Original envelope: desired state only, entirely plaintext.
  DeployManifestFormatVersionV2* = 2'u16
    ## Adds a sealed-secrets section (see ``secrets.nim``) between the build
    ## actions and the producer public key, INSIDE the signed prefix.
  DeployManifestFormatVersion* = DeployManifestFormatVersionV1
    ## Retained for source compatibility with callers that referenced the
    ## single-version constant. Producers should not read this: the version a
    ## manifest carries is chosen by content (see ``encodeUnsignedPrefix``).

  # ## Why two versions rather than one bumped version
  #
  # A v1 manifest is still exactly right for a target with no secrets, and
  # `win-ci-vm-001` is served one today. Emitting v2 unconditionally would
  # invalidate that live manifest for every agent not yet upgraded, for no
  # gain. So the producer emits the LOWEST version that can express the
  # content, and a current agent accepts both.
  #
  # The asymmetry is deliberate and is the safe direction: an OLD agent shown
  # a v2 envelope rejects it on the version check and applies nothing, rather
  # than applying desired state while silently discarding the secrets that
  # state depends on.

# ---------------------------------------------------------------------------
# Little-endian primitives (same shape as the cache codec).
# ---------------------------------------------------------------------------

proc writeU16LE(buf: var seq[byte]; v: uint16) =
  buf.add(byte(v and 0xff'u16))
  buf.add(byte((v shr 8) and 0xff'u16))

proc writeU32LE(buf: var seq[byte]; v: uint32) =
  for shift in countup(0, 24, 8):
    buf.add(byte((v shr uint32(shift)) and 0xff'u32))

proc writeU64LE(buf: var seq[byte]; v: uint64) =
  for shift in countup(0, 56, 8):
    buf.add(byte((v shr uint64(shift)) and 0xff'u64))

proc writeU8(buf: var seq[byte]; v: uint8) =
  buf.add(v)

proc writeString(buf: var seq[byte]; v: string) =
  writeU32LE(buf, uint32(v.len))
  for ch in v:
    buf.add(byte(ch))

proc writeStrSeq(buf: var seq[byte]; xs: seq[string]) =
  writeU32LE(buf, uint32(xs.len))
  for x in xs:
    writeString(buf, x)

# ---------------------------------------------------------------------------
# Cursor readers.
# ---------------------------------------------------------------------------

template ensureBytes(remaining, need: int; what: string) =
  if remaining < need:
    raise newException(DeployManifestCodecError,
      "manifest truncated reading " & what & ": need " & $need &
      " bytes, have " & $remaining)

proc readU8(buf: openArray[byte]; pos: var int): uint8 =
  ensureBytes(buf.len - pos, 1, "u8")
  result = buf[pos]
  inc pos

proc readU16LE(buf: openArray[byte]; pos: var int): uint16 =
  ensureBytes(buf.len - pos, 2, "u16")
  result = uint16(buf[pos]) or (uint16(buf[pos + 1]) shl 8)
  inc pos, 2

proc readU32LE(buf: openArray[byte]; pos: var int): uint32 =
  ensureBytes(buf.len - pos, 4, "u32")
  result = 0'u32
  for i in 0 ..< 4:
    result = result or (uint32(buf[pos + i]) shl uint32(i * 8))
  inc pos, 4

proc readU64LE(buf: openArray[byte]; pos: var int): uint64 =
  ensureBytes(buf.len - pos, 8, "u64")
  result = 0'u64
  for i in 0 ..< 8:
    result = result or (uint64(buf[pos + i]) shl uint64(i * 8))
  inc pos, 8

proc readString(buf: openArray[byte]; pos: var int): string =
  let n = int(readU32LE(buf, pos))
  ensureBytes(buf.len - pos, n, "string payload")
  result = newString(n)
  for i in 0 ..< n:
    result[i] = char(buf[pos + i])
  inc pos, n

proc readStrSeq(buf: openArray[byte]; pos: var int): seq[string] =
  let n = int(readU32LE(buf, pos))
  result = newSeqOfCap[string](n)
  for _ in 0 ..< n:
    result.add(readString(buf, pos))

proc readPubKey(buf: openArray[byte]; pos: var int): peerAuth.PublicKeyBytes =
  ensureBytes(buf.len - pos, peerAuth.P256PubLen, "ECDSA-P256 pubkey")
  for i in 0 ..< peerAuth.P256PubLen:
    result[i] = buf[pos + i]
  inc pos, peerAuth.P256PubLen

proc readSignature(buf: openArray[byte]; pos: var int): peerAuth.SignatureBytes =
  ensureBytes(buf.len - pos, peerAuth.P256SigLen, "ECDSA-P256 signature")
  for i in 0 ..< peerAuth.P256SigLen:
    result[i] = buf[pos + i]
  inc pos, peerAuth.P256SigLen

# ---------------------------------------------------------------------------
# ProfileBuildAction sub-codec.
#
# A ProfileBuildAction is a plain data record (id + argv + cwd + deps +
# inputs + outputs + commandStatsId + toolIdentityRefs + requiresElevation
# + cacheable). We encode exactly those fields, canonically, so the signed
# bytes cover the WHOLE desired action set — a tampered argv changes the
# signed prefix and fails verification.
# ---------------------------------------------------------------------------

proc encodeBuildAction(buf: var seq[byte]; a: reproProfile.ProfileBuildAction) =
  writeString(buf, a.id)
  writeStrSeq(buf, a.argv)
  writeString(buf, a.cwd)
  writeStrSeq(buf, a.deps)
  writeStrSeq(buf, a.inputs)
  writeStrSeq(buf, a.outputs)
  writeString(buf, a.commandStatsId)
  writeStrSeq(buf, a.toolIdentityRefs)
  writeU8(buf, if a.requiresElevation: 1'u8 else: 0'u8)
  writeU8(buf, if a.cacheable: 1'u8 else: 0'u8)

proc decodeBuildAction(buf: openArray[byte]; pos: var int):
    reproProfile.ProfileBuildAction =
  result.id = readString(buf, pos)
  result.argv = readStrSeq(buf, pos)
  result.cwd = readString(buf, pos)
  result.deps = readStrSeq(buf, pos)
  result.inputs = readStrSeq(buf, pos)
  result.outputs = readStrSeq(buf, pos)
  result.commandStatsId = readString(buf, pos)
  result.toolIdentityRefs = readStrSeq(buf, pos)
  result.requiresElevation = readU8(buf, pos) != 0'u8
  result.cacheable = readU8(buf, pos) != 0'u8

# ---------------------------------------------------------------------------
# Whole-manifest encode.
# ---------------------------------------------------------------------------

proc wireVersion*(m: DeployManifest): uint16 =
  ## The lowest format version that can express this manifest's content.
  if m.hasSecrets: DeployManifestFormatVersionV2
  else: DeployManifestFormatVersionV1

proc encodeUnsignedPrefix(m: DeployManifest): seq[byte] =
  ## Everything up to (but not including) the signature. The bytes the
  ## producer key signs.
  ##
  ## The sealed-secrets section sits INSIDE this prefix on purpose: the
  ## producer's signature then covers the ciphertext, the ephemeral public key
  ## and the nonce, so none of them can be swapped for another target's
  ## envelope by anyone who cannot sign.
  result = newSeqOfCap[byte](512)
  for ch in DeployManifestMagic:
    result.add(byte(ch))
  writeU16LE(result, m.wireVersion)
  writeU16LE(result, 0'u16)                  # reserved / future flags
  writeString(result, m.target)
  writeU64LE(result, m.sequence)
  writeString(result, m.deploymentId)
  writeString(result, m.profileText)
  writeU32LE(result, uint32(m.buildActions.len))
  for a in m.buildActions:
    encodeBuildAction(result, a)
  if m.wireVersion >= DeployManifestFormatVersionV2:
    writeU8(result, if m.hasSecrets: 1'u8 else: 0'u8)
    if m.hasSecrets:
      for b in m.secrets.ephemeralPubKey:
        result.add(b)
      for b in m.secrets.nonce:
        result.add(b)
      for b in m.secrets.tag:
        result.add(b)
      writeU32LE(result, uint32(m.secrets.ciphertext.len))
      for b in m.secrets.ciphertext:
        result.add(b)
  for b in m.producerPubKey:
    result.add(b)

proc encodeManifest*(m: DeployManifest): seq[byte] =
  ## Full envelope including the trailing 64-byte signature.
  result = encodeUnsignedPrefix(m)
  for b in m.signature:
    result.add(b)

# ---------------------------------------------------------------------------
# Whole-manifest decode.
# ---------------------------------------------------------------------------

proc decodeManifest*(buf: openArray[byte]): DeployManifest =
  if buf.len < DeployManifestMagic.len + 4 + peerAuth.P256SigLen:
    raise newException(DeployManifestCodecError,
      "deploy manifest envelope too short: " & $buf.len & " bytes")
  for i, ch in DeployManifestMagic:
    if buf[i] != byte(ch):
      raise newException(DeployManifestCodecError,
        "deploy manifest magic mismatch at byte " & $i)
  var pos = DeployManifestMagic.len
  result.formatVersion = readU16LE(buf, pos)
  if result.formatVersion != DeployManifestFormatVersionV1 and
     result.formatVersion != DeployManifestFormatVersionV2:
    raise newException(DeployManifestCodecError,
      "deploy manifest format version mismatch: got " &
      $result.formatVersion & ", expected " & $DeployManifestFormatVersionV1 &
      " or " & $DeployManifestFormatVersionV2)
  discard readU16LE(buf, pos)                # reserved
  result.target = readString(buf, pos)
  result.sequence = readU64LE(buf, pos)
  result.deploymentId = readString(buf, pos)
  result.profileText = readString(buf, pos)
  let actionCount = int(readU32LE(buf, pos))
  result.buildActions = newSeqOfCap[reproProfile.ProfileBuildAction](actionCount)
  for _ in 0 ..< actionCount:
    result.buildActions.add(decodeBuildAction(buf, pos))
  if result.formatVersion >= DeployManifestFormatVersionV2:
    let flag = readU8(buf, pos)
    if flag > 1'u8:
      raise newException(DeployManifestCodecError,
        "deploy manifest secrets-present flag is " & $flag & ", expected 0 or 1")
    result.hasSecrets = flag == 1'u8
    if result.hasSecrets:
      result.secrets.ephemeralPubKey = readPubKey(buf, pos)
      ensureBytes(buf.len - pos, reproSecrets.GcmNonceLen, "secrets nonce")
      for i in 0 ..< reproSecrets.GcmNonceLen:
        result.secrets.nonce[i] = buf[pos + i]
      inc pos, reproSecrets.GcmNonceLen
      ensureBytes(buf.len - pos, reproSecrets.GcmTagLen, "secrets tag")
      for i in 0 ..< reproSecrets.GcmTagLen:
        result.secrets.tag[i] = buf[pos + i]
      inc pos, reproSecrets.GcmTagLen
      let ctLen = int(readU32LE(buf, pos))
      ensureBytes(buf.len - pos, ctLen, "secrets ciphertext")
      result.secrets.ciphertext = newSeq[byte](ctLen)
      for i in 0 ..< ctLen:
        result.secrets.ciphertext[i] = buf[pos + i]
      inc pos, ctLen
  result.producerPubKey = readPubKey(buf, pos)
  result.signature = readSignature(buf, pos)
  if pos != buf.len:
    raise newException(DeployManifestCodecError,
      "deploy manifest envelope has trailing bytes: pos=" & $pos &
      " len=" & $buf.len)

# ---------------------------------------------------------------------------
# Sign / verify.
# ---------------------------------------------------------------------------

proc signManifest*(kp: peerAuth.PeerKeypair; m: var DeployManifest) =
  ## Populate ``producerPubKey`` + ``signature`` in place with an
  ## ECDSA-P256 signature over the canonical unsigned prefix.
  ##
  ## The version is derived from content rather than taken from the caller, so
  ## a manifest carrying secrets cannot be signed as v1 — which would encode
  ## the section and then advertise a version whose decoder does not read it,
  ## leaving the trailing-bytes check as the only thing standing between that
  ## and a silently truncated apply.
  m.formatVersion = m.wireVersion
  m.producerPubKey = kp.publicKey
  let prefix = encodeUnsignedPrefix(m)
  m.signature = peerAuth.signMessage(kp, prefix)

proc verifySignature*(m: DeployManifest): bool =
  ## Cryptographic check only: does the embedded signature verify against
  ## the embedded producer pubkey over the canonical prefix? Trust-anchor
  ## membership is a SEPARATE check (``verifyTrusted``).
  let prefix = encodeUnsignedPrefix(m)
  peerAuth.verifySignature(m.producerPubKey, prefix, m.signature)

proc verifyTrusted*(m: DeployManifest; anchors: peerAuth.TrustAnchors): bool =
  ## The full gate the agent enforces: the signature verifies AND the
  ## producer pubkey is a member of the allowed-signers set. Returns
  ## ``false`` on either failure (untrusted signer OR bad signature) so
  ## the caller branches without try/except.
  ##
  ## This is exactly the cache's trust model
  ## (``peerAuth.verifySignature(anchors, pubKey, msg, sig)``): a
  ## signature that verifies but whose key is not an anchor is REJECTED.
  let prefix = encodeUnsignedPrefix(m)
  peerAuth.verifySignature(anchors, m.producerPubKey, prefix, m.signature)
