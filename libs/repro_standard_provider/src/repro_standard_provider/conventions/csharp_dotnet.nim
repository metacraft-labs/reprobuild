## C# / .NET language convention (Tier 2b) — M42.
##
## Third managed-runtime-ecosystem standard-provider convention after
## the M40 ``java-maven`` and M41 ``kotlin-gradle`` siblings. Recognises
## a single ``*.csproj`` at the project root and shells out to a stock
## ``dotnet`` driver for a single offline ``dotnet build -c Release
## --no-restore --nologo --verbosity quiet`` invocation. The action graph
## is intentionally coarse: one build action that produces
## ``bin/Release/<TargetFramework>/<AssemblyName>.exe`` (or ``.dll`` for
## libraries) per declared member.
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
##   1. ``csharp-dotnet-build`` — single ``<dotnet> build -c Release
##      --no-restore --nologo --verbosity quiet <csproj>`` action under
##      the project root. Inputs: the ``.csproj`` plus
##      ``packages.lock.json`` plus every ``.cs`` source file recursively
##      walked from the project root (excluding ``bin/`` / ``obj/`` /
##      ``.repro/`` / ``.git/``). Outputs: one
##      ``bin/Release/<TargetFramework>/<AssemblyName>.<ext>`` per
##      declared member, where ``<ext>`` is ``.exe`` when the csproj
##      ``<OutputType>`` is ``Exe`` and ``.dll`` otherwise. Uses
##      ``declaredOnlyDependencyPolicy`` — ``dotnet`` spawns MSBuild
##      worker processes whose FS reads aren't reliably observed via
##      Windows DLL-interpose (same constraint M38 / M39 / M40 / M41
##      face for their configure / package / build actions).
##
## **Output paths** (parsed from ``.csproj``):
##   * ``<TargetFramework>`` (e.g. ``net8.0``). When the csproj uses
##     the plural ``<TargetFrameworks>`` (multi-target) M42 picks the
##     first one; multi-target output is DEFERRED.
##   * ``<AssemblyName>`` (optional). Defaults to the csproj filename
##     without the ``.csproj`` extension, matching MSBuild's own
##     default.
##   * ``<OutputType>`` (``Exe`` or ``Library``; defaults to
##     ``Library`` when absent). Determines the produced file's
##     extension (``.exe`` vs ``.dll``).
##   * Predicted path:
##     ``<projectRoot>/bin/Release/<TargetFramework>/<AssemblyName>.<ext>``.
##
## **Honest scope** (deferred):
##   * Multi-target ``<TargetFrameworks>`` (plural) — M42 picks the
##     first target; emitting per-TFM outputs is deferred.
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

const
  ScratchDirName* = ".repro/build"
    ## Top-level scratch directory under the project root. Identical to
    ## the M40 / M41 conventions' value, but M42 doesn't actually use
    ## it as a build dir — MSBuild writes to ``<projectRoot>/bin/`` and
    ## ``<projectRoot>/obj/`` (its own convention). The constant is
    ## retained for consistency.

  DotnetBinSubdir* = "bin"
    ## Sub-directory under the project root where MSBuild lays its
    ## final build outputs. Hard-coded by MSBuild's default
    ## ``$(OutputPath)`` derivation; the convention predicts the
    ## ``bin/Release/<TargetFramework>/`` path under it.

  DotnetReleaseSubdir* = "Release"
    ## Sub-directory under ``bin/`` corresponding to the build
    ## configuration. The convention pins ``-c Release`` so the path
    ## is fixed.

  DefaultTargetFramework* = "net8.0"
    ## Fallback target framework when the csproj omits both
    ## ``<TargetFramework>`` and ``<TargetFrameworks>``. ``net8.0`` is
    ## the M42 documented provisioning target (.NET SDK 8 LTS); .NET
    ## SDK 9 (the current latest on the M42 review host) ships an
    ## ``Microsoft.NETCore.App`` runtime pack that covers net8.0 by
    ## default so the fallback is widely buildable.

  DefaultOutputType* = "Library"
    ## MSBuild's default when ``<OutputType>`` is omitted from the
    ## csproj. The convention encodes the same default explicitly so
    ## the output-path prediction is unambiguous.

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
      ## ``.csproj`` is present at the project root.
    csprojName: string
      ## ``<csprojPath>`` basename without the ``.csproj`` extension.
      ## Used as the default ``<AssemblyName>`` when the csproj omits
      ## the tag (matching MSBuild's own default).
    targetFramework: string
      ## Value of the first ``<TargetFramework>`` tag, or the first
      ## entry of ``<TargetFrameworks>`` (semicolon-separated list)
      ## when only the plural form is present. Falls back to
      ## ``DefaultTargetFramework`` when both are absent.
    assemblyName: string
      ## Value of ``<AssemblyName>`` when present, otherwise
      ## ``csprojName``.
    outputType: string
      ## Value of ``<OutputType>`` when present, otherwise
      ## ``DefaultOutputType``. Compared case-insensitively against
      ## ``Exe`` to decide the produced file's extension.

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

proc extractSimpleXmlTag(source, tagName: string): string =
  ## Return the inner text of the first ``<tagName>...</tagName>``
  ## occurrence in ``source``. Intentionally crude — avoids pulling
  ## in an XML parser for parsing three scalar fields out of the M42
  ## csproj shape (``<TargetFramework>`` / ``<AssemblyName>`` /
  ## ``<OutputType>``). The helper assumes the tag's value is on a
  ## single line, the standard SDK-style csproj layout. Returns the
  ## empty string when the tag isn't found.
  ##
  ## NB: this does NOT handle XML comments or CDATA sections — the
  ## minimal M42 fixture (and 99% of real-world SDK-style csprojs)
  ## use a flat ``<PropertyGroup>`` shape that the naive search
  ## handles correctly. Matches the M40 ``extractSimpleXmlTag`` in
  ## ``java_maven.nim``.
  let openTag = "<" & tagName & ">"
  let closeTag = "</" & tagName & ">"
  let openIdx = source.find(openTag)
  if openIdx < 0:
    return ""
  let valueStart = openIdx + openTag.len
  let closeIdx = source.find(closeTag, start = valueStart)
  if closeIdx < 0:
    return ""
  source[valueStart ..< closeIdx].strip()

proc parseCsprojCoordinates(projectRoot: string): CSharpDotnetCoordinates =
  ## Parse ``<TargetFramework>`` (singular preferred), ``<AssemblyName>``
  ## (optional; defaults to csproj filename), and ``<OutputType>``
  ## (optional; defaults to ``Library``) from the project's
  ## ``.csproj`` so we can predict the produced binary's filename and
  ## path. Returns blank ``csprojPath`` when no ``.csproj`` is present;
  ## callers detect the blank and either raise or fall through.
  let csproj = findFirstCsproj(projectRoot)
  if csproj.len == 0:
    return
  result.csprojPath = csproj
  let basename = extractFilename(csproj)
  # Strip the ``.csproj`` extension — case-insensitive match per
  # MSBuild's own convention.
  let lowerBase = basename.toLowerAscii
  if lowerBase.endsWith(".csproj"):
    result.csprojName = basename[0 ..< basename.len - len(".csproj")]
  else:
    result.csprojName = basename
  var csprojSource = ""
  try:
    csprojSource = readFile(extendedPath(csproj))
  except CatchableError:
    discard
  if csprojSource.len > 0:
    # ``<TargetFramework>`` (singular) wins when present; otherwise
    # peel the first entry off ``<TargetFrameworks>`` (plural,
    # semicolon-separated).
    var tf = extractSimpleXmlTag(csprojSource, "TargetFramework")
    if tf.len == 0:
      let plural = extractSimpleXmlTag(csprojSource, "TargetFrameworks")
      if plural.len > 0:
        let first = plural.split(';')[0].strip()
        if first.len > 0:
          tf = first
    if tf.len > 0:
      result.targetFramework = tf
    let asmName = extractSimpleXmlTag(csprojSource, "AssemblyName")
    if asmName.len > 0:
      result.assemblyName = asmName
    let outType = extractSimpleXmlTag(csprojSource, "OutputType")
    if outType.len > 0:
      result.outputType = outType
  if result.targetFramework.len == 0:
    result.targetFramework = DefaultTargetFramework
  if result.assemblyName.len == 0:
    result.assemblyName = result.csprojName
  if result.outputType.len == 0:
    result.outputType = DefaultOutputType

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

proc producedBinaryExtension(outputType: string): string =
  ## ``.exe`` when the csproj declares ``<OutputType>Exe</OutputType>``,
  ## ``.dll`` otherwise. Compared case-insensitively so ``Exe`` and
  ## ``exe`` both work.
  if outputType.toLowerAscii == "exe":
    ".exe"
  else:
    ".dll"

proc producedBinaryPath(projectRoot: string;
                        coords: CSharpDotnetCoordinates): string =
  ## Predicted output path for the dotnet build's produced binary.
  ## MSBuild's default ``$(OutputPath)`` for a Release build with the
  ## SDK-style csproj is
  ## ``bin/Release/<TargetFramework>/<AssemblyName>.<ext>``. The
  ## extension depends on ``<OutputType>`` — ``.exe`` for ``Exe`` and
  ## ``.dll`` for ``Library`` (or any other value).
  let ext = producedBinaryExtension(coords.outputType)
  let fileName = coords.assemblyName & ext
  projectRoot / DotnetBinSubdir / DotnetReleaseSubdir /
    coords.targetFramework / fileName

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

proc emitBuildAction(projectRoot, dotnetExe: string;
                     coords: CSharpDotnetCoordinates): BuildActionDef =
  ## Emit the single ``dotnet build -c Release --no-restore --nologo
  ## --verbosity quiet <csproj>`` action. Outputs the predicted
  ## ``bin/Release/<TargetFramework>/<AssemblyName>.<ext>`` path under
  ## the project root.
  ##
  ## ``-c Release`` enforces the Release-configuration build (debug
  ## builds use ``$(OutputPath)`` = ``bin/Debug/``; the convention
  ## hard-pins Release to keep predicted output paths stable).
  ## ``--no-restore`` enforces the M42 hermetic contract: ``dotnet``
  ## MUST NOT consult NuGet during the action — the
  ## ``packages.lock.json`` + warmed ``~/.nuget/packages/`` cache
  ## covers every package. ``--nologo`` + ``--verbosity quiet`` keep
  ## per-action logs readable; MSBuild's default chatter (one line
  ## per target per project) is extremely verbose.
  let binaryPath = producedBinaryPath(projectRoot, coords)
  createDir(extendedPath(parentDir(binaryPath)))
  let argv = @[dotnetExe, "build",
               "-c", "Release",
               "--no-restore",
               "--nologo",
               "--verbosity", "quiet",
               coords.csprojPath]
  let inputs = collectCsharpInputs(projectRoot, coords.csprojPath)
  buildAction(
    id = "csharp-dotnet-build",
    call = inlineExecCall(argv, projectRoot),
    inputs = inputs,
    outputs = @[binaryPath],
    pool = "compile",
    # ``dotnet`` spawns MSBuild worker processes (Csc.exe, the SDK
    # resolver, the framework-pack loader, etc.) whose FS reads
    # aren't reliably observed via the Windows DLL-interpose path.
    # Same constraint M38/M39/M40/M41 face for their configure /
    # package / build actions. Enumerate inputs explicitly via
    # ``collectCsharpInputs`` so per-source invalidation still works
    # without monitoring.
    dependencyPolicy = automaticMonitorPolicy(),
    commandStatsId = "csharp-dotnet.build")

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
      let buildAct = emitBuildAction(projectRoot,
        dotnetExecutable(), coords)
      defaultTarget(target("default", @[buildAct]))
    result = buildPackageFragment(pkg, request, registerAll,
      includeDefault = false)

proc csharpDotnetConvention*(): LanguageConvention =
  ## The single value the standard provider binary registers at startup.
  LanguageConvention(
    name: "csharp-dotnet",
    recognize: csharpDotnetRecognize,
    emitFragment: csharpDotnetEmitFragment)
