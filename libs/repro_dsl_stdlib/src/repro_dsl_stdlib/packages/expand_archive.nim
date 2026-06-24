## Windows-System-Resources Phase F — ``expandArchive`` typed tool.
##
## A stdlib package that wraps platform-native archive extraction
## utilities behind a single typed ``build:`` surface so profile
## authors can write
##
## .. code-block:: nim
##
##   expandArchive.build(
##     archive = "C:\\actions-runner-cache\\runner.zip",
##     destination = "C:\\actions-runner",
##     marker = "C:\\actions-runner\\config.cmd",
##     requiresElevation = true)
##
## and the engine resolves the right native tool per OS:
##
##   * **Linux / macOS** — ``tar`` for tar-family archives, ``unzip``
##     for zip archives. Both are declared as stdlib provisioning stubs
##     (see ``tar.nim`` / ``unzip.nim``).
##   * **Windows** — ``Expand-Archive`` PowerShell cmdlet for zip
##     archives (built into every Windows PowerShell since 5.0; no
##     provisioning channel needed); ``tar.exe`` for tar-family archives
##     (ships in ``%SystemRoot%\System32\`` on Win11 — assumed
##     available, no provisioning channel needed).
##
## ## Lowering
##
## ``expandArchive.build(...)`` emits a ``BuildActionDef`` whose ``call``
## is an ``inlineExecCall(...)`` — the same lowering path Phase E pins
## for elevated edges. The platform branch logic lives in this Nim
## wrapper (a single ``when defined(windows): ... else: ...`` block at
## profile-COMPILE time) so the lowered ``BuildActionDef`` carries a
## deterministic argv per host.
##
## ## Idempotency
##
## ``marker`` is wired into the action's ``outputs`` — the build engine
## handles "skip if output exists and inputs haven't changed" via its
## normal cache/output mechanism. Conventionally ``marker`` is a file
## the archive itself extracts (e.g. ``config.cmd`` for the
## actions-runner zip).
##
## ## Elevation
##
## ``requiresElevation = true`` propagates straight to the
## ``BuildActionDef.requiresElevation`` flag introduced in Phase E.
## When the engine encounters an elevated edge it routes the spawn
## through the privileged-operation broker (``mkInfraApplyBrokerSpawn``
## from Phase E's CLI seam).

import std/strutils

import repro_project_dsl

# The native real-tools' provisioning blocks must land in
# ``registeredPackages()`` so the engine can resolve them via
# ``toolIdentityRefs`` at fork time.
import repro_dsl_stdlib/packages/tar as tar_module
import repro_dsl_stdlib/packages/unzip as unzip_module

export tar_module
export unzip_module

# ---------------------------------------------------------------------------
# Format auto-detection
# ---------------------------------------------------------------------------

type
  ExpandArchiveFormat* = enum
    ## The format axis. ``eafUnknown`` is the explicit unset slot used
    ## by the ``format = ""`` default; the auto-detect helper resolves
    ## it from the archive's filename suffix.
    eafUnknown, eafZip, eafTar, eafTarGz, eafTarBz2, eafTarXz, eafSevenZip

proc parseExpandArchiveFormat*(value: string): ExpandArchiveFormat =
  ## Map a spec'd ``format`` string to the typed enum. The accepted
  ## tags mirror the spec §2.2 list verbatim. Empty / "auto" routes the
  ## caller into ``detectExpandArchiveFormat`` below.
  case value.strip().toLowerAscii()
  of "", "auto": eafUnknown
  of "zip": eafZip
  of "tar": eafTar
  of "tar.gz", "tgz", "targz": eafTarGz
  of "tar.bz2", "tbz", "tbz2", "tarbz2": eafTarBz2
  of "tar.xz", "txz", "tarxz": eafTarXz
  of "7z", "sevenzip": eafSevenZip
  else:
    raise newException(ValueError,
      "expandArchive: unknown format '" & value & "' " &
      "(accepted: zip / tar / tar.gz / tar.bz2 / tar.xz / 7z)")

proc detectExpandArchiveFormat*(archive: string): ExpandArchiveFormat =
  ## Filename-suffix dispatcher. The walk is greedy on the longer
  ## suffixes first so ``.tar.gz`` wins over ``.gz`` and the
  ## double-extension variants land on the right branch.
  let lowered = archive.toLowerAscii()
  if lowered.endsWith(".tar.gz") or lowered.endsWith(".tgz"):
    return eafTarGz
  if lowered.endsWith(".tar.bz2") or lowered.endsWith(".tbz2") or
      lowered.endsWith(".tbz"):
    return eafTarBz2
  if lowered.endsWith(".tar.xz") or lowered.endsWith(".txz"):
    return eafTarXz
  if lowered.endsWith(".tar"):
    return eafTar
  if lowered.endsWith(".zip"):
    return eafZip
  if lowered.endsWith(".7z"):
    return eafSevenZip
  raise newException(ValueError,
    "expandArchive: cannot infer format from archive name '" & archive &
    "' (extension not recognised — pass an explicit `format = ...`)")

proc resolveExpandArchiveFormat*(archive, format: string):
    ExpandArchiveFormat =
  ## Caller-facing dispatcher: honour an explicit ``format`` override
  ## first, fall back to filename auto-detect when unset.
  let explicit = parseExpandArchiveFormat(format)
  if explicit != eafUnknown:
    return explicit
  detectExpandArchiveFormat(archive)

proc isTarFamily*(fmt: ExpandArchiveFormat): bool =
  ## Tar-family formats share the same ``tar -xf`` invocation skeleton;
  ## the compression switch differs but the dispatch path is the same.
  fmt in {eafTar, eafTarGz, eafTarBz2, eafTarXz}

# ---------------------------------------------------------------------------
# Argv assemblers — pure helpers, exported for test pinning
# ---------------------------------------------------------------------------

proc tarCompressionFlag*(fmt: ExpandArchiveFormat): string =
  ## Map a tar-family format to ``tar``'s single-letter compression
  ## switch. The empty return signals "no compression flag" (used for
  ## ``eafTar`` plain).
  case fmt
  of eafTar: ""
  of eafTarGz: "-z"
  of eafTarBz2: "-j"
  of eafTarXz: "-J"
  else:
    raise newException(ValueError,
      "tarCompressionFlag: not a tar-family format: " & $fmt)

proc buildZipArgvWindows*(archive, destination: string): seq[string] =
  ## PowerShell ``Expand-Archive`` invocation. ``-Force`` overwrites
  ## existing files in the destination (matches Linux/macOS ``unzip
  ## -o``); ``-NoProfile`` skips the operator's PowerShell profile
  ## so a slow / failing ``$PROFILE`` does not stall the apply.
  @["powershell", "-NoProfile", "-Command",
    "Expand-Archive -Path \"" & archive &
    "\" -DestinationPath \"" & destination & "\" -Force"]

proc buildZipArgvPosix*(archive, destination: string): seq[string] =
  ## InfoZIP invocation. ``-q`` quiets the per-file output;
  ## ``-o`` overwrites existing files without prompting (matches
  ## Windows ``Expand-Archive -Force``); ``-d`` selects the
  ## destination directory.
  @["unzip", "-q", "-o", archive, "-d", destination]

proc buildTarArgv*(archive, destination: string;
                   fmt: ExpandArchiveFormat;
                   stripComponents: int): seq[string] =
  ## Tar invocation, shared across Linux / macOS / Windows (Win11 ships
  ## ``tar.exe`` in System32). ``-x`` extracts; ``-f`` selects the
  ## archive; ``-C`` selects the destination; the compression switch
  ## (``-z`` / ``-j`` / ``-J``) is inserted only when non-empty.
  if not isTarFamily(fmt):
    raise newException(ValueError,
      "buildTarArgv: not a tar-family format: " & $fmt)
  if stripComponents < 0:
    raise newException(ValueError,
      "expandArchive.stripComponents must be >= 0, got " &
      $stripComponents)
  var args = @["tar"]
  let comp = tarCompressionFlag(fmt)
  if comp.len > 0:
    args.add(comp)
  args.add("-x")
  args.add("-f")
  args.add(archive)
  args.add("-C")
  args.add(destination)
  if stripComponents > 0:
    args.add("--strip-components=" & $stripComponents)
  args

# ---------------------------------------------------------------------------
# Platform dispatch — invoked at profile-COMPILE time
# ---------------------------------------------------------------------------

proc resolveExpandArchiveArgv*(archive, destination: string;
                               fmt: ExpandArchiveFormat;
                               stripComponents: int;
                               onWindows: bool): seq[string] =
  ## Pure dispatch over (format x platform). Exported so tests can
  ## drive both branches from a single Linux test host (the production
  ## ``build`` proc below ties ``onWindows`` to the host's
  ## ``defined(windows)`` value).
  case fmt
  of eafUnknown:
    raise newException(ValueError,
      "resolveExpandArchiveArgv: format is eafUnknown — caller must " &
      "resolve via resolveExpandArchiveFormat first")
  of eafZip:
    if stripComponents != 0:
      # The two zip extractors have no native ``--strip-components``
      # analogue. The spec says: "for zip it's emulated by post-extract
      # rename, or omitted with a clear error if not supported on the
      # chosen tool." We pick the error path — the typed wrapper is a
      # thin lowering; emulation would expand the action's argv into
      # a multi-step shell pipeline whose audit trail is harder to
      # reason about.
      raise newException(ValueError,
        "expandArchive: stripComponents is not supported for zip " &
        "archives (got stripComponents = " & $stripComponents &
        ") — extract the archive and rename in a follow-up step.")
    if onWindows:
      result = buildZipArgvWindows(archive, destination)
    else:
      result = buildZipArgvPosix(archive, destination)
  of eafTar, eafTarGz, eafTarBz2, eafTarXz:
    # Tar dispatch is the same on every platform: ``tar -xf <archive>
    # -C <dest> [comp-flag] [--strip-components=N]``. Win11 ships
    # ``tar.exe`` in ``System32`` so the argv carries no platform
    # branch. (BSD tar on macOS understands the same ``-x -f -C
    # --strip-components`` surface; the compression switches match
    # GNU tar.)
    result = buildTarArgv(archive, destination, fmt, stripComponents)
  of eafSevenZip:
    # The spec explicitly lists ``7z`` as an accepted ``format = ...``
    # value but does NOT enumerate an argv shape (the underlying
    # 7-Zip provisioning is the ``sevenzip.nim`` MSI on Windows; on
    # Linux/macOS the closest equivalent is ``7z`` from ``p7zip``).
    # Refuse politely until a recipe lands that actually needs it.
    raise newException(ValueError,
      "expandArchive: 7z extraction is not yet implemented; pass an " &
      "archive of format zip / tar / tar.gz / tar.bz2 / tar.xz instead.")

proc markerInsideDestination*(marker, destination: string): bool =
  ## A marker that lives outside its destination is almost always an
  ## operator typo — the archive cannot write to it, so the cache
  ## layer's "skip if output exists" path never fires. The build
  ## helper enforces this invariant at lowering time so the failure
  ## surfaces at the recipe author's keyboard, not on a production
  ## host.
  ##
  ## Mixed-separator paths (the spec example uses Windows backslashes
  ## even when running on a Linux test host) are normalised with
  ## ``replace`` before the prefix comparison so ``C:\foo\bar`` is
  ## recognised as inside ``C:\foo``.
  if marker.len == 0 or destination.len == 0:
    return false
  proc canon(p: string): string =
    var lowered = p
    when not defined(windows):
      # On non-Windows hosts the input may still be a Windows-style
      # path (when the test fixture mirrors a Windows recipe). We
      # canonicalise backslash -> forward slash so the prefix check
      # is direction-agnostic; the path itself stays unevaluated
      # because we are not touching the filesystem here.
      lowered = lowered.replace("\\", "/")
    if lowered.len > 1 and lowered[^1] in {'/', '\\'}:
      lowered.setLen(lowered.len - 1)
    lowered
  let m = canon(marker)
  let d = canon(destination)
  if m == d:
    return false
  m.startsWith(d & "/")

# ---------------------------------------------------------------------------
# Default action-id derivation
# ---------------------------------------------------------------------------

proc sanitizeExpandArchiveSlug(value: string): string =
  ## Reduce a path to the limited character set the action-id slot
  ## accepts (alphanumerics + ``-``/``_``/``.``). Used by the default
  ## action-id helper below.
  for ch in value:
    if ch in {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '-', '_', '.'}:
      result.add(ch)
    else:
      result.add('_')
  if result.len == 0:
    result = "archive"

proc defaultExpandArchiveActionId*(archive, destination: string): string =
  ## Stable default action id when the caller does not pass an explicit
  ## ``address``. Mirrors the convention ``autotools_package`` uses
  ## (``autotools-fetch-<sanitized>``).
  "expand-archive-" & sanitizeExpandArchiveSlug(archive) & "-" &
    sanitizeExpandArchiveSlug(destination)

# ---------------------------------------------------------------------------
# Provisioning skeleton — the typed-tool wrapper does not itself need a
# provisioning channel (the native tools' channels do), but the
# ``expandArchive`` symbol must resolve to a callable record. A
# provisioning-only ``package`` block keeps that contract.
# ---------------------------------------------------------------------------

package `expandArchive`:
  provisioning:
    # ``expandArchive`` is a thin Nim wrapper over native tools; the
    # tools themselves carry the real provisioning channels
    # (``packages/tar.nim``, ``packages/unzip.nim``). The package
    # declaration here exists so the ``expandArchive`` symbol resolves
    # through the same DSL surface as ``tar`` / ``unzip`` / ``gcc`` /
    # ``cmake`` (every typed-tool consumer expects a package frame).
    # Nix provides ``coreutils`` as an inert anchor; the real fork
    # never invokes it.
    nixPackage "nixpkgs#coreutils", executablePath = "bin/true",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="

# ---------------------------------------------------------------------------
# Typed ``build:`` callable
# ---------------------------------------------------------------------------

proc build*(archive: string;
            destination: string;
            marker: string;
            requiresElevation = false;
            format = "";
            stripComponents = 0;
            address = "";
            dependsOn: openArray[string] = [];
            extraInputs: openArray[string] = []): BuildActionDef
    {.discardable.} =
  ## Lower an ``expandArchive.build(...)`` call to a single
  ## ``BuildActionDef`` whose ``call`` is an ``inlineExecCall(argv)``
  ## targeting the resolved native tool.
  ##
  ## Parameters:
  ##
  ## ``archive``
  ##   Absolute path of the archive on the target system. Used both as
  ##   the action's argv input and as a build-time input (so the
  ##   engine's cache invalidates when the archive bytes change).
  ##
  ## ``destination``
  ##   Absolute path of the extraction root. The native tool creates
  ##   this directory if missing (``Expand-Archive`` requires
  ##   ``-Force``; ``unzip`` + ``tar`` create on extract).
  ##
  ## ``marker``
  ##   Idempotency marker — a file the archive itself contains. Wired
  ##   into ``outputs`` so the engine's "skip if output exists" path
  ##   short-circuits re-extraction.
  ##
  ## ``requiresElevation``
  ##   Propagates to ``BuildActionDef.requiresElevation`` (Phase E).
  ##   When ``true`` the engine routes the spawn through the
  ##   privileged-operation broker.
  ##
  ## ``format``
  ##   Explicit format selector. Empty (default) auto-detects from the
  ##   archive's filename suffix. Accepts ``zip`` / ``tar`` /
  ##   ``tar.gz`` / ``tar.bz2`` / ``tar.xz`` / ``7z``.
  ##
  ## ``stripComponents``
  ##   ``--strip-components`` value for tar-family archives. Must be
  ##   ``0`` for zip (the zip extractors have no native equivalent;
  ##   the wrapper raises if non-zero is passed).
  ##
  ## ``address``
  ##   Optional caller-supplied action id; empty (default) routes to
  ##   ``defaultExpandArchiveActionId``.
  ##
  ## ``dependsOn``
  ##   Standard build-graph deps. Forwarded verbatim to ``buildAction``.
  ##
  ## ``extraInputs``
  ##   Additional input paths the engine should fingerprint. The
  ##   archive itself is always added.
  if archive.len == 0:
    raise newException(ValueError,
      "expandArchive.build: archive must be non-empty")
  if destination.len == 0:
    raise newException(ValueError,
      "expandArchive.build: destination must be non-empty")
  if marker.len == 0:
    raise newException(ValueError,
      "expandArchive.build: marker must be non-empty " &
      "(marker is the action's output and idempotency anchor)")
  if not markerInsideDestination(marker, destination):
    raise newException(ValueError,
      "expandArchive.build: marker '" & marker &
      "' must live inside destination '" & destination & "'")
  let fmt = resolveExpandArchiveFormat(archive, format)
  when defined(windows):
    const onWin = true
  else:
    const onWin = false
  let argv = resolveExpandArchiveArgv(archive, destination, fmt,
    stripComponents, onWin)
  let call = inlineExecCall(argv)
  let actionId =
    if address.len > 0: address
    else: defaultExpandArchiveActionId(archive, destination)
  var inputs: seq[string] = @[archive]
  for extra in extraInputs:
    if extra notin inputs:
      inputs.add(extra)
  # The native tool's name is the first argv element. We thread it
  # through ``toolIdentityRefs`` so the engine's tool-identity resolver
  # prepends the resolved bin dir to PATH at fork time. On Windows the
  # spawn target is ``powershell`` (zip) or ``tar`` (tar-family); on
  # POSIX it is ``unzip`` (zip) or ``tar`` (tar-family). ``powershell``
  # itself does not carry a stdlib provisioning channel — the engine's
  # fall-through resolver lets system-PATH wins through unmodified.
  let toolName = argv[0]
  result = buildAction(
    id = actionId,
    call = call,
    deps = dependsOn,
    inputs = inputs,
    outputs = @[marker],
    cacheable = true,
    commandStatsId = "expandArchive." & $fmt,
    toolIdentityRefs = @[toolName],
    requiresElevation = requiresElevation)
