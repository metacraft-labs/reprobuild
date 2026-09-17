## DSL-port M9.R.2b — clang stdlib package + Layer-2 operation
## implementations.
##
## clang's driver argv is broadly compatible with gcc's for the
## compile / link / archive / strip surface; v1 mirrors the gcc
## wrapper but invokes ``clang`` instead.

import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin
import repro_dsl_stdlib/types/library
import repro_dsl_stdlib/types/options
import repro_dsl_stdlib/operations/buildtype

package clang:
  provisioning:
    nixPackage "nixpkgs#clang", executablePath = "bin/clang",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash
    # Windows: the official LLVM release tarball. Agent Harbor needs it for
    # two distinct reasons and both want the whole toolchain rather than the
    # driver alone — `clang-cl` is the compiler its arm64 slice selects for
    # aws-lc-sys's ARM assembly, and several native build scripts reach for
    # `llvm-ar` / `llvm-objcopy` from the same bin dir.
    #
    # The archive carries a `clang+llvm-<ver>-<triple>/` wrapper holding
    # `bin/`, `lib/` and `include/`; clang resolves its resource directory
    # relative to its own location, so stripComponents=1 flattens the wrapper
    # and keeps that tree rather than isolating the driver from its headers.
    #
    # Digests are the `LLVM_SHA256_*` values Agent Harbor's toolchain pin
    # file already carried, harvested independently of this catalog.
    #
    # What the prunes drop, and why each group is safe to drop. The Windows
    # release is 3.9 GB unpacked, of which `bin` alone is 3.2 GB: LLVM ships
    # one statically linked ~50-100 MB executable per tool, so tools nobody
    # here invokes are not free. The keep-set is "compile, link, and inspect
    # object files"; what goes is everything serving a different trade.
    #
    #   * The debugger (`lldb*`, `liblldb.dll`). 161 MB. The one reference to
    #     lldb in the consuming tree is a macOS-only backtrace fallback in
    #     agentharborfs-e2e-tests, which never runs against this Windows
    #     prefix.
    #   * The macOS cross tools (`ld64.lld`, `dsymutil`, `llvm-libtool-
    #     darwin`, `llvm-lipo`, `llvm-otool`, `llvm-readtapi`,
    #     `clang-installapi`). 203 MB. This entry is the x86_64-windows
    #     slice; Mach-O output is not one of its jobs.
    #   * LLVM's own development tools (`bugpoint`, `llvm-reduce`,
    #     `llvm-stress`, `llvm-exegesis`, `llvm-c-test`,
    #     `verify-uselistorder`, `reduce-chunk-list`). 214 MB. These exist to
    #     debug LLVM itself, not to build with it.
    #   * The interpreter / JIT surface (`clang-repl`, `lli`, `llvm-jitlink`,
    #     `llvm-rtdyld`). 160 MB.
    #   * The clang-tools refactoring suite (`clang-change-namespace`,
    #     `clang-move`, `clang-refactor`, `clang-reorder-fields`,
    #     `clang-include-fixer`, `clang-include-cleaner`, `clang-doc`,
    #     `clang-query`, `modularize`, `pp-trace`, `find-all-symbols`,
    #     `c-index-test`, `clang-check`). 434 MB. Nothing in the tree invokes
    #     any of them; `clang-format`, `clang-tidy`, `clangd` and
    #     `clang-scan-deps` — the ones an editor or a build does reach for —
    #     all stay.
    #
    # The compiler drivers, the lld linkers, libclang/LLVM-C/LTO, the
    # binutils-equivalent `llvm-*` tools and the whole of `lib/` and
    # `include/` are untouched, so `clang-cl` still compiles aws-lc-sys and
    # `llvm-ar` and friends are still where a build script expects them.
    tarball url = "https://github.com/llvm/llvm-project/releases/download/llvmorg-21.1.7/clang+llvm-21.1.7-x86_64-pc-windows-msvc.tar.xz",
      sha256 = "70a2b73f2f14f787557f90abf380e7170b54e97b893218999144de5284b4f8f8",
      archiveType = "tar.xz",
      stripComponents = 1,
      prune = "bin/lldb.exe",
      prune = "bin/lldb-dap.exe",
      prune = "bin/lldb-instr.exe",
      prune = "bin/lldb-server.exe",
      prune = "bin/lldb-argdumper.exe",
      prune = "bin/liblldb.dll",
      prune = "bin/ld64.lld.exe",
      prune = "bin/dsymutil.exe",
      prune = "bin/llvm-libtool-darwin.exe",
      prune = "bin/llvm-lipo.exe",
      prune = "bin/llvm-otool.exe",
      prune = "bin/llvm-readtapi.exe",
      prune = "bin/clang-installapi.exe",
      prune = "bin/bugpoint.exe",
      prune = "bin/llvm-reduce.exe",
      prune = "bin/llvm-stress.exe",
      prune = "bin/llvm-exegesis.exe",
      prune = "bin/llvm-c-test.exe",
      prune = "bin/verify-uselistorder.exe",
      prune = "bin/reduce-chunk-list.exe",
      prune = "bin/clang-repl.exe",
      prune = "bin/lli.exe",
      prune = "bin/llvm-jitlink.exe",
      prune = "bin/llvm-rtdyld.exe",
      prune = "bin/clang-change-namespace.exe",
      prune = "bin/clang-move.exe",
      prune = "bin/clang-refactor.exe",
      prune = "bin/clang-reorder-fields.exe",
      prune = "bin/clang-include-fixer.exe",
      prune = "bin/clang-include-cleaner.exe",
      prune = "bin/clang-doc.exe",
      prune = "bin/clang-query.exe",
      prune = "bin/modularize.exe",
      prune = "bin/pp-trace.exe",
      prune = "bin/find-all-symbols.exe",
      prune = "bin/c-index-test.exe",
      prune = "bin/clang-check.exe",
      executablePath = "bin/clang.exe",
      packageId = "llvm@21.1.7",
      cpu = "x86_64",
      os = "windows",
      lockIdentity = "tarball:llvm@21.1.7:windows-x86_64:sha256:70a2b73f2f14f787557f90abf380e7170b54e97b893218999144de5284b4f8f8"
    tarball url = "https://github.com/llvm/llvm-project/releases/download/llvmorg-21.1.7/clang+llvm-21.1.7-aarch64-pc-windows-msvc.tar.xz",
      sha256 = "e0054932e7ca46ad5f06c66a0d7405e3ed0d5c7dd47be0d8d172cfcb99f8a03f",
      archiveType = "tar.xz",
      stripComponents = 1,
      prune = "bin/lldb.exe",
      prune = "bin/lldb-dap.exe",
      prune = "bin/lldb-instr.exe",
      prune = "bin/lldb-server.exe",
      prune = "bin/lldb-argdumper.exe",
      prune = "bin/liblldb.dll",
      prune = "bin/ld64.lld.exe",
      prune = "bin/dsymutil.exe",
      prune = "bin/llvm-libtool-darwin.exe",
      prune = "bin/llvm-lipo.exe",
      prune = "bin/llvm-otool.exe",
      prune = "bin/llvm-readtapi.exe",
      prune = "bin/clang-installapi.exe",
      prune = "bin/bugpoint.exe",
      prune = "bin/llvm-reduce.exe",
      prune = "bin/llvm-stress.exe",
      prune = "bin/llvm-exegesis.exe",
      prune = "bin/llvm-c-test.exe",
      prune = "bin/verify-uselistorder.exe",
      prune = "bin/reduce-chunk-list.exe",
      prune = "bin/clang-repl.exe",
      prune = "bin/lli.exe",
      prune = "bin/llvm-jitlink.exe",
      prune = "bin/llvm-rtdyld.exe",
      prune = "bin/clang-change-namespace.exe",
      prune = "bin/clang-move.exe",
      prune = "bin/clang-refactor.exe",
      prune = "bin/clang-reorder-fields.exe",
      prune = "bin/clang-include-fixer.exe",
      prune = "bin/clang-include-cleaner.exe",
      prune = "bin/clang-doc.exe",
      prune = "bin/clang-query.exe",
      prune = "bin/modularize.exe",
      prune = "bin/pp-trace.exe",
      prune = "bin/find-all-symbols.exe",
      prune = "bin/c-index-test.exe",
      prune = "bin/clang-check.exe",
      executablePath = "bin/clang.exe",
      packageId = "llvm@21.1.7",
      cpu = "aarch64",
      os = "windows",
      lockIdentity = "tarball:llvm@21.1.7:windows-aarch64:sha256:e0054932e7ca46ad5f06c66a0d7405e3ed0d5c7dd47be0d8d172cfcb99f8a03f"

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
  let bt = currentCompileFlags()
  clang(source = opts.source, output = opts.target,
    compileOnly = true,
    includeDirs = includeDirs,
    defines = defs,
    standard = std,
    optimization = bt.optimization,
    debug3 = bt.debugInfo)

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
