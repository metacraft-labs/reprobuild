## M42 verification: C# / .NET (Tier 2b) language convention.
##
## Tests against the in-tree fixture under
## ``reprobuild-examples/csharp-dotnet/hello-binary/`` plus scratch
## projects materialised in the test's temp directory.
##
## Coverage:
##   * ``recognize`` returns true for the hello-binary fixture when:
##     - dotnet is on PATH
##   * ``recognize`` returns false when:
##     - no ``*.csproj`` is at the root
##     - ``packages.lock.json`` is missing (HARD precondition per M42
##       spec — the offline-build guarantee)
##     - ``uses:`` doesn't list dotnet
##     - no executable / library member is declared
##     - an F# project (``*.fsproj``) is present at the root
##   * ``emitFragment`` against the hello-binary fixture (skipped when
##     dotnet is missing):
##     - the convention emits a ``csharp-dotnet-outputs`` discovery
##       action and a single ``csharp-dotnet-build`` action.
##     - the build action's argv carries ``dotnet build -c Release
##       --no-restore --nologo --verbosity quiet --disable-build-servers``.
##     - the build action declares no outputs of its own: it loads the
##       discovery fragment, which is one of its inputs.
##   * Where MSBuild puts the assembly (default layout, ``OutputPath``,
##     ``AssemblyName``, ``RuntimeIdentifier``, ``UseAppHost=false``) is
##     checked by real SDK builds in ``test_delegated_build_outputs.nim``.

import std/[os, osproc, strutils, tempfiles, unittest]
import repro_test_support/reasoned_skip
import repro_test_support

import repro_core
import repro_provider_runtime
import repro_project_dsl
import repro_standard_provider/convention
import repro_standard_provider/conventions/csharp_dotnet as dotnet_convention

let
  ## parentDir four times from
  ## ``libs/repro_standard_provider/tests/test_csharp_dotnet_convention.nim``
  ## lands at the ``reprobuild/`` repo root; one more parent gets to the
  ## sibling ``reprobuild-examples`` checkout.
  ReprobuildRoot = currentSourcePath.parentDir.parentDir.parentDir.parentDir
  MetacraftRoot = workspaceRootForRepo(ReprobuildRoot)
  HelloBinaryFixture =
    MetacraftRoot / "reprobuild-examples" / "csharp-dotnet" / "hello-binary"

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

proc dotnetToolchainReady(): bool =
  ## True when ``dotnet`` is on PATH. The convention's ``recognize``
  ## enforces this; the test's emit-fragment branch SKIPs when
  ## missing.
  findExe("dotnet").len > 0

suite "csharp-dotnet convention M42":

  test "recognize: positive — hello-binary fixture (toolchain-gated)":
    let conv = dotnet_convention.csharpDotnetConvention()
    check conv.name == "csharp-dotnet"
    if not fileExists(HelloBinaryFixture / "hello.csproj"):
      checkpoint "fixture missing — looked at " & HelloBinaryFixture
      fail()
    if not fileExists(HelloBinaryFixture / "packages.lock.json"):
      checkpoint "fixture missing packages.lock.json — " &
        "M42 HARD precondition"
      fail()
    let request = dummyRequest(HelloBinaryFixture)
    if dotnetToolchainReady():
      check conv.recognize(HelloBinaryFixture, request)
    else:
      checkpoint "dotnet toolchain unavailable — recognize must be false"
      check not conv.recognize(HelloBinaryFixture, request)

  test "recognize: negative — no *.csproj at root":
    let scratch = getTempDir() / "test_csharp_dotnet_convention_no_csproj"
    if dirExists(scratch):
      removeDir(scratch)
    createDir(scratch)
    writeFile(scratch / "Program.cs",
      "using System;\n" &
      "Console.WriteLine(\"hi\");\n")
    writeFile(scratch / "packages.lock.json", "{\n  \"version\": 1\n}\n")
    writeFile(scratch / "reprobuild.nim",
      "import repro_project_dsl\n" &
      "package fakeDotnetNoCsproj:\n" &
      "  uses:\n" &
      "    \"dotnet >=8\"\n" &
      "\n" &
      "  executable hello:\n" &
      "    discard\n")
    defer:
      removeDir(scratch)
    let conv = dotnet_convention.csharpDotnetConvention()
    let request = dummyRequest(scratch)
    check not conv.recognize(scratch, request)

  test "recognize: negative — packages.lock.json missing (M42 HARD precondition)":
    let scratch = getTempDir() / "test_csharp_dotnet_convention_no_lockfile"
    if dirExists(scratch):
      removeDir(scratch)
    createDir(scratch)
    writeFile(scratch / "Program.cs",
      "using System;\n" &
      "Console.WriteLine(\"hi\");\n")
    writeFile(scratch / "hello.csproj",
      "<Project Sdk=\"Microsoft.NET.Sdk\">\n" &
      "  <PropertyGroup>\n" &
      "    <OutputType>Exe</OutputType>\n" &
      "    <TargetFramework>net8.0</TargetFramework>\n" &
      "    <RestorePackagesWithLockFile>true</RestorePackagesWithLockFile>\n" &
      "  </PropertyGroup>\n" &
      "</Project>\n")
    # Deliberately NO packages.lock.json — M42 spec calls this a HARD
    # precondition; the convention must refuse to recognise.
    writeFile(scratch / "reprobuild.nim",
      "import repro_project_dsl\n" &
      "package fakeDotnetNoLockfile:\n" &
      "  uses:\n" &
      "    \"dotnet >=8\"\n" &
      "\n" &
      "  executable hello:\n" &
      "    discard\n")
    defer:
      removeDir(scratch)
    let conv = dotnet_convention.csharpDotnetConvention()
    let request = dummyRequest(scratch)
    check not conv.recognize(scratch, request)

  test "recognize: negative — uses lacks dotnet":
    let scratch = getTempDir() / "test_csharp_dotnet_convention_no_dotnet_in_uses"
    if dirExists(scratch):
      removeDir(scratch)
    createDir(scratch)
    writeFile(scratch / "Program.cs",
      "using System;\n" &
      "Console.WriteLine(\"hi\");\n")
    writeFile(scratch / "hello.csproj",
      "<Project Sdk=\"Microsoft.NET.Sdk\">\n" &
      "  <PropertyGroup>\n" &
      "    <OutputType>Exe</OutputType>\n" &
      "    <TargetFramework>net8.0</TargetFramework>\n" &
      "    <RestorePackagesWithLockFile>true</RestorePackagesWithLockFile>\n" &
      "  </PropertyGroup>\n" &
      "</Project>\n")
    writeFile(scratch / "packages.lock.json", "{\n  \"version\": 1\n}\n")
    writeFile(scratch / "reprobuild.nim",
      "import repro_project_dsl\n" &
      "package fakeDotnetNoUses:\n" &
      "  uses:\n" &
      "    \"gcc >=11\"\n" &
      "\n" &
      "  executable hello:\n" &
      "    discard\n")
    defer:
      removeDir(scratch)
    let conv = dotnet_convention.csharpDotnetConvention()
    let request = dummyRequest(scratch)
    check not conv.recognize(scratch, request)

  test "recognize: negative — no member declared":
    let scratch = getTempDir() / "test_csharp_dotnet_convention_no_member"
    if dirExists(scratch):
      removeDir(scratch)
    createDir(scratch)
    writeFile(scratch / "Program.cs",
      "using System;\n" &
      "Console.WriteLine(\"hi\");\n")
    writeFile(scratch / "hello.csproj",
      "<Project Sdk=\"Microsoft.NET.Sdk\">\n" &
      "  <PropertyGroup>\n" &
      "    <OutputType>Exe</OutputType>\n" &
      "    <TargetFramework>net8.0</TargetFramework>\n" &
      "    <RestorePackagesWithLockFile>true</RestorePackagesWithLockFile>\n" &
      "  </PropertyGroup>\n" &
      "</Project>\n")
    writeFile(scratch / "packages.lock.json", "{\n  \"version\": 1\n}\n")
    writeFile(scratch / "reprobuild.nim",
      "import repro_project_dsl\n" &
      "package fakeDotnetNoMember:\n" &
      "  uses:\n" &
      "    \"dotnet >=8\"\n")
    defer:
      removeDir(scratch)
    let conv = dotnet_convention.csharpDotnetConvention()
    let request = dummyRequest(scratch)
    check not conv.recognize(scratch, request)

  test "recognize: negative — *.fsproj at root (F# territory)":
    let scratch = getTempDir() / "test_csharp_dotnet_convention_fsproj_present"
    if dirExists(scratch):
      removeDir(scratch)
    createDir(scratch)
    writeFile(scratch / "Program.cs",
      "using System;\n" &
      "Console.WriteLine(\"hi\");\n")
    writeFile(scratch / "hello.csproj",
      "<Project Sdk=\"Microsoft.NET.Sdk\">\n" &
      "  <PropertyGroup>\n" &
      "    <OutputType>Exe</OutputType>\n" &
      "    <TargetFramework>net8.0</TargetFramework>\n" &
      "    <RestorePackagesWithLockFile>true</RestorePackagesWithLockFile>\n" &
      "  </PropertyGroup>\n" &
      "</Project>\n")
    # Both .csproj and .fsproj present — the convention must defer
    # to the future F# convention (mirrors the M40/M41 sibling-
    # rejection pattern).
    writeFile(scratch / "hello.fsproj",
      "<Project Sdk=\"Microsoft.NET.Sdk\">\n" &
      "  <PropertyGroup>\n" &
      "    <OutputType>Exe</OutputType>\n" &
      "    <TargetFramework>net8.0</TargetFramework>\n" &
      "  </PropertyGroup>\n" &
      "</Project>\n")
    writeFile(scratch / "packages.lock.json", "{\n  \"version\": 1\n}\n")
    writeFile(scratch / "reprobuild.nim",
      "import repro_project_dsl\n" &
      "package fakeDotnetFsprojBoth:\n" &
      "  uses:\n" &
      "    \"dotnet >=8\"\n" &
      "\n" &
      "  executable hello:\n" &
      "    discard\n")
    defer:
      removeDir(scratch)
    let conv = dotnet_convention.csharpDotnetConvention()
    let request = dummyRequest(scratch)
    check not conv.recognize(scratch, request)

  test "emitFragment: hello-binary fixture produces a single build action":
    if not dotnetToolchainReady():
      skip("dotnet not on PATH")
    else:
      let conv = dotnet_convention.csharpDotnetConvention()
      let request = dummyRequest(HelloBinaryFixture)
      require conv.recognize(HelloBinaryFixture, request)
      let fragment = conv.emitFragment(HelloBinaryFixture, request)

      var buildActions: seq[BuildActionDef] = @[]
      for node in fragment.nodes:
        if node.kind != gnkAction:
          continue
        let action = decodeBuildActionPayload(toBytes(node.payload))
        if action.id == "csharp-dotnet-build":
          buildActions.add(action)

      check buildActions.len == 1
      let buildAct = buildActions[0]
      check buildAct.pool == "compile"

      # argv carries: dotnet, "build", "-c", "Release", "--no-restore",
      # "--nologo", "--verbosity", "quiet", <csproj>
      let argv = inlineArgvOf(buildAct)
      var sawBuildVerb = false
      var sawReleaseConfig = false
      var sawNoRestoreFlag = false
      var sawNologoFlag = false
      var sawVerbosityQuiet = false
      for i, token in argv:
        if token == "build": sawBuildVerb = true
        elif token == "Release" and i > 0 and argv[i - 1] == "-c":
          sawReleaseConfig = true
        elif token == "--no-restore": sawNoRestoreFlag = true
        elif token == "--nologo": sawNologoFlag = true
        elif token == "quiet" and i > 0 and argv[i - 1] == "--verbosity":
          sawVerbosityQuiet = true
      check sawBuildVerb
      check sawReleaseConfig
      check sawNoRestoreFlag
      check sawNologoFlag
      check sawVerbosityQuiet

      check "--disable-build-servers" in argv
      check ("DOTNET_CLI_TELEMETRY_OPTOUT", "1") in buildAct.env
      # The build edge's outputs are discovered, not predicted
      # (Build-Engine-And-Scheduler.md §"Outputs a delegated build
      # decides"): it declares none itself, loads the fragment its
      # discovery edge writes, and is keyed on it. Real builds of the
      # default layout and of the overrides are in
      # test_delegated_build_outputs.nim.
      check buildAct.outputs.len == 0
      check buildAct.dynamicDepsFile.replace('\\', '/').endsWith(
        "/.repro/build/csharp-dotnet-outputs.dyndep")
      check buildAct.dynamicDepsFile in buildAct.inputs
      check "csharp-dotnet-outputs" in buildAct.deps
      var sawDiscovery = false
      for node in fragment.nodes:
        if node.kind != gnkAction:
          continue
        let action = decodeBuildActionPayload(toBytes(node.payload))
        if action.id == "csharp-dotnet-outputs":
          sawDiscovery = true
          check action.outputs == @[buildAct.dynamicDepsFile]
          check "--delegated-outputs" in inlineArgvOf(action)
      check sawDiscovery
