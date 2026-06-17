## Kotlin / Gradle language convention (Tier 2b) — M41.
##
## Second JVM-ecosystem standard-provider convention (sibling of the M40
## ``java-maven`` Tier 2b convention). Recognises a ``build.gradle.kts``
## (Kotlin DSL, preferred) or ``build.gradle`` (Groovy DSL) at the
## project root and shells out to a stock ``gradle`` binary (or the
## project-shipped ``gradlew`` wrapper when present) for a single
## offline ``gradle build`` invocation. The action graph is intentionally
## coarse: one ``gradle build --offline --no-daemon -q`` action that
## produces ``build/libs/<projectName>-<version>.jar`` per declared
## member.
##
## **Distinction from a hypothetical future Tier 2c Gradle provider.**
## A Tier 2c Gradle provider would parse Gradle's tooling-API model
## output and lift individual tasks / per-source compile commands into
## the reprobuild DAG. That heavyweight path is not in scope for M41;
## M41 is the lightweight Mode 2 ecosystem-delegation sibling (mirroring
## M38 c-cpp-cmake, M39 c-cpp-meson, and M40 java-maven).
##
## **Recognition contract**:
##   * ``<projectRoot>/build.gradle.kts`` OR ``<projectRoot>/build.gradle``
##     exists (Kotlin DSL preferred — checked first; the Groovy DSL
##     filename is accepted as a fall-back since the Gradle ecosystem
##     still has plenty of Groovy projects).
##   * NO ``pom.xml`` at the project root (Maven territory — the M40
##     ``java-maven`` convention claims that case; defensive bidirectional
##     rejection mirrors the M38/M39/M40 sibling-convention pattern).
##   * ``<projectRoot>/repro.nim`` (or legacy ``reprobuild.nim``) exists
##     AND ``uses:`` lists ``gradle`` or ``kotlin`` AND ``java`` (or
##     ``jdk`` / ``javac``).
##   * at least one ``executable`` or ``library`` member declared.
##   * a JDK driver (``javac``) is on PATH (Gradle invokes ``javac`` for
##     the underlying ``compileJava`` task; bare ``java`` runtime is not
##     enough).
##   * ``gradle`` is on PATH OR ``<projectRoot>/gradlew[.bat]`` exists
##     (the project ships a Gradle wrapper).
##
## **Wrapper vs. system Gradle** (M41 prefers the project-shipped
## wrapper when present):
##   * If ``<projectRoot>/gradlew.bat`` (Windows) or ``gradlew`` (POSIX)
##     exists, the convention prefers it over the system ``gradle``. The
##     wrapper is version-pinned by the project's
##     ``gradle/wrapper/gradle-wrapper.properties``, so using the wrapper
##     locks the Gradle version to whatever the project intends.
##   * Otherwise the convention falls back to whatever ``gradle`` is on
##     PATH. The documented provisioning install location is
##     ``D:/metacraft-dev-deps/gradle/8.x/`` (Gradle 8.x) for the dev
##     shell.
##
## **Offline mode** (M41 enforces ``--offline`` to keep builds hermetic):
##   * The action runs ``gradle build --offline --no-daemon -q``.
##     Gradle's dependency cache at ``~/.gradle/caches/`` is the staging
##     surface.
##   * If the project declares external Gradle/Maven dependencies in its
##     ``build.gradle[.kts]``, those MUST be pre-populated by a
##     provisioning step BEFORE the convention dispatches: a non-offline
##     ``gradle build`` from a context with network access (the warm
##     step). The convention itself never reaches the network.
##   * The M41 fixture ships a self-contained Hello.kt (no external
##     dependencies beyond the Kotlin stdlib, which Gradle resolves from
##     the wrapper-bundled Maven Central mirror) so the warm-step is a
##     no-op for the fixture; the convention can be exercised end-to-end
##     without provisioning external deps once the host has warmed
##     ``~/.gradle/caches/`` once.
##
## **Daemon explicitly disabled** (``--no-daemon``): Gradle daemons
## mutate global state across builds (open JVM, class loaders, in-memory
## caches) and break Reprobuild's hermetic-action guarantee. The
## daemon-off mode is slower per-action; an opt-in daemon flag is
## deferred to a follow-up M (the spec calls this out).
##
## **Emitted actions**:
##   1. ``kotlin-gradle-build`` — single ``<gradleExe> build --offline
##      --no-daemon -q`` action under the project root. Inputs: every
##      ``build.gradle[.kts]`` / ``settings.gradle[.kts]`` /
##      ``gradle.properties`` at the project root plus every ``.kt`` /
##      ``.java`` source file under ``src/main/``. Outputs: one
##      ``build/libs/<projectName>-<version>.jar`` per declared member
##      (M41 assumes the project produces a single jar — the convention
##      parses ``rootProject.name`` from ``settings.gradle[.kts]`` and
##      ``version = "..."`` from ``build.gradle[.kts]`` to predict the
##      path). Uses ``declaredOnlyDependencyPolicy`` — ``gradle`` spawns
##      a fan-out of plugin processes whose FS reads aren't reliably
##      observed via Windows DLL-interpose (same constraint M38 / M39 /
##      M40 face for their configure / package actions).
##
## **Output paths**:
##   * Executable / library: ``build/libs/<projectName>-<version>.jar``.
##     Gradle's ``application`` + ``java`` plugins lay the produced jar
##     at ``<projectRoot>/build/libs/${rootProject.name}-${version}.jar``
##     by default. When the project omits the ``version`` declaration,
##     Gradle's default is ``unspecified`` — the convention treats that
##     as a missing-version and produces ``<projectName>.jar`` instead.
##     The M41 fixture explicitly sets ``version = "1.0"`` so the jar
##     lands at ``build/libs/hello-1.0.jar`` and the prediction is
##     observable.
##
## **Honest scope** (deferred):
##   * Multi-module Gradle projects (sub-projects via ``include`` in
##     ``settings.gradle``). Single-module only — recognising a multi-
##     module project requires parsing the sub-project list and emitting
##     a per-module action graph.
##   * External Gradle dependencies. The convention runs ``--offline``
##     and assumes ``~/.gradle/caches/`` is pre-populated. Documented as
##     outstanding above.
##   * ``gradle test`` discovery (M22-style ``#test`` target). The
##     crude fallback still covers it; a follow-up M may surface a
##     ``#test`` target.
##   * Gradle Wrapper checksum allowlist. The M41 spec calls for
##     verifying ``gradle/wrapper/gradle-wrapper.jar`` against an
##     allowlist; M41 trusts the project-shipped wrapper without
##     checksum verification. A follow-up M can lift this.
##   * Android Gradle plugin. JVM-only; the Android plugin's
##     ``com.android.application`` task graph is materially different
##     and isn't covered.
##   * Cross-language (JNI / Kotlin Native). A Kotlin/Gradle project
##     that declares a C/C++ ``uses:`` companion library or compiles to
##     Kotlin Native isn't addressed; deferred.
##   * Maven — M40's milestone (this convention defers when
##     ``pom.xml`` is also at the root).
##
## See ``reprobuild-specs/Mode3-Language-Expansion.milestones.org`` §M41.

import std/[algorithm, os, strutils]

import repro_core
import repro_provider_runtime
import repro_project_dsl
import repro_standard_provider/convention

const
  ScratchDirName* = ".repro/build"
    ## Top-level scratch directory under the project root. Identical to
    ## the M40 Maven convention's value, but M41 doesn't actually use it
    ## as a build dir — Gradle writes to ``<projectRoot>/build/`` (its
    ## own convention). The constant is retained for consistency.

  GradleBuildSubdir* = "build"
    ## Sub-directory under the project root where Gradle lays its build
    ## outputs. Hard-coded by Gradle's ``java`` plugin defaults; the
    ## convention predicts the jar path under
    ## ``<projectRoot>/build/libs/``.

  GradleLibsSubdir* = "libs"
    ## Sub-directory under ``build/`` where the ``java`` plugin's
    ## ``jar`` task writes the produced jar.

type
  KotlinGradleMemberKind = enum
    kgmExecutable
    kgmLibrary

  KotlinGradleMember = object
    name: string
    kind: KotlinGradleMemberKind

  GradleCoordinates = object
    projectName: string
    version: string

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

proc usesIncludesKotlinGradle(source: string): bool =
  ## True when ``uses:`` lists ``gradle`` or ``kotlin`` AND ``java`` or
  ## ``jdk`` / ``javac``. The convention is conservative — it requires
  ## both halves (same pattern as the M40 Maven convention's
  ## ``usesIncludesJavaMaven``).
  if source.len == 0:
    return false
  var sawJdk = false
  var sawGradle = false
  var inBlock = false
  proc consume(token: string) {.closure.} =
    if token == "java" or token == "jdk" or token == "javac":
      sawJdk = true
    if token == "gradle" or token == "kotlin":
      sawGradle = true
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
  sawJdk and sawGradle

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

proc extractMembers(source: string): seq[KotlinGradleMember] =
  for name in extractExecutables(source):
    result.add(KotlinGradleMember(name: name, kind: kgmExecutable))
  for name in extractLibraries(source):
    result.add(KotlinGradleMember(name: name, kind: kgmLibrary))

proc hasGradleBuildScript(projectRoot: string): bool =
  ## True when the project root carries either a Kotlin DSL
  ## (``build.gradle.kts``, preferred) or a Groovy DSL (``build.gradle``)
  ## build script.
  fileExists(extendedPath(projectRoot / "build.gradle.kts")) or
    fileExists(extendedPath(projectRoot / "build.gradle"))

proc hasMavenArtifacts(projectRoot: string): bool =
  ## True when the project root carries Maven artefacts. The Gradle
  ## convention defers to the M40 Maven convention in that case
  ## (matching the defensive sibling-conventions pattern).
  fileExists(extendedPath(projectRoot / "pom.xml"))

proc javacExecutable(): string =
  ## Resolve a ``javac`` driver on PATH (the convention treats the
  ## presence of ``javac`` — not ``java`` — as the JDK availability
  ## signal; a bare JRE wouldn't be able to compile a Gradle project's
  ## ``compileJava`` / ``compileKotlin`` task chain).
  findExe("javac")

proc gradleWrapperPath(projectRoot: string): string =
  ## Resolve a project-shipped Gradle wrapper at the project root.
  ## Prefers ``gradlew.bat`` on Windows, ``gradlew`` elsewhere. Returns
  ## the empty string when no wrapper is present.
  when defined(windows):
    let bat = projectRoot / "gradlew.bat"
    if fileExists(extendedPath(bat)):
      return bat
    let posix = projectRoot / "gradlew"
    if fileExists(extendedPath(posix)):
      return posix
  else:
    let posix = projectRoot / "gradlew"
    if fileExists(extendedPath(posix)):
      return posix
    let bat = projectRoot / "gradlew.bat"
    if fileExists(extendedPath(bat)):
      return bat
  ""

proc systemGradleExecutable(): string =
  ## Resolve a ``gradle`` driver on PATH. On Windows the binary is
  ## usually ``gradle.bat``; ``findExe`` resolves both shapes via
  ## PATHEXT.
  findExe("gradle")

proc gradleExecutable(projectRoot: string): string =
  ## Resolve the Gradle driver to invoke. Prefers the project-shipped
  ## wrapper (``gradlew`` / ``gradlew.bat``) over the system ``gradle``
  ## binary. Returns the empty string when neither is available.
  let wrapper = gradleWrapperPath(projectRoot)
  if wrapper.len > 0:
    return wrapper
  systemGradleExecutable()

proc stripQuotedString(value: string): string =
  ## Strip a leading/trailing pair of matching ``"`` or ``'`` characters.
  ## Returns the input unchanged when it isn't quoted.
  if value.len >= 2 and
      (value[0] == '"' or value[0] == '\'') and
      value[^1] == value[0]:
    return value[1 ..< ^1]
  value

proc extractAssignmentValue(source, lhs: string): string =
  ## Find the first line in ``source`` matching ``<lhs> = <value>`` (with
  ## optional whitespace around the ``=``) and return the (unquoted)
  ## value. Used to parse Gradle DSL scalar assignments like
  ## ``rootProject.name = "hello"`` (settings.gradle[.kts]) and
  ## ``version = "1.0"`` (build.gradle[.kts]). Intentionally crude — the
  ## convention assumes the M41 fixture-shape (single-line scalar
  ## assignment), matching the M40 Maven convention's
  ## ``extractSimpleXmlTag`` pattern.
  for rawLine in source.splitLines():
    var line = rawLine
    let commentIdx = line.find("//")
    if commentIdx >= 0:
      line = line[0 ..< commentIdx]
    let stripped = line.strip()
    if not stripped.startsWith(lhs):
      continue
    let rest = stripped[lhs.len .. ^1].strip()
    if rest.len == 0 or rest[0] != '=':
      continue
    let raw = rest[1 .. ^1].strip(chars = {' ', '\t', ';'})
    return stripQuotedString(raw)
  ""

proc readGradleFileOrEmpty(path: string): string =
  if not fileExists(extendedPath(path)):
    return ""
  try:
    readFile(extendedPath(path))
  except CatchableError:
    ""

proc parseGradleCoordinates(projectRoot: string): GradleCoordinates =
  ## Parse ``rootProject.name`` (from ``settings.gradle[.kts]``) and
  ## ``version`` (from ``build.gradle[.kts]``) so we can predict the
  ## produced jar's filename. Returns blank fields when the inputs are
  ## unreadable or the tags are missing — callers detect the blank and
  ## either raise or fall through.
  let settingsKts = readGradleFileOrEmpty(projectRoot / "settings.gradle.kts")
  let settingsGroovy = readGradleFileOrEmpty(projectRoot / "settings.gradle")
  let buildKts = readGradleFileOrEmpty(projectRoot / "build.gradle.kts")
  let buildGroovy = readGradleFileOrEmpty(projectRoot / "build.gradle")
  for source in [settingsKts, settingsGroovy]:
    if source.len == 0:
      continue
    let candidate = extractAssignmentValue(source, "rootProject.name")
    if candidate.len > 0:
      result.projectName = candidate
      break
  if result.projectName.len == 0:
    # Fall back to the project root's basename, matching Gradle's own
    # default when ``settings.gradle[.kts]`` is missing.
    result.projectName = extractFilename(projectRoot)
  for source in [buildKts, buildGroovy]:
    if source.len == 0:
      continue
    let candidate = extractAssignmentValue(source, "version")
    if candidate.len > 0:
      result.version = candidate
      break

proc kotlinGradleRecognize(projectRoot: string;
                           request: ProviderGraphRequest): bool {.gcsafe.} =
  ## Recognition contract — see module docstring.
  if not hasGradleBuildScript(projectRoot):
    return false
  if hasMavenArtifacts(projectRoot):
    return false
  let source = readReprobuildSource(projectRoot)
  if source.len == 0:
    return false
  if not usesIncludesKotlinGradle(source):
    return false
  let members = extractMembers(source)
  if members.len == 0:
    return false
  if javacExecutable().len == 0:
    return false
  if gradleExecutable(projectRoot).len == 0:
    return false
  let coords = parseGradleCoordinates(projectRoot)
  if coords.projectName.len == 0:
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
                     coords: GradleCoordinates): string =
  ## Predicted output path for the Gradle build's produced jar. Gradle's
  ## ``java`` plugin lays the jar at ``build/libs/<projectName>-
  ## <version>.jar`` by default; when the project omits ``version =
  ## "..."`` Gradle treats the version as ``unspecified`` and produces
  ## a jar named ``<projectName>.jar`` (no hyphen, no version segment).
  ## The convention treats a blank version the same way.
  let jarName =
    if coords.version.len > 0:
      coords.projectName & "-" & coords.version & ".jar"
    else:
      coords.projectName & ".jar"
  projectRoot / GradleBuildSubdir / GradleLibsSubdir / jarName

proc collectGradleInputs(projectRoot: string): seq[string] =
  ## Conservative input enumeration for the build action: every
  ## ``build.gradle[.kts]`` / ``settings.gradle[.kts]`` /
  ## ``gradle.properties`` at the project root plus every ``.kt`` /
  ## ``.java`` file under ``src/main/``. Test sources under
  ## ``src/test/`` are excluded (M41 ships ``gradle build`` only;
  ## ``gradle test`` discovery is deferred). Resource files under
  ## ``src/main/resources/`` are NOT enumerated — they don't typically
  ## invalidate the produced jar for the minimal-stdlib fixture, and a
  ## follow-up M can lift them when test-discovery lands.
  if not dirExists(extendedPath(projectRoot)):
    return @[]
  for candidate in ["build.gradle.kts", "build.gradle",
                    "settings.gradle.kts", "settings.gradle",
                    "gradle.properties"]:
    let path = projectRoot / candidate
    if fileExists(extendedPath(path)):
      result.add(path)
  let srcMainDir = projectRoot / "src" / "main"
  if dirExists(extendedPath(srcMainDir)):
    for entry in walkDirRec(srcMainDir):
      let lower = entry.toLowerAscii
      if lower.endsWith(".kt") or lower.endsWith(".java"):
        result.add(entry)
  # De-dup while preserving order.
  var seen: seq[string] = @[]
  for path in result:
    if path notin seen:
      seen.add(path)
  result = seen
  result.sort(system.cmp[string])

proc emitBuildAction(projectRoot, gradleExe: string;
                     coords: GradleCoordinates): BuildActionDef =
  ## Emit the single ``gradle build --offline --no-daemon -q`` action.
  ## Outputs the predicted ``build/libs/<projectName>-<version>.jar``
  ## path under the project root.
  ##
  ## ``--offline`` enforces the M41 hermetic contract: Gradle MUST NOT
  ## reach the network during the action. ``--no-daemon`` enforces the
  ## per-action JVM lifecycle — Gradle daemons mutate global state
  ## across builds. ``-q`` (quiet) keeps the per-action logs readable —
  ## Gradle's default lifecycle chatter is extremely verbose.
  let jarPath = producedJarPath(projectRoot, coords)
  createDir(extendedPath(parentDir(jarPath)))
  let argv = @[gradleExe, "build", "--offline", "--no-daemon", "-q"]
  let inputs = collectGradleInputs(projectRoot)
  buildAction(
    id = "kotlin-gradle-build",
    call = inlineExecCall(argv, projectRoot),
    inputs = inputs,
    outputs = @[jarPath],
    pool = "compile",
    # ``gradle`` spawns a fan-out of task processes (compileKotlin,
    # compileJava, processResources, jar, etc.) whose FS reads aren't
    # reliably observed via the Windows DLL-interpose path. Same
    # constraint M38/M39/M40 face for their configure / package actions.
    # Enumerate inputs explicitly via ``collectGradleInputs`` so per-
    # source invalidation still works without monitoring.
    dependencyPolicy = automaticMonitorPolicy(),
    commandStatsId = "kotlin-gradle.build")

proc syntheticPackage(projectRoot: string;
                      members: seq[KotlinGradleMember]): PackageDef =
  var name = "kotlin_gradle_convention"
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

proc kotlinGradleEmitFragment(projectRoot: string;
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
        "kotlin-gradle convention: no executable or library members " &
          "declared in " & projectFile)
    if javacExecutable().len == 0:
      raise newException(ValueError,
        "kotlin-gradle convention: no 'javac' on PATH (JDK required)")
    let gradleExe = gradleExecutable(projectRoot)
    if gradleExe.len == 0:
      raise newException(ValueError,
        "kotlin-gradle convention: no 'gradle' on PATH and no " &
          "'gradlew[.bat]' wrapper at " & projectRoot)
    let coords = parseGradleCoordinates(projectRoot)
    if coords.projectName.len == 0:
      raise newException(ValueError,
        "kotlin-gradle convention: cannot determine project name " &
          "(neither settings.gradle[.kts] nor a project-root basename " &
          "yielded a non-empty rootProject.name); cannot predict " &
          "produced jar's output path")
    let pkg = syntheticPackage(projectRoot, members)
    let registerAll = proc() =
      discard buildPool("compile", 8'u32)
      let buildAct = emitBuildAction(projectRoot, gradleExe, coords)
      defaultTarget(target("default", @[buildAct]))
    result = buildPackageFragment(pkg, request, registerAll,
      includeDefault = false)

proc kotlinGradleConvention*(): LanguageConvention =
  ## The single value the standard provider binary registers at startup.
  LanguageConvention(
    name: "kotlin-gradle",
    recognize: kotlinGradleRecognize,
    emitFragment: kotlinGradleEmitFragment)
