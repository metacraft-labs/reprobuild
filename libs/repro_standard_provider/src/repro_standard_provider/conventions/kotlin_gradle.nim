## Kotlin / Gradle language convention (Tier 2b) — M41.
##
## Second JVM-ecosystem standard-provider convention (sibling of the M40
## ``java-maven`` Tier 2b convention). Recognises a ``build.gradle.kts``
## (Kotlin DSL, preferred) or ``build.gradle`` (Groovy DSL) at the
## project root and shells out to a stock ``gradle`` binary (or the
## project-shipped ``gradlew`` wrapper when present) for a single
## offline ``gradle build`` invocation. The action graph is intentionally
## coarse: one ``gradle build --offline --no-daemon -q`` action, whose
## products Gradle itself names (see **Output paths**).
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
## **Dependencies and the user home** (Language-Conventions/Kotlin.md
## §"Dependencies: a fetch edge and an isolated user home"; owner decision
## of 2026-10-28):
##   * One edge, ``kotlin-gradle-dependencies``, may reach the network. It
##     resolves every configuration into a private user home and exports
##     that home's ``modules-2`` as a read-only dependency cache
##     (``GRADLE_RO_DEP_CACHE``), plus, for a wrapper project, the
##     distribution the wrapper downloaded and verified.
##   * Discovery and the build run ``--offline`` with that cache and a
##     ``GRADLE_USER_HOME`` inside their own scratch directory, emptied
##     before they run. They read nothing from the host's ``~/.gradle``, and
##     what they read from the export is monitored, so it keys them.
##
## **Daemons explicitly disabled**: ``--no-daemon`` (Gradle may still fork
## a single-use daemon for the build; it is a child of the edge and stops
## with it) and ``-Pkotlin.compiler.execution.strategy=in-process`` (no
## Kotlin compile daemon outliving the edge).
##
## **Emitted actions**:
##   0. ``kotlin-gradle-dependencies`` -- the dependency fetch
##      (``output_discovery.gradleDependencies``), run by the standard
##      provider. Never cached (it reaches the network); a stamp holding the
##      digest of its inputs keeps an unchanged re-run from starting Gradle.
##      Fixed-output when the project commits ``gradle/verification-
##      metadata.xml`` (and, with a wrapper, ``distributionSha256Sum``).
##   1. ``kotlin-gradle-outputs`` -- asks Gradle where the build puts its
##      products: an init script (``output_discovery.GradleOutputsInitScript``)
##      registers a task that reports the root project's
##      ``layout.buildDirectory`` and its ``jar`` task's ``archiveFile``,
##      run by the standard provider itself
##      (``output_discovery.gradleOutputs``) with the build's own offline
##      flags, environment and launcher. Gradle's project cache and user home
##      for that query live in the edge's scratch directory. Writes a
##      dynamic-output fragment. Monitored.
##   2. ``kotlin-gradle-build`` -- a single ``<gradleExe> build --offline
##      --no-daemon -q --project-cache-dir <scratch>/project-cache`` action
##      under the project root, with ``GRADLE_USER_HOME=<scratch>/user-home``
##      and ``GRADLE_RO_DEP_CACHE`` the fetch's export. Inputs: the root
##      build scripts, ``gradle.properties``, version catalogs, lockfiles and
##      verification metadata, every ``.kt`` / ``.java`` source file under
##      ``src/main/``, the fetch's stamp and the fragment, which is also its
##      ``dynamicDepsFile``. Its outputs come from the fragment. Its scratch
##      directory (``.repro/build/kotlin-gradle/build``) is emptied before
##      each run: the build directory the project cache describes is removed
##      then too. Uses ``automaticMonitorPolicy``.
##
## **Output paths** (Build-Engine-And-Scheduler.md §"Outputs a delegated
## build decides"):
##   * ``layout.buildDirectory`` (``build/`` by default) is an opaque output
##     directory: removed before ``gradle build`` runs, recorded whole and
##     restored exactly.
##   * The ``jar`` task's ``archiveFile`` is the obligatory main artifact:
##     ``rootProject.name``, ``version``, ``archiveBaseName``,
##     ``archiveVersion``, ``archiveClassifier`` and
##     ``destinationDirectory`` are Gradle's to apply. A build with no
##     ``jar`` task is refused at discovery.
##   * What Gradle writes under ``GRADLE_USER_HOME`` (lock files, journals,
##     compiled build scripts, native libraries) is in the edge's scratch
##     directory, so it is neither an input nor an output and does not keep
##     the S7 gate from admitting a restore.
##
## **Honest scope** (deferred):
##   * Multi-module Gradle projects (sub-projects via ``include`` in
##     ``settings.gradle``). Single-module only — recognising a multi-
##     module project requires parsing the sub-project list and emitting
##     a per-module action graph.
##   * A plugin that resolves a detached configuration inside a task
##     action is not seen by the fetch; the offline build then fails naming
##     the module.
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
import repro_standard_provider/conventions/output_discovery

const
  ScratchDirName* = ".repro/build"
    ## Top-level scratch directory under the project root. Gradle builds
    ## into its own build directory; this convention keeps Gradle's
    ## per-edge project caches and its output discovery here.

  ConventionName = "kotlin-gradle"
  BuildActionId = ConventionName & "-build"
  DependenciesActionId = ConventionName & "-dependencies"

type
  KotlinGradleMemberKind = enum
    kgmExecutable
    kgmLibrary

  KotlinGradleMember = object
    name: string
    kind: KotlinGradleMemberKind

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
  true

proc sanitizeNamePart(value: string): string =
  for ch in value:
    if ch in {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '-', '_', '.'}:
      result.add(ch)
    else:
      result.add('_')
  if result.len == 0:
    result = "x"

proc gradleConfigurationInputs(projectRoot: string): seq[string] =
  ## The files that decide what the build resolves and how it is
  ## configured: the root build scripts and ``gradle.properties``; every
  ## version catalog under ``gradle/`` (``libs.versions.toml`` is the
  ## default one); the dependency lockfiles; and the dependency
  ## verification metadata and keyrings.
  ## https://docs.gradle.org/current/userguide/version_catalogs.html
  ## https://docs.gradle.org/current/userguide/dependency_locking.html
  ## https://docs.gradle.org/current/userguide/dependency_verification.html
  for candidate in ["build.gradle.kts", "build.gradle",
                    "settings.gradle.kts", "settings.gradle",
                    "gradle.properties", "gradle.lockfile",
                    "settings-gradle.lockfile", "buildscript-gradle.lockfile",
                    "gradle" / "verification-metadata.xml",
                    "gradle" / "verification-keyring.keys",
                    "gradle" / "verification-keyring.gpg"]:
    let path = projectRoot / candidate
    if fileExists(extendedPath(path)):
      result.add(path)
  let catalogDir = projectRoot / "gradle"
  if dirExists(extendedPath(catalogDir)):
    var catalogs: seq[string] = @[]
    for entry in walkDir(catalogDir):
      if entry.kind == pcFile and entry.path.endsWith(".versions.toml"):
        catalogs.add(entry.path)
    catalogs.sort(system.cmp[string])
    result.add(catalogs)

proc gradleWrapperInputs(projectRoot: string): seq[string] =
  ## A wrapper project's wrapper: the scripts, the jar and the properties
  ## naming (and, with ``distributionSha256Sum``, pinning) the distribution.
  ## https://docs.gradle.org/current/userguide/gradle_wrapper.html
  for candidate in ["gradlew", "gradlew.bat",
                    "gradle" / "wrapper" / "gradle-wrapper.jar",
                    "gradle" / "wrapper" / "gradle-wrapper.properties"]:
    let path = projectRoot / candidate
    if fileExists(extendedPath(path)):
      result.add(path)

proc collectGradleInputs(projectRoot: string): seq[string] =
  ## Conservative input enumeration for the build action: every
  ## file `gradleConfigurationInputs` names plus every ``.kt`` /
  ## ``.java`` file under ``src/main/``. Test sources under
  ## ``src/test/`` are excluded (M41 ships ``gradle build`` only;
  ## ``gradle test`` discovery is deferred). Resource files under
  ## ``src/main/resources/`` are NOT enumerated — they don't typically
  ## invalidate the produced jar for the minimal-stdlib fixture, and a
  ## follow-up M can lift them when test-discovery lands.
  if not dirExists(extendedPath(projectRoot)):
    return @[]
  result.add(gradleConfigurationInputs(projectRoot))
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

proc edgeScratchDir(projectRoot, edge: string): string =
  ## One edge's scratch directory under the convention's ``.repro/build``
  ## (a `BuildActionDef.scratchDirs` entry, emptied before the edge runs):
  ## Gradle's project cache (``--project-cache-dir``, normally
  ## ``<root>/.gradle``) at ``project-cache/`` and its ``GRADLE_USER_HOME``
  ## at ``user-home/``. The build leaves nothing in the project that its
  ## declared outputs do not account for, and nothing in the host's
  ## ``~/.gradle``.
  projectRoot / ScratchDirName / ConventionName / edge

proc dependenciesDir(projectRoot: string): string =
  ## The dependency fetch's state: its private user home, the read-only
  ## cache it exports, the wrapper distribution and its stamp
  ## (`output_discovery.gradleDependencies`).
  projectRoot / ScratchDirName / ConventionName / "dependencies"

type GradleLauncher = object
  ## Which Gradle each edge runs. The fetch runs the project's wrapper when
  ## it ships one, so the wrapper downloads and verifies the distribution it
  ## pins; the offline edges then run that distribution from the fetch's
  ## export, never the wrapper, which would download it again into their
  ## empty user home. Without a wrapper every edge runs the ``gradle`` on
  ## PATH.
  fetchExe: string
  offlineExe: string
  wrapper: bool

proc gradleLauncher(projectRoot, gradleExe: string): GradleLauncher =
  let wrapper = gradleWrapperPath(projectRoot)
  if wrapper.len > 0 and gradleExe == wrapper and
      fileExists(extendedPath(gradleWrapperProperties(projectRoot))):
    GradleLauncher(fetchExe: wrapper, wrapper: true,
      offlineExe: gradleDistributionLauncher(dependenciesDir(projectRoot)))
  else:
    GradleLauncher(fetchExe: gradleExe, offlineExe: gradleExe, wrapper: false)

proc emitDependenciesAction(projectRoot: string; launcher: GradleLauncher):
    BuildActionDef =
  ## The ``kotlin-gradle-dependencies`` edge: the one Gradle invocation that
  ## may reach the network. It resolves every configuration into a private
  ## user home and exports that home's ``modules-2`` as the read-only cache
  ## the offline edges read (Language-Conventions/Kotlin.md §"Dependencies:
  ## a fetch edge and an isolated user home").
  ##
  ## Never cached, because it reaches the network (like `npm_vendor` and
  ## `cargo_vendor`); its stamp keeps a re-run with unchanged inputs from
  ## starting Gradle. With a committed ``gradle/verification-metadata.xml``
  ## that pins every artifact by checksum (`gradleVerificationPinsChecksums`)
  ## -- and, for a wrapper project, a ``distributionSha256Sum`` -- every
  ## module and distribution it can fetch is pinned by a checksum Gradle
  ## verifies, so it is a fixed-output action (Cache-Scope P3.4).
  let root = dependenciesDir(projectRoot)
  let scratch = edgeScratchDir(projectRoot, "dependencies-fetch")
  var inputs = gradleConfigurationInputs(projectRoot)
  if launcher.wrapper:
    inputs.add(gradleWrapperInputs(projectRoot))
  let verified = gradleVerificationPinsChecksums(projectRoot) and
    (not launcher.wrapper or gradleWrapperIsVerified(projectRoot))
  buildAction(
    id = DependenciesActionId,
    call = inlineExecCall(gradleDependenciesCommand(projectRoot,
      launcher.fetchExe, launcher.wrapper, root, scratch, inputs), projectRoot),
    inputs = inputs,
    outputs = @[gradleDependenciesStamp(root)],
    declaredOutputs = @[root],
    fixedOutput = verified,
    pool = "fetch",
    cacheable = false,
    dependencyPolicy = automaticMonitorPolicy(),
    commandStatsId = "kotlin-gradle.dependencies",
    scratchDirs = @[scratch])

proc emitBuildAction(projectRoot, gradleExe, fragment, discoveryId,
                     stamp: string): BuildActionDef =
  ## Emit the single ``gradle build --offline --no-daemon -q`` action. Its
  ## outputs are the ones ``kotlin-gradle-outputs`` discovered: the build
  ## directory as an opaque output tree and the jar inside it as an
  ## obligatory output.
  ##
  ## ``--offline`` enforces the M41 hermetic contract: Gradle MUST NOT
  ## reach the network during the action. ``--no-daemon`` enforces the
  ## per-action JVM lifecycle — Gradle daemons mutate global state
  ## across builds. ``-q`` (quiet) keeps the per-action logs readable —
  ## Gradle's default lifecycle chatter is extremely verbose.
  ##
  ## Its ``GRADLE_USER_HOME`` is its own scratch ``user-home``, empty when
  ## Gradle starts, and every module comes from the fetch edge's read-only
  ## cache (`output_discovery.gradleIsolationEnv`): what the build reads
  ## there keys it, and what Gradle writes in its user home is neither an
  ## input nor an output.
  let scratch = edgeScratchDir(projectRoot, "build")
  let argv = @[gradleExe, "build"] & @GradleOfflineFlags &
    gradleUserHomeArgs(scratch / "user-home") &
    @["--project-cache-dir", scratch / "project-cache"]
  let inputs = collectGradleInputs(projectRoot) & @[stamp, fragment]
  buildAction(
    id = BuildActionId,
    call = inlineExecCall(argv, projectRoot),
    deps = @[discoveryId, DependenciesActionId],
    inputs = inputs,
    outputs = @[],
    dynamicDepsFile = fragment,
    pool = "compile",
    # ``gradle`` spawns a fan-out of task processes (compileKotlin,
    # compileJava, processResources, jar, etc.); the monitor records their
    # real read-set on top of the enumerated build scripts and sources.
    dependencyPolicy = automaticMonitorPolicy(),
    commandStatsId = "kotlin-gradle.build",
    env = gradleIsolationEnv(scratch / "user-home",
      gradleReadOnlyCache(dependenciesDir(projectRoot))),
    scratchDirs = @[scratch])

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
    let pkg = syntheticPackage(projectRoot, members)
    let registerAll = proc() =
      discard buildPool("compile", 8'u32)
      discard buildPool("fetch", 2'u32)
      let launcher = gradleLauncher(projectRoot, gradleExe)
      let dependencies = emitDependenciesAction(projectRoot, launcher)
      let stamp = gradleDependenciesStamp(dependenciesDir(projectRoot))
      let discoveryScratch = edgeScratchDir(projectRoot, "outputs")
      let discovery = delegatedOutputsAction(ConventionName, "gradle",
        BuildActionId, projectRoot, launcher.offlineExe,
        inputs = gradleConfigurationInputs(projectRoot) & @[stamp],
        extra = @[discoveryScratch,
          gradleReadOnlyCache(dependenciesDir(projectRoot))],
        scratchDirs = @[discoveryScratch],
        deps = @[DependenciesActionId])
      let buildAct = emitBuildAction(projectRoot, launcher.offlineExe,
        discovery.fragment, discovery.action.id, stamp)
      defaultTarget(target("default",
        @[dependencies, discovery.action, buildAct]))
    result = buildPackageFragment(pkg, request, registerAll,
      includeDefault = false)

proc kotlinGradleConvention*(): LanguageConvention =
  ## The single value the standard provider binary registers at startup.
  LanguageConvention(
    name: "kotlin-gradle",
    recognize: kotlinGradleRecognize,
    emitFragment: kotlinGradleEmitFragment)
