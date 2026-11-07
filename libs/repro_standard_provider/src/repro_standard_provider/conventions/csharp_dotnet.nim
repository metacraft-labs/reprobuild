## C# / .NET language convention (Tier 2b) — M42.
##
## Third managed-runtime-ecosystem standard-provider convention after
## the M40 ``java-maven`` and M41 ``kotlin-gradle`` siblings. Recognises
## a single ``*.csproj`` at the project root and shells out to a stock
## ``dotnet`` driver for a single offline ``dotnet build -c Release
## --no-restore --nologo --verbosity quiet`` invocation. The action graph
## is intentionally coarse: one build action, whose products MSBuild
## itself names (see **Output paths**).
##
## **Distinction from a hypothetical future Tier 2c .NET provider.**
## A Tier 2c .NET provider would parse MSBuild's binary-log output and
## lift individual targets / per-source compile commands into the
## reprobuild DAG. That heavyweight path is not in scope for M42; M42
## is the lightweight Mode 2 ecosystem-delegation sibling (mirroring
## M38 c-cpp-cmake, M39 c-cpp-meson, M40 java-maven, and M41
## kotlin-gradle).
##
## **Recognition contract**:
##   * ``<projectRoot>/*.csproj`` — exactly one ``.csproj`` is required
##     at the project root (M42 takes the first match alphabetically;
##     multi-project ``.sln`` setups are deferred to a follow-up M).
##   * ``<projectRoot>/packages.lock.json`` — HARD PRECONDITION per
##     spec. The NuGet lockfile is the offline-build guarantee; the
##     convention refuses to recognise a project that lacks it. The
##     refusal is silent at ``recognize`` time (returns ``false``); the
##     ``emitFragment`` path raises with a clear diagnostic ("run
##     ``dotnet restore --use-lock-file`` once to generate") if the
##     project somehow slips through.
##   * ``<projectRoot>/repro.nim`` (or legacy ``reprobuild.nim``) exists
##     AND ``uses:`` lists ``dotnet`` or ``dotnet-sdk`` AND optionally
##     ``csharp`` (the closed-set token list mirrors the M40/M41
##     pattern).
##   * at least one ``executable`` or ``library`` member declared.
##   * a ``dotnet`` driver is on PATH (the .NET SDK ships the dotnet
##     host as a single binary; presence of ``dotnet`` on PATH is the
##     SDK availability signal).
##
## **Offline mode** (M42 enforces ``--no-restore`` to keep builds
## hermetic):
##   * The action runs ``dotnet build -c Release --no-restore --nologo
##     --verbosity quiet``. The NuGet global packages cache at
##     ``~/.nuget/packages/`` (or ``%USERPROFILE%\.nuget\packages\`` on
##     Windows) is the staging surface.
##   * ``--no-restore`` instructs the SDK NOT to consult NuGet at build
##     time; the lockfile (``packages.lock.json``) plus the warmed
##     global packages cache covers every package the project declares.
##     If the project pulls external NuGet packages they MUST be
##     pre-populated by a provisioning step BEFORE the convention
##     dispatches: ``dotnet restore --use-lock-file`` from a context
##     with network access (the warm step). The convention itself never
##     reaches the network.
##   * The M42 fixture ships a stdlib-only Program.cs (no external
##     NuGet packages beyond the implicit ``Microsoft.NETCore.App``
##     reference, which is part of the SDK's bundled framework pack) so
##     the warm step is a no-op for the fixture; the convention can be
##     exercised end-to-end without provisioning external deps.
##
## **Quiet output** (``--nologo --verbosity quiet``): the default
## MSBuild console output is extremely verbose (one line per project
## target, per source file compiled, etc.) — the convention's quiet
## mode keeps per-action logs readable. The action still emits the
## final "Build succeeded" / "Build FAILED" summary to stderr when
## something goes wrong.
##
## **Emitted actions**:
##   1. ``csharp-dotnet-outputs`` -- asks MSBuild where the build puts its
##      products: ``dotnet msbuild <csproj> -p:Configuration=Release
##      -getProperty:TargetPath -getProperty:TargetDir -getProperty:ProjectDir
##      -getProperty:IntermediateOutputPath`` (MSBuild 17.8 / SDK 8), run by
##      the standard provider itself (``output_discovery.dotnetOutputs``).
##      Writes a dynamic-output fragment. Monitored, so
##      ``Directory.Build.props``, imported targets and the restore's
##      generated props key the answer.
##   2. ``csharp-dotnet-build`` -- a single ``<dotnet> build -c Release
##      --no-restore --nologo --verbosity quiet --disable-build-servers
##      <csproj>`` action under the project root. Inputs: the ``.csproj``
##      plus ``packages.lock.json`` plus every ``.cs`` source file
##      recursively walked from the project root (excluding ``bin/`` /
##      ``obj/`` / ``.repro/`` / ``.git/``) and the fragment, which is also
##      its ``dynamicDepsFile``. Its outputs come from the fragment. Uses
##      ``automaticMonitorPolicy``: ``dotnet`` spawns MSBuild worker
##      processes and the engine monitors their real read-set.
##
## Both edges run with ``DOTNET_CLI_TELEMETRY_OPTOUT=1``, ``DOTNET_NOLOGO=1``
## and ``DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1`` (CSharp-DotNet.md §"Mode B"),
## and the build with ``--disable-build-servers``: telemetry, the first-run
## sentinel and persistent compiler / MSBuild servers otherwise write under
## the user's home and the temporary directory, outside anything the edge
## declares, and outlive the action.
##
## **Output paths** (Build-Engine-And-Scheduler.md §"Outputs a delegated
## build decides"):
##   * ``TargetDir`` (``bin/Release/<tfm>/[<rid>/]`` by default) and
##     ``IntermediateOutputPath`` (``obj/Release/<tfm>/``) are opaque output
##     directories: removed before the build runs, recorded whole and
##     restored exactly. The apphost, the ``.deps.json``, the
##     ``.runtimeconfig.json`` and the PDB are recorded with ``TargetDir``.
##     The restore's own files at the root of ``obj/`` are outside both.
##   * ``TargetPath`` is the obligatory main assembly: ``OutputPath``,
##     ``BaseOutputPath``, ``AssemblyName``, ``OutputType``,
##     ``RuntimeIdentifier``, ``Append*ToOutputPath`` and a .NET Framework
##     ``.exe`` are MSBuild's to apply, wherever they are set.
##
## **Honest scope** (deferred):
##   * Multi-target ``<TargetFrameworks>`` (plural) — one coarse build
##     edge builds every framework; discovery declares each framework's
##     ``TargetDir`` and ``IntermediateOutputPath`` opaque and its
##     ``TargetPath`` obligatory. A per-framework edge is deferred.
##   * Multi-project solutions (``*.sln``) — single ``.csproj`` only.
##   * F# (``*.fsproj``) — a separate convention is the right shape.
##   * VB.NET (``*.vbproj``) — deferred.
##   * ``dotnet test`` discovery (M22-style ``#test`` target) — the
##     crude fallback still covers it; a follow-up M may surface a
##     ``#test`` target.
##   * Self-contained ``dotnet publish`` (single-file / AOT) — a
##     separate opt-in DSL field; M42 only covers ``dotnet build``.
##   * AOT compilation (``PublishAot``) — deferred.
##   * External NuGet packages at convention time — the M42
##     ``packages.lock.json`` hard precondition + ``--no-restore``
##     contract pushes that to the provisioning step.
##
## See ``reprobuild-specs/Mode3-Language-Expansion.milestones.org`` §M42.

import std/[algorithm, os, strutils]

import repro_core
import repro_provider_runtime
import repro_project_dsl
import repro_standard_provider/convention
import repro_standard_provider/conventions/output_discovery

const
  ScratchDirName* = ".repro/build"
    ## Top-level scratch directory under the project root. MSBuild builds
    ## into its own ``bin/`` and ``obj/``; this convention keeps its output
    ## discovery here.

  ConventionName = "csharp-dotnet"
  BuildActionId = ConventionName & "-build"

type
  CSharpDotnetMemberKind = enum
    cdmExecutable
    cdmLibrary

  CSharpDotnetMember = object
    name: string
    kind: CSharpDotnetMemberKind

  CSharpDotnetCoordinates = object
    csprojPath: string
      ## Absolute path to the project's ``.csproj``. Empty when no
      ## ``.csproj`` is present at the project root. Everything about where
      ## the build writes is MSBuild's answer, not parsed here.

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

proc usesIncludesCsharpDotnet(source: string): bool =
  ## True when ``uses:`` lists ``dotnet`` or ``dotnet-sdk`` (the
  ## ``csharp`` token is accepted as a secondary signal but isn't
  ## required — same pattern as the M41 kotlin-gradle convention's
  ## ``usesIncludesKotlinGradle``, which requires the build-system
  ## token AND the language-runtime token. M42's ``dotnet`` token
  ## covers both the SDK driver and the runtime since the .NET SDK
  ## ships them as a single binary distribution.
  if source.len == 0:
    return false
  var sawDotnet = false
  var inBlock = false
  proc consume(token: string) {.closure.} =
    if token == "dotnet" or token == "dotnet-sdk" or token == "csharp":
      sawDotnet = true
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
  sawDotnet

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

proc extractMembers(source: string): seq[CSharpDotnetMember] =
  for name in extractExecutables(source):
    result.add(CSharpDotnetMember(name: name, kind: cdmExecutable))
  for name in extractLibraries(source):
    result.add(CSharpDotnetMember(name: name, kind: cdmLibrary))

proc findFirstCsproj(projectRoot: string): string =
  ## Scan the project root (non-recursively) for ``*.csproj`` files,
  ## sort them alphabetically, and return the first hit. M42 takes
  ## exactly one ``.csproj``; multi-project ``.sln`` is deferred.
  ## Returns the empty string when no ``.csproj`` is present.
  if not dirExists(extendedPath(projectRoot)):
    return ""
  var csprojs: seq[string] = @[]
  try:
    for kind, path in walkDir(projectRoot):
      if kind notin {pcFile, pcLinkToFile}:
        continue
      let basename = extractFilename(path)
      if basename.toLowerAscii.endsWith(".csproj"):
        csprojs.add(path)
  except OSError:
    return ""
  if csprojs.len == 0:
    return ""
  csprojs.sort(system.cmp[string])
  csprojs[0]

proc hasPackagesLockJson(projectRoot: string): bool =
  ## True when ``<projectRoot>/packages.lock.json`` exists. The M42
  ## spec calls this out as a HARD PRECONDITION — the offline-build
  ## guarantee relies on the lockfile naming every transitive NuGet
  ## package the project pulls.
  fileExists(extendedPath(projectRoot / "packages.lock.json"))

proc hasFsproj(projectRoot: string): bool =
  ## True when an F# project file is present at the root. The C#
  ## convention defers to a future F# convention in that case
  ## (matching the defensive sibling-conventions pattern).
  try:
    for kind, path in walkDir(projectRoot):
      if kind notin {pcFile, pcLinkToFile}:
        continue
      let basename = extractFilename(path)
      if basename.toLowerAscii.endsWith(".fsproj"):
        return true
  except OSError:
    discard
  false

proc dotnetExecutable(): string =
  ## Resolve a ``dotnet`` driver on PATH. On Windows the binary is
  ## usually ``dotnet.exe``; ``findExe`` resolves both shapes via
  ## PATHEXT.
  findExe("dotnet")

proc parseCsprojCoordinates(projectRoot: string): CSharpDotnetCoordinates =
  ## Locate the project's ``.csproj``. Returns a blank ``csprojPath`` when
  ## there is none; callers detect the blank and either raise or fall
  ## through.
  result.csprojPath = findFirstCsproj(projectRoot)

proc csharpDotnetRecognize(projectRoot: string;
                           request: ProviderGraphRequest): bool {.gcsafe.} =
  ## Recognition contract — see module docstring.
  let csproj = findFirstCsproj(projectRoot)
  if csproj.len == 0:
    return false
  if hasFsproj(projectRoot):
    return false
  # HARD PRECONDITION (M42 spec): packages.lock.json must be present.
  # The convention refuses to recognise when the lockfile is missing —
  # the offline-build guarantee can't hold without it.
  if not hasPackagesLockJson(projectRoot):
    return false
  let source = readReprobuildSource(projectRoot)
  if source.len == 0:
    return false
  if not usesIncludesCsharpDotnet(source):
    return false
  let members = extractMembers(source)
  if members.len == 0:
    return false
  if dotnetExecutable().len == 0:
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

proc collectCsharpInputs(projectRoot: string;
                        csprojPath: string): seq[string] =
  ## Conservative input enumeration for the build action: the
  ## ``.csproj`` + ``packages.lock.json`` + every ``.cs`` file
  ## recursively walked from the project root (excluding
  ## ``bin/`` / ``obj/`` / ``.repro/`` / ``.git/`` to avoid feeding
  ## MSBuild's own outputs back into the input set). Test sources are
  ## NOT excluded — a C# project's tests typically live in a separate
  ## ``*.Tests.csproj`` sibling project; the convention covers
  ## single-project layouts only.
  if not dirExists(extendedPath(projectRoot)):
    return @[]
  if csprojPath.len > 0 and fileExists(extendedPath(csprojPath)):
    result.add(csprojPath)
  let lockPath = projectRoot / "packages.lock.json"
  if fileExists(extendedPath(lockPath)):
    result.add(lockPath)
  # Walk for ``.cs`` sources. Skip directories MSBuild owns or that
  # carry generated output to avoid invalidation feedback loops.
  proc shouldSkipDir(name: string): bool =
    let lower = name.toLowerAscii
    lower in ["bin", "obj", ".repro", ".git", ".vs"]
  var stack: seq[string] = @[projectRoot]
  while stack.len > 0:
    let cur = stack[^1]
    stack.setLen(stack.len - 1)
    try:
      for kind, path in walkDir(cur):
        let basename = extractFilename(path)
        case kind
        of pcFile, pcLinkToFile:
          if basename.toLowerAscii.endsWith(".cs"):
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

proc emitBuildAction(projectRoot, dotnetExe, fragment, discoveryId: string;
                     coords: CSharpDotnetCoordinates): BuildActionDef =
  ## Emit the single ``dotnet build -c Release --no-restore --nologo
  ## --verbosity quiet --disable-build-servers <csproj>`` action. Its
  ## outputs are the ones ``csharp-dotnet-outputs`` discovered: ``TargetDir``
  ## and ``IntermediateOutputPath`` as opaque output trees and
  ## ``TargetPath`` as an obligatory output.
  ##
  ## ``-c Release`` enforces the Release-configuration build; its discovery
  ## evaluates the same configuration. ``--no-restore`` enforces the M42
  ## hermetic contract: ``dotnet`` MUST NOT consult NuGet during the
  ## action — the ``packages.lock.json`` + warmed ``~/.nuget/packages/``
  ## cache covers every package. ``--nologo`` + ``--verbosity quiet`` keep
  ## per-action logs readable. ``--disable-build-servers`` (SDK 7+) keeps
  ## the compiler and MSBuild servers from outliving the action.
  let argv = @[dotnetExe, "build",
               "-c", "Release",
               "--no-restore",
               "--nologo",
               "--verbosity", "quiet",
               "--disable-build-servers",
               coords.csprojPath]
  let inputs = collectCsharpInputs(projectRoot, coords.csprojPath) &
    @[fragment]
  buildAction(
    id = BuildActionId,
    call = inlineExecCall(argv, projectRoot),
    deps = @[discoveryId],
    inputs = inputs,
    outputs = @[],
    dynamicDepsFile = fragment,
    pool = "compile",
    # ``dotnet`` spawns MSBuild worker processes (Csc, the SDK resolver,
    # the framework-pack loader, etc.); the monitor records their real
    # read-set on top of the enumerated sources.
    dependencyPolicy = automaticMonitorPolicy(),
    commandStatsId = "csharp-dotnet.build",
    env = DotnetQuietEnvironment)

proc syntheticPackage(projectRoot: string;
                      members: seq[CSharpDotnetMember]): PackageDef =
  var name = "csharp_dotnet_convention"
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

proc csharpDotnetEmitFragment(projectRoot: string;
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
        "csharp-dotnet convention: no executable or library members " &
          "declared in " & projectFile)
    if dotnetExecutable().len == 0:
      raise newException(ValueError,
        "csharp-dotnet convention: no 'dotnet' on PATH (.NET SDK " &
          "required; install .NET SDK 8.0 LTS into " &
          "D:/metacraft-dev-deps/dotnet/8.0/ or via " &
          "'winget install Microsoft.DotNet.SDK.8')")
    let coords = parseCsprojCoordinates(projectRoot)
    if coords.csprojPath.len == 0:
      raise newException(ValueError,
        "csharp-dotnet convention: no '*.csproj' at project root " &
          projectRoot & "; multi-project '.sln' setups are deferred " &
          "(see M42 'Honest scope')")
    if not hasPackagesLockJson(projectRoot):
      raise newException(ValueError,
        "csharp-dotnet convention: 'packages.lock.json' missing at " &
          projectRoot & "; this is a HARD PRECONDITION for the M42 " &
          "offline-build guarantee. Run 'dotnet restore " &
          "--use-lock-file' once to generate.")
    let pkg = syntheticPackage(projectRoot, members)
    let registerAll = proc() =
      discard buildPool("compile", 8'u32)
      let dotnetExe = dotnetExecutable()
      var projectFiles = @[coords.csprojPath]
      let lockPath = projectRoot / "packages.lock.json"
      if fileExists(extendedPath(lockPath)):
        projectFiles.add(lockPath)
      let discovery = delegatedOutputsAction(ConventionName, "dotnet",
        BuildActionId, projectRoot, dotnetExe, inputs = projectFiles,
        extra = @[coords.csprojPath], env = DotnetQuietEnvironment)
      let buildAct = emitBuildAction(projectRoot, dotnetExe,
        discovery.fragment, discovery.action.id, coords)
      defaultTarget(target("default", @[discovery.action, buildAct]))
    result = buildPackageFragment(pkg, request, registerAll,
      includeDefault = false)

proc csharpDotnetConvention*(): LanguageConvention =
  ## The single value the standard provider binary registers at startup.
  LanguageConvention(
    name: "csharp-dotnet",
    recognize: csharpDotnetRecognize,
    emitFragment: csharpDotnetEmitFragment)
