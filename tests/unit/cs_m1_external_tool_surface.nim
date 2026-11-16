## Renders the external-tool surface of every in-tree ``cli:`` tool
## definition as canonical text, for the CS-M1 golden comparison
## (``t_cs_m1_external_tool_argv_unchanged.nim``).
##
## The surface has three parts per package, and each one is what a consumer
## of the CLI model actually sees:
##
## 1. **The model.** Every field of every ``CliCommandDef`` and
##    ``CliParamDef`` that a typed-tool wrapper or the engine reads, including
##    the reprobuild build-graph vocabulary (parameter roles, ``outputs``,
##    ``optionalOutputs``, ``removeBeforeRun``, ``subTools``,
##    ``dependencyPolicy``, ``inputCheckPolicy``, ``nonDeterminism``, the
##    provider entry point). The typed-tool wrapper procs are generated from
##    exactly these fields, so an identical model means identical wrappers.
## 2. **The argv.** Each command called with every parameter supplied, built
##    through the same runtime helpers the generated wrapper calls
##    (``cliArg`` / ``inputArg`` / ``outputArg`` and their ``Seq`` forms,
##    chosen by role and Nim type exactly as the wrapper generator chooses
##    them) and rendered by the engine's own ``argvForCall``.
## 3. **The interface artifact's command surface.** The package's
##    ``ProjectInterfaceArtifact`` is encoded with the real codec, DECODED
##    again, and its public executables, commands and parameters are
##    rendered field by field. That is the part of the artifact a consumer
##    of another project's tools binds against; going through the codec
##    means a field the codec drops or garbles shows up here.
##
## WHAT IS DELIBERATELY LEFT OUT, AND WHY. The rendering is a regression
## guard on what an external tool receives, so it leaves out what changes on
## edits that do not touch any tool's command line:
##
## * Source LINE numbers. Every site is rendered as its import path
##   (``repro_dsl_stdlib/packages/zig.nim``) without the line: a comment or
##   a provisioning record added above a ``cli:`` block moves every line
##   below it and changes no argv. Source FILES stay, since the test is
##   compiled with ``-d:reproInstalledPrefix`` (its ``.nim.cfg``), the mode
##   in which the DSL names its source sites the same way on every checkout.
## * A digest of the whole encoded interface artifact. The artifact also
##   carries the package's provisioning records, tool uses and the envelope
##   version, so its digest moved on every codec version bump and every
##   provisioning edit, none of which reaches argv. Part 3 renders the
##   artifact's command surface instead.
##
## ``static`` guards below fail the compile when a field is added to one of
## the reprobuild-side model types (or to the interface's command surface,
## or to the call record a typed wrapper hands the engine)
## without being rendered here or listed as deliberately excluded, so a new
## build-graph declaration cannot silently fall outside the comparison.

{.experimental: "callOperator".}

import std/[algorithm, macros, strutils]


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

# ---- Coverage guards --------------------------------------------------------
#
# Each list names every field of a type the rendering is meant to cover:
# either rendered above/below, or excluded with the reason beside it. A field
# added to the type and named in neither list fails the compile with a
# message naming it, so the author decides, in this file, whether it reaches
# an external tool. Only the reprobuild-side types are guarded; the clispec
# library's own ``CliParam`` / ``CliCommand`` fields that reach argv are the
# ones ``fullCallArg`` passes to the argv builders (kind, position, alias,
# format, placement, repetition), and all of them are rendered. That holds
# only while the call record carries nothing else, so ``PublicCliArg`` and
# ``PublicCliCall`` are guarded too.

macro requireCovered(T: typedesc; covered: static[seq[string]]): untyped =
  ## Compile-time check that every field of the object type ``T`` is in
  ## ``covered``.
  var impl = getTypeImpl(T)
  if impl.kind == nnkBracketExpr:
    impl = getTypeImpl(impl[1])
  impl.expectKind(nnkObjectTy)
  for def in impl[2]:
    def.expectKind(nnkIdentDefs)
    for i in 0 ..< def.len - 2:
      let name = $def[i]
      if name notin covered:
        error("cs_m1_external_tool_surface: " & $T & "." & name &
          " is neither rendered nor listed as excluded; render it (if it " &
          "can reach an external tool or its edges) or add it to the " &
          "exclusion list with the reason", def[i])
  result = newEmptyNode()

requireCovered(ReproCliParamExt, @["role"])
requireCovered(ReproCliCommandExt, @["dependencyPolicy", "nonDeterminism",
  "subTools", "inputCheckPolicy", "nonDeterminismJustification",
  "providerEntrypointId", "optionalOutputFlags", "removeBeforeRunFlags",
  "outputFlags", "typedOutputs"])
requireCovered(TypedOutputDef, @["fieldName", "types", "pathExpr",
  "sourceFile",
  "sourceLine"])   # excluded: a line number (module header)
requireCovered(InterfaceExecutable, @["exportName", "binaryName", "commands",
  "location"])     # excluded: a source location (module header)
requireCovered(InterfaceCommand, @["name", "params", "providerEntrypointId",
  "location"])     # excluded: a source location
requireCovered(InterfaceParam, @["name", "nimType", "kind", "position",
  "alias", "required",
  "location"])     # excluded: a source location
# The records a generated wrapper hands the engine, from which
# ``argvForCall`` builds the command line. ``fullCallArg`` / ``renderArgv``
# fill every field of both, and ``renderCall`` prints every field of a
# recorded call; a new field here may change argv without passing through
# any field guarded above.
requireCovered(PublicCliArg, @["name", "nimType", "kind", "role", "format",
  "placement", "repeated", "position", "alias", "encodedValue"])
requireCovered(PublicCliCall, @["packageName", "executableName", "subcommand",
  "providerEntrypointId", "arguments"])

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
      td.sourceFile & ")")
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
    " src=" & param.sourceFile

proc renderCommand*(cmd: CliCommandDef): string =
  result = "command name=" & cmd.name.escape() &
    " path=" & quoted(cmd.path) &
    " entry=" & cmd.ext.providerEntrypointId.escape() &
    " src=" & cmd.sourceFile & "\n"
  result.add("    dependencyPolicy=" & $cmd.ext.dependencyPolicy & "\n")
  result.add("    inputCheckPolicy=" & $cmd.ext.inputCheckPolicy & "\n")
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

proc renderInterfaceSurface*(pkg: PackageDef;
                             packages: openArray[PackageDef]): string =
  ## The command surface of ``pkg``'s interface artifact, read back through
  ## the codec: encode the artifact exactly as an extraction writes it,
  ## decode it, and render every public executable, command and parameter.
  ## Source locations are left out (see the module header).
  let bytes = encodeProjectInterfaceArtifact(
    artifactFor(toProjectInterface(pkg, packages)))
  let decoded = decodeProjectInterfaceArtifact(bytes).projectInterface
  for exe in decoded.publicExecutables:
    result.add("  interface executable " & exe.exportName.escape() &
      " binary=" & exe.binaryName.escape() & "\n")
    for cmd in exe.commands:
      result.add("    interface command name=" & cmd.name.escape() &
        " entry=" & cmd.providerEntrypointId.escape() & "\n")
      for param in cmd.params:
        result.add("      interface param name=" & param.name.escape() &
          " nimType=" & param.nimType.escape() & " kind=" & $param.kind &
          " position=" & $param.position & " alias=" & param.alias.escape() &
          " required=" & $param.required & "\n")

proc renderPackage*(pkg: PackageDef; packages: openArray[PackageDef]): string =
  result = "package " & pkg.packageName.escape() & "\n"
  for exe in pkg.executables:
    result.add("  executable " & exe.exportName.escape() & " binary=" &
      exe.binaryName.escape() & " src=" & exe.sourceFile & "\n")
    for cmd in exe.commands:
      result.add("    " & renderCommand(cmd))
      for param in cmd.params:
        result.add("      " & renderParam(param) & "\n")
      result.add(renderArgv(pkg.packageName, exe.exportName, cmd))
  result.add(renderInterfaceSurface(pkg, packages))

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
