## C / C++ (plain Make) language convention (Tier 2b) — Mode A
## "fine-grained" plugin.
##
## Recognises a project whose ``reprobuild.nim`` ``uses:`` block lists a
## C compiler (``gcc`` / ``clang``) plus ``make``, AND ships a
## ``Makefile`` (or ``GNUmakefile``) at the project root, AND declares at
## least one ``executable`` or ``library`` member. ``CMakeLists.txt`` at
## the root is a hard reject (CMake projects belong to the Tier 2c CMake
## direct provider).
##
## The convention spec (``reprobuild-specs/Language-Conventions/C-Cpp-Make.md``
## §"Mode A — Fine-grained build graph") prescribes parsing
## ``make --print-data-base -n`` to lift recognised rule shapes
## (``%.o: %.c``, ``<bin>: <objs>``, ``lib<n>.a: <objs>``) into reprobuild
## per-source + link/archive edges. That parser is non-trivial — the
## ``make`` database dump format is undocumented + version-sensitive — so
## the M17 surface ships **Option B**: a layout-based heuristic that
## walks the conventional source tree (``<projectRoot>/src``) and emits
## per-source ``gcc -c`` + per-target ``gcc -o`` / ``ar rcs`` actions
## directly. The Makefile sits in the source tree as a documentation
## artifact; the convention's heuristic must agree with it (the M9 harness
## verifies the produced binary's behavior end-to-end).
##
## **Layout rules (Option B)**:
##
##   * For each ``executable <name>`` member:
##     - look for ``src/main.c`` (single-binary layout — bare ``main.c``),
##       or ``src/<name>.c``, or ``src/<name>/main.c``.
##     - compile EVERY sibling ``.c`` file in the same directory.
##     - emit one ``gcc -c`` per source, then one ``gcc -o <name>[.exe]``
##       linking them.
##   * For each ``library <name>`` member (defaults to static at M17):
##     - look for ``src/<name>.c`` (single-source library — e.g.
##       ``src/greet.c``) OR ``src/<name>/*.c`` (multi-source layout).
##       Header files (``.h``) under the same directory are NOT compiled
##       — they're picked up via the per-source depfile.
##     - emit one ``gcc -c`` per source, then ``ar rcs lib<name>.a <objs>``.
##
## **Per-source compile argv**::
##
##     gcc -c -O2 -Wall -Wextra -MD -MF <obj>.d -I src -I src/include
##         -I include -o <obj> <src>
##
## ``-MD -MF`` produces the depfile reprobuild consumes via
## ``makeDepfilePolicy(<depfile>)`` so header edits invalidate the action.
## The ``-I`` flags cover the two conventional include patterns (top-level
## ``include/`` and ``src/`` itself when sources include their own
## headers — the library-static fixture's ``src/greet.c`` ``#include``s
## ``"greet.h"`` from ``src/``). The ``-O2 -Wall -Wextra`` defaults mirror
## the fixture Makefile's defaults.
##
## **Tooling preference**: ``gcc`` first via ``findExe``; ``clang`` as
## the fallback. ``ar`` is similarly resolved from ``findExe`` with a
## literal-token fallback. The resolved absolute paths are baked into the
## emitted argv so the action stays self-contained.
##
## **Out of scope for M17 (handled by ``recognize`` returning false)**:
##
##   * ``CMakeLists.txt`` at the project root (CMake convention's job).
##   * ``configure.ac`` / ``Makefile.am`` at the project root (Autotools
##     convention's job — c_cpp_autotools.nim).
##   * Shared libraries (``lkShared`` / ``lkBoth`` — the DSL doesn't yet
##     thread ``kind:`` through to plain ``library`` members for C, and
##     the M17 fixtures are static-only).
##   * C++ sources (``.cc`` / ``.cpp`` / ``.cxx``) — the M17 fixtures are
##     pure C; C++ recognition lands when a fixture exercises it.
##   * Cross-compilation (``CC=<triple>-gcc``).
##
## **Caveats**:
##   * Requires ``gcc`` or ``clang`` AND ``ar`` on PATH at convention-emit
##     time. When the compiler is missing, ``recognize`` returns ``false``
##     so dispatch falls through to the "no convention matched" diagnostic.
##   * The convention's heuristic source enumeration assumes the Makefile
##     compiles every ``.c`` file in the matched directory. If the
##     Makefile is selective (e.g. ``foo.c`` is compiled but ``bar.c`` is
##     not), the convention will over-compile. The M17 fixtures fit the
##     "compile every .c" pattern.

import std/[algorithm, os, strutils]

import repro_core
import repro_provider_runtime
import repro_project_dsl
import repro_standard_provider/convention
import repro_standard_provider/conventions/fetch_action

const
  ScratchDirName* = ".repro/build"
    ## Top-level scratch directory under the project root the C/C++ Make
    ## convention writes into. Identical to the other language
    ## conventions' ``ScratchDirName``.

type
  CCppMemberKind = enum
    ccmkExecutable
    ccmkLibraryStatic

  CCppMember = object
    ## Single ``executable <name>`` or ``library <name>`` declaration in
    ## ``reprobuild.nim``.
    name: string
    kind: CCppMemberKind

  CCppEmitTarget = object
    ## Resolved member: the kind plus the directory holding its sources
    ## and the list of ``.c`` files to compile. Computed by walking the
    ## conventional layout in ``resolveTarget``.
    member: CCppMember
    sourceDir: string
      ## Directory containing the per-source ``.c`` files.
    sourceFiles: seq[string]
      ## Absolute paths to the ``.c`` files for this member.

proc readReprobuildSource(projectRoot: string): string =
  ## Read the project file (``repro.nim`` or legacy ``reprobuild.nim``)
  ## or return the empty string. See ``repro_core/project_file``.
  let match = resolveProjectFile(projectRoot)
  if match.path.len == 0:
    return ""
  try:
    readFile(extendedPath(match.path))
  except CatchableError:
    ""

proc usesIncludesCCppMake(source: string): bool =
  ## True when the ``uses:`` block names ``gcc`` / ``clang`` AND ``make``.
  ## Mirrors the other conventions' ``usesIncludes*`` line-scan. The
  ## recognition tests both flavors (the spec demands ``make`` plus a
  ## compiler from ``uses:``; either gcc or clang qualifies).
  if source.len == 0:
    return false
  var sawCompiler = false
  var sawMake = false
  var inBlock = false
  proc consume(token: string) {.closure.} =
    if token == "gcc" or token == "clang":
      sawCompiler = true
    if token == "make":
      sawMake = true
  for rawLine in source.splitLines():
    var line = rawLine
    let commentIdx = line.find('#')
    if commentIdx >= 0:
      line = line[0 ..< commentIdx]
    let stripped = line.strip()
    if stripped.len == 0:
      if inBlock:
        inBlock = false
      continue
    if inBlock:
      let leading = line.len > 0 and line[0] in {' ', '\t'}
      if not leading:
        inBlock = false
      else:
        for raw in stripped.split({',', ' ', '\t'}):
          let entry = raw.strip(chars = {' ', '\t', '"', '\'', ',', ';'})
          if entry.len == 0:
            continue
          let firstToken = entry.split({' ', '\t', '>', '<', '='})[0]
          consume(firstToken)
        continue
    if stripped.startsWith("uses:"):
      let payload = stripped[5 .. ^1].strip()
      if payload.len == 0:
        inBlock = true
      else:
        var clean = payload
        if clean.startsWith("["):
          clean = clean[1 .. ^1]
        if clean.endsWith("]"):
          clean = clean[0 ..< ^1]
        for raw in clean.split({',', ' ', '\t'}):
          let entry = raw.strip(chars = {' ', '\t', '"', '\'', ',', ';'})
          if entry.len == 0:
            continue
          let firstToken = entry.split({' ', '\t', '>', '<', '='})[0]
          consume(firstToken)
  sawCompiler and sawMake

proc extractExecutables(source: string): seq[string] =
  ## Heuristic line-scan for ``executable <name>`` declarations.
  for rawLine in source.splitLines():
    var line = rawLine
    let commentIdx = line.find('#')
    if commentIdx >= 0:
      line = line[0 ..< commentIdx]
    let stripped = line.strip()
    if not stripped.startsWith("executable"):
      continue
    if stripped.len > len("executable") and
        stripped[len("executable")] notin {' ', '\t'}:
      continue
    let rest = stripped[len("executable") .. ^1].strip()
    if rest.len == 0:
      continue
    var name = ""
    for ch in rest:
      if ch in {' ', '\t', ':', ','}:
        break
      name.add(ch)
    if name.len > 0:
      result.add(name)

proc extractLibraries(source: string): seq[string] =
  ## Heuristic line-scan for ``library <name>`` declarations. M17 treats
  ## every ``library`` as ``kind: static`` (the DSL doesn't yet thread
  ## ``kind:`` through to the C convention; shared/both is a follow-up).
  for rawLine in source.splitLines():
    var line = rawLine
    let commentIdx = line.find('#')
    if commentIdx >= 0:
      line = line[0 ..< commentIdx]
    let stripped = line.strip()
    if not stripped.startsWith("library"):
      continue
    if stripped.len > len("library") and
        stripped[len("library")] notin {' ', '\t'}:
      continue
    let rest = stripped[len("library") .. ^1].strip()
    if rest.len == 0:
      continue
    var name = ""
    for ch in rest:
      if ch in {' ', '\t', ':', ','}:
        break
      name.add(ch)
    if name.len > 0:
      result.add(name)

proc extractMembers(source: string): seq[CCppMember] =
  ## Combine executables + libraries into a single ordered seq.
  for name in extractExecutables(source):
    result.add(CCppMember(name: name, kind: ccmkExecutable))
  for name in extractLibraries(source):
    result.add(CCppMember(name: name, kind: ccmkLibraryStatic))

proc extractFirstPackageName(source: string): string =
  ## DSL-port M9.K: heuristic scan for the first ``package <ident>:``
  ## declaration. Same shape as the sibling conventions' helpers — the
  ## lookup key for the M9.H ``registeredFetchSpec`` and M9.I
  ## ``registeredBuildFlags`` registries.
  for rawLine in source.splitLines():
    var line = rawLine
    let commentIdx = line.find('#')
    if commentIdx >= 0:
      line = line[0 ..< commentIdx]
    let stripped = line.strip()
    if not stripped.startsWith("package"):
      continue
    if stripped.len > len("package") and
        stripped[len("package")] notin {' ', '\t'}:
      continue
    let rest = stripped[len("package") .. ^1].strip()
    if rest.len == 0:
      continue
    var name = ""
    for ch in rest:
      if ch in {' ', '\t', ':', ','}:
        break
      name.add(ch)
    if name.len > 0:
      return name
  ""

proc rootMakefile(projectRoot: string): string =
  ## Return the absolute path of the root-level Makefile (preferring
  ## ``GNUmakefile`` → ``Makefile`` → lowercase ``makefile``), or the
  ## empty string if none exists. Matches the GNU make search order.
  for name in ["GNUmakefile", "Makefile", "makefile"]:
    let candidate = projectRoot / name
    if fileExists(extendedPath(candidate)):
      return candidate
  ""

proc collectCSources(dir: string): seq[string] =
  ## Every ``.c`` file directly under ``dir`` (non-recursive). The M17
  ## fixtures keep their per-member sources flat; recursive walks land in
  ## a later milestone alongside ``%.c`` rule lifting (Option A).
  if not dirExists(extendedPath(dir)):
    return @[]
  for kind, path in walkDir(dir):
    if kind == pcFile and path.toLowerAscii.endsWith(".c"):
      result.add(path)
  result.sort(system.cmp[string])

proc resolveExecutableTarget(projectRoot: string;
                             member: CCppMember): CCppEmitTarget =
  ## Locate the source directory + ``.c`` files for an ``executable``
  ## member. Returns a target with empty ``sourceFiles`` when no layout
  ## matches; the caller treats that as a recognition / emit failure.
  ## Priority:
  ##   1. ``src/<name>/main.c`` — per-binary subdir layout.
  ##   2. ``src/main.c``        — single-binary flat layout (the M17
  ##                              ``c-cpp-make/binary`` fixture).
  ##   3. ``src/<name>.c``      — same-as-binary-name flat layout.
  result.member = member
  let perBinaryDir = projectRoot / "src" / member.name
  if fileExists(extendedPath(perBinaryDir / "main.c")):
    result.sourceDir = perBinaryDir
    result.sourceFiles = collectCSources(perBinaryDir)
    return
  let flatMain = projectRoot / "src" / "main.c"
  if fileExists(extendedPath(flatMain)):
    result.sourceDir = projectRoot / "src"
    result.sourceFiles = collectCSources(result.sourceDir)
    return
  let nameC = projectRoot / "src" / (member.name & ".c")
  if fileExists(extendedPath(nameC)):
    result.sourceDir = projectRoot / "src"
    result.sourceFiles = collectCSources(result.sourceDir)
    return

proc resolveLibraryTarget(projectRoot: string;
                          member: CCppMember): CCppEmitTarget =
  ## Locate the source directory + ``.c`` files for a ``library`` member.
  ## Priority:
  ##   1. ``src/<name>/*.c`` — per-library subdir layout.
  ##   2. ``src/<name>.c``   — single-source flat layout (the M17
  ##                           ``c-cpp-make/library-static`` fixture
  ##                           which compiles ``src/greet.c`` for
  ##                           ``library greet``).
  ##   3. ``src/*.c``        — flat layout, library owns the whole src/.
  result.member = member
  let perLibDir = projectRoot / "src" / member.name
  if dirExists(extendedPath(perLibDir)):
    let collected = collectCSources(perLibDir)
    if collected.len > 0:
      result.sourceDir = perLibDir
      result.sourceFiles = collected
      return
  let nameC = projectRoot / "src" / (member.name & ".c")
  if fileExists(extendedPath(nameC)):
    result.sourceDir = projectRoot / "src"
    result.sourceFiles = @[nameC]
    return
  let srcDir = projectRoot / "src"
  let flat = collectCSources(srcDir)
  if flat.len > 0:
    result.sourceDir = srcDir
    result.sourceFiles = flat

proc resolveTarget(projectRoot: string; member: CCppMember): CCppEmitTarget =
  case member.kind
  of ccmkExecutable: resolveExecutableTarget(projectRoot, member)
  of ccmkLibraryStatic: resolveLibraryTarget(projectRoot, member)

proc ccCompiler(): string =
  ## Resolve a C compiler driver on PATH. Prefer ``gcc``; fall back to
  ## ``clang``. Returns the empty string when neither is found — the
  ## convention then declines recognition.
  let gcc = findExe("gcc")
  if gcc.len > 0:
    return gcc
  findExe("clang")

proc arDriver(): string =
  ## Resolve ``ar`` on PATH. Falls back to the literal ``"ar"`` so emit
  ## still produces a coherent argv even when ``ar`` is missing (the
  ## resulting action fails loudly at build time).
  let candidate = findExe("ar")
  if candidate.len > 0:
    return candidate
  "ar"

proc hasCMakeLists(projectRoot: string): bool =
  fileExists(extendedPath(projectRoot / "CMakeLists.txt"))

proc hasMesonBuild(projectRoot: string): bool =
  fileExists(extendedPath(projectRoot / "meson.build"))

proc hasAutotoolsArtifacts(projectRoot: string): bool =
  ## True when the project root carries Autotools artefacts. The C/C++
  ## Make convention defers to the Autotools convention in that case.
  fileExists(extendedPath(projectRoot / "configure.ac")) or
    fileExists(extendedPath(projectRoot / "configure.in")) or
    fileExists(extendedPath(projectRoot / "Makefile.am"))

proc cCppMakeRecognize(projectRoot: string;
                       request: ProviderGraphRequest): bool {.gcsafe.} =
  ## Recognition contract (M17):
  ##   * ``<projectRoot>/Makefile`` (or ``GNUmakefile`` / ``makefile``)
  ##     exists.
  ##   * ``<projectRoot>/reprobuild.nim`` exists AND ``uses:`` lists a
  ##     compiler (``gcc``/``clang``) AND ``make``.
  ##   * at least one ``executable`` or ``library`` member is declared.
  ##   * NO ``CMakeLists.txt`` at the project root.
  ##   * NO ``meson.build`` at the project root (M39 Meson territory).
  ##   * NO Autotools artefacts (``configure.ac`` / ``Makefile.am``) at
  ##     the project root.
  ##   * a C compiler (``gcc`` or ``clang``) is on PATH at convention-
  ##     emit time.
  ##   * each declared member resolves to a non-empty source layout —
  ##     reject otherwise so the no-match diagnostic surfaces the missing
  ##     ``src/main.c`` / ``src/<name>.c`` rather than the convention
  ##     producing an empty graph at build time.
  ##
  ## M9.N: tool availability (``gcc`` / ``clang`` on PATH) is NOT gated
  ## here. Recognition claims a recipe based on DECLARATION (root
  ## Makefile + ``uses:`` lists a C compiler + per-member source
  ## resolution). Tool identity is resolved AFTER recognise, possibly
  ## via cache substitute or source build, so a host-PATH probe at
  ## recognise time is wrong.
  ##
  ## TODO(M9.N Batch B): resolve tool identity through engine instead of
  ## findExe at emit time.
  if rootMakefile(projectRoot).len == 0:
    return false
  if hasCMakeLists(projectRoot):
    return false
  if hasMesonBuild(projectRoot):
    return false
  if hasAutotoolsArtifacts(projectRoot):
    return false
  let source = readReprobuildSource(projectRoot)
  if source.len == 0:
    return false
  if not usesIncludesCCppMake(source):
    return false
  let members = extractMembers(source)
  if members.len == 0:
    return false
  for member in members:
    let resolved = resolveTarget(projectRoot, member)
    if resolved.sourceFiles.len == 0:
      return false
  true

proc scratchPathFor(projectRoot, member: string): string =
  projectRoot / ScratchDirName / member

proc objDirFor(projectRoot, member: string): string =
  scratchPathFor(projectRoot, member) / "obj"

proc binaryPathFor(projectRoot, member: string): string =
  when defined(windows):
    scratchPathFor(projectRoot, member) / (member & ".exe")
  else:
    scratchPathFor(projectRoot, member) / member

proc staticLibraryPathFor(projectRoot, member: string): string =
  ## ``lib<name>.a`` lives under the per-member scratch dir so two
  ## libraries with overlapping object names don't stomp each other.
  scratchPathFor(projectRoot, member) / ("lib" & member & ".a")

proc sanitizeNamePart(value: string): string =
  for ch in value:
    if ch in {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '-', '_', '.'}:
      result.add(ch)
    else:
      result.add('_')
  if result.len == 0:
    result = "x"

proc objFileFor(objDir, source: string): string =
  ## Map a source path to its object path under ``objDir``. Two sources
  ## with the same basename (rare but possible: ``a/foo.c`` and
  ## ``b/foo.c``) would collide; we sanitize the relative-stem so the
  ## .o paths stay unique. M17 fixtures don't trigger that — every
  ## member's source files live in one directory and have unique
  ## basenames — but the safety belt costs nothing.
  let base = extractFilename(source)
  let stem =
    if base.endsWith(".c"): base[0 ..< base.len - 2]
    else: base
  objDir / (sanitizeNamePart(stem) & ".o")

proc emitCompileAction(projectRoot, ccExe: string;
                       member: CCppMember;
                       source, objFile, depFile: string;
                       sourceDir: string;
                       extraDeps: seq[string] = @[];
                       extraInputs: seq[string] = @[]): BuildActionDef =
  ## One ``gcc -c`` action for a single C source.
  let includeFlags = block:
    var flags: seq[string] = @[]
    let srcDir = projectRoot / "src"
    if dirExists(extendedPath(srcDir)):
      flags.add("-I")
      flags.add(srcDir)
    let srcIncludeDir = projectRoot / "src" / "include"
    if dirExists(extendedPath(srcIncludeDir)):
      flags.add("-I")
      flags.add(srcIncludeDir)
    let topIncludeDir = projectRoot / "include"
    if dirExists(extendedPath(topIncludeDir)):
      flags.add("-I")
      flags.add(topIncludeDir)
    # When the source directory differs from ``src/`` (per-member subdir
    # layout, e.g. ``src/<name>/``), give the compiler that dir too so
    # ``#include "<sibling>.h"`` resolves.
    if sourceDir != srcDir and dirExists(extendedPath(sourceDir)):
      flags.add("-I")
      flags.add(sourceDir)
    flags
  var argv = @[ccExe, "-c", "-O2", "-Wall", "-Wextra",
    "-MD", "-MF", depFile]
  for flag in includeFlags:
    argv.add(flag)
  argv.add("-o")
  argv.add(objFile)
  argv.add(source)
  let actionId = "ccpp-make-compile-" & sanitizeNamePart(member.name) & "-" &
    sanitizeNamePart(extractFilename(source))
  let kindTag = case member.kind
    of ccmkExecutable: "executable"
    of ccmkLibraryStatic: "library-static"
  var inputs = @[source]
  for ei in extraInputs:
    if ei notin inputs:
      inputs.add(ei)
  buildAction(
    id = actionId,
    call = inlineExecCall(argv, projectRoot),
    deps = extraDeps,
    inputs = inputs,
    outputs = @[objFile],
    pool = "compile",
    depfile = depFile,
    dependencyPolicy = makeDepfilePolicy(depFile),
    commandStatsId = "ccpp-make." & kindTag & ".compile")

proc emitLinkAction(projectRoot, ccExe: string;
                    member: CCppMember;
                    objFiles: seq[string];
                    compileActionIds: seq[string];
                    makeFlags: seq[string]): BuildActionDef =
  ## ``gcc -o <bin> <objs>`` link action for an ``executable`` member.
  ##
  ## DSL-port M9.K: the c-cpp-make convention does NOT invoke ``make``
  ## itself (it emits its own per-source DAG), so the M9.I ``makeFlags``
  ## channel has no native injection point. The pragmatic mapping is to
  ## append the registered flags to the link action's argv — the
  ## closest analog to "make produces the final binary" within this
  ## convention's emit shape. Recipes whose makeFlags are CFLAGS-style
  ## tokens (``CFLAGS=-O3``) land on the gcc link command line where
  ## they are effective; recipes whose makeFlags are make-variable
  ## overrides (``ARCH=x86_64``) would belong on a real ``make ...``
  ## action — that integration is a follow-up when the c-cpp-make
  ## convention gains a Mode-A → make fallback.
  let binaryOutput = binaryPathFor(projectRoot, member.name)
  createDir(extendedPath(parentDir(binaryOutput)))
  var argv = @[ccExe, "-o", binaryOutput]
  for obj in objFiles:
    argv.add(obj)
  for flag in makeFlags:
    argv.add(flag)
  buildAction(
    id = "ccpp-make-link-" & sanitizeNamePart(member.name),
    call = inlineExecCall(argv, projectRoot),
    deps = compileActionIds,
    inputs = objFiles,
    outputs = @[binaryOutput],
    pool = "compile",
    dependencyPolicy = automaticMonitorPolicy(),
    commandStatsId = "ccpp-make.executable.link")

proc emitArchiveAction(projectRoot, arExe: string;
                       member: CCppMember;
                       objFiles: seq[string];
                       compileActionIds: seq[string];
                       makeFlags: seq[string]): BuildActionDef =
  ## ``ar rcs lib<name>.a <objs>`` archive action for a static library.
  ##
  ## DSL-port M9.K: see ``emitLinkAction`` for the makeFlags channel
  ## semantics — same pragmatic mapping (appended verbatim to the
  ## archive argv).
  let archiveOutput = staticLibraryPathFor(projectRoot, member.name)
  createDir(extendedPath(parentDir(archiveOutput)))
  var argv = @[arExe, "rcs", archiveOutput]
  for obj in objFiles:
    argv.add(obj)
  for flag in makeFlags:
    argv.add(flag)
  buildAction(
    id = "ccpp-make-archive-" & sanitizeNamePart(member.name),
    call = inlineExecCall(argv, projectRoot),
    deps = compileActionIds,
    inputs = objFiles,
    outputs = @[archiveOutput],
    pool = "compile",
    dependencyPolicy = automaticMonitorPolicy(),
    commandStatsId = "ccpp-make.library-static.archive")

proc emitForMember(projectRoot, ccExe, arExe: string;
                   target: CCppEmitTarget;
                   makeFlags: seq[string];
                   compileExtraDeps: seq[string] = @[];
                   compileExtraInputs: seq[string] = @[]):
                     tuple[compiles: seq[BuildActionDef];
                           terminal: BuildActionDef] =
  ## Emit per-source compiles + the terminal link/archive action for a
  ## single member. Materialises the per-member ``obj/`` scratch dir
  ## eagerly so the engine's spawn step doesn't race on directory
  ## creation.
  let objDir = objDirFor(projectRoot, target.member.name)
  createDir(extendedPath(objDir))
  var compileActions: seq[BuildActionDef] = @[]
  var objFiles: seq[string] = @[]
  var compileIds: seq[string] = @[]
  for source in target.sourceFiles:
    let objFile = objFileFor(objDir, source)
    let depFile = objFile & ".d"
    objFiles.add(objFile)
    let action = emitCompileAction(projectRoot, ccExe, target.member,
      source, objFile, depFile, target.sourceDir,
      compileExtraDeps, compileExtraInputs)
    compileActions.add(action)
    compileIds.add(action.id)
  case target.member.kind
  of ccmkExecutable:
    let link = emitLinkAction(projectRoot, ccExe, target.member, objFiles,
      compileIds, makeFlags)
    (compileActions, link)
  of ccmkLibraryStatic:
    let archive = emitArchiveAction(projectRoot, arExe, target.member,
      objFiles, compileIds, makeFlags)
    (compileActions, archive)

proc syntheticPackage(projectRoot: string;
                      members: seq[CCppMember]): PackageDef =
  ## Build a minimal ``PackageDef`` the runtime helper wants.
  var name = "c_cpp_make_convention"
  if members.len > 0:
    name = sanitizeNamePart(members[0].name)
  let projectMatch = resolveProjectFile(projectRoot)
  let sourceFile =
    if projectMatch.path.len > 0: projectMatch.path
    else: projectRoot / LegacyProjectFileName
  PackageDef(
    packageName: name,
    sourceFile: sourceFile,
    hasDevEnv: false,
    devEnvBodyHash: "",
    toolUses: @[])

proc cCppMakeEmitFragment(projectRoot: string;
                          request: ProviderGraphRequest):
                            GraphFragment {.gcsafe.} =
  ## Convention entry — enumerate members, resolve each to a
  ## source-file list, emit per-source compile + per-member link/archive
  ## actions via the DSL, hand the whole thing to ``buildPackageFragment``.
  ##
  ## The DSL runtime mutates module-level registries that aren't
  ## annotated ``gcsafe``. Same ``cast(gcsafe)`` escape hatch as the
  ## other conventions.
  {.cast(gcsafe).}:
    let source = readReprobuildSource(projectRoot)
    let members = extractMembers(source)
    if members.len == 0:
      let projectMatch = resolveProjectFile(projectRoot)
      let projectFile =
        if projectMatch.path.len > 0: projectMatch.path
        else: projectRoot / LegacyProjectFileName
      raise newException(ValueError,
        "c-cpp-make convention: no executable or library members " &
          "declared in " & projectFile)
    let ccExe = ccCompiler()
    if ccExe.len == 0:
      raise newException(ValueError,
        "c-cpp-make convention: neither 'gcc' nor 'clang' on PATH; " &
          "cannot compile C sources")
    let arExe = arDriver()
    var targets: seq[CCppEmitTarget] = @[]
    for member in members:
      let target = resolveTarget(projectRoot, member)
      if target.sourceFiles.len == 0:
        raise newException(ValueError,
          "c-cpp-make convention: no .c sources resolved for member '" &
            member.name & "' under " & projectRoot)
      targets.add(target)
    let pkg = syntheticPackage(projectRoot, members)
    # DSL-port M9.K: look up the DSL package name and read the M9.H
    # fetch spec + M9.I make flag seq against that key.
    let dslPackageName = extractFirstPackageName(source)
    let fetchSpec =
      if dslPackageName.len > 0: registeredFetchSpec(dslPackageName)
      else: DslFetchSpec()
    let hasFetch = fetchSpec.url.len > 0 and fetchSpec.hashHex.len > 0
    let makeFlags =
      if dslPackageName.len > 0:
        registeredBuildFlags(dslPackageName, "", "make")
      else: @[]
    let registerAll = proc() =
      discard buildPool("compile", 8'u32)
      var allActions: seq[BuildActionDef] = @[]
      var compileExtraDeps: seq[string] = @[]
      var compileExtraInputs: seq[string] = @[]
      if hasFetch:
        discard buildPool("fetch", 2'u32)
        let fetchAct = emitFetchAction(projectRoot, dslPackageName, fetchSpec)
        allActions.add(fetchAct)
        compileExtraDeps.add(fetchAct.id)
        compileExtraInputs.add(fetchStampPath(projectRoot, fetchSpec.hashHex))
      for target in targets:
        let emitted = emitForMember(projectRoot, ccExe, arExe, target,
          makeFlags, compileExtraDeps, compileExtraInputs)
        for a in emitted.compiles:
          allActions.add(a)
        allActions.add(emitted.terminal)
      defaultTarget(target("default", allActions))
    result = buildPackageFragment(pkg, request, registerAll,
      includeDefault = false)

proc cCppMakeConvention*(): LanguageConvention =
  ## The single value the standard provider binary registers at startup.
  ## Same factory shape as the other conventions so tests can build
  ## isolated registries.
  LanguageConvention(
    name: "c-cpp-make",
    recognize: cCppMakeRecognize,
    emitFragment: cCppMakeEmitFragment)
