## Nim language convention (Tier 2b) — Mode A "fine-grained" plugin.
##
## Recognises a project whose ``reprobuild.nim`` has ``uses:`` containing
## ``nim`` AND a conventional ``<pkg>.nimble`` (or ``src/<pkg>.nim``) on
## disk plus at least one ``executable`` / ``library`` member, and emits
## the three-phase Nim build graph the convention spec
## (``reprobuild-specs/Language-Conventions/Nim.md`` §"Mode A — Fine-grained
## build graph") prescribes:
##
##   Phase 1 (one action per entrypoint):
##     ``nim c --skipParentCfg --skipUserCfg --compileOnly --noLinking
##       --nimcache:<scratch>/<entry>/nimcache --mm:orc -d:release
##       <projectRoot>/src/<entry>.nim``
##     produces the C files + the ``<entry>.json`` nimcache manifest.
##
##   Phase 2 (one action per ``.c`` file, derived from the manifest's
##   ``compile`` array):
##     ``gcc -c -o <obj> -MD -MF <obj>.d <nim-emitted-flags> <c-file>``
##     each depends on phase 1 and writes a depfile (depfile policy).
##
##   Phase 3 (one action per entrypoint):
##     ``gcc -o <projectRoot>/.repro/build/<entry>/<entry>.exe <objs>
##       <linker-flags-from-manifest>``
##     depends on every phase-2 action.
##
## **Design decision (M3 Option 1 — eager + M18 fingerprint cache).** The
## convention invokes ``nim c --compileOnly`` from ``emitFragment`` itself
## (via ``osproc.execCmdEx``) so it can read the manifest and enumerate
## the per-file compile actions *at convention-emit time*. The pure-
## dyndep alternative — a generator action that produces a ``dyndep``
## file the engine reads at build time, with the engine SYNTHESISING per-
## ``.c`` actions from the fragment — would require extending the engine's
## current dyndep contract (which can only attach extra deps/outputs to
## actions that already exist, not create new ones). That refactor is
## deferred to a follow-on milestone.
##
## M18 lands the headline perf goal (the eager subprocess no longer fires
## on every ``repro build``) via a pragmatic fingerprint sidecar in
## ``conventions/emit_cache.nim``: ``runNimCompileOnly`` hashes the
## ``.nim`` source set + the entry source + the ``--app:lib`` toggle +
## the nim driver path, compares against
## ``<nimcacheDir>/nim-c-compileonly.repro-emit-fingerprint``, and skips
## the subprocess on a match (the previous run's manifest is reused).
## This keeps a static-graph emit shape while making cold-snapshot
## re-emits cheap when the source set is unchanged.
##
## The eager ``nim c`` run also doubles as the Phase 1 action: we encode
## the *same* command line into the inline-exec call so the engine's
## action cache fingerprints the work and skips a re-run when nothing has
## changed.
##
## **Caveats**:
##   * Requires ``nim`` on ``PATH`` at convention-emit time (the same
##     condition Phase 1 needs at build time). When ``nim`` is missing,
##     ``recognize`` returns ``false`` so dispatch falls through to the
##     "no convention matched" diagnostic with the regular project hint.
##   * Phase 2/3 hard-code ``gcc`` as the C compiler — matches the Nim
##     compiler's default on Linux/MinGW. M3+ should consult ``uses:``
##     for ``msvc``/``clang`` pins and pick the matching compiler driver.

import std/[algorithm, json, os, osproc, strutils]

import repro_core
import repro_provider_runtime
import repro_project_dsl
import repro_standard_provider/convention
import repro_standard_provider/conventions/emit_cache

const
  ScratchDirName* = ".repro/build"
    ## Top-level scratch directory under the project root the Nim
    ## convention writes into. Kept as a const so the e2e validator and
    ## any cleanup scripts agree with the convention on a single edit.

type
  NimEntrypoint = object
    ## Single ``executable foo`` declaration discovered in
    ## ``reprobuild.nim``. Library-only packages join the dispatch surface
    ## via ``NimLibraryTarget`` (M12); the two kinds share Phase 1/2 of
    ## the build graph and differ only in the Phase 3 link action.
    name: string
    sourceFile: string
      ## Absolute path to ``<projectRoot>/src/<name>.nim``.

  NimLibraryKind = enum
    nlkStatic
    nlkShared
    nlkBoth
    nlkHeaderOnly

  NimLibraryTarget = object
    ## Single ``library foo`` declaration discovered in
    ## ``reprobuild.nim``. M12 supports ``kind: static|shared|both|header-only``.
    name: string
    sourceFile: string
      ## Absolute path to ``<projectRoot>/src/<name>.nim``.
    kind: NimLibraryKind

  NimcacheCompileStep = object
    ## One row of the ``compile`` array in ``<entry>.json``. The Nim
    ## compiler emits ``[<absolute c file>, <gcc command template>]``;
    ## we keep the entry as parsed and decode the gcc command lazily.
    cFile: string
    gccCommand: string

  NimcacheManifest = object
    compile: seq[NimcacheCompileStep]
    link: seq[string]
    linkcmd: string

proc readReprobuildSource(projectRoot: string): string =
  ## Read ``<projectRoot>/reprobuild.nim`` or return the empty string.
  ## Used by both ``recognize`` and ``emitFragment``; never raises.
  let path = projectRoot / "reprobuild.nim"
  if not fileExists(extendedPath(path)):
    return ""
  try:
    readFile(extendedPath(path))
  except CatchableError:
    ""

proc usesIncludesNim(source: string): bool =
  ## True when the ``uses:`` block names a ``nim`` or ``nim >=x`` toolchain.
  ## Mirrors the heuristic in ``project_intro.readUsesHint`` but trims the
  ## version constraint suffix off each entry. Conservative: any error
  ## in parsing returns ``false`` so dispatch falls through.
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
          if firstToken == "nim":
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
          if firstToken == "nim":
            return true
  false

proc extractEntrypoints(source: string): seq[string] =
  ## Heuristic line-scan for ``executable <name>`` declarations. Same
  ## scope as the rest of the Tier 2b heuristics — diagnostic-grade, not
  ## a DSL evaluator. Ignores ``executable <name>:`` blocks too (the
  ## colon is dropped before comparison).
  for rawLine in source.splitLines():
    var line = rawLine
    let commentIdx = line.find('#')
    if commentIdx >= 0:
      line = line[0 ..< commentIdx]
    let stripped = line.strip()
    if not stripped.startsWith("executable"):
      continue
    let rest = stripped[len("executable") .. ^1].strip()
    if rest.len == 0:
      continue
    # Stop at the first whitespace/colon — block-form ``executable foo:``
    # and inline-form ``executable foo`` both collapse to "foo".
    var name = ""
    for ch in rest:
      if ch in {' ', '\t', ':', ','}:
        break
      name.add(ch)
    if name.len > 0:
      result.add(name)

proc parseNimLibraryKind(text: string): NimLibraryKind =
  ## Mirrors ``libraryKindLiteral`` in the DSL; accepts the same token
  ## set the DSL grammar does. Conservative-static on unknowns — keeps
  ## the heuristic line-scanner from raising on malformed bodies (the
  ## DSL evaluator would have rejected them earlier).
  case text.normalize
  of "shared", "lkshared", "dynamic":
    nlkShared
  of "both", "lkboth":
    nlkBoth
  of "header-only", "headeronly", "lkheaderonly":
    nlkHeaderOnly
  else:
    nlkStatic

proc extractLibraries(source: string): seq[NimLibraryTarget] =
  ## Heuristic line-scan for ``library <name>`` declarations and any
  ## subsequent indented ``kind: <token>`` line in their body. Mirrors
  ## ``extractEntrypoints`` for the executable case; diagnostic-grade,
  ## not a DSL evaluator. Accepts both shapes:
  ##
  ##   library foo                 — bare command, ``kind`` defaults to
  ##                                 ``nlkStatic``.
  ##   library foo:                — block form. The body may carry a
  ##     kind: shared                ``kind: <token>`` line. We pick up
  ##                                 the first ``kind:`` line encountered
  ##                                 while indented under the declaration.
  ##
  ## Indentation tracking: we record the column of the ``library`` keyword
  ## and treat any subsequent non-empty line whose leading whitespace
  ## exceeds that column as part of the library body. The first line that
  ## un-indents back to ``library``'s column closes the body.
  var current: ref NimLibraryTarget
  var libraryColumn = -1
  for rawLine in source.splitLines():
    var line = rawLine
    let commentIdx = line.find('#')
    if commentIdx >= 0:
      line = line[0 ..< commentIdx]
    let stripped = line.strip()
    if stripped.len == 0:
      continue
    var indent = 0
    for ch in line:
      if ch == ' ':
        inc indent
      elif ch == '\t':
        indent += 8
      else:
        break
    if current != nil:
      if indent > libraryColumn:
        # Still inside the library body. Look for ``kind: <token>``.
        if stripped.startsWith("kind:"):
          var value = stripped[5 .. ^1].strip()
          if value.len > 0:
            value = value.strip(chars = {'"', '\''})
            current[].kind = parseNimLibraryKind(value)
        continue
      else:
        # Un-indented — body closed. Emit and fall through to look at
        # the current line as a fresh statement.
        result.add(current[])
        current = nil
        libraryColumn = -1
    if stripped.startsWith("library") and
        (stripped.len == len("library") or
         stripped[len("library")] in {' ', '\t'}):
      let rest = stripped[len("library") .. ^1].strip()
      if rest.len == 0:
        continue
      var name = ""
      for ch in rest:
        if ch in {' ', '\t', ':', ','}:
          break
        name.add(ch)
      if name.len == 0:
        continue
      var lib = NimLibraryTarget(name: name, kind: nlkStatic)
      current = new(NimLibraryTarget)
      current[] = lib
      libraryColumn = indent
  if current != nil:
    result.add(current[])

proc hasAnyMember(source: string): bool =
  ## True when the package declares at least one ``executable`` or
  ## ``library`` member. Delegates to the per-shape extractors so the
  ## sentinel check matches the same token boundary the per-shape
  ## scanners use (``library<sp|tab>name``, never ``libraryName``).
  if extractEntrypoints(source).len > 0:
    return true
  extractLibraries(source).len > 0

proc findNimbleFile(projectRoot: string): string =
  ## Return the absolute path of the first ``*.nimble`` file in
  ## ``projectRoot``, or the empty string. The Nim convention's recognition
  ## spec wants ``<pkgname>.nimble`` — but stem-vs-package matching is
  ## brittle when pkgname uses camelCase (``nimBinaryExample``) while the
  ## conventional snake_case ``.nimble`` stem (``nim_binary_example``) is
  ## what nimble itself enforces. The looser check "*any* .nimble at the
  ## root" is good enough for M3: every Nim package ships exactly one.
  for kind, path in walkDir(projectRoot):
    if kind == pcFile and path.endsWith(".nimble"):
      return path
  ""

proc nimExecutable(): string =
  ## Resolve the ``nim`` executable on PATH or return ``""`` if missing.
  ## Recognise time: avoids declaring a match we can't fulfil at emit.
  findExe("nim")

proc nimRecognize(projectRoot: string;
                  request: ProviderGraphRequest): bool {.gcsafe.} =
  ## Recognition contract (M3):
  ##   * ``reprobuild.nim`` mentions ``nim`` in ``uses:``
  ##   * at least one ``executable`` (or ``library``) member is declared
  ##   * either a ``*.nimble`` exists at the project root, OR at least
  ##     one declared executable has its ``src/<name>.nim`` on disk
  ##   * the ``nim`` compiler is on PATH (so emit can run it)
  let source = readReprobuildSource(projectRoot)
  if source.len == 0:
    return false
  if not usesIncludesNim(source):
    return false
  if not hasAnyMember(source):
    return false
  if nimExecutable().len == 0:
    return false
  let hasNimble = findNimbleFile(projectRoot).len > 0
  if hasNimble:
    return true
  for name in extractEntrypoints(source):
    let entryFile = projectRoot / "src" / (name & ".nim")
    if fileExists(extendedPath(entryFile)):
      return true
  for lib in extractLibraries(source):
    let entryFile = projectRoot / "src" / (lib.name & ".nim")
    if fileExists(extendedPath(entryFile)):
      return true
  false

proc scratchPathFor(projectRoot, entry: string): string =
  projectRoot / ScratchDirName / entry

proc nimcachePathFor(projectRoot, entry: string): string =
  scratchPathFor(projectRoot, entry) / "nimcache"

proc objDirFor(projectRoot, entry: string): string =
  scratchPathFor(projectRoot, entry) / "obj"

proc binaryPathFor(projectRoot, entry: string): string =
  when defined(windows):
    scratchPathFor(projectRoot, entry) / (entry & ".exe")
  else:
    scratchPathFor(projectRoot, entry) / entry

proc staticLibraryPathFor(projectRoot, entry: string): string =
  ## ``libfoo.a`` lives under the per-library scratch dir so the
  ## convention's outputs line up neatly: one ``.a`` per ``library``
  ## declaration. ``ar`` writes archive members keyed by member basename;
  ## the per-entry scratch keeps two libraries from stomping each other
  ## even on case-insensitive filesystems.
  scratchPathFor(projectRoot, entry) / ("lib" & entry & ".a")

proc sharedLibraryPathFor(projectRoot, entry: string): string =
  ## Platform-specific shared library name. Nim convention M12 picks the
  ## native suffix:
  ##   * Windows : ``<entry>.dll``
  ##   * macOS   : ``lib<entry>.dylib``
  ##   * Other   : ``lib<entry>.so``
  when defined(windows):
    scratchPathFor(projectRoot, entry) / (entry & ".dll")
  elif defined(macosx):
    scratchPathFor(projectRoot, entry) / ("lib" & entry & ".dylib")
  else:
    scratchPathFor(projectRoot, entry) / ("lib" & entry & ".so")

proc nimcacheManifestPathFor(projectRoot, entry: string): string =
  nimcachePathFor(projectRoot, entry) / (entry & ".json")

proc nimCompileOnlyArgv(nimExe, nimcacheDir, entrySource: string;
                        appLib = false): seq[string] =
  ## The literal argv for both the eager (emit-time) and recorded
  ## (graph-action) Phase 1 invocation. Keeping these identical is the
  ## whole point of Option 1: the cached fingerprint of the recorded
  ## action matches what we just executed.
  ##
  ## M12: when ``appLib`` is true, append ``--app:lib`` so Nim emits a
  ## linkcmd that produces a shared library rather than an executable.
  ## ``ar``-based static linking ignores Nim's linkcmd entirely so the
  ## static path leaves ``appLib`` false (preserving the executable-mode
  ## linkcmd in the manifest, even though we discard it).
  result = @[
    nimExe,
    "c",
    "--skipParentCfg",
    "--skipUserCfg",
    "--compileOnly",
    "--noLinking",
    "--nimcache:" & nimcacheDir,
    "--mm:orc",
    "--define:release"
  ]
  if appLib:
    result.add("--app:lib")
  result.add(entrySource)

const
  NimEmitCacheBaseName = "nim-c-compileonly"
    ## Sidecar file basename for the M18 emit-time fingerprint cache.
    ## See ``emit_cache.nim`` for the contract.

proc nimEmitCacheFingerprint(nimExe, entrySource, manifestPath: string;
                             nimSources: openArray[string];
                             appLib: bool): string =
  ## Fingerprint key for the nim-c-compileonly cache.
  ##
  ## Inputs that participate in the key:
  ##   * the Nim driver path (``findExe("nim")`` resolved on this run);
  ##   * the entry source path (which entry we're compiling);
  ##   * the ``appLib`` toggle (controls whether ``--app:lib`` is emitted,
  ##     which materially changes the nimcache linkcmd);
  ##   * the manifest output path (so two scratch dirs can't share a
  ##     fingerprint sidecar even if their source set is identical);
  ##   * every ``.nim`` source file under ``<projectRoot>/src/`` plus the
  ##     entry source itself — content digest folded in via
  ##     ``fileInput``.
  ##
  ## Not in the key today:
  ##   * the ``nim`` binary's bytes (only its path). On a managed dev
  ##     shell the path includes the version, which is good enough; a
  ##     paranoid future M can fold in ``nim --version`` output if a
  ##     same-path-different-binary case crops up.
  ##   * environment variables. The convention's argv is hermetic at
  ##     the source level — Nim doesn't read ``NIMCACHE_DIR`` etc. when
  ##     ``--nimcache:`` is set on the command line.
  var inputs: seq[EmitCacheInput] = @[
    textInput("nim-exe:" & nimExe),
    textInput("entry-source:" & entrySource),
    textInput("manifest:" & manifestPath),
    textInput("app-lib:" & (if appLib: "true" else: "false")),
    fileInput(entrySource),
  ]
  for source in nimSources:
    inputs.add(fileInput(source))
  computeEmitCacheFingerprint(inputs)

proc runNimCompileOnly(nimExe, nimcacheDir, entrySource: string;
                       nimSources: openArray[string];
                       manifestPath: string;
                       appLib = false) =
  ## Execute the eager Phase 1 run and surface any failure as a
  ## ``ValueError`` carrying the captured stderr. The standard provider
  ## binary's outer ``try/except`` (in ``apps/repro-standard-provider``)
  ## converts these into the protocol-level error response.
  ##
  ## **M6.5 pipe-buffer audit**: previously used
  ## ``osproc.startProcess(..., options = {poStdErrToStdOut}) +
  ## outputStream.readAll() + waitForExit()`` which deadlocks on Windows
  ## when ``nim c`` output exceeds the ~64 KB OS pipe buffer (a real
  ## project with thousands of modules emits enough log chatter to hit
  ## this). Switched to ``execCmdEx`` which drains the pipe continuously
  ## via background reader, matching the Go convention's
  ## ``runGoListExport`` pattern.
  ##
  ## The captured output is used **only** for the non-zero-exit
  ## diagnostic; the actual graph data is parsed from the on-disk
  ## ``nimcache.json`` manifest after the process exits, so any progress
  ## chatter in the merged stdout/stderr is harmless here.
  ##
  ## **M18 emit-cache fast path**: when a sidecar fingerprint at
  ## ``<nimcacheDir>/nim-c-compileonly.repro-emit-fingerprint`` matches
  ## the current source-set fingerprint AND the nimcache manifest is on
  ## disk, we skip the subprocess entirely — the previous run's manifest
  ## is still valid. The convention's caller re-parses the manifest
  ## unconditionally; that work is cheap (~10 KB JSON) compared to the
  ## ~1-2 s ``nim c`` invocation. The sidecar is refreshed on every
  ## subprocess success so a partial run never poisons the cache.
  createDir(extendedPath(nimcacheDir))
  let fingerprint = nimEmitCacheFingerprint(nimExe, entrySource,
    manifestPath, nimSources, appLib)
  if emitCacheIsUsable(nimcacheDir, NimEmitCacheBaseName, fingerprint,
      [manifestPath]):
    return
  let argv = nimCompileOnlyArgv(nimExe, nimcacheDir, entrySource, appLib)
  let cmd = quoteShellCommand(argv)
  let (output, exitCode) = execCmdEx(cmd,
    options = {poStdErrToStdOut, poUsePath})
  if exitCode != 0:
    raise newException(ValueError,
      "nim convention: 'nim c --compileOnly' exited " & $exitCode &
        " for " & entrySource & ":\n" & output)
  writeEmitCacheFingerprint(nimcacheDir, NimEmitCacheBaseName, fingerprint)

proc parseNimcacheManifest(manifestPath: string): NimcacheManifest =
  ## Decode the nimcache ``<entry>.json`` Nim writes alongside the
  ## ``.c`` files. We pull just the fields Phase 2/3 need; any future
  ## extension (``configFiles``, ``depfiles``) plugs in here.
  let raw = readFile(extendedPath(manifestPath))
  let node = parseJson(raw)
  if node.kind != JObject:
    raise newException(ValueError,
      "nim convention: nimcache manifest is not a JSON object: " & manifestPath)
  if "compile" in node and node["compile"].kind == JArray:
    for entry in node["compile"]:
      if entry.kind != JArray or entry.len != 2:
        continue
      result.compile.add(NimcacheCompileStep(
        cFile: entry[0].getStr(),
        gccCommand: entry[1].getStr()))
  if "link" in node and node["link"].kind == JArray:
    for item in node["link"]:
      result.link.add(item.getStr())
  if "linkcmd" in node:
    result.linkcmd = node["linkcmd"].getStr()

proc splitCommandLine(cmd: string): seq[string] =
  ## Minimal POSIX-style argv tokeniser sufficient for the gcc commands
  ## Nim emits — whitespace separated, no quoted multi-word arguments
  ## (Nim quotes paths containing spaces but our scratch dir is under
  ## ``.repro/build`` which we control). Anything fancier would need a
  ## real lexer; on Windows, ``CreateProcessW`` re-joins these via
  ## ``CommandLineToArgvW`` rules so a single-pass whitespace split is
  ## safe as long as no token contains a space.
  var token = ""
  for ch in cmd:
    if ch in {' ', '\t'}:
      if token.len > 0:
        result.add(token)
        token = ""
    else:
      token.add(ch)
  if token.len > 0:
    result.add(token)

proc rewriteGccArgv(rawArgv: seq[string]; cFile, objFile, depFile: string):
    seq[string] =
  ## Take the gcc argv Nim baked into the nimcache manifest and rewrite
  ## the per-file outputs:
  ##   * replace ``-o <something>`` with ``-o <objFile>``
  ##   * drop the trailing ``<cFile>`` (we re-add it explicitly)
  ##   * append ``-MD -MF <depFile>`` for incremental dep tracking
  ##
  ## We keep every other flag verbatim — Nim picks ``-O3 -fno-ident``
  ## etc. for us and the convention spec wants those preserved.
  var argv: seq[string] = @[]
  var i = 0
  while i < rawArgv.len:
    let token = rawArgv[i]
    if token == "-o" and i + 1 < rawArgv.len:
      argv.add("-o")
      argv.add(objFile)
      inc i, 2
      continue
    if token == cFile:
      inc i
      continue
    argv.add(token)
    inc i
  argv.add("-MD")
  argv.add("-MF")
  argv.add(depFile)
  argv.add(cFile)
  argv

proc gccDriverFromCommand(rawArgv: seq[string]; gccDefault: string): string =
  ## Pluck the driver (first token) out of the manifest command; fall
  ## back to whatever ``findExe`` resolved. Nim emits ``gcc.exe`` on
  ## Windows / ``gcc`` on POSIX as the first token.
  if rawArgv.len > 0:
    return rawArgv[0]
  gccDefault

proc objFileFromManifestCFile(objDir, cFile: string): string =
  ## Nim emits one ``.c`` per Nim module with mangled names like
  ## ``@mfoo.nim.c`` or ``@psystem.nim.c``. Reuse those names for the
  ## per-file ``.o`` so the manifest's ``link`` array (which already
  ## carries the matching ``.o`` paths) lines up with what Phase 2
  ## produces, edge for edge.
  let stem = extractFilename(cFile)
  objDir / (stem & ".o")

proc actionIdFor(prefix, entry, detail: string): string =
  ## Build a Reprobuild-safe action id. The DSL's ``sanitizeNodePart``
  ## already rewrites unsafe chars, but keeping the *human* id readable
  ## helps the ``--log=actions`` output.
  var sanitized = ""
  for ch in detail:
    if ch in {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '-', '_', '.'}:
      sanitized.add(ch)
    else:
      sanitized.add('_')
  if sanitized.len == 0:
    sanitized = "x"
  prefix & "-" & entry & "-" & sanitized

proc collectNimSources(srcDir: string): seq[string] =
  ## Every ``.nim`` under ``<projectRoot>/src``. These become the
  ## Phase-1 action's declared inputs so source-only edits invalidate
  ## the action without relying on the FS-snoop monitor.
  if not dirExists(extendedPath(srcDir)):
    return @[]
  for entry in walkDirRec(srcDir):
    if entry.toLowerAscii.endsWith(".nim"):
      result.add(entry)
  result.sort(system.cmp[string])

proc emitForEntrypoint(projectRoot, nimExe: string;
                      entry: NimEntrypoint): tuple[phase1: BuildActionDef;
                                                  phase2: seq[BuildActionDef];
                                                  phase3: BuildActionDef] =
  ## Materialise the three-phase graph for a single ``executable``.
  ## Eagerly runs ``nim c --compileOnly`` so the manifest is on disk
  ## before we register Phase 2/3 — or skips the run when the M18
  ## emit-time fingerprint cache says the previous manifest is still
  ## current.
  let nimcacheDir = nimcachePathFor(projectRoot, entry.name)
  let objDir = objDirFor(projectRoot, entry.name)
  let binaryOutput = binaryPathFor(projectRoot, entry.name)
  let manifestPath = nimcacheManifestPathFor(projectRoot, entry.name)
  createDir(extendedPath(objDir))
  # M18: collect the full ``src/`` source set ONCE so the same fingerprint
  # serves the cache check AND the Phase 1 action's declared inputs.
  let nimSources = collectNimSources(projectRoot / "src")
  runNimCompileOnly(nimExe, nimcacheDir, entry.sourceFile, nimSources,
    manifestPath)
  let manifest = parseNimcacheManifest(manifestPath)
  if manifest.compile.len == 0:
    raise newException(ValueError,
      "nim convention: nimcache manifest carries no compile steps for " &
        entry.name)

  let phase1Outputs = block:
    var outs = @[nimcacheDir, manifestPath]
    for step in manifest.compile:
      outs.add(step.cFile)
    outs

  let phase1Id = actionIdFor("nim-c-compileonly", entry.name, "umbrella")
  let phase1Argv = nimCompileOnlyArgv(nimExe, nimcacheDir, entry.sourceFile)
  let phase1Action = buildAction(
    id = phase1Id,
    call = inlineExecCall(phase1Argv, projectRoot),
    inputs = nimSources,
    outputs = phase1Outputs,
    pool = "compile",
    dependencyPolicy = automaticMonitorPolicy(),
    commandStatsId = "nim.c.compileOnly")

  var phase2: seq[BuildActionDef] = @[]
  var objFiles: seq[string] = @[]
  for step in manifest.compile:
    let cFile = step.cFile
    let rawArgv = splitCommandLine(step.gccCommand)
    let driver = gccDriverFromCommand(rawArgv, findExe("gcc"))
    let objFile = objFileFromManifestCFile(objDir, cFile)
    let depFile = objFile & ".d"
    objFiles.add(objFile)
    var gccArgv = rewriteGccArgv(
      if rawArgv.len > 0: rawArgv[1 .. ^1] else: @[],
      cFile, objFile, depFile)
    gccArgv.insert(driver, 0)
    let action = buildAction(
      id = actionIdFor("gcc-compile", entry.name, extractFilename(cFile)),
      call = inlineExecCall(gccArgv, projectRoot),
      deps = @[phase1Id],
      inputs = @[cFile],
      outputs = @[objFile],
      pool = "compile",
      depfile = depFile,
      dependencyPolicy = makeDepfilePolicy(depFile),
      commandStatsId = "nim.c.gcc-compile")
    phase2.add(action)

  # Phase 3 — link. Reconstruct the linker argv from the manifest's
  # ``linkcmd``: keep every flag Nim emitted but redirect the output to
  # our scratch binary path and use *our* object files.
  let linkRawArgv = splitCommandLine(manifest.linkcmd)
  var linkerArgv: seq[string] = @[]
  if linkRawArgv.len > 0:
    linkerArgv.add(linkRawArgv[0])
  else:
    linkerArgv.add(findExe("gcc"))
  # Walk the manifest linkcmd, keep flags, drop ``-o ...`` and any
  # token that ends in ``.o`` (we'll add our objs ourselves), so that
  # extra link flags such as ``-Wl,-Bstatic -lpthread`` survive.
  var i = if linkRawArgv.len > 0: 1 else: 0
  while i < linkRawArgv.len:
    let token = linkRawArgv[i]
    if token == "-o" and i + 1 < linkRawArgv.len:
      inc i, 2
      continue
    if token.endsWith(".o"):
      inc i
      continue
    linkerArgv.add(token)
    inc i
  # Move the -o pair to the front (right after the driver), then objs,
  # then any remaining flags. Nim emits link libs trailing-after-objs
  # which is what gcc expects, so keep that order.
  var finalArgv: seq[string] = @[linkerArgv[0], "-o", binaryOutput]
  for obj in objFiles:
    finalArgv.add(obj)
  for j in 1 ..< linkerArgv.len:
    finalArgv.add(linkerArgv[j])

  let phase2Ids = block:
    var ids: seq[string] = @[]
    for action in phase2:
      ids.add(action.id)
    ids

  let phase3Action = buildAction(
    id = actionIdFor("gcc-link", entry.name, "binary"),
    call = inlineExecCall(finalArgv, projectRoot),
    deps = phase2Ids,
    inputs = objFiles,
    outputs = @[binaryOutput],
    pool = "compile",
    dependencyPolicy = declaredOnlyDependencyPolicy(),
    commandStatsId = "nim.c.gcc-link")

  (phase1Action, phase2, phase3Action)

proc arDriver(): string =
  ## Resolve ``ar`` on PATH; fall back to the literal token so emit
  ## still produces a coherent argv even when ``ar`` is missing (the
  ## graph-action will report ``ar: command not found`` at build time —
  ## the operator can install GNU binutils and re-run).
  let candidate = findExe("ar")
  if candidate.len > 0:
    return candidate
  "ar"

proc emitForLibrary(projectRoot, nimExe: string;
                   lib: NimLibraryTarget): tuple[
                     phase1: BuildActionDef;
                     phase2: seq[BuildActionDef];
                     phase3: seq[BuildActionDef]] =
  ## Materialise the three-phase graph for a single ``library`` member.
  ## Shares Phase 1/2 with the executable path; Phase 3 differs by
  ## ``lib.kind``:
  ##
  ##   * ``nlkStatic``     — replace gcc link with ``ar rcs libfoo.a <objs>``
  ##   * ``nlkShared``     — keep Nim's emitted linkcmd (Phase 1 invoked
  ##                          with ``--app:lib`` so the linkcmd already
  ##                          carries ``-shared``); redirect the output
  ##                          path to ``libfoo.<so|dylib|dll>``.
  ##   * ``nlkBoth``       — emit BOTH the ``ar`` static action AND the
  ##                          ``gcc -shared`` action, in parallel; Phase 1
  ##                          uses ``--app:lib`` so the manifest carries
  ##                          a shared linkcmd we can reuse.
  ##   * ``nlkHeaderOnly`` — caller is expected to filter these out
  ##                          before reaching ``emitForLibrary``. We treat
  ##                          accidental calls as a bug.
  if lib.kind == nlkHeaderOnly:
    raise newException(ValueError,
      "nim convention: emitForLibrary called for header-only library '" &
        lib.name & "' — header-only libraries emit no actions")

  let useAppLib = lib.kind in {nlkShared, nlkBoth}
  let nimcacheDir = nimcachePathFor(projectRoot, lib.name)
  let objDir = objDirFor(projectRoot, lib.name)
  let manifestPath = nimcacheManifestPathFor(projectRoot, lib.name)
  createDir(extendedPath(objDir))
  # M18: collect the ``src/`` source set ONCE so the same fingerprint
  # serves the emit-cache check AND the Phase 1 action's declared inputs.
  let nimSources = collectNimSources(projectRoot / "src")
  runNimCompileOnly(nimExe, nimcacheDir, lib.sourceFile, nimSources,
    manifestPath, useAppLib)
  let manifest = parseNimcacheManifest(manifestPath)
  if manifest.compile.len == 0:
    raise newException(ValueError,
      "nim convention: nimcache manifest carries no compile steps for " &
        lib.name)

  let phase1Outputs = block:
    var outs = @[nimcacheDir, manifestPath]
    for step in manifest.compile:
      outs.add(step.cFile)
    outs

  let phase1Id = actionIdFor("nim-c-compileonly", lib.name, "umbrella")
  let phase1Argv = nimCompileOnlyArgv(nimExe, nimcacheDir, lib.sourceFile,
    useAppLib)
  let phase1Action = buildAction(
    id = phase1Id,
    call = inlineExecCall(phase1Argv, projectRoot),
    inputs = nimSources,
    outputs = phase1Outputs,
    pool = "compile",
    dependencyPolicy = automaticMonitorPolicy(),
    commandStatsId = "nim.c.compileOnly")

  var phase2: seq[BuildActionDef] = @[]
  var objFiles: seq[string] = @[]
  for step in manifest.compile:
    let cFile = step.cFile
    let rawArgv = splitCommandLine(step.gccCommand)
    let driver = gccDriverFromCommand(rawArgv, findExe("gcc"))
    let objFile = objFileFromManifestCFile(objDir, cFile)
    let depFile = objFile & ".d"
    objFiles.add(objFile)
    var gccArgv = rewriteGccArgv(
      if rawArgv.len > 0: rawArgv[1 .. ^1] else: @[],
      cFile, objFile, depFile)
    # For shared linkage we need every translation unit compiled with
    # -fPIC. Nim's manifest already emits the right thing on POSIX for
    # ``--app:lib`` but be explicit so the static-only path stays safe
    # to switch via ``kind: shared`` without a recompile of the .o files
    # ending up in the wrong shape. No-op on Windows/MinGW where -fPIC
    # is the default.
    if useAppLib:
      var alreadyPic = false
      for tok in gccArgv:
        if tok == "-fPIC" or tok == "-fpic":
          alreadyPic = true
          break
      if not alreadyPic:
        gccArgv.insert("-fPIC", 1)
    gccArgv.insert(driver, 0)
    let action = buildAction(
      id = actionIdFor("gcc-compile", lib.name, extractFilename(cFile)),
      call = inlineExecCall(gccArgv, projectRoot),
      deps = @[phase1Id],
      inputs = @[cFile],
      outputs = @[objFile],
      pool = "compile",
      depfile = depFile,
      dependencyPolicy = makeDepfilePolicy(depFile),
      commandStatsId = "nim.c.gcc-compile")
    phase2.add(action)

  let phase2Ids = block:
    var ids: seq[string] = @[]
    for action in phase2:
      ids.add(action.id)
    ids

  var phase3: seq[BuildActionDef] = @[]

  if lib.kind in {nlkStatic, nlkBoth}:
    let staticOutput = staticLibraryPathFor(projectRoot, lib.name)
    var arArgv: seq[string] = @[arDriver(), "rcs", staticOutput]
    for obj in objFiles:
      arArgv.add(obj)
    let staticAction = buildAction(
      id = actionIdFor("ar-archive", lib.name, "static"),
      call = inlineExecCall(arArgv, projectRoot),
      deps = phase2Ids,
      inputs = objFiles,
      outputs = @[staticOutput],
      pool = "compile",
      dependencyPolicy = declaredOnlyDependencyPolicy(),
      commandStatsId = "nim.c.ar-archive")
    phase3.add(staticAction)

  if lib.kind in {nlkShared, nlkBoth}:
    let sharedOutput = sharedLibraryPathFor(projectRoot, lib.name)
    # Reuse Nim's linkcmd structure (driver + flags) just like the
    # executable path. Phase 1 ran with ``--app:lib`` so the linkcmd
    # already carries ``-shared``. We still rebuild the argv defensively
    # to redirect ``-o`` to our scratch path and ensure our object list
    # is on the link line.
    let linkRawArgv = splitCommandLine(manifest.linkcmd)
    var linkerArgv: seq[string] = @[]
    if linkRawArgv.len > 0:
      linkerArgv.add(linkRawArgv[0])
    else:
      linkerArgv.add(findExe("gcc"))
    var sawShared = false
    var i = if linkRawArgv.len > 0: 1 else: 0
    while i < linkRawArgv.len:
      let token = linkRawArgv[i]
      if token == "-o" and i + 1 < linkRawArgv.len:
        inc i, 2
        continue
      if token.endsWith(".o"):
        inc i
        continue
      if token == "-shared":
        sawShared = true
      linkerArgv.add(token)
      inc i
    var finalArgv: seq[string] = @[linkerArgv[0], "-o", sharedOutput]
    if not sawShared:
      finalArgv.add("-shared")
    for obj in objFiles:
      finalArgv.add(obj)
    for j in 1 ..< linkerArgv.len:
      finalArgv.add(linkerArgv[j])
    let sharedAction = buildAction(
      id = actionIdFor("gcc-link-shared", lib.name, "shared"),
      call = inlineExecCall(finalArgv, projectRoot),
      deps = phase2Ids,
      inputs = objFiles,
      outputs = @[sharedOutput],
      pool = "compile",
      dependencyPolicy = declaredOnlyDependencyPolicy(),
      commandStatsId = "nim.c.gcc-link-shared")
    phase3.add(sharedAction)

  (phase1Action, phase2, phase3)

proc collectEntrypoints(projectRoot, source: string): seq[NimEntrypoint] =
  for name in extractEntrypoints(source):
    let path = projectRoot / "src" / (name & ".nim")
    if fileExists(extendedPath(path)):
      result.add(NimEntrypoint(name: name, sourceFile: path))

proc collectLibraries(projectRoot, source: string): seq[NimLibraryTarget] =
  for lib in extractLibraries(source):
    let path = projectRoot / "src" / (lib.name & ".nim")
    if fileExists(extendedPath(path)):
      result.add(NimLibraryTarget(
        name: lib.name,
        sourceFile: path,
        kind: lib.kind))

proc syntheticPackage(projectRoot: string;
                      entrypoints: seq[NimEntrypoint];
                      libraries: seq[NimLibraryTarget] = @[]): PackageDef =
  ## Build a minimal ``PackageDef`` the runtime helper wants. The Nim
  ## convention doesn't go through DSL evaluation, so we synthesise the
  ## shape ``buildPackageFragment`` needs purely from the recognised
  ## members. ``packageName`` shows up in diagnostics only.
  var name = "nim_convention"
  if entrypoints.len > 0:
    name = entrypoints[0].name
  elif libraries.len > 0:
    name = libraries[0].name
  PackageDef(
    packageName: name,
    sourceFile: projectRoot / "reprobuild.nim",
    hasDevEnv: false,
    devEnvBodyHash: "",
    toolUses: @[])

proc nimEmitFragment(projectRoot: string;
                     request: ProviderGraphRequest): GraphFragment {.gcsafe.} =
  ## Convention entry — eager Phase 1, parse manifest, register Phase
  ## 2/3 via the DSL, hand the whole thing to
  ## ``buildPackageFragment`` so the standard runtime emits the
  ## GraphFragment with all the engine-side bookkeeping (digest,
  ## evaluationInputs, target metadata).
  ##
  ## The DSL runtime mutates module-level registries that aren't
  ## annotated ``gcsafe`` (they predate the provider host). The
  ## standard-provider binary is single-threaded so the ``cast(gcsafe)``
  ## block below is the established escape hatch — same shape the
  ## trycompile provider uses to call ``buildPackageFragment``.
  {.cast(gcsafe).}:
    let source = readReprobuildSource(projectRoot)
    let entrypoints = collectEntrypoints(projectRoot, source)
    let allLibraries = collectLibraries(projectRoot, source)
    # Header-only libraries emit no actions but still need to be
    # acknowledged by the convention. Filter them out at the convention
    # level so emitForLibrary never receives one.
    var buildableLibraries: seq[NimLibraryTarget] = @[]
    for lib in allLibraries:
      if lib.kind != nlkHeaderOnly:
        buildableLibraries.add(lib)
    if entrypoints.len == 0 and buildableLibraries.len == 0:
      if allLibraries.len > 0:
        raise newException(ValueError,
          "nim convention: package declares only header-only libraries; " &
            "no compile/link actions to emit. Add an executable or a " &
            "static/shared library member.")
      raise newException(ValueError,
        "nim convention: no executable or library entry points " &
          "discovered under " & projectRoot)
    let nimExe = nimExecutable()
    if nimExe.len == 0:
      raise newException(ValueError,
        "nim convention: 'nim' executable not on PATH; cannot run Phase 1")
    let pkg = syntheticPackage(projectRoot, entrypoints, buildableLibraries)
    let registerAll = proc() =
      discard buildPool("compile", 8'u32)
      var allActions: seq[BuildActionDef] = @[]
      for entry in entrypoints:
        let triple = emitForEntrypoint(projectRoot, nimExe, entry)
        allActions.add(triple.phase1)
        for a in triple.phase2:
          allActions.add(a)
        allActions.add(triple.phase3)
        discard target(entry.name, allActions)
      for lib in buildableLibraries:
        let bundle = emitForLibrary(projectRoot, nimExe, lib)
        allActions.add(bundle.phase1)
        for a in bundle.phase2:
          allActions.add(a)
        for a in bundle.phase3:
          allActions.add(a)
        discard target(lib.name, allActions)
      if entrypoints.len > 0 or buildableLibraries.len > 0:
        defaultTarget(target("default", allActions))
    result = buildPackageFragment(pkg, request, registerAll,
      includeDefault = false)

proc nimConvention*(): LanguageConvention =
  ## The single value the standard provider binary registers at startup.
  ## Provider plugins typically expose a ``XConvention()`` factory so
  ## consumers can also build *isolated* registries for tests without
  ## touching ``defaultConventionRegistry``.
  LanguageConvention(
    name: "nim",
    recognize: nimRecognize,
    emitFragment: nimEmitFragment)
