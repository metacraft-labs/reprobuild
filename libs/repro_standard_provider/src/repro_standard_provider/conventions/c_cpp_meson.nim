## C / C++ (Meson) language convention (Tier 2b) — M39.
##
## Sibling of the M38 ``c-cpp-cmake`` Tier 2b convention. Recognises a
## ``meson.build`` at the project root and shells out to a stock
## ``meson`` binary for ``setup`` + per-target ``compile``. The action
## graph is coarse (one configure action + one per-target build
## action), but the convention works on any project whose
## ``meson.build`` parses with stock Meson — no forked generator
## required.
##
## **Distinction from a hypothetical future Tier 2c Meson provider.**
## A Tier 2c Meson provider (mirroring ``apps/repro-cmake-trycompile-
## provider.exe``) would parse Meson's introspection output and lift
## individual targets / per-source compile commands into the reprobuild
## DAG. That heavyweight path is not in scope here; M39 ships the
## lightweight Mode 2 ecosystem-delegation sibling.
##
## **Recognition contract**:
##   * ``<projectRoot>/meson.build`` exists.
##   * NO ``CMakeLists.txt`` at the project root (CMake territory —
##     ``c-cpp-cmake`` Tier 2b's job; in any case the CMake convention
##     is registered FIRST and would already have claimed the project).
##   * NO ``configure.ac`` / ``Makefile.am`` at the project root
##     (Autotools territory).
##   * ``<projectRoot>/repro.nim`` (or legacy ``reprobuild.nim``) exists
##     AND ``uses:`` lists ``meson`` AND a C compiler
##     (``gcc`` / ``clang``).
##   * at least one ``executable`` or ``library`` member declared.
##   * a C compiler is on PATH.
##   * ``meson`` is on PATH.
##   * ``ninja`` is on PATH. Meson's default backend is Ninja
##     (single-config, cross-platform); the convention does not attempt
##     to negotiate the ``vs`` / ``xcode`` multi-config backends.
##
## **Backend choice** (M39 forces single-config to keep output paths
## predictable):
##   * Always invoke ``meson setup`` with the default ``ninja`` backend.
##     This matches Meson's out-of-the-box behaviour on Linux + macOS +
##     Windows.
##   * Multi-config backends (``vs2017`` / ``vs2019`` / ``vs2022`` /
##     ``xcode``) are deferred. Like the CMake convention's multi-config
##     deferral, they place artefacts under ``<buildtype>/<name>`` which
##     complicates output-path declaration.
##
## **Emitted actions**:
##   1. ``ccpp-meson-configure`` — ``meson setup <scratch> <root>
##      --buildtype=release``. Inputs include the root ``meson.build``
##      plus every other ``meson.build`` / ``meson.options`` /
##      ``meson_options.txt`` file under the project tree, plus every
##      source file we can statically observe under ``src/`` /
##      ``include/``. Outputs include the build dir's
##      ``build.ninja`` + a custom stamp so the action's success is
##      recorded independently of Meson's internal touch behaviour.
##      Uses ``automaticMonitorPolicy`` (automatic monitoring is the spec
##      baseline for opaque tools, Reprobuild-Development M17): like the
##      cmake convention, the configure step spawns a fan-out of
##      subprocesses and the engine monitors their real read-set instead
##      of trusting only statically declared inputs.
##   2. ``ccpp-meson-build-<member>`` — one per declared member:
##      ``meson compile -C <scratch> <member>``. Deps:
##      ``ccpp-meson-configure``. Outputs: the produced binary or
##      static archive at the predicted path under ``<scratch>``.
##
## **Output paths** (Ninja backend, GCC/Clang archiver convention):
##   * Executable: ``<scratch>/<member>[.exe]``.
##     Meson lays the produced binary at the build dir root by default
##     (subdir-of-meson.build under multi-directory projects; the M39
##     fixture is single-directory so this lands at ``<scratch>/<member>``).
##   * Static library: ``<scratch>/lib<member>.a``. Meson's default
##     static library naming on GNU toolchains is ``lib<name>.a``;
##     MSVC-style ``<member>.lib`` is deferred to a multi-config follow-
##     up.
##
## **Honest scope** (deferred):
##   * Per-source lift via parsing the generated ``build.ninja`` — a
##     hypothetical Tier 2c Meson provider's job.
##   * Multi-config backends (``vs*`` / ``xcode``).
##   * Shared libraries (``library('foo', ..., type: 'shared')``).
##   * ``subproject()`` / ``wrap`` files — these can hit the network at
##     configure time. The M39 convention accepts the io-monitor but
##     doesn't try to sandbox the network fetch.
##   * ``test()`` discovery via ``meson test`` (M22-style test target
##     deferred — the crude fallback still covers it).
##   * ``install()`` target.
##
## See ``reprobuild-specs/Mode3-Language-Expansion.milestones.org`` §M39.

import std/[algorithm, os, strutils]

import repro_core
import repro_provider_runtime
import repro_project_dsl
import repro_standard_provider/convention
import repro_standard_provider/conventions/fetch_action

const
  ScratchDirName* = ".repro/build"
    ## Top-level scratch directory under the project root the Meson
    ## convention writes into. Identical to other conventions'.

  MesonBuildSubdir* = "meson"
    ## Sub-directory under ``<projectRoot>/.repro/build/`` that holds
    ## the Meson build tree (the backend's scratch space). Per-member
    ## outputs land here; the configure action treats the dir as both
    ## its scratch and its output dir.

type
  CCppMesonMemberKind = enum
    ccmsExecutable
    ccmsLibraryStatic

  CCppMesonMember = object
    name: string
    kind: CCppMesonMemberKind

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

proc usesIncludesMeson(source: string): bool =
  ## True when ``uses:`` lists ``meson`` AND a C compiler (``gcc`` or
  ## ``clang``). The convention is conservative — it requires both.
  if source.len == 0:
    return false
  var sawCompiler = false
  var sawMeson = false
  var inBlock = false
  proc consume(token: string) {.closure.} =
    if token == "gcc" or token == "clang":
      sawCompiler = true
    if token == "meson":
      sawMeson = true
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
  sawCompiler and sawMeson

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

proc extractMembers(source: string): seq[CCppMesonMember] =
  for name in extractExecutables(source):
    result.add(CCppMesonMember(name: name, kind: ccmsExecutable))
  for name in extractLibraries(source):
    result.add(CCppMesonMember(name: name, kind: ccmsLibraryStatic))

proc extractFirstPackageName(source: string): string =
  ## DSL-port M9.K: heuristic scan for the first ``package <ident>:``
  ## declaration. The result is the lookup key the convention uses
  ## against the M9.H ``registeredFetchSpec`` and M9.I
  ## ``registeredBuildFlags`` registries (both keyed by the DSL package
  ## name as written in the recipe source).
  ##
  ## Returns the empty string when no ``package`` block can be found
  ## (e.g. legacy recipes that pre-date the M9 surface) — callers then
  ## skip the registry lookups so behaviour stays unchanged.
  for rawLine in source.splitLines():
    var line = rawLine
    let commentIdx = line.find('#')
    if commentIdx >= 0:
      line = line[0 ..< commentIdx]
    let stripped = line.strip()
    if not stripped.startsWith("package"):
      continue
    if stripped.len > len("package") and
        stripped[len("package")] notin {' ', '\t'}:
      continue
    let rest = stripped[len("package") .. ^1].strip()
    if rest.len == 0:
      continue
    var name = ""
    for ch in rest:
      if ch in {' ', '\t', ':', ','}:
        break
      name.add(ch)
    if name.len > 0:
      return name
  ""

proc hasMesonBuild(projectRoot: string): bool =
  fileExists(extendedPath(projectRoot / "meson.build"))

proc hasCMakeLists(projectRoot: string): bool =
  fileExists(extendedPath(projectRoot / "CMakeLists.txt"))

proc hasAutotoolsArtifacts(projectRoot: string): bool =
  ## True when the project root carries Autotools artefacts. The Meson
  ## convention defers to the Autotools convention in that case
  ## (matching the c-cpp-cmake and c-cpp-make conventions' defensive
  ## ordering).
  fileExists(extendedPath(projectRoot / "configure.ac")) or
    fileExists(extendedPath(projectRoot / "configure.in")) or
    fileExists(extendedPath(projectRoot / "Makefile.am"))

proc ccCompiler(): string =
  ## M9.N Batch B: bare tool name; engine resolves via PATH plumbing
  ## from ``toolIdentityRefs``. Pre-Batch-B the convention probed
  ## host PATH at emit time which produced an invalid argv on hosts
  ## without a C compiler installed.
  "gcc"

proc mesonExecutable(): string =
  ## M9.N Batch B: bare tool name; engine resolves via PATH plumbing.
  "meson"

proc ninjaExecutable(): string =
  ## M9.N Batch B: bare tool name; engine resolves via PATH plumbing.
  "ninja"

proc cCppMesonRecognize(projectRoot: string;
                       request: ProviderGraphRequest): bool {.gcsafe.} =
  ## Recognition contract — see module docstring.
  ##
  ## M9.N: tool availability (``meson`` / ``ninja`` / ``gcc`` on PATH) is
  ## NOT gated here. Recognition claims a recipe based on DECLARATION
  ## (``meson.build`` at projectRoot + ``uses:`` lists ``meson`` +
  ## ``executable`` / ``library`` member declared). Tool identity is
  ## resolved AFTER recognise, possibly via cache substitute or source
  ## build, so a host-PATH probe at recognise time is wrong.
  ##
  ## TODO(M9.N Batch B): resolve tool identity through engine instead of
  ## findExe at emit time.
  if not hasMesonBuild(projectRoot):
    return false
  if hasCMakeLists(projectRoot):
    return false
  if hasAutotoolsArtifacts(projectRoot):
    return false
  let source = readReprobuildSource(projectRoot)
  if source.len == 0:
    return false
  if not usesIncludesMeson(source):
    return false
  let members = extractMembers(source)
  if members.len == 0:
    return false
  true

proc scratchPathFor(projectRoot: string): string =
  projectRoot / ScratchDirName / MesonBuildSubdir

proc configureStampPath(projectRoot: string): string =
  ## The configure action's custom stamp — written after a successful
  ## ``meson setup`` run. ``build.ninja`` + the cache files are the
  ## headline outputs, but they may be touched during build too; the
  ## stamp gives the engine an immutable "configure succeeded" signal
  ## that the build actions key off.
  scratchPathFor(projectRoot) / "configure.stamp"

proc buildNinjaPath(projectRoot: string): string =
  scratchPathFor(projectRoot) / "build.ninja"

proc sanitizeNamePart(value: string): string =
  for ch in value:
    if ch in {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '-', '_', '.'}:
      result.add(ch)
    else:
      result.add('_')
  if result.len == 0:
    result = "x"

proc executableOutputPath(projectRoot, member: string): string =
  ## Predicted output path for an ``executable('<member>', ...)`` Meson
  ## target. Single-directory project + Ninja backend: Meson places
  ## binaries at the build dir root (on Windows the ``.exe`` suffix is
  ## added automatically).
  when defined(windows):
    scratchPathFor(projectRoot) / (member & ".exe")
  else:
    scratchPathFor(projectRoot) / member

proc staticLibraryOutputPath(projectRoot, member: string): string =
  ## Predicted output path for a ``static_library('<member>', ...)``
  ## Meson target. GNU archiver convention is ``lib<name>.a``; MSVC-
  ## style ``<member>.lib`` is deferred.
  scratchPathFor(projectRoot) / ("lib" & member & ".a")

proc collectMesonInputs(projectRoot: string): seq[string] =
  ## Conservative input enumeration for the configure action: every
  ## ``meson.build``, ``meson.options``, ``meson_options.txt`` file
  ## anywhere under the project root, plus every source file we can
  ## statically observe under ``src/`` / ``include/``. Header tweaks
  ## force re-configuration when generator-time file globbing would
  ## have re-included them.
  if not dirExists(extendedPath(projectRoot)):
    return @[]
  let rootMesonBuild = projectRoot / "meson.build"
  if fileExists(extendedPath(rootMesonBuild)):
    result.add(rootMesonBuild)
  for entry in walkDirRec(projectRoot):
    let unified = entry.replace('\\', '/')
    if (ScratchDirName & "/") in unified:
      continue
    if "/.repro/" in unified or "/.git/" in unified:
      continue
    let lower = entry.toLowerAscii
    let base = extractFilename(entry).toLowerAscii
    if base == "meson.build" or base == "meson.options" or
        base == "meson_options.txt":
      result.add(entry)
      continue
    if lower.endsWith(".c") or lower.endsWith(".cc") or
        lower.endsWith(".cpp") or lower.endsWith(".cxx") or
        lower.endsWith(".h") or lower.endsWith(".hpp") or
        lower.endsWith(".hh"):
      result.add(entry)
  # De-dup while preserving order — ``walkDirRec`` may produce the root
  # meson.build a second time.
  var seen: seq[string] = @[]
  for path in result:
    if path notin seen:
      seen.add(path)
  result = seen
  result.sort(system.cmp[string])

proc emitConfigureAction(projectRoot, mesonExe, ccExe: string;
                         mesonOptions: seq[string];
                         extraDeps: seq[string] = @[];
                         extraInputs: seq[string] = @[]):
    tuple[action: BuildActionDef; stamp: string] =
  ## Emit the ``meson setup <scratch> <root> --buildtype=release`` action.
  ## On success the action runs a follow-up touch via a sh-c wrapper if
  ## one is available; otherwise the action declares ``build.ninja`` as
  ## its primary output and a stamp file written by the action itself.
  ##
  ## Implementation note: mirrors the cmake convention's wrapper shape.
  ##
  ## **Compiler pinning via ``CC``**. Meson's compiler auto-detection
  ## probes ``cc`` before ``gcc``. On Windows hosts that ship MSYS2
  ## (``D:/metacraft-dev-deps/msys2/msys64/mingw64/bin/cc.exe``) alongside
  ## a separate winlibs gcc (``D:/metacraft-dev-deps/gcc/15.2.0/bin/gcc.exe``)
  ## meson would pick the MSYS2 ``cc`` even when the winlibs gcc is
  ## explicitly on PATH first. To force the convention to honour
  ## ``ccCompiler()``'s resolved compiler, we always pass ``CC=<ccExe>``
  ## into meson's environment via the sh wrapper. The fallback path
  ## (no sh on PATH) sets ``CC`` in the action's process env via the
  ## ``inlineExecCall`` env channel.
  let scratch = scratchPathFor(projectRoot)
  createDir(extendedPath(scratch))
  let buildNinja = buildNinjaPath(projectRoot)
  let stamp = configureStampPath(projectRoot)
  # M9.N Batch B: bare ``sh`` resolved via ``toolIdentityRefs``.
  let shExe = "sh"
  var argv: seq[string]
  if shExe.len > 0:
    # Compound: meson setup, then touch the stamp.
    let escapedStamp = stamp.replace("\\", "/").replace("\"", "\\\"")
    let escapedMeson = mesonExe.replace("\\", "/").replace("\"", "\\\"")
    let escapedCc = ccExe.replace("\\", "/").replace("\"", "\\\"")
    let escapedRoot = projectRoot.replace("\\", "/").replace("\"", "\\\"")
    let escapedScratch = scratch.replace("\\", "/").replace("\"", "\\\"")
    # DSL-port M9.K: append M9.I-registered mesonOptions to the
    # ``meson setup`` invocation. Each flag is double-quote-escaped
    # for the shell context. Order is preserved verbatim — the M9.I
    # registry stores flags in source-declaration order.
    var trailingOpts = ""
    for opt in mesonOptions:
      trailingOpts.add(" \"")
      trailingOpts.add(opt.replace("\"", "\\\""))
      trailingOpts.add("\"")
    let script = "set -e; export CC=\"" & escapedCc & "\"; \"" &
      escapedMeson & "\" setup \"" &
      escapedScratch & "\" \"" & escapedRoot &
      "\" --buildtype=release --backend=ninja" & trailingOpts &
      "; touch \"" & escapedStamp & "\""
    argv = @[shExe, "-c", script]
  else:
    # No sh on PATH (rare on dev hosts): invoke meson directly. The
    # stamp won't be touched, but ``build.ninja`` IS declared as the
    # primary output so the engine still records success. The
    # ``CC=<ccExe>`` pin is not applied on this path; if a host
    # somehow ends up here AND has a broken ``cc`` shadowing ``gcc``,
    # the configure step fails loudly rather than silently building
    # with the wrong toolchain.
    argv = @[mesonExe, "setup", scratch, projectRoot,
      "--buildtype=release", "--backend=ninja"]
    # DSL-port M9.K: append M9.I-registered mesonOptions verbatim.
    for opt in mesonOptions:
      argv.add(opt)
  var inputs = collectMesonInputs(projectRoot)
  for ei in extraInputs:
    if ei notin inputs:
      inputs.add(ei)
  var outputs = @[buildNinja]
  if shExe.len > 0:
    outputs.add(stamp)
  let action = buildAction(
    id = "ccpp-meson-configure",
    call = inlineExecCall(argv, projectRoot),
    deps = extraDeps,
    inputs = inputs,
    outputs = outputs,
    pool = "compile",
    # The configure step spawns a fan-out of generator subprocesses
    # (cc / ar probes; backend introspection) whose reads aren't
    # reliably observed via Windows DLL-interpose. Same constraint
    # ``c-cpp-cmake`` and ``c-cpp-autotools`` face for their configure
    # actions. Enumerate inputs explicitly via ``collectMesonInputs``
    # so per-file invalidation still works without monitoring.
    dependencyPolicy = automaticMonitorPolicy(),
    commandStatsId = "ccpp-meson.configure",
    # M9.N Batch B: meson configure invokes ninja + the C compiler at
    # probe time; the script itself is shelled via ``sh``.
    toolIdentityRefs = @["meson", "ninja", "gcc", "sh"])
  (action, stamp)

proc emitBuildAction(projectRoot, mesonExe: string;
                     member: CCppMesonMember;
                     configureActionId, configureStamp: string;
                     ninjaFlags: seq[string]):
                       BuildActionDef =
  ## Emit ``meson compile -C <scratch> <member>`` for a single member.
  ## The output path is the convention's predicted location of the
  ## produced artefact.
  ##
  ## DSL-port M9.K: ninja flags from the M9.I registry are passed
  ## through to ninja via meson's ``--ninja-args=<joined>`` pass-through
  ## (a single argument whose value is the space-joined ninja flag
  ## list). Per-flag escaping is the caller's responsibility — the M9.I
  ## emitter passes each literal flag verbatim, and these are normally
  ## simple tokens like ``-j4``.
  let scratch = scratchPathFor(projectRoot)
  let outputPath = case member.kind
    of ccmsExecutable: executableOutputPath(projectRoot, member.name)
    of ccmsLibraryStatic: staticLibraryOutputPath(projectRoot, member.name)
  createDir(extendedPath(parentDir(outputPath)))
  var argv = @[mesonExe, "compile", "-C", scratch, member.name]
  if ninjaFlags.len > 0:
    # Meson's ``--ninja-args`` accepts a single argument whose contents
    # are forwarded to ninja. Space-join preserves declaration order.
    argv.add("--ninja-args=" & ninjaFlags.join(" "))
  let kindTag = case member.kind
    of ccmsExecutable: "executable"
    of ccmsLibraryStatic: "library-static"
  buildAction(
    id = "ccpp-meson-build-" & sanitizeNamePart(member.name),
    call = inlineExecCall(argv, projectRoot),
    deps = @[configureActionId],
    inputs = @[configureStamp],
    outputs = @[outputPath],
    pool = "compile",
    dependencyPolicy = automaticMonitorPolicy(),
    commandStatsId = "ccpp-meson." & kindTag & ".build",
    # M9.N Batch B: ``meson compile`` re-invokes ninja + the C
    # compiler per the build rules.
    toolIdentityRefs = @["meson", "ninja", "gcc"])

proc syntheticPackage(projectRoot: string;
                      members: seq[CCppMesonMember]): PackageDef =
  var name = "c_cpp_meson_convention"
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

proc cCppMesonEmitFragment(projectRoot: string;
                          request: ProviderGraphRequest):
                            GraphFragment {.gcsafe.} =
  ## Convention entry — emit configure + per-member build actions, hand
  ## the bundle to ``buildPackageFragment``.
  {.cast(gcsafe).}:
    let source = readReprobuildSource(projectRoot)
    let members = extractMembers(source)
    if members.len == 0:
      let projectMatch = resolveProjectFile(projectRoot)
      let projectFile =
        if projectMatch.path.len > 0: projectMatch.path
        else: projectRoot / LegacyProjectFileName
      raise newException(ValueError,
        "c-cpp-meson convention: no executable or library members " &
          "declared in " & projectFile)
    let ccExe = ccCompiler()
    if ccExe.len == 0:
      raise newException(ValueError,
        "c-cpp-meson convention: no C compiler on PATH")
    let mesonExe = mesonExecutable()
    if mesonExe.len == 0:
      raise newException(ValueError,
        "c-cpp-meson convention: no 'meson' on PATH")
    if ninjaExecutable().len == 0:
      raise newException(ValueError,
        "c-cpp-meson convention: no 'ninja' on PATH " &
          "(Meson's default backend; multi-config backends deferred)")
    let pkg = syntheticPackage(projectRoot, members)
    # DSL-port M9.K: look up the DSL package name (first ``package
    # <ident>:`` block in the recipe source) and read the M9.H fetch
    # spec + M9.I meson/ninja flag seqs against that key.
    let dslPackageName = extractFirstPackageName(source)
    let fetchSpec =
      if dslPackageName.len > 0: registeredFetchSpec(dslPackageName)
      else: DslFetchSpec()
    let hasFetch = fetchSpec.url.len > 0 and fetchSpec.hashHex.len > 0
    # M9.R.6.1: the M9.I ``registeredBuildFlags`` registry was retired.
    # The in-tree c_cpp_meson convention no longer threads recipe-side
    # mesonOptions / ninjaFlags into the configure / compile argv. The
    # recipe author drives per-tool options via an explicit ``build:``
    # block calling the M9.R.2b ``meson_package(...)`` constructor.
    let mesonOptions: seq[string] = @[]
    let ninjaFlags: seq[string] = @[]
    let registerAll = proc() =
      discard buildPool("compile", 8'u32)
      var allActions: seq[BuildActionDef] = @[]
      var configureDeps: seq[string] = @[]
      var configureInputsExtra: seq[string] = @[]
      if hasFetch:
        discard buildPool("fetch", 2'u32)
        let fetchAct = emitFetchAction(projectRoot, dslPackageName, fetchSpec)
        allActions.add(fetchAct)
        configureDeps.add(fetchAct.id)
        configureInputsExtra.add(fetchStampPath(projectRoot, fetchSpec.hashHex))
      let configurePair = emitConfigureAction(projectRoot, mesonExe, ccExe,
        mesonOptions, configureDeps, configureInputsExtra)
      allActions.add(configurePair.action)
      for member in members:
        let buildAct = emitBuildAction(projectRoot, mesonExe, member,
          configurePair.action.id, configurePair.stamp, ninjaFlags)
        allActions.add(buildAct)
      defaultTarget(target("default", allActions))
    result = buildPackageFragment(pkg, request, registerAll,
      includeDefault = false)

proc cCppMesonConvention*(): LanguageConvention =
  ## The single value the standard provider binary registers at startup.
  LanguageConvention(
    name: "c-cpp-meson",
    recognize: cCppMesonRecognize,
    emitFragment: cCppMesonEmitFragment)
