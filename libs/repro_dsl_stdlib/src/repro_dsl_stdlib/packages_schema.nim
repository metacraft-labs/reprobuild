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
## **SHA validation.** Exactly one of ``sha256`` / ``sha512`` / ``sha1``
## is required per ``PlatformBinary``. ``validateVersionedProvisioning``
## (called from the M63 unit tests; will also be called from the M64
## realize loop) returns a structured error list rather than raising,
## so the harvester (M66) can batch-validate the whole catalog and
## emit a single diagnostic report. M1 (Realize-Closure spec) extended
## the schema to accept ``sha1`` as a *weak* hash — the harvester emits
## ``HHashAlgorithmWeak`` for it and the realize loop emits
## ``WSha1HashAccepted`` to stderr. ``sha1`` is accepted only because a
## handful of Scoop manifests (notably ``freepascal``) ship nothing
## stronger; operators should bump to ``sha256``/``sha512`` when the
## upstream manifest is upgraded. ``md5`` remains rejected.
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

# ---------------------------------------------------------------------------
# Schema warning hook
# ---------------------------------------------------------------------------
#
# M1 (Realize-Closure spec) wired a deprecation-warning sidechannel into
# the validator: a ``PlatformBinary`` populated with ONLY ``sha1`` (the
# weak case) is accepted but the validator emits a ``WSha1`` warning so
# operators see the deprecation at construction/test time. The default
# sink writes to ``stderr`` via ``logSchemaWarning``; the
# ``validateVersionedProvisioningEx`` overload also returns the warnings
# in a parallel ``seq[string]`` so test code can assert on them.

proc logSchemaWarning*(msg: string) =
  ## Default warning sink: stderr. Kept open for callers that want to
  ## reroute warnings (e.g. the harvester's diagnostic stream).
  stderr.writeLine(msg)

type
  ArchiveFormat* = enum
    ## How the downloaded artifact is unpacked. ``afRaw`` is the
    ## "download a single binary, no extraction" case (e.g. a static
    ## ``rg.exe``). ``afInstallerNsis`` / ``afInstallerMsi`` mark
    ## installers that run silently via ``imInstallerSilent``.
    ##
    ## M3 (Realize-Closure-And-Catalog-Expansion spec) added
    ## ``afSevenZipSfx`` — a 7z self-extracting archive (``.7z.exe`` /
    ## ``.exe#/dl.7z`` shape). The payload is structurally a 7z archive
    ## with a PE-SFX loader stub prepended; the 7z extractor transparently
    ## handles both raw .7z and SFX-wrapped .7z, so the realize-time
    ## dispatch is identical to ``afSevenZip`` plus the SFX classification
    ## marker.
    afZip = "zip"
    afTarGz = "tar.gz"
    afTarXz = "tar.xz"
    afTarBz2 = "tar.bz2"
    afSevenZip = "7z"
    afSevenZipSfx = "7z-sfx"
    afInstallerNsis = "installer-nsis"
    afInstallerMsi = "installer-msi"
    afRaw = "raw"

  InstallMethod* = enum
    ## How the realize loop turns the verified artifact into a usable
    ## prefix on disk. ``imExtract`` is the default common case; the
    ## other three mirror the M49–M62 ad-hoc installer / pacman /
    ## bootstrap-build escape hatches the campaign needs.
    ##
    ## M4 (Realize-Closure-And-Catalog-Expansion spec) added three
    ## variants for the Windows installer families:
    ##   * ``imInstallerMsi`` — extract an MSI via WiX ``dark.exe``
    ##     (decompile to a file tree; no global state, no installer
    ##     execution). The escape-hatch ``CAKBUILTIN_PREFER_MSIEXEC=1``
    ##     env var swaps the dark.exe path for ``msiexec /a TARGETDIR``.
    ##   * ``imInstallerNsisBundle`` — NSIS self-extracting executable
    ##     whose payload is one or more inner MSIs. Realize unwraps the
    ##     NSIS shell via 7z + dark, then per-MSI dark-extract + merge.
    ##   * ``imInstallerInnoSetup`` — Inno-Setup-built installer (the
    ##     freepascal shape, ``innosetup: true`` Scoop marker). Realize
    ##     dispatches via the discovered ``innounp.exe``.
    imExtract = "extract"
    imInstallerSilent = "installer-silent"
    imMsys2Pacman = "msys2-pacman"
    imSourceBootstrap = "source-bootstrap"
    imInstallerMsi = "installer-msi"
    imInstallerNsisBundle = "installer-nsis-bundle"
    imInstallerInnoSetup = "installer-inno-setup"

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
    sha256*: string        ## hex-encoded (64 chars); empty if another
                           ## digest is set
    sha512*: string        ## hex-encoded (128 chars); empty if another
                           ## digest is set
    sha1*: string          ## hex-encoded (40 chars); WEAK — accepted
                           ## only when the upstream manifest ships
                           ## nothing stronger (e.g. freepascal). The
                           ## harvester emits ``HHashAlgorithmWeak`` and
                           ## the M64 realize loop emits
                           ## ``WSha1HashAccepted`` to stderr.
    extract_path*: string  ## inner-dir to strip; "" = none
    nested_7z*: bool       ## M3: when true, after the outer extraction
                           ## the realize loop scans the extract dir for
                           ## ``*.7z`` files and recursively extracts each
                           ## in place (depth-bounded). Used for the
                           ## gcc/winlibs ``components-*.7z`` shape whose
                           ## payload is itself a sequence of inner .7z
                           ## archives (binutils + mingw-w64+gcc). The
                           ## harvester sets this when the manifest's
                           ## ``pre_install`` block explicitly performs the
                           ## nested extraction.
    msi_admin_install*: bool
                           ## M4: when true (and ``install_method`` is
                           ## ``imInstallerMsi``), the realize loop uses
                           ## ``msiexec /a <msi> /qn TARGETDIR=<dir>`` for
                           ## the extraction instead of WiX ``dark.exe``.
                           ## Operators may also flip the global default
                           ## via ``CAKBUILTIN_PREFER_MSIEXEC=1`` (see
                           ## ``builtin_adapter.nim``); this field is the
                           ## per-platform override for MSIs whose
                           ## custom-action table makes dark.exe fail
                           ## silent-skip in practice.

  PreInstallActionKind* = enum
    ## M3: a closed set of ``pre_install`` PowerShell shapes the
    ## cakBuiltin realize loop recognizes and replays programmatically
    ## (NOT via exec'ing PowerShell — that surface is too broad). The
    ## harvester translates matching ``pre_install`` lines into these
    ## actions; unmatched lines are captured verbatim in
    ## ``pre_install_unrecognized`` and surfaced as a
    ## ``WPreInstallUnrecognized`` warning at realize time.
    ##
    ## M4 extends the allowlist with three Windows installer family
    ## entries: ``Expand-DarkArchive``, ``Expand-MsiArchive``,
    ## ``Expand-InnoArchive``. These cover the python3 + swift Scoop
    ## ``installer.script`` patterns that the M3 spec-text deferred to
    ## M4.
    piaNewItemDir = "new-item-dir"        ## New-Item -ItemType Directory
    piaNewItemFile = "new-item-file"      ## New-Item -ItemType File
    piaCopyItem = "copy-item"             ## Copy-Item -Path A -Destination B [-Recurse]
    piaMoveItem = "move-item"             ## Move-Item -Path A -Destination B
    piaRemoveItem = "remove-item"         ## Remove-Item -Path A [-Recurse -Force]
    piaSetContent = "set-content"         ## Set-Content -Path A -Value "<literal>"
    piaAddPath = "add-path"               ## Scoop Add-Path builtin → env metadata only
    piaExpand7z = "expand-7z"             ## Expand-7zArchive / Expand-7ZipArchive
    piaExpandDark = "expand-dark"         ## M4: Expand-DarkArchive <msi> <dir>
    piaExpandMsi = "expand-msi"           ## M4: Expand-MsiArchive <msi> <dir>
    piaExpandInno = "expand-inno"         ## M4: Expand-InnoArchive <exe> <dir>

  PreInstallAction* = object
    ## M3: one structured ``pre_install`` action the realize loop
    ## replays. Path arguments are stored ``$dir``-relative (or
    ## ``${prefix}``-rewritten); the runner substitutes against the
    ## staged extract directory at apply time. ``source`` / ``target``
    ## are role-specific (Copy/Move use both; Remove + NewItem use
    ## ``target``; Set-Content uses ``target`` + ``literal``; Expand-7z
    ## uses ``source`` + ``target``).
    kind*: PreInstallActionKind
    source*: string          ## $dir-relative source (may contain * glob)
    target*: string          ## $dir-relative target
    recurse*: bool           ## Copy-Item -Recurse / Remove-Item -Recurse
    literal*: string         ## Set-Content -Value literal

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
    pre_install_actions*: seq[PreInstallAction]
                                      ## M3: ordered list of allowlisted
                                      ## ``pre_install`` actions the realize
                                      ## loop replays AFTER extraction. The
                                      ## harvester populates this from the
                                      ## Scoop manifest's ``pre_install``
                                      ## block when every line matches the
                                      ## allowlist; lines that do not match
                                      ## land in ``pre_install_unrecognized``.
    pre_install_unrecognized*: seq[string]
                                      ## M3: ``pre_install`` lines the
                                      ## harvester could not translate into
                                      ## an allowlisted ``PreInstallAction``.
                                      ## The realize loop emits one
                                      ## ``WPreInstallUnrecognized`` warning
                                      ## per line at apply time so the
                                      ## operator sees the gap. Realize does
                                      ## NOT fail closed on this — the rest
                                      ## of the install proceeds.

# ---------------------------------------------------------------------------
# Construction helpers
# ---------------------------------------------------------------------------

proc initPlatformBinary*(cpu: PlatformCpu; os: PlatformOs; url: string;
                         sha256 = ""; sha512 = ""; sha1 = "";
                         extract_path = "";
                         nested_7z = false;
                         msi_admin_install = false): PlatformBinary =
  PlatformBinary(
    cpu: cpu, os: os, url: url,
    sha256: sha256, sha512: sha512, sha1: sha1,
    extract_path: extract_path,
    nested_7z: nested_7z,
    msi_admin_install: msi_admin_install)

proc initVersionedProvisioning*(version: string;
                                archive_format: ArchiveFormat;
                                install_method = imExtract;
                                bin_relpath: seq[string] = @[];
                                platforms: seq[PlatformBinary] = @[];
                                installer_args: seq[string] = @[];
                                pacman_packages: seq[string] = @[];
                                bootstrap_argv: seq[string] = @[];
                                env: openArray[(string, string)] = [];
                                pre_install_actions: seq[PreInstallAction] = @[];
                                pre_install_unrecognized: seq[string] = @[]):
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
    env: initTable[string, string](),
    pre_install_actions: pre_install_actions,
    pre_install_unrecognized: pre_install_unrecognized)
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

proc validatePlatformBinaryEx*(pb: PlatformBinary; index: int;
                               warnings: var seq[string]):
    seq[string] =
  ## Returns the structured-error list AND populates ``warnings`` with
  ## non-fatal advisories (e.g. ``sha1`` weak-hash deprecation). See
  ## ``validatePlatformBinary`` for the error-only signature.
  let prefix = "platforms[" & $index & "] (" & $pb.cpu & "-" & $pb.os & "): "
  if pb.url.len == 0:
    result.add(prefix & "url is required")
  let hasSha256 = pb.sha256.len > 0
  let hasSha512 = pb.sha512.len > 0
  let hasSha1   = pb.sha1.len > 0
  let digestCount =
    (if hasSha256: 1 else: 0) +
    (if hasSha512: 1 else: 0) +
    (if hasSha1: 1 else: 0)
  if digestCount == 0:
    result.add(prefix &
      "at least one of sha256 / sha512 / sha1 is required")
  if digestCount > 1:
    result.add(prefix &
      "only one of sha256 / sha512 / sha1 may be set")
  if hasSha256 and pb.sha256.len != 64:
    result.add(prefix & "sha256 must be a 64-char hex digest (got " &
      $pb.sha256.len & " chars)")
  if hasSha512 and pb.sha512.len != 128:
    result.add(prefix & "sha512 must be a 128-char hex digest (got " &
      $pb.sha512.len & " chars)")
  if hasSha1 and pb.sha1.len != 40:
    result.add(prefix & "sha1 must be a 40-char hex digest (got " &
      $pb.sha1.len & " chars)")
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
  for ch in pb.sha1:
    if ch notin {'0'..'9', 'a'..'f', 'A'..'F'}:
      result.add(prefix & "sha1 must be hex-encoded (offending char: '" &
        $ch & "')")
      break
  # M1: weak-hash deprecation warning. Fires when ONLY sha1 is set AND
  # the digest itself passes the length+hex shape checks (so we don't
  # double-flag bogus values).
  if hasSha1 and (not hasSha256) and (not hasSha512) and
     pb.sha1.len == 40:
    var hexOk = true
    for ch in pb.sha1:
      if ch notin {'0'..'9', 'a'..'f', 'A'..'F'}:
        hexOk = false
        break
    if hexOk:
      warnings.add(prefix & "sha1 digest is weaker than sha256; " &
        "accepted because the upstream manifest ships nothing stronger. " &
        "Bump to sha256/sha512 when upstream upgrades.")

proc validatePlatformBinary*(pb: PlatformBinary; index: int):
    seq[string] =
  ## Backwards-compatible error-only validator. Warnings are emitted to
  ## stderr via ``logSchemaWarning`` so callers that have not migrated
  ## to ``validatePlatformBinaryEx`` still see the M1 deprecation note.
  var warnings: seq[string] = @[]
  result = validatePlatformBinaryEx(pb, index, warnings)
  for w in warnings: logSchemaWarning("WSchema: " & w)

proc validateVersionedProvisioningEx*(vp: VersionedProvisioning;
                                      warnings: var seq[string]):
    seq[string] =
  ## Returns the structured-error list AND populates ``warnings`` with
  ## non-fatal advisories (currently: the M1 sha1 weak-hash
  ## deprecation per ``validatePlatformBinaryEx``).
  if vp.version.len == 0:
    result.add("version is required")
  if vp.platforms.len == 0:
    result.add("at least one platforms[] entry is required")
  var seenPairs: seq[string] = @[]
  for i, pb in vp.platforms:
    result.add(validatePlatformBinaryEx(pb, i, warnings))
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
  of imInstallerMsi, imInstallerNsisBundle, imInstallerInnoSetup:
    # M4: each Windows installer family needs at least one bin_relpath
    # so the post-extract sanity check has something to verify against
    # the realized prefix tree (mirrors imExtract).
    if vp.bin_relpath.len == 0:
      result.add("install_method=" & $vp.install_method &
        " requires at least one bin_relpath entry")

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
  ##
  ## Warnings (M1: sha1 weak-hash deprecation) are routed to
  ## ``logSchemaWarning`` (stderr); use
  ## ``validateVersionedProvisioningEx`` to capture them as a list.
  var warnings: seq[string] = @[]
  result = validateVersionedProvisioningEx(vp, warnings)
  for w in warnings: logSchemaWarning("WSchema: " & w)

proc validateCatalogEx*(entries: openArray[VersionedProvisioning];
                        warnings: var seq[string]): seq[string] =
  ## Errors-plus-warnings overload of ``validateCatalog``. Warnings
  ## (currently: M1 sha1 weak-hash) are aggregated across all entries
  ## with the version prefix that errors carry, so a downstream
  ## diagnostic can correlate the warning to the slice.
  var seenVersions: seq[string] = @[]
  for i, vp in entries:
    var entryWarnings: seq[string] = @[]
    for err in validateVersionedProvisioningEx(vp, entryWarnings):
      result.add("entries[" & $i & "] (version=" & vp.version & "): " & err)
    for w in entryWarnings:
      warnings.add("entries[" & $i & "] (version=" & vp.version & "): " & w)
    if vp.version.len > 0:
      if vp.version in seenVersions:
        result.add("entries[" & $i & "]: duplicate version '" &
          vp.version & "'")
      seenVersions.add(vp.version)

proc validateCatalog*(entries: openArray[VersionedProvisioning]):
    seq[string] =
  ## Validate a whole ``<tool>Catalog`` array. Each error is prefixed
  ## with the entry's version so the diagnostic locates the bad slice.
  ## Warnings are routed to ``logSchemaWarning`` (stderr); use
  ## ``validateCatalogEx`` to capture them as a list.
  var warnings: seq[string] = @[]
  result = validateCatalogEx(entries, warnings)
  for w in warnings: logSchemaWarning("WSchema: " & w)

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
  of afSevenZipSfx: "afSevenZipSfx"
  of afInstallerNsis: "afInstallerNsis"
  of afInstallerMsi: "afInstallerMsi"
  of afRaw: "afRaw"

proc preInstallActionKindIdent*(pia: PreInstallActionKind): string =
  case pia
  of piaNewItemDir: "piaNewItemDir"
  of piaNewItemFile: "piaNewItemFile"
  of piaCopyItem: "piaCopyItem"
  of piaMoveItem: "piaMoveItem"
  of piaRemoveItem: "piaRemoveItem"
  of piaSetContent: "piaSetContent"
  of piaAddPath: "piaAddPath"
  of piaExpand7z: "piaExpand7z"
  of piaExpandDark: "piaExpandDark"
  of piaExpandMsi: "piaExpandMsi"
  of piaExpandInno: "piaExpandInno"

proc installMethodIdent(im: InstallMethod): string =
  case im
  of imExtract: "imExtract"
  of imInstallerSilent: "imInstallerSilent"
  of imMsys2Pacman: "imMsys2Pacman"
  of imSourceBootstrap: "imSourceBootstrap"
  of imInstallerMsi: "imInstallerMsi"
  of imInstallerNsisBundle: "imInstallerNsisBundle"
  of imInstallerInnoSetup: "imInstallerInnoSetup"

proc serializePlatformBinary(pb: PlatformBinary): string =
  # Field order: sha256, sha512, sha1 — sha1 last to make it
  # visually clear that it's the deprecated branch (M1 weak-hash
  # acceptance). ``nested_7z`` (M3) is emitted ONLY when true so the
  # vast majority of catalog entries (all non-nested archives) keep
  # their compact one-line shape and the existing harvester output
  # bytes-equal-trees against the M67/M68 baseline.
  result = "PlatformBinary(cpu: " & cpuIdent(pb.cpu) &
    ", os: " & osIdent(pb.os) &
    ", url: " & escapeString(pb.url) &
    ", sha256: " & escapeString(pb.sha256) &
    ", sha512: " & escapeString(pb.sha512) &
    ", sha1: " & escapeString(pb.sha1) &
    ", extract_path: " & escapeString(pb.extract_path)
  if pb.nested_7z:
    result.add(", nested_7z: true")
  # M4: msi_admin_install emitted only when true so the M67/M68 baseline
  # round-trips byte-identical.
  if pb.msi_admin_install:
    result.add(", msi_admin_install: true")
  result.add(")")

proc serializePreInstallAction*(pia: PreInstallAction): string =
  result = "PreInstallAction(kind: " & preInstallActionKindIdent(pia.kind) &
    ", source: " & escapeString(pia.source) &
    ", target: " & escapeString(pia.target) &
    ", recurse: " & (if pia.recurse: "true" else: "false") &
    ", literal: " & escapeString(pia.literal) & ")"

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
  result.add("}.toTable()")
  # M3: emit pre_install_actions + pre_install_unrecognized ONLY when
  # non-empty, so the M67/M68 baseline (every existing entry has
  # neither) round-trips byte-identical through the harvester. Newer
  # entries with actions/unrecognized lines render an explicit
  # multi-line tail.
  if vp.pre_install_actions.len > 0:
    result.add(",\n  pre_install_actions: @[\n")
    for i, pia in vp.pre_install_actions:
      result.add("    " & serializePreInstallAction(pia))
      if i + 1 < vp.pre_install_actions.len:
        result.add(",")
      result.add("\n")
    result.add("  ]")
  if vp.pre_install_unrecognized.len > 0:
    result.add(",\n  pre_install_unrecognized: @[")
    for i, line in vp.pre_install_unrecognized:
      if i > 0: result.add(", ")
      result.add(escapeString(line))
    result.add("]")
  result.add(")")
