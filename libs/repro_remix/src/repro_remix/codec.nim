## Canonical codec for Remix manifests and envelopes.
##
## Normative source: `reprobuild-pm/spec/Remix-Protocol.md` §"Manifest",
## §"Canonical form" and §"Parser bounds".
##
## The codec has one rule that does most of the work: after decoding, it
## re-encodes what it decoded and refuses unless the bytes are identical
## (§"Canonical form"). SSZ itself rejects trailing bytes and bad offsets;
## the re-encode check then rejects every other variant that would decode
## to the same value. Ordering, duplicates and vocabularies are checked
## explicitly so a refusal names its reason.
##
## Text rules. Identifier fields are restricted to printable ASCII so the
## same identifier cannot be spelled with two byte strings (no Unicode
## normalization is needed or performed). Free text (`intent`) must be
## valid UTF-8 without control characters other than newline and tab; it
## is hashed as the author wrote it.

import std/[algorithm, strutils, unicode]

import ssz_serialization

import ./types
import ./wire

const
  FrameMagic = [byte(ord('R')), byte(ord('B')), byte(ord('S')), byte(ord('Z'))]
    ## The shared RBSZ framing of `repro_domain_types/codec.nim`.
  FrameVersion = 1'u16
  FrameHeaderLen = 12
  MaxFrameBytes = MaxBodyBytes + 64 * 1024
    ## Body bound plus a generous allowance for 16 signatures and SSZ
    ## offsets; checked before the wrapper is decoded.
  MaxHealthTimeoutSeconds = 3600'u32
  MaxPatchStrip = 16'u8
  KnownExtensions: array[0, string] = []
    ## v1 defines no extensions, so every critical extension refuses.

# ---------------------------------------------------------------------------
# Byte and list helpers.
# ---------------------------------------------------------------------------

proc toBytes(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  for i, c in s:
    result[i] = byte(ord(c))

proc toStr(b: openArray[byte]): string =
  result = newString(b.len)
  for i, x in b:
    result[i] = char(x)

proc cmpBytes(a, b: openArray[byte]): int =
  let n = min(a.len, b.len)
  for i in 0 ..< n:
    if a[i] != b[i]:
      return (if a[i] < b[i]: -1 else: 1)
  cmp(a.len, b.len)

template toL(s: untyped; L: typedesc; field: string): untyped =
  ## Convert to a bounded SSZ list, refusing (not truncating) past the
  ## bound. A template because generic inference does not see through
  ## the `SszName`-style aliases.
  block:
    let tmp = s
    if tmp.len > int(L.maxLen):
      refuse(rrBound, field & " has " & $tmp.len & " entries, bound " & $L.maxLen)
    L.init(tmp)

template textL(s: string; L: typedesc; field: string): untyped =
  toL(toBytes(s), L, field)

proc requireStrictlyAscending[T](items: seq[T]; key: proc (x: T): seq[byte];
                                 field: string) =
  ## Shared check for every sorted list: strictly ascending by `key`, so
  ## an equal neighbour is a duplicate and a smaller one is misordering.
  for i in 1 ..< items.len:
    let c = cmpBytes(key(items[i - 1]), key(items[i]))
    if c == 0:
      refuse(rrDuplicate, field & " entry " & $i & " duplicates its predecessor")
    if c > 0:
      refuse(rrUnsorted, field & " entry " & $i & " is out of canonical order")

# ---------------------------------------------------------------------------
# Text validation.
# ---------------------------------------------------------------------------

proc checkIdent(s, field: string; allowEmpty = false) =
  ## Printable ASCII without spaces.
  if s.len == 0:
    if allowEmpty: return
    refuse(rrInvalidText, field & " is empty")
  for c in s:
    if ord(c) < 0x21 or ord(c) > 0x7e:
      refuse(rrInvalidText, field & " contains a byte outside printable ASCII")

proc checkSpacedAscii(s, field: string) =
  ## Printable ASCII with single interior spaces (SPDX expressions,
  ## version ranges): no leading, trailing or doubled space, so a value
  ## has one spelling.
  if s.len == 0:
    refuse(rrInvalidText, field & " is empty")
  if s[0] == ' ' or s[^1] == ' ':
    refuse(rrInvalidText, field & " has leading or trailing space")
  for i, c in s:
    if ord(c) < 0x20 or ord(c) > 0x7e:
      refuse(rrInvalidText, field & " contains a byte outside printable ASCII")
    if c == ' ' and i > 0 and s[i - 1] == ' ':
      refuse(rrInvalidText, field & " contains a doubled space")

proc checkFreeText(s, field: string) =
  if s.len == 0:
    refuse(rrInvalidText, field & " is empty")
  if validateUtf8(s) != -1:
    refuse(rrInvalidText, field & " is not valid UTF-8")
  for r in s.runes:
    let v = int32(r)
    if (v < 0x20 and v != 0x0a and v != 0x09) or v == 0x7f or
       (v >= 0x80 and v < 0xa0):
      refuse(rrInvalidText, field & " contains a control character")

proc isLowerHex(s: string): bool =
  for c in s:
    if c notin {'0'..'9', 'a'..'f'}:
      return false
  true

proc checkRevision(s, field: string) =
  ## Full-width object id: 40 (SHA-1) or 64 (SHA-256) lowercase hex.
  if s.len notin [40, 64] or not isLowerHex(s):
    refuse(rrInvalidText, field & " is not a full-width lowercase object id")

proc checkDigestText(s, field: string) =
  ## Self-describing `<alg>:<hex>` with a registered algorithm
  ## (Workspace-Manifests.md §"Self-describing integrity (multihash)").
  let colon = s.find(':')
  if colon <= 0:
    refuse(rrInvalidText, field & " is not <alg>:<hex>")
  let alg = s[0 ..< colon]
  let hex = s[colon + 1 .. ^1]
  let width =
    case alg
    of "git-sha1": 40
    of "git-sha256", "blake3": 64
    else: refuse(rrUnknownVocabulary, field & " names unknown digest algorithm " & alg)
  if hex.len != width or not isLowerHex(hex):
    refuse(rrInvalidText, field & " digest has the wrong width or case")

proc checkRemixName(s: string) =
  ## `<namespace>/<slug>`, each `[a-z0-9][a-z0-9._-]*`.
  let slash = s.find('/')
  if slash <= 0 or slash == s.len - 1 or s.find('/', slash + 1) >= 0:
    refuse(rrInvalidText, "remixName is not <namespace>/<slug>")
  for part in [s[0 ..< slash], s[slash + 1 .. ^1]]:
    if part[0] notin {'a'..'z', '0'..'9'}:
      refuse(rrInvalidText, "remixName part must start with [a-z0-9]")
    for c in part:
      if c notin {'a'..'z', '0'..'9', '.', '_', '-'}:
        refuse(rrInvalidText, "remixName contains a character outside [a-z0-9._-]")

# ---------------------------------------------------------------------------
# Vocabulary decoding: an unknown tag is a refusal, never a crash.
# ---------------------------------------------------------------------------

proc enumFrom[E: enum](v: uint8; _: typedesc[E]; field: string): E =
  for e in E:
    if uint8(ord(e)) == v:
      return e
  refuse(rrUnknownVocabulary, field & " has unknown value " & $v)

# ---------------------------------------------------------------------------
# Domain <-> wire.
# ---------------------------------------------------------------------------

proc toW(o: OriginalRef): OriginalRefW =
  OriginalRefW(
    package: textL(o.package, SszName, "package"),
    interfaceFingerprint: o.interfaceFingerprint,
    catalogWorkspace: textL(o.catalogWorkspace, SszName, "catalogWorkspace"),
    catalogRemote: textL(o.catalogRemote, SszText, "catalogRemote"),
    catalogRevision: textL(o.catalogRevision, SszRevision, "catalogRevision"),
    catalogInterfaceArtifact: o.catalogInterfaceArtifact)

proc fromW(w: OriginalRefW): OriginalRef =
  OriginalRef(
    package: toStr(asSeq(w.package)),
    interfaceFingerprint: w.interfaceFingerprint,
    catalogWorkspace: toStr(asSeq(w.catalogWorkspace)),
    catalogRemote: toStr(asSeq(w.catalogRemote)),
    catalogRevision: toStr(asSeq(w.catalogRevision)),
    catalogInterfaceArtifact: w.catalogInterfaceArtifact)

proc toW(b: BlobRef): BlobRefW =
  BlobRefW(id: b.id, mediaType: textL(b.mediaType, SszName, "mediaType"),
           size: b.size)

proc fromW(w: BlobRefW): BlobRef =
  BlobRef(id: w.id, mediaType: toStr(asSeq(w.mediaType)), size: w.size)

proc mapW[A, B](xs: seq[A]; f: proc (x: A): B): seq[B] =
  result = newSeqOfCap[B](xs.len)
  for x in xs:
    result.add f(x)

proc toWire*(m: Manifest): ManifestW =
  ## Convert without validating; `encodeManifest` validates first.
  result.remixName = textL(m.remixName, SszName, "remixName")
  result.version = textL(m.version, SszName, "version")
  result.intent = textL(m.intent, SszIntent, "intent")
  result.license = textL(m.license, SszName, "license")
  result.targets = toL(mapW(m.targets, proc (t: Target): TargetW =
    TargetW(original: toW(t.original), constraintKind: uint8(ord(t.constraintKind)),
            constraint: textL(t.constraint, SszName, "constraint"))),
    List[TargetW, MaxEntries], "targets")
  result.platforms = toL(mapW(m.platforms, proc (p: string): SszName =
    textL(p, SszName, "platform")), List[SszName, MaxPlatforms], "platforms")
  result.parents = toL(m.parents, List[Digest32, MaxParents], "parents")
  result.sources = toL(mapW(m.sources, proc (s: SourceTree): SourceTreeW =
    SourceTreeW(repo: textL(s.repo, SszName, "repo"),
                remote: textL(s.remote, SszText, "remote"),
                revision: textL(s.revision, SszRevision, "revision"),
                digest: textL(s.digest, SszDigestText, "digest"))),
    List[SourceTreeW, MaxEntries], "sources")
  result.patches = toL(mapW(m.patches, proc (p: Patch): PatchW =
    PatchW(appliesToKind: uint8(ord(p.appliesToKind)),
           appliesToIndex: p.appliesToIndex, blob: toW(p.blob),
           strip: p.strip, order: p.order)),
    List[PatchW, MaxEntries], "patches")
  result.graphFragments = toL(mapW(m.graphFragments, toW),
    List[BlobRefW, MaxEntries], "graphFragments")
  result.configuration = toL(mapW(m.configuration,
    proc (c: ConfigContribution): ConfigContributionW =
      ConfigContributionW(configurable: textL(c.configurable, SszName, "configurable"),
        schemaFingerprint: c.schemaFingerprint,
        priority: uint8(ord(c.priority)), operation: uint8(ord(c.operation)),
        value: toW(c.value))),
    List[ConfigContributionW, MaxEntries], "configuration")
  result.exposedConfigurables = toL(mapW(m.exposedConfigurables,
    proc (e: ExposedConfigurable): ExposedConfigurableW =
      ExposedConfigurableW(name: textL(e.name, SszName, "exposedConfigurable"),
                           schemaFingerprint: e.schemaFingerprint)),
    List[ExposedConfigurableW, MaxSmallLists], "exposedConfigurables")
  result.tests = toL(mapW(m.tests, proc (t: TestRef): TestRefW =
    TestRefW(name: textL(t.name, SszName, "test"), fragment: t.fragment)),
    List[TestRefW, MaxEntries], "tests")
  result.healthChecks = toL(mapW(m.healthChecks, proc (h: HealthCheck): HealthCheckW =
    HealthCheckW(kind: uint8(ord(h.kind)), target: textL(h.target, SszText, "healthCheck"),
                 timeoutSeconds: h.timeoutSeconds)),
    List[HealthCheckW, MaxSmallLists], "healthChecks")
  result.assets = toL(mapW(m.assets, toW), List[BlobRefW, MaxSmallLists], "assets")
  result.permissions = toL(mapW(m.permissions, proc (p: Permission): PermissionW =
    PermissionW(kind: uint8(ord(p.kind)), scope: textL(p.scope, SszName, "scope"))),
    List[PermissionW, MaxSmallLists], "permissions")
  result.dataMigrations = toL(mapW(m.dataMigrations, proc (d: DataMigration): DataMigrationW =
    DataMigrationW(store: textL(d.store, SszName, "store"), kind: uint8(ord(d.kind)),
                   edge: textL(d.edge, SszName, "edge"))),
    List[DataMigrationW, MaxDataMigrations], "dataMigrations")
  result.dependenciesAdded = toL(mapW(m.dependenciesAdded, toW),
    List[OriginalRefW, MaxEntries], "dependenciesAdded")
  result.authors = toL(m.authors, List[Digest32, MaxSignatures], "authors")
  result.extensions = toL(mapW(m.extensions, proc (e: Extension): ExtensionW =
    ExtensionW(id: textL(e.id, SszName, "extension"), critical: e.critical,
               payload: toL(e.payload, List[byte, MaxExtensionBytes], "extension payload"))),
    List[ExtensionW, MaxExtensions], "extensions")

proc fromWire*(w: ManifestW): Manifest =
  ## Convert a decoded wire value, refusing unknown vocabulary tags.
  result.remixName = toStr(asSeq(w.remixName))
  result.version = toStr(asSeq(w.version))
  result.intent = toStr(asSeq(w.intent))
  result.license = toStr(asSeq(w.license))
  for t in asSeq(w.targets):
    result.targets.add Target(original: fromW(t.original),
      constraintKind: enumFrom(t.constraintKind, ConstraintKind, "constraintKind"),
      constraint: toStr(asSeq(t.constraint)))
  for p in asSeq(w.platforms):
    result.platforms.add toStr(asSeq(p))
  result.parents = asSeq(w.parents)
  for s in asSeq(w.sources):
    result.sources.add SourceTree(repo: toStr(asSeq(s.repo)),
      remote: toStr(asSeq(s.remote)), revision: toStr(asSeq(s.revision)),
      digest: toStr(asSeq(s.digest)))
  for p in asSeq(w.patches):
    result.patches.add Patch(
      appliesToKind: enumFrom(p.appliesToKind, PatchTargetKind, "patch appliesToKind"),
      appliesToIndex: p.appliesToIndex, blob: fromW(p.blob), strip: p.strip,
      order: p.order)
  for b in asSeq(w.graphFragments):
    result.graphFragments.add fromW(b)
  for c in asSeq(w.configuration):
    result.configuration.add ConfigContribution(
      configurable: toStr(asSeq(c.configurable)),
      schemaFingerprint: c.schemaFingerprint,
      priority: enumFrom(c.priority, ConfigPriority, "configuration priority"),
      operation: enumFrom(c.operation, ConfigOperation, "configuration operation"),
      value: fromW(c.value))
  for e in asSeq(w.exposedConfigurables):
    result.exposedConfigurables.add ExposedConfigurable(
      name: toStr(asSeq(e.name)), schemaFingerprint: e.schemaFingerprint)
  for t in asSeq(w.tests):
    result.tests.add TestRef(name: toStr(asSeq(t.name)), fragment: t.fragment)
  for h in asSeq(w.healthChecks):
    result.healthChecks.add HealthCheck(
      kind: enumFrom(h.kind, HealthCheckKind, "healthCheck kind"),
      target: toStr(asSeq(h.target)), timeoutSeconds: h.timeoutSeconds)
  for b in asSeq(w.assets):
    result.assets.add fromW(b)
  for p in asSeq(w.permissions):
    result.permissions.add Permission(
      kind: enumFrom(p.kind, PermissionKind, "permission kind"),
      scope: toStr(asSeq(p.scope)))
  for d in asSeq(w.dataMigrations):
    result.dataMigrations.add DataMigration(store: toStr(asSeq(d.store)),
      kind: enumFrom(d.kind, MigrationKind, "dataMigration kind"),
      edge: toStr(asSeq(d.edge)))
  for o in asSeq(w.dependenciesAdded):
    result.dependenciesAdded.add fromW(o)
  result.authors = asSeq(w.authors)
  for e in asSeq(w.extensions):
    result.extensions.add Extension(id: toStr(asSeq(e.id)), critical: e.critical,
                                    payload: asSeq(e.payload))

# ---------------------------------------------------------------------------
# Semantic validation (§"Manifest body", §"Canonical form").
# ---------------------------------------------------------------------------

proc sszKey[T](x: T): seq[byte] = SSZ.encode(x)

proc checkOriginal(o: OriginalRef; field: string) =
  checkIdent(o.package, field & ".package")
  checkIdent(o.catalogWorkspace, field & ".catalogWorkspace")
  checkIdent(o.catalogRemote, field & ".catalogRemote")
  checkRevision(o.catalogRevision, field & ".catalogRevision")

proc checkBlob(b: BlobRef; field: string; maxSize = MaxBlobBytes) =
  checkIdent(b.mediaType, field & ".mediaType")
  if b.size == 0:
    refuse(rrInvalidText, field & " declares an empty blob")
  if b.size > maxSize:
    refuse(rrBound, field & " declares " & $b.size & " bytes, bound " & $maxSize)

proc validateManifest*(m: Manifest) =
  ## Every rule a well-formed v1 manifest satisfies. Raises `RemixError`.
  checkRemixName(m.remixName)
  checkIdent(m.version, "version")
  checkFreeText(m.intent, "intent")
  checkSpacedAscii(m.license, "license")

  for i, t in m.targets:
    checkOriginal(t.original, "targets[" & $i & "]")
    case t.constraintKind
    of ckExactFingerprint:
      if t.constraint.len != 0:
        refuse(rrNonCanonical, "exact-fingerprint target carries a range")
    of ckVersionRange:
      checkSpacedAscii(t.constraint, "targets[" & $i & "].constraint")
  requireStrictlyAscending(m.targets, proc (t: Target): seq[byte] =
    sszKey(TargetW(original: toW(t.original), constraintKind: uint8(ord(t.constraintKind)),
                   constraint: textL(t.constraint, SszName, "constraint"))), "targets")

  for p in m.platforms:
    checkIdent(p, "platform")
  requireStrictlyAscending(m.platforms, proc (p: string): seq[byte] = toBytes(p),
                           "platforms")

  requireStrictlyAscending(m.parents, proc (d: Digest32): seq[byte] = @d, "parents")

  for i, s in m.sources:
    checkIdent(s.repo, "sources[" & $i & "].repo")
    checkIdent(s.remote, "sources[" & $i & "].remote")
    checkRevision(s.revision, "sources[" & $i & "].revision")
    checkDigestText(s.digest, "sources[" & $i & "].digest")
  requireStrictlyAscending(m.sources, proc (s: SourceTree): seq[byte] =
    sszKey(SourceTreeW(repo: textL(s.repo, SszName, "repo"),
      remote: textL(s.remote, SszText, "remote"),
      revision: textL(s.revision, SszRevision, "revision"),
      digest: textL(s.digest, SszDigestText, "digest"))), "sources")

  for i, p in m.patches:
    let bound = (if p.appliesToKind == ptTarget: m.targets.len else: m.sources.len)
    if int(p.appliesToIndex) >= bound:
      refuse(rrDanglingReference, "patches[" & $i & "] applies to a missing entry")
    if p.strip > MaxPatchStrip:
      refuse(rrBound, "patches[" & $i & "].strip exceeds " & $MaxPatchStrip)
    checkBlob(p.blob, "patches[" & $i & "].blob")
  requireStrictlyAscending(m.patches, proc (p: Patch): seq[byte] =
    @[byte(ord(p.appliesToKind)), byte(p.appliesToIndex shr 8),
      byte(p.appliesToIndex and 0xff), byte(p.order shr 8), byte(p.order and 0xff)],
    "patches")

  for i, b in m.graphFragments:
    checkBlob(b, "graphFragments[" & $i & "]")
  requireStrictlyAscending(m.graphFragments, proc (b: BlobRef): seq[byte] = @(b.id),
                           "graphFragments")

  for i, c in m.configuration:
    checkIdent(c.configurable, "configuration[" & $i & "].configurable")
    checkBlob(c.value, "configuration[" & $i & "].value")
  requireStrictlyAscending(m.configuration, proc (c: ConfigContribution): seq[byte] =
    toBytes(c.configurable) & @[0'u8, byte(ord(c.priority)), byte(ord(c.operation))],
    "configuration")

  for e in m.exposedConfigurables:
    checkIdent(e.name, "exposedConfigurable")
  requireStrictlyAscending(m.exposedConfigurables,
    proc (e: ExposedConfigurable): seq[byte] = toBytes(e.name), "exposedConfigurables")

  for i, t in m.tests:
    checkIdent(t.name, "tests[" & $i & "].name")
    if int(t.fragment) >= m.graphFragments.len:
      refuse(rrDanglingReference, "tests[" & $i & "] names a missing graph fragment")
  requireStrictlyAscending(m.tests, proc (t: TestRef): seq[byte] = toBytes(t.name),
                           "tests")

  for i, h in m.healthChecks:
    # A command check carries its arguments (single spaces, printable
    # ASCII); every other kind names one unit, socket or path.
    if h.kind == hcCommandExitZero:
      checkSpacedAscii(h.target, "healthChecks[" & $i & "].target")
    else:
      checkIdent(h.target, "healthChecks[" & $i & "].target")
    if h.timeoutSeconds == 0 or h.timeoutSeconds > MaxHealthTimeoutSeconds:
      refuse(rrBound, "healthChecks[" & $i & "] timeout outside 1.." &
                      $MaxHealthTimeoutSeconds)
  requireStrictlyAscending(m.healthChecks, proc (h: HealthCheck): seq[byte] =
    @[byte(ord(h.kind))] & toBytes(h.target), "healthChecks")

  for i, b in m.assets:
    checkBlob(b, "assets[" & $i & "]", MaxAssetBytes)
  requireStrictlyAscending(m.assets, proc (b: BlobRef): seq[byte] = @(b.id), "assets")

  for i, p in m.permissions:
    if permissionTakesScope(p.kind):
      checkIdent(p.scope, "permissions[" & $i & "].scope")
    elif p.scope.len != 0:
      refuse(rrNonCanonical, "permissions[" & $i & "] carries a scope its kind does not take")
  requireStrictlyAscending(m.permissions, proc (p: Permission): seq[byte] =
    @[byte(ord(p.kind))] & toBytes(p.scope), "permissions")

  for i, d in m.dataMigrations:
    checkIdent(d.store, "dataMigrations[" & $i & "].store")
    checkIdent(d.edge, "dataMigrations[" & $i & "].edge")
  requireStrictlyAscending(m.dataMigrations, proc (d: DataMigration): seq[byte] =
    toBytes(d.store), "dataMigrations")

  for i, o in m.dependenciesAdded:
    checkOriginal(o, "dependenciesAdded[" & $i & "]")
  requireStrictlyAscending(m.dependenciesAdded, proc (o: OriginalRef): seq[byte] =
    sszKey(toW(o)), "dependenciesAdded")

  if m.authors.len == 0:
    refuse(rrMissingAuthorSignature, "manifest names no authors")
  requireStrictlyAscending(m.authors, proc (d: Digest32): seq[byte] = @d, "authors")

  for e in m.extensions:
    checkIdent(e.id, "extension id")
    if e.critical and e.id notin KnownExtensions:
      refuse(rrUnknownCriticalExtension, "critical extension " & e.id)
  requireStrictlyAscending(m.extensions, proc (e: Extension): seq[byte] = toBytes(e.id),
                           "extensions")

# ---------------------------------------------------------------------------
# Manifest body bytes.
# ---------------------------------------------------------------------------

proc encodeManifest*(m: Manifest): seq[byte] =
  ## Validate, then encode the canonical body bytes.
  validateManifest(m)
  SSZ.encode(toWire(m))

proc decodeManifest*(body: openArray[byte]): Manifest =
  ## Decode, validate, and refuse unless re-encoding reproduces `body`.
  if body.len > MaxBodyBytes:
    refuse(rrOversize, "manifest body exceeds " & $MaxBodyBytes & " bytes")
  var w: ManifestW
  try:
    w = SSZ.decode(body, ManifestW)
  except SerializationError as e:
    refuse(rrMalformed, "manifest body: " & e.msg)
  result = fromWire(w)
  validateManifest(result)
  let again = SSZ.encode(toWire(result))
  if again != @body:
    refuse(rrNonCanonical, "manifest body does not re-encode to the same bytes")

# ---------------------------------------------------------------------------
# Envelope (RBSZ frame around the bounded wrapper).
# ---------------------------------------------------------------------------

proc putU16(buf: var seq[byte]; v: uint16) =
  buf.add byte(v and 0xff)
  buf.add byte(v shr 8)

proc putU32(buf: var seq[byte]; v: uint32) =
  for i in 0 ..< 4:
    buf.add byte((v shr (8 * i)) and 0xff)

proc getU16(b: openArray[byte]; pos: int): uint16 =
  uint16(b[pos]) or (uint16(b[pos + 1]) shl 8)

proc getU32(b: openArray[byte]; pos: int): uint32 =
  for i in 0 ..< 4:
    result = result or (uint32(b[pos + i]) shl (8 * i))

proc sortSignatures*(sigs: var seq[Signature]) =
  sigs.sort(proc (a, b: Signature): int = cmpBytes(a.keyId, b.keyId))

proc checkSignatureShapes(sigs: seq[Signature]) =
  requireStrictlyAscending(sigs, proc (s: Signature): seq[byte] = @(s.keyId),
                           "signatures")
  for s in sigs:
    case s.algorithm
    of saEcdsaP256:
      if s.publicKey.len != 65 or s.value.len != 64:
        refuse(rrMalformed, "ECDSA-P256 signature has the wrong key or value length")

proc encodeEnvelope*(env: Envelope): seq[byte] =
  ## Frame an envelope. Signatures must already be in canonical order
  ## (`sortSignatures`); the encoder refuses rather than silently sorting,
  ## so a caller's bytes and the encoder's never disagree.
  checkSignatureShapes(env.signatures)
  var w = WrapperW(schemaVersion: env.schemaVersion,
                   requiredFeatures: env.requiredFeatures,
                   recordKind: uint8(ord(env.recordKind)),
                   body: toL(env.body, List[byte, MaxBodyBytes], "body"))
  var sigs: seq[SignatureW]
  for s in env.signatures:
    sigs.add SignatureW(keyId: s.keyId, algorithm: uint8(ord(s.algorithm)),
      publicKey: toL(s.publicKey, List[byte, MaxPublicKeyBytes], "publicKey"),
      value: toL(s.value, List[byte, MaxSignatureValueBytes], "signature"))
  w.signatures = toL(sigs, List[SignatureW, MaxSignatures], "signatures")
  let payload = SSZ.encode(w)
  result = newSeqOfCap[byte](FrameHeaderLen + payload.len)
  result.add FrameMagic
  result.putU16(FrameVersion)
  result.putU16(RemixEnvelopeTypeId)
  result.putU32(uint32(payload.len))
  result.add payload

proc decodeEnvelope*(bytes: openArray[byte]): Envelope =
  ## Decode and check the frame and wrapper. Does not decode the body or
  ## verify signatures; see `decodeManifestEnvelope` and `verify.nim`.
  if bytes.len < FrameHeaderLen:
    refuse(rrTruncated, "shorter than the RBSZ frame header")
  for i in 0 ..< 4:
    if bytes[i] != FrameMagic[i]:
      refuse(rrBadMagic, "not an RBSZ frame")
  if getU16(bytes, 4) != FrameVersion:
    refuse(rrUnknownEnvelopeVersion, "frame version " & $getU16(bytes, 4))
  if getU16(bytes, 6) != RemixEnvelopeTypeId:
    refuse(rrUnknownTypeId, "type id " & $getU16(bytes, 6))
  let length = int(getU32(bytes, 8))
  if length > MaxFrameBytes:
    refuse(rrOversize, "frame payload of " & $length & " bytes")
  if FrameHeaderLen + length != bytes.len:
    refuse(rrLengthMismatch, "frame length field disagrees with the input")
  var w: WrapperW
  try:
    w = SSZ.decode(bytes.toOpenArray(FrameHeaderLen, bytes.len - 1), WrapperW)
  except SerializationError as e:
    refuse(rrMalformed, "wrapper: " & e.msg)
  if w.schemaVersion != RemixSchemaVersion:
    refuse(rrUnknownSchemaVersion, "schema version " & $w.schemaVersion)
  if (w.requiredFeatures and not RemixKnownFeatures) != 0:
    refuse(rrUnknownRequiredFeature, "required feature bits " & $w.requiredFeatures)
  result.schemaVersion = w.schemaVersion
  result.requiredFeatures = w.requiredFeatures
  if w.recordKind < uint8(ord(RecordKind.low)) or
     w.recordKind > uint8(ord(RecordKind.high)):
    refuse(rrUnknownRecordKind, "record kind " & $w.recordKind)
  result.recordKind = RecordKind(w.recordKind)
  result.body = asSeq(w.body)
  for s in asSeq(w.signatures):
    result.signatures.add Signature(keyId: s.keyId,
      algorithm: enumFrom(s.algorithm, SignatureAlgorithm, "signature algorithm"),
      publicKey: asSeq(s.publicKey), value: asSeq(s.value))
  checkSignatureShapes(result.signatures)
  if encodeEnvelope(result) != @bytes:
    refuse(rrNonCanonical, "envelope does not re-encode to the same bytes")

proc newManifestEnvelope*(m: Manifest): Envelope =
  ## An unsigned v1 manifest envelope; sign it with `signEnvelope`.
  Envelope(schemaVersion: RemixSchemaVersion, requiredFeatures: 0,
           recordKind: rkManifest, body: encodeManifest(m))
