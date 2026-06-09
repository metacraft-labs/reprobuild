var registry: seq[PackageDef] = @[]
var buildActionRegistry: seq[BuildActionDef] = @[]
var buildTargetRegistry: seq[BuildTargetDef] = @[]
var buildPoolRegistry: seq[BuildPoolDef] = @[]
var defaultBuildActionRegistry = ""
var targetExportRegistry: TargetExportTable = TargetExportTable()
  ## Named-Targets M1: project-scoped per-package target-export rows
  ## (implicit + explicit) collected during ``buildProc`` evaluation.
  ## The provider rolls these into the normalized graph artifact when
  ## emitting the GraphFragment so ``repro graph`` / ``repro why`` and
  ## the M2 CLI resolver consume one source of truth.

var currentOwningPackageOverride = ""
  ## Named-Targets M1: thread-local stash naming the package whose
  ## ``buildProc`` is currently executing. ``buildPackageFragment``
  ## (in ``runtime_provider.nim``) writes this before invoking the
  ## generated ``buildXyzPackage`` proc and clears it on exit. The
  ## ``recordImplicitTargetExports`` path consults this override so
  ## edges produced via a typed-tool wrapper defined in package A but
  ## called from package B's ``build:`` body are attributed to B (the
  ## edge's home), not A (the tool's home). When the override is
  ## empty the M1 wiring falls back to the literal package name the
  ## macro baked into the wrapper at expansion time.

type
  WorkspaceDepEdge* = object
    ## Mode 3 inter-package dependency edge.
    ##
    ## Recorded via the ``depends_on <pkg>: <dep1>, <dep2>`` macro (see
    ## ``macros_b.nim``). Each call appends one edge per declared
    ## dependency to ``workspaceDepRegistry``. The engine does NOT yet
    ## consume these edges for graph wiring — the Mode 3 Nim pilot
    ## (Three-Mode-Convention-System §"Open questions") establishes the
    ## DSL surface and the scanner; consumption of the edges by the
    ## standard provider is deferred to a follow-on milestone. The
    ## registry is therefore inspection-only today: ``repro deps refresh
    ## --check`` and tests read it back, but builds do not branch on it.
    package*: string
      ## The package the edge originates from. Matches the identifier
      ## used in ``package <name>:`` declarations.
    dependency*: string
      ## The in-workspace package this one depends on. Same naming rule
      ## as ``package``.

var workspaceDepRegistry: seq[WorkspaceDepEdge] = @[]

# ---------------------------------------------------------------------------
# Project-DSL-Composition M5 — Approach B active-build-context handle.
#
# Mirrors the v8 staged layer's `PackageBuildState` / `activeBuilds`
# (`tools/prototypes/v8/staged/package_catalog/project_package_dsl.nim`
# lines 42-129). Helper procs and unknown top-level Nim statements that
# reach typed-tool wrappers from OUTSIDE a literal `build:` block query
# this stack to find the active package frame; the `package` macro
# pushes a frame on entry to its lowered `build:` block and pops on exit.
#
# `ownerKind` distinguishes `"package"` (the build block sat directly at
# package top level — M1's symmetry rule) from artifact-owner kinds
# (`"executable"`, `"library"`, `"files"`, `"service"`). M5 only wires
# the package-owner shape; artifact-owner support follows in the
# M6 test-suite migration if needed.
# ---------------------------------------------------------------------------
type
  PackageBuildState* = ref object
    ownerKind*: string   ## "package" or "executable" / "library" / ...
    ownerName*: string   ## package name (or artifact ident when artifact-owned)
    packageName*: string ## the enclosing package — always set

var activeBuilds {.threadvar.}: seq[PackageBuildState]

proc beginBuildBlock*(packageName: string;
                      ownerKind = "package";
                      ownerName = ""): PackageBuildState {.dynOrStatic.} =
  ## Push a frame onto the active-build stack. Called by the lowered
  ## form of a `build:` block; `package` macro expansion wraps the
  ## user's build statements in a `try/finally` that pairs this with
  ## `endBuildBlock`. The returned handle is opaque to authors.
  result = PackageBuildState(
    ownerKind: ownerKind,
    ownerName: (if ownerName.len > 0: ownerName else: packageName),
    packageName: packageName)
  activeBuilds.add(result)

proc endBuildBlock*(state: PackageBuildState) {.dynOrStatic.} =
  ## Pop the matching frame. Safe to call with a stale handle — the
  ## stack is searched and the top-most matching frame is removed so
  ## an exception thrown across nested `build:` blocks unwinds cleanly.
  if activeBuilds.len == 0:
    return
  for i in countdown(activeBuilds.high, 0):
    if activeBuilds[i] == state:
      activeBuilds.delete(i)
      return
  # Fallback: just pop the top (shouldn't be reached in healthy code).
  activeBuilds.setLen(activeBuilds.len - 1)

proc currentBuildState*(): PackageBuildState {.dynOrStatic.} =
  ## Raises ``ValueError`` if no `build:` block is currently active.
  ## The error message names the typed tool only at the call site;
  ## here we surface a stable, traceable spelling.
  if activeBuilds.len == 0:
    raise newException(ValueError,
      "build DSL operation used outside an active build: block")
  activeBuilds[^1]

proc tryCurrentBuildState*(): PackageBuildState {.dynOrStatic.} =
  ## Returns nil instead of raising when no `build:` block is active.
  ## Helper-proc wrappers that want to surface a richer error use this
  ## and craft the message themselves.
  if activeBuilds.len == 0:
    return nil
  activeBuilds[^1]


const fs* = ReproFs()
const hcr* = ReproHcr()

when defined(reproProviderMode):
  var providerEvaluationInputRegistry: seq[GraphEvaluationInput] = @[]
  var currentProviderProjectRoot = ""
  var devEnvShellOpsRegistry: seq[DevEnvShellOp] = @[]
  var devEnvToolRegistry: seq[DevEnvToolRequirement] = @[]
  var devEnvActivityRegistry: seq[string] = @[]
  var devEnvTaskRegistry: seq[DevEnvTaskMetadata] = @[]
  var devEnvServiceRegistry: seq[DevEnvServiceMetadata] = @[]
  var devEnvDiagnosticRegistry: seq[DevEnvDiagnostic] = @[]

const
  BuildActionPayloadMagic = [byte(ord('R')), byte(ord('B')), byte(ord('A')),
    byte(ord('P'))]
  BuildActionPayloadVersion = 12'u16
    ## v12: Typed-Outputs M1 — appends a length-prefixed list of
    ## ``BuildActionTypedOutput`` entries after ``targetNames``. Each
    ## entry serialises ``fieldName: string``, ``types: seq[string]``,
    ## ``path: string`` so engine consumers can identify typed
    ## outputs (e.g. ``TestBinary``) without re-parsing the DSL.
    ## v11 payloads decode with an empty ``typedOutputs`` list.
    ##
    ## v11: Named-Targets M1 — appended ``targetNames: seq[string]``
    ## after the action cache policy. Older payloads (v1..v10) decode
    ## with an empty ``targetNames`` list.
  BuildTargetPayloadMagic = [byte(ord('R')), byte(ord('B')), byte(ord('T')),
    byte(ord('P'))]
  BuildTargetPayloadVersion = 2'u16
    ## v2: Named-Targets M1 — appends ``sourceFile`` + ``sourceLine`` so
    ## collision diagnostics from the target-export table can cite the
    ## explicit ``target "name", handle`` call site. v1 payloads decode
    ## with empty source-location strings.
  BuildPoolPayloadMagic = [byte(ord('R')), byte(ord('B')), byte(ord('P')),
    byte(ord('L'))]
  BuildPoolPayloadVersion = 1'u16
  TargetExportTablePayloadMagic = [byte(ord('R')), byte(ord('T')),
    byte(ord('E')), byte(ord('T'))]
    ## Named-Targets M1: tag for the project-scoped target-export table
    ## payload carried as a metadata node on the GraphFragment.
  TargetExportTablePayloadVersion = 1'u16

proc resetPackageRegistry*() {.dynOrStatic.} =
  registry.setLen(0)

proc registerPackageDef*(pkg: PackageDef) {.dynOrStatic.} =
  registry.add(pkg)

proc registeredPackages*(): seq[PackageDef] {.dynOrStatic.} =
  registry

proc resetWorkspaceDepRegistry*() {.dynOrStatic.} =
  ## Reset the Mode 3 ``depends_on`` registry. Test helpers call this
  ## between scenarios so registry entries don't leak across cases.
  workspaceDepRegistry.setLen(0)

proc registerWorkspaceDep*(package, dependency: string) {.dynOrStatic.} =
  ## Append one workspace dep edge. Called from the ``depends_on``
  ## macro expansion (one call per ``<dep>`` listed). Duplicates are
  ## NOT collapsed at registration time — the scanner emits a
  ## deduplicated set, but manual edges in ``repro.nim`` may overlap
  ## with scanned edges; downstream consumers (today: just the
  ## test/inspection surface) are responsible for set-union semantics.
  workspaceDepRegistry.add(WorkspaceDepEdge(
    package: package,
    dependency: dependency))

proc registeredWorkspaceDeps*(): seq[WorkspaceDepEdge] {.dynOrStatic.} =
  ## Return every ``depends_on`` edge recorded in evaluation order.
  workspaceDepRegistry

proc resetBuildActionRegistry*() {.dynOrStatic.} =
  buildActionRegistry.setLen(0)

proc registeredBuildActions*(): seq[BuildActionDef] {.dynOrStatic.} =
  buildActionRegistry

proc resetBuildTargetRegistry*() {.dynOrStatic.} =
  buildTargetRegistry.setLen(0)

proc registeredBuildTargets*(): seq[BuildTargetDef] {.dynOrStatic.} =
  buildTargetRegistry

proc resetBuildPoolRegistry*() {.dynOrStatic.} =
  buildPoolRegistry.setLen(0)

proc registeredBuildPools*(): seq[BuildPoolDef] {.dynOrStatic.} =
  buildPoolRegistry

proc resetDefaultBuildActionRegistry*() {.dynOrStatic.} =
  defaultBuildActionRegistry = ""

proc resetTargetExportRegistry*() {.dynOrStatic.} =
  ## Named-Targets M1: reset the per-package target-export registry.
  ## Called by ``buildPackageFragment`` between package evaluations so
  ## entries don't leak across fragments.
  targetExportRegistry = TargetExportTable()

proc registeredTargetExports*(): TargetExportTable {.dynOrStatic.} =
  ## Named-Targets M1: return the rolled-up target-export table for the
  ## current evaluation.
  targetExportRegistry

proc setCurrentOwningPackageOverride*(name: string) {.dynOrStatic.} =
  ## Named-Targets M1: set the active per-edge ``owningPackage`` while
  ## a package's ``buildProc`` is running. ``buildPackageFragment`` is
  ## the only caller; tests can set the override directly when
  ## exercising the export-table helpers in isolation.
  currentOwningPackageOverride = name

proc clearCurrentOwningPackageOverride*() {.dynOrStatic.} =
  ## Named-Targets M1: clear the override (paired with
  ## ``setCurrentOwningPackageOverride`` around the ``buildProc`` call).
  currentOwningPackageOverride = ""

proc currentOwningPackage*(): string {.dynOrStatic.} =
  ## Named-Targets M1: return the active override, or empty when no
  ## ``buildProc`` is currently running.
  currentOwningPackageOverride

proc defaultBuildAction*(id: string) {.dynOrStatic.} =
  defaultBuildActionRegistry = id

proc defaultBuildAction*(action: BuildActionDef) {.dynOrStatic.} =
  defaultBuildActionRegistry = action.id

proc defaultBuildAction*(target: BuildTargetDef) {.dynOrStatic.} =
  defaultBuildActionRegistry = target.name

proc defaultTarget*(action: BuildActionDef) {.dynOrStatic.} =
  defaultBuildAction(action)

proc defaultTarget*(target: BuildTargetDef) {.dynOrStatic.} =
  defaultBuildAction(target)

proc registeredDefaultBuildAction*(): string {.dynOrStatic.} =
  defaultBuildActionRegistry

when defined(reproProviderMode):
  proc resetProviderEvaluationInputRegistry() =
    providerEvaluationInputRegistry.setLen(0)

  proc resetDevEnvRegistry() =
    devEnvShellOpsRegistry.setLen(0)
    devEnvToolRegistry.setLen(0)
    devEnvActivityRegistry.setLen(0)
    devEnvTaskRegistry.setLen(0)
    devEnvServiceRegistry.setLen(0)
    devEnvDiagnosticRegistry.setLen(0)

  proc materialProviderPath(path: string): string =
    if path.len == 0 or path.isAbsolute:
      path
    else:
      os.normalizedPath(currentProviderProjectRoot / path)

  proc providerDirectoryInput*(path: string) {.dynOrStatic.} =
    providerEvaluationInputRegistry.add(
      directoryEnumerationInput(materialProviderPath(path), "", ""))

  proc providerDirectoryInput*(path, memberEntryPointId,
                               memberEntryPointBodyHash: string) {.dynOrStatic.} =
    let material = materialProviderPath(path)
    providerEvaluationInputRegistry.add(
      directoryEnumerationInput(material, memberEntryPointId,
        memberEntryPointBodyHash, memberArgumentRoot = material))

  proc registeredProviderEvaluationInputs(): seq[GraphEvaluationInput] =
    providerEvaluationInputRegistry

  proc selectedActivityList*(activity: string): seq[string] {.dynOrStatic.} =
    for item in activity.split(','):
      let stripped = item.strip()
      if stripped.len > 0:
        result.add(stripped)

  proc addUniqueActivity(value: string) =
    let stripped = value.strip()
    if stripped.len > 0 and devEnvActivityRegistry.find(stripped) < 0:
      devEnvActivityRegistry.add(stripped)

  proc addDevEnvShellOp(kind: DevEnvShellOpKind; name, value: string;
                        separator = $PathSep;
                        activities: openArray[string] = []) =
    devEnvShellOpsRegistry.add(DevEnvShellOp(
      kind: kind,
      name: name,
      value: value,
      separator: separator,
      activityRequirements: @activities))

  proc setEnv*(name, value: string; activities: openArray[string] = []) {.dynOrStatic.} =
    addDevEnvShellOp(deskSetEnv, name, value, activities = activities)

  proc unsetEnv*(name: string; activities: openArray[string] = []) {.dynOrStatic.} =
    addDevEnvShellOp(deskUnsetEnv, name, "", activities = activities)

  proc prependPath*(name, value: string; separator = $PathSep;
                    activities: openArray[string] = []) {.dynOrStatic.} =
    addDevEnvShellOp(deskPrependPath, name, value, separator, activities)

  proc appendPath*(name, value: string; separator = $PathSep;
                   activities: openArray[string] = []) {.dynOrStatic.} =
    addDevEnvShellOp(deskAppendPath, name, value, separator, activities)

  proc setPathList*(name: string; values: openArray[string];
                    separator = $PathSep;
                    activities: openArray[string] = []) {.dynOrStatic.} =
    addDevEnvShellOp(deskSetPathList, name, (@values).join(separator),
      separator, activities)

  proc setWorkingDirectory*(path: string; activities: openArray[string] = []) {.dynOrStatic.} =
    addDevEnvShellOp(deskSetWorkingDirectory, "PWD", materialProviderPath(path),
      activities = activities)

  proc useTool*(logicalName: string; packageSelector = "";
                executableName = ""; policyPath: openArray[string] = [];
                activities: openArray[string] = []) {.dynOrStatic.} =
    let selector =
      if packageSelector.len > 0: packageSelector else: logicalName
    devEnvToolRegistry.add(DevEnvToolRequirement(
      logicalName: logicalName,
      packageSelector: selector,
      executableName: if executableName.len > 0: executableName else: logicalName,
      policyPath: @policyPath,
      activityRequirements: @activities))

  proc activity*(name: string) {.dynOrStatic.} =
    addUniqueActivity(name)

  proc task*(name: string; command = ""; description = "";
             activities: openArray[string] = []) {.dynOrStatic.} =
    devEnvTaskRegistry.add(DevEnvTaskMetadata(
      name: name,
      description: description,
      command: command,
      activityRequirements: @activities))

  proc servicePlaceholder*(name: string; metadata = "";
                           activities: openArray[string] = []) {.dynOrStatic.} =
    devEnvServiceRegistry.add(DevEnvServiceMetadata(
      name: name,
      activityRequirements: @activities,
      metadata: metadata))

  proc diagnostic*(message: string; severity = dedsInfo;
                   sourceFile = ""; sourceLine = 0) {.dynOrStatic.} =
    devEnvDiagnosticRegistry.add(DevEnvDiagnostic(
      severity: severity,
      message: message,
      sourceFile: sourceFile,
      sourceLine: sourceLine))

  proc readDevEnvFile*(path: string): string {.dynOrStatic.} =
    let material = materialProviderPath(path)
    providerEvaluationInputRegistry.add(fileReadInput(material))
    readFile(extendedPath(material))

  proc developOverridePath*(dependency: string): string {.dynOrStatic.} =
    ## Return the active local develop-mode path for `dependency`, if one is
    ## present in the local workspace metadata supplied by the engine.
    let metadataPath = getEnv("REPRO_DEVELOP_OVERRIDES_FILE")
    if metadataPath.len == 0 or not fileExists(extendedPath(metadataPath)):
      return ""
    let metadataInput = fileReadInput(metadataPath)
    providerEvaluationInputRegistry.add(metadataInput)
    let metadata = parseFile(extendedPath(metadataPath))
    if metadata.kind != JObject or not metadata.hasKey("overrides"):
      return ""
    for item in metadata["overrides"]:
      if item.kind != JObject:
        continue
      let node =
        if item.hasKey("node"): item["node"].getStr()
        elif item.hasKey("dependency"): item["dependency"].getStr()
        else: ""
      if node == dependency:
        result = item{"path"}.getStr()
        providerEvaluationInputRegistry.add(GraphEvaluationInput(
          kind: gevDevelopModeOverride,
          identity: dependency,
          digest: result))
        return

  proc activityRecordIsActive(requirements, selected: openArray[string]): bool =
    if requirements.len == 0:
      return true
    for requirement in requirements:
      if selected.find(requirement) < 0:
        return false
    true

  proc activeShellOps(selected: openArray[string]): seq[DevEnvShellOp] =
    for op in devEnvShellOpsRegistry:
      if activityRecordIsActive(op.activityRequirements, selected):
        result.add(op)

  proc activeToolRequirements(selected: openArray[string]):
      seq[DevEnvToolRequirement] =
    for tool in devEnvToolRegistry:
      if activityRecordIsActive(tool.activityRequirements, selected):
        result.add(tool)

  proc activeTasks(selected: openArray[string]): seq[DevEnvTaskMetadata] =
    for task in devEnvTaskRegistry:
      if activityRecordIsActive(task.activityRequirements, selected):
        result.add(task)

  proc activeServices(selected: openArray[string]): seq[DevEnvServiceMetadata] =
    for service in devEnvServiceRegistry:
      if activityRecordIsActive(service.activityRequirements, selected):
        result.add(service)

else:
  proc providerDirectoryInput*(path: string) {.dynOrStatic.} =
    discard path

  proc providerDirectoryInput*(path, memberEntryPointId,
                               memberEntryPointBodyHash: string) {.dynOrStatic.} =
    discard path
    discard memberEntryPointId
    discard memberEntryPointBodyHash

  proc developOverridePath*(dependency: string): string {.dynOrStatic.} =
    discard dependency
    ""

proc dirListing*(path: string): seq[string] {.dynOrStatic.} =
  if not dirExists(extendedPath(path)):
    return @[]
  # TODO(win-longpath): walk results escape; needs review
  for kind, child in walkDir(path):
    if kind in {pcFile, pcDir}:
      result.add(child)
  result.sort(system.cmp[string])

proc cliArg*(name: string; value: string; kind = cpkFlag; position = 0;
             alias = ""; format = cafSeparate;
             placement = capAfterSubcommand;
             repeated = false): PublicCliArg {.dynOrStatic.} =
  PublicCliArg(name: name, nimType: "string", kind: kind, position: position,
    alias: alias, format: format, placement: placement, repeated: repeated,
    encodedValue: value)

proc cliArg*(name: string; value: int; kind = cpkFlag; position = 0;
             alias = ""; format = cafSeparate;
             placement = capAfterSubcommand;
             repeated = false): PublicCliArg {.dynOrStatic.} =
  PublicCliArg(name: name, nimType: "int", kind: kind, position: position,
    alias: alias, format: format, placement: placement, repeated: repeated,
    encodedValue: $value)

proc cliArg*(name: string; value: bool; kind = cpkFlag; position = 0;
             alias = ""; format = cafSeparate;
             placement = capAfterSubcommand;
             repeated = false): PublicCliArg {.dynOrStatic.} =
  PublicCliArg(name: name, nimType: "bool", kind: kind, position: position,
    alias: alias, format: format, placement: placement, repeated: repeated,
    encodedValue: $value)

proc cliArgSeq*(name: string; value: seq[string]; kind = cpkFlag; position = 0;
                alias = ""; format = cafSeparate;
                placement = capAfterSubcommand;
                repeated = false): PublicCliArg {.dynOrStatic.} =
  PublicCliArg(name: name, nimType: "seq[string]", kind: kind, position: position,
    alias: alias, format: format, placement: placement, repeated: repeated,
    encodedValue: value.join("\x1f"))

proc inputArg*(name: string; value: string; kind = cpkFlag; position = 0;
               alias = ""; format = cafSeparate;
               placement = capAfterSubcommand;
               repeated = false): PublicCliArg {.dynOrStatic.} =
  result = cliArg(name, value, kind, position, alias, format, placement,
    repeated)
  result.role = carInput

proc outputArg*(name: string; value: string; kind = cpkFlag; position = 0;
                alias = ""; format = cafSeparate;
                placement = capAfterSubcommand;
                repeated = false): PublicCliArg {.dynOrStatic.} =
  result = cliArg(name, value, kind, position, alias, format, placement,
    repeated)
  result.role = carOutput

proc inputArgSeq*(name: string; value: seq[string]; kind = cpkFlag; position = 0;
                  alias = ""; format = cafSeparate;
                  placement = capAfterSubcommand;
                  repeated = false): PublicCliArg {.dynOrStatic.} =
  result = cliArgSeq(name, value, kind, position, alias, format, placement,
    repeated)
  result.role = carInput

proc outputArgSeq*(name: string; value: seq[string]; kind = cpkFlag;
                   position = 0; alias = ""; format = cafSeparate;
                   placement = capAfterSubcommand;
                   repeated = false): PublicCliArg {.dynOrStatic.} =
  result = cliArgSeq(name, value, kind, position, alias, format, placement,
    repeated)
  result.role = carOutput

proc publicCliCall*(packageName, executableName, subcommand,
                    providerEntrypointId: string;
                    arguments: openArray[PublicCliArg]): PublicCliCall {.dynOrStatic.} =
  PublicCliCall(
    packageName: packageName,
    executableName: executableName,
    subcommand: subcommand,
    providerEntrypointId: providerEntrypointId,
    arguments: @arguments)

proc selectedExecutable*(packageName, executableName: string): SelectedExecutable {.dynOrStatic.} =
  SelectedExecutable(packageName: packageName, executableName: executableName)

proc defaultDependencyPolicy*(
    ignoredInputPrefixes: openArray[string] = []):
    BuildActionDependencyPolicy {.dynOrStatic.} =
  BuildActionDependencyPolicy(
    kind: bdpDefault,
    ignoredInputPrefixes: @ignoredInputPrefixes)

proc declaredOnlyDependencyPolicy*(
    ignoredInputPrefixes: openArray[string] = []):
    BuildActionDependencyPolicy {.dynOrStatic.} =
  BuildActionDependencyPolicy(
    kind: bdpDeclaredOnly,
    ignoredInputPrefixes: @ignoredInputPrefixes)

proc automaticMonitorPolicy*(
    ignoredInputPrefixes: openArray[string] = []):
    BuildActionDependencyPolicy {.dynOrStatic.} =
  BuildActionDependencyPolicy(
    kind: bdpAutomaticMonitor,
    ignoredInputPrefixes: @ignoredInputPrefixes)

proc makeDepfilePolicy*(depfile = "";
                        ignoredInputPrefixes: openArray[string] = []):
    BuildActionDependencyPolicy {.dynOrStatic.} =
  BuildActionDependencyPolicy(
    kind: bdpMakeDepfile,
    depfile: depfile,
    ignoredInputPrefixes: @ignoredInputPrefixes)

proc defaultActionCachePolicy*(): ActionCacheFingerprintPolicy {.dynOrStatic.} =
  acfpTimestamp

const
  BuiltinPackageName = "reprobuild.builtin"
  BuiltinFsExecutable = "fs"
  BuiltinHcrExecutable = "hcr"
  BuiltinExecExecutable = "exec"

proc builtinFsCall(command: string; arguments: openArray[PublicCliArg]):
    PublicCliCall =
  publicCliCall(BuiltinPackageName, BuiltinFsExecutable, command,
    BuiltinPackageName & "." & BuiltinFsExecutable & "." & command, arguments)

proc builtinHcrCall(command: string; arguments: openArray[PublicCliArg]):
    PublicCliCall =
  publicCliCall(BuiltinPackageName, BuiltinHcrExecutable, command,
    BuiltinPackageName & "." & BuiltinHcrExecutable & "." & command, arguments)

proc inlineExecCall*(argv: openArray[string]; cwd = ""): PublicCliCall {.dynOrStatic.} =
  ## Builds a PublicCliCall that, when lowered by the engine, runs `argv`
  ## directly via the OS spawn primitive without consulting any package
  ## profile or wrapper script. The action's LaunchPlan is fully realized
  ## at provider-compile time and the binary graph cache stores the literal
  ## argv. Intended for generated provider files (such as the one emitted
  ## by the CMake Reprobuild generator) whose upstream build system already
  ## knows the absolute executable path and arguments of one build edge.
  ## Pair this with an `external` block (see Inline External Profiles in
  ## reprobuild-specs/External-Package-Catalog-Adapters.md) when the call
  ## also needs to expose the executable as a typed tool to other call
  ## sites in the same project file.
  var arguments: seq[PublicCliArg] = @[
    cliArgSeq("argv", @argv, cpkPositional, 0)
  ]
  if cwd.len > 0:
    arguments.add(cliArg("cwd", cwd))
  publicCliCall(BuiltinPackageName, BuiltinExecExecutable, "",
    BuiltinPackageName & "." & BuiltinExecExecutable, arguments)
proc builtinActionIdPart(value: string): string =
  for ch in value:
    if ch in {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '.', '_', '-'}:
      result.add(ch)
    else:
      result.add("-" & toHex(ord(ch), 2).toLowerAscii())
  if result.len == 0:
    result = "value"

proc defaultBuiltinActionId(command: string; key: string): string =
  "fs-" & builtinActionIdPart(command) & "-" & builtinActionIdPart(key)

proc preserveTreeManifestOutput(actionId: string): string =
  var sanitized = ""
  for ch in actionId:
    if ch in {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '-', '_', '.'}:
      sanitized.add(ch)
    else:
      sanitized.add('_')
  if sanitized.len == 0:
    sanitized = "action"
  ".repro/preserve-tree/" & sanitized & ".manifest"

proc buildAction*(id: string; call: PublicCliCall;
                  deps: openArray[string] = [];
                  inputs: openArray[string] = [];
                  outputs: openArray[string] = [];
                  pool = "";
                  poolUnits = 1'u32;
                  depfile = "";
                  dynamicDepsFile = "";
                  cacheable = true;
                  commandStatsId = "";
                  dependencyPolicy = defaultDependencyPolicy();
                  actionCachePolicy = defaultActionCachePolicy()):
    BuildActionDef {.dynOrStatic.} =
  result = BuildActionDef(
    id: id,
    call: call,
    deps: @deps,
    inputs: @inputs,
    outputs: @outputs,
    pool: pool,
    poolUnits: poolUnits,
    depfile: depfile,
    dynamicDepsFile: dynamicDepsFile,
    cacheable: cacheable,
    commandStatsId: if commandStatsId.len > 0: commandStatsId else: id,
    dependencyPolicy: dependencyPolicy,
    actionCachePolicy: actionCachePolicy)
  buildActionRegistry.add(result)

proc buildPool*(name: string; capacity: uint32): BuildPoolDef {.discardable, dynOrStatic.} =
  result = BuildPoolDef(name: name, capacity: capacity)
  buildPoolRegistry.add(result)

proc addUniqueValue(values: var seq[string]; value: string) =
  if value.len > 0 and values.find(value) < 0:
    values.add(value)

proc actionIds*(actions: openArray[BuildActionDef]): seq[string] {.dynOrStatic.} =
  for action in actions:
    result.addUniqueValue(action.id)

proc targetNames*(targets: openArray[BuildTargetDef]): seq[string] {.dynOrStatic.} =
  for target in targets:
    result.addUniqueValue(target.name)

proc combineActionDeps*(deps: openArray[string];
                        after: openArray[BuildActionDef] = []): seq[string] {.dynOrStatic.} =
  for dep in deps:
    result.addUniqueValue(dep)
  for action in after:
    result.addUniqueValue(action.id)

proc registerBuildTarget(target: BuildTargetDef): BuildTargetDef =
  result = target
  buildTargetRegistry.add(result)

proc target*(name: string; action: BuildActionDef): BuildTargetDef
    {.discardable, dynOrStatic.} =
  registerBuildTarget(BuildTargetDef(name: name, actions: @[action.id]))

proc target*(name: string; actions: openArray[BuildActionDef]): BuildTargetDef
    {.discardable, dynOrStatic.} =
  var actionRefs: seq[string] = @[]
  for action in actions:
    actionRefs.addUniqueValue(action.id)
  registerBuildTarget(BuildTargetDef(name: name, actions: actionRefs))

proc exportTarget*(name: string; action: BuildActionDef): BuildTargetDef
    {.discardable, dynOrStatic.} =
  target(name, action)

proc exportTarget*(name: string; actions: openArray[BuildActionDef]):
    BuildTargetDef {.discardable, dynOrStatic.} =
  target(name, actions)

proc aggregate*(name: string; actions: openArray[BuildActionDef] = [];
                targets: openArray[BuildTargetDef] = []): BuildTargetDef
    {.discardable, dynOrStatic.} =
  var actionRefs: seq[string] = @[]
  var targetRefs: seq[string] = @[]
  for action in actions:
    actionRefs.addUniqueValue(action.id)
  for target in targets:
    targetRefs.addUniqueValue(target.name)
  registerBuildTarget(BuildTargetDef(
    name: name,
    actions: actionRefs,
    targets: targetRefs))

# ---------------------------------------------------------------------------
# Spec-Implementation M0 — build graph collections (per
# reprobuild-specs/Build-Graph-Collections.md).
#
# A build graph collection is a named set of build-graph targets that
# ``repro build <name>`` materializes as a unit. Distinct from package
# *shared* collections (which accumulate values during package
# evaluation and get finalized into configs/resources): build graph
# collections live at graph emission time and operate on target
# identities only.
#
# M0 implementation note: the runtime data model is shared with
# ``aggregate`` — collections and aggregates both produce a
# ``BuildTargetDef`` that lands in the project-scoped target-export
# table. The CLI resolver treats them identically. A future milestone
# splits the registries so the build-report can distinguish
# ``kind: "collection"`` from ``kind: "aggregate"`` per
# Build-Graph-Collections.md §"Build-Report Integration". For M0, the
# semantic distinction lives in the call-site naming: authors call
# ``collect`` for build graph collections (test/bench/lint/docs/package
# and project-defined ones) and ``aggregate`` for ad-hoc target groups
# that are not part of the collection contract.
# ---------------------------------------------------------------------------

proc collect*(name: string; actions: openArray[BuildActionDef] = [];
              targets: openArray[BuildTargetDef] = []): BuildTargetDef
    {.discardable, dynOrStatic.} =
  ## Register a build graph collection under ``name`` carrying every
  ## supplied build-edge action and/or sub-target. ``repro build <name>``
  ## materializes the union of their dependency closures in one engine
  ## pass; the conventional collections (``test``, ``bench``, ``lint``,
  ## ``docs``, ``package``) additionally receive CLI verb aliases per
  ## Build-Graph-Collections.md §"Verb Aliases for Conventional
  ## Collections".
  ##
  ## See ``aggregate`` for ad-hoc target groupings that are not part of
  ## the collection contract.
  aggregate(name, actions, targets)

proc exportTarget*(name: string; target: BuildTargetDef): BuildTargetDef
    {.discardable, dynOrStatic.} =
  registerBuildTarget(BuildTargetDef(name: name, targets: @[target.name]))

proc exportTarget*(name: string; targets: openArray[BuildTargetDef]):
    BuildTargetDef {.discardable, dynOrStatic.} =
  var targetRefs: seq[string] = @[]
  for target in targets:
    targetRefs.addUniqueValue(target.name)
  registerBuildTarget(BuildTargetDef(name: name, targets: targetRefs))

proc addUniquePath(paths: var seq[string]; path: string) =
  let stripped = path.strip()
  if stripped.len > 0 and paths.find(stripped) < 0:
    paths.add(stripped)

proc addRoleValues(paths: var seq[string]; arg: PublicCliArg) =
  if arg.nimType.normalize == "bool":
    return
  if arg.nimType.normalize == "seq[string]":
    if arg.encodedValue.len > 0:
      for item in arg.encodedValue.split("\x1f"):
        paths.addUniquePath(item)
  else:
    paths.addUniquePath(arg.encodedValue)

proc declaredInputPaths*(call: PublicCliCall): seq[string] {.dynOrStatic.} =
  for arg in call.arguments:
    if arg.role == carInput:
      result.addRoleValues(arg)

proc declaredOutputPaths*(call: PublicCliCall): seq[string] {.dynOrStatic.} =
  for arg in call.arguments:
    if arg.role == carOutput:
      result.addRoleValues(arg)

# ---------------------------------------------------------------------------
# Named-Targets M1: implicit-name basename rule + project-scoped exports.
# ---------------------------------------------------------------------------

const
  ## Conventional artifact extensions stripped by the M1 basename rule.
  ## Order matters: ``.so.<ver>`` is detected separately by a regex-free
  ## match inside ``stripArtifactExtension``. The single-token suffixes
  ## below cover the rest.
  artifactSingleExts = [".exe", ".dll", ".dylib", ".lib", ".so", ".a",
    ".o", ".obj", ".d"]

proc isFilesystemShapedValue*(value: string): bool {.dynOrStatic.} =
  ## Named-Targets M1: a value is "filesystem-shaped" — and therefore
  ## eligible for the basename + extension-stripping rule — when it
  ## contains a path separator (``/`` or ``\\``) OR when the last
  ## segment after splitting on path separators contains a ``.``.
  ## Non-filesystem-shaped values pass through verbatim per the spec.
  if value.len == 0:
    return false
  for ch in value:
    if ch == '/' or ch == '\\':
      return true
  # No separators: only filesystem-shaped if the value itself looks
  # like a file (last segment contains a dot).
  '.' in value

proc lastPathSegment(value: string): string =
  var i = value.len
  while i > 0:
    let ch = value[i - 1]
    if ch == '/' or ch == '\\':
      break
    dec i
  if i >= value.len:
    return value
  value[i ..< value.len]

proc stripArtifactExtension(name: string): string =
  ## Apply the M1 basename rule's extension-stripping step. Handles the
  ## ``.so.<ver>`` form (e.g. ``libfoo.so.1.2``) by matching a ``.so.``
  ## marker and dropping everything from that point. The single-token
  ## suffixes (``.exe``, ``.dll``, ``.dylib``, ``.lib``, ``.so``,
  ## ``.a``, ``.o``, ``.obj``) are stripped if they appear at the end.
  result = name
  let lower = result.toLowerAscii()
  # ``.so.<ver>`` — handle before ``.so`` so ``libfoo.so.1.2`` collapses
  # to ``libfoo`` rather than ``libfoo.so.1``.
  let soVerMarker = ".so."
  let soVerPos = lower.find(soVerMarker)
  if soVerPos > 0:
    return result[0 ..< soVerPos]
  for ext in artifactSingleExts:
    if lower.endsWith(ext):
      return result[0 ..< result.len - ext.len]

proc applyImplicitTargetNameBasenameRule*(value: string): string {.dynOrStatic.} =
  ## Named-Targets M1 §"Basename Rule" canonicalisation. Non-path values
  ## pass through verbatim; filesystem-shaped values are reduced to
  ## their basename, with conventional artifact extensions stripped.
  if not isFilesystemShapedValue(value):
    return value
  stripArtifactExtension(lastPathSegment(value))

proc callArgEncodedValue*(call: PublicCliCall; flagName: string):
    tuple[present: bool; value: string] {.dynOrStatic.} =
  ## Look up a flag (or positional) by ``name`` on a ``PublicCliCall``
  ## and return its encoded value. ``present`` is false when the call
  ## did not supply a value for the flag (the macro elides the arg in
  ## that case). ``seq[string]``-typed args report their join-encoded
  ## form; M1 does not consume those in the canonical-name slot
  ## (multiple names would be ambiguous), but auxiliary names from
  ## ``outputs`` lists may still produce one entry per element.
  for arg in call.arguments:
    if arg.name == flagName:
      return (present: true, value: arg.encodedValue)
  (present: false, value: "")

proc computeImplicitTargetNames*(call: PublicCliCall;
                                  outputFlags: openArray[string]):
    seq[string] {.dynOrStatic.} =
  ## Named-Targets M1: walk the call's ``outputFlags`` set in declaration
  ## order, read each flag's value from ``call.arguments``, and apply
  ## the basename + extension-stripping rule. Flags whose values were
  ## not supplied at the call site contribute no entry. ``seq[string]``
  ## flags expand to one entry per element (in declaration order).
  for flagName in outputFlags:
    var matched = false
    for arg in call.arguments:
      if arg.name != flagName:
        continue
      matched = true
      if arg.nimType.normalize == "seq[string]":
        if arg.encodedValue.len == 0:
          break
        for item in arg.encodedValue.split("\x1f"):
          if item.len > 0:
            result.add(applyImplicitTargetNameBasenameRule(item))
      elif arg.nimType.normalize == "bool":
        break
      else:
        if arg.encodedValue.len > 0:
          result.add(applyImplicitTargetNameBasenameRule(arg.encodedValue))
      break
    if not matched:
      discard

proc raiseTargetCollision(name, owningPackage: string;
                          existing, addition: TargetExportEntry) {.noreturn.} =
  raise newException(ValueError,
    "duplicate implicit target name '" & name & "' within package '" &
      owningPackage & "': first registered for action '" & existing.actionId &
      "' at " & existing.sourceFile & ":" & $existing.sourceLine &
      "; re-registered for action '" & addition.actionId & "' at " &
      addition.sourceFile & ":" & $addition.sourceLine)

proc qualifiedExportName(owningPackage, name: string): string =
  owningPackage & ":" & name

proc registerTargetExportEntry(entry: TargetExportEntry) =
  ## Append one entry to ``targetExportRegistry.entries``, applying the
  ## same-package collision rule (raise) and the cross-package
  ## ambiguity rule (record in ``ambiguities``).
  for existing in targetExportRegistry.entries:
    if existing.name == entry.name and
        existing.owningPackage == entry.owningPackage and
        existing.actionId != entry.actionId:
      raiseTargetCollision(entry.name, entry.owningPackage, existing, entry)

  targetExportRegistry.entries.add(entry)

  # Cross-package ambiguity bookkeeping: collect every package that
  # has registered ``entry.name`` so far. When two or more distinct
  # packages share the name, surface it under the unqualified form.
  var packages: seq[string] = @[]
  for existing in targetExportRegistry.entries:
    if existing.name == entry.name:
      if packages.find(existing.owningPackage) < 0:
        packages.add(existing.owningPackage)
  if packages.len >= 2:
    var candidates: seq[string] = @[]
    for pkg in packages:
      candidates.add(qualifiedExportName(pkg, entry.name))
    var foundExisting = false
    for i in 0 ..< targetExportRegistry.ambiguities.len:
      if targetExportRegistry.ambiguities[i].name == entry.name:
        targetExportRegistry.ambiguities[i].candidates = candidates
        foundExisting = true
        break
    if not foundExisting:
      targetExportRegistry.ambiguities.add(TargetExportAmbiguity(
        name: entry.name,
        candidates: candidates))

proc registerImplicitTargetExports*(actionId, owningPackage: string;
                                    names: openArray[string];
                                    sourceFile: string;
                                    sourceLine: int) {.dynOrStatic.} =
  ## Named-Targets M1: register one ``TargetExportEntry`` per implicit
  ## name on the edge. Multi-name edges (auxiliary outputs) contribute
  ## multiple rows pointing at the same ``actionId``. Same-name
  ## within-package collisions raise. Cross-package collisions are
  ## recorded as ambiguities consumed by the M2 resolver.
  ##
  ## ``actionId`` and the call-site source location are passed
  ## explicitly so the emit-site macro can supply them without the
  ## helper having to walk the action registry. The effective owning
  ## package is the active ``buildPackageFragment`` override when set
  ## (the call site's package); otherwise the literal ``owningPackage``
  ## the macro baked into the wrapper at expansion time (the tool's
  ## package — fallback for direct DSL helpers and tests).
  let effectiveOwner =
    if currentOwningPackageOverride.len > 0:
      currentOwningPackageOverride
    else:
      owningPackage
  for name in names:
    if name.len == 0:
      continue
    registerTargetExportEntry(TargetExportEntry(
      name: name,
      kind: tekImplicit,
      owningPackage: effectiveOwner,
      actionId: actionId,
      sourceFile: sourceFile,
      sourceLine: sourceLine))

proc registerExplicitTargetExport*(target: BuildTargetDef;
                                   owningPackage: string) {.dynOrStatic.} =
  ## Named-Targets M1: surface a ``target "name", handle`` declaration
  ## in the target-export table as a ``tekExplicit`` row. The
  ## ``actionId`` is the first action handle the target references
  ## (most explicit targets attach to exactly one action; the
  ## aggregate-over-many form falls back to the target's own name as
  ## the handle). Collision/ambiguity logic matches the implicit case.
  if target.name.len == 0:
    return
  let handle =
    if target.actions.len > 0: target.actions[0] else: target.name
  registerTargetExportEntry(TargetExportEntry(
    name: target.name,
    kind: tekExplicit,
    owningPackage: owningPackage,
    actionId: handle,
    sourceFile: target.sourceFile,
    sourceLine: target.sourceLine))

proc recordCommandAction*(id: string; call: PublicCliCall;
                          deps: openArray[string] = [];
                          extraInputs: openArray[string] = [];
                          extraOutputs: openArray[string] = [];
                          pool = "";
                          poolUnits = 1'u32;
                          depfile = "";
                          cacheable = true;
                          commandStatsId = "";
                          dependencyPolicy = defaultDependencyPolicy();
                          actionCachePolicy = defaultActionCachePolicy()):
    BuildActionDef {.dynOrStatic.} =
  var inputs = declaredInputPaths(call)
  var outputs = declaredOutputPaths(call)
  for item in extraInputs:
    inputs.addUniquePath(item)
  for item in extraOutputs:
    outputs.addUniquePath(item)
  buildAction(
    id,
    call,
    deps = deps,
    inputs = inputs,
    outputs = outputs,
    pool = pool,
    poolUnits = poolUnits,
    depfile = depfile,
    cacheable = cacheable,
    commandStatsId = commandStatsId,
    dependencyPolicy = dependencyPolicy,
    actionCachePolicy = actionCachePolicy)

proc setRegisteredActionTargetNames*(actionId: string;
                                     names: openArray[string]) {.dynOrStatic.} =
  ## Named-Targets M1: write the computed implicit target names back
  ## onto the registry's ``BuildActionDef`` so that downstream consumers
  ## (graph emission, ``repro graph``, ``repro why``) see the same names
  ## as the per-package target-export table. The lookup walks the
  ## registry in registration order; on hit the entry is updated in
  ## place. No-op when the id is not present (defensive — the wrapper
  ## always calls this immediately after ``recordToolInvocation``).
  for i in 0 ..< buildActionRegistry.len:
    if buildActionRegistry[i].id == actionId:
      buildActionRegistry[i].targetNames = @names
      return

proc appendRegisteredActionTypedOutput*(actionId: string;
                                        fieldName: string;
                                        types: openArray[string];
                                        path: string) {.dynOrStatic.} =
  ## Typed-Outputs M1: append one ``BuildActionTypedOutput`` row to the
  ## registry entry's ``typedOutputs`` list. The typed-tool wrapper
  ## proc calls this once per ``TypedOutputDef`` immediately after
  ## ``recordToolInvocation`` so the engine artifact carries the
  ## resolved (fieldName, types, path) triple. No-op when the id is
  ## not present (defensive — same shape as
  ## ``setRegisteredActionTargetNames``).
  for i in 0 ..< buildActionRegistry.len:
    if buildActionRegistry[i].id == actionId:
      buildActionRegistry[i].typedOutputs.add(BuildActionTypedOutput(
        fieldName: fieldName,
        types: @types,
        path: path))
      return

proc recordToolInvocation*(id: string; call: PublicCliCall;
                           deps: openArray[string] = [];
                           extraInputs: openArray[string] = [];
                           extraOutputs: openArray[string] = [];
                           pool = "";
                           poolUnits = 1'u32;
                           depfile = "";
                           cacheable = true;
                           commandStatsId = "";
                           dependencyPolicy = defaultDependencyPolicy();
                           actionCachePolicy = defaultActionCachePolicy()):
    BuildActionDef {.dynOrStatic.} =
  recordCommandAction(
    id,
    call,
    deps = deps,
    extraInputs = extraInputs,
    extraOutputs = extraOutputs,
    pool = pool,
    poolUnits = poolUnits,
    depfile = depfile,
    cacheable = cacheable,
    commandStatsId = commandStatsId,
    dependencyPolicy = dependencyPolicy,
    actionCachePolicy = actionCachePolicy)

proc prepareObject*(tool: ReproHcr; input, output: string;
                    functionName = ""; segmentName = "__HCR"; actionId = "";
                    deps: openArray[string] = [];
                    after: openArray[BuildActionDef] = [];
                    cacheable = true; commandStatsId = "";
                    actionCachePolicy = defaultActionCachePolicy()):
    BuildActionDef {.discardable, dynOrStatic.} =
  discard tool
  let call = builtinHcrCall("prepareObject", [
    inputArg("input", input),
    outputArg("output", output),
    cliArg("function", functionName),
    cliArg("segment", segmentName)
  ])
  let selectedActionId =
    if actionId.len > 0: actionId else: defaultBuiltinActionId("hcr-prepareObject", output)
  recordCommandAction(selectedActionId, call, deps = combineActionDeps(deps, after),
    cacheable = cacheable, commandStatsId = commandStatsId,
    dependencyPolicy = declaredOnlyDependencyPolicy(),
    actionCachePolicy = actionCachePolicy)

proc machoSegmentLinkFlags*(tool: ReproHcr; segmentName = "__HCR"): string {.dynOrStatic.} =
  discard tool
  when defined(macosx):
    "-Wl,-segprot," & segmentName & ",rwx,rwx"
  else:
    ""

proc patchableFunctionEntryFlag*(tool: ReproHcr; entryBytes = 16;
                                 entryOffset = 0): string {.dynOrStatic.} =
  discard tool
  "-fpatchable-function-entry=" & $entryBytes & "," & $entryOffset

proc copyFile*(tool: ReproFs; source, output: string; actionId = "";
               deps: openArray[string] = [];
               after: openArray[BuildActionDef] = [];
               cacheable = true; commandStatsId = "";
               actionCachePolicy = defaultActionCachePolicy()):
    BuildActionDef {.discardable, dynOrStatic.} =
  discard tool
  let call = builtinFsCall("copyFile", [
    inputArg("source", source),
    outputArg("output", output)
  ])
  let selectedActionId =
    if actionId.len > 0: actionId else: defaultBuiltinActionId("copyFile", output)
  recordCommandAction(selectedActionId, call, deps = combineActionDeps(deps, after),
    cacheable = cacheable, commandStatsId = commandStatsId,
    dependencyPolicy = declaredOnlyDependencyPolicy(),
    actionCachePolicy = actionCachePolicy)

proc ensureDir*(tool: ReproFs; path: string; actionId = "";
                deps: openArray[string] = [];
                after: openArray[BuildActionDef] = [];
                commandStatsId = ""):
    BuildActionDef {.discardable, dynOrStatic.} =
  discard tool
  let call = builtinFsCall("ensureDir", [
    outputArg("path", path)
  ])
  let selectedActionId =
    if actionId.len > 0: actionId else: defaultBuiltinActionId("ensureDir", path)
  recordCommandAction(selectedActionId, call, deps = combineActionDeps(deps, after),
    commandStatsId = commandStatsId,
    dependencyPolicy = declaredOnlyDependencyPolicy())

proc writeText*(tool: ReproFs; output, text: string; actionId = "";
                deps: openArray[string] = [];
                after: openArray[BuildActionDef] = [];
                cacheable = true; commandStatsId = "";
                actionCachePolicy = defaultActionCachePolicy()):
    BuildActionDef {.discardable, dynOrStatic.} =
  discard tool
  let call = builtinFsCall("writeText", [
    outputArg("output", output),
    cliArg("text", text)
  ])
  let selectedActionId =
    if actionId.len > 0: actionId else: defaultBuiltinActionId("writeText", output)
  recordCommandAction(selectedActionId, call, deps = combineActionDeps(deps, after),
    cacheable = cacheable, commandStatsId = commandStatsId,
    dependencyPolicy = declaredOnlyDependencyPolicy(),
    actionCachePolicy = actionCachePolicy)

proc stamp*(tool: ReproFs; output, title: string;
            entries: openArray[string] = []; inputs: openArray[string] = [];
            actionId = ""; deps: openArray[string] = [];
            after: openArray[BuildActionDef] = [];
            cacheable = true; commandStatsId = "";
            actionCachePolicy = defaultActionCachePolicy()):
    BuildActionDef {.discardable, dynOrStatic.} =
  discard tool
  let call = builtinFsCall("stamp", [
    outputArg("output", output),
    cliArg("title", title),
    cliArgSeq("entries", @entries)
  ])
  let selectedActionId =
    if actionId.len > 0: actionId else: defaultBuiltinActionId("stamp", output)
  recordCommandAction(selectedActionId, call, deps = combineActionDeps(deps, after),
    extraInputs = inputs, cacheable = cacheable, commandStatsId = commandStatsId,
    dependencyPolicy = declaredOnlyDependencyPolicy(),
    actionCachePolicy = actionCachePolicy)

proc normalizedRelPath(path: string): string =
  path.replace('\\', '/')

type
  PreserveTreeSymlink = tuple[path: string; target: string]

proc collectPreserveTree(root: string):
    tuple[dirs: seq[string]; files: seq[string]; symlinks: seq[PreserveTreeSymlink]] =
  if not dirExists(extendedPath(root)):
    return
  var pending = @[root]
  while pending.len > 0:
    let dir = pending.pop()
    result.dirs.add(dir)
    # TODO(win-longpath): walk results escape; needs review
    for kind, child in walkDir(dir):
      case kind
      of pcDir:
        pending.add(child)
      of pcFile:
        result.files.add(child)
      of pcLinkToFile, pcLinkToDir:
        result.symlinks.add((path: child, target: expandSymlink(child)))
      else:
        discard
  result.dirs.sort(system.cmp[string])
  result.files.sort(system.cmp[string])
  result.symlinks.sort(proc(a, b: PreserveTreeSymlink): int =
    system.cmp(a.path, b.path))

proc encodePreserveTreeFile(relative: string): string =
  "file\t" & relative

proc encodePreserveTreeSymlink(relative, target: string): string =
  "symlink\t" & relative & "\t" & target

proc shouldExcludePreserveTreeEntry(relative: string;
                                    excludePrefixes: openArray[string]): bool =
  let normalized = normalizedRelPath(relative)
  for prefix in excludePrefixes:
    let normalizedPrefix = normalizedRelPath(prefix).strip(chars = {'/'})
    if normalizedPrefix.len == 0:
      continue
    if normalized == normalizedPrefix or normalized.startsWith(
        normalizedPrefix & "/"):
      return true

proc preserveTree*(tool: ReproFs; sourceRoot, outputRoot: string;
                   actionId = ""; deps: openArray[string] = [];
                   after: openArray[BuildActionDef] = [];
                   excludePrefixes: openArray[string] = [];
                   commandStatsId = ""):
    BuildActionDef {.discardable, dynOrStatic.} =
  discard tool
  providerDirectoryInput(sourceRoot)
  let tree = collectPreserveTree(sourceRoot)
  for dirPath in tree.dirs:
    providerDirectoryInput(normalizedRelPath(dirPath))
  var entries: seq[string] = @[]
  var inputs: seq[string] = @[]
  var outputs: seq[string] = @[]
  for sourcePath in tree.files:
    let relative = normalizedRelPath(relativePath(sourcePath, sourceRoot))
    if shouldExcludePreserveTreeEntry(relative, excludePrefixes):
      continue
    entries.add(encodePreserveTreeFile(relative))
    inputs.add(normalizedRelPath(sourcePath))
    outputs.add(normalizedRelPath(outputRoot / relative))
  for symlink in tree.symlinks:
    let relative = normalizedRelPath(relativePath(symlink.path, sourceRoot))
    if shouldExcludePreserveTreeEntry(relative, excludePrefixes):
      continue
    entries.add(encodePreserveTreeSymlink(relative, symlink.target))
    inputs.add(normalizedRelPath(symlink.path))
    outputs.add(normalizedRelPath(outputRoot / relative))
  let selectedActionId =
    if actionId.len > 0: actionId else: defaultBuiltinActionId("preserveTree", outputRoot)
  outputs.add(preserveTreeManifestOutput(selectedActionId))
  let call = builtinFsCall("preserveTree", [
    cliArg("sourceRoot", normalizedRelPath(sourceRoot)),
    outputArg("outputRoot", normalizedRelPath(outputRoot)),
    cliArgSeq("entries", entries)
  ])
  recordCommandAction(selectedActionId, call,
    deps = combineActionDeps(deps, after),
    extraInputs = inputs,
    extraOutputs = outputs,
    commandStatsId = commandStatsId,
    dependencyPolicy = declaredOnlyDependencyPolicy())

proc normalizedDeclaredProjectPath*(projectRoot, path: string): string {.dynOrStatic.} =
  result = path.replace('\\', '/').strip()
  while result.startsWith("./"):
    result = result.substr(2)
  while result.endsWith("/") and result.len > 1:
    result.setLen(result.len - 1)
  if result.len == 0:
    return
  if projectRoot.len > 0 and path.isAbsolute:
    let normalizedRoot = normalizedPath(projectRoot).replace('\\', '/')
    let normalizedPathValue = normalizedPath(path).replace('\\', '/')
    if normalizedPathValue == normalizedRoot:
      return "."
    let prefix = normalizedRoot & "/"
    if normalizedPathValue.startsWith(prefix):
      return normalizedPathValue.substr(prefix.len)
    result = normalizedPathValue

proc inferDeclaredActionDeps*(actions: openArray[BuildActionDef];
                              projectRoot = ""): seq[BuildActionDef] {.dynOrStatic.} =
  result = @actions
  var outputProducer = initTable[string, string]()
  for action in actions:
    for output in action.outputs:
      let normalized = normalizedDeclaredProjectPath(projectRoot, output)
      if normalized.len > 0 and not outputProducer.hasKey(normalized):
        outputProducer[normalized] = action.id
  for i in 0 ..< result.len:
    var knownDeps = result[i].deps
    for input in result[i].inputs:
      let normalized = normalizedDeclaredProjectPath(projectRoot, input)
      if normalized.len == 0:
        continue
      if outputProducer.hasKey(normalized):
        let producerId = outputProducer[normalized]
        if producerId != result[i].id and knownDeps.find(producerId) < 0:
          knownDeps.add(producerId)
    result[i].deps = knownDeps

proc writeByte(outp: var seq[byte]; value: byte) =
  outp.add(value)

proc raisePayload(message: string) {.noreturn.} =
  raise newException(BuildActionPayloadError, message)

proc readByte(bytes: openArray[byte]; pos: var int): byte =
  if pos >= bytes.len:
    raisePayload("truncated build action payload byte")
  result = bytes[pos]
  inc pos

proc writeU16Le(outp: var seq[byte]; value: uint16) =
  outp.add(byte(value and 0xff'u16))
  outp.add(byte((value shr 8) and 0xff'u16))

proc writeU32Le(outp: var seq[byte]; value: uint32) =
  for shift in [0, 8, 16, 24]:
    outp.add(byte((value shr shift) and 0xff'u32))

proc readU16Le(bytes: openArray[byte]; pos: var int): uint16 =
  if pos + 2 > bytes.len:
    raisePayload("truncated uint16 in build action payload")
  result = uint16(bytes[pos]) or (uint16(bytes[pos + 1]) shl 8)
  pos += 2

proc readU32Le(bytes: openArray[byte]; pos: var int): uint32 =
  if pos + 4 > bytes.len:
    raisePayload("truncated uint32 in build action payload")
  for i in 0 ..< 4:
    result = result or (uint32(bytes[pos + i]) shl (8 * i))
  pos += 4

proc writeString(outp: var seq[byte]; value: string) =
  outp.writeU32Le(uint32(value.len))
  for ch in value:
    outp.add(byte(ord(ch)))

proc readString(bytes: openArray[byte]; pos: var int): string =
  let length = int(readU32Le(bytes, pos))
  if pos + length > bytes.len:
    raisePayload("truncated string in build action payload")
  result = newString(length)
  for i in 0 ..< length:
    result[i] = char(bytes[pos + i])
  pos += length

proc fromBytes(bytes: openArray[byte]): string =
  result = newString(bytes.len)
  for i, b in bytes:
    result[i] = char(b)

proc writeStringSeq(outp: var seq[byte]; values: openArray[string]) =
  outp.writeU32Le(uint32(values.len))
  for value in values:
    outp.writeString(value)

proc writeU32(outp: var seq[byte]; value: uint32) =
  outp.writeU32Le(value)

proc readStringSeq(bytes: openArray[byte]; pos: var int): seq[string] =
  let count = int(readU32Le(bytes, pos))
  result = newSeq[string](count)
  for i in 0 ..< count:
    result[i] = readString(bytes, pos)

proc writeCliArg(outp: var seq[byte]; arg: PublicCliArg) =
  outp.writeString(arg.name)
  outp.writeString(arg.nimType)
  outp.writeByte(byte(ord(arg.kind)))
  outp.writeU32Le(uint32(arg.position))
  outp.writeString(arg.alias)
  outp.writeByte(byte(ord(arg.role)))
  outp.writeByte(byte(ord(arg.format)))
  outp.writeByte(if arg.repeated: 1'u8 else: 0'u8)
  outp.writeByte(byte(ord(arg.placement)))
  outp.writeString(arg.encodedValue)

proc readCliArg(bytes: openArray[byte]; pos: var int; version: uint16):
    PublicCliArg =
  result.name = readString(bytes, pos)
  result.nimType = readString(bytes, pos)
  if version >= 2'u16:
    let kind = readByte(bytes, pos)
    if kind > byte(ord(cpkFlag)):
      raisePayload("invalid CLI argument kind in build action payload")
    result.kind = CliParamKind(kind)
    result.position = int(readU32Le(bytes, pos))
    result.alias = readString(bytes, pos)
  else:
    result.kind = cpkFlag
  if version >= 4'u16:
    let role = readByte(bytes, pos)
    if role > byte(ord(carOutput)):
      raisePayload("invalid CLI argument role in build action payload")
    result.role = CliArgRole(role)
  else:
    result.role = carOrdinary
  if version >= 5'u16:
    let format = readByte(bytes, pos)
    if format > byte(ord(cafEquals)):
      raisePayload("invalid CLI argument format in build action payload")
    result.format = CliArgFormat(format)
    result.repeated = readByte(bytes, pos) == 1'u8
  else:
    result.format = cafSeparate
    result.repeated = false
  if version >= 6'u16:
    let placement = readByte(bytes, pos)
    if placement > byte(ord(capBeforeSubcommand)):
      raisePayload("invalid CLI argument placement in build action payload")
    result.placement = CliArgPlacement(placement)
  else:
    result.placement = capAfterSubcommand
  result.encodedValue = readString(bytes, pos)

proc writeCliCall(outp: var seq[byte]; call: PublicCliCall) =
  outp.writeString(call.packageName)
  outp.writeString(call.executableName)
  outp.writeString(call.subcommand)
  outp.writeString(call.providerEntrypointId)
  outp.writeU32Le(uint32(call.arguments.len))
  for arg in call.arguments:
    outp.writeCliArg(arg)

proc readCliCall(bytes: openArray[byte]; pos: var int; version: uint16):
    PublicCliCall =
  result.packageName = readString(bytes, pos)
  result.executableName = readString(bytes, pos)
  result.subcommand = readString(bytes, pos)
  result.providerEntrypointId = readString(bytes, pos)
  let count = int(readU32Le(bytes, pos))
  result.arguments = newSeq[PublicCliArg](count)
  for i in 0 ..< count:
    result.arguments[i] = readCliArg(bytes, pos, version)

proc writeDependencyPolicy(outp: var seq[byte];
                           policy: BuildActionDependencyPolicy) =
  outp.writeByte(byte(ord(policy.kind)))
  outp.writeString(policy.depfile)
  outp.writeStringSeq(policy.ignoredInputPrefixes)

proc readDependencyPolicy(bytes: openArray[byte]; pos: var int; version: uint16):
    BuildActionDependencyPolicy =
  let kind = readByte(bytes, pos)
  if kind > byte(ord(bdpMakeDepfile)):
    raisePayload("invalid dependency policy kind in build action payload")
  result.kind = BuildActionDependencyPolicyKind(kind)
  result.depfile = readString(bytes, pos)
  if version >= 10'u16:
    result.ignoredInputPrefixes = readStringSeq(bytes, pos)

proc writeActionCachePolicy(outp: var seq[byte];
                            policy: ActionCacheFingerprintPolicy) =
  outp.writeByte(byte(ord(policy)))

proc readActionCachePolicy(bytes: openArray[byte]; pos: var int):
    ActionCacheFingerprintPolicy =
  let policy = readByte(bytes, pos)
  if policy > byte(ord(acfpHybrid)):
    raisePayload("invalid action cache policy in build action payload")
  ActionCacheFingerprintPolicy(policy)

proc encodeBuildActionPayload*(action: BuildActionDef): seq[byte] {.dynOrStatic.} =
  var payload: seq[byte] = @[]
  payload.writeString(action.id)
  payload.writeCliCall(action.call)
  payload.writeStringSeq(action.deps)
  payload.writeStringSeq(action.inputs)
  payload.writeStringSeq(action.outputs)
  payload.writeString(action.pool)
  payload.writeU32(action.poolUnits)
  payload.writeString(action.depfile)
  payload.writeString(action.dynamicDepsFile)
  payload.writeByte(if action.cacheable: 1'u8 else: 0'u8)
  payload.writeString(action.commandStatsId)
  payload.writeDependencyPolicy(action.dependencyPolicy)
  payload.writeActionCachePolicy(action.actionCachePolicy)
  # v11: Named-Targets M1 implicit target names.
  payload.writeStringSeq(action.targetNames)
  # v12: Typed-Outputs M1 per-output typed entries.
  payload.writeU32Le(uint32(action.typedOutputs.len))
  for typedOutput in action.typedOutputs:
    payload.writeString(typedOutput.fieldName)
    payload.writeStringSeq(typedOutput.types)
    payload.writeString(typedOutput.path)

  result.add(BuildActionPayloadMagic)
  result.writeU16Le(BuildActionPayloadVersion)
  result.writeU32Le(uint32(payload.len))
  result.add(payload)

proc decodeBuildActionPayload*(bytes: openArray[byte]): BuildActionDef {.dynOrStatic.} =
  if bytes.len < 10:
    raisePayload("truncated build action payload envelope")
  for i in 0 ..< BuildActionPayloadMagic.len:
    if bytes[i] != BuildActionPayloadMagic[i]:
      raisePayload("unknown build action payload magic")
  var pos = 4
  let version = readU16Le(bytes, pos)
  if version notin {1'u16, 2'u16, 3'u16, 4'u16, 5'u16, 6'u16, 7'u16, 8'u16,
      9'u16, 10'u16, 11'u16, BuildActionPayloadVersion}:
    raisePayload("unsupported build action payload version")
  let payloadLength = int(readU32Le(bytes, pos))
  if pos + payloadLength != bytes.len:
    raisePayload("build action payload length mismatch")

  result.id = readString(bytes, pos)
  result.call = readCliCall(bytes, pos, version)
  result.deps = readStringSeq(bytes, pos)
  result.inputs = readStringSeq(bytes, pos)
  result.outputs = readStringSeq(bytes, pos)
  if version >= 7'u16:
    result.pool = readString(bytes, pos)
    result.poolUnits = readU32Le(bytes, pos)
  else:
    result.poolUnits = 1'u32
  result.depfile = readString(bytes, pos)
  if version >= 8'u16:
    result.dynamicDepsFile = readString(bytes, pos)
  result.cacheable = readByte(bytes, pos) == 1'u8
  result.commandStatsId = readString(bytes, pos)
  if version >= 3'u16:
    result.dependencyPolicy = readDependencyPolicy(bytes, pos, version)
  else:
    result.dependencyPolicy = defaultDependencyPolicy()
  if version >= 9'u16:
    result.actionCachePolicy = readActionCachePolicy(bytes, pos)
  else:
    result.actionCachePolicy = defaultActionCachePolicy()
  if version >= 11'u16:
    result.targetNames = readStringSeq(bytes, pos)
  if version >= 12'u16:
    let typedOutputCount = int(readU32Le(bytes, pos))
    result.typedOutputs = newSeq[BuildActionTypedOutput](typedOutputCount)
    for i in 0 ..< typedOutputCount:
      result.typedOutputs[i].fieldName = readString(bytes, pos)
      result.typedOutputs[i].types = readStringSeq(bytes, pos)
      result.typedOutputs[i].path = readString(bytes, pos)
  if pos != bytes.len:
    raisePayload("trailing build action payload bytes")

proc actionPayload*(action: BuildActionDef): string {.dynOrStatic.} =
  fromBytes(encodeBuildActionPayload(action))

proc encodeBuildTargetPayload*(target: BuildTargetDef): seq[byte] {.dynOrStatic.} =
  var payload: seq[byte] = @[]
  payload.writeString(target.name)
  payload.writeStringSeq(target.actions)
  payload.writeStringSeq(target.targets)
  payload.writeString(target.sourceFile)
  payload.writeU32Le(uint32(max(target.sourceLine, 0)))

  result.add(BuildTargetPayloadMagic)
  result.writeU16Le(BuildTargetPayloadVersion)
  result.writeU32Le(uint32(payload.len))
  result.add(payload)

proc decodeBuildTargetPayload*(bytes: openArray[byte]): BuildTargetDef {.dynOrStatic.} =
  if bytes.len < 10:
    raisePayload("truncated build target payload envelope")
  for i in 0 ..< BuildTargetPayloadMagic.len:
    if bytes[i] != BuildTargetPayloadMagic[i]:
      raisePayload("unknown build target payload magic")
  var pos = 4
  let version = readU16Le(bytes, pos)
  if version notin {1'u16, BuildTargetPayloadVersion}:
    raisePayload("unsupported build target payload version")
  let payloadLength = int(readU32Le(bytes, pos))
  if pos + payloadLength != bytes.len:
    raisePayload("build target payload length mismatch")
  result.name = readString(bytes, pos)
  result.actions = readStringSeq(bytes, pos)
  result.targets = readStringSeq(bytes, pos)
  if version >= 2'u16:
    result.sourceFile = readString(bytes, pos)
    result.sourceLine = int(readU32Le(bytes, pos))
  if pos != bytes.len:
    raisePayload("trailing build target payload bytes")

proc targetPayload*(target: BuildTargetDef): string {.dynOrStatic.} =
  fromBytes(encodeBuildTargetPayload(target))

proc encodeBuildPoolPayload*(pool: BuildPoolDef): seq[byte] {.dynOrStatic.} =
  var payload: seq[byte] = @[]
  payload.writeString(pool.name)
  payload.writeU32Le(pool.capacity)

  result.add(BuildPoolPayloadMagic)
  result.writeU16Le(BuildPoolPayloadVersion)
  result.writeU32Le(uint32(payload.len))
  result.add(payload)

proc decodeBuildPoolPayload*(bytes: openArray[byte]): BuildPoolDef {.dynOrStatic.} =
  if bytes.len < 10:
    raisePayload("truncated build pool payload envelope")
  for i in 0 ..< BuildPoolPayloadMagic.len:
    if bytes[i] != BuildPoolPayloadMagic[i]:
      raisePayload("unknown build pool payload magic")
  var pos = 4
  let version = readU16Le(bytes, pos)
  if version != BuildPoolPayloadVersion:
    raisePayload("unsupported build pool payload version")
  let payloadLength = int(readU32Le(bytes, pos))
  if pos + payloadLength != bytes.len:
    raisePayload("build pool payload length mismatch")
  result.name = readString(bytes, pos)
  result.capacity = readU32Le(bytes, pos)
  if pos != bytes.len:
    raisePayload("trailing build pool payload bytes")

proc poolPayload*(pool: BuildPoolDef): string {.dynOrStatic.} =
  fromBytes(encodeBuildPoolPayload(pool))

proc writeTargetExportEntry(outp: var seq[byte]; entry: TargetExportEntry) =
  outp.writeString(entry.name)
  outp.writeByte(byte(ord(entry.kind)))
  outp.writeString(entry.owningPackage)
  outp.writeString(entry.actionId)
  outp.writeString(entry.sourceFile)
  outp.writeU32Le(uint32(max(entry.sourceLine, 0)))

proc readTargetExportEntry(bytes: openArray[byte]; pos: var int):
    TargetExportEntry =
  result.name = readString(bytes, pos)
  let kindByte = readByte(bytes, pos)
  if kindByte > byte(ord(tekExplicit)):
    raisePayload("invalid target export entry kind")
  result.kind = TargetExportKind(kindByte)
  result.owningPackage = readString(bytes, pos)
  result.actionId = readString(bytes, pos)
  result.sourceFile = readString(bytes, pos)
  result.sourceLine = int(readU32Le(bytes, pos))

proc writeTargetExportAmbiguity(outp: var seq[byte];
                                ambiguity: TargetExportAmbiguity) =
  outp.writeString(ambiguity.name)
  outp.writeStringSeq(ambiguity.candidates)

proc readTargetExportAmbiguity(bytes: openArray[byte]; pos: var int):
    TargetExportAmbiguity =
  result.name = readString(bytes, pos)
  result.candidates = readStringSeq(bytes, pos)

proc encodeTargetExportTablePayload*(table: TargetExportTable):
    seq[byte] {.dynOrStatic.} =
  ## Named-Targets M1: SSZ-style frame around the project-scoped
  ## target-export table. The table travels as the payload of a single
  ## ``gnkMetadata`` node on the GraphFragment (stableName
  ## ``reprobuild.target-export-table.v1``) so ``repro graph`` and the
  ## M2 CLI resolver consume one source of truth.
  var payload: seq[byte] = @[]
  payload.writeU32Le(uint32(table.entries.len))
  for entry in table.entries:
    payload.writeTargetExportEntry(entry)
  payload.writeU32Le(uint32(table.ambiguities.len))
  for ambiguity in table.ambiguities:
    payload.writeTargetExportAmbiguity(ambiguity)

  result.add(TargetExportTablePayloadMagic)
  result.writeU16Le(TargetExportTablePayloadVersion)
  result.writeU32Le(uint32(payload.len))
  result.add(payload)

proc decodeTargetExportTablePayload*(bytes: openArray[byte]):
    TargetExportTable {.dynOrStatic.} =
  if bytes.len < 10:
    raisePayload("truncated target export table envelope")
  for i in 0 ..< TargetExportTablePayloadMagic.len:
    if bytes[i] != TargetExportTablePayloadMagic[i]:
      raisePayload("unknown target export table payload magic")
  var pos = 4
  let version = readU16Le(bytes, pos)
  if version != TargetExportTablePayloadVersion:
    raisePayload("unsupported target export table payload version")
  let payloadLength = int(readU32Le(bytes, pos))
  if pos + payloadLength != bytes.len:
    raisePayload("target export table payload length mismatch")
  let entryCount = int(readU32Le(bytes, pos))
  result.entries = newSeq[TargetExportEntry](entryCount)
  for i in 0 ..< entryCount:
    result.entries[i] = readTargetExportEntry(bytes, pos)
  let ambiguityCount = int(readU32Le(bytes, pos))
  result.ambiguities = newSeq[TargetExportAmbiguity](ambiguityCount)
  for i in 0 ..< ambiguityCount:
    result.ambiguities[i] = readTargetExportAmbiguity(bytes, pos)
  if pos != bytes.len:
    raisePayload("trailing target export table payload bytes")

proc targetExportTablePayload*(table: TargetExportTable): string {.dynOrStatic.} =
  fromBytes(encodeTargetExportTablePayload(table))

proc callIdentity*(call: PublicCliCall): string {.dynOrStatic.} =
  var parts = @[call.packageName, call.executableName, call.subcommand,
                call.providerEntrypointId]
  for arg in call.arguments:
    parts.add(arg.name & ":" & arg.nimType & ":" & $arg.role & ":" &
      $arg.format & ":" & $arg.placement & ":" & $arg.repeated & "=" &
      arg.encodedValue)
  parts.join("|")

proc stableHashHex(value: string): string =
  var hash = 0xcbf29ce484222325'u64
  for ch in value:
    hash = hash xor uint64(ord(ch))
    hash = hash * 0x100000001b3'u64
  hash.toHex(16).toLowerAscii()

proc actionIdPart(value: string): string =
  for ch in value:
    if ch in {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '.', '_', '-'}:
      result.add(ch.toLowerAscii())
    elif ch in {' ', '/', '\\', ':'}:
      if result.len == 0 or result[^1] != '-':
        result.add('-')
    else:
      result.add(toHex(ord(ch), 2).toLowerAscii())
  while result.len > 0 and result[^1] == '-':
    result.setLen(result.len - 1)
  if result.len == 0:
    result = "tool"

proc defaultToolActionId*(call: PublicCliCall): string {.dynOrStatic.} =
  var base = actionIdPart(call.executableName)
  if call.subcommand.len > 0:
    base.add("-" & actionIdPart(call.subcommand))
  base & "-" & stableHashHex(callIdentity(call))
