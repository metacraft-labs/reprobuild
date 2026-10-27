## A real ``repro build`` of a Maven, .NET, Cabal and Gradle project, then
## the same build after the tool's whole output tree is deleted.
## Build-Engine-And-Scheduler.md §"Outputs a delegated build decides" and
## §"Restoring a delegated build".
##
## What each convention's build edge promises comes from its discovery edge:
## the tool's output tree as an opaque output directory, the main product as
## an obligatory output inside it. With ``--restore-cached-outputs`` the
## engine records the tree whole, so deleting it must bring every file back
## from the cache, byte for byte, without running the tool -- where the S7
## gate admits the record. It does for Maven, .NET and Cabal. Gradle writes
## under ``GRADLE_USER_HOME`` on every build, outside anything the edge can
## declare, so S7 withholds its payloads and the deleted tree is rebuilt by
## running Gradle again; this test pins that too, so the day it changes is
## visible.
##
## Spawns the built ``repro`` (``build/bin/repro``) and the real tools; a
## case whose toolchain is not on PATH is skipped with its reason. Nothing
## is mocked. Where the monitor loses events in a tool's runtime the edge is
## never published, and only the first build can be checked (see the
## comment at the check).

import std/[algorithm, json, os, osproc, sequtils, strutils, tables, tempfiles, unittest]

const reproBinary =
  when defined(windows): "build/bin/repro.exe" else: "build/bin/repro"

proc findRepoRoot(): string =
  var dir = currentSourcePath().parentDir
  while dir.len > 0:
    if fileExists(dir / "repro.nim") and fileExists(dir / "repro_tests.nim"):
      return dir
    let parent = dir.parentDir
    if parent == dir:
      break
    dir = parent
  raise newException(IOError,
    "cannot locate reprobuild repo root from " & currentSourcePath())

type
  Outcome = object
    found: bool
    status: string
    cacheDecision: string
    reason: string
    launched: bool
    diagnostics: string

proc readOutcome(reportPath, actionId: string): Outcome =
  let report = parseFile(reportPath)
  for item in report{"actions"}.getElems():
    if item{"id"}.getStr() != actionId:
      continue
    result = Outcome(found: true, status: item{"status"}.getStr(),
      cacheDecision: item{"cacheDecision"}.getStr(),
      reason: item{"reason"}.getStr(), launched: item{"launched"}.getBool())
    result.diagnostics = $item{"evidence"}{"diagnostics"} & " " &
      item{"cachePublishSkipReason"}.getStr()

proc snapshot(tree: string): Table[string, string] =
  ## Every file of `tree` by relative path, with its bytes.
  for path in walkDirRec(tree, yieldFilter = {pcFile, pcLinkToFile}):
    result[relativePath(path, tree).replace('\\', '/')] = readFile(path)

proc writeProject(root: string; files: openArray[(string, string)]) =
  for (relative, content) in files:
    createDir(parentDir(root / relative))
    writeFile(root / relative, content)

proc reproNim(packageName, uses, member: string): string =
  "import repro_project_dsl\npackage " & packageName & ":\n  uses:\n" & uses &
    "\n  executable " & member & ":\n    discard\n"

proc tool(argv: seq[string]; cwd: string) =
  let res = execCmdEx(argv.quoteShellCommand(), workingDir = cwd)
  checkpoint argv.quoteShellCommand() & "\n" & res.output
  require res.exitCode == 0

const JavaHello = "package com.example;\npublic class Hello {\n" &
  "  public static void main(String[] args) { System.out.println(\"hello\"); }\n}\n"

type Case = object
  name: string
  missing: string            ## why this case cannot run here, or ""
  buildId: string            ## the convention's build edge
  tree: string               ## relative: the tool's output tree
  product: string            ## relative: the obligatory main product
  restorable: bool           ## whether S7 admits the record
  setup: proc (root: string) {.closure.}

proc cases(): seq[Case] =
  result.add(Case(name: "maven", buildId: "java-maven-package",
    tree: "target", product: "target/hello-1.0.jar", restorable: true,
    missing: (if findExe("mvn").len == 0 or findExe("javac").len == 0:
      "mvn or javac not on PATH" else: ""),
    setup: proc (root: string) =
      writeProject(root, [
        ("pom.xml", "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" &
          "<project xmlns=\"http://maven.apache.org/POM/4.0.0\">\n" &
          "  <modelVersion>4.0.0</modelVersion>\n" &
          "  <groupId>com.example</groupId>\n  <artifactId>hello</artifactId>\n" &
          "  <version>1.0</version>\n  <properties>\n" &
          "    <maven.compiler.release>17</maven.compiler.release>\n" &
          "    <project.build.sourceEncoding>UTF-8</project.build.sourceEncoding>\n" &
          "  </properties>\n</project>\n"),
        ("src/main/java/com/example/Hello.java", JavaHello),
        ("reprobuild.nim", reproNim("mavenRestore",
          "    \"java >=17\"\n    \"mvn >=3.9\"\n", "hello"))])))
  result.add(Case(name: "dotnet", buildId: "csharp-dotnet-build",
    tree: "bin/Release/net8.0", product: "bin/Release/net8.0/hello.dll",
    restorable: true,
    missing: (if findExe("dotnet").len == 0: "dotnet not on PATH" else: ""),
    setup: proc (root: string) =
      writeProject(root, [
        ("hello.csproj", "<Project Sdk=\"Microsoft.NET.Sdk\">\n" &
          "  <PropertyGroup>\n    <OutputType>Exe</OutputType>\n" &
          "    <TargetFramework>net8.0</TargetFramework>\n" &
          "    <RestorePackagesWithLockFile>true</RestorePackagesWithLockFile>\n" &
          "  </PropertyGroup>\n</Project>\n"),
        ("Program.cs", "System.Console.WriteLine(\"hello\");\n"),
        ("reprobuild.nim", reproNim("dotnetRestore",
          "    \"dotnet >=8\"\n", "hello"))])
      putEnv("DOTNET_CLI_TELEMETRY_OPTOUT", "1")
      tool(@["dotnet", "restore", root / "hello.csproj", "--use-lock-file"], root)))
  result.add(Case(name: "cabal", buildId: "haskell-cabal-build",
    tree: "dist-newstyle", product: "", restorable: true,
    missing: (if findExe("cabal").len == 0 or findExe("ghc").len == 0:
      "cabal or ghc not on PATH" else: ""),
    setup: proc (root: string) =
      writeProject(root, [
        ("hello.cabal", "cabal-version: 2.4\nname: hello\nversion: 1.0\n" &
          "build-type: Simple\n\nexecutable hello\n  main-is: Main.hs\n" &
          "  hs-source-dirs: app\n  build-depends: base\n" &
          "  default-language: Haskell2010\n"),
        ("app/Main.hs", "main :: IO ()\nmain = putStrLn \"hello\"\n"),
        ("reprobuild.nim", reproNim("cabalRestore",
          "    \"ghc >=9\"\n    \"cabal >=3.10\"\n", "hello"))])))
  result.add(Case(name: "gradle", buildId: "kotlin-gradle-build",
    tree: "build", product: "build/libs/hello-1.0.jar", restorable: false,
    missing: (if findExe("gradle").len == 0 or findExe("javac").len == 0:
      "gradle or javac not on PATH" else: ""),
    setup: proc (root: string) =
      writeProject(root, [
        ("settings.gradle.kts", "rootProject.name = \"hello\"\n"),
        ("build.gradle.kts", "plugins { java }\nversion = \"1.0\"\n"),
        ("src/main/java/com/example/Hello.java", JavaHello),
        ("reprobuild.nim", reproNim("gradleRestore",
          "    \"java >=17\"\n    \"gradle >=8\"\n", "hello"))])))

suite "a delegated build's output tree is restored from the cache":
  let repoRoot = findRepoRoot()
  let repro = repoRoot / reproBinary
  for testCase in cases():
    test "restore after deleting the output tree: " & testCase.name:
      if not fileExists(repro):
        checkpoint "repro binary not built: " & repro
        skip()
      elif testCase.missing.len > 0:
        checkpoint testCase.missing
        skip()
      else:
        let scratch = createTempDir("repro-delegated-restore-" & testCase.name & "-", "")
        defer: removeDir(scratch)
        let project = scratch / "project"
        createDir(project)
        testCase.setup(project)
        proc build(label: string): Outcome =
          let report = scratch / (label & ".json")
          let res = execCmdEx(@[repro, "build", "--tool-provisioning=path",
            "--daemon=off", "--no-runquota", "--log=quiet", "--progress=quiet",
            "--measure=none", "--restore-cached-outputs",
            "--action-cache-root=" & (scratch / "cache"),
            "--write-report=" & report].quoteShellCommand(),
            workingDir = project)
          checkpoint label & ": " & res.output
          require res.exitCode == 0
          result = readOutcome(report, testCase.buildId)
          checkpoint label & ": " & $result
          require result.found

        let first = build("first")
        check first.status == "asSucceeded"
        let tree = project / testCase.tree
        require dirExists(tree)
        if testCase.product.len > 0:
          check fileExists(project / testCase.product)
        let before = snapshot(tree)
        check before.len > 0
        # The cache can restore only an edge it published, and a monitored
        # edge whose capture lost events is never published (spec
        # Monitor-Loss-Path-Invalidation.md). That is every edge of these
        # tools on Windows (reprobuild-pm issue 2026-10-27-no-monitored-c-cpp-
        # link-edge-is-published-on-windows.md), and on Linux the JVM's and
        # the .NET runtime's: their JITs map anonymous executable memory and
        # issue raw syscalls the monitor cannot follow (the class of
        # 2026-10-07-isonim-tailwind-frozen-monitor-mprotect-and-raw-syscall-
        # loss.md). Such an edge re-runs on every build, and this case then
        # stops at what the first build showed: the discovered outputs were
        # obligatory and produced.
        let unpublished = defined(windows) or
          "monitor loss" in first.diagnostics or
          "monitor-loss" in first.diagnostics
        if unpublished:
          checkpoint "restore not exercised: the edge was not published " &
            "(monitor loss): " & first.diagnostics[0 ..< min(400, first.diagnostics.len)]
          skip()
        else:
          let unchanged = build("unchanged")
          check not unchanged.launched

          removeDir(tree)
          let after = build("after-delete")
          if testCase.restorable:
            check after.status == "asCacheHit"
            check after.reason == "restored"
            check not after.launched
            # The whole tree, byte for byte: products, intermediates and the
            # tool's own incremental state.
            let restored = snapshot(tree)
            var names = toSeq(before.keys)
            names.sort()
            var restoredNames = toSeq(restored.keys)
            restoredNames.sort()
            check restoredNames == names
            for name in names:
              if restored.getOrDefault(name) != before[name]:
                checkpoint "differs after restore: " & name
                fail()
          else:
            # S7 withheld the payloads: the tool runs again and rebuilds it.
            check after.launched
            check after.status == "asSucceeded"
            check "withheld" in after.diagnostics or
              "payload" in after.diagnostics
            check dirExists(tree)
            if testCase.product.len > 0:
              check fileExists(project / testCase.product)
