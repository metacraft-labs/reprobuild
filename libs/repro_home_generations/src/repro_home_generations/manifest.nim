## Activation manifest writer/reader (M62 —
## Home-Profile-Generations-And-State.md "Activation Manifest").
##
## The activation manifest is the per-generation "what we did" record
## that drives rollback and the next transition's plan. It is binary,
## content-addressed in the local CAS, and referenced from the pointer
## envelope by `activationManifestDigest`.
##
## Two generations whose intent produces a byte-identical plan share
## one CAS blob (gate 2 pins this).
##
## Binary on-disk shape (little-endian throughout):
##
##   offset 0   :  magic                       4 bytes ASCII "RBAM"
##                 ("Reprobuild Activation Manifest")
##   offset 4   :  schemaVersion               u16 LE
##   offset 6   :  bodyLength                  u32 LE
##   offset 10  :  body                        bodyLength bytes
##   trailing   :  trailingChecksum            32 bytes BLAKE3-256
##
## Body field order (per spec, audited record types):
##
##   1. realizedPackages    u32 LE count + count*RealizedPackage records
##   2. exportedCommands    u32 LE count + count*ExportedCommand records
##   3. generatedFiles      u32 LE count + count*GeneratedFile records
##   4. managedBlocks       u32 LE count + count*ManagedBlock records
##   5. resourceBindings    u32 LE count + count*ResourceBinding records
##
## Each record is a sequence of length-prefixed strings and fixed-size
## fields documented inline below. The "ResourceBinding" record is
## defined here at M62 but expected to be empty until M68 wires up the
## resource lifecycle layer — the on-disk count is just `0` in M62
## fixtures.

import blake3
import repro_core

import ./errors
import ./pointer

const
  ManifestMagic* = "RBAM"
  ManifestSchemaVersion*: uint16 = 1
  ManifestHeaderSize = 4 + 2 + 4
  ManifestTrailerSize = 32

type
  RealizedPackage* = object
    ## See "Activation Manifest -> RealizedPackage" in the spec. Cited
    ## consumers: rollback re-realization, `repro home why <pkg>`.
    packageId*: string
    realizedPrefixId*: Digest256
    adapter*: string
    provenance*: seq[byte]
      ## Adapter-specific bytes needed to re-acquire on rollback.

  ExportedCommand* = object
    ## See "Activation Manifest -> ExportedCommand" in the spec.
    commandName*: string
    launchPlanDigest*: Digest256
      ## CAS digest of the launch plan, per Launch-Plans-And-Platform-
      ## Launchers.md "Materialization Into Home Profile Bin Dirs".
    binDirRelativePath*: string
    binDirArtifactKind*: string
      ## "symlink" | "launcher-script" | "windows-launcher"

  GeneratedFileOwnership* = enum
    ## Spec-mandated set. Stow modes are documented in
    ## Home-Profile-Intent-Layer.md "Stow-Style Dotfile Support".
    gfoOwned = "owned"
    gfoMerged = "merged"
    gfoExistingPreserved = "existing-preserved"
    gfoStowSymlink = "stow-symlink"
    gfoStowJunction = "stow-junction"
    gfoStowCopy = "stow-copy"

  GeneratedFile* = object
    absoluteOutputPath*: string
    storeContentHash*: Digest256
    ownershipPolicy*: GeneratedFileOwnership
    preWriteDigest*: Digest256
    hasPreWriteDigest*: bool
    postWriteDigest*: Digest256
    stowSource*: string
      ## "" if not a stow file.

  ManagedBlock* = object
    hostFilePath*: string
    blockId*: string
    preWriteFileDigest*: Digest256
    postWriteBlockBytes*: seq[byte]
    postWriteFileDigest*: Digest256

  ResourceBinding* = object
    ## Reserved for M68. M62 fixtures always serialize an empty list.
    resourceAddress*: string
    providerIdentity*: string
    realWorldIdentity*: string
    recordedAttributes*: seq[byte]
    lifecyclePolicy*: string

  ActivationManifest* = object
    schemaVersion*: uint16
    realizedPackages*: seq[RealizedPackage]
    exportedCommands*: seq[ExportedCommand]
    generatedFiles*: seq[GeneratedFile]
    managedBlocks*: seq[ManagedBlock]
    resourceBindings*: seq[ResourceBinding]

# ---------------------------------------------------------------------------
# Encoder helpers
# ---------------------------------------------------------------------------

proc writeBytes(outp: var seq[byte]; data: openArray[byte]) =
  for b in data: outp.add(b)

proc writeBlob(outp: var seq[byte]; data: openArray[byte]) =
  outp.writeU32Le(uint32(data.len))
  for b in data: outp.add(b)

proc writeDigest(outp: var seq[byte]; digest: Digest256) =
  for b in digest: outp.add(b)

proc writeRealizedPackage(outp: var seq[byte]; rec: RealizedPackage) =
  outp.writeString(rec.packageId)
  outp.writeDigest(rec.realizedPrefixId)
  outp.writeString(rec.adapter)
  outp.writeBlob(rec.provenance)

proc writeExportedCommand(outp: var seq[byte]; rec: ExportedCommand) =
  outp.writeString(rec.commandName)
  outp.writeDigest(rec.launchPlanDigest)
  outp.writeString(rec.binDirRelativePath)
  outp.writeString(rec.binDirArtifactKind)

proc writeGeneratedFile(outp: var seq[byte]; rec: GeneratedFile) =
  outp.writeString(rec.absoluteOutputPath)
  outp.writeDigest(rec.storeContentHash)
  outp.writeString($rec.ownershipPolicy)
  outp.add(if rec.hasPreWriteDigest: 1'u8 else: 0'u8)
  if rec.hasPreWriteDigest:
    outp.writeDigest(rec.preWriteDigest)
  outp.writeDigest(rec.postWriteDigest)
  outp.writeString(rec.stowSource)

proc writeManagedBlock(outp: var seq[byte]; rec: ManagedBlock) =
  outp.writeString(rec.hostFilePath)
  outp.writeString(rec.blockId)
  outp.writeDigest(rec.preWriteFileDigest)
  outp.writeBlob(rec.postWriteBlockBytes)
  outp.writeDigest(rec.postWriteFileDigest)

proc writeResourceBinding(outp: var seq[byte]; rec: ResourceBinding) =
  outp.writeString(rec.resourceAddress)
  outp.writeString(rec.providerIdentity)
  outp.writeString(rec.realWorldIdentity)
  outp.writeBlob(rec.recordedAttributes)
  outp.writeString(rec.lifecyclePolicy)

proc encodeBody(manifest: ActivationManifest): seq[byte] =
  result.writeU32Le(uint32(manifest.realizedPackages.len))
  for rec in manifest.realizedPackages:
    result.writeRealizedPackage(rec)
  result.writeU32Le(uint32(manifest.exportedCommands.len))
  for rec in manifest.exportedCommands:
    result.writeExportedCommand(rec)
  result.writeU32Le(uint32(manifest.generatedFiles.len))
  for rec in manifest.generatedFiles:
    result.writeGeneratedFile(rec)
  result.writeU32Le(uint32(manifest.managedBlocks.len))
  for rec in manifest.managedBlocks:
    result.writeManagedBlock(rec)
  result.writeU32Le(uint32(manifest.resourceBindings.len))
  for rec in manifest.resourceBindings:
    result.writeResourceBinding(rec)

proc encodeManifest*(manifest: ActivationManifest): seq[byte] =
  ## Serialize the manifest to bytes with the envelope shape documented
  ## above. The bytes are deterministic: two identical inputs always
  ## produce identical bytes, so the CAS-dedup invariant (gate 2)
  ## holds.
  let body = encodeBody(manifest)
  let bodyLen = uint32(body.len)
  result = newSeqOfCap[byte](
    ManifestHeaderSize + body.len + ManifestTrailerSize)
  for ch in ManifestMagic:
    result.add(byte(ord(ch)))
  result.writeU16Le(ManifestSchemaVersion)
  result.writeU32Le(bodyLen)
  result.writeBytes(body)
  let checksum = blake3.digest(result)
  result.writeBytes(checksum)

proc manifestDigest*(manifest: ActivationManifest): Digest256 =
  ## BLAKE3-256 over the canonical encoded bytes — equals the CAS key
  ## used to store the blob.
  blake3.digest(encodeManifest(manifest))

# ---------------------------------------------------------------------------
# Decoder helpers
# ---------------------------------------------------------------------------

proc readDigest(buf: openArray[byte]; pos: var int;
                filePath, field: string): Digest256 =
  if pos + 32 > buf.len:
    raiseManifestCorrupt(filePath, field, "truncated digest")
  for i in 0 ..< 32:
    result[i] = buf[pos + i]
  pos += 32

proc readBlob(buf: openArray[byte]; pos: var int;
              filePath, field: string): seq[byte] =
  let n = int(readU32Le(buf, pos))
  if pos + n > buf.len:
    raiseManifestCorrupt(filePath, field, "truncated blob")
  result = newSeq[byte](n)
  for i in 0 ..< n:
    result[i] = buf[pos + i]
  pos += n

proc parseOwnership(text: string; filePath, field: string): GeneratedFileOwnership =
  case text
  of $gfoOwned: gfoOwned
  of $gfoMerged: gfoMerged
  of $gfoExistingPreserved: gfoExistingPreserved
  of $gfoStowSymlink: gfoStowSymlink
  of $gfoStowJunction: gfoStowJunction
  of $gfoStowCopy: gfoStowCopy
  else:
    raiseManifestCorrupt(filePath, field,
      "unknown ownership policy: " & text)

proc decodeManifestBytes*(bytes: openArray[byte];
                         filePath = "<memory>"): ActivationManifest =
  ## Strict decoder: validates magic, schema version, body-length
  ## bounds, trailing checksum. Raises `EManifestCorrupt` on any
  ## structural inconsistency.
  if bytes.len < ManifestHeaderSize + ManifestTrailerSize:
    raiseManifestCorrupt(filePath, "envelope",
      "file is too short to be an activation manifest")
  for i in 0 ..< 4:
    if bytes[i] != byte(ord(ManifestMagic[i])):
      raiseManifestCorrupt(filePath, "magic",
        "expected '" & ManifestMagic & "' magic")
  var pos = 4
  let version = readU16Le(bytes, pos)
  if version != ManifestSchemaVersion:
    raiseManifestCorrupt(filePath, "schemaVersion",
      "unsupported manifest schema version " & $version)
  let bodyLen = int(readU32Le(bytes, pos))
  if pos + bodyLen + ManifestTrailerSize != bytes.len:
    raiseManifestCorrupt(filePath, "bodyLength",
      "declared body length disagrees with file size")
  let bodyEnd = pos + bodyLen
  var prefix = newSeqOfCap[byte](bodyEnd)
  for i in 0 ..< bodyEnd:
    prefix.add(bytes[i])
  let expected = blake3.digest(prefix)
  for i in 0 ..< 32:
    if bytes[bodyEnd + i] != expected[i]:
      raiseManifestCorrupt(filePath, "trailingChecksum",
        "BLAKE3-256 trailing checksum mismatch")
  result.schemaVersion = version
  let rpCount = int(readU32Le(bytes, pos))
  result.realizedPackages = newSeq[RealizedPackage](rpCount)
  for i in 0 ..< rpCount:
    var rec: RealizedPackage
    rec.packageId = readString(bytes, pos)
    rec.realizedPrefixId = readDigest(bytes, pos, filePath,
      "realizedPackages[" & $i & "].realizedPrefixId")
    rec.adapter = readString(bytes, pos)
    rec.provenance = readBlob(bytes, pos, filePath,
      "realizedPackages[" & $i & "].provenance")
    result.realizedPackages[i] = rec
  let ecCount = int(readU32Le(bytes, pos))
  result.exportedCommands = newSeq[ExportedCommand](ecCount)
  for i in 0 ..< ecCount:
    var rec: ExportedCommand
    rec.commandName = readString(bytes, pos)
    rec.launchPlanDigest = readDigest(bytes, pos, filePath,
      "exportedCommands[" & $i & "].launchPlanDigest")
    rec.binDirRelativePath = readString(bytes, pos)
    rec.binDirArtifactKind = readString(bytes, pos)
    result.exportedCommands[i] = rec
  let gfCount = int(readU32Le(bytes, pos))
  result.generatedFiles = newSeq[GeneratedFile](gfCount)
  for i in 0 ..< gfCount:
    var rec: GeneratedFile
    rec.absoluteOutputPath = readString(bytes, pos)
    rec.storeContentHash = readDigest(bytes, pos, filePath,
      "generatedFiles[" & $i & "].storeContentHash")
    let policyStr = readString(bytes, pos)
    rec.ownershipPolicy = parseOwnership(policyStr, filePath,
      "generatedFiles[" & $i & "].ownershipPolicy")
    if pos >= bytes.len:
      raiseManifestCorrupt(filePath,
        "generatedFiles[" & $i & "].hasPreWriteDigest", "truncated bool")
    let hasPre = bytes[pos]; inc pos
    rec.hasPreWriteDigest = hasPre == 1
    if rec.hasPreWriteDigest:
      rec.preWriteDigest = readDigest(bytes, pos, filePath,
        "generatedFiles[" & $i & "].preWriteDigest")
    rec.postWriteDigest = readDigest(bytes, pos, filePath,
      "generatedFiles[" & $i & "].postWriteDigest")
    rec.stowSource = readString(bytes, pos)
    result.generatedFiles[i] = rec
  let mbCount = int(readU32Le(bytes, pos))
  result.managedBlocks = newSeq[ManagedBlock](mbCount)
  for i in 0 ..< mbCount:
    var rec: ManagedBlock
    rec.hostFilePath = readString(bytes, pos)
    rec.blockId = readString(bytes, pos)
    rec.preWriteFileDigest = readDigest(bytes, pos, filePath,
      "managedBlocks[" & $i & "].preWriteFileDigest")
    rec.postWriteBlockBytes = readBlob(bytes, pos, filePath,
      "managedBlocks[" & $i & "].postWriteBlockBytes")
    rec.postWriteFileDigest = readDigest(bytes, pos, filePath,
      "managedBlocks[" & $i & "].postWriteFileDigest")
    result.managedBlocks[i] = rec
  let rbCount = int(readU32Le(bytes, pos))
  result.resourceBindings = newSeq[ResourceBinding](rbCount)
  for i in 0 ..< rbCount:
    var rec: ResourceBinding
    rec.resourceAddress = readString(bytes, pos)
    rec.providerIdentity = readString(bytes, pos)
    rec.realWorldIdentity = readString(bytes, pos)
    rec.recordedAttributes = readBlob(bytes, pos, filePath,
      "resourceBindings[" & $i & "].recordedAttributes")
    rec.lifecyclePolicy = readString(bytes, pos)
    result.resourceBindings[i] = rec
  if pos != bodyEnd:
    raiseManifestCorrupt(filePath, "body",
      "trailing " & $(bodyEnd - pos) & " bytes after audited record set")
