## Rust language convention (Tier 2b) — Mode A "fine-grained" plugin.
##
## Recognises a Cargo project whose ``reprobuild.nim`` declares ``uses:``
## containing ``rust`` (or ``cargo``) AND ships a conventional Cargo
## layout. The convention spec
## (``reprobuild-specs/Language-Conventions/Rust.md`` §"Mode A — Fine-grained
## build graph") prescribes:
##
##   Pass 1 (metadata, per library-flavoured target; binaries skip it):
##     ``rustc --crate-name <n> --edition <e> --crate-type <lib|...>
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
##     own depfile. A library's Pass 2 depends on its Pass 1 so the
##     metadata edge is captured. A binary gets ``--extern`` for its own
##     package's library too, as Cargo passes it.
##
##   Action ids name the package, the target's kind and name, and the
##   phase (``rustActionId``), because a library and a binary of one
##   package usually share a crate name.
##
## **M13 extensions** over M4's single-crate-binary baseline:
##
##   * Library-only crates (``src/lib.rs`` with no ``src/main.rs``). The
##     convention now claims them and emits the two-action pipeline with
##     ``--crate-type lib --emit=link,dep-info`` producing ``lib<n>-<hash>.rlib``.
##   * ``[lib]`` and ``[[bin]]`` array entries in ``Cargo.toml``. The
##     convention iterates every ``bin``/``lib`` target reported by
##     ``cargo metadata`` and emits a (metadata, link) pair per library
##     target and a link action per binary.
##     Test targets (``kind: ["test"]``), example targets, and benchmarks
##     are intentionally skipped at the M13 surface — they're test-runner
##     territory (deferred to a later milestone).
##   * Workspaces (``[workspace] members = [...]``). The convention
##     enumerates every member package, emits per-target compile/link
##     actions for each, and wires inter-crate ``--extern <name>=<rmeta>``
##     edges based on each member's ``dependencies`` array (only path
##     deps that resolve to another workspace member). A crates.io / git
##     dependency, or a path dependency on a package that is no workspace
##     member, sends the whole project to the Mode B cargo fallback.
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
##   * ``harness = false`` beyond a plain ``[[test]]`` table — a
##     ``[[test]]`` with ``harness = false`` is compiled without ``--test``;
##     a setting ``scanHarnessSettings`` cannot attribute to one (inline
##     tables, ``[lib]``/``[[bin]]``) routes the workspace to the crude
##     fallback.
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
##   * Each target compiles under its own edition as ``cargo metadata``
##     reports it (a ``[lib]`` or ``[[bin]]`` table may override the
##     package's), never under one edition per package.
##   * ``-C metadata`` / ``-C extra-filename`` use a stable FNV-1a hash of
##     ``crateName & "@" & edition`` (the target's edition) — distinct
##     from cargo's own package-id hash because we don't have a published
##     source URL or features set in the M13 fixtures. This is fine for the
##     workspace/library cases where no downstream consumer expects
##     rmeta compatibility with ambient ``cargo check``.

import std/[algorithm, json, os, osproc, sets, strutils, tables]

import repro_core
import repro_provider_runtime
import repro_project_dsl
import repro_standard_provider/convention
import repro_standard_provider/conventions/emit_cache
import repro_standard_provider/crude
import repro_cargo_edge/edge_cli

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
    rawName: string
      ## The target's name as ``cargo metadata`` reports it, before the
      ## ``-`` → ``_`` normalisation. Cargo names ``CARGO_BIN_NAME`` and
      ## ``CARGO_BIN_EXE_<name>`` with it.
    edition: string
      ## The edition rustc compiles this target under: the target's own
      ## ``edition`` as ``cargo metadata`` reports it, which is the
      ## package's edition unless the target table sets its own
      ## (``targetEdition``).
    kind: RustTargetKind
    sourcePath: string
      ## Absolute path to the target's crate root (``main.rs``/``lib.rs``
      ## or whatever ``Cargo.toml`` declares).
    noHarness: bool
      ## An integration test declared with ``harness = false``
      ## (``scanHarnessSettings``): its test build is compiled with
      ## ``--cfg test`` in place of ``--test``, as Cargo does, so its own
      ## ``main`` runs.
    unitTests: bool
      ## The target's ``test`` key as ``cargo metadata`` reports it (the
      ## target table's ``test`` setting, ``true`` unless the manifest
      ## turns it off; Cargo reference, "Cargo Targets", "The ``test``
      ## field":
      ## https://doc.rust-lang.org/cargo/reference/cargo-targets.html#the-test-field).
      ## For a library or a binary it says whether ``cargo test`` builds
      ## and runs the target's own ``#[cfg(test)]`` code as a test crate;
      ## Mode A then emits that unit under the ``test`` target
      ## (``emitForUnitTestTarget``). For an integration test it says
      ## whether ``cargo test`` builds and runs it at all (``[[test]] test
      ## = false`` leaves it to ``cargo test --test <name>``), and Pass C
      ## emits none for ``false``.

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
      ## True when this package depends on a package Mode A does not
      ## compile: a dependency of any kind (normal, build or dev) with
      ## ``source != null`` (a crates.io registry or git dep), or a
      ## ``path`` dependency of any kind whose directory is not a
      ## workspace member (outside the workspace, listed in ``exclude``,
      ## or any path dependency of a package with no ``[workspace]``). ``cargo metadata --no-deps``
      ## lists members only, so Mode A has no target to compile for such
      ## a dependency and could pass no ``--extern`` for it. Used by the
      ## routing in ``rustEmitFragment`` to fall through to the Mode B
      ## crude fallback rather than emit a graph whose ``rustc`` fails to
      ## resolve the crate.
    hasFeatures: bool
      ## True when the package declares a feature (``features`` in
      ## ``cargo metadata`` is non-empty) or an optional dependency.
      ## Mode A does no feature resolution, so such a package sends the
      ## whole workspace to Mode B (Rust.md §"Recognition" item 6).
    harnessUnattributed: bool
      ## True when the package's ``Cargo.toml`` may set ``harness = false``
      ## where ``scanHarnessSettings`` cannot tell on which ``[[test]]``
      ## (``HarnessSettings.unattributed``). Mode A would build that
      ## target with ``rustc --test``, which replaces its ``main`` with
      ## libtest's runner, so this sends the whole workspace to Mode B
      ## (Rust.md §"Recognition" item 6).
    crateEnv: seq[(string, string)]
      ## The package-level variables Cargo sets for every crate of this
      ## package (``CARGO_PKG_*``, ``CARGO_MANIFEST_DIR``,
      ## ``CARGO_MANIFEST_PATH``), in a fixed order. Rust.md
      ## §"Features, lints and the crate environment".

  RustProject = object
    ## The full project view the emitter walks. ``packages`` always
    ## contains at least one entry; for workspaces it contains every
    ## member.
    packages: seq[RustPackage]
    isWorkspace: bool
    hasExternalDeps: bool
      ## M23: true when any package in the project depends on a
      ## crates.io / git source, or on a path package that is not a
      ## workspace member (``RustPackage.hasExternalDeps``). Routes the
      ## entire project through the
      ## Mode B crude fallback. See the M23 "Crates.io / git deps"
      ## section in ``Standard-Provider-Implementation.milestones.org``
      ## for the trade-off (we could ALSO try to harvest rlib paths from
      ## a separate ``cargo build --release --offline
      ## --message-format=json`` run, but the simpler "delegate to
      ## cargo" route lands in M23 and a full ``--extern``-threading
      ## implementation is deferred).
    hasFeatures: bool
      ## True when any package declares a feature or an optional
      ## dependency. Routes the entire project through Mode B: the
      ## features enabled on one package depend on what every package
      ## that depends on it asks for, so the trigger is workspace-wide
      ## (Rust.md §"Features, lints and the crate environment").
    harnessUnattributed: bool
      ## True when any package may set ``harness = false`` where Mode A
      ## cannot tell on which target (``RustPackage.harnessUnattributed``).
      ## Routes the entire project through Mode B, like ``hasFeatures``.

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

type
  HarnessSettings = object
    ## What ``scanHarnessSettings`` read from one ``Cargo.toml``.
    harnessOffTests: seq[string]
      ## Names of the ``[[test]]`` targets set ``harness = false`` in the
      ## plain form the scan attributes (see ``scanHarnessSettings``).
    unattributed: bool
      ## The manifest may set ``harness = false`` somewhere the scan
      ## cannot tie to a ``[[test]]``, ``[[bench]]`` or ``[[example]]``
      ## table and its name, or could not be read. Sends the workspace to
      ## Mode B.

proc looseHarnessFalseCount(text: string): int =
  ## How many times ``text`` may set ``harness = false``: every
  ## ``harness`` key, bare, quoted or the last part of a dotted key,
  ## followed by ``=`` and ``false``, wherever it stands. Errs towards
  ## counting (text inside a string value counts too).
  const keyChars = {'A'..'Z', 'a'..'z', '0'..'9', '_', '-'}
  const blank = {' ', '\t', '\r', '\n'}
  var start = 0
  while true:
    let at = text.find("harness", start)
    if at < 0:
      return
    start = at + len("harness")
    if at > 0 and text[at - 1] in keyChars:
      continue
    var i = start
    if i < text.len and text[i] in {'"', '\''}:
      # A quoted key: the quote before it must be the same one.
      if at == 0 or text[at - 1] != text[i]:
        continue
      inc i
    elif i < text.len and text[i] in keyChars:
      continue
    while i < text.len and text[i] in blank:
      inc i
    if i >= text.len or text[i] != '=':
      continue
    inc i
    while i < text.len and text[i] in blank:
      inc i
    if text.continuesWith("false", i) and
        (i + len("false") >= text.len or
          text[i + len("false")] notin keyChars):
      inc result

proc hasEscapedQuotedKey(line: string): bool =
  ## True when ``line`` holds a basic-string (``"..."``) key with an
  ## escape sequence in it, such as ``"harness" = false``: a key the
  ## loose count cannot read.
  var i = 0
  while i < line.len:
    if line[i] == '"':
      var j = i + 1
      var escaped = false
      while j < line.len and line[j] != '"':
        if line[j] == '\\':
          escaped = true
          inc j
        inc j
      if j >= line.len:
        return false
      var k = j + 1
      while k < line.len and line[k] in {' ', '\t'}:
        inc k
      if escaped and k < line.len and line[k] == '=':
        return true
      i = j + 1
    else:
      inc i
  false

proc plainValue(line, key: string): tuple[found: bool; value: string] =
  ## ``key = <value>`` written plainly on one line: a bare key, then the
  ## value, then optionally a comment. ``value`` is the text after ``=``
  ## with a trailing comment removed only when the value is not a string.
  let s = line.strip()
  if not s.startsWith(key):
    return
  let rest = s[key.len .. ^1].strip(trailing = false)
  if not rest.startsWith("="):
    return
  var value = rest[1 .. ^1].strip()
  if not value.startsWith("\""):
    let hash = value.find('#')
    if hash >= 0:
      value = value[0 ..< hash].strip()
  (true, value)

proc plainStringName(value: string): string =
  ## The name in ``"<name>"`` (optionally followed by a comment); empty
  ## when ``value`` is anything else, such as a string with an escape.
  if not value.startsWith("\""):
    return ""
  let close = value.find('"', 1)
  if close < 0:
    return ""
  let name = value[1 ..< close]
  let tail = value[close + 1 .. ^1].strip()
  if '\\' in name or (tail.len > 0 and not tail.startsWith("#")):
    return ""
  name

proc scanHarnessSettings(cargoTomlPath: string): HarnessSettings =
  ## Which targets ``Cargo.toml`` builds without libtest's harness.
  ## ``cargo metadata`` does not report ``harness`` (a target's keys are
  ## ``crate_types``, ``doc``, ``doctest``, ``edition``, ``kind``,
  ## ``name``, ``src_path`` and ``test``), so this reads the manifest.
  ## With ``harness = false`` Cargo compiles the target's test build
  ## without ``--test`` and the target's own ``main`` is the test (Cargo
  ## reference, "Cargo Targets", "The ``harness`` field":
  ## https://doc.rust-lang.org/cargo/reference/cargo-targets.html#the-harness-field).
  ##
  ## Deliberately not a TOML parser (see the module header). Two passes
  ## over the manifest, whole-line comments removed:
  ##
  ##   * ``looseHarnessFalseCount`` counts every place that may set
  ##     ``harness = false``, in any form;
  ##   * a line-wise pass attributes the plain form: a ``harness = false``
  ##     line inside a ``[[test]]``, ``[[bench]]`` or ``[[example]]``
  ##     table. A ``[[test]]`` table's name comes from its plain
  ##     ``name = "<name>"`` line; ``[[bench]]`` and ``[[example]]`` need
  ##     none, since Mode A builds neither.
  ##
  ## When the loose count exceeds what the second pass attributed (an
  ## inline table, a dotted or quoted key, ``[lib]`` or ``[[bin]]``,
  ## whose test crates Mode A compiles with ``--test`` only
  ## (``emitForUnitTestTarget``), a ``[[test]]`` with no plain name), or a quoted key holds an escape, or the manifest holds a
  ## multi-line string (``"""`` or ``'''``, which the line-wise pass cannot
  ## see into), or the file cannot be read, ``unattributed`` is set and
  ## the workspace goes to Mode B, which cargo builds as declared.
  if not fileExists(extendedPath(cargoTomlPath)):
    return
  var raw: string
  try:
    raw = readFile(extendedPath(cargoTomlPath))
  except CatchableError:
    result.unattributed = true
    return
  var text = ""
  var lines: seq[string] = @[]
  for line in raw.splitLines():
    if line.strip().startsWith("#"):
      continue
    text.add(line)
    text.add('\n')
    lines.add(line)
    if hasEscapedQuotedKey(line):
      result.unattributed = true
  let loose = looseHarnessFalseCount(text)
  if loose == 0:
    return
  if "\"\"\"" in text or "\'\'\'" in text:
    # A multi-line string can hold lines that look like table headers or
    # ``name =`` lines; the line-wise pass cannot tell them apart, and
    # would credit a setting to the wrong table.
    result.unattributed = true
    return
  var attributed = 0
  var section = ""
  var sectionName = ""
  var sectionHarnessOff = 0
  proc flush(settings: var HarnessSettings; attributed: var int;
             section, sectionName: string; sectionHarnessOff: int) =
    if sectionHarnessOff == 0:
      return
    case section
    of "[[test]]":
      if sectionName.len > 0:
        settings.harnessOffTests.add(sectionName)
        attributed += sectionHarnessOff
    of "[[bench]]", "[[example]]":
      attributed += sectionHarnessOff
    else:
      discard
  for line in lines:
    let s = line.strip()
    if s.startsWith("["):
      flush(result, attributed, section, sectionName, sectionHarnessOff)
      let close = s.find(']')
      section =
        if s.startsWith("[["):
          let c2 = s.find("]]")
          if c2 < 0: s
          else: "[[" & s[2 ..< c2].strip() & "]]"
        elif close < 0: s
        else: "[" & s[1 ..< close].strip() & "]"
      sectionName = ""
      sectionHarnessOff = 0
      continue
    let h = plainValue(line, "harness")
    if h.found and h.value == "false":
      inc sectionHarnessOff
      continue
    let n = plainValue(line, "name")
    if n.found:
      sectionName = plainStringName(n.value)
  flush(result, attributed, section, sectionName, sectionHarnessOff)
  if loose > attributed:
    result.unattributed = true

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
  ##   * every ``README``, ``README.md`` and ``README.txt``: with no
  ##     ``readme`` key in the manifest, cargo metadata reports the one it
  ##     finds beside it, and that value becomes ``CARGO_PKG_README``.
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
    if basename == "cargo.toml" or basename == "cargo.lock" or ext == ".rs" or
        basename in ["readme", "readme.md", "readme.txt"]:
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

const CargoDefaultEdition = "2015"
  ## The edition Cargo assumes for a package whose manifest declares none,
  ## and rustc's own default for ``--edition``
  ## (https://doc.rust-lang.org/cargo/reference/manifest.html#the-edition-field,
  ## https://doc.rust-lang.org/rustc/command-line-arguments.html#--edition-specify-the-edition-to-use).

proc nonEmptyStringField(node: JsonNode; key: string): string =
  ## ``node[key]`` when it is a non-empty JSON string, else ``""``.
  if node.kind == JObject and key in node and node[key].kind == JString:
    node[key].getStr()
  else:
    ""

proc targetEdition(target: JsonNode; packageEdition: string): string =
  ## The edition one ``targets[]`` entry of ``cargo metadata`` compiles
  ## under. A target table (``[lib]``, ``[[bin]]``, ``[[test]]``, ...) may
  ## set its own ``edition``, which overrides the package's for that target
  ## alone, and ``cargo metadata`` reports the result per target
  ## (https://doc.rust-lang.org/cargo/reference/cargo-targets.html#the-edition-field).
  ## Cargo always fills the field in; the package edition is only a
  ## fallback for output that lacks it.
  let own = nonEmptyStringField(target, "edition")
  if own.len > 0: own else: packageEdition

proc extractTargets(pkgNode: JsonNode;
                    packageEdition: string): seq[RustTarget] =
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
        # one ``targets[]`` entry per file. A library's or a binary's own
        # ``#[cfg(test)]`` tests are no target of this kind: they are the
        # ``test`` key of the lib/bin entry (``RustTarget.unitTests``).
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
    # Cargo reports ``test`` for every target; a metadata without it is
    # read as Cargo's default, ``true``.
    let unitTests =
      if "test" in target and target["test"].kind == JBool:
        target["test"].getBool()
      else: true
    result.add(RustTarget(
      crateName: normaliseCrateName(rawName),
      rawName: rawName,
      edition: targetEdition(target, packageEdition),
      kind: kind,
      sourcePath: srcPath,
      unitTests: unitTests))
    if isOther:
      # Future-proofing: don't fail loud, but a custom kind on the same
      # target as bin/lib is unusual enough that the comment surfaces in
      # ``--log=actions`` debugging if anyone hits it.
      discard

proc jsonStringField(node: JsonNode; key: string): string =
  ## ``node[key]`` as a string, or ``""`` when absent or ``null`` — the
  ## value Cargo gives a ``CARGO_PKG_*`` variable whose manifest key is
  ## unset.
  if node.kind == JObject and key in node and node[key].kind == JString:
    node[key].getStr()
  else:
    ""

proc semverComponents(version: string):
    tuple[major, minor, patch, pre: string] =
  ## Split ``MAJOR.MINOR.PATCH[-PRE][+BUILD]`` the way Cargo fills
  ## ``CARGO_PKG_VERSION_{MAJOR,MINOR,PATCH,PRE}``. Build metadata is
  ## dropped; ``pre`` is empty for a release version. Cargo has already
  ## validated the version, so this does not.
  var core = version
  let plusIdx = core.find('+')
  if plusIdx >= 0:
    core = core[0 ..< plusIdx]
  let dashIdx = core.find('-')
  if dashIdx >= 0:
    result.pre = core[dashIdx + 1 .. ^1]
    core = core[0 ..< dashIdx]
  let parts = core.split('.')
  if parts.len > 0: result.major = parts[0]
  if parts.len > 1: result.minor = parts[1]
  if parts.len > 2: result.patch = parts[2]

proc packageCrateEnv(pkgNode: JsonNode; manifestPath: string):
    seq[(string, string)] =
  ## The package-level half of the crate environment, from the
  ## package's entry in ``cargo metadata`` (Cargo reference,
  ## "Environment variables Cargo sets for crates"). Every variable is
  ## present, holding ``""`` when the manifest has no value, as Cargo
  ## does. ``CARGO_PKG_AUTHORS`` joins the authors with ``:``.
  let version = jsonStringField(pkgNode, "version")
  let parts = semverComponents(version)
  var authors: seq[string] = @[]
  if "authors" in pkgNode and pkgNode["authors"].kind == JArray:
    for a in pkgNode["authors"]:
      if a.kind == JString:
        authors.add(a.getStr())
  result = @[
    ("CARGO_PKG_NAME", jsonStringField(pkgNode, "name")),
    ("CARGO_PKG_VERSION", version),
    ("CARGO_PKG_VERSION_MAJOR", parts.major),
    ("CARGO_PKG_VERSION_MINOR", parts.minor),
    ("CARGO_PKG_VERSION_PATCH", parts.patch),
    ("CARGO_PKG_VERSION_PRE", parts.pre),
    ("CARGO_PKG_AUTHORS", authors.join(":")),
    ("CARGO_PKG_DESCRIPTION", jsonStringField(pkgNode, "description")),
    ("CARGO_PKG_HOMEPAGE", jsonStringField(pkgNode, "homepage")),
    ("CARGO_PKG_REPOSITORY", jsonStringField(pkgNode, "repository")),
    ("CARGO_PKG_LICENSE", jsonStringField(pkgNode, "license")),
    ("CARGO_PKG_LICENSE_FILE", jsonStringField(pkgNode, "license_file")),
    ("CARGO_PKG_RUST_VERSION", jsonStringField(pkgNode, "rust_version")),
    ("CARGO_PKG_README", jsonStringField(pkgNode, "readme")),
    ("CARGO_MANIFEST_DIR", manifestPath.parentDir),
    ("CARGO_MANIFEST_PATH", manifestPath),
  ]

proc packageDeclaresFeatures(pkgNode: JsonNode): bool =
  ## A feature in ``[features]`` or an optional dependency. Either one
  ## makes the crate's ``--cfg feature`` set depend on feature
  ## resolution, which Mode A does not do (Rust.md §"Recognition"
  ## item 6).
  if "features" in pkgNode and pkgNode["features"].kind == JObject and
      pkgNode["features"].len > 0:
    return true
  if "dependencies" in pkgNode and pkgNode["dependencies"].kind == JArray:
    for dep in pkgNode["dependencies"]:
      if dep.kind == JObject and "optional" in dep and
          dep["optional"].kind == JBool and dep["optional"].getBool():
        return true
  false

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
    # The package's edition is only the default for its targets; each
    # target's own edition is resolved in ``extractTargets``. Real
    # ``cargo metadata`` always reports it, so the fallback is reached
    # only on malformed output, and then it is what Cargo and rustc assume.
    let packageEdition = block:
      let declared = nonEmptyStringField(pkgNode, "edition")
      if declared.len > 0: declared else: CargoDefaultEdition
    let manifestPath =
      if "manifest_path" in pkgNode: pkgNode["manifest_path"].getStr()
      else: ""
    let manifestDir =
      if manifestPath.len > 0: manifestPath.parentDir
      else: projectRoot
    var targets = extractTargets(pkgNode, packageEdition)
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
        # A registry or git dependency (``source`` set) sends the
        # workspace to Mode B whatever its kind (Rust.md §"Recognition",
        # item 6). That includes a dev-dependency: Mode A gives a test
        # compile ``--extern`` for its own package's library only, so
        # ``rustc`` would fail to resolve the crate in ``repro build
        # .#test`` (reprobuild-pm
        # issues/2026-11-17-rust-mode-a-tolerates-registry-dev-dependencies-that-its-test-compile-cannot-resolve.md).
        let hasSource = "source" in dep and dep["source"].kind != JNull
        if hasSource:
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
        else:
          # A path dependency on a package that is not a workspace member:
          # ``cargo metadata --no-deps`` does not list it, so Mode A has
          # no target to compile and no rlib to pass with ``--extern``.
          # Dropping it would leave ``rustc`` with an unresolved crate;
          # cargo resolves it in Mode B. As for a registry dependency
          # this applies to every kind: a dev-dependency here would leave
          # the package's test compile with the same unresolved crate.
          hasExternalDeps = true
    if hasExternalDeps:
      result.hasExternalDeps = true
    let hasFeatures = packageDeclaresFeatures(pkgNode)
    if hasFeatures:
      result.hasFeatures = true
    let harness = scanHarnessSettings(
      if manifestPath.len > 0: manifestPath
      else: projectRoot / "Cargo.toml")
    let harnessUnattributed = harness.unattributed
    if harnessUnattributed:
      result.harnessUnattributed = true
    for t in targets.mitems:
      if t.kind == rtkIntegrationTest and t.rawName in harness.harnessOffTests:
        t.noHarness = true
    let crateEnv = packageCrateEnv(pkgNode,
      if manifestPath.len > 0: manifestPath
      else: projectRoot / "Cargo.toml")
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
        hasExternalDeps: hasExternalDeps,
        hasFeatures: hasFeatures,
        harnessUnattributed: harnessUnattributed,
        crateEnv: crateEnv))
      continue
    result.packages.add(RustPackage(
      packageName: name,
      manifestPath: manifestPath,
      manifestDir: manifestDir,
      targets: targets,
      workspaceDeps: workspaceDeps,
      hasExternalDeps: hasExternalDeps,
      hasFeatures: hasFeatures,
      harnessUnattributed: harnessUnattributed,
      crateEnv: crateEnv))
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

proc unitTestsScratchDir(projectRoot, packageCrateName,
                         kindToken: string): string =
  ## Where the test crate of a library's or a binary's own ``#[cfg(test)]``
  ## code goes: ``<scratch>/<package>/tests/unit-<kind>``. Its crate name is
  ## the target's, which an integration test ``tests/<package>.rs`` and a
  ## binary sharing the library's name can also have, so each kind gets its
  ## own directory. ``unit-<kind>`` holds a ``-``, which no crate name
  ## does, so it cannot be an integration test's binary or stamp.
  testsScratchDir(projectRoot, packageCrateName) / ("unit-" & kindToken)

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

proc targetKindToken(kind: RustTargetKind): string =
  ## The target's kind as ``cargo metadata`` names it in a target's
  ## ``kind`` array (``lib`` also stands for a ``[lib]`` reported as
  ## ``rlib``).
  case kind
  of rtkBinary: "bin"
  of rtkLibrary: "lib"
  of rtkCdylib: "cdylib"
  of rtkStaticlib: "staticlib"
  of rtkDylib: "dylib"
  of rtkIntegrationTest: "test"

proc actionIdPart(value: string): string =
  ## One component of an action id: ``value`` with every character other
  ## than an ASCII letter, digit, ``-`` or ``_`` replaced by ``_``. Those
  ## are the characters of an ordinary package or target name; for any
  ## other name the replacement can make two ids equal, and the engine
  ## then refuses the graph with a "duplicate action id" error rather
  ## than build either action wrongly. It keeps ``.`` out of the
  ## components, which ``rustActionId`` uses to separate them.
  for ch in value:
    if ch in {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '-', '_'}:
      result.add(ch)
    else:
      result.add('_')
  if result.len == 0:
    result = "_"

proc rustActionId(phase: string; pkg: RustPackage;
                  target: RustTarget): string =
  ## The id of one of a target's actions:
  ## ``rustc-<phase>-<package>.<kind>.<target>``. A crate name does not
  ## identify a target: Cargo's default layout, ``src/lib.rs`` plus
  ## ``src/main.rs``, gives the library and the binary the package's name
  ## (Cargo reference, "Cargo Targets", "Target auto-discovery":
  ## https://doc.rust-lang.org/cargo/reference/cargo-targets.html#target-auto-discovery),
  ## and two workspace members may each have a target of one name. So the
  ## id names the package, the target's kind and its name as ``cargo
  ## metadata`` reports them, and the phase, which also says whether the
  ## action is a test-harness build (``test-compile``, ``test-run``,
  ## ``test-stamp``). The engine refuses a graph in which two actions share
  ## an id. ``.`` separates the components because no component can hold
  ## one (``actionIdPart``), and no phase followed by ``-`` begins another
  ## phase, so two tuples of ordinary names never give one id.
  "rustc-" & phase & "-" & actionIdPart(pkg.packageName) & "." &
    targetKindToken(target.kind) & "." & actionIdPart(target.rawName)

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

proc testTargetTmpDir(projectRoot, packageCrateName: string): string =
  ## ``CARGO_TARGET_TMPDIR`` for a package's integration tests: Cargo's
  ## ``target/tmp``, here one per package beside its ``tests/`` dir so
  ## that no test binary's name can collide with it.
  scratchPathFor(projectRoot, packageCrateName) / "tmp"

proc targetCrateEnv(pkg: RustPackage; target: RustTarget;
                    cargoExe: string): seq[(string, string)] =
  ## The whole crate environment of one ``rustc`` action (Rust.md
  ## §"Features, lints and the crate environment"): the package's
  ## variables, then the target's ``CARGO_CRATE_NAME`` (and
  ## ``CARGO_BIN_NAME`` for a binary), ``CARGO_PRIMARY_PACKAGE=1`` — Mode
  ## A builds every workspace member, as ``cargo build --workspace``
  ## selects them all — and ``CARGO``. Paths are passed as they are, not
  ## canonicalised: ``env!`` puts them in the output. The engine's local
  ## action key covers the declared values. The portable key (used for
  ## content-checked actions, or when portable caching is turned on) is
  ## weaker here: it rewrites paths under the tracked roots in a declared
  ## variable to location-independent tokens, as it does in the argv. So
  ## two checkouts at different locations can share one entry although
  ## the output embeds the path of only one of them, as ``rustc`` also
  ## embeds argv paths through ``file!()`` and debug info. Closing that
  ## gap belongs to the portable key, not to this convention.
  result = pkg.crateEnv
  result.add(("CARGO_CRATE_NAME", target.crateName))
  if target.kind == rtkBinary:
    result.add(("CARGO_BIN_NAME", target.rawName))
  result.add(("CARGO_PRIMARY_PACKAGE", "1"))
  result.add(("CARGO", cargoExe))

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
    crateName: string
      ## The target's crate name: the name a consumer passes with
      ## ``--extern <crateName>=<rlib>``.
    metadataAction: BuildActionDef
      ## Library-flavoured targets only; a binary has none (its ``id`` is
      ## empty).
    linkAction: BuildActionDef
    rmetaPath: string
      ## Empty for binary targets.
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

proc isLibFlavoured(kind: RustTargetKind): bool =
  ## M23: classify whether a target compiles into a "library-flavoured"
  ## artefact (rlib / cdylib / staticlib / dylib). Used to decide
  ## whether the target lands in Pass A (libs) vs Pass B (binaries).
  case kind
  of rtkLibrary, rtkCdylib, rtkStaticlib, rtkDylib: true
  else: false

proc emitForTarget(projectRoot, rustcExe: string;
                   target: RustTarget;
                   pkg: RustPackage;
                   metadataExterns: seq[string];
                   linkExterns: seq[string];
                   externDepIds: seq[string];
                   inputRmetas: seq[string];
                   inputRlibs: seq[string];
                   crateEnv: seq[(string, string)]): TargetActions =
  ## Materialise the actions of a single bin/lib target: a library-
  ## flavoured target gets a metadata-only pass and a link pass, a binary
  ## the link pass alone. Cargo's pipelining exists so that a dependent
  ## crate can type-check against the library's metadata before its
  ## codegen ends; nothing depends on a binary, so a binary's metadata
  ## pass would only repeat its type-check (Cargo emits none:
  ## ``--emit=dep-info,link`` for a binary).
  ##
  ## ``metadataExterns`` and ``linkExterns`` carry the pre-built
  ## ``--extern name=path`` pairs the metadata pass and the link pass
  ## see respectively. The metadata pass points at upstream ``.rmeta``
  ## files; the link pass points at upstream ``.rlib`` files (linkage
  ## requires the compiled artifact, not just the metadata).
  ## ``externDepIds`` is the action-id list those externs introduce as
  ## deps of both passes.
  let stableHash = stableHashHex(target.crateName & "@" & target.edition)
  let hasMetadataPass = isLibFlavoured(target.kind)
  let depsDir = depsPathFor(projectRoot, target.crateName)
  let binDir = binPathFor(projectRoot, target.crateName)
  if hasMetadataPass:
    createDir(extendedPath(depsDir))
  createDir(extendedPath(binDir))

  let crateType = crateTypeArg(target.kind)
  let crateSources = collectRustSourcesUnderManifest(pkg.manifestDir)
  var metadataAction: BuildActionDef
  var rmetaOutput = ""
  if hasMetadataPass:
    let metadataDepfile =
      metadataDepfilePath(projectRoot, target.crateName, stableHash)
    rmetaOutput = rmetaOutputPath(projectRoot, target.crateName, stableHash)
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
    let metadataInputs = block:
      var inputs = crateSources
      inputs.add(pkg.manifestPath)
      for rmeta in inputRmetas:
        inputs.add(rmeta)
      inputs
    metadataAction = buildAction(
      id = rustActionId("metadata", pkg, target),
      call = inlineExecCall(metadataArgv, projectRoot),
      deps = externDepIds,
      inputs = metadataInputs,
      outputs = @[rmetaOutput, metadataDepfile],
      pool = "compile",
      depfile = metadataDepfile,
      dependencyPolicy = makeDepfilePolicy(metadataDepfile),
      commandStatsId = "rust.rustc-metadata",
      env = crateEnv)

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
    if hasMetadataPass:
      inputs.add(rmetaOutput)
    for rlib in inputRlibs:
      inputs.add(rlib)
    inputs

  var linkDeps: seq[string] = @[]
  if hasMetadataPass:
    linkDeps.add(metadataAction.id)
  for depId in externDepIds:
    if depId notin linkDeps:
      linkDeps.add(depId)

  let linkAction = buildAction(
    id = rustActionId("link", pkg, target),
    call = inlineExecCall(linkArgv, projectRoot),
    deps = linkDeps,
    inputs = linkInputs,
    outputs = @[linkOutput, linkDepfile],
    pool = "compile",
    depfile = linkDepfile,
    dependencyPolicy = makeDepfilePolicy(linkDepfile),
    commandStatsId = "rust.rustc-link",
    env = crateEnv)

  TargetActions(
    crateName: target.crateName,
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
                       libActions: TargetActions;
                       binActions: seq[(RustTarget, TargetActions)];
                       cargoExe: string): TestTargetActions =
  ## M22: emit the compile + run action pair for a single integration
  ## test (``tests/<name>.rs``).
  ##
  ##   Compile action:
  ##     ``rustc [--test] --crate-name <name> --edition <e>
  ##       --crate-type bin --emit=link --out-dir <scratch>/tests
  ##       -L dependency=<scratch>/<crate>/deps
  ##       --extern <libCrate>=<rlib>
  ##       <test.rs>``
  ##
  ##     A ``harness = false`` target (``RustTarget.noHarness``) gets
  ##     ``--cfg test`` in place of ``--test``: its own ``main`` is the
  ##     test, as under Cargo.
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
  ##
  ## ``binActions`` are the package's binaries. As Cargo does, the compile
  ## sees each one's path in ``CARGO_BIN_EXE_<name>`` and depends on its
  ## link action. ``CARGO_TARGET_TMPDIR`` names a directory created here
  ## and declared a scratch directory of the run action, so the engine
  ## recreates it empty before the test runs, even from a cached graph,
  ## and what the test writes and reads back there is not taken as an
  ## input (Rust.md §"Features, lints and the crate environment").
  let testsDir = testsScratchDir(projectRoot, packageCrateName)
  let depsDir = depsPathFor(projectRoot, packageCrateName)
  createDir(extendedPath(testsDir))
  let binaryOutput =
    testBinaryPath(projectRoot, packageCrateName, test.crateName)

  var argv = @[rustcExe]
  if test.noHarness:
    # ``harness = false``: the target is a plain program whose ``main`` is
    # the test. ``--test`` would replace that ``main`` with libtest's
    # runner (Rust.md §"Test commands"). Cargo passes ``--cfg test``
    # instead, so ``#[cfg(test)]`` code is still compiled in.
    argv.add(@["--cfg", "test"])
  else:
    argv.add("--test")
  argv.add(@[
    "--crate-name", test.crateName,
    "--edition", test.edition,
    "--crate-type", crateTypeArg(test.kind),
    "--emit=link",
    "--out-dir", testsDir,
    "-L", "dependency=" & depsDir,
  ])
  if libActions.crateName.len > 0 and libActions.rlibPath.len > 0:
    argv.add("--extern")
    argv.add(libActions.crateName & "=" & libActions.rlibPath)
  argv.add(test.sourcePath)

  let tmpDir = testTargetTmpDir(projectRoot, packageCrateName)
  createDir(extendedPath(tmpDir))
  var compileEnv = targetCrateEnv(pkg, test, cargoExe)
  for (bin, actions) in binActions:
    compileEnv.add(("CARGO_BIN_EXE_" & bin.rawName,
      actions.linkAction.outputs[0]))
  compileEnv.add(("CARGO_TARGET_TMPDIR", tmpDir))

  let compileInputs = block:
    var inputs: seq[string] = @[test.sourcePath, pkg.manifestPath]
    if libActions.rlibPath.len > 0:
      inputs.add(libActions.rlibPath)
    if libActions.rmetaPath.len > 0:
      inputs.add(libActions.rmetaPath)
    for (_, actions) in binActions:
      # The path in CARGO_BIN_EXE_<name> is stable across rebuilds, so the
      # binary's bytes must be an input for the compile to see a change.
      inputs.add(actions.linkAction.outputs[0])
    inputs
  let compileDeps = block:
    var deps: seq[string] = @[]
    if libActions.linkAction.id.len > 0:
      deps.add(libActions.linkAction.id)
    if libActions.metadataAction.id.len > 0 and
        libActions.metadataAction.id notin deps:
      deps.add(libActions.metadataAction.id)
    for (_, actions) in binActions:
      if actions.linkAction.id notin deps:
        deps.add(actions.linkAction.id)
    deps

  let compileAction = buildAction(
    id = rustActionId("test-compile", pkg, test),
    call = inlineExecCall(argv, projectRoot),
    deps = compileDeps,
    inputs = compileInputs,
    outputs = @[binaryOutput],
    pool = "compile",
    dependencyPolicy = automaticMonitorPolicy(),
    commandStatsId = "rust.rustc-test-compile",
    env = compileEnv)

  let stampPath =
    testRunStampPath(projectRoot, packageCrateName, test.crateName)
  let runArgv = @[binaryOutput]
  # Cargo also sets the package, manifest, CARGO_BIN_EXE_* and
  # CARGO_TARGET_TMPDIR variables when it runs the test, so tests that read
  # them at run time (``std::env::var``) find them. The compile-only ones
  # are left out.
  var runEnv: seq[(string, string)] = @[]
  for (k, v) in compileEnv:
    if k notin ["CARGO_CRATE_NAME", "CARGO_BIN_NAME",
                "CARGO_PRIMARY_PACKAGE"]:
      runEnv.add((k, v))
  var runInputs = @[binaryOutput]
  var runDeps = @[compileAction.id]
  for (_, actions) in binActions:
    # The test executes these binaries, so a relinked binary reruns it.
    runInputs.add(actions.linkAction.outputs[0])
    if actions.linkAction.id notin runDeps:
      runDeps.add(actions.linkAction.id)
  # Cargo runs a test with its package's directory as the working
  # directory, so a test that opens a path relative to it finds the file.
  let runAction = buildAction(
    id = rustActionId("test-run", pkg, test),
    call = inlineExecCall(runArgv, pkg.manifestDir),
    deps = runDeps,
    inputs = runInputs,
    outputs = @[],
    pool = "compile",
    dependencyPolicy = automaticMonitorPolicy(),
    commandStatsId = "rust.rustc-test-run",
    env = runEnv,
    scratchDirs = @[tmpDir])

  # Stamp the run so the engine has a declared output to track. The
  # stamp's text is the test's crate name — purely diagnostic.
  createDir(extendedPath(parentDir(stampPath)))
  let stampAction = fs.stamp(
    output = stampPath,
    title = "rust-test:" & test.crateName,
    entries = @[test.crateName],
    actionId = rustActionId("test-stamp", pkg, test),
    deps = @[runAction.id],
    commandStatsId = "rust.rustc-test-stamp")

  TestTargetActions(
    compileAction: compileAction,
    runAction: runAction,
    stampAction: stampAction)

proc emitForUnitTestTarget(projectRoot, rustcExe: string;
                           target: RustTarget;
                           pkg: RustPackage;
                           packageCrateName: string;
                           linkExterns: seq[string];
                           externDepIds: seq[string];
                           inputRlibs: seq[string];
                           cargoExe: string): TestTargetActions =
  ## The test crate of a library's or a binary's own ``#[cfg(test)]`` code
  ## (Rust.md §"Test commands"): the target's crate root compiled again
  ## with ``--test``, then run and stamped like an integration test.
  ## ``cargo test`` builds this unit for every lib and bin target whose
  ## ``test`` key is ``true``, alongside the target's ordinary build.
  ##
  ##   ``rustc --test --crate-name <crate> --edition <e> --crate-type bin
  ##     --emit=link --out-dir <scratch>/tests/unit-<kind>
  ##     -C metadata=<hash> <the target's -L / --extern flags> <root>.rs``
  ##
  ## ``linkExterns`` / ``externDepIds`` / ``inputRlibs`` are the ones the
  ## target's own link action gets: the test crate is the same source
  ## with the same dependencies, and for a binary that includes its own
  ## package's library, as Cargo passes it. The crate environment is the
  ## target's (Cargo sets ``CARGO_BIN_NAME`` for a binary's test crate as
  ## well, and neither ``CARGO_BIN_EXE_*`` nor ``CARGO_TARGET_TMPDIR``,
  ## which are for integration tests and benchmarks only).
  ##
  ## A target with ``harness = false`` should be built without
  ## ``--test``; ``cargo metadata`` does not report ``harness``, so that
  ## case is not told apart here (reprobuild-pm issue
  ## ``2026-11-17-rust-mode-a-compiles-harness-false-integration-tests-with-the-test-harness.md``).
  let kindToken = targetKindToken(target.kind)
  let outDir = unitTestsScratchDir(projectRoot, packageCrateName, kindToken)
  createDir(extendedPath(outDir))
  let binaryOutput =
    when defined(windows): outDir / (target.crateName & ".exe")
    else: outDir / target.crateName
  # A test crate's own ``-C metadata``, so its symbols differ from the
  # target's ordinary build and from a library it is linked against that
  # has the same crate name (a binary's test crate gets
  # ``--extern <its own lib>``, as Cargo passes it).
  let stableHash = stableHashHex("test:" & kindToken & ":" &
    target.crateName & "@" & target.edition)
  var argv = @[
    rustcExe,
    "--test",
    "--crate-name", target.crateName,
    "--edition", target.edition,
    "--crate-type", "bin",
    "--emit=link",
    "--out-dir", outDir,
    "-C", "metadata=" & stableHash,
  ]
  for flag in linkExterns:
    argv.add(flag)
  argv.add(target.sourcePath)

  let compileEnv = targetCrateEnv(pkg, target, cargoExe)
  let compileInputs = block:
    var inputs = collectRustSourcesUnderManifest(pkg.manifestDir)
    if target.sourcePath notin inputs:
      inputs.add(target.sourcePath)
    inputs.add(pkg.manifestPath)
    for rlib in inputRlibs:
      inputs.add(rlib)
    inputs
  let compileAction = buildAction(
    id = rustActionId("test-compile", pkg, target),
    call = inlineExecCall(argv, projectRoot),
    deps = externDepIds,
    inputs = compileInputs,
    outputs = @[binaryOutput],
    pool = "compile",
    dependencyPolicy = automaticMonitorPolicy(),
    commandStatsId = "rust.rustc-test-compile",
    env = compileEnv)

  var runEnv: seq[(string, string)] = @[]
  for (k, v) in compileEnv:
    if k notin ["CARGO_CRATE_NAME", "CARGO_BIN_NAME",
                "CARGO_PRIMARY_PACKAGE"]:
      runEnv.add((k, v))
  # Run from the package's directory, as Cargo does.
  let runAction = buildAction(
    id = rustActionId("test-run", pkg, target),
    call = inlineExecCall(@[binaryOutput], pkg.manifestDir),
    deps = @[compileAction.id],
    inputs = @[binaryOutput],
    outputs = @[],
    pool = "compile",
    dependencyPolicy = automaticMonitorPolicy(),
    commandStatsId = "rust.rustc-test-run",
    env = runEnv)

  let stampPath = outDir / (target.crateName & ".stamp")
  let stampAction = fs.stamp(
    output = stampPath,
    title = "rust-test:" & kindToken & ":" & target.crateName,
    entries = @[target.crateName],
    actionId = rustActionId("test-stamp", pkg, target),
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

proc libraryTargetName(pkg: RustPackage; lib: RustTarget): string =
  ## The named target of a package's library: its crate name, unless one
  ## of the package's binaries has that crate name too, as Cargo's default
  ## ``src/lib.rs`` plus ``src/main.rs`` layout gives both. The binary
  ## then keeps the name, since it is what ``cargo run`` and ``cargo build
  ## --bin <name>`` select by that name, and the library's target is
  ## ``<crate>-lib``. A crate name holds no ``-``, so that name cannot be
  ## another target's crate name.
  for t in pkg.targets:
    if t.kind == rtkBinary and t.crateName == lib.crateName:
      return lib.crateName & "-lib"
  lib.crateName

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
    let cargoArgv = @[
      cargoExe,
      "build",
      "--release",
      "--locked",
      "--offline",
    ]
    # The thin cargo edge (``libs/repro_cargo_edge``, Build-Engine-And-
    # Scheduler.md "Integration tiers" -> Cargo). cargo stays the build system;
    # the edge asks it, through ``--message-format=json``, which final
    # products it made, and writes that answer to ``productsFile``, the
    # action's one declared output. ``target`` is cargo's own incremental
    # state: a tool-owned cache that is neither declared nor cleared, so an
    # edit to one crate recompiles that crate. Declaring it an output (as this
    # used to) made the engine record the whole tree, and declaring it opaque
    # would clear it before every run and recompile every unit.
    let productsFile = projectRoot / ".repro" / "build" / "cargo" /
      (packageName & ".products")
    let argv = edgeCommand(getAppFilename(), productsFile, cargoArgv)
    result = emitCrudeFragment(
      projectRoot = projectRoot,
      request = request,
      packageName = packageName,
      nativeBuildArgv = argv,
      outputDirs = [],
      toolCacheDirs = ["target"],
      outputFiles = [productsFile],
      widthFlag = "-j")

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
    # Rust.md §"Recognition" item 6: Mode A passes no ``--cfg feature``
    # because it does no feature resolution, so a crate with default
    # features would compile with them off. Any feature or optional
    # dependency anywhere sends the whole workspace to Mode B, where
    # cargo resolves them.
    if project.hasFeatures:
      return rustCrudeFallback(projectRoot, request)
    # Rust.md §"Recognition" item 6 and §"Test commands": a target with
    # ``harness = false`` is tested by running its own ``main``. Mode A
    # builds a ``[[test]]`` it can name that way without ``--test``
    # (``RustTarget.noHarness``); a setting it cannot attribute would leave
    # some target compiled with ``--test``, whose libtest runner reports
    # "running 0 tests" and passes whatever the body does, so cargo builds
    # that workspace (Mode B).
    if project.harnessUnattributed:
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
      # ``[lib]+[[bin]]`` case, which Cargo's default ``src/lib.rs`` plus
      # ``src/main.rs`` layout produces).
      var libActionsByPackage = initTable[string, TargetActions]()
        ## package name → its first lib-flavoured target's actions
        ## (the only one a same-package bin or a workspace consumer can
        ## reference by the ``crate-name`` convention). Only entries
        ## whose lib has a real rlib (i.e. ``rtkLibrary``) are usable as
        ## ``--extern`` sources — cdylib/staticlib/dylib still land here
        ## for diagnostic completeness but their ``rlibPath`` is empty.
      var allActions: seq[BuildActionDef] = @[]
      var testActions: seq[BuildActionDef] = @[]
        ## Every action of the non-default ``test`` target: the test
        ## crates of libraries and binaries (Passes A and B) and of
        ## integration tests (Pass C).
      var binActionsByPackage =
        initTable[string, seq[(RustTarget, TargetActions)]]()
        ## package name → its binaries' actions, for the
        ## ``CARGO_BIN_EXE_<name>`` of the package's integration tests.

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
          metadataExterns.add("--extern")
          metadataExterns.add(depActions.crateName & "=" & depActions.rmetaPath)
          linkExterns.add("--extern")
          linkExterns.add(depActions.crateName & "=" & depActions.rlibPath)
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
            inputRlibs = inputRlibs,
            crateEnv = targetCrateEnv(pkg, t, cargoExe))
          allActions.add(actions.metadataAction)
          allActions.add(actions.linkAction)
          discard target(libraryTargetName(pkg, t),
            @[actions.metadataAction, actions.linkAction])
          if t.unitTests:
            # The library's own ``#[cfg(test)]`` tests: the same crate
            # root with the same dependencies as its link action.
            let unit = emitForUnitTestTarget(
              projectRoot = projectRoot,
              rustcExe = rustcExe,
              target = t,
              pkg = pkg,
              packageCrateName = normaliseCrateName(pkg.packageName),
              linkExterns = linkExterns,
              externDepIds = externDepIds,
              inputRlibs = inputRlibs,
              cargoExe = cargoExe)
            testActions.add(unit.compileAction)
            testActions.add(unit.runAction)
            testActions.add(unit.stampAction)
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
          # Cargo's extern name = the lib target's crate name.
          metadataExterns.add("--extern")
          metadataExterns.add(depActions.crateName & "=" & depActions.rmetaPath)
          linkExterns.add("--extern")
          linkExterns.add(depActions.crateName & "=" & depActions.rlibPath)
          if depActions.metadataAction.id notin externDepIds:
            externDepIds.add(depActions.metadataAction.id)
          if depActions.linkAction.id notin externDepIds:
            externDepIds.add(depActions.linkAction.id)
          inputRmetas.add(depActions.rmetaPath)
          inputRlibs.add(depActions.rlibPath)
        # The package's own library. Cargo passes each binary of a package
        # ``--extern <lib>=<the lib's rlib>`` (Cargo reference, "Cargo
        # Targets", "Binaries": a binary "can use the public API of the
        # package's library":
        # https://doc.rust-lang.org/cargo/reference/cargo-targets.html#binaries).
        # The package-level dependency graph walked above does not list
        # this edge, so it is added here. The binary has no metadata pass,
        # so the rlib alone is passed, and its link action is the one dep.
        if pkg.packageName in libActionsByPackage:
          let ownLib = libActionsByPackage[pkg.packageName]
          if ownLib.rlibPath.len > 0:
            linkExterns.add("--extern")
            linkExterns.add(ownLib.crateName & "=" & ownLib.rlibPath)
            if ownLib.linkAction.id notin externDepIds:
              externDepIds.add(ownLib.linkAction.id)
            inputRlibs.add(ownLib.rlibPath)
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
            inputRlibs = inputRlibs,
            crateEnv = targetCrateEnv(pkg, t, cargoExe))
          allActions.add(actions.linkAction)
          discard target(t.crateName, @[actions.linkAction])
          binActionsByPackage.mgetOrPut(pkg.packageName, @[]).add((t, actions))
          if t.unitTests:
            # The binary's own ``#[cfg(test)]`` tests, with the binary's
            # dependencies (its own package's library included).
            let unit = emitForUnitTestTarget(
              projectRoot = projectRoot,
              rustcExe = rustcExe,
              target = t,
              pkg = pkg,
              packageCrateName = normaliseCrateName(pkg.packageName),
              linkExterns = linkExterns,
              externDepIds = externDepIds,
              inputRlibs = inputRlibs,
              cargoExe = cargoExe)
            testActions.add(unit.compileAction)
            testActions.add(unit.runAction)
            testActions.add(unit.stampAction)
      if allActions.len == 0:
        raise newException(ValueError,
          "rust convention: no bin or lib targets found across " &
            $project.packages.len & " package(s) under " & projectRoot)
      defaultTarget(target("default", allActions))

      # Pass C (M22): integration tests under ``tests/<name>.rs``. Per
      # cargo metadata's ``kind=["test"]`` filter; each becomes a
      # ``rustc --test`` compile + a run action that fires the harness.
      # The test crates of libraries' and binaries' own ``#[cfg(test)]``
      # code were added to ``testActions`` in Passes A and B.
      # The test target is non-default so ``repro build .#default``
      # stays bin/lib-only; ``repro build .#test`` opts in. Tests need
      # the package's primary lib target as the ``--extern`` source —
      # without it the test couldn't ``use <crate>::...``; we skip
      # tests for packages without a lib target.
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
          if t.kind != rtkIntegrationTest or not t.unitTests:
            # ``test = false``: ``cargo test`` neither builds nor runs it.
            continue
          let pair = emitForTestTarget(
            projectRoot = projectRoot,
            rustcExe = rustcExe,
            test = t,
            pkg = pkg,
            packageCrateName = packageCrateName,
            libActions = libActions,
            binActions = binActionsByPackage.getOrDefault(pkg.packageName),
            cargoExe = cargoExe)
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
