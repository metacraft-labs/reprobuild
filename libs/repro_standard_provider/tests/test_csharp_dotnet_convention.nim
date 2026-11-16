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
##   * Mode A's per-unit ``csc`` argv (CSharp-DotNet.md §"Per-unit compile
##     argv (managed assembly)"), against the real SDK (skipped when dotnet
##     is missing):
##     - the argv derived the way that section prescribes, from MSBuild's
##       ``CscCommandLineArgs``, compiles the unmodified ``dotnet new
##       console`` project through a response file (``/noconfig`` kept on
##       the command line, so csc must not warn CS2023), and the assembly
##       prints what the ``dotnet build`` one prints: the same ``#if`` branches and the same
##       ``TargetFrameworkAttribute``. The query runs after a ``dotnet
##       build`` of the same project, so it must defeat CoreCompile's
##       up-to-date check or it reports no arguments at all.
##     - the argv the section used to prescribe (the ``**/*.cs`` glob minus
##       ``obj/`` and ``bin/``, ``-define:RELEASE``) cannot compile that
##       project: ``ImplicitUsings``' global usings live in a generated
##       ``obj/`` file, and the compiler fails with CS0103 on ``Console``.
##     Recorded as reprobuild-pm
##     ``issues/2026-11-12-c-mode-a-csc-argv-omits-sdk-generated-sources-and-framework-defines.md``.
##     Nothing is mocked: the cases run the SDK's own ``dotnet``, MSBuild
##     and ``csc.dll``. Mode A has no graph emitter yet, so the argv is
##     derived here, step by step as the section states it; the section is
##     what these cases hold to the tool.

import std/[json, os, osproc, sequtils, strtabs, strutils, tempfiles, unittest]
import repro_test_support/reasoned_skip
import repro_test_support

import repro_core
import repro_provider_runtime
import repro_project_dsl
import repro_standard_provider/convention
import repro_standard_provider/conventions/csharp_dotnet as dotnet_convention
import repro_standard_provider/conventions/output_discovery

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

# --- Mode A: the per-unit csc argv against the real SDK ----------------------

const
  TemplateCsproj = "<Project Sdk=\"Microsoft.NET.Sdk\">\n\n" &
    "  <PropertyGroup>\n" &
    "    <OutputType>Exe</OutputType>\n" &
    "    <TargetFramework>net8.0</TargetFramework>\n" &
    "    <ImplicitUsings>enable</ImplicitUsings>\n" &
    "    <Nullable>enable</Nullable>\n" &
    "  </PropertyGroup>\n\n</Project>\n"
    ## ``dotnet new console`` (SDK 8) byte for byte, BOM aside: the
    ## template is the case CSharp-DotNet.md §"Example projects" names
    ## (``console-app/`` — Mode A; top-level statements).
  TemplateProgram = "Console.WriteLine(\"Hello, World!\");\n" &
    "#if NET8_0_OR_GREATER\nConsole.WriteLine(\"NET8_0_OR_GREATER\");\n#endif\n" &
    "#if TRACE\nConsole.WriteLine(\"TRACE\");\n#endif\n" &
    "#if RELEASE\nConsole.WriteLine(\"RELEASE\");\n#endif\n" &
    "var framework = (System.Runtime.Versioning.TargetFrameworkAttribute?)" &
    "Attribute.GetCustomAttribute(typeof(Program).Assembly, " &
    "typeof(System.Runtime.Versioning.TargetFrameworkAttribute));\n" &
    "Console.WriteLine(framework?.FrameworkName ?? \"no TargetFrameworkAttribute\");\n"
    ## The template's one statement (no ``using``: ``Console`` resolves only
    ## through the implicit global usings), then one line per symbol that
    ## ``dotnet build`` defines and the attribute its generated
    ## AssemblyAttributes file carries.

proc runCaptured(argv: seq[string]; cwd: string): tuple[output: string,
                                                         code: int] =
  ## Runs a tool with the current environment plus the Mode B quiet
  ## environment, returning its combined output and exit code.
  let environment = newStringTable(modeCaseSensitive)
  for key, value in envPairs():
    environment[key] = value
  for (key, value) in DotnetQuietEnvironment:
    environment[key] = value
  let process = startProcess(argv[0], workingDir = cwd, args = argv[1 .. ^1],
    env = environment, options = {poStdErrToStdOut, poUsePath})
  defer: process.close()
  result.output = process.outputStream.readToEnd()
  result.code = process.waitForExit()

proc runOk(argv: seq[string]; cwd: string): string =
  let (output, code) = runCaptured(argv, cwd)
  doAssert code == 0, argv.quoteShellCommand() & " exited " & $code & "\n" &
    output
  output

proc templateProject(): string =
  ## A restored and built copy of the console template, as a developer's
  ## checkout has it after one ``dotnet build``.
  result = createTempDir("repro-csharp-mode-a-", "")
  writeFile(result / "hello.csproj", TemplateCsproj)
  writeFile(result / "Program.cs", TemplateProgram)
  discard runOk(@["dotnet", "restore", "--disable-build-servers"], result)
  discard runOk(@["dotnet", "build", "-c", "Release", "--no-restore",
    "--disable-build-servers", "-nologo"], result)

type MsbuildCompileLine = object
  cscDll: string      ## ``<sdk>/Roslyn/bincore/csc.dll``
  arguments: seq[string]  ## ``CscCommandLineArgs``, in order

proc msbuildCompileLine(projectDir: string): MsbuildCompileLine =
  ## CSharp-DotNet.md §"Per-unit compile argv (managed assembly)": run the
  ## ``Compile`` target with ``ProvideCommandLineArgs`` and
  ## ``SkipCompilerExecution`` and read the ``CscCommandLineArgs`` item the
  ## Csc task returns. ``NonExistentFile`` is one of CoreCompile's
  ## ``Inputs``; naming a file that does not exist keeps the target from
  ## being skipped as up to date, which would return no item at all.
  ## https://github.com/dotnet/roslyn/blob/main/src/Compilers/Core/MSBuildTask/Microsoft.CSharp.Core.targets
  let answer = runOk(@["dotnet", "msbuild", projectDir / "hello.csproj",
    "-nologo", "--disable-build-servers", "-p:Configuration=Release",
    "-p:ProvideCommandLineArgs=true", "-p:SkipCompilerExecution=true",
    "-p:BuildProjectReferences=false",
    "-p:NonExistentFile=__NonExistentSubDir__/__NonExistentFile__",
    "-t:Compile", "-getItem:CscCommandLineArgs",
    "-getProperty:RoslynTargetsPath"], projectDir)
  let first = answer.find('{')
  let last = answer.rfind('}')
  doAssert first >= 0 and last > first, "MSBuild printed no JSON:\n" & answer
  let parsed = parseJson(answer[first .. last])
  result.cscDll = parsed["Properties"]["RoslynTargetsPath"].getStr() /
    "bincore" / "csc.dll"
  for item in parsed["Items"]{"CscCommandLineArgs"}.getElems():
    result.arguments.add(item["Identity"].getStr())

proc compileWith(cscDll: string; arguments: seq[string];
                 projectDir, outDir: string): tuple[output: string,
                                                    code: int] =
  ## The Mode A compile action: ``dotnet <csc.dll> /noconfig @<csc.rsp>``
  ## over `arguments`, run from the project directory (MSBuild's source
  ## paths are relative to it), with the assembly and its reference
  ## assembly redirected to `outDir` and the source root mapped, as the
  ## section says reprobuild does. ``/noconfig`` stays on the command line:
  ## csc ignores it inside a response file (warning CS2023), and the Csc
  ## task places it the same way.
  createDir(outDir / "ref")
  var lines: seq[string] = @[]
  var noconfig = false
  for argument in arguments:
    doAssert '"' notin argument, "unexpected quote in " & argument
    if argument == "/noconfig":
      noconfig = true
    elif argument.startsWith("/out:"):
      lines.add("\"/out:" & outDir / "hello.dll" & "\"")
    elif argument.startsWith("/refout:"):
      lines.add("\"/refout:" & outDir / "ref" / "hello.dll" & "\"")
    elif argument.contains({' ', '\t'}):
      lines.add("\"" & argument & "\"")
    else:
      lines.add(argument)
  lines.add("\"-pathmap:" & projectDir & "=/_/\"")
  let responseFile = outDir / "csc.rsp"
  writeFile(responseFile, lines.join("\n") & "\n")
  var argv = @["dotnet", cscDll]
  if noconfig:
    argv.add("/noconfig")
  argv.add("@" & responseFile)
  runCaptured(argv, projectDir)

proc runAssembly(projectDir, assembly: string): string =
  ## Runs `assembly` on the framework ``dotnet build`` resolved for the
  ## project. Mode A's own runtimeconfig is outside this section, so the
  ## one ``dotnet build`` wrote stands in for it.
  runOk(@["dotnet", "exec", "--runtimeconfig",
    projectDir / "bin" / "Release" / "net8.0" / "hello.runtimeconfig.json",
    assembly], projectDir)

suite "csharp-dotnet Mode A compile argv (real SDK)":

  test "MSBuild's csc argv compiles the console template as dotnet build does":
    if not dotnetToolchainReady():
      skip("dotnet not on PATH")
    else:
      let project = templateProject()
      defer: removeDir(project)
      let expected = runOk(@["dotnet",
        project / "bin" / "Release" / "net8.0" / "hello.dll"], project)
      check "Hello, World!" in expected
      check "NET8_0_OR_GREATER" in expected
      check "TRACE" in expected
      check ".NETCoreApp,Version=v8.0" in expected

      let line = msbuildCompileLine(project)
      check fileExists(line.cscDll)
      # The generated sources the source glob cannot see.
      var generated: seq[string] = @[]
      for argument in line.arguments:
        if argument.replace('\\', '/').startsWith("obj/"):
          generated.add(argument.extractFilename)
      checkpoint "CscCommandLineArgs: " & line.arguments.join(" ")
      check "hello.GlobalUsings.g.cs" in generated
      check "hello.AssemblyInfo.cs" in generated
      check ".NETCoreApp,Version=v8.0.AssemblyAttributes.cs" in generated

      let outDir = project / "mode-a"
      let compiled = compileWith(line.cscDll, line.arguments, project, outDir)
      checkpoint compiled.output
      require compiled.code == 0
      check "CS2023" notin compiled.output
      check runAssembly(project, outDir / "hello.dll") == expected

  test "the Compile glob alone cannot compile the console template (CS0103)":
    if not dotnetToolchainReady():
      skip("dotnet not on PATH")
    else:
      # The derivation the section stated before reprobuild-pm's fix of the
      # issue above: sources from ``**/*.cs`` minus ``obj/`` and ``bin/``,
      # ``-define:RELEASE``. Everything else, references included, is
      # MSBuild's, so the sources and the defines are the only difference.
      let project = templateProject()
      defer: removeDir(project)
      let line = msbuildCompileLine(project)
      var arguments: seq[string] = @[]
      for argument in line.arguments:
        if argument.startsWith("/") and not argument.startsWith("/define:"):
          arguments.add(argument)
      arguments.add("-define:RELEASE")
      for path in walkDirRec(project, relative = true):
        let unified = path.replace('\\', '/')
        if unified.endsWith(".cs") and not unified.startsWith("obj/") and
            not unified.startsWith("bin/"):
          arguments.add(path)
      check arguments.filterIt(it.endsWith(".cs")) == @["Program.cs"]
      let compiled = compileWith(line.cscDll, arguments, project,
        project / "glob")
      checkpoint compiled.output
      check compiled.code != 0
      check "error CS0103: The name 'Console' does not exist" in compiled.output
