## Go language convention (Tier 2b) — Mode A "fine-grained" plugin.
##
## Recognises a single-module Go project whose ``reprobuild.nim`` declares
## ``uses:`` containing ``go`` AND ships a conventional Go layout
## (``go.mod`` at the project root plus at least one of: a root
## ``main.go``, one or more ``cmd/<name>/main.go`` files, or a non-main
## library package somewhere in the module) AND has *no* CGO triggers
## (no ``import "C"`` lines anywhere and no ``_cgo_*.go`` files in the
## source tree) AND no ``go.work`` (workspaces are deferred). The
## convention spec
## (``reprobuild-specs/Language-Conventions/Go.md`` §"Mode A — Fine-grained
## build graph") prescribes:
##
##   Per project (non-stdlib) package P:
##     ``go tool compile
##         -p <importPath>
##         -lang=goX.Y
##         -complete
##         -importcfg <P>/importcfg
##         -pack
##         -o <P>.a
##         <P>'s .go source files``
##     produces ``<P>.a`` (a Go package archive).
##
##   Per binary:
##     ``go tool link -importcfg <main>/importcfg.link -buildmode=exe
##         -o <bin> <main>.a``
##     produces the final executable.
##
## Each per-package ``importcfg`` is itself a tiny ``fs.writeText`` action
## whose text is a list of ``packagefile <importPath>=<archivePath>``
## directives — one for every package imported by P (direct imports only;
## the link-time ``importcfg.link`` carries the full transitive set).
##
## **Design decision (M5 Option 1 — eager + M18 fingerprint cache).** Like
## the M3 Nim and M4 Rust conventions, this plugin invokes the upstream
## tooling eagerly at emit time, then layers an emit-time fingerprint
## sidecar (see ``conventions/emit_cache.nim``) on top so the upstream
## call doesn't fire on every ``repro build``:
##
##   * ``runGoListExport`` hashes every ``go.mod``/``go.sum``/``.go`` file
##     under the project root + the ``go`` driver path, compares against
##     ``<projectRoot>/.repro/build/.emit-cache/go-list-export.repro-emit-fingerprint``,
##     and on a hit re-parses the persisted raw output instead of
##     re-spawning ``go list``.
##
## The eager-at-emit-time shape is preserved (the convention still
## produces a static graph from the parsed package list); only the
## subprocess invocation moves behind the cache. True Option 2 dyndep
## (where the engine synthesises per-package compile actions from a
## generator-produced fragment) is deferred to a follow-on milestone
## because the engine's current dyndep contract can only attach
## extra deps/outputs to actions that already exist.
##
## **Original-M5 eager rationale (preserved):**
##
##   * ``go list -export -json -deps ./...`` runs once per
##     ``emitFragment`` call. The ``-export`` flag is the key — it triggers
##     ``go`` to populate the standard library into ``GOCACHE`` *and*
##     reports the resulting archive path back via the ``Export`` field on
##     every package record. Without ``-export`` we'd be on the hook for
##     reproducing Go's content-addressed cache key derivation, which is
##     not what a single-language convention should be doing.
##
##   * The convention writes its own per-package ``importcfg`` files as
##     ``fs.writeText`` *generator actions* — they're cheap (a handful of
##     lines each) and they keep the convention free of stateful "did we
##     already write this on disk?" guesswork. The engine treats them like
##     any other action and reuses cached outputs on a no-op rebuild.
##
##   * Standard-library packages (``Standard: true`` in the ``go list``
##     output) are *not* re-compiled — the convention spec mandates
##     treating them as toolchain-provisioned inputs. We reference their
##     ``Export`` paths directly from the per-package ``importcfg`` files
##     and from the link-time ``importcfg.link``. Re-compiling stdlib
##     would mean ~270 packages per build, with no upside since the
##     toolchain already maintains them in ``GOCACHE``.
##
## The ``go list -export`` invocation is the same one a future Option 2
## (dyndep) lowering would emit at build time. The trade-off is identical
## to M3/M4: eager emit produces a static graph; dyndep would defer the
## walk to the engine and pay the cost only on go-source churn.
##
## **M14 extensions** over M5's root-``main.go``-only baseline:
##
##   * Multi-binary modules with ``cmd/<name>/main.go`` layouts. The
##     convention iterates every ``package main`` reported by ``go list``
##     and emits one (compile, link) pair per binary. Binary name is the
##     last path segment of the main package's import path
##     (``example.com/foo/cmd/alpha`` → ``alpha``); each link action drops
##     its executable under ``<scratch>/<project-entry>/bin/<bin>.exe``.
##   * Library-only modules (``go.mod`` + non-main packages, no
##     ``package main`` anywhere). The convention emits per-package
##     ``go tool compile`` actions producing ``.a`` archives but no link
##     action. The ``default`` target lists every compile action so
##     ``repro build .#default`` builds the entire module.
##
## **Out of scope for M14 (handled by ``recognize`` returning ``false``)**:
##
##   * ``go.work`` workspaces (per-member DAGs).
##   * CGO (``import "C"`` or ``_cgo_*.go``) — needs a C cross-toolchain
##     the standard provider doesn't provision; falls through to M6.
##   * Tests (``_test.go`` files) — the convention spec asks for a
##     per-package test binary, deferred to a later M.
##
## **Caveats**:
##   * Requires ``go`` on ``PATH`` at convention-emit time. When ``go`` is
##     missing, ``recognize`` returns ``false`` so dispatch falls through
##     to the "no convention matched" diagnostic with the regular project
##     hint.
##   * ``go.mod``'s ``go`` directive is consulted only for the ``-lang=``
##     flag value passed to ``go tool compile``; the convention does not
##     enforce a minimum Go toolchain version on its own (the ``uses:``
##     constraint in ``reprobuild.nim`` is the authoritative pin).
##   * The compile/link uses ``go tool compile`` / ``go tool link`` via
##     the ``go`` driver itself. That guarantees the tool path matches the
##     active toolchain without us hard-coding ``$(go env GOTOOLDIR)``
##     into the action argv.

import std/[algorithm, json, os, osproc, strutils]

import repro_core
import repro_provider_runtime
import repro_project_dsl
import repro_standard_provider/convention
import repro_standard_provider/conventions/emit_cache

const
  ScratchDirName* = ".repro/build"
    ## Top-level scratch directory under the project root the Go
    ## convention writes into. Same const value used by the Nim and Rust
    ## conventions — every language convention owns a per-entry
    ## subdirectory under this prefix.

type
  GoPackage = object
    ## One record from ``go list -json -deps`` reduced to the fields the
    ## convention needs.
    importPath: string
      ## ``Module/Path`` style fully-qualified import path
      ## (``example.com/foo/bar``) or stdlib short path (``fmt``).
    name: string
      ## ``main`` for the entry-point package, otherwise the bare package
      ## name (``foo`` for ``example.com/foo``).
    dir: string
      ## Absolute path to the directory containing the package's source.
    standard: bool
      ## ``true`` for stdlib packages — we never compile these ourselves.
    goFiles: seq[string]
      ## Source ``.go`` files (excludes ``_test.go``). Listed by name only
      ## relative to ``dir`` per ``go list``'s output.
    imports: seq[string]
      ## Direct ``import "..."`` strings. Used to derive the per-package
      ## ``importcfg``.
    exportArchive: string
      ## Absolute path to the package archive ``go`` knows about. For
      ## stdlib packages this is a GOCACHE entry; for project packages we
      ## ignore this field and emit our own compile action with our own
      ## output path.

  GoModuleInfo = object
    ## ``go.mod`` essentials for the ``-lang=`` flag.
    goVersion: string
      ## ``go.mod``'s ``go`` directive value (``1.22``). Defaults to
      ## ``1.22`` when absent — Go's own behaviour.
    modulePath: string
      ## ``go.mod``'s ``module`` directive value
      ## (``example.com/foo``). Empty when the directive is missing —
      ## ``go list`` would have already failed in that case so the empty
      ## fallback is defensive only.

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

proc usesIncludesGo(source: string): bool =
  ## True when the ``uses:`` block names ``go``. Mirrors the Rust
  ## convention's ``usesIncludesRustOrCargo`` line-scan — diagnostic-grade,
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
          if firstToken == "go":
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
          if firstToken == "go":
            return true
  false

proc projectGoFilesHaveCgo(projectRoot: string): bool =
  ## Scan every ``.go`` file under ``projectRoot`` for either:
  ##   * an ``import "C"`` line (cgo trigger), or
  ##   * a ``_cgo_*.go`` filename (cgo-generated source)
  ## Returns ``true`` on the first hit. Conservative: any read error
  ## treats the offending file as "no cgo" so other files still get
  ## scanned. The convention spec (Go.md §"Recognition" #4) is explicit
  ## that cgo anywhere in the module forces Mode B.
  if not dirExists(extendedPath(projectRoot)):
    return false
  for entry in walkDirRec(projectRoot):
    let lower = entry.toLowerAscii
    if not lower.endsWith(".go"):
      continue
    let filename = extractFilename(entry)
    if filename.toLowerAscii.startsWith("_cgo_") and lower.endsWith(".go"):
      return true
    # ``import "C"`` is a Go-syntax line; the recognition spec only
    # requires a heuristic scan (M5 won't accept cgo regardless of how
    # creatively it's spelled). A simple line-by-line check covers the
    # ``import "C"`` and ``import \"C\"`` forms; multi-line ``import (\n
    # "C"\n)`` blocks are caught by the bare-``"C"`` line.
    var content: string
    try:
      content = readFile(extendedPath(entry))
    except CatchableError:
      continue
    for rawLine in content.splitLines():
      var line = rawLine
      let commentIdx = line.find("//")
      if commentIdx >= 0:
        line = line[0 ..< commentIdx]
      let stripped = line.strip()
      # Single-line: ``import "C"``
      if stripped == "import \"C\"":
        return true
      # Inside an import (...) block: a lone ``"C"`` line is the cgo
      # trigger. Match either ``"C"`` or ``_ "C"`` (blank import) or
      # ``name "C"`` (renamed import — unusual for "C" but legal Go).
      if stripped == "\"C\"":
        return true
      if stripped.endsWith(" \"C\"") and not stripped.startsWith("import"):
        # ``_ "C"`` or ``ignored "C"`` inside an import block.
        return true
  false

proc goExecutable(): string =
  findExe("go")

proc hasRootMainGo(projectRoot: string): bool =
  ## True when ``<projectRoot>/main.go`` exists.
  fileExists(extendedPath(projectRoot / "main.go"))

proc hasCmdMainGo(projectRoot: string): bool =
  ## True when at least one ``<projectRoot>/cmd/<name>/main.go`` exists.
  ## Used by recognise to accept the canonical Go multi-binary layout
  ## without paying for a ``go list`` run. We probe only one level under
  ## ``cmd/`` — that's the Go community convention (sub-commands live in
  ## ``cmd/<name>/``, not deeper).
  let cmdDir = projectRoot / "cmd"
  if not dirExists(extendedPath(cmdDir)):
    return false
  for kind, path in walkDir(cmdDir):
    if kind != pcDir:
      continue
    if fileExists(extendedPath(path / "main.go")):
      return true
  false

proc hasAnyNonTestGoFile(projectRoot: string): bool =
  ## True when ANY ``.go`` file exists somewhere under ``projectRoot``
  ## (excluding ``_test.go`` files). Library-only modules don't carry a
  ## ``main.go`` anywhere — they're just one or more ``package <name>``
  ## files. We accept any non-test ``.go`` under the tree as evidence the
  ## module has compilable content so ``go list`` can derive the graph.
  if not dirExists(extendedPath(projectRoot)):
    return false
  for entry in walkDirRec(projectRoot):
    let lower = entry.toLowerAscii
    if not lower.endsWith(".go"):
      continue
    if extractFilename(entry).toLowerAscii.endsWith("_test.go"):
      continue
    return true
  false

proc goRecognize(projectRoot: string;
                 request: ProviderGraphRequest): bool {.gcsafe.} =
  ## Recognition contract (M14):
  ##   * ``<projectRoot>/go.mod`` exists
  ##   * ``<projectRoot>/reprobuild.nim`` mentions ``go`` in ``uses:``
  ##   * at least ONE of:
  ##       - ``<projectRoot>/main.go`` exists (root-binary layout), OR
  ##       - at least one ``<projectRoot>/cmd/<name>/main.go`` exists
  ##         (canonical Go multi-binary layout), OR
  ##       - any non-test ``.go`` file exists somewhere under
  ##         ``<projectRoot>`` (library-only module — non-main packages).
  ##   * no ``import "C"`` line and no ``_cgo_*.go`` file anywhere under
  ##     ``projectRoot`` (cgo forces Mode B — M6)
  ##   * ``<projectRoot>/go.work`` does NOT exist (workspaces deferred)
  ##   * ``go`` is on PATH (so emit can run ``go list``)
  if not fileExists(extendedPath(projectRoot / "go.mod")):
    return false
  let source = readReprobuildSource(projectRoot)
  if source.len == 0:
    return false
  if not usesIncludesGo(source):
    return false
  if fileExists(extendedPath(projectRoot / "go.work")):
    return false
  if (not hasRootMainGo(projectRoot)) and
     (not hasCmdMainGo(projectRoot)) and
     (not hasAnyNonTestGoFile(projectRoot)):
    return false
  if projectGoFilesHaveCgo(projectRoot):
    return false
  if goExecutable().len == 0:
    return false
  true

proc parseGoMod(projectRoot: string): GoModuleInfo =
  ## Best-effort line-scan for ``go.mod``'s ``go`` directive and
  ## ``module`` directive. ``go list`` is the authoritative source for
  ## the module path (it carries each package's full import path) but
  ## we read ``module`` here too so library-only modules — where no
  ## main package's import path can stand in for the module name — can
  ## still derive a scratch-dir entry name.
  result.goVersion = "1.22"
  let modPath = projectRoot / "go.mod"
  if not fileExists(extendedPath(modPath)):
    return
  var content: string
  try:
    content = readFile(extendedPath(modPath))
  except CatchableError:
    return
  for rawLine in content.splitLines():
    let stripped = rawLine.strip()
    if stripped.startsWith("go "):
      let payload = stripped[3 .. ^1].strip()
      if payload.len > 0:
        result.goVersion = payload
    elif stripped.startsWith("module "):
      let payload = stripped[7 .. ^1].strip().strip(chars = {'"', '\'',
        ' ', '\t'})
      if payload.len > 0:
        result.modulePath = payload

proc splitJsonObjects(blob: string): seq[JsonNode] =
  ## ``go list -json`` emits one JSON object per package, concatenated
  ## without any wrapping array — they're newline-separated by convention
  ## but ``parseJson`` only consumes the first one. Loop the JSON
  ## fragments by tracking nested brace depth, skipping over strings.
  var depth = 0
  var startIdx = -1
  var i = 0
  var inString = false
  var escape = false
  while i < blob.len:
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
          let fragment = blob[startIdx .. i]
          try:
            result.add(parseJson(fragment))
          except CatchableError:
            discard
          startIdx = -1
      else:
        discard
    inc i

const
  GoEmitCacheBaseName = "go-list-export"
    ## Sidecar file basename for the M18 emit-time fingerprint cache.
  GoEmitCacheOutputName = "go-list-export.cached.json"
    ## Cached raw ``go list -export -json -deps ./...`` output. Lives
    ## next to the fingerprint sidecar.

proc goEmitCacheScratchDir(projectRoot: string): string =
  ## Per-project emit-cache scratch — same shape as the Rust convention.
  projectRoot / ScratchDirName / ".emit-cache"

proc collectGoInputs(projectRoot: string): seq[string] =
  ## Every input file ``go list`` could possibly inspect on this
  ## project: ``go.mod``, ``go.sum``, every ``.go`` file (recursively),
  ## skipping ``.repro/`` scratch + any ``vendor/`` tree (vendor is
  ## immutable cargo-cult input, but folding it in is correct — a
  ## ``vendor/`` edit IS a real input change, just rare in practice).
  ## We DO skip the obvious "build scratch" dirs the convention itself
  ## owns so we don't get fingerprint feedback loops.
  if not dirExists(extendedPath(projectRoot)):
    return @[]
  for entry in walkDirRec(projectRoot, yieldFilter = {pcFile}):
    let rel = entry.relativePath(projectRoot)
    let lowered = rel.replace('\\', '/').toLowerAscii
    if lowered.startsWith(".repro/"):
      continue
    let basename = extractFilename(entry).toLowerAscii
    let ext = splitFile(entry).ext.toLowerAscii
    if basename == "go.mod" or basename == "go.sum" or ext == ".go":
      result.add(entry)
  result.sort(system.cmp[string])

proc goEmitCacheFingerprint(projectRoot, goExe: string;
                            sources: openArray[string]): string =
  ## Fingerprint key for the go-list-export cache. See the analogous
  ## comment in ``nim.nim``/``rust.nim`` for the rationale.
  var inputs: seq[EmitCacheInput] = @[
    textInput("go-exe:" & goExe),
    textInput("project-root:" & projectRoot),
    textInput("cmd:go list -export -json -deps ./..."),
  ]
  for source in sources:
    inputs.add(fileInput(source))
  computeEmitCacheFingerprint(inputs)

proc parseGoListExportOutput(output: string): seq[GoPackage] =
  ## Decode the raw ``go list -export -json -deps ./...`` text into the
  ## convention's reduced-shape ``GoPackage`` records. Pulled out of
  ## ``runGoListExport`` so the M18 cache-hit path can re-parse the
  ## persisted output without copy-pasting the JSON shape.
  for node in splitJsonObjects(output):
    if node.kind != JObject:
      continue
    var pkg = GoPackage()
    if "ImportPath" in node:
      pkg.importPath = node["ImportPath"].getStr()
    if pkg.importPath.len == 0:
      continue
    if "Name" in node:
      pkg.name = node["Name"].getStr()
    if "Dir" in node:
      pkg.dir = node["Dir"].getStr()
    if "Standard" in node:
      pkg.standard = node["Standard"].getBool()
    if "Export" in node:
      pkg.exportArchive = node["Export"].getStr()
    if "GoFiles" in node and node["GoFiles"].kind == JArray:
      for item in node["GoFiles"]:
        pkg.goFiles.add(item.getStr())
    if "Imports" in node and node["Imports"].kind == JArray:
      for item in node["Imports"]:
        pkg.imports.add(item.getStr())
    result.add(pkg)

proc runGoListExport(projectRoot, goExe: string): seq[GoPackage] =
  ## Execute ``go list -export -json -deps ./...`` and parse the
  ## resulting concatenated-JSON output. ``-export`` triggers the Go
  ## toolchain to populate ``GOCACHE`` with stdlib archives and report
  ## the cache paths via the ``Export`` field.
  ##
  ## The output is large (~100 KB for a "hello world" — every transitive
  ## stdlib package gets a JSON record). On Windows the default pipe
  ## buffer is ~64 KB so the naïve ``readAll`` pattern that works for
  ## ``cargo metadata`` (a few KB) deadlocks here: Go fills the pipe
  ## faster than we drain it. ``execCmdEx`` reads stdout line-by-line
  ## while polling the exit code, which is exactly the drain pattern we
  ## need. ``poStdErrToStdOut`` merges any progress chatter Go writes
  ## (e.g. ``# downloading``) into the captured output, which becomes
  ## the diagnostic on exit-code != 0.
  ##
  ## **M18 emit-cache fast path**: hash every ``go.mod``/``go.sum``/``.go``
  ## file under the project root and, when the fingerprint matches a
  ## sidecar AND a cached output is on disk, re-parse the cached output
  ## instead of re-spawning ``go list``. The headline win isn't ``go
  ## list``'s wall-time (~200-400 ms) — it's that the convention's emit
  ## becomes purely on-disk I/O when nothing has changed.
  let scratchDir = goEmitCacheScratchDir(projectRoot)
  let sources = collectGoInputs(projectRoot)
  let fingerprint = goEmitCacheFingerprint(projectRoot, goExe, sources)
  let cachedOutputPath = scratchDir / GoEmitCacheOutputName
  if emitCacheIsUsable(scratchDir, GoEmitCacheBaseName, fingerprint,
      [cachedOutputPath]):
    try:
      let cached = readFile(extendedPath(cachedOutputPath))
      let parsed = parseGoListExportOutput(cached)
      if parsed.len > 0:
        return parsed
    except CatchableError:
      # Stale cache — fall through to the subprocess.
      discard
  let argv = @[
    goExe,
    "list",
    "-export",
    "-json",
    "-deps",
    "./...",
  ]
  let cmd = quoteShellCommand(argv)
  let (output, exitCode) = execCmdEx(cmd,
    options = {poStdErrToStdOut, poUsePath},
    workingDir = projectRoot)
  if exitCode != 0:
    raise newException(ValueError,
      "go convention: 'go list -export -json -deps ./...' exited " &
        $exitCode & " for " & projectRoot & ":\n" & output)
  result = parseGoListExportOutput(output)
  # Persist the cache. As with the Rust path, write the output BEFORE
  # the fingerprint so a partial-write crash leaves the sidecar
  # mismatched (which is correct — a miss) rather than matched-but-
  # stale.
  try:
    createDir(extendedPath(scratchDir))
    writeFile(extendedPath(cachedOutputPath), output)
    writeEmitCacheFingerprint(scratchDir, GoEmitCacheBaseName, fingerprint)
  except CatchableError:
    discard

proc sanitizeImportPath(importPath: string): string =
  ## Map a Go import path (``example.com/foo/bar``) to a filesystem-safe
  ## action-id / scratch-dir segment. Slashes become ``__``; everything
  ## outside ``[A-Za-z0-9_.-]`` becomes ``_``.
  for ch in importPath:
    case ch
    of 'a' .. 'z', 'A' .. 'Z', '0' .. '9', '-', '_', '.':
      result.add(ch)
    of '/':
      result.add("__")
    else:
      result.add('_')
  if result.len == 0:
    result = "x"

proc stableHashHex(value: string): string =
  ## FNV-1a 64-bit hash, hex-encoded. Same algorithm as the Rust
  ## convention's ``stableHashHex`` — kept identical so future
  ## cross-checks line up.
  var hash = 0xcbf29ce484222325'u64
  for ch in value:
    hash = hash xor uint64(ord(ch))
    hash = hash * 0x100000001b3'u64
  hash.toHex(16).toLowerAscii()

proc scratchPathFor(projectRoot, projectEntry: string): string =
  projectRoot / ScratchDirName / projectEntry

proc archivePathFor(projectRoot, projectEntry, importPath: string): string =
  scratchPathFor(projectRoot, projectEntry) / "pkg" /
    (sanitizeImportPath(importPath) & ".a")

proc importcfgPathFor(projectRoot, projectEntry, importPath: string): string =
  scratchPathFor(projectRoot, projectEntry) / "pkg" /
    (sanitizeImportPath(importPath) & ".importcfg")

proc linkImportcfgPathFor(projectRoot, projectEntry: string): string =
  ## Pre-M14 link importcfg path — kept as the single-binary default for
  ## backwards-compat with any caller probing the old name.
  scratchPathFor(projectRoot, projectEntry) / "importcfg.link"

proc linkImportcfgPathForBinary(projectRoot, projectEntry,
                                binaryName: string): string =
  ## M14: per-binary link importcfg path. Each main package gets its own
  ## ``importcfg.link`` because the link argv references it positionally,
  ## and two main packages in the same module could otherwise stomp each
  ## other when their compile-deps closure differs (it doesn't today —
  ## the closure is module-wide — but keeping per-binary keeps the action
  ## fingerprint correctly partitioned).
  scratchPathFor(projectRoot, projectEntry) /
    (binaryName & ".importcfg.link")

proc binaryPathFor(projectRoot, projectEntry: string): string =
  ## Pre-M14 single-binary helper. Retained for the single-main fixture
  ## that names its binary after the project entry; new call sites should
  ## prefer ``binaryPathForName`` below so the binary name comes from the
  ## main package's import path.
  when defined(windows):
    scratchPathFor(projectRoot, projectEntry) / "bin" /
      (projectEntry & ".exe")
  else:
    scratchPathFor(projectRoot, projectEntry) / "bin" / projectEntry

proc binaryPathForName(projectRoot, projectEntry,
                       binaryName: string): string =
  ## M14: a main package's binary path under the project's scratch dir.
  ## All binaries from the same module share ``<scratch>/<projectEntry>/bin/``;
  ## the per-binary basename is the last path segment of the main
  ## package's import path (Go's own ``go build`` convention).
  when defined(windows):
    scratchPathFor(projectRoot, projectEntry) / "bin" /
      (binaryName & ".exe")
  else:
    scratchPathFor(projectRoot, projectEntry) / "bin" / binaryName

proc actionIdFor(prefix, projectEntry, importPath: string): string =
  ## Build a Reprobuild-safe action id keyed on the import path. Matches
  ## the shape used by ``nim.nim`` / ``rust.nim`` so ``--log=actions``
  ## output is uniform across conventions.
  let sanitized = sanitizeImportPath(importPath)
  let hashSuffix = stableHashHex(importPath)[0 .. 7]
  prefix & "-" & projectEntry & "-" & sanitized & "-" & hashSuffix

proc collectGoSources(pkg: GoPackage): seq[string] =
  ## Resolve ``pkg.goFiles`` (which ``go list`` reports relative to
  ## ``pkg.dir``) to absolute paths. ``walkDir`` would also work but
  ## ``goFiles`` already excludes ``_test.go`` and obeys build tags, so
  ## prefer the authoritative list.
  for relative in pkg.goFiles:
    result.add(pkg.dir / relative)
  result.sort(system.cmp[string])

proc renderImportcfg(packages: openArray[GoPackage];
                     imports: openArray[string];
                     projectRoot, projectEntry: string): string =
  ## Build a ``packagefile <importPath>=<archive>`` listing for a single
  ## package's ``importcfg``. Each direct import maps to either:
  ##   * a stdlib package's ``Export`` archive (GOCACHE entry), or
  ##   * a project package's archive path under our scratch tree.
  ## The first line is a literal ``# import config`` comment (Go's own
  ## driver emits this header and the spec section 4 §"importcfg" lists
  ## it as the conventional preamble — purely informational, ``go tool``
  ## accepts files without it).
  result.add("# import config\n")
  for importPath in imports:
    var found = false
    for pkg in packages:
      if pkg.importPath != importPath:
        continue
      found = true
      if pkg.standard:
        if pkg.exportArchive.len == 0:
          # Stdlib packages with no Export (e.g. ``unsafe``) carry no
          # archive at all — they're handled at compile-tool level via
          # ``-complete`` and the Go compiler intrinsically.
          break
        result.add("packagefile " & importPath & "=" & pkg.exportArchive &
          "\n")
      else:
        result.add("packagefile " & importPath & "=" &
          archivePathFor(projectRoot, projectEntry, importPath) & "\n")
      break

proc renderLinkImportcfg(packages: seq[GoPackage]; mainImportPath,
                        projectRoot, projectEntry: string): string =
  ## Build the link-time ``importcfg.link`` — a *superset* of any single
  ## package's ``importcfg``. Per Go.md §"Per-binary link argv", the
  ## linker needs every transitive dependency's archive listed (not just
  ## direct imports). Our seq of GoPackages from ``go list -deps`` is
  ## already the transitive closure for the main module.
  result.add("# import config\n")
  for pkg in packages:
    if pkg.standard:
      if pkg.exportArchive.len == 0:
        continue
      result.add("packagefile " & pkg.importPath & "=" & pkg.exportArchive &
        "\n")
    else:
      result.add("packagefile " & pkg.importPath & "=" &
        archivePathFor(projectRoot, projectEntry, pkg.importPath) & "\n")
  # Make sure the main package itself is in there — go list -deps lists
  # the dependency closure including the root, so the loop above already
  # covered it via the non-standard branch. Belt-and-braces: if the main
  # somehow wasn't in the loop (e.g. listed but Standard=false yet
  # filtered by some future refactor), add it.
  if mainImportPath.len > 0:
    var alreadyListed = false
    for pkg in packages:
      if not pkg.standard and pkg.importPath == mainImportPath:
        alreadyListed = true
        break
    if not alreadyListed:
      result.add("packagefile " & mainImportPath & "=" &
        archivePathFor(projectRoot, projectEntry, mainImportPath) & "\n")

proc collectAllProjectGoSources(projectRoot: string): seq[string] =
  ## Every ``.go`` file under ``projectRoot`` (excluding ``_test.go``).
  ## Used to roll the "is anything stale?" decision for the umbrella
  ## ``go list`` action — its declared inputs trigger a re-listing
  ## whenever the source layout changes.
  for entry in walkDirRec(projectRoot):
    let lower = entry.toLowerAscii
    if not lower.endsWith(".go"):
      continue
    if extractFilename(entry).toLowerAscii.endsWith("_test.go"):
      continue
    result.add(entry)
  result.sort(system.cmp[string])

type
  GoCompileAction = object
    action: BuildActionDef
    importPath: string
    archivePath: string

proc emitCompileAction(projectRoot, projectEntry, goExe: string;
                      module: GoModuleInfo;
                      pkg: GoPackage;
                      importcfgPath: string;
                      importcfgActionId: string): GoCompileAction =
  ## Emit a single per-package ``go tool compile`` action. Inputs are the
  ## package's ``.go`` files plus the importcfg the previous action just
  ## wrote. Outputs are the package archive.
  let archive = archivePathFor(projectRoot, projectEntry, pkg.importPath)
  let archiveDir = parentDir(archive)
  createDir(extendedPath(archiveDir))
  let sourceFiles = collectGoSources(pkg)

  # ``-p`` is the *symbol-table* identifier the compiler bakes into the
  # archive. For ``package main`` Go's own driver passes ``-p main`` (the
  # bare package name); for every other package it passes the full
  # import path. The link step then resolves archives via the
  # ``packagefile <importPath>=<path>`` lines in ``importcfg.link`` —
  # the bare ``main`` only shows up in the archive's metadata so the
  # runtime can find ``main.main`` at link time. Getting this wrong
  # produces a confusing ``function main is undeclared in the main
  # package`` link error.
  let pFlag =
    if pkg.name == "main": "main"
    else: pkg.importPath
  var argv = @[
    goExe,
    "tool",
    "compile",
    "-p", pFlag,
    "-lang=go" & module.goVersion,
  ]
  # ``-complete`` tells the compiler not to look for missing function
  # bodies in assembly. Safe for any package that has no ``.s`` files;
  # ``go list`` exposes ``SFiles`` for that but we don't currently use
  # it — stdlib-only deps + project packages without assembly cover the
  # M5 fixture set. If a project package has assembly, the compile will
  # fail loudly and the user gets a clear "missing function body" error.
  argv.add("-complete")
  argv.add("-importcfg")
  argv.add(importcfgPath)
  argv.add("-pack")
  argv.add("-o")
  argv.add(archive)
  for src in sourceFiles:
    argv.add(src)

  var inputs: seq[string] = @[importcfgPath]
  for src in sourceFiles:
    inputs.add(src)

  let action = buildAction(
    id = actionIdFor("go-compile", projectEntry, pkg.importPath),
    call = inlineExecCall(argv, projectRoot),
    deps = @[importcfgActionId],
    inputs = inputs,
    outputs = @[archive],
    pool = "compile",
    dependencyPolicy = declaredOnlyDependencyPolicy(),
    commandStatsId = "go.compile")
  GoCompileAction(
    action: action,
    importPath: pkg.importPath,
    archivePath: archive)

proc emitImportcfgAction(projectRoot, projectEntry: string;
                        pkg: GoPackage;
                        packages: seq[GoPackage]): tuple[action: BuildActionDef;
                                                          importcfgPath: string] =
  ## Emit an ``fs.writeText`` action that materialises a package's
  ## ``importcfg`` file. The text is fully resolved at emit time; the
  ## action exists purely to give the engine a place to track the file
  ## and re-create it after a clean checkout.
  let importcfgPath =
    importcfgPathFor(projectRoot, projectEntry, pkg.importPath)
  createDir(extendedPath(parentDir(importcfgPath)))
  let text = renderImportcfg(packages, pkg.imports, projectRoot,
    projectEntry)
  let action = fs.writeText(
    output = importcfgPath,
    text = text,
    actionId = actionIdFor("go-importcfg", projectEntry, pkg.importPath),
    commandStatsId = "go.importcfg")
  (action, importcfgPath)

proc emitLinkImportcfgAction(projectRoot, projectEntry: string;
                            mainImportPath, binaryName: string;
                            packages: seq[GoPackage]):
    tuple[action: BuildActionDef; path: string] =
  ## M14: per-binary importcfg.link. ``binaryName`` is the basename of
  ## the final executable (last path segment of ``mainImportPath``).
  let linkImportcfg =
    linkImportcfgPathForBinary(projectRoot, projectEntry, binaryName)
  createDir(extendedPath(parentDir(linkImportcfg)))
  let text = renderLinkImportcfg(packages, mainImportPath, projectRoot,
    projectEntry)
  let action = fs.writeText(
    output = linkImportcfg,
    text = text,
    actionId = actionIdFor("go-importcfg-link", projectEntry,
      mainImportPath),
    commandStatsId = "go.importcfg-link")
  (action, linkImportcfg)

proc emitLinkAction(projectRoot, projectEntry, goExe: string;
                   mainImportPath, binaryName: string;
                   compileActions: seq[GoCompileAction];
                   linkImportcfg: string;
                   linkImportcfgActionId: string): BuildActionDef =
  ## Final ``go tool link`` action for a single main package. Consumes:
  ##   * the main package's archive (positional),
  ##   * every other project package's archive (via importcfg.link),
  ##   * the link-time importcfg.
  ## Produces the final executable under ``<scratch>/<entry>/bin/``.
  ## ``binaryName`` controls the output basename so multi-binary modules
  ## that share one project-entry scratch dir produce distinct
  ## executables.
  let binaryOutput =
    binaryPathForName(projectRoot, projectEntry, binaryName)
  createDir(extendedPath(parentDir(binaryOutput)))
  var mainArchive = ""
  var compileActionIds: seq[string] = @[]
  var inputs: seq[string] = @[linkImportcfg]
  for ca in compileActions:
    compileActionIds.add(ca.action.id)
    inputs.add(ca.archivePath)
    if ca.importPath == mainImportPath:
      mainArchive = ca.archivePath
  if mainArchive.len == 0:
    raise newException(ValueError,
      "go convention: main package's compile action missing for " &
        mainImportPath)
  let argv = @[
    goExe,
    "tool",
    "link",
    "-importcfg", linkImportcfg,
    "-buildmode=exe",
    "-o", binaryOutput,
    mainArchive,
  ]
  var deps = compileActionIds
  deps.add(linkImportcfgActionId)
  buildAction(
    id = actionIdFor("go-link", projectEntry, mainImportPath),
    call = inlineExecCall(argv, projectRoot),
    deps = deps,
    inputs = inputs,
    outputs = @[binaryOutput],
    pool = "compile",
    dependencyPolicy = declaredOnlyDependencyPolicy(),
    commandStatsId = "go.link")

proc syntheticPackage(projectRoot, projectEntry: string): PackageDef =
  ## Build a minimal ``PackageDef`` for the runtime helper. Same shape
  ## used by the Nim and Rust conventions.
  PackageDef(
    packageName: projectEntry,
    sourceFile: projectRoot / "reprobuild.nim",
    hasDevEnv: false,
    devEnvBodyHash: "",
    toolUses: @[])

proc sanitizeBinaryName(name: string): string =
  ## Map a binary basename (a path segment like ``go-binary-example``,
  ## ``alpha``, ``cmd``) to the snake-case form the reprobuild DSL uses
  ## for ``executable`` member names — hyphens become underscores.
  ## Cargo's normaliseCrateName does the same thing.
  result = newStringOfCap(name.len)
  for ch in name:
    if ch == '-':
      result.add('_')
    else:
      result.add(ch)
  if result.len == 0:
    result = "go_binary"

proc binaryNameForMain(mainPkg: GoPackage): string =
  ## Go's own ``go build`` convention: the binary name is the last path
  ## segment of the main package's import path.
  ##   * ``example.com/go-binary-example`` → ``go-binary-example``
  ##   * ``example.com/foo/cmd/alpha``     → ``alpha``
  ##   * ``example.com/foo/cmd/beta``      → ``beta``
  ## We then snake-case the hyphen so the basename round-trips through
  ## the reprobuild DSL's executable-name normalisation
  ## (``executable go_binary_example`` declared in reprobuild.nim).
  let tail = mainPkg.importPath.split('/')[^1]
  sanitizeBinaryName(tail)

proc deriveProjectEntryFromModule(module: GoModuleInfo;
                                  projectRoot: string): string =
  ## Pick a stable filename-safe ``entry`` name for the module as a
  ## whole. Used as the scratch-dir prefix
  ## (``<scratch>/<projectEntry>/pkg/``) and as the synthetic
  ## ``PackageDef.packageName``. Library-only modules use this directly;
  ## binary-bearing modules also share one entry across all their main
  ## packages so they don't fragment the scratch tree.
  ##
  ## Priority:
  ##   1. ``go.mod``'s ``module`` directive last segment, snake-cased.
  ##   2. ``projectRoot`` basename, snake-cased (defensive fallback —
  ##      ``parseGoMod`` should always populate ``modulePath`` for any
  ##      project that passes recognise).
  if module.modulePath.len > 0:
    let tail = module.modulePath.split('/')[^1]
    return sanitizeBinaryName(tail)
  let rootBase = projectRoot.extractFilename
  if rootBase.len > 0:
    return sanitizeBinaryName(rootBase)
  "go_module"

proc collectMainPackages(packages: seq[GoPackage]): seq[GoPackage] =
  ## All ``package main`` entries reported by ``go list`` (excluding
  ## stdlib, which never carries a main).
  for pkg in packages:
    if pkg.standard:
      continue
    if pkg.name == "main":
      result.add(pkg)

proc goEmitFragment(projectRoot: string;
                    request: ProviderGraphRequest):
                      GraphFragment {.gcsafe.} =
  ## Convention entry — eagerly invoke ``go list -export -json -deps``,
  ## register the per-package importcfg, compile, link, and importcfg.link
  ## actions via the DSL, hand the whole thing to ``buildPackageFragment``.
  ##
  ## **M14 multi-target shape**:
  ##   1. ``go list -deps ./...`` enumerates every non-stdlib package in
  ##      the module. Each gets a per-package importcfg + ``go tool
  ##      compile`` action (producing ``<importPath>.a``).
  ##   2. Each ``package main`` additionally gets a per-binary
  ##      importcfg.link + ``go tool link`` action producing
  ##      ``<scratch>/<projectEntry>/bin/<binaryName>.exe`` where
  ##      ``binaryName`` is the last path segment of the main package's
  ##      import path (``cmd/alpha`` → ``alpha``, ``cmd/beta`` → ``beta``).
  ##   3. The ``default`` target lists every action so
  ##      ``repro build .#default`` builds everything. Each binary also
  ##      gets its own named target keyed on the binary name so
  ##      ``repro build .#alpha`` works.
  ##   4. Library-only modules (no ``package main`` anywhere) emit only
  ##      the per-package compile actions; the ``default`` target still
  ##      builds every package but no executable is produced.
  ##
  ## The DSL runtime mutates module-level registries that aren't annotated
  ## ``gcsafe`` (they predate the provider host). Same shape as the M3
  ## Nim / M4 Rust conventions' ``cast(gcsafe)`` escape hatch.
  {.cast(gcsafe).}:
    let goExe = goExecutable()
    if goExe.len == 0:
      raise newException(ValueError,
        "go convention: 'go' executable not on PATH; cannot run 'go list'")
    let module = parseGoMod(projectRoot)
    let packages = runGoListExport(projectRoot, goExe)
    if packages.len == 0:
      raise newException(ValueError,
        "go convention: 'go list' returned no packages for " & projectRoot)
    let mainPackages = collectMainPackages(packages)
    let projectEntry = deriveProjectEntryFromModule(module, projectRoot)
    let pkg = syntheticPackage(projectRoot, projectEntry)
    let registerAll = proc() =
      discard buildPool("compile", 8'u32)
      var compileActions: seq[GoCompileAction] = @[]
      var allActions: seq[BuildActionDef] = @[]
      # Pass 1: per-package compile + importcfg actions.
      # Skip stdlib (treated as toolchain-provisioned per Go.md §"Cross-
      # package ordering edges").
      for srcPkg in packages:
        if srcPkg.standard:
          continue
        let importcfgPair = emitImportcfgAction(projectRoot, projectEntry,
          srcPkg, packages)
        allActions.add(importcfgPair.action)
        let compileAction = emitCompileAction(projectRoot, projectEntry,
          goExe, module, srcPkg, importcfgPair.importcfgPath,
          importcfgPair.action.id)
        compileActions.add(compileAction)
        allActions.add(compileAction.action)
      # Pass 2: per-main-package link + importcfg.link actions.
      # Library-only modules skip this pass entirely.
      var registeredBinaryTargets: seq[string] = @[]
      for mainPkg in mainPackages:
        let binaryName = binaryNameForMain(mainPkg)
        let linkImportcfgPair = emitLinkImportcfgAction(projectRoot,
          projectEntry, mainPkg.importPath, binaryName, packages)
        allActions.add(linkImportcfgPair.action)
        let linkAction = emitLinkAction(projectRoot, projectEntry, goExe,
          mainPkg.importPath, binaryName, compileActions,
          linkImportcfgPair.path, linkImportcfgPair.action.id)
        allActions.add(linkAction)
        # Per-binary named target so ``repro build .#<binaryName>``
        # works. The umbrella ``default`` target below covers
        # ``repro build .#default``. Skip the per-binary alias when the
        # binary's name collides with the module-wide ``projectEntry``
        # alias we register below — single-binary modules whose main
        # package shares the module name's last segment (e.g.
        # ``example.com/go-binary-example``) would otherwise emit two
        # ``target("go_binary_example", ...)`` registrations and the
        # build engine flags the duplicate as a graph error. We register
        # the umbrella alias instead (it carries the link action
        # transitively).
        if binaryName != projectEntry:
          discard target(binaryName,
            @[linkImportcfgPair.action, linkAction])
          registeredBinaryTargets.add(binaryName)
      if allActions.len == 0:
        # Defensive: ``go list`` returned packages but they were all
        # stdlib. This shouldn't happen in practice (the user's own
        # ``go.mod`` ensures at least one project package) but a clear
        # error here beats a silent empty graph.
        raise newException(ValueError,
          "go convention: no project packages found in 'go list' output " &
            "for " & projectRoot &
            " (all reported packages are stdlib — check go.mod)")
      # Module-wide alias target so ``repro build .#<projectEntry>`` is
      # equivalent to building everything. Mirrors the M5 surface for
      # the single-binary case.
      discard target(projectEntry, allActions)
      defaultTarget(target("default", allActions))
    result = buildPackageFragment(pkg, request, registerAll,
      includeDefault = false)

proc goConvention*(): LanguageConvention =
  ## The single value the standard provider binary registers at startup.
  ## Same factory shape as ``nimConvention`` / ``rustConvention`` so
  ## tests can build isolated registries.
  LanguageConvention(
    name: "go",
    recognize: goRecognize,
    emitFragment: goEmitFragment)
