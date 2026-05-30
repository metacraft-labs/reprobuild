## VersionedProvisioning schema (M63 — first milestone of the
## ``Builtin-Catalog-And-Home-Profile-Provisioning`` campaign).
##
## Each ``packages/<tool>.nim`` may expose, alongside its existing
## ``package <tool>:`` block, a top-level
## ``<tool>Catalog: seq[VersionedProvisioning]`` literal carrying one
## record per coexisting version (e.g. JDK 21.0.5, 17.0.13, 11.0.25 in a
## single ``packages/jdk.nim``). The records are **purely declarative**:
## M63 ships the field shape only; the M64 ``cakBuiltin`` adapter is the
## first consumer.
##
## **Per-platform variant shape.** A single ``VersionedProvisioning``
## carries the cross-platform metadata (``version``, ``archive_format``,
## ``bin_relpath``, ``install_method``, ``env``) at the top level and a
## ``platforms: seq[PlatformBinary]`` slice for the per-(cpu, os)
## download URL + digest + inner-dir flatten path. This shape:
##
##   * matches the JDK case (same archive format + binary relpath across
##     ``x86_64-windows`` and ``aarch64-windows``, different URLs +
##     SHA-256s + extract paths);
##   * keeps the common case compact (one record per version);
##   * lets a downstream realize loop iterate ``platforms`` to pick the
##     entry whose ``cpu`` / ``os`` matches the current host (M64);
##   * mirrors the spec's permissive guidance ("Pick a shape …") with
##     the simplest design that supports M64 without locking the
##     campaign into a Table API.
##
## **SHA validation.** Exactly one of ``sha256`` / ``sha512`` is
## required per ``PlatformBinary``. ``validateVersionedProvisioning``
## (called from the M63 unit tests; will also be called from the M64
## realize loop) returns a structured error list rather than raising,
## so the harvester (M66) can batch-validate the whole catalog and
## emit a single diagnostic report.
##
## **Honest scope.** M63 ships the data types + a runtime validator
## only. No realize logic, no harvester, no DSL macro integration with
## ``repro_project_dsl``. ``packages/<tool>.nim`` files declare the
## catalog as an ordinary ``let <tool>Catalog* = @[...]`` literal next
## to the existing ``package`` block — both coexist without
## modification. The M67/M68 bulk-populate milestones will add catalog
## entries to every existing ``packages/*.nim``; in M63 only
## ``packages/jdk.nim`` carries a real entry (as the M49 reference).

import std/tables

type
  ArchiveFormat* = enum
    ## How the downloaded artifact is unpacked. ``afRaw`` is the
    ## "download a single binary, no extraction" case (e.g. a static
    ## ``rg.exe``). ``afInstallerNsis`` / ``afInstallerMsi`` mark
    ## installers that run silently via ``imInstallerSilent``.
    afZip = "zip"
    afTarGz = "tar.gz"
    afTarXz = "tar.xz"
    afTarBz2 = "tar.bz2"
    afSevenZip = "7z"
    afInstallerNsis = "installer-nsis"
    afInstallerMsi = "installer-msi"
    afRaw = "raw"

  InstallMethod* = enum
    ## How the realize loop turns the verified artifact into a usable
    ## prefix on disk. ``imExtract`` is the default common case; the
    ## other three mirror the M49–M62 ad-hoc installer / pacman /
    ## bootstrap-build escape hatches the campaign needs.
    imExtract = "extract"
    imInstallerSilent = "installer-silent"
    imMsys2Pacman = "msys2-pacman"
    imSourceBootstrap = "source-bootstrap"

  PlatformCpu* = enum
    ## Coarse CPU enum. Matches the ``cpu_arch`` tokens the
    ## reprobuild runtime already uses (see
    ## ``repro_core``). The ``pcAny`` variant is reserved for
    ## architecture-independent artifacts (rare — most installers are
    ## arch-specific even on Windows).
    pcAny = "any"
    pcX86_64 = "x86_64"
    pcAArch64 = "aarch64"
    pcX86 = "x86"

  PlatformOs* = enum
    poAny = "any"
    poWindows = "windows"
    poLinux = "linux"
    poMacos = "macos"

  PlatformBinary* = object
    ## Per-(cpu, os) download slice: one URL + one digest + one
    ## extract-path. The ``extract_path`` is the inner directory the
    ## archive ships under (e.g. ``jdk-21.0.5+11`` for the Adoptium
    ## JDK zip); the realize loop flattens it so the realized prefix
    ## carries ``bin/javac.exe`` directly. Empty ``extract_path`` =
    ## no inner dir.
    cpu*: PlatformCpu
    os*: PlatformOs
    url*: string
    sha256*: string        ## hex-encoded; empty if sha512 is set
    sha512*: string        ## hex-encoded; empty if sha256 is set
    extract_path*: string  ## inner-dir to strip; "" = none

  VersionedProvisioning* = object
    ## One coexisting version of a tool. The campaign author writes
    ## newest-first so the LAST entry in ``<tool>Catalog`` is the
    ## ``defaultVersion`` (M64 may surface an explicit
    ## ``defaultVersion`` selector — for M63 the array order is the
    ## convention).
    version*: string                  ## semver pin, e.g. "21.0.5"
    archive_format*: ArchiveFormat
    install_method*: InstallMethod
    bin_relpath*: seq[string]         ## relpaths within the realized prefix
                                      ## (e.g. @["bin/javac.exe"])
    platforms*: seq[PlatformBinary]   ## per-(cpu, os) download variants
    installer_args*: seq[string]      ## for imInstallerSilent
    pacman_packages*: seq[string]     ## for imMsys2Pacman
    bootstrap_argv*: seq[string]      ## for imSourceBootstrap
    env*: Table[string, string]       ## per-tool env vars; values may
                                      ## reference the realized prefix
                                      ## via ``${prefix}`` (the M64
                                      ## realizer substitutes)

# ---------------------------------------------------------------------------
# Construction helpers
# ---------------------------------------------------------------------------

proc initPlatformBinary*(cpu: PlatformCpu; os: PlatformOs; url: string;
                         sha256 = ""; sha512 = "";
                         extract_path = ""): PlatformBinary =
  PlatformBinary(
    cpu: cpu, os: os, url: url,
    sha256: sha256, sha512: sha512,
    extract_path: extract_path)

proc initVersionedProvisioning*(version: string;
                                archive_format: ArchiveFormat;
                                install_method = imExtract;
                                bin_relpath: seq[string] = @[];
                                platforms: seq[PlatformBinary] = @[];
                                installer_args: seq[string] = @[];
                                pacman_packages: seq[string] = @[];
                                bootstrap_argv: seq[string] = @[];
                                env: openArray[(string, string)] = []):
    VersionedProvisioning =
  result = VersionedProvisioning(
    version: version,
    archive_format: archive_format,
    install_method: install_method,
    bin_relpath: bin_relpath,
    platforms: platforms,
    installer_args: installer_args,
    pacman_packages: pacman_packages,
    bootstrap_argv: bootstrap_argv,
    env: initTable[string, string]())
  for pair in env:
    result.env[pair[0]] = pair[1]

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------
#
# Validation runs at construction or test time. Returns a list of
# error strings so the M66 harvester can batch-validate the whole
# catalog in one pass. An empty result means the record is
# well-formed.

proc validatePlatformBinary*(pb: PlatformBinary; index: int):
    seq[string] =
  let prefix = "platforms[" & $index & "] (" & $pb.cpu & "-" & $pb.os & "): "
  if pb.url.len == 0:
    result.add(prefix & "url is required")
  if pb.sha256.len == 0 and pb.sha512.len == 0:
    result.add(prefix & "at least one of sha256 / sha512 is required")
  if pb.sha256.len > 0 and pb.sha512.len > 0:
    result.add(prefix & "only one of sha256 / sha512 may be set")
  if pb.sha256.len > 0 and pb.sha256.len != 64:
    result.add(prefix & "sha256 must be a 64-char hex digest (got " &
      $pb.sha256.len & " chars)")
  if pb.sha512.len > 0 and pb.sha512.len != 128:
    result.add(prefix & "sha512 must be a 128-char hex digest (got " &
      $pb.sha512.len & " chars)")
  for ch in pb.sha256:
    if ch notin {'0'..'9', 'a'..'f', 'A'..'F'}:
      result.add(prefix & "sha256 must be hex-encoded (offending char: '" &
        $ch & "')")
      break
  for ch in pb.sha512:
    if ch notin {'0'..'9', 'a'..'f', 'A'..'F'}:
      result.add(prefix & "sha512 must be hex-encoded (offending char: '" &
        $ch & "')")
      break

proc validateVersionedProvisioning*(vp: VersionedProvisioning):
    seq[string] =
  ## Returns a list of validation errors; an empty result means the
  ## record is well-formed. Validation rules:
  ##   * ``version`` non-empty;
  ##   * at least one ``platforms`` entry;
  ##   * every platform entry passes ``validatePlatformBinary``;
  ##   * no duplicate (cpu, os) pairs in ``platforms``;
  ##   * ``imInstallerSilent`` records have at least one
  ##     ``installer_args`` entry (the silent flag);
  ##   * ``imMsys2Pacman`` records have at least one ``pacman_packages``
  ##     entry;
  ##   * ``imSourceBootstrap`` records have a non-empty ``bootstrap_argv``;
  ##   * ``imExtract`` records have at least one ``bin_relpath`` entry
  ##     (otherwise the realized prefix exposes no binary).
  if vp.version.len == 0:
    result.add("version is required")
  if vp.platforms.len == 0:
    result.add("at least one platforms[] entry is required")
  var seenPairs: seq[string] = @[]
  for i, pb in vp.platforms:
    result.add(validatePlatformBinary(pb, i))
    let key = $pb.cpu & "-" & $pb.os
    if key in seenPairs:
      result.add("platforms[" & $i & "]: duplicate (cpu, os) pair '" &
        key & "'")
    seenPairs.add(key)
  case vp.install_method
  of imExtract:
    if vp.bin_relpath.len == 0:
      result.add("install_method=imExtract requires at least one " &
        "bin_relpath entry")
  of imInstallerSilent:
    if vp.installer_args.len == 0:
      result.add("install_method=imInstallerSilent requires at least " &
        "one installer_args entry (the silent flag)")
  of imMsys2Pacman:
    if vp.pacman_packages.len == 0:
      result.add("install_method=imMsys2Pacman requires at least one " &
        "pacman_packages entry")
  of imSourceBootstrap:
    if vp.bootstrap_argv.len == 0:
      result.add("install_method=imSourceBootstrap requires a " &
        "non-empty bootstrap_argv")

proc validateCatalog*(entries: openArray[VersionedProvisioning]):
    seq[string] =
  ## Validate a whole ``<tool>Catalog`` array. Each error is prefixed
  ## with the entry's version so the diagnostic locates the bad slice.
  var seenVersions: seq[string] = @[]
  for i, vp in entries:
    for err in validateVersionedProvisioning(vp):
      result.add("entries[" & $i & "] (version=" & vp.version & "): " & err)
    if vp.version.len > 0:
      if vp.version in seenVersions:
        result.add("entries[" & $i & "]: duplicate version '" &
          vp.version & "'")
      seenVersions.add(vp.version)

# ---------------------------------------------------------------------------
# Per-platform resolution
# ---------------------------------------------------------------------------

proc selectPlatformBinary*(vp: VersionedProvisioning;
                           cpu: PlatformCpu; os: PlatformOs):
    tuple[found: bool; binary: PlatformBinary] =
  ## Pick the ``PlatformBinary`` for the (cpu, os) tuple. Resolution
  ## order:
  ##   1. exact match (cpu, os);
  ##   2. (pcAny, os) fallback;
  ##   3. (cpu, poAny) fallback;
  ##   4. (pcAny, poAny) fallback.
  ## Returns ``(false, PlatformBinary())`` if no entry matches.
  for pb in vp.platforms:
    if pb.cpu == cpu and pb.os == os:
      return (true, pb)
  for pb in vp.platforms:
    if pb.cpu == pcAny and pb.os == os:
      return (true, pb)
  for pb in vp.platforms:
    if pb.cpu == cpu and pb.os == poAny:
      return (true, pb)
  for pb in vp.platforms:
    if pb.cpu == pcAny and pb.os == poAny:
      return (true, pb)
  (false, PlatformBinary())

proc selectDefault*(catalog: openArray[VersionedProvisioning]):
    tuple[found: bool; entry: VersionedProvisioning] =
  ## Pick the default version: the LAST entry in the array (the
  ## campaign author writes newest-first). Returns ``(false, ...)``
  ## for an empty catalog.
  if catalog.len == 0:
    return (false, VersionedProvisioning())
  (true, catalog[catalog.len - 1])

proc selectVersion*(catalog: openArray[VersionedProvisioning];
                    version: string):
    tuple[found: bool; entry: VersionedProvisioning] =
  ## Pick the entry whose ``version`` exactly equals ``version`` (no
  ## semver-range parsing in v1; M65 may add it).
  for vp in catalog:
    if vp.version == version:
      return (true, vp)
  (false, VersionedProvisioning())

# ---------------------------------------------------------------------------
# Serialization helpers (for the M66 harvester + the M64 receipt schema)
# ---------------------------------------------------------------------------
#
# ``serializeAsCode`` emits a Nim source fragment that round-trips
# back to an identical ``VersionedProvisioning`` value when evaluated
# under this module. Used by the M66 harvester to write
# ``packages/<tool>.nim`` files byte-identically across re-runs (the
# spec's "idempotent harvest" requirement) and exercised by the M63
# tests as a cheap round-trip serialization check.

proc escapeString(s: string): string =
  result = "\""
  for ch in s:
    case ch
    of '\\': result.add("\\\\")
    of '"': result.add("\\\"")
    of '\n': result.add("\\n")
    of '\r': result.add("\\r")
    of '\t': result.add("\\t")
    else: result.add(ch)
  result.add("\"")

proc cpuIdent(cpu: PlatformCpu): string =
  case cpu
  of pcAny: "pcAny"
  of pcX86_64: "pcX86_64"
  of pcAArch64: "pcAArch64"
  of pcX86: "pcX86"

proc osIdent(os: PlatformOs): string =
  case os
  of poAny: "poAny"
  of poWindows: "poWindows"
  of poLinux: "poLinux"
  of poMacos: "poMacos"

proc archiveFormatIdent(af: ArchiveFormat): string =
  case af
  of afZip: "afZip"
  of afTarGz: "afTarGz"
  of afTarXz: "afTarXz"
  of afTarBz2: "afTarBz2"
  of afSevenZip: "afSevenZip"
  of afInstallerNsis: "afInstallerNsis"
  of afInstallerMsi: "afInstallerMsi"
  of afRaw: "afRaw"

proc installMethodIdent(im: InstallMethod): string =
  case im
  of imExtract: "imExtract"
  of imInstallerSilent: "imInstallerSilent"
  of imMsys2Pacman: "imMsys2Pacman"
  of imSourceBootstrap: "imSourceBootstrap"

proc serializePlatformBinary(pb: PlatformBinary): string =
  result = "PlatformBinary(cpu: " & cpuIdent(pb.cpu) &
    ", os: " & osIdent(pb.os) &
    ", url: " & escapeString(pb.url) &
    ", sha256: " & escapeString(pb.sha256) &
    ", sha512: " & escapeString(pb.sha512) &
    ", extract_path: " & escapeString(pb.extract_path) & ")"

proc serializeAsCode*(vp: VersionedProvisioning): string =
  ## Emit a Nim source fragment that constructs an equivalent
  ## ``VersionedProvisioning`` value. The result evaluates under this
  ## module's symbol table (the enum literals are unqualified —
  ## callers ``import repro_dsl_stdlib/packages_schema`` to bring them
  ## into scope).
  result = "VersionedProvisioning(\n"
  result.add("  version: " & escapeString(vp.version) & ",\n")
  result.add("  archive_format: " & archiveFormatIdent(vp.archive_format) & ",\n")
  result.add("  install_method: " & installMethodIdent(vp.install_method) & ",\n")
  result.add("  bin_relpath: @[")
  for i, b in vp.bin_relpath:
    if i > 0: result.add(", ")
    result.add(escapeString(b))
  result.add("],\n  platforms: @[\n")
  for i, pb in vp.platforms:
    result.add("    " & serializePlatformBinary(pb))
    if i + 1 < vp.platforms.len:
      result.add(",")
    result.add("\n")
  result.add("  ],\n  installer_args: @[")
  for i, a in vp.installer_args:
    if i > 0: result.add(", ")
    result.add(escapeString(a))
  result.add("],\n  pacman_packages: @[")
  for i, p in vp.pacman_packages:
    if i > 0: result.add(", ")
    result.add(escapeString(p))
  result.add("],\n  bootstrap_argv: @[")
  for i, a in vp.bootstrap_argv:
    if i > 0: result.add(", ")
    result.add(escapeString(a))
  result.add("],\n  env: {")
  # Sort env keys for deterministic output (M66 harvester
  # idempotence requirement).
  var keys: seq[string] = @[]
  for k in vp.env.keys:
    keys.add(k)
  # std/algorithm.sort would pull a larger import — bubble sort the
  # typically-small env table by hand.
  for i in 0 ..< keys.len:
    for j in i + 1 ..< keys.len:
      if keys[j] < keys[i]:
        let tmp = keys[i]
        keys[i] = keys[j]
        keys[j] = tmp
  for i, k in keys:
    if i > 0: result.add(", ")
    result.add(escapeString(k) & ": " & escapeString(vp.env[k]))
  result.add("}.toTable())")
