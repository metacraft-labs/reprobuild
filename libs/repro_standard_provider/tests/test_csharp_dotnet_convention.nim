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
##     - the convention emits a single ``csharp-dotnet-build`` action.
##     - the action's argv carries ``dotnet build -c Release
##       --no-restore --nologo --verbosity quiet``.
##     - the action's output is
##       ``bin/Release/<TargetFramework>/<AssemblyName>.exe`` under
##       the project root (the fixture's csproj pins ``net8.0`` +
##       ``OutputType=Exe`` + ``AssemblyName=hello``).
##   * Output-path resolution: ``<TargetFramework>`` (singular or
##     first entry of plural) + ``<AssemblyName>`` (or csproj basename
##     fall-back) + ``<OutputType>`` (extension selector) compose the
##     predicted binary path.

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

proc unifiedPaths(paths: seq[string]): seq[string] =
  for path in paths:
    result.add(path.replace('\\', '/'))

proc scratchProject(name, csproj: string): string =
  ## A one-file C# project under the temp dir with ``csproj`` as its
  ## project file and an ``app`` executable member, for emit-only cases.
  result = createTempDir(name & "-", "")
  writeFile(result / "Program.cs",
    "using System;\nConsole.WriteLine(\"x\");\n")
  writeFile(result / "app.csproj", csproj)
  writeFile(result / "packages.lock.json", "{\n  \"version\": 1\n}\n")
  writeFile(result / "reprobuild.nim",
    "import repro_project_dsl\n" &
    "package fakeDotnetScratch:\n" &
    "  uses:\n" &
    "    \"dotnet >=8\"\n" &
    "\n" &
    "  executable app:\n" &
    "    discard\n")

proc exeCsproj(tfm: string; extra = ""): string =
  "<Project Sdk=\"Microsoft.NET.Sdk\">\n" &
  "  <PropertyGroup>\n" &
  "    <OutputType>Exe</OutputType>\n" &
  "    <TargetFramework>" & tfm & "</TargetFramework>\n" &
  extra &
  "  </PropertyGroup>\n" &
  "</Project>\n"

proc emittedBuildAction(projectRoot: string): BuildActionDef =
  let conv = dotnet_convention.csharpDotnetConvention()
  let request = dummyRequest(projectRoot)
  doAssert conv.recognize(projectRoot, request)
  let fragment = conv.emitFragment(projectRoot, request)
  for node in fragment.nodes:
    if node.kind != gnkAction:
      continue
    let action = decodeBuildActionPayload(toBytes(node.payload))
    if action.id == "csharp-dotnet-build":
      return action
  raise newException(ValueError, "no csharp-dotnet-build action emitted")

proc hostRid(): string =
  ## The RID a RID-less ``dotnet build`` on this host targets.
  let os =
    when defined(windows): "win"
    elif defined(macosx): "osx"
    else: "linux"
  let arch =
    when defined(arm64): "arm64"
    else: "x64"
  os & "-" & arch

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

      # Output is bin/Release/<TargetFramework>/<AssemblyName>.exe
      # under the fixture root. The fixture pins TargetFramework=net8.0
      # + OutputType=Exe + AssemblyName defaults from "hello.csproj"
      # so the binary lands at ``bin/Release/net8.0/hello.dll``.
      var sawExeOutput = false
      for outPath in buildAct.outputs:
        let unified = outPath.replace('\\', '/')
        if unified.endsWith("/bin/Release/net8.0/hello.dll"):
          sawExeOutput = true
      check sawExeOutput

  test "output-path resolution: TargetFramework + AssemblyName + OutputType compose the binary filename":
    # Scratch project with custom TargetFramework + AssemblyName +
    # OutputType to exercise the csproj XML parser without needing the
    # dotnet toolchain on PATH. ``recognize`` will fail when dotnet
    # isn't installed, but emit-fragment's output-path branch is
    # independent of that gate; since ``emitFragment`` calls
    # ``dotnetExecutable()`` and raises when dotnet is missing, this
    # test SKIPs when the toolchain is unavailable.
    if not dotnetToolchainReady():
      skip("dotnet not on PATH")
    else:
      let scratch = getTempDir() / "test_csharp_dotnet_convention_custom_coords"
      if dirExists(scratch):
        removeDir(scratch)
      createDir(scratch)
      writeFile(scratch / "Program.cs",
        "using System;\n" &
        "Console.WriteLine(\"x\");\n")
      # Use ``<TargetFrameworks>`` (plural, semicolon-separated) to
      # exercise the first-entry pickoff; pin a custom AssemblyName
      # and ``OutputType=Exe`` so the predicted path is
      # ``bin/Release/net9.0/customAsm.dll``.
      writeFile(scratch / "custom.csproj",
        "<Project Sdk=\"Microsoft.NET.Sdk\">\n" &
        "  <PropertyGroup>\n" &
        "    <OutputType>Exe</OutputType>\n" &
        "    <TargetFrameworks>net9.0;net8.0</TargetFrameworks>\n" &
        "    <AssemblyName>customAsm</AssemblyName>\n" &
        "    <RestorePackagesWithLockFile>true</RestorePackagesWithLockFile>\n" &
        "  </PropertyGroup>\n" &
        "</Project>\n")
      writeFile(scratch / "packages.lock.json", "{\n  \"version\": 1\n}\n")
      writeFile(scratch / "reprobuild.nim",
        "import repro_project_dsl\n" &
        "package fakeDotnetCustomCoords:\n" &
        "  uses:\n" &
        "    \"dotnet >=8\"\n" &
        "\n" &
        "  executable custom:\n" &
        "    discard\n")
      defer:
        removeDir(scratch)
      let conv = dotnet_convention.csharpDotnetConvention()
      let request = dummyRequest(scratch)
      require conv.recognize(scratch, request)
      let fragment = conv.emitFragment(scratch, request)
      var sawCustomBinary = false
      for node in fragment.nodes:
        if node.kind != gnkAction:
          continue
        let action = decodeBuildActionPayload(toBytes(node.payload))
        for outPath in action.outputs:
          let unified = outPath.replace('\\', '/')
          if unified.endsWith("/bin/Release/net9.0/customAsm.dll"):
            sawCustomBinary = true
      check sawCustomBinary

  test "output-path resolution: OutputType=Library yields .dll":
    # Library output: ``OutputType=Library`` (or omitted) ⇒ ``.dll``.
    # AssemblyName defaults to the csproj basename when omitted.
    if not dotnetToolchainReady():
      skip("dotnet not on PATH")
    else:
      let scratch = getTempDir() / "test_csharp_dotnet_convention_library_output"
      if dirExists(scratch):
        removeDir(scratch)
      createDir(scratch)
      writeFile(scratch / "Lib.cs",
        "namespace MyLib;\npublic static class L { " &
          "public static int Add(int a, int b) => a + b; }\n")
      writeFile(scratch / "mylib.csproj",
        "<Project Sdk=\"Microsoft.NET.Sdk\">\n" &
        "  <PropertyGroup>\n" &
        "    <OutputType>Library</OutputType>\n" &
        "    <TargetFramework>net8.0</TargetFramework>\n" &
        "    <RestorePackagesWithLockFile>true</RestorePackagesWithLockFile>\n" &
        "  </PropertyGroup>\n" &
        "</Project>\n")
      writeFile(scratch / "packages.lock.json", "{\n  \"version\": 1\n}\n")
      writeFile(scratch / "reprobuild.nim",
        "import repro_project_dsl\n" &
        "package fakeDotnetLibrary:\n" &
        "  uses:\n" &
        "    \"dotnet >=8\"\n" &
        "\n" &
        "  library mylib:\n" &
        "    discard\n")
      defer:
        removeDir(scratch)
      let conv = dotnet_convention.csharpDotnetConvention()
      let request = dummyRequest(scratch)
      require conv.recognize(scratch, request)
      let fragment = conv.emitFragment(scratch, request)
      var sawDllOutput = false
      for node in fragment.nodes:
        if node.kind != gnkAction:
          continue
        let action = decodeBuildActionPayload(toBytes(node.payload))
        for outPath in action.outputs:
          let unified = outPath.replace('\\', '/')
          if unified.endsWith("/bin/Release/net8.0/mylib.dll"):
            sawDllOutput = true
      check sawDllOutput

  test "real SDK executable produces its managed output with apphost disabled":
    # A real SDK restore supplies the lock and framework assets before the
    # convention's deliberately offline --no-restore build. No tool is mocked.
    let scratch = createTempDir("repro-dotnet-output-obligation-", "")
    defer: removeDir(scratch)
    let dotnet = findExe("dotnet")
    require dotnet.len > 0
    let created = execCmdEx(@[dotnet, "new", "console", "--no-restore",
      "--name", "OutputRegression", "--output", scratch].quoteShellCommand())
    checkpoint created.output
    require created.exitCode == 0
    let project = scratch / "OutputRegression.csproj"
    writeFile(project, readFile(project).replace("</PropertyGroup>",
      "<UseAppHost>false</UseAppHost><UseSharedCompilation>false</UseSharedCompilation></PropertyGroup>"))
    let restored = execCmdEx(@[dotnet, "restore", project,
      "--use-lock-file", "--ignore-failed-sources"].quoteShellCommand())
    checkpoint restored.output
    require restored.exitCode == 0
    writeFile(scratch / "reprobuild.nim", "import repro_project_dsl\npackage outputRegression:\n  uses:\n    \"dotnet >=8\"\n  executable OutputRegression:\n    discard\n")
    let conv = dotnet_convention.cSharpDotnetConvention()
    require conv.recognize(scratch, dummyRequest(scratch))
    let fragment = conv.emitFragment(scratch, dummyRequest(scratch))
    var sawBuild = false
    for node in fragment.nodes:
      if node.kind != gnkAction: continue
      let action = decodeBuildActionPayload(toBytes(node.payload))
      if action.id != "csharp-dotnet-build": continue
      sawBuild = true
      let built = execCmdEx(inlineArgvOf(action).quoteShellCommand(), workingDir = scratch)
      checkpoint built.output
      require built.exitCode == 0
      require action.outputs.len == 1
      check action.outputs[0].replace('\\', '/').endsWith(
        "/OutputRegression.dll")
      check fileExists(action.outputs[0])
      require action.optionalOutputs.len == 1
      check not fileExists(action.optionalOutputs[0])
    check sawBuild

  test "output-path resolution: RuntimeIdentifier names the apphost and the directory":
    if not dotnetToolchainReady():
      skip("dotnet not on PATH: emitFragment refuses without a driver")
    else:
      for (rid, appHost) in [("linux-x64", "app"), ("win-x64", "app.exe")]:
        let scratch = scratchProject(
          "test_csharp_dotnet_convention_rid_" & rid,
          exeCsproj("net8.0",
            "    <RuntimeIdentifier>" & rid & "</RuntimeIdentifier>\n"))
        defer: removeDir(scratch)
        let action = emittedBuildAction(scratch)
        checkpoint "rid " & rid & ": " & action.outputs.unifiedPaths.join(", ") &
          " optional: " & action.optionalOutputs.unifiedPaths.join(", ")
        check action.outputs.unifiedPaths.len == 1
        check action.outputs.unifiedPaths[0].endsWith(
          "/bin/Release/net8.0/" & rid & "/app.dll")
        check action.optionalOutputs.unifiedPaths ==
          @[action.outputs.unifiedPaths[0].parentDir.replace('\\', '/') &
            "/" & appHost]

  test "output-path resolution: AppendTargetFrameworkToOutputPath=false drops the TFM segment":
    if not dotnetToolchainReady():
      skip("dotnet not on PATH: emitFragment refuses without a driver")
    else:
      let scratch = scratchProject("test_csharp_dotnet_convention_no_tfm_dir",
        exeCsproj("net8.0", "    <AppendTargetFrameworkToOutputPath>" &
          "false</AppendTargetFrameworkToOutputPath>\n"))
      defer: removeDir(scratch)
      let action = emittedBuildAction(scratch)
      check action.outputs.unifiedPaths.len == 1
      check action.outputs.unifiedPaths[0].endsWith("/bin/Release/app.dll")

  test "output-path resolution: a .NET Framework executable is the .exe assembly itself":
    if not dotnetToolchainReady():
      skip("dotnet not on PATH: emitFragment refuses without a driver")
    else:
      let scratch = scratchProject("test_csharp_dotnet_convention_netfx",
        exeCsproj("net48"))
      defer: removeDir(scratch)
      let action = emittedBuildAction(scratch)
      check action.outputs.unifiedPaths.len == 1
      check action.outputs.unifiedPaths[0].endsWith(
        "/bin/Release/net48/app.exe")
      check action.optionalOutputs.len == 0

  test "real SDK build with a RuntimeIdentifier writes the declared outputs":
    # The engine fails a cacheable action that exits 0 without a required
    # output (Build-Engine-And-Scheduler.md, "A declared output is an
    # obligation"). A RuntimeIdentifier moves the build output into a
    # ``<rid>/`` sub-directory; only a real SDK build can show that the
    # declared paths are the ones it writes. The host's own RID needs only
    # the in-box apphost pack, so the restore does not reach for a runtime
    # pack. No tool is mocked.
    if not dotnetToolchainReady():
      skip("dotnet not on PATH: the real-build case needs the .NET SDK")
    else:
      let dotnet = findExe("dotnet")
      let scratch = scratchProject("test_csharp_dotnet_convention_rid_real",
        exeCsproj("net8.0", "    <RuntimeIdentifier>" & hostRid() &
          "</RuntimeIdentifier>\n" &
          "    <UseSharedCompilation>false</UseSharedCompilation>\n"))
      defer: removeDir(scratch)
      removeFile(scratch / "packages.lock.json")
      let restored = execCmdEx(@[dotnet, "restore", scratch / "app.csproj",
        "--use-lock-file"].quoteShellCommand())
      checkpoint restored.output
      require restored.exitCode == 0
      let action = emittedBuildAction(scratch)
      let built = execCmdEx(inlineArgvOf(action).quoteShellCommand(),
        workingDir = scratch)
      checkpoint built.output
      require built.exitCode == 0
      require action.outputs.len == 1
      check action.outputs[0].replace('\\', '/').endsWith(
        "/bin/Release/net8.0/" & hostRid() & "/app.dll")
      check fileExists(action.outputs[0])
      # The host RID writes the apphost; it is optional only because some
      # configurations do not.
      require action.optionalOutputs.len == 1
      check fileExists(action.optionalOutputs[0])
