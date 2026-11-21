## Java / Maven language convention (Tier 2b) — M40.
##
## First JVM-ecosystem standard-provider convention. Recognises a
## ``pom.xml`` at the project root and shells out to a stock ``mvn``
## binary for an offline ``mvn package`` invocation. The action graph
## is intentionally coarse: one ``mvn package -o`` build action, whose
## products Maven itself names (see **Output paths**).
##
## **Distinction from a hypothetical future Tier 2c Maven provider.**
## A Tier 2c Maven provider would parse Maven's effective-pom / build-
## plan output and lift individual goals / per-source compile commands
## into the reprobuild DAG. That heavyweight path is not in scope for
## M40; M40 is the lightweight Mode 2 ecosystem-delegation sibling
## (mirroring M38 c-cpp-cmake and M39 c-cpp-meson).
##
## **Recognition contract**:
##   * ``<projectRoot>/pom.xml`` exists.
##   * NO sibling Gradle artefacts at the project root (``build.gradle``
##     / ``build.gradle.kts`` — Gradle territory; that's M41's job).
##   * ``<projectRoot>/repro.nim`` (or legacy ``reprobuild.nim``) exists
##     AND ``uses:`` lists ``mvn`` or ``maven`` AND ``java`` (or ``jdk``).
##   * at least one ``executable`` or ``library`` member declared.
##   * a JDK driver (``javac``) is on PATH.
##   * ``mvn`` is on PATH.
##
## **Offline mode** (M40 enforces ``-o`` to keep builds hermetic):
##   * The action runs ``mvn package -o -q`` (offline + quiet). Maven's
##     local repository at ``~/.m2/repository/`` is the staging surface.
##   * If the project declares external Maven dependencies in its
##     ``pom.xml``, those MUST be pre-populated by a provisioning step
##     BEFORE the convention dispatches: ``mvn dependency:go-offline -f
##     <projectRoot>/pom.xml`` from a context with network access (the
##     warm-step). The convention itself never reaches the network.
##   * Output discovery runs the pinned ``maven-help-plugin``
##     (``output_discovery.MavenHelpEvaluate``), which ``go-offline`` does
##     not resolve: the warm step also runs ``mvn <MavenHelpEvaluate>
##     -Dexpression=project.version`` once online.
##   * The M40 fixture ships a self-contained Hello.java (stdlib only),
##     so the only plugins to warm are Maven's defaults and the help
##     plugin.
##
## **Emitted actions**:
##   1. ``java-maven-outputs`` -- asks Maven where the build puts its
##      products: three ``help:evaluate`` queries (``project.build.directory``,
##      ``project.build.finalName``, the packaging's artifact-handler
##      extension), run by the standard provider itself
##      (``output_discovery.mavenOutputs``). Writes a dynamic-output
##      fragment. Monitored, so the parent POMs and settings Maven reads key
##      the answer.
##   2. ``java-maven-package`` -- a single ``mvn package -o -q -f
##      <projectRoot>/pom.xml`` action. Inputs: ``pom.xml``, every ``.java``
##      source file under ``src/main/java/`` and the fragment, which is also
##      its ``dynamicDepsFile``. Its outputs come from the fragment. Uses
##      ``automaticMonitorPolicy``: ``mvn`` spawns a fan-out of plugin
##      processes and the engine monitors their real read-set.
##
## **Output paths** (Build-Engine-And-Scheduler.md §"Outputs a delegated
## build decides"):
##   * ``${project.build.directory}`` (``target/`` by default) is an opaque
##     output directory: removed before ``mvn package`` runs, recorded whole
##     and restored exactly.
##   * ``${project.build.directory}/${project.build.finalName}.<extension>``
##     is the obligatory main artifact: ``<finalName>``, a ``<directory>``
##     override, a version inherited from a parent POM and a non-``jar``
##     packaging are Maven's to apply, not this convention's to predict.
##   * A ``pom``-packaging project builds no artifact of its own and is
##     refused at discovery.
##
## **Honest scope** (deferred):
##   * Multi-module Maven projects (``<modules>`` in pom.xml). Single-
##     module only — recognising a multi-module pom requires parsing the
##     module list and emitting a per-module action graph.
##   * External Maven dependencies. The convention runs ``-o`` (offline)
##     and assumes ``~/.m2/repository/`` is pre-populated. Documented as
##     outstanding above.
##   * ``mvn test`` discovery (M22-style test target). The crude fallback
##     still covers it; a follow-up M may surface a ``#test`` target.
##   * Maven Wrapper (``mvnw``). The convention uses the catalog-
##     provisioned ``mvn``; Maven Wrapper support is a follow-up.
##   * Cross-language (JNI). A Java project that declares a C/C++
##     ``uses:`` companion library is not addressed; deferred.
##   * Gradle — M41's milestone.
##
## See ``reprobuild-specs/Mode3-Language-Expansion.milestones.org`` §M40.

import std/[algorithm, os, strutils]

import repro_core
import repro_provider_runtime
import repro_project_dsl
import repro_standard_provider/convention
import repro_standard_provider/conventions/output_discovery

const
  ScratchDirName* = ".repro/build"
    ## Top-level scratch directory under the project root. Maven builds
    ## into its own build directory; this convention keeps its output
    ## discovery's fragment here.

  ConventionName = "java-maven"
  PackageActionId = ConventionName & "-package"

type
  JavaMavenMemberKind = enum
    jmmExecutable
    jmmLibrary

  JavaMavenMember = object
    name: string
    kind: JavaMavenMemberKind

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

proc usesIncludesJavaMaven(source: string): bool =
  ## True when ``uses:`` lists ``mvn`` or ``maven`` AND ``java`` or
  ## ``jdk``. The convention is conservative — it requires both halves.
  if source.len == 0:
    return false
  var sawJdk = false
  var sawMaven = false
  var inBlock = false
  proc consume(token: string) {.closure.} =
    if token == "java" or token == "jdk" or token == "javac":
      sawJdk = true
    if token == "mvn" or token == "maven":
      sawMaven = true
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
  sawJdk and sawMaven

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

proc extractMembers(source: string): seq[JavaMavenMember] =
  for name in extractExecutables(source):
    result.add(JavaMavenMember(name: name, kind: jmmExecutable))
  for name in extractLibraries(source):
    result.add(JavaMavenMember(name: name, kind: jmmLibrary))

proc hasPomXml(projectRoot: string): bool =
  fileExists(extendedPath(projectRoot / "pom.xml"))

proc hasGradleArtifacts(projectRoot: string): bool =
  ## True when the project root carries Gradle artefacts. The Maven
  ## convention defers to Gradle's future M41 convention in that case
  ## (matching the defensive sibling-conventions pattern).
  fileExists(extendedPath(projectRoot / "build.gradle")) or
    fileExists(extendedPath(projectRoot / "build.gradle.kts")) or
    fileExists(extendedPath(projectRoot / "settings.gradle")) or
    fileExists(extendedPath(projectRoot / "settings.gradle.kts"))

proc javacExecutable(): string =
  ## Resolve a ``javac`` driver on PATH (the convention treats the
  ## presence of ``javac`` — not ``java`` — as the JDK availability
  ## signal; a bare JRE wouldn't be able to compile a Maven project).
  findExe("javac")

proc mvnExecutable(): string =
  ## Resolve a ``mvn`` driver on PATH. On Windows the binary is usually
  ## ``mvn.cmd``; ``findExe`` resolves both shapes via PATHEXT.
  findExe("mvn")

proc javaMavenRecognize(projectRoot: string;
                        request: ProviderGraphRequest): bool {.gcsafe.} =
  ## Recognition contract — see module docstring.
  if not hasPomXml(projectRoot):
    return false
  if hasGradleArtifacts(projectRoot):
    return false
  let source = readReprobuildSource(projectRoot)
  if source.len == 0:
    return false
  if not usesIncludesJavaMaven(source):
    return false
  let members = extractMembers(source)
  if members.len == 0:
    return false
  if javacExecutable().len == 0:
    return false
  if mvnExecutable().len == 0:
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

proc collectJavaInputs(projectRoot: string): seq[string] =
  ## Conservative input enumeration for the package action: the root
  ## ``pom.xml`` plus every ``.java`` file under ``src/main/java/``.
  ## Test sources under ``src/test/java/`` are excluded (M40 ships
  ## ``mvn package`` only; ``mvn test`` discovery is deferred). Resource
  ## files under ``src/main/resources/`` are NOT enumerated — they
  ## don't typically invalidate the produced jar for the minimal-stdlib
  ## fixture, and a follow-up M can lift them when test-discovery
  ## lands.
  if not dirExists(extendedPath(projectRoot)):
    return @[]
  let rootPom = projectRoot / "pom.xml"
  if fileExists(extendedPath(rootPom)):
    result.add(rootPom)
  let javaSrcDir = projectRoot / "src" / "main" / "java"
  if dirExists(extendedPath(javaSrcDir)):
    for entry in walkDirRec(javaSrcDir):
      let lower = entry.toLowerAscii
      if lower.endsWith(".java"):
        result.add(entry)
  # De-dup while preserving order.
  var seen: seq[string] = @[]
  for path in result:
    if path notin seen:
      seen.add(path)
  result = seen
  result.sort(system.cmp[string])

proc emitPackageAction(projectRoot, mvnExe, fragment,
                       discoveryId: string): BuildActionDef =
  ## Emit the single ``mvn package -o -q -f <pom>`` action. Its outputs are
  ## the ones ``java-maven-outputs`` discovered: the build directory as an
  ## opaque output tree and the main artifact inside it as an obligatory
  ## output.
  ##
  ## ``-o`` (offline) enforces the M40 hermetic contract: Maven MUST
  ## NOT reach the network during the action. ``-q`` (quiet) keeps the
  ## per-action logs readable — Maven's default INFO chatter is
  ## extremely verbose. ``-f <pom>`` explicitly names the pom so the
  ## action works regardless of which directory the engine spawns mvn
  ## from.
  let pomPath = projectRoot / "pom.xml"
  let argv = @[mvnExe, "package", "-o", "-q", "-f", pomPath]
  let inputs = collectJavaInputs(projectRoot) & @[fragment]
  buildAction(
    id = PackageActionId,
    call = inlineExecCall(argv, projectRoot),
    deps = @[discoveryId],
    inputs = inputs,
    outputs = @[],
    dynamicDepsFile = fragment,
    pool = "compile",
    # ``mvn`` spawns a fan-out of plugin processes (compiler:compile,
    # resources:resources, jar:jar, etc.); the monitor records their real
    # read-set on top of the enumerated sources.
    dependencyPolicy = automaticMonitorPolicy(),
    commandStatsId = "java-maven.package")

proc syntheticPackage(projectRoot: string;
                      members: seq[JavaMavenMember]): PackageDef =
  var name = "java_maven_convention"
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

proc javaMavenEmitFragment(projectRoot: string;
                           request: ProviderGraphRequest):
                             GraphFragment {.gcsafe.} =
  ## Convention entry — emit the single package action, hand the bundle
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
        "java-maven convention: no executable or library members " &
          "declared in " & projectFile)
    if javacExecutable().len == 0:
      raise newException(ValueError,
        "java-maven convention: no 'javac' on PATH (JDK required)")
    let mvnExe = mvnExecutable()
    if mvnExe.len == 0:
      raise newException(ValueError,
        "java-maven convention: no 'mvn' on PATH")
    let pkg = syntheticPackage(projectRoot, members)
    let registerAll = proc() =
      discard buildPool("compile", 8'u32)
      let discovery = delegatedOutputsAction(ConventionName, "maven",
        PackageActionId, projectRoot, mvnExe,
        inputs = @[projectRoot / "pom.xml"])
      let packageAction = emitPackageAction(projectRoot, mvnExe,
        discovery.fragment, discovery.action.id)
      defaultTarget(target("default", @[discovery.action, packageAction]))
    result = buildPackageFragment(pkg, request, registerAll,
      includeDefault = false)

proc javaMavenConvention*(): LanguageConvention =
  ## The single value the standard provider binary registers at startup.
  LanguageConvention(
    name: "java-maven",
    recognize: javaMavenRecognize,
    emitFragment: javaMavenEmitFragment)
