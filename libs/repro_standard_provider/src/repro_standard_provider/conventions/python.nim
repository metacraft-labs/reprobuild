## Python language convention (Tier 2b) — Mode A "fine-grained" plugin
## with M24 Mode B crude fallback.
##
## Recognises a project whose ``reprobuild.nim`` declares ``uses:``
## containing ``python3`` (or ``python``) AND ships a conventional
## ``pyproject.toml``.
##
## **Mode A backends** (well-understood, fine-grained PEP 517 action
## graph emitted directly via the configured backend's ``build_wheel``
## hook):
##
##   * ``hatchling.build``
##   * ``flit_core.buildapi``
##   * ``setuptools.build_meta``
##   * ``setuptools.build_meta:__legacy__``
##
## **Mode B backends** (M24 — recognised, routed to the crude fallback
## which delegates to ``python -m build --wheel --no-isolation`` under
## io-monitor). These backends need their own toolchains (a Rust compiler
## for maturin, a CMake-driven C/C++ compiler for scikit-build-core, an
## opinionated PEP 517 frontend for poetry-core / pdm-backend / uv_build)
## and have manifest shapes that don't reduce cleanly to the four PEP 517
## hooks Mode A exercises. The Mode B path treats the project as a
## black box and trusts the backend's frontend to handle isolation,
## dep resolution, native toolchain orchestration, etc.:
##
##   * ``maturin``                          (Rust-backed PyO3 extensions)
##   * ``scikit_build_core.build``          (CMake-driven C/C++ extensions)
##   * ``poetry.core.masonry.api``          (poetry-core)
##   * ``pdm.backend``
##   * ``uv_build``
##
## ``Standard-Provider-Implementation.milestones.org §M15`` (Tier 2b
## landing) and ``§M20`` (deferred A1/A4/A5 graduations) are the canonical
## spec for the M20 surface. Mode A's five sub-graphs:
##
##   * **A1 byte-compile** (per-``.py``) — ``python3 -m compileall -b -q -f
##     <src.py>`` actions emit a ``<src.py>c`` adjacent to each source.
##     The wheel-build action consumes those ``.pyc`` files as inputs so
##     the bytecode is included in the produced wheel (hatchling /
##     flit_core / setuptools all happily ship adjacent ``.pyc`` files
##     when present at build time).
##   * **A2 native extension compile + link** — deferred. Triggered by
##     ``[tool.setuptools.ext-modules]`` / ``Extension(...)`` blocks;
##     would also produce platform-tagged wheels.
##   * **A3 wheel assembly** via the PEP 517 ``build_wheel`` hook called
##     directly (bypassing the frontend solver). The convention's hook
##     script ``chdir``s to the project root, ``importlib.import_module``s
##     the configured backend, and calls ``backend.build_wheel(<dist>)``.
##   * **A4 sdist assembly** via the PEP 517 ``build_sdist`` hook (M20).
##     Mirrors A3's shape: one action per member that emits
##     ``<dist>-<ver>.tar.gz`` under the same ``<scratch>/<member>/dist/``
##     directory.
##   * **A5 console-script wrapper shim** (M20). When the project
##     declares ``[project.scripts]`` AND a member is recognised as an
##     ``executable``, an additional ``python3 -m installer
##     --destdir <out>/install <wheel>`` action unpacks the wheel onto
##     disk and emits the launcher executable. Output paths:
##     ``<scratch>/<member>/install/Scripts/<name>.exe`` (Windows) or
##     ``<scratch>/<member>/install/bin/<name>`` (POSIX). The launcher's
##     ``__main__.py`` is patched with a ``sys.path.insert(0, "...")``
##     preamble pointing at the install's ``site/`` subtree so the shim
##     runs without any PYTHONPATH plumbing from the caller.
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
## **Caveats**:
##   * Requires ``python3`` on ``PATH`` AND requires the configured backend
##     module (``hatchling``, ``flit_core``, or ``setuptools``) to be
##     importable from that Python. The convention trusts the
##     provisioning catalog (``python3.nim`` + ``installer.nim``) to make
##     the backend available — when it isn't, the action fails at build
##     time with a clear ``ImportError`` rather than silently falling back
##     to anything.
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
import repro_standard_provider/crude

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
    ## well-understood enough to drive directly via PEP 517 hooks
    ## (Mode A). The convention emits the full byte-compile + wheel +
    ## sdist (+ installer) sub-graph for these.

  ModeBBackends = [
    "maturin",
    "scikit_build_core.build",
    "scikit-build-core.build",
    "poetry.core.masonry.api",
    "poetry.masonry.api",
    "pdm.backend",
    "pdm-backend",
    "uv_build",
    "uv-build",
  ]
    ## M24: build backends that the convention RECOGNISES but routes to
    ## the Mode B crude fallback. These backends need extra toolchains
    ## (Rust compiler for maturin, CMake for scikit-build-core, etc.)
    ## and don't reduce cleanly to the four PEP 517 hooks Mode A uses.
    ## The fallback invokes ``python -m build --wheel --no-isolation``
    ## which delegates to the configured backend; the backend is expected
    ## to already be importable (provisioned via the dev environment).
    ##
    ## Both hyphen-spelled and underscore-spelled forms are listed
    ## because some projects historically wrote the dotted Python path
    ## with hyphens — pip + the PEP 517 frontend are forgiving but our
    ## TOML scan reads the literal string.

type
  PythonMemberKind = enum
    pmkLibrary
    pmkExecutable

  PythonMember = object
    ## Single ``library <name>`` or ``executable <name>`` declaration in
    ## ``reprobuild.nim``. The convention emits one wheel-build action per
    ## member; executables additionally surface their ``[project.scripts]``
    ## entry-point (M20: an installer action wires the runnable launcher).
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
  ## Read the project file (``repro.nim`` or legacy ``reprobuild.nim``)
  ## under ``projectRoot``; return the empty string when neither is
  ## present. Used by both ``recognize`` and ``emitFragment``; never
  ## raises. See ``repro_core/project_file`` for the alias contract.
  let match = resolveProjectFile(projectRoot)
  if match.path.len == 0:
    return ""
  try:
    readFile(extendedPath(match.path))
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

proc isModeBBackend(backend: string): bool =
  ## M24: True when ``backend`` is one of the Mode B-eligible PEP 517
  ## backends (maturin / scikit-build-core / poetry-core / pdm-backend /
  ## uv_build). The convention claims projects with these backends and
  ## routes them through ``pythonCrudeFallback``.
  for entry in ModeBBackends:
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
  ## Recognition contract (M15 + M24):
  ##   * ``<projectRoot>/pyproject.toml`` exists
  ##   * ``<projectRoot>/reprobuild.nim`` exists AND its ``uses:`` lists
  ##     ``python3`` or ``python``
  ##   * the package declares at least one ``library`` or ``executable``
  ##     member
  ##   * ``pyproject.toml`` declares a ``[build-system].build-backend``
  ##     EITHER in the Mode A supported list (hatchling.build /
  ##     flit_core.buildapi / setuptools.build_meta /
  ##     setuptools.build_meta:__legacy__) OR in the M24 Mode B list
  ##     (maturin / scikit_build_core.build / poetry.core.* /
  ##     pdm.backend / uv_build)
  ##   * ``python3`` (or ``python``) is on PATH (so emit can run either
  ##     the Mode A PEP 517 hook script or the Mode B
  ##     ``python -m build`` frontend)
  ##
  ## Unknown backends still fall through to no-match — only the explicit
  ## Mode A + Mode B catalog is claimed. ``emitFragment`` then dispatches
  ## to ``pythonCrudeFallback`` for Mode B backends and to the Mode A
  ## sub-graph emitter otherwise.
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
  if not isSupportedBackend(info.buildBackend) and
     not isModeBBackend(info.buildBackend):
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

proc installDirFor(projectRoot, member: string): string =
  ## M20 A5: per-member ``install/`` scratch directory the
  ## ``python3 -m installer`` action writes into. Layout:
  ##
  ##   <scratch>/<member>/install/
  ##     Scripts/<console-script>.exe   (Windows)
  ##     bin/<console-script>            (POSIX)
  ##     site/<package>/...              (purelib contents)
  ##     site/<dist>-<ver>.dist-info/...
  ##
  ## The install dir is the action's declared output set; the launcher
  ## itself is the load-bearing artefact validated by the E2E gate.
  scratchPathFor(projectRoot, member) / "install"

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

proc sdistHookScriptPathFor(projectRoot, member: string): string =
  ## On-disk location of the PEP 517 build_sdist hook script (M20 A4).
  ## Same shape as ``hookScriptPathFor``; lives next to the wheel hook so
  ## both actions can fingerprint identical input sets and a per-member
  ## ``ls`` shows the convention's full surface.
  scratchPathFor(projectRoot, member) / "build_sdist.py"

proc installerHookScriptPathFor(projectRoot, member: string): string =
  ## On-disk location of the M20 A5 installer hook script. Same as the
  ## wheel + sdist hooks: written eagerly at convention-emit time;
  ## referenced positionally on the action's argv.
  scratchPathFor(projectRoot, member) / "install_wheel.py"

proc predictedWheelFilename(info: PythonProjectInfo): string =
  ## Compose the PEP 427 wheel filename from the parsed pyproject.toml
  ## fields. M15 only targets pure-Python wheels so the python / ABI /
  ## platform tags are fixed at ``py3-none-any``.
  normalizeDistName(info.distributionName) & "-" & info.version &
    "-py3-none-any.whl"

proc predictedSdistFilename(info: PythonProjectInfo): string =
  ## PEP 625 sdist filename: ``<normalized>-<version>.tar.gz``.
  normalizeDistName(info.distributionName) & "-" & info.version & ".tar.gz"

proc launcherFilename(scriptName: string): string =
  ## OS-specific launcher filename for a ``[project.scripts]`` entry.
  ## Windows installer writes a self-contained ``.exe`` per entry; POSIX
  ## emits a hashbang script with the bare console-script name.
  when defined(windows):
    scriptName & ".exe"
  else:
    scriptName

proc launcherSubdir(): string =
  ## Subdirectory of ``installDirFor`` that holds the console-script
  ## launchers. Matches the layout the convention's installer hook script
  ## writes (``scheme_dict['scripts']``); kept in sync with the hook.
  when defined(windows):
    "Scripts"
  else:
    "bin"

proc collectPySourceFiles(projectRoot: string): seq[string] =
  ## Enumerate every ``.py`` file under ``<projectRoot>/src/`` (the
  ## conventional Python src-layout). Used by the M20 A1 byte-compile
  ## sub-graph to drive one ``python3 -m compileall`` action per file.
  ##
  ## We only walk ``src/`` (not the full project tree) because:
  ##   * The PEP 517 backends we recognise (hatchling / flit_core /
  ##     setuptools) all use the src-layout; ``pyproject.toml`` packages
  ##     under ``tool.hatch.build.targets.wheel.packages = ["src/<pkg>"]``.
  ##   * Auxiliary scripts (``conftest.py`` at the project root, build
  ##     hooks, tooling helpers) shouldn't have ``.pyc`` siblings created
  ##     since they aren't shipped in the wheel.
  ##   * Tests under ``tests/`` are not packaged into the wheel; emitting
  ##     ``.pyc`` for them would create noise and bloat the per-file
  ##     action graph.
  ##
  ## Files under ``.repro/`` or any ``__pycache__/`` directories are
  ## skipped — those are reprobuild scratch or stale CPython caches that
  ## must NOT be byte-compiled (their ``.pyc`` siblings have no source).
  let srcRoot = projectRoot / "src"
  if not dirExists(extendedPath(srcRoot)):
    return @[]
  for entry in walkDirRec(srcRoot):
    let normalised = entry.replace('\\', '/')
    if "/__pycache__/" in normalised:
      continue
    if "/.repro/" in normalised:
      continue
    if entry.toLowerAscii.endsWith(".py"):
      result.add(entry)
  result.sort(system.cmp[string])

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

proc renderSdistHookScript(projectRoot, backend, distDir,
                           predictedSdist: string): string =
  ## M20 A4: build_sdist hook script. Mirrors ``renderHookScript`` but
  ## calls ``backend.build_sdist(dist_dir)`` and renames the output to the
  ## predicted ``<dist>-<version>.tar.gz`` filename if the backend's
  ## chosen name differs.
  let projectRootLit = projectRoot.replace("\\", "\\\\").replace("\"", "\\\"")
  let distDirLit = distDir.replace("\\", "\\\\").replace("\"", "\\\"")
  let predictedLit = predictedSdist.replace("\\", "\\\\").replace("\"", "\\\"")
  let backendLit = backend.replace("\"", "\\\"")
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
  lines.add("if \":\" in backend_name:")
  lines.add("    mod_name, attr_name = backend_name.split(\":\", 1)")
  lines.add("else:")
  lines.add("    mod_name, attr_name = backend_name, None")
  lines.add("backend = importlib.import_module(mod_name)")
  lines.add("if attr_name:")
  lines.add("    for part in attr_name.split(\".\"):")
  lines.add("        backend = getattr(backend, part)")
  lines.add("build_sdist = getattr(backend, \"build_sdist\")")
  lines.add("produced = build_sdist(dist_dir)")
  lines.add("src = os.path.join(dist_dir, produced)")
  lines.add("if produced != predicted:")
  lines.add("    target = os.path.join(dist_dir, predicted)")
  lines.add("    if os.path.exists(target):")
  lines.add("        os.remove(target)")
  lines.add("    os.rename(src, target)")
  lines.add("    produced = predicted")
  lines.add("print(\"sdist:\", produced, file=sys.stderr)")
  result = lines.join("\n") & "\n"

proc renderInstallerHookScript(installDir, wheelPath: string): string =
  ## M20 A5: render the installer hook script. The script:
  ##
  ##   1. Imports ``installer`` (PyPA's reference wheel installer).
  ##   2. Constructs a ``SchemeDictionaryDestination`` pointing every
  ##      sysconfig key at the action's per-member ``install/`` scratch
  ##      dir — ``purelib`` -> ``<install>/site``, ``scripts`` ->
  ##      ``<install>/Scripts`` (Windows) or ``<install>/bin`` (POSIX),
  ##      etc.
  ##   3. **Monkey-patches** ``installer.scripts._SCRIPT_TEMPLATE`` so the
  ##      ``__main__.py`` baked into each launcher.exe prepends the
  ##      install's ``site/`` directory to ``sys.path``. Without this
  ##      patch the produced launchers fail with ``ModuleNotFoundError``
  ##      because nothing in the launcher's environment points Python at
  ##      where the package was unpacked (the standard installer's
  ##      assumption is that ``Scripts/`` is a sibling of ``Lib/
  ##      site-packages/`` under the Python prefix; reprobuild's per-
  ##      member install layout breaks that assumption deliberately to
  ##      keep the artefacts self-contained).
  ##   4. Calls ``installer.install(WheelFile.open(wheel), dest, {})``.
  ##
  ## The patched template encodes the absolute path of the install's
  ## ``site/`` directory as a Python string literal via ``repr()`` (in
  ## Python, not in Nim) so backslashes and embedded spaces are handled
  ## correctly.
  let installDirLit = installDir.replace("\\", "\\\\").replace("\"", "\\\"")
  let wheelPathLit = wheelPath.replace("\\", "\\\\").replace("\"", "\\\"")
  var lines: seq[string] = @[]
  lines.add("import os, sys")
  lines.add("install_dir = \"" & installDirLit & "\"")
  lines.add("wheel_path = \"" & wheelPathLit & "\"")
  lines.add("os.makedirs(install_dir, exist_ok=True)")
  # Compose the per-member scheme. The keys match sysconfig's install-
  # scheme keys (purelib / platlib / headers / scripts / data).
  lines.add("site_dir = os.path.join(install_dir, \"site\")")
  when defined(windows):
    lines.add("scripts_dir = os.path.join(install_dir, \"Scripts\")")
  else:
    lines.add("scripts_dir = os.path.join(install_dir, \"bin\")")
  lines.add("headers_dir = os.path.join(install_dir, \"include\")")
  lines.add("data_dir = os.path.join(install_dir, \"data\")")
  lines.add("scheme = {")
  lines.add("    \"purelib\": site_dir,")
  lines.add("    \"platlib\": site_dir,")
  lines.add("    \"headers\": headers_dir,")
  lines.add("    \"scripts\": scripts_dir,")
  lines.add("    \"data\":    data_dir,")
  lines.add("}")
  # Determine the launcher kind. POSIX uses hashbang scripts; Windows
  # uses the ``installer.scripts`` per-arch launcher templates.
  lines.add("if sys.platform == \"win32\":")
  lines.add("    import platform")
  lines.add("    machine = platform.machine().lower()")
  lines.add("    if machine in (\"amd64\", \"x86_64\"):")
  lines.add("        launcher_kind = \"win-amd64\"")
  lines.add("    elif machine in (\"arm64\", \"aarch64\"):")
  lines.add("        launcher_kind = \"win-arm64\"")
  lines.add("    else:")
  lines.add("        launcher_kind = \"win-ia32\"")
  lines.add("else:")
  lines.add("    launcher_kind = \"posix\"")
  # Monkey-patch the launcher's bundled ``__main__.py`` template so the
  # produced shim can locate its package without any caller-supplied
  # PYTHONPATH. The patched template prepends ``<install>/site`` to
  # ``sys.path`` before importing the entry-point module.
  lines.add("import installer.scripts as _is")
  lines.add("import installer")
  lines.add("from installer.sources import WheelFile")
  lines.add("from installer.destinations import SchemeDictionaryDestination")
  lines.add("_PATCHED_TEMPLATE = (")
  lines.add("    \"# -*- coding: utf-8 -*-\\n\"")
  lines.add("    \"import os, re, sys\\n\"")
  lines.add("    \"sys.path.insert(0, \" + repr(site_dir) + \")\\n\"")
  lines.add("    \"from {module} import {import_name}\\n\"")
  lines.add("    \"if __name__ == \\\"__main__\\\":\\n\"")
  lines.add("    \"    sys.argv[0] = re.sub(r\\\"(-script\\\\.pyw|\\\\.exe)?$\\\", \\\"\\\", sys.argv[0])\\n\"")
  lines.add("    \"    sys.exit({func_path}())\\n\"")
  lines.add(")")
  lines.add("_is._SCRIPT_TEMPLATE = _PATCHED_TEMPLATE")
  lines.add("dest = SchemeDictionaryDestination(")
  lines.add("    scheme_dict=scheme,")
  lines.add("    interpreter=sys.executable,")
  lines.add("    script_kind=launcher_kind,")
  lines.add("    bytecode_optimization_levels=(0,),")
  lines.add("    overwrite_existing=True,")
  lines.add(")")
  lines.add("with WheelFile.open(wheel_path) as source:")
  lines.add("    installer.install(source, dest, {})")
  lines.add("print(\"installed:\", wheel_path, \"->\", install_dir, file=sys.stderr)")
  result = lines.join("\n") & "\n"

proc emitByteCompileActions(projectRoot, pythonExe: string;
                            member: PythonMember;
                            sourceFiles: seq[string]):
                              tuple[actions: seq[BuildActionDef];
                                    pycFiles: seq[string]] =
  ## M20 A1: one byte-compile action per ``.py`` under ``<projectRoot>/src``.
  ## Each action runs ``python3 -m compileall -b -q -f <src.py>``;
  ## ``-b`` writes the ``.pyc`` adjacent to the source (NOT under
  ## ``__pycache__/``), ``-f`` forces recompile so the action's output
  ## existence check is reliable, and ``-q`` keeps the per-file stdout
  ## quiet.
  ##
  ## The output ``<src.py>c`` is declared so the wheel-build action can
  ## consume the bytecode and so the engine's per-action cache fires on
  ## individual source-file edits rather than re-running every byte-
  ## compile when any source under ``src/`` changes.
  let kindTag = case member.kind
    of pmkLibrary: "library"
    of pmkExecutable: "executable"
  for source in sourceFiles:
    let pycPath = source & "c"
    # Path relative to projectRoot for the action ID — keeps the ID
    # stable across cwd changes and short enough to read in logs.
    var rel = source
    if source.startsWith(projectRoot):
      rel = source[projectRoot.len .. ^1]
      while rel.len > 0 and rel[0] in {'/', '\\'}:
        rel = rel[1 .. ^1]
    let argv = @[
      pythonExe,
      "-m", "compileall",
      "-b",  # write <src.py>c adjacent (not under __pycache__/)
      "-q",  # quiet — no per-file stdout
      "-f",  # force recompile (don't trust mtime)
      source,
    ]
    let actionId = "python-byte-compile-" & sanitizeNamePart(member.name) &
      "-" & sanitizeNamePart(rel)
    let action = buildAction(
      id = actionId,
      call = inlineExecCall(argv, projectRoot),
      inputs = @[source],
      outputs = @[pycPath],
      pool = "compile",
      dependencyPolicy = automaticMonitorPolicy(),
      commandStatsId = "python.byte-compile." & kindTag)
    result.actions.add(action)
    result.pycFiles.add(pycPath)

proc emitMemberWheelAction(projectRoot, pythonExe: string;
                           member: PythonMember;
                           info: PythonProjectInfo;
                           sourceInputs: seq[string];
                           pycInputs: seq[string];
                           byteCompileIds: seq[string]):
                             tuple[action: BuildActionDef;
                                   wheelPath: string] =
  ## Emit the wheel-build action for a single ``library``/``executable``
  ## member. M20 wires the per-``.py`` byte-compile actions as
  ## dependencies via ``deps`` (the engine's action-ordering primitive);
  ## the produced ``.pyc`` files are also listed as inputs so the
  ## action's cache fingerprint covers them.
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
  for p in pycInputs:
    inputs.add(p)
  let action = buildAction(
    id = actionId,
    call = inlineExecCall(argv, projectRoot),
    deps = byteCompileIds,
    inputs = inputs,
    outputs = @[wheelPath],
    pool = "compile",
    dependencyPolicy = automaticMonitorPolicy(),
    commandStatsId = statsId)
  (action, wheelPath)

proc emitMemberSdistAction(projectRoot, pythonExe: string;
                           member: PythonMember;
                           info: PythonProjectInfo;
                           sourceInputs: seq[string]):
                             tuple[action: BuildActionDef;
                                   sdistPath: string] =
  ## M20 A4: sdist-build action for a single member. Independent of the
  ## wheel-build action (different PEP 517 hook, different output) so
  ## the two run in parallel on the convention's ``compile`` pool.
  ##
  ## Unlike the wheel action, the sdist action does NOT depend on the
  ## byte-compile sub-graph: an sdist is a source archive and should NOT
  ## carry compiled bytecode (PEP 625 sdist contents are conventionally
  ## the raw source tree plus generated ``PKG-INFO`` metadata).
  let distDir = distDirFor(projectRoot, member.name)
  let sdistFilename = predictedSdistFilename(info)
  let sdistPath = distDir / sdistFilename
  let scriptPath = sdistHookScriptPathFor(projectRoot, member.name)
  createDir(extendedPath(distDir))
  createDir(extendedPath(parentDir(scriptPath)))

  let script = renderSdistHookScript(projectRoot, info.buildBackend, distDir,
    sdistFilename)
  writeFile(extendedPath(scriptPath), script)

  let argv = @[
    pythonExe,
    scriptPath,
  ]
  let actionId = "python-build-sdist-" & sanitizeNamePart(member.name)
  let statsId = case member.kind
    of pmkLibrary: "python.build-sdist.library"
    of pmkExecutable: "python.build-sdist.executable"
  var inputs = sourceInputs
  inputs.add(scriptPath)
  let action = buildAction(
    id = actionId,
    call = inlineExecCall(argv, projectRoot),
    inputs = inputs,
    outputs = @[sdistPath],
    pool = "compile",
    dependencyPolicy = automaticMonitorPolicy(),
    commandStatsId = statsId)
  (action, sdistPath)

proc emitMemberInstallerAction(projectRoot, pythonExe: string;
                               member: PythonMember;
                               info: PythonProjectInfo;
                               wheelPath: string;
                               wheelActionId: string):
                                 tuple[action: BuildActionDef;
                                       launcherPaths: seq[string]] =
  ## M20 A5: emit the installer action that unpacks ``wheelPath`` into
  ## ``<scratch>/<member>/install/`` and materialises the runnable
  ## console-script launcher(s). Output paths declare every launcher
  ## listed under ``[project.scripts]`` so the engine's output-existence
  ## check fires per-launcher.
  ##
  ## The action depends on the wheel-build action via ``deps`` (the
  ## wheel is its input) and on the byte-compile actions transitively
  ## (the wheel-build action itself depends on them).
  let installDir = installDirFor(projectRoot, member.name)
  let scriptPath = installerHookScriptPathFor(projectRoot, member.name)
  let launcherDir = installDir / launcherSubdir()
  createDir(extendedPath(installDir))
  createDir(extendedPath(parentDir(scriptPath)))

  let script = renderInstallerHookScript(installDir, wheelPath)
  writeFile(extendedPath(scriptPath), script)

  var launcherPaths: seq[string] = @[]
  for entry in info.consoleScripts:
    launcherPaths.add(launcherDir / launcherFilename(entry.name))

  let argv = @[
    pythonExe,
    scriptPath,
  ]
  let actionId = "python-install-wheel-" & sanitizeNamePart(member.name)
  let statsId = case member.kind
    of pmkLibrary: "python.install-wheel.library"
    of pmkExecutable: "python.install-wheel.executable"
  let action = buildAction(
    id = actionId,
    call = inlineExecCall(argv, projectRoot),
    deps = @[wheelActionId],
    inputs = @[wheelPath, scriptPath],
    outputs = launcherPaths,
    pool = "compile",
    dependencyPolicy = automaticMonitorPolicy(),
    commandStatsId = statsId)
  (action, launcherPaths)

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

proc pythonCrudeFallback(projectRoot: string;
                         request: ProviderGraphRequest;
                         info: PythonProjectInfo):
                           GraphFragment {.gcsafe.} =
  ## M24: Mode B emitter for Python projects whose ``[build-system]
  ## .build-backend`` is in the ``ModeBBackends`` catalog (maturin,
  ## scikit-build-core, poetry-core, pdm-backend, uv_build). Delegates
  ## to ``python -m build --wheel --no-isolation`` under io-monitor
  ## monitoring per the M6 spec.
  ##
  ## **Design decision — why ``python -m build --wheel --no-isolation``
  ## over ``python -m pip wheel --no-build-isolation --no-deps .``**:
  ##
  ##   * ``python -m build`` is the PyPA-blessed PEP 517 frontend
  ##     (vendored as the ``build`` distribution on PyPI). It is the
  ##     intended frontend for direct backend invocation — pip is the
  ##     installer-frontend and treats wheel-building as an
  ##     internal-implementation detail of ``pip install <sdist>``.
  ##   * ``--no-isolation`` makes ``build`` skip the implicit
  ##     ``venv + pip install build-backend`` dance and use the
  ##     ambient Python's already-installed backend. This is what we
  ##     want under Reprobuild: the dev environment is expected to
  ##     have already provisioned the configured backend (maturin /
  ##     scikit-build-core / poetry-core / pdm-backend / uv) — a venv
  ##     spun up per build would re-install it on every invocation.
  ##   * ``--wheel`` restricts to wheel output (skip sdist). The Mode A
  ##     path emits both wheel + sdist actions but the Mode B path
  ##     prioritises the runnable wheel because that's the load-bearing
  ##     artefact for downstream consumers and Mode B's headline goal
  ##     ("graceful handling, ANY working artefact") doesn't require
  ##     sdist parity.
  ##
  ## ``python -m pip wheel --no-build-isolation --no-deps .`` is the
  ## documented fallback for hosts that don't ship ``build`` — same
  ## end-state (a ``.whl`` under ``dist/`` or a configured output dir)
  ## but the wheel landing path is less predictable (pip writes to the
  ## CWD by default; ``-w`` can redirect). We pick ``python -m build``
  ## here because every supported dev environment already includes the
  ## ``build`` distribution alongside the backend.
  ##
  ## The wheel lands under ``<projectRoot>/dist/`` (``python -m build``
  ## default). The crude fragment declares ``dist`` as an opaque output
  ## directory and the project root as the input root; io-monitor
  ## promotes any read/written file the backend touches at runtime.
  {.cast(gcsafe).}:
    let pythonExe = pythonExecutable()
    if pythonExe.len == 0:
      raise newException(ValueError,
        "python convention: neither 'python3' nor 'python' on PATH; " &
          "cannot run the Mode B 'python -m build' frontend")
    var packageName = info.distributionName
    if packageName.len > 0:
      packageName = normalizeDistName(packageName)
    if packageName.len == 0:
      packageName = projectRoot.extractFilename
    if packageName.len == 0:
      packageName = "python-crude"
    let argv = @[
      pythonExe,
      "-m",
      "build",
      "--wheel",
      "--no-isolation",
    ]
    result = emitCrudeFragment(
      projectRoot = projectRoot,
      request = request,
      packageName = packageName,
      nativeBuildArgv = argv,
      outputDirs = ["dist"])

proc pythonEmitFragment(projectRoot: string;
                        request: ProviderGraphRequest):
                          GraphFragment {.gcsafe.} =
  ## Convention entry — parse pyproject.toml, enumerate the package's
  ## members, emit per-member action sub-graphs covering byte-compile +
  ## wheel + sdist + (when applicable) installer, then hand the whole
  ## thing to ``buildPackageFragment``.
  ##
  ## **M24 routing**: when the project's ``[build-system].build-backend``
  ## is in the Mode B catalog (maturin / scikit-build-core /
  ## poetry-core / pdm-backend / uv_build), delegate to
  ## ``pythonCrudeFallback`` rather than emit the Mode A sub-graph.
  ##
  ## The DSL runtime mutates module-level registries that aren't annotated
  ## ``gcsafe`` (they predate the provider host). Same shape as the
  ## Nim/Rust/Go conventions' ``cast(gcsafe)`` escape hatch.
  {.cast(gcsafe).}:
    let source = readReprobuildSource(projectRoot)
    let members = extractMembers(source)
    if members.len == 0:
      let projectMatch = resolveProjectFile(projectRoot)
      let projectFile =
        if projectMatch.path.len > 0: projectMatch.path
        else: projectRoot / LegacyProjectFileName
      raise newException(ValueError,
        "python convention: no library or executable members declared " &
          "in " & projectFile)
    let info = parsePyprojectToml(projectRoot / "pyproject.toml")
    if info.distributionName.len == 0:
      raise newException(ValueError,
        "python convention: pyproject.toml has no [project].name field " &
          "(under " & projectRoot & ")")
    if info.version.len == 0:
      raise newException(ValueError,
        "python convention: pyproject.toml has no [project].version " &
          "field (under " & projectRoot & ")")
    # M24 Mode B routing: maturin / scikit-build-core / poetry-core /
    # pdm-backend / uv_build all need their own toolchains (Rust
    # compiler, CMake, etc.) and have manifest shapes that don't
    # reduce cleanly to the four PEP 517 hooks Mode A drives.
    # Delegate to the crude fallback which calls ``python -m build``.
    if isModeBBackend(info.buildBackend):
      return pythonCrudeFallback(projectRoot, request, info)
    if not isSupportedBackend(info.buildBackend):
      raise newException(ValueError,
        "python convention: unsupported [build-system].build-backend '" &
          info.buildBackend & "' (recognised: hatchling.build / " &
          "flit_core.buildapi / setuptools.build_meta or one of the " &
          "Mode B backends: maturin / scikit_build_core.build / " &
          "poetry.core.masonry.api / pdm.backend / uv_build)")
    let pythonExe = pythonExecutable()
    if pythonExe.len == 0:
      raise newException(ValueError,
        "python convention: neither 'python3' nor 'python' on PATH; " &
          "cannot run the PEP 517 build_wheel hook")
    let pkg = syntheticPackage(projectRoot, members, info)
    let sourceInputs = collectSourceInputs(projectRoot)
    let pySources = collectPySourceFiles(projectRoot)
    let registerAll = proc() =
      discard buildPool("compile", 8'u32)
      var allActions: seq[BuildActionDef] = @[]
      for member in members:
        # A1: per-``.py`` byte-compile actions.
        let byteCompile = emitByteCompileActions(projectRoot, pythonExe,
          member, pySources)
        var byteCompileIds: seq[string] = @[]
        for action in byteCompile.actions:
          byteCompileIds.add(action.id)
          allActions.add(action)
        # A3: wheel build (depends on the byte-compile sub-graph so the
        # produced wheel includes the per-source ``.pyc`` siblings).
        let wheel = emitMemberWheelAction(projectRoot, pythonExe, member,
          info, sourceInputs, byteCompile.pycFiles, byteCompileIds)
        allActions.add(wheel.action)
        # A4: sdist build (parallel to wheel; independent action graph).
        let sdist = emitMemberSdistAction(projectRoot, pythonExe, member,
          info, sourceInputs)
        allActions.add(sdist.action)
        # A5: console-script wrapper shim — emitted only when the
        # package's ``[project.scripts]`` is non-empty AND the member is
        # an executable. Library members don't get an installer action
        # even if the project happens to declare console-scripts —
        # those scripts belong to the executable member's launcher set.
        if info.consoleScripts.len > 0 and member.kind == pmkExecutable:
          let installer = emitMemberInstallerAction(projectRoot, pythonExe,
            member, info, wheel.wheelPath, wheel.action.id)
          allActions.add(installer.action)
      # Per-member target aliases remain deferred (M20 doesn't change the
      # alias surface): the engine's graph linker still rejects
      # "single-action target N + single-action target default both
      # pointing at the same action" as a duplicate-alias error. M20
      # graduates the per-member graph to multi-action (byte-compile +
      # wheel + sdist [+ installer]) so the duplicate-alias hazard goes
      # away in principle, but ``default`` alone remains sufficient for
      # the M9 harness which builds ``#default``.
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
