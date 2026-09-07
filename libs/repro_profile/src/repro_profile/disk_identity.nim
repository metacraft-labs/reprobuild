## Deterministic identifiers for the filesystems and partition tables
## ``disk_apply`` creates.
##
## ## The problem this solves
##
## Every tool the apply driver shells out to invents an identifier when it
## is not given one, and it invents it from the clock plus randomness:
##
##   * ``mkfs.ext4`` seeds the filesystem UUID *and* the directory-hash
##     seed from ``time(0)`` + ``/dev/urandom``.
##   * ``mkswap`` seeds the swap UUID the same way.
##   * ``mkfs.vfat`` derives the FAT volume serial from the wall clock
##     (it honours ``SOURCE_DATE_EPOCH``, so it is the one identifier a
##     pinned epoch already covers — and only for as long as the caller
##     keeps pinning one).
##   * ``sgdisk`` draws the GPT disk GUID and every partition GUID from
##     the system RNG.
##
## An image built twice from identical inputs therefore differs in its
## bytes, which makes byte-for-byte comparison of two builds impossible
## and makes any hash taken over the resulting block device meaningless.
##
## ## The scheme
##
## Given one opaque ``seed`` and a stable ``purpose`` string naming *what*
## is being identified, this module derives an **RFC 4122 version 5**
## (name-based, SHA-1) UUID. Version 5 is used rather than an invented
## construction so that the derivation is a published algorithm anyone can
## re-implement and check: the digest is taken over the 16 namespace bytes
## followed by the name, the version nibble is set to 5, and the variant
## bits to ``0b10``.
##
## The purpose strings are built by the helpers below and are stable
## across runs, hosts and tool versions because they are made only of
## names the caller already declared — the disk's name in the layout, the
## partition's name, and which identifier of that node is wanted.
##
## The scheme is deliberately *not* keyed on anything the host contributes
## (no MAC address, no boot id, no time). Two hosts applying the same
## layout with the same seed produce the same identifiers; two different
## seeds produce unrelated ones.
##
## ## What a seed must and must not be
##
## A seed is an opaque, non-empty string. A caller that wants the
## "identical inputs produce identical images" property derives the seed
## from those inputs (a digest of the configuration and the package set,
## say). A caller installing onto a physical machine should NOT pin a
## seed: two machines installed from one image would then claim the same
## filesystem UUIDs, and ``root=UUID=`` stops naming one device. Pinned
## identifiers are a property of a reproducible *build*, not of a layout.
## That is why the seed is carried beside the layout document rather than
## inside it.
##
## ## No mocking
##
## Nothing here executes anything or reads any state; it is a pure
## function of its arguments.

import std/[json, os, sha1, strutils]

type
  DiskIdentity* = object
    ## The identity seed in force for one apply. The zero value carries
    ## an empty seed, which means "derive nothing" — every tool keeps its
    ## own default and the result is not reproducible.
    seed*: string

const
  DiskIdentityDocumentVersion* = 1
    ## Wire version of the sibling identity document. A document that
    ## declares a version this build does not know is rejected rather
    ## than half-understood.

  DiskIdentityNamespace*: array[16, byte] = [
    0x8a'u8, 0x30'u8, 0x4f'u8, 0x1d'u8, 0x1e'u8, 0xb7'u8, 0x4c'u8, 0x5e'u8,
    0x9a'u8, 0x6b'u8, 0x2f'u8, 0x0d'u8, 0xc3'u8, 0x71'u8, 0x55'u8, 0x02'u8,
  ]
    ## The RFC 4122 namespace UUID every derivation below is taken in:
    ## ``8a304f1d-1eb7-4c5e-9a6b-2f0dc3715502``. A constant, so that the
    ## same (seed, purpose) pair yields the same identifier in every
    ## build of every consumer. Changing it changes every identifier
    ## every consumer has ever derived, which is why it is spelled out
    ## here rather than computed.

proc isPinned*(identity: DiskIdentity): bool {.inline.} =
  ## True when this apply has a seed and will therefore pin identifiers.
  identity.seed.len > 0

# ---------------------------------------------------------------------
# Purpose strings — the stable names the derivation is keyed on.
#
# They are built here, in one place, because a purpose string IS part of
# the derivation: changing one silently changes the identifier it names.
# ---------------------------------------------------------------------

proc diskGuidPurpose*(diskName: string): string =
  ## The GPT disk GUID of the named disk in the layout.
  "gpt/" & diskName & "/disk-guid"

proc partitionGuidPurpose*(diskName, partitionName: string): string =
  ## The unique GPT GUID of one partition.
  "gpt/" & diskName & "/" & partitionName & "/partition-guid"

proc filesystemUuidPurpose*(nodeKey: string): string =
  ## The filesystem UUID of a content node. ``nodeKey`` is the apply
  ## driver's own path to that node (``main.root``, ``main.luks.inner``),
  ## so nested content under LUKS or LVM gets its own identifier without
  ## this module having to know the nesting rules.
  "fs/" & nodeKey & "/uuid"

proc filesystemHashSeedPurpose*(nodeKey: string): string =
  ## The ext4 directory-hash seed. Distinct from the filesystem UUID:
  ## ``mke2fs`` defaults it to a *separate* random value, so pinning only
  ## the UUID leaves the image non-reproducible.
  "fs/" & nodeKey & "/hash-seed"

proc filesystemVolumeIdPurpose*(nodeKey: string): string =
  ## The 32-bit FAT volume serial.
  "fs/" & nodeKey & "/volume-id"

# ---------------------------------------------------------------------
# Derivation.
# ---------------------------------------------------------------------

proc identityDigest(seed, purpose: string): Sha1Digest =
  ## SHA-1 over the namespace bytes followed by the name, per RFC 4122
  ## §4.3. The name is ``<seed>\n<purpose>`` — a separator that cannot
  ## occur in a purpose string, so no two distinct pairs share a name.
  var name = newStringOfCap(16 + seed.len + 1 + purpose.len)
  for b in DiskIdentityNamespace:
    name.add char(b)
  name.add seed
  name.add '\n'
  name.add purpose
  Sha1Digest(secureHash(name))

proc formatUuid(d: Sha1Digest): string =
  var b: array[16, byte]
  for i in 0 ..< 16:
    b[i] = byte(d[i])
  # RFC 4122: version 5 in the high nibble of octet 6, variant 0b10 in
  # the top bits of octet 8.
  b[6] = (b[6] and 0x0F'u8) or 0x50'u8
  b[8] = (b[8] and 0x3F'u8) or 0x80'u8
  var hex = newStringOfCap(32)
  for x in b:
    hex.add toHex(int(x), 2).toLowerAscii()
  hex[0 ..< 8] & "-" & hex[8 ..< 12] & "-" & hex[12 ..< 16] & "-" &
    hex[16 ..< 20] & "-" & hex[20 ..< 32]

proc deriveUuid*(identity: DiskIdentity; purpose: string): string =
  ## The RFC 4122 v5 UUID for ``purpose`` under this identity's seed, in
  ## the lower-case ``8-4-4-4-12`` form every one of the tools accepts.
  ## Returns "" when the identity carries no seed, which is how every
  ## call site spells "leave the tool's own default alone".
  if not identity.isPinned:
    return ""
  formatUuid(identityDigest(identity.seed, purpose))

proc deriveVolumeId*(identity: DiskIdentity; purpose: string): string =
  ## The 32-bit FAT volume serial for ``purpose``, as the eight upper-case
  ## hex digits ``mkfs.vfat -i`` expects. ``00000000`` is remapped,
  ## because some tools read an all-zero serial as "absent".
  if not identity.isPinned:
    return ""
  let d = identityDigest(identity.seed, purpose)
  var value = 0'u32
  for i in 0 ..< 4:
    value = (value shl 8) or uint32(byte(d[i]))
  if value == 0'u32:
    value = 1'u32
  toHex(int64(value), 8).toUpperAscii()

# ---------------------------------------------------------------------
# The sibling identity document.
#
# The seed rides beside the layout document rather than inside it, for
# the reason given in the module header: the layout describes a disk
# shape that many machines may legitimately share, while pinned
# identifiers are a property of one reproducible build of one image.
# Keeping them apart also means a consumer that has no use for pinning
# is not handed a document full of UUIDs it must ignore.
# ---------------------------------------------------------------------

proc diskIdentitySiblingPath*(layoutPath: string): string =
  ## Where ``repro disk apply <layoutPath>`` looks for the identity
  ## document when it was not told explicitly: the layout's path with its
  ## extension replaced by ``.identity.json``. So ``…/disko.json`` pairs
  ## with ``…/disko.identity.json``.
  ##
  ## Convention rather than a flag on purpose. An identifier pin that has
  ## to be remembered and forwarded at every call site is one that will
  ## eventually not be, and the failure is silent — the apply succeeds and
  ## the image is merely irreproducible.
  let (dir, name, _) = splitFile(layoutPath)
  dir / name & ".identity.json"

proc renderDiskIdentityDocument*(identity: DiskIdentity): string =
  ## The exact bytes of an identity document. Hand-rendered so the byte
  ## layout does not move with the Nim version — producers of this file
  ## are compared byte for byte by their own gates.
  "{\n" &
  "  \"version\": " & $DiskIdentityDocumentVersion & ",\n" &
  "  \"seed\": " & escapeJson(identity.seed) & "\n" &
  "}\n"

proc parseDiskIdentityDocument*(text, source: string): DiskIdentity =
  ## Parse an identity document. Raises ``ValueError`` with an
  ## operator-readable reason for anything it cannot honour — an
  ## identity document that is present but unusable must stop the apply,
  ## not be skipped past.
  var doc: JsonNode
  try:
    doc = parseJson(text)
  except CatchableError as e:
    raise newException(ValueError,
      source & ": not valid JSON: " & e.msg)
  if doc.kind != JObject:
    raise newException(ValueError,
      source & ": expected a JSON object, got " & $doc.kind)
  if not doc.hasKey("version"):
    raise newException(ValueError,
      source & ": no \"version\" field; expected " &
      $DiskIdentityDocumentVersion)
  if doc["version"].kind != JInt or
     doc["version"].getInt() != DiskIdentityDocumentVersion:
    raise newException(ValueError,
      source & ": unsupported identity-document version " &
      $doc["version"] & "; this build understands " &
      $DiskIdentityDocumentVersion)
  if not doc.hasKey("seed") or doc["seed"].kind != JString:
    raise newException(ValueError,
      source & ": no \"seed\" string field")
  let seed = doc["seed"].getStr()
  if seed.len == 0:
    raise newException(ValueError,
      source & ": \"seed\" is empty; omit the document entirely if the " &
      "identifiers are meant to be left unpinned")
  DiskIdentity(seed: seed)
