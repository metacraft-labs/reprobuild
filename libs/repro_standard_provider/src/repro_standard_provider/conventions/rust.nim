## Rust language convention (Tier 2b) — Mode A "fine-grained" plugin.
##
## Recognises a single-crate Cargo project whose ``reprobuild.nim`` declares
## ``uses:`` containing ``rust`` (or ``cargo``) AND ships a conventional
## Cargo layout (``Cargo.toml`` plus ``src/main.rs`` for a binary or
## ``src/lib.rs`` for a library) AND has *no* ``build.rs`` and *no*
## ``[workspace]`` table — the convention spec
## (``reprobuild-specs/Language-Conventions/Rust.md`` §"Mode A — Fine-grained
## build graph") prescribes:
##
##   Pass 1 (metadata, per crate):
##     ``rustc --crate-name <n> --edition <e> --crate-type <bin|lib>
##       --emit=metadata,dep-info
##       --out-dir <scratch>/deps
##       -C metadata=<stable-hash> -C extra-filename=-<stable-hash>
##       <crate-root>.rs``
##     produces the ``lib<n>-<hash>.rmeta`` + ``<n>-<hash>.d`` depfile.
##
##   Pass 2 (codegen + link, per crate):
##     ``rustc --crate-name <n> --edition <e> --crate-type <bin|lib>
##       --emit=link,dep-info
##       --out-dir <scratch>/bin
##       -C metadata=<stable-hash> -C extra-filename=-<stable-hash>
##       <crate-root>.rs``
##     produces ``<n>.exe`` (or ``lib<n>.rlib`` for library crates) plus its
##     own depfile. Depends on Pass 1's id so the metadata edge is captured.
##
## **Design decision (M4 Option 1 — eager metadata extraction).** Like the
## M3 Nim convention's Option 1, we invoke ``cargo metadata
## --format-version=1 --no-deps`` at emit time to extract the crate's
## manifest info (package name, edition, target list). The alternative —
## driving the manifest read entirely from a hand-rolled TOML parser —
## would let us recognise without a working ``cargo`` on PATH, but the
## convention spec already requires ``cargo`` for workspace resolution
## anyway and Cargo.toml syntax is rich enough that re-implementing the
## TOML edge-cases buys nothing here.
##
## The eager cargo-metadata run also lets us fail fast with a useful
## diagnostic when the manifest is malformed or when ``[workspace]`` is
## present (workspaces are deferred to M4+1).
##
## **Workspaces and multi-bin crates: DEFERRED.** This M4 plugin
## intentionally rejects:
##   * Cargo manifests with a ``[workspace]`` table (single-crate only).
##   * Crates with ``[[bin]]`` array entries beyond the default
##     ``src/main.rs`` (would need one Pass-1/Pass-2 pair per binary
##     target plus cross-target dep edges).
##   * Crates with ``build.rs`` (forces Tier 1 / crude fallback — the
##     convention spec is explicit that build.rs presence degrades the
##     offending crate to Mode B, see §"Mode A trigger").
##   * Crates whose ``Cargo.toml`` declares ``[lib]`` and ``[[bin]]``
##     simultaneously (mixed crates would need both rmeta-then-rlib for
##     the library and rmeta-then-bin for the binary, with the bin's
##     metadata pass consuming the library's rmeta — implementable but
##     beyond the M4 scope).
## Each of these is handled by ``recognize`` returning ``false`` so the
## dispatch loop falls through; the M6 crude fallback will eventually
## handle them via cargo delegation.
##
## **Caveats**:
##   * Requires ``cargo`` and ``rustc`` on PATH at convention-emit time.
##     When either is missing, ``recognize`` returns ``false`` so dispatch
##     falls through to the "no convention matched" diagnostic with the
##     regular project hint.
##   * The convention always builds the *release* artifact (``--out-dir``
##     points at ``<scratch>/<crateName>/bin``). The Rust convention spec
##     defaults Mode A to release-profile output; debug-profile and
##     per-profile artifact dirs are an M4+1 surface.
##   * ``-C metadata`` / ``-C extra-filename`` use a stable FNV-1a hash of
##     ``crateName & "@" & edition`` — distinct from cargo's own
##     package-id hash because we don't have a published source URL or
##     features set in the M4 fixtures. This is fine for single-crate
##     builds where no downstream consumer expects rmeta compatibility
##     with ambient ``cargo check``; M4+1 must switch to cargo-compatible
##     hashes when multi-crate workspaces land.

import std/[algorithm, json, os, osproc, streams, strutils]

import repro_core
import repro_provider_runtime
import repro_project_dsl
import repro_standard_provider/convention
import repro_standard_provider/crude

const
  ScratchDirName* = ".repro/build"
    ## Top-level scratch directory under the project root the Rust
    ## convention writes into. Kept as a const so the e2e validator and
    ## any cleanup scripts agree with the convention on a single edit.
    ## Identical to the Nim convention's ``ScratchDirName`` — both
    ## languages own a per-entry subdirectory under this prefix.

type
  RustCrateKind = enum
    rckBinary
    rckLibrary

  RustCrateInfo = object
    ## Manifest info extracted from ``cargo metadata --no-deps`` for the
    ## single-crate-project case. Multi-crate workspaces are out of scope
    ## for M4 (``recognize`` rejects them).
    crateName: string
      ## ``-`` → ``_`` normalised crate name (rustc's ``--crate-name``).
    packageName: string
      ## Original ``[package].name`` for diagnostics.
    edition: string
      ## ``2015`` / ``2018`` / ``2021`` / ``2024``.
    kind: RustCrateKind
    sourcePath: string
      ## Absolute path to ``src/main.rs`` (bin) or ``src/lib.rs`` (lib).

proc readReprobuildSource(projectRoot: string): string =
  ## Read ``<projectRoot>/reprobuild.nim`` or return the empty string.
  ## Used by ``recognize``; never raises.
  let path = projectRoot / "reprobuild.nim"
  if not fileExists(extendedPath(path)):
    return ""
  try:
    readFile(extendedPath(path))
  except CatchableError:
    ""

proc usesIncludesRustOrCargo(source: string): bool =
  ## True when the ``uses:`` block names ``rust`` or ``cargo``. Mirrors
  ## the Nim convention's ``usesIncludesNim`` line-scan — diagnostic-grade,
  ## not a DSL evaluator.
  if source.len == 0:
    return false
  var inBlock = false
  for rawLine in source.splitLines():
    var line = rawLine
    let commentIdx = line.find('#')
    if commentIdx >= 0:
      line = line[0 ..< commentIdx]
    let stripped = line.strip()
    if stripped.len == 0:
      if inBlock:
        inBlock = false
      continue
    if inBlock:
      let leading = line.len > 0 and line[0] in {' ', '\t'}
      if not leading:
        inBlock = false
      else:
        for raw in stripped.split({',', ' ', '\t'}):
          let entry = raw.strip(chars = {' ', '\t', '"', '\'', ',', ';'})
          if entry.len == 0:
            continue
          let firstToken = entry.split({' ', '\t', '>', '<', '='})[0]
          if firstToken == "rust" or firstToken == "cargo":
            return true
        continue
    if stripped.startsWith("uses:"):
      let payload = stripped[5 .. ^1].strip()
      if payload.len == 0:
        inBlock = true
      else:
        var clean = payload
        if clean.startsWith("["):
          clean = clean[1 .. ^1]
        if clean.endsWith("]"):
          clean = clean[0 ..< ^1]
        for raw in clean.split({',', ' ', '\t'}):
          let entry = raw.strip(chars = {' ', '\t', '"', '\'', ',', ';'})
          if entry.len == 0:
            continue
          let firstToken = entry.split({' ', '\t', '>', '<', '='})[0]
          if firstToken == "rust" or firstToken == "cargo":
            return true
  false

proc cargoTomlHasWorkspace(cargoTomlPath: string): bool =
  ## Heuristic line scan for a ``[workspace]`` table header. We do NOT
  ## attempt to fully parse TOML — the M4 contract is that any
  ## ``[workspace]`` (or ``[workspace.something]``) header forces a
  ## ``recognize=false`` so the M4+1 workspace handler can take over once
  ## it lands. Same shape as the Cargo.toml ``[lib]`` / ``[[bin]]`` checks
  ## below.
  if not fileExists(extendedPath(cargoTomlPath)):
    return false
  var raw: string
  try:
    raw = readFile(extendedPath(cargoTomlPath))
  except CatchableError:
    return false
  for rawLine in raw.splitLines():
    var line = rawLine
    let commentIdx = line.find('#')
    if commentIdx >= 0:
      line = line[0 ..< commentIdx]
    let stripped = line.strip()
    if stripped == "[workspace]" or stripped.startsWith("[workspace."):
      return true
  false

proc cargoTomlHasExplicitBinOrLib(cargoTomlPath: string): bool =
  ## Heuristic line scan for ``[[bin]]`` or ``[lib]`` table headers in
  ## Cargo.toml. M4 only handles the *default* layout (one binary or one
  ## library at the conventional source path); explicit tables would mean
  ## one rustc per binary target plus mixed bin+lib edges, which is
  ## M4+1 surface.
  if not fileExists(extendedPath(cargoTomlPath)):
    return false
  var raw: string
  try:
    raw = readFile(extendedPath(cargoTomlPath))
  except CatchableError:
    return false
  for rawLine in raw.splitLines():
    var line = rawLine
    let commentIdx = line.find('#')
    if commentIdx >= 0:
      line = line[0 ..< commentIdx]
    let stripped = line.strip()
    if stripped == "[[bin]]" or stripped == "[lib]" or
       stripped.startsWith("[[bin.") or stripped.startsWith("[lib."):
      return true
  false

proc hasExtraBinSourceFiles(projectRoot: string): bool =
  ## True when ``src/bin/*.rs`` (or ``src/bin/<name>/main.rs``) exist —
  ## those are extra binaries beyond the conventional ``src/main.rs`` and
  ## are deferred to M4+1.
  let binDir = projectRoot / "src" / "bin"
  if not dirExists(extendedPath(binDir)):
    return false
  for entry in walkDirRec(binDir):
    if entry.toLowerAscii.endsWith(".rs"):
      return true
  false

proc rustcExecutable(): string =
  findExe("rustc")

proc cargoExecutable(): string =
  findExe("cargo")

proc normaliseCrateName(packageName: string): string =
  ## Rustc's crate names use ``_`` where Cargo packages use ``-``. The
  ## official cargo source calls this "crate name from package name" and
  ## applies it whenever the user hasn't explicitly set ``[lib].name``.
  result = newStringOfCap(packageName.len)
  for ch in packageName:
    if ch == '-':
      result.add('_')
    else:
      result.add(ch)

proc runCargoMetadata(projectRoot, cargoExe: string): JsonNode =
  ## Execute ``cargo metadata --format-version=1 --no-deps`` and parse
  ## the resulting JSON. ``--no-deps`` skips dependency resolution (and
  ## thus any network access), which is what we want — at M4 the standard
  ## provider relies on Cargo only for manifest parsing. We pass
  ## ``--offline`` too, even with ``--no-deps``, so a cold workspace
  ## without a populated registry index doesn't try to reach crates.io.
  let argv = @[
    cargoExe,
    "metadata",
    "--format-version=1",
    "--no-deps",
    "--offline",
    "--manifest-path",
    projectRoot / "Cargo.toml",
  ]
  let process = startProcess(argv[0], args = argv[1 .. ^1],
    options = {poUsePath})
  let output =
    if process.outputStream != nil: process.outputStream.readAll()
    else: ""
  let errOutput =
    if process.errorStream != nil: process.errorStream.readAll()
    else: ""
  let exitCode = process.waitForExit()
  process.close()
  if exitCode != 0:
    raise newException(ValueError,
      "rust convention: 'cargo metadata' exited " & $exitCode &
        " for " & projectRoot & ":\n" & errOutput)
  try:
    result = parseJson(output)
  except CatchableError as err:
    raise newException(ValueError,
      "rust convention: failed to parse 'cargo metadata' JSON output for " &
        projectRoot & ": " & err.msg)

proc extractCrateInfo(projectRoot: string;
                      metadata: JsonNode): RustCrateInfo =
  ## Walk the ``cargo metadata`` JSON for the single-crate case and
  ## extract the bits Pass 1/2 need. Raises ``ValueError`` if the manifest
  ## doesn't fit the M4 contract (multi-package workspace, missing
  ## conventional source file, etc.). The caller is expected to have
  ## already rejected ``[workspace]`` via the textual scan.
  if metadata.kind != JObject or "packages" notin metadata or
     metadata["packages"].kind != JArray:
    raise newException(ValueError,
      "rust convention: cargo metadata missing 'packages' array for " &
        projectRoot)
  let packages = metadata["packages"]
  if packages.len == 0:
    raise newException(ValueError,
      "rust convention: cargo metadata returned no packages for " &
        projectRoot)
  if packages.len != 1:
    raise newException(ValueError,
      "rust convention: cargo metadata returned " & $packages.len &
        " packages — multi-package workspaces are deferred (M4+1)")
  let pkg = packages[0]
  let packageName =
    if pkg.kind == JObject and "name" in pkg: pkg["name"].getStr()
    else: ""
  if packageName.len == 0:
    raise newException(ValueError,
      "rust convention: cargo metadata package missing 'name' for " &
        projectRoot)
  let edition =
    if pkg.kind == JObject and "edition" in pkg: pkg["edition"].getStr()
    else: "2021"
  if "targets" notin pkg or pkg["targets"].kind != JArray:
    raise newException(ValueError,
      "rust convention: cargo metadata package missing 'targets' for " &
        packageName)
  # Walk the targets array and pick the first bin or lib whose
  # ``src_path`` is the conventional one. ``cargo metadata`` always
  # returns one entry per target kind; the convention only fires when
  # exactly one of bin/lib is present and lives at the canonical path.
  var binTarget = newJNull()
  var libTarget = newJNull()
  var binTargetCount = 0
  var libTargetCount = 0
  for target in pkg["targets"]:
    if target.kind != JObject or "kind" notin target or
       target["kind"].kind != JArray:
      continue
    var isBin = false
    var isLib = false
    for k in target["kind"]:
      let kindStr = k.getStr()
      if kindStr == "bin":
        isBin = true
      elif kindStr == "lib" or kindStr == "rlib" or kindStr == "dylib":
        isLib = true
    if isBin:
      inc binTargetCount
      if binTarget.kind == JNull:
        binTarget = target
    elif isLib:
      inc libTargetCount
      if libTarget.kind == JNull:
        libTarget = target
  if binTargetCount > 1:
    raise newException(ValueError,
      "rust convention: package '" & packageName & "' has " &
        $binTargetCount & " binary targets — multi-bin crates are deferred (M4+1)")
  if binTargetCount == 1 and libTargetCount >= 1:
    raise newException(ValueError,
      "rust convention: package '" & packageName & "' declares both " &
        "[lib] and [[bin]] — mixed crates are deferred (M4+1)")
  var kind: RustCrateKind
  var chosenTarget: JsonNode
  if binTargetCount == 1:
    kind = rckBinary
    chosenTarget = binTarget
  elif libTargetCount == 1:
    kind = rckLibrary
    chosenTarget = libTarget
  else:
    raise newException(ValueError,
      "rust convention: package '" & packageName &
        "' has no bin or lib target — nothing to compile")
  if "src_path" notin chosenTarget:
    raise newException(ValueError,
      "rust convention: target for '" & packageName & "' missing 'src_path'")
  let srcPath = chosenTarget["src_path"].getStr()
  if srcPath.len == 0:
    raise newException(ValueError,
      "rust convention: target for '" & packageName & "' has empty src_path")
  result = RustCrateInfo(
    crateName:
      if "name" in chosenTarget: normaliseCrateName(chosenTarget["name"].getStr())
      else: normaliseCrateName(packageName),
    packageName: packageName,
    edition: edition,
    kind: kind,
    sourcePath: srcPath)

proc rustRecognize(projectRoot: string;
                   request: ProviderGraphRequest): bool {.gcsafe.} =
  ## Recognition contract (post-M6):
  ##   * ``reprobuild.nim`` mentions ``rust`` or ``cargo`` in ``uses:``
  ##   * ``<projectRoot>/Cargo.toml`` exists
  ##   * one of ``src/main.rs``, ``src/lib.rs`` exists
  ##   * ``Cargo.toml`` does NOT declare a ``[workspace]`` table
  ##     (deferred to M4+1)
  ##   * ``Cargo.toml`` does NOT declare explicit ``[[bin]]`` or ``[lib]``
  ##     tables (multi-bin / mixed-target crates are deferred to M4+1)
  ##   * ``src/bin/*.rs`` does NOT exist (extra binaries deferred)
  ##   * ``rustc`` and ``cargo`` are on PATH (so emit can run them)
  ##
  ## **M6 change**: ``build.rs`` is no longer a rejection condition.
  ## When present, the convention now CLAIMS the project at
  ## ``recognize`` time and routes the work to the Mode B crude
  ## fallback inside ``emitFragment``. This keeps dispatch order simple
  ## — the Rust convention is the single owner of any Rust project that
  ## passes the toolchain probe, and the routing decision (Mode A vs
  ## Mode B) is internal to the convention.
  let cargoTomlPath = projectRoot / "Cargo.toml"
  if not fileExists(extendedPath(cargoTomlPath)):
    return false
  let source = readReprobuildSource(projectRoot)
  if source.len == 0:
    return false
  if not usesIncludesRustOrCargo(source):
    return false
  if cargoTomlHasWorkspace(cargoTomlPath):
    return false
  if cargoTomlHasExplicitBinOrLib(cargoTomlPath):
    return false
  if hasExtraBinSourceFiles(projectRoot):
    return false
  let hasMain = fileExists(extendedPath(projectRoot / "src" / "main.rs"))
  let hasLib = fileExists(extendedPath(projectRoot / "src" / "lib.rs"))
  if not (hasMain or hasLib):
    return false
  if hasMain and hasLib:
    # Same as the [lib]+[[bin]] rejection above but caught at the
    # filesystem layer — M4+1 will route this through a mixed-crate path.
    return false
  if rustcExecutable().len == 0:
    return false
  if cargoExecutable().len == 0:
    return false
  true

proc scratchPathFor(projectRoot, crateName: string): string =
  projectRoot / ScratchDirName / crateName

proc depsPathFor(projectRoot, crateName: string): string =
  scratchPathFor(projectRoot, crateName) / "deps"

proc binPathFor(projectRoot, crateName: string): string =
  scratchPathFor(projectRoot, crateName) / "bin"

proc binaryOutputPath(projectRoot, crateName: string): string =
  when defined(windows):
    binPathFor(projectRoot, crateName) / (crateName & ".exe")
  else:
    binPathFor(projectRoot, crateName) / crateName

proc rlibOutputPath(projectRoot, crateName, stableHash: string): string =
  binPathFor(projectRoot, crateName) /
    ("lib" & crateName & "-" & stableHash & ".rlib")

proc rmetaOutputPath(projectRoot, crateName, stableHash: string): string =
  depsPathFor(projectRoot, crateName) /
    ("lib" & crateName & "-" & stableHash & ".rmeta")

proc metadataDepfilePath(projectRoot, crateName, stableHash: string): string =
  depsPathFor(projectRoot, crateName) /
    (crateName & "-" & stableHash & ".d")

proc linkDepfilePath(projectRoot, crateName, stableHash: string;
                     kind: RustCrateKind): string =
  case kind
  of rckBinary:
    binPathFor(projectRoot, crateName) / (crateName & ".d")
  of rckLibrary:
    binPathFor(projectRoot, crateName) /
      (crateName & "-" & stableHash & ".d")

proc collectRustSources(srcDir: string): seq[string] =
  ## Every ``.rs`` under ``<projectRoot>/src``. These become the declared
  ## inputs of both rustc passes so source-only edits invalidate the
  ## actions without needing the FS-snoop monitor. The depfile + depfile
  ## policy still own the *transitive* edges (``mod foo;`` /
  ## ``include!()`` discovery) — see Rust.md §"Implicit-dependency
  ## capture".
  if not dirExists(extendedPath(srcDir)):
    return @[]
  for entry in walkDirRec(srcDir):
    if entry.toLowerAscii.endsWith(".rs"):
      result.add(entry)
  result.sort(system.cmp[string])

proc stableHashHex(value: string): string =
  ## FNV-1a 64-bit hash, hex-encoded. Same algorithm as
  ## ``runtime_core.stableHashHex`` (which is private to that module);
  ## kept identical here so future cross-checks can compare hashes
  ## byte-for-byte if needed.
  var hash = 0xcbf29ce484222325'u64
  for ch in value:
    hash = hash xor uint64(ord(ch))
    hash = hash * 0x100000001b3'u64
  hash.toHex(16).toLowerAscii()

proc actionIdFor(prefix, crateName, detail: string): string =
  ## Build a Reprobuild-safe action id. Mirrors the Nim convention's
  ## ``actionIdFor`` so ``--log=actions`` output is consistent across
  ## conventions.
  var sanitized = ""
  for ch in detail:
    if ch in {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '-', '_', '.'}:
      sanitized.add(ch)
    else:
      sanitized.add('_')
  if sanitized.len == 0:
    sanitized = "x"
  prefix & "-" & crateName & "-" & sanitized

proc crateTypeArg(kind: RustCrateKind): string =
  case kind
  of rckBinary: "bin"
  of rckLibrary: "lib"

proc rustcArgvCommon(rustcExe, crateName, edition, crateType, outDir,
                     stableHash, sourcePath, emit: string;
                     applyExtraFilename: bool): seq[string] =
  ## Build the rustc argv shared between Pass 1 and Pass 2 — they differ
  ## only in ``--emit``, ``--out-dir``, and whether ``-C extra-filename``
  ## is applied. Output order is deterministic so the engine's
  ## fingerprint is stable.
  ##
  ## ``-C extra-filename`` controls whether rustc appends ``-<hash>`` to
  ## the produced artifact's filename. We always apply it to the
  ## metadata pass (the rmeta needs to be unique per crate so cross-crate
  ## --extern flags from M4+1 can target it by absolute path), and we
  ## apply it to the link pass for *libraries* (so the rlib uses the
  ## same convention as the rmeta). For binary link passes we omit it
  ## so the produced executable lands at ``<binDir>/<crateName>.exe``
  ## without the hash suffix — that matches what the user invokes after
  ## ``repro build`` and avoids a rename/copy step.
  result = @[
    rustcExe,
    "--crate-name", crateName,
    "--edition", edition,
    "--crate-type", crateType,
    "--emit=" & emit,
    "--out-dir", outDir,
    "-C", "metadata=" & stableHash,
  ]
  if applyExtraFilename:
    result.add("-C")
    result.add("extra-filename=-" & stableHash)
  result.add(sourcePath)

proc emitForCrate(projectRoot, rustcExe: string;
                  info: RustCrateInfo): tuple[metadataAction: BuildActionDef;
                                              linkAction: BuildActionDef] =
  ## Materialise the two-action graph for a single crate. Creates the
  ## scratch directories eagerly (rustc fails out otherwise — see the
  ## "error writing dependencies" smoke test). The metadata + bin output
  ## dirs deliberately differ so the engine's effect-claim bookkeeping
  ## doesn't have to disambiguate which action produced which artifact.
  let stableHash = stableHashHex(info.crateName & "@" & info.edition)
  let depsDir = depsPathFor(projectRoot, info.crateName)
  let binDir = binPathFor(projectRoot, info.crateName)
  createDir(extendedPath(depsDir))
  createDir(extendedPath(binDir))

  let crateType = crateTypeArg(info.kind)
  let metadataDepfile =
    metadataDepfilePath(projectRoot, info.crateName, stableHash)
  let rmetaOutput =
    rmetaOutputPath(projectRoot, info.crateName, stableHash)
  let metadataArgv = rustcArgvCommon(
    rustcExe = rustcExe,
    crateName = info.crateName,
    edition = info.edition,
    crateType = crateType,
    outDir = depsDir,
    stableHash = stableHash,
    sourcePath = info.sourcePath,
    emit = "metadata,dep-info",
    applyExtraFilename = true)
  let metadataInputs = block:
    var inputs = collectRustSources(projectRoot / "src")
    inputs.add(projectRoot / "Cargo.toml")
    inputs

  let metadataActionId =
    actionIdFor("rustc-metadata", info.crateName, "umbrella")
  let metadataAction = buildAction(
    id = metadataActionId,
    call = inlineExecCall(metadataArgv, projectRoot),
    inputs = metadataInputs,
    outputs = @[rmetaOutput, metadataDepfile],
    pool = "compile",
    depfile = metadataDepfile,
    dependencyPolicy = makeDepfilePolicy(metadataDepfile),
    commandStatsId = "rust.rustc-metadata")

  let linkDepfile =
    linkDepfilePath(projectRoot, info.crateName, stableHash, info.kind)
  let linkOutput =
    case info.kind
    of rckBinary: binaryOutputPath(projectRoot, info.crateName)
    of rckLibrary: rlibOutputPath(projectRoot, info.crateName, stableHash)
  let linkArgv = rustcArgvCommon(
    rustcExe = rustcExe,
    crateName = info.crateName,
    edition = info.edition,
    crateType = crateType,
    outDir = binDir,
    stableHash = stableHash,
    sourcePath = info.sourcePath,
    emit = "link,dep-info",
    applyExtraFilename = info.kind == rckLibrary)
  let linkInputs = block:
    var inputs = collectRustSources(projectRoot / "src")
    inputs.add(projectRoot / "Cargo.toml")
    # Declare the rmeta from the metadata pass as an input — captures
    # the pipelined edge in the action cache fingerprint. For binary
    # crates the rmeta is empty (rustc still writes the file), but
    # declaring it keeps the dep wiring symmetric and matches what the
    # Rust convention spec asks for in §"Cross-crate ordering edges".
    inputs.add(rmetaOutput)
    inputs

  let linkAction = buildAction(
    id = actionIdFor("rustc-link", info.crateName, "umbrella"),
    call = inlineExecCall(linkArgv, projectRoot),
    deps = @[metadataActionId],
    inputs = linkInputs,
    outputs = @[linkOutput, linkDepfile],
    pool = "compile",
    depfile = linkDepfile,
    dependencyPolicy = makeDepfilePolicy(linkDepfile),
    commandStatsId = "rust.rustc-link")

  (metadataAction, linkAction)

proc syntheticPackage(projectRoot: string;
                      info: RustCrateInfo): PackageDef =
  ## Build a minimal ``PackageDef`` for the runtime helper. The Rust
  ## convention doesn't go through DSL evaluation either — see the M3
  ## Nim convention's same proc.
  PackageDef(
    packageName: info.crateName,
    sourceFile: projectRoot / "reprobuild.nim",
    hasDevEnv: false,
    devEnvBodyHash: "",
    toolUses: @[])

proc hasBuildRs(projectRoot: string): bool =
  fileExists(extendedPath(projectRoot / "build.rs"))

proc rustCrudeFallback(projectRoot: string;
                       request: ProviderGraphRequest):
                         GraphFragment {.gcsafe.} =
  ## Mode B emitter for Rust projects that can't take the Mode A path
  ## (today: any project carrying a ``build.rs``). Delegates to
  ## ``cargo build --release --locked --offline`` under FS-snoop
  ## monitoring per the M6 spec.
  ##
  ## ``--offline`` prevents Cargo from reaching crates.io during the
  ## monitored run — any required crates must already live in the
  ## local registry cache. This matches the M4 convention's stance on
  ## hermetic builds and keeps the M6 outstanding-task about FS-snoop
  ## interacting with Cargo's network access trivially safe (no
  ## network access happens). ``--locked`` forces Cargo to use the
  ## checked-in ``Cargo.lock`` rather than regenerate it, which is the
  ## standard hermeticity flag for CI-grade builds.
  ##
  ## We still consult ``cargo metadata`` (offline, no-deps) to extract
  ## the package name so the synthetic ``PackageDef`` and action id
  ## carry the canonical crate identity. When that fails (malformed
  ## manifest, etc.) we fall back to the project directory's basename
  ## — the crude path is best-effort by design and shouldn't crash on
  ## metadata-extraction quirks.
  {.cast(gcsafe).}:
    let cargoExe = cargoExecutable()
    if cargoExe.len == 0:
      raise newException(ValueError,
        "rust convention: 'cargo' executable not on PATH; cannot run " &
          "Mode B crude fallback")
    var packageName = ""
    try:
      let metadata = runCargoMetadata(projectRoot, cargoExe)
      if metadata.kind == JObject and "packages" in metadata and
         metadata["packages"].kind == JArray and
         metadata["packages"].len > 0 and
         metadata["packages"][0].kind == JObject and
         "name" in metadata["packages"][0]:
        packageName = metadata["packages"][0]["name"].getStr()
    except CatchableError:
      packageName = ""
    if packageName.len == 0:
      packageName = projectRoot.extractFilename
    if packageName.len == 0:
      packageName = "rust-crude"
    let argv = @[
      cargoExe,
      "build",
      "--release",
      "--locked",
      "--offline",
    ]
    result = emitCrudeFragment(
      projectRoot = projectRoot,
      request = request,
      packageName = packageName,
      nativeBuildArgv = argv,
      outputDirs = ["target"])

proc rustEmitFragment(projectRoot: string;
                      request: ProviderGraphRequest):
                        GraphFragment {.gcsafe.} =
  ## Convention entry — eagerly invoke ``cargo metadata``, derive the
  ## per-crate info, register Pass 1 / Pass 2 via the DSL, and hand the
  ## whole thing to ``buildPackageFragment``.
  ##
  ## **M6 routing**: when the project carries a ``build.rs``, the Mode A
  ## graph would be wrong (rustc alone can't honour build-script env
  ## vars / linker hints) so we delegate to ``rustCrudeFallback`` which
  ## drives ``cargo build`` under FS-snoop monitoring. The routing
  ## decision is internal to the convention — the engine never sees a
  ## "Mode A failed, try Mode B" interaction.
  ##
  ## The DSL runtime mutates module-level registries that aren't
  ## annotated ``gcsafe`` (they predate the provider host). Same shape
  ## as the Nim convention's ``cast(gcsafe)`` escape hatch.
  {.cast(gcsafe).}:
    if hasBuildRs(projectRoot):
      return rustCrudeFallback(projectRoot, request)
    let rustcExe = rustcExecutable()
    if rustcExe.len == 0:
      raise newException(ValueError,
        "rust convention: 'rustc' executable not on PATH; cannot run rustc passes")
    let cargoExe = cargoExecutable()
    if cargoExe.len == 0:
      raise newException(ValueError,
        "rust convention: 'cargo' executable not on PATH; cannot extract crate metadata")
    let metadata = runCargoMetadata(projectRoot, cargoExe)
    let info = extractCrateInfo(projectRoot, metadata)
    if not fileExists(extendedPath(info.sourcePath)):
      raise newException(ValueError,
        "rust convention: declared crate source missing: " & info.sourcePath)
    let pkg = syntheticPackage(projectRoot, info)
    let registerAll = proc() =
      discard buildPool("compile", 8'u32)
      let pair = emitForCrate(projectRoot, rustcExe, info)
      let allActions = @[pair.metadataAction, pair.linkAction]
      discard target(info.crateName, allActions)
      defaultTarget(target("default", allActions))
    result = buildPackageFragment(pkg, request, registerAll,
      includeDefault = false)

proc rustConvention*(): LanguageConvention =
  ## The single value the standard provider binary registers at startup.
  ## Same factory shape as ``nimConvention`` so tests can build isolated
  ## registries.
  LanguageConvention(
    name: "rust",
    recognize: rustRecognize,
    emitFragment: rustEmitFragment,
    crudeFallback: rustCrudeFallback)
