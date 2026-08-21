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

import std/[strutils, tables]

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
    afTarZst = "tar.zst"
      ## M6 (Realize-Closure-And-Catalog-Expansion spec): zstd-compressed
      ## tarball. The canonical MSYS2 pacman package format
      ## (``mingw-w64-<arch>-<name>-<version>-<rel>-any.pkg.tar.zst``) and
      ## an increasingly common upstream tarball shape (rustup, Arch
      ## Linux packages, ...). The cakBuiltin realize loop extracts via a
      ## three-strategy discovery (catalog ``7zip`` prefix → host ``tar
      ## --zstd`` → host ``zstd | tar``) — see ``extractTarZst`` in
      ## builtin_adapter.nim.
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
    ##   * ``imInstallerNsis`` — plain NSIS installer whose payload is a
    ##     bona-fide file tree (NOT a Burn outer wrapping inner MSIs).
    ##     The cakBuiltin realize hook dispatches via the discovered
    ##     full ``7z.exe`` directly (which transparently understands the
    ##     modern NSIS installer format). M11 (Realize-Closure-And-
    ##     Catalog-Expansion spec) added this variant after the M8 live
    ##     smoke proved erlang's OTP installer is a bona-fide NSIS
    ##     installer with no Burn outer — dark.exe rejects it with
    ##     ``DARK0339`` (no .wixburn section), but the full 7-Zip 26.01
    ##     M8 re-harvest extracts it cleanly. See ``packages/erlang.nim``'s
    ##     M11 header for the LIVE-validated trace.
    ##   * ``imInstallerInnoSetup`` — Inno-Setup-built installer (the
    ##     freepascal shape, ``innosetup: true`` Scoop marker). Realize
    ##     dispatches via the discovered ``innounp.exe``.
    imExtract = "extract"
    imInstallerSilent = "installer-silent"
    imMsys2Pacman = "msys2-pacman"
      ## M6 (Realize-Closure-And-Catalog-Expansion spec): provenance-
      ## labelled variant of ``imExtract`` for ``.pkg.tar.zst`` payloads
      ## harvested from the MSYS2 pacman repository. The realize-time
      ## semantics are intentionally a strict subset of ``imExtract`` —
      ## download, sha256 verify, extract via the discovered zstd-
      ## capable extractor, flatten the inner ``<env>/`` subtree, replay
      ## allowlisted pre_install actions. The dispatch does NOT invoke
      ## pacman; the ``pacman_packages`` field is an audit trail (the
      ## harvested MSYS2 package name, e.g. ``mingw-w64-x86_64-ocaml``)
      ## that drives the schema validator + future drift detection
      ## against repo.msys2.org, NOT a recursive package-manager call.
      ## The catalog-author rationale for the separate enum (vs an
      ## ``imExtract`` slice with ``archive_format=afTarZst``):
      ## (i) self-documenting at the call site (catalog readers see at
      ## a glance that the slice came from MSYS2);
      ## (ii) the validator enforces ``pacman_packages.len >= 1`` AND
      ## ``archive_format == afTarZst``, blocking malformed authoring;
      ## (iii) future drift-detection / re-harvest tooling keys off
      ## this discriminant to query repo.msys2.org for upstream version
      ## bumps. Behavior at realize time IS the same as the equivalent
      ## ``imExtract`` slice; the differentiation is provenance only.
    imSourceBootstrap = "source-bootstrap"
    imInstallerMsi = "installer-msi"
    imInstallerNsisBundle = "installer-nsis-bundle"
    imInstallerNsis = "installer-nsis"
    imInstallerInnoSetup = "installer-inno-setup"

  PlatformCpu* = enum
    ## The CPU **family** axis. Matches the ``cpu_arch`` tokens the
    ## reprobuild runtime already uses (see
    ## ``repro_core``). The ``pcAny`` variant is reserved for
    ## architecture-independent artifacts (rare — most installers are
    ## arch-specific even on Windows).
    ##
    ## PMC-2 (Platform-And-Microarchitecture-Constraints,
    ## Package-Model.md §"The CPU axis, which is where a flat string
    ## breaks first"): this enum is deliberately UNCHANGED. It was the
    ## whole of "CPU" before PMC-2 and is now one of two coordinates —
    ## the family — with ``MicroarchLevel`` carrying the other. Keeping
    ## the family enum byte-identical is what makes "every existing
    ## catalog entry resolves exactly as before" checkable rather than
    ## hoped for: no catalog literal, no serialized form and no test
    ## that names ``pcX86_64`` had to move.
    pcAny = "any"
    pcX86_64 = "x86_64"
    pcAArch64 = "aarch64"
    pcX86 = "x86"

  MicroarchLevel* = enum
    ## PMC-2: the microarchitecture axis, as the x86-64 psABI levels.
    ##
    ## These are the coarse axis the milestone chose deliberately: the
    ## levels form a LINEAR CHAIN, so "artifact requires >= v2, host
    ## provides v3" is an integer comparison rather than a walk over
    ## archspec's is-a graph. This org's CI already labels hosts
    ## ``x86-64-v2`` / ``x86-64-v3``, so the vocabulary predates the code.
    ##
    ## The enum's ORDER is the comparison. ``mlNone`` sorts below every
    ## real level so that "no floor" compares as "the least demanding
    ## artifact", which is exactly its meaning on the artifact side.
    ##
    ## On the HOST side ``mlNone`` means "this host has not stated a
    ## level", which is NOT the same as "v1" and is deliberately treated
    ## as unsatisfying for any arm that declares a floor — see
    ## ``satisfiesFloor``. Feature sets finer than a level (AVX-512 in
    ## particular is not one level) are PMC-3.
    mlNone = "none"
    mlX86_64_v1 = "x86-64-v1"
    mlX86_64_v2 = "x86-64-v2"
    mlX86_64_v3 = "x86-64-v3"
    mlX86_64_v4 = "x86-64-v4"

  PlatformTarget* = object
    ## PMC-2 deliverable 1: the structured target — a CPU family plus an
    ## OPTIONAL microarchitecture level.
    ##
    ## Read in two directions, and the direction changes what ``level``
    ## means:
    ##
    ##   * on an ARTIFACT (``PlatformBinary.cpu`` + ``.cpu_level``) the
    ##     level is the FLOOR the artifact needs — the minimum the host
    ##     must provide for the binary not to trap;
    ##   * on a HOST (``PlatformTarget`` passed to selection) the level is
    ##     what the host PROVIDES.
    ##
    ## Compatibility is therefore an ORDERING (``provided >= floor``), not
    ## the equality the flat enum could express. ``mlNone`` on the
    ## artifact side is what ``pcAny`` used to mean implicitly: no floor,
    ## runs anywhere in the family.
    family*: PlatformCpu
    level*: MicroarchLevel

  PlatformOs* = enum
    poAny = "any"
    poWindows = "windows"
    poLinux = "linux"
    poMacos = "macos"

  PackagePlatform* = object
    ## PMC-1 (Platform-And-Microarchitecture-Constraints spec,
    ## Package-Model.md §"Proposed shape"): ONE coordinate of a
    ## package-level ``platforms:`` declaration — the COARSE axis only
    ## (OS, plus CPU family). Microarchitecture levels and feature sets
    ## are PMC-2 / PMC-3 and deliberately absent here.
    ##
    ## Distinct from ``PlatformBinary``, which says "here is the
    ## artifact for this (cpu, os)". This says "the package can EXIST
    ## on this (cpu, os)" — availability, not provisioning. Nix keeps
    ## the same split (``meta.platforms`` vs the per-system derivation)
    ## and so does Spack (``requires("platform=…")`` vs
    ## ``depends_on(…, when=…)``).
    cpu*: PlatformCpu
    os*: PlatformOs

  PackageAvailability* = object
    ## PMC-1: the answer to "where can this package exist?" for one
    ## package.
    ##
    ## ``declared`` is the load-bearing field. It is ``true`` ONLY when
    ## the package wrote an explicit ``platforms:`` block. When it is
    ## ``false`` the ``platforms`` seq is EMPTY and carries no inferred
    ## fallback: the resolver treats an undeclared package exactly as it
    ## did before PMC-1 — availability was never stated, only implied by
    ## whichever provisioning arms happened to exist, and that implication
    ## stays where it was, in the adapter chain. Gating on a guess
    ## would change how existing catalog entries resolve, which PMC-1
    ## explicitly forbids; PMC-5 converts the inferences into
    ## declarations one entry at a time, and each conversion is what
    ## turns the gate on for that entry.
    declared*: bool
    platforms*: seq[PackagePlatform]
    message*: string
      ## Optional author-supplied reason, the equivalent of Spack's
      ## ``requires(…, msg="…")``. Rendered verbatim in the
      ## unavailable-package diagnostic so the author's knowledge
      ## reaches the reader instead of being guessed at.

  PlatformBinary* = object
    ## Per-(cpu, os) download slice: one URL + one digest + one
    ## extract-path. The ``extract_path`` is the inner directory the
    ## archive ships under (e.g. ``jdk-21.0.5+11`` for the Adoptium
    ## JDK zip); the realize loop flattens it so the realized prefix
    ## carries ``bin/javac.exe`` directly. Empty ``extract_path`` =
    ## no inner dir.
    cpu*: PlatformCpu
    cpu_level*: MicroarchLevel
                           ## PMC-2: the microarchitecture FLOOR this
                           ## slice requires, or ``mlNone`` (the default,
                           ## and the state of every catalog entry that
                           ## exists today) for "no floor — runs on any
                           ## host of this family".
                           ##
                           ## A floor is a REQUIREMENT, not a preference:
                           ## a slice built with ``-march=x86-64-v3``
                           ## carries instructions a v2 host does not
                           ## have, and running it there is a ``SIGILL``
                           ## far from its cause. Selection therefore
                           ## refuses such a slice rather than ranking it
                           ## lower (``selectPlatformBinaryEx``).
                           ##
                           ## Serialization emits this field ONLY when it
                           ## is non-``mlNone``, so every checked-in
                           ## ``packages/<tool>.nim`` round-trips
                           ## byte-identical through ``serializeAsCode``.
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
    archive_format_override*: ArchiveFormat
                           ## M9.5 (Realize-Closure-And-Catalog-Expansion
                           ## spec): per-platform override of the parent
                           ## ``VersionedProvisioning.archive_format``.
                           ## Only consulted when
                           ## ``has_archive_format_override`` is true —
                           ## ArchiveFormat has no natural unset sentinel.
                           ## The M9.5 cross-OS catalog harvester pass
                           ## needs this because a single tool's upstream
                           ## ships different archive shapes per OS
                           ## (e.g. gh ships a ``.zip`` on Windows and a
                           ## ``.tar.gz`` on Linux). The Windows-only
                           ## M67/M68 baseline never set this field; all
                           ## existing catalog files round-trip byte-
                           ## identical because the serializer emits this
                           ## field ONLY when ``has_archive_format_override``
                           ## is true.
    has_archive_format_override*: bool
                           ## M9.5: sentinel for archive_format_override.
                           ## ``false`` (default) = use the parent
                           ## VersionedProvisioning's archive_format.
                           ## ``true`` = use ``archive_format_override``.
    bin_relpath_override*: seq[string]
                           ## M9.5: per-platform override of the parent
                           ## ``VersionedProvisioning.bin_relpath``.
                           ## ``@[]`` (default) = use the parent's
                           ## bin_relpath. Non-empty = use this list
                           ## instead. The M9.5 cross-OS pass needs this
                           ## because Windows binaries have the ``.exe``
                           ## suffix while Linux binaries do not, and
                           ## per-OS archives ship binaries under
                           ## different inner paths (e.g. gh's Linux
                           ## tarball nests under
                           ## ``gh_<ver>_linux_amd64/bin/`` while the
                           ## Windows zip is flat ``bin\\gh.exe``).

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

  LauncherEmitKind* = enum
    ## M5 (Realize-Closure-And-Catalog-Expansion spec): closed-set
    ## launcher-synthesis shapes the cakBuiltin realize loop emits AFTER
    ## the extract / install_method dispatch completes. Each kind names a
    ## wrap pattern Scoop's ``pre_install`` PowerShell idiomatically
    ## synthesizes (composer's ``& php $dir\composer.phar @args`` shim,
    ## the rare ``& java -jar $dir\<tool>.jar @args`` shim, the generic
    ## wrapped-script shape). The interpreter binary is discovered at
    ## realize time via the same catalog-prefix-first pattern as M3/M4
    ## extractors (``discoverPhpExe`` / ``discoverJavaExe``); the
    ## launcher file itself is generated inline via deterministic Nim
    ## string concatenation — the M56 content-addressed store's digest
    ## covers the launcher bytes.
    lekPhar = "phar"     ## ``.phar`` wrap (composer); interpreter = php
    lekJar = "jar"       ## ``.jar`` wrap (future gradle/maven); interpreter = jdk
    lekScript = "script" ## generic wrapped-script shape (bash/python etc.)

  LauncherEmitSpec* = object
    ## M5: one launcher to emit at realize time. The realize loop
    ## generates two files per spec under the prefix's ``bin/``
    ## directory: ``<launcher_name>.ps1`` (PowerShell entry) and
    ## ``<launcher_name>.cmd`` (cmd.exe entry on Windows). Both invoke
    ## the discovered interpreter with the ``target`` (a relpath under
    ## the prefix that points at the .phar / .jar / script file the
    ## extract step deposited) and forward the user's argv.
    ##
    ## The ``interpreter_package_id`` is the catalog id whose realized
    ## prefix supplies the interpreter binary (e.g. ``"php"`` for
    ## composer, ``"jdk"`` for jar wrappers). The realize loop's
    ## discovery falls through (catalog prefix -> PATH -> fail closed
    ## with ``EBuiltinInterpreterUnavailable``) — same shape as M3's
    ## 7z / M4's lessmsi discovery.
    kind*: LauncherEmitKind
    target*: string                   ## prefix-relative path to the
                                      ## payload (e.g. "composer.phar").
                                      ## The post-extract layout places
                                      ## this file at <prefix>/<target>.
    interpreter_package_id*: string   ## catalog package id of the
                                      ## interpreter (e.g. "php", "jdk").
    launcher_name*: string            ## bare name of the emitted
                                      ## launchers (e.g. "composer" ->
                                      ## "bin/composer.ps1" +
                                      ## "bin/composer.cmd").

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
    launcher_emit*: seq[LauncherEmitSpec]
                                      ## M5 (Realize-Closure-And-Catalog-
                                      ## Expansion spec): ordered list of
                                      ## launcher shims the realize loop
                                      ## emits AFTER extract / install_method
                                      ## dispatch. Each spec yields
                                      ## ``bin/<launcher_name>.ps1`` +
                                      ## ``bin/<launcher_name>.cmd`` invoking
                                      ## the discovered interpreter against
                                      ## the spec's ``target`` (a prefix-
                                      ## relative path the extract step
                                      ## deposited). Used for ``.phar``
                                      ## (composer; interpreter=php), ``.jar``
                                      ## (future jdk-based tools), and
                                      ## generic wrapped-script shapes.
                                      ## Validation: every spec's
                                      ## ``launcher_name`` must appear in
                                      ## ``bin_relpath`` as a ``.ps1`` or
                                      ## ``.cmd`` entry (sanity check that
                                      ## the catalog declares the launchers
                                      ## as its bin surface). Empty for the
                                      ## vast majority of catalog entries —
                                      ## the M67/M68 baseline round-trips
                                      ## byte-identical when this field is
                                      ## empty.
                                      ##
                                      ## **Placement trade-off (M5)**:
                                      ## ``launcher_emit`` lives at the
                                      ## ``VersionedProvisioning`` level
                                      ## (cross-platform), NOT on
                                      ## ``PlatformBinary``. The composer
                                      ## .phar wrap is identical on every
                                      ## platform (same php interpreter id,
                                      ## same .phar payload name, same
                                      ## launcher body), so version-level
                                      ## placement avoids duplicating the
                                      ## spec across per-platform slices.
                                      ## A future tool needing DIFFERENT
                                      ## launchers per arch / OS (e.g. a
                                      ## bash-script on Linux + a .ps1 on
                                      ## Windows) would need a schema
                                      ## extension promoting this field to
                                      ## the platform level. M5 ships the
                                      ## simpler cross-platform shape.

# ---------------------------------------------------------------------------
# PMC-2 — the microarchitecture axis: an ORDER, not an equality
# ---------------------------------------------------------------------------
#
# Everything below is pure and total. It is deliberately free of any ambient
# read (no env, no ``hostCPU``, no OS probe): detection lives in
# ``repro_home_apply/package_catalog.nim`` where it can be supplied through the
# resolution entry points' DEFAULT PARAMETERS. That separation is the reason
# every microarchitecture test in this campaign is hermetic — a test names a
# synthetic ``PlatformTarget`` and never needs v2/v3 hardware. Do not add a
# global lookup here.

proc initPlatformTarget*(family: PlatformCpu; level = mlNone): PlatformTarget =
  ## Construct a target. ``level`` defaults to ``mlNone``: on the host side
  ## that means "this host has not stated what it provides", which refuses
  ## every arm that declares a floor (see ``satisfiesFloor``).
  PlatformTarget(family: family, level: level)

proc levelFamily*(level: MicroarchLevel): PlatformCpu =
  ## The CPU family a microarchitecture level belongs to. Every level
  ## defined today is an x86-64 psABI level; ``mlNone`` belongs to no
  ## family in particular and answers ``pcAny``.
  ##
  ## Exists so the validator can refuse ``cpu: pcAArch64,
  ## cpu_level: mlX86_64_v3`` at authoring time rather than letting a
  ## nonsense pair reach selection, where it would simply never match and
  ## look like a missing arm.
  case level
  of mlNone: pcAny
  of mlX86_64_v1, mlX86_64_v2, mlX86_64_v3, mlX86_64_v4: pcX86_64

proc describeMicroarchLevel*(level: MicroarchLevel): string =
  ## ``x86-64-v3``; ``mlNone`` renders as ``none``. The spelling is the
  ## psABI one and the one this org's CI labels already use, so a
  ## diagnostic can be pasted into a runner label search.
  $level

proc satisfiesFloor*(hostLevel, floor: MicroarchLevel): bool =
  ## Does a host PROVIDING ``hostLevel`` satisfy an artifact whose FLOOR is
  ## ``floor``? This is the ordering the milestone asks for.
  ##
  ## Two asymmetric rules, and the asymmetry is the point:
  ##
  ##   * ``floor == mlNone`` — no floor. Always satisfied, on any host,
  ##     including one that has stated nothing. This is what keeps every
  ##     catalog entry that exists today selecting exactly as it did.
  ##   * ``hostLevel == mlNone`` with a real floor — REFUSED. An
  ##     unstated host level is not "v1"; it is "unknown", and the
  ##     failure mode of guessing high is ``SIGILL`` inside someone
  ##     else's build. Compare with ``platformMatchesHost``, which
  ##     fails OPEN for an unrecognised CPU family: there the cost of
  ##     guessing wrong is a resolution that finds nothing, here it is a
  ##     binary that runs and traps. The two directions are chosen per
  ##     consequence, not by a single house rule.
  if floor == mlNone: true
  elif hostLevel == mlNone: false
  else: ord(hostLevel) >= ord(floor)

# ---------------------------------------------------------------------------
# Construction helpers
# ---------------------------------------------------------------------------

proc initPlatformBinary*(cpu: PlatformCpu; os: PlatformOs; url: string;
                         sha256 = ""; sha512 = ""; sha1 = "";
                         extract_path = "";
                         nested_7z = false;
                         msi_admin_install = false;
                         archive_format_override = afZip;
                         has_archive_format_override = false;
                         bin_relpath_override: seq[string] = @[];
                         cpu_level = mlNone):
    PlatformBinary =
  PlatformBinary(
    cpu: cpu, cpu_level: cpu_level, os: os, url: url,
    sha256: sha256, sha512: sha512, sha1: sha1,
    extract_path: extract_path,
    nested_7z: nested_7z,
    msi_admin_install: msi_admin_install,
    archive_format_override: archive_format_override,
    has_archive_format_override: has_archive_format_override,
    bin_relpath_override: bin_relpath_override)

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
                                pre_install_unrecognized: seq[string] = @[];
                                launcher_emit: seq[LauncherEmitSpec] = @[]):
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
    pre_install_unrecognized: pre_install_unrecognized,
    launcher_emit: launcher_emit)
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
  # PMC-2: a microarchitecture floor must belong to the arm's own family.
  # ``cpu: pcAArch64, cpu_level: mlX86_64_v3`` is not a narrow arm, it is a
  # contradiction, and without this check it would simply never be selected —
  # indistinguishable at the point of failure from a missing arm.
  if pb.cpu_level != mlNone and pb.cpu != levelFamily(pb.cpu_level):
    result.add(prefix & "cpu_level " & describeMicroarchLevel(pb.cpu_level) &
      " belongs to cpu family " & $levelFamily(pb.cpu_level) &
      ", but this slice declares cpu " & $pb.cpu &
      ". A microarchitecture floor constrains a family it is part of; " &
      "set cpu to " & $levelFamily(pb.cpu_level) & " or drop cpu_level.")
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
    # PMC-2: the uniqueness key gained the microarchitecture floor. Several
    # slices for the SAME (cpu, os) at DIFFERENT floors is the whole point of
    # the milestone — v1/v2/v3 builds of one tool for one OS — so keying on
    # (cpu, os) alone would reject exactly the shape the feature exists to
    # express. The rendered key is unchanged for a levelless slice, so every
    # existing duplicate-pair diagnostic reads byte-identically.
    let key = $pb.cpu & "-" & $pb.os &
      (if pb.cpu_level == mlNone: ""
       else: " " & describeMicroarchLevel(pb.cpu_level))
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
        "pacman_packages entry (the harvested MSYS2 package name, e.g. " &
        "'mingw-w64-x86_64-ocaml')")
    # M6: the M6 cakBuiltin realize hook downloads + extracts the
    # ``.pkg.tar.zst`` and verifies bin_relpath against the realized
    # prefix — same shape as imExtract. Require at least one bin_relpath
    # entry so the post-extract sanity check has something to assert.
    if vp.bin_relpath.len == 0:
      result.add("install_method=imMsys2Pacman requires at least one " &
        "bin_relpath entry (the realize hook flattens mingw64/ to the " &
        "prefix root and verifies each bin_relpath exists post-extract)")
  of imSourceBootstrap:
    if vp.bootstrap_argv.len == 0:
      result.add("install_method=imSourceBootstrap requires a " &
        "non-empty bootstrap_argv")
  of imInstallerMsi, imInstallerNsisBundle, imInstallerNsis,
     imInstallerInnoSetup:
    # M4: each Windows installer family needs at least one bin_relpath
    # so the post-extract sanity check has something to verify against
    # the realized prefix tree (mirrors imExtract).
    # M11: imInstallerNsis joined the family — same bin_relpath rule
    # (the realize hook calls extract7z on the .exe payload and the
    # post-extract sanity check verifies each bin_relpath exists).
    if vp.bin_relpath.len == 0:
      result.add("install_method=" & $vp.install_method &
        " requires at least one bin_relpath entry")
  # M5: when launcher_emit is non-empty, every spec's launcher_name must
  # appear in bin_relpath as a .ps1 / .cmd entry. The sanity check
  # confirms the catalog declares the emitted launchers as the tool's
  # public bin surface (so the post-extract bin-existence verification
  # at apply time matches reality). Also catches typos in launcher_name.
  for i, spec in vp.launcher_emit:
    let prefix = "launcher_emit[" & $i & "] (kind=" & $spec.kind & "): "
    if spec.launcher_name.len == 0:
      result.add(prefix & "launcher_name is required")
    if spec.target.len == 0:
      result.add(prefix & "target is required (prefix-relative path " &
        "to the payload file)")
    if spec.interpreter_package_id.len == 0:
      result.add(prefix & "interpreter_package_id is required (the " &
        "catalog package whose realized prefix supplies the interpreter)")
    if spec.launcher_name.len > 0 and vp.bin_relpath.len > 0:
      let ps1Leaf = spec.launcher_name & ".ps1"
      let cmdLeaf = spec.launcher_name & ".cmd"
      var sawPs1 = false
      var sawCmd = false
      for b in vp.bin_relpath:
        let leaf = b.split({'/', '\\'})[^1]
        if leaf == ps1Leaf: sawPs1 = true
        if leaf == cmdLeaf: sawCmd = true
      if not (sawPs1 or sawCmd):
        result.add(prefix & "launcher_name '" & spec.launcher_name &
          "' has no matching .ps1 or .cmd entry in bin_relpath (declare " &
          "the launcher files in bin_relpath so the post-extract sanity " &
          "check matches reality)")

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
# PMC-1 — declared package availability (the COARSE axis)
# ---------------------------------------------------------------------------
#
# The token vocabulary is deliberately the SAME one the per-arm ``cpu =`` /
# ``os =`` setters already accept, so a reader does not have to learn a second
# spelling of "windows". ``darwin`` is accepted as an alias of ``macos``
# because the DSL's arm parser accepts both.

proc parsePlatformCpuToken*(token: string):
    tuple[ok: bool; cpu: PlatformCpu] =
  ## Map a ``platforms:`` CPU token onto ``PlatformCpu``. Empty or
  ## ``any`` means "every CPU family".
  case token.toLowerAscii()
  of "", "any":     (true, pcAny)
  of "x86_64", "amd64", "x64": (true, pcX86_64)
  of "aarch64", "arm64":       (true, pcAArch64)
  of "x86", "i386", "i686":    (true, pcX86)
  else:             (false, pcAny)

proc parseMicroarchLevelToken*(token: string):
    tuple[ok: bool; level: MicroarchLevel] =
  ## PMC-2: map a microarchitecture token onto ``MicroarchLevel``.
  ##
  ## Accepts the psABI spelling (``x86-64-v3``), the underscore variant
  ## the CPU-family vocabulary uses (``x86_64_v3`` / ``x86_64-v3``), and
  ## the bare level (``v3``) for use where the family is already fixed by
  ## context. Empty and ``none`` mean "no level".
  ##
  ## Rejects anything else rather than widening to ``mlNone``: a typo'd
  ## floor that silently became "no floor" is a v3 binary shipped to a v2
  ## host, which is the exact failure the milestone exists to prevent.
  var norm = token.strip().toLowerAscii()
  for i in 0 ..< norm.len:
    if norm[i] == '_': norm[i] = '-'
  case norm
  of "", "none":                            (true, mlNone)
  of "v1", "x86-64-v1", "x86-64v1":         (true, mlX86_64_v1)
  of "v2", "x86-64-v2", "x86-64v2":         (true, mlX86_64_v2)
  of "v3", "x86-64-v3", "x86-64v3":         (true, mlX86_64_v3)
  of "v4", "x86-64-v4", "x86-64v4":         (true, mlX86_64_v4)
  else:                                     (false, mlNone)

proc parsePlatformOsToken*(token: string):
    tuple[ok: bool; os: PlatformOs] =
  ## Map a ``platforms:`` OS token onto ``PlatformOs``. Empty or ``any``
  ## means "every OS".
  case token.toLowerAscii()
  of "", "any":            (true, poAny)
  of "windows", "win":     (true, poWindows)
  of "linux":              (true, poLinux)
  of "macos", "darwin", "osx": (true, poMacos)
  else:                    (false, poAny)

proc parsePackagePlatformToken*(token: string):
    tuple[ok: bool; platform: PackagePlatform] =
  ## Parse ONE ``platforms:`` entry. Two shapes are accepted:
  ##
  ##   * a bare OS or CPU token — ``windows``, ``linux``, ``aarch64``;
  ##   * a ``<cpu>-<os>`` pair — ``x86_64-windows``, ``aarch64-linux``.
  ##
  ## The bare form is the common case and reads as the milestone writes
  ## it (``platforms: [windows]``); the paired form is what a package
  ## available on only one architecture of one OS needs. A bare token is
  ## resolved against the OS vocabulary first and the CPU vocabulary
  ## second, so ``windows`` means "any CPU, Windows" and ``aarch64``
  ## means "aarch64, any OS".
  let trimmed = token.strip()
  let cut = trimmed.rfind('-')
  if cut > 0 and cut + 1 < trimmed.len:
    let cpuPart = parsePlatformCpuToken(trimmed[0 ..< cut])
    let osPart = parsePlatformOsToken(trimmed[cut + 1 .. ^1])
    if cpuPart.ok and osPart.ok:
      return (true, PackagePlatform(cpu: cpuPart.cpu, os: osPart.os))
  let asOs = parsePlatformOsToken(trimmed)
  if asOs.ok and trimmed.len > 0 and trimmed.toLowerAscii() != "any":
    return (true, PackagePlatform(cpu: pcAny, os: asOs.os))
  let asCpu = parsePlatformCpuToken(trimmed)
  if asCpu.ok and trimmed.len > 0 and trimmed.toLowerAscii() != "any":
    return (true, PackagePlatform(cpu: asCpu.cpu, os: poAny))
  if trimmed.len == 0 or trimmed.toLowerAscii() == "any":
    return (true, PackagePlatform(cpu: pcAny, os: poAny))
  (false, PackagePlatform())

proc platformMatchesHost*(p: PackagePlatform;
                          hostCpu: PlatformCpu; hostOs: PlatformOs): bool =
  ## Does a host at ``(hostCpu, hostOs)`` fall inside coordinate ``p``?
  ##
  ## ``pcAny`` / ``poAny`` on EITHER side match. On the declaration side
  ## that is the point of the token. On the host side it is fail-open:
  ## ``detectHostCpu`` reports ``pcAny`` for a CPU it does not recognise,
  ## and refusing to resolve on an unrecognised host would turn a
  ## detection gap into an outage.
  (p.cpu == pcAny or hostCpu == pcAny or p.cpu == hostCpu) and
  (p.os == poAny or hostOs == poAny or p.os == hostOs)

proc isAvailableOn*(availability: PackageAvailability;
                    hostCpu: PlatformCpu; hostOs: PlatformOs): bool =
  ## True when the host satisfies at least one declared coordinate.
  ##
  ## An UNDECLARED package is available everywhere: PMC-1 gates only on
  ## what an author actually wrote (see ``PackageAvailability.declared``).
  ## An empty declared list is likewise treated as unconstrained rather
  ## than as "nowhere" — refusing every host on an empty list would turn
  ## a typo into a fleet-wide outage.
  if not availability.declared or availability.platforms.len == 0:
    return true
  for p in availability.platforms:
    if platformMatchesHost(p, hostCpu, hostOs):
      return true
  false

proc constrainsCpu*(availability: PackageAvailability): bool =
  ## True when at least one declared coordinate names a CPU family.
  ## Drives whether the diagnostic reports the host as ``linux`` or as
  ## ``x86_64-linux`` — naming an axis the declaration never mentions
  ## invites the reader to go looking for a CPU problem that is not
  ## there.
  for p in availability.platforms:
    if p.cpu != pcAny:
      return true
  false

proc describePlatform*(p: PackagePlatform): string =
  if p.cpu == pcAny and p.os == poAny: "any"
  elif p.cpu == pcAny: $p.os
  elif p.os == poAny: $p.cpu
  else: $p.cpu & "-" & $p.os

proc describeDeclaredPlatforms*(availability: PackageAvailability): string =
  ## Human phrasing of the declared set, for the diagnostic. A single
  ## OS-only coordinate renders as ``windows only`` so the sentence in
  ## the milestone ("chocolatey is declared for windows only") comes out
  ## verbatim; anything richer renders as a bracketed list.
  if availability.platforms.len == 0:
    return "no platform"
  if availability.platforms.len == 1:
    return describePlatform(availability.platforms[0]) & " only"
  var parts: seq[string] = @[]
  for p in availability.platforms:
    parts.add(describePlatform(p))
  "[" & parts.join(", ") & "]"

proc describeHostTarget*(availability: PackageAvailability;
                         hostCpu: PlatformCpu; hostOs: PlatformOs): string =
  ## Human phrasing of the host, on the same axes the declaration uses.
  if availability.constrainsCpu():
    $hostCpu & "-" & $hostOs
  else:
    $hostOs

# ---------------------------------------------------------------------------
# Per-platform resolution
# ---------------------------------------------------------------------------

type
  PlatformSelection* = object
    ## PMC-2: the outcome of arm selection, widened so that "no arm's
    ## floor is satisfied" is DISTINGUISHABLE from "no arm exists for
    ## this (cpu, os)".
    ##
    ## The two need different remediations and, more to the point,
    ## different diagnostics: the first is "your host is below the floor
    ## this artifact needs" and the second is "nobody built this for your
    ## platform". Collapsing them into one ``found = false`` is how a
    ## microarchitecture shortfall would reach the reader as a generic
    ## no-matching-arm message, which is where PMC-1 started.
    found*: bool
    binary*: PlatformBinary
    refusedForLevel*: bool
      ## True when at least one arm matched the (cpu, os) coordinate and
      ## every such arm declared a floor above what the host provides.
    requiredLevel*: MicroarchLevel
      ## The LOWEST floor among the refused arms — the least the host
      ## would have to provide for something to select. Naming the lowest
      ## rather than the highest is deliberate: it is the actionable
      ## number.
    hostLevel*: MicroarchLevel
      ## What the host said it provides, echoed so the caller can render
      ## "needs x86-64-v3, host provides x86-64-v2" without re-deriving it.

proc armPreferenceTier(pb: PlatformBinary;
                       cpu: PlatformCpu; os: PlatformOs): int =
  ## The pre-PMC-2 four-step preference, reified as a rank.
  ##
  ##   0 = exact (cpu, os); 1 = (pcAny, os); 2 = (cpu, poAny);
  ##   3 = (pcAny, poAny); -1 = does not apply to this host at all.
  ##
  ## Scanning tiers in order and taking the first arm in the first
  ## non-empty tier is EXACTLY what the four sequential loops did, which
  ## is what makes ``t_levelless_catalog_selection_is_unchanged`` a
  ## statement about equivalence rather than a hope.
  if pb.cpu == cpu and pb.os == os: 0
  elif pb.cpu == pcAny and pb.os == os: 1
  elif pb.cpu == cpu and pb.os == poAny: 2
  elif pb.cpu == pcAny and pb.os == poAny: 3
  else: -1

proc selectPlatformBinaryEx*(vp: VersionedProvisioning;
                             target: PlatformTarget; os: PlatformOs):
    PlatformSelection =
  ## PMC-2 deliverable 3: selection as "filter to what the host can run,
  ## then take the highest floor".
  ##
  ## The order of operations is the substance:
  ##
  ##   1. FILTER to arms whose (cpu, os) applies to this host AND whose
  ##      microarchitecture floor the host satisfies. Filtering first is
  ##      what makes an unsatisfiable arm invisible rather than merely
  ##      unranked — a v3 arm on a v2 host must not be able to win by
  ##      being the most specific.
  ##   2. Among the survivors take the BEST preference tier — the
  ##      pre-PMC-2 exact-then-``any`` order, unchanged.
  ##   3. Within that tier take the HIGHEST floor: the best the host can
  ##      actually run. "Refuses what it cannot run" and "picks the best
  ##      it can run" are separate properties and this step is the second
  ##      one.
  ##   4. Ties (equal tier, equal floor) go to the first declared arm,
  ##      which is what the four sequential loops did.
  ##
  ## DEGENERATE CASE — and this is the compatibility guarantee for the
  ## entire existing stdlib: when NO arm declares a level, every
  ## applicable arm survives step 1 (``satisfiesFloor`` is unconditionally
  ## true for ``mlNone``) and every survivor has the same floor, so steps
  ## 3 and 4 collapse and the result is "first arm of the best non-empty
  ## tier" — the four-step order, arm for arm.
  ##
  ## Tier BEFORE floor, not the other way round: the (cpu, os) coordinate
  ## is an availability statement and the floor is a capability one, and a
  ## same-family exact arm is a stronger claim than an ``any``-family arm
  ## that happens to be tuned higher. In the shape this milestone is for —
  ## v1/v2/v3 builds of one tool for one (family, os) — every candidate
  ## shares a tier and the floor decides outright.
  result.hostLevel = target.level
  result.requiredLevel = mlNone
  var bestTier = high(int)
  var haveBest = false
  for pb in vp.platforms:
    let tier = armPreferenceTier(pb, target.family, os)
    if tier < 0:
      continue
    if not satisfiesFloor(target.level, pb.cpu_level):
      # Applicable coordinate, unreachable floor. Remember the LOWEST such
      # floor so the diagnostic can name what the host would need.
      if not result.refusedForLevel or
         ord(pb.cpu_level) < ord(result.requiredLevel):
        result.requiredLevel = pb.cpu_level
      result.refusedForLevel = true
      continue
    if not haveBest or tier < bestTier or
       (tier == bestTier and ord(pb.cpu_level) > ord(result.binary.cpu_level)):
      haveBest = true
      bestTier = tier
      result.binary = pb
  result.found = haveBest
  if haveBest:
    # Something selected, so this is not a shortfall — clear the refusal so
    # a caller cannot render a warning about an arm it did not need.
    result.refusedForLevel = false
    result.requiredLevel = mlNone

proc describeMicroarchShortfall*(sel: PlatformSelection): string =
  ## PMC-2 deliverable 4: the shortfall sentence —
  ## "needs x86-64-v3, host provides x86-64-v2".
  ##
  ## The milestone writes its example with the host side abbreviated
  ## ("host provides v2"); this spells both sides in full psABI form
  ## deliberately, and the difference is not cosmetic. The string is the
  ## same vocabulary this org's CI runner labels use (``x86-64-v3`` appears
  ## verbatim in ``services/github-runners/common.nix``), so a reader can
  ## paste either half into a label search. A bare ``v2`` is also the one
  ## spelling that stops being unambiguous the moment PMC-3 adds a second
  ## family's ladder.
  ##
  ## A host that stated nothing gets the honest phrasing instead of being
  ## reported as some level it never claimed; the remediation differs
  ## (declare the host's level vs. get a better host) and a wrong noun
  ## here sends the reader to the wrong fix.
  if not sel.refusedForLevel:
    return ""
  let provides =
    if sel.hostLevel == mlNone: "no declared microarchitecture level"
    else: describeMicroarchLevel(sel.hostLevel)
  "needs " & describeMicroarchLevel(sel.requiredLevel) &
    ", host provides " & provides

proc selectPlatformBinary*(vp: VersionedProvisioning;
                           cpu: PlatformCpu; os: PlatformOs):
    tuple[found: bool; binary: PlatformBinary] =
  ## Pre-PMC-2 signature, preserved. Resolution order:
  ##   1. exact match (cpu, os);
  ##   2. (pcAny, os) fallback;
  ##   3. (cpu, poAny) fallback;
  ##   4. (pcAny, poAny) fallback.
  ## Returns ``(false, PlatformBinary())`` if no entry matches.
  ##
  ## PMC-2: this is now ``selectPlatformBinaryEx`` with a target whose
  ## level is ``mlNone`` — a host that has stated nothing about its
  ## microarchitecture. For a catalog declaring no floors (every catalog
  ## that exists today) that is bit-for-bit the old behaviour. For a
  ## catalog that does declare floors it refuses them all, which is the
  ## safe direction for a caller that has not been taught to supply a
  ## host level, and the caller loses only the ability to SAY SO — use
  ## ``selectPlatformBinaryEx`` to get the shortfall.
  let sel = selectPlatformBinaryEx(vp, initPlatformTarget(cpu), os)
  (sel.found, sel.binary)

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

proc microarchLevelIdent(level: MicroarchLevel): string =
  ## PMC-2: the Nim ENUM IDENTIFIER, not the psABI spelling. The
  ## serializer emits Nim source that must re-evaluate under this module,
  ## and ``x86-64-v3`` is not an identifier.
  case level
  of mlNone: "mlNone"
  of mlX86_64_v1: "mlX86_64_v1"
  of mlX86_64_v2: "mlX86_64_v2"
  of mlX86_64_v3: "mlX86_64_v3"
  of mlX86_64_v4: "mlX86_64_v4"

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
  of afTarZst: "afTarZst"
  of afSevenZip: "afSevenZip"
  of afSevenZipSfx: "afSevenZipSfx"
  of afInstallerNsis: "afInstallerNsis"
  of afInstallerMsi: "afInstallerMsi"
  of afRaw: "afRaw"

proc launcherEmitKindIdent*(lek: LauncherEmitKind): string =
  case lek
  of lekPhar: "lekPhar"
  of lekJar: "lekJar"
  of lekScript: "lekScript"

proc serializeLauncherEmitSpec*(spec: LauncherEmitSpec): string =
  result = "LauncherEmitSpec(kind: " & launcherEmitKindIdent(spec.kind) &
    ", target: " & escapeString(spec.target) &
    ", interpreter_package_id: " & escapeString(spec.interpreter_package_id) &
    ", launcher_name: " & escapeString(spec.launcher_name) & ")"

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
  of imInstallerNsis: "imInstallerNsis"
  of imInstallerInnoSetup: "imInstallerInnoSetup"

proc serializePlatformBinary(pb: PlatformBinary): string =
  # Field order: sha256, sha512, sha1 — sha1 last to make it
  # visually clear that it's the deprecated branch (M1 weak-hash
  # acceptance). ``nested_7z`` (M3) is emitted ONLY when true so the
  # vast majority of catalog entries (all non-nested archives) keep
  # their compact one-line shape and the existing harvester output
  # bytes-equal-trees against the M67/M68 baseline.
  result = "PlatformBinary(cpu: " & cpuIdent(pb.cpu)
  # PMC-2: cpu_level emitted ONLY when a floor is declared. No checked-in
  # catalog declares one, so every packages/<tool>.nim round-trips through
  # ``serializeAsCode`` byte-identically — the widened type is NOT a
  # serialized-form change for anything that exists today. (When a floor IS
  # declared the emitted form gains a field, which a pre-PMC-2 build of this
  # module could not parse; that is a forward-compatibility break confined to
  # catalogs that opt in.)
  if pb.cpu_level != mlNone:
    result.add(", cpu_level: " & microarchLevelIdent(pb.cpu_level))
  result.add(", os: " & osIdent(pb.os) &
    ", url: " & escapeString(pb.url) &
    ", sha256: " & escapeString(pb.sha256) &
    ", sha512: " & escapeString(pb.sha512) &
    ", sha1: " & escapeString(pb.sha1) &
    ", extract_path: " & escapeString(pb.extract_path))
  if pb.nested_7z:
    result.add(", nested_7z: true")
  # M4: msi_admin_install emitted only when true so the M67/M68 baseline
  # round-trips byte-identical.
  if pb.msi_admin_install:
    result.add(", msi_admin_install: true")
  # M9.5: archive_format_override + bin_relpath_override emitted ONLY when
  # the per-platform override is in effect (has_archive_format_override
  # true, or bin_relpath_override non-empty). The Windows-only M67/M68
  # baseline never sets these — every existing catalog file round-trips
  # byte-identical through the serializer.
  if pb.has_archive_format_override:
    result.add(", archive_format_override: " &
      archiveFormatIdent(pb.archive_format_override))
    result.add(", has_archive_format_override: true")
  if pb.bin_relpath_override.len > 0:
    result.add(", bin_relpath_override: @[")
    for i, b in pb.bin_relpath_override:
      if i > 0: result.add(", ")
      result.add(escapeString(b))
    result.add("]")
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
  # M5: launcher_emit emitted ONLY when non-empty so the M67/M68 baseline
  # (every existing entry has none) round-trips byte-identical through
  # the harvester. Composer (the M5 target) renders an explicit
  # multi-line tail.
  if vp.launcher_emit.len > 0:
    result.add(",\n  launcher_emit: @[\n")
    for i, spec in vp.launcher_emit:
      result.add("    " & serializeLauncherEmitSpec(spec))
      if i + 1 < vp.launcher_emit.len:
        result.add(",")
      result.add("\n")
    result.add("  ]")
  result.add(")")
