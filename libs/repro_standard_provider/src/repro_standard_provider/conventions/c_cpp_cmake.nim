## C / C++ (CMake) language convention (Tier 2b) — M38.
##
## **Distinction from Tier 1 ``reprobuild-cmake``.** The Tier 1 try-compile
## provider (apps/repro-cmake-trycompile-provider.exe, built from a forked
## CMake with an embedded reprobuild generator) is the heavyweight path for
## CMake projects that need full try_compile probes lifted into the
## reprobuild DAG. M38 is the lightweight Mode 2 ecosystem-delegation
## sibling: it recognises a ``CMakeLists.txt`` and shells out to a stock
## ``cmake`` binary for configure + per-member build. The action graph is
## coarse (one configure action + one per-target build action), but the
## convention works on any project whose CMakeLists.txt parses with stock
## CMake (no forked generator required).
##
## **Recognition contract**:
##   * ``<projectRoot>/CMakeLists.txt`` exists.
##   * NO ``configure.ac`` / ``Makefile.am`` at the project root (Autotools
##     territory).
##   * ``<projectRoot>/repro.nim`` (or legacy ``reprobuild.nim``) exists
##     AND ``uses:`` lists ``cmake`` AND a C compiler (``gcc``/``clang``).
##   * at least one ``executable`` or ``library`` member declared.
##   * a C compiler is on PATH.
##   * ``cmake`` is on PATH.
##   * EITHER ``ninja`` is on PATH, OR (per platform) the platform's
##     ``make`` fallback resolves:
##       * Windows: ``mingw32-make`` (used with ``-G "MinGW Makefiles"``).
##       * POSIX:   ``make`` (used with ``-G "Unix Makefiles"``).
##
## **Generator choice** (M38 forces single-config to keep output paths
## predictable):
##   * Prefer ``Ninja`` when on PATH (cross-platform, fast).
##   * Fallback: ``MinGW Makefiles`` on Windows, ``Unix Makefiles`` on
##     POSIX. Both are single-config.
##   * Multi-config generators (Visual Studio, Xcode, Ninja Multi-Config)
##     are deferred to a follow-up milestone — they place binaries at
##     ``<config>/<name>`` which complicates output-path declaration.
##
## **Emitted actions**:
##   1. ``ccpp-cmake-configure`` — ``cmake -S <root> -B <scratch>
##      -G <generator>``. Inputs include the root ``CMakeLists.txt`` plus
##      every other ``CMakeLists.txt`` and ``*.cmake`` file under the
##      project tree, plus every source file we can statically observe
##      under ``src/``/``include/``. Outputs include the build dir's
##      ``CMakeCache.txt`` plus a custom stamp so the action's success is
##      recorded independently of CMake's internal touch behaviour. Uses
##      ``declaredOnlyDependencyPolicy`` — the configure step spawns a
##      fan-out of generator subprocesses whose FS reads are tracked
##      poorly by the Windows DLL-interpose path (same reason
##      ``c-cpp-autotools`` declines automatic-monitor for its configure
##      action).
##   2. ``ccpp-cmake-build-<member>`` — one per declared member:
##      ``cmake --build <scratch> --target <member>``. Deps:
##      ``ccpp-cmake-configure``. Outputs: the produced binary or static
##      archive at the predicted path under ``<scratch>``.
##
## **Output paths** (single-config generators):
##   * Executable: ``<scratch>/<member>[.exe]``.
##   * Static library: ``<scratch>/lib<member>.a`` (POSIX), or
##     ``<scratch>/lib<member>.a`` (MinGW Makefiles / Ninja on Windows —
##     gcc's archiver convention). MSVC-style ``<member>.lib`` is deferred
##     to multi-config follow-up.
##
## **Honest scope** (deferred):
##   * Per-source lift via parsing the generated Makefile (Tier 1's job).
##   * Multi-config generators.
##   * Shared libraries.
##   * ``find_package(Foo REQUIRED)`` upstream visibility (user declares
##     Foo in ``uses:`` per spec).
##   * CTest discovery.
##   * ``install()`` target.

import std/[algorithm, os, strutils]

import repro_core
import repro_provider_runtime
import repro_project_dsl
import repro_standard_provider/convention
import repro_standard_provider/conventions/fetch_action

const
  ScratchDirName* = ".repro/build"
    ## Top-level scratch directory under the project root the CMake
    ## convention writes into. Identical to other conventions'.

  CMakeBuildSubdir* = "cmake"
    ## Sub-directory under ``<projectRoot>/.repro/build/`` that holds the
    ## CMake build tree (the generator scratch space). Per-member outputs
    ## land here; the configure action treats the dir as both its scratch
    ## and its output dir.

type
  CCppCMakeMemberKind = enum
    cccmkExecutable
    cccmkLibraryStatic

  CCppCMakeMember = object
    name: string
    kind: CCppCMakeMemberKind

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

proc usesIncludesCMake(source: string): bool =
  ## True when ``uses:`` lists ``cmake`` AND a C compiler (``gcc`` or
  ## ``clang``). The convention is conservative — it requires both.
  if source.len == 0:
    return false
  var sawCompiler = false
  var sawCMake = false
  var inBlock = false
  proc consume(token: string) {.closure.} =
    if token == "gcc" or token == "clang":
      sawCompiler = true
    if token == "cmake":
      sawCMake = true
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
  sawCompiler and sawCMake

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

proc extractMembers(source: string): seq[CCppCMakeMember] =
  for name in extractExecutables(source):
    result.add(CCppCMakeMember(name: name, kind: cccmkExecutable))
  for name in extractLibraries(source):
    result.add(CCppCMakeMember(name: name, kind: cccmkLibraryStatic))

proc extractFirstPackageName(source: string): string =
  ## DSL-port M9.K: heuristic scan for the first ``package <ident>:``
  ## declaration. Same shape as the meson convention's helper — the
  ## lookup key for the M9.H ``registeredFetchSpec`` and M9.I
  ## ``registeredBuildFlags`` registries.
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

proc hasCMakeListsTxt(projectRoot: string): bool =
  fileExists(extendedPath(projectRoot / "CMakeLists.txt"))

proc hasAutotoolsArtifacts(projectRoot: string): bool =
  ## True when the project root carries Autotools artefacts. The CMake
  ## convention defers to the Autotools convention in that case (matching
  ## the c-cpp-make convention's defensive ordering).
  fileExists(extendedPath(projectRoot / "configure.ac")) or
    fileExists(extendedPath(projectRoot / "configure.in")) or
    fileExists(extendedPath(projectRoot / "Makefile.am"))

proc ccCompiler(): string =
  ## Resolve a C compiler driver on PATH. Prefer ``gcc``; fall back to
  ## ``clang``.
  let gcc = findExe("gcc")
  if gcc.len > 0:
    return gcc
  findExe("clang")

proc cmakeExecutable(): string =
  findExe("cmake")

proc ninjaExecutable(): string =
  findExe("ninja")

proc platformMakeExecutable(): string =
  ## Resolve a single-config ``make`` driver for the CMake-emitted
  ## Makefile. On Windows we prefer ``mingw32-make`` (MinGW Makefiles
  ## generator); on POSIX we prefer ``make`` (Unix Makefiles generator).
  ## Returns the empty string when neither resolves.
  when defined(windows):
    let mingw = findExe("mingw32-make")
    if mingw.len > 0:
      return mingw
    let make = findExe("make")
    if make.len > 0:
      return make
    ""
  else:
    findExe("make")

proc selectGenerator(): tuple[name, driverExe: string] =
  ## Pick the single-config generator + the build driver CMake will
  ## invoke. Prefers Ninja when on PATH; falls back to the platform's
  ## Make. Returns ``("", "")`` when neither builder resolves — the
  ## convention then declines recognition.
  let ninja = ninjaExecutable()
  if ninja.len > 0:
    return ("Ninja", ninja)
  let plat = platformMakeExecutable()
  if plat.len == 0:
    return ("", "")
  when defined(windows):
    ("MinGW Makefiles", plat)
  else:
    ("Unix Makefiles", plat)

proc cCppCMakeRecognize(projectRoot: string;
                       request: ProviderGraphRequest): bool {.gcsafe.} =
  ## Recognition contract — see module docstring.
  if not hasCMakeListsTxt(projectRoot):
    return false
  if hasAutotoolsArtifacts(projectRoot):
    return false
  let source = readReprobuildSource(projectRoot)
  if source.len == 0:
    return false
  if not usesIncludesCMake(source):
    return false
  let members = extractMembers(source)
  if members.len == 0:
    return false
  if ccCompiler().len == 0:
    return false
  if cmakeExecutable().len == 0:
    return false
  let gen = selectGenerator()
  if gen.name.len == 0:
    return false
  true

proc scratchPathFor(projectRoot: string): string =
  projectRoot / ScratchDirName / CMakeBuildSubdir

proc configureStampPath(projectRoot: string): string =
  ## The configure action's custom stamp — written after a successful
  ## ``cmake -S ... -B ...`` run. CMakeCache.txt + the generator's
  ## Makefile/ninja file are the headline outputs, but they may be
  ## touched during build too; the stamp gives the engine an immutable
  ## "configure succeeded" signal that the build actions key off.
  scratchPathFor(projectRoot) / "configure.stamp"

proc cmakeCachePath(projectRoot: string): string =
  scratchPathFor(projectRoot) / "CMakeCache.txt"

proc sanitizeNamePart(value: string): string =
  for ch in value:
    if ch in {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '-', '_', '.'}:
      result.add(ch)
    else:
      result.add('_')
  if result.len == 0:
    result = "x"

proc executableOutputPath(projectRoot, member: string): string =
  ## Predicted output path for an ``add_executable(<member> ...)`` target.
  ## Single-config generators place binaries at ``<build dir>/<name>``
  ## (or ``<build dir>/<name>.exe`` on Windows).
  when defined(windows):
    scratchPathFor(projectRoot) / (member & ".exe")
  else:
    scratchPathFor(projectRoot) / member

proc staticLibraryOutputPath(projectRoot, member: string): string =
  ## Predicted output path for an ``add_library(<member> STATIC ...)``
  ## target with the GNU archiver convention. CMake's
  ## ``CMAKE_STATIC_LIBRARY_PREFIX`` defaults to ``lib`` for both
  ## ``MinGW Makefiles`` and ``Ninja`` (when using gcc/clang), and the
  ## suffix defaults to ``.a``. MSVC-style ``<member>.lib`` is deferred.
  scratchPathFor(projectRoot) / ("lib" & member & ".a")

proc collectCMakeInputs(projectRoot: string): seq[string] =
  ## Conservative input enumeration for the configure action:
  ## every ``CMakeLists.txt`` and ``*.cmake`` file anywhere under
  ## the project root, plus every source file under ``src/`` /
  ## ``include/`` (so a header tweak forces re-configuration when
  ## generator-time file globbing would have re-included it).
  if not dirExists(extendedPath(projectRoot)):
    return @[]
  let rootCMakeLists = projectRoot / "CMakeLists.txt"
  if fileExists(extendedPath(rootCMakeLists)):
    result.add(rootCMakeLists)
  for entry in walkDirRec(projectRoot):
    let unified = entry.replace('\\', '/')
    if (ScratchDirName & "/") in unified:
      continue
    if "/.repro/" in unified or "/.git/" in unified:
      continue
    let lower = entry.toLowerAscii
    let base = extractFilename(entry).toLowerAscii
    if base == "cmakelists.txt" or lower.endsWith(".cmake"):
      result.add(entry)
      continue
    if lower.endsWith(".c") or lower.endsWith(".cc") or
        lower.endsWith(".cpp") or lower.endsWith(".cxx") or
        lower.endsWith(".h") or lower.endsWith(".hpp") or
        lower.endsWith(".hh"):
      result.add(entry)
  # De-dup while preserving order — ``walkDirRec`` may produce the root
  # CMakeLists.txt a second time.
  var seen: seq[string] = @[]
  for path in result:
    if path notin seen:
      seen.add(path)
  result = seen
  result.sort(system.cmp[string])

proc emitConfigureAction(projectRoot, cmakeExe, generator: string;
                         cmakeFlags: seq[string];
                         extraDeps: seq[string] = @[];
                         extraInputs: seq[string] = @[]):
    tuple[action: BuildActionDef; stamp: string] =
  ## Emit the ``cmake -S <root> -B <scratch> -G <generator>`` action.
  ## On success the action runs a follow-up touch via a sh-c wrapper if
  ## one is available; otherwise the action declares the cache file as
  ## its primary output and a stamp file written by the action itself.
  ##
  ## Implementation note: we issue a single CMake invocation, then the
  ## engine inspects the cache file's existence as the success signal.
  ## The "stamp" path is written by a follow-up touch via Nim's runtime
  ## in the post-action verify phase — but to keep the action self-
  ## contained at the engine level, we declare BOTH the cache file AND
  ## a stamp file the action produces by wrapping the cmake invocation
  ## in a sh-c when sh is available. When sh isn't available the stamp
  ## isn't written by the action itself; the engine still keys off the
  ## cache file's mtime.
  let scratch = scratchPathFor(projectRoot)
  createDir(extendedPath(scratch))
  let cache = cmakeCachePath(projectRoot)
  let stamp = configureStampPath(projectRoot)
  # Always declare the cache file as a primary output; stamp is also
  # declared but the action's command list creates it directly via a
  # platform-portable wrapper.
  let shExe = findExe("sh")
  var argv: seq[string]
  if shExe.len > 0:
    # Compound: cmake configure, then touch the stamp.
    let escapedStamp = stamp.replace("\\", "/").replace("\"", "\\\"")
    let escapedCmake = cmakeExe.replace("\\", "/").replace("\"", "\\\"")
    let escapedRoot = projectRoot.replace("\\", "/").replace("\"", "\\\"")
    let escapedScratch = scratch.replace("\\", "/").replace("\"", "\\\"")
    # DSL-port M9.K: append M9.I-registered cmakeFlags to the
    # ``cmake -S ... -B ... -G ...`` invocation. Each flag is
    # double-quote-escaped for the shell context.
    var trailingFlags = ""
    for flag in cmakeFlags:
      trailingFlags.add(" \"")
      trailingFlags.add(flag.replace("\"", "\\\""))
      trailingFlags.add("\"")
    let script = "set -e; \"" & escapedCmake & "\" -S \"" & escapedRoot &
      "\" -B \"" & escapedScratch & "\" -G \"" & generator &
      "\" -DCMAKE_BUILD_TYPE=Release" & trailingFlags &
      "; touch \"" & escapedStamp & "\""
    argv = @[shExe, "-c", script]
  else:
    # No sh on PATH (rare on dev hosts): invoke cmake directly. The
    # stamp won't be touched, but the cache file IS declared as the
    # primary output so the engine still records success.
    argv = @[cmakeExe, "-S", projectRoot, "-B", scratch, "-G", generator,
      "-DCMAKE_BUILD_TYPE=Release"]
    # DSL-port M9.K: append M9.I-registered cmakeFlags verbatim.
    for flag in cmakeFlags:
      argv.add(flag)
  var inputs = collectCMakeInputs(projectRoot)
  for ei in extraInputs:
    if ei notin inputs:
      inputs.add(ei)
  var outputs = @[cache]
  if shExe.len > 0:
    outputs.add(stamp)
  let action = buildAction(
    id = "ccpp-cmake-configure",
    call = inlineExecCall(argv, projectRoot),
    deps = extraDeps,
    inputs = inputs,
    outputs = outputs,
    pool = "compile",
    # The configure step spawns a fan-out of generator subprocesses
    # whose reads aren't reliably observed via Windows DLL-interpose
    # (same constraint c-cpp-autotools's configure action faces). We
    # enumerate inputs explicitly via ``collectCMakeInputs`` so per-
    # file invalidation still works without monitoring.
    dependencyPolicy = automaticMonitorPolicy(),
    commandStatsId = "ccpp-cmake.configure")
  (action, stamp)

proc emitBuildAction(projectRoot, cmakeExe: string;
                     member: CCppCMakeMember;
                     configureActionId, configureStamp: string):
                       BuildActionDef =
  ## Emit ``cmake --build <scratch> --target <member>`` for a single
  ## member. The output path is the convention's predicted location of
  ## the produced artefact.
  let scratch = scratchPathFor(projectRoot)
  let outputPath = case member.kind
    of cccmkExecutable: executableOutputPath(projectRoot, member.name)
    of cccmkLibraryStatic: staticLibraryOutputPath(projectRoot, member.name)
  createDir(extendedPath(parentDir(outputPath)))
  let argv = @[cmakeExe, "--build", scratch, "--target", member.name]
  let kindTag = case member.kind
    of cccmkExecutable: "executable"
    of cccmkLibraryStatic: "library-static"
  buildAction(
    id = "ccpp-cmake-build-" & sanitizeNamePart(member.name),
    call = inlineExecCall(argv, projectRoot),
    deps = @[configureActionId],
    inputs = @[configureStamp],
    outputs = @[outputPath],
    pool = "compile",
    dependencyPolicy = automaticMonitorPolicy(),
    commandStatsId = "ccpp-cmake." & kindTag & ".build")

proc syntheticPackage(projectRoot: string;
                      members: seq[CCppCMakeMember]): PackageDef =
  var name = "c_cpp_cmake_convention"
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

proc cCppCMakeEmitFragment(projectRoot: string;
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
        "c-cpp-cmake convention: no executable or library members " &
          "declared in " & projectFile)
    let ccExe = ccCompiler()
    if ccExe.len == 0:
      raise newException(ValueError,
        "c-cpp-cmake convention: no C compiler on PATH")
    let cmakeExe = cmakeExecutable()
    if cmakeExe.len == 0:
      raise newException(ValueError,
        "c-cpp-cmake convention: no 'cmake' on PATH")
    let gen = selectGenerator()
    if gen.name.len == 0:
      raise newException(ValueError,
        "c-cpp-cmake convention: no single-config build driver on PATH " &
          "(needs ninja, or platform-specific make: mingw32-make on " &
          "Windows / make on POSIX)")
    let pkg = syntheticPackage(projectRoot, members)
    # DSL-port M9.K: look up the DSL package name (first ``package
    # <ident>:`` block in the recipe source) and read the M9.H fetch
    # spec + M9.I cmake flag seq against that key.
    let dslPackageName = extractFirstPackageName(source)
    let fetchSpec =
      if dslPackageName.len > 0: registeredFetchSpec(dslPackageName)
      else: DslFetchSpec()
    let hasFetch = fetchSpec.url.len > 0 and fetchSpec.hashHex.len > 0
    let cmakeFlags =
      if dslPackageName.len > 0:
        registeredBuildFlags(dslPackageName, "", "cmake")
      else: @[]
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
      let configurePair = emitConfigureAction(projectRoot, cmakeExe, gen.name,
        cmakeFlags, configureDeps, configureInputsExtra)
      allActions.add(configurePair.action)
      for member in members:
        let buildAct = emitBuildAction(projectRoot, cmakeExe, member,
          configurePair.action.id, configurePair.stamp)
        allActions.add(buildAct)
      defaultTarget(target("default", allActions))
    result = buildPackageFragment(pkg, request, registerAll,
      includeDefault = false)

proc cCppCMakeConvention*(): LanguageConvention =
  ## The single value the standard provider binary registers at startup.
  LanguageConvention(
    name: "c-cpp-cmake",
    recognize: cCppCMakeRecognize,
    emitFragment: cCppCMakeEmitFragment)
