## M41 verification: Kotlin + Gradle (Tier 2b) language convention.
##
## Tests against the in-tree fixture under
## ``reprobuild-examples/kotlin-gradle/hello-binary/`` plus scratch
## projects materialised in the test's temp directory.
##
## Coverage:
##   * ``recognize`` returns true for the hello-binary fixture when:
##     - gradle is on PATH (or gradlew is at the project root)
##     - javac is on PATH
##   * ``recognize`` returns true for an alternate Groovy DSL scratch
##     project (``build.gradle`` instead of ``build.gradle.kts``).
##   * ``recognize`` returns false when:
##     - both ``build.gradle.kts`` and ``build.gradle`` are absent
##     - ``pom.xml`` is present at the root (Maven's territory —
##       defensive bidirectional rejection; M40's job)
##     - ``uses:`` doesn't list gradle/kotlin AND java/jdk
##     - no executable / library member is declared
##   * ``emitFragment`` against the hello-binary fixture (skipped when
##     toolchain is missing):
##     - the convention emits a ``kotlin-gradle-outputs`` discovery
##       action and a single ``kotlin-gradle-build`` action.
##     - the build action's argv carries ``gradle build --offline
##       --no-daemon -q``.
##     - the build action declares no outputs of its own: it loads the
##       discovery fragment, which is one of its inputs.
##     - a ``kotlin-gradle-dependencies`` fetch edge (never cached, pool
##       ``fetch``) precedes discovery and the build, and the build's
##       ``GRADLE_USER_HOME`` lies in its own scratch directory, with the
##       fetch's export as ``GRADLE_RO_DEP_CACHE`` (Kotlin.md
##       §"Dependencies: a fetch edge and an isolated user home").
##   * Where Gradle puts the jar (default layout, ``archiveBaseName`` /
##     ``archiveVersion``, the build directory) is checked by real builds
##     in ``test_delegated_build_outputs.nim``.

import std/[os, strutils, tempfiles, unittest]
import repro_test_support/reasoned_skip
import repro_test_support

import repro_core
import repro_provider_runtime
import repro_project_dsl
import repro_standard_provider/convention
import repro_standard_provider/conventions/kotlin_gradle as gradle_convention
from repro_standard_provider/conventions/output_discovery import
  gradleVerificationPinsChecksums

let
  ## parentDir four times from
  ## ``libs/repro_standard_provider/tests/test_kotlin_gradle_convention.nim``
  ## lands at the ``reprobuild/`` repo root; one more parent gets to the
  ## sibling ``reprobuild-examples`` checkout.
  ReprobuildRoot = currentSourcePath.parentDir.parentDir.parentDir.parentDir
  MetacraftRoot = workspaceRootForRepo(ReprobuildRoot)
  HelloBinaryFixture =
    MetacraftRoot / "reprobuild-examples" / "kotlin-gradle" / "hello-binary"

proc dummyRequest(projectRoot: string): ProviderGraphRequest =
  ProviderGraphRequest(
    kind: prkGraphInvocation,
    providerArtifactId: "test-provider",
    entryPointId: "standardProvider.root",
    entryPointBodyHash: "test-body-hash",
    reason: girExplicitUserRequest,
    arguments: projectRoot,
    namespace: "project")

proc inlineArgvOf(action: BuildActionDef): seq[string] =
  for arg in action.call.arguments:
    if arg.name == "argv":
      if arg.encodedValue.len == 0:
        return @[]
      return arg.encodedValue.split("\x1f")
  @[]

proc gradleToolchainReady(projectRoot: string): bool =
  ## True when gradle (system or project wrapper) + javac are both
  ## available. The convention's ``recognize`` enforces both; the test's
  ## emit-fragment branch SKIPs when either is missing.
  if findExe("javac").len == 0:
    return false
  if findExe("gradle").len == 0:
    when defined(windows):
      if not fileExists(projectRoot / "gradlew.bat") and
          not fileExists(projectRoot / "gradlew"):
        return false
    else:
      if not fileExists(projectRoot / "gradlew") and
          not fileExists(projectRoot / "gradlew.bat"):
        return false
  true

suite "kotlin-gradle convention M41":

  test "recognize: positive — hello-binary fixture (toolchain-gated)":
    let conv = gradle_convention.kotlinGradleConvention()
    check conv.name == "kotlin-gradle"
    if not fileExists(HelloBinaryFixture / "build.gradle.kts"):
      checkpoint "fixture missing — looked at " & HelloBinaryFixture
      fail()
    let request = dummyRequest(HelloBinaryFixture)
    if gradleToolchainReady(HelloBinaryFixture):
      check conv.recognize(HelloBinaryFixture, request)
    else:
      checkpoint "gradle/javac toolchain unavailable — recognize must be false"
      check not conv.recognize(HelloBinaryFixture, request)

  test "recognize: positive — scratch Groovy DSL build.gradle":
    if findExe("javac").len == 0 or findExe("gradle").len == 0:
      skip("javac or gradle not on PATH")
    else:
      let scratch = getTempDir() / "test_kotlin_gradle_convention_groovy_dsl"
      if dirExists(scratch):
        removeDir(scratch)
      createDir(scratch)
      createDir(scratch / "src" / "main" / "kotlin")
      writeFile(scratch / "src" / "main" / "kotlin" / "Hello.kt",
        "fun main() { println(\"hi\") }\n")
      writeFile(scratch / "build.gradle",
        "plugins { id 'org.jetbrains.kotlin.jvm' version '1.9.25' }\n" &
        "version = '1.0'\n")
      writeFile(scratch / "settings.gradle",
        "rootProject.name = 'groovy_proj'\n")
      writeFile(scratch / "reprobuild.nim",
        "import repro_project_dsl\n" &
        "package fakeGradleGroovy:\n" &
        "  uses:\n" &
        "    \"java >=21\"\n" &
        "    \"gradle >=8\"\n" &
        "\n" &
        "  executable hello:\n" &
        "    discard\n")
      defer:
        removeDir(scratch)
      let conv = gradle_convention.kotlinGradleConvention()
      let request = dummyRequest(scratch)
      check conv.recognize(scratch, request)

  test "recognize: negative — neither build.gradle nor build.gradle.kts":
    let scratch = getTempDir() / "test_kotlin_gradle_convention_no_gradle"
    if dirExists(scratch):
      removeDir(scratch)
    createDir(scratch)
    createDir(scratch / "src" / "main" / "kotlin")
    writeFile(scratch / "src" / "main" / "kotlin" / "Hello.kt",
      "fun main() { println(\"hi\") }\n")
    writeFile(scratch / "reprobuild.nim",
      "import repro_project_dsl\n" &
      "package fakeGradleNoBuild:\n" &
      "  uses:\n" &
      "    \"java >=21\"\n" &
      "    \"gradle >=8\"\n" &
      "\n" &
      "  executable hello:\n" &
      "    discard\n")
    defer:
      removeDir(scratch)
    let conv = gradle_convention.kotlinGradleConvention()
    let request = dummyRequest(scratch)
    check not conv.recognize(scratch, request)

  test "recognize: negative — pom.xml at root (Maven's territory)":
    let scratch = getTempDir() / "test_kotlin_gradle_convention_pom_present"
    if dirExists(scratch):
      removeDir(scratch)
    createDir(scratch)
    createDir(scratch / "src" / "main" / "kotlin")
    writeFile(scratch / "src" / "main" / "kotlin" / "Hello.kt",
      "fun main() { println(\"hi\") }\n")
    writeFile(scratch / "build.gradle.kts",
      "plugins { kotlin(\"jvm\") version \"1.9.25\" }\n" &
      "version = \"1.0\"\n")
    writeFile(scratch / "settings.gradle.kts",
      "rootProject.name = \"hello\"\n")
    writeFile(scratch / "pom.xml",
      "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" &
      "<project xmlns=\"http://maven.apache.org/POM/4.0.0\">\n" &
      "  <modelVersion>4.0.0</modelVersion>\n" &
      "  <groupId>com.example</groupId>\n" &
      "  <artifactId>hello</artifactId>\n" &
      "  <version>1.0</version>\n" &
      "</project>\n")
    writeFile(scratch / "reprobuild.nim",
      "import repro_project_dsl\n" &
      "package fakeGradleMavenBoth:\n" &
      "  uses:\n" &
      "    \"java >=21\"\n" &
      "    \"gradle >=8\"\n" &
      "    \"mvn >=3.9\"\n" &
      "\n" &
      "  executable hello:\n" &
      "    discard\n")
    defer:
      removeDir(scratch)
    let conv = gradle_convention.kotlinGradleConvention()
    let request = dummyRequest(scratch)
    check not conv.recognize(scratch, request)

  test "recognize: negative — uses lacks gradle/kotlin":
    let scratch = getTempDir() / "test_kotlin_gradle_convention_no_gradle_in_uses"
    if dirExists(scratch):
      removeDir(scratch)
    createDir(scratch)
    createDir(scratch / "src" / "main" / "kotlin")
    writeFile(scratch / "src" / "main" / "kotlin" / "Hello.kt",
      "fun main() { println(\"hi\") }\n")
    writeFile(scratch / "build.gradle.kts",
      "plugins { kotlin(\"jvm\") version \"1.9.25\" }\n" &
      "version = \"1.0\"\n")
    writeFile(scratch / "settings.gradle.kts",
      "rootProject.name = \"hello\"\n")
    writeFile(scratch / "reprobuild.nim",
      "import repro_project_dsl\n" &
      "package fakeGradleNoGradleInUses:\n" &
      "  uses:\n" &
      "    \"java >=21\"\n" &
      "\n" &
      "  executable hello:\n" &
      "    discard\n")
    defer:
      removeDir(scratch)
    let conv = gradle_convention.kotlinGradleConvention()
    let request = dummyRequest(scratch)
    check not conv.recognize(scratch, request)

  test "recognize: negative — uses lacks java/jdk":
    let scratch = getTempDir() / "test_kotlin_gradle_convention_no_java_in_uses"
    if dirExists(scratch):
      removeDir(scratch)
    createDir(scratch)
    createDir(scratch / "src" / "main" / "kotlin")
    writeFile(scratch / "src" / "main" / "kotlin" / "Hello.kt",
      "fun main() { println(\"hi\") }\n")
    writeFile(scratch / "build.gradle.kts",
      "plugins { kotlin(\"jvm\") version \"1.9.25\" }\n" &
      "version = \"1.0\"\n")
    writeFile(scratch / "settings.gradle.kts",
      "rootProject.name = \"hello\"\n")
    writeFile(scratch / "reprobuild.nim",
      "import repro_project_dsl\n" &
      "package fakeGradleNoJavaInUses:\n" &
      "  uses:\n" &
      "    \"gradle >=8\"\n" &
      "\n" &
      "  executable hello:\n" &
      "    discard\n")
    defer:
      removeDir(scratch)
    let conv = gradle_convention.kotlinGradleConvention()
    let request = dummyRequest(scratch)
    check not conv.recognize(scratch, request)

  test "recognize: negative — no member declared":
    let scratch = getTempDir() / "test_kotlin_gradle_convention_no_member"
    if dirExists(scratch):
      removeDir(scratch)
    createDir(scratch)
    createDir(scratch / "src" / "main" / "kotlin")
    writeFile(scratch / "src" / "main" / "kotlin" / "Hello.kt",
      "fun main() { println(\"hi\") }\n")
    writeFile(scratch / "build.gradle.kts",
      "plugins { kotlin(\"jvm\") version \"1.9.25\" }\n" &
      "version = \"1.0\"\n")
    writeFile(scratch / "settings.gradle.kts",
      "rootProject.name = \"hello\"\n")
    writeFile(scratch / "reprobuild.nim",
      "import repro_project_dsl\n" &
      "package fakeGradleNoMember:\n" &
      "  uses:\n" &
      "    \"java >=21\"\n" &
      "    \"gradle >=8\"\n")
    defer:
      removeDir(scratch)
    let conv = gradle_convention.kotlinGradleConvention()
    let request = dummyRequest(scratch)
    check not conv.recognize(scratch, request)

  test "fixed-output: verification metadata must pin every artifact by checksum":
    # Kotlin.md §"Dependencies: a fetch edge and an isolated user home",
    # "Determinism": the fetch is fixed-output only when Gradle's
    # verification metadata lets no artifact through without a checksum.
    let root = createTempDir("repro-gradle-verification-", "")
    defer: removeDir(root)
    check not gradleVerificationPinsChecksums(root)
    createDir(root / "gradle")
    proc metadata(configuration, components: string): string =
      "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" &
        "<verification-metadata xmlns=\"https://schema.gradle.org/dependency-verification\">\n" &
        "   <configuration>\n" & configuration & "   </configuration>\n" &
        "   <components>\n" & components & "   </components>\n" &
        "</verification-metadata>\n"
    const Pinned = "      <component group=\"com.google.code.gson\" name=\"gson\" version=\"2.10.1\">\n" &
      "         <artifact name=\"gson-2.10.1.jar\">\n" &
      "            <sha256 value=\"4241c14a7727c34feea6507ec801318a3d4a90f070e4525681079fb94ee4c593\" origin=\"Generated by Gradle\"/>\n" &
      "         </artifact>\n      </component>\n"
    const Strict = "      <verify-metadata>true</verify-metadata>\n" &
      "      <verify-signatures>false</verify-signatures>\n"
    let file = root / "gradle" / "verification-metadata.xml"
    # What ``--write-verification-metadata sha256`` writes: fixed-output.
    writeFile(file, metadata(Strict, Pinned))
    check gradleVerificationPinsChecksums(root)
    # Signatures may stand in for checksums.
    writeFile(file, metadata("      <verify-metadata>true</verify-metadata>\n" &
      "      <verify-signatures>true</verify-signatures>\n", Pinned))
    check not gradleVerificationPinsChecksums(root)
    # Exempted artifacts.
    writeFile(file, metadata(Strict & "      <trusted-artifacts>\n" &
      "         <trust group=\"com.example\"/>\n      </trusted-artifacts>\n", Pinned))
    check not gradleVerificationPinsChecksums(root)
    # Unchecked module metadata.
    writeFile(file, metadata("      <verify-metadata>false</verify-metadata>\n", Pinned))
    check not gradleVerificationPinsChecksums(root)
    # No components element: nothing is listed.
    writeFile(file, "<verification-metadata/>\n")
    check not gradleVerificationPinsChecksums(root)

  test "emitFragment: hello-binary fixture produces a single build action":
    if not gradleToolchainReady(HelloBinaryFixture):
      skip("javac not on PATH, or neither gradle nor a gradlew wrapper in reprobuild-examples/kotlin-gradle/hello-binary")
    else:
      let conv = gradle_convention.kotlinGradleConvention()
      let request = dummyRequest(HelloBinaryFixture)
      require conv.recognize(HelloBinaryFixture, request)
      let fragment = conv.emitFragment(HelloBinaryFixture, request)

      var buildActions: seq[BuildActionDef] = @[]
      for node in fragment.nodes:
        if node.kind != gnkAction:
          continue
        let action = decodeBuildActionPayload(toBytes(node.payload))
        if action.id == "kotlin-gradle-build":
          buildActions.add(action)

      check buildActions.len == 1
      let buildAct = buildActions[0]
      check buildAct.pool == "compile"

      # argv carries: gradle, "build", "--offline", "--no-daemon", "-q"
      let argv = inlineArgvOf(buildAct)
      var sawBuildVerb = false
      var sawOfflineFlag = false
      var sawNoDaemonFlag = false
      for token in argv:
        if token == "build": sawBuildVerb = true
        elif token == "--offline": sawOfflineFlag = true
        elif token == "--no-daemon": sawNoDaemonFlag = true
      check sawBuildVerb
      check sawOfflineFlag
      check sawNoDaemonFlag

      # The build edge's outputs are discovered, not predicted
      # (Build-Engine-And-Scheduler.md §"Outputs a delegated build
      # decides"): it declares none itself, loads the fragment its
      # discovery edge writes, and is keyed on it. Real builds of the
      # default layout and of the overrides are in
      # test_delegated_build_outputs.nim.
      check buildAct.outputs.len == 0
      check buildAct.dynamicDepsFile.replace('\\', '/').endsWith(
        "/.repro/build/kotlin-gradle-outputs.dyndep")
      check buildAct.dynamicDepsFile in buildAct.inputs
      check "kotlin-gradle-outputs" in buildAct.deps

      # Kotlin.md §"Dependencies: a fetch edge and an isolated user home":
      # the build's GRADLE_USER_HOME is inside one of its own scratch
      # directories (emptied before it runs), and its modules come from the
      # fetch edge's read-only cache.
      proc unified(path: string): string = path.replace('\\', '/')
      var userHome = ""
      var readOnlyCache = ""
      for (name, value) in buildAct.env:
        if name == "GRADLE_USER_HOME": userHome = value
        elif name == "GRADLE_RO_DEP_CACHE": readOnlyCache = value
      checkpoint "GRADLE_USER_HOME=" & userHome
      check userHome.len > 0
      var ownedHome = false
      for dir in buildAct.scratchDirs:
        if userHome.unified.startsWith(dir.unified & "/"):
          ownedHome = true
      check ownedHome
      # The command line names the same home: it outranks a host's
      # ``gradle.user.home`` system property (``GRADLE_OPTS``), which in turn
      # outranks the variable.
      let buildArgv = inlineArgvOf(buildAct)
      let homeFlag = buildArgv.find("--gradle-user-home")
      check homeFlag >= 0
      check homeFlag + 1 < buildArgv.len and buildArgv[homeFlag + 1] == userHome
      check readOnlyCache.unified.endsWith(
        "/.repro/build/kotlin-gradle/dependencies/read-only-cache")
      check "kotlin-gradle-dependencies" in buildAct.deps

      var sawDiscovery = false
      var sawDependencies = false
      for node in fragment.nodes:
        if node.kind != gnkAction:
          continue
        let action = decodeBuildActionPayload(toBytes(node.payload))
        if action.id == "kotlin-gradle-outputs":
          sawDiscovery = true
          check action.outputs == @[buildAct.dynamicDepsFile]
          check "--delegated-outputs" in inlineArgvOf(action)
          check "kotlin-gradle-dependencies" in action.deps
          check readOnlyCache in inlineArgvOf(action)
        elif action.id == "kotlin-gradle-dependencies":
          # The only edge that reaches the network: never cached, in the
          # fetch pool, its stamp the declared output.
          sawDependencies = true
          check not action.cacheable
          check action.pool == "fetch"
          check action.outputs.len == 1
          check action.outputs[0].unified.endsWith(
            "/.repro/build/kotlin-gradle/dependencies/dependencies.stamp")
          check action.outputs[0] in buildAct.inputs
          check "--gradle-dependencies" in inlineArgvOf(action)
          check (HelloBinaryFixture / "build.gradle.kts") in action.inputs
          # The fixture commits no verification metadata: its fetch is not
          # pinned by checksums, so it is not fixed-output.
          check not action.fixedOutput
      check sawDiscovery
      check sawDependencies
