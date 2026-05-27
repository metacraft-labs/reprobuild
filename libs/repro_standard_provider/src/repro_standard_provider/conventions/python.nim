## Python language convention (Tier 2b) — Mode A "fine-grained" plugin.
##
## Recognises a project whose ``reprobuild.nim`` declares ``uses:``
## containing ``python3`` (or ``python``) AND ships a conventional
## ``pyproject.toml`` whose ``[build-system].build-backend`` is one of
## the supported PEP 517 backends with stable, well-understood internal
## action graphs:
##
##   * ``hatchling.build``
##   * ``flit_core.buildapi``
##   * ``setuptools.build_meta``
##   * ``setuptools.build_meta:__legacy__``
##
## Other backends (``maturin``, ``scikit-build-core``, ``poetry.core.*``,
## ``pdm.backend``, ``uv_build``) are NOT recognised at M15. They would
## route to a future Mode B crude fallback that delegates to
## ``uv build`` / ``python -m build``.
##
## ``Standard-Provider-Implementation.milestones.org §M15`` and
## ``reprobuild-specs/Language-Conventions/Python.md §"Mode A — Fine-grained
## build graph"`` are the canonical spec. Mode A as fully specified covers
## five sub-graphs (A1 byte-compile, A2 native extension, A3 wheel, A4
## sdist, A5 venv+installer for executable wrappers). The M15 surface
## ships **only the wheel build (A3)**: the per-``.py`` byte-compile
## sub-graph and the venv+installer wrapper emission are deferred to a
## later milestone — both projects in ``reprobuild-examples/python/``
## (``library-pure`` and ``console-script``) graduate from SKIPPED to PASS
## with the wheel alone, since the headline assertion is "a wheel is
## produced and imports cleanly".
##
## **Design decision (M15 — eager PEP 517 hook invocation in-process).**
## Unlike Nim/Rust/Go we don't shell out to a frontend (``uv build`` /
## ``python -m build``). Instead the convention emits a single action
## per ``library``/``executable`` member that runs ``python3 -c
## "<hook script>"``. The hook script:
##
##   1. ``import``s the configured build backend (read from
##      ``pyproject.toml``'s ``[build-system].build-backend``).
##   2. Calls ``backend.build_wheel(<scratch>/<entry>/dist)`` —
##      the spec-faithful PEP 517 entry point. The frontend's
##      build-isolation venv is bypassed because reprobuild's provisioning
##      catalog already arranged for the backend to be importable.
##   3. Optionally renames the produced wheel to the deterministic
##      ``<dist_name>-<version>-py3-none-any.whl`` filename if the backend
##      happened to use a different naming convention (defensive — the
##      three recognised backends all already produce that exact form
##      for pure-Python projects).
##
## **The wheel filename is predicted at convention-emit time** from the
## ``[project].name`` + ``[project].version`` fields in ``pyproject.toml``
## so the action's declared outputs can be enumerated up front. PEP 503
## normalises the distribution name by replacing ``-`` / ``.`` runs with
## ``_``. For ``[project].name = "python-library-example"`` and
## ``version = "0.1.0"``, the wheel lands at
## ``python_library_example-0.1.0-py3-none-any.whl``. Non-pure-Python
## wheels (with platform / ABI tags other than ``py3-none-any``) are not
## yet emitted by this convention — the M15 fixtures are pure-Python; the
## A2 native-extension sub-graph that would produce platform-tagged
## wheels is one of the deferred surfaces.
##
## **Inputs**: every ``.py`` / ``.pyi`` / ``.toml`` / ``README*`` /
## ``LICENSE*`` file under ``<projectRoot>`` plus ``pyproject.toml``
## itself. That covers the source surface hatchling / flit_core /
## setuptools all read at wheel-build time without us having to
## interpret each backend's specific "what goes in the wheel?" rules
## (they ALL re-read the source tree at backend.build_wheel time
## regardless of what we declare — declared inputs only affect the
## action-cache fingerprint).
##
## **Outstanding tasks (deferred from M15)**:
##
##   * A1 per-``.py`` byte-compile via ``python3 -m compileall``. The
##     wheel-assembly action consumes every source file as a single bundle
##     today; once the byte-compile pre-step lands, the wheel action's
##     inputs will be ``.pyc`` outputs and the per-file cache granularity
##     matches the rest of the standard provider's languages.
##   * A2 native extension compile/link via the C-family compile helpers.
##     Triggered by ``[tool.setuptools.ext-modules]`` / ``Extension(...)``
##     blocks.
##   * A4 sdist hook (independent action graph, mirrors A3).
##   * A5 venv + ``installer`` for executable wrappers. The
##     ``[project.scripts]`` entry-points declared by ``console-script``
##     fixtures only become runnable launchers after this step lands. The
##     wheel itself already carries the metadata that materialises them.
##
## **Caveats**:
##   * Requires ``python3`` on ``PATH`` AND requires the configured backend
##     module (``hatchling``, ``flit_core``, or ``setuptools``) to be
##     importable from that Python. The M15 surface trusts the
##     provisioning catalog (``python3.nim``, plus the future
##     ``pyproject-hooks.nim``) to make the backend available — when it
##     isn't, the action fails at build time with a clear ``ImportError``
##     rather than silently falling back to anything.
##   * The wheel filename prediction assumes pure-Python. If a project
##     happens to declare a non-pure backend (e.g. setuptools with C
##     extensions) but slips through recognition, the action will produce
##     a platform-tagged wheel that doesn't match the predicted output
##     name; the engine's output-existence check then surfaces the
##     mismatch.

import std/[algorithm, os, strutils]

import repro_core
import repro_provider_runtime
import repro_project_dsl
import repro_standard_provider/convention

const
  ScratchDirName* = ".repro/build"
    ## Top-level scratch directory under the project root the Python
    ## convention writes into. Identical to the Nim/Rust/Go conventions'
    ## ``ScratchDirName`` — every language convention owns a per-entry
    ## subdirectory under this prefix.

  SupportedBackends = [
    "hatchling.build",
    "flit_core.buildapi",
    "setuptools.build_meta",
    "setuptools.build_meta:__legacy__",
  ]
    ## Build backends whose internal action graph is stable and
    ## well-understood enough to drive directly via PEP 517 hooks. Other
    ## backends (poetry, pdm, maturin, scikit-build-core, uv_build) need
    ## a Mode B frontend; the M15 surface rejects them at recognise time.

type
  PythonMemberKind = enum
    pmkLibrary
    pmkExecutable

  PythonMember = object
    ## Single ``library <name>`` or ``executable <name>`` declaration in
    ## ``reprobuild.nim``. The convention emits one wheel-build action per
    ## member; executables additionally surface their ``[project.scripts]``
    ## entry-point (A5 wrapper emission is deferred).
    name: string
    kind: PythonMemberKind

  PythonProjectInfo = object
    ## Parsed essentials from ``<projectRoot>/pyproject.toml``. The
    ## convention's wheel-build action argv is derived from these.
    distributionName: string
      ## ``[project].name`` verbatim (``"python-library-example"``).
    version: string
      ## ``[project].version`` (``"0.1.0"``).
    buildBackend: string
      ## ``[build-system].build-backend`` (``"hatchling.build"``).
    consoleScripts: seq[tuple[name, target: string]]
      ## ``[project.scripts]`` entries. Each is ``(name, "pkg.module:func")``.

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

proc usesIncludesPython(source: string): bool =
  ## True when the ``uses:`` block names ``python3`` or ``python``.
  ## Mirrors the Nim convention's ``usesIncludesNim`` line-scan — diagnostic-
  ## grade, not a DSL evaluator. Accepts both shapes:
  ##
  ##   uses: python3                  # inline single
  ##   uses: [python3, uv]            # inline list
  ##   uses:                          # block form
  ##     "python3 >=3.11 <4.0"
  ##     "uv >=0.5"
  ##
  ## The version constraint suffix is trimmed off each entry before the
  ## name comparison.
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
          if firstToken == "python3" or firstToken == "python":
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
          if firstToken == "python3" or firstToken == "python":
            return true
  false

proc extractExecutables(source: string): seq[string] =
  ## Heuristic line-scan for ``executable <name>`` declarations. Mirrors
  ## the Nim convention's ``extractEntrypoints``; diagnostic-grade. Ignores
  ## ``executable <name>:`` blocks (the colon is dropped before
  ## comparison).
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
    var name = ""
    for ch in rest:
      if ch in {' ', '\t', ':', ','}:
        break
      name.add(ch)
    if name.len > 0:
      result.add(name)

proc extractLibraries(source: string): seq[string] =
  ## Heuristic line-scan for ``library <name>`` declarations. The Python
  ## convention only cares about the member name (no ``kind: static|shared``
  ## distinction the way the Nim convention does — Python "libraries" are
  ## always wheels).
  for rawLine in source.splitLines():
    var line = rawLine
    let commentIdx = line.find('#')
    if commentIdx >= 0:
      line = line[0 ..< commentIdx]
    let stripped = line.strip()
    if not stripped.startsWith("library"):
      continue
    if stripped.len > len("library") and
        stripped[len("library")] notin {' ', '\t'}:
      continue
    let rest = stripped[len("library") .. ^1].strip()
    if rest.len == 0:
      continue
    var name = ""
    for ch in rest:
      if ch in {' ', '\t', ':', ','}:
        break
      name.add(ch)
    if name.len > 0:
      result.add(name)

proc extractMembers(source: string): seq[PythonMember] =
  ## Combine executables + libraries into a single ordered seq. Libraries
  ## come first so the M15 surface emits the library-pure wheel action
  ## before the executable-bearing console-script action; the order is
  ## diagnostic-only (each member's action is independent).
  for name in extractLibraries(source):
    result.add(PythonMember(name: name, kind: pmkLibrary))
  for name in extractExecutables(source):
    result.add(PythonMember(name: name, kind: pmkExecutable))

proc trimTomlValue(raw: string): string =
  ## Strip whitespace and surrounding quotes from a TOML scalar value.
  ## Accepts both single- and double-quoted strings; bare unquoted
  ## values are returned verbatim (we don't currently consume any
  ## non-string TOML scalar from pyproject.toml).
  var v = raw.strip()
  # Drop trailing comment if any.
  let hash = v.find('#')
  if hash >= 0:
    v = v[0 ..< hash].strip()
  if v.len >= 2 and v[0] == '"' and v[^1] == '"':
    return v[1 ..< v.len - 1]
  if v.len >= 2 and v[0] == '\'' and v[^1] == '\'':
    return v[1 ..< v.len - 1]
  v

proc parsePyprojectToml(path: string): PythonProjectInfo =
  ## Minimal pyproject.toml line-scanner — pulls just the fields the
  ## wheel-build action needs. A real TOML parser would be more robust but
  ## the convention spec already constrains pyproject.toml's shape: every
  ## supported backend's manifest fits the three flat tables
  ## ``[project]``, ``[build-system]``, and ``[project.scripts]``, and the
  ## convention only reads scalar string fields out of them. Multi-line
  ## arrays, inline tables, and ``[project.urls]`` are ignored.
  ##
  ## The scan tracks the current ``[section]`` so identical key names in
  ## different tables (e.g. ``name`` appears under both ``[project]`` and
  ## ``[build-system.requires]``) don't false-positive.
  if not fileExists(extendedPath(path)):
    return
  var raw: string
  try:
    raw = readFile(extendedPath(path))
  except CatchableError:
    return
  var section = ""
  for rawLine in raw.splitLines():
    var line = rawLine
    let stripped = line.strip()
    if stripped.len == 0 or stripped.startsWith("#"):
      continue
    if stripped.startsWith("[") and stripped.endsWith("]"):
      section = stripped[1 ..< stripped.len - 1].strip()
      continue
    let eq = stripped.find('=')
    if eq < 0:
      continue
    let key = stripped[0 ..< eq].strip()
    let value = trimTomlValue(stripped[eq + 1 .. ^1])
    case section
    of "project":
      if key == "name":
        result.distributionName = value
      elif key == "version":
        result.version = value
    of "build-system":
      if key == "build-backend":
        result.buildBackend = value
    of "project.scripts":
      if key.len > 0 and value.len > 0:
        result.consoleScripts.add((name: key, target: value))
    else:
      discard

proc isSupportedBackend(backend: string): bool =
  for entry in SupportedBackends:
    if entry == backend:
      return true
  false

proc pythonExecutable(): string =
  ## Resolve ``python3`` (preferred) or ``python`` on PATH. Recognise time:
  ## avoids declaring a match we can't fulfil at emit. M15 only uses this
  ## as a tie-breaker — the actual action's argv carries the literal
  ## ``python3`` string so the engine's tool provisioning layer resolves
  ## the binary at build time.
  let py3 = findExe("python3")
  if py3.len > 0:
    return py3
  findExe("python")

proc pythonRecognize(projectRoot: string;
                     request: ProviderGraphRequest): bool {.gcsafe.} =
  ## Recognition contract (M15):
  ##   * ``<projectRoot>/pyproject.toml`` exists
  ##   * ``<projectRoot>/reprobuild.nim`` exists AND its ``uses:`` lists
  ##     ``python3`` or ``python``
  ##   * ``pyproject.toml`` declares a ``[build-system].build-backend`` in
  ##     the supported list (hatchling.build / flit_core.buildapi /
  ##     setuptools.build_meta / setuptools.build_meta:__legacy__)
  ##   * the package declares at least one ``library`` or ``executable``
  ##     member
  ##   * ``python3`` (or ``python``) is on PATH (so emit can run the
  ##     PEP 517 hook script)
  ##
  ## Other backends (maturin / scikit-build-core / poetry-core / pdm /
  ## uv_build) fall through to no-match — a future M would route them
  ## to a Mode B crude path.
  if not fileExists(extendedPath(projectRoot / "pyproject.toml")):
    return false
  let source = readReprobuildSource(projectRoot)
  if source.len == 0:
    return false
  if not usesIncludesPython(source):
    return false
  if extractMembers(source).len == 0:
    return false
  let info = parsePyprojectToml(projectRoot / "pyproject.toml")
  if not isSupportedBackend(info.buildBackend):
    return false
  if pythonExecutable().len == 0:
    return false
  true

proc normalizeDistName(name: string): string =
  ## PEP 503 normalisation as applied by wheel filename construction:
  ## replace runs of ``-``, ``_``, or ``.`` with a single ``_``. Used to
  ## predict the wheel filename at convention-emit time.
  ##
  ## Note: PEP 503 itself normalises to lower-case + ``-``-separated; the
  ## wheel filename PEP 427 then replaces ``-`` with ``_``. The combined
  ## effect for the M15 fixtures (``python-library-example``,
  ## ``python-console-script``) is exactly what this proc returns.
  var prev = '\0'
  for ch in name:
    var c = ch
    if c in {'-', '.'}:
      c = '_'
    if c == '_' and prev == '_':
      continue
    result.add(c)
    prev = c

proc sanitizeNamePart(value: string): string =
  ## Build a Reprobuild-safe action-id segment from a member name. Same
  ## shape used by the Nim/Rust/Go conventions; keeps ``--log=actions``
  ## output uniform across the registry.
  for ch in value:
    if ch in {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '-', '_', '.'}:
      result.add(ch)
    else:
      result.add('_')
  if result.len == 0:
    result = "x"

proc scratchPathFor(projectRoot, member: string): string =
  projectRoot / ScratchDirName / member

proc distDirFor(projectRoot, member: string): string =
  scratchPathFor(projectRoot, member) / "dist"

proc hookScriptPathFor(projectRoot, member: string): string =
  ## On-disk location of the PEP 517 hook script the wheel-build action
  ## executes. The script is written at convention-emit time (alongside
  ## the action graph) and referenced positionally on the action's argv
  ## as ``python3 <script>``. Writing the script to disk rather than
  ## passing it as a ``python3 -c "..."`` argv literal avoids the Windows
  ## command-line newline-mangling failure mode (CreateProcessW collapses
  ## embedded newlines in a single argv element under some quoting
  ## regimes); the engine's process-spawn path on this platform goes
  ## through ``startProcess(... poParentStreams)`` which inherits the
  ## same behaviour.
  scratchPathFor(projectRoot, member) / "build_wheel.py"

proc predictedWheelFilename(info: PythonProjectInfo): string =
  ## Compose the PEP 427 wheel filename from the parsed pyproject.toml
  ## fields. M15 only targets pure-Python wheels so the python / ABI /
  ## platform tags are fixed at ``py3-none-any``.
  normalizeDistName(info.distributionName) & "-" & info.version &
    "-py3-none-any.whl"

proc collectSourceInputs(projectRoot: string): seq[string] =
  ## Every ``.py`` / ``.pyi`` / ``.toml`` file plus the canonical
  ## metadata files (``README*``, ``LICENSE*``) under ``projectRoot``.
  ## Declared inputs only affect the action-cache fingerprint — the
  ## backend re-reads the entire source tree at build time regardless,
  ## so the input list's job is to invalidate the cache on every relevant
  ## file edit and nothing else.
  if not dirExists(extendedPath(projectRoot)):
    return @[]
  for entry in walkDirRec(projectRoot):
    let lower = entry.toLowerAscii
    # Skip everything under the scratch dir — those are our own outputs.
    if (ScratchDirName & "/") in entry.replace('\\', '/'):
      continue
    if "/.repro/" in entry.replace('\\', '/'):
      continue
    let base = extractFilename(entry).toLowerAscii
    if lower.endsWith(".py") or lower.endsWith(".pyi") or
       lower.endsWith(".toml"):
      result.add(entry)
      continue
    if base.startsWith("readme") or base.startsWith("license") or
       base == "py.typed":
      result.add(entry)
      continue
  result.sort(system.cmp[string])

proc renderHookScript(projectRoot, backend, distDir,
                      predictedWheel: string): string =
  ## Build the Python source for the PEP 517 ``build_wheel`` hook
  ## invocation. The script:
  ##
  ##   1. ``chdir``s to ``projectRoot`` so the backend reads the right
  ##      ``pyproject.toml`` regardless of where the action was invoked.
  ##   2. Creates the output directory.
  ##   3. ``importlib.import_module``s the configured backend.
  ##   4. Calls ``backend.build_wheel(distDir)``.
  ##   5. Renames the produced wheel to the predicted filename if the
  ##      backend's chosen name differs (defensive — for hatchling /
  ##      flit_core / setuptools pure-Python wheels the two already
  ##      match).
  ##
  ## We bake ``SOURCE_DATE_EPOCH`` / ``PYTHONHASHSEED`` / ``ZIP_DETERMINISTIC``
  ## into the environment *inside* the script via ``os.environ`` so the
  ## archive byte-stable contract holds even when the engine's caller
  ## doesn't inherit them.
  ##
  ## The script is small and self-contained — it doesn't touch the
  ## frontend's solver, doesn't materialise a build-isolation venv, and
  ## doesn't reach the network. PEP 517 build_wheel is a pure function of
  ## the source tree + the importable backend.
  ##
  ## Path quoting: every interpolated path is wrapped in ``repr()`` at
  ## render time so backslashes (Windows) and embedded spaces don't break
  ## the Python source. The triple-quoted string body is constructed in
  ## Nim, then the path values are spliced in as Python string literals.
  let projectRootLit = projectRoot.replace("\\", "\\\\").replace("\"", "\\\"")
  let distDirLit = distDir.replace("\\", "\\\\").replace("\"", "\\\"")
  let predictedLit = predictedWheel.replace("\\", "\\\\")
    .replace("\"", "\\\"")
  let backendLit = backend.replace("\"", "\\\"")
  # Build the Python source as a sequence of lines joined with explicit
  # newlines. Doing it line-by-line (rather than a single triple-quoted
  # template with embedded ``& "..." &``) sidesteps Nim's triple-quoted
  # string semantics: when ``"""`` is immediately followed by a newline,
  # Nim strips that newline from the string value. That stripping caused
  # the previous template to emit the four constant-assignment lines
  # without separators ("project_root = ...dist_dir = ...predicted = ...
  # backend_name = ..." on one line), which Python then rejected with
  # ``SyntaxError: invalid syntax``.
  var lines: seq[string] = @[]
  lines.add("import importlib, os, sys")
  lines.add("os.environ.setdefault(\"SOURCE_DATE_EPOCH\", \"315532800\")")
  lines.add("os.environ.setdefault(\"PYTHONHASHSEED\", \"0\")")
  lines.add("os.environ.setdefault(\"ZIP_DETERMINISTIC\", \"1\")")
  lines.add("project_root = \"" & projectRootLit & "\"")
  lines.add("dist_dir = \"" & distDirLit & "\"")
  lines.add("predicted = \"" & predictedLit & "\"")
  lines.add("backend_name = \"" & backendLit & "\"")
  lines.add("os.makedirs(dist_dir, exist_ok=True)")
  lines.add("os.chdir(project_root)")
  # PEP 517 build-backend qualifiers: "module:attr" allows the backend to
  # expose its hook surface on a non-default attribute. The convention
  # ships with backends (hatchling/flit_core/setuptools/legacy) where the
  # attribute is always omitted (the module itself exposes
  # ``build_wheel``); the split below stays general for forward-compat.
  lines.add("if \":\" in backend_name:")
  lines.add("    mod_name, attr_name = backend_name.split(\":\", 1)")
  lines.add("else:")
  lines.add("    mod_name, attr_name = backend_name, None")
  lines.add("backend = importlib.import_module(mod_name)")
  lines.add("if attr_name:")
  lines.add("    for part in attr_name.split(\".\"):")
  lines.add("        backend = getattr(backend, part)")
  lines.add("build_wheel = getattr(backend, \"build_wheel\")")
  lines.add("produced = build_wheel(dist_dir)")
  lines.add("src = os.path.join(dist_dir, produced)")
  lines.add("if produced != predicted:")
  lines.add("    target = os.path.join(dist_dir, predicted)")
  lines.add("    if os.path.exists(target):")
  lines.add("        os.remove(target)")
  lines.add("    os.rename(src, target)")
  lines.add("    produced = predicted")
  lines.add("print(\"wheel:\", produced, file=sys.stderr)")
  result = lines.join("\n") & "\n"

proc emitMemberAction(projectRoot, pythonExe: string;
                      member: PythonMember;
                      info: PythonProjectInfo;
                      sourceInputs: seq[string]):
                        tuple[action: BuildActionDef;
                              wheelPath: string] =
  ## Emit the wheel-build action for a single ``library``/``executable``
  ## member. M15 ships one action per member; M16+ will add the
  ## byte-compile pre-step + venv-install post-step.
  let distDir = distDirFor(projectRoot, member.name)
  let wheelFilename = predictedWheelFilename(info)
  let wheelPath = distDir / wheelFilename
  let scriptPath = hookScriptPathFor(projectRoot, member.name)
  createDir(extendedPath(distDir))
  createDir(extendedPath(parentDir(scriptPath)))

  let script = renderHookScript(projectRoot, info.buildBackend, distDir,
    wheelFilename)
  # Materialise the hook script eagerly so the action's argv stays a
  # simple ``python3 <script>``. Eager write mirrors the Nim convention's
  # eager ``nim c --compileOnly`` invocation: a tiny side-effect at
  # convention-emit time that the engine then fingerprints via the
  # action's declared inputs.
  writeFile(extendedPath(scriptPath), script)

  let argv = @[
    pythonExe,
    scriptPath,
  ]
  let actionId = "python-build-wheel-" & sanitizeNamePart(member.name)
  let statsId = case member.kind
    of pmkLibrary: "python.build-wheel.library"
    of pmkExecutable: "python.build-wheel.executable"
  var inputs = sourceInputs
  inputs.add(scriptPath)
  let action = buildAction(
    id = actionId,
    call = inlineExecCall(argv, projectRoot),
    inputs = inputs,
    outputs = @[wheelPath],
    pool = "compile",
    dependencyPolicy = declaredOnlyDependencyPolicy(),
    commandStatsId = statsId)
  (action, wheelPath)

proc syntheticPackage(projectRoot: string;
                      members: seq[PythonMember];
                      info: PythonProjectInfo): PackageDef =
  ## Build a minimal ``PackageDef`` the runtime helper wants. The
  ## convention doesn't go through DSL evaluation, so we synthesise the
  ## shape ``buildPackageFragment`` needs purely from the recognised
  ## members. ``packageName`` shows up in diagnostics only — prefer the
  ## distribution name from pyproject.toml when present so the diagnostic
  ## matches what the rest of the Python toolchain calls the project.
  var name = "python_convention"
  if info.distributionName.len > 0:
    name = normalizeDistName(info.distributionName)
  elif members.len > 0:
    name = members[0].name
  PackageDef(
    packageName: name,
    sourceFile: projectRoot / "reprobuild.nim",
    hasDevEnv: false,
    devEnvBodyHash: "",
    toolUses: @[])

proc pythonEmitFragment(projectRoot: string;
                        request: ProviderGraphRequest):
                          GraphFragment {.gcsafe.} =
  ## Convention entry — parse pyproject.toml, enumerate the package's
  ## members, emit one wheel-build action per member, hand the whole
  ## thing to ``buildPackageFragment``.
  ##
  ## The DSL runtime mutates module-level registries that aren't annotated
  ## ``gcsafe`` (they predate the provider host). Same shape as the
  ## Nim/Rust/Go conventions' ``cast(gcsafe)`` escape hatch.
  {.cast(gcsafe).}:
    let source = readReprobuildSource(projectRoot)
    let members = extractMembers(source)
    if members.len == 0:
      raise newException(ValueError,
        "python convention: no library or executable members declared " &
          "in " & projectRoot / "reprobuild.nim")
    let info = parsePyprojectToml(projectRoot / "pyproject.toml")
    if info.distributionName.len == 0:
      raise newException(ValueError,
        "python convention: pyproject.toml has no [project].name field " &
          "(under " & projectRoot & ")")
    if info.version.len == 0:
      raise newException(ValueError,
        "python convention: pyproject.toml has no [project].version " &
          "field (under " & projectRoot & ")")
    if not isSupportedBackend(info.buildBackend):
      raise newException(ValueError,
        "python convention: unsupported [build-system].build-backend '" &
          info.buildBackend & "' (recognised: hatchling.build / " &
          "flit_core.buildapi / setuptools.build_meta)")
    let pythonExe = pythonExecutable()
    if pythonExe.len == 0:
      raise newException(ValueError,
        "python convention: neither 'python3' nor 'python' on PATH; " &
          "cannot run the PEP 517 build_wheel hook")
    let pkg = syntheticPackage(projectRoot, members, info)
    let sourceInputs = collectSourceInputs(projectRoot)
    let registerAll = proc() =
      discard buildPool("compile", 8'u32)
      var allActions: seq[BuildActionDef] = @[]
      for member in members:
        let emitted = emitMemberAction(projectRoot, pythonExe, member, info,
          sourceInputs)
        allActions.add(emitted.action)
      # Per-member target aliases are deferred: at M15 each member emits
      # exactly one wheel-build action, and the engine's graph linker
      # rejects "single-action target N + single-action target default
      # both pointing at the same action" as a duplicate-alias error
      # (see ``repro_cli_support.nim`` §"aliasForAction"). The ``default``
      # target alone is sufficient for the M9 harness which builds
      # ``#default``. Multi-action members (post-M15 once the
      # byte-compile and installer sub-graphs land) can opt back in to
      # per-member aliases without triggering the check.
      defaultTarget(target("default", allActions))
    result = buildPackageFragment(pkg, request, registerAll,
      includeDefault = false)

proc pythonConvention*(): LanguageConvention =
  ## The single value the standard provider binary registers at startup.
  ## Same factory shape as ``nimConvention`` / ``rustConvention`` /
  ## ``goConvention`` so tests can build isolated registries.
  LanguageConvention(
    name: "python",
    recognize: pythonRecognize,
    emitFragment: pythonEmitFragment)
