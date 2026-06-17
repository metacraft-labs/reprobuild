## Java / Maven language convention (Tier 2b) — M40.
##
## First JVM-ecosystem standard-provider convention. Recognises a
## ``pom.xml`` at the project root and shells out to a stock ``mvn``
## binary for an offline ``mvn package`` invocation. The action graph
## is intentionally coarse: one ``mvn package -o`` build action that
## produces ``target/<artifactId>-<version>.jar`` per declared member.
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
##   * The M40 fixture ships a self-contained Hello.java (stdlib only)
##     so the warm-step is a no-op; the convention can be exercised
##     end-to-end without provisioning external deps.
##
## **Emitted actions**:
##   1. ``java-maven-package`` — single ``mvn package -o -q -f
##      <projectRoot>/pom.xml`` action. Inputs: ``pom.xml`` plus every
##      ``.java`` source file under ``src/main/java/`` (conservative
##      enumeration; header tweaks aren't a Java concept so we miss
##      nothing by limiting to ``.java``). Outputs: one
##      ``target/<artifactId>-<version>.jar`` per declared member (M40
##      assumes the project produces a single jar — ``<artifactId>`` is
##      parsed from ``pom.xml``). Uses ``declaredOnlyDependencyPolicy`` —
##      ``mvn`` spawns a fan-out of plugin processes whose FS reads
##      aren't reliably observed via Windows DLL-interpose (same
##      constraint M38 / M39 face for their configure actions).
##
## **Output paths**:
##   * Executable / library: ``target/<artifactId>-<version>.jar``.
##     Maven's default ``maven-jar-plugin`` lays the produced jar at
##     ``target/${project.artifactId}-${project.version}.jar`` under the
##     project root. The convention parses ``<artifactId>`` and
##     ``<version>`` from the root ``pom.xml`` to predict the path.
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

const
  ScratchDirName* = ".repro/build"
    ## Top-level scratch directory under the project root. Identical to
    ## the C/C++ conventions' value, but M40 doesn't actually use it as
    ## a build dir — Maven writes to ``<projectRoot>/target/`` (its own
    ## convention). The constant is retained for consistency.

  MavenTargetSubdir* = "target"
    ## Sub-directory under the project root where Maven lays its build
    ## outputs (jars). Hard-coded in Maven; the convention predicts the
    ## jar path under this directory.

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

proc extractSimpleXmlTag(source, tagName: string): string =
  ## Return the inner text of the first top-level ``<tagName>...
  ## </tagName>`` occurrence in ``source``. Intentionally crude —
  ## avoids pulling in an XML parser for parsing two scalar fields out
  ## of the M40 pom.xml shape (``<artifactId>`` and ``<version>``). The
  ## helper assumes the tag's value is on a single line, the standard
  ## Maven pom.xml layout. Returns the empty string when the tag isn't
  ## found, when it's nested under a different top-level element (e.g.
  ## a ``<dependency><artifactId>...</artifactId></dependency>`` block
  ## — the helper picks the FIRST occurrence; for the standard pom.xml
  ## shape the project-level ``<artifactId>`` precedes ``<dependencies>``
  ## so the helper does the right thing), or when the value is empty.
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

type PomCoordinates = object
  artifactId: string
  version: string

proc parsePomCoordinates(projectRoot: string): PomCoordinates =
  ## Parse ``<artifactId>`` and ``<version>`` from ``pom.xml`` so we
  ## can predict the produced jar's filename. Returns blank fields when
  ## the pom.xml is unreadable or the tags are missing — callers detect
  ## the blank and either raise or fall through (recognize/emitFragment
  ## treat a blank ``artifactId`` as a hard failure since the output
  ## path can't be predicted without it).
  let pomPath = projectRoot / "pom.xml"
  if not fileExists(extendedPath(pomPath)):
    return
  var pomSource = ""
  try:
    pomSource = readFile(extendedPath(pomPath))
  except CatchableError:
    return
  result.artifactId = extractSimpleXmlTag(pomSource, "artifactId")
  result.version = extractSimpleXmlTag(pomSource, "version")

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
  let coords = parsePomCoordinates(projectRoot)
  if coords.artifactId.len == 0:
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

proc producedJarPath(projectRoot: string;
                     coords: PomCoordinates): string =
  ## Predicted output path for the Maven build's produced jar. Maven's
  ## default ``maven-jar-plugin`` lays the jar at ``target/<artifactId>-
  ## <version>.jar``; when the pom omits ``<version>`` (unusual but
  ## valid for inherited-from-parent flavours) Maven still produces a
  ## jar named ``<artifactId>-.jar`` — the convention preserves the
  ## raw string so the prediction matches reality even in that edge
  ## case.
  let jarName =
    if coords.version.len > 0:
      coords.artifactId & "-" & coords.version & ".jar"
    else:
      coords.artifactId & ".jar"
  projectRoot / MavenTargetSubdir / jarName

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

proc emitPackageAction(projectRoot, mvnExe: string;
                       coords: PomCoordinates): BuildActionDef =
  ## Emit the single ``mvn package -o -q -f <pom>`` action. Outputs the
  ## predicted ``target/<artifactId>-<version>.jar`` path under the
  ## project root.
  ##
  ## ``-o`` (offline) enforces the M40 hermetic contract: Maven MUST
  ## NOT reach the network during the action. ``-q`` (quiet) keeps the
  ## per-action logs readable — Maven's default INFO chatter is
  ## extremely verbose. ``-f <pom>`` explicitly names the pom so the
  ## action works regardless of which directory the engine spawns mvn
  ## from.
  let pomPath = projectRoot / "pom.xml"
  let jarPath = producedJarPath(projectRoot, coords)
  createDir(extendedPath(parentDir(jarPath)))
  let argv = @[mvnExe, "package", "-o", "-q", "-f", pomPath]
  let inputs = collectJavaInputs(projectRoot)
  buildAction(
    id = "java-maven-package",
    call = inlineExecCall(argv, projectRoot),
    inputs = inputs,
    outputs = @[jarPath],
    pool = "compile",
    # ``mvn`` spawns a fan-out of plugin processes (compiler:compile,
    # resources:resources, jar:jar, etc.) whose FS reads aren't
    # reliably observed via the Windows DLL-interpose path. Same
    # constraint M38/M39's configure actions face. Enumerate inputs
    # explicitly via ``collectJavaInputs`` so per-source invalidation
    # still works without monitoring.
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
    let coords = parsePomCoordinates(projectRoot)
    if coords.artifactId.len == 0:
      raise newException(ValueError,
        "java-maven convention: pom.xml missing <artifactId> tag; " &
          "cannot predict produced jar's output path")
    let pkg = syntheticPackage(projectRoot, members)
    let registerAll = proc() =
      discard buildPool("compile", 8'u32)
      let packageAction = emitPackageAction(projectRoot, mvnExe, coords)
      defaultTarget(target("default", @[packageAction]))
    result = buildPackageFragment(pkg, request, registerAll,
      includeDefault = false)

proc javaMavenConvention*(): LanguageConvention =
  ## The single value the standard provider binary registers at startup.
  LanguageConvention(
    name: "java-maven",
    recognize: javaMavenRecognize,
    emitFragment: javaMavenEmitFragment)
