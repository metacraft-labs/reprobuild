## Go language convention (Tier 2b) — Mode A "fine-grained" plugin.
##
## Recognises a Go module or workspace whose ``reprobuild.nim`` declares
## ``uses:`` containing ``go`` AND ships a conventional Go layout
## (``go.mod`` or ``go.work`` at the project root plus at least one of: a
## root ``main.go``, one or more ``cmd/<name>/main.go`` files, or a non-main
## library package somewhere under the root) AND has *no* CGO triggers
## (no ``import "C"`` lines anywhere and no ``_cgo_*.go`` files in the
## source tree). The convention spec
## (``reprobuild-specs/Language-Conventions/Go.md`` §"Mode A — Fine-grained
## build graph") prescribes:
##
##   Per project (non-stdlib) package P:
##     ``go tool compile
##         -p <importPath>
##         -lang=goX.Y
##         -complete
##         -importcfg <P>/importcfg
##         [-embedcfg <P>/embedcfg]   # iff P has //go:embed patterns
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
## **Design decision (M5 Option 1 — eager, keyed on observed reads).** Like
## the M3 Nim and M4 Rust conventions, this plugin invokes the upstream
## tooling eagerly at emit time. Every field of the graph comes from the
## ``go list`` records (``Imports``/``ImportMap`` for the importcfg,
## ``EmbedPatterns``/``EmbedFiles`` for the embedcfg, ``Module.GoVersion``
## for ``-lang``), never from reading ``go.mod`` by hand. Its KEY is what the
## listing read (Go.md §"Implicit-dependency capture", item 3):
##
##   * ``runGoListing`` runs ``go list`` under io-mon's in-process host and
##     records every file read or probed and every directory enumerated —
##     ``go.mod``/``go.sum``/``go.work`` wherever they are, a ``replace``d
##     module's sources outside the project, the embed directories, the
##     standard-library export archives;
##   * those become the fragment's graph-evaluation inputs, so the engine
##     re-invokes the convention when any of them changes;
##   * the emit-time cache (``conventions/emit_cache.nim``) reuses the stored
##     output only while every recorded input is unchanged, instead of
##     hashing a hand-picked list of ``.go`` files.
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
##   * ``go list -export -json -deps <patterns>`` runs once per
##     ``emitFragment`` call, over the whole module or workspace (one DAG,
##     one version selection — Go.md §"Workspace and module mode"). The ``-export`` flag is the key — it triggers
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
##   * Each package's ``-lang=`` is its module's ``go`` version as ``go
##     list`` reports it (``Module.GoVersion``); the convention does not
##     enforce a minimum Go toolchain version on its own (the ``uses:``
##     constraint in ``reprobuild.nim`` is the authoritative pin).
##   * The listing needs the io monitor (``librepro_monitor_shim`` beside the
##     binaries); without it the convention refuses rather than emit a graph
##     it cannot key. A capture the monitor grades incomplete — on Linux
##     every run of a statically linked ``go``, which the preload monitor
##     cannot enter — keys nothing: the listing is re-run and the fragment
##     re-derived on every refresh.
##   * The compile/link uses ``go tool compile`` / ``go tool link`` via
##     the ``go`` driver itself. That guarantees the tool path matches the
##     active toolchain without us hard-coding ``$(go env GOTOOLDIR)``
##     into the action argv.

import std/[algorithm, json, os, strutils]

import repro_core
import repro_provider_runtime
import repro_project_dsl
import repro_standard_provider/convention
import repro_standard_provider/conventions/emit_cache
import repro_standard_provider/conventions/observed_reads
import repro_standard_provider/conventions/go_embed

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
    testGoFiles: seq[string]
      ## M22: ``_test.go`` files INSIDE the package's own ``package``
      ## declaration (white-box tests). Reported by ``go list``'s
      ## ``TestGoFiles`` field. Listed by name only relative to ``dir``.
    xTestGoFiles: seq[string]
      ## M22: ``_test.go`` files under ``package <name>_test`` (black-
      ## box tests) — same directory, different package declaration.
      ## Reported by ``go list``'s ``XTestGoFiles`` field. Listed by name
      ## only relative to ``dir``.
    imports: seq[string]
      ## ``go list``'s ``Imports``: the package's direct imports as RESOLVED
      ## import paths (after ``ImportMap``). Each names another record of the
      ## same listing; one ``packagefile`` line per entry.
    importMap: seq[(string, string)]
      ## ``go list``'s ``ImportMap``, source path -> resolved path, sorted by
      ## source path. One ``importmap`` line per entry (Go.md §"The importcfg
      ## file").
    embedPatterns: seq[string]
      ## ``go list``'s ``EmbedPatterns``: the patterns of the package's
      ## ``//go:embed`` directives, ``all:`` prefix included.
    embedFiles: seq[string]
      ## ``go list``'s ``EmbedFiles``: the union of the files those patterns
      ## resolve to, slash paths relative to ``dir``.
    modulePath: string
      ## ``Module.Path`` of the module that contains the package.
    moduleDir: string
      ## ``Module.Dir``.
    moduleMain: bool
      ## ``Module.Main``: the module is the main module or a workspace member.
    moduleGoVersion: string
      ## ``Module.GoVersion``; empty when the module declares no ``go``
      ## directive.
    hasModule: bool
      ## The record carried a ``Module`` object (every non-standard package
      ## does in module and workspace mode).
    exportArchive: string
      ## Absolute path to the package archive ``go`` knows about. For
      ## stdlib packages this is a GOCACHE entry; for project packages we
      ## ignore this field and emit our own compile action with our own
      ## output path.

  GoObservedInputs = ObservedReads
    ## What the io monitor observed the project's ``go list`` runs read:
    ## the graph's key (Go.md §"Implicit-dependency capture", item 3). On
    ## Linux every run of a statically linked ``go`` is graded incomplete (the
    ## preload monitor cannot enter it; reprobuild-pm issue
    ## 2026-10-08-frozen-wasm-static-go-monitor-incomplete), and then nothing
    ## derived from the listing is reused.

  GoListing = object
    ## The project's one ``go list`` (plus, in workspace mode, the
    ## ``go list -m`` that names its members), with what it read.
    packages: seq[GoPackage]
    observed: GoObservedInputs

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
  ## Recognition contract (M14, workspaces since the 2026-11-16 Go.md
  ## amendment):
  ##   * ``<projectRoot>/go.mod`` or ``<projectRoot>/go.work`` exists
  ##     (Go.md §"Recognition" 1; a ``go.work`` selects workspace mode)
  ##   * ``<projectRoot>/reprobuild.nim`` mentions ``go`` in ``uses:``
  ##   * at least ONE of:
  ##       - ``<projectRoot>/main.go`` exists (root-binary layout), OR
  ##       - at least one ``<projectRoot>/cmd/<name>/main.go`` exists
  ##         (canonical Go multi-binary layout), OR
  ##       - any non-test ``.go`` file exists somewhere under
  ##         ``<projectRoot>`` (library-only module — non-main packages).
  ##   * no ``import "C"`` line and no ``_cgo_*.go`` file anywhere under
  ##     ``projectRoot`` (cgo forces Mode B — M6)
  ##   * ``go`` is on PATH (so emit can run ``go list``)
  if not fileExists(extendedPath(projectRoot / "go.mod")) and
      not fileExists(extendedPath(projectRoot / "go.work")):
    return false
  let source = readReprobuildSource(projectRoot)
  if source.len == 0:
    return false
  if not usesIncludesGo(source):
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

proc splitJsonObjects(blob, context: string): seq[JsonNode] =
  ## ``go list -json`` emits one JSON object per package (or module),
  ## concatenated without a wrapping array; ``parseJson`` only consumes the
  ## first one. Loop the fragments by tracking nested brace depth, skipping
  ## over strings.
  ##
  ## A fragment that does not parse, or text outside the objects other than
  ## whitespace, is REFUSED rather than skipped: a listing with a package
  ## missing would emit a graph that silently lacks it. (On Windows the
  ## monitored run's stdout and stderr share one capture file, so a stray
  ## diagnostic line lands here and is reported instead of being mistaken for
  ## part of the listing.)
  var depth = 0
  var startIdx = -1
  var i = 0
  var inString = false
  var escape = false
  var stray = ""
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
          except CatchableError as e:
            raise newException(ValueError,
              "go convention: " & context & " printed an object that is not " &
                "JSON (" & e.msg & "):\n" & fragment)
          startIdx = -1
      else:
        if depth == 0 and ch notin Whitespace:
          stray.add(ch)
    inc i
  if depth != 0 or stray.len > 0:
    raise newException(ValueError,
      "go convention: " & context & " printed text that is not part of its " &
        "JSON listing; refusing a listing that may be incomplete:\n" & blob)

proc stringList(node: JsonNode; key: string): seq[string] =
  if key in node and node[key].kind == JArray:
    for item in node[key]:
      result.add(item.getStr())

proc parseGoListOutput(output: string): seq[GoPackage] =
  ## Decode the raw ``go list -export -json -deps`` text into the
  ## convention's reduced ``GoPackage`` records. Every field the graph uses
  ## comes from here and from nothing else (Go.md §"The importcfg file",
  ## §"The embedcfg file", §"Per-package compile argv").
  for node in splitJsonObjects(output, "'go list -export -json -deps'"):
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
    pkg.goFiles = stringList(node, "GoFiles")
    pkg.testGoFiles = stringList(node, "TestGoFiles")
    pkg.xTestGoFiles = stringList(node, "XTestGoFiles")
    pkg.imports = stringList(node, "Imports")
    pkg.embedPatterns = stringList(node, "EmbedPatterns")
    pkg.embedFiles = stringList(node, "EmbedFiles")
    if "ImportMap" in node and node["ImportMap"].kind == JObject:
      for source, resolved in node["ImportMap"].pairs:
        pkg.importMap.add((source, resolved.getStr()))
      pkg.importMap.sort(proc(a, b: (string, string)): int = cmp(a[0], b[0]))
    if "Module" in node and node["Module"].kind == JObject:
      let module = node["Module"]
      pkg.hasModule = true
      if "Path" in module: pkg.modulePath = module["Path"].getStr()
      if "Dir" in module: pkg.moduleDir = module["Dir"].getStr()
      if "Main" in module: pkg.moduleMain = module["Main"].getBool()
      if "GoVersion" in module:
        pkg.moduleGoVersion = module["GoVersion"].getStr()
    result.add(pkg)

const
  GoEmitCacheBaseName = "go-list-export"
    ## Sidecar file basename for the emit-time fingerprint cache.
  GoEmitCacheOutputName = "go-list-export.cached.json"
    ## Cached raw ``go list -export -json -deps`` output (go's own JSON,
    ## re-parsed on a hit).
  GoEmitCacheObservedName = "go-list-export.observed"
    ## What the monitored runs read, in ``renderObservedReads``'s format: the
    ## inputs the cache key is recomputed over on the next emit.
  DefaultModuleGoVersion = "1.16"
    ## cmd/go's ``gover.DefaultGoModVersion``: the language version of a
    ## module whose ``go.mod`` has no ``go`` directive.

proc goEmitCacheScratchDir(projectRoot: string): string =
  ## Per-project emit-cache scratch — same shape as the Rust convention.
  projectRoot / ScratchDirName / ".emit-cache"

type GoRun = object
  stdout: string
  stderr: string

proc runGoMonitored(goExe: string; args: seq[string];
                    projectRoot, scratchDir, stem: string;
                    observed: var GoObservedInputs): GoRun =
  ## Run ``go <args>`` from ``projectRoot`` under io-mon's in-process host
  ## and fold what it read into ``observed`` (Go.md §"Implicit-dependency
  ## capture", item 3), following Failure-Semantics.md §"Monitoring
  ## Failures":
  ##   * a monitor that cannot be started (no shim, unsupported host) is
  ##     required monitoring that is unavailable, and the run is REFUSED;
  ##   * a capture graded incomplete is a loss of unknown scope: the output is
  ##     used, and the diagnosis is recorded in ``observed.incomplete`` so
  ##     that nothing derived from it is reused.
  ##
  ## io-mon spawns with ``poParentStreams``. On POSIX the provider's own
  ## descriptors 1 and 2 are pointed at two capture files across the spawn
  ## (``repro_core/monitor_spawn_stdio``, the engine's implementation), so the
  ## listing is read from its own file and the child opens nothing to write
  ## it. On Windows io-mon captures the child's stdout and stderr into one
  ## file; ``splitJsonObjects`` refuses any text in it that is not JSON.
  let commandText = "go " & args.join(" ")
  var run: MonitoredRun
  try:
    run = runMonitoredTool(@[goExe] & args, projectRoot, scratchDir, stem,
      commandText, observed)
  except MonitorUnavailableError as e:
    raise newException(ValueError,
      "go convention: an unobserved listing has no sound key " &
        "(Go.md §\"Implicit-dependency capture\"): " & e.msg)
  result = GoRun(stdout: run.stdout, stderr: run.stderr)
  if run.exitCode != 0:
    raise newException(ValueError,
      "go convention: '" & commandText & "' exited " & $run.exitCode &
        " for " & projectRoot & ":\n" & result.stderr & result.stdout)

proc listArgs(patterns: seq[string]): seq[string] =
  @["list", "-export", "-json", "-deps"] & patterns

proc workspacePatterns(projectRoot, goExe, scratchDir: string;
                       observed: var GoObservedInputs): seq[string] =
  ## Workspace mode (Go.md §"Workspace and module mode"): ``go list -m
  ## -json`` names the workspace's main modules, and the listing covers
  ## ``<Dir>/...`` of each. ``./...`` cannot stand in for it: a workspace
  ## root that is not itself a module matches no package, and a member may
  ## live outside the root.
  let run = runGoMonitored(goExe, @["list", "-m", "-json"], projectRoot,
    scratchDir, "go-list-m", observed)
  for node in splitJsonObjects(run.stdout, "'go list -m -json'"):
    if node.kind != JObject:
      continue
    if "Main" in node and node["Main"].getBool() and "Dir" in node:
      result.add(node["Dir"].getStr() / "...")
  if result.len == 0:
    raise newException(ValueError,
      "go convention: 'go list -m -json' named no workspace module for " &
        projectRoot & ":\n" & run.stdout)
  result.sort(system.cmp[string])

proc observedFingerprint(projectRoot, goExe: string;
                         observed: GoObservedInputs): string =
  ## The emit-cache key: the toolchain, the command, and the CURRENT content
  ## of every recorded input — file digests, directory memberships and
  ## digests of the values of the environment variables the runs read
  ## (``observedReadsInputs``).
  var inputs: seq[EmitCacheInput] = @[
    textInput("go-exe:" & goExe),
    toolVersionInput(goExe, ["version"]),
    textInput("project-root:" & projectRoot),
    textInput("cmd:go list -export -json -deps (module or workspace patterns)"),
  ]
  inputs.add(observedReadsInputs(observed))
  computeEmitCacheFingerprint(inputs)

proc runGoListing(projectRoot, goExe: string): GoListing =
  ## The project's one listing (Go.md §"Recognition" 2): ``go list -export
  ## -json -deps <patterns>`` run once for the whole project, under the
  ## monitor, with ``<patterns>`` ``./...`` in module mode and each workspace
  ## module's ``<Dir>/...`` in workspace mode.
  ##
  ## ``-export`` makes ``go`` populate ``GOCACHE`` with the standard-library
  ## archives and report each one's path in ``Export``; those reads are part
  ## of the observed key, so a trimmed cache entry re-derives the graph.
  ##
  ## **Emit cache**: the raw output is kept with the list of what the runs
  ## read. A later emit reuses it only while every recorded file has the
  ## same content, every recorded directory the same members and every
  ## recorded environment variable the same value, compared by digest
  ## (``observedFingerprint``).
  ## On a hit the same recorded inputs are what the fragment reports. A
  ## listing whose capture was incomplete is never stored, so it is never
  ## reused.
  let scratchDir = goEmitCacheScratchDir(projectRoot)
  let cachedOutputPath = scratchDir / GoEmitCacheOutputName
  let observedPath = scratchDir / GoEmitCacheObservedName
  if fileExists(extendedPath(observedPath)) and
      fileExists(extendedPath(cachedOutputPath)):
    try:
      let observed = parseObservedReads(readFile(extendedPath(observedPath)))
      if observed.files.len > 0 and emitCacheIsUsable(scratchDir,
          GoEmitCacheBaseName, observedFingerprint(projectRoot, goExe,
          observed), [cachedOutputPath, observedPath]):
        let packages = parseGoListOutput(
          readFile(extendedPath(cachedOutputPath)))
        if packages.len > 0:
          return GoListing(packages: packages, observed: observed)
    except CatchableError:
      # An unreadable or unparsable cache is a miss.
      discard
  var observed = GoObservedInputs()
  let patterns =
    if fileExists(extendedPath(projectRoot / "go.work")):
      workspacePatterns(projectRoot, goExe, scratchDir, observed)
    else:
      @["./..."]
  let run = runGoMonitored(goExe, listArgs(patterns), projectRoot,
    scratchDir, "go-list-export", observed)
  result = GoListing(packages: parseGoListOutput(run.stdout),
    observed: observed)
  if observed.incomplete.len > 0:
    return
  # Persist the output and the observed inputs BEFORE the fingerprint, so a
  # crash part-way leaves a mismatched sidecar (a miss), never a matched but
  # stale one.
  try:
    writeFile(extendedPath(cachedOutputPath), run.stdout)
    writeFile(extendedPath(observedPath), renderObservedReads(observed))
    writeEmitCacheFingerprint(scratchDir, GoEmitCacheBaseName,
      observedFingerprint(projectRoot, goExe, observed))
  except CatchableError:
    discard

proc registerObservedInputs(observed: GoObservedInputs; goExe: string) =
  ## Report the observed reads as the fragment's evaluation inputs
  ## (Project-Provider-Graph-Protocol.md §"Evaluation Inputs"): a changed
  ## file re-invokes this convention, a changed directory membership re-runs
  ## the root. Must run inside ``buildPackageFragment``'s build proc, which
  ## resets the registry before calling it. A path that is a directory when
  ## registered is covered by its enumeration if it was enumerated; a file
  ## digest of it would read as ``missing`` either way.
  registerObservedReads(observed, goExe)

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

proc renderImportcfg(packages: openArray[GoPackage]; pkg: GoPackage;
                     projectRoot, projectEntry: string): string =
  ## The package's ``importcfg`` (Go.md §"The importcfg file"), taken from
  ## its own ``go list`` record and from nothing else:
  ##   * one ``importmap <source>=<resolved>`` line per ``ImportMap`` entry;
  ##   * one ``packagefile <path>=<archive>`` line per ``Imports`` entry,
  ##     whose archive is the standard-library ``Export`` file or our own
  ##     compile output for a non-standard package.
  ## ``go.mod``'s ``replace`` directives play no part: a replacement changes
  ## a package's ``Dir``, never its import path. The first line is the
  ## ``# import config`` comment cmd/go writes (informational only).
  result.add("# import config\n")
  for (source, resolved) in pkg.importMap:
    result.add("importmap " & source & "=" & resolved & "\n")
  for importPath in pkg.imports:
    var found = false
    for dep in packages:
      if dep.importPath != importPath:
        continue
      found = true
      if dep.standard:
        if dep.exportArchive.len == 0:
          # ``unsafe`` (and only such intrinsic packages) carries no archive:
          # the compiler provides it.
          break
        result.add("packagefile " & importPath & "=" & dep.exportArchive &
          "\n")
      else:
        result.add("packagefile " & importPath & "=" &
          archivePathFor(projectRoot, projectEntry, importPath) & "\n")
      break
    if not found:
      raise newException(ValueError,
        "go convention: " & pkg.importPath & " imports " & importPath &
          ", which 'go list -deps' did not report; refusing an importcfg " &
          "that would omit it")

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

type
  GoCompileAction = object
    action: BuildActionDef
    importPath: string
    archivePath: string

proc goLanguageVersion*(version: string): string =
  ## Port of cmd/go's ``gover.Lang``
  ## (https://github.com/golang/go/blob/master/src/cmd/go/internal/gover/gover.go):
  ## the language version of a Go version — its ``major.minor`` prefix, or
  ## the bare major for ``1`` and ``1.0``. ``1.22.3`` and ``1.21rc1`` give
  ## ``1.22`` and ``1.21``. A ``go`` directive may carry a patch release or a
  ## pre-release suffix (``go mod init`` writes ``go 1.N.0`` since Go 1.21),
  ## and the compiler's ``-lang`` accepts only ``goMAJOR.MINOR``, so cmd/go
  ## passes ``-lang=go`` & ``Lang(v)``, never ``v`` itself. Raises
  ## ``ValueError`` on a string that does not start with ``major[.minor]``
  ## (``go list`` validates the directive, so that means a corrupt record).
  proc digitsAt(s: string; start: int): int =
    result = start
    while result < s.len and s[result] in Digits:
      inc result
  let majorEnd = digitsAt(version, 0)
  if majorEnd == 0:
    raise newException(ValueError,
      "go convention: not a Go version: " & version.escape())
  let major = version[0 ..< majorEnd]
  if majorEnd == version.len:
    return major
  if version[majorEnd] != '.':
    raise newException(ValueError,
      "go convention: not a Go version: " & version.escape())
  let minorEnd = digitsAt(version, majorEnd + 1)
  if minorEnd == majorEnd + 1:
    raise newException(ValueError,
      "go convention: not a Go version: " & version.escape())
  let minor = version[majorEnd + 1 ..< minorEnd]
  if major == "1" and minor == "0":
    return major
  major & "." & minor

proc languageVersionOf(pkg: GoPackage): string =
  ## ``-lang`` for one package (Go.md §"Per-package compile argv"): the
  ## language version (``goLanguageVersion``) of the ``GoVersion`` of the
  ## module containing it, as ``go list`` reports it in the package's
  ## ``Module`` record, or of cmd/go's default when that module declares no
  ## ``go`` directive. Never the root ``go.mod``'s version: a dependency or a
  ## workspace member compiles at its own.
  if not pkg.hasModule:
    raise newException(ValueError,
      "go convention: 'go list' reported no module for non-standard " &
        "package " & pkg.importPath & "; only module and workspace mode " &
        "are supported (Go.md)")
  goLanguageVersion(
    if pkg.moduleGoVersion.len > 0: pkg.moduleGoVersion
    else: DefaultModuleGoVersion)

proc collectEmbedSources(pkg: GoPackage): seq[string] =
  ## Absolute paths of the package's ``EmbedFiles``.
  for relative in pkg.embedFiles:
    result.add(pkg.dir / relative.replace('/', DirSep))
  result.sort(system.cmp[string])

proc embedcfgPathFor(projectRoot, projectEntry, importPath: string): string =
  scratchPathFor(projectRoot, projectEntry) / "pkg" /
    (sanitizeImportPath(importPath) & ".embedcfg")

proc emitEmbedcfgAction(projectRoot, projectEntry: string;
                        pkg: GoPackage): tuple[action: BuildActionDef;
                                               path: string] =
  ## The package's ``-embedcfg`` document (Go.md §"The embedcfg file") as an
  ## ``fs.writeText`` action, like the importcfg.
  let path = embedcfgPathFor(projectRoot, projectEntry, pkg.importPath)
  createDir(extendedPath(parentDir(path)))
  let action = fs.writeText(
    output = path,
    text = renderEmbedcfg(pkg.dir, pkg.embedPatterns, pkg.embedFiles),
    actionId = actionIdFor("go-embedcfg", projectEntry, pkg.importPath),
    commandStatsId = "go.embedcfg")
  (action, path)

proc emitCompileAction(projectRoot, projectEntry, goExe: string;
                      pkg: GoPackage;
                      packages: seq[GoPackage];
                      importcfgPath: string;
                      importcfgActionId: string;
                      embedcfgPath = "";
                      embedcfgActionId = ""): GoCompileAction =
  ## Emit a single per-package ``go tool compile`` action. Inputs are the
  ## package's ``.go`` files, its embedded files, and the importcfg (and,
  ## for a package with ``//go:embed``, the embedcfg) the writer actions
  ## produce. Outputs are the package archive.
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
    "-lang=go" & languageVersionOf(pkg),
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
  if embedcfgPath.len > 0:
    argv.add("-embedcfg")
    argv.add(embedcfgPath)
  argv.add("-pack")
  argv.add("-o")
  argv.add(archive)
  for src in sourceFiles:
    argv.add(src)

  var inputs: seq[string] = @[importcfgPath]
  for src in sourceFiles:
    inputs.add(src)
  var deps = @[importcfgActionId]
  # Go.md §"Cross-package ordering edges": the compile of a package consumes
  # the archive of every non-standard package it imports, so it must run
  # after their compiles. Without the edge the scheduler is free to start it
  # first, and the compile fails reading an archive that does not exist yet.
  for importPath in pkg.imports:
    for dep in packages:
      if dep.importPath == importPath and not dep.standard:
        inputs.add(archivePathFor(projectRoot, projectEntry, importPath))
        deps.add(actionIdFor("go-compile", projectEntry, importPath))
        break
  if embedcfgPath.len > 0:
    inputs.add(embedcfgPath)
    deps.add(embedcfgActionId)
    for embedded in collectEmbedSources(pkg):
      inputs.add(embedded)

  let action = buildAction(
    id = actionIdFor("go-compile", projectEntry, pkg.importPath),
    call = inlineExecCall(argv, projectRoot),
    deps = deps,
    inputs = inputs,
    outputs = @[archive],
    pool = "compile",
    dependencyPolicy = automaticMonitorPolicy(),
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
  let text = renderImportcfg(packages, pkg, projectRoot, projectEntry)
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
    dependencyPolicy = automaticMonitorPolicy(),
    commandStatsId = "go.link")

proc syntheticPackage(projectRoot, projectEntry: string): PackageDef =
  ## Build a minimal ``PackageDef`` for the runtime helper. Same shape
  ## used by the Nim and Rust conventions.
  let projectMatch = resolveProjectFile(projectRoot)
  let sourceFile =
    if projectMatch.path.len > 0: projectMatch.path
    else: projectRoot / LegacyProjectFileName
  PackageDef(
    packageName: projectEntry,
    sourceFile: sourceFile,
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

proc sameDirectory(a, b: string): bool =
  if a.len == 0 or b.len == 0:
    return false
  if os.normalizedPath(a) == os.normalizedPath(b):
    return true
  try:
    sameFile(a, b)
  except CatchableError:
    false

proc deriveProjectEntry(packages: seq[GoPackage];
                        projectRoot: string): string =
  ## Pick a stable filename-safe ``entry`` name for the project as a whole.
  ## Used as the scratch-dir prefix (``<scratch>/<projectEntry>/pkg/``) and
  ## as the synthetic ``PackageDef.packageName``; every binary of the
  ## project shares it.
  ##
  ## Priority:
  ##   1. The last segment of the path of the main module whose ``Dir`` is
  ##      the project root, as ``go list`` reports it (module mode, or a
  ##      workspace whose root is itself a module), snake-cased.
  ##   2. ``projectRoot`` basename, snake-cased (a workspace whose root is
  ##      not a module).
  for pkg in packages:
    if pkg.standard or not pkg.moduleMain or pkg.modulePath.len == 0:
      continue
    if sameDirectory(pkg.moduleDir, projectRoot):
      return sanitizeBinaryName(pkg.modulePath.split('/')[^1])
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

proc packageHasTests(pkg: GoPackage): bool =
  ## M22: true when the package ships at least one ``_test.go`` file
  ## (either white-box ``TestGoFiles`` or black-box ``XTestGoFiles``).
  ## We don't recurse — ``go list`` already enumerates every package in
  ## the module, so the caller iterates over packages directly.
  pkg.testGoFiles.len > 0 or pkg.xTestGoFiles.len > 0

proc testStampPathFor(projectRoot, projectEntry, importPath: string):
    string =
  ## M22: per-package test-run stamp under
  ## ``<scratch>/<projectEntry>/tests/<sanitized>.stamp``. Mirrors the
  ## shape of the per-package compile archive's path; one stamp per
  ## test-bearing package keeps the cache invalidation granular without
  ## fragmenting the scratch tree.
  scratchPathFor(projectRoot, projectEntry) / "tests" /
    (sanitizeImportPath(importPath) & ".stamp")

proc collectTestSources(pkg: GoPackage): seq[string] =
  ## Absolute paths of every ``_test.go`` file in the package. Used as
  ## inputs of the ``go test`` action so a test-source edit invalidates
  ## the action.
  for relative in pkg.testGoFiles:
    result.add(pkg.dir / relative)
  for relative in pkg.xTestGoFiles:
    result.add(pkg.dir / relative)
  result.sort(system.cmp[string])

proc emitTestAction(projectRoot, projectEntry, goExe: string;
                    pkg: GoPackage;
                    nonStdlibArchives: seq[string]):
                      tuple[run: BuildActionDef; stamp: BuildActionDef] =
  ## M22: emit a single ``go test -count=1 <importPath>`` action per
  ## test-bearing package, paired with an ``fs.stamp`` companion that
  ## marks success.
  ##
  ## Why ``-count=1``: by default ``go test`` caches results across
  ## invocations under ``$GOCACHE``. ``-count=1`` is the official knob
  ## that disables the cache without invalidating it (vs ``go clean
  ## -testcache``). Reprobuild's own action cache is the source of truth
  ## for "should we re-run?"; we want every invocation that does fire
  ## to actually re-run the binary.
  ##
  ## Inputs include the package's regular ``.go`` files + its
  ## ``_test.go`` files + every non-stdlib archive in the module
  ## (those are the compile outputs the test could possibly link
  ## against). Stdlib archives live in ``GOCACHE`` and are not declared
  ## inputs — same trade-off the per-package compile action makes.
  ##
  ## ``automaticMonitorPolicy()`` covers transitive package reads the
  ## eager input enumeration missed (e.g. a test that uses ``runtime``
  ## reflection to load extra files).
  let sourceFiles = collectGoSources(pkg)
  let testFiles = collectTestSources(pkg)
  let argv = @[
    goExe,
    "test",
    "-count=1",
    pkg.importPath,
  ]
  var inputs: seq[string] = @[]
  for src in sourceFiles:
    inputs.add(src)
  for src in testFiles:
    inputs.add(src)
  for archive in nonStdlibArchives:
    inputs.add(archive)
  let runAction = buildAction(
    id = actionIdFor("go-test-run", projectEntry, pkg.importPath),
    call = inlineExecCall(argv, projectRoot),
    inputs = inputs,
    outputs = @[],
    pool = "compile",
    dependencyPolicy = automaticMonitorPolicy(),
    commandStatsId = "go.test-run")
  let stampPath =
    testStampPathFor(projectRoot, projectEntry, pkg.importPath)
  createDir(extendedPath(parentDir(stampPath)))
  let stampAction = fs.stamp(
    output = stampPath,
    title = "go-test:" & pkg.importPath,
    entries = @[pkg.importPath],
    actionId = actionIdFor("go-test-stamp", projectEntry, pkg.importPath),
    deps = @[runAction.id],
    commandStatsId = "go.test-stamp")
  (runAction, stampAction)

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
    let listing = runGoListing(projectRoot, goExe)
    let packages = listing.packages
    if packages.len == 0:
      raise newException(ValueError,
        "go convention: 'go list' returned no packages for " & projectRoot)
    let mainPackages = collectMainPackages(packages)
    let projectEntry = deriveProjectEntry(packages, projectRoot)
    let pkg = syntheticPackage(projectRoot, projectEntry)
    let registerAll = proc() =
      # The graph below is derived from the listing, so what the listing read
      # is what the fragment reports as its evaluation inputs (Go.md
      # §"Implicit-dependency capture", item 3).
      registerObservedInputs(listing.observed, goExe)
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
        var embedcfgPath, embedcfgActionId: string
        if srcPkg.embedPatterns.len > 0:
          let embedcfgPair = emitEmbedcfgAction(projectRoot, projectEntry,
            srcPkg)
          allActions.add(embedcfgPair.action)
          embedcfgPath = embedcfgPair.path
          embedcfgActionId = embedcfgPair.action.id
        let compileAction = emitCompileAction(projectRoot, projectEntry,
          goExe, srcPkg, packages, importcfgPair.importcfgPath,
          importcfgPair.action.id, embedcfgPath, embedcfgActionId)
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

      # M22 test discovery. For each non-stdlib package that ships
      # ``_test.go`` files (``TestGoFiles`` or ``XTestGoFiles`` non-empty
      # in ``go list -json``), emit one ``go test -count=1 <importPath>``
      # action under a non-default ``test`` target.
      var testActions: seq[BuildActionDef] = @[]
      # Pre-collect the module's non-stdlib archive paths so each test
      # action's input list can declare them — captures the edge that
      # ``go test`` may link against any of these.
      var nonStdlibArchives: seq[string] = @[]
      for ca in compileActions:
        nonStdlibArchives.add(ca.archivePath)
      for srcPkg in packages:
        if srcPkg.standard:
          continue
        if not packageHasTests(srcPkg):
          continue
        let pair = emitTestAction(projectRoot, projectEntry, goExe,
          srcPkg, nonStdlibArchives)
        testActions.add(pair.run)
        testActions.add(pair.stamp)
      if testActions.len > 0:
        discard target("test", testActions)
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
