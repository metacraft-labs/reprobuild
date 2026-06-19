## DSL-port M9.R.2b — clang stdlib package + Layer-2 operation
## implementations.
##
## clang's driver argv is broadly compatible with gcc's for the
## compile / link / archive / strip surface; v1 mirrors the gcc
## wrapper but invokes ``clang`` instead.

import repro_project_dsl
import repro_dsl_stdlib/types/library
import repro_dsl_stdlib/types/options

package clang:
  provisioning:
    nixPackage "nixpkgs#clang", executablePath = "bin/clang",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="

  executable clang:
    cli:
      dependencyPolicy automaticMonitor

      # The clang driver call mirrors gcc.nim's M9.R.2 surface.
      call:
        boolFlag pic is bool, alias = "-fPIC"
        boolFlag debug3 is bool, alias = "-g3"
        boolFlag compileOnly is bool, alias = "-c"
        boolFlag preprocessOnly is bool, alias = "-E"
        boolFlag makeDeps is bool, alias = "-M"
        boolFlag makeDepsMMD is bool, alias = "-MMD"
        boolFlag shared is bool, alias = "-shared"
        boolFlag staticLink is bool, alias = "-static"
        flag depfileOut is string,
          alias = "-MF",
          format = separate,
          role = output
        flag includes is seq[string],
          alias = "-include",
          role = input,
          repeated = true
        flag includeDirs is seq[string],
          alias = "-I",
          format = concat,
          repeated = true
        flag libDirs is seq[string],
          alias = "-L",
          format = concat,
          repeated = true
        flag libs is seq[string],
          alias = "-l",
          format = concat,
          repeated = true
        flag defines is seq[string],
          alias = "-D",
          format = concat,
          repeated = true
        flag optimization is string,
          alias = "-O",
          format = concat
        flag standard is string,
          alias = "-std=",
          format = concat
        flag output is string,
          alias = "-o",
          role = output,
          required = true
        pos source is string,
          role = input,
          position = 0

        outputs output

# ---------------------------------------------------------------------------
# DSL-port M9.R.2b — Layer-2 operation implementations (clang).
# Mirrors ``packages/gcc.nim``'s ``gccCompile`` / ``gccLink`` /
# ``gccArchive`` / ``gccStrip``.
# ---------------------------------------------------------------------------

{.experimental: "callOperator".}

proc clangApiHeaders(api: LibraryApi): seq[string] =
  if api.declared:
    for h in api.headers: result.add(h)
    for h in api.privateHeaders: result.add(h)

proc clangApiDefines(api: LibraryApi): seq[string] =
  if api.declared:
    for d in api.defines: result.add(d)
    for d in api.privateDefines: result.add(d)

proc clangApiLinks(api: LibraryApi): seq[string] =
  if api.declared:
    for l in api.links: result.add(l)
    for l in api.privateLinks: result.add(l)

proc clangCompile*(opts: CompileOptions): BuildActionDef =
  var includeDirs: seq[string] = @[]
  var defs: seq[string] = @[]
  for api in opts.inputs:
    for h in clangApiHeaders(api): includeDirs.add(h)
    for d in clangApiDefines(api): defs.add(d)
  for d in opts.defines: defs.add(d)
  let std = opts.standard
  if includeDirs.len == 0 and defs.len == 0 and std.len == 0:
    return clang(source = opts.source, output = opts.target,
      compileOnly = true)
  clang(source = opts.source, output = opts.target,
    compileOnly = true,
    includeDirs = includeDirs,
    defines = defs,
    standard = std)

proc clangLink*(opts: LinkOptions): BuildActionDef =
  var libs: seq[string] = @[]
  var libDirs: seq[string] = @[]
  for dep in opts.deps:
    for l in clangApiLinks(dep.api): libs.add(l)
    if dep.installPrefix.len > 0:
      libDirs.add(dep.installPrefix)
  let firstObj =
    if opts.objects.len > 0 and opts.objects[0].outputs.len > 0:
      opts.objects[0].outputs[0]
    else: opts.target
  result = clang(
    source = firstObj,
    output = opts.target,
    shared = (opts.kind == lokShared),
    staticLink = (opts.kind == lokStatic),
    libs = libs,
    libDirs = libDirs)

proc clangArchive*(opts: ArchiveOptions): BuildActionDef =
  ## Mirrors ``gccArchive`` — clang ships with ``llvm-ar`` (or routes
  ## to host ``ar``); v1 emits a ``binutils.ar`` invocation symmetric
  ## with the gcc path.
  result = BuildActionDef(
    call: PublicCliCall(
      packageName: "binutils",
      executableName: "ar",
      subcommand: "",
      arguments: @[]))
  let modifiers =
    if opts.modifiers.len > 0: opts.modifiers else: "rcs"
  result.call.arguments.add(PublicCliArg(
    name: "modifiers",
    kind: cpkPositional,
    position: 0,
    encodedValue: modifiers))
  result.call.arguments.add(PublicCliArg(
    name: "archive",
    kind: cpkPositional,
    position: 1,
    role: carOutput,
    encodedValue: opts.target))
  for i, obj in opts.objects:
    let path =
      if obj.outputs.len > 0: obj.outputs[0] else: ""
    result.call.arguments.add(PublicCliArg(
      name: "object" & $i,
      kind: cpkPositional,
      position: 2 + i,
      role: carInput,
      encodedValue: path))
  result.outputs.add(opts.target)

proc clangStrip*(opts: StripOptions): BuildActionDef =
  result = BuildActionDef(
    call: PublicCliCall(
      packageName: "binutils",
      executableName: "strip",
      subcommand: "",
      arguments: @[]))
  if opts.target.len > 0:
    result.call.arguments.add(PublicCliArg(
      name: "output",
      kind: cpkFlag,
      alias: "-o",
      format: cafSeparate,
      role: carOutput,
      encodedValue: opts.target))
    result.outputs.add(opts.target)
  for sym in opts.keepSymbols:
    result.call.arguments.add(PublicCliArg(
      name: "keep",
      kind: cpkFlag,
      alias: "-K",
      format: cafSeparate,
      encodedValue: sym))
  let inputPath =
    if opts.input.outputs.len > 0: opts.input.outputs[0] else: ""
  result.call.arguments.add(PublicCliArg(
    name: "input",
    kind: cpkPositional,
    position: 0,
    role: carInput,
    encodedValue: inputPath))
