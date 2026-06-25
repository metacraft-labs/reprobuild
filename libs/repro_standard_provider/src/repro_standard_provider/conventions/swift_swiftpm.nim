## Swift / SwiftPM language convention (Tier 2b) — M43.
##
## Fourth managed-ecosystem standard-provider convention after the M40
## ``java-maven``, M41 ``kotlin-gradle`` and M42 ``csharp-dotnet``
## siblings. Recognises a ``Package.swift`` at the project root and
## shells out to the stock ``swift`` driver for a single offline
## ``swift build -c release --quiet`` invocation. The action graph is
## intentionally coarse: one build action that produces
## ``.build/release/<target>`` (or ``.build/release/<target>.exe`` on
## Windows) per declared executable, and ``.build/release/lib<target>.a``
## per declared library.
##
## **Distinction from a hypothetical future Tier 2c Swift provider.**
## A Tier 2c Swift provider would intercept the SwiftPM build plan and
## lift individual ``swiftc`` invocations into the reprobuild DAG. That
## heavyweight path is not in scope for M43; M43 is the lightweight
## Mode 2 ecosystem-delegation sibling (mirroring M38 c-cpp-cmake,
## M39 c-cpp-meson, M40 java-maven, M41 kotlin-gradle and M42
## csharp-dotnet).
##
## **Recognition contract**:
##   * ``<projectRoot>/Package.swift`` — the SwiftPM package manifest.
##     The presence of this file is the SwiftPM package signal; no other
##     standard-provider convention recognises this filename, so the
##     gate is unambiguous.
##   * ``<projectRoot>/repro.nim`` (or legacy ``reprobuild.nim``) exists
##     AND ``uses:`` lists ``swift`` or ``swiftc`` or ``swiftpm`` (the
##     closed-set token list mirrors the M40/M41/M42 pattern; the
##     ``swift`` token covers both the compiler driver and the package
##     manager because they ship as a single binary distribution).
##   * at least one ``executable`` or ``library`` member declared.
##   * a ``swift`` driver is on PATH (the Swift toolchain ships the
##     ``swift`` host as a single binary that subcommands into ``swiftc``
##     for compilation and into ``swift build``/``swift package`` for
##     SwiftPM operations; presence of ``swift`` on PATH is the toolchain
##     availability signal).
##
## **Offline mode** (M43 keeps builds hermetic via the ``--quiet`` mode
## that defaults to no network):
##   * The action runs ``swift build -c release --quiet``. SwiftPM's
##     dependency-resolution step is a no-op when ``Package.swift``
##     declares no external dependencies — the M43 fixture is
##     stdlib-only so no network access is needed. Real-world projects
##     pulling external SwiftPM packages should run ``swift package
##     resolve`` once with network access BEFORE invoking the convention
##     to populate ``.build/`` with the resolved packages and the
##     ``Package.resolved`` lockfile.
##   * The M43 fixture is stdlib-only (no external SwiftPM dependencies)
##     so no provisioning warm step is required for the fixture; the
##     convention can be exercised end-to-end without provisioning
##     external deps.
##
## **Emitted actions**:
##   1. ``swift-swiftpm-build`` — single ``<swift> build -c release
##      --quiet`` action under the project root. Inputs: ``Package.swift``
##      plus every ``.swift`` source file recursively walked under
##      ``Sources/`` (excluding ``.build/`` / ``.repro/`` / ``.git/``).
##      Outputs: one ``.build/release/<target>[.exe]`` per declared
##      executable, ``.build/release/lib<target>.a`` per declared
##      library. Uses ``automaticMonitorPolicy`` (automatic monitoring is
##      the spec baseline for opaque tools, Reprobuild-Development M17):
##      ``swift build`` spawns ``swiftc`` worker processes and the engine
##      monitors their real read-set instead of trusting only statically
##      declared inputs.
##
## **Output paths**:
##   * Executable: ``<projectRoot>/.build/release/<targetName>`` (on
##     POSIX) or ``<projectRoot>/.build/release/<targetName>.exe`` (on
##     Windows). The Swift Windows toolchain produces ``.exe`` files.
##   * Library: ``<projectRoot>/.build/release/lib<targetName>.a``
##     (static archive — SwiftPM's default product for ``.library``
##     targets when ``type: .static`` is declared or when no type is
##     specified for a library product).
##   * NB: on some toolchain shapes SwiftPM may write into
##     ``.build/<arch>-<os>-<vendor>/release/<target>`` with a symlink
##     at ``.build/release/`` pointing into it; the convention predicts
##     the symlink path which is stable across toolchain hosts.
##
## **Honest scope** (deferred):
##   * External SwiftPM dependencies — the convention assumes a
##     ``Package.resolved`` is either absent (stdlib-only) or already
##     materialised by a provisioning step before the convention runs.
##     A future M may add a ``Package.resolved`` hard-precondition check
##     mirroring M42's ``packages.lock.json`` requirement.
##   * Multi-target packages — the convention emits one output per
##     declared member, picking the executable/library names from the
##     ``repro.nim``. SwiftPM's own product/target wiring (in
##     ``Package.swift``) is not lifted; the user is responsible for
##     keeping the names in sync.
##   * ``swift test`` discovery — deferred to a follow-up M (mirrors
##     M40/M41/M42 deferral of test-task discovery).
##   * Multi-platform (Linux/macOS/Windows) — the convention is
##     platform-agnostic but the produced binary path differs slightly
##     per toolchain shape. The convention predicts the
##     ``.build/release/`` symlink path which is stable across the
##     three platforms.
##   * Xcode-style ``.xcodeproj`` projects — out of scope per the M43
##     spec; SwiftPM only.
##   * Swift Package Index dependency resolution — a provisioning
##     concern, deferred.
##
## **Provisioning note**: on a development host that doesn't ship the
## Swift toolchain, the supported install paths are:
##   * swift.org Windows installer (``Swift-5.10-RELEASE-windows10.exe``)
##     unpacked under ``D:/metacraft-dev-deps/swift/5.10/`` (manual
##     download is the canonical Windows path for the dev shell).
##   * Or: ``winget install Swift.Toolchain`` (uses the Microsoft Store
##     Swift install; lands ``%LocalAppData%\Programs\Swift\Toolchains\
##     <ver>\usr\bin\swift.exe`` on PATH automatically).
##
## See ``reprobuild-specs/Mode3-Language-Expansion.milestones.org`` §M43.

import std/[algorithm, os, strutils]

import repro_core
import repro_provider_runtime
import repro_project_dsl
import repro_standard_provider/convention

const
  ScratchDirName* = ".repro/build"
    ## Top-level scratch directory under the project root. Identical to
    ## the M40 / M41 / M42 conventions' value, but M43 doesn't actually
    ## use it as a build dir — SwiftPM writes to
    ## ``<projectRoot>/.build/`` (its own convention). The constant is
    ## retained for consistency.

  SwiftBuildSubdir* = ".build"
    ## Sub-directory under the project root where SwiftPM lays its
    ## final build outputs. Hard-coded by SwiftPM's default
    ## ``--build-path`` derivation; the convention predicts the
    ## ``.build/release/`` path under it.

  SwiftReleaseSubdir* = "release"
    ## Sub-directory under ``.build/`` corresponding to the build
    ## configuration. The convention pins ``-c release`` so the path
    ## is fixed.

type
  SwiftSwiftpmMemberKind = enum
    ssmExecutable
    ssmLibrary

  SwiftSwiftpmMember = object
    name: string
    kind: SwiftSwiftpmMemberKind

proc readReprobuildSource(projectRoot: string): string =
  ## Read the project file (``repro.nim`` or legacy ``reprobuild.nim``)
  ## or return the empty string.
  let match = resolveProjectFile(projectRoot)
  if match.path.len == 0:
    return ""
  try:
    readFile(extendedPath(match.path))
  except CatchableError:
    ""

proc usesIncludesSwiftSwiftpm(source: string): bool =
  ## True when ``uses:`` lists ``swift`` or ``swiftc`` or ``swiftpm``
  ## (the closed-set token list mirrors the M42 ``csharp-dotnet``
  ## convention's ``usesIncludesCsharpDotnet`` — a single token covers
  ## the toolchain since the Swift distribution ships compiler +
  ## package manager as a single binary).
  if source.len == 0:
    return false
  var sawSwift = false
  var inBlock = false
  proc consume(token: string) {.closure.} =
    if token == "swift" or token == "swiftc" or token == "swiftpm":
      sawSwift = true
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
  sawSwift

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

proc extractMembers(source: string): seq[SwiftSwiftpmMember] =
  for name in extractExecutables(source):
    result.add(SwiftSwiftpmMember(name: name, kind: ssmExecutable))
  for name in extractLibraries(source):
    result.add(SwiftSwiftpmMember(name: name, kind: ssmLibrary))

proc hasPackageSwift(projectRoot: string): bool =
  ## True when ``<projectRoot>/Package.swift`` exists. This is the
  ## SwiftPM package manifest signal — uniquely identifies a SwiftPM
  ## package (no other convention recognises this filename).
  fileExists(extendedPath(projectRoot / "Package.swift"))

proc swiftExecutable(): string =
  ## Resolve a ``swift`` driver on PATH. On Windows the binary is
  ## usually ``swift.exe``; ``findExe`` resolves both shapes via
  ## PATHEXT.
  findExe("swift")

proc swiftSwiftpmRecognize(projectRoot: string;
                           request: ProviderGraphRequest): bool {.gcsafe.} =
  ## Recognition contract — see module docstring.
  if not hasPackageSwift(projectRoot):
    return false
  let source = readReprobuildSource(projectRoot)
  if source.len == 0:
    return false
  if not usesIncludesSwiftSwiftpm(source):
    return false
  let members = extractMembers(source)
  if members.len == 0:
    return false
  if swiftExecutable().len == 0:
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

proc producedExecutablePath*(projectRoot, targetName: string): string =
  ## Predicted output path for a SwiftPM executable target. SwiftPM's
  ## ``-c release`` build writes the executable into
  ## ``.build/release/<targetName>`` (with a ``.exe`` extension on
  ## Windows). The ``.build/release/`` path is a symlink into a
  ## triple-specific subdir (e.g. ``.build/x86_64-unknown-windows-msvc/
  ## release/``) on some toolchain shapes; the convention predicts the
  ## symlink path which is stable across the supported platforms.
  let exeName =
    when defined(windows): targetName & ".exe"
    else: targetName
  projectRoot / SwiftBuildSubdir / SwiftReleaseSubdir / exeName

proc producedLibraryPath*(projectRoot, targetName: string): string =
  ## Predicted output path for a SwiftPM static-library target.
  ## SwiftPM's ``-c release`` build writes static libraries as
  ## ``.build/release/lib<targetName>.a`` (the ``lib`` prefix is added
  ## automatically by SwiftPM's build system, matching the cross-
  ## platform Unix archive-naming convention).
  let libName = "lib" & targetName & ".a"
  projectRoot / SwiftBuildSubdir / SwiftReleaseSubdir / libName

proc collectSwiftInputs(projectRoot: string): seq[string] =
  ## Conservative input enumeration for the build action: the
  ## ``Package.swift`` manifest plus every ``.swift`` file recursively
  ## walked under ``Sources/`` (excluding ``.build/`` / ``.repro/`` /
  ## ``.git/``). ``Package.resolved`` (when present) is also included as
  ## an input — it records the resolved versions of any external SwiftPM
  ## dependencies and changes whenever those dependencies are re-resolved.
  ## Test sources under ``Tests/`` are NOT enumerated (M43 ships
  ## ``swift build`` only; ``swift test`` discovery is deferred).
  if not dirExists(extendedPath(projectRoot)):
    return @[]
  let manifestPath = projectRoot / "Package.swift"
  if fileExists(extendedPath(manifestPath)):
    result.add(manifestPath)
  let resolvedPath = projectRoot / "Package.resolved"
  if fileExists(extendedPath(resolvedPath)):
    result.add(resolvedPath)
  let sourcesDir = projectRoot / "Sources"
  if dirExists(extendedPath(sourcesDir)):
    proc shouldSkipDir(name: string): bool =
      let lower = name.toLowerAscii
      lower in [".build", ".repro", ".git"]
    var stack: seq[string] = @[sourcesDir]
    while stack.len > 0:
      let cur = stack[^1]
      stack.setLen(stack.len - 1)
      try:
        for kind, path in walkDir(cur):
          let basename = extractFilename(path)
          case kind
          of pcFile, pcLinkToFile:
            if basename.toLowerAscii.endsWith(".swift"):
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

proc emitBuildAction(projectRoot, swiftExe: string;
                     members: seq[SwiftSwiftpmMember]): BuildActionDef =
  ## Emit the single ``swift build -c release --quiet`` action. Outputs
  ## the predicted ``.build/release/<target>[.exe]`` path under the
  ## project root for each declared executable, plus
  ## ``.build/release/lib<target>.a`` for each declared library.
  ##
  ## ``-c release`` enforces the Release-configuration build (debug
  ## builds use ``.build/debug/``; the convention hard-pins release so
  ## predicted output paths are stable). ``--quiet`` keeps per-action
  ## logs readable — SwiftPM's default chatter (one line per source
  ## file compiled, plus link summary) is verbose for non-trivial
  ## packages.
  var outputs: seq[string] = @[]
  for m in members:
    case m.kind
    of ssmExecutable:
      outputs.add(producedExecutablePath(projectRoot, m.name))
    of ssmLibrary:
      outputs.add(producedLibraryPath(projectRoot, m.name))
  if outputs.len > 0:
    createDir(extendedPath(parentDir(outputs[0])))
  let argv = @[swiftExe, "build", "-c", "release", "--quiet"]
  let inputs = collectSwiftInputs(projectRoot)
  buildAction(
    id = "swift-swiftpm-build",
    call = inlineExecCall(argv, projectRoot),
    inputs = inputs,
    outputs = outputs,
    pool = "compile",
    # ``swift build`` spawns ``swiftc`` worker processes (one per
    # source file, plus the linker invocation) whose FS reads aren't
    # reliably observed via the Windows DLL-interpose path. Same
    # constraint M38/M39/M40/M41/M42 face for their configure /
    # package / build actions. Enumerate inputs explicitly via
    # ``collectSwiftInputs`` so per-source invalidation still works
    # without monitoring.
    dependencyPolicy = automaticMonitorPolicy(),
    commandStatsId = "swift-swiftpm.build")

proc syntheticPackage(projectRoot: string;
                      members: seq[SwiftSwiftpmMember]): PackageDef =
  var name = "swift_swiftpm_convention"
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

proc swiftSwiftpmEmitFragment(projectRoot: string;
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
        "swift-swiftpm convention: no executable or library members " &
          "declared in " & projectFile)
    if swiftExecutable().len == 0:
      raise newException(ValueError,
        "swift-swiftpm convention: no 'swift' on PATH (Swift toolchain " &
          "required; install Swift 5.10 from swift.org into " &
          "D:/metacraft-dev-deps/swift/5.10/ or via " &
          "'winget install Swift.Toolchain')")
    if not hasPackageSwift(projectRoot):
      raise newException(ValueError,
        "swift-swiftpm convention: no 'Package.swift' at project root " &
          projectRoot)
    let pkg = syntheticPackage(projectRoot, members)
    let registerAll = proc() =
      discard buildPool("compile", 8'u32)
      let buildAct = emitBuildAction(projectRoot,
        swiftExecutable(), members)
      defaultTarget(target("default", @[buildAct]))
    result = buildPackageFragment(pkg, request, registerAll,
      includeDefault = false)

proc swiftSwiftpmConvention*(): LanguageConvention =
  ## The single value the standard provider binary registers at startup.
  LanguageConvention(
    name: "swift-swiftpm",
    recognize: swiftSwiftpmRecognize,
    emitFragment: swiftSwiftpmEmitFragment)
