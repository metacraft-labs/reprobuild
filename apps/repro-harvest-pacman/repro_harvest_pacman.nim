## D2 P2: ``repro-harvest-pacman`` — Arch Linux pacman harvester.
##
## Mirrors the apt + dnf harvester structures:
##
##   1. Fetch ``<repo>.db`` (USTAR tarball) from the snapshot host.
##   2. Verify the signature (external-gpg detached or vendored
##      allowlist).
##   3. Parse the desc files, walk the transitive closure of the
##      requested package(s), emit one C1-format catalog file per
##      package in the union closure.
##
## ## Command-line surface
##
##   repro-harvest-pacman
##     --source pacman:<pkgs>@<distro>/<release>:<snapshot>
##     --output-dir <path>          (required)
##     --cache-dir  <path>          (HTTP cache; default
##                                   ``$TMP/repro-harvest-pacman-cache``)
##     --gpg-keys   <path>          (key-bundle dir; default
##                                   ``recipes/catalog/foreign/pacman/keys/``)
##     --offline                    (refuse live HTTP; cache-only)
##     --insecure                   (skip db signature verification)
##     --upstream  <host>           (default archive.archlinux.org)
##     --repo      <name>           (default ``core``; also ``extra``,
##                                   ``community``)
##     --rate-ms   <int>            (per-host min delay; default 1000)
##     --signature-backend external-gpg | fingerprint-allowlist
##     --allow-unresolved           (default off — pacman repos are
##                                   internally consistent; an
##                                   unresolved dep usually means a
##                                   missing alternate repo)
##
## ## Exit codes
##
##   0  — success; catalog files written.
##   1  — argument parsing / spec validation failure.
##   2  — signature verification failure.
##   3  — network / cache failure.
##   4  — index parsing / closure-walk failure.
##   5  — catalog emission failure.

import std/[options, os, strutils, tables]

import blake3

import repro_dsl_stdlib/packages/foreign_pacman
import repro_dsl_stdlib/packages/pacman_index
import repro_system_apply/types as sysTypes
import repro_binary_cache_server/types as bcsTypes

# Reuse the apt harvester's generic HTTP-cache + decompression utility.
import repro_harvest_apt/fetch as apt_fetch

import repro_harvest_pacman/signature
import repro_harvest_pacman/source_spec

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
    repoName: string
    rateMs: int
    signatureBackend: SignatureBackend
    allowUnresolved: bool

  CliError = object of CatchableError

proc defaultCacheDir(): string =
  getTempDir() / "repro-harvest-pacman-cache"

proc parseArgs(argv: seq[string] = commandLineParams()):
    HarvesterArgs =
  result.upstream = DefaultUpstream
  result.repoName = "core"
  result.rateMs = 1000
  result.signatureBackend = sbExternalGpg
  result.allowUnresolved = false

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
    of "repo":
      result.repoName = if hasInline: val else: nextValue(flag)
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
  let raw = blake3.digest("repro-harvest-pacman:dev:" & path)
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

proc fetchAndVerifyIndex(client: FetchClient; spec: PacmanSourceSpec;
                        keyBundleDir: string;
                        preferredBackend: SignatureBackend;
                        insecure: bool; upstream, repoName: string):
    seq[PacmanPackageRecord] =
  let url = repoDbUrl(spec, upstream, repoName)
  stderr.writeLine "fetch: ", url
  let dbFetch = fetchUrl(client, url)

  # Optional detached sig at <url>.sig.
  var sigBytes = ""
  if preferredBackend == sbExternalGpg and not insecure:
    let sigUrl = url & ".sig"
    try:
      let sig = fetchUrl(client, sigUrl)
      sigBytes = sig.bytes
    except CatchableError:
      stderr.writeLine "note: no detached sig at ", sigUrl,
        "; falling back to allowlist backend"

  if insecure:
    stderr.writeLine "WARNING: --insecure was passed; skipping " &
      "repo-db signature verification"
  else:
    let verification = verifyRepoDb(dbFetch.bytes, keyBundleDir,
      sigBytes = sigBytes, preferredBackend = preferredBackend)
    stderr.writeLine "repo db verified via " & $verification.backend &
      " (signer=" & verification.signerKeyId & ")"

  # Decompress gzip if needed.
  var raw = dbFetch.bytes
  if isGzip(raw):
    raw = apt_fetch.maybeDecompress(raw, url & ".gz")

  result = parseRepoDb(raw)
  stderr.writeLine "parsed ", result.len,
    " package records from ", repoName, ".db"

# ---------------------------------------------------------------------------
# Catalog emission
# ---------------------------------------------------------------------------

proc poolUrlFor(spec: PacmanSourceSpec; rec: PacmanPackageRecord;
               upstream, repoName: string): string =
  snapshotBaseUrl(spec, upstream, repoName) & "/" & rec.filename

proc mkCatalogForRecord(spec: PacmanSourceSpec; upstream, repoName: string;
                       rec: PacmanPackageRecord;
                       perRecordClosure: seq[PacmanPackageRecord]):
    ForeignCatalog =
  let snapPin = canonicalSnapshotPin(spec)
  result.formatVersion = ForeignCatalogFormatVersion
  result.package = mkForeignPackageRef("pacman", rec.name, snapPin)
  result.version = rec.version
  result.provisioningMethods = @[
    ForeignProvisioningMethod(
      kind: fpkDirectSnapshotUrl,
      url: poolUrlFor(spec, rec, upstream, repoName),
      sha256: rec.sha256,
      sizeBytes: rec.csize,
    )
  ]
  for d in perRecordClosure:
    if d.name == rec.name: continue
    result.dependencyClosure.add(
      mkForeignPackageRef("pacman", d.name, snapPin))

# ---------------------------------------------------------------------------
# Main harvester driver
# ---------------------------------------------------------------------------

proc runHarvest*(args: HarvesterArgs) =
  let spec = parsePacmanSourceSpec(args.source)
  let keyDir = resolveKeyBundleDir(args.gpgKeys)

  let client = newFetchClient(args.cacheDir,
    minIntervalMs = args.rateMs, offline = args.offline)

  let records = fetchAndVerifyIndex(client, spec, keyDir,
    args.signatureBackend, args.insecure, args.upstream,
    args.repoName)
  let index = buildPacmanIndex(records)

  for pkg in spec.packages:
    if pkg notin index.byName:
      raise newException(PacmanClosureError,
        "requested root package '" & pkg & "' is not in the " &
        "snapshot's repo db")

  let closure = resolveMultiClosure(spec.packages, index,
    allowUnresolved = args.allowUnresolved)
  stderr.writeLine "closure: ", closure.len, " packages (",
    spec.packages.len, " roots)"

  let pacDir = args.outputDir / "pacman"
  createDir(pacDir)

  let harvRev = harvesterBinaryRevision()
  let hostPlatform = PlatformTriple(
    cpu: "x86_64", os: "linux", abi: "gnu",
    libcVariant: "")

  var emitted = 0
  for rec in closure:
    let recOwn = resolveClosure(rec.name, index,
      allowUnresolved = args.allowUnresolved)
    var catalog = mkCatalogForRecord(spec, args.upstream, args.repoName,
      rec, recOwn)
    let provRev = canonicalCatalogProviderRevision(catalog)
    discard foreignPackageIdentity(catalog, hostPlatform,
      harvesterRevision = harvRev,
      providerRevision = provRev,
      resolver = noopDepResolver)
    let outPath = pacDir / (rec.name & ".json")
    writeForeignCatalog(catalog, outPath)
    inc emitted

  stderr.writeLine "wrote ", emitted, " catalog files under ", pacDir

  let resolver = mkOnDiskCatalogResolver(args.outputDir)
  for rec in closure:
    if rec.name notin spec.packages: continue
    let catalogPath = pacDir / (rec.name & ".json")
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
    pacDir

proc printHelp() =
  echo """repro-harvest-pacman — Arch Linux pacman harvester (D2 P2)

Usage:
  repro-harvest-pacman
    --source pacman:<pkgs>@<distro>/<release>:<snapshot>
    --output-dir <path>
    [--cache-dir <path>]       default $TMP/repro-harvest-pacman-cache
    [--gpg-keys <path>]        default recipes/catalog/foreign/pacman/keys/
    [--offline]                cache-only; refuse live HTTP
    [--insecure]               skip db signature verification
    [--upstream <host>]        default archive.archlinux.org
    [--repo <name>]            default core
    [--rate-ms <int>]          per-host min delay; default 1000
    [--signature-backend <external-gpg|fingerprint-allowlist>]
    [--allow-unresolved]       tolerate unresolved deps in closure walk

Examples:
  repro-harvest-pacman --source pacman:htop@archlinux/rolling:20260601 \
                       --output-dir recipes/catalog/foreign
  repro-harvest-pacman --source pacman:{htop,fzf}@archlinux/rolling:20260601 \
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
  except PacmanIndexParseError as ex:
    stderr.writeLine "index parse error: ", ex.msg
    quit(4)
  except PacmanClosureError as ex:
    stderr.writeLine "closure resolution error: ", ex.msg, " (root=",
      ex.rootPackage, " missing=", ex.missingDep, ")"
    quit(4)
  except IOError as ex:
    stderr.writeLine "I/O error: ", ex.msg
    quit(5)
  except CatchableError as ex:
    stderr.writeLine "unexpected error: ", ex.msg
    quit(5)
