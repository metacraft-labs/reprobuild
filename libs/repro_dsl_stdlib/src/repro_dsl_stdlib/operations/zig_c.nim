## The C operations (`compile`, `link`, `archive`) for a `cross_zig`
## target: Reprobuild-Standard-Library.md §"Worked Example:
## Cross-Compilation", step 4 -- a typed-tool call reads the active
## `CrossTarget` and folds its flags into the argv it emits, so a recipe built
## with `repro build --target=<triple>` is the same source as its native
## build. Under a zig target the toolchain is `zig cc` / `zig ar` (one driver
## carrying its own musl and compiler-rt, `adapters/cross_zig`), and the
## adapter's `cFlags` (`-target <zig triple> -mcpu=<cpu>`) are the injected
## flags.
##
## The recipe declares `zig` in `nativeBuildDeps:` once, unconditionally, as
## the catalog's cross-capable recipes do: dependency blocks are resolved at
## compile time, not from the solved target, and a native build has it on
## PATH and never runs it. A recipe that does not is refused here by name,
## rather than failing later at tool resolution.

import std/[os, strutils]

import repro_project_dsl

import ../active_context
import ../adapters/cross_zig
import ../interfaces/cross_target
import ../types/library
import ../types/options
import ./buildtype
import ../packages/zig as zig_module

proc activeZigCrossTarget*(): CrossTarget =
  ## The active `CrossTarget` when it is a zig one, else nil. Read through
  ## `peekActiveCrossTarget`, so asking does not lift the fail-closed guard
  ## for a constructor that does not thread the target.
  let ct = peekActiveCrossTarget()
  if isZigCrossTarget(ct): ct else: nil

proc requireZigDeclared*(caller: string) =
  ## Refuse when the package building now has not declared `zig` as a
  ## build-host tool: its typed `zig cc` edge would have no tool to run.
  let state = tryCurrentBuildState()
  if state == nil:
    return
  for pkg in registeredPackages():
    if pkg.packageName != state.packageName:
      continue
    for use in pkg.nativeBuildDeps:
      if use.packageSelector == "zig":
        return
    raise newException(ValueError, "recipe '" & state.packageName & "': " &
      caller & " builds for the zig target '" & peekActiveCrossTarget().triple &
      "' with `zig cc`, but the package does not declare `zig` in " &
      "`nativeBuildDeps:`. Add `\"zig >=0.13 <0.15\"` there (it is unused by " &
      "a native build).")

proc targetKeyedPath*(path: string): string =
  ## ``path`` as a build for the active target writes it: unchanged for a
  ## native build, and under ``--target`` with its top-level component (or,
  ## for an absolute path, its directory) spelled ``<name>@<triple>`` -- the
  ## rule ``.repro/output/`` entries follow (``targetKeyedOutputName``,
  ## CLI/build.md §"Cross Targets: `--target`") -- so a native and a target
  ## build of one recipe write different files and coexist.
  if path.len == 0 or effectiveInstallMirrorTarget().len == 0:
    return path
  if path.isAbsolute:
    return path.parentDir.parentDir /
      targetKeyedOutputName(path.parentDir.extractFilename) /
      path.extractFilename
  let parts = path.replace('\\', '/').split('/')
  result = targetKeyedOutputName(parts[0])
  for part in parts[1 .. ^1]:
    result = result / part

proc targetKeyedDir*(dir: string): string =
  ## A DIRECTORY a target build writes (a constructor's build tree), keyed
  ## on its LAST component: ``.repro/build/zlib-native`` becomes
  ## ``.repro/build/zlib-native@<triple>`` beside the native one, not a new
  ## ``.repro@<triple>`` beside ``.repro``. Unchanged for a native build.
  if dir.len == 0 or effectiveInstallMirrorTarget().len == 0:
    return dir
  let trimmed = dir.strip(leading = false, chars = {'/', '\\'})
  let parent = trimmed.parentDir
  let name = targetKeyedOutputName(trimmed.extractFilename)
  if parent.len == 0: name else: parent / name

proc libraryHeaderDirs(api: LibraryApi): seq[string] =
  if api.declared:
    for h in api.headers: result.add(h)
    for h in api.privateHeaders: result.add(h)

proc libraryDefines(api: LibraryApi): seq[string] =
  if api.declared:
    for d in api.defines: result.add(d)
    for d in api.privateDefines: result.add(d)

proc libraryLinks(api: LibraryApi): seq[string] =
  if api.declared:
    for l in api.links: result.add(l)
    for l in api.privateLinks: result.add(l)

proc zigCompile*(opts: CompileOptions; ct: CrossTarget): BuildActionDef =
  var includeDirs: seq[string]
  var defs: seq[string]
  for api in opts.inputs:
    for h in libraryHeaderDirs(api): includeDirs.add(h)
    for d in libraryDefines(api): defs.add(d)
  for d in opts.defines: defs.add(d)
  let bt = currentCompileFlags()
  zig_module.zig.cc(
    targetArgs = ct.cFlags,
    sources = @[opts.source],
    output = targetKeyedPath(opts.target),
    compileOnly = true,
    pic = opts.pic,
    includeDirs = includeDirs,
    defines = defs,
    standard = opts.standard,
    optimization = bt.optimization,
    debug3 = bt.debugInfo,
    extra = opts.extra)

proc zigArchive*(opts: ArchiveOptions): BuildActionDef =
  var objects: seq[string]
  for obj in opts.objects:
    for o in obj.outputs: objects.add(o)
  zig_module.zig.ar(
    modifiers = (if opts.modifiers.len > 0: opts.modifiers else: "rcs"),
    archive = targetKeyedPath(opts.target), objects = objects,
    after = opts.objects)

proc zigSharedLinkCompilerRtArgs*(linkArgs: seq[string]; ct: CrossTarget):
    tuple[args: seq[string], wrappers: BuildActionDef] =
  ## What a `-shared` link for `ct` adds so that zig's compiler-rt is local
  ## in the library, and the edge it must order after (the wrapper edge, or
  ## the merge edge that writes the link's own script): the same rule the
  ## `cc` / `c++` wrappers apply (`adapters/cross_zig`,
  ## `zigCrossCompilerRtMap`), here for the typed `zig cc` edge, which does
  ## not run through them. Nothing on a row whose libraries export none of
  ## compiler-rt.
  ##
  ## A link that names no version script of its own gets the map the wrapper
  ## edge writes beside the wrappers. zig hands the linker only the last
  ## version script of a link, so a link that names its own gets no second
  ## one: its script must already make compiler-rt local -- the output of
  ## `emitZigCrossVersionScriptAction`, or a script that carries `local: *;`
  ## -- and is refused by name otherwise. `--undefined-version` because a
  ## library need not pull in every listed helper.
  ##
  ## Before this, an armv7 library linked by `link(kind = lokShared)`
  ## exported 385 compiler-rt symbols under zig 0.13.0 (measured 2026-11-17,
  ## `t_zig_cross_shared_library_exports`), so a consumer bound its own
  ## helper calls to the library and failed to load against a target
  ## system's build of that soname, which exports none of them.
  let t = zigCrossTarget(ct.triple)
  if zigCrossCompilerRtMap(t).len == 0:
    return
  let own = zigCrossOwnVersionScript(linkArgs)
  let root = activeProviderProjectRoot()
  if own.len == 0:
    let state = tryCurrentBuildState()
    let pkg = if state == nil: "" else: state.packageName
    result.wrappers = emitZigCrossWrappersAction(root, pkg, ct.triple)
    result.args.add("-Wl,--version-script=" &
      zigCrossWrapperDir(root, ct.triple) / ZigCrossCompilerRtMapName)
  else:
    # A script the merge edge writes is accepted, and the link orders after
    # that edge (it must be registered first). Any other script is read now,
    # when the graph is built, as the wrappers read it when they run: so it
    # must be a source file, not the output of some other edge.
    let path = if own.isAbsolute or root.len == 0: own else: root / own
    for act in registeredBuildActions():
      if act.commandStatsId == "zig-cross.version-script":
        for o in act.outputs:
          let op = if o.isAbsolute or root.len == 0: o else: root / o
          if normalizedPath(op) == normalizedPath(path):
            result.wrappers = act
    if result.wrappers.id.len == 0:
      if not fileExists(path):
        raise newException(ValueError, "zig cc (" & ct.triple & "): the " &
          "version script " & own & " does not exist when the graph is " &
          "built, and no emitZigCrossVersionScriptAction edge registered " &
          "before this link writes it; a shared-library link for this " &
          "target reads its own script then, to check that it makes zig's " &
          "compiler-rt local")
      if not zigCrossVersionScriptCovers(readFile(path)):
        raise newException(ValueError, "zig cc (" & ct.triple & "): the " &
          "version script " & own & " leaves zig's compiler-rt exported " &
          "from this shared library; make every unlisted symbol local " &
          "(local: *;) or merge it with cross_zig's " &
          "emitZigCrossVersionScriptAction")
  result.args.add("-Wl,--undefined-version")

proc zigLink*(opts: LinkOptions; ct: CrossTarget): BuildActionDef =
  ## Every object the link names goes on the line (not only the first). A
  ## static library is an archive, so it is `zig ar`, not a `-static` link.
  if opts.kind == lokStatic:
    return zigArchive(ArchiveOptions(objects: opts.objects,
      target: opts.target, modifiers: "rcs"))
  var objects: seq[string]
  for obj in opts.objects:
    for o in obj.outputs: objects.add(o)
  var libs: seq[string]
  var libDirs: seq[string]
  for dep in opts.deps:
    for l in libraryLinks(dep.api): libs.add(l)
    # Where the dep's own edge writes it, which is where ``-l`` must look;
    # never ``installPrefix``, a staged-install path no edge writes.
    if dep.linkDir.len > 0 and dep.linkDir notin libDirs:
      libDirs.add(dep.linkDir)
  var extra = opts.extra
  # After every library ``-l`` names, not only the objects.
  var after = opts.objects & linkPrerequisites(opts.deps)
  if opts.kind == lokShared:
    let compilerRt = zigSharedLinkCompilerRtArgs(opts.extra, ct)
    for a in compilerRt.args: extra.add(a)
    if compilerRt.wrappers.id.len > 0: after.add(compilerRt.wrappers)
  zig_module.zig.cc(
    targetArgs = ct.linkFlags,
    sources = objects,
    output = targetKeyedPath(opts.target),
    shared = (opts.kind == lokShared),
    soname = (if opts.kind == lokShared: opts.soname else: ""),
    libs = libs,
    libDirs = libDirs,
    extra = extra,
    after = after)

proc nimCpuOf*(triple: string): string =
  ## Nim's `--cpu:` spelling of a triple's CPU
  ## (https://nim-lang.org/docs/nimc.html#crossminuscompilation).
  let cpu = triple.split('-')[0]
  if cpu.startsWith("armv7") or cpu == "arm": "arm"
  elif cpu == "aarch64": "arm64"
  elif cpu == "x86_64": "amd64"
  elif cpu in ["i386", "i486", "i586", "i686"]: "i386"
  elif cpu == "riscv64": "riscv64"
  else:
    raise newException(ValueError, "no Nim --cpu: for the triple '" &
      triple & "'")

type ZigNimCross* = object
  ## What a Nim compile needs to build for a zig target.
  wrappers*: BuildActionDef   ## writes the `cc` wrapper; order after it
  cpu*, os*, ccExe*: string

proc zigNimCross*(ct: CrossTarget; caller: string): ZigNimCross =
  requireZigDeclared(caller)
  let state = tryCurrentBuildState()
  let pkg = if state == nil: "" else: state.packageName
  let root = activeProviderProjectRoot()
  result.wrappers = emitZigCrossWrappersAction(root, pkg, ct.triple)
  result.cpu = nimCpuOf(ct.triple)
  result.os = "linux"
  result.ccExe = zigCrossWrapperDir(root, ct.triple) / "cc"
