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
## **Design decision (M4 Option 1 — eager metadata extraction + M18
## fingerprint cache).** Like the M3 Nim convention's Option 1, we
## invoke ``cargo metadata --format-version=1 --no-deps --offline`` at
## emit time to extract each crate's manifest info (package name,
## edition, target list, dependencies). The alternative — driving the
## manifest read entirely from a hand-rolled TOML parser — would let us
## recognise without a working ``cargo`` on PATH, but the convention
## spec already requires ``cargo`` for workspace resolution anyway and
## Cargo.toml syntax is rich enough that re-implementing the TOML
## edge-cases buys nothing here.
##
## M18 lands a fingerprint sidecar (see
## ``conventions/emit_cache.nim``): the convention hashes every
## ``Cargo.toml``/``Cargo.lock``/``.rs`` file in the project tree plus
## the cargo driver path, compares against
## ``<projectRoot>/.repro/build/.emit-cache/cargo-metadata.repro-emit-fingerprint``,
## and on a hit reads the cached JSON output (``cargo-metadata.cached.json``
## next to the sidecar) instead of re-spawning cargo. Cold-snapshot
## re-emits become pure on-disk I/O when nothing has changed.
##
## **M23 extensions** over M13's outstanding tasks:
##
##   * **Workspace lib→lib edges**: Pass A now topologically sorts
##     library packages by their workspace deps before emitting, so a
##     lib's metadata/link passes pick up its upstream lib rmeta/rlib
##     via ``--extern <name>=<path>``. The
##     ``rust/workspace-lib-chain`` fixture exercises a three-crate
##     ``crate_a → crate_b → crate_c`` chain.
##   * **cdylib / staticlib / dylib variants**: ``extractTargets`` now
##     distinguishes per-target ``crate-type``. ``emitForTarget`` picks
##     the matching ``--crate-type`` flag (``cdylib`` / ``staticlib``
##     / ``dylib``) and the platform-specific output name (``<n>.dll``
##     on Windows, ``lib<n>.so/dylib`` on POSIX for cdylib/dylib;
##     ``<n>.lib`` on MSVC / ``lib<n>.a`` elsewhere for staticlib). The
##     ``rust/cdylib`` fixture exercises this on a minimal C-ABI lib.
##   * **crates.io / git deps (partial)**: detect dependencies with
##     ``source != null`` at ``loadProject`` time and, when present,
##     fall through to the Mode B crude fallback (``cargo build
##     --release --offline``). The full Mode A path (per-dep
##     ``--extern`` threading from ``CARGO_HOME`` + ``cargo fetch``)
##     remains an outstanding follow-up; see the M23 section in
##     ``Standard-Provider-Implementation.milestones.org`` for the
##     trade-off.
##
## **Still deferred** (post-M23):
##   * ``build.rs`` crates — they keep routing through the Mode B crude
##     fallback inside ``emitFragment``.
##   * Full Mode A for crates.io / git deps — the convention currently
##     drops to the crude fallback when an external dep is detected.
##     A future milestone can graduate this to per-dep ``--extern``
##     threading.
##   * cdylib / dylib as a ``--extern`` source for downstream Rust
##     crates. The M23 surface treats them like the C ABI export they
##     are; an additional convention extension would have to thread the
##     dylib path into a downstream Rust crate's link action.
##   * Examples / benches — these need a per-example runner that the
##     M23 surface doesn't yet cover.
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

import std/[algorithm, json, os, osproc, sets, strutils, tables]

import repro_core
import repro_provider_runtime
import repro_project_dsl
import repro_standard_provider/convention
import repro_standard_provider/conventions/emit_cache
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
      ## Default ``[lib]`` target (rlib). Linkable as a Rust dependency
      ## via ``--extern <name>=<rlib>``.
    rtkCdylib
      ## M23: ``crate-type = ["cdylib"]`` — dynamic library with a C
      ## ABI. Emits ``<name>.dll`` on Windows and ``lib<name>.so`` /
      ## ``lib<name>.dylib`` on POSIX. Not linkable as a Rust dep (no
      ## rmeta), so we don't thread it through ``--extern`` edges to
      ## downstream lib targets.
    rtkStaticlib
      ## M23: ``crate-type = ["staticlib"]`` — static library with a C
      ## ABI. Emits ``lib<name>.a`` (POSIX) or ``<name>.lib`` (MSVC).
      ## Same non-linkable-as-rust-dep caveat as ``rtkCdylib``.
    rtkDylib
      ## M23: ``crate-type = ["dylib"]`` — dynamic library with the
      ## Rust ABI. Same output naming as cdylib but reachable via
      ## ``--extern <name>=<dylib>`` from another Rust crate (Rust ABI
      ## means the rmeta is meaningful). M23 surface treats it like
      ## cdylib for emit purposes; cross-crate consumption via dylib is
      ## an outstanding follow-up.
    rtkIntegrationTest
      ## M22: an integration test under ``tests/<name>.rs``. Cargo
      ## metadata reports these as ``kind=["test"]``; the convention
      ## emits a (compile, run) action pair per test target under a
      ## non-default ``test`` target.

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
    hasExternalDeps: bool
      ## M23: true when this package's ``dependencies`` array includes
      ## at least one entry with ``source != null`` (i.e. a crates.io
      ## registry or git dep, as opposed to a path dep to a sibling
      ## workspace member). Used by the M23 routing in ``rustEmitFragment``
      ## to fall through to the Mode B crude fallback rather than
      ## emitting an incomplete Mode A graph that would fail to resolve
      ## the external rlibs.

  RustProject = object
    ## The full project view the emitter walks. ``packages`` always
    ## contains at least one entry; for workspaces it contains every
    ## member.
    packages: seq[RustPackage]
    isWorkspace: bool
    hasExternalDeps: bool
      ## M23: true when any package in the project depends on a
      ## crates.io / git source. Routes the entire project through the
      ## Mode B crude fallback. See the M23 "Crates.io / git deps"
      ## section in ``Standard-Provider-Implementation.milestones.org``
      ## for the trade-off (we could ALSO try to harvest rlib paths from
      ## a separate ``cargo build --release --offline
      ## --message-format=json`` run, but the simpler "delegate to
      ## cargo" route lands in M23 and a full ``--extern``-threading
      ## implementation is deferred).

proc readReprobuildSource(projectRoot: string): string =
  ## Read the project file (``repro.nim`` or legacy ``reprobuild.nim``)
  ## under ``projectRoot``; return the empty string when neither is
  ## present. Used by ``recognize``; never raises. See
  ## ``repro_core/project_file`` for the alias contract.
  let match = resolveProjectFile(projectRoot)
  if match.path.len == 0:
    return ""
  try:
    readFile(extendedPath(match.path))
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

const
  RustEmitCacheBaseName = "cargo-metadata"
    ## Sidecar file basename for the M18 emit-time fingerprint cache.
    ## See ``emit_cache.nim`` for the contract.
  RustEmitCacheJsonName = "cargo-metadata.cached.json"
    ## Cached ``cargo metadata`` JSON output. Lives next to the
    ## fingerprint sidecar so the convention can rehydrate the same
    ## ``JsonNode`` without re-running the subprocess.

proc rustEmitCacheScratchDir(projectRoot: string): string =
  ## The convention's M18 emit-cache scratch lives under
  ## ``<projectRoot>/.repro/build/.emit-cache`` — out of the way of the
  ## per-target scratch subdirs the build engine writes into. Created
  ## on demand by ``writeEmitCacheFingerprint``.
  projectRoot / ScratchDirName / ".emit-cache"

proc collectRustSources(projectRoot: string): seq[string] =
  ## Every input file ``cargo metadata`` could possibly inspect on a
  ## ``--no-deps --offline`` run:
  ##
  ##   * the workspace ``Cargo.toml`` and (optionally) ``Cargo.lock``
  ##   * every member's ``Cargo.toml``
  ##   * every ``.rs`` source under ``src/``, ``examples/``, ``tests/``,
  ##     ``benches/``, ``build.rs``, ``bin/`` (these are NOT
  ##     interpreted by cargo metadata, but they DO determine the set
  ##     of bin/lib targets when ``[[bin]]`` entries auto-discover from
  ##     the filesystem — auto-discovery is on by default).
  ##
  ## We walk recursively but skip ``target/`` and ``.repro/`` so build
  ## scratch doesn't pollute the fingerprint.
  if not dirExists(extendedPath(projectRoot)):
    return @[]
  for entry in walkDirRec(projectRoot, yieldFilter = {pcFile}):
    let rel = entry.relativePath(projectRoot)
    let lowered = rel.replace('\\', '/').toLowerAscii
    if lowered.startsWith("target/") or lowered.startsWith(".repro/"):
      continue
    let basename = extractFilename(entry).toLowerAscii
    let ext = splitFile(entry).ext.toLowerAscii
    if basename == "cargo.toml" or basename == "cargo.lock" or ext == ".rs":
      result.add(entry)
  result.sort(system.cmp[string])

proc rustEmitCacheFingerprint(projectRoot, cargoExe: string;
                              sources: openArray[string]): string =
  ## Fingerprint key for the cargo-metadata cache. See the analogous
  ## comment in ``nim.nim`` for the rationale around what is and isn't
  ## folded in.
  ##
  ## **M29 Part A**: ``cargo --version`` output is folded in via
  ## ``toolVersionInput``. An in-place ``cargo`` upgrade (or a host
  ## ``rustup`` toolchain switch keeping the same shim path) flips the
  ## reported version and naturally misses the cache.
  var inputs: seq[EmitCacheInput] = @[
    textInput("cargo-exe:" & cargoExe),
    toolVersionInput(cargoExe),
    textInput("project-root:" & projectRoot),
    textInput("cmd:cargo metadata --format-version=1 --no-deps --offline"),
  ]
  for source in sources:
    inputs.add(fileInput(source))
  computeEmitCacheFingerprint(inputs)

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
  ##
  ## **M18 emit-cache fast path**: hash the project's Cargo manifests +
  ## ``.rs`` sources and, when the fingerprint matches a sidecar in the
  ## convention's emit-cache scratch dir AND a cached JSON output is on
  ## disk, return the cached parse directly without re-running cargo.
  ## ``cargo metadata`` is fast (~200 ms locally) but the bigger win is
  ## that the convention's emit becomes purely-on-disk-I/O when nothing
  ## has changed — important when the provider snapshot is wiped (e.g.,
  ## the build engine cache is cleared but the convention's manifests
  ## are still on disk).
  let scratchDir = rustEmitCacheScratchDir(projectRoot)
  let sources = collectRustSources(projectRoot)
  let fingerprint = rustEmitCacheFingerprint(projectRoot, cargoExe, sources)
  let cachedJsonPath = scratchDir / RustEmitCacheJsonName
  if emitCacheIsUsable(scratchDir, RustEmitCacheBaseName, fingerprint,
      [cachedJsonPath]):
    try:
      return parseFile(extendedPath(cachedJsonPath))
    except CatchableError:
      # Stale cache (corrupted JSON, partial write). Fall through to the
      # subprocess; the writeFile at the bottom of this proc rewrites
      # both sidecar + JSON together.
      discard
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
  # Persist the cached output BEFORE the fingerprint sidecar so a crash
  # between the two writes leaves the cache miss-but-correct, not
  # hit-but-stale.
  try:
    createDir(extendedPath(scratchDir))
    writeFile(extendedPath(cachedJsonPath), jsonText)
    writeEmitCacheFingerprint(scratchDir, RustEmitCacheBaseName, fingerprint)
  except CatchableError:
    discard

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
  ## Walk a package's ``targets`` array and keep ``bin`` / ``lib`` targets
  ## plus (M22) ``test`` integration-test targets. Examples, benches, and
  ## custom-build targets are still skipped — those need additional
  ## tooling (per-example runners, criterion harness) that's outside the
  ## M22 surface.
  ##
  ## **M23**: lib-flavoured targets (``lib`` / ``rlib`` / ``cdylib`` /
  ## ``staticlib`` / ``dylib``) are now distinguished per-target so the
  ## emitter can pick the appropriate ``--crate-type`` flag + output
  ## naming. A single ``[lib]`` target whose ``crate-type`` array carries
  ## multiple kinds reports back as a single ``targets[]`` entry whose
  ## ``kind`` array lists every requested crate type — we pick the first
  ## kind whose output we know how to emit (rlib > cdylib > staticlib >
  ## dylib) so the most useful artefact wins.
  if "targets" notin pkgNode or pkgNode["targets"].kind != JArray:
    return @[]
  for target in pkgNode["targets"]:
    if target.kind != JObject or "kind" notin target or
       target["kind"].kind != JArray:
      continue
    var isBin = false
    var hasRlib = false
    var hasCdylib = false
    var hasStaticlib = false
    var hasDylib = false
    var isTest = false
    var isOther = false
    for k in target["kind"]:
      case k.getStr()
      of "bin":
        isBin = true
      of "lib", "rlib":
        hasRlib = true
      of "cdylib":
        hasCdylib = true
      of "staticlib":
        hasStaticlib = true
      of "dylib":
        hasDylib = true
      of "test":
        # M22: integration tests under ``tests/<name>.rs``. Cargo emits
        # one ``targets[]`` entry per file. We DO NOT pick up ``--test``
        # built unit-tests inside ``src/lib.rs`` (those still need
        # ``cargo test`` proper) — only the ``tests/`` directory's
        # standalone integration-test crates.
        isTest = true
      else:
        isOther = true
    let isLibFlavoured = hasRlib or hasCdylib or hasStaticlib or hasDylib
    # Examples / benches: skip silently. Tests: keep for the M22 test
    # target. Bin/lib-flavoured: keep for the default build target.
    if (not isBin) and (not isLibFlavoured) and (not isTest):
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
    let kind =
      if isBin: rtkBinary
      elif hasRlib: rtkLibrary
      elif hasCdylib: rtkCdylib
      elif hasStaticlib: rtkStaticlib
      elif hasDylib: rtkDylib
      else: rtkIntegrationTest
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
    var hasExternalDeps = false
    if "dependencies" in pkgNode and pkgNode["dependencies"].kind == JArray:
      for dep in pkgNode["dependencies"]:
        if dep.kind != JObject:
          continue
        # Path deps have ``source == null`` AND a ``path`` field set to
        # the absolute directory of the dependency. crates.io deps have
        # ``source`` ≠ null. Git deps have ``source`` starting with
        # ``git+``. Only path deps that resolve to a sibling workspace
        # member contribute an ``--extern`` edge.
        #
        # M23: Also note "build" and "dev" kinds. Build-script
        # dependencies (``kind == "build"``) wire into build.rs which
        # already routes through the Mode B crude fallback (see
        # ``hasBuildRs``). Dev dependencies (``kind == "dev"``) are
        # only consumed by tests — the M22 test target compile would
        # need to thread them, but for now dev-deps are ignored at the
        # default-build surface and tests fall back to crude when they
        # need external dev deps.
        let depKindStr =
          if "kind" in dep and dep["kind"].kind == JString:
            dep["kind"].getStr()
          else: ""
        let hasSource = "source" in dep and dep["source"].kind != JNull
        if hasSource:
          # Treat normal+build deps with external sources as triggering
          # the Mode B fallback. Dev deps are tolerated at default-build
          # time (they only matter for tests).
          if depKindStr != "dev":
            hasExternalDeps = true
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
    if hasExternalDeps:
      result.hasExternalDeps = true
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
        workspaceDeps: workspaceDeps,
        hasExternalDeps: hasExternalDeps))
      continue
    result.packages.add(RustPackage(
      packageName: name,
      manifestPath: manifestPath,
      manifestDir: manifestDir,
      targets: targets,
      workspaceDeps: workspaceDeps,
      hasExternalDeps: hasExternalDeps))
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

proc cdylibOutputPath(projectRoot, crateName: string): string =
  ## M23: ``cdylib`` / ``dylib`` produce a platform-naming dynamic
  ## library. Windows: ``<name>.dll`` (no ``lib`` prefix — Rust matches
  ## MSVC's convention here). macOS: ``lib<name>.dylib``. Linux/others:
  ## ``lib<name>.so``. We DO NOT thread the stable-hash suffix in here
  ## because dynamic libraries are typically consumed by external (C/C++)
  ## callers that hard-code the filename; cargo itself drops the hash for
  ## cdylib by default.
  when defined(windows):
    binPathFor(projectRoot, crateName) / (crateName & ".dll")
  elif defined(macosx):
    binPathFor(projectRoot, crateName) / ("lib" & crateName & ".dylib")
  else:
    binPathFor(projectRoot, crateName) / ("lib" & crateName & ".so")

proc staticlibOutputPath(projectRoot, crateName: string): string =
  ## M23: ``staticlib`` produces ``<name>.lib`` on MSVC + ``lib<name>.a``
  ## elsewhere. rustc 1.75+ on the ``*-pc-windows-msvc`` triple defaults
  ## the staticlib output to ``<name>.lib``; the ``*-pc-windows-gnu``
  ## triple keeps the ``lib<name>.a`` form. We pick the MSVC form on
  ## Windows for consistency with what cargo produces on this host.
  when defined(windows):
    binPathFor(projectRoot, crateName) / (crateName & ".lib")
  else:
    binPathFor(projectRoot, crateName) / ("lib" & crateName & ".a")

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
  of rtkCdylib, rtkDylib, rtkStaticlib:
    binPathFor(projectRoot, crateName) / (crateName & ".d")
  of rtkIntegrationTest:
    binPathFor(projectRoot, crateName) / (crateName & ".d")

proc testsScratchDir(projectRoot, packageCrateName: string): string =
  ## M22: ``<projectRoot>/.repro/build/<packageCrateName>/tests`` — where
  ## per-test compile actions drop their binaries. Each package owns its
  ## own ``tests/`` subtree under its scratch root so workspace members
  ## don't clobber each other.
  scratchPathFor(projectRoot, packageCrateName) / "tests"

proc testBinaryPath(projectRoot, packageCrateName, testName: string): string =
  when defined(windows):
    testsScratchDir(projectRoot, packageCrateName) / (testName & ".exe")
  else:
    testsScratchDir(projectRoot, packageCrateName) / testName

proc testRunStampPath(projectRoot, packageCrateName, testName: string):
    string =
  testsScratchDir(projectRoot, packageCrateName) /
    (testName & ".stamp")

proc collectRustSourcesUnderManifest(manifestDir: string): seq[string] =
  ## Every ``.rs`` under ``<manifestDir>/src``. These become the declared
  ## inputs of both rustc passes so source-only edits invalidate the
  ## actions without needing the io-monitor monitor. We walk *only* the
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
  ## Map a target kind to rustc's ``--crate-type`` token. M22:
  ## ``rtkIntegrationTest`` collapses to ``bin`` because ``rustc --test``
  ## always emits a bin-shaped test harness (the harness's ``fn main``
  ## is generated by rustc itself). We pass ``--crate-type bin``
  ## defensively even though ``--test`` implies it — matches the shape
  ## ``cargo test`` itself emits.
  ## M23: ``rtkCdylib`` / ``rtkStaticlib`` / ``rtkDylib`` map to their
  ## respective rustc tokens — one per supported dynamic/static library
  ## variant.
  case kind
  of rtkBinary: "bin"
  of rtkLibrary: "lib"
  of rtkCdylib: "cdylib"
  of rtkStaticlib: "staticlib"
  of rtkDylib: "dylib"
  of rtkIntegrationTest: "bin"

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

  TestTargetActions = object
    ## M22: per integration-test (compile, run, stamp) triple. The
    ## compile produces the test harness binary; the run executes it;
    ## the stamp writes a marker file after the run succeeds so the
    ## engine has a declared output to track for cache invalidation.
    compileAction: BuildActionDef
    runAction: BuildActionDef
    stampAction: BuildActionDef

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
    of rtkCdylib, rtkDylib:
      # M23: ``--crate-type cdylib`` / ``dylib`` produce a platform-named
      # dynamic library. ``rtkDylib`` reuses the cdylib output naming
      # because rustc + cargo use the same filename pattern; only the
      # ABI differs.
      cdylibOutputPath(projectRoot, target.crateName)
    of rtkStaticlib:
      # M23: ``--crate-type staticlib`` produces ``<name>.lib`` on MSVC
      # and ``lib<name>.a`` elsewhere.
      staticlibOutputPath(projectRoot, target.crateName)
    of rtkIntegrationTest:
      # ``emitForTarget`` is the bin/lib emitter — integration tests
      # route through ``emitForTestTarget`` instead. Hit this branch
      # only on a programmer error (caller passed a test target into
      # the bin/lib emitter).
      raise newException(ValueError,
        "rust convention: integration-test target '" & target.crateName &
          "' passed to emitForTarget; use emitForTestTarget")
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
        rlibOutputPath(projectRoot, target.crateName, stableHash)
      of rtkCdylib, rtkDylib, rtkStaticlib:
        # M23: cdylib/staticlib/dylib aren't consumable as Rust deps via
        # ``--extern`` in the M23 surface, so leave ``rlibPath`` empty.
        # A downstream Rust crate that needs to link against a dylib
        # would need a separate convention extension that threads the
        # dylib path into the link action — outstanding follow-up.
        ""
      of rtkIntegrationTest: "")

proc emitForTestTarget(projectRoot, rustcExe: string;
                       test: RustTarget;
                       pkg: RustPackage;
                       packageCrateName: string;
                       libActions: TargetActions): TestTargetActions =
  ## M22: emit the compile + run action pair for a single integration
  ## test (``tests/<name>.rs``).
  ##
  ##   Compile action:
  ##     ``rustc --test --crate-name <name> --edition <e>
  ##       --crate-type bin --emit=link --out-dir <scratch>/tests
  ##       -L dependency=<scratch>/<crate>/deps
  ##       --extern <libCrate>=<rlib>
  ##       <test.rs>``
  ##
  ##     produces ``<scratch>/tests/<name>[.exe]``. The ``-L
  ##     dependency=`` path is the library's metadata dir so any
  ##     ``rmeta`` neighbouring the rlib also resolves (rustc's resolver
  ##     consults both rlib and rmeta when ``--extern`` is set).
  ##
  ##   Run action:
  ##     ``<scratch>/tests/<name>[.exe]``
  ##
  ##     no argv flags — the harness defaults to running every
  ##     ``#[test]`` discovered at compile time. Stamp file is the run
  ##     action's declared output so a re-run is a no-op when the test
  ##     binary's inputs are unchanged.
  ##
  ## ``libActions`` is the package's primary lib target's actions —
  ## ``rmetaPath`` / ``rlibPath`` feed the ``--extern`` flag. Without a
  ## sibling lib target the test wouldn't be able to ``use
  ## <crate>::...``; the caller short-circuits before reaching this proc
  ## when no lib is present.
  let testsDir = testsScratchDir(projectRoot, packageCrateName)
  let depsDir = depsPathFor(projectRoot, packageCrateName)
  createDir(extendedPath(testsDir))
  let binaryOutput =
    testBinaryPath(projectRoot, packageCrateName, test.crateName)

  var argv = @[
    rustcExe,
    "--test",
    "--crate-name", test.crateName,
    "--edition", test.edition,
    "--crate-type", crateTypeArg(test.kind),
    "--emit=link",
    "--out-dir", testsDir,
    "-L", "dependency=" & depsDir,
  ]
  # Derive the lib's extern name from its rmeta path: ``lib<n>-<hash>.rmeta``
  # → strip ``lib`` prefix + ``-<hash>.rmeta`` suffix.
  var libCrateName = ""
  if libActions.rmetaPath.len > 0:
    var baseName = libActions.rmetaPath.extractFilename
    if baseName.startsWith("lib"):
      baseName = baseName[3 .. ^1]
    let dashIdx = baseName.rfind('-')
    if dashIdx > 0:
      baseName = baseName[0 ..< dashIdx]
    if baseName.endsWith(".rmeta"):
      baseName = baseName[0 ..< baseName.len - len(".rmeta")]
    libCrateName = baseName
  if libCrateName.len > 0 and libActions.rlibPath.len > 0:
    argv.add("--extern")
    argv.add(libCrateName & "=" & libActions.rlibPath)
  argv.add(test.sourcePath)

  let compileInputs = block:
    var inputs: seq[string] = @[test.sourcePath, pkg.manifestPath]
    if libActions.rlibPath.len > 0:
      inputs.add(libActions.rlibPath)
    if libActions.rmetaPath.len > 0:
      inputs.add(libActions.rmetaPath)
    inputs
  let compileDeps = block:
    var deps: seq[string] = @[]
    if libActions.linkAction.id.len > 0:
      deps.add(libActions.linkAction.id)
    if libActions.metadataAction.id.len > 0 and
        libActions.metadataAction.id notin deps:
      deps.add(libActions.metadataAction.id)
    deps

  let compileAction = buildAction(
    id = actionIdFor("rustc-test-compile", test.crateName, "compile"),
    call = inlineExecCall(argv, projectRoot),
    deps = compileDeps,
    inputs = compileInputs,
    outputs = @[binaryOutput],
    pool = "compile",
    dependencyPolicy = automaticMonitorPolicy(),
    commandStatsId = "rust.rustc-test-compile")

  let stampPath =
    testRunStampPath(projectRoot, packageCrateName, test.crateName)
  let runArgv = @[binaryOutput]
  let runAction = buildAction(
    id = actionIdFor("rustc-test-run", test.crateName, "run"),
    call = inlineExecCall(runArgv, projectRoot),
    deps = @[compileAction.id],
    inputs = @[binaryOutput],
    outputs = @[],
    pool = "compile",
    dependencyPolicy = automaticMonitorPolicy(),
    commandStatsId = "rust.rustc-test-run")

  # Stamp the run so the engine has a declared output to track. The
  # stamp's text is the test's crate name — purely diagnostic.
  createDir(extendedPath(parentDir(stampPath)))
  let stampAction = fs.stamp(
    output = stampPath,
    title = "rust-test:" & test.crateName,
    entries = @[test.crateName],
    actionId = actionIdFor("rustc-test-stamp", test.crateName, "stamp"),
    deps = @[runAction.id],
    commandStatsId = "rust.rustc-test-stamp")

  TestTargetActions(
    compileAction: compileAction,
    runAction: runAction,
    stampAction: stampAction)

proc syntheticPackage(projectRoot: string;
                      project: RustProject): PackageDef =
  ## Build a minimal ``PackageDef`` for the runtime helper. The Rust
  ## convention doesn't go through DSL evaluation — see the M3 Nim
  ## convention's same proc.
  var name = "rust_convention"
  if project.packages.len > 0:
    name = normaliseCrateName(project.packages[0].packageName)
  let projectMatch = resolveProjectFile(projectRoot)
  let sourceFile =
    if projectMatch.path.len > 0: projectMatch.path
    else: projectRoot / LegacyProjectFileName
  PackageDef(
    packageName: name,
    sourceFile: sourceFile,
    hasDevEnv: false,
    devEnvBodyHash: "",
    toolUses: @[])

proc hasBuildRs(projectRoot: string): bool =
  fileExists(extendedPath(projectRoot / "build.rs"))

proc topologicalSortLibPackages(project: RustProject): seq[int] =
  ## M23: produce package indices in topological order such that, if
  ## package B depends on package A (path-dep, in the workspace), then
  ## A appears before B in the result. This lets Pass A emit each lib
  ## with the rmeta/rlib paths of its upstream lib deps already known.
  ##
  ## Algorithm: Kahn's algorithm against the package-name graph. We only
  ## consider packages whose ``workspaceDeps`` are also in the project
  ## (non-workspace deps were already filtered out at ``loadProject``
  ## time). The result preserves cargo's package order as a stable
  ## tie-breaker (matches the order ``cargo metadata`` reports members,
  ## which is the manifest-declaration order).
  ##
  ## On cycle detection (which Cargo itself forbids — a workspace with a
  ## cycle won't pass ``cargo check``) we fall back to the original order
  ## and emit a deterministic-but-suboptimal graph; the convention's
  ## subsequent rustc invocation will surface cargo's cycle diagnostic.
  let n = project.packages.len
  if n <= 1:
    result = @[]
    for i in 0 ..< n:
      result.add(i)
    return result
  # name → index map for the consumer-side lookup.
  var nameToIdx = initTable[string, int]()
  for i in 0 ..< n:
    nameToIdx[project.packages[i].packageName] = i
  # In-degree per package: number of workspace deps it imports.
  var inDeg = newSeq[int](n)
  # adjacency: producer index → seq of consumer indices.
  var adj = newSeq[seq[int]](n)
  for i in 0 ..< n:
    for depName in project.packages[i].workspaceDeps:
      if depName notin nameToIdx:
        continue
      let producerIdx = nameToIdx[depName]
      if producerIdx == i:
        # Self-dep would be a degenerate cycle; ignore.
        continue
      adj[producerIdx].add(i)
      inc inDeg[i]
  var queue: seq[int] = @[]
  for i in 0 ..< n:
    if inDeg[i] == 0:
      queue.add(i)
  var visited = 0
  while queue.len > 0:
    let head = queue[0]
    queue.delete(0)
    result.add(head)
    inc visited
    for c in adj[head]:
      dec inDeg[c]
      if inDeg[c] == 0:
        queue.add(c)
  if visited != n:
    # Cycle detected; fall back to original order. Cargo would have
    # already rejected this at metadata time, but be defensive.
    result = @[]
    for i in 0 ..< n:
      result.add(i)

proc isLibFlavoured(kind: RustTargetKind): bool =
  ## M23: classify whether a target compiles into a "library-flavoured"
  ## artefact (rlib / cdylib / staticlib / dylib). Used to decide
  ## whether the target lands in Pass A (libs) vs Pass B (binaries).
  case kind
  of rtkLibrary, rtkCdylib, rtkStaticlib, rtkDylib: true
  else: false

proc transitiveWorkspaceDeps(project: RustProject; rootName: string):
    seq[string] =
  ## M23: compute the transitive closure of workspace deps reachable
  ## from ``rootName`` (excluding ``rootName`` itself). The result is
  ## deterministic — packages are emitted in the order they are first
  ## discovered via a BFS over the workspace-dep graph.
  ##
  ## Rationale: rustc resolves transitive crate references by reading
  ## the rmeta of each direct ``--extern``-named crate and then needs
  ## to find the second-level dep on its own — either via another
  ## ``--extern`` flag or via ``-L dependency=<dir>``. For the M23
  ## workspace-lib-chain fixture (``crate_c → crate_b → crate_a``),
  ## threading ``--extern crate_b=...`` alone is insufficient; rustc
  ## also needs to reach crate_a's rmeta. Cargo itself threads every
  ## transitive dep as ``--extern <name>=...`` so we mirror that here.
  var nameToIdx = initTable[string, int]()
  for i in 0 ..< project.packages.len:
    nameToIdx[project.packages[i].packageName] = i
  if rootName notin nameToIdx:
    return @[]
  var seen = initHashSet[string]()
  var queue: seq[string] = @[]
  # Seed with the root's direct deps; don't include the root itself.
  for dep in project.packages[nameToIdx[rootName]].workspaceDeps:
    if dep == rootName:
      continue
    if dep notin seen:
      seen.incl dep
      queue.add(dep)
      result.add(dep)
  var i = 0
  while i < queue.len:
    let cur = queue[i]
    inc i
    if cur notin nameToIdx:
      continue
    for nextDep in project.packages[nameToIdx[cur]].workspaceDeps:
      if nextDep == rootName or nextDep in seen:
        continue
      seen.incl nextDep
      queue.add(nextDep)
      result.add(nextDep)

proc rustCrudeFallback(projectRoot: string;
                       request: ProviderGraphRequest):
                         GraphFragment {.gcsafe.} =
  ## Mode B emitter for Rust projects that can't take the Mode A path
  ## (today: any project carrying a ``build.rs``). Delegates to
  ## ``cargo build --release --locked --offline`` under io-monitor
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
  ## **M23 routing**: when a project pulls in a crates.io / git
  ## dependency (``source != null`` for a normal/build dep in cargo
  ## metadata's ``dependencies[]`` array), the convention routes to the
  ## Mode B crude fallback. The full Mode A path would need to either
  ## (a) eagerly run ``cargo fetch`` + extract per-dep ``--extern``
  ## paths from a separate ``cargo build --release --offline
  ## --message-format=json`` run, or (b) consult ``Cargo.lock`` +
  ## ``CARGO_HOME``'s on-disk layout. Both are non-trivial and out of
  ## scope for M23's "honest scope" cut — see the spec's
  ## "Crates.io / git deps" section for the trade-off. The Mode B
  ## fallback still gives users a working build; future milestones can
  ## graduate them to Mode A's per-rustc-action graph.
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
  ##
  ## **M23 lib→lib edges**: Pass A now topologically sorts library
  ## packages by their workspace deps so a downstream lib (say
  ## ``crate_b`` that depends on ``crate_a``) sees ``crate_a``'s rmeta
  ## + rlib in its own ``--extern`` flags. Pass B then sees all libs
  ## via ``libActionsByPackage`` regardless of declaration order.
  ##
  ## **M23 cdylib/staticlib/dylib**: ``extractTargets`` distinguishes
  ## per-target ``crate-type``; ``emitForTarget`` picks the matching
  ## ``--crate-type`` flag + output naming. These targets land in Pass A
  ## (they're "lib-flavoured") but their ``rlibPath`` is empty so
  ## downstream Rust crates don't reference them via ``--extern``.
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
    # M23: route external-dep projects through Mode B. Done AFTER
    # loadProject so the project view (and the per-package
    # hasExternalDeps flag) is populated; doing this earlier would
    # require duplicating the dep-walk logic. The Mode B fallback
    # invokes cargo itself which handles registry/git resolution
    # natively.
    if project.hasExternalDeps:
      return rustCrudeFallback(projectRoot, request)
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
    # M23: pre-compute the topologically-sorted package index list so
    # Pass A emits libs in dep order (producer before consumer).
    let libPkgOrder = topologicalSortLibPackages(project)
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
        ## package name → its first lib-flavoured target's actions
        ## (the only one a same-package bin or a workspace consumer can
        ## reference by the ``crate-name`` convention). Only entries
        ## whose lib has a real rlib (i.e. ``rtkLibrary``) are usable as
        ## ``--extern`` sources — cdylib/staticlib/dylib still land here
        ## for diagnostic completeness but their ``rlibPath`` is empty.
      var allActions: seq[BuildActionDef] = @[]

      # Pass A: libraries, in topological order so each lib's
      # ``--extern`` flags can point at upstream lib rmeta/rlib paths.
      for pkgIdx in libPkgOrder:
        let pkg = project.packages[pkgIdx]
        # Build the upstream-extern lists ONCE per package — every
        # lib-flavoured target of this package shares them. (Today
        # there's almost always at most one lib target per package, but
        # the data-shape supports >1 if a future fixture exercises it.)
        #
        # M23: ``--extern`` is emitted ONLY for DIRECT workspace deps
        # (that's how cargo does it); transitive deps are reached via
        # ``-L dependency=<dir>`` search paths. Without the ``-L`` flag,
        # rustc errors with "can't find crate for <transitive dep>"
        # when it walks an ``--extern``ed crate's rmeta and tries to
        # resolve ITS deps. We add one ``-L dependency=<lib's bin dir>``
        # AND one ``-L dependency=<lib's deps dir>`` per transitive lib
        # so the rlib + neighbouring rmeta both become discoverable.
        var metadataExterns: seq[string] = @[]
        var linkExterns: seq[string] = @[]
        var externDepIds: seq[string] = @[]
        var inputRmetas: seq[string] = @[]
        var inputRlibs: seq[string] = @[]
        var libSearchPaths = initOrderedSet[string]()
        let directDeps = pkg.workspaceDeps
        let transitiveDeps =
          transitiveWorkspaceDeps(project, pkg.packageName)
        for depName in transitiveDeps:
          if depName notin libActionsByPackage:
            continue
          let depActions = libActionsByPackage[depName]
          if depActions.rlibPath.len == 0:
            continue
          # Always add the lib's bin + deps dirs as search paths — rustc
          # needs the deps dir for the rmeta neighbour and the bin dir
          # for the rlib.
          libSearchPaths.incl(depActions.rlibPath.parentDir)
          libSearchPaths.incl(depActions.rmetaPath.parentDir)
          if depName notin directDeps:
            # Transitive-only: search-path is enough; no ``--extern``
            # needed (cargo doesn't emit one either). But carry the
            # producer's action ids + inputs so the engine's
            # fingerprint catches the upstream's rebuilds.
            if depActions.metadataAction.id notin externDepIds:
              externDepIds.add(depActions.metadataAction.id)
            if depActions.linkAction.id notin externDepIds:
              externDepIds.add(depActions.linkAction.id)
            inputRmetas.add(depActions.rmetaPath)
            inputRlibs.add(depActions.rlibPath)
            continue
          let baseName = depActions.rmetaPath.extractFilename
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
        # Prepend ``-L dependency=`` tokens for each transitive lib's
        # bin + deps dirs. Ordered set keeps the emit deterministic and
        # avoids duplicates when the same dir appears for multiple libs.
        var searchFlags: seq[string] = @[]
        for path in libSearchPaths:
          searchFlags.add("-L")
          searchFlags.add("dependency=" & path)
        metadataExterns = searchFlags & metadataExterns
        linkExterns = searchFlags & linkExterns
        for t in pkg.targets:
          if not isLibFlavoured(t.kind):
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
          # Record only the FIRST lib-flavoured target of each package
          # — that's the one a workspace consumer's ``--extern
          # <crateName>=<path>`` flag will point at when it depends on
          # the package by name.
          if pkg.packageName notin libActionsByPackage:
            libActionsByPackage[pkg.packageName] = actions

      # Pass B: binaries. Mirrors Pass A's transitive-deps logic —
      # ``--extern`` for direct deps + ``-L dependency=<dir>`` for the
      # transitive set so rustc can resolve transitive crate refs while
      # walking each direct dep's rmeta.
      for pkg in project.packages:
        var metadataExterns: seq[string] = @[]
        var linkExterns: seq[string] = @[]
        var externDepIds: seq[string] = @[]
        var inputRmetas: seq[string] = @[]
        var inputRlibs: seq[string] = @[]
        var libSearchPaths = initOrderedSet[string]()
        let directDeps = pkg.workspaceDeps
        let transitiveDeps =
          transitiveWorkspaceDeps(project, pkg.packageName)
        for depName in transitiveDeps:
          if depName notin libActionsByPackage:
            continue
          let depActions = libActionsByPackage[depName]
          # cdylib/staticlib/dylib aren't ``--extern``-able as Rust
          # deps. Skip them silently; the consumer can still link them
          # via the C-side toolchain but that's outside the M23 surface.
          if depActions.rlibPath.len == 0:
            continue
          libSearchPaths.incl(depActions.rlibPath.parentDir)
          libSearchPaths.incl(depActions.rmetaPath.parentDir)
          if depName notin directDeps:
            if depActions.metadataAction.id notin externDepIds:
              externDepIds.add(depActions.metadataAction.id)
            if depActions.linkAction.id notin externDepIds:
              externDepIds.add(depActions.linkAction.id)
            inputRmetas.add(depActions.rmetaPath)
            inputRlibs.add(depActions.rlibPath)
            continue
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
        var searchFlags: seq[string] = @[]
        for path in libSearchPaths:
          searchFlags.add("-L")
          searchFlags.add("dependency=" & path)
        metadataExterns = searchFlags & metadataExterns
        linkExterns = searchFlags & linkExterns
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

      # Pass C (M22): integration tests under ``tests/<name>.rs``. Per
      # cargo metadata's ``kind=["test"]`` filter; each becomes a
      # ``rustc --test`` compile + a run action that fires the harness.
      # The test target is non-default so ``repro build .#default``
      # stays bin/lib-only; ``repro build .#test`` opts in. Tests need
      # the package's primary lib target as the ``--extern`` source —
      # without it the test couldn't ``use <crate>::...``; we skip
      # tests for packages without a lib target.
      var testActions: seq[BuildActionDef] = @[]
      for pkg in project.packages:
        var hasTests = false
        for t in pkg.targets:
          if t.kind == rtkIntegrationTest:
            hasTests = true
            break
        if not hasTests:
          continue
        if pkg.packageName notin libActionsByPackage:
          # No lib target → tests would have nothing to ``use``. Cargo
          # itself would refuse to compile in this shape, so skip
          # silently. A future M can lift this when bin-only crates with
          # in-tree integration tests (against the bin's modules)
          # surface as a real case.
          continue
        let packageCrateName =
          normaliseCrateName(pkg.packageName)
        let libActions = libActionsByPackage[pkg.packageName]
        for t in pkg.targets:
          if t.kind != rtkIntegrationTest:
            continue
          let pair = emitForTestTarget(
            projectRoot = projectRoot,
            rustcExe = rustcExe,
            test = t,
            pkg = pkg,
            packageCrateName = packageCrateName,
            libActions = libActions)
          testActions.add(pair.compileAction)
          testActions.add(pair.runAction)
          testActions.add(pair.stampAction)
      if testActions.len > 0:
        discard target("test", testActions)
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
