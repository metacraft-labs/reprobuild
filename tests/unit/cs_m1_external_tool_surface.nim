## Renders the external-tool surface of every in-tree ``cli:`` tool
## definition as canonical text, for the CS-M1 golden comparison
## (``t_cs_m1_external_tool_argv_unchanged.nim``).
##
## The surface has three parts per package, and each one is what a consumer
## of the CLI model actually sees:
##
## 1. **The model.** Every field of every ``CliCommandDef`` and
##    ``CliParamDef`` the ``package`` macro produced, including the
##    reprobuild build-graph vocabulary (parameter roles, ``outputs``,
##    ``optionalOutputs``, ``removeBeforeRun``, ``subTools``,
##    ``dependencyPolicy``, ``nonDeterminism``, the provider entry point).
##    The typed-tool wrapper procs are generated from exactly these fields,
##    so an identical model means identical wrappers.
## 2. **The argv.** Each command called with every parameter supplied, built
##    through the same runtime helpers the generated wrapper calls
##    (``cliArg`` / ``inputArg`` / ``outputArg`` and their ``Seq`` forms,
##    chosen by role and Nim type exactly as the wrapper generator chooses
##    them) and rendered by the engine's own ``argvForCall``.
## 3. **The interface artifact.** The encoded ``ProjectInterfaceArtifact``
##    bytes for the package, as their SHA-256.
##
## Source locations are recorded as import paths, not absolute paths: the
## test is compiled with ``-d:reproInstalledPrefix`` (its ``.nim.cfg``), the
## mode in which the DSL names its source sites the same way on every
## checkout.

{.experimental: "callOperator".}

import std/[algorithm, strutils]

import nimcrypto/sha2

import repro_cli_support
import repro_interface_artifacts
import repro_project_dsl
import repro_tool_profiles

# Every stdlib module that declares an ``executable … cli:`` block. Imported
# for the ``registerPackageDef`` side effect of their ``package`` blocks; each
# is aliased so a package const and its module of the same name never
# collide.
import repro_dsl_stdlib/packages/appimagetool as cs_m1_appimagetool
import repro_dsl_stdlib/packages/autoconf as cs_m1_autoconf
import repro_dsl_stdlib/packages/binutils as cs_m1_binutils
import repro_dsl_stdlib/packages/cargo_cli as cs_m1_cargo_cli
import repro_dsl_stdlib/packages/clang as cs_m1_clang
import repro_dsl_stdlib/packages/cmake as cs_m1_cmake
import repro_dsl_stdlib/packages/coreutils_install as cs_m1_coreutils_install
import repro_dsl_stdlib/packages/create_dmg as cs_m1_create_dmg
import repro_dsl_stdlib/packages/dpkg_deb as cs_m1_dpkg_deb
import repro_dsl_stdlib/packages/gcc as cs_m1_gcc
import repro_dsl_stdlib/packages/git as cs_m1_git
import repro_dsl_stdlib/packages/make as cs_m1_make
import repro_dsl_stdlib/packages/meson as cs_m1_meson
import repro_dsl_stdlib/packages/mktemp as cs_m1_mktemp
import repro_dsl_stdlib/packages/nim as cs_m1_nim
import repro_dsl_stdlib/packages/ninja as cs_m1_ninja
import repro_dsl_stdlib/packages/node as cs_m1_node
import repro_dsl_stdlib/packages/nsis as cs_m1_nsis
import repro_dsl_stdlib/packages/patchelf as cs_m1_patchelf
import repro_dsl_stdlib/packages/readelf as cs_m1_readelf
import repro_dsl_stdlib/packages/rpmbuild as cs_m1_rpmbuild
import repro_dsl_stdlib/packages/sh as cs_m1_sh
import repro_dsl_stdlib/packages/stylus as cs_m1_stylus
import repro_dsl_stdlib/packages/tar as cs_m1_tar
import repro_dsl_stdlib/packages/tree_sitter as cs_m1_tree_sitter
import repro_dsl_stdlib/packages/wix3_tools as cs_m1_wix3_tools
import repro_dsl_stdlib/packages/zig as cs_m1_zig

proc quoted(items: openArray[string]): string =
  ## A list rendered so that element boundaries survive: ``["a", "b c"]``.
  result = "["
  for i, item in items:
    if i > 0:
      result.add(", ")
    result.add(item.escape())
  result.add("]")

proc renderTypedOutputs(outputs: openArray[TypedOutputDef]): string =
  result = "["
  for i, td in outputs:
    if i > 0:
      result.add(", ")
    result.add("(field: " & td.fieldName.escape() & ", types: " &
      quoted(td.types) & ", path: " & td.pathExpr.escape() & ", src: " &
      td.sourceFile & ":" & $td.sourceLine & ")")
  result.add("]")

proc renderParam*(param: CliParamDef): string =
  ## One line per parameter, every field named, so a diff points at the
  ## field that moved.
  "param name=" & param.name.escape() &
    " nimType=" & param.nimType.escape() &
    " kind=" & $param.kind &
    " role=" & $param.ext.role &
    " format=" & $param.format &
    " placement=" & $param.placement &
    " repeated=" & $param.repeated &
    " position=" & $param.position &
    " alias=" & param.alias.escape() &
    " required=" & $param.required &
    " src=" & param.sourceFile & ":" & $param.sourceLine

proc renderCommand*(cmd: CliCommandDef): string =
  result = "command name=" & cmd.name.escape() &
    " path=" & quoted(cmd.path) &
    " entry=" & cmd.ext.providerEntrypointId.escape() &
    " src=" & cmd.sourceFile & ":" & $cmd.sourceLine & "\n"
  result.add("    dependencyPolicy=" & $cmd.ext.dependencyPolicy & "\n")
  result.add("    nonDeterminism=" & $cmd.ext.nonDeterminism &
    " justification=" & cmd.ext.nonDeterminismJustification.escape() & "\n")
  result.add("    subTools=" & quoted(cmd.ext.subTools) & "\n")
  result.add("    outputs=" & quoted(cmd.ext.outputFlags) & "\n")
  result.add("    optionalOutputs=" & quoted(cmd.ext.optionalOutputFlags) &
    "\n")
  result.add("    removeBeforeRun=" & quoted(cmd.ext.removeBeforeRunFlags) &
    "\n")
  result.add("    typedOutputs=" & renderTypedOutputs(cmd.ext.typedOutputs) &
    "\n")

proc fullCallArg(param: CliParamDef): PublicCliArg =
  ## The ``PublicCliArg`` the generated wrapper records for ``param`` when
  ## the caller supplies a value. Mirrors ``argBuilder`` in the ``package``
  ## macro: the helper is picked by role and by whether the type is
  ## ``seq[string]``, and the declaration's kind, position, alias, format,
  ## placement and repetition are passed through. The value is synthetic
  ## and derived from the parameter's name, so it is recognisable in argv.
  let isSeq = param.nimType.normalize == "seq[string]"
  let seqValue = @[param.name & "-a", param.name & "-b"]
  let strValue = param.name & "-v"
  template build(single, many: untyped): PublicCliArg =
    if isSeq:
      many(param.name, seqValue, param.kind, param.position, param.alias,
        param.format, param.placement, param.repeated)
    else:
      single(param.name, strValue, param.kind, param.position, param.alias,
        param.format, param.placement, param.repeated)
  case param.ext.role
  of carInput:
    result = build(inputArg, inputArgSeq)
  of carOutput:
    result = build(outputArg, outputArgSeq)
  of carOrdinary:
    case param.nimType.normalize
    of "bool":
      result = cliArg(param.name, true, param.kind, param.position,
        param.alias, param.format, param.placement, param.repeated)
    of "int":
      result = cliArg(param.name, 7, param.kind, param.position,
        param.alias, param.format, param.placement, param.repeated)
    else:
      result = build(cliArg, cliArgSeq)

proc renderArgv*(packageName, executableName: string;
                 cmd: CliCommandDef): string =
  var arguments: seq[PublicCliArg] = @[]
  for param in cmd.params:
    arguments.add(fullCallArg(param))
  let call = publicCliCall(packageName, executableName, cmd.name,
    cmd.ext.providerEntrypointId, arguments)
  let profile = PathOnlyToolProfile(
    resolvedExecutablePath: "/tool/" & executableName)
  "    argv=" & quoted(argvForCall(call, profile)) & "\n"

proc interfaceDigest*(pkg: PackageDef;
                      packages: openArray[PackageDef]): string =
  let bytes = encodeProjectInterfaceArtifact(
    artifactFor(toProjectInterface(pkg, packages)))
  var ctx: sha256
  ctx.init()
  if bytes.len > 0:
    ctx.update(bytes)
  "sha256:" & ($ctx.finish()).toLowerAscii()

proc renderPackage*(pkg: PackageDef; packages: openArray[PackageDef]): string =
  result = "package " & pkg.packageName.escape() & "\n"
  for exe in pkg.executables:
    result.add("  executable " & exe.exportName.escape() & " binary=" &
      exe.binaryName.escape() & " src=" & exe.sourceFile & ":" &
      $exe.sourceLine & "\n")
    for cmd in exe.commands:
      result.add("    " & renderCommand(cmd))
      for param in cmd.params:
        result.add("      " & renderParam(param) & "\n")
      result.add(renderArgv(pkg.packageName, exe.exportName, cmd))
  result.add("  interface " & interfaceDigest(pkg, packages) & "\n")

proc hasCliCommands(pkg: PackageDef): bool =
  for exe in pkg.executables:
    if exe.commands.len > 0:
      return true
  false

proc renderExternalToolSurface*(packages: openArray[PackageDef]): string =
  ## The whole surface: every package that declares at least one command,
  ## in package-name order (registration order is an import-order accident).
  var selected: seq[PackageDef] = @[]
  for pkg in packages:
    if pkg.hasCliCommands():
      selected.add(pkg)
  selected.sort(proc (a, b: PackageDef): int = cmp(a.packageName,
    b.packageName))
  for pkg in selected:
    result.add(renderPackage(pkg, packages))

# ``defineCliInterface`` is the second ``cli`` front end: it builds the same
# model but emits only wrapper procs, never a registered ``PackageDef``. Its
# surface is therefore captured by CALLING the wrappers it generates. The
# fixture uses every construct that front end accepts: a parameter-group
# template expanded in two commands, a flag before the subcommand, an
# interface-level ``dependencyPolicy``, ``call:`` and ``subcmd``, ``outputs``,
# and the ``alias`` / ``required`` / ``repeated`` / ``format`` /
# ``placement`` / ``position`` / ``role`` arguments.
defineCliInterface csM1Iface, "cs-m1-iface":
  template commonFlags() =
    boolFlag verbose is bool, alias = "-v"
    flag defines is seq[string], alias = "-D", format = concat,
      repeated = true
  flag config is string, alias = "--config", format = equals
  dependencyPolicy makeDepfile
  call:
    commonFlags()
    flag output is string, alias = "-o", role = output, required = true
    pos sources is seq[string], role = input, position = 1
    pos mode is string, position = 0
    outputs output
  subcmd "link":
    commonFlags()
    flag libs is seq[string], alias = "-l", format = concat, repeated = true,
      placement = before
    flag jobs is int, alias = "-j"
    pos objects is seq[string], role = input

proc renderCall*(act: BuildActionDef): string =
  ## A recorded typed-tool call: every argument the wrapper recorded, with
  ## its role, and the argv the engine renders from it.
  let call = act.call
  result = "  call " & call.packageName.escape() & " " &
    call.executableName.escape() & " " & call.subcommand.escape() &
    " entry=" & call.providerEntrypointId.escape() & "\n"
  result.add("    dependencyPolicy=" & $act.dependencyPolicy & "\n")
  for arg in call.arguments:
    result.add("    arg name=" & arg.name.escape() & " nimType=" &
      arg.nimType.escape() & " kind=" & $arg.kind & " role=" & $arg.role &
      " format=" & $arg.format & " placement=" & $arg.placement &
      " repeated=" & $arg.repeated & " position=" & $arg.position &
      " alias=" & arg.alias.escape() & " value=" &
      arg.encodedValue.escape() & "\n")
  let profile = PathOnlyToolProfile(
    resolvedExecutablePath: "/tool/" & call.executableName)
  result.add("    argv=" & quoted(argvForCall(call, profile)) & "\n")

proc renderInterfaceFixtureSurface*(): string =
  result = "defineCliInterface \"cs-m1-iface\"\n"
  resetBuildActionRegistry()
  result.add(renderCall(csM1Iface(config = "cfg", verbose = true,
    defines = @["A", "B=1"], output = "out.bin", sources = @["a.c", "b.c"],
    mode = "fast", actionId = "cs-m1-iface-call")))
  result.add(renderCall(csM1Iface.link(config = "cfg", verbose = true,
    defines = @["C"], libs = @["m", "z"], jobs = 4,
    objects = @["a.o", "b.o"], actionId = "cs-m1-iface-link")))
  resetBuildActionRegistry()

proc renderRegisteredExternalToolSurface*(): string =
  renderExternalToolSurface(registeredPackages()) &
    renderInterfaceFixtureSurface()
