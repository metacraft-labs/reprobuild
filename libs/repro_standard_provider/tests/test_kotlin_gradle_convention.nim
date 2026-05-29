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
##     - the convention emits a single ``kotlin-gradle-build`` action.
##     - the action's argv carries ``gradle build --offline --no-daemon
##       -q``.
##     - the action's output is
##       ``build/libs/<projectName>-<version>.jar`` under the project
##       root.
##   * Output-path resolution: ``rootProject.name`` (from
##     ``settings.gradle.kts``) and ``version`` (from
##     ``build.gradle.kts``) compose the predicted jar path.

import std/[os, strutils, unittest]

import repro_core
import repro_provider_runtime
import repro_project_dsl
import repro_standard_provider/convention
import repro_standard_provider/conventions/kotlin_gradle as gradle_convention

const
  ## parentDir four times from
  ## ``libs/repro_standard_provider/tests/test_kotlin_gradle_convention.nim``
  ## lands at the ``reprobuild/`` repo root; one more parent gets to the
  ## sibling ``reprobuild-examples`` checkout.
  ReprobuildRoot = currentSourcePath.parentDir.parentDir.parentDir.parentDir
  MetacraftRoot = ReprobuildRoot.parentDir
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
      skip()
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

  test "emitFragment: hello-binary fixture produces a single build action":
    if not gradleToolchainReady(HelloBinaryFixture):
      skip()
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

      # Output is build/libs/<projectName>-<version>.jar under the
      # fixture root. The fixture pins ``rootProject.name = "hello"``
      # plus ``version = "1.0"`` so the jar lands at
      # ``build/libs/hello-1.0.jar``.
      var sawJarOutput = false
      for outPath in buildAct.outputs:
        let unified = outPath.replace('\\', '/')
        if unified.endsWith("/build/libs/hello-1.0.jar"):
          sawJarOutput = true
      check sawJarOutput

  test "output-path resolution: projectName + version compose the jar filename":
    # Scratch project with custom ``rootProject.name`` + ``version`` to
    # exercise the Gradle DSL parser without needing the Gradle toolchain
    # on PATH. ``recognize`` will fail when gradle/javac aren't installed
    # but emit-fragment's output-path branch is independent of that gate;
    # since ``emitFragment`` calls ``gradleExecutable()`` and raises when
    # gradle is missing, this test SKIPs when the toolchain is
    # unavailable.
    if findExe("javac").len == 0 or findExe("gradle").len == 0:
      skip()
    else:
      let scratch = getTempDir() / "test_kotlin_gradle_convention_custom_coords"
      if dirExists(scratch):
        removeDir(scratch)
      createDir(scratch)
      createDir(scratch / "src" / "main" / "kotlin")
      writeFile(scratch / "src" / "main" / "kotlin" / "Main.kt",
        "fun main() { println(\"x\") }\n")
      writeFile(scratch / "build.gradle.kts",
        "plugins { kotlin(\"jvm\") version \"1.9.25\" }\n" &
        "version = \"3.7.1\"\n")
      writeFile(scratch / "settings.gradle.kts",
        "rootProject.name = \"custom-coords\"\n")
      writeFile(scratch / "reprobuild.nim",
        "import repro_project_dsl\n" &
        "package fakeGradleCustomCoords:\n" &
        "  uses:\n" &
        "    \"java >=21\"\n" &
        "    \"gradle >=8\"\n" &
        "\n" &
        "  executable main:\n" &
        "    discard\n")
      defer:
        removeDir(scratch)
      let conv = gradle_convention.kotlinGradleConvention()
      let request = dummyRequest(scratch)
      require conv.recognize(scratch, request)
      let fragment = conv.emitFragment(scratch, request)
      var sawCustomJar = false
      for node in fragment.nodes:
        if node.kind != gnkAction:
          continue
        let action = decodeBuildActionPayload(toBytes(node.payload))
        for outPath in action.outputs:
          let unified = outPath.replace('\\', '/')
          if unified.endsWith("/build/libs/custom-coords-3.7.1.jar"):
            sawCustomJar = true
      check sawCustomJar
