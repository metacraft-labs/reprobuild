## Real Maven, Gradle, Cabal and .NET builds check each convention's
## declared outputs against what the tool writes, for the tool's default
## layout and for the overrides the conventions used to guess wrong:
## Maven's ``<finalName>``, ``<directory>`` and a version inherited from a
## parent POM; Gradle's ``archiveBaseName`` / ``archiveVersion`` and
## ``layout.buildDirectory``; Cabal's ``optimization``; MSBuild's
## ``OutputPath``, ``AssemblyName``, ``RuntimeIdentifier`` and
## ``TargetFrameworks``. A Gradle build that enables the configuration cache
## must answer discovery too.
## Build-Engine-And-Scheduler.md §"Outputs a delegated build decides".
##
## Nothing is mocked. The emitted graph is run the way the engine runs it:
## the discovery edge (this process stands in for the standard-provider
## binary its argv names, through the same ``runOutputDiscoveryCommand``),
## then the fragment is read, its opaque output directories are removed,
## and the build edge's own argv runs with its own environment. Every
## obligatory output, static or discovered, must then exist. A convention
## that predicts a path fails here the way the engine would fail it
## (``declaredOutputsAreObligatory``). The cache-hit restore of the same
## edges, through a real ``repro build``, is
## ``tests/integration/t_delegated_build_outputs_restore.nim``.
##
## Each case runs only where its toolchain is on PATH (a reasoned skip
## otherwise). Maven runs offline, so the pinned ``maven-help-plugin`` must
## be in the local repository (one online ``help:evaluate`` warms it).

import std/[os, osproc, streams, strtabs, strutils, tempfiles, times, unittest]
import repro_test_support/reasoned_skip

import repro_core
import repro_provider_runtime
import repro_project_dsl
import repro_standard_provider/convention
import repro_standard_provider/conventions/output_discovery
import repro_standard_provider/conventions/java_maven as maven_convention
import repro_standard_provider/conventions/kotlin_gradle as gradle_convention
import repro_standard_provider/conventions/haskell_cabal as cabal_convention
import repro_standard_provider/conventions/csharp_dotnet as dotnet_convention

type DeclaredOutputs = object
  ## What a build edge promised, from its static declaration and its
  ## discovered fragment.
  outputs: seq[string]
  opaque: seq[string]

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

proc unified(path: string): string = path.replace('\\', '/')

proc runTool(argv: seq[string]; cwd: string;
             env: openArray[(string, string)] = []): string =
  ## Runs a tool with the current environment plus `env`, failing the test
  ## with its output when it exits non-zero.
  let environment = newStringTable(modeCaseSensitive)
  for key, value in envPairs():
    environment[key] = value
  for (key, value) in env:
    environment[key] = value
  let process = startProcess(argv[0], workingDir = cwd, args = argv[1 .. ^1],
    env = environment, options = {poStdErrToStdOut, poUsePath})
  defer: process.close()
  result = process.outputStream.readToEnd()
  let code = process.waitForExit()
  checkpoint argv.quoteShellCommand() & "\n" & result
  require code == 0

proc readFragment(path: string): DeclaredOutputs =
  for line in readFile(path).splitLines():
    let fields = line.split('\t')
    if fields.len != 3:
      continue
    case fields[0]
    of "output": result.outputs.add(fields[2])
    of "opaque-output": result.opaque.add(fields[2])
    else: discard

proc buildAsTheEngineDoes(conv: LanguageConvention;
                          projectRoot: string): DeclaredOutputs =
  ## Emits the convention's graph for `projectRoot` and runs it in the
  ## engine's order (see the module comment), returning what the build edge
  ## promised. Every promised output is checked to exist afterwards.
  let request = dummyRequest(projectRoot)
  require conv.recognize(projectRoot, request)
  let fragment = conv.emitFragment(projectRoot, request)
  var actions: seq[BuildActionDef] = @[]
  for node in fragment.nodes:
    if node.kind == gnkAction:
      actions.add(decodeBuildActionPayload(toBytes(node.payload)))
  # Discovery first: the build edge depends on it.
  var ordered: seq[BuildActionDef] = @[]
  for action in actions:
    if action.id.endsWith("-outputs"): ordered.add(action)
  for action in actions:
    if not action.id.endsWith("-outputs"): ordered.add(action)
  for action in ordered:
    let argv = inlineArgvOf(action)
    require argv.len > 0
    if argv.len > 1 and argv[1] == "--delegated-outputs":
      check action.outputs.len == 1
      require runOutputDiscoveryCommand(argv[1 .. ^1])
      continue
    for output in action.outputs:
      result.outputs.add(output)
    if action.dynamicDepsFile.len > 0:
      # The fragment keys the edge (Build-Engine-And-Scheduler.md
      # §"Discovery"), and the engine removes the opaque trees first.
      check action.dynamicDepsFile in action.inputs
      let discovered = readFragment(action.dynamicDepsFile)
      result.outputs.add(discovered.outputs)
      result.opaque.add(discovered.opaque)
      for tree in discovered.opaque:
        if dirExists(tree): removeDir(tree)
    discard runTool(argv, projectRoot, action.env)
  require result.outputs.len > 0
  for output in result.outputs:
    checkpoint "declared output " & output
    check fileExists(output)
  for tree in result.opaque:
    checkpoint "opaque output directory " & tree
    check dirExists(tree)
    # Each obligatory product is inside one of the build's trees: a restore
    # of the trees restores the products.
  for output in result.outputs:
    var inside = result.opaque.len == 0
    for tree in result.opaque:
      if output.unified.startsWith(tree.unified & "/"):
        inside = true
    check inside

proc writeProject(root: string; files: openArray[(string, string)]) =
  for (relative, content) in files:
    createDir(parentDir(root / relative))
    writeFile(root / relative, content)

proc reproNim(packageName, uses, member: string): string =
  "import repro_project_dsl\npackage " & packageName & ":\n  uses:\n" & uses &
    "\n  executable " & member & ":\n    discard\n"

# --- toolchain gates --------------------------------------------------------

proc mavenReady(): string =
  ## "" when Maven can run this file's cases, else why not.
  if findExe("mvn").len == 0 or findExe("javac").len == 0:
    return "mvn or javac not on PATH"
  let local = getHomeDir() / ".m2" / "repository" / "org" / "apache" /
    "maven" / "plugins" / "maven-help-plugin" / "3.5.1"
  if not dirExists(local):
    return "maven-help-plugin 3.5.1 is not in the local repository " &
      "(warm it once online: mvn " & MavenHelpEvaluate &
      " -Dexpression=project.version -q -DforceStdout)"
  ""

proc gradleReady(): string =
  if findExe("gradle").len == 0 or findExe("javac").len == 0:
    return "gradle or javac not on PATH"
  ""

proc cabalReady(): string =
  if findExe("cabal").len == 0 or findExe("ghc").len == 0:
    return "cabal or ghc not on PATH"
  ""

proc dotnetReady(): string =
  if findExe("dotnet").len == 0:
    return "dotnet not on PATH"
  ""

# --- fixtures ---------------------------------------------------------------

const MavenUses = "    \"java >=21\"\n    \"mvn >=3.9\"\n"
const JavaHello = "package com.example;\npublic class Hello {\n" &
  "  public static void main(String[] args) { System.out.println(\"hello\"); }\n}\n"

proc mavenPom(artifactId: string; extra = ""; parent = ""): string =
  "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" &
    "<project xmlns=\"http://maven.apache.org/POM/4.0.0\">\n" &
    "  <modelVersion>4.0.0</modelVersion>\n" & parent &
    "  <artifactId>" & artifactId & "</artifactId>\n" & extra &
    "  <properties>\n" &
    "    <maven.compiler.release>17</maven.compiler.release>\n" &
    "    <project.build.sourceEncoding>UTF-8</project.build.sourceEncoding>\n" &
    "  </properties>\n</project>\n"

const GradleUses = "    \"java >=17\"\n    \"gradle >=8\"\n"
const CabalUses = "    \"ghc >=9\"\n    \"cabal >=3.10\"\n"
const DotnetUses = "    \"dotnet >=8\"\n"

proc cabalProject(root: string; projectFile = "") =
  var files = @[
    ("hello.cabal", "cabal-version: 2.4\nname: hello\nversion: 1.0\n" &
      "build-type: Simple\n\nexecutable hello\n  main-is: Main.hs\n" &
      "  hs-source-dirs: app\n  build-depends: base\n" &
      "  default-language: Haskell2010\n"),
    ("app/Main.hs", "main :: IO ()\nmain = putStrLn \"hello\"\n"),
    ("reprobuild.nim", reproNim("cabalOutputs", CabalUses, "hello"))]
  if projectFile.len > 0:
    files.add(("cabal.project", projectFile))
  writeProject(root, files)

proc dotnetProject(root, csprojName, properties: string;
                   frameworks = "<TargetFramework>net8.0</TargetFramework>") =
  writeProject(root, [
    (csprojName & ".csproj", "<Project Sdk=\"Microsoft.NET.Sdk\">\n" &
      "  <PropertyGroup>\n    <OutputType>Exe</OutputType>\n" &
      "    " & frameworks & "\n" &
      "    <RestorePackagesWithLockFile>true</RestorePackagesWithLockFile>\n" &
      properties & "  </PropertyGroup>\n</Project>\n"),
    ("Program.cs", "System.Console.WriteLine(\"hello\");\n"),
    ("reprobuild.nim", reproNim("dotnetOutputs", DotnetUses, csprojName))])
  discard runTool(@["dotnet", "restore", root / (csprojName & ".csproj"),
    "--use-lock-file"], root, DotnetQuietEnvironment)

proc hostRid(): string =
  ## The SDK's RID for this host; its apphost pack ships with the SDK, so a
  ## restore for it needs no download.
  let arch = when hostCPU == "arm64": "arm64" else: "x64"
  when defined(windows): "win-" & arch
  elif defined(macosx): "osx-" & arch
  else: "linux-" & arch

suite "delegated builds declare the outputs the tool writes":

  test "Maven default layout: target/ and <artifactId>-<version>.jar":
    let why = mavenReady()
    if why.len > 0:
      skip(why)
    else:
      let root = createTempDir("repro-maven-default-", "")
      defer: removeDir(root)
      writeProject(root, [
        ("pom.xml", mavenPom("hello", "  <groupId>com.example</groupId>\n" &
          "  <version>1.0</version>\n")),
        ("src/main/java/com/example/Hello.java", JavaHello),
        ("reprobuild.nim", reproNim("mavenOutputs", MavenUses, "hello"))])
      let declared = buildAsTheEngineDoes(maven_convention.javaMavenConvention(), root)
      check declared.outputs.len == 1
      check declared.outputs[0].unified.endsWith("/target/hello-1.0.jar")
      check declared.opaque.len == 1
      check declared.opaque[0].unified.endsWith("/target")

  test "Maven overrides: inherited version, <finalName> and <directory>":
    let why = mavenReady()
    if why.len > 0:
      skip(why)
    else:
      let root = createTempDir("repro-maven-override-", "")
      defer: removeDir(root)
      let project = root / "child"
      # The child has no <version> of its own (the old prediction named
      # `child.jar`), builds into `out/` and names its jar itself.
      writeProject(root, [
        ("parent/pom.xml", "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" &
          "<project xmlns=\"http://maven.apache.org/POM/4.0.0\">\n" &
          "  <modelVersion>4.0.0</modelVersion>\n" &
          "  <groupId>com.example</groupId>\n  <artifactId>parent</artifactId>\n" &
          "  <version>4.2</version>\n  <packaging>pom</packaging>\n</project>\n"),
        ("child/pom.xml", mavenPom("child",
          "  <build>\n    <directory>${project.basedir}/out</directory>\n" &
          "    <finalName>renamed-${project.version}</finalName>\n  </build>\n",
          parent = "  <parent>\n    <groupId>com.example</groupId>\n" &
            "    <artifactId>parent</artifactId>\n    <version>4.2</version>\n" &
            "    <relativePath>../parent/pom.xml</relativePath>\n  </parent>\n")),
        ("child/src/main/java/com/example/Hello.java", JavaHello),
        ("child/reprobuild.nim", reproNim("mavenOverride", MavenUses, "child"))])
      let declared = buildAsTheEngineDoes(maven_convention.javaMavenConvention(), project)
      check declared.outputs.len == 1
      check declared.outputs[0].unified.endsWith("/child/out/renamed-4.2.jar")
      check not dirExists(project / "target")

  test "Maven refuses a pom-packaging project instead of guessing a jar":
    let why = mavenReady()
    if why.len > 0:
      skip(why)
    else:
      let root = createTempDir("repro-maven-pom-", "")
      defer: removeDir(root)
      writeProject(root, [("pom.xml", mavenPom("aggregate",
        "  <groupId>com.example</groupId>\n  <version>1.0</version>\n" &
        "  <packaging>pom</packaging>\n"))])
      expect ValueError:
        discard mavenOutputs(findExe("mvn"), root)

  test "Gradle default layout: build/ and build/libs/<name>-<version>.jar":
    let why = gradleReady()
    if why.len > 0:
      skip(why)
    else:
      let root = createTempDir("repro-gradle-default-", "")
      defer: removeDir(root)
      writeProject(root, [
        ("settings.gradle.kts", "rootProject.name = \"hello\"\n"),
        ("build.gradle.kts", "plugins { java }\nversion = \"1.0\"\n"),
        ("src/main/java/com/example/Hello.java", JavaHello),
        ("reprobuild.nim", reproNim("gradleOutputs", GradleUses, "hello"))])
      let declared = buildAsTheEngineDoes(gradle_convention.kotlinGradleConvention(), root)
      check declared.outputs.len == 1
      check declared.outputs[0].unified.endsWith("/build/libs/hello-1.0.jar")
      check declared.opaque.len == 1
      check declared.opaque[0].unified.endsWith("/build")
      # Gradle's project cache went to the convention's scratch directory.
      check not dirExists(root / ".gradle")

  test "Gradle overrides: archiveBaseName, archiveVersion and the build directory":
    let why = gradleReady()
    if why.len > 0:
      skip(why)
    else:
      let root = createTempDir("repro-gradle-override-", "")
      defer: removeDir(root)
      writeProject(root, [
        ("settings.gradle.kts", "rootProject.name = \"hello\"\n"),
        ("build.gradle.kts", "plugins { java }\nversion = \"1.0\"\n" &
          "layout.buildDirectory = layout.projectDirectory.dir(\"out\")\n" &
          "tasks.jar {\n  archiveBaseName.set(\"renamed\")\n" &
          "  archiveVersion.set(\"9\")\n}\n"),
        ("src/main/java/com/example/Hello.java", JavaHello),
        ("reprobuild.nim", reproNim("gradleOverride", GradleUses, "hello"))])
      let declared = buildAsTheEngineDoes(gradle_convention.kotlinGradleConvention(), root)
      check declared.outputs.len == 1
      check declared.outputs[0].unified.endsWith("/out/libs/renamed-9.jar")
      check not dirExists(root / "build")

  test "Gradle with the configuration cache enabled":
    # A discovery task that reads `Task.project` while it runs is refused by
    # the configuration cache, which then writes its report into the build
    # directory discovery must not touch.
    let why = gradleReady()
    if why.len > 0:
      skip(why)
    else:
      let root = createTempDir("repro-gradle-cc-", "")
      defer: removeDir(root)
      writeProject(root, [
        ("settings.gradle.kts", "rootProject.name = \"hello\"\n"),
        ("build.gradle.kts", "plugins { java }\nversion = \"1.0\"\n"),
        ("gradle.properties", "org.gradle.configuration-cache=true\n"),
        ("src/main/java/com/example/Hello.java", JavaHello),
        ("reprobuild.nim", reproNim("gradleCache", GradleUses, "hello"))])
      let declared = buildAsTheEngineDoes(gradle_convention.kotlinGradleConvention(), root)
      check declared.outputs.len == 1
      check declared.outputs[0].unified.endsWith("/build/libs/hello-1.0.jar")
      check not dirExists(root / "build" / "reports" / "configuration-cache")

  test "Cabal default layout: the executable cabal list-bin names":
    let why = cabalReady()
    if why.len > 0:
      skip(why)
    else:
      let root = createTempDir("repro-cabal-default-", "")
      defer: removeDir(root)
      cabalProject(root)
      let declared = buildAsTheEngineDoes(cabal_convention.haskellCabalConvention(), root)
      check declared.outputs.len == 1
      let exe = when defined(windows): "hello.exe" else: "hello"
      check declared.outputs[0].unified.endsWith("/hello-1.0/x/hello/build/hello/" & exe)
      check declared.opaque.len == 1
      check declared.opaque[0].unified.endsWith("/dist-newstyle")

  test "Cabal override: optimization in cabal.project moves the executable":
    let why = cabalReady()
    if why.len > 0:
      skip(why)
    else:
      let root = createTempDir("repro-cabal-override-", "")
      defer: removeDir(root)
      cabalProject(root, "packages: .\noptimization: 2\n")
      let declared = buildAsTheEngineDoes(cabal_convention.haskellCabalConvention(), root)
      check declared.outputs.len == 1
      let exe = when defined(windows): "hello.exe" else: "hello"
      check declared.outputs[0].unified.endsWith("/x/hello/opt/build/hello/" & exe)

  test ".NET default layout: bin/Release/net8.0 and obj/Release/net8.0":
    let why = dotnetReady()
    if why.len > 0:
      skip(why)
    else:
      let root = createTempDir("repro-dotnet-default-", "")
      defer: removeDir(root)
      dotnetProject(root, "hello", "")
      let declared = buildAsTheEngineDoes(dotnet_convention.csharpDotnetConvention(), root)
      check declared.outputs.len == 1
      check declared.outputs[0].unified.endsWith("/bin/Release/net8.0/hello.dll")
      check declared.opaque.len == 2
      # The apphost is recorded with its tree, whatever this platform names it.
      let apphost = when defined(windows): "hello.exe" else: "hello"
      check fileExists(root / "bin" / "Release" / "net8.0" / apphost)

  test ".NET overrides: OutputPath, AssemblyName and RuntimeIdentifier":
    let why = dotnetReady()
    if why.len > 0:
      skip(why)
    else:
      let root = createTempDir("repro-dotnet-override-", "")
      defer: removeDir(root)
      dotnetProject(root, "hello",
        "    <OutputPath>custom/out/</OutputPath>\n" &
        "    <AssemblyName>renamed</AssemblyName>\n" &
        "    <RuntimeIdentifier>" & hostRid() & "</RuntimeIdentifier>\n" &
        "    <SelfContained>false</SelfContained>\n")
      let declared = buildAsTheEngineDoes(dotnet_convention.csharpDotnetConvention(), root)
      check declared.outputs.len == 1
      check declared.outputs[0].unified.endsWith("/renamed.dll")
      check "/custom/out/" in declared.outputs[0].unified
      check not dirExists(root / "bin" / "Release")

  test ".NET without an apphost: the assembly is still the product":
    let why = dotnetReady()
    if why.len > 0:
      skip(why)
    else:
      let root = createTempDir("repro-dotnet-noapphost-", "")
      defer: removeDir(root)
      dotnetProject(root, "hello", "    <UseAppHost>false</UseAppHost>\n")
      let declared = buildAsTheEngineDoes(dotnet_convention.csharpDotnetConvention(), root)
      check declared.outputs.len == 1
      check declared.outputs[0].unified.endsWith("/bin/Release/net8.0/hello.dll")
      check not fileExists(root / "bin" / "Release" / "net8.0" / "hello.exe")
      check not fileExists(root / "bin" / "Release" / "net8.0" / "hello")

  test ".NET refuses an output directory that contains the project":
    let why = dotnetReady()
    if why.len > 0:
      skip(why)
    else:
      let root = createTempDir("repro-dotnet-inplace-", "")
      defer: removeDir(root)
      dotnetProject(root, "hello",
        "    <OutputPath>./</OutputPath>\n" &
        "    <AppendTargetFrameworkToOutputPath>false</AppendTargetFrameworkToOutputPath>\n")
      expect ValueError:
        discard dotnetOutputs(findExe("dotnet"), root / "hello.csproj")

  test ".NET multi-targeting: every framework's trees and assembly":
    # `<TargetFrameworks>` (plural), even with one entry, makes the outer
    # build evaluate no TargetPath; each inner build's evaluation answers.
    let why = dotnetReady()
    if why.len > 0:
      skip(why)
    else:
      let root = createTempDir("repro-dotnet-multi-", "")
      defer: removeDir(root)
      dotnetProject(root, "hello", "",
        frameworks = "<TargetFrameworks>net8.0</TargetFrameworks>")
      let declared = buildAsTheEngineDoes(dotnet_convention.csharpDotnetConvention(), root)
      check declared.outputs.len == 1
      check declared.outputs[0].unified.endsWith("/bin/Release/net8.0/hello.dll")
      check declared.opaque.len == 2
      # Two frameworks, evaluated only: building net6.0 would need its
      # targeting pack, which the SDK 8 does not carry.
      writeFile(root / "hello.csproj", readFile(root / "hello.csproj").replace(
        "<TargetFrameworks>net8.0</TargetFrameworks>",
        "<TargetFrameworks>net8.0;net6.0</TargetFrameworks>"))
      let both = dotnetOutputs(findExe("dotnet"), root / "hello.csproj")
      check both.outputs.len == 2
      check both.outputs[0].unified.endsWith("/bin/Release/net8.0/hello.dll")
      check both.outputs[1].unified.endsWith("/bin/Release/net6.0/hello.dll")
      check both.opaqueOutputs.len == 4
      var objNet6 = false
      for tree in both.opaqueOutputs:
        if tree.unified.strip(leading = false, chars = {'/'}).endsWith(
            "/obj/Release/net6.0"): objNet6 = true
      check objNet6

suite "discovery fragments":

  test "nested opaque trees collapse to the outermost":
    check collapseOpaqueOutputs(@["/w/bin/Release/", "/w/bin", "/w/obj/x",
      "/w/bin/Release/net8.0"]) == @["/w/bin", "/w/obj/x"]
    check collapseOpaqueOutputs(@["/w/out", "/w/out2"]) == @["/w/out", "/w/out2"]

  test "an unchanged answer leaves the fragment untouched":
    # The fragment keys the build edge; rewriting the same bytes would move
    # its times and miss the build edge's record (Build-Engine-And-
    # Scheduler.md §"Restoring a delegated build").
    let root = createTempDir("repro-fragment-restat-", "")
    defer: removeDir(root)
    let path = root / "f.dyndep"
    let answer = DiscoveredOutputs(outputs: @["/w/out/a.jar"],
      opaqueOutputs: @["/w/out"])
    writeOutputFragment(path, "build", answer)
    let old = fromUnix(1_000_000_000)
    setLastModificationTime(path, old)
    writeOutputFragment(path, "build", answer)
    check getLastModificationTime(path) == old
    writeOutputFragment(path, "build", DiscoveredOutputs(
      outputs: @["/w/out/b.jar"], opaqueOutputs: @["/w/out"]))
    check getLastModificationTime(path) != old
    check "/w/out/b.jar" in readFile(path)

  test "a fragment lists trees, then obligatory, then optional outputs":
    let root = createTempDir("repro-fragment-", "")
    defer: removeDir(root)
    let path = root / "f.dyndep"
    writeOutputFragment(path, "build", DiscoveredOutputs(
      outputs: @["C:\\w\\bin\\a.dll"], optionalOutputs: @["/w/a.pdb"],
      opaqueOutputs: @["C:\\w\\bin\\", "C:\\w\\obj"]))
    check readFile(path) == "repro-dynamic-graph-v1\n" &
      "opaque-output\tbuild\tC:/w/bin\n" &
      "opaque-output\tbuild\tC:/w/obj\n" &
      "output\tbuild\tC:/w/bin/a.dll\n" &
      "optional-output\tbuild\t/w/a.pdb\n"
