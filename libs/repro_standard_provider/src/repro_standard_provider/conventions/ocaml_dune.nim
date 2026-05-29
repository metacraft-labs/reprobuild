## OCaml / Dune language convention (Tier 2b) — M46.
##
## Fifth managed-ecosystem standard-provider convention after the M40
## ``java-maven``, M41 ``kotlin-gradle``, M42 ``csharp-dotnet`` and M43
## ``swift-swiftpm`` siblings. Recognises a ``dune-project`` at the
## project root and shells out to the stock ``dune`` driver for a single
## ``dune build --release`` invocation. The action graph is intentionally
## coarse: one build action that produces ``_build/default/<entry-dir>/
## <name>.exe`` per declared executable and
## ``_build/default/<entry-dir>/<name>.cmxa`` per declared library.
##
## **Distinction from a hypothetical future Tier 2c OCaml provider.**
## A Tier 2c OCaml provider would re-implement Dune's per-module
## dep-ordering + module-aliasing heuristics and lift individual
## ``ocamlfind ocamlopt`` invocations into the reprobuild DAG. That
## heavyweight path is explicitly DEFERRED per the M46 spec — Dune's
## heuristics are non-trivial to re-implement. M46 is strictly the
## lightweight Mode 2 ecosystem-delegation sibling.
##
## **Recognition contract**:
##   * ``<projectRoot>/dune-project`` — the Dune project manifest. The
##     presence of this file is the Dune project signal; no other
##     standard-provider convention recognises this filename, so the gate
##     is unambiguous.
##   * ``<projectRoot>/repro.nim`` (or legacy ``reprobuild.nim``) exists
##     AND ``uses:`` lists BOTH ``ocaml`` (or ``ocamlc``/``ocamlopt``/
##     ``ocamlfind``) AND ``dune`` (the HARD precondition — mirrors M40's
##     "both halves required" pattern; Dune isn't a built-in part of the
##     OCaml distribution, it's a separate ``opam install dune`` and the
##     convention won't dispatch unless both are declared).
##   * at least one ``executable`` or ``library`` member declared.
##   * an ``ocaml`` driver is on PATH.
##   * a ``dune`` driver is on PATH.
##
## **Offline mode** (M46 keeps builds hermetic — Dune itself defaults to
## not reaching the network for its build step; only ``dune build`` is
## invoked, not ``dune subst`` or ``dune install`` which can fetch).
##   * The action runs ``dune build --release -j 1``. The ``-j 1``
##     pin keeps the build deterministic (no race between parallel
##     module-compile jobs) at a small wall-clock cost; the convention
##     prefers determinism for the M46 fixture-and-test surface. A
##     follow-up M may flip this to ``-j auto`` for larger projects.
##   * Real-world projects pulling external opam dependencies should
##     run ``opam install --deps-only .`` once with network access
##     BEFORE invoking the convention to populate the opam switch with
##     the resolved packages. The convention itself never reaches the
##     network.
##   * The M46 fixture is stdlib-only (no external opam dependencies)
##     so no provisioning warm step is required for the fixture; the
##     convention can be exercised end-to-end without provisioning
##     external deps.
##
## **Emitted actions**:
##   1. ``ocaml-dune-build`` — single ``<dune> build --release -j 1``
##      action under the project root. Inputs: ``dune-project`` plus
##      every ``dune`` file recursively walked AND every ``.ml``/
##      ``.mli`` source file recursively walked under the project root
##      (excluding ``_build/`` / ``.repro/`` / ``.git/``). Outputs: one
##      ``_build/default/<entry-dir>/<name>.exe`` per declared executable
##      and ``_build/default/<entry-dir>/<name>.cmxa`` per declared
##      library. Uses ``declaredOnlyDependencyPolicy`` — ``dune build``
##      spawns ``ocamlopt`` / ``ocamldep`` worker processes whose FS
##      reads aren't reliably observed via Windows DLL-interpose (same
##      constraint M38 / M39 / M40 / M41 / M42 / M43 face for their
##      configure / package / build actions).
##
## **Output paths**:
##   * Executable: ``<projectRoot>/_build/default/<entry-dir>/<name>.exe``.
##     Dune's release build writes the produced native-code executable
##     under ``_build/default/<containing-dir-of-dune-file>/<name>.exe``
##     on all platforms (Dune normalises the suffix to ``.exe`` on Windows
##     and emits a no-suffix binary on POSIX — but the ``.exe`` form is
##     also produced as an alias on POSIX since Dune 3.x). The convention
##     emits BOTH the ``.exe`` and the bare paths for executables so the
##     OS-specific predicted path matches whichever Dune lays down.
##   * Library: ``<projectRoot>/_build/default/<entry-dir>/<name>.cmxa``.
##     Dune's release build writes the native-code library archive at
##     this path. ``.cma`` (bytecode) is also produced by default but
##     the convention treats ``.cmxa`` as the primary library artefact
##     (matching the ``--release`` mode's native-code focus).
##   * **Entry-dir resolution**: the convention searches for the FIRST
##     ``dune`` file under the project root (excluding ``_build/``) and
##     uses its containing directory as the entry-dir. If the ``dune``
##     file is at the root the entry-dir is the root itself
##     (``_build/default/<name>.exe``); if at ``src/``, the entry-dir
##     is ``src`` (``_build/default/src/<name>.exe``); etc. M46
##     intentionally supports a single-dune-file layout — multi-target
##     dune projects with multiple dune files in different directories
##     are DEFERRED.
##
## **Honest scope** (deferred per M46 spec):
##   * Mode 3 OCaml — explicitly DEFERRED. The per-source
##     ``ocamlfind ocamlopt`` story requires re-implementing Dune's
##     dep-ordering and module-aliasing heuristics. Track as a future
##     milestone if demand surfaces.
##   * Multi-target dune projects (multiple ``dune`` files in
##     different directories with different members) — DEFERRED. M46
##     pins to a single-package-per-project shape; the first ``dune``
##     file found drives the entry-dir resolution.
##   * Cross-language with C (``CAMLprim`` FFI). A future milestone
##     would add this as a separate cross-lang convention.
##   * opam-managed external dependencies — the convention assumes the
##     opam switch is pre-populated. A future M may add a
##     ``packages.lock``-style hard precondition mirroring M42's
##     ``packages.lock.json`` requirement.
##   * ``dune test`` discovery — deferred to a follow-up M (mirrors
##     M40 / M41 / M42 / M43 deferral of test-task discovery).
##   * Subprojects (``(subproject ...)``) — deferred.
##   * Bytecode-only builds (``.cma`` instead of ``.cmxa``) — the
##     convention pins ``--release`` which builds native code.
##
## **Provisioning note**: on a development host that doesn't ship OCaml
## + Dune (the M46 default on Windows — the dev shell doesn't currently
## bundle OCaml), the supported install paths are:
##   * OPAM Windows from ocaml.org (``opam-2.x.y.exe`` Windows installer)
##     unpacked under ``D:/metacraft-dev-deps/opam/`` (manual download
##     is the canonical Windows path for the dev shell).
##   * Dune installed via ``opam install dune`` after the switch is
##     initialised with ``opam init -y --bare`` + ``opam switch create
##     <version>``.
## env.ps1 should then prepend the opam switch's ``bin/`` directory
## (typically ``%LOCALAPPDATA%\opam\<switch>\bin``) to PATH so ``ocaml``
## and ``dune`` resolve via PATH (a follow-up provisioning milestone
## covers the full catalog work).
##
## See ``reprobuild-specs/Mode3-Language-Expansion.milestones.org`` §M46.

import std/[algorithm, os, strutils]

import repro_core
import repro_provider_runtime
import repro_project_dsl
import repro_standard_provider/convention

const
  ScratchDirName* = ".repro/build"
    ## Top-level scratch directory under the project root. Identical to
    ## the M40 / M41 / M42 / M43 conventions' value, but M46 doesn't
    ## actually use it as a build dir — Dune writes to
    ## ``<projectRoot>/_build/`` (its own convention). The constant is
    ## retained for consistency.

  DuneBuildSubdir* = "_build"
    ## Sub-directory under the project root where Dune lays its build
    ## outputs. Hard-coded by Dune (configurable via ``--build-dir`` but
    ## not exercised by M46); the convention predicts the
    ## ``_build/default/`` path under it.

  DuneDefaultSubdir* = "default"
    ## Sub-directory under ``_build/`` for the default context. Dune
    ## supports named contexts via ``(context ...)`` in
    ## ``dune-project``; M46 assumes the default context which is the
    ## near-universal case.

type
  OcamlDuneMemberKind = enum
    odmExecutable
    odmLibrary

  OcamlDuneMember = object
    name: string
    kind: OcamlDuneMemberKind

proc readReprobuildSource(projectRoot: string): string =
  ## Read the project file (``repro.nim`` or legacy ``reprobuild.nim``)
  ## or return the empty string. See ``repro_core/project_file``.
  let match = resolveProjectFile(projectRoot)
  if match.path.len == 0:
    return ""
  try:
    readFile(extendedPath(match.path))
  except CatchableError:
    ""

proc usesIncludesOcamlDune(source: string): bool =
  ## True when ``uses:`` lists BOTH an OCaml-driver token AND ``dune``.
  ## The convention is conservative — it requires both halves (mirrors
  ## M40 ``java-maven``'s strict pattern). Recognised OCaml tokens:
  ## ``ocaml`` / ``ocamlc`` / ``ocamlopt`` / ``ocamlfind`` (any one of
  ## the four counts as the compiler signal). The ``dune`` token is
  ## strictly required separately because Dune isn't a built-in part
  ## of the OCaml distribution — it's a separate ``opam install dune``
  ## and the convention won't dispatch unless both are declared.
  if source.len == 0:
    return false
  var sawOcaml = false
  var sawDune = false
  var inBlock = false
  proc consume(token: string) {.closure.} =
    if token == "ocaml" or token == "ocamlc" or token == "ocamlopt" or
        token == "ocamlfind":
      sawOcaml = true
    if token == "dune":
      sawDune = true
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
          consume(firstToken)
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
          consume(firstToken)
  sawOcaml and sawDune

proc extractExecutables(source: string): seq[string] =
  for rawLine in source.splitLines():
    var line = rawLine
    let commentIdx = line.find('#')
    if commentIdx >= 0:
      line = line[0 ..< commentIdx]
    let stripped = line.strip()
    if not stripped.startsWith("executable"):
      continue
    if stripped.len > len("executable") and
        stripped[len("executable")] notin {' ', '\t'}:
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

proc extractMembers(source: string): seq[OcamlDuneMember] =
  for name in extractExecutables(source):
    result.add(OcamlDuneMember(name: name, kind: odmExecutable))
  for name in extractLibraries(source):
    result.add(OcamlDuneMember(name: name, kind: odmLibrary))

proc hasDuneProject(projectRoot: string): bool =
  ## True when ``<projectRoot>/dune-project`` exists. This is the Dune
  ## project manifest signal — uniquely identifies a Dune project (no
  ## other convention recognises this filename).
  fileExists(extendedPath(projectRoot / "dune-project"))

proc ocamlExecutable(): string =
  ## Resolve an ``ocaml`` driver on PATH. On Windows the binary is
  ## usually ``ocaml.exe``; ``findExe`` resolves both shapes via
  ## PATHEXT.
  findExe("ocaml")

proc duneExecutable(): string =
  ## Resolve a ``dune`` driver on PATH. On Windows the binary is
  ## usually ``dune.exe``; ``findExe`` resolves both shapes via
  ## PATHEXT.
  findExe("dune")

proc findDuneEntryDir*(projectRoot: string): string =
  ## Locate the directory containing the FIRST ``dune`` file under
  ## ``projectRoot`` (excluding ``_build/`` / ``.repro/`` / ``.git/``).
  ## The walk is depth-first — root first, then ``src/``, ``bin/`` ...
  ## Returns the absolute path of the containing directory (which is
  ## ``projectRoot`` itself when the dune file is at the root). Returns
  ## the empty string when no ``dune`` file is found.
  if not dirExists(extendedPath(projectRoot)):
    return ""
  # First check root.
  if fileExists(extendedPath(projectRoot / "dune")):
    return projectRoot
  # Then walk subdirs (single-pass BFS, skipping noise dirs).
  proc shouldSkipDir(name: string): bool =
    let lower = name.toLowerAscii
    lower in ["_build", ".repro", ".git", "node_modules"]
  var queue: seq[string] = @[]
  try:
    for kind, path in walkDir(projectRoot):
      let basename = extractFilename(path)
      case kind
      of pcDir, pcLinkToDir:
        if not shouldSkipDir(basename):
          queue.add(path)
      else:
        discard
  except OSError:
    return ""
  queue.sort(system.cmp[string])
  while queue.len > 0:
    let cur = queue[0]
    queue.delete(0)
    if fileExists(extendedPath(cur / "dune")):
      return cur
    try:
      var subdirs: seq[string] = @[]
      for kind, path in walkDir(cur):
        let basename = extractFilename(path)
        case kind
        of pcDir, pcLinkToDir:
          if not shouldSkipDir(basename):
            subdirs.add(path)
        else:
          discard
      subdirs.sort(system.cmp[string])
      for sd in subdirs:
        queue.add(sd)
    except OSError:
      discard
  ""

proc ocamlDuneRecognize(projectRoot: string;
                        request: ProviderGraphRequest): bool {.gcsafe.} =
  ## Recognition contract — see module docstring.
  if not hasDuneProject(projectRoot):
    return false
  let source = readReprobuildSource(projectRoot)
  if source.len == 0:
    return false
  if not usesIncludesOcamlDune(source):
    return false
  let members = extractMembers(source)
  if members.len == 0:
    return false
  if ocamlExecutable().len == 0:
    return false
  if duneExecutable().len == 0:
    return false
  true

proc sanitizeNamePart(value: string): string =
  for ch in value:
    if ch in {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '-', '_', '.'}:
      result.add(ch)
    else:
      result.add('_')
  if result.len == 0:
    result = "x"

proc relEntryDirFromRoot(projectRoot, entryDir: string): string =
  ## Compute the relative path of ``entryDir`` under ``projectRoot``.
  ## Returns the empty string when entryDir is the project root (so
  ## the produced ``_build/default/<rel>/<name>.exe`` collapses to
  ## ``_build/default/<name>.exe``).
  if entryDir.len == 0 or entryDir == projectRoot:
    return ""
  let rootNorm = projectRoot.replace('\\', '/')
  let entryNorm = entryDir.replace('\\', '/')
  if entryNorm.startsWith(rootNorm & "/"):
    return entryNorm[rootNorm.len + 1 .. ^1]
  # Fallback: take the last path component (defensive — shouldn't hit
  # for findDuneEntryDir results).
  extractFilename(entryDir)

proc producedExecutablePath*(projectRoot, entryRel, targetName: string): string =
  ## Predicted output path for a Dune executable target. Dune's
  ## ``--release`` build writes the executable into
  ## ``_build/default/<entryRel>/<targetName>.exe`` on all platforms
  ## (Dune normalises the ``.exe`` suffix even on POSIX as of Dune 3.x;
  ## a bare-suffix file is ALSO produced on POSIX but ``.exe`` is the
  ## stable predicted form across platforms).
  ##
  ## When ``entryRel`` is empty (the dune file lives at the project
  ## root), the path collapses to ``_build/default/<targetName>.exe``.
  let exeName = targetName & ".exe"
  if entryRel.len == 0:
    projectRoot / DuneBuildSubdir / DuneDefaultSubdir / exeName
  else:
    projectRoot / DuneBuildSubdir / DuneDefaultSubdir / entryRel / exeName

proc producedLibraryPath*(projectRoot, entryRel, targetName: string): string =
  ## Predicted output path for a Dune library target. Dune's
  ## ``--release`` build writes the native-code archive at
  ## ``_build/default/<entryRel>/<targetName>.cmxa`` (the OCaml
  ## native-code library extension; ``.cma`` is the bytecode form which
  ## Dune also produces but the convention pins on ``.cmxa`` as the
  ## primary artefact in release mode).
  ##
  ## When ``entryRel`` is empty the path collapses to
  ## ``_build/default/<targetName>.cmxa``.
  let libName = targetName & ".cmxa"
  if entryRel.len == 0:
    projectRoot / DuneBuildSubdir / DuneDefaultSubdir / libName
  else:
    projectRoot / DuneBuildSubdir / DuneDefaultSubdir / entryRel / libName

proc collectOcamlInputs(projectRoot: string): seq[string] =
  ## Conservative input enumeration for the build action: the
  ## ``dune-project`` manifest plus every ``dune`` file recursively
  ## walked plus every ``.ml`` / ``.mli`` source file recursively walked
  ## under the project root (excluding ``_build/`` / ``.repro/`` /
  ## ``.git/``). Dune-controlled subdirectories like ``_build/`` MUST
  ## be skipped — they hold generated artefacts that change every build
  ## and would cause spurious cache misses if enumerated as inputs.
  if not dirExists(extendedPath(projectRoot)):
    return @[]
  let manifestPath = projectRoot / "dune-project"
  if fileExists(extendedPath(manifestPath)):
    result.add(manifestPath)
  proc shouldSkipDir(name: string): bool =
    let lower = name.toLowerAscii
    lower in ["_build", ".repro", ".git", "node_modules"]
  var stack: seq[string] = @[projectRoot]
  while stack.len > 0:
    let cur = stack[^1]
    stack.setLen(stack.len - 1)
    try:
      for kind, path in walkDir(cur):
        let basename = extractFilename(path)
        case kind
        of pcFile, pcLinkToFile:
          let lower = basename.toLowerAscii
          if lower == "dune" or lower.endsWith(".ml") or
              lower.endsWith(".mli"):
            result.add(path)
        of pcDir, pcLinkToDir:
          if shouldSkipDir(basename):
            continue
          stack.add(path)
    except OSError:
      discard
  # De-dup while preserving order.
  var seen: seq[string] = @[]
  for path in result:
    if path notin seen:
      seen.add(path)
  result = seen
  result.sort(system.cmp[string])

proc emitBuildAction(projectRoot, duneExe, entryRel: string;
                     members: seq[OcamlDuneMember]): BuildActionDef =
  ## Emit the single ``dune build --release -j 1`` action. Outputs the
  ## predicted ``_build/default/<entryRel>/<target>.exe`` path under the
  ## project root for each declared executable, plus
  ## ``_build/default/<entryRel>/<target>.cmxa`` for each declared
  ## library.
  ##
  ## ``--release`` builds native code in release configuration (no
  ## debug symbols, optimised). ``-j 1`` keeps the build deterministic
  ## (single-threaded compile) at a small wall-clock cost; a follow-up
  ## M may flip to ``-j auto`` for larger projects.
  var outputs: seq[string] = @[]
  for m in members:
    case m.kind
    of odmExecutable:
      outputs.add(producedExecutablePath(projectRoot, entryRel, m.name))
    of odmLibrary:
      outputs.add(producedLibraryPath(projectRoot, entryRel, m.name))
  if outputs.len > 0:
    createDir(extendedPath(parentDir(outputs[0])))
  let argv = @[duneExe, "build", "--release", "-j", "1"]
  let inputs = collectOcamlInputs(projectRoot)
  buildAction(
    id = "ocaml-dune-build",
    call = inlineExecCall(argv, projectRoot),
    inputs = inputs,
    outputs = outputs,
    pool = "compile",
    # ``dune build`` spawns ``ocamlopt`` / ``ocamldep`` worker
    # processes whose FS reads aren't reliably observed via the Windows
    # DLL-interpose path. Same constraint M38/M39/M40/M41/M42/M43 face
    # for their configure / package / build actions. Enumerate inputs
    # explicitly via ``collectOcamlInputs`` so per-source invalidation
    # still works without monitoring.
    dependencyPolicy = declaredOnlyDependencyPolicy(),
    commandStatsId = "ocaml-dune.build")

proc syntheticPackage(projectRoot: string;
                     members: seq[OcamlDuneMember]): PackageDef =
  var name = "ocaml_dune_convention"
  if members.len > 0:
    name = sanitizeNamePart(members[0].name)
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

proc ocamlDuneEmitFragment(projectRoot: string;
                           request: ProviderGraphRequest):
                             GraphFragment {.gcsafe.} =
  ## Convention entry — emit the single build action, hand the bundle
  ## to ``buildPackageFragment``.
  {.cast(gcsafe).}:
    let source = readReprobuildSource(projectRoot)
    let members = extractMembers(source)
    if members.len == 0:
      let projectMatch = resolveProjectFile(projectRoot)
      let projectFile =
        if projectMatch.path.len > 0: projectMatch.path
        else: projectRoot / LegacyProjectFileName
      raise newException(ValueError,
        "ocaml-dune convention: no executable or library members " &
          "declared in " & projectFile)
    if ocamlExecutable().len == 0:
      raise newException(ValueError,
        "ocaml-dune convention: no 'ocaml' on PATH (OCaml toolchain " &
          "required; install OPAM Windows from ocaml.org into " &
          "D:/metacraft-dev-deps/opam/ and then 'opam install dune')")
    let duneExe = duneExecutable()
    if duneExe.len == 0:
      raise newException(ValueError,
        "ocaml-dune convention: no 'dune' on PATH (Dune build system " &
          "required; install via 'opam install dune' after OPAM init)")
    if not hasDuneProject(projectRoot):
      raise newException(ValueError,
        "ocaml-dune convention: no 'dune-project' at project root " &
          projectRoot)
    let entryDir = findDuneEntryDir(projectRoot)
    if entryDir.len == 0:
      raise newException(ValueError,
        "ocaml-dune convention: no 'dune' file found under project " &
          "root " & projectRoot & " (expected at least one 'dune' file " &
          "to drive the entry-dir resolution; M46 supports a " &
          "single-dune-file layout — multi-target dune projects with " &
          "multiple dune files in different directories are deferred)")
    let entryRel = relEntryDirFromRoot(projectRoot, entryDir)
    let pkg = syntheticPackage(projectRoot, members)
    let registerAll = proc() =
      discard buildPool("compile", 8'u32)
      let buildAct = emitBuildAction(projectRoot, duneExe, entryRel,
        members)
      defaultTarget(target("default", @[buildAct]))
    result = buildPackageFragment(pkg, request, registerAll,
      includeDefault = false)

proc ocamlDuneConvention*(): LanguageConvention =
  ## The single value the standard provider binary registers at startup.
  LanguageConvention(
    name: "ocaml-dune",
    recognize: ocamlDuneRecognize,
    emitFragment: ocamlDuneEmitFragment)
