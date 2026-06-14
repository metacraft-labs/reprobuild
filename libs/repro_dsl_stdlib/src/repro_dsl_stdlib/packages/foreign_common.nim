## C1: shared infrastructure for the foreign-distro package DSL.
##
## The three thin DSL modules — ``foreign_apt``, ``foreign_dnf``,
## ``foreign_pacman`` — all delegate to the helpers in this module:
##
##   * ``mkForeignPackageRef`` — construct a B1-shape ``PackageRef``
##     (``ptForeignBundle`` variant) with the snapshot-pin shape +
##     known-distro validation B1's parser already enforces. The
##     resulting value composes byte-for-byte with the typed values
##     B1's ``parsePackageCall`` produces when the operator inlines the
##     same package inside a ``configuration.nim`` ``packages = [...]``
##     list (B1 ``dsl.nim`` lines 270-350).
##   * ``writeForeignCatalog`` / ``readForeignCatalog`` — the JSON
##     codec for ``recipes/catalog/foreign/<distro>/<package>.json``
##     files. The codec writes sorted-key JSON so two identical catalogs
##     re-serialize byte-identically (the C2 harvester's idempotency
##     requirement; see also the campaign spec § C2 deliverable list).
##   * ``foreignPackageIdentity`` — composes the catalog file's
##     ``(distro, name, snapshot, version, dep_closure)`` into an A3
##     ``CacheEntryIdentity`` so the realize-hash differentiates by
##     snapshot + distro + name + closure on the existing A3 surface
##     instead of inventing a parallel hashing pipeline.
##
## ## Why the codec lives here and not in a top-level ``repro_catalog``
##
## The B1 ``PackageRef`` shape is the single source of truth for "what
## a Tier 3 package looks like in a configuration". C1's standalone
## DSL just gives the operator a way to *construct* that same value
## inline (e.g. in a Nim helper module that emits a configuration via
## generated code) without going through the configuration-file parser.
## Putting the codec next to the DSL keeps the entire foreign-package
## surface in one importable place — the operator imports
## ``repro_dsl_stdlib/packages/foreign_apt`` and gets the constructor,
## the catalog round-trip helpers, and the realize-hash composer
## without a second import.
##
## ## Catalog file format
##
## See ``recipes/catalog/foreign/SCHEMA.md`` for the authoritative
## description. The codec here implements format_version 1.

import std/[algorithm, json, options, strutils, tables]

import repro_system_apply/types
import repro_system_apply/errors
import ../../../../repro_binary_cache_server/src/repro_binary_cache_server/types as bcsTypes
import ../../../../repro_binary_cache_client/src/repro_binary_cache_client/cache_key

export PackageRef, PackageTier, KnownForeignDistros
export bcsTypes.PlatformTriple, bcsTypes.ToolchainIdentity
export CacheEntryIdentity, deriveCacheEntryKeyHex

const
  ForeignCatalogFormatVersion* = 1
    ## Current on-disk format version. Readers REJECT any other version
    ## (see ``readForeignCatalog``); the writer hard-codes this constant.

type
  ForeignProvisioningKind* = enum
    ## Closed set of provisioning methods the catalog records. C1 ships
    ## ``fpkDirectSnapshotUrl`` only — direct fetch from
    ## ``snapshot.debian.org`` / ``kojipkgs.fedoraproject.org`` /
    ## ``archive.archlinux.org``. Future kinds (mirror-url, content-
    ## addressed local cache) extend this enum + the JSON codec by
    ## adding a new ``"kind"`` discriminator.
    fpkDirectSnapshotUrl = "direct-snapshot-url"

  ForeignProvisioningMethod* = object
    ## One provisioning method entry. C1 carries the direct-URL shape;
    ## the (size, sha256, url) triple matches the binary-cache payload
    ## descriptor surface from A2 so a future "publish the .deb to the
    ## binary cache" flow can reuse the digest verbatim.
    kind*: ForeignProvisioningKind
    url*: string                       ## fully-qualified upstream URL
    sha256*: string                    ## 64-char lowercase hex
    sizeBytes*: int64                  ## archive size in bytes

  ForeignSignedEnvelope* = object
    ## Opt-in BLAKE3 + ECDSA-P256 wrap. C1 leaves the envelope unset;
    ## C2 populates it once the key-bundle policy lands. The envelope
    ## carries the digest of the *un-wrapped* catalog bytes (the
    ## ``providerRevision`` input) plus the signature over that digest.
    digestHex*: string                 ## 64-char lowercase hex BLAKE3
                                       ## of the unsigned canonical
                                       ## catalog bytes
    signatureHex*: string              ## hex-encoded ECDSA-P256
                                       ## signature
    signerKeyId*: string               ## opaque key identifier the
                                       ## verifier looks up in the
                                       ## archive key bundle

  ForeignCatalog* = object
    ## In-memory shape of a ``recipes/catalog/foreign/<distro>/<package>.json``
    ## file. The codec writes this with sorted keys at every level so
    ## two identical catalogs re-serialize byte-identically.
    formatVersion*: int                ## must equal
                                       ## ``ForeignCatalogFormatVersion``
    package*: PackageRef               ## the foreign-bundle PackageRef
                                       ## the operator references in the
                                       ## DSL; this is the SAME shape B1
                                       ## produces from
                                       ## ``parsePackageCall``
    version*: string                   ## inferred from the snapshot's
                                       ## Packages index. C1 ships
                                       ## placeholder strings on the
                                       ## sample catalogs; C2 fills the
                                       ## real version on harvest.
    provisioningMethods*: seq[ForeignProvisioningMethod]
                                       ## at least one entry required
    dependencyClosure*: seq[PackageRef]
                                       ## sorted by (distro, name,
                                       ## snapshot). C1 leaves the
                                       ## placeholder catalogs with an
                                       ## empty closure; C2 fills.
    signedEnvelope*: Option[ForeignSignedEnvelope]
                                       ## ``none`` on C1 catalogs; C2
                                       ## populates.

  EForeignCatalog* = object of CatchableError
    ## Common base for catalog I/O diagnostics. Concrete subclasses
    ## carry structured context for the CLI.

  EForeignCatalogVersion* = object of EForeignCatalog
    ## Reader saw a ``format_version`` other than the constant it
    ## supports. Operators must re-harvest with a matching C2 release.
    seenVersion*: int
    expectedVersion*: int

  EForeignCatalogMissingField* = object of EForeignCatalog
    ## Required field absent from the JSON envelope.
    field*: string

  EForeignCatalogShape* = object of EForeignCatalog
    ## A field is present but malformed (wrong JSON kind, empty string,
    ## bad hex, ...).
    field*: string
    detail*: string

# ---------------------------------------------------------------------------
# Snapshot + distro validation (shared with B1's parser by intent;
# duplicated by code so the DSL is usable from a standalone Nim helper
# that doesn't import the system_apply parser).
# ---------------------------------------------------------------------------

proc validateSnapshotPin*(snapshot: string): bool =
  ## Mirror of B1's ``parsePackageCall`` snapshot validation
  ## (``libs/repro_system_apply/src/repro_system_apply/dsl.nim`` lines
  ## 340-348): non-empty, slash-separated, at least three non-empty
  ## segments. ``"debian/bookworm/20260601T000000Z"`` passes;
  ## ``"not-a-pin"`` and ``"a//b/c"`` do not.
  if snapshot.len == 0:
    return false
  let segs = snapshot.split('/')
  if segs.len < 3:
    return false
  for s in segs:
    if s.len == 0:
      return false
  true

proc mkForeignPackageRef*(distro, name, snapshot: string;
                          sourceFile = ""; sourceLine = 0): PackageRef =
  ## Construct a ``ptForeignBundle`` PackageRef with the same validation
  ## B1's parser performs. Raises ``EUnknownForeignDistro`` for an
  ## unknown distro, ``EMalformedSnapshot`` for a bad snapshot,
  ## ``EMissingRequiredField`` for an empty package name. The
  ## constructor uses B1's exception types (re-exported via
  ## ``repro_system_apply/errors``) so a downstream CLI catches
  ## inline-DSL diagnostics with the same ``except ESystemConfig``
  ## clause it already has for configuration-file diagnostics.
  if name.len == 0:
    raiseMissingRequiredField(sourceFile, "package", "", "name",
      max(sourceLine, 1))
  if distro notin KnownForeignDistros:
    raiseUnknownForeignDistro(sourceFile, distro, max(sourceLine, 1))
  if not validateSnapshotPin(snapshot):
    raiseMalformedSnapshot(sourceFile, snapshot, max(sourceLine, 1))
  PackageRef(tier: ptForeignBundle, name: name,
    distro: distro, snapshot: snapshot,
    sourceFile: sourceFile, sourceLine: sourceLine)

# ---------------------------------------------------------------------------
# Catalog file path helpers
# ---------------------------------------------------------------------------

proc catalogRelpath*(distro, name: string): string =
  ## Returns the catalog file's repo-relative path:
  ## ``recipes/catalog/foreign/<distro>/<name>.json``. The caller joins
  ## the repo root.
  "recipes/catalog/foreign/" & distro & "/" & name & ".json"

# ---------------------------------------------------------------------------
# JSON codec — sorted-key write + version-checked read
# ---------------------------------------------------------------------------

proc cmpPackageRef(a, b: PackageRef): int =
  result = cmp(a.distro, b.distro)
  if result != 0: return
  result = cmp(a.name, b.name)
  if result != 0: return
  result = cmp(a.snapshot, b.snapshot)

proc cmpProvisioning(a, b: ForeignProvisioningMethod): int =
  result = cmp($a.kind, $b.kind)
  if result != 0: return
  result = cmp(a.url, b.url)

proc packageRefToJson(p: PackageRef): JsonNode =
  ## Produce a sorted-key JSON object for one PackageRef. The catalog
  ## writer wraps this for both the outer ``package`` field and each
  ## ``dependency_closure`` entry.
  result = newJObject()
  result["distro"] = %p.distro
  result["name"] = %p.name
  result["snapshot"] = %p.snapshot
  result["tier"] = %($p.tier)

proc provisioningToJson(m: ForeignProvisioningMethod): JsonNode =
  result = newJObject()
  result["kind"] = %($m.kind)
  result["sha256"] = %m.sha256
  result["size_bytes"] = %m.sizeBytes
  result["url"] = %m.url

proc signedEnvelopeToJson(env: ForeignSignedEnvelope): JsonNode =
  result = newJObject()
  result["digest_hex"] = %env.digestHex
  result["signature_hex"] = %env.signatureHex
  result["signer_key_id"] = %env.signerKeyId

proc catalogToJson*(c: ForeignCatalog): JsonNode =
  ## Build the canonical JSON tree. Keys are inserted in lexical order
  ## ('d' < 'f' < 'p' < 's') so the std/json serializer (which preserves
  ## insertion order) emits a sorted-key document.
  result = newJObject()

  # "dependency_closure" — sorted by (distro, name, snapshot)
  var deps = c.dependencyClosure
  deps.sort(cmpPackageRef)
  let depsArr = newJArray()
  for d in deps:
    depsArr.add packageRefToJson(d)
  result["dependency_closure"] = depsArr

  # "format_version"
  result["format_version"] = %c.formatVersion

  # "package" — outer package object; keys are inserted in sorted order
  # (distro/name/snapshot/version) so the encoded bytes stay stable.
  let pkgObj = newJObject()
  pkgObj["distro"] = %c.package.distro
  pkgObj["name"] = %c.package.name
  pkgObj["snapshot"] = %c.package.snapshot
  pkgObj["version"] = %c.version
  result["package"] = pkgObj

  # "provisioning_methods" — sorted by (kind, url)
  var methods = c.provisioningMethods
  methods.sort(cmpProvisioning)
  let methodsArr = newJArray()
  for m in methods:
    methodsArr.add provisioningToJson(m)
  result["provisioning_methods"] = methodsArr

  # "signed_envelope" — null when unset
  if c.signedEnvelope.isSome:
    result["signed_envelope"] = signedEnvelopeToJson(c.signedEnvelope.get)
  else:
    result["signed_envelope"] = newJNull()

proc serializeCatalog*(c: ForeignCatalog): string =
  ## Byte-stable canonical encoding: 2-space indented, sorted-key JSON
  ## ending in a trailing newline. The trailing newline matches the
  ## existing reprobuild convention (every catalog file the M67/M68
  ## bulk-harvester emits ends in ``\n``).
  let node = catalogToJson(c)
  result = node.pretty(indent = 2)
  if not result.endsWith("\n"):
    result.add('\n')

proc writeForeignCatalog*(c: ForeignCatalog; outPath: string) =
  ## Write the catalog file. Mirror of B2's ``manifest.txt`` write side
  ## but for the JSON catalog plane.
  writeFile(outPath, serializeCatalog(c))

proc raiseMissingField(field: string) {.noreturn.} =
  var e = newException(EForeignCatalogMissingField,
    "foreign catalog missing required field '" & field & "'")
  e.field = field
  raise e

proc raiseShape(field, detail: string) {.noreturn.} =
  var e = newException(EForeignCatalogShape,
    "foreign catalog field '" & field & "' is malformed: " & detail)
  e.field = field
  e.detail = detail
  raise e

proc parsePackageRef(node: JsonNode; ctx: string): PackageRef =
  if node.kind != JObject:
    raiseShape(ctx, "expected object, got " & $node.kind)
  if "distro" notin node:
    raiseShape(ctx & ".distro", "absent")
  if "name" notin node:
    raiseShape(ctx & ".name", "absent")
  if "snapshot" notin node:
    raiseShape(ctx & ".snapshot", "absent")
  let distro = node["distro"].getStr
  let name = node["name"].getStr
  let snapshot = node["snapshot"].getStr
  if distro notin KnownForeignDistros:
    raiseShape(ctx & ".distro", "unknown distro '" & distro & "'")
  if not validateSnapshotPin(snapshot):
    raiseShape(ctx & ".snapshot", "malformed pin '" & snapshot & "'")
  result = PackageRef(tier: ptForeignBundle,
    distro: distro, name: name, snapshot: snapshot)

proc parseProvisioning(node: JsonNode; ctx: string):
    ForeignProvisioningMethod =
  if node.kind != JObject:
    raiseShape(ctx, "expected object, got " & $node.kind)
  if "kind" notin node:
    raiseShape(ctx & ".kind", "absent")
  let kindStr = node["kind"].getStr
  if kindStr != $fpkDirectSnapshotUrl:
    raiseShape(ctx & ".kind",
      "unknown provisioning kind '" & kindStr & "'")
  result.kind = fpkDirectSnapshotUrl
  if "url" notin node:
    raiseShape(ctx & ".url", "absent")
  if "sha256" notin node:
    raiseShape(ctx & ".sha256", "absent")
  if "size_bytes" notin node:
    raiseShape(ctx & ".size_bytes", "absent")
  result.url = node["url"].getStr
  result.sha256 = node["sha256"].getStr
  result.sizeBytes = node["size_bytes"].getBiggestInt.int64

proc parseSignedEnvelope(node: JsonNode; ctx: string): ForeignSignedEnvelope =
  if node.kind != JObject:
    raiseShape(ctx, "expected object, got " & $node.kind)
  if "digest_hex" notin node or "signature_hex" notin node or
     "signer_key_id" notin node:
    raiseShape(ctx, "signed envelope must carry digest_hex + " &
      "signature_hex + signer_key_id")
  result.digestHex = node["digest_hex"].getStr
  result.signatureHex = node["signature_hex"].getStr
  result.signerKeyId = node["signer_key_id"].getStr

proc readForeignCatalogFromString*(src: string): ForeignCatalog =
  ## Parse a catalog file's canonical JSON encoding. Rejects any
  ## ``format_version`` other than the one this build supports.
  let root = parseJson(src)
  if root.kind != JObject:
    raiseShape("<root>", "expected JSON object, got " & $root.kind)

  if "format_version" notin root:
    raiseMissingField("format_version")
  let ver = root["format_version"].getInt
  if ver != ForeignCatalogFormatVersion:
    var e = newException(EForeignCatalogVersion,
      "foreign catalog format_version " & $ver &
      " unsupported (this build understands " &
      $ForeignCatalogFormatVersion & ")")
    e.seenVersion = ver
    e.expectedVersion = ForeignCatalogFormatVersion
    raise e
  result.formatVersion = ver

  if "package" notin root:
    raiseMissingField("package")
  let pkgNode = root["package"]
  if pkgNode.kind != JObject:
    raiseShape("package", "expected object, got " & $pkgNode.kind)
  result.package = parsePackageRef(pkgNode, "package")
  if "version" notin pkgNode:
    raiseShape("package.version", "absent")
  result.version = pkgNode["version"].getStr

  if "provisioning_methods" notin root:
    raiseMissingField("provisioning_methods")
  let methodsNode = root["provisioning_methods"]
  if methodsNode.kind != JArray:
    raiseShape("provisioning_methods",
      "expected array, got " & $methodsNode.kind)
  if methodsNode.len == 0:
    raiseShape("provisioning_methods",
      "at least one provisioning method is required")
  for i, m in methodsNode.elems:
    result.provisioningMethods.add(
      parseProvisioning(m, "provisioning_methods[" & $i & "]"))

  # dependency_closure is required but may be the empty list (C1
  # placeholders, before C2's harvester fills it).
  if "dependency_closure" notin root:
    raiseMissingField("dependency_closure")
  let depsNode = root["dependency_closure"]
  if depsNode.kind != JArray:
    raiseShape("dependency_closure",
      "expected array, got " & $depsNode.kind)
  for i, d in depsNode.elems:
    result.dependencyClosure.add(
      parsePackageRef(d, "dependency_closure[" & $i & "]"))

  # signed_envelope is optional / nullable
  if "signed_envelope" in root:
    let env = root["signed_envelope"]
    if env.kind == JNull:
      result.signedEnvelope = none(ForeignSignedEnvelope)
    else:
      result.signedEnvelope = some(parseSignedEnvelope(env, "signed_envelope"))
  else:
    result.signedEnvelope = none(ForeignSignedEnvelope)

proc readForeignCatalog*(path: string): ForeignCatalog =
  readForeignCatalogFromString(readFile(path))

# ---------------------------------------------------------------------------
# Realize-hash composer (A3 ``CacheEntryIdentity`` shape)
# ---------------------------------------------------------------------------

proc foreignPackageIdentity*(catalog: ForeignCatalog;
                             hostPlatform: PlatformTriple;
                             harvesterRevision = "c1-placeholder";
                             providerRevision = "c1-placeholder"):
    CacheEntryIdentity =
  ## Compose the realize-hash inputs for a foreign-package catalog.
  ## Mirrors the A3 ``CacheEntryIdentity`` shape so the resulting key
  ## flows through the same ``deriveCacheEntryKey`` /
  ## ``cacheEntryKeyHex`` pipeline as Tier 1 packages.
  ##
  ## Differentiating axes (per the campaign spec § C1 Fix scope):
  ##   * snapshot — encoded in ``selectedOptions["snapshot"]``;
  ##   * distro   — encoded in ``selectedOptions["distro"]`` AND in the
  ##                catalog file path the harvester wrote, so two
  ##                catalogs with the same name but different distros
  ##                produce different ``providerRevision`` inputs (the
  ##                C2 harvester sets this to the canonical catalog-byte
  ##                SHA-256 in production);
  ##   * name     — encoded in ``packageName``;
  ##   * closure  — encoded in ``depClosure`` (sorted hex of each
  ##                transitive dep's identity hash).
  ##
  ## ``harvesterRevision`` is the harvester's content-addressed identity
  ## (C2 sets this to the harvester binary's sha256). C1 takes a
  ## placeholder so the realize-hash composer is testable in isolation.
  ##
  ## ``providerRevision`` is the SHA-256 of the canonical catalog bytes.
  ## Tests typically pass the canonical-bytes hex directly; the
  ## production realize loop computes ``sha256(serializeCatalog(c))``.
  let toolchain = ToolchainIdentity(
    name: catalog.package.distro & "-harvester",
    version: harvesterRevision,
    hostLdSoAbi: "",
    extraFingerprint: "")
  result = newCacheEntryIdentity(
    packageName = catalog.package.name,
    packageVersion = catalog.version,
    platform = hostPlatform,
    toolchain = toolchain,
    providerRevision = providerRevision)
  result.addOption("distro", catalog.package.distro)
  result.addOption("snapshot", catalog.package.snapshot)

  # Dep-closure: for C1 we compose a SYNTHETIC 64-char hex digest per
  # dep from its (distro, name, snapshot) — the C2 harvester replaces
  # this with the real per-dep ``CacheEntryIdentity`` hex once the
  # transitive deps each get their own catalog files. The synthetic
  # form is still byte-stable + sensitive to (distro, name, snapshot)
  # changes, which is the differentiating property the realize-hash
  # test cares about. ``addOption`` accepts arbitrary 64-char hex; we
  # produce 32-zero-padding + the (distro, name, snapshot) string
  # hashed via a simple stable mixer.
  for dep in catalog.dependencyClosure:
    # Use the existing ``depClosureDigest`` helper indirectly: each dep
    # contributes one 64-char hex string that we feed verbatim. The
    # caller (C2) will pass real digests; for C1 we mix the dep's
    # (distro, name, snapshot) into 64 hex chars deterministically.
    let mix = dep.distro & "\x00" & dep.name & "\x00" & dep.snapshot
    var hexBuf = newStringOfCap(64)
    # Simple deterministic 64-char hex: byte-by-byte hex of a repeating
    # mix string. This is NOT a cryptographic hash; it's a stable
    # placeholder until C2 wires the real per-dep digest. The
    # differentiating property the C1 realize-hash test exercises
    # (adding/removing a dep changes the hash) holds because the
    # encoded depClosure bytes differ.
    var idx = 0
    while hexBuf.len < 64:
      let ch = mix[idx mod mix.len]
      let hi = (ch.uint8 shr 4) and 0xf
      let lo = ch.uint8 and 0xf
      const Hex = "0123456789abcdef"
      hexBuf.add Hex[hi]
      hexBuf.add Hex[lo]
      inc idx
    result.addDep(hexBuf)
