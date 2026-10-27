## M40 verification: Java + Maven (Tier 2b) language convention.
##
## Tests against the in-tree fixture under
## ``reprobuild-examples/java-maven/hello-binary/`` plus scratch
## projects materialised in the test's temp directory.
##
## Coverage:
##   * ``recognize`` returns true for the hello-binary fixture when:
##     - mvn is on PATH
##     - javac is on PATH
##   * ``recognize`` returns false when:
##     - ``pom.xml`` is absent
##     - ``build.gradle`` is present at the root (Gradle's territory —
##       defensive bidirectional rejection; M41's job)
##     - ``uses:`` doesn't list mvn/maven AND java/jdk
##     - no executable / library member is declared
##   * ``emitFragment`` against the hello-binary fixture (skipped when
##     toolchain is missing):
##     - the convention emits a ``java-maven-outputs`` discovery action
##       and a single ``java-maven-package`` action.
##     - the package action's argv carries ``mvn package -o`` plus a
##       ``-f`` flag pointing at the pom.
##     - the package action declares no outputs of its own: it loads the
##       discovery fragment, which is one of its inputs.
##   * Where Maven puts the jar (default layout, ``<finalName>``,
##     ``<directory>``, an inherited version) is checked by real builds in
##     ``test_delegated_build_outputs.nim``.

import std/[os, strutils, unittest]
import repro_test_support/reasoned_skip
import repro_test_support

import repro_core
import repro_provider_runtime
import repro_project_dsl
import repro_standard_provider/convention
import repro_standard_provider/conventions/java_maven as maven_convention

let
  ## parentDir four times from
  ## ``libs/repro_standard_provider/tests/test_java_maven_convention.nim``
  ## lands at the ``reprobuild/`` repo root; one more parent gets to the
  ## sibling ``reprobuild-examples`` checkout.
  ReprobuildRoot = currentSourcePath.parentDir.parentDir.parentDir.parentDir
  MetacraftRoot = workspaceRootForRepo(ReprobuildRoot)
  HelloBinaryFixture =
    MetacraftRoot / "reprobuild-examples" / "java-maven" / "hello-binary"

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

proc mavenToolchainReady(): bool =
  ## True when mvn + javac are both on PATH. The convention's
  ## ``recognize`` enforces both; the test's emit-fragment branch
  ## SKIPs when either is missing.
  if findExe("mvn").len == 0:
    return false
  if findExe("javac").len == 0:
    return false
  true

suite "java-maven convention M40":

  test "recognize: positive — hello-binary fixture (toolchain-gated)":
    let conv = maven_convention.javaMavenConvention()
    check conv.name == "java-maven"
    if not fileExists(HelloBinaryFixture / "pom.xml"):
      checkpoint "fixture missing — looked at " & HelloBinaryFixture
      fail()
    let request = dummyRequest(HelloBinaryFixture)
    if mavenToolchainReady():
      check conv.recognize(HelloBinaryFixture, request)
    else:
      checkpoint "maven toolchain unavailable — recognize must be false"
      check not conv.recognize(HelloBinaryFixture, request)

  test "recognize: negative — pom.xml missing":
    let scratch = getTempDir() / "test_java_maven_convention_no_pom"
    if dirExists(scratch):
      removeDir(scratch)
    createDir(scratch)
    createDir(scratch / "src" / "main" / "java" / "com" / "example")
    writeFile(scratch / "src" / "main" / "java" / "com" / "example" /
      "Hello.java",
      "package com.example;\npublic class Hello { " &
        "public static void main(String[] args) { " &
        "System.out.println(\"hi\"); } }\n")
    writeFile(scratch / "reprobuild.nim",
      "import repro_project_dsl\n" &
      "package fakeMavenNoPom:\n" &
      "  uses:\n" &
      "    \"java >=21\"\n" &
      "    \"mvn >=3.9\"\n" &
      "\n" &
      "  executable hello:\n" &
      "    discard\n")
    defer:
      removeDir(scratch)
    let conv = maven_convention.javaMavenConvention()
    let request = dummyRequest(scratch)
    check not conv.recognize(scratch, request)

  test "recognize: negative — build.gradle at root (Gradle's territory)":
    let scratch = getTempDir() / "test_java_maven_convention_gradle_present"
    if dirExists(scratch):
      removeDir(scratch)
    createDir(scratch)
    createDir(scratch / "src" / "main" / "java")
    writeFile(scratch / "src" / "main" / "java" / "Hello.java",
      "public class Hello { " &
        "public static void main(String[] args) { " &
        "System.out.println(\"hi\"); } }\n")
    writeFile(scratch / "pom.xml",
      "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" &
      "<project xmlns=\"http://maven.apache.org/POM/4.0.0\">\n" &
      "  <modelVersion>4.0.0</modelVersion>\n" &
      "  <groupId>com.example</groupId>\n" &
      "  <artifactId>hello</artifactId>\n" &
      "  <version>1.0</version>\n" &
      "</project>\n")
    writeFile(scratch / "build.gradle",
      "plugins { id 'application' }\n")
    writeFile(scratch / "reprobuild.nim",
      "import repro_project_dsl\n" &
      "package fakeMavenGradle:\n" &
      "  uses:\n" &
      "    \"java >=21\"\n" &
      "    \"mvn >=3.9\"\n" &
      "    \"gradle >=8\"\n" &
      "\n" &
      "  executable hello:\n" &
      "    discard\n")
    defer:
      removeDir(scratch)
    let conv = maven_convention.javaMavenConvention()
    let request = dummyRequest(scratch)
    check not conv.recognize(scratch, request)

  test "recognize: negative — uses lacks maven":
    let scratch = getTempDir() / "test_java_maven_convention_no_mvn_in_uses"
    if dirExists(scratch):
      removeDir(scratch)
    createDir(scratch)
    createDir(scratch / "src" / "main" / "java")
    writeFile(scratch / "src" / "main" / "java" / "Hello.java",
      "public class Hello { " &
        "public static void main(String[] args) { " &
        "System.out.println(\"hi\"); } }\n")
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
      "package fakeMavenNoMvnInUses:\n" &
      "  uses:\n" &
      "    \"java >=21\"\n" &
      "\n" &
      "  executable hello:\n" &
      "    discard\n")
    defer:
      removeDir(scratch)
    let conv = maven_convention.javaMavenConvention()
    let request = dummyRequest(scratch)
    check not conv.recognize(scratch, request)

  test "recognize: negative — uses lacks java":
    let scratch = getTempDir() / "test_java_maven_convention_no_java_in_uses"
    if dirExists(scratch):
      removeDir(scratch)
    createDir(scratch)
    createDir(scratch / "src" / "main" / "java")
    writeFile(scratch / "src" / "main" / "java" / "Hello.java",
      "public class Hello { " &
        "public static void main(String[] args) { " &
        "System.out.println(\"hi\"); } }\n")
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
      "package fakeMavenNoJavaInUses:\n" &
      "  uses:\n" &
      "    \"mvn >=3.9\"\n" &
      "\n" &
      "  executable hello:\n" &
      "    discard\n")
    defer:
      removeDir(scratch)
    let conv = maven_convention.javaMavenConvention()
    let request = dummyRequest(scratch)
    check not conv.recognize(scratch, request)

  test "recognize: negative — no member declared":
    let scratch = getTempDir() / "test_java_maven_convention_no_member"
    if dirExists(scratch):
      removeDir(scratch)
    createDir(scratch)
    createDir(scratch / "src" / "main" / "java")
    writeFile(scratch / "src" / "main" / "java" / "Hello.java",
      "public class Hello { " &
        "public static void main(String[] args) { " &
        "System.out.println(\"hi\"); } }\n")
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
      "package fakeMavenNoMember:\n" &
      "  uses:\n" &
      "    \"java >=21\"\n" &
      "    \"mvn >=3.9\"\n")
    defer:
      removeDir(scratch)
    let conv = maven_convention.javaMavenConvention()
    let request = dummyRequest(scratch)
    check not conv.recognize(scratch, request)

  test "emitFragment: hello-binary fixture produces a single package action":
    if not mavenToolchainReady():
      skip("mvn or javac not on PATH")
    else:
      let conv = maven_convention.javaMavenConvention()
      let request = dummyRequest(HelloBinaryFixture)
      require conv.recognize(HelloBinaryFixture, request)
      let fragment = conv.emitFragment(HelloBinaryFixture, request)

      var packageActions: seq[BuildActionDef] = @[]
      for node in fragment.nodes:
        if node.kind != gnkAction:
          continue
        let action = decodeBuildActionPayload(toBytes(node.payload))
        if action.id == "java-maven-package":
          packageActions.add(action)

      check packageActions.len == 1
      let packageAction = packageActions[0]
      check packageAction.pool == "compile"

      # argv carries: mvn, "package", "-o", "-q", "-f", "<pom>"
      let argv = inlineArgvOf(packageAction)
      var sawPackageVerb = false
      var sawOfflineFlag = false
      var sawFFlag = false
      for token in argv:
        if token == "package": sawPackageVerb = true
        elif token == "-o": sawOfflineFlag = true
        elif token == "-f": sawFFlag = true
      check sawPackageVerb
      check sawOfflineFlag
      check sawFFlag

      # The build edge's outputs are discovered, not predicted
      # (Build-Engine-And-Scheduler.md §"Outputs a delegated build
      # decides"): it declares none itself, loads the fragment its
      # discovery edge writes, and is keyed on it. Real builds of the
      # default layout and of the overrides are in
      # test_delegated_build_outputs.nim.
      check packageAction.outputs.len == 0
      check packageAction.dynamicDepsFile.replace('\\', '/').endsWith(
        "/.repro/build/java-maven-outputs.dyndep")
      check packageAction.dynamicDepsFile in packageAction.inputs
      check "java-maven-outputs" in packageAction.deps
      var sawDiscovery = false
      for node in fragment.nodes:
        if node.kind != gnkAction:
          continue
        let action = decodeBuildActionPayload(toBytes(node.payload))
        if action.id == "java-maven-outputs":
          sawDiscovery = true
          check action.outputs == @[packageAction.dynamicDepsFile]
          check "--delegated-outputs" in inlineArgvOf(action)
      check sawDiscovery
