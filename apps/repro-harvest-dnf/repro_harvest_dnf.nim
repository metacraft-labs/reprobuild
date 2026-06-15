## D2 P1: ``repro-harvest-dnf`` — Fedora dnf foreign-package harvester.
##
## Mirrors the structure of ``repro-harvest-apt``:
##
##   1. Fetch ``repodata/repomd.xml`` from the snapshot host.
##   2. Verify the signature (external-gpg detached sig OR vendored
##      fingerprint allowlist).
##   3. Read ``<data type="primary">`` location + sha256 from repomd.xml;
##      fetch + sha256-verify the primary.xml.gz; decompress.
##   4. Parse the primary.xml, walk the transitive closure of the
##      requested package(s), gather every dep's location + sha256 +
##      version. Emit one C1-format catalog file per package in the
##      union closure.
##
## ## Command-line surface
##
##   repro-harvest-dnf
##     --source dnf:<pkgs>@<distro>/<release>:<snapshot>
##     --output-dir <path>          (required)
##     --cache-dir  <path>          (HTTP cache; default
##                                   ``$TMP/repro-harvest-dnf-cache``)
##     --gpg-keys   <path>          (key-bundle dir; default
##                                   ``recipes/catalog/foreign/dnf/keys/``)
##     --offline                    (refuse live HTTP; cache-only)
##     --insecure                   (skip repomd.xml signature
##                                   verification; logs a warning)
##     --upstream  <host>           (default kojipkgs.fedoraproject.org)
##     --rate-ms   <int>            (per-host min delay; default 1000)
##     --signature-backend external-gpg | fingerprint-allowlist
##     --allow-unresolved           (treat unresolved requires atoms as
##                                   warnings, not closure-walk failures.
##                                   Default ON for dnf — real Fedora
##                                   primary.xml carries dozens of
##                                   file-path style requires.)
##     --strict-closure             (opposite of --allow-unresolved)
##
## ## Exit codes
##
##   0  — success; catalog files written.
##   1  — argument parsing / spec validation failure.
##   2  — signature verification failure (anti-tamper).
##   3  — network / cache failure.
##   4  — index parsing / closure-walk failure.
##   5  — catalog emission failure (I/O error on write).

import std/[options, os, strutils, tables]

import blake3

import repro_dsl_stdlib/packages/foreign_dnf
import repro_dsl_stdlib/packages/dnf_index
import repro_system_apply/types as sysTypes
import repro_binary_cache_server/types as bcsTypes

# Reuse the apt harvester's generic HTTP-cache + decompression utility.
import repro_harvest_apt/fetch as apt_fetch

import repro_harvest_dnf/signature
import repro_harvest_dnf/source_spec

# ---------------------------------------------------------------------------
# CLI argument parsing
# ---------------------------------------------------------------------------

type
  HarvesterArgs = object
    source: string
    outputDir: string
    cacheDir: string
    gpgKeys: string
    offline: bool
    insecure: bool
    upstream: string
    rateMs: int
    signatureBackend: SignatureBackend
    allowUnresolved: bool

  CliError = object of CatchableError

proc defaultCacheDir(): string =
  getTempDir() / "repro-harvest-dnf-cache"

proc parseArgs(argv: seq[string] = commandLineParams()):
    HarvesterArgs =
  result.upstream = DefaultUpstream
  result.rateMs = 1000
  result.signatureBackend = sbExternalGpg
  result.allowUnresolved = true

  var i = 0
  proc nextValue(flag: string): string =
    inc i
    if i >= argv.len:
      raise newException(CliError,
        "--" & flag & " requires a value")
    argv[i]

  while i < argv.len:
    var a = argv[i]
    if a == "-h" or a == "--help":
      raise newException(CliError, "HELP")
    if not a.startsWith("--"):
      raise newException(CliError, "unexpected positional argument: " &
        a)
    a = a[2 .. ^1]
    var flag = a
    var val = ""
    var hasInline = false
    let eqIdx = a.find('=')
    if eqIdx >= 0:
      flag = a[0 ..< eqIdx]
      val = a[eqIdx + 1 .. ^1]
      hasInline = true
    case flag
    of "source":
      result.source = if hasInline: val else: nextValue(flag)
    of "output-dir":
      result.outputDir = if hasInline: val else: nextValue(flag)
    of "cache-dir":
      result.cacheDir = if hasInline: val else: nextValue(flag)
    of "gpg-keys":
      result.gpgKeys = if hasInline: val else: nextValue(flag)
    of "offline": result.offline = true
    of "insecure": result.insecure = true
    of "upstream":
      result.upstream = if hasInline: val else: nextValue(flag)
    of "rate-ms":
      let v = if hasInline: val else: nextValue(flag)
      try:
        result.rateMs = parseInt(v)
      except ValueError:
        raise newException(CliError, "--rate-ms expects an integer")
    of "signature-backend":
      let v = if hasInline: val else: nextValue(flag)
      case v
      of "external-gpg": result.signatureBackend = sbExternalGpg
      of "fingerprint-allowlist":
        result.signatureBackend = sbFingerprintAllowlist
      else:
        raise newException(CliError,
          "--signature-backend must be 'external-gpg' or " &
          "'fingerprint-allowlist'; got " & v)
    of "allow-unresolved":
      result.allowUnresolved = true
    of "strict-closure":
      result.allowUnresolved = false
    of "help":
      raise newException(CliError, "HELP")
    else:
      raise newException(CliError, "unknown option: --" & flag)
    inc i

  if result.source.len == 0:
    raise newException(CliError, "--source is required")
  if result.outputDir.len == 0:
    raise newException(CliError, "--output-dir is required")
  if result.cacheDir.len == 0:
    result.cacheDir = defaultCacheDir()

# ---------------------------------------------------------------------------
# Harvester-binary fingerprint
# ---------------------------------------------------------------------------

proc harvesterBinaryRevision*(): string =
  let path = try: getAppFilename() except: ""
  if path.len > 0 and fileExists(path):
    try:
      return apt_fetch.sha256HexStr(readFile(path))
    except CatchableError:
      discard
  # Test/transient fallback.
  let raw = blake3.digest("repro-harvest-dnf:dev:" & path)
  result = newStringOfCap(64)
  const Hex = "0123456789abcdef"
  for i in 0 ..< 32:
    let b = raw[i].uint8
    result.add(Hex[int(b shr 4)])
    result.add(Hex[int(b and 0x0f)])

# ---------------------------------------------------------------------------
# Resolver implementation for the foreign_common composer
# ---------------------------------------------------------------------------

proc mkOnDiskCatalogResolver*(catalogRoot: string): ForeignDepResolver =
  proc resolver(depRef: PackageRef): Option[ForeignCatalog] {.gcsafe.} =
    let path = catalogRoot / depRef.distro / (depRef.name & ".json")
    if not fileExists(path):
      return none(ForeignCatalog)
    try:
      return some(readForeignCatalog(path))
    except CatchableError:
      return none(ForeignCatalog)
  resolver

# ---------------------------------------------------------------------------
# Index fetch + signature verify
# ---------------------------------------------------------------------------

proc fetchAndVerifyIndex(client: FetchClient; spec: DnfSourceSpec;
                        keyBundleDir: string;
                        preferredBackend: SignatureBackend;
                        insecure: bool; upstream: string):
    seq[DnfPackageRecord] =
  ## Fetch repomd.xml, verify, then fetch + sha256-verify primary.xml.gz
  ## (or primary.xml), decompress, parse.
  let baseUrl = snapshotBaseUrl(spec, upstream)
  let repomdUrl = repomdUrl(spec, upstream)
  stderr.writeLine "fetch: ", repomdUrl
  let repomd = fetchUrl(client, repomdUrl)
  # Try sibling .asc if external-gpg is requested + not insecure.
  var ascBytes = ""
  if preferredBackend == sbExternalGpg and not insecure:
    let ascUrl = repomdUrl & ".asc"
    try:
      let asc = fetchUrl(client, ascUrl)
      ascBytes = asc.bytes
    except CatchableError:
      stderr.writeLine "note: no repomd.xml.asc at ", ascUrl,
        "; falling back to allowlist backend"

  if insecure:
    stderr.writeLine "WARNING: --insecure was passed; skipping " &
      "repomd.xml signature verification"
  else:
    let verification = verifyRepomd(repomd.bytes, keyBundleDir,
      repomdAscBytes = ascBytes,
      preferredBackend = preferredBackend)
    stderr.writeLine "repomd.xml verified via " & $verification.backend &
      " (signer=" & verification.signerKeyId & ")"

  let entries = parseRepomdXml(repomd.bytes)
  var pri: RepomdEntry
  for e in entries:
    if e.dataType == "primary":
      pri = e
      break
  if pri.location.len == 0:
    raise newException(DnfIndexParseError,
      "repomd.xml has no <data type=\"primary\"> entry")

  # Try the primary.xml.gz (or .xz) location, then plain.
  var priUrl = baseUrl & "/" & pri.location
  stderr.writeLine "fetch: ", priUrl
  var priFetch: CachedFetch
  var fellBackToPlain = false
  try:
    priFetch = fetchUrl(client, priUrl)
  except FetchError:
    # Fall back to a plain primary.xml under repodata/.
    priUrl = baseUrl & "/repodata/primary.xml"
    stderr.writeLine "fallback fetch: ", priUrl
    priFetch = fetchUrl(client, priUrl)
    fellBackToPlain = true

  if not fellBackToPlain and pri.checksumHex.len == 64:
    let actual = apt_fetch.sha256HexStr(priFetch.bytes)
    if actual != pri.checksumHex:
      raise newException(SignatureVerificationError,
        "primary.xml.gz sha256 mismatch: expected " & pri.checksumHex &
        ", got " & actual & " (url=" & priUrl & ")")

  let decompressed =
    if fellBackToPlain or not priUrl.endsWith(".gz") and not priUrl.endsWith(".xz"):
      priFetch.bytes
    else:
      apt_fetch.maybeDecompress(priFetch.bytes, priUrl)
  result = parsePrimaryXml(decompressed)
  stderr.writeLine "parsed ", result.len, " package records from primary.xml"

# ---------------------------------------------------------------------------
# Catalog emission
# ---------------------------------------------------------------------------

proc poolUrlFor(spec: DnfSourceSpec; rec: DnfPackageRecord;
               upstream: string): string =
  snapshotBaseUrl(spec, upstream) & "/" & rec.location

proc fullVersionOf(rec: DnfPackageRecord): string =
  ## Compose ``[epoch:]version-release`` for the catalog's version field.
  if rec.epoch.len > 0 and rec.epoch != "0":
    return rec.epoch & ":" & rec.version & "-" & rec.release
  return rec.version & "-" & rec.release

proc mkCatalogForRecord(spec: DnfSourceSpec; upstream: string;
                       rec: DnfPackageRecord;
                       perRecordClosure: seq[DnfPackageRecord]):
    ForeignCatalog =
  let snapPin = canonicalSnapshotPin(spec)
  result.formatVersion = ForeignCatalogFormatVersion
  result.package = mkForeignPackageRef("dnf", rec.name, snapPin)
  result.version = fullVersionOf(rec)
  result.provisioningMethods = @[
    ForeignProvisioningMethod(
      kind: fpkDirectSnapshotUrl,
      url: poolUrlFor(spec, rec, upstream),
      sha256: rec.checksumHex,
      sizeBytes: rec.sizePackage,
    )
  ]
  for d in perRecordClosure:
    if d.name == rec.name: continue
    result.dependencyClosure.add(
      mkForeignPackageRef("dnf", d.name, snapPin))

# ---------------------------------------------------------------------------
# Main harvester driver
# ---------------------------------------------------------------------------

proc runHarvest*(args: HarvesterArgs) =
  let spec = parseDnfSourceSpec(args.source)
  let keyDir = resolveKeyBundleDir(args.gpgKeys)

  let client = newFetchClient(args.cacheDir,
    minIntervalMs = args.rateMs, offline = args.offline)

  let records = fetchAndVerifyIndex(client, spec, keyDir,
    args.signatureBackend, args.insecure, args.upstream)
  let index = buildDnfIndex(records)

  for pkg in spec.packages:
    if pkg notin index.byName:
      raise newException(DnfClosureError,
        "requested root package '" & pkg & "' is not in the " &
        "snapshot's primary.xml")

  let closure = resolveMultiClosure(spec.packages, index,
    allowUnresolved = args.allowUnresolved)
  stderr.writeLine "closure: ", closure.len, " packages (",
    spec.packages.len, " roots)"

  let dnfDir = args.outputDir / "dnf"
  createDir(dnfDir)

  let harvRev = harvesterBinaryRevision()
  let hostPlatform = PlatformTriple(
    cpu: "x86_64", os: "linux", abi: "gnu",
    libcVariant: "")

  var emitted = 0
  for rec in closure:
    # Per-record transitive closure (mirror of apt harvester).
    let recOwn = resolveClosure(rec.name, index,
      allowUnresolved = args.allowUnresolved)
    var catalog = mkCatalogForRecord(spec, args.upstream, rec, recOwn)
    let provRev = canonicalCatalogProviderRevision(catalog)
    discard foreignPackageIdentity(catalog, hostPlatform,
      harvesterRevision = harvRev,
      providerRevision = provRev,
      resolver = noopDepResolver)
    let outPath = dnfDir / (rec.name & ".json")
    writeForeignCatalog(catalog, outPath)
    inc emitted

  stderr.writeLine "wrote ", emitted, " catalog files under ", dnfDir

  # Second pass: re-compose with the on-disk resolver for diagnostic id.
  let resolver = mkOnDiskCatalogResolver(args.outputDir)
  for rec in closure:
    if rec.name notin spec.packages: continue
    let catalogPath = dnfDir / (rec.name & ".json")
    let catalog = readForeignCatalog(catalogPath)
    let provRev = canonicalCatalogProviderRevision(catalog)
    let idy = foreignPackageIdentity(catalog, hostPlatform,
      harvesterRevision = harvRev,
      providerRevision = provRev,
      resolver = resolver)
    let keyHex = deriveCacheEntryKeyHex(idy)
    stderr.writeLine "identity: ", rec.name, " key=", keyHex,
      " providerRev=", provRev

  stderr.writeLine "harvester complete: ", emitted, " catalogs in ",
    dnfDir

proc printHelp() =
  echo """repro-harvest-dnf — Fedora dnf foreign-package harvester (D2 P1)

Usage:
  repro-harvest-dnf
    --source dnf:<pkgs>@<distro>/<release>:<snapshot>
    --output-dir <path>
    [--cache-dir <path>]       default $TMP/repro-harvest-dnf-cache
    [--gpg-keys <path>]        default recipes/catalog/foreign/dnf/keys/
    [--offline]                cache-only; refuse live HTTP
    [--insecure]               skip repomd signature verification
    [--upstream <host>]        default kojipkgs.fedoraproject.org
    [--rate-ms <int>]          per-host min delay; default 1000
    [--signature-backend <external-gpg|fingerprint-allowlist>]
    [--strict-closure]         turn unresolved requires into errors

Examples:
  repro-harvest-dnf --source dnf:htop@fedora/39:20260601 \
                    --output-dir recipes/catalog/foreign
  repro-harvest-dnf --source dnf:{htop,neovim}@fedora/39:20260601 \
                    --output-dir recipes/catalog/foreign --offline
"""

when isMainModule:
  let args = try:
    parseArgs()
  except CliError as ex:
    if ex.msg == "HELP":
      printHelp()
      quit(0)
    stderr.writeLine "error: ", ex.msg
    printHelp()
    quit(1)

  try:
    runHarvest(args)
  except CliError as ex:
    stderr.writeLine "error: ", ex.msg
    quit(1)
  except SignatureVerificationError as ex:
    stderr.writeLine "signature verification failed: ", ex.msg
    stderr.writeLine "(backend=", ex.backend, ", log=", ex.backendLog,
      ")"
    quit(2)
  except FetchError as ex:
    stderr.writeLine "fetch error: ", ex.msg, " (url=", ex.url, ")"
    quit(3)
  except DnfIndexParseError as ex:
    stderr.writeLine "index parse error: ", ex.msg
    quit(4)
  except DnfClosureError as ex:
    stderr.writeLine "closure resolution error: ", ex.msg, " (root=",
      ex.rootPackage, " missing=", ex.missingDep, ")"
    quit(4)
  except IOError as ex:
    stderr.writeLine "I/O error: ", ex.msg
    quit(5)
  except CatchableError as ex:
    stderr.writeLine "unexpected error: ", ex.msg
    quit(5)
