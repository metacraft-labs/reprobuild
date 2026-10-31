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
import std/[algorithm, json, os, osproc, sets, streams, strtabs, strutils]
import blake3
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
  env*: seq[(string, string)]
    ## Overrides applied on top of this process's environment. An empty
    ## value removes the variable: a query that must not see a host
    ## setting (Gradle's ``GRADLE_RO_DEP_CACHE``) clears it explicitly.

proc queryEnvironment(overrides: openArray[(string, string)]): StringTableRef =
  ## This process's environment with `overrides` applied, or nil (inherit
  ## unchanged) when there are none. Windows variable names are
  ## case-insensitive, so the table is too.
  if overrides.len == 0:
    return nil
  result = when defined(windows): newStringTable(modeCaseInsensitive)
           else: newStringTable(modeCaseSensitive)
  for key, value in envPairs():
    result[key] = value
  for (key, value) in overrides:
    if value.len == 0:
      result.del(key)
    else:
      result[key] = value

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
        args = query.args, env = queryEnvironment(query.env),
        options = {poStdErrToStdOut}))
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

const GradleOfflineFlags* = ["--offline", "--no-daemon", "-q",
  "-Pkotlin.compiler.execution.strategy=in-process"]
  ## Shared by the build and its discovery, so both see the same
  ## configuration.
  ##
  ## * ``--offline``: neither edge reaches the network. Every module comes
  ##   from the read-only dependency cache the fetch edge exported
  ##   (`gradleDependencies`), and one it missed fails the build with
  ##   Gradle's "No cached version ... available for offline mode" instead
  ##   of being downloaded.
  ## * ``--no-daemon``: no Gradle daemon outlives the edge or carries state
  ##   between edges. Gradle may still fork a single-use daemon for the
  ##   build when the build's JVM arguments differ from the client's; it is
  ##   a child of the edge and exits with it.
  ## * ``kotlin.compiler.execution.strategy=in-process``: the Kotlin Gradle
  ##   plugin otherwise starts a Kotlin compile daemon, a JVM that outlives
  ##   the build and logs to the system temporary directory (measured on
  ##   eli-pc with KGP 1.9.25: ``%TEMP%\kotlin-daemon.<date>.log``). In
  ##   process, the compiler runs inside the edge.
  ##   https://kotlinlang.org/docs/gradle-compilation-and-caches.html#defining-kotlin-compiler-execution-strategy

const GradleFetchFlags* = ["--no-daemon", "-q", "--no-configuration-cache",
  "-Pkotlin.compiler.execution.strategy=in-process"]
  ## The dependency fetch's flags: the build's, less ``--offline``. The
  ## configuration cache is off because the resolving task reads every
  ## project's configurations while it runs, which the cache refuses; with it
  ## off nothing is written into the build directory either.

const GradleDependenciesInitScript* = """
// Written by reprobuild's kotlin-gradle convention (output_discovery.nim).
// Resolves every resolvable configuration of every project, and of every
// project's build script, so each module the build can ask for is in the
// dependency cache. Plugins and the settings classpath are resolved while
// the build is configured. This is the task nixpkgs runs to record a Gradle
// build's dependencies (`nixDownloadDeps`,
// pkgs/development/tools/build-managers/gradle/init-deps.gradle).
gradle.projectsLoaded {
  rootProject.allprojects {
    tasks.register("reproResolveDependencies") {
      notCompatibleWithConfigurationCache("resolves every configuration")
      doLast {
        project.buildscript.configurations.findAll { it.canBeResolved }.each { it.resolve() }
        project.configurations.findAll { it.canBeResolved }.each { it.resolve() }
      }
    }
  }
}
"""

proc gradleIsolationEnv*(userHome, readOnlyCache: string): seq[(string, string)] =
  ## The environment of every offline Gradle edge (discovery and build):
  ## a ``GRADLE_USER_HOME`` the edge owns, emptied before it runs, and the
  ## fetch edge's export as ``GRADLE_RO_DEP_CACHE``.
  ## https://docs.gradle.org/current/userguide/dependency_caching.html#sec:shared-readonly-cache
  ##
  ## Nothing the build reads therefore comes from the host's ``~/.gradle``:
  ## the user home is new and empty, so every module, plugin and Kotlin
  ## compiler jar is read from the read-only cache, where the monitor keys
  ## the edge on it. Gradle never writes the read-only cache; what it writes
  ## (lock files, journals, compiled build scripts, extracted native
  ## libraries) lands in the edge's own user home.
  ##
  ## The edge's command line names the same user home
  ## (`gradleUserHomeArgs`), which outranks a host's ``gradle.user.home``
  ## system property; the variable stays for the wrapper scripts and for
  ## anything the build starts that reads it.
  @[("GRADLE_USER_HOME", userHome), ("GRADLE_RO_DEP_CACHE", readOnlyCache)]

proc gradleUserHomeArgs*(userHome: string): seq[string] =
  ## ``--gradle-user-home <userHome>``, on the command line of every Gradle
  ## edge beside the ``GRADLE_USER_HOME`` of `gradleIsolationEnv`.
  ##
  ## The environment variable alone does not isolate an edge. Gradle (and the
  ## wrapper) take the user home from ``-g``/``--gradle-user-home`` first, then
  ## from the ``gradle.user.home`` system property, and only then from
  ## ``GRADLE_USER_HOME``; a host that sets
  ## ``GRADLE_OPTS=-Dgradle.user.home=...`` (a common CI setting) would point
  ## every edge back at one shared home. Measured on eli-pc with Gradle
  ## 8.10.2: with that ``GRADLE_OPTS`` and the variable alone, all three edges
  ## wrote the host-set directory and none wrote its own.
  ## https://docs.gradle.org/current/userguide/directory_layout.html#dir:gradle_user_home
  ## https://docs.gradle.org/current/userguide/command_line_interface.html#environment_options
  @["--gradle-user-home", userHome]

proc gradleReadOnlyCache*(dependenciesRoot: string): string =
  ## The read-only dependency cache the fetch edge exports: a copy of its
  ## private user home's ``caches/modules-2`` at ``<this>/modules-2``.
  dependenciesRoot / "read-only-cache"

proc gradleDistribution*(dependenciesRoot: string): string =
  ## The Gradle distribution a wrapper project's build runs: the one the
  ## wrapper downloaded, verified and unpacked during the fetch, copied out
  ## of the fetch's private user home.
  dependenciesRoot / "distribution"

proc gradleDistributionLauncher*(dependenciesRoot: string): string =
  gradleDistribution(dependenciesRoot) / "bin" /
    (when defined(windows): "gradle.bat" else: "gradle")

proc gradleDependenciesStamp*(dependenciesRoot: string): string =
  ## The fetch edge's declared output: the digest of what it fetched for.
  dependenciesRoot / "dependencies.stamp"

proc gradleFetchUserHome(dependenciesRoot: string): string =
  ## The fetch's own ``GRADLE_USER_HOME``. It persists across fetches, like
  ## the vendor steps' download caches (`npm_vendor`, `cargo_vendor`), so a
  ## re-fetch after one changed version downloads only that module. It is
  ## never read by an offline edge.
  dependenciesRoot / "home"

proc readJavaProperty(path, key: string): string =
  ## The value of `key` in a Java properties file, with the backslash escapes
  ## a ``gradle-wrapper.properties`` uses (``https\://``) undone; "" when the
  ## file or the key is absent.
  ## https://docs.oracle.com/javase/8/docs/api/java/util/Properties.html#load-java.io.Reader-
  if not fileExists(extendedPath(path)):
    return ""
  for raw in readFile(extendedPath(path)).splitLines():
    let line = raw.strip()
    if line.len == 0 or line[0] in {'#', '!'}:
      continue
    let sep = line.find('=')
    if sep <= 0 or line[0 ..< sep].strip() != key:
      continue
    let text = line[sep + 1 .. ^1].strip()
    var i = 0
    while i < text.len:
      if text[i] == '\\' and i + 1 < text.len:
        result.add(text[i + 1])
        inc i, 2
      else:
        result.add(text[i])
        inc i
    return
  ""

proc gradleWrapperProperties*(projectRoot: string): string =
  projectRoot / "gradle" / "wrapper" / "gradle-wrapper.properties"

proc gradleWrapperIsVerified*(projectRoot: string): bool =
  ## Whether the wrapper checks the distribution it downloads against a
  ## declared SHA-256 (``distributionSha256Sum``).
  ## https://docs.gradle.org/current/userguide/gradle_wrapper.html#sec:verification
  readJavaProperty(gradleWrapperProperties(projectRoot),
    "distributionSha256Sum").len > 0

proc gradleVerificationPinsChecksums*(projectRoot: string): bool =
  ## Whether the project's ``gradle/verification-metadata.xml`` pins every
  ## artifact the fetch can download by a checksum Gradle checks: what makes
  ## the fetch a fixed-output action. The file's presence is necessary, not
  ## sufficient. Each of these lets an artifact through without a listed
  ## checksum, so each answers false:
  ##   * ``<verify-signatures>true</verify-signatures>``: an artifact may be
  ##     accepted on a trusted key's signature;
  ##   * ``<trusted-artifacts>`` (``<trust .../>``) and ``<trusted-keys>``:
  ##     artifacts exempted from verification, or trusted by key;
  ##   * ``<verify-metadata>false</verify-metadata>``: POM and Gradle module
  ##     metadata are not checked.
  ## https://docs.gradle.org/current/userguide/dependency_verification.html
  ##
  ## The test is textual (whitespace removed) and can only err toward false:
  ## a false answer costs the fetch its portable record, while a wrong true
  ## one would let a portable lookup substitute an unpinned fetch on another
  ## machine (Cache-Scope P3.4).
  let path = projectRoot / "gradle" / "verification-metadata.xml"
  if not fileExists(extendedPath(path)):
    return false
  var text = ""
  try:
    text = readFile(extendedPath(path))
  except IOError, OSError:
    return false
  var compact = newStringOfCap(text.len)
  for ch in text:
    if ch notin Whitespace:
      compact.add(ch)
  for exemption in ["<verify-signatures>true</verify-signatures>",
                    "<verify-metadata>false</verify-metadata>",
                    "<trust"]:
    if exemption in compact:
      return false
  "<components>" in compact

proc gradleDependenciesToken*(projectRoot, launcher: string; wrapper: bool;
                              inputs: openArray[string]): string =
  ## What a fetch is for: the resolving script, the launcher, and the bytes
  ## of every declared input (build scripts, version catalogs, lockfiles,
  ## verification metadata, wrapper properties). Equal tokens mean the fetch
  ## would ask for the same modules.
  # v2: the fetch passes ``--gradle-user-home``, and its flags are part of
  # the token. A v1 export fetched under a host ``gradle.user.home`` override
  # may be empty, so it is fetched again.
  var text = "repro-gradle-dependencies-v2\n" & GradleDependenciesInitScript &
    "\nflags=" & GradleFetchFlags.join(" ") &
    "\nlauncher=" & launcher & "\nwrapper=" & $wrapper & "\n"
  var sorted = @inputs
  sorted.sort()
  for input in sorted:
    # Relative to the project, so two checkouts of it agree on the token.
    let name = relativePath(input, projectRoot).replace('\\', '/')
    text.add("--input " & name & "\n")
    if fileExists(extendedPath(input)):
      text.add(readFile(extendedPath(input)))
    else:
      text.add("<absent>")
    text.add("\n")
  "blake3:" & blake3.toHex(blake3.digest(text))

proc sameFileContent(a, b: string): bool =
  try:
    getFileSize(extendedPath(a)) == getFileSize(extendedPath(b)) and
      readFile(extendedPath(a)) == readFile(extendedPath(b))
  except OSError, IOError:
    false

proc syncTree(source, destination: string;
              skip: proc (relative: string): bool {.closure.}) =
  ## Makes `destination` hold exactly the files of `source` (less those
  ## `skip` names), rewriting only a file whose bytes differ. An unchanged
  ## export therefore leaves every file untouched: the offline edges are
  ## keyed on what they read here, and a rewrite with the same bytes is
  ## still a change to the engine's revalidation (the same reason
  ## `writeOutputFragment` writes only a changed answer).
  var wanted = initHashSet[string]()
  if dirExists(extendedPath(source)):
    # Through the extended-length spelling: a module path under
    # ``files-2.1/<group>/<name>/<version>/<sha1>/`` routinely passes
    # Windows' 260-character MAX_PATH.
    for path in walkDirRec(extendedPath(source),
                           yieldFilter = {pcFile, pcLinkToFile},
                           relative = true):
      let relative = path.replace('\\', '/')
      if skip(relative):
        continue
      wanted.incl(relative)
      let target = destination / relative
      if fileExists(extendedPath(target)) and
          sameFileContent(source / relative, target):
        continue
      createDir(extendedPath(target.parentDir))
      copyFileWithPermissions(extendedPath(source / relative),
        extendedPath(target))
  createDir(extendedPath(destination))
  var stale: seq[string] = @[]
  for path in walkDirRec(extendedPath(destination),
                         yieldFilter = {pcFile, pcLinkToFile},
                         relative = true):
    if path.replace('\\', '/') notin wanted:
      stale.add(path)
  for path in stale:
    removeFile(extendedPath(destination / path))

proc unpackedWrapperDistribution(fetchHome, projectRoot: string): string =
  ## Where the wrapper unpacked the distribution its properties name:
  ## ``<user home>/wrapper/dists/<zip name>/<url hash>/<root>`` with
  ## ``bin/gradle`` inside. The hash directory is the wrapper's own
  ## (``PathAssembler``); it is found, not computed.
  let url = readJavaProperty(gradleWrapperProperties(projectRoot),
    "distributionUrl")
  if url.len == 0:
    raise newException(ValueError, gradleWrapperProperties(projectRoot) &
      " names no distributionUrl")
  var name = url
  let slash = max(name.rfind('/'), name.rfind('\\'))
  if slash >= 0:
    name = name[slash + 1 .. ^1]
  if name.toLowerAscii().endsWith(".zip"):
    name.setLen(name.len - 4)
  let launcherName = when defined(windows): "gradle.bat" else: "gradle"
  let dists = fetchHome / "wrapper" / "dists" / name
  if dirExists(extendedPath(dists)):
    for hashDir in walkDir(dists):
      if hashDir.kind != pcDir:
        continue
      for root in walkDir(hashDir.path):
        if root.kind == pcDir and
            fileExists(extendedPath(root.path / "bin" / launcherName)):
          return root.path
  raise newException(ValueError, "the Gradle wrapper left no unpacked " &
    "distribution under " & dists)

proc gradleDependencies*(launcher: string; wrapper: bool;
                         projectRoot, dependenciesRoot, scratch: string;
                         inputs: openArray[string]): bool =
  ## The dependency fetch: resolves every module the build can ask for into
  ## a private user home, online, and exports that home's dependency cache
  ## as the read-only cache the offline edges read
  ## (`gradleIsolationEnv`). For a wrapper project the wrapper downloads,
  ## checks (``distributionSha256Sum``) and unpacks the distribution during
  ## the same run, and the unpacked distribution is exported too: the
  ## offline edges run it directly, never the wrapper, which would download
  ## into their empty user home.
  ##
  ## Returns false, having run nothing, when the stamp already names this
  ## fetch's token and the export is in place: the edge reaches the network,
  ## so it is never cached and runs on every build (like the vendor steps,
  ## `npm_vendor`), and the token keeps that run from starting a JVM.
  ##
  ## Determinism is Gradle's own: a committed ``gradle/verification-
  ## metadata.xml`` makes the resolution fail on any module whose checksum
  ## it does not list, and lockfiles make it fail on any version they do not
  ## list. https://docs.gradle.org/current/userguide/dependency_verification.html
  ## https://docs.gradle.org/current/userguide/dependency_locking.html
  let token = gradleDependenciesToken(projectRoot, launcher, wrapper, inputs)
  let stamp = gradleDependenciesStamp(dependenciesRoot)
  let readOnly = gradleReadOnlyCache(dependenciesRoot)
  let exported = dirExists(extendedPath(readOnly / "modules-2")) and
    (not wrapper or
     fileExists(extendedPath(gradleDistributionLauncher(dependenciesRoot))))
  if exported and fileExists(extendedPath(stamp)):
    try:
      if readFile(extendedPath(stamp)).strip() == token:
        return false
    except IOError:
      discard
  let home = gradleFetchUserHome(dependenciesRoot)
  createDir(extendedPath(home))
  createDir(extendedPath(scratch))
  let script = scratch / "repro-dependencies.init.gradle"
  writeFile(extendedPath(script), GradleDependenciesInitScript)
  # A host-wide read-only cache must not stand in for a download: what the
  # build will read is what this fetch put in its own home.
  discard runToolQueries(projectRoot, [ToolQuery(exe: launcher,
    args: @GradleFetchFlags & gradleUserHomeArgs(home) &
      @["-p", projectRoot, "-I", script,
      "--project-cache-dir", scratch / "project-cache",
      "reproResolveDependencies"],
    env: @[("GRADLE_USER_HOME", home), ("GRADLE_RO_DEP_CACHE", "")])])
  # Gradle's documented copy: the whole ``modules-2`` less its lock files
  # and ``gc.properties``.
  # https://docs.gradle.org/current/userguide/dependency_caching.html#sec:shared-readonly-cache
  syncTree(home / "caches" / "modules-2", readOnly / "modules-2",
    proc (relative: string): bool =
      relative.endsWith(".lock") or relative == "gc.properties")
  if wrapper:
    syncTree(unpackedWrapperDistribution(home, projectRoot),
      gradleDistribution(dependenciesRoot),
      proc (relative: string): bool = false)
  var previous = ""
  if fileExists(extendedPath(stamp)):
    try: previous = readFile(extendedPath(stamp)).strip()
    except IOError: discard
  if previous != token:
    writeFile(extendedPath(stamp), token & "\n")
  true

proc gradleOutputs*(gradleExe, projectRoot, scratch,
                    readOnlyCache: string): DiscoveredOutputs =
  ## Asks Gradle through an init script, isolated like the build
  ## (`gradleIsolationEnv`): its user home is ``<scratch>/user-home``,
  ## emptied first, and its project cache ``<scratch>/project-cache``, so
  ## nothing is written into the build's project cache, build directory or
  ## the host's ``~/.gradle``.
  createDir(extendedPath(scratch))
  let script = scratch / "repro-outputs.init.gradle"
  let answer = scratch / "outputs.txt"
  let userHome = scratch / "user-home"
  writeFile(extendedPath(script), GradleOutputsInitScript)
  if fileExists(extendedPath(answer)):
    removeFile(extendedPath(answer))
  if dirExists(extendedPath(userHome)):
    # Extended-length: Gradle's compiled build-script accessors nest past
    # Windows' MAX_PATH.
    removeDir(extendedPath(userHome))
  discard runToolQueries(projectRoot, [ToolQuery(exe: gradleExe,
    args: @GradleOfflineFlags & gradleUserHomeArgs(userHome) &
      @["-p", projectRoot, "-I", script,
      "--project-cache-dir", scratch / "project-cache", "reproDescribeOutputs",
      "-Prepro.outputs.file=" & answer],
    env: gradleIsolationEnv(userHome, readOnlyCache))])
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
                             env: openArray[(string, string)] = [];
                             deps: openArray[string] = []):
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
    deps = @deps,
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
      expectExtra(2)
      gradleOutputs(tool, projectRoot, extra[0], extra[1])
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

proc gradleDependenciesCommand*(projectRoot, launcher: string; wrapper: bool;
                                dependenciesRoot, scratch: string;
                                inputs: openArray[string]): seq[string] =
  ## The argv of the Gradle dependency-fetch edge: this standard-provider
  ## binary, asked to run `gradleDependencies`. The inputs travel in the argv
  ## so the fetch's token covers exactly the files the edge declares.
  @[getAppFilename(), "--gradle-dependencies", projectRoot, launcher,
    (if wrapper: "wrapper" else: "gradle"), dependenciesRoot, scratch] &
    @inputs

proc runOutputDiscoveryCommand*(args: seq[string]): bool =
  ## Internal standard-provider operation, invoked by a discovery action.
  if args.len > 0 and args[0] == "--delegated-outputs":
    runDelegatedOutputsCommand(args)
    return true
  if args.len > 0 and args[0] == "--gradle-dependencies":
    if args.len < 6 or args[3] notin ["wrapper", "gradle"]:
      raise newException(ValueError, "invalid Gradle dependency fetch arguments")
    let fetched = gradleDependencies(args[2], args[3] == "wrapper", args[1],
      args[4], args[5], args[6 .. ^1])
    echo(if fetched: "gradle dependencies: fetched and exported"
         else: "gradle dependencies: up to date")
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
