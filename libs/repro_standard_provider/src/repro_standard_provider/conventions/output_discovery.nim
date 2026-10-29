## Tool-authored target metadata is the authority for delegated build outputs.
## A discovery step -- the configure edge, or a dedicated ``<convention>-
## outputs`` edge -- asks the tool where the build it is about to run puts its
## products, and writes a dynamic-output fragment the build edge loads before
## it is looked up or run. The engine then applies its ordinary output
## obligation and cache handling to the actual artifacts, including custom
## names, output directories and subdirectory targets.
##
## Three record kinds, Build-Engine-And-Scheduler.md §"Outputs a delegated
## build decides":
##
## * ``output`` -- an obligatory product (the jar, the executable, the
##   assembly a consumer uses);
## * ``opaque-output`` -- the tool's output tree, removed before the build,
##   recorded whole and restored exactly (BuildXL's exclusive opaque
##   directory);
## * ``optional-output`` -- a byproduct the tool lists but may not write.
##
## A convention never falls back to predicting a path: when the tool cannot
## answer, discovery fails and names the tool's own diagnostic.
import std/[algorithm, json, os, osproc, streams, strutils]
from repro_core/paths import extendedPath
from repro_core/ambient_execution import uncontrolledStartProcess
import repro_project_dsl

type DiscoveredOutputs* = object
  outputs*: seq[string]
  optionalOutputs*: seq[string]
  opaqueOutputs*: seq[string]

proc normalizedOutputPath(path: string): string =
  ## Forward slashes, no trailing separator: the spelling fragment records
  ## carry, and the one containment below is computed on.
  result = path.replace('\\', '/')
  while result.len > 1 and result.endsWith("/"):
    result.setLen(result.len - 1)

proc collapseOpaqueOutputs*(trees: seq[string]): seq[string] =
  ## Unique trees, none nested in another: a tree inside another tree of the
  ## same action is already recorded and removed with its ancestor. (BuildXL's
  ## MSBuild resolver collapses its predicted output folders the same way,
  ## `PipConstructor.GetOutputDirectories`.) Case-insensitive on Windows,
  ## where the tools report a directory in more than one spelling.
  var normalized: seq[string] = @[]
  for tree in trees:
    let path = normalizedOutputPath(tree)
    if path.len > 0 and path notin normalized:
      normalized.add(path)
  proc key(path: string): string =
    when defined(windows): path.toLowerAscii() else: path
  for path in normalized:
    var nested = false
    for other in normalized:
      if other != path and key(path).startsWith(key(other) & "/"):
        nested = true
        break
    if not nested:
      result.add(path)

proc writeOutputFragment*(path, actionId: string; outputs: seq[string];
    optionalOutputs: seq[string] = @[]; opaqueOutputs: seq[string] = @[]) =
  var text = "repro-dynamic-graph-v1\n"
  proc appendOutput(kind, output: string) =
    if '\t' in output or '\n' in output or '\r' in output:
      raise newException(ValueError, "output cannot be represented in a dynamic graph: " & output)
    text.add(kind & "\t" & actionId & "\t" & normalizedOutputPath(output) & "\n")
  for output in collapseOpaqueOutputs(opaqueOutputs): appendOutput("opaque-output", output)
  for output in outputs: appendOutput("output", output)
  for output in optionalOutputs: appendOutput("optional-output", output)
  createDir(extendedPath(path.parentDir))
  # Write only when the answer changed (Ninja's `restat`): the fragment is
  # an input of the build edge, and a rewrite with the same bytes still moves
  # its change time, which misses the build edge's record. Discovery re-runs
  # whenever the directory it enumerates changes -- deleting the build's own
  # output tree does that -- and must not cost the build its restore.
  if fileExists(extendedPath(path)):
    try:
      if readFile(extendedPath(path)) == text:
        return
    except IOError:
      discard
  writeFile(extendedPath(path), text)

proc writeOutputFragment*(path, actionId: string; discovered: DiscoveredOutputs) =
  writeOutputFragment(path, actionId, discovered.outputs,
    discovered.optionalOutputs, discovered.opaqueOutputs)

proc cmakeTargetArtifacts(buildDir, target: string): DiscoveredOutputs =
  let replyDir = buildDir / ".cmake/api/v1/reply"
  var indexes: seq[string]
  for path in walkFiles(replyDir / "index-*.json"): indexes.add(path)
  indexes.sort()
  if indexes.len == 0:
    raise newException(ValueError, "CMake file-API index missing: " & replyDir)
  let index = parseFile(indexes[^1])
  let model = parseFile(replyDir / index["reply"]["codemodel-v2"]["jsonFile"].getStr())
  for config in model["configurations"]:
    # This convention configures and builds Release. An artifact from another
    # configuration must never fulfill this edge's obligation or cache record.
    if config["name"].getStr() != "Release": continue
    for entry in config["targets"]:
      if entry["name"].getStr() != target: continue
      let detail = parseFile(replyDir / entry["jsonFile"].getStr())
      let objectsOnly = detail["type"].getStr() == "OBJECT_LIBRARY"
      let primaryName = detail.getOrDefault("nameOnDisk").getStr()
      for artifact in detail["artifacts"]:
        let path = artifact["path"].getStr().replace('\\', '/')
        let output = if path.isAbsolute: path else: buildDir / path
        if objectsOnly or extractFilename(path) == primaryName:
          result.outputs.add(output)
        else:
          # nameOnDisk identifies the primary linked/archived artifact. CMake
          # also lists linker byproducts (notably import libraries and PDBs)
          # which it predicts even when a successful link will not emit them.
          # Keep them restorable when present without weakening the primary.
          # This convention delegates to stock CMake and its own generator,
          # whose MSVC link writes no import library for a DLL without
          # exports; only the Reprobuild CMake generator's link step creates
          # that library and so declares it obligatory.
          result.optionalOutputs.add(output)
      if result.outputs.len == 0:
        raise newException(ValueError, "CMake target has no primary artifact: " & target)
      return
  raise newException(ValueError, "CMake Release target absent from codemodel: " & target)

proc cmakeTargetOutputs*(buildDir, target: string): seq[string] =
  ## Primary mandatory artifacts, excluding conditionally emitted byproducts.
  cmakeTargetArtifacts(buildDir, target).outputs

proc mesonTargetOutputs*(buildDir, target: string): seq[string] =
  let metadata = parseFile(buildDir / "meson-info/intro-targets.json")
  for entry in metadata:
    if entry["name"].getStr() != target: continue
    for artifact in entry["filename"]:
      let path = artifact.getStr()
      result.add(if path.isAbsolute: path else: buildDir / path)
    if result.len == 0:
      raise newException(ValueError, "Meson target has no artifacts: " & target)
    return
  raise newException(ValueError, "Meson target absent from introspection: " & target)


# ---------------------------------------------------------------------------
# Asking a delegated tool

type ToolQuery* = object
  ## One read-only invocation of a delegated tool: an evaluation of the
  ## build's configuration that plans or builds nothing.
  exe*: string
  args*: seq[string]

proc readToEnd*(stream: Stream): string =
  ## Everything `stream` yields until end of file. Not ``Stream.readAll``,
  ## which stops at the first short read -- and a pipe returns short reads
  ## mid-stream (measured on eli-pc: the JSON object
  ## ``dotnet msbuild -getProperty`` writes was cut after 256 bytes).
  var buffer = newString(4096)
  while true:
    let count = stream.readData(addr buffer[0], buffer.len)
    if count <= 0:
      break
    result.add(buffer[0 ..< count])

proc runToolQueries*(cwd: string; queries: openArray[ToolQuery]): seq[string] =
  ## Runs `queries` concurrently and returns each one's output, in order.
  ## Every query starts before any is waited on: each is a JVM or SDK
  ## start-up, and the answers are independent. Standard error is merged so
  ## no query can stall on a full pipe; each caller takes its answer from a
  ## position a warning cannot occupy (the last line, the JSON object, a
  ## file). A failing query is reported with its command and output.
  var processes: seq[Process] = @[]
  try:
    for query in queries:
      processes.add(uncontrolledStartProcess(query.exe, workingDir = cwd,
        args = query.args, options = {poStdErrToStdOut}))
    for i, process in processes:
      let output = process.outputStream.readToEnd()
      let code = process.waitForExit()
      if code != 0:
        raise newException(ValueError, "output discovery query failed (exit " &
          $code & "): " & quoteShellCommand(@[queries[i].exe] & queries[i].args) &
          "\n" & output)
      result.add(output)
  finally:
    for process in processes:
      process.close()

proc lastLine(text: string): string =
  for line in text.splitLines():
    if line.strip().len > 0:
      result = line.strip()

proc pathKey(path: string): string =
  result = normalizedOutputPath(path)
  when defined(windows):
    result = result.toLowerAscii()

proc requireTreeOutsideProject(tree, projectRoot, what: string) =
  ## An opaque output directory is removed before the build runs. One that
  ## holds the project's own files (an output directory set to `.`) cannot be
  ## one, and the tool's answer is refused here with the tool's own name for
  ## it rather than by the engine's ownership check later.
  let treeKey = pathKey(tree)
  let rootKey = pathKey(projectRoot)
  if treeKey == rootKey or rootKey.startsWith(treeKey & "/"):
    raise newException(ValueError, what & " '" & tree &
      "' contains the project directory '" & projectRoot &
      "'; the build's output tree must be separate from its sources")

# --- Maven -----------------------------------------------------------------

const MavenHelpEvaluate* =
  "org.apache.maven.plugins:maven-help-plugin:3.5.1:evaluate"
  ## Pinned: an unversioned ``help:evaluate`` resolves the plugin version
  ## from repository metadata, which an offline build cannot refresh. The
  ## offline warm step must fetch it as well as the build's own plugins:
  ## ``dependency:go-offline`` resolves only what the POM uses, so the warm
  ## step also runs ``mvn <this> -Dexpression=project.version`` once
  ## online. Without it discovery fails with Maven's own resolution error.
  ## https://maven.apache.org/plugins/maven-help-plugin/evaluate-mojo.html

proc mavenQuery(mvnExe, pom, expression: string): ToolQuery =
  ## ``-DforceStdout`` prints the bare value under ``-q`` (help plugin
  ## 3.1.0+). One expression per invocation: the mojo evaluates a single
  ## expression, not an interpolated string.
  ToolQuery(exe: mvnExe, args: @["-o", "-q", "-B", "-f", pom, MavenHelpEvaluate,
    "-DforceStdout", "-Dexpression=" & expression])

proc mavenOutputs*(mvnExe, projectRoot: string): DiscoveredOutputs =
  ## Where ``mvn package`` puts the project's main artifact, from Maven's own
  ## evaluation of the effective POM: ``${project.build.directory}/
  ## ${project.build.finalName}.<extension>``, the extension being the
  ## packaging's artifact handler's (``jar`` for ``jar``, ``maven-plugin``,
  ## ``ejb``; ``war`` for ``war``; whatever an extension's packaging
  ## declares). ``project.build.directory`` is the opaque output tree.
  let pom = projectRoot / "pom.xml"
  const expressions = ["project.build.directory", "project.build.finalName",
    "project.artifact.artifactHandler.extension"]
  var queries: seq[ToolQuery] = @[]
  for expression in expressions:
    queries.add(mavenQuery(mvnExe, pom, expression))
  let answers = runToolQueries(projectRoot, queries)
  var values: seq[string] = @[]
  for i, answer in answers:
    # ``forceStdout`` prints the bare value last, after anything the JVM
    # warned about on start-up.
    let value = lastLine(answer)
    if value.len == 0 or value == "null object or invalid expression":
      raise newException(ValueError, "Maven did not evaluate ${" &
        expressions[i] & "} for " & pom & ": " & answer)
    values.add(value)
  var directory = values[0]
  if not directory.isAbsolute:
    directory = projectRoot / directory
  let extension = values[2]
  if extension == "pom":
    raise newException(ValueError, pom & " has packaging 'pom': the project " &
      "builds no artifact of its own for this convention to declare")
  requireTreeOutsideProject(directory, projectRoot,
    "Maven's project.build.directory")
  result.opaqueOutputs = @[directory]
  result.outputs = @[directory / (values[1] & "." & extension)]

# --- Gradle ----------------------------------------------------------------

const GradleOutputsInitScript* = """
// Written by reprobuild's kotlin-gradle convention (output_discovery.nim).
// Reports where this build puts its products, as Gradle configured them:
// the root project's build directory and the archive its `jar` task writes.
// The providers are taken when the task is configured and read when it
// runs: a task action that touches `project` fails a build that enables
// the configuration cache.
rootProject {
  tasks.register("reproDescribeOutputs") {
    def answer = gradle.startParameter.projectProperties.get("repro.outputs.file")
    def buildDirectory = project.layout.buildDirectory
    def jar = project.tasks.findByName("jar")
    def archive = jar != null ? jar.archiveFile : null
    doLast {
      def lines = ["tree\t" + buildDirectory.get().asFile.absolutePath]
      if (archive != null) {
        lines << "output\t" + archive.get().asFile.absolutePath
      }
      new File(answer).setText(lines.join("\n") + "\n", "UTF-8")
    }
  }
}
"""
  ## Groovy, so it applies to Kotlin-DSL and Groovy-DSL builds alike.
  ## ``archiveFile`` is "the destinationDirectory plus the archiveFileName"
  ## (AbstractArchiveTask), after every ``archiveBaseName`` /
  ## ``archiveVersion`` / ``archiveClassifier`` override the build applied:
  ## both it and ``layout.buildDirectory`` are lazy providers, resolved in
  ## the task action. Neither is read through ``Task.project`` at execution
  ## time, which the configuration cache refuses
  ## (https://docs.gradle.org/current/userguide/configuration_cache.html#config_cache:requirements:use_project_during_execution);
  ## a refusal would also write its report into the build directory.
  ## https://docs.gradle.org/current/userguide/init_scripts.html

const GradleOfflineFlags* = ["--offline", "--no-daemon", "-q"]
  ## Shared by the build and its discovery, so both see the same
  ## configuration.

proc gradleOutputs*(gradleExe, projectRoot, scratch: string): DiscoveredOutputs =
  ## Asks Gradle through an init script. Gradle's own state for this query
  ## goes under `scratch` (``--project-cache-dir``), never into the build's
  ## project cache or build directory.
  createDir(extendedPath(scratch))
  let script = scratch / "repro-outputs.init.gradle"
  let answer = scratch / "outputs.txt"
  writeFile(extendedPath(script), GradleOutputsInitScript)
  if fileExists(extendedPath(answer)):
    removeFile(extendedPath(answer))
  discard runToolQueries(projectRoot, [ToolQuery(exe: gradleExe,
    args: @GradleOfflineFlags & @["-p", projectRoot, "-I", script,
      "--project-cache-dir", scratch / "project-cache", "reproDescribeOutputs",
      "-Prepro.outputs.file=" & answer])])
  if not fileExists(extendedPath(answer)):
    raise newException(ValueError, "Gradle wrote no output description for " &
      projectRoot)
  for line in readFile(extendedPath(answer)).splitLines():
    let fields = line.split('\t')
    if fields.len != 2:
      continue
    case fields[0]
    of "tree":
      requireTreeOutsideProject(fields[1], projectRoot,
        "Gradle's layout.buildDirectory")
      result.opaqueOutputs.add(fields[1])
    of "output":
      result.outputs.add(fields[1])
    else:
      discard
  if result.opaqueOutputs.len == 0:
    raise newException(ValueError, "Gradle reported no build directory for " &
      projectRoot)
  if result.outputs.len == 0:
    raise newException(ValueError, "the Gradle build at " & projectRoot &
      " has no 'jar' task, so it produces no archive for this convention " &
      "to declare")

# --- Cabal -----------------------------------------------------------------

const CabalConfigFlags*: seq[string] =
  when defined(linux) or defined(macosx): @["--offline", "--enable-relocatable"]
  else: @["--offline"]
  ## The configuration flags of the delegated ``cabal v2-build``. Its
  ## discovery passes the same ones: optimisation, relocatability and the
  ## like decide the directory an executable lands in (``opt`` / ``noopt``).
  ##
  ## ``--enable-relocatable`` only where Cabal allows it: its configure step
  ## refuses a relocatable build on any OS but Linux and macOS
  ## (``checkRelocatable``'s ``checkOS``, Cabal/src/Distribution/Simple/
  ## Configure.hs at Cabal-v3.16.1.0). Measured on eli-pc with cabal-install
  ## 3.16.1.0 and GHC 9.12.1: ``Error: [Cabal-3339] Operating system:
  ## windows, does not support relocatable builds``.

proc cabalOutputs*(cabalExe, projectRoot, discoveryBuildDir, buildDir: string;
                   executables: openArray[string]): DiscoveredOutputs =
  ## ``cabal list-bin`` names the path each executable will be built at
  ## (cabal-install 3.4+). It is asked against a private ``--builddir`` --
  ## it writes the plan cache there -- and the answer is moved onto the
  ## build's own ``--builddir``: the layout below the build directory is
  ## cabal's, the build directory is the convention's. The build directory
  ## is the opaque output tree.
  ## https://cabal.readthedocs.io/en/stable/cabal-commands.html#cabal-list-bin
  let discoveryKey = pathKey(discoveryBuildDir)
  for executable in executables:
    # One at a time: every query plans into the same private build directory.
    let answer = runToolQueries(projectRoot, [ToolQuery(exe: cabalExe,
      args: @["list-bin"] & @CabalConfigFlags &
        @["--builddir=" & discoveryBuildDir, "exe:" & executable])])[0]
    let path = lastLine(answer)
    if not path.isAbsolute or
        not pathKey(path).startsWith(discoveryKey & "/"):
      raise newException(ValueError, "cabal list-bin exe:" & executable &
        " did not name a path under its build directory " & discoveryBuildDir &
        ": " & answer)
    let relative = normalizedOutputPath(path)[discoveryKey.len .. ^1]
    result.outputs.add(normalizedOutputPath(buildDir) & relative)
  requireTreeOutsideProject(buildDir, projectRoot, "Cabal's --builddir")
  result.opaqueOutputs = @[buildDir]

proc cabalLogsDirectory*(cabalExe: string): string =
  ## Where cabal appends its global build summary (``<logs-dir>/build.log``)
  ## on every build, from ``cabal path`` (cabal-install 3.10+), or "" when
  ## this cabal cannot say. The build never reads it; the convention declares
  ## it machine-local derived state so the summary does not withhold a
  ## restore (Build-Engine-And-Scheduler.md §"Restoring a delegated build").
  if cabalExe.len == 0:
    return ""
  try:
    let answer = runToolQueries(getCurrentDir(), [ToolQuery(exe: cabalExe,
      args: @["path", "--logs-dir"])])[0]
    var value = lastLine(answer)
    if value.startsWith("logs-dir:"):
      value = value["logs-dir:".len .. ^1].strip()
    if value.isAbsolute:
      return value
  except CatchableError:
    discard
  ""

# --- .NET ------------------------------------------------------------------

const DotnetQuietEnvironment* = [
  ("DOTNET_CLI_TELEMETRY_OPTOUT", "1"),
  ("DOTNET_NOLOGO", "1"),
  ("DOTNET_SKIP_FIRST_TIME_EXPERIENCE", "1")]
  ## Language-Conventions/CSharp-DotNet.md §"Mode B": telemetry and the
  ## first-run experience write under the user's home on every invocation.

proc dotnetOutputs*(dotnetExe, csproj: string;
                    configuration = "Release"): DiscoveredOutputs =
  ## MSBuild's own evaluation of the project (``-getProperty``, MSBuild 17.8
  ## / .NET SDK 8): ``TargetPath`` is the assembly a consumer references,
  ## ``TargetDir`` and ``IntermediateOutputPath`` the two trees the build
  ## writes. Every ``OutputPath``, ``BaseOutputPath``, ``AssemblyName``,
  ## ``RuntimeIdentifier`` and ``Append*ToOutputPath`` setting, wherever it
  ## comes from (the project, ``Directory.Build.props``, the SDK), is
  ## already applied. The apphost and everything else ``TargetDir`` holds
  ## are recorded with the tree.
  ##
  ## A multi-targeting project (``<TargetFrameworks>``, plural) has no
  ## ``TargetPath`` of its own: ``dotnet build`` runs one inner build per
  ## framework, each with ``TargetFramework`` set as a global property. Each
  ## inner build is evaluated the same way here, and each one's trees and
  ## assembly are declared.
  ## https://learn.microsoft.com/en-us/visualstudio/msbuild/evaluate-items-and-properties
  ## https://learn.microsoft.com/en-us/dotnet/standard/frameworks#how-to-specify-a-target-framework
  let projectDir = csproj.parentDir
  const outputProperties = ["TargetPath", "TargetDir", "ProjectDir",
    "IntermediateOutputPath"]
  proc query(globals: seq[string]; names: openArray[string]): ToolQuery =
    var args = @["msbuild", csproj, "-nologo",
      "-p:Configuration=" & configuration] & globals
    for name in names:
      args.add("-getProperty:" & name)
    ToolQuery(exe: dotnetExe, args: args)
  proc properties(answer: string): JsonNode =
    # The JSON object is the whole of a successful answer; anything around
    # it is a warning the SDK printed.
    let first = answer.find('{')
    let last = answer.rfind('}')
    try:
      if first < 0 or last < first:
        raise newException(ValueError, "no JSON object")
      result = parseJson(answer[first .. last])["Properties"]
    except CatchableError:
      raise newException(ValueError, "MSBuild did not report the output " &
        "properties of " & csproj & ": " & answer)
  proc declare(found: JsonNode; discovered: var DiscoveredOutputs;
               build: string) =
    proc property(name: string): string =
      result = found{name}.getStr().strip()
      if result.len == 0:
        raise newException(ValueError, "MSBuild evaluated an empty " & name &
          " for " & csproj & build)
    let targetDir = property("TargetDir")
    var intermediate = property("IntermediateOutputPath")
    if not intermediate.isAbsolute:
      intermediate = property("ProjectDir") / intermediate
    requireTreeOutsideProject(targetDir, projectDir, "MSBuild's TargetDir")
    requireTreeOutsideProject(intermediate, projectDir,
      "MSBuild's IntermediateOutputPath")
    discovered.opaqueOutputs.add(@[targetDir, intermediate])
    discovered.outputs.add(property("TargetPath"))
  let outer = properties(runToolQueries(projectDir, [query(@[],
    @outputProperties & @["TargetFramework", "TargetFrameworks"])])[0])
  var frameworks: seq[string] = @[]
  if outer{"TargetFramework"}.getStr().strip().len == 0:
    for raw in outer{"TargetFrameworks"}.getStr().split(';'):
      let framework = raw.strip()
      if framework.len > 0 and framework notin frameworks:
        frameworks.add(framework)
  if frameworks.len == 0:
    declare(outer, result, "")
    return
  var queries: seq[ToolQuery] = @[]
  for framework in frameworks:
    queries.add(query(@["-p:TargetFramework=" & framework], outputProperties))
  let answers = runToolQueries(projectDir, queries)
  for i, answer in answers:
    declare(properties(answer), result,
      " (TargetFramework " & frameworks[i] & ")")

# --- SwiftPM ---------------------------------------------------------------

proc swiftOutputDirectory*(swiftExe, projectRoot: string): string =
  ## SwiftPM owns the build triple and directory layout. This query plans no
  ## compilation and lets a single delegated build own its complete release
  ## tree, including automatic-library modules and dynamic/static products.
  let process = uncontrolledStartProcess(swiftExe, workingDir = projectRoot,
    args = @["build", "-c", "release", "--show-bin-path"],
    options = {poUsePath, poStdErrToStdOut})
  defer: process.close()
  let output = process.outputStream.readToEnd()
  if process.waitForExit() != 0:
    raise newException(ValueError, "SwiftPM output directory query failed: " & output)
  for line in output.splitLines():
    if line.strip().len > 0: result = line.strip()
  if not result.isAbsolute:
    raise newException(ValueError, "SwiftPM did not report an absolute output directory: " & output)

# ---------------------------------------------------------------------------
# The discovery command the standard provider runs as an action

proc delegatedOutputsCommand*(kind, fragment, consumerId, projectRoot,
                              tool: string;
                              extra: openArray[string] = []): seq[string] =
  ## The argv of a discovery edge: this standard-provider binary, asked to
  ## query `tool` and write `fragment` for the action `consumerId`.
  @[getAppFilename(), "--delegated-outputs", kind, fragment, consumerId,
    projectRoot, tool] & @extra

proc delegatedOutputsFragmentPath*(projectRoot, conventionName: string): string =
  ## Where a delegating convention's discovery writes its fragment: under the
  ## project's ``.repro/build`` scratch area, outside every tool tree.
  projectRoot / ".repro" / "build" / (conventionName & "-outputs.dyndep")

proc delegatedOutputsAction*(conventionName, kind, consumerId, projectRoot,
                             tool: string; inputs: openArray[string];
                             extra: openArray[string] = [];
                             scratchDirs: openArray[string] = [];
                             env: openArray[(string, string)] = []):
    tuple[action: BuildActionDef; fragment: string] =
  ## The discovery edge of a delegating convention, `<conventionName>-
  ## outputs`, and the fragment it writes. The build edge `consumerId` lists
  ## the fragment as an input AND as its ``dynamicDepsFile``, and depends on
  ## this edge. Monitored: what the tool reads to evaluate the build's
  ## configuration (parent POMs, init scripts, ``Directory.Build.props``,
  ## ``cabal.project``) keys the answer. Build-Engine-And-Scheduler.md
  ## §"Discovery".
  let fragment = delegatedOutputsFragmentPath(projectRoot, conventionName)
  result.fragment = fragment
  result.action = buildAction(
    id = conventionName & "-outputs",
    call = inlineExecCall(delegatedOutputsCommand(kind, fragment, consumerId,
      projectRoot, tool, extra), projectRoot),
    inputs = inputs,
    outputs = @[fragment],
    pool = "compile",
    dependencyPolicy = automaticMonitorPolicy(),
    commandStatsId = conventionName & ".outputs",
    env = env,
    scratchDirs = scratchDirs)

proc runDelegatedOutputsCommand(args: seq[string]) =
  if args.len < 6:
    raise newException(ValueError, "invalid delegated output discovery arguments")
  let kind = args[1]
  let fragment = args[2]
  let consumerId = args[3]
  let projectRoot = args[4]
  let tool = args[5]
  let extra = args[6 .. ^1]
  proc expectExtra(count: int) =
    if extra.len != count:
      raise newException(ValueError, "invalid " & kind &
        " output discovery arguments")
  let discovered = case kind
    of "maven":
      expectExtra(0)
      mavenOutputs(tool, projectRoot)
    of "gradle":
      expectExtra(1)
      gradleOutputs(tool, projectRoot, extra[0])
    of "cabal":
      if extra.len < 3:
        raise newException(ValueError, "invalid cabal output discovery arguments")
      cabalOutputs(tool, projectRoot, extra[0], extra[1], extra[2 .. ^1])
    of "dotnet":
      expectExtra(1)
      dotnetOutputs(tool, extra[0])
    else:
      raise newException(ValueError, "unknown delegated build kind: " & kind)
  writeOutputFragment(fragment, consumerId, discovered)

proc runOutputDiscoveryCommand*(args: seq[string]): bool =
  ## Internal standard-provider operation, invoked by a discovery action.
  if args.len > 0 and args[0] == "--delegated-outputs":
    runDelegatedOutputsCommand(args)
    return true
  if args.len > 0 and args[0] == "--swift-output-directory":
    if args.len != 4:
      raise newException(ValueError, "invalid Swift output discovery arguments")
    let output = swiftOutputDirectory(args[1], args[2])
    let alias = args[2] / ".build/release"
    # The release directory is the opaque output tree: removed before the
    # build, so a product a since-edited manifest no longer declares cannot
    # be recorded with it. The `.build/release` alias is a link SwiftPM
    # may not create.
    writeOutputFragment(args[3], "swift-swiftpm-build", @[],
      if alias != output: @[alias] else: @[], opaqueOutputs = @[output])
    return true
  if args.len == 0 or args[0] != "--convention-outputs": return false
  if args.len < 3 or (args.len - 3) mod 3 != 0:
    raise newException(ValueError, "invalid convention output discovery arguments")
  let kind = args[1]
  let buildDir = args[2]
  var i = 3
  while i < args.len:
    let artifacts = case kind
      of "cmake": cmakeTargetArtifacts(buildDir, args[i + 1])
      of "meson": DiscoveredOutputs(outputs: mesonTargetOutputs(buildDir, args[i + 1]))
      else: raise newException(ValueError, "unknown convention: " & kind)
    writeOutputFragment(args[i + 2], args[i], artifacts.outputs, artifacts.optionalOutputs)
    inc i, 3
  true

proc outputDiscoveryCommand*(kind, buildDir: string;
    targets: seq[tuple[id, name, fragment: string]]): string =
  var argv = @[getAppFilename(), "--convention-outputs", kind, buildDir]
  for target in targets:
    argv.add(@[target.id, target.name, target.fragment])
  argv.quoteShellCommand()
