## C2 P1: ``repro-harvest-apt`` — Debian apt foreign-package harvester.
##
## Drives the four C2 deliverable phases for a single ``--source``
## invocation:
##
##   1. Fetch the snapshot's ``InRelease`` + ``Packages.xz``.
##   2. Verify the GPG signature against the vendored key bundle.
##   3. Parse the index, walk the transitive ``Depends:`` closure of
##      the requested package(s), gather every dep's ``.deb`` URL +
##      sha256 + version.
##   4. Emit one C1-format catalog file per package in the union
##      closure, with real per-dep ``CacheEntryKey`` hex via the
##      foreign_common composer + the harvester's own sha256 +
##      providerRevision (closes C1 risks 1 + 2).
##
## ## Command-line surface
##
##   repro-harvest-apt
##     --source apt:<pkgs>@<distro>/<suite>:<snapshot>
##     --output-dir <path>          (where catalog files land; required)
##     --cache-dir  <path>          (HTTP cache; default
##                                   ``$TMP/repro-harvest-apt-cache``)
##     --gpg-keys   <path>          (key-bundle dir; default
##                                   ``recipes/catalog/foreign/apt/keys/``)
##     --offline                    (refuse live HTTP; cache-only)
##     --insecure                   (skip signature verification; logs
##                                   a warning to stderr — intended for
##                                   local fixture-driven tests, not
##                                   production)
##     --component <name>           (apt component; default ``main``)
##     --arch      <name>           (Debian arch; default ``amd64``)
##     --rate-ms   <int>            (per-host min delay; default 1000)
##     --signature-backend external-gpg | fingerprint-allowlist
##                                  (preferred verification backend)
##
## ## Exit codes
##
##   0  — success; catalog files written.
##   1  — argument parsing / spec validation failure.
##   2  — signature verification failure (anti-tamper).
##   3  — network / cache failure.
##   4  — index parsing / closure-walk failure.
##   5  — catalog emission failure (I/O error on write).
##
## ## Why ``repro-harvest-apt`` instead of folding into ``repro``
##
## The harvester is rarely invoked by operators directly; the realize
## pipeline calls it once per snapshot. Keeping it standalone lets the
## binary be content-addressed independently of the much larger
## ``repro`` binary — its sha256 is the C2 ``harvesterRevision`` input
## the foreign_common composer feeds into the catalog identity.

import std/[options, os, strutils, tables]

import blake3

import repro_dsl_stdlib/packages/foreign_apt
import repro_dsl_stdlib/packages/apt_index
import repro_system_apply/types as sysTypes
import repro_binary_cache_server/types as bcsTypes

import repro_harvest_apt/fetch
import repro_harvest_apt/signature
import repro_harvest_apt/source_spec

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
    component: string
    arch: string
    rateMs: int
    signatureBackend: SignatureBackend

  CliError = object of CatchableError

proc defaultCacheDir(): string =
  getTempDir() / "repro-harvest-apt-cache"

proc parseArgs(argv: seq[string] = commandLineParams()):
    HarvesterArgs =
  ## Parse the harvester's command-line into a typed record. Accepts
  ## both ``--key value`` and ``--key=value`` forms by walking the
  ## argument array manually (Nim's std/parseopt only supports the
  ## attached form, which is too restrictive for the apt-source spec
  ## whose value carries ``:`` and ``@`` punctuation).
  result.component = "main"
  result.arch = "amd64"
  result.rateMs = 1000
  result.signatureBackend = sbExternalGpg

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
    of "component":
      result.component = if hasInline: val else: nextValue(flag)
    of "arch":
      result.arch = if hasInline: val else: nextValue(flag)
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
  ## SHA-256 of the harvester binary's own bytes — the C2 P5
  ## ``harvesterRevision`` input to the foreign_common composer.
  ## Implemented as ``sha256(getAppFilename())`` so identical binaries
  ## produce identical catalogs.
  ##
  ## Fallback: when the binary cannot be read (e.g. when running from
  ## ``nim r`` against a transient compiler output), we emit a
  ## deterministic placeholder derived from the BLAKE3 of the source
  ## path. This preserves byte-stable harvesting from a Nim test
  ## context.
  let path = try: getAppFilename() except: ""
  if path.len > 0 and fileExists(path):
    try:
      return sha256HexStr(readFile(path))
    except CatchableError:
      discard
  # Test/transient fallback.
  let raw = blake3.digest("repro-harvest-apt:dev:" & path)
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
  ## Returns a resolver that reads dep catalog files from disk under
  ## ``catalogRoot/<distro>/<name>.json``. Used by the harvester after
  ## it writes the closure's catalogs so the parent's identity is
  ## composed against the real per-dep identities.
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

proc parseSha256ForFile(payload: string; relPath: string): string =
  ## Look up the InRelease's SHA256: line for ``relPath`` (relative to
  ## the suite root, e.g. ``main/binary-amd64/Packages.xz``).
  ## Returns "" if not found.
  var inSha = false
  for raw in payload.splitLines:
    let line = raw
    if line.startsWith("SHA256:"):
      inSha = true
      continue
    if inSha:
      if line.len == 0 or (line[0] != ' ' and line[0] != '\t'):
        inSha = false
        continue
      let parts = line.strip().splitWhitespace()
      if parts.len >= 3 and parts[2] == relPath:
        return parts[0].toLowerAscii()
  ""

proc fetchAndVerifyIndex(client: FetchClient; spec: AptSourceSpec;
                        keyBundleDir: string;
                        preferredBackend: SignatureBackend;
                        insecure: bool;
                        component: string; arch: string):
    seq[AptPackageRecord] =
  ## Fetch InRelease + Packages.<compression>, verify signatures, return
  ## the parsed records.
  stderr.writeLine "fetch: ", inReleaseUrl(spec)
  let inRel = fetchUrl(client, inReleaseUrl(spec))
  var payload = ""
  var sigBackend = sbExternalGpg
  if insecure:
    stderr.writeLine "WARNING: --insecure was passed; skipping " &
      "InRelease GPG verification"
    let parts = extractClearsignedPayload(inRel.bytes)
    payload = parts.payload
  else:
    let verification = verifyInRelease(inRel.bytes, keyBundleDir,
      preferredBackend = preferredBackend)
    payload = verification.payload
    sigBackend = verification.backend
    stderr.writeLine "InRelease verified via " & $sigBackend &
      " (signer=" & verification.signerKeyId & ")"

  # Try xz first, fall back to gz, then plain uncompressed Packages.
  # (Real snapshot.debian.org always carries xz + gz; the plain form is
  # for the fixture-driven test path.)
  let pkgPathXz = component & "/binary-" & arch & "/Packages.xz"
  let pkgPathGz = component & "/binary-" & arch & "/Packages.gz"
  let pkgPathPlain = component & "/binary-" & arch & "/Packages"
  var pkgUrl = packagesIndexUrl(spec, component, arch, "xz")
  var pkgRel = pkgPathXz
  var expectedSha = parseSha256ForFile(payload, pkgRel)
  if expectedSha.len == 0:
    pkgUrl = packagesIndexUrl(spec, component, arch, "gz")
    pkgRel = pkgPathGz
    expectedSha = parseSha256ForFile(payload, pkgRel)
  if expectedSha.len == 0:
    pkgUrl = spec.suiteBaseUrl & "/" & pkgPathPlain
    pkgRel = pkgPathPlain
    expectedSha = parseSha256ForFile(payload, pkgRel)
  if expectedSha.len == 0 and not insecure:
    raise newException(SignatureVerificationError,
      "InRelease has no SHA256 entry for " & pkgPathXz & ", " &
      pkgPathGz & ", or " & pkgPathPlain &
      "; cannot verify the Packages index")

  stderr.writeLine "fetch: ", pkgUrl
  let pkgFetch = fetchUrl(client, pkgUrl)
  if expectedSha.len > 0:
    let actual = sha256HexStr(pkgFetch.bytes)
    if actual != expectedSha:
      raise newException(SignatureVerificationError,
        "Packages index sha256 mismatch: expected " & expectedSha &
        ", got " & actual & " (url=" & pkgUrl & ")")

  let decompressed = maybeDecompress(pkgFetch.bytes, pkgUrl)
  result = parsePackagesIndex(decompressed)
  stderr.writeLine "parsed ", result.len, " package records from ",
    pkgRel

# ---------------------------------------------------------------------------
# Catalog emission
# ---------------------------------------------------------------------------

proc poolUrlFor(spec: AptSourceSpec; rec: AptPackageRecord): string =
  ## ``rec.filename`` is the relative path from the suite's pool root.
  spec.snapshotBaseUrl & "/" & rec.filename

proc mkCatalogForRecord(spec: AptSourceSpec;
                       rec: AptPackageRecord;
                       perRecordClosure: seq[AptPackageRecord]):
    ForeignCatalog =
  ## Build the in-memory ForeignCatalog for one harvested record. The
  ## ``perRecordClosure`` argument is the transitive closure of
  ## ``rec`` itself (NOT the union closure of the harvest request) —
  ## i.e. the deps the realize pipeline will need to bind-mount when
  ## the operator pulls THIS package into their FHS sandbox. Sharing
  ## the union across catalogs would (a) over-approximate the per-pkg
  ## bind set, and (b) cause the C2 recursive ``foreignPackageIdentity``
  ## composer to do combinatorial work on each parent's identity
  ## composition (every dep's catalog would carry every other package
  ## as its own dep, blowing the visited-set guard out from cycle
  ## protection to depth bounding).
  let snapPin = canonicalSnapshotPin(spec)
  result.formatVersion = ForeignCatalogFormatVersion
  result.package = mkForeignPackageRef("apt", rec.name, snapPin)
  result.version = rec.version
  result.provisioningMethods = @[
    ForeignProvisioningMethod(
      kind: fpkDirectSnapshotUrl,
      url: poolUrlFor(spec, rec),
      sha256: rec.sha256,
      sizeBytes: rec.sizeBytes,
    )
  ]
  for d in perRecordClosure:
    if d.name == rec.name: continue
    result.dependencyClosure.add(
      mkForeignPackageRef("apt", d.name, snapPin))

# ---------------------------------------------------------------------------
# Main harvester driver
# ---------------------------------------------------------------------------

proc runHarvest*(args: HarvesterArgs) =
  let spec = parseAptSourceSpec(args.source)
  if spec.distro notin ["debian", "ubuntu"]:
    raise newException(CliError,
      "C2 supports the 'debian' (and 'ubuntu') distros only; " &
      "got '" & spec.distro & "'")
  let keyDir = resolveKeyBundleDir(args.gpgKeys)

  let client = newFetchClient(args.cacheDir,
    minIntervalMs = args.rateMs, offline = args.offline)

  let records = fetchAndVerifyIndex(client, spec, keyDir,
    args.signatureBackend, args.insecure, args.component, args.arch)
  let index = buildAptIndex(records)

  # Validate every requested package is in the index BEFORE walking.
  for pkg in spec.packages:
    if pkg notin index.byName:
      raise newException(AptClosureError,
        "requested root package '" & pkg & "' is not in the " &
        "snapshot's Packages index")

  let closure = resolveMultiClosure(spec.packages, index)
  stderr.writeLine "closure: ", closure.len, " packages (",
    spec.packages.len, " roots)"

  # Catalog tree: write under <output-dir>/apt/<name>.json
  let aptDir = args.outputDir / "apt"
  createDir(aptDir)

  # First pass: write every catalog with the leaf-identity composer
  # (resolver returns none → leaf BLAKE3 of each dep). Required because
  # the on-disk resolver needs the dep files to exist.
  let harvRev = harvesterBinaryRevision()
  let hostPlatform = PlatformTriple(
    cpu: "x86_64", os: "linux", abi: "gnu",
    libcVariant: "")  # left blank; the realize pipeline binds the
                     # platform's libc at apply time

  var emitted = 0
  for rec in closure:
    # Per-record transitive closure: every dep this specific package
    # needs to function. The union closure of the harvest is the
    # operator's TOP-LEVEL realize set; each catalog's own dep list is
    # the bind-mount manifest the sandbox-launcher (C3) will consume.
    let recOwn = resolveClosure(rec.name, index)
    var catalog = mkCatalogForRecord(spec, rec, recOwn)
    # providerRevision is BLAKE3 of the canonical bytes
    # (closes risk #2). Catalog write must use this revision so the
    # composer + the catalog file agree.
    let provRev = canonicalCatalogProviderRevision(catalog)
    # Compose the identity once with the leaf-only resolver to get the
    # full hex (used only for the run log; the catalog file itself
    # carries the inputs, not the derived key, so callers can re-derive
    # at realize time).
    discard foreignPackageIdentity(catalog, hostPlatform,
      harvesterRevision = harvRev,
      providerRevision = provRev,
      resolver = noopDepResolver)
    let outPath = aptDir / (rec.name & ".json")
    writeForeignCatalog(catalog, outPath)
    inc emitted

  stderr.writeLine "wrote ", emitted, " catalog files under ", aptDir

  # Second pass: now that every dep's catalog file is on disk, re-compose
  # each root's identity through the on-disk resolver so the
  # parent-dep-key relationship is the C2-required recursive
  # ``CacheEntryKey`` shape. We log the resulting digest for diagnostics
  # but do NOT rewrite the catalog files (the inputs are stable; only
  # the derived key changes). Operators wanting the derived key can
  # invoke ``foreignPackageIdentity`` themselves via the same resolver.
  let resolver = mkOnDiskCatalogResolver(args.outputDir)
  for rec in closure:
    if rec.name notin spec.packages: continue
    let catalogPath = aptDir / (rec.name & ".json")
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
    aptDir

proc printHelp() =
  echo """repro-harvest-apt — Debian apt foreign-package harvester (C2)

Usage:
  repro-harvest-apt
    --source apt:<pkgs>@<distro>/<suite>:<snapshot>
    --output-dir <path>
    [--cache-dir <path>]       default $TMP/repro-harvest-apt-cache
    [--gpg-keys <path>]        default recipes/catalog/foreign/apt/keys/
    [--offline]                cache-only; refuse live HTTP
    [--insecure]               skip InRelease signature verification
    [--component <name>]       default 'main'
    [--arch <name>]            default 'amd64'
    [--rate-ms <int>]          per-host min delay; default 1000
    [--signature-backend <external-gpg|fingerprint-allowlist>]

Examples:
  repro-harvest-apt --source apt:git@debian/bookworm:20260601T000000Z \
                    --output-dir recipes/catalog/foreign
  repro-harvest-apt --source apt:{git,vim,curl}@debian/bookworm:20260601T000000Z \
                    --output-dir recipes/catalog/foreign \
                    --offline

Exit codes:
  0   success
  1   argument error
  2   signature verification failed
  3   network / cache error
  4   index parse / closure walk error
  5   catalog emission error
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
  except AptIndexParseError as ex:
    stderr.writeLine "index parse error: ", ex.msg
    quit(4)
  except AptClosureError as ex:
    stderr.writeLine "closure resolution error: ", ex.msg, " (root=",
      ex.rootPackage, " missing=", ex.missingDep, ")"
    quit(4)
  except IOError as ex:
    stderr.writeLine "I/O error: ", ex.msg
    quit(5)
  except CatchableError as ex:
    stderr.writeLine "unexpected error: ", ex.msg
    quit(5)
