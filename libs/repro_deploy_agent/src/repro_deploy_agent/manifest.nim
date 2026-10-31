## Windows-Runner-Binary-Cache-Deploy M5 — signed desired-state manifest.
##
## The reprobuild-native analog of the Linux ``mcl-deploy-agent`` manifest
## (nixos-modules ``packages/mcl-devops/src/mcl/utils/deploy_manifest.d``). Where
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

import std/[algorithm, strutils]

from repro_core import elementCountFits
import ../../../repro_peer_cache/src/repro_peer_cache/auth as peerAuth
import repro_profile as reproProfile
import ./agent_mutations
import ./secrets as reproSecrets

export reproSecrets.SealedSecrets, reproSecrets.SecretFile,
       reproSecrets.SecretsError

type
  ProfileFile* = object
    ## One file of the profile bundle (RDMF v3). ``path`` is relative to the
    ## profile source, `/`-separated, with no `..` segment: the agent stages
    ## it beside the staged profile so the profile's own `staticRead` finds
    ## it, and nothing else about where the agent keeps that scratch tree is
    ## the producer's business. ``content`` is the file's bytes.
    path*: string
    content*: string

  ClosureDigest* = object
    ## One pinned closure output (RDMF v3): the archive digest of the
    ## declared outputs of the build action ``actionId``, spelled
    ## ``blake3:<64 lowercase hex>`` -- the ``expectedOutputDigest``
    ## spelling, i.e. what ``repro cache publish`` prints for those outputs.
    ## An agent that requires v3 refuses an output whose digest differs,
    ## before it is linked, named in a unit or activated.
    actionId*: string
    digest*: string

  DeployManifest* = object
    ## A signed desired-state document for ONE target.
    formatVersion*: uint16
    target*: string
    sequence*: uint64
    deploymentId*: string
    profileText*: string
    profileFiles*: seq[ProfileFile]
      ## Files the profile reads at compile time, relative to itself (a
      ## `staticRead("locks/x.lock")`). Empty for a self-contained profile.
      ## Non-empty makes the envelope v3; see ``DeployManifestFormatVersionV3``.
    issuedAt*: uint64
      ## RDMF v3 attestation block: when the producer signed this manifest,
      ## in seconds since the Unix epoch (UTC). With ``maxAgeSeconds`` it
      ## bounds how long a mirror can keep serving it (``aoStale``). 0 means
      ## the block is absent; when present it is never 0.
    maxAgeSeconds*: uint64
      ## The oldest this manifest may be when an agent selects it: a manifest
      ## with ``now - issuedAt > maxAgeSeconds`` is stale. Present with
      ## ``issuedAt``, never 0.
    rollbackFloor*: uint64
      ## The lowest manifest SEQUENCE an automatic revert may return to: a
      ## generation applied from an older sequence (or by no manifest at
      ## all) is below the floor. 0 means no floor. Never above ``sequence``.
    closureDigests*: seq[ClosureDigest]
      ## The pinned output digest of every build action this manifest's
      ## desired state realises, sorted by ``actionId``.
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
  DeployManifestFormatVersionV3* = 3'u16
    ## Adds the profile bundle: ``profileFiles``, right after ``profileText``
    ## and inside the signed prefix. A manifest used to carry the profile as
    ## ONE text, so a profile could not read a sibling file at compile time
    ## (an apt closure lock, a long configuration file) and producers had to
    ## inline every such file into the Nim source. Deploy-Agent.md §"The
    ## `RDMF` envelope".
  DeployManifestFlagAttestations* = 1'u16
    ## Bit 0 of the u16 after ``formatVersion`` (``flags``, formerly
    ## "reserved"): the v3 envelope carries the attestation block --
    ## ``issuedAt``, ``maxAgeSeconds``, ``rollbackFloor`` and the closure
    ## digests -- right after the profile bundle. Only a v3 envelope may set
    ## it, and no other bit is defined: a decoder refuses any other value.
    ## A flag rather than a fixed layout because v3 already shipped with the
    ## bundle alone (a producer serving a host whose agent predates the
    ## block keeps emitting that form until the host's agent is upgraded),
    ## and an agent that requires the block (a ReproOS add-on agent) then
    ## refuses a v3 envelope without it exactly as it refuses v1 and v2.
  ClosureDigestPrefix* = "blake3:"
  ClosureDigestHexLen* = 64
  StagedProfileModule* = "manifest_profile.nim"
    ## The file name the agent stages ``profileText`` under before compiling
    ## it (a valid Nim module name: the compiler rejects a hyphenated stem).
    ## Reserved: a bundle file may not use it, since staging would then
    ## overwrite the profile with it.
  MaxDeployManifestBytes* = 32 * 1024 * 1024
    ## The largest envelope an agent reads from a source. A manifest is a
    ## profile plus a bundle of small files (locks, configuration); the cap
    ## stops a 404-page-sized target from being handed an arbitrarily large
    ## body to hold in memory before the signature is even checked. Checked
    ## against ``Content-Length`` before the body is read, and again while
    ## reading it, since a server need not send the header.
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
  let nRaw = readU32LE(buf, pos)
  if not elementCountFits(nRaw, buf.len - pos, 4):
    raise newException(DeployManifestCodecError, "element count exceeds remaining bytes")
  let n = int(nRaw)
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

proc profileFilePathError*(path: string): string =
  ## Why `path` may not name a profile bundle file, or "" when it may. The
  ## agent joins it to its scratch directory and writes there as root, so
  ## the rule is the one a tar extractor applies: relative, `/`-separated,
  ## no empty, `.` or `..` segment, no backslash, no NUL. Enforced by the
  ## decoder (a manifest that breaks it is malformed, like one with
  ## trailing bytes) and by the encoder, so neither implementation can
  ## emit one.
  if path.len == 0: return "profile file path is empty"
  if path[0] == '/': return "profile file path '" & path & "' is absolute"
  if '\\' in path:
    return "profile file path '" & path & "' contains a backslash"
  if '\0' in path:
    return "profile file path contains a NUL byte"
  for seg in path.split('/'):
    if seg.len == 0:
      return "profile file path '" & path & "' has an empty segment"
    if seg == "." or seg == "..":
      return "profile file path '" & path & "' has a '" & seg & "' segment"
    # Reserved at ANY depth, as the producer's validator has it (infra
    # `profile_file_path_error`, corpus `tests/fixtures/profile-file-paths.corpus`):
    # the staged profile is a module, and a bundle file of the same name in
    # a subdirectory would shadow nothing today but would be the one name
    # whose meaning changes if the staging layout ever does.
    if seg == StagedProfileModule:
      return "profile file path '" & path & "' names the reserved staged " &
        "profile module '" & StagedProfileModule & "'"
  ""

proc validateProfileFiles*(files: openArray[ProfileFile]) =
  ## Raise ``DeployManifestCodecError`` on a bad path (``profileFilePathError``,
  ## which includes the reserved ``StagedProfileModule`` name), a duplicate,
  ## or a path that is both a file and a directory of another (``a`` and
  ## ``a/b``): staging would write one over the other, and which one won
  ## would depend on order. The rules are the producer's too: both
  ## implementations are held to ``tests/fixtures/profile-file-paths.corpus``.
  var seen: seq[string]
  for f in files:
    let err = profileFilePathError(f.path)
    if err.len > 0:
      raise newException(DeployManifestCodecError, err)
    if f.path in seen:
      raise newException(DeployManifestCodecError,
        "profile file path '" & f.path & "' appears twice")
    for other in seen:
      if f.path.startsWith(other & "/") or other.startsWith(f.path & "/"):
        raise newException(DeployManifestCodecError,
          "profile file paths '" & other & "' and '" & f.path &
          "' conflict: one is a directory of the other")
    seen.add(f.path)

proc closureDigestError*(d: ClosureDigest): string =
  ## Why ``d`` is not a well-formed closure digest entry, or "".
  if d.actionId.len == 0: return "closure digest names an empty action id"
  if '\0' in d.actionId: return "closure digest action id contains a NUL byte"
  if not d.digest.startsWith(ClosureDigestPrefix) or
      d.digest.len != ClosureDigestPrefix.len + ClosureDigestHexLen:
    return "closure digest for '" & d.actionId & "' is not spelled " &
      ClosureDigestPrefix & "<" & $ClosureDigestHexLen & " hex digits>: '" &
      d.digest & "'"
  for c in d.digest[ClosureDigestPrefix.len .. ^1]:
    if c notin {'0' .. '9', 'a' .. 'f'}:
      return "closure digest for '" & d.actionId &
        "' is not lowercase hex: '" & d.digest & "'"
  ""

proc validateClosureDigests*(ds: openArray[ClosureDigest]) =
  ## Raise ``DeployManifestCodecError`` on a malformed entry, or when the
  ## entries are not strictly ascending by ``actionId`` (byte order). The
  ## order makes the signed bytes of one set of pins unique, so two
  ## producers emitting the same pins sign the same bytes; strictly
  ## ascending also excludes a duplicate id, which would leave which pin
  ## governs an action to the reader.
  for i, d in ds:
    let err = closureDigestError(d)
    if err.len > 0:
      raise newException(DeployManifestCodecError, err)
    if i > 0 and not (ds[i - 1].actionId < d.actionId):
      raise newException(DeployManifestCodecError,
        "closure digests are not strictly ascending by action id: '" &
        ds[i - 1].actionId & "' then '" & d.actionId & "'")

proc hasAttestations*(m: DeployManifest): bool =
  ## Whether ``m`` carries the v3 attestation block. Any of its fields set
  ## means it does; ``validateAttestations`` then requires the mandatory
  ## pair.
  m.issuedAt != 0 or m.maxAgeSeconds != 0 or m.rollbackFloor != 0 or
    m.closureDigests.len > 0

proc validateAttestations*(m: DeployManifest) =
  ## The block's own rules (Deploy-Agent.md §Strictness): ``issuedAt`` and
  ## ``maxAgeSeconds`` are both non-zero, the floor is not above the
  ## manifest's own sequence (a floor no generation of this manifest can
  ## reach would forbid every revert, including to itself), and the
  ## closure digests are well formed and ordered.
  if m.issuedAt == 0:
    raise newException(DeployManifestCodecError,
      "attestation block without issuedAt (seconds since the epoch, > 0)")
  if m.maxAgeSeconds == 0:
    raise newException(DeployManifestCodecError,
      "attestation block without a maximum age (seconds, > 0)")
  if m.rollbackFloor > m.sequence:
    raise newException(DeployManifestCodecError,
      "rollback floor " & $m.rollbackFloor & " is above the manifest's own " &
      "sequence " & $m.sequence)
  validateClosureDigests(m.closureDigests)

proc sortClosureDigests*(ds: var seq[ClosureDigest]) =
  ## Put pins in the order the encoder requires (``validateClosureDigests``).
  ds.sort(proc (a, b: ClosureDigest): int = cmp(a.actionId, b.actionId))

proc closureDigestFor*(m: DeployManifest; actionId: string): string =
  ## The pinned digest of ``actionId``, or "" when the manifest pins none.
  for d in m.closureDigests:
    if d.actionId == actionId: return d.digest
  ""

proc wireFlags*(m: DeployManifest): uint16 =
  if m.hasAttestations: DeployManifestFlagAttestations else: 0'u16

proc wireVersion*(m: DeployManifest): uint16 =
  ## The lowest format version that can express this manifest's content.
  if m.profileFiles.len > 0 or m.hasAttestations: DeployManifestFormatVersionV3
  elif m.hasSecrets: DeployManifestFormatVersionV2
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
  writeU16LE(result, m.wireFlags)            # flags (bit 0: v3 attestations)
  writeString(result, m.target)
  writeU64LE(result, m.sequence)
  writeString(result, m.deploymentId)
  writeString(result, m.profileText)
  if m.wireVersion >= DeployManifestFormatVersionV3:
    validateProfileFiles(m.profileFiles)
    writeU32LE(result, uint32(m.profileFiles.len))
    for f in m.profileFiles:
      writeString(result, f.path)
      writeString(result, f.content)
    if m.hasAttestations:
      validateAttestations(m)
      writeU64LE(result, m.issuedAt)
      writeU64LE(result, m.maxAgeSeconds)
      writeU64LE(result, m.rollbackFloor)
      writeU32LE(result, uint32(m.closureDigests.len))
      for d in m.closureDigests:
        writeString(result, d.actionId)
        writeString(result, d.digest)
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
  if result.formatVersion notin [DeployManifestFormatVersionV1,
      DeployManifestFormatVersionV2, DeployManifestFormatVersionV3]:
    raise newException(DeployManifestCodecError,
      "deploy manifest format version mismatch: got " &
      $result.formatVersion & ", expected " &
      $DeployManifestFormatVersionV1 & ", " & $DeployManifestFormatVersionV2 &
      " or " & $DeployManifestFormatVersionV3)
  let flags = readU16LE(buf, pos)
  # Only a v3 envelope may set a flag, and only the attestation bit is
  # defined; anything else is a layout this decoder cannot read, refused
  # rather than skipped (an older reader that ignored the word would
  # misparse the block as build actions).
  if flags != 0'u16 and (result.formatVersion < DeployManifestFormatVersionV3 or
      flags != DeployManifestFlagAttestations):
    raise newException(DeployManifestCodecError,
      "deploy manifest flags word is " & $flags & " in a formatVersion " &
      $result.formatVersion & " envelope (only formatVersion 3 may set " &
      "bit 0, the attestation block)")
  result.target = readString(buf, pos)
  result.sequence = readU64LE(buf, pos)
  result.deploymentId = readString(buf, pos)
  result.profileText = readString(buf, pos)
  if result.formatVersion >= DeployManifestFormatVersionV3:
    let fileCountRaw = readU32LE(buf, pos)
    if not elementCountFits(fileCountRaw, buf.len - pos, 8):
      raise newException(DeployManifestCodecError,
        "element count exceeds remaining bytes")
    # The lowest-version rule, enforced on the reading side: a v3 envelope
    # with neither a bundle nor the attestation block should have been v2
    # or v1. Named as such, rather than failing later as an invalid
    # signature over bytes no producer emits.
    if fileCountRaw == 0'u32 and flags == 0'u16:
      raise newException(DeployManifestCodecError,
        "non-canonical envelope: formatVersion 3 with no profile files " &
        "and no attestation block (a producer must emit the lowest " &
        "version that expresses its content)")
    for _ in 0 ..< int(fileCountRaw):
      var f: ProfileFile
      f.path = readString(buf, pos)
      f.content = readString(buf, pos)
      result.profileFiles.add(f)
    # Strict, like trailing bytes: a path the agent would refuse to stage
    # makes the whole envelope malformed, so it is rejected here, before
    # the signature is even checked.
    validateProfileFiles(result.profileFiles)
    if flags == DeployManifestFlagAttestations:
      result.issuedAt = readU64LE(buf, pos)
      result.maxAgeSeconds = readU64LE(buf, pos)
      result.rollbackFloor = readU64LE(buf, pos)
      let digestCountRaw = readU32LE(buf, pos)
      if not elementCountFits(digestCountRaw, buf.len - pos, 8):
        raise newException(DeployManifestCodecError,
          "element count exceeds remaining bytes")
      for _ in 0 ..< int(digestCountRaw):
        var d: ClosureDigest
        d.actionId = readString(buf, pos)
        d.digest = readString(buf, pos)
        result.closureDigests.add(d)
      # Same strictness as the bundle: the block's own rules are checked
      # before the signature, so a malformed block is named as one.
      validateAttestations(result)
  let actionCountRaw = readU32LE(buf, pos)
  if not elementCountFits(actionCountRaw, buf.len - pos, 4):
    raise newException(DeployManifestCodecError, "element count exceeds remaining bytes")
  let actionCount = int(actionCountRaw)
  result.buildActions = newSeqOfCap[reproProfile.ProfileBuildAction](actionCount)
  for _ in 0 ..< actionCount:
    result.buildActions.add(decodeBuildAction(buf, pos))
  if result.formatVersion >= DeployManifestFormatVersionV2:
    let flag = readU8(buf, pos)
    if flag > 1'u8:
      raise newException(DeployManifestCodecError,
        "deploy manifest secrets-present flag is " & $flag & ", expected 0 or 1")
    result.hasSecrets = flag == 1'u8
    if not result.hasSecrets and
        result.formatVersion == DeployManifestFormatVersionV2:
      raise newException(DeployManifestCodecError,
        "non-canonical envelope: formatVersion 2 without a sealed section " &
        "(a producer must emit the lowest version that expresses its content)")
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

# ---------------------------------------------------------------------------
# Closure digests against the actions an apply realises (RDMF v3).
# ---------------------------------------------------------------------------

proc pinActionsToClosureDigests*(m: DeployManifest;
    actions: seq[reproProfile.ProfileBuildAction]):
    tuple[actions: seq[reproProfile.ProfileBuildAction]; refusal: string] =
  ## Bind every action an apply is about to realise to the output digest
  ## the signed manifest pins for it, so the substitute path refuses any
  ## other bytes before a single one is materialised
  ## (``expectedOutputDigest``; Deploy-Agent.md §"Version 3"). A manifest
  ## without the attestation block pins nothing and ``actions`` pass
  ## through unchanged. With the block:
  ##
  ## - an action the manifest pins no digest for is refused (the producer
  ##   did not vouch for its output);
  ## - an action whose own ``expectedOutputDigest`` differs from the pin is
  ##   refused (the profile and the signed manifest disagree about the
  ##   bytes, and neither is allowed to win silently);
  ## - a pin naming no action is refused (the producer pinned a closure the
  ##   target did not compile: a platform mismatch, Deploy-Agent.md
  ##   §"Field semantics").
  ##
  ## ``refusal`` is "" when every action is pinned.
  result.actions = actions
  if not m.hasAttestations: return
  var used: seq[string]
  for a in result.actions.mitems:
    let pin = m.closureDigestFor(a.id)
    if pin.len == 0:
      result.refusal = "the manifest pins no closure digest for build " &
        "action '" & a.id & "'"
      return
    if a.expectedOutputDigest.len > 0 and a.expectedOutputDigest != pin:
      result.refusal = "build action '" & a.id & "' pins " &
        a.expectedOutputDigest & " but the signed manifest pins " & pin
      return
    a.expectedOutputDigest = pin
    used.add(a.id)
  for d in m.closureDigests:
    if d.actionId notin used:
      result.refusal = "the manifest pins closure digest " & d.digest &
        " for build action '" & d.actionId & "', which this apply does " &
        "not realise"
      return

proc closureDigestRefusal*(m: DeployManifest; actionId, actual: string): string =
  ## Compare the digest an output actually has (``archiveDigestTag`` of its
  ## declared outputs, as staged) with the one the signed manifest pins.
  ## "" when they agree; otherwise why the output must not be moved into
  ## the store, linked or named in a unit. A manifest without the
  ## attestation block pins nothing and refuses nothing here (an agent
  ## that needs pins requires the block before it gets this far).
  if not m.hasAttestations: return ""
  let pin = m.closureDigestFor(actionId)
  if pin.len == 0:
    return "the manifest pins no closure digest for build action '" &
      actionId & "'"
  when agentMutated("rdmf-skips-closure-digest"):
    return ""
  if actual != pin:
    return "closure digest mismatch for build action '" & actionId &
      "': the signed manifest pins " & pin & ", the output is " &
      (if actual.len > 0: actual else: "absent or unhashable")
  ""
