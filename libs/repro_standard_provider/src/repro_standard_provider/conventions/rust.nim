## Rust language convention (Tier 2b) — Mode A "fine-grained" plugin.
##
## Recognises a Cargo project whose ``reprobuild.nim`` declares ``uses:``
## containing ``rust`` (or ``cargo``) AND ships a conventional Cargo
## layout. The convention spec
## (``reprobuild-specs/Language-Conventions/Rust.md`` §"Mode A — Fine-grained
## build graph") prescribes:
##
##   Pass 1 (metadata, per crate target):
##     ``rustc --crate-name <n> --edition <e> --crate-type <bin|lib>
##       --emit=metadata,dep-info
##       --out-dir <scratch>/deps
##       -C metadata=<stable-hash> -C extra-filename=-<stable-hash>
##       <crate-root>.rs``
##     produces the ``lib<n>-<hash>.rmeta`` + ``<n>-<hash>.d`` depfile.
##
##   Pass 2 (codegen + link, per crate target):
##     ``rustc --crate-name <n> --edition <e> --crate-type <bin|lib>
##       --emit=link,dep-info
##       --out-dir <scratch>/bin
##       -C metadata=<stable-hash> [-C extra-filename=-<stable-hash>]
##       [--extern <dep-name>=<dep-rlib>] ...
##       <crate-root>.rs``
##     produces ``<n>.exe`` (bin) or ``lib<n>-<hash>.rlib`` (lib) plus its
##     own depfile. Depends on Pass 1's id so the metadata edge is captured.
##
## **M13 extensions** over M4's single-crate-binary baseline:
##
##   * Library-only crates (``src/lib.rs`` with no ``src/main.rs``). The
##     convention now claims them and emits the two-action pipeline with
##     ``--crate-type lib --emit=link,dep-info`` producing ``lib<n>-<hash>.rlib``.
##   * ``[lib]`` and ``[[bin]]`` array entries in ``Cargo.toml``. The
##     convention iterates every ``bin``/``lib`` target reported by
##     ``cargo metadata`` and emits one (metadata, link) pair per target.
##     Test targets (``kind: ["test"]``), example targets, and benchmarks
##     are intentionally skipped at the M13 surface — they're test-runner
##     territory (deferred to a later milestone).
##   * Workspaces (``[workspace] members = [...]``). The convention
##     enumerates every member package, emits per-target compile/link
##     actions for each, and wires inter-crate ``--extern <name>=<rmeta>``
##     edges based on each member's ``dependencies`` array (only path
##     deps that resolve to another workspace member — crates.io / git
##     deps fall through to whatever rustc/cargo can find on the system
##     after the convention's offline run, which is sufficient for the
##     M13 fixtures whose workspace deps are purely path-local).
##
## **Design decision (M4 Option 1 — eager metadata extraction).** Like the
## M3 Nim convention's Option 1, we invoke ``cargo metadata
## --format-version=1 --no-deps --offline`` at emit time to extract each
## crate's manifest info (package name, edition, target list,
## dependencies). The alternative — driving the manifest read entirely
## from a hand-rolled TOML parser — would let us recognise without a
## working ``cargo`` on PATH, but the convention spec already requires
## ``cargo`` for workspace resolution anyway and Cargo.toml syntax is
## rich enough that re-implementing the TOML edge-cases buys nothing
## here.
##
## **Still deferred** (post-M13):
##   * ``build.rs`` crates — they keep routing through the Mode B crude
##     fallback inside ``emitFragment``.
##   * Crates with ``[dependencies]`` resolving to crates.io / git
##     sources. Pass-through to whatever rustc finds; the M13 fixtures
##     don't exercise this path.
##   * Test targets (``kind: ["test"]``), examples, benches — these need
##     a per-test runner that consumes the library's rmeta plus its own
##     source. Tracked by the milestone's M14+ test work.
##
## **Caveats**:
##   * Requires ``cargo`` and ``rustc`` on PATH at convention-emit time.
##     When either is missing, ``recognize`` returns ``false`` so dispatch
##     falls through to the "no convention matched" diagnostic.
##   * The convention always builds the *release* artifact. The Rust
##     convention spec defaults Mode A to release-profile output; debug-
##     profile and per-profile artifact dirs are an outstanding surface.
##   * ``-C metadata`` / ``-C extra-filename`` use a stable FNV-1a hash of
##     ``crateName & "@" & edition`` — distinct from cargo's own
##     package-id hash because we don't have a published source URL or
##     features set in the M13 fixtures. This is fine for the
##     workspace/library cases where no downstream consumer expects
##     rmeta compatibility with ambient ``cargo check``.

import std/[algorithm, json, os, osproc, strutils, tables]

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
  RustTargetKind = enum
    rtkBinary
    rtkLibrary

  RustTarget = object
    ## One ``bin`` or ``lib`` target reported by ``cargo metadata`` —
    ## flattened so the emitter doesn't have to keep peeking at the JSON.
    crateName: string
      ## ``-`` → ``_`` normalised crate name (rustc's ``--crate-name``).
      ## For libraries this is also the basename of the ``rlib``/``rmeta``.
    edition: string
    kind: RustTargetKind
    sourcePath: string
      ## Absolute path to the target's crate root (``main.rs``/``lib.rs``
      ## or whatever ``Cargo.toml`` declares).

  RustPackage = object
    ## One workspace member (or, in the single-crate case, the entire
    ## project). Carries the package's manifest path so we can wire
    ## workspace deps via path comparison.
    packageName: string
      ## Original ``[package].name`` for diagnostics.
    manifestPath: string
      ## Absolute path to this package's ``Cargo.toml``.
    manifestDir: string
      ## ``parentDir`` of ``manifestPath`` — the directory cargo treats
      ## as the package root. Used to resolve workspace path deps.
    targets: seq[RustTarget]
    workspaceDeps: seq[string]
      ## Names of OTHER workspace members this package depends on (as the
      ## package names appear in cargo metadata — pre-normalisation).
      ## crates.io / git deps are filtered out: the M13 surface only wires
      ## ``--extern`` edges for path deps that resolve to a sibling
      ## workspace member.

  RustProject = object
    ## The full project view the emitter walks. ``packages`` always
    ## contains at least one entry; for workspaces it contains every
    ## member.
    packages: seq[RustPackage]
    isWorkspace: bool

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
  ## Heuristic line scan for a ``[workspace]`` table header. Used by
  ## ``recognize`` to short-circuit on the presence of a workspace before
  ## running ``cargo metadata`` — the metadata call still happens at emit
  ## time, but ``recognize`` should stay fast and side-effect-free.
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

proc cargoTomlHasPackageTable(cargoTomlPath: string): bool =
  ## True when ``Cargo.toml`` declares a ``[package]`` table — i.e. it's
  ## either a standalone crate manifest, or a workspace root that ALSO
  ## carries a member package. We need this to distinguish the workspace
  ## with-no-package-at-root case (``[workspace]`` only, no ``src/``)
  ## from the standalone crate case.
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
    if stripped == "[package]" or stripped.startsWith("[package."):
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

proc extractFirstJsonObject(blob: string): string =
  ## Slice out the first balanced ``{ ... }`` JSON object in ``blob``,
  ## skipping any leading non-JSON noise (e.g. cargo log lines that
  ## landed in the captured stream because ``poStdErrToStdOut`` is in
  ## effect). Tracks brace depth while honouring JSON string literals
  ## (including ``\"`` escapes) so braces inside strings don't throw
  ## off the count.
  var depth = 0
  var startIdx = -1
  var inString = false
  var escape = false
  for i in 0 ..< blob.len:
    let ch = blob[i]
    if inString:
      if escape:
        escape = false
      elif ch == '\\':
        escape = true
      elif ch == '"':
        inString = false
    else:
      case ch
      of '"':
        inString = true
      of '{':
        if depth == 0:
          startIdx = i
        inc depth
      of '}':
        dec depth
        if depth == 0 and startIdx >= 0:
          return blob[startIdx .. i]
      else:
        discard
  ""

proc runCargoMetadata(projectRoot, cargoExe: string): JsonNode =
  ## Execute ``cargo metadata --format-version=1 --no-deps --offline`` and
  ## parse the resulting JSON. ``--no-deps`` skips dependency resolution
  ## (and thus any network access); ``--offline`` is belt-and-braces. For
  ## workspaces, cargo emits every member's package info in the
  ## ``packages`` array.
  ##
  ## **M6.5 pipe-buffer audit**: ``execCmdEx`` continuously drains the
  ## merged stream so workspaces with hundreds of crates don't deadlock
  ## the Windows OS pipe. See the original M4 commit message for the
  ## rationale.
  let argv = @[
    cargoExe,
    "metadata",
    "--format-version=1",
    "--no-deps",
    "--offline",
    "--manifest-path",
    projectRoot / "Cargo.toml",
  ]
  let cmd = quoteShellCommand(argv)
  let (output, exitCode) = execCmdEx(cmd,
    options = {poStdErrToStdOut, poUsePath})
  if exitCode != 0:
    raise newException(ValueError,
      "rust convention: 'cargo metadata' exited " & $exitCode &
        " for " & projectRoot & ":\n" & output)
  let jsonText = extractFirstJsonObject(output)
  if jsonText.len == 0:
    raise newException(ValueError,
      "rust convention: 'cargo metadata' produced no JSON object for " &
        projectRoot & ":\n" & output)
  try:
    result = parseJson(jsonText)
  except CatchableError as err:
    raise newException(ValueError,
      "rust convention: failed to parse 'cargo metadata' JSON output for " &
        projectRoot & ": " & err.msg)

proc normalisedManifestDir(path: string): string =
  ## Canonicalise a manifest directory path for cross-package comparison:
  ## ``parentDir`` of the manifest, then forward-slash + lower-case on
  ## Windows so path deps with mixed-case drive letters or ``../`` segments
  ## still match between consumer and producer.
  var d = path.parentDir
  # ``..`` collapsing inside cargo metadata's reported manifest_path is
  # already done — cargo emits absolute, canonical paths. We just
  # normalise the separator + case for case-insensitive filesystems so
  # the path-deps lookup table works.
  d = d.replace('\\', '/')
  when defined(windows):
    d = d.toLowerAscii
  d

proc extractTargets(pkgNode: JsonNode; edition: string): seq[RustTarget] =
  ## Walk a package's ``targets`` array and keep only the ``bin`` / ``lib``
  ## ones. Tests, examples, benches, custom-build targets are skipped at
  ## the M13 surface — those need extra wiring (test runner, etc.) that's
  ## tracked by later milestones.
  if "targets" notin pkgNode or pkgNode["targets"].kind != JArray:
    return @[]
  for target in pkgNode["targets"]:
    if target.kind != JObject or "kind" notin target or
       target["kind"].kind != JArray:
      continue
    var isBin = false
    var isLib = false
    var isOther = false
    for k in target["kind"]:
      case k.getStr()
      of "bin":
        isBin = true
      of "lib", "rlib":
        isLib = true
      of "dylib", "cdylib", "staticlib":
        # Treat as a lib target for M13 — same Pass 1/Pass 2 shape with
        # a tweaked ``--crate-type``. We currently always pass
        # ``--crate-type lib`` (rlib by default) which is what cargo
        # would emit for a default lib target; cdylib/staticlib variants
        # are an outstanding follow-up.
        isLib = true
      else:
        isOther = true
    # Tests/examples/benches: skip silently. They show up alongside the
    # primary bin/lib for crates with ``tests/`` directories.
    if (not isBin) and (not isLib):
      continue
    if "src_path" notin target:
      continue
    let srcPath = target["src_path"].getStr()
    if srcPath.len == 0:
      continue
    let rawName =
      if "name" in target: target["name"].getStr()
      else: ""
    if rawName.len == 0:
      continue
    let kind = if isBin: rtkBinary else: rtkLibrary
    result.add(RustTarget(
      crateName: normaliseCrateName(rawName),
      edition: edition,
      kind: kind,
      sourcePath: srcPath))
    if isOther:
      # Future-proofing: don't fail loud, but a custom kind on the same
      # target as bin/lib is unusual enough that the comment surfaces in
      # ``--log=actions`` debugging if anyone hits it.
      discard

proc loadProject(projectRoot: string;
                 metadata: JsonNode): RustProject =
  ## Parse ``cargo metadata`` into our flattened ``RustProject``. Detects
  ## workspace mode via ``workspace_members.len > 1`` OR the presence of
  ## a ``[workspace]`` header at the root; for single-crate projects we
  ## still consume the one-member array shape that ``cargo metadata``
  ## returns.
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
  # First pass: build a manifest-dir → package-name lookup table so the
  # second pass can resolve path-dep edges across workspace members
  # without re-walking the JSON. ``cargo metadata`` always emits absolute
  # ``manifest_path`` values; we canonicalise to forward slashes +
  # lower-case (Windows) so consumer/producer paths compare equal.
  var manifestDirToName = initTable[string, string]()
  for pkgNode in packages:
    if pkgNode.kind != JObject:
      continue
    let name =
      if "name" in pkgNode: pkgNode["name"].getStr()
      else: ""
    let mpath =
      if "manifest_path" in pkgNode: pkgNode["manifest_path"].getStr()
      else: ""
    if name.len == 0 or mpath.len == 0:
      continue
    manifestDirToName[normalisedManifestDir(mpath)] = name

  for pkgNode in packages:
    if pkgNode.kind != JObject:
      continue
    let name =
      if "name" in pkgNode: pkgNode["name"].getStr()
      else: ""
    if name.len == 0:
      raise newException(ValueError,
        "rust convention: cargo metadata package missing 'name' for " &
          projectRoot)
    let edition =
      if "edition" in pkgNode: pkgNode["edition"].getStr()
      else: "2021"
    let manifestPath =
      if "manifest_path" in pkgNode: pkgNode["manifest_path"].getStr()
      else: ""
    let manifestDir =
      if manifestPath.len > 0: manifestPath.parentDir
      else: projectRoot
    let targets = extractTargets(pkgNode, edition)
    var workspaceDeps: seq[string] = @[]
    if "dependencies" in pkgNode and pkgNode["dependencies"].kind == JArray:
      for dep in pkgNode["dependencies"]:
        if dep.kind != JObject:
          continue
        # Path deps have ``source == null`` AND a ``path`` field set to
        # the absolute directory of the dependency. crates.io deps have
        # ``source`` ≠ null. Git deps have ``source`` starting with
        # ``git+``. Only path deps that resolve to a sibling workspace
        # member contribute an ``--extern`` edge.
        let hasSource = "source" in dep and dep["source"].kind != JNull
        if hasSource:
          continue
        let depPath =
          if "path" in dep and dep["path"].kind == JString:
            dep["path"].getStr()
          else: ""
        if depPath.len == 0:
          continue
        let depKey = normalisedManifestDir(depPath / "Cargo.toml")
        if depKey in manifestDirToName:
          workspaceDeps.add(manifestDirToName[depKey])
    if targets.len == 0:
      # Library-only packages with no bin/lib targets shouldn't happen
      # in practice (cargo always synthesises a default target). Skip
      # silently rather than fail loud — a member with no compilable
      # target is fine; the convention just produces no actions for it.
      result.packages.add(RustPackage(
        packageName: name,
        manifestPath: manifestPath,
        manifestDir: manifestDir,
        targets: @[],
        workspaceDeps: workspaceDeps))
      continue
    result.packages.add(RustPackage(
      packageName: name,
      manifestPath: manifestPath,
      manifestDir: manifestDir,
      targets: targets,
      workspaceDeps: workspaceDeps))
  # Workspace detection: prefer ``workspace_members.len > 1`` (the
  # robust signal cargo metadata emits) but fall back to the textual
  # ``[workspace]`` scan when there's only one member but it's declared
  # as a workspace anyway (a virtual workspace with one member).
  result.isWorkspace = packages.len > 1
  if not result.isWorkspace:
    result.isWorkspace =
      cargoTomlHasWorkspace(projectRoot / "Cargo.toml") and
      not cargoTomlHasPackageTable(projectRoot / "Cargo.toml")

proc rustRecognize(projectRoot: string;
                   request: ProviderGraphRequest): bool {.gcsafe.} =
  ## Recognition contract (post-M13):
  ##   * ``reprobuild.nim`` mentions ``rust`` or ``cargo`` in ``uses:``
  ##   * ``<projectRoot>/Cargo.toml`` exists
  ##   * one of the following layouts holds:
  ##       - ``src/main.rs`` exists (single-crate binary), OR
  ##       - ``src/lib.rs`` exists (single-crate library), OR
  ##       - ``[workspace]`` table declared (workspace mode — members
  ##         resolved by ``cargo metadata`` at emit time), OR
  ##       - ``[[bin]]`` / ``[lib]`` declared with a non-default
  ##         ``path = ...`` (handled by ``cargo metadata`` at emit time).
  ##   * ``rustc`` and ``cargo`` are on PATH (so emit can run them).
  ##
  ## **M6 ``build.rs``**: still recognised, but routes to the Mode B
  ## crude fallback inside ``emitFragment``. We don't gate ``recognize``
  ## on ``build.rs`` absence — keeps dispatch order simple.
  let cargoTomlPath = projectRoot / "Cargo.toml"
  if not fileExists(extendedPath(cargoTomlPath)):
    return false
  let source = readReprobuildSource(projectRoot)
  if source.len == 0:
    return false
  if not usesIncludesRustOrCargo(source):
    return false
  if rustcExecutable().len == 0:
    return false
  if cargoExecutable().len == 0:
    return false
  # Accept any of: workspace, src/main.rs, src/lib.rs, OR explicit
  # ``[[bin]]``/``[lib]`` table (in which case ``cargo metadata`` at emit
  # time resolves the actual source paths from the manifest).
  if cargoTomlHasWorkspace(cargoTomlPath):
    return true
  if fileExists(extendedPath(projectRoot / "src" / "main.rs")):
    return true
  if fileExists(extendedPath(projectRoot / "src" / "lib.rs")):
    return true
  # Last resort: any explicit ``[[bin]]`` or ``[lib]`` table. Same shape
  # as the workspace detection but accepted for non-workspace manifests
  # with custom layouts.
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
                     kind: RustTargetKind): string =
  case kind
  of rtkBinary:
    binPathFor(projectRoot, crateName) / (crateName & ".d")
  of rtkLibrary:
    binPathFor(projectRoot, crateName) /
      (crateName & "-" & stableHash & ".d")

proc collectRustSourcesUnderManifest(manifestDir: string): seq[string] =
  ## Every ``.rs`` under ``<manifestDir>/src``. These become the declared
  ## inputs of both rustc passes so source-only edits invalidate the
  ## actions without needing the FS-snoop monitor. We walk *only* the
  ## crate's own ``src/`` — workspace siblings have their own action set
  ## with their own input list.
  let srcDir = manifestDir / "src"
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

proc crateTypeArg(kind: RustTargetKind): string =
  case kind
  of rtkBinary: "bin"
  of rtkLibrary: "lib"

proc rustcArgvCommon(rustcExe, crateName, edition, crateType, outDir,
                     stableHash, sourcePath, emit: string;
                     applyExtraFilename: bool;
                     externFlags: seq[string]): seq[string] =
  ## Build the rustc argv shared between Pass 1 and Pass 2 — they differ
  ## only in ``--emit``, ``--out-dir``, whether ``-C extra-filename`` is
  ## applied, and which ``--extern`` paths are visible. Output order is
  ## deterministic so the engine's fingerprint is stable.
  ##
  ## ``externFlags`` are the pre-built ``--extern name=path`` pairs from
  ## workspace deps — one ``--extern`` token plus one ``name=path`` token
  ## per dependency, already in alphabetic order. Empty for crates with
  ## no workspace deps.
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
  for flag in externFlags:
    result.add(flag)
  result.add(sourcePath)

type
  TargetActions = object
    metadataAction: BuildActionDef
    linkAction: BuildActionDef
    rmetaPath: string
    rlibPath: string
      ## Empty for binary targets.

proc emitForTarget(projectRoot, rustcExe: string;
                   target: RustTarget;
                   pkg: RustPackage;
                   metadataExterns: seq[string];
                   linkExterns: seq[string];
                   externDepIds: seq[string];
                   inputRmetas: seq[string];
                   inputRlibs: seq[string]): TargetActions =
  ## Materialise the two-action graph for a single bin/lib target.
  ##
  ## ``metadataExterns`` and ``linkExterns`` carry the pre-built
  ## ``--extern name=path`` pairs the metadata pass and the link pass
  ## see respectively. The metadata pass points at upstream ``.rmeta``
  ## files; the link pass points at upstream ``.rlib`` files (linkage
  ## requires the compiled artifact, not just the metadata).
  ## ``externDepIds`` is the action-id list those externs introduce as
  ## deps of both passes.
  let stableHash = stableHashHex(target.crateName & "@" & target.edition)
  let depsDir = depsPathFor(projectRoot, target.crateName)
  let binDir = binPathFor(projectRoot, target.crateName)
  createDir(extendedPath(depsDir))
  createDir(extendedPath(binDir))

  let crateType = crateTypeArg(target.kind)
  let metadataDepfile =
    metadataDepfilePath(projectRoot, target.crateName, stableHash)
  let rmetaOutput =
    rmetaOutputPath(projectRoot, target.crateName, stableHash)
  let metadataArgv = rustcArgvCommon(
    rustcExe = rustcExe,
    crateName = target.crateName,
    edition = target.edition,
    crateType = crateType,
    outDir = depsDir,
    stableHash = stableHash,
    sourcePath = target.sourcePath,
    emit = "metadata,dep-info",
    applyExtraFilename = true,
    externFlags = metadataExterns)
  let crateSources = collectRustSourcesUnderManifest(pkg.manifestDir)
  let metadataInputs = block:
    var inputs = crateSources
    inputs.add(pkg.manifestPath)
    for rmeta in inputRmetas:
      inputs.add(rmeta)
    inputs

  let metadataActionId =
    actionIdFor("rustc-metadata", target.crateName, "umbrella")
  let metadataAction = buildAction(
    id = metadataActionId,
    call = inlineExecCall(metadataArgv, projectRoot),
    deps = externDepIds,
    inputs = metadataInputs,
    outputs = @[rmetaOutput, metadataDepfile],
    pool = "compile",
    depfile = metadataDepfile,
    dependencyPolicy = makeDepfilePolicy(metadataDepfile),
    commandStatsId = "rust.rustc-metadata")

  let linkDepfile =
    linkDepfilePath(projectRoot, target.crateName, stableHash, target.kind)
  let linkOutput =
    case target.kind
    of rtkBinary: binaryOutputPath(projectRoot, target.crateName)
    of rtkLibrary: rlibOutputPath(projectRoot, target.crateName, stableHash)
  let linkArgv = rustcArgvCommon(
    rustcExe = rustcExe,
    crateName = target.crateName,
    edition = target.edition,
    crateType = crateType,
    outDir = binDir,
    stableHash = stableHash,
    sourcePath = target.sourcePath,
    emit = "link,dep-info",
    applyExtraFilename = target.kind == rtkLibrary,
    externFlags = linkExterns)
  let linkInputs = block:
    var inputs = crateSources
    inputs.add(pkg.manifestPath)
    # Declare the rmeta from this crate's metadata pass as an input —
    # captures the pipelined edge in the action cache fingerprint.
    inputs.add(rmetaOutput)
    for rlib in inputRlibs:
      inputs.add(rlib)
    inputs

  var linkDeps: seq[string] = @[metadataActionId]
  for depId in externDepIds:
    if depId notin linkDeps:
      linkDeps.add(depId)

  let linkAction = buildAction(
    id = actionIdFor("rustc-link", target.crateName, "umbrella"),
    call = inlineExecCall(linkArgv, projectRoot),
    deps = linkDeps,
    inputs = linkInputs,
    outputs = @[linkOutput, linkDepfile],
    pool = "compile",
    depfile = linkDepfile,
    dependencyPolicy = makeDepfilePolicy(linkDepfile),
    commandStatsId = "rust.rustc-link")

  TargetActions(
    metadataAction: metadataAction,
    linkAction: linkAction,
    rmetaPath: rmetaOutput,
    rlibPath:
      case target.kind
      of rtkBinary: ""
      of rtkLibrary:
        rlibOutputPath(projectRoot, target.crateName, stableHash))

proc syntheticPackage(projectRoot: string;
                      project: RustProject): PackageDef =
  ## Build a minimal ``PackageDef`` for the runtime helper. The Rust
  ## convention doesn't go through DSL evaluation — see the M3 Nim
  ## convention's same proc.
  var name = "rust_convention"
  if project.packages.len > 0:
    name = normaliseCrateName(project.packages[0].packageName)
  PackageDef(
    packageName: name,
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
  ## per-package + per-target info, register every (metadata, link) pair
  ## via the DSL, and hand the whole thing to ``buildPackageFragment``.
  ##
  ## **M6 routing**: when the project carries a ``build.rs``, the Mode A
  ## graph would be wrong (rustc alone can't honour build-script env
  ## vars / linker hints) so we delegate to ``rustCrudeFallback``.
  ##
  ## **M13 workspace shape**:
  ##   1. ``cargo metadata`` lists every workspace member's package node.
  ##   2. For each package, ``extractTargets`` keeps just the bin/lib
  ##      targets.
  ##   3. Each package's ``workspaceDeps`` is the set of OTHER workspace
  ##      members it depends on by path. We use the first lib target of
  ##      each producer as the source for ``--extern <lib-name>=<rmeta>``
  ##      (metadata pass) and ``--extern <lib-name>=<rlib>`` (link pass).
  ##   4. Action deps mirror the data: a consumer's link action lists
  ##      the producer's link action id in ``deps``; its metadata action
  ##      lists the producer's metadata action id.
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
    let project = loadProject(projectRoot, metadata)
    if project.packages.len == 0:
      raise newException(ValueError,
        "rust convention: no compilable packages found in " & projectRoot)
    # Verify every declared source path actually exists; cargo metadata
    # can sometimes report stale entries if the user edits Cargo.toml
    # without saving the source file.
    for pkg in project.packages:
      for t in pkg.targets:
        if not fileExists(extendedPath(t.sourcePath)):
          raise newException(ValueError,
            "rust convention: declared crate source missing for '" &
              t.crateName & "': " & t.sourcePath)
    let pkgDef = syntheticPackage(projectRoot, project)
    let registerAll = proc() =
      discard buildPool("compile", 8'u32)
      # Two-pass walk:
      #   Pass A: emit per-package per-lib-target actions first so the
      #     resulting ``TargetActions`` (esp. ``rmetaPath`` / ``rlibPath``)
      #     are available when we emit consumers in Pass B.
      #   Pass B: emit per-package per-bin-target actions, threading the
      #     workspace-dep externs from Pass A.
      #
      # Within each package, lib targets are emitted before bin targets
      # so a same-package bin can pick up its own ``[lib]`` (the
      # ``[lib]+[[bin]]`` mixed case — rare in the M13 fixtures but the
      # mechanism is the same as a workspace dep).
      var libActionsByPackage = initTable[string, TargetActions]()
        ## package name → its first lib target's actions (the only one
        ## a same-package bin or a workspace consumer can reference by
        ## the ``crate-name`` convention).
      var allActions: seq[BuildActionDef] = @[]

      # Pass A: libraries.
      for pkg in project.packages:
        for t in pkg.targets:
          if t.kind != rtkLibrary:
            continue
          # Library targets get no externs from us in M13 — workspace
          # deps that themselves depend on other libs would need a
          # topological-sort emit; the M13 fixture is shallow (one lib,
          # one bin, one edge) so we leave the more general case to
          # M13+1.
          let actions = emitForTarget(
            projectRoot = projectRoot,
            rustcExe = rustcExe,
            target = t,
            pkg = pkg,
            metadataExterns = @[],
            linkExterns = @[],
            externDepIds = @[],
            inputRmetas = @[],
            inputRlibs = @[])
          allActions.add(actions.metadataAction)
          allActions.add(actions.linkAction)
          discard target(t.crateName, @[actions.metadataAction, actions.linkAction])
          # Record only the FIRST lib target of each package — that's the
          # one a workspace consumer's ``--extern <crateName>=<path>`` flag
          # will point at when it depends on the package by name.
          if pkg.packageName notin libActionsByPackage:
            libActionsByPackage[pkg.packageName] = actions

      # Pass B: binaries.
      for pkg in project.packages:
        var metadataExterns: seq[string] = @[]
        var linkExterns: seq[string] = @[]
        var externDepIds: seq[string] = @[]
        var inputRmetas: seq[string] = @[]
        var inputRlibs: seq[string] = @[]
        for depName in pkg.workspaceDeps:
          if depName notin libActionsByPackage:
            continue
          let depActions = libActionsByPackage[depName]
          # Cargo's extern name = the lib target's crate name. We
          # retrieve it by stripping the ``-<hash>.rmeta`` suffix off
          # the rmeta path's basename → ``lib<crateName>``.
          let baseName = depActions.rmetaPath.extractFilename
          # ``lib<crate>-<hash>.rmeta`` → strip ``lib`` prefix +
          # ``-<hash>.rmeta`` suffix.
          var crateName = baseName
          if crateName.startsWith("lib"):
            crateName = crateName[3 .. ^1]
          let dashIdx = crateName.rfind('-')
          if dashIdx > 0:
            crateName = crateName[0 ..< dashIdx]
          if crateName.endsWith(".rmeta"):
            crateName = crateName[0 ..< crateName.len - len(".rmeta")]
          metadataExterns.add("--extern")
          metadataExterns.add(crateName & "=" & depActions.rmetaPath)
          linkExterns.add("--extern")
          linkExterns.add(crateName & "=" & depActions.rlibPath)
          if depActions.metadataAction.id notin externDepIds:
            externDepIds.add(depActions.metadataAction.id)
          if depActions.linkAction.id notin externDepIds:
            externDepIds.add(depActions.linkAction.id)
          inputRmetas.add(depActions.rmetaPath)
          inputRlibs.add(depActions.rlibPath)
        for t in pkg.targets:
          if t.kind != rtkBinary:
            continue
          let actions = emitForTarget(
            projectRoot = projectRoot,
            rustcExe = rustcExe,
            target = t,
            pkg = pkg,
            metadataExterns = metadataExterns,
            linkExterns = linkExterns,
            externDepIds = externDepIds,
            inputRmetas = inputRmetas,
            inputRlibs = inputRlibs)
          allActions.add(actions.metadataAction)
          allActions.add(actions.linkAction)
          discard target(t.crateName, @[actions.metadataAction, actions.linkAction])
      if allActions.len == 0:
        raise newException(ValueError,
          "rust convention: no bin or lib targets found across " &
            $project.packages.len & " package(s) under " & projectRoot)
      defaultTarget(target("default", allActions))
    result = buildPackageFragment(pkgDef, request, registerAll,
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
